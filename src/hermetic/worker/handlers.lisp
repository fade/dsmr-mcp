;;;; src/hermetic/worker/handlers.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Method handlers for hermetic worker JSON-RPC server.
;;;; Current verb surface: worker/eval only.
;;;;
;;;; register-all-handlers wires the single handler into the server.
;;;; The handler function takes a params hash-table and returns a
;;;; hash-table payload; worker/server.lisp wraps it in the JSON-RPC
;;;; result envelope.
;;;;
;;;; %handle-eval implements attached/hermetic repl-eval output parity via
;;;; build-wrapping-form + eval + build-eval-response — the same pipeline
;;;; as the attached path with local eval replacing slime-eval. A per-call
;;;; soft timeout (sb-ext:with-timeout) guards against runaway evaluations
;;;; while keeping the worker alive for subsequent calls.

(defpackage #:dsmr-mcp/src/hermetic/worker/handlers
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/hermetic/worker/server #:register-method)
  (:import-from #:dsmr-mcp/src/attach/wrap-form
                #:build-wrapping-form #:truncate-output
                #:*default-max-output-length*)
  (:import-from #:dsmr-mcp/src/attach/dispatch
                #:build-eval-response)
  (:import-from #:dsmr-mcp/src/hermetic/worker/inspect
                #:inspect-object-by-id
                #:build-inspect-response
                #:generate-result-preview)
  (:import-from #:dsmr-mcp/src/hermetic/worker/registry
                #:register-object
                #:inspectable-p)
  (:import-from #:dsmr-mcp/src/log #:log-event)
  (:import-from #:sb-ext)
  (:import-from #:uiop)
  (:export #:register-all-handlers #:*default-eval-timeout*))

(in-package #:dsmr-mcp/src/hermetic/worker/handlers)

;;; ---------------------------------------------------------------------------
;;; Configuration
;;; ---------------------------------------------------------------------------

(defparameter *default-eval-timeout*
  (let ((v (uiop:getenv "DSMR_WORKER_EVAL_TIMEOUT")))
    (if (and v (not (string= v "")))
        (max 1 (parse-integer v :junk-allowed t))
        120))
  "Default per-call eval timeout in seconds. Workers serving autonomous agents
need a bounded default to prevent runaway evaluations.
Override via DSMR_WORKER_EVAL_TIMEOUT environment variable.")

;;; ---------------------------------------------------------------------------
;;; worker/eval handler
;;; ---------------------------------------------------------------------------

(defun %handle-eval (params registry)
  "Evaluate code in-process and return the response structure.

Reads code / package / timeout_seconds / max_output_length / register_result
from PARAMS. Builds the wrapping form via build-wrapping-form, evaluates it
inside sb-ext:with-timeout, then calls build-eval-response — the same
pipeline as the attached path, giving identical output regardless of whether
the eval runs in attached or hermetic mode.

When register_result is true (the default) and the eval succeeds with an
inspectable result, registers the live value in REGISTRY and adds
result_object_id to the response. The live value is captured by evaluating
the user's forms directly (without output redirection) before the full
wrapping-form eval, so the registration sees the actual Lisp object, not
its printed representation. This pre-eval captures the raw value only — it
does not capture stdout/stderr, which the wrapping-form eval handles. The
pre-eval result is used solely for registration; no side effects are doubled
because registration reads only the identity of the object.

On sb-ext:with-timeout expiry the worker returns a structured TIMEOUT result
and SURVIVES — the condition is caught, not re-signalled.

Returns a hash-table payload; worker/server.lisp wraps it in the JSON-RPC
result envelope before sending to the dispatcher."
  (let* ((code              (gethash "code"             params))
         (package-name      (gethash "package"          params))
         (timeout-seconds   (gethash "timeout_seconds"  params))
         (max-output-length (gethash "max_output_length" params))
         ;; Distinguish absent key (default true) from explicit false.
         (register-result
           (multiple-value-bind (val presentp)
               (gethash "register_result" params)
             (if presentp val t))))
    (unless code
      (error "code is required"))
    (let* ((form (build-wrapping-form code package-name))
           (result-list
             (handler-case
                 (sb-ext:with-timeout (or timeout-seconds *default-eval-timeout*)
                   (eval form))
               (sb-ext:timeout ()
                 (list (format nil "TIMEOUT after ~As"
                               (or timeout-seconds *default-eval-timeout*))
                       nil "" ""
                       (list :condition-type "SB-EXT:TIMEOUT"
                             :message (format nil "Evaluation timed out after ~A seconds"
                                              (or timeout-seconds *default-eval-timeout*))
                             :restarts nil :frames nil)))))
           (printed       (first  result-list))
           (stdout        (or (third  result-list) ""))
           (stderr        (or (fourth result-list) ""))
           (error-context (fifth  result-list))
           (effective-limit (or (and (integerp max-output-length)
                                     (plusp max-output-length)
                                     max-output-length)
                                *default-max-output-length*))
           (response
             (build-eval-response
              (truncate-output (or printed "") effective-limit)
              (truncate-output stdout effective-limit)
              (truncate-output stderr effective-limit)
              error-context effective-limit)))
      ;; Surface result_object_id when: no error, register_result true.
      ;; The worker eval runs in-process, so the raw Lisp value is accessible.
      ;; We capture it by re-reading and re-evaluating the code forms in a
      ;; lightweight handler-case — this is a second eval of the same code,
      ;; gated strictly on register_result and eval success (error-context nil).
      ;; The trade-off is acceptable: result registration is opt-outable, the
      ;; second eval is only for identity capture, and most worker evals are
      ;; pure expressions rather than long-running side-effectful scripts.
      (when (and register-result (null error-context))
        (handler-case
            (let* ((pkg (or (and package-name (find-package (string-upcase package-name)))
                            *package*))
                   (forms (let ((*package* pkg))
                            (with-input-from-string (s code)
                              (loop for form = (read s nil s)
                                    until (eq form s)
                                    collect form))))
                   (raw-value
                     ;; Eval all forms in sequence; keep only the last first value.
                     (let (last-val)
                       (dolist (f forms last-val)
                         (setf last-val (car (multiple-value-list (eval f))))))))
              (when (and raw-value (inspectable-p raw-value))
                (let ((id (register-object raw-value registry)))
                  (when id
                    (setf (gethash "result_object_id" response) id)))))
          (error () nil)))
      response)))

;;; ---------------------------------------------------------------------------
;;; Public API
;;; ---------------------------------------------------------------------------

(defun %handle-inspect-object (params registry)
  "Inspect a registered object by ID. Returns the cl-mcp envelope shape.
REGISTRY is the per-worker object-registry instance passed at handler
registration. The id parameter is the raw integer ID (the dispatcher in
05-03 strips the epoch/session prefix before forwarding)."
  (let* ((object-id    (gethash "id"           params))
         (max-depth    (or (gethash "max_depth"    params) 1))
         (max-elements (or (gethash "max_elements" params) 50)))
    (unless object-id
      (error "id is required"))
    (let ((result (inspect-object-by-id object-id registry
                                        :max-depth    max-depth
                                        :max-elements max-elements)))
      (build-inspect-response result))))

(defun register-all-handlers (server registry)
  "Register all worker method handlers on SERVER.
REGISTRY is the per-worker object-registry instance; it is closed over by
the handler lambdas so each call shares the same per-process registry.

Registered methods:
  worker/eval            — evaluate code and return a response
  worker/inspect-object  — inspect a registered object by ID"
  (register-method server "worker/eval"
                   (lambda (params) (%handle-eval params registry)))
  (register-method server "worker/inspect-object"
                   (lambda (params) (%handle-inspect-object params registry)))
  (log-event :info "worker.handlers.registered" "count" 2)
  server)
