;;;; tests/install/defaults-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Parachute tests for the installer's site-wide .envrc defaults
;;;; (ENVRC-08..09). The pure render and the non-interactive gates are covered
;;;; directly; the write/skip tests bind XDG_CONFIG_HOME to a fresh temp dir for
;;;; their dynamic extent so the write target is isolated and cleaned up — the
;;;; operator's real ~/.config/dsmr-mcp/envrc.template is never touched.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/install/defaults-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/install/defaults-test
  (:use #:cl #:parachute)
  (:import-from #:dsmr-mcp/src/install/defaults
                #:render-site-defaults-template
                #:collect-site-defaults
                #:write-site-defaults-template
                #:install-envrc-defaults)
  (:import-from #:dsmr-mcp/src/envrc-template
                #:site-defaults-template-path))

(in-package #:dsmr-mcp/tests/install/defaults-test)

;;; Temp-XDG helpers ----------------------------------------------------------

(defun %unique-temp-dir (stem)
  "Create and return a fresh, unique temporary directory pathname named for STEM."
  (let ((dir (uiop:ensure-directory-pathname
              (merge-pathnames
               (format nil "~A-~A/" stem (random (expt 2 48)))
               (uiop:temporary-directory)))))
    (ensure-directories-exist dir)
    dir))

(defmacro with-xdg-config-home ((dir) &body body)
  "Bind the XDG_CONFIG_HOME environment variable to DIR (a namestring) for the
dynamic extent of BODY, restoring its prior value (or unset state) on exit."
  (let ((prior (gensym "PRIOR")) (had (gensym "HAD")))
    `(let* ((,prior (uiop:getenv "XDG_CONFIG_HOME"))
            (,had ,prior))
       (unwind-protect
            (progn
              (sb-posix:setenv "XDG_CONFIG_HOME" ,dir 1)
              ,@body)
         (if ,had
             (sb-posix:setenv "XDG_CONFIG_HOME" ,prior 1)
             (sb-posix:unsetenv "XDG_CONFIG_HOME"))))))

;;; Pure render --------------------------------------------------------------

(define-test render-defaults-substitutes-port
  "A supplied Slynk port lands in the rendered template."
  (let ((s (render-site-defaults-template :slynk-port 4123)))
    (true (search "4123" s) "supplied port present in output")))

(define-test render-defaults-no-placeholders
  "The rendered output is shell, never a render-template target."
  (let ((s (render-site-defaults-template :slynk-port 4123)))
    (false (search "{{" s) "no {{ placeholder substring")))

(define-test render-defaults-uses-shipped-when-nil
  "With no args, render falls back to the shipped defaults."
  (let ((s (render-site-defaults-template)))
    (true (search "127.0.0.1" s) "shipped Slynk host")
    (true (search "4005" s) "shipped Slynk port")
    (true (search "DSMR_MODE=auto" s) "shipped mode")))

;;; Non-interactive gates -----------------------------------------------------

(define-test collect-noninteractive-returns-nil
  "collect-site-defaults :interactive nil returns nil without reading stdin."
  (false (collect-site-defaults :interactive nil)))

(define-test install-envrc-defaults-skip-noop
  "install-envrc-defaults :mode :skip is a no-op: returns nil and writes
nothing — the site path stays absent under a fresh temp XDG home."
  (let ((root (%unique-temp-dir "dsmr-defaults-skip")))
    (unwind-protect
         (with-xdg-config-home ((namestring root))
           (false (install-envrc-defaults :mode :skip) "skip returns nil")
           (false (probe-file (site-defaults-template-path))
                  "skip wrote no template file"))
      (ignore-errors (uiop:delete-directory-tree root :validate t)))))

;;; Atomic write --------------------------------------------------------------

(define-test write-roundtrips
  "write-site-defaults-template creates the file under a temp XDG home and its
content matches the render output."
  (let ((root (%unique-temp-dir "dsmr-defaults-write")))
    (unwind-protect
         (with-xdg-config-home ((namestring root))
           (let* ((defaults (list :slynk-port "4321"))
                  (path (write-site-defaults-template defaults)))
             (true (probe-file path) "template file created")
             (is equal
                 (apply #'render-site-defaults-template defaults)
                 (uiop:read-file-string path)
                 "written content equals render output")))
      (ignore-errors (uiop:delete-directory-tree root :validate t)))))
