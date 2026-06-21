;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; scripts/install.lisp
;;;;
;;;; Runnable wrapper for the dsmr-mcp installer. Loads :dsmr-mcp and calls
;;;; dsmr-mcp/src/install:install with options parsed from the command line.
;;;;
;;;; Usage:
;;;;   sbcl --script scripts/install.lisp [FLAGS]
;;;;
;;;; Flags (all optional):
;;;;   --keep       coexist with any existing cl-mcp entry (default)
;;;;   --migrate    remove an existing cl-mcp entry, install dsmr-mcp
;;;;   --replace    replace an existing cl-mcp entry with dsmr-mcp
;;;;   --print      print the canonical JSON snippet to stdout instead of
;;;;                writing ~/.claude.json (for non-Claude agents)
;;;;   --no-skill   do not copy the scaffold skill into ~/.claude/skills/
;;;;   --no-envrc-defaults  skip the interactive site-wide .envrc defaults step
;;;;                (otherwise it runs after the install when stdin is a tty)
;;;;   --no-hook    skip the SessionStart auto-arm hook step (otherwise it
;;;;                runs after the install when stdin is a tty)
;;;;   --project DIR  the project whose .claude/settings.json receives the
;;;;                SessionStart hook (defaults to the installer's CWD, which is
;;;;                rarely the project to instrument — pass this to be explicit)
;;;;
;;;; --keep/--migrate/--replace are mutually exclusive; the last one wins.
;;;; Like scripts/dev-boot.lisp, this resolves the local-projects source
;;;; tree from LISP_WORKSPACE (defensively expanding a literal leading ~),
;;;; falling back to ~/SourceCode/lisp/, so :dsmr-mcp loads without a
;;;; pre-seeded source-registry.

(in-package #:cl-user)

(require :asdf)

;;; Prefer the Quicklisp dist's ASDF + dependency resolution. The bundled
;;; ASDF that ships with --script is older than the version dsmr-mcp
;;; requires, and Quicklisp is where the runtime dependencies (jzon,
;;; hunchentoot, cl-ppcre, …) resolve. Load setup.lisp when present; fall
;;; back to the bare image otherwise.
(let ((setup (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
  (when (probe-file setup)
    (let ((*standard-output* *error-output*))
      (load setup))))

(defun install-getenv (name default)
  (let ((v (uiop:getenv name)))
    (if (and v (plusp (length v))) v default)))

(defun expand-tilde (path)
  "Expand a leading ~/ to the home directory. Only the ~/ form is handled; a
bare ~ or a ~user form is left untouched (stripping two chars from ~user would
yield a wrong subseq, and from a bare ~ would overrun). LISP_WORKSPACE may carry
an unexpanded ~/, so this is a real input, not a hypothetical."
  (if (and (> (length path) 1)
           (char= (char path 0) #\~)
           (char= (char path 1) #\/))
      (namestring (merge-pathnames (subseq path 2) (user-homedir-pathname)))
      path))

(let* ((workspace (expand-tilde
                   (install-getenv "LISP_WORKSPACE"
                                   (namestring
                                    (merge-pathnames "SourceCode/lisp/"
                                                     (user-homedir-pathname))))))
       (workspace (uiop:ensure-directory-pathname workspace)))
  (pushnew workspace asdf:*central-registry* :test #'equal))

;;; Parse flags.
(let ((on-existing :keep)
      (agent :claude-code)
      (install-skill t)
      (install-hook t)
      (project-root nil)
      (site-defaults :interactive)
      (args (uiop:command-line-arguments)))
  (loop while args
        for arg = (pop args)
        do (cond ((string= arg "--keep")     (setf on-existing :keep))
                 ((string= arg "--migrate")  (setf on-existing :remove))
                 ((string= arg "--replace")  (setf on-existing :replace))
                 ((string= arg "--print")    (setf agent :print))
                 ((string= arg "--no-skill") (setf install-skill nil))
                 ((string= arg "--no-envrc-defaults") (setf site-defaults :skip))
                 ((string= arg "--no-hook") (setf install-hook nil))
                 ((string= arg "--project")
                  ;; The directory whose .claude/settings.json receives the
                  ;; SessionStart hook. Without this, the installer defaults the
                  ;; target to its own CWD — the directory the operator stood in,
                  ;; which is rarely the project they mean to instrument.
                  (let ((dir (pop args)))
                    (unless dir
                      (format *error-output* "~&[install] --project requires a DIR argument~%")
                      (uiop:quit 2))
                    (setf project-root
                          (uiop:ensure-directory-pathname
                           (uiop:truenamize (expand-tilde dir))))))
                 ((or (string= arg "-h") (string= arg "--help"))
                  (format t "~&Usage: sbcl --script scripts/install.lisp ~
[--keep|--migrate|--replace] [--print] [--no-skill] [--no-envrc-defaults] ~
[--no-hook] [--project DIR]~%")
                  (uiop:quit 0))
                 (t
                  (format *error-output* "~&[install] unknown flag: ~A~%" arg)
                  (uiop:quit 2))))

  ;; Load the project (compilation chatter to stderr so --print stdout stays
  ;; clean JSON).
  (let ((*standard-output* *error-output*))
    (asdf:load-system :dsmr-mcp))

  (apply (read-from-string "dsmr-mcp/src/install:install")
         :agent agent
         :on-existing-cl-mcp on-existing
         :install-skill install-skill
         :install-hook install-hook
         :site-defaults site-defaults
         ;; Only forward an explicit --project; otherwise let install default it
         ;; (to getcwd) at its own boundary.
         (when project-root (list :project-root project-root))))
