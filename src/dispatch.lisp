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
                #:dispatch-hermetic-call
                #:worker-routed-tool-p)
  (:import-from #:com.inuoe.jzon)
  (:export #:handle-tools-call
           #:%ensure-rendered-result
           #:*synthesized-content-max-chars*))

(in-package #:dsmr-mcp/src/dispatch)

;;; ---------------------------------------------------------------------------
;;; Result-content guard
;;; ---------------------------------------------------------------------------
;;;
;;; MCP clients render a tools/call result through its content block array
;;; and nothing else; a result carrying only structured fields displays as
;;; empty, silently. Several tools shipped exactly that shape on their
;;; success paths (their error paths all built content, which kept the
;;; defect invisible: errors rendered, results vanished). This guard makes
;;; the failure structurally impossible: every tools/call result leaves the
;;; dispatcher with a content array, synthesized from the structured fields
;;; when the tool did not provide one.

(defparameter *synthesized-content-max-chars* 4096
  "Cap on synthesized content text. The guard is a backstop, not a
renderer — a tool returning a large structured payload (a threads array, a
diagnostics dump) must not get megabytes of JSON synthesized into a text
block. Past the cap the text is cut and marked elided; the structured
fields remain complete and authoritative.")

(defun %ensure-rendered-result (envelope tool-name)
  "Guarantee that a tools/call response ENVELOPE carries renderable content.
When ENVELOPE is a JSON-RPC success whose result hash-table lacks a
\"content\" key, synthesize one — the structured fields rendered as JSON
text, bounded by *synthesized-content-max-chars* — and log a warning naming
TOOL-NAME so the missing summary surfaces during development. JSON-RPC
error envelopes and results that already carry content pass through
untouched. Returns ENVELOPE."
  (let ((payload (and (hash-table-p envelope)
                      (not (gethash "error" envelope))
                      (gethash "result" envelope))))
    (when (and (hash-table-p payload)
               (not (nth-value 1 (gethash "content" payload))))
      (let* ((rendered (handler-case (com.inuoe.jzon:stringify payload)
                         (error () "(unrenderable structured result)")))
             (bounded (if (> (length rendered) *synthesized-content-max-chars*)
                          (concatenate 'string
                                       (subseq rendered 0 *synthesized-content-max-chars*)
                                       (format nil "...[elided ~D of ~D chars]"
                                               (- (length rendered)
                                                  *synthesized-content-max-chars*)
                                               (length rendered)))
                          rendered)))
        (setf (gethash "content" payload) (text-content bounded))
        (log-event :warn "tools-call.result.missing-content"
                   "tool" (or tool-name "")
                   "chars" (length rendered)))))
  envelope)

(defun handle-tools-call (session id params)
  "Dispatch a tools/call request.

1. Assert *current-session-id* is a bound, non-empty string (regression
   boundary — the transport must bind this before calling process-json-line).
2. When *mode* is :hermetic AND the tool is a worker-routed (image-bound) verb,
   route to dispatch-hermetic-call which handles pool assignment, the
   one-notification crash path, and all structured pool error conditions.
   Dispatcher-side tools (fs-*, clhs-lookup, lsp-*, pool-status, ...) fall
   through to the local path below, the same way they are served in attached
   mode -- they need no worker image.
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
  ;; Hermetic mode: route ONLY image-bound verbs to the pool dispatcher.
  ;; dispatch-hermetic-call handles get-or-assign-worker, the one-notification
  ;; reset path, and all pool/worker conditions — nothing unhandled escapes.
  ;; Dispatcher-side tools (fs-*, clhs-lookup, lsp-*, pool-status, ...) are NOT
  ;; routed to a worker; they fall through to the local *tool-classes* path,
  ;; exactly as in attached mode. A blanket route would send them to worker/eval,
  ;; which then fails with "code is required" — and would make the pool-management
  ;; tools, which must act on the pool from this process, unreachable.
  (let ((name (and params (gethash "name" params))))
    (when (and (eq *mode* :hermetic) (worker-routed-tool-p name))
      (let ((args (and params (gethash "arguments" params))))
        (return-from handle-tools-call
          (%ensure-rendered-result
           (dispatch-hermetic-call session id name args) name)))))
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
            (%ensure-rendered-result (tool-handle instance id args) name))
        (arg-validation-error (e)
          (rpc-error id -32602 (arg-validation-message e)))))))
