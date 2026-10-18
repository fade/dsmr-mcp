;;;; src/install.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Public entry point for the dsmr-mcp installer and the agent-target
;;;; dispatch. install resolves the requested agent to an IO function,
;;;; performs the config install, optionally copies the scaffold skill into
;;;; the operator's skills directory, and prints a concise summary.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-posix))

(defpackage #:dsmr-mcp/src/install
  (:use #:cl)
  (:import-from #:sb-posix)
  (:local-nicknames (#:jzon #:com.inuoe.jzon)
                    (#:config #:dsmr-mcp/src/install/config)
                    (#:claude #:dsmr-mcp/src/install/claude)
                    (#:defaults #:dsmr-mcp/src/install/defaults)
                    (#:hooks #:dsmr-mcp/src/install/hooks))
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

;;; Bus-watch binary source / destination -----------------------------------

(defparameter +bus-watch-name+ "dsmr-bus-watch"
  "Filename of the bus watcher command's static C front end, both as built in the
repo's bin/ and as installed on PATH. It runs a wake itself and every other mode
through the SBCL program named by +BUS-WATCH-LISP-NAME+ in its own directory.")

(defparameter +bus-watch-lisp-name+ "dsmr-bus-watch-lisp"
  "Filename of the bus watcher's SBCL program. It sits beside the front end, in
the repo's bin/ as built and on PATH as installed.")

(defun %bus-watch-source ()
  "Return the pathname of the built front end in the repo (bin/dsmr-bus-watch).
The SBCL program is expected beside it, as bin/dsmr-bus-watch-lisp."
  (merge-pathnames (format nil "bin/~A" +bus-watch-name+) (%repo-root)))

(defun default-bin-dir ()
  "Return the default operator bin directory, ~/.local/bin/."
  (merge-pathnames ".local/bin/" (user-homedir-pathname)))

(defun %place-binary (src bin-dir name)
  "Install the file SRC as BIN-DIR/NAME, mode 755, replacing any file there in
one rename.

Copy SRC to BIN-DIR/.NAME.tmp, set its mode, then rename it over the
destination, so a session that runs NAME meanwhile gets the old file or the
new one, never a partial copy. Return the destination pathname. When any step
fails, remove the temp file, write one line naming the destination and the
error to *ERROR-OUTPUT*, leave the destination as it was, and return NIL."
  (let* ((dir (uiop:ensure-directory-pathname bin-dir))
         (tmp (merge-pathnames (format nil ".~A.tmp" name) dir))
         (dest (merge-pathnames name dir)))
    (handler-case
        (progn
          (ensure-directories-exist dir)
          (uiop:copy-file src tmp)
          ;; sb-posix rather than chmod and mv children: a failed step signals,
          ;; and rename(2) fails on a directory at the destination where mv
          ;; would move the file into it.
          (sb-posix:chmod (uiop:native-namestring tmp) #o755)
          (sb-posix:rename (uiop:native-namestring tmp)
                           (uiop:native-namestring dest))
          dest)
      (error (e)
        (ignore-errors (delete-file tmp))
        (format *error-output* "~&dsmr-mcp install: could not install ~A: ~A~%"
                (uiop:native-namestring dest) e)
        nil))))

(defun %copy-binary (bin-dir &optional (src (%bus-watch-source)))
  "Install the built front end SRC and the SBCL program beside it into BIN-DIR,
so a sister repo can arm the watcher by bare command name.

SRC defaults to the repo's built front end and is overridable for testing; the
SBCL program is the file named +BUS-WATCH-LISP-NAME+ in SRC's directory. The
SBCL program is placed first and the front end second, each through
%PLACE-BINARY, because the front end runs the program for every mode but a
wake.

Return the front end's destination pathname, or NIL when nothing new reached
PATH:
- SRC is absent (`make bus-watch` has not been run); nothing is printed.
- The SBCL program is absent beside SRC; one line on *ERROR-OUTPUT* names it,
  and neither binary is installed.
- The SBCL program could not be placed; any existing front end is left as it
  was.
- The front end could not be placed, after the SBCL program was.
Never signals for these, which keeps install non-fatal."
  (unless (probe-file src)
    (return-from %copy-binary nil))
  (let ((lisp-src (merge-pathnames +bus-watch-lisp-name+
                                   (uiop:pathname-directory-pathname src))))
    (unless (probe-file lisp-src)
      (format *error-output*
              "~&dsmr-mcp install: ~A is missing, so neither watcher binary was ~
installed; run 'make bus-watch' to build both.~%"
              (uiop:native-namestring lisp-src))
      (return-from %copy-binary nil))
    (and (%place-binary lisp-src bin-dir +bus-watch-lisp-name+)
         (%place-binary src bin-dir +bus-watch-name+))))

;;; Print-mode renderer ------------------------------------------------------

(defun %print-snippet ()
  "Write the canonical dsmr-mcp server entry as a pretty JSON snippet to
*standard-output* for pasting into a non-Claude agent's MCP config. The
snippet is the object that belongs under the host's \"mcpServers\" map
keyed by \"dsmr-mcp\"."
  (let ((wrapper (make-hash-table :test 'equal)))
    (setf (gethash config:+dsmr-server-name+ wrapper)
          (config:canonical-server-entry config:+dsmr-server-name+
                                          :launcher (claude:launcher-if-present)))
    (format t "~&Add this entry under your agent's \"mcpServers\" map:~%~%~A~%"
            (jzon:stringify wrapper :pretty t))))

;;; Public entry -------------------------------------------------------------

(defun install (&key (agent :claude-code)
                     (on-existing-cl-mcp :keep)
                     (install-skill t)
                     (skills-dir nil)
                     (install-bus-watch t)
                     (bin-dir nil)
                     (install-hook t)
                     (project-root nil)
                     (lib-dir nil)
                     (hook-mode nil)
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

INSTALL-HOOK (default T) governs the SessionStart auto-arm hook step run after
the Claude Code install: when true the hook step runs under the same consent
posture as SITE-DEFAULTS (the SITE-DEFAULTS value is forwarded as the hook
step's mode), copying the adaptive arm script into LIB-DIR (default
~/.local/lib/dsmr-mcp/) and merging a SessionStart hook into PROJECT-ROOT's
.claude/settings.json so a fresh session in that project auto-arms the bus
watcher; when nil the hook step is skipped entirely (wired to --no-hook). Like
the defaults step, the hook step never runs under the :print agent — print mode
stays pure-stdout.

PROJECT-ROOT names the directory whose .claude/settings.json receives the hook.
It defaults to (uiop:getcwd) ONLY at this outermost boundary — callers that know
the intended target (e.g. scripts/install.lisp's --project flag) should pass it
explicitly, because getcwd is the directory the installer was launched from, not
necessarily the project to instrument. The resolved target is reported under
:hook-project-root and printed in the summary so the operator can confirm it.

HOOK-MODE, when non-NIL, overrides the hook step's consent mode independently of
SITE-DEFAULTS (which it otherwise inherits). :force installs the hook without
prompting — for a non-interactive opt-in given out of band, and for tests that
drive the positive write end-to-end.

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
            (bus-watch-dest (when install-bus-watch
                              (%copy-binary (or bin-dir (default-bin-dir)))))
            (envrc-template (defaults:install-envrc-defaults :mode site-defaults))
            ;; Resolve the hook target explicitly at this outermost boundary.
            ;; install-hooks would otherwise default to (uiop:getcwd), which for
            ;; an `sbcl --script scripts/install.lisp` run is wherever the
            ;; operator stood when they ran the installer — not necessarily the
            ;; project they mean to instrument. Resolve it here and carry it so
            ;; the summary can name the directory the hook was written into.
            (hook-target (uiop:ensure-directory-pathname
                          (or project-root (uiop:getcwd))))
            ;; The hook step's consent mode defaults to SITE-DEFAULTS (so a
            ;; single consent posture covers both steps), but HOOK-MODE can
            ;; override it independently — e.g. :force for a non-interactive
            ;; opt-in already given out of band, or for a test that drives the
            ;; positive write end-to-end without a tty.
            (hook-result (when install-hook
                           (hooks:install-hooks
                            :project-root hook-target
                            :lib-dir (or lib-dir (hooks:default-lib-dir))
                            :mode (or hook-mode site-defaults))))
            (full (append result (list :skill-dir skill-dest
                                       :bus-watch-path bus-watch-dest
                                       :envrc-template-dir envrc-template
                                       :hook-project-root hook-target
                                       :hook-result hook-result))))
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
  ;; The front end and the SBCL program it runs are installed as a pair.
  (let ((b (getf result :bus-watch-path)))
    (if b
        (format t "  bus-watch:    ~A (front end)~%                ~A (SBCL program)~%"
                (namestring b)
                (namestring (merge-pathnames +bus-watch-lisp-name+
                                             (uiop:pathname-directory-pathname b))))
        (format t "  bus-watch:    (not installed - run 'make bus-watch' first)~%")))
  (format t "  envrc tmpl:   ~A~%"
          (let ((e (getf result :envrc-template-dir)))
            (if e (namestring e) "(site-wide defaults skipped)")))
  (format t "  hook:         ~A~%"
          (let* ((h (getf result :hook-result))
                 (path (getf (getf h :hook) :path)))
            (if path (namestring path) "(not installed)")))
  ;; Name the project the hook was written into, so the operator can confirm it
  ;; landed in the intended tree rather than an unrelated CWD. Printed whenever a
  ;; hook target was resolved, even if the step itself declined/skipped.
  (let ((root (getf result :hook-project-root)))
    (when root
      (format t "  hook project: ~A~%" (namestring root))))
  ;; Report the settings.json backup when the hook step overwrote an existing
  ;; file, mirroring the claude-config backup line above.
  (let ((b (getf (getf (getf result :hook-result) :hook) :backup-path)))
    (when b
      (format t "  hook backup:  ~A~%" (namestring b))))
  (format t "~%Restart Claude Code (or reconnect MCP servers) to pick up ~
the dsmr-mcp entry.~%"))
