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
  (:use #:cl #:zebra)
  (:import-from #:dsmr-mcp/src/project-root
                #:allowed-read-path
                #:ensure-write-path)
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

(define-test symlink-parent-of-new-file-write-rejected
  "A write to a nonexistent file whose parent directory is a symlink pointing
outside the session root must be rejected, even though the leaf file does not
exist and truename on the full path would fail.
Regression for the nonexistent-leaf write-jail escape."
  (let* ((outside-dir (%make-temp-directory)))
    (unwind-protect
         (with-temp-project-root (_session root)
           ;; /root/evil -> /outside/  (evil is a directory symlink, not a file symlink)
           (let ((link-name (namestring (make-pathname :name "evil" :defaults root))))
             (sb-posix:symlink (namestring outside-dir) link-name)
             ;; Attempt to write a NEW file under the symlinked directory.
             ;; newfile.txt does not exist, so truename on the full path fails —
             ;; the fix must resolve via the parent directory instead.
             (let* ((target (concatenate 'string link-name "/newfile.txt"))
                    (result (ensure-write-path target root)))
               ;; Must return NIL: the real write destination is outside the root.
               (false result
                      "ensure-write-path must reject a new file under a symlinked-out-of-root parent"))))
      (uiop:delete-directory-tree outside-dir :validate t :if-does-not-exist :ignore))))

(define-test symlink-parent-of-new-file-read-rejected
  "A read of a nonexistent file whose parent directory is a symlink pointing
outside the session root must be rejected.
Regression for the nonexistent-leaf read-allow-list escape."
  (let* ((outside-dir (%make-temp-directory)))
    (unwind-protect
         (with-temp-project-root (_session root)
           ;; /root/evil -> /outside/  (evil is a directory symlink)
           (let ((link-name (namestring (make-pathname :name "evil" :defaults root))))
             (sb-posix:symlink (namestring outside-dir) link-name)
             ;; Attempt to read a nonexistent file under the symlinked directory.
             (let* ((target (concatenate 'string link-name "/secret.txt"))
                    (result (allowed-read-path target root)))
               ;; Must return NIL: the real path resolves outside the root.
               (false result
                      "allowed-read-path must reject a nonexistent file under a symlinked-out-of-root parent"))))
      (uiop:delete-directory-tree outside-dir :validate t :if-does-not-exist :ignore))))

(define-test symlink-parent-of-deeply-nested-new-file-write-rejected
  "A write to a nonexistent file whose path descends through MULTIPLE
nonexistent components below a symlinked-out-of-root ancestor must be
rejected. truename fails on the full path AND on the immediate parent, so
resolving only the immediate parent leaves the path lexically inside the
root and the writer's ensure-directories-exist would create the missing
directories THROUGH the symlink, escaping the jail.
Regression for the multi-level nonexistent-tail write-jail escape."
  (let* ((outside-dir (%make-temp-directory)))
    (unwind-protect
         (with-temp-project-root (_session root)
           ;; /root/evil -> /outside/  (evil is a directory symlink)
           (let ((link-name (namestring (make-pathname :name "evil" :defaults root))))
             (sb-posix:symlink (namestring outside-dir) link-name)
             ;; newdir AND newfile.txt both do not exist (two missing levels).
             (let* ((target (concatenate 'string link-name "/newdir/newfile.txt"))
                    (result (ensure-write-path target root)))
               (false result
                      "ensure-write-path must reject a deeply-nested new file under a symlinked-out-of-root ancestor"))))
      (uiop:delete-directory-tree outside-dir :validate t :if-does-not-exist :ignore))))

(define-test symlink-parent-of-deeply-nested-new-file-read-rejected
  "A read of a nonexistent file whose path descends through MULTIPLE
nonexistent components below a symlinked-out-of-root ancestor must be
rejected.
Regression for the multi-level nonexistent-tail read-allow-list escape."
  (let* ((outside-dir (%make-temp-directory)))
    (unwind-protect
         (with-temp-project-root (_session root)
           ;; /root/evil -> /outside/  (evil is a directory symlink)
           (let ((link-name (namestring (make-pathname :name "evil" :defaults root))))
             (sb-posix:symlink (namestring outside-dir) link-name)
             ;; newdir AND secret.txt both do not exist (two missing levels).
             (let* ((target (concatenate 'string link-name "/newdir/secret.txt"))
                    (result (allowed-read-path target root)))
               (false result
                      "allowed-read-path must reject a deeply-nested new file under a symlinked-out-of-root ancestor"))))
      (uiop:delete-directory-tree outside-dir :validate t :if-does-not-exist :ignore))))

(define-test new-file-under-root-without-symlink-allowed
  "Writing or reading a new (nonexistent) file at a path that is lexically
inside the session root and involves no symlinks must remain allowed.
Ensures the symlink-parent fix does not break the common new-file case."
  (with-temp-project-root (_session root)
    ;; A nonexistent file directly under the root
    (let* ((target (namestring (merge-pathnames "brand-new.lisp" root)))
           (write-result (ensure-write-path target root))
           (read-result  (allowed-read-path target root)))
      (true write-result "ensure-write-path must allow a new file directly under the root")
      (true read-result  "allowed-read-path must allow a new file directly under the root"))
    ;; A nonexistent file under a new (also nonexistent) subdirectory
    (let* ((target (namestring (merge-pathnames "newsubdir/brand-new.lisp" root)))
           (write-result (ensure-write-path target root)))
      (true write-result "ensure-write-path must allow a new file in a new subdirectory"))))
