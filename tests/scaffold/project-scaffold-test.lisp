;;;; tests/scaffold/project-scaffold-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Zebra tests for the project-scaffold verb (VERB-22).
;;;; Covers: validator accept/reject, manifest rendering, e2e
;;;; load-system smoke, write-jail rejection, debris-free failure.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/scaffold/project-scaffold-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/scaffold/project-scaffold-test
  (:use #:cl #:zebra)
  (:import-from #:dsmr-mcp/src/project-scaffold-core
                #:validate-project-name
                #:validate-destination
                #:validate-text-field
                #:render-template
                #:plan-scaffold
                #:invalid-argument-error
                #:invalid-argument-field
                #:invalid-argument-reason)
  (:import-from #:dsmr-mcp/src/project-scaffold
                #:write-scaffold)
  (:import-from #:dsmr-mcp/tests/support/fs-fixture
                #:with-temp-project-root)
  (:import-from #:alexandria
                #:read-file-into-string))

(in-package #:dsmr-mcp/tests/scaffold/project-scaffold-test)

;;; --- project-name validation ------------------------------------------------

(define-test project-name-accepts-valid-names
  "validate-project-name passes well-formed names through."
  (true (validate-project-name "my-proj"))
  (true (validate-project-name "a"))
  (true (validate-project-name "foo123"))
  (true (validate-project-name "foo-bar-baz")))

(define-test project-name-rejects-leading-digit
  "validate-project-name rejects names starting with a digit."
  (fail (validate-project-name "9bad") 'invalid-argument-error))

(define-test project-name-rejects-uppercase
  "validate-project-name rejects names containing uppercase letters."
  (fail (validate-project-name "Has-Caps") 'invalid-argument-error))

(define-test project-name-rejects-overlong
  "validate-project-name rejects names longer than 64 characters."
  (fail (validate-project-name (make-string 65 :initial-element #\a))
        'invalid-argument-error))

(define-test project-name-rejects-non-string
  "validate-project-name rejects non-string input."
  (fail (validate-project-name :keyword) 'invalid-argument-error))

;;; --- destination validation -------------------------------------------------

(define-test destination-accepts-relative-path
  "validate-destination accepts a plain relative directory name."
  (true (validate-destination "scaffolds"))
  (true (validate-destination "work/samples")))

(define-test destination-rejects-absolute-path
  "validate-destination rejects a leading-slash (absolute) path (T-11-01)."
  (fail (validate-destination "/tmp/foo") 'invalid-argument-error))

(define-test destination-rejects-dotdot-segment
  "validate-destination rejects any path segment that is '..' (T-11-01)."
  (fail (validate-destination "../outside") 'invalid-argument-error)
  (fail (validate-destination "scaffolds/../..") 'invalid-argument-error))

;;; --- text-field validation --------------------------------------------------

(define-test text-field-accepts-normal-string
  "validate-text-field passes an ordinary single-line string."
  (true (validate-text-field "author" "Ada Lovelace"))
  (true (validate-text-field "description" "")))

(define-test text-field-rejects-newline
  "validate-text-field rejects a value containing a newline (T-11-04)."
  (fail (validate-text-field "author" (format nil "Ada~%Lovelace"))
        'invalid-argument-error))

(define-test text-field-rejects-carriage-return
  "validate-text-field rejects a value containing a carriage return (T-11-04)."
  (fail (validate-text-field "description" (format nil "foo~Abar" #\Return))
        'invalid-argument-error))

;;; --- manifest rendering (via plan-scaffold) ---------------------------------

(define-test scaffold-manifest-no-unresolved-placeholders
  "scaffold manifest renders every {{key}} — no unresolved placeholders remain."
  (let ((manifest (plan-scaffold :name "test-proj"
                                 :description "A test project"
                                 :author "Test Author"
                                 :license "AGPL-3.0-or-later"
                                 :copyright "Test Author"
                                 :year "2026"
                                 :destination "scaffolds")))
    (dolist (entry manifest)
      (false (search "{{" (cdr entry))
             (format nil "Unresolved placeholder found in ~A" (car entry))))))

(define-test scaffold-default-license-spdx-header
  "Scaffold emits AGPL-3.0-or-later SPDX header for the default license."
  (let ((manifest (plan-scaffold :name "agpl-proj"
                                 :description "AGPL test"
                                 :author "Tester"
                                 :license "AGPL-3.0-or-later"
                                 :copyright "Tester"
                                 :year "2026"
                                 :destination "scaffolds")))
    (let ((asd (cdr (assoc "agpl-proj.asd" manifest :test #'string=))))
      (true asd ".asd entry not found in manifest")
      (true (search "SPDX-License-Identifier: AGPL-3.0-or-later" asd)
            ".asd does not contain AGPL SPDX header"))))

(define-test scaffold-mit-license-spdx-header
  "Scaffold emits MIT SPDX header when license MIT is passed."
  (let ((manifest (plan-scaffold :name "mit-proj"
                                 :description "MIT test"
                                 :author "Tester"
                                 :license "MIT"
                                 :copyright "Tester"
                                 :year "2026"
                                 :destination "scaffolds")))
    (let ((asd (cdr (assoc "mit-proj.asd" manifest :test #'string=))))
      (true asd ".asd entry not found in manifest")
      (true (search "SPDX-License-Identifier: MIT" asd)
            ".asd does not contain MIT SPDX header"))))

(define-test scaffold-manifest-is-string-alist
  "plan-scaffold returns an alist of (relative-path . content) string pairs."
  (let ((manifest (plan-scaffold :name "alist-proj"
                                 :description "alist test"
                                 :author "Tester"
                                 :license "MIT"
                                 :copyright "Tester"
                                 :year "2026"
                                 :destination "scaffolds")))
    (true (consp manifest) "manifest is not a cons")
    (dolist (entry manifest)
      (true (consp entry) "entry is not a cons")
      (true (stringp (car entry)) "key is not a string")
      (true (stringp (cdr entry)) "content is not a string"))))

(define-test scaffold-manifest-covers-required-files
  "Scaffold manifest covers the required D-17 files."
  (let* ((manifest (plan-scaffold :name "full-proj"
                                  :description "full test"
                                  :author "Tester"
                                  :license "MIT"
                                  :copyright "Tester"
                                  :year "2026"
                                  :destination "scaffolds"))
         (keys (mapcar #'car manifest)))
    (true (find "full-proj.asd" keys :test #'string=) ".asd missing")
    (true (find "src/main.lisp" keys :test #'string=) "src/main.lisp missing")
    (true (find "AGENTS.md" keys :test #'string=) "AGENTS.md missing")
    (true (find "CLAUDE.md" keys :test #'string=) "CLAUDE.md missing")
    (true (find "README.md" keys :test #'string=) "README.md missing")
    (true (find ".gitignore" keys :test #'string=) ".gitignore missing")
    (true (find "prompts/repl-driven-development.md" keys :test #'string=)
          "prompts/repl-driven-development.md missing (D-12: self-contained prompt)")
    (true (find "LICENSE" keys :test #'string=) "LICENSE missing")))

(define-test scaffold-copies-prompt-into-tree
  "The scaffold bakes the dsmr-discipline prompt into the project itself (D-12),
so the generated CLAUDE.md/AGENTS.md @-include resolves locally with no
parent-pointing path."
  (let* ((manifest (plan-scaffold :name "promptful"
                                  :description "prompt test"
                                  :author "Tester"
                                  :license "AGPL-3.0-or-later"
                                  :copyright "Tester"
                                  :year "2026"
                                  :destination "scaffolds"))
         (prompt (cdr (assoc "prompts/repl-driven-development.md" manifest
                             :test #'string=)))
         (claude (cdr (assoc "CLAUDE.md" manifest :test #'string=))))
    (true prompt "prompt entry missing from manifest")
    ;; The copied prompt carries the dsmr biases, not a bare stub.
    (true (search "DSMR biases" prompt) "prompt missing the conventions section")
    (false (search "{{name}}" prompt) "prompt has an unrendered placeholder")
    ;; CLAUDE.md points at the project-local prompt, never a parent path.
    (true (search "@prompts/repl-driven-development.md" claude)
          "CLAUDE.md @-include is not project-local")
    (false (search ".." claude) "CLAUDE.md still contains a parent-pointing path")))

;;; --- write-scaffold: outside-root jail rejection (T-11-02) ------------------

(define-test write-scaffold-rejects-outside-root-destination
  "write-scaffold with a '..' destination signals an error and leaves no .tmp-* debris."
  (with-temp-project-root (session root)
    (handler-case
        (progn
          (write-scaffold :session-root root
                          :name "jail-test"
                          :description "jail test"
                          :author "Tester"
                          :license "MIT"
                          :copyright "Tester"
                          :year "2026"
                          :destination "../outside")
          ;; Should not reach here
          (fail "write-scaffold should have signaled an error"))
      (error ()
        ;; Error was raised — now verify no debris under root
        (let* ((root-entries (uiop:subdirectories root))
               (tmp-dirs (remove-if-not
                          (lambda (p)
                            (let ((seg (car (last (pathname-directory p)))))
                              (and (stringp seg)
                                   (uiop:string-prefix-p ".tmp-" seg))))
                          root-entries)))
          (true (null tmp-dirs)
                (format nil "Debris found: ~S" tmp-dirs)))))))

;;; --- e2e: write-scaffold + load-system + smoke test (success criterion 1) ---

(define-test scaffold-e2e-load-and-smoke
  "A fresh scaffold load-systems clean AND its Zebra smoke test passes."
  (with-temp-project-root (session root)
    (let* ((result (write-scaffold :session-root root
                                   :name "e2e-smoke"
                                   :description "e2e smoke test project"
                                   :author "Test"
                                   :license "MIT"
                                   :copyright "Test"
                                   :year "2026"
                                   :destination "scaffolds"))
           (target-dir (getf result :target-dir))
           (asd-path   (merge-pathnames "e2e-smoke.asd" target-dir)))
      (true target-dir "write-scaffold did not return :target-dir")
      (true (uiop:directory-exists-p target-dir)
            "scaffold target directory was not created")
      (true (probe-file asd-path) "generated .asd not found")
      ;; The project is self-contained: the prompt the agent docs @-include is
      ;; written into the tree, no session-root stub required (D-12).
      (true (probe-file (merge-pathnames "prompts/repl-driven-development.md"
                                         target-dir))
            "generated project is missing its own prompts/ copy")
      (asdf:load-asd asd-path)
      (unwind-protect
           (progn
             (asdf:load-system "e2e-smoke")
             (asdf:load-system "e2e-smoke/tests")
             (let* ((pkg (find-package (string-upcase "e2e-smoke/tests/main-test")))
                    (run-result (when pkg
                                  (uiop:symbol-call :zebra :test pkg))))
               (true pkg "generated test package not loaded")
               (when run-result
                 (false (uiop:symbol-call :zebra :results-with-status
                                          :failed run-result)
                        "generated smoke test reported failures"))))
        (ignore-errors (asdf:clear-system "e2e-smoke/tests/main-test"))
        (ignore-errors (asdf:clear-system "e2e-smoke/tests"))
        (ignore-errors (asdf:clear-system "e2e-smoke"))))))

(define-test scaffold-no-debris-on-failure
  "A failed scaffold leaves no .tmp-* debris in the session root (T-11-03)."
  (with-temp-project-root (session root)
    (ignore-errors
      ;; Name validation will fail — unwind-protect must clean up temp dir.
      (write-scaffold :session-root root
                      :name "BadName"
                      :description "d"
                      :author "a"
                      :license "MIT"
                      :copyright "a"
                      :year "2026"
                      :destination "scaffolds"))
    ;; Verify no .tmp- prefix dirs remain
    (let* ((scaffolds-dir (merge-pathnames "scaffolds/" root))
           (tmp-dirs (when (uiop:directory-exists-p scaffolds-dir)
                       (remove-if-not
                        (lambda (p)
                          (let ((seg (car (last (pathname-directory p)))))
                            (and (stringp seg)
                                 (uiop:string-prefix-p ".tmp-" seg))))
                        (uiop:subdirectories scaffolds-dir)))))
      (true (null tmp-dirs)
            (format nil "Debris found after failed scaffold: ~S" tmp-dirs)))))
