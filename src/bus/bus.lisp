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
                    (#:envelope #:dsmr-mcp/src/bus/envelope)
                    (#:wal #:dsmr-mcp/src/bus/wal)
                    (#:tz #:dsmr-mcp/src/bus/zmq))
  (:import-from #:dsmr-mcp/src/bus/cursor
                #:+default-batch-size+)
  (:import-from #:dsmr-mcp/src/bus/envelope
                #:encode-id
                #:decode-id
                #:split-agent-id
                #:author-display
                #:agent-id
                #:wrap-envelope
                #:decode-envelope
                #:delivered-body-string
                #:foreign-self-id-p
                #:foreign-record-p
                #:record-addressee
                #:deliverable-p
                #:deliverable-record-p
                #:+envelope-delimiter+)
  (:export #:client #:connect-client #:publish #:disconnect-client
           #:subscriber #:subscribe #:unsubscribe #:poll #:poll-count
           #:poll-count-foreign #:await
           #:skip-to-head #:+default-batch-size+
           #:agent-id #:encode-id #:decode-id
           #:split-agent-id #:author-display
           #:decode-envelope #:delivered-body-string
           #:foreign-self-id-p #:foreign-record-p
           #:record-addressee #:deliverable-p #:deliverable-record-p))

(in-package #:dsmr-mcp/src/bus/bus)

(defun %now-ms ()
  "Milliseconds from GET-INTERNAL-REAL-TIME. This is a monotonic-ish counter from
   an implementation-dependent fixed point in the past, used ONLY for measuring
   relative durations (deadlines) — never as a wall clock the operator reads."
  (values (truncate (* 1000 (get-internal-real-time)) internal-time-units-per-second)))

(defun %release-fd (fd)
  (when fd (ignore-errors (election:close-lock fd))))

;;; ------------------------------------------------------ message envelope
;;;
;;; Id construction, id encoding, and the body envelope itself live in the
;;; dsmr-mcp/src/bus/envelope leaf and are imported here, then re-exported so
;;; BUS:ENCODE-ID and friends stay the names callers already use. They are
;;; separate because the standalone watcher binary has to decode the same wire
;;; format to tell a peer's message from its own, and that binary links no
;;; ZeroMQ — which this file does. One implementation, two consumers.
;;;
;;; What stays here is the correlation-id: it is minted per publish, matched on
;;; read-back to learn this message's assigned seq, and never parsed by anyone
;;; but the publisher, so it belongs with the publishing code rather than with
;;; the shared format.

(defvar *correlation-random* (make-random-state t)
  "A per-process random source, seeded from system entropy at load, for the random
   nonce in a correlation-id. Distinct fresh images thus draw distinct nonces even
   when pid + counter happen to align.")

(defvar *correlation-counter* 0
  "Process-local counter contributing the monotonic component of a
   correlation-id.")

(defun %new-correlation-id ()
  "A token unique across processes (pid), within one process (a monotonic counter),
   and against accidental reuse (a random nonce). The alphabet is lowercase
   hex/alphanumerics only, so the envelope delimiter can never appear inside it,
   and two publishes anywhere on the host never collide."
  (format nil "c~(~x~)x~(~x~)x~(~x~)"
          (sb-posix:getpid)
          (incf *correlation-counter*)
          (random (expt 2 48) *correlation-random*)))

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
   AFTER is not advanced between turns — the floor stays where the publish began,
   because the id match, not the position, selects the record. Touches no cursor.

   The rescan is incremental: one reader is held across the whole wait, so each
   record is examined on the turn it lands and not again. Re-reading the log from
   the floor on every turn instead made one publish pay for the entire history
   several hundred times over on a busy bus, for a wait that is normally decided
   in the first few turns."
  (let ((deadline (+ (%now-ms) timeout-ms))
        (wal-path (broker:bus-paths-wal paths))
        (reader (wal:make-reader)))
    (loop
      (dolist (record (wal:read-forward wal-path reader :after after))
        (multiple-value-bind (text cid sid) (decode-envelope (wal:record-body-string record))
          (declare (ignore text sid))
          (when (and cid (string= cid correlation-id))
            (return-from %await-own-seq (wal:record-seq record)))))
      (when (>= (%now-ms) deadline) (return nil))
      (sleep (/ poll-ms 1000.0)))))

(defun publish (client payload &key after self-id to)
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
   WAL read-only and touches NO cursor.

   TO, when given, is the bus id of the one participant the message is for. It
   rides in the same envelope field as SELF-ID and changes nothing else: the
   record is appended to the fleet's own log exactly as a broadcast is, and every
   member's cursor still advances over it. Only who is SHOWN the message changes.
   That also means an addressed message is not a private one. It sits on a log
   every member of the fleet can read, and the transport has no security surface
   to make it otherwise."
  (let* ((correlation-id (%new-correlation-id))
         (paths (client-paths client))
         (floor (or after (wal:scan (broker:bus-paths-wal paths)))))
    (tz:send-message (client-submitter client)
                     (wrap-envelope correlation-id self-id payload :to to))
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
   (under the bus cursors dir) and a SUB socket on the broker's fan-out feed.

   A cursor that does not exist yet is seeded at the current log head before this
   returns, so a participant joining for the first time starts from now rather
   than replaying everything the bus has ever carried. Seeding happens here
   rather than lazily on the first read because a caller may connect long before
   it reads — the background restart listener joins at server startup and then
   polls on its own cadence — and an unseeded cursor would spend that whole gap
   looking like a participant owed the entire log."
  (broker:ensure-bus-dirs paths)
  (let ((cursor-path (merge-pathnames (encode-id id) (broker:bus-paths-cursors-dir paths))))
    (%make-subscriber
     :paths paths
     :cursor (cursor:ensure-seeded
              (cursor:make-subscriber id (broker:bus-paths-wal paths) cursor-path))
     :feed (tz:make-feed (broker:bus-paths-pub-endpoint paths)
                         :timeout-ms feed-timeout-ms)
     :members-fd (when join (broker:join-members paths)))))

(defun poll (subscriber &key (limit cursor:+default-batch-size+))
  "Non-blocking: deliver a bounded batch of the records past the cursor right now
   (catch-up) and advance the cursor over exactly what it delivered. Returns the
   list of WAL:RECORD delivered (possibly empty). LIMIT NIL asks for the whole
   backlog. What remains after a bounded call is POLL-COUNT's question to answer,
   not a second value returned from here."
  (cursor:deliver-pending (subscriber-cursor subscriber) :limit limit))

(defun poll-count (subscriber)
  "How many records are waiting for SUBSCRIBER right now, without delivering them
   or moving the cursor."
  (cursor:pending-count (subscriber-cursor subscriber)))

(defun poll-count-foreign (subscriber own-encoded)
  "How many records past SUBSCRIBER's cursor DELIVERY would actually hand back
   for the agent whose encoded self-id is OWN-ENCODED. That is records this agent
   did not publish and that name either nobody or this agent, under the exact
   DELIVERABLE-RECORD-P predicate the receive path filters by.

   This is the count an agent should read as `pending`. POLL-COUNT is the raw
   count above the cursor: it includes the agent's OWN un-consumed publishes and
   any mail addressed to somebody else, both of which delivery drops, so it
   over-reports for any subscriber on a bus carrying either. Read-only, and the
   cursor never moves.

   Sharing one predicate with AGENT-RECEIVE is the whole point: the count and the
   delivery filter reach the same verdict, so a reported `pending` can never
   promise a message a receive would then quietly withhold."
  (let ((cur (subscriber-cursor subscriber))
        (deliverable 0))
    (dolist (record (wal:read-records (cursor:subscriber-wal cur)
                                      :after (cursor:cursor-value cur))
                    deliverable)
      (when (deliverable-record-p record own-encoded)
        (incf deliverable)))))

(defun await (subscriber &key (timeout-ms 1000) (limit cursor:+default-batch-size+))
  "Block up to TIMEOUT-MS for at least one message, then deliver and return it.
   Delivers any existing backlog first (catch-up), then waits on the live ZeroMQ
   nudge for more. The cursor — not the nudge — is the source of truth, so a
   missed nudge degrades to catch-up, never a lost message. Returns the delivered
   records, or NIL if nothing arrived before the deadline.

   Each delivery is bounded by LIMIT, so a caller waiting on a bus it has been
   away from gets one batch and can come back for the rest; LIMIT NIL asks for
   the whole backlog at once.

   TIMEOUT-MS is GRANULAR to the feed's own receive timeout (the FEED-TIMEOUT-MS
   passed to SUBSCRIBE, default 100ms): the deadline is only checked between feed
   receives, so a quiet AWAIT can overshoot TIMEOUT-MS by up to nearly one feed
   interval. Pick a feed timeout no larger than the tightest AWAIT timeout a
   caller needs honored. The clock is for relative durations only (see %NOW-MS)."
  (let ((deadline (+ (%now-ms) timeout-ms)))
    (loop
      (let ((delivered (cursor:deliver-pending (subscriber-cursor subscriber)
                                               :limit limit)))
        (when delivered (return delivered)))
      (when (>= (%now-ms) deadline) (return nil))
      ;; wait for a live nudge over zmq (bounded by the feed's receive timeout);
      ;; its content is irrelevant — the next loop turn reads the log.
      (tz:recv-message (subscriber-feed subscriber)))))

(defun skip-to-head (subscriber)
  "Abandon SUBSCRIBER's backlog outright and return how many records were given
   up. Offered here so a caller can make that choice without reaching past the
   facade into the cursor itself. Nothing on the delivery path calls it — giving
   up unread messages is always a decision someone makes on purpose, and the
   count is what makes it visible afterwards."
  (cursor:skip-to-head (subscriber-cursor subscriber)))

(defun unsubscribe (subscriber)
  "Close the subscriber's feed and release its membership lock. The durable cursor
   file is left in place so the subscriber resumes where it left off next time."
  (when (subscriber-feed subscriber)
    (tz:close-endpoint (subscriber-feed subscriber))
    (setf (subscriber-feed subscriber) nil))
  (%release-fd (subscriber-members-fd subscriber))
  (setf (subscriber-members-fd subscriber) nil)
  (values))
