;;;; tests/report/axis-summary-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Drives the axis-summary reporter against runs whose shape is known,
;;;; rather than reading it and agreeing with it.
;;;;
;;;; Every fixture is built at run time inside a scratch package that is
;;;; deliberately absent from the system definition, so the umbrella suite
;;;; never enumerates it and a fixture that is supposed to fail cannot fail
;;;; the real run. The scratch package is emptied before and after each use.

(defpackage #:dsmr-mcp/tests/report/axis-summary-test
  (:use #:cl #:parachute)
  (:local-nicknames (#:pa #:parachute)
                    (#:ar #:dsmr-mcp/tests/support/parachute-report)
                    (#:ppcre #:cl-ppcre)))

(in-package #:dsmr-mcp/tests/report/axis-summary-test)

;;; ------------------------------------------------------------------
;;; Scratch fixtures

(defvar *fixture-package*
  (or (find-package '#:dsmr-mcp-report-fixtures)
      (make-package '#:dsmr-mcp-report-fixtures :use '(#:cl)))
  "Home for tests that exist to be counted, never to be run by the suite.
Kept out of the system definition on purpose: the umbrella walks the systems
it depends on, and a fixture that fails on purpose would fail the real run.")

(defun install-fixture (name thunk &rest initargs)
  (setf (pa:find-test name *fixture-package*)
        (apply #'make-instance 'pa:test
               :name name
               :home *fixture-package*
               :tests (list thunk)
               initargs)))

(defun run-fixtures (builder &rest report-args)
  "Build fixtures with BUILDER, run them under a fresh report, and return the
report and everything it printed."
  (pa:remove-all-tests-in-package *fixture-package*)
  (funcall builder)
  (unwind-protect
       (let* ((stream (make-string-output-stream))
              (report
                ;; Both of these are bound to the run doing the driving. Left
                ;; alone, every fixture result is filed under the driving test
                ;; and the inner report files itself under the outer one, so a
                ;; fixture failing on purpose fails the real suite.
                (let ((pa:*parent* nil)
                      (pa:*context* nil))
                  ;; A fixture that signals makes parachute warn. That warning
                  ;; is the fixture working.
                  (handler-bind ((warning #'muffle-warning))
                    (apply #'pa:test *fixture-package* :stream stream report-args)))))
         (values report (get-output-stream-string stream)))
    (pa:remove-all-tests-in-package *fixture-package*)))

(defun shape-all-pass ()
  (install-fixture "everything-passes" (lambda () (true t) (is = 1 1))))

(defun shape-failing-leaf ()
  (install-fixture "one-check-fails" (lambda () (true t) (is = 1 2))))

(defun shape-dies-before-asserting ()
  (install-fixture "dies-before-asserting"
                   (lambda () (error "fixture signals before it asserts"))))

(defun shape-skip ()
  (install-fixture "stands-itself-down"
                   (lambda () (skip "fixture stands itself down") (true nil))))

(defun shape-outlives-its-limit ()
  (install-fixture "outlives-its-limit"
                   (lambda () (sleep 0.2) (true t))
                   :time-limit 0.01))

(defun shape-asserts-nothing ()
  (install-fixture "asserts-nothing" (lambda () (values))))

(defun shape-group-wholly-skipped ()
  (install-fixture "group-stood-down"
                   (lambda ()
                     (group (stood-down) (skip "no work here" (true nil))))))

(defun shape-empty ()
  "Register nothing, so the run resolves no test at all."
  nil)

(defparameter +every-shape+
  (list (cons "all pass" #'shape-all-pass)
        (cons "failing leaf" #'shape-failing-leaf)
        (cons "dies before asserting" #'shape-dies-before-asserting)
        (cons "skip" #'shape-skip)
        (cons "outlives its limit" #'shape-outlives-its-limit)
        (cons "asserts nothing" #'shape-asserts-nothing)
        (cons "group wholly skipped" #'shape-group-wholly-skipped)
        (cons "empty run" #'shape-empty)))

(defun printed-triple (output)
  "The three numbers parachute's own summary printed, read back from its text.
Reading the text is the point: one side of the comparison is her formatter,
the other side is our arithmetic."
  (flet ((number-after (label)
           (multiple-value-bind (match groups)
               (ppcre:scan-to-strings (format nil "~a:\\s+(\\d+)" label) output)
             (unless match
               (error "No ~a line in the reporter output:~%~a" label output))
             (parse-integer (aref groups 0)))))
    (list (number-after "Passed") (number-after "Failed") (number-after "Skipped"))))

;;; ------------------------------------------------------------------
;;; The measurement that gates every count taken as a length

(define-test the-report-vector-never-holds-one-object-twice
  ;; Every axis is a length over the report's own result vector, so the
  ;; vector holding a duplicate would inflate all of them including the
  ;; total. Measured by identity, never by equality. Duplicates do occur
  ;; further down: a result created inside a control object is filed under
  ;; that object twice. The report's own vector is the level the counts read.
  (dolist (entry +every-shape+)
    (destructuring-bind (label . shape) entry
      (let* ((results (pa:results (run-fixtures shape :report 'ar:axis-summary)))
             (objects (coerce results 'list)))
        (is = (length objects)
            (length (remove-duplicates objects :test #'eq))
            "~a: an object appears more than once in the report vector" label)))))

;;; ------------------------------------------------------------------
;;; The failure parachute's own summary cannot show

(define-test a-test-that-dies-before-asserting-is-counted
  ;; The state this class exists to change. Under the default reporter this
  ;; run prints no passes and no failures at all.
  (let ((theirs (printed-triple
                 (nth-value 1 (run-fixtures #'shape-dies-before-asserting
                                            :report 'pa:plain)))))
    (is equal '(0 0 0) theirs
        "parachute prints a bare zero triple for a test that died"))
  ;; The same run through this reporter, with the deviation selected.
  (multiple-value-bind (report output)
      (run-fixtures #'shape-dies-before-asserting
                    :report 'ar:axis-summary
                    :uncarried-test-failures-are-failures t)
    (let ((axes (ar:axes-of report)))
      (is = 1 (ar:axes-test-failed-uncarried axes))
      (is = 1 (ar:axes-failed axes))
      ;; and the compatibility number is untouched by the deviation.
      (is = 0 (ar:axes-upstream-failed axes)))
    (true (search "tests failed, nothing beneath accounts for it" output))))

(define-test the-deviations-are-off-until-they-are-asked-for
  ;; A caller who asks for nothing gets parachute's numbers, so adopting the
  ;; class does not move any figure a gate already reads.
  (multiple-value-bind (report output)
      (run-fixtures #'shape-dies-before-asserting :report 'ar:axis-summary)
    (multiple-value-bind (passed failed skipped) (ar:triple report)
      (is = 0 passed)
      (is = 0 failed)
      (is = 0 skipped))
    (true (search "Counted exactly as parachute counts" output))
    ;; The axis still holds the failure whatever the triple says: the axes
    ;; are facts about the run and no deviation moves them.
    (is = 1 (ar:axes-test-failed-uncarried (ar:axes-of report)))))

;;; ------------------------------------------------------------------
;;; Our arithmetic against her formatter

(define-test the-derived-triple-matches-the-one-parachute-prints
  ;; One side of this comparison is parachute's formatted text, the other is
  ;; this reporter's own walk of the raw vector. Nothing calls her counting
  ;; helpers, so the two can disagree, which is the only reason to run it.
  (dolist (entry (list (cons "all pass" #'shape-all-pass)
                       (cons "failing leaf" #'shape-failing-leaf)
                       (cons "dies before asserting" #'shape-dies-before-asserting)
                       (cons "skip" #'shape-skip)
                       (cons "group wholly skipped" #'shape-group-wholly-skipped)
                       (cons "asserts nothing" #'shape-asserts-nothing)
                       (cons "empty run" #'shape-empty)))
    (destructuring-bind (label . shape) entry
      (let ((theirs (printed-triple
                     (nth-value 1 (run-fixtures shape :report 'pa:plain))))
            (axes (ar:axes-of (run-fixtures shape :report 'ar:axis-summary))))
        (is equal theirs
            (list (ar:axes-upstream-passed axes)
                  (ar:axes-upstream-failed axes)
                  (ar:axes-upstream-skipped axes))
            "~a: derived compatibility triple disagrees with the printed one"
            label)))))

(define-test the-time-limit-shape-is-where-the-loaded-parachute-diverges
  ;; The compatibility numbers reproduce upstream, which drops every test
  ;; result from the failed count. The checkout loaded here carries a local
  ;; patch that keeps a test which outlived its limit, so on this one shape
  ;; the printed number and the derived number differ, by design.
  ;;
  ;; If this test starts failing, the loaded parachute and upstream have
  ;; converged. Recheck which semantics the compatibility line should
  ;; reproduce; do not relax the assertion.
  (let* ((theirs (printed-triple
                  (nth-value 1 (run-fixtures #'shape-outlives-its-limit
                                             :report 'pa:plain))))
         (axes (ar:axes-of (run-fixtures #'shape-outlives-its-limit
                                         :report 'ar:axis-summary))))
    (is = 1 (second theirs) "the loaded checkout counts the overrun as a failure")
    (is = 0 (ar:axes-upstream-failed axes) "upstream would count no failure")
    ;; The overrun is not lost by reproducing upstream. It reaches the axes
    ;; through a predicate that consults no clock: the test failed and
    ;; nothing beneath it carries that failure.
    (is = 1 (ar:axes-test-failed-uncarried axes))))

(define-test the-two-numbers-behind-a-time-limit-are-reported-uncompared
  ;; Whether an overrun caused a failure is a judgement, and the run records
  ;; no cause. Both numbers are handed back so a caller can draw their own
  ;; line rather than inherit ours.
  (let* ((axes (ar:axes-of (run-fixtures #'shape-outlives-its-limit
                                         :report 'ar:axis-summary)))
         (observations (ar:axes-declared-limits axes)))
    (is = 1 (length observations))
    (let ((observation (first observations)))
      (is eql 0.01 (ar:limit-declared observation))
      (true (numberp (ar:limit-duration observation)))
      (is eql :failed (ar:limit-status observation))
      ;; The comparison a caller might make, made here by the caller.
      (true (< (ar:limit-declared observation) (ar:limit-duration observation)))))
  ;; A run with no declared limit reports no observation rather than a zero.
  (let ((axes (ar:axes-of (run-fixtures #'shape-all-pass :report 'ar:axis-summary))))
    (is equal '() (ar:axes-declared-limits axes))))

;;; ------------------------------------------------------------------
;;; The partition

(define-test the-axes-partition-the-result-vector-exactly
  (dolist (entry +every-shape+)
    (destructuring-bind (label . shape) entry
      (let ((axes (ar:axes-of (run-fixtures shape :report 'ar:axis-summary))))
        (is = (ar:axes-total axes)
            (+ (ar:axes-leaf-passed axes)
               (ar:axes-leaf-failed axes)
               (ar:axes-leaf-skipped axes)
               (ar:axes-test-passed-carried axes)
               (ar:axes-test-passed-uncarried axes)
               (ar:axes-test-failed-carried axes)
               (ar:axes-test-failed-uncarried axes)
               (ar:axes-test-skipped axes)
               (ar:axes-control-passed axes)
               (ar:axes-control-failed axes)
               (ar:axes-control-skipped axes)
               (ar:axes-non-terminal axes))
            "~a: the axes do not sum to the total" label)))))

(define-test a-normal-run-reports-numbers-that-reconcile
  (multiple-value-bind (report output) (run-fixtures #'shape-all-pass
                                                     :report 'ar:axis-summary)
    (let ((axes (ar:axes-of report)))
      (is = 2 (ar:axes-leaf-passed axes))
      (is = 0 (ar:axes-leaf-failed axes))
      (is = 1 (ar:axes-test-passed-carried axes))
      (is = 3 (ar:axes-total axes))
      (is = 2 (ar:axes-passed axes))
      (is = 0 (ar:axes-failed axes)))
    (false (search "UNACCOUNTED" output))))

(define-test one-failure-is-counted-once-not-once-per-enclosing-result
  ;; The trap in copying the shipped large-scale reporter: it counts a failing
  ;; test and the failing check beneath it, so one failure reads as two.
  (let ((axes (ar:axes-of (run-fixtures #'shape-failing-leaf
                                        :report 'ar:axis-summary))))
    (is = 1 (ar:axes-leaf-failed axes))
    (is = 1 (ar:axes-test-failed-carried axes))
    (is = 0 (ar:axes-test-failed-uncarried axes))
    ;; The failing test is on its own line, so no reader has to know whether
    ;; the failure count includes it.
    (is = 1 (ar:axes-failed axes))))

;;; ------------------------------------------------------------------
;;; Zero triples that mean different things

(define-test an-empty-run-and-a-run-that-asserted-nothing-are-distinguishable
  ;; Parachute prints the same three zeroes for both.
  (is equal
      (printed-triple (nth-value 1 (run-fixtures #'shape-empty :report 'pa:plain)))
      (printed-triple (nth-value 1 (run-fixtures #'shape-asserts-nothing
                                                 :report 'pa:plain))))
  (multiple-value-bind (report output) (run-fixtures #'shape-empty
                                                     :report 'ar:axis-summary)
    (is = 0 (ar:axes-total (ar:axes-of report)))
    (true (search "Nothing ran" output)))
  (multiple-value-bind (report output) (run-fixtures #'shape-asserts-nothing
                                                     :report 'ar:axis-summary)
    (let ((axes (ar:axes-of report)))
      (is = 1 (ar:axes-total axes))
      (is = 1 (ar:axes-test-passed-uncarried axes)))
    (true (search "no leaf check among" output))))

(define-test an-empty-run-prints-without-dividing-by-anything
  ;; The shipped large-scale reporter divides each count by the total and
  ;; signals division-by-zero on a run with no results. Nothing here divides.
  (multiple-value-bind (report output) (run-fixtures #'shape-empty
                                                     :report 'ar:axis-summary)
    (declare (ignore report))
    (true (search ";; Summary:" output))
    (true (search "total results recorded" output))
    (true (search "Nothing ran" output))))

;;; ------------------------------------------------------------------
;;; The text is a projection of the structure

(define-test the-printed-report-is-rendered-from-the-structured-counts
  ;; Computing the numbers and formatting them separately would satisfy any
  ;; check that only asks whether both exist, and would drift the moment
  ;; either side is edited. So: move the structure, and require the text to
  ;; move with it. A reporter that recomputed its numbers while printing
  ;; would print the old values here and nothing else would notice.
  (let ((axes (ar:axes-of (run-fixtures #'shape-all-pass :report 'ar:axis-summary))))
    (setf (ar:axes-passed axes) 4242
          (ar:axes-failed axes) 5353
          (ar:axes-leaf-passed axes) 1717
          (ar:axes-total axes) 9393)
    (let ((reprinted (with-output-to-string (stream) (ar:print-axes axes stream))))
      (true (search "4242" reprinted) "the passed line follows the structure")
      (true (search "5353" reprinted) "the failed line follows the structure")
      (true (search "1717" reprinted) "the leaf axis follows the structure")
      (true (search "9393" reprinted) "the total follows the structure")
      ;; The total no longer matches the partition, and the report says so
      ;; rather than printing a set of numbers that quietly disagree.
      (true (search "UNACCOUNTED" reprinted)))))

;;; ------------------------------------------------------------------
;;; The deviations, one at a time

(define-test controls-are-not-checks-removes-the-group-leak
  ;; Parachute drops test results from the leaf counts but not groups or
  ;; control objects, so a GROUP form is counted as though it asserted.
  (let ((theirs (ar:axes-of (run-fixtures #'shape-group-wholly-skipped
                                          :report 'ar:axis-summary)))
        (ours (ar:axes-of (run-fixtures #'shape-group-wholly-skipped
                                        :report 'ar:axis-summary
                                        :controls-are-not-checks t))))
    ;; The run contains no leaf check at all.
    (is = 0 (ar:axes-leaf-passed theirs))
    ;; Yet the compatibility count reports passes, because the group and the
    ;; test around it are counted.
    (true (plusp (ar:axes-upstream-passed theirs)))
    (is = 0 (ar:axes-passed ours)
        "with controls excluded, a run with no check reports no pass")))

(define-test skips-are-not-passes-stops-a-stood-down-body-reading-as-work
  (let ((ours (ar:axes-of (run-fixtures #'shape-group-wholly-skipped
                                        :report 'ar:axis-summary
                                        :skips-are-not-passes t)))
        (theirs (ar:axes-of (run-fixtures #'shape-group-wholly-skipped
                                          :report 'ar:axis-summary))))
    (true (< (ar:axes-passed ours) (ar:axes-passed theirs))
          "a group whose whole body was stood down should not read as a pass")))

(define-test a-selected-deviation-is-named-in-the-printed-report
  (multiple-value-bind (report output)
      (run-fixtures #'shape-dies-before-asserting
                    :report 'ar:axis-summary
                    :uncarried-test-failures-are-failures t)
    (declare (ignore report))
    (true (search "uncarried-test-failures-are-failures" output))
    (true (search "without them the" output)
          "the report says what parachute's own numbers would have been")))

(define-test a-dynamic-default-selects-the-same-semantics-as-an-initarg
  (let ((by-initarg (ar:axes-of (run-fixtures #'shape-dies-before-asserting
                                              :report 'ar:axis-summary
                                              :uncarried-test-failures-are-failures t)))
        (by-variable
          (let ((ar:*uncarried-test-failures-are-failures* t))
            (ar:axes-of (run-fixtures #'shape-dies-before-asserting
                                      :report 'ar:axis-summary)))))
    (is = (ar:axes-failed by-initarg) (ar:axes-failed by-variable))
    (is = 1 (ar:axes-failed by-variable))))

;;; ------------------------------------------------------------------
;;; Counts without a report of our own

(define-test the-counts-can-be-taken-from-any-parachute-report
  ;; A caller already holding a plain report should not have to re-run
  ;; anything to get the numbers as data.
  (let* ((report (run-fixtures #'shape-failing-leaf :report 'pa:plain))
         (axes (ar:tally report)))
    (is = 1 (ar:axes-leaf-failed axes))
    (is = 1 (ar:axes-leaf-passed axes))
    (is = 3 (ar:axes-total axes))))
