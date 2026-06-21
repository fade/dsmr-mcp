;;;; tests/bus/cursor-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Parachute tests for the per-subscriber delivery cursor. The contract: a
;;;; subscriber receives every record past its cursor exactly once, catch-up after
;;;; an absence delivers the backlog, and re-delivery is idempotent so a duplicate
;;;; wake never replays a message.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/bus/cursor-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/bus/cursor-test
  (:use #:cl #:parachute)
  (:local-nicknames (#:wal #:dsmr-mcp/src/bus/wal)
                    (#:cursor #:dsmr-mcp/src/bus/cursor)))

(in-package #:dsmr-mcp/tests/bus/cursor-test)

(defmacro with-sub ((var) &body body)
  "Bind VAR to a fresh subscriber over a temp WAL + temp cursor, cleaned up after."
  (let ((wal-path (gensym)) (cur-path (gensym)))
    `(let ((,wal-path (uiop:with-temporary-file (:pathname p :keep t :type "wal") p))
           (,cur-path (uiop:with-temporary-file (:pathname p :keep t :type "cursor") p)))
       (let ((,var (cursor:make-subscriber "sub-1" ,wal-path ,cur-path)))
         (unwind-protect (progn ,@body)
           (ignore-errors (delete-file ,wal-path))
           (ignore-errors (delete-file ,cur-path)))))))

(defun publish (sub n &optional (body "x"))
  "Append records (last-seq+1 .. last-seq+n) to the subscriber's WAL."
  (let ((start (wal:scan (cursor:subscriber-wal sub))))
    (loop for i from 1 to n
          do (wal:append-record (cursor:subscriber-wal sub) (+ start i) body))))

(define-test fresh-cursor-is-zero
  "A subscriber that has never delivered has cursor 0."
  (with-sub (s)
    (is = 0 (cursor:cursor-value s))))

(define-test delivers-all-then-advances
  "First delivery hands back every record and advances the cursor to the last."
  (with-sub (s)
    (publish s 5)
    (let ((recs (cursor:deliver-pending s)))
      (is equal '(1 2 3 4 5) (mapcar #'wal:record-seq recs))
      (is = 5 (cursor:cursor-value s)))))

(define-test idempotent-redelivery
  "A second delivery with nothing new returns nothing and leaves the cursor put."
  (with-sub (s)
    (publish s 3)
    (cursor:deliver-pending s)
    (let ((again (cursor:deliver-pending s)))
      (is = 0 (length again))
      (is = 3 (cursor:cursor-value s)))))

(define-test catch-up-after-absence
  "Records published while the subscriber was away are all delivered on return."
  (with-sub (s)
    (publish s 2)
    (cursor:deliver-pending s)                 ; cursor -> 2
    (publish s 3)                              ; 3,4,5 arrive while "asleep"
    (let ((recs (cursor:deliver-pending s)))
      (is equal '(3 4 5) (mapcar #'wal:record-seq recs))
      (is = 5 (cursor:cursor-value s)))))

(define-test delivers-bodies
  "Delivered records carry their payloads intact."
  (with-sub (s)
    (wal:append-record (cursor:subscriber-wal s) 1 "first")
    (wal:append-record (cursor:subscriber-wal s) 2 "second")
    (let ((recs (cursor:deliver-pending s)))
      (is equal '("first" "second") (mapcar #'wal:record-body-string recs)))))

(define-test pending-count-is-read-only
  "PENDING-COUNT reports the backlog without delivering or moving the cursor."
  (with-sub (s)
    (publish s 4)
    (is = 4 (cursor:pending-count s))
    (is = 0 (cursor:cursor-value s))           ; unchanged by the observation
    (cursor:deliver-pending s)
    (is = 0 (cursor:pending-count s))))