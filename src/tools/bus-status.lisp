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
                #:session-agent #:bus-label #:identity-summary #:no-project-root)
  (:import-from #:dsmr-mcp/src/bus/selector
                #:invalid-bus-name)
  (:import-from #:dsmr-mcp/src/bus/agent
                #:agent-bus #:agent-status))

(in-package #:dsmr-mcp/src/tools/bus-status)

(defclass bus-status-tool (mcp-tool)
  ((dsmr-mcp/src/tools/base::name
    :allocation :class :initform "bus-status")
   (dsmr-mcp/src/tools/base::description
    :allocation :class
    :initform "Report this agent's view of the coordination bus at one moment: \
whether a broker is running and how many records are waiting for this agent, \
without consuming them. \
It is not an inventory of the bus. It does not establish what the broker is, \
which source that broker is serving or whether it would survive a restart; it \
does not say which generation of the log this is, which recorded positions are \
stranded, or which identities are enrolled and reading. bus-inspect answers \
those, and it is the verb to call when the question is what state the bus is \
in. \
The pending figure counts every record past this agent's cursor, and that \
includes this agent's own publishes, which delivery filters out. The number \
shown here and the number a receive returns can therefore legitimately differ, \
and neither of them is wrong.")
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
identity so it never resumes the main agent's cursor.")
                 (bus
                  :type :string
                  :description "Optional named bus to report on. Omit to use \
this session's bus, which is DSMR_BUS_SELECTOR from the repository's .envrc \
when that is set and the shared host-wide bus otherwise. A name that cannot \
become a bus is refused; the shared bus is never reported on in place of a bus \
that was named."))
                :required ())))
  (:metaclass mcp-tool-class)
  (:documentation "MCP tool: report coordination-bus status for this agent.

Superseded by bus-inspect and kept answering. What it measures is unchanged and
every field it has ever returned is still returned, because the harm was never
in the measurement: it was in a familiar name being read as an inventory of the
bus when it reports a moment in time. So the verb now says what it means and
names where the fuller answer lives, in the response as well as in the tool
list, since a caller relaying an answer onward carries the reply and not the
description."))

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
        (bus-arg (gethash "bus" args))
        (ephemeral (and (gethash "ephemeral" args) t)))
    ;; An empty bus is refused rather than read as "no bus named": resolved, it
    ;; would report on whatever bus the session already speaks on, and a report
    ;; that names a bus it was not asked about is worse than no report at all.
    (unless (or (null bus-arg) (and (stringp bus-arg) (plusp (length bus-arg))))
      (return-from tool-handle
        (result id (make-ht "isError" t
                            "error_type" "invalid-argument"
                            "content"
                            (text-content "bus-status: bus must be a non-empty \
string naming a bus. Omit it to report on this session's own bus.")))))
    (handler-case
        (let* ((a (session-agent (tool-session tool) agent-id-arg
                                 :ephemeral ephemeral :bus bus-arg))
               (st (agent-status a))
               (label (bus-label (agent-bus a)))
               (running (getf st :broker-running))
               (pending (getf st :pending))
               (aid (getf st :id))
               (watcher-status (getf st :watcher-status))
               (watcher-age (getf st :watcher-age-seconds))
               (live-watcher (getf st :live-watcher)))
          (result id (make-ht "broker_running" (and running t)
                              "pending" pending
                              "bus" label
                              "agent_id" aid
                              "agent_name" (getf st :name)
                              "namespace" (getf st :namespace)
                              "stable" (and (getf st :stable) t)
                              "live_watcher" (and live-watcher t)
                              "watcher_status" watcher-status
                              "watcher_age_seconds" (or watcher-age 'null)
                              ;; Built fresh on each call rather than held in a
                              ;; constant, so nothing a caller does to the object
                              ;; it was handed can reach the next caller.
                              "superseded_by"
                              (make-ht
                               "verb" "bus-inspect"
                               "reports" "This reply is a moment in time: a broker is or is not holding the election lock, and this agent has this many records past its cursor. It is not an inventory of the bus, and it establishes nothing about which source the broker is serving, which generation of the log this is, which recorded positions are stranded, or who else is reading. bus-inspect answers those."
                               "pending" "The pending number counts every record past this agent's cursor, and that includes records this agent published itself, which delivery filters out. So this number and the count a receive returns can legitimately differ, and neither of them is wrong.")
                              "content" (text-content
                                         (format nil "You are ~A. Bus ~A is ~A: ~D message(s) pending. ~A"
                                                 (identity-summary a)
                                                 label
                                                 (if running "up" "down (no broker)")
                                                 pending
                                                 (%watcher-line watcher-status watcher-age))))))
      ;; A bus name that cannot become a bus root is refused rather than
      ;; downgraded. A status line about the shared bus, returned to an agent
      ;; that asked about a named one, is a report of the wrong bus's health.
      (invalid-bus-name (e)
        (result id (make-ht "isError" t
                            "error_type" "invalid-argument"
                            "content" (text-content
                                       (format nil "bus-status: ~A" e)))))
      (no-project-root ()
        (result id (make-ht "isError" t
                            "error_type" "project-root-not-set"
                            "content" (text-content "bus-status: no project root set. Call fs-set-project-root first.")))))))
