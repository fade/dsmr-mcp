;;;; src/bus/wakeup.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; The wakeup side of the bus. Nothing — not a socket, not a signal — can pull a
;;;; sleeping agent back into its loop; the last hop is always a background watcher
;;;; that blocks until there is a message for this subscriber and then returns, so
;;;; the surrounding harness can re-invoke the agent, which catches up from its
;;;; durable cursor.
;;;;
;;;; The one property that makes this lossless is that the wait is LEVEL-triggered,
;;;; not edge-triggered. On entry it compares the log's current end against the
;;;; subscriber's cursor; a message that landed in the gap between "agent went to
;;;; sleep" and "watcher armed" is therefore seen immediately rather than waited
;;;; past. A pure edge watch (an inotify with no initial check) would silently
;;;; drop that message — the bug this design exists to avoid.
;;;;
;;;; Waiting is OBSERVE-ONLY: it reads through WAL:SCAN (which never truncates a
;;;; torn tail) and never advances the cursor. Advancing the cursor is delivery's
;;;; job (see the cursor module), kept separate so a wake that is never followed
;;;; by a delivery does not silently consume messages.

(defpackage #:dsmr-mcp/src/bus/wakeup
  (:use #:cl)
  (:local-nicknames (#:wal #:dsmr-mcp/src/bus/wal)
                    (#:cursor #:dsmr-mcp/src/bus/cursor))
  (:export #:wait-until-seq
           #:wait-for-message))

(in-package #:dsmr-mcp/src/bus/wakeup)

(defun wait-until-seq (wal-path after &key (timeout-ms 5000) (poll-ms 20))
  "Block until WAL-PATH holds a record with seq greater than AFTER, then return
   that last seq. Return NIL on timeout. Level-triggered: if a qualifying record
   is already present it returns on the first check, so a message that arrived
   before the wait began is never missed. Read-only — never truncates or acks."
  (let ((deadline (+ (wal:now-ms) timeout-ms)))
    (loop
      (let ((last (wal:scan wal-path)))
        (when (> last after) (return last)))
      (when (>= (wal:now-ms) deadline) (return nil))
      (sleep (/ poll-ms 1000.0)))))

(defun wait-for-message (subscriber &key (timeout-ms 5000) (poll-ms 20))
  "Block until SUBSCRIBER has at least one undelivered record, then return the
   log's current last seq (NIL on timeout). Observe-only: it does NOT advance the
   cursor — call the cursor module's DELIVER-PENDING after waking to receive and
   acknowledge the messages."
  (wait-until-seq (cursor:subscriber-wal subscriber)
                  (cursor:cursor-value subscriber)
                  :timeout-ms timeout-ms :poll-ms poll-ms))
