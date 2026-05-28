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
  (:import-from #:dsmr-mcp/tests/support/portability-guard
                #:dsmr-package-leaks-in)
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
  (is equal '() (dsmr-package-leaks-in (%build-attach-thread-form nil nil)))
  (is equal '() (dsmr-package-leaks-in (%build-attach-thread-form 42 t))))

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

(defun %make-fake-thread-name-form (fake-name)
  "Return a sexp shaped like %build-attach-thread-form's per-thread inner
let* + push, but with the thread-name call replaced by a constant FAKE-NAME.
Lets the test exercise the form's name-coercion logic without depending on
a bordeaux-threads implementation that accepts non-string :name arguments."
  (flet ((cs (n) (intern n (find-package :common-lisp-user))))
    (let ((s-nm-raw (cs "%DSMR-MCP-ATTACH-THR-NM-RAW"))
          (s-nm     (cs "%DSMR-MCP-ATTACH-THR-NM")))
      `(let* ((,s-nm-raw ',fake-name)
              (,s-nm     (handler-case
                             (cond ((stringp ,s-nm-raw) ,s-nm-raw)
                                   ((null   ,s-nm-raw) "unnamed")
                                   (t (princ-to-string ,s-nm-raw)))
                           (error () "unnamed"))))
         (map 'string #'identity ,s-nm)))))

(define-test thread-list-coerces-non-string-name-defensively
  "inspect-thread's name-coercion logic must produce a string for any
bordeaux-threads:thread-name return value, including symbols and other
printable objects.  Earlier code passed the raw value straight to
(map 'string #'identity ...), which signals TYPE-ERROR on a symbol and
aborts the whole dolist mid-loop — surfacing as NETWORK_ERROR from a
real attached image.

Exercises the form's coercion logic in isolation by EVALing a fragment
shaped like %build-attach-thread-form's per-thread body, with the BT
thread-name call replaced by a constant.  Asserts a string result for
every input type the form might encounter."
  ;; String passes through untouched.
  (let ((result (eval (%make-fake-thread-name-form "string-name"))))
    (is equal "string-name" result))
  ;; NIL → "unnamed".
  (let ((result (eval (%make-fake-thread-name-form nil))))
    (is equal "unnamed" result))
  ;; Symbol → string via princ-to-string (not type-error).
  (let ((result (eval (%make-fake-thread-name-form 'foo-thread))))
    (true (stringp result))
    (true (search "FOO-THREAD" result)))
  ;; Integer → string.
  (let ((result (eval (%make-fake-thread-name-form 12345))))
    (true (stringp result))
    (is equal "12345" result)))

(define-test attached-backtrace-captures-frames
  "inspect-thread with backtrace requested returns a well-formed result —
no isError — with a top-level 'eval_thread_frames' key (present even when
empty under #-sbcl) and per-thread entries that no longer carry a per-entry
'frames' key.  The single backtrace snapshot belongs at the top of the
response because it is one snapshot of the eval thread's stack."
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
            (true (plusp (length threads)))
            ;; Per-thread entries must NOT carry a 'frames' key — the
            ;; snapshot is at the response top level now.
            (dolist (thr (coerce threads 'list))
              (false (gethash "frames" thr)
                     "per-thread entry must not carry 'frames' — \
that misled callers about which thread the frames belonged to")))
          ;; eval_thread_frames must be present when backtrace was requested.
          (true (nth-value 1 (gethash "eval_thread_frames" result))
                "eval_thread_frames key must be present when backtrace=t"))))))

(define-test attached-no-backtrace-omits-frames-key
  "inspect-thread without backtrace requested must NOT carry an
'eval_thread_frames' key at all — that lets the caller distinguish 'did
not ask for backtrace' from 'asked and got an empty vector'."
  (with-temporary-slynk-listener (conn)
    (multiple-value-bind (session repl-tool thr-tool)
        (%make-attach-session "test-thr-no-bt-01" conn)
      (declare (ignore session thr-tool))
      (let* ((params (make-hash-table :test 'equal))
             (result (%dispatch-attach-inspect-thread repl-tool nil params)))
        (false (gethash "isError" result))
        (false (nth-value 1 (gethash "eval_thread_frames" result))
               "eval_thread_frames must be absent when backtrace was not \
requested")))))
