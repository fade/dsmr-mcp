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
                #:session-agent #:identity-summary #:no-project-root)
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

(defun %watcher-line (status age)
  "One human-readable clause about this agent's wakeup watcher, appended to the
   status text so an agent sees at a glance whether its own ears are on. STATUS is
   \"live\"/\"stale\"/\"dead\" and AGE is whole seconds or NIL."
  (cond
    ((equal status "live")  (format nil "Watcher: live (age ~Ds)." age))
    ((equal status "stale") (format nil "Watcher: stale (age ~Ds) — may have stopped listening." age))
    (t "Watcher: DEAD — nothing listening.")))

(c2mop:ensure-finalized (find-class 'bus-status-tool))

(defmethod tool-handle ((tool bus-status-tool) id args)
  (let ((agent-id-arg (gethash "agent_id" args))
        (ephemeral (and (gethash "ephemeral" args) t)))
    (handler-case
        (let* ((a (session-agent (tool-session tool) agent-id-arg :ephemeral ephemeral))
               (st (agent-status a))
               (running (getf st :broker-running))
               (pending (getf st :pending))
               (aid (getf st :id))
               (watcher-status (getf st :watcher-status))
               (watcher-age (getf st :watcher-age-seconds))
               (live-watcher (getf st :live-watcher)))
          (result id (make-ht "broker_running" (and running t)
                              "pending" pending
                              "agent_id" aid
                              "agent_name" (getf st :name)
                              "namespace" (getf st :namespace)
                              "stable" (and (getf st :stable) t)
                              "live_watcher" (and live-watcher t)
                              "watcher_status" watcher-status
                              "watcher_age_seconds" (or watcher-age 'null)
                              "content" (text-content
                                         (format nil "You are ~A. Bus ~A: ~D message(s) pending. ~A"
                                                 (identity-summary a)
                                                 (if running "up" "down (no broker)")
                                                 pending
                                                 (%watcher-line watcher-status watcher-age))))))
      (no-project-root ()
        (result id (make-ht "isError" t
                            "error_type" "project-root-not-set"
                            "content" (text-content "bus-status: no project root set. Call fs-set-project-root first.")))))))
