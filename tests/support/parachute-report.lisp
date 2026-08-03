;;;; tests/support/parachute-report.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; A Parachute report class that reads the raw result vector and makes the
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
;;;;   The compatibility rule drops exactly TEST-RESULT, quirks included,
;;;;   because that is what parachute does and the point of the line is that
;;;;   a reader sees the number they have always seen.
;;;;
;;;;   The axes rule drops every PARENT-RESULT, because a group or a control
;;;;   object is not a check and counting it as one inflates the leaf counts.
;;;;
;;;; Neither rule calls parachute's own helpers. The compatibility numbers are
;;;; derived here, by this file's own walk of the raw vector, so that comparing
;;;; them against what parachute's reporter PRINTS compares two independent
;;;; computations rather than one function to itself.
;;;;
;;;; Nothing in a parachute result records why a test failed. Every count in
;;;; this file is therefore a property of the recorded data and never a claim
;;;; about a cause.

(defpackage #:dsmr-mcp/tests/support/parachute-report
  (:use #:cl)
  (:local-nicknames (#:pa #:parachute))
  (:export #:axis-summary
           #:*controls-are-not-checks*
           #:*uncarried-test-failures-are-failures*
           #:*skips-are-not-passes*
           #:controls-are-not-checks-p
           #:uncarried-test-failures-are-failures-p
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

(in-package #:dsmr-mcp/tests/support/parachute-report)

;;; ------------------------------------------------------------------
;;; Selectable semantics
;;;
;;; Each deviation is named for what it does and is set independently, so a
;;; caller can adopt one without adopting the rest and so each is greppable
;;; on its own name. Every one defaults to NIL, and with all three off the
;;; triple this reporter returns and prints is parachute's own.

(defvar *controls-are-not-checks* nil
  "When true, group and control results are excluded from the passed and
failed counts, leaving only genuine leaf checks. Parachute excludes only
test results, so a GROUP or a WITH-FORCED-STATUS form is counted as though
it were an assertion.")

(defvar *uncarried-test-failures-are-failures* nil
  "When true, a test that failed while no result beneath it carries that
failure is counted as one failure. Parachute drops every test result from
the failed count, so a test that dies before reaching its first assertion
contributes nothing and the run reports zero failures.

The predicate is mechanical: it asks whether any child result carries the
test's own status. It cannot ask why the test failed, and does not try. A
test that ran out of its declared time is one instance of the condition it
does detect, reached without consulting any clock.")

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
UPSTREAM-SKIPPED are always parachute's own numbers, whatever the policy,
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
  ;; Parachute's own view, always.
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
                       ((:uncarried-test-failures-are-failures uncarried)
                        *uncarried-test-failures-are-failures*)
                       ((:skips-are-not-passes skips) *skips-are-not-passes*))
  "Walk REPORT's raw result vector once and return an AXES structure.

Works on any parachute report, not only on AXIS-SUMMARY, so a caller holding
an ordinary PLAIN report can still obtain the numbers as data."
  (let ((axes (make-axes
               :active-deviations
               (append (when controls '(:controls-are-not-checks))
                       (when uncarried '(:uncarried-test-failures-are-failures))
                       (when skips '(:skips-are-not-passes))))))
    (loop for result across (pa:results report)
          for status = (pa:status result)
          for testp = (typep result 'pa:test-result)
          for parentp = (typep result 'pa:parent-result)
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

             ;; Parachute's own triple, derived here rather than borrowed.
             ;; The rule below is upstream's whole rule: drop every test
             ;; result from passed and from failed, count skipped raw.
             ;; It filters TEST-RESULT and nothing else, which is not what
             ;; the axes rule does, and that difference is the reason both
             ;; exist. Do not reconcile them.
             (unless testp
               (case status
                 (:passed (incf (axes-upstream-passed axes)))
                 (:failed (incf (axes-upstream-failed axes)))))
             (when (eql status :skipped)
               (incf (axes-upstream-skipped axes)))

             ;; The policy triple. Same walk, one rule per deviation.
             (let ((excluded-from-checks (if controls parentp testp)))
               (unless excluded-from-checks
                 (case status
                   (:passed (unless (and skips
                                         parentp
                                         (wholly-skipped-body-p result))
                              (incf (axes-passed axes))))
                   (:failed (incf (axes-failed axes))))))
             (when (eql status :skipped)
               (incf (axes-skipped axes)))
             (when (and uncarried
                        testp
                        (eql status :failed)
                        (not (status-carried-by-a-child-p result)))
               (incf (axes-failed axes))))
    (setf (axes-declared-limits axes) (nreverse (axes-declared-limits axes)))
    axes))

;;; ------------------------------------------------------------------
;;; The report class

(defclass axis-summary (pa:plain)
  ((controls-are-not-checks
    :initarg :controls-are-not-checks
    :reader controls-are-not-checks-p)
   (uncarried-test-failures-are-failures
    :initarg :uncarried-test-failures-are-failures
    :reader uncarried-test-failures-are-failures-p)
   (skips-are-not-passes
    :initarg :skips-are-not-passes
    :reader skips-are-not-passes-p)
   (axes :initform nil :accessor axes-of))
  (:default-initargs
   :controls-are-not-checks *controls-are-not-checks*
   :uncarried-test-failures-are-failures *uncarried-test-failures-are-failures*
   :skips-are-not-passes *skips-are-not-passes*)
  (:documentation
   "Parachute report that keeps its counts as data and prints them second.

Adopting it changes nothing an existing gate relies on: with no options set
the Passed, Failed and Skipped line is parachute's own, so anyone switching
a gate to this class reads the same three numbers they have read for years,
with the unambiguous axes added beneath them.

Subclasses PLAIN deliberately. PLAIN and QUIET are where parachute contains
an error raised inside a test; a report subclassed straight off REPORT lets
such an error escape and take the rest of the run with it.

Nothing in a parachute result records why a test failed, so no count here
names a cause. The three deviations documented on *CONTROLS-ARE-NOT-CHECKS*,
*UNCARRIED-TEST-FAILURES-ARE-FAILURES* and *SKIPS-ARE-NOT-PASSES* are
selected per instance or globally, and govern both the printed triple and
the triple returned in the AXES structure. The axes themselves are
unaffected by them; they are facts about the run."))

(defun tally-for (report)
  (tally report
         :controls-are-not-checks (controls-are-not-checks-p report)
         :uncarried-test-failures-are-failures
         (uncarried-test-failures-are-failures-p report)
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
                      ;; These are not parachute's own numbers; without them the~%~
                      ;; triple would read ~d / ~d / ~d.~%"
              (axes-active-deviations axes)
              (axes-upstream-passed axes)
              (axes-upstream-failed axes)
              (axes-upstream-skipped axes))
      (format stream ";; Counted exactly as parachute counts: every test result~%~
                      ;; dropped from passed and from failed, skipped counted raw.~%"))
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
               ;; Durations are kept as the exact rationals parachute
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

(defun print-failures (report axes stream)
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
        (format stream "~&~a~%~%" (pa:format-result result :extensive))))
    (when (and (plusp (axes-test-failed-uncarried axes))
               (zerop (axes-upstream-failed axes)))
      (format stream "~&;; ~d failure~:p above ~:[are~;is~] invisible in~%~
                      ;; parachute's own failed count, which reads ~d.~%"
              (axes-test-failed-uncarried axes)
              (= 1 (axes-test-failed-uncarried axes))
              (axes-upstream-failed axes)))))

(defmethod pa:summarize ((report axis-summary))
  (let ((axes (axes-of report))
        (stream (pa:output report)))
    (print-axes axes stream)
    (print-failures report axes stream)
    (force-output stream))
  report)
