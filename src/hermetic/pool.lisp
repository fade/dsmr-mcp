;;;; src/hermetic/pool.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Worker pool manager with strict session affinity for dsmr-mcp.
;;;;
;;;; Design principles:
;;;; 1. Strict exclusive affinity: 1 session = 1 dedicated worker. No sharing.
;;;; 2. Scale-out: When standbys exhausted, spawn new workers on demand up to max.
;;;; 3. Warm standbys: Pool pre-spawns workers ready for immediate assignment.
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
                #:*reaper-threads* #:*reaper-threads-lock*
                #:*worker-startup-timeout*)
  (:import-from #:dsmr-mcp/src/hermetic/worker/handlers
                #:*default-eval-timeout*)
  (:import-from #:dsmr-mcp/src/log #:log-event)
  (:import-from #:sb-ext)
  (:import-from #:sb-posix)
  (:export #:*worker-pool-warmup* #:*max-pool-size*
           #:*health-check-interval-seconds*
           #:*crash-breaker-window* #:*crash-breaker-threshold*
           #:*circuit-breaker-cooldown* #:*circuit-breaker-map*
           #:initialize-pool #:shutdown-pool
           #:get-or-assign-worker #:release-session
           #:kill-session-worker #:pool-status-info
           #:pool-worker-info #:find-session-worker
           #:pool-shutting-down #:pool-capacity-exceeded
           #:pool-spawn-cancelled #:*recovery-threads*
           #:pool-rpc-with-hard-kill))

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

Used to seed pool-tuning defvars from the environment so operators can
tune dsmr-mcp without editing source. Each fresh SBCL process reads the
environment once at load time."
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

(defvar *worker-pool-warmup*
  (%env-int "DSMR_WORKER_POOL_WARMUP" 1 :min 0)
  "Number of standby workers to pre-spawn and maintain.
Default 1; override with DSMR_WORKER_POOL_WARMUP env var (non-negative integer).
Set to 0 to disable pre-spawning; workers spawn on demand as sessions arrive.")

(defvar *max-pool-size*
  (%env-int "DSMR_MAX_POOL_SIZE" 16 :min 1)
  "Maximum total number of workers (bound + standby). Prevents unbounded
resource consumption. Each SBCL worker uses ~100-500 MB memory.
Default 16; override with DSMR_MAX_POOL_SIZE env var (positive integer).")

(defvar *health-check-interval-seconds* 10.0d0
  "Seconds between health monitor poll iterations.")

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

;;; ---------------------------------------------------------------------------
;;; Parent hard-kill backstop — dsmr-mcp addition over cl-mcp
;;; ---------------------------------------------------------------------------

(defparameter *worker-kill-grace-seconds*
  (let ((v (uiop:getenv "DSMR_WORKER_KILL_GRACE_SECONDS")))
    (if (and v (not (string= v "")))
        (max 1 (parse-integer v :junk-allowed t))
        5))
  "Grace margin in seconds added to the in-worker soft timeout before the
parent SIGKILLs the worker. If the worker's sb-ext:with-timeout fires and
the worker does not return a response within this grace margin, the parent
treats the worker as runaway and kills it, routing the crash through the
normal recovery path. Override via DSMR_WORKER_KILL_GRACE_SECONDS.")

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
  "Return the effective pool size: live workers plus in-flight spawns.
Counts all *all-workers* plus placeholder entries in *affinity-map*.
Must be called with *pool-lock* held."
  (let ((pending 0))
    (maphash (lambda (k v)
               (declare (ignore k))
               (when (typep v 'worker-placeholder)
                 (incf pending)))
             *affinity-map*)
    (+ (length *all-workers*) pending)))

;;; ---------------------------------------------------------------------------
;;; Internal — spawn and bind
;;; ---------------------------------------------------------------------------

(defun %spawn-and-bind (session-id placeholder &key need-reset)
  "Spawn a worker, bind it to SESSION-ID, and notify waiting threads.
On failure, clean up the affinity map entry and notify waiters. When
NEED-RESET is true, arms needs-reset-notification on the new worker before
making it visible. Returns the worker on success."
  (let ((new-worker nil))
    (unwind-protect
        (progn
          (setf new-worker (spawn-worker))
          (setf (worker-state new-worker) :bound)
          (setf (worker-session-id new-worker) session-id)
          (when need-reset
            (setf (worker-needs-reset-notification new-worker) t))
          (let ((cancelled nil))
            (bt:with-lock-held (*pool-lock*)
              (cond
                ((worker-placeholder-cancelled placeholder)
                 (setf cancelled t)
                 (setf (worker-state new-worker) :released))
                (t
                 (setf (gethash session-id *affinity-map*) new-worker)
                 (push new-worker *all-workers*))))
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
                       (* (+ *worker-startup-timeout* 15)
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
  "Spawn standby workers until the pool has *worker-pool-warmup* standbys.
Respects *max-pool-size*. Runs in a background thread; exits when
*pool-running* becomes NIL."
  (unwind-protect
      (loop (unless *pool-running* (return))
            (let ((need-more nil))
              (bt:with-lock-held (*pool-lock*)
                (when (and *pool-running*
                           (< (length *standby-workers*) *worker-pool-warmup*)
                           (< (%effective-pool-size) *max-pool-size*))
                  (setf need-more t)))
              (unless need-more (return))
              (handler-case
                  (let ((w (spawn-worker)))
                    (bt:with-lock-held (*pool-lock*)
                      (cond
                        ((not *pool-running*)
                         (ignore-errors (kill-worker w))
                         (return))
                        ((>= (%effective-pool-size) *max-pool-size*)
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
Skips if a replenish thread is already running. Captures the caller's
dynamic bindings for *worker-pool-warmup* and *max-pool-size* so the
value is honoured inside the new thread."
  (let ((should-start nil))
    (bt:with-lock-held (*pool-lock*)
      (when (and (not *replenish-running*)
                 (< (length *standby-workers*) *worker-pool-warmup*))
        (setf *replenish-running* t
              should-start t)))
    (when should-start
      (let ((warmup *worker-pool-warmup*)
            (max-size *max-pool-size*))
        (bt:make-thread
         (lambda ()
           (let ((*worker-pool-warmup* warmup)
                 (*max-pool-size* max-size))
             (%replenish-standbys)))
         :name "pool-replenish")))))

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

(defun %wait-for-next-health-check ()
  "Wait until the next health check interval, or until shutdown wakes us."
  (bt:with-lock-held (*health-monitor-lock*)
    (when *pool-running*
      (bt:condition-wait *health-monitor-condvar*
                         *health-monitor-lock*
                         :timeout *health-check-interval-seconds*))))

(defun %health-monitor-loop ()
  "Periodically check all workers via sb-ext:process-alive-p and dispatch
crash recovery asynchronously. Runs until *pool-running* becomes NIL."
  (loop while *pool-running*
        do (%wait-for-next-health-check)
           (when *pool-running*
             (handler-case
                 (let ((workers nil))
                   ;; Snapshot worker list under lock
                   (bt:with-lock-held (*pool-lock*)
                     (setf workers (copy-list *all-workers*)))
                   ;; Check each bound/standby worker outside the lock
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
    (unless (and (integerp *max-pool-size*) (plusp *max-pool-size*))
      (error "Invalid *max-pool-size*: must be a positive integer, got ~S"
             *max-pool-size*))
    (unless (and (integerp *worker-pool-warmup*)
                 (>= *worker-pool-warmup* 0))
      (error "Invalid *worker-pool-warmup*: must be a non-negative integer, got ~S"
             *worker-pool-warmup*))
    (when (> *worker-pool-warmup* *max-pool-size*)
      (error "*worker-pool-warmup* (~D) exceeds *max-pool-size* (~D)"
             *worker-pool-warmup* *max-pool-size*))
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
               "warmup_target" *worker-pool-warmup*
               "max_pool_size" *max-pool-size*)))

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
Signals error with 'Circuit breaker' in message during the cooldown window."
  (let ((entry nil) (need-spawn nil) (assigned-from-standby nil)
        (need-reset nil) (old-worker-to-kill nil)
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
            (error "Circuit breaker active for session ~A; ~As remaining in cooldown. ~
The worker crashed ~D times in ~Ds. Manual reset via release-session."
                   session-id (ceiling remaining)
                   *crash-breaker-threshold* *crash-breaker-window*))))
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
               need-reset (not (worker-needs-reset-notification old-worker-to-kill))))
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
                      (setf (worker-needs-reset-notification w) t))
                    (setf assigned-from-standby w)
                    (return))
                   (t
                    (setf *all-workers* (remove w *all-workers*))
                    (log-event :warn "pool.standby.dead-on-assign"
                               "worker_id" (worker-id w)
                               "pid" (worker-pid w)))))
        (when (and (null assigned-from-standby) (null entry))
          (when (>= (%effective-pool-size) *max-pool-size*)
            (error 'pool-capacity-exceeded :limit *max-pool-size*))
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
      (error "Circuit breaker tripped for session ~A: worker crashed ~D times ~
within ~Ds. Failing fast for ~Ds. Manual reset via release-session."
             session-id *crash-breaker-threshold* *crash-breaker-window*
             *circuit-breaker-cooldown*))
    (cond
      (assigned-from-standby
       (%schedule-replenish)
       assigned-from-standby)
      (need-spawn
       (%spawn-and-bind session-id entry :need-reset need-reset))
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
                      "session" session-id)))))
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
           (when reset (remhash session-id *circuit-breaker-map*))))))
    (when worker-to-kill
      (log-event :info "pool.session.worker-killed"
                 "session" session-id
                 "worker_id" (worker-id worker-to-kill))
      (ignore-errors (signal-worker-terminate worker-to-kill))
      (ignore-errors (kill-worker worker-to-kill))
      (%schedule-replenish))
    kill-result))

;;; ---------------------------------------------------------------------------
;;; Public API — pool-worker-info / pool-status-info
;;; ---------------------------------------------------------------------------

(defun pool-worker-info ()
  "Return a vector of worker info hash-tables for inclusion in pool-status output.
Includes id, session (truncated), tcp_port, pid, state. Omits swank_port
to prevent unrestricted REPL access bypassing MCP security policies."
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
                                       (symbol-name (worker-state w))))
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
            (gethash "max_pool_size" info) *max-pool-size*
            (gethash "warmup_target" info) *worker-pool-warmup*
            (gethash "workers" info) workers)
      info)))

;;; ---------------------------------------------------------------------------
;;; Public API — pool-rpc-with-hard-kill
;;; ---------------------------------------------------------------------------

(defun pool-rpc-with-hard-kill (worker method params
                                 &key (soft-timeout *default-eval-timeout*)
                                      (grace *worker-kill-grace-seconds*))
  "Send METHOD with PARAMS to WORKER, returning the result hash-table.

Implements a two-level timeout:
  - SOFT-TIMEOUT: passed to worker-rpc so the in-worker sb-ext:with-timeout
    fires if the eval exceeds it. The worker returns a TIMEOUT error payload.
    Defaults to *default-eval-timeout* (120 s) — the eval budget, not the
    startup budget.
  - Hard-kill backstop: if the worker does not return within SOFT-TIMEOUT +
    GRACE seconds, the parent kills the worker via its sb-ext:process object
    (avoiding the PID-reuse hazard of killing by raw numeric pid after the
    process may have already exited), then marks it crashed via the normal
    mark-worker-crashed path (which closes the stream and arms the reset
    notification), then signals WORKER-CRASHED so the dispatcher's existing
    handler returns a structured isError.

WORKER-CRASHED from worker-rpc is re-signalled unchanged so the dispatcher's
existing handler fires for both the soft and hard timeout cases."
  (let ((hard-timeout (when (and soft-timeout grace)
                        (+ soft-timeout grace))))
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
