;;;; src/project-debt.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; What happens when the quality gate meets a repository that cannot yet
;;;; satisfy it.
;;;;
;;;; The answer is a severity, not a number. Installing the gate at a recording
;;;; severity keeps every pre-existing site visible without failing the build,
;;;; and raising it later is a separate deliberate act. The alternative, a gate
;;;; that blocks on day one, does not survive contact with a real codebase: a
;;;; rule that blocks before the codebase can satisfy it just gets switched off,
;;;; and switched off it reports nothing at all.
;;;;
;;;; Nothing here derives that severity from a measurement of the repository.
;;;; Development tempo and the number of people committing were both measured
;;;; across the whole population of repositories on this host, and no ordering
;;;; of either reproduces the one calibration on record: the repository judged
;;;; least urgent is busier and older than one already gated, with the same
;;;; number of contributors. A number built from those signals would contradict
;;;; that judgement confidently, and a number is believed precisely because it
;;;; is a number. So the starting severity is a judgement written down in one
;;;; place, where it can be read, argued with and changed in one line.
;;;;
;;;; The three categories a frozen site can carry are the three decisions the
;;;; deviation module already names, one for one:
;;;;
;;;;   ACCEPT-AS-DELIBERATE  -> :CORRECT-AS-WRITTEN
;;;;   RECORD-AS-DEBT        -> :FROZEN-WITH-DIAGNOSIS
;;;;   REPAIR                -> :DEMONSTRATED-DEFECTIVE
;;;;
;;;; A parallel vocabulary here would mean a site described one way when a
;;;; decision is taken and another way when it is written down.
;;;;
;;;; This module renders text and touches no file. Where the baseline is written
;;;; and what is excluded before it is written belong to the layer that owns
;;;; writes.

(defpackage #:dsmr-mcp/src/project-debt
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/project-scaffold-core
                #:render-template)
  (:import-from #:dsmr-mcp/src/project-scaffold-templates
                #:*mallet-config-template*
                #:*lint-lisp-template*
                #:*pre-commit-hook-template*)
  (:export #:*severity-ladder*
           #:*adopted-repo-gate-severity*
           #:adopted-repo-gate-severity
           #:severity-at-least-p
           #:validate-severity
           #:invalid-severity-error
           #:invalid-severity-value
           #:+debt-categories+
           #:validate-debt-category
           #:invalid-debt-category-error
           #:invalid-debt-category-value
           #:render-gate-config
           #:render-lint-script
           #:render-pre-commit-hook
           #:render-debt-baseline))

(in-package #:dsmr-mcp/src/project-debt)

;;; ---------------------------------------------------------------------------
;;; The two vocabularies, and the one judgement
;;;
;;; Defined ahead of the conditions that report against them, so the reports can
;;; name what they expected.
;;; ---------------------------------------------------------------------------

(defvar *severity-ladder* '(:info :warning :error)
  "The gate severities, in increasing order of consequence.

:INFO records, :WARNING draws attention, :ERROR refuses the commit. Order is
carried by position in this list rather than by a separate table, so a severity
that exists always has a place in the ordering.

DEFVAR rather than DEFCONSTANT: a constant bound to a list re-evaluates to a
fresh, non-EQL list on reload and breaks a warm image.")

(defvar +debt-categories+
  '(:correct-as-written :frozen-with-diagnosis :demonstrated-defective)
  "Every category a frozen site may carry.

One for one with the decisions the deviation module names: an acceptance is
:CORRECT-AS-WRITTEN, a recording is :FROZEN-WITH-DIAGNOSIS, and a repair is
:DEMONSTRATED-DEFECTIVE. Named as a constant, defined with DEFVAR, for the same
warm-image reason as the ladder above.")

(defvar *adopted-repo-gate-severity* :info
  "The severity a quality gate is installed at in a newly adopted repository.

This is the severity used where the repository already contains sites the rule
would fire on. It records rather than blocks, because a rule that blocks before
the codebase can satisfy it just gets switched off, and switched off it protects
nothing at all. Promotion to a blocking severity is a separate deliberate act,
taken once the repository can satisfy the rule.

The value is a judgement the developer owns. It is not derived from any
measurement of the repository, and deliberately so: development tempo and
contributor counts were both measured across the whole population of
repositories here, and no ordering of either reproduces the one calibration on
record. Nothing in this module computes anything from a repository's history,
and a test asserts that nothing ever starts to.

Being one variable in one file is the point. A different ruling about where an
adopted repository should start costs exactly this line.")

;;; ---------------------------------------------------------------------------
;;; Conditions
;;; ---------------------------------------------------------------------------

(define-condition invalid-severity-error (error)
  ((value :initarg :value :reader invalid-severity-value))
  (:documentation
   "Signaled when something that is not a gate severity is offered as one.

Rendering a configuration around an unrecognised severity would produce a linter
configuration the linter cannot read, discovered at the developer's next commit
rather than here.")
  (:report
   (lambda (condition stream)
     (format stream "~S is not a gate severity. Expected one of ~S."
             (invalid-severity-value condition)
             *severity-ladder*))))

(setf (documentation 'invalid-severity-value 'function)
      "Return the object that was offered as a gate severity and rejected.")

(define-condition invalid-debt-category-error (error)
  ((value :initarg :value :reader invalid-debt-category-value))
  (:documentation
   "Signaled when a frozen site carries a category outside the settled three.

The categories are the decisions the deviation module names. A fourth one
appearing in a baseline means a site was classified by something that does not
share that vocabulary, and the record would describe the site in terms nothing
else in the system understands.")
  (:report
   (lambda (condition stream)
     (format stream "~S is not a debt category. Expected one of ~S."
             (invalid-debt-category-value condition)
             +debt-categories+))))

(setf (documentation 'invalid-debt-category-value 'function)
      "Return the object that was offered as a debt category and rejected.")

;;; ---------------------------------------------------------------------------
;;; Severity: validation, ordering, and the call-time override
;;; ---------------------------------------------------------------------------

(defun validate-severity (severity)
  "Return SEVERITY when it names a gate severity, else signal.

Signals INVALID-SEVERITY-ERROR rather than returning a default. A caller that
handed us something unrecognised has a bug, and quietly substituting :INFO for
it would install a gate nobody asked for at a severity nobody chose."
  (unless (member severity *severity-ladder*)
    (error 'invalid-severity-error :value severity))
  severity)

(defun severity-at-least-p (severity floor)
  "Return true when SEVERITY sits at or above FLOOR on the ladder.

Both arguments are validated, so an unrecognised severity is a signal rather
than a comparison against a position that does not exist."
  (validate-severity severity)
  (validate-severity floor)
  (>= (position severity *severity-ladder*)
      (position floor *severity-ladder*)))

(defun %severity-from-string (string)
  "Return the ladder severity STRING names, or NIL when it names none.
Accepts \"info\", \":info\" and \"INFO\" alike: this reads an environment
variable, and the developer setting one should not have to guess our spelling."
  (let* ((trimmed (string-trim '(#\Space #\Tab #\Newline #\Return) string))
         (bare    (if (and (plusp (length trimmed))
                           (char= #\: (char trimmed 0)))
                      (subseq trimmed 1)
                      trimmed)))
    (find bare *severity-ladder*
          :test (lambda (name severity)
                  (string-equal name (symbol-name severity))))))

(defun adopted-repo-gate-severity ()
  "Return the severity a gate is installed at in a newly adopted repository.

Reads DSMR_GATE_SEVERITY at call time, so a developer can override the starting
severity for one run without editing anything. An override that names no ladder
severity signals INVALID-SEVERITY-ERROR: a misspelled override that silently
fell back to the default would install a gate at a severity the developer
believes he changed."
  (let ((override (uiop:getenv "DSMR_GATE_SEVERITY")))
    (if (and override (plusp (length (string-trim " " override))))
        (or (%severity-from-string override)
            (error 'invalid-severity-error :value override))
        *adopted-repo-gate-severity*)))

;;; ---------------------------------------------------------------------------
;;; Debt categories
;;; ---------------------------------------------------------------------------

(defun validate-debt-category (category)
  "Return CATEGORY when it is one of the three, else signal.

Signals INVALID-DEBT-CATEGORY-ERROR. Rendering an unrecognised category into
the baseline would put a word in a record that outlives everyone who knew what
it was supposed to mean."
  (unless (member category +debt-categories+)
    (error 'invalid-debt-category-error :value category))
  category)

;;; ---------------------------------------------------------------------------
;;; Rendering the gate itself
;;; ---------------------------------------------------------------------------

(defun %severity-literal (severity)
  "Return SEVERITY as the text a linter configuration reads, e.g. \":info\"."
  (string-downcase (format nil "~S" severity)))

(defun %gate-bindings (severity project-name spdx)
  "Return the substitution alist the three gate templates are rendered from."
  (list (cons "gate-severity" (%severity-literal severity))
        (cons "name" (or project-name ""))
        (cons "spdx" (or spdx "AGPL-3.0-or-later"))))

(defun render-gate-config (&key (severity (adopted-repo-gate-severity))
                                project-name
                                spdx)
  "Return the text of a linter configuration installed at SEVERITY.

SEVERITY is validated before anything is rendered, so an unrecognised one never
reaches a file."
  (validate-severity severity)
  (render-template *mallet-config-template*
                   (%gate-bindings severity project-name spdx)))

(defun render-lint-script (&key (severity (adopted-repo-gate-severity))
                                project-name
                                spdx)
  "Return the text of the lint runner script for a project.

Takes SEVERITY for symmetry with the other two renderers and validates it, so a
caller rendering the whole gate at one severity cannot get two of the three
files and a signal on the third."
  (validate-severity severity)
  (render-template *lint-lisp-template*
                   (%gate-bindings severity project-name spdx)))

(defun render-pre-commit-hook (&key (severity (adopted-repo-gate-severity))
                                    project-name
                                    spdx)
  "Return the text of the pre-commit hook for a project."
  (validate-severity severity)
  (render-template *pre-commit-hook-template*
                   (%gate-bindings severity project-name spdx)))

;;; ---------------------------------------------------------------------------
;;; Rendering the frozen baseline
;;; ---------------------------------------------------------------------------

(defun %site-position (site)
  "Return the position of SITE as file:line or file:line:column."
  (let ((file   (getf site :file))
        (line   (getf site :line))
        (column (getf site :column)))
    (cond ((and line column) (format nil "~A:~A:~A" file line column))
          (line              (format nil "~A:~A" file line))
          (t                 (format nil "~A" file)))))

(defun %site-callee-knowable (site)
  "Return what SITE records about whether its callee is knowable.

Absent means nothing was determined, and that is what gets printed. Printing
\"unknown\" where nothing was measured is how a record starts being believed for
more than it says."
  (or (getf site :callee-knowable) :not-determined))

(defun %site-note (site)
  "Return the intended fix recorded for SITE, or a phrase saying there is none."
  (let ((note (getf site :note)))
    (if (and note (stringp note) (plusp (length note)))
        note
        "not recorded")))

(defun %baseline-row (site)
  "Return one table row for SITE, validating its category first."
  (validate-debt-category (getf site :category))
  (format nil "| ~A | ~(~S~) | ~(~S~) | ~A | ~A | ~A |"
          (%site-position site)
          (%site-callee-knowable site)
          (getf site :category)
          (or (getf site :rule) "")
          (or (getf site :message) "")
          (%site-note site)))

(defun render-debt-baseline (&key repo-name classification severity sites)
  "Return the text of the frozen quality-gate baseline for a repository.

REPO-NAME names the repository, CLASSIFICATION says what kind of repository it
was found to be, SEVERITY is the severity the gate was installed at, and SITES
is a list of site plists carrying :FILE :LINE :COLUMN :RULE :SEVERITY :MESSAGE
:CALLEE-KNOWABLE :CATEGORY and :NOTE.

Every site's category is validated. An empty SITES renders a sentence saying so
in place of the table, because an empty table and a baseline nobody ever
populated look identical on the page, and the one that was never populated would
be read as a clean repository."
  (validate-severity severity)
  (let ((rows (mapcar #'%baseline-row sites)))
    (with-output-to-string (out)
      (format out "# Quality gate baseline: ~A~%~%" (or repo-name "this repository"))
      (format out "Repository kind: ~(~S~)~%" (or classification :unclassified))
      (format out "Gate installed at severity: ~(~S~)~%" severity)
      (format out "Sites recorded: ~D~%~%" (length sites))
      (format out "These sites were present when the gate was installed. Freezing~%")
      (format out "them here is a record of what was already in the tree, not an~%")
      (format out "endorsement of any of it, and not a claim that any of it is wrong.~%~%")
      (format out "The gate runs at ~(~S~), so every finding stays visible without~%"
              severity)
      (format out "failing the build. A rule that blocks before the codebase can~%")
      (format out "satisfy it just gets switched off, and switched off it reports~%")
      (format out "nothing at all. Promotion to a blocking severity is a separate~%")
      (format out "deliberate act, taken once the repository can satisfy the rule.~%~%")
      (format out "Callee knowability is meaningful only where a site handles a~%")
      (format out "condition, and no linter determines it for an arbitrary rule. A~%")
      (format out "site the scan did not examine for it says so rather than guessing.~%~%")
      (if (null rows)
          (progn
            (format out "No pre-existing sites were found. The scan ran over this~%")
            (format out "repository and reported nothing, which is an empty result~%")
            (format out "from a scan that happened rather than a baseline that was~%")
            (format out "never populated.~%"))
          (progn
            (format out "| Position | Callee knowable | Category | Rule | Finding | Intended fix |~%")
            (format out "|---|---|---|---|---|---|~%")
            (dolist (row rows)
              (format out "~A~%" row)))))))
