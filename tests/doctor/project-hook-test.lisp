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
  (:import-from #:dsmr-mcp/src/project-hook
                #:+gate-hook-name+
                #:gate-hook-command
                #:gate-hook-path
                #:configured-hooks-supported-p
                #:gate-hook-wired-p
                #:wire-gate-hook)
  (:import-from #:dsmr-mcp/src/git
                #:run-git)
  (:import-from #:dsmr-mcp/tests/support/git-fixture
                #:with-temp-git-repo
                #:with-linked-worktree
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

(defun %run-gate (root gate &key (mallet (namestring (linter-path))) tmpdir)
  "Run GATE with ROOT as the working directory and MALLET naming the linter.
TMPDIR, when given, is the gate's TMPDIR.
Returns the combined output and the exit code."
  (multiple-value-bind (output error-output code)
      (uiop:run-program (append (list "/usr/bin/env"
                                      (format nil "MALLET=~A" mallet))
                                (when tmpdir
                                  (list (format nil "TMPDIR=~A"
                                                (string-right-trim
                                                 "/" (namestring tmpdir)))))
                                (list (namestring gate)))
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

;;; ---------------------------------------------------------------------------
;;; The blocking gate
;;; ---------------------------------------------------------------------------

(defparameter +clean-and-failing-source+
  "(defun clean-form (x)
  (+ x 1))

(defun failing-form (y)
  (ignore-errors (error \"bang\"))
  y)
"
  "A clean first form and a second form with one finding, on line 5.")

(defmacro with-ours-gate ((root gate &key (source '+two-form-source+))
                          &body body)
  "Bind ROOT to a fixture tracking lib.lisp holding SOURCE, and GATE to its
blocking gate."
  `(with-temp-git-repo (,root :initial-file "lib.lisp"
                              :initial-content ,source)
     (let ((,gate (%install-gate ,root (render-pre-commit-hook
                                         :profile :ours))))
       ,@body)))

(define-test the-blocking-gate-refuses-a-touched-failing-form
  "ALWAYS-PASS CONTROL. A touched form carrying a warning refuses the commit."
  (with-ours-gate (root gate)
    (%stage root "lib.lisp" (%edit-second-form))
    (multiple-value-bind (output code) (%run-gate root gate)
      (is = 1 code "the blocking gate refuses the commit: ~A" output)
      (if (gate-scanner-available-p)
          (true (%reports-p output "lib.lisp:6:")
                "the finding that refuses it is printed: ~A" output)
          (true (search "linter not found" output)
                "with no linter, the gate says so: ~A" output)))))

(define-test the-blocking-gate-lints-a-renamed-file
  "RENAME CONTROL. git diff detects renames by default, so a file moved with git
mv and edited is staged as a rename. The gate still lints it and refuses the
commit on the touched form's finding."
  (with-ours-gate (root gate)
    (run-git (list "mv" "lib.lisp" "moved.lisp") :directory root)
    (%stage root "moved.lisp" (%edit-second-form))
    (true (search "moved.lisp"
                  (run-git (list "diff" "--cached" "--name-status" "-M")
                           :directory root))
          "precondition: the change is staged")
    (multiple-value-bind (output code) (%run-gate root gate)
      (is = 1 code "the blocking gate refuses the commit: ~A" output)
      (if (gate-scanner-available-p)
          (true (%reports-p output "moved.lisp:6:")
                "the renamed file's finding is printed: ~A" output)
          (true (search "linter not found" output)
                "with no linter, the gate says so: ~A" output)))))

(define-test an-ambient-linter-config-does-not-disable-the-gate
  "AMBIENT-CONFIG CONTROL. The linter looks for a config upward from the file it
lints. A config that ignores every file, planted in the gate's TMPDIR, must not
reach the repository's lint: the blocking gate still refuses the touched
failing form."
  (let ((ambient (dsmr-mcp/tests/support/fs-fixture:%make-temp-directory)))
    (unwind-protect
         (progn
           (write-fixture-file ambient ".mallet.lisp"
                               "(:mallet-config
 (:ignore \"**/*.lisp\"))
")
           (with-ours-gate (root gate)
             (%stage root "lib.lisp" (%edit-second-form))
             (multiple-value-bind (output code)
                 (%run-gate root gate :tmpdir ambient)
               (is = 1 code "the blocking gate refuses the commit: ~A" output)
               (when (gate-scanner-available-p)
                 (true (%reports-p output "lib.lisp:6:")
                       "the finding is printed: ~A" output)))))
      (uiop:delete-directory-tree ambient :validate t
                                          :if-does-not-exist :ignore))))

(define-test a-file-the-linter-cannot-name-is-never-passed-silently
  "GLOB-NAME CONTROL. The linter reads a wildcard character in an argument as a
pattern and prints such a name escaped, so its findings cannot be attributed to
the file. The blocking gate refuses the commit instead of passing it with no
findings; the informational gate lets it through and says the file was
skipped."
  (let ((name "a*b.lisp"))
    (flet ((write-native (root content)
             ;; A Lisp namestring reads * as a wildcard; write by native name.
             (with-open-file (out (uiop:parse-native-namestring
                                   (concatenate 'string (namestring root) name))
                                  :direction :output :if-exists :supersede
                                  :if-does-not-exist :create
                                  :element-type 'character)
               (write-string content out))
             (run-git (list "add" "--" name) :directory root)))
      (dolist (case '((:ours 1) (:foreign 0)))
        (destructuring-bind (profile expected) case
          (with-temp-git-repo (root :initial-file "lib.lisp"
                                    :initial-content +two-form-source+)
            (let ((gate (%install-gate root (render-pre-commit-hook
                                             :profile profile))))
              (write-native root +two-form-source+)
              (run-git (list "commit" "-q" "-m" "glob name") :directory root)
              (write-native root (%edit-second-form))
              (multiple-value-bind (output code) (%run-gate root gate)
                (is = expected code "~S: exit status: ~A" profile output)
                (when (gate-scanner-available-p)
                  (true (search "skipped" output)
                        "~S: the output says the file was skipped: ~A"
                        profile output))))))))))

(define-test a-textconv-driver-does-not-move-the-touched-form
  "TEXTCONV CONTROL. A diff driver whose textconv prepends four lines shifts the
hunk line numbers of a plain git diff. The gate reads the staged blob's own
line numbers, so an edit to the first form still reports line 2 and not the
second form's line 6."
  (with-foreign-gate (root gate)
    (write-fixture-file root ".git/info/attributes" "*.lisp diff=shift
")
    (run-git (list "config" "--local" "diff.shift.textconv"
                   "sh -c 'printf \"\\n\\n\\n\\n\"; cat \"$1\"' textconv")
             :directory root)
    (%stage root "lib.lisp" (%edit-first-form))
    (true (search "@@ -5"
                  (run-git (list "diff" "--cached" "-U0" "--" "lib.lisp")
                           :directory root))
          "precondition: the driver shifts the plain diff's hunk")
    (multiple-value-bind (output code) (%run-gate root gate)
      (is = 0 code "the informational gate lets the commit through: ~A" output)
      (when (gate-scanner-available-p)
        (true (%reports-p output "lib.lisp:2:")
              "the touched form's finding is reported: ~A" output)
        (false (%reports-p output "lib.lisp:6:")
               "the untouched form's finding is not reported: ~A" output)))))

(define-test the-blocking-gate-passes-when-only-untouched-forms-fail
  "Touching only the clean form lets the commit through although the other form
in the same file carries a finding."
  (with-ours-gate (root gate :source +clean-and-failing-source+)
    (%stage root "lib.lisp"
            (%edit-line +clean-and-failing-source+ 1
                        "(defun clean-form-renamed (x)"))
    (multiple-value-bind (output code) (%run-gate root gate)
      (if (gate-scanner-available-p)
          (progn
            (is = 0 code "the commit proceeds: ~A" output)
            (is = 0 (length (%finding-lines output))
                "no finding line is printed: ~A" output))
          (progn
            (is = 1 code "with no linter, the blocking gate refuses: ~A" output)
            (true (search "linter not found" output)
                  "with no linter, the gate says so: ~A" output))))))

(define-test a-finding-lowered-to-info-is-printed-and-passes
  "With the planted rule lowered to info by the repository's .mallet.lisp, the
blocking gate prints the finding and lets the commit through."
  (with-ours-gate (root gate)
    (fixture-commit-file root ".mallet.lisp"
                         "(:mallet-config
 (:extends :default)
 (:enable :no-ignore-errors :severity :info))
")
    (%stage root "lib.lisp" (%edit-second-form))
    (multiple-value-bind (output code) (%run-gate root gate)
      (if (gate-scanner-available-p)
          (progn
            (is = 0 code "an info finding does not refuse: ~A" output)
            (true (%reports-p output "lib.lisp:6:")
                  "the info finding is still printed: ~A" output)
            (true (search ": info: " output)
                  "it is printed at info severity: ~A" output))
          (true (search "linter not found" output)
                "with no linter, the gate says so: ~A" output)))))

(define-test the-blocking-gate-refuses-without-a-linter
  "With MALLET naming a missing path, the blocking gate exits 1 and names the
single-commit bypass."
  (with-ours-gate (root gate)
    (%stage root "lib.lisp" (%edit-second-form))
    (let ((missing (namestring (merge-pathnames "no-linter-here"
                                                (uiop:ensure-directory-pathname
                                                 root)))))
      (multiple-value-bind (output code) (%run-gate root gate :mallet missing)
        (is = 1 code "the blocking gate refuses: ~A" output)
        (true (search "linter not found" output)
              "the output says the linter was not found: ~A" output)
        (true (search "git commit --no-verify" output)
              "the output names the single-commit bypass: ~A" output)))))

;;; ---------------------------------------------------------------------------
;;; Wiring through git's configured hooks
;;; ---------------------------------------------------------------------------

(defun %local-config (root)
  "Return the repository-local config at ROOT as git config --list prints it."
  (values (run-git (list "config" "--local" "--list") :directory root)))

(defun %hook-list-lines (root)
  "Return the lines git hook list prints for pre-commit at ROOT."
  (%lines (run-git (list "hook" "list" "pre-commit")
                   :directory root :error-on-failure nil)))

(defun %file-octets (path)
  "Return the contents of PATH as an octet vector."
  (with-open-file (in path :element-type '(unsigned-byte 8))
    (let ((octets (make-array (file-length in)
                              :element-type '(unsigned-byte 8))))
      (read-sequence octets in)
      octets)))

(defun %commit (root &key (mallet (namestring (linter-path))))
  "Run git commit at ROOT with MALLET naming the linter.
Returns the combined output and the exit code."
  (multiple-value-bind (output error-output code)
      (uiop:run-program (list "/usr/bin/env" (format nil "MALLET=~A" mallet)
                              "git" "-C" (namestring root)
                              "commit" "-q" "-m" "edit")
                        :output :string
                        :error-output :output
                        :ignore-error-status t)
    (declare (ignore error-output))
    (values output code)))

(define-test wiring-a-repository-with-no-hooks
  "The first call creates the two entries and git lists the gate; the second
answers :already-present and changes no config entry."
  (with-temp-git-repo (root :initial-file "lib.lisp"
                            :initial-content +two-form-source+)
    (if (not (configured-hooks-supported-p root))
        (is eq :not-wired (getf (wire-gate-hook root) :action-taken)
            "a git without configured hooks is reported as not wired")
        (let ((created (wire-gate-hook root)))
          (is eq :created (getf created :action-taken) "~S" created)
          (true (uiop:string-suffix-p (namestring (getf created :path))
                                      "config")
                "the report names the local config file: ~S" created)
          (true (member +gate-hook-name+ (%hook-list-lines root)
                        :test #'string=)
                "git hook list names the gate: ~S" (%hook-list-lines root))
          (true (gate-hook-wired-p root) "the gate reads as wired")
          (let* ((before (%local-config root))
                 (again (wire-gate-hook root)))
            (is eq :already-present (getf again :action-taken) "~S" again)
            (is string= before (%local-config root)
                "the second call changes no config entry"))))))

(define-test wiring-leaves-an-existing-hookdir-hook-untouched
  "An executable pre-commit already in the hooks directory is byte-identical
after wiring, and git lists both it and the gate."
  (with-temp-git-repo (root :initial-file "lib.lisp"
                            :initial-content +two-form-source+)
    (let ((existing (merge-pathnames ".git/hooks/pre-commit"
                                     (uiop:ensure-directory-pathname root))))
      (ensure-directories-exist existing)
      (with-open-file (out existing :direction :output :if-exists :supersede
                                    :if-does-not-exist :create
                                    :element-type 'character)
        (write-string (format nil "#!/bin/sh~%# somebody else's hook~%exit 0~%")
                      out))
      (uiop:run-program (list "chmod" "+x" (namestring existing)))
      (let ((before (%file-octets existing))
            (report (wire-gate-hook root)))
        (is equalp before (%file-octets existing)
            "the existing hook is byte-identical after wiring")
        (if (not (configured-hooks-supported-p root))
            (is eq :not-wired (getf report :action-taken) "~S" report)
            (let ((listed (%hook-list-lines root)))
              (is eq :created (getf report :action-taken) "~S" report)
              (true (member +gate-hook-name+ listed :test #'string=)
                    "git lists the gate: ~S" listed)
              (true (member "hook from hookdir" listed :test #'string=)
                    "git still lists the hookdir hook: ~S" listed)))))))

(define-test a-differing-existing-entry-is-reported-never-replaced
  "A command entry set to another value, or the gate disabled, is reported as
:not-wired with a reason, and the config is left as it was found."
  (dolist (setting (list (list "hook.lisp-gate.command" "echo somebody-else")
                         (list "hook.lisp-gate.enabled" "false")))
    (with-temp-git-repo (root :initial-file "lib.lisp"
                              :initial-content +two-form-source+)
      (run-git (list* "config" "--local" setting) :directory root)
      (let* ((before (%local-config root))
             (report (wire-gate-hook root)))
        (is eq :not-wired (getf report :action-taken)
            "~A set elsewhere: ~S" (first setting) report)
        (true (stringp (getf report :reason))
              "the report says why: ~S" report)
        (is string= before (%local-config root)
            "the config is unchanged after ~A" (first setting))
        (false (gate-hook-wired-p root)
               "the gate does not read as wired with ~A" (first setting))))))

(define-test a-dry-run-writes-nothing
  "DRY-RUN answers :would-create and leaves the config unchanged."
  (with-temp-git-repo (root :initial-file "lib.lisp"
                            :initial-content +two-form-source+)
    (let* ((before (%local-config root))
           (report (wire-gate-hook root :dry-run t)))
      (if (configured-hooks-supported-p root)
          (is eq :would-create (getf report :action-taken) "~S" report)
          (is eq :not-wired (getf report :action-taken) "~S" report))
      (is string= before (%local-config root) "the config is unchanged")
      (false (gate-hook-wired-p root) "the gate does not read as wired"))))

(define-test wired-means-listed-enabled-with-the-expected-command
  "DISABLED-PREFIX CONTROL. gate-hook-wired-p is true after wiring, false once
the gate is disabled (git then lists it with a disabled prefix), and false when
the command entry differs."
  (with-temp-git-repo (root :initial-file "lib.lisp"
                            :initial-content +two-form-source+)
    (if (not (configured-hooks-supported-p root))
        (false (gate-hook-wired-p root)
               "a git without configured hooks never reads as wired")
        (progn
          (wire-gate-hook root)
          (true (gate-hook-wired-p root) "wired after wire-gate-hook")
          (run-git (list "config" "--local" "hook.lisp-gate.enabled" "false")
                   :directory root)
          (true (find-if (lambda (line) (uiop:string-prefix-p "disabled" line))
                         (%hook-list-lines root))
                "precondition: git lists the gate as disabled: ~S"
                (%hook-list-lines root))
          (false (gate-hook-wired-p root) "a disabled gate is not wired")
          (run-git (list "config" "--local" "--unset" "hook.lisp-gate.enabled")
                   :directory root)
          (true (gate-hook-wired-p root) "re-enabled, it is wired again")
          (run-git (list "config" "--local" "hook.lisp-gate.command"
                         "echo somebody-else")
                   :directory root)
          (false (gate-hook-wired-p root)
                 "a differing command entry is not wired")))))

(define-test the-wired-gate-runs-at-commit
  "End to end through git commit. The informational gate lets a commit touching
a failing form through and names the finding; the blocking gate refuses it and
HEAD does not move."
  (dolist (case '((:foreign 0) (:ours 1)))
    (destructuring-bind (profile expected) case
      (with-temp-git-repo (root :initial-file "lib.lisp"
                                :initial-content +two-form-source+)
        (%install-gate root (render-pre-commit-hook :profile profile))
        (let ((report (wire-gate-hook root))
              (head (run-git (list "rev-parse" "HEAD") :directory root)))
          (if (not (configured-hooks-supported-p root))
              (is eq :not-wired (getf report :action-taken) "~S" report)
              (progn
                (true (probe-file (gate-hook-path root))
                      "the gate is installed where the command points")
                (%stage root "lib.lisp" (%edit-second-form))
                (multiple-value-bind (output code) (%commit root)
                  (cond
                    ((not (gate-scanner-available-p))
                     (true (search "linter not found" output)
                           "~S: with no linter, the gate says so: ~A"
                           profile output))
                    ((zerop expected)
                     (is = 0 code "~S: the commit succeeds: ~A" profile output)
                     (true (search "lib.lisp:6:" output)
                           "~S: the output names the finding: ~A"
                           profile output)
                     (false (string= head (run-git (list "rev-parse" "HEAD")
                                                   :directory root))
                            "~S: HEAD moved" profile))
                    (t
                     (false (zerop code)
                            "~S: the commit is refused: ~A" profile output)
                     (true (search "lib.lisp:6:" output)
                           "~S: the output names the finding: ~A"
                           profile output)
                     (is string= head (run-git (list "rev-parse" "HEAD")
                                               :directory root)
                         "~S: HEAD did not move" profile)))))))))))

(defun %install-gate-at (path text)
  "Write TEXT to PATH, make it executable, and return PATH."
  (ensure-directories-exist path)
  (with-open-file (out path :direction :output :if-exists :supersede
                            :if-does-not-exist :create
                            :element-type 'character)
    (write-string text out))
  (uiop:run-program (list "chmod" "+x" (namestring path)))
  path)

(define-test one-wiring-serves-every-worktree
  "LINKED-WORKTREE CONTROL. git config --local writes the config every worktree
shares, so the gate installed and wired from one worktree must run from all of
them. Installed from the linked worktree, a commit in the main worktree
succeeds, and the reverse; each commit stages a non-Lisp file, so only a
missing or unrunnable gate can refuse it."
  (dolist (installer '(:linked :main))
    (with-temp-git-repo (root :initial-file "lib.lisp"
                              :initial-content +two-form-source+)
      (with-linked-worktree (worktree root)
        (if (not (configured-hooks-supported-p root))
            (is eq :not-wired (getf (wire-gate-hook root) :action-taken))
            (let ((from (if (eq installer :linked) worktree root)))
              (%install-gate-at (gate-hook-path from)
                                (render-pre-commit-hook :profile :foreign))
              (wire-gate-hook from)
              (true (probe-file (gate-hook-path worktree))
                    "from ~(~A~): the linked worktree resolves the gate" installer)
              (true (probe-file (gate-hook-path root))
                    "from ~(~A~): the main worktree resolves the gate" installer)
              (dolist (where (list root worktree))
                (%stage where "notes.txt" (namestring where))
                (multiple-value-bind (output code) (%commit where)
                  (is = 0 code "wired from the ~(~A~) worktree, a commit in ~A succeeds: ~A"
                      installer where output)))))))))

(define-test a-missing-gate-script-follows-the-profile
  "With the wiring in place and the script removed, the informational wiring
lets the commit through and the blocking wiring refuses it. Each prints one
line naming where it looked."
  (dolist (case '((:foreign 0) (:ours 1)))
    (destructuring-bind (profile expected) case
      (with-temp-git-repo (root :initial-file "lib.lisp"
                                :initial-content +two-form-source+)
        (if (not (configured-hooks-supported-p root))
            (is eq :not-wired (getf (wire-gate-hook root :profile profile)
                                    :action-taken))
            (progn
              (wire-gate-hook root :profile profile)
              (false (probe-file (gate-hook-path root))
                     "precondition: no gate script is installed")
              (%stage root "notes.txt" "notes")
              (multiple-value-bind (output code) (%commit root)
                (is = expected code "~S: exit status: ~A" profile output)
                (true (search "lisp-gate: no gate at" output)
                      "~S: the output says the gate is missing: ~A"
                      profile output))))))))
