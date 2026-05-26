;;;; tests/fs/sandbox-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Tests for SAFETY-01, SAFETY-02, SAFETY-03:
;;;; read allow-list (root + ASDF source dirs), write jail, 2 MB cap.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/fs/sandbox-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/fs/sandbox-test
  (:use #:cl #:parachute)
  (:import-from #:dsmr-mcp/src/project-root
                #:allowed-read-path
                #:ensure-write-path)
  (:import-from #:dsmr-mcp/src/fs
                #:read-file-string
                #:*fs-read-max-bytes*)
  (:import-from #:dsmr-mcp/tests/support/fs-fixture
                #:with-temp-project-root
                #:write-fixture-file))

(in-package #:dsmr-mcp/tests/fs/sandbox-test)

;;; SAFETY-01: path under root is allowed for read ----------------------------

(define-test read-allows-path-under-root
  "A file under the session root is admitted by allowed-read-path."
  (with-temp-project-root (session root)
    (let* ((pn  (write-fixture-file root "hello.txt" "content"))
           (res (allowed-read-path (namestring pn) root)))
      (true res)
      (is string= (namestring pn) (namestring res)))))

;;; SAFETY-01/02: path outside root and outside ASDF dirs is rejected ---------

(define-test read-rejects-path-outside-allow-list
  "A path outside the session root and all ASDF source dirs returns NIL."
  (with-temp-project-root (session root)
    ;; /etc/passwd is definitely outside root and outside ASDF source dirs
    (false (allowed-read-path "/etc/passwd" root))))

;;; SAFETY-02: ASDF source dir is allowed for read ----------------------------

(define-test read-allows-asdf-source-dir
  "A path under a registered ASDF source dir is admitted for reading."
  ;; dsmr-mcp itself is registered; its src/state.lisp should be readable
  (with-temp-project-root (session root)
    (let* ((dsmr-src (asdf:system-source-directory :dsmr-mcp))
           (state-pn (merge-pathnames "src/state.lisp" dsmr-src)))
      ;; Only run this check if the file exists (it should)
      (when (probe-file state-pn)
        (true (allowed-read-path (namestring state-pn) root))))))

;;; D-13: ensure-write-path rejects ASDF source dirs -------------------------

(define-test write-rejects-asdf-source-dir
  "ensure-write-path returns NIL for a path in an ASDF source dir (read-only)."
  (with-temp-project-root (session root)
    ;; dsmr-mcp/src/ is an ASDF source dir — writes to it must be rejected
    (let* ((dsmr-src (asdf:system-source-directory :dsmr-mcp))
           (state-pn (merge-pathnames "src/state.lisp" dsmr-src)))
      (false (ensure-write-path (namestring state-pn) root)))))

;;; SAFETY-03: D-17 2 MB read cap -------------------------------------------

(define-test read-over-cap-truncates
  "Reading a file larger than *fs-read-max-bytes* returns truncated-p true."
  (with-temp-project-root (session root)
    ;; Create a file whose content exceeds the cap
    (let* ((big-content (make-string (1+ *fs-read-max-bytes*) :initial-element #\a))
           (pn          (write-fixture-file root "big.txt" big-content)))
      (multiple-value-bind (text truncated file-len read-len)
          (read-file-string pn)
        (true truncated)
        (is = *fs-read-max-bytes* read-len)
        (is = (1+ *fs-read-max-bytes*) file-len)
        (is = *fs-read-max-bytes* (length text))))))

;;; SAFETY-03: offset/limit pagination ----------------------------------------

(define-test read-with-offset-and-limit
  "offset and limit slice the read correctly; the 2 MB cap is not hit."
  (with-temp-project-root (session root)
    (let ((pn (write-fixture-file root "slice.txt" "abcdefghij")))
      (multiple-value-bind (text truncated file-len read-len)
          (read-file-string pn :offset 3 :limit 4)
        (is string= "defg" text)
        (is = 4 read-len)
        ;; With limit=4, effective=4, capped=min(4,2MB)=4, so (> 4 4)=NIL.
        ;; Truncated is only true when the 2 MB cap is hit, not when the user
        ;; supplies a limit smaller than the file.
        (false truncated)
        (is = 10 file-len)))))
