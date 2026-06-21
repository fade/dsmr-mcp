;;;; src/tools/bus-status.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; MCP tool: report this agent's view of the coordination bus — whether a broker
;;;; is live and how many messages are waiting — without consuming anything.
;;;; Dispatcher-side and mode-independent.

(defpackage #:dsmr-mcp/src/tools/bus-status
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/tools/base
                #:mcp-tool #:mcp-tool-class #:tool-handle #:tool-session)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:make-ht #:result #:text-content)
  (:import-from #:dsmr-mcp/src/tools/bus-helpers
                #:session-agent #:no-project-root)
  (:import-from #:dsmr-mcp/src/bus/agent
                #:agent-status))

(in-package #:dsmr-mcp/src/tools/bus-status)

(defclass bus-status-tool (mcp-tool)
  ((dsmr-mcp/src/tools/base::name
    :allocation :class :initform "bus-status")
   (dsmr-mcp/src/tools/base::description
    :allocation :class
    :initform "Report the coordination bus state for this agent: whether a broker \
is running and how many messages are waiting, without consuming them.")
   (dsmr-mcp/src/tools/base::input-schema
    :allocation :class
    :initform '(:object
                :properties
                ((agent_id
                  :type :string
                  :description "Optional stable agent name to report for (under \
this project's namespace). Omit to use the session's anonymous default agent.")
                 (ephemeral
                  :type :boolean
                  :description "Set true to force a fresh one-shot ephemeral \
identity for this subagent, opting out of the project's stable DSMR_BUS_AGENT \
identity so it never resumes the main agent's cursor."))
                :required ())))
  (:metaclass mcp-tool-class)
  (:documentation "MCP tool: report coordination-bus status for this agent."))

(c2mop:ensure-finalized (find-class 'bus-status-tool))

(defmethod tool-handle ((tool bus-status-tool) id args)
  (let ((agent-id-arg (gethash "agent_id" args))
        (ephemeral (and (gethash "ephemeral" args) t)))
    (handler-case
        (let* ((a (session-agent (tool-session tool) agent-id-arg :ephemeral ephemeral))
               (st (agent-status a))
               (running (getf st :broker-running))
               (pending (getf st :pending))
               (aid (getf st :id)))
          (result id (make-ht "broker_running" (and running t)
                              "pending" pending
                              "agent_id" aid
                              "content" (text-content
                                         (format nil "Bus ~A for ~A: ~D message(s) pending."
                                                 (if running "up" "down (no broker)") aid pending)))))
      (no-project-root ()
        (result id (make-ht "isError" t
                            "error_type" "project-root-not-set"
                            "content" (text-content "bus-status: no project root set. Call fs-set-project-root first.")))))))
