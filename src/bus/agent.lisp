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
                    (#:heartbeat #:dsmr-mcp/src/bus/heartbeat)
                    (#:wal #:dsmr-mcp/src/bus/wal))
  (:export #:agent #:agent-id #:agent-name #:agent-namespace #:agent-stable-p
           #:agent-paths
           #:connect-agent #:disconnect-agent
           #:agent-publish #:agent-receive #:agent-status
           #:agent-skip-to-head))

(in-package #:dsmr-mcp/src/bus/agent)

(defstruct (agent (:constructor %make-agent))
  id namespace stable paths client subscriber)

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
       :namespace namespace
       :stable (and name t)
       :paths paths
       :client (bus:connect-client paths)
       :subscriber (bus:subscribe paths id :feed-timeout-ms feed-timeout-ms)))))

(defun agent-name (agent)
  "The agent's name within its namespace — the trailing segment of its id past the
   namespace prefix. For a stable agent this is the name supplied via agent_id or
   DSMR_BUS_AGENT; for an ephemeral one it is the auto-unique token. This is how an
   agent reads its own handle without parsing the composite id by eye (the
   namespace and a same-named project would otherwise be ambiguous)."
  (let* ((ns (agent-namespace agent))
         (prefix (and ns (concatenate 'string ns "/")))
         (id (agent-id agent)))
    (if (and prefix
             (<= (length prefix) (length id))
             (string= prefix id :end2 (length prefix)))
        (subseq id (length prefix))
        id)))

(defun agent-stable-p (agent)
  "True when this agent has a stable identity (a name was supplied via agent_id or
   DSMR_BUS_AGENT), so it resumes its durable cursor across restarts. NIL for an
   anonymous/ephemeral participant whose cursor does not persist."
  (and (agent-stable agent) t))

(defun agent-publish (agent message)
  "Broadcast MESSAGE (string) onto the bus and return the EXACT broker-assigned seq
   of this message (an integer, or NIL when it could not be matched within the
   bound). The message embeds this agent's stable self-id so the agent's OWN
   receive filters it back out — the agent never gets its own message returned to
   it, with NO cursor manipulation and so no risk of skipping a foreign message.
   The correlation-id match (not WAL position) is what disambiguates a concurrent
   foreign publisher's record. PUBLISH defaults the read-back scan floor to the
   WAL's current highest seq; that floor only BOUNDS the rescan window — its cost
   scales with how much bus traffic accrues above the floor while waiting for the
   id to appear, not with correctness."
  (bus:publish (agent-client agent) message
               :self-id (agent-id agent)))

(defun agent-receive (agent &key (timeout-ms 0) (limit bus:+default-batch-size+))
  "Receive messages addressed to the whole bus that this agent has not yet seen,
   advancing its cursor. With TIMEOUT-MS 0 this is a non-blocking catch-up; with a
   positive timeout it waits up to that long for the first message. Returns a list
   of message strings (most recent last), empty if none. The delivery cursor
   advances over EVERY pending record (including this agent's own), but records
   carrying this agent's own self-id are filtered out of the RETURNED set — the
   receive-side self-echo filter. A foreign record interleaved below this agent's
   own seq was delivered in order and IS returned: no message is skipped.

   LIMIT bounds how many records are DELIVERED, not how many come back. A batch
   made up entirely of this agent's own publishes therefore returns nothing while
   still advancing the cursor past them — correct, not starvation: those records
   are genuinely consumed, and the next call reads the ones after them. LIMIT NIL
   asks for the whole backlog in one delivery."
  (let ((records (if (plusp timeout-ms)
                     (bus:await (agent-subscriber agent)
                                :timeout-ms timeout-ms :limit limit)
                     (bus:poll (agent-subscriber agent) :limit limit)))
        (own (bus:encode-id (agent-id agent)))
        (out '()))
    (dolist (record records (nreverse out))
      (multiple-value-bind (text cid sid)
          (bus:decode-envelope (wal:record-body-string record))
        (declare (ignore cid))
        ;; Keep a legacy un-enveloped message (sid NIL) and any FOREIGN message;
        ;; drop only records carrying this agent's own encoded self-id. The verdict
        ;; goes through the shared FOREIGN-SELF-ID-P so this filter and the pending
        ;; count can never disagree about what delivery returns.
        (when (bus:foreign-self-id-p sid own)
          (push text out))))))

(defun agent-skip-to-head (agent)
  "Give up whatever this agent has not yet read and return how many records that
   was. For a participant returning to a backlog it judges too stale to be worth
   the reading — a deliberate choice, reported so the size of what was dropped is
   on the record."
  (bus:skip-to-head (agent-subscriber agent)))

(defun agent-status (agent)
  "A snapshot of this agent's view of the bus: its own identity (full id, the name
   within the namespace, the namespace, and whether the identity is stable),
   whether a broker is live, how many messages are waiting for it right now, and
   whether a wakeup watcher is currently listening on its behalf.

   PENDING is the self-aware count: only the FOREIGN records delivery would
   actually return, never this agent's own un-consumed publishes (which receive
   filters out). It shares one predicate with AGENT-RECEIVE, so the number here
   and the batch a receive hands back cannot disagree.

   The watcher fields come from the heartbeat a running watch refreshes under this
   agent's identity: LIVE-WATCHER is true only when that beat is fresh, and
   WATCHER-STATUS / WATCHER-AGE-SECONDS carry the detail (a dead or absent watch
   reports \"dead\" with a NIL age). The freshness window is the shared default, so
   this read and the watcher's own --check-live agree on what `live` means."
  (let ((own (bus:encode-id (agent-id agent))))
    (multiple-value-bind (wstatus wage)
        (heartbeat:beat-liveness
         (heartbeat:beat-path (agent-id agent) (heartbeat:default-watch-dir))
         heartbeat:+default-live-window-seconds+)
      (list :id (agent-id agent)
            :name (agent-name agent)
            :namespace (agent-namespace agent)
            :stable (agent-stable-p agent)
            :broker-running (broker:broker-running-p (agent-paths agent))
            :pending (bus:poll-count-foreign (agent-subscriber agent) own)
            :live-watcher (eq wstatus :live)
            :watcher-status (string-downcase (symbol-name wstatus))
            :watcher-age-seconds wage))))

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
