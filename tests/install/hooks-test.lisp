;;;; tests/install/hooks-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Parachute tests for the SessionStart auto-arm hook writer: the pure
;;;; settings.json transform (idempotency, no-clobber, presence predicate), the
;;;; arm-script copy (executable bit, graceful absent-source), the path helper,
;;;; and the project-settings write (create + re-parse + already-present). Every
;;;; path is a fresh temp dir, so the operator's real ~/.claude or ~/.local is
;;;; never touched.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/install/hooks-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/install/hooks-test
  (:use #:cl #:parachute)
  (:local-nicknames (#:jzon #:com.inuoe.jzon))
  (:import-from #:dsmr-mcp/src/install/hooks
                #:default-lib-dir
                #:arm-script-path
                #:hook-already-present-p
                #:ensure-hook-entry
                #:install-hooks
                #:%copy-arm-script
                #:%write-project-hook))

(in-package #:dsmr-mcp/tests/install/hooks-test)

;;; helpers -------------------------------------------------------------------

(defun %unique-temp-dir (stem)
  "Create and return a fresh, unique temporary directory pathname named for STEM.
SBCL's default *random-state* is deterministic across process invocations, so the
random suffix must be drawn from an entropy-seeded state minted at the call site —
otherwise the \"unique\" names repeat run-to-run and a leftover dir can leak into a
later run's absence assertions. Bind *random-state* before each random call."
  (let* ((*random-state* (make-random-state t))
         (dir (uiop:ensure-directory-pathname
               (merge-pathnames
                (format nil "~A-~A/" stem (random (expt 2 48)))
                (uiop:temporary-directory)))))
    (ensure-directories-exist dir)
    dir))

(defmacro with-temp-dir ((var stem) &body body)
  "Bind VAR to a fresh process-unique temp dir for the dynamic extent of BODY,
deleting it (and its contents) on exit so /tmp never accumulates leftovers that
could leak into a later run's absence assertions."
  `(let ((,var (%unique-temp-dir ,stem)))
     (unwind-protect (progn ,@body)
       (ignore-errors (uiop:delete-directory-tree
                       ,var :validate t :if-does-not-exist :ignore)))))

(defun %write-stub (path)
  "Write a tiny stub file at PATH and return it."
  (ensure-directories-exist path)
  (with-open-file (out path :direction :output :if-exists :supersede
                            :if-does-not-exist :create)
    (write-line "#!/bin/sh" out)
    (write-line "echo stub" out))
  path)

(defun %executable-p (path)
  "True if PATH has any execute bit set."
  (let ((mode (sb-posix:stat-mode (sb-posix:stat path))))
    (plusp (logand mode #o111))))

(defun ht (&rest kvs)
  "Local equal-keyed hash-table builder for in-memory transform tests."
  (let ((h (make-hash-table :test 'equal)))
    (loop for (k v) on kvs by #'cddr do (setf (gethash k h) v))
    h))

;;; pure-transform tests ------------------------------------------------------

(define-test ensure-hook-entry-from-nil-config
  (let* ((cmd (namestring (arm-script-path)))
         (out (ensure-hook-entry nil cmd))
         (hooks (gethash "hooks" out))
         (ss (gethash "SessionStart" hooks)))
    (true (hash-table-p out))
    (is = 1 (length ss))
    (is equal cmd
        (gethash "command" (aref (gethash "hooks" (aref ss 0)) 0)))))

(define-test ensure-hook-entry-idempotent
  (let* ((cmd "/abs/bus-arm.sh")
         (once (ensure-hook-entry nil cmd))
         (twice (ensure-hook-entry once cmd))
         (once-ss (gethash "SessionStart" (gethash "hooks" once)))
         (twice-ss (gethash "SessionStart" (gethash "hooks" twice))))
    (is = 1 (length once-ss))
    (is = 1 (length twice-ss))
    (is string= (jzon:stringify once) (jzon:stringify twice))))

(define-test ensure-hook-entry-no-clobber
  (let* ((cmd "/abs/bus-arm.sh")
         (pre-entry (ht "hooks" (vector (ht "type" "command"
                                            "command" "/other/thing.sh"))))
         (input (ht "model" "opus"
                    "hooks" (ht "SessionStart" (vector pre-entry))))
         (input-ss (gethash "SessionStart" (gethash "hooks" input)))
         (out (ensure-hook-entry input cmd))
         (out-ss (gethash "SessionStart" (gethash "hooks" out))))
    ;; input is never mutated
    (is = 1 (length input-ss))
    (is equal "opus" (gethash "model" input))
    ;; unrelated key survives; pre-existing entry preserved; length grows by 1
    (is equal "opus" (gethash "model" out))
    (is = 2 (length out-ss))
    (true (hook-already-present-p out "/other/thing.sh"))
    (true (hook-already-present-p out cmd))))

(define-test hook-already-present-p-present-and-absent
  (let* ((cmd "/abs/bus-arm.sh")
         (with (ensure-hook-entry nil cmd)))
    (true (hook-already-present-p with cmd))
    (false (hook-already-present-p with "/some/other.sh"))
    ;; nil-safe: no hooks / empty settings
    (false (hook-already-present-p nil cmd))
    (false (hook-already-present-p (ht) cmd))
    (false (hook-already-present-p (ht "hooks" (ht "SessionStart" #())) cmd))))

;;; arm-script copy tests -----------------------------------------------------

(define-test copy-arm-script-installs-executable
  (with-temp-dir (src-dir "hooks-arm-src")
    (with-temp-dir (lib-dir "hooks-arm-lib")
      (let* ((src (%write-stub (merge-pathnames "bus-arm.sh" src-dir)))
             (dest (%copy-arm-script lib-dir src)))
        (true dest)
        (is equal (arm-script-path lib-dir) dest)
        (true (probe-file dest))
        (true (%executable-p dest))))))

(define-test copy-arm-script-nil-when-source-absent
  (with-temp-dir (lib-dir "hooks-arm-lib")
    (with-temp-dir (missing-dir "hooks-arm-missing")
      (let ((missing (merge-pathnames "bus-arm.sh" missing-dir))
            (dest (arm-script-path lib-dir)))
        (ignore-errors (delete-file missing))
        (ignore-errors (delete-file dest))
        (false (%copy-arm-script lib-dir missing))
        (false (probe-file dest))))))

;;; path-helper test ----------------------------------------------------------

(define-test default-lib-dir-is-local-lib
  (is equal
      (merge-pathnames ".local/lib/dsmr-mcp/" (user-homedir-pathname))
      (default-lib-dir)))

;;; settings-write tests ------------------------------------------------------

(define-test write-project-hook-creates-and-is-idempotent
  (with-temp-dir (project-dir "hooks-test-project")
    (let* ((cmd "/abs/bus-arm.sh")
           (settings-path (merge-pathnames ".claude/settings.json" project-dir))
           (first (%write-project-hook project-dir cmd)))
      ;; created the file
      (is eq :created (getf first :action-taken))
      (true (probe-file settings-path))
      ;; re-parses and contains the command
      (let* ((parsed (jzon:parse (uiop:read-file-string settings-path)))
             (ss (gethash "SessionStart" (gethash "hooks" parsed))))
        (is = 1 (length ss))
        (true (hook-already-present-p parsed cmd)))
      ;; a second call leaves SessionStart at length 1 and reports already-present
      (let* ((second (%write-project-hook project-dir cmd))
             (parsed2 (jzon:parse (uiop:read-file-string settings-path)))
             (ss2 (gethash "SessionStart" (gethash "hooks" parsed2))))
        (is eq :already-present (getf second :action-taken))
        (is = 1 (length ss2))))))

(define-test install-hooks-skip-is-noop
  (with-temp-dir (project-dir "hooks-test-project")
    (with-temp-dir (lib-dir "hooks-test-lib")
      (false (install-hooks :project-root project-dir
                            :lib-dir lib-dir
                            :mode :skip))
      (false (probe-file (merge-pathnames ".claude/settings.json" project-dir)))
      (false (probe-file (arm-script-path lib-dir))))))
