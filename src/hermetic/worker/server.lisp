;;;; src/hermetic/worker/server.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; TCP server for hermetic worker processes. Accepts a single connection
;;;; and processes newline-delimited JSON-RPC requests with pluggable method
;;;; dispatch. Designed for child worker processes that serve exactly one
;;;; parent session.
;;;;
;;;; Framing: imports %read-line-limited / +max-json-line-bytes+ from
;;;; worker-client — the same 16 MB cap used on both sides of the wire.
;;;; Auth: every method call (except worker/authenticate itself) is gated
;;;; behind the DSMR_WORKER_SECRET check (SAFETY-05 channel boundary).

(defpackage #:dsmr-mcp/src/hermetic/worker/server
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/log #:log-event)
  (:import-from #:dsmr-mcp/src/hermetic/worker-client
                #:%read-line-limited #:+max-json-line-bytes+ #:line-too-long)
  (:import-from #:usocket)
  (:import-from #:com.inuoe.jzon)
  (:import-from #:sb-ext)
  (:import-from #:uiop)
  (:export #:worker-server #:make-worker-server #:server-port
           #:start-accept-loop #:stop-server #:register-method
           #:*worker-read-timeout*))

(in-package #:dsmr-mcp/src/hermetic/worker/server)

;;; ---------------------------------------------------------------------------
;;; Configuration
;;; ---------------------------------------------------------------------------

(defvar *worker-read-timeout* 300
  "Seconds to wait for a JSON-RPC line from the parent before treating
the connection as idle. When exceeded, the loop keeps waiting rather
than closing — the parent manages worker lifecycle via kill-worker
or shutdown-pool. Prevents zombie workers when the parent disappears
without closing the socket.")

;;; ---------------------------------------------------------------------------
;;; Server struct
;;; ---------------------------------------------------------------------------

(defstruct (worker-server (:constructor %make-worker-server))
  "A single-connection TCP server for worker processes.
Listens on an ephemeral port, dispatches JSON-RPC requests to registered
handlers, and requires authentication with the shared secret before
processing any non-auth method calls."
  (listen-socket nil :type t)
  (port 0 :type integer)
  (methods (make-hash-table :test 'equal) :type hash-table)
  (running-p nil :type boolean)
  (authenticated-p nil :type boolean))

;;; ---------------------------------------------------------------------------
;;; Constructor
;;; ---------------------------------------------------------------------------

(defun make-worker-server (&key (port 0) (host "127.0.0.1"))
  "Create a worker server bound to HOST:PORT.
When PORT is 0 the OS assigns an ephemeral port. The built-in
worker/ping method is registered automatically."
  (let* ((listener (usocket:socket-listen host port
                                          :reuse-address t
                                          :element-type 'character))
         (actual-port (usocket:get-local-port listener))
         (server (%make-worker-server :listen-socket listener
                                      :port actual-port
                                      :running-p t)))
    (register-method server "worker/ping"
                     (lambda (params)
                       (declare (ignore params))
                       (let ((ht (make-hash-table :test 'equal)))
                         (setf (gethash "pong" ht) t)
                         ht)))
    (log-event :info "worker.server.created" "port" actual-port)
    server))

(defun server-port (server)
  "Return the TCP port the worker SERVER is listening on."
  (worker-server-port server))

;;; ---------------------------------------------------------------------------
;;; Method registry
;;; ---------------------------------------------------------------------------

(defun register-method (server method-name handler)
  "Register HANDLER for METHOD-NAME on SERVER.
HANDLER is a function of one argument (params hash-table or NIL)
that returns a hash-table to be used as the JSON-RPC result."
  (setf (gethash method-name (worker-server-methods server)) handler)
  (log-event :debug "worker.method.registered" "method" method-name))

;;; ---------------------------------------------------------------------------
;;; Internal helpers — response builders
;;; ---------------------------------------------------------------------------

(defun %make-result (id payload)
  "Build a JSON-RPC 2.0 success response hash-table."
  (let ((ht (make-hash-table :test 'equal)))
    (setf (gethash "jsonrpc" ht) "2.0"
          (gethash "id" ht) id
          (gethash "result" ht) payload)
    ht))

(defun %make-error (id code message)
  "Build a JSON-RPC 2.0 error response hash-table."
  (let ((err (make-hash-table :test 'equal))
        (ht (make-hash-table :test 'equal)))
    (setf (gethash "code" err) code
          (gethash "message" err) message)
    (setf (gethash "jsonrpc" ht) "2.0"
          (gethash "id" ht) id
          (gethash "error" ht) err)
    ht))

(defun %write-response (stream ht)
  "Write HT as a single newline-delimited JSON line to STREAM."
  (write-string (com.inuoe.jzon:stringify ht) stream)
  (terpri stream)
  (force-output stream))

;;; ---------------------------------------------------------------------------
;;; Internal helpers — request dispatch
;;; ---------------------------------------------------------------------------

(defun %dispatch-request (server stream id method params)
  "Dispatch a JSON-RPC request to the registered handler and write
the response to STREAM. Authentication is gated before any non-auth
method fires (SAFETY-05 / D-05 spoofing boundary).

Only worker/authenticate and worker/ping are allowed on an
unauthenticated connection; everything else returns -32600."
  ;; Auth gate: reject non-authentication requests before handshake.
  ;; Only enforce when DSMR_WORKER_SECRET is configured (pool mode).
  (unless (or (worker-server-authenticated-p server)
              (string= method "worker/authenticate")
              (string= method "worker/ping")
              (null (uiop:getenv "DSMR_WORKER_SECRET")))
    (%write-response stream
                     (%make-error id -32600 "Not authenticated"))
    (return-from %dispatch-request))
  ;; Handle authentication as a built-in method
  (when (string= method "worker/authenticate")
    (let ((expected (uiop:getenv "DSMR_WORKER_SECRET"))
          (provided (and params (gethash "secret" params))))
      (cond
        ((null expected)
         ;; No secret configured — auto-authenticate (no-pool invocation).
         (setf (worker-server-authenticated-p server) t)
         (%write-response stream
                          (%make-result id
                            (let ((ht (make-hash-table :test 'equal)))
                              (setf (gethash "authenticated" ht) t)
                              ht))))
        ((and provided (string= provided expected))
         (setf (worker-server-authenticated-p server) t)
         (%write-response stream
                          (%make-result id
                            (let ((ht (make-hash-table :test 'equal)))
                              (setf (gethash "authenticated" ht) t)
                              ht))))
        (t
         (log-event :warn "worker.auth.failed")
         (%write-response stream
                          (%make-error id -32600 "Authentication failed")))))
    (return-from %dispatch-request))
  ;; Normal dispatch for authenticated connections
  (let ((handler (gethash method (worker-server-methods server))))
    (if (null handler)
        (%write-response stream
                         (%make-error id -32601
                                      (format nil "Method not found: ~A" method)))
        (handler-case
            (let ((result (funcall handler params)))
              (%write-response stream (%make-result id result)))
          (serious-condition (e)
            (log-event :error "worker.dispatch-error"
                       "method" method
                       "msg" (princ-to-string e))
            (%write-response stream
                             (%make-error id -32603
                                          (format nil "Internal error: ~A"
                                                  (princ-to-string e)))))))))

(defun %process-line (server stream line)
  "Parse a JSON-RPC line and dispatch to the appropriate handler.
Writes the response to STREAM. Handles parse errors and invalid requests."
  (let ((trimmed (string-trim '(#\Space #\Tab #\Newline #\Return) line)))
    (when (string= trimmed "")
      (return-from %process-line))
    (let ((msg (handler-case
                   (com.inuoe.jzon:parse trimmed)
                 (error (e)
                   (log-event :warn "worker.parse.error"
                              "error" (princ-to-string e))
                   (handler-case
                       (%write-response stream
                                        (%make-error nil -32700 "Parse error"))
                     (stream-error ()))
                   (return-from %process-line)))))
      (unless (hash-table-p msg)
        (handler-case
            (%write-response stream (%make-error nil -32600 "Invalid Request"))
          (stream-error ()))
        (return-from %process-line))
      (let ((id     (gethash "id" msg))
            (method (gethash "method" msg))
            (params (gethash "params" msg)))
        (cond
          ((and method id)
           (%dispatch-request server stream id method params))
          (method
           ;; Notification — no response
           nil)
          (t
           (handler-case
               (%write-response stream (%make-error id -32600 "Invalid Request"))
             (stream-error ()))))))))

;;; ---------------------------------------------------------------------------
;;; Accept loop
;;; ---------------------------------------------------------------------------

(defun %handle-connection (server stream)
  "Read JSON-RPC lines from STREAM and write responses until EOF.
The idle timeout (*worker-read-timeout*) keeps the loop alive without
closing — parent lifecycle management (kill-worker, shutdown-pool)
is the authoritative termination path.

line-too-long is caught specifically and answered with a -32600 error
so the loop survives a single oversized request rather than treating
the size violation as an unrecoverable EOF/crash (WR-05)."
  (loop while (worker-server-running-p server)
        for line = (handler-case
                       (sb-ext:with-timeout *worker-read-timeout*
                         (%read-line-limited stream :eof +max-json-line-bytes+))
                     (sb-ext:timeout ()
                       (log-event :debug "worker.read.idle"
                                  "seconds" *worker-read-timeout*)
                       :idle)
                     (line-too-long ()
                       ;; Oversize request: reject with a JSON-RPC error and
                       ;; keep the loop running. Do NOT treat as EOF — that
                       ;; would mark the worker crashed and burn a circuit-breaker
                       ;; count for what is a recoverable protocol-size violation.
                       (log-event :warn "worker.read.line-too-long"
                                  "limit" +max-json-line-bytes+)
                       (ignore-errors
                         (%write-response stream
                                          (%make-error nil -32600
                                                       "Request too large")))
                       :idle)
                     (error (e)
                       (log-event :warn "worker.read.error"
                                  "error" (princ-to-string e))
                       :eof))
        when (eq line :eof) do (return)
        when (stringp line)
        do (handler-case
               (%process-line server stream line)
             (stream-error (e)
               (log-event :warn "worker.write.error"
                          "error" (princ-to-string e))
               (return)))))

(defun start-accept-loop (server)
  "Accept a single connection on SERVER and process requests until
the client disconnects or STOP-SERVER is called. Blocks the caller.
The listener socket is closed immediately after accept to free the
port — one-connection-per-worker design."
  (let ((listener (worker-server-listen-socket server)))
    (log-event :info "worker.accept.waiting"
               "port" (worker-server-port server))
    (let ((client (handler-case
                      (usocket:socket-accept listener
                                            :element-type 'character)
                    (error (e)
                      (unless (not (worker-server-running-p server))
                        (log-event :warn "worker.accept.error"
                                   "error" (princ-to-string e)))
                      nil))))
      (when client
        ;; Close listener — worker accepts exactly one connection.
        (ignore-errors (usocket:socket-close listener))
        (setf (worker-server-listen-socket server) nil)
        (log-event :info "worker.accept.connected"
                   "port" (worker-server-port server))
        (unwind-protect
             (%handle-connection server (usocket:socket-stream client))
          (ignore-errors (usocket:socket-close client))
          (log-event :info "worker.connection.closed"
                     "port" (worker-server-port server)))))))

;;; ---------------------------------------------------------------------------
;;; Stop
;;; ---------------------------------------------------------------------------

(defun stop-server (server)
  "Stop the worker SERVER. Closes the listener socket and signals
the accept/read loop to exit."
  (setf (worker-server-running-p server) nil)
  (let ((sock (worker-server-listen-socket server)))
    (when sock
      (ignore-errors (usocket:socket-close sock))
      (setf (worker-server-listen-socket server) nil)))
  (log-event :info "worker.server.stopped"
             "port" (worker-server-port server)))
