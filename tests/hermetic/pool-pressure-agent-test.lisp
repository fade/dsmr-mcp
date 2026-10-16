;;;; tests/hermetic/pool-pressure-agent-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; What a pool publishes about its workers, read without a single process.
;;;;
;;;; The host service chooses which worker to stop or hibernate from the
;;;; record each pool writes, and an operator reads the same facts through
;;;; pool-status. Both are built from the worker structs alone, so these cases
;;;; hand-build workers with MAKE-WORKER and bind the pool's specials around
;;;; them: nothing is spawned and nothing outlives a case.

(defpackage #:dsmr-mcp/tests/hermetic/pool-pressure-agent-test
  (:use #:cl #:zebra)
  (:import-from #:dsmr-mcp/src/hermetic/pool
                #:*pool-lock* #:*pool-running*
                #:*all-workers* #:*standby-workers*
                #:build-worker-record
                #:pool-worker-info #:pool-status-info
                #:*pressure-kill-min-age-seconds*
                #:*resolved-pool-settings* #:resolve-pool-settings
                #:pool-settings-pressure-kill-min-age-seconds
                #:*max-hibernated-workers*
                #:pool-settings-max-hibernated-workers)
  (:import-from #:dsmr-mcp/src/hermetic/worker-client
                #:make-worker #:*worker-core* #:*worker-core-disabled*)
  (:import-from #:dsmr-mcp/src/hermetic/pool-records
                #:server-stem #:parse-server-stem)
  (:import-from #:sb-posix)
  (:import-from #:uiop))

(in-package #:dsmr-mcp/tests/hermetic/pool-pressure-agent-test)

;;; ---------------------------------------------------------------------------
;;; Fixtures
;;; ---------------------------------------------------------------------------

(defun %fresh-worker ()
  "A worker bound to a session and never called: its last activity is unset
on the struct, as it is on a worker built before the pool stamps one."
  (make-worker :id 3 :state :bound :session-id "session-fresh"
               :pid 501001 :tcp-port 42001
               :boot-kind :core :spawned-at 1000))

(defun %busy-worker ()
  "A stateful worker with one call in flight."
  (make-worker :id 4 :state :bound :session-id "session-busy"
               :pid 501002 :tcp-port 42002
               :boot-kind :source :spawned-at 1100 :last-activity 1500
               :stateful-p t :in-flight 1))

(defun %hibernated-worker (now)
  "A worker whose world was saved to disk 30 s before NOW and that was once
refused for being busy."
  (make-worker :id 5 :state :hibernated
               :session-id "session-hibernated-long-name"
               :pid 501003 :tcp-port 42003 :swank-port 42004
               :boot-kind :resumed :spawned-at 1200 :last-activity 1700
               :stateful-p t
               :hibernate-core-path "/nonexistent/5.core"
               :hibernated-at (- now 30)
               :core-bytes 123456789
               :last-hibernate-milliseconds 900
               :last-resume-milliseconds 48
               :refused-reason "busy" :refused-at 1600))

(defun %unix-now ()
  "The current time in Unix seconds."
  (- (get-universal-time) (encode-universal-time 0 0 0 1 1 1970 0)))

(defmacro %with-workers ((&rest workers) &body body)
  "Evaluate BODY with a running pool whose only workers are WORKERS."
  `(let* ((*pool-running* t)
          (*all-workers* (list ,@workers))
          (*standby-workers* nil))
     ,@body))

(defun %record-worker (record id)
  "The worker plist with ID in RECORD."
  (find id (getf record :workers) :key (lambda (w) (getf w :id))))

(defun %info-worker (info id)
  "The pool-worker-info hash with ID."
  (find id (coerce info 'list) :key (lambda (h) (gethash "id" h))))

;;; ---------------------------------------------------------------------------
;;; The published record
;;; ---------------------------------------------------------------------------

(define-test the-record-names-this-server-and-every-worker
  "The record carries this server's pid and start time and one entry per
worker with every field the host service chooses by."
  (let ((now (%unix-now)))
    (%with-workers ((%fresh-worker) (%busy-worker) (%hibernated-worker now))
      (let ((record (build-worker-record now)))
        (multiple-value-bind (pid start) (parse-server-stem (server-stem))
          (is eql pid (getf record :server-pid))
          (is eql start (getf record :server-start)))
        (is eql now (getf record :written-at))
        (is = 3 (length (getf record :workers)))
        (dolist (w (getf record :workers))
          (is equal '(:id :pid :state :session :stateful :busy :spawned-at
                      :last-activity :refused-reason :refused-at :core-bytes)
              (loop for (k nil) on w by #'cddr collect k)
              "worker ~A keys" (getf w :id)))
        (let ((fresh (%record-worker record 3)))
          (is eql 501001 (getf fresh :pid))
          (is eq :bound (getf fresh :state))
          (is equal "session-fresh" (getf fresh :session))
          (is eq nil (getf fresh :stateful))
          (is eq nil (getf fresh :busy))
          (is eql 1000 (getf fresh :spawned-at))
          (is eql 1000 (getf fresh :last-activity)
              "a worker never called reports its spawn time as its activity"))
        (let ((busy (%record-worker record 4)))
          (is eq t (getf busy :stateful))
          (is eq t (getf busy :busy))
          (is eql 1500 (getf busy :last-activity)))
        (let ((hib (%record-worker record 5)))
          (is eq :hibernated (getf hib :state))
          (is eq nil (getf hib :pid)
              "a hibernated worker has no process, so no pid is published")
          (is eql 123456789 (getf hib :core-bytes))
          (is equal "busy" (getf hib :refused-reason))
          (is eql 1600 (getf hib :refused-at)))))))

(define-test the-record-carries-the-service-and-the-last-action
  "What the pool last saw of the service and the last request it answered
travel in the record, and are absent when there is nothing to say."
  (let ((now (%unix-now)))
    (%with-workers ((%fresh-worker))
      (let ((bare (build-worker-record now)))
        (is eq nil (getf bare :service-seen))
        (is eq nil (getf bare :last-action)))
      (let* ((action (list :worker-id 3 :action :kill :result :killed :at now))
             (record (build-worker-record now :service-seen t
                                              :last-action action)))
        (is eq t (getf record :service-seen))
        (is equal action (getf record :last-action))))))

(define-test no-published-worker-has-a-missing-activity
  "Every worker in the record has a last activity, whatever its struct holds."
  (let ((now (%unix-now)))
    (%with-workers ((%fresh-worker) (%busy-worker) (%hibernated-worker now))
      (dolist (w (getf (build-worker-record now) :workers))
        (true (integerp (getf w :last-activity)) "worker ~A" (getf w :id))))))

;;; ---------------------------------------------------------------------------
;;; Status fields
;;; ---------------------------------------------------------------------------

(define-test a-hibernated-worker-reports-its-saved-world
  "pool-worker-info gives a hibernated worker's statefulness, activity, boot
kind, core size and age, save and resume times and last refusal, and still
never its REPL port."
  (let ((now (%unix-now)))
    (%with-workers ((%hibernated-worker now) (%fresh-worker))
      (let* ((info (pool-worker-info))
             (hib (%info-worker info 5))
             (fresh (%info-worker info 3)))
        (dolist (key '("stateful" "busy" "last_activity" "boot" "core_bytes"
                       "core_age_seconds" "last_hibernate_ms" "last_resume_ms"
                       "refused_reason"))
          (true (nth-value 1 (gethash key hib)) "key ~A missing" key))
        (false (nth-value 1 (gethash "swank_port" hib)))
        (is eq t (gethash "stateful" hib))
        (is eq nil (gethash "busy" hib))
        (is eql 1700 (gethash "last_activity" hib))
        (is equal "resumed" (gethash "boot" hib))
        (is eql 123456789 (gethash "core_bytes" hib))
        (true (<= 30 (gethash "core_age_seconds" hib) 40)
              "age ~A" (gethash "core_age_seconds" hib))
        (is eql 900 (gethash "last_hibernate_ms" hib))
        (is eql 48 (gethash "last_resume_ms" hib))
        (is equal "busy" (gethash "refused_reason" hib))
        (is equal "hibernated" (gethash "state" hib))
        (is eq 'cl:null (gethash "pid" hib))
        (is eql 501001 (gethash "pid" fresh))
        ;; A worker with no saved world reports its absence as null.
        (is eql 1000 (gethash "last_activity" fresh))
        (is eq 'cl:null (gethash "core_bytes" fresh))
        (is eq 'cl:null (gethash "core_age_seconds" fresh))
        (is eq 'cl:null (gethash "refused_reason" fresh))
        (is equal "core" (gethash "boot" fresh))
        ;; The keys reported before stay.
        (dolist (key '("id" "session" "tcp_port" "pid" "state" "liveness"))
          (true (nth-value 1 (gethash key fresh)) "key ~A missing" key))))))

(define-test pool-status-counts-hibernated-and-resident-workers
  "pool-status-info counts hibernated and resident workers apart and says
whether pressure relief is active."
  (let ((now (%unix-now)))
    (%with-workers ((%hibernated-worker now) (%fresh-worker) (%busy-worker))
      (let ((info (pool-status-info)))
        (is = 1 (gethash "hibernated_count" info))
        (is = 2 (gethash "resident_count" info))
        (is = 2 (gethash "bound_count" info)
            "a hibernated worker is not counted as bound")
        (is equal "inactive" (gethash "pressure_relief" info)
            "no pressure agent runs in this case")
        (dolist (key '("pool_running" "total_workers" "standby_count"
                       "bound_count" "max_pool_size" "warmup_target" "workers"
                       "worker_core" "worker_core_status"))
          (true (nth-value 1 (gethash key info)) "key ~A missing" key))))))

(define-test pool-status-says-which-worker-core-is-in-use-or-why-none-is
  "worker_core is the core path new workers boot from, or null, and
worker_core_status says in use, unset, missing or disabled with the reason."
  (let ((file (uiop:with-temporary-file (:pathname p :keep t) p)))
    (unwind-protect
         (%with-workers ()
           (let ((*worker-core* (uiop:native-namestring file))
                 (*worker-core-disabled* nil))
             (let ((info (pool-status-info)))
               (is equal (uiop:native-namestring file)
                   (gethash "worker_core" info))
               (is equal "in use" (gethash "worker_core_status" info))))
           (let ((*worker-core* "/nonexistent/dsmr.core.worker")
                 (*worker-core-disabled* nil))
             (let ((info (pool-status-info)))
               (is eq 'cl:null (gethash "worker_core" info))
               (is equal "missing" (gethash "worker_core_status" info))))
           (let ((*worker-core* (uiop:native-namestring file))
                 (*worker-core-disabled* "boot failed"))
             (let ((info (pool-status-info)))
               (is eq 'cl:null (gethash "worker_core" info))
               (is equal "disabled: boot failed"
                   (gethash "worker_core_status" info))))
           (let ((env (uiop:getenv "DSMR_WORKER_CORE")))
             (when (or (null env) (zerop (length env)))
               (let ((*worker-core* nil)
                     (*worker-core-disabled* nil))
                 (is equal "unset"
                     (gethash "worker_core_status" (pool-status-info)))))))
      (ignore-errors (delete-file file)))))

;;; ---------------------------------------------------------------------------
;;; The minimum age before a pressure stop
;;; ---------------------------------------------------------------------------

(define-test the-minimum-kill-age-defaults-to-ten-seconds
  "With nothing set, a worker must be ten seconds old before a pressure stop;
a bound special wins, and so does the environment."
  (let ((old (sb-posix:getenv "DSMR_PRESSURE_MIN_KILL_AGE_SECONDS"))
        (*resolved-pool-settings* nil))
    (unwind-protect
         (progn
           (sb-posix:unsetenv "DSMR_PRESSURE_MIN_KILL_AGE_SECONDS")
           (let ((*pressure-kill-min-age-seconds* nil))
             (is = 10 (pool-settings-pressure-kill-min-age-seconds
                       (resolve-pool-settings))))
           (let ((*pressure-kill-min-age-seconds* 0))
             (is = 0 (pool-settings-pressure-kill-min-age-seconds
                      (resolve-pool-settings))))
           (sb-posix:setenv "DSMR_PRESSURE_MIN_KILL_AGE_SECONDS" "25" 1)
           (let ((*pressure-kill-min-age-seconds* nil))
             (is = 25 (pool-settings-pressure-kill-min-age-seconds
                       (resolve-pool-settings)))))
      (if old
          (sb-posix:setenv "DSMR_PRESSURE_MIN_KILL_AGE_SECONDS" old 1)
          (sb-posix:unsetenv "DSMR_PRESSURE_MIN_KILL_AGE_SECONDS")))))

(define-test the-hibernated-limit-defaults-to-eight-and-reaches-the-record
  "With nothing set a server keeps at most eight workers hibernated; a bound
special wins, and so does the environment. The published record says the
server is full once that many are hibernated, and not before."
  (let ((old (sb-posix:getenv "DSMR_MAX_HIBERNATED_WORKERS"))
        (*resolved-pool-settings* nil))
    (unwind-protect
         (progn
           (sb-posix:unsetenv "DSMR_MAX_HIBERNATED_WORKERS")
           (let ((*max-hibernated-workers* nil))
             (is = 8 (pool-settings-max-hibernated-workers (resolve-pool-settings))))
           (let ((*max-hibernated-workers* 0))
             (is = 0 (pool-settings-max-hibernated-workers (resolve-pool-settings))))
           (sb-posix:setenv "DSMR_MAX_HIBERNATED_WORKERS" "3" 1)
           (let ((*max-hibernated-workers* nil))
             (is = 3 (pool-settings-max-hibernated-workers (resolve-pool-settings))))
           (let ((now (%unix-now)))
             (%with-workers ((%fresh-worker) (%hibernated-worker now))
               (let ((*max-hibernated-workers* 1))
                 (resolve-pool-settings)
                 (is eq t (getf (build-worker-record now) :hibernate-full)))
               (let ((*max-hibernated-workers* 2))
                 (resolve-pool-settings)
                 (is eq nil (getf (build-worker-record now) :hibernate-full))))))
      (if old
          (sb-posix:setenv "DSMR_MAX_HIBERNATED_WORKERS" old 1)
          (sb-posix:unsetenv "DSMR_MAX_HIBERNATED_WORKERS")))))
