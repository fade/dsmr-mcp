;;;; tests/git/git-primitives-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Zebra tests for the typed git subprocess primitives.
;;;;
;;;; Most of what is asserted about adopting a repository is an ABSENCE: no
;;;; apparatus file tracked, no change on a second run, no remote configured.
;;;; An absence assertion passes just as readily when it is pointed at nothing
;;;; at all, so every negative assertion here is paired with a positive one in
;;;; the same test, and its docstring says which property it protects. A check
;;;; nobody has watched fail is not evidence.

;; Package evolution guard - delete prior definition on warm reload.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/git/git-primitives-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/git/git-primitives-test
  (:use #:cl #:zebra)
  (:import-from #:sb-posix)
  (:import-from #:dsmr-mcp/src/git
                #:run-git
                #:git-command-error
                #:git-command-error-argv
                #:git-command-error-exit-code
                #:git-command-error-stderr
                #:git-repository-p
                #:git-toplevel
                #:git-remote-url
                #:git-remote-add
                #:git-tracked-files
                #:git-head-sha
                #:git-status-porcelain)
  (:import-from #:dsmr-mcp/tests/support/git-fixture
                #:with-temp-git-repo
                #:make-temp-git-repo
                #:fixture-commit-file
                #:+ours-origin-url+
                #:+third-party-upstream-url+)
  (:import-from #:dsmr-mcp/tests/support/fs-fixture
                #:write-fixture-file
                #:%make-temp-directory))

(in-package #:dsmr-mcp/tests/git/git-primitives-test)

;;; --- tracked versus untracked ----------------------------------------------

(define-test tracked-files-excludes-an-unadded-file
  "CONTROL for the never-leak property: proves git-tracked-files can omit a file
that exists on disk. If it listed everything present, every check that an
apparatus file stayed out of a repository would pass without meaning anything,
so this runs before any of them."
  (with-temp-git-repo (root)
    (fixture-commit-file root "a.txt" "a")
    (write-fixture-file root "b.txt" "b")
    (let ((tracked (git-tracked-files root)))
      (true (member "a.txt" tracked :test #'string=)
            "a committed file is listed")
      (false (member "b.txt" tracked :test #'string=)
             "a file written but never added is not listed")
      (true (member "?? b.txt" (git-status-porcelain root) :test #'string=)
            "and git does see it on disk, so its absence above is not an artefact"))))

;;; --- repository detection ---------------------------------------------------

(define-test repository-p-distinguishes-a-repo-from-a-plain-directory
  "CONTROL for classification: proves git-repository-p can return NIL. A
predicate that answered T everywhere would let a directory that is not a
repository be adopted as one."
  (with-temp-git-repo (root)
    (true (git-repository-p root) "a fixture repo is a repository"))
  (let ((plain (%make-temp-directory)))
    (unwind-protect
         (false (git-repository-p plain)
                "a plain temp directory is not a repository")
      (uiop:delete-directory-tree plain :validate t :if-does-not-exist :ignore))))

(define-test toplevel-of-a-subdirectory-is-the-repository-root
  "git-toplevel resolves upward, which is what separates a directory that IS a
repository root from one that merely sits inside somebody else's."
  (with-temp-git-repo (root)
    (let ((sub (merge-pathnames "src/" root)))
      (ensure-directories-exist sub)
      (is equal (truename root) (truename (git-toplevel sub)))
      (is equal (truename root) (truename (git-toplevel root))))))

(define-test toplevel-outside-a-repository-is-nil
  "CONTROL for classification: proves git-toplevel can return NIL rather than
inventing a root for a directory that belongs to no repository."
  (let ((plain (%make-temp-directory)))
    (unwind-protect
         (false (git-toplevel plain))
      (uiop:delete-directory-tree plain :validate t :if-does-not-exist :ignore))))

;;; --- remotes -----------------------------------------------------------------

(define-test remote-url-reads-a-configured-remote
  "A seeded origin reads back, and an unseeded upstream reads back as NIL rather
than as a failure. Classification rests on telling those two apart."
  (with-temp-git-repo (root :origin-url +ours-origin-url+)
    (is string= +ours-origin-url+ (git-remote-url root "origin"))
    (false (git-remote-url root "upstream")
           "an unconfigured remote is absent, not an error")))

(define-test remote-url-absent-is-not-an-error
  "CONTROL for the absent-versus-broken distinction: proves an absent remote
returns NIL quietly. Were it to signal, callers would learn to suppress the
condition and would then also suppress a genuinely unreadable config."
  (with-temp-git-repo (root)
    (false (git-remote-url root "origin"))
    (false (git-remote-url root "upstream"))))

(define-test remote-add-rejects-a-url-that-looks-like-an-option
  "CONTROL for argument handling: proves the URL check fires and adds nothing. A
URL beginning with a hyphen would be consumed by git as an option instead of a
location, so the rejection must happen before any process starts."
  (with-temp-git-repo (root)
    (fail (git-remote-add root "evil" "--upload-pack=touch /tmp/pwned")
          'git-command-error)
    (false (git-remote-url root "evil")
           "no remote was added by the rejected call")
    (git-remote-add root "upstream" +third-party-upstream-url+)
    (is string= +third-party-upstream-url+ (git-remote-url root "upstream")
        "and a well-formed URL still goes through")))

(define-test remote-add-rejects-an-empty-url
  "CONTROL for argument handling: proves the empty case is rejected too, so the
check above is not passing on the hyphen alone."
  (with-temp-git-repo (root)
    (fail (git-remote-add root "empty" "") 'git-command-error)
    (false (git-remote-url root "empty"))))

;;; --- the failure path --------------------------------------------------------

(define-test failing-git-command-signals-with-context
  "CONTROL for the failure path: proves a non-zero exit signals rather than
returning a value that reads as an empty success. The condition must carry
enough to report what was run without reconstructing it."
  (with-temp-git-repo (root)
    (fail (run-git (list "rev-parse" "--verify" "--not-a-real-flag")
                   :directory root)
          'git-command-error)
    (let ((condition (handler-case
                         (progn (run-git (list "rev-parse" "--verify" "--not-a-real-flag")
                                         :directory root)
                                nil)
                       (git-command-error (caught) caught))))
      (true condition "the failing command signalled")
      (false (zerop (git-command-error-exit-code condition))
             "the exit code is non-zero")
      (true (member "rev-parse" (git-command-error-argv condition) :test #'string=)
            "the argument vector is carried")
      (true (plusp (length (git-command-error-stderr condition)))
            "and git's own diagnosis is carried"))))

(define-test failure-can-be-returned-instead-of-signalled
  "The same failing command returns its non-zero exit code when the caller asks
for it, which is how the readers that accept one specific status are built."
  (with-temp-git-repo (root)
    (multiple-value-bind (stdout stderr exit-code)
        (run-git (list "rev-parse" "--verify" "--not-a-real-flag")
                 :directory root
                 :error-on-failure nil)
      (declare (ignore stdout))
      (false (zerop exit-code))
      (true (plusp (length stderr))))))

;;; --- HEAD ---------------------------------------------------------------------

(define-test head-sha-is-present-with-history-and-absent-without
  "CONTROL for the empty-repository case: proves git-head-sha returns NIL on a
repository with no commits rather than signalling. A freshly initialized
repository is a normal state during adoption, not a fault."
  (with-temp-git-repo (root :initial-file "a.txt" :initial-content "a")
    (let ((sha (git-head-sha root)))
      (true (stringp sha))
      (is = 40 (length sha))))
  (with-temp-git-repo (root)
    (false (git-head-sha root)
           "a repository with no commit has no HEAD, and that is not an error")))

;;; --- fixture path uniqueness ---------------------------------------------------

(define-test successive-fixture-repositories-get-distinct-paths
  "Two repositories built back to back must not share a directory. If they did,
one test would tear down another's tree and an absence assertion would pass for
the wrong reason."
  (let ((first (make-temp-git-repo))
        (second (make-temp-git-repo)))
    (unwind-protect
         (false (equal first second))
      (uiop:delete-directory-tree first :validate t :if-does-not-exist :ignore)
      (uiop:delete-directory-tree second :validate t :if-does-not-exist :ignore))))

;;; --- fixture independence from the host init template -----------------------

(define-test fixture-repositories-carry-no-host-template
  "A fixture repository holds no hook and no exclude file from the host's init
template, so a test's outcome does not depend on whose machine runs it. The
repository's own HEAD file is asserted present in the same test, so the absence
checks are aimed at a real git directory rather than at nothing."
  (with-temp-git-repo (root)
    (let ((git-dir (merge-pathnames ".git/" root)))
      (true (probe-file (merge-pathnames "HEAD" git-dir))
            "the fixture created a real git directory")
      (false (probe-file (merge-pathnames "hooks/pre-commit" git-dir))
             "no pre-commit hook arrived from an init template")
      (false (probe-file (merge-pathnames "info/exclude" git-dir))
             "no exclude file arrived from an init template"))))

(defmacro %with-environment-variable ((name value) &body body)
  "Run BODY with the process environment variable NAME set to VALUE, then
restore whatever NAME held before, or unset it."
  (let ((old (gensym "OLD-")))
    `(let ((,old (sb-posix:getenv ,name)))
       (unwind-protect
            (progn (sb-posix:setenv ,name ,value 1) ,@body)
         (if ,old
             (sb-posix:setenv ,name ,old 1)
             (sb-posix:unsetenv ,name))))))

(define-test an-inherited-git-dir-does-not-redirect-a-command
  "A GIT_DIR inherited from the parent process, as a git hook exports it, must
not redirect a command aimed at another repository with -C. The config write
lands in the repository named by DIRECTORY, and the repository GIT_DIR names
is checked unchanged in the same test, so the assertion is aimed at both."
  (with-temp-git-repo (decoy)
    (with-temp-git-repo (target)
      (%with-environment-variable
          ("GIT_DIR" (namestring (merge-pathnames ".git/" decoy)))
        (run-git (list "config" "--local" "probe.key" "target")
                 :directory target))
      (is string= "target"
          (string-trim '(#\Newline)
                       (run-git (list "config" "--local" "--get" "probe.key")
                                :directory target :error-on-failure nil))
          "the write landed in the repository named by DIRECTORY")
      (is = 1 (nth-value 2 (run-git (list "config" "--local" "--get"
                                          "probe.key")
                                    :directory decoy :error-on-failure nil))
          "the repository named by GIT_DIR was not written"))))
