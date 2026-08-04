;;;; src/project-deviation.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; What it means for a repository to differ from the shape a project of ours
;;;; has, and the three decisions that can be taken about one such difference.
;;;;
;;;; A difference is a condition class carrying the item it is about, never a
;;;; path string. A string cannot be dispatched on, so a finding reported as a
;;;; list of missing filenames forces every consumer to work out for itself what
;;;; kind of problem it is looking at, and each consumer works it out
;;;; differently. The class and the item are the identity of the finding; the
;;;; detail slot is prose for a person and nothing branches on it.
;;;;
;;;; The three decisions are named restarts rather than report categories:
;;;; REPAIR for a difference demonstrated to be a defect, RECORD-AS-DEBT for one
;;;; examined and frozen together with its diagnosis, ACCEPT-AS-DELIBERATE for
;;;; one that is correct as written. That vocabulary is not coined here. It is
;;;; the triage taxonomy already in use across the fleet, stated as recoveries
;;;; instead of as labels, so the recovery is an explicit named decision at a
;;;; site that understands the consequence rather than a default buried in a
;;;; handler.
;;;;
;;;; One difference is deliberately not repairable. Our operational apparatus
;;;; being tracked in a repository we do not own is a violation whose obvious
;;;; fix, removing the file, is itself a change to somebody else's tracked tree,
;;;; which is forbidden just as firmly as adding one. So REPAIR is not merely
;;;; discouraged there: the restart carries a test that makes FIND-RESTART fail
;;;; to find it, and a policy naming it signals rather than quietly doing
;;;; something else instead.
;;;;
;;;; Scope, and the seam that bounds it. Everything here lives inside a single
;;;; call. A restart established while answering one request is gone the moment
;;;; that answer is sent, so no later request can resume it. What survives across
;;;; that boundary is the restart NAMES, as the vocabulary a caller picks a
;;;; policy from and as the words a report answers in. The machinery does not.
;;;; This module is the in-image half only.
;;;;
;;;; No restart here performs any I/O. Each returns a keyword naming what was
;;;; decided, and the engine that interprets that keyword owns every effect. That
;;;; is what lets this module be tested with no filesystem and no repository at
;;;; all.

(defpackage #:dsmr-mcp/src/project-deviation
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/project-shape
                #:shape-item
                #:shape-item-key
                #:shape-item-path
                #:shape-item-match
                #:shape-item-tier
                #:shape-item-group
                #:shape-item-apparatus-p)
  (:export #:shape-deviation
           #:deviation-item
           #:deviation-repo
           #:deviation-profile
           #:deviation-detail
           #:missing-shape-item
           #:drifted-shape-item
           #:foreign-apparatus-tracked
           #:deviation-repairable-p
           #:signal-deviation
           #:available-restarts
           #:call-with-deviation-policy
           #:with-deviation-policy
           #:policy-not-applicable-error
           #:policy-not-applicable-deviation
           #:policy-not-applicable-policy
           #:policy-not-applicable-reason
           #:+policies+
           #:deviation-report-line))

(in-package #:dsmr-mcp/src/project-deviation)

;;; ---------------------------------------------------------------------------
;;; The deviation
;;; ---------------------------------------------------------------------------

(define-condition shape-deviation (error)
  ((item    :initarg :item    :reader deviation-item    :initform nil)
   (repo    :initarg :repo    :reader deviation-repo    :initform nil)
   (profile :initarg :profile :reader deviation-profile :initform nil)
   (detail  :initarg :detail  :reader deviation-detail  :initform nil))
  (:report (lambda (condition stream)
             (write-string (deviation-report-line condition) stream)))
  (:documentation
   "One way in which a repository differs from the declared shape.

Carries the SHAPE-ITEM the difference is about, the repository root it was found
in, the profile that repository was assessed under, and a free-text DETAIL
holding the diagnosis.

DETAIL is never the identity of the finding. The class says what kind of
difference this is and the item says which part of the shape it concerns; a
caller deciding what to do reads those and never the words. A design that put the
finding in a string would leave every consumer parsing prose to recover what the
signaller already knew."))

(define-condition missing-shape-item (shape-deviation)
  ()
  (:report (lambda (condition stream)
             (format stream "~A is absent~@[ from ~A~]~@[: ~A~]"
                     (%item-name condition)
                     (deviation-repo condition)
                     (deviation-detail condition))))
  (:documentation
   "Signalled when an item's assertion is unsatisfied in a repository whose
profile expects that item to be present.

Absent under a profile that does not expect the item is not a deviation at all
and must not be signalled: a repository legitimately without a convenience file
is not sick, and reporting it as such buries the findings that are real."))

(define-condition drifted-shape-item (shape-deviation)
  ()
  (:report (lambda (condition stream)
             (format stream "~A does not match the definition~@[ in ~A~]~@[: ~A~]"
                     (%item-name condition)
                     (deviation-repo condition)
                     (deviation-detail condition))))
  (:documentation
   "Signalled when an item is present but does not match its definition.

A local ignore file that has fallen behind the pattern set of record reports
through here: the file exists, so nothing is missing, and it is still wrong."))

(define-condition foreign-apparatus-tracked (shape-deviation)
  ()
  (:report (lambda (condition stream)
             (format stream "~A is tracked in ~A, which is not ours~@[: ~A~]"
                     (%item-name condition)
                     (or (deviation-repo condition) "a foreign repository")
                     (deviation-detail condition))))
  (:documentation
   "Signalled when our operational apparatus is TRACKED in a repository we do not
own.

This is the violation the whole two-mode shape exists to prevent, and it is the
one deviation that must never be fixed without a person deciding to. Removing a
file from somebody else's index is a change to their tracked tree, so the
recovery that looks obvious is itself the thing forbidden. REPAIR is therefore
not offered for this class at all."))

(define-condition policy-not-applicable-error (error)
  ((deviation :initarg :deviation :reader policy-not-applicable-deviation
              :initform nil)
   (policy    :initarg :policy    :reader policy-not-applicable-policy
              :initform nil)
   (reason    :initarg :reason    :reader policy-not-applicable-reason
              :initform nil))
  (:report (lambda (condition stream)
             (format stream "Policy ~S cannot be applied~@[ (~A)~]~@[: ~A~]"
                     (policy-not-applicable-policy condition)
                     (let ((deviation (policy-not-applicable-deviation condition)))
                       (and deviation (deviation-report-line deviation)))
                     (policy-not-applicable-reason condition))))
  (:documentation
   "Signalled when a policy names a recovery that is not on offer.

There is deliberately no fallback to a second choice. A policy that silently
became a different policy would fail in the unsafe direction, and it would fail
invisibly: the report would name an outcome that was never the one asked for, and
nothing downstream could tell that apart from the outcome being correct."))

;;; ---------------------------------------------------------------------------
;;; Rendering
;;; ---------------------------------------------------------------------------

(defun %item-name (deviation)
  "Return a short label naming the item DEVIATION is about, for a report.

Falls back to the item's match pattern when it has no path, which is how an item
found by glob rather than by name is still named in a report."
  (let ((item (deviation-item deviation)))
    (if item
        (format nil "~S (~A)"
                (shape-item-key item)
                (or (shape-item-path item) (shape-item-match item)))
        "an unnamed item")))

(defun deviation-report-line (deviation)
  "Return a one-line summary of DEVIATION naming its kind, its item key and its
path.

Written for a person to read in a list of findings. It is a rendering of the
deviation and never its identity: anything choosing what to do about a deviation
dispatches on the class, and this line exists so the choice can be explained
afterwards."
  (let ((item (deviation-item deviation)))
    (format nil "~(~A~) ~S ~A~@[: ~A~]"
            (class-name (class-of deviation))
            (if item (shape-item-key item) :unknown-item)
            (if item
                (or (shape-item-path item) (shape-item-match item))
                "(no path)")
            (deviation-detail deviation))))

;;; ---------------------------------------------------------------------------
;;; Which recoveries a deviation admits
;;; ---------------------------------------------------------------------------

(defgeneric deviation-repairable-p (deviation)
  (:documentation
   "Return true when bringing the repository up to the definition is a recovery
this deviation may be offered.

There is deliberately NO method on SHAPE-DEVIATION itself. A subclass added later
without a method here fails loudly at the first deviation of that kind rather
than inheriting an answer nobody chose. Inheriting T would offer repair for a
case never considered, and inheriting NIL would silently withhold it; both are
answers arrived at by omission, which is the shape of decision this module exists
to remove."))

(defmethod deviation-repairable-p ((deviation missing-shape-item))
  "A file the shape says should exist and does not can be written."
  t)

(defmethod deviation-repairable-p ((deviation drifted-shape-item))
  "A file that exists and does not match the definition can be brought to it."
  t)

(defmethod deviation-repairable-p ((deviation foreign-apparatus-tracked))
  "Never repairable. Untracking a file in a repository we do not own edits
somebody else's tracked tree, which is the same act, in the other direction, as
the leak this condition reports."
  nil)

;;; ---------------------------------------------------------------------------
;;; Policies
;;; ---------------------------------------------------------------------------

(defvar *policy-restarts*
  '((:repair . repair)
    (:record-as-debt . record-as-debt)
    (:accept-as-deliberate . accept-as-deliberate))
  "Each policy keyword a caller may name, paired with the restart it selects.

One table, so the set of policies and the set of restarts cannot drift apart. A
caller across a process boundary can only ever hand us a keyword, and this is
where a keyword becomes a recovery.")

(defvar +policies+
  (mapcar #'car *policy-restarts*)
  "Every policy keyword CALL-WITH-DEVIATION-POLICY accepts.

Derived from *POLICY-RESTARTS* rather than written out again, so a policy that
exists here always has a restart to select. Named as a constant but defined with
DEFVAR on purpose: DEFCONSTANT on a list re-evaluates to a fresh, non-EQL list on
reload and breaks a warm image.")

(defun %restart-for-policy (policy)
  "Return the restart name POLICY selects, or NIL when POLICY is not a policy."
  (cdr (assoc policy *policy-restarts*)))

(defun %policy-applicable-p (policy deviation)
  "Return true when the restart POLICY names would be established for DEVIATION.

Derived from DEVIATION-REPAIRABLE-P, the same predicate the REPAIR restart's own
test consults, so the answer given here and the answer FIND-RESTART gives cannot
disagree."
  (if (eq policy :repair)
      (and (deviation-repairable-p deviation) t)
      t))

(defun available-restarts (deviation)
  "Return the policy keywords SIGNAL-DEVIATION would offer for DEVIATION.

Computed without signalling anything, so a caller can be told what it may choose
before it chooses. This is the half of the design that crosses a process
boundary: the names travel as data, and the restarts they name do not."
  (remove-if-not (lambda (policy) (%policy-applicable-p policy deviation))
                 +policies+))

;;; ---------------------------------------------------------------------------
;;; Signalling, and choosing
;;; ---------------------------------------------------------------------------

(defun signal-deviation (deviation)
  "Signal DEVIATION and return the keyword naming the decision taken about it.

Three recoveries are established. REPAIR is established only when the deviation
is repairable: its test consults DEVIATION-REPAIRABLE-P, which FIND-RESTART
honours, so on a deviation that must never be auto-repaired the restart is not
merely undocumented, it cannot be found. RECORD-AS-DEBT and ACCEPT-AS-DELIBERATE
are always available, because examining a site and freezing it, or judging it
correct as written, are decisions that can be taken about any difference at all.

With no handler established the deviation propagates to the caller. That is the
correct outcome and not a gap: an unattended run must not decide on its own what
to do to a repository.

Each restart returns its keyword and performs no I/O whatsoever. The effectful
work belongs to the engine that interprets the returned keyword, which is what
keeps the decision and the act separable and this module testable against no
filesystem at all."
  (restart-case (error deviation)
    (repair ()
      :test (lambda (condition)
              (declare (ignore condition))
              (deviation-repairable-p deviation))
      :report "Bring the repository up to the definition."
      :repaired)
    (record-as-debt ()
      :report "Freeze this site as baseline debt with its diagnosis."
      :recorded-as-debt)
    (accept-as-deliberate ()
      :report "This deviation is correct as written."
      :accepted)))

(defun call-with-deviation-policy (thunk &key policy)
  "Call THUNK with POLICY deciding every SHAPE-DEVIATION signalled inside it.

POLICY must be one of +POLICIES+. It is checked before THUNK runs, so an unknown
keyword is refused whether or not any deviation is ever signalled, rather than
lying in wait until one is.

When POLICY is NIL no handler is established at all and deviations propagate to
the caller unchanged. That is the whole of the no-policy behaviour: there is no
outcome chosen, because nobody chose one.

HANDLER-BIND rather than HANDLER-CASE, because the deviation is observed rather
than replaced. The handler runs before the stack unwinds, so a backtrace taken
there names the frame that actually found the difference instead of this one.

When the restart POLICY names is not established for the deviation in hand,
POLICY-NOT-APPLICABLE-ERROR is signalled. There is no branch that picks a
different restart instead. Quietly downgrading a refused repair to an acceptance
would report a repository as deliberately different when nobody said so, and the
report would be indistinguishable from the truthful one."
  (when (and policy (not (member policy +policies+)))
    (error 'policy-not-applicable-error
           :policy policy
           :reason "not one of the policies this doctor knows"))
  (if (null policy)
      (funcall thunk)
      (handler-bind
          ((shape-deviation
             (lambda (deviation)
               (let ((restart (find-restart (%restart-for-policy policy)
                                            deviation)))
                 (unless restart
                   (error 'policy-not-applicable-error
                          :deviation deviation
                          :policy policy
                          :reason
                          "that recovery is not offered for this deviation"))
                 (invoke-restart restart)))))
        (funcall thunk))))

(defmacro with-deviation-policy ((&key policy) &body body)
  "Evaluate BODY with POLICY deciding every SHAPE-DEVIATION signalled inside it.

See CALL-WITH-DEVIATION-POLICY, which this expands into and which carries the
contract."
  `(call-with-deviation-policy (lambda () ,@body) :policy ,policy))
