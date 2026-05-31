;;;; tests/envrc-template/envrc-template-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Lookup tests for the site-wide-preferring .envrc template resolution
;;;; (ENVRC-04): envrc-template-path falls back to the shipped repo template
;;;; when no site-wide file exists, and prefers a per-machine template under
;;;; XDG_CONFIG_HOME when one is present. The site-wide probe is driven by a
;;;; temporary XDG_CONFIG_HOME that is set then restored around the assertion
;;;; so no env-var state leaks across tests.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/envrc-template/envrc-template-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/envrc-template/envrc-template-test
  (:use #:cl #:parachute)
  (:import-from #:dsmr-mcp/src/envrc-template
                #:envrc-template-path
                #:read-envrc-template))

(in-package #:dsmr-mcp/tests/envrc-template/envrc-template-test)

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

(defun %unique-temp-dir (stem)
  "Create and return a fresh, unique temporary directory pathname named for STEM."
  (let ((dir (uiop:ensure-directory-pathname
              (merge-pathnames
               (format nil "~A-~A/" stem (random (expt 2 48)))
               (uiop:temporary-directory)))))
    (ensure-directories-exist dir)
    dir))

(define-test template-path-falls-back-to-shipped
  "With no site-wide template present, envrc-template-path resolves to the
repo's shipped templates/dsmr-mcp.envrc.template."
  (let ((empty (%unique-temp-dir "dsmr-envrc-empty")))
    (unwind-protect
         (with-xdg-config-home ((namestring empty))
           (let ((resolved (envrc-template-path)))
             (is equal "dsmr-mcp.envrc.template" (file-namestring resolved))
             (is equal "templates"
                 (car (last (pathname-directory resolved)))
                 "fallback path is not under templates/")))
      (ignore-errors (uiop:delete-directory-tree empty :validate t)))))

(define-test template-path-prefers-site-wide
  "When ~/.config/dsmr-mcp/envrc.template exists under XDG_CONFIG_HOME,
envrc-template-path returns it instead of the shipped default."
  (let* ((root (%unique-temp-dir "dsmr-envrc-site"))
         (site (merge-pathnames "dsmr-mcp/envrc.template" root)))
    (ensure-directories-exist site)
    (with-open-file (out site :direction :output :if-exists :supersede)
      (write-string "export DSMR_MODE=auto # site-wide marker" out))
    (unwind-protect
         (with-xdg-config-home ((namestring root))
           (let ((resolved (envrc-template-path)))
             (is equal (truename site) (truename resolved)
                 "envrc-template-path did not prefer the site-wide template")
             (true (search "site-wide marker" (read-envrc-template))
                   "read-envrc-template did not read the site-wide file")))
      (ignore-errors (uiop:delete-directory-tree root :validate t)))))
