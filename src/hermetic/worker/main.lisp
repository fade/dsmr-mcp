;;;; src/hermetic/worker/main.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Worker process entry point.
;;;;
;;;; A hermetic worker is a fresh SBCL image that loads dsmr-mcp and serves
;;;; over an ephemeral localhost TCP port it opens itself — it does NOT carry
;;;; the primary's attached-image state (D-03, HERM-01).
;;;;
;;;; MANDATORY STARTUP ORDER (D-04, RESEARCH.md Pitfall 2):
;;;;   1. sb-ext:disable-debugger   — prevents SBCL debugger writing to stdout
;;;;   2. configure-log4cl-for-server — installs stderr-only appender BEFORE any log
;;;;   3. log-event                 — first safe log point
;;;;   4. make-worker-server        — open ephemeral TCP port
;;;;   5. register-all-handlers     — wire method table
;;;;   6. %output-handshake         — ONE JSON line to stdout then done
;;;;   7. %redirect-stdout-to-devnull — stdout → /dev/null post-handshake
;;;;   8. %start-parent-watchdog    — orphan-exit watchdog thread
;;;;   9. start-accept-loop         — blocks serving
;;;;
;;;; stdout is the handshake channel; any later write corrupts the parent's
;;;; pipe read. All log output goes to stderr via the log4cl stderr appender.

(defpackage #:dsmr-mcp/src/hermetic/worker/main
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/hermetic/worker/server
                #:make-worker-server #:server-port #:start-accept-loop)
  (:import-from #:dsmr-mcp/src/hermetic/worker/handlers
                #:register-all-handlers)
  (:import-from #:dsmr-mcp/src/log
                #:log-event #:configure-log4cl-for-server)
  (:import-from #:com.inuoe.jzon)
  (:import-from #:bordeaux-threads #:make-thread)
  (:import-from #:sb-ext)
  (:import-from #:sb-posix)
  (:import-from #:uiop)
  (:export #:start))

(in-package #:dsmr-mcp/src/hermetic/worker/main)

;;; ---------------------------------------------------------------------------
;;; Constants
;;; ---------------------------------------------------------------------------

(defconstant +worker-protocol-version+ 1
  "Worker protocol version. Logged in the handshake; parent warns on mismatch
but does not hard-fail for forward compatibility.")

;;; ---------------------------------------------------------------------------
;;; Internal helpers — process info
;;; ---------------------------------------------------------------------------

(defun %get-pid ()
  "Return the current process PID as an integer."
  (sb-posix:getpid))

;;; ---------------------------------------------------------------------------
;;; Internal helpers — Swank (stubbed OFF for Phase 4)
;;; ---------------------------------------------------------------------------

(defun %maybe-start-swank ()
  "Attempt to start a Swank server in the worker. Always returns NIL in
Phase 4 — Swank is OFF by default (D-06, assumption A1 from RESEARCH.md).
Set DSMR_WORKER_SWANK=1 for the Phase-5 opt-in."
  (let ((env-val (uiop:getenv "DSMR_WORKER_SWANK")))
    (when (and env-val (plusp (length env-val)))
      (log-event :warn "worker.swank.skip"
                 "reason" "DSMR_WORKER_SWANK reserved for Phase-5 opt-in"))
    ;; Always nil this phase — Swank wiring lands in Phase 5.
    nil))

;;; ---------------------------------------------------------------------------
;;; Internal helpers — project root
;;; ---------------------------------------------------------------------------

(defun %setup-project-root ()
  "Read DSMR_PROJECT_ROOT from the environment and set *default-pathname-defaults*.
Phase 4 simplification: sets the root but skips chdir — repl-eval does
not require it. Full chdir + fs verb support lands in Phase 6+."
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
encodes as JSON false (the Phase-1 jzon nil-vs-null fix, D-06).
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
the parent's pipe read (D-04 channel integrity)."
  (let ((devnull (open #P"/dev/null" :direction :output :if-exists :append)))
    (setf *standard-output* devnull
          *debug-io*        (make-two-way-stream *standard-input* devnull)
          *trace-output*    devnull
          *terminal-io*     (make-two-way-stream *standard-input* devnull))))

;;; ---------------------------------------------------------------------------
;;; Internal helpers — parent-death watchdog
;;; ---------------------------------------------------------------------------

(defun %start-parent-watchdog ()
  "Start a daemon thread that polls getppid() every 2 seconds and
self-exits via sb-ext:exit when the parent dies (D-10, RESEARCH.md §Pitfall 6).

The expected parent PID is read from DSMR_PARENT_PID (injected by
%build-environment in worker-client). Falling back to the live getppid()
value when the variable is absent (manual invocation or MCP_NO_WORKER_POOL).

Docker ppid=1 special case (verbatim from cl-mcp): when DSMR_PARENT_PID
is absent and the original ppid is already 1, the check that would
detect a stale ppid is skipped — the worker is running inside a
container where PID 1 is the legitimate parent."
  (let* ((original-ppid (sb-posix:getppid))
         (env-ppid-str  (uiop:getenv "DSMR_PARENT_PID"))
         (expected-ppid
          (if (and env-ppid-str (plusp (length env-ppid-str)))
              (or (ignore-errors (parse-integer env-ppid-str)) original-ppid)
              original-ppid)))
    (when (and (/= expected-ppid 1) (/= original-ppid expected-ppid))
      ;; Spawning thread already exited before we started — genuinely orphaned.
      ;; (The Docker ppid=1 case: legitimate parent IS pid 1 — don't exit.)
      (log-event :warn "worker.parent-already-dead"
                 "pid" (%get-pid) "expected_ppid" expected-ppid
                 "actual_ppid" original-ppid)
      (sb-ext:exit :code 0 :abort t))
    (log-event :info "worker.parent-watchdog.started"
               "pid" (%get-pid) "parent_pid" expected-ppid)
    (make-thread
     (lambda ()
       (loop (sleep 2)
             (let ((ppid (sb-posix:getppid)))
               (when (/= ppid expected-ppid)
                 (ignore-errors
                   (log-event :info "worker.parent-died"
                              "pid" (%get-pid)
                              "expected_ppid" expected-ppid
                              "current_ppid" ppid))
                 (sb-ext:exit :code 0 :abort t)))))
     :name "parent-watchdog")))

;;; ---------------------------------------------------------------------------
;;; Public API — entry point
;;; ---------------------------------------------------------------------------

(defun start ()
  "Entry point for worker child processes. Called by the sbcl args built by
%build-sbcl-args in worker-client.lisp.

Follows the mandatory startup order (RESEARCH.md Pitfall 2, D-04):
  1. disable-debugger — first, unconditionally
  2. Restore *standard-output* to sb-sys:*stdout* (raw fd-1 pipe).
     %build-sbcl-args redirects *standard-output* to *error-output* before
     asdf:load-system so ASDF compile notes and SLYNK's *debug-io* banner
     do not corrupt the handshake channel.  Here we restore the raw fd-1
     stream so step 6 (%output-handshake) can reach the parent's pipe read.
  3. configure-log4cl-for-server — second; any earlier log would corrupt stdout
  4. log worker.starting
  5. make-worker-server (ephemeral TCP)
  6. register-all-handlers
  7. %output-handshake (ONE line to stdout, then done)
  8. %redirect-stdout-to-devnull
  9. %start-parent-watchdog thread
  10. start-accept-loop (blocks)

When the accept loop exits (parent disconnected or server stopped),
the process exits cleanly."
  ;; Step 1: disable debugger FIRST — prevents SBCL writing to stdout on errors.
  (sb-ext:disable-debugger)
  ;; Step 2: restore *standard-output* to the raw fd-1 pipe so the handshake
  ;; can reach the parent.  %build-sbcl-args redirected it to *error-output*
  ;; before asdf:load-system to keep ASDF compile notes and SLYNK's banner
  ;; off the handshake channel.
  (setf *standard-output* sb-sys:*stdout*)
  ;; Step 3: install stderr-only log appender BEFORE any log-event call.
  (configure-log4cl-for-server :info)
  ;; Step 4: first safe log point.
  (let ((worker-id (or (uiop:getenv "DSMR_WORKER_ID") "?")))
    (log-event :info "worker.starting"
               "worker_id" worker-id
               "pid" (%get-pid)))
  ;; Install SIGTERM handler for clean pool shutdown.
  (%install-signal-handlers)
  ;; Set project root when injected (Phase 6+ uses this for fs verbs).
  (%setup-project-root)
  ;; Step 5: open ephemeral TCP port.
  (handler-case
      (let* ((server   (make-worker-server))
             (tcp-port (server-port server)))
        ;; Step 6: register method handlers.
        (register-all-handlers server)
        ;; Step 6 cont: start optional Swank (always nil this phase).
        (let ((swank-port (%maybe-start-swank)))
          (log-event :info "worker.ready"
                     "tcp_port" tcp-port
                     "swank_port" (or swank-port "none")
                     "pid" (%get-pid))
          ;; Step 7: emit the ONE handshake line to stdout.
          ;; *standard-output* was restored to sb-sys:*stdout* above.
          ;; 'null (CL:NULL) for absent swank_port — NOT nil (jzon nil = false).
          (%output-handshake tcp-port swank-port)
          ;; Step 8: stdout → /dev/null; no further writes reach the parent pipe.
          (%redirect-stdout-to-devnull)
          ;; Step 9: orphan watchdog thread.
          (%start-parent-watchdog)
          ;; Step 10: block in the accept loop.
          (start-accept-loop server)))
    (serious-condition (e)
      (ignore-errors
        (log-event :error "worker.fatal"
                   "error" (princ-to-string e)
                   "pid" (%get-pid)))))
  (sb-ext:exit :code 0 :abort t))
