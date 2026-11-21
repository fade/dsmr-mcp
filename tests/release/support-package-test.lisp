;;;; tests/release/support-package-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Unit tests of the run-time lookup of the support code's own packages:
;;;; the prefix follows the helper's own package name, a suffix resolves to the
;;;; support package carrying that prefix, and an absent package is reported.

(defpackage #:dsmr-mcp/tests/release/support-package-test
  (:use #:cl #:zebra)
  (:import-from #:dsmr-mcp/src/support-package
                #:support-prefix
                #:support-package
                #:support-symbol-call)
  (:import-from #:dsmr-mcp/src/notify)
  (:import-from #:cl-ppcre))

(in-package #:dsmr-mcp/tests/release/support-package-test)

(define-test the-support-prefix-is-dsmr-mcp-in-the-test-image
  "Unrenamed, the support packages carry the DSMR-MCP prefix."
  (is string= "DSMR-MCP" (support-prefix)))

(define-test the-prefix-is-the-text-before-src
  "The prefix is the package name up to its first /SRC/, whatever it is."
  (is string= "DSMR-WORKER"
      (dsmr-mcp/src/support-package::%prefix-of "DSMR-WORKER/SRC/SUPPORT-PACKAGE"))
  (is string= "DSMR-MCP"
      (dsmr-mcp/src/support-package::%prefix-of "DSMR-MCP/SRC/SUPPORT-PACKAGE")))

(define-test a-suffix-resolves-to-the-support-package
  "A suffix names the support package carrying the image's prefix."
  (is eq (find-package "DSMR-MCP/SRC/NOTIFY") (support-package "SRC/NOTIFY")))

(define-test a-support-function-is-called-by-suffix-and-name
  "support-symbol-call reaches a function by package suffix and symbol name and
passes its arguments through."
  (is string= "SRC/NOTIFY"
      (support-symbol-call "SRC/SUPPORT-PACKAGE" "%PREFIX-OF" "SRC/NOTIFY"))
  (is string= "A"
      (support-symbol-call "SRC/SUPPORT-PACKAGE" "%PREFIX-OF" "A/SRC/B")))

(define-test an-absent-support-package-is-reported
  "A suffix naming no package gives NIL from support-package, and an error
naming the package from support-symbol-call."
  (false (support-package "SRC/NO-SUCH-PACKAGE"))
  (let ((condition (handler-case
                       (progn (support-symbol-call "SRC/NO-SUCH-PACKAGE" "F") nil)
                     (error (e) e))))
    (true condition "an absent package was called")
    (true (and condition
               (search "DSMR-MCP/SRC/NO-SUCH-PACKAGE" (princ-to-string condition)))
          "~A" condition)))

;;; ---------------------------------------------------------------------------
;;; Run-time designators in the worker's code
;;; ---------------------------------------------------------------------------

(defparameter *run-time-designator-scanner*
  (cl-ppcre:create-scanner
   "\\b(?:symbol-call|find-package|find-symbol)\\s+(?:\"[^\"]*\"\\s+)?(?:#?:|\")dsmr-mcp/"
   :case-insensitive-mode t)
  "Matches symbol-call, find-package or find-symbol followed, across any
whitespace including newlines, by a dsmr-mcp/ package designator. A
find-symbol name string may sit between the two.")

(defun %worker-closure-files ()
  "Source files of every dsmr-mcp/src/ system in the dependency closure of
dsmr-mcp/src/hermetic/worker/main."
  (let ((seen (make-hash-table :test #'equal))
        (files '()))
    (labels ((visit (name)
               (when (and (stringp name)
                          (uiop:string-prefix-p "dsmr-mcp/src/" name)
                          (not (gethash name seen)))
                 (setf (gethash name seen) t)
                 (let ((system (asdf:find-system name nil)))
                   (when system
                     (let ((source (find-if (lambda (c)
                                              (typep c 'asdf:cl-source-file))
                                            (asdf:component-children system))))
                       (when source
                         (pushnew (asdf:component-pathname source) files
                                  :test #'equal)))
                     (dolist (dep (asdf:system-depends-on system))
                       (visit (if (consp dep) (car (last dep)) dep))))))))
      (visit "dsmr-mcp/src/hermetic/worker/main"))
    files))

(defun %blank-comment-lines (text)
  "TEXT with every line whose first non-blank character is a semicolon emptied,
keeping the line count."
  (cl-ppcre:regex-replace-all "(?m)^[ \\t]*;.*$" text ""))

(defun %run-time-designators (file)
  "Each \"FILE:LINE\" where a run-time lookup names a dsmr-mcp/ package."
  (let ((text (%blank-comment-lines (uiop:read-file-string file)))
        (hits '()))
    (cl-ppcre:do-matches (start end *run-time-designator-scanner* text)
      (declare (ignore end))
      (push (format nil "~A:~D" (uiop:native-namestring file)
                    (1+ (count #\Newline text :end start)))
            hits))
    (nreverse hits)))

(define-test no-worker-file-names-a-dsmr-mcp-package-at-run-time
  "No file in the worker's closure looks up a dsmr-mcp/ package by name at run
time; such a lookup goes through support-package or support-symbol-call."
  (let ((files (%worker-closure-files)))
    (true (> (length files) 10) "worker closure has only ~D files" (length files))
    (true (find "connection" files :key #'pathname-name :test #'string=)
          "attach/connection.lisp is not in the worker closure")
    (let ((hits (mapcan #'%run-time-designators files)))
      (false hits "run-time dsmr-mcp/ package designators; use support-package:~{~%  ~A~}"
             hits))))
