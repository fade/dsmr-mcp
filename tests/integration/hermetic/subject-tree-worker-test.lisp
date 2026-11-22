;;;; tests/integration/hermetic/subject-tree-worker-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; A worker rooted at a dsmr-mcp tree loads that tree's dsmr-mcp systems
;;;; beside its own support code, which a release worker core keeps under
;;;; DSMR-WORKER package names.
;;;;
;;;; The subject is a `git archive HEAD` copy of this tree whose
;;;; src/hermetic/worker/main.lisp carries one extra function, SUBJECT-MARKER,
;;;; so a loaded subject is observable. The first two tests run a release worker
;;;; core (DSMR_TEST_RELEASE_WORKER_CORE, from a scratch `make deploy`) and skip
;;;; without one. Two controls show the same assertions can go red: an
;;;; unrenamed dev worker core is clobbered by the subject, and the command line
;;;; workers were started with before the rename, which put this server's own
;;;; tree first in ASDF's lookup, never loads the subject at all.
;;;;
;;;; The last release cases root the worker at a copy of a dependency the
;;;; release worker core itself loads and holds immutable, with one extra
;;;; function, and check that the copy is what loads: jzon with its .asd at the
;;;; root, jzon with its .asd one directory down, and a sly tree, whose
;;;; slynk.asd is in slynk/.

(defpackage #:dsmr-mcp/tests/integration/hermetic/subject-tree-worker-test
  (:use #:cl #:zebra)
  (:import-from #:dsmr-mcp/src/hermetic/worker-client
                #:spawn-worker #:kill-worker #:worker-rpc #:worker-ping
                #:*worker-core-disabled*)
  (:import-from #:dsmr-mcp/src/log
                #:configure-log4cl-for-server)
  (:import-from #:dsmr-mcp/tests/integration/support
                #:sbcl-path
                #:with-worker-core-or-skip
                #:with-release-worker-core-or-skip)
  (:import-from #:uiop))

(in-package #:dsmr-mcp/tests/integration/hermetic/subject-tree-worker-test)

;;; ---------------------------------------------------------------------------
;;; The subject tree
;;; ---------------------------------------------------------------------------

(defparameter *subject-system* "dsmr-mcp/src/hermetic/worker/main"
  "The subject system each worker is asked to load.")

(defparameter *load-timeout-seconds* 600
  "Seconds a worker may take to compile and load the subject.")

(defvar *subject-tree* nil
  "The subject tree for this process, made once by SUBJECT-TREE.")

(defun %this-tree ()
  "This checkout's directory, as a namestring."
  (namestring (asdf:system-source-directory "dsmr-mcp")))

(defun subject-tree ()
  "A `git archive HEAD` copy of this tree, with SUBJECT-MARKER appended to
src/hermetic/worker/main.lisp, as a directory namestring. Made once per
process and removed when the process exits."
  (or *subject-tree*
      (let* ((dir (string-right-trim
                   '(#\Newline)
                   (uiop:run-program '("mktemp" "-d" "/tmp/dsmr-subject-tree.XXXXXX")
                                     :output :string)))
             (dir (namestring (uiop:ensure-directory-pathname dir))))
        (push (lambda () (ignore-errors (uiop:delete-directory-tree
                                         (pathname dir) :validate t)))
              sb-ext:*exit-hooks*)
        (uiop:run-program
         (list "sh" "-c"
               (format nil "git -C ~A archive --format=tar HEAD | tar -x -C ~A"
                       (uiop:escape-sh-token (%this-tree))
                       (uiop:escape-sh-token dir)))
         :error-output :string)
        (with-open-file (out (merge-pathnames "src/hermetic/worker/main.lisp" dir)
                             :direction :output :if-exists :append)
          (format out "~%(defun subject-marker () :subject-tree)~%"))
        (setf *subject-tree* dir))))

(defun %under-p (path dir)
  "True when the file PATH lies under directory DIR, both compared as truenames."
  (let ((path (or (ignore-errors (truename path)) (pathname path)))
        (dir (or (ignore-errors (truename dir)) (pathname dir))))
    (and (uiop:subpathp path dir) t)))

(defun %release-root (core)
  "The release directory holding CORE, which lives at <release>/core/<file>."
  (uiop:pathname-parent-directory-pathname (uiop:pathname-directory-pathname core)))

;;; ---------------------------------------------------------------------------
;;; Loading the subject in a worker
;;; ---------------------------------------------------------------------------

(defun %eval-text (worker code)
  "Send CODE to WORKER through worker/eval and return the text of the first
content block of the reply, or NIL when there is none."
  (let ((params (make-hash-table :test 'equal)))
    (setf (gethash "code" params) code)
    (let* ((resp (worker-rpc worker "worker/eval" params))
           (content (and (hash-table-p resp) (gethash "content" resp))))
      (when (and (vectorp content) (plusp (length content)))
        (gethash "text" (aref content 0))))))

(defparameter *marker-form*
  "(let* ((p (find-package \"DSMR-MCP/SRC/HERMETIC/WORKER/MAIN\"))
          (s (and p (find-symbol \"SUBJECT-MARKER\" p))))
     (format nil \"marker=~S\" (and s (fboundp s) (funcall s))))"
  "Reports SUBJECT-MARKER's value, or NIL when the subject's function is absent.")

(defparameter *support-start-form*
  "(let* ((p (or (find-package \"DSMR-WORKER/SRC/HERMETIC/WORKER/MAIN\")
                 (find-package \"DSMR-MCP/SRC/HERMETIC/WORKER/MAIN\")))
          (s (find-symbol \"START\" p))
          (src (first (funcall (find-symbol \"FIND-DEFINITION-SOURCES-BY-NAME\" \"SB-INTROSPECT\")
                               s :function))))
     (format nil \"start-from=~A|\"
             (and src (namestring (funcall (find-symbol \"DEFINITION-SOURCE-PATHNAME\" \"SB-INTROSPECT\")
                                           src)))))"
  "Reports the file the support code's START is defined from, in DSMR-WORKER
when the image renamed its support packages, else in DSMR-MCP.")

(defun %between (text start end)
  "The part of TEXT after START and before the next END, or NIL."
  (let ((i (and text (search start text))))
    (when i
      (let* ((from (+ i (length start)))
             (to (search end text :start2 from)))
        (and to (subseq text from to))))))

(defvar *observations* (make-hash-table :test 'equal)
  "Observations of the subject load, keyed by core path, so tests sharing a core
load the subject once.")

(defun %outside-subject (redefinitions)
  "The REDEFINITIONS that name no DSMR-MCP/ package. A fresh compile of the
subject tree redefines a few of its own macros (a DEFMACRO the file compiler
has already evaluated is defined again at load), so a redefinition inside the
subject's own packages says nothing about the worker; one anywhere else does."
  (remove-if (lambda (text) (search "DSMR-MCP/" text)) redefinitions))

(defun observe-subject-load (core)
  "Spawn a worker from CORE rooted at the subject tree, load the subject system
without force so redefinitions are reported, and return a plist of what was
seen: :status, :source-directory, :redefinitions (warning texts naming a
redefinition), :marker, :start-from (file START is defined from after the load)
and :ping (round trip in ms after the load, or NIL)."
  (or (gethash core *observations*)
      (setf (gethash core *observations*)
            (let ((*error-output* (make-string-output-stream))
                  (*worker-core-disabled* nil)
                  (worker nil))
              (configure-log4cl-for-server :warn)
              (unwind-protect
                   (let ((params (make-hash-table :test 'equal)))
                     (setf worker (spawn-worker :core core :root (subject-tree)))
                     (setf (gethash "system" params) *subject-system*
                           (gethash "force" params) nil
                           (gethash "timeout_seconds" params) *load-timeout-seconds*)
                     (let* ((reply (worker-rpc worker "worker/load-system" params
                                               :timeout (+ 60 *load-timeout-seconds*)))
                            (details (coerce (or (gethash "warning_details" reply) #()) 'list)))
                       (list :status (gethash "status" reply)
                             :source-directory (gethash "source_directory" reply)
                             :redefinitions (remove-if-not
                                             (lambda (w) (search "redefin" (string-downcase w)))
                                             details)
                             :marker (%between (%eval-text worker *marker-form*) "marker=" "\"")
                             :start-from (%between (%eval-text worker *support-start-form*)
                                                   "start-from=" "|")
                             :ping (ignore-errors (worker-ping worker :timeout 10)))))
                (when worker (ignore-errors (kill-worker worker))))))))

;;; ---------------------------------------------------------------------------
;;; A release worker core
;;; ---------------------------------------------------------------------------

(define-test a-renamed-worker-loads-a-dsmr-mcp-subject-from-its-tree
  "A release worker core rooted at a dsmr-mcp tree loads the subject system
from that tree, reports the tree as its source directory, reports no
redefinition outside the subject's own packages, and the subject's own function
is there afterwards."
  (with-release-worker-core-or-skip (core)
    (let ((seen (observe-subject-load core)))
      (is equal "loaded" (getf seen :status) "~S" seen)
      (true (and (getf seen :source-directory)
                 (uiop:pathname-equal (truename (getf seen :source-directory))
                                      (truename (subject-tree))))
            "source_directory ~S; expected the subject tree ~A"
            (getf seen :source-directory) (subject-tree))
      (is equal nil (%outside-subject (getf seen :redefinitions))
          "redefinitions outside the subject's packages: ~S"
          (%outside-subject (getf seen :redefinitions)))
      (is equal ":SUBJECT-TREE" (getf seen :marker) "~S" seen))))

(define-test the-renamed-worker-keeps-its-own-code-after-the-subject-loads
  "After the subject loads, the worker's own START is still defined from the
release tree rather than the subject's, and the worker still answers a ping."
  (with-release-worker-core-or-skip (core)
    (let* ((seen (observe-subject-load core))
           (start-from (getf seen :start-from)))
      (true start-from "no definition source for START: ~S" seen)
      (when start-from
        (false (%under-p start-from (subject-tree))
               "START is defined from the subject tree: ~A" start-from)
        (true (%under-p start-from (%release-root core))
              "START is defined from ~A, outside the release ~A"
              start-from (namestring (%release-root core))))
      (true (getf seen :ping) "the worker did not answer a ping: ~S" seen))))

(defparameter *dependency-system* "com.inuoe.jzon"
  "A system the release worker core loads for itself, used as a subject.")

(defvar *dependency-subjects* (make-hash-table :test 'equal)
  "The dependency subject tree made for each release root, by DEPENDENCY-SUBJECT.")

(defun dependency-subject (core)
  "A writable copy of the jzon sources bundled in the release holding CORE,
with SUBJECT-MARKER appended to src/jzon.lisp, as a directory namestring, or
NIL when the release bundles no jzon. Made once per release and removed when
the process exits."
  (let ((release (namestring (%release-root core))))
    (or (gethash release *dependency-subjects*)
        (let ((asd (first (directory (merge-pathnames "deps/software/*/com.inuoe.jzon.asd"
                                                      release)))))
          (when asd
            (let* ((dir (string-right-trim
                         '(#\Newline)
                         (uiop:run-program '("mktemp" "-d" "/tmp/dsmr-subject-dep.XXXXXX")
                                           :output :string)))
                   (dir (namestring (uiop:ensure-directory-pathname dir))))
              (push (lambda () (ignore-errors (uiop:delete-directory-tree
                                               (pathname dir) :validate t)))
                    sb-ext:*exit-hooks*)
              (uiop:run-program
               (list "sh" "-c"
                     (format nil "cp -R ~A/. ~A && chmod -R u+w ~A"
                             (uiop:escape-sh-token
                              (namestring (uiop:pathname-directory-pathname asd)))
                             (uiop:escape-sh-token dir)
                             (uiop:escape-sh-token dir)))
               :error-output :string)
              (with-open-file (out (merge-pathnames "src/jzon.lisp" dir)
                                   :direction :output :if-exists :append)
                (format out "~%(defun subject-marker () :subject-tree)~%"))
              (setf (gethash release *dependency-subjects*) dir)))))))

(defun observe-dependency-load (core subject &key (system *dependency-system*)
                                                  (package "COM.INUOE.JZON"))
  "Spawn a worker from CORE rooted at SUBJECT, load SYSTEM (default
*dependency-system*) without force, and return a plist of :status,
:source-directory and :marker, the value SUBJECT-MARKER returns in PACKAGE, or
NIL when it is absent."
  (let ((*error-output* (make-string-output-stream))
        (*worker-core-disabled* nil)
        (worker nil))
    (configure-log4cl-for-server :warn)
    (unwind-protect
         (let ((params (make-hash-table :test 'equal)))
           (setf worker (spawn-worker :core core :root subject))
           (setf (gethash "system" params) system
                 (gethash "force" params) nil
                 (gethash "timeout_seconds" params) *load-timeout-seconds*)
           (let ((reply (worker-rpc worker "worker/load-system" params
                                    :timeout (+ 60 *load-timeout-seconds*))))
             (list :status (gethash "status" reply)
                   :source-directory (gethash "source_directory" reply)
                   :marker (%between
                            (%eval-text worker
                                        (format nil "(let* ((p (find-package ~S))
                                                (s (and p (find-symbol \"SUBJECT-MARKER\" p))))
                                           (format nil \"marker=~~S\" (and s (fboundp s) (funcall s))))"
                                                package))
                            "marker=" "\""))))
      (when worker (ignore-errors (kill-worker worker))))))

(define-test a-worker-rooted-at-a-dependency-loads-that-tree
  "A release worker core rooted at a copy of jzon, which the core itself loads,
loads com.inuoe.jzon from that copy: the reply names the copy as the source
directory, and the copy's own function is there afterwards."
  (with-release-worker-core-or-skip (core)
    (let ((subject (dependency-subject core)))
      (if (null subject)
          (skip ("the release holding ~A bundles no jzon" core))
          (let ((seen (observe-dependency-load core subject)))
            (is equal "loaded" (getf seen :status) "~S" seen)
            (true (and (getf seen :source-directory)
                       (uiop:pathname-equal (truename (getf seen :source-directory))
                                            (truename subject)))
                  "source_directory ~S; expected the subject tree ~A"
                  (getf seen :source-directory) subject)
            (is equal ":SUBJECT-TREE" (getf seen :marker) "~S" seen))))))

(defvar *nested-subjects* (make-hash-table :test 'equal)
  "The nested subject trees made by NESTED-SUBJECT, keyed by release and layout.")

(defun nested-subject (core layout)
  "A writable subject tree whose .asd sits one directory below the root, made
from the sources bundled in the release holding CORE, with SUBJECT-MARKER
appended to one source file. LAYOUT :jzon puts a copy of jzon under src/, as
upstream jzon lays out its sources; LAYOUT :slynk copies the sly tree, which
keeps slynk.asd in slynk/. Returns (root . asd-directory) as namestrings, or
NIL when the release bundles no such system. Made once per release and layout
and removed when the process exits."
  (let* ((release (namestring (%release-root core)))
         (key (format nil "~A|~A" release layout)))
    (or (gethash key *nested-subjects*)
        (destructuring-bind (pattern up below marker-file)
            (ecase layout
              (:jzon '("deps/software/*/com.inuoe.jzon.asd" 0 "src/" "src/jzon.lisp"))
              (:slynk '("deps/software/*/slynk/slynk.asd" 1 "" "slynk/slynk.lisp")))
          (let ((asd (first (directory (merge-pathnames pattern release)))))
            (when asd
              (let* ((from (uiop:pathname-directory-pathname asd))
                     (from (if (= up 1) (uiop:pathname-parent-directory-pathname from) from))
                     (root (namestring
                            (uiop:ensure-directory-pathname
                             (string-right-trim
                              '(#\Newline)
                              (uiop:run-program '("mktemp" "-d" "/tmp/dsmr-subject-nested.XXXXXX")
                                                :output :string)))))
                     (copy (namestring (merge-pathnames below root))))
                (push (lambda () (ignore-errors (uiop:delete-directory-tree
                                                 (pathname root) :validate t)))
                      sb-ext:*exit-hooks*)
                (uiop:run-program
                 (list "sh" "-c"
                       (format nil "mkdir -p ~A && cp -R ~A/. ~A && chmod -R u+w ~A"
                               (uiop:escape-sh-token copy)
                               (uiop:escape-sh-token (namestring from))
                               (uiop:escape-sh-token copy)
                               (uiop:escape-sh-token root)))
                 :error-output :string)
                (with-open-file (out (merge-pathnames marker-file copy)
                                     :direction :output :if-exists :append)
                  (format out "~%(defun subject-marker () :subject-tree)~%"))
                (setf (gethash key *nested-subjects*)
                      (cons root (namestring (uiop:pathname-directory-pathname
                                              (merge-pathnames (enough-namestring asd from)
                                                               copy))))))))))))

(defun %check-nested-load (core layout system package)
  "Root a release worker from CORE at the LAYOUT subject of NESTED-SUBJECT, load
SYSTEM, and assert that it loaded from the subject's nested .asd directory and
that SUBJECT-MARKER is defined in PACKAGE afterwards."
  (let ((subject (nested-subject core layout)))
    (if (null subject)
        (skip ("the release holding ~A bundles no ~A" core system))
        (destructuring-bind (root . asd-dir) subject
          (let ((seen (observe-dependency-load core root :system system :package package)))
            (is equal "loaded" (getf seen :status) "~S" seen)
            (true (and (getf seen :source-directory)
                       (uiop:pathname-equal (truename (getf seen :source-directory))
                                            (truename asd-dir)))
                  "source_directory ~S; expected the subject's ~A"
                  (getf seen :source-directory) asd-dir)
            (is equal ":SUBJECT-TREE" (getf seen :marker) "~S" seen))))))

(define-test a-dependency-with-a-nested-asd-loads-from-the-subject
  "A release worker rooted at a tree that keeps jzon's .asd in src/, as upstream
jzon does, loads com.inuoe.jzon from that directory rather than the copy the
worker core holds."
  (with-release-worker-core-or-skip (core)
    (%check-nested-load core :jzon "com.inuoe.jzon" "COM.INUOE.JZON")))

(define-test a-sly-tree-loads-its-own-slynk
  "A release worker rooted at a sly tree, which keeps slynk.asd in slynk/, loads
slynk from that directory rather than the copy the worker core holds."
  (with-release-worker-core-or-skip (core)
    (%check-nested-load core :slynk "slynk" "SLYNK")))

;;; ---------------------------------------------------------------------------
;;; Controls
;;; ---------------------------------------------------------------------------

(define-test an-unrenamed-worker-is-clobbered-by-the-subject
  "Control: a dev worker core keeps its support code under the DSMR-MCP names,
so the same load redefines that code, which the main assertions catch as a
redefinition outside the subject's packages or START defined from the subject
tree."
  (with-worker-core-or-skip (core)
    (let* ((seen (observe-subject-load core))
           (start-from (getf seen :start-from)))
      (true (or (%outside-subject (getf seen :redefinitions))
                (and start-from (%under-p start-from (subject-tree))))
            "the unrenamed worker was not clobbered: ~S" seen))))

(define-test the-old-command-line-never-loads-the-subject
  "Control: a dev worker core started with the command line workers had before
the rename, which put this server's tree first in ASDF's lookup, loads the
subject system from that tree, so the subject's function never appears. The
child runs the load a load-system request would run, in place of START."
  (with-worker-core-or-skip (core)
    (let* ((tree (%this-tree))
           (output
             (uiop:run-program
              (list "env" (format nil "DSMR_PROJECT_ROOT=~A" (subject-tree))
                    (sbcl-path) "--core" (namestring core)
                    "--noinform" "--disable-debugger" "--no-userinit" "--non-interactive"
                    "--eval" (format nil "(progn (asdf:clear-source-registry) (pushnew (pathname ~S) asdf:*central-registry* :test (function equal)))"
                                     tree)
                    "--eval" (format nil "(let ((*standard-output* *error-output*)) (asdf:load-system ~S))"
                                     *subject-system*)
                    "--eval" (format nil "(format t \"~~A~~%\" ~A)" *marker-form*))
              :output :string :error-output nil :ignore-error-status t)))
      (true (search "marker=" output) "the child printed no marker line: ~S" output)
      (true (search "marker=NIL" output) "the subject loaded: ~S" output))))
