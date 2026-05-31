;;;; src/install.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Public entry point for the dsmr-mcp installer and the agent-target
;;;; dispatch. install resolves the requested agent to an IO function,
;;;; performs the config install, optionally copies the scaffold skill into
;;;; the operator's skills directory, and prints a concise summary.

(defpackage #:dsmr-mcp/src/install
  (:use #:cl)
  (:local-nicknames (#:jzon #:com.inuoe.jzon)
                    (#:config #:dsmr-mcp/src/install/config)
                    (#:claude #:dsmr-mcp/src/install/claude)
                    (#:defaults #:dsmr-mcp/src/install/defaults))
  (:export #:install))

(in-package #:dsmr-mcp/src/install)

;;; Skill source / destination ----------------------------------------------

(defun %repo-root ()
  "Return the dsmr-mcp source tree root, derived from this file's compiled
location (.../src/install.lisp -> repo root). Used to locate the scaffold
skill source that ships in the repository."
  ;; *load-pathname* is .../src/install.lisp at load time; climb one
  ;; directory (out of src/) to reach the repo root.
  (let* ((here (or *load-pathname* *compile-file-pathname*
                   (truename "."))))
    (uiop:pathname-parent-directory-pathname
     (uiop:pathname-directory-pathname here))))

(defparameter +skill-name+ "scaffold-project"
  "Directory name of the scaffold skill, both in the repo and under the
operator's skills directory.")

(defun %skill-source-dir ()
  "Return the pathname of the scaffold skill source directory in the repo
(skills/scaffold-project/)."
  (merge-pathnames (format nil "skills/~A/" +skill-name+) (%repo-root)))

(defun default-skills-dir ()
  "Return the default operator skills directory, ~/.claude/skills/."
  (merge-pathnames ".claude/skills/" (user-homedir-pathname)))

(defun %copy-skill (skills-dir)
  "Copy the scaffold skill from the repo into SKILLS-DIR/scaffold-project/,
creating directories as needed. Returns the destination directory pathname,
or NIL when the skill source is not present in the repo."
  (let* ((src (%skill-source-dir))
         (dest (merge-pathnames (format nil "~A/" +skill-name+)
                                (uiop:ensure-directory-pathname skills-dir))))
    (unless (uiop:directory-exists-p src)
      (return-from %copy-skill nil))
    (ensure-directories-exist dest)
    (dolist (file (uiop:directory-files src))
      (uiop:copy-file file (merge-pathnames (file-namestring file) dest)))
    dest))

;;; Print-mode renderer ------------------------------------------------------

(defun %print-snippet ()
  "Write the canonical dsmr-mcp server entry as a pretty JSON snippet to
*standard-output* for pasting into a non-Claude agent's MCP config. The
snippet is the object that belongs under the host's \"mcpServers\" map
keyed by \"dsmr-mcp\"."
  (let ((wrapper (make-hash-table :test 'equal)))
    (setf (gethash config:+dsmr-server-name+ wrapper)
          (config:canonical-server-entry))
    (format t "~&Add this entry under your agent's \"mcpServers\" map:~%~%~A~%"
            (jzon:stringify wrapper :pretty t))))

;;; Public entry -------------------------------------------------------------

(defun install (&key (agent :claude-code)
                     (on-existing-cl-mcp :keep)
                     (install-skill t)
                     (skills-dir nil)
                     (site-defaults :interactive))
  "Install dsmr-mcp as an MCP server for the requested AGENT and report
what was done.

AGENT selects the install target:
  :claude-code  (default) write the canonical dsmr-mcp entry into
                ~/.claude.json (backed up first), and -- when INSTALL-SKILL
                is true -- copy the scaffold skill into SKILLS-DIR (default
                ~/.claude/skills/scaffold-project/).
  :print        write the canonical JSON snippet to *standard-output* for
                any other agent / MCP client to paste into its own config.
                This is the documented extension point for agents whose
                config format we cannot verify.

ON-EXISTING-CL-MCP (:keep, :remove, :replace) governs an existing cl-mcp
entry under Claude Code; see dsmr-mcp/src/install/config:ensure-server.

SITE-DEFAULTS (:interactive, :skip) governs the site-wide `.envrc` defaults
step run after the Claude Code install: :interactive prompts for the
operator's Slynk host/port/workspace defaults and writes them to
~/.config/dsmr-mcp/envrc.template (skipped automatically when stdin is not
interactive); :skip suppresses the step entirely. The step never runs under
the :print agent — print mode stays pure-stdout.

To extend this installer to a new agent, add a new AGENT keyword here and
a corresponding IO function (mirroring dsmr-mcp/src/install/claude) that
reads, transforms via the config core, and writes that agent's config
format. Keep the config transform in the pure core so it stays testable.

Returns the IO result plist for :claude-code (see install-into-claude,
augmented with :skill-dir), or NIL for :print."
  (check-type agent (member :claude-code :print))
  (ecase agent
    (:print
     (%print-snippet)
     nil)
    (:claude-code
     (let* ((result (claude:install-into-claude
                     :on-existing-cl-mcp on-existing-cl-mcp))
            (skill-dest (when install-skill
                          (%copy-skill (or skills-dir (default-skills-dir)))))
            (envrc-template (defaults:install-envrc-defaults :mode site-defaults))
            (full (append result (list :skill-dir skill-dest
                                       :envrc-template-dir envrc-template))))
       (%print-claude-summary full)
       full))))

(defun %print-claude-summary (result)
  "Print a concise human-readable summary of a :claude-code install RESULT."
  (format t "~&dsmr-mcp installed for Claude Code.~%")
  (format t "  config:       ~A~%" (namestring (getf result :path)))
  (format t "  backup:       ~A~%"
          (let ((b (getf result :backup-path)))
            (if b (namestring b) "(none — config created fresh)")))
  (format t "  cl-mcp found: ~A~%" (if (getf result :cl-mcp-was-present) "yes" "no"))
  (format t "  action:       ~A~%" (getf result :action-taken))
  (format t "  skill:        ~A~%"
          (let ((s (getf result :skill-dir)))
            (if s (namestring s) "(not installed)")))
  (format t "  envrc tmpl:   ~A~%"
          (let ((e (getf result :envrc-template-dir)))
            (if e (namestring e) "(site-wide defaults skipped)")))
  (format t "~%Restart Claude Code (or reconnect MCP servers) to pick up ~
the dsmr-mcp entry.~%"))
