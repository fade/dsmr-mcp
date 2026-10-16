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
                #:hibernate-worker-process #:release-worker-process)
  (:import-from #:dsmr-mcp/src/hermetic/pool-records
                #:server-stem #:ensure-owner-directory
                #:unsafe-hibernate-path #:hibernated-core-path
                #:disk-allows-hibernation-p #:expected-core-bytes
                #:free-disk-bytes)
  (:import-from #:dsmr-mcp/src/bus/hostfiles
                #:fleet-line #:append-fleet-line)
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
           #:*resolved-pool-settings* #:resolve-pool-settings
           #:effective-worker-pool-warmup #:effective-max-pool-size
           #:effective-worker-kill-grace-seconds
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
  (kill-grace-seconds 5))

(defvar *resolved-pool-settings* nil
  "The pool-settings record from the last resolve-pool-settings call, or NIL
when nothing has resolved yet. The effective-* readers resolve on first use
when it is NIL.")

(defun resolve-pool-settings ()
  "Read the pool tuning settings now and store them in *resolved-pool-settings*.
Returns the fresh pool-settings record.

Each field takes the matching special when it is non-NIL, else the
environment, else its default: *worker-pool-warmup* or DSMR_WORKER_POOL_WARMUP
(default 0), *max-pool-size* or DSMR_MAX_POOL_SIZE (default 16), and
*worker-kill-grace-seconds* or DSMR_WORKER_KILL_GRACE_SECONDS (default 5). An
unparseable or out-of-range environment value warns and falls back to the
default.

It also resolves the worker handshake timeout and the eval timeout, so one
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
                                             5 :min 1)))))
    (setf *resolved-pool-settings* settings)
    (resolve-worker-startup-timeout)
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
               warmup max-size)))
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
    (%start-health-monitor)
    (pushnew 'shutdown-pool sb-ext:*exit-hooks*)
    (%schedule-replenish)
    (log-event :info "pool.initialized"
               "warmup_target" (effective-worker-pool-warmup)
               "max_pool_size" (effective-max-pool-size))))

;;; ---------------------------------------------------------------------------
;;; Public API — shutdown
;;; ---------------------------------------------------------------------------

(defun shutdown-pool ()
  "Shut down all workers and clean up pool state. Stops the health monitor,
waits for in-flight replenish/recovery/reaper threads, then kills all workers."
  (log-event :info "pool.shutting-down")
  (setf *pool-running* nil)
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
      (clrhash *circuit-breaker-map*))
    (dolist (w workers) (ignore-errors (kill-worker w))))
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

(defun get-or-assign-worker (session-id)
  "Return the worker bound to SESSION-ID, assigning one if needed.
If a standby worker is available, it is assigned immediately; otherwise
a new worker is spawned. Multiple concurrent threads requesting the same
new session coordinate via a placeholder so only one spawn occurs.

Circuit breaker: before spawning, checks *circuit-breaker-map* for a recent
trip within *circuit-breaker-cooldown* seconds and fails fast with an error.

Signals pool-shutting-down if the pool is not running.
Signals pool-capacity-exceeded if max workers would be exceeded.
Signals circuit-breaker-active both when the breaker trips and on any later
call inside the cooldown window; the condition carries the seconds remaining."
  (let ((entry nil) (need-spawn nil) (assigned-from-standby nil)
        (need-reset nil) (reset-reason nil) (old-worker-to-kill nil)
        (circuit-breaker-tripped nil))
    (bt:with-lock-held (*pool-lock*)
      (unless *pool-running*
        (error 'pool-shutting-down))
      ;; Check circuit-breaker cooldown BEFORE anything else.
      ;; Blocks calls during the fail-fast window after the breaker trips.
      (let ((trip-time (gethash session-id *circuit-breaker-map*)))
        (when (and trip-time
                   (< (get-universal-time) (+ trip-time *circuit-breaker-cooldown*)))
          (let ((remaining (- (+ trip-time *circuit-breaker-cooldown*)
                              (get-universal-time))))
            (error 'circuit-breaker-active
                   :session-id session-id
                   :remaining-seconds (ceiling remaining)))))
      (setf entry (gethash session-id *affinity-map*))
      (cond
        ;; Path 1: existing bound worker — return immediately
        ((and entry (typep entry 'worker) (eq :bound (worker-state entry)))
         (return-from get-or-assign-worker entry))
        ;; Path 1b: existing dead/crashed worker — remove and reassign
        ((and entry (typep entry 'worker))
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
         ;; saving its world) is no crash: no history was pushed above, and
         ;; the session is told why in the notice.
         (when (and (eq :dead (worker-state old-worker-to-kill))
                    (worker-reset-reason old-worker-to-kill))
           (setf need-reset t
                 reset-reason (worker-reset-reason old-worker-to-kill))))
        ;; Path 2: placeholder — another thread is spawning
        ((and entry (typep entry 'worker-placeholder))
         nil))
      ;; Assign standby or insert placeholder for spawn
      (when (and (null entry) (not circuit-breaker-tripped))
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
    (cond
      (assigned-from-standby
       (%schedule-replenish)
       assigned-from-standby)
      (need-spawn
       (%spawn-and-bind session-id entry :need-reset need-reset
                                         :reset-reason reset-reason))
      (t
       (%wait-for-placeholder entry)))))

;;; ---------------------------------------------------------------------------
;;; Public API — release-session
;;; ---------------------------------------------------------------------------

(defun release-session (session-id)
  "Release the worker bound to SESSION-ID. Kills the worker and removes it
from the pool. Also clears circuit-breaker state so a manual reset works.

If a spawn is in progress (placeholder), marks it as cancelled so the
spawn thread will clean up the worker after it completes."
  (let ((worker-to-kill nil))
    (bt:with-lock-held (*pool-lock*)
      (let ((entry (gethash session-id *affinity-map*)))
        (cond
          ((and entry (typep entry 'worker))
           (setf worker-to-kill entry)
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
      (%schedule-replenish))))

;;; ---------------------------------------------------------------------------
;;; Public API — kill-session-worker
;;; ---------------------------------------------------------------------------

(defun kill-session-worker (session-id &key reset)
  "Kill the worker bound to SESSION-ID without ending the session.
Unlike release-session, the session remains active — the next tool call
will spawn a fresh worker via get-or-assign-worker.

Clears crash history so the intentional kill does not count toward the
circuit breaker. When RESET is true, also clears *circuit-breaker-map*
for this session (manual breaker reset).

Returns :killed if a worker was found and killed, :no-worker if none
was bound, :placeholder if a spawn was in progress (cancelled)."
  (let ((worker-to-kill nil)
        (kill-result :no-worker))
    (bt:with-lock-held (*pool-lock*)
      (let ((entry (gethash session-id *affinity-map*)))
        (cond
          ((and entry (typep entry 'worker))
           (setf worker-to-kill entry
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
       (ignore-errors (delete-file path))
       (log-event :info "pool.hibernate.discarded"
                  "session" session-id
                  "worker_id" (worker-id worker)
                  "state" (string-downcase (symbol-name (worker-state worker))))
       (values :not-eligible (string-downcase
                              (symbol-name (worker-state worker))))))))

(defun %lose-worker-during-hibernation (session-id worker)
  "Take WORKER, which died while saving and left no core, out of service.

Its process and channel are let go outside *pool-lock*. Under the lock it
becomes :dead with the reason the session will be told, and it stays the
session's entry, so the session's next call gets a fresh worker carrying that
reset notice. This is not a crash: nothing is added to the crash history and
the breaker is not touched. When the session let the worker go meanwhile there
is no one to tell, and nothing more is done."
  (release-worker-process worker)
  (let ((lost nil))
    (bt:with-lock-held (*pool-lock*)
      (when (eq (worker-state worker) :hibernating)
        (setf (worker-state worker) :dead
              (worker-reset-reason worker) *died-while-hibernating-reason*
              *all-workers* (remove worker *all-workers*)
              lost t)))
    (when lost
      (log-event :error "pool.worker.died-during-hibernate"
                 "session" session-id
                 "worker_id" (worker-id worker))
      (ignore-errors
       (append-fleet-line
        (fleet-line :error "worker-hibernate-died"
                    :id session-id
                    :msg (format nil "worker ~D of session ~A: ~A"
                                 (worker-id worker) session-id
                                 *died-while-hibernating-reason*)))))
    (values :died (if lost "died" "released"))))

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
             ;; should always have answered first; this is the backstop.
             (log-event :error "pool.hibernate.timeout"
                        "session" session-id
                        "worker_id" id
                        "ms" milliseconds)
             (%return-to-service worker "timeout")
             (values :timeout "timeout"))
            (t
             ;; The channel ended without a reply. A core on disk means the
             ;; save finished and only the answer was lost.
             (if (%core-file-bytes path)
                 (%finish-hibernation session-id worker path nil milliseconds)
                 (%lose-worker-during-hibernation session-id worker)))))))))

(defun hibernate-session-worker (session-id)
  "Have SESSION-ID's worker save its whole world to disk and end its process,
so it holds no memory until the session needs it again.

Returns (values OUTCOME REASON), OUTCOME being one of:
  :hibernated    the world is saved and the process is gone; the worker is
                 :hibernated and no longer counts against the pool size.
  :busy          a call is holding the worker; it is left serving.
  :not-eligible  the session has no worker, or it is not :bound (REASON
                 names the state), or the pool is not running.
  :refused       the worker declined (REASON is its word: has-threads when
                 the session started threads of its own, a save that failed,
                 or bad-path); it is left serving.
  :disk          less than twice the expected core size is free; it is left
                 serving.
  :timeout       no answer in time; it is left serving.
  :died          it died during the save and left no core; its session gets a
                 fresh worker and a reset notice saying so on its next call.

A worker is refused rather than saved whenever saving it could lose work it is
doing or make a short host worse: a call in flight, a thread of the session's
own, or a disk without room for the core. The reason and time of a refusal are
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
          ((not (eq (worker-state entry) :bound))
           (return-from hibernate-session-worker
             (values :not-eligible
                     (string-downcase (symbol-name (worker-state entry))))))
          ((plusp (worker-in-flight entry))
           (setf (worker-refused-reason entry) "busy"
                 (worker-refused-at entry) (%unix-now))
           (return-from hibernate-session-worker (values :busy "busy")))
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
;;; Public API — pool-worker-info / pool-status-info
;;; ---------------------------------------------------------------------------

(defun pool-worker-info ()
  "Return a vector of worker info hash-tables for inclusion in pool-status output.
Includes id, session (truncated), tcp_port, pid, state, and the liveness the
health monitor last established: the classification, how it was established, the
last ping round trip in milliseconds, how many pings in a row have gone
unanswered, and the universal time the classification was taken. Omits
swank_port to prevent unrestricted REPL access bypassing MCP security policies.

The liveness values are raw here on purpose. A reader needs to state what a
classification does and does not establish before putting it in front of anyone,
and that rendering belongs to the verb doing the reporting, not to the pool."
  (let ((result (make-array 0 :adjustable t :fill-pointer 0)))
    (bt:with-lock-held (*pool-lock*)
      (dolist (w *all-workers*)
        (let ((ht (make-hash-table :test 'equal)))
          (setf (gethash "id" ht) (worker-id w)
                (gethash "session" ht) (let ((sid (worker-session-id w)))
                                          (if (and (stringp sid) (> (length sid) 8))
                                              (concatenate 'string (subseq sid 0 8) "...")
                                              sid))
                (gethash "tcp_port" ht) (worker-tcp-port w)
                (gethash "pid" ht) (worker-pid w)
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
                  (worker-liveness-checked-at w))
          (vector-push-extend ht result))))
    result))

(defun pool-status-info ()
  "Return a hash-table with pool diagnostic information for the pool-status MCP tool.
Keys: pool_running, total_workers, standby_count, bound_count,
max_pool_size, warmup_target, workers (vector of per-worker hashes)."
  (let* ((running *pool-running*)
         (workers (if running (pool-worker-info) (vector)))
         (standby-count 0)
         (bound-count 0))
    (when running
      (bt:with-lock-held (*pool-lock*)
        (setf standby-count (length *standby-workers*)
              bound-count (- (length *all-workers*) (length *standby-workers*)))))
    (let ((info (make-hash-table :test 'equal)))
      (setf (gethash "pool_running" info) (if running t nil)
            (gethash "total_workers" info) (length workers)
            (gethash "standby_count" info) standby-count
            (gethash "bound_count" info) bound-count
            (gethash "max_pool_size" info) (effective-max-pool-size)
            (gethash "warmup_target" info) (effective-worker-pool-warmup)
            (gethash "workers" info) workers)
      info)))

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
