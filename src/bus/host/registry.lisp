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
