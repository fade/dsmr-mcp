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
;;;; reports a failure instead of the intended skip. Worse, parachute's SKIP
;;;; does not abort the enclosing test (it records a skipped sub-result and
;;;; returns), so a bare `(unless (spawnable) (skip ...))` guard falls through
;;;; into the spawn anyway.
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

(defpackage #:dsmr-mcp/tests/integration/support
  (:use #:cl)
  (:import-from #:parachute #:skip)
  (:export #:sbcl-path
           #:quicklisp-setup-path
           #:worker-child-buildable
           #:foreign-slynk-child-buildable
           #:mcp-server-child-buildable
           #:reset-build-probes
           #:with-worker-child-or-skip
           #:with-foreign-slynk-child-or-skip
           #:with-mcp-server-child-or-skip))

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
child needs: load Quicklisp if present, then quickload slynk + alexandria. Exits
0 on success, 7 on any resolution error."
  (list
   "--eval" "(require :asdf)"
   "--eval" (concatenate 'string
              "(let ((q (merge-pathnames \"quicklisp/setup.lisp\" (user-homedir-pathname)))) "
              "(when (and (probe-file q) (not (find-package :ql))) (load q)))")
   "--eval" (concatenate 'string
              "(handler-case (progn "
              "(funcall (read-from-string \"ql:quickload\") (list :slynk :alexandria) :silent t) "
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

(defun reset-build-probes ()
  "Forget memoized build verdicts so the next consult re-probes. Mainly for
interactive re-runs after fixing a registry."
  (setf *worker-child-build* :unknown
        *foreign-slynk-child-build* :unknown
        *mcp-server-child-build* :unknown)
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
alexandria in this environment."
  (%verdict '*foreign-slynk-child-build* #'%foreign-slynk-build-eval-program))

(defun mcp-server-child-buildable ()
  "Memoized (values OK-P DETAIL): true iff a fresh child can resolve and load the
full dsmr-mcp system in this environment — the precondition for spawning a real
stdio server subprocess."
  (%verdict '*mcp-server-child-build* #'%mcp-server-build-eval-program))

;;; ---------------------------------------------------------------------------
;;; Guard macros — run BODY only on a buildable environment, else SKIP it
;;; ---------------------------------------------------------------------------

(defmacro with-worker-child-or-skip (&body body)
  "Evaluate BODY only when a fresh child can build the hermetic worker system
here; otherwise parachute:skip the enclosing test WITHOUT evaluating BODY. Skips
only on a build/resolution failure — a buildable-but-misbehaving child runs BODY
and is free to fail, which is the regression signal these tests exist to catch."
  (let ((ok (gensym "OK")) (detail (gensym "DETAIL")))
    `(multiple-value-bind (,ok ,detail) (worker-child-buildable)
       (if ,ok
           (progn ,@body)
           (skip ("hermetic worker child could not build in this environment: ~A" ,detail))))))

(defmacro with-foreign-slynk-child-or-skip (&body body)
  "Evaluate BODY only when a fresh child can quickload slynk + alexandria here;
otherwise parachute:skip the enclosing test WITHOUT evaluating BODY. Skips only
on a build/resolution failure — once slynk is known buildable, an unreachable
child (port race, dropped wire) is a genuine failure and is left to fail."
  (let ((ok (gensym "OK")) (detail (gensym "DETAIL")))
    `(multiple-value-bind (,ok ,detail) (foreign-slynk-child-buildable)
       (if ,ok
           (progn ,@body)
           (skip ("foreign slynk child could not build in this environment: ~A" ,detail))))))

(defmacro with-mcp-server-child-or-skip (&body body)
  "Evaluate BODY only when a fresh child can build the full dsmr-mcp system here;
otherwise parachute:skip the enclosing test WITHOUT evaluating BODY. Skips only on
a build/resolution failure — once the server child is known buildable, a spawned
server that misbehaves is a genuine failure and is left to fail."
  (let ((ok (gensym "OK")) (detail (gensym "DETAIL")))
    `(multiple-value-bind (,ok ,detail) (mcp-server-child-buildable)
       (if ,ok
           (progn ,@body)
           (skip ("dsmr-mcp server child could not build in this environment: ~A" ,detail))))))
