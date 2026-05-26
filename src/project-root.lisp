;;;; src/project-root.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Per-session sandbox policy: allowed-read-path, ensure-write-path,
;;;; broad-root-p, and the condition types that callers signal when
;;;; containment is violated.
;;;;
;;;; Design: all path utilities take session-root as an explicit parameter
;;;; (never a global). This is a deliberate divergence from cl-mcp's
;;;; process-global *project-root* + uiop:chdir approach (D-03): per-session
;;;; roots let multiple concurrent sessions each be rooted at a different
;;;; project without racing on shared state.
;;;;
;;;; D-14 ordering (mandatory): truename (symlink resolution) runs BEFORE the
;;;; uiop:subpathp containment check. A symlink inside the root that resolves
;;;; outside it is rejected. Always use the guarded form:
;;;;   (or (handler-case (truename p) (file-error () nil)) p)
;;;; never bare (truename p) — truename signals file-error on nonexistent paths.

(defpackage #:dsmr-mcp/src/project-root
  (:use #:cl)
  (:import-from #:uiop
                #:ensure-directory-pathname
                #:subpathp
                #:merge-pathnames*
                #:directory-exists-p
                #:absolute-pathname-p
                #:ensure-pathname)
  (:import-from #:dsmr-mcp/src/log
                #:log-event)
  (:export #:allowed-read-path
           #:ensure-write-path
           #:broad-root-p
           #:canonical-path
           #:%asdf-source-dirs
           #:project-root-not-set-error
           #:sandbox-violation-error
           #:reroot-permission-required-error
           #:broad-root-error))

(in-package #:dsmr-mcp/src/project-root)

;;; Conditions --------------------------------------------------------------

(define-condition project-root-not-set-error (error)
  ((tool-name :initarg :tool-name :reader project-root-not-set-tool-name
              :initform nil))
  (:report (lambda (c s)
             (format s "No project root set~@[ for ~A~]. Call fs-set-project-root first."
                     (project-root-not-set-tool-name c))))
  (:documentation "Signalled when an fs verb is called without a session root.
Per D-16: silent fallback to process CWD is forbidden."))

(define-condition sandbox-violation-error (error)
  ((path :initarg :path :reader sandbox-violation-path :initform nil)
   (session-root :initarg :session-root :reader sandbox-violation-root :initform nil))
  (:report (lambda (c s)
             (format s "Path ~A is outside the read allow-list (root: ~A)"
                     (sandbox-violation-path c)
                     (sandbox-violation-root c))))
  (:documentation "Signalled when a path is not in the session root or any ASDF source dir."))

(define-condition reroot-permission-required-error (error)
  ((path :initarg :path :reader reroot-permission-required-path :initform nil)
   (current-root :initarg :current-root :reader reroot-permission-required-current-root
                 :initform nil))
  (:report (lambda (c s)
             (format s "Re-rooting to ~A requires human approval (D-05). ~
Call fs-set-project-root with human_approved: true."
                     (reroot-permission-required-path c))))
  (:documentation "Signalled when re-root target is outside the whitelist and human_approved is false."))

(define-condition broad-root-error (error)
  ((path :initarg :path :reader broad-root-error-path :initform nil))
  (:report (lambda (c s)
             (format s "~A is too broad to be used as a project root. ~
Choose a specific project directory."
                     (broad-root-error-path c))))
  (:documentation "Signalled when a broad root (/, /tmp/, /home/) is supplied."))

;;; Broad-root deny list ----------------------------------------------------

(defparameter *broad-root-deny-list*
  (list "/" "/tmp/" "/home/" "/usr/" "/etc/" "/var/")
  "Paths that are too broad to be used as a project root (D-13).")

(defun broad-root-p (pathname)
  "Return T when PATHNAME is on the broad-root deny list (D-13).
Checks both the raw namestring and the truename-resolved namestring to
prevent symlink bypass (e.g. macOS /tmp -> /private/tmp/)."
  (let ((ns (namestring (uiop:ensure-directory-pathname pathname))))
    (when (some (lambda (d) (string= ns d)) *broad-root-deny-list*)
      (return-from broad-root-p t))
    ;; Also check after truename resolution to close symlink bypass
    (let* ((tn (handler-case (truename pathname) (file-error () nil)))
           (resolved (when tn
                       (namestring (uiop:ensure-directory-pathname tn)))))
      (when (and resolved (some (lambda (d) (string= resolved d)) *broad-root-deny-list*))
        (return-from broad-root-p t)))
    nil))

;;; Path canonicalization ---------------------------------------------------

(defun canonical-path (path session-root)
  "Merge a relative PATH against SESSION-ROOT (absolute paths pass through).
Returns a pathname. Does not signal on nonexistent paths — truename is guarded."
  (let* ((pn (if (uiop:absolute-pathname-p path)
                 (uiop:ensure-pathname path)
                 (uiop:merge-pathnames* path session-root)))
         ;; Pitfall 3 guard: truename signals file-error on nonexistent paths.
         ;; Use the guarded form; fall back to the un-resolved pathname.
         (resolved (or (handler-case (truename pn) (file-error () nil)) pn)))
    resolved))

;;; ASDF source directory enumeration (D-15) --------------------------------

(defun %asdf-source-dirs ()
  "Return a list of pathnames for all registered ASDF system source directories.
Uses the dispatcher's own ASDF (D-15, Phase 6 scope). Attached-image
enumeration is deferred to Phase 7.
Nils are dropped; errors per-system are silently swallowed so one bad
system entry does not abort the allow-list check."
  (remove nil
          (mapcar (lambda (name)
                    (ignore-errors (asdf:system-source-directory name)))
                  (asdf/system-registry:registered-systems))))

;;; Read allow-list ---------------------------------------------------------

(defun allowed-read-path (path session-root)
  "Return canonical pathname if PATH is readable under SESSION-ROOT or any
registered ASDF source dir. Return NIL when PATH is outside the allow-list.

CONTRACT (D-16): SESSION-ROOT must be non-NIL; callers check and return
a typed error before calling this function. This function does NOT signal
on a nil SESSION-ROOT — that would make the contract too implicit.

D-14 ordering: canonicalize with truename FIRST, then check containment.
A symlink inside the root that resolves outside it returns NIL."
  (let* ((pn (if (uiop:absolute-pathname-p path)
                 (uiop:ensure-pathname path)
                 (uiop:merge-pathnames* path session-root)))
         ;; Resolve symlinks before containment check (D-14)
         (resolved (or (handler-case (truename pn) (file-error () nil)) pn))
         ;; Normalize directory status after resolution
         (normalized (if (uiop:directory-exists-p resolved)
                         (uiop:ensure-directory-pathname resolved)
                         resolved))
         (root-dir (uiop:ensure-directory-pathname session-root))
         (resolved-root (or (handler-case (truename root-dir) (file-error () nil))
                            root-dir)))
    ;; Primary check: under the session root
    (when (uiop:subpathp normalized resolved-root)
      (return-from allowed-read-path normalized))
    ;; Secondary check: under any registered ASDF source dir (D-15, read-only)
    (dolist (dir (%asdf-source-dirs))
      (let ((rdir (or (handler-case (truename dir) (file-error () nil)) dir)))
        (when (and rdir (uiop:subpathp normalized rdir))
          (return-from allowed-read-path normalized))))
    nil))

;;; Write sandbox -----------------------------------------------------------

(defun ensure-write-path (path session-root)
  "Return the resolved pathname for PATH when it is under SESSION-ROOT.
Return NIL when PATH is outside the session root or when SESSION-ROOT is NIL.

D-13: writes are allowed only under the current session root. ASDF source
dirs are read-only and are deliberately excluded from the write allow-list.
D-14: truename runs before the containment check."
  (unless session-root
    (return-from ensure-write-path nil))
  (let* ((pn (if (uiop:absolute-pathname-p path)
                 (uiop:ensure-pathname path)
                 (uiop:merge-pathnames* path session-root)))
         ;; Resolve symlinks before containment check (D-14)
         (resolved (or (handler-case (truename pn) (file-error () nil)) pn))
         (root-dir (uiop:ensure-directory-pathname session-root))
         (resolved-root (or (handler-case (truename root-dir) (file-error () nil))
                            root-dir)))
    (when (uiop:subpathp resolved resolved-root)
      resolved)))
