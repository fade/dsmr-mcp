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

(defun %asdf-source-registry-dir ()
  "Return the source-registry directory hint so the child can find dsmr-mcp."
  (namestring
   (uiop/pathname:ensure-directory-pathname
    (asdf:system-source-directory "dsmr-mcp"))))

(defun %extra-registry-push-evals ()
  "Return a list of --eval strings that push extra *central-registry* directories
into the child process.  These are directories hosting .asd files for dsmr-mcp
transitive dependencies that live outside ~/SourceCode/lisp/ (typically quicklisp
software directories).  Computed from the parent process's live ASDF knowledge so
no paths are hardcoded.

The quicklisp client directory itself is excluded to prevent the child from
accidentally loading quicklisp (which prints 'To load X:' messages to stdout)."
  (let* ((workspace    (uiop:truename* "~/SourceCode/lisp/"))
         (ql-quicklisp (uiop:truename* "~/quicklisp/quicklisp/"))
         (dirs (remove-duplicates
                (remove nil
                  (mapcar (lambda (sys)
                            (let ((s (ignore-errors (asdf:find-system sys nil))))
                              (when s
                                (let ((src (ignore-errors
                                            (asdf:system-source-directory s))))
                                  (when (and src
                                             (not (uiop:subpathp src workspace))
                                             ;; Skip the quicklisp client dir itself.
                                             (not (equal src ql-quicklisp)))
                                    src)))))
                          (asdf:already-loaded-systems)))
                :test #'equal)))
    (mapcar (lambda (dir)
              (format nil "(push ~S asdf:*central-registry*)" (namestring dir)))
            dirs)))

(defun %spawn-dsmr-mcp ()
  "Spawn a child sbcl running dsmr-mcp in :stdio mode.
Returns a UIOP process-info object with :input :stream :output :stream
and :error-output :stream.  The caller is responsible for closing the
input stream (triggering EOF and thus child exit) and waiting for the
process.

Uses --no-userinit to prevent the sbclrc from loading quicklisp, which would
write 'To load X:' messages to stdout (the JSON-RPC pipe).  Instead, extra
ASDF *central-registry* directories are pushed explicitly from the parent
process's live ASDF knowledge (see %extra-registry-push-evals)."
  (let* ((dir   (%asdf-source-registry-dir))
         (extra (%extra-registry-push-evals))
         ;; Build the --eval argument list: require asdf, push dirs, load, run.
         (evals (append
                 (list "--eval" "(require :asdf)")
                 (list "--eval" (format nil "(push ~S asdf:*central-registry*)" dir))
                 ;; Push one extra dir per --eval (each --eval must be single form).
                 (loop for e in extra append (list "--eval" e))
                 ;; Route diagnostic streams to stderr for the child's whole
                 ;; life so nothing but JSON-RPC reaches stdout. *debug-io* in
                 ;; particular is how SLYNK's ASDF loader prints its
                 ;; "SLYNK's ASDF loader finished." banner (slynk.asd) — a
                 ;; let-binding of *standard-output* alone does not catch it,
                 ;; and the banner would otherwise corrupt the JSON pipe.
                 (list "--eval"
                       "(setf *debug-io* *error-output* *trace-output* *error-output*)")
                 (list "--eval"
                       ;; Suppress any remaining ASDF load output (advisory notes
                       ;; from asdf:load-system itself) from reaching the JSON pipe.
                       "(let ((*standard-output* *error-output*)) (asdf:load-system :dsmr-mcp))")
                 (list "--eval" "(dsmr-mcp:run :transport :stdio)"))))
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
