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

;;; install-hooks (IO entry) lives in Task 3.
