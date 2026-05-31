;;;; tests/scaffold/project-scaffold-envrc-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Parity tests for the scaffold manifest's .envrc entry (ENVRC-02/03):
;;;; the entry exists, carries the required DSMR_*/SLYNK_* exports, and
;;;; survives render2 with no unresolved {{}} placeholders (the verbatim
;;;; shell ${VAR:-default} syntax must pass through untouched).

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/scaffold/project-scaffold-envrc-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/scaffold/project-scaffold-envrc-test
  (:use #:cl #:parachute)
  (:import-from #:dsmr-mcp/src/project-scaffold-core
                #:plan-scaffold))

(in-package #:dsmr-mcp/tests/scaffold/project-scaffold-envrc-test)

(defun %manifest-envrc ()
  "Return the .envrc content from a freshly planned scaffold manifest."
  (let ((manifest (plan-scaffold :name "envrc-test"
                                 :description "envrc test"
                                 :author "Tester"
                                 :license "MIT"
                                 :copyright "Tester"
                                 :year "2026"
                                 :destination "scaffolds")))
    (cdr (assoc ".envrc" manifest :test #'string=))))

(define-test scaffold-manifest-includes-envrc
  "The scaffold manifest carries a .envrc entry."
  (true (%manifest-envrc) ".envrc entry missing from manifest"))

(define-test envrc-has-no-unresolved-placeholders
  "The .envrc entry has no {{...}} placeholder (verbatim shell syntax survives)."
  (false (search "{{" (%manifest-envrc))
         ".envrc has an unresolved {{...}} placeholder"))

(define-test envrc-has-required-exports
  "The .envrc entry carries the required DSMR_*/SLYNK_* exports."
  (let ((envrc (%manifest-envrc)))
    (true (search "DSMR_MODE" envrc) ".envrc missing DSMR_MODE")
    (true (search "SLYNK_HOST" envrc) ".envrc missing SLYNK_HOST")
    (true (search "SLYNK_PORT" envrc) ".envrc missing SLYNK_PORT")
    (true (search "DSMR_SLYNK_ATTACH" envrc) ".envrc missing DSMR_SLYNK_ATTACH")
    (true (search "LISP_WORKSPACE" envrc) ".envrc missing LISP_WORKSPACE")))
