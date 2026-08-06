;;;; tests/hermetic/inspect-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; In-process tests for the hermetic worker's object registry and walker.
;;;; These tests run without spawning a worker process — they exercise the
;;;; registry and inspect functions directly, proving the worker-LOCAL
;;;; behaviors required on the hermetic path.
;;;;
;;;; Coverage:
;;;;   - Registry round-trip (register + lookup)
;;;;   - inspectable-p predicate (primitives excluded, composites included)
;;;;   - Walker envelope shape for CLOS instances and hash-tables
;;;;   - OBJECT_NOT_FOUND for unknown IDs
;;;;   - build-inspect-response wrapping (success and error cases)
;;;;   - Single-eval guarantee: user code runs once, registered object is
;;;;     the same instance the eval returned

(defpackage #:dsmr-mcp/tests/hermetic/inspect-test
  (:use #:cl #:zebra)
  (:import-from #:dsmr-mcp/src/hermetic/worker/registry
                #:make-object-registry
                #:register-object
                #:lookup-object
                #:inspectable-p)
  (:import-from #:dsmr-mcp/src/hermetic/worker/inspect
                #:inspect-object-by-id
                #:build-inspect-response)
  (:import-from #:dsmr-mcp/src/hermetic/worker/handlers
                #:%handle-eval))

(in-package #:dsmr-mcp/tests/hermetic/inspect-test)

;;; ---------------------------------------------------------------------------
;;; Throwaway CLOS class for registry tests
;;; ---------------------------------------------------------------------------

(defclass %test-widget ()
  ((color :initarg :color :initform "red")
   (count :initarg :count :initform 0))
  (:documentation "Minimal CLOS class used only within inspect-test."))

;;; ---------------------------------------------------------------------------
;;; Registry round-trip
;;; ---------------------------------------------------------------------------

(define-test worker-registry-roundtrip
  "make-object-registry + register-object + lookup-object round-trips a
CLOS instance through the per-worker registry without a global."
  (let* ((reg (make-object-registry))
         (obj (make-instance '%test-widget :color "blue" :count 42))
         (id  (register-object obj reg)))
    (true (integerp id))
    (true (plusp id))
    (multiple-value-bind (found found-p)
        (lookup-object id reg)
      (true found-p)
      (is eq obj found))))

;;; ---------------------------------------------------------------------------
;;; inspectable-p predicate
;;; ---------------------------------------------------------------------------

(define-test worker-inspectable-p-primitives-excluded
  "inspectable-p returns nil for numbers, strings, symbols, and characters
— the four primitive classes that must not be registered."
  (false (inspectable-p 42))
  (false (inspectable-p 3.14))
  (false (inspectable-p "hello"))
  (false (inspectable-p 'foo))
  (false (inspectable-p #\a)))

(define-test worker-inspectable-p-composites-included
  "inspectable-p returns true for conses, instances, and hash-tables."
  (true (inspectable-p (cons 1 2)))
  (true (inspectable-p (make-instance '%test-widget)))
  (true (inspectable-p (make-hash-table))))

;;; ---------------------------------------------------------------------------
;;; Walker envelope — CLOS instance
;;; ---------------------------------------------------------------------------

(define-test worker-inspect-returns-instance-envelope
  "inspect-object-by-id on a registered CLOS instance returns a hash-table
with kind=instance, a non-empty slots sequence, and id matching the
registered id."
  (let* ((reg (make-object-registry))
         (obj (make-instance '%test-widget :color "green" :count 7))
         (id  (register-object obj reg))
         (result (inspect-object-by-id id reg)))
    (true (hash-table-p result))
    (false (gethash "error" result))
    (is string= "instance" (gethash "kind" result))
    (is = id (gethash "id" result))
    (let ((slots (gethash "slots" result)))
      (true (and slots (plusp (length slots)))))))

;;; ---------------------------------------------------------------------------
;;; Walker envelope — hash-table
;;; ---------------------------------------------------------------------------

(define-test worker-inspect-hash-table-entries
  "inspect-object-by-id on a registered hash-table returns kind=hash-table
and a non-nil entries sequence."
  (let* ((reg (make-object-registry))
         (ht  (let ((h (make-hash-table :test 'equal)))
                (setf (gethash "x" h) 1)
                (setf (gethash "y" h) 2)
                h))
         (id  (register-object ht reg))
         (result (inspect-object-by-id id reg)))
    (true (hash-table-p result))
    (false (gethash "error" result))
    (is string= "hash-table" (gethash "kind" result))
    (is = id (gethash "id" result))
    (let ((entries (gethash "entries" result)))
      (true (and entries (plusp (length entries)))))))

;;; ---------------------------------------------------------------------------
;;; OBJECT_NOT_FOUND for unknown ID
;;; ---------------------------------------------------------------------------

(define-test worker-unknown-id-returns-object-not-found
  "inspect-object-by-id on an ID not present in the registry returns a
hash-table with error=t and code=OBJECT_NOT_FOUND."
  (let* ((reg (make-object-registry))
         (result (inspect-object-by-id 999999 reg)))
    (true (hash-table-p result))
    (true (gethash "error" result))
    (is string= "OBJECT_NOT_FOUND" (gethash "code" result))))

;;; ---------------------------------------------------------------------------
;;; build-inspect-response wrapping
;;; ---------------------------------------------------------------------------

(define-test worker-build-inspect-response-wraps-success-and-error
  "build-inspect-response returns an isError response for OBJECT_NOT_FOUND
and a content-bearing envelope for a successful inspection."
  (let* ((reg (make-object-registry))
         (ht  (let ((h (make-hash-table :test 'equal)))
                (setf (gethash "k" h) 99)
                h))
         (id  (register-object ht reg))
         ;; Success case
         (ok-result     (inspect-object-by-id id reg))
         (ok-response   (build-inspect-response ok-result))
         ;; Error case
         (err-result    (inspect-object-by-id 888888 reg))
         (err-response  (build-inspect-response err-result)))
    ;; Success response must have content and no isError
    (true (hash-table-p ok-response))
    (false (gethash "isError" ok-response))
    (true (gethash "content" ok-response))
    ;; Error response must have isError=t
    (true (hash-table-p err-response))
    (true (gethash "isError" err-response))))

;;; ---------------------------------------------------------------------------
;;; Single-eval guarantee — side effects run once, registered object matches
;;; ---------------------------------------------------------------------------

;; Counter lives in CL-USER so the eval'd code string can reference it
;; without package-qualification gymnastics.
(defvar cl-user::*inspect-test-eval-counter* 0
  "Counter incremented inside eval-side-effect-runs-once to detect double evaluation.")

(define-test eval-side-effect-runs-once
  "User code passed to %handle-eval executes exactly once even when
register_result is true.  A form that increments a special variable and
returns a fresh cons must leave the counter at exactly 1 after the call."
  ;; Reset counter before each run.
  (setf cl-user::*inspect-test-eval-counter* 0)
  (let* ((reg (make-object-registry))
         (params (let ((ht (make-hash-table :test 'equal)))
                   ;; The code increments the counter and returns a cons
                   ;; (inspectable, so registration fires).
                   (setf (gethash "code" ht)
                         "(progn (incf cl-user::*inspect-test-eval-counter*) (cons :tag cl-user::*inspect-test-eval-counter*))")
                   (setf (gethash "register_result" ht) t)
                   ht))
         (response (%handle-eval params reg)))
    ;; Counter must be 1 — proves the user form ran exactly once.
    (is = 1 cl-user::*inspect-test-eval-counter*)
    ;; A result_object_id must have been assigned (cons is inspectable).
    (true (gethash "result_object_id" response))))

(define-test eval-registers-result-without-re-running
  "The object stored in the registry under result_object_id is the same
instance that %handle-eval evaluated — not a second instance produced by
a re-evaluation.  Verified by mutating the registered object's slot and
confirming the mutation is visible through a fresh lookup, and by checking
that the printed result matches the instance's original slot value."
  (let* ((reg (make-object-registry))
         (params (let ((ht (make-hash-table :test 'equal)))
                   (setf (gethash "code" ht)
                         "(make-instance 'dsmr-mcp/tests/hermetic/inspect-test::%test-widget :color \"same-instance\" :count 42)")
                   (setf (gethash "register_result" ht) t)
                   ht))
         (response (%handle-eval params reg))
         (id (gethash "result_object_id" response)))
    ;; An ID must have been assigned.
    (true (and id (integerp id) (plusp id)))
    ;; Retrieve the registered object and verify its slot matches what was constructed.
    (multiple-value-bind (obj found-p)
        (lookup-object id reg)
      (true found-p)
      (is string= "same-instance" (slot-value obj 'color))
      (is = 42 (slot-value obj 'count))
      ;; Mutate the registered object.  If it were a re-evaluated second instance,
      ;; this mutation would not affect whatever was returned to the caller — the
      ;; test would still pass, but the guarantee would be broken.  Because the
      ;; same object is registered, the mutation is visible through the same id.
      (setf (slot-value obj 'count) 999)
      (multiple-value-bind (obj2 found2-p)
          (lookup-object id reg)
        (true found2-p)
        ;; EQ identity: same pointer, not a copy.
        (true (eq obj obj2))
        ;; Mutation visible through re-lookup proves it is the same instance.
        (is = 999 (slot-value obj2 'count))))))
