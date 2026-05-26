;;;; tests/fs/symlink-escape-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; D-14: a symlink under the root that resolves outside it is rejected.
;;;; truename runs before the uiop:subpathp containment check.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/fs/symlink-escape-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/fs/symlink-escape-test
  (:use #:cl #:parachute)
  (:import-from #:dsmr-mcp/src/project-root
                #:allowed-read-path)
  (:import-from #:dsmr-mcp/tests/support/fs-fixture
                #:with-temp-project-root
                #:write-fixture-file
                #:%make-temp-directory))

(in-package #:dsmr-mcp/tests/fs/symlink-escape-test)

(define-test symlink-pointing-outside-root-rejected
  "D-14: a symlink inside the session root that resolves outside it is rejected.
truename must run before the containment check so the resolved path is tested."
  ;; Create an OUTSIDE temp dir with a file in it
  (let* ((outside-dir  (%make-temp-directory))
         (outside-file (merge-pathnames "secret.txt" outside-dir)))
    (unwind-protect
         (progn
           ;; Write a known payload to the outside file
           (with-open-file (out outside-file :direction :output :if-exists :supersede
                                             :if-does-not-exist :create :element-type 'character)
             (write-string "secret" out))
           (with-temp-project-root (session root)
             ;; Place a symlink inside the root that points to the outside file
             (let ((link-pn (merge-pathnames "escape-link" root)))
               ;; Use sb-posix:symlink for POSIX symlink creation (SBCL-specific,
               ;; acceptable since this project targets SBCL >=2.5)
               (sb-posix:symlink (namestring outside-file) (namestring link-pn))
               ;; allowed-read-path must return NIL because truename resolves the symlink
               ;; to the outside file BEFORE the containment check (D-14)
               (false (allowed-read-path (namestring link-pn) root)))))
      (uiop:delete-directory-tree outside-dir :validate t :if-does-not-exist :ignore))))
