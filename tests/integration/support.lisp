;;;; tests/integration/support.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Shared spawn-precondition probes for the cross-process integration suite.
;;;;
;;;; Every integration leaf forks a real SBCL child. A child can fail to come up
;;;; for two very different reasons, and they demand opposite verdicts:
;;;;
;;;;   * the environment cannot build what the child needs — no sbcl, no
;;;;     Quicklisp, or the project (or slynk) not resolvable in a fresh image.
;;;;     The suite is simply unsupported here and the test must SKIP.
;;;;
;;;;   * the child's systems DO build, but bring-up still fails — handshake
;;;;     timeout, crash, auth reject, a dropped wire. That is exactly the
;;;;     regression class these tests exist to catch, and it must FAIL loudly.
;;;;
;;;; A presence check on sbcl + setup.lisp cannot tell these apart: a runner
;;;; with Quicklisp installed but the project off the child's source registry
;;;; passes the presence check, then the child fails to build — and the test
;;;; reports a failure instead of the intended skip. Zebra's SKIP records a
;;;; skipped result and then stands the enclosing test down, so a bare
;;;; `(unless (spawnable) (skip ...))` guard would also work. The branch below is
;;;; kept because it says in the code which side runs, rather than resting on how
;;;; SKIP unwinds.
;;;;
;;;; This module closes both gaps. A one-shot build probe spawns a throwaway
;;;; child that does nothing but resolve and load the systems the real child
;;;; needs, then exits 0 (buildable) or non-zero (not). If the probe cannot
;;;; build, the environment is unsupported -> skip; if it can, every later
;;;; bring-up failure is a genuine defect -> fail. The probe result is memoized,
;;;; so it costs one extra child per image regardless of how many leaves consult
;;;; it — and because that child compiles into the same fasl cache the real
;;;; workers use, the cost is paid once and reused, not doubled. The WITH-*-OR-SKIP
;;;; macros run their body only on a buildable environment and otherwise SKIP
;;;; without evaluating it, so the skip actually takes effect.
;;;;
;;;; Server children run under a private state root in /tmp with no inherited
;;;; DSMR_ setting. A process still running under that root after the server
;;;; child exits fails the test, and the cleanup stops it by root, never by name.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-posix))

(defpackage #:dsmr-mcp/tests/integration/support
  (:use #:cl)
  (:import-from #:zebra #:skip #:true #:false)
  (:export #:sbcl-path
           #:quicklisp-setup-path
           #:worker-child-buildable
           #:foreign-slynk-child-buildable
           #:mcp-server-child-buildable
           #:reset-build-probes
           #:with-worker-child-or-skip
           #:with-foreign-slynk-child-or-skip
           #:with-mcp-server-child-or-skip
           #:worker-core-for-tests
           #:with-worker-core-or-skip
           #:fresh-server-child-state-home
           #:server-child-environment
           #:launch-server-child
           #:processes-under-state-home
           #:stop-processes-under-state-home
           #:with-server-child-state-home))

(in-package #:dsmr-mcp/tests/integration/support)

;;; ---------------------------------------------------------------------------
;;; Environment presence
;;; ---------------------------------------------------------------------------

(defun sbcl-path ()
  "Absolute path to an sbcl binary, or NIL if none is on PATH or in the usual
locations."
  (or (ignore-errors
        (let ((r (string-trim '(#\Newline #\Return #\Space)
                              (uiop:run-program '("which" "sbcl")
                                                :output :string
                                                :ignore-error-status t))))
          (and (plusp (length r)) r)))
      (let ((p (find-if #'probe-file
                        '("/usr/local/bin/sbcl" "/usr/bin/sbcl" "/opt/local/bin/sbcl"))))
        (and p (namestring p)))))

(defun quicklisp-setup-path ()
  "Absolute path to the user's Quicklisp setup.lisp if present, else NIL."
  (let ((p (probe-file (merge-pathnames "quicklisp/setup.lisp"
                                        (user-homedir-pathname)))))
    (and p (namestring p))))

;;; ---------------------------------------------------------------------------
;;; One-shot build probe
;;; ---------------------------------------------------------------------------

(defparameter *build-probe-timeout* 180
  "Seconds to allow a build-probe child to resolve and compile its systems on a
cold fasl cache before declaring the environment unable to build it. Generous on
purpose: a false skip (capable-but-slow runner) silently drops real coverage, so
err toward waiting.")

(defun %tail (string n)
  "The last N characters of STRING (all of it if shorter), or NIL."
  (when string
    (subseq string (max 0 (- (length string) n)))))

(defun %run-build-probe (eval-program)
  "Spawn a throwaway bare SBCL that runs EVAL-PROGRAM (a list of \"--eval\" FORM
strings) and exits. The forms must exit 0 on a successful build and non-zero on
any failure. Returns (values OK-P DETAIL): OK-P is true iff the child exited 0
within the timeout; DETAIL is the child's combined output tail for diagnostics.
Never signals — a probe that cannot even launch returns (values NIL reason)."
  (let ((sbcl (sbcl-path)))
    (unless sbcl
      (return-from %run-build-probe (values nil "no sbcl on PATH")))
    (let ((out (uiop:tmpize-pathname
                (merge-pathnames "dsmr-build-probe.log"
                                 (uiop:temporary-directory))))
          (proc nil))
      (unwind-protect
           (handler-case
               (progn
                 (setf proc (uiop:launch-program
                             (list* sbcl "--noinform" "--non-interactive"
                                    "--no-userinit" eval-program)
                             :output out :error-output out))
                 ;; Poll to a deadline, then kill — never block forever on a
                 ;; child that wedged mid-compile.
                 (loop repeat (ceiling *build-probe-timeout* 0.25)
                       while (uiop:process-alive-p proc)
                       do (sleep 0.25))
                 (if (uiop:process-alive-p proc)
                     (progn
                       (ignore-errors (uiop:terminate-process proc :urgent t))
                       (ignore-errors (uiop:wait-process proc))
                       (values nil (format nil "build probe exceeded ~Ds~@[~%--- output tail ---~%~A~]"
                                           *build-probe-timeout*
                                           (%tail (ignore-errors (uiop:read-file-string out)) 2000))))
                     (let ((rc (uiop:wait-process proc)))
                       (values (eql rc 0)
                               (%tail (ignore-errors (uiop:read-file-string out)) 2000)))))
             (error (e)
               (values nil (princ-to-string e))))
        (ignore-errors
          (when (and proc (uiop:process-alive-p proc))
            (uiop:terminate-process proc :urgent t)
            (uiop:wait-process proc)))
        (ignore-errors (delete-file out))))))

(defun %worker-build-eval-program ()
  "The --eval program a build probe runs to mirror what the hermetic worker
child does up to (but not including) starting its server: load Quicklisp, point
the source registry at the project tree exactly as %build-sbcl-args does, then
load the worker system. Exits 0 on success, 7 on any build/resolution error."
  (let ((src (namestring (asdf:system-source-directory :dsmr-mcp)))
        (ql (quicklisp-setup-path)))
    (append
     (when ql (list "--load" ql))
     (list "--eval"
           (concatenate 'string
             "(handler-case (progn "
             "(asdf:initialize-source-registry '(:source-registry :inherit-configuration (:tree "
             (prin1-to-string src)
             "))) "
             "(asdf:load-system :dsmr-mcp/src/hermetic/worker/main) "
             "(sb-ext:exit :code 0)) "
             "(error (e) (format *error-output* \"BUILD-PROBE-FAILED: ~A~%\" e) "
             "(sb-ext:exit :code 7)))")))))

(defun %foreign-slynk-build-eval-program ()
  "The --eval program a build probe runs to mirror what the cross-process foreign
children need: load Quicklisp if present, then quickload slynk + alexandria +
zebra (the wire leaf probes alexandria; the run-tests leaf runs a zebra
suite). Exits 0 on success, 7 on any resolution error."
  (list
   "--eval" "(require :asdf)"
   "--eval" (concatenate 'string
              "(let ((q (merge-pathnames \"quicklisp/setup.lisp\" (user-homedir-pathname)))) "
              "(when (and (probe-file q) (not (find-package :ql))) (load q)))")
   "--eval" (concatenate 'string
              "(handler-case (progn "
              "(funcall (read-from-string \"ql:quickload\") (list :slynk :alexandria :zebra) :silent t) "
              "(sb-ext:exit :code 0)) "
              "(error (e) (format *error-output* \"BUILD-PROBE-FAILED: ~A~%\" e) "
              "(sb-ext:exit :code 7)))")))

(defun %mcp-server-build-eval-program ()
  "The --eval program a build probe runs to mirror what a spawned full stdio
server child does up to (but not including) starting the transport: load
Quicklisp so dependencies resolve to their dist-pinned versions, register the
project directory plus :inherit-configuration, then load the whole dsmr-mcp
system. Exits 0 on success, 7 on any build/resolution error."
  (let ((project (uiop:truename* (asdf:system-source-directory "dsmr-mcp")))
        (ql (quicklisp-setup-path)))
    (append
     (when ql (list "--load" ql))
     (list "--eval"
           (concatenate 'string
             "(handler-case (progn "
             "(asdf:initialize-source-registry '(:source-registry"
             (if project (format nil " (:directory ~S)" (namestring project)) "")
             " :inherit-configuration)) "
             "(asdf:load-system :dsmr-mcp) "
             "(sb-ext:exit :code 0)) "
             "(error (e) (format *error-output* \"BUILD-PROBE-FAILED: ~A~%\" e) "
             "(sb-ext:exit :code 7)))")))))

;;; ---------------------------------------------------------------------------
;;; Memoized verdicts
;;; ---------------------------------------------------------------------------

(defvar *worker-child-build* :unknown
  "Memoized worker-child build verdict: :UNKNOWN, :OK, or (:UNAVAILABLE . detail).")
(defvar *foreign-slynk-child-build* :unknown
  "Memoized foreign-slynk-child build verdict, same shape as *WORKER-CHILD-BUILD*.")
(defvar *mcp-server-child-build* :unknown
  "Memoized full-dsmr-mcp-server-child build verdict, same shape as *WORKER-CHILD-BUILD*.")

(defvar *worker-core-build* :unknown
  "Memoized worker core for the tests that boot workers from one: :UNKNOWN,
(:OK . path), or (:UNAVAILABLE . detail).")

(defun reset-build-probes ()
  "Forget memoized build verdicts so the next consult re-probes. Mainly for
interactive re-runs after fixing a registry."
  (setf *worker-child-build* :unknown
        *foreign-slynk-child-build* :unknown
        *mcp-server-child-build* :unknown
        *worker-core-build* :unknown)
  (values))

(defun %verdict (place-symbol program-fn)
  "Resolve a memoized build verdict cell. PLACE-SYMBOL names a special holding
:UNKNOWN / :OK / (:UNAVAILABLE . detail); PROGRAM-FN returns the probe's eval
program. Returns (values OK-P DETAIL)."
  (when (eq (symbol-value place-symbol) :unknown)
    (setf (symbol-value place-symbol)
          (cond ((not (sbcl-path)) (cons :unavailable "no sbcl on PATH"))
                ((not (quicklisp-setup-path)) (cons :unavailable "no Quicklisp setup.lisp"))
                (t (multiple-value-bind (ok detail)
                       (%run-build-probe (funcall program-fn))
                     (if ok :ok (cons :unavailable (or detail "child could not build"))))))))
  (let ((v (symbol-value place-symbol)))
    (if (eq v :ok) (values t nil) (values nil (cdr v)))))

(defun worker-child-buildable ()
  "Memoized (values OK-P DETAIL): true iff a fresh child can resolve and load the
hermetic worker system in this environment."
  (%verdict '*worker-child-build* #'%worker-build-eval-program))

(defun foreign-slynk-child-buildable ()
  "Memoized (values OK-P DETAIL): true iff a fresh child can quickload slynk +
alexandria + zebra in this environment."
  (%verdict '*foreign-slynk-child-build* #'%foreign-slynk-build-eval-program))

(defun mcp-server-child-buildable ()
  "Memoized (values OK-P DETAIL): true iff a fresh child can resolve and load the
full dsmr-mcp system in this environment — the precondition for spawning a real
stdio server subprocess."
  (%verdict '*mcp-server-child-build* #'%mcp-server-build-eval-program))

;;; ---------------------------------------------------------------------------
;;; Worker core for tests
;;;
;;; Tests that boot workers from the worker core need one built from the tree
;;; under test, not whatever image happens to be installed. It is built once per
;;; test process into a scratch directory, with DSMR_WORKER_EVAL_TIMEOUT set to 7
;;; during the build: a core that froze its settings at build time would answer
;;; 7 where the worker's own environment says otherwise, so a test can tell.
;;; ---------------------------------------------------------------------------

(defparameter *worker-core-build-timeout* 900
  "Seconds to allow `make core-worker` to build, verify and install the test
worker core before giving up on it.")

(defun %make-scratch-directory ()
  "Create a fresh private temporary directory and return its pathname."
  (uiop:ensure-directory-pathname
   (string-trim '(#\Newline #\Return #\Space)
                (uiop:run-program '("mktemp" "-d" "-t" "dsmr-worker-core.XXXXXX")
                                  :output :string))))

(defun %build-worker-core-for-tests ()
  "Build a worker core from this tree into a new scratch directory. Returns
(values PATH NIL) on success, else (values NIL DETAIL) with the end of the build
output. The directory is removed when this process exits, or at once when the
build fails."
  (let ((dir nil) (proc nil))
    (handler-case
        (let* ((repo (namestring (asdf:system-source-directory "dsmr-mcp")))
               (scratch (setf dir (%make-scratch-directory)))
               (core (namestring (merge-pathnames "dsmr.core.worker" scratch)))
               (log (merge-pathnames "build.log" scratch)))
          (setf proc (uiop:launch-program
                      (list "env" "DSMR_WORKER_EVAL_TIMEOUT=7"
                            "make" "-C" repo "core-worker"
                            (format nil "WORKER_CORE=~A" core))
                      :output log :error-output log))
          (loop repeat (ceiling *worker-core-build-timeout* 0.5)
                while (uiop:process-alive-p proc)
                do (sleep 0.5))
          (let* ((timed-out (uiop:process-alive-p proc))
                 (rc (progn
                       (when timed-out
                         (ignore-errors (uiop:terminate-process proc :urgent t)))
                       (uiop:wait-process proc)))
                 (tail (%tail (ignore-errors (uiop:read-file-string log)) 2000)))
            (cond ((and (not timed-out) (eql rc 0) (probe-file core))
                   (push (lambda ()
                           (ignore-errors
                            (uiop:delete-directory-tree scratch :validate t)))
                         sb-ext:*exit-hooks*)
                   (values core nil))
                  (t
                   (ignore-errors (uiop:delete-directory-tree scratch :validate t))
                   (values nil
                           (format nil "make core-worker ~:[exited ~A~*~;exceeded ~*~Ds~]~@[~%--- output tail ---~%~A~]"
                                   timed-out rc *worker-core-build-timeout* tail))))))
      (error (e)
        (when (and proc (uiop:process-alive-p proc))
          (ignore-errors (uiop:terminate-process proc :urgent t))
          (ignore-errors (uiop:wait-process proc)))
        (when dir
          (ignore-errors (uiop:delete-directory-tree dir :validate t)))
        (values nil (princ-to-string e))))))

(defun worker-core-for-tests ()
  "A worker core for tests to boot workers from, as (values PATH DETAIL).

When DSMR_TEST_WORKER_CORE names an existing file that file is used, which
saves the build while iterating. Otherwise a core is built from this tree once
per process and the answer memoized in *worker-core-build*; reset-build-probes
forgets it. PATH is NIL when no core could be had, and DETAIL then says why."
  (let ((given (uiop:getenv "DSMR_TEST_WORKER_CORE")))
    (if (and given (plusp (length given)) (probe-file given))
        (values given nil)
        (progn
          (when (eq *worker-core-build* :unknown)
            (setf *worker-core-build*
                  (multiple-value-bind (path detail) (%build-worker-core-for-tests)
                    (if path
                        (cons :ok path)
                        (cons :unavailable (or detail "worker core build failed"))))))
          (let ((v *worker-core-build*))
            (if (eq (car v) :ok)
                (values (cdr v) nil)
                (values nil (cdr v))))))))

;;; ---------------------------------------------------------------------------
;;; Guard macros — run BODY only on a buildable environment, else SKIP it
;;; ---------------------------------------------------------------------------

(defmacro with-worker-child-or-skip (&body body)
  "Evaluate BODY only when a fresh child can build the hermetic worker system
here; otherwise zebra:skip the enclosing test WITHOUT evaluating BODY. Skips
only on a build/resolution failure — a buildable-but-misbehaving child runs BODY
and is free to fail, which is the regression signal these tests exist to catch."
  (let ((ok (gensym "OK")) (detail (gensym "DETAIL")))
    `(multiple-value-bind (,ok ,detail) (worker-child-buildable)
       (if ,ok
           (progn ,@body)
           (skip ("hermetic worker child could not build in this environment: ~A" ,detail))))))

(defmacro with-foreign-slynk-child-or-skip (&body body)
  "Evaluate BODY only when a fresh child can quickload slynk + alexandria here;
otherwise zebra:skip the enclosing test WITHOUT evaluating BODY. Skips only
on a build/resolution failure — once slynk is known buildable, an unreachable
child (port race, dropped wire) is a genuine failure and is left to fail."
  (let ((ok (gensym "OK")) (detail (gensym "DETAIL")))
    `(multiple-value-bind (,ok ,detail) (foreign-slynk-child-buildable)
       (if ,ok
           (progn ,@body)
           (skip ("foreign slynk child could not build in this environment: ~A" ,detail))))))

(defmacro with-mcp-server-child-or-skip (&body body)
  "Evaluate BODY only when a fresh child can build the full dsmr-mcp system here;
otherwise zebra:skip the enclosing test WITHOUT evaluating BODY. Skips only on
a build/resolution failure — once the server child is known buildable, a spawned
server that misbehaves is a genuine failure and is left to fail."
  (let ((ok (gensym "OK")) (detail (gensym "DETAIL")))
    `(multiple-value-bind (,ok ,detail) (mcp-server-child-buildable)
       (if ,ok
           (progn ,@body)
           (skip ("dsmr-mcp server child could not build in this environment: ~A" ,detail))))))

(defmacro with-worker-core-or-skip ((var) &body body)
  "Evaluate BODY with VAR bound to the path of a worker core built from this
tree (see worker-core-for-tests); when none can be had, zebra:skip the enclosing
test WITHOUT evaluating BODY. Skips only when the core cannot be built: a core
that builds but whose workers misbehave runs BODY and is free to fail."
  (let ((detail (gensym "DETAIL")))
    `(multiple-value-bind (,var ,detail) (worker-core-for-tests)
       (if ,var
           (progn ,@body)
           (skip ("no worker core could be built here (make core-worker): ~A" ,detail))))))

;;; ---------------------------------------------------------------------------
;;; Server children under a private state root
;;;
;;; A server child starts with none of the caller's DSMR_ settings and with
;;; XDG_STATE_HOME naming a fresh directory under /tmp. Anything it leaves
;;; running there, such as a broker it elected, is found through /proc by that
;;; root and stopped by pid.
;;; ---------------------------------------------------------------------------

(defparameter *server-child-leftover-grace* 5
  "Seconds a finished test waits for processes under its state root to exit on
their own before reporting them as left running.")

(defun fresh-server-child-state-home ()
  "Create a fresh mode-0700 directory under /tmp and return it as a directory
pathname. The literal /tmp keeps socket paths derived under the root within the
sun_path limit whatever TMPDIR names."
  (uiop:ensure-directory-pathname
   (string-trim '(#\Newline #\Return #\Space)
                (uiop:run-program '("mktemp" "-d" "/tmp/dsmr-child.XXXXXXXX")
                                  :output :string))))

(defun %state-home-root (state-home)
  "The native namestring of STATE-HOME in directory form, with its trailing slash."
  (uiop:native-namestring (uiop:ensure-directory-pathname state-home)))

(defun %environment-entry-name (entry)
  "The text of the environment ENTRY before its first equals sign, or all of
ENTRY when it has none."
  (subseq entry 0 (or (position #\= entry) (length entry))))

(defun server-child-environment (state-home &key assignments
                                                 (inherited (sb-ext:posix-environ)))
  "Return the environment for a server child as a list of NAME=VALUE strings:
ASSIGNMENTS verbatim, then XDG_STATE_HOME naming STATE-HOME, then every
INHERITED entry whose name is neither XDG_STATE_HOME nor starts with DSMR_.
INHERITED defaults to this process's environment. Touches no file."
  (append assignments
          (list (concatenate 'string "XDG_STATE_HOME=" (%state-home-root state-home)))
          (remove-if (lambda (entry)
                       (let ((name (%environment-entry-name entry)))
                         (or (string= name "XDG_STATE_HOME")
                             (uiop:string-prefix-p "DSMR_" name))))
                     inherited)))

(defun launch-server-child (command state-home &key assignments
                                                    (inherited nil inherited-p))
  "Start COMMAND with the environment SERVER-CHILD-ENVIRONMENT builds for
STATE-HOME and ASSIGNMENTS, with input, output and error output as streams, and
return its process-info. INHERITED, when supplied, stands in for this process's
environment.

Signal an ERROR, starting nothing, unless STATE-HOME is an existing directory
under /tmp/ and the environment holds exactly one XDG_STATE_HOME entry, naming it."
  (let* ((root (%state-home-root state-home))
         (environment (apply #'server-child-environment state-home
                             :assignments assignments
                             (when inherited-p (list :inherited inherited))))
         (state-entries (remove "XDG_STATE_HOME" environment
                                :key #'%environment-entry-name
                                :test-not #'string=)))
    (unless (uiop:string-prefix-p "/tmp/" root)
      (error "Server child state root ~A is not under /tmp/; pass a root from ~
FRESH-SERVER-CHILD-STATE-HOME." root))
    (unless (uiop:directory-exists-p root)
      (error "Server child state root ~A does not exist; check that it was ~
created before the launch." root))
    (unless (equal state-entries
                   (list (concatenate 'string "XDG_STATE_HOME=" root)))
      (error "Server child environment for state root ~A holds the XDG_STATE_HOME ~
entries ~S, not one naming the root; check ASSIGNMENTS." root state-entries))
    (uiop:launch-program command
                         :input :stream
                         :output :stream
                         :error-output :stream
                         :environment environment)))

(defun %proc-text (pid file)
  "The /proc FILE of PID as text, read byte for byte, or NIL when it cannot be
read."
  (ignore-errors
   (uiop:read-file-string (format nil "/proc/~D/~A" pid file)
                          :external-format :latin-1)))

(defun %own-process-p (pid)
  "True when PID belongs to the user this process runs as."
  (eql (ignore-errors (sb-posix:stat-uid (sb-posix:stat (format nil "/proc/~D" pid))))
       (sb-posix:getuid)))

(defun %process-under-state-home-p (pid root)
  "True when PID is a process of this user, other than this one, whose
environment holds XDG_STATE_HOME=ROOT exactly or whose command line contains
ROOT. ROOT is a native directory namestring with its trailing slash. A process
whose /proc entries cannot be read answers false."
  (let ((nul (string (code-char 0))))
    (and (/= pid (sb-posix:getpid))
         (%own-process-p pid)
         (let ((environ (%proc-text pid "environ"))
               (cmdline (%proc-text pid "cmdline")))
           (or (and environ
                    (member (concatenate 'string "XDG_STATE_HOME=" root)
                            (uiop:split-string environ :separator nul)
                            :test #'string=)
                    t)
               (and cmdline (search root cmdline) t))))))

(defun processes-under-state-home (state-home)
  "Every process of this user, other than this one, whose environment names
STATE-HOME as XDG_STATE_HOME or whose command line contains it, as a list of
(PID . COMMAND-LINE) with the command line's arguments joined by spaces."
  (let ((root (%state-home-root state-home))
        (nul (string (code-char 0))))
    (loop for dir in (ignore-errors (uiop:subdirectories "/proc/"))
          for name = (car (last (pathname-directory dir)))
          for pid = (and (stringp name) (plusp (length name))
                         (every #'digit-char-p name)
                         (parse-integer name))
          when (and pid (%process-under-state-home-p pid root))
            collect (cons pid (substitute #\Space (code-char 0)
                                          (string-right-trim
                                           nul (or (%proc-text pid "cmdline") "")))))))

(defun %await-true (thunk seconds)
  "Call THUNK every tenth of a second until it returns true or SECONDS pass, and
return its last value."
  (loop repeat (max 1 (round (* 10 seconds)))
        for answer = (funcall thunk)
        when answer do (return answer)
        do (sleep 0.1)
        finally (return (funcall thunk))))

(defun stop-processes-under-state-home (state-home &key (grace-seconds 5))
  "Stop every process PROCESSES-UNDER-STATE-HOME lists for STATE-HOME: SIGTERM,
then SIGKILL to whatever is still listed after GRACE-SECONDS, then up to 2 s
more. Each pid is re-checked against the root immediately before each signal,
and only that pid is signalled, never a process group. Return true when nothing
is left under the root."
  (let ((root (%state-home-root state-home)))
    (flet ((signal-listed (signal)
             (dolist (entry (processes-under-state-home state-home))
               (when (%process-under-state-home-p (car entry) root)
                 (ignore-errors (sb-posix:kill (car entry) signal)))))
           (none-left-p ()
             (null (processes-under-state-home state-home))))
      (unless (none-left-p)
        (signal-listed sb-posix:sigterm)
        (unless (%await-true #'none-left-p grace-seconds)
          (signal-listed sb-posix:sigkill)
          (%await-true #'none-left-p 2)))
      (none-left-p))))

(defun %leftovers-after-grace (state-home)
  "Wait up to *SERVER-CHILD-LEFTOVER-GRACE* seconds for nothing to be running
under STATE-HOME, and return what PROCESSES-UNDER-STATE-HOME lists then."
  (%await-true (lambda () (null (processes-under-state-home state-home)))
               *server-child-leftover-grace*)
  (processes-under-state-home state-home))

(defun %remove-server-child-state-home (state-home)
  "Delete the STATE-HOME tree, refusing any root whose native namestring does not
start with /tmp/dsmr-child."
  (uiop:delete-directory-tree
   (uiop:ensure-directory-pathname state-home)
   :if-does-not-exist :ignore
   :validate (lambda (path)
               (uiop:string-prefix-p "/tmp/dsmr-child."
                                     (uiop:native-namestring path)))))

(defmacro with-server-child-state-home ((var &key (check-leftovers t)) &body body)
  "Evaluate BODY with VAR bound to a fresh state root from
FRESH-SERVER-CHILD-STATE-HOME, and return BODY's values.

After BODY, when CHECK-LEFTOVERS is true, assert that nothing is running under
the root once *SERVER-CHILD-LEFTOVER-GRACE* has passed. On every exit, stop
whatever still runs under the root and delete it."
  ;; Zebra prints the asserted form, so this binding's name is the label in the report.
  (let ((root (gensym "ROOT"))
        (leftovers (make-symbol "PROCESSES-STILL-RUNNING-UNDER-STATE-ROOT")))
    `(let* ((,root (fresh-server-child-state-home))
            (,var ,root))
       (declare (ignorable ,var))
       (unwind-protect
            (multiple-value-prog1 (progn ,@body)
              (when ,check-leftovers
                (let ((,leftovers (%leftovers-after-grace ,root)))
                  (false ,leftovers
                         "processes are still running under the state root ~A ~
after the server child exited:~:{~%  ~D ~A~}"
                         (%state-home-root ,root)
                         (mapcar (lambda (entry) (list (car entry) (cdr entry)))
                                 ,leftovers)))))
         (ignore-errors (stop-processes-under-state-home ,root))
         (ignore-errors (%remove-server-child-state-home ,root))))))
