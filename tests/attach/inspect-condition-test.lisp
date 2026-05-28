;;;; tests/attach/inspect-condition-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Integration tests for the dispatcher-side inspect-condition verb (VERB-19),
;;;; attached path.  Covers:
;;;;   - Structural portability guard: injected form carries no DSMR-MCP symbols
;;;;     across the Slynk wire (the handler-case condition-variable leak class
;;;;     that caused commit 6ca196d).
;;;;   - Not-at-break: returns a structured condition-p=false result, not isError.
;;;;   - Live-break with a project-package custom condition: returns condition_type
;;;;     and non-empty slots with known slot names and values.
;;;;   - Type hierarchy: hierarchy vector contains the custom condition's class
;;;;     name and a standard ancestor.
;;;;
;;;; Uses the in-process Slynk fixture (with-temporary-slynk-listener) so tests
;;;; exercise the real slime-eval path without an external image.
;;;;
;;;; NOTE: The in-process fixture shares dsmr-mcp's package namespace, so it
;;;; CANNOT catch injected-form package-leak bugs.  condition-form-is-portable is
;;;; the ONLY automated defense against the NETWORK_ERROR handler-case variable
;;;; leak class for real attached images.

;;; Package evolution guard: delete prior definition before redefining so
;;; the defpackage is always fresh in warm images.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/attach/inspect-condition-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/attach/inspect-condition-test
  (:use #:cl #:parachute)
  (:import-from #:dsmr-mcp/tests/support/slynk-fixture
                #:with-temporary-slynk-listener)
  (:import-from #:dsmr-mcp/src/attach/dispatch
                #:repl-eval-tool
                #:repl-eval-tool-slynk-conn)
  (:import-from #:dsmr-mcp/src/state
                #:make-session
                #:*current-session-id*
                #:get-tool-instance)
  ;; inspect-condition symbols imported once the source package exists (Task 2).
  ;; At Task-1 compile time the package does not exist; they are accessed via
  ;; find-symbol in the portability guard test to keep this file loadable alone.
  )

(in-package #:dsmr-mcp/tests/attach/inspect-condition-test)

;;; ---------------------------------------------------------------------------
;;; Portability guard helpers
;;;
;;; Copied verbatim from tests/code-intelligence/load-system-test.lisp lines
;;; 228-247, per the established precedent for structural injected-form guards.
;;; ---------------------------------------------------------------------------

(defun %collect-symbols (form)
  "Flat list of every symbol appearing in FORM (a tree of conses and atoms,
descending into non-string vectors)."
  (let ((acc '()))
    (labels ((walk (x)
               (cond ((and (symbolp x) x) (push x acc))
                     ((consp x) (walk (car x)) (walk (cdr x)))
                     ((and (vectorp x) (not (stringp x))) (map nil #'walk x)))))
      (walk form))
    acc))

(defun %dsmr-package-leaks (form)
  "Symbols in FORM whose home package name contains \"DSMR-MCP\" — symbols that
cannot be READ in an attached image that does not have dsmr-mcp loaded."
  (remove-duplicates
   (remove-if-not
    (lambda (s)
      (let ((pkg (symbol-package s)))
        (and pkg (search "DSMR-MCP" (package-name pkg)))))
    (%collect-symbols form))))

;;; ---------------------------------------------------------------------------
;;; Custom condition fixture for the live-break tests
;;;
;;; Defined here (project-package condition with a user-defined slot) so the
;;; slot-drill assertions have a known slot name and value to check.
;;; The slot carries a reader and :initarg so the test can supply a known value.
;;; ---------------------------------------------------------------------------

(define-condition test-custom-condition (error)
  ((detail :initarg :detail
           :reader test-custom-condition-detail
           :initform "default-detail"))
  (:report (lambda (c s)
             (format s "test-custom-condition: ~A"
                     (test-custom-condition-detail c)))))

;;; ---------------------------------------------------------------------------
;;; Test session helper
;;; ---------------------------------------------------------------------------

(defun %make-attach-session (id conn)
  "Create a test session for attached-mode tests and install CONN as the
cached slynk-connection on the repl-eval tool instance.

Returns (values SESSION REPL-TOOL COND-TOOL).
REPL-TOOL has CONN pre-installed so %dispatch-attach-inspect-condition
reuses the already-open fixture connection.
COND-TOOL is the inspect-condition-tool instance for the same session;
it is NIL when the tool class has not been registered yet (Task 1 scaffold)."
  (let* ((session   (make-session :id id :slynk-attach "127.0.0.1:1"))
         (*current-session-id* id)
         (repl-tool  (get-tool-instance session "repl-eval"))
         (cond-tool  (ignore-errors
                       (get-tool-instance session "inspect-condition"))))
    (setf (repl-eval-tool-slynk-conn repl-tool) conn)
    (values session repl-tool cond-tool)))

;;; ---------------------------------------------------------------------------
;;; Structural portability guard
;;;
;;; These tests check the emitted sexp statically — no Slynk connection
;;; required.  They are the ONLY automated defense against the package-leak
;;; NETWORK_ERROR class for real attached images.
;;;
;;; The guard is deferred until Task 2 creates the source package, but the
;;; defpackage import section is intentionally omitted here: the builder
;;; symbol is accessed by find-symbol at test time so Task 1 can compile
;;; without the source package existing yet.
;;; ---------------------------------------------------------------------------

(define-test condition-form-is-portable
  "%build-attach-condition-form must emit no symbol from a DSMR-MCP-internal
package for either the live-break (nil object-id) or the held-object branch.
A leaked handler-case condition variable breaks the remote READ in a real
attached image — this was the root cause of commit 6ca196d."
  (let* ((pkg   (find-package "DSMR-MCP/SRC/TOOLS/INSPECT-CONDITION"))
         (build (when pkg (find-symbol "%BUILD-ATTACH-CONDITION-FORM" pkg))))
    (true pkg "dsmr-mcp/src/tools/inspect-condition package must be loaded")
    (when (and pkg build)
      ;; Live-break branch (nil object-id)
      (is equal '() (%dsmr-package-leaks (funcall build nil nil)))
      ;; Held-object branch (non-nil object-id)
      (is equal '() (%dsmr-package-leaks (funcall build 42 "test-session-01"))))))

;;; ---------------------------------------------------------------------------
;;; Integration tests — stubs filled in Task 3
;;; ---------------------------------------------------------------------------

(define-test condition-not-at-break-returns-structured-nil
  "inspect-condition when not at a break returns a structured condition-p=false
result — no isError."
  (true t))

(define-test condition-at-break-returns-slots-for-custom-condition
  "inspect-condition at a live SLDB break returns condition_type and non-empty
slots for a project-package custom condition with a known slot value."
  (true t))

(define-test condition-reports-type-hierarchy
  "inspect-condition at a live SLDB break includes a type hierarchy vector
containing the custom condition class name and at least one standard ancestor."
  (true t))
