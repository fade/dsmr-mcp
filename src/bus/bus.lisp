;;;; src/bus/bus.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; The public face of the coordination bus — what an agent actually calls. A
;;;; CLIENT publishes work to the broker; a SUBSCRIBER receives it. The two roles
;;;; are split because publishing and consuming have different sockets and state,
;;;; though one agent commonly does both.
;;;;
;;;; Publishing is a ZeroMQ PUSH to the broker's intake — fire-and-forget; the
;;;; broker is what makes it durable by appending to the log.
;;;;
;;;; Receiving combines the live and durable paths exactly as the design intends:
;;;; AWAIT first delivers anything already past the subscriber's cursor (so a
;;;; backlog accumulated while the agent was away is caught up immediately), then
;;;; blocks on the ZeroMQ fan-out feed for a live nudge that more has arrived. The
;;;; nudge's content is ignored — the log, read through the cursor, is the source
;;;; of truth — so a dropped or missed nudge costs latency, never a message. POLL
;;;; is the non-blocking form: catch up and return whatever is pending right now.

(require :sb-posix)

(defpackage #:dsmr-mcp/src/bus/bus
  (:use #:cl)
  (:local-nicknames (#:broker #:dsmr-mcp/src/bus/broker)
                    (#:cursor #:dsmr-mcp/src/bus/cursor)
                    (#:election #:dsmr-mcp/src/bus/election)
                    (#:wal #:dsmr-mcp/src/bus/wal)
                    (#:tz #:dsmr-mcp/src/bus/zmq))
  (:export #:client #:connect-client #:publish #:disconnect-client
           #:subscriber #:subscribe #:unsubscribe #:poll #:poll-count #:await
           #:agent-id #:encode-id
           #:decode-envelope #:delivered-body-string))

(in-package #:dsmr-mcp/src/bus/bus)

(defun %now-ms ()
  (values (truncate (* 1000 (get-internal-real-time)) internal-time-units-per-second)))

;;; --------------------------------------------------------------- identity

(defvar *local-counter* 0
  "Process-local counter for auto-generated subscriber names.")

(defun %unique-local ()
  "A token unique across processes (pid) and within one (counter) — gensym-style
   for an anonymous, ephemeral subagent."
  (format nil "g~A-~A" (sb-posix:getpid) (incf *local-counter*)))

(defun agent-id (namespace &key name)
  "Construct a bus subscriber id of the form <namespace>/<name>. NAMESPACE is the
   project root (the shared 'generation name'); NAME, when given, is a stable
   subagent name that resumes its cursor across restarts. When NAME is omitted an
   auto-unique ephemeral name is generated, so multiple anonymous subagents in one
   project each get a distinct id under the shared namespace."
  (format nil "~A/~A" namespace (or name (%unique-local))))

(defun encode-id (id)
  "Percent-encode ID into a single filesystem-safe token for a cursor filename.
   Injective, so two distinct ids never share a cursor."
  (with-output-to-string (s)
    (loop for ch across id
          do (if (or (alphanumericp ch) (member ch '(#\. #\- #\_)))
                 (write-char ch s)
                 (format s "%~2,'0X" (char-code ch))))))

(defun %release-fd (fd)
  (when fd (ignore-errors (election:close-lock fd))))

;;; ------------------------------------------------------ message envelope
;;;
;;; Two distinct needs ride one body envelope, with NO change to the WAL frame or
;;; the broker (which appends the submission verbatim):
;;;
;;;   - SELF-WAKE: the publisher learns the broker-assigned seq of its OWN message
;;;     by tagging it with a globally-unique correlation-id, then matching that id
;;;     on the durable record it reads back. Matching by message IDENTITY (not WAL
;;;     position) is what makes this race-free under concurrent cross-process
;;;     publishing — a foreign agent's record simply fails the id match.
;;;
;;;   - SELF-ECHO suppression: the envelope also carries the publisher's stable
;;;     self-id, so the publisher's OWN receive can filter its own messages out of
;;;     the returned set (the agent layer does this) — without ever touching a
;;;     cursor.
;;;
;;; Wire format of the body string:  correlation-id <DELIM> encoded-self-id <DELIM> payload
;;; DELIM is a single char outside both the correlation-id alphabet and ENCODE-ID's
;;; output, so neither field can ever contain it; the payload follows the SECOND
;;; delimiter raw and may itself contain DELIM harmlessly (decoding splits on the
;;; first two only).

(defconstant +envelope-delimiter+ #\|
  "The envelope field separator. Outside the correlation-id alphabet (lowercase
   hex/alphanumerics) and outside ENCODE-ID's output (percent-encoding over
   alphanumerics + . - _), so it can appear only in the payload — never in either
   id field.")

(defvar *correlation-random* (make-random-state t)
  "A per-process random source, seeded from system entropy at load, for the random
   nonce in a correlation-id. Distinct fresh images thus draw distinct nonces even
   when pid + counter happen to align.")

(defun %new-correlation-id ()
  "A token unique across processes (pid), within one process (a monotonic counter),
   and against accidental reuse (a random nonce). The alphabet is lowercase
   hex/alphanumerics only, so the envelope delimiter can never appear inside it,
   and two publishes anywhere on the host never collide."
  (format nil "c~(~x~)x~(~x~)x~(~x~)"
          (sb-posix:getpid)
          (incf *local-counter*)
          (random (expt 2 48) *correlation-random*)))

(defun %wrap-envelope (correlation-id self-id payload)
  "Build the wire body: CORRELATION-ID + DELIM + (ENCODE-ID SELF-ID) + DELIM +
   PAYLOAD. A NIL SELF-ID embeds an empty encoded field; the wrap always emits two
   delimiters so the format is uniform and decoding is unambiguous."
  (format nil "~A~C~A~C~A"
          correlation-id
          +envelope-delimiter+
          (if self-id (encode-id self-id) "")
          +envelope-delimiter+
          payload))

(defun decode-envelope (body-string)
  "Split a wire body into THREE values: the original user TEXT (everything past the
   second delimiter), the CORRELATION-ID, and the ENCODED SELF-ID (compared
   encoded-vs-encoded against (ENCODE-ID id), so it is returned in its encoded
   form). The payload may itself contain the delimiter — only the first two
   delimiter positions are used. A body WITHOUT two delimiters is a legacy,
   un-enveloped message from an old-core publisher: it is returned verbatim as the
   text with NIL ids, so the decoder is backward-compatible during a staggered
   rollout."
  (let ((d1 (position +envelope-delimiter+ body-string)))
    (if d1
        (let ((d2 (position +envelope-delimiter+ body-string :start (1+ d1))))
          (if d2
              (values (subseq body-string (1+ d2))
                      (subseq body-string 0 d1)
                      (let ((encoded (subseq body-string (1+ d1) d2)))
                        (if (zerop (length encoded)) nil encoded)))
              (values body-string nil nil)))
        (values body-string nil nil))))

(defun delivered-body-string (record)
  "The original user text of RECORD — its body decoded through the envelope. A
   single call for body-only readers that do not need the ids."
  (values (decode-envelope (wal:record-body-string record))))

;;; --------------------------------------------------------------- client

(defstruct (client (:constructor %make-client))
  paths submitter members-fd)

(defun connect-client (paths &key (join t))
  "Open a publishing client against the bus at PATHS. Holds a PUSH socket to the
   broker's intake and, by default, a membership lock for its lifetime."
  (broker:ensure-bus-dirs paths)
  (%make-client
   :paths paths
   :submitter (tz:make-submitter (broker:bus-paths-submit-endpoint paths))
   :members-fd (when join (broker:join-members paths))))

(defun %await-own-seq (paths correlation-id after &key (timeout-ms 2000) (poll-ms 5))
  "Read the WAL (read-only) for records past AFTER and return the RECORD-SEQ of the
   FIRST one whose decoded correlation-id STRING= CORRELATION-ID — that is the
   publisher's OWN record, identified by message identity, never by WAL position.
   A concurrent foreign agent's record fails the id match and is left for normal
   delivery. Bounded by a deadline: returns NIL if the id has not appeared in time.
   AFTER is not advanced between turns — re-scanning from the same floor is fine
   because the id match, not the position, selects the record. Touches no cursor."
  (let ((deadline (+ (%now-ms) timeout-ms))
        (wal-path (broker:bus-paths-wal paths)))
    (loop
      (dolist (record (wal:read-records wal-path :after after))
        (multiple-value-bind (text cid sid) (decode-envelope (wal:record-body-string record))
          (declare (ignore text sid))
          (when (and cid (string= cid correlation-id))
            (return-from %await-own-seq (wal:record-seq record)))))
      (when (>= (%now-ms) deadline) (return nil))
      (sleep (/ poll-ms 1000.0)))))

(defun publish (client payload &key after self-id)
  "Submit PAYLOAD (string) to the broker, wrapped in a correlation-id + self-id
   envelope. Delivery is still fire-and-forget — a ZeroMQ PUSH the broker appends
   verbatim and fans out — but the call ALSO reports the EXACT broker-assigned seq
   of this message, learned by matching its globally-unique correlation-id on the
   durable record it reads back over the existing feed. Returns that integer seq,
   or NIL when it could not be matched within the bound (the message was still
   sent; only the seq-learnance is best-effort, never a failure). AFTER is the
   pre-send floor for the read-back scan (the caller's last-seen seq); it defaults
   to the WAL's current highest seq. SELF-ID is the publisher's stable bus id,
   embedded so the publisher's own receive can filter the message out. Reads the
   WAL read-only and touches NO cursor."
  (let* ((correlation-id (%new-correlation-id))
         (paths (client-paths client))
         (floor (or after (wal:scan (broker:bus-paths-wal paths)))))
    (tz:send-message (client-submitter client)
                     (%wrap-envelope correlation-id self-id payload))
    (%await-own-seq paths correlation-id floor)))

(defun disconnect-client (client)
  "Close the client's socket and release its membership lock."
  (when (client-submitter client)
    (tz:close-endpoint (client-submitter client))
    (setf (client-submitter client) nil))
  (%release-fd (client-members-fd client))
  (setf (client-members-fd client) nil)
  (values))

;;; ------------------------------------------------------------ subscriber

(defstruct (subscriber (:constructor %make-subscriber))
  paths cursor feed members-fd)

(defun subscribe (paths id &key (join t) (feed-timeout-ms 100))
  "Open a subscriber named ID against the bus at PATHS. Holds a durable cursor
   (under the bus cursors dir) and a SUB socket on the broker's fan-out feed."
  (broker:ensure-bus-dirs paths)
  (let ((cursor-path (merge-pathnames (encode-id id) (broker:bus-paths-cursors-dir paths))))
    (%make-subscriber
     :paths paths
     :cursor (cursor:make-subscriber id (broker:bus-paths-wal paths) cursor-path)
     :feed (tz:make-feed (broker:bus-paths-pub-endpoint paths)
                         :timeout-ms feed-timeout-ms)
     :members-fd (when join (broker:join-members paths)))))

(defun poll (subscriber)
  "Non-blocking: deliver every record past the cursor right now (catch-up) and
   advance the cursor. Returns the list of WAL:RECORD delivered (possibly empty)."
  (cursor:deliver-pending (subscriber-cursor subscriber)))

(defun poll-count (subscriber)
  "How many records are waiting for SUBSCRIBER right now, without delivering them
   or moving the cursor."
  (cursor:pending-count (subscriber-cursor subscriber)))

(defun await (subscriber &key (timeout-ms 1000))
  "Block up to TIMEOUT-MS for at least one message, then deliver and return it.
   Delivers any existing backlog first (catch-up), then waits on the live ZeroMQ
   nudge for more. The cursor — not the nudge — is the source of truth, so a
   missed nudge degrades to catch-up, never a lost message. Returns the delivered
   records, or NIL if nothing arrived before the deadline."
  (let ((deadline (+ (%now-ms) timeout-ms)))
    (loop
      (let ((delivered (cursor:deliver-pending (subscriber-cursor subscriber))))
        (when delivered (return delivered)))
      (when (>= (%now-ms) deadline) (return nil))
      ;; wait for a live nudge over zmq (bounded by the feed's receive timeout);
      ;; its content is irrelevant — the next loop turn reads the log.
      (tz:recv-message (subscriber-feed subscriber)))))

(defun unsubscribe (subscriber)
  "Close the subscriber's feed and release its membership lock. The durable cursor
   file is left in place so the subscriber resumes where it left off next time."
  (when (subscriber-feed subscriber)
    (tz:close-endpoint (subscriber-feed subscriber))
    (setf (subscriber-feed subscriber) nil))
  (%release-fd (subscriber-members-fd subscriber))
  (setf (subscriber-members-fd subscriber) nil)
  (values))
