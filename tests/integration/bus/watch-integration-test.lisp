;;;; tests/integration/bus/watch-integration-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Cross-process integration tests for the compiled bus-watch binary. These
;;;; spawn the REAL `bin/dsmr-bus-watch` executable against a temp WAL and assert
;;;; the property that only shows up across the process boundary an agent actually
;;;; lives behind: the binary signals a new foreign message on STDOUT and exits.
;;;;
;;;; Gated: if the binary has not been built (`make bus-watch`), the tests SKIP
;;;; cleanly rather than fail — the binary is a build artifact, not a source dep.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/integration/bus/watch-integration-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/integration/bus/watch-integration-test
  (:use #:cl #:parachute)
  (:local-nicknames (#:wal #:dsmr-mcp/src/bus/wal)))

(in-package #:dsmr-mcp/tests/integration/bus/watch-integration-test)

;;; helpers -------------------------------------------------------------------

(defun watcher-binary ()
  "The built watcher binary path, or NIL if it has not been built."
  (let ((p (merge-pathnames "bin/dsmr-bus-watch"
                            (asdf:system-source-directory "dsmr-mcp"))))
    (when (probe-file p) p)))

(defun temp-wal ()
  (uiop:with-temporary-file (:pathname p :keep t :type "wal" :prefix "dsmr-bus-watch-it-")
    p))

(defmacro with-wal ((var) &body body)
  `(let ((,var (temp-wal)))
     (unwind-protect (progn ,@body)
       (ignore-errors (delete-file ,var)))))

(defun seed-wal (path n &optional (body "x"))
  (loop for s from 1 to n do (wal:append-record path s body)))

(defun run-watcher (bin &rest args)
  "Run BIN with ARGS synchronously, returning (values stdout stderr exit-code)."
  (uiop:run-program (cons (namestring bin) args)
                    :output '(:string :stripped t)
                    :error-output '(:string :stripped t)
                    :ignore-error-status t))

;;; tests ---------------------------------------------------------------------

(define-test exit-on-event-signals-new-seq-and-exits-zero
  (let ((bin (watcher-binary)))
    (if (null bin)
        (skip ("dsmr-bus-watch not built; run 'make bus-watch' to enable this test"))
        (with-wal (w)
          ;; baseline = 3; a record at seq 4 is already present, so the watcher
          ;; fires on its first poll and exits — deterministic, no timing race.
          (seed-wal w 4)
          (multiple-value-bind (out err code)
              (run-watcher bin "--wal" (namestring w)
                           "--after" "3" "--poll-ms" "50" "--recycle-seconds" "10")
            (declare (ignore err))
            (is = 0 code)
            (true (search "bus:4" out)))))))

(define-test idle-watch-self-recycles-and-exits-zero
  (let ((bin (watcher-binary)))
    (if (null bin)
        (skip ("dsmr-bus-watch not built; run 'make bus-watch' to enable this test"))
        (with-wal (w)
          ;; baseline at the current max (3) with nothing newer: the watcher must
          ;; self-recycle within the window and exit 0 with a recycle: line.
          (seed-wal w 3)
          (multiple-value-bind (out err code)
              (run-watcher bin "--wal" (namestring w)
                           "--after" "3" "--poll-ms" "50" "--recycle-seconds" "1")
            (declare (ignore err))
            (is = 0 code)
            (true (search "recycle:" out)))))))
