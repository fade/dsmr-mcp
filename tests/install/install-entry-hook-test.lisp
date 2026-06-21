;;;; tests/install/install-entry-hook-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Entry-level tests that the installer threads the SessionStart auto-arm hook
;;;; step into its result plist and honours the install-hook opt-out.
;;;;
;;;; Isolation: install writes ~/.claude.json (and copies skills/bus-watch into
;;;; ~/.local/...) by default, and the hook step's default lib-dir and the
;;;; claude-config path both resolve against (user-homedir-pathname), which reads
;;;; $HOME at call time. Every test therefore runs inside with-temp-home, which
;;;; points $HOME at a fresh temp dir for the dynamic extent of the install call
;;;; and restores it afterward — so the operator's real ~/.claude and ~/.local are
;;;; never read or written. The non-interactive consent gate (:site-defaults :skip
;;;; and a non-tty stdin) keeps the defaults/hook steps from prompting or blocking.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/install/install-entry-hook-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/install/install-entry-hook-test
  (:use #:cl #:parachute)
  (:import-from #:dsmr-mcp/src/install
                #:install))

(in-package #:dsmr-mcp/tests/install/install-entry-hook-test)

;;; helpers -------------------------------------------------------------------

(defun %unique-temp-dir (stem)
  "Create and return a fresh, unique temporary directory pathname named for STEM.
SBCL's default *random-state* is deterministic across process invocations, so the
random suffix must be drawn from an entropy-seeded state minted at the call site —
otherwise the \"unique\" names repeat run-to-run and a leftover dir can leak into a
later run's absence assertions."
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

(defmacro with-temp-home ((var stem) &body body)
  "Point $HOME at a fresh temp dir VAR for the dynamic extent of BODY, restoring
the previous value on exit. (user-homedir-pathname reads $HOME at call time, so
this redirects every default install path — ~/.claude.json, ~/.claude/skills,
~/.local/bin, ~/.local/lib — into temp space, keeping the real home untouched.)"
  (let ((old (gensym "OLD-HOME")))
    `(with-temp-dir (,var ,stem)
       (let ((,old (uiop:getenv "HOME")))
         (unwind-protect
              (progn
                (sb-posix:setenv "HOME" (namestring ,var) 1)
                ,@body)
           (when ,old (sb-posix:setenv "HOME" ,old 1)))))))

;;; tests ---------------------------------------------------------------------

(define-test no-hook-flag-skips-the-hook-write
  ;; install-hook nil must not write a hook anywhere. We assert on the temp
  ;; project root's .claude/settings.json (the hook target when the step runs):
  ;; with the step disabled it is never created.
  (with-temp-home (home "install-entry-hook-home")
    (with-temp-dir (proj "install-entry-hook-proj")
      (let* ((*default-pathname-defaults* proj)
             (settings (merge-pathnames ".claude/settings.json" proj))
             (result (install :agent :claude-code
                              :install-hook nil
                              :site-defaults :skip
                              :install-skill nil
                              :install-bus-watch nil)))
        ;; The plist is well-formed and carries no hook result.
        (true (listp result))
        (false (getf result :hook-result))
        ;; No hook artifact landed in the temp project root.
        (false (probe-file settings))))))

(define-test skip-mode-returns-plist-without-blocking
  ;; install-hook t with a :skip consent posture forwards :skip to the hook
  ;; step, which is a pure no-op (no prompt, no read, no hang). The call returns
  ;; a well-formed plist whose :hook-result is NIL.
  (with-temp-home (home "install-entry-hook-home")
    (with-temp-dir (proj "install-entry-hook-proj")
      (let* ((*default-pathname-defaults* proj)
             (result (install :agent :claude-code
                              :install-hook t
                              :site-defaults :skip
                              :install-skill nil
                              :install-bus-watch nil)))
        (true (listp result))
        (false (getf result :hook-result))
        ;; The plist still carries the rest of the install result.
        (true (getf result :path))))))
