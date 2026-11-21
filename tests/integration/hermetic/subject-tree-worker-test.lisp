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
