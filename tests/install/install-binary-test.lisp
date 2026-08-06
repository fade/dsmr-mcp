;;;; tests/install/install-binary-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Zebra tests for the installer's watcher-binary placement (%copy-binary).
;;;; Both the copy-and-chmod path and the graceful absent-source path are covered
;;;; with a stub source and a fresh temp bin-dir, so the operator's real
;;;; ~/.local/bin is never touched and the tests do not depend on a built binary.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/install/install-binary-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/install/install-binary-test
  (:use #:cl #:zebra)
  (:import-from #:dsmr-mcp/src/install
                #:%copy-binary
                #:default-bin-dir))

(in-package #:dsmr-mcp/tests/install/install-binary-test)

;;; helpers -------------------------------------------------------------------

(defun %unique-temp-dir (stem)
  "Create and return a fresh, unique temporary directory pathname named for STEM.
SBCL's default *random-state* is deterministic across process invocations, so the
random suffix must be drawn from an entropy-seeded state minted at the call site —
otherwise the \"unique\" names repeat run-to-run and a leftover dir can leak into a
later run's absence assertions. Bind *random-state* before each random call."
  (let* ((*random-state* (make-random-state t))
         (dir (uiop:ensure-directory-pathname
               (merge-pathnames
                (format nil "~A-~A/" stem (random (expt 2 48)))
                (uiop:temporary-directory)))))
    (ensure-directories-exist dir)
    dir))

(defmacro with-temp-dir ((var stem) &body body)
  "Bind VAR to a fresh process-unique temp dir for the dynamic extent of BODY,
deleting it (and its contents) on exit so /tmp never accumulates leftovers that
could leak into a later run's absence assertions."
  `(let ((,var (%unique-temp-dir ,stem)))
     (unwind-protect (progn ,@body)
       (ignore-errors (uiop:delete-directory-tree
                       ,var :validate t :if-does-not-exist :ignore)))))

(defun %write-stub (path)
  "Write a tiny stub file at PATH and return it."
  (ensure-directories-exist path)
  (with-open-file (out path :direction :output :if-exists :supersede
                            :if-does-not-exist :create)
    (write-line "#!/bin/sh" out)
    (write-line "echo stub" out))
  path)

(defun %executable-p (path)
  "True if PATH has any execute bit set."
  (let ((mode (sb-posix:stat-mode (sb-posix:stat path))))
    (plusp (logand mode #o111))))

;;; tests ---------------------------------------------------------------------

(define-test copies-stub-into-bin-dir-and-marks-executable
  (with-temp-dir (src-dir "bus-watch-src")
    (with-temp-dir (bin-dir "bus-watch-bin")
      (let* ((src (%write-stub (merge-pathnames "dsmr-bus-watch" src-dir)))
             (dest (%copy-binary bin-dir src)))
        (true dest)
        (is equal (merge-pathnames "dsmr-bus-watch"
                                   (uiop:ensure-directory-pathname bin-dir))
            dest)
        (true (probe-file dest))
        (true (%executable-p dest))))))

(define-test returns-nil-when-source-absent
  (with-temp-dir (bin-dir "bus-watch-bin")
    (with-temp-dir (missing-dir "bus-watch-missing")
      (let ((missing (merge-pathnames "dsmr-bus-watch" missing-dir))
            (dest-in-bin (merge-pathnames "dsmr-bus-watch"
                                          (uiop:ensure-directory-pathname bin-dir))))
        ;; pristine preconditions: no source, and nothing already at the dest
        (ignore-errors (delete-file missing))
        (ignore-errors (delete-file dest-in-bin))
        (let ((result (%copy-binary bin-dir missing)))
          (false result)
          (false (probe-file dest-in-bin)))))))

(define-test default-bin-dir-is-local-bin
  (is equal
      (merge-pathnames ".local/bin/" (user-homedir-pathname))
      (default-bin-dir)))
