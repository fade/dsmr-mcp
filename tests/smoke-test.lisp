;;;; tests/smoke-test.lisp
;;;;
;;;; Trivial smoke test so `(asdf:test-system :dsmr-mcp)` exits green
;;;; before the real test suites land in later phases.

(defpackage #:dsmr-mcp/tests/smoke-test
  (:use #:cl #:zebra)
  (:import-from #:dsmr-mcp/src/main
                #:version
                #:*default-mode*))

(in-package #:dsmr-mcp/tests/smoke-test)

(define-test version-is-non-empty-string
  (let ((v (version)))
    (true (stringp v))
    (true (plusp (length v)))))

(define-test default-mode-is-attached
  (is eq :attached *default-mode*))
