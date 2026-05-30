;;;; tests/support/lsp-mock.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; In-process mock alive-lsp TCP server for LSP unit tests.
;;;;
;;;; Starts a Content-Length–framed JSON-RPC TCP listener on an OS-assigned
;;;; ephemeral port (127.0.0.1 only).  An accept thread reads inbound
;;;; Content-Length frames, matches the request's "method" against a
;;;; CANNED-RESPONSES alist, and writes back a Content-Length–framed reply.
;;;;
;;;; Server-initiated request path: when the server's :send-request thunk is
;;;; called (e.g. to send workspace/configuration as alive-lsp does during
;;;; textDocument/rangeFormatting), the accept thread writes the request and
;;;; parks until the client's response arrives, then delivers it to the caller.
;;;;
;;;; Wire format: standard LSP base protocol.
;;;;   Outbound: "Content-Length: N\r\n\r\n" + UTF-8 JSON body (N bytes).
;;;;   Inbound:  same.  (RESEARCH.md Domain 1, alive-lsp src/lsp/packet.lisp)
;;;;
;;;; Teardown: with-lsp-mock-server uses unwind-protect to guarantee stop on
;;;; every exit path, mirroring with-temporary-slynk-listener in
;;;; tests/support/slynk-fixture.lisp.

;; Package evolution guard — delete prior definition on warm reload.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/support/lsp-mock)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/support/lsp-mock
  (:use #:cl)
  (:import-from #:usocket
                #:socket-listen
                #:socket-accept
                #:socket-close
                #:socket-stream
                #:get-local-port
                #:connection-refused-error)
  (:import-from #:flexi-streams
                #:make-flexi-stream
                #:string-to-octets
                #:octets-to-string)
  (:import-from #:com.inuoe.jzon)
  (:import-from #:bordeaux-threads
                #:make-thread
                #:make-lock
                #:with-lock-held
                #:make-condition-variable
                #:condition-wait
                #:condition-notify
                #:thread-alive-p
                #:destroy-thread)
  (:export #:with-lsp-mock-server
           #:%start-mock-lsp-server
           #:%stop-mock-lsp-server
           #:mock-lsp-server-received-methods))

(in-package #:dsmr-mcp/tests/support/lsp-mock)

;;; ---------------------------------------------------------------------------
;;; Content-Length framing helpers
;;; ---------------------------------------------------------------------------

(defun %read-lsp-header-line (flexi-stream)
  "Read one CR+LF-terminated header line from FLEXI-STREAM as a string.
Returns the line content without trailing CR or LF."
  ;; LSP headers are ASCII; read byte-by-byte for simplicity.
  (let ((bytes (make-array 0 :element-type '(unsigned-byte 8) :adjustable t
                             :fill-pointer 0)))
    (loop
      (let ((b (read-byte flexi-stream nil nil)))
        (cond
          ((null b) (return (octets-to-string bytes :external-format :utf-8)))
          ((= b 13)                     ; CR — consume the following LF
           (let ((next (read-byte flexi-stream nil nil)))
             (declare (ignore next)))
           (return (octets-to-string bytes :external-format :utf-8)))
          ((= b 10)                     ; bare LF — also accept
           (return (octets-to-string bytes :external-format :utf-8)))
          (t (vector-push-extend b bytes)))))))

(defun %lsp-read-message (flexi-stream)
  "Read one Content-Length–framed LSP message from FLEXI-STREAM.
Returns a parsed jzon hash-table, or NIL on EOF."
  (let ((content-length nil))
    ;; Read header lines until empty line.
    (loop
      (let ((line (%read-lsp-header-line flexi-stream)))
        (cond
          ((null line) (return-from %lsp-read-message nil))
          ((zerop (length line)) (return))
          ((and (>= (length line) 15)
                (string-equal (subseq line 0 15) "Content-Length:"))
           (setf content-length
                 (parse-integer (string-trim '(#\Space)
                                             (subseq line 15))))))))
    (unless content-length
      (return-from %lsp-read-message nil))
    (let ((buf (make-array content-length :element-type '(unsigned-byte 8))))
      (let ((n (read-sequence buf flexi-stream)))
        (when (zerop n)
          (return-from %lsp-read-message nil)))
      (handler-case
          (com.inuoe.jzon:parse (octets-to-string buf :external-format :utf-8))
        (error () nil)))))

(defun %lsp-write-message (stream ht)
  "Write HT as a Content-Length–framed LSP message to STREAM (binary socket stream)."
  (let* ((json-str  (com.inuoe.jzon:stringify ht))
         (body-bytes (string-to-octets json-str :external-format :utf-8))
         (header     (format nil "Content-Length: ~A~C~C~C~C"
                             (length body-bytes)
                             #\Return #\Newline
                             #\Return #\Newline))
         (hdr-bytes  (string-to-octets header :external-format :utf-8)))
    (write-sequence hdr-bytes stream)
    (write-sequence body-bytes stream)
    (force-output stream)))

;;; ---------------------------------------------------------------------------
;;; Mock server state
;;; ---------------------------------------------------------------------------

(defstruct mock-lsp-server
  "Internal state for a running in-process LSP mock server."
  (listen-socket  nil)
  (accept-thread  nil)
  (stop-flag      nil)                  ; set to T to signal the accept thread
  (stop-lock      (make-lock "mock-stop-lock"))
  ;; Canned responses: alist of (method-string . response-hash-table).
  ;; When an inbound request matches a method, the server replies with the ht
  ;; stamped with the request's id.
  (canned-responses nil)
  ;; Pending server→client request support:
  ;; a function the test can call to push a server-initiated request.
  ;; The mock sends it and waits for the client's response.
  (server-request-lock    (make-lock "mock-svr-req-lock"))
  (server-request-cv      (make-condition-variable :name "mock-svr-req-cv"))
  (pending-server-request nil)          ; hash-table of the request to send
  (server-request-reply   nil)          ; set when client's response arrives
  ;; Bound port — set by the accept thread before signalling ready.
  (port            nil)
  (port-lock       (make-lock "mock-port-lock"))
  (port-cv         (make-condition-variable :name "mock-port-cv"))
  ;; received-methods: ordered list of all method strings received from the
  ;; client (both requests and notifications), in arrival order.
  ;; Protected by received-methods-lock.  Tests use this to assert ordering.
  (received-methods      nil)
  (received-methods-lock (make-lock "mock-recv-methods-lock")))

;;; ---------------------------------------------------------------------------
;;; Accept loop
;;; ---------------------------------------------------------------------------

(defun %handle-mock-connection (conn server)
  "Handle one accepted connection on CONN for mock SERVER.
Reads Content-Length frames, matches methods against canned-responses,
replies.  Handles server→client workspace/configuration requests."
  (let* ((raw-stream  (socket-stream conn))
         (flexi       (make-flexi-stream raw-stream))
         (write-lock  (make-lock "mock-conn-write-lock")))
    (flet ((send-ht (ht)
             (with-lock-held (write-lock)
               (%lsp-write-message raw-stream ht))))
      (unwind-protect
           (loop
             ;; Deliver any pending server→client request.
             (with-lock-held ((mock-lsp-server-server-request-lock server))
               (when (mock-lsp-server-pending-server-request server)
                 (let ((req (mock-lsp-server-pending-server-request server)))
                   (setf (mock-lsp-server-pending-server-request server) nil)
                   (send-ht req))))
             ;; Check stop flag.
             (with-lock-held ((mock-lsp-server-stop-lock server))
               (when (mock-lsp-server-stop-flag server)
                 (return)))
             ;; Try to read a message (non-blocking check via a flexi-stream peek).
             ;; Use a short sb-ext:with-timeout to avoid blocking forever.
             (let ((msg (handler-case
                             (sb-ext:with-timeout 0.1
                               (%lsp-read-message flexi))
                           (sb-ext:timeout () :timeout)
                           (error () nil))))
               (cond
                 ((eq msg :timeout) nil) ; just loop and check stop flag again
                 ((null msg) (return))   ; EOF or parse error — close connection
                 (t
                  ;; Dispatch the inbound message.
                  (let ((method (gethash "method" msg))
                        (id     (gethash "id" msg)))
                    ;; Record every inbound method (requests and notifications)
                    ;; in received-methods so tests can assert ordering.
                    (when method
                      (with-lock-held ((mock-lsp-server-received-methods-lock server))
                        (setf (mock-lsp-server-received-methods server)
                              (append (mock-lsp-server-received-methods server)
                                      (list method)))))
                    (cond
                      ;; Server→client response (client is replying to OUR request).
                      ((and (null method) (or (gethash "result" msg)
                                              (gethash "error" msg)))
                       (with-lock-held ((mock-lsp-server-server-request-lock server))
                         (setf (mock-lsp-server-server-request-reply server) msg)
                         (condition-notify (mock-lsp-server-server-request-cv server))))
                      ;; Client→server request: look up in canned responses.
                      ((and method id)
                       (let ((canned (cdr (assoc method
                                                 (mock-lsp-server-canned-responses server)
                                                 :test #'string=))))
                         (if canned
                             (let ((reply (make-hash-table :test 'equal)))
                               (setf (gethash "jsonrpc" reply) "2.0"
                                     (gethash "id"      reply) id
                                     (gethash "result"  reply) canned)
                               (send-ht reply))
                             ;; No canned response: reply with null result.
                             (let ((reply (make-hash-table :test 'equal)))
                               (setf (gethash "jsonrpc" reply) "2.0"
                                     (gethash "id"      reply) id
                                     (gethash "result"  reply) :null)
                               (send-ht reply)))))
                      ;; Client→server notification (no id): already recorded above.
                      (method nil)
                      ))))))
        ;; Teardown: close connection.
        (ignore-errors (socket-close conn))))))

(defun %mock-accept-loop (server)
  "Accept connections on SERVER's listen socket until the stop flag is set."
  (let ((listen-sock (mock-lsp-server-listen-socket server)))
    ;; Report the bound port.
    (let ((port (get-local-port listen-sock)))
      (with-lock-held ((mock-lsp-server-port-lock server))
        (setf (mock-lsp-server-port server) port)
        (condition-notify (mock-lsp-server-port-cv server))))
    (loop
      (with-lock-held ((mock-lsp-server-stop-lock server))
        (when (mock-lsp-server-stop-flag server)
          (return)))
      (let ((conn (handler-case
                      (sb-ext:with-timeout 0.1
                        (socket-accept listen-sock :element-type '(unsigned-byte 8)))
                    (sb-ext:timeout () nil)
                    (error () nil))))
        (when conn
          ;; Handle the connection inline (tests are single-client).
          (%handle-mock-connection conn server))))))

;;; ---------------------------------------------------------------------------
;;; Public start / stop
;;; ---------------------------------------------------------------------------

(defun %start-mock-lsp-server (&key canned-responses on-bound)
  "Start an in-process mock LSP TCP server on an OS-assigned port.
Returns a MOCK-LSP-SERVER structure.

CANNED-RESPONSES — alist of (method-string . response-hash-table).
ON-BOUND         — optional thunk called with the bound port integer once
                   the listen socket is ready."
  (let* ((listen-sock (socket-listen "127.0.0.1" 0
                                     :reuse-address t
                                     :element-type '(unsigned-byte 8)))
         (server (make-mock-lsp-server
                  :listen-socket   listen-sock
                  :canned-responses canned-responses)))
    (setf (mock-lsp-server-accept-thread server)
          (make-thread
           (lambda ()
             (unwind-protect
                  (%mock-accept-loop server)
               (ignore-errors (socket-close listen-sock))))
           :name "lsp-mock-accept"))
    ;; Wait until the port is known.
    (with-lock-held ((mock-lsp-server-port-lock server))
      (loop until (mock-lsp-server-port server)
            do (condition-wait (mock-lsp-server-port-cv server)
                               (mock-lsp-server-port-lock server))))
    (when on-bound
      (funcall on-bound (mock-lsp-server-port server)))
    server))

(defun %stop-mock-lsp-server (server)
  "Stop the mock LSP server SERVER and join its accept thread."
  (when server
    (with-lock-held ((mock-lsp-server-stop-lock server))
      (setf (mock-lsp-server-stop-flag server) t))
    (let ((thr (mock-lsp-server-accept-thread server)))
      (when (and thr (thread-alive-p thr))
        (handler-case
            (sb-ext:with-timeout 2
              (bordeaux-threads:join-thread thr))
          (error () (ignore-errors (destroy-thread thr))))))
    (ignore-errors (socket-close (mock-lsp-server-listen-socket server)))))

;;; ---------------------------------------------------------------------------
;;; with-lsp-mock-server macro
;;; ---------------------------------------------------------------------------

(defmacro with-lsp-mock-server ((client-var &key canned-responses server) &body body)
  "Start an in-process Content-Length LSP TCP server on an OS-assigned port.
Bind CLIENT-VAR to a connected LSP client (via dsmr-mcp/src/lsp/client:connect-lsp-client
once that package exists), execute BODY, then tear down both the client and
the server via unwind-protect.

CANNED-RESPONSES is an alist of (method-string . response-hash-table) for
scripting server replies.  The server answers an inbound request whose method
matches a canned key, stamping the response with the request's id.

SERVER, when provided as a symbol, is bound to the MOCK-LSP-SERVER struct.
Tests use this to access MOCK-LSP-SERVER-RECEIVED-METHODS after the body runs.

CLIENT-VAR is NIL when the mock is used before the Wave-1 LSP client package
is loaded (Wave 0 tests that only exercise the server side use :no-client t).

Mirrors with-temporary-slynk-listener's retry-connect loop (slynk-fixture.lisp)
and unwind-protect teardown.  Binds to 127.0.0.1 only (T-lsp-scaffold-01)."
  (let ((port-var    (gensym "LSP-MOCK-PORT-"))
        (server-var  (or server (gensym "LSP-MOCK-SERVER-")))
        (attempt-var (gensym "LSP-MOCK-ATTEMPT-"))
        (max-var     (gensym "LSP-MOCK-MAX-")))
    `(let* ((,port-var   nil)
            (,server-var (%start-mock-lsp-server
                          :on-bound (lambda (p) (setf ,port-var p))
                          :canned-responses ,canned-responses))
            (,max-var    20)
            (,client-var nil))
       ;; Retry connect up to max-tries — the accept loop may not be live yet.
       ;; CLIENT-VAR is NIL if the Wave-1 client package is not yet loaded.
       (dotimes (,attempt-var ,max-var)
         (when ,port-var
           (setf ,client-var
                 (ignore-errors
                   ;; Reference by fully-qualified name; not imported at
                   ;; compile time so the fixture compiles before Wave 1 lands.
                   (funcall (find-symbol "CONNECT-LSP-CLIENT"
                                         "DSMR-MCP/SRC/LSP/CLIENT")
                            "127.0.0.1" ,port-var)))
           (when ,client-var (return)))
         (sleep 0.05))
       ;; If the Wave-1 client package is absent, CLIENT-VAR stays NIL.
       ;; Wave 0 tests that exercise only the mock server side still proceed.
       (unwind-protect
            (progn ,@body)
         ;; Teardown: shut down client first, then server.
         (when ,client-var
           (ignore-errors
             (funcall (find-symbol "LSP-SHUTDOWN" "DSMR-MCP/SRC/LSP/CLIENT")
                      ,client-var)))
         (ignore-errors (%stop-mock-lsp-server ,server-var))))))
