;;;; tests/bus/host-conditions-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Zebra tests for the host service's condition protocol: the breaker that
;;;; bounds every heal, the supervisor's handling of a fault that has a heal, one
;;;; that has none and one whose heal is not on offer where it was found, and the
;;;; healing table itself. The clock is a number the test hands in, so nothing
;;;; here sleeps, and every report lands in a list rather than a file.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/bus/host-conditions-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/bus/host-conditions-test
  (:use #:cl #:zebra)
  (:local-nicknames (#:conditions #:dsmr-bus-host/src/bus/host/conditions)))

(in-package #:dsmr-mcp/tests/bus/host-conditions-test)

;;; ------------------------------------------------------------------ fixtures

(defun recorder ()
  "A report function and a reader for what it was given. Each record is the
   list (level code bus id subject msg)."
  (let ((records '()))
    (values (lambda (level code &key bus id subject msg)
              (push (list level code bus id subject msg) records))
            (lambda () (reverse records)))))

(defun records-with-code (records code)
  "The records in RECORDS whose code is CODE."
  (remove-if-not (lambda (record) (equal (second record) code)) records))

(defun inject-stale-beat (subject heals)
  "Raise a stale beat for SUBJECT with a heal on offer, as a beat check would.
   The heal counts itself in the car of HEALS and answers :HEALED."
  (restart-case (conditions:raise-fault 'conditions:stale-beat
                                        :bus "b"
                                        :id (format nil "/n/~A" subject)
                                        :subject subject
                                        :detail "beat is 9 s old")
    (conditions:rewrite-beat ()
      (incf (car heals))
      :healed)))

(defun fresh-breakers ()
  "An empty breaker table, so one test's trips never reach another."
  (make-hash-table :test 'equal))

;;; ------------------------------------------------------------------- breaker

(define-test the-breaker-allows-its-threshold-then-trips-once-and-reopens
  "Three heals inside the window are allowed, the fourth trips the breaker and
   says so once, later ones are refused quietly, and once the cooldown has run
   the count starts again from nothing."
  (let ((state (conditions:make-breaker-state))
        (outcomes '()))
    (flet ((step-at (now)
             (multiple-value-bind (next allowed tripped)
                 (conditions:breaker-step state now :threshold 3 :window 600
                                                    :cooldown 600)
               (setf state next)
               (push (list now allowed tripped) outcomes)
               (values allowed tripped))))
      (dolist (now '(0 1 2))
        (multiple-value-bind (allowed tripped) (step-at now)
          (true allowed)
          (false tripped)))
      (multiple-value-bind (allowed tripped) (step-at 3)
        (false allowed)
        (true tripped))
      (multiple-value-bind (allowed tripped) (step-at 4)
        (false allowed)
        (false tripped))
      (multiple-value-bind (allowed tripped) (step-at (+ 3 600))
        (true allowed)
        (false tripped))
      ;; a fresh count: two more inside the new window are still allowed
      (true (step-at (+ 3 601)))
      (true (step-at (+ 3 602)))
      (false (step-at (+ 3 603))))))

(define-test the-breaker-step-leaves-its-input-alone
  "The step is pure: the state handed in reads the same afterwards."
  (let ((state (conditions:make-breaker-state)))
    (conditions:breaker-step state 0 :threshold 1 :window 600 :cooldown 600)
    (conditions:breaker-step state 1 :threshold 1 :window 600 :cooldown 600)
    (is = 0 (conditions:breaker-state-count state))
    (is eq nil (conditions:breaker-state-open-until state))))

(define-test a-count-outside-the-window-starts-a-new-window
  "Faults spread wider apart than the window never trip the breaker."
  (let ((state (conditions:make-breaker-state)))
    (dolist (now '(0 700 1400 2100 2800))
      (multiple-value-bind (next allowed tripped)
          (conditions:breaker-step state now :threshold 1 :window 600 :cooldown 600)
        (setf state next)
        (true allowed)
        (false tripped)))))

;;; ------------------------------------------------------------------- healing

(define-test a-fault-with-a-heal-on-offer-is-healed-and-reported-at-info
  "The heal named in the table runs where the fault was found, and the report
   function hears about it as an INFO record carrying the fault's code."
  (multiple-value-bind (report-fn records) (recorder)
    (let* ((heals (list 0))
           (result (conditions:with-healing (:now-fn (lambda () 100)
                                             :report-fn report-fn
                                             :breakers (fresh-breakers))
                     (inject-stale-beat "a" heals))))
      (is eq :healed result)
      (is = 1 (car heals))
      (is = 1 (length (funcall records)))
      (destructuring-bind (level code bus id subject msg) (first (funcall records))
        (is eq :info level)
        (is string= "stale-beat" code)
        (is string= "b" bus)
        (is string= "/n/a" id)
        (is string= "a" subject)
        (true (search "rewrite-beat" msg))))))

(define-test a-fault-that-keeps-returning-trips-its-breaker-and-is-skipped
  "Inside one window the heal runs three times, the fourth occurrence writes a
   single ERROR breaker-tripped record and is skipped, a fifth is skipped
   without another record, and the same fault for another subject still heals."
  (multiple-value-bind (report-fn records) (recorder)
    (let* ((heals (list 0))
           (clock 0)
           (breakers (fresh-breakers)))
      (flet ((once (subject)
               (conditions:call-with-healing
                (lambda () (inject-stale-beat subject heals))
                :now-fn (lambda () (incf clock))
                :report-fn report-fn
                :breakers breakers)))
        (let ((results (loop repeat 4 collect (once "a"))))
          (is equal '(:healed :healed :healed :skipped) results))
        (is = 3 (car heals))
        (let ((trips (records-with-code (funcall records) "breaker-tripped")))
          (is = 1 (length trips))
          (is eq :error (first (first trips)))
          (is string= "a" (fifth (first trips))))
        (is eq :skipped (once "a"))
        (is = 1 (length (records-with-code (funcall records) "breaker-tripped")))
        (is = 3 (car heals))
        (is eq :healed (once "other"))
        (is = 4 (car heals))))))

(define-test a-fault-with-no-heal-is-reported-at-its-level-and-skipped
  "A roster gap has no heal in the table: it is reported at INFO under its own
   code and skipped."
  (multiple-value-bind (report-fn records) (recorder)
    (let ((result (conditions:call-with-healing
                   (lambda ()
                     (conditions:raise-fault 'conditions:roster-gap
                                             :bus "b" :id "/n/z" :subject "/n/z"
                                             :detail "on the roster, never registered"))
                   :now-fn (lambda () 0)
                   :report-fn report-fn
                   :breakers (fresh-breakers))))
      (is eq :skipped result)
      (is = 1 (length (funcall records)))
      (is eq :info (first (first (funcall records))))
      (is string= "roster-gap" (second (first (funcall records)))))))

(define-test a-heal-not-on-offer-where-the-fault-was-found-is-reported-and-skipped
  "A stranded cursor's heal is a restart the signal site has to establish.
   Raised without it, the fault is reported at its table level and skipped,
   and never escapes the supervisor."
  (multiple-value-bind (report-fn records) (recorder)
    (let ((result (handler-case
                      (conditions:call-with-healing
                       (lambda ()
                         (conditions:raise-fault 'conditions:stranded-cursor
                                                 :bus "b" :id "/n/a" :subject "/n/a"
                                                 :detail "cursor above head"))
                       :now-fn (lambda () 0)
                       :report-fn report-fn
                       :breakers (fresh-breakers))
                    (error () :escaped))))
      (is eq :skipped result)
      (is = 1 (length (funcall records)))
      (destructuring-bind (level code &rest rest) (first (funcall records))
        (declare (ignore rest))
        (is eq :error level)
        (is string= "stranded-cursor" code)))))

(define-test a-fault-signalled-without-a-skip-is-still-contained
  "A fault raised with plain ERROR, so with no skip on offer, still stops at
   the supervisor: it is reported and the supervised work answers :SKIPPED."
  (multiple-value-bind (report-fn records) (recorder)
    (let ((result (handler-case
                      (conditions:call-with-healing
                       (lambda ()
                         (error 'conditions:roster-gap :subject "x")
                         :not-reached)
                       :now-fn (lambda () 0)
                       :report-fn report-fn
                       :breakers (fresh-breakers))
                    (error () :escaped))))
      (is eq :skipped result)
      (is = 1 (length (funcall records))))))

(define-test an-ordinary-error-is-not-swallowed
  "Only host faults are the supervisor's business; any other error carries on
   to whoever called it."
  (multiple-value-bind (report-fn records) (recorder)
    (is eq :escaped
        (handler-case
            (conditions:call-with-healing (lambda () (error "not a fault"))
                                          :now-fn (lambda () 0)
                                          :report-fn report-fn
                                          :breakers (fresh-breakers))
          (simple-error () :escaped)))
    (is = 0 (length (funcall records)))))

(define-test a-report-function-that-fails-does-not-let-the-fault-out
  "A broken report function must not turn a contained fault into an escaped
   error."
  (let ((result (handler-case
                    (let ((*error-output* (make-broadcast-stream)))
                      (conditions:call-with-healing
                       (lambda ()
                         (conditions:raise-fault 'conditions:roster-gap :subject "x"))
                       :now-fn (lambda () 0)
                       :report-fn (lambda (&rest args)
                                    (declare (ignore args))
                                    (error "report failed"))
                       :breakers (fresh-breakers)))
                  (error () :escaped))))
    (is eq :skipped result)))

(define-test a-fault-carries-its-code-bus-identity-subject-and-detail
  "Each fault names what went wrong, where and to whom, and its code defaults to
   the code its healing row reports under."
  (let ((fault (make-condition 'conditions:session-gone
                               :bus "b" :id "/n/a" :subject "/n/a" :detail "pid 7 gone")))
    (is string= "session-lapsed" (conditions:fault-code fault))
    (is string= "b" (conditions:fault-bus fault))
    (is string= "/n/a" (conditions:fault-id fault))
    (is string= "/n/a" (conditions:fault-subject fault))
    (is string= "pid 7 gone" (conditions:fault-detail fault))
    (true (typep fault 'conditions:host-fault))
    (true (search "session-lapsed" (princ-to-string fault)))))

;;; ------------------------------------------------------------- healing table

(defparameter *expected-rows*
  '((conditions:broker-thread-died conditions:restart-broker-thread 3 600 600 :error "broker-thread-died")
    (conditions:bus-root-unusable nil nil nil nil :error "bus-root-unusable")
    (conditions:client-elected-broker nil nil nil nil :warn "degraded")
    (conditions:stranded-cursor conditions:rebase-cursor 5 600 600 :error "stranded-cursor")
    (conditions:wal-rotated conditions:rebase-cursors 3 600 600 :error "wal-rotated")
    (conditions:stale-beat conditions:rewrite-beat 3 600 600 :error "stale-beat")
    (conditions:pid-claim-lost conditions:reclaim-pid-file 3 600 600 :error "pid-claim-lost")
    (conditions:publication-gap conditions:reconnect-feed 6 600 600 :warn "publication-gap")
    (conditions:unreadable-registration conditions:quarantine-registration 10 600 600 :error "unreadable-registration")
    (conditions:legacy-watcher-found conditions:adopt-legacy-watcher 50 600 600 :warn "legacy-watcher-found")
    (conditions:session-gone conditions:lapse 50 600 600 :warn "session-lapsed")
    (conditions:parked-session-gone conditions:deregister 50 600 600 :info "parked-session-ended")
    (conditions:roster-gap nil nil nil nil :info "roster-gap"))
  "Each fault class with the heal, budget, level and code it is handled with.")

(defun row-matches-p (class restart threshold window cooldown level code)
  "True when the healing table's row for CLASS says exactly this."
  (let ((row (conditions:healing-entry (make-condition class))))
    (and row
         (eq class (getf row :class))
         (eq restart (getf row :restart))
         (eql threshold (getf row :threshold))
         (eql window (getf row :window))
         (eql cooldown (getf row :cooldown))
         (eq level (getf row :level))
         (equal code (getf row :code))
         (equal code (conditions:fault-code (make-condition class))))))

(define-test every-fault-class-has-the-healing-row-it-is-handled-by
  "One check per fault class: the table is the policy, so a row that drifts is
   a change of behaviour."
  (is = (length *expected-rows*) (length conditions:*healing-table*))
  (true (apply #'row-matches-p (nth 0 *expected-rows*)))
  (true (apply #'row-matches-p (nth 1 *expected-rows*)))
  (true (apply #'row-matches-p (nth 2 *expected-rows*)))
  (true (apply #'row-matches-p (nth 3 *expected-rows*)))
  (true (apply #'row-matches-p (nth 4 *expected-rows*)))
  (true (apply #'row-matches-p (nth 5 *expected-rows*)))
  (true (apply #'row-matches-p (nth 6 *expected-rows*)))
  (true (apply #'row-matches-p (nth 7 *expected-rows*)))
  (true (apply #'row-matches-p (nth 8 *expected-rows*)))
  (true (apply #'row-matches-p (nth 9 *expected-rows*)))
  (true (apply #'row-matches-p (nth 10 *expected-rows*)))
  (true (apply #'row-matches-p (nth 11 *expected-rows*)))
  (true (apply #'row-matches-p (nth 12 *expected-rows*))))
