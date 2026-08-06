;;;; tests/dispatch/mode-router-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Integration tests for the mode router in handle-tools-call.
;;;; A :hermetic call routes to dispatch-hermetic-call, which returns a
;;;; structured rpc-error when the pool is not running (pool-shutting-down
;;;; condition), and routes to a live worker when the pool is up.
;;;;
;;;; The router branches on :hermetic; the :attached path is covered by
;;;; tests/attach/repl-eval-attach-test.lisp.

(defpackage #:dsmr-mcp/tests/dispatch/mode-router-test
  (:use #:cl #:zebra)
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
                #:make-ht)
  (:import-from #:dsmr-mcp/tests/support/env-fixture
                #:with-clean-resolution-env))

(in-package #:dsmr-mcp/tests/dispatch/mode-router-test)

;;; ---------------------------------------------------------------------------
;;; Hermetic mode dispatch — pool not running path
;;; ---------------------------------------------------------------------------

(define-test criterion-3-hermetic-pool-not-running-returns-rpc-error
  "With *mode* :hermetic and no pool initialized, a tools/call routes through
dispatch-hermetic-call and returns a structured rpc-error -32000 (pool-shutting-
down condition caught) rather than crashing the serve loop."
  (with-clean-resolution-env
  ;; Guarantee the precondition rather than assume it: an earlier test (or a
  ;; reachable Slynk on the dev shell's DSMR_SLYNK_ATTACH target) can leave a pool
  ;; initialized, which would make repl-eval route to a live worker instead of the
  ;; pool-not-running error this test asserts.
  (ignore-errors (shutdown-pool))
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
      (true (search "pool" (string-downcase (gethash "message" rpc-err))))))))

(define-test hermetic-unknown-tool-returns-not-found
  "With *mode* :hermetic, an unknown tool name is NOT a worker-routed verb, so
the mode router falls through to the local tool lookup and returns -32601
tool-not-found — the same answer it would give in attached mode. (Previously the
router blanket-routed every hermetic call to the pool, so an unknown tool died as
a pool error / \"code is required\" instead of a clear not-found.)"
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
      ;; Tool-not-found, not a pool error.
      (true rpc-err)
      (is = -32601 (gethash "code" rpc-err)))))

(define-test hermetic-dispatcher-side-tool-served-locally
  "With *mode* :hermetic and NO pool running, a dispatcher-side tool
(pool-status) is served on the local *tool-classes* path rather than routed to a
worker. It returns a normal result envelope — never the pool rpc-error -32000 or
the worker/eval \"code is required\" failure that a blanket hermetic route caused.
This is the regression guard for the launch-time wedge where every non-eval tool
was misrouted to worker/eval."
  (let* ((*mode* :hermetic)
         (capture (make-string-output-stream))
         (*error-output* capture)
         (*log-level* :debug)
         (session (make-session :id "hermetic-local-tool"))
         (*current-session-id* "hermetic-local-tool"))
    (configure-log4cl-for-server :debug)
    (let* ((env (handle-tools-call
                 session "req-local"
                 (make-ht "name" "pool-status" "arguments" (make-ht))))
           (rpc-err (gethash "error" env))
           (res     (gethash "result" env)))
      ;; Local path: a result envelope, not an rpc-error envelope.
      (false rpc-err)
      (true res)
      ;; And specifically not the misrouted-to-worker failure text.
      (let ((blob (jzon:stringify env)))
        (false (search "code is required" blob))))))

(define-test server-does-not-crash
  "handle-tools-call returns normally under :hermetic regardless of pool state
— no unhandled condition escapes, so the serve loop stays up.
Exercises both pool-not-running and the :attached fallthrough."
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
;;; :auto mode fallback
;;; ---------------------------------------------------------------------------

(define-test auto-no-slynk-resolves-hermetic
  "With mode :auto and no reachable Slynk listener (slynk-attach nil),
resolve-mode emits a run.auto-mode :warn line on stderr and resolves to
:hermetic. The warn line is startup-time only (not per-call)."
  (let* ((capture (make-string-output-stream))
         (*error-output* capture)
         (*log-level* :debug))
    (configure-log4cl-for-server :debug)
    ;; :auto with nil slynk-attach: %slynk-reachable-p returns nil, so
    ;; resolve-mode logs the warn and returns :hermetic.
    (let ((resolved (resolve-mode :mode :auto :slynk-attach nil)))
      (is eq :hermetic resolved)
      (let ((stderr (get-output-stream-string capture)))
        (true (search "run.auto-mode" stderr))))))
