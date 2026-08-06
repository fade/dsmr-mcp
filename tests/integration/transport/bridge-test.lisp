;;;; tests/transport/bridge-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Zebra end-to-end tests for the stdio<->TCP bridge binary.
;;;;
;;;; Every test body sits inside WITH-BRIDGE-BINARY-OR-SKIP so a lane that has
;;;; not built the binary reports a zebra skip rather than a vacuous pass
;;;; (or a CI failure). The guard must be a branch, never a bare (skip ...) in
;;;; front of the body: zebra's SKIP records a skipped result and returns,
;;;; so a guard written that way runs the body anyway. That is not merely
;;;; cosmetic. The body then launches a binary that is not there, unwinds into
;;;; cleanup, and waits on a helper thread that nothing will ever wake.
;;;;
;;;; Three distinct exit paths have three distinct tests:
;;;;   (1) bridge-exits-cleanly-on-connect-refused -- the never-connected path
;;;;   (2) bridge-exits-cleanly-on-stdin-eof-after-connect -- connected-then-EOF
;;;;   (3) bridge-routes-log-lines-to-stderr -- log-line filter is substring-
;;;;       based, not a prefix check, because jzon key order is implementation-
;;;;       defined
;;;;   (4) bridge-help-exits-zero -- --help short-circuit path

(defpackage #:dsmr-mcp/tests/integration/transport/bridge-test
  (:use #:cl #:zebra)
  (:import-from #:dsmr-mcp/src/transport/tcp
                #:serve-tcp)
  (:import-from #:bordeaux-threads
                #:make-thread
                #:join-thread
                #:thread-alive-p)
  (:import-from #:usocket))

(in-package #:dsmr-mcp/tests/integration/transport/bridge-test)

;;; ---------------------------------------------------------------------------
;;; Helpers
;;; ---------------------------------------------------------------------------

(defun %bridge-binary-path ()
  "Return an absolute pathname for bin/dsmr-mcp-bridge, resolved from the
dsmr-mcp system source directory so the lookup is independent of the test
runner's current working directory."
  (merge-pathnames "bin/dsmr-mcp-bridge"
                   (asdf:system-source-directory :dsmr-mcp)))

(defun %bridge-binary-present-p ()
  "Return T when bin/dsmr-mcp-bridge exists on disk.
Guards probe-file because a malformed pathname or a symlink loop can signal, and
the guarded tests are supposed to degrade to a recorded SKIP in that case rather
than crash the suite."
  (and (ignore-errors (probe-file (%bridge-binary-path))) t))

(defun %socket-available-p ()
  "Return T when a TCP listen socket can be bound on loopback.
Mirrors the guard pattern from tcp-test.lisp so the test passes
gracefully on a host where port binding is restricted."
  (handler-case
      (let ((sock (usocket:socket-listen "127.0.0.1" 0
                                         :reuse-address t
                                         :element-type 'character)))
        (unwind-protect
             (progn (usocket:get-local-port sock) t)
          (ignore-errors (usocket:socket-close sock))))
    (error () nil)))

(defparameter *accept-deadline* 20
  "Seconds a test's throwaway TCP server waits for the bridge to connect.
Generous enough for a loaded CI runner, and finite so that a test body which
never launches a client fails in seconds instead of parking the whole suite.")

(defparameter *join-deadline* 10
  "Seconds cleanup waits for a test's server thread to finish.
Abandoning a wedged thread leaks it for the rest of the run, which is cheap.
A join that cannot return costs the entire suite.")

(defun %accept-with-deadline (listener seconds)
  "Accept one connection on LISTENER, giving up after SECONDS.
Returns the connected socket, or NIL when nothing arrived in time.
A bare accept has no deadline, so a test that never launches its client leaves
this thread unreachable: nothing signals it, so no handler can rescue it."
  (when (usocket:wait-for-input listener :timeout seconds :ready-only t)
    (usocket:socket-accept listener :element-type 'character)))

(defun %join-server-thread (thread seconds)
  "Join THREAD, giving up after SECONDS.
Returns T when the thread finished in time and NIL when it was still running at
the deadline. Test cleanup must never be able to block the suite, so the wait
for a helper thread is bounded even when the thread itself misbehaves."
  (handler-case
      (progn (sb-ext:with-timeout seconds (join-thread thread)) t)
    (sb-ext:timeout () nil)
    (error () t)))

(defmacro with-bridge-binary-or-skip (&body body)
  "Evaluate BODY only when bin/dsmr-mcp-bridge is on disk, and otherwise record a
zebra skip WITHOUT evaluating BODY.

SKIP stands the enclosing test down, so a bare guard would also work. The branch
is kept because it states the requirement in the code rather than resting on how
SKIP unwinds: a lane that never built the binary must execute none of the body."
  `(if (%bridge-binary-present-p)
       (progn ,@body)
       (skip "bridge binary not built; run 'make bridge' to enable this test")))

(defmacro with-loopback-listen-or-skip (&body body)
  "Evaluate BODY only when a loopback TCP listen socket can be bound, and
otherwise record a zebra skip WITHOUT evaluating BODY. A real branch for the
same reason WITH-BRIDGE-BINARY-OR-SKIP is one."
  `(if (%socket-available-p)
       (progn ,@body)
       (skip "loopback TCP listen unavailable")))

(defun %raw-echo-server-thread (port-cell done-flag)
  "Spin up a raw TCP server on an ephemeral port that echoes received lines
back to the connected client.

Sets the car of PORT-CELL to the bound port when listening.
Sets the car of DONE-FLAG to T once the server is finished, whether that is a
closed connection, a bind that failed, or nothing ever connecting."
  (make-thread
   (lambda ()
     (let ((listener (handler-case
                         (usocket:socket-listen "127.0.0.1" 0
                                                :reuse-address t
                                                :element-type 'character)
                       (error () nil))))
       (unwind-protect
            (when listener
              (setf (car port-cell) (usocket:get-local-port listener))
              (handler-case
                  (let ((client (%accept-with-deadline listener *accept-deadline*)))
                    (when client
                      (let ((stream (usocket:socket-stream client)))
                        (unwind-protect
                             (loop
                               (let ((line (read-line stream nil nil)))
                                 (unless line (return))
                                 (write-line line stream)
                                 (force-output stream)))
                          (ignore-errors (close stream))
                          (ignore-errors (usocket:socket-close client))))))
                (error () nil)))
         (when listener
           (ignore-errors (usocket:socket-close listener)))
         (setf (car done-flag) t))))
   :name "bridge-echo-server"))

(defun %two-line-server-thread (port-cell line1 line2)
  "Spin up a raw TCP server that, on accept, sends LINE1 then LINE2 then closes.

Sets the car of PORT-CELL to the bound port when ready."
  (make-thread
   (lambda ()
     (let ((listener (handler-case
                         (usocket:socket-listen "127.0.0.1" 0
                                                :reuse-address t
                                                :element-type 'character)
                       (error () nil))))
       (unwind-protect
            (when listener
              (setf (car port-cell) (usocket:get-local-port listener))
              (handler-case
                  (let ((client (%accept-with-deadline listener *accept-deadline*)))
                    (when client
                      (let ((stream (usocket:socket-stream client)))
                        (unwind-protect
                             (progn
                               (write-line line1 stream)
                               (force-output stream)
                               (write-line line2 stream)
                               (force-output stream))
                          (ignore-errors (close stream))
                          (ignore-errors (usocket:socket-close client))))))
                (error () nil)))
         (when listener
           (ignore-errors (usocket:socket-close listener))))))
   :name "bridge-two-line-server"))

;;; ---------------------------------------------------------------------------
;;; Tests
;;; ---------------------------------------------------------------------------

(define-test bridge-exits-cleanly-on-connect-refused
  "Bridge launched against a port nothing is listening on exits with code 2
(connect-refused) or 3 (timeout/unreachable).
Covers the NEVER-CONNECTED path exclusively."
  (with-bridge-binary-or-skip
    (multiple-value-bind (stdout stderr rc)
        (handler-case
            (uiop:run-program
             (list (namestring (%bridge-binary-path))
                   "--host" "127.0.0.1"
                   "--port" "1"
                   "--connect-timeout" "2.0")
             :output :string
             :error-output :string
             :ignore-error-status t)
          (error (e)
            (values "" (princ-to-string e) -1)))
      (declare (ignore stdout))
      ;; rc 2 (refused) or 3 (timeout / EHOSTUNREACH) are both acceptable.
      (true (member rc '(2 3)))
      (true (or (search "refused" stderr)
                (search "connect" stderr))))))

(define-test bridge-exits-cleanly-on-stdin-eof-after-connect
  "Bridge launched against a running echo server: after a round-trip
exchange the subprocess stdin is closed, and the bridge exits 0 within 5 s.
Covers the CONNECTED-then-stdin-EOF path exclusively."
  (with-bridge-binary-or-skip
    (with-loopback-listen-or-skip
      (let* ((port-cell (list nil))
             (done-flag (list nil))
             (server-thr (%raw-echo-server-thread port-cell done-flag)))
        (unwind-protect
             (progn
               ;; Wait for server to bind (up to 2 s).
               (loop repeat 200
                     until (car port-cell)
                     do (sleep 0.01d0))
               (true (car port-cell))
               (let* ((port (car port-cell))
                      (probe-line
                        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}"))
                 ;; Launch bridge with writable stdin and readable stdout.
                 (let ((proc (uiop:launch-program
                              (list (namestring (%bridge-binary-path))
                                    "--host" "127.0.0.1"
                                    "--port" (write-to-string port))
                              :input :stream
                              :output :stream
                              :error-output nil)))
                   (unwind-protect
                        (progn
                          ;; Write probe line so bridge enters CONNECTED pump mode.
                          (let ((in (uiop:process-info-input proc)))
                            (write-line probe-line in)
                            (force-output in))
                          ;; Read echoed line back from bridge stdout.
                          (let ((echoed
                                  (handler-case
                                      (sb-ext:with-timeout 3
                                        (read-line
                                         (uiop:process-info-output proc) nil nil))
                                    (sb-ext:timeout () nil))))
                            (true echoed)
                            (when echoed
                              (is string= probe-line echoed)))
                          ;; Close bridge stdin to trigger the clean-shutdown path.
                          (close (uiop:process-info-input proc))
                          ;; Bridge must exit 0 within 5 s.
                          (let ((rc
                                  (handler-case
                                      (sb-ext:with-timeout 5
                                        (uiop:wait-process proc))
                                    (sb-ext:timeout ()
                                      (ignore-errors
                                       (uiop:terminate-process proc :urgent t))
                                      :timeout))))
                            (is = 0 rc)))
                     (ignore-errors
                      (uiop:terminate-process proc :urgent t))))))
          (%join-server-thread server-thr *join-deadline*))))))

(define-test bridge-routes-log-lines-to-stderr
  "Bridge proxies a plain JSON-RPC line to stdout and routes a log-shaped
line where ts: appears mid-object (not first key) to stderr.
Proves the substring filter is wired correctly: a log object where the
ts: key is buried mid-object would slip past a naive prefix check."
  (with-bridge-binary-or-skip
    (with-loopback-listen-or-skip
      ;; line1: plain JSON-RPC result (no ts: or level: key)
      ;; line2: log-shaped object where ts: is NOT the first key (mid-object,
      ;; the case a prefix-only check would miss).
      (let* ((jsonrpc-line
               "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}")
             (log-line
               (concatenate 'string
                            "{\"jsonrpc\":\"2.0\",\"params\":"
                            "{\"msg\":\"hi\",\"ts\":\"2026-05-28T00:00:00Z\"},"
                            "\"method\":\"log\"}"))
             (port-cell (list nil))
             (server-thr
               (%two-line-server-thread port-cell jsonrpc-line log-line)))
        (unwind-protect
             (progn
               (loop repeat 200
                     until (car port-cell)
                     do (sleep 0.01d0))
               (true (car port-cell))
               (let ((port (car port-cell)))
                 ;; Bridge connects, receives two lines, then exits when server
                 ;; closes the connection.  No stdin input needed from us.
                 (multiple-value-bind (stdout stderr _rc)
                     (handler-case
                         (uiop:run-program
                          (list (namestring (%bridge-binary-path))
                                "--host" "127.0.0.1"
                                "--port" (write-to-string port))
                          :output :string
                          :error-output :string
                          :ignore-error-status t)
                       (error (e)
                         (values "" (princ-to-string e) -1)))
                   (declare (ignore _rc))
                   ;; JSON-RPC line must reach stdout.
                   (true (and (stringp stdout)
                              (search jsonrpc-line stdout)))
                   ;; Log line (mid-object ts:) must NOT reach stdout.
                   (false (and (stringp stdout)
                               (search "\"ts\":" stdout)))
                   ;; Log line must reach stderr (proving the substring check).
                   (true (and (stringp stderr)
                              (search "\"ts\":" stderr))))))
          (%join-server-thread server-thr *join-deadline*))))))

(define-test bridge-help-exits-zero
  "Running dsmr-mcp-bridge --help exits 0 and emits a usage block
to stderr that mentions stdio or TCP."
  (with-bridge-binary-or-skip
    (multiple-value-bind (stdout stderr rc)
        (handler-case
            (uiop:run-program
             (list (namestring (%bridge-binary-path)) "--help")
             :output :string
             :error-output :string
             :ignore-error-status t)
          (error (e)
            (values "" (princ-to-string e) -1)))
      (declare (ignore stdout))
      (is = 0 rc)
      (true (and (stringp stderr)
                 (or (search "stdio" stderr)
                     (search "TCP" stderr)))))))
