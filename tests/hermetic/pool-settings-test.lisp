;;;; tests/hermetic/pool-settings-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Unit tests for the pool and worker tuning settings.
;;;;
;;;; Every one of these settings is read from the environment when the server
;;;; or worker starts, never when its file loads, so a server booted from a
;;;; prebuilt image honours the environment it is started with rather than the
;;;; one the image was built under. The tests change the environment after the
;;;; system has loaded and check that the new value is the one resolved; they
;;;; also check the defaults and that a bound special still wins over the
;;;; environment.
;;;;
;;;; No worker is spawned here. Each test restores the environment variables
;;;; and the resolved settings it touched.

(defpackage #:dsmr-mcp/tests/hermetic/pool-settings-test
  (:use #:cl #:zebra)
  (:import-from #:dsmr-mcp/src/hermetic/pool
                #:*worker-pool-warmup*
                #:*max-pool-size*
                #:*worker-kill-grace-seconds*
                #:*resolved-pool-settings*
                #:resolve-pool-settings
                #:pool-settings-warmup
                #:pool-settings-max-pool-size
                #:pool-settings-kill-grace-seconds
                #:effective-max-pool-size)
  (:import-from #:dsmr-mcp/src/transport/dispatch-pool
                #:*dispatch-pool-size*
                #:effective-dispatch-pool-size)
  (:import-from #:dsmr-mcp/src/hermetic/worker-client
                #:*worker-startup-timeout*
                #:*resolved-worker-startup-timeout*
                #:resolve-worker-startup-timeout
                #:effective-worker-startup-timeout)
  (:import-from #:dsmr-mcp/src/hermetic/worker/handlers
                #:*default-eval-timeout*
                #:*resolved-eval-timeout*
                #:resolve-eval-timeout
                #:effective-eval-timeout)
  (:import-from #:sb-posix))

(in-package #:dsmr-mcp/tests/hermetic/pool-settings-test)

;;; ---------------------------------------------------------------------------
;;; Environment isolation
;;; ---------------------------------------------------------------------------

(defparameter +settings-env-vars+
  '("DSMR_WORKER_POOL_WARMUP" "DSMR_MAX_POOL_SIZE"
    "DSMR_WORKER_KILL_GRACE_SECONDS" "DSMR_DISPATCH_POOL_SIZE"
    "DSMR_WORKER_STARTUP_TIMEOUT" "DSMR_WORKER_EVAL_TIMEOUT")
  "Every environment variable the settings resolvers read. A developer shell
may export any of them, so each test starts with all of them unset.")

(defun %set-env (name value)
  "Set environment variable NAME to the string VALUE, or unset it when VALUE
is NIL."
  (if value
      (sb-posix:setenv name value 1)
      (sb-posix:unsetenv name)))

(defun call-with-settings-env (thunk)
  "Call THUNK with every variable in +SETTINGS-ENV-VARS+ unset, the setting
specials NIL and nothing resolved, then put the environment and the resolved
settings back as they were.

The resolved settings are saved and restored rather than rebound, because a
thread started inside THUNK sees only the global value, and that is exactly
what the pool's own threads read."
  (let ((saved-env (mapcar (lambda (name) (cons name (sb-posix:getenv name)))
                           +settings-env-vars+))
        (saved-settings *resolved-pool-settings*)
        (saved-startup *resolved-worker-startup-timeout*)
        (saved-eval *resolved-eval-timeout*))
    (unwind-protect
         (progn
           (dolist (name +settings-env-vars+) (%set-env name nil))
           (setf *resolved-pool-settings* nil
                 *resolved-worker-startup-timeout* nil
                 *resolved-eval-timeout* nil)
           (let ((*worker-pool-warmup* nil)
                 (*max-pool-size* nil)
                 (*worker-kill-grace-seconds* nil)
                 (*dispatch-pool-size* nil)
                 (*worker-startup-timeout* nil)
                 (*default-eval-timeout* nil))
             (funcall thunk)))
      (setf *resolved-pool-settings* saved-settings
            *resolved-worker-startup-timeout* saved-startup
            *resolved-eval-timeout* saved-eval)
      (dolist (pair saved-env)
        (%set-env (car pair) (cdr pair))))))

(defmacro with-settings-env (&body body)
  "Evaluate BODY under CALL-WITH-SETTINGS-ENV."
  `(call-with-settings-env (lambda () ,@body)))

(defun %resolve-capturing-warnings (thunk)
  "Call THUNK, muffling every warning it signals. Return its value and the
number of warnings muffled."
  (let ((count 0))
    (values (handler-bind ((warning (lambda (w)
                                      (incf count)
                                      (muffle-warning w))))
              (funcall thunk))
            count)))

;;; ---------------------------------------------------------------------------
;;; Pool settings
;;; ---------------------------------------------------------------------------

(define-test pool-settings-default-with-nothing-set
  ;; No environment and no bound special: no warm standby, the stock maximum
  ;; and the stock kill grace.
  (with-settings-env
    (let ((settings (resolve-pool-settings)))
      (is = 0 (pool-settings-warmup settings))
      (is = 16 (pool-settings-max-pool-size settings))
      (is = 5 (pool-settings-kill-grace-seconds settings)))))

(define-test pool-settings-read-the-environment-when-resolved
  ;; The variable is set after the system loaded, so a value read at load
  ;; time could not see it.
  (with-settings-env
    (%set-env "DSMR_MAX_POOL_SIZE" "7")
    (is = 7 (pool-settings-max-pool-size (resolve-pool-settings)))
    (%set-env "DSMR_MAX_POOL_SIZE" nil)
    (is = 16 (pool-settings-max-pool-size (resolve-pool-settings)))))

(define-test warmup-honours-the-environment-and-rejects-junk
  (with-settings-env
    (%set-env "DSMR_WORKER_POOL_WARMUP" "3")
    (is = 3 (pool-settings-warmup (resolve-pool-settings)))
    (%set-env "DSMR_WORKER_POOL_WARMUP" "abc")
    (multiple-value-bind (settings warnings)
        (%resolve-capturing-warnings #'resolve-pool-settings)
      (is = 0 (pool-settings-warmup settings))
      (true (plusp warnings)))))

(define-test bound-special-wins-over-the-environment
  (with-settings-env
    (%set-env "DSMR_MAX_POOL_SIZE" "9")
    (let ((*max-pool-size* 4))
      (is = 4 (pool-settings-max-pool-size (resolve-pool-settings))))))

(define-test resolved-settings-are-stored-globally
  ;; The struct is what pool threads read, so the binding in force at resolve
  ;; time is what every thread sees afterwards.
  (with-settings-env
    (let ((*max-pool-size* 4))
      (resolve-pool-settings))
    (is = 4 (effective-max-pool-size))
    (is = 4 (bt:join-thread (bt:make-thread #'effective-max-pool-size)))))

(define-test effective-maximum-resolves-lazily
  (with-settings-env
    (%set-env "DSMR_MAX_POOL_SIZE" "6")
    (false *resolved-pool-settings*)
    (is = 6 (effective-max-pool-size))
    (true *resolved-pool-settings*)))

;;; ---------------------------------------------------------------------------
;;; Dispatch pool size
;;; ---------------------------------------------------------------------------

(define-test dispatch-pool-size-follows-the-resolved-maximum
  (with-settings-env
    (%set-env "DSMR_DISPATCH_POOL_SIZE" "7")
    (resolve-pool-settings)
    (is = 7 (effective-dispatch-pool-size))
    (let ((*max-pool-size* 4))
      (resolve-pool-settings))
    (is = 4 (effective-dispatch-pool-size))))

;;; ---------------------------------------------------------------------------
;;; Worker eval timeout and startup timeout
;;; ---------------------------------------------------------------------------

(define-test eval-timeout-reads-the-environment-when-resolved
  (with-settings-env
    (is = 120 (resolve-eval-timeout))
    (%set-env "DSMR_WORKER_EVAL_TIMEOUT" "11")
    (is = 11 (resolve-eval-timeout))
    (is = 11 (effective-eval-timeout))
    ;; Below one second is raised to one, as it always was.
    (%set-env "DSMR_WORKER_EVAL_TIMEOUT" "0")
    (is = 1 (resolve-eval-timeout))
    (%set-env "DSMR_WORKER_EVAL_TIMEOUT" "x")
    (multiple-value-bind (timeout warnings)
        (%resolve-capturing-warnings #'resolve-eval-timeout)
      (is = 120 timeout)
      (true (plusp warnings)))))

(define-test bound-eval-timeout-wins-over-the-environment
  (with-settings-env
    (%set-env "DSMR_WORKER_EVAL_TIMEOUT" "11")
    (let ((*default-eval-timeout* 9))
      (is = 9 (resolve-eval-timeout)))))

(define-test effective-eval-timeout-resolves-lazily
  (with-settings-env
    (%set-env "DSMR_WORKER_EVAL_TIMEOUT" "13")
    (false *resolved-eval-timeout*)
    (is = 13 (effective-eval-timeout))
    (true *resolved-eval-timeout*)))

(define-test startup-timeout-reads-the-environment-when-resolved
  (with-settings-env
    (is = 30 (resolve-worker-startup-timeout))
    (%set-env "DSMR_WORKER_STARTUP_TIMEOUT" "45")
    (is = 45 (resolve-worker-startup-timeout))
    (is = 45 (effective-worker-startup-timeout))))

(define-test resolving-the-pool-refreshes-both-timeouts
  ;; A pool start is the one place the server resolves, so it carries the
  ;; worker timeouts along with the pool fields.
  (with-settings-env
    (resolve-pool-settings)
    (is = 120 (effective-eval-timeout))
    (is = 30 (effective-worker-startup-timeout))
    (%set-env "DSMR_WORKER_EVAL_TIMEOUT" "17")
    (%set-env "DSMR_WORKER_STARTUP_TIMEOUT" "19")
    (resolve-pool-settings)
    (is = 17 (effective-eval-timeout))
    (is = 19 (effective-worker-startup-timeout))))
