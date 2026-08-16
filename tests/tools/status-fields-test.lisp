;;;; tests/tools/status-fields-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Coverage for the reported-field constructor and the conformance walker.
;;;;
;;;; The point of these tests is the walker's RED condition. A suite that only
;;;; shows the walker accepting a well-formed response proves nothing useful:
;;;; a walker that looked at nothing at all would pass that suite exactly as
;;;; well. So most of what follows plants a specific fault and asserts the
;;;; walker reports it.
;;;;
;;;; Every malformed field here is assembled by hand out of a plain hash-table.
;;;; That is not a shortcut around a helper, it is the only way to build one:
;;;; the constructor refuses, which is itself asserted below.
;;;;
;;;; These tests touch no global state and leave nothing behind.

(defpackage #:dsmr-mcp/tests/tools/status-fields-test
  (:use #:cl #:zebra)
  (:import-from #:dsmr-mcp/src/tools/status-fields
                #:reported-field
                #:*field-basis-values*
                #:field-contract-violations
                #:field-contract-error)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:make-ht))

(in-package #:dsmr-mcp/tests/tools/status-fields-test)

;;; ---------------------------------------------------------------------------
;;; Helpers
;;; ---------------------------------------------------------------------------

(defun %hand-built (&rest kvs)
  "Assemble a field by hand from KEY VALUE pairs, bypassing the constructor.
This is how a malformed field gets built: the constructor will not make one."
  (apply #'make-ht kvs))

(defun %sound-field (&rest overrides)
  "A conforming hand-built classification, with OVERRIDES applied on top.
Starting from something sound and breaking exactly one thing keeps each test
honest about which defect produced the violation it asserts."
  (let ((ht (%hand-built "value"              "armed"
                         "establishes"        "one holder remains on the lock"
                         "does_not_establish" "that the holder is healthy"
                         "basis"              "active-probe"
                         "red_condition"      "more than one holder remains"
                         "checked_at"         "2026-08-16T00:00:00Z")))
    (loop for (k v) on overrides by #'cddr
          do (if (eq v :absent)
                 (remhash k ht)
                 (setf (gethash k ht) v)))
    ht))

(defun %latency-field ()
  "A conforming measurement built through the constructor. A number has no
failure state of its own, so it carries no red condition."
  (reported-field 12
                  :establishes "measured one round trip in milliseconds"
                  :does-not-establish "nothing about what the next call will cost"
                  :basis "active-probe"))

(defun %liveness-field ()
  "A conforming classification built through the constructor."
  (reported-field "healthy"
                  :establishes "the worker answered a ping on this cycle"
                  :does-not-establish "nothing about the worker's in-image state"
                  :basis "active-probe"
                  :red-condition "the ping times out on two consecutive cycles"))

;;; ---------------------------------------------------------------------------
;;; The green case
;;; ---------------------------------------------------------------------------

(define-test a-response-built-through-the-constructor-conforms
  ;; Nested one level down and inside a vector, so the walk is genuinely
  ;; exercised rather than the top level alone.
  (let ((response (make-ht "bus"     (make-ht "rotation" (%liveness-field))
                           "workers" (vector (%latency-field) (%liveness-field))
                           "note"    "ordinary text, not a field")))
    (is equal '() (field-contract-violations response)
        "a wholly conforming response yields no violations")))

;;; ---------------------------------------------------------------------------
;;; The constructor refuses to build the faults planted below
;;; ---------------------------------------------------------------------------

(define-test the-constructor-refuses-a-field-with-no-stated-bound
  ;; This is why every malformed field in this file is hand-built.
  (fail (reported-field "armed"
                        :establishes "one holder remains on the lock"
                        :does-not-establish ""
                        :basis "active-probe"
                        :red-condition "more than one holder remains")
        field-contract-error)
  (fail (reported-field "armed"
                        :establishes "one holder remains on the lock"
                        :does-not-establish "that the holder is healthy"
                        :basis "guess"
                        :red-condition "more than one holder remains")
        field-contract-error)
  (fail (reported-field "armed"
                        :establishes "one holder remains on the lock"
                        :does-not-establish "that the holder is healthy"
                        :basis "active-probe")
        field-contract-error))

;;; ---------------------------------------------------------------------------
;;; The red conditions
;;; ---------------------------------------------------------------------------

(define-test a-field-with-no-stated-bound-is-a-violation
  (let* ((response (make-ht "bus" (make-ht "rotation"
                                           (%sound-field "does_not_establish" :absent))))
         (violations (field-contract-violations response)))
    (is = 1 (length violations)
        "one broken field yields exactly one violation")
    (true (search "$.bus.rotation" (first violations))
          "the violation names the path where the field sits")
    (true (search "does_not_establish" (first violations))
          "the violation names the bound that is missing")))

(define-test an-empty-bound-counts-as-a-missing-one
  (let* ((response (make-ht "bus" (make-ht "rotation"
                                           (%sound-field "does_not_establish" ""))))
         (violations (field-contract-violations response)))
    (is = 1 (length violations)
        "an empty bound is reported, not passed over")
    (true (search "$.bus.rotation" (first violations))
          "the violation names the path where the field sits")))

(define-test a-classification-without-a-red-condition-is-a-violation
  (let* ((response (make-ht "state" (%sound-field "red_condition" :absent)))
         (violations (field-contract-violations response)))
    (is = 1 (length violations)
        "a string value is a classification and must say how it would flip")
    (true (search "red_condition" (first violations))
          "the violation names the missing red condition")))

(define-test a-measurement-needs-no-red-condition
  ;; The counterpart to the test above: the same omission on a numeric value is
  ;; correct, because a measurement has no failure state of its own. Without
  ;; this the previous test could be passing for the wrong reason.
  (let ((response (make-ht "latency_ms"
                           (%sound-field "value" 12 "red_condition" :absent))))
    (is equal '() (field-contract-violations response)
        "a numeric value is not required to carry a red condition")))

(define-test the-advisory-basis-is-usable-and-an-invented-one-is-not
  (true (member "roster-advisory" *field-basis-values* :test #'string=)
        "the advisory tag is part of the closed set")
  (let ((advisory (make-ht "members"
                           (%sound-field "value" 3
                                         "basis" "roster-advisory"
                                         "red_condition" :absent))))
    (is equal '() (field-contract-violations advisory)
        "a roster-derived answer is reportable, tagged as what it is"))
  (let* ((invented (make-ht "members" (%sound-field "basis" "vibes")))
         (violations (field-contract-violations invented)))
    (is = 1 (length violations)
        "a basis outside the closed set is reported")
    (true (search "basis" (first violations))
          "the violation names the basis")))

(define-test a-field-buried-three-levels-deep-is-still-found
  ;; A hash-table holding a vector holding a hash-table holding the field. If
  ;; the walk stopped at any of those, a verb could hide a broken field simply
  ;; by nesting it.
  (let* ((response (make-ht
                    "buses"
                    (vector (make-ht "name" "leaders"
                                     "rotation" (%sound-field "does_not_establish" :absent)))))
         (violations (field-contract-violations response)))
    (is = 1 (length violations)
        "nesting does not hide a broken field")
    (true (search "$.buses[0].rotation" (first violations))
          "the violation names the full path down to the buried field")))
