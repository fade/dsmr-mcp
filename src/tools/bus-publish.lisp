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
                #:session-agent #:bus-label #:identity-summary #:no-project-root)
  (:import-from #:dsmr-mcp/src/bus/agent
                #:agent-publish #:agent-id #:agent-name #:agent-namespace
                #:agent-bus #:agent-stable-p #:direct-addressing-disabled
                #:unresolvable-recipient)
  (:import-from #:dsmr-mcp/src/bus/selector
                #:invalid-bus-name))

(in-package #:dsmr-mcp/src/tools/bus-publish)

(defclass bus-publish-tool (mcp-tool)
  ((dsmr-mcp/src/tools/base::name
    :allocation :class :initform "bus-publish")
   (dsmr-mcp/src/tools/base::description
    :allocation :class
    :initform "Broadcast a message onto the coordination bus. All subscribed \
agents (sister agents in other repos and subagents in this one) receive it, \
unless the optional to argument names one recipient, in which case only that \
participant is handed it. Fire-and-forget; the message is appended durably to \
the bus log either way.")
   (dsmr-mcp/src/tools/base::input-schema
    :allocation :class
    :initform '(:object
                :properties
                ((message
                  :type :string
                  :description "The message text to broadcast.")
                 (to
                  :type :string
                  :description "Optional recipient, either a full \
NAMESPACE/NAME bus id or the bare name of a participant already on this bus. A \
bare name is matched against the participants the bus knows, whichever \
repository they live in, so a sister is named by the name it answers to; a name \
that matches nothing, or that two participants answer to, publishes nothing and \
returns an error listing what was considered. Only the named participant is \
handed the message; no other member of the bus is shown it. This is NOT privacy: \
the record still travels on the fleet's shared log and any member can read it \
there, so naming a recipient filters delivery and does not confine the text. \
Direct addressing is off unless the repository that needs it sets \
DSMR_BUS_DIRECT_ADDRESSING to 1; naming a recipient while it is off publishes \
nothing and returns an error saying so. Omit to broadcast.")
                 (agent_id
                  :type :string
                  :description "Optional stable agent name to publish as (under \
this project's namespace). Omit to use the session's anonymous default agent.")
                 (ephemeral
                  :type :boolean
                  :description "Set true to force a fresh one-shot ephemeral \
identity for this subagent, opting out of the project's stable DSMR_BUS_AGENT \
identity so it never resumes the main agent's cursor.")
                 (bus
                  :type :string
                  :description "Optional named bus to publish on. Omit to use \
this session's bus, which is DSMR_BUS_SELECTOR from the repository's .envrc \
when that is set and the shared host-wide bus otherwise. A name that cannot \
become a bus is refused; nothing is ever published to the shared bus in place \
of a bus that was named."))
                :required ("message"))))
  (:metaclass mcp-tool-class)
  (:documentation "MCP tool: publish a message to the coordination bus."))

(c2mop:ensure-finalized (find-class 'bus-publish-tool))

(defun %invalid-argument (id message)
  "An invalid-argument refusal in the shape every bus-publish guard returns."
  (result id (make-ht "isError" t
                      "error_type" "invalid-argument"
                      "content" (text-content message))))

(defmethod tool-handle ((tool bus-publish-tool) id args)
  (let ((message (gethash "message" args))
        (agent-id-arg (gethash "agent_id" args))
        (to-arg (gethash "to" args))
        (bus-arg (gethash "bus" args))
        (ephemeral (and (gethash "ephemeral" args) t)))
    (unless (and message (stringp message))
      (return-from tool-handle
        (%invalid-argument id "bus-publish: message must be a string.")))
    ;; A recipient is checked before the session is touched, so a call that
    ;; names one badly connects nothing and publishes nothing. An empty string
    ;; is refused with the rest: it is the name of no participant, and a
    ;; message addressed to nobody is one no reader is ever shown.
    (unless (or (null to-arg) (and (stringp to-arg) (plusp (length to-arg))))
      (return-from tool-handle
        (%invalid-argument id "bus-publish: to must be a non-empty string, \
either a full NAMESPACE/NAME bus id or the bare name of a participant already on \
this bus.")))
    ;; A named bus is checked in the same breath and for the same reason. An
    ;; empty string is refused rather than read as "no bus named": resolved, it
    ;; would fall through to whatever bus the session already speaks on, which
    ;; puts a fleet's message in front of the wrong fleet while the call reports
    ;; success.
    (unless (or (null bus-arg) (and (stringp bus-arg) (plusp (length bus-arg))))
      (return-from tool-handle
        (%invalid-argument id "bus-publish: bus must be a non-empty string \
naming a bus. Omit it to publish on this session's own bus.")))
    (handler-case
        (let ((a (session-agent (tool-session tool) agent-id-arg
                                :ephemeral ephemeral :bus bus-arg)))
          ;; What comes back as the recipient is the id the BUS resolved, never
          ;; the string the caller typed, so the reply names the identity the
          ;; message was actually filtered to.
          (multiple-value-bind (seq recipient)
              (agent-publish a message :to to-arg)
            (result id (make-ht "published" t
                                "bus" (bus-label (agent-bus a))
                                "agent_id" (agent-id a)
                                "agent_name" (agent-name a)
                                "namespace" (agent-namespace a)
                                "stable" (agent-stable-p a)
                                "to" (or recipient 'null)
                                "seq" (or seq 'null)
                                "content" (text-content
                                           (format nil "Published ~D char(s) ~
~@[to ~A ~]on bus ~A as ~A~@[ (seq ~D)~]."
                                                   (length message) recipient
                                                   (bus-label (agent-bus a))
                                                   (identity-summary a) seq))))))
      ;; The refusal is surfaced with a stable error_type of its own so a caller
      ;; can branch on the taxonomy rather than on the prose, and the condition's
      ;; own report carries the instruction for turning the capability on.
      (direct-addressing-disabled (e)
        (result id (make-ht "isError" t
                            "error_type" "direct-addressing-disabled"
                            "content" (text-content (format nil "bus-publish: ~A" e)))))
      ;; A bare name the bus cannot place is refused rather than turned into an
      ;; id and published to. Joining it to this session's own namespace is what
      ;; used to happen, and across a fleet that spans repositories it minted an
      ;; identity nothing had ever answered to: the record was appended, the
      ;; addressed filter matched no reader, and the caller was handed a seq and
      ;; the word published.
      (unresolvable-recipient (e)
        (result id (make-ht "isError" t
                            "error_type" "unresolvable-recipient"
                            "content" (text-content
                                       (format nil "bus-publish: ~A" e)))))
      ;; A bus name that cannot become a bus root is refused here rather than
      ;; downgraded. Falling back to the session's own bus would put the message
      ;; on a bus the caller did not name while the reply said it succeeded.
      (invalid-bus-name (e)
        (%invalid-argument id (format nil "bus-publish: ~A" e)))
      (no-project-root ()
        (result id (make-ht "isError" t
                            "error_type" "project-root-not-set"
                            "content" (text-content "bus-publish: no project root set. Call fs-set-project-root first.")))))))
