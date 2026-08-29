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
  (:import-from #:dsmr-mcp/src/tools/status-fields
                #:reported-field)
  (:import-from #:dsmr-mcp/src/tools/bus-helpers
                #:session-agent #:bus-label #:identity-summary #:no-project-root)
  (:import-from #:dsmr-mcp/src/bus/bus
                #:+default-batch-size+)
  (:import-from #:dsmr-mcp/src/bus/selector
                #:invalid-bus-name)
  (:import-from #:dsmr-mcp/src/bus/broker
                #:bus-paths-wal #:cursor-path-for)
  (:import-from #:dsmr-mcp/src/bus/cursor
                #:make-subscriber #:cursor-and-head #:stranded-reason)
  (:import-from #:dsmr-mcp/src/bus/agent
                #:agent-receive-detailed #:agent-id #:agent-name #:agent-namespace
                #:agent-bus #:agent-paths #:delivery-author #:delivery-author-id
                #:delivery-text
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
resumes where it left off across restarts. Every message comes back with the \
agent that published it in its own author field, and the rendered text labels \
each message with that author: a body opening with a name is ADDRESSING that \
agent, not signing as it. \
Every answer, delivered or empty, also says where this agent's cursor sits in \
the log it read and what the page bound was spent on, so an empty reply says \
which kind of empty it is. A caught-up reader and a reader whose recorded \
position the log no longer holds both receive nothing, and cursor_state is what \
tells them apart; a page consumed by mail addressed to other participants also \
delivers nothing, and the page field is what reconciles that with a \
remaining_pending above zero.")
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
many were given up. No messages are received in the same call.")
                 (bus
                  :type :string
                  :description "Optional named bus to receive from. Omit to use \
this session's bus, which is DSMR_BUS_SELECTOR from the repository's .envrc \
when that is set and the shared host-wide bus otherwise. A name that cannot \
become a bus is refused; nothing is ever read from the shared bus in place of a \
bus that was named."))
                :required ())))
  (:metaclass mcp-tool-class)
  (:documentation "MCP tool: receive pending coordination-bus messages."))

(c2mop:ensure-finalized (find-class 'bus-receive-tool))

(defun %identity-fields (a)
  "The identity key/value pairs every bus-receive result carries, as a flat list
   ready to splice into make-ht. Both the receive and the abandon reply report
   who the caller resolved to, so an agent never has to infer its own identity
   from the traffic it happens to see.

   The bus is part of that answer. An agent joined to two buses under one name
   is two participants with two cursors, and a reply that named only the agent
   would leave a reader unable to tell which of the two it had just drained."
  (list "agent_id" (agent-id a)
        "agent_name" (agent-name a)
        "namespace" (agent-namespace a)
        "bus" (bus-label (agent-bus a))
        "stable" (agent-stable-p a)))

(defun %message-fields (d)
  "One delivered message as the object a client reads: the body, the author
   rendered for display, and the author's full bus id. The author is a field of
   its own so a consumer never has to recover it by parsing prose, and never has
   to guess it from a body that opens with somebody's name. AUTHOR-ID is JSON null
   when the record carried no id that would decode."
  (make-ht "author" (delivery-author d)
           "author_id" (or (delivery-author-id d) 'null)
           "text" (delivery-text d)))

(defun %message-block (index total d)
  "One delivered message rendered as a header line naming its author followed by
   the body verbatim.

   The header is bracketed, counted and labelled so it cannot be read as part of
   the body. That is the whole point of the shape: bodies here conventionally open
   with the name of the agent being ADDRESSED, which reads as a byline, and agents
   have repeatedly credited a message to the wrong sender on the strength of it.
   An author label that looked like ordinary prose would not fix anything."
  (format nil "[~D/~D] author: ~A~%~A"
          index total (delivery-author d) (delivery-text d)))

(defun %standing (a)
  "Where this caller's durable position sits in the log it is reading, with
   nothing folded away: (values cursor head recorded-generation log-generation
   stranded-reason).

   The position is read from the cursor file and the head from the log, through
   the accessor that returns both as they are. The count of what is deliverable
   cannot answer this question and is not asked: it reports zero for a caught-up
   reader and zero for a reader whose position is past the end of the log, which
   is precisely the pair a caller is trying to tell apart here.

   The head and the log's generation are read once and handed to the strand
   check, so establishing where a reader stands costs one pass over the log
   rather than two."
  (let* ((paths (agent-paths a))
         (position (make-subscriber (agent-id a)
                                    (bus-paths-wal paths)
                                    (cursor-path-for paths (agent-id a)))))
    (multiple-value-bind (cursor head recorded current)
        (cursor-and-head position)
      (values cursor head recorded current
              (stranded-reason position :head head :log-generation current)))))

(defun %cursor-word (reason)
  "The one word for a stranded reason, in the vocabulary the bus surface already
   uses for it, and JSON null when the position is a sound one."
  (case reason
    (:cursor-above-head "cursor-above-head")
    (:generation-mismatch "generation-mismatch")
    (t 'null)))

(defun %cursor-fields (cursor head recorded current reason &key (moment :read-from))
  "The cursor-versus-head key/value pairs every receive answer carries, as a flat
   list ready to splice into make-ht.

   They are here on every call, delivered or empty, sound position or not. A fact
   that appeared only when something was wrong would make its absence the
   ordinary case, and its absence is exactly what a broken read looks like.

   The classification is what closes the failure this reports: a reader caught up
   with its log and a reader holding a position that log no longer has both
   receive nothing, and until now their two answers were identical.

   MOMENT says which position these values describe, because the two replies this
   verb sends describe different ones and a reader cannot tell from the numbers.
   A receive reports the position it READ FROM: that is the only moment at which
   a position recorded against a replaced log is visible at all, since reading
   past it rewrites the record against the log in hand. An abandonment reports
   where it LEFT the reader, because moving the position is the whole intent of
   that call and reporting the state it just repaired would read as a repair that
   did not happen."
  (list
   "cursor" cursor
   "head" head
   "recorded_generation" (or recorded 'null)
   "log_generation" current
   "stranded_reason" (%cursor-word reason)
   "cursor_state"
   (reported-field (cond (reason "stranded")
                         ((< cursor head) "behind")
                         (t "caught-up"))
                   :establishes
                   (ecase moment
                     (:read-from "the position this call read from, compared against the head of the log that position names and the generation that log is on, all three read from disk before anything was delivered")
                     (:left-at "the position this call left this identity at, compared against the head of the log that position names and the generation that log is on, all three read from disk after the cursor was moved"))
                   :does-not-establish "an empty delivery establishes that nothing addressed to this identity sits past this position in the log as it stands now. It does not establish that no message was ever published, and it does not establish that this identity is the one a sender addressed: a message naming somebody else is filtered out of what you are shown."
                   :basis "durable-record"
                   :red-condition "the position names a record past the end of the log, or names a generation the log has since left behind. Either way what this identity missed is in a log that is no longer being read, and reading on from here delivers the replacement log's traffic instead.")))

(defun %page-fields (limit records-read own-echo elsewhere)
  "What this call's page bound was spent on, as a flat list ready to splice into
   make-ht.

   The bound counts records READ, the cursor advances over every record read, and
   the recipient filter runs afterwards. So a page spent on mail addressed to
   other participants delivers nothing, advances normally, and leaves a real
   backlog still counted behind it. Two fleets read the log by hand over that
   pair of statements, because the answer gave them nothing to reconcile the two
   with."
  (list
   "page"
   (reported-field (make-ht "limit" limit
                            "records_read" records-read
                            "filtered_own_echo" own-echo
                            "filtered_addressed_elsewhere" elsewhere)
                   :establishes "how many records this call read past the cursor under its page bound, and how many of those the delivery filter withheld: the ones this caller published itself, and the ones naming another participant"
                   :does-not-establish "a page spent on other participants' mail does not establish that nothing is waiting. An empty delivery beside a non-zero remaining_pending is the ordinary consequence of a bounded page on a bus carrying addressed traffic, and it is not evidence of a stranded position: a stranded position reports nothing pending at all, so a pending count above zero is positive evidence that the cursor is not past the head. Raising limit past the withheld records delivers what is behind them in one call."
                   :basis "active-probe")))

(defun %cursor-sentence (cursor head reason)
  "Where this reader stands, in one sentence for a person.

   The stranded cases say what the state is and what to do about it, because a
   reader who never opens the payload is exactly the reader this exists for. The
   sound case still states both numbers: an answer that went quiet whenever
   nothing was wrong would make silence the ordinary case, and silence is what
   the broken read looks like."
  (case reason
    (:cursor-above-head
     (format nil "Your position on this bus is ~D and the log's head is ~D. \
Nothing can sit past the end of a log, so this position will never be delivered \
anything: the log was replaced while this identity held a place in the one \
before it. Put the position back inside the log to start receiving again."
             cursor head))
    (:generation-mismatch
     (format nil "Your position on this bus is ~D, taken against a log that has \
since been replaced, and the head of the log now in place is ~D. The number \
reads as merely behind and is not: reading on from here delivers the \
replacement log's traffic, and what was missed is in the sealed log."
             cursor head))
    (t (format nil "This call read from position ~D of a log whose head is ~D."
               cursor head))))

(defun %page-sentence (limit records-read own-echo elsewhere)
  "What this call's page went on, when some of it went to records the reader is
   not shown. Empty when everything read was deliverable, since a page with
   nothing withheld has nothing to reconcile."
  (let ((withheld (+ own-echo elsewhere)))
    (if (plusp withheld)
        (format nil "~%~%This call read ~D record(s) under a limit of ~D, of \
which ~D addressed to another participant and ~D published by you: your cursor \
advanced over all of them and none was shown to you. Raise limit to walk past \
them in one call."
                records-read limit elsewhere own-echo)
        "")))

(defun %receive-content (a deliveries remaining cursor head reason
                         limit records-read own-echo elsewhere)
  "The human-readable text for a receive reply: who the caller is, who wrote each
   message it got, and, when the batch stopped short of the backlog, that more is
   still waiting. A caller told only what it received cannot tell a page from the
   whole queue, and an agent that believes it is caught up when it is not is the
   starvation this reports away.

   Where the reader's position sits is part of the text and not only of the
   payload. The answer this exists to correct was the words \"No new messages\"
   standing alone, which read the same to a reader caught up with the bus and to
   one holding a position the bus no longer has."
  (let ((tail (if (plusp remaining)
                  (format nil "~%~%~D more message(s) still pending. Call \
bus-receive again to continue."
                          remaining)
                  ""))
        (standing (format nil "~%~%~A" (%cursor-sentence cursor head reason)))
        (page (%page-sentence limit records-read own-echo elsewhere)))
    (if deliveries
        (format nil "You are ~A.~%~D message(s):~%~%~{~A~^~%~%~}~A~A~A"
                (identity-summary a) (length deliveries)
                (let ((total (length deliveries))
                      (index 0))
                  (mapcar (lambda (d) (%message-block (incf index) total d))
                          deliveries))
                tail standing page)
        (format nil "You are ~A. No new messages.~A~A~A"
                (identity-summary a) tail standing page))))

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
        (bus-arg (gethash "bus" args))
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
    ;; An empty bus is refused rather than read as "no bus named": resolved, it
    ;; would fall through to whatever bus the session already speaks on, and a
    ;; caller that asked for one fleet's traffic would be handed another's while
    ;; the reply reported success.
    (unless (or (null bus-arg) (and (stringp bus-arg) (plusp (length bus-arg))))
      (return-from tool-handle
        (%invalid-argument
         id "bus-receive: bus must be a non-empty string naming a bus. Omit it \
to receive from this session's own bus.")))
    (handler-case
        (let ((a (session-agent (tool-session tool) agent-id-arg
                                :ephemeral ephemeral :bus bus-arg)))
          (if skip-to-head
              ;; Abandonment and receipt are distinct intents. Doing both in one
              ;; call would make the abandoned count ambiguous: a caller could
              ;; not tell what it was handed from what it gave up.
              ;;
              ;; Where the cursor is left is reported here too. Abandoning is
              ;; the one call that MOVES the position on purpose, so a caller
              ;; that has just given up a backlog is owed the same statement of
              ;; where it now stands as a caller that read one.
              (let ((abandoned (agent-skip-to-head a)))
                (multiple-value-bind (cursor head recorded current reason)
                    (%standing a)
                  (result id (apply #'make-ht
                                    "messages" (vector)
                                    "count" 0
                                    "abandoned" abandoned
                                    "content"
                                    (text-content
                                     (format nil "You are ~A. Abandoned ~D \
pending message(s) by skipping to the head of the bus; they will not be \
delivered.~%~%~A"
                                             (identity-summary a) abandoned
                                             (%cursor-sentence cursor head
                                                               reason)))
                                    (append
                                     (%cursor-fields cursor head recorded
                                                     current reason
                                                     :moment :left-at)
                                     (%identity-fields a))))))
              (let ((page (or limit +default-batch-size+)))
                ;; The position is read BEFORE the delivery, from the cursor
                ;; file and the log rather than from the count of what is
                ;; deliverable. Two reasons, and both matter.
                ;;
                ;; The count clamps, so it answers zero for a reader caught up
                ;; and zero for a reader whose position the log no longer holds;
                ;; sourcing the fact from it would reproduce here the very
                ;; ambiguity this is added to remove.
                ;;
                ;; And the order is the fact's only chance. A delivery advances
                ;; the cursor over every record it reads and rewrites it against
                ;; the log in hand, so a position recorded against a log that has
                ;; since been replaced is repaired by the very call that would
                ;; have reported it. Read afterwards, that state could never once
                ;; be seen; read first, the answer says which log the records it
                ;; is handing over actually came from.
                (multiple-value-bind (cursor head recorded current reason)
                    (%standing a)
                  (multiple-value-bind (deliveries records-read own-echo elsewhere)
                      (agent-receive-detailed a :timeout-ms timeout :limit page)
                    ;; Read what remains after the delivery rather than
                    ;; threading a second value down through every cursor, bus
                    ;; and agent caller: only this boundary wants the figure,
                    ;; and reading it costs a log scan that materializes no
                    ;; records.
                    (let ((remaining (getf (agent-status a) :pending)))
                      (result id
                              (apply #'make-ht
                                     "messages" (map 'vector #'%message-fields
                                                     deliveries)
                                     "count" (length deliveries)
                                     "remaining_pending" remaining
                                     "content"
                                     (text-content
                                      (%receive-content a deliveries remaining
                                                        cursor head reason
                                                        page records-read
                                                        own-echo
                                                        elsewhere))
                                     (append
                                      (%cursor-fields cursor head recorded
                                                      current reason)
                                      (%page-fields page records-read own-echo
                                                    elsewhere)
                                      (%identity-fields a))))))))))
      ;; A bus name that cannot become a bus root is refused rather than
      ;; downgraded, so a caller is never quietly handed the shared bus's
      ;; backlog in place of the one it named.
      (invalid-bus-name (e)
        (%invalid-argument id (format nil "bus-receive: ~A" e)))
      (no-project-root ()
        (result id (make-ht "isError" t
                            "error_type" "project-root-not-set"
                            "content" (text-content "bus-receive: no project root set. Call fs-set-project-root first.")))))))
