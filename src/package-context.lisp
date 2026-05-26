;;;; src/package-context.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Lenient package context synthesis for structural file reading tools.
;;;; Provides two complementary capabilities:
;;;;
;;;;   1. call-with-lenient-packages — wraps a read loop with a handler-bind
;;;;      that catches unknown-package-prefix errors and creates ephemeral stub
;;;;      packages on the fly (Eclector + SBCL CL-reader variants handled).
;;;;
;;;;   2. call-with-file-package-context — extracts the leading IN-PACKAGE name
;;;;      from a source text and arranges the correct *PACKAGE* binding (with
;;;;      a synthesized stub if the package is not loaded in the dispatcher image)
;;;;      before calling the supplied thunk.
;;;;
;;;; Both are used by the CST parser (src/cst.lisp) to produce readable symbol
;;;; output for files whose packages are not present in the dispatcher image.
;;;;
;;;; Fresh AGPL write adapting patterns from cl-mcp/src/utils/lenient-read.lisp
;;;; and cl-mcp/src/package-context.lisp (MIT).

(defpackage #:dsmr-mcp/src/package-context
  (:use #:cl)
  (:import-from #:eclector.reader
                #:package-does-not-exist
                #:symbol-does-not-exist
                #:symbol-is-not-external)
  (:export #:call-with-lenient-packages
           #:call-with-file-package-context
           #:*homeless-due-to-teardown*))

(in-package #:dsmr-mcp/src/package-context)

;;;; -------------------------------------------------------------------------
;;;; Homeless-symbol tracking
;;;; -------------------------------------------------------------------------

(defvar *homeless-due-to-teardown*
  #+sbcl (make-hash-table :test #'eq :weakness :key :synchronized t)
  #-sbcl (make-hash-table :test #'eq)
  "Weak-key hash-table of symbols that became homeless when a synthesized
stub package was torn down after a parse operation.  Used by display code
(e.g. lisp-read-file's form printer) to distinguish symbols that were
genuinely uninterned in the source from symbols made homeless only as a
side effect of package teardown.")

(defun %record-homeless-on-teardown (pkg)
  "Register every symbol home-packaged in PKG as homeless-due-to-teardown.
Must be called BEFORE delete-package while home relationships are intact."
  (when (and pkg (packagep pkg) (package-name pkg))
    (do-symbols (s pkg)
      (when (eq (symbol-package s) pkg)
        (setf (gethash s *homeless-due-to-teardown*) t)))))

;;;; -------------------------------------------------------------------------
;;;; Restart discovery helpers
;;;; -------------------------------------------------------------------------

(defun %find-restart-by-name (name-string condition)
  "Find the first restart whose name matches NAME-STRING by symbol-name comparison.
Avoids package-qualification issues with Eclector's internal restart names."
  (dolist (r (compute-restarts condition))
    (when (and (restart-name r)
               (string= name-string (symbol-name (restart-name r))))
      (return r))))

#+sbcl
(defun %find-restart-by-name-and-description (name-string desc-pattern condition)
  "Find a restart matching NAME-STRING whose description contains DESC-PATTERN.
Used on SBCL where multiple restarts may share the same name but differ in scope."
  (dolist (r (compute-restarts condition))
    (when (and (restart-name r)
               (string= name-string (symbol-name (restart-name r))))
      (let ((desc (format nil "~A" r)))
        (when (search desc-pattern desc :test #'char-equal)
          (return r))))))

;;;; -------------------------------------------------------------------------
;;;; Condition handlers for call-with-lenient-packages
;;;; -------------------------------------------------------------------------

(defun %handle-eclector-package-missing (condition stubs)
  "Create a stub package for the unknown prefix and invoke USE-PACKAGE."
  (let ((name (eclector.reader::desired-package-name condition)))
    (unless (find-package name)
      (push (make-package name :use nil) (car stubs)))
    (let ((r (%find-restart-by-name "USE-PACKAGE" condition)))
      (when r
        (invoke-restart r (find-package name))))))

(defun %handle-eclector-symbol-missing (condition stubs managed)
  "Intern and export the missing symbol in a stub package via USE-VALUE."
  (let ((pkg (eclector.reader::desired-symbol-package condition)))
    (when (and pkg
               (or (member pkg (car stubs) :test #'eq)
                   (member pkg managed :test #'eq)))
      (let ((sym-name (eclector.reader::desired-symbol-name condition)))
        (let ((sym (intern sym-name pkg)))
          (export sym pkg)
          (let ((r (%find-restart-by-name "USE-VALUE" condition)))
            (when r
              (invoke-restart r sym))))))))

(defun %handle-eclector-symbol-not-external (condition stubs managed)
  "Invoke USE-ANYWAY for a non-external symbol in a stub package."
  (let ((pkg (eclector.reader::desired-symbol-package condition)))
    (when (and pkg
               (or (member pkg (car stubs) :test #'eq)
                   (member pkg managed :test #'eq)))
      (let ((r (%find-restart-by-name "USE-ANYWAY" condition)))
        (when r
          (invoke-restart r))))))

#+sbcl
(defun %handle-sbcl-reader-package-error (condition stubs managed)
  "Handle SBCL's simple-reader-package-error by creating stubs or exporting symbols."
  (let ((ctrl (simple-condition-format-control condition))
        (args (simple-condition-format-arguments condition)))
    (cond
      ;; "Package ~A does not exist."
      ((search "does not exist" ctrl :test #'char-equal)
       (let ((name (first args)))
         (when (stringp name)
           (unless (find-package name)
             (push (make-package name :use nil) (car stubs)))
           (let ((r (%find-restart-by-name-and-description "RETRY" "finding" condition)))
             (when r (invoke-restart r))))))
      ;; "Symbol ~S not found in the ~A package."
      ((search "not found" ctrl :test #'char-equal)
       (let ((sym-name (first args))
             (pkg-name (second args)))
         (when (and (stringp sym-name) (stringp pkg-name))
           (let ((pkg (find-package pkg-name)))
             (when (and pkg
                        (or (member pkg (car stubs) :test #'eq)
                            (member pkg managed :test #'eq)))
               (export (intern sym-name pkg) pkg)
               (let ((r (%find-restart-by-name "CONTINUE" condition)))
                 (when r (invoke-restart r))))))))
      ;; "The symbol ~S is not external in the ~A package."
      ((search "not external" ctrl :test #'char-equal)
       (let ((sym-name (first args))
             (pkg-name (second args)))
         (when (and (stringp sym-name) (stringp pkg-name))
           (let ((pkg (find-package pkg-name)))
             (when (and pkg
                        (or (member pkg (car stubs) :test #'eq)
                            (member pkg managed :test #'eq)))
               (export (intern sym-name pkg) pkg)
               (let ((r (%find-restart-by-name "CONTINUE" condition)))
                 (when r (invoke-restart r)))))))))))

(defun %cleanup-stubs (stubs)
  "Delete all stub packages, recording their symbols as homeless first."
  (dolist (pkg stubs)
    (let ((name (ignore-errors (package-name pkg))))
      (when (and name (find-package name))
        (%record-homeless-on-teardown pkg)
        (do-symbols (s pkg)
          (unintern s pkg))
        (delete-package pkg)))))

;;;; -------------------------------------------------------------------------
;;;; Public API
;;;; -------------------------------------------------------------------------

(defvar *managed-lenient-packages* nil
  "Dynamic list of pre-created stub packages whose lifecycle is owned by the
caller (via call-with-file-package-context).  Treated identically to on-demand
stubs by the condition handlers in call-with-lenient-packages.")

(defun call-with-lenient-packages (thunk)
  "Call THUNK with handler-bind intercepting unknown-package conditions.

When the Eclector or SBCL CL reader encounters a package-qualified symbol
whose package does not exist, an ephemeral stub package is created on the fly
so that the read can proceed.  All stub packages are cleaned up unconditionally
after THUNK returns, recording their symbols as homeless-due-to-teardown.

Handled conditions:
  ECLECTOR.READER:PACKAGE-DOES-NOT-EXIST    -- invokes USE-PACKAGE restart
  ECLECTOR.READER:SYMBOL-DOES-NOT-EXIST     -- interns+exports via USE-VALUE
  ECLECTOR.READER:SYMBOL-IS-NOT-EXTERNAL    -- invokes USE-ANYWAY restart
  SB-INT:SIMPLE-READER-PACKAGE-ERROR (SBCL) -- creates stub or exports, retries

Returns the values returned by THUNK."
  (let ((stubs-cell (list nil))
        (managed *managed-lenient-packages*))
    (unwind-protect
         (handler-bind
             ((package-does-not-exist
                (lambda (c)
                  (%handle-eclector-package-missing c stubs-cell)))
              (symbol-does-not-exist
                (lambda (c)
                  (%handle-eclector-symbol-missing c stubs-cell managed)))
              (symbol-is-not-external
                (lambda (c)
                  (%handle-eclector-symbol-not-external c stubs-cell managed)))
              #+sbcl
              (sb-int:simple-reader-package-error
                (lambda (c)
                  (%handle-sbcl-reader-package-error c stubs-cell managed))))
           (funcall thunk))
      (%cleanup-stubs (car stubs-cell)))))

;;;; -------------------------------------------------------------------------
;;;; File-package-context synthesis
;;;; -------------------------------------------------------------------------

(defun %designator-name (designator)
  "Normalize DESIGNATOR to an uppercase package-name string, or NIL."
  (typecase designator
    (null nil)
    (string (string-upcase designator))
    (symbol (string-upcase (symbol-name designator)))
    (t nil)))

(defun %extract-in-package-name (text)
  "Return the first IN-PACKAGE name from TEXT as an uppercase string, or NIL.
Uses the CL reader with *read-eval* nil so no code is evaluated."
  (handler-case
      (let ((*read-eval* nil))
        (with-input-from-string (stream text)
          (loop for form = (read stream nil :eof)
                until (eq form :eof)
                do (when (and (consp form)
                              (symbolp (car form))
                              (string= (symbol-name (car form)) "IN-PACKAGE")
                              (consp (cdr form)))
                     (return (%designator-name (second form)))))))
    (error () nil)))

(defstruct synthesized-context
  "Temporary package objects created for a single reader operation."
  root-package
  (created-packages nil :type list))

(defun %make-package-guarded (name &key nicknames use)
  "Create package NAME; signal a clear error on failure."
  (handler-case
      (make-package name :use use :nicknames nicknames)
    (error (e)
      (error "Failed to synthesize stub package ~A: ~A" name e))))

(defun %ensure-stub (name created-packages-cell)
  "Return an existing package by NAME or create a stub and record it."
  (or (find-package name)
      (let ((pkg (%make-package-guarded name :use nil)))
        (push pkg (car created-packages-cell))
        pkg)))

(defun %synthesize-context-for-package (pkg-name)
  "Create a minimal synthesized package context for PKG-NAME.
Returns a SYNTHESIZED-CONTEXT, or NIL if pkg-name is NIL or already loaded."
  (when (and pkg-name (not (find-package pkg-name)))
    (let ((created-cell (list nil)))
      (let ((pkg (%make-package-guarded pkg-name :use nil)))
        (push pkg (car created-cell))
        (make-synthesized-context :root-package pkg
                                  :created-packages (car created-cell))))))

(defun %cleanup-synthesized-context (ctx)
  "Delete all packages in CTX, recording homeless symbols first."
  (when ctx
    (dolist (pkg (reverse (synthesized-context-created-packages ctx)))
      (let ((name (ignore-errors (package-name pkg))))
        (when (and name (find-package name))
          (%record-homeless-on-teardown pkg)
          (ignore-errors (delete-package pkg)))))))

(defun call-with-file-package-context (file-text thunk)
  "Extract the IN-PACKAGE name from FILE-TEXT and call THUNK with *PACKAGE*
bound to that package (or a synthesized stub if not loaded in the dispatcher image).

When no IN-PACKAGE is found, THUNK is called inside call-with-lenient-packages
with the current *PACKAGE* unchanged.  This is the correct behaviour for files
that define a package and use it immediately — the parse loop tracks IN-PACKAGE
forms as it goes and updates *PACKAGE* progressively via parse-top-level-forms."
  (let ((pkg-name (%extract-in-package-name file-text)))
    (cond
      ((null pkg-name)
       ;; No in-package — just wrap in lenient reader context.
       (call-with-lenient-packages thunk))
      ((find-package pkg-name)
       ;; Package already loaded — bind *PACKAGE* and add lenient wrap.
       (let ((*package* (find-package pkg-name)))
         (call-with-lenient-packages thunk)))
      (t
       ;; Package not present — synthesize a stub, bind *PACKAGE*, clean up after.
       (let ((ctx (%synthesize-context-for-package pkg-name)))
         (unwind-protect
              (let ((*package* (if ctx
                                   (synthesized-context-root-package ctx)
                                   *package*))
                    (*managed-lenient-packages*
                      (if ctx
                          (append (synthesized-context-created-packages ctx)
                                  *managed-lenient-packages*)
                          *managed-lenient-packages*)))
                (call-with-lenient-packages thunk))
           (%cleanup-synthesized-context ctx)))))))
