;;;; tests/install/install-binary-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Parachute tests for the installer's watcher-binary placement (%copy-binary).
;;;; Both the copy-and-chmod path and the graceful absent-source path are covered
;;;; with a stub source and a fresh temp bin-dir, so the operator's real
;;;; ~/.local/bin is never touched and the tests do not depend on a built binary.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/install/install-binary-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/install/install-binary-test
  (:use #:cl #:parachute)
  (:import-from #:dsmr-mcp/src/install
                #:%copy-binary
                #:default-bin-dir))

(in-package #:dsmr-mcp/tests/install/install-binary-test)

;;; helpers -------------------------------------------------------------------

(defun %unique-temp-dir (stem)
  "Create and return a fresh, unique temporary directory pathname named for STEM."
  (let ((dir (uiop:ensure-directory-pathname
              (merge-pathnames
               (format nil "~A-~A/" stem (random (expt 2 48)))
               (uiop:temporary-directory)))))
    (ensure-directories-exist dir)
    dir))

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
  (let* ((src (%write-stub (merge-pathnames "dsmr-bus-watch"
                                            (%unique-temp-dir "bus-watch-src"))))
         (bin-dir (%unique-temp-dir "bus-watch-bin"))
         (dest (%copy-binary bin-dir src)))
    (true dest)
    (is equal (merge-pathnames "dsmr-bus-watch"
                               (uiop:ensure-directory-pathname bin-dir))
        dest)
    (true (probe-file dest))
    (true (%executable-p dest))))

(define-test returns-nil-when-source-absent
  (let* ((bin-dir (%unique-temp-dir "bus-watch-bin"))
         (missing (merge-pathnames "dsmr-bus-watch"
                                   (%unique-temp-dir "bus-watch-missing")))
         (dest nil))
    ;; ensure the stub source truly does not exist
    (ignore-errors (delete-file missing))
    (finish (setf dest (%copy-binary bin-dir missing)))
    (false dest)
    (false (probe-file (merge-pathnames "dsmr-bus-watch"
                                        (uiop:ensure-directory-pathname bin-dir))))))

(define-test default-bin-dir-is-local-bin
  (is equal
      (merge-pathnames ".local/bin/" (user-homedir-pathname))
      (default-bin-dir)))
