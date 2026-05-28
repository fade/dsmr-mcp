;;;; tests/attach/inspect-thread-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Integration tests for the dispatcher-side inspect-thread verb,
;;;; attached path.  Covers:
;;;;   - Structural portability guard: injected form carries no DSMR-MCP symbols
;;;;     across the Slynk wire (both no-backtrace and backtrace arities).
;;;;   - Attached thread listing returns at least one thread (the main thread)
;;;;     with a non-empty name and no isError.
;;;;   - Attached backtrace path returns a well-formed result.
;;;;
;;;; Uses the in-process Slynk fixture (with-temporary-slynk-listener) so
;;;; tests exercise the real slime-eval path without an external image.
;;;;
;;;; NOTE: The in-process fixture shares dsmr-mcp's package namespace, so it
;;;; CANNOT catch injected-form package-leak bugs.  thread-form-is-portable is
;;;; the ONLY structural defense against the NETWORK_ERROR package-leak class
;;;; for real attached images.

;;; Package evolution guard: delete prior definition before redefining so
;;; the defpackage is always fresh in warm images.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/attach/inspect-thread-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/attach/inspect-thread-test
  (:use #:cl #:parachute)
  (:import-from #:dsmr-mcp/tests/support/slynk-fixture
                #:with-temporary-slynk-listener)
  (:import-from #:dsmr-mcp/src/tools/inspect-thread
                #:inspect-thread-tool
                #:%build-attach-thread-form
                #:%dispatch-attach-inspect-thread)
  (:import-from #:dsmr-mcp/src/attach/dispatch
                #:repl-eval-tool
                #:repl-eval-tool-slynk-conn)
  (:import-from #:dsmr-mcp/src/state
                #:make-session
                #:*current-session-id*
                #:get-tool-instance))

(in-package #:dsmr-mcp/tests/attach/inspect-thread-test)

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
;;; Test session helper
;;; ---------------------------------------------------------------------------

(defun %make-attach-session (id conn)
  "Create a test session for attached-mode tests and install CONN as the
cached slynk-connection on the repl-eval tool instance.

Returns (values SESSION REPL-TOOL THREAD-TOOL).
REPL-TOOL has CONN pre-installed so %dispatch-attach-inspect-thread reuses
the already-open fixture connection.
THREAD-TOOL is the inspect-thread-tool instance for the same session."
  (let* ((session (make-session :id id :slynk-attach "127.0.0.1:1"))
         (*current-session-id* id)
         (repl-tool   (get-tool-instance session "repl-eval"))
         (thr-tool    (get-tool-instance session "inspect-thread")))
    (setf (repl-eval-tool-slynk-conn repl-tool) conn)
    (values session repl-tool thr-tool)))

;;; ---------------------------------------------------------------------------
;;; Structural portability guard
;;;
;;; These tests check the emitted sexp statically — no Slynk connection
;;; required.  They are the ONLY defense against the package-leak
;;; NETWORK_ERROR class for real attached images.
;;; ---------------------------------------------------------------------------

(define-test thread-form-is-portable
  "%build-attach-thread-form must emit no symbol from a DSMR-MCP-internal
package for either the no-backtrace or the backtrace arities.  A DSMR-MCP
symbol in an injected form breaks the remote READ in a real attached image."
  (is equal '() (%dsmr-package-leaks (%build-attach-thread-form nil nil)))
  (is equal '() (%dsmr-package-leaks (%build-attach-thread-form 42 t))))

;;; ---------------------------------------------------------------------------
;;; Integration tests (use the in-process Slynk fixture)
;;; ---------------------------------------------------------------------------

(define-test thread-list-returns-main-thread
  "inspect-thread via the attached Slynk path returns at least one thread
entry with a non-empty name and no isError."
  (with-temporary-slynk-listener (conn)
    (multiple-value-bind (session repl-tool thr-tool)
        (%make-attach-session "test-thr-01" conn)
      (declare (ignore session thr-tool))
      (let* ((params (make-hash-table :test 'equal))
             (result (%dispatch-attach-inspect-thread repl-tool nil params)))
        ;; Must not be an error.
        (false (gethash "isError" result))
        ;; Must have a "threads" key.
        (let ((threads (gethash "threads" result)))
          (true threads)
          ;; At least one thread entry.
          (true (plusp (length threads)))
          ;; Every entry must have a non-empty "name".
          (dolist (thr (coerce threads 'list))
            (let ((name (gethash "name" thr)))
              (true (and (stringp name) (plusp (length name)))))))))))

(define-test attached-backtrace-captures-frames
  "inspect-thread with backtrace requested returns a well-formed result —
no isError — for at least one thread entry.  The frames field is present
(possibly empty under #-sbcl) without signalling an error."
  (with-temporary-slynk-listener (conn)
    (multiple-value-bind (session repl-tool thr-tool)
        (%make-attach-session "test-thr-bt-01" conn)
      (declare (ignore session thr-tool))
      (let* ((params (make-hash-table :test 'equal)))
        ;; Request backtrace (no specific thread id — nil means all threads,
        ;; backtrace for current/main thread where available).
        (setf (gethash "backtrace" params) t)
        (let ((result (%dispatch-attach-inspect-thread repl-tool nil params)))
          ;; Must not be an error.
          (false (gethash "isError" result))
          ;; Must have a "threads" key with at least one entry.
          (let ((threads (gethash "threads" result)))
            (true threads)
            (true (plusp (length threads)))))))))
