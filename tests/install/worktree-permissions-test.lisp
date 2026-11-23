;;;; tests/install/worktree-permissions-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Zebra tests for the worktree .envrc edit rules: rule derivation, the
;;;; append-only merge into a Claude Code settings file, idempotency, refusal of
;;;; unreadable files, and extra roots from the environment. Every test passes an
;;;; explicit settings path inside a fresh temp dir and an explicit workspace, so
;;;; the real user settings are never read or written.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/install/worktree-permissions-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/install/worktree-permissions-test
  (:use #:cl #:zebra)
  (:local-nicknames (#:jzon #:com.inuoe.jzon))
  (:import-from #:dsmr-mcp/src/install/permissions
                #:worktree-envrc-rules
                #:ensure-allow-rules
                #:env-worktree-roots
                #:install-worktree-permissions))

(in-package #:dsmr-mcp/tests/install/worktree-permissions-test)

;;; helpers -------------------------------------------------------------------

(defun %unique-temp-dir (stem)
  "Create and return a fresh, unique temporary directory pathname named for STEM.
The suffix comes from an entropy-seeded random state, because SBCL's default
*random-state* repeats across process invocations."
  (let* ((*random-state* (make-random-state t))
         (dir (uiop:ensure-directory-pathname
               (merge-pathnames
                (format nil "~A-~A/" stem (random (expt 2 48)))
                (uiop:temporary-directory)))))
    (ensure-directories-exist dir)
    dir))

(defmacro with-temp-dir ((var stem) &body body)
  "Bind VAR to a fresh temp dir for the dynamic extent of BODY and delete it,
with its contents, on exit."
  `(let ((,var (%unique-temp-dir ,stem)))
     (unwind-protect (progn ,@body)
       (ignore-errors (uiop:delete-directory-tree
                       ,var :validate t :if-does-not-exist :ignore)))))

(defmacro with-env ((&rest bindings) &body body)
  "Set each (NAME VALUE) in BINDINGS in the process environment for BODY and
restore the previous values on exit. An unset variable is restored as empty."
  (let ((saved (gensym "SAVED")) (pair (gensym "PAIR")))
    `(let ((,saved (mapcar (lambda (name) (cons name (uiop:getenv name)))
                           (list ,@(mapcar #'first bindings)))))
       (unwind-protect
            (progn
              ,@(mapcar (lambda (b) `(setf (uiop:getenv ,(first b)) ,(second b)))
                        bindings)
              ,@body)
         (dolist (,pair ,saved)
           (setf (uiop:getenv (car ,pair)) (or (cdr ,pair) "")))))))

(defun %write-text (path text)
  "Write TEXT to PATH as UTF-8 and return PATH."
  (ensure-directories-exist path)
  (with-open-file (out path :direction :output :if-exists :supersede
                            :if-does-not-exist :create :external-format :utf-8)
    (write-string text out))
  path)

(defun %read-text (path)
  "Return the contents of PATH read as UTF-8."
  (uiop:read-file-string path :external-format :utf-8))

(defun %listing (dir)
  "Return the sorted file names directly inside DIR."
  (sort (mapcar #'file-namestring (uiop:directory-files dir)) #'string<))

(defun %allow (path)
  "Return permissions.allow of the settings file at PATH as a list."
  (coerce (gethash "allow" (gethash "permissions" (jzon:parse (%read-text path))))
          'list))

(defun %keys (ht)
  "Return the keys of HT in iteration order."
  (let ((keys '()))
    (maphash (lambda (k v) (declare (ignore v)) (push k keys)) ht)
    (nreverse keys)))

(defparameter +workspace+ "/srv/example/lisp/")
(defparameter +scratch+ "/srv/example/scratch")

(defparameter +worktrees-rule+ "Edit(//srv/example/lisp/*/.worktrees/**/.envrc)")
(defparameter +claude-worktrees-rule+
  "Edit(//srv/example/lisp/**/.claude/worktrees/**/.envrc)")
(defparameter +scratch-rule+ "Edit(//srv/example/scratch/**/.envrc)")

(defparameter +expected-rules+
  (list +worktrees-rule+ +claude-worktrees-rule+ +scratch-rule+))

(defparameter +fixture+
  "{
  \"env\": {
    \"EXAMPLE_FLAG\": \"1\"
  },
  \"permissions\": {
    \"allow\": [
      \"Bash(git status:*)\",
      \"Read(//srv/example/notes/**)\"
    ],
    \"deny\": [],
    \"defaultMode\": \"default\"
  },
  \"hooks\": {},
  \"model\": \"example-model\",
  \"cleanupPeriodDays\": 30,
  \"includeCoAuthoredBy\": false
}
"
  "Settings text in the format Claude Code writes.")

(defparameter +fixture-merged+
  "{
  \"env\": {
    \"EXAMPLE_FLAG\": \"1\"
  },
  \"permissions\": {
    \"allow\": [
      \"Bash(git status:*)\",
      \"Read(//srv/example/notes/**)\",
      \"Edit(//srv/example/lisp/*/.worktrees/**/.envrc)\",
      \"Edit(//srv/example/lisp/**/.claude/worktrees/**/.envrc)\",
      \"Edit(//srv/example/scratch/**/.envrc)\"
    ],
    \"deny\": [],
    \"defaultMode\": \"default\"
  },
  \"hooks\": {},
  \"model\": \"example-model\",
  \"cleanupPeriodDays\": 30,
  \"includeCoAuthoredBy\": false
}
"
  "+fixture+ after a run with +workspace+ and +scratch+.")

(defun %run (path &rest args)
  "Run install-worktree-permissions on PATH with +workspace+ and +scratch+,
overridable through ARGS."
  (apply #'install-worktree-permissions
         (append args
                 (list :settings-path path
                       :workspace +workspace+
                       :extra-roots (list +scratch+)))))

;;; rule derivation -----------------------------------------------------------

(define-test rules-for-workspace-and-extra-root
  (is equal +expected-rules+ (worktree-envrc-rules +workspace+ (list +scratch+)))
  (is equal +expected-rules+
      (worktree-envrc-rules "/srv/example/lisp" (list +scratch+))
      "a workspace without the trailing slash gives the same rules"))

(define-test unusable-extra-roots-are-ignored
  (multiple-value-bind (rules ignored)
      (worktree-envrc-rules +workspace+ (list "" "relative/dir" "/" +scratch+ +scratch+))
    (is equal +expected-rules+ rules "a root listed twice gives one rule")
    (is equal (list "" "relative/dir" "/") ignored)))

(define-test invalid-workspace-signals
  (fail (worktree-envrc-rules "relative/ws" nil))
  (fail (worktree-envrc-rules "" nil)))

;;; merge ---------------------------------------------------------------------

(define-test merge-does-not-mutate-input
  (let* ((settings (jzon:parse +fixture+))
         (before (jzon:stringify settings)))
    (multiple-value-bind (new added) (ensure-allow-rules settings +expected-rules+)
      (is equal +expected-rules+ added)
      (false (eq new settings))
      (is string= before (jzon:stringify settings)))))

(define-test absent-file-is-created
  (with-temp-dir (dir "worktree-perms")
    (let* ((path (merge-pathnames "settings.json" dir))
           (result (%run path)))
      (is eq :created (getf result :action-taken))
      (false (getf result :backup-path))
      (is equal +expected-rules+ (%allow path))
      (let ((text (%read-text path)))
        (true (char= #\Newline (char text (1- (length text))))
              "the created file ends in a newline"))
      (is equal (list "settings.json") (%listing dir)))))

(define-test merge-keeps-existing-rules-and-key-order
  (with-temp-dir (dir "worktree-perms")
    (let* ((path (%write-text (merge-pathnames "settings.json" dir) +fixture+))
           (result (%run path)))
      (is eq :updated (getf result :action-taken))
      (is equal +expected-rules+ (getf result :missing))
      (is string= +fixture-merged+ (%read-text path))
      (let ((backup (getf result :backup-path)))
        (true backup)
        (true (probe-file backup))
        (is string= +fixture+ (%read-text backup))))))

(define-test merge-appends-only-missing-rules
  (with-temp-dir (dir "worktree-perms")
    (let* ((text (format nil "{~%  \"permissions\": {~%    \"allow\": [~%      \"Bash(ls)\",~%      \"~A\",~%      \"Read(x)\"~%    ]~%  }~%}~%"
                         +worktrees-rule+))
           (path (%write-text (merge-pathnames "settings.json" dir) text))
           (result (%run path)))
      (is equal (list +claude-worktrees-rule+ +scratch-rule+) (getf result :missing))
      (is equal (list "Bash(ls)" +worktrees-rule+ "Read(x)"
                      +claude-worktrees-rule+ +scratch-rule+)
          (%allow path)))))

(define-test merge-adds-permissions-last
  (with-temp-dir (dir "worktree-perms")
    (let ((path (%write-text (merge-pathnames "settings.json" dir)
                             (format nil "{~%  \"model\": \"m\",~%  \"env\": {}~%}~%"))))
      (%run path)
      (let ((parsed (jzon:parse (%read-text path))))
        (is equal (list "model" "env" "permissions") (%keys parsed))
        (is equal +expected-rules+ (%allow path))))))

(define-test merge-adds-allow-last-in-permissions
  (with-temp-dir (dir "worktree-perms")
    (let ((path (%write-text (merge-pathnames "settings.json" dir)
                             (format nil "{~%  \"permissions\": {~%    \"deny\": [],~%    \"defaultMode\": \"default\"~%  },~%  \"model\": \"m\"~%}~%"))))
      (%run path)
      (let ((parsed (jzon:parse (%read-text path))))
        (is equal (list "permissions" "model") (%keys parsed))
        (is equal (list "deny" "defaultMode" "allow")
            (%keys (gethash "permissions" parsed)))
        (is equal +expected-rules+ (%allow path))))))

;;; idempotency ---------------------------------------------------------------

(define-test second-run-writes-nothing
  (with-temp-dir (dir "worktree-perms")
    (let ((path (%write-text (merge-pathnames "settings.json" dir) +fixture+)))
      (%run path)
      (let ((bytes (%read-text path))
            (date (file-write-date path))
            (listing (%listing dir)))
        (sleep 1.1)
        (let ((result (%run path)))
          (is eq :already-present (getf result :action-taken))
          (false (getf result :missing))
          (false (getf result :backup-path))
          (is string= bytes (%read-text path))
          (is = date (file-write-date path))
          (is equal listing (%listing dir)))))))

;;; extra roots from the environment ------------------------------------------

(define-test extra-roots-come-from-the-environment
  (with-env (("DSMR_WORKTREE_ROOTS" "/srv/example/scratch:/srv/example/other"))
    (is equal (list "/srv/example/scratch" "/srv/example/other") (env-worktree-roots))
    (with-temp-dir (dir "worktree-perms")
      (let ((path (merge-pathnames "settings.json" dir)))
        (install-worktree-permissions :settings-path path :workspace +workspace+)
        (let ((allow (%allow path)))
          (true (member +scratch-rule+ allow :test #'string=))
          (true (member "Edit(//srv/example/other/**/.envrc)" allow :test #'string=)))))))

(define-test empty-environment-gives-no-extra-roots
  (with-env (("DSMR_WORKTREE_ROOTS" ""))
    (false (env-worktree-roots))))

;;; refusal -------------------------------------------------------------------

(defun %assert-refused (text)
  "Assert that a settings file holding TEXT is refused and left untouched."
  (with-temp-dir (dir "worktree-perms")
    (let* ((path (%write-text (merge-pathnames "settings.json" dir) text))
           (result (%run path)))
      (is eq :refused (getf result :action-taken))
      (let ((reason (getf result :reason)))
        (true (and (stringp reason) (plusp (length reason)))))
      (false (getf result :backup-path))
      (is string= text (%read-text path))
      (is equal (list "settings.json") (%listing dir)))))

(define-test malformed-file-is-refused
  (%assert-refused "{ not json"))

(define-test empty-file-is-refused
  (%assert-refused ""))

;;; dry run -------------------------------------------------------------------

(define-test dry-run-changes-nothing
  (with-temp-dir (dir "worktree-perms")
    (let* ((path (merge-pathnames "settings.json" dir))
           (result (%run path :dry-run t)))
      (is eq :checked (getf result :action-taken))
      (is equal +expected-rules+ (getf result :missing))
      (false (probe-file path)))
    (let* ((path (%write-text (merge-pathnames "settings.json" dir) +fixture+))
           (result (%run path :dry-run t)))
      (is eq :checked (getf result :action-taken))
      (is equal +expected-rules+ (getf result :missing))
      (is string= +fixture+ (%read-text path))
      (is equal (list "settings.json") (%listing dir)))))
