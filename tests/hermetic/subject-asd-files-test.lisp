;;;; tests/hermetic/subject-asd-files-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Unit tests for the search a worker runs over its subject tree for .asd
;;;; files: the subject's own nested systems are found, and copies of
;;;; dependencies vendored into the tree are not.
;;;;
;;;; Each test builds a tree of empty .asd files in a fresh temporary
;;;; directory and removes it afterwards. No worker is spawned.

(defpackage #:dsmr-mcp/tests/hermetic/subject-asd-files-test
  (:use #:cl #:zebra)
  (:local-nicknames (#:main #:dsmr-mcp/src/hermetic/worker/main))
  (:import-from #:uiop)
  (:import-from #:sb-posix))

(in-package #:dsmr-mcp/tests/hermetic/subject-asd-files-test)

(defun %call-with-tree (relative-asds fn)
  "Create a temporary directory holding an empty file at each path in
RELATIVE-ASDS, call FN with the directory, and delete the directory."
  (let ((root (uiop:ensure-directory-pathname
               (merge-pathnames (format nil "dsmr-subject-asd-~36R-~D/"
                                        (random (expt 36 8) (make-random-state t))
                                        (sb-posix:getpid))
                                (uiop:temporary-directory)))))
    (unwind-protect
         (progn
           (dolist (rel relative-asds)
             (let ((file (merge-pathnames rel root)))
               (ensure-directories-exist file)
               (with-open-file (out file :direction :output :if-exists :supersede)
                 (declare (ignore out)))))
           (funcall fn root))
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(defun %found (root)
  "The .asd files %SUBJECT-ASD-FILES returns for ROOT, as paths relative to ROOT."
  (let ((true-root (truename root)))
    (mapcar (lambda (p) (enough-namestring (truename p) true-root))
            (main::%subject-asd-files root))))

(define-test the-subjects-own-nested-systems-are-found
  "A .asd at the root, one in src/<name>/ and one in contrib/<name>/ are all found."
  (%call-with-tree '("top.asd" "src/foo/foo.asd" "contrib/x/x.asd" "slynk/slynk.asd")
                   (lambda (root)
                     (let ((found (%found root)))
                       (dolist (want '("top.asd" "src/foo/foo.asd" "contrib/x/x.asd"
                                       "slynk/slynk.asd"))
                         (true (member want found :test #'string=)
                               "~A not found; found ~S" want found))))))

(define-test vendored-dependencies-are-not-found
  "No .asd under a vendoring directory is found: ocicl, vendor, vendored,
third_party, third-party, lib, quicklisp, local-projects, systems, dists,
bundle, deps, or a hidden directory such as .qlot."
  (let ((vendored '("ocicl/alexandria-20240503-abc/alexandria.asd"
                    "vendor/usocket/usocket.asd"
                    "vendored/jzon/com.inuoe.jzon.asd"
                    "third_party/log4cl/log4cl.asd"
                    "third-party/log4cl/log4cl.asd"
                    "lib/bordeaux-threads/bordeaux-threads.asd"
                    "quicklisp/local-projects/cffi.asd"
                    "local-projects/cffi/cffi.asd"
                    "systems/babel/babel.asd"
                    "dists/quicklisp.asd"
                    "bundle/software/trivia.asd"
                    "deps/software/fiveam.asd"
                    ".qlot/local-projects/fiveam.asd")))
    (%call-with-tree (cons "top.asd" vendored)
                     (lambda (root)
                       (let ((found (%found root)))
                         (is equal '("top.asd") found
                             "vendored .asd files found: ~S"
                             (remove "top.asd" found :test #'string=)))))))
