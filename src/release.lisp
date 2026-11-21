;;;; src/release.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; What a release image needs to know about itself: the release directory it
;;;; runs from, how its ASDF registry is sealed, and whether it is sealed.

(defpackage #:dsmr-mcp/src/release
  (:use #:cl)
  (:export #:release-root
           #:seal-source-registry
           #:sealed-p
           #:loaded-system-directories
           #:release-ties
           #:guard-report
           #:guard-main
           #:release-manifest
           #:release-commit))

(in-package #:dsmr-mcp/src/release)

(defun %package-inferred-search ()
  "The symbol naming ASDF's package-inferred system search function."
  (uiop:find-symbol* '#:sysdef-package-inferred-system-search
                     '#:asdf/package-inferred-system))

(defun release-root ()
  "Return the directory DSMR_RELEASE_ROOT names, as a physical directory
pathname, or NIL when the variable is unset, empty, or names no existing
directory. Reads the environment on every call."
  (let ((value (uiop:getenv "DSMR_RELEASE_ROOT")))
    (when (and value (plusp (length value)))
      (let ((dir (ignore-errors (uiop:directory-exists-p
                                 (uiop:ensure-directory-pathname value)))))
        (and dir (ignore-errors (truename dir)))))))

(defun seal-source-registry ()
  "Seal this image's ASDF registry and return no values.

Empties ASDF:*CENTRAL-REGISTRY* and ASDF:*DEFAULT-SOURCE-REGISTRIES*, leaves
the package-inferred search function as the only system search function, and
clears the source registry. Loaded systems stay usable: loading one again is a
no-op and SYSTEM-RELATIVE-PATHNAME still answers. Finding or loading a system
the image has not loaded signals ASDF/FIND-COMPONENT:MISSING-COMPONENT, and
ASDF:CLEAR-SOURCE-REGISTRY does not undo the seal."
  (setf asdf:*central-registry* nil
        asdf:*default-source-registries* nil
        asdf:*system-definition-search-functions*
        (list (%package-inferred-search)))
  (asdf:clear-source-registry)
  (values))

(defun sealed-p ()
  "True when the image is sealed: the package-inferred search function is the
only system search function and both the central and default source
registries are empty."
  (and (equal asdf:*system-definition-search-functions*
              (list (%package-inferred-search)))
       (null asdf:*central-registry*)
       (null asdf:*default-source-registries*)))

(defun release-manifest ()
  "Return the MANIFEST of the release at RELEASE-ROOT as an alist of key to
value strings, in file order, with every `dependency` line's value collected in
one list under \"dependency\". NIL when there is no release root or the
MANIFEST is absent or unreadable; never signals."
  (let ((root (release-root)))
    (when root
      (ignore-errors
       (with-open-file (in (merge-pathnames "MANIFEST" root)
                           :direction :input :if-does-not-exist nil)
         (when in
           (let ((entries '())
                 (dependencies '()))
             (loop for line = (read-line in nil)
                   while line
                   do (let* ((line (string-right-trim '(#\Return #\Space) line))
                             (space (position #\Space line))
                             (key (if space (subseq line 0 space) line))
                             (value (if space (subseq line (1+ space)) "")))
                        (cond ((zerop (length key)))
                              ((string= key "dependency")
                               (unless dependencies
                                 (push (cons key nil) entries))
                               (push value dependencies))
                              (t (push (cons key value) entries)))))
             (let ((entries (nreverse entries)))
               (when dependencies
                 (setf (cdr (assoc "dependency" entries :test #'string=))
                       (nreverse dependencies)))
               entries))))))))

(defun release-commit ()
  "Return the commit the release's MANIFEST records, or NIL when there is no
release, no MANIFEST or no non-empty commit line."
  (let ((commit (cdr (assoc "commit" (release-manifest) :test #'string=))))
    (and (stringp commit) (plusp (length commit)) commit)))

;;; ---------------------------------------------------------------------------
;;; The guard: what ties a release image to a checkout or to a path outside it
;;; ---------------------------------------------------------------------------

(defun %physical-directory (designator)
  "DESIGNATOR as a physical directory namestring ending in /, symlinks
resolved. A directory that does not exist keeps its given spelling. NIL for
NIL or an empty string."
  (when (and designator
             (not (and (stringp designator) (zerop (length designator)))))
    (let ((dir (uiop:ensure-directory-pathname designator)))
      (namestring (or (ignore-errors (truename dir)) dir)))))

(defun %physical-file (designator)
  "DESIGNATOR as a physical file namestring, symlinks resolved. A file that
does not exist keeps its given spelling. NIL for NIL or an empty string."
  (when (and designator
             (not (and (stringp designator) (zerop (length designator)))))
    (namestring (or (ignore-errors (truename designator))
                    (pathname designator)))))

(defun %under-p (directory root)
  "True when the namestring DIRECTORY is ROOT or lies below it. Both end in /."
  (and directory root
       (<= (length root) (length directory))
       (string= root directory :end2 (length root))))

(defun %inside-work-tree-p (directory)
  "True when DIRECTORY or one of its ancestors holds a .git entry: a directory
in a checkout, a file in a linked work tree."
  (loop for dir = (pathname directory) then parent
        for parent = (uiop:pathname-parent-directory-pathname dir)
        thereis (or (probe-file (merge-pathnames ".git" dir))
                    (uiop:directory-exists-p (merge-pathnames ".git/" dir)))
        until (equal (namestring parent) (namestring dir))))

(defun %contrib-directory ()
  "The physical SBCL contrib directory of this image."
  (%physical-directory (merge-pathnames "contrib/" (sb-int:sbcl-homedir-pathname))))

(defun %preloaded-name-p (name)
  "True for the systems an SBCL image may carry without a source directory:
asdf, uiop and the sb-* contribs."
  (or (string= name "asdf")
      (string= name "uiop")
      (and (< 3 (length name)) (string= "sb-" name :end2 3))))

(defun loaded-system-directories ()
  "Return a list of (NAME . DIRECTORY), one per system ASDF has loaded, where
DIRECTORY is the physical namestring of the system's source directory, or NIL
when it has none or asking signals an error."
  (mapcar (lambda (name)
            (cons name
                  (ignore-errors
                   (%physical-directory (asdf:system-source-directory name)))))
          (asdf:already-loaded-systems)))

(defun release-ties (root &key (systems nil systems-p)
                               (launcher nil launcher-p)
                               exceptions)
  "Return every tie of a release image at ROOT as plists (:NAME :DIRECTORY
:REASON), in SYSTEMS order with the launcher last.

SYSTEMS is a list of (NAME . DIRECTORY) and defaults to
LOADED-SYSTEM-DIRECTORIES. LAUNCHER is a file path and defaults to the value of
DSMR_LAUNCHER_PATH; NIL or empty means no launcher. A directory under one of
EXCEPTIONS is never a tie. Every comparison uses physical paths.

Reasons:
  :CHECKOUT                  the directory lies in a git work tree, under ROOT or not
  :OUTSIDE-RELEASE           the directory is outside ROOT and the SBCL contrib directory
  :NO-SOURCE                 no source directory, and not asdf, uiop or an sb-* contrib
  :LAUNCHER-IN-WORK-TREE     the launcher lies in a git work tree
  :LAUNCHER-OUTSIDE-RELEASE  the launcher is outside ROOT"
  (let* ((root (%physical-directory root))
         (contrib (%contrib-directory))
         (exceptions (remove nil (mapcar #'%physical-directory exceptions)))
         (systems (if systems-p systems (loaded-system-directories)))
         (launcher (%physical-file (if launcher-p
                                       launcher
                                       (uiop:getenv "DSMR_LAUNCHER_PATH"))))
         (work-tree (make-hash-table :test 'equal))
         (ties '()))
    (flet ((in-work-tree-p (dir)
             (multiple-value-bind (known presentp) (gethash dir work-tree)
               (if presentp
                   known
                   (setf (gethash dir work-tree)
                         (and (%inside-work-tree-p dir) t)))))
           (excepted-p (dir)
             (some (lambda (e) (%under-p dir e)) exceptions))
           (tie (name dir reason)
             (push (list :name name :directory dir :reason reason) ties)))
      (dolist (entry systems)
        (let ((name (car entry))
              (dir (%physical-directory (cdr entry))))
          (cond ((null dir)
                 (unless (%preloaded-name-p name)
                   (tie name nil :no-source)))
                ((excepted-p dir))
                ((in-work-tree-p dir)
                 (tie name dir :checkout))
                ((or (%under-p dir root) (%under-p dir contrib)))
                (t
                 (tie name dir :outside-release)))))
      (when launcher
        (let ((dir (%physical-directory
                    (uiop:pathname-directory-pathname launcher))))
          (cond ((in-work-tree-p dir)
                 (tie "launcher" launcher :launcher-in-work-tree))
                ((not (%under-p dir root))
                 (tie "launcher" launcher :launcher-outside-release))))))
    (nreverse ties)))

(defun %residuals ()
  "Tool code that runs outside the release by design, as a list of hash tables
with name, directory and reason."
  (let ((alive (uiop:getenv "DSMR_ALIVE_LSP_DIR")))
    (when (and alive (plusp (length alive)))
      (let ((h (make-hash-table :test 'equal)))
        (setf (gethash "name" h) "alive-lsp"
              (gethash "directory" h) (%physical-directory alive)
              (gethash "reason" h)
              "the LSP bridge loads it in its own process from outside the release")
        (list h)))))

(defun guard-report (&key (root (release-root))
                          (systems nil systems-p)
                          (launcher nil launcher-p)
                          exceptions
                          (sealed (sealed-p)))
  "Return the release guard's report as a hash table for JSON.

Keys:
  release_root  the release root, or null without one
  sealed        SEALED as a boolean
  launcher      the launcher path, or null when there is none
  ties          a vector of objects with name, directory and reason
  residuals     tool code outside the release by design; never turns the report red
  status        \"green\" with a release root, SEALED true and no tie, else \"red\"
Without a release root no tie is computed. SYSTEMS, LAUNCHER and EXCEPTIONS are
passed to RELEASE-TIES; LAUNCHER defaults to DSMR_LAUNCHER_PATH."
  (let* ((root (and root (%physical-directory root)))
         (launcher (%physical-file (if launcher-p
                                       launcher
                                       (uiop:getenv "DSMR_LAUNCHER_PATH"))))
         (ties (when root
                 (if systems-p
                     (release-ties root :systems systems :launcher launcher
                                        :exceptions exceptions)
                     (release-ties root :launcher launcher
                                        :exceptions exceptions))))
         (h (make-hash-table :test 'equal)))
    (setf (gethash "release_root" h) (or root 'null)
          (gethash "sealed" h) (and sealed t)
          (gethash "launcher" h) (or launcher 'null)
          (gethash "ties" h)
          (map 'vector
               (lambda (tie)
                 (let ((th (make-hash-table :test 'equal)))
                   (setf (gethash "name" th) (getf tie :name)
                         (gethash "directory" th) (or (getf tie :directory) 'null)
                         (gethash "reason" th)
                         (string-downcase (symbol-name (getf tie :reason))))
                   th))
               ties)
          (gethash "residuals" h) (coerce (%residuals) 'vector)
          (gethash "status" h) (if (and root sealed (null ties)) "green" "red"))
    h))

(defun guard-main ()
  "Print the guard report for this image on standard output, then exit.

Prints `release-root <root>`, `sealed <t|nil>`, one `tie <reason> <name>
<directory>` line per tie, one `residual <name> <directory>` line per residual
and `ties <n>`. Exits 0 when the report is green and 1 otherwise. Without a
release root prints `release-root none` and exits 1."
  (let ((report (guard-report)))
    (flet ((field (key)
             (let ((value (gethash key report)))
               (if (eq value 'null) nil value))))
      (cond ((null (field "release_root"))
             (format t "release-root none~%"))
            (t
             (format t "release-root ~A~%" (field "release_root"))
             (format t "sealed ~(~A~)~%" (field "sealed"))
             (loop for tie across (field "ties")
                   for dir = (gethash "directory" tie)
                   do (format t "tie ~A ~A ~A~%" (gethash "reason" tie)
                              (gethash "name" tie) (if (eq dir 'null) "-" dir)))
             (loop for residual across (field "residuals")
                   do (format t "residual ~A ~A~%" (gethash "name" residual)
                              (gethash "directory" residual)))
             (format t "ties ~D~%" (length (field "ties")))))
      (finish-output)
      (uiop:quit (if (equal (field "status") "green") 0 1)))))
