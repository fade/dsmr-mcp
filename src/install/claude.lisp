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
  (:export #:claude-config-path
           #:wrapper-launcher-path
           #:launcher-if-present
           #:install-into-claude))

(in-package #:dsmr-mcp/src/install/claude)

;;; Path resolution ----------------------------------------------------------

(defun claude-config-path ()
  "Return the pathname of Claude Code's MCP-server config file,
~/.claude.json, resolved against the home directory."
  (merge-pathnames ".claude.json" (user-homedir-pathname)))

(defun wrapper-launcher-path ()
  "Absolute namestring of the lifecycle launch wrapper shipped in the repo,
scripts/dsmr-mcp-launch.sh, resolved against the dsmr-mcp source tree. This
is the command an installed entry invokes so the server boots from the
prebuilt core and self-regenerates it on SBCL/source/dependency drift."
  (namestring
   (merge-pathnames "scripts/dsmr-mcp-launch.sh"
                    (asdf:system-source-directory :dsmr-mcp))))

(defun launcher-if-present ()
  "Return the wrapper-launcher-path when that script actually exists in this
checkout, else NIL — so an install from a partial tree degrades to the
source-load launcher rather than pointing at a missing command."
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
  "Install the canonical dsmr-mcp MCP server entry into the Claude Code
config at PATH (default ~/.claude.json), applying the ON-EXISTING-CL-MCP
policy (:keep, :remove, or :replace) to any pre-existing cl-mcp entry.

When PATH does not exist it is created from a minimal config. When it
does exist it is parsed, transformed by the pure config core, and written
back pretty-printed. A timestamped backup (<path>.bak-YYYYMMDDHHMMSS) is
written from the original bytes BEFORE the new content is written; if the
backup cannot be written the install aborts and PATH is left untouched.

Before committing the write the rendered JSON is re-parsed; if it does not
parse the original file is left in place (the backup, if any, is retained)
and an error is signalled.

Returns a plist:
  :path                  the config pathname written
  :backup-path           the backup pathname, or NIL when PATH was created fresh
  :cl-mcp-was-present     T when the original config already had a cl-mcp entry
  :action-taken          one of :created, :updated-kept-cl-mcp,
                         :updated-removed-cl-mcp, :updated-no-cl-mcp"
  (check-type on-existing-cl-mcp (member :keep :remove :replace))
  (let* ((existed (and (probe-file path) t))
         (original (and existed (%read-config path)))
         (cl-mcp-present (and original (config:has-cl-mcp-p original)))
         (updated (config:ensure-server original
                                        :on-existing-cl-mcp on-existing-cl-mcp
                                        :launcher (launcher-if-present)))
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
        ;; Confirm the backup actually landed before mutating the original.
        (unless (probe-file backup)
          (error "install-into-claude: backup ~A was not created; ~
                  refusing to overwrite ~A."
                 (namestring backup) (namestring path))))
      ;; Write the new content.
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
                  (t :updated-no-cl-mcp))))))
