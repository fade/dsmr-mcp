;;;; tests/transport/stdio-integration-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Spawned-subprocess integration tests.
;;;; A real SBCL child process is launched with OS pipes; the test drives an
;;;; initialize exchange over those pipes and asserts on the response and on
;;;; child stderr capturing a stdio.start log event.
;;;;
;;;; Gated: skips cleanly when sbcl is not on PATH.
;;;; Kept to one or two test cases — subprocess tests are slow and environment-dependent.

(defpackage #:dsmr-mcp/tests/integration/transport/stdio-integration-test
  (:use #:cl #:parachute)
  (:local-nicknames (#:jzon #:com.inuoe.jzon))
  (:import-from #:dsmr-mcp/tests/support/json-asserts
                #:gethash*))

(in-package #:dsmr-mcp/tests/integration/transport/stdio-integration-test)

;;; ---------------------------------------------------------------------------
;;; Helpers
;;; ---------------------------------------------------------------------------

(defun %sbcl-path ()
  "Return the path string to the sbcl binary, or NIL when not on PATH.
Uses 'which sbcl' first; falls back to checking common fixed locations."
  (or (ignore-errors
        (let ((result (string-trim
                       '(#\Newline #\Return #\Space)
                       (uiop:run-program '("which" "sbcl")
                                         :output :string
                                         :ignore-error-status t))))
          (and (plusp (length result)) result)))
      (find-if #'probe-file
               (list "/usr/local/bin/sbcl"
                     "/usr/bin/sbcl"
                     "/opt/local/bin/sbcl"))))

(defun %child-source-registry-form ()
  "Return a single --eval form (as a string) that installs an explicit ASDF
source registry in the child, rooted at stable directories rather than
reconstructed from the parent's mutable already-loaded-systems set: the project
source directory, the local-projects workspace, the project's vendor tree, and
the quicklisp 'software' tree where dist dependencies live.

Making the registry explicit and invocation-independent removes the fragile
coupling on which load path started the parent (a bare run, a warm core image,
or the CI prime step each leave a different transitive closure loaded). The
quicklisp client directory itself is NOT added, so the child never loads
quicklisp (which would print 'To load X:' lines onto the JSON-RPC stdout pipe).
Missing roots are dropped, so a runner without ~/SourceCode/lisp or a global
quicklisp still gets a well-formed config from whatever roots do exist."
  (let* ((project     (uiop:truename* (asdf:system-source-directory "dsmr-mcp")))
         (workspace   (uiop:truename* "~/SourceCode/lisp/"))
         (ql-software (uiop:truename* "~/quicklisp/dists/quicklisp/software/"))
         (vendor      (and project
                           (uiop:truename* (merge-pathnames "vendor/" project))))
         ;; (:directory D) is the dir itself; (:tree D) recurses D for .asd files.
         (entries (remove nil
                    (list (when project     (format nil "(:directory ~S)" (namestring project)))
                          (when workspace   (format nil "(:tree ~S)" (namestring workspace)))
                          (when vendor      (format nil "(:tree ~S)" (namestring vendor)))
                          (when ql-software (format nil "(:tree ~S)" (namestring ql-software)))))))
    (format nil
            "(asdf:initialize-source-registry '(:source-registry ~{~A ~}:inherit-configuration))"
            entries)))

(defun %spawn-dsmr-mcp ()
  "Spawn a child sbcl running dsmr-mcp in :stdio mode.
Returns a UIOP process-info object with :input :stream :output :stream
and :error-output :stream.  The caller is responsible for closing the
input stream (triggering EOF and thus child exit) and waiting for the
process.

Uses --no-userinit to prevent the sbclrc from loading quicklisp, which would
write 'To load X:' messages to stdout (the JSON-RPC pipe).  The child resolves
dsmr-mcp and its dependencies through an explicit source registry installed at
startup (see %child-source-registry-form), rooted at stable directories so
resolution does not depend on how the parent process was started."
  (let* ((evals (list
                 "--eval" "(require :asdf)"
                 ;; Install the explicit, invocation-independent source registry
                 ;; before any load-system so dsmr-mcp + deps resolve from stable
                 ;; roots rather than the parent's mutable loaded-systems set.
                 "--eval" (%child-source-registry-form)
                 ;; Route diagnostic streams to stderr for the child's whole
                 ;; life so nothing but JSON-RPC reaches stdout. *debug-io* in
                 ;; particular is how SLYNK's ASDF loader prints its
                 ;; "SLYNK's ASDF loader finished." banner (slynk.asd) — a
                 ;; let-binding of *standard-output* alone does not catch it,
                 ;; and the banner would otherwise corrupt the JSON pipe.
                 "--eval"
                 "(setf *debug-io* *error-output* *trace-output* *error-output*)"
                 ;; Suppress any remaining ASDF load output (advisory notes
                 ;; from asdf:load-system itself) from reaching the JSON pipe.
                 "--eval"
                 "(let ((*standard-output* *error-output*)) (asdf:load-system :dsmr-mcp))"
                 "--eval" "(dsmr-mcp:run :transport :stdio)")))
    (uiop:launch-program
     (append
      (list (%sbcl-path)
            "--noinform"          ; suppress \"This is SBCL 2.x.y...\" banner
            "--non-interactive"
            "--no-userinit")      ; prevent sbclrc from loading quicklisp onto stdout
      evals)
     :input        :stream
     :output       :stream
     :error-output :stream)))

(defun %init-line ()
  "Return a well-formed initialize JSON-RPC request line."
  (concatenate 'string
               "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\","
               "\"params\":{\"protocolVersion\":\"2025-06-18\","
               "\"capabilities\":{},\"clientInfo\":{\"name\":\"inttest\","
               "\"version\":\"0\"}}}"))

;;; ---------------------------------------------------------------------------
;;; Tests
;;; ---------------------------------------------------------------------------

(define-test initialize-over-real-pipes
  "A spawned SBCL child answers an initialize line on its stdout with
a structurally correct JSON-RPC response containing protocolVersion."
  ;; Skip cleanly when sbcl is not on PATH.
  (unless (%sbcl-path)
    (skip "sbcl not on PATH — skipping spawned-subprocess test"))

  (let ((proc (%spawn-dsmr-mcp)))
    (unwind-protect
         (let ((child-in  (uiop:process-info-input  proc))
               (child-out (uiop:process-info-output proc)))
           ;; Send the initialize line.
           (write-line (%init-line) child-in)
           (force-output child-in)

           ;; Read one response line from child stdout.
           (let* ((response (read-line child-out nil nil))
                  (parsed   (and response (jzon:parse response))))
             ;; Assert protocolVersion is present in the result.
             (true response)
             (true parsed)
             (is equal "2.0" (gethash "jsonrpc" parsed))
             (is = 1 (gethash "id" parsed))
             (let ((ver (gethash* parsed "result" "protocolVersion")))
               (true (stringp ver))
               (true (> (length ver) 0))))

           ;; Close input to trigger EOF; child should exit.
           (close child-in)
           (uiop:wait-process proc))

      ;; Ensure the process is reaped even if assertions fail.
      (ignore-errors
        (close (uiop:process-info-input proc)))
      (ignore-errors
        (uiop:terminate-process proc))
      (ignore-errors
        (uiop:wait-process proc)))))

(define-test stdio-start-appears-in-child-stderr
  "Child stderr contains a stdio.start log event, proving the transport
logged its start."
  ;; Skip cleanly when sbcl is not on PATH.
  (unless (%sbcl-path)
    (skip "sbcl not on PATH — skipping spawned-subprocess test"))

  (let ((proc (%spawn-dsmr-mcp)))
    (unwind-protect
         (let ((child-in  (uiop:process-info-input  proc))
               (child-out (uiop:process-info-output proc)))
           ;; Send and receive one initialize exchange so the server starts.
           (write-line (%init-line) child-in)
           (force-output child-in)
           ;; Read the response (ignore content — just drain so the child
           ;; has had a chance to write its log lines).
           (read-line child-out nil nil)
           ;; Close to trigger EOF, wait for child to exit.
           (close child-in)
           (uiop:wait-process proc)
           ;; Drain stderr into a string (the stream is now at EOF
           ;; because the child has exited and closed its end).
           (let* ((err-stream (uiop:process-info-error-output proc))
                  (stderr     (with-output-to-string (s)
                                (loop for line = (read-line err-stream nil nil)
                                      while line
                                      do (write-line line s)))))
             (true (stringp stderr))
             (true (search "stdio.start" stderr))))

      ;; Ensure process cleanup.
      (ignore-errors (close (uiop:process-info-input proc)))
      (ignore-errors (uiop:terminate-process proc))
      (ignore-errors (uiop:wait-process proc)))))
