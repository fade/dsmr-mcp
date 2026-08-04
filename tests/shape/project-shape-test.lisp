;;;; tests/shape/project-shape-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Parachute tests for the shape representation and the declared catalog.
;;;;
;;;; The property that matters most here is a negative one: our operational
;;;; apparatus is never tracked in a repository we do not own. A negative
;;;; property is exactly the kind that passes when the instrument is pointed at
;;;; nothing, so the assertions below iterate the live catalog rather than a
;;;; hand-picked item, and each is paired with a control that was watched failing
;;;; before its green was believed.
;;;;
;;;; The other thing under test is a claim about where a decision lives. The
;;;; tiers, the scaffold flags and the profile-to-tier mapping are provisional,
;;;; and the whole value of that being true is that changing them costs one edit
;;;; to one data file. A test that only reads the mapping cannot tell whether it
;;;; is still the mapping in force, so the control here changes it and asserts
;;;; the change is observed.

;; Package evolution guard - delete prior definition on warm reload.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/shape/project-shape-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/shape/project-shape-test
  (:use #:cl #:parachute)
  (:import-from #:dsmr-mcp/src/project-shape
                #:shape-item
                #:make-shape-item
                #:shape-item-key
                #:shape-item-path
                #:shape-item-tier
                #:shape-item-group
                #:shape-item-apparatus-p
                #:shape-item-emit-on-scaffold-p
                #:item-disposition
                #:shape-items-for-profile
                #:shape-group-items
                #:*shape-catalog*
                #:+tiers+
                #:invalid-shape-item-error)
  (:import-from #:dsmr-mcp/src/project-shape-catalog
                #:catalog-item
                #:*assessed-tiers*
                #:assessed-tiers-for-profile
                #:apparatus-paths-for-profile
                #:unknown-profile-error)
  (:import-from #:dsmr-mcp/src/project-scaffold-core
                #:render-template
                #:plan-scaffold))

(in-package #:dsmr-mcp/tests/shape/project-shape-test)

;;; --- helpers ----------------------------------------------------------------

(defvar *sample-name* "sample-project"
  "The project name both sides of the parity check are rendered with.")

(defun sample-bindings ()
  "Return the bindings a catalog path is rendered with for the parity check."
  (list (cons "name" *sample-name*)))

(defun emitted-paths (&optional (catalog *shape-catalog*))
  "Return the relative paths CATALOG says the scaffold writes, in order.

Reads the catalog argument on every call, so binding *SHAPE-CATALOG* changes the
answer. A version that closed over a fixed list would satisfy the parity
assertion below no matter what the catalog said."
  (mapcar (lambda (item)
            (render-template (shape-item-path item) (sample-bindings)))
          (remove-if-not #'shape-item-emit-on-scaffold-p catalog)))

(defun scaffold-paths ()
  "Return the relative paths the scaffold actually writes today, in order."
  (mapcar #'car
          (plan-scaffold :name *sample-name*
                         :description "a sample"
                         :author "somebody")))

(defun apparatus-items (&optional (catalog *shape-catalog*))
  "Return the items in CATALOG that are our own operational apparatus."
  (remove-if-not #'shape-item-apparatus-p catalog))

(defun synthetic-catalog ()
  "Return a two-item catalog with one apparatus item and one ordinary item.

Deliberately unlike the real one: different keys, different paths, one of each
kind. An assertion that reads the real catalog regardless will not see these."
  (list (make-shape-item :key :synthetic-apparatus
                         :path "SYNTHETIC-APPARATUS.md"
                         :tier :convenience
                         :apparatus-p t
                         :assertion :file-exists
                         :match "SYNTHETIC-APPARATUS.md")
        (make-shape-item :key :synthetic-content
                         :path "synthetic-content.txt"
                         :tier :convenience
                         :assertion :file-exists
                         :match "synthetic-content.txt")))

;;; --- disposition ------------------------------------------------------------

(define-test every-apparatus-item-is-excluded-in-a-foreign-repository
  "Our apparatus is never tracked in a repository we do not own.

Iterates the whole catalog rather than sampling it: this is the one property
whose failure reaches a third party's history, and a sample cannot report on the
item somebody adds next."
  (let ((items (apparatus-items)))
    (true (plusp (length items))
          "The catalog declares at least one apparatus item to test.")
    (dolist (item items)
      (is eql :excluded (item-disposition item :foreign)
          "~S is excluded under the foreign profile." (shape-item-key item)))))

(define-test every-apparatus-item-is-tracked-in-our-own-repository
  "The same files are ordinary tracked content in a repository we own.

Without this the excluded-in-foreign assertion is satisfied by a function that
excludes everything everywhere, which would be a different bug."
  (dolist (item (apparatus-items))
    (is eql :tracked (item-disposition item :ours)
        "~S is tracked under our own profile." (shape-item-key item))))

(define-test ordinary-project-content-is-tracked-under-either-profile
  "A file that is the project's own content is tracked whoever owns the repo."
  (let ((readme (catalog-item :readme)))
    (true readme "The catalog declares a README item.")
    (is eql :tracked (item-disposition readme :ours))
    (is eql :tracked (item-disposition readme :foreign))))

(define-test an-unrecognised-profile-signals-rather-than-defaulting
  "A profile nobody recognises cannot silently answer tracked.

The default answer would have to be tracked, and that is the answer that puts
our files into somebody else's commit."
  (fail (item-disposition (catalog-item :envrc) :probably-ours) 'error))

;;; --- the catalog's own shape ------------------------------------------------

(define-test the-quality-gate-is-one-unit
  "The gate is retrievable as a group, so an absent gate is one finding.

The linter config and the lint script never occur apart in the measured
population, and the hook is what makes either take effect. Reporting them
separately would describe a partial install that does not happen."
  (let ((gate (shape-group-items :quality-gate)))
    (is = 3 (length gate))
    (dolist (item gate)
      (is eql :gate (shape-item-tier item)
          "~S is in the gate tier." (shape-item-key item))
      (true (shape-item-apparatus-p item)
            "~S is our apparatus." (shape-item-key item)))))

(define-test the-invariant-tier-is-only-what-makes-a-working-system
  "The strongest tier holds a system definition and the two source directories.

Anything more would report working third-party repositories as broken, which is
the failure the tiering exists to prevent."
  (let ((invariants (remove-if-not (lambda (item) (eq :invariant (shape-item-tier item)))
                                   *shape-catalog*)))
    (is = 3 (length invariants))
    (is equal '(:asd-system :src-dir :tests-dir)
        (mapcar #'shape-item-key invariants))))

(define-test our-apparatus-is-never-an-invariant-of-somebody-elses-project
  "No item is both our apparatus and something every repository must have.

An apparatus file in the invariant tier would be asserted against a repository
we do not own, which is our convention presented as their defect."
  (dolist (item *shape-catalog*)
    (false (and (shape-item-apparatus-p item)
                (eq :invariant (shape-item-tier item)))
           "~S is not both apparatus and invariant." (shape-item-key item))))

(define-test every-catalog-tier-is-a-declared-tier
  "No item carries a tier the vocabulary does not name."
  (dolist (item *shape-catalog*)
    (true (member (shape-item-tier item) +tiers+)
          "~S carries a declared tier." (shape-item-key item))))

(define-test the-gate-is-not-written-by-the-scaffold-yet
  "Whether a new project is born with the gate installed is still open.

These flags are the entire cost of answering it the other way, which is only
true while they all agree."
  (dolist (item (shape-group-items :quality-gate))
    (false (shape-item-emit-on-scaffold-p item)
           "~S is not emitted by the scaffold." (shape-item-key item))))

(define-test the-exclude-set-is-derived-from-the-catalog
  "What must stay out of a foreign index comes from the same list as everything
else, including the item with no generator, and leaves out what is not in the
worktree at all."
  (let ((paths (apparatus-paths-for-profile :foreign)))
    (true (member ".gate-baseline.md" paths :test #'string=)
          "An item with no generator is still excluded.")
    (true (member ".mallet.lisp" paths :test #'string=))
    (false (member "hooks/pre-commit" paths :test #'string=)
           "An item under the git directory is not a worktree pattern.")
    (is equal '() (apparatus-paths-for-profile :ours)
        "Nothing is excluded in a repository we own.")))

;;; --- the profile-to-tier mapping --------------------------------------------

(define-test a-foreign-repository-is-not-held-to-our-quality-gate
  "A third party's project is not defective for lacking our conventions."
  (false (member :gate (assessed-tiers-for-profile :foreign)))
  (true (member :invariant (assessed-tiers-for-profile :foreign))))

(define-test our-own-repositories-are-held-to-the-quality-gate
  (true (member :gate (assessed-tiers-for-profile :ours)))
  (true (member :invariant (assessed-tiers-for-profile :ours))))

(define-test an-unmapped-profile-signals-rather-than-assessing-nothing
  "An empty tier list reports every repository as clean, and that report is
indistinguishable from the report for a repository that genuinely is."
  (fail (assessed-tiers-for-profile :nonsense) 'unknown-profile-error))

;;; --- CONTROLS ---------------------------------------------------------------

(define-test control-no-slot-can-record-a-tracked-foreign-apparatus
  "CONTROL for the property that the ours-and-foreign distinction lives in the
type rather than in a check at each write site.

Asserting only that the disposition comes back excluded leaves the property a
convention: someone could add a settable slot and the assertion would still
pass, right up until a caller set it. This fails the day such a slot appears."
  (let ((apparatus (catalog-item :mallet-config)))
    (is eql :excluded (item-disposition apparatus :foreign))
    (false (find 'disposition
                 (sb-mop:class-slots (find-class 'shape-item))
                 :key #'sb-mop:slot-definition-name)
           "The structure has no slot able to hold a disposition.")))

(define-test control-the-disposition-assertions-read-their-catalog
  "CONTROL for the disposition assertions above, which iterate the live catalog.

A loop that ignored its argument and reported on a constant would pass every one
of them. Binding a synthetic catalog with different keys and asserting the answer
follows proves the iteration is reading what it was handed."
  (let ((*shape-catalog* (synthetic-catalog)))
    (is = 2 (length *shape-catalog*))
    (is equal '(:synthetic-apparatus)
        (mapcar #'shape-item-key (apparatus-items)))
    (is equal '(:excluded :tracked)
        (mapcar #'cdr (shape-items-for-profile :foreign)))
    (is equal '(:tracked :tracked)
        (mapcar #'cdr (shape-items-for-profile :ours)))
    (is equal '("SYNTHETIC-APPARATUS.md")
        (apparatus-paths-for-profile :foreign))))

(define-test control-the-scaffold-parity-assertion-can-fail
  "CONTROL for the parity between what the catalog says the scaffold writes and
what it actually writes.

Two unrelated constant lists satisfy an equality check just as well as two
related ones. Removing an emitting item from the catalog must shorten the derived
list; if it does not, the assertion above was never reading the catalog."
  (let ((expected (scaffold-paths)))
    (is = 12 (length expected))
    (is equal expected (emitted-paths))
    (let ((*shape-catalog* (remove (catalog-item :readme) *shape-catalog*)))
      (is = (1- (length expected)) (length (emitted-paths))
          "Dropping an emitting item shortens the derived manifest.")
      (false (member "README.md" (emitted-paths) :test #'string=)))))

(define-test control-a-malformed-item-cannot-be-constructed
  "CONTROL for the constructor's validation.

A catalog entry with a tier nobody assesses, or an assertion kind nothing can
evaluate, would never match anything and would report as an absent file rather
than as the typo it is."
  (fail (make-shape-item :key :bad :tier :whatever
                         :assertion :file-exists :match "x")
        'invalid-shape-item-error)
  (fail (make-shape-item :key :bad :tier :gate
                         :assertion :whatever :match "x")
        'invalid-shape-item-error)
  (fail (make-shape-item :key :bad :tier :gate
                         :assertion :file-exists :match "x"
                         :install-target :somewhere-else)
        'invalid-shape-item-error)
  (fail (make-shape-item :key "not-a-keyword" :tier :gate
                         :assertion :file-exists :match "x")
        'invalid-shape-item-error)
  (fail (make-shape-item :key :bad :tier :gate :assertion :file-exists)
        'invalid-shape-item-error)
  (let ((item (make-shape-item :key :fine :tier :gate
                               :assertion :file-exists :match "x")))
    (is eql :fine (shape-item-key item))))

(define-test control-the-profile-to-tier-mapping-is-the-one-in-force
  "CONTROL for the claim that the provisional answers live in one data file.

Reading the mapping proves only what it says today. This changes it, and asserts
the change is observed. If the mapping is ever defined a second time outside the
catalog, that other definition will be the one in force, this binding will not
reach it, and this assertion is what notices."
  (is equal '(:invariant) (assessed-tiers-for-profile :foreign))
  (let ((*assessed-tiers* '((:ours . (:invariant :gate))
                            (:foreign . (:invariant :gate)))))
    (is equal '(:invariant :gate) (assessed-tiers-for-profile :foreign)
        "A different ruling takes effect by editing this mapping alone."))
  (is equal '(:invariant) (assessed-tiers-for-profile :foreign)
      "The mapping is restored when the binding unwinds."))
