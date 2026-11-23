;;;; src/install/permissions.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Installer module that merges Claude Code allow rules for .envrc files in
;;;; git worktrees into the user's Claude Code settings file
;;;; ($CLAUDE_CONFIG_DIR/settings.json, else ~/.claude/settings.json).
;;;;
;;;; Rule derivation and the merge are pure functions on text and parsed jzon
;;;; hash-tables. install-worktree-permissions is the IO entry: it reads the
;;;; file, refuses one it cannot parse, writes nothing when every rule is
;;;; present, and otherwise backs the file up and writes it atomically.

(defpackage #:dsmr-mcp/src/install/permissions
  (:use #:cl)
  (:local-nicknames (#:jzon #:com.inuoe.jzon))
  (:import-from #:dsmr-mcp/src/fs
                #:write-file-string-atomically)
  (:import-from #:sb-posix)
  (:export #:worktree-envrc-rules
           #:ensure-allow-rules
           #:user-settings-path
           #:default-workspace
           #:env-worktree-roots
           #:install-worktree-permissions
           #:offer-worktree-permissions
           #:run-worktree-permissions))

(in-package #:dsmr-mcp/src/install/permissions)

;;; Hash-table helpers --------------------------------------------------------

(defun %copy-ht (ht)
  "Return a fresh equal-keyed shallow copy of hash-table HT, keeping key order."
  (let ((out (make-hash-table :test 'equal :size (max 1 (hash-table-count ht)))))
    (maphash (lambda (k v) (setf (gethash k out) v)) ht)
    out))

(defun %json-array-p (x)
  "True when X is a parsed JSON array. A string is a vector, so it is excluded."
  (and (vectorp x) (not (stringp x))))

;;; Rule derivation -----------------------------------------------------------

(defun %expand-home (text)
  "Return TEXT with a leading ~/ replaced by the home directory."
  (if (and (>= (length text) 2)
           (char= (char text 0) #\~)
           (char= (char text 1) #\/))
      (concatenate 'string
                   (string-right-trim "/" (uiop:native-namestring
                                           (user-homedir-pathname)))
                   "/" (subseq text 2))
      text))

(defun %normalize-root (designator)
  "Return DESIGNATOR as an absolute native directory string with no trailing
slash, or NIL when it is not a string or pathname, is empty, is relative after
~/ expansion, or names the filesystem root."
  (let ((text (typecase designator
                (string designator)
                (pathname (uiop:native-namestring designator))
                (t nil))))
    (when text
      (let ((trimmed (string-right-trim "/" (%expand-home text))))
        (when (and (plusp (length trimmed))
                   (char= (char trimmed 0) #\/))
          trimmed)))))

(defun worktree-envrc-rules (workspace extra-roots)
  "Return (values RULES IGNORED) for WORKSPACE and the list EXTRA-ROOTS.

RULES lists Edit(/<workspace>/*/.worktrees/**/.envrc) and
Edit(/<workspace>/**/.claude/worktrees/**/.envrc), then one
Edit(/<root>/**/.envrc) per usable extra root in the given order, with
duplicates removed. Each directory is absolute, so the text reads Edit(//...).
IGNORED lists the extra-root entries that give no rule: empty, relative, or
the filesystem root. Signals an error when WORKSPACE is not usable."
  (let ((w (%normalize-root workspace)))
    (unless w
      (error "workspace ~S is not an absolute directory; set LISP_WORKSPACE ~
              to an absolute path" workspace))
    (let ((rules (list (format nil "Edit(/~A/*/.worktrees/**/.envrc)" w)
                       (format nil "Edit(/~A/**/.claude/worktrees/**/.envrc)" w)))
          (ignored '()))
      (dolist (root extra-roots)
        (let ((r (%normalize-root root)))
          (if r
              (setf rules (append rules (list (format nil "Edit(/~A/**/.envrc)" r))))
              (push root ignored))))
      (values (remove-duplicates rules :test #'string= :from-end t)
              (nreverse ignored)))))

;;; Pure merge ----------------------------------------------------------------

(defun ensure-allow-rules (settings rules)
  "Return (values NEW-SETTINGS ADDED). NEW-SETTINGS is SETTINGS with each rule
of RULES that is not already a string element of permissions.allow appended
at the end of that array, in rule order. ADDED lists the appended rules.

SETTINGS is a parsed jzon hash-table or NIL, and is never mutated. A missing
permissions key is added last at the top level, and a missing allow key last
inside permissions. No existing key or element is removed, reordered, or
rewritten."
  (let* ((base (if (hash-table-p settings)
                   (%copy-ht settings)
                   (make-hash-table :test 'equal)))
         (perms-in (gethash "permissions" base))
         (perms (if (hash-table-p perms-in)
                    (%copy-ht perms-in)
                    (make-hash-table :test 'equal)))
         (allow-in (gethash "allow" perms))
         (allow (if (%json-array-p allow-in) allow-in #()))
         (added '()))
    (dolist (rule rules)
      (unless (or (find rule allow :test #'equal)
                  (member rule added :test #'string=))
        (setf added (append added (list rule)))))
    (when added
      (setf (gethash "allow" perms)
            (concatenate 'simple-vector allow added))
      (setf (gethash "permissions" base) perms))
    (values base added)))

;;; Default resolution --------------------------------------------------------

(defun %env (name)
  "Return environment variable NAME, or NIL when it is unset or empty."
  (let ((v (uiop:getenv name)))
    (and v (plusp (length v)) v)))

(defun user-settings-path ()
  "Return <CLAUDE_CONFIG_DIR>/settings.json when CLAUDE_CONFIG_DIR is set and
non-empty, else ~/.claude/settings.json. Signals an error when
CLAUDE_CONFIG_DIR is set but not absolute."
  (let ((dir (%env "CLAUDE_CONFIG_DIR")))
    (if dir
        (let ((path (uiop:ensure-directory-pathname
                     (uiop:parse-native-namestring dir))))
          (unless (uiop:absolute-pathname-p path)
            (error "CLAUDE_CONFIG_DIR ~S is not an absolute directory; set it to ~
                    an absolute path or unset it" dir))
          (merge-pathnames "settings.json" path))
        (merge-pathnames ".claude/settings.json" (user-homedir-pathname)))))

(defun default-workspace ()
  "Return LISP_WORKSPACE with a leading ~/ expanded when it is set and
non-empty, else ~/SourceCode/lisp/, as a string."
  (let ((ws (%env "LISP_WORKSPACE")))
    (if ws
        (%expand-home ws)
        (uiop:native-namestring
         (merge-pathnames "SourceCode/lisp/" (user-homedir-pathname))))))

(defun env-worktree-roots ()
  "Return DSMR_WORKTREE_ROOTS split on colons, empty entries included, or NIL
when the variable is unset or empty."
  (let ((roots (%env "DSMR_WORKTREE_ROOTS")))
    (and roots (uiop:split-string roots :separator ":"))))

;;; Backup --------------------------------------------------------------------

(defun %timestamp ()
  "Return a YYYYMMDDHHMMSS stamp for the current local time."
  (multiple-value-bind (s m h d mo y) (decode-universal-time (get-universal-time))
    (format nil "~4,'0D~2,'0D~2,'0D~2,'0D~2,'0D~2,'0D" y mo d h m s)))

(defun %backup-path (path stamp)
  "Return <path>.bak-<STAMP>, or the first of <path>.bak-<STAMP>-1, -2, ...
that does not exist, so an existing backup is never overwritten."
  (let ((base (format nil "~A.bak-~A" (uiop:native-namestring path) stamp)))
    (loop for n from 0
          for candidate = (if (zerop n) base (format nil "~A-~D" base n))
          unless (probe-file candidate)
            return (uiop:parse-native-namestring candidate))))

(defun %copy-mode (from to)
  "Give TO the permission bits of FROM. Returns NIL."
  (let ((mode (logand (sb-posix:stat-mode
                       (sb-posix:stat (uiop:native-namestring from)))
                      #o7777)))
    (sb-posix:chmod (uiop:native-namestring to) mode)
    nil))

(defun %write-backup (path)
  "Copy PATH byte for byte to a fresh backup beside it, with PATH's mode, and
return the backup pathname. Signals an error when the backup did not appear."
  (let ((backup (%backup-path path (%timestamp))))
    (uiop:copy-file path backup)
    (unless (probe-file backup)
      (error "backup ~A was not created; ~A is unchanged"
             (uiop:native-namestring backup) (uiop:native-namestring path)))
    (%copy-mode path backup)
    backup))

;;; IO entry ------------------------------------------------------------------

(defun %as-pathname (designator)
  "Return DESIGNATOR as a pathname, parsing a string as a native namestring."
  (if (pathnamep designator)
      designator
      (uiop:parse-native-namestring designator)))

(defun %read-settings (path)
  "Return (values SETTINGS TEXT REASON) for the existing file PATH. SETTINGS is
the parsed object; REASON is a string, and SETTINGS NIL, when the file is
refused."
  (let ((name (uiop:native-namestring path)))
    (handler-case
        (let ((text (uiop:read-file-string path :external-format :utf-8)))
          (if (zerop (length (string-trim '(#\Space #\Tab #\Newline #\Return) text)))
              (values nil text
                      (format nil "~A is empty; write {} into it or remove it, ~
                                   then run again" name))
              (values (jzon:parse text) text nil)))
      (error (e)
        (values nil nil
                (format nil "~A is not valid JSON: ~A; fix the file, then run again"
                        name e))))))

(defun install-worktree-permissions (&key (settings-path (user-settings-path))
                                          (workspace (default-workspace))
                                          (extra-roots (env-worktree-roots))
                                          dry-run)
  "Merge the worktree .envrc edit rules for WORKSPACE and EXTRA-ROOTS into the
Claude Code settings file SETTINGS-PATH. Returns a plist:

  :path           the file examined or written, its truename when it exists
  :rules          every generated rule
  :missing        the rules absent before the run
  :ignored-roots  extra-root entries that gave no rule
  :backup-path    the backup written, or NIL
  :action-taken   :created, :updated, :already-present, :refused, or :checked
  :reason         why the file was refused (only with :refused)

An existing file is resolved to its truename, so a symlink is written through.
A file that is empty or not valid JSON is refused and left unchanged. When no
rule is missing nothing is written. DRY-RUN true reports :checked and writes
nothing. Otherwise the file is backed up to <path>.bak-<stamp> and replaced
atomically with its mode kept. Signals an error when WORKSPACE is not usable."
  (multiple-value-bind (rules ignored) (worktree-envrc-rules workspace extra-roots)
    (let* ((given (%as-pathname settings-path))
           (existing (probe-file given))
           (path (if existing (truename given) given)))
      (flet ((result (action &key missing backup reason)
               (list* :path path
                      :rules rules
                      :missing missing
                      :ignored-roots ignored
                      :backup-path backup
                      :action-taken action
                      (when reason (list :reason reason)))))
        (multiple-value-bind (settings text reason)
            (if existing (%read-settings path) (values nil nil nil))
          (when reason
            (return-from install-worktree-permissions
              (result :refused :reason reason)))
          (multiple-value-bind (updated missing) (ensure-allow-rules settings rules)
            (cond
              (dry-run (result :checked :missing missing))
              ((and existing (null missing)) (result :already-present))
              (t
               (let ((rendered (jzon:stringify updated :pretty t)))
                 (when (or (not existing)
                           (and (plusp (length text))
                                (char= #\Newline (char text (1- (length text))))))
                   (setf rendered (concatenate 'string rendered (string #\Newline))))
                 (handler-case (jzon:parse rendered)
                   (error (e)
                     (error "rendered settings did not parse (~A); ~A is unchanged"
                            e (uiop:native-namestring path))))
                 (let ((backup (when existing (%write-backup path))))
                   (write-file-string-atomically path rendered
                                                 :keep-mode t
                                                 :external-format :utf-8)
                   (result (if existing :updated :created)
                           :missing missing
                           :backup backup)))))))))))

;;; Consent gate --------------------------------------------------------------

(defun %yes-p (line)
  "True when LINE, trimmed, is y or yes in any case."
  (and line
       (let ((trimmed (string-trim '(#\Space #\Tab #\Return) line)))
         (or (string-equal trimmed "y") (string-equal trimmed "yes")))))

(defun offer-worktree-permissions (&key (mode :interactive) settings-path)
  "Installer step for the worktree .envrc edit rules.

MODE selects the behaviour:
  :skip         return NIL.
  :force        run install-worktree-permissions without asking.
  :interactive  when *standard-input* is interactive, print the rules and the
                settings path, ask [y/N], and run the install on y or yes;
                otherwise return NIL without reading.

SETTINGS-PATH, when non-NIL, replaces user-settings-path. Returns the
install-worktree-permissions plist, or NIL when skipped or declined."
  (let ((args (when settings-path (list :settings-path settings-path))))
    (ecase mode
      (:skip nil)
      (:force (apply #'install-worktree-permissions args))
      (:interactive
       (when (interactive-stream-p *standard-input*)
         (let ((path (or settings-path (user-settings-path)))
               (rules (worktree-envrc-rules (default-workspace)
                                            (env-worktree-roots))))
           (format *standard-output*
                   "~&Allow Claude Code to edit .envrc files in git worktrees?~%~
                    These rules go into ~A:~%~{  ~A~%~}[y/N] "
                   (uiop:native-namestring path) rules)
           (finish-output *standard-output*)
           (when (%yes-p (read-line *standard-input* nil nil))
             (apply #'install-worktree-permissions args))))))))

;;; Command entry -------------------------------------------------------------

(defun %blank-p (x)
  "True when X is NIL or an empty string."
  (or (null x) (and (stringp x) (zerop (length x)))))

(defun run-worktree-permissions (&key settings-path workspace dry-run)
  "Run install-worktree-permissions, print a report to *standard-output*, and
return an exit code: 0, or 1 when the file is refused or the run signals an
error. With DRY-RUN true, 1 also when any rule is missing. An empty or NIL
SETTINGS-PATH or WORKSPACE takes the default."
  (let ((result
          (handler-case
              (apply #'install-worktree-permissions
                     :dry-run dry-run
                     (append (unless (%blank-p settings-path)
                               (list :settings-path settings-path))
                             (unless (%blank-p workspace)
                               (list :workspace workspace))))
            (error (e)
              (format t "~&worktree permissions: ~A~%" e)
              (return-from run-worktree-permissions 1)))))
    (destructuring-bind (&key path missing ignored-roots backup-path
                           action-taken reason &allow-other-keys)
        result
      (format t "~&worktree permissions: ~A: ~(~A~)~%"
              (uiop:native-namestring path) action-taken)
      (dolist (rule missing)
        (format t "  ~A: ~A~%" (if (member action-taken '(:created :updated))
                                   "added" "missing")
                rule))
      (dolist (root ignored-roots)
        (format t "  ignored root: ~S (not an absolute directory)~%" root))
      (when backup-path
        (format t "  backup: ~A~%" (uiop:native-namestring backup-path)))
      (when reason
        (format t "  refused: ~A~%" reason))
      (cond ((eq action-taken :refused) 1)
            ((and dry-run missing) 1)
            (t 0)))))
