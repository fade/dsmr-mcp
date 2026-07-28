;;;; src/tools/bus-roster.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; MCP tool: read and change one bus's roster, so a fleet is assembled and
;;;; maintained from a leader's terminal instead of by hand-editing files under
;;;; the state root.
;;;;
;;;; The roster is operator-managed and advisory, and the bus enforces nothing
;;;; from it. Nothing on the serving path consults it: an agent that is absent
;;;; from the roster, or that was refused a place on it, still connects, still
;;;; publishes and still receives. What separates one fleet from another is the
;;;; separate state root and the filesystem permissions on it, never a membership
;;;; check, because the transport has no security surface that could back one.
;;;;
;;;; Closing enrollment is therefore a gate and not an access control list. It
;;;; stops the leader from listing new participants and stops nothing else. That
;;;; gate, plus a leader recorded per bus, is the whole of the answer to two
;;;; fleets sharing one machine: each names its own bus, each declares its own
;;;; leader, and neither can quietly become the other's. There is no
;;;; cryptographic or capability guard here and none is planned, because a
;;;; transport that cannot back one would only be wearing it.
;;;;
;;;; Dispatcher-side and mode-independent: it talks to the bus, not to a Lisp
;;;; image.

(defpackage #:dsmr-mcp/src/tools/bus-roster
  (:use #:cl)
  (:local-nicknames (#:agent #:dsmr-mcp/src/bus/agent)
                    (#:broker #:dsmr-mcp/src/bus/broker)
                    (#:bus #:dsmr-mcp/src/bus/bus)
                    (#:roster #:dsmr-mcp/src/bus/roster))
  (:import-from #:dsmr-mcp/src/tools/base
                #:mcp-tool #:mcp-tool-class #:tool-handle #:tool-session)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:make-ht #:result #:text-content)
  (:import-from #:dsmr-mcp/src/tools/bus-helpers
                #:session-agent #:bus-label #:no-project-root)
  (:import-from #:dsmr-mcp/src/bus/selector
                #:invalid-bus-name))

(in-package #:dsmr-mcp/src/tools/bus-roster)

(defparameter *accepted-actions*
  '("list" "enroll" "disenroll" "close-enrollment" "open-enrollment"
    "declare-leader")
  "Every action this verb accepts, in the order a refusal lists them. Matched
case-insensitively and reported back in this spelling, so a caller that guessed
the wrong case is told the exact set rather than left to guess again.")

(defparameter *actions-needing-an-agent*
  '("enroll" "disenroll" "declare-leader")
  "The actions that act on one named agent and therefore cannot run without one.
Listing, closing and reopening are bus-wide and take no agent.")

(defclass bus-roster-tool (mcp-tool)
  ((dsmr-mcp/src/tools/base::name
    :allocation :class :initform "bus-roster")
   (dsmr-mcp/src/tools/base::description
    :allocation :class
    :initform "Read and change the roster of a coordination bus: list who is on \
it, enroll and disenroll participants while the fleet is running, close or \
reopen enrollment, and record which agent leads the bus. \
The roster is operator-managed and ADVISORY: the bus enforces nothing from it. \
An agent that is not on the roster, or that was refused a place on it, can still \
connect, publish and receive exactly as any other participant. Closing \
enrollment stops the leader from listing new participants; it stops nobody from \
using the bus. This is a gate, not an access control list. \
Isolation between fleets comes from each bus having its own state root and the \
filesystem permissions on that root, not from a membership check, because the \
transport has no security surface that could back one. A declared leader plus a \
closeable gate is the answer to two fleets sharing a machine: each names its own \
bus and records its own leader. There is no cryptographic or capability guard \
here, and adding one would only dress a convention up as a control.")
   (dsmr-mcp/src/tools/base::input-schema
    :allocation :class
    :initform '(:object
                :properties
                ((action
                  :type :string
                  :description "What to do: list (every entry, plus whether \
enrollment is open and who leads), enroll (add an agent), disenroll (mark an \
agent departed and stamp when), close-enrollment (shut the gate), \
open-enrollment (reopen it), or declare-leader (record who leads this bus).")
                 (agent
                  :type :string
                  :description "The agent to act on: either a full \
NAMESPACE/NAME bus id, or the bare name within this session's own project \
namespace, which is qualified for you. Required by enroll, disenroll and \
declare-leader; ignored by the others.")
                 (bus
                  :type :string
                  :description "Optional named bus to act on. Omit to use the \
bus this session already speaks on."))
                :required ("action"))))
  (:metaclass mcp-tool-class)
  (:documentation "MCP tool: read and change one coordination bus's roster.

   The roster records who a leader has listed on a bus, who has left it and
   when, who leads it, and whether enrollment is open. Every one of those is
   advisory: nothing on the serving path reads any of it, so a refused or
   unlisted agent connects, publishes and receives like any other. Isolation is
   the separate state root and its filesystem permissions; a membership check
   would be a heuristic dressed as a control, since the transport cannot back
   one. Closing enrollment is a gate the leader may shut for any reason, not an
   access control list, and a declared leader plus that gate is what keeps two
   fleets on one machine from overriding each other."))

(c2mop:ensure-finalized (find-class 'bus-roster-tool))

;;; ---------------------------------------------------------------- rendering

(defun %stamp (universal-time)
  "UNIVERSAL-TIME rendered for a person to read, or \"unknown\" when there is
   nothing to render. Only the human-readable text uses this; the structured
   fields carry the raw universal time, which is what the busmaster's aging
   sweep compares against and what a caller should compare against too."
  (if (integerp universal-time)
      (multiple-value-bind (sec min hour day month year)
          (decode-universal-time universal-time)
        (format nil "~4,'0D-~2,'0D-~2,'0D ~2,'0D:~2,'0D:~2,'0D"
                year month day hour min sec))
      "unknown"))

(defun %keyword-text (value)
  "VALUE rendered as a lower-case wire string, or JSON null when absent. Entry
   statuses and roles are keywords on disk and read better downcased."
  (if (symbolp value)
      (if value (string-downcase (symbol-name value)) 'null)
      value))

(defun %entry-fields (e)
  "One roster entry as the object a caller reads: who it names, whether it is
   enrolled or departed, the role recorded for it, when it was enrolled and,
   for a departed entry, when it left.

   The role and the enrollment time are read off the entry plist directly. The
   roster leaf exposes accessors for the id, the status and the departure time
   only, because those are the three the busmaster's sweeps need; the other two
   exist on the entry and are wanted here and nowhere else."
  (make-ht "agent_id" (roster:entry-id e)
           "status" (%keyword-text (roster:entry-status e))
           "role" (%keyword-text (getf e :role))
           "enrolled_at" (or (getf e :enrolled-at) 'null)
           "departed_at" (or (roster:entry-departed-at e) 'null)))

(defun %entry-line (e)
  "One roster entry as a line of the rendered listing."
  (if (eq (roster:entry-status e) :departed)
      (format nil "  ~A: departed ~A (role ~A)"
              (roster:entry-id e)
              (%stamp (roster:entry-departed-at e))
              (%keyword-text (getf e :role)))
      (format nil "  ~A: enrolled ~A (role ~A)"
              (roster:entry-id e)
              (%stamp (getf e :enrolled-at))
              (%keyword-text (getf e :role)))))

(defparameter *advisory-note*
  "The roster is advisory: nothing on the bus enforces it. An agent that is not \
listed, or was refused a place, still connects, publishes and receives."
  "The sentence every reply ends with. A surface that only ever printed the
roster would teach a reader it was a membership control, which it is not.")

(defun %listing-text (label entries open leader)
  "The rendered listing: which bus, who is on it, whether the gate is open, and
   who leads."
  (format nil "Roster for bus ~A: ~D entr~:@P.~%~
               Enrollment is ~A. Leader: ~A.~
               ~{~%~A~}~%~%~A"
          label (length entries)
          (if open "open" "closed")
          (or leader "none declared")
          (mapcar #'%entry-line entries)
          *advisory-note*))

;;; ------------------------------------------------------------------ guards

(defun %invalid-argument (id message)
  "An invalid-argument refusal in the shape every bus verb returns."
  (result id (make-ht "isError" t
                      "error_type" "invalid-argument"
                      "content" (text-content message))))

(defun %canonical-action (value)
  "VALUE matched case-insensitively against the accepted actions, returning the
   canonical spelling, or NIL when it is not one of them. Validated before any
   roster call so an unknown action changes nothing on disk."
  (and (stringp value)
       (find value *accepted-actions* :test #'string-equal)))

(defun %qualify (agent-arg namespace)
  "AGENT-ARG as a full bus id. A value that already carries a separator is taken
   as an id and used as given; a bare name is qualified with NAMESPACE, the
   session's own project root, exactly as a participant's id is built.

   So an operator names a sister by the name it answers to and never types a
   project root, and a bare name cannot reach into another project's namespace
   by accident: two projects may both run an agent called valis, and a bare name
   always means this session's one."
  (if (find #\/ agent-arg)
      agent-arg
      (bus:agent-id namespace :name agent-arg)))

;;; ---------------------------------------------------------------- dispatch

(defun %list-roster (id label roster-dir state-path)
  (let ((entries (roster:members roster-dir))
        (open (roster:enrollment-open-p state-path))
        (leader (roster:leader state-path)))
    (result id (make-ht "action" "list"
                        "bus" label
                        "enrollment_open" (and open t)
                        "leader" (or leader 'null)
                        "count" (length entries)
                        "members" (map 'vector #'%entry-fields entries)
                        "content" (text-content
                                   (%listing-text label entries open leader))))))

(defun %enroll (id label target roster-dir state-path)
  (multiple-value-bind (entry refusal) (roster:enroll target roster-dir state-path)
    (if entry
        (result id (make-ht "action" "enroll"
                            "bus" label
                            "agent_id" target
                            "enrolled" t
                            "member" (%entry-fields entry)
                            "content" (text-content
                                       (format nil "Enrolled ~A on bus ~A.~%~%~A"
                                               target label *advisory-note*))))
        (result id (make-ht "action" "enroll"
                            "bus" label
                            "agent_id" target
                            "enrolled" nil
                            "reason" (%keyword-text refusal)
                            "content"
                            (text-content
                             (format nil "Refused: enrollment is closed on bus ~
~A, so ~A was not listed and nothing was written.~%~%This refusal is a roster ~
answer and not a transport one. ~A can still connect to the bus, publish on it ~
and receive from it; the only thing it lacks is a line on the roster. Reopen ~
the gate with the open-enrollment action to list it."
                                     label target target)))))))

(defun %disenroll (id label target roster-dir)
  (let ((entry (roster:disenroll target roster-dir)))
    (result id (make-ht "action" "disenroll"
                        "bus" label
                        "agent_id" target
                        "departed_at" (or (roster:entry-departed-at entry) 'null)
                        "member" (%entry-fields entry)
                        "content"
                        (text-content
                         (format nil "Marked ~A departed from bus ~A at ~A.~%~%~
The bus carries on unaffected: disenrolling records that the agent left, and ~
does not disconnect it or stop it publishing. An agent that leaves under its ~
own steam should call bus-leave, which drains what it has first.~%~%~A"
                                 target label
                                 (%stamp (roster:entry-departed-at entry))
                                 *advisory-note*))))))

(defun %set-gate (id action label state-path)
  (if (string= action "close-enrollment")
      (roster:close-enrollment state-path)
      (roster:open-enrollment state-path))
  (let ((open (roster:enrollment-open-p state-path)))
    (result id (make-ht "action" action
                        "bus" label
                        "enrollment_open" (and open t)
                        "content"
                        (text-content
                         (format nil "Enrollment on bus ~A is now ~A.~%~%~
~A~%~%~A"
                                 label (if open "open" "closed")
                                 (if open
                                     "New participants can be listed again."
                                     "New participants cannot be listed. \
Everyone already on the roster carries on entirely unaffected, and nobody is \
disconnected: shutting the gate stops the roster growing and stops nothing \
else.")
                                 *advisory-note*))))))

(defun %declare-leader (id label target state-path)
  (roster:declare-leader target state-path)
  (let ((leader (roster:leader state-path)))
    (result id (make-ht "action" "declare-leader"
                        "bus" label
                        "leader" (or leader 'null)
                        "content"
                        (text-content
                         (format nil "Bus ~A now records ~A as its leader.~%~%~
Recording, not granting: leadership belongs to whoever assembled the bus, and ~
this writes that fact down so any participant can read it back. No entry's ~
status changed and the leader gained no ability an ordinary member lacks. Two ~
fleets on one machine stay apart because each names its own bus and records its ~
own leader, not because anything here is enforced.~%~%~A"
                                 label target *advisory-note*))))))

(defmethod tool-handle ((tool bus-roster-tool) id args)
  (let ((action (%canonical-action (gethash "action" args)))
        (agent-arg (gethash "agent" args))
        (bus-arg (gethash "bus" args)))
    ;; Every guard runs before anything reaches the roster, so a refused call
    ;; leaves the bus's durable metadata exactly as it found it.
    (unless action
      (return-from tool-handle
        (%invalid-argument
         id (format nil "bus-roster: action must be one of ~{~A~^, ~}."
                    *accepted-actions*))))
    (when (and (member action *actions-needing-an-agent* :test #'string=)
               (not (and (stringp agent-arg) (plusp (length agent-arg)))))
      (return-from tool-handle
        (%invalid-argument
         id (format nil "bus-roster: the ~A action needs an agent argument, ~
either a full NAMESPACE/NAME bus id or a bare name in this project's namespace."
                    action))))
    ;; An empty bus is refused rather than read as "no bus named": resolved, it
    ;; would fall through to whatever bus the session already speaks on, and a
    ;; caller that asked to change one fleet's roster would change another's
    ;; while the reply reported success on the bus it actually used.
    (unless (or (null bus-arg) (and (stringp bus-arg) (plusp (length bus-arg))))
      (return-from tool-handle
        (%invalid-argument
         id "bus-roster: bus must be a non-empty string naming a bus. Omit it \
to act on this session's own bus.")))
    (handler-case
        (let* ((a (session-agent (tool-session tool) nil :bus bus-arg))
               (paths (agent:agent-paths a))
               (roster-dir (broker:bus-paths-roster-dir paths))
               (state-path (broker:bus-paths-roster-state paths))
               (label (bus-label (agent:agent-bus a)))
               (target (and (stringp agent-arg)
                            (plusp (length agent-arg))
                            (%qualify agent-arg (agent:agent-namespace a)))))
          (cond
            ((string= action "list") (%list-roster id label roster-dir state-path))
            ((string= action "enroll")
             (%enroll id label target roster-dir state-path))
            ((string= action "disenroll") (%disenroll id label target roster-dir))
            ((string= action "declare-leader")
             (%declare-leader id label target state-path))
            (t (%set-gate id action label state-path))))
      (invalid-bus-name (e)
        (%invalid-argument id (format nil "bus-roster: ~A" e)))
      (no-project-root ()
        (result id (make-ht "isError" t
                            "error_type" "project-root-not-set"
                            "content" (text-content "bus-roster: no project root set. Call fs-set-project-root first.")))))))
