;;;; tests/hermetic/hibernate-helpers-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Unit tests for the parts of a worker's save and resume that need no
;;;; worker: the refusal word for a fork that failed.

(defpackage #:dsmr-mcp/tests/hermetic/hibernate-helpers-test
  (:use #:cl #:zebra)
  (:local-nicknames (#:hibernate #:dsmr-mcp/src/hermetic/worker/hibernate))
  (:import-from #:dsmr-mcp/src/hermetic/worker/hibernate))

(in-package #:dsmr-mcp/tests/hermetic/hibernate-helpers-test)

;;; ---------------------------------------------------------------------------
;;; A fork that fails
;;; ---------------------------------------------------------------------------

(define-test a-fork-that-fails-for-memory-is-not-reported-as-threads
  "SBCL's refusal to fork with other threads running reads has-threads; any
other fork failure reads fork-failed."
  (is string= "has-threads"
      (hibernate::%fork-refusal-token
       (make-condition 'simple-error
                       :format-control "Cannot fork with multiple threads running.")))
  (is string= "fork-failed"
      (hibernate::%fork-refusal-token
       (make-condition 'simple-error
                       :format-control "fork(2) failed: Cannot allocate memory"))))
