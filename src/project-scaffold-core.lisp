;;;; src/project-scaffold-core.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Pure helpers for project-scaffold (VERB-22): input validation, template
;;;; rendering, path math, and file manifest construction. No I/O. No worker
;;;; interaction. This module exists so the effectful layer in
;;;; project-scaffold.lisp stays thin and the bulk of the logic is testable
;;;; without a session root, a filesystem, or a running image.

(defpackage #:dsmr-mcp/src/project-scaffold-core
  (:use #:cl)
  (:import-from #:cl-ppcre
                #:scan
                #:regex-replace-all)
  (:import-from #:dsmr-mcp/src/project-scaffold-templates
                #:*asd-template*
                #:*main-lisp-template*
                #:*main-test-template*
                #:*build-template*
                #:*dev-boot-template*
                #:*agents-md-template*
                #:*claude-md-template*
                #:*readme-template*
                #:*gitignore-template*
                #:*prompt-template*
                #:*license-template*
                #:license-body-for-spdx)
  (:export #:validate-project-name
           #:validate-destination
           #:validate-text-field
           #:render-template
           #:plan-scaffold
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
;;; Template rendering
;;; ---------------------------------------------------------------------------

(defun render-template (template bindings)
  "Return TEMPLATE with each '{{key}}' substituted using BINDINGS.
BINDINGS is an alist of (KEY-STRING . VALUE-STRING). Unknown placeholders
are left intact. Values are substituted literally; regex metacharacters
in values (including backslash and dollar sign) are handled safely via
cl-ppcre's :simple-calls replacement callback."
  (cl-ppcre:regex-replace-all
   "\\{\\{([A-Za-z_-][A-Za-z0-9_-]*)\\}\\}"
   template
   (lambda (match &rest registers)
     (declare (ignore match))
     (let* ((key (first registers))
            (entry (assoc key bindings :test #'string=)))
       (if entry
           (cdr entry)
           (format nil "{{~A}}" key))))
   :simple-calls t))

;;; ---------------------------------------------------------------------------
;;; Manifest builder
;;; ---------------------------------------------------------------------------

(defun plan-scaffold (&key name description author license copyright year destination)
  "Return an alist of (RELATIVE-PATH . CONTENT) for the scaffold manifest.
Applies all template substitutions but performs no I/O. Callers are
responsible for input validation before calling this function;
plan-scaffold assumes its arguments are already normalized strings.

The full D-17 file set is emitted: <name>.asd, src/main.lisp,
tests/main-test.lisp, build.sh, scripts/dev-boot.sh, AGENTS.md, CLAUDE.md,
README.md, .gitignore, LICENSE, prompts/repl-driven-development.md.

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
                     ("year"          . ,(or year "2026"))
                     ("license-body"  . ,license-body))))
    ;; Render the license body with copyright/year substitutions
    (let ((bindings-with-rendered-license
           (cons (cons "license-body" (render-template license-body bindings))
                 (remove "license-body" bindings :key #'car :test #'string=))))
      (let ((render2 (lambda (tpl) (render-template tpl bindings-with-rendered-license))))
        (list
         (cons (format nil "~A.asd" name) (funcall render2 *asd-template*))
         (cons "src/main.lisp"           (funcall render2 *main-lisp-template*))
         (cons "tests/main-test.lisp"    (funcall render2 *main-test-template*))
         (cons "build.sh"                (funcall render2 *build-template*))
         (cons "scripts/dev-boot.sh"     (funcall render2 *dev-boot-template*))
         (cons "AGENTS.md"               (funcall render2 *agents-md-template*))
         (cons "CLAUDE.md"               (funcall render2 *claude-md-template*))
         (cons "README.md"               (funcall render2 *readme-template*))
         (cons ".gitignore"              (funcall render2 *gitignore-template*))
         (cons "prompts/repl-driven-development.md"
                                         (funcall render2 *prompt-template*))
         (cons "LICENSE"                 (funcall render2 *license-template*)))))))
