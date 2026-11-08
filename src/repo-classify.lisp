;;;; src/repo-classify.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; The project disposition: what a repository is to the operator, declared once
;;;; and recorded in the repository's own untracked .envrc.
;;;;
;;;;   :ours          code originating with the operator
;;;;   :contributing  a third-party project the operator only contributes to
;;;;   :forked        forked to shorten the acceptance chain, or because upstream
;;;;                  is unmaintained
;;;;
;;;; Remotes cannot decide it. Adoption forks upstream under the operator's own
;;;; account and clones the fork, so an origin under that account says nothing
;;;; about who wrote the code, and licence text is no more reliable. Remote facts
;;;; produce consistency warnings only.
;;;;
;;;; The declaration is the line `export DSMR_PROJECT_DISPOSITION=<value>`. It is
;;;; read from the file as text and never from the process environment: the
;;;; server's environment belongs to the directory it was launched in, the
;;;; repository asked about may be another one, and the lint gate runs under git
;;;; without direnv. The file is never sourced. A linked worktree with no
;;;; declaration of its own reads the main worktree's. Declarations that disagree
;;;; are refused, never resolved.
;;;;
;;;; Recording writes only the target worktree's own .envrc, only after .envrc is
;;;; in the local exclude, and never rewrites a value already declared: a change
;;;; of disposition is a hand edit.

(defpackage #:dsmr-mcp/src/repo-classify
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/git
                #:git-repository-p
                #:git-toplevel
                #:git-common-dir
                #:git-remote-url
                #:git-tracked-files
                #:not-a-repository-error)
  (:import-from #:dsmr-mcp/src/envrc-vars
                #:declared-values
                #:ensure-declaration-line
                #:region-open-line
                #:region-close-line)
  (:import-from #:dsmr-mcp/src/project-exclude
                #:repair-repo-exclude)
  (:import-from #:dsmr-mcp/src/project-root
                #:ensure-write-path)
  (:import-from #:dsmr-mcp/src/fs
                #:write-file-string-atomically)
  (:export #:+dispositions+
           #:+disposition-variable+
           #:+disposition-meanings+
           #:disposition
           #:disposition-name
           #:resolve-disposition
           #:check-disposition-recordable
           #:record-disposition
           #:disposition-profile
           #:disposition-warnings
           #:project-disposition-error
           #:project-disposition-required
           #:disposition-required-directory
           #:disposition-required-origin-url
           #:disposition-required-upstream-url
           #:project-disposition-conflict
           #:disposition-conflict-declarations
           #:project-disposition-unreadable
           #:disposition-unreadable-path
           #:disposition-unreadable-value
           #:project-disposition-not-recordable
           #:disposition-not-recordable-path
           #:disposition-not-recordable-reason))

(in-package #:dsmr-mcp/src/repo-classify)

;;; ---------------------------------------------------------------------------
;;; The vocabulary
;;; ---------------------------------------------------------------------------

(defvar +dispositions+ '(:ours :contributing :forked)
  "Every disposition a repository can be declared, in the order they are offered.

DEFVAR rather than DEFCONSTANT: DEFCONSTANT on a list re-evaluates to a fresh,
non-EQL list on reload and breaks a warm image.")

(deftype disposition ()
  "One of the three declared project dispositions."
  '(member :ours :contributing :forked))

(defvar +disposition-variable+ "DSMR_PROJECT_DISPOSITION"
  "The .envrc variable a disposition is recorded in.")

(defvar +disposition-meanings+
  '((:ours . "code originating with the operator; the lint gate refuses a commit whose changed forms carry a warning or an error")
    (:contributing . "a third-party project the operator only contributes to; the lint gate reports and never refuses, and the licence is never touched")
    (:forked . "forked to shorten the acceptance chain or because upstream is unmaintained; the lint gate is the one ours gets, and the licence it came with is kept"))
  "An alist of each disposition and what declaring it means.")

(defun disposition-name (disposition)
  "Return DISPOSITION's name as a lower-case string."
  (string-downcase (symbol-name disposition)))

;;; ---------------------------------------------------------------------------
;;; Conditions
;;; ---------------------------------------------------------------------------

(define-condition project-disposition-error (error)
  ()
  (:documentation "Parent of every refusal concerning a project disposition."))

(define-condition project-disposition-required (project-disposition-error)
  ((directory    :initarg :directory    :initform nil
                 :reader disposition-required-directory)
   (origin-url   :initarg :origin-url   :initform nil
                 :reader disposition-required-origin-url)
   (upstream-url :initarg :upstream-url :initform nil
                 :reader disposition-required-upstream-url))
  (:documentation
   "Signalled when no disposition is recorded and none was supplied.

Carries the directory and the origin and upstream URLs found, as facts for the
question; none of them answers it.")
  (:report
   (lambda (condition stream)
     (format stream "No project disposition is recorded for ~A~
~@[ (origin ~A)~]~@[ (upstream ~A)~]. Declare one of ~{~A~^, ~}."
             (disposition-required-directory condition)
             (disposition-required-origin-url condition)
             (disposition-required-upstream-url condition)
             (mapcar #'disposition-name +dispositions+)))))

(define-condition project-disposition-conflict (project-disposition-error)
  ((declarations :initarg :declarations :initform '()
                 :reader disposition-conflict-declarations))
  (:documentation
   "Signalled when two declarations of the disposition disagree.

DECLARATIONS is a list of (SOURCE . VALUE): SOURCE is the .envrc pathname or
:ARGUMENT for a supplied answer, VALUE the text declared.")
  (:report
   (lambda (condition stream)
     (format stream "The project disposition is declared more than once and the ~
declarations disagree: ~{~A~^; ~}. Edit the .envrc so one value remains."
             (mapcar (lambda (entry)
                       (format nil "~A in ~A"
                               (cdr entry)
                               (if (eq :argument (car entry))
                                   "the disposition argument"
                                   (namestring (car entry)))))
                     (disposition-conflict-declarations condition))))))

(define-condition project-disposition-unreadable (project-disposition-error)
  ((path  :initarg :path  :initform nil :reader disposition-unreadable-path)
   (value :initarg :value :initform nil :reader disposition-unreadable-value))
  (:documentation
   "Signalled when a declaration is not exactly one of the three names, bare or
inside one pair of matching quotes.")
  (:report
   (lambda (condition stream)
     (format stream "~A declares ~A=~A, which is not one of ~{~A~^, ~}. ~
The value is read as text and never expanded."
             (namestring (disposition-unreadable-path condition))
             +disposition-variable+
             (disposition-unreadable-value condition)
             (mapcar #'disposition-name +dispositions+)))))

(define-condition project-disposition-not-recordable (project-disposition-error)
  ((path   :initarg :path   :initform nil :reader disposition-not-recordable-path)
   (reason :initarg :reason :initform nil :reader disposition-not-recordable-reason))
  (:documentation
   "Signalled when a disposition cannot be recorded at PATH without the record
becoming tracked content or leaving the write jail.")
  (:report
   (lambda (condition stream)
     (format stream "The project disposition cannot be recorded in ~A: ~A."
             (namestring (disposition-not-recordable-path condition))
             (disposition-not-recordable-reason condition)))))

;;; ---------------------------------------------------------------------------
;;; Reading
;;; ---------------------------------------------------------------------------

(defun %parse-value (raw)
  "Return the disposition RAW names, or NIL.

Accepts exactly one of the three names, optionally inside one pair of matching
quotes. Any other text, a shell expansion included, is NIL."
  (let ((text raw))
    (when (and (>= (length text) 2)
               (member (char text 0) '(#\" #\'))
               (char= (char text 0) (char text (1- (length text)))))
      (setf text (subseq text 1 (1- (length text)))))
    (find text +dispositions+ :key #'disposition-name :test #'string=)))

(defun %worktree-root (directory)
  "Return the root of the worktree containing DIRECTORY."
  (uiop:ensure-directory-pathname (or (git-toplevel directory) directory)))

(defun %envrc-path (root)
  "Return the .envrc pathname under ROOT."
  (merge-pathnames ".envrc" (uiop:ensure-directory-pathname root)))

(defun %same-directory-p (a b)
  "Return true when A and B name the same existing directory."
  (let ((ta (probe-file a))
        (tb (probe-file b)))
    (and ta tb (string= (namestring ta) (namestring tb)))))

(defun %main-worktree-root (directory)
  "Return the main worktree's root when DIRECTORY lies in a linked worktree, else NIL.

The main worktree is the parent of the common git directory when that directory
is named .git. A bare or separated git directory has no main worktree."
  (let* ((common (git-common-dir directory))
         (name (car (last (pathname-directory common)))))
    (when (equal name ".git")
      (let ((main (uiop:pathname-parent-directory-pathname common)))
        (unless (%same-directory-p main (%worktree-root directory))
          main)))))

(defun %file-declaration (path)
  "Return the disposition the file at PATH declares, or NIL when it declares none.

Signals PROJECT-DISPOSITION-UNREADABLE for a value that is not one of the names,
and PROJECT-DISPOSITION-CONFLICT when the file declares two that disagree."
  (when (probe-file path)
    (let ((raws (declared-values (uiop:read-file-string path)
                                 +disposition-variable+)))
      (when raws
        (let ((parsed (mapcar (lambda (raw)
                                (or (%parse-value raw)
                                    (error 'project-disposition-unreadable
                                           :path path :value raw)))
                              raws)))
          (unless (every (lambda (d) (eq d (first parsed))) parsed)
            (error 'project-disposition-conflict
                   :declarations (mapcar (lambda (raw) (cons path raw)) raws)))
          (first parsed))))))

(defun resolve-disposition (directory &key supplied)
  "Return the disposition of the repository at DIRECTORY, and where it came from.

Two values: a member of +DISPOSITIONS+, and the .envrc pathname it was read from
or :ARGUMENT when SUPPLIED was used because nothing is recorded.

The worktree's own .envrc is read first; a linked worktree with no declaration
of its own reads the main worktree's. The process environment is never read.

Signals:
  NOT-A-REPOSITORY-ERROR          DIRECTORY lies outside any repository.
  PROJECT-DISPOSITION-REQUIRED    nothing recorded and SUPPLIED is NIL.
  PROJECT-DISPOSITION-CONFLICT    two declarations disagree, or SUPPLIED differs
                                  from the recorded value.
  PROJECT-DISPOSITION-UNREADABLE  a declared value is not one of the names.
  TYPE-ERROR                      SUPPLIED is not a disposition."
  (unless (git-repository-p directory)
    (error 'not-a-repository-error :path directory))
  (when supplied
    (check-type supplied disposition))
  (let* ((own-path (%envrc-path (%worktree-root directory)))
         (own (%file-declaration own-path))
         (main-root (%main-worktree-root directory))
         (main-path (and main-root (%envrc-path main-root)))
         (main (and main-path (%file-declaration main-path))))
    (when (and own main (not (eq own main)))
      (error 'project-disposition-conflict
             :declarations (list (cons main-path (disposition-name main))
                                 (cons own-path (disposition-name own)))))
    (let ((stored (or own main))
          (source (if own own-path main-path)))
      (cond
        ((and stored supplied (not (eq stored supplied)))
         (error 'project-disposition-conflict
                :declarations (list (cons source (disposition-name stored))
                                    (cons :argument (disposition-name supplied)))))
        (stored (values stored source))
        (supplied (values supplied :argument))
        (t (error 'project-disposition-required
                  :directory directory
                  :origin-url (git-remote-url directory "origin")
                  :upstream-url (git-remote-url directory "upstream")))))))

;;; ---------------------------------------------------------------------------
;;; Recording
;;; ---------------------------------------------------------------------------

(defun %envrc-tracked-p (root)
  "Return true when the repository at ROOT tracks its .envrc."
  (and (member ".envrc" (git-tracked-files root) :test #'string=) t))

(defun check-disposition-recordable (directory)
  "Signal PROJECT-DISPOSITION-NOT-RECORDABLE when the worktree containing
DIRECTORY tracks its .envrc, else return NIL. Writes nothing."
  (let ((root (%worktree-root directory)))
    (when (%envrc-tracked-p root)
      (error 'project-disposition-not-recordable
             :path (%envrc-path root)
             :reason "the repository tracks its .envrc, so a declaration written there would be committed"))))

(defun %declaration-text (text disposition)
  "Return TEXT with the declaration of DISPOSITION added, every other line kept.
The line joins the last dsmr-mcp managed region, or a new one is appended."
  (let ((line (format nil "export ~A=~A" +disposition-variable+
                      (disposition-name disposition))))
    (if (zerop (length text))
        (format nil "~A~%~A~%~A~%" (region-open-line) line (region-close-line))
        (values (ensure-declaration-line text +disposition-variable+ line)))))

(defun record-disposition (directory disposition &key jail dry-run)
  "Record DISPOSITION in the .envrc of the worktree containing DIRECTORY.

Returns a plist (:PATH P :DISPOSITION D :ACTION-TAKEN A), where A is :CREATED
(no .envrc existed), :ADDED (the line joined an existing file), :ALREADY-PRESENT
(the same value is declared), or :WOULD-RECORD (DRY-RUN; nothing written).

Before writing, .envrc is added to the local exclude. Every other line of an
existing file is kept. JAIL, defaulting to the worktree root, bounds the write.

Signals:
  PROJECT-DISPOSITION-CONFLICT        a different value is already declared.
  PROJECT-DISPOSITION-UNREADABLE      the declared value cannot be read.
  PROJECT-DISPOSITION-NOT-RECORDABLE  the .envrc is tracked, or lies outside JAIL.
  TYPE-ERROR                          DISPOSITION is not a disposition."
  (check-type disposition disposition)
  (let* ((root (%worktree-root directory))
         (path (%envrc-path root))
         (stored (%file-declaration path)))
    (cond
      ((eq stored disposition)
       (list :path path :disposition disposition :action-taken :already-present))
      (stored
       (error 'project-disposition-conflict
              :declarations (list (cons path (disposition-name stored))
                                  (cons :argument (disposition-name disposition)))))
      (t
       (check-disposition-recordable root)
       (let ((target (ensure-write-path (namestring path) (or jail root))))
         (unless target
           (error 'project-disposition-not-recordable
                  :path path
                  :reason "the .envrc lies outside the write jail"))
         (if dry-run
             (list :path path :disposition disposition :action-taken :would-record)
             (let* ((existed (and (probe-file path) t))
                    (text (if existed (uiop:read-file-string path) "")))
               (repair-repo-exclude root :template-patterns (list ".envrc"))
               (write-file-string-atomically target
                                             (%declaration-text text disposition))
               (list :path path
                     :disposition disposition
                     :action-taken (if existed :added :created)))))))))

;;; ---------------------------------------------------------------------------
;;; What the disposition implies
;;; ---------------------------------------------------------------------------

(defun disposition-profile (disposition)
  "Return the shape profile for DISPOSITION: :OURS for ours and forked, :FOREIGN
for contributing. Signals TYPE-ERROR for anything else."
  (ecase disposition
    ((:ours :forked) :ours)
    (:contributing :foreign)))

(defun %declares-p (path)
  "Return true when the file at PATH holds a disposition declaration of any value."
  (and (probe-file path)
       (declared-values (uiop:read-file-string path) +disposition-variable+)
       t))

(defun disposition-warnings (directory disposition &key upstream-url)
  "Return a list of warning strings about DISPOSITION against the repository's
remotes and files. Each states a fact that does not fit the declaration; none
changes it.

UPSTREAM-URL is an upstream about to be recorded, counted as recorded."
  (let* ((root (%worktree-root directory))
         (upstream (or (git-remote-url directory "upstream") upstream-url))
         (main-root (%main-worktree-root directory))
         (warnings '()))
    (when (and (eq disposition :ours) upstream)
      (push (format nil "declared ours, but an upstream remote is recorded (~A); ~
code that originates here has no upstream, so forked may be the disposition meant"
                    upstream)
            warnings))
    (when (and (eq disposition :contributing) (null upstream))
      (push "declared contributing, but no upstream remote is recorded; supply upstream_url to record the project contributed to"
            warnings))
    (when (and (%declares-p (%envrc-path root)) (%envrc-tracked-p root))
      (push "the .envrc holding the declaration is tracked, so the declaration is committed content"
            warnings))
    (when (and main-root (not (%declares-p (%envrc-path main-root))))
      (push (format nil "the disposition is recorded only in this linked worktree; ~
a new worktree of this repository would be asked again until ~A declares it"
                    (namestring (%envrc-path main-root)))
            warnings))
    (nreverse warnings)))
