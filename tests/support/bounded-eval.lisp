;;;; tests/support/bounded-eval.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Bounded remote eval for the test suite.
;;;;
;;;; slynk-client:slime-eval waits for its reply unconditionally, so a reply the
;;;; remote never delivers blocks the caller forever.  A test that blocks that
;;;; way is the worst possible CI failure: no assertion fails, the job is killed
;;;; when the wall-clock ceiling expires, and every test after the blocked one
;;;; goes unreported.  The evidence looks like an infrastructure flake rather
;;;; than the lost reply it actually is.
;;;;
;;;; src/attach/connection.lisp already solves this for production callers with
;;;; bounded-slime-eval: dispatch with slime-eval-async, wait on a private
;;;; condition variable with a deadline, and turn a lost reply into a clean
;;;; slynk-client:slime-network-error.  This module is the test suite's face of
;;;; that call.  It adds the two things a test needs on top of the bound: one
;;;; adjustable value for the whole suite, and a condition report that names
;;;; which eval went unanswered, so the CI log alone identifies the site.
;;;;
;;;; Two constraints carried over verbatim from bounded-slime-eval, both of
;;;; which callers here must respect:
;;;;
;;;;   1. The bound is safe only for idempotent forms.  A round trip whose
;;;;      remote effect must not be repeated may still be in flight when the
;;;;      deadline fires, so it must not be reissued on the same connection.
;;;;      Every call site in the suite is a probe (arithmetic, find-package) or
;;;;      a definition guarded by an existence check, so reissuing is harmless.
;;;;
;;;;   2. The wait is a timed condition-wait, never sb-ext:with-timeout.  A
;;;;      SIGALRM unwind does not compose with the locked condition-wait inside
;;;;      the rex round trip.

(defpackage #:dsmr-mcp/tests/support/bounded-eval
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/attach/connection
                #:bounded-slime-eval)
  (:import-from #:slynk-client
                #:slime-network-error)
  (:export #:*eval-timeout-seconds*
           #:remote-eval-unanswered
           #:remote-eval-unanswered-label
           #:remote-eval-unanswered-form
           #:remote-eval-unanswered-seconds
           #:eval-in-image))

(in-package #:dsmr-mcp/tests/support/bounded-eval)

;;; The suite-wide bound ------------------------------------------------------
;;;
;;; Every remote eval the suite performs is either against the in-process Slynk
;;; fixture or against a freshly spawned local child, and both answer a probe in
;;; milliseconds once the connection is up.  20 seconds is therefore orders of
;;; magnitude above any healthy round trip, so a slow machine never trips it,
;;; while still leaving the whole suite far inside its CI wall-clock ceiling:
;;; even in the pathological case where every bounded site in both suites goes
;;; unanswered in a single run, the accumulated wait is a handful of minutes and
;;; the job still reports real results instead of being killed.
;;;
;;; Rebind or setf this one place to retune the suite.

(defparameter *eval-timeout-seconds* 20
  "Seconds a single remote eval in the test suite may wait for its reply.
Deliberately far above any healthy round trip against the in-process Slynk
fixture or a spawned local child, and far below the wall-clock ceiling the CI
job runs under, so a lost reply becomes a reported failure rather than a
killed job.")

;;; The diagnosable failure ---------------------------------------------------

(define-condition remote-eval-unanswered (error)
  ((label   :initarg :label   :initform nil :reader remote-eval-unanswered-label)
   (form    :initarg :form    :initform nil :reader remote-eval-unanswered-form)
   (seconds :initarg :seconds :initform nil :reader remote-eval-unanswered-seconds))
  (:report
   (lambda (condition stream)
     ;; The form is printed flat and bounded: a CI log line that wraps a large
     ;; quoted form across dozens of pretty-printed lines buries the label that
     ;; identifies the site, which is the whole point of the report.
     (let ((*print-pretty* nil)
           (*print-length* 20)
           (*print-level*  4))
       (format stream
               "Remote eval~@[ ~A~] received no reply within ~A second~:P. ~
The remote never answered, or the connection dropped. Form: ~S"
               (remote-eval-unanswered-label condition)
               (remote-eval-unanswered-seconds condition)
               (remote-eval-unanswered-form condition)))))
  (:documentation
   "Signalled when a test's remote eval passes its deadline with no reply.
Carries the caller's LABEL and the FORM so the report names the exact eval
that went unanswered, which a bare network error does not."))

;;; The wrapper ---------------------------------------------------------------

(defun eval-in-image (form conn &key label (timeout *eval-timeout-seconds*))
  "Evaluate FORM on the Slynk connection CONN, waiting at most TIMEOUT seconds.

Returns the remote result.  When no reply arrives in time, signals
remote-eval-unanswered whose report names LABEL and prints FORM, rather than
blocking until the CI job is killed.

LABEL is a short string identifying the call site; several sites in the suite
evaluate the same trivial probe form, so the form alone does not distinguish
them.  Pass one at every site.

FORM must be idempotent: see the file header."
  (handler-case (bounded-slime-eval form conn :timeout timeout)
    (slime-network-error ()
      (error 'remote-eval-unanswered
             :label label
             :form form
             :seconds timeout))))
