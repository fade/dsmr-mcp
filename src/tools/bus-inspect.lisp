;;;; src/tools/bus-inspect.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; MCP tool: bus-inspect.
;;;;
;;;; One verb answering the questions a leader has to settle about a
;;;; coordination bus before it can act on anything the bus says: which broker
;;;; is serving it and whether that broker would survive, whether a departure
;;;; right now would seal the log, what the log's head and generation are, which
;;;; recorded positions cannot be positions in the log as it stands, and which
;;;; identities are enrolled and reading. Each of those has, at least once, been
;;;; settled instead by reading state files by hand, and each of those readings
;;;; has been wrong in a way nobody could see.
;;;;
;;;; It answers about the bus and nothing else. Backend liveness, which is to
;;;; say the worker pool or the connection to the developer's image, is a
;;;; separate subject with its own verb. Merging the two produces the kind of
;;;; everything-report a reader skims, and the whole value here is in the parts
;;;; that are easy to skim past.
;;;;
;;;; This is a new verb rather than more fields on the older bus status one.
;;;; That verb reports a moment in time and is routinely read as an inventory,
;;;; and adding an inventory to a name that already means something else
;;;; entrenches the misreading instead of fixing it.
;;;;
;;;; Every classification arrives carrying the check that produced it, the
;;;; nearest wrong conclusion a reader might draw from it, how the value was
;;;; obtained and what would flip it. The wording travels with each fact from
;;;; the aggregator that took the measurement, so the sentence a reader sees is
;;;; the sentence written beside the code that can make it false.
;;;;
;;;; CLOS pattern: see pool-status.lisp. Class-allocated slots carry their value
;;;; in an :initform, because the registration hook reads the class prototype
;;;; and the prototype never applies per-class default initargs; a value
;;;; supplied that way is invisible to it and the verb silently fails to
;;;; register. The explicit finalization after the class definition is what
;;;; makes the registration happen at load time.

(defpackage #:dsmr-mcp/src/tools/bus-inspect
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/tools/base
                #:mcp-tool #:mcp-tool-class #:tool-handle #:tool-session)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:make-ht #:result #:text-content)
  (:import-from #:dsmr-mcp/src/tools/status-fields
                #:reported-field)
  (:import-from #:dsmr-mcp/src/tools/bus-helpers
                #:session-agent #:bus-label #:identity-summary #:no-project-root)
  (:import-from #:dsmr-mcp/src/bus/selector
                #:invalid-bus-name)
  (:import-from #:dsmr-mcp/src/bus/agent
                #:agent-bus #:agent-paths #:agent-id)
  (:import-from #:dsmr-mcp/src/bus/status
                #:broker-identity #:rotation-armed
                #:cursor-inventory #:identity-visibility)
  (:import-from #:dsmr-mcp/src/bus/broker
                #:bus-paths-root #:bus-paths-wal)
  (:import-from #:dsmr-mcp/src/bus/wal
                #:scan #:generation)
  (:import-from #:dsmr-mcp/src/bus/heartbeat
                #:default-watch-dir)
  ;; closer-mop: the class is finalized explicitly after the defclass below.
  ;; MUST be declared here or the cold build fails ("Package CLOSER-MOP does not exist").
  (:import-from #:closer-mop)
  ;; com.inuoe.jzon: the built payload is stringified into the text content.
  ;; MUST be declared here or the cold build fails ("Package COM.INUOE.JZON does not exist").
  (:import-from #:com.inuoe.jzon)
  (:export #:bus-inspect-tool))

(in-package #:dsmr-mcp/src/tools/bus-inspect)

;;; ---------------------------------------------------------------------------
;;; Rendering a measured fact for the wire
;;; ---------------------------------------------------------------------------

(defun %or-null (value)
  "VALUE, or the marker the JSON encoder writes as null, when it is NIL.

A bare NIL goes out as the JSON literal false, which invites a reader to
conclude something from a measurement nobody took. An absent value is null:
nobody looked, which is a different statement from any value at all."
  (or value 'cl:null))

(defun %word (value)
  "A keyword rendered as the lowercase word it stands for, a string unchanged,
and NIL as JSON null.

The absent case is null rather than the string \"nil\" on purpose: the contract
walker reads any string as a classification and would then require a failure
condition of a value that is the absence of a classification."
  (cond ((keywordp value) (string-downcase (symbol-name value)))
        ((stringp value) value)
        ((null value) 'cl:null)
        (t (princ-to-string value))))

(defun %restate (fact &optional (value (getf fact :value)))
  "Render one of the aggregator's raw facts as a field ready for the wire.

The bounds travel with the fact rather than being written again here. The
aggregator is where the measurement is taken and where a change could make the
stated bound false, so that is where the sentence belongs; a second copy at the
wire boundary would drift from it silently and the drift would show up as a
reader trusting a value further than the check behind it, which is the failure
this whole surface exists to remove.

VALUE may be supplied by a caller that has converted a row list into wire
objects, since the aggregator returns rows as plists and a plist encodes as an
array of alternating keys and values that no client would read."
  (reported-field value
                  :establishes (getf fact :establishes)
                  :does-not-establish (getf fact :does-not-establish)
                  :basis (getf fact :basis)
                  :red-condition (getf fact :red-condition)))

;;; ---------------------------------------------------------------------------
;;; Rows
;;; ---------------------------------------------------------------------------

(defun %cursor-row (row)
  "One cursor's position rendered for the wire.

A cursor above the head is flagged in a field of its own as well as appearing
in the reason, because that is the shape a reader is scanning for and a reason
string read at a glance is easy to skip."
  (make-ht "name" (getf row :name)
           "ephemeral" (and (getf row :ephemeral) t)
           "cursor" (%or-null (getf row :cursor))
           "head" (%or-null (getf row :head))
           "above_head" (eq (getf row :stranded-reason) :cursor-above-head)
           "recorded_generation" (%or-null (getf row :recorded-generation))
           "log_generation" (%or-null (getf row :log-generation))
           "stranded_reason" (%word (getf row :stranded-reason))
           "age_seconds" (%or-null (getf row :age-seconds))))

(defun %member-row (row)
  "One enrolled identity rendered for the wire."
  (make-ht "agent_id" (getf row :id)
           "status" (%word (getf row :status))
           "departed_at" (%or-null (getf row :departed-at))
           "cursor_name" (%or-null (getf row :cursor-name))
           "has_cursor" (and (getf row :has-cursor) t)
           "ephemeral" (and (getf row :ephemeral) t)
           "cursor_age_seconds" (%or-null (getf row :cursor-age-seconds))
           "cursor_advanced_recently" (and (getf row :cursor-advanced-recently) t)))

(defun %unenrolled-row (row)
  "One cursor with no roster entry, with the kind of name it carries."
  (make-ht "name" (getf row :name)
           "kind" (getf row :kind)))

(defun %beat-row (row)
  "One enrolled identity's watch heartbeat rendered for the wire."
  (make-ht "agent_id" (getf row :id)
           "status" (%word (getf row :status))
           "age_seconds" (%or-null (getf row :age-seconds))
           "pid" (%or-null (getf row :pid))))

(defun %rows (rows renderer)
  "ROWS rendered through RENDERER as a vector, so the encoder writes an array."
  (map 'vector renderer rows))

;;; ---------------------------------------------------------------------------
;;; The five groups
;;; ---------------------------------------------------------------------------

(defun %broker-payload (paths)
  "Who is serving this bus, since when, under what parent, and against what
source. Every field is the aggregator's, restated for the wire."
  (let ((identity (broker-identity paths)))
    (make-ht
     "running"             (%restate (getf identity :running))
     "pid"                 (%restate (getf identity :pid))
     "parent_pid"          (%restate (getf identity :parent-pid))
     "parent_pid_at_start" (%restate (getf identity :parent-pid-at-start))
     "started_at"          (%restate (getf identity :started-at))
     "uptime_seconds"      (%restate (getf identity :uptime-seconds))
     "source_revision"     (%restate (getf identity :source-revision))
     "recorded_version"    (%restate (getf identity :recorded-version)))))

(defun %rotation-payload (paths)
  "Whether a member leaving right now would seal the log, and the count behind
that answer.

The count is a field rather than a bare number because it is the value a reader
reaches for when the answer surprises them, and it means something narrower
than the agent count it looks like."
  (let* ((armed (rotation-armed paths))
         (holders (getf armed :holders)))
    (make-ht
     "armed" (%restate armed)
     "holders"
     (if holders
         (reported-field holders
                         :establishes "how many open file descriptions the kernel's lock table showed holding this bus's membership lock at this instant"
                         :does-not-establish "it does not establish how many agents are on the bus. One process holding two descriptors is counted twice, an agent that joined without taking the lock is not counted at all, and a descriptor inherited by a child outlives the process that opened it."
                         :basis "active-probe")
         (reported-field (%or-null nil)
                         :establishes "that the kernel's lock table could not be read, or could not be correlated to this bus's membership file, so no count was taken"
                         :does-not-establish "it does not establish that nothing holds the lock. Nothing was counted, and a count of zero would be the strongest claim available on the strength of having failed to look."
                         :basis "passive-inference")))))

(defun %archive-inventory (paths)
  "Every sealed log sitting beside the active one in this bus's root, in name
order, with the millisecond stamp its name carries."
  (let* ((log (bus-paths-wal paths))
         (prefix (concatenate 'string (file-namestring log) ".archive-"))
         (found '()))
    (dolist (file (ignore-errors (uiop:directory-files (bus-paths-root paths))))
      (let ((name (file-namestring file)))
        (when (and (> (length name) (length prefix))
                   (string= prefix name :end2 (length prefix)))
          (push (make-ht "name" name
                         "sealed_at_ms"
                         (%or-null (parse-integer name :start (length prefix)
                                                       :junk-allowed t)))
                found))))
    (coerce (sort found #'string< :key (lambda (h) (gethash "name" h)))
            'vector)))

(defun %log-payload (paths)
  "What log this bus is on: its head, the identity that says which log that is,
and the sealed ones behind it."
  (let* ((log (bus-paths-wal paths))
         (head (ignore-errors (scan log)))
         (current (ignore-errors (generation log)))
         (archives (%archive-inventory paths)))
    (make-ht
     "head"
     (reported-field (%or-null head)
                     :establishes "the sequence number of the last record in this bus's active log, read by scanning the log on this call"
                     :does-not-establish "it does not establish that any participant has read that far, and it does not establish that this has always been the log. A rotation empties the log and the next records number from one again, so a head below a position somebody holds is the ordinary shape of a sealed log rather than a fault in that position."
                     :basis "active-probe")
     "generation"
     (reported-field (%or-null current)
                     :establishes "which generation of the log this bus is on, read from the counter file beside the log, which moves when the log is replaced and at no other time"
                     :does-not-establish "it does not establish when any replacement happened, and a zero does not establish that the log has never been rotated: a bus older than the counter reads zero because nothing was recorded, not because nothing happened."
                     :basis "durable-record")
     "archive_count"
     (reported-field (length archives)
                     :establishes "how many sealed logs sit beside the active one in this bus's root directory"
                     :does-not-establish "it does not establish how many times this bus has rotated. Sealing an empty log writes no archive, and an archive moved away by hand leaves nothing here to count."
                     :basis "durable-record")
     "archives"
     (reported-field archives
                     :establishes "the name of each sealed log in this bus's root directory, with the millisecond stamp its name carries"
                     :does-not-establish "a stamp names when the seal was written and says nothing about what the sealed log holds. Nothing here reads a record out of an archive."
                     :basis "durable-record"))))

(defun %cursor-payload (paths)
  "Every position recorded on this bus, how many there are, and which of them
cannot be positions in the log as it stands."
  (let ((inventory (cursor-inventory paths)))
    (make-ht
     "count"           (%restate (getf inventory :count))
     "ephemeral_count" (%restate (getf inventory :ephemeral-count))
     "stranded_count"  (%restate (getf inventory :stranded-count))
     "cursors"
     (let ((fact (getf inventory :cursors)))
       (%restate fact (%rows (getf fact :value) #'%cursor-row))))))

(defun %identity-payload (paths bus)
  "Who is enrolled on this bus, who holds a position without being enrolled, and
what the watch beats say.

The watch directory is the one the heartbeat leaf derives for this bus by name,
rather than the default taken from the bus root, so a named bus is asked about
its own watchers instead of about whichever ones happen to sit under the root."
  (let ((visibility (identity-visibility paths :watch-dir (default-watch-dir bus))))
    (make-ht
     "members"
     (let ((fact (getf visibility :members)))
       (%restate fact (%rows (getf fact :value) #'%member-row)))
     "unenrolled"
     (let ((fact (getf visibility :unenrolled)))
       (%restate fact (%rows (getf fact :value) #'%unenrolled-row)))
     "watch_beat"
     (let ((fact (getf visibility :watch-beat)))
       (%restate fact (%rows (getf fact :value) #'%beat-row))))))

;;; ---------------------------------------------------------------------------
;;; The whole answer
;;; ---------------------------------------------------------------------------

(defparameter +scope+
  "Everything below is about one bus: the broker serving it, whether a departure would seal its log, the log itself, the positions recorded against it, and the identities holding them. Backend liveness is a separate subject with its own verb and is not answered here."
  "What this verb covers, stated in the answer as well as in the tool list.

A caller relaying an answer onward carries the reply and not the tool
description, so the reply has to say what it is about.")

(defun %payload (a paths)
  "The whole bus answer for the participant A on the bus at PATHS."
  (let* ((bus (agent-bus a))
         (broker (%broker-payload paths))
         (rotation (%rotation-payload paths))
         (cursors (%cursor-payload paths)))
    (make-ht
     "bus"        (bus-label bus)
     "agent_id"   (agent-id a)
     "scope"      +scope+
     "summary"    (%summary-line a (bus-label bus) broker rotation cursors)
     "broker"     broker
     "rotation"   rotation
     "log"        (%log-payload paths)
     "cursors"    cursors
     "identities" (%identity-payload paths bus))))

(defun %summary-line (a label broker rotation cursors)
  "One line a person reads before opening the structure underneath it.

Carried inside the answer rather than as a second content item, so a client
that reads only the first one still gets the whole reply."
  (format nil "You are ~A. Bus ~A: broker ~A, rotation ~A, ~A cursor(s) of which ~A stranded. Every field states what it establishes and what it does not."
          (identity-summary a)
          label
          (gethash "value" (gethash "running" broker))
          (gethash "value" (gethash "armed" rotation))
          (gethash "value" (gethash "count" cursors))
          (gethash "value" (gethash "stranded_count" cursors))))

;;; ---------------------------------------------------------------------------
;;; The verb
;;; ---------------------------------------------------------------------------

(defclass bus-inspect-tool (mcp-tool)
  ;; CRITICAL: class-allocated slots carry their value in an :initform. The
  ;; registration hook reads the class prototype, which never applies the
  ;; per-class default initargs, so a value supplied that way is invisible to
  ;; it and the verb silently fails to register.
  ((dsmr-mcp/src/tools/base::name
    :allocation :class :initform "bus-inspect")
   (dsmr-mcp/src/tools/base::description
    :allocation :class
    :initform "Inspect one coordination bus in depth: which broker is serving \
it and whether that broker would survive, whether a member leaving right now \
would seal the log, the log's head and generation and the sealed logs behind \
it, every recorded position with the ones that cannot be positions in the \
current log flagged, and which identities are enrolled, which are per-process, \
and which hold a position on a bus that never enrolled them. \
Read-only: nothing is published, no cursor is moved and no lock is taken. \
Every classification comes back with the check that produced it, the nearest \
wrong conclusion a reader might draw, how the value was obtained and what \
would flip it, so no value has to be read on trust. \
Note in particular that a broker reported running has been found holding the \
election lock and says nothing about which source it is serving, and that the \
recorded source revision is the source the broker loaded at start and is not \
compared against the working tree here. \
This verb answers about the bus. Backend liveness, meaning the worker pool or \
this session's connection to the developer's image, is a separate subject with \
its own verb; ask that one instead of expecting this to say how everything is. \
For a quick peek at whether a broker is up and how many messages are waiting \
for you, bus-status is the smaller and faster call.")
   (dsmr-mcp/src/tools/base::input-schema
    :allocation :class
    :initform '(:object
                :properties
                ((agent_id
                  :type :string
                  :description "Optional stable agent name to inspect under \
(within this project's namespace). Omit to use the session's anonymous default \
agent.")
                 (ephemeral
                  :type :boolean
                  :description "Set true to force a fresh one-shot ephemeral \
identity for this subagent, opting out of the project's stable DSMR_BUS_AGENT \
identity so it never resumes the main agent's cursor.")
                 (bus
                  :type :string
                  :description "Optional named bus to inspect. Omit to use this \
session's bus, which is DSMR_BUS_SELECTOR from the repository's .envrc when \
that is set and the shared host-wide bus otherwise. A name that cannot become \
a bus is refused; the shared bus is never inspected in place of a bus that was \
named."))
                :required ())))
  (:metaclass mcp-tool-class)
  (:documentation "MCP tool: report the full state of one coordination bus.
Read-only throughout: the broker is identified from the election lock without
taking it, the rotation answer is read from the kernel's lock table without
converting any lock, and no cursor is read past or advanced."))

;; CRITICAL: ensure-finalized must appear after defclass so the metaclass
;; finalize-inheritance :after hook fires at load time and registers
;; "bus-inspect" in *tool-classes*.
(c2mop:ensure-finalized (find-class 'bus-inspect-tool))

(defmethod tool-handle ((tool bus-inspect-tool) id args)
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
                            (text-content "bus-inspect: bus must be a non-empty \
string naming a bus. Omit it to inspect this session's own bus.")))))
    (handler-case
        (let* ((a (session-agent (tool-session tool) agent-id-arg
                                 :ephemeral ephemeral :bus bus-arg))
               (payload (%payload a (agent-paths a))))
          (result id (make-ht "isError" nil
                              "bus" (gethash "bus" payload)
                              "content"
                              (text-content
                               (com.inuoe.jzon:stringify payload)))))
      ;; A bus name that cannot become a bus root is refused rather than
      ;; downgraded. A report about the shared bus, returned to an agent that
      ;; asked about a named one, is a report of the wrong bus.
      (invalid-bus-name (e)
        (result id (make-ht "isError" t
                            "error_type" "invalid-argument"
                            "content" (text-content
                                       (format nil "bus-inspect: ~A" e)))))
      (no-project-root ()
        (result id (make-ht "isError" t
                            "error_type" "project-root-not-set"
                            "content" (text-content "bus-inspect: no project root set. Call fs-set-project-root first.")))))))
