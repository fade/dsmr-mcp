;;;; tests/bus/host-service-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Zebra tests for the host service's supervisor, run in this process: one
;;;; tick against a clock the case chooses writes the status summary that
;;;; --host-status reads, an orderly stop lets everything go without rotating a
;;;; log or removing an agent's files, and the watchdog's progress rule.
;;;;
;;;; The state home is a fresh short directory under /tmp (a bus socket path has
;;;; to fit in 107 bytes), the fleet and service logs are installed there before
;;;; anything can report, and every service a case makes is stopped when it ends.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/bus/host-service-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-posix)
  (require :sb-bsd-sockets))

(defpackage #:dsmr-mcp/tests/bus/host-service-test
  (:use #:cl #:zebra)
  (:local-nicknames (#:service #:dsmr-bus-host/src/bus/host/main)
                    (#:fleetlog #:dsmr-bus-host/src/bus/host/fleetlog)
                    (#:hostfiles #:dsmr-mcp/src/bus/hostfiles)
                    (#:broker #:dsmr-mcp/src/bus/broker)
                    (#:wal #:dsmr-mcp/src/bus/wal))
  (:import-from #:dsmr-bus-watch/src/bus/watch
                #:%reap-notifiers
                #:%unix-time))

(in-package #:dsmr-mcp/tests/bus/host-service-test)

;;; ------------------------------------------------------------------ fixtures

(defparameter *ns* "/home/x/proj"
  "The namespace every fixture's agents live in.")

(defvar *services* '()
  "Services made during the current case, stopped when it ends.")

(defun short-temp-dir ()
  "A new empty directory directly under /tmp with a short name, so the sockets
   of a bus rooted inside it fit the unix-domain path limit."
  (loop for dir = (format nil "/tmp/h43sv-~36R~36R/" (sb-posix:getpid) (random 1000000))
        unless (probe-file dir)
          do (ensure-directories-exist dir)
             (return (pathname dir))))

(defun write-text (path text)
  "Replace PATH with TEXT."
  (ensure-directories-exist path)
  (with-open-file (out path :direction :output :if-exists :supersede
                            :if-does-not-exist :create)
    (write-string text out))
  path)

(defun call-with-host (thunk)
  "Call THUNK with XDG_STATE_HOME pointing at a fresh short directory, the fleet
   and service logs installed inside it, and stand-in notify-send and gdbus
   programs first on PATH. Afterwards every service is stopped without exiting
   and the directory is removed."
  (let* ((state (short-temp-dir))
         (stubs (merge-pathnames "stub/" state))
         (previous (uiop:getenv "XDG_STATE_HOME"))
         (previous-path (uiop:getenv "PATH"))
         (*services* '()))
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
           (funcall thunk state))
      (dolist (svc *services*)
        (ignore-errors (service:stop-service svc :mark-clean nil)))
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

(defmacro with-host ((state) &body body)
  "Run BODY inside CALL-WITH-HOST with STATE bound to the state home."
  `(call-with-host (lambda (,state) (declare (ignorable ,state)) ,@body)))

(defun id (agent)
  "The full id of AGENT in the fixtures' namespace."
  (format nil "~A/~A" *ns* agent))

(defun register (agent &key (bus nil) (token "t1"))
  "Leave a registration for AGENT on BUS, as --detach would, naming no session."
  (hostfiles:write-registration
   (hostfiles:detach-stem bus (id agent))
   (list :id (id agent) :bus bus :poll-ms 250 :recycle-seconds 600
         :deaf-seconds 600 :token token :registered-at (%unix-time)
         :cli-version "test")))

(defun new-service ()
  "A service run by this process, noted for clean-up."
  (let ((svc (service:make-service)))
    (push svc *services*)
    svc))

(defun read-status ()
  "The status summary and its read status."
  (hostfiles:read-plist-file (hostfiles:service-status-path) :max-bytes (* 1024 1024)))

(defun default-bus-paths ()
  (broker:make-bus-paths (broker:default-state-root nil)))

;;; --------------------------------------------------------------------- cases

(define-test one-tick-writes-the-status-the-probe-reads
  "One supervisor tick, at a time the case chooses, serves a registration and
   writes the status summary: the unnamed bus, the agent serving, and the time
   written taken from the clock the tick was handed, not the wall clock."
  (with-host (state)
    (register "alpha")
    (let* ((svc (new-service))
           (now (- (%unix-time) 3)))
      (service:supervisor-tick svc now)
      (multiple-value-bind (status read) (read-status)
        (is eq :ok read)
        (is = (sb-posix:getpid) (getf status :pid))
        (is = (+ now 2208988800) (getf status :written-at))
        (true (find nil (getf status :buses) :key (lambda (entry) (getf entry :bus)))
              "the unnamed bus is listed")
        (true (member (getf (find nil (getf status :buses)
                                  :key (lambda (entry) (getf entry :bus)))
                            :owner)
                      '(:host :none :client)))
        (let ((entry (find (id "alpha") (getf status :registrations)
                           :key (lambda (entry) (getf entry :id))
                           :test #'equal)))
          (true entry "the registration is listed")
          (is eq :serving (getf entry :state))
          (is eq nil (getf entry :bus)))
        ;; The unnamed bus's roster is empty, so the one registration is a
        ;; finding: registered, not enrolled. It is reported, and gates nothing.
        (is equal (list (list :kind :registered-unenrolled :bus nil :id (id "alpha")))
            (getf status :findings)))
      (true (probe-file (hostfiles:served-path (hostfiles:detach-stem nil (id "alpha"))))
            "the registration was acknowledged"))))

(define-test the-unnamed-bus-is-served-by-the-service
  "Within a few ticks the service's own broker holds the unnamed bus, and the
   status says the host owns it."
  (with-host (state)
    (let ((svc (new-service)))
      (true (loop repeat 40
                  do (service:supervisor-tick svc (%unix-time))
                     (when (eq :host
                               (getf (find nil (getf (read-status) :buses)
                                           :key (lambda (entry) (getf entry :bus)))
                                     :owner))
                       (return t))
                     (sleep 0.25))))))

(define-test an-orderly-stop-rotates-nothing-and-keeps-the-agent-s-files
  "The orderly stop lets the broker go without archiving although the service
   was the bus's only member, closes the agent's descriptors without removing
   its pid file or its registration, and leaves the clean-stop marker."
  (with-host (state)
    (register "alpha")
    (let* ((svc (new-service))
           (paths (default-bus-paths))
           (stem (hostfiles:detach-stem nil (id "alpha"))))
      (true (loop repeat 40
                  do (service:supervisor-tick svc (%unix-time))
                     (when (service:service-ready-p svc) (return t))
                     (sleep 0.25))
            "the service became ready")
      (let ((generation (wal:generation (broker:bus-paths-wal paths))))
        (service:stop-service svc :mark-clean t)
        (is equal '() (directory (merge-pathnames "bus.wal.archive-*"
                                                  (broker:bus-paths-root paths))))
        (is = generation (wal:generation (broker:bus-paths-wal paths))))
      (true (probe-file (hostfiles:clean-stop-path)))
      (true (probe-file (hostfiles:watch-state-file stem "pid")))
      (true (probe-file (hostfiles:registration-path stem)))
      ;; The membership and the role were let go: a fresh exclusive probe of the
      ;; membership lock succeeds.
      (let ((fd (dsmr-mcp/src/bus/election:open-lock (broker:bus-paths-members paths))))
        (unwind-protect
             (true (dsmr-mcp/src/bus/election:try-lock-exclusive fd))
          (dsmr-mcp/src/bus/election:close-lock fd))))))

(define-test a-thread-counts-as-progressing-only-while-its-count-moves
  "The watchdog's rule: a thread whose progress count has not moved for more
   than the window is stalled, and moving again makes it fresh."
  (let ((stamp (service:progress-step nil 5 100)))
    (is equal '(5 . 100) stamp)
    (setf stamp (service:progress-step stamp 5 105))
    (is equal '(5 . 100) stamp)
    (true (service:progress-fresh-p stamp 110))
    (false (service:progress-fresh-p stamp 111))
    (setf stamp (service:progress-step stamp 6 111))
    (true (service:progress-fresh-p stamp 111))))

(defun receive-one (sock)
  "One datagram from SOCK as a string, or NIL when none arrives within two
   seconds."
  (let ((buffer (make-array 64 :element-type '(unsigned-byte 8))))
    (loop repeat 20
          do (multiple-value-bind (got length)
                 (handler-case (sb-bsd-sockets:socket-receive sock buffer nil)
                   (sb-bsd-sockets:interrupted-error () nil))
               (when (and got length (plusp length))
                 (return (map 'string #'code-char (subseq buffer 0 length)))))
             (sleep 0.1))))

(define-test readiness-reaches-the-manager-s-socket-in-both-namespaces
  "The readiness message reaches a datagram socket named by path and one in
   the abstract namespace, named with a leading @. With no socket named,
   nothing is sent and nothing fails."
  (let* ((dir (short-temp-dir))
         (path (uiop:native-namestring (merge-pathnames "notify" dir)))
         (abstract (format nil "h43sv-notify-~D-~D" (sb-posix:getpid) (random 1000000)))
         (by-path (make-instance 'sb-bsd-sockets:local-socket :type :datagram))
         (by-name (make-instance 'sb-bsd-sockets:local-abstract-socket :type :datagram)))
    (unwind-protect
         (progn
           (sb-bsd-sockets:socket-bind by-path path)
           (sb-bsd-sockets:socket-bind by-name abstract)
           (setf (sb-bsd-sockets:non-blocking-mode by-path) t
                 (sb-bsd-sockets:non-blocking-mode by-name) t)
           (true (service:sd-notify "READY=1" :socket path))
           (is equal "READY=1" (receive-one by-path))
           (true (service:sd-notify "WATCHDOG=1" :socket (concatenate 'string "@" abstract)))
           (is equal "WATCHDOG=1" (receive-one by-name))
           (false (service:sd-notify "READY=1" :socket nil))
           (false (service:sd-notify "READY=1" :socket "")))
      (ignore-errors (sb-bsd-sockets:socket-close by-path))
      (ignore-errors (sb-bsd-sockets:socket-close by-name))
      (ignore-errors (uiop:delete-directory-tree dir :validate t
                                                     :if-does-not-exist :ignore)))))
