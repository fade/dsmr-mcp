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
                    (#:tz #:dsmr-mcp/src/bus/zmq))
  (:export #:client #:connect-client #:publish #:disconnect-client
           #:subscriber #:subscribe #:unsubscribe #:poll #:poll-count #:await
           #:agent-id #:encode-id))

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

(defun publish (client payload)
  "Submit PAYLOAD (string or octet vector) to the broker. Fire-and-forget: the
   broker appends it to the log and fans out a nudge. Returns PAYLOAD."
  (tz:send-message (client-submitter client) payload)
  payload)

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
