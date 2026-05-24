;;;; src/hermetic/dispatch.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Hermetic-mode dispatcher: routes one tools/call from the MCP dispatcher
;;;; to the session's dedicated worker process via the pool.
;;;;
;;;; dispatch-hermetic-call is imported by src/dispatch.lisp to replace the
;;;; Phase-3 :hermetic not-ready stub. The one-notification pattern (D-14)
;;;; returns a structured isError reset notification on the FIRST call after a
;;;; worker crash, so the agent gets one clear signal; the next call succeeds.
;;;;
;;;; All pool conditions (pool-shutting-down, pool-capacity-exceeded) and
;;;; worker-crashed are caught and converted to structured isError / rpc-error
;;;; responses so the serve loop never sees an unhandled condition (T-04-17).

(defpackage #:dsmr-mcp/src/hermetic/dispatch
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/state
                #:*current-session-id*
                #:*mode*)
  (:import-from #:dsmr-mcp/src/log
                #:log-event)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:make-ht #:text-content #:result #:rpc-error)
  (:import-from #:dsmr-mcp/src/hermetic/pool
                #:get-or-assign-worker #:pool-shutting-down
                #:pool-capacity-exceeded)
  (:import-from #:dsmr-mcp/src/hermetic/worker-client
                #:worker-rpc #:worker-crashed
                #:check-and-clear-reset-notification)
  (:export #:dispatch-hermetic-call))

(in-package #:dsmr-mcp/src/hermetic/dispatch)

(defun dispatch-hermetic-call (session id name args)
  "Route one tools/call to the session's dedicated hermetic worker.

Implements the one-notification pattern (D-14): if the worker was just
reset after a crash, the agent receives a structured isError reset
notification as the response to THIS call, and the call is NOT forwarded
to the worker. The next call from the same session proceeds normally.

Structured conditions are caught and returned as isError / rpc-error
responses so the MCP serve loop never sees an unhandled condition (T-04-17):
  worker-crashed      -> isError with crash message
  pool-shutting-down  -> rpc-error -32000
  pool-capacity-exceeded -> rpc-error -32000
  error (circuit breaker) -> rpc-error -32000

SESSION is the session object (unused; *current-session-id* is the key).
ID is the JSON-RPC request id. NAME is the tool name string. ARGS is the
tool arguments hash-table, or NIL when the client sent no arguments."
  (declare (ignore session))
  (handler-case
      (let* ((worker (get-or-assign-worker *current-session-id*))
             (had-reset (check-and-clear-reset-notification worker)))
        (when had-reset
          (log-event :warn "dispatch.worker-reset"
                     "session" *current-session-id*
                     "tool" name)
          (return-from dispatch-hermetic-call
            (result id
                    (make-ht "isError" t
                             "content"
                             (text-content
                              "Worker was reset after a crash. \
In-image state has been lost. Retry your call.")))))
        (let* ((params (make-ht "name" name
                                "arguments" (or args (make-hash-table :test 'equal))))
               (resp (worker-rpc worker "worker/eval" params)))
          (result id resp)))
    (worker-crashed (e)
      (log-event :error "dispatch.worker-crashed"
                 "session" *current-session-id*
                 "tool" name
                 "reason" (princ-to-string e))
      (result id (make-ht "isError" t
                          "content"
                          (text-content
                           (format nil "Worker crashed: ~A" e)))))
    (pool-shutting-down ()
      (rpc-error id -32000 "Worker pool is shutting down"))
    (pool-capacity-exceeded ()
      (rpc-error id -32000 "Worker pool at capacity; retry later"))
    (error (e)
      (rpc-error id -32000
                 (format nil "Worker pool error: ~A" e)))))
