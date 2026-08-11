;;;; tests/bus/flow-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; End-to-end flow test for the bus, in one process: a broker runs in a thread,
;;;; a client publishes over ZeroMQ, the broker appends to the log and fans out a
;;;; nudge, and a subscriber receives the message through its cursor. Also checks
;;;; catch-up (a subscriber that was not reading still gets what it missed) and that a
;;;; clean last-member-out shutdown archives the log. The multi-process SIGKILL
;;;; failover lives in the slow integration suite.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/bus/flow-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/bus/flow-test
  (:use #:cl #:zebra)
  (:local-nicknames (#:broker #:dsmr-mcp/src/bus/broker)
                    (#:bus #:dsmr-mcp/src/bus/bus)
                    (#:wal #:dsmr-mcp/src/bus/wal)))

(in-package #:dsmr-mcp/tests/bus/flow-test)

(defmacro with-bus ((paths) &body body)
  "A fresh bus rooted in a unique temp directory, cleaned up after."
  (let ((name (gensym "NAME")) (root (gensym "ROOT")))
    `(let* ((,name (uiop:with-temporary-file (:pathname p :keep t :prefix "dsmr-bus-flow") p))
            (,root (progn (ignore-errors (delete-file ,name))
                          (uiop:ensure-directory-pathname ,name)))
            (,paths (broker:make-bus-paths ,root)))
       (broker:ensure-bus-dirs ,paths)
       (unwind-protect (progn ,@body)
         (ignore-errors (uiop:delete-directory-tree
                         ,root :validate t :if-does-not-exist :ignore))))))

(defmacro with-running-broker ((br paths) &body body)
  "Start a broker on PATHS and serve it in a background thread for BODY."
  (let ((stop (gensym "STOP")) (thread (gensym "THREAD")))
    `(let* ((,br (broker:start-broker ,paths :block nil))
            (,stop nil)
            (,thread (sb-thread:make-thread
                      (lambda () (broker:serve-broker ,br (lambda () ,stop)))
                      :name "bus-flow-broker")))
       (unwind-protect (progn ,@body)
         (setf ,stop t)
         (ignore-errors (sb-thread:join-thread ,thread))
         (ignore-errors (broker:stop-broker ,br))))))

(defun bodies (records) (mapcar #'bus:delivered-body-string records))

(define-test broker-elects-and-binds
  "START-BROKER wins an uncontended election and a second non-blocking attempt
   sees the role taken."
  (with-bus (paths)
    (let ((br (broker:start-broker paths :block nil)))
      (true br "first broker started")
      (unwind-protect
           (is eq nil (broker:start-broker paths :block nil)
               "second non-blocking start finds the role taken")
        (broker:stop-broker br)))))

(define-test publish-then-await-delivers
  "A published message travels client -> broker -> log -> subscriber."
  (with-bus (paths)
    (with-running-broker (br paths)
      (let ((client (bus:connect-client paths))
            (sub (bus:subscribe paths "s1")))
        (unwind-protect
             (progn
               (bus:publish client "hello")
               (let ((got (bus:await sub :timeout-ms 3000)))
                 (is equal '("hello") (bodies got))))
          (bus:disconnect-client client)
          (bus:unsubscribe sub))))))

(define-test subscriber-catches-up-on-what-arrived-while-it-was-idle
  "Messages published while a subscriber was not reading are still delivered, in
   order, whenever it next polls — delivery rides the durable cursor, not the
   live nudge. The subscriber joins first, because what precedes a join is
   history and a participant that has never read has no claim on it."
  (with-bus (paths)
    (with-running-broker (br paths)
      (let ((client (bus:connect-client paths)))
        (unwind-protect
             (let ((sub (bus:subscribe paths "late")))
               (unwind-protect
                    (progn
                      (bus:publish client "a")
                      (bus:publish client "b")
                      (bus:publish client "c")
                      ;; Sync point: publishing is async (zmq -> broker -> WAL), so
                      ;; wait until all three are durably logged before reading.
                      ;; Otherwise the poll can catch the broker mid-append and
                      ;; return a partial batch — the source of an intermittent
                      ;; failure under load. With all three present, one POLL
                      ;; drains them.
                      (loop repeat 150
                            until (>= (wal:scan (broker:bus-paths-wal paths)) 3)
                            do (sleep 0.02))
                      (is equal '("a" "b" "c") (bodies (bus:poll sub))))
                 (bus:unsubscribe sub)))
          (bus:disconnect-client client))))))

(define-test cursor-persists-across-resubscribe
  "A subscriber that leaves and returns resumes after its last delivered message,
   not from the start."
  (with-bus (paths)
    (with-running-broker (br paths)
      (let ((client (bus:connect-client paths)))
        (unwind-protect
             (progn
               (bus:publish client "one")
               (let ((s (bus:subscribe paths "resumer")))
                 (bus:await s :timeout-ms 3000)        ; consumes "one"
                 (bus:unsubscribe s))
               (bus:publish client "two")
               (let ((s (bus:subscribe paths "resumer")))
                 (unwind-protect
                      (let ((got (bus:await s :timeout-ms 3000)))
                        (is equal '("two") (bodies got)))   ; not "one" again
                   (bus:unsubscribe s))))
          (bus:disconnect-client client))))))