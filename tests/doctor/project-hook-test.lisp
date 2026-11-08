;;;; tests/doctor/project-hook-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Zebra tests for the lint gate over real git repositories and the real
;;;; linter.
;;;;
;;;; The gate is rendered, written under the fixture's git directory, and run
;;;; as a program against a staged change, so what is asserted is what a
;;;; developer sees at commit time. The linter may be absent on a build host:
;;;; the tests needing it branch on GATE-SCANNER-AVAILABLE-P and assert what
;;;; the gate does without it.

;; Package evolution guard - delete prior definition on warm reload.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/doctor/project-hook-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/doctor/project-hook-test
  (:use #:cl #:zebra)
  (:import-from #:dsmr-mcp/src/project-debt
                #:render-pre-commit-hook)
  (:import-from #:dsmr-mcp/src/project-gate-scan
                #:linter-path
                #:gate-scanner-available-p)
  (:import-from #:dsmr-mcp/src/git
                #:run-git)
  (:import-from #:dsmr-mcp/tests/support/git-fixture
                #:with-temp-git-repo
                #:fixture-commit-file)
  (:import-from #:dsmr-mcp/tests/support/fs-fixture
                #:write-fixture-file))

(in-package #:dsmr-mcp/tests/doctor/project-hook-test)

;;; ---------------------------------------------------------------------------
;;; Fixtures
;;; ---------------------------------------------------------------------------

(defparameter +two-form-source+
  "(defun first-form (x)
  (ignore-errors (error \"boom\"))
  x)

(defun second-form (y)
  (ignore-errors (error \"bang\"))
  y)
"
  "Two top-level forms, each with one default-preset finding on its second line.
The findings sit at lines 2 and 6; each form's first line is finding-free.")

(defun %edit-line (source line-number new-line)
  "Return SOURCE with line LINE-NUMBER (1-based) replaced by NEW-LINE."
  (with-output-to-string (out)
    (with-input-from-string (in source)
      (loop for n from 1
            for line = (read-line in nil)
            while line
            do (write-string (if (= n line-number) new-line line) out)
               (terpri out)))))

(defun %edit-first-form ()
  "Return the fixture source with only the first form's first line changed."
  (%edit-line +two-form-source+ 1 "(defun first-form-renamed (x)"))

(defun %edit-second-form ()
  "Return the fixture source with only the second form's first line changed."
  (%edit-line +two-form-source+ 5 "(defun second-form-renamed (y)"))

(defun %stage (root relative-path content)
  "Write CONTENT to RELATIVE-PATH under ROOT and stage it."
  (write-fixture-file root relative-path content)
  (run-git (list "add" "--" relative-path) :directory root))

(defun %install-gate (root text)
  "Write TEXT to ROOT/.git/hooks/lisp-gate, make it executable, return its path."
  (let ((path (merge-pathnames ".git/hooks/lisp-gate"
                               (uiop:ensure-directory-pathname root))))
    (ensure-directories-exist path)
    (with-open-file (out path :direction :output :if-exists :supersede
                              :if-does-not-exist :create
                              :element-type 'character)
      (write-string text out))
    (uiop:run-program (list "chmod" "+x" (namestring path)))
    path))

(defun %run-gate (root gate &key (mallet (namestring (linter-path))))
  "Run GATE with ROOT as the working directory and MALLET naming the linter.
Returns the combined output and the exit code."
  (multiple-value-bind (output error-output code)
      (uiop:run-program (list "/usr/bin/env" (format nil "MALLET=~A" mallet)
                              (namestring gate))
                        :directory (namestring root)
                        :output :string
                        :error-output :output
                        :ignore-error-status t)
    (declare (ignore error-output))
    (values output code)))

(defun %lines (text)
  "Return the non-empty lines of TEXT."
  (remove "" (uiop:split-string text :separator '(#\Newline))
          :test #'string=))

(defun %finding-lines (output)
  "Return the lines of OUTPUT that report a finding, i.e. all but the gate's own."
  (remove-if (lambda (line) (uiop:string-prefix-p "lisp-gate:" line))
             (%lines output)))

(defun %reports-p (output prefix)
  "Return true when a finding line of OUTPUT starts with PREFIX."
  (and (find-if (lambda (line) (uiop:string-prefix-p prefix line))
                (%finding-lines output))
       t))

(defmacro with-foreign-gate ((root gate) &body body)
  "Bind ROOT to a fixture tracking lib.lisp and GATE to its informational gate."
  `(with-temp-git-repo (,root :initial-file "lib.lisp"
                              :initial-content +two-form-source+)
     (let ((,gate (%install-gate ,root (render-pre-commit-hook
                                         :profile :foreign))))
       ,@body)))

;;; ---------------------------------------------------------------------------
;;; The informational gate
;;; ---------------------------------------------------------------------------

(define-test the-informational-gate-reports-only-the-touched-form
  "FORM-SCOPE CONTROL. The edit is on the second form's first line and the
finding is on its second, so a gate scoped to changed lines reports nothing.
The first form's finding must not appear."
  (with-foreign-gate (root gate)
    (%stage root "lib.lisp" (%edit-second-form))
    (multiple-value-bind (output code) (%run-gate root gate)
      (is = 0 code "the informational gate lets the commit through: ~A" output)
      (if (gate-scanner-available-p)
          (progn
            (true (%reports-p output "lib.lisp:6:")
                  "the touched form's finding is reported: ~A" output)
            (false (%reports-p output "lib.lisp:2:")
                   "the untouched form's finding is not reported: ~A" output)
            (is = 1 (length (%finding-lines output))
                "exactly one finding is reported: ~A" output))
          (true (search "linter not found" output)
                "with no linter, the gate says so: ~A" output)))))

(define-test editing-the-other-form-reports-the-other-finding
  "The same fixture with the first form edited reports line 2 and not line 6."
  (with-foreign-gate (root gate)
    (%stage root "lib.lisp" (%edit-first-form))
    (multiple-value-bind (output code) (%run-gate root gate)
      (is = 0 code "the informational gate lets the commit through: ~A" output)
      (if (gate-scanner-available-p)
          (progn
            (true (%reports-p output "lib.lisp:2:")
                  "the touched form's finding is reported: ~A" output)
            (false (%reports-p output "lib.lisp:6:")
                   "the untouched form's finding is not reported: ~A" output))
          (true (search "linter not found" output)
                "with no linter, the gate says so: ~A" output)))))

(define-test no-staged-lisp-file-reports-nothing
  "A staged change holding no Lisp file prints no finding and exits 0."
  (with-foreign-gate (root gate)
    (%stage root "README.md" "notes")
    (multiple-value-bind (output code) (%run-gate root gate)
      (is = 0 code "the gate exits 0: ~A" output)
      (is = 0 (length (%finding-lines output))
          "no finding line is printed: ~A" output))))

(define-test a-missing-linter-is-one-line-and-exit-zero
  "With MALLET naming a path that does not exist, the informational gate prints
one line saying so and lets the commit through."
  (with-foreign-gate (root gate)
    (%stage root "lib.lisp" (%edit-second-form))
    (let ((missing (namestring (merge-pathnames "no-linter-here"
                                                (uiop:ensure-directory-pathname
                                                 root)))))
      (multiple-value-bind (output code) (%run-gate root gate :mallet missing)
        (is = 0 code "the informational gate exits 0: ~A" output)
        (is = 1 (length (%lines output)) "exactly one line: ~A" output)
        (true (search "linter not found" output)
              "the line says the linter was not found: ~A" output)))))

(define-test a-hostile-file-name-is-linted-and-never-evaluated
  "INJECTION CONTROL. A staged file whose name holds a space, a semicolon and a
dollar-parenthesis sequence is reported under that name, and the canary the
name would create if evaluated does not exist afterwards."
  (let ((name "odd name; $(touch canary).lisp"))
    (with-foreign-gate (root gate)
      (fixture-commit-file root name +two-form-source+)
      (%stage root name (%edit-second-form))
      (multiple-value-bind (output code) (%run-gate root gate)
        (is = 0 code "the gate exits 0: ~A" output)
        (if (gate-scanner-available-p)
            (true (%reports-p output (format nil "~A:6:" name))
                  "the finding is reported under the file's own name: ~A"
                  output)
            (true (search "linter not found" output)
                  "with no linter, the gate says so: ~A" output))
        (false (probe-file (merge-pathnames "canary"
                                            (uiop:ensure-directory-pathname
                                             root)))
               "no canary in the repository root")
        (false (probe-file (merge-pathnames "canary"
                                            (uiop:temporary-directory)))
               "no canary in the temporary directory")))))
