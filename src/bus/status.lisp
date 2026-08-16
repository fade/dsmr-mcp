;;;; src/bus/status.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Read-only aggregation of what can honestly be said about a coordination
;;;; bus: which broker is serving it, since when, under what parent, and against
;;;; which source.
;;;;
;;;; Three properties hold throughout this file and none of them is negotiable.
;;;;
;;;; Asking must not change the answer. Every question here has at least one
;;;; tempting implementation that mutates the thing it claims to observe, and
;;;; each of those is called out where it would otherwise be reached for. A
;;;; status read that quietly takes a lock, moves a cursor or removes a file is
;;;; worse than no status read at all, because the damage is invisible to
;;;; whoever ran it: they believed they were reading.
;;;;
;;;; Every value comes back with the check that produced it and with what that
;;;; check does NOT settle. A bare value cannot say which of those it is, and a
;;;; reader trusting a value further than the check behind it is the failure
;;;; this whole surface exists to remove. A weaker answer that states its bound
;;;; is correct; a confident wrong one is the thing that cost a peer fleet three
;;;; messages and three record edits to undo.
;;;;
;;;; Raw values only. Nothing here renders JSON and nothing here imports from
;;;; the tool layer, so the same facts are usable from a verb, from a test, and
;;;; from the image by hand. The wire shape belongs to whoever is answering a
;;;; client, and that is not this leaf's business.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-posix))

(defpackage #:dsmr-mcp/src/bus/status
  (:use #:cl)
  (:local-nicknames (#:broker #:dsmr-mcp/src/bus/broker))
  (:export #:process-alive-p
           #:parent-pid
           #:broker-identity))

(in-package #:dsmr-mcp/src/bus/status)

;;; ------------------------------------------------------------- a stated fact

(defun %fact (value &key establishes does-not-establish basis red-condition)
  "One reported fact: the value, the check that produced it, what that check
   does not settle, and how the value was obtained.

   A plist rather than a wire object on purpose. This leaf is read from a verb,
   from a test, and from a live image by hand, and only the first of those three
   wants JSON. The renderer at the tool boundary is where BASIS is checked
   against the closed set of ways a value can have been obtained and where a
   classification carrying no failure condition is refused; the spelling used
   here is the spelling that set expects.

   RED-CONDITION is included only when there is one to state. A measurement has
   no failure state of its own. A word chosen out of a small set does, and
   naming the condition that would flip it is what makes the word checkable by
   somebody who was not here when it was written."
  (append (list :value value
                :establishes establishes
                :does-not-establish does-not-establish
                :basis basis)
          (when red-condition (list :red-condition red-condition))))

(defun %unavailable (establishes does-not-establish red-condition
                     &key (basis "durable-record"))
  "A fact whose value could not be obtained, saying why.

   The value is the word `unavailable`, and never a zero, an empty string or a
   nil dressed up as one. Unavailable and zero are different claims: one says
   nothing was measured, the other says something was measured and came out at
   nothing. A surface that answers a missing measurement with a plausible number
   is how a reader comes to believe a figure nobody took."
  (%fact "unavailable"
         :establishes establishes
         :does-not-establish does-not-establish
         :basis basis
         :red-condition red-condition))

;;; ------------------------------------------------------ live process facts

(defun process-alive-p (pid)
  "True when a process with PID exists on this host right now.

   The cross-check without which a recorded pid means nothing. A row in the
   kernel's lock table names the process that CREATED the lock, and that row
   outlives the process whenever a child inherited the descriptor, so a pid read
   from anywhere is a claim about the past until this says otherwise. Measured
   on this machine: a lock row naming a pid that no longer existed, with the
   lock still held by the inheriting child."
  (and (integerp pid)
       (plusp pid)
       (not (null (ignore-errors (probe-file (format nil "/proc/~D" pid)))))))

(defun parent-pid (pid)
  "The parent pid the process PID reports right now, or NIL when it cannot be
   read.

   Read live from the running process rather than from any record, because the
   live value is the one that carries information. A broker outlives the process
   that spawned it, and when that process exits the broker is adopted by
   another; only the running process knows that happened, and a record written
   at start never will."
  (ignore-errors
   (with-open-file (in (format nil "/proc/~D/status" pid) :if-does-not-exist nil)
     (when in
       (loop for line = (read-line in nil nil)
             while line
             when (and (>= (length line) 5) (string= "PPid:" line :end2 5))
               do (return (parse-integer line :start 5 :junk-allowed t)))))))

;;; ------------------------------------------------------------ broker identity

(defun broker-identity (paths)
  "Who is serving the bus at PATHS, since when, under what parent, and against
   what source. Returns a plist of stated facts.

   Running comes from the election lock and from nothing else. The presence of
   an identity record is not evidence that a broker is running: the record is a
   file, it is left behind by a broker that died, and reporting it as current is
   exactly the stale-state failure this reader exists to avoid. Equally, the
   recorded pid is repeated only when a process with that pid actually exists,
   since a pid is reused after its process exits.

   The parent is read live from the running process. The record carries the
   parent the broker had at start, and the two are reported side by side because
   a difference between them is the reparenting: the process that spawned the
   broker has exited and something else adopted it. Neither value alone shows
   that.

   A bus with no identity record at all, which is every bus that predates
   brokers recording themselves, reports running or not from the lock and
   reports each identity field as unavailable with the reason. It does not
   report zeros."
  (let* ((running (broker:broker-running-p paths))
         (record (broker:read-broker-identity paths))
         (recorded-pid (broker:broker-identity-pid record))
         (live (and recorded-pid (process-alive-p recorded-pid)))
         (started (broker:broker-identity-started-at record))
         (revision (broker:broker-identity-revision record))
         (version (broker:broker-identity-version record)))
    (list
     :running
     (%fact (if running "running" "not-running")
            :establishes
            (if running
                "a non-blocking attempt to take this bus's election lock found it already held"
                "a non-blocking attempt to take this bus's election lock found it free, and released it again immediately")
            :does-not-establish
            "it does not establish which process holds the lock, nor that the holder is serving. A lock belongs to an open file description, so a child that inherited a dead broker's descriptor keeps this answering running. It is also racy against a broker in the act of starting."
            :basis "active-probe"
            :red-condition
            "the last open file description holding the election lock is closed, which happens when the broker and every process that inherited its descriptor have exited")

     :pid
     (cond
       ((null record)
        (%unavailable
         "no identity record exists on this bus, so nothing recorded which process took the broker role"
         "it does not establish that no broker is running. A bus whose broker started before brokers recorded themselves has no record and serves normally, and the running answer above is the one to read for that."
         "a broker starts on this bus and writes an identity record"))
       ((null recorded-pid)
        (%unavailable
         "an identity record exists on this bus but names no pid"
         "it does not establish that no broker is running; it establishes only that the record is incomplete."
         "a broker starts on this bus and writes a complete identity record"))
       (live
        (%fact recorded-pid
               :establishes
               "the identity record this bus's broker wrote at start names this pid, and a process with that pid exists now"
               :does-not-establish
               "it does not establish that this process is still the broker. A pid is reused once its process exits, and the record is a file that a restarted broker may not have rewritten. Agreement between this and the holder of the election lock is what would settle it, and that agreement is not asserted here."
               :basis "durable-record"))
       (t
        (%unavailable
         "an identity record names a pid, and no process with that pid exists now"
         "it does not establish that no broker is serving this bus. A broker that restarted without the record being rewritten, and a broker whose descriptor was inherited by a child that outlived it, both look exactly like this."
         "a broker starts on this bus and writes its own pid into the record")))

     :parent-pid
     (let ((parent (and live (parent-pid recorded-pid))))
       (if parent
           (%fact parent
                  :establishes
                  "the running process with this bus's recorded broker pid reports this parent pid right now"
                  :does-not-establish
                  "it does not establish that this is the process that spawned the broker. A broker whose spawning process has exited is adopted, and this then names whatever adopted it rather than anything that knows about the bus."
                  :basis "active-probe")
           (%unavailable
            "no live process with a recorded broker pid was available to ask for its parent"
            "it does not establish that the broker has no parent, only that none could be read."
            "a process with the recorded broker pid exists and its status can be read"
            :basis "active-probe")))

     :parent-pid-at-start
     (let ((at-start (broker:broker-identity-ppid-at-start record)))
       (if at-start
           (%fact at-start
                  :establishes
                  "the broker recorded this as its parent at the moment it won the role"
                  :does-not-establish
                  "it does not establish the broker's parent now. Reparenting after the spawning process exits changes the live value and never changes this one, which is the whole reason both are reported."
                  :basis "durable-record")
           (%unavailable
            "no identity record on this bus names the parent the broker had at start"
            "it does not establish that the broker had no parent, only that none was recorded."
            "a broker starts on this bus and records its parent")))

     :started-at
     (if started
         (%fact started
                :establishes
                "a broker wrote this bus's identity record at this universal time"
                :does-not-establish
                "it does not establish that a broker has been serving continuously since then. It is the time a record was written, and a broker that died an hour later leaves it unchanged."
                :basis "durable-record")
         (%unavailable
          "no identity record on this bus names a start time"
          "it does not establish that the broker started recently, or long ago; nothing was recorded either way."
          "a broker starts on this bus and records when"))

     :uptime-seconds
     (if started
         (%fact (max 0 (- (get-universal-time) started))
                :establishes
                "the difference between now and the start time in this bus's identity record"
                :does-not-establish
                "it does not establish continuous service. It is the age of a record, so a broker that died and was replaced without the record being rewritten reports the older figure and looks like the longer-lived one."
                :basis "durable-record")
         (%unavailable
          "no start time was recorded on this bus, so no age can be taken from it"
          "it does not establish that the broker started recently; an age was not computed at all."
          "a broker starts on this bus and records when"))

     :source-revision
     (if revision
         (%fact revision
                :establishes
                "the broker recorded this source revision when it started, so this is the source it loaded"
                :does-not-establish
                "it does not establish that this agrees with the current working tree. The tree moves while a broker goes on serving whatever it loaded, and a reader wanting that comparison makes it against a revision they name rather than against whatever the tree happens to hold at the moment of asking."
                :basis "durable-record"
                :red-condition
                "a broker starts from a different source and records a different revision")
         (%unavailable
          "the broker recorded no source revision, because nothing in the image it ran carries one"
          "it does not establish that the broker is serving the current working tree, and it does not establish that it is not. Nothing was recorded, so nothing can be compared. The version below names the release the image reported and says nothing about which source built it."
          "the build begins baking a revision into the image and a broker started from it records one"))

     :recorded-version
     (if version
         (%fact version
                :establishes
                "the broker's image reported this version string for itself at start"
                :does-not-establish
                "it does not establish which source the broker is serving. A version string moves once a release, while the source under it moves many times a day, so it cannot settle agreement with the working tree and must not be read as a revision."
                :basis "durable-record"
                :red-condition
                "a broker is started from an image reporting a different version")
         (%unavailable
          "no identity record on this bus names a version"
          "it does not establish anything about the source the broker is serving."
          "a broker starts on this bus and records the version its image reports")))))
