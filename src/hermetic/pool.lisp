;;;; src/hermetic/pool.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Worker pool manager with strict session affinity for dsmr-mcp.
;;;;
;;;; Design principles:
;;;; 1. Strict exclusive affinity: 1 session = 1 dedicated worker. No sharing.
;;;; 2. Scale-out: When standbys exhausted, spawn new workers on demand up to max.
;;;; 3. Warm standbys: Pool can pre-spawn workers ready for immediate
;;;;    assignment. Off unless DSMR_WORKER_POOL_WARMUP asks for some.
;;;; 4. Crash recovery: Detect crash, restart worker, arm reset notification.
;;;; 5. Explicit crash notification: Session gets ONE notification about
;;;;    crash/reset — the next call after that succeeds normally.
;;;; 6. Circuit breaker + 60s cool-down (dsmr-mcp addition over cl-mcp):
;;;;    After 3 crashes in 5 minutes the breaker trips; further calls for that
;;;;    session fail fast for 60 seconds.
;;;; 7. Parent hard-kill backstop: The in-worker sb-ext:with-timeout soft-kills
;;;;    the eval; the parent additionally SIGKILLs the worker after the soft
;;;;    timeout plus DSMR_WORKER_KILL_GRACE_SECONDS (default 5s) to cover
;;;;    runaway FFI that cannot be interrupted by the soft timeout.
;;;; 8. Workers are held while their session lives and are never reaped for
;;;;    idleness; under memory pressure an idle one may be hibernated or, when
;;;;    it holds no state, stopped.
;;;;
;;;; Thread safety — lock hierarchy (NEVER acquire in reverse order):
;;;;   *pool-lock* (global) -> placeholder.lock -> worker.stream-lock
;;;;
;;;; Ported from cl-mcp/src/pool.lisp (1166 lines); adaptation deltas:
;;;;   - DSMR_-prefixed env var names (not CL_MCP_*)
;;;;   - log4cl via log-event (not cl-mcp/src/log's log-stream)
;;;;   - No proxy/cancel machinery (verify-proxy-bindings, active-requests)
;;;;   - No project-root broadcast (send-root-to-session-worker, broadcast-root-to-workers)
;;;;   - +60s *circuit-breaker-map* cool-down (cl-mcp only removes the session)
;;;;   - Parent hard-kill backstop in pool-rpc-with-hard-kill

(defpackage #:dsmr-mcp/src/hermetic/pool
  (:use #:cl)
  (:import-from #:bordeaux-threads
                #:make-lock #:with-lock-held
                #:make-condition-variable #:condition-wait
                #:make-thread #:threadp #:thread-alive-p #:join-thread)
  (:import-from #:dsmr-mcp/src/hermetic/worker-client
                #:worker #:spawn-worker #:worker-rpc #:kill-worker
                #:signal-worker-terminate
                #:worker-state #:worker-session-id
                #:worker-needs-reset-notification
                #:worker-tcp-port #:worker-pid #:worker-id
                #:worker-process-info #:worker-crash-history-pushed-p
                #:worker-last-crash-reason #:worker-last-exit-status
                #:worker-last-exit-code
                #:mark-worker-crashed
                #:worker-ping #:worker-unresponsive
                #:worker-liveness #:worker-liveness-basis
                #:worker-last-ping-milliseconds
                #:worker-consecutive-missed-pings
                #:worker-liveness-checked-at
                #:*reaper-threads* #:*reaper-threads-lock*
                #:resolve-worker-startup-timeout
                #:effective-worker-startup-timeout
                #:worker-stateful-p #:worker-last-activity
                #:worker-in-flight #:worker-reset-reason
                #:worker-hibernate-core-path #:worker-hibernated-at
                #:worker-core-bytes #:worker-last-hibernate-milliseconds
                #:worker-refused-reason #:worker-refused-at
                #:hibernate-worker-process #:release-worker-process
                #:end-worker-process
                #:resume-worker #:*hibernate-timeout-seconds*
                #:*hibernate-late-answer-seconds*
                #:worker-last-resume-milliseconds
                #:worker-spawned-at #:worker-boot-kind
                #:worker-core-path #:*worker-core-disabled*
                #:worker-resume-failure #:worker-resume-deferrals
                #:worker-spawn-failure-final-p
                #:resolve-worker-resume-timeout
                #:effective-worker-resume-timeout)
  (:local-nicknames (#:pool-records #:dsmr-mcp/src/hermetic/pool-records))
  (:import-from #:dsmr-mcp/src/hermetic/pool-records
                #:server-stem #:ensure-owner-directory
                #:unsafe-hibernate-path #:hibernated-core-path
                #:disk-allows-hibernation-p #:expected-core-bytes
                #:free-disk-bytes #:parse-server-stem
                #:write-worker-record #:remove-worker-record
                #:pending-requests #:remove-request)
  (:import-from #:dsmr-mcp/src/bus/hostfiles
                #:fleet-line #:append-fleet-line #:service-alive-p)
  (:import-from #:dsmr-mcp/src/hermetic/worker/handlers
                #:resolve-eval-timeout #:effective-eval-timeout)
  (:import-from #:dsmr-mcp/src/log #:log-event)
  (:import-from #:sb-ext)
  (:import-from #:sb-posix)
  (:export #:*worker-pool-warmup* #:*max-pool-size*
           #:*worker-kill-grace-seconds*
           #:pool-settings #:pool-settings-p
           #:pool-settings-warmup #:pool-settings-max-pool-size
           #:pool-settings-kill-grace-seconds
           #:pool-settings-pressure-kill-min-age-seconds
           #:pool-settings-max-hibernated-workers
           #:*max-hibernated-workers* #:effective-max-hibernated-workers
           #:pool-settings-max-resume-attempts
           #:*max-resume-attempts* #:effective-max-resume-attempts
           #:*resolved-pool-settings* #:resolve-pool-settings
           #:effective-worker-pool-warmup #:effective-max-pool-size
           #:effective-worker-kill-grace-seconds
           #:effective-pressure-kill-min-age-seconds
           #:*pressure-kill-min-age-seconds* #:*pressure-agent-interval*
           #:start-pressure-agent #:stop-pressure-agent
           #:build-worker-record #:act-on-hibernate-request
           #:*health-check-interval-seconds*
           #:*worker-ping-timeout-seconds*
           #:*missed-pings-before-wedged*
           #:*crash-breaker-window* #:*crash-breaker-threshold*
           #:*circuit-breaker-cooldown* #:*circuit-breaker-map*
           #:initialize-pool #:shutdown-pool
           #:get-or-assign-worker #:release-session
           #:kill-session-worker #:pool-status-info
           #:pool-worker-info #:find-session-worker
           #:pool-shutting-down #:pool-capacity-exceeded
           #:pool-spawn-cancelled #:*recovery-threads*
           #:pool-resume-deferred #:pool-resume-deferred-session-id
           #:pool-resume-deferred-cause
           #:circuit-breaker-active
           #:circuit-breaker-active-session-id
           #:circuit-breaker-active-remaining-seconds
           #:pool-rpc-with-hard-kill
           #:call-with-session-worker #:with-session-worker
           #:*after-assign-hook*
           #:hibernate-session-worker
           #:*free-disk-bytes-function*
           #:*hibernate-worker-process-function*
           #:*pool-transition-condvar*
           #:+stateless-worker-methods+))

(in-package #:dsmr-mcp/src/hermetic/pool)

;;; ---------------------------------------------------------------------------
;;; Conditions
;;; ---------------------------------------------------------------------------

(define-condition pool-shutting-down (error)
  ()
  (:report (lambda (c s)
             (declare (ignore c))
             (format s "Worker pool is shutting down"))))

(define-condition pool-capacity-exceeded (error)
  ((limit :initarg :limit :reader pool-capacity-exceeded-limit))
  (:report (lambda (c s)
             (format s "Pool size limit reached (~D workers). ~
Release unused sessions before creating new ones."
                     (pool-capacity-exceeded-limit c)))))

(define-condition pool-spawn-cancelled (error)
  ((session-id :initarg :session-id :reader pool-spawn-cancelled-session-id))
  (:report (lambda (c s)
             (format s "Session ~A was released during worker spawn."
                     (pool-spawn-cancelled-session-id c)))))

(define-condition pool-resume-deferred (error)
  ((session-id :initarg :session-id :reader pool-resume-deferred-session-id)
   (cause :initarg :cause :reader pool-resume-deferred-cause))
  (:report (lambda (c s)
             (format s "Session ~A's hibernated world could not be resumed just now (~A). ~
It is still saved on disk, and the next call tries again; nothing has been lost."
                     (pool-resume-deferred-session-id c)
                     (pool-resume-deferred-cause c))))
  (:documentation "A hibernated session's world failed to come back for a
reason that may pass, such as a slow disk, a fork the kernel refused for
memory, or a process killed while it loaded. The worker stays hibernated with
its core in place, so retrying the call resumes it."))

;;; ---------------------------------------------------------------------------
;;; Configuration
;;; ---------------------------------------------------------------------------

(defun %env-int (name default &key (min nil))
  "Read an integer from environment variable NAME. Return DEFAULT when
NAME is unset or empty. When the value is unparseable, or with MIN given
is below MIN, emit a warning and return DEFAULT.

Used by resolve-pool-settings to read the pool tuning settings, so you can
tune dsmr-mcp without editing source. It runs when the pool starts, never
when this file loads, so a server booted from a prebuilt image reads the
environment it was started with rather than the one the image was built
under."
  (let ((s (uiop:getenv name)))
    (cond
      ((or (null s) (zerop (length s))) default)
      (t
       (handler-case
           (let ((n (parse-integer s)))
             (cond
               ((and min (< n min))
                (warn "~A=~A is below ~D; using default ~D" name n min default)
                default)
               (t n)))
         (error ()
           (warn "~A=~S is not an integer; using default ~D" name s default)
           default))))))

(defvar *worker-pool-warmup* nil
  "Number of standby workers to pre-spawn and keep ready, or NIL to read the
environment when the pool starts.

NIL (the default) means resolve-pool-settings reads DSMR_WORKER_POOL_WARMUP, a
non-negative integer defaulting to 0. At 0 the pool keeps no standby and a
worker spawns on a session's first hermetic request, so a host that never
needs a worker pays nothing for one. A non-NIL value, set globally or bound
in the thread that starts the pool, wins over the environment.")

(defvar *max-pool-size* nil
  "Maximum total number of workers (bound + standby), or NIL to read the
environment when the pool starts. The bound prevents unbounded resource
consumption: each SBCL worker uses ~100-500 MB memory.

NIL (the default) means resolve-pool-settings reads DSMR_MAX_POOL_SIZE, a
positive integer defaulting to 16. A non-NIL value, set globally or bound in
the thread that starts the pool, wins over the environment.")

(defvar *health-check-interval-seconds* 10.0d0
  "Seconds between health monitor poll iterations.")

(defparameter *worker-ping-timeout-seconds* 2
  "Seconds to wait for an idle worker's answer to a liveness ping.

A ping has no work to do: the worker builds a two-entry hash-table and writes
it back, with no evaluation and no I/O of its own, so a healthy one answers in
single-digit milliseconds. Two seconds is therefore generous slack against a
momentarily loaded host rather than a realistic upper bound on the work, and it
stays far enough under *health-check-interval-seconds* that a slow probe cannot
still be outstanding when the next tick arrives.")

(defparameter *missed-pings-before-wedged* 2
  "Consecutive unanswered pings before a live worker is classified :wedged.

One missed ping is cheap and common: a garbage collection pause or a moment of
scheduler starvation on a loaded host is enough to produce one. Requiring two in
a row costs one extra tick of detection latency and removes that whole class of
false wedge. It is the same reasoning that makes the crash breaker count crashes
inside a window rather than trip on the first one, applied to a probe that has
none of a crash's recovery cost to weigh on the other side.

Reaching this count does two things at once: it establishes :wedged in the
record and it retires the worker. Nothing hands out a worker that has been
classified wedged.")

(defvar *shutdown-replenish-wait-seconds* 0.05d0
  "Polling interval (seconds) while waiting for replenish thread shutdown.")

;;; ---------------------------------------------------------------------------
;;; Circuit breaker — dsmr-mcp addition over cl-mcp
;;; ---------------------------------------------------------------------------

(defparameter *crash-breaker-window* 300
  "Time window in seconds for the crash circuit breaker (5 min).")

(defparameter *crash-breaker-threshold* 3
  "Maximum crashes allowed within *crash-breaker-window* before halting
recovery for a session.")

(defparameter *max-concurrent-recoveries* 4
  "Maximum concurrent crash recovery threads. Prevents resource exhaustion
when many workers crash simultaneously.")

(defvar *circuit-breaker-map* (make-hash-table :test 'equal)
  "Maps session-id -> circuit-breaker trip timestamp (get-universal-time).
Entries are cleared by release-session so manual reset works.
dsmr-mcp addition over cl-mcp: cl-mcp only removes the session from the
affinity map; dsmr-mcp additionally records the trip time and fails fast
for *circuit-breaker-cooldown* seconds.")

(defparameter *circuit-breaker-cooldown* 60
  "Seconds to fail-fast after circuit breaker trips for a session.
During the cooldown window, get-or-assign-worker signals an error
immediately rather than attempting to spawn a replacement worker.
After the window expires, the session may spawn a new worker normally.")

(define-condition circuit-breaker-active (error)
  ((session-id :initarg :session-id
               :reader circuit-breaker-active-session-id)
   (remaining-seconds :initarg :remaining-seconds
                      :reader circuit-breaker-active-remaining-seconds))
  (:report (lambda (c s)
             (format s "Circuit breaker active for session ~A; ~Ds remaining in ~
cooldown. The worker crashed ~D times in ~Ds. Manual reset via release-session."
                     (circuit-breaker-active-session-id c)
                     (circuit-breaker-active-remaining-seconds c)
                     *crash-breaker-threshold*
                     *crash-breaker-window*)))
  (:documentation "Signaled when a session's worker has crashed repeatedly enough that
the pool refuses further calls instead of spawning another replacement.

It lives beside the breaker's own tuning parameters rather than with the other
pool conditions so its report can read them without a forward reference.

Carries the session and how many seconds of the cooldown remain, so a caller at
the dispatch boundary can tell the agent how long to wait rather than only that
something failed."))

;;; ---------------------------------------------------------------------------
;;; Parent hard-kill backstop — dsmr-mcp addition over cl-mcp
;;; ---------------------------------------------------------------------------

(defvar *worker-kill-grace-seconds* nil
  "Grace margin in seconds added to the in-worker soft timeout before the
parent SIGKILLs the worker, or NIL to read the environment when the pool
starts. If the worker's sb-ext:with-timeout fires and the worker does not
return a response within this grace margin, the parent treats the worker as
runaway and kills it, routing the crash through the normal recovery path.

NIL (the default) means resolve-pool-settings reads
DSMR_WORKER_KILL_GRACE_SECONDS, a positive integer defaulting to 5. A non-NIL
value, set globally or bound in the thread that starts the pool, wins over
the environment.")

(defvar *pressure-kill-min-age-seconds* nil
  "How old, in seconds, a worker must be before the host service may have it
stopped under memory pressure, or NIL to read the environment when the pool
starts. A worker that was just spawned has cost its boot and not yet served
anything, so stopping it would only make the next call pay for another boot.

NIL (the default) means resolve-pool-settings reads
DSMR_PRESSURE_MIN_KILL_AGE_SECONDS, a non-negative integer defaulting to 10. A
non-NIL value, set globally or bound in the thread that starts the pool, wins
over the environment; a binding visible to the thread deciding a stop wins
there too.")

(defvar *max-hibernated-workers* nil
  "The most workers this server keeps hibernated at once, or NIL to read the
environment when the pool starts. A hibernated worker holds no memory and no
place in the pool, so without a limit a server whose sessions come and go
without being released would fill the disk with their worlds. At the limit a
request to hibernate is refused with :at-limit and the host service turns to
another worker.

NIL (the default) means resolve-pool-settings reads
DSMR_MAX_HIBERNATED_WORKERS, a non-negative integer defaulting to 8; 0 turns
hibernation off. A non-NIL value, set globally or bound in the thread that
starts the pool, wins over the environment.")

(defvar *max-resume-attempts* nil
  "How many resumes of one hibernated worker in a row may fail in a way that
may pass before its world is given up, or NIL to read the environment when the
pool starts. A failure that looks passing (a timeout, a process that exited
before its handshake) can in fact be permanent, as with a core damaged inside
the file, and without a limit such a session would be told on every call that
its world is still saved and would never get a working worker. At the limit
the world is given up as a failure that can never pass: its core is kept for
diagnosis and the session gets a fresh worker with a notice saying why.

NIL (the default) means resolve-pool-settings reads DSMR_MAX_RESUME_ATTEMPTS,
a positive integer defaulting to 3. A non-NIL value, set globally or bound in
the thread that starts the pool, wins over the environment.")

;;; ---------------------------------------------------------------------------
;;; Settings resolved when the pool starts
;;; ---------------------------------------------------------------------------

(defstruct (pool-settings (:copier nil))
  "The pool tuning settings in force, resolved once per start by
resolve-pool-settings. Every pool thread reads this one global record, so the
value a caller bound around initialize-pool is the value every thread sees,
including threads started after the caller's binding has gone.

The slots carry no type declaration on purpose: a bound special is taken as
given, and initialize-pool reports an invalid one with its own error."
  (warmup 0)
  (max-pool-size 16)
  (kill-grace-seconds 5)
  (pressure-kill-min-age-seconds 10)
  (max-hibernated-workers 8)
  (max-resume-attempts 3))

(defvar *resolved-pool-settings* nil
  "The pool-settings record from the last resolve-pool-settings call, or NIL
when nothing has resolved yet. The effective-* readers resolve on first use
when it is NIL.")

(defun resolve-pool-settings ()
  "Read the pool tuning settings now and store them in *resolved-pool-settings*.
Returns the fresh pool-settings record.

Each field takes the matching special when it is non-NIL, else the
environment, else its default: *worker-pool-warmup* or DSMR_WORKER_POOL_WARMUP
(default 0), *max-pool-size* or DSMR_MAX_POOL_SIZE (default 16),
*worker-kill-grace-seconds* or DSMR_WORKER_KILL_GRACE_SECONDS (default 5), and
*pressure-kill-min-age-seconds* or DSMR_PRESSURE_MIN_KILL_AGE_SECONDS (default
10), *max-hibernated-workers* or DSMR_MAX_HIBERNATED_WORKERS (default 8), and
*max-resume-attempts* or DSMR_MAX_RESUME_ATTEMPTS (default 3).
An unparseable or out-of-range environment value warns and falls back to
the default.

It also resolves the worker handshake timeouts, for a fresh worker and for a
resumed one, and the eval timeout, so one
call settles every pool and worker timing setting the server uses.

initialize-pool calls this first on every start, so a server booted from a
prebuilt image honours the environment it is started with."
  (let ((settings
          (make-pool-settings
           :warmup (or *worker-pool-warmup*
                       (%env-int "DSMR_WORKER_POOL_WARMUP" 0 :min 0))
           :max-pool-size (or *max-pool-size*
                              (%env-int "DSMR_MAX_POOL_SIZE" 16 :min 1))
           :kill-grace-seconds (or *worker-kill-grace-seconds*
                                   (%env-int "DSMR_WORKER_KILL_GRACE_SECONDS"
                                             5 :min 1))
           :pressure-kill-min-age-seconds
           (or *pressure-kill-min-age-seconds*
               (%env-int "DSMR_PRESSURE_MIN_KILL_AGE_SECONDS" 10 :min 0))
           :max-hibernated-workers
           (or *max-hibernated-workers*
               (%env-int "DSMR_MAX_HIBERNATED_WORKERS" 8 :min 0))
           :max-resume-attempts
           (or *max-resume-attempts*
               (%env-int "DSMR_MAX_RESUME_ATTEMPTS" 3 :min 1)))))
    (setf *resolved-pool-settings* settings)
    (resolve-worker-startup-timeout)
    (resolve-worker-resume-timeout)
    (resolve-eval-timeout)
    settings))

(defun %current-pool-settings ()
  "Return *resolved-pool-settings*, resolving it first when nothing has."
  (or *resolved-pool-settings* (resolve-pool-settings)))

(defun effective-worker-pool-warmup ()
  "The number of standby workers the pool keeps, as last resolved."
  (pool-settings-warmup (%current-pool-settings)))

(defun effective-max-pool-size ()
  "The maximum number of workers the pool runs, as last resolved."
  (pool-settings-max-pool-size (%current-pool-settings)))

(defun effective-worker-kill-grace-seconds ()
  "The grace in seconds past the soft timeout before a worker is killed, as
last resolved."
  (pool-settings-kill-grace-seconds (%current-pool-settings)))

(defun effective-pressure-kill-min-age-seconds ()
  "The age in seconds a worker must reach before a pressure stop may take it:
a binding of *pressure-kill-min-age-seconds* visible here, else the value last
resolved."
  (or *pressure-kill-min-age-seconds*
      (pool-settings-pressure-kill-min-age-seconds (%current-pool-settings))))

(defun effective-max-hibernated-workers ()
  "The most workers this server keeps hibernated at once, as last resolved."
  (pool-settings-max-hibernated-workers (%current-pool-settings)))

(defun effective-max-resume-attempts ()
  "How many resumes of one worker in a row may fail in a way that may pass
before its world is given up: a binding of *max-resume-attempts* visible here,
else the value last resolved."
  (or *max-resume-attempts*
      (pool-settings-max-resume-attempts (%current-pool-settings))))

;;; ---------------------------------------------------------------------------
;;; Global pool state
;;; ---------------------------------------------------------------------------

(defvar *pool-lock* (bt:make-lock "pool-lock")
  "Global mutex protecting pool state and the affinity map.
Must be acquired before any worker-stream-lock (lock hierarchy).")

(defvar *affinity-map* (make-hash-table :test 'equal)
  "Maps session-id (string) to worker struct or worker-placeholder.")

(defvar *standby-workers* nil
  "List of workers in :standby state, ready for immediate assignment.")

(defvar *all-workers* nil
  "List of all live worker structs (used for shutdown and status).")

(defvar *health-thread* nil
  "Background thread running the health monitor loop.")

(defvar *health-monitor-lock* (bt:make-lock "pool-health-monitor-lock")
  "Lock protecting health monitor wake/sleep coordination.")

(defvar *health-monitor-condvar*
  (bt:make-condition-variable :name "pool-health-monitor-condvar")
  "Condition variable used to wake the health monitor during shutdown.")

(defvar *pool-running* nil
  "Controls the health monitor loop. NIL causes the monitor to exit.")

(defvar *replenish-running* nil
  "Flag preventing concurrent replenish threads. Set under *pool-lock*.")

(defvar *recovery-threads* nil
  "List of active crash recovery threads. Maintained under *pool-lock*.")

(defvar *crash-history* (make-hash-table :test 'equal)
  "Maps session-id to list of crash timestamps (get-universal-time).
Used by the circuit breaker to detect repeated crash loops.")

(defvar *pool-transition-condvar*
  (bt:make-condition-variable :name "pool-transition")
  "Broadcast, with *pool-lock* held, whenever a worker changes state or a call
hands its worker back. A thread waiting for a worker to finish saving or
resuming waits on it with *pool-lock*.")

(defvar *after-assign-hook* nil
  "NIL, or a function of one argument, the worker, that call-with-session-worker
calls after get-or-assign-worker returns and before it takes the worker for the
call. It exists so a test can make something happen to the worker inside that
window deterministically; nothing in the server sets it.")

(defvar *free-disk-bytes-function* #'free-disk-bytes
  "The function hibernate-session-worker asks for the free bytes of a
directory before it lets a worker save its world there.")

(defvar *hibernate-worker-process-function* #'hibernate-worker-process
  "The function hibernate-session-worker calls, with the worker and the core
path, to have a worker save its world. It answers as hibernate-worker-process
does; a test binds it to stand in for a save that is slow or that dies.")

;; The calls that leave nothing behind in a worker's image. Every other call
;; marks the worker stateful. This is wider than the strict rule (only an
;; eval, a system load or a test run can create state) on purpose: the inspect
;; calls can only act on objects an earlier eval registered, so they never mark
;; a fresh worker in practice, and when in doubt a worker should be hibernated
;; rather than stopped.
(defparameter +stateless-worker-methods+
  '("worker/ping" "worker/code-find" "worker/code-describe"
    "worker/code-find-references")
  "Worker methods that do not make a worker stateful.")

(defun %unix-now ()
  "The current time in whole Unix seconds."
  (- (get-universal-time) (encode-universal-time 0 0 0 1 1 1970 0)))

;;; ---------------------------------------------------------------------------
;;; Placeholder struct — coordinates concurrent spawn requests for same session
;;; ---------------------------------------------------------------------------

(defun %condition-broadcast (condvar)
  "Wake ALL threads waiting on CONDVAR."
  #+sbcl (sb-thread:condition-broadcast condvar)
  #-sbcl (bt:condition-notify condvar))

(defstruct worker-placeholder
  "Placeholder inserted into the affinity map while a worker is being spawned.
Other threads requesting the same session wait on the condition variable
until the spawn completes or fails."
  (session-id nil)
  (lock (bt:make-lock "placeholder-lock"))
  (condvar (bt:make-condition-variable :name "placeholder-ready"))
  (state :spawning :type keyword)
  (worker nil)
  (error-message nil)
  (cancelled nil :type boolean))

(defun %effective-pool-size ()
  "Return the effective pool size: resident workers plus in-flight spawns.
Counts every worker in *all-workers* except those in state :hibernated, plus
placeholder entries in *affinity-map*. A hibernated worker has no process and
holds no memory, only a file on disk, and the size limit exists to bound
memory, so it does not take a place; a worker that is saving or resuming
still has a process and does. Must be called with *pool-lock* held."
  (let ((pending 0))
    (maphash (lambda (k v)
               (declare (ignore k))
               (when (typep v 'worker-placeholder)
                 (incf pending)))
             *affinity-map*)
    (+ (count-if-not (lambda (w) (eq (worker-state w) :hibernated))
                     *all-workers*)
       pending)))

;;; ---------------------------------------------------------------------------
;;; Internal — spawn and bind
;;; ---------------------------------------------------------------------------

(defun %spawn-and-bind (session-id placeholder &key need-reset reset-reason)
  "Spawn a worker, bind it to SESSION-ID, and notify waiting threads.
On failure, clean up the affinity map entry and notify waiters. When
NEED-RESET is true, arms needs-reset-notification on the new worker before
making it visible, with RESET-REASON, when given, as the reason the session's
reset notice names. Returns the worker on success."
  (let ((new-worker nil))
    (unwind-protect
        (progn
          (setf new-worker (spawn-worker))
          (setf (worker-state new-worker) :bound)
          (setf (worker-session-id new-worker) session-id)
          (when need-reset
            (setf (worker-needs-reset-notification new-worker) t
                  (worker-reset-reason new-worker) reset-reason))
          (let ((cancelled nil))
            (bt:with-lock-held (*pool-lock*)
              (cond
                ((worker-placeholder-cancelled placeholder)
                 (setf cancelled t)
                 (setf (worker-state new-worker) :released))
                (t
                 (setf (gethash session-id *affinity-map*) new-worker)
                 (push new-worker *all-workers*)))
              (%condition-broadcast *pool-transition-condvar*))
            (cond
              (cancelled
               (bt:with-lock-held ((worker-placeholder-lock placeholder))
                 (setf (worker-placeholder-state placeholder) :failed
                       (worker-placeholder-error-message placeholder)
                       "Session released during spawn.")
                 (%condition-broadcast (worker-placeholder-condvar placeholder)))
               (log-event :info "pool.spawn.cancelled"
                          "session" session-id
                          "worker_id" (worker-id new-worker))
               (ignore-errors (kill-worker new-worker))
               (setf new-worker nil)
               (error 'pool-spawn-cancelled :session-id session-id))
              (t
               (bt:with-lock-held ((worker-placeholder-lock placeholder))
                 (setf (worker-placeholder-worker placeholder) new-worker
                       (worker-placeholder-state placeholder) :ready)
                 (%condition-broadcast (worker-placeholder-condvar placeholder)))
               (log-event :info "pool.worker.bound"
                          "session" session-id
                          "worker_id" (worker-id new-worker))
               (%schedule-replenish)
               new-worker))))
      (when (null (worker-placeholder-worker placeholder))
        (bt:with-lock-held (*pool-lock*)
          (when (eq (gethash session-id *affinity-map*) placeholder)
            (remhash session-id *affinity-map*)))
        (bt:with-lock-held ((worker-placeholder-lock placeholder))
          (setf (worker-placeholder-state placeholder) :failed
                (worker-placeholder-error-message placeholder)
                "Worker process failed to start.")
          (%condition-broadcast (worker-placeholder-condvar placeholder)))
        (when new-worker
          (ignore-errors (kill-worker new-worker)))))))

;;; ---------------------------------------------------------------------------
;;; Internal — wait for placeholder
;;; ---------------------------------------------------------------------------

(defun %wait-for-placeholder (placeholder)
  "Wait for another thread to finish spawning a worker for the same session.
Returns the worker on success. Signals an error on failure or timeout."
  (bt:with-lock-held ((worker-placeholder-lock placeholder))
    (let ((deadline (+ (get-internal-real-time)
                       (* (+ (effective-worker-startup-timeout) 15)
                          internal-time-units-per-second))))
      (loop while (eq (worker-placeholder-state placeholder) :spawning)
            for remaining = (/ (max 0 (- deadline (get-internal-real-time)))
                               internal-time-units-per-second)
            when (zerop remaining) do (loop-finish)
            do (bt:condition-wait
                (worker-placeholder-condvar placeholder)
                (worker-placeholder-lock placeholder)
                :timeout remaining)))
    (case (worker-placeholder-state placeholder)
      (:ready  (worker-placeholder-worker placeholder))
      (:failed (error "Worker spawn failed: ~A"
                      (worker-placeholder-error-message placeholder)))
      (:spawning (error "Worker spawn timed out for session ~A"
                        (worker-placeholder-session-id placeholder))))))

;;; ---------------------------------------------------------------------------
;;; Internal — standby replenishment
;;; ---------------------------------------------------------------------------

(defun %replenish-standbys ()
  "Spawn standby workers until the pool has the resolved warmup count of
standbys. Respects the resolved maximum pool size. Runs in a background
thread; exits when *pool-running* becomes NIL."
  (unwind-protect
      (loop (unless *pool-running* (return))
            (let ((need-more nil)
                  (warmup (effective-worker-pool-warmup))
                  (max-size (effective-max-pool-size)))
              (bt:with-lock-held (*pool-lock*)
                (when (and *pool-running*
                           (< (length *standby-workers*) warmup)
                           (< (%effective-pool-size) max-size))
                  (setf need-more t)))
              (unless need-more (return))
              (handler-case
                  (let ((w (spawn-worker)))
                    (bt:with-lock-held (*pool-lock*)
                      (cond
                        ((not *pool-running*)
                         (ignore-errors (kill-worker w))
                         (return))
                        ((>= (%effective-pool-size) max-size)
                         (log-event :info "pool.standby.cap-reached"
                                    "worker_id" (worker-id w))
                         (ignore-errors (kill-worker w))
                         (return))
                        (t
                         (push w *standby-workers*)
                         (push w *all-workers*))))
                    (log-event :info "pool.standby.spawned"
                               "worker_id" (worker-id w)))
                (error (e)
                  (log-event :warn "pool.standby.spawn.failed"
                             "error" (princ-to-string e))
                  (return)))))
    (bt:with-lock-held (*pool-lock*)
      (setf *replenish-running* nil))))

(defun %schedule-replenish ()
  "Spawn a background thread to replenish standby workers if needed.
Skips if a replenish thread is already running. The new thread reads the
resolved pool settings, which are global, so a value the caller bound around
initialize-pool is honoured there without being passed across."
  (let ((should-start nil)
        (warmup (effective-worker-pool-warmup)))
    (bt:with-lock-held (*pool-lock*)
      (when (and (not *replenish-running*)
                 (< (length *standby-workers*) warmup))
        (setf *replenish-running* t
              should-start t)))
    (when should-start
      (bt:make-thread #'%replenish-standbys :name "pool-replenish"))))

;;; ---------------------------------------------------------------------------
;;; Internal — crash recovery
;;; ---------------------------------------------------------------------------

(defun %handle-worker-crash (crashed-worker)
  "Handle a crashed worker: spawn a replacement bound to the same session,
arm needs-reset-notification on the replacement, and set the circuit-breaker
trip time when the crash threshold is reached.

When the circuit breaker trips, records the trip time in *circuit-breaker-map*
so get-or-assign-worker fails fast for *circuit-breaker-cooldown* seconds.

Exits immediately when *pool-running* is NIL to prevent orphan recovery
threads from spawning workers after shutdown."
  (unless *pool-running* (return-from %handle-worker-crash))
  (let ((session-id nil)
        (was-bound nil)
        (was-standby nil)
        (was-already-crashed nil))
    (bt:with-lock-held (*pool-lock*)
      (case (worker-state crashed-worker)
        (:bound
         (setf was-bound t
               session-id (worker-session-id crashed-worker))
         (setf (worker-state crashed-worker) :crashed))
        (:standby
         (setf was-standby t)
         (setf *standby-workers* (remove crashed-worker *standby-workers*))
         (setf (worker-state crashed-worker) :crashed))
        (:crashed
         ;; Already marked crashed by worker-rpc EOF detection.
         ;; Clean up pool tracking and trigger replenishment.
         (setf was-already-crashed t
               session-id (worker-session-id crashed-worker))
         (when (eql (gethash session-id *affinity-map*) crashed-worker)
           (remhash session-id *affinity-map*)
           (setf was-bound t))
         (setf *all-workers* (remove crashed-worker *all-workers*)))
        (otherwise (return-from %handle-worker-crash))))
    (let (exit-code exit-status)
      (ignore-errors
        (let* ((proc (worker-process-info crashed-worker))
               (status (and proc (sb-ext:process-status proc))))
          (when status
            (setf exit-status (string-downcase (symbol-name status))))
          (when (member status '(:exited :signaled))
            (setf exit-code (sb-ext:process-exit-code proc)))))
      (log-event :warn "pool.worker.crashed"
                 "worker_id" (worker-id crashed-worker)
                 "session" session-id
                 "was_standby" was-standby
                 "exit_status" (or exit-status "unknown")
                 "exit_code" (or exit-code "unknown"))
      (setf (worker-last-crash-reason crashed-worker) "process-died"
            (worker-last-exit-status crashed-worker) (or exit-status "unknown")
            (worker-last-exit-code crashed-worker) (or exit-code "unknown")))
    (ignore-errors (kill-worker crashed-worker))
    (when was-already-crashed
      (when was-bound (%schedule-replenish))
      (return-from %handle-worker-crash))
    (cond
      (was-bound
       ;; Circuit breaker: record crash and check threshold.
       (let* ((now (get-universal-time))
              (window-start (- now *crash-breaker-window*))
              (breaker-tripped nil))
         (bt:with-lock-held (*pool-lock*)
           (let ((history (gethash session-id *crash-history*)))
             (setf history (remove-if (lambda (ts) (< ts window-start)) history))
             (push now history)
             (setf (gethash session-id *crash-history*) history)
             (setf (worker-crash-history-pushed-p crashed-worker) t)
             (when (>= (length history) *crash-breaker-threshold*)
               (setf breaker-tripped t)
               (log-event :error "pool.circuit-breaker.tripped"
                          "session" session-id
                          "crashes" (length history)
                          "window_seconds" *crash-breaker-window*
                          "cooldown_seconds" *circuit-breaker-cooldown*)
               ;; Clear crash history to prevent stale data on session reuse.
               (remhash session-id *crash-history*)
               (when (eql (gethash session-id *affinity-map*) crashed-worker)
                 (remhash session-id *affinity-map*))
               (setf *all-workers* (remove crashed-worker *all-workers*))
               ;; Record trip time in *circuit-breaker-map* so the next
               ;; get-or-assign-worker call fails immediately during the cooldown.
               (setf (gethash session-id *circuit-breaker-map*)
                     (get-universal-time)))))
         (when breaker-tripped
           (return-from %handle-worker-crash)))
       ;; No breaker trip: spawn a replacement worker.
       (handler-case
           (let ((new-worker nil) (registered nil))
             (unwind-protect
                 (progn
                   (setf new-worker (spawn-worker))
                   (unless *pool-running*
                     (ignore-errors (kill-worker new-worker))
                     (setf new-worker nil)
                     (return-from %handle-worker-crash))
                   (setf (worker-state new-worker) :bound)
                   (setf (worker-session-id new-worker) session-id)
                   ;; Arm the reset notification flag on the replacement so the
                   ;; dispatcher returns T exactly once, then clears it.
                   (setf (worker-needs-reset-notification new-worker) t)
                   (setf (worker-last-crash-reason new-worker)
                           (worker-last-crash-reason crashed-worker)
                         (worker-last-exit-status new-worker)
                           (worker-last-exit-status crashed-worker)
                         (worker-last-exit-code new-worker)
                           (worker-last-exit-code crashed-worker))
                   (bt:with-lock-held (*pool-lock*)
                     (cond
                       ((not *pool-running*)
                        (setf (worker-state new-worker) :released)
                        (setf *all-workers* (remove crashed-worker *all-workers*)))
                       ((eql (gethash session-id *affinity-map*) crashed-worker)
                        (setf (gethash session-id *affinity-map*) new-worker)
                        (setf *all-workers* (remove crashed-worker *all-workers*))
                        (push new-worker *all-workers*)
                        (setf registered t))
                       (t
                        (setf (worker-state new-worker) :released)
                        (setf *all-workers* (remove crashed-worker *all-workers*)))))
                   (cond
                     ((not registered)
                      (log-event :info "pool.worker.recovery.session-gone"
                                 "worker_id" (worker-id new-worker)
                                 "session" session-id)
                      (ignore-errors (kill-worker new-worker))
                      (setf new-worker nil))
                     (t
                      (log-event :info "pool.worker.recovered"
                                 "old_worker_id" (worker-id crashed-worker)
                                 "new_worker_id" (worker-id new-worker)
                                 "session" session-id))))
               (when (and new-worker (not registered))
                 (ignore-errors (kill-worker new-worker)))))
         (error (e)
           (log-event :error "pool.worker.recovery.failed"
                      "worker_id" (worker-id crashed-worker)
                      "session" session-id
                      "error" (princ-to-string e))
           (bt:with-lock-held (*pool-lock*)
             (when (eql (gethash session-id *affinity-map*) crashed-worker)
               (remhash session-id *affinity-map*))
             (setf *all-workers* (remove crashed-worker *all-workers*))))))
      (was-standby
       (bt:with-lock-held (*pool-lock*)
         (setf *all-workers* (remove crashed-worker *all-workers*)))
       (%schedule-replenish)))))

;;; ---------------------------------------------------------------------------
;;; Internal — health monitor
;;; ---------------------------------------------------------------------------

(defun %worker-process-alive-p (worker)
  "Return T if the worker's OS process is still alive, NIL otherwise.
Does not acquire any locks or perform I/O."
  (let ((process (worker-process-info worker)))
    (and process
         (ignore-errors (sb-ext:process-alive-p process)))))

(defun %record-liveness (worker classification basis &key milliseconds)
  "Write CLASSIFICATION on WORKER, stamped with BASIS and the time it was taken.

Every write to a worker's liveness goes through here so the classification, how
it was established and when can never drift apart in the record. MILLISECONDS is
supplied only by a probe that actually timed a round trip; a classification
reached any other way leaves the previous timing alone rather than overwriting
it with a value it did not measure."
  (setf (worker-liveness worker) classification
        (worker-liveness-basis worker) basis
        (worker-liveness-checked-at worker) (get-universal-time))
  (when milliseconds
    (setf (worker-last-ping-milliseconds worker) milliseconds))
  classification)

(defun %retire-unresponsive-worker (worker)
  "Take a worker that has stopped answering out of service.

Reaching *missed-pings-before-wedged* is the point at which a silence stops
looking like a pause and starts looking like a worker that will never answer
again. From there the worker goes through the same path a detected crash takes:
it leaves the standby list, its process is killed, and a replacement is
scheduled.

This is what keeps the tolerance honest. The probe no longer condemns a worker
for one silence, and nothing has been loosened about what happens once the
silence is established. The crash reason is corrected afterwards, because the
shared path stamps 'process-died' and the whole point of this case is that the
process had not died.

Costs this thread the length of one kill, which is bounded by the terminate
grace period. It rides the health monitor's own tick, where that is affordable,
and only once per worker."
  (%handle-worker-crash worker)
  (setf (worker-last-crash-reason worker) "unresponsive"))

(defun %record-missed-ping (worker condition)
  "Record what a failed liveness probe on WORKER established, if anything.

CONDITION is whatever the probe signalled. It is deliberately not dispatched on:
the classification turns on whether the process is still there, which is the
question that separates a worker that has gone from a worker that is present and
silent, and no condition class answers that as well as looking.

A process that has gone establishes :dead at once. A process that is still
running counts one more silence, and establishes :wedged only when the count
reaches *missed-pings-before-wedged*, at which point the worker is retired."
  (cond
    ((not (%worker-process-alive-p worker))
     (%record-liveness worker :dead :active-probe)
     (log-event :warn "pool.monitor.ping-worker-gone"
                "worker_id" (worker-id worker)
                "pid" (worker-pid worker)
                "error" (princ-to-string condition)))
    (t
     (let ((missed (incf (worker-consecutive-missed-pings worker))))
       (when (>= missed *missed-pings-before-wedged*)
         (%record-liveness worker :wedged :active-probe)
         (%retire-unresponsive-worker worker))
       (log-event :warn "pool.monitor.ping-missed"
                  "worker_id" (worker-id worker)
                  "pid" (worker-pid worker)
                  "consecutive_missed" missed
                  "threshold" *missed-pings-before-wedged*
                  "liveness" (string-downcase
                              (symbol-name (worker-liveness worker)))
                  "error" (princ-to-string condition))))))

(defun %ping-eligible-p (worker)
  "True when WORKER is still one a liveness ping may reach: :bound or :standby
with no call holding it.

worker-ping calls this while it holds the worker's stream lock, so it reads
the slots without taking *pool-lock*, which would invert the lock order. The
read is enough: every state that rules a ping out is set before the save or
stop takes the stream lock, and stays set until the channel is gone."
  (and (member (worker-state worker) '(:bound :standby))
       (zerop (worker-in-flight worker))
       t))

(defun %ping-idle-worker (worker)
  "Ask WORKER a real question and record what the answer established.

Only ever called for a worker in :standby. A worker mid-eval holds its stream
lock for the whole call, so probing one would either park this thread on real
work or expire and report a busy worker as wedged, which is precisely the false
positive an active probe exists to avoid. A bound worker is already being
exercised by the call in flight, and that call's own end-of-file and timeout
paths are the evidence for its turn.

An answer inside *worker-ping-timeout-seconds* establishes :healthy and records
the round trip it took, clearing the missed count.

A single miss establishes nothing. It counts one miss and leaves the previous
classification, its basis and the time it was taken exactly where they were, so
the recorded age of a classification stays the age of the check that actually
reached a conclusion rather than the age of the last attempt. Restamping on
every tick would make a value that has not been confirmed for a minute look as
fresh as one confirmed a second ago, which is the whole failure this record
exists to prevent. Only once *missed-pings-before-wedged* misses have
accumulated in a row is :wedged established and stamped, and only then is the
worker taken out of service.

That tolerance is why the probe goes through WORKER-PING rather than WORKER-RPC:
WORKER-RPC ends a worker on its first timeout, which would make the missed-ping
count unreachable past one and leave a worker retired for a garbage collection
pause.

A miss from a worker whose process has gone establishes :dead at once: the wedge
case is an addition to the crash case, never a replacement for it, and a dead
process must not be reported as merely unresponsive.

A worker that is saving, saved or resuming is never pinged, and the state is
checked a second time once the ping holds the worker's stream lock, through
%ping-eligible-p: a ping that waited on that lock behind a save would otherwise
reach a channel the save has just closed and read it as a crash. A ping skipped
that way records nothing.

Returns T when the worker answered."
  (when (member (worker-state worker) '(:hibernating :hibernated :resuming))
    (return-from %ping-idle-worker nil))
  (handler-case
      (let ((milliseconds (worker-ping worker
                                       :timeout *worker-ping-timeout-seconds*
                                       :eligible-p #'%ping-eligible-p)))
        (cond
          ((eq milliseconds :skipped) nil)
          (t
           (setf (worker-consecutive-missed-pings worker) 0)
           (%record-liveness worker :healthy :active-probe
                             :milliseconds milliseconds)
           t)))
    (error (e)
      (%record-missed-ping worker e)
      nil)))

(defun %infer-bound-worker-liveness (worker)
  "Record what the traffic already reaching a bound WORKER establishes.

A bound worker is not probed, so there is no round trip to time. What is known
without asking is that the process is still there and that no call on its
channel has failed hard enough for the pool to mark it crashed. That is recorded
as :healthy on a passive-inference basis, and the basis is the whole of the
honesty here: it says the process is alive and its channel has not failed, and
it does not say the worker answered anything. A worker wedged inside an
evaluation reads :healthy here until its own call's timeout fires, which is what
the timeout is for.

A worker that is saving, saved or resuming is left alone: its process is
meant to be going or gone, and that is not evidence of anything."
  (cond
    ((member (worker-state worker) '(:hibernating :hibernated :resuming))
     nil)
    ((%worker-process-alive-p worker)
     (%record-liveness worker :healthy :passive-inference))
    (t
     (%record-liveness worker :dead :passive-inference))))

(defun %check-worker-liveness (workers)
  "Establish a liveness classification for every worker in WORKERS on this tick.

Rides the health monitor's existing wake rather than adding a timer of its own,
so the whole active-probe design costs no extra wake-ups.

The state is read here rather than taken from the caller's snapshot, because a
standby worker can be assigned to a session in between and only a worker still
idle at this moment may be pinged. A worker assigned in the remaining instant
before the ping reaches its stream is the one case this cannot exclude; it costs
this thread the length of that call and nothing else, since a real call's own
answer keeps the worker classified healthy either way."
  (dolist (w workers)
    (case (worker-state w)
      ;; Saving, saved or resuming: no channel to ask and no process to judge.
      ((:hibernating :hibernated :resuming) nil)
      (:standby (%ping-idle-worker w))
      (:bound (%infer-bound-worker-liveness w))
      (t nil))))

(defun %wait-for-next-health-check ()
  "Wait until the next health check interval, or until shutdown wakes us."
  (bt:with-lock-held (*health-monitor-lock*)
    (when *pool-running*
      (bt:condition-wait *health-monitor-condvar*
                         *health-monitor-lock*
                         :timeout *health-check-interval-seconds*))))

(defun %health-monitor-loop ()
  "Periodically check all workers and dispatch crash recovery asynchronously.
Runs until *pool-running* becomes NIL.

Each tick asks two separate questions. Whether the process still exists, which
catches a crash and is answered by sb-ext:process-alive-p; and whether the
worker is still answering, which catches a worker that is alive and no longer
useful and is answered only by sending it a request and timing the reply. The
second is what %check-worker-liveness runs, for idle workers alone."
  (loop while *pool-running*
        do (%wait-for-next-health-check)
           (when *pool-running*
             (handler-case
                 (let ((workers nil))
                   ;; Snapshot worker list under lock
                   (bt:with-lock-held (*pool-lock*)
                     (setf workers (copy-list *all-workers*)))
                   ;; Check each bound/standby worker outside the lock. Only
                   ;; those two states are judged: a worker that is saving,
                   ;; saved or resuming (:hibernating, :hibernated,
                   ;; :resuming) has a process that is meant to end, so its
                   ;; absence is never a crash here.
                   (dolist (w workers)
                     (when (member (worker-state w) '(:bound :standby))
                       (unless (%worker-process-alive-p w)
                         (let ((active-count
                                 (bt:with-lock-held (*pool-lock*)
                                   (length *recovery-threads*))))
                           (if (>= active-count *max-concurrent-recoveries*)
                               (log-event :warn "pool.monitor.recovery-deferred"
                                          "worker_id" (worker-id w)
                                          "active_recoveries" active-count
                                          "max" *max-concurrent-recoveries*)
                               (let ((thread nil))
                                 (bt:with-lock-held (*pool-lock*)
                                   (setf thread
                                         (bt:make-thread
                                          (lambda ()
                                            (unwind-protect
                                                (handler-case
                                                    (%handle-worker-crash w)
                                                  (error (e)
                                                    (log-event :error
                                                     "pool.monitor.recovery-error"
                                                     "worker_id" (worker-id w)
                                                     "error" (princ-to-string e))))
                                              (bt:with-lock-held (*pool-lock*)
                                                (setf *recovery-threads*
                                                      (remove thread
                                                              *recovery-threads*)))))
                                          :name (format nil "pool-recover-~A"
                                                        (worker-id w))))
                                   (push thread *recovery-threads*))))))))
                   ;; Ask each idle worker a real question and record the answer
                   (%check-worker-liveness workers)
                   ;; Reap zombie crashed workers
                   (dolist (w workers)
                     (when (eq (worker-state w) :crashed)
                       (let ((process (worker-process-info w)))
                         (when process
                           (ignore-errors (sb-ext:process-close process))))))
                   ;; Prune stale crash-history entries
                   (let ((window-start (- (get-universal-time) *crash-breaker-window*)))
                     (bt:with-lock-held (*pool-lock*)
                       (let ((stale nil))
                         (maphash (lambda (sid timestamps)
                                    (unless (some (lambda (ts) (>= ts window-start))
                                                  timestamps)
                                      (push sid stale)))
                                  *crash-history*)
                         (dolist (sid stale)
                           (remhash sid *crash-history*))))))
               (error (e)
                 (log-event :error "pool.monitor.loop-error"
                            "error" (princ-to-string e)))))))

(defun %start-health-monitor ()
  "Start the background health monitor thread."
  (setf *pool-running* t)
  (let ((interval *health-check-interval-seconds*))
    (setf *health-thread*
          (bt:make-thread
           (lambda ()
             (let ((*health-check-interval-seconds* interval))
               (%health-monitor-loop)))
           :name "pool-health-monitor"))))

;;; ---------------------------------------------------------------------------
;;; Public API — initialize
;;; ---------------------------------------------------------------------------

(defvar *init-lock* (bt:make-lock "pool-init-lock")
  "Serializes concurrent calls to initialize-pool.")

(defun initialize-pool ()
  "Initialize the worker pool and start the health monitor. Safe to call
multiple times (shuts down any existing pool first). Registers shutdown-pool
in sb-ext:*exit-hooks* to clean up workers on parent process exit.

Resolves the pool settings first, through resolve-pool-settings, so every
start reads the environment it runs under and a special bound around the
call wins in every pool thread. The validation below checks those resolved
values.

Pre-warms the worker system's fasl cache in the parent process before
allowing any concurrent worker spawn. When the cache is cold, two workers
spawning in parallel (warmup standby + on-demand session) would race
compiling the same package-inferred system files into the shared ASDF
output path, causing a fatal compile error in one of the children. Loading
the worker system here, under *init-lock*, ensures the fasls are on disk
before the replenish thread or any get-or-assign-worker call launches a
child. On a warm cache asdf:load-system returns immediately with no I/O.

Returns immediately after pre-warm; warm standby workers spawn
asynchronously via the replenish thread so the caller is not blocked on
subprocess launches beyond the one-time fasl compile on a cold cache."
  (bt:with-lock-held (*init-lock*)
    (let* ((settings (resolve-pool-settings))
           (max-size (pool-settings-max-pool-size settings))
           (warmup (pool-settings-warmup settings)))
      (unless (and (integerp max-size) (plusp max-size))
        (error "Invalid *max-pool-size*: must be a positive integer, got ~S"
               max-size))
      (unless (and (integerp warmup) (>= warmup 0))
        (error "Invalid *worker-pool-warmup*: must be a non-negative integer, got ~S"
               warmup))
      (when (> warmup max-size)
        (error "*worker-pool-warmup* (~D) exceeds *max-pool-size* (~D)"
               warmup max-size))
      (let ((min-age (pool-settings-pressure-kill-min-age-seconds settings)))
        (unless (and (integerp min-age) (>= min-age 0))
          (error "Invalid *pressure-kill-min-age-seconds*: must be a non-negative integer, got ~S"
                 min-age)))
      (let ((limit (pool-settings-max-hibernated-workers settings)))
        (unless (and (integerp limit) (>= limit 0))
          (error "Invalid *max-hibernated-workers*: must be a non-negative integer, got ~S"
                 limit)))
      (let ((attempts (pool-settings-max-resume-attempts settings)))
        (unless (and (integerp attempts) (plusp attempts))
          (error "Invalid *max-resume-attempts*: must be a positive integer, got ~S"
                 attempts))))
    (when *pool-running*
      (shutdown-pool))
    ;; Pre-warm the worker system's fasl cache so concurrent child spawns
    ;; never race to compile the same files. This is the fix for the cold
    ;; concurrent spawn race: both the warmup standby and an immediate
    ;; session worker call (asdf:load-system :dsmr-mcp/src/hermetic/worker/main)
    ;; in their SBCL child command line; without pre-warming, they compile
    ;; into the same shared cache simultaneously and one fatally aborts.
    ;; Loading here in the parent populates the cache once, serially, so
    ;; every child thereafter reads cached fasls and skips compilation.
    (handler-case
        (asdf:load-system :dsmr-mcp/src/hermetic/worker/main)
      (error (e)
        (log-event :warn "pool.worker-system.preload-failed"
                   "error" (princ-to-string e))))
    (bt:with-lock-held (*pool-lock*)
      (setf *affinity-map* (make-hash-table :test 'equal)
            *standby-workers* nil
            *all-workers* nil
            *recovery-threads* nil)
      (clrhash *crash-history*)
      (clrhash *circuit-breaker-map*))
    ;; Clear what servers that are no longer running left behind, then this
    ;; server's own core directory, which can only hold worlds of workers no
    ;; pool tracks any more. A start never fails over cleanup.
    (handler-case
        (pool-records:sweep-dead-owners
         :report-fn (lambda (level code &key subject msg)
                      (log-event level (format nil "pool.sweep.~A" code)
                                 "subject" subject
                                 "msg" msg)))
      (error (e)
        (log-event :warn "pool.sweep.failed" "error" (princ-to-string e))))
    (handler-case
        (let ((stem (server-stem)))
          (when stem
            (pool-records:remove-owner-directory stem)))
      (error (e)
        (log-event :warn "pool.hibernate.cleanup-failed"
                   "error" (princ-to-string e))))
    (%start-health-monitor)
    (start-pressure-agent)
    (pushnew 'shutdown-pool sb-ext:*exit-hooks*)
    (%schedule-replenish)
    (log-event :info "pool.initialized"
               "warmup_target" (effective-worker-pool-warmup)
               "max_pool_size" (effective-max-pool-size)
               "max_hibernated_workers" (effective-max-hibernated-workers))))

;;; ---------------------------------------------------------------------------
;;; Public API — shutdown
;;; ---------------------------------------------------------------------------

(defun shutdown-pool ()
  "Shut down all workers and clean up pool state. Stops the health monitor,
stops answering the host service (removing this server's worker record and the
requests waiting for it), waits for in-flight replenish/recovery/reaper
threads, then kills all workers.

A worker in the middle of a save is ended first, before anything waits on the
thread running the save, and loses only that save. Shutdown is bounded: it
never waits for a save to finish, so a server exit or restart takes seconds
however large the world being saved."
  (log-event :info "pool.shutting-down")
  ;; Stopping the pool and listing the saves under way happen in one hold of
  ;; *pool-lock*, the lock a save is started under, so no save can start
  ;; after the list is taken.
  (let ((saving (bt:with-lock-held (*pool-lock*)
                  (setf *pool-running* nil)
                  (remove-if-not (lambda (w) (eq (worker-state w) :hibernating))
                                 *all-workers*))))
    (dolist (w saving)
      (log-event :info "pool.shutdown.ending-save" "worker_id" (worker-id w))
      (ignore-errors (end-worker-process w))))
  ;; Wake health monitor so it exits promptly
  (bt:with-lock-held (*health-monitor-lock*)
    (%condition-broadcast *health-monitor-condvar*))
  ;; Join the health monitor thread
  (when (and *health-thread*
             (bt:threadp *health-thread*)
             (bt:thread-alive-p *health-thread*))
    (handler-case (bt:join-thread *health-thread*)
      (error () nil)))
  (setf *health-thread* nil)
  ;; Stop answering the host service before any worker goes, and take this
  ;; server's record and the requests waiting for it along.
  (stop-pressure-agent)
  ;; Wait for in-flight replenish thread
  (loop repeat 100
        while (bt:with-lock-held (*pool-lock*) *replenish-running*)
        do (sleep *shutdown-replenish-wait-seconds*))
  ;; Wait for in-flight recovery threads
  (let ((threads (bt:with-lock-held (*pool-lock*)
                   (copy-list *recovery-threads*))))
    (dolist (th threads)
      (when (bt:thread-alive-p th)
        (handler-case (bt:join-thread th)
          (error () nil)))))
  ;; Wait for in-flight reaper threads (from worker-client crashes)
  (let ((threads (bt:with-lock-held (*reaper-threads-lock*)
                   (copy-list *reaper-threads*)))
        (deadline (+ (get-internal-real-time)
                     (* 5 internal-time-units-per-second))))
    (dolist (th threads)
      (loop while (and (bt:thread-alive-p th)
                       (< (get-internal-real-time) deadline))
            do (sleep 0.1))
      (unless (bt:thread-alive-p th)
        (handler-case (bt:join-thread th)
          (error () nil)))))
  ;; Snapshot and kill all workers
  (let ((workers nil))
    (bt:with-lock-held (*pool-lock*)
      (setf workers (copy-list *all-workers*))
      (setf *all-workers* nil
            *standby-workers* nil)
      (clrhash *affinity-map*)
      (clrhash *circuit-breaker-map*)
      ;; Wake any request waiting on a save or a resume, so it sees the
      ;; pool stopping now rather than at its deadline.
      (%condition-broadcast *pool-transition-condvar*))
    (dolist (w workers) (ignore-errors (kill-worker w))))
  ;; Every world this server saved belongs to a worker that is now gone.
  (handler-case
      (let ((stem (server-stem)))
        (when stem
          (pool-records:remove-owner-directory stem)))
    (error (e)
      (log-event :warn "pool.hibernate.cleanup-failed"
                 "error" (princ-to-string e))))
  (log-event :info "pool.shutdown-complete"))

;;; ---------------------------------------------------------------------------
;;; Public API — get-or-assign-worker
;;; ---------------------------------------------------------------------------

(defun find-session-worker (session-id)
  "Return the worker bound to SESSION-ID if alive, NIL otherwise.
Does not spawn. Used when a tool call needs to route to an existing worker
without creating a new one."
  (bt:with-lock-held (*pool-lock*)
    (let ((entry (gethash session-id *affinity-map*)))
      (when (and entry (typep entry 'worker)
                 (eq :bound (worker-state entry)))
        entry))))

(defun %transition-wait-seconds ()
  "How long a request waits for its session's worker to finish saving or
resuming before it gives up: the longest a save may take, including the time
the pool goes on listening for a late answer, plus the longest a process may
take to come up, fresh or resumed, plus a margin."
  (+ *hibernate-timeout-seconds*
     *hibernate-late-answer-seconds*
     (max (effective-worker-startup-timeout) (effective-worker-resume-timeout))
     15))

(defun %delete-core-files (path)
  "Delete the saved core at PATH and the partial <PATH>.tmp a save in progress
writes first, whichever exist. A link is removed as a link. Errors are
ignored: the file may already be gone."
  (when path
    (let ((native (uiop:native-namestring path)))
      (ignore-errors (sb-posix:unlink native))
      (ignore-errors (sb-posix:unlink (concatenate 'string native ".tmp"))))))

(defun %worker-core-file (worker)
  "Where WORKER's world is or would be saved: the core it was hibernated to,
else the path a save of it writes, which follows its id. NIL when this
process cannot name itself. A worker let go in the middle of a save has no
recorded core yet, and the partial file of that save must still be found."
  (or (worker-hibernate-core-path worker)
      (ignore-errors
       (let ((stem (server-stem)))
         (and stem (uiop:native-namestring
                    (hibernated-core-path stem (worker-id worker))))))))

(defun %finish-resume (session-id worker path)
  "Put WORKER, whose process resume-worker has just started from the core at
PATH, back into service, and return it.

The core is deleted while the worker is still :resuming. A :bound worker can
be saved again at once, to the same path because the path follows the worker
id, and deleting afterwards could remove that newer world.

When the session let the worker go while it was resuming (a release, a kill
or a shutdown changed its state), the new process belongs to nobody: it is
ended and pool-spawn-cancelled is signalled, as for a spawn cancelled the
same way."
  (%delete-core-files path)
  (let ((serving nil))
    (bt:with-lock-held (*pool-lock*)
      (when (eq (worker-state worker) :resuming)
        (setf (worker-state worker) :bound
              (worker-hibernate-core-path worker) nil
              (worker-hibernated-at worker) nil
              (worker-core-bytes worker) nil
              (worker-resume-failure worker) nil
              (worker-resume-deferrals worker) 0
              serving t))
      (%condition-broadcast *pool-transition-condvar*))
    (cond
      (serving
       (log-event :info "pool.worker.resumed"
                  "session" session-id
                  "worker_id" (worker-id worker)
                  "ms" (worker-last-resume-milliseconds worker))
       worker)
      (t
       (log-event :info "pool.resume.cancelled"
                  "session" session-id
                  "worker_id" (worker-id worker)
                  "state" (string-downcase (symbol-name (worker-state worker))))
       (ignore-errors (kill-worker worker))
       (error 'pool-spawn-cancelled :session-id session-id)))))

(defun %fail-resume (session-id worker path cause)
  "Take WORKER, whose saved world at PATH could not be resumed for CAUSE, out
of service, and return NIL.

The worker becomes :dead with a reset reason naming CAUSE and stays the
session's entry, so whichever request reaches it first replaces it with a
fresh worker carrying that notice, and no request can be handed a fresh
worker without it. It leaves *all-workers* at once. This is not a crash:
nothing is added to the crash history and the breaker is not touched.

The core is kept under the failed-core directory for diagnosis, the failure
is logged as an error, and a line goes to the fleet error log that leaders
watch, so a lost world is never silent. When the session let the worker go
meanwhile, there is no one to tell and pool-spawn-cancelled is signalled."
  (let ((lost nil)
        (kept-at nil))
    (bt:with-lock-held (*pool-lock*)
      (when (eq (worker-state worker) :resuming)
        (setf (worker-state worker) :dead
              (worker-reset-reason worker)
              (format nil "its hibernated world could not be resumed (~A)" cause)
              *all-workers* (remove worker *all-workers*)
              lost t))
      (%condition-broadcast *pool-transition-condvar*))
    (unless lost
      (log-event :info "pool.resume.cancelled"
                 "session" session-id
                 "worker_id" (worker-id worker)
                 "cause" cause)
      (error 'pool-spawn-cancelled :session-id session-id))
    (when (and path (%core-file-bytes path))
      (handler-case
          (setf kept-at (uiop:native-namestring
                         (pool-records:retain-failed-core
                          path (server-stem) (worker-id worker))))
        (error (e)
          (log-event :warn "pool.resume.core-not-kept"
                     "session" session-id
                     "worker_id" (worker-id worker)
                     "error" (princ-to-string e)))))
    (log-event :error "pool.worker.resume-failed"
               "session" session-id
               "worker_id" (worker-id worker)
               "cause" cause
               "kept_at" (or kept-at "none"))
    (ignore-errors
     (append-fleet-line
      (fleet-line :error "worker-resume-failed"
                  :id session-id
                  :msg (format nil "worker ~D of session ~A: ~A; core kept at ~A"
                               (worker-id worker) session-id cause
                               (or kept-at "nowhere")))))
    nil))

(defun %defer-resume (session-id worker cause)
  "Put WORKER, whose resume failed for CAUSE in a way that may pass, back to
:hibernated with its core untouched, and remember CAUSE on it so requests that
were waiting on this resume are told the same rather than each trying again at
once. Returns T. Nothing is lost, so no notice is armed and the crash record
is left alone. The failure is counted on the worker, so that
%resume-hibernated-worker gives the world up once *max-resume-attempts*
resumes in a row have failed, and the first failure of a run writes a warning
to the fleet log, so a leader sees a world that has stopped resuming before
it is given up. When the session let the worker go meanwhile,
pool-spawn-cancelled is signalled instead."
  (let ((deferred nil)
        (count 0))
    (bt:with-lock-held (*pool-lock*)
      (when (eq (worker-state worker) :resuming)
        (setf (worker-state worker) :hibernated
              (worker-resume-failure worker) cause
              count (incf (worker-resume-deferrals worker))
              deferred t))
      (%condition-broadcast *pool-transition-condvar*))
    (unless deferred
      (log-event :info "pool.resume.cancelled"
                 "session" session-id
                 "worker_id" (worker-id worker)
                 "cause" cause)
      (error 'pool-spawn-cancelled :session-id session-id))
    (log-event :warn "pool.resume.deferred"
               "session" session-id
               "worker_id" (worker-id worker)
               "attempt" count
               "cause" cause)
    (when (= count 1)
      (ignore-errors
       (append-fleet-line
        (fleet-line :warn "worker-resume-deferred"
                    :id session-id
                    :msg (format nil "worker ~D of session ~A could not be resumed ~
                                      (~A); its world is still saved and is given ~
                                      up after ~D failures like this in a row"
                                 (worker-id worker) session-id cause
                                 (effective-max-resume-attempts))))))
    t))

(defun %resume-hibernated-worker (session-id worker)
  "Resume WORKER, which this thread has marked :resuming, from its saved core.
Runs without *pool-lock*, which is taken only to settle the state.

Returns WORKER, :bound again with the world it had, or NIL when the world can
never be resumed (no core recorded, the file missing, the runtime refusing it,
or the runtime that wrote it gone), in which case the session's next pass gets
a fresh worker with a reset notice.

Any other failure may pass: the handshake ran out of time on a slow disk, the
kernel refused the fork for memory, the process was killed while it loaded.
Then the world is not given up. The worker goes back to :hibernated with its
core in place and pool-resume-deferred is signalled, so this call fails with
an error saying so and the session's next call tries again. Once
*max-resume-attempts* resumes in a row have failed that way, the last failure
is taken as final instead, as above.

Signals pool-spawn-cancelled when the session let the worker go while it was
resuming."
  (let* ((path (worker-hibernate-core-path worker))
         (final (cond ((null path) "no saved core was recorded")
                      ((not (%core-file-bytes path))
                       (format nil "the saved core ~A is missing" path))))
         (passing nil)
         (settled nil))
    (unwind-protect
         (progn
           (unless final
             (handler-case (resume-worker worker)
               (error (e)
                 (if (worker-spawn-failure-final-p e)
                     (setf final (princ-to-string e))
                     (setf passing (princ-to-string e)))))
             ;; A failure that may pass, repeated this often, is taken as
             ;; permanent: nothing else would ever stop the retries.
             (let ((attempts (1+ (worker-resume-deferrals worker))))
               (when (and passing (>= attempts (effective-max-resume-attempts)))
                 (setf final (format nil "~D resumes in a row failed, the last: ~A"
                                     attempts passing)
                       passing nil))))
           (cond
             (final
              (multiple-value-prog1 (%fail-resume session-id worker path final)
                (setf settled t)))
             (passing
              (%defer-resume session-id worker passing)
              (setf settled t)
              (error 'pool-resume-deferred :session-id session-id :cause passing))
             (t
              (multiple-value-prog1 (%finish-resume session-id worker path)
                (setf settled t)))))
      ;; Only an unexpected unwind, such as an interrupt, gets here unsettled.
      ;; The worker goes back to hibernated, so no request waits on it for
      ;; ever, and any process the resume had started is ended.
      (unless settled
        (let ((reverted nil))
          (bt:with-lock-held (*pool-lock*)
            (when (eq (worker-state worker) :resuming)
              (setf (worker-state worker) :hibernated
                    reverted t))
            (%condition-broadcast *pool-transition-condvar*))
          (when reverted
            (ignore-errors (release-worker-process worker))))))))

(defun get-or-assign-worker (session-id)
  "Return the worker bound to SESSION-ID, assigning one if needed.
If a standby worker is available, it is assigned immediately; otherwise
a new worker is spawned. Multiple concurrent threads requesting the same
new session coordinate via a placeholder so only one spawn occurs.

A session whose worker is hibernated gets that same worker back, resumed from
its saved core with the world it had, and no reset notice: the session never
sees that it was on disk. A request that arrives while the worker is saving
or resuming waits for that to finish, so every concurrent request gets the
same worker and only one process is ever started. Only when the core can never
be resumed does the session get a fresh worker, and then its next reply says
its world was reset and why. A resume that failed in a way that may pass
leaves the worker hibernated with its core, and signals pool-resume-deferred
to this request and to every request that waited on it; the next call tries
again, until *max-resume-attempts* resumes in a row have failed and the world
is given up as above. None of this counts toward the circuit breaker.

Circuit breaker: before spawning, checks *circuit-breaker-map* for a recent
trip within *circuit-breaker-cooldown* seconds and fails fast with an error.

Signals pool-shutting-down if the pool is not running.
Signals pool-capacity-exceeded if max workers would be exceeded, including
when resuming a hibernated worker would exceed it; that worker stays
hibernated.
Signals circuit-breaker-active both when the breaker trips and on any later
call inside the cooldown window; the condition carries the seconds remaining.
Signals an error naming the session and the state when a save or resume it
waited on has not finished within %transition-wait-seconds."
  (let ((transition-deadline nil)
        (waited-on-resume nil))
    (loop
      (let ((entry nil) (need-spawn nil) (assigned-from-standby nil)
            (need-reset nil) (reset-reason nil) (old-worker-to-kill nil)
            (circuit-breaker-tripped nil) (to-resume nil))
        (bt:with-lock-held (*pool-lock*)
          ;; Read the entry, waiting out a save or a resume in progress. The
          ;; wait releases *pool-lock*; every pass re-reads everything.
          (loop
            (unless *pool-running*
              (error 'pool-shutting-down))
            ;; Check circuit-breaker cooldown BEFORE anything else.
            ;; Blocks calls during the fail-fast window after the breaker trips.
            (let ((trip-time (gethash session-id *circuit-breaker-map*)))
              (when (and trip-time
                         (< (get-universal-time)
                            (+ trip-time *circuit-breaker-cooldown*)))
                (let ((remaining (- (+ trip-time *circuit-breaker-cooldown*)
                                    (get-universal-time))))
                  (error 'circuit-breaker-active
                         :session-id session-id
                         :remaining-seconds (ceiling remaining)))))
            (setf entry (gethash session-id *affinity-map*))
            (unless (and (typep entry 'worker)
                         (member (worker-state entry) '(:hibernating :resuming)))
              (return))
            (when (eq (worker-state entry) :resuming)
              (setf waited-on-resume entry))
            (let ((now (get-internal-real-time)))
              (unless transition-deadline
                (setf transition-deadline
                      (+ now (* (%transition-wait-seconds)
                                internal-time-units-per-second))))
              (when (>= now transition-deadline)
                (error "Gave up waiting for session ~A's worker, still ~(~A~) after ~D s."
                       session-id (worker-state entry) (%transition-wait-seconds)))
              (bt:condition-wait *pool-transition-condvar* *pool-lock*
                                 :timeout (/ (- transition-deadline now)
                                             internal-time-units-per-second))))
          (cond
            ;; Path 1: existing bound worker, returned immediately
            ((and entry (typep entry 'worker) (eq :bound (worker-state entry)))
             (return-from get-or-assign-worker entry))
            ;; Path 1a: hibernated worker, resumed outside the lock when
            ;; the pool has room for its process.
            ((and entry (typep entry 'worker) (eq :hibernated (worker-state entry)))
             ;; This request waited on a resume that failed in a way that may
             ;; pass: it gets the same answer as the request that tried, and
             ;; the session's next call tries again.
             (when (and (eq entry waited-on-resume) (worker-resume-failure entry))
               (error 'pool-resume-deferred
                      :session-id session-id
                      :cause (worker-resume-failure entry)))
             (let ((limit (effective-max-pool-size)))
               (when (>= (%effective-pool-size) limit)
                 (error 'pool-capacity-exceeded :limit limit)))
             (setf (worker-state entry) :resuming
                   to-resume entry)
             (%condition-broadcast *pool-transition-condvar*))
            ;; Path 1b: existing dead/crashed worker, removed and reassigned
            ((and entry (typep entry 'worker)
                  (member (worker-state entry) '(:crashed :dead :released)))
             (setf old-worker-to-kill entry)
             (remhash session-id *affinity-map*)
             (setf *all-workers* (remove entry *all-workers*))
             ;; Record crash for circuit breaker (avoid double-counting if
             ;; %handle-worker-crash already pushed for this worker).
             (when (and (eq :crashed (worker-state entry))
                        (not (worker-crash-history-pushed-p entry)))
               (let* ((now (get-universal-time))
                      (window-start (- now *crash-breaker-window*))
                      (history (gethash session-id *crash-history*)))
                 (setf history (remove-if (lambda (ts) (< ts window-start)) history))
                 (push now history)
                 (setf (gethash session-id *crash-history*) history)
                 (when (>= (length history) *crash-breaker-threshold*)
                   (setf circuit-breaker-tripped t))))
             ;; Also check if health monitor already pushed enough history to trip it
             (when (and (not circuit-breaker-tripped)
                        (eq :crashed (worker-state entry))
                        (worker-crash-history-pushed-p entry))
               (let ((window-start (- (get-universal-time) *crash-breaker-window*))
                     (history (gethash session-id *crash-history*)))
                 (setf history (remove-if (lambda (ts) (< ts window-start)) history))
                 (setf (gethash session-id *crash-history*) history)
                 (when (>= (length history) *crash-breaker-threshold*)
                   (setf circuit-breaker-tripped t))))
             (setf entry nil
                   need-reset (not (worker-needs-reset-notification old-worker-to-kill)))
             ;; A worker lost for a reason the pool recorded (it died while
             ;; saving its world, or its world could not be resumed) is no
             ;; crash: no history was pushed above, and the session is told
             ;; why in the notice.
             (when (and (eq :dead (worker-state old-worker-to-kill))
                        (worker-reset-reason old-worker-to-kill))
               (setf need-reset t
                     reset-reason (worker-reset-reason old-worker-to-kill))))
            ;; A worker struct in any other state never belongs in the map.
            ((and entry (typep entry 'worker))
             (error "Session ~A's worker is in a state no session worker should have: ~(~A~)."
                    session-id (worker-state entry)))
            ;; Path 2: placeholder; another thread is spawning
            ((and entry (typep entry 'worker-placeholder))
             nil))
          ;; Assign standby or insert placeholder for spawn
          (when (and (null entry) (null to-resume) (not circuit-breaker-tripped))
            (loop while *standby-workers*
                  for w = (pop *standby-workers*)
                  do (cond
                       ((%worker-process-alive-p w)
                        (setf (worker-state w) :bound
                              (worker-session-id w) session-id
                              (gethash session-id *affinity-map*) w)
                        (when need-reset
                          (setf (worker-needs-reset-notification w) t
                                (worker-reset-reason w) reset-reason))
                        (setf assigned-from-standby w)
                        (return))
                       (t
                        (setf *all-workers* (remove w *all-workers*))
                        (log-event :warn "pool.standby.dead-on-assign"
                                   "worker_id" (worker-id w)
                                   "pid" (worker-pid w)))))
            (when (and (null assigned-from-standby) (null entry))
              (let ((limit (effective-max-pool-size)))
                (when (>= (%effective-pool-size) limit)
                  (error 'pool-capacity-exceeded :limit limit)))
              (let ((ph (make-worker-placeholder :session-id session-id)))
                (setf (gethash session-id *affinity-map*) ph
                      entry ph
                      need-spawn t)))))
        (cond
          (to-resume
           ;; NIL means the core could not be resumed: the entry is now :dead
           ;; with a reset reason, and the next pass replaces it through
           ;; Path 1b with a notice saying why.
           (let ((resumed (%resume-hibernated-worker session-id to-resume)))
             (when resumed
               (return resumed))))
          (t
           ;; Kill orphaned old worker outside the lock (kill-worker may block ~2s)
           (when old-worker-to-kill
             (ignore-errors (kill-worker old-worker-to-kill)))
           ;; Circuit breaker: record trip time and fail fast
           (when circuit-breaker-tripped
             (bt:with-lock-held (*pool-lock*)
               ;; Record the trip time for the 60s fail-fast window
               (setf (gethash session-id *circuit-breaker-map*) (get-universal-time))
               (remhash session-id *crash-history*))
             (log-event :error "pool.circuit-breaker.tripped"
                        "session" session-id
                        "threshold" *crash-breaker-threshold*
                        "window_seconds" *crash-breaker-window*
                        "cooldown_seconds" *circuit-breaker-cooldown*)
             (error 'circuit-breaker-active
                    :session-id session-id
                    :remaining-seconds *circuit-breaker-cooldown*))
           (return
             (cond
               (assigned-from-standby
                (%schedule-replenish)
                assigned-from-standby)
               (need-spawn
                (%spawn-and-bind session-id entry :need-reset need-reset
                                                  :reset-reason reset-reason))
               (t
                (%wait-for-placeholder entry))))))))))

;;; ---------------------------------------------------------------------------
;;; Public API — release-session
;;; ---------------------------------------------------------------------------

(defun release-session (session-id)
  "Release the worker bound to SESSION-ID. Kills the worker and removes it
from the pool. Also clears circuit-breaker state so a manual reset works.
A world the worker had saved to disk goes with it: the core is deleted.

If a spawn is in progress (placeholder), marks it as cancelled so the
spawn thread will clean up the worker after it completes. A worker in the
middle of saving is released the same way: its saving child ends with it, the
partial core is deleted, and a save that finished meanwhile, finding it
released, deletes the core it wrote."
  (let ((worker-to-kill nil)
        (core-path nil))
    (bt:with-lock-held (*pool-lock*)
      (let ((entry (gethash session-id *affinity-map*)))
        (cond
          ((and entry (typep entry 'worker))
           (setf worker-to-kill entry
                 core-path (worker-hibernate-core-path entry))
           (setf (worker-state worker-to-kill) :released)
           (remhash session-id *affinity-map*)
           (remhash session-id *crash-history*)
           ;; Clear the circuit breaker map so release-session serves as
           ;; a manual reset.
           (remhash session-id *circuit-breaker-map*)
           (setf *all-workers* (remove worker-to-kill *all-workers*)))
          ((and entry (typep entry 'worker-placeholder))
           (setf (worker-placeholder-cancelled entry) t)
           (remhash session-id *affinity-map*)
           (remhash session-id *crash-history*)
           (remhash session-id *circuit-breaker-map*)
           (log-event :info "pool.session.cancelled-spawn"
                      "session" session-id))))
      (%condition-broadcast *pool-transition-condvar*))
    (when worker-to-kill
      (log-event :info "pool.session.released"
                 "session" session-id
                 "worker_id" (worker-id worker-to-kill))
      ;; SIGTERM first to break any in-flight RPC holding stream-lock,
      ;; then kill-worker can acquire it without deadlock.
      (ignore-errors (signal-worker-terminate worker-to-kill))
      (ignore-errors (kill-worker worker-to-kill))
      (%delete-core-files (or core-path (%worker-core-file worker-to-kill)))
      (%schedule-replenish))))

;;; ---------------------------------------------------------------------------
;;; Public API — kill-session-worker
;;; ---------------------------------------------------------------------------

(defun kill-session-worker (session-id &key reset)
  "Kill the worker bound to SESSION-ID without ending the session.
Unlike release-session, the session remains active — the next tool call
will spawn a fresh worker via get-or-assign-worker. A world the worker had
saved to disk is deleted with it.

Clears crash history so the intentional kill does not count toward the
circuit breaker. When RESET is true, also clears *circuit-breaker-map*
for this session (manual breaker reset).

Returns :killed if a worker was found and killed, :no-worker if none
was bound, :placeholder if a spawn was in progress (cancelled)."
  (let ((worker-to-kill nil)
        (core-path nil)
        (kill-result :no-worker))
    (bt:with-lock-held (*pool-lock*)
      (let ((entry (gethash session-id *affinity-map*)))
        (cond
          ((and entry (typep entry 'worker))
           (setf worker-to-kill entry
                 core-path (worker-hibernate-core-path entry)
                 kill-result :killed)
           (setf (worker-state worker-to-kill) :released)
           (remhash session-id *affinity-map*)
           (remhash session-id *crash-history*)
           (when reset (remhash session-id *circuit-breaker-map*))
           (setf *all-workers* (remove worker-to-kill *all-workers*)))
          ((and entry (typep entry 'worker-placeholder))
           (setf (worker-placeholder-cancelled entry) t
                 kill-result :placeholder)
           (remhash session-id *affinity-map*)
           (remhash session-id *crash-history*)
           (when reset (remhash session-id *circuit-breaker-map*)))))
      (%condition-broadcast *pool-transition-condvar*))
    (when worker-to-kill
      (log-event :info "pool.session.worker-killed"
                 "session" session-id
                 "worker_id" (worker-id worker-to-kill))
      (ignore-errors (signal-worker-terminate worker-to-kill))
      (ignore-errors (kill-worker worker-to-kill))
      (%delete-core-files (or core-path (%worker-core-file worker-to-kill)))
      (%schedule-replenish))
    kill-result))

;;; ---------------------------------------------------------------------------
;;; Public API: acquiring a session's worker for one call
;;; ---------------------------------------------------------------------------

(defparameter *acquire-attempts* 5
  "How many times call-with-session-worker asks for the session's worker before
giving up. Each retry means the worker it was given stopped being usable in
between, which takes a save, a stop or a crash landing in that instant, so a
handful of passes is already far beyond anything ordinary.")

(defun call-with-session-worker (session-id function)
  "Call FUNCTION with SESSION-ID's worker, holding that worker for the call.

The worker is taken in the same *pool-lock* hold that checks it is still the
session's worker and still :bound, by counting one more call in flight on it,
and it is handed back when FUNCTION returns or unwinds. Hibernating a worker
and stopping it under memory pressure both check that no call is in flight and
change the state within one hold of the same lock, so either the call took the
worker first and they refuse it as busy, or they acted first and this sees the
worker is no longer :bound. In that case the worker is not used at all: the
request goes back through get-or-assign-worker, which hands out a usable one,
and no call ever reaches a worker that is saving, saved or stopped.

Signals an error naming the session when no usable worker could be held after
*acquire-attempts* passes; get-or-assign-worker's own conditions pass through."
  (loop repeat *acquire-attempts*
        do (let ((worker (get-or-assign-worker session-id))
                 (acquired nil))
             (when *after-assign-hook*
               (funcall *after-assign-hook* worker))
             (bt:with-lock-held (*pool-lock*)
               (when (and (eq (gethash session-id *affinity-map*) worker)
                          (eq (worker-state worker) :bound))
                 (incf (worker-in-flight worker))
                 (setf (worker-last-activity worker) (%unix-now)
                       acquired t)))
             (when acquired
               (return-from call-with-session-worker
                 (unwind-protect (funcall function worker)
                   (bt:with-lock-held (*pool-lock*)
                     (setf (worker-in-flight worker)
                           (max 0 (1- (worker-in-flight worker)))
                           (worker-last-activity worker) (%unix-now))
                     (%condition-broadcast *pool-transition-condvar*)))))
             (log-event :debug "pool.acquire.retry"
                        "session" session-id
                        "worker_id" (worker-id worker)
                        "state" (string-downcase
                                 (symbol-name (worker-state worker))))))
  (error "No usable worker could be held for session ~A after ~D attempts."
         session-id *acquire-attempts*))

(defmacro with-session-worker ((var session-id) &body body)
  "Evaluate BODY with VAR bound to SESSION-ID's worker, held for the duration
of BODY as call-with-session-worker holds it."
  `(call-with-session-worker ,session-id (lambda (,var) ,@body)))

;;; ---------------------------------------------------------------------------
;;; Public API: hibernating a session's worker
;;; ---------------------------------------------------------------------------

(defparameter *died-while-hibernating-reason*
  "its worker died while hibernating, most likely killed for memory"
  "The reset reason a session is given when its worker died during a save and
left no core behind. A save can briefly need twice the worker's memory, so on
a host already short of it the kernel is the likeliest cause.")

(defparameter *unanswered-hibernate-reason*
  "its worker stopped answering while hibernating and was ended"
  "The reset reason a session is given when its worker did not answer a
request to hibernate in time and left no finished core. The worker may still
have been saving, so it is ended rather than put back in service, where its
session's next call would find it gone and count a crash.")

(defun %return-to-service (worker reason)
  "Put WORKER, marked :hibernating, back to :bound and keep REASON, a word, as
why it was not hibernated. Leaves a worker whose state something else changed
in the meantime alone."
  (bt:with-lock-held (*pool-lock*)
    (when (eq (worker-state worker) :hibernating)
      (setf (worker-state worker) :bound))
    (setf (worker-refused-reason worker) reason
          (worker-refused-at worker) (%unix-now))))

(defun %core-file-bytes (path)
  "The size of the regular file PATH in bytes, or NIL when there is none."
  (handler-case
      (let ((stat (sb-posix:stat (uiop:native-namestring path))))
        (and (sb-posix:s-isreg (sb-posix:stat-mode stat))
             (sb-posix:stat-size stat)))
    (error () nil)))

(defun %finish-hibernation (session-id worker path result milliseconds)
  "Record WORKER, whose world is saved at PATH, as :hibernated.

The worker's process and channel are let go first, outside *pool-lock*. When
the session let the worker go while it was saving (it is no longer
:hibernating), the saved world belongs to nobody and the file is deleted.
RESULT is the worker's reply, or NIL when there was none to read. Returns the
outcome and reason for hibernate-session-worker."
  (release-worker-process worker)
  (let ((bytes (or (and (hash-table-p result) (gethash "bytes" result))
                   (%core-file-bytes path)))
        (kept nil))
    (bt:with-lock-held (*pool-lock*)
      (when (eq (worker-state worker) :hibernating)
        (setf (worker-state worker) :hibernated
              (worker-hibernate-core-path worker) (uiop:native-namestring path)
              (worker-hibernated-at worker) (%unix-now)
              (worker-core-bytes worker) bytes
              (worker-last-hibernate-milliseconds worker) milliseconds
              kept t)))
    (cond
      (kept
       (log-event :info "pool.worker.hibernated"
                  "session" session-id
                  "worker_id" (worker-id worker)
                  "bytes" (or bytes "unknown")
                  "ms" milliseconds)
       (values :hibernated nil))
      (t
       (%delete-core-files path)
       (log-event :info "pool.hibernate.discarded"
                  "session" session-id
                  "worker_id" (worker-id worker)
                  "state" (string-downcase (symbol-name (worker-state worker))))
       (values :not-eligible (string-downcase
                              (symbol-name (worker-state worker))))))))

(defun %lose-worker-during-hibernation (session-id worker
                                        &key (reason *died-while-hibernating-reason*)
                                             (code "worker-hibernate-died")
                                             (outcome :died))
  "Take WORKER, which left no core while saving, out of service.

Its process and channel are let go outside *pool-lock*. Under the lock it
becomes :dead with REASON, the sentence the session will be told, and it stays
the session's entry, so the session's next call gets a fresh worker carrying
that reset notice. This is not a crash: nothing is added to the crash history
and the breaker is not touched. The loss is logged as an error and written to
the fleet log under CODE. Returns OUTCOME and \"died\" for
hibernate-session-worker. When the session let the worker go meanwhile, or
the pool is shutting down and ended the save itself, there is no one to tell, nothing more is done, and the reason returned is
\"released\". Either way the partial core the save may have left is deleted,
once the worker's process is gone."
  (release-worker-process worker)
  (let ((scratch (%worker-core-file worker)))
    (when scratch
      (ignore-errors
       (sb-posix:unlink (concatenate 'string scratch ".tmp")))))
  (let ((lost nil))
    (bt:with-lock-held (*pool-lock*)
      (cond
        ((not (eq (worker-state worker) :hibernating)))
        ;; The pool is stopping and ended the save itself: nothing was lost
        ;; that anyone will ask for, so it is not reported as a loss.
        ((not *pool-running*)
         (setf (worker-state worker) :dead))
        (t
         (setf (worker-state worker) :dead
               (worker-reset-reason worker) reason
               *all-workers* (remove worker *all-workers*)
               lost t))))
    (when lost
      (log-event :error "pool.worker.died-during-hibernate"
                 "session" session-id
                 "worker_id" (worker-id worker)
                 "reason" reason)
      (ignore-errors
       (append-fleet-line
        (fleet-line :error code
                    :id session-id
                    :msg (format nil "worker ~D of session ~A: ~A"
                                 (worker-id worker) session-id reason)))))
    (values outcome (if lost "died" "released"))))

(defun %hibernate-marked-worker (session-id worker)
  "Save the world of WORKER, already marked :hibernating, and settle its state.
Runs without *pool-lock*, which is taken only for each state change. Returns
the outcome and reason for hibernate-session-worker."
  (let* ((id (worker-id worker))
         (pid (worker-pid worker))
         (stem (server-stem))
         (dir (handler-case (ensure-owner-directory stem)
                (error (e)
                  (log-event :warn "pool.hibernate.refused"
                             "session" session-id
                             "worker_id" id
                             "reason" "bad-path"
                             "error" (princ-to-string e))
                  (%return-to-service worker "bad-path")
                  (return-from %hibernate-marked-worker
                    (values :refused "bad-path")))))
         (path (hibernated-core-path stem id))
         (expected (expected-core-bytes pid)))
    (multiple-value-bind (allowed free)
        (disk-allows-hibernation-p dir expected
                                   :free-fn *free-disk-bytes-function*)
      (unless allowed
        (log-event :warn "pool.hibernate.refused"
                   "session" session-id
                   "worker_id" id
                   "reason" "disk"
                   "free_bytes" (or free "unknown")
                   "expected_bytes" expected)
        (%return-to-service worker "disk")
        (return-from %hibernate-marked-worker (values :disk "disk"))))
    (let ((started (get-internal-real-time)))
      (multiple-value-bind (outcome detail message)
          (handler-case (funcall *hibernate-worker-process-function* worker path)
            (error (e)
              (log-event :error "pool.hibernate.error"
                         "session" session-id
                         "worker_id" id
                         "error" (princ-to-string e))
              (values :died nil)))
        (let ((milliseconds (round (* 1000 (- (get-internal-real-time) started))
                                   internal-time-units-per-second)))
          (case outcome
            (:hibernated
             (%finish-hibernation session-id worker path detail milliseconds))
            (:refused
             (log-event :info "pool.hibernate.refused"
                        "session" session-id
                        "worker_id" id
                        "reason" detail
                        "message" (or message ""))
             (%return-to-service worker detail)
             (values :refused detail))
            (:timeout
             ;; The worker's own deadline is shorter than this wait, so it
             ;; should always have answered first; this is the backstop. Its
             ;; answer may still be on the way, and it may still be saving,
             ;; so it never goes back to serving: it is ended, and a core it
             ;; finished is kept as the session's world.
             (log-event :error "pool.hibernate.timeout"
                        "session" session-id
                        "worker_id" id
                        "ms" milliseconds)
             (release-worker-process worker)
             (bt:with-lock-held (*pool-lock*)
               (setf (worker-refused-reason worker) "timeout"
                     (worker-refused-at worker) (%unix-now)))
             (if (%core-file-bytes path)
                 (%finish-hibernation session-id worker path nil milliseconds)
                 (%lose-worker-during-hibernation
                  session-id worker
                  :reason *unanswered-hibernate-reason*
                  :code "worker-hibernate-timeout"
                  :outcome :timeout)))
            (t
             ;; The channel ended without a reply. A core on disk means the
             ;; save finished and only the answer was lost.
             (if (%core-file-bytes path)
                 (%finish-hibernation session-id worker path nil milliseconds)
                 (%lose-worker-during-hibernation session-id worker)))))))))

(defun %holds-saved-world-p (worker)
  "True when WORKER's world is on disk or on its way there or back: it is
hibernated, being saved, or being resumed. A resume that fails in a way that
may pass leaves the world on disk, so a resuming worker still owns its core."
  (and (member (worker-state worker) '(:hibernated :hibernating :resuming)) t))

(defun %saved-worker-count ()
  "How many of this pool's workers hold a saved world (%holds-saved-world-p).
Must be called with *pool-lock* held."
  (count-if #'%holds-saved-world-p *all-workers*))

(defun hibernate-session-worker (session-id &key ((:worker expected)))
  "Have SESSION-ID's worker save its whole world to disk and end its process,
so it holds no memory until the session needs it again.

Returns (values OUTCOME REASON), OUTCOME being one of:
  :hibernated    the world is saved and the process is gone; the worker is
                 :hibernated and no longer counts against the pool size.
  :busy          a call is holding the worker; it is left serving.
  :not-eligible  the session has no worker, or it is not :bound (REASON
                 names the state), or the pool is not running, or WORKER
                 was given and the session's worker is no longer that one
                 (REASON is replaced).
  :refused       the worker declined (REASON is its word: has-threads when
                 the session started threads of its own, fork-failed when the
                 saving child could not be started, a save that failed, or
                 bad-path); it is left serving.
  :at-limit      this server already keeps *max-hibernated-workers* workers
                 hibernated, saving or resuming; it is left serving.
  :disk          less than twice the expected core size is free; it is left
                 serving. This check applies under the limit as well.
  :timeout       no answer in time and no finished core. The worker may still
                 have been saving, so it is ended, never put back to serving;
                 its session gets a fresh worker and a reset notice saying so
                 on its next call. (When a finished core is there after all,
                 the outcome is :hibernated.)
  :died          it died during the save and left no core; its session gets a
                 fresh worker and a reset notice saying so on its next call.

A worker is refused rather than saved whenever saving it could lose work it is
doing or make a short host worse: a call in flight, a thread of the session's
own, a server already keeping as many saved worlds as it may, or a disk
without room for the core. The reason and time of a refusal are
kept on the worker. The worker is marked :hibernating under *pool-lock*, which
is never held across the save; no call can be handed the worker meanwhile, and
none of these outcomes counts as a crash."
  (let ((worker nil))
    (bt:with-lock-held (*pool-lock*)
      (let ((entry (gethash session-id *affinity-map*)))
        (cond
          ((not *pool-running*)
           (return-from hibernate-session-worker
             (values :not-eligible "pool-not-running")))
          ((not (typep entry 'worker))
           (return-from hibernate-session-worker
             (values :not-eligible (if entry "spawning" "no-worker"))))
          ((and expected (not (eq entry expected)))
           (return-from hibernate-session-worker
             (values :not-eligible "replaced")))
          ((not (eq (worker-state entry) :bound))
           (return-from hibernate-session-worker
             (values :not-eligible
                     (string-downcase (symbol-name (worker-state entry))))))
          ((plusp (worker-in-flight entry))
           (setf (worker-refused-reason entry) "busy"
                 (worker-refused-at entry) (%unix-now))
           (return-from hibernate-session-worker (values :busy "busy")))
          ((>= (%saved-worker-count) (effective-max-hibernated-workers))
           (setf (worker-refused-reason entry) "at-limit"
                 (worker-refused-at entry) (%unix-now))
           (return-from hibernate-session-worker
             (values :at-limit "at-limit")))
          (t
           (setf (worker-state entry) :hibernating
                 worker entry)
           (%condition-broadcast *pool-transition-condvar*)))))
    (log-event :info "pool.hibernate.start"
               "session" session-id
               "worker_id" (worker-id worker))
    (unwind-protect (%hibernate-marked-worker session-id worker)
      (bt:with-lock-held (*pool-lock*)
        ;; Only an unexpected unwind, such as an interrupt, leaves the mark in
        ;; place. The worker goes back to serving; if its channel did not
        ;; survive, the next call finds that out the ordinary way.
        (when (eq (worker-state worker) :hibernating)
          (setf (worker-state worker) :bound))
        (%condition-broadcast *pool-transition-condvar*)))))

;;; ---------------------------------------------------------------------------
;;; Public API: answering the host service under memory pressure
;;; ---------------------------------------------------------------------------
;;;
;;; One host service watches the memory of the whole machine and every MCP
;;; server's pool of workers. The service decides; each pool listens. A pool
;;; publishes a record of its workers, at most once a second and at least every
;;; few seconds, and reads the requests the service leaves for it: stop a fresh
;;; idle worker, which costs nothing to replace, or hibernate a stateful idle
;;; one. By the time a request is read the worker may be serving a call, may
;;; have picked up state, or may be gone, so every request is checked again
;;; under *pool-lock* and refused when it is no longer safe. Without a service
;;; the pool takes no action of its own.

(defvar *pressure-agent-interval* 1
  "Seconds between two passes of the pressure agent, read when it starts.")

(defparameter *pressure-record-refresh-seconds* 5
  "The longest the pool leaves its worker record unwritten. The record is
written at once when anything in it changes, and at least this often anyway,
so the service can tell a quiet pool from a dead one.")

(defparameter *pressure-request-max-age-seconds* 300
  "The oldest request, in seconds, the pool still acts on. Anything older was
written about a host that may no longer be short of memory, so it is removed
unread.")

(defparameter *pressure-agent-join-seconds* 10
  "How long stopping the pressure agent waits for its thread to finish. A pass
that is hibernating a worker can take far longer; the pass then ends on its
own and acts on nothing more.")

(defvar *before-pressure-stop-hook* nil
  "NIL, or a function of one argument, the worker, that act-on-hibernate-request
calls after it has decided to stop the worker and before %stop-idle-worker
acts. It exists so a test can put a call in that window deterministically;
nothing in the server sets it.")

(defstruct (pressure-agent-state (:copier nil))
  "What one pressure agent remembers between passes: the server stem it
answers for, the record it last wrote (without its time) and when, what it
last saw of the host service (:unknown before the first look, then T or NIL),
and the last request it answered."
  (stem nil)
  (published nil)
  (published-at nil)
  (service :unknown)
  (last-action nil))

(defvar *pressure-agent-current* nil
  "The state of the pressure agent that should be running, or NIL. An agent's
thread keeps going only while this is its own state, so an agent that was
stopped can never act again, even when its thread outlives the stop.")

(defvar *pressure-agent-thread* nil
  "The pressure agent's thread, or NIL.")

(defvar *pressure-agent-lock* (bt:make-lock "pool-pressure-agent-lock")
  "Lock pairing with *pressure-agent-condvar* for the agent's wait and wake.")

(defvar *pressure-agent-condvar*
  (bt:make-condition-variable :name "pool-pressure-agent-condvar")
  "Broadcast to wake the pressure agent early when it is being stopped.")

(defun %worker-age (worker now)
  "Seconds from WORKER's spawn to NOW, in Unix seconds; 0 when it has no
spawn time, so a worker of unknown age is never old enough to stop."
  (let ((spawned (worker-spawned-at worker)))
    (if spawned (max 0 (- now spawned)) 0)))

(defun %holds-state-p (worker)
  "True when stopping WORKER would lose something its session must not lose:
the state its calls left in its image, or a reset notice it still owes. A
worker that replaced a crashed or lost one is fresh, but until its session has
been told its world was reset, that notice lives only on this worker, and
stopping it would leave the session calling functions that are gone with no
word of why. Such a worker is treated as stateful everywhere a stop is
decided, and is published as stateful, so the host service never offers it
as a fresh idle worker."
  (and (or (worker-stateful-p worker)
           (worker-needs-reset-notification worker))
       t))

(defun %live-pid (worker)
  "WORKER's pid, or NIL while it has no process of its own: hibernated, or
resuming and not yet answering. The pid it had then names a process that has
ended, and the kernel may have given that number to another."
  (if (member (worker-state worker) '(:hibernated :resuming))
      nil
      (worker-pid worker)))

(defun %worker-record-entry (worker now)
  "WORKER as one entry of the published record. Its last activity falls back
to its spawn time, and to NOW when it has neither, so the service never reads
a live worker without one. A worker with no process (hibernated, or still
resuming) is published without a pid, since the one it last had may since
belong to another process."
  (list :id (worker-id worker)
        :pid (%live-pid worker)
        :state (worker-state worker)
        :session (worker-session-id worker)
        :stateful (%holds-state-p worker)
        :busy (and (plusp (worker-in-flight worker)) t)
        :spawned-at (worker-spawned-at worker)
        :last-activity (or (worker-last-activity worker)
                           (worker-spawned-at worker)
                           now)
        :refused-reason (worker-refused-reason worker)
        :refused-at (worker-refused-at worker)
        :core-bytes (worker-core-bytes worker)))

(defun build-worker-record (now &key (workers nil workers-p) service-seen
                                     last-action)
  "The worker record this server publishes for the host service, as of NOW in
Unix seconds.

The record names this server by pid and start time and lists every worker in
WORKERS, which defaults to the pool's workers read under *pool-lock*, with its
id, pid, state, session, whether it holds state or is serving a call, when it
was spawned and last active, its last refusal and the size of its saved core.
SERVICE-SEEN says whether the pool last found the host service alive, and
LAST-ACTION is the last request answered, as (:worker-id :action :result :at),
or NIL. :HIBERNATE-FULL is true while the server keeps as many workers
hibernated, saving or resuming as *max-hibernated-workers* allows, so the service asks
it for no more saves until one resumes or goes. Nothing is written; the caller
publishes the plist."
  (multiple-value-bind (entries saved)
      (flet ((read-workers (list)
               (values (mapcar (lambda (w) (%worker-record-entry w now)) list)
                       (count-if #'%holds-saved-world-p list))))
        (if workers-p
            (read-workers workers)
            (bt:with-lock-held (*pool-lock*)
              (read-workers *all-workers*))))
    (multiple-value-bind (pid start) (parse-server-stem (server-stem))
      (list :server-pid pid
            :server-start start
            :written-at now
            :service-seen (and service-seen t)
            :workers entries
            :last-action last-action
            :hibernate-full (>= saved (effective-max-hibernated-workers))))))

(defun %stop-idle-worker (session-id worker &key (now (%unix-now)))
  "Stop WORKER, SESSION-ID's worker, only if it is still idle, holds no state
and is old enough, and return :killed, or say why not: :gone when it is no
longer the session's :bound worker, :busy when a call holds it, :stateful when
it holds state or still owes its session a reset notice (%holds-state-p),
:too-young when it was spawned too recently.
Every check and the change of state happen in one hold of *pool-lock*, the
same lock a call takes its worker under, so a call and a stop can never both
win: a call that took the worker first makes this answer :busy, and a call
arriving after the stop finds the session without a worker and gets a fresh
one. The worker is marked :released and dropped from the session and the pool
inside that hold; its process is ended after the lock is let go. Nothing was
lost, so the session's next call is answered without a reset notice, and a
stop is not a crash: it adds nothing to the crash record and leaves the
breaker alone."
  (let ((outcome
          (bt:with-lock-held (*pool-lock*)
            (cond
              ((not (eq (gethash session-id *affinity-map*) worker)) :gone)
              ((not (eq (worker-state worker) :bound)) :gone)
              ((plusp (worker-in-flight worker)) :busy)
              ((%holds-state-p worker) :stateful)
              ((< (%worker-age worker now)
                  (effective-pressure-kill-min-age-seconds))
               :too-young)
              (t
               (setf (worker-state worker) :released)
               (remhash session-id *affinity-map*)
               (setf *all-workers* (remove worker *all-workers*))
               (%condition-broadcast *pool-transition-condvar*)
               :killed)))))
    (when (eq outcome :killed)
      (ignore-errors (signal-worker-terminate worker))
      (ignore-errors (kill-worker worker))
      (%schedule-replenish))
    outcome))

(defun act-on-hibernate-request (plist &key (now (%unix-now)))
  "Answer one request from the host service, PLIST as read-hibernate-request
returns it, and return what came of it as a keyword.

A :kill request stops a worker only when it is :bound, idle, holds no state
and is at least the minimum kill age old, and only when it booted from a
worker core rather than from source: a worker in that state has lost
nothing and the next call boots a new one in a tenth of a second, so it is
stopped without a reset notice. A worker that still owes its session a reset
notice counts as holding state (%holds-state-p): it is never stopped, and it
may be hibernated, which keeps the notice with the worker. A :hibernate
request saves a worker only when it is :bound, idle and holds state. The
answer is:
  :killed          the worker was stopped.
  :too-young       a :kill for a worker spawned too recently to stop.
  :no-core         a :kill for a worker that loaded from source because no
                   worker core was in use. A stop is cheap only because the
                   next worker boots from the core in a tenth of a second;
                   without one it loads from source,
                   which takes tens of seconds and more memory at its peak
                   than the worker it replaces, so the worker is left
                   serving and the refusal is kept on it.
  :busy            a call took the worker just before it was stopped.
  :changed         the worker has since become busy, gained state (for a
                   :kill), lost it (for a :hibernate), or left its session.
  :unknown-worker  no worker of this pool has that id, or the request names
                   another server.
  :stale           the request is older than *pressure-request-max-age-seconds*
                   or carries no time.
  :hibernated, :refused, :at-limit, :disk, :timeout, :died
                   as hibernate-session-worker answers a :hibernate.
A stale or unknown request is logged as a warning and nothing is done. A
request only ever names a worker by its id; where a world is saved is decided
here, never by the request."
  (let ((id (getf plist :worker-id))
        (action (getf plist :action))
        (requested-at (getf plist :requested-at)))
    (multiple-value-bind (pid start) (parse-server-stem (server-stem))
      (unless (and pid
                   (eql pid (getf plist :server-pid))
                   (eql start (getf plist :server-start)))
        (log-event :warn "pool.pressure.request-refused"
                   "worker_id" id "action" action "reason" "another-server")
        (return-from act-on-hibernate-request :unknown-worker)))
    (unless (and (integerp requested-at)
                 (<= (- now requested-at) *pressure-request-max-age-seconds*))
      (log-event :warn "pool.pressure.request-refused"
                 "worker_id" id "action" action "reason" "stale"
                 "requested_at" requested-at)
      (return-from act-on-hibernate-request :stale))
    (let ((worker nil)
          (session nil)
          (verdict nil))
      (bt:with-lock-held (*pool-lock*)
        (setf worker (find id *all-workers* :key #'worker-id))
        (when worker
          (setf session (worker-session-id worker)
                verdict
                (cond
                  ((not (and session
                             (eq (gethash session *affinity-map*) worker)
                             (eq (worker-state worker) :bound)
                             (zerop (worker-in-flight worker))))
                   :changed)
                  ((eq action :kill)
                   (cond ((%holds-state-p worker) :changed)
                         ((eq (worker-boot-kind worker) :source)
                          ;; A worker that had to load from source says no
                          ;; core is in use, so its replacement would load
                          ;; from source too. The refusal is kept on the
                          ;; worker, so the service passes it over instead
                          ;; of asking again at once.
                          (setf (worker-refused-reason worker) "no-core"
                                (worker-refused-at worker) now)
                          :no-core)
                         ((< (%worker-age worker now)
                             (effective-pressure-kill-min-age-seconds))
                          :too-young)
                         (t :stop)))
                  ((eq action :hibernate)
                   (if (%holds-state-p worker) :hibernate :changed))
                  (t :changed)))))
      (unless worker
        (log-event :warn "pool.pressure.request-refused"
                   "worker_id" id "action" action "reason" "unknown-worker")
        (return-from act-on-hibernate-request :unknown-worker))
      (case verdict
        (:stop
         (when *before-pressure-stop-hook*
           (funcall *before-pressure-stop-hook* worker))
         (let ((outcome (%stop-idle-worker session worker :now now)))
           (case outcome
             (:killed
              (log-event :info "pool.worker.pressure-stopped"
                         "session" session
                         "worker_id" id)
              :killed)
             ((:busy :too-young) outcome)
             (t :changed))))
        (:hibernate
         (let ((outcome (hibernate-session-worker session :worker worker)))
           (if (eq outcome :not-eligible) :changed outcome)))
        (t verdict)))))

(defun %pressure-agent-live-p (state)
  "True while STATE belongs to the pressure agent that should be running."
  (eq *pressure-agent-current* state))

(defun %note-service (state)
  "Look at whether the host service is alive and remember it in STATE. Says
once that pressure relief is inactive when the service is missing, and once
that it is back when it returns, never on every pass."
  (let ((alive (and (ignore-errors (service-alive-p)) t))
        (seen (pressure-agent-state-service state)))
    (cond
      ((and alive (not (eq seen t)))
       (when (null seen)
         (log-event :info "pool.pressure.service-back"
                    "msg" "the host service is alive; pressure relief is active"))
       (setf (pressure-agent-state-service state) t))
      ((and (not alive) (not (null seen)))
       (log-event :warn "pool.pressure.no-service"
                  "msg" "no host service is alive; pressure relief is inactive")
       (setf (pressure-agent-state-service state) nil)))
    alive))

(defun %publish-worker-record (state alive)
  "Write this server's worker record when anything in it but its time has
changed since the last write, or when *pressure-record-refresh-seconds* have
passed. ALIVE is what the pool just saw of the host service."
  (let* ((now (%unix-now))
         (record (build-worker-record
                  now :service-seen alive
                      :last-action (pressure-agent-state-last-action state)))
         (content (loop for (key value) on record by #'cddr
                        unless (eq key :written-at)
                          append (list key value)))
         (published-at (pressure-agent-state-published-at state)))
    (when (and (%pressure-agent-live-p state)
               (or (null published-at)
                   (not (equal content (pressure-agent-state-published state)))
                   (>= (- now published-at) *pressure-record-refresh-seconds*)))
      (write-worker-record (pressure-agent-state-stem state) record)
      (setf (pressure-agent-state-published state) content
            (pressure-agent-state-published-at state) now))))

(defun %answer-pending-requests (state)
  "Answer every request waiting for this server, oldest name first, removing
each once answered and remembering the last answer in STATE. The worker record
is republished after each answer and before its request is removed, so the
service never reads a record older than the answer. A request that
fails validation was already removed by pending-requests and is only logged.
One request that cannot be answered is logged and removed, and the rest are
still answered."
  (let ((stem (pressure-agent-state-stem state)))
    (multiple-value-bind (pending rejected) (pending-requests stem)
      (dolist (entry rejected)
        (log-event :warn "pool.pressure.request-rejected"
                   "file" (file-namestring (car entry))
                   "reason" (cdr entry)))
      (dolist (entry pending)
        (unless (%pressure-agent-live-p state)
          (return))
        (let* ((path (car entry))
               (plist (cdr entry))
               (id (getf plist :worker-id))
               (action (getf plist :action)))
          (handler-case
              (let ((result (act-on-hibernate-request plist)))
                (log-event :info "pool.pressure.answered"
                           "worker_id" id
                           "action" action
                           "result" result)
                (setf (pressure-agent-state-last-action state)
                      (list :worker-id id :action action :result result
                            :at (%unix-now))))
            (error (e)
              (log-event :error "pool.pressure.request-error"
                         "worker_id" id
                         "action" action
                         "error" (princ-to-string e))))
          ;; The record goes out before the request is removed: the service
          ;; asks again only once no request stands, and it must then read
          ;; what this answer did, not the record from before it.
          (handler-case
              (%publish-worker-record
               state (eq (pressure-agent-state-service state) t))
            (error (e)
              (log-event :error "pool.pressure.record-failed"
                         "error" (princ-to-string e))))
          (ignore-errors (remove-request path)))))))

(defun %pressure-agent-pass (state)
  "One pass of the pressure agent: look at the host service, publish the
worker record when it is due, then answer the requests waiting. Each step is
guarded on its own, so a failure in one is logged and the others still run."
  (let ((alive nil))
    (handler-case (setf alive (%note-service state))
      (error (e)
        (log-event :error "pool.pressure.service-check-failed"
                   "error" (princ-to-string e))))
    (handler-case (%publish-worker-record state alive)
      (error (e)
        (log-event :error "pool.pressure.record-failed"
                   "error" (princ-to-string e))))
    (handler-case (%answer-pending-requests state)
      (error (e)
        (log-event :error "pool.pressure.requests-failed"
                   "error" (princ-to-string e))))))

(defun %pressure-agent-loop (state interval)
  "Run passes of the pressure agent STATE every INTERVAL seconds, the first at
once, until the agent is stopped. A stop wakes the wait at once."
  (loop while (%pressure-agent-live-p state)
        do (%pressure-agent-pass state)
           (bt:with-lock-held (*pressure-agent-lock*)
             (when (%pressure-agent-live-p state)
               (bt:condition-wait *pressure-agent-condvar*
                                  *pressure-agent-lock*
                                  :timeout interval)))))

(defun start-pressure-agent ()
  "Start the thread through which this pool answers the host service, and
return it. Every *pressure-agent-interval* seconds it publishes this server's
worker record when that is due and answers the requests left for this server.
Returns NIL, logging why, when this process cannot name itself to the service.
A running agent is left as it is."
  (when (and *pressure-agent-current*
             *pressure-agent-thread*
             (bt:thread-alive-p *pressure-agent-thread*))
    (return-from start-pressure-agent *pressure-agent-thread*))
  (let ((stem (server-stem)))
    (unless stem
      (log-event :warn "pool.pressure.no-identity"
                 "msg" "this process cannot read its start time; pressure relief is inactive")
      (return-from start-pressure-agent nil))
    (let ((state (make-pressure-agent-state :stem stem))
          (interval *pressure-agent-interval*))
      (bt:with-lock-held (*pressure-agent-lock*)
        (setf *pressure-agent-current* state))
      (setf *pressure-agent-thread*
            (bt:make-thread (lambda () (%pressure-agent-loop state interval))
                            :name "pool-pressure-agent")))))

(defun %remove-own-pressure-files ()
  "Remove this server's worker record and every request waiting for it."
  (handler-case
      (let ((stem (server-stem)))
        (when stem
          (remove-worker-record stem)
          (dolist (entry (pending-requests stem))
            (remove-request (car entry)))))
    (error (e)
      (log-event :warn "pool.pressure.cleanup-failed"
                 "error" (princ-to-string e)))))

(defun stop-pressure-agent ()
  "Stop the pressure agent, waiting up to *pressure-agent-join-seconds* for its
thread, then remove this server's worker record and the requests waiting for
it. An agent stopped in the middle of a pass finishes the request it is on and
acts on nothing after it."
  (bt:with-lock-held (*pressure-agent-lock*)
    (setf *pressure-agent-current* nil)
    (%condition-broadcast *pressure-agent-condvar*))
  (let ((thread *pressure-agent-thread*))
    (when (and thread (bt:threadp thread))
      (let ((deadline (+ (get-internal-real-time)
                         (* *pressure-agent-join-seconds*
                            internal-time-units-per-second))))
        (loop while (and (bt:thread-alive-p thread)
                         (< (get-internal-real-time) deadline))
              do (sleep 0.05))
        (if (bt:thread-alive-p thread)
            (log-event :warn "pool.pressure.stop-slow"
                       "msg" "the pressure agent is still finishing a request")
            (handler-case (bt:join-thread thread)
              (error () nil)))))
    (setf *pressure-agent-thread* nil))
  (%remove-own-pressure-files))

;;; ---------------------------------------------------------------------------
;;; Public API — pool-worker-info / pool-status-info
;;; ---------------------------------------------------------------------------

(defun pool-worker-info ()
  "Return a vector of worker info hash-tables for inclusion in pool-status output.
Includes id, session (truncated), tcp_port, pid (JSON null while the worker
is hibernated or resuming and has no process), state, and the liveness the
health monitor last established: the classification, how it was established, the
last ping round trip in milliseconds, how many pings in a row have gone
unanswered, and the universal time the classification was taken. Omits
swank_port to prevent unrestricted REPL access bypassing MCP security policies.

It also gives what memory pressure relief needs to be seen: whether the worker
holds state and whether a call is holding it, its last activity in Unix
seconds, how it booted (core, source or resumed), the size in bytes of its last
saved core and, while it is hibernated, the age of that core in seconds, how
long its last save and its last resume took in milliseconds, and why its last
hibernation was refused. Each of these that has no value is JSON null.

The liveness values are raw here on purpose. A reader needs to state what a
classification does and does not establish before putting it in front of anyone,
and that rendering belongs to the verb doing the reporting, not to the pool."
  (let ((result (make-array 0 :adjustable t :fill-pointer 0))
        (now (%unix-now)))
    (flet ((or-null (value) (if (null value) 'cl:null value)))
      (bt:with-lock-held (*pool-lock*)
        (dolist (w *all-workers*)
          (let ((ht (make-hash-table :test 'equal)))
            (setf (gethash "id" ht) (worker-id w)
                  (gethash "session" ht) (let ((sid (worker-session-id w)))
                                            (if (and (stringp sid) (> (length sid) 8))
                                                (concatenate 'string (subseq sid 0 8) "...")
                                                sid))
                  (gethash "tcp_port" ht) (worker-tcp-port w)
                  (gethash "pid" ht) (or-null (%live-pid w))
                  (gethash "state" ht) (string-downcase
                                         (symbol-name (worker-state w)))
                  (gethash "liveness" ht) (string-downcase
                                            (symbol-name (worker-liveness w)))
                  (gethash "liveness_basis" ht)
                    (let ((basis (worker-liveness-basis w)))
                      (and basis (string-downcase (symbol-name basis))))
                  (gethash "last_ping_ms" ht) (worker-last-ping-milliseconds w)
                  (gethash "consecutive_missed_pings" ht)
                    (worker-consecutive-missed-pings w)
                  (gethash "liveness_checked_at" ht)
                    (worker-liveness-checked-at w)
                  (gethash "stateful" ht) (and (worker-stateful-p w) t)
                  (gethash "busy" ht) (and (plusp (worker-in-flight w)) t)
                  (gethash "last_activity" ht)
                    (or-null (or (worker-last-activity w) (worker-spawned-at w)))
                  (gethash "boot" ht)
                    (let ((kind (worker-boot-kind w)))
                      (if kind (string-downcase (symbol-name kind)) 'cl:null))
                  (gethash "core_bytes" ht) (or-null (worker-core-bytes w))
                  (gethash "core_age_seconds" ht)
                    (let ((at (worker-hibernated-at w)))
                      (if (and at (eq (worker-state w) :hibernated))
                          (max 0 (- now at))
                          'cl:null))
                  (gethash "last_hibernate_ms" ht)
                    (or-null (worker-last-hibernate-milliseconds w))
                  (gethash "last_resume_ms" ht)
                    (or-null (worker-last-resume-milliseconds w))
                  (gethash "refused_reason" ht) (or-null (worker-refused-reason w)))
            (vector-push-extend ht result)))))
    result))

(defun %worker-core-status ()
  "The worker core new workers boot from, or JSON null, and a word for it:
\"in use\", \"unset\", \"missing\", or \"disabled: \" and why, as two values."
  (multiple-value-bind (path reason) (worker-core-path)
    (cond
      (path (values path "in use"))
      (*worker-core-disabled*
       (values 'cl:null (format nil "disabled: ~A" *worker-core-disabled*)))
      ((and reason (uiop:string-prefix-p "missing" reason))
       (values 'cl:null "missing"))
      (t (values 'cl:null "unset")))))

(defun pool-status-info ()
  "Return a hash-table with pool diagnostic information for the pool-status MCP tool.
Keys: pool_running, total_workers, standby_count, bound_count (workers bound
to a session with a process; hibernated ones are counted apart),
max_pool_size, warmup_target, workers (vector of per-worker hashes),
hibernated_count (workers saved to disk, holding no memory),
max_hibernated_workers (the most this server keeps hibernated), resident_count
(workers with a running process), pressure_relief (\"active\" when the pool is
answering a live host service, else \"inactive\"), worker_core (the core new
workers boot from, or JSON null) and worker_core_status (\"in use\", \"unset\",
\"missing\", or \"disabled: \" and why)."
  (let* ((running *pool-running*)
         (workers (if running (pool-worker-info) (vector)))
         (standby-count 0)
         (bound-count 0)
         (hibernated-count 0)
         (resident-count 0))
    (when running
      (bt:with-lock-held (*pool-lock*)
        (setf standby-count (length *standby-workers*)
              hibernated-count (count :hibernated *all-workers* :key #'worker-state)
              bound-count (- (length *all-workers*) (length *standby-workers*)
                             hibernated-count)
              resident-count (- (length *all-workers*) hibernated-count))))
    (multiple-value-bind (core core-status) (%worker-core-status)
      (let ((info (make-hash-table :test 'equal))
            (relief (and running
                         *pressure-agent-current*
                         *pressure-agent-thread*
                         (bt:thread-alive-p *pressure-agent-thread*)
                         (ignore-errors (service-alive-p)))))
        (setf (gethash "pool_running" info) (if running t nil)
              (gethash "total_workers" info) (length workers)
              (gethash "standby_count" info) standby-count
              (gethash "bound_count" info) bound-count
              (gethash "max_pool_size" info) (effective-max-pool-size)
              (gethash "warmup_target" info) (effective-worker-pool-warmup)
              (gethash "workers" info) workers
              (gethash "hibernated_count" info) hibernated-count
              (gethash "max_hibernated_workers" info)
                (effective-max-hibernated-workers)
              (gethash "resident_count" info) resident-count
              (gethash "pressure_relief" info) (if relief "active" "inactive")
              (gethash "worker_core" info) core
              (gethash "worker_core_status" info) core-status)
        info))))

;;; ---------------------------------------------------------------------------
;;; Public API — pool-rpc-with-hard-kill
;;; ---------------------------------------------------------------------------

(defun pool-rpc-with-hard-kill (worker method params
                                 &key (soft-timeout nil)
                                      (grace nil))
  "Send METHOD with PARAMS to WORKER, returning the result hash-table.

Implements a two-level timeout:
  - SOFT-TIMEOUT: passed to worker-rpc so the in-worker sb-ext:with-timeout
    fires if the eval exceeds it. The worker returns a TIMEOUT error payload.
    Defaults to the resolved eval timeout (DSMR_WORKER_EVAL_TIMEOUT, 120 s
    unless set): the eval budget, not the startup budget.
  - Hard-kill backstop: if the worker does not return within SOFT-TIMEOUT +
    GRACE seconds, the parent kills the worker via its sb-ext:process object
    (avoiding the PID-reuse hazard of killing by raw numeric pid after the
    process may have already exited), then marks it crashed via the normal
    mark-worker-crashed path (which closes the stream and arms the reset
    notification), then signals WORKER-CRASHED so the dispatcher's existing
    handler returns a structured isError. GRACE defaults to the resolved
    kill grace (DSMR_WORKER_KILL_GRACE_SECONDS, 5 s unless set).

WORKER-CRASHED from worker-rpc is re-signalled unchanged so the dispatcher's
existing handler fires for both the soft and hard timeout cases.

Before sending, the worker's last activity is stamped, and any METHOD outside
+stateless-worker-methods+ marks the worker stateful, so the pool knows it may
hold a session's work. Both happen under *pool-lock*, which is released before
the call goes out."
  (bt:with-lock-held (*pool-lock*)
    (setf (worker-last-activity worker) (%unix-now))
    (unless (member method +stateless-worker-methods+ :test #'string=)
      (setf (worker-stateful-p worker) t)))
  (let* ((soft-timeout (or soft-timeout (effective-eval-timeout)))
         (grace (or grace (effective-worker-kill-grace-seconds)))
         (hard-timeout (+ soft-timeout grace)))
    (handler-case
        (worker-rpc worker method params :timeout hard-timeout)
      (sb-ext:timeout ()
        ;; Hard timeout expired: the in-worker soft timeout should have fired
        ;; and returned a TIMEOUT payload, but the response did not arrive
        ;; within the grace margin. Kill via the process object to avoid
        ;; sending SIGKILL to a recycled PID.
        (log-event :warn "pool.hard-kill.backstop"
                   "id" (worker-id worker)
                   "soft_timeout" soft-timeout
                   "grace" grace)
        (let ((proc (worker-process-info worker)))
          (when (and proc (ignore-errors (sb-ext:process-alive-p proc)))
            (ignore-errors (sb-ext:process-kill proc 9))))
        ;; Route through the standard crash-recovery path: marks state
        ;; :crashed, closes stream, arms reset-notification, spawns reaper.
        ;; This must happen outside of any stream-lock context (the outer
        ;; with-timeout interrupted worker-rpc before it released the lock,
        ;; so stream-lock is NOT held here).
        (ignore-errors
          (mark-worker-crashed worker "hard-kill-timeout"))
        ;; Surface as a structured crash so the dispatcher returns isError.
        (error 'dsmr-mcp/src/hermetic/worker-client:worker-crashed
               :worker worker :reason "hard-kill-timeout"))
      (dsmr-mcp/src/hermetic/worker-client:worker-crashed (e)
        (error e)))))
