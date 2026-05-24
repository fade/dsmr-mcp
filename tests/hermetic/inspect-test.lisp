;;;; tests/hermetic/inspect-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; In-process tests for the hermetic worker's object registry and walker.
;;;; These tests run without spawning a worker process — they exercise the
;;;; registry and inspect functions directly, proving the worker-LOCAL
;;;; behaviors that VERB-11 requires on the hermetic path.
;;;;
;;;; Coverage:
;;;;   - Registry round-trip (register + lookup)
;;;;   - inspectable-p predicate (primitives excluded, composites included)
;;;;   - Walker envelope shape for CLOS instances and hash-tables
;;;;   - OBJECT_NOT_FOUND for unknown IDs
;;;;   - build-inspect-response wrapping (success and error cases)

(defpackage #:dsmr-mcp/tests/hermetic/inspect-test
  (:use #:cl #:parachute)
  (:import-from #:dsmr-mcp/src/hermetic/worker/registry
                #:make-object-registry
                #:register-object
                #:lookup-object
                #:inspectable-p)
  (:import-from #:dsmr-mcp/src/hermetic/worker/inspect
                #:inspect-object-by-id
                #:build-inspect-response))

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
