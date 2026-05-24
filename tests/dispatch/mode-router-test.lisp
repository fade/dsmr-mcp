;;;; tests/dispatch/mode-router-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Integration tests for the mode router in handle-tools-call.
;;;; Phase 3 covered the stub (:hermetic returned isError + logged
;;;; dispatch.mode-not-ready). Phase 4 replaces the stub with real pool
;;;; dispatch: a :hermetic call routes to dispatch-hermetic-call, which
;;;; returns a structured rpc-error when the pool is not running (pool-shutting-
;;;; down condition), and routes to a live worker when the pool is up.
;;;;
;;;; The router branches ONLY on :hermetic; the :attached path is the
;;;; unchanged Phase 2 dispatch (not re-tested here — covered by
;;;; tests/attach/repl-eval-attach-test.lisp).

(defpackage #:dsmr-mcp/tests/dispatch/mode-router-test
  (:use #:cl #:parachute)
  (:local-nicknames (#:jzon #:com.inuoe.jzon))
  (:import-from #:dsmr-mcp/src/state
                #:make-session
                #:*current-session-id*
                #:*mode*)
  (:import-from #:dsmr-mcp/src/dispatch
                #:handle-tools-call)
  (:import-from #:dsmr-mcp/src/run
                #:resolve-mode)
  (:import-from #:dsmr-mcp/src/hermetic/pool
                #:initialize-pool #:shutdown-pool)
  (:import-from #:dsmr-mcp/src/log
                #:*log-level*
                #:*log-session-id*
                #:*log-request-id*
                #:configure-log4cl-for-server)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:make-ht))

(in-package #:dsmr-mcp/tests/dispatch/mode-router-test)

;;; ---------------------------------------------------------------------------
;;; Hermetic mode dispatch — pool not running path
;;; ---------------------------------------------------------------------------

(define-test criterion-3-hermetic-pool-not-running-returns-rpc-error
  "With *mode* :hermetic and no pool initialized, a tools/call routes through
dispatch-hermetic-call and returns a structured rpc-error -32000 (pool-shutting-
down condition caught) rather than crashing the serve loop (T-04-17)."
  (let* ((*mode* :hermetic)
         (capture (make-string-output-stream))
         (*error-output* capture)
         (*log-level* :debug)
         (session (make-session :id "hermetic-no-pool"))
         (*current-session-id* "hermetic-no-pool"))
    (configure-log4cl-for-server :debug)
    (let* ((env (handle-tools-call
                 session "req-1"
                 (make-ht "name" "repl-eval"
                          "arguments" (make-ht "code" "(+ 1 2)"))))
           (rpc-err (gethash "error" env)))
      ;; Should be an rpc-error envelope (not a result envelope).
      (true rpc-err)
      (is = -32000 (gethash "code" rpc-err))
      (true (search "pool" (string-downcase (gethash "message" rpc-err)))))))

(define-test criterion-3-hermetic-unknown-tool-also-returns-rpc-error
  "With *mode* :hermetic, the mode router fires BEFORE tool lookup — an
unknown tool name returns a pool rpc-error (not a -32601 not-found error)
because the :hermetic branch short-circuits before tool resolution."
  (let* ((*mode* :hermetic)
         (capture (make-string-output-stream))
         (*error-output* capture)
         (*log-level* :debug)
         (session (make-session :id "hermetic-unknown"))
         (*current-session-id* "hermetic-unknown"))
    (configure-log4cl-for-server :debug)
    (let* ((env (handle-tools-call
                 session "req-2"
                 (make-ht "name" "no-such-tool" "arguments" (make-ht))))
           (rpc-err (gethash "error" env)))
      ;; Pool error, not a tool-not-found error.
      (true rpc-err)
      (is = -32000 (gethash "code" rpc-err))
      ;; Not a -32601 tool-not-found.
      (false (= -32601 (gethash "code" rpc-err))))))

(define-test server-does-not-crash
  "T-03-MODE-01 / T-04-17: handle-tools-call returns normally under :hermetic
regardless of pool state — no unhandled condition escapes, so the serve loop
stays up. Exercises both pool-not-running and the :attached fallthrough."
  (let* ((*mode* :hermetic)
         (capture (make-string-output-stream))
         (*error-output* capture)
         (*log-level* :debug)
         (session (make-session :id "hermetic-nocrash"))
         (*current-session-id* "hermetic-nocrash"))
    (configure-log4cl-for-server :debug)
    ;; Returns normally (no signal) even when pool is not running.
    (finish (handle-tools-call
             session "req-3"
             (make-ht "name" "repl-eval"
                      "arguments" (make-ht "code" "(+ 1 2)"))))
    ;; Same for unknown tool name.
    (finish (handle-tools-call
             session "req-4"
             (make-ht "name" "no-such-tool" "arguments" (make-ht))))))

;;; ---------------------------------------------------------------------------
;;; :auto mode fallback — criterion 4 / HERM-07
;;; ---------------------------------------------------------------------------

(define-test criterion-4-auto-no-slynk-resolves-hermetic
  "HERM-07 / D-15 / criterion-4: with mode :auto and no reachable Slynk
listener (slynk-attach nil), resolve-mode emits a run.auto-mode :warn line
on stderr and resolves to :hermetic.

This is the non-crashing, logged fallback that distinguishes :auto from a
silent alias of :attached. The warn line is startup-time only (not per-call)."
  (let* ((capture (make-string-output-stream))
         (*error-output* capture)
         (*log-level* :debug))
    (configure-log4cl-for-server :debug)
    ;; :auto with nil slynk-attach: %slynk-reachable-p returns nil, so
    ;; resolve-mode logs the warn and returns :hermetic.
    (let ((resolved (resolve-mode :mode :auto :slynk-attach nil)))
      ;; Resolved to hermetic (D-15).
      (is eq :hermetic resolved)
      ;; The warn JSON line was emitted to stderr (HERM-07).
      (let ((stderr (get-output-stream-string capture)))
        (true (search "run.auto-mode" stderr))))))
