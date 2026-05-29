;;;; src/transport/tcp.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; TCP transport: accepts multiple concurrent client connections on a
;;;; configurable loopback address, spawning one thread per connection.
;;;; Each connection carries its own session so agents running in parallel
;;;; never share state or corrupt each other's JSON-RPC channel.
;;;;
;;;; Key design decisions:
;;;;   serve-tcp is the blocking entry point; run.lisp's :tcp arm dispatches
;;;;   here via uiop:symbol-call after %check-remote-bind passes.
;;;;   %dispatch-with-stdout-guard (imported from stdio.lisp) captures stray
;;;;   *standard-output* writes per connection so tool code cannot corrupt
;;;;   any one client's JSON-RPC channel.
;;;;   %read-line-limited (imported from stdio.lisp) enforces the 8 MB
;;;;   +max-json-line-bytes+ cap per TCP line — oversized requests get a
;;;;   -32600 error and the connection is drained but kept open.
;;;;   detach-session cleanup runs in every connection's unwind-protect via
;;;;   runtime symbol resolution, mirroring stdio.lisp's bracket pattern.
;;;;
;;;; Ported and adapted from cl-mcp/src/tcp.lisp (MIT) under AGPL:
;;;;   - make-state → make-session with :id "tcp-N" :slynk-attach :project-root
;;;;   - release-session → uiop:symbol-call detach-session
;;;;   - process-json-line bare call → %dispatch-with-stdout-guard wrapper
;;;;   - tcp-line-channel installed on session before dispatch loop starts
;;;;   - thread name prefix "mcp-client-~A" → "dsmr-tcp-client-~A"
;;;;   - worker-pool calls removed (hermetic dispatch lives in run.lisp / pool)

(defpackage #:dsmr-mcp/src/transport/tcp
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/state
                #:make-session
                #:session-id
                #:session-notify-channel
                #:*current-session-id*)
  (:import-from #:dsmr-mcp/src/protocol
                #:process-json-line)
  (:import-from #:dsmr-mcp/src/log
                #:log-event)
  (:import-from #:dsmr-mcp/src/notify
                #:tcp-line-channel)
  (:import-from #:dsmr-mcp/src/transport/stdio
                #:%read-line-limited
                #:+max-json-line-bytes+
                #:line-too-long
                #:%dispatch-with-stdout-guard)
  (:import-from #:bordeaux-threads
                #:make-thread
                #:thread-alive-p
                #:make-lock
                #:with-lock-held)
  (:import-from #:usocket)
  (:export #:serve-tcp
           #:start-tcp-server-thread
           #:ensure-tcp-server-thread
           #:stop-tcp-server-thread
           #:tcp-server-running-p
           #:*tcp-server-thread*
           #:*tcp-server-port*
           #:*tcp-stop-flag*
           #:*tcp-conn-counter*
           #:*tcp-accept-timeout*
           #:*tcp-read-timeout*
           #:*tcp-max-connections*))

(in-package #:dsmr-mcp/src/transport/tcp)

;;; ---------------------------------------------------------------------------
;;; Process-level specials
;;; ---------------------------------------------------------------------------

(defparameter *tcp-server-thread* nil
  "Background TCP accept-loop thread created by START-TCP-SERVER-THREAD.
NIL when no thread is running.")

(defparameter *tcp-server-port* nil
  "Port number of the currently running TCP server listener.
Set to the resolved port (even when port=0 is requested) so callers can
query the actual ephemeral port.  NIL when no server is running.")

(defparameter *tcp-stop-flag* nil
  "When T, the accept loop exits at the next heartbeat cycle.
Set by STOP-TCP-SERVER-THREAD; cleared by SERVE-TCP at startup.")

(defparameter *tcp-conn-counter* 0
  "Monotonic integer counter; incremented once per accepted connection.
Used to tag connection threads and session ids (\"tcp-N\").")

(defparameter *tcp-accept-timeout* 0.5d0
  "Seconds usocket:wait-for-input blocks before re-checking *tcp-stop-flag*.
Shorter values improve stop latency at the cost of more accept-loop iterations.
Default 0.5s means stop requests are observed within half a second.")

(defparameter *tcp-read-timeout* nil
  "Seconds to wait for data on a connected socket before the read heartbeat
re-checks the stop flag.  NIL = no per-connection read timeout; idle
connections remain open indefinitely (the accept-loop heartbeat handles
stop signalling, not per-connection timeouts).")

(defparameter *tcp-max-connections* 64
  "Maximum number of concurrent connection-handler threads.  When the live
count reaches this ceiling the accept loop closes new connections
immediately (after logging a warn) instead of spawning another thread.
Defaults sized for the loopback workload; bump for a remote-bind
deployment.  NIL disables the cap.")

(defvar *tcp-live-connections* 0
  "Count of in-flight connection-handler threads.  Mutated only inside
*TCP-LIVE-CONNECTIONS-LOCK*.")

(defvar *tcp-live-connections-lock*
  (bordeaux-threads:make-lock "tcp-live-connections-lock")
  "Lock protecting *TCP-LIVE-CONNECTIONS*.")

;;; ---------------------------------------------------------------------------
;;; Internal: accept helpers
;;; ---------------------------------------------------------------------------

(defun %tcp-accept-client (listener)
  "Accept one connection on LISTENER.
Returns the accepted socket on success, or NIL on transient errors.
Handles USOCKET:BAD-FILE-DESCRIPTOR-ERROR (listener closed during shutdown)
and generic USOCKET:SOCKET-CONDITION by logging a warning and returning NIL."
  (handler-case
      (usocket:socket-accept listener :element-type 'character)
    (usocket:bad-file-descriptor-error ()
      nil)
    (usocket:socket-condition (e)
      (log-event :warn "tcp.accept.fail" "error" (princ-to-string e))
      nil)))

;;; ---------------------------------------------------------------------------
;;; Internal: per-connection dispatch loop
;;; ---------------------------------------------------------------------------

(defun %process-stream (stream client conn-id session)
  "Dispatch JSON-RPC lines from STREAM for one accepted TCP connection.
Reads lines via %READ-LINE-LIMITED (8 MB cap), dispatches each through
%DISPATCH-WITH-STDOUT-GUARD so stray tool-body format-t calls cannot corrupt
the per-connection JSON-RPC channel.

Returns when the client closes the connection (EOF), a write error occurs
(broken pipe), or *TCP-STOP-FLAG* is set while waiting for the next line."
  (declare (ignore client))
  (let ((*current-session-id* (session-id session)))
    (loop
      (let ((line (handler-case
                      (%read-line-limited stream :eof +max-json-line-bytes+)
                    (line-too-long (e)
                      (log-event :warn "tcp.read.line-too-long"
                                 "conn" conn-id
                                 "error" (princ-to-string e))
                      ;; Drain remaining bytes on this line so the next read
                      ;; starts on a fresh line boundary.
                      (ignore-errors
                       (loop for ch = (read-char stream nil nil)
                             while (and ch (not (char= ch #\Newline)))))
                      ;; Respond with a -32600 envelope so the client knows.
                      (handler-case
                          (progn
                            (write-line
                             "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32600,\"message\":\"Line exceeds maximum size\"}}"
                             stream)
                            (force-output stream))
                        (stream-error (we)
                          (log-event :warn "tcp.write.error"
                                     "conn" conn-id
                                     "error" (princ-to-string we))
                          (return)))
                      ;; Continue to next line rather than closing.
                      :line-too-long)
                    (stream-error (e)
                      (log-event :warn "tcp.read.error"
                                 "conn" conn-id
                                 "error" (princ-to-string e))
                      :eof))))
        (cond
          ;; Client closed the connection.
          ((eq line :eof)
           (return))

          ;; Already handled the too-long case above; continue.
          ((eq line :line-too-long)
           nil)

          ;; Normal line — dispatch with stdout guard.
          (t
           (multiple-value-bind (response captured)
               (%dispatch-with-stdout-guard line session)
             ;; Log stray stdout pollution using the same event name as
             ;; stdio.lisp so existing log dashboards catch it.
             (when (plusp (length captured))
               (log-event :warn "transport.stdout-pollution"
                          "session" (session-id session)
                          "bytes" (length captured)))
             ;; Write response when non-NIL (NIL = notification, no reply).
             (when response
               (handler-case
                   (progn
                     (write-line response stream)
                     (force-output stream))
                 (stream-error (e)
                   (log-event :warn "tcp.write.error"
                              "conn" conn-id
                              "error" (princ-to-string e))
                   (return)))))))))))

;;; ---------------------------------------------------------------------------
;;; Internal: per-connection handler
;;; ---------------------------------------------------------------------------

(defun %tcp-handle-client (client conn-id slynk-attach project-root)
  "Set up and run one accepted TCP connection end-to-end.

Creates a fresh session with id \"tcp-<CONN-ID>\", installs a TCP-LINE-CHANNEL
so the session can push server-initiated notifications to this client,
then runs the dispatch loop.  Cleanup under UNWIND-PROTECT closes the stream
and socket, calls DETACH-SESSION via runtime symbol resolution (mirrors
stdio.lisp line 216), and decrements *tcp-live-connections* so the accept
loop can spawn another thread."
  (let ((stream nil)
        (session (make-session :id (format nil "tcp-~A" conn-id)
                               :slynk-attach slynk-attach
                               :project-root project-root)))
    (unwind-protect
         (when client
           (let ((remote (ignore-errors (princ-to-string
                                         (usocket:get-peer-address client)))))
             (log-event :info "tcp.accept" "conn" conn-id "remote" remote)
             (setf stream (usocket:socket-stream client))
             ;; Install the per-connection notification channel BEFORE the
             ;; dispatch loop reads its first line so any notification emitted
             ;; during initialization lands on this TCP stream.
             (setf (session-notify-channel session)
                   (make-instance 'tcp-line-channel :stream stream))
             (%process-stream stream client conn-id session)))
      (when stream (ignore-errors (close stream)))
      (when client (ignore-errors (usocket:socket-close client)))
      ;; Close the attached Slynk connection cleanly, same as stdio.lisp.
      (ignore-errors
       (uiop:symbol-call :dsmr-mcp/src/attach/dispatch :detach-session session))
      (bordeaux-threads:with-lock-held (*tcp-live-connections-lock*)
        (decf *tcp-live-connections*))
      (log-event :info "tcp.conn.closed" "conn" conn-id))))

;;; ---------------------------------------------------------------------------
;;; Internal: accept loop
;;; ---------------------------------------------------------------------------

(defun %tcp-accept-loop (listener accept-once slynk-attach project-root)
  "Run the TCP accept loop until *TCP-STOP-FLAG* is set.

Each heartbeat cycle calls USOCKET:WAIT-FOR-INPUT with *TCP-ACCEPT-TIMEOUT*
so the loop re-checks *TCP-STOP-FLAG* without blocking indefinitely.
SLYNK-ATTACH and PROJECT-ROOT are closure-captured from SERVE-TCP and
forwarded to each spawned per-connection thread.

When ACCEPT-ONCE is T, accepts exactly one connection (blocking) and returns
immediately — used for integration tests that need a single-shot server."
  (loop while (not *tcp-stop-flag*)
        do (let ((ready
                   (handler-case
                       (usocket:wait-for-input (list listener)
                                               :timeout *tcp-accept-timeout*)
                     ;; Listener was closed externally (e.g. stop nudge).
                     (usocket:bad-file-descriptor-error ()
                       (return)))))
             (cond
               ;; Timeout — re-check stop flag on next iteration.
               ((null ready) nil)

               ;; Single-shot mode: accept one connection, handle it inline,
               ;; then return so the test can join the server thread.
               (accept-once
                (let ((client (%tcp-accept-client listener)))
                  (when client
                    (%tcp-handle-client client 0 slynk-attach project-root))
                  (return)))

               ;; Normal multi-client mode: spawn a thread per connection.
               ;; Increment the counter only after a successful accept so
               ;; transient accept failures (ECONNABORTED, fd exhaustion)
               ;; don't leave gaps in conn-id sequencing.  When the live
               ;; thread count is at *tcp-max-connections*, close the new
               ;; socket immediately so a buggy or hostile client cannot
               ;; spawn unbounded threads.
               (t
                (let ((client (%tcp-accept-client listener)))
                  (when client
                    (let ((accepted
                            (bordeaux-threads:with-lock-held
                                (*tcp-live-connections-lock*)
                              (cond
                                ((or (null *tcp-max-connections*)
                                     (< *tcp-live-connections*
                                        *tcp-max-connections*))
                                 (incf *tcp-live-connections*)
                                 t)
                                (t nil)))))
                      (cond
                        (accepted
                         (let ((conn-id (incf *tcp-conn-counter*)))
                           ;; make-thread can signal under genuinely abnormal
                           ;; conditions (pthread-create exhaustion, OOM,
                           ;; SBCL thread-creation-failed).  When that fires
                           ;; the handler thread's unwind-protect never runs,
                           ;; so the live-connections slot AND the client
                           ;; socket the handler would have reaped both leak.
                           ;; A leaked slot is a slow-DOS path: a sequence
                           ;; of failed spawns eventually pins the cap at
                           ;; full and the accept loop refuses every new
                           ;; client.  Reap both here when the spawn fails.
                           (handler-case
                               (bordeaux-threads:make-thread
                                (lambda ()
                                  (%tcp-handle-client client conn-id slynk-attach project-root))
                                :name (format nil "dsmr-tcp-client-~A" conn-id))
                             (error (e)
                               (bordeaux-threads:with-lock-held
                                   (*tcp-live-connections-lock*)
                                 (decf *tcp-live-connections*))
                               (ignore-errors (usocket:socket-close client))
                               (log-event :warn "tcp.spawn.failed"
                                          "conn" conn-id
                                          "error" (princ-to-string e))))))
                        (t
                         (log-event :warn "tcp.accept.capped"
                                    "limit" *tcp-max-connections*)
                         (ignore-errors (usocket:socket-close client))))))))))))

;;; ---------------------------------------------------------------------------
;;; Public: blocking server entry point
;;; ---------------------------------------------------------------------------

(defun serve-tcp (&key (host "127.0.0.1") (port 3000)
                       slynk-attach project-root
                       accept-once on-listening)
  "Start a TCP listener on HOST:PORT and accept MCP connections until stopped.

Each accepted connection receives its own session and runs the full
JSON-RPC dispatch in a dedicated thread (or inline when ACCEPT-ONCE is T).
Returns T when the server exits cleanly.

Arguments:
  HOST          — bind address (default \"127.0.0.1\"); validated by
                  run.lisp's %CHECK-REMOTE-BIND before SERVE-TCP is called.
  PORT          — listener port; 0 picks an ephemeral port.
  SLYNK-ATTACH  — host:port string for the Slynk listener, or NIL.
  PROJECT-ROOT  — initial session project root pathname, or NIL.
  ACCEPT-ONCE   — when T, accept exactly one connection and return.
  ON-LISTENING  — when non-NIL, called with the resolved port number once
                  the listener is bound (useful for tests using port=0)."
  (setf *tcp-stop-flag* nil)
  (let ((listener
          (handler-case
              (usocket:socket-listen host port
                                     :reuse-address t
                                     :element-type 'character)
            (error (e)
              (log-event :warn "tcp.listen.error" "error" (princ-to-string e))
              (return-from serve-tcp nil)))))
    (setf *tcp-server-port* (usocket:get-local-port listener))
    (when on-listening
      (funcall on-listening *tcp-server-port*))
    (log-event :info "tcp.start" "host" host "port" *tcp-server-port*)
    (unwind-protect
         (%tcp-accept-loop listener accept-once slynk-attach project-root)
      (ignore-errors (usocket:socket-close listener))
      (log-event :info "tcp.stop" "host" host "port" *tcp-server-port*)
      (setf *tcp-server-port* nil))
    t))

;;; ---------------------------------------------------------------------------
;;; Public: background thread lifecycle
;;; ---------------------------------------------------------------------------

(defun tcp-server-running-p ()
  "Return T when a background TCP server thread is alive, NIL otherwise."
  (and *tcp-server-thread*
       (bordeaux-threads:thread-alive-p *tcp-server-thread*)))

(defun start-tcp-server-thread (&key (host "127.0.0.1") (port 3000)
                                     slynk-attach project-root)
  "Start a background TCP server thread on HOST:PORT.

When a server thread is already running, returns the existing thread without
starting a second one.  Returns the thread object."
  ;; Reap a dead thread before checking running-p.
  (when (and *tcp-server-thread*
             (not (bordeaux-threads:thread-alive-p *tcp-server-thread*)))
    (setf *tcp-server-thread* nil))
  (when (tcp-server-running-p)
    (return-from start-tcp-server-thread *tcp-server-thread*))
  (setf *tcp-server-thread*
        (bordeaux-threads:make-thread
         (lambda ()
           (serve-tcp :host host :port port
                      :slynk-attach slynk-attach
                      :project-root project-root))
         :name "dsmr-tcp-accept-loop")))

(defun ensure-tcp-server-thread (&key (host "127.0.0.1") (port 3000)
                                      slynk-attach project-root)
  "Ensure a TCP server thread is running, starting one if needed.
Returns the (possibly pre-existing) thread."
  (start-tcp-server-thread :host host :port port
                           :slynk-attach slynk-attach
                           :project-root project-root))

(defun stop-tcp-server-thread ()
  "Stop the background TCP server thread if one is running.

Sets *TCP-STOP-FLAG* to T, then nudges the accept loop via a loopback
self-connection so USOCKET:WAIT-FOR-INPUT unblocks immediately rather than
waiting for the next heartbeat.  Joins the thread with a 5-second guard.
Returns T whether or not a server was running."
  (when (tcp-server-running-p)
    (setf *tcp-stop-flag* t)
    ;; Nudge the accept loop so it exits its wait-for-input immediately.
    (when *tcp-server-port*
      (ignore-errors
       (let ((sock (usocket:socket-connect "127.0.0.1" *tcp-server-port*
                                           :timeout 1.0d0
                                           :element-type 'character)))
         (when sock
           (ignore-errors (usocket:socket-close sock))))))
    ;; Join with a timeout guard.
    (when *tcp-server-thread*
      (handler-case
          (sb-ext:with-timeout 5
            (bordeaux-threads:join-thread *tcp-server-thread*))
        (sb-ext:timeout ()
          (ignore-errors
           (bordeaux-threads:destroy-thread *tcp-server-thread*)))
        (error () nil)))
    (setf *tcp-server-thread* nil))
  t)
