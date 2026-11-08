;;;; tests/doctor/project-licence-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Zebra tests for the rule that adopting a repository leaves its licence
;;;; exactly as it was found.
;;;;
;;;; Adopting a project is agreeing to contribute on that project's own terms.
;;;; Nothing the doctor writes into a repository it adopts may carry a licence
;;;; identifier or licence text, and no licence file or file header already
;;;; there may change by a single byte.
;;;;
;;;; Each absence assertion here is paired with a control showing the same
;;;; instrument can see the thing it reports absent, because a scan for licence
;;;; text over files that were never written passes just as well.

;; Package evolution guard - delete prior definition on warm reload.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/doctor/project-licence-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/doctor/project-licence-test
  (:use #:cl #:zebra)
  (:import-from #:dsmr-mcp/src/project-doctor
                #:normalise-repository
                #:report-changed
                #:report-debt-baseline
                #:*repair-writer*)
  (:import-from #:dsmr-mcp/src/project-shape
                #:shape-item-key
                #:shape-item-generator
                #:shape-item-tier
                #:item-disposition
                #:*shape-catalog*)
  (:import-from #:dsmr-mcp/src/project-shape-catalog
                #:*assessed-tiers*)
  (:import-from #:dsmr-mcp/src/project-debt
                #:adopted-repo-gate-severity)
  (:import-from #:dsmr-mcp/src/project-gate-scan
                #:linter-path
                #:gate-scanner-available-p)
  (:import-from #:dsmr-mcp/src/project-exclude
                #:*exclude-template-path*)
  (:import-from #:dsmr-mcp/src/git
                #:run-git
                #:git-tracked-files)
  (:import-from #:dsmr-mcp/tests/support/git-fixture
                #:with-temp-git-repo
                #:fixture-commit-file
                #:seed-exclude-patterns
                #:+ours-origin-url+
                #:+third-party-origin-url+)
  (:import-from #:dsmr-mcp/tests/support/fs-fixture
                #:write-fixture-file
                #:%make-temp-directory))

(in-package #:dsmr-mcp/tests/doctor/project-licence-test)

;;; ---------------------------------------------------------------------------
;;; What counts as licence text
;;; ---------------------------------------------------------------------------

(defvar +licence-markers+
  '("SPDX-License-Identifier" "AGPL" "GNU General Public" "GNU Affero"
    "Copyright")
  "Strings whose presence in written content states a licence or an owner.
Matched without regard to case.")

(defun %licence-markers-in (text)
  "Return the members of +LICENCE-MARKERS+ that occur in TEXT, ignoring case."
  (remove-if-not (lambda (marker) (search marker text :test #'char-equal))
                 +licence-markers+))

;;; ---------------------------------------------------------------------------
;;; Fixtures
;;; ---------------------------------------------------------------------------

(defmacro with-fixture-template (() &body body)
  "Run BODY with a freshly written exclude template as the pattern set of record.

The environment override is cleared as well, so a developer's own template
cannot change what is measured."
  (let ((dir (gensym "TEMPLATE-DIR-"))
        (path (gensym "TEMPLATE-"))
        (saved (gensym "SAVED-")))
    `(let* ((,dir (%make-temp-directory))
            (,path (write-fixture-file ,dir "info/exclude"
                                       (format nil ".claude/~%AGENTS.md~%CLAUDE.md~%")))
            (,saved (uiop:getenv "DSMR_GIT_EXCLUDE_TEMPLATE"))
            (*exclude-template-path* ,path))
       (unwind-protect
            (progn
              (setf (uiop:getenv "DSMR_GIT_EXCLUDE_TEMPLATE") "")
              ,@body)
         (setf (uiop:getenv "DSMR_GIT_EXCLUDE_TEMPLATE") (or ,saved ""))
         (uiop:delete-directory-tree ,dir :validate t :if-does-not-exist :ignore)))))

(defun %clear-ambient-ignores (root)
  "Empty ROOT's local exclude and point its global ignore file at an empty file."
  (seed-exclude-patterns root '())
  (let ((empty (write-fixture-file root ".git/no-ignores" "")))
    (run-git (list "config" "core.excludesFile" (namestring empty))
             :directory root))
  root)

(defun %flat-foreign-fixture (root)
  "Give ROOT the committed shape of a flat third-party library."
  (%clear-ambient-ignores root)
  (fixture-commit-file root "example.asd" "(asdf:defsystem \"example\")")
  (fixture-commit-file root "example.lisp" ";; the whole library, at the top level")
  root)

(defun %created-paths (report)
  "Return the destination of every file REPORT says the run created."
  (loop for entry in (report-changed report)
        when (and (eq :created (getf entry :action-taken))
                  (getf entry :item))
          collect (getf entry :path)))

;;; ---------------------------------------------------------------------------
;;; Every piece of apparatus, as the doctor renders it
;;; ---------------------------------------------------------------------------

(defun %foreign-renderable-items ()
  "Return the catalog items excluded under :FOREIGN whose content can be rendered."
  (remove-if-not
   (lambda (item)
     (and (eq :excluded (item-disposition item :foreign))
          (or (shape-item-generator item)
              (member (shape-item-key item)
                      '(:mallet-config :lint-script :pre-commit)))))
   *shape-catalog*))

(defun %render-as-doctor (item root)
  "Return ITEM's content as the doctor would write it into the repository at ROOT."
  (dsmr-mcp/src/project-doctor::%item-content
   item
   (dsmr-mcp/src/project-doctor::%bindings root)
   (adopted-repo-gate-severity)
   (dsmr-mcp/src/project-doctor::%repo-name root)
   :foreign))

(define-test no-foreign-apparatus-renders-licence-text
  "Every apparatus item a foreign repository receives renders with no licence text.

Walks the whole catalog rather than naming items, so a template added later is
covered without anyone adding a case for it."
  (with-temp-git-repo (root :origin-url +third-party-origin-url+
                            :initial-file "README.md" :initial-content "x")
    (let ((items (%foreign-renderable-items)))
      (dolist (key '(:mallet-config :lint-script :pre-commit))
        (true (member key items :key #'shape-item-key)
              "the walk reaches ~S" key))
      (dolist (item items)
        (let ((content (%render-as-doctor item root)))
          (true (plusp (length content))
                "~S renders to something" (shape-item-key item))
          (is equal '() (%licence-markers-in content)
              "~S carries no licence text" (shape-item-key item)))))))

(define-test no-item-of-ours-renders-an-empty-licence-tag
  "The doctor binds no licence, so a file it writes into a repository of ours
must carry no licence tag at all rather than one naming nothing: no
SPDX-License-Identifier line without an identifier, and no empty :license in
a system definition. Walks every renderable item the :OURS profile is held to."
  (with-temp-git-repo (root :origin-url +ours-origin-url+
                            :initial-file "README.md" :initial-content "x")
    (let ((items (remove-if-not
                  (lambda (item)
                    (and (member (shape-item-tier item) '(:invariant :gate))
                         (or (shape-item-generator item)
                             (member (shape-item-key item)
                                     '(:mallet-config :lint-script :pre-commit)))))
                  *shape-catalog*)))
      (true (member :asd-system items :key #'shape-item-key)
            "the walk reaches the system definition")
      (dolist (item items)
        (let ((content (dsmr-mcp/src/project-doctor::%item-content
                        item
                        (dsmr-mcp/src/project-doctor::%bindings root)
                        (adopted-repo-gate-severity)
                        (dsmr-mcp/src/project-doctor::%repo-name root)
                        :ours)))
          (dolist (line (uiop:split-string content :separator '(#\Newline)))
            (let ((trimmed (string-trim '(#\Space #\Tab #\Return) line)))
              (false (uiop:string-suffix-p trimmed "SPDX-License-Identifier:")
                     "~S carries an empty licence tag: ~S"
                     (shape-item-key item) line)
              (false (string= trimmed ":license \"\"")
                     "~S carries an empty :license: ~S"
                     (shape-item-key item) line))))))))

(define-test a-foreign-repair-writes-no-licence-text
  "A full repair of a foreign repository writes files, none naming a licence."
  (with-fixture-template ()
    (with-temp-git-repo (root :origin-url +third-party-origin-url+
                              :initial-file "README.md" :initial-content "x")
      (%flat-foreign-fixture root)
      (let* ((report (normalise-repository root :policy :repair))
             (created (%created-paths report)))
        (true created "the run created files, so the scan below reads something")
        (true (find "lint-lisp.sh" created
                    :key #'file-namestring :test #'string=)
              "the lint script is among the files written")
        (dolist (path created)
          (is equal '() (%licence-markers-in (uiop:read-file-string path))
              "~A carries no licence text" path))))))

(defun %octets (path)
  "Return the contents of PATH as a vector of octets."
  (with-open-file (in path :element-type '(unsigned-byte 8))
    (let ((octets (make-array (file-length in) :element-type '(unsigned-byte 8))))
      (read-sequence octets in)
      octets)))

(defun %tracked-octets (root)
  "Return an alist of (RELATIVE-PATH . OCTETS) for every file ROOT tracks."
  (mapcar (lambda (path)
            (cons path (%octets (merge-pathnames
                                 path (uiop:ensure-directory-pathname root)))))
          (git-tracked-files root)))

(defun %changed-tracked-files (before root)
  "Return the paths in BEFORE, a %TRACKED-OCTETS result, whose octets in ROOT differ.
A path no longer present counts as changed."
  (loop for (path . octets) in before
        for file = (merge-pathnames path (uiop:ensure-directory-pathname root))
        unless (and (probe-file file) (equalp octets (%octets file)))
          collect path))

(defun %licence-named-p (path)
  "Return true when PATH's file name contains licence, license, copying or
notice, ignoring case."
  (let ((name (file-namestring path)))
    (and (some (lambda (word) (search word name :test #'char-equal))
               '("licence" "license" "copying" "notice"))
         t)))

(defun %licence-named-files (root)
  "Return, sorted, every licence-named file under ROOT outside its git directory,
as it reads from ROOT."
  (let* ((base (uiop:ensure-directory-pathname root))
         (prefix (length (namestring base)))
         (found '()))
    (flet ((outside-git-p (directory)
             (not (equal ".git" (car (last (pathname-directory directory)))))))
      (uiop:collect-sub*directories
       base #'outside-git-p #'outside-git-p
       (lambda (directory)
         (dolist (file (uiop:directory-files directory))
           (when (%licence-named-p file)
             (push (subseq (namestring file) prefix) found))))))
    (sort found #'string<)))

(defun %new-licence-files (before root)
  "Return the licence-named files in ROOT that are not in the list BEFORE."
  (set-difference (%licence-named-files root) before :test #'string=))

(defun %licensed-foreign-fixture (root)
  "Give ROOT the committed shape of a third-party library carrying its own licence.

The licence-shaped content is synthetic and names an example owner; it is not
a copy of any real licence text."
  (%clear-ambient-ignores root)
  (fixture-commit-file root "LICENSE"
                       (format nil "Example Licence~%~%Copyright (c) 2026 Example Owner~%~%~
Redistribution and use of this example are permitted on the terms the example~%~
owner chose for it.~%"))
  (fixture-commit-file root "COPYING"
                       (format nil "See LICENSE for the terms of this example.~%"))
  (fixture-commit-file root "example.asd"
                       (format nil "(asdf:defsystem \"example\"~%  :license \"BSD-2-Clause\"~%  :components ((:file \"src/example\")))~%"))
  (fixture-commit-file root "src/example.lisp"
                       (format nil ";;;; Copyright (c) 2026 Example Owner~%~
;;;; SPDX-License-Identifier: BSD-2-Clause~%~%(defpackage #:example (:use #:cl))~%"))
  root)

(define-test a-foreign-adoption-leaves-the-licence-byte-identical
  "Repair and then record-as-debt over a foreign repository with its own licence
leave every tracked file byte-identical and create no licence-named file.

The debt run branches on the linter being installed: present, the baseline is
written and must carry no licence text; absent, the run must say the debt was
not enumerated."
  (with-fixture-template ()
    (with-temp-git-repo (root :origin-url +third-party-origin-url+
                              :initial-file "README.md" :initial-content "x")
      (%licensed-foreign-fixture root)
      (let ((before (%tracked-octets root))
            (names-before (%licence-named-files root)))
        (true (assoc "LICENSE" before :test #'string=)
              "precondition: the fixture tracks its licence")
        (is equal '("COPYING" "LICENSE") names-before
            "precondition: the name scan sees the fixture's licence files")
        (let ((repair (normalise-repository root :policy :repair)))
          (true (report-changed repair)
                "the repair wrote something, so the comparison is about a run"))
        (let ((debt (normalise-repository root :policy :record-as-debt)))
          (if (gate-scanner-available-p (linter-path))
              (let ((baseline (merge-pathnames ".gate-baseline.md" root)))
                (is eq :created (getf (report-debt-baseline debt) :action-taken)
                    "with the linter installed the baseline is written")
                (is equal '() (%licence-markers-in
                               (uiop:read-file-string baseline))
                    "and the baseline carries no licence text"))
              (is eq :not-enumerated
                  (getf (report-debt-baseline debt) :action-taken)
                  "with no linter installed the debt is not enumerated")))
        (is equal '() (%changed-tracked-files before root)
            "every tracked file is byte-identical after both runs")
        (is equal '() (%new-licence-files names-before root)
            "no licence-named file was created")))))

(define-test control-a-writer-touching-the-licence-is-caught
  "CONTROL for the byte-identity check. A repair writer that also appends to
LICENSE makes the same comparison report LICENSE as changed."
  (with-fixture-template ()
    (with-temp-git-repo (root :origin-url +third-party-origin-url+
                              :initial-file "README.md" :initial-content "x")
      (%licensed-foreign-fixture root)
      (let* ((before (%tracked-octets root))
             (licence (merge-pathnames "LICENSE" root))
             (original *repair-writer*)
             (*repair-writer*
               (lambda (path content)
                 (prog1 (funcall original path content)
                   (with-open-file (out licence :direction :output
                                                :if-exists :append)
                     (write-line "appended" out))))))
        (normalise-repository root :policy :repair)
        (is equal '("LICENSE") (%changed-tracked-files before root)
            "the comparison sees the licence change, and only that")))))

(define-test control-a-planted-licence-file-is-caught
  "CONTROL for the name scan. A file named LICENSE-extra planted after a run is
reported as a new licence-named file."
  (with-fixture-template ()
    (with-temp-git-repo (root :origin-url +third-party-origin-url+
                              :initial-file "README.md" :initial-content "x")
      (%licensed-foreign-fixture root)
      (let ((names-before (%licence-named-files root)))
        (normalise-repository root :policy :repair)
        (write-fixture-file root "LICENSE-extra" "planted")
        (is equal '("LICENSE-extra") (%new-licence-files names-before root)
            "the scan sees the planted file, and only that")))))

(defun %adopt-unlicensed (root declared)
  "Commit an unlicensed source file to ROOT, then run repair and record-as-debt
over it, passing DECLARED as the classification. Return the repair report."
  (%clear-ambient-ignores root)
  (fixture-commit-file root "example.lisp" ";; no licence anywhere")
  (prog1 (normalise-repository root :policy :repair
                                    :declared-classification declared)
    (normalise-repository root :policy :record-as-debt
                               :declared-classification declared)))

(define-test a-repository-of-ours-is-given-no-licence-file
  "A repository of ours, declared on the call or a declared hard fork, ends a
repair and a record-as-debt run with no licence-named file.

The licence item sits in the convenience tier, which no profile the doctor
assesses holds; the control below widens that and watches a LICENSE appear."
  (with-fixture-template ()
    (with-temp-git-repo (root :origin-url +ours-origin-url+
                              :initial-file "README.md" :initial-content "x")
      (let ((report (%adopt-unlicensed root :ours)))
        (true (report-changed report)
              "the repair of a declared-ours repository wrote something"))
      (is equal '() (%licence-named-files root)
          "declared ours on the call: no licence-named file")))
  (with-fixture-template ()
    (with-temp-git-repo (root :origin-url "git@github.com:fade/zebra.git"
                              :initial-file "README.md" :initial-content "x")
      (let ((report (%adopt-unlicensed root nil)))
        (true (report-changed report)
              "the repair of a declared hard fork wrote something"))
      (is equal '() (%licence-named-files root)
          "a declared hard fork: no licence-named file"))))

(define-test control-a-widened-ours-profile-writes-a-licence
  "CONTROL. With the convenience tier assessed for :OURS the same repair writes a
LICENSE, so the absence asserted above is one the scan can see."
  (with-fixture-template ()
    (with-temp-git-repo (root :origin-url +ours-origin-url+
                              :initial-file "README.md" :initial-content "x")
      (let ((*assessed-tiers* '((:ours . (:invariant :gate :convenience))
                                (:foreign . ()))))
        (%adopt-unlicensed root :ours))
      (true (member "LICENSE" (%licence-named-files root) :test #'string=)
            "a LICENSE appears once the convenience tier is assessed"))))
