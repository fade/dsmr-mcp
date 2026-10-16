;;;; tests/hermetic/worker-client-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Unit tests for how workers are started and brought back: the secret a
;;;; worker authenticates with, the runtime a saved world is resumed with, how
;;;; a failed start is classified, and the resume handshake budget.
;;;;
;;;; The only processes started here are runtimes refusing a core that is not
;;;; one, which exit at once.

(defpackage #:dsmr-mcp/tests/hermetic/worker-client-test
  (:use #:cl #:zebra)
  (:local-nicknames (#:wc #:dsmr-mcp/src/hermetic/worker-client))
  (:import-from #:dsmr-mcp/src/hermetic/worker-client
                #:make-worker #:spawn-worker #:resume-worker
                #:worker-spawn-failed #:worker-spawn-failed-kind
                #:worker-spawn-failure-final-p
                #:runtime-identity #:resume-runtime
                #:*worker-resume-timeout* #:*resolved-worker-resume-timeout*
                #:resolve-worker-resume-timeout
                #:effective-worker-resume-timeout)
  (:import-from #:sb-posix)
  (:import-from #:uiop))

(in-package #:dsmr-mcp/tests/hermetic/worker-client-test)

;;; ---------------------------------------------------------------------------
;;; Helpers
;;; ---------------------------------------------------------------------------

(defun %temp-file (bytes)
  "A new temporary file holding BYTES zero bytes; returns its native path."
  (let ((path (uiop:native-namestring
               (uiop:with-temporary-file (:pathname p :keep t :type "core") p))))
    (with-open-file (out path :direction :output :element-type '(unsigned-byte 8)
                              :if-exists :supersede)
      (write-sequence (make-array bytes :element-type '(unsigned-byte 8)
                                        :initial-element 0)
                      out))
    path))

;;; ---------------------------------------------------------------------------
;;; Secrets
;;; ---------------------------------------------------------------------------

(define-test servers-started-alike-give-their-workers-different-secrets
  "Every server starts from the same image with the same random state, so a
secret drawn from that state would repeat from one server to the next. Two
draws made from identical random states still differ."
  (let ((a (let ((*random-state* (sb-ext:seed-random-state 7)))
             (wc::%generate-worker-secret)))
        (b (let ((*random-state* (sb-ext:seed-random-state 7)))
             (wc::%generate-worker-secret))))
    (is = 32 (length a))
    (true (every (lambda (ch) (digit-char-p ch 16)) a))
    (false (string= a b) "two servers would share the secret ~A" a)))

;;; ---------------------------------------------------------------------------
;;; The runtime a saved world is resumed with
;;; ---------------------------------------------------------------------------

(define-test a-resume-prefers-the-runtime-that-wrote-the-core
  "The recorded runtime is used while it is the same file; when it is gone
and this server's own executable is that file, the server's executable is
used; a different file at the recorded path is tried; with nothing that
matches and nothing at the path, there is no runtime to use."
  (let ((own (format nil "/proc/~D/exe" (sb-posix:getpid)))
        (sh "/bin/sh"))
    (multiple-value-bind (path basis)
        (resume-runtime (make-worker :runtime-path sh
                                     :runtime-identity (runtime-identity sh)))
      (is string= sh path)
      (is eq :recorded basis))
    (multiple-value-bind (path basis)
        (resume-runtime (make-worker :runtime-path "/nonexistent-runtime/sbcl"
                                     :runtime-identity (runtime-identity own)))
      (is string= own path)
      (is eq :server basis))
    (multiple-value-bind (path basis)
        (resume-runtime (make-worker :runtime-path sh
                                     :runtime-identity (list 0 0 0 0)))
      (is string= sh path)
      (is eq :changed basis))
    (multiple-value-bind (path basis)
        (resume-runtime (make-worker :runtime-path "/nonexistent-runtime/sbcl"
                                     :runtime-identity (list 0 0 0 0)))
      (false path)
      (is eq :gone basis))
    (multiple-value-bind (path basis) (resume-runtime (make-worker))
      (true (and path (char= #\/ (char path 0))) "~A" path)
      (is eq :unrecorded basis))))

(define-test a-world-whose-runtime-is-gone-fails-for-good
  "Resuming a world whose runtime is gone, with nothing else the same file,
fails as final with the kind runtime-gone, and starts nothing."
  (let ((core (%temp-file 16)))
    (unwind-protect
         (let ((condition
                 (handler-case
                     (progn
                       (resume-worker
                        (make-worker :id 1 :hibernate-core-path core
                                     :runtime-path "/nonexistent-runtime/sbcl"
                                     :runtime-identity (list 0 0 0 0)))
                       nil)
                   (worker-spawn-failed (c) c))))
           (true condition)
           (is eq :runtime-gone (and condition (worker-spawn-failed-kind condition)))
           (true (worker-spawn-failure-final-p condition)))
      (ignore-errors (delete-file core)))))

;;; ---------------------------------------------------------------------------
;;; Classifying a failed start
;;; ---------------------------------------------------------------------------

(define-test what-a-runtime-prints-on-refusing-a-core-is-recognised
  "The messages a runtime prints when it refuses a core are recognised, and a
runtime that could not get memory is not, since that may pass."
  (true (wc::%core-rejection-p
         "fatal error encountered in SBCL pid 1:
premature end of core file"))
  (true (wc::%core-rejection-p
         "fatal error encountered in SBCL pid 1:
invalid magic number in core: 949f should have been 5342434c"))
  (true (wc::%core-rejection-p
         "fatal error encountered in SBCL pid 1:
core was built for runtime \"a\" but this is \"b\""))
  (false (wc::%core-rejection-p
          "fatal error encountered in SBCL pid 1:
Can't allocate 8589934592 bytes for dynamic space"))
  (false (wc::%core-rejection-p "")))

(define-test a-core-the-runtime-refuses-is-final-and-other-failures-are-not
  "A runtime refusing a file that is no core ends the spawn with the kind
rejected, which is final. A timeout, a launch failure and a process killed
while loading are not final."
  (let ((core (%temp-file 4096)))
    (unwind-protect
         (let ((condition (handler-case (progn (spawn-worker :hibernated-core core) nil)
                            (worker-spawn-failed (c) c))))
           (true condition)
           (is eq :rejected (and condition (worker-spawn-failed-kind condition))
               "~A" condition)
           (true (worker-spawn-failure-final-p condition)))
      (ignore-errors (delete-file core))))
  (dolist (kind '(:timeout :launch :exited :connect :auth :other))
    (false (worker-spawn-failure-final-p
            (make-condition 'worker-spawn-failed :kind kind :message "x"))
           "~A was taken as final" kind))
  (false (worker-spawn-failure-final-p (make-condition 'simple-error))))

(define-test the-resume-handshake-budget-is-read-when-resolved
  "The resume handshake budget defaults to 120 s, reads
DSMR_WORKER_RESUME_TIMEOUT when resolved, and a bound special wins."
  (let ((saved-env (sb-posix:getenv "DSMR_WORKER_RESUME_TIMEOUT"))
        (saved *resolved-worker-resume-timeout*))
    (unwind-protect
         (let ((*worker-resume-timeout* nil))
           (sb-posix:unsetenv "DSMR_WORKER_RESUME_TIMEOUT")
           (setf *resolved-worker-resume-timeout* nil)
           (is = 120 (effective-worker-resume-timeout))
           (sb-posix:setenv "DSMR_WORKER_RESUME_TIMEOUT" "300" 1)
           (is = 300 (resolve-worker-resume-timeout))
           (is = 300 (effective-worker-resume-timeout))
           (let ((*worker-resume-timeout* 7))
             (is = 7 (resolve-worker-resume-timeout))))
      (setf *resolved-worker-resume-timeout* saved)
      (if saved-env
          (sb-posix:setenv "DSMR_WORKER_RESUME_TIMEOUT" saved-env 1)
          (sb-posix:unsetenv "DSMR_WORKER_RESUME_TIMEOUT")))))
