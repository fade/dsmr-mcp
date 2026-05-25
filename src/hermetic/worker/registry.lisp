;;;; src/hermetic/worker/registry.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Per-worker FIFO object registry for hermetic-mode inspection.
;;;; Ported from cl-mcp/src/object-registry.lisp (MIT) under AGPL.
;;;;
;;;; The registry is created once per worker process at startup and passed
;;;; explicitly to all handlers — there is no global *object-registry*.
;;;; A worker crash discards the registry entirely; the next process starts
;;;; with a fresh empty one, which is the correct invalidation behavior.
;;;;
;;;; FIFO eviction caps memory at +max-registry-size+ = 1000 entries.
;;;; When the registry is full, the oldest entry is evicted and its ID
;;;; returns OBJECT_NOT_FOUND on the next lookup.
;;;;
;;;; SBCL-specific introspection is permitted in the worker — the worker is
;;;; dsmr-mcp's own SBCL process, not the user's attached image.

(defpackage #:dsmr-mcp/src/hermetic/worker/registry
  (:use #:cl)
  (:import-from #:bordeaux-threads
                #:make-lock
                #:with-lock-held)
  (:export #:make-object-registry
           #:inspectable-p
           #:register-object
           #:lookup-object
           #:clear-registry
           #:registry-count
           #:+max-registry-size+))

(in-package #:dsmr-mcp/src/hermetic/worker/registry)

;;; ---------------------------------------------------------------------------
;;; Configuration
;;; ---------------------------------------------------------------------------

(defconstant +max-registry-size+ 1000
  "Maximum number of objects held in a single worker registry before FIFO
eviction discards the oldest entry.")

;;; ---------------------------------------------------------------------------
;;; Registry struct
;;; ---------------------------------------------------------------------------

(defstruct (object-registry (:constructor %make-object-registry))
  "FIFO cache mapping integer IDs to live objects in the worker process.
Thread-safe via a per-registry lock; all mutations acquire the lock."
  (storage (make-hash-table :test 'eql) :type hash-table)
  (history (make-array +max-registry-size+ :initial-element nil) :type simple-vector)
  (head    0 :type fixnum)   ; next write position in history ring
  (count   0 :type fixnum)   ; current number of occupied slots
  (next-id 1 :type integer)
  (lock    (bordeaux-threads:make-lock "object-registry")))

(defun make-object-registry ()
  "Create and return a fresh, empty object registry."
  (%make-object-registry))

;;; ---------------------------------------------------------------------------
;;; Predicates
;;; ---------------------------------------------------------------------------

(defun inspectable-p (object)
  "Return T if OBJECT should be registered for inspection.
Numbers, strings, symbols, and characters are primitives that need no
registry entry; all other types are inspectable."
  (not (or (numberp object)
           (stringp object)
           (symbolp object)
           (characterp object))))

;;; ---------------------------------------------------------------------------
;;; Internal: FIFO eviction
;;; ---------------------------------------------------------------------------

(defun %evict-oldest (registry)
  "Remove the oldest entry from REGISTRY. Must be called with lock held."
  (let ((history (object-registry-history registry))
        (storage (object-registry-storage registry))
        (head    (object-registry-head    registry))
        (count   (object-registry-count   registry)))
    (when (>= count +max-registry-size+)
      (let* ((oldest-pos (mod head +max-registry-size+))
             (oldest-id  (aref history oldest-pos)))
        (when oldest-id
          (remhash oldest-id storage)
          (setf (aref history oldest-pos) nil))))))

;;; ---------------------------------------------------------------------------
;;; Registry operations — REGISTRY is a required explicit parameter
;;; ---------------------------------------------------------------------------

(defun register-object (object registry)
  "Register OBJECT in REGISTRY and return its integer ID.
Returns NIL when OBJECT is not inspectable (primitives).
Evicts the oldest entry when the registry is at capacity."
  (unless (inspectable-p object)
    (return-from register-object nil))
  (with-lock-held ((object-registry-lock registry))
    (let ((storage (object-registry-storage registry))
          (history (object-registry-history registry))
          (id      (object-registry-next-id registry))
          (head    (object-registry-head    registry))
          (count   (object-registry-count   registry)))
      (when (>= count +max-registry-size+)
        (%evict-oldest registry))
      (setf (gethash id storage) object)
      (setf (aref history head) id)
      (setf (object-registry-head registry)
            (mod (1+ head) +max-registry-size+))
      (setf (object-registry-count registry)
            (min (1+ count) +max-registry-size+))
      (incf (object-registry-next-id registry))
      id)))

(defun lookup-object (id registry)
  "Return (values OBJECT FOUND-P) for ID in REGISTRY.
FOUND-P is NIL when the ID was never registered or has been evicted."
  (with-lock-held ((object-registry-lock registry))
    (multiple-value-bind (object found-p)
        (gethash id (object-registry-storage registry))
      (values object found-p))))

(defun clear-registry (registry)
  "Remove all objects from REGISTRY, resetting head and count to zero."
  (with-lock-held ((object-registry-lock registry))
    (clrhash (object-registry-storage registry))
    (fill    (object-registry-history registry) nil)
    (setf (object-registry-head  registry) 0
          (object-registry-count registry) 0)
    t))

(defun registry-count (registry)
  "Return the number of objects currently held in REGISTRY."
  (with-lock-held ((object-registry-lock registry))
    (object-registry-count registry)))
