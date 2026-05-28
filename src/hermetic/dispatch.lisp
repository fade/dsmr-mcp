;;;; src/hermetic/dispatch.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Hermetic-mode dispatcher: routes one tools/call from the MCP dispatcher
;;;; to the session's dedicated worker process via the pool.
;;;;
;;;; dispatch-hermetic-call is imported by src/dispatch.lisp to route tool calls
;;;; to the session's worker pool. The one-notification pattern returns a
;;;; structured isError reset notification on the FIRST call after a worker
;;;; crash, so the agent gets one clear signal; the next call succeeds.
;;;;
;;;; All pool conditions (pool-shutting-down, pool-capacity-exceeded) and
;;;; worker-crashed are caught and converted to structured isError / rpc-error
;;;; responses so the serve loop never sees an unhandled condition.

(defpackage #:dsmr-mcp/src/hermetic/dispatch
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/state
                #:*current-session-id*
                #:*mode*
                #:session-project-root)
  (:import-from #:dsmr-mcp/src/log
                #:log-event)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:make-ht #:text-content #:result #:rpc-error)
  (:import-from #:dsmr-mcp/src/hermetic/pool
                #:get-or-assign-worker #:pool-shutting-down
                #:pool-capacity-exceeded #:pool-rpc-with-hard-kill)
  (:import-from #:dsmr-mcp/src/hermetic/worker-client
                #:worker-crashed
                #:check-and-clear-reset-notification
                #:worker-id)
  (:import-from #:dsmr-mcp/src/hermetic/worker/handlers
                #:*default-eval-timeout*)
  (:import-from #:dsmr-mcp/src/attach/registry
                #:decode-object-id)
  (:export #:dispatch-hermetic-call))

(in-package #:dsmr-mcp/src/hermetic/dispatch)

(defun dispatch-hermetic-call (session id name args)
  "Route one tools/call to the session's dedicated hermetic worker.

Implements the one-notification pattern: if the worker was just reset after
a crash, the agent receives a structured isError reset notification as the
response to THIS call, and the call is NOT forwarded to the worker. The next
call from the same session proceeds normally.

Routes by NAME:
  \"inspect-object\" -> worker method \"worker/inspect-object\" with a
    worker-incarnation epoch check before the RPC call.  The decoded epoch
    is compared to (worker-id worker); a mismatch short-circuits to a
    registry-reset error before any pool-rpc-with-hard-kill call.  Only
    the raw integer id (epoch+session stripped) is forwarded to the worker.
  \"code-find\" / \"code-describe\" / \"code-find-references\" -> worker method
    \"worker/<name>\" directly (no epoch check). The session project root is
    read once and injected as \"project_root\" in the params when non-NIL,
    so the worker handler can relativize returned paths.
  \"load-system\" / \"run-tests\" -> worker method \"worker/<name>\" directly
    (no epoch check, no project_root injection — these verbs do not
    relativize paths).
  \"inspect-thread\" -> worker method \"worker/inspect-thread\" directly
    (no epoch check, no project_root injection).
  Any other name  -> worker method \"worker/eval\" (unchanged behaviour).

Structured conditions are caught and returned as isError / rpc-error
responses so the MCP serve loop never sees an unhandled condition:
  worker-crashed      -> isError with crash message
  pool-shutting-down  -> rpc-error -32000
  pool-capacity-exceeded -> rpc-error -32000
  error (circuit breaker) -> rpc-error -32000

SESSION is the session object; the project root is read from it for the
code-intelligence verbs. ID is the JSON-RPC request id. NAME is the tool
name string. ARGS is the tool arguments hash-table, or NIL when the client
sent no arguments."
  (let ((session-root (session-project-root session)))
    (handler-case
        (let* ((worker    (get-or-assign-worker *current-session-id*))
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
          ;; Name-based routing.
          (cond
            ;; ----------------------------------------------------------------
            ;; inspect-object branch: epoch check + worker/inspect-object RPC.
            ;; ----------------------------------------------------------------
            ((string= name "inspect-object")
             (let* ((params      (or args (make-hash-table :test 'equal)))
                    (id-string   (gethash "id" params)))
               ;; Validate the id field is present.
               (unless (and (stringp id-string) (plusp (length id-string)))
                 (return-from dispatch-hermetic-call
                   (rpc-error id -32602
                              "inspect-object: 'id' parameter is required.")))
               ;; Decode the object id; malformed -> rpc-error -32602.
               (multiple-value-bind (decoded-epoch decoded-session-id decoded-raw-id)
                   (handler-case (decode-object-id id-string)
                     (error (e)
                       (return-from dispatch-hermetic-call
                         (rpc-error id -32602
                                    (format nil "inspect-object: malformed id: ~A" e)))))
                 (declare (ignore decoded-session-id))
                 ;; Worker-incarnation epoch check: compare the decoded epoch
                 ;; to (worker-id worker).  A mismatch means the object was
                 ;; registered against a previous worker incarnation and the
                 ;; registry has been reset.  Short-circuit BEFORE any RPC call.
                 (when (/= decoded-epoch (worker-id worker))
                   (log-event :info "dispatch.inspect.stale-epoch"
                              "session" *current-session-id*
                              "decoded-epoch" decoded-epoch
                              "worker-epoch" (worker-id worker))
                   (return-from dispatch-hermetic-call
                     (result id
                             (make-ht "isError"    t
                                      "error_type" "registry-reset"
                                      "content"
                                      (text-content
                                       "Object registry was reset after a worker \
crash; the object id is no longer valid.")))))
                 ;; Epoch matches: forward only the raw integer id to the worker.
                 ;; Strip the epoch and session-id; the worker owns only raw ids.
                 (let* ((worker-params (make-hash-table :test 'equal)))
                   (setf (gethash "id" worker-params) decoded-raw-id)
                   ;; Forward optional max_depth / max_elements if provided.
                   (let ((max-depth     (gethash "max_depth" params))
                         (max-elements  (gethash "max_elements" params)))
                     (when max-depth
                       (setf (gethash "max_depth" worker-params) max-depth))
                     (when max-elements
                       (setf (gethash "max_elements" worker-params) max-elements)))
                   (let ((resp (pool-rpc-with-hard-kill worker "worker/inspect-object"
                                                        worker-params
                                                        :soft-timeout *default-eval-timeout*)))
                     (result id resp))))))
            ;; ----------------------------------------------------------------
            ;; Code-intelligence branch: route to worker/<name> and inject the
            ;; session project root so the worker handler can relativize paths.
            ;; No object-ID epoch check — these verbs carry no object IDs.
            ;; ----------------------------------------------------------------
            ((member name '("code-find" "code-describe" "code-find-references")
                     :test #'string=)
             (let* ((params (or args (make-hash-table :test 'equal)))
                    (soft   (let ((v (gethash "timeout_seconds" params)))
                              (if (and v (integerp v) (plusp v))
                                  v *default-eval-timeout*))))
               ;; Inject project_root when the session has one set; the worker
               ;; handler reads it and passes it as :root to the code-core engine.
               (when session-root
                 (setf (gethash "project_root" params)
                       (namestring session-root)))
               (let ((resp (pool-rpc-with-hard-kill worker
                                                    (format nil "worker/~A" name)
                                                    params
                                                    :soft-timeout soft)))
                 (result id resp))))
            ;; ----------------------------------------------------------------
            ;; load-system / run-tests branch: route to worker/<name>.
            ;; No epoch check, no project_root injection.
            ;; ----------------------------------------------------------------
            ((member name '("load-system" "run-tests")
                     :test #'string=)
             (let* ((params (or args (make-hash-table :test 'equal)))
                    (soft   (let ((v (gethash "timeout_seconds" params)))
                              (if (and v (integerp v) (plusp v))
                                  v *default-eval-timeout*)))
                    (resp   (pool-rpc-with-hard-kill worker
                                                     (format nil "worker/~A" name)
                                                     params
                                                     :soft-timeout soft)))
               (result id resp)))
            ;; ----------------------------------------------------------------
            ;; Inspection-verb branch: route to worker/<name>.
            ;; No epoch check, no project_root injection.
            ;; inspect-restart returns a structured empty set in hermetic mode.
            ;; ----------------------------------------------------------------
            ((member name '("inspect-thread" "inspect-restart")
                     :test #'string=)
             (let* ((params (or args (make-hash-table :test 'equal)))
                    (soft   (let ((v (gethash "timeout_seconds" params)))
                              (if (and v (integerp v) (plusp v))
                                  v *default-eval-timeout*)))
                    (resp   (pool-rpc-with-hard-kill worker
                                                     (format nil "worker/~A" name)
                                                     params
                                                     :soft-timeout soft)))
               (result id resp)))
            ;; ----------------------------------------------------------------
            ;; Default branch: worker/eval (repl-eval and any future verbs).
            ;; Pass args directly as worker/eval params — the handler reads
            ;; "code"/"package"/"timeout_seconds"/"max_output_length" from the
            ;; top-level params hash-table (not nested under "arguments").
            ;; Route through pool-rpc-with-hard-kill so the parent hard-kill
            ;; backstop covers runaway FFI that the in-worker soft timeout
            ;; cannot interrupt.
            ;; ----------------------------------------------------------------
            (t
             (let* ((params (or args (make-hash-table :test 'equal)))
                    (soft   (let ((v (gethash "timeout_seconds" params)))
                              (if (and v (integerp v) (plusp v))
                                  v
                                  *default-eval-timeout*)))
                    (resp   (pool-rpc-with-hard-kill worker "worker/eval" params
                                                     :soft-timeout soft)))
               (result id resp)))))
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
                   (format nil "Worker pool error: ~A" e))))))
