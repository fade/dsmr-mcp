;;;; src/bus/host/identity.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; One agent as the host service serves it.
;;;;
;;;; An agent's listener follows its watch log, and the probes leaders run read
;;;; its pid file, its heartbeat and its markers. None of them asks which
;;;; process wrote those files, and none of them should have to. The service is
;;;; a different scheduler for the detached watcher's own functions: it holds the
;;;; same lock, writes each wake line through the same formatter, keeps the same
;;;; heartbeat and raises the same deafness alarm, so a listener cannot tell an
;;;; identity the service holds from one a detached watcher holds. What changes
;;;; is the cost. One process serves every agent on the host, where there used
;;;; to be one process per agent per bus.
;;;;
;;;; Everything here is a function the supervisor calls with the time handed in,
;;;; so each duty can be tested in-process against a clock the test controls.
;;;;
;;;; One rule governs every pid file here. POSIX drops a process's record locks
;;;; on a file as soon as that process closes any descriptor for it, and this
;;;; process holds many such locks. So each pid file is opened exactly once,
;;;; that descriptor is kept for as long as the agent is served, and the file is
;;;; never opened, read or probed for a lock again. The pid and the identity it
;;;; records are kept in memory instead.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-posix))

(defpackage #:dsmr-bus-host/src/bus/host/identity
  (:use #:cl)
  ;; The struct is called IDENTITY, which is also the name of a standard
  ;; function; shadowing keeps the standard one untouched.
  (:shadow #:identity)
  (:local-nicknames (#:hostfiles #:dsmr-mcp/src/bus/hostfiles)
                    (#:heartbeat #:dsmr-mcp/src/bus/heartbeat)
                    (#:envelope #:dsmr-mcp/src/bus/envelope)
                    (#:wal #:dsmr-mcp/src/bus/wal)
                    (#:cursor #:dsmr-mcp/src/bus/cursor)
                    (#:conditions #:dsmr-bus-host/src/bus/host/conditions)
                    (#:fleetlog #:dsmr-bus-host/src/bus/host/fleetlog))
  (:import-from #:dsmr-bus-watch/src/bus/watch
                #:%signal-line
                #:%batch-parties
                #:%deaf-step
                #:make-deaf-state
                #:deaf-state-unheard-since
                #:deaf-state-latched
                #:make-deaf-watch
                #:%write-deaf-marker
                #:%notify-deaf
                #:%reap-notifiers
                #:%fd-opened-for-reading-p
                #:%directory-entries
                #:%whole-file-lock
                #:%poll-forward
                #:%unix-time
                #:%cursor-holds-seq-p
                #:%stranded-fleet-message
                #:poll-new-records
                #:default-wal-path
                #:default-cursors-dir)
  (:export
   ;; the served identity
   #:identity
   #:identity-p
   #:identity-id
   #:identity-bus
   #:identity-stem
   #:identity-token
   #:identity-session-pid
   #:identity-session-start
   #:identity-state
   #:identity-pid-stream
   #:identity-log-stream
   #:identity-log-path
   #:identity-pid-path
   #:identity-beat-path
   #:identity-floor
   #:identity-last-activity
   #:identity-deaf-watch
   #:identity-deaf-state
   #:identity-poll-ms
   #:identity-recycle-seconds
   #:identity-deaf-seconds
   #:identity-cursor-path
   #:identity-cursor-mtime
   #:identity-pending-p
   #:identity-service-pid
   ;; claim and release
   #:lock-pid-file
   #:finish-claim
   #:claim-identity
   #:release-identity
   ;; serving
   #:identity-deliver
   #:identity-tick
   #:identity-baseline
   #:clamp-baseline
   #:lapse-identity
   #:unlapse-identity
   #:log-reader-counts
   ;; reports
   #:report-to-logs))

(in-package #:dsmr-bus-host/src/bus/host/identity)

;;; ------------------------------------------------------------------ the agent

(defstruct (identity (:conc-name identity-))
  "One agent the service serves on one bus.

   ID is the agent's full bus id and BUS the bus (NIL for the unnamed one); STEM
   names the agent's watch files. TOKEN, SESSION-PID and SESSION-START come from
   the agent's registration. STATE is :SERVING while the agent's session lives
   and :LAPSED once it has ended without parking, when only the unread-mail
   alarm is kept; :RELEASED once the files are let go.

   PID-STREAM is the one descriptor on the pid file, which carries the lock, and
   LOG-STREAM the one write-only descriptor on the log. FLOOR is the highest seq
   already considered for this agent, and LAST-ACTIVITY when the log last moved
   under it. DEAF-WATCH and DEAF-STATE are the deafness alarm's, exactly as the
   detached watcher keeps them. CURSOR-MTIME is the agent's cursor file's write
   date when it was last looked at, and PENDING-P whether mail the agent would be
   handed sits above its cursor. SERVICE-PID is the pid the pid file records."
  id bus stem token session-pid session-start
  (state :serving)
  pid-stream log-stream log-path pid-path beat-path
  (floor 0)
  last-activity
  deaf-watch
  (deaf-state (make-deaf-state))
  (poll-ms 250)
  (recycle-seconds 600)
  (deaf-seconds 600)
  cursor-path
  cursor-mtime
  (pending-p nil)
  pending-key
  pid-ino
  service-pid)

(defun report-to-logs (level code &key bus id subject msg)
  "Hand a report to the service's logs: INFO to the service log, anything worse
   to the fleet error log a leader watches. Takes the arguments the healing
   supervisor gives its report function, so it can be handed straight to it.

   A heal is routine and belongs in the service log; only what a leader may have
   to act on goes to the fleet log."
  (if (eq level :info)
      (fleetlog:service-log :info "~A~@[ bus=~A~]~@[ id=~A~]~@[ subject=~A~]~@[: ~A~]"
                            code bus id subject msg)
      (fleetlog:fleet-report level code :bus bus :id id :subject subject :msg msg)))

;;; ----------------------------------------------------------------- the files

(defvar *open-nofollow*
  (let ((flag (find-symbol "O-NOFOLLOW" "SB-POSIX")))
    (if (and flag (boundp flag)) (symbol-value flag) 0))
  "O_NOFOLLOW where this SBCL provides it, else 0. A pid file or log that has
   been replaced by a symbolic link is refused rather than followed; where the
   flag is missing the files are opened without that check.")

(defun %native (path)
  "PATH as a native namestring."
  (uiop:native-namestring path))

(defun %mtime (path)
  "PATH's write date in universal time, or NIL when it does not exist."
  (ignore-errors (file-write-date path)))

(defun %watch-file (identity type)
  "The watch file of TYPE beside IDENTITY's pid file."
  (hostfiles:watch-state-file (identity-stem identity) type))

(defun %cursor-path (self-id cursors-dir)
  "Where SELF-ID's durable cursor lives under CURSORS-DIR."
  (merge-pathnames (envelope:encode-id self-id)
                   (uiop:ensure-directory-pathname cursors-dir)))

(defun lock-pid-file (path)
  "Open the pid file at PATH and take a write lock on the whole of it. Returns
   the descriptor, which now carries the lock, or NIL when another process holds
   it already.

   The descriptor must be kept open for as long as the lock is wanted and must
   be the only one this process ever opens on PATH: closing any descriptor on
   the file drops the lock."
  (ensure-directories-exist path)
  (let ((fd (sb-posix:open (%native path)
                           (logior sb-posix:o-creat sb-posix:o-rdwr *open-nofollow*)
                           #o644)))
    (handler-case
        (progn
          (sb-posix:fcntl fd sb-posix:f-setlk (%whole-file-lock sb-posix:f-wrlck))
          fd)
      (sb-posix:syscall-error ()
        (ignore-errors (sb-posix:close fd))
        nil))))

(defun %close-quietly (stream)
  "Close STREAM when there is one, ignoring a failure."
  (when stream (ignore-errors (close stream))))

(defun %take-pid-file (identity fd)
  "Record IDENTITY's service pid and full id in its pid file through FD, the
   descriptor holding the file's lock, and keep FD as IDENTITY's pid stream.
   Nothing else ever opens the file, so the lock lasts as long as the stream."
  (sb-posix:ftruncate fd 0)
  (sb-posix:lseek fd 0 sb-posix:seek-set)
  (let ((stream (sb-sys:make-fd-stream fd :input t :output t
                                          :external-format :utf-8
                                          :buffering :full)))
    (setf (identity-pid-stream identity) stream)
    (format stream "~D~%~A~%" (identity-service-pid identity) (identity-id identity))
    (finish-output stream))
  (setf (identity-pid-ino identity) (sb-posix:stat-ino (sb-posix:fstat fd))))

(defun finish-claim (fd registration &key (service-pid (sb-posix:getpid))
                                          (now (%unix-time))
                                          wal-path cursors-dir
                                          (report-fn #'report-to-logs))
  "Serve the agent REGISTRATION names, given FD, a descriptor already holding
   the write lock on its pid file. Returns the identity.

   Takes the agent's baseline from its cursor, records SERVICE-PID and the full
   id in the pid file through FD, opens the log for appending, writes the
   heartbeat, and removes a deafness marker an earlier holder left. WAL-PATH and
   CURSORS-DIR default to the bus's own. Used both for a fresh claim and for a
   lock taken over from a watcher that let it go.

   When anything fails the descriptors are closed, which lets the lock go, and
   the failure is passed on."
  (let* ((id (hostfiles:normalise-agent-id (getf registration :id)))
         (bus (getf registration :bus))
         (stem (hostfiles:detach-stem bus id))
         (wal-path (or wal-path (default-wal-path bus)))
         (cursors-dir (or cursors-dir (default-cursors-dir bus)))
         (deaf-seconds (or (getf registration :deaf-seconds) 600))
         (identity (make-identity
                    :id id :bus bus :stem stem
                    :token (getf registration :token)
                    :session-pid (getf registration :session-pid)
                    :session-start (getf registration :session-start)
                    :pid-path (hostfiles:watch-state-file stem "pid")
                    :log-path (hostfiles:watch-state-file stem "log")
                    :beat-path (heartbeat:beat-path id (heartbeat:default-watch-dir bus))
                    :poll-ms (or (getf registration :poll-ms) 250)
                    :recycle-seconds (or (getf registration :recycle-seconds) 600)
                    :deaf-seconds deaf-seconds
                    :deaf-watch (and (plusp deaf-seconds)
                                     (make-deaf-watch :self-id id :bus bus :stem stem
                                                      :threshold deaf-seconds))
                    :cursor-path (%cursor-path id cursors-dir)
                    :last-activity now
                    :service-pid service-pid))
         (claimed nil))
    (unwind-protect
         (progn
           (identity-baseline identity wal-path cursors-dir :report-fn report-fn)
           (setf (identity-cursor-mtime identity) (%mtime (identity-cursor-path identity)))
           (%take-pid-file identity fd)
           (let ((log-fd (sb-posix:open (%native (identity-log-path identity))
                                        (logior sb-posix:o-creat sb-posix:o-wronly
                                                sb-posix:o-append *open-nofollow*)
                                        #o644)))
             (setf (identity-log-stream identity)
                   (sb-sys:make-fd-stream log-fd :output t :external-format :utf-8
                                                 :buffering :full)))
           (heartbeat:write-beat (identity-beat-path identity)
                                 :mode :stream :baseline (identity-floor identity)
                                 :poll-ms 250)
           (let ((marker (%watch-file identity "deaf")))
             (when (probe-file marker) (ignore-errors (delete-file marker))))
           (setf claimed t)
           identity)
      (unless claimed
        (%close-quietly (identity-log-stream identity))
        (if (identity-pid-stream identity)
            (%close-quietly (identity-pid-stream identity))
            (ignore-errors (sb-posix:close fd)))))))

(defun claim-identity (registration &rest keys
                       &key service-pid now wal-path cursors-dir report-fn)
  "Take the lock on the pid file of the agent REGISTRATION names and serve it.
   Returns (values identity nil), or (values nil :held) when another process
   already holds the lock. KEYS are passed to FINISH-CLAIM."
  (declare (ignore service-pid now wal-path cursors-dir report-fn))
  (let* ((id (hostfiles:normalise-agent-id (getf registration :id)))
         (stem (hostfiles:detach-stem (getf registration :bus) id))
         (fd (lock-pid-file (hostfiles:watch-state-file stem "pid"))))
    (if fd
        (values (apply #'finish-claim fd registration keys) nil)
        (values nil :held))))

(defun %unlink-own-pid-file (identity)
  "Remove IDENTITY's pid file, but only when the file at that path is still the
   one this process holds, so a file someone else put there is left alone."
  (let ((path (%native (identity-pid-path identity))))
    (when (eql (ignore-errors (sb-posix:stat-ino (sb-posix:stat path)))
               (identity-pid-ino identity))
      (ignore-errors (sb-posix:unlink path)))))

(defun release-identity (identity &key (remove-files t))
  "Stop serving IDENTITY and return it.

   With REMOVE-FILES, the agent is deregistered: the pid file is removed while
   its lock is still held, so nobody sees it unlocked first, then the lock is let
   go, and the heartbeat and any deafness marker are removed. The log, the park
   marker and the listener's offset are the agent's and stay. Without it, which
   is how an orderly stop of the service leaves things, only the descriptors are
   closed and every file stays for the service that follows."
  (%close-quietly (identity-log-stream identity))
  (setf (identity-log-stream identity) nil)
  (when (and remove-files (identity-pid-stream identity))
    (%unlink-own-pid-file identity)
    (heartbeat:remove-beat (identity-beat-path identity))
    (let ((marker (%watch-file identity "deaf")))
      (when (probe-file marker) (ignore-errors (delete-file marker)))))
  (%close-quietly (identity-pid-stream identity))
  (setf (identity-pid-stream identity) nil
        (identity-state identity) :released)
  identity)

;;; ------------------------------------------------------------------ baseline

(defun %heal-baseline (identity wal-path cursor-path rebase-p report-fn)
  "The baseline for IDENTITY's stranded cursor at CURSOR-PATH: rewritten into
   the log at WAL-PATH when REBASE-P and the rewrite succeeds, else the log's
   head. Either outcome is reported with the cursor's old position."
  (multiple-value-bind (baseline action report)
      (hostfiles:heal-stranded-baseline (identity-id identity) wal-path cursor-path
                                        :rebase-p rebase-p)
    (when (member action '(:rebased :clamped))
      (let ((rebased-p (eq action :rebased)))
        (funcall report-fn (if rebased-p :warn :error)
                 (if rebased-p "stranded-cursor" "stranded-cursor-clamped")
                 :bus (identity-bus identity) :id (identity-id identity)
                 :subject (identity-stem identity)
                 :msg (%stranded-fleet-message report))))
    ;; A cursor that vanished since it was read has no baseline to give, and
    ;; the agent then arms at the head as it would with no cursor at all.
    (or baseline (values (wal:scan wal-path)))))

(defun %stranded-baseline (identity wal-path cursor-path reason head report-fn)
  "Raise the STRANDED-CURSOR fault for IDENTITY's cursor, stranded for REASON
   against a log whose head is HEAD, and return the baseline the heal taken
   gives. Skipped, the fault leaves the identity armed at the head."
  (restart-case
      (progn
        (conditions:raise-fault 'conditions:stranded-cursor
                                :bus (identity-bus identity)
                                :id (identity-id identity)
                                :subject (identity-stem identity)
                                :detail (format nil "~(~A~) against a log whose head is ~D"
                                                reason head))
        (%heal-baseline identity wal-path cursor-path nil report-fn))
    (conditions:rebase-cursor ()
      :report "Rewrite the cursor into the current log, reporting its old position."
      (%heal-baseline identity wal-path cursor-path t report-fn))
    (clamp-baseline ()
      :report "Leave the cursor as it is and arm at the head of the log."
      (%heal-baseline identity wal-path cursor-path nil report-fn))))

(defun identity-baseline (identity wal-path cursors-dir
                          &key (report-fn #'report-to-logs))
  "Set IDENTITY's floor from the agent's durable cursor under CURSORS-DIR over
   the log at WAL-PATH, and return it.

   Arming from the cursor is what lets mail that landed while nothing was
   watching still wake the agent. With no readable cursor the floor is the head
   of the log instead: a missing cursor read as 0 would make the whole log owed
   to an agent that has never read it.

   A cursor that is stranded, above the head of the log or recorded against a
   generation of it that is gone, would filter out every record in the new log
   while every probe called the agent healthy. That is raised as a
   STRANDED-CURSOR fault offering two heals. REBASE-CURSOR rewrites the cursor
   into the current log and reports the old position as a warning, since the
   rewrite discards the only record of it. CLAMP-BASELINE leaves the cursor
   alone and arms at the head of the log, reported as an error. A fault the
   supervisor skips clamps too, so the identity never filters on a stranded
   value."
  (let* ((id (identity-id identity))
         (path (%cursor-path id cursors-dir)))
    (setf (identity-cursor-path identity) path)
    (setf (identity-floor identity)
          (if (not (%cursor-holds-seq-p path))
              (progn
                (funcall report-fn :info "no-cursor"
                         :bus (identity-bus identity) :id id
                         :subject (identity-stem identity)
                         :msg "no readable cursor; armed at the log head")
                (values (wal:scan wal-path)))
              (let* ((subscriber (cursor:make-subscriber id wal-path path))
                     (head (values (wal:scan wal-path)))
                     (reason (cursor:stranded-reason
                              subscriber :head head
                                         :log-generation (wal:generation wal-path))))
                (if reason
                    (%stranded-baseline identity wal-path path reason head report-fn)
                    (cursor:cursor-value subscriber)))))))

;;; ------------------------------------------------------------------- readers

(defun log-reader-counts (log-paths &key (exclude-pids (list (sb-posix:getpid))))
  "How many processes hold each of LOG-PATHS open for reading, as a hash table
   from each path's native namestring to a count, taken in one pass over /proc.
   Every count is :UNKNOWN where there is no /proc to ask.

   Processes in EXCLUDE-PIDS, by default this one, are not counted, nor are
   descriptors opened write-only: the service's own log descriptors are
   write-only, and a reader is something that could hear a line. A log that does
   not exist has no readers. Processes whose descriptors may not be looked at
   belong to another user and are passed over."
  (let ((counts (make-hash-table :test 'equal))
        (targets (make-hash-table :test 'equal)))
    (dolist (path log-paths)
      (let ((key (%native path)))
        (setf (gethash key counts) 0)
        (let ((true (ignore-errors (%native (truename path)))))
          (when true (setf (gethash true targets) key)))))
    (cond
      ((not (probe-file "/proc/self/fd/"))
       (loop for key being the hash-keys of counts
             do (setf (gethash key counts) :unknown)))
      ((plusp (hash-table-count targets))
       (dolist (name (%directory-entries "/proc"))
         (let ((pid (and (every #'digit-char-p name) (parse-integer name))))
           (when (and pid (not (member pid exclude-pids)))
             (let ((fd-dir (format nil "/proc/~D/fd" pid))
                   (seen '()))
               (dolist (fd (%directory-entries fd-dir))
                 (let ((key (gethash (ignore-errors
                                      (sb-posix:readlink (format nil "~A/~A" fd-dir fd)))
                                     targets)))
                   (when (and key (not (member key seen :test #'string=))
                              (%fd-opened-for-reading-p pid fd))
                     (push key seen)
                     (incf (gethash key counts)))))))))))
    counts))

(defun %readers (identity readers)
  "READERS when the caller measured it, else a fresh count for IDENTITY's log."
  (or readers
      (gethash (%native (identity-log-path identity))
               (log-reader-counts (list (identity-log-path identity))))))

;;; ---------------------------------------------------------------- deafness

(defun %parked-p (identity)
  "True while IDENTITY's park marker exists. Read, never created or removed."
  (and (probe-file (%watch-file identity "parked")) t))

(defun %observe-deaf (identity now &rest observation)
  "Feed one OBSERVATION at NOW (Unix seconds) to the deafness rule with
   IDENTITY's own state, and act on the answer exactly as the detached watcher
   does: on a raise write the marker and then notify, on a clear remove the
   marker. Returns the action, or NIL while the alarm is off."
  (let ((watch (identity-deaf-watch identity)))
    (when watch
      (multiple-value-bind (state action)
          (apply #'%deaf-step (identity-deaf-state identity) now
                 :threshold (identity-deaf-seconds identity) observation)
        (setf (identity-deaf-state identity) state)
        (case action
          (:raise
           (let ((since (deaf-state-unheard-since state)))
             (ignore-errors (%write-deaf-marker watch since))
             (%notify-deaf watch (- now since))))
          (:clear
           (let ((marker (%watch-file identity "deaf")))
             (when (probe-file marker) (ignore-errors (delete-file marker))))))
        action))))

;;; ------------------------------------------------------------------- fan-out

(defun %own-namespace (identity)
  "The namespace IDENTITY's agent belongs to, which decides how senders are
   named on its lines."
  (nth-value 0 (envelope:split-agent-id (identity-id identity))))

(defun %write-line (identity line)
  "Append LINE to IDENTITY's log and push it out at once."
  (let ((stream (identity-log-stream identity)))
    (write-string line stream)
    (terpri stream)
    (finish-output stream)))

(defun %announce (identity records now readers)
  "Write the one wake line for RECORDS, all of them mail IDENTITY's agent would
   be handed, and note it for the deafness alarm."
  (multiple-value-bind (froms tos) (%batch-parties records (%own-namespace identity))
    (%write-line identity (%signal-line (reduce #'max records :key #'wal:record-seq)
                                        froms tos)))
  (%observe-deaf identity now
                 :readers (%readers identity readers)
                 :parked-p (%parked-p identity)
                 :line-written-p t))

(defun identity-deliver (identity records now &key readers)
  "Hand IDENTITY the bus's new RECORDS, oldest first, at NOW (Unix seconds).
   Returns true when a wake line was written.

   One line per batch, carrying the highest seq of the mail in it and who it
   came from and was for, exactly as the detached watcher streams it. The
   agent's own publishes and mail addressed to someone else are stepped over
   without a line. Records at or below the floor have been considered already
   and are ignored, so a batch handed over twice is announced once. While the
   identity is lapsed nothing is written; the mail is only noted as pending.

   READERS is the count of processes following the log, when the caller has
   just measured it for many identities at once; otherwise it is measured
   here."
  (let* ((floor (identity-floor identity))
         (fresh (remove-if-not (lambda (record) (> (wal:record-seq record) floor))
                               records)))
    (when fresh
      (setf (identity-floor identity) (reduce #'max fresh :key #'wal:record-seq)
            (identity-last-activity identity) now)
      (let* ((own (envelope:encode-id (identity-id identity)))
             (mail (remove-if-not (lambda (record)
                                    (envelope:deliverable-record-p record own))
                                  fresh)))
        (when mail
          (if (eq (identity-state identity) :serving)
              (progn (%announce identity mail now readers) t)
              (progn (setf (identity-pending-p identity) t) nil)))))))

;;; --------------------------------------------------------------------- ticks

(defun %refresh-beat (identity now)
  "Move IDENTITY's heartbeat's write date to NOW (Unix seconds). The beat is
   written once at claim and only touched afterwards, since rewriting every
   agent's beat every second costs far more than moving its date.

   A beat that cannot be touched is a STALE-BEAT fault, healed by writing the
   beat again: a probe reads a missing beat as a dead watcher."
  (let ((path (%native (identity-beat-path identity))))
    (handler-case (sb-posix:utimes path now now)
      (sb-posix:syscall-error (e)
        (restart-case
            (conditions:raise-fault 'conditions:stale-beat
                                    :bus (identity-bus identity)
                                    :id (identity-id identity)
                                    :subject (identity-stem identity)
                                    :detail (format nil "the heartbeat ~A could not be refreshed: ~A"
                                                    path e))
          (conditions:rewrite-beat ()
            :report "Write the heartbeat again."
            (heartbeat:write-beat (identity-beat-path identity)
                                  :mode :stream :baseline (identity-floor identity)
                                  :poll-ms 250)
            (ignore-errors (sb-posix:utimes path now now))))))))

(defun %reclaim-pid-file (identity)
  "Take IDENTITY's pid file again after it was removed or replaced, and return
   true, or NIL when another process now holds its lock. The descriptor on the
   old file is closed only once the new one is held; its lock was on a file
   that is no longer at the path."
  (let ((fd (lock-pid-file (identity-pid-path identity)))
        (old (identity-pid-stream identity)))
    (when fd
      (%take-pid-file identity fd)
      (%close-quietly old)
      t)))

(defun %check-pid-claim (identity)
  "Raise PID-CLAIM-LOST when the file at IDENTITY's pid path is gone or is not
   the one this process holds. Probes read the lock on that path as `a watcher
   is running`, so a lock on a file no longer there says nothing to them.

   The path is only examined with stat, which opens nothing, so the lock this
   process holds is never put at risk by the check."
  (let ((ino (ignore-errors
              (sb-posix:stat-ino (sb-posix:stat (%native (identity-pid-path identity)))))))
    (unless (eql ino (identity-pid-ino identity))
      (restart-case
          (conditions:raise-fault 'conditions:pid-claim-lost
                                  :bus (identity-bus identity)
                                  :id (identity-id identity)
                                  :subject (identity-stem identity)
                                  :detail (if ino
                                              "the pid file was replaced"
                                              "the pid file was removed"))
        (conditions:reclaim-pid-file ()
          :report "Create the pid file again, lock it and record this process."
          (%reclaim-pid-file identity))))))

(defun %cursor-seq (identity wal-path)
  "The seq IDENTITY's agent has consumed to, or NIL when its cursor holds
   nothing readable. NIL is not 0: an unreadable cursor says nothing about what
   the agent has read."
  (let ((path (identity-cursor-path identity)))
    (and path (%cursor-holds-seq-p path)
         (cursor:cursor-value (cursor:make-subscriber (identity-id identity)
                                                      wal-path path)))))

(defun %stranded-p (identity wal-path)
  "True when IDENTITY's cursor is stranded against the log at WAL-PATH. The
   cheap question, asked before any fault is raised."
  (let ((path (identity-cursor-path identity)))
    (and path (%cursor-holds-seq-p path)
         (ignore-errors
          (cursor:stranded-reason
           (cursor:make-subscriber (identity-id identity) wal-path path)))
         t)))

(defun %recheck-cursor (identity now readers wal-path cursors-dir report-fn
                        &key force)
  "Look at IDENTITY's cursor again when its write date has changed since the
   last look, or when FORCE. A cursor found stranded is healed through
   IDENTITY-BASELINE, and when the heal lowers the floor the mail between the
   new floor and the old one is announced at once, since the bus's reader has
   already moved past it.

   A heal never raises the floor: records above the old floor have not been
   handed over yet, and skipping them would lose mail."
  (let ((mtime (%mtime (identity-cursor-path identity))))
    (when (or force (not (eql mtime (identity-cursor-mtime identity))))
      (setf (identity-cursor-mtime identity) mtime)
      (when (%stranded-p identity wal-path)
        (let* ((old-floor (identity-floor identity))
               (baseline (identity-baseline identity wal-path cursors-dir
                                            :report-fn report-fn)))
          (setf (identity-cursor-mtime identity) (%mtime (identity-cursor-path identity)))
          (if (< baseline old-floor)
              (identity-deliver identity
                                (values (%poll-forward wal-path (wal:make-reader) baseline))
                                now :readers readers)
              (setf (identity-floor identity) old-floor)))))))

(defun %unread-mail (identity wal-path)
  "The records between IDENTITY's cursor and its floor that its agent would be
   handed, oldest first; NIL when the cursor holds nothing readable or has
   reached the floor. Records above the floor are left to the next delivery."
  (let ((cursor (%cursor-seq identity wal-path))
        (floor (identity-floor identity)))
    (when (and cursor (< cursor floor))
      (remove-if (lambda (record) (> (wal:record-seq record) floor))
                 (values (poll-new-records wal-path cursor (identity-id identity)))))))

(defun %pending-p (identity wal-path)
  "True when mail IDENTITY's agent would be handed sits above its cursor. The
   log is read only when the cursor or the floor has moved since the last
   answer, so a lapsed identity costs a stat and a small file read per tick."
  (let* ((key (list (%cursor-seq identity wal-path) (identity-floor identity)))
         (cached (identity-pending-key identity)))
    (if (and cached (equal (car cached) key))
        (cdr cached)
        (let ((pending (and (%unread-mail identity wal-path) t)))
          (setf (identity-pending-key identity) (cons key pending))
          pending))))

(defun %offset-time (identity)
  "When a listener last saved its read offset for IDENTITY's log, in Unix
   seconds, or NIL when it never has."
  (let ((date (%mtime (%watch-file identity "offset"))))
    (and date (%unix-time date))))

(defun %reannounce (identity now readers wal-path cursors-dir report-fn)
  "Once a recycle window has passed with the log quiet under IDENTITY, announce
   again the mail still above the agent's cursor, and start the next window.

   This is the detached watcher's re-arm on the same clock: a wake line that
   nobody heard is not the agent's only chance to learn of its mail. The cursor
   is checked for stranding first, as a re-arm would.

   The window has to be exceeded, not just reached. The clock is in whole
   seconds, so the log may have moved up to a second after the LAST it records,
   and a window that was only reached could end almost a second early."
  (let ((last (identity-last-activity identity)))
    (when (and last (> (- now last) (identity-recycle-seconds identity)))
      (setf (identity-last-activity identity) now)
      (%recheck-cursor identity now readers wal-path cursors-dir report-fn :force t)
      (let ((mail (%unread-mail identity wal-path)))
        (when mail
          (%announce identity mail now readers))))))

(defun %lapsed-tick (identity now readers wal-path)
  "One tick of a lapsed IDENTITY: no lines, only the question of whether mail
   is waiting unread. Mail that waits counts as a line nobody heard, so the
   deafness rule raises the alarm after the threshold exactly as it would for a
   served agent. Returns :HEARD once the cursor has moved past mail that was
   pending, which ends the lapse, and :OK otherwise."
  (let ((was (identity-pending-p identity))
        (pending (%pending-p identity wal-path)))
    (setf (identity-pending-p identity) pending)
    (if (and was (not pending))
        (let ((marker (%watch-file identity "deaf")))
          (when (probe-file marker) (ignore-errors (delete-file marker)))
          (setf (identity-deaf-state identity) (make-deaf-state))
          :heard)
        (progn
          (%observe-deaf identity now
                         :readers (%readers identity readers)
                         :parked-p (%parked-p identity)
                         :line-written-p pending
                         :offset-time (%offset-time identity))
          :ok))))

(defun identity-tick (identity now &key readers wal-path cursors-dir
                                        (report-fn #'report-to-logs))
  "Do IDENTITY's duties for one tick at NOW (Unix seconds) and return :OK, or
   :HEARD when a lapsed identity's agent has read past its pending mail.

   Every tick refreshes the heartbeat, checks the pid file is still the one
   held, and looks at the cursor again if it has been rewritten. A served
   identity then announces unread mail again once a recycle window has passed
   quietly, and samples the deafness rule; a lapsed one only watches for unread
   mail. Faults are raised for the supervisor to heal.

   READERS is the count of processes following the log from the supervisor's
   one census of every log; left out, it is measured here. WAL-PATH and
   CURSORS-DIR default to the bus's own."
  (when (eq (identity-state identity) :released)
    (return-from identity-tick :ok))
  (let ((wal-path (or wal-path (default-wal-path (identity-bus identity))))
        (cursors-dir (or cursors-dir (default-cursors-dir (identity-bus identity)))))
    (%reap-notifiers)
    (%refresh-beat identity now)
    (%check-pid-claim identity)
    (%recheck-cursor identity now readers wal-path cursors-dir report-fn)
    (if (eq (identity-state identity) :lapsed)
        (%lapsed-tick identity now readers wal-path)
        (progn
          (%reannounce identity now readers wal-path cursors-dir report-fn)
          (%observe-deaf identity now
                         :readers (%readers identity readers)
                         :parked-p (%parked-p identity)
                         :offset-time (%offset-time identity))
          :ok))))

;;; -------------------------------------------------------------------- lapses

(defun lapse-identity (identity)
  "Mark IDENTITY lapsed: its session ended without parking, so no wake lines
   are written for it, but its files stay held and unread mail still raises
   the alarm. Returns IDENTITY."
  (setf (identity-state identity) :lapsed
        (identity-pending-key identity) nil)
  identity)

(defun unlapse-identity (identity registration)
  "Serve IDENTITY again for the session REGISTRATION names, taking that
   registration's token, session and settings. Returns IDENTITY."
  (let ((deaf-seconds (or (getf registration :deaf-seconds)
                          (identity-deaf-seconds identity))))
    (setf (identity-state identity) :serving
          (identity-token identity) (getf registration :token)
          (identity-session-pid identity) (getf registration :session-pid)
          (identity-session-start identity) (getf registration :session-start)
          (identity-poll-ms identity) (or (getf registration :poll-ms)
                                          (identity-poll-ms identity))
          (identity-recycle-seconds identity) (or (getf registration :recycle-seconds)
                                                  (identity-recycle-seconds identity))
          (identity-deaf-seconds identity) deaf-seconds
          (identity-deaf-watch identity)
          (and (plusp deaf-seconds)
               (make-deaf-watch :self-id (identity-id identity)
                                :bus (identity-bus identity)
                                :stem (identity-stem identity)
                                :threshold deaf-seconds))
          (identity-pending-p identity) nil
          (identity-pending-key identity) nil))
  identity)
