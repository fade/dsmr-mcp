;;;; src/tools/load-system.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; load-system MCP tool (VERB-12): load an ASDF system with force /
;;;; clear-fasls / timeout, severity-bucketed warning capture, and a true
;;;; in-image timeout that actually interrupts a runaway compile.
;;;;
;;;; Dual-mode dispatch following inspect-object.lisp's pattern:
;;;;   :attached  — builds the load form via %build-load-system-form, injects
;;;;                it into the live image via bounded-slime-eval under the
;;;;                per-session call-lock, and decodes the (:ok N WARNS) /
;;;;                (:timeout S) / (:error MSG) result into the wire envelope.
;;;;   :hermetic  — routes through dispatch-hermetic-call to the worker's
;;;;                worker/load-system handler.
;;;;   :inline    — returns a typed "requires attached or hermetic mode" error.
;;;;
;;;; No human-permission gate on the attached path (D-04): load-system
;;;; compiles and executes arbitrary ASDF systems in the developer's own live
;;;; image — by design, because the agent is already trusted to repl-eval
;;;; arbitrary code, and recompiling to pick up edits is the whole point.
;;;;
;;;; The attached path wraps the load in sb-ext:with-timeout inside the image
;;;; (D-06), so a runaway compile is interrupted rather than observed from
;;;; the dispatcher side. The hermetic path defers to the worker handler which
;;;; calls load-system from system-loader-core (also wrapped in with-timeout).

(defpackage #:dsmr-mcp/src/tools/load-system
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/tools/base
                #:mcp-tool
                #:mcp-tool-class
                #:tool-handle
                #:tool-session)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:make-ht
                #:result
                #:text-content
                #:rpc-error)
  (:import-from #:dsmr-mcp/src/attach/dispatch
                #:repl-eval-tool
                #:repl-eval-tool-slynk-conn
                #:repl-eval-tool-call-lock)
  (:import-from #:dsmr-mcp/src/attach/connection
                #:bounded-slime-eval)
  (:import-from #:dsmr-mcp/src/state
                #:*mode*
                #:get-tool-instance)
  (:import-from #:dsmr-mcp/src/log
                #:log-event)
  (:import-from #:dsmr-mcp/src/hermetic/dispatch
                #:dispatch-hermetic-call)
  (:import-from #:dsmr-mcp/src/system-loader-core
                #:%build-load-system-form)
  (:import-from #:slynk-client
                #:slime-network-error)
  (:import-from #:bordeaux-threads
                #:with-lock-held)
  (:export #:load-system-tool
           #:%dispatch-attach-load-system))

(in-package #:dsmr-mcp/src/tools/load-system)

;;; ---------------------------------------------------------------------------
;;; load-system-tool CLOS class
;;; ---------------------------------------------------------------------------

(defclass load-system-tool (mcp-tool)
  ((dsmr-mcp/src/tools/base::name
    :allocation :class
    :initform "load-system")
   (dsmr-mcp/src/tools/base::description
    :allocation :class
    :initform "Load an ASDF system with structured output and reload support. \
Solves three problems with using (asdf:load-system) via repl-eval: \
1. Staleness: force=true (default) clears loaded state so edits from \
lisp-edit-form become live. 2. Output noise: warnings are collected and \
returned in a structured list rather than flooding the terminal. \
3. Timeout: the load is wrapped in a real in-image timeout that actually \
interrupts a runaway compile. Requires attached or hermetic mode.")
   (dsmr-mcp/src/tools/base::input-schema
    :allocation :class
    :initform '(:object
                :properties
                ((system
                  :type :string
                  :description "ASDF system name (e.g. \"my-project\", \
\"my-project/tests\"). Must be findable by ASDF (registered via asdf:load-asd \
or on the ASDF source registry / Quicklisp search paths).")
                 (force
                  :type :boolean
                  :description "Clear loaded state before loading to pick up \
changes from lisp-edit-form (default: true).")
                 (clear-fasls
                  :type :boolean
                  :description "Force full recompilation from source by clearing \
the ASDF output cache before loading (default: false).")
                 (timeout-seconds
                  :type :integer
                  :description "Timeout in seconds before the load is \
interrupted (default: 120). The timeout fires inside the target image \
so a runaway compile is actually aborted."))
                :required ("system"))))
  (:metaclass mcp-tool-class)
  (:documentation "MCP tool: load an ASDF system with force / clear-fasls /
timeout and severity-bucketed warning capture.
Attached mode injects an sb-ext:with-timeout + handler-bind form into the
live image so edits from lisp-edit-form become live and compiler output
stays off the developer's terminal.
Hermetic mode routes to worker/load-system via dispatch-hermetic-call.
Both paths return the same wire envelope."))

;; ensure-finalized fires the metaclass :after method immediately, registering
;; "load-system" in *tool-classes* at load time.
(c2mop:ensure-finalized (find-class 'load-system-tool))

;;; ---------------------------------------------------------------------------
;;; Result decoder for the attached path
;;;
;;; The injected form returns (:ok N WARNS), (:timeout S), or (:error MSG).
;;; This decoder converts those to the standard wire envelope hash-table.
;;; ---------------------------------------------------------------------------

(defun %decode-load-result (raw sys-name start-time force clear-fasls)
  "Decode the raw result from the attached injected form into a wire envelope.
RAW is (:ok N WARNS), (:timeout S), or (:error MSG).
Returns a hash-table suitable for (result id ...)."
  (declare (ignore clear-fasls))
  (let ((elapsed-ms (round (* 1000 (/ (- (get-internal-real-time) start-time)
                                      internal-time-units-per-second)))))
    (cond
      ;; Success
      ((and (listp raw) (eq (car raw) :ok))
       (let* ((n-warns (second raw))
              (warns   (third  raw))
              (ht      (make-ht "status"      "loaded"
                                "system"      (map 'string #'identity sys-name)
                                "duration_ms" elapsed-ms
                                "forced"      force
                                "warnings"    (or n-warns 0))))
         (when (and n-warns (plusp n-warns) warns)
           (setf (gethash "warning_details" ht)
                 (mapcar (lambda (w) (map 'string #'identity w))
                         warns)))
         ht))
      ;; Timeout
      ((and (listp raw) (eq (car raw) :timeout))
       (let ((timeout-secs (second raw)))
         (make-ht "status"      "timeout"
                  "system"      (map 'string #'identity sys-name)
                  "duration_ms" elapsed-ms
                  "message"     (format nil "Load timed out after ~A seconds"
                                        timeout-secs))))
      ;; Error
      ((and (listp raw) (eq (car raw) :error))
       (let ((msg (map 'string #'identity (or (second raw) "unknown error"))))
         (make-ht "status"      "error"
                  "system"      (map 'string #'identity sys-name)
                  "duration_ms" elapsed-ms
                  "message"     msg)))
      ;; Unexpected shape
      (t
       (log-event :warn "load-system.attach.unexpected-result"
                  "shape" (princ-to-string (and (listp raw) (car raw))))
       (make-ht "isError" t
                "error_type" "LOAD_ERROR"
                "content"
                (text-content "load-system: unexpected result from image."))))))

;;; ---------------------------------------------------------------------------
;;; Attached dispatcher
;;; ---------------------------------------------------------------------------

(defun %dispatch-attach-load-system (tool id params)
  "Dispatch load-system to the attached Slynk image.
Builds the injected form via %build-load-system-form, acquires the call-lock,
and runs bounded-slime-eval. Decodes the result into the wire envelope.
Returns a hash-table (without the result wrapper) so the caller can wrap it."
  (declare (ignore id))
  (let* ((sys-name        (and params (gethash "system"          params)))
         (force           (let ((v (and params (gethash "force"  params))))
                            (if (null v) t v)))  ; default true when absent
         (clear-fasls     (and params (gethash "clear_fasls"     params)))
         (timeout-seconds (or (and params (gethash "timeout_seconds" params)) 120)))
    (unless (and (stringp sys-name) (plusp (length sys-name)))
      (return-from %dispatch-attach-load-system
        (make-ht "isError" t
                 "content"
                 (text-content "load-system: 'system' parameter is required."))))
    (let* ((start-time (get-internal-real-time))
           (form       (handler-case
                           (%build-load-system-form
                            sys-name force clear-fasls timeout-seconds)
                         (error (e)
                           (return-from %dispatch-attach-load-system
                             (make-ht "isError" t
                                      "content"
                                      (text-content
                                       (format nil "load-system: form build error: ~A" e)))))))
           (lock       (repl-eval-tool-call-lock tool))
           (raw        (handler-case
                           (with-lock-held (lock)
                             (bounded-slime-eval form (repl-eval-tool-slynk-conn tool)))
                         (slime-network-error (e)
                           (log-event :warn "load-system.attach.network-error"
                                      "error" (handler-case (princ-to-string e)
                                                (error () "")))
                           (return-from %dispatch-attach-load-system
                             (make-ht "isError"    t
                                      "error_type" "NETWORK_ERROR"
                                      "content"
                                      (text-content
                                       (format nil "load-system: Slynk connection error: ~A"
                                               e))))))))
      (%decode-load-result raw sys-name start-time force clear-fasls))))

;;; ---------------------------------------------------------------------------
;;; tool-handle method
;;; ---------------------------------------------------------------------------

(defmethod tool-handle ((tool load-system-tool) id args)
  "Route load-system by *mode*.
Attached: injects a with-timeout + handler-bind form into the live image.
Hermetic: routes to worker/load-system via dispatch-hermetic-call.
Inline: returns a typed mode error."
  (ecase *mode*
    (:attached
     (let ((repl-tool (get-tool-instance (tool-session tool) "repl-eval")))
       (result id (%dispatch-attach-load-system repl-tool id args))))
    (:hermetic
     (dispatch-hermetic-call (tool-session tool) id "load-system" args))
    (:inline
     (rpc-error id -32603
                "load-system requires attached or hermetic mode."))))
