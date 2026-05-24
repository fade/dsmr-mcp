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
;;;; FULL EVAL BODY: completed in 04-04 (D-17 parity via
;;;; build-wrapping-form + eval + build-eval-response).
;;;; The placeholder body below satisfies the ASDF load graph and
;;;; cold-build requirements for this plan.

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
  "Evaluate code and return the response structure expected by the
dispatcher side. Returns a hash-table payload (the JSON-RPC result
field); worker/server.lisp wraps it in the response envelope.

FULL EVAL BODY: completed in 04-04 (D-17 parity via
build-wrapping-form + eval + build-eval-response).
This placeholder satisfies the ASDF load graph for the current plan."
  (let* ((code (gethash "code" params))
         (package-name (gethash "package" params))
         (timeout-seconds (gethash "timeout_seconds" params))
         (max-output-length (gethash "max_output_length" params)))
    (unless code
      (error "code is required"))
    ;; FULL EVAL BODY: completed in 04-04 (D-17 parity via
    ;; build-wrapping-form + eval + build-eval-response).
    ;; Placeholder: returns a stub response so the load graph resolves.
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
