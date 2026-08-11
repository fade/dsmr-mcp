;;;; tests/envrc-template/envrc-template-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Lookup tests for the site-wide-preferring .envrc template resolution
;;;; (ENVRC-04): envrc-template-path falls back to the shipped repo template
;;;; when no site-wide file exists, and prefers a per-machine template under
;;;; XDG_CONFIG_HOME when one is present. The site-wide probe is driven by a
;;;; temporary XDG_CONFIG_HOME that is set then restored around the assertion
;;;; so no env-var state leaks across tests.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/envrc-template/envrc-template-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/envrc-template/envrc-template-test
  (:use #:cl #:zebra)
  (:import-from #:dsmr-mcp/src/envrc-template
                #:envrc-template-path
                #:read-envrc-template)
  (:import-from #:dsmr-mcp/src/install/defaults
                #:render-site-defaults-template)
  (:import-from #:dsmr-mcp/src/envrc-vars
                #:managed-block
                #:managed-variables
                #:variable-name))

(in-package #:dsmr-mcp/tests/envrc-template/envrc-template-test)

(defmacro with-xdg-config-home ((dir) &body body)
  "Bind the XDG_CONFIG_HOME environment variable to DIR (a namestring) for the
dynamic extent of BODY, restoring its prior value (or unset state) on exit."
  (let ((prior (gensym "PRIOR")) (had (gensym "HAD")))
    `(let* ((,prior (uiop:getenv "XDG_CONFIG_HOME"))
            (,had ,prior))
       (unwind-protect
            (progn
              (sb-posix:setenv "XDG_CONFIG_HOME" ,dir 1)
              ,@body)
         (if ,had
             (sb-posix:setenv "XDG_CONFIG_HOME" ,prior 1)
             (sb-posix:unsetenv "XDG_CONFIG_HOME"))))))

(defun %unique-temp-dir (stem)
  "Create and return a fresh, unique temporary directory pathname named for STEM."
  (let ((dir (uiop:ensure-directory-pathname
              (merge-pathnames
               (format nil "~A-~A/" stem (random (expt 2 48)))
               (uiop:temporary-directory)))))
    (ensure-directories-exist dir)
    dir))

(define-test template-path-falls-back-to-shipped
  "With no site-wide template present, envrc-template-path resolves to the
repo's shipped templates/dsmr-mcp.envrc.template."
  (let ((empty (%unique-temp-dir "dsmr-envrc-empty")))
    (unwind-protect
         (with-xdg-config-home ((namestring empty))
           (let ((resolved (envrc-template-path)))
             (is equal "dsmr-mcp.envrc.template" (file-namestring resolved))
             (is equal "templates"
                 (car (last (pathname-directory resolved)))
                 "fallback path is not under templates/")))
      (ignore-errors (uiop:delete-directory-tree empty :validate t)))))

(define-test template-path-prefers-site-wide
  "When ~/.config/dsmr-mcp/envrc.template exists under XDG_CONFIG_HOME,
envrc-template-path returns it instead of the shipped default."
  (let* ((root (%unique-temp-dir "dsmr-envrc-site"))
         (site (merge-pathnames "dsmr-mcp/envrc.template" root)))
    (ensure-directories-exist site)
    (with-open-file (out site :direction :output :if-exists :supersede)
      (write-string "export DSMR_MODE=auto # site-wide marker" out))
    (unwind-protect
         (with-xdg-config-home ((namestring root))
           (let ((resolved (envrc-template-path)))
             (is equal (truename site) (truename resolved)
                 "envrc-template-path did not prefer the site-wide template")
             (true (search "site-wide marker" (read-envrc-template))
                   "read-envrc-template did not read the site-wide file")))
      (ignore-errors (uiop:delete-directory-tree root :validate t)))))

(defun %shipped-template ()
  "Return the contents of the repository's shipped `.envrc` template.
Read through ASDF:SYSTEM-RELATIVE-PATHNAME rather than ENVRC-TEMPLATE-PATH so
the assertion is about the file this repository ships, not about whichever file
the running machine happens to prefer."
  (uiop:read-file-string
   (asdf:system-relative-pathname "dsmr-mcp"
                                  "templates/dsmr-mcp.envrc.template")))

(defparameter +lockstep-note+
  "templates/dsmr-mcp.envrc.template and render-site-defaults-template in
src/install/defaults.lisp are two hand-kept copies of one text, held in lockstep
on purpose: the shipped file is what a new project's .envrc is copied from, the
renderer is what personalizes it at install time. Change BOTH, and declare the
same variable in the table in src/envrc-vars.lisp."
  "The remedy every assertion in this section points a reader at. Naming the
files is the whole value of the guard: the failure is otherwise a wall of shell
text with no indication of which copy is behind.")

(defun %declared-names (text)
  "Return the shell variable names TEXT declares, in the order they appear.
Comment lines declare nothing, so the commented DSMR_RELATED_PROJECTS example
and the managed-region markers are skipped rather than counted."
  (loop for raw in (uiop:split-string text :separator (list #\Newline))
        for line = (string-trim '(#\Space #\Tab #\Return) raw)
        when (and (> (length line) 7)
                  (string= "export " line :end2 7))
          collect (let* ((rest (subseq line 7))
                         (eq-pos (position #\= rest)))
                    (if eq-pos (subseq rest 0 eq-pos) rest))))

(define-test shipped-template-matches-the-site-defaults-renderer
  "render-site-defaults-template called with the shipped defaults is byte-equal
to templates/dsmr-mcp.envrc.template. The renderer's docstring used to merely
claim that shape match; a line added to one file alone now fails here rather
than reaching a repository half-applied."
  (is string= (%shipped-template) (render-site-defaults-template)
      (format nil "the shipped template and the site-defaults renderer have ~
drifted apart.~%~A" +lockstep-note+)))

(define-test template-declares-the-managed-variables-in-order
  "The shipped template declares exactly the variables the managed block
declares, in the same order, sourced from the variable table. A fourth variable
added to the table without touching the template fails here rather than in a
repository."
  (let ((from-table (mapcar #'variable-name (managed-variables))))
    (is equal from-table (%declared-names (managed-block))
        "the managed block is not the variable table in table order")
    (is equal from-table (%declared-names (%shipped-template))
        (format nil "the shipped template does not declare the managed ~
variables in table order.~%~A" +lockstep-note+))
    (is equal from-table (%declared-names (render-site-defaults-template))
        (format nil "the site-defaults renderer does not declare the managed ~
variables in table order.~%~A" +lockstep-note+))))

(define-test template-declares-the-bus-selector-exactly-once
  "The shipped template carries the fleet selector: mentioned in the explanatory
comment and declared exactly once, with an empty default. Two declarations would
leave a repository whose later line silently wins over the earlier one, and a
non-empty default would move every repository onto a named bus merely by
shipping the stanza."
  (let ((shipped (%shipped-template)))
    (is = 1 (count "DSMR_BUS_SELECTOR" (%declared-names shipped)
                   :test #'string=)
        "the selector must be declared exactly once")
    (true (search "export DSMR_BUS_SELECTOR=\"${DSMR_BUS_SELECTOR:-}\"" shipped)
          "the selector's default must be empty, which resolves to the shared
host-wide bus, so distributing this stanza moves nobody onto a named bus")))
