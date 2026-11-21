;;;; tests/release/support-package-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Unit tests of the run-time lookup of the support code's own packages:
;;;; the prefix follows the helper's own package name, a suffix resolves to the
;;;; support package carrying that prefix, and an absent package is reported.

(defpackage #:dsmr-mcp/tests/release/support-package-test
  (:use #:cl #:zebra)
  (:import-from #:dsmr-mcp/src/support-package
                #:support-prefix
                #:support-package
                #:support-symbol-call)
  (:import-from #:dsmr-mcp/src/notify))

(in-package #:dsmr-mcp/tests/release/support-package-test)

(define-test the-support-prefix-is-dsmr-mcp-in-the-test-image
  "Unrenamed, the support packages carry the DSMR-MCP prefix."
  (is string= "DSMR-MCP" (support-prefix)))

(define-test the-prefix-is-the-text-before-src
  "The prefix is the package name up to its first /SRC/, whatever it is."
  (is string= "DSMR-WORKER"
      (dsmr-mcp/src/support-package::%prefix-of "DSMR-WORKER/SRC/SUPPORT-PACKAGE"))
  (is string= "DSMR-MCP"
      (dsmr-mcp/src/support-package::%prefix-of "DSMR-MCP/SRC/SUPPORT-PACKAGE")))

(define-test a-suffix-resolves-to-the-support-package
  "A suffix names the support package carrying the image's prefix."
  (is eq (find-package "DSMR-MCP/SRC/NOTIFY") (support-package "SRC/NOTIFY")))

(define-test a-support-function-is-called-by-suffix-and-name
  "support-symbol-call reaches a function by package suffix and symbol name and
passes its arguments through."
  (is string= "SRC/NOTIFY"
      (support-symbol-call "SRC/SUPPORT-PACKAGE" "%PREFIX-OF" "SRC/NOTIFY"))
  (is string= "A"
      (support-symbol-call "SRC/SUPPORT-PACKAGE" "%PREFIX-OF" "A/SRC/B")))

(define-test an-absent-support-package-is-reported
  "A suffix naming no package gives NIL from support-package, and an error
naming the package from support-symbol-call."
  (false (support-package "SRC/NO-SUCH-PACKAGE"))
  (let ((condition (handler-case
                       (progn (support-symbol-call "SRC/NO-SUCH-PACKAGE" "F") nil)
                     (error (e) e))))
    (true condition "an absent package was called")
    (true (and condition
               (search "DSMR-MCP/SRC/NO-SUCH-PACKAGE" (princ-to-string condition)))
          "~A" condition)))
