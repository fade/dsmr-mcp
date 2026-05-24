;;;; src/dispatch.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Per-session tool dispatch: resolve the tool by name from *tool-classes*,
;;;; get-or-create the per-session instance, validate arguments against the
;;;; class-allocated schema, dispatch tool-handle, map validation failures
;;;; to -32602.
;;;;
;;;; Inline tool dispatch is the initial posture; backend routing to attached
;;;; or hermetic workers is added as those subsystems come online.
;;;;
;;;; Regression boundary (assertion b5/c in the test plan):
;;;;   *current-session-id* must be a bound, non-empty string when
;;;;   handle-tools-call is entered. The transport guarantees this binding.
;;;;   This assertion is the detector that fires if a caller omits the
;;;;   binding (e.g. a test helper that drives process-json-line directly
;;;;   without binding *current-session-id*).

(defpackage #:dsmr-mcp/src/dispatch
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/state
                #:get-tool-instance
                #:*current-session-id*
                #:*mode*)
  (:import-from #:dsmr-mcp/src/log
                #:log-event)
  (:import-from #:dsmr-mcp/src/tools/base
                #:*tool-classes*
                #:tool-handle
                #:tool-input-schema)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:rpc-error
                #:validate-args
                #:arg-validation-error
                #:arg-validation-message
                #:make-ht
                #:text-content
                #:result)
  (:import-from #:dsmr-mcp/src/hermetic/dispatch
                #:dispatch-hermetic-call)
  (:export #:handle-tools-call))

(in-package #:dsmr-mcp/src/dispatch)

(defun handle-tools-call (session id params)
  "Dispatch a tools/call request.

1. Assert *current-session-id* is a bound, non-empty string (regression
   boundary — the transport must bind this before calling process-json-line).
2. When *mode* is :hermetic, route directly to dispatch-hermetic-call which
   handles pool assignment, the one-notification crash path, and
   all structured pool error conditions.
3. Extract tool name from params.
4. Look up the class in *tool-classes* — return -32601 if not found.
5. Resolve the per-session instance via get-tool-instance.
6. Validate arguments against the tool's class-allocated input-schema.
   A missing required field signals arg-validation-error, mapped to -32602
   with a human-readable message naming the missing field.
7. Call tool-handle on the instance and return its result envelope."
  ;; Regression boundary: *current-session-id* must be a bound, non-empty
  ;; string. The stdio transport binds it around serve-streams; tests bind it
  ;; explicitly. This assertion fires early rather than letting the session
  ;; leak a nil id into log entries or tool state.
  (unless (and (boundp '*current-session-id*)
               (stringp *current-session-id*)
               (plusp (length *current-session-id*)))
    (error "handle-tools-call: *current-session-id* is not a bound non-empty string. ~
            The transport (or test setup) must bind it before calling ~
            process-json-line."))
  ;; Hermetic mode: route to the pool dispatcher. dispatch-hermetic-call
  ;; handles get-or-assign-worker, the one-notification reset path,
  ;; and all pool/worker conditions — nothing unhandled escapes.
  (when (eq *mode* :hermetic)
    (let ((name (and params (gethash "name" params)))
          (args (and params (gethash "arguments" params))))
      (return-from handle-tools-call
        (dispatch-hermetic-call session id name args))))
  (let* ((name (and params (gethash "name" params)))
         (args (and params (gethash "arguments" params)))
         (class (and name (gethash name *tool-classes*))))
    (unless class
      (return-from handle-tools-call
        (rpc-error id -32601
                   (format nil "Tool not found: ~A" name))))
    (let ((instance (get-tool-instance session name)))
      (handler-case
          (let ((schema (tool-input-schema instance)))
            (validate-args schema args)
            (tool-handle instance id args))
        (arg-validation-error (e)
          (rpc-error id -32602 (arg-validation-message e)))))))
