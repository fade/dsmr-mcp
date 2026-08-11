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
;;;; foreign SBCL — CL + slynk + zebra only — gives it a tiny UMBRELLA
;;;; test system (no package named like the system; one passing and one
;;;; failing test across two sub-suite packages, the package-inferred
;;;; norm), and drives the real tool dispatch end to end: bootstrap,
;;;; ASDF-deps framework detection, the umbrella package resolver,
;;;; ghost-purge + reload, the merged run, and the plist decode back into
;;;; structured counts with rendered failure reasons.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/integration/attach/run-tests-cross-process-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/integration/attach/run-tests-cross-process-test
  (:use #:cl #:zebra)
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
                #:slime-close)
  (:import-from #:dsmr-mcp/tests/support/bounded-eval
                #:eval-in-image)
  (:import-from #:dsmr-mcp/tests/integration/support
                #:with-foreign-slynk-child-or-skip))

(in-package #:dsmr-mcp/tests/integration/attach/run-tests-cross-process-test)

;;; ---------------------------------------------------------------------------
;;; Probe system source
;;;
;;; The parent writes this file into a temp directory; the child registers an
;;; in-memory ASDF system over it (:depends-on zebra), so the verb's
;;; default path — ASDF-deps framework detection, ghost-purge, force-reload —
;;; runs exactly as it would for a real operator project.  One test passes,
;;; one fails deliberately, so the counts prove real extraction rather than
;;; an empty run.
;;; ---------------------------------------------------------------------------

(defparameter +probe-asd+
  "(defsystem \"dsmr-xproc-runner-probe\"
  :depends-on (\"zebra\"
               \"dsmr-xproc-runner-probe/suite-a\"
               \"dsmr-xproc-runner-probe/suite-b\"))
(defsystem \"dsmr-xproc-runner-probe/suite-a\"
  :depends-on (\"zebra\")
  :components ((:file \"suite-a\")))
(defsystem \"dsmr-xproc-runner-probe/suite-b\"
  :depends-on (\"zebra\")
  :components ((:file \"suite-b\")))
"
  "UMBRELLA system definition: the top system has NO components and no
same-named package — its tests live entirely in the two slashy
subsystems, the package-inferred norm this leaf exists to prove.")

(defparameter +probe-suite-a+
  "(defpackage #:dsmr-xproc-runner-probe/suite-a (:use #:cl))
(in-package #:dsmr-xproc-runner-probe/suite-a)
(zebra:define-test xproc-probe-passes (zebra:true t))
"
  "First sub-suite: one passing test.")

(defparameter +probe-suite-b+
  "(defpackage #:dsmr-xproc-runner-probe/suite-b (:use #:cl))
(in-package #:dsmr-xproc-runner-probe/suite-b)
(zebra:define-test xproc-probe-fails (zebra:is = 1 2))
"
  "Second sub-suite: one deliberately failing test, so the merged counts
and the rendered failure reason are both observable.")

(defun %write-probe-system (dir)
  "Write the umbrella probe system into DIR — dsmr-xproc-runner-probe.asd
plus suite-a.lisp and suite-b.lisp — and return DIR.  The .asd must exist
on disk under the system's own name (not an in-memory defsystem): ASDF's
central-registry search looks for <system-name>.asd exactly, and the
engine's force-reload re-resolves the definition, dropping systems with no
backing file."
  (ensure-directories-exist dir)
  (with-open-file (s (merge-pathnames "dsmr-xproc-runner-probe.asd" dir)
                     :direction :output :if-exists :supersede)
    (write-string +probe-asd+ s))
  (with-open-file (s (merge-pathnames "suite-a.lisp" dir)
                     :direction :output :if-exists :supersede)
    (write-string +probe-suite-a+ s))
  (with-open-file (s (merge-pathnames "suite-b.lisp" dir)
                     :direction :output :if-exists :supersede)
    (write-string +probe-suite-b+ s))
  dir)

(defun %free-tcp-port ()
  "Bind an OS-assigned loopback port, read it back, release it, return it.
Same benign-race caveats as the wire cross-process leaf: the sanity eval
below is what catches a lost rebind."
  (let ((listener (usocket:socket-listen "127.0.0.1" 0 :reuse-address t)))
    (unwind-protect (usocket:get-local-port listener)
      (usocket:socket-close listener))))

(defun %child-eval-forms (port probe-dir)
  "The --eval program for the foreign image: Quicklisp, slynk + zebra,
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
   "--eval" "(funcall (read-from-string \"ql:quickload\") (list :slynk :zebra) :silent t)"
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
never loaded dsmr-mcp, for an UMBRELLA system: the probe has no package
named like the system — its tests live in two sub-suite packages — so this
exercises the engine bootstrap, ASDF-deps framework detection, the
umbrella package resolver, the merged multi-package run, and the
failure-reason rendering, end to end through the real tool dispatch.  A
second call succeeds through the bootstrap's :CURRENT path."
  (with-foreign-slynk-child-or-skip
    (with-foreign-test-image (conn probe-dir)
      (declare (ignorable probe-dir))
      ;; Sanity: the link works and the image is genuinely foreign.
      (is = 3 (eval-in-image '(+ 1 2) conn :label "foreign runner link probe"))
      (false (eval-in-image '(find-package "DSMR-MCP/SRC/TEST-RUNNER-ENGINE") conn
                            :label "engine absent before bootstrap"))

      (let* ((tool (%attach-repl-tool "xproc-run-tests" conn))
             (params (make-ht "system" "dsmr-xproc-runner-probe"
                              "timeout_seconds" 120))
             (res (%dispatch-attach-run-tests tool 1 params)))
        (true (hash-table-p res))
        (false (equal "NETWORK_ERROR" (gethash "error_type" res))
               "run-tests dropped the wire (NETWORK_ERROR)")
        (false (gethash "isError" res) "run-tests returned isError")
        (is equal "zebra" (gethash "framework" res))
        ;; Merged counts across the two sub-suites: 1 pass + 1 fail.
        (is = 1 (gethash "passed" res))
        (is = 1 (gethash "failed" res))
        ;; The failing test's name and a reason crossed the rex and render
        ;; in the summary — counts alone once hid the real failure.
        (let ((fails (gethash "failed_tests" res)))
          (is = 1 (length fails))
          (true (search "XPROC-PROBE-FAILS" (gethash "test_name" (aref fails 0))))
          (true (plusp (length (gethash "reason" (aref fails 0))))))
        (let ((summary (gethash "text" (aref (gethash "content" res) 0))))
          (true (search "XPROC-PROBE-FAILS" summary)))
        ;; The bootstrap installed the engine; the umbrella stayed
        ;; packageless (resolution went through ASDF, not a name match).
        (true (eval-in-image '(and (find-package "DSMR-MCP/SRC/TEST-RUNNER-ENGINE") t) conn
                             :label "engine present after bootstrap"))
        (false (eval-in-image '(find-package "DSMR-XPROC-RUNNER-PROBE") conn
                              :label "umbrella stayed packageless"))
        ;; Second call: the version gate is :CURRENT, the run still works.
        (let ((res2 (%dispatch-attach-run-tests tool 2 params)))
          (false (gethash "isError" res2))
          (is = 1 (gethash "passed" res2))
          (is = 1 (gethash "failed" res2)))))))
