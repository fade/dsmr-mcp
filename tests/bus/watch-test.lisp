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
                #:default-wal-path
                ;; internal: the argument parser and its record are exercised
                ;; directly, since the flags they carry are only observable
                ;; through main otherwise
                #:%parse-args
                #:opt-wal
                #:opt-after
                #:opt-agent
                #:opt-namespace
                #:opt-agent-id
                #:opt-cursors-dir
                #:opt-stream-p
                #:opt-poll-ms
                #:opt-recycle-seconds
                #:opt-help-p))

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

(defun call-capturing-stderr (thunk)
  "Run THUNK with *error-output* redirected, and return (values result text).
   The watcher's degradations are only observable as stderr diagnostics, so the
   text is as much part of the contract as the value."
  (let* ((stream (make-string-output-stream))
         (result (let ((*error-output* stream)) (funcall thunk))))
    (values result (get-output-stream-string stream))))

(defmacro capturing-stderr (&body body)
  `(call-capturing-stderr (lambda () ,@body)))

(define-test unknown-flag-warns-and-parsing-continues
  ;; A mistyped flag must not deafen the agent: it is named on stderr, skipped,
  ;; and the flags around it still take effect.
  (multiple-value-bind (opts err)
      (capturing-stderr (%parse-args (list "--bogus" "--poll-ms" "250")))
    (is = 250 (opt-poll-ms opts))
    (is = 600 (opt-recycle-seconds opts))
    (false (opt-wal opts))
    (false (opt-after opts))
    (true (search "--bogus" err))))

(define-test unparseable-value-keeps-that-flags-default
  ;; A value that will not parse costs its own flag only, never the whole run.
  (multiple-value-bind (opts err)
      (capturing-stderr (%parse-args (list "--poll-ms" "banana"
                                           "--recycle-seconds" "30")))
    (is = 1000 (opt-poll-ms opts))
    (is = 30 (opt-recycle-seconds opts))
    (true (search "--poll-ms" err))))

(define-test dangling-value-flag-warns-and-resolves-nothing
  ;; A value-taking flag at the very end of argv has nothing to consume.
  (multiple-value-bind (opts err)
      (capturing-stderr (%parse-args (list "--agent")))
    (false (opt-agent opts))
    (true (search "--agent" err))))

(define-test identity-flags-parse
  (let ((opts (%parse-args (list "--agent" "runciter"
                                 "--namespace" "/p"
                                 "--agent-id" "/p/runciter"
                                 "--cursors-dir" "/tmp/cursors/"))))
    (is equal "runciter" (opt-agent opts))
    (is equal "/p" (opt-namespace opts))
    (is equal "/p/runciter" (opt-agent-id opts))
    (is equal "/tmp/cursors/" (opt-cursors-dir opts))))

(define-test previously-supported-flags-parse-unchanged
  ;; Every combination the arm wrapper passes today, plus the operator-facing
  ;; overrides, must land on the same values they did before the flags grew.
  (let ((opts (%parse-args (list "--wal" "/tmp/x.wal" "--after" "7" "--stream"))))
    (is equal "/tmp/x.wal" (opt-wal opts))
    (is = 7 (opt-after opts))
    (true (opt-stream-p opts)))
  (dolist (cadence '(("500" "60") ("1000" "120") ("1000" "300") ("1000" "600")))
    (destructuring-bind (poll recycle) cadence
      (let ((opts (%parse-args (list "--poll-ms" poll "--recycle-seconds" recycle))))
        (is = (parse-integer poll) (opt-poll-ms opts))
        (is = (parse-integer recycle) (opt-recycle-seconds opts))
        (false (opt-stream-p opts))
        (false (opt-wal opts))
        (false (opt-after opts)))))
  (true (opt-help-p (%parse-args (list "--help"))))
  (true (opt-help-p (%parse-args (list "-h")))))
