;;;; src/bus/cursor.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Per-subscriber delivery cursor over the bus write-ahead log. Each subscriber
;;;; owns a durable file holding the sequence number it has acknowledged. The
;;;; cursor is the safety net that makes a missed real-time wakeup degrade to
;;;; catch-up rather than a lost message: whatever the subscriber's liveness, on
;;;; the next delivery it receives every record past its cursor and no other.
;;;;
;;;; Two operations, kept deliberately distinct (see the wakeup module for why):
;;;;
;;;;   - OBSERVE is read-only and lives in the WAL/wakeup layer — it never moves
;;;;     the cursor.
;;;;   - DELIVER-PENDING is the sole cursor-advancing step. It hands back every
;;;;     record with seq greater than the cursor, then advances the cursor to the
;;;;     last delivered seq. It is idempotent: a second call with nothing new
;;;;     delivers nothing and leaves the cursor where it was, so a re-arm or a
;;;;     duplicate wake never replays a message.
;;;;
;;;; Delivery reads through WAL:READ-RECORDS, which is read-only and stops at a
;;;; torn tail — a subscriber therefore never sees a half-written record and never
;;;; truncates the log (only a successor broker repairs it).

(defpackage #:dsmr-mcp/src/bus/cursor
  (:use #:cl)
  (:local-nicknames (#:wal #:dsmr-mcp/src/bus/wal))
  (:export #:subscriber #:make-subscriber
           #:subscriber-id #:subscriber-wal #:subscriber-cursor-path
           #:cursor-value
           #:deliver-pending
           #:pending-count))

(in-package #:dsmr-mcp/src/bus/cursor)

(defstruct (subscriber (:constructor make-subscriber (id wal cursor-path)))
  "A bus consumer: its stable ID, the WAL path it reads, and the path of its
   durable cursor file."
  (id "" :type string)
  (wal "" :type (or string pathname))
  (cursor-path "" :type (or string pathname)))

(defun cursor-value (subscriber)
  "The last sequence number SUBSCRIBER has acknowledged (0 if it has never
   delivered)."
  (let ((path (subscriber-cursor-path subscriber)))
    (if (probe-file path)
        (with-open-file (in path :if-does-not-exist nil)
          (or (and in (let ((v (read in nil nil)))
                        (and (integerp v) (>= v 0) v)))
              0))
        0)))

(defun (setf cursor-value) (seq subscriber)
  (with-open-file (out (subscriber-cursor-path subscriber)
                       :direction :output :if-exists :supersede
                       :if-does-not-exist :create)
    (prin1 seq out)
    (finish-output out))
  seq)

(defun pending-count (subscriber)
  "How many records are deliverable to SUBSCRIBER right now, without delivering
   them or moving the cursor (read-only)."
  (max 0 (- (wal:scan (subscriber-wal subscriber))
            (cursor-value subscriber))))

(defun deliver-pending (subscriber)
  "Deliver every record with seq greater than SUBSCRIBER's cursor, in order, and
   advance the cursor to the last delivered seq. Returns the list of WAL:RECORD
   delivered (empty if nothing is pending). Idempotent."
  (let* ((cursor (cursor-value subscriber))
         (records (wal:read-records (subscriber-wal subscriber) :after cursor)))
    (when records
      (setf (cursor-value subscriber)
            (wal:record-seq (car (last records)))))
    records))
