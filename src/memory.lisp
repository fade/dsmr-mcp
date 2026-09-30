;;;; src/memory.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Finding and reading Claude Code memory pages: which store belongs to a
;;;; session, which files in a store may be read, and what a page's
;;;; frontmatter says about its status.

(defpackage #:dsmr-mcp/src/memory
  (:use #:cl)
  (:import-from #:cl-ppcre
                #:split)
  (:import-from #:dsmr-mcp/src/log
                #:log-event)
  (:export #:*claude-config-dir*
           #:claude-config-dir
           #:projects-directory
           #:store-name-for
           #:repository-root
           #:project-store-directory
           #:memory-page-path
           #:list-store-pages))

(in-package #:dsmr-mcp/src/memory)

(defvar *claude-config-dir* nil)

(defun claude-config-dir () nil)

(defun projects-directory () nil)

(defun store-name-for (directory) (declare (ignore directory)) "")

(defun repository-root (directory) (declare (ignore directory)) nil)

(defun project-store-directory (session-root) (declare (ignore session-root)) nil)

(defun memory-page-path (file projects-dir) (declare (ignore file projects-dir)) nil)

(defun list-store-pages (store-dir projects-dir)
  (declare (ignore store-dir projects-dir))
  (values nil nil 0))
