;;;; tests/slynk-port-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Zebra tests for the per-project Slynk port derivation module.
;;;; The properties under test are contractual — they are locked-in on the first
;;;; shipped version because the derived value lives in each project's `.envrc`
;;;; and must reproduce exactly on a fresh install or after an SBCL upgrade.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/slynk-port-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/slynk-port-test
  (:use #:cl #:zebra)
  (:import-from #:dsmr-mcp/src/slynk-port
                #:derive-slynk-port
                #:fnv1a-32
                #:+slynk-port-base+
                #:+slynk-port-span+))

(in-package #:dsmr-mcp/tests/slynk-port-test)

;;; FNV-1a correctness (published test vectors) --------------------------------

(define-test fnv1a-32-empty-string
  "FNV-1a of \"\" equals the offset basis — the published identity case."
  (is = 2166136261 (fnv1a-32 "")))

(define-test fnv1a-32-published-vector
  "FNV-1a 32 of \"foobar\" = 0xBF9CF968 = 3214735720, a published test vector."
  (is = 3214735720 (fnv1a-32 "foobar")))

;;; Range constraint -----------------------------------------------------------

(define-test derived-port-in-range
  "The derived port is always in [+slynk-port-base+, 32768) for a typical path."
  (let ((port (derive-slynk-port "/home/fade/SourceCode/lisp/dsmr-mcp/")))
    (true (<= +slynk-port-base+ port) "at or above base")
    (true (< port 32768) "below ephemeral floor")))

(define-test derived-port-range-invariant-many-paths
  "Every path in a representative set yields a port in [base, 32768)."
  (dolist (path (list "/home/fade/SourceCode/lisp/dsmr-mcp/"
                      "/home/fade/SourceCode/lisp/eve-quant/"
                      "/home/fade/SourceCode/lisp/eve-gate/"
                      "/home/fade/SourceCode/lisp/cl-mcp/"
                      "/tmp/scratch/"
                      "/a/"
                      (make-string 200 :initial-element #\a)))
    (let ((port (derive-slynk-port path)))
      (true (<= +slynk-port-base+ port (1- 32768))
            (format nil "port ~A in range for ~A" port path)))))

;;; Determinism ----------------------------------------------------------------

(define-test derived-port-is-deterministic
  "Calling derive-slynk-port twice on the same string returns the same value."
  (let ((path "/home/fade/SourceCode/lisp/dsmr-mcp/"))
    (is = (derive-slynk-port path) (derive-slynk-port path))))

;;; Known-good fixed values (regression lock) ----------------------------------
;;; These values are the published contract. If they change, something broke the
;;; derivation's version-stability guarantee. They were independently verified
;;; by two separate spike runs (002 and 003) producing the same number.

(define-test derived-port-dsmr-mcp-regression
  "The derived port for the dsmr-mcp project path is the known-good value 18709.
This is a regression lock: if this test ever fails, the FNV constants or the
window arithmetic changed — a breaking change for any existing .envrc."
  (is = 18709 (derive-slynk-port "/home/fade/SourceCode/lisp/dsmr-mcp/")))

(define-test derived-port-eve-quant-regression
  "The derived port for eve-quant is the known-good value 29906."
  (is = 29906 (derive-slynk-port "/home/fade/SourceCode/lisp/eve-quant/")))

;;; Decorrelation (near-identical sibling paths) --------------------------------

(define-test sibling-paths-decorrelate
  "Near-identical paths (same directory, different project names) land on
different ports — FNV-1a does not cluster close inputs."
  (let ((ports (mapcar #'derive-slynk-port
                       '("/home/fade/SourceCode/lisp/dsmr-mcp/"
                         "/home/fade/SourceCode/lisp/eve-quant/"
                         "/home/fade/SourceCode/lisp/eve-gate/"
                         "/home/fade/SourceCode/lisp/cl-mcp/"))))
    (is = (length ports) (length (remove-duplicates ports))
        "all four sibling paths yield distinct ports")))

;;; Edge-case input handling ---------------------------------------------------

(define-test derived-port-pathname-argument
  "derive-slynk-port also accepts a pathname object."
  (let ((s (derive-slynk-port "/home/fade/SourceCode/lisp/dsmr-mcp/"))
        (p (derive-slynk-port #p"/home/fade/SourceCode/lisp/dsmr-mcp/")))
    (is = s p "string and pathname yield same port")))

(define-test derived-port-nil-signals-error
  "A NIL project-path signals an error rather than silently hashing as empty."
  (fail (derive-slynk-port nil) error))

(define-test derived-port-empty-signals-error
  "An empty string signals an error."
  (fail (derive-slynk-port "") error))
