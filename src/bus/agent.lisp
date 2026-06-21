;;;; src/bus/agent.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; The agent layer: the convenience a caller (the MCP tool surface) uses to take
;;;; part in the bus as one named participant. It bundles the three things a
;;;; participant needs — a guarantee a broker is running, a client to publish
;;;; with, and a subscriber with a durable cursor to receive through — behind one
;;;; handle, and it constructs the participant's identity from a project namespace
;;;; plus an optional stable name.
;;;;
;;;; Identity follows the locked model: <project-namespace>/<name>. A given name
;;;; resumes its cursor across restarts; an omitted name yields an auto-unique,
;;;; ephemeral id, so several anonymous subagents in one project each receive every
;;;; message independently while sharing the namespace. The bus itself is a single
;;;; host-wide instance, so agents in different projects coexist on it under
;;;; different namespaces. Messages are broadcast; coordination is by convention.

(defpackage #:dsmr-mcp/src/bus/agent
  (:use #:cl)
  (:local-nicknames (#:broker #:dsmr-mcp/src/bus/broker)
                    (#:bus #:dsmr-mcp/src/bus/bus)
                    (#:wal #:dsmr-mcp/src/bus/wal))
  (:export #:agent #:agent-id #:agent-paths
           #:connect-agent #:disconnect-agent
           #:agent-publish #:agent-receive #:agent-status))

(in-package #:dsmr-mcp/src/bus/agent)

(defstruct (agent (:constructor %make-agent))
  id paths client subscriber)

(defun connect-agent (namespace &key name paths (ensure-broker t) (feed-timeout-ms 100))
  "Join the bus as one participant. NAMESPACE is the project root; NAME, if given,
   is a stable subagent name (resumes its cursor) and otherwise an ephemeral
   auto-unique name is used. PATHS defaults to the host-wide bus. Unless
   ENSURE-BROKER is nil, a detached broker is spawned if none is running. Returns
   an AGENT handle."
  (let ((paths (or paths (broker:make-bus-paths))))
    (broker:ensure-bus-dirs paths)
    (when ensure-broker (broker:ensure-broker paths))
    (let ((id (bus:agent-id namespace :name name)))
      (%make-agent
       :id id
       :paths paths
       :client (bus:connect-client paths)
       :subscriber (bus:subscribe paths id :feed-timeout-ms feed-timeout-ms)))))

(defun agent-publish (agent message)
  "Broadcast MESSAGE (string or octet vector) onto the bus. Returns MESSAGE."
  (bus:publish (agent-client agent) message))

(defun agent-receive (agent &key (timeout-ms 0))
  "Receive messages addressed to the whole bus that this agent has not yet seen,
   advancing its cursor. With TIMEOUT-MS 0 this is a non-blocking catch-up; with a
   positive timeout it waits up to that long for the first message. Returns a list
   of message strings (most recent last), empty if none."
  (let ((records (if (plusp timeout-ms)
                     (bus:await (agent-subscriber agent) :timeout-ms timeout-ms)
                     (bus:poll (agent-subscriber agent)))))
    (mapcar #'wal:record-body-string records)))

(defun agent-status (agent)
  "A snapshot of this agent's view of the bus: its id, whether a broker is live,
   and how many messages are waiting for it right now."
  (list :id (agent-id agent)
        :broker-running (broker:broker-running-p (agent-paths agent))
        :pending (bus:poll-count (agent-subscriber agent))))

(defun disconnect-agent (agent)
  "Release the agent's client and subscriber. The durable cursor is left in place
   so a named agent resumes where it left off next time."
  (when (agent-client agent)
    (bus:disconnect-client (agent-client agent))
    (setf (agent-client agent) nil))
  (when (agent-subscriber agent)
    (bus:unsubscribe (agent-subscriber agent))
    (setf (agent-subscriber agent) nil))
  (values))
