;;;; tests/integration/bus/host-support.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; What every cross-process test of the host bus service shares: a private
;;;; state root with stub desktop notifiers, a way to run the watcher and the
;;;; service binaries under it, the stand-in service, and the small probes the
;;;; cases assert with.
;;;;
;;;; Every case gets its own state root directly under /tmp. The default state
;;;; directory holds the pid files, logs and registrations of the agents this
;;;; machine is actually listening through, and a reap or a registration aimed
;;;; at the wrong one would leave a live agent deaf. Nothing here reads or
;;;; writes it.
;;;;
;;;; Only processes a case started are ever signalled: the stand-in service and
;;;; sleepers through STOP-PROCESS, and on the way out of WITH-HOST-STATE the
;;;; watchers whose pid files sit in that case's own root and whose environment
;;;; names that root.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/integration/bus/host-support)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-posix))

(defpackage #:dsmr-mcp/tests/integration/bus/host-support
  (:use #:cl)
  (:local-nicknames (#:hostfiles #:dsmr-mcp/src/bus/hostfiles)
                    (#:wal #:dsmr-mcp/src/bus/wal)
                    (#:envelope #:dsmr-mcp/src/bus/envelope)
                    (#:broker #:dsmr-mcp/src/bus/broker))
  (:import-from #:dsmr-bus-watch/src/bus/watch
                #:default-wal-path
                #:default-cursors-dir
                #:%lock-holder)
  (:export #:watcher-binary
           #:host-binary
           #:stub-dir
           #:install-notify-stub
           #:install-gdbus-stub
           #:notify-calls
           #:gdbus-calls
           #:watcher-env
           #:fresh-state-home
           #:run-in
           #:run-in-env
           #:identity-args
           #:full-id
           #:stem
           #:detach-file
           #:field
           #:alive-p
           #:await-exit
           #:await-true
           #:start-stub-service
           #:start-sleeper
           #:stop-process
           #:sample-check-live
           #:with-host-state
           #:with-state-home
           #:*started-pids*
           #:start-service
           #:kill-service
           #:launch-wake
           #:finish-wake
           #:publish
           #:publish-batch
           #:write-cursor
           #:lock-holder
           #:processes-under-state
           #:start-publisher
           #:publisher-lines
           #:start-foreign-broker))

(in-package #:dsmr-mcp/tests/integration/bus/host-support)

;;; binaries -------------------------------------------------------------------

(defun %repo-file (relative)
  "RELATIVE under the dsmr-mcp checkout, or NIL when no such file exists."
  (let ((p (merge-pathnames relative (asdf:system-source-directory "dsmr-mcp"))))
    (when (probe-file p) p)))

(defun watcher-binary ()
  "The built watcher binary, or NIL if it has not been built."
  (%repo-file "bin/dsmr-bus-watch"))

(defun host-binary ()
  "The built host service binary, or NIL if it has not been built."
  (%repo-file "bin/dsmr-bus-host"))

;;; state root and stubs -------------------------------------------------------

(defun stub-dir (state)
  "The directory under the state root STATE holding the stub notifiers."
  (merge-pathnames "stub-bin/" state))

(defun %install-stub (state name calls-file exit-code body)
  "Write the stub NAME into STATE's stub directory: a shell script whose BODY is
   a format control taking the calls file twice, ending in EXIT-CODE."
  (let ((stub (merge-pathnames name (stub-dir state)))
        (calls (uiop:native-namestring calls-file)))
    (ensure-directories-exist stub)
    (with-open-file (out stub :direction :output :if-exists :supersede)
      (format out "#!/bin/sh~%")
      (format out body calls calls)
      (format out "exit ~D~%" exit-code))
    (sb-posix:chmod (uiop:native-namestring stub) #o755)
    stub))

(defun install-notify-stub (state &key (exit-code 0))
  "A stub notify-send under STATE that records each call, one line per call, so
   no case can put a real notification on the developer's desktop."
  (%install-stub state "notify-send" (merge-pathnames "notify-calls" state)
                 exit-code "printf '%s\\n' \"$*\" >> '~A'~*~%"))

(defun install-gdbus-stub (state &key (exit-code 0))
  "A stub gdbus under STATE that records each call's arguments, each in square
   brackets, one line per call."
  (%install-stub state "gdbus" (merge-pathnames "gdbus-calls" state)
                 exit-code
                 "for arg in \"$@\"; do printf '[%s]' \"$arg\"; done >> '~A'~%printf '\\n' >> '~A'~%"))

(defun notify-calls (state)
  "Every call the stub notify-send under STATE has received."
  (or (ignore-errors (uiop:read-file-lines (merge-pathnames "notify-calls" state)))
      '()))

(defun gdbus-calls (state)
  "Every call the stub gdbus under STATE has received."
  (or (ignore-errors (uiop:read-file-lines (merge-pathnames "gdbus-calls" state)))
      '()))

(defun watcher-env (state &optional extra)
  "The environment assignments a process under STATE runs with: the private
   state root, a PATH that finds the stub notifiers first, and the assignments
   in EXTRA."
  (append (list (format nil "XDG_STATE_HOME=~A" (uiop:native-namestring state))
                (format nil "PATH=~A:~A"
                        (string-right-trim "/" (uiop:native-namestring
                                                (stub-dir state)))
                        (or (uiop:getenv "PATH") "")))
          extra))

(defun fresh-state-home ()
  "A new, empty state root directly under /tmp, holding the stub notifiers.
   Kept short on purpose: the bus refuses a state root whose derived socket
   path would pass 107 characters."
  (let* ((suffix (let ((*random-state* (make-random-state t)))
                   (format nil "~(~36R~)" (random (expt 36 8)))))
         (dir (pathname (format nil "/tmp/dbw-~A/" suffix))))
    (ensure-directories-exist dir)
    (install-notify-stub dir)
    (install-gdbus-stub dir)
    dir))

;;; running --------------------------------------------------------------------

(defun run-in-env (state extra bin &rest args)
  "Run BIN with ARGS under the state root STATE with no ambient bus identity,
   bus selector or agent session, plus the assignments in EXTRA, and return
   (values stdout stderr exit-code)."
  (uiop:run-program (append (list "env" "-u" "DSMR_BUS_AGENT"
                                  "-u" "DSMR_BUS_SELECTOR" "-u" "CLAUDE_PID")
                            (watcher-env state extra)
                            (list (uiop:native-namestring bin))
                            args)
                    :output '(:string :stripped t)
                    :error-output '(:string :stripped t)
                    :ignore-error-status t))

(defun run-in (state bin &rest args)
  "RUN-IN-ENV with nothing extra."
  (apply #'run-in-env state '() bin args))

(defun full-id (namespace agent)
  "The full bus id of AGENT under NAMESPACE, joined with one separator."
  (format nil "~A/~A" (string-right-trim "/" namespace) agent))

(defun identity-args (bus namespace agent)
  "The watcher flags naming AGENT under NAMESPACE on BUS."
  (list "--bus" bus "--agent" agent "--namespace" namespace))

(defun stem (bus namespace agent)
  "The file stem the watcher and the service use for AGENT under NAMESPACE on
   BUS, from the shared leaf they both name it through."
  (hostfiles:detach-stem bus (full-id namespace agent)))

(defun detach-file (state bus namespace agent type)
  "The per-identity watch file of TYPE for AGENT under NAMESPACE on BUS, under
   the state root STATE."
  (merge-pathnames (format nil "dsmr-mcp/watch/~A.~A" (stem bus namespace agent)
                           type)
                   state))

;;; probes ---------------------------------------------------------------------

(defun field (key line)
  "The value of KEY=... in LINE, or NIL."
  (let ((start (search (concatenate 'string key "=") line)))
    (when start
      (let* ((from (+ start (length key) 1))
             (end (or (position #\Space line :start from) (length line))))
        (subseq line from end)))))

(defun alive-p (pid)
  "True when PID names a process that exists and is not a zombie."
  (and (integerp pid)
       (handler-case (progn (sb-posix:kill pid 0) t)
         (sb-posix:syscall-error () nil))
       (let ((stat (ignore-errors
                    (uiop:read-file-string (format nil "/proc/~D/stat" pid)))))
         (not (and stat
                   (let ((close (position #\) stat :from-end t)))
                     (and close (char= (char stat (+ close 2)) #\Z))))))))

(defun await-exit (process seconds)
  "Wait up to SECONDS for PROCESS to exit. Returns its exit code, or NIL when it
   is still running."
  (loop repeat (* 10 seconds)
        while (uiop:process-alive-p process)
        do (sleep 0.1))
  (unless (uiop:process-alive-p process)
    (uiop:wait-process process)))

(defun await-true (thunk seconds)
  "Call THUNK every tenth of a second until it answers true or SECONDS pass, and
   return its last answer."
  (loop repeat (max 1 (round (* 10 seconds)))
        for answer = (funcall thunk)
        when answer do (return answer)
        do (sleep 0.1)
        finally (return (funcall thunk))))

;;; processes a case starts ----------------------------------------------------

(defmacro with-state-home ((state) &body body)
  "Run BODY with XDG_STATE_HOME naming STATE in this process, so the shared
   leaf's functions read and write the files the case's processes use, and put
   the previous value back on the way out."
  (let ((saved (gensym "SAVED")))
    `(let ((,saved (uiop:getenv "XDG_STATE_HOME")))
       (unwind-protect
            (progn (setf (uiop:getenv "XDG_STATE_HOME")
                         (uiop:native-namestring ,state))
                   ,@body)
         (setf (uiop:getenv "XDG_STATE_HOME") (or ,saved ""))))))

(defvar *started-pids* '()
  "The pids the current case started, stopped on the way out of
   WITH-HOST-STATE.")

(defvar *started-processes* '()
  "The process objects behind *STARTED-PIDS*, waited for so none is left a
   zombie.")

(defun %note-started (process)
  (push process *started-processes*)
  (push (uiop:process-info-pid process) *started-pids*)
  (uiop:process-info-pid process))

(defun start-sleeper (&optional (seconds 600))
  "Start a `sleep` standing in for an agent session and return its pid."
  (%note-started (uiop:launch-program (list "sleep" (princ-to-string seconds))
                                      :input nil :output nil :error-output nil)))

(defun start-stub-service (state &key role hold-members (seconds 60))
  "Start the stand-in host service under STATE, in ROLE (NIL or
   \"lock-in-child\"), wait up to SECONDS for it to beat, and return its pid. It
   leads its own process group. Its output goes to stub.log under STATE.

   HOLD-MEMBERS, a bus root, makes the stand-in hold that bus's membership lock
   from before its first beat and take over the broker of every degraded bus
   whose broker lock comes free, as the service does (see host-stub.lisp). It
   cannot be combined with ROLE."
  (let* ((script (%repo-file "tests/integration/bus/host-stub.lisp"))
         (asd (asdf:system-source-file "dsmr-mcp"))
         (log (with-open-file (out (merge-pathnames "stub.log" state)
                                   :direction :output :if-exists :append
                                   :if-does-not-exist :create)
                (pathname out)))
         (process (uiop:launch-program
                   (append (list "env")
                           (watcher-env state)
                           (list (uiop:native-namestring sb-ext:*runtime-pathname*)
                                 "--script" (uiop:native-namestring script)
                                 "dsmr-bus-host-stub"
                                 (uiop:native-namestring asd))
                           (and role (list role))
                           (and hold-members
                                (list "--hold-members"
                                      (uiop:native-namestring hold-members))))
                   :input nil
                   :output (uiop:native-namestring log)
                   :if-output-exists :append
                   :error-output :output))
         (pid (%note-started process)))
    (unless (await-true (lambda ()
                          (with-state-home (state)
                            (and (eql (hostfiles:read-service-pid) pid)
                                 (hostfiles:service-alive-p))))
                        seconds)
      (error "the stand-in service (pid ~D) did not beat within ~Ds; see ~A"
             pid seconds (merge-pathnames "stub.log" state)))
    pid))

(defun stop-process (pid &key (grace-seconds 5))
  "Stop PID, a process this case started: its whole group when it leads one,
   SIGTERM first and SIGKILL after GRACE-SECONDS. True when it is gone."
  (when (alive-p pid)
    (let* ((group-p (eql (ignore-errors (sb-posix:getpgid pid)) pid))
           (target (if group-p (- pid) pid)))
      (ignore-errors (sb-posix:kill target sb-posix:sigterm))
      (unless (await-true (lambda () (not (alive-p pid))) grace-seconds)
        (ignore-errors (sb-posix:kill target sb-posix:sigkill))
        (await-true (lambda () (not (alive-p pid))) 2))))
  (let ((process (find pid *started-processes* :key #'uiop:process-info-pid)))
    (when (and process (not (uiop:process-alive-p process)))
      (ignore-errors (uiop:wait-process process))))
  (not (alive-p pid)))

(defun %watcher-of-state-p (pid state)
  "True when PID is a watcher binary running under the state root STATE, so it
   was started by the case that owns STATE."
  (let ((cmdline (ignore-errors
                  (uiop:read-file-string (format nil "/proc/~D/cmdline" pid))))
        (environ (ignore-errors
                  (uiop:read-file-string (format nil "/proc/~D/environ" pid)))))
    (and cmdline environ
         (search "dsmr-bus-watch" cmdline)
         (search (format nil "XDG_STATE_HOME=~A" (uiop:native-namestring state))
                 environ)
         t)))

(defun %stop-watchers-of (state)
  "Stop every watcher whose pid file sits under STATE and which runs under it."
  (dolist (file (ignore-errors
                 (uiop:directory-files (merge-pathnames "dsmr-mcp/watch/" state))))
    (when (equal (pathname-type file) "pid")
      (let ((pid (ignore-errors
                  (parse-integer (first (uiop:read-file-lines file))
                                 :junk-allowed t))))
        (when (and pid (alive-p pid) (%watcher-of-state-p pid state))
          (stop-process pid))))))

(defmacro with-host-state ((state) &body body)
  "Run BODY with STATE bound to a fresh private state root. On the way out stop
   every process the case started and every watcher running under the root,
   then remove it."
  `(let ((,state (fresh-state-home))
         (*started-pids* '())
         (*started-processes* '()))
     (unwind-protect (progn ,@body)
       (dolist (pid *started-pids*) (ignore-errors (stop-process pid)))
       (ignore-errors (%stop-watchers-of ,state))
       (ignore-errors (uiop:delete-directory-tree ,state :validate t)))))

(defun sample-check-live (state id-args hz seconds)
  "Run `--check-live` with ID-ARGS under STATE HZ times a second for SECONDS,
   and return the status word of every answer, in order."
  (let ((bin (watcher-binary))
        (interval (/ 1.0 hz))
        (deadline (+ (get-internal-real-time)
                     (* seconds internal-time-units-per-second))))
    (loop while (< (get-internal-real-time) deadline)
          collect (let ((out (apply #'run-in state bin "--check-live" id-args)))
                    (subseq out 0 (or (position #\Space out) (length out))))
          do (sleep interval))))

;;; the real service ------------------------------------------------------------

(defun start-service (state &key (seconds 10))
  "Start the built host service under STATE, with no systemd notification
   socket and no ambient bus identity or agent session, its output appended to
   service.out under STATE. Wait up to SECONDS for it to record its pid and
   write a beat of its own, and return its pid. It leads its own process group
   and is stopped with the case."
  (let* ((launched (get-universal-time))
         (out (with-open-file (stream (merge-pathnames "service.out" state)
                                      :direction :output :if-exists :append
                                      :if-does-not-exist :create)
                (pathname stream)))
         (process (uiop:launch-program
                   (append (list "env" "-u" "NOTIFY_SOCKET" "-u" "DSMR_BUS_AGENT"
                                 "-u" "DSMR_BUS_SELECTOR" "-u" "CLAUDE_PID")
                           (watcher-env state)
                           (list (uiop:native-namestring (host-binary))))
                   :input nil
                   :output (uiop:native-namestring out)
                   :if-output-exists :append
                   :error-output :output))
         (pid (%note-started process)))
    (unless (await-true
             (lambda ()
               (with-state-home (state)
                 (and (eql (hostfiles:read-service-pid) pid)
                      (hostfiles:service-alive-p)
                      (let ((beat (ignore-errors
                                   (file-write-date (hostfiles:service-beat-path)))))
                        (and beat (>= beat launched))))))
             seconds)
      (error "the host service (pid ~D) did not beat within ~Ds; see ~A"
             pid seconds out))
    pid))

(defun kill-service (state signal &key (seconds 5))
  "Send SIGNAL to the host service recorded under STATE, wait up to SECONDS for
   it to exit, and return its exit status, or NIL while it is still running.
   The recorded pid must be a process this case started; anything else is an
   error and is never signalled."
  (let* ((pid (with-state-home (state) (hostfiles:read-service-pid)))
         (process (and pid (find pid *started-processes*
                                 :key #'uiop:process-info-pid))))
    (unless process
      (error "the service pid ~A recorded under ~A was not started by this case"
             pid state))
    (sb-posix:kill pid signal)
    (await-exit process seconds)))

(defun launch-wake (state args &key hook-input)
  "Start the watcher binary with ARGS under STATE as RUN-IN would, without
   waiting, and return the process. HOOK-INPUT, a string, is written to its
   standard input, which is then closed, as the harness hands a Stop hook its
   event. STDOUT and STDERR are kept apart for FINISH-WAKE."
  (let ((process (uiop:launch-program
                  (append (list "env" "-u" "DSMR_BUS_AGENT" "-u" "DSMR_BUS_SELECTOR"
                                "-u" "CLAUDE_PID")
                          (watcher-env state)
                          (list (uiop:native-namestring (watcher-binary)))
                          args)
                  :input :stream :output :stream :error-output :stream)))
    (%note-started process)
    (let ((in (uiop:process-info-input process)))
      (ignore-errors
       (when hook-input
         (write-string hook-input in)
         (finish-output in)))
      (ignore-errors (close in)))
    process))

(defun finish-wake (process seconds)
  "Wait up to SECONDS for PROCESS, started by LAUNCH-WAKE, to exit, then return
   (values exit-code stdout stderr), both outputs whole and trimmed. The exit
   code is NIL when it was still running and had to be stopped."
  (let ((code (await-exit process seconds)))
    (unless code
      (stop-process (uiop:process-info-pid process))
      (ignore-errors (uiop:wait-process process)))
    (flet ((slurp (stream)
             (string-trim '(#\Newline #\Space)
                          (or (ignore-errors (uiop:slurp-stream-string stream)) ""))))
      (values code
              (slurp (uiop:process-info-output process))
              (slurp (uiop:process-info-error-output process))))))

(defun publish-batch (state bus specs)
  "Append one record per spec in SPECS to BUS's log under STATE, numbered on
   from the log's head, in a single write so every reader finds them in one
   batch, and return the highest seq written. Each spec is (FROM-ID &key TO
   TEXT): the record is wrapped as FROM-ID publishing TEXT, addressed to TO when
   given, exactly as the bus client wraps it."
  (with-state-home (state)
    (let* ((wal-path (default-wal-path bus))
           (head (or (ignore-errors (values (wal:scan wal-path))) 0))
           (bytes (apply #'concatenate '(vector (unsigned-byte 8))
                         (loop for spec in specs
                               for seq from (1+ head)
                               collect (destructuring-bind (from &key to (text "mail"))
                                           spec
                                         (wal:encode-record
                                          seq
                                          (envelope:wrap-envelope
                                           (format nil "c~D" seq) from text
                                           :to to)))))))
      (ensure-directories-exist wal-path)
      (with-open-file (out wal-path :element-type '(unsigned-byte 8)
                                    :direction :output :if-exists :append
                                    :if-does-not-exist :create)
        (write-sequence bytes out)
        (finish-output out))
      (+ head (length specs)))))

(defun publish (state bus from-id &key to (text "mail"))
  "Append one record from FROM-ID to BUS's log under STATE, addressed to TO when
   given, and return its seq."
  (publish-batch state bus (list (list from-id :to to :text text))))

(defun write-cursor (state bus id seq &optional generation)
  "Leave the agent ID a durable cursor at SEQ on BUS under STATE, as though it
   had read the bus up to there, and return its path. GENERATION, when given,
   is written after the seq as the generation of the log the position was
   taken against, as the bus client writes it."
  (with-state-home (state)
    (let ((path (merge-pathnames (envelope:encode-id id)
                                 (uiop:ensure-directory-pathname
                                  (default-cursors-dir bus)))))
      (ensure-directories-exist path)
      (with-open-file (out path :direction :output :if-exists :supersede
                                :if-does-not-exist :create)
        (format out "~D~@[ ~D~]" seq generation))
      path)))

(defun lock-holder (state bus namespace agent)
  "The pid holding the lock on AGENT's pid file under NAMESPACE on BUS under
   STATE, or NIL. Asked from this process, which never holds that lock."
  (%lock-holder (detach-file state bus namespace agent "pid")))

;;; processes under a state root ------------------------------------------------

(defun %proc-text (pid file)
  "The /proc FILE of PID as text, read byte for byte, or NIL when it cannot be
   read."
  (ignore-errors
   (uiop:read-file-string (format nil "/proc/~D/~A" pid file)
                          :external-format :latin-1)))

(defun %own-process-p (pid)
  "True when PID belongs to the user this process runs as."
  (eql (ignore-errors (sb-posix:stat-uid (sb-posix:stat (format nil "/proc/~D" pid))))
       (sb-posix:getuid)))

(defun processes-under-state (state)
  "Every process of this user whose environment names STATE as its state root,
   as a list of (PID . COMMAND-LINE), the command line's arguments joined by
   spaces. Only processes of this user are looked at, and one whose environment
   cannot be read is passed over rather than counted."
  (let ((wanted (format nil "XDG_STATE_HOME=~A" (uiop:native-namestring state)))
        (nul (string (code-char 0))))
    (loop for dir in (ignore-errors (uiop:subdirectories "/proc/"))
          for name = (car (last (pathname-directory dir)))
          for pid = (and (stringp name) (every #'digit-char-p name)
                         (parse-integer name))
          for environ = (and pid (%own-process-p pid) (%proc-text pid "environ"))
          when (and environ
                    (member wanted (uiop:split-string environ :separator nul)
                            :test #'string=))
            collect (cons pid (substitute #\Space (code-char 0)
                                          (string-right-trim
                                           nul (or (%proc-text pid "cmdline") "")))))))

;;; a publishing client ---------------------------------------------------------

(defun %publisher-out (state)
  "Where the publishing client under STATE writes what it has done."
  (merge-pathnames "publisher.out" state))

(defun publisher-lines (state)
  "What the publishing client under STATE has written so far, line by line."
  (or (ignore-errors (uiop:read-file-lines (%publisher-out state))) '()))

(defun %publisher-program (root from-id count interval)
  "The form a publishing client evaluates once the bus client is loaded: join
   the bus at ROOT, submit COUNT records from FROM-ID INTERVAL seconds apart,
   then wait for the last of them to reach the log before closing, since the
   socket drops whatever it still holds when it closes."
  (format nil "(let* ((paths (dsmr-mcp/src/bus/broker:make-bus-paths (pathname ~S)))
         (wal (dsmr-mcp/src/bus/broker:bus-paths-wal paths))
         (members (dsmr-mcp/src/bus/broker:join-members paths))
         (submitter (dsmr-mcp/src/bus/zmq:make-submitter
                     (dsmr-mcp/src/bus/broker:bus-paths-submit-endpoint paths))))
    (declare (ignorable members))
    (format t \"ready~~%\") (finish-output)
    (loop for n from 1 to ~D
          do (dsmr-mcp/src/bus/zmq:send-message
              submitter
              (dsmr-mcp/src/bus/envelope:wrap-envelope
               (format nil \"pub~~D\" n) ~S (format nil \"count=~~D\" n)))
             (format t \"sent ~~D~~%\" n) (finish-output)
             (sleep ~F))
    (loop repeat 300
          until (find \"count=~D\" (ignore-errors (dsmr-mcp/src/bus/wal:read-records wal))
                      :test (lambda (want record)
                              (search want (dsmr-mcp/src/bus/wal:record-body-string record))))
          do (sleep 0.1))
    (format t \"done~~%\") (finish-output)
    (dsmr-mcp/src/bus/zmq:close-endpoint submitter))"
          root count from-id interval count))

(defun start-publisher (state bus from-id count &key (interval 0.1) (seconds 120))
  "Start a bus client in a process of its own, under STATE, that joins BUS as a
   member, as an agent's server does, and submits COUNT records from FROM-ID,
   one every INTERVAL seconds, the Nth with the text count=N. It never elects a
   broker: what it submits while nothing serves the bus waits in its socket.

   It writes `ready` once connected, `sent N` after each submission and `done`
   once its last record is in the log, to publisher.out under STATE (see
   PUBLISHER-LINES). Waits up to SECONDS for `ready` and returns the process,
   which is stopped with the case."
  (let* ((root (with-state-home (state)
                 (uiop:native-namestring
                  (broker:bus-paths-root
                   (broker:ensure-bus-dirs
                    (broker:make-bus-paths (broker:default-state-root bus)))))))
         (process (uiop:launch-program
                   (append (list "env" "-u" "DSMR_BUS_AGENT" "-u" "DSMR_BUS_SELECTOR"
                                 "-u" "CLAUDE_PID")
                           (watcher-env state)
                           (list (uiop:native-namestring sb-ext:*runtime-pathname*)
                                 "--noinform" "--disable-debugger" "--non-interactive"
                                 "--eval" "(require :asdf)"
                                 "--eval" (format nil "(asdf:load-asd ~S)"
                                                  (uiop:native-namestring
                                                   (asdf:system-source-file "dsmr-mcp")))
                                 "--eval" "(asdf:load-system \"dsmr-mcp/src/bus/bus\")"
                                 "--eval" (%publisher-program root from-id count interval)))
                   :input nil
                   :output (uiop:native-namestring
                            (with-open-file (stream (%publisher-out state)
                                                    :direction :output
                                                    :if-exists :append
                                                    :if-does-not-exist :create)
                              (pathname stream)))
                   :if-output-exists :append
                   :error-output :output)))
    (%note-started process)
    (unless (await-true (lambda () (member "ready" (publisher-lines state)
                                           :test #'string=))
                        seconds)
      (error "the publishing client did not connect within ~Ds; see ~A"
             seconds (%publisher-out state)))
    process))

;;; a broker a client elected -------------------------------------------------

(defun start-foreign-broker (state bus &key (seconds 120))
  "Start a broker for BUS under STATE in a process of its own, the way a
   client elects one while no service runs, wait up to SECONDS for it to win
   the election and bind its intake, and return its pid. It is stopped with
   the case.

   Readiness is read from the identity record the broker writes and the
   socket it binds, never by probing the election lock: a probe holds the lock
   for an instant, and a broker started without blocking that loses to it
   exits."
  (with-state-home (state)
    (let* ((paths (broker:ensure-bus-dirs
                   (broker:make-bus-paths (broker:default-state-root bus))))
           (pid (%note-started (broker:spawn-broker paths :block nil))))
      (unless (await-true
               (lambda ()
                 (and (eql pid (broker:broker-identity-pid
                                (broker:read-broker-identity paths)))
                      (probe-file (merge-pathnames "submit.ipc"
                                                   (broker:bus-paths-root paths)))
                      t))
               seconds)
        (error "the broker (pid ~D) did not come up within ~Ds; see ~A"
               pid seconds (merge-pathnames "broker.log" (broker:bus-paths-root paths))))
      pid)))
