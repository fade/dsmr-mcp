;;;; src/tools/bus-publish.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; MCP tool: broadcast a message onto the coordination bus so sister agents and
;;;; subagents receive it. Dispatcher-side and mode-independent — it talks to the
;;;; bus, not a Lisp image.

(defpackage #:dsmr-mcp/src/tools/bus-publish
  (:use #:cl)
  ;; The bus facade is reached under a nickname purely for AGENT-ID, the id
  ;; CONSTRUCTOR. The struct ACCESSOR of the same name is imported below from the
  ;; agent leaf, and the two would otherwise collide on one symbol.
  (:local-nicknames (#:bus #:dsmr-mcp/src/bus/bus))
  (:import-from #:dsmr-mcp/src/tools/base
                #:mcp-tool #:mcp-tool-class #:tool-handle #:tool-session)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:make-ht #:result #:text-content)
  (:import-from #:dsmr-mcp/src/tools/bus-helpers
                #:session-agent #:identity-summary #:no-project-root)
  (:import-from #:dsmr-mcp/src/bus/agent
                #:agent-publish #:agent-id #:agent-name #:agent-namespace
                #:agent-stable-p #:direct-addressing-disabled))

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
NAMESPACE/NAME bus id or a bare name in this project's namespace. Only that one \
participant is handed the message; no other member of the bus is shown it. This \
is NOT privacy: the record still travels on the fleet's shared log and any \
member can read it there, so naming a recipient filters delivery and does not \
confine the text. Direct addressing is off unless the repository that needs it \
sets DSMR_BUS_DIRECT_ADDRESSING to 1; naming a recipient while it is off \
publishes nothing and returns an error saying so. Omit to broadcast.")
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

(defun %invalid-argument (id message)
  "An invalid-argument refusal in the shape every bus-publish guard returns."
  (result id (make-ht "isError" t
                      "error_type" "invalid-argument"
                      "content" (text-content message))))

(defun %qualify (recipient namespace)
  "RECIPIENT as a full bus id. A value that already carries a separator is taken
   as an id and used as given; a bare name is qualified with NAMESPACE, this
   session's own project root, exactly as a participant's id is built.

   So an agent names a sister by the name it answers to and never types a project
   root, and a bare name can never reach into another project's namespace by
   accident: two projects may both run an agent called valis, and a bare name
   here always means this session's one."
  (if (find #\/ recipient)
      recipient
      (bus:agent-id namespace :name recipient)))

(defmethod tool-handle ((tool bus-publish-tool) id args)
  (let ((message (gethash "message" args))
        (agent-id-arg (gethash "agent_id" args))
        (to-arg (gethash "to" args))
        (ephemeral (and (gethash "ephemeral" args) t)))
    (unless (and message (stringp message))
      (return-from tool-handle
        (%invalid-argument id "bus-publish: message must be a string.")))
    ;; A recipient is checked before the session is touched, so a call that
    ;; names one badly connects nothing and publishes nothing. An empty string
    ;; is refused with the rest: qualified, it would name <namespace>/ , which
    ;; is nobody, and the message would then be delivered to no reader at all.
    (unless (or (null to-arg) (and (stringp to-arg) (plusp (length to-arg))))
      (return-from tool-handle
        (%invalid-argument id "bus-publish: to must be a non-empty string, \
either a full NAMESPACE/NAME bus id or a bare name in this project's \
namespace.")))
    (handler-case
        (let* ((a (session-agent (tool-session tool) agent-id-arg :ephemeral ephemeral))
               (recipient (and to-arg (%qualify to-arg (agent-namespace a))))
               (seq (agent-publish a message :to recipient)))
          (result id (make-ht "published" t
                              "agent_id" (agent-id a)
                              "agent_name" (agent-name a)
                              "namespace" (agent-namespace a)
                              "stable" (agent-stable-p a)
                              "to" (or recipient 'null)
                              "seq" (or seq 'null)
                              "content" (text-content
                                         (format nil "Published ~D char(s) to ~
~:[the bus~;~:*~A~] as ~A~@[ (seq ~D)~]."
                                                 (length message) recipient
                                                 (identity-summary a) seq)))))
      ;; The refusal is surfaced with a stable error_type of its own so a caller
      ;; can branch on the taxonomy rather than on the prose, and the condition's
      ;; own report carries the instruction for turning the capability on.
      (direct-addressing-disabled (e)
        (result id (make-ht "isError" t
                            "error_type" "direct-addressing-disabled"
                            "content" (text-content (format nil "bus-publish: ~A" e)))))
      (no-project-root ()
        (result id (make-ht "isError" t
                            "error_type" "project-root-not-set"
                            "content" (text-content "bus-publish: no project root set. Call fs-set-project-root first.")))))))
