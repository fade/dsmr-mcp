;;;; tests/support/fs-fixture.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Shared fixture macro for fs-* tests: creates a temp directory,
;;;; makes a session rooted there, runs body, and cleans up on exit.

;; Package evolution guard — delete prior definition on warm reload.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/support/fs-fixture)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/support/fs-fixture
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/state
                #:make-session
                #:session-project-root)
  (:export #:with-temp-project-root
           #:write-fixture-file
           #:%make-temp-directory))

(in-package #:dsmr-mcp/tests/support/fs-fixture)

(defun %make-temp-directory ()
  "Create a uniquely named temp directory under /tmp and return its pathname."
  ;; Generate a unique name using a gensym-style random string.
  (loop
    (let* ((rand-part (format nil "dsmr-test-~8,'0X" (random #xFFFFFFFF)))
           (dir-pn    (uiop:ensure-directory-pathname
                       (merge-pathnames rand-part #p"/tmp/"))))
      (unless (probe-file dir-pn)
        (ensure-directories-exist dir-pn)
        (return dir-pn)))))

(defmacro with-temp-project-root ((session-var root-var) &body body)
  "Create a fresh temp directory and a session rooted at it.
SESSION-VAR is bound to the session; ROOT-VAR is bound to the directory pathname.
Cleans up the temp tree on exit (even on non-local exit)."
  (let ((dir-var (gensym "TMPDIR-")))
    `(let* ((,dir-var  (%make-temp-directory))
            (,root-var ,dir-var)
            (,session-var (make-session :id "test" :project-root ,root-var)))
       (unwind-protect
            (progn ,@body)
         (uiop:delete-directory-tree ,dir-var
                                     :validate t
                                     :if-does-not-exist :ignore)))))

(defun write-fixture-file (root relative-path content)
  "Write CONTENT to RELATIVE-PATH under ROOT (a pathname).
Returns the absolute pathname of the written file."
  (let ((pn (merge-pathnames relative-path root)))
    (ensure-directories-exist pn)
    (with-open-file (out pn :direction :output :if-exists :supersede
                            :if-does-not-exist :create :element-type 'character)
      (write-string content out))
    pn))
