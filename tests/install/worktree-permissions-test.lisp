;;;; tests/install/worktree-permissions-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Zebra tests for the worktree .envrc edit rules: rule derivation, the
;;;; append-only merge into a Claude Code settings file, idempotency, refusal of
;;;; unreadable or wrongly shaped files, file mode and symlink handling, backup
;;;; naming, default path resolution, and the consent gate. Every test passes a
;;;; settings path inside a fresh temp dir, and every test that resolves a
;;;; default path first points HOME and CLAUDE_CONFIG_DIR into a temp dir, so
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
                #:install-worktree-permissions
                #:user-settings-path
                #:default-workspace
                #:offer-worktree-permissions
                #:run-worktree-permissions
                #:*interactive-p*
                #:%backup-path
                #:%replace-file
                #:%read-octets))

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

(defmacro with-scratch-home ((var stem) &body body)
  "Run BODY with HOME at a fresh temp dir VAR, CLAUDE_CONFIG_DIR at VAR/.claude/,
and LISP_WORKSPACE and DSMR_WORKTREE_ROOTS empty, restoring all four on exit.
Every default path then resolves inside VAR."
  `(with-temp-dir (,var ,stem)
     (with-env (("HOME" (uiop:native-namestring ,var))
                ("CLAUDE_CONFIG_DIR"
                 (uiop:native-namestring (merge-pathnames ".claude/" ,var)))
                ("LISP_WORKSPACE" "")
                ("DSMR_WORKTREE_ROOTS" ""))
       ,@body)))

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
    \"EXAMPLE_FLAG\": \"1\",
    \"EXAMPLE_QUOTE\": \"say \\\"hi\\\" \\\\ there\"
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
  \"statusLine\": {
    \"type\": \"command\",
    \"command\": \"printf '→ café 😀'\"
  },
  \"model\": \"example-model\",
  \"cleanupPeriodDays\": 30,
  \"feedbackSurveyRate\": 0.5,
  \"includeCoAuthoredBy\": false
}
"
  "Settings text in the format Claude Code writes, with non-ASCII text, escaped
characters, and a float.")

(defparameter +fixture-merged+
  "{
  \"env\": {
    \"EXAMPLE_FLAG\": \"1\",
    \"EXAMPLE_QUOTE\": \"say \\\"hi\\\" \\\\ there\"
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
  \"statusLine\": {
    \"type\": \"command\",
    \"command\": \"printf '→ café 😀'\"
  },
  \"model\": \"example-model\",
  \"cleanupPeriodDays\": 30,
  \"feedbackSurveyRate\": 0.5,
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

(define-test wrong-shapes-are-refused
  (%assert-refused (format nil "[]~%"))
  (%assert-refused (format nil "{~%  \"permissions\": \"x\"~%}~%"))
  (%assert-refused (format nil "{~%  \"permissions\": null~%}~%"))
  (%assert-refused (format nil "{~%  \"permissions\": {~%    \"allow\": \"Edit(x)\"~%  }~%}~%")))

(defun %mode (path)
  "Return the permission bits of PATH."
  (logand #o777 (sb-posix:stat-mode (sb-posix:stat (uiop:native-namestring path)))))

(defmacro with-umask ((mask) &body body)
  "Run BODY with the process umask set to MASK, restoring the previous one."
  (let ((old (gensym "OLD")))
    `(let ((,old (sb-posix:umask ,mask)))
       (unwind-protect (progn ,@body)
         (sb-posix:umask ,old)))))

(define-test updating-run-keeps-file-mode
  ;; Under umask 022 a file created without an explicit mode is 0644, so 0600
  ;; and 0640 both differ from what the umask alone would give.
  (with-umask (#o022)
    (dolist (mode (list #o600 #o640))
      (with-temp-dir (dir "worktree-perms")
        (let ((path (%write-text (merge-pathnames "settings.json" dir) +fixture+)))
          (sb-posix:chmod (uiop:native-namestring path) mode)
          (let ((result (%run path)))
            (is eq :updated (getf result :action-taken))
            (is = mode (%mode path))
            (is = mode (%mode (getf result :backup-path))
                "the backup keeps the original mode too")
            (is = 2 (length (%listing dir))
                "no temp file is left beside the settings file")))))))

(define-test symlinked-settings-are-written-through-the-link
  (with-temp-dir (dir "worktree-perms")
    (let* ((target (%write-text (merge-pathnames "managed/settings.json" dir) +fixture+))
           (link (merge-pathnames "settings.json" dir)))
      (sb-posix:symlink (uiop:native-namestring target) (uiop:native-namestring link))
      (let ((result (%run link)))
        (is eq :updated (getf result :action-taken))
        (true (sb-posix:s-islnk
               (sb-posix:stat-mode (sb-posix:lstat (uiop:native-namestring link))))
              "the settings path is still a symlink")
        (is string= +fixture-merged+ (%read-text target))
        (is equal (truename target) (getf result :path))
        (is equal (pathname-directory (truename target))
            (pathname-directory (getf result :backup-path))
            "the backup sits beside the link target")))))

(define-test backup-name-never-overwrites
  (with-temp-dir (dir "worktree-perms")
    (let* ((path (merge-pathnames "settings.json" dir))
           (base (concatenate 'string (uiop:native-namestring path)
                              ".bak-20260101000000")))
      (is string= base (uiop:native-namestring (%backup-path path "20260101000000")))
      (%write-text (uiop:parse-native-namestring base) "x")
      (is string= (concatenate 'string base "-1")
          (uiop:native-namestring (%backup-path path "20260101000000")))
      (%write-text (uiop:parse-native-namestring (concatenate 'string base "-1")) "x")
      (is string= (concatenate 'string base "-2")
          (uiop:native-namestring (%backup-path path "20260101000000"))))))

(define-test user-settings-path-resolution
  (with-scratch-home (home "worktree-perms-home")
    (let ((cfg (merge-pathnames "cfg/" home)))
      (with-env (("CLAUDE_CONFIG_DIR" (uiop:native-namestring cfg)))
        (is string= (uiop:native-namestring (merge-pathnames "settings.json" cfg))
            (uiop:native-namestring (user-settings-path)))))
    (with-env (("CLAUDE_CONFIG_DIR" ""))
      (is string= (uiop:native-namestring (merge-pathnames ".claude/settings.json" home))
          (uiop:native-namestring (user-settings-path))))
    (with-env (("CLAUDE_CONFIG_DIR" "relative/dir"))
      (fail (user-settings-path)))))

(define-test default-workspace-resolution
  (with-scratch-home (home "worktree-perms-home")
    (let ((home-text (uiop:native-namestring home)))
      (with-env (("LISP_WORKSPACE" "~/ws/"))
        (is string= (concatenate 'string home-text "ws/") (default-workspace)))
      (is string= (concatenate 'string home-text "SourceCode/lisp/") (default-workspace))
      (is equal (format nil "Edit(/~Ascratch/**/.envrc)" home-text)
          (third (worktree-envrc-rules +workspace+ (list "~/scratch")))
          "a home-relative extra root expands under the home directory"))))

(define-test offer-respects-consent-mode
  (with-scratch-home (home "worktree-perms-home")
    (let ((path (merge-pathnames "settings.json" home)))
      (false (offer-worktree-permissions :mode :skip :settings-path path))
      (false (probe-file path))
      (let ((*standard-input* (make-string-input-stream (format nil "y~%"))))
        (false (offer-worktree-permissions :mode :interactive :settings-path path)
               "a non-interactive stream is never read"))
      (false (probe-file path))
      (let ((result (offer-worktree-permissions :mode :force :settings-path path)))
        (is eq :created (getf result :action-taken))
        (is equal (worktree-envrc-rules (default-workspace) nil) (%allow path))))))

(define-test exponent-numbers-are-rewritten-in-decimal
  ;; jzon writes a number back in its own spelling: 1e3 becomes 1000.0. The
  ;; value is unchanged; the text of that line is not.
  (with-temp-dir (dir "worktree-perms")
    (let ((path (%write-text (merge-pathnames "settings.json" dir)
                             (format nil "{~%  \"limit\": 1e3~%}~%"))))
      (is eq :updated (getf (%run path) :action-taken))
      (true (search "\"limit\": 1000.0," (%read-text path))))))

(define-test settings-under-a-directory-with-glob-characters
  (with-temp-dir (dir "worktree-perms")
    (let ((path (uiop:parse-native-namestring
                 (concatenate 'string (uiop:native-namestring dir)
                              "cfg[1] a*b?c/settings.json"))))
      (is eq :created (getf (%run path) :action-taken))
      (is equal +expected-rules+ (%allow path))
      (%write-text path +fixture+)
      (let ((result (%run path)))
        (is eq :updated (getf result :action-taken))
        (is string= +fixture-merged+ (%read-text path))
        (is string= +fixture+ (%read-text (getf result :backup-path))))
      (is eq :already-present (getf (%run path) :action-taken)))))

(define-test roots-are-canonicalized
  (dolist (ws (list "//srv/example/lisp" "/srv/example/x/../lisp"
                    "/srv/./example/lisp/." "/srv//example/lisp//"))
    (is equal (subseq +expected-rules+ 0 2) (worktree-envrc-rules ws nil)
        "each spelling of the workspace gives the canonical rules"))
  (multiple-value-bind (rules ignored)
      (worktree-envrc-rules +workspace+
                            (list "/srv/example//scratch" "/srv/example/scratch/"
                                  "/srv/example/scratch/x/.." "/." "//" "/.."
                                  "/srv/a*b" "/srv/build[1]" "/srv/{x}" "/srv/q?"))
    (is equal +expected-rules+ rules "spellings of one root give one rule")
    (is equal (list "/." "//" "/.." "/srv/a*b" "/srv/build[1]" "/srv/{x}" "/srv/q?")
        ignored "filesystem-root and glob roots give no rule"))
  (fail (worktree-envrc-rules "/." nil))
  (fail (worktree-envrc-rules "//" nil))
  (fail (worktree-envrc-rules "/srv/a*b" nil)))

(defun %refusal (path)
  "Run against PATH, assert it is refused with no backup, and return the reason."
  (let ((result (%run path)))
    (is eq :refused (getf result :action-taken))
    (false (getf result :backup-path))
    (getf result :reason)))

(define-test unreadable-settings-get-their-own-reasons
  (with-temp-dir (dir "worktree-perms")
    (let ((path (merge-pathnames "settings.json" dir)))
      (ensure-directories-exist (merge-pathnames "settings.json/" dir))
      (true (search "is a directory" (%refusal path)))))
  (with-temp-dir (dir "worktree-perms")
    (let ((path (merge-pathnames "settings.json" dir)))
      (sb-posix:symlink (uiop:native-namestring (merge-pathnames "missing.json" dir))
                        (uiop:native-namestring path))
      (true (search "is a symlink to a missing file" (%refusal path)))
      (false (probe-file (merge-pathnames "missing.json" dir))
             "the link target is not created")))
  (with-temp-dir (dir "worktree-perms")
    (let ((path (merge-pathnames "settings.json" dir)))
      (with-open-file (out path :direction :output :element-type '(unsigned-byte 8))
        (write-sequence (coerce #(123 255 125 10) '(vector (unsigned-byte 8))) out))
      (true (search "is not valid UTF-8" (%refusal path)))
      (is equal (list "settings.json") (%listing dir))))
  ;; Mode 000 does not stop root from reading, so the case runs only as a
  ;; regular user.
  (unless (zerop (sb-posix:geteuid))
    (with-temp-dir (dir "worktree-perms")
      (let ((path (%write-text (merge-pathnames "settings.json" dir) +fixture+)))
        (sb-posix:chmod (uiop:native-namestring path) 0)
        (unwind-protect (true (search "cannot be read" (%refusal path)))
          (sb-posix:chmod (uiop:native-namestring path) #o600))
        (is string= +fixture+ (%read-text path))))))

(define-test a-file-changed-after-parsing-is-not-replaced
  (with-temp-dir (dir "worktree-perms")
    (let* ((path (%write-text (merge-pathnames "settings.json" dir) +fixture+))
           (parsed (%read-octets path)))
      ;; Another writer replaces the file between the parse and the rename.
      (%write-text path +fixture-merged+)
      (false (%replace-file path parsed
                            (sb-ext:string-to-octets "{}" :external-format :utf-8)))
      (is string= +fixture-merged+ (%read-text path))
      (is equal (list "settings.json") (%listing dir)
          "no backup and no temp file remain"))))

(defun %exit-code (&rest args)
  "Return (values CODE OUTPUT) from run-worktree-permissions called with ARGS."
  (let* ((out (make-string-output-stream))
         (code (let ((*standard-output* out))
                 (apply #'run-worktree-permissions args))))
    (values code (get-output-stream-string out))))

(define-test run-exit-codes
  (with-env (("DSMR_WORKTREE_ROOTS" ""))
    (with-temp-dir (dir "worktree-perms")
      (let ((path (uiop:native-namestring (merge-pathnames "settings.json" dir))))
        (is = 1 (%exit-code :settings-path path :workspace +workspace+ :dry-run t)
            "a missing rule fails the check")
        (false (probe-file path) "the check writes nothing")
        (multiple-value-bind (code out)
            (%exit-code :settings-path path :workspace +workspace+)
          (is = 0 code "an install that adds the rules succeeds")
          (true (search "added:" out)))
        (is = 0 (%exit-code :settings-path path :workspace +workspace+ :dry-run t)
            "a complete file passes the check")
        (is = 0 (%exit-code :settings-path path :workspace +workspace+)
            "an install with every rule present succeeds")
        (is = 1 (%exit-code :settings-path path :workspace "relative/ws")
            "an unusable workspace fails")))
    (with-temp-dir (dir "worktree-perms")
      (let ((path (uiop:native-namestring
                   (%write-text (merge-pathnames "settings.json" dir) "{ not json"))))
        (multiple-value-bind (code out)
            (%exit-code :settings-path path :workspace +workspace+)
          (is = 1 code "a refused file fails the install")
          (true (search "refused:" out)))
        (is = 1 (%exit-code :settings-path path :workspace +workspace+ :dry-run t)
            "a refused file fails the check"))))
  (with-env (("DSMR_WORKTREE_ROOTS" (format nil "relative/dir:~A" +scratch+)))
    (with-temp-dir (dir "worktree-perms")
      (let ((path (uiop:native-namestring (merge-pathnames "settings.json" dir))))
        (multiple-value-bind (code out)
            (%exit-code :settings-path path :workspace +workspace+)
          (is = 0 code "an ignored root is reported and does not fail the run")
          (true (search "ignored root: \"relative/dir\" (is relative)" out)))
        (is = 0 (%exit-code :settings-path path :workspace +workspace+ :dry-run t)
            "an ignored root does not fail the check")))))

(defun %offer-with-answer (answer path)
  "Run the :interactive offer for PATH as though on a terminal that supplies
ANSWER. Returns (values RESULT PROMPT-TEXT)."
  (let ((*interactive-p* (constantly t))
        (*standard-input* (make-string-input-stream answer))
        (*standard-output* (make-string-output-stream)))
    (values (offer-worktree-permissions :mode :interactive :settings-path path)
            (get-output-stream-string *standard-output*))))

(define-test terminal-consent-installs-only-on-yes
  (with-scratch-home (home "worktree-perms-home")
    (let ((n 0))
      (flet ((fresh-path ()
               (merge-pathnames (format nil "settings-~D.json" (incf n)) home)))
        (dolist (answer (list (format nil "n~%") (format nil "no~%") (format nil "~%") ""))
          (let ((path (fresh-path)))
            (multiple-value-bind (result prompt) (%offer-with-answer answer path)
              (is eq :declined (getf result :action-taken))
              (true (search "[y/N]" prompt))
              (false (probe-file path) "a declined offer writes nothing"))))
        (dolist (answer (list (format nil "y~%") (format nil "YES~%")))
          (let ((path (fresh-path)))
            (is eq :created (getf (%offer-with-answer answer path) :action-taken))
            (is equal (worktree-envrc-rules (default-workspace) nil) (%allow path))))
        (with-env (("LISP_WORKSPACE" "relative/ws"))
          (let ((path (fresh-path)))
            (is eq :declined
                (getf (%offer-with-answer (format nil "n~%") path) :action-taken)
                "no path is resolved before the answer")
            (let ((result (offer-worktree-permissions :mode :force :settings-path path)))
              (is eq :failed (getf result :action-taken))
              (true (search "LISP_WORKSPACE" (getf result :reason))))
            (false (probe-file path))))))))
