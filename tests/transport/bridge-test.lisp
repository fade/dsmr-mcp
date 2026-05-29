;;;; tests/transport/bridge-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Parachute end-to-end tests for the stdio<->TCP bridge binary.
;;;;
;;;; Every test opens with (if (not (%bridge-binary-present-p)) (true t) ...)
;;;; so a CI lane that has not built the binary degrades to PASS-via-guard
;;;; rather than CI failure (D-15 pattern).
;;;;
;;;; W-4 invariant: three distinct exit paths have three distinct tests:
;;;;   (1) bridge-exits-cleanly-on-connect-refused -- the never-connected path
;;;;   (2) bridge-exits-cleanly-on-stdin-eof-after-connect -- connected-then-EOF
;;;;   (3) bridge-routes-log-lines-to-stderr -- D-09 log-line filter (W-6)
;;;;   (4) bridge-help-exits-zero -- --help short-circuit path

(defpackage #:dsmr-mcp/tests/transport/bridge-test
  (:use #:cl #:parachute)
  (:import-from #:dsmr-mcp/src/transport/tcp
                #:serve-tcp)
  (:import-from #:bordeaux-threads
                #:make-thread
                #:join-thread
                #:thread-alive-p)
  (:import-from #:usocket))

(in-package #:dsmr-mcp/tests/transport/bridge-test)

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
  "Return T when bin/dsmr-mcp-bridge exists on disk."
  (and (probe-file (%bridge-binary-path)) t))

(defun %socket-available-p ()
  "Return T when a TCP listen socket can be bound on loopback.
Mirrors the guard pattern from tcp-test.lisp (D-15)."
  (handler-case
      (let ((sock (usocket:socket-listen "127.0.0.1" 0
                                         :reuse-address t
                                         :element-type 'character)))
        (unwind-protect
             (progn (usocket:get-local-port sock) t)
          (ignore-errors (usocket:socket-close sock))))
    (error () nil)))

(defun %raw-echo-server-thread (port-cell done-flag)
  "Spin up a raw TCP server on an ephemeral port that echoes received lines
back to the connected client.

Sets the car of PORT-CELL to the bound port when listening.
Sets the car of DONE-FLAG to T after the first connection closes."
  (make-thread
   (lambda ()
     (let ((listener nil))
       (handler-case
           (setf listener
                 (usocket:socket-listen "127.0.0.1" 0
                                        :reuse-address t
                                        :element-type 'character))
         (error ()
           (setf (car done-flag) t)
           (return-from %raw-echo-server-thread nil)))
       (setf (car port-cell) (usocket:get-local-port listener))
       (handler-case
           (let* ((client (usocket:socket-accept listener :element-type 'character))
                  (stream (usocket:socket-stream client)))
             (unwind-protect
                  (loop
                    (let ((line (read-line stream nil nil)))
                      (unless line (return))
                      (write-line line stream)
                      (force-output stream)))
               (ignore-errors (close stream))
               (ignore-errors (usocket:socket-close client))
               (setf (car done-flag) t)))
         (error () (setf (car done-flag) t)))
       (ignore-errors (usocket:socket-close listener))))
   :name "bridge-echo-server"))

(defun %two-line-server-thread (port-cell line1 line2)
  "Spin up a raw TCP server that, on accept, sends LINE1 then LINE2 then closes.

Sets the car of PORT-CELL to the bound port when ready."
  (make-thread
   (lambda ()
     (let ((listener nil))
       (handler-case
           (setf listener
                 (usocket:socket-listen "127.0.0.1" 0
                                        :reuse-address t
                                        :element-type 'character))
         (error ()
           (return-from %two-line-server-thread nil)))
       (setf (car port-cell) (usocket:get-local-port listener))
       (handler-case
           (let* ((client (usocket:socket-accept listener :element-type 'character))
                  (stream (usocket:socket-stream client)))
             (unwind-protect
                  (progn
                    (write-line line1 stream)
                    (force-output stream)
                    (write-line line2 stream)
                    (force-output stream))
               (ignore-errors (close stream))
               (ignore-errors (usocket:socket-close client))))
         (error () nil))
       (ignore-errors (usocket:socket-close listener))))
   :name "bridge-two-line-server"))

;;; ---------------------------------------------------------------------------
;;; Tests
;;; ---------------------------------------------------------------------------

(define-test bridge-exits-cleanly-on-connect-refused
  "Bridge launched against a port nothing is listening on exits with code 2
(connect-refused) or 3 (timeout/unreachable).
Covers the NEVER-CONNECTED path exclusively."
  (if (not (%bridge-binary-present-p))
      (true t)
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
  (if (or (not (%bridge-binary-present-p))
          (not (%socket-available-p)))
      (true t)
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
          (ignore-errors (join-thread server-thr))))))

(define-test bridge-routes-log-lines-to-stderr
  "Bridge proxies a plain JSON-RPC line to stdout and routes a log-shaped
line where ts: appears mid-object (not first key) to stderr.
Proves the substring filter, not a prefix check -- W-6."
  (if (or (not (%bridge-binary-present-p))
          (not (%socket-available-p)))
      (true t)
      ;; line1: plain JSON-RPC result (no ts: or level: key)
      ;; line2: log-shaped object where ts: is NOT the first key (W-6 mid-object)
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
                   ;; Log line must reach stderr (substring check W-6).
                   (true (and (stringp stderr)
                              (search "\"ts\":" stderr))))))
          (ignore-errors (join-thread server-thr))))))

(define-test bridge-help-exits-zero
  "Running dsmr-mcp-bridge --help exits 0 and emits a usage block
to stderr that mentions stdio or TCP."
  (if (not (%bridge-binary-present-p))
      (true t)
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
