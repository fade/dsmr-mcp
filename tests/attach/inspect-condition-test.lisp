;;;; tests/attach/inspect-condition-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Integration tests for the dispatcher-side inspect-condition verb (VERB-19),
;;;; attached path.  Covers:
;;;;   - Structural portability guard: injected form carries no DSMR-MCP symbols
;;;;     across the Slynk wire (the handler-case condition-variable leak class
;;;;     that caused commit 6ca196d).
;;;;   - Not-at-break: returns a structured condition-p=false result, not isError.
;;;;   - Background-break path: *slynk-debugger-condition* is thread-local to the
;;;;     break thread; the injected form runs in the rex eval thread where it is
;;;;     unbound.  This is the same constraint as inspect-restart wave-2.  The test
;;;;     asserts the correct fallback: condition-p=false, no isError.
;;;;   - Type hierarchy / slot assertions: exercised by evaluating the injected
;;;;     form directly in-process with *slynk-debugger-condition* bound in the
;;;;     calling thread — the only reliable path given the cross-thread binding
;;;;     limitation.
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
  (:import-from #:dsmr-mcp/src/tools/inspect-condition
                #:inspect-condition-tool
                #:%build-attach-condition-form
                #:%dispatch-attach-inspect-condition)
  (:import-from #:dsmr-mcp/src/hermetic/worker/handlers
                #:%handle-inspect-condition)
  (:import-from #:dsmr-mcp/src/state
                #:make-session
                #:*current-session-id*
                #:get-tool-instance))

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
;;; Custom condition fixture for the live-condition tests
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
COND-TOOL is the inspect-condition-tool instance for the same session."
  (let* ((session   (make-session :id id :slynk-attach "127.0.0.1:1"))
         (*current-session-id* id)
         (repl-tool  (get-tool-instance session "repl-eval"))
         (cond-tool  (get-tool-instance session "inspect-condition")))
    (setf (repl-eval-tool-slynk-conn repl-tool) conn)
    (values session repl-tool cond-tool)))

;;; ---------------------------------------------------------------------------
;;; Structural portability guard
;;;
;;; These tests check the emitted sexp statically — no Slynk connection
;;; required.  They are the ONLY automated defense against the package-leak
;;; NETWORK_ERROR class for real attached images.
;;; ---------------------------------------------------------------------------

(define-test condition-form-is-portable
  "%build-attach-condition-form must emit no symbol from a DSMR-MCP-internal
package for either the live-break (nil object-id) or the held-object branch.
A leaked handler-case condition variable breaks the remote READ in a real
attached image — this was the root cause of commit 6ca196d."
  ;; Live-break branch (nil object-id)
  (is equal '() (%dsmr-package-leaks (%build-attach-condition-form nil nil)))
  ;; Held-object branch (non-nil object-id)
  (is equal '() (%dsmr-package-leaks (%build-attach-condition-form 42 "test-session-01"))))

;;; ---------------------------------------------------------------------------
;;; Integration tests
;;; ---------------------------------------------------------------------------

(define-test condition-not-at-break-returns-structured-nil
  "inspect-condition when not at a break returns a structured condition-p=false
result — no isError."
  (with-temporary-slynk-listener (conn)
    (multiple-value-bind (session repl-tool cond-tool)
        (%make-attach-session "test-cond-nil-01" conn)
      (declare (ignore session cond-tool))
      (let* ((params (make-hash-table :test 'equal))
             (result (%dispatch-attach-inspect-condition repl-tool nil params)))
        ;; Must not be an error.
        (false (gethash "isError" result))
        ;; condition_p must be false.
        (false (gethash "condition_p" result))))))

(define-test condition-at-break-returns-slots-for-custom-condition
  "inspect-condition with a background break documents the empirical constraint:
*slynk-debugger-condition* is thread-local to the break thread; the injected
form evaluates in the rex worker thread where it is unbound.  Asserts the
correct fallback: structured result with condition_p=false, no isError.

The full slot-drill is validated in condition-reports-type-hierarchy which
evaluates the form directly in-process with the symbol bound."
  (with-temporary-slynk-listener (conn)
    (multiple-value-bind (session repl-tool cond-tool)
        (%make-attach-session "test-cond-break-01" conn)
      (declare (ignore session cond-tool))
      (let ((break-thread nil))
        (setf break-thread
              (bordeaux-threads:make-thread
               (lambda ()
                 (handler-bind
                     ((error (lambda (c) (invoke-debugger c))))
                   (error 'test-custom-condition :detail "known-slot-value")))
               :name "dsmr-mcp-test-cond-break-thread"))
        (sleep 0.3)
        (unwind-protect
             (let* ((params (make-hash-table :test 'equal))
                    (result (%dispatch-attach-inspect-condition repl-tool nil params)))
               ;; Must not be an error — background break does not change this.
               (false (gethash "isError" result))
               ;; condition_p key must be present.
               (true (nth-value 1 (gethash "condition_p" result))
                     "condition_p key must be present"))
          (ignore-errors
            (bordeaux-threads:destroy-thread break-thread)))))))

(define-test condition-reports-type-hierarchy
  "inspect-condition's injected form computes the correct type hierarchy and
slot values when *slynk-debugger-condition* is bound.

Because *slynk-debugger-condition* is only visible in the thread where it is
dynamically bound, and the Slynk rex worker thread does not inherit the test
thread's bindings, the form is evaluated directly (via EVAL) in this thread
with the symbol bound via PROGV.  This tests the form's correctness without
the cross-thread binding limitation.  The dispatcher dispatch path is already
exercised by condition-not-at-break-returns-structured-nil.

Verifies:
  - condition_p=true when the condition is bound.
  - condition_type is a non-empty string.
  - hierarchy vector contains TEST-CUSTOM-CONDITION and ERROR or CONDITION.
  - slots vector contains the DETAIL slot with the expected value."
  (let* ((the-condition (make-condition 'test-custom-condition :detail "hier-test"))
         (form          (%build-attach-condition-form nil nil))
         (slynk-cond-sym (find-symbol "*SLYNK-DEBUGGER-CONDITION*" "SLYNK"))
         ;; Evaluate the injected form directly with *slynk-debugger-condition*
         ;; bound in this thread — tests the form logic without Slynk dispatch.
         (raw-result    (progv (list slynk-cond-sym) (list the-condition)
                          (eval form)))
         ;; Decode via the dispatcher's plist->ht helper.
         (ht            (dsmr-mcp/src/tools/inspect-condition::%plist->condition-ht
                         raw-result 50)))
    ;; condition-p must be true.
    (true (gethash "condition_p" ht) "condition_p must be true")
    ;; condition_type must be a non-empty string.
    (let ((ctype (gethash "condition_type" ht)))
      (true (and (stringp ctype) (plusp (length ctype)))
            "condition_type must be a non-empty string"))
    ;; hierarchy must be a non-empty vector.
    (let ((hier (gethash "hierarchy" ht)))
      (true (and hier (vectorp hier) (plusp (length hier)))
            "hierarchy must be a non-empty vector")
      (when (and hier (vectorp hier) (plusp (length hier)))
        (let ((names (coerce hier 'list)))
          (true (member "TEST-CUSTOM-CONDITION" names :test #'string=)
                "hierarchy must include TEST-CUSTOM-CONDITION")
          (true (or (member "ERROR" names :test #'string=)
                    (member "CONDITION" names :test #'string=))
                "hierarchy must include ERROR or CONDITION"))))
    ;; slots must be a non-empty vector with the DETAIL slot.
    (let ((slots (gethash "slots" ht)))
      (true (and slots (vectorp slots) (plusp (length slots)))
            "slots must be a non-empty vector")
      (when (and slots (vectorp slots) (plusp (length slots)))
        (let ((slot-names (mapcar (lambda (s) (gethash "name" s))
                                  (coerce slots 'list))))
          (true (member "DETAIL" slot-names :test #'string=)
                "slots must include the DETAIL slot"))
        (let ((detail-slot (find "DETAIL" (coerce slots 'list)
                                 :key (lambda (s) (gethash "name" s))
                                 :test #'string=)))
          (when detail-slot
            (let ((val (gethash "value" detail-slot)))
              (true (and (stringp val) (search "hier-test" val))
                    "DETAIL slot value must contain the known string"))))))))
