;;;; src/install/claude.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; IO layer for installing dsmr-mcp into Claude Code's ~/.claude.json.
;;;; Resolves the config path, reads + parses with jzon, applies the pure
;;;; config core, makes a timestamped backup, validates the rendered result
;;;; by re-parsing it, then writes it back. The config path is injectable so
;;;; the IO layer is testable against a temp file (never the real
;;;; ~/.claude.json).

(defpackage #:dsmr-mcp/src/install/claude
  (:use #:cl)
  (:local-nicknames (#:jzon #:com.inuoe.jzon)
                    (#:config #:dsmr-mcp/src/install/config))
  (:import-from #:sb-posix)
  (:export #:claude-config-path
           #:dsmr-home
           #:host-home-p
           #:account-config-p
           #:wrapper-launcher-path
           #:launcher-if-present
           #:install-into-claude))

(in-package #:dsmr-mcp/src/install/claude)

;;; Path resolution ----------------------------------------------------------

(defun claude-config-path ()
  "Return the pathname of Claude Code's MCP-server config file,
~/.claude.json, resolved against the home directory."
  (merge-pathnames ".claude.json" (user-homedir-pathname)))

(defun %env-directory (name)
  "Return environment variable NAME as a directory pathname, or NIL when it is
unset or empty. Signal an error when its value is not an absolute path."
  (let ((value (uiop:getenv name)))
    (when (and value (plusp (length value)))
      (unless (uiop:absolute-pathname-p value)
        (error "~A is ~S, which is not an absolute path" name value))
      (uiop:ensure-directory-pathname value))))

(defun dsmr-home ()
  "Return the deploy home as a directory pathname: DSMR_HOME when set and
non-empty, else XDG_DATA_HOME/dsmr-mcp/, else ~/.local/share/dsmr-mcp/.
Signal an error when the variable used is not an absolute path."
  (or (%env-directory "DSMR_HOME")
      (let ((data (%env-directory "XDG_DATA_HOME")))
        (and data (merge-pathnames "dsmr-mcp/" data)))
      (merge-pathnames ".local/share/dsmr-mcp/" (user-homedir-pathname))))

(defun %resolved (path)
  "Return PATH as a namestring with every symlink, `.' and `..' resolved and no
trailing slash, as `realpath -m' prints it; components that do not exist are
kept as written."
  (uiop:run-program (list "realpath" "-m" "--" (uiop:native-namestring path))
                    :output '(:string :stripped t)))

(defun host-home-p (home)
  "Return true when HOME is the account's own deploy home: $HOME/.local/share/dsmr-mcp/,
or $XDG_DATA_HOME/dsmr-mcp/ when XDG_DATA_HOME resolves to a directory under
$HOME. Paths are compared resolved. Every other home is a scratch home. The
rule matches host_home_p in scripts/release-paths.sh."
  (let* ((user (%resolved (user-homedir-pathname)))
         (home (%resolved home))
         (data (%env-directory "XDG_DATA_HOME")))
    (or (string= home (format nil "~A/.local/share/dsmr-mcp" user))
        (and data
             (let ((data (%resolved data)))
               (and (uiop:string-prefix-p (format nil "~A/" user) (format nil "~A/" data))
                    (string= home (format nil "~A/dsmr-mcp" data))))))))

(defun %file-identity (path)
  "Return (device . inode) of the file PATH names, following symlinks, or NIL
when there is none."
  (let ((stat (ignore-errors (sb-posix:stat (uiop:native-namestring path)))))
    (and stat (cons (sb-posix:stat-dev stat) (sb-posix:stat-ino stat)))))

(defun account-config-p (path)
  "Return true when PATH is the account's Claude Code config, ~/.claude.json:
the same file, a symlink or hard link to it included, or, when either file is
absent, the same resolved path."
  (let* ((account (claude-config-path))
         (a (%file-identity path))
         (b (%file-identity account)))
    (if (and a b)
        (equal a b)
        (string= (%resolved path) (%resolved account)))))

(defun wrapper-launcher-path ()
  "Return the namestring of <dsmr-home>current/bin/dsmr-mcp-launch, whether or
not it exists. The path goes through the current link, never its target, so a
deploy or rollback changes what runs without re-registering."
  (namestring (merge-pathnames "current/bin/dsmr-mcp-launch" (dsmr-home))))

(defun launcher-if-present ()
  "Return wrapper-launcher-path when the launcher exists, else NIL."
  (let ((p (wrapper-launcher-path)))
    (when (probe-file p) p)))

;;; Timestamp ----------------------------------------------------------------

(defun %timestamp ()
  "Return a YYYYMMDDHHMMSS string for the current local time.
Built from get-universal-time / decode-universal-time so the stamp never
depends on the shell or external tools."
  (multiple-value-bind (sec min hour day month year)
      (decode-universal-time (get-universal-time))
    (format nil "~4,'0D~2,'0D~2,'0D~2,'0D~2,'0D~2,'0D"
            year month day hour min sec)))

(defun %backup-path (path)
  "Return the timestamped backup pathname for PATH: <path>.bak-YYYYMMDDHHMMSS."
  (let ((ns (namestring path)))
    (pathname (format nil "~A.bak-~A" ns (%timestamp)))))

;;; Read / parse -------------------------------------------------------------

(defun %read-config (path)
  "Return the parsed jzon object at PATH, or NIL when PATH does not exist.
Signals on a malformed existing file so a corrupt config is never silently
overwritten."
  (when (probe-file path)
    (jzon:parse (uiop:read-file-string path))))

;;; Public entry -------------------------------------------------------------

(defun install-into-claude (&key (path (claude-config-path))
                                 (on-existing-cl-mcp :keep))
  "Write the dsmr-mcp server entry, naming the release launcher
<dsmr-home>current/bin/dsmr-mcp-launch, into the Claude Code config at PATH
(default ~/.claude.json). Apply ON-EXISTING-CL-MCP (:keep, :remove or :replace)
to any cl-mcp entry. An existing dsmr-mcp entry keeps its env; see
dsmr-mcp/src/install/config:ensure-server.

Signal an error, before PATH is read or backed up, when the deploy home is a
scratch home (see host-home-p) and PATH is the account's config (see
account-config-p), or when the launcher does not exist. Create PATH when absent. Otherwise copy it to
<path>.bak-YYYYMMDDHHMMSS first and abort, leaving PATH untouched, when the
backup is missing. Signal an error, leaving PATH untouched, when the rendered
JSON does not re-parse.

Return a plist:
  :path                the config pathname written
  :backup-path         the backup pathname, or NIL when PATH was created
  :cl-mcp-was-present  T when the original config had a cl-mcp entry
  :action-taken        one of :created, :updated-kept-cl-mcp,
                       :updated-removed-cl-mcp, :updated-no-cl-mcp"
  (check-type on-existing-cl-mcp (member :keep :remove :replace))
  (let ((home (dsmr-home)))
    (when (and (not (host-home-p home)) (account-config-p path))
      (error "deploy home ~A is a scratch home but ~A is the account's Claude Code config; ~
              register a scratch home with make register DSMR_HOME=<scratch home> CLAUDE_CONFIG=<scratch file>"
             (namestring home) (namestring path))))
  (let ((launcher (launcher-if-present)))
    (unless launcher
      (error "no deployed release at ~Acurrent; run make deploy REF=<sha> before registering"
             (namestring (dsmr-home))))
    (let* ((existed (and (probe-file path) t))
           (original (and existed (%read-config path)))
           (cl-mcp-present (and original (config:has-cl-mcp-p original)))
           (updated (config:ensure-server original
                                          :on-existing-cl-mcp on-existing-cl-mcp
                                          :launcher launcher))
           (rendered (jzon:stringify updated :pretty t)))
      ;; Validate the rendered output by re-parsing it before any write.
      (handler-case (jzon:parse rendered)
        (error (e)
          (error "install-into-claude: rendered config did not re-parse; ~
                  leaving ~A untouched. (~A)" (namestring path) e)))
      ;; Back up the existing file from its original bytes before writing.
      (let ((backup nil))
        (when existed
          (setf backup (%backup-path path))
          (uiop:copy-file path backup)
          (unless (probe-file backup)
            (error "install-into-claude: backup ~A was not created; ~
                    refusing to overwrite ~A."
                   (namestring backup) (namestring path))))
        (with-open-file (out path :direction :output
                                  :if-exists :supersede
                                  :if-does-not-exist :create
                                  :external-format :utf-8)
          (write-string rendered out))
        (list :path path
              :backup-path backup
              :cl-mcp-was-present (and cl-mcp-present t)
              :action-taken
              (cond ((not existed) :created)
                    ((and cl-mcp-present (eq on-existing-cl-mcp :keep))
                     :updated-kept-cl-mcp)
                    ((and cl-mcp-present
                          (member on-existing-cl-mcp '(:remove :replace)))
                     :updated-removed-cl-mcp)
                    (t :updated-no-cl-mcp)))))))
