;;;; src/repo-classify.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Decide what a repository IS, before anything is written into it.
;;;;
;;;; Three terminal outcomes and one signalled ambiguity:
;;;;
;;;;   :ours                   our own project; our apparatus is tracked content
;;;;   :foreign-with-upstream  somebody else's software, with an upstream to record
;;;;   :foreign-orphan         somebody else's software, with no upstream left
;;;;
;;;; The obvious test, "does it have an upstream remote", is measurably wrong.
;;;; Raw third-party clones sit in the workspace with origin pointing straight
;;;; at the author's own account and no upstream remote at all. That test reads
;;;; them as ours, and adopting them as ours would commit our tooling into
;;;; somebody else's history.
;;;;
;;;; Origin ownership alone is not sufficient in the other direction either.
;;;; Because everything is forked to our account before it is cloned, an origin
;;;; under our account says nothing about who wrote the software. Measured
;;;; across 251 repositories in the workspace: 161 carry a third-party origin,
;;;; 22 carry our origin with an upstream recorded, and 68 carry our origin with
;;;; no upstream at all. Nothing on disk tells that last group apart from one of
;;;; our own projects, and it is the largest of the three our-origin outcomes.
;;;;
;;;; So that case is asked, never guessed. There is no default return value in
;;;; this module and no handler swallowing the question, because concluding
;;;; "ours" wrongly is the single error that ends with our tooling tracked in a
;;;; third party's repository. Concluding "foreign" wrongly costs nothing worse
;;;; than an untracked file in one of our own trees.
;;;;
;;;; An absent upstream is not a defect. Orphaned projects are still working
;;;; software, so :foreign-orphan is a place to stop rather than drift to
;;;; repair.

(defpackage #:dsmr-mcp/src/repo-classify
  (:use #:cl)
  (:import-from #:cl-ppcre
                #:create-scanner
                #:scan)
  (:import-from #:dsmr-mcp/src/git
                #:git-repository-p
                #:git-remote-url
                #:not-a-repository-error)
  (:export #:*our-git-accounts*
           #:our-git-accounts
           #:parse-remote-owner
           #:our-remote-p
           #:classify-repository
           #:repo-classification
           #:repo-profile
           #:+classifications+
           #:repo-classification-ambiguous-error
           #:repo-classification-ambiguous-directory
           #:repo-classification-ambiguous-origin-url))

(in-package #:dsmr-mcp/src/repo-classify)

;;; ---------------------------------------------------------------------------
;;; The terminal outcomes
;;; ---------------------------------------------------------------------------

(defvar +classifications+ '(:ours :foreign-with-upstream :foreign-orphan)
  "Every terminal classification a repository can reach.

Named as a constant but defined with DEFVAR on purpose: DEFCONSTANT on a list
re-evaluates to a fresh, non-EQL list on reload and breaks a warm image. Every
DEFCONSTANT in this codebase holds a number, for the same reason.")

(deftype repo-classification ()
  "One of the three terminal classifications a repository can reach."
  '(member :ours :foreign-with-upstream :foreign-orphan))

;;; ---------------------------------------------------------------------------
;;; Conditions
;;; ---------------------------------------------------------------------------

(define-condition repo-classification-ambiguous-error (error)
  ((directory  :initarg :directory  :initform nil
               :reader repo-classification-ambiguous-directory)
   (origin-url :initarg :origin-url :initform nil
               :reader repo-classification-ambiguous-origin-url))
  (:documentation
   "Signaled when nothing on disk decides whether a repository is ours.

Two shapes reach here: an origin under one of our own accounts with no upstream
recorded anywhere, and no origin at all. Both are questions for the operator,
and both carry the directory and whatever origin URL was found so the question
can be put without re-reading the repository.

This is a normal outcome rather than a fault. Among repositories whose origin is
ours it is the most common one, so a caller that treats it as a rare failure
will be wrong most of the time.")
  (:report
   (lambda (condition stream)
     (format stream
             "Cannot tell whether ~A is our own project or somebody else's~
~@[ (origin ~A, no upstream recorded)~]. Supply the upstream, or declare the ~
classification."
             (repo-classification-ambiguous-directory condition)
             (repo-classification-ambiguous-origin-url condition)))))

(setf (documentation 'repo-classification-ambiguous-directory 'function)
      "Return the directory whose classification could not be decided.")
(setf (documentation 'repo-classification-ambiguous-origin-url 'function)
      "Return the origin URL found, or NIL when the repository has no origin.")

;;; ---------------------------------------------------------------------------
;;; Which accounts are ours
;;; ---------------------------------------------------------------------------

(defvar *our-git-accounts* (list "fade" "deepsky")
  "The hosting accounts whose repositories may be our own software.

A DEFVAR rather than a DEFPARAMETER so that reloading the system does not
discard an override installed at runtime.")

(defun %split-on-comma (string)
  "Return the non-empty, whitespace-trimmed comma-separated fields of STRING.

NIL and a string holding only separators both yield the empty list, so a caller
can tell \"nothing was configured\" from \"one name was configured\"."
  (if (null string)
      '()
      (remove ""
              (mapcar (lambda (field)
                        (string-trim '(#\Space #\Tab #\Newline #\Return) field))
                      (uiop:split-string string :separator '(#\,)))
              :test #'string=)))

(defun our-git-accounts ()
  "Return the list of hosting accounts currently treated as ours.

DSMR_GIT_ACCOUNTS, read as a comma-separated list, wins whenever it names at
least one account; otherwise the answer is *OUR-GIT-ACCOUNTS*. The variable is
read on every call so a change takes effect without reloading anything."
  (or (%split-on-comma (uiop:getenv "DSMR_GIT_ACCOUNTS"))
      *our-git-accounts*))

;;; ---------------------------------------------------------------------------
;;; Reading an account out of a remote URL
;;; ---------------------------------------------------------------------------

;;; Three URL shapes occur across the repositories on this host. Both scanners
;;; require a non-empty repository segment after the account, so a bare host
;;; cannot be read as an account name.

(defvar *scheme-url-scanner*
  (create-scanner "^[a-zA-Z][a-zA-Z0-9+.-]*://(?:[^/@]+@)?[^/]+/([^/]+)/[^/]")
  "Matches https://host/owner/repo and ssh://git@host/owner/repo, capturing the owner.")

(defvar *scp-url-scanner*
  (create-scanner "^[^/@]+@[^/:]+:([^/]+)/[^/]")
  "Matches the scp shorthand git@host:owner/repo.git, capturing the owner.")

(defun %first-group (scanner string)
  "Return the first capture group SCANNER matches in STRING, or NIL."
  (multiple-value-bind (start end group-starts group-ends)
      (scan scanner string)
    (declare (ignore end))
    (when (and start
               (plusp (length group-starts))
               (aref group-starts 0))
      (subseq string (aref group-starts 0) (aref group-ends 0)))))

(defun parse-remote-owner (url)
  "Return the hosting account named in URL as a string, or NIL when there is none.

Pure string work: nothing here or below it opens a connection, so a crafted
remote URL cannot cause a lookup. A URL in none of the recognised shapes returns
NIL, which every caller reads as \"not ours\"."
  (when (stringp url)
    (let ((owner (or (%first-group *scheme-url-scanner* url)
                     (%first-group *scp-url-scanner* url))))
      (when (and owner (string/= owner ""))
        owner))))

(defun our-remote-p (url)
  "Return T when URL names a repository under one of OUR-GIT-ACCOUNTS.

A URL that cannot be parsed is not ours. That asymmetry is deliberate: reading
an unrecognised URL as ours is what puts our tooling into somebody else's
tracked tree, while reading one of ours as foreign only leaves the apparatus
untracked in a repository we own.

Accounts are compared without regard to case, which is how the hosts themselves
resolve them."
  (let ((owner (parse-remote-owner url)))
    (when (and owner
               (member owner (our-git-accounts) :test #'string-equal))
      t)))

;;; ---------------------------------------------------------------------------
;;; The classification itself
;;; ---------------------------------------------------------------------------

(defun classify-repository (directory &key declared-classification upstream-url)
  "Return the classification of the repository at DIRECTORY, and its upstream URL.

Two values: a member of +CLASSIFICATIONS+, and the URL of the software this tree
came from, or NIL when there is none to record. The second value spares a caller
from reading the remotes again to write the upstream down.

DECLARED-CLASSIFICATION carries an answer already given by the operator and
outranks everything inferred here. A value outside +CLASSIFICATIONS+ signals a
TYPE-ERROR rather than falling through to inference, so a mistyped declaration
cannot quietly become a guess.

UPSTREAM-URL supplies an upstream that the repository does not yet record, which
is how a repository is resolved without first repairing its remotes.

Signals NOT-A-REPOSITORY-ERROR when DIRECTORY lies outside any repository.
Signals REPO-CLASSIFICATION-AMBIGUOUS-ERROR when the origin is one of ours and
nothing records an upstream, and when there is no origin at all. Neither of
those has a default: an origin under our account is at least as often somebody
else's software as our own, and only the operator knows which."
  (unless (git-repository-p directory)
    (error 'not-a-repository-error :path directory))
  (when declared-classification
    (unless (member declared-classification +classifications+)
      (error 'type-error
             :datum declared-classification
             :expected-type 'repo-classification))
    (return-from classify-repository
      (values declared-classification
              (when (eq declared-classification :foreign-with-upstream)
                (or upstream-url (git-remote-url directory "upstream"))))))
  (let ((origin (git-remote-url directory "origin")))
    (unless origin
      (error 'repo-classification-ambiguous-error
             :directory directory
             :origin-url nil))
    (unless (our-remote-p origin)
      ;; A third-party origin settles the question by itself, with no reference
      ;; to any upstream remote. These are the raw clones that record no
      ;; upstream at all, and they are the dangerous ones: every test that looks
      ;; for an upstream first reads them as ours.
      (return-from classify-repository
        (values :foreign-with-upstream origin)))
    (let ((upstream (or upstream-url (git-remote-url directory "upstream"))))
      (when upstream
        (return-from classify-repository
          (values :foreign-with-upstream upstream)))
      (error 'repo-classification-ambiguous-error
             :directory directory
             :origin-url origin))))

(defun repo-profile (classification)
  "Return :OURS or :FOREIGN for CLASSIFICATION.

The two foreign outcomes collapse into one profile because they call for
identical treatment: the apparatus is present on disk and none of it is tracked.
They differ only in whether there is an upstream to record. An unrecognised
value signals rather than defaulting, because this profile is what decides
whether a write becomes tracked content in a repository we do not own."
  (ecase classification
    (:ours :ours)
    ((:foreign-with-upstream :foreign-orphan) :foreign)))
