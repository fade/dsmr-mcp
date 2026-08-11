;;;; tests/fs/fs-verbs-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Tests for VERB-03/04/05: fs-read-file, fs-write-file, fs-list-directory
;;;; round-trips against a temp directory under the session root.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/fs/fs-verbs-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/fs/fs-verbs-test
  (:use #:cl #:zebra)
  (:import-from #:dsmr-mcp/src/state
                #:get-tool-instance)
  (:import-from #:dsmr-mcp/src/tools/base
                #:tool-handle)
  (:import-from #:dsmr-mcp/tests/support/fs-fixture
                #:with-temp-project-root
                #:write-fixture-file))

(in-package #:dsmr-mcp/tests/fs/fs-verbs-test)

;;; Helper: make a simple equal-keyed args hash-table ------------------------

(defun make-args (&rest kvs)
  (let ((h (make-hash-table :test 'equal)))
    (loop for (k v) on kvs by #'cddr
          do (setf (gethash k h) v))
    h))

;;; VERB-03 + VERB-04: write then read round-trip ----------------------------

(define-test write-then-read-round-trips
  "Writing a file and reading it back returns the same content (VERB-04/VERB-03)."
  (with-temp-project-root (session root)
    (let* ((rel-path "notes.txt")
           (content  "Hello, round-trip!")
           (abs-path (namestring (merge-pathnames rel-path root)))
           ;; VERB-04: write
           (write-tool (get-tool-instance session "fs-write-file"))
           (write-resp (tool-handle write-tool 1 (make-args "path" abs-path "content" content)))
           (write-res  (gethash "result" write-resp))
           ;; VERB-03: read back
           (read-tool  (get-tool-instance session "fs-read-file"))
           (read-resp  (tool-handle read-tool 2 (make-args "path" abs-path)))
           (read-res   (gethash "result" read-resp)))
      ;; Write should succeed
      (false (gethash "isError" write-res))
      (true  (gethash "success"  write-res))
      ;; Read should return the same content
      (false (gethash "isError"  read-res))
      (is string= content (gethash "text" read-res)))))

;;; VERB-05: list directory shows written file --------------------------------

(define-test list-directory-shows-written-file
  "A file written via fs-write-file appears in the fs-list-directory output (VERB-05)."
  (with-temp-project-root (session root)
    (let* ((filename "listed.txt")
           (abs-path (namestring (merge-pathnames filename root)))
           ;; Write the file
           (write-tool (get-tool-instance session "fs-write-file"))
           (ignored    (tool-handle write-tool 1 (make-args "path" abs-path "content" "x")))
           ;; List the root directory
           (list-tool  (get-tool-instance session "fs-list-directory"))
           (list-resp  (tool-handle list-tool 2 (make-args "path" (namestring root))))
           (list-res   (gethash "result" list-resp))
           (entries    (gethash "entries" list-res)))
      (declare (ignore ignored))
      (false (gethash "isError" list-res))
      (true (find filename
                  (map 'list (lambda (e) (gethash "name" e)) entries)
                  :test #'string=)))))

;;; VERB-04 guard: write refuses to overwrite existing .lisp -----------------

(define-test write-rejects-existing-lisp-source
  "fs-write-file refuses to overwrite an existing .lisp file (Pitfall 6)."
  (with-temp-project-root (session root)
    (let* ((lisp-path (namestring (merge-pathnames "existing.lisp" root)))
           ;; Create the .lisp file manually first
           (ignored   (write-fixture-file root "existing.lisp" "(defun foo () t)"))
           ;; Attempt to overwrite via fs-write-file
           (write-tool (get-tool-instance session "fs-write-file"))
           (resp       (tool-handle write-tool 1 (make-args "path" lisp-path "content" "overwrite")))
           (result     (gethash "result" resp)))
      (declare (ignore ignored))
      (true (gethash "isError" result))
      (is string= "lisp-overwrite-refused" (gethash "error_type" result)))))
