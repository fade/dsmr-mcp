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
   ;; claim and release
   #:lock-pid-file
   #:finish-claim
   #:claim-identity
   #:release-identity
   ;; serving
   #:identity-deliver
   #:identity-baseline
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
   handed sits above its cursor."
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
  pid-ino)

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
                    :last-activity now))
         (claimed nil))
    (unwind-protect
         (progn
           (identity-baseline identity wal-path cursors-dir :report-fn report-fn)
           (setf (identity-cursor-mtime identity) (%mtime (identity-cursor-path identity)))
           (sb-posix:ftruncate fd 0)
           (sb-posix:lseek fd 0 sb-posix:seek-set)
           (let ((stream (sb-sys:make-fd-stream fd :input t :output t
                                                   :external-format :utf-8
                                                   :buffering :full)))
             (setf (identity-pid-stream identity) stream)
             (format stream "~D~%~A~%" service-pid id)
             (finish-output stream))
           (setf (identity-pid-ino identity) (sb-posix:stat-ino (sb-posix:fstat fd)))
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

(defun identity-baseline (identity wal-path cursors-dir
                          &key (report-fn #'report-to-logs))
  "Set IDENTITY's floor from the agent's durable cursor under CURSORS-DIR over
   the log at WAL-PATH, and return it.

   Arming from the cursor is what lets mail that landed while nothing was
   watching still wake the agent. With no readable cursor the floor is the head
   of the log instead: a missing cursor read as 0 would make the whole log owed
   to an agent that has never read it."
  (let ((path (%cursor-path (identity-id identity) cursors-dir)))
    (setf (identity-cursor-path identity) path)
    (setf (identity-floor identity)
          (if (%cursor-holds-seq-p path)
              (cursor:cursor-value
               (cursor:make-subscriber (identity-id identity) wal-path path))
              (progn
                (funcall report-fn :info "no-cursor"
                         :bus (identity-bus identity) :id (identity-id identity)
                         :subject (identity-stem identity)
                         :msg "no readable cursor; armed at the log head")
                (values (wal:scan wal-path)))))))

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
