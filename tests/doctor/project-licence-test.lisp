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
                #:report-changed)
  (:import-from #:dsmr-mcp/src/project-shape
                #:shape-item-key
                #:shape-item-generator
                #:item-disposition
                #:*shape-catalog*)
  (:import-from #:dsmr-mcp/src/project-shape-catalog
                #:catalog-item)
  (:import-from #:dsmr-mcp/src/project-debt
                #:adopted-repo-gate-severity)
  (:import-from #:dsmr-mcp/src/project-exclude
                #:*exclude-template-path*)
  (:import-from #:dsmr-mcp/src/git
                #:run-git)
  (:import-from #:dsmr-mcp/tests/support/git-fixture
                #:with-temp-git-repo
                #:fixture-commit-file
                #:seed-exclude-patterns
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
   (dsmr-mcp/src/project-doctor::%repo-name root)))

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
