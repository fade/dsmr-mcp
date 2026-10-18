;;;; tests/install/install-binary-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Zebra tests for the installer's watcher-binary placement (%copy-binary):
;;;; the front end and the SBCL program installed together, the program first;
;;;; a front end refused when its program is missing; an existing front end kept
;;;; when the program cannot be placed; and the absent-source path. Stub sources
;;;; and fresh temp bin dirs only, so the operator's real ~/.local/bin is never
;;;; touched and the tests do not depend on a built binary.

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

(defun %write-stub (path &optional (text "stub"))
  "Write a tiny shell stub at PATH that echoes TEXT, and return PATH."
  (ensure-directories-exist path)
  (with-open-file (out path :direction :output :if-exists :supersede
                            :if-does-not-exist :create)
    (write-line "#!/bin/sh" out)
    (format out "echo ~A~%" text))
  path)

(defun %executable-p (path)
  "True if PATH has any execute bit set."
  (let ((mode (sb-posix:stat-mode (sb-posix:stat path))))
    (plusp (logand mode #o111))))

(defun %file-text (path)
  "Return the contents of the file at PATH as a string."
  (uiop:read-file-string path))

(defun %temp-leftovers (dir)
  "Return the names of the files in DIR, hidden ones included, that end in .tmp."
  (loop for file in (directory (merge-pathnames "*.*" (uiop:ensure-directory-pathname dir))
                               :resolve-symlinks nil)
        for name = (file-namestring file)
        when (and (plusp (length name))
                  (uiop:string-suffix-p name ".tmp"))
          collect name))

(defun %binary-pair (dir)
  "Return the front-end and SBCL-program pathnames inside DIR, as two values."
  (let ((dir (uiop:ensure-directory-pathname dir)))
    (values (merge-pathnames "dsmr-bus-watch" dir)
            (merge-pathnames "dsmr-bus-watch-lisp" dir))))

;;; tests ---------------------------------------------------------------------

(define-test copies-stub-into-bin-dir-and-marks-executable
  (with-temp-dir (src-dir "bus-watch-src")
    (with-temp-dir (bin-dir "bus-watch-bin")
      (multiple-value-bind (src lisp-src) (%binary-pair src-dir)
        (%write-stub src)
        (%write-stub lisp-src)
        (let ((dest (%copy-binary bin-dir src)))
          (true dest)
          (is equal (merge-pathnames "dsmr-bus-watch"
                                     (uiop:ensure-directory-pathname bin-dir))
              dest)
          (true (probe-file dest))
          (true (%executable-p dest)))))))

(define-test installs-the-lisp-program-beside-the-front-end
  (with-temp-dir (src-dir "bus-watch-src")
    (with-temp-dir (bin-dir "bus-watch-bin")
      (multiple-value-bind (src lisp-src) (%binary-pair src-dir)
        (multiple-value-bind (front-dest lisp-dest) (%binary-pair bin-dir)
          (%write-stub src "front-end")
          (%write-stub lisp-src "lisp-program")
          (is equal front-dest (%copy-binary bin-dir src))
          (true (probe-file front-dest))
          (true (probe-file lisp-dest))
          (when (and (probe-file front-dest) (probe-file lisp-dest))
            (true (%executable-p front-dest))
            (true (%executable-p lisp-dest))
            (is string= (%file-text src) (%file-text front-dest))
            (is string= (%file-text lisp-src) (%file-text lisp-dest)))
          (is equal '() (%temp-leftovers bin-dir)))))))

(define-test refuses-a-front-end-without-its-lisp-program
  (with-temp-dir (src-dir "bus-watch-src")
    (with-temp-dir (bin-dir "bus-watch-bin")
      (multiple-value-bind (src lisp-src) (%binary-pair src-dir)
        (multiple-value-bind (front-dest lisp-dest) (%binary-pair bin-dir)
          (%write-stub src "front-end")
          (false (probe-file lisp-src))
          (false (%copy-binary bin-dir src))
          (false (probe-file front-dest))
          (false (probe-file lisp-dest)))))))

(define-test keeps-the-old-front-end-when-the-lisp-program-cannot-be-placed
  (with-temp-dir (src-dir "bus-watch-src")
    (with-temp-dir (bin-dir "bus-watch-bin")
      (multiple-value-bind (src lisp-src) (%binary-pair src-dir)
        (multiple-value-bind (front-dest lisp-dest) (%binary-pair bin-dir)
          (%write-stub src "new-front-end")
          (%write-stub lisp-src "new-lisp-program")
          (%write-stub front-dest "old-front-end")
          ;; A directory where the SBCL program belongs makes its rename fail.
          (ensure-directories-exist (uiop:ensure-directory-pathname lisp-dest))
          (let ((old (%file-text front-dest)))
            (false (%copy-binary bin-dir src))
            (is string= old (%file-text front-dest))
            (true (uiop:directory-exists-p lisp-dest))
            (is equal '() (%temp-leftovers bin-dir))))))))

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
