;;;; tests/doctor/project-gate-scan-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Parachute tests for discovering the sites a quality gate would report,
;;;; against a real source tree and a real linter.
;;;;
;;;; The claim under test is one that passes trivially when the instrument is
;;;; aimed at nothing. A scanner that never ran returns the same empty list as a
;;;; clean repository, so no emptiness assertion is made on its own here: the
;;;; test that requires nothing from a clean file requires a finding from a
;;;; deliberately broken one, in the same call to the same function, over the
;;;; same directory.
;;;;
;;;; The second claim is the one that matters when the tooling is missing rather
;;;; than the code. A scanner with no linter must say so, because a baseline
;;;; asserting zero sites and a baseline nobody could populate are
;;;; indistinguishable once written, and the written one gets believed. That is
;;;; asserted as a signal, not as an empty result.
;;;;
;;;; The linter may genuinely be absent on a build host, and that is not a test
;;;; failure. The tests needing it take an explicit branch on
;;;; GATE-SCANNER-AVAILABLE-P and assert something true about the unavailable
;;;; case instead. A bare skip form is not used: a skip that falls through runs
;;;; the very body it was meant to prevent, which is how a suite reports a green
;;;; run it never performed.

;; Package evolution guard - delete prior definition on warm reload.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/doctor/project-gate-scan-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/doctor/project-gate-scan-test
  (:use #:cl #:parachute)
  (:import-from #:dsmr-mcp/src/project-gate-scan
                #:*linter-path*
                #:linter-path
                #:gate-scanner-available-p
                #:collect-debt-sites
                #:gate-scanner-unavailable-error
                #:gate-scanner-unavailable-path
                #:gate-scan-failed-error)
  (:import-from #:dsmr-mcp/tests/support/fs-fixture
                #:write-fixture-file
                #:%make-temp-directory))

(in-package #:dsmr-mcp/tests/doctor/project-gate-scan-test)

;;; ---------------------------------------------------------------------------
;;; Fixtures
;;; ---------------------------------------------------------------------------

(defparameter +violating-source+
  "(defun violating (x)
  (ignore-errors (error \"boom\"))
  x)
"
  "A source file carrying one violation nobody could call a matter of taste.
The rule against swallowing every condition is on by default and its finding is
unambiguous, so a scan that reports nothing here reported nothing at all.")

(defparameter +clean-source+
  "(defun clean (x)
  (+ x 1))
"
  "A source file the linter has nothing to say about.
Paired with the violating one in the same test: an empty result is only evidence
when the same instrument has been seen returning a non-empty one.")

(defmacro with-temp-tree ((root-var) &body body)
  "Run BODY with ROOT-VAR bound to a fresh temp directory, removed afterwards."
  (let ((dir (gensym "TREE-")))
    `(let* ((,dir      (%make-temp-directory))
            (,root-var ,dir))
       (unwind-protect (progn ,@body)
         (uiop:delete-directory-tree ,dir
                                     :validate t
                                     :if-does-not-exist :ignore)))))

(defun %files-named (sites)
  "Return the file of every site in SITES."
  (mapcar (lambda (site) (getf site :file)) sites))

(defun %sites-for (sites name)
  "Return the sites in SITES whose file ends in NAME."
  (remove-if-not (lambda (site)
                   (let ((file (getf site :file)))
                     (and (stringp file)
                          (>= (length file) (length name))
                          (string= name file :start2 (- (length file)
                                                        (length name))))))
                 sites))

;;; ---------------------------------------------------------------------------
;;; Detection, and the emptiness that is only evidence beside it
;;; ---------------------------------------------------------------------------

(define-test the-scanner-finds-a-real-violation-and-reports-none-for-clean-source
  "DETECTION CONTROL. Both halves live in this one test on purpose.

A scanner that never ran, that was handed no files, or that discarded everything
it parsed returns exactly what a clean repository returns. Asserting the empty
half alone would be satisfied by all four of those. So the same directory holds
one deliberately broken file and one clean one, one call scans both, and the
findings must land on the broken file and on nothing else.

Takes an explicit branch when no linter is installed rather than relying on a
skip form to end the test."
  (if (not (gate-scanner-available-p))
      (fail (collect-debt-sites (uiop:temporary-directory))
            'gate-scanner-unavailable-error
            "with no linter installed, scanning signals rather than returning")
      (with-temp-tree (root)
        (write-fixture-file root "src/violating.lisp" +violating-source+)
        (write-fixture-file root "src/clean.lisp" +clean-source+)
        (let* ((sites   (collect-debt-sites root))
               (dirty   (%sites-for sites "violating.lisp"))
               (clean   (%sites-for sites "clean.lisp")))
          (true (plusp (length dirty))
                "the seeded violation is reported: ~S" (%files-named sites))
          (is = 0 (length clean)
              "the clean file yields nothing: ~S" (%files-named sites))
          (let ((site (first dirty)))
            (true (getf site :file)   "the site names its file")
            (true (getf site :line)   "the site carries a line")
            (true (getf site :rule)   "the site carries the rule that fired")
            (true (getf site :severity)
                  "the site carries the severity the linter gave it")
            (is eq :frozen-with-diagnosis (getf site :category)
                "a discovered site is examined-and-frozen, never judged")
            (is eq :not-determined (getf site :callee-knowable)
                "callee knowability is left undetermined, not guessed"))))))

(define-test every-discovered-site-is-frozen-and-undetermined
  "The category and the knowability are fixed for every site, not just the first.

A scanner that set them on one site and left the rest at NIL would satisfy the
single-site assertion in the test above and would put NIL in a baseline column
that a reader takes for a measurement."
  (if (not (gate-scanner-available-p))
      (fail (collect-debt-sites (uiop:temporary-directory))
            'gate-scanner-unavailable-error
            "with no linter installed, scanning signals rather than returning")
      (with-temp-tree (root)
        (write-fixture-file root "src/one.lisp" +violating-source+)
        (write-fixture-file root "src/two.lisp" +violating-source+)
        (let ((sites (collect-debt-sites root)))
          (true (>= (length sites) 2)
                "both seeded files are reported: ~S" (%files-named sites))
          (true (every (lambda (site)
                         (eq :frozen-with-diagnosis (getf site :category)))
                       sites)
                "every site is frozen with its diagnosis")
          (true (every (lambda (site)
                         (eq :not-determined (getf site :callee-knowable)))
                       sites)
                "every site leaves callee knowability undetermined")
          (true (notany (lambda (site)
                          (let ((file (getf site :file)))
                            (and (stringp file)
                                 (plusp (length file))
                                 (char= #\/ (char file 0)))))
                        sites)
                "no site names an absolute path: ~S" (%files-named sites))))))

(define-test a-tree-with-no-lisp-sources-yields-nothing
  "An empty answer for a tree that holds no Lisp at all.

Paired with the detection test above rather than standing alone: on its own this
is satisfied by a scanner that returns NIL unconditionally."
  (if (not (gate-scanner-available-p))
      (fail (collect-debt-sites (uiop:temporary-directory))
            'gate-scanner-unavailable-error
            "with no linter installed, scanning signals rather than returning")
      (with-temp-tree (root)
        (write-fixture-file root "README.md" "nothing to lint here")
        (is equal '() (collect-debt-sites root)
            "a tree with no .lisp files reports no sites"))))

;;; ---------------------------------------------------------------------------
;;; The absent linter
;;; ---------------------------------------------------------------------------

(define-test an-absent-linter-signals-rather-than-reporting-no-debt
  "UNAVAILABLE CONTROL. The check that keeps \"no linter\" out of the record as
\"no debt\".

A baseline asserting a repository has no pre-existing sites and a baseline
nobody was able to populate read identically once written, and the written one
is the one that gets believed. So the absent case must be a signal. Returning
NIL here would pass every other test in this file."
  (with-temp-tree (root)
    (write-fixture-file root "src/violating.lisp" +violating-source+)
    (let ((*linter-path* (merge-pathnames "no-linter-here" root)))
      (false (gate-scanner-available-p (linter-path))
             "precondition: the bound path holds no linter. A DSMR_LINTER set in
              this environment overrides the binding and defeats this control.")
      (fail (collect-debt-sites root) 'gate-scanner-unavailable-error
            "an absent linter signals")
      (handler-case (progn (collect-debt-sites root) nil)
        (gate-scanner-unavailable-error (condition)
          (true (gate-scanner-unavailable-path condition)
                "the condition names the path that was looked at"))))))

(define-test the-absent-linter-is-refused-before-anything-is-run
  "The refusal does not depend on there being files to scan.

A scanner that enumerated first and checked the binary later would return NIL
for an empty tree with no linter, which is the exact pair of unknowns this
module exists to keep apart."
  (with-temp-tree (root)
    (let ((*linter-path* (merge-pathnames "no-linter-here" root)))
      (false (gate-scanner-available-p (linter-path))
             "precondition: the bound path holds no linter")
      (fail (collect-debt-sites root) 'gate-scanner-unavailable-error
            "an empty tree with no linter signals rather than reporting clean"))))

;;; ---------------------------------------------------------------------------
;;; Availability
;;; ---------------------------------------------------------------------------

(define-test availability-follows-the-file-on-disk
  "GATE-SCANNER-AVAILABLE-P answers about a real file, in both directions.

Asserted both ways in one test: a predicate hardcoded to either answer satisfies
half of this and nothing would say which half."
  (with-temp-tree (root)
    (let ((present (write-fixture-file root "pretend-linter" "#!/bin/sh\n"))
          (absent  (merge-pathnames "definitely-not-here" root)))
      (true  (gate-scanner-available-p present)
             "a file that exists is available")
      (false (gate-scanner-available-p absent)
             "a file that does not exist is not available"))))

(define-test the-linter-path-is-absolute
  "The configured path is absolute, never a bare command name.

A bare name would be resolved against PATH, where a binary of the same name
belongs to an unrelated toolkit. That one would run, report on nothing we asked
about, and its silence would be recorded as a clean repository."
  (let ((path (linter-path)))
    (is eq :absolute (car (pathname-directory path))
        "the linter path is absolute: ~A" path)))
