;;;; src/envrc-template.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Resolves which `.envrc` template dsmr-mcp should use when bringing a
;;;; project up. A per-machine personalised template (written by the
;;;; installer's site-wide-defaults step) takes precedence over the
;;;; verbatim default that ships in the repo, so an operator who set their
;;;; own Slynk host/port/workspace defaults gets them in every project they
;;;; scaffold or bring up — without editing the repo.
;;;;
;;;; The template is copied verbatim into a project's `.envrc`; it uses
;;;; shell `${VAR:-default}` expansion, never `{{key}}` placeholders, so no
;;;; per-project rendering is required.

(defpackage #:dsmr-mcp/src/envrc-template
  (:use #:cl)
  (:export #:envrc-template-path
           #:read-envrc-template
           #:site-defaults-template-path))

(in-package #:dsmr-mcp/src/envrc-template)

(defun %xdg-config-home ()
  "Return the XDG config home directory as a directory pathname.
Honours XDG_CONFIG_HOME when set, else falls back to ~/.config per the
XDG Base Directory spec."
  (uiop:ensure-directory-pathname
   (or (uiop:getenv "XDG_CONFIG_HOME")
       (merge-pathnames ".config" (user-homedir-pathname)))))

(defun site-defaults-template-path ()
  "Return the per-machine `.envrc` template pathname under the XDG config home
(~/.config/dsmr-mcp/envrc.template). Returned unconditionally — the file need
not exist. The installer's site-wide-defaults step writes here; the runtime
lookup prefers it when present."
  (merge-pathnames "dsmr-mcp/envrc.template" (%xdg-config-home)))

(defun envrc-template-path ()
  "Return the pathname of the `.envrc` template to use.
Prefers the per-machine site-wide template at ~/.config/dsmr-mcp/envrc.template
when it exists; otherwise falls back to the verbatim default shipped in the
repo at templates/dsmr-mcp.envrc.template."
  (let ((site-path (site-defaults-template-path)))
    (if (probe-file site-path)
        site-path
        (asdf:system-relative-pathname
         "dsmr-mcp" "templates/dsmr-mcp.envrc.template"))))

(defun read-envrc-template ()
  "Return the `.envrc` template content as a string (site-wide-preferring)."
  (uiop:read-file-string (envrc-template-path)))
