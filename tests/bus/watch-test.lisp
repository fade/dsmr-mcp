;;;; tests/bus/watch-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Parachute tests for the cross-agent bus wakeup watcher. The load-bearing
;;;; properties: the watcher fires on a seq strictly above its arm-time baseline
;;;; (so an agent's own just-published message, which is at-or-below the baseline
;;;; once it re-arms, never wakes it), it self-recycles to NIL when the idle
;;;; window passes with nothing new, it tolerates a missing/empty WAL, and the
;;;; streaming step emits exactly one signal per new message. The watch loop is a
;;;; named function exercised directly in-process — no subprocess, no real waiting.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/bus/watch-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/bus/watch-test
  (:use #:cl #:parachute)
  (:import-from #:dsmr-mcp/src/bus/wal
                #:scan
                #:append-record)
  (:import-from #:dsmr-bus-watch/src/bus/watch
                #:watch-until-foreign
                #:poll-new
                #:default-wal-path))

(in-package #:dsmr-mcp/tests/bus/watch-test)

;;; helpers (local copies of the wal-test fixtures; do not cross-import test pkgs)

(defun temp-wal ()
  (uiop:with-temporary-file (:pathname p :keep t :type "wal" :prefix "dsmr-bus-watch-")
    p))

(defmacro with-wal ((var) &body body)
  `(let ((,var (temp-wal)))
     (unwind-protect (progn ,@body)
       (ignore-errors (delete-file ,var)))))

(defun write-good-wal (path n &optional (body "x"))
  "Append N contiguous good records 1..N."
  (loop for s from 1 to n do (append-record path s body)))

;;; tests ---------------------------------------------------------------------

(define-test fires-when-record-already-above-baseline
  ;; Level-triggered: a qualifying record present at arm returns on the first poll.
  (with-wal (w)
    (write-good-wal w 3)
    (is = 3 (watch-until-foreign w 0 :poll-ms 5 :recycle-seconds 5))))

(define-test does-not-fire-when-nothing-exceeds-baseline
  ;; Baseline at the current max — the agent's own latest message — never wakes it.
  (with-wal (w)
    (write-good-wal w 3)
    (false (watch-until-foreign w 3 :poll-ms 5 :recycle-seconds 0.05))))

(define-test fires-when-record-appended-after-arm
  ;; Append then poll: the new seq is found on the next scan.
  (with-wal (w)
    (write-good-wal w 2)
    (append-record w 3 "x")
    (is = 3 (watch-until-foreign w 2 :poll-ms 5 :recycle-seconds 5))))

(define-test explicit-baseline-ignores-lower-and-equal
  ;; --after-style baseline: equal/lower seqs are ignored; the next higher fires.
  (with-wal (w)
    (write-good-wal w 3)
    (false (watch-until-foreign w 3 :poll-ms 5 :recycle-seconds 0.05))
    (append-record w 4 "x")
    (is = 4 (watch-until-foreign w 3 :poll-ms 5 :recycle-seconds 5))))

(define-test self-recycles-on-empty-wal
  ;; Missing/empty WAL: baseline 0, scan returns 0, recycles to NIL — no error.
  (with-wal (w)
    (ignore-errors (delete-file w))   ; ensure the file does not exist
    (false (watch-until-foreign w 0 :poll-ms 5 :recycle-seconds 0.05))))

(define-test streaming-emits-one-signal-per-new-seq
  ;; The streaming step emits exactly one signal per new message across appends.
  (with-wal (w)
    (let ((seen '()))
      (flet ((collect (s) (push s seen)))
        (let ((cursor 0))
          (append-record w 1 "x")
          (setf cursor (poll-new w cursor #'collect))
          (append-record w 2 "x")
          (setf cursor (poll-new w cursor #'collect))
          (is = 2 cursor)
          (is equal '(1 2) (nreverse seen)))))))
