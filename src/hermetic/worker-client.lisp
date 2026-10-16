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
           #:worker-ping #:worker-unresponsive
           #:worker-unresponsive-worker #:worker-unresponsive-seconds
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
           #:worker-last-exit-code #:*worker-startup-timeout*
           #:*resolved-worker-startup-timeout*
           #:resolve-worker-startup-timeout
           #:effective-worker-startup-timeout
           #:*worker-core* #:worker-core-path #:*worker-core-disabled*
           #:worker-boot-kind #:worker-boot-milliseconds
           #:worker-liveness #:worker-liveness-basis
           #:worker-last-ping-milliseconds
           #:worker-consecutive-missed-pings
           #:worker-liveness-checked-at
           #:worker-stateful-p #:worker-spawned-at #:worker-last-activity
           #:worker-in-flight #:worker-spawn-root
           #:worker-hibernate-core-path #:worker-hibernated-at
           #:worker-core-bytes #:worker-last-hibernate-milliseconds
           #:worker-last-resume-milliseconds
           #:worker-refused-reason #:worker-refused-at
           #:worker-reset-reason
           #:*hibernate-timeout-seconds* #:*hibernate-answer-margin-seconds*
           #:*hibernate-late-answer-seconds* #:hibernate-save-deadline
           #:hibernate-worker-process #:hibernate-refusal-token
           #:release-worker-process #:resume-worker
           #:end-worker-process #:*stream-lock-grace-seconds*
           #:worker-spawn-failed-kind #:worker-spawn-failure-final-p
           #:worker-runtime-path #:worker-runtime-identity
           #:worker-resume-failure #:worker-resume-deferrals
           #:runtime-identity #:resume-runtime
           #:*worker-resume-timeout* #:*resolved-worker-resume-timeout*
           #:resolve-worker-resume-timeout #:effective-worker-resume-timeout))

(in-package #:dsmr-mcp/src/hermetic/worker-client)

;;; ---------------------------------------------------------------------------
;;; Configuration
;;; ---------------------------------------------------------------------------

(defconstant +worker-protocol-version+ 1
  "Expected worker protocol version. Logs a warning on mismatch
but does not hard-fail for forward compatibility.")

(defvar *worker-startup-timeout* nil
  "Maximum seconds to wait for a worker handshake after launch, or NIL to read
the environment at start.

NIL (the default) means resolve-worker-startup-timeout reads
DSMR_WORKER_STARTUP_TIMEOUT, an integer number of seconds defaulting to 30 and
raised to at least 1. A non-NIL value, set globally or bound in the thread
that resolves, wins over the environment.")

(defvar *resolved-worker-startup-timeout* nil
  "The handshake timeout in seconds from the last
resolve-worker-startup-timeout call, or NIL when nothing has resolved yet.")

(defun %env-seconds (name default)
  "Read a whole number of seconds from environment variable NAME. Return
DEFAULT when NAME is unset or empty. A value below 1 is raised to 1. An
unparseable value warns and returns DEFAULT."
  (let ((s (uiop:getenv name)))
    (if (or (null s) (zerop (length s)))
        default
        (handler-case (max 1 (parse-integer s))
          (error ()
            (warn "~A=~S is not an integer; using default ~D" name s default)
            default)))))

(defun resolve-worker-startup-timeout ()
  "Read the worker handshake timeout now and store it in
*resolved-worker-startup-timeout*. Returns the number of seconds:
*worker-startup-timeout* when non-NIL, else DSMR_WORKER_STARTUP_TIMEOUT,
else 30.

The pool calls this whenever it starts, so a server booted from a prebuilt
image reads the environment it was started with."
  (setf *resolved-worker-startup-timeout*
        (or *worker-startup-timeout*
            (%env-seconds "DSMR_WORKER_STARTUP_TIMEOUT" 30))))

(defun effective-worker-startup-timeout ()
  "The worker handshake timeout in seconds as last resolved, resolving it
first when nothing has."
  (or *resolved-worker-startup-timeout* (resolve-worker-startup-timeout)))

(defvar *hibernate-timeout-seconds* 180
  "Seconds the pool waits for a worker's answer to a request to hibernate.

A save can take tens of seconds on a large world. The worker is given its own
deadline *hibernate-answer-margin-seconds* shorter than this (see
hibernate-save-deadline), so it always answers first, and this wait only
matters when the worker cannot answer at all.")

(defparameter *hibernate-answer-margin-seconds* 30
  "How much sooner than the pool stops waiting a worker must give up its save.
After its deadline the worker still has to kill and collect the saving child,
restart its watchdog and send its answer, and a host short of memory, which is
when saves run, can deschedule it for seconds at a time. A refusal that lands
after the pool stopped waiting would end a worker whose world was intact.")

(defparameter *hibernate-late-answer-seconds* 15
  "How long the pool goes on listening for a worker's answer to a save once its
wait has run out, before it ends the worker. A late refusal read in that time
puts the worker back into service with its world instead of losing it.")

(defun hibernate-save-deadline (timeout)
  "The deadline in whole seconds, at least 1, a worker is given for a save the
pool waits TIMEOUT seconds for: TIMEOUT less *hibernate-answer-margin-seconds*."
  (max 1 (floor (- timeout *hibernate-answer-margin-seconds*))))

(defvar *worker-resume-timeout* nil
  "Maximum seconds to wait for the handshake of a worker resumed from a core it
saved of itself, or NIL to read the environment at start.

A resumed world is read back from disk, possibly hundreds of megabytes on a
busy disk while the host is short of memory, so it gets a budget of its own,
longer than a fresh worker's. NIL (the default) means
resolve-worker-resume-timeout reads DSMR_WORKER_RESUME_TIMEOUT, an integer
number of seconds defaulting to 120 and raised to at least 1. A non-NIL value,
set globally or bound in the thread that resolves, wins over the environment.")

(defvar *resolved-worker-resume-timeout* nil
  "The resume handshake timeout in seconds from the last
resolve-worker-resume-timeout call, or NIL when nothing has resolved yet.")

(defun resolve-worker-resume-timeout ()
  "Read the resume handshake timeout now and store it in
*resolved-worker-resume-timeout*. Returns the number of seconds:
*worker-resume-timeout* when non-NIL, else DSMR_WORKER_RESUME_TIMEOUT, else
120. The pool calls this whenever it starts."
  (setf *resolved-worker-resume-timeout*
        (or *worker-resume-timeout*
            (%env-seconds "DSMR_WORKER_RESUME_TIMEOUT" 120))))

(defun effective-worker-resume-timeout ()
  "The resume handshake timeout in seconds as last resolved, resolving it
first when nothing has."
  (or *resolved-worker-resume-timeout* (resolve-worker-resume-timeout)))

(defvar *worker-core* nil
  "Path of a worker core image to boot workers from, or NIL to read
DSMR_WORKER_CORE. A non-NIL value wins over the environment; tests use it to
offer a core without touching the process environment.")

(defvar *worker-core-disabled* nil
  "NIL, or a string saying why the worker core stopped being offered.

spawn-worker sets it when a worker fails to boot from the core. From then on
worker-core-path answers NIL, so this process loads every later worker from
source instead of failing on the same image again.")

(defvar *worker-core-unavailable-logged* nil
  "True once this process has logged why it spawns workers from source, so the
reason is reported once rather than on every spawn.")

(defun %regular-file-p (path)
  "True when PATH names an existing regular file."
  (handler-case
      (sb-posix:s-isreg (sb-posix:stat-mode (sb-posix:stat path)))
    (error () nil)))

(defun %offered-core (path)
  "Judge PATH as a worker core to boot from. Returns (values PATH NIL) when it
names an existing regular file, else (values NIL REASON) where REASON is
\"unset\" or \"missing <path>\"."
  (let ((p (and path (namestring path))))
    (cond ((or (null p) (zerop (length p))) (values nil "unset"))
          ((%regular-file-p p) (values p nil))
          (t (values nil (format nil "missing ~A" p))))))

(defun worker-core-path ()
  "The worker core image a new worker should boot from, or NIL when workers
load from source. Returns a second value, the reason, when the answer is NIL.

*worker-core* wins when non-NIL, else DSMR_WORKER_CORE; either way the path is
used only when it names an existing regular file. Once a worker has failed to
boot from the core (*worker-core-disabled*) this answers NIL for the rest of
the process. The launcher sets DSMR_WORKER_CORE only when the image is fresh."
  (if *worker-core-disabled*
      (values nil (format nil "disabled ~A" *worker-core-disabled*))
      (%offered-core (or *worker-core* (uiop:getenv "DSMR_WORKER_CORE")))))

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
  ;; Where the worker is in its life:
  ;;   :standby      spawned and waiting for a session;
  ;;   :bound        serving one session;
  ;;   :hibernating  saving its world to a core, so no call may reach it;
  ;;   :hibernated   its world is on disk and its process is gone;
  ;;   :resuming     a process is being started from its saved core;
  ;;   :crashed      its channel failed and it is being replaced;
  ;;   :released     taken out of service on purpose (session end, kill, stop);
  ;;   :dead         its process has been terminated.
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
  (last-exit-code nil)
  ;; How this worker came up: :core when booted from the worker core, :source
  ;; when its systems were loaded at spawn, :resumed when started from a core
  ;; a worker saved of itself. spawn-worker writes both once.
  (boot-kind nil)
  ;; Milliseconds from process launch to an authenticated connection.
  (boot-milliseconds nil)
  ;; Liveness, kept beside the worker it describes so a status read never has
  ;; to correlate two structures. :unknown until something has actually asked
  ;; the worker a question; the pool's health monitor owns every write here.
  (liveness :unknown :type keyword)
  (liveness-basis nil)
  (last-ping-milliseconds nil)
  (consecutive-missed-pings 0 :type integer)
  (liveness-checked-at nil)
  ;; True once the pool has sent this worker a call that can leave state
  ;; behind in its image. The pool counts every call except a ping and the
  ;; three read-only code-intelligence calls, which is wider than strictly
  ;; needed on purpose: a worker wrongly thought stateful is hibernated rather
  ;; than stopped, and that costs disk, never a session's work.
  (stateful-p nil :type boolean)
  ;; Unix seconds at which the worker authenticated, and at which it was last
  ;; handed to a call or handed back. last-activity starts at spawned-at, so a
  ;; live worker always has one.
  (spawned-at nil)
  (last-activity nil)
  ;; Calls currently holding this worker. The pool's acquire and release own it.
  (in-flight 0 :type integer)
  ;; The DSMR_PROJECT_ROOT the worker was started with, or NIL.
  (spawn-root nil)
  ;; The saved world: where it is, when it was written, how large it is, and
  ;; how long the last save and the last resume took.
  (hibernate-core-path nil)
  (hibernated-at nil)
  (core-bytes nil)
  (last-hibernate-milliseconds nil)
  (last-resume-milliseconds nil)
  ;; Why the last request to hibernate this worker was refused, and when.
  (refused-reason nil)
  (refused-at nil)
  ;; Why the session's previous worker was lost, when it was lost for a reason
  ;; other than a crash. The session's reset notice carries it.
  (reset-reason nil)
  ;; The runtime executable this worker's process was started with, as an
  ;; absolute path, and that file's identity when it started (see
  ;; runtime-identity). A core the worker saves can only be resumed by the
  ;; same runtime build, so a resume starts from this one.
  (runtime-path nil)
  (runtime-identity nil)
  ;; Why the last resume of this worker's saved world failed in a way worth
  ;; retrying, while its core is still on disk; NIL while a new resume runs
  ;; and once one succeeds.
  (resume-failure nil)
  ;; How many resumes of this worker's saved world in a row have failed in a
  ;; way worth retrying; 0 once a resume succeeds.
  (resume-deferrals 0 :type integer))

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
  ((message :initarg :message :reader worker-spawn-failed-message)
   (kind :initarg :kind :initform :other :reader worker-spawn-failed-kind))
  (:report (lambda (c s)
             (format s "Failed to spawn worker: ~A"
                     (worker-spawn-failed-message c))))
  (:documentation "A worker could not be brought up. KIND says how, so a caller
can tell a failure worth retrying from one that will never succeed:
  :launch        the process could not be started (fork or exec failed);
  :timeout       no handshake arrived in time;
  :exited        the process ended before its handshake;
  :rejected      the runtime refused the core it was given;
  :runtime-gone  the runtime a saved core needs is no longer installed;
  :no-core       there is no saved core to start from;
  :connect, :auth, :other  the channel could not be set up."))

(defun worker-spawn-failure-final-p (condition)
  "True when CONDITION says a saved world can never be resumed as things stand:
the runtime refused the core, the runtime that wrote it is gone, or there is
no core. Every other failure, a timeout, a fork that failed for memory, a
process killed while it loaded, may succeed when tried again."
  (and (typep condition 'worker-spawn-failed)
       (member (worker-spawn-failed-kind condition)
               '(:rejected :runtime-gone :no-core))
       t))

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

(define-condition worker-unresponsive (error)
  ((worker :initarg :worker :reader worker-unresponsive-worker)
   (seconds :initarg :seconds :reader worker-unresponsive-seconds))
  (:report (lambda (c s)
             (format s "Worker ~A (PID ~A) left a liveness ping unanswered for ~As. ~
Its channel was left open and it was left in service; only a run of unanswered ~
pings retires it."
                     (worker-id (worker-unresponsive-worker c))
                     (worker-pid (worker-unresponsive-worker c))
                     (worker-unresponsive-seconds c))))
  (:documentation "A liveness ping went unanswered within its deadline.

Distinct from WORKER-CRASHED, and the distinction is the whole point: crashed
means the channel is gone and the worker with it, while this means the worker
did not answer in time and nothing has been concluded from that yet. One silence
is the ordinary shape of a garbage collection pause. The caller decides how many
in a row stop looking like a pause."))

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

(defun %unix-now ()
  "The current time in whole Unix seconds."
  (- (get-universal-time) (encode-universal-time 0 0 0 1 1 1970 0)))

;;; ---------------------------------------------------------------------------
;;; Internal helpers — secret generation
;;; ---------------------------------------------------------------------------

(defun %generate-worker-secret ()
  "Generate a 128-bit random hex secret for worker TCP authentication.

The bits come from /dev/urandom. Every server starts from the same image, and
SBCL starts every process with the same global random state, so a secret drawn
from that state would be the same in every server; when the device cannot be
read, a random state freshly seeded from the system is used instead."
  (let ((n (handler-case
               (with-open-file (in "/dev/urandom" :element-type '(unsigned-byte 8))
                 (let ((bytes (make-array 16 :element-type '(unsigned-byte 8))))
                   (unless (= 16 (read-sequence bytes in))
                     (error "short read from /dev/urandom"))
                   (reduce (lambda (acc b) (logior (ash acc 8) b)) bytes
                           :initial-value 0)))
             (error ()
               (random (expt 2 128) (make-random-state t))))))
    (format nil "~32,'0X" n)))

;;; ---------------------------------------------------------------------------
;;; Internal helpers — environment
;;; ---------------------------------------------------------------------------

(defparameter *worker-env-denylist*
  '("DSMR_WORKER_SECRET" "DSMR_WORKER_ID" "DSMR_PARENT_PID")
  "Environment variables that must NOT be inherited from the parent.
These are set explicitly per-worker to the correct per-worker values.")

(defun %build-environment (secret id &key root)
  "Build the environment for worker processes.
Inherits the parent's full environment, adding DSMR-specific variables
and excluding only those that would conflict with per-worker overrides.
When ROOT is non-NIL, DSMR_PROJECT_ROOT is set to it in place of any
inherited value, so a resumed worker sees the project root its session had."
  (let ((env (list (format nil "DSMR_WORKER_SECRET=~A" secret)
                   (format nil "DSMR_WORKER_ID=~A" id)
                   (format nil "DSMR_PARENT_PID=~A" (sb-posix:getpid))
                   "DSMR_NO_WORKER_POOL=1")))
    (when root
      (push (format nil "DSMR_PROJECT_ROOT=~A" root) env))
    ;; Inherit all parent environment variables except those that
    ;; conflict with per-worker overrides set above.
    (dolist (entry (sb-ext:posix-environ))
      (let ((eq-pos (position #\= entry)))
        (when eq-pos
          (let ((name (subseq entry 0 eq-pos)))
            (unless (or (member name *worker-env-denylist* :test #'string=)
                        (string= name "DSMR_NO_WORKER_POOL")
                        (and root (string= name "DSMR_PROJECT_ROOT")))
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

(defun %executable-file-p (native)
  "True when NATIVE names a regular file this process may execute."
  (handler-case
      (and (sb-posix:s-isreg (sb-posix:stat-mode (sb-posix:stat native)))
           (progn (sb-posix:access native sb-posix:x-ok) t))
    (error () nil)))

(defun %resolve-executable (name)
  "NAME as the absolute path of the file that would run, looked up through PATH
the way a shell would when NAME holds no slash, or NAME itself when nothing
matches. Workers are started from the resolved path, so the runtime a worker
ran is exactly the one recorded on it."
  (cond ((find #\/ name)
         (if (char= (char name 0) #\/)
             name
             (uiop:native-namestring (merge-pathnames name (uiop:getcwd)))))
        (t
         (or (loop for dir in (uiop:split-string (or (uiop:getenv "PATH") "")
                                                 :separator ":")
                   for candidate = (and (plusp (length dir))
                                        (concatenate 'string
                                                     (string-right-trim "/" dir)
                                                     "/" name))
                   when (and candidate (%executable-file-p candidate))
                     return candidate)
             name))))

(defun runtime-identity (path)
  "The identity of the executable file at PATH, following links: a list of its
device, inode, size and modification time, or NIL when it cannot be read. Two
equal identities name the same file, so a runtime package upgraded in place,
which writes a new file, never compares equal to the one it replaced."
  (handler-case
      (let ((st (sb-posix:stat path)))
        (list (sb-posix:stat-dev st) (sb-posix:stat-ino st)
              (sb-posix:stat-size st) (sb-posix:stat-mtime st)))
    (error () nil)))

(defun resume-runtime (worker)
  "The runtime to resume WORKER's saved core with, and why, as two values.

A core can only be resumed by the runtime build that wrote it, which is the
one WORKER's process ran. In order:
  the recorded runtime path, while the file there is still the same one
    (:recorded);
  this server's own executable, through /proc/<pid>/exe, when it is that same
    file, as after the package was upgraded under a running server (:server);
  the recorded path anyway when a different file is there now (:changed); if
    it is another build it refuses the core, and that refusal is final;
  the runtime this process starts fresh workers with, when nothing was
    recorded (:unrecorded).
Returns (values NIL :gone) when the recorded runtime is gone and nothing else
is that same file."
  (let ((path (worker-runtime-path worker))
        (identity (worker-runtime-identity worker))
        (own (format nil "/proc/~D/exe" (sb-posix:getpid))))
    (cond ((null path)
           (values (%resolve-executable (%find-sbcl-path)) :unrecorded))
          ((and identity (equal identity (runtime-identity path)))
           (values path :recorded))
          ((and identity (equal identity (runtime-identity own)))
           (values own :server))
          ((%executable-file-p path)
           (values path :changed))
          (t (values nil :gone)))))

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

(defun %build-sbcl-args (&key core hibernated-core)
  "Build command-line arguments for spawning a worker via bare SBCL.

With HIBERNATED-CORE, the path of a core a worker saved of itself, the
arguments are only the image and --noinform: the image's own entry point
resumes the worker, and CORE is ignored.

With CORE, the path of a worker core image, the worker boots from that image,
which already holds the worker system, so nothing is loaded before start. The
image carries the source registry as it stood when it was built; the arguments
discard it, so the worker sees the workspace as it is now, and add this project
directory to the central registry, so the project's systems are found even
when it sits outside the configured registry. Discarding rather than
re-scanning matters: a scan of a large workspace takes seconds, and ASDF
repeats it lazily at the worker's first system lookup instead of before its
handshake. Without CORE the worker loads its systems from source as described
below.

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
  (when hibernated-core
    ;; A core a worker saved of itself carries its own entry point, which
    ;; redoes everything the arguments below would, so nothing is passed but
    ;; the image and the runtime's banner switch.
    (return-from %build-sbcl-args
      (list "--core" (namestring hibernated-core) "--noinform")))
  (let ((source-dir (namestring (asdf:system-source-directory :dsmr-mcp)))
        (ql-setup (%quicklisp-setup-path)))
    (when core
      (return-from %build-sbcl-args
        (list "--core" (namestring core)
              "--noinform" "--disable-debugger" "--no-userinit"
              "--eval" (format nil
                               "(progn (asdf:clear-source-registry) (pushnew (pathname ~S) asdf:*central-registry* :test (function equal)))"
                               source-dir)
              "--eval" "(dsmr-mcp/src/hermetic/worker/main:start)")))
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

(defun %launch-worker-process (secret id &key core hibernated-core root runtime)
  "Launch a worker child process via sb-ext:run-program: resumed from the
saved core HIBERNATED-CORE when given, else booted from the worker core image
CORE when given, else loaded from source. ROOT, when non-NIL, replaces the
inherited DSMR_PROJECT_ROOT. RUNTIME, when non-NIL, is the runtime executable
to start; otherwise it is the one this process runs, resolved through PATH.
Returns two values: the sb-ext:process object with stdout and stderr as
streams, and the absolute path of the runtime started.
Always uses bare SBCL; dsmr-mcp is SBCL-only (no ros run wrapper)."
  (let ((env (%build-environment secret id :root root))
        (sbcl-path (or runtime (%resolve-executable (%find-sbcl-path)))))
    (values (sb-ext:run-program sbcl-path
                                (%build-sbcl-args :core core
                                                  :hibernated-core hibernated-core)
                                :output :stream :error :stream :wait nil
                                :search t :environment env)
            sbcl-path)))

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
                 :kind :exited
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
Signals WORKER-SPAWN-FAILED of kind :timeout on timeout, or of kind :exited
when stdout is closed before a valid handshake is found."
  (let ((stdout (sb-ext:process-output process)))
    (handler-case
        (sb-ext:with-timeout timeout
          (%parse-handshake-from-stream stdout))
      (sb-ext:timeout ()
        (error 'worker-spawn-failed
               :kind :timeout
               :message (format nil "Worker handshake timed out after ~As"
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
Signals SIMPLE-ERROR for protocol-level failures (parse errors, ID mismatches).

A response whose id is LOWER than ID is the late answer to an earlier request
whose caller already stopped waiting. It is discarded and the read continues,
because it is not evidence of corruption: it is evidence the worker is behind,
which is a different fact and one a caller may want to survive. Without this,
any caller that ever gives up waiting poisons the channel for the next one, and
a worker that catches up is condemned for answering late.

A response whose id is at or above ID has no such explanation. Nothing on this
channel can legitimately answer a request that has not been sent, so that
remains a protocol error and still condemns the stream."
  (flet ((do-read ()
           (loop
             (let ((line (%read-line-limited stream nil +max-json-line-bytes+)))
               (unless line
                 (error 'end-of-file :stream stream))
               (let ((json (com.inuoe.jzon:parse line)))
                 (unless (hash-table-p json)
                   (error "Invalid JSON-RPC response: not an object"))
                 (let ((resp-id (gethash "id" json)))
                   (cond
                     ;; Late answer to an abandoned request; drop it and keep reading.
                     ((and (integerp resp-id) (integerp id) (< resp-id id)))
                     ((not (eql resp-id id))
                      (error "JSON-RPC response ID mismatch: expected ~A, got ~A"
                             id resp-id))
                     (t
                      ;; Check for error: signal a typed condition for worker errors
                      (let ((err (gethash "error" json)))
                        (when err
                          (error 'worker-rpc-error
                                 :code (gethash "code" err)
                                 :message (gethash "message" err))))
                      ;; Return the result
                      (return (gethash "result" json))))))))))
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

(defun %spawn-root (root)
  "The project root a worker launched with ROOT sees: ROOT when given, else
the DSMR_PROJECT_ROOT this process passes on, else NIL."
  (or root
      (let ((inherited (uiop:getenv "DSMR_PROJECT_ROOT")))
        (and inherited (plusp (length inherited)) inherited))))

(defun %early-exit-report (process)
  "How PROCESS, which closed its stdout before its handshake, ended: three
values, :exited or :signaled (NIL when it has not ended within two seconds),
the exit code or signal number, and up to 4096 characters of what it wrote to
stderr. Reads nothing while the process is still running."
  (let ((status nil) (code nil) (text ""))
    (ignore-errors
     (loop repeat 20
           while (sb-ext:process-alive-p process)
           do (sleep 0.1))
     (setf status (sb-ext:process-status process))
     (when (member status '(:exited :signaled))
       (setf code (sb-ext:process-exit-code process))
       (let ((err (sb-ext:process-error process))
             (out (make-string-output-stream)))
         (when err
           (handler-case
               (sb-ext:with-timeout 1
                 (loop for ch = (read-char err nil nil)
                       for n from 0
                       while (and ch (< n 4096))
                       do (write-char ch out)))
             (error () nil))
           (setf text (get-output-stream-string out))))))
    (values (and (member status '(:exited :signaled)) status) code text)))

(defun %transient-read-failure-p (low)
  "True when LOW, lower-cased runtime output, says the core could not be
opened or read for a reason that has nothing to do with the core: out of
descriptors, out of memory, an interrupted call or an I/O error. SBCL reports
a failed open with the system's error text and a failed read with the error
number, so both forms are recognised."
  (or (some (lambda (needle) (search needle low))
            '("too many open files" "interrupted system call" "input/output error"))
      (let ((at (search "errno = " low)))
        (and at
             (member (parse-integer low :start (+ at (length "errno = "))
                                        :junk-allowed t)
                     (list sb-posix:eintr sb-posix:eio sb-posix:enomem
                           sb-posix:enfile sb-posix:emfile))
             t))))

(defun %core-rejection-p (text)
  "True when TEXT, what a runtime printed before exiting, says it refused the
core it was given: the wrong build, a bad magic number, a truncated file or one
it could not open. A runtime that could not get memory for the heap is not
refusing the core and is left out, since it may succeed later, and so is one
that could not open or read the file for a passing reason such as running out
of descriptors (%transient-read-failure-p)."
  (let ((low (string-downcase (or text ""))))
    (and (some (lambda (needle) (search needle low))
               '("core was built for" "magic number in core" "core file"
                 "could not open file" "not a core"))
         (notany (lambda (needle) (search needle low))
                 '("allocate" "memory" "mmap"))
         (not (%transient-read-failure-p low))
         t)))

(defun %last-line (text)
  "The last non-blank line of TEXT, trimmed and cut to 200 characters."
  (let* ((lines (remove-if (lambda (line) (zerop (length (string-trim " " line))))
                           (uiop:split-string (or text "")
                                              :separator (string #\Newline))))
         (line (string-trim " " (or (car (last lines)) ""))))
    (if (> (length line) 200) (subseq line 0 200) line)))

(defun %spawn-worker-once (core &key hibernated-core id root runtime)
  "Launch one worker child process and return a WORKER struct, resuming it
from the saved core HIBERNATED-CORE when given, else booting it from the
worker core image CORE when non-NIL, else loading it from source. ID, when
non-NIL, is the worker id to use instead of a new one; ROOT, when non-NIL,
replaces the inherited DSMR_PROJECT_ROOT; RUNTIME, when non-NIL, is the
runtime executable to start instead of the one this process runs.
The worker is launched via sb-ext:run-program (bare SBCL only).
Reads the JSON handshake to discover tcp_port/pid/swank_port, connects
to the TCP port, authenticates with a shared secret, and returns the
worker in :standby state, with the runtime it was started with recorded.
A resumed worker is given the resume handshake budget, a fresh one the
startup budget.

Signals WORKER-SPAWN-FAILED if the process cannot be started,
the handshake fails, or authentication is rejected. Its kind says which
(see the condition); a process that ended before its handshake is reported
as :rejected when what it printed says the runtime refused the core."
  (let ((id (or id (%next-worker-id)))
        (kind (cond (hibernated-core :resumed) (core :core) (t :source)))
        (secret (%generate-worker-secret))
        (process nil)
        (runtime-path nil)
        (socket nil)
        (started (get-internal-real-time)))
    (handler-case
        (progn
          (log-event :info "worker.spawning" "id" id
                     "boot" (string-downcase (symbol-name kind)))
          (setf started (get-internal-real-time))
          (handler-case
              (multiple-value-setq (process runtime-path)
                (%launch-worker-process secret id
                                        :core core
                                        :hibernated-core hibernated-core
                                        :root root
                                        :runtime runtime))
            (error (e)
              (error 'worker-spawn-failed
                     :kind :launch
                     :message (princ-to-string e))))
          (multiple-value-bind (tcp-port pid swank-port)
              (%read-handshake process (if hibernated-core
                                           (effective-worker-resume-timeout)
                                           (effective-worker-startup-timeout)))
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
            (setf socket
                  (handler-case (%connect-to-worker "127.0.0.1" tcp-port)
                    (error (e)
                      (error 'worker-spawn-failed
                             :kind :connect
                             :message (princ-to-string e)))))
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
                         :kind :auth
                         :message "Worker authentication failed"))))
            (let* ((now (%unix-now))
                   (worker (make-worker
                            :id id
                            :state :standby
                            :spawned-at now
                            :last-activity now
                            :spawn-root (%spawn-root root)
                            :runtime-path runtime-path
                            :runtime-identity (runtime-identity runtime-path)
                            :process-info process
                            :stream (usocket:socket-stream socket)
                            :socket socket
                            :tcp-port tcp-port
                            :swank-port swank-port
                            :pid pid
                            :boot-kind kind
                            :boot-milliseconds
                            (round (* 1000 (- (get-internal-real-time) started))
                                   internal-time-units-per-second))))
              (%start-stderr-drain worker)
              (log-event :info "worker.spawned"
                         "id" id
                         "tcp_port" tcp-port
                         "pid" pid
                         "boot" (string-downcase (symbol-name kind))
                         "boot_ms" (worker-boot-milliseconds worker))
              worker)))
      (error (e)
        (let ((failure (if (typep e 'worker-spawn-failed)
                           e
                           (make-condition 'worker-spawn-failed
                                           :message (princ-to-string e)))))
          ;; A process that ended before its handshake says why on stderr;
          ;; read it before the cleanup below closes the pipe.
          (when (and process (eq (worker-spawn-failed-kind failure) :exited))
            (multiple-value-bind (status code text) (%early-exit-report process)
              (let ((line (%last-line text)))
                (setf failure
                      (make-condition
                       'worker-spawn-failed
                       :kind (if (and (eq status :exited) (%core-rejection-p text))
                                 :rejected
                                 :exited)
                       :message (format nil "~A (~(~A~) ~A)~@[: ~A~]"
                                        (worker-spawn-failed-message failure)
                                        (or status "still running")
                                        (or code "")
                                        (and (plusp (length line)) line)))))))
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
                     "kind" (string-downcase
                             (symbol-name (worker-spawn-failed-kind failure)))
                     "error" (princ-to-string failure))
          (error failure))))))

(defun spawn-worker (&key (core nil core-p) hibernated-core id root runtime)
  "Launch a worker child process and return a WORKER struct in :standby state.

CORE is the worker core image to boot from; when it is not given,
worker-core-path decides. A worker from the core starts in a fraction of a
second, against tens of seconds to load its systems from source, which is why
the pool can afford to spawn on demand and keep nothing warm.

When no usable core is offered the worker loads from source, and the reason is
logged once per process as worker.core.unavailable. When a core is offered but
the worker fails to boot from it, the failure is logged as a warning,
*worker-core-disabled* records it so this process does not try the core again,
and the spawn is retried once from source.

HIBERNATED-CORE is a core a worker saved of itself. Given one, the worker is
resumed from it with everything its session had built, CORE is ignored, and
there is no retry from source: a fresh worker would silently stand in for the
session's world, so a resume that fails signals instead and the caller decides.
ID is the worker id to give the new process (a resumed worker keeps the id it
had), and ROOT, when non-NIL, is the project root to give it in place of the
inherited DSMR_PROJECT_ROOT. RUNTIME, used only with HIBERNATED-CORE, is the
runtime executable to resume it with (see resume-runtime).

worker-boot-kind on the result says which way it came up (:core, :source or
:resumed), and worker-boot-milliseconds how long it took. Signals
WORKER-SPAWN-FAILED when the worker cannot be brought up at all."
  (when hibernated-core
    (unless (%regular-file-p (namestring hibernated-core))
      (error 'worker-spawn-failed
             :kind :no-core
             :message (format nil "no saved core at ~A" hibernated-core)))
    (return-from spawn-worker
      (%spawn-worker-once nil :hibernated-core (namestring hibernated-core)
                              :id id :root root :runtime runtime)))
  (multiple-value-bind (path reason)
      (if core-p
          (if core (%offered-core core) (values nil "not requested"))
          (worker-core-path))
    (cond
      (path
       (handler-case (%spawn-worker-once path :id id :root root)
         (worker-spawn-failed (e)
           (let ((why (princ-to-string e)))
             (log-event :warn "worker.core.boot-failed"
                        "core" path
                        "error" why)
             (setf *worker-core-disabled* why)
             (%spawn-worker-once nil :id id :root root)))))
      (t
       (unless *worker-core-unavailable-logged*
         (setf *worker-core-unavailable-logged* t)
         (log-event :info "worker.core.unavailable" "reason" reason))
       (%spawn-worker-once nil :id id :root root)))))

(defun resume-worker (worker)
  "Bring WORKER, whose world is saved at its hibernate-core-path, back to life
from that core and return WORKER.

The worker stays the same struct with the same id, session, stateful flag and
last activity, so the session keeps the worker it had and every object id
issued before the save still names it. Only what belongs to a process is
replaced: the process, its channel, its ports and pid, its stderr drain, the
runtime it runs and how it booted, which reads :resumed.
last-resume-milliseconds records how long the resume took. The worker's state
is left to the caller.

The core is resumed with the runtime build that wrote it, as resume-runtime
chooses, and the handshake gets the resume budget.

Signals WORKER-SPAWN-FAILED when no core is recorded or the file is gone
(kind :no-core), when the runtime that wrote it is gone (:runtime-gone), or
when no process comes up from it; worker-spawn-failure-final-p tells a refused
core from a failure worth retrying. WORKER is untouched in every case."
  (let ((path (worker-hibernate-core-path worker))
        (started (get-internal-real-time)))
    (unless path
      (error 'worker-spawn-failed
             :kind :no-core
             :message (format nil "worker ~D has no saved core recorded"
                              (worker-id worker))))
    (multiple-value-bind (runtime basis) (resume-runtime worker)
      (unless runtime
        (error 'worker-spawn-failed
               :kind :runtime-gone
               :message (format nil "the runtime that saved it, ~A, is no longer installed"
                                (worker-runtime-path worker))))
      (let ((fresh (spawn-worker :hibernated-core path
                                 :id (worker-id worker)
                                 :root (worker-spawn-root worker)
                                 :runtime runtime))
            (milliseconds nil))
        (setf milliseconds (round (* 1000 (- (get-internal-real-time) started))
                                  internal-time-units-per-second))
        (bt:with-lock-held ((worker-stream-lock worker))
          (setf (worker-process-info worker) (worker-process-info fresh)
                (worker-stream worker) (worker-stream fresh)
                (worker-socket worker) (worker-socket fresh)
                (worker-tcp-port worker) (worker-tcp-port fresh)
                (worker-swank-port worker) (worker-swank-port fresh)
                (worker-pid worker) (worker-pid fresh)
                (worker-stderr-thread worker) (worker-stderr-thread fresh)
                (worker-runtime-path worker) (worker-runtime-path fresh)
                (worker-runtime-identity worker) (worker-runtime-identity fresh)
                (worker-boot-kind worker) :resumed
                (worker-boot-milliseconds worker) (worker-boot-milliseconds fresh)
                (worker-consecutive-missed-pings worker) 0
                (worker-last-resume-milliseconds worker) milliseconds))
        (log-event :info "worker.resumed"
                   "id" (worker-id worker)
                   "pid" (worker-pid worker)
                   "runtime" runtime
                   "runtime_basis" (string-downcase (symbol-name basis))
                   "ms" milliseconds)
        worker))))

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

(defun worker-ping (worker &key timeout (eligible-p (constantly t)))
  "Ask WORKER the liveness question and return the round trip in milliseconds.

WORKER-RPC treats a timeout as a crash, and for a general call that is right:
the caller has given up on an answer that may still be in flight, so the channel
can no longer be trusted. A probe cannot afford that verdict. A single missed
ping is the ordinary shape of a garbage collection pause, and retiring an idle
worker for one buys nothing and costs a respawn.

So this leaves the late answer to be handled rather than feared:
%READ-JSON-RPC-RESPONSE discards answers older than the request it is waiting
for, which is what lets a worker that catches up be read correctly on the next
probe instead of being condemned for answering late.

Signals WORKER-UNRESPONSIVE when no answer arrives within TIMEOUT seconds,
leaving the worker's state, stream and socket exactly as they were so the caller
decides what a run of silences means.

Signals WORKER-CRASHED for the failures that admit no second opinion: a channel
already closed, an end of file, a stream error, or an answer that cannot be
parsed. Those mark the worker crashed here, as WORKER-RPC does.

ELIGIBLE-P is called with WORKER once the stream lock is held and before
anything else is looked at. When it answers NIL nothing is sent and this
returns :skipped. A ping can wait on the lock behind a save, and by the time it
gets the lock the worker may have saved its world and closed its channel; the
check lets the caller say, at that moment, whether the worker is still one it
means to probe, so a finished save is never read as a crash."
  (bt:with-lock-held ((worker-stream-lock worker))
    (unless (funcall eligible-p worker)
      (return-from worker-ping :skipped))
    (unless (worker-stream worker)
      (error 'worker-crashed :worker worker :reason "already-dead"))
    (let ((id (incf (worker-request-counter worker)))
          (start (get-internal-real-time)))
      (handler-case
          (progn
            (%send-json-rpc (worker-stream worker) id "worker/ping"
                            (make-hash-table :test 'equal))
            (%read-json-rpc-response (worker-stream worker) id timeout)
            (round (* 1000 (- (get-internal-real-time) start))
                   internal-time-units-per-second))
        (sb-ext:timeout ()
          (error 'worker-unresponsive :worker worker :seconds timeout))
        (end-of-file ()
          (%mark-worker-crashed worker "eof")
          (error 'worker-crashed :worker worker :reason "eof"))
        (stream-error ()
          (%mark-worker-crashed worker "stream-error")
          (error 'worker-crashed :worker worker :reason "stream-error"))
        (worker-rpc-error (e)
          ;; The worker answered, badly. That is still an answer, so it is
          ;; re-signalled without condemning the channel.
          (error e))
        (error (e)
          (%mark-worker-crashed worker (format nil "protocol-error: ~A" e))
          (error 'worker-crashed :worker worker
                 :reason (format nil "protocol-error: ~A" e)))))))

(defun hibernate-refusal-token (message)
  "The reason word at the start of a worker's refusal to hibernate, such as
\"has-threads\" or \"bad-path\", taken from the error MESSAGE it sent.

The worker writes its refusal as the word, a colon and the detail, and its
server puts \"Internal error: \" in front of every handler error. The prefix is
removed first, on purpose, so the word read is the worker's and not the
server's. Returns the whole trimmed message when it carries no colon."
  (let* ((prefix "Internal error: ")
         (text (string-trim '(#\Space) (or message "")))
         (body (if (and (>= (length text) (length prefix))
                        (string= prefix text :end2 (length prefix)))
                   (subseq text (length prefix))
                   text))
         (colon (position #\: body)))
    (string-trim '(#\Space) (if colon (subseq body 0 colon) body))))

(defun hibernate-worker-process (worker path
                                 &key (timeout *hibernate-timeout-seconds*)
                                      (deadline (hibernate-save-deadline timeout))
                                      (grace *hibernate-late-answer-seconds*))
  "Ask WORKER to save its whole world to the core file PATH, and say how it went.

Returns one of:
  (values :hibernated RESULT)      the core is written; RESULT is the worker's
                                   reply, with \"path\", \"bytes\" and
                                   \"milliseconds\". The worker closes its
                                   channel after answering.
  (values :refused TOKEN MESSAGE)  the worker declined and is still serving;
                                   TOKEN is its reason word (see
                                   hibernate-refusal-token), MESSAGE the text.
  (values :timeout NIL)            no answer within TIMEOUT seconds, nor in
                                   the GRACE seconds after; the worker's
                                   state, stream and socket are left exactly
                                   as they were.
  (values :died NIL)               the channel ended or broke before an answer
                                   came, or the answer could not be read, so
                                   the worker cannot be trusted to be serving.

DEADLINE is the worker's own limit on the save, sent with the request. By
default it is TIMEOUT less *hibernate-answer-margin-seconds*, so the worker
answers well before this stops waiting. When TIMEOUT runs out regardless, the
channel is read for GRACE seconds more, and an answer that arrives then counts
as if it had come in time.

None of these outcomes marks the worker crashed. A successful save ends the
channel by design, and a worker killed for memory in the middle of a save has
not crashed in any sense the crash breaker should count; the caller decides
what each outcome means for the session. Signals WORKER-CRASHED with reason
\"already-dead\" only when the worker has no channel at all."
  (bt:with-lock-held ((worker-stream-lock worker))
    (unless (worker-stream worker)
      (error 'worker-crashed :worker worker :reason "already-dead"))
    (let ((id (incf (worker-request-counter worker)))
          (params (make-hash-table :test 'equal)))
      (setf (gethash "path" params) (uiop:native-namestring path)
            (gethash "deadline_seconds" params) deadline)
      (flet ((outcome (thunk)
               (handler-case
                   (values :hibernated (funcall thunk))
                 (worker-rpc-error (e)
                   (let ((message (or (worker-rpc-error-message e) "")))
                     (values :refused (hibernate-refusal-token message) message)))
                 (sb-ext:timeout ()
                   (values :timeout nil))
                 (end-of-file ()
                   (values :died nil))
                 (stream-error ()
                   (values :died nil))
                 (error (e)
                   (log-event :warn "worker.hibernate.unreadable-answer"
                              "id" (worker-id worker)
                              "error" (princ-to-string e))
                   (values :died nil)))))
        (multiple-value-bind (result detail message)
            (outcome (lambda ()
                       (%send-json-rpc (worker-stream worker) id "worker/hibernate"
                                       params)
                       (%read-json-rpc-response (worker-stream worker) id timeout)))
          (if (and (eq result :timeout) grace (plusp grace))
              (progn
                (log-event :warn "worker.hibernate.answer-late"
                           "id" (worker-id worker)
                           "timeout_seconds" timeout
                           "grace_seconds" grace)
                (outcome (lambda ()
                           (%read-json-rpc-response (worker-stream worker) id
                                                    grace))))
              (values result detail message)))))))

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

(defvar *stream-lock-grace-seconds* 2
  "How long ending a worker waits for its channel to be free before it ends
the process outright. A call or a save can hold the channel for minutes, and
nothing that is ending the worker should wait that long behind it.")

(defun end-worker-process (worker &key (grace 2))
  "End WORKER's process now, without waiting for its channel. Sends SIGTERM,
which a worker in the middle of a save answers by ending the save and
deleting its partial core, waits up to GRACE seconds, then sends SIGKILL, and
shuts the channel down so a thread reading it, such as one waiting on a save,
gets end-of-file at once instead of at its deadline. The socket itself is
left for release-worker-process to close. The worker's state is left alone.
Safe on a worker whose process has already gone."
  (let ((process (worker-process-info worker)))
    (when process
      (handler-case
          (when (sb-ext:process-alive-p process)
            (sb-ext:process-kill process 15)
            (loop repeat (ceiling grace 0.05)
                  while (sb-ext:process-alive-p process)
                  do (sleep 0.05))
            (when (sb-ext:process-alive-p process)
              (log-event :warn "worker.sigkill"
                         "id" (worker-id worker)
                         "pid" (worker-pid worker)
                         "reason" "ending")
              (sb-ext:process-kill process 9)))
        (error (e)
          (log-event :warn "worker.end.error"
                     "id" (worker-id worker)
                     "error" (princ-to-string e))))))
  (let ((socket (worker-socket worker)))
    (when socket
      (ignore-errors (usocket:socket-shutdown socket :io))))
  worker)

(defun %call-with-stream-lock-or-end (worker function)
  "Call FUNCTION holding WORKER's stream lock. When the lock is not free within
*stream-lock-grace-seconds*, whatever holds it (a call or a save) is cut off
first: the process is ended with end-worker-process, which makes the holder
read end-of-file and let go. Ending a worker therefore never waits on a save
or a long call."
  (let ((lock (worker-stream-lock worker))
        (limit (+ (get-internal-real-time)
                  (* *stream-lock-grace-seconds* internal-time-units-per-second))))
    (loop until (bt:acquire-lock lock nil)
          do (when (>= (get-internal-real-time) limit)
               (log-event :warn "worker.channel-busy"
                          "id" (worker-id worker)
                          "pid" (worker-pid worker))
               (end-worker-process worker :grace 0)
               (bt:acquire-lock lock t)
               (return))
             (sleep 0.02))
    (unwind-protect (funcall function)
      (bt:release-lock lock))))

(defun release-worker-process (worker)
  "Close WORKER's channel and end its process, leaving its state alone.
Closes the TCP socket under stream-lock for mutual exclusion with
concurrent worker-rpc calls. Sends SIGTERM first, waits up to 2
seconds, then SIGKILL if still alive.
Closes the worker's stderr pipe before waiting on the drain thread so
the thread exits cleanly (read-line returns NIL) without holding
*stderr-drain-lock*; falls back to destroy-thread only if the thread
has not exited after 1 s.
Robust against already-dead processes and safe to call twice.

The pool calls this directly when the state is its own to set, as after a
worker has saved its world and is to be recorded :hibernated rather than
:dead."
  (let ((process (worker-process-info worker)))
    ;; Close TCP socket under stream-lock first, so any concurrent
    ;; worker-rpc sees the closure as a stream-error.
    ;; A save or a call holding the lock past the grace is cut off by ending
    ;; the process, so this never waits minutes behind it.
    (%call-with-stream-lock-or-end
     worker
     (lambda ()
       (let ((socket (worker-socket worker)))
         (when socket
           (ignore-errors (usocket:socket-close socket))
           (setf (worker-socket worker) nil
                 (worker-stream worker) nil)))))
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
    worker))

(defun kill-worker (worker)
  "Terminate the worker process, clean up its resources and set its state to
:dead. The state is set under stream-lock, so a concurrent call that holds the
lock sees the worker as it was; the cleanup is release-worker-process.
When a call or a save holds the lock past *stream-lock-grace-seconds*, the
process is ended first so the holder lets go: killing a worker in the middle
of a save costs that save, never minutes of waiting.
Robust against already-dead processes."
  (log-event :info "worker.killing"
             "id" (worker-id worker)
             "pid" (worker-pid worker))
  (%call-with-stream-lock-or-end
   worker
   (lambda () (setf (worker-state worker) :dead)))
  (release-worker-process worker)
  (log-event :info "worker.killed"
             "id" (worker-id worker)
             "pid" (worker-pid worker))
  worker)

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
Returns T if the flag was set (and is now cleared), NIL otherwise. The second
value is the worker's reset reason, a sentence saying why the session's
previous worker was lost when that was not a crash, or NIL; it is cleared too.
Uses stream-lock for mutual exclusion with concurrent callers,
preventing the TOCTOU race where two threads both see the flag
as set and both return crash notifications."
  (bt:with-lock-held ((worker-stream-lock worker))
    (let ((reason (worker-reset-reason worker)))
      (setf (worker-reset-reason worker) nil)
      (if (worker-needs-reset-notification worker)
          (progn
            (setf (worker-needs-reset-notification worker) nil)
            (values t reason))
          (values nil reason)))))
