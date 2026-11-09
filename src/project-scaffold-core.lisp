;;;; src/project-scaffold-core.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Pure helpers for project-scaffold: input validation, path math, and file
;;;; manifest construction. No I/O. No worker interaction. This module exists
;;;; so the effectful layer in project-scaffold.lisp stays thin and the bulk of
;;;; the logic is testable without a session root, a filesystem, or a running
;;;; image.
;;;;
;;;; The manifest is derived from the shape catalogue rather than listed here.
;;;; The catalogue is the same definition an existing repository is assessed
;;;; against, and two lists that agree today drift tomorrow: once they have,
;;;; a repository can be certified as the right shape while being one the
;;;; scaffold would not produce, and nothing reports it.

(defpackage #:dsmr-mcp/src/project-scaffold-core
  (:use #:cl)
  (:import-from #:cl-ppcre
                #:scan)
  (:import-from #:dsmr-mcp/src/template-render
                #:render-template)
  (:import-from #:dsmr-mcp/src/project-shape
                #:shape-item-key
                #:shape-item-path
                #:shape-item-generator
                #:shape-item-emit-on-scaffold-p
                #:shape-item-install-target)
  ;; *SHAPE-CATALOG* is declared by project-shape and filled by the catalogue data
  ;; file. Reading it from the catalogue package is what makes this module depend
  ;; on the file that populates it, so the manifest is never derived from an
  ;; empty list.
  (:import-from #:dsmr-mcp/src/project-shape-catalog
                #:*shape-catalog*)
  (:import-from #:dsmr-mcp/src/project-scaffold-templates
                #:license-body-for-spdx)
  (:export #:validate-project-name
           #:validate-destination
           #:validate-text-field
           #:render-template
           #:plan-scaffold
           #:without-licence-text
           #:invalid-argument-error
           #:invalid-argument-field
           #:invalid-argument-value
           #:invalid-argument-reason))

(in-package #:dsmr-mcp/src/project-scaffold-core)

;;; ---------------------------------------------------------------------------
;;; Condition
;;; ---------------------------------------------------------------------------

(define-condition invalid-argument-error (error)
  ((field  :initarg :field  :reader invalid-argument-field)
   (value  :initarg :value  :reader invalid-argument-value)
   (reason :initarg :reason :reader invalid-argument-reason))
  (:documentation "Signaled when a project-scaffold input argument is invalid.")
  (:report
   (lambda (condition stream)
     (format stream "Invalid argument ~A = ~S: ~A"
             (invalid-argument-field condition)
             (invalid-argument-value condition)
             (invalid-argument-reason condition)))))

(setf (documentation 'invalid-argument-field 'function)
      "Return the name of the offending field from an INVALID-ARGUMENT-ERROR.")
(setf (documentation 'invalid-argument-value 'function)
      "Return the rejected value from an INVALID-ARGUMENT-ERROR.")
(setf (documentation 'invalid-argument-reason 'function)
      "Return the human-readable reason string from an INVALID-ARGUMENT-ERROR.")

;;; ---------------------------------------------------------------------------
;;; Validators
;;; ---------------------------------------------------------------------------

(defparameter *project-name-regex* "^[a-z][a-z0-9-]*$"
  "Regular expression that valid project names must fully match.")

(defparameter *project-name-max-length* 64
  "Maximum allowed length for a project name.")

(defun validate-project-name (name)
  "Return NAME unchanged when valid, else signal INVALID-ARGUMENT-ERROR.
A valid name is a non-empty string of length at most *PROJECT-NAME-MAX-LENGTH*
that fully matches *PROJECT-NAME-REGEX*: a lower-case letter followed by
lower-case letters, digits, or hyphens."
  (unless (stringp name)
    (error 'invalid-argument-error
           :field "name" :value name :reason "must be a string"))
  (when (zerop (length name))
    (error 'invalid-argument-error
           :field "name" :value name :reason "must not be empty"))
  (when (> (length name) *project-name-max-length*)
    (error 'invalid-argument-error
           :field "name" :value name
           :reason (format nil "must be at most ~D characters" *project-name-max-length*)))
  (unless (cl-ppcre:scan *project-name-regex* name)
    (error 'invalid-argument-error
           :field "name" :value name
           :reason (format nil "must match ~A" *project-name-regex*)))
  name)

(defun validate-destination (destination)
  "Return DESTINATION when it is a safe relative path, else signal error.
A valid destination is a non-empty relative path with no absolute segment
and no '..' component."
  (unless (and (stringp destination) (plusp (length destination)))
    (error 'invalid-argument-error
           :field "destination" :value destination
           :reason "must be a non-empty string"))
  (when (char= (char destination 0) #\/)
    (error 'invalid-argument-error
           :field "destination" :value destination
           :reason "must be a relative path (no leading /)"))
  (dolist (segment (uiop:split-string destination :separator "/"))
    (when (string= segment "..")
      (error 'invalid-argument-error
             :field "destination" :value destination
             :reason "must not contain '..' path segments")))
  destination)

(defun validate-text-field (field-name value)
  "Return VALUE when it is an acceptable free-text field, else signal.
FIELD-NAME is included in the error for caller-side diagnostics. A valid
value is a string containing no newline (#\\Newline) or carriage return
(#\\Return) characters. Empty strings are allowed."
  (unless (stringp value)
    (error 'invalid-argument-error
           :field field-name :value value :reason "must be a string"))
  (when (or (find #\Newline value) (find #\Return value))
    (error 'invalid-argument-error
           :field field-name :value value
           :reason "must not contain newline characters"))
  value)

;;; ---------------------------------------------------------------------------
;;; Manifest builder
;;; ---------------------------------------------------------------------------

(defun %current-year ()
  "Return the current calendar year as a string (the single source of the
year default for generated LICENSE/.asd content)."
  (format nil "~D" (nth-value 5 (get-decoded-time))))

(defun %item-content (item bindings)
  "Return the content ITEM's generator produces from BINDINGS.

An item the scaffold is asked to emit but that carries no generator is a
catalogue defect, not a caller mistake, and it is reported as one. Skipping it
instead would write a project silently short of a file the catalogue says it
has, while the manifest still looked complete."
  (let ((generator (shape-item-generator item)))
    (unless generator
      (error "Shape catalogue item ~S is marked for emission but has no generator."
             (shape-item-key item)))
    (funcall generator bindings)))

(defun without-licence-text (text)
  "Return TEXT without its licence text: every line naming an SPDX identifier,
every :license line, and a Markdown section headed License up to the next
heading of the same or a higher level. Every other line is kept."
  (let ((kept '())
        (skipping nil))
    (dolist (line (uiop:split-string text :separator '(#\Newline)))
      (let ((trimmed (string-trim '(#\Space #\Tab #\Return) line)))
        (cond
          ((string= trimmed "## License") (setf skipping t))
          ((and skipping (or (uiop:string-prefix-p "# " trimmed)
                             (uiop:string-prefix-p "## " trimmed)))
           (setf skipping nil)
           (push line kept))
          (skipping nil)
          ((search "SPDX-License-Identifier" trimmed) nil)
          ((uiop:string-prefix-p ":license " trimmed) nil)
          (t (push line kept)))))
    (let ((result (string-right-trim '(#\Newline)
                                     (format nil "~{~A~^~%~}" (nreverse kept)))))
      (if (uiop:string-suffix-p text (string #\Newline))
          (concatenate 'string result (string #\Newline))
          result))))

(defun plan-scaffold (&key name description author license copyright year destination
                           without-licence)
  "Return an alist of (RELATIVE-PATH . CONTENT) for the scaffold manifest.
Applies all template substitutions but performs no I/O. Callers are
responsible for input validation before calling this function;
plan-scaffold assumes its arguments are already normalized strings.

Which files are emitted is not listed here. It is read from the shape catalogue,
which is the same definition an existing repository is assessed against, so
the set the scaffold writes and the set a repository is expected to have
cannot drift apart. An item is emitted when it is marked for emission and
lives in the working tree; an item belonging under the repository's git
directory is never part of a manifest.

Both an item's path and its content go through template substitution, so the
catalogue can name a file whose name depends on the project.

WITHOUT-LICENCE true plans no licence text at all: no LICENSE file, and no
SPDX identifier, :license line or License section in any other file. LICENSE
and COPYRIGHT are then ignored.

DESTINATION is accepted for caller symmetry with write-scaffold but is not used
here: the prompt is copied into the project's own prompts/ dir, so no path back
to a parent prompts/ directory is computed."
  (declare (ignore destination))
  (let* ((spdx           (or license "AGPL-3.0-or-later"))
         (raw-license-body (license-body-for-spdx spdx))
         (license-body   (or raw-license-body
                             (format nil "License: ~A~%See: https://spdx.org/licenses/~A.html~%"
                                     spdx spdx)))
         (bindings `(("name"          . ,name)
                     ("description"   . ,(or description ""))
                     ("author"        . ,(or author ""))
                     ("license"       . ,spdx)
                     ("spdx"          . ,spdx)
                     ("copyright"     . ,(or copyright author "Unknown"))
                     ("year"          . ,(or year (%current-year)))
                     ;; A project we create states the licence its creator
                     ;; chose on every script, and starts at the linter's own
                     ;; severities: it has no existing sites to hold below the
                     ;; failing threshold.
                     ("spdx-line"     . ,(format nil "# SPDX-License-Identifier: ~A"
                                                 spdx))
                     ("severity-pins" . "")
                     ("license-body"  . ,license-body))))
    ;; Render the license body with copyright/year substitutions
    (let ((bindings-with-rendered-license
           (cons (cons "license-body" (render-template license-body bindings))
                 (remove "license-body" bindings :key #'car :test #'string=))))
      (loop for item in *shape-catalog*
            when (and (shape-item-emit-on-scaffold-p item)
                      (eq :worktree (shape-item-install-target item))
                      (not (and without-licence
                                (eq :license (shape-item-key item)))))
              collect (let ((content (%item-content
                                      item bindings-with-rendered-license)))
                        (cons (render-template (shape-item-path item)
                                               bindings-with-rendered-license)
                              (if without-licence
                                  (without-licence-text content)
                                  content)))))))
