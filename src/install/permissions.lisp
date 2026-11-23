;;;; src/install/permissions.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Installer module that merges Claude Code allow rules for .envrc files in
;;;; git worktrees into the user's Claude Code settings file
;;;; ($CLAUDE_CONFIG_DIR/settings.json, else ~/.claude/settings.json).
;;;;
;;;; Rule derivation and the merge are pure functions on text and parsed jzon
;;;; hash-tables. install-worktree-permissions is the IO entry. It refuses a
;;;; file it cannot read or parse, or one with the wrong shape, and writes
;;;; nothing when every rule is present. A missing file is created with no
;;;; backup; an existing one is backed up and then replaced atomically.

(defpackage #:dsmr-mcp/src/install/permissions
  (:use #:cl)
  (:local-nicknames (#:jzon #:com.inuoe.jzon))
  (:import-from #:sb-posix)
  (:export #:worktree-envrc-rules
           #:ensure-allow-rules
           #:user-settings-path
           #:default-workspace
           #:env-worktree-roots
           #:install-worktree-permissions
           #:offer-worktree-permissions
           #:*interactive-p*
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

(defparameter +glob-characters+ "*?[]{}"
  "Characters a root may not contain: rule text is a glob pattern, so a root
holding one matches other directories and not itself.")

(defun %canonical-root (designator)
  "Return (values DIRECTORY PROBLEM) for the directory designator DESIGNATOR.

DIRECTORY is an absolute native path with a leading ~/ expanded, repeated
slashes collapsed, . and .. resolved lexically, and no trailing slash. When
DESIGNATOR gives no usable root, DIRECTORY is NIL and PROBLEM is a predicate
phrase saying why: not text, empty, relative, the filesystem root (/, /. and
// included), or holding a glob character."
  (let ((text (typecase designator
                (string designator)
                (pathname (uiop:native-namestring designator))
                (t nil))))
    (cond
      ((null text) (values nil "is not a string or pathname"))
      ((zerop (length text)) (values nil "is empty"))
      (t
       (let ((expanded (%expand-home text)))
         (if (char/= (char expanded 0) #\/)
             (values nil "is relative")
             (let ((parts '()))
               (dolist (part (uiop:split-string expanded :separator "/"))
                 (cond ((member part '("" ".") :test #'string=))
                       ((string= part "..") (pop parts))
                       (t (push part parts))))
               (let ((canonical (format nil "~{/~A~}" (reverse parts))))
                 (cond
                   ((null parts) (values nil "is the filesystem root"))
                   ((find-if (lambda (c) (find c +glob-characters+)) canonical)
                    (values nil "contains a glob character (one of * ? [ ] { })"))
                   (t (values canonical nil)))))))))))

(defun worktree-envrc-rules (workspace extra-roots)
  "Return (values RULES IGNORED) for WORKSPACE and the list EXTRA-ROOTS.

RULES lists Edit(/<workspace>/*/.worktrees/**/.envrc) and
Edit(/<workspace>/**/.claude/worktrees/**/.envrc), then one
Edit(/<root>/**/.envrc) per usable extra root in the given order, with
duplicates removed. Each directory is canonicalized first and is absolute, so
the text reads Edit(//...). IGNORED lists the extra-root entries that give no
rule: empty, relative, the filesystem root, or holding a glob character.
Signals an error when WORKSPACE is not usable."
  (multiple-value-bind (w problem) (%canonical-root workspace)
    (unless w
      (error "workspace ~S ~A; set LISP_WORKSPACE to an absolute directory ~
              without glob characters" workspace problem))
    (let ((rules (list (format nil "Edit(/~A/*/.worktrees/**/.envrc)" w)
                       (format nil "Edit(/~A/**/.claude/worktrees/**/.envrc)" w)))
          (ignored '()))
      (dolist (root extra-roots)
        (let ((r (%canonical-root root)))
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

;;; Files, backups and durable writes ---------------------------------------

(defun %native (path)
  "Return PATH as a native namestring."
  (uiop:native-namestring path))

(defun %errno-p (condition errno)
  "True when the sb-posix:syscall-error CONDITION carries ERRNO."
  (eql (sb-posix:syscall-errno condition) errno))

(defun %file-kind (path)
  "Return what PATH names, following symlinks: :absent, :file, :directory,
:dangling (a symlink to nothing), or :other. When stat fails for any reason
but a missing file, return (values :unreadable CONDITION)."
  (let ((name (%native path)))
    (handler-case
        (let ((mode (sb-posix:stat-mode (sb-posix:stat name))))
          (cond ((sb-posix:s-isreg mode) :file)
                ((sb-posix:s-isdir mode) :directory)
                (t :other)))
      (sb-posix:syscall-error (e)
        (cond ((not (%errno-p e sb-posix:enoent)) (values :unreadable e))
              ((handler-case (progn (sb-posix:lstat name) t)
                 (sb-posix:syscall-error () nil))
               :dangling)
              (t :absent))))))

(defun %free-name (base)
  "Return the first of BASE, BASE-1, BASE-2, ... that names nothing, as a
pathname parsed from native text. Signals when a candidate cannot be checked."
  (loop for n from 0
        for candidate = (uiop:parse-native-namestring
                         (if (zerop n) base (format nil "~A-~D" base n)))
        do (multiple-value-bind (kind e) (%file-kind candidate)
             (case kind
               (:absent (return candidate))
               (:unreadable (error e))))))

(defun %temp-path (path)
  "Return a free hidden temp file name beside PATH: .<name>.tmp-<pid>[-N]."
  (let* ((native (%native path))
         (slash (position #\/ native :from-end t)))
    (%free-name (format nil "~A.~A.tmp-~D"
                        (subseq native 0 (1+ slash))
                        (subseq native (1+ slash))
                        (sb-posix:getpid)))))

(defun %timestamp ()
  "Return a YYYYMMDDHHMMSS stamp for the current local time."
  (multiple-value-bind (s m h d mo y) (decode-universal-time (get-universal-time))
    (format nil "~4,'0D~2,'0D~2,'0D~2,'0D~2,'0D~2,'0D" y mo d h m s)))

(defun %backup-path (path stamp)
  "Return <path>.bak-<STAMP>, or the first of <path>.bak-<STAMP>-1, -2, ...
that names nothing, so an existing backup is never overwritten."
  (%free-name (format nil "~A.bak-~A" (%native path) stamp)))

(defun %read-octets (path)
  "Return the bytes of the file PATH as an octet vector."
  (with-open-file (in path :element-type '(unsigned-byte 8))
    (let* ((buf (make-array (file-length in) :element-type '(unsigned-byte 8)))
           (n (read-sequence buf in)))
      (if (= n (length buf)) buf (subseq buf 0 n)))))

(defun %write-octets (fd octets)
  "Write every byte of the simple octet vector OCTETS to file descriptor FD."
  (sb-sys:with-pinned-objects (octets)
    (let ((sap (sb-sys:vector-sap octets))
          (start 0)
          (end (length octets)))
      (loop while (< start end)
            do (incf start (sb-posix:write fd (sb-sys:sap+ sap start)
                                           (- end start)))))))

(defun %create-file (path octets &key mode uid gid)
  "Create PATH exclusively, write OCTETS to it, and fsync it.

MODE, when given, is set on the descriptor before any byte is written, so the
content never exists under wider permission bits; without MODE the file takes
#o666 under the process umask. UID and GID, when given, are set first where the
process may set them. Returns T, or NIL when PATH already exists. Any other
failure signals sb-posix:syscall-error and removes the partial file."
  (let* ((name (%native path))
         (fd (handler-case
                 (sb-posix:open name
                                (logior sb-posix:o-creat sb-posix:o-excl
                                        sb-posix:o-wronly)
                                (or mode #o666))
               (sb-posix:syscall-error (e)
                 (if (%errno-p e sb-posix:eexist)
                     (return-from %create-file nil)
                     (error e)))))
         (done nil))
    (unwind-protect
         (progn
           (when (and uid gid)
             (handler-case (sb-posix:fchown fd uid gid)
               (sb-posix:syscall-error () nil)))
           (when mode (sb-posix:fchmod fd mode))
           (%write-octets fd octets)
           (sb-posix:fsync fd)
           (setf done t))
      (sb-posix:close fd)
      (unless done (ignore-errors (sb-posix:unlink name))))
    t))

(defun %create-unique (next-name octets &rest keys)
  "Create a file holding OCTETS at the pathname the function NEXT-NAME returns,
calling it again when another process takes that name first, and return the
pathname. KEYS go to %create-file."
  (loop for candidate = (funcall next-name)
        when (apply #'%create-file candidate octets keys)
          return candidate))

(defun %fsync-directory (path)
  "Fsync the directory that holds PATH, so a rename or create in it is durable."
  (let ((fd (sb-posix:open (%native (uiop:pathname-directory-pathname path))
                           sb-posix:o-rdonly)))
    (unwind-protect (sb-posix:fsync fd)
      (sb-posix:close fd))))

(defun %replace-file (path original replacement)
  "Replace the file PATH, whose bytes were ORIGINAL when it was parsed, with
the octets REPLACEMENT. Returns the backup pathname, or NIL when PATH no
longer holds ORIGINAL; NIL leaves PATH, and every file beside it, unchanged.

ORIGINAL goes to a fresh <path>.bak-<stamp>[-N] and REPLACEMENT to a hidden
temp file beside PATH. Both are created with PATH's mode, owner and group
before any byte is written, and both are fsynced. The temp file is renamed
over PATH only after PATH is read again and still equals ORIGINAL; the
directory is fsynced after the rename."
  (let* ((stat (sb-posix:stat (%native path)))
         (keys (list :mode (logand #o7777 (sb-posix:stat-mode stat))
                     :uid (sb-posix:stat-uid stat)
                     :gid (sb-posix:stat-gid stat)))
         (stamp (%timestamp))
         (backup nil)
         (tmp nil)
         (renamed nil))
    (unwind-protect
         (progn
           (setf backup (apply #'%create-unique
                               (lambda () (%backup-path path stamp))
                               original keys))
           (setf tmp (apply #'%create-unique
                            (lambda () (%temp-path path))
                            replacement keys))
           (cond ((equalp original (%read-octets path))
                  (sb-posix:rename (%native tmp) (%native path))
                  (setf renamed t)
                  (%fsync-directory path)
                  backup)
                 (t
                  (sb-posix:unlink (%native backup))
                  nil)))
      (when (and tmp (not renamed))
        (ignore-errors (sb-posix:unlink (%native tmp)))))))

(defun %create-new (path octets)
  "Create PATH, which named nothing when checked, holding OCTETS under the
process umask, fsync it and its directory, and return T. Returns NIL, writing
nothing, when PATH has appeared since."
  (ensure-directories-exist path)
  (when (%create-file path octets)
    (%fsync-directory path)
    t))

;;; IO entry ------------------------------------------------------------------

(defun %as-pathname (designator)
  "Return DESIGNATOR as a pathname, parsing a string as a native namestring."
  (if (pathnamep designator)
      designator
      (uiop:parse-native-namestring designator)))

(defun %read-settings (path)
  "Return (values SETTINGS OCTETS REASON) for PATH, which names something.
SETTINGS is the parsed object and OCTETS the bytes it was parsed from. When
the file is refused, SETTINGS and OCTETS are NIL and REASON is a string: PATH
is a directory, a dangling symlink, not a regular file, unreadable, not
UTF-8, empty, or not valid JSON."
  (let ((name (%native path)))
    (flet ((refuse (control &rest args)
             (return-from %read-settings
               (values nil nil (apply #'format nil control name args)))))
      (multiple-value-bind (kind e) (%file-kind path)
        (case kind
          (:directory (refuse "~A is a directory, not a file; check the settings path"))
          (:dangling (refuse "~A is a symlink to a missing file; check the link target"))
          (:other (refuse "~A is not a regular file; check the settings path"))
          (:unreadable (refuse "~A cannot be read: ~A; check its permissions" e))))
      (let* ((octets (handler-case (%read-octets path)
                       (error (c)
                         (refuse "~A cannot be read: ~A; check its permissions" c))))
             (text (handler-case
                       (sb-ext:octets-to-string octets :external-format :utf-8)
                     (error ()
                       (refuse "~A is not valid UTF-8; check the file's encoding")))))
        (when (zerop (length (string-trim '(#\Space #\Tab #\Newline #\Return) text)))
          (refuse "~A is empty; write {} into it or remove it, then run again"))
        (handler-case (values (jzon:parse text) octets nil)
          (error (c)
            (refuse "~A is not valid JSON: ~A; fix the file, then run again" c)))))))

(defun %shape-problem (settings path)
  "Return a refusal reason when SETTINGS, parsed from PATH, does not have the
shape of a Claude Code settings file, else NIL. The top level is an object,
permissions is absent or an object, and permissions.allow is absent or an
array."
  (let ((name (uiop:native-namestring path)))
    (flet ((problem (what)
             (format nil "~A: ~A; fix the file, then run again" name what)))
      (cond
        ((not (hash-table-p settings))
         (problem "the top level is not a JSON object"))
        (t
         (multiple-value-bind (perms perms-p) (gethash "permissions" settings)
           (cond
             ((not perms-p) nil)
             ((not (hash-table-p perms))
              (problem "\"permissions\" is not a JSON object"))
             (t
              (multiple-value-bind (allow allow-p) (gethash "allow" perms)
                (when (and allow-p (not (%json-array-p allow)))
                  (problem "\"permissions.allow\" is not a JSON array")))))))))))

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
A file that cannot be read, is empty, is not valid JSON, or does not have the
shape of a settings file is refused and left unchanged; so is one that changes
while the run updates it. When no rule is missing nothing is written. DRY-RUN
true reports :checked and writes nothing. A missing file is created with no
backup. An existing file is backed up to <path>.bak-<stamp> and replaced
atomically, with its mode, owner and group kept. Signals an error when
WORKSPACE is not usable."
  (multiple-value-bind (rules ignored) (worktree-envrc-rules workspace extra-roots)
    (let* ((given (%as-pathname settings-path))
           (kind (%file-kind given))
           (existing (not (eq kind :absent)))
           (path (if (eq kind :file) (truename given) given)))
      (flet ((result (action &key missing backup reason)
               (list* :path path
                      :rules rules
                      :missing missing
                      :ignored-roots ignored
                      :backup-path backup
                      :action-taken action
                      (when reason (list :reason reason)))))
        (multiple-value-bind (settings original reason)
            (if existing (%read-settings path) (values nil nil nil))
          (let ((reason (or reason
                            (and existing (%shape-problem settings path)))))
            (when reason
              (return-from install-worktree-permissions
                (result :refused :reason reason))))
          (multiple-value-bind (updated missing) (ensure-allow-rules settings rules)
            (cond
              (dry-run (result :checked :missing missing))
              ((and existing (null missing)) (result :already-present))
              (t
               (let ((rendered (jzon:stringify updated :pretty t)))
                 (when (or (not existing)
                           (and (plusp (length original))
                                (= 10 (aref original (1- (length original))))))
                   (setf rendered (concatenate 'string rendered (string #\Newline))))
                 (handler-case (jzon:parse rendered)
                   (error (e)
                     (error "rendered settings did not parse (~A); ~A is unchanged"
                            e (%native path))))
                 (let ((octets (sb-ext:string-to-octets rendered :external-format :utf-8))
                       (changed (format nil "~A changed while it was being ~
                                             updated; nothing was written, run again"
                                        (%native path))))
                   (if existing
                       (let ((backup (%replace-file path original octets)))
                         (if backup
                             (result :updated :missing missing :backup backup)
                             (result :refused :missing missing :reason changed)))
                       (if (%create-new path octets)
                           (result :created :missing missing)
                           (result :refused :missing missing :reason changed)))))))))))))

;;; Consent gate --------------------------------------------------------------

(defun %yes-p (line)
  "True when LINE, trimmed, is y or yes in any case."
  (and line
       (let ((trimmed (string-trim '(#\Space #\Tab #\Return) line)))
         (or (string-equal trimmed "y") (string-equal trimmed "yes")))))

(defvar *interactive-p* #'interactive-stream-p
  "Function of one stream, true when the consent prompt may read that stream.")

(defun offer-worktree-permissions (&key (mode :interactive) settings-path)
  "Installer step for the worktree .envrc edit rules.

MODE selects the behaviour:
  :skip         return NIL.
  :force        run install-worktree-permissions without asking.
  :interactive  when *interactive-p* is true of *standard-input*, ask [y/N]
                and run the install on y or yes; otherwise return NIL without
                reading. No path is resolved before the answer.

SETTINGS-PATH, when non-NIL, replaces user-settings-path. Returns NIL when
skipped or not asked, (:path NIL :action-taken :declined) when the answer is
not yes, (:path NIL :action-taken :failed :reason TEXT) when the step signals
an error, and otherwise the install-worktree-permissions plist. Never signals
from the step itself, so an installer that calls it still reports."
  (check-type mode (member :skip :force :interactive))
  (let ((args (when settings-path (list :settings-path settings-path))))
    (handler-case
        (ecase mode
          (:skip nil)
          (:force (apply #'install-worktree-permissions args))
          (:interactive
           (when (funcall *interactive-p* *standard-input*)
             (format *standard-output*
                     "~&Add Claude Code allow rules for editing .envrc files in ~
                      git worktrees to the user settings file? [y/N] ")
             (finish-output *standard-output*)
             (if (%yes-p (read-line *standard-input* nil nil))
                 (apply #'install-worktree-permissions args)
                 (list :path nil :action-taken :declined)))))
      (error (e)
        (list :path nil :action-taken :failed :reason (princ-to-string e))))))

;;; Command entry -------------------------------------------------------------

(defun %blank-p (x)
  "True when X is NIL or an empty string."
  (or (null x) (and (stringp x) (zerop (length x)))))

(defun run-worktree-permissions (&key settings-path workspace dry-run)
  "Run install-worktree-permissions, print a report to *standard-output*, and
return an exit code: 0, or 1 when the file is refused or the run signals an
error. With DRY-RUN true, 1 also when any rule is missing. An extra root that
gives no rule is reported and leaves the exit code unchanged. An empty or NIL
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
        (format t "  ignored root: ~S (~A)~%" root
                (nth-value 1 (%canonical-root root))))
      (when backup-path
        (format t "  backup: ~A~%" (uiop:native-namestring backup-path)))
      (when reason
        (format t "  refused: ~A~%" reason))
      (cond ((eq action-taken :refused) 1)
            ((and dry-run missing) 1)
            (t 0)))))
