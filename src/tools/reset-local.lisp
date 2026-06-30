;;;; src/tools/reset-local.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; MCP tool: reset-local — the rung-1 operator-triggered local backend reset.
;;;;
;;;; Dispatches to reset-local-backends, which drops the attached connection,
;;;; kills the hermetic workers, clears the circuit breaker, and clears the
;;;; orphan registry. The verb takes no confirmation gate (a recovery tool must
;;;; not depend on a client round-trip that may itself be wedged); safety comes
;;;; from the explicit verb name, idempotent reset semantics, and the structured
;;;; outcome it returns.
;;;;
;;;; CLOS pattern: see pool-kill-worker.lisp / pool-status.lisp — the same
;;;; :initform-on-class-slots rule and post-defclass ensure-finalized apply.

(defpackage #:dsmr-mcp/src/tools/reset-local
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/tools/base
                #:mcp-tool #:mcp-tool-class #:tool-handle #:tool-session)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:result #:text-content #:make-ht)
  (:import-from #:dsmr-mcp/src/reset
                #:reset-local-backends)
  ;; closer-mop: c2mop:ensure-finalized is called after the defclass below.
  ;; MUST be declared here or the cold build fails ("Package CLOSER-MOP does not exist").
  (:import-from #:closer-mop))

(in-package #:dsmr-mcp/src/tools/reset-local)

(defclass reset-local-tool (mcp-tool)
  ;; CRITICAL: :initform on class-allocated slots, NOT :default-initargs.
  ((dsmr-mcp/src/tools/base::name
    :allocation :class
    :initform "reset-local")
   (dsmr-mcp/src/tools/base::description
    :allocation :class
    :initform "Reset the local backends in place (rung 1 of the recovery ladder). \
Drops the attached Slynk connection, kills the hermetic workers bound to this \
server, clears the circuit breaker, and clears the orphan registry — a \
synchronous, non-blocking recovery that never waits for a wedged backend to \
acknowledge. In-image state (loaded systems, REPL definitions) bound to killed \
workers is lost; a fresh worker spawns on the next call and the attached \
connection reopens on demand. Optional scope narrows the reset: \"attached\" \
drops only the attached connection, \"hermetic\" kills workers and clears the \
breaker, and a session-id narrows the kill to one worker. Optional target \
narrows the hermetic kill to one session-id.")
   (dsmr-mcp/src/tools/base::input-schema
    :allocation :class
    :initform '(:object
                :properties
                ((scope
                  :type :string
                  :description "Optional reset scope: \"all\" (the default), \
\"attached\", \"hermetic\", or a session-id to narrow the worker kill to one worker.")
                 (target
                  :type :string
                  :description "Optional session-id; narrows the hermetic worker \
kill to that one worker."))
                :required ())))
  (:metaclass mcp-tool-class)
  (:documentation "MCP tool: rung-1 operator-triggered local backend reset.
Dispatches to reset-local-backends with optional scope/target narrowing."))

;; CRITICAL: ensure-finalized must appear after defclass.
;; (src/tools/base.lisp line 162; src/attach/dispatch.lisp line 115.)
(c2mop:ensure-finalized (find-class 'reset-local-tool))

(defun %arg (args key)
  "Read KEY from request ARGS, treating absent and the jzon null sentinel alike
as NIL so a client-supplied JSON null falls through to the reset-all default."
  (let ((v (and args (gethash key args))))
    (if (eq v 'null) nil v)))

(defmethod tool-handle ((tool reset-local-tool) id args)
  (let* ((scope (%arg args "scope"))
         (target (%arg args "target"))
         (outcome (reset-local-backends (tool-session tool)
                                        :scope scope :target target)))
    (flet ((payload (is-error)
             (make-ht "isError" is-error
                      "content" (text-content (getf outcome :summary))
                      "attached_reset" (and (getf outcome :attached-reset) t)
                      "epoch" (or (getf outcome :epoch) 'null)
                      "workers_killed" (getf outcome :workers-killed)
                      "circuit_breaker_cleared" (and (getf outcome :circuit-breaker-cleared) t)
                      "orphans_cleared" (getf outcome :orphans-cleared))))
      (case (getf outcome :status)
        (:ok
         (result id (payload nil)))
        (:partial
         (let ((ht (payload nil)))
           (setf (gethash "partial" ht) t)
           (result id ht)))
        (t
         (result id (make-ht "isError" t
                             "content"
                             (text-content
                              (format nil "reset-local failed: ~A"
                                      (getf outcome :summary))))))))))
