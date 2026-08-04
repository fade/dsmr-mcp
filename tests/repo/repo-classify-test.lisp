;;;; tests/repo/repo-classify-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Parachute tests for repository classification, over real git repositories.
;;;;
;;;; Every fixture here is an actual repository with actual remotes, not a temp
;;;; directory standing in for one. Classification reads remotes, and a bare
;;;; directory has none, so a check aimed at one would report the same answer
;;;; whether the code worked or not.
;;;;
;;;; The dangerous mistake this file is built around is a single direction:
;;;; concluding that somebody else's repository is ours. That conclusion ends
;;;; with our tooling committed into a third party's history, and it is silent.
;;;; So the tests that matter most assert the negative explicitly, rather than
;;;; trusting a positive assertion that a function returning one constant would
;;;; also satisfy.

;; Package evolution guard - delete prior definition on warm reload.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/repo/repo-classify-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/repo/repo-classify-test
  (:use #:cl #:parachute)
  (:import-from #:dsmr-mcp/src/repo-classify
                #:*our-git-accounts*
                #:our-git-accounts
                #:parse-remote-owner
                #:our-remote-p
                #:classify-repository
                #:repo-profile
                #:+classifications+
                #:repo-classification-ambiguous-error
                #:repo-classification-ambiguous-directory
                #:repo-classification-ambiguous-origin-url)
  (:import-from #:dsmr-mcp/src/git
                #:not-a-repository-error)
  (:import-from #:dsmr-mcp/tests/support/git-fixture
                #:with-temp-git-repo
                #:+ours-origin-url+
                #:+third-party-origin-url+
                #:+third-party-upstream-url+)
  (:import-from #:dsmr-mcp/tests/support/fs-fixture
                #:%make-temp-directory))

(in-package #:dsmr-mcp/tests/repo/repo-classify-test)

;;; --- helpers ----------------------------------------------------------------

(defun ambiguity-signalled-by (directory &rest arguments)
  "Return the ambiguity condition CLASSIFY-REPOSITORY signals for DIRECTORY.

Returns NIL when the call returned instead of signalling, so a caller can tell
the two apart and report which happened. PARACHUTE's FAIL proves that something
was signalled; this exists to read the slots off it afterwards."
  (handler-case (progn (apply #'classify-repository directory arguments) nil)
    (repo-classification-ambiguous-error (condition) condition)))

;;; --- reading an account out of a URL ----------------------------------------

(define-test parse-remote-owner-reads-every-url-shape-on-this-host
  "The three shapes remotes actually take here, each read back to its account."
  (is string= "sionescu"
      (parse-remote-owner "https://github.com/sionescu/iolib.git"))
  (is string= "fade"
      (parse-remote-owner "git@github.com:fade/dsmr-mcp.git"))
  (is string= "fade"
      (parse-remote-owner "ssh://git@codeberg.org/fade/parachute")))

(define-test unparseable-url-fails-toward-foreign
  "CONTROL for the parse step: proves an unrecognised URL yields no account and
is not treated as ours. Were an unparseable URL to read as ours, every remote
shape this parser does not know would silently become an invitation to track our
apparatus in somebody else's tree, and no other check in this file would notice."
  (is eq nil (parse-remote-owner "not-a-url"))
  (is eq nil (parse-remote-owner ""))
  (is eq nil (parse-remote-owner :not-even-a-string))
  (false (our-remote-p "not-a-url")
         "an unparseable URL is not ours")
  (false (our-remote-p "https://github.com/sionescu/iolib.git")
         "and a parseable third-party URL is not ours either")
  (true (our-remote-p +ours-origin-url+)
        "while one of our own accounts is, so the negatives above are not blanket"))

(define-test our-git-accounts-defaults-without-an-override
  "The account list is readable and non-empty, which every classification below
depends on. An empty list would make every repository foreign and would make the
foreign assertions pass for the wrong reason."
  (true (member "fade" (our-git-accounts) :test #'string=))
  (true (member "fade" *our-git-accounts* :test #'string=)))

;;; --- the four classification inputs -----------------------------------------

(define-test declared-ours-is-the-only-route-to-ours
  "A repository indistinguishable from one of ours reaches :OURS only because it
was declared. The same fixture without the declaration signals, which the
ambiguity test below asserts separately."
  (with-temp-git-repo (root :origin-url +ours-origin-url+
                            :initial-file "README.md"
                            :initial-content "x")
    (multiple-value-bind (classification upstream)
        (classify-repository root :declared-classification :ours)
      (is eq :ours classification)
      (is eq nil upstream "our own project records no upstream")
      (is eq :ours (repo-profile classification)))))

(define-test our-origin-with-an-upstream-is-a-foreign-fork
  "Our origin plus a third-party upstream is the fork-then-clone shape, and it is
somebody else's software however our own the origin looks."
  (with-temp-git-repo (root :origin-url +ours-origin-url+
                            :upstream-url +third-party-upstream-url+
                            :initial-file "README.md"
                            :initial-content "x")
    (multiple-value-bind (classification upstream)
        (classify-repository root)
      (is eq :foreign-with-upstream classification)
      (is string= +third-party-upstream-url+ upstream)
      (is eq :foreign (repo-profile classification)))))

(define-test third-party-origin-without-an-upstream-is-foreign
  "CONTROL for classification, and the one that guards the leak. This fixture is
a raw clone of somebody else's repository with NO upstream remote at all, which
is the commonest shape in the workspace and the shape an upstream-presence test
reads as ours. The negative assertion is made explicitly rather than inferred
from the positive one, because a function that returned a single constant would
satisfy the positive assertion alone."
  (with-temp-git-repo (root :origin-url +third-party-origin-url+
                            :initial-file "README.md"
                            :initial-content "x")
    (multiple-value-bind (classification upstream)
        (classify-repository root)
      (isnt eql :ours classification
            "a third party's repository is never ours")
      (isnt eq :ours (repo-profile classification)
            "and its profile is never the tracked-apparatus one")
      (is eq :foreign-with-upstream classification)
      (is string= +third-party-origin-url+ upstream
          "the origin is the upstream to record, there being no other")
      (is eq :foreign (repo-profile classification)))))

(define-test declared-orphan-is-a-terminal-state
  "An absent upstream is a place to stop, not drift to repair. A declared orphan
comes back as one and carries no upstream, and its profile is foreign, so it is
adopted exactly like any other repository we do not own."
  (with-temp-git-repo (root :origin-url +ours-origin-url+
                            :initial-file "README.md"
                            :initial-content "x")
    (multiple-value-bind (classification upstream)
        (classify-repository root :declared-classification :foreign-orphan)
      (is eq :foreign-orphan classification)
      (is eq nil upstream)
      (is eq :foreign (repo-profile classification))
      (true (member classification +classifications+)
            "orphan is one of the terminal classifications, not an error code"))))

;;; --- the ambiguous case, which is the common one ----------------------------

(define-test our-origin-without-an-upstream-signals
  "CONTROL for the ambiguity path. Our origin with nothing recording an upstream
cannot be told from one of our own projects by anything on disk, and it is the
largest of the our-origin buckets. FAIL proves the call produces no value at
all: a version that returned :OURS here is precisely the silent leak, and it
would satisfy any assertion phrased as a comparison."
  (with-temp-git-repo (root :origin-url +ours-origin-url+
                            :initial-file "README.md"
                            :initial-content "x")
    (fail (classify-repository root) 'repo-classification-ambiguous-error)
    (let ((condition (ambiguity-signalled-by root)))
      (true condition "the call signalled rather than returning")
      (is string= +ours-origin-url+
          (repo-classification-ambiguous-origin-url condition)
          "the condition carries the origin, so the operator can be asked")
      (true (repo-classification-ambiguous-directory condition)
            "and the directory the question is about"))))

(define-test a-supplied-upstream-resolves-the-ambiguity
  "The ambiguous fixture stops being ambiguous once an upstream is supplied,
without the repository's remotes being repaired first."
  (with-temp-git-repo (root :origin-url +ours-origin-url+
                            :initial-file "README.md"
                            :initial-content "x")
    (multiple-value-bind (classification upstream)
        (classify-repository root :upstream-url +third-party-upstream-url+)
      (is eq :foreign-with-upstream classification)
      (is string= +third-party-upstream-url+ upstream))))

(define-test a-repository-with-no-origin-signals
  "No origin is as undecidable as an ambiguous one, and it signals the same way
rather than defaulting. The condition carries a NIL origin, which is how a
caller tells this shape from the our-origin one."
  (with-temp-git-repo (root :initial-file "README.md" :initial-content "x")
    (fail (classify-repository root) 'repo-classification-ambiguous-error)
    (let ((condition (ambiguity-signalled-by root)))
      (true condition "the call signalled rather than returning")
      (is eq nil (repo-classification-ambiguous-origin-url condition)))))

;;; --- inputs that are not classifiable at all --------------------------------

(define-test a-plain-directory-is-not-a-repository
  "A directory outside any repository is a broken precondition, reported as such
rather than folded into the ambiguity path where it would be mistaken for a
question worth asking the operator."
  (let ((plain (%make-temp-directory)))
    (unwind-protect
         (fail (classify-repository plain) 'not-a-repository-error)
      (uiop:delete-directory-tree plain :validate t :if-does-not-exist :ignore))))

(define-test an-invalid-declaration-signals-rather-than-being-ignored
  "CONTROL for the declaration path: proves a value outside the three terminal
classifications is rejected. Were it ignored, a mistyped declaration would fall
through to inference and the operator's answer would be silently replaced by a
guess, which is the failure this module exists to prevent."
  (with-temp-git-repo (root :origin-url +ours-origin-url+
                            :initial-file "README.md"
                            :initial-content "x")
    (fail (classify-repository root :declared-classification :probably-ours)
          'type-error)
    (fail (classify-repository root :declared-classification "ours")
          'type-error)
    (is eq :ours (classify-repository root :declared-classification :ours)
        "while a valid declaration still goes through, so the rejections above
are not blanket")))

;;; --- profile ----------------------------------------------------------------

(define-test repo-profile-collapses-both-foreign-outcomes
  "Both foreign outcomes call for the same treatment, apparatus present and none
of it tracked, so they share one profile. An unrecognised value signals rather
than defaulting to either."
  (is eq :ours (repo-profile :ours))
  (is eq :foreign (repo-profile :foreign-with-upstream))
  (is eq :foreign (repo-profile :foreign-orphan))
  (fail (repo-profile :something-else) 'type-error))
