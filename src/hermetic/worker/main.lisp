;;;; src/hermetic/worker/main.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Worker process entry point.
;;;;
;;;; A hermetic worker is a fresh SBCL image that loads dsmr-mcp and serves
;;;; over an ephemeral localhost TCP port it opens itself — it does NOT carry
;;;; the primary's attached-image state.
;;;;
;;;; MANDATORY STARTUP ORDER (start):
;;;;   1. sb-ext:disable-debugger: prevents SBCL debugger writing to stdout
;;;;   2. configure-log4cl-for-server: installs stderr-only appender BEFORE any log
;;;;      then resolve-eval-timeout, which reads the eval timeout from this
;;;;      process's environment rather than the image it booted from
;;;;   3. log-event: first safe log point
;;;;   4. make-worker-server: open ephemeral TCP port
;;;;   5. register-worker-methods: wire method table
;;;;   6. %output-handshake: ONE JSON line to stdout then done
;;;;   7. %redirect-stdout-to-devnull: stdout to /dev/null post-handshake
;;;;   8. start-parent-watchdog: orphan-exit watchdog thread
;;;;   9. start-accept-loop: blocks serving
;;;;
;;;; RESUME ORDER (resume, the entry point of a core the worker saved of itself):
;;;;   1. sb-ext:disable-debugger
;;;;   2. install-descriptor-placeholders: cover the saved descriptor numbers
;;;;      with /dev/null before anything opens a new descriptor
;;;;   3. restore stdout, configure-log4cl-for-server, resolve-eval-timeout,
;;;;      then the first log
;;;;   4. SIGTERM handler, project root, and a fresh ASDF source registry scan
;;;;      on first lookup
;;;;   5. reopen-worker-server: a new listener for the server that came back
;;;;      from the heap with its method table and object registry
;;;;   6. %output-handshake, %redirect-stdout-to-devnull
;;;;   7. start-parent-watchdog on this process's DSMR_PARENT_PID
;;;;   8. start-accept-loop: blocks serving
;;;;
;;;; stdout is the handshake channel; any later write corrupts the parent's
;;;; pipe read. All log output goes to stderr via the log4cl stderr appender.

(defpackage #:dsmr-mcp/src/hermetic/worker/main
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/hermetic/worker/server
                #:make-worker-server #:server-port #:start-accept-loop
                #:register-method #:reopen-worker-server)
  (:import-from #:dsmr-mcp/src/hermetic/worker/handlers
                #:register-all-handlers #:resolve-eval-timeout)
  (:import-from #:dsmr-mcp/src/hermetic/worker/registry
                #:make-object-registry)
  (:import-from #:dsmr-mcp/src/hermetic/worker/hibernate
                #:handle-hibernate #:install-descriptor-placeholders)
  (:import-from #:dsmr-mcp/src/log
                #:log-event #:configure-log4cl-for-server)
  (:import-from #:com.inuoe.jzon)
  (:import-from #:bordeaux-threads #:make-thread)
  (:import-from #:sb-ext)
  (:import-from #:sb-posix)
  (:import-from #:uiop)
  (:export #:start #:resume #:register-worker-methods
           #:stop-parent-watchdog #:start-parent-watchdog
           #:*server* #:*registry* #:*watchdog-thread* #:*watchdog-stop*))

(in-package #:dsmr-mcp/src/hermetic/worker/main)

;;; ---------------------------------------------------------------------------
;;; Constants
;;; ---------------------------------------------------------------------------

(defconstant +worker-protocol-version+ 1
  "Worker protocol version. Logged in the handshake; parent warns on mismatch
but does not hard-fail for forward compatibility.")

(defvar *server* nil
  "This worker's server. Kept in a global, not a local of START, because a
worker resumed from a saved core finds it here with its method table intact.")

(defvar *registry* nil
  "This worker's object registry, kept global for the same reason as *SERVER*:
the ids a session holds must still resolve after a resume.")

(defvar *watchdog-thread* nil
  "The running parent watchdog thread, or NIL when none is running.")

(defvar *watchdog-stop* nil
  "Set to true to ask the parent watchdog to end its loop.")

;;; ---------------------------------------------------------------------------
;;; Internal helpers — process info
;;; ---------------------------------------------------------------------------

(defun %get-pid ()
  "Return the current process PID as an integer."
  (sb-posix:getpid))

;;; ---------------------------------------------------------------------------
;;; Internal helpers — Swank (stubbed OFF by default)
;;; ---------------------------------------------------------------------------

(defun %maybe-start-swank ()
  "Attempt to start a Swank server in the worker. Always returns NIL —
Swank is OFF by default. Set DSMR_WORKER_SWANK=1 to opt in."
  (let ((env-val (uiop:getenv "DSMR_WORKER_SWANK")))
    (when (and env-val (plusp (length env-val)))
      (log-event :warn "worker.swank.skip"
                 "reason" "DSMR_WORKER_SWANK not yet wired"))
    nil))

;;; ---------------------------------------------------------------------------
;;; Internal helpers — project root
;;; ---------------------------------------------------------------------------

(defun %setup-project-root ()
  "Read DSMR_PROJECT_ROOT from the environment and set *default-pathname-defaults*.
Sets the root but skips chdir — repl-eval does not require it. Full chdir
and filesystem verb support requires a later extension."
  (let ((env-root (uiop:getenv "DSMR_PROJECT_ROOT")))
    (when (and env-root (plusp (length env-root)))
      (let ((dir (uiop:ensure-directory-pathname env-root)))
        (if (uiop:directory-exists-p dir)
            (progn
              (log-event :info "worker.project-root.set"
                         "path" (namestring dir))
              dir)
            (progn
              (log-event :warn "worker.project-root.invalid"
                         "path" env-root)
              nil))))))

;;; ---------------------------------------------------------------------------
;;; Internal helpers — signal handlers
;;; ---------------------------------------------------------------------------

(defun %install-signal-handlers ()
  "Install SIGTERM handler so the worker exits cleanly when the parent
shuts down the pool. Without this, SBCL raises a condition for SIGTERM
which cascades into nested errors when stderr is a broken pipe."
  (sb-sys:enable-interrupt
   sb-posix:sigterm
   (lambda (signo context info)
     (declare (ignore signo context info))
     (ignore-errors
       (log-event :info "worker.sigterm" "pid" (%get-pid)))
     (sb-ext:exit :code 0 :abort t))))

;;; ---------------------------------------------------------------------------
;;; Internal helpers — handshake
;;; ---------------------------------------------------------------------------

(defun %output-handshake (tcp-port swank-port
                          &optional (stream *standard-output*))
  "Write the one-line JSON handshake to STREAM then flush.
SWANK-PORT must be 'null (CL:NULL) when absent — NOT nil, which jzon
encodes as JSON false (jzon encodes nil as false, not null).
This is the ONLY write to stdout; stdout is redirected afterwards."
  (let ((ht (make-hash-table :test 'equal)))
    (setf (gethash "tcp_port"         ht) tcp-port
          (gethash "swank_port"       ht) (if swank-port swank-port 'null)
          (gethash "pid"              ht) (%get-pid)
          (gethash "protocol_version" ht) +worker-protocol-version+)
    (write-string (com.inuoe.jzon:stringify ht) stream)
    (terpri stream)
    (force-output stream)))

;;; ---------------------------------------------------------------------------
;;; Internal helpers — stdout redirect
;;; ---------------------------------------------------------------------------

(defun %redirect-stdout-to-devnull ()
  "Open /dev/null for output and rebind *standard-output*, *debug-io*,
*trace-output*, and *terminal-io* to it. After the handshake any further
write to those streams goes silently to /dev/null rather than reaching
the parent's pipe read — preserving the handshake channel."
  (let ((devnull (open #P"/dev/null" :direction :output :if-exists :append)))
    (setf *standard-output* devnull
          *debug-io*        (make-two-way-stream *standard-input* devnull)
          *trace-output*    devnull
          *terminal-io*     (make-two-way-stream *standard-input* devnull))))

;;; ---------------------------------------------------------------------------
;;; Internal helpers — parent-death watchdog
;;; ---------------------------------------------------------------------------

(defun start-parent-watchdog ()
  "Start a daemon thread, named parent-watchdog, that checks getppid() every
2 seconds and self-exits via sb-ext:exit when the parent dies. The thread is
stored in *WATCHDOG-THREAD* and ends its loop when *WATCHDOG-STOP* is set; it
sleeps in quarter-second slices so STOP-PARENT-WATCHDOG never waits long.

The expected parent PID is read from DSMR_PARENT_PID (injected by
%build-environment in worker-client) each time this is called, so a worker
resumed from a saved core watches the process that resumed it. Falls back to
the live getppid() value when the variable is absent (manual invocation or
MCP_NO_WORKER_POOL).

Docker ppid=1 special case: when DSMR_PARENT_PID is absent and the
original ppid is already 1, the orphan check is skipped, because the worker is
running inside a container where PID 1 is the legitimate parent."
  (let* ((original-ppid (sb-posix:getppid))
         (env-ppid-str  (uiop:getenv "DSMR_PARENT_PID"))
         (expected-ppid
          (if (and env-ppid-str (plusp (length env-ppid-str)))
              (or (ignore-errors (parse-integer env-ppid-str)) original-ppid)
              original-ppid)))
    (when (and (/= expected-ppid 1) (/= original-ppid expected-ppid))
      ;; Spawning thread already exited before we started: genuinely orphaned.
      ;; (The Docker ppid=1 case: legitimate parent IS pid 1, so don't exit.)
      (log-event :warn "worker.parent-already-dead"
                 "pid" (%get-pid) "expected_ppid" expected-ppid
                 "actual_ppid" original-ppid)
      (sb-ext:exit :code 0 :abort t))
    (log-event :info "worker.parent-watchdog.started"
               "pid" (%get-pid) "parent_pid" expected-ppid)
    (setf *watchdog-stop* nil
          *watchdog-thread*
          (make-thread
           (lambda ()
             (loop with slices = 0
                   until *watchdog-stop*
                   do (sleep 0.25)
                      (incf slices)
                      (when (>= slices 8)
                        (setf slices 0)
                        (let ((ppid (sb-posix:getppid)))
                          (when (/= ppid expected-ppid)
                            (ignore-errors
                              (log-event :info "worker.parent-died"
                                         "pid" (%get-pid)
                                         "expected_ppid" expected-ppid
                                         "current_ppid" ppid))
                            (sb-ext:exit :code 0 :abort t))))))
           :name "parent-watchdog"))))

(defun stop-parent-watchdog ()
  "Ask the parent watchdog to end and wait up to 5 seconds for it, then clear
the stop flag and *WATCHDOG-THREAD*. A worker can only save itself with no
thread but its own running, so this is called before a save and
START-PARENT-WATCHDOG after a save that failed."
  (let ((thread *watchdog-thread*))
    (when (and thread (sb-thread:thread-alive-p thread))
      (setf *watchdog-stop* t)
      (handler-case (sb-thread:join-thread thread :timeout 5 :default nil)
        (error () nil)))
    (setf *watchdog-stop* nil
          *watchdog-thread* nil)))

;;; ---------------------------------------------------------------------------
;;; Public API — entry point
;;; ---------------------------------------------------------------------------

(defun %forget-source-registry-scan ()
  "Drop the ASDF source registry scan the saved world carried, keeping
asdf:*central-registry* and every system already loaded.

The scan is a snapshot of which .asd file was where when the worker last
looked, and files may have moved while the core sat on disk. Rescanning here
would put seconds in front of the handshake on a large workspace, so the scan
is left for ASDF to redo at the worker's first system lookup, as a worker
booted from the worker core does."
  (asdf:clear-source-registry))

(defun register-worker-methods (server registry)
  "Install every worker method on SERVER: the handler table over REGISTRY,
plus the method that saves this worker's world to a core so a later process
can resume it. The save is handed RESUME as the core's entry point and the
watchdog's stop and start functions, because a save needs the worker to be
the only thread running and a failed save must leave the watchdog running."
  (register-all-handlers server registry)
  (register-method server "worker/hibernate"
                   (lambda (params)
                     (handle-hibernate params server #'resume
                                       :stop-watchdog #'stop-parent-watchdog
                                       :start-watchdog #'start-parent-watchdog)))
  server)

(defun start ()
  "Entry point for worker child processes. Called by the sbcl args built by
%build-sbcl-args in worker-client.lisp.

Follows the mandatory startup order:
  1. disable-debugger, first, unconditionally
  2. Restore *standard-output* to sb-sys:*stdout* (raw fd-1 pipe).
     %build-sbcl-args redirects *standard-output* to *error-output* before
     asdf:load-system so ASDF compile notes and the Slynk banner do not
     corrupt the handshake channel.  Here we restore the raw fd-1 stream
     so step 6 (%output-handshake) can reach the parent's pipe read.
  3. configure-log4cl-for-server, second: any earlier log would corrupt stdout;
     then resolve-eval-timeout, so the eval timeout comes from this process's
     environment and not from the image it booted from
  4. log worker.starting
  5. make-worker-server (ephemeral TCP), kept in *server*
  6. register-worker-methods with a new object registry, kept in *registry*
  7. %output-handshake (ONE line to stdout, then done)
  8. %redirect-stdout-to-devnull
  9. start-parent-watchdog thread
  10. start-accept-loop (blocks)

When the accept loop exits (parent disconnected, server stopped, or the
worker saved itself to a core), the process exits cleanly."
  ;; Step 1: disable debugger FIRST, so SBCL never writes to stdout on errors.
  (sb-ext:disable-debugger)
  ;; Step 2: restore *standard-output* to the raw fd-1 pipe so the handshake
  ;; can reach the parent.  %build-sbcl-args redirected it to *error-output*
  ;; before asdf:load-system to keep ASDF compile notes and SLYNK's banner
  ;; off the handshake channel.
  (setf *standard-output* sb-sys:*stdout*)
  ;; Step 3: install stderr-only log appender BEFORE any log-event call.
  (configure-log4cl-for-server :info)
  ;; Step 3 cont: read the eval timeout from this process's environment now,
  ;; after the appender is in place so a warning about a bad value goes to
  ;; stderr, never the handshake channel.  A worker booted from a prebuilt
  ;; image would otherwise carry the value from when the image was built.
  (resolve-eval-timeout)
  ;; Step 4: first safe log point.
  (let ((worker-id (or (uiop:getenv "DSMR_WORKER_ID") "?")))
    (log-event :info "worker.starting"
               "worker_id" worker-id
               "pid" (%get-pid)))
  ;; Install SIGTERM handler for clean pool shutdown.
  (%install-signal-handlers)
  ;; Set project root when injected (fs verbs read this for path resolution).
  (%setup-project-root)
  ;; Step 5: open ephemeral TCP port.
  (handler-case
      (let* ((server   (setf *server* (make-worker-server)))
             (tcp-port (server-port server)))
        ;; Step 6: create a per-worker registry and register method handlers.
        ;; The registry lives for the worker process lifetime and survives a
        ;; save and resume; a crash (new process) starts a fresh empty
        ;; registry, which is the correct invalidation behavior.
        (register-worker-methods server (setf *registry* (make-object-registry)))
        ;; Step 6 cont: start optional Swank (always nil this phase).
        (let ((swank-port (%maybe-start-swank)))
          (log-event :info "worker.ready"
                     "tcp_port" tcp-port
                     "swank_port" (or swank-port "none")
                     "pid" (%get-pid))
          ;; Step 7: emit the ONE handshake line to stdout.
          ;; *standard-output* was restored to sb-sys:*stdout* above.
          ;; 'null (CL:NULL) for absent swank_port, NOT nil (jzon nil = false).
          (%output-handshake tcp-port swank-port)
          ;; Step 8: stdout to /dev/null; no further writes reach the parent pipe.
          (%redirect-stdout-to-devnull)
          ;; Step 9: orphan watchdog thread.
          (start-parent-watchdog)
          ;; Step 10: block in the accept loop.
          (start-accept-loop server)))
    (serious-condition (e)
      (ignore-errors
        (log-event :error "worker.fatal"
                   "error" (princ-to-string e)
                   "pid" (%get-pid)))))
  (sb-ext:exit :code 0 :abort t))

(defun resume ()
  "Entry point of every core a worker saves of itself.

The server, its method table and the object registry come back from the heap
in *server* and *registry*, so nothing is registered again. Everything that
belongs to the process rather than the heap is redone, in the resume order:
  1. disable-debugger
  2. install-descriptor-placeholders, before anything opens a descriptor
  3. restore *standard-output*, configure-log4cl-for-server,
     resolve-eval-timeout, then the first log, which also reports the
     placeholders
  4. SIGTERM handler and project root from this process's environment, and
     the ASDF source registry scan dropped so it is redone on first lookup
  5. reopen-worker-server: new listener, new port, not yet authenticated
  6. %output-handshake, %redirect-stdout-to-devnull
  7. start-parent-watchdog, which reads this process's DSMR_PARENT_PID
  8. start-accept-loop (blocks)

The connection authenticates against DSMR_WORKER_SECRET from this process's
environment, so the process that resumes the core decides the secret."
  (sb-ext:disable-debugger)
  ;; Covering the stale numbers protects later descriptors from stale
  ;; objects, but a resume that cannot do it still serves: the failure is
  ;; kept and reported once logging is up.
  (multiple-value-bind (covered in-use uncovered problem)
      (handler-case (install-descriptor-placeholders)
        (error (e) (values 0 nil nil (princ-to-string e))))
    (setf *standard-output* sb-sys:*stdout*)
    (configure-log4cl-for-server :info)
    (resolve-eval-timeout)
    (log-event :info "worker.resuming"
               "worker_id" (or (uiop:getenv "DSMR_WORKER_ID") "?")
               "pid" (%get-pid))
    (log-event :info "worker.resume.placeholders" "count" covered)
    (dolist (fd in-use)
      (log-event :warn "worker.resume.descriptor-in-use" "fd" fd))
    (dolist (fd uncovered)
      (log-event :warn "worker.resume.descriptor-uncovered" "fd" fd))
    (when problem
      (log-event :error "worker.resume.placeholders-failed" "error" problem)))
  (%install-signal-handlers)
  (%setup-project-root)
  (%forget-source-registry-scan)
  (handler-case
      (let ((tcp-port (reopen-worker-server *server*)))
        (let ((swank-port (%maybe-start-swank)))
          (log-event :info "worker.ready"
                     "tcp_port" tcp-port
                     "swank_port" (or swank-port "none")
                     "pid" (%get-pid))
          (%output-handshake tcp-port swank-port)
          (%redirect-stdout-to-devnull)
          (start-parent-watchdog)
          (start-accept-loop *server*)))
    (serious-condition (e)
      (ignore-errors
        (log-event :error "worker.fatal"
                   "error" (princ-to-string e)
                   "pid" (%get-pid)))))
  (sb-ext:exit :code 0 :abort t))
