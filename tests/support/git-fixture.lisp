;;;; tests/support/git-fixture.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Fixture that produces a REAL git repository on disk.
;;;;
;;;; A bare temp directory cannot stand in for one. The checks that matter here
;;;; are about what git tracks, what .git/info/exclude contains and what lives
;;;; under .git/hooks/, and none of those exist without an actual repository.
;;;; Pointed at a plain directory, an assertion about absence passes because
;;;; there is nothing there at all, which is the failure mode this file exists
;;;; to remove.
;;;;
;;;; Repositories are built through the same primitives production code uses,
;;;; so a fixture that works is also evidence the primitives work.

;; Package evolution guard - delete prior definition on warm reload.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/support/git-fixture)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/support/git-fixture
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/git
                #:run-git
                #:git-init
                #:git-remote-add)
  (:import-from #:dsmr-mcp/tests/support/fs-fixture
                #:write-fixture-file)
  (:export #:with-temp-git-repo
           #:make-temp-git-repo
           #:seed-exclude-patterns
           #:fixture-commit-file
           #:+ours-origin-url+
           #:+third-party-origin-url+
           #:+third-party-upstream-url+))

(in-package #:dsmr-mcp/tests/support/git-fixture)

;;; ---------------------------------------------------------------------------
;;; Sample remote URLs
;;; ---------------------------------------------------------------------------

;;; These exist to be parsed and classified. No network access is ever made
;;; against them, and none of these repositories is contacted by any test.

(defvar +ours-origin-url+ "git@github.com:fade/example.git"
  "An origin URL under our own account.")

(defvar +third-party-origin-url+ "https://github.com/sionescu/iolib.git"
  "An origin URL owned by somebody else.")

(defvar +third-party-upstream-url+ "https://github.com/shinmera/parachute.git"
  "An upstream URL owned by somebody else.")

;;; ---------------------------------------------------------------------------
;;; Unique temp paths
;;; ---------------------------------------------------------------------------

(defvar *fixture-random-state* (make-random-state t)
  "A random state seeded from the environment at load time.

Drawing temp-path suffixes from an unseeded state repeats the same sequence in
every fresh image, so two runs land on the same directory and a test asserting
that something is absent can pass because a neighbour already removed it. It is
a DEFVAR rather than a DEFPARAMETER so reloading the system mid-suite does not
reset the sequence back to its start.")

(defun %make-temp-repo-directory ()
  "Create a uniquely named empty directory under /tmp and return its pathname."
  (loop
    (let* ((name   (format nil "dsmr-git-test-~8,'0X"
                           (random #xFFFFFFFF *fixture-random-state*)))
           (dir-pn (uiop:ensure-directory-pathname
                    (merge-pathnames name #p"/tmp/"))))
      (unless (probe-file dir-pn)
        (ensure-directories-exist dir-pn)
        (return dir-pn)))))

;;; ---------------------------------------------------------------------------
;;; Repository construction
;;; ---------------------------------------------------------------------------

(defun %configure-fixture-identity (root)
  "Give ROOT its own committer identity and disable commit signing.

Set in the repository-local config rather than inherited, so a fixture commit
does not carry the developer's name and does not fail on a machine where every
commit is signed."
  (run-git (list "config" "user.email" "fixture@invalid") :directory root)
  (run-git (list "config" "user.name" "fixture") :directory root)
  (run-git (list "config" "commit.gpgsign" "false") :directory root))

(defun fixture-commit-file (root relative-path content &key (message "fixture"))
  "Write CONTENT to RELATIVE-PATH under ROOT, stage it and commit it.

Returns the absolute pathname written. This is how a fixture gets a repository
that already tracks a given file, which is what a check for an apparatus file
having leaked into somebody else's tree has to be aimed at."
  (let ((written (write-fixture-file root relative-path content)))
    (run-git (list "add" "--" (namestring relative-path)) :directory root)
    (run-git (list "commit" "-m" message) :directory root)
    written))

(defun seed-exclude-patterns (root patterns)
  "Write PATTERNS, one per line, to ROOT/.git/info/exclude. Returns the pathname.

A fixture must never assume git init already populated that file. Whether it
does depends on the host's configured template directory, so a repository built
on one machine arrives seeded and on another arrives empty. Every drift check
therefore writes the baseline it intends to test against, rather than trusting
whatever the host happened to leave behind."
  (let ((exclude (merge-pathnames ".git/info/exclude"
                                  (uiop:ensure-directory-pathname root))))
    (ensure-directories-exist exclude)
    (with-open-file (out exclude :direction :output :if-exists :supersede
                                 :if-does-not-exist :create
                                 :element-type 'character)
      (dolist (pattern patterns)
        (write-string pattern out)
        (terpri out)))
    exclude))

(defun make-temp-git-repo (&key origin-url upstream-url initial-file initial-content)
  "Create a real git repository in a fresh temp directory and return its root.

ORIGIN-URL and UPSTREAM-URL, when supplied, become remotes of those names.
INITIAL-FILE, when supplied, is written with INITIAL-CONTENT, staged and
committed, so the repository has real history and a resolvable HEAD rather than
the empty state a bare git init leaves behind.

The caller owns the returned tree and must delete it. Prefer WITH-TEMP-GIT-REPO,
which does that unconditionally."
  (let ((root (%make-temp-repo-directory)))
    (git-init root)
    (%configure-fixture-identity root)
    (when initial-file
      (fixture-commit-file root initial-file (or initial-content "")
                           :message "initial"))
    (when origin-url
      (git-remote-add root "origin" origin-url))
    (when upstream-url
      (git-remote-add root "upstream" upstream-url))
    root))

(defmacro with-temp-git-repo ((root-var &key origin-url upstream-url
                                             initial-file initial-content)
                              &body body)
  "Bind ROOT-VAR to a fresh real git repository, run BODY, then delete the tree.

Teardown runs from an UNWIND-PROTECT cleanup form, so it happens whether BODY
returned or threw. A fixture that only cleans up on success leaves debris behind
exactly when a run is failing, which is when the next run can least afford to
find a stale directory."
  (let ((dir-var (gensym "REPO-")))
    `(let* ((,dir-var (make-temp-git-repo :origin-url ,origin-url
                                          :upstream-url ,upstream-url
                                          :initial-file ,initial-file
                                          :initial-content ,initial-content))
            (,root-var ,dir-var))
       (unwind-protect
            (progn ,@body)
         (uiop:delete-directory-tree ,dir-var
                                     :validate t
                                     :if-does-not-exist :ignore)))))
