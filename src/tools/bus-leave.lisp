;;;; src/tools/bus-leave.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; MCP tool: leave a coordination bus cleanly, for this session's own
;;;; participant and no other.
;;;;
;;;; Leaving is three things in order: read out whatever is still waiting, put
;;;; the departure on the bus's roster with the time it happened, and release the
;;;; connection. The roster entry is what transfers custody of the cursor to the
;;;; bus's busmaster, which then keeps it at the head of the log until it ages
;;;; out on that recorded time. So a departed participant can never pin the log
;;;; with records it will not read, and holding its cursor never quietly becomes
;;;; keeping it forever.
;;;;
;;;; It departs only the identity the session resolves. There is deliberately no
;;;; way to leave on another agent's behalf: an agent that could evict its
;;;; neighbours would be a denial of service wearing a verb. Removing somebody
;;;; else from the roster is the operator's job and lives in bus-roster.
;;;;
;;;; Dispatcher-side and mode-independent: it talks to the bus, not to a Lisp
;;;; image.

(defpackage #:dsmr-mcp/src/tools/bus-leave
  (:use #:cl)
  (:local-nicknames (#:agent #:dsmr-mcp/src/bus/agent))
  (:import-from #:dsmr-mcp/src/tools/base
                #:mcp-tool #:mcp-tool-class #:tool-handle #:tool-session)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:make-ht #:result #:text-content)
  (:import-from #:dsmr-mcp/src/tools/bus-helpers
                #:session-agent #:forget-session-agent #:bus-label
                #:identity-summary #:no-project-root)
  (:import-from #:dsmr-mcp/src/bus/selector
                #:invalid-bus-name))

(in-package #:dsmr-mcp/src/tools/bus-leave)

(defclass bus-leave-tool (mcp-tool)
  ((dsmr-mcp/src/tools/base::name
    :allocation :class :initform "bus-leave")
   (dsmr-mcp/src/tools/base::description
    :allocation :class
    :initform "Leave a coordination bus cleanly. This agent reads out whatever \
is still waiting for it, records its departure on the bus's roster with the time \
it left, and disconnects. \
From that moment the bus's busmaster holds this agent's cursor and keeps it at \
the head of the log, so nothing the agent never read can pin the log, and the \
cursor is retired once the departure is old enough rather than living forever. \
Returning later resumes at the current head: no backlog arrives for the period \
away, which is what having left means. \
It can only depart the identity this session resolves, never another agent's. \
Use bus-roster to disenroll somebody else.")
   (dsmr-mcp/src/tools/base::input-schema
    :allocation :class
    :initform '(:object
                :properties
                ((bus
                  :type :string
                  :description "Optional named bus to leave. Omit to leave the \
bus this session already speaks on.")
                 (agent_id
                  :type :string
                  :description "Optional stable agent name to leave as (under \
this project's namespace). Omit to use the session's usual identity.")
                 (ephemeral
                  :type :boolean
                  :description "Set true to depart the session's one-shot \
ephemeral identity rather than the project's stable DSMR_BUS_AGENT one."))
                :required ())))
  (:metaclass mcp-tool-class)
  (:documentation "MCP tool: this session's participant leaves a bus cleanly.

   Drain, record the departure, disconnect, and forget the participant so a
   later bus call in the same session reconnects instead of using a handle with
   no connection behind it. The identity departed is whatever the session
   resolves and nothing else, so one agent can never evict another."))

(c2mop:ensure-finalized (find-class 'bus-leave-tool))

(defun %departure-text (a drained departed-at bound-reached)
  "What leaving meant, for the agent that just did it: what it read on the way
   out, whether the roster took the departure, and what happens to its cursor
   and to its mail from here."
  (format nil "You are ~A.~%~%~
Left bus ~A. ~A on the way out.~A~%~%~
~A~%~%~
Your cursor is now held by the bus's busmaster, which keeps it at the head of \
the log until it ages out on the departure time above, so nothing you did not \
read pins the log for anybody else. Coming back later resumes at the head: you \
will receive nothing published while you were away, which is what having left \
means."
          (identity-summary a)
          (bus-label (agent:agent-bus a))
          (if (plusp drained)
              (format nil "Drained ~D message~:P" drained)
              "Nothing was waiting")
          (if bound-reached
              " Messages were still arriving when the drain stopped on its \
bound, so some were left unread rather than delivered."
              "")
          (if departed-at
              "The departure is on this bus's roster."
              "The departure could NOT be written to the roster, and you left \
anyway. Without that record the busmaster has nothing to age your cursor \
against, so an operator should disenroll you with bus-roster.")))

(defmethod tool-handle ((tool bus-leave-tool) id args)
  (let ((agent-id-arg (gethash "agent_id" args))
        (ephemeral (and (gethash "ephemeral" args) t))
        (bus-arg (gethash "bus" args))
        (session (tool-session tool)))
    (handler-case
        (let ((a (session-agent session agent-id-arg
                               :ephemeral ephemeral :bus bus-arg)))
          (multiple-value-bind (drained departed-at bound-reached)
              (agent:quiesce-and-leave a)
            ;; Forget the participant only after it has actually gone. Left in
            ;; the cache it would hand the session's next bus call a handle whose
            ;; client and subscriber are already released, and that fails in a
            ;; way that looks nothing like its cause.
            (forget-session-agent session agent-id-arg
                                  :ephemeral ephemeral :bus bus-arg)
            (result id (make-ht "left" t
                                "bus" (bus-label (agent:agent-bus a))
                                "agent_id" (agent:agent-id a)
                                "agent_name" (agent:agent-name a)
                                "namespace" (agent:agent-namespace a)
                                "stable" (and (agent:agent-stable-p a) t)
                                "drained" drained
                                "departed_at" (or departed-at 'null)
                                "bound_reached" (and bound-reached t)
                                "content"
                                (text-content
                                 (%departure-text a drained departed-at
                                                  bound-reached))))))
      (invalid-bus-name (e)
        (result id (make-ht "isError" t
                            "error_type" "invalid-argument"
                            "content" (text-content
                                       (format nil "bus-leave: ~A" e)))))
      (no-project-root ()
        (result id (make-ht "isError" t
                            "error_type" "project-root-not-set"
                            "content" (text-content "bus-leave: no project root set. Call fs-set-project-root first.")))))))
