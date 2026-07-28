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
;;;; message independently while sharing the namespace.
;;;;
;;;; A bus is a named, isolated state root. An unset name means the shared
;;;; host-wide bus, which is where everything lands unless something says
;;;; otherwise. Namespaces separate projects within one bus; the bus name
;;;; separates one fleet's traffic from another's, down to a private write-ahead
;;;; log and a private pair of sockets. One process may hold participants on
;;;; several buses at once, each with its own connection, membership and cursor,
;;;; which is how an agent reports into a neighbouring fleet without carrying that
;;;; fleet's traffic everywhere else. Messages are broadcast; coordination is by
;;;; convention.

(defpackage #:dsmr-mcp/src/bus/agent
  (:use #:cl)
  (:local-nicknames (#:broker #:dsmr-mcp/src/bus/broker)
                    (#:bus #:dsmr-mcp/src/bus/bus)
                    (#:heartbeat #:dsmr-mcp/src/bus/heartbeat)
                    (#:roster #:dsmr-mcp/src/bus/roster)
                    (#:selector #:dsmr-mcp/src/bus/selector)
                    (#:wal #:dsmr-mcp/src/bus/wal))
  (:export #:agent #:agent-id #:agent-name #:agent-namespace #:agent-stable-p
           #:agent-paths #:agent-bus
           #:connect-agent #:disconnect-agent #:quiesce-and-leave
           #:agent-publish #:agent-receive #:agent-receive-detailed
           #:*direct-addressing-enabled* #:direct-addressing-enabled-p
           #:direct-addressing-disabled #:direct-addressing-disabled-addressee
           #:delivery #:delivery-author #:delivery-author-id #:delivery-text
           #:agent-status
           #:agent-skip-to-head))

(in-package #:dsmr-mcp/src/bus/agent)

(defstruct (agent (:constructor %make-agent))
  id namespace stable bus paths client subscriber)

(defstruct (delivery (:constructor %make-delivery))
  "One message handed to a reader, with the agent that published it attached.
   AUTHOR is the publisher rendered for display and is always a string, \"unknown\"
   when the record carries no usable id. AUTHOR-ID is the publisher's full bus id,
   or NIL when it could not be established. TEXT is the message body exactly as
   published.

   The author travels WITH the body rather than beside it because the two were
   coming apart at the presentation layer: a body that opens with the addressee's
   name reads as a byline, and readers have attributed messages to the wrong agent
   on the strength of it."
  author author-id text)

(defun connect-agent (namespace &key name bus paths (ensure-broker t)
                                     (feed-timeout-ms 100))
  "Join a bus as one participant. NAMESPACE is the project root; NAME, if given,
   is a stable subagent name (resumes its cursor) and otherwise an ephemeral
   auto-unique name is used.

   BUS names which bus to join. NIL, the default, is the host's unnamed bus, so a
   caller that says nothing lands exactly where it always has. A name selects an
   isolated state root of its own: its own write-ahead log, broker, membership
   lock, cursors and sockets. The name is recorded on the handle, so every
   surface downstream can say which bus a participant is speaking on rather than
   assuming there is only one. Signals SELECTOR:INVALID-BUS-NAME for a name that
   cannot be turned into a usable root, and connects nothing when it does.

   PATHS overrides the derivation outright and is how a test points a participant
   at a bus root of its own choosing; supplying it makes BUS purely descriptive.
   Unless ENSURE-BROKER is nil, a detached broker is spawned if none is running
   on the resolved bus. Returns an AGENT handle."
  (let ((paths (or paths (broker:make-bus-paths (selector:bus-root bus)))))
    (broker:ensure-bus-dirs paths)
    (when ensure-broker (broker:ensure-broker paths))
    (let ((id (bus:agent-id namespace :name name)))
      (%make-agent
       :id id
       :namespace namespace
       :stable (and name t)
       :bus bus
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

(defvar *direct-addressing-enabled* nil
  "Whether this process may publish a message naming one recipient.

   NIL by default, and deliberately inert. The capability exists because the
   busmaster holds every participant's identity, and once it does, naming one of
   them is the obvious thing to want. It is off because the arrangement actually
   in use is hub and spoke: a leader talks to each worker and each worker talks
   to the leader. The standing site rule that keeps it that way is not revised by
   this code, and its reasoning still holds: several workers converging on one
   point is usually one claim echoing rather than corroboration.

   Bind this to true for one process, or set DSMR_BUS_DIRECT_ADDRESSING to 1,
   true or yes for one repository, to turn the capability on.")

(defun direct-addressing-enabled-p ()
  "True when this process may publish a message naming one recipient.

   *DIRECT-ADDRESSING-ENABLED* wins when it is true; otherwise the environment is
   consulted, so an operator can turn the capability on for one repository from
   its .envrc without touching any code. The environment is read on every call
   rather than cached at load, so a value set after the image came up still
   counts."
  (or (and *direct-addressing-enabled* t)
      (and (member (uiop:getenv "DSMR_BUS_DIRECT_ADDRESSING")
                   '("1" "true" "yes") :test #'string=)
           t)))

(define-condition direct-addressing-disabled (error)
  ((addressee :initarg :addressee :initform nil
              :reader direct-addressing-disabled-addressee))
  (:report (lambda (condition stream)
             (format stream
                     "dsmr-mcp bus: direct addressing is off, so nothing was ~
                      published to ~S. Set DSMR_BUS_DIRECT_ADDRESSING to 1 in ~
                      the repository that needs it, or bind ~
                      *DIRECT-ADDRESSING-ENABLED*."
                     (direct-addressing-disabled-addressee condition))))
  (:documentation
   "Signalled when a publish names a recipient while direct addressing is off.

    Nothing is sent. Refusing is the whole point: broadcasting the message
    instead would put something its sender believed was private in front of the
    entire fleet, and the sender would have no way to tell it had happened."))

(defun agent-publish (agent message &key to)
  "Put MESSAGE (string) on the bus and return the EXACT broker-assigned seq
   of this message (an integer, or NIL when it could not be matched within the
   bound). The message embeds this agent's stable self-id so the agent's OWN
   receive filters it back out — the agent never gets its own message returned to
   it, with NO cursor manipulation and so no risk of skipping a foreign message.
   The correlation-id match (not WAL position) is what disambiguates a concurrent
   foreign publisher's record. PUBLISH defaults the read-back scan floor to the
   WAL's current highest seq; that floor only BOUNDS the rescan window — its cost
   scales with how much bus traffic accrues above the floor while waiting for the
   id to appear, not with correctness.

   TO names one participant by its full bus id, and only that participant is
   handed the message. The record still goes to the fleet's own log and every
   member's cursor still advances over it; what changes is who is shown it. An
   addressed message is therefore filtered, not private.

   Naming a recipient while direct addressing is off signals
   DIRECT-ADDRESSING-DISABLED and publishes nothing. It does not fall back to a
   broadcast, because a message its sender believed had one reader arriving in
   front of the whole fleet is a worse outcome than a refusal the sender can
   read."
  (when (and to (not (direct-addressing-enabled-p)))
    (error 'direct-addressing-disabled :addressee to))
  (bus:publish (agent-client agent) message
               :self-id (agent-id agent)
               :to to))

(defun agent-receive-detailed (agent &key (timeout-ms 0)
                                         (limit bus:+default-batch-size+))
  "Receive as AGENT-RECEIVE does, but return a DELIVERY per message instead of a
   bare string: the text, the publishing agent's id, and a rendering of that
   publisher fit to show a reader. Delivery semantics, the cursor, the self-echo
   filter and LIMIT are exactly AGENT-RECEIVE's, which is defined in terms of this
   function.

   The author comes off the same envelope field the self-echo filter already
   reads, so a message and the name attached to it cannot come apart. Resolving
   the rendering here rather than at the tool boundary is deliberate: this is the
   layer that knows the reader's own namespace, and that is what decides whether a
   sender is shown by bare name or qualified by the project it publishes from."
  (let ((records (if (plusp timeout-ms)
                     (bus:await (agent-subscriber agent)
                                :timeout-ms timeout-ms :limit limit)
                     (bus:poll (agent-subscriber agent) :limit limit)))
        (own (bus:encode-id (agent-id agent)))
        (namespace (agent-namespace agent))
        (out '()))
    (dolist (record records (nreverse out))
      (multiple-value-bind (text cid sid addressee)
          (bus:decode-envelope (wal:record-body-string record))
        (declare (ignore cid))
        ;; Two halves to one verdict. Drop records carrying this agent's own
        ;; encoded self-id, so a publisher never gets its own message back; and
        ;; drop records naming somebody else, so addressed mail reaches only the
        ;; participant it names. Everything else is kept, a legacy un-enveloped
        ;; message (sid NIL) included. The cursor has already advanced over all
        ;; of them either way: filtering here decides what is shown, never where
        ;; the cursor sits, because a reader that stopped at other people's mail
        ;; would pin the log. The verdict goes through the shared DELIVERABLE-P
        ;; so this filter and the pending count cannot disagree.
        (when (bus:deliverable-p sid addressee own)
          (push (%make-delivery :author (bus:author-display sid namespace)
                                :author-id (bus:decode-id sid)
                                :text text)
                out))))))

(defun agent-receive (agent &key (timeout-ms 0) (limit bus:+default-batch-size+))
  "Receive messages addressed to the whole bus, or to this agent by name, that it
   has not yet seen, advancing its cursor. With TIMEOUT-MS 0 this is a non-blocking catch-up; with a
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
   asks for the whole backlog in one delivery.

   This is the text-only view of AGENT-RECEIVE-DETAILED, kept for callers with no
   use for the author. A caller that PRESENTS a message to a reader should use the
   detailed form instead: bodies conventionally open with the addressee's name,
   which reads as a byline, so a body shown without its author invites
   misattribution."
  (mapcar #'delivery-text
          (agent-receive-detailed agent :timeout-ms timeout-ms :limit limit)))

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

   PENDING is the self-aware count: only the records delivery would actually
   return, never this agent's own un-consumed publishes and never mail addressed
   to somebody else, both of which receive filters out. It shares one predicate
   with AGENT-RECEIVE, so the number here and the batch a receive hands back
   cannot disagree.

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

(defun %record-departure (agent)
  "Put AGENT's departure on its bus's roster and return the universal time now on
   record for it, or NIL when nothing could be written.

   An existing departure is left exactly as it stands. That time is what the
   busmaster ages a held cursor against, so a repeated leave must not push it
   forward: doing so would turn holding a cursor into keeping it forever.

   A failure is named on stderr and swallowed. The caller is on its way out and
   has nowhere to handle it."
  (let ((roster-dir (broker:bus-paths-roster-dir (agent-paths agent)))
        (id (agent-id agent)))
    (handler-case
        (let ((existing (roster:entry id roster-dir)))
          (if (and (eq (roster:entry-status existing) :departed)
                   (integerp (roster:entry-departed-at existing)))
              (roster:entry-departed-at existing)
              (roster:entry-departed-at (roster:disenroll id roster-dir))))
      (error (e)
        (format *error-output*
                "dsmr-mcp bus: could not record ~A leaving: ~A~%" id e)
        nil))))

(defun quiesce-and-leave (agent &key (max-batches 100)
                                     (limit bus:+default-batch-size+))
  "Leave the bus cleanly: read whatever is still waiting for AGENT, put its
   departure on this bus's roster, and release its connection.

   Returns (VALUES DRAINED DEPARTED-AT BOUND-REACHED). DRAINED is how many
   messages came back on the way out. DEPARTED-AT is the universal time now on
   record, or NIL when the roster could not be written. BOUND-REACHED is true
   when the drain stopped on MAX-BATCHES with records still arriving, so a
   firehose cannot hold a departing agent indefinitely; the records left behind
   are not lost, they are simply not read by an agent that is leaving.

   The roster entry written here is what transfers custody of this agent's
   cursor, and that is the design rather than a workaround. A cursor is normally
   written by exactly one process, the session consuming the bus through it,
   which is why the watcher binary refuses to touch one: writing it from outside
   would move a live session's delivery position behind its back. On a clean
   leave that session is gone, and the per-bus busmaster, which already owns the
   lifecycle of the cursor directory, takes the file over. It advances the cursor
   with fleet traffic so a departed participant can never pin the log, and
   retires it once the departure is old enough. The entry written here is what
   makes that handover explicit and datable; an agent that vanishes without one
   gets none of it.

   Leaving twice is safe. The second call finds the departure already recorded,
   leaves the original time in place, and reports nothing drained.

   A roster write that fails is reported and not signalled, and the disconnect
   happens either way. An agent that cannot leave is a worse outcome than one
   whose departure went unrecorded.

   Membership is not upgraded, probed or otherwise touched. This agent holds two
   shared locks on the bus's membership file, one for its client and one for its
   subscriber, so it could never win an upgrade against itself, and a won upgrade
   has no release anywhere in this tree and would block every later join.
   Leaving therefore does not make the clean-exit archive reachable and does not
   pretend to."
  (let ((drained 0)
        (bound-reached t)
        (departed-at nil))
    (unwind-protect
         (progn
           (if (agent-subscriber agent)
               (dotimes (batch max-batches)
                 (declare (ignore batch))
                 (let ((records (agent-receive agent :timeout-ms 0 :limit limit)))
                   (cond (records (incf drained (length records)))
                         (t (setf bound-reached nil)
                            (return)))))
               (setf bound-reached nil))
           (setf departed-at (%record-departure agent)))
      (disconnect-agent agent))
    (values drained departed-at bound-reached)))
