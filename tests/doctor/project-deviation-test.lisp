;;;; tests/doctor/project-deviation-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Parachute tests for the deviation vocabulary: the three recoveries, the one
;;;; that is withheld, and the absence of any recovery when nobody asked for one.
;;;;
;;;; Two of the three things under test here are negative, and a negative claim
;;;; is exactly the kind that passes when the instrument is aimed at nothing. So
;;;; each is watched from more than one side.
;;;;
;;;; The recovery that must be withheld is observed three ways: the restart
;;;; cannot be found, the policy layer refuses rather than substituting, and the
;;;; advertised list of choices omits it. Those three read alike and they measure
;;;; different things. The first measures the restart's own test, the second
;;;; measures the policy layer, and the third measures a computation that never
;;;; signals at all. Breaking any one of the three leaves the other two green,
;;;; which is the whole reason all three are here.
;;;;
;;;; The absence of an outcome is observed by asserting that the deviation
;;;; escapes. An implementation that quietly settled on accept-as-deliberate when
;;;; handed no policy would look identical in every other test in this file, and
;;;; would report repositories as deliberately different when nobody said so.
;;;;
;;;; Nothing here touches a filesystem or a repository. The deviations are built
;;;; directly and the shape items are synthetic, which is possible only because
;;;; the recoveries decide without acting.

;; Package evolution guard - delete prior definition on warm reload.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/doctor/project-deviation-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/doctor/project-deviation-test
  (:use #:cl #:parachute)
  (:import-from #:dsmr-mcp/src/project-shape
                #:make-shape-item)
  (:import-from #:dsmr-mcp/src/project-deviation
                #:shape-deviation
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
                #:policy-not-applicable-policy
                #:+policies+
                #:deviation-report-line))

(in-package #:dsmr-mcp/tests/doctor/project-deviation-test)

;;; ---------------------------------------------------------------------------
;;; Fixtures, built in memory
;;; ---------------------------------------------------------------------------

(defun %item ()
  "Return a synthetic shape item for a deviation to be about.

Its content is irrelevant to everything measured here. What matters is that a
deviation carries an item at all, so a report can name which part of the shape it
concerns."
  (make-shape-item :key :envrc
                   :path ".envrc"
                   :tier :convenience
                   :assertion :file-exists
                   :match ".envrc"))

(defun %repairable ()
  "Return a deviation whose recovery is a file we may write."
  (make-condition 'missing-shape-item
                  :item (%item)
                  :repo #P"/nowhere/ours/"
                  :profile :ours
                  :detail "nothing at that path"))

(defun %drifted ()
  "Return a deviation whose recovery is a file we may bring to the definition."
  (make-condition 'drifted-shape-item
                  :item (%item)
                  :repo #P"/nowhere/ours/"
                  :profile :ours
                  :detail "present and not what the definition says"))

(defun %unrepairable ()
  "Return the deviation the doctor must never fix on its own.

Our apparatus tracked in a repository we do not own. Untracking it edits somebody
else's tracked tree, which is the same forbidden act as adding to it."
  (make-condition 'foreign-apparatus-tracked
                  :item (%item)
                  :repo #P"/nowhere/theirs/"
                  :profile :foreign
                  :detail "the index carries it"))

(defun %decide (deviation policy)
  "Signal DEVIATION under POLICY and return the outcome keyword."
  (call-with-deviation-policy (lambda () (signal-deviation deviation))
                              :policy policy))

;;; ---------------------------------------------------------------------------
;;; The three recoveries
;;; ---------------------------------------------------------------------------

(define-test each-policy-returns-its-own-outcome
  "DISTINCTNESS CONTROL.

The three policies are asserted to produce three keywords AND to produce three
DIFFERENT keywords, in one test. Asserting only the individual values would be
satisfied by three separate constants; asserting only distinctness would be
satisfied by any three values at all. A decision layer that answered one constant
regardless of the policy handed to it, which is the plausible way for this to be
wrong, fails the second assertion and would pass a test that made each assertion
on its own."
  (let ((outcomes (mapcar (lambda (policy) (%decide (%repairable) policy))
                          '(:repair :record-as-debt :accept-as-deliberate))))
    (is equal '(:repaired :recorded-as-debt :accepted) outcomes)
    (is = 3 (length (remove-duplicates outcomes)))))

(define-test the-macro-and-the-function-agree
  "WITH-DEVIATION-POLICY is the wrapper and must decide the same way the function
does. A macro that dropped its policy argument would leave the deviation
unhandled, which is a different bug from deciding wrongly."
  (is eql :recorded-as-debt
      (with-deviation-policy (:policy :record-as-debt)
        (signal-deviation (%repairable))))
  (is eql :accepted
      (with-deviation-policy (:policy :accept-as-deliberate)
        (signal-deviation (%drifted)))))

;;; ---------------------------------------------------------------------------
;;; The recovery that is withheld
;;; ---------------------------------------------------------------------------

(define-test a-forbidden-repair-is-not-on-offer
  "UNAVAILABILITY CONTROL.

Three independent observations of one guarantee, because each covers a different
mechanism and the other two stay green when one breaks.

First, the restart itself: inside a handler for the deviation, FIND-RESTART for
repair answers NIL. That measures the restart's own test and nothing else.

Second, the policy layer: naming that recovery signals rather than substituting a
different one. This is the observation that would still pass if the policy layer
were merely broken in some other way, which is why it is not the only one.

Third, the advertised choices: the list a caller is offered omits it. That is
computed without signalling anything, so it holds even where no deviation is in
flight, and it is what a caller on the far side of a process boundary actually
reads."
  (let ((deviation (%unrepairable))
        (found :unset))
    (call-with-deviation-policy
     (lambda ()
       (handler-bind ((shape-deviation
                        (lambda (condition)
                          (setf found
                                (find-restart
                                 'dsmr-mcp/src/project-deviation::repair
                                 condition)))))
         (signal-deviation deviation)))
     :policy :record-as-debt)
    (is eql nil found))
  (fail (%decide (%unrepairable) :repair) 'policy-not-applicable-error)
  (false (member :repair (available-restarts (%unrepairable)))))

(define-test a-refused-repair-is-not-quietly-downgraded
  "The deviation that may not be repaired is still handled by the other two
recoveries. Refusing one recovery must not make the deviation unmanageable, or a
caller would have no way to record the leak it just found."
  (is eql :recorded-as-debt (%decide (%unrepairable) :record-as-debt))
  (is eql :accepted (%decide (%unrepairable) :accept-as-deliberate)))

(define-test the-refusal-names-the-policy-that-was-asked-for
  "A refusal a caller cannot attribute is barely better than a silent one. The
condition carries the policy that was requested."
  (let ((condition (handler-case (%decide (%unrepairable) :repair)
                     (policy-not-applicable-error (c) c))))
    (of-type policy-not-applicable-error condition)
    (is eql :repair (policy-not-applicable-policy condition))))

;;; ---------------------------------------------------------------------------
;;; No policy, no outcome
;;; ---------------------------------------------------------------------------

(define-test no-policy-produces-no-outcome
  "NO-DEFAULT CONTROL.

With no policy the deviation escapes to the caller. An implementation that
quietly settled on accept-as-deliberate would look identical in every other test
in this file, and would report repositories as deliberately different when nobody
said so. Both the bare signal and the explicit nil policy are asserted, because a
default could be introduced in either place."
  (fail (signal-deviation (%repairable)) 'shape-deviation)
  (fail (call-with-deviation-policy (lambda () (signal-deviation (%repairable)))
                                    :policy nil)
        'shape-deviation)
  (fail (with-deviation-policy (:policy nil) (signal-deviation (%unrepairable)))
        'foreign-apparatus-tracked))

(define-test an-unknown-policy-signals
  "A policy keyword nobody defined is refused rather than ignored. Ignoring it
would leave the deviation to escape, which reads exactly like the no-policy case
and would hide a caller sending the wrong word."
  (fail (%decide (%repairable) :fix-it-somehow) 'policy-not-applicable-error)
  (fail (call-with-deviation-policy (lambda () :never-reached)
                                    :policy :fix-it-somehow)
        'policy-not-applicable-error))

;;; ---------------------------------------------------------------------------
;;; What a caller is told it may choose
;;; ---------------------------------------------------------------------------

(define-test the-offered-choices-follow-repairability
  "AVAILABLE-RESTARTS is the half of this vocabulary that crosses a process
boundary, so it is asserted against both kinds of deviation and against the
declared set of policies. A version answering a fixed list would satisfy either
half alone."
  (is equal '(:repair :record-as-debt :accept-as-deliberate)
      (available-restarts (%repairable)))
  (is equal '(:record-as-debt :accept-as-deliberate)
      (available-restarts (%unrepairable)))
  (true (member :repair (available-restarts (%drifted))))
  (dolist (deviation (list (%repairable) (%drifted) (%unrepairable)))
    (true (subsetp (available-restarts deviation) +policies+))))

(define-test repairability-is-a-property-of-the-kind
  "The two writable kinds are repairable and the leak is not. Asserted directly
as well as through the restarts, so a break in the restart machinery and a break
in the classification are told apart."
  (true (deviation-repairable-p (%repairable)))
  (true (deviation-repairable-p (%drifted)))
  (false (deviation-repairable-p (%unrepairable))))

;;; ---------------------------------------------------------------------------
;;; Rendering
;;; ---------------------------------------------------------------------------

(define-test the-report-line-names-the-kind-the-key-and-the-path
  "The one-line summary carries all three, so a list of findings can be read
without opening anything. It is a rendering and never the identity of the
finding, which is why the class is asserted separately above rather than parsed
back out of this string."
  (let ((line (deviation-report-line (%unrepairable))))
    (true (search "foreign-apparatus-tracked" line))
    (true (search "ENVRC" line))
    (true (search ".envrc" line)))
  (let ((line (deviation-report-line (%repairable))))
    (true (search "missing-shape-item" line))
    (false (search "foreign-apparatus-tracked" line))))

(define-test a-deviation-carries-what-it-was-built-with
  "The slots a report and a repair both read back are the ones that were set. A
deviation losing its repository would produce findings nobody could act on."
  (let ((deviation (%unrepairable)))
    (is equal #P"/nowhere/theirs/" (deviation-repo deviation))
    (is eql :foreign (deviation-profile deviation))
    (is equal "the index carries it" (deviation-detail deviation))
    (true (deviation-item deviation))))
