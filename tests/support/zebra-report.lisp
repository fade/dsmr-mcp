;;;; tests/support/zebra-report.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; A Zebra report class that reads the raw result vector and makes the
;;;; counts available as DATA before it makes them available as text.
;;;;
;;;; The problem it solves: a summary line that renders counts to prose and
;;;; keeps nothing means every consumer has to reconstruct the numbers by
;;;; parsing the prose, and a number that was never separable in the first
;;;; place cannot be recovered at all. Here one walk produces a structure and
;;;; the printed report is a projection of that structure. A caller that
;;;; wants the numbers parses nothing, and the text cannot drift away from
;;;; the data because there is only one computation.
;;;;
;;;; Two counting rules live in this file and they DISAGREE ON PURPOSE.
;;;; Making them agree would destroy the reason the file exists:
;;;;
;;;;   The compatibility rule counts every result on the line for its
;;;;   status, except a TEST-RESULT whose status a direct child already
;;;;   carries, quirks included, because that is what zebra does and the
;;;;   point of the line is that a reader sees the number zebra prints.
;;;;
;;;;   The axes rule drops every PARENT-RESULT, because a group or a control
;;;;   object is not a check and counting it as one inflates the leaf counts.
;;;;
;;;; Neither rule calls zebra's own helpers. The compatibility numbers are
;;;; derived here, by this file's own walk of the raw vector, so that comparing
;;;; them against what zebra's reporter PRINTS compares two independent
;;;; computations rather than one function to itself.
;;;;
;;;; Nothing in a zebra result records why a test failed. Every count in
;;;; this file is therefore a property of the recorded data and never a claim
;;;; about a cause.

(defpackage #:dsmr-mcp/tests/support/zebra-report
  (:use #:cl)
  (:local-nicknames (#:pa #:zebra))
  (:export #:axis-summary
           #:*controls-are-not-checks*
           #:*skips-are-not-passes*
           #:controls-are-not-checks-p
           #:skips-are-not-passes-p
           #:tally
           #:axes-of
           #:triple
           #:print-axes
           #:axes
           #:axes-p
           #:axes-leaf-passed
           #:axes-leaf-failed
           #:axes-leaf-skipped
           #:axes-test-passed-carried
           #:axes-test-passed-uncarried
           #:axes-test-failed-carried
           #:axes-test-failed-uncarried
           #:axes-test-skipped
           #:axes-control-passed
           #:axes-control-failed
           #:axes-control-skipped
           #:axes-non-terminal
           #:axes-total
           #:axes-passed
           #:axes-failed
           #:axes-skipped
           #:axes-upstream-passed
           #:axes-upstream-failed
           #:axes-upstream-skipped
           #:axes-active-deviations
           #:axes-declared-limits
           #:limit-observation
           #:limit-observation-p
           #:limit-label
           #:limit-status
           #:limit-declared
           #:limit-duration))

(in-package #:dsmr-mcp/tests/support/zebra-report)

;;; ------------------------------------------------------------------
;;; Selectable semantics
;;;
;;; Each deviation is named for what it does and is set independently, so a
;;; caller can adopt one without adopting the other and so each is greppable
;;; on its own name. Both default to NIL, and with both off the triple this
;;; reporter returns and prints is zebra's own.

(defvar *controls-are-not-checks* nil
  "When true, group and control results are excluded from the passed and
failed counts, leaving only genuine leaf checks. Zebra excludes only a test
whose status a child carries, so a GROUP or a WITH-FORCED-STATUS form is
counted as though it were an assertion. A test that nothing beneath accounts
for stays counted under either setting.")

(defvar *skips-are-not-passes* nil
  "When true, a result that passed while every result beneath it was skipped
is not counted as a pass. Standing a body down leaves the enclosing group or
test marked passed, so a wholly skipped body is otherwise indistinguishable
from work that ran and succeeded.")

;;; ------------------------------------------------------------------
;;; The data

(defstruct (limit-observation (:conc-name limit-) (:copier nil))
  "The two numbers a time-limited test leaves behind, recorded as the run
left them.

Both are reported raw and uncompared. Comparing them is a judgement about a
cause, the run records no cause, and a comparison made here would replace
two numbers a caller can disagree with by one boolean they cannot."
  (label "" :type string)
  (status :unknown)
  (declared nil)
  (duration nil))

(defstruct (axes (:copier nil))
  "Counts taken from one report's raw result vector.

The partition slots are facts about the vector and do not depend on any
selected semantics: LEAF-PASSED through NON-TERMINAL each count one kind of
object, no object falls in two of them, and together they sum to TOTAL.

PASSED, FAILED and SKIPPED are the policy view, computed under whichever
deviations were active. UPSTREAM-PASSED, UPSTREAM-FAILED and
UPSTREAM-SKIPPED are always zebra's own numbers, whatever the policy,
so the two can be compared without running anything twice."
  ;; Partition: leaf results, i.e. anything that is not a parent-result.
  (leaf-passed 0 :type unsigned-byte)
  (leaf-failed 0 :type unsigned-byte)
  (leaf-skipped 0 :type unsigned-byte)
  ;; Partition: test results.
  (test-passed-carried 0 :type unsigned-byte)
  (test-passed-uncarried 0 :type unsigned-byte)
  (test-failed-carried 0 :type unsigned-byte)
  (test-failed-uncarried 0 :type unsigned-byte)
  (test-skipped 0 :type unsigned-byte)
  ;; Partition: parent results that are not tests, i.e. groups and controls.
  (control-passed 0 :type unsigned-byte)
  (control-failed 0 :type unsigned-byte)
  (control-skipped 0 :type unsigned-byte)
  ;; Partition: anything still in :unknown or :tentative when the run ended.
  (non-terminal 0 :type unsigned-byte)
  (total 0 :type unsigned-byte)
  ;; Policy view.
  (passed 0 :type unsigned-byte)
  (failed 0 :type unsigned-byte)
  (skipped 0 :type unsigned-byte)
  ;; Zebra's own view, always.
  (upstream-passed 0 :type unsigned-byte)
  (upstream-failed 0 :type unsigned-byte)
  (upstream-skipped 0 :type unsigned-byte)
  (active-deviations '() :type list)
  ;; Raw numbers for every test that declared a limit. Not a count.
  (declared-limits '() :type list))

;;; ------------------------------------------------------------------
;;; Mechanical predicates. Neither asks why anything happened.

(defun status-carried-by-a-child-p (result)
  "True when some direct child of RESULT has the same status RESULT does."
  (loop for child across (pa:results result)
        thereis (eql (pa:status result) (pa:status child))))

(defun wholly-skipped-body-p (result)
  "True when RESULT has children and every one of them was skipped."
  (let ((children (pa:results result)))
    (and (plusp (length children))
         (loop for child across children
               always (eql :skipped (pa:status child))))))

(defun declared-limit-of (result)
  "The time limit RESULT's test declared, or NIL if it declared none."
  (let ((expression (pa:expression result)))
    (and (typep expression 'pa:test) (pa:time-limit expression))))

;;; ------------------------------------------------------------------
;;; The walk

(defun tally (report &key
                       ((:controls-are-not-checks controls)
                        *controls-are-not-checks*)
                       ((:skips-are-not-passes skips) *skips-are-not-passes*))
  "Walk REPORT's raw result vector once and return an AXES structure.

Works on any zebra report, not only on AXIS-SUMMARY, so a caller holding
an ordinary PLAIN report can still obtain the numbers as data."
  (let ((axes (make-axes
               :active-deviations
               (append (when controls '(:controls-are-not-checks))
                       (when skips '(:skips-are-not-passes))))))
    (loop for result across (pa:results report)
          for status = (pa:status result)
          for testp = (typep result 'pa:test-result)
          for parentp = (typep result 'pa:parent-result)
          ;; Zebra's own rule, derived here rather than borrowed: every
          ;; result counts on the line for its status, except a test result
          ;; whose status a direct child already carries. One rule for all
          ;; three lines. It filters TEST-RESULT and nothing else, which is
          ;; not what the axes rule does, and that difference is the reason
          ;; both exist. Do not reconcile them.
          for zebra-counts-p = (not (and testp
                                         (status-carried-by-a-child-p result)))
          for controlp = (and parentp (not testp))
          do (incf (axes-total axes))

             ;; The partition. Facts, not policy.
             (cond ((not (member status '(:passed :failed :skipped)))
                    (incf (axes-non-terminal axes)))
                   (testp
                    (ecase status
                      (:passed (if (status-carried-by-a-child-p result)
                                   (incf (axes-test-passed-carried axes))
                                   (incf (axes-test-passed-uncarried axes))))
                      (:failed (if (status-carried-by-a-child-p result)
                                   (incf (axes-test-failed-carried axes))
                                   (incf (axes-test-failed-uncarried axes))))
                      (:skipped (incf (axes-test-skipped axes)))))
                   (parentp
                    (ecase status
                      (:passed (incf (axes-control-passed axes)))
                      (:failed (incf (axes-control-failed axes)))
                      (:skipped (incf (axes-control-skipped axes)))))
                   (t
                    (ecase status
                      (:passed (incf (axes-leaf-passed axes)))
                      (:failed (incf (axes-leaf-failed axes)))
                      (:skipped (incf (axes-leaf-skipped axes))))))

             ;; Raw numbers for anything that declared a limit, so a caller
             ;; who wants the time-limit subset can draw their own line.
             (let ((declared (and testp (declared-limit-of result))))
               (when declared
                 (push (make-limit-observation
                        :label (or (ignore-errors
                                    (pa:format-result result :oneline))
                                   "")
                        :status status
                        :declared declared
                        :duration (pa:duration result))
                       (axes-declared-limits axes))))

             ;; Zebra's own triple.
             (when zebra-counts-p
               (case status
                 (:passed (incf (axes-upstream-passed axes)))
                 (:failed (incf (axes-upstream-failed axes)))
                 (:skipped (incf (axes-upstream-skipped axes)))))

             ;; The policy triple: zebra's triple, less what each selected
             ;; deviation excludes. No deviation touches skipped.
             (when zebra-counts-p
               (case status
                 (:passed (unless (or (and controls controlp)
                                      (and skips
                                           parentp
                                           (wholly-skipped-body-p result)))
                            (incf (axes-passed axes))))
                 (:failed (unless (and controls controlp)
                            (incf (axes-failed axes))))
                 (:skipped (incf (axes-skipped axes))))))
    (setf (axes-declared-limits axes) (nreverse (axes-declared-limits axes)))
    axes))

;;; ------------------------------------------------------------------
;;; The report class

(defclass axis-summary (pa:plain)
  ((controls-are-not-checks
    :initarg :controls-are-not-checks
    :reader controls-are-not-checks-p)
   (skips-are-not-passes
    :initarg :skips-are-not-passes
    :reader skips-are-not-passes-p)
   (axes :initform nil :accessor axes-of))
  (:default-initargs
   :controls-are-not-checks *controls-are-not-checks*
   :skips-are-not-passes *skips-are-not-passes*)
  (:documentation
   "Zebra report that keeps its counts as data and prints them second.

Adopting it changes nothing an existing gate relies on: with no options set
the Passed, Failed and Skipped line is zebra's own, so anyone switching
a gate to this class reads the same three numbers zebra prints, with the
unambiguous axes added beneath them.

Subclasses PLAIN deliberately. PLAIN and QUIET are where zebra contains
an error raised inside a test; a report subclassed straight off REPORT lets
such an error escape and take the rest of the run with it.

Nothing in a zebra result records why a test failed, so no count here
names a cause. The two deviations documented on *CONTROLS-ARE-NOT-CHECKS*
and *SKIPS-ARE-NOT-PASSES* are selected per instance or globally, and
govern both the printed triple and the triple returned in the AXES
structure. The axes themselves are unaffected by them; they are facts
about the run."))

(defun tally-for (report)
  (tally report
         :controls-are-not-checks (controls-are-not-checks-p report)
         :skips-are-not-passes (skips-are-not-passes-p report)))

(defmethod axes-of :around ((report axis-summary))
  (or (call-next-method) (setf (axes-of report) (tally-for report))))

(defun triple (report)
  "Return the passed, failed and skipped counts of REPORT as three values,
under whichever semantics REPORT selects."
  (let ((axes (axes-of report)))
    (values (axes-passed axes) (axes-failed axes) (axes-skipped axes))))

;;; ------------------------------------------------------------------
;;; Printing, which projects the structure and computes nothing of its own

(defparameter +partition-lines+
  '(("leaf checks passed" . axes-leaf-passed)
    ("leaf checks failed" . axes-leaf-failed)
    ("leaf checks skipped" . axes-leaf-skipped)
    ("tests passed, a child carries that status" . axes-test-passed-carried)
    ("tests passed, no child carries that status" . axes-test-passed-uncarried)
    ("tests failed, a child carries that status" . axes-test-failed-carried)
    ("tests failed, nothing beneath accounts for it" . axes-test-failed-uncarried)
    ("tests skipped" . axes-test-skipped)
    ("groups and controls passed" . axes-control-passed)
    ("groups and controls failed" . axes-control-failed)
    ("groups and controls skipped" . axes-control-skipped)
    ("results in a non-terminal status" . axes-non-terminal))
  "Label and reader for every line of the partition, in printing order.")

(defun partition-sum (axes)
  (loop for (nil . reader) in +partition-lines+
        sum (funcall reader axes)))

(defun print-axes (axes stream)
  "Write AXES to STREAM. Every number printed is read from AXES; nothing is
recomputed here, so the text moves whenever the structure does.

No count is divided by any other, so a run that recorded nothing prints the
same shape as any other run rather than signalling on a zero denominator."
  (format stream "~&~%;; Summary:~%~
                  Passed:  ~4d~%~
                  Failed:  ~4d~%~
                  Skipped: ~4d~%"
          (axes-passed axes) (axes-failed axes) (axes-skipped axes))
  (if (axes-active-deviations axes)
      (format stream ";; Counted under: ~{~(~a~)~^, ~}.~%~
                      ;; These are not zebra's own numbers; without them the~%~
                      ;; triple would read ~d / ~d / ~d.~%"
              (axes-active-deviations axes)
              (axes-upstream-passed axes)
              (axes-upstream-failed axes)
              (axes-upstream-skipped axes))
      (format stream ";; Counted exactly as zebra counts: every result except a~%~
                      ;; test whose status a direct child already carries.~%"))
  (format stream "~%;; Axes. Facts about the run, unaffected by the semantics~%~
                  ;; above. Each line counts one kind of object, no object is on~%~
                  ;; two lines, and the lines sum to the total.~%")
  (loop for (label . reader) in +partition-lines+
        do (format stream "  ~46a ~5d~%" label (funcall reader axes)))
  (format stream "  ~46a -----~%" "")
  (format stream "  ~46a ~5d~%" "total results recorded" (axes-total axes))
  (let ((sum (partition-sum axes)))
    (unless (= sum (axes-total axes))
      (format stream "  ~46a ~5d~%"
              "UNACCOUNTED, the lines above do not sum"
              (- (axes-total axes) sum))))
  (when (axes-declared-limits axes)
    (format stream "~%;; Tests that declared a time limit, as the run left them.~%~
                    ;; Nothing records why a test failed, so the two numbers are~%~
                    ;; reported uncompared and no verdict is drawn from them.~%")
    (dolist (observation (axes-declared-limits axes))
      (flet ((seconds (value)
               ;; Durations are kept as the exact rationals zebra
               ;; recorded; only this display rounds them.
               (if (realp value) (float value 1d0) value)))
        (format stream "  limit ~10@a   took ~10@a   ~9a ~a~%"
                (seconds (limit-declared observation))
                (seconds (limit-duration observation))
                (limit-status observation)
                (limit-label observation)))))
  ;; The two shapes that a bare zero triple cannot tell apart.
  (cond ((zerop (axes-total axes))
         (format stream "~%;; Nothing ran: the run recorded no result at all.~%"))
        ((zerop (+ (axes-leaf-passed axes)
                   (axes-leaf-failed axes)
                   (axes-leaf-skipped axes)))
         (format stream "~%;; ~d result~:p recorded and no leaf check among~%~
                         ;; them: nothing in this run reached an assertion.~%"
                 (axes-total axes))))
  axes)

(defun print-failures (report stream)
  "List the failures that would otherwise have to be inferred: every failing
leaf check, and every test that failed with nothing beneath it carrying the
failure. Failing parents whose child is already listed are left out, so one
failure appears once."
  (let ((interesting
          (loop for result across (pa:results report)
                when (and (eql :failed (pa:status result))
                          (or (not (typep result 'pa:parent-result))
                              (and (typep result 'pa:test-result)
                                   (not (status-carried-by-a-child-p result)))))
                  collect result)))
    (when interesting
      (format stream "~&~%;; Failures:~%")
      (dolist (result interesting)
        (format stream "~&~a~%~%" (pa:format-result result :extensive))))))

(defmethod pa:summarize ((report axis-summary))
  (let ((axes (axes-of report))
        (stream (pa:output report)))
    (print-axes axes stream)
    (print-failures report stream)
    (force-output stream))
  report)
