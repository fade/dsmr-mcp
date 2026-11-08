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
                #:run-git
                #:git-common-dir)
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

(defun gate-hook-command (&optional (profile :foreign))
  "Return the shell command git runs for the gate rendered for PROFILE.

The script is found through the git directory every worktree shares, resolved
when the hook runs, so one wiring serves every worktree and survives the
repository being moved. When no executable script is there, the command prints
one line and exits:
  :FOREIGN  0, so the commit proceeds; the gate never refuses there.
  :OURS     1, so the commit is refused, as the blocking gate does whenever it
            cannot lint.
Any other PROFILE signals an error."
  (format nil "f=\"$(git rev-parse --path-format=absolute --git-common-dir)/hooks/~A\"; [ -x \"$f\" ] && exec \"$f\"; ~A"
          +gate-hook-name+
          (ecase profile
            (:foreign "echo \"lisp-gate: no gate at $f; the commit proceeds without a lint check.\" >&2; exit 0")
            (:ours "echo \"lisp-gate: no gate at $f; commit refused. Bypass a single commit with: git commit --no-verify\" >&2; exit 1"))))

(defvar +superseded-gate-commands+
  '("\"$(git rev-parse --absolute-git-dir)/hooks/lisp-gate\"")
  "Commands an earlier wiring of the gate wrote. They resolve the per-worktree
git directory, so they fail in every worktree but the one that installed the
gate; WIRE-GATE-HOOK replaces them.")

(defun %own-command-p (command)
  "Return true when COMMAND is a gate command this module writes or once wrote."
  (and (or (member command +superseded-gate-commands+ :test #'string=)
           (string= command (gate-hook-command :foreign))
           (string= command (gate-hook-command :ours)))
       t))

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
The script lives in the git directory every worktree shares, the one
GATE-HOOK-COMMAND looks in, so it is the same file from every worktree.
Signals GIT-COMMAND-ERROR when ROOT is not in a repository."
  (merge-pathnames (format nil "hooks/~A" +gate-hook-name+)
                   (git-common-dir root)))

(defun %local-config-path (root)
  "Return the absolute path of the local config file of the repository at ROOT."
  (merge-pathnames "config" (git-common-dir root)))

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

(defun gate-hook-wired-p (root &key profile)
  "Return true when the gate is wired at ROOT.
True only when git hook list names the gate enabled (a disabled hook is listed
with a disabled prefix) and the local command entry is GATE-HOOK-COMMAND for
PROFILE. With PROFILE NIL, the command for either profile counts."
  (multiple-value-bind (lines code) (%hook-list root)
    (let ((commands (%config-values root "command")))
      (and (eql code 0)
           (member +gate-hook-name+ lines :test #'string=)
           (= 1 (length commands))
           (if profile
               (string= (first commands) (gate-hook-command profile))
               (or (string= (first commands) (gate-hook-command :foreign))
                   (string= (first commands) (gate-hook-command :ours))))
           t))))

(defun %conflict (root)
  "Return why an existing gate entry at ROOT stops wiring, or NIL when none does.
A command entry this module wrote, for either profile or in an earlier form, is
not a conflict: WIRE-GATE-HOOK replaces it."
  (let ((commands (%config-values root "command"))
        (events (%config-values root "event"))
        (enabled (%config-values root "enabled")))
    (cond
      ((and commands
            (not (and (= 1 (length commands))
                      (%own-command-p (first commands)))))
       (format nil "~A is already set to ~S" (%config-key "command") commands))
      ((and events (not (member +hook-event+ events :test #'string=)))
       (format nil "~A is already set to ~S" (%config-key "event") events))
      ((and enabled
            (notevery (lambda (value)
                        (member value '("true" "yes" "on" "1")
                                :test #'string-equal))
                      enabled))
       (format nil "~A is set to ~S" (%config-key "enabled") enabled)))))

(defun wire-gate-hook (root &key dry-run (profile :foreign))
  "Register the gate as a configured pre-commit hook of the repository at ROOT.

Writes only with git config --local: hook.lisp-gate.event and
hook.lisp-gate.command, the latter set to GATE-HOOK-COMMAND for PROFILE. Never
edits a file under the hooks directory. A command entry this module wrote, for
the other profile or in an earlier form, is replaced; any other existing
hook.lisp-gate value that differs from what it would write is left alone.
DRY-RUN writes nothing.

Returns (:path P :action-taken A :reason R), where P is the local config file
and A is one of:
  :created          the entries were written and the gate now reads as wired.
  :replaced         a command entry of ours was rewritten for PROFILE.
  :already-present  the gate was already wired; nothing was written.
  :would-create     DRY-RUN, and the entries would be written.
  :would-replace    DRY-RUN, and a command entry of ours would be rewritten.
  :not-wired        nothing was written; R says why.
Signals an error when the entries were written and the gate still does not
read as wired."
  (let ((path (%local-config-path root))
        (command (gate-hook-command profile)))
    (flet ((report (action &optional reason)
             (list :path path :action-taken action :reason reason)))
      (let ((conflict (%conflict root))
            (existing (%config-values root "command")))
        (cond
          ((not (configured-hooks-supported-p root))
           (report :not-wired "this git cannot run configured hooks"))
          (conflict (report :not-wired conflict))
          ((gate-hook-wired-p root :profile profile) (report :already-present))
          (dry-run (report (if existing :would-replace :would-create)))
          (t
           (unless (member +hook-event+ (%config-values root "event")
                           :test #'string=)
             (run-git (list "config" "--local" "--add" (%config-key "event")
                            +hook-event+)
                      :directory root))
           (unless (equal existing (list command))
             (run-git (list "config" "--local" "--replace-all"
                            (%config-key "command") command)
                      :directory root))
           (unless (gate-hook-wired-p root :profile profile)
             (error "wrote the ~A hook entries at ~A but git does not list it"
                    +gate-hook-name+ root))
           (report (if (and existing (not (equal existing (list command))))
                       :replaced
                       :created))))))))
