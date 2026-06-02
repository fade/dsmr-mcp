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
                #:gethash*)
  (:import-from #:dsmr-mcp/tests/integration/support
                #:quicklisp-setup-path))

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
  "Return a single --eval form (as a string) installing the child's ASDF source
registry: the project source directory — so dsmr-mcp itself resolves — plus
:inherit-configuration so every dependency resolves through the Quicklisp setup
the child loads, i.e. the same dist-pinned versions the parent uses.

Earlier this scanned the whole ~/quicklisp/dists/.../software tree with (:tree
…). That is unsafe: the tree holds many historical versions of a dependency
(e.g. seventeen float-features releases), and ASDF picks an arbitrary — usually
too-old — one, which then fails to satisfy a newer dependent like jzon. Letting
Quicklisp resolve the single dist-pinned version instead is what every other
load path in the project already relies on. Missing roots drop out, so a runner
without a discoverable project directory still gets a well-formed config."
  (let ((project (uiop:truename* (asdf:system-source-directory "dsmr-mcp"))))
    (format nil
            "(asdf:initialize-source-registry '(:source-registry~@[ (:directory ~S)~] :inherit-configuration))"
            (and project (namestring project)))))

(defun %spawn-dsmr-mcp ()
  "Spawn a child sbcl running dsmr-mcp in :stdio mode.
Returns a UIOP process-info object with :input :stream :output :stream
and :error-output :stream.  The caller is responsible for closing the
input stream (triggering EOF and thus child exit) and waiting for the
process.

Uses --no-userinit so the sbclrc does not run, then loads Quicklisp's setup.lisp
explicitly (its load is silent on stdout) so dependencies resolve to their single
dist-pinned versions. Diagnostic streams are routed to stderr for the child's
whole life, so the only thing that reaches stdout is the JSON-RPC traffic."
  (let* ((ql (quicklisp-setup-path))
         (args (append
                (list (%sbcl-path)
                      "--noinform"        ; suppress "This is SBCL 2.x.y..." banner
                      "--non-interactive"
                      "--no-userinit")    ; do not run the user's sbclrc
                (list "--eval" "(require :asdf)")
                ;; Route diagnostic streams to stderr before loading anything.
                ;; *debug-io* in particular carries SLYNK's "ASDF loader
                ;; finished." banner (slynk.asd); a let-binding of
                ;; *standard-output* alone does not catch it, and it would
                ;; otherwise corrupt the JSON pipe.
                (list "--eval"
                      "(setf *debug-io* *error-output* *trace-output* *error-output*)")
                ;; Load Quicklisp so deps resolve to their dist-pinned versions.
                ;; setup.lisp prints nothing to stdout; the noisy "To load X:"
                ;; lines only appear on a quickload of an uncompiled system, which
                ;; this child never does (it uses asdf:load-system on warm fasls).
                (when ql (list "--load" ql))
                ;; Project directory + :inherit-configuration (Quicklisp).
                (list "--eval" (%child-source-registry-form))
                ;; Suppress advisory ASDF load output from reaching the JSON pipe.
                (list "--eval"
                      "(let ((*standard-output* *error-output*)) (asdf:load-system :dsmr-mcp))")
                (list "--eval" "(dsmr-mcp:run :transport :stdio)"))))
    (uiop:launch-program
     args
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
