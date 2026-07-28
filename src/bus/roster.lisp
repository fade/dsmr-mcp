;;;; src/bus/roster.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; The durable roster of one bus: who is enrolled on it, who has left and when,
;;;; who leads it, and whether enrollment is open.
;;;;
;;;; The roster is ADVISORY. Nothing about joining, publishing or receiving is
;;;; gated on it. An ipc:// socket is guarded by directory permissions and
;;;; nothing else, so the transport has no security surface to back a membership
;;;; check, and a bus-enforced roster would buy nothing while turning a typo in a
;;;; sister's name into a silent non-join. What isolates one fleet from another
;;;; is the separate state root and its filesystem permissions, never this file.
;;;;
;;;; Leadership is recorded here, not enforced. A bus has a declared leader and a
;;;; closeable enrollment gate, and that pair is the whole answer to "two fleets
;;;; sharing one bus cannot override each other's leader". There is deliberately
;;;; no cryptographic or capability-based leader guard, and none is wanted:
;;;; nothing in the transport could back one. Joining a bus never confers
;;;; leadership of it, so a joined agent has every ability a member has except
;;;; that label.
;;;;
;;;; Storage is one small readable file per agent under a roster directory, named
;;;; by the same percent-encoding that cursors and heartbeats key their filenames
;;;; on, plus one bus-level file holding the enrollment gate and the leader.
;;;; Reusing the encoder is not a stylistic choice: the broker's cursor-shape
;;;; match already depends on that exact alphabet, and a second encoding would
;;;; desync without ever saying so.
;;;;
;;;; Two conventions are deliberate and differ from the cursor leaf next door:
;;;;
;;;;   - Every write goes to a temporary file in the same directory and is then
;;;;     renamed over the target, so a reader concurrent with a write observes
;;;;     the old entry or the new one and never a half-written one.
;;;;   - Every read distinguishes "absent" from "present but unreadable". The
;;;;     cursor leaf collapses an unreadable file to position zero, which is the
;;;;     right default for a cursor and the wrong one here: it would report an
;;;;     agent that has departed as one that never left, and the departure stamp
;;;;     is the evidence the held-cursor aging sweep keys on.
;;;;
;;;; Nothing here knows about the broker, about bus paths, or about ZeroMQ: every
;;;; function takes plain pathnames, so the broker can own the layout and this
;;;; leaf stays free of a dependency cycle.

(defpackage #:dsmr-mcp/src/bus/roster
  (:use #:cl)
  (:local-nicknames (#:envelope #:dsmr-mcp/src/bus/envelope))
  (:export #:entry
           #:enroll
           #:disenroll
           #:members
           #:departed-members
           #:entry-status
           #:entry-departed-at
           #:entry-id
           #:enrollment-open-p
           #:close-enrollment
           #:open-enrollment
           #:leader
           #:declare-leader
           #:roster-entry-path))

(in-package #:dsmr-mcp/src/bus/roster)

;;; --------------------------------------------------------------- file layout

(defun %entry-file-type ()
  "The filename type every roster entry file carries.

   A function rather than a constant so that reloading this file into a live
   image is never a redefinition error. Singular, so nothing confuses an entry
   with the shared membership lock one directory up: that lock is held by every
   live process and vanishes with them, while an entry outlives the process it
   names."
  "member")

(defun %temp-file-type ()
  "The filename type of an in-flight write. Distinct from an entry's type so a
   directory listing can never mistake a half-written file for a roster entry,
   even in the window before the rename."
  "tmp")

(defun %canonical-key (id)
  "ID reduced to the spelling that identifies the agent, so two ways of writing
   one identity address one entry.

   A bus id is a namespace joined to a name by a single separator. An operator
   listing a sister that lives in another repository has to type the full id by
   hand, and ids built before the join was normalized carry two separators,
   because the namespace is a project root in its directory form and already ends
   in one. All of them mean the same agent. Without this they land on separate
   files, and the one the operator made can never be departed afterwards, because
   leaving only ever departs the identity a session resolves for itself: the
   roster then shows a single agent as enrolled and departed at once.

   The name is the segment after the last separator, and the namespace is
   everything before it with any trailing separators dropped; the two are rejoined
   by exactly one. Idempotent, so an id already spelled this way comes back
   unchanged. An id with no separator at all is not a qualified id and is returned
   as it came."
  (if (and (stringp id) (find #\/ id))
      (let* ((cut (position #\/ id :from-end t))
             (name (subseq id (1+ cut)))
             (namespace (string-right-trim "/" (subseq id 0 cut))))
        (concatenate 'string namespace "/" name))
      id))

(defun roster-entry-path (id roster-dir)
  "Where the roster entry for agent ID lives under ROSTER-DIR.

   Keyed on the SAME encoded id that this agent's cursor and heartbeat files use,
   so the three names for one identity are derived once and cannot drift.

   The id is reduced to its identity key first, which is what makes a hand-typed
   id and a constructed one address one file instead of two."
  (merge-pathnames (concatenate 'string
                                (envelope:encode-id (%canonical-key id))
                                "." (%entry-file-type))
                   (uiop:ensure-directory-pathname roster-dir)))

(defun %temp-path (target)
  "A scratch pathname beside TARGET for a write that has not committed yet.

   The random state is seeded per call rather than taken from the image's
   default. That default repeats across fresh images, so two processes writing
   one entry at the same moment could otherwise choose the same scratch name and
   the loser's rename would land the winner's bytes. Seeding costs a little, and
   roster writes are rare enough that it does not matter."
  (make-pathname :name (format nil "~A-~D"
                               (or (pathname-name target) "roster")
                               (random 100000000 (make-random-state t)))
                 :type (%temp-file-type)
                 :defaults target))

;;; ------------------------------------------------------------- durable I/O

(defun %readable-plist-p (form)
  "True iff FORM is a proper property list: even length, symbols in the key
   positions. Anything else read out of an entry file is damage, not data.

   LIST-LENGTH is wrapped because a damaged file can hold a dotted or circular
   list, and the length check is the first thing that would meet it."
  (and (listp form)
       (let ((len (ignore-errors (list-length form))))
         (and len (evenp len)))
       (loop for rest on form by #'cddr
             always (symbolp (first rest)))))

(defun %read-plist (path)
  "Read the plist stored at PATH.

   Returns (VALUES PLIST PRESENT-P). A missing file answers NIL and NIL. A file
   that is there but holds nothing readable, or holds something that is not a
   plist, answers NIL and T, so damage is never reported as absence: the two need
   different handling, and conflating them would report a departed agent as one
   that never left.

   *READ-EVAL* is bound off for the read. The roster sits under a state root that
   other processes can write, so a crafted entry file must not be able to run
   code just by being looked at. Standard io syntax also pins the read base and
   the readtable, keeping the parse independent of whatever the calling image has
   configured."
  (if (probe-file path)
      (let ((form (handler-case
                      (with-standard-io-syntax
                        (let ((*read-eval* nil))
                          (with-open-file (in path :if-does-not-exist nil)
                            (and in (read in nil nil)))))
                    (error () :unreadable))))
        (if (and (not (eq form :unreadable))
                 (%readable-plist-p form))
            (values form t)
            (values nil t)))
      (values nil nil)))

(defun %plain-text (value)
  "VALUE with every string inside it held as a full CHARACTER string.

   An id reaches the roster as the namestring of a pathname, and this
   implementation hands back a base string whenever every character is ASCII.
   Printed readably, a base string is an array literal, so the entry files and
   the bus state file fill up with #A(...) forms where plain strings belong. They
   read back, so nothing breaks here, and that is exactly why it is worth
   stopping at the write: the same literal on a wire has repeatedly killed the
   image at the far end, and durable state a person can read at a glance is worth
   more than the microsecond the coercion costs."
  (typecase value
    (string (map '(simple-array character (*)) #'identity value))
    (cons (cons (%plain-text (car value)) (%plain-text (cdr value))))
    (t value)))

(defun %write-plist (path plist)
  "Write PLIST to PATH atomically and return what landed.

   The replacement must be atomic. A roster file is read by processes other than
   the one writing it, so writing in place would truncate first and expose a
   transiently empty file, which reads back as damage. Writing a scratch file in
   the SAME directory and renaming it over the target makes the swap one
   filesystem operation: a reader sees either value, never neither. The scratch
   file is removed if anything goes wrong, so a failed write leaves the previous
   entry intact and no litter behind.

   Strings are flattened to a single element type on the way out, and the
   flattened plist is what comes back, so a caller reading the return value and a
   caller reading the file are looking at the same thing."
  (ensure-directories-exist path)
  (let ((plain (%plain-text plist))
        (temp (%temp-path path)))
    (unwind-protect
         (progn
           (with-open-file (out temp :direction :output
                                     :if-exists :supersede
                                     :if-does-not-exist :create)
             (with-standard-io-syntax
               (prin1 plain out))
             (finish-output out))
           (rename-file temp path)
           (setf temp nil))
      (when temp (ignore-errors (delete-file temp))))
    plain))

;;; ------------------------------------------------------------- entry access

(defun entry-id (entry)
  "The full <namespace>/<name> bus id ENTRY names."
  (getf entry :id))

(defun entry-status (entry)
  "Whether ENTRY is :ENROLLED or :DEPARTED."
  (getf entry :status))

(defun entry-departed-at (entry)
  "The universal time ENTRY's agent left, or NIL while it is still enrolled.

   Distinct from the entry file's own write time on purpose. A departed agent's
   cursor keeps advancing with fleet traffic, so its modification time stays
   within seconds of now forever; anything aging a departure out has to read this
   stamp instead, or holding a cursor quietly becomes keeping it immortal."
  (getf entry :departed-at))

(defun entry (id roster-dir)
  "The roster entry for ID under ROSTER-DIR.

   Returns (VALUES ENTRY PRESENT-P): NIL and NIL when no entry exists, NIL and T
   when one exists but cannot be read."
  (%read-plist (roster-entry-path id roster-dir)))

(defun members (roster-dir)
  "Every readable roster entry under ROSTER-DIR, enrolled and departed alike.

   Damaged entries are skipped rather than reported: an entry that will not parse
   has no id to name, so there is nothing to hand back. Use ENTRY on a known id
   to tell a damaged entry from an absent one."
  (let ((dir (uiop:ensure-directory-pathname roster-dir))
        (found '()))
    (when (uiop:directory-exists-p dir)
      (dolist (file (uiop:directory-files dir))
        (when (equal (pathname-type file) (%entry-file-type))
          (let ((plist (%read-plist file)))
            (when plist (push plist found))))))
    (nreverse found)))

(defun departed-members (roster-dir)
  "Only the entries under ROSTER-DIR whose agent has left."
  (remove-if-not (lambda (e) (eq (entry-status e) :departed))
                 (members roster-dir)))

;;; ------------------------------------------------------- bus-level state

(defun %bus-state (state-path)
  "The bus-level plist at STATE-PATH, or the default state when it is absent or
   damaged. The default is open enrollment with no declared leader: a bus nobody
   has closed is open, and a state file too damaged to read must not be able to
   lock a fleet out of its own bus."
  (or (%read-plist state-path)
      (list :enrollment :open :leader nil :updated-at nil)))

(defun %update-bus-state (state-path key value)
  "Set KEY to VALUE in the bus-level state at STATE-PATH and stamp it, atomically."
  (let ((plist (copy-list (%bus-state state-path))))
    (setf (getf plist key) value)
    (setf (getf plist :updated-at) (get-universal-time))
    (%write-plist state-path plist)))

(defun enrollment-open-p (state-path)
  "True while new agents may be enrolled on the bus whose state lives at
   STATE-PATH.

   Absent reads as open, which is the right default for a bus nobody has closed;
   damaged reads as open too, on the same reasoning as %BUS-STATE. This is a gate
   the leader can shut, not an access control list: it stops the roster from
   growing, and stops nothing else. An agent refused enrollment can still connect,
   publish and receive as before. All it means is that the leader has not listed
   it."
  (not (eq (getf (%bus-state state-path) :enrollment) :closed)))

(defun close-enrollment (state-path)
  "Shut the enrollment gate on the bus whose state lives at STATE-PATH.

   The leader may do this for any reason. Agents already enrolled carry on
   entirely unaffected."
  (%update-bus-state state-path :enrollment :closed))

(defun open-enrollment (state-path)
  "Reopen the enrollment gate on the bus whose state lives at STATE-PATH."
  (%update-bus-state state-path :enrollment :open))

(defun leader (state-path)
  "The declared leader of the bus whose state lives at STATE-PATH, or NIL."
  (getf (%bus-state state-path) :leader))

(defun declare-leader (id state-path)
  "Record ID as the leader of the bus whose state lives at STATE-PATH, and return
   the spelling that was recorded.

   Recording, not granting. Leadership belongs to whoever assembled the bus, and
   this writes that fact down so any participant can read it back. It changes no
   entry's status and confers no ability that a member lacks.

   What lands is the identity spelling, so declaring the same agent again under
   another separator spelling records one leader, and the leader a listing prints
   matches the entry sitting beside it in that listing."
  (let ((recorded (%canonical-key id)))
    (%update-bus-state state-path :leader recorded)
    recorded))

;;; --------------------------------------------------------- enrol and depart

(defun enroll (id roster-dir state-path &key role)
  "Enroll ID on the bus whose roster is ROSTER-DIR and whose state is STATE-PATH.

   Returns (VALUES ENTRY NIL) on success. When the enrollment gate is shut,
   returns (VALUES NIL :ENROLLMENT-CLOSED) and writes nothing. That refusal is
   the whole of the gate: the agent may still connect, publish and receive, and
   only its absence from the roster distinguishes it from any other participant.

   Enrolling an id that has departed clears its departure stamp and returns it to
   enrolled, so an agent that left can come back. ROLE defaults to whatever the
   existing entry carried and to :MEMBER for a new one, so re-enrolling a leader
   does not quietly demote it.

   Every spelling of one id is one agent here, and they land on one entry. What
   is written down is the identity spelling, because the busmaster derives a
   departed agent's cursor filename from this field and that cursor is named by
   the id the agent's own session resolves. A field holding some other spelling
   points the busmaster at a file that does not exist, and a missing cursor path
   is skipped in silence: the departed agent's position then stops advancing and
   quietly becomes the thing pinning the log."
  (if (enrollment-open-p state-path)
      (let* ((now (get-universal-time))
             (existing (entry id roster-dir))
             (recorded (%canonical-key id))
             (returning (not (eq (entry-status existing) :enrolled)))
             (plist (list :id recorded
                          :status :enrolled
                          :enrolled-at (if returning
                                           now
                                           (or (getf existing :enrolled-at) now))
                          :departed-at nil
                          :role (or role (getf existing :role) :member))))
        (values (%write-plist (roster-entry-path recorded roster-dir) plist) nil))
      (values nil :enrollment-closed)))

(defun disenroll (id roster-dir)
  "Mark ID departed from the roster at ROSTER-DIR and stamp when it left.

   Works whether or not the gate is open, and whether or not ID was ever
   enrolled: an id with no entry gets a departed one rather than an error, so a
   self-service departure is always recorded. A departure with no record would
   leave the agent's cursor with nothing to age against.

   Any spelling of an id departs the entry any other spelling of it enrolled.
   Anything else lets an agent sit on the roster as enrolled and departed at the
   same time, with the enrolled half beyond the reach of every later call."
  (let* ((existing (entry id roster-dir))
         (recorded (%canonical-key id))
         (plist (list :id recorded
                      :status :departed
                      :enrolled-at (getf existing :enrolled-at)
                      :departed-at (get-universal-time)
                      :role (or (getf existing :role) :member))))
    (%write-plist (roster-entry-path recorded roster-dir) plist)))
