;;;; src/tools/bus-receive.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; MCP tool: receive messages waiting on the coordination bus for this agent,
;;;; advancing its durable cursor. Catch-up by default; optionally waits a bounded
;;;; time for the first message. Dispatcher-side and mode-independent.

(defpackage #:dsmr-mcp/src/tools/bus-receive
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/tools/base
                #:mcp-tool #:mcp-tool-class #:tool-handle #:tool-session)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:make-ht #:result #:text-content)
  (:import-from #:dsmr-mcp/src/tools/bus-helpers
                #:session-agent #:no-project-root)
  (:import-from #:dsmr-mcp/src/bus/agent
                #:agent-receive #:agent-id))

(in-package #:dsmr-mcp/src/tools/bus-receive)

(defclass bus-receive-tool (mcp-tool)
  ((dsmr-mcp/src/tools/base::name
    :allocation :class :initform "bus-receive")
   (dsmr-mcp/src/tools/base::description
    :allocation :class
    :initform "Receive messages from the coordination bus that this agent has \
not yet seen, advancing its cursor so each is delivered once. Returns immediately \
with whatever is pending (catch-up); set timeout_ms to wait that long for the \
first message. A named agent resumes where it left off across restarts.")
   (dsmr-mcp/src/tools/base::input-schema
    :allocation :class
    :initform '(:object
                :properties
                ((agent_id
                  :type :string
                  :description "Optional stable agent name to receive as (under \
this project's namespace). Omit to use the session's anonymous default agent.")
                 (timeout_ms
                  :type :integer
                  :description "Milliseconds to wait for the first message before \
returning empty (default 0 = non-blocking catch-up)."))
                :required ())))
  (:metaclass mcp-tool-class)
  (:documentation "MCP tool: receive pending coordination-bus messages."))

(c2mop:ensure-finalized (find-class 'bus-receive-tool))

(defmethod tool-handle ((tool bus-receive-tool) id args)
  (let ((agent-id-arg (gethash "agent_id" args))
        (timeout (or (gethash "timeout_ms" args) 0)))
    (unless (and (integerp timeout) (>= timeout 0))
      (return-from tool-handle
        (result id (make-ht "isError" t
                            "error_type" "invalid-argument"
                            "content" (text-content "bus-receive: timeout_ms must be a non-negative integer.")))))
    (handler-case
        (let* ((a (session-agent (tool-session tool) agent-id-arg))
               (messages (agent-receive a :timeout-ms timeout)))
          (result id (make-ht "messages" (coerce messages 'vector)
                              "count" (length messages)
                              "agent_id" (agent-id a)
                              "content" (text-content
                                         (if messages
                                             (format nil "~D message(s) for ~A:~%~{- ~A~^~%~}"
                                                     (length messages) (agent-id a) messages)
                                             (format nil "No new messages for ~A." (agent-id a)))))))
      (no-project-root ()
        (result id (make-ht "isError" t
                            "error_type" "project-root-not-set"
                            "content" (text-content "bus-receive: no project root set. Call fs-set-project-root first.")))))))
