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
                #:session-agent #:identity-summary #:no-project-root)
  (:import-from #:dsmr-mcp/src/bus/bus
                #:+default-batch-size+)
  (:import-from #:dsmr-mcp/src/bus/agent
                #:agent-receive #:agent-id #:agent-name #:agent-namespace
                #:agent-stable-p #:agent-skip-to-head #:agent-status))

(in-package #:dsmr-mcp/src/tools/bus-receive)

(defclass bus-receive-tool (mcp-tool)
  ((dsmr-mcp/src/tools/base::name
    :allocation :class :initform "bus-receive")
   (dsmr-mcp/src/tools/base::description
    :allocation :class
    :initform "Receive messages from the coordination bus that this agent has \
not yet seen, advancing its cursor so each is delivered once. Delivery is \
bounded: the oldest pending messages come back a page at a time and \
remaining_pending says how many are still waiting, so a long backlog is walked \
forward across calls rather than arriving all at once. Returns immediately by \
default; set timeout_ms to wait that long for the first message. A named agent \
resumes where it left off across restarts.")
   (dsmr-mcp/src/tools/base::input-schema
    :allocation :class
    :initform `(:object
                :properties
                ((agent_id
                  :type :string
                  :description "Optional stable agent name to receive as (under \
this project's namespace). Omit to use the session's anonymous default agent.")
                 (ephemeral
                  :type :boolean
                  :description "Set true to force a fresh one-shot ephemeral \
identity for this subagent, opting out of the project's stable DSMR_BUS_AGENT \
identity so it never resumes the main agent's cursor.")
                 (timeout_ms
                  :type :integer
                  :description "Milliseconds to wait for the first message before \
returning empty (default 0 = non-blocking catch-up).")
                 (limit
                  :type :integer
                  :description
                  ,(format nil "Maximum number of messages to deliver in this \
call (default ~D). Delivery is oldest-first and paginated: the cursor advances \
only over what was delivered, so the remainder is not lost and is picked up by \
the next call."
                           +default-batch-size+))
                 (skip_to_head
                  :type :boolean
                  :description "Set true to DISCARD every pending message by \
advancing the cursor straight to the current head of the bus. The discarded \
messages are never delivered to this agent; the abandoned field reports how \
many were given up. No messages are received in the same call."))
                :required ())))
  (:metaclass mcp-tool-class)
  (:documentation "MCP tool: receive pending coordination-bus messages."))

(c2mop:ensure-finalized (find-class 'bus-receive-tool))

(defun %identity-fields (a)
  "The identity key/value pairs every bus-receive result carries, as a flat list
   ready to splice into make-ht. Both the receive and the abandon reply report
   who the caller resolved to, so an agent never has to infer its own identity
   from the traffic it happens to see."
  (list "agent_id" (agent-id a)
        "agent_name" (agent-name a)
        "namespace" (agent-namespace a)
        "stable" (agent-stable-p a)))

(defun %receive-content (a messages remaining)
  "The human-readable text for a receive reply: who the caller is, what it got,
   and — when the batch stopped short of the backlog — that more is still
   waiting. A caller told only what it received cannot tell a page from the whole
   queue, and an agent that believes it is caught up when it is not is the
   starvation this reports away."
  (let ((tail (if (plusp remaining)
                  (format nil "~%~D more message(s) still pending — call \
bus-receive again to continue."
                          remaining)
                  "")))
    (if messages
        (format nil "You are ~A.~%~D message(s):~%~{- ~A~^~%~}~A"
                (identity-summary a) (length messages) messages tail)
        (format nil "You are ~A. No new messages.~A"
                (identity-summary a) tail))))

(defun %invalid-argument (id message)
  "An invalid-argument refusal in the shape every bus-receive guard returns."
  (result id (make-ht "isError" t
                      "error_type" "invalid-argument"
                      "content" (text-content message))))

(defmethod tool-handle ((tool bus-receive-tool) id args)
  (let ((agent-id-arg (gethash "agent_id" args))
        (ephemeral (and (gethash "ephemeral" args) t))
        (timeout (or (gethash "timeout_ms" args) 0))
        (limit (gethash "limit" args))
        (skip-to-head (and (gethash "skip_to_head" args) t)))
    (unless (and (integerp timeout) (>= timeout 0))
      (return-from tool-handle
        (%invalid-argument
         id "bus-receive: timeout_ms must be a non-negative integer.")))
    ;; Refuse a bad limit here rather than letting it reach the bus core, where a
    ;; zero or negative value would degrade to the default batch silently and a
    ;; non-integer would error deep inside the log reader. Both are worse than
    ;; telling the caller what was wrong with the value it sent.
    (unless (or (null limit) (and (integerp limit) (plusp limit)))
      (return-from tool-handle
        (%invalid-argument
         id "bus-receive: limit must be a positive integer.")))
    (handler-case
        (let ((a (session-agent (tool-session tool) agent-id-arg
                                :ephemeral ephemeral)))
          (if skip-to-head
              ;; Abandonment and receipt are distinct intents. Doing both in one
              ;; call would make the abandoned count ambiguous — a caller could
              ;; not tell what it was handed from what it gave up.
              (let ((abandoned (agent-skip-to-head a)))
                (result id (apply #'make-ht
                                  "messages" (vector)
                                  "count" 0
                                  "abandoned" abandoned
                                  "content"
                                  (text-content
                                   (format nil "You are ~A. Abandoned ~D pending \
message(s) by skipping to the head of the bus; they will not be delivered."
                                           (identity-summary a) abandoned))
                                  (%identity-fields a))))
              (let* ((messages (agent-receive a :timeout-ms timeout
                                                :limit (or limit
                                                           +default-batch-size+)))
                     ;; Read what remains after the delivery rather than
                     ;; threading a second value down through every cursor, bus
                     ;; and agent caller: only this boundary wants the figure,
                     ;; and reading it costs a log scan that materializes no
                     ;; records.
                     (remaining (getf (agent-status a) :pending)))
                (result id (apply #'make-ht
                                  "messages" (coerce messages 'vector)
                                  "count" (length messages)
                                  "remaining_pending" remaining
                                  "content" (text-content
                                             (%receive-content a messages remaining))
                                  (%identity-fields a))))))
      (no-project-root ()
        (result id (make-ht "isError" t
                            "error_type" "project-root-not-set"
                            "content" (text-content "bus-receive: no project root set. Call fs-set-project-root first.")))))))
