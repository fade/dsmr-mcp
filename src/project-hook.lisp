;;;; src/project-hook.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Wiring the lint gate into git through configured hooks.
;;;;
;;;; The gate is registered as two local config entries, hook.lisp-gate.event
;;;; and hook.lisp-gate.command, so git runs it beside whatever pre-commit hook
;;;; the repository already has. No file under the hooks directory is edited,
;;;; renamed or replaced: on this host every git init and git clone seeds a
;;;; pre-commit hook from the init template, and that hook belongs to whoever
;;;; installed it. Removing the wiring is one git config --unset per entry.

(defpackage #:dsmr-mcp/src/project-hook
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/git
                #:run-git)
  (:export #:+gate-hook-name+
           #:gate-hook-command
           #:gate-hook-path
           #:configured-hooks-supported-p
           #:gate-hook-wired-p
           #:wire-gate-hook))

(in-package #:dsmr-mcp/src/project-hook)

(defvar +gate-hook-name+ "lisp-gate"
  "The friendly name the gate is registered under in git's configured hooks.")

(defvar +hook-event+ "pre-commit"
  "The git event the gate runs at.")

(defvar +no-hooks-warning+ "no hooks found for event"
  "What git hook list prints, exiting 1, when an event has no hook at all.")

(defun gate-hook-command ()
  "Return the shell command git runs for the gate.
Resolves the git directory when the hook runs, so the entry survives the
repository being moved and points into a linked worktree's own git directory."
  "\"$(git rev-parse --absolute-git-dir)/hooks/lisp-gate\"")

(defun %config-key (field)
  "Return the config key for FIELD of the gate's configured hook."
  (format nil "hook.~A.~A" +gate-hook-name+ field))

(defun %trimmed (string)
  "Return STRING without surrounding whitespace."
  (string-trim '(#\Space #\Tab #\Newline #\Return) string))

(defun %lines (string)
  "Return the non-empty lines of STRING."
  (remove "" (uiop:split-string string :separator '(#\Newline))
          :test #'string=))

(defun gate-hook-path (root)
  "Return the absolute pathname the gate is installed at for the repository at ROOT.
The git directory comes from git rev-parse --absolute-git-dir, so a linked
worktree or a separate git directory resolves to its own hooks directory.
Signals GIT-COMMAND-ERROR when ROOT is not in a repository."
  (merge-pathnames
   "hooks/lisp-gate"
   (uiop:ensure-directory-pathname
    (%trimmed (run-git (list "rev-parse" "--absolute-git-dir")
                       :directory root)))))

(defun %local-config-path (root)
  "Return the absolute path of the local config file of the repository at ROOT."
  (merge-pathnames
   "config"
   (uiop:ensure-directory-pathname
    (%trimmed (run-git (list "rev-parse" "--path-format=absolute"
                             "--git-common-dir")
                       :directory root)))))

(defun %hook-list (root)
  "Run git hook list for the gate's event at ROOT.
Returns the output lines, the exit code and standard error."
  (multiple-value-bind (stdout stderr code)
      (run-git (list "hook" "list" +hook-event+)
               :directory root :error-on-failure nil)
    (values (%lines stdout) code stderr)))

(defun configured-hooks-supported-p (root)
  "Return true when git at ROOT can run configured hooks.
True when git hook list exits 0, or exits 1 with its no-hooks warning; any
other result means this git has no configured hooks."
  (multiple-value-bind (lines code stderr) (%hook-list root)
    (declare (ignore lines))
    (or (eql code 0)
        (and (eql code 1) (search +no-hooks-warning+ stderr) t))))

(defun %config-values (root field)
  "Return every local value of FIELD of the gate's configured hook at ROOT."
  (multiple-value-bind (stdout stderr code)
      (run-git (list "config" "--local" "--get-all" (%config-key field))
               :directory root :error-on-failure nil)
    (declare (ignore stderr))
    ;; Exit 1 means the key is unset; anything else is a config read failure.
    (case code
      (0 (mapcar #'%trimmed (%lines stdout)))
      (1 '())
      (t (error "git config could not read ~A at ~A (exit ~A)"
                (%config-key field) root code)))))

(defun gate-hook-wired-p (root)
  "Return true when the gate is wired at ROOT.
True only when git hook list names the gate enabled (a disabled hook is listed
with a disabled prefix) and the local command entry equals GATE-HOOK-COMMAND."
  (multiple-value-bind (lines code) (%hook-list root)
    (and (eql code 0)
         (member +gate-hook-name+ lines :test #'string=)
         (equal (list (gate-hook-command)) (%config-values root "command"))
         t)))

(defun %conflict (root)
  "Return why an existing gate entry at ROOT stops wiring, or NIL when none does."
  (let ((commands (%config-values root "command"))
        (events (%config-values root "event"))
        (enabled (%config-values root "enabled")))
    (cond
      ((and commands (not (equal commands (list (gate-hook-command)))))
       (format nil "~A is already set to ~S" (%config-key "command") commands))
      ((and events (not (member +hook-event+ events :test #'string=)))
       (format nil "~A is already set to ~S" (%config-key "event") events))
      ((and enabled
            (notevery (lambda (value)
                        (member value '("true" "yes" "on" "1")
                                :test #'string-equal))
                      enabled))
       (format nil "~A is set to ~S" (%config-key "enabled") enabled)))))

(defun wire-gate-hook (root &key dry-run)
  "Register the gate as a configured pre-commit hook of the repository at ROOT.

Writes only with git config --local: hook.lisp-gate.event and
hook.lisp-gate.command. Never edits a file under the hooks directory and never
replaces an existing hook.lisp-gate value that differs from what it would
write. DRY-RUN writes nothing.

Returns (:path P :action-taken A :reason R), where P is the local config file
and A is one of:
  :created          the entries were written and the gate now reads as wired.
  :already-present  the gate was already wired; nothing was written.
  :would-create     DRY-RUN, and the entries would be written.
  :not-wired        nothing was written; R says why.
Signals an error when the entries were written and the gate still does not
read as wired."
  (let ((path (%local-config-path root)))
    (flet ((report (action &optional reason)
             (list :path path :action-taken action :reason reason)))
      (let ((conflict (%conflict root)))
        (cond
          ((not (configured-hooks-supported-p root))
           (report :not-wired "this git cannot run configured hooks"))
          (conflict (report :not-wired conflict))
          ((gate-hook-wired-p root) (report :already-present))
          (dry-run (report :would-create))
          (t
           (unless (member +hook-event+ (%config-values root "event")
                           :test #'string=)
             (run-git (list "config" "--local" "--add" (%config-key "event")
                            +hook-event+)
                      :directory root))
           (unless (%config-values root "command")
             (run-git (list "config" "--local" (%config-key "command")
                            (gate-hook-command))
                      :directory root))
           (unless (gate-hook-wired-p root)
             (error "wrote the ~A hook entries at ~A but git does not list it"
                    +gate-hook-name+ root))
           (report :created)))))))
