;;;; src/project-shape.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; What a project of ours is made of, in a form that can both write a new
;;;; repository and assess one that already exists.
;;;;
;;;; The older answer was an alist of relative path and rendered content. That
;;;; shape can write a file and cannot say anything about one. A content blob has
;;;; no way to express "a build script is optional", "these files are one gate
;;;; rather than three independent misses", or "this file is ordinary project
;;;; content in a repository we own and contraband in one we do not".
;;;;
;;;; So an item carries an assertion, meaning whatever makes it satisfied in a
;;;; repository that already exists, separately from a generator, meaning the
;;;; content to write when creating one. It also carries a tier and a group, so
;;;; that advisory items and single-unit gates are both expressible.
;;;;
;;;; The distinction that matters most is the last one. Our operational apparatus
;;;; is ordinary tracked content in our own trees and must be present but never
;;;; tracked in somebody else's. That distinction lives in the item's type rather
;;;; than at each site that writes a file: a check at a write site is a thing the
;;;; next write site can forget, and forgetting it once means our tooling
;;;; committed into a third party's history.
;;;;
;;;; This module is mechanism only. Which files exist, what tier each is in and
;;;; which of them are apparatus are declared in the catalog data file, which
;;;; fills in *SHAPE-CATALOG*. Nothing here reads that file, and every function
;;;; below accepts a catalog argument so a caller can supply its own.

(defpackage #:dsmr-mcp/src/project-shape
  (:use #:cl)
  (:export #:shape-item
           #:make-shape-item
           #:shape-item-key
           #:shape-item-path
           #:shape-item-tier
           #:shape-item-group
           #:shape-item-apparatus-p
           #:shape-item-assertion
           #:shape-item-match
           #:shape-item-generator
           #:shape-item-emit-on-scaffold-p
           #:shape-item-install-target
           #:item-disposition
           #:*shape-catalog*
           #:shape-items-for-profile
           #:shape-group-items
           #:+tiers+
           #:+assertions+
           #:+install-targets+
           #:invalid-shape-item-error
           #:invalid-shape-item-field
           #:invalid-shape-item-value
           #:invalid-shape-item-reason))

(in-package #:dsmr-mcp/src/project-shape)

;;; ---------------------------------------------------------------------------
;;; The vocabularies an item is built from
;;; ---------------------------------------------------------------------------

;;; Named as constants but defined with DEFVAR on purpose: DEFCONSTANT on a list
;;; re-evaluates to a fresh, non-EQL list on reload and breaks a warm image.

(defvar +tiers+ '(:invariant :gate :convenience)
  "Every tier an item can be assigned to, strongest first.

:INVARIANT is what a repository of this kind has without exception. :GATE is a
quality gate, which is assessed as one unit through its group rather than as
separate files. :CONVENIENCE is advisory and its absence is never a fault.

The tier is what keeps assessment from declaring working repositories sick. A
requirement that every project carry every file we like to have would report the
majority of the third-party repositories on this machine as broken, and a report
that is mostly false entries hides the true ones.")

(defvar +assertions+ '(:file-exists :directory-exists :any-file-matching)
  "Every kind of check that can decide whether an item is satisfied.

:FILE-EXISTS and :DIRECTORY-EXISTS take a relative path. :ANY-FILE-MATCHING takes
a filename glob and is satisfied by any one file matching it, which is how a
system definition is asserted without dictating what the project is called.")

(defvar +install-targets+ '(:worktree :git-dir)
  "Where an item lives once installed.

:WORKTREE items sit in the working tree, so in a repository we do not own they
must be excluded from tracking. :GIT-DIR items sit under the repository's own git
directory, which is never part of any worktree and never reaches an upstream, so
they are invisible to a third party regardless of profile.")

;;; ---------------------------------------------------------------------------
;;; Condition
;;; ---------------------------------------------------------------------------

(define-condition invalid-shape-item-error (error)
  ((field  :initarg :field  :reader invalid-shape-item-field)
   (value  :initarg :value  :reader invalid-shape-item-value)
   (reason :initarg :reason :reader invalid-shape-item-reason))
  (:documentation
   "Signaled when MAKE-SHAPE-ITEM is given an argument it cannot accept.

Carries the offending field, the value supplied and why it was rejected, so a
malformed catalog entry names itself rather than surfacing later as a missing
file nobody declared.")
  (:report
   (lambda (condition stream)
     (format stream "Invalid shape item ~A = ~S: ~A"
             (invalid-shape-item-field condition)
             (invalid-shape-item-value condition)
             (invalid-shape-item-reason condition)))))

(setf (documentation 'invalid-shape-item-field 'function)
      "Return the name of the offending field from an INVALID-SHAPE-ITEM-ERROR.")
(setf (documentation 'invalid-shape-item-value 'function)
      "Return the rejected value from an INVALID-SHAPE-ITEM-ERROR.")
(setf (documentation 'invalid-shape-item-reason 'function)
      "Return the human-readable reason string from an INVALID-SHAPE-ITEM-ERROR.")

;;; ---------------------------------------------------------------------------
;;; The item
;;; ---------------------------------------------------------------------------

;;; Every slot is read-only and the raw constructor is private, so an item is
;;; whatever MAKE-SHAPE-ITEM validated it into and stays that way. There is
;;; deliberately no slot recording whether the file is tracked: see
;;; ITEM-DISPOSITION below.

(defstruct (shape-item (:constructor %make-shape-item)
                       (:copier nil)
                       (:predicate shape-item-p))
  "One file or directory a project of ours is expected to have.

Assertion and generator are separate because assessing an existing repository and
writing a new one ask different questions of the same item, and some items can
answer only the first."
  (key                nil :type keyword           :read-only t)
  (path               nil :type (or null string)  :read-only t)
  (tier               nil :type keyword           :read-only t)
  (group              nil :type (or null keyword) :read-only t)
  (apparatus-p        nil :type boolean           :read-only t)
  (assertion          nil :type keyword           :read-only t)
  (match              nil :type string            :read-only t)
  (generator          nil :type (or null function) :read-only t)
  (emit-on-scaffold-p nil :type boolean           :read-only t)
  (install-target :worktree :type keyword         :read-only t))

(defun %validate-member (field value permitted)
  "Return VALUE when it is in PERMITTED, else signal INVALID-SHAPE-ITEM-ERROR."
  (unless (member value permitted)
    (error 'invalid-shape-item-error
           :field field :value value
           :reason (format nil "must be one of ~{~S~^, ~}" permitted)))
  value)

(defun make-shape-item (&key key path tier group apparatus-p assertion match
                             generator emit-on-scaffold-p
                             (install-target :worktree))
  "Return a validated SHAPE-ITEM, or signal INVALID-SHAPE-ITEM-ERROR.

This is the only way to build an item. TIER, ASSERTION and INSTALL-TARGET are
checked against +TIERS+, +ASSERTIONS+ and +INSTALL-TARGETS+, so a typo in the
catalog is a load-time failure naming the field rather than an item that quietly
never matches anything.

KEY names the item in reports and must be a keyword. MATCH is the argument the
assertion needs and is required for every kind: without it the item asserts
nothing and would report satisfied in any repository at all.

PATH may be NIL for an item that is matched rather than named, such as a system
definition found by glob. GENERATOR may be NIL for an item that can be asserted
but not written, such as one whose content is computed per repository."
  (unless (keywordp key)
    (error 'invalid-shape-item-error
           :field "key" :value key :reason "must be a keyword"))
  (unless (or (null path) (stringp path))
    (error 'invalid-shape-item-error
           :field "path" :value path :reason "must be a string or NIL"))
  (unless (or (null group) (keywordp group))
    (error 'invalid-shape-item-error
           :field "group" :value group :reason "must be a keyword or NIL"))
  (unless (and (stringp match) (plusp (length match)))
    (error 'invalid-shape-item-error
           :field "match" :value match :reason "must be a non-empty string"))
  (unless (or (null generator) (functionp generator))
    (error 'invalid-shape-item-error
           :field "generator" :value generator
           :reason "must be a function of one argument, or NIL"))
  (%validate-member "tier" tier +tiers+)
  (%validate-member "assertion" assertion +assertions+)
  (%validate-member "install-target" install-target +install-targets+)
  (%make-shape-item :key key
                    :path path
                    :tier tier
                    :group group
                    :apparatus-p (and apparatus-p t)
                    :assertion assertion
                    :match match
                    :generator generator
                    :emit-on-scaffold-p (and emit-on-scaffold-p t)
                    :install-target install-target))

;;; ---------------------------------------------------------------------------
;;; Disposition
;;; ---------------------------------------------------------------------------

(defun item-disposition (item profile)
  "Return :TRACKED or :EXCLUDED for ITEM under PROFILE.

Our operational apparatus is ordinary tracked content in a repository we own, and
must be present but untracked in one we do not. Under :FOREIGN every apparatus
item is therefore :EXCLUDED, and no argument to this function can change that.

The disposition is computed here and never stored on the item, which is the whole
of the design. No accessor can report a foreign repository's apparatus as tracked,
because the structure has no slot able to hold that claim: it cannot be
constructed, written down, or read back. The rule has exactly one place it could
be broken, and this is it.

An unrecognised profile signals rather than defaulting. A default would have to
answer :TRACKED, and that is the answer that puts our files into somebody else's
commit."
  (ecase profile
    (:foreign (if (shape-item-apparatus-p item) :excluded :tracked))
    (:ours :tracked)))

;;; ---------------------------------------------------------------------------
;;; Reading a catalog
;;; ---------------------------------------------------------------------------

(defvar *shape-catalog* '()
  "The list of SHAPE-ITEMs that defines the shape of a project of ours.

Declared here and filled in by the catalog data file, so that this module holds
no list of its own and a caller can bind or pass a different one. Empty until
that file is loaded.")

(defun shape-items-for-profile (profile &optional (catalog *shape-catalog*))
  "Return a list of (ITEM . DISPOSITION) conses, one per item in CATALOG.

Every item is returned, including the excluded ones. A caller deciding what to
write needs to know that an apparatus file belongs on disk and out of the index,
which is a different statement from the file not being wanted at all."
  (mapcar (lambda (item)
            (cons item (item-disposition item profile)))
          catalog))

(defun shape-group-items (group &optional (catalog *shape-catalog*))
  "Return the items in CATALOG belonging to GROUP.

A group is a set of items that stand or fall together. Reporting them separately
would describe a partial install that does not occur in practice, and would count
one missing gate as several unrelated faults."
  (remove-if-not (lambda (item) (eq group (shape-item-group item)))
                 catalog))
