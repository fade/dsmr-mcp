;;;; src/template-render.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; The one placeholder substitution used to turn a template into file content.
;;;;
;;;; It lives on its own rather than beside the scaffold because two modules need
;;;; it and neither may depend on the other. The shape catalog renders a template
;;;; to produce an item's content, and the scaffold renders the same templates to
;;;; produce a manifest derived from that catalog. With the substitution sitting
;;;; in the scaffold, those two imports close a loop and the system will not
;;;; build. Nothing here depends on anything of ours, so both sides can reach it.

(defpackage #:dsmr-mcp/src/template-render
  (:use #:cl)
  (:import-from #:cl-ppcre
                #:regex-replace-all)
  (:export #:render-template))

(in-package #:dsmr-mcp/src/template-render)

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
