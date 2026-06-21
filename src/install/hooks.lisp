;;;; src/install/hooks.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Installer module that arms the bus wakeup watcher automatically at agent
;;;; bringup. It writes a Claude Code SessionStart hook into a project's
;;;; .claude/settings.json so a fresh session launches the watcher with no
;;;; manual step, and it installs the adaptive launch script the hook calls.
;;;;
;;;; The file splits the same way config/claude split: a pure transform
;;;; (ensure-hook-entry) that is unit-testable on in-memory hash-tables, and an
;;;; IO entry (install-hooks) that copies the arm script, reads the target
;;;; settings file, applies the transform, re-validates the rendered JSON by
;;;; re-parsing, and writes it back atomically. The settings.json write has no
;;;; backup step: the project file is low-stakes and the merge is additive only.

(defpackage #:dsmr-mcp/src/install/hooks
  (:use #:cl)
  (:local-nicknames (#:jzon #:com.inuoe.jzon))
  (:import-from #:dsmr-mcp/src/fs
                #:write-file-string-atomically)
  (:export #:default-lib-dir
           #:arm-script-path
           #:hook-already-present-p
           #:ensure-hook-entry
           #:install-hooks))

(in-package #:dsmr-mcp/src/install/hooks)

;;; Hash-table helpers --------------------------------------------------------
;;; Duplicated from src/install/config.lisp (which does not export them). jzon
;;; emits and consumes equal-keyed string-keyed hash-tables, so every object
;;; that participates in the settings wire must use :test 'equal.

(defun %ht (&rest kvs)
  "Build an equal-keyed hash-table from alternating KEY VALUE pairs."
  (let ((ht (make-hash-table :test 'equal)))
    (loop for (k v) on kvs by #'cddr
          do (setf (gethash k ht) v))
    ht))

(defun %vec (&rest items)
  "Build a simple-vector from ITEMS so jzon encodes it as a JSON array."
  (coerce items 'simple-vector))

(defun %copy-ht (ht)
  "Return a fresh equal-keyed shallow copy of hash-table HT.
Top-level keys are copied; values are shared, so a transform mutates only the
copy and never the input."
  (let ((out (make-hash-table :test 'equal :size (max 1 (hash-table-count ht)))))
    (maphash (lambda (k v) (setf (gethash k out) v)) ht)
    out))

;;; Paths ---------------------------------------------------------------------

(defun default-lib-dir ()
  "Return the default operator lib directory for dsmr-mcp data files,
~/.local/lib/dsmr-mcp/ (parallel to default-bin-dir's ~/.local/bin/)."
  (merge-pathnames ".local/lib/dsmr-mcp/" (user-homedir-pathname)))

(defun arm-script-path (&optional (lib-dir (default-lib-dir)))
  "Return the absolute pathname of the installed arm script, LIB-DIR/bus-arm.sh.
The hook command string the transform writes is the namestring of this path —
an expanded absolute path (no ~), so idempotency reduces to exact string
equality on the command."
  (merge-pathnames "bus-arm.sh" (uiop:ensure-directory-pathname lib-dir)))

;;; Idempotency predicate -----------------------------------------------------

(defun hook-already-present-p (settings-ht command-string)
  "Return T when SETTINGS-HT carries a SessionStart entry whose inner hooks
array holds a command equal to COMMAND-STRING; NIL otherwise (including when
hooks / SessionStart are absent or SessionStart is empty). Nil-safe at every
level."
  (let* ((hooks-ht (and (hash-table-p settings-ht)
                        (gethash "hooks" settings-ht)))
         (ss (and (hash-table-p hooks-ht)
                  (gethash "SessionStart" hooks-ht))))
    (and (vectorp ss)
         (some (lambda (entry)
                 (and (hash-table-p entry)
                      (let ((inner (gethash "hooks" entry)))
                        (and (vectorp inner)
                             (some (lambda (h)
                                     (and (hash-table-p h)
                                          (equal (gethash "command" h)
                                                 command-string)))
                                   inner)))))
               ss)
         t)))

;;; Pure transform ------------------------------------------------------------

(defun ensure-hook-entry (config command-string)
  "Return a NEW settings object derived from parsed CONFIG with a SessionStart
hook whose command equals COMMAND-STRING ensured under hooks.SessionStart.
CONFIG is never mutated.

CONFIG may be a jzon hash-table or NIL; NIL yields a fresh minimal object.
Unrelated top-level keys are preserved verbatim, and any pre-existing
SessionStart entries are preserved — the new entry appends, never replaces.

Idempotent: applying it twice yields an object equal to applying it once,
because the append is gated on hook-already-present-p."
  (let* ((base (if (hash-table-p config)
                   (%copy-ht config)
                   (make-hash-table :test 'equal)))
         (existing-hooks (gethash "hooks" base))
         (hooks-ht (if (hash-table-p existing-hooks)
                       (%copy-ht existing-hooks)
                       (make-hash-table :test 'equal)))
         (existing-ss (gethash "SessionStart" hooks-ht))
         (ss (if (vectorp existing-ss) existing-ss #())))
    (unless (hook-already-present-p base command-string)
      (let ((new-entry (%ht "hooks"
                            (%vec (%ht "type" "command"
                                       "command" command-string)))))
        (setf (gethash "SessionStart" hooks-ht)
              (concatenate 'simple-vector ss (vector new-entry)))))
    (setf (gethash "hooks" base) hooks-ht)
    base))

;;; Arm-script source / copy --------------------------------------------------

(defun %repo-root ()
  "Return the dsmr-mcp source tree root, derived from this file's compiled
location (.../src/install/hooks.lisp -> repo root). Used to locate the arm
script source that ships in the repository."
  ;; *load-pathname* is .../src/install/hooks.lisp at load time; climb two
  ;; directories (out of src/install/) to reach the repo root.
  (let* ((here (or *load-pathname* *compile-file-pathname* (truename "."))))
    (uiop:pathname-parent-directory-pathname
     (uiop:pathname-parent-directory-pathname
      (uiop:pathname-directory-pathname here)))))

(defun %arm-script-source ()
  "Return the pathname of the arm script source in the repo
(scripts/bus-arm.sh)."
  (merge-pathnames "scripts/bus-arm.sh" (%repo-root)))

(defun %copy-arm-script (lib-dir &optional (src (%arm-script-source)))
  "Copy the arm script SRC into LIB-DIR/bus-arm.sh and mark it executable, so
the SessionStart hook can launch it by absolute path. Returns the destination
pathname, or NIL when SRC is absent — keeping install non-fatal. SRC defaults
to the repo's shipped script and is overridable for testing."
  (let ((dest (arm-script-path lib-dir)))
    (unless (probe-file src)
      (return-from %copy-arm-script nil))
    (ensure-directories-exist dest)
    (uiop:copy-file src dest)
    (uiop:run-program (list "chmod" "+x" (namestring dest)))
    dest))

;;; settings.json write -------------------------------------------------------

(defun %project-settings-path (project-root)
  "Return <project-root>/.claude/settings.json."
  (merge-pathnames ".claude/settings.json"
                   (uiop:ensure-directory-pathname project-root)))

(defun %write-project-hook (project-root command-string)
  "Merge a SessionStart hook for COMMAND-STRING into
<project-root>/.claude/settings.json, creating .claude/ and the file when
absent. Parses any existing file, applies ensure-hook-entry, re-validates the
rendered JSON by re-parsing (error -> abort, file untouched), then writes
atomically. No backup: the merge is additive and the project file is
low-stakes.

Returns a plist (:path PATH :action-taken {:created | :updated |
:already-present})."
  (let* ((path (%project-settings-path project-root))
         (existed (and (probe-file path) t))
         (original (when existed (jzon:parse (uiop:read-file-string path))))
         (already (and original (hook-already-present-p original command-string)))
         (updated (ensure-hook-entry original command-string))
         (rendered (jzon:stringify updated :pretty t)))
    (handler-case (jzon:parse rendered)
      (error (e)
        (error "install-hooks: rendered settings did not re-parse; leaving ~A ~
                untouched. (~A)" (namestring path) e)))
    (ensure-directories-exist path)
    (write-file-string-atomically path rendered)
    (list :path path
          :action-taken (cond ((not existed) :created)
                              (already :already-present)
                              (t :updated)))))

;;; Gated installer entry -----------------------------------------------------

(defun %do-install-hooks (project-root lib-dir)
  "Do the actual install work, deterministically and without prompting: copy
the arm script into LIB-DIR, then merge the SessionStart hook into
PROJECT-ROOT's .claude/settings.json keyed on the installed script's absolute
path. Returns a plist (:script-path ... :script-installed BOOL :hook ...)."
  (let* ((script-dest (%copy-arm-script lib-dir))
         (command (namestring (arm-script-path lib-dir)))
         (hook-result (%write-project-hook project-root command)))
    (list :script-path script-dest
          :script-installed (and script-dest t)
          :hook hook-result)))

(defun install-hooks (&key (project-root (uiop:getcwd))
                           (lib-dir (default-lib-dir))
                           (mode :interactive))
  "Installer entry for the SessionStart auto-arm hook.

MODE selects behavior:
  :skip         no-op; return NIL. (Used by tests and by --no-hook.)
  :interactive  when stdin is interactive, prompt for consent and, on a yes,
                install the arm script + merge the project hook; when stdin is
                NOT interactive (piped / CI), return NIL without prompting so
                an automated install never blocks on a read.

PROJECT-ROOT is the directory whose .claude/settings.json receives the hook
(default the current directory). LIB-DIR is where the arm script is installed
(default ~/.local/lib/dsmr-mcp/).

Returns the result plist from %do-install-hooks, or NIL when skipped/declined."
  (ecase mode
    (:skip nil)
    (:interactive
     (when (interactive-stream-p *standard-input*)
       (format *standard-output*
               "~&Install a SessionStart hook that auto-arms the bus watcher ~
                at startup? [y/N] ")
       (finish-output *standard-output*)
       (let ((line (read-line *standard-input* nil nil)))
         (when (and line
                    (let ((trimmed (string-trim '(#\Space #\Tab #\Return) line)))
                      (or (string-equal trimmed "y")
                          (string-equal trimmed "yes"))))
           (%do-install-hooks project-root lib-dir)))))))

