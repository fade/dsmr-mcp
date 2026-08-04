;;;; tests/doctor/project-debt-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Parachute tests for the severity ladder, the gate renderers and the frozen
;;;; baseline. Nothing here touches a filesystem, a repository or a subprocess:
;;;; the module renders text and decides nothing else.
;;;;
;;;; Three of the properties defended here are the kind that pass against an
;;;; implementation doing nothing at all, so each is watched from a second side.
;;;;
;;;; A renderer that ignored its severity and hardcoded one satisfies any single
;;;; assertion that the output carries a severity. So the config is rendered at
;;;; two severities in one test, and the two outputs must differ and must each
;;;; carry its own.
;;;;
;;;; An empty table and a baseline nobody managed to populate look identical on
;;;; the page. The empty case is therefore required to say in words which of the
;;;; two it is, and required not to emit the table header at all, in the same
;;;; test that requires a populated baseline to emit both.
;;;;
;;;; The decision not to compute a number from a repository's history is enforced
;;;; by asking the package at run time what it exports, rather than by grepping
;;;; the source. A grep is satisfied by a symbol spelled differently; the package
;;;; is not, and it is still answering the question long after the reasoning
;;;; behind the decision has scrolled out of everyone's memory.

;; Package evolution guard - delete prior definition on warm reload.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/doctor/project-debt-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/doctor/project-debt-test
  (:use #:cl #:parachute)
  (:import-from #:dsmr-mcp/src/project-debt
                #:*severity-ladder*
                #:*adopted-repo-gate-severity*
                #:adopted-repo-gate-severity
                #:severity-at-least-p
                #:validate-severity
                #:invalid-severity-error
                #:invalid-severity-value
                #:+debt-categories+
                #:validate-debt-category
                #:invalid-debt-category-error
                #:render-gate-config
                #:render-lint-script
                #:render-pre-commit-hook
                #:render-debt-baseline))

(in-package #:dsmr-mcp/tests/doctor/project-debt-test)

;;; ---------------------------------------------------------------------------
;;; Helpers
;;; ---------------------------------------------------------------------------

(defparameter +one-site+
  (list :file "src/handler.lisp"
        :line 42
        :column 7
        :rule "no-ignore-errors"
        :severity "warning"
        :message "Avoid using ignore-errors"
        :callee-knowable :not-determined
        :category :frozen-with-diagnosis
        :note "narrow to the condition the call can actually raise")
  "One site in the shape the scanner produces and the renderer consumes.")

(defparameter +table-header-marker+ "| Position | Callee knowable |"
  "The opening of the site table. Its absence is what the empty case asserts.")

(defparameter +no-sites-marker+ "No pre-existing sites were found"
  "The sentence the empty case must say in place of a table.")

(defun contains-p (haystack needle)
  "Return true when NEEDLE occurs in HAYSTACK."
  (and (search needle haystack) t))

;;; ---------------------------------------------------------------------------
;;; The ladder
;;; ---------------------------------------------------------------------------

(define-test the-ladder-is-ordered-low-to-high
  "The three severities in increasing order of consequence."
  (is equal '(:info :warning :error) *severity-ladder*))

(define-test severity-ordering-answers-both-ways
  "SEVERITY-AT-LEAST-P is asserted in both directions.

A predicate returning T unconditionally satisfies half of this, and a predicate
returning NIL unconditionally satisfies the other half. Neither survives both."
  (true  (severity-at-least-p :warning :info))
  (true  (severity-at-least-p :error :info))
  (true  (severity-at-least-p :info :info))
  (false (severity-at-least-p :info :warning))
  (false (severity-at-least-p :warning :error)))

(define-test the-starting-severity-records-rather-than-blocks
  "The severity an adopted repository starts at does not fail a build.

This is the behaviour the whole approach rests on: a gate installed above the
recording severity on a repository that cannot satisfy it gets switched off, and
switched off it reports nothing at all."
  (is eq :info *adopted-repo-gate-severity*)
  (false (severity-at-least-p (adopted-repo-gate-severity) :warning)
         "the starting severity sits below the blocking ones"))

;;; ---------------------------------------------------------------------------
;;; Severity injection
;;; ---------------------------------------------------------------------------

(define-test the-severity-reaches-the-rendered-gate-config
  "SEVERITY-INJECTION CONTROL. Rendered at two severities in one test.

A renderer that ignores its argument and writes a fixed severity passes any
single-severity assertion perfectly. Requiring the two outputs to differ, and
each to carry its own severity and not the other's, is what that renderer fails."
  (let ((at-info    (render-gate-config :severity :info))
        (at-warning (render-gate-config :severity :warning)))
    (false (contains-p at-info "{{gate-severity}}")
           "the placeholder is gone from the rendered config")
    (false (contains-p at-warning "{{gate-severity}}")
           "the placeholder is gone at the other severity too")
    (true  (contains-p at-info ":info")
           "rendering at :info produces :info")
    (true  (contains-p at-warning ":warning")
           "rendering at :warning produces :warning")
    (false (contains-p at-info ":warning")
           "rendering at :info does not produce :warning")
    (false (contains-p at-warning ":info")
           "rendering at :warning does not produce :info")
    (false (string= at-info at-warning)
           "the two renderings differ")))

(define-test the-other-two-gate-files-render
  "The lint script and the hook render, and carry no unsubstituted placeholder."
  (let ((script (render-lint-script :severity :info :spdx "AGPL-3.0-or-later"))
        (hook   (render-pre-commit-hook :severity :info :spdx "AGPL-3.0-or-later")))
    (true (plusp (length script)) "the lint script renders to something")
    (true (plusp (length hook))   "the hook renders to something")
    (false (contains-p script "{{spdx}}") "the script carries no raw placeholder")
    (false (contains-p hook "{{spdx}}")   "the hook carries no raw placeholder")
    (true (contains-p script "mallet")
          "the script names the linter it runs")
    (true (contains-p hook "lint-lisp.sh")
          "the hook runs the repository's own lint script and nothing else")))

;;; ---------------------------------------------------------------------------
;;; The frozen baseline
;;; ---------------------------------------------------------------------------

(define-test the-baseline-reads-as-a-record-rather-than-an-endorsement
  "The document says what it is, at what severity, and what promotion costs."
  (let ((text (render-debt-baseline :repo-name "some-library"
                                    :classification :foreign-orphan
                                    :severity :info
                                    :sites (list +one-site+))))
    (true (contains-p text "some-library")   "the document names the repository")
    (true (contains-p text "foreign-orphan") "it names what kind of repository it is")
    (true (contains-p text "not an")         "it says it is not an endorsement")
    (true (contains-p text "endorsement")    "in those words")
    (true (contains-p text ":info")          "it states the severity installed at")
    (true (contains-p text "separate")       "it says promotion is separate")
    (true (contains-p text "deliberate act") "and deliberate")))

(define-test an-empty-baseline-says-so-and-a-populated-one-shows-its-row
  "EMPTY-BASELINE CONTROL. Both cases asserted against each other in one test.

A renderer emitting an empty table for an empty site list is indistinguishable
on the page from a baseline nobody ever populated, and this phase asserts mostly
on absence. So the empty case must carry the sentence and must NOT carry the
table header, while the populated case must carry the header and the row. Split
across two tests, deleting either leaves a green suite that cannot tell the two
apart."
  (let ((empty      (render-debt-baseline :repo-name "quiet-repo"
                                          :classification :ours
                                          :severity :info
                                          :sites '()))
        (populated  (render-debt-baseline :repo-name "loud-repo"
                                          :classification :ours
                                          :severity :info
                                          :sites (list +one-site+))))
    (true  (contains-p empty +no-sites-marker+)
           "the empty document says no sites were found")
    (false (contains-p empty +table-header-marker+)
           "the empty document emits no table at all")
    (true  (contains-p empty "Sites recorded: 0")
           "the empty document states the count it is reporting")
    (true  (contains-p populated +table-header-marker+)
           "the populated document emits the table")
    (true  (contains-p populated "src/handler.lisp:42:7")
           "the row carries the site's position")
    (true  (contains-p populated ":not-determined")
           "the row carries callee knowability verbatim")
    (true  (contains-p populated ":frozen-with-diagnosis")
           "the row carries the site's category")
    (true  (contains-p populated "narrow to the condition")
           "the row carries the intended fix where one is known")
    (false (contains-p populated +no-sites-marker+)
           "the populated document does not also claim nothing was found")))

(define-test an-unmeasured-knowability-is-printed-as-unmeasured
  "A site with no knowability recorded says so rather than reading as unknown.

Printing a word that sounds like a measurement where nothing was measured is how
a record starts being believed for more than it says."
  (let ((text (render-debt-baseline
               :repo-name "r" :classification :ours :severity :info
               :sites (list (list :file "src/a.lisp" :line 1
                                  :category :frozen-with-diagnosis)))))
    (true (contains-p text ":not-determined")
          "an absent knowability renders as not determined")))

;;; ---------------------------------------------------------------------------
;;; Validation
;;; ---------------------------------------------------------------------------

(define-test an-unknown-severity-signals-rather-than-rendering
  "VALIDATION CONTROL, first half. Nothing is produced from a severity we do not
know.

A renderer substituting a default for an unrecognised severity would write a
gate at a severity nobody chose, and the developer who misspelled it would
believe he had changed it."
  (fail (validate-severity :critical) 'invalid-severity-error)
  (fail (validate-severity nil) 'invalid-severity-error)
  (fail (validate-severity "info") 'invalid-severity-error
        "a string is not a severity, however it is spelled")
  (fail (render-gate-config :severity :critical) 'invalid-severity-error)
  (fail (render-lint-script :severity :critical) 'invalid-severity-error)
  (fail (render-pre-commit-hook :severity :critical) 'invalid-severity-error)
  (fail (render-debt-baseline :repo-name "r" :classification :ours
                              :severity :critical :sites '())
        'invalid-severity-error)
  (handler-case (progn (validate-severity :critical) nil)
    (invalid-severity-error (condition)
      (is eq :critical (invalid-severity-value condition)
          "the condition carries what was rejected"))))

(define-test an-unknown-debt-category-signals
  "VALIDATION CONTROL, second half. The three categories are the only three.

A fourth category reaching a baseline means a site was classified by something
that does not share this vocabulary, and the record would describe the site in
terms nothing else in the system understands."
  (is equal '(:correct-as-written :frozen-with-diagnosis :demonstrated-defective)
      +debt-categories+)
  (is eq :correct-as-written (validate-debt-category :correct-as-written))
  (is eq :frozen-with-diagnosis (validate-debt-category :frozen-with-diagnosis))
  (is eq :demonstrated-defective (validate-debt-category :demonstrated-defective))
  (fail (validate-debt-category :probably-fine) 'invalid-debt-category-error)
  (fail (validate-debt-category nil) 'invalid-debt-category-error)
  (fail (render-debt-baseline
         :repo-name "r" :classification :ours :severity :info
         :sites (list (list :file "src/a.lisp" :line 1 :category :probably-fine)))
        'invalid-debt-category-error
        "a bad category in a site stops the baseline being rendered"))

;;; ---------------------------------------------------------------------------
;;; The negative result, enforced
;;; ---------------------------------------------------------------------------

(define-test the-module-exports-nothing-that-computes-a-number
  "NO-SCORE CONTROL. Asked of the package at run time, not of the source text.

Development tempo and contributor counts were measured across the whole
population of repositories here and no ordering of either reproduces the one
calibration on record, so a number derived from them would contradict that
calibration confidently and would be believed for being a number. Risk weighting
is a severity instead.

This is the check that keeps the decision after the reasoning behind it has
scrolled out of everyone's memory. A grep over the source is satisfied by a
symbol spelled differently and by a function that was never exported; asking the
package what it offers is not."
  (let ((offending '()))
    (do-external-symbols (symbol (find-package "DSMR-MCP/SRC/PROJECT-DEBT"))
      (let ((name (symbol-name symbol)))
        (when (or (search "SCORE" name)
                  (search "WEIGHT" name)
                  (search "TEMPO" name)
                  (search "RANK" name))
          (push name offending))))
    (is equal '() offending
        "the module exports no symbol named for a computed number: ~S" offending))
  (true (find-package "DSMR-MCP/SRC/PROJECT-DEBT")
        "precondition: the package this control inspects exists")
  (true (member :info *severity-ladder*)
        "what replaces the number is a severity on a ladder"))
