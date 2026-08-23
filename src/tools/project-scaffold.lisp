;;;; src/tools/project-scaffold.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; MCP tool: emit a full DSMR-discipline Lisp project tree under the
;;;; session write-jail. Mode-independent (dispatcher-side). No-root guard
;;;; at entry — scaffold writes require a session root.

(defpackage #:dsmr-mcp/src/tools/project-scaffold
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/tools/base
                #:mcp-tool
                #:mcp-tool-class
                #:tool-handle
                #:tool-session)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:make-ht
                #:result
                #:text-content)
  (:import-from #:dsmr-mcp/src/state
                #:session-project-root)
  (:import-from #:dsmr-mcp/src/project-scaffold
                #:write-scaffold)
  (:import-from #:dsmr-mcp/src/project-scaffold-core
                #:invalid-argument-error
                #:invalid-argument-field
                #:invalid-argument-reason))

(in-package #:dsmr-mcp/src/tools/project-scaffold)

(defclass project-scaffold-tool (mcp-tool)
  ((dsmr-mcp/src/tools/base::name
    :allocation :class
    :initform "project-scaffold")
   (dsmr-mcp/src/tools/base::description
    :allocation :class
    :initform "Generate a complete Lisp project skeleton under the session root. \
Emits a package-inferred-system with a mode-dispatching executable, Zebra \
test suite, build recipe, dev-boot script, dependency-preference agent docs, \
a copied REPL-development guide, and a selectable license with per-file SPDX \
headers. Returns a manifest of created files and next-step commands.")
   (dsmr-mcp/src/tools/base::input-schema
    :allocation :class
    :initform '(:object
                :properties
                ((name
                  :type :string
                  :description "Project name in lisp-case (e.g. foo-lib). \
Must match ^[a-z][a-z0-9-]*$ and be 1-64 characters.")
                 (license
                  :type :string
                  :enum ("AGPL-3.0-or-later" "GPL-3.0-or-later" "GPL-2.0-or-later"
                         "LGPL-3.0-or-later" "LGPL-2.1-or-later"
                         "MIT" "BSD-2-Clause" "BSD-3-Clause" "Apache-2.0")
                  :description "SPDX license identifier (default: AGPL-3.0-or-later).")
                 (author
                  :type :string
                  :description "Author string for .asd :author. No newlines.")
                 (copyright
                  :type :string
                  :description "Copyright holder for LICENSE file (defaults to author). No newlines.")
                 (description
                  :type :string
                  :description "One-line project description for .asd and README. No newlines.")
                 (destination
                  :type :string
                  :description "Relative parent directory under the session root \
where <name>/ is created (default: scaffolds). No leading / or .. segments.")
                 (year
                  :type :string
                  :description "Copyright year for LICENSE (default: current year).")
                 (overwrite
                  :type :boolean
                  :description "When true, replace an existing scaffold directory. Default: false."))
                :required ("name"))))
  (:metaclass mcp-tool-class)
  (:documentation "MCP tool: generate a DSMR-discipline Lisp project skeleton.
Writes an atomic tree under the session root via temp-dir + rename-file.
No-root guard at entry — call fs-set-project-root first."))

(c2mop:ensure-finalized (find-class 'project-scaffold-tool))

(defmethod tool-handle ((tool project-scaffold-tool) id args)
  (let* ((session (tool-session tool))
         (root    (session-project-root session)))
    ;; No-root guard: scaffold writes under the session root
    (unless root
      (return-from tool-handle
        (result id (make-ht "isError" t
                            "error_type" "project-root-not-set"
                            "content"
                            (text-content "project-scaffold: no project root set. \
Call fs-set-project-root first.")))))
    ;; Read args (kebab->snake wire transform: description stays description,
    ;; others match schema property names directly)
    (let* ((name        (gethash "name" args))
           (license     (gethash "license" args))
           (author      (gethash "author" args))
           (copyright   (gethash "copyright" args))
           (description (gethash "description" args))
           (destination (gethash "destination" args))
           (year        (gethash "year" args))
           (overwrite   (gethash "overwrite" args)))
      (unless (and name (stringp name))
        (return-from tool-handle
          (result id (make-ht "isError" t
                              "error_type" "invalid-argument"
                              "content" (text-content "project-scaffold: name must be a string.")))))
      (handler-case
          (let* ((res         (write-scaffold
                               :session-root root
                               :name name
                               :description (or description
                                                "A Common Lisp project.")
                               :author (or author "Unknown")
                               :license (or license "AGPL-3.0-or-later")
                               :copyright (or copyright author "Unknown")
                               ;; year default (live current year) is owned by
                               ;; the scaffold core; pass the raw arg through
                               :year year
                               :destination (or destination "scaffolds")
                               :overwrite overwrite))
                 (target-dir  (getf res :target-dir))
                 (relative    (getf res :relative-path))
                 (files       (getf res :files))
                 (abs-asd     (namestring
                               (merge-pathnames (format nil "~A.asd" name) target-dir)))
                 (registration (getf res :registration))
                 (next-steps  (vector
                               ;; Report what registration actually reached. A
                               ;; project on a configured source-registry tree
                               ;; is findable from any image on this host; one
                               ;; outside every tree was registered here alone,
                               ;; and the caller needs the load-asd line to
                               ;; reach any other image.
                               (if (eq registration :source-registry)
                                   (format nil
                                           "Registered with ASDF: ~S resolves on the source registry. ~
In an image that started before this scaffold: (asdf:load-asd ~S)"
                                           name abs-asd)
                                   (format nil
                                           "Registered in this image only: ~S sits outside every configured ~
ASDF source-registry tree. Elsewhere: (asdf:load-asd ~S)"
                                           name abs-asd))
                               (format nil
                                       "To load: run load-system with {\"system\": ~S}"
                                       name)
                               (format nil
                                       "To test: run run-tests with {\"system\": ~S}"
                                       (format nil "~A/tests" name))
                               (format nil
                                       "To edit: use lisp-edit-form with paths under ~A"
                                       (namestring target-dir)))))
            (result id
                    (make-ht "created" t
                             "path" (if (stringp relative) relative
                                        (namestring relative))
                             "absolute_path" (namestring target-dir)
                             "files" (coerce files 'vector)
                             "next_steps" next-steps
                             "content"
                             (text-content
                              (format nil "Scaffolded ~A at ~A (~D files)~%Path: ~A~%~{~A~%~}"
                                      name relative (length files)
                                      (namestring target-dir)
                                      (coerce next-steps 'list))))))
        (invalid-argument-error (e)
          (result id
                  (make-ht "isError" t
                           "created" nil
                           "error_type" (let ((field (invalid-argument-field e))
                                              (reason (invalid-argument-reason e)))
                                          (if (string= field "destination")
                                              "sandbox-violation"
                                              "invalid-argument"))
                           "content" (text-content (princ-to-string e)))))))))
