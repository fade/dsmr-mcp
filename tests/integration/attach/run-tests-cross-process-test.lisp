;;;; tests/integration/attach/run-tests-cross-process-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Cross-process proof that attached-mode run-tests works against a FOREIGN
;;;; image — one that has never loaded dsmr-mcp.
;;;;
;;;; The attached run-tests path used to dispatch on dsmr-mcp's own
;;;; test-runner package being present in the target image, which only held
;;;; when the server attached to itself; against any real operator image the
;;;; verb failed immediately.  The fix bootstraps the dependency-free engine
;;;; file into the image, version-gated by a content fingerprint.  The
;;;; in-process slynk fixture structurally cannot prove that (its image
;;;; already carries the engine via ASDF), so this leaf spawns a genuinely
;;;; foreign SBCL — CL + slynk + parachute only — registers a tiny two-test
;;;; parachute system in it, and drives the real tool dispatch end to end:
;;;; bootstrap, ASDF-deps framework detection, ghost-purge + reload, run,
;;;; and the plist decode back into structured counts.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/integration/attach/run-tests-cross-process-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/integration/attach/run-tests-cross-process-test
  (:use #:cl #:parachute)
  (:import-from #:dsmr-mcp/src/attach/dispatch
                #:repl-eval-tool-slynk-conn)
  (:import-from #:dsmr-mcp/src/tools/run-tests
                #:%dispatch-attach-run-tests)
  (:import-from #:dsmr-mcp/src/state
                #:make-session
                #:*current-session-id*
                #:get-tool-instance)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:make-ht)
  (:import-from #:slynk-client
                #:slime-connect
                #:slime-close
                #:slime-eval)
  (:import-from #:dsmr-mcp/tests/integration/support
                #:with-foreign-slynk-child-or-skip))

(in-package #:dsmr-mcp/tests/integration/attach/run-tests-cross-process-test)

;;; ---------------------------------------------------------------------------
;;; Probe system source
;;;
;;; The parent writes this file into a temp directory; the child registers an
;;; in-memory ASDF system over it (:depends-on parachute), so the verb's
;;; default path — ASDF-deps framework detection, ghost-purge, force-reload —
;;; runs exactly as it would for a real operator project.  One test passes,
;;; one fails deliberately, so the counts prove real extraction rather than
;;; an empty run.
;;; ---------------------------------------------------------------------------

(defparameter +probe-source+
  "(defpackage #:dsmr-xproc-runner-probe (:use #:cl))
(in-package #:dsmr-xproc-runner-probe)
(parachute:define-test xproc-probe-passes (parachute:true t))
(parachute:define-test xproc-probe-fails (parachute:true nil))
"
  "Contents of the probe system's single file.")

(defun %write-probe-system (dir)
  "Write the probe system into DIR — a real probe.asd plus probe.lisp — and
return DIR.  The .asd must exist on disk (not an in-memory defsystem):
the engine's default force-reload makes ASDF re-resolve the system
definition, and a system with no backing .asd is dropped mid-reload with
\"Component ... not found\"."
  (ensure-directories-exist dir)
  ;; ASDF's central-registry search looks for <system-name>.asd exactly;
  ;; any other file name is invisible to it.
  (with-open-file (s (merge-pathnames "dsmr-xproc-runner-probe.asd" dir)
                     :direction :output :if-exists :supersede)
    (write-string "(defsystem \"dsmr-xproc-runner-probe\"
  :depends-on (\"parachute\")
  :components ((:file \"probe\")))
" s))
  (with-open-file (s (merge-pathnames "probe.lisp" dir)
                     :direction :output :if-exists :supersede)
    (write-string +probe-source+ s))
  dir)

(defun %free-tcp-port ()
  "Bind an OS-assigned loopback port, read it back, release it, return it.
Same benign-race caveats as the wire cross-process leaf: the sanity eval
below is what catches a lost rebind."
  (let ((listener (usocket:socket-listen "127.0.0.1" 0 :reuse-address t)))
    (unwind-protect (usocket:get-local-port listener)
      (usocket:socket-close listener))))

(defun %child-eval-forms (port probe-dir)
  "The --eval program for the foreign image: Quicklisp, slynk + parachute,
put PROBE-DIR (which holds probe.asd) on the central registry, start Slynk
on PORT, block.  Foreign package symbols go through read-from-string so the
forms READ before their packages exist."
  (list
   "--eval" "(require :asdf)"
   "--eval" (concatenate 'string
                         "(let ((q (merge-pathnames \"quicklisp/setup.lisp\""
                         " (user-homedir-pathname))))"
                         " (when (and (probe-file q) (not (find-package :ql)))"
                         " (load q)))")
   "--eval" "(funcall (read-from-string \"ql:quickload\") (list :slynk :parachute) :silent t)"
   "--eval" (format nil "(push (pathname ~S) asdf:*central-registry*)"
                    (namestring probe-dir))
   "--eval" (format nil "(funcall (read-from-string \"slynk:create-server\") :port ~D :dont-close t)"
                    port)
   "--eval" "(loop (sleep 3600))"))

(defmacro with-foreign-test-image ((conn-var probe-dir-var) &body body)
  "Spawn the foreign SBCL with the probe system registered, connect, run BODY,
always tear down (close client, kill child, reap, remove temp artifacts)."
  (let ((port (gensym "PORT-")) (out (gensym "OUT-")) (proc (gensym "PROC-"))
        (conn-tmp (gensym "CONN-")) (tries (gensym "TRIES-")) (i (gensym "I-")))
    ;; Not tmpize-pathname: it reserves the name as a FILE, which then blocks
    ;; ensure-directories-exist from creating the directory.  A random suffix
    ;; from a freshly seeded state is collision-safe enough for a test scratch
    ;; directory that is removed on unwind.
    `(let* ((,probe-dir-var (uiop:ensure-directory-pathname
                             (merge-pathnames
                              (format nil "dsmr-runner-xproc-~36R/"
                                      (random (expt 36 8) (make-random-state t)))
                              (uiop:temporary-directory))))
            (,port (%free-tcp-port))
            (,out  (uiop:tmpize-pathname
                    (merge-pathnames "dsmr-runner-xproc.log"
                                     (uiop:temporary-directory))))
            (,proc (progn
                     (%write-probe-system ,probe-dir-var)
                     (uiop:launch-program
                      (list* (uiop:native-namestring sb-ext:*runtime-pathname*)
                             "--noinform" "--disable-debugger"
                             (%child-eval-forms ,port ,probe-dir-var))
                      :output ,out :error-output ,out)))
            (,conn-tmp nil)
            (,tries 160))
       (unwind-protect
            (progn
              (dotimes (,i ,tries)
                (when (and (uiop:process-alive-p ,proc)
                           (setf ,conn-tmp
                                 (ignore-errors (slime-connect "127.0.0.1" ,port))))
                  (return))
                (unless (uiop:process-alive-p ,proc)
                  (return))
                (sleep 0.25))
              (unless ,conn-tmp
                (error "with-foreign-test-image: could not reach foreign Slynk ~
on 127.0.0.1:~D after ~,1Fs (child alive: ~A).~%--- child output tail ---~%~A"
                       ,port (* ,tries 0.25)
                       (uiop:process-alive-p ,proc)
                       (ignore-errors
                        (let ((s (uiop:read-file-string ,out)))
                          (subseq s (max 0 (- (length s) 2000)))))))
              (let ((,conn-var ,conn-tmp))
                ,@body))
         (ignore-errors (when ,conn-tmp (slime-close ,conn-tmp)))
         (ignore-errors (uiop:terminate-process ,proc :urgent t))
         (ignore-errors (uiop:wait-process ,proc))
         (ignore-errors (delete-file ,out))
         (ignore-errors (uiop:delete-directory-tree
                         ,probe-dir-var :validate t))))))

(defun %attach-repl-tool (id conn)
  "Session-bound repl-eval tool instance with CONN installed, as the real
tool-handle path provides it."
  (let* ((*current-session-id* id)
         (session (make-session :id id :slynk-attach "127.0.0.1:1"))
         (tool    (get-tool-instance session "repl-eval")))
    (setf (repl-eval-tool-slynk-conn tool) conn)
    tool))

;;; ---------------------------------------------------------------------------
;;; The acceptance proof
;;; ---------------------------------------------------------------------------

(define-test run-tests-works-against-foreign-image
  "Attached run-tests returns structured pass/fail counts from an image that
never loaded dsmr-mcp: the engine bootstraps over the wire, the framework is
detected from the probe system's ASDF deps, and the deliberate 1-pass /
1-fail split comes back intact.  A second call succeeds through the
bootstrap's :CURRENT path, proving the version gate settles."
  (with-foreign-slynk-child-or-skip
    (with-foreign-test-image (conn probe-dir)
      (declare (ignorable probe-dir))
      ;; Sanity: the link works and the image is genuinely foreign.
      (is = 3 (slime-eval '(+ 1 2) conn))
      (false (slime-eval '(find-package "DSMR-MCP/SRC/TEST-RUNNER-ENGINE") conn))

      (let* ((tool (%attach-repl-tool "xproc-run-tests" conn))
             (params (make-ht "system" "dsmr-xproc-runner-probe"
                              "timeout_seconds" 120))
             (res (%dispatch-attach-run-tests tool 1 params)))
        (true (hash-table-p res))
        (false (equal "NETWORK_ERROR" (gethash "error_type" res))
               "run-tests dropped the wire (NETWORK_ERROR)")
        (false (gethash "isError" res) "run-tests returned isError")
        (is equal "parachute" (gethash "framework" res))
        (is = 1 (gethash "passed" res))
        (is = 1 (gethash "failed" res))
        ;; The bootstrap actually installed the engine in the foreign image.
        (true (slime-eval '(and (find-package "DSMR-MCP/SRC/TEST-RUNNER-ENGINE") t) conn))
        ;; Second call: the version gate is :CURRENT, the run still works.
        (let ((res2 (%dispatch-attach-run-tests tool 2 params)))
          (false (gethash "isError" res2))
          (is = 1 (gethash "passed" res2))
          (is = 1 (gethash "failed" res2)))))))
