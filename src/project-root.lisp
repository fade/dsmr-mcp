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
  (list "/" "/tmp/" "/home/" "/usr/" "/etc/" "/var/"
        "/root/" "/dev/" "/proc/" "/sys/" "/run/" "/boot/")
  "Paths that are too broad to be used as a project root (D-13).
Expanded to include system pseudo-filesystems and privileged home dirs.")

(defun broad-root-p (pathname)
  "Return T when PATHNAME is on the broad-root deny list (D-13).
Checks both the raw namestring and the truename-resolved namestring to
prevent symlink bypass (e.g. macOS /tmp -> /private/tmp/).
Uses %resolve-with-parent-fallback so that a symlinked or nonexistent
candidate root is still resolved before the deny-list check (CR-03)."
  (let ((ns (namestring (uiop:ensure-directory-pathname pathname))))
    (when (some (lambda (d) (string= ns d)) *broad-root-deny-list*)
      (return-from broad-root-p t))
    ;; Also check after symlink/parent resolution to close bypass attempts.
    ;; %resolve-with-parent-fallback handles the case where the directory
    ;; does not yet exist, unlike a bare truename call.
    (let* ((resolved (%resolve-with-parent-fallback
                      (uiop:ensure-directory-pathname pathname)))
           (resolved-ns (namestring (uiop:ensure-directory-pathname resolved))))
      (when (some (lambda (d) (string= resolved-ns d)) *broad-root-deny-list*)
        (return-from broad-root-p t)))
    nil))

;;; Path canonicalization ---------------------------------------------------

(defun %resolve-with-parent-fallback (pn)
  "Return the real (truename-resolved) path for PN, falling back to
ancestor-directory resolution when PN does not yet exist.

When PN exists, truename resolves it directly (symlinks followed, D-14).

When PN does not exist, we walk UP the directory components to the DEEPEST
EXISTING ANCESTOR, truename THAT ancestor (following any symlink in the
existing portion), and reattach ALL the stripped nonexistent tail components
plus the leaf name/type onto the resolved ancestor. This closes the
nonexistent-leaf escape regardless of how many path levels are missing.

A symlink /root/evil -> /outside/ causes /root/evil/newdir/newfile to resolve
to /outside/newdir/newfile — correctly outside the root — even though both
newdir and newfile are absent and truename on the full path (and on the
immediate parent) would fail. The writer's ensure-directories-exist would
otherwise create newdir THROUGH the symlink and escape the jail.

If no ancestor exists at all (e.g. an absolute path on a nonexistent volume),
we keep PN as-is; that is safe because without a real symlink the lexical
path carries no resolution to follow. Reconstruction preserves the
absolute/relative status of PN so a nonexistent path never silently becomes
relative."
  (or
   ;; Primary: file exists — truename resolves it including any symlinks.
   (handler-case (truename pn) (file-error () nil))
   ;; Secondary: file does not exist — resolve via the deepest existing
   ;; ancestor directory and reattach the missing tail components.
   (let* ((dir (pathname-directory pn))
          (absolute (eq (first dir) :absolute))
          (components (rest dir))
          ;; Tail directory components stripped while walking up, in path order.
          (tail '()))
     (labels ((directory-pathname-for (head)
                (make-pathname
                 :directory (cons (if absolute :absolute :relative) head)
                 :name nil :type nil :version nil
                 :defaults pn)))
       (loop with head = (copy-list components)
             for existing = (handler-case (truename (directory-pathname-for head))
                              (file-error () nil))
             when existing
               ;; Reattach stripped dirs + leaf onto the resolved ancestor.
               do (return
                    (make-pathname
                     :directory (append (pathname-directory existing) tail)
                     :name (pathname-name pn)
                     :type (pathname-type pn)
                     :version (pathname-version pn)
                     :defaults existing))
             ;; No ancestor exists at all — keep PN unchanged (no symlink to follow).
             when (null head)
               do (return pn)
             do (push (car (last head)) tail)
                (setf head (butlast head)))))))

(defun canonical-path (path session-root)
  "Merge a relative PATH against SESSION-ROOT (absolute paths pass through).
Returns a pathname. Does not signal on nonexistent paths — truename is guarded.
Uses %resolve-with-parent-fallback so that a symlinked parent directory is
resolved before the containment check (see D-14)."
  (let* ((pn (if (uiop:absolute-pathname-p path)
                 (uiop:ensure-pathname path)
                 (uiop:merge-pathnames* path session-root))))
    (%resolve-with-parent-fallback pn)))

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
A symlink inside the root that resolves outside it returns NIL.
%resolve-with-parent-fallback handles the nonexistent-leaf case: when the
target file does not yet exist, the parent directory is truename-resolved so
a symlinked parent cannot bypass the containment check."
  (let* ((pn (if (uiop:absolute-pathname-p path)
                 (uiop:ensure-pathname path)
                 (uiop:merge-pathnames* path session-root)))
         ;; Resolve symlinks before containment check (D-14).
         ;; Use parent-fallback to handle the nonexistent-leaf case (CR-02).
         (resolved (%resolve-with-parent-fallback pn))
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
D-14: truename runs before the containment check.
%resolve-with-parent-fallback handles the nonexistent-leaf case (CR-01):
when the target file does not yet exist, the parent directory is
truename-resolved so a symlinked parent cannot bypass the write jail."
  (unless session-root
    (return-from ensure-write-path nil))
  (let* ((pn (if (uiop:absolute-pathname-p path)
                 (uiop:ensure-pathname path)
                 (uiop:merge-pathnames* path session-root)))
         ;; Resolve symlinks before containment check (D-14).
         ;; Use parent-fallback to handle the nonexistent-leaf case (CR-01).
         (resolved (%resolve-with-parent-fallback pn))
         (root-dir (uiop:ensure-directory-pathname session-root))
         (resolved-root (or (handler-case (truename root-dir) (file-error () nil))
                            root-dir)))
    (when (uiop:subpathp resolved resolved-root)
      resolved)))
