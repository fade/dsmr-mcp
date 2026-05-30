;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; scripts/dev-boot.lisp
;;;;
;;;; Lisp half of the dsmr-mcp development image. Loaded by scripts/dev-boot.sh
;;;; AFTER quicklisp's setup.lisp. Brings up a live dsmr-mcp image with a Slynk
;;;; listener so Claude Code's dsmr-mcp MCP server (running in :attached mode)
;;;; can route its REPL-backed verbs — repl-eval, run-tests, inspect-*,
;;;; attached code-find — into THIS image, where the project's definitions,
;;;; packages, and state already exist. Dogfooding dsmr-mcp on itself.
;;;;
;;;; Env (set by dev-boot.sh, read here via uiop:getenv):
;;;;   SLYNK_PORT     listener port      (default 4006)
;;;;   SLYNK_HOST     listener address   (default 127.0.0.1)
;;;;   LISP_WORKSPACE local-projects tree for the asdf source-registry
;;;;
;;;; The image idles on the main thread until the stop sentinel
;;;; /tmp/dsmr-mcp-dev-stop appears (touch it for a graceful shutdown), or
;;;; until the process is killed.

(in-package #:cl-user)

(defparameter *stop-sentinel* "/tmp/dsmr-mcp-dev-stop")

(defun dev-getenv (name default)
  (let ((v (uiop:getenv name)))
    (if (and v (plusp (length v))) v default)))

;;; Defensive tilde expansion: some shells export LISP_WORKSPACE as a literal
;;; "~/..." that never expanded. Resolve a leading ~ to the home directory so
;;; the source-registry push points at a real tree.
(defun expand-tilde (path)
  (if (and (plusp (length path)) (char= (char path 0) #\~))
      (namestring (merge-pathnames (subseq path 2)
                                   (user-homedir-pathname)))
      path))

(let* ((workspace (expand-tilde (dev-getenv "LISP_WORKSPACE"
                                            (namestring
                                             (merge-pathnames "SourceCode/lisp/"
                                                              (user-homedir-pathname))))))
       (workspace (uiop:ensure-directory-pathname workspace)))
  (pushnew workspace asdf:*central-registry* :test #'equal)
  (format *error-output* "~&[dev-boot] source-registry root: ~A~%" workspace))

;;; Load the project. Deps (jzon, hunchentoot, cl-ppcre, slynk, …) resolve via
;;; the quicklisp dist + the workspace registry. Compilation chatter goes to
;;; *error-output* so it never masquerades as anything structured.
(format *error-output* "~&[dev-boot] loading :dsmr-mcp …~%")
(let ((*standard-output* *error-output*))
  (asdf:load-system :dsmr-mcp))
(format *error-output* "~&[dev-boot] :dsmr-mcp loaded (version ~A)~%"
        (funcall (read-from-string "dsmr-mcp:version")))

;;; Dev mode defaults to debug logging. set-log-level-from-env already read
;;; DSMR_LOG_LEVEL into *log-level* at load; sync the log4cl root logger so the
;;; debug records actually emit (and the appender is pinned off *debug-io*).
(let* ((level-name (string-downcase (dev-getenv "DSMR_LOG_LEVEL" "debug")))
       (level (cond ((string= level-name "debug") :debug)
                    ((string= level-name "info")  :info)
                    ((string= level-name "warn")  :warn)
                    ((string= level-name "error") :error)
                    (t :debug))))
  (funcall (read-from-string "dsmr-mcp/src/log:configure-log4cl-for-server") level)
  (format *error-output* "~&[dev-boot] log level: ~A~%" level))

;;; Start the Slynk listener the MCP server attaches to.
(let ((host (dev-getenv "SLYNK_HOST" "127.0.0.1"))
      (port (parse-integer (dev-getenv "SLYNK_PORT" "4006"))))
  (require :slynk)
  (let ((*standard-output* *error-output*))
    (funcall (read-from-string "slynk:create-server")
             :interface host :port port :dont-close t))
  (format *error-output*
          "~&[dev-boot] slynk listening on ~A:~D — set DSMR_SLYNK_ATTACH=~A:~D~%"
          host port host port)
  (format *error-output*
          "~&[dev-boot] image up. Stop: touch ~A (graceful) or kill the process.~%"
          *stop-sentinel*))

;;; Keep the image alive. Slynk serves from its own threads; the main thread
;;; idles until the stop sentinel appears.
(loop
  (when (probe-file *stop-sentinel*)
    (format *error-output* "~&[dev-boot] stop sentinel seen — exiting.~%")
    (ignore-errors (delete-file *stop-sentinel*))
    (uiop:quit 0))
  (sleep 2))
