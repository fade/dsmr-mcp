;;;; src/tools/bus-publish.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; MCP tool: broadcast a message onto the coordination bus so sister agents and
;;;; subagents receive it. Dispatcher-side and mode-independent — it talks to the
;;;; bus, not a Lisp image.

(defpackage #:dsmr-mcp/src/tools/bus-publish
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/tools/base
                #:mcp-tool #:mcp-tool-class #:tool-handle #:tool-session)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:make-ht #:result #:text-content)
  (:import-from #:dsmr-mcp/src/tools/bus-helpers
                #:session-agent #:identity-summary #:no-project-root)
  (:import-from #:dsmr-mcp/src/bus/agent
                #:agent-publish #:agent-id #:agent-name #:agent-namespace
                #:agent-stable-p))

(in-package #:dsmr-mcp/src/tools/bus-publish)

(defclass bus-publish-tool (mcp-tool)
  ((dsmr-mcp/src/tools/base::name
    :allocation :class :initform "bus-publish")
   (dsmr-mcp/src/tools/base::description
    :allocation :class
    :initform "Broadcast a message onto the coordination bus. All subscribed \
agents (sister agents in other repos and subagents in this one) receive it. \
Fire-and-forget; the message is appended durably to the bus log.")
   (dsmr-mcp/src/tools/base::input-schema
    :allocation :class
    :initform '(:object
                :properties
                ((message
                  :type :string
                  :description "The message text to broadcast.")
                 (agent_id
                  :type :string
                  :description "Optional stable agent name to publish as (under \
this project's namespace). Omit to use the session's anonymous default agent.")
                 (ephemeral
                  :type :boolean
                  :description "Set true to force a fresh one-shot ephemeral \
identity for this subagent, opting out of the project's stable DSMR_BUS_AGENT \
identity so it never resumes the main agent's cursor."))
                :required ("message"))))
  (:metaclass mcp-tool-class)
  (:documentation "MCP tool: publish a message to the coordination bus."))

(c2mop:ensure-finalized (find-class 'bus-publish-tool))

(defmethod tool-handle ((tool bus-publish-tool) id args)
  (let ((message (gethash "message" args))
        (agent-id-arg (gethash "agent_id" args))
        (ephemeral (and (gethash "ephemeral" args) t)))
    (unless (and message (stringp message))
      (return-from tool-handle
        (result id (make-ht "isError" t
                            "error_type" "invalid-argument"
                            "content" (text-content "bus-publish: message must be a string.")))))
    (handler-case
        (let ((a (session-agent (tool-session tool) agent-id-arg :ephemeral ephemeral)))
          (agent-publish a message)
          (result id (make-ht "published" t
                              "agent_id" (agent-id a)
                              "agent_name" (agent-name a)
                              "namespace" (agent-namespace a)
                              "stable" (agent-stable-p a)
                              "content" (text-content
                                         (format nil "Published ~D char(s) to the bus as ~A."
                                                 (length message) (identity-summary a))))))
      (no-project-root ()
        (result id (make-ht "isError" t
                            "error_type" "project-root-not-set"
                            "content" (text-content "bus-publish: no project root set. Call fs-set-project-root first.")))))))
