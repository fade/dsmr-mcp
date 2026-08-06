;;;; tests/bus/wakeup-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Zebra tests for the level-triggered wakeup watcher. The contract: a
;;;; message already pending when the wait begins returns immediately (no lost
;;;; wake), a genuinely empty wait times out, a message appended mid-wait wakes
;;;; the watcher, and waiting never advances the cursor (observe vs ack stay
;;;; separate).

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/bus/wakeup-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/bus/wakeup-test
  (:use #:cl #:zebra)
  (:local-nicknames (#:wal #:dsmr-mcp/src/bus/wal)
                    (#:cursor #:dsmr-mcp/src/bus/cursor)
                    (#:wakeup #:dsmr-mcp/src/bus/wakeup)))

(in-package #:dsmr-mcp/tests/bus/wakeup-test)

(defmacro with-sub ((var) &body body)
  (let ((wal-path (gensym)) (cur-path (gensym)))
    `(let ((,wal-path (uiop:with-temporary-file (:pathname p :keep t :type "wal") p))
           (,cur-path (uiop:with-temporary-file (:pathname p :keep t :type "cursor") p)))
       (let ((,var (cursor:make-subscriber "sub-1" ,wal-path ,cur-path)))
         (unwind-protect (progn ,@body)
           (ignore-errors (delete-file ,wal-path))
           (ignore-errors (delete-file ,cur-path)))))))

(define-test pre-arm-message-returns-immediately
  "A message already present when the wait begins fires at once — no lost wake."
  (with-sub (s)
    (wal:append-record (cursor:subscriber-wal s) 1 "x")
    (let* ((t0 (wal:now-ms))
           (woke (wakeup:wait-for-message s :timeout-ms 1000))
           (dt (- (wal:now-ms) t0)))
      (is eql 1 woke)
      (true (< dt 200) "returned promptly, did not wait out the timeout"))))

(define-test empty-wait-times-out
  "With nothing pending the wait returns NIL at the deadline."
  (with-sub (s)
    (is eq nil (wakeup:wait-for-message s :timeout-ms 100 :poll-ms 10))))

(define-test append-mid-wait-wakes-watcher
  "A record appended by another thread while the watcher is blocked wakes it."
  (with-sub (s)
    (let ((writer (sb-thread:make-thread
                   (lambda ()
                     (sleep 0.1)
                     (wal:append-record (cursor:subscriber-wal s) 1 "ping")))))
      (let ((woke (wakeup:wait-for-message s :timeout-ms 2000 :poll-ms 10)))
        (sb-thread:join-thread writer)
        (is eql 1 woke)))))

(define-test waiting-does-not-advance-cursor
  "Observe is not ack: a wait leaves the cursor untouched so a later delivery
   still hands back the message."
  (with-sub (s)
    (wal:append-record (cursor:subscriber-wal s) 1 "x")
    (wakeup:wait-for-message s :timeout-ms 1000)
    (is = 0 (cursor:cursor-value s))                 ; unchanged by the wait
    (is = 1 (length (cursor:deliver-pending s)))     ; still deliverable
    (is = 1 (cursor:cursor-value s))))               ; now acked by delivery

(define-test waits-past-already-delivered
  "After the cursor has advanced, the watcher only wakes for records beyond it,
   not for ones already delivered."
  (with-sub (s)
    (wal:append-record (cursor:subscriber-wal s) 1 "x")
    (cursor:deliver-pending s)                        ; cursor -> 1
    (is eq nil (wakeup:wait-for-message s :timeout-ms 100 :poll-ms 10))
    (wal:append-record (cursor:subscriber-wal s) 2 "y")
    (is eql 2 (wakeup:wait-for-message s :timeout-ms 1000))))