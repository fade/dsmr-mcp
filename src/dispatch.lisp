;;;; src/dispatch.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Per-session tool dispatch: resolve the tool by name from *tool-classes*,
;;;; get-or-create the per-session instance, validate arguments against the
;;;; class-allocated schema, dispatch tool-handle, map validation failures
;;;; to -32602.
;;;;
;;;; Phase 1 always runs tools inline (no attached/hermetic backend routing).
;;;; Phase 3+ will extend this file to route to attached/hermetic backends
;;;; when the session's backend policy is set.
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
  (:export #:handle-tools-call))

(in-package #:dsmr-mcp/src/dispatch)

(defun handle-tools-call (session id params)
  "Dispatch a tools/call request.

1. Assert *current-session-id* is a bound, non-empty string (regression
   boundary — the transport must bind this before calling process-json-line).
2. Extract tool name from params.
3. Look up the class in *tool-classes* — return -32601 if not found.
4. Resolve the per-session instance via get-tool-instance.
5. Validate arguments against the tool's class-allocated input-schema.
   A missing required field signals arg-validation-error, mapped to -32602
   with a human-readable message naming the missing field.
6. Call tool-handle on the instance and return its result envelope.

Phase 3+ will extend this function to route to attached/hermetic backends
based on session backend policy. Phase 1 always runs inline."
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
  ;; Mode router (D-05): :hermetic has no backend until Phase 4.  Short-circuit
  ;; before tool lookup so any tools/call under :hermetic — including an unknown
  ;; tool name — surfaces a structured not-yet-implemented isError (never a crash,
  ;; never a -32601) and logs the miss.  :attached (and :auto, already aliased to
  ;; :attached in run) falls through to the unchanged Phase 2 path; the D-04
  ;; no-target check stays in attach's with-attach-dispatch and is NOT duplicated
  ;; here.
  (when (eq *mode* :hermetic)
    (let ((name (and params (gethash "name" params))))
      (log-event :warn "dispatch.mode-not-ready"
                 "mode" :hermetic "tool" name)
      (return-from handle-tools-call
        (result id
                (make-ht "isError" t
                         "content"
                         (text-content
                          (format nil
                                  "Mode :hermetic is not yet available (Phase 4). ~
                                   Requested tool: ~A. Set DSMR_MODE=attached or ~
                                   omit DSMR_MODE to use attached mode."
                                  name)))))))
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
