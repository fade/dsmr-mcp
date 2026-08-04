;;;; src/git.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Typed git subprocess primitives.
;;;;
;;;; Every git invocation in this codebase goes through RUN-GIT. Two properties
;;;; are the reason this module exists rather than each caller shelling out for
;;;; itself:
;;;;
;;;; 1. Argument vectors are always lists. A remote URL or a path can therefore
;;;;    never be reinterpreted as shell syntax, no matter what a caller hands in.
;;;;
;;;; 2. A non-zero exit signals GIT-COMMAND-ERROR by default. A git failure that
;;;;    returns a value indistinguishable from success is the bug this module is
;;;;    built to prevent, so swallowing status is opt-in and never the default.
;;;;    Exactly two readers translate one specific non-zero status into NIL, and
;;;;    each says in its own docstring which status it accepts and why.

(defpackage #:dsmr-mcp/src/git
  (:use #:cl)
  (:export #:git-command-error
           #:git-command-error-argv
           #:git-command-error-exit-code
           #:git-command-error-stderr
           #:not-a-repository-error
           #:not-a-repository-path
           #:run-git
           #:git-repository-p
           #:git-toplevel
           #:git-init
           #:git-remote-url
           #:git-remote-add
           #:git-tracked-files
           #:git-head-sha
           #:git-status-porcelain))

(in-package #:dsmr-mcp/src/git)

;;; ---------------------------------------------------------------------------
;;; Conditions
;;; ---------------------------------------------------------------------------

(define-condition git-command-error (error)
  ((argv      :initarg :argv      :reader git-command-error-argv)
   (exit-code :initarg :exit-code :reader git-command-error-exit-code)
   (stderr    :initarg :stderr    :initform "" :reader git-command-error-stderr))
  (:documentation
   "Signaled when a git invocation fails.

Carries the whole argument vector, the process exit code and whatever git
wrote to standard error, so a caller reporting the failure does not have to
reconstruct what was run. An exit code of -1 means the invocation was rejected
before a process was ever started.")
  (:report
   (lambda (condition stream)
     (format stream "git command ~S failed with exit code ~A: ~A"
             (git-command-error-argv condition)
             (git-command-error-exit-code condition)
             (git-command-error-stderr condition)))))

(setf (documentation 'git-command-error-argv 'function)
      "Return the full argument vector of the failed git invocation.")
(setf (documentation 'git-command-error-exit-code 'function)
      "Return the process exit code, or -1 when the invocation was rejected before launch.")
(setf (documentation 'git-command-error-stderr 'function)
      "Return what git wrote to standard error, or the rejection reason.")

(define-condition not-a-repository-error (error)
  ((path :initarg :path :reader not-a-repository-path))
  (:documentation
   "Signaled when a directory that was required to be a git repository is not one.

Distinct from GIT-COMMAND-ERROR: nothing failed, the caller's precondition was
simply not met.")
  (:report
   (lambda (condition stream)
     (format stream "~A is not a git repository."
             (not-a-repository-path condition)))))

(setf (documentation 'not-a-repository-path 'function)
      "Return the directory that was expected to be a git repository.")

;;; ---------------------------------------------------------------------------
;;; Child process environment
;;; ---------------------------------------------------------------------------

(defun %environment-key (entry)
  "Return the variable name of an environment ENTRY written as NAME=VALUE."
  (let ((separator (position #\= entry)))
    (if separator (subseq entry 0 separator) entry)))

(defun %inherited-environment ()
  "Return the current process environment as a list of NAME=VALUE strings."
  #+sbcl (sb-ext:posix-environ)
  #-sbcl nil)

(defun %child-environment ()
  "Return the environment handed to a git child process.

The inherited environment is preserved so git still finds its configuration,
its PATH and the operator's locale. Two entries are forced on top of it, and
any inherited entry of the same name is dropped so the forced value wins: a
git that cannot find credentials must fail immediately rather than stop and
wait for a password, because no terminal is attached to answer it and the
whole caller would hang."
  (let ((forced (list "GIT_TERMINAL_PROMPT=0" "GIT_ASKPASS=/bin/true")))
    (append forced
            (remove-if (lambda (entry)
                         (member (%environment-key entry) forced
                                 :key #'%environment-key
                                 :test #'string=))
                       (%inherited-environment)))))

;;; ---------------------------------------------------------------------------
;;; Text helpers
;;; ---------------------------------------------------------------------------

(defun %trim (string)
  "Return STRING with surrounding whitespace removed."
  (string-trim '(#\Space #\Tab #\Newline #\Return) (or string "")))

(defun %nonempty (string)
  "Return STRING when it holds something, NIL when it is empty."
  (if (string= string "") nil string))

(defun %split-on-nul (string)
  "Split STRING on NUL characters, discarding empty pieces.

git's -z output terminates rather than separates, so the piece after the final
NUL is always empty and dropping it is correct rather than lossy."
  (let ((pieces '())
        (start 0))
    (loop for position = (position #\Nul string :start start)
          while position
          do (let ((piece (subseq string start position)))
               (unless (string= piece "")
                 (push piece pieces)))
             (setf start (1+ position)))
    (let ((tail (subseq string start)))
      (unless (string= tail "")
        (push tail pieces)))
    (nreverse pieces)))

;;; ---------------------------------------------------------------------------
;;; The single invocation point
;;; ---------------------------------------------------------------------------

(defun run-git (args &key directory (error-on-failure t))
  "Run git with ARGS, optionally inside DIRECTORY, and return four values:
standard output, standard error, the exit code, and the argument vector used.

ARGS is a list of strings appended to the vector (\"git\" \"-C\" DIRECTORY).
Nothing is ever passed through a shell, so a caller-supplied path or URL cannot
become shell syntax.

When ERROR-ON-FAILURE is true (the default) a non-zero exit signals
GIT-COMMAND-ERROR carrying the argument vector, the exit code and standard
error. Pass NIL only where a specific non-zero status is a meaningful answer
rather than a failure, and say in the caller which status that is."
  (let ((argv (append (list "git")
                      (when directory
                        (list "-C" (namestring
                                    (uiop:ensure-directory-pathname directory))))
                      args)))
    (multiple-value-bind (stdout stderr exit-code)
        (uiop:run-program argv
                          :output :string
                          :error-output :string
                          :ignore-error-status t
                          :environment (%child-environment))
      (let ((stdout (or stdout ""))
            (stderr (or stderr "")))
        (when (and error-on-failure (not (zerop exit-code)))
          (error 'git-command-error
                 :argv argv
                 :exit-code exit-code
                 :stderr stderr))
        (values stdout stderr exit-code argv)))))

;;; ---------------------------------------------------------------------------
;;; Repository shape
;;; ---------------------------------------------------------------------------

(defun git-repository-p (directory)
  "Return T when DIRECTORY sits inside a git repository, NIL otherwise.

A directory that does not exist, or that lies outside any repository, is not a
failure to report: it is the answer NIL."
  (multiple-value-bind (stdout stderr exit-code)
      (run-git (list "rev-parse" "--git-dir")
               :directory directory
               :error-on-failure nil)
    (declare (ignore stdout stderr))
    (zerop exit-code)))

(defun git-toplevel (directory)
  "Return the root of the repository containing DIRECTORY, or NIL if there is none.

This is what separates \"this directory IS a repository root\" from \"this
directory sits inside somebody else's repository\". Initialising a repository
inside a tree that already belongs to one is a mistake no later caller can
undo, so the decision to do it rests on comparing this value against the
directory asked about."
  (multiple-value-bind (stdout stderr exit-code)
      (run-git (list "rev-parse" "--show-toplevel")
               :directory directory
               :error-on-failure nil)
    (declare (ignore stderr))
    (when (zerop exit-code)
      (let ((root (%nonempty (%trim stdout))))
        (when root
          (uiop:ensure-directory-pathname root))))))

(defun git-init (directory)
  "Create DIRECTORY if needed, initialise a git repository in it, and return it.

A failed initialisation propagates as GIT-COMMAND-ERROR. Everything downstream
assumes the repository exists, so a silent failure here would surface much
later as a confusing absence."
  (let ((root (uiop:ensure-directory-pathname directory)))
    (ensure-directories-exist root)
    (run-git (list "init" "-q") :directory root)
    root))

;;; ---------------------------------------------------------------------------
;;; Remotes
;;; ---------------------------------------------------------------------------

(defun git-remote-url (directory remote-name)
  "Return the URL configured for REMOTE-NAME in DIRECTORY, or NIL when absent.

git config exits 1 for a key that is not set, which is the answer \"there is no
such remote\" and not a failure. Any other non-zero status signals
GIT-COMMAND-ERROR, so an absent remote stays distinguishable from a broken
repository or an unreadable config."
  (let ((key (format nil "remote.~A.url" remote-name)))
    (multiple-value-bind (stdout stderr exit-code argv)
        (run-git (list "config" "--get" key)
                 :directory directory
                 :error-on-failure nil)
      (cond ((zerop exit-code) (%nonempty (%trim stdout)))
            ((= exit-code 1) nil)
            (t (error 'git-command-error
                      :argv argv
                      :exit-code exit-code
                      :stderr stderr))))))

(defun %remote-url-rejection (url)
  "Return the reason URL is unfit to hand to git, or NIL when it is fit."
  (cond ((not (stringp url))
         "remote URL must be a string")
        ((string= url "")
         "remote URL must not be empty")
        ((char= (char url 0) #\-)
         "remote URL must not start with a hyphen, git would read it as an option")
        ((find-if (lambda (character)
                    (let ((code (char-code character)))
                      (or (< code 32) (= code 127))))
                  url)
         "remote URL must not contain a control character, newline, carriage return or NUL")
        (t nil)))

(defun git-remote-add (directory remote-name url)
  "Add REMOTE-NAME pointing at URL in DIRECTORY and return URL.

URL is checked before anything is run. A URL that begins with a hyphen would be
consumed as an option by git rather than treated as a location, and a URL
carrying a control character or newline cannot be represented faithfully in a
config file. Either one signals GIT-COMMAND-ERROR with exit code -1, meaning no
process was ever started and no remote was added."
  (let ((rejection (%remote-url-rejection url)))
    (when rejection
      (error 'git-command-error
             :argv (list "git" "remote" "add" remote-name url)
             :exit-code -1
             :stderr rejection)))
  (run-git (list "remote" "add" remote-name url) :directory directory)
  url)

;;; ---------------------------------------------------------------------------
;;; Working tree state
;;; ---------------------------------------------------------------------------

(defun git-tracked-files (directory)
  "Return the repository-relative paths git tracks in DIRECTORY, as strings.

The listing is read NUL-separated so a path containing a newline or a quote
survives intact. A file present on disk but never added does not appear here,
which is the distinction every never-leak check rests on."
  (%split-on-nul (run-git (list "ls-files" "-z") :directory directory)))

(defun git-head-sha (directory)
  "Return the commit sha at HEAD in DIRECTORY, or NIL when there is no commit yet.

A freshly initialised repository has no HEAD and git exits non-zero saying so.
That is a normal state during adoption rather than an error, so it becomes NIL."
  (multiple-value-bind (stdout stderr exit-code)
      (run-git (list "rev-parse" "HEAD")
               :directory directory
               :error-on-failure nil)
    (declare (ignore stderr))
    (when (zerop exit-code)
      (%nonempty (%trim stdout)))))

(defun git-status-porcelain (directory)
  "Return the non-empty lines of git status --porcelain for DIRECTORY.

An empty list means the working tree is clean, which is how a run proves it
changed nothing."
  (remove-if (lambda (line) (string= (%trim line) ""))
             (uiop:split-string (run-git (list "status" "--porcelain")
                                         :directory directory)
                                :separator '(#\Newline))))
