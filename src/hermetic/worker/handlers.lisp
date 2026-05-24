;;;; src/hermetic/worker/handlers.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Method handlers for hermetic worker JSON-RPC server.
;;;; Phase 4 verb surface = worker/eval only (D-18).
;;;;
;;;; register-all-handlers wires the single handler into the server.
;;;; The handler function takes a params hash-table and returns a
;;;; hash-table payload; worker/server.lisp wraps it in the JSON-RPC
;;;; result envelope.
;;;;
;;;; %handle-eval implements attached/hermetic repl-eval output parity (D-17)
;;;; via build-wrapping-form + eval + build-eval-response — the same pipeline
;;;; as the attached path with local eval replacing slime-eval. A per-call
;;;; soft timeout (sb-ext:with-timeout) guards against runaway evaluations
;;;; while keeping the worker alive for subsequent calls (SAFETY-05).

(defpackage #:dsmr-mcp/src/hermetic/worker/handlers
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/hermetic/worker/server #:register-method)
  (:import-from #:dsmr-mcp/src/attach/wrap-form
                #:build-wrapping-form #:truncate-output
                #:*default-max-output-length*)
  (:import-from #:dsmr-mcp/src/attach/dispatch
                #:build-eval-response)
  (:import-from #:dsmr-mcp/src/log #:log-event)
  (:import-from #:sb-ext)
  (:import-from #:uiop)
  (:export #:register-all-handlers))

(in-package #:dsmr-mcp/src/hermetic/worker/handlers)

;;; ---------------------------------------------------------------------------
;;; Configuration
;;; ---------------------------------------------------------------------------

(defparameter *default-eval-timeout*
  (let ((v (uiop:getenv "DSMR_WORKER_EVAL_TIMEOUT")))
    (if (and v (not (string= v "")))
        (max 1 (parse-integer v :junk-allowed t))
        120))
  "Default per-call eval timeout in seconds (D-11). Workers serving
autonomous agents need a bounded default to prevent runaway evaluations.
Override via DSMR_WORKER_EVAL_TIMEOUT environment variable.")

;;; ---------------------------------------------------------------------------
;;; worker/eval handler
;;; ---------------------------------------------------------------------------

(defun %handle-eval (params)
  "Evaluate code in-process and return the response structure (D-17 parity).

Reads code / package / timeout_seconds / max_output_length from PARAMS.
Builds the wrapping form via build-wrapping-form, evaluates it inside
sb-ext:with-timeout (client timeout_seconds else *default-eval-timeout*),
then calls build-eval-response with the same pipeline as the attached path
(build-wrapping-form + eval + build-eval-response), giving attached/hermetic
repl-eval output parity (D-17).

On sb-ext:timeout the worker returns a structured TIMEOUT result and
SURVIVES — the condition is caught, not re-signalled (SAFETY-05).

Returns a hash-table payload; worker/server.lisp wraps it in the JSON-RPC
result envelope (jsonrpc/id/result) before sending to the dispatcher."
  (let* ((code (gethash "code" params))
         (package-name (gethash "package" params))
         (timeout-seconds (gethash "timeout_seconds" params))
         (max-output-length (gethash "max_output_length" params)))
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
                                *default-max-output-length*)))
      (build-eval-response
       (truncate-output (or printed "") effective-limit)
       (truncate-output stdout effective-limit)
       (truncate-output stderr effective-limit)
       error-context effective-limit))))

;;; ---------------------------------------------------------------------------
;;; Public API
;;; ---------------------------------------------------------------------------

(defun register-all-handlers (server)
  "Register all Phase-4 worker method handlers on SERVER.
Phase-4 verb surface = worker/eval only (D-18). No fs-*, inspect-*,
or other handlers are registered this phase."
  (register-method server "worker/eval" #'%handle-eval)
  (log-event :info "worker.handlers.registered" "count" 1)
  server)
