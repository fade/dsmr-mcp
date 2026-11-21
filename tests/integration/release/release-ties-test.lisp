;;;; tests/integration/release/release-ties-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; The control set for the release guard: four planted ties that must turn
;;;; red, and one deployed release that must stay green.
;;;;
;;;;   a launcher inside a work tree       the release launcher refuses with 78
;;;;   a launcher that runs make           the old checkout launcher runs make on
;;;;                                       a stale core; the release launcher never does
;;;;   an unsealed image in a checkout     GUARD-MAIN in the test core exits 1 and
;;;;                                       names a dsmr-mcp system in a checkout
;;;;   a release with no worker core       the worker client refuses a source worker
;;;;   a deployed release                  GUARD-MAIN in its core exits 0 with no tie
;;;;
;;;; The launcher cases reuse the fake releases and stub programs of
;;;; launcher-release-test. The image cases boot DSMR_BROKER_CORE, the test
;;;; core make test-integration passes, in a child whose environment holds no
;;;; inherited DSMR_ variable. The old launcher is read from commit 16d1e20 with
;;;; git show; a clone without that commit skips the case. The release case
;;;; reads DSMR_TEST_RELEASE_HOME, a deploy home holding a release made by
;;;; make deploy, and skips without it.

(defpackage #:dsmr-mcp/tests/integration/release/release-ties-test
  (:use #:cl #:zebra)
  (:import-from #:dsmr-mcp/tests/integration/support
                #:sbcl-path
                #:server-child-environment
                #:fresh-server-child-state-home)
  (:import-from #:dsmr-mcp/tests/integration/scripts/launcher-release-test
                #:with-fake-release
                #:%launch
                #:%entry
                #:%refused-p
                #:%make-ran-p
                #:%write-file
                #:%git-available-p
                #:%run
                #:%path))

(in-package #:dsmr-mcp/tests/integration/release/release-ties-test)

(defparameter *old-launcher-commit* "16d1e20"
  "A commit whose scripts/dsmr-mcp-launch.sh rebuilds a stale core with make.")

(defparameter *child-timeout* 180
  "Seconds a child SBCL may run before timeout(1) stops it.")

(defun %source-directory ()
  "The dsmr-mcp source directory as a native namestring."
  (uiop:native-namestring (asdf:system-source-directory "dsmr-mcp")))

(defun %old-launcher ()
  "The text of scripts/dsmr-mcp-launch.sh at *OLD-LAUNCHER-COMMIT*, or NIL when
git cannot show it."
  (multiple-value-bind (out err rc)
      (uiop:run-program (list "git" "-C" (%source-directory) "show"
                              (format nil "~A:scripts/dsmr-mcp-launch.sh"
                                      *old-launcher-commit*))
                        :output :string :error-output :string
                        :ignore-error-status t)
    (declare (ignore err))
    (and (eql rc 0) (plusp (length out)) out)))

(defun %core-path (value)
  "VALUE as a native namestring when it names an existing file, else NIL."
  (and value (plusp (length value)) (probe-file value)
       (uiop:native-namestring (probe-file value))))

(defun %boot-image (core forms &key assignments)
  "Boot CORE with no init files, evaluate each string of FORMS in order, and
return the exit code and the combined output. The environment is this
process's without any DSMR_ variable, with XDG_STATE_HOME at a fresh
directory and ASSIGNMENTS (NAME=VALUE strings) added."
  (let ((state (fresh-server-child-state-home)))
    (unwind-protect
         (multiple-value-bind (out err rc)
             (uiop:run-program
              (append (list "timeout" (princ-to-string *child-timeout*)
                            (sbcl-path) "--core" core
                            "--noinform" "--non-interactive"
                            "--no-sysinit" "--no-userinit")
                      (loop for form in forms append (list "--eval" form)))
              :input nil :output :string :error-output :string
              :ignore-error-status t
              :environment (server-child-environment state :assignments assignments))
           (values rc (concatenate 'string out err)))
      (ignore-errors (uiop:delete-directory-tree state :validate t
                                                       :if-does-not-exist :ignore)))))

(defun %lines-with-prefix (prefix text)
  "The lines of TEXT that start with PREFIX."
  (remove-if-not (lambda (line) (uiop:string-prefix-p prefix line))
                 (uiop:split-string text :separator '(#\Newline))))

(defun %tail (string)
  "The last 2000 characters of STRING."
  (subseq string (max 0 (- (length string) 2000))))

(defparameter +guard-form+ "(dsmr-mcp/src/release:guard-main)"
  "The form that prints the guard report and exits with its status.")

(defparameter +loaded-count-form+
  "(format t \"~&@@ loaded-dsmr-mcp ~D~%\"
     (count-if (lambda (entry) (uiop:string-prefix-p \"dsmr-mcp\" (car entry)))
               (dsmr-mcp/src/release:loaded-system-directories)))"
  "Prints how many dsmr-mcp systems the guard examines.")

;;; ---------------------------------------------------------------------------
;;; Launcher ties
;;; ---------------------------------------------------------------------------

(define-test a-launcher-in-a-work-tree-is-refused
  "The release launcher of a release under a git work tree exits 78, boots
nothing, and its stderr names the work tree."
  (if (not (%git-available-p))
      (skip "git is unavailable in this environment")
      (with-fake-release (tmp home)
        (%run "git" "init" "-q" (%path tmp))
        (multiple-value-bind (rc out err) (%launch tmp (%entry home))
          (%refused-p rc out err tmp "make register")
          (true (search "is inside a git work tree" err)
                "stderr does not name the work tree; stderr:~%~A" err)))))

(define-test only-the-old-launcher-runs-make
  "With a stale core beside it the old checkout launcher runs make; the release
launcher of a release with no core does not."
  (let ((old (and (%git-available-p) (%old-launcher))))
    (if (null old)
        (skip ("git cannot show scripts/dsmr-mcp-launch.sh at ~A; fetch the full history"
               *old-launcher-commit*))
        (with-fake-release (tmp home :core nil)
          (%launch tmp (%entry home))
          (false (%make-ran-p tmp :wait 3) "the release launcher ran make")
          (let ((launcher (merge-pathnames "checkout/scripts/dsmr-mcp-launch.sh" tmp)))
            (%write-file launcher old :executable t)
            (%write-file (merge-pathnames "checkout/dsmr.core" tmp) "decoy")
            (%write-file (merge-pathnames "checkout/dsmr.core.manifest" tmp)
                         (format nil "sbcl-version 9.9.9~%"))
            (%launch tmp (%path launcher))
            (true (%make-ran-p tmp :wait 10)
                  "the old launcher did not run make on a stale core; the stub make never ran"))))))

;;; ---------------------------------------------------------------------------
;;; Image ties
;;; ---------------------------------------------------------------------------

(defmacro with-test-core ((core) &body body)
  "Bind CORE to the file DSMR_BROKER_CORE names and evaluate BODY, or skip."
  `(let ((,core (%core-path (uiop:getenv "DSMR_BROKER_CORE"))))
     (if (null ,core)
         (skip "DSMR_BROKER_CORE names no core file; run under make test-integration or set it to the test core")
         (progn ,@body))))

(define-test an-unsealed-image-in-a-checkout-is-tied
  "The test core, unsealed and loaded from this checkout, booted with a release
root reports red and names a dsmr-mcp system in a checkout."
  (with-test-core (core)
    (let ((root (uiop:ensure-directory-pathname (fresh-server-child-state-home))))
      (unwind-protect
           (multiple-value-bind (rc output)
               (%boot-image core (list +guard-form+)
                            :assignments (list (concatenate 'string "DSMR_RELEASE_ROOT="
                                                            (uiop:native-namestring root))))
             (is eql 1 rc "the guard exited ~S, not 1; output:~%~A" rc (%tail output))
             (true (%lines-with-prefix "sealed nil" output)
                   "the report does not say the image is unsealed; output:~%~A" (%tail output))
             (true (%lines-with-prefix "tie checkout dsmr-mcp" output)
                   "no tie names a dsmr-mcp system in a checkout; output:~%~A" (%tail output)))
        (ignore-errors (uiop:delete-directory-tree root :validate t
                                                        :if-does-not-exist :ignore))))))

(define-test a-release-without-a-worker-core-spawns-no-source-worker
  "With a release root, no DSMR_WORKER_CORE and no DSMR_ALLOW_SOURCE_WORKERS,
spawning a worker signals WORKER-SPAWN-FAILED of kind :NO-WORKER-CORE."
  (with-test-core (core)
    (let ((root (uiop:ensure-directory-pathname (fresh-server-child-state-home))))
      (unwind-protect
           (multiple-value-bind (rc output)
               (%boot-image
                core
                (list "(handler-case
                         (progn (dsmr-mcp/src/hermetic/worker-client:spawn-worker)
                                (format t \"~&@@ kind spawned~%\"))
                       (dsmr-mcp/src/hermetic/worker-client:worker-spawn-failed (e)
                         (format t \"~&@@ kind ~S~%\"
                                 (dsmr-mcp/src/hermetic/worker-client:worker-spawn-failed-kind e))))")
                :assignments (list (concatenate 'string "DSMR_RELEASE_ROOT="
                                                (uiop:native-namestring root))))
             (declare (ignore rc))
             (true (%lines-with-prefix "@@ kind :NO-WORKER-CORE" output)
                   "the spawn was not refused with :NO-WORKER-CORE; output:~%~A" (%tail output)))
        (ignore-errors (uiop:delete-directory-tree root :validate t
                                                        :if-does-not-exist :ignore))))))

;;; ---------------------------------------------------------------------------
;;; The green control
;;; ---------------------------------------------------------------------------

(define-test a-deployed-release-is-untied
  "The server core of the release DSMR_TEST_RELEASE_HOME's current names,
booted with that release's root and launcher, examines its dsmr-mcp systems and
reports green with no tie."
  (let* ((home (uiop:getenv "DSMR_TEST_RELEASE_HOME"))
         (current (and home (plusp (length home))
                       (probe-file (uiop:ensure-directory-pathname
                                    (merge-pathnames "current/"
                                                     (uiop:ensure-directory-pathname home))))))
         (core (and current (%core-path (uiop:native-namestring
                                         (merge-pathnames "core/dsmr.core" current))))))
    (if (null core)
        (skip "set DSMR_TEST_RELEASE_HOME to a deploy home whose current holds a release (make deploy into a scratch DSMR_HOME)")
        (let ((root (uiop:native-namestring current)))
          (multiple-value-bind (rc output)
              (%boot-image core (list +loaded-count-form+ +guard-form+)
                           :assignments
                           (list (concatenate 'string "DSMR_RELEASE_ROOT=" root)
                                 (concatenate 'string "DSMR_LAUNCHER_PATH=" root
                                              "bin/dsmr-mcp-launch")))
            (is eql 0 rc "the guard exited ~S, not 0; output:~%~A" rc (%tail output))
            (true (%lines-with-prefix "sealed t" output)
                  "the release image is not sealed; output:~%~A" (%tail output))
            (true (%lines-with-prefix "ties 0" output)
                  "the release reports ties; output:~%~A" (%tail output))
            (let ((count (first (%lines-with-prefix "@@ loaded-dsmr-mcp " output))))
              (true (and count
                         (plusp (or (parse-integer count :start (length "@@ loaded-dsmr-mcp ")
                                                         :junk-allowed t)
                                    0)))
                    "the guard examined no dsmr-mcp system, so its green proves nothing; output:~%~A"
                    (%tail output))))))))
