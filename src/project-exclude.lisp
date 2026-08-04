;;;; src/project-exclude.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Drift detection and repair for a repository's local exclude file.
;;;;
;;;; The patterns that keep local tooling artifacts out of a repository live in
;;;; .git/info/exclude and nowhere else. That file is untracked and invisible
;;;; upstream, so writing it is safe even in a repository somebody else owns,
;;;; and it is the reason nothing here ever writes a tracked file.
;;;;
;;;; The pattern set of record is the git template's own exclude file, read at
;;;; run time. Copying that list into Lisp would create a second definition that
;;;; drifts the moment a pattern is added to the template, which is precisely
;;;; the failure this module exists to find: git seeds the template into a
;;;; repository once, at creation, and nothing re-syncs an existing one.
;;;;
;;;; The shape mirrors src/install/hooks.lisp function for function: an
;;;; idempotency predicate checked before acting, a pure transform that never
;;;; mutates its input, a re-parse of the rendered output that aborts the write
;;;; when it does not carry what was asked for, a timestamped backup confirmed
;;;; on disk before the original is overwritten, and a report whose action-taken
;;;; keyword says what CHANGED separately from what was already correct.
;;;;
;;;; The merge is additive. Local entries a repository carries for its own
;;;; reasons are never removed, never reordered and never deduplicated.

(defpackage #:dsmr-mcp/src/project-exclude
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/fs
                #:write-file-string-atomically)
  (:import-from #:dsmr-mcp/src/git
                #:git-repository-p
                #:git-toplevel
                #:not-a-repository-error)
  (:export #:*exclude-template-path*
           #:exclude-template-path
           #:exclude-template-missing-error
           #:exclude-template-missing-path
           #:template-exclude-patterns
           #:parse-exclude-patterns
           #:repo-exclude-path
           #:missing-exclude-patterns
           #:ensure-exclude-patterns
           #:repair-repo-exclude))

(in-package #:dsmr-mcp/src/project-exclude)

;;; ---------------------------------------------------------------------------
;;; The pattern set of record
;;; ---------------------------------------------------------------------------

(defvar *exclude-template-path*
  (merge-pathnames ".config/git/template/info/exclude" (user-homedir-pathname))
  "The file holding the patterns every repository is measured against.

git seeds this same file into a new repository through init.templateDir, so
reading it here means the two agree by construction rather than by maintenance.

A DEFVAR rather than a DEFPARAMETER so reloading the system does not discard an
override an operator or a test has already put in place.")

(defun exclude-template-path ()
  "Return the template file to read the pattern set from.

DSMR_GIT_EXCLUDE_TEMPLATE overrides *EXCLUDE-TEMPLATE-PATH* when it is set to
something non-empty. It is consulted on every call rather than once at load
time, so a caller can point the check at a fixture without rebuilding."
  (let ((override (uiop:getenv "DSMR_GIT_EXCLUDE_TEMPLATE")))
    (if (and (stringp override) (string/= override ""))
        (pathname override)
        *exclude-template-path*)))

(define-condition exclude-template-missing-error (error)
  ((path :initarg :path :reader exclude-template-missing-path))
  (:documentation
   "Signaled when the template holding the pattern set of record is absent.

There is deliberately no fallback to a list written into this file. A host with
no template would then report every repository it examined as carrying every
pattern, which is a false clean answer on the one check that exists to catch a
missing pattern, and it would be silent.")
  (:report
   (lambda (condition stream)
     (format stream "The exclude pattern template ~A does not exist."
             (exclude-template-missing-path condition)))))

(setf (documentation 'exclude-template-missing-path 'function)
      "Return the template pathname that was expected to exist.")

;;; ---------------------------------------------------------------------------
;;; Reading patterns out of an exclude file
;;; ---------------------------------------------------------------------------

(defun %trim (line)
  "Return LINE with surrounding whitespace removed."
  (string-trim '(#\Space #\Tab #\Return) (or line "")))

(defun parse-exclude-patterns (text)
  "Return the patterns TEXT declares, in the order they appear.

Blank lines and comment lines, meaning those whose first non-whitespace
character is #\\#, carry no pattern and are dropped. Every remaining line is
trimmed. An exclude file is mostly prose, so counting its lines and counting its
patterns are different measurements and only this one answers the question."
  (let ((patterns '()))
    (dolist (line (uiop:split-string (or text "") :separator '(#\Newline))
                  (nreverse patterns))
      (let ((trimmed (%trim line)))
        (unless (or (string= trimmed "")
                    (char= (char trimmed 0) #\#))
          (push trimmed patterns))))))

(defun template-exclude-patterns ()
  "Return the patterns the template declares, in template order.

Signals EXCLUDE-TEMPLATE-MISSING-ERROR when the template is absent, rather than
answering with an empty set. An empty set read as an answer would make every
repository look compliant."
  (let ((path (exclude-template-path)))
    (unless (probe-file path)
      (error 'exclude-template-missing-error :path path))
    (parse-exclude-patterns (uiop:read-file-string path))))

(defun repo-exclude-path (root)
  "Return ROOT/.git/info/exclude, the local exclude file of the repository at ROOT."
  (merge-pathnames ".git/info/exclude" (uiop:ensure-directory-pathname root)))

;;; ---------------------------------------------------------------------------
;;; Idempotency predicate and pure transform
;;; ---------------------------------------------------------------------------

(defun missing-exclude-patterns (existing template-patterns)
  "Return the members of TEMPLATE-PATTERNS absent from EXISTING, in template order.

EXISTING is a list of patterns as PARSE-EXCLUDE-PATTERNS returns them. NIL means
nothing is missing, which is what makes the transform below idempotent."
  (remove-if (lambda (pattern)
               (member pattern existing :test #'string=))
             template-patterns))

(defun ensure-exclude-patterns (existing-text template-patterns)
  "Return NEW exclude text carrying every pattern in TEMPLATE-PATTERNS.

EXISTING-TEXT is never mutated and may be NIL for a repository with no exclude
file yet. Every pre-existing line survives verbatim, comments included and local
entries the template knows nothing about included: the result is the existing
text followed, only when something is actually missing, by a blank line, a
one-line comment saying what the block is for, and the missing patterns one per
line. Nothing is reordered, nothing is deduplicated and nothing is removed.

Idempotent by construction, because the append is gated on
MISSING-EXCLUDE-PATTERNS being non-empty: applying it twice yields text equal to
applying it once."
  (let* ((existing (or existing-text ""))
         (missing (missing-exclude-patterns
                   (parse-exclude-patterns existing)
                   template-patterns)))
    (if (null missing)
        existing
        (with-output-to-string (out)
          (write-string existing out)
          (when (plusp (length existing))
            (unless (char= (char existing (1- (length existing))) #\Newline)
              (terpri out))
            (terpri out))
          (write-line "# Local tooling artifacts, kept out of the repository and never tracked."
                      out)
          (dolist (pattern missing)
            (write-line pattern out))))))

;;; ---------------------------------------------------------------------------
;;; Backup naming
;;; ---------------------------------------------------------------------------

(defun %timestamp ()
  "A compact YYYYMMDDHHMMSS stamp for a unique backup suffix."
  (multiple-value-bind (s m h d mo y) (decode-universal-time (get-universal-time))
    (format nil "~4,'0D~2,'0D~2,'0D~2,'0D~2,'0D~2,'0D" y mo d h m s)))

(defun %backup-path (path)
  "Return the timestamped backup pathname for PATH: <path>.bak-YYYYMMDDHHMMSS.
Mirrors the installer's backup naming so both repair paths look the same."
  (pathname (format nil "~A.bak-~A" (namestring path) (%timestamp))))

;;; ---------------------------------------------------------------------------
;;; The repair
;;; ---------------------------------------------------------------------------

(defun %validate-rendered (rendered template-patterns path)
  "Confirm RENDERED parses back to text carrying every pattern in
TEMPLATE-PATTERNS, and signal naming PATH when it does not.

The check runs against the rendered text rather than against the transform's
inputs, so a rendering fault is caught while the original file is still intact."
  (let ((round-trip (parse-exclude-patterns rendered)))
    (dolist (pattern template-patterns)
      (unless (member pattern round-trip :test #'string=)
        (error "The repaired exclude text does not carry ~S; leaving ~A untouched."
               pattern (namestring path))))))

(defun repair-repo-exclude (root &key (template-patterns (template-exclude-patterns))
                                      dry-run)
  "Bring the local exclude file of the repository at ROOT up to TEMPLATE-PATTERNS.

Signals NOT-A-REPOSITORY-ERROR when ROOT is not inside a repository, since there
is no local exclude file to repair outside one. The file written is the one
belonging to the repository ROOT sits in, found through GIT-TOPLEVEL, so a call
against a subdirectory repairs the real file rather than creating a second one
git would never read.

The existing file is read, the missing patterns computed, and the merged text
re-parsed to confirm it carries what was asked for before anything is written.
An existing file is copied to a timestamped backup whose existence is confirmed
before the atomic overwrite, so the original is always recoverable. A repository
already carrying every pattern is NOT rewritten: leaving the file alone is what
makes a second run observably a no-op.

DRY-RUN reports what would be added and writes nothing.

Returns a plist (:path PATH :backup-path {PATH | NIL} :action-taken
{:created | :updated | :already-present | :would-update} :added-patterns LIST)."
  (unless (git-repository-p root)
    (error 'not-a-repository-error :path root))
  (let ((toplevel (git-toplevel root)))
    (unless toplevel
      (error 'not-a-repository-error :path root))
    (let* ((path (repo-exclude-path toplevel))
           (existed (and (probe-file path) t))
           (existing-text (when existed (uiop:read-file-string path)))
           (missing (missing-exclude-patterns
                     (parse-exclude-patterns (or existing-text ""))
                     template-patterns))
           (rendered (ensure-exclude-patterns existing-text template-patterns)))
      (%validate-rendered rendered template-patterns path)
      (cond
        ((null missing)
         (list :path path :backup-path nil
               :action-taken :already-present :added-patterns nil))
        (dry-run
         (list :path path :backup-path nil
               :action-taken :would-update :added-patterns missing))
        (t
         (let ((backup (when existed (%backup-path path))))
           (when backup
             (uiop:copy-file path backup)
             (unless (probe-file backup)
               (error "The backup ~A was not created; leaving ~A untouched."
                      (namestring backup) (namestring path))))
           (write-file-string-atomically path rendered)
           (list :path path
                 :backup-path backup
                 :action-taken (if existed :updated :created)
                 :added-patterns missing)))))))
