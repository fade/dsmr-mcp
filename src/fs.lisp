;;;; src/fs.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Filesystem I/O primitives for the fs-* verb surface.
;;;; Pure functions; the sandbox policy is enforced by callers via
;;;; allowed-read-path / ensure-write-path from src/project-root.lisp.
;;;;
;;;; D-17: read cap is 2 MB (not cl-mcp's 1 MB).
;;;; D-14: callers resolve and check paths before passing to these functions.
;;;;
;;;; Adapted from cl-mcp/src/fs.lisp (MIT) under AGPL.

(defpackage #:dsmr-mcp/src/fs
  (:use #:cl)
  (:import-from #:uiop
                #:ensure-directory-pathname
                #:directory-exists-p
                #:directory*
                #:subdirectories)
  (:import-from #:dsmr-mcp/src/log
                #:log-event)
  (:export #:read-file-string
           #:write-file-string-atomically
           #:list-directory-entries
           #:lisp-source-path-p
           #:*fs-read-max-bytes*
           #:*hidden-prefixes*
           #:*skip-extensions*))

(in-package #:dsmr-mcp/src/fs)

;;; Constants ---------------------------------------------------------------

(defparameter *fs-read-max-bytes* (* 2 1024 1024)
  "Maximum characters fs-read-file will return in one call (D-17: 2 MB).
cl-mcp used 1 MB; dsmr-mcp doubles the cap per SAFETY-03.")

(defparameter *hidden-prefixes*
  '("." ".git" ".hg" ".svn" ".cache" ".fasl")
  "Entry name prefixes filtered from directory listings by default.")

(defparameter *skip-extensions*
  '("fasl" "ufasl" "x86f" "cfasl")
  "File extensions always filtered from directory listings (build artifacts).")

;;; Lisp source guard -------------------------------------------------------

(defun lisp-source-path-p (pathname)
  "Return T when PATHNAME has a Common Lisp source extension.
Used by fs-write-file to prevent accidental overwrite of Lisp source with
raw text; structural edits go through lisp-edit-form instead."
  (member (string-downcase (or (pathname-type pathname) ""))
          '("lisp" "asd" "cl" "lsp") :test #'string=))

;;; Bounded file read -------------------------------------------------------

(defun read-file-string (pathname &key offset limit)
  "Read file PATHNAME honoring OFFSET and LIMIT (both may be NIL).
OFFSET is a 0-based character count; LIMIT is the maximum characters to read.
The effective read cap is *FS-READ-MAX-BYTES* (D-17: 2 MB).

Returns four values:
  (1) text       — the string read
  (2) truncated  — T when the file extended beyond the read cap
  (3) file-length — total file size in characters (NIL if unknown)
  (4) read-length — characters actually returned"
  (when (and offset (< offset 0))
    (error "offset must be non-negative"))
  (when (and limit (< limit 0))
    (error "limit must be non-negative"))
  (when (and limit (> limit *fs-read-max-bytes*))
    (error "limit ~D exceeds the maximum read cap (~D)" limit *fs-read-max-bytes*))
  (with-open-file (in pathname :direction :input :element-type 'character)
    (when (and offset (> offset 0))
      (file-position in offset))
    (let* ((raw-len (ignore-errors (file-length in)))
           (remaining (and raw-len (max 0 (- raw-len (or offset 0)))))
           (effective (or limit remaining *fs-read-max-bytes*))
           (capped    (min effective *fs-read-max-bytes*))
           (buf       (make-string capped))
           (count     (read-sequence buf in :end capped))
           (text      (subseq buf 0 count))
           ;; Truncated iff the effective requested amount was itself capped by
           ;; *fs-read-max-bytes* (i.e. the file/remaining exceeds the cap).
           ;; A user-supplied limit that happens to be less than file-length
           ;; is NOT truncation — the user asked for that much.
           (truncated (and raw-len (> effective capped))))
      (log-event :debug "fs.read"
                 "path" (namestring pathname)
                 "offset" offset
                 "limit" limit
                 "count" count
                 "truncated" truncated)
      (values text truncated raw-len count))))

;;; Atomic file write -------------------------------------------------------

(defun write-file-string-atomically (pathname content)
  "Write CONTENT to PATHNAME atomically via tmp-then-rename.
Parent directories are created if absent.
The original file is preserved on failure (unwind-protect cleanup).

The rename-done flag ensures the unwind-protect cleanup only deletes the
temp file when the rename did not complete.  A post-rename failure (e.g.
in log-event) cannot delete the now-live destination file."
  (ensure-directories-exist pathname)
  (let ((tmp (make-pathname
              :name (format nil ".~A.tmp" (pathname-name pathname))
              :type (pathname-type pathname)
              :defaults pathname))
        (rename-done nil))
    (unwind-protect
         (progn
           (with-open-file (out tmp :direction :output :if-exists :supersede
                                    :if-does-not-exist :create :element-type 'character)
             (write-string content out)
             (finish-output out))
           (rename-file tmp pathname)
           (setf rename-done t)
           (log-event :debug "fs.write.atomic"
                      "path" (namestring pathname)
                      "bytes" (length content))
           t)
      ;; Only clean up the temp file when the rename did not complete.
      ;; After a successful rename, tmp no longer refers to live data.
      (unless rename-done
        (when (probe-file tmp)
          (handler-case (delete-file tmp) (file-error () nil)))))))

;;; Directory listing -------------------------------------------------------

(defun %entry-name (path)
  "Return the display name for a directory entry PATH."
  (let* ((namestr (file-namestring path))
         (trimmed (and namestr (string-right-trim "/" namestr))))
    (if (and trimmed (plusp (length trimmed)))
        trimmed
        (let* ((dir (pathname-directory path))
               (leaf (car (last dir))))
          (and leaf (string leaf))))))

(defun %skip-entry-p (path show-hidden)
  "Return T when PATH should be omitted from a directory listing.
Build artifacts (*SKIP-EXTENSIONS*) are always filtered.
Hidden entries (*HIDDEN-PREFIXES*) are filtered unless SHOW-HIDDEN is non-nil."
  (let ((name (%entry-name path))
        (type (pathname-type path)))
    (or (null name)
        (and (not show-hidden)
             (some (lambda (pref)
                     (and (>= (length name) (length pref))
                          (string= name pref :end1 (length pref))))
                   *hidden-prefixes*))
        (and type
             (member (string-downcase type) *skip-extensions* :test #'string=)))))

(defun list-directory-entries (pathname &key show-hidden)
  "Return a list of (name . type) cons pairs for entries in PATHNAME.
TYPE is the string \"file\" or \"directory\".
Filters hidden prefixes and build-artifact extensions unless SHOW-HIDDEN is non-nil."
  (unless (uiop:directory-exists-p pathname)
    (error "Directory ~A does not exist or is not readable" (namestring pathname)))
  (let* ((dir-pn   (uiop:ensure-directory-pathname pathname))
         (patterns (list #P"*" #P"*.*"))
         (entries  (loop for pat in patterns
                         append (directory (merge-pathnames pat dir-pn))))
         (seen     (make-hash-table :test #'equal))
         (results  nil))
    (dolist (p entries)
      (unless (%skip-entry-p p show-hidden)
        (let ((key (namestring p)))
          (unless (gethash key seen)
            (setf (gethash key seen) t)
            (let ((name (%entry-name p)))
              (push (cons name
                          (if (uiop:directory-exists-p p)
                              "directory"
                              "file"))
                    results))))))
    (nreverse results)))
