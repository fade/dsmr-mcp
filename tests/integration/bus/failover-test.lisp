;;;; tests/integration/bus/failover-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Cross-process integration tests for the coordination bus. These spawn a REAL
;;;; detached broker process (the production path) and drive it over ipc:// from
;;;; the test process acting as client and subscriber. They verify the properties
;;;; that only show up across a process boundary:
;;;;
;;;;   - a detached broker comes up and round-trips a message end to end;
;;;;   - a SIGKILLed broker does NOT archive and leaves the log intact, and a
;;;;     successor replays it and continues the sequence with no gap or duplicate
;;;;     (E1 + E2 + the crash half of E3);
;;;;   - a clean SIGTERM by the last member out DOES archive (the clean half of E3).
;;;;
;;;; Gated: each spawn cold-loads the broker subsystem (and libzmq), so the test
;;;; SKIPs cleanly where that environment cannot be built and otherwise FAILs on a
;;;; genuine bring-up problem — the regression signal it exists to catch.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/integration/bus/failover-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/integration/bus/failover-test
  (:use #:cl #:parachute)
  (:local-nicknames (#:broker #:dsmr-mcp/src/bus/broker)
                    (#:bus #:dsmr-mcp/src/bus/bus)
                    (#:wal #:dsmr-mcp/src/bus/wal))
  (:import-from #:dsmr-mcp/tests/integration/support
                #:with-mcp-server-child-or-skip))

(in-package #:dsmr-mcp/tests/integration/bus/failover-test)

;;; ---------------------------------------------------------------- helpers

(defparameter *ready-timeout* 120
  "Seconds to allow a cold-spawned broker to come up and bind its sockets.")

(defun wait-until (predicate &key (timeout 30) (poll 0.2))
  "Poll PREDICATE until it returns true or TIMEOUT seconds pass. Returns the truthy
   value, or NIL on timeout."
  (let ((deadline (+ (get-internal-real-time)
                     (* timeout internal-time-units-per-second))))
    (loop for v = (funcall predicate)
          when v return v
          when (> (get-internal-real-time) deadline) return nil
          do (sleep poll))))

(defun submit-socket-path (paths)
  (merge-pathnames "submit.ipc" (broker:bus-paths-root paths)))

(defun broker-ready-p (paths)
  "A broker is ready once it holds the election lock and has bound its intake."
  (and (broker:broker-running-p paths)
       (probe-file (submit-socket-path paths))))

(defun spawn-ready-broker (paths &key (block t))
  "Spawn a detached broker and wait until it is serving. Returns the process."
  (let ((proc (broker:spawn-broker paths :block block)))
    (unless (wait-until (lambda () (broker-ready-p paths)) :timeout *ready-timeout*)
      (error "broker did not become ready within ~Ds" *ready-timeout*))
    proc))

(defun bodies (records) (mapcar #'bus:delivered-body-string records))

(defun archive-files (paths)
  (directory (merge-pathnames "bus.wal.archive-*" (broker:bus-paths-root paths))))

(defmacro with-temp-bus ((paths) &body body)
  (let ((name (gensym)) (root (gensym)))
    `(let* ((,name (uiop:with-temporary-file (:pathname p :keep t :prefix "dsmr-bus-it") p))
            (,root (progn (ignore-errors (delete-file ,name))
                          (uiop:ensure-directory-pathname ,name)))
            (,paths (broker:make-bus-paths ,root)))
       (broker:ensure-bus-dirs ,paths)
       (unwind-protect (progn ,@body)
         (ignore-errors (uiop:delete-directory-tree
                         ,root :validate t :if-does-not-exist :ignore))))))

(defmacro with-killable ((proc-var spawn-form) &body body)
  "Bind PROC-VAR to a spawned process for BODY; SIGKILL it on the way out unless
   the body already reaped it."
  `(let ((,proc-var ,spawn-form))
     (declare (ignorable ,proc-var))
     (unwind-protect (progn ,@body)
       (ignore-errors (uiop:terminate-process ,proc-var :urgent t)))))

;;; ----------------------------------------------------------------- tests

(define-test detached-broker-round-trip
  "A spawned detached broker round-trips a message: client publish -> subscriber."
  (with-mcp-server-child-or-skip
    (with-temp-bus (paths)
      (with-killable (proc (spawn-ready-broker paths :block nil))
        (let ((client (bus:connect-client paths))
              (sub (bus:subscribe paths "it-sub")))
          (unwind-protect
               (progn
                 (bus:publish client "hello-across-processes")
                 (is equal '("hello-across-processes")
                     (bodies (bus:await sub :timeout-ms 5000))))
            (bus:disconnect-client client)
            (bus:unsubscribe sub)))))))

(define-test crash-failover-preserves-wal
  "A SIGKILLed broker neither archives nor corrupts the log; a successor replays
   it and continues the sequence with no gap or duplicate."
  (with-mcp-server-child-or-skip
    (with-temp-bus (paths)
      (let ((client (bus:connect-client paths))
            (sub (bus:subscribe paths "it-sub")))
        (unwind-protect
             (progn
               ;; broker A serves three messages
               (let ((a (spawn-ready-broker paths :block nil)))
                 (dolist (m '("a" "b" "c")) (bus:publish client m))
                 (is equal '("a" "b" "c")
                     (bodies (bus:await sub :timeout-ms 5000)))
                 ;; crash A
                 (uiop:terminate-process a :urgent t)
                 (uiop:wait-process a))
               ;; the crash must not have archived, and the log must survive
               (is = 0 (length (archive-files paths)) "a crash does not archive")
               (is = 3 (length (wal:read-records (broker:bus-paths-wal paths)))
                   "log survives the crash for replay")
               ;; a successor takes over and continues the sequence
               (with-killable (b (spawn-ready-broker paths :block nil))
                 (dolist (m '("d" "e")) (bus:publish client m))
                 (is equal '("d" "e") (bodies (bus:await sub :timeout-ms 5000)))
                 (is equal '(1 2 3 4 5)
                     (mapcar #'wal:record-seq
                             (wal:read-records (broker:bus-paths-wal paths)))
                     "sequence is continuous across the failover")))
          (bus:disconnect-client client)
          (bus:unsubscribe sub))))))

(define-test clean-shutdown-archives
  "When the broker is the last member out, a clean SIGTERM rotates the log to an
   archive."
  (with-mcp-server-child-or-skip
    (with-temp-bus (paths)
      (let ((proc (spawn-ready-broker paths :block nil)))
        (unwind-protect
             (progn
               ;; publish, then drop the client's membership so the broker is the
               ;; last member out
               (let ((client (bus:connect-client paths)))
                 (bus:publish client "seal-me")
                 (wait-until (lambda ()
                               (plusp (wal:scan (broker:bus-paths-wal paths))))
                             :timeout 5)
                 (bus:disconnect-client client))
               ;; clean shutdown (SIGTERM) -> last member archives
               (uiop:terminate-process proc)      ; SIGTERM, not urgent
               (uiop:wait-process proc)
               (is eq t (and (wait-until (lambda () (plusp (length (archive-files paths))))
                                         :timeout 10)
                             t)
                   "clean last-member-out shutdown archived the log"))
          (ignore-errors (uiop:terminate-process proc :urgent t)))))))
