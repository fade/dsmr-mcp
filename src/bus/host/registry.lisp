;;;; src/bus/host/registry.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Who the host service serves, and for how long.
;;;;
;;;; An agent asks to be watched by leaving a registration file in the host
;;;; directory, and the service answers with an acknowledgement beside it. I
;;;; made registrations files rather than messages because a file outlives the
;;;; process that reads it: when the service restarts, it reads the directory
;;;; again and every agent is served as before, with nobody having to register
;;;; twice. Removing the file is how an agent leaves.
;;;;
;;;; A registration names the agent's session, and the service follows that
;;;; process. When a parked session ends, its registration ends with it and
;;;; nothing is raised: parking is how an agent says it is going. When an
;;;; unparked session ends, the identity lapses instead. No wake lines are
;;;; written for it, but its files stay held and mail left unread still raises
;;;; the alarm, because that alarm is how you find out a session crashed.
;;;;
;;;; A bus roster is the operator's statement of who should be on the bus. The
;;;; service compares it with the registrations and reports the difference as a
;;;; finding, and that is all it does with it: nobody is refused, delayed or
;;;; served differently because of the roster, which this file only ever reads.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-posix))

(defpackage #:dsmr-bus-host/src/bus/host/registry
  (:use #:cl)
  (:local-nicknames (#:hostfiles #:dsmr-mcp/src/bus/hostfiles)
                    (#:roster #:dsmr-mcp/src/bus/roster)
                    (#:conditions #:dsmr-bus-host/src/bus/host/conditions)
                    (#:ident #:dsmr-bus-host/src/bus/host/identity))
  (:import-from #:dsmr-bus-watch/src/bus/watch
                #:%pid-alive-p
                #:%unix-time
                #:%lock-holder
                #:%pid-file-contents
                #:%whole-file-lock
                #:default-wal-path
                #:default-cursors-dir)
  (:export
   ;; the registry
   #:registry
   #:make-registry
   #:registry-p
   #:registry-identities
   #:registry-reported-findings
   #:registry-service-pid
   #:registry-adopting
   ;; registrations and sessions
   #:scan-registrations
   #:check-sessions
   #:drop-identity
   #:settle-tick
   ;; watchers started before the service
   #:find-legacy-watchers
   #:adopt-legacy-watcher
   #:adopt-legacy-watchers
   ;; roster
   #:roster-gap-findings
   ;; status
   #:registry-snapshot))

(in-package #:dsmr-bus-host/src/bus/host/registry)

;;; --------------------------------------------------------------- the registry

(defstruct (registry (:constructor make-registry
                         (&key (service-pid (sb-posix:getpid)))))
  "Everything the service is serving and has said.

   IDENTITIES maps each registration's file stem to the identity served for it.
   REPORTED-FINDINGS holds every finding already reported, so each is reported
   once and its end is noticed. SERVICE-PID is the pid acknowledgements and pid
   files name. ADOPTING lists the watchers being taken over at this moment."
  (identities (make-hash-table :test 'equal))
  (reported-findings (make-hash-table :test 'equal))
  service-pid
  (adopting '()))

(defun %default-report (level code &key bus id subject msg)
  "Report through the service's own logs."
  (ident:report-to-logs level code :bus bus :id id :subject subject :msg msg))

(defun %note-once (registry key)
  "Record KEY as reported. True when it was not reported before."
  (let ((table (registry-reported-findings registry)))
    (unless (gethash key table)
      (setf (gethash key table) t))))

(defun %forget (registry key)
  "Forget that KEY was reported. True when it had been."
  (remhash key (registry-reported-findings registry)))

;;; ------------------------------------------------------------- registrations

(defun %native (path)
  (uiop:native-namestring path))

(defun %quarantine (stem)
  "Move STEM's registration aside as <stem>.reg.bad, where it can be looked at
   and is never read as a registration again."
  (let ((path (%native (hostfiles:registration-path stem))))
    (sb-posix:rename path (concatenate 'string path ".bad"))))

(defun %set-aside (stem detail report-fn)
  "Raise UNREADABLE-REGISTRATION for STEM, offering to quarantine it. A
   quarantined registration is reported as an error, once: it was put there by
   someone who wanted to be served, and they are not."
  (restart-case
      (conditions:raise-fault 'conditions:unreadable-registration
                              :subject stem :detail detail)
    (conditions:quarantine-registration ()
      :report "Move the registration aside as <stem>.reg.bad."
      (%quarantine stem)
      (funcall report-fn :error "unreadable-registration" :subject stem
               :msg (format nil "~A; moved aside as ~A.reg.bad" detail stem)))))

(defun %registration-problem (stem plist)
  "Why the readable registration PLIST under STEM cannot be served, or NIL when
   it can. A registration has to name an agent, and has to be filed under the
   stem its own agent and bus give: anything else would have the service claim
   the files of an agent that never asked."
  (let ((id (getf plist :id))
        (bus (getf plist :bus)))
    (cond ((not (and (stringp id) (plusp (length id))))
           "the registration names no agent")
          ((not (or (null bus) (stringp bus)))
           "the registration's bus is not a name")
          ((not (string= stem (hostfiles:detach-stem bus id)))
           (format nil "the registration names ~A on bus ~A, which is not filed under ~A"
                   id (or bus "default") stem)))))

(defun %acknowledge (registry identity)
  "Write the acknowledgement that IDENTITY's current registration is served."
  (hostfiles:write-served-ack (ident:identity-stem identity)
                              (ident:identity-token identity)
                              (registry-service-pid registry)))

(defun %claim (registry stem plist now report-fn wal-path-fn cursors-dir-fn)
  "Claim the identity PLIST registers under STEM and acknowledge it. Leaves it
   alone when another process holds its lock: a watcher of the agent's own is
   then still running, and taking it over is adoption's work."
  (let ((bus (getf plist :bus)))
    (multiple-value-bind (identity refusal)
        (ident:claim-identity plist
                              :service-pid (registry-service-pid registry)
                              :now now
                              :wal-path (funcall wal-path-fn bus)
                              :cursors-dir (funcall cursors-dir-fn bus)
                              :report-fn report-fn)
      (declare (ignore refusal))
      (when identity
        (setf (gethash stem (registry-identities registry)) identity)
        (%acknowledge registry identity))
      identity)))

(defun %renew (registry identity plist)
  "Take the new registration PLIST for IDENTITY: its token, session and
   settings, and serve it again if it had lapsed. The pid file's lock is kept
   throughout, so no probe sees the identity unwatched."
  (ident:unlapse-identity identity plist)
  (%acknowledge registry identity))

(defun %scan-one (registry stem now report-fn wal-path-fn cursors-dir-fn)
  "Bring STEM's registration and the identity served for it into line."
  (multiple-value-bind (plist status)
      (hostfiles:read-registration (hostfiles:registration-path stem))
    (case status
      (:unreadable
       (%set-aside stem "the registration file cannot be read as one" report-fn))
      (:ok
       (let ((problem (%registration-problem stem plist))
             (identity (gethash stem (registry-identities registry))))
         (cond
           (problem (%set-aside stem problem report-fn))
           ((null identity)
            (%claim registry stem plist now report-fn wal-path-fn cursors-dir-fn))
           ((not (equal (getf plist :token) (ident:identity-token identity)))
            (%renew registry identity plist))))))))

(defun scan-registrations (registry now &key (report-fn #'%default-report)
                                             (wal-path-fn #'default-wal-path)
                                             (cursors-dir-fn #'default-cursors-dir))
  "Bring REGISTRY into line with the registration files, at NOW (Unix seconds),
   and return REGISTRY.

   A new registration is claimed and acknowledged with its token and the
   service's pid. A registration rewritten with a new token, which is what a
   new session's bring-up does, refreshes the identity's session and settings
   and ends a lapse, without letting the pid file's lock go. A registration
   whose file has gone is released: pid file and heartbeat removed, the log
   left for its listener. One that cannot be read is raised as a fault offering
   quarantine, and the scan carries on with the others.

   WAL-PATH-FN and CURSORS-DIR-FN map a bus name to its log and its cursors
   directory. Faults are raised for the supervisor to heal; any other failure
   with one registration is reported and does not stop the rest."
  (let ((stems (hostfiles:registration-stems)))
    (dolist (stem stems)
      (handler-case
          (progn
            (%scan-one registry stem now report-fn wal-path-fn cursors-dir-fn)
            (%forget registry (list :kind :claim-failed :stem stem)))
        ((and error (not conditions:host-fault)) (e)
          (when (%note-once registry (list :kind :claim-failed :stem stem))
            (funcall report-fn :error "registration-failed" :subject stem
                     :msg (princ-to-string e))))))
    (let ((gone '()))
      (maphash (lambda (stem identity)
                 (declare (ignore identity))
                 (unless (member stem stems :test #'string=)
                   (push stem gone)))
               (registry-identities registry))
      (dolist (stem gone)
        (drop-identity registry stem :remove-registration nil))))
  registry)

(defun drop-identity (registry stem &key (remove-registration t))
  "Stop serving the identity under STEM: release its pid file and heartbeat,
   and with REMOVE-REGISTRATION remove its registration and acknowledgement as
   well. True when there was an identity to drop."
  (let ((identity (gethash stem (registry-identities registry))))
    (when identity
      (remhash stem (registry-identities registry))
      (ident:release-identity identity :remove-files t))
    (when remove-registration
      (hostfiles:remove-registration stem))
    (and identity t)))

;;; ------------------------------------------------------------------ sessions

(defun %parked-p (identity)
  "True while IDENTITY's park marker exists."
  (and (probe-file (hostfiles:watch-state-file (ident:identity-stem identity) "parked"))
       t))

(defun %session-alive-p (identity)
  "True while the session IDENTITY's registration names is running. A
   registration naming no session lives until it is removed. With a start time
   the pid has to be the same process that started then, since pids are reused."
  (let ((pid (ident:identity-session-pid identity))
        (start (ident:identity-session-start identity)))
    (cond ((null pid) t)
          (start (hostfiles:process-matches-p pid start))
          (t (%pid-alive-p pid)))))

(defun %end-parked (registry identity)
  "Raise PARKED-SESSION-GONE for IDENTITY, offering to deregister it."
  (let ((stem (ident:identity-stem identity)))
    (restart-case
        (conditions:raise-fault 'conditions:parked-session-gone
                                :bus (ident:identity-bus identity)
                                :id (ident:identity-id identity)
                                :subject stem
                                :detail "the session ended while parked")
      (conditions:deregister ()
        :report "Release the identity and remove its registration."
        (drop-identity registry stem)))))

(defun %lapse (identity report-fn)
  "Raise SESSION-GONE for IDENTITY, offering to lapse it."
  (restart-case
      (conditions:raise-fault 'conditions:session-gone
                              :bus (ident:identity-bus identity)
                              :id (ident:identity-id identity)
                              :subject (ident:identity-stem identity)
                              :detail "the session ended without parking")
    (conditions:lapse ()
      :report "Keep the identity's files and its alarm, and write no lines."
      (ident:lapse-identity identity)
      (funcall report-fn :warn "session-lapsed"
               :bus (ident:identity-bus identity)
               :id (ident:identity-id identity)
               :subject (ident:identity-stem identity)
               :msg (format nil "session ~A ended without parking; unread mail ~
                                 still raises the alarm"
                            (ident:identity-session-pid identity))))))

(defun check-sessions (registry now &key (report-fn #'%default-report))
  "Look at the session behind every identity in REGISTRY, at NOW (Unix
   seconds), and return REGISTRY.

   A session that has ended after parking takes its registration with it,
   quietly: pid file, heartbeat and registration go and the park marker stays,
   so mail waits at the cursor for the next bring-up. One that ended without
   parking lapses the identity, with a warning. A lapsed identity whose agent
   then parks is deregistered the same quiet way. Faults are raised for the
   supervisor to heal."
  (declare (ignore now))
  (let ((identities '()))
    (maphash (lambda (stem identity)
               (declare (ignore stem))
               (push identity identities))
             (registry-identities registry))
    (dolist (identity identities)
      (case (ident:identity-state identity)
        (:lapsed
         (when (%parked-p identity)
           (%end-parked registry identity)))
        (:serving
         (unless (%session-alive-p identity)
           (if (%parked-p identity)
               (%end-parked registry identity)
               (%lapse identity report-fn)))))))
  registry)

(defun settle-tick (registry identity result &key (report-fn #'%default-report))
  "Act on RESULT, what IDENTITY-TICK answered for IDENTITY. A lapsed identity
   whose agent has read past the mail that waited for it is :HEARD, and is
   deregistered: whoever read the mail is listening some other way. True when
   the identity was deregistered."
  (when (and (eq result :heard) (eq (ident:identity-state identity) :lapsed))
    (let ((stem (ident:identity-stem identity)))
      (when (eq identity (gethash stem (registry-identities registry)))
        (drop-identity registry stem)
        (funcall report-fn :info "lapse-ended"
                 :bus (ident:identity-bus identity)
                 :id (ident:identity-id identity)
                 :subject stem
                 :msg "the mail that waited was read; registration removed")
        t))))

;;; ------------------------------------------------- watchers started before it
;;;
;;; A host that already runs a detached watcher per agent has to be taken over
;;; one watcher at a time without any listener seeing a moment when nobody
;;; holds the agent's pid file: a probe reads that moment as a dead watcher and
;;; a waiting listener gives up. So the service queues for the pid file's lock
;;; before it ends the old watcher, and ends it with SIGKILL, which skips the
;;; watcher's own clean-up. The pid file and heartbeat stay where they are, the
;;; kernel hands the queued lock over as the old process dies, and the service
;;; carries on with the same files, the log's inode included, so a listener
;;; already following the log keeps its descriptor.

(defvar *open-nofollow*
  (let ((flag (find-symbol "O-NOFOLLOW" "SB-POSIX")))
    (if (and flag (boundp flag)) (symbol-value flag) 0))
  "O_NOFOLLOW where this SBCL provides it, else 0, so a pid file replaced by a
   symbolic link is refused rather than followed.")

(defun %legacy-command-p (args)
  "True when the argument vector ARGS is a detached watcher's: the binary is
   dsmr-bus-watch and it runs as the detached child."
  (and (member "--detached-child" args :test #'string=)
       (some (lambda (arg) (search "dsmr-bus-watch" arg)) args)
       t))

(defun %flag-value (args flag)
  "The value given to FLAG in the argument vector ARGS, the last one when it is
   given more than once, as the watcher's own parser takes it; NIL when absent."
  (let ((value nil))
    (loop for (arg next) on args
          when (string= arg flag)
            do (setf value next))
    value))

(defun %integer-flag (args flag)
  "FLAG's value in ARGS as a non-negative integer, or NIL."
  (let ((value (ignore-errors (parse-integer (or (%flag-value args flag) "")))))
    (and value (>= value 0) value)))

(defun %proc-locks ()
  "The lines of /proc/locks, or NIL where there is none."
  (ignore-errors (uiop:read-file-lines "/proc/locks")))

(defun %inode (path)
  "PATH's inode number, found without opening it, or NIL."
  (ignore-errors (sb-posix:stat-ino (sb-posix:stat (%native path)))))

(defun %lock-lines-on (ino lines)
  "The lines of LINES, from /proc/locks, that describe a POSIX lock on inode
   INO, each split into fields."
  (when ino
    (let ((suffix (format nil ":~D" ino)))
      (loop for line in lines
            for fields = (remove "" (uiop:split-string line :separator " ")
                                 :test #'string=)
            when (and (find "POSIX" fields :test #'string=)
                      (some (lambda (field) (uiop:string-suffix-p field suffix)) fields))
              collect fields))))

(defun %held-here-p (ino lines)
  "True when LINES from /proc/locks show this process holding a lock on inode
   INO. Asking who holds such a file by opening it would drop that lock."
  (let ((me (princ-to-string (sb-posix:getpid))))
    (some (lambda (fields)
            (and (not (find "->" fields :test #'string=))
                 (find me fields :test #'string=)))
          (%lock-lines-on ino lines))))

(defun %queued-here-p (ino)
  "True when /proc/locks shows this process waiting for a lock on inode INO."
  (let ((me (princ-to-string (sb-posix:getpid))))
    (some (lambda (fields)
            (and (find "->" fields :test #'string=)
                 (find me fields :test #'string=)))
          (%lock-lines-on ino (%proc-locks)))))

(defun find-legacy-watchers (&key (exclude-pids (list (sb-posix:getpid))) skip-stems)
  "The detached watchers running on this host's watch files, as a list of
   plists (:pid :start :pid-path :stem :id :bus :args).

   Only pid files in this process's own watch state directory are looked at,
   so a service, or a test, never reaches the watchers of another state home.
   A watcher counts only when it holds the lock on its pid file, and its
   command line shows the watcher binary running as a detached child. Holders
   in EXCLUDE-PIDS are passed over. Files under SKIP-STEMS, and any file this
   process holds a lock on, are never opened: asking who holds a lock from the
   process that holds it lets the lock go.

   ID is the identity the pid file records, or else the one on the command
   line; BUS is the command line's, NIL for the unnamed bus. STEM is the
   file's own, which is the older name-only stem for a watcher an earlier
   build started."
  (let ((locks (%proc-locks))
        (found '()))
    (dolist (path (ignore-errors (uiop:directory-files (hostfiles:watch-state-dir))))
      (let* ((name (file-namestring path))
             (stem (and (uiop:string-suffix-p name ".pid")
                        (subseq name 0 (- (length name) 4)))))
        (when (and stem (plusp (length stem))
                   (not (member stem skip-stems :test #'string=))
                   (not (%held-here-p (%inode path) locks)))
          (let ((holder (%lock-holder path)))
            (when (and holder (not (member holder exclude-pids)))
              (let ((args (hostfiles:proc-cmdline holder))
                    (start (hostfiles:proc-starttime holder)))
                (when (and start (%legacy-command-p args))
                  (let ((id (or (nth-value 1 (%pid-file-contents path))
                                (%flag-value args "--agent-id"))))
                    (when id
                      (push (list :pid holder :start start :pid-path path :stem stem
                                  :id (hostfiles:normalise-agent-id id)
                                  :bus (%flag-value args "--bus")
                                  :args args)
                            found))))))))))
    (nreverse found)))

(defun %legacy-registration (legacy now)
  "The registration the watcher LEGACY is adopted under: the one already on
   disk for its stem, or one written now from its command line. The written one
   names no session, so the agent is served until it is deregistered, as its
   watcher would have run until it was reaped. NIL while the registration on
   disk cannot be served; the registration scan deals with that file first."
  (let ((stem (getf legacy :stem))
        (args (getf legacy :args)))
    (multiple-value-bind (plist status)
        (hostfiles:read-registration (hostfiles:registration-path stem))
      (case status
        (:ok (and (null (%registration-problem stem plist)) plist))
        (:absent
         (hostfiles:write-registration
          stem
          (list :id (getf legacy :id)
                :bus (getf legacy :bus)
                :poll-ms (or (%integer-flag args "--poll-ms") 250)
                :recycle-seconds (or (%integer-flag args "--recycle-seconds") 600)
                :deaf-seconds (or (%integer-flag args "--deaf-seconds") 600)
                :session-pid nil
                :session-start nil
                :token (format nil "~(~16,'0X~)"
                               (random (expt 16 16) (make-random-state t)))
                :registered-at now
                :cli-version "adopted")))
        (t nil)))))

(defun %fd-lock-holder (fd)
  "The pid of the process holding a lock that would block a write lock through
   FD, or NIL. Asked through the descriptor already open, so no descriptor is
   opened or closed on the file."
  (let ((lock (%whole-file-lock sb-posix:f-wrlck)))
    (sb-posix:fcntl fd sb-posix:f-getlk lock)
    (unless (= (sb-posix:flock-type lock) sb-posix:f-unlck)
      (sb-posix:flock-pid lock))))

(defun %still-legacy-p (legacy)
  "True while LEGACY's pid is still the watcher process found: the same start
   time, and still the watcher binary running as a detached child. Checked
   before any signal, since a pid on its own may by now name anything."
  (let ((pid (getf legacy :pid)))
    (and (hostfiles:process-matches-p pid (getf legacy :start))
         (%legacy-command-p (hostfiles:proc-cmdline pid)))))

(defun %serve-adopted (registry stem identity)
  "Record IDENTITY as served under STEM and acknowledge its registration."
  (setf (gethash stem (registry-identities registry)) identity)
  (%acknowledge registry identity)
  identity)

(defun %adopt-by-queued-lock (registry legacy registration claim-keys grant-seconds
                              report-fn)
  "Take LEGACY's pid file over with no moment in which nobody holds its lock.
   Returns the identity, or :GONE, :CHANGED or :TIMEOUT when it was not taken.

   The pid file is opened once and that descriptor is the one that ends up
   holding the lock. A helper thread queues a blocking write lock on it; once
   the queued request shows, and the holder is checked once more to still be
   the watcher found, the watcher alone is sent SIGKILL. SIGKILL is the point:
   the watcher's clean-up would remove the pid file and heartbeat on the way
   out, and a probe looking in between would see no watcher at all. The lock
   passes to the queued request as the process dies, and the claim is
   finished on that descriptor."
  (let* ((stem (getf legacy :stem))
         (path (%native (getf legacy :pid-path)))
         (fd (handler-case (sb-posix:open path (logior sb-posix:o-rdwr *open-nofollow*))
               (sb-posix:syscall-error () nil))))
    (unless fd
      (return-from %adopt-by-queued-lock :gone))
    (unless (and (eql (ignore-errors (%fd-lock-holder fd)) (getf legacy :pid))
                 (%still-legacy-p legacy))
      (sb-posix:close fd)
      (return-from %adopt-by-queued-lock :changed))
    (let* ((ino (sb-posix:stat-ino (sb-posix:fstat fd)))
           (helper (sb-thread:make-thread
                    (lambda ()
                      (handler-case
                          (progn
                            (sb-posix:fcntl fd sb-posix:f-setlkw
                                            (%whole-file-lock sb-posix:f-wrlck))
                            :granted)
                        (error (e) e)))
                    :name (format nil "adopt ~A" stem))))
      (loop repeat 100
            until (%queued-here-p ino)
            do (sleep 0.01))
      (when (%still-legacy-p legacy)
        (ignore-errors (sb-posix:kill (getf legacy :pid) sb-posix:sigkill)))
      (let ((outcome (sb-thread:join-thread helper :timeout grant-seconds
                                                   :default :timeout)))
        (when (eq outcome :timeout)
          (ignore-errors (sb-thread:terminate-thread helper))
          (setf outcome (sb-thread:join-thread helper :timeout 2 :default :timeout)))
        (cond
          ((eq outcome :granted)
           (%serve-adopted registry stem
                           (apply #'ident:finish-claim fd registration claim-keys)))
          (t
           ;; A helper still blocked keeps its descriptor: closing it under a
           ;; request the kernel may yet grant would leave a lock nobody owns.
           (unless (sb-thread:thread-alive-p helper)
             (ignore-errors (sb-posix:close fd)))
           (funcall report-fn :warn "legacy-watcher-found"
                    :bus (getf legacy :bus) :id (getf legacy :id) :subject stem
                    :msg (format nil "the lock of watcher ~D was not handed over within ~D s; ~
                                      left for the next scan"
                                 (getf legacy :pid) grant-seconds))
           :timeout))))))

(defun %adopt-by-terminating (registry legacy registration claim-keys grant-seconds)
  "Take LEGACY over the naive way: ask it to stop, wait for it to go, then
   claim its files afresh. Its clean-up removes the pid file and heartbeat
   first, so for a moment no watcher shows at all. Kept only so a test can show
   that moment exists when the lock is not queued first; the service never
   adopts this way."
  (let ((pid (getf legacy :pid)))
    (when (%still-legacy-p legacy)
      (ignore-errors (sb-posix:kill pid sb-posix:sigterm)))
    (loop repeat (max 1 (ceiling (* 4 grant-seconds)))
          while (%pid-alive-p pid)
          do (sleep 0.25))
    (let ((identity (apply #'ident:claim-identity registration claim-keys)))
      (if identity
          (%serve-adopted registry (getf legacy :stem) identity)
          :timeout))))

(defun adopt-legacy-watcher (registry legacy now
                             &key (report-fn #'%default-report)
                                  (wal-path-fn #'default-wal-path)
                                  (cursors-dir-fn #'default-cursors-dir)
                                  (grant-seconds 5)
                                  (method :queued-lock))
  "Take over LEGACY, a watcher FIND-LEGACY-WATCHERS returned, at NOW (Unix
   seconds), and serve its agent from this process. Returns the identity, or a
   keyword saying why not: :LEFT, :SERVED, :DEFERRED, :GONE, :CHANGED or
   :TIMEOUT.

   The agent's registration is the one on disk, or one written from the
   watcher's command line when there is none. The pid file's lock is queued
   for before the watcher is ended, so no probe or listener ever finds the
   identity unwatched, and the log keeps its inode. A lock not handed over
   within GRANT-SECONDS is reported and the watcher left for the next scan.

   A watcher under the older name-only stem is reported once and left running:
   its agent moves over at its next bring-up. METHOD :TERMINATE-THEN-CLAIM is
   the naive takeover, there only to show what the queued lock prevents."
  (let* ((stem (getf legacy :stem))
         (id (getf legacy :id))
         (bus (getf legacy :bus)))
    (cond
      ((not (string= stem (hostfiles:detach-stem bus id)))
       (when (%note-once registry (list :kind :legacy-stem :stem stem
                                        :pid (getf legacy :pid)))
         (funcall report-fn :warn "legacy-stem-watcher" :bus bus :id id :subject stem
                  :msg (format nil "watcher ~D runs under the name-only stem ~A; ~
                                    left running until its agent's next bring-up"
                               (getf legacy :pid) stem)))
       :left)
      ((gethash stem (registry-identities registry)) :served)
      (t
       (let ((registration (%legacy-registration legacy now)))
         (if (null registration)
             :deferred
             (let ((claim-keys (list :service-pid (registry-service-pid registry)
                                     :now now
                                     :wal-path (funcall wal-path-fn bus)
                                     :cursors-dir (funcall cursors-dir-fn bus)
                                     :report-fn report-fn)))
               (push legacy (registry-adopting registry))
               (unwind-protect
                    (ecase method
                      (:queued-lock
                       (%adopt-by-queued-lock registry legacy registration claim-keys
                                              grant-seconds report-fn))
                      (:terminate-then-claim
                       (%adopt-by-terminating registry legacy registration claim-keys
                                              grant-seconds)))
                 (setf (registry-adopting registry)
                       (remove legacy (registry-adopting registry)))))))))))

(defun adopt-legacy-watchers (registry now &key (report-fn #'%default-report)
                                               (wal-path-fn #'default-wal-path)
                                               (cursors-dir-fn #'default-cursors-dir)
                                               (grant-seconds 5))
  "Find every detached watcher on this host's watch files and take each over,
   at NOW (Unix seconds). Each one found is raised as LEGACY-WATCHER-FOUND,
   offering adoption, so the supervisor decides and its breaker bounds how
   often. A watcher under a name-only stem is reported and left, without a
   fault. Returns the list of what each adoption answered."
  (let ((outcomes '()))
    (dolist (legacy (find-legacy-watchers
                     :exclude-pids (list (sb-posix:getpid) (registry-service-pid registry))
                     :skip-stems (loop for stem being the hash-keys
                                         of (registry-identities registry)
                                       collect stem)))
      (flet ((adopt ()
               (adopt-legacy-watcher registry legacy now
                                     :report-fn report-fn
                                     :wal-path-fn wal-path-fn
                                     :cursors-dir-fn cursors-dir-fn
                                     :grant-seconds grant-seconds)))
        (push (if (string= (getf legacy :stem)
                           (hostfiles:detach-stem (getf legacy :bus) (getf legacy :id)))
                  (restart-case
                      (conditions:raise-fault 'conditions:legacy-watcher-found
                                              :bus (getf legacy :bus)
                                              :id (getf legacy :id)
                                              :subject (getf legacy :stem)
                                              :detail (format nil "detached watcher ~D"
                                                              (getf legacy :pid)))
                    (conditions:adopt-legacy-watcher ()
                      :report "Queue for the watcher's lock, end it and serve its agent."
                      (adopt)))
                  (adopt))
              outcomes)))
    (nreverse outcomes)))

;;; -------------------------------------------------------------------- roster

(defun %enrolled-ids (roster-dir)
  "The normalised ids enrolled, and not departed, on the roster at ROSTER-DIR."
  (loop for entry in (roster:members roster-dir)
        when (eq (roster:entry-status entry) :enrolled)
          collect (hostfiles:normalise-agent-id (roster:entry-id entry))))

(defun %registered-ids (registry bus)
  "The normalised ids REGISTRY serves on BUS, lapsed ones included."
  (let ((ids '()))
    (maphash (lambda (stem identity)
               (declare (ignore stem))
               (when (equal (ident:identity-bus identity) bus)
                 (push (hostfiles:normalise-agent-id (ident:identity-id identity)) ids)))
             (registry-identities registry))
    ids))

(defun %bus-findings (registry bus roster-dir)
  "The findings for BUS, whose roster is at ROSTER-DIR."
  (let ((enrolled (%enrolled-ids roster-dir))
        (registered (%registered-ids registry bus)))
    (append
     (loop for id in (sort (remove-duplicates enrolled :test #'string=) #'string<)
           unless (member id registered :test #'string=)
             collect (list :kind :enrolled-unregistered :bus bus :id id))
     (loop for id in (sort (remove-duplicates registered :test #'string=) #'string<)
           unless (member id enrolled :test #'string=)
             collect (list :kind :registered-unenrolled :bus bus :id id)))))

(defun %finding-words (kind)
  (ecase kind
    (:enrolled-unregistered "enrolled on the roster with no registration")
    (:registered-unenrolled "registered with no enrollment on the roster")))

(defun %report-finding (finding)
  "Raise the ROSTER-GAP finding FINDING. It has no heal: the supervisor reports
   it and carries on."
  (conditions:raise-fault 'conditions:roster-gap
                          :bus (getf finding :bus)
                          :id (getf finding :id)
                          :subject (format nil "~(~A~) ~A"
                                           (getf finding :kind) (getf finding :id))
                          :detail (format nil "~A ~A" (getf finding :id)
                                          (%finding-words (getf finding :kind)))))

(defun roster-gap-findings (registry buses roster-dir-fn
                            &key (report-fn #'%default-report))
  "Compare the roster of each of BUSES, found through ROSTER-DIR-FN, with the
   identities REGISTRY serves on it, and return the findings, each a plist
   (:kind :bus :id) with kind :ENROLLED-UNREGISTERED or :REGISTERED-UNENROLLED.

   Each finding is raised once, as a ROSTER-GAP fault the supervisor reports at
   INFO, and a finding that has gone away is reported as recovered. A bus with
   no roster directory has stated no intent and gives no findings. A roster
   that cannot be read is reported once and passed over. Nothing here changes
   who is served, and the roster is only ever read."
  (let ((found '()))
    (dolist (bus buses)
      (let ((unreadable-key (list :kind :roster-unreadable :bus bus)))
        (handler-case
            (let ((dir (uiop:ensure-directory-pathname (funcall roster-dir-fn bus))))
              (when (uiop:directory-exists-p dir)
                (let ((findings (%bus-findings registry bus dir)))
                  (%forget registry unreadable-key)
                  (dolist (finding findings)
                    (when (%note-once registry finding)
                      (%report-finding finding)))
                  (let ((ended '()))
                    (maphash (lambda (key value)
                               (declare (ignore value))
                               (when (and (member (getf key :kind)
                                                  '(:enrolled-unregistered
                                                    :registered-unenrolled))
                                          (equal (getf key :bus) bus)
                                          (not (member key findings :test #'equal)))
                                 (push key ended)))
                             (registry-reported-findings registry))
                    (dolist (key ended)
                      (%forget registry key)
                      (funcall report-fn :info "roster-gap"
                               :bus bus :id (getf key :id)
                               :subject (format nil "~(~A~) ~A"
                                                (getf key :kind) (getf key :id))
                               :msg (format nil "recovered: ~A is no longer ~A"
                                            (getf key :id)
                                            (%finding-words (getf key :kind))))))
                  (setf found (append found findings)))))
          ((and error (not conditions:host-fault)) (e)
            (when (%note-once registry unreadable-key)
              (funcall report-fn :warn "roster-unreadable" :bus bus
                       :msg (format nil "the roster could not be read: ~A" e)))))))
    found))

;;; -------------------------------------------------------------------- status

(defun registry-snapshot (registry)
  "The registrations REGISTRY serves, for the service's status record: one
   plist (:id :bus :state :session-pid) for each, :STATE being :SERVING,
   :LAPSED or :ADOPTING, sorted by id."
  (let ((entries '()))
    (maphash (lambda (stem identity)
               (declare (ignore stem))
               (push (list :id (ident:identity-id identity)
                           :bus (ident:identity-bus identity)
                           :state (ident:identity-state identity)
                           :session-pid (ident:identity-session-pid identity))
                     entries))
             (registry-identities registry))
    (dolist (legacy (registry-adopting registry))
      (push (list :id (getf legacy :id) :bus (getf legacy :bus)
                  :state :adopting :session-pid nil)
            entries))
    (sort entries #'string< :key (lambda (entry) (or (getf entry :id) "")))))
