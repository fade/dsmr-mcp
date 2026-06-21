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
  (if (and (plusp (length path)) (char= (char path 0) #\~))
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
      (site-defaults :interactive))
  (dolist (arg (uiop:command-line-arguments))
    (cond ((string= arg "--keep")     (setf on-existing :keep))
          ((string= arg "--migrate")  (setf on-existing :remove))
          ((string= arg "--replace")  (setf on-existing :replace))
          ((string= arg "--print")    (setf agent :print))
          ((string= arg "--no-skill") (setf install-skill nil))
          ((string= arg "--no-envrc-defaults") (setf site-defaults :skip))
          ((string= arg "--no-hook") (setf install-hook nil))
          ((or (string= arg "-h") (string= arg "--help"))
           (format t "~&Usage: sbcl --script scripts/install.lisp ~
[--keep|--migrate|--replace] [--print] [--no-skill] [--no-envrc-defaults] ~
[--no-hook]~%")
           (uiop:quit 0))
          (t
           (format *error-output* "~&[install] unknown flag: ~A~%" arg)
           (uiop:quit 2))))

  ;; Load the project (compilation chatter to stderr so --print stdout stays
  ;; clean JSON).
  (let ((*standard-output* *error-output*))
    (asdf:load-system :dsmr-mcp))

  (funcall (read-from-string "dsmr-mcp/src/install:install")
           :agent agent
           :on-existing-cl-mcp on-existing
           :install-skill install-skill
           :install-hook install-hook
           :site-defaults site-defaults))
