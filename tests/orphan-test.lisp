;;;; tests/orphan-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Unit tests for the bounded, thread-safe orphan registry.
;;;; Covers register->count, list shape, clear->count, the hard bound with
;;;; oldest-entry eviction, and concurrent registration under contention.

(defpackage #:dsmr-mcp/tests/orphan-test
  (:use #:cl #:parachute)
  (:import-from #:dsmr-mcp/src/orphan
                #:register-orphan
                #:orphan-count
                #:orphan-list
                #:clear-orphan
                #:orphan-info)
  ;; Internal symbols needed to inspect entries and reset state between tests.
  (:import-from #:dsmr-mcp/src/orphan
                #:orphan-entry-request-id
                #:orphan-entry-session-id
                #:orphan-entry-thread
                #:orphan-entry-timestamp
                #:orphan-entry-mode
                #:*orphan-registry*
                #:*orphan-lock*
                #:*max-tracked-orphans*)
  (:import-from #:bordeaux-threads
                #:make-thread
                #:join-thread
                #:with-lock-held))

(in-package #:dsmr-mcp/tests/orphan-test)

;;; ---------------------------------------------------------------------------
;;; Helpers
;;; ---------------------------------------------------------------------------

(defun %reset-registry ()
  "Clear all tracked orphans so each test starts from an empty registry."
  (with-lock-held (*orphan-lock*)
    (clrhash *orphan-registry*)))

(defun %find-entry (request-id)
  "Return the tracked orphan-entry whose request-id is REQUEST-ID, or NIL."
  (find request-id (orphan-list)
        :key #'orphan-entry-request-id :test #'string=))

;;; ---------------------------------------------------------------------------
;;; Tests
;;; ---------------------------------------------------------------------------

(define-test register-increments-count
  (%reset-registry)
  (is = 0 (orphan-count))
  (register-orphan :request-id "r-1" :session-id "s-1" :thread nil :mode :attached)
  (is = 1 (orphan-count))
  (register-orphan :request-id "r-2" :session-id "s-1" :thread nil :mode :hermetic)
  (is = 2 (orphan-count)))

(define-test list-returns-entries-carrying-all-fields
  (%reset-registry)
  (register-orphan :request-id "r-1" :session-id "s-7" :thread nil :mode :attached)
  (let ((entry (%find-entry "r-1")))
    (true entry "registered orphan appears in orphan-list")
    (is string= "r-1" (orphan-entry-request-id entry))
    (is string= "s-7" (orphan-entry-session-id entry))
    (is eq :attached (orphan-entry-mode entry))
    (true (integerp (orphan-entry-timestamp entry))
          "timestamp is a universal-time integer")
    ;; thread slot is carried through verbatim (nil here, a real handle in prod).
    (is eq nil (orphan-entry-thread entry))))

(define-test clear-removes-entry-and-decrements-count
  (%reset-registry)
  (register-orphan :request-id "r-1" :session-id "s-1" :thread nil :mode :attached)
  (register-orphan :request-id "r-2" :session-id "s-1" :thread nil :mode :attached)
  (is = 2 (orphan-count))
  (true (clear-orphan "r-1") "clearing a tracked id reports removal")
  (is = 1 (orphan-count))
  (false (%find-entry "r-1") "cleared entry no longer listed")
  (true (%find-entry "r-2") "untouched entry still listed")
  ;; Clearing an unknown id is a no-op that reports nothing was removed.
  (false (clear-orphan "no-such-id"))
  (is = 1 (orphan-count)))

(define-test info-summary-is-json-shaped
  (%reset-registry)
  (register-orphan :request-id "r-1" :session-id "s-9" :thread nil :mode :hermetic)
  (let ((info (orphan-info)))
    (is = 1 (gethash "orphan_count" info))
    (let* ((orphans (gethash "orphans" info))
           (row (elt orphans 0)))
      (is = 1 (length orphans))
      (is string= "r-1" (gethash "request_id" row))
      (is string= "s-9" (gethash "session_id" row))
      (is string= "hermetic" (gethash "mode" row))
      (true (integerp (gethash "age" row)) "age is a non-negative integer")
      (true (>= (gethash "age" row) 0)))))

(define-test bound-evicts-oldest-and-caps-count
  (%reset-registry)
  (let ((*max-tracked-orphans* 20))
    ;; Register the oldest entry first, with a timestamp strictly below the
    ;; rest, so the eviction (smallest timestamp first) is deterministic.
    (register-orphan :request-id "oldest" :session-id "s" :thread nil :mode :attached)
    (sleep 1.1)
    ;; Overfill by 5 past the cap.
    (dotimes (i (+ *max-tracked-orphans* 5))
      (register-orphan :request-id (format nil "fill-~D" i)
                       :session-id "s" :thread nil :mode :attached))
    (is = *max-tracked-orphans* (orphan-count)
        "count never exceeds the cap after over-filling")
    (false (%find-entry "oldest") "the oldest entry was evicted first")))

(define-test concurrent-register-has-no-lost-update
  (%reset-registry)
  ;; N threads each register a distinct request-id under contention; with a cap
  ;; below N the final count is min(N, cap) and no update is lost. The cap is set
  ;; on the global (not a dynamic LET) because bordeaux-threads worker threads do
  ;; not inherit the spawning thread's dynamic bindings.
  (let ((saved-cap *max-tracked-orphans*)
        (n 60)
        (cap 20))
    (unwind-protect
         (progn
           (setf *max-tracked-orphans* cap)
           (let ((threads
                   (loop for i below n
                         collect (let ((id (format nil "c-~D" i)))
                                   (make-thread
                                    (lambda ()
                                      (register-orphan :request-id id
                                                       :session-id "s"
                                                       :thread nil
                                                       :mode :hermetic)))))))
             (mapc #'join-thread threads))
           (is = (min n cap) (orphan-count)
               "final count equals min(N, cap) with no lost-update"))
      (setf *max-tracked-orphans* saved-cap))))
