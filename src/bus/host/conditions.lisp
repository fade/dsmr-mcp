;;;; src/bus/host/conditions.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; How the host service heals: faults are conditions, heals are restarts, and
;;;; one table decides which heal answers which fault.
;;;;
;;;; A fault is usually found deep inside the work of one bus or one agent: a
;;;; broker thread that died, a cursor stranded by a rotated log, a beat that
;;;; stopped. The code that finds it knows what a heal would look like there and
;;;; offers it as a restart, but it is the wrong place to decide whether to heal,
;;;; how often, or what to tell the fleet. Signalling a condition hands that
;;;; decision to one policy in the supervisor, so every fault on the host is
;;;; handled the same way and the policy can be read in one table.
;;;;
;;;; Every heal is bounded. A fault that comes back after it was healed is
;;;; healed again only up to a threshold within a window; the next occurrence
;;;; trips a breaker, which writes one ERROR record and skips the heal until the
;;;; cooldown has run. A fault that keeps coming back therefore becomes one loud
;;;; record a leader can act on, rather than a quiet loop that heals forever and
;;;; hides the cause. A fault with no heal, or whose heal was not on offer where
;;;; it was found, is reported at its table level and skipped. Nothing a fault
;;;; does gets past the supervisor; any other error still does, since it is not
;;;; this policy's to judge.
;;;;
;;;; The breaker is a pure function of its state and the time, in the manner of
;;;; the watcher's deafness rule, so its behaviour is tested by handing it the
;;;; clock rather than by sleeping. The words threshold, window and cooldown
;;;; are the ones the hermetic worker pool's crash breaker uses.

(defpackage #:dsmr-bus-host/src/bus/host/conditions
  (:use #:cl)
  (:local-nicknames (#:hostfiles #:dsmr-mcp/src/bus/hostfiles))
  (:export
   ;; faults
   #:host-fault
   #:fault-code
   #:fault-bus
   #:fault-id
   #:fault-subject
   #:fault-detail
   #:broker-thread-died
   #:bus-root-unusable
   #:client-elected-broker
   #:stranded-cursor
   #:wal-rotated
   #:stale-beat
   #:pid-claim-lost
   #:publication-gap
   #:unreadable-registration
   #:legacy-watcher-found
   #:session-gone
   #:parked-session-gone
   #:roster-gap
   #:memory-pressure
   #:memory-pressure-unrelieved
   ;; restarts
   #:skip-fault
   #:restart-broker-thread
   #:rebase-cursor
   #:rebase-cursors
   #:rewrite-beat
   #:reclaim-pid-file
   #:reconnect-feed
   #:quarantine-registration
   #:adopt-legacy-watcher
   #:lapse
   #:deregister
   #:request-hibernation
   ;; signalling
   #:raise-fault
   ;; breaker
   #:breaker-state
   #:make-breaker-state
   #:breaker-state-count
   #:breaker-state-window-start
   #:breaker-state-open-until
   #:breaker-step
   #:*breakers*
   ;; policy
   #:*healing-table*
   #:healing-entry
   #:call-with-healing
   #:with-healing))

(in-package #:dsmr-bus-host/src/bus/host/conditions)

;;; -------------------------------------------------------------------- faults

(define-condition host-fault (error)
  ((code :initarg :code :initform "host-fault" :reader fault-code
         :documentation "The code the fault is reported under in the fleet log.")
   (bus :initarg :bus :initform nil :reader fault-bus
        :documentation "The bus the fault was found on, or NIL.")
   (id :initarg :id :initform nil :reader fault-id
       :documentation "The agent identity the fault concerns, or NIL.")
   (subject :initarg :subject :initform nil :reader fault-subject
            :documentation "What the fault is about: an identity, a bus or a
                            file. Heals of one fault class are counted per
                            subject, so one agent's trouble never uses up
                            another's heals.")
   (detail :initarg :detail :initform nil :reader fault-detail
           :documentation "What was seen, in words, or NIL."))
  (:report (lambda (fault stream)
             (format stream "~A~@[ on bus ~A~]~@[ for ~A~]~@[: ~A~]"
                     (fault-code fault) (fault-bus fault) (fault-id fault)
                     (fault-detail fault))))
  (:documentation "Something the host service found wrong with a bus, an agent
   or itself. Signal one of its subclasses with RAISE-FAULT, offering the heal
   that fits as a restart; the supervisor decides whether to take it."))

(define-condition broker-thread-died (host-fault)
  ()
  (:default-initargs :code "broker-thread-died")
  (:documentation "A bus's broker thread inside the service stopped."))

(define-condition bus-root-unusable (host-fault)
  ()
  (:default-initargs :code "bus-root-unusable")
  (:documentation "A bus root cannot be served at all, for instance because
   its name is invalid or its socket path is too long. The bus is skipped and
   the others carry on."))

(define-condition client-elected-broker (host-fault)
  ()
  (:default-initargs :code "degraded")
  (:documentation "A bus is being served by a broker a client elected rather
   than by the service. Order is restored by a leader, not by the service."))

(define-condition stranded-cursor (host-fault)
  ()
  (:default-initargs :code "stranded-cursor")
  (:documentation "An agent's cursor points past the head of its bus's log, or
   at a log generation that is gone, so new mail would never wake it."))

(define-condition wal-rotated (host-fault)
  ()
  (:default-initargs :code "wal-rotated")
  (:documentation "A bus's log was rotated, so every cursor on it is stranded
   at once."))

(define-condition stale-beat (host-fault)
  ()
  (:default-initargs :code "stale-beat")
  (:documentation "A heartbeat file the service keeps fresh is old or
   missing."))

(define-condition pid-claim-lost (host-fault)
  ()
  (:default-initargs :code "pid-claim-lost")
  (:documentation "A pid file the service holds a lock on was removed or
   replaced, so probes no longer see the agent's watcher."))

(define-condition publication-gap (host-fault)
  ()
  (:default-initargs :code "publication-gap")
  (:documentation "A bus's log grew without the broker's publication feed
   saying so. The periodic read already delivered the mail; the feed is
   remade."))

(define-condition unreadable-registration (host-fault)
  ()
  (:default-initargs :code "unreadable-registration")
  (:documentation "A registration file cannot be read as one."))

(define-condition legacy-watcher-found (host-fault)
  ()
  (:default-initargs :code "legacy-watcher-found")
  (:documentation "A detached watcher process of the kind the service replaces
   is running on the host."))

(define-condition session-gone (host-fault)
  ()
  (:default-initargs :code "session-lapsed")
  (:documentation "The session behind a registration has ended without parking
   or deregistering."))

(define-condition parked-session-gone (host-fault)
  ()
  (:default-initargs :code "parked-session-ended")
  (:documentation "The session behind a registration has ended after parking,
   which is the expected way for a parked agent to go."))

(define-condition roster-gap (host-fault)
  ()
  (:default-initargs :code "roster-gap")
  (:documentation "An agent is on a bus roster but has no registration with the
   service. A finding to report, never a gate."))

(define-condition memory-pressure (host-fault)
  ()
  (:default-initargs :code "memory-pressure")
  (:documentation "The host is short of memory: stalls on memory are high or
   little memory is left available. The heal asks a session pool to stop or
   hibernate one idle worker."))

(define-condition memory-pressure-unrelieved (host-fault)
  ()
  (:default-initargs :code "memory-pressure-unrelieved")
  (:documentation "The host has stayed short of memory with no idle worker left
   to stop or hibernate. Nothing the service can do helps, so it is reported
   for a leader to act on."))

;;; ------------------------------------------------------------------ signalling

(defun raise-fault (class &rest initargs)
  "Signal a fault of CLASS made from INITARGS, with a SKIP-FAULT restart on
   offer around it. Returns :SKIPPED when the supervisor takes that restart.

   A heal is offered by the caller, with RESTART-CASE around this call and a
   clause named for the heal, so the restart runs in the frame that knows how
   to heal. The fault is signalled with ERROR, so outside a supervisor it is
   not ignored."
  (let ((fault (apply #'make-condition class initargs)))
    (restart-case (error fault)
      (skip-fault ()
        :report "Leave the fault unhealed and carry on."
        :skipped))))

;;; ------------------------------------------------------------------- breaker

(defstruct (breaker-state (:copier nil))
  "Where one breaker stands. COUNT heals have run in the window that began at
   WINDOW-START; OPEN-UNTIL, when set, is the time before which the breaker
   refuses every heal."
  (count 0 :type unsigned-byte)
  (window-start nil)
  (open-until nil))

(defun breaker-step (state now &key (threshold 3) (window 600) (cooldown 600))
  "Decide whether a heal may run at NOW, given the breaker STATE. Returns
   (values new-state allowed-p tripped-p). Pure: STATE is not modified.

   A heal is allowed while fewer than THRESHOLD have run in the current WINDOW
   seconds; a heal asked for outside the window starts a new one. The first
   heal refused in a full window trips the breaker (TRIPPED-P true, once), and
   every heal asked for in the COOLDOWN seconds after that is refused quietly.
   When the cooldown has run, the count starts again from nothing."
  (let ((count (breaker-state-count state))
        (start (breaker-state-window-start state))
        (open-until (breaker-state-open-until state)))
    (cond
      ((and open-until (< now open-until))
       (values state nil nil))
      ((or open-until (null start) (>= (- now start) window))
       (values (make-breaker-state :count 1 :window-start now) t nil))
      ((< count threshold)
       (values (make-breaker-state :count (1+ count) :window-start start) t nil))
      (t
       (values (make-breaker-state :open-until (+ now cooldown)) nil t)))))

(defvar *breakers* (make-hash-table :test 'equal :synchronized t)
  "The service's breakers, one per fault class and subject, keyed on
   (class . subject).")

(defvar *breakers-lock* (sb-thread:make-mutex :name "host fault breakers")
  "Held while a breaker is read, stepped and written back, so two threads
   reporting the same fault cannot both spend the same heal.")

(defun %step-breaker (breakers key now row)
  "Step the breaker for KEY in BREAKERS at NOW with ROW's budget, store the
   result, and return (values allowed-p tripped-p)."
  (sb-thread:with-mutex (*breakers-lock*)
    (multiple-value-bind (next allowed tripped)
        (breaker-step (or (gethash key breakers) (make-breaker-state))
                      now
                      :threshold (getf row :threshold)
                      :window (getf row :window)
                      :cooldown (getf row :cooldown))
      (setf (gethash key breakers) next)
      (values allowed tripped))))

;;; ------------------------------------------------------------- healing table

(defparameter *healing-table*
  '((:class broker-thread-died :restart restart-broker-thread
     :threshold 3 :window 600 :cooldown 600 :level :error :code "broker-thread-died")
    (:class bus-root-unusable :restart nil
     :level :error :code "bus-root-unusable")
    (:class client-elected-broker :restart nil
     :level :warn :code "degraded")
    (:class stranded-cursor :restart rebase-cursor
     :threshold 5 :window 600 :cooldown 600 :level :error :code "stranded-cursor")
    (:class wal-rotated :restart rebase-cursors
     :threshold 3 :window 600 :cooldown 600 :level :error :code "wal-rotated")
    (:class stale-beat :restart rewrite-beat
     :threshold 3 :window 600 :cooldown 600 :level :error :code "stale-beat")
    (:class pid-claim-lost :restart reclaim-pid-file
     :threshold 3 :window 600 :cooldown 600 :level :error :code "pid-claim-lost")
    (:class publication-gap :restart reconnect-feed
     :threshold 6 :window 600 :cooldown 600 :level :warn :code "publication-gap")
    (:class unreadable-registration :restart quarantine-registration
     :threshold 10 :window 600 :cooldown 600 :level :error :code "unreadable-registration")
    (:class legacy-watcher-found :restart adopt-legacy-watcher
     :threshold 50 :window 600 :cooldown 600 :level :warn :code "legacy-watcher-found")
    (:class session-gone :restart lapse
     :threshold 50 :window 600 :cooldown 600 :level :warn :code "session-lapsed")
    (:class parked-session-gone :restart deregister
     :threshold 50 :window 600 :cooldown 600 :level :info :code "parked-session-ended")
    (:class roster-gap :restart nil
     :level :info :code "roster-gap")
    (:class memory-pressure :restart request-hibernation
     :threshold 30 :window 600 :cooldown 60 :level :warn :code "memory-pressure")
    (:class memory-pressure-unrelieved :restart nil
     :level :error :code "memory-pressure-unrelieved"))
  "The healing policy, one row per fault class: the restart that heals it (NIL
   when nothing does), the breaker's THRESHOLD heals per WINDOW seconds and its
   COOLDOWN, the LEVEL a fault that goes unhealed is reported at, and the CODE
   it is reported under. A heal itself is reported at INFO and a tripped
   breaker at ERROR, whatever the row's level.")

(defun healing-entry (fault &optional (table *healing-table*))
  "The row of TABLE that handles FAULT, a condition or a fault class name, or
   NIL when no row does."
  (find-if (lambda (row)
             (if (symbolp fault)
                 (eq fault (getf row :class))
                 (typep fault (getf row :class))))
           table))

;;; ----------------------------------------------------------------- supervisor

(defun %report-to-stderr (level code &key bus id subject msg)
  "Write a report as a fleet line on standard error: the report of last resort
   when the supervisor was given no report function, or its own failed."
  (declare (ignore subject))
  (ignore-errors
   (format *error-output* "~A~%" (hostfiles:fleet-line level code :bus bus :id id :msg msg))
   (force-output *error-output*)))

(defun %report (report-fn fault level code msg)
  "Hand one record about FAULT to REPORT-FN. A report function that fails is
   itself reported on standard error, so it cannot let the fault escape."
  (flet ((send (fn)
           (funcall fn level code :bus (fault-bus fault) :id (fault-id fault)
                                  :subject (fault-subject fault) :msg msg)))
    (handler-case (send report-fn)
      (error (e)
        (send #'%report-to-stderr)
        (%report-to-stderr :error "report-failed" :msg (princ-to-string e))))))

(defun %fault-name (fault)
  "The fault's class name, in lower case, as messages show it."
  (string-downcase (symbol-name (class-name (class-of fault)))))

(defun %handle-fault (fault table report-fn now-fn breakers abandon)
  "Decide FAULT by TABLE: heal it, report and skip it, or skip it quietly while
   its breaker is open. ABANDON is called to leave the supervised work when
   the fault offers no SKIP-FAULT restart."
  (let* ((row (healing-entry fault table))
         (skip (find-restart 'skip-fault fault))
         (detail (fault-detail fault)))
    (flet ((skip-it ()
             (if skip (invoke-restart skip) (funcall abandon))))
      (when (null row)
        (%report report-fn fault :error (fault-code fault)
                 (format nil "~A has no healing row~@[: ~A~]" (%fault-name fault) detail))
        (skip-it))
      (let* ((restart-name (getf row :restart))
             (restart (and restart-name (find-restart restart-name fault)))
             (code (getf row :code)))
        (when (null restart)
          (%report report-fn fault (getf row :level) code
                   (if restart-name
                       (format nil "~@[~A; ~]no ~(~A~) on offer where it was found"
                               detail restart-name)
                       (or detail (%fault-name fault))))
          (skip-it))
        (multiple-value-bind (allowed tripped)
            (%step-breaker breakers
                           (cons (class-name (class-of fault)) (fault-subject fault))
                           (funcall now-fn) row)
          (cond
            (allowed
             (%report report-fn fault :info code
                      (format nil "healed by ~(~A~)~@[: ~A~]" restart-name detail))
             (invoke-restart restart))
            (tripped
             (%report report-fn fault :error "breaker-tripped"
                      (format nil "~A~@[ for ~A~] was healed ~D times within ~D s ~
                                   and came back; healing paused for ~D s~@[: ~A~]"
                              code (fault-subject fault) (getf row :threshold)
                              (getf row :window) (getf row :cooldown) detail))
             (skip-it))
            (t (skip-it))))))))

(defun call-with-healing (thunk &key (now-fn #'get-universal-time)
                                     (report-fn #'%report-to-stderr)
                                     (table *healing-table*)
                                     (breakers *breakers*))
  "Call THUNK, deciding every host fault it raises by TABLE.

   A fault whose heal is on offer is healed, within its breaker's budget, and
   reported at INFO. One that trips its breaker is reported at ERROR under the
   code breaker-tripped and skipped; while the breaker is open it is skipped
   without another record. One with no heal, or whose heal was not on offer
   where it was raised, is reported at its row's level and skipped. A fault
   raised without a SKIP-FAULT restart ends THUNK, and this returns :SKIPPED.
   Errors that are not host faults are left alone.

   REPORT-FN is called as (funcall report-fn level code &key bus id subject
   msg). NOW-FN gives the time in seconds. BREAKERS is a hash table keyed on
   (class . subject), equal-tested, holding each breaker's state."
  (block healing
    (handler-bind ((host-fault
                     (lambda (fault)
                       (%handle-fault fault table report-fn now-fn breakers
                                      (lambda () (return-from healing :skipped))))))
      (funcall thunk))))

(defmacro with-healing ((&rest options &key now-fn report-fn table breakers)
                        &body body)
  "Run BODY under CALL-WITH-HEALING with the given OPTIONS; those left out keep
   CALL-WITH-HEALING's defaults."
  (declare (ignore now-fn report-fn table breakers))
  `(call-with-healing (lambda () ,@body) ,@options))
