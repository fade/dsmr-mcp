;;;; src/hermetic/worker-client.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Dispatcher-side wire client for hermetic ICP workers.
;;;; Workers are fresh SBCL child processes launched via sb-ext:run-program.
;;;; Each worker outputs a one-line JSON handshake on stdout containing
;;;; tcp_port, pid, and swank_port; the dispatcher connects to the worker's
;;;; TCP port and exchanges JSON-RPC requests line-by-line.
;;;;
;;;; Framing: newline-delimited JSON with a 16 MB line cap (+max-json-line-bytes+).
;;;; TCP connect: sb-ext:with-timeout only — never usocket:socket-connect :timeout
;;;; which sets SO_RCVTIMEO and breaks all subsequent reads (cl-mcp PR #67).

(defpackage #:dsmr-mcp/src/hermetic/worker-client
  (:use #:cl)
  (:import-from #:bordeaux-threads
                #:make-lock #:with-lock-held #:make-thread
                #:thread-alive-p #:join-thread #:destroy-thread)
  (:import-from #:dsmr-mcp/src/log #:log-event)
  (:import-from #:usocket)
  (:import-from #:com.inuoe.jzon)
  (:import-from #:sb-ext)
  (:import-from #:sb-posix)
  (:import-from #:uiop)
  (:export #:worker #:make-worker #:spawn-worker #:worker-rpc
           #:worker-rpc-error #:worker-tcp-port #:worker-swank-port
           #:worker-pid #:worker-state #:worker-session-id #:worker-id
           #:worker-needs-reset-notification #:worker-stream-lock
           #:mark-worker-crashed
           #:clear-reset-notification #:check-and-clear-reset-notification
           #:worker-process-info #:kill-worker #:worker-crashed
           #:worker-crashed-reason #:worker-spawn-failed
           #:+max-json-line-bytes+ #:%read-line-limited #:line-too-long
           #:worker-crash-history-pushed-p #:*reaper-threads*
           #:*reaper-threads-lock* #:signal-worker-terminate
           #:worker-last-crash-reason #:worker-last-exit-status
           #:worker-last-exit-code #:*worker-startup-timeout*))

(in-package #:dsmr-mcp/src/hermetic/worker-client)

;;; ---------------------------------------------------------------------------
;;; Configuration
;;; ---------------------------------------------------------------------------

(defconstant +worker-protocol-version+ 1
  "Expected worker protocol version. Logs a warning on mismatch
but does not hard-fail for forward compatibility.")

(defparameter *worker-startup-timeout*
  (let ((v (uiop:getenv "DSMR_WORKER_STARTUP_TIMEOUT")))
    (if (and v (not (string= v "")))
        (max 1 (parse-integer v :junk-allowed t))
        30))
  "Maximum seconds to wait for a worker handshake after launch.
Override via DSMR_WORKER_STARTUP_TIMEOUT environment variable.")

(defvar *worker-id-counter* 0
  "Monotonically increasing worker ID counter.")

(defvar *worker-id-lock* (bt:make-lock "worker-id-lock")
  "Lock protecting *worker-id-counter*.")

(defvar *reaper-threads* nil
  "List of active reaper threads spawned by %mark-worker-crashed.
Each thread terminates and self-removes after reaping its process.")

(defvar *reaper-threads-lock* (bt:make-lock "reaper-threads-lock")
  "Lock protecting *reaper-threads*.")

(defvar *stderr-drain-lock* (bt:make-lock "stderr-drain-lock")
  "Lock protecting concurrent writes to *error-output* from stderr drain threads.")

;;; ---------------------------------------------------------------------------
;;; Worker struct (defined early so condition reporters can reference accessors)
;;; ---------------------------------------------------------------------------

(defstruct worker
  "Represents a child worker process and its communication channel."
  (id nil)
  (state :dead :type keyword)
  (process-info nil)
  (stream nil)
  (socket nil)
  (stream-lock (bt:make-lock "worker-stream-lock"))
  (tcp-port nil)
  (swank-port nil)
  (pid nil)
  (needs-reset-notification nil :type boolean)
  (session-id nil)
  (request-counter 0 :type integer)
  (stderr-thread nil)
  (crash-history-pushed-p nil :type boolean)
  (last-crash-reason nil)
  (last-exit-status nil)
  (last-exit-code nil))

;;; ---------------------------------------------------------------------------
;;; Conditions
;;; ---------------------------------------------------------------------------

(define-condition worker-crashed (error)
  ((worker :initarg :worker :reader worker-crashed-worker)
   (reason :initarg :reason :reader worker-crashed-reason
           :initform "unknown"))
  (:report (lambda (c s)
             (format s "Worker ~A (PID ~A) ~A"
                     (worker-id (worker-crashed-worker c))
                     (worker-pid (worker-crashed-worker c))
                     (let ((r (worker-crashed-reason c)))
                       (if (string= r "timeout")
                           "timed out"
                           (format nil "crashed (~A)" r)))))))

(define-condition worker-spawn-failed (error)
  ((message :initarg :message :reader worker-spawn-failed-message))
  (:report (lambda (c s)
             (format s "Failed to spawn worker: ~A"
                     (worker-spawn-failed-message c)))))

(define-condition worker-rpc-error (error)
  ((code :initarg :code :reader worker-rpc-error-code)
   (message :initarg :message :reader worker-rpc-error-message))
  (:report (lambda (c s)
             (format s "JSON-RPC error ~A: ~A"
                     (worker-rpc-error-code c)
                     (worker-rpc-error-message c))))
  (:documentation "Legitimate JSON-RPC error response from a worker handler.
Distinct from protocol errors (parse failure, ID mismatch) which
indicate stream corruption and require marking the worker crashed."))

(define-condition line-too-long (error)
  ((limit :initarg :limit :reader line-too-long-limit))
  (:report (lambda (c s)
             (format s "JSON-RPC line exceeds ~D byte limit"
                     (line-too-long-limit c))))
  (:documentation "Signaled by %READ-LINE-LIMITED when input exceeds the byte limit.
Allows callers to distinguish size-limit violations from other I/O errors."))

;;; ---------------------------------------------------------------------------
;;; Message size limit + framing
;;; ---------------------------------------------------------------------------

(defconstant +max-json-line-bytes+ (* 16 1024 1024)
  "Maximum bytes for a single JSON-RPC line (16 MB).
Guards against memory exhaustion from malformed or malicious input.
Framing is newline-delimited JSON — NOT length-prefixed.")

(defun %read-line-limited (stream eof-value limit)
  "Read a newline-delimited line from STREAM, enforcing LIMIT byte cap.
Returns the line as a string, or EOF-VALUE at end-of-file.
Signals LINE-TOO-LONG if the cap is exceeded.
Handles both LF and CRLF line endings."
  (let ((buf (make-array 256 :element-type 'character
                             :adjustable t :fill-pointer 0))
        (count 0))
    (loop (let ((ch (read-char stream nil nil)))
            (cond
              ((null ch)
               (return (if (zerop count) eof-value buf)))
              ((char= ch #\Newline)
               (return buf))
              ((char= ch #\Return)
               ;; Skip CR in CRLF
               nil)
              (t
               (incf count)
               (when (> count limit)
                 (error 'line-too-long :limit limit))
               (vector-push-extend ch buf)))))))

;;; ---------------------------------------------------------------------------
;;; Internal helpers — ID generation
;;; ---------------------------------------------------------------------------

(defun %next-worker-id ()
  "Return the next monotonically increasing worker ID."
  (bt:with-lock-held (*worker-id-lock*)
    (incf *worker-id-counter*)))

;;; ---------------------------------------------------------------------------
;;; Internal helpers — secret generation
;;; ---------------------------------------------------------------------------

(defun %generate-worker-secret ()
  "Generate a 128-bit random hex secret for worker TCP authentication."
  (format nil "~32,'0X" (random (expt 2 128))))

;;; ---------------------------------------------------------------------------
;;; Internal helpers — environment
;;; ---------------------------------------------------------------------------

(defparameter *worker-env-denylist*
  '("DSMR_WORKER_SECRET" "DSMR_WORKER_ID" "DSMR_PARENT_PID")
  "Environment variables that must NOT be inherited from the parent.
These are set explicitly per-worker to the correct per-worker values.")

(defun %build-environment (secret id)
  "Build the environment for worker processes.
Inherits the parent's full environment, adding DSMR-specific variables
and excluding only those that would conflict with per-worker overrides."
  (let ((env (list (format nil "DSMR_WORKER_SECRET=~A" secret)
                   (format nil "DSMR_WORKER_ID=~A" id)
                   (format nil "DSMR_PARENT_PID=~A" (sb-posix:getpid))
                   "DSMR_NO_WORKER_POOL=1")))
    ;; Inherit all parent environment variables except those that
    ;; conflict with per-worker overrides set above.
    (dolist (entry (sb-ext:posix-environ))
      (let ((eq-pos (position #\= entry)))
        (when eq-pos
          (let ((name (subseq entry 0 eq-pos)))
            (unless (or (member name *worker-env-denylist* :test #'string=)
                        (string= name "DSMR_NO_WORKER_POOL"))
              (push entry env))))))
    env))

;;; ---------------------------------------------------------------------------
;;; Internal helpers — process launch
;;; ---------------------------------------------------------------------------

(defvar *cached-sbcl-path* nil
  "Cached result of %find-sbcl-path.")

(defun %find-sbcl-path ()
  "Locate the sbcl executable. Uses argv[0] of the running process first,
falls back to 'which sbcl'."
  (or *cached-sbcl-path*
      (setf *cached-sbcl-path*
            (or (let ((argv0 (first sb-ext:*posix-argv*)))
                  (when (and argv0 (search "sbcl" argv0))
                    argv0))
                (handler-case
                    (let ((path (string-trim '(#\Newline #\Return #\Space)
                                  (uiop:run-program
                                   '("which" "sbcl") :output :string))))
                      (if (and path (plusp (length path))) path "sbcl"))
                  (error () "sbcl"))))))

(defun %quicklisp-setup-path ()
  "Return the absolute path to Quicklisp's setup.lisp if Quicklisp is
loaded in the current image, or NIL otherwise."
  (let ((ql-pkg (find-package :quicklisp)))
    (when ql-pkg
      (let ((sym (find-symbol "*QUICKLISP-HOME*" ql-pkg)))
        (when (and sym (boundp sym))
          (let ((home (symbol-value sym)))
            (when home
              (namestring (merge-pathnames "setup.lisp"
                                           (namestring home))))))))))

(defun %build-sbcl-args ()
  "Build command-line arguments for spawning a worker via bare SBCL.

--no-userinit prevents the user's ~/.sbclrc from running in the child.
Without this flag, .sbclrc (which quickloads bordeaux-threads and slynk)
runs in every worker, and when two workers spawn concurrently both try to
compile slynk to the same tmp-named fasl simultaneously, causing ASDF to
crash with a PROTO-SYSTEM error before the worker can emit its handshake.

The redirect-to-stderr eval runs before asdf:load-system so that ASDF
compile notes and SLYNK's *debug-io* banner ('SLYNK's ASDF loader
finished.') are routed to stderr rather than the handshake channel (fd 1).
sb-sys:*stdout* is the raw fd-1 FD-STREAM and is not affected by the
rebinding; start() restores *standard-output* to it before emitting the
handshake JSON line."
  (let ((source-dir (namestring (asdf:system-source-directory :dsmr-mcp)))
        (ql-setup (%quicklisp-setup-path)))
    (append
     (list "--noinform" "--non-interactive" "--no-userinit")
     (when ql-setup
       (list "--load" ql-setup))
     (list
      ;; Route stdout to stderr during load-system so compile notes and
      ;; SLYNK's *debug-io* banner cannot corrupt the handshake channel.
      ;; sb-sys:*stdout* retains the raw fd-1 pipe; start() restores it.
      "--eval"
      "(setf *standard-output* *error-output*
             *trace-output*    *error-output*
             *debug-io*        (make-two-way-stream *standard-input* *error-output*))"
      "--eval" (format nil
                       "(asdf:initialize-source-registry '(:source-registry :inherit-configuration (:tree ~S)))"
                       source-dir)
      "--eval" "(asdf:load-system :dsmr-mcp/src/hermetic/worker/main)"
      "--eval" "(dsmr-mcp/src/hermetic/worker/main:start)"))))

(defun %launch-worker-process (secret id)
  "Launch a worker child process via sb-ext:run-program.
Returns the sb-ext:process object with stdout and stderr as streams.
Always uses bare SBCL; dsmr-mcp is SBCL-only (no ros run wrapper)."
  (let ((env (%build-environment secret id))
        (sbcl-path (%find-sbcl-path)))
    (sb-ext:run-program sbcl-path
                        (%build-sbcl-args)
                        :output :stream :error :stream :wait nil
                        :search t :environment env)))

;;; ---------------------------------------------------------------------------
;;; Internal helpers — handshake
;;; ---------------------------------------------------------------------------

(defun %parse-handshake-from-stream (stdout)
  "Read lines from STDOUT until a valid handshake JSON line is found.
Skips non-JSON lines. Returns (values tcp-port pid swank-port-or-nil).
JSON null (the symbol 'null via jzon) for swank_port yields nil,
since (integerp 'null) is NIL."
  (loop for line = (%read-line-limited stdout nil +max-json-line-bytes+)
        unless line do
          (error 'worker-spawn-failed
                 :message "Worker closed stdout before handshake")
        do (let ((json (ignore-errors (com.inuoe.jzon:parse line))))
             (when (and (hash-table-p json) (gethash "tcp_port" json))
               (let ((tcp-port  (gethash "tcp_port"  json))
                     (pid       (gethash "pid"       json))
                     (swank-raw (gethash "swank_port" json)))
                 (unless (integerp tcp-port)
                   (error 'worker-spawn-failed
                          :message "Handshake tcp_port is not an integer"))
                 ;; Check protocol version (warn on mismatch, don't hard-fail)
                 (let ((version (gethash "protocol_version" json)))
                   (when (and version (integerp version)
                              (/= version +worker-protocol-version+))
                     (log-event :warn "worker.handshake.version-mismatch"
                                "expected" +worker-protocol-version+
                                "got" version)))
                 (return (values tcp-port
                                 pid
                                 (when (integerp swank-raw) swank-raw))))))))

(defun %read-handshake (process timeout)
  "Read the JSON handshake line from the worker's stdout.
Returns three values: tcp-port, pid, swank-port (or NIL).
Signals WORKER-SPAWN-FAILED on timeout or if stdout is closed
before a valid handshake is found."
  (let ((stdout (sb-ext:process-output process)))
    (handler-case
        (sb-ext:with-timeout timeout
          (%parse-handshake-from-stream stdout))
      (sb-ext:timeout ()
        (error 'worker-spawn-failed
               :message (format nil "Worker handshake timed out after ~Ds"
                                timeout))))))

;;; ---------------------------------------------------------------------------
;;; Internal helpers — TCP connection
;;; ---------------------------------------------------------------------------

(defun %connect-to-worker (host port)
  "Open a TCP connection to the worker at HOST:PORT.
Uses sb-ext:with-timeout for a 10-second connect-phase timeout.
Do NOT use usocket:socket-connect :timeout — it sets SO_RCVTIMEO
which causes IO-TIMEOUT on any subsequent read (cl-mcp PR #67 bug)."
  (handler-case
      (sb-ext:with-timeout 10
        (usocket:socket-connect host port :element-type 'character))
    (sb-ext:timeout ()
      (error "Connection to worker at ~A:~A timed out after 10s"
             host port))))

;;; ---------------------------------------------------------------------------
;;; Internal helpers — JSON-RPC framing
;;; ---------------------------------------------------------------------------

(defun %send-json-rpc (stream id method params)
  "Write a JSON-RPC 2.0 request to STREAM as a single newline-delimited line."
  (let ((req (make-hash-table :test 'equal)))
    (setf (gethash "jsonrpc" req) "2.0"
          (gethash "id"      req) id
          (gethash "method"  req) method)
    (when params
      (setf (gethash "params" req) params))
    (write-string (com.inuoe.jzon:stringify req) stream)
    (terpri stream)
    (force-output stream)))

(defun %read-json-rpc-response (stream id timeout)
  "Read a JSON-RPC 2.0 response from STREAM matching ID.
When TIMEOUT is non-NIL, signals SB-EXT:TIMEOUT after that many seconds.
Returns the parsed JSON hash-table on success.
Signals WORKER-RPC-ERROR for legitimate JSON-RPC error responses.
Signals SIMPLE-ERROR for protocol-level failures (parse errors, ID mismatches)."
  (flet ((do-read ()
           (let ((line (%read-line-limited stream nil +max-json-line-bytes+)))
             (unless line
               (error 'end-of-file :stream stream))
             (let ((json (com.inuoe.jzon:parse line)))
               (unless (hash-table-p json)
                 (error "Invalid JSON-RPC response: not an object"))
               ;; Verify ID matches
               (let ((resp-id (gethash "id" json)))
                 (unless (eql resp-id id)
                   (error "JSON-RPC response ID mismatch: expected ~A, got ~A"
                          id resp-id)))
               ;; Check for error — signal typed condition for worker errors
               (let ((err (gethash "error" json)))
                 (when err
                   (error 'worker-rpc-error
                          :code (gethash "code" err)
                          :message (gethash "message" err))))
               ;; Return the result
               (gethash "result" json)))))
    (if timeout
        (sb-ext:with-timeout timeout
          (do-read))
        (do-read))))

;;; ---------------------------------------------------------------------------
;;; Internal helpers — stderr drain
;;; ---------------------------------------------------------------------------

(defun %start-stderr-drain (worker)
  "Start a daemon thread that reads the worker's stderr line by line
and forwards each line to *error-output* under *stderr-drain-lock*.
Without this, the child's log output accumulates in an unread OS pipe
buffer. Once that buffer fills (typically 64 KB on Linux), the child
blocks on every stderr write, causing worker RPC calls to hang.
Stores the thread in the worker's stderr-thread slot for cleanup."
  (let ((process (worker-process-info worker))
        (wid (worker-id worker)))
    (when process
      (let ((err (sb-ext:process-error process)))
        (when err
          (setf (worker-stderr-thread worker)
                (bt:make-thread
                 (lambda ()
                   (unwind-protect
                       (ignore-errors
                        (loop for line = (read-line err nil nil)
                              while line
                              do (ignore-errors
                                  (bt:with-lock-held (*stderr-drain-lock*)
                                    (write-string line *error-output*)
                                    (terpri *error-output*)
                                    (force-output *error-output*)))))
                     (ignore-errors (close err))))
                 :name (format nil "worker-stderr-~A" wid))))))))

;;; ---------------------------------------------------------------------------
;;; Public API — spawn
;;; ---------------------------------------------------------------------------

(defun spawn-worker ()
  "Launch a worker child process and return a WORKER struct.
The worker is launched via sb-ext:run-program (bare SBCL only).
Reads the JSON handshake to discover tcp_port/pid/swank_port, connects
to the TCP port, authenticates with a shared secret, and returns the
worker in :standby state.

Signals WORKER-SPAWN-FAILED if the process cannot be started,
the handshake fails, or authentication is rejected."
  (let ((id (%next-worker-id))
        (secret (%generate-worker-secret))
        (process nil)
        (socket nil))
    (handler-case
        (progn
          (log-event :info "worker.spawning" "id" id)
          (setf process (%launch-worker-process secret id))
          (multiple-value-bind (tcp-port pid swank-port)
              (%read-handshake process *worker-startup-timeout*)
            (log-event :info "worker.handshake.received"
                       "id" id
                       "tcp_port" tcp-port
                       "swank_port" (or swank-port "none")
                       "pid" pid)
            ;; Close stdout pipe — no longer needed after handshake.
            ;; Frees an FD that would otherwise be held open for the
            ;; entire worker lifetime.
            (ignore-errors
              (close (sb-ext:process-output process)))
            (setf socket (%connect-to-worker "127.0.0.1" tcp-port))
            ;; Authenticate with shared secret
            (let ((auth-stream (usocket:socket-stream socket)))
              (%send-json-rpc auth-stream 0 "worker/authenticate"
                              (let ((ht (make-hash-table :test 'equal)))
                                (setf (gethash "secret" ht) secret)
                                ht))
              (let ((auth-resp (%read-json-rpc-response auth-stream 0 10)))
                (unless (and (hash-table-p auth-resp)
                             (gethash "authenticated" auth-resp))
                  (error 'worker-spawn-failed
                         :message "Worker authentication failed"))))
            (let ((worker (make-worker
                           :id id
                           :state :standby
                           :process-info process
                           :stream (usocket:socket-stream socket)
                           :socket socket
                           :tcp-port tcp-port
                           :swank-port swank-port
                           :pid pid)))
              (%start-stderr-drain worker)
              (log-event :info "worker.spawned"
                         "id" id
                         "tcp_port" tcp-port
                         "pid" pid)
              worker)))
      (error (e)
        ;; Clean up on failure
        (when socket
          (ignore-errors (usocket:socket-close socket)))
        (when process
          (ignore-errors
            (when (sb-ext:process-alive-p process)
              (sb-ext:process-kill process 15)
              (sleep 0.5)
              (when (sb-ext:process-alive-p process)
                (sb-ext:process-kill process 9)))
            (sb-ext:process-close process)))
        (log-event :warn "worker.spawn.failed"
                   "id" id
                   "error" (princ-to-string e))
        (if (typep e 'worker-spawn-failed)
            (error e)
            (error 'worker-spawn-failed
                   :message (princ-to-string e)))))))

;;; ---------------------------------------------------------------------------
;;; Internal helpers — crash handling
;;; ---------------------------------------------------------------------------

(defun %mark-worker-crashed (worker reason)
  "Mark WORKER as crashed, set reset notification flag, close its
stream to prevent further use, and log the event.
Process reaping is deferred to a background thread to avoid blocking
the caller, which typically holds stream-lock.
Returns nothing."
  (setf (worker-state worker) :crashed)
  (setf (worker-needs-reset-notification worker) t)
  ;; Close the stream/socket to prevent stale-response corruption.
  (ignore-errors
    (when (worker-socket worker)
      (usocket:socket-close (worker-socket worker))
      (setf (worker-socket worker) nil
            (worker-stream worker) nil)))
  ;; Shut down the stderr drain thread. Close the worker's stderr pipe first
  ;; so read-line in the drain loop returns NIL and the thread exits cleanly
  ;; via its own unwind-protect. Then poll briefly (up to 1 s) for the
  ;; natural exit before resorting to destroy-thread. This avoids destroying
  ;; the thread while it holds *stderr-drain-lock*, which would leave the
  ;; lock permanently held and block other workers' drain threads.
  (let ((th (worker-stderr-thread worker)))
    (when (and th (bt:thread-alive-p th))
      ;; Close the pipe to wake the read-line loop (write-end closed by
      ;; the killed process; closing the read-end unblocks any pending read).
      (let ((proc (worker-process-info worker)))
        (when proc
          (ignore-errors (close (sb-ext:process-error proc)))))
      ;; Poll up to 1 s for natural thread exit before force-destroying.
      (loop repeat 10
            while (bt:thread-alive-p th)
            do (sleep 0.1))
      (when (bt:thread-alive-p th)
        (ignore-errors (bt:destroy-thread th)))
      (setf (worker-stderr-thread worker) nil)))
  ;; Collect exit code before reaping.
  (let ((process (worker-process-info worker))
        (wid (worker-id worker))
        (exit-code nil)
        (exit-status nil))
    (when process
      (ignore-errors
        (let ((status (sb-ext:process-status process)))
          (setf exit-status (string-downcase (symbol-name status)))
          (when (member status '(:exited :signaled))
            (setf exit-code (sb-ext:process-exit-code process)))))
      (setf (worker-last-crash-reason worker) reason
            (worker-last-exit-status worker) (or exit-status "unknown")
            (worker-last-exit-code worker) (or exit-code "unknown"))
      ;; Reap the OS process in a background thread to avoid blocking.
      (let ((reaper-thread nil))
        (setf reaper-thread
              (bt:make-thread
               (lambda ()
                 (unwind-protect
                     (progn
                       ;; SIGTERM first, then wait up to 2s, then SIGKILL
                       (ignore-errors
                         (when (sb-ext:process-alive-p process)
                           (sb-ext:process-kill process 15)
                           (loop repeat 20
                                 while (sb-ext:process-alive-p process)
                                 do (sleep 0.1))
                           (when (sb-ext:process-alive-p process)
                             (log-event :warn "worker.reaper.sigkill" "id" wid)
                             (sb-ext:process-kill process 9)
                             (sleep 0.2))))
                       (ignore-errors (sb-ext:process-wait process))
                       (ignore-errors (sb-ext:process-close process)))
                   ;; Self-remove from reaper thread list on completion
                   (bt:with-lock-held (*reaper-threads-lock*)
                     (setf *reaper-threads*
                           (remove reaper-thread *reaper-threads*)))))
               :name (format nil "reap-worker-~A" wid)))
        ;; Register the thread before it can self-remove
        (bt:with-lock-held (*reaper-threads-lock*)
          (push reaper-thread *reaper-threads*))))
    (log-event :warn "worker.crashed"
               "id" (worker-id worker)
               "pid" (worker-pid worker)
               "exit_status" (or exit-status "unknown")
               "exit_code" (or exit-code "unknown")
               "reason" reason)))

;;; ---------------------------------------------------------------------------
;;; Public API — RPC
;;; ---------------------------------------------------------------------------

(defun worker-rpc (worker method params &key timeout)
  "Send a JSON-RPC request to WORKER and return the result hash-table.
TIMEOUT, when non-NIL, is the maximum seconds to wait for a response.

Signals WORKER-CRASHED if the worker process has died (EOF on stream),
timed out, encountered a stream/socket error, or if the stream is
already NIL (e.g. marked crashed by a concurrent thread).
Also signals WORKER-CRASHED for protocol errors (JSON parse failure,
response ID mismatch) which indicate stream desynchronization.

Signals WORKER-RPC-ERROR for legitimate JSON-RPC error responses from
the worker handler. These are re-signaled without marking the worker crashed."
  (bt:with-lock-held ((worker-stream-lock worker))
    (unless (worker-stream worker)
      (error 'worker-crashed :worker worker :reason "already-dead"))
    (let ((id (incf (worker-request-counter worker))))
      (handler-case
          (progn
            (%send-json-rpc (worker-stream worker) id method params)
            (%read-json-rpc-response (worker-stream worker) id timeout))
        (end-of-file ()
          (%mark-worker-crashed worker "eof")
          (error 'worker-crashed :worker worker :reason "eof"))
        (sb-ext:timeout ()
          (%mark-worker-crashed worker "timeout")
          (error 'worker-crashed :worker worker :reason "timeout"))
        (stream-error ()
          (%mark-worker-crashed worker "stream-error")
          (error 'worker-crashed :worker worker :reason "stream-error"))
        (worker-rpc-error (e)
          ;; Legitimate worker-side error (e.g. "symbol not found").
          ;; Re-signal without marking the worker as crashed.
          (error e))
        (error (e)
          ;; Protocol error (parse failure, ID mismatch, etc.).
          ;; Mark worker as crashed since the stream is desynchronized.
          (%mark-worker-crashed worker
                                (format nil "protocol-error: ~A" e))
          (error 'worker-crashed :worker worker
                 :reason (format nil "protocol-error: ~A" e)))))))

;;; ---------------------------------------------------------------------------
;;; Public API — kill
;;; ---------------------------------------------------------------------------

(defun signal-worker-terminate (worker)
  "Send SIGTERM to the worker's OS process to break its TCP pipe.
Returns T if signal was sent, NIL if process was already dead."
  (let ((process (worker-process-info worker)))
    (when (and process (sb-ext:process-alive-p process))
      (ignore-errors (sb-ext:process-kill process 15))
      t)))

(defun kill-worker (worker)
  "Terminate the worker process and clean up resources.
Closes the TCP socket under stream-lock for mutual exclusion with
concurrent worker-rpc calls. Sends SIGTERM first, waits up to 2
seconds, then SIGKILL if still alive. Sets state to :dead.
Closes the worker's stderr pipe before waiting on the drain thread so
the thread exits cleanly (read-line returns NIL) without holding
*stderr-drain-lock*; falls back to destroy-thread only if the thread
has not exited after 1 s.
Robust against already-dead processes."
  (let ((process (worker-process-info worker)))
    (log-event :info "worker.killing"
               "id" (worker-id worker)
               "pid" (worker-pid worker))
    ;; Close TCP socket under stream-lock first, so any concurrent
    ;; worker-rpc sees the closure as a stream-error.
    (bt:with-lock-held ((worker-stream-lock worker))
      (let ((socket (worker-socket worker)))
        (when socket
          (ignore-errors (usocket:socket-close socket))
          (setf (worker-socket worker) nil
                (worker-stream worker) nil)))
      (setf (worker-state worker) :dead))
    ;; Terminate the OS process outside the lock (may block up to ~2.2s)
    (when process
      (handler-case
          (when (sb-ext:process-alive-p process)
            ;; SIGTERM
            (sb-ext:process-kill process 15)
            ;; Wait up to 2 seconds
            (loop repeat 20
                  while (sb-ext:process-alive-p process)
                  do (sleep 0.1))
            ;; SIGKILL if still alive
            (when (sb-ext:process-alive-p process)
              (log-event :warn "worker.sigkill"
                         "id" (worker-id worker)
                         "pid" (worker-pid worker))
              (sb-ext:process-kill process 9)
              (sleep 0.2)))
        (error (e)
          (log-event :warn "worker.kill.error"
                     "id" (worker-id worker)
                     "error" (princ-to-string e))))
      ;; Close the stderr pipe to wake the drain thread's read-line loop,
      ;; then poll up to 1 s for natural exit before resorting to
      ;; destroy-thread. Closing the pipe avoids the risk of destroy-thread
      ;; killing the thread while it holds *stderr-drain-lock*.
      (let ((th (worker-stderr-thread worker)))
        (when (and th (bt:thread-alive-p th))
          (ignore-errors (close (sb-ext:process-error process)))
          (loop repeat 10
                while (bt:thread-alive-p th)
                do (sleep 0.1))
          (when (bt:thread-alive-p th)
            (ignore-errors (bt:destroy-thread th)))
          (setf (worker-stderr-thread worker) nil)))
      (ignore-errors (sb-ext:process-close process)))
    (log-event :info "worker.killed"
               "id" (worker-id worker)
               "pid" (worker-pid worker))
    worker))

;;; ---------------------------------------------------------------------------
;;; Public API — utility
;;; ---------------------------------------------------------------------------

(defun mark-worker-crashed (worker reason)
  "Public entry point to mark WORKER as crashed with REASON.
Delegates to %mark-worker-crashed so pool.lisp can crash-mark a worker
without accessing private struct accessors. See %mark-worker-crashed for
full semantics (state, stream close, reset-notification, reaper thread)."
  (%mark-worker-crashed worker reason))

(defun clear-reset-notification (worker)
  "Clear the needs-reset-notification flag on WORKER."
  (setf (worker-needs-reset-notification worker) nil))

(defun check-and-clear-reset-notification (worker)
  "Atomically check and clear the needs-reset-notification flag.
Returns T if the flag was set (and is now cleared), NIL otherwise.
Uses stream-lock for mutual exclusion with concurrent callers,
preventing the TOCTOU race where two threads both see the flag
as set and both return crash notifications."
  (bt:with-lock-held ((worker-stream-lock worker))
    (when (worker-needs-reset-notification worker)
      (setf (worker-needs-reset-notification worker) nil)
      t)))
