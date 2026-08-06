;;;; tests/integration/attach/error-context-guard-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Debugger-entry backstop guards, gated out of the fast push suite.
;;;;
;;;; Each define-test below exercises a failure mode that used to reach the
;;;; Slynk debugger in the attached image (a reader error, a serious non-error
;;;; condition, a storage-condition, a bare BREAK).  The backstop must convert
;;;; each into a structured error_context over the rex instead of parking the
;;;; rex worker in the debugger.  To assert that, every test does a full Slynk
;;;; rex round-trip into the attached image — and that round-trip can block
;;;; until its timeout under CI load.  The in-process listener these tests use
;;;; normally runs fast, so this is not a slowness gate: it is a containment
;;;; gate.  A transient rex timeout here (e.g. a slow runner returning a NIL
;;;; error context after the rex deadline) must not redden main, so these live
;;;; in the gated cross-process integration suite rather than the fast
;;;; dsmr-mcp/tests push umbrella.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/integration/attach/error-context-guard-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/integration/attach/error-context-guard-test
  (:use #:cl #:zebra)
  (:import-from #:dsmr-mcp/tests/support/slynk-fixture
                #:with-temporary-slynk-listener)
  (:import-from #:dsmr-mcp/src/attach/dispatch
                #:repl-eval-tool-slynk-conn
                #:%dispatch-attach)
  (:import-from #:dsmr-mcp/src/state
                #:make-session
                #:*current-session-id*
                #:get-tool-instance)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:make-ht))

(in-package #:dsmr-mcp/tests/integration/attach/error-context-guard-test)

;;; Test session helper -------------------------------------------------------
;;; Duplicated here rather than lifted to shared support: this is the
;;; lower-blast-radius default — a self-contained copy keeps the gated leaf
;;; from coupling the fast suite's helper to the integration suite's lifetime.

(defun %make-attach-session (id conn)
  "Create a test session for attached-mode tests and install CONN as the
cached slynk-connection on the repl-eval tool instance.

Returns (values SESSION TOOL) with CONN installed on TOOL's slynk-conn slot
so %dispatch-attach reuses the already-open fixture connection."
  (let* ((session (make-session :id id :slynk-attach "127.0.0.1:1"))
         (*current-session-id* id)
         (tool (get-tool-instance session "repl-eval")))
    (setf (repl-eval-tool-slynk-conn tool) conn)
    (values session tool)))

(defun %attach-error-context (conn session-id code)
  "Dispatch CODE through %dispatch-attach on a fresh test session.
Returns (values ERROR-CONTEXT-HT ERROR-TYPE RESULT-HT)."
  (multiple-value-bind (session tool)
      (%make-attach-session session-id conn)
    (declare (ignore session))
    (let ((res (%dispatch-attach tool (make-ht "code" code))))
      (values (gethash "error_context" res)
              (gethash "error_type" res)
              res))))

(define-test reader-error-returns-error-context
  "Unreadable code text yields a structured error, not a debugger entry.
The READ of the code string runs inside the injected form's guarded region."
  (with-temporary-slynk-listener (conn)
    (multiple-value-bind (ec error-type)
        (%attach-error-context conn "guard-reader-error" "#<unreadable>")
      (false (equal "NETWORK_ERROR" error-type))
      (true ec)
      (true (gethash "condition_type" ec)))))

(define-test non-error-serious-condition-returns-error-context
  "A serious-but-not-error condition (sb-ext:timeout is not an ERROR subtype)
is caught by the widened handler with full restarts context."
  (with-temporary-slynk-listener (conn)
    (multiple-value-bind (ec error-type)
        (%attach-error-context conn "guard-serious-non-error"
                               "(error (make-condition 'sb-ext:timeout))")
      (false (equal "NETWORK_ERROR" error-type))
      (true ec)
      (true (search "TIMEOUT" (gethash "condition_type" ec)))
      ;; Full-context branch: restarts captured with the stack live.
      (let ((restarts (gethash "restarts" ec)))
        (true (vectorp restarts))
        (true (plusp (length restarts)))))))

(define-test storage-condition-returns-minimal-error-context
  "A storage-condition takes the minimal type+message branch — no restarts,
no frames — because consing heavily inside a heap-exhaustion handler can
itself fail and fall through to the debugger."
  (with-temporary-slynk-listener (conn)
    (multiple-value-bind (ec error-type)
        (%attach-error-context conn "guard-storage-condition"
                               "(error (make-condition 'storage-condition))")
      (false (equal "NETWORK_ERROR" error-type))
      (true ec)
      (true (search "STORAGE-CONDITION" (gethash "condition_type" ec)))
      (let ((restarts (gethash "restarts" ec)))
        (true (or (null restarts)
                  (and (vectorp restarts) (zerop (length restarts)))))))))

(define-test break-returns-error-context-without-debugger
  "BREAK bypasses handlers and *debugger-hook* by definition; the
SB-EXT:*INVOKE-DEBUGGER-HOOK* backstop converts it to a minimal error
context instead of parking the rex worker in the debugger."
  (with-temporary-slynk-listener (conn)
    (multiple-value-bind (ec error-type)
        (%attach-error-context conn "guard-break"
                               "(break \"guard-break-test\")")
      (false (equal "NETWORK_ERROR" error-type))
      (true ec)
      (true (search "guard-break-test" (gethash "message" ec))))))
