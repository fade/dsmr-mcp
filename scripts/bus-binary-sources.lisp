;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; scripts/bus-binary-sources.lisp
;;;;
;;;; Writes the make prerequisite list for a bus binary or a core image: one
;;;; `TARGET: PATH` line per file the target is built from, that is, every
;;;; system definition file and every existing component file in the ASDF
;;;; dependency closure of the systems it is built from.
;;;;
;;;; The caller loads this file into an SBCL that already holds the target's
;;;; build setup (the BUS_WATCH_SBCL or BUS_HOST_SBCL prefix, or
;;;; scripts/build-core.lisp in list mode), so the closure resolves exactly as
;;;; the build resolves it. It is never loaded into a build image, so no binary
;;;; or core carries it. It finds systems and never loads, compiles or operates
;;;; on them; finding a third-party system may load that system's .asd file, as
;;;; the build setup does.
;;;;
;;;; Every refusal signals an error with a message. Under --disable-debugger
;;;; SBCL prints it and exits non-zero, and nothing is written.

(in-package #:cl-user)

(require :asdf)

(defpackage #:bus-binary-sources
  (:use #:cl)
  (:export #:system-source-files
           #:write-prerequisites
           #:make-safe-namestring-p))

(in-package #:bus-binary-sources)

(defun dependency-name (spec)
  "Return the system name a dependency SPEC names, or NIL.
A string or symbol names itself; (:version n ...) names n; (:feature f n)
names n only when feature f holds; any other form names nothing."
  (cond ((or (stringp spec) (and spec (symbolp spec)))
         (asdf:coerce-name spec))
        ((consp spec)
         (case (first spec)
           (:version (dependency-name (second spec)))
           (:feature (and (uiop:featurep (second spec))
                          (dependency-name (third spec))))
           (t nil)))
        (t nil)))

(defun component-files (component)
  "Return the native namestrings of every existing leaf file under COMPONENT."
  (if (typep component 'asdf:parent-component)
      (mapcan #'component-files (asdf:component-children component))
      (let ((path (asdf:component-pathname component)))
        (when (and path (uiop:file-exists-p path))
          (list (uiop:native-namestring path))))))

(defun system-source-files (name)
  "Return the sorted, deduplicated native namestrings of the files system NAME
is built from: each system definition file and every existing leaf component
file in its closure over depends-on, defsystem-depends-on and
weakly-depends-on.
Signal an error when NAME, or a system named by depends-on or
defsystem-depends-on, cannot be found, or when the closure names no file.
A weakly depended system that cannot be found is skipped."
  (let ((seen (make-hash-table :test 'equal))
        (queue (list (list (asdf:coerce-name name) "the caller" t)))
        (files '()))
    (loop while queue
          do (destructuring-bind (system-name parent required) (pop queue)
               (unless (gethash system-name seen)
                 (setf (gethash system-name seen) t)
                 (let ((system (asdf:find-system system-name nil)))
                   (cond (system
                          (let ((definition (asdf:system-source-file system)))
                            (when definition
                              (push (uiop:native-namestring definition) files)))
                          (setf files (append (component-files system) files))
                          (flet ((enqueue (specs requiredp)
                                   (dolist (spec specs)
                                     (let ((dependency (dependency-name spec)))
                                       (when dependency
                                         (setf queue
                                               (append queue
                                                       (list (list dependency system-name
                                                                   requiredp)))))))))
                            (enqueue (asdf:system-depends-on system) t)
                            (enqueue (asdf:system-defsystem-depends-on system) t)
                            (enqueue (asdf:system-weakly-depends-on system) nil)))
                         (required
                          (error "cannot resolve system ~A, required by ~A; ~
                                  check the ASDF source registry the build uses"
                                 system-name parent)))))))
    (let ((result (sort (remove-duplicates files :test #'string=) #'string<)))
      (when (null result)
        (error "system ~A names no source files; ~
                check that its system definition is loaded"
               (asdf:coerce-name name)))
      result)))

(defun make-safe-namestring-p (string)
  "Return true when STRING is non-empty and holds only ASCII letters, digits
and the characters / . _ - + , @.
Make reads whitespace, quotes and : ; = # $ % * ? [ ] ( ) \\ ~ specially in a
rule line."
  (and (stringp string)
       (plusp (length string))
       (every (lambda (c)
                (or (char<= #\a c #\z)
                    (char<= #\A c #\Z)
                    (char<= #\0 c #\9)
                    (find c "/._-+,@")))
              string)))

(defun check-make-safe (string)
  "Return STRING; signal an error when MAKE-SAFE-NAMESTRING-P rejects it."
  (unless (make-safe-namestring-p string)
    (error "~S cannot be a make prerequisite: ~
            use only letters, digits and / . _ - + , @"
           string))
  string)

(defun write-prerequisites (system target output)
  "Write one `TARGET: PATH` line to file OUTPUT per file SYSTEM is built from,
and return the number of lines written.
SYSTEM is one system name, or a list of names whose closures are merged into
one sorted, deduplicated list.
Signal an error, before OUTPUT is opened, when TARGET or any path fails
MAKE-SAFE-NAMESTRING-P, or when SYSTEM-SOURCE-FILES refuses a system."
  (check-make-safe target)
  (let ((files (if (listp system)
                   (sort (remove-duplicates (mapcan #'system-source-files system)
                                            :test #'string=)
                         #'string<)
                   (system-source-files system))))
    (mapc #'check-make-safe files)
    (with-open-file (stream output :direction :output
                                   :if-exists :supersede
                                   :if-does-not-exist :create)
      (dolist (file files)
        (format stream "~A: ~A~%" target file)))
    (length files)))
