;;;; tests/integration/bus/host-stub.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; A stand-in for the host bus service, for the watcher's cross-process tests.
;;;;
;;;; The watcher's --detach, --reap and --host-status act on what the host
;;;; service leaves on disk: its pid file, its beat, the acknowledgement of a
;;;; registration and the pid-file lock it holds for every identity it serves.
;;;; Those are properties of another process, so a case needs another process
;;;; that keeps them up. This one does that and nothing else: it watches no bus.
;;;;
;;;; It is a script, not a test leaf, and no system loads it. A case starts it as
;;;;
;;;;   sbcl --script host-stub.lisp dsmr-bus-host-stub <dsmr-mcp.asd> [ROLE]
;;;;
;;;; with XDG_STATE_HOME pointing at the case's private state root. The second
;;;; argument puts dsmr-bus-host on its command line, which is how the watcher
;;;; recognises the service. ROLE is one of:
;;;;
;;;;   (none)         one process: beats, acknowledges every registration, and
;;;;                  holds the pid-file lock of each registered identity.
;;;;   lock-in-child  as above, except a child in this process's own process
;;;;                  group holds the locks, so a case can show that no process
;;;;                  in the service's group is ever signalled.
;;;;   holder         the child of lock-in-child. It only holds locks, and exits
;;;;                  when its parent goes.
;;;;
;;;; A lock is held on one descriptor that stays open, and the pid and identity
;;;; are written through that same descriptor, because closing any descriptor
;;;; on a file drops this process's locks on it. When a registration disappears
;;;; the lock is released and the pid file removed. SIGTERM ends the process.

(require :asdf)
(require :sb-posix)

(asdf:load-asd (pathname (third sb-ext:*posix-argv*)))
(asdf:load-system "dsmr-mcp/src/bus/hostfiles")

(defpackage #:dsmr-bus-host-stub
  (:use #:cl)
  (:local-nicknames (#:hostfiles #:dsmr-mcp/src/bus/hostfiles)))

(in-package #:dsmr-bus-host-stub)

(defvar *held* (make-hash-table :test 'equal)
  "Stem to the open stream whose descriptor holds that identity's lock.")

(defvar *acked* (make-hash-table :test 'equal)
  "Stem to the registration token last acknowledged.")

(defun touch (path)
  "Rewrite PATH so its modification time is now."
  (with-open-file (out path :direction :output :if-exists :supersede
                            :if-does-not-exist :create)
    (write-line "beat" out)))

(defun claim (stem id)
  "Take the lock on STEM's pid file and record this pid and ID in it. True on
   success."
  (let* ((path (hostfiles:watch-state-file stem "pid"))
         (fd (progn (ensure-directories-exist path)
                    (sb-posix:open (uiop:native-namestring path)
                                   (logior sb-posix:o-creat sb-posix:o-rdwr)
                                   #o644))))
    (handler-case
        (progn
          (sb-posix:fcntl fd sb-posix:f-setlk
                          (make-instance 'sb-posix:flock
                                         :type sb-posix:f-wrlck
                                         :whence sb-posix:seek-set
                                         :start 0 :len 0))
          (sb-posix:ftruncate fd 0)
          (let ((stream (sb-sys:make-fd-stream fd :input t :output t
                                                  :external-format :utf-8
                                                  :buffering :full)))
            (format stream "~D~%~A~%" (sb-posix:getpid) id)
            (finish-output stream)
            (setf (gethash stem *held*) stream))
          t)
      (error ()
        (ignore-errors (sb-posix:close fd))
        nil))))

(defun release (stem)
  "Remove STEM's pid file and drop its lock."
  (let ((stream (gethash stem *held*)))
    (ignore-errors (delete-file (hostfiles:watch-state-file stem "pid")))
    (ignore-errors (close stream))
    (remhash stem *held*)))

(defun registrations ()
  "Every readable registration, as a list of (STEM . PLIST)."
  (loop for stem in (hostfiles:registration-stems)
        for (plist status) = (multiple-value-list
                              (hostfiles:read-registration
                               (hostfiles:registration-path stem)))
        when (eq status :ok)
          collect (cons stem plist)))

(defun hold-locks (current)
  "Hold the lock of every registration in CURRENT and release the rest."
  (loop for stem being the hash-keys of *held*
        unless (assoc stem current :test #'equal)
          collect stem into gone
        finally (mapc #'release gone))
  (loop for (stem . plist) in current
        unless (gethash stem *held*)
          do (claim stem (getf plist :id))))

(defun acknowledge (current)
  "Acknowledge every registration in CURRENT whose token has not been."
  (loop for (stem . plist) in current
        for token = (getf plist :token)
        unless (equal token (gethash stem *acked*))
          do (hostfiles:write-served-ack stem token (sb-posix:getpid))
             (setf (gethash stem *acked*) token)))

(defun hold-until-orphaned ()
  "The holder's loop: hold locks until the parent is gone."
  (let ((parent (sb-posix:getppid)))
    (loop while (= parent (sb-posix:getppid))
          do (hold-locks (registrations))
             (sleep 0.2))))

(defun serve (claim-p)
  "The service's loop: beat, acknowledge, and with CLAIM-P hold the locks."
  (hostfiles:ensure-host-dir)
  (with-open-file (out (hostfiles:service-pid-path) :direction :output
                                                    :if-exists :supersede)
    (format out "~D~%" (sb-posix:getpid)))
  (hostfiles:write-plist-file (hostfiles:service-state-path)
                              (list :pid (sb-posix:getpid)
                                    :started-at (get-universal-time)
                                    :stand-in t))
  (loop
    (touch (hostfiles:service-beat-path))
    (let ((current (registrations)))
      (when claim-p (hold-locks current))
      (acknowledge current))
    (sleep 0.2)))

(let ((role (fourth sb-ext:*posix-argv*))
      (self (uiop:native-namestring sb-ext:*runtime-pathname*))
      (script (uiop:native-namestring *load-truename*)))
  (cond
    ((equal role "holder")
     (hold-until-orphaned))
    ((equal role "lock-in-child")
     ;; Inherited stdin keeps the child in this process's group: given a
     ;; redirected one, run-program would put it in a group of its own.
     (sb-ext:run-program self
                         (list "--script" script "dsmr-bus-host-stub"
                               (third sb-ext:*posix-argv*) "holder")
                         :input t :output nil :error nil :wait nil)
     (serve nil))
    (t
     (serve t))))
