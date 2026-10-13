;;;; tests/bus/host-registry-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Zebra tests for the host service's registry: registrations taken and
;;;; acknowledged, renewed and released; unreadable ones set aside; sessions
;;;; followed until they end, quietly when parked and with the alarm kept when
;;;; not; and the gap between a bus roster and the registrations reported as a
;;;; finding that never stops anyone being served.
;;;;
;;;; Every file lives under a fresh temporary state home, the fleet and service
;;;; logs are installed there before anything can report, and every session is
;;;; a `sleep` this test started, so the only processes a case ends are its own.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/bus/host-registry-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/bus/host-registry-test
  (:use #:cl #:zebra)
  (:local-nicknames (#:registry #:dsmr-bus-host/src/bus/host/registry)
                    (#:ident #:dsmr-bus-host/src/bus/host/identity)
                    (#:fleetlog #:dsmr-bus-host/src/bus/host/fleetlog)
                    (#:conditions #:dsmr-bus-host/src/bus/host/conditions)
                    (#:hostfiles #:dsmr-mcp/src/bus/hostfiles)
                    (#:heartbeat #:dsmr-mcp/src/bus/heartbeat)
                    (#:envelope #:dsmr-mcp/src/bus/envelope)
                    (#:roster #:dsmr-mcp/src/bus/roster)
                    (#:wal #:dsmr-mcp/src/bus/wal))
  (:import-from #:dsmr-bus-watch/src/bus/watch
                #:default-wal-path
                #:default-cursors-dir
                #:%poll-forward
                #:%directory-entries
                #:%reap-notifiers
                #:%unix-time))

(in-package #:dsmr-mcp/tests/bus/host-registry-test)

;;; ------------------------------------------------------------------ fixtures

(defparameter *bus* "hr"
  "The bus every fixture registers on.")

(defparameter *ns* "/home/x/proj"
  "The namespace every fixture's agents live in.")

(defparameter *other* "/ns/other"
  "An agent in another project, the author of every foreign record.")

(defvar *registries* '()
  "Registries made during the current case, emptied when it ends.")

(defvar *sleepers* '()
  "Session stand-ins started during the current case, ended when it ends.")

(defvar *reports* '()
  "Reports COLLECT-REPORT has been handed, newest first, each as (level code
   msg).")

(defun fresh-temp-dir (prefix)
  "A new empty directory under the system temp directory."
  (let ((name (uiop:with-temporary-file (:pathname p :keep t :prefix prefix) p)))
    (ignore-errors (delete-file name))
    (let ((dir (uiop:ensure-directory-pathname name)))
      (ensure-directories-exist dir)
      dir)))

(defun write-text (path text)
  "Replace PATH with TEXT."
  (ensure-directories-exist path)
  (with-open-file (out path :direction :output :if-exists :supersede
                            :if-does-not-exist :create)
    (write-string text out))
  path)

(defun call-with-host (thunk)
  "Call THUNK with XDG_STATE_HOME pointing at a fresh directory, the fleet and
   service logs installed inside it, the bus's directories made, and stand-in
   notify-send and gdbus programs first on PATH. Afterwards every identity a
   registry took is let go, every session stand-in is ended, and the directory
   is removed."
  (let* ((state (fresh-temp-dir "dsmr-host-registry"))
         (stubs (merge-pathnames "stub/" state))
         (previous (uiop:getenv "XDG_STATE_HOME"))
         (previous-path (uiop:getenv "PATH"))
         (*registries* '())
         (*sleepers* '())
         (*reports* '()))
    (unwind-protect
         (progn
           (sb-posix:setenv "XDG_STATE_HOME" (namestring state) 1)
           (dolist (program '("notify-send" "gdbus"))
             (let ((script (merge-pathnames program stubs)))
               (write-text script
                           (format nil "#!/bin/sh~%echo \"$*\" >> '~A~A.calls'~%"
                                   (uiop:native-namestring stubs) program))
               (sb-posix:chmod (uiop:native-namestring script) #o755)))
           (sb-posix:setenv "PATH" (format nil "~A:~A" (uiop:native-namestring stubs)
                                           (or previous-path ""))
                            1)
           (fleetlog:install-fleet-log
            :path (hostfiles:fleet-log-path)
            :service-log-path (merge-pathnames "service.log" (hostfiles:host-dir)))
           (ensure-directories-exist (default-wal-path *bus*))
           (ensure-directories-exist (default-cursors-dir *bus*))
           (ensure-directories-exist (hostfiles:watch-state-dir))
           (hostfiles:ensure-host-dir)
           (funcall thunk))
      (dolist (reg *registries*)
        (loop for identity being the hash-values of (registry:registry-identities reg)
              do (ignore-errors (ident:release-identity identity :remove-files nil))))
      (dolist (process *sleepers*)
        (ignore-errors (sb-posix:kill (uiop:process-info-pid process) sb-posix:sigkill))
        (ignore-errors (uiop:wait-process process)))
      (loop repeat 30
            do (%reap-notifiers)
            until (null dsmr-bus-watch/src/bus/watch::*notify-processes*)
            do (sleep 0.1))
      (fleetlog:remove-fleet-log)
      (when previous-path (sb-posix:setenv "PATH" previous-path 1))
      (if previous
          (sb-posix:setenv "XDG_STATE_HOME" previous 1)
          (ignore-errors (sb-posix:unsetenv "XDG_STATE_HOME")))
      (ignore-errors (uiop:delete-directory-tree state :validate t
                                                       :if-does-not-exist :ignore)))))

(defmacro with-host (() &body body)
  "Run BODY inside CALL-WITH-HOST."
  `(call-with-host (lambda () ,@body)))

(defun id (agent)
  "The full id of AGENT in the fixtures' namespace."
  (format nil "~A/~A" *ns* agent))

(defun stem (agent &optional (bus *bus*))
  "The file stem of AGENT on BUS."
  (hostfiles:detach-stem bus (id agent)))

(defun watch-file (agent type)
  "AGENT's per-identity watch file of TYPE on the fixtures' bus."
  (hostfiles:watch-state-file (stem agent) type))

(defun beat-file (agent)
  "Where AGENT's heartbeat on the fixtures' bus lives."
  (heartbeat:beat-path (id agent) (heartbeat:default-watch-dir *bus*)))

(defun reg-file (agent)
  (hostfiles:registration-path (stem agent)))

(defun new-registry ()
  "A registry served by this process, noted for clean-up."
  (let ((reg (registry:make-registry :service-pid (sb-posix:getpid))))
    (push reg *registries*)
    reg))

(defun start-session ()
  "Start a `sleep` standing in for an agent session and return its pid and its
   start time."
  (let* ((process (uiop:launch-program (list "sleep" "600")
                                       :input nil :output nil :error-output nil))
         (pid (uiop:process-info-pid process)))
    (push process *sleepers*)
    (values pid (loop repeat 50
                      for start = (hostfiles:proc-starttime pid)
                      when start do (return start)
                      do (sleep 0.02)))))

(defun end-session (pid)
  "End the session stand-in PID and collect it, so it is not left a zombie
   that still answers to its pid and start time."
  (let ((process (find pid *sleepers* :key #'uiop:process-info-pid)))
    (sb-posix:kill pid sb-posix:sigkill)
    (uiop:wait-process process)))

(defun register (agent &key (token "t1") session-pid session-start (bus *bus*))
  "Leave a registration for AGENT on BUS, as --detach would."
  (hostfiles:write-registration
   (stem agent bus)
   (list :id (id agent) :bus bus :poll-ms 250 :recycle-seconds 600
         :deaf-seconds 600 :session-pid session-pid :session-start session-start
         :token token :registered-at (%unix-time) :cli-version "test")))

(defun collect-report (level code &key bus id subject msg)
  "A report function that keeps what it is handed in *REPORTS*."
  (declare (ignore bus id subject))
  (push (list level code msg) *reports*))

(defun reports (level code)
  "The reports at LEVEL under CODE so far."
  (remove-if-not (lambda (r) (and (eq level (first r)) (string= code (second r))))
                 *reports*))

(defun healing (thunk)
  "Call THUNK under the healing supervisor, collecting every report, with
   breakers of its own so one case's heals never spend another's."
  (conditions:call-with-healing thunk :report-fn #'collect-report
                                      :breakers (make-hash-table :test 'equal)))

(defun scan (reg &key (now (%unix-time)))
  "Scan the registrations into REG under the healing supervisor."
  (healing (lambda ()
             (registry:scan-registrations reg now :report-fn #'collect-report))))

(defun check (reg &key (now (%unix-time)))
  "Check REG's sessions under the healing supervisor."
  (healing (lambda ()
             (registry:check-sessions reg now :report-fn #'collect-report))))

(defun served (reg agent)
  "The identity REG serves for AGENT, or NIL."
  (gethash (stem agent) (registry:registry-identities reg)))

(defun locked-by-me-p (path)
  "True when /proc/locks shows this process holding a POSIX write lock on the
   file at PATH. Reading /proc/locks never touches PATH itself."
  (let ((ino (ignore-errors
              (sb-posix:stat-ino (sb-posix:stat (uiop:native-namestring path)))))
        (pid (princ-to-string (sb-posix:getpid))))
    (and ino
         (some (lambda (line)
                 (let ((fields (remove "" (uiop:split-string line :separator " ")
                                       :test #'string=)))
                   (and (>= (length fields) 6)
                        (string= "POSIX" (second fields))
                        (string= "WRITE" (fourth fields))
                        (string= pid (fifth fields))
                        (uiop:string-suffix-p (sixth fields) (format nil ":~D" ino)))))
               (uiop:read-file-lines "/proc/locks")))))

(defun open-count (target)
  "How many of this process's descriptors name the native path TARGET."
  (count-if (lambda (fd)
              (let ((link (ignore-errors
                           (sb-posix:readlink (format nil "/proc/self/fd/~A" fd)))))
                (and link (uiop:string-prefix-p target link))))
            (%directory-entries "/proc/self/fd")))

(defun ack (agent)
  "AGENT's served acknowledgement and its read status."
  (hostfiles:read-served-ack (stem agent)))

(defun roster-dir (bus)
  "Where the fixtures keep BUS's roster: beside the bus's own files."
  (merge-pathnames (format nil "roster-~A/" bus) (hostfiles:host-dir)))

(defun roster-state (bus)
  (merge-pathnames (format nil "roster-~A.state" bus) (hostfiles:host-dir)))

(defun findings (reg)
  "The roster findings for the fixtures' bus, under the healing supervisor."
  (let (found)
    (healing (lambda ()
               (setf found (registry:roster-gap-findings
                            reg (list *bus*) #'roster-dir
                            :report-fn #'collect-report))))
    found))

(defun finding-set (found)
  "FOUND as a sorted list of (kind agent-name) pairs, for comparison."
  (sort (mapcar (lambda (f)
                  (list (getf f :kind) (hostfiles:agent-name (getf f :id))))
                found)
        #'string< :key (lambda (pair) (format nil "~A ~A" (first pair) (second pair)))))

;;; -------------------------------------------------------------- registration

(define-test a-new-registration-is-claimed-and-acknowledged
  "The next scan after a registration lands claims the identity and writes an
   acknowledgement carrying the registration's token and the service's pid."
  (with-host ()
    (let ((reg (new-registry)))
      (multiple-value-bind (pid start) (start-session)
        (register "alpha" :session-pid pid :session-start start))
      (scan reg)
      (true (served reg "alpha"))
      (multiple-value-bind (plist status) (ack "alpha")
        (is eq :ok status)
        (is equal "t1" (getf plist :token))
        (is eql (sb-posix:getpid) (getf plist :pid)))
      (true (locked-by-me-p (watch-file "alpha" "pid")))
      (true (probe-file (beat-file "alpha"))))))

(define-test a-renewed-registration-refreshes-the-session-without-letting-the-lock-go
  "A new token from a new session updates what the identity knows of its
   session and is acknowledged, on the same descriptor and the same lock."
  (with-host ()
    (let ((reg (new-registry)))
      (multiple-value-bind (pid start) (start-session)
        (register "alpha" :session-pid pid :session-start start))
      (scan reg)
      (let* ((identity (served reg "alpha"))
             (fd (sb-sys:fd-stream-fd (ident:identity-pid-stream identity))))
        (multiple-value-bind (pid2 start2) (start-session)
          (register "alpha" :token "t2" :session-pid pid2 :session-start start2)
          (scan reg)
          (is eq identity (served reg "alpha") "the same identity is kept")
          (is equal "t2" (ident:identity-token identity))
          (is eql pid2 (ident:identity-session-pid identity))
          (is eql start2 (ident:identity-session-start identity))
          (is equal "t2" (getf (ack "alpha") :token))
          (is eql fd (sb-sys:fd-stream-fd (ident:identity-pid-stream identity)))
          (true (locked-by-me-p (watch-file "alpha" "pid")))
          (is = 1 (open-count (uiop:native-namestring
                               (truename (watch-file "alpha" "pid"))))))))))

(define-test a-deleted-registration-releases-the-identity
  "Removing the registration lets the identity go on the next scan: pid file
   and beat removed, the log kept for its listener."
  (with-host ()
    (let ((reg (new-registry)))
      (register "alpha")
      (scan reg)
      (true (served reg "alpha"))
      (delete-file (reg-file "alpha"))
      (scan reg)
      (false (served reg "alpha"))
      (false (probe-file (watch-file "alpha" "pid")))
      (false (probe-file (beat-file "alpha")))
      (true (probe-file (watch-file "alpha" "log"))))))

(define-test an-unreadable-registration-is-set-aside-and-the-scan-goes-on
  "A registration that will not read is renamed out of the way and reported
   once as an error; the other registrations are served regardless."
  (with-host ()
    (let ((reg (new-registry))
          (bad (reg-file "broken")))
      (write-text bad "#.(error \"planted\")")
      (register "alpha")
      (scan reg)
      (false (probe-file bad))
      (true (probe-file (uiop:parse-native-namestring
                         (concatenate 'string (uiop:native-namestring bad) ".bad")))
            "set aside as <stem>.reg.bad")
      (is = 1 (length (reports :error "unreadable-registration")))
      (true (served reg "alpha"))
      (false (served reg "broken"))
      (scan reg)
      (is = 1 (length (reports :error "unreadable-registration"))
          "reported once, not at every scan"))))

(define-test a-registration-under-another-identity-s-stem-is-set-aside
  "A registration filed under a stem that its own id does not give is not
   allowed to claim the files of the identity it names."
  (with-host ()
    (let ((reg (new-registry)))
      (hostfiles:write-registration
       (stem "decoy")
       (list :id (id "alpha") :bus *bus* :token "t1"))
      (scan reg)
      (false (served reg "decoy"))
      (false (served reg "alpha"))
      (false (probe-file (watch-file "alpha" "pid")))
      (is = 1 (length (reports :error "unreadable-registration"))))))

;;; ------------------------------------------------------------------ sessions

(define-test a-dead-session-lapses-its-identity
  "An unparked session that ends leaves its identity lapsed: the lock is kept,
   no line is written, the registration stays, and a warning says so."
  (with-host ()
    (let ((reg (new-registry)))
      (multiple-value-bind (pid start) (start-session)
        (register "alpha" :session-pid pid :session-start start)
        (scan reg)
        (check reg)
        (is eq :serving (ident:identity-state (served reg "alpha")))
        (end-session pid))
      (check reg)
      (let ((identity (served reg "alpha")))
        (true identity)
        (is eq :lapsed (ident:identity-state identity)))
      (is = 1 (length (reports :warn "session-lapsed")))
      (true (locked-by-me-p (watch-file "alpha" "pid")))
      (true (probe-file (reg-file "alpha")))
      (check reg)
      (is = 1 (length (reports :warn "session-lapsed")) "a lapse is reported once"))))

(define-test a-parked-session-ends-its-registration-quietly
  "A parked session that ends takes its registration with it and raises
   nothing: pid file, beat and registration go, the park marker stays."
  (with-host ()
    (let ((reg (new-registry)))
      (multiple-value-bind (pid start) (start-session)
        (register "alpha" :session-pid pid :session-start start)
        (scan reg)
        (write-text (watch-file "alpha" "parked") "")
        (end-session pid))
      (check reg)
      (false (served reg "alpha"))
      (false (probe-file (watch-file "alpha" "pid")))
      (false (probe-file (beat-file "alpha")))
      (false (probe-file (reg-file "alpha")))
      (true (probe-file (watch-file "alpha" "parked")))
      (true (reports :info "parked-session-ended"))
      (false (find-if (lambda (r) (member (first r) '(:warn :error))) *reports*)
             "nothing louder than INFO: ~S" *reports*))))

(define-test a-session-pid-with-another-start-time-counts-as-gone
  "A live process that only shares the session's pid is not the session."
  (with-host ()
    (let ((reg (new-registry)))
      (multiple-value-bind (pid start) (start-session)
        (register "alpha" :session-pid pid :session-start (1+ start)))
      (scan reg)
      (check reg)
      (is eq :lapsed (ident:identity-state (served reg "alpha"))))))

(define-test a-registration-with-no-session-never-lapses
  "With no session named the identity is served until it is deregistered."
  (with-host ()
    (let ((reg (new-registry)))
      (register "alpha")
      (scan reg)
      (check reg)
      (is eq :serving (ident:identity-state (served reg "alpha")))
      (false (find-if (lambda (r) (member (first r) '(:warn :error))) *reports*)
             "nothing louder than INFO: ~S" *reports*))))

(defun lapse-alpha (reg)
  "Register alpha with a session, serve it, end the session and check, so
   alpha is lapsed."
  (multiple-value-bind (pid start) (start-session)
    (register "alpha" :session-pid pid :session-start start)
    (scan reg)
    (end-session pid))
  (check reg)
  (served reg "alpha"))

(define-test a-lapsed-identity-is-deregistered-when-it-parks
  (with-host ()
    (let* ((reg (new-registry))
           (identity (lapse-alpha reg)))
      (is eq :lapsed (ident:identity-state identity))
      (write-text (watch-file "alpha" "parked") "")
      (check reg)
      (false (served reg "alpha"))
      (false (probe-file (reg-file "alpha")))
      (false (probe-file (watch-file "alpha" "pid")))
      (true (probe-file (watch-file "alpha" "parked"))))))

(define-test a-lapsed-identity-is-released-when-its-registration-goes
  (with-host ()
    (let ((reg (new-registry)))
      (lapse-alpha reg)
      (delete-file (reg-file "alpha"))
      (scan reg)
      (false (served reg "alpha"))
      (false (probe-file (watch-file "alpha" "pid"))))))

(define-test a-lapsed-identity-is-deregistered-once-its-mail-is-heard
  "Mail that waited while the session was gone, read at last, ends the lapse
   by deregistering the identity."
  (with-host ()
    (let* ((reg (new-registry))
           (identity (lapse-alpha reg))
           (wal (default-wal-path *bus*)))
      (wal:append-record wal 1 (envelope:wrap-envelope "c1" *other* "x"))
      (false (ident:identity-deliver identity
                                     (values (%poll-forward wal (wal:make-reader) 0))
                                     (%unix-time) :readers 0)
             "a lapsed identity writes no line")
      (true (ident:identity-pending-p identity))
      (write-text (merge-pathnames (envelope:encode-id (id "alpha"))
                                   (default-cursors-dir *bus*))
                  "1")
      (let ((result (ident:identity-tick identity (%unix-time) :readers 0
                                                               :report-fn #'collect-report)))
        (is eq :heard result)
        (true (registry:settle-tick reg identity result :report-fn #'collect-report)))
      (false (served reg "alpha"))
      (false (probe-file (reg-file "alpha")))
      (false (probe-file (watch-file "alpha" "pid"))))))

(define-test a-new-registration-ends-a-lapse
  "A session that comes back with a new token is served again."
  (with-host ()
    (let* ((reg (new-registry))
           (identity (lapse-alpha reg)))
      (multiple-value-bind (pid start) (start-session)
        (register "alpha" :token "t2" :session-pid pid :session-start start))
      (scan reg)
      (is eq identity (served reg "alpha"))
      (is eq :serving (ident:identity-state identity))
      (is equal "t2" (getf (ack "alpha") :token)))))

;;; -------------------------------------------------------------------- roster

(define-test roster-gaps-are-reported-once-and-recovered
  "Enrolled and unregistered, and registered and unenrolled, are each reported
   once; a gap that closes is reported as recovered."
  (with-host ()
    (let ((reg (new-registry))
          (dir (roster-dir *bus*))
          (state (roster-state *bus*)))
      (roster:enroll (id "aa") dir state)
      (roster:enroll (id "bb") dir state)
      (register "bb")
      (register "cc")
      (scan reg)
      (is equal '((:enrolled-unregistered "aa") (:registered-unenrolled "cc"))
          (finding-set (findings reg)))
      (is = 2 (length (reports :info "roster-gap")))
      (is equal '((:enrolled-unregistered "aa") (:registered-unenrolled "cc"))
          (finding-set (findings reg)))
      (is = 2 (length (reports :info "roster-gap")) "each finding reported once")
      (roster:enroll (id "cc") dir state)
      (is equal '((:enrolled-unregistered "aa")) (finding-set (findings reg)))
      (let ((recovered (remove-if-not (lambda (r) (search "recovered" (or (third r) "")))
                                      (reports :info "roster-gap"))))
        (is = 1 (length recovered))
        (true (search (id "cc") (third (first recovered)))))
      (is = 3 (length (reports :info "roster-gap"))))))

(define-test a-closed-roster-gates-nothing
  "An agent missing from a roster whose enrollment is closed is still claimed
   and served; the gap is only a finding."
  (with-host ()
    (let ((reg (new-registry))
          (dir (roster-dir *bus*))
          (state (roster-state *bus*)))
      (roster:enroll (id "aa") dir state)
      (roster:close-enrollment state)
      (register "aa")
      (register "cc")
      (scan reg)
      (true (served reg "cc"))
      (is equal "t1" (getf (ack "cc") :token))
      (is equal '((:registered-unenrolled "cc")) (finding-set (findings reg))))))

(define-test a-roster-that-cannot-be-read-is-reported-and-ignored
  (with-host ()
    (let ((reg (new-registry))
          found)
      (register "aa")
      (scan reg)
      (healing (lambda ()
                 (setf found (registry:roster-gap-findings
                              reg (list *bus*)
                              (lambda (bus) (declare (ignore bus)) (error "no roster here"))
                              :report-fn #'collect-report))))
      (false found)
      (true (served reg "aa"))
      (is = 1 (length (reports :warn "roster-unreadable"))))))
