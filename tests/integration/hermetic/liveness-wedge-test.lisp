;;;; tests/integration/hermetic/liveness-wedge-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Planted-fault coverage for the hermetic pool's liveness classification.
;;;;
;;;; A suite that only ever runs against healthy workers proves the code runs.
;;;; It cannot prove the code detects anything, because nothing in it ever
;;;; creates the condition the detector exists to find. Every test here plants
;;;; a real fault in a real worker process and watches the classification move.
;;;;
;;;; The fault that matters is a worker that is alive and no longer answering,
;;;; because it is invisible to every check that asks the OS whether the process
;;;; exists. SIGSTOP produces exactly that state, and each test carries the
;;;; control that shows the assertion could have failed:
;;;;
;;;;   * an untouched worker reads healthy on the same probe, so a red reading
;;;;     is not the probe alarming at everything it sees;
;;;;   * the process reads alive at the moment the worker is called unresponsive,
;;;;     which is what makes the classification a new fact rather than a slower
;;;;     restatement of the crash check;
;;;;   * a SIGKILLed worker reads dead and not wedged, so the two faults are
;;;;     proven distinct;
;;;;   * a worker busy on a long evaluation is never called wedged, which is the
;;;;     false positive this whole design exists to avoid.
;;;;
;;;; These tests signal real child processes and take several seconds each. The
;;;; release signal is always issued from an unwind cleanup, so a failing
;;;; assertion cannot leave a stopped process behind.

(defpackage #:dsmr-mcp/tests/integration/hermetic/liveness-wedge-test
  (:use #:cl #:zebra)
  (:import-from #:dsmr-mcp/src/hermetic/pool
                #:initialize-pool #:shutdown-pool
                #:get-or-assign-worker
                #:*worker-pool-warmup* #:*max-pool-size*
                #:*health-check-interval-seconds*
                #:*missed-pings-before-wedged*
                #:%check-worker-liveness
                #:*pool-lock* #:*standby-workers*)
  (:import-from #:dsmr-mcp/src/hermetic/worker-client
                #:worker-rpc #:worker-pid #:worker-state #:worker-process-info
                #:worker-liveness #:worker-liveness-basis
                #:worker-last-ping-milliseconds
                #:worker-consecutive-missed-pings
                #:worker-liveness-checked-at)
  (:import-from #:dsmr-mcp/src/state
                #:*mode*)
  (:import-from #:dsmr-mcp/src/log
                #:configure-log4cl-for-server)
  (:import-from #:dsmr-mcp/tests/integration/support
                #:with-worker-child-or-skip)
  (:import-from #:sb-posix))

(in-package #:dsmr-mcp/tests/integration/hermetic/liveness-wedge-test)

;;; ---------------------------------------------------------------------------
;;; Signals used to plant and release the fault
;;; ---------------------------------------------------------------------------

(defconstant +freeze-signal+ 19
  "SIGSTOP. Halts a process without ending it, which is the one fault that
leaves every existence check answering exactly as it does for a healthy worker.")

(defconstant +release-signal+ 18
  "SIGCONT. Resumes a frozen process. Always sent from an unwind cleanup so a
red assertion cannot leave a stopped child behind.")

(defconstant +kill-signal+ 9
  "SIGKILL. Ends a process outright, producing the fault the pool could already
see, and here only as the control that keeps the two apart.")

;;; ---------------------------------------------------------------------------
;;; Fixture
;;; ---------------------------------------------------------------------------

(defun standby-worker (&key (deadline-seconds 60))
  "Wait until the pool holds an idle worker and return it, or NIL by DEADLINE-SECONDS.

Idle is the only state an active probe may touch, so every test here starts from
one. Waiting rather than assuming is what keeps the leaf usable on a cold fasl
cache, where the first child takes a while to come up."
  (loop repeat (ceiling deadline-seconds 0.1)
        for worker = (bt:with-lock-held (*pool-lock*) (first *standby-workers*))
        when worker return worker
        do (sleep 0.1)))

(defun drive-one-tick (worker)
  "Run exactly one health-monitor liveness sweep over WORKER.

Driving the sweep rather than waiting for the monitor thread is what makes these
observations deterministic: the classification is read at a point where exactly
one probe has happened since the last read, and never in a race with a timer."
  (%check-worker-liveness (list worker)))

(defmacro with-liveness-pool ((worker &key (threshold 2)) &body body)
  "Bring a pool up holding one idle worker, bind WORKER to it, and run BODY.

The health check interval is pushed far beyond the length of any test so the
background monitor never fires on its own. THRESHOLD sets how many consecutive
unanswered pings establish the unresponsive classification, so a test can choose
to cross that line or to stay deliberately under it."
  `(let ((*mode* :hermetic)
         (*error-output* (make-string-output-stream))
         (*health-check-interval-seconds* 3600.0d0)
         (*missed-pings-before-wedged* ,threshold)
         (*worker-pool-warmup* 1)
         (*max-pool-size* 4))
     (configure-log4cl-for-server :warn)
     (initialize-pool)
     (unwind-protect
          (let ((,worker (standby-worker)))
            (declare (ignorable ,worker))
            (true ,worker "the pool must hold an idle worker to probe")
            (when ,worker ,@body))
       (ignore-errors (shutdown-pool)))))

;;; ---------------------------------------------------------------------------
;;; The wedge plant
;;; ---------------------------------------------------------------------------

(define-test a-frozen-worker-is-classified-unresponsive
  "A worker frozen with SIGSTOP is alive and silent, and is classified wedged.

The freeze is the red condition this whole surface exists to report, and it is
planted rather than assumed. Its process reads alive throughout the part of the
run that matters, so nothing that asks the OS whether the worker exists could
have told it apart from a healthy one.

Two controls sit either side of the flip. The same worker on the same probe
reads healthy before the freeze, so the probe is not alarming at everything.
And one silence establishes nothing at all: the count rises, the classification
and its timestamp do not move, and the flip happens on the configured miss and
not before. Crossing the threshold also retires the worker, so nothing hands out
a worker that has been called unresponsive, and the pool comes back to a healthy
idle worker on its own."
  (with-worker-child-or-skip
    (with-liveness-pool (worker :threshold 2)
      (let ((pid (worker-pid worker))
            (process (worker-process-info worker)))
        ;; Control: the known-good case, on the same probe, before any fault.
        (drive-one-tick worker)
        (is eq :healthy (worker-liveness worker)
            "an untouched idle worker answers its ping")
        (is eq :active-probe (worker-liveness-basis worker)
            "and the record says the answer is what established it")
        (let ((established-at (worker-liveness-checked-at worker)))
          (unwind-protect
               (progn
                 (sb-posix:kill pid +freeze-signal+)
                 (sleep 0.3)
                 ;; The assertion that gives the rest its meaning.
                 (true (sb-ext:process-alive-p process)
                       "a frozen worker's process still reads alive")

                 (drive-one-tick worker)
                 (true (sb-ext:process-alive-p process)
                       "still alive after the first unanswered ping")
                 (is = 1 (worker-consecutive-missed-pings worker)
                     "one silence is counted")
                 (isnt eq :wedged (worker-liveness worker)
                       "one silence establishes nothing")
                 (is eql established-at (worker-liveness-checked-at worker)
                     "and an inconclusive check does not restamp the classification")
                 (is eq :standby (worker-state worker)
                     "a worker under the threshold is still in service")

                 (drive-one-tick worker)
                 (is eq :wedged (worker-liveness worker)
                     "the second consecutive silence establishes the classification")
                 (is eq :active-probe (worker-liveness-basis worker))
                 (true (>= (worker-consecutive-missed-pings worker) 2)
                       "with the missed count at the threshold")
                 (true (> (worker-liveness-checked-at worker) established-at)
                       "and a conclusive check does restamp it")
                 (false (member (worker-state worker) '(:standby :bound))
                        "a worker called unresponsive is taken out of service"))
            (ignore-errors (sb-posix:kill pid +release-signal+)))
          ;; The classification tracks the pool, not just the worker: the
          ;; retirement scheduled a replacement, and it answers.
          (let ((replacement (standby-worker)))
            (true replacement "retiring a wedged worker brings up a replacement")
            (when replacement
              (drive-one-tick replacement)
              (is eq :healthy (worker-liveness replacement)
                  "and the pool reads healthy again once it has"))))))))

;;; ---------------------------------------------------------------------------
;;; Recovery
;;; ---------------------------------------------------------------------------

(define-test a-released-worker-is-read-healthy-again
  "A worker released with SIGCONT while still in service is read healthy again.

A classification that latches once red is as useless as one that never goes red,
so the missed count must fall back to zero and a real round trip must be
recorded and freshly stamped. The threshold is set above the number of silences
planted here on purpose: crossing it retires the worker by design, so the state
in which recovery is even meaningful is the one below the line, which is exactly
the garbage collection pause the tolerance exists for.

The freshness of the stamp is what discriminates. Without it, a worker that was
never probed again would read healthy too, and the test would pass on nothing
having happened."
  (with-worker-child-or-skip
    (with-liveness-pool (worker :threshold 4)
      (let ((pid (worker-pid worker)))
        (drive-one-tick worker)
        (is eq :healthy (worker-liveness worker))
        (let ((established-at (worker-liveness-checked-at worker)))
          (unwind-protect
               (progn
                 (sb-posix:kill pid +freeze-signal+)
                 (sleep 0.3)
                 (drive-one-tick worker)
                 (drive-one-tick worker)
                 (is = 2 (worker-consecutive-missed-pings worker)
                     "two silences are counted")
                 (is eq :standby (worker-state worker)
                     "and a worker under the threshold is still in service"))
            (ignore-errors (sb-posix:kill pid +release-signal+)))
          (sleep 0.5)
          (drive-one-tick worker)
          (is eq :healthy (worker-liveness worker)
              "a released worker answers again")
          (is eq :active-probe (worker-liveness-basis worker))
          (is = 0 (worker-consecutive-missed-pings worker)
              "and the run of silences is forgotten")
          (true (integerp (worker-last-ping-milliseconds worker))
                "with a round trip actually measured")
          (true (> (worker-liveness-checked-at worker) established-at)
                "and freshly stamped, which is what proves the probe ran"))))))

;;; ---------------------------------------------------------------------------
;;; The crash control, so the two faults are proven distinct
;;; ---------------------------------------------------------------------------

(define-test a-killed-worker-is-classified-dead-and-not-unresponsive
  "A worker killed outright is classified dead, never wedged.

Without this the wedge test cannot show it is measuring unresponsiveness rather
than absence: both faults stop the answers arriving, and only the state of the
process tells them apart. A gone process is also concluded on the first probe
rather than counted toward a run of silences, because there is nothing left to
wait for."
  (with-worker-child-or-skip
    (with-liveness-pool (worker :threshold 2)
      (let ((process (worker-process-info worker)))
        (drive-one-tick worker)
        (is eq :healthy (worker-liveness worker)
            "the same worker on the same probe reads healthy first")
        (sb-posix:kill (worker-pid worker) +kill-signal+)
        (loop repeat 100
              while (sb-ext:process-alive-p process)
              do (sleep 0.1))
        (false (sb-ext:process-alive-p process)
               "the killed process is gone, which is the difference that matters")
        (drive-one-tick worker)
        (is eq :dead (worker-liveness worker))
        (isnt eq :wedged (worker-liveness worker)
              "absence is not unresponsiveness")
        (is = 0 (worker-consecutive-missed-pings worker)
            "a gone process is concluded at once, not counted toward a wedge")))))

;;; ---------------------------------------------------------------------------
;;; The busy control, which is the false positive this must not ship
;;; ---------------------------------------------------------------------------

(define-test a-busy-worker-is-never-classified-unresponsive
  "A worker mid-evaluation is classified by inference and never called wedged.

A worker running a long evaluation holds its channel for the whole call, so a
probe sent to it would either park the health monitor on somebody's real work or
expire and report a busy worker as broken. This is the test that fails if a
change ever lets the probe contend for that lock: the classification would go
red, or the ticks would take the length of the evaluation instead of no time at
all, and both are asserted.

The evaluation is checked to have genuinely run. A control that idles is not a
control, and this one would otherwise pass just as well against a worker doing
nothing."
  (with-worker-child-or-skip
    (with-liveness-pool (idle :threshold 2)
      (let* ((worker (get-or-assign-worker "long-evaluation-session"))
             (answer nil)
             (evaluator
               (bt:make-thread
                (lambda ()
                  (setf answer
                        (ignore-errors
                          (worker-rpc worker "worker/eval"
                                      (let ((params (make-hash-table :test 'equal)))
                                        (setf (gethash "code" params) "(sleep 8)"
                                              (gethash "timeout_seconds" params) 30)
                                        params)
                                      :timeout 60))))
                :name "liveness-busy-evaluator")))
        (sleep 1)
        (is eq :bound (worker-state worker)
            "the worker is bound to the session running the evaluation")
        (let ((started (get-internal-real-time)))
          (drive-one-tick worker)
          (drive-one-tick worker)
          (let ((elapsed (/ (- (get-internal-real-time) started)
                            internal-time-units-per-second)))
            (true (< elapsed 3)
                  "two ticks over a busy worker cost nothing, because none of them waits on it")))
        (isnt eq :wedged (worker-liveness worker)
              "a worker doing real work is not unresponsive")
        (is eq :healthy (worker-liveness worker))
        (is eq :passive-inference (worker-liveness-basis worker)
            "and the record says it was inferred, not asked")
        (is = 0 (worker-consecutive-missed-pings worker)
            "no ping was sent, so no ping went unanswered")
        (bt:join-thread evaluator)
        (true answer
              "the evaluation must actually have run, or this control tests nothing")))))
