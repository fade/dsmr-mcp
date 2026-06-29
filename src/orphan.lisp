;;;; src/orphan.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Bounded, thread-safe registry of orphaned eval threads.
;;;;
;;;; When a cancel request asks an in-flight eval to abort and the eval does
;;;; not unwind within the grace window, the cancel path records the stranded
;;;; thread here as a tracked orphan. The registry is the structured fallback
;;;; target for a cooperative-abort that does not take, and the data the
;;;; cancel-result notification counts.
;;;;
;;;; This module is a leaf: it depends only on bordeaux-threads (locking) and
;;;; the structured logger. It owns recording and bookkeeping only — probing
;;;; liveness and reclaiming orphaned threads belong to later work.
;;;;
;;;; Concurrency: *orphan-registry* is shared mutable state across the cancel
;;;; threads. Every read-modify-write is serialised under *orphan-lock*, so
;;;; concurrent register/clear calls cannot lose an update. The registry is
;;;; hard-capped at *max-tracked-orphans*: registering past the cap evicts the
;;;; oldest entry first, so a hostile client firing repeated cancels can never
;;;; grow the registry without bound.

(defpackage #:dsmr-mcp/src/orphan
  (:use #:cl)
  (:import-from #:bordeaux-threads
                #:make-lock
                #:with-lock-held)
  (:import-from #:dsmr-mcp/src/log
                #:log-event)
  (:export #:register-orphan
           #:orphan-count
           #:orphan-list
           #:clear-orphan
           #:orphan-info))

(in-package #:dsmr-mcp/src/orphan)

;;; ---------------------------------------------------------------------------
;;; Configuration
;;; ---------------------------------------------------------------------------

(defun %env-positive-int (name default)
  "Read a positive integer from environment variable NAME.
Return DEFAULT when NAME is unset, empty, unparseable, or non-positive.
Each fresh process reads the environment once at load time so operators can
tune the cap without editing source."
  (let ((s (uiop:getenv name)))
    (if (or (null s) (zerop (length s)))
        default
        (handler-case
            (let ((n (parse-integer s)))
              (if (plusp n) n default))
          (error () default)))))

(defvar *max-tracked-orphans*
  (%env-positive-int "DSMR_MAX_TRACKED_ORPHANS" 256)
  "Hard upper bound on the number of orphans tracked at once. Registering past
this cap evicts the oldest entry, so the registry can never grow without bound
from repeated cancels by a hostile client (the memory-exhaustion mitigation).
Default 256; override with DSMR_MAX_TRACKED_ORPHANS (positive integer).")

;;; ---------------------------------------------------------------------------
;;; Global state
;;; ---------------------------------------------------------------------------

(defvar *orphan-lock* (make-lock "orphan-lock")
  "Global mutex serialising every read-modify-write on *orphan-registry*.")

(defvar *orphan-registry* (make-hash-table :test 'equal)
  "Maps request-id (string) -> orphan-entry. Mutated only under *orphan-lock*.")

(defstruct orphan-entry
  request-id       ; original request id (string), the registry key
  session-id       ; session the eval belonged to
  thread           ; the stranded thread handle (bt:thread)
  timestamp        ; (get-universal-time) at registration
  mode)            ; backend mode: :attached | :hermetic

;;; ---------------------------------------------------------------------------
;;; Registry operations
;;; ---------------------------------------------------------------------------

(defun %evict-oldest ()
  "Remove the entry with the smallest timestamp and log the eviction.
The caller MUST hold *orphan-lock*."
  (let ((oldest nil))
    (maphash (lambda (key entry)
               (declare (ignore key))
               (when (or (null oldest)
                         (< (orphan-entry-timestamp entry)
                            (orphan-entry-timestamp oldest)))
                 (setf oldest entry)))
             *orphan-registry*)
    (when oldest
      (remhash (orphan-entry-request-id oldest) *orphan-registry*)
      (log-event :warn "orphan.evicted"
                 "request_id" (orphan-entry-request-id oldest)
                 "session_id" (orphan-entry-session-id oldest)))))

(defun register-orphan (&key request-id session-id thread mode)
  "Record one stranded eval thread as a tracked orphan and return its entry.
REQUEST-ID keys the entry; re-registering the same id replaces it. MODE is the
backend mode (:attached or :hermetic). The registration timestamp is captured
here. When the registry is already at *max-tracked-orphans* and REQUEST-ID is
new, the oldest entry is evicted first so the count never exceeds the cap.
Serialised under *orphan-lock*."
  (with-lock-held (*orphan-lock*)
    (let ((entry (make-orphan-entry
                  :request-id request-id
                  :session-id session-id
                  :thread thread
                  :timestamp (get-universal-time)
                  :mode mode)))
      (when (and (not (nth-value 1 (gethash request-id *orphan-registry*)))
                 (>= (hash-table-count *orphan-registry*) *max-tracked-orphans*))
        (%evict-oldest))
      (setf (gethash request-id *orphan-registry*) entry)
      entry)))

(defun orphan-count ()
  "Return the number of currently-tracked orphans. Serialised under *orphan-lock*."
  (with-lock-held (*orphan-lock*)
    (hash-table-count *orphan-registry*)))

(defun orphan-list ()
  "Return the tracked orphan-entry structs as a fresh list.
Serialised under *orphan-lock*."
  (with-lock-held (*orphan-lock*)
    (let ((entries nil))
      (maphash (lambda (key entry)
                 (declare (ignore key))
                 (push entry entries))
               *orphan-registry*)
      entries)))

(defun clear-orphan (request-id)
  "Remove the orphan tracked under REQUEST-ID. Return T when an entry was
removed, NIL when none was tracked. Serialised under *orphan-lock*."
  (with-lock-held (*orphan-lock*)
    (remhash request-id *orphan-registry*)))

(defun orphan-info ()
  "Return a JSON-encodable hash-table summary of the registry for status
surfacing: \"orphan_count\" plus an \"orphans\" array of per-entry hash-tables
carrying request_id, session_id, mode, and age (seconds since registration).
Uses plain hash-tables so this module stays a leaf with no tools/helpers
dependency. Serialised under *orphan-lock*."
  (with-lock-held (*orphan-lock*)
    (let* ((now (get-universal-time))
           (summary (make-hash-table :test 'equal))
           (orphans (make-array (hash-table-count *orphan-registry*)
                                :fill-pointer 0 :adjustable t)))
      (maphash (lambda (key entry)
                 (declare (ignore key))
                 (let ((row (make-hash-table :test 'equal))
                       (mode (orphan-entry-mode entry)))
                   (setf (gethash "request_id" row) (orphan-entry-request-id entry)
                         (gethash "session_id" row) (orphan-entry-session-id entry)
                         (gethash "mode" row) (when mode (string-downcase (string mode)))
                         (gethash "age" row) (- now (orphan-entry-timestamp entry)))
                   (vector-push-extend row orphans)))
               *orphan-registry*)
      (setf (gethash "orphan_count" summary) (hash-table-count *orphan-registry*)
            (gethash "orphans" summary) orphans)
      summary)))
