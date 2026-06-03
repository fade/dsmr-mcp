;;;; src/lsp/client.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; alive-lsp TCP client: Content-Length base-protocol framing, reader thread
;;;; with id-keyed request/response correlation, server→client request handling
;;;; (workspace/configuration so rangeFormatting does not hang), attach-else-spawn
;;;; lifecycle (probe 127.0.0.1:8006 first; on refusal spawn a child SBCL running
;;;; alive-lsp with OS-assigned ephemeral port), per-project-root registry, and
;;;; idle eviction mirroring http.lisp's eviction sweep.
;;;;
;;;; Connect discipline: sb-ext:with-timeout around usocket:socket-connect only.
;;;; Never use the :timeout keyword on socket-connect — it sets SO_RCVTIMEO and
;;;; causes IO-TIMEOUT on every subsequent read (cl-mcp PR #67 bug).
;;;;
;;;; Spawn stdout-redirect ordering: alive-lsp's start-server captures
;;;; *standard-output* before threading.  Redirect stdout→stderr during
;;;; (asdf:load-system "alive-lsp"), restore to sb-sys:*stdout* before
;;;; (alive/server:start), redirect again after start returns.

(defpackage #:dsmr-mcp/src/lsp/client
  (:use #:cl)
  (:import-from #:bordeaux-threads
                #:make-lock #:with-lock-held #:make-thread
                #:make-condition-variable #:condition-wait #:condition-notify
                #:thread-alive-p #:join-thread #:destroy-thread #:interrupt-thread)
  (:import-from #:dsmr-mcp/src/log #:log-event)
  (:import-from #:usocket
                #:socket-connect #:socket-close #:socket-stream
                #:socket-listen #:get-local-port
                #:connection-refused-error)
  (:import-from #:com.inuoe.jzon)
  (:import-from #:flexi-streams
                #:make-flexi-stream #:string-to-octets #:octets-to-string)
  (:import-from #:sb-ext)
  (:import-from #:sb-posix)
  (:import-from #:uiop)
  (:export #:lsp-client
           #:lsp-client-socket
           #:lsp-client-attached-p
           #:lsp-client-project-root
           #:lsp-client-last-active
           #:lsp-client-active-requests
           #:lsp-client-opened-uris
           #:lsp-client-opened-uris-lock
           #:ensure-lsp-client
           #:find-lsp-client
           #:connect-lsp-client
           #:lsp-send-request
           #:lsp-send-notification
           #:lsp-shutdown
           #:lsp-client-connected-p
           #:lsp-connection-lost
           #:bump-uri-version
           #:*lsp-idle-timeout*
           #:*lsp-startup-timeout*
           #:*lsp-registry*
           #:*lsp-registry-lock*
           #:start-lsp-cleanup
           #:stop-lsp-cleanup))

(in-package #:dsmr-mcp/src/lsp/client)

;;; ---------------------------------------------------------------------------
;;; Configuration specials
;;; ---------------------------------------------------------------------------

(defparameter *lsp-startup-timeout*
  (let ((v (uiop:getenv "DSMR_LSP_STARTUP_TIMEOUT")))
    (if (and v (not (string= v "")))
        (max 1 (parse-integer v :junk-allowed t))
        30))
  "Maximum seconds to wait for alive-lsp [STARTING] line on stdout.
Override via DSMR_LSP_STARTUP_TIMEOUT environment variable.")

(defparameter *lsp-idle-timeout* 3600
  "Seconds a per-root LSP client may be idle before eviction.
Matches http.lisp *session-timeout-seconds* default (D-09).")

(defparameter *lsp-cleanup-interval* 60
  "Seconds between idle-eviction sweeps.")

(defparameter *lsp-attach-port* 8006
  "Default port to probe for an existing alive-lsp instance (D-08).")

(defparameter *lsp-attach-host* "127.0.0.1"
  "Host to probe for alive-lsp. Loopback only (T-lsp-client-02).")

;;; ---------------------------------------------------------------------------
;;; Per-root registry
;;; ---------------------------------------------------------------------------

(defvar *lsp-registry* (make-hash-table :test 'equal)
  "Hash-table mapping project-root namestring → LSP-CLIENT.
Protected by *LSP-REGISTRY-LOCK*.")

(defvar *lsp-registry-lock* (make-lock "lsp-registry-lock")
  "Lock protecting *LSP-REGISTRY* for thread-safe read/write.")

;;; ---------------------------------------------------------------------------
;;; Client struct
;;; ---------------------------------------------------------------------------

(defstruct lsp-client
  "Represents an alive-lsp TCP connection and its communication state."
  (socket          nil)
  (flexi-stream    nil)                  ; flexi-streams wrapper for read side
  (write-lock      (make-lock "lsp-write-lock"))
  (reader-thread   nil)
  ;; pending-requests: integer id → (condition-variable . result-cell)
  ;; result-cell is a two-element list: (value errorp)
  ;; Initial value is (+pending-sentinel+ nil); both fields are written
  ;; atomically under pending-lock before condition-notify.
  (pending-requests (make-hash-table :test 'eql))
  (pending-lock    (make-lock "lsp-pending-lock"))
  (next-id         1    :type integer)
  (last-active     (get-universal-time) :type integer)
  (active-requests 0    :type integer)  ; guard: skip eviction when > 0
  (active-req-lock (make-lock "lsp-active-req-lock"))
  (attached-p      nil  :type boolean)  ; T when we did not spawn the process
  (process-info    nil)                 ; sb-ext:process for spawned children
  (project-root    nil)                 ; project root namestring or pathname
  (%connected      nil  :type boolean)  ; set T after handshake, NIL on disconnect
  ;; per-URI version counter for textDocument/didChange
  (uri-versions    (make-hash-table :test 'equal))
  (uri-versions-lock (make-lock "lsp-uri-versions-lock"))
  ;; opened-uris: tracks URIs for which textDocument/didOpen has been sent.
  ;; The bridge sends didOpen on first position query and didChange on
  ;; subsequent queries so alive-lsp's in-memory buffer matches disk.
  (opened-uris     (make-hash-table :test 'equal))
  (opened-uris-lock (make-lock "lsp-opened-uris-lock")))

;;; ---------------------------------------------------------------------------
;;; Condition
;;; ---------------------------------------------------------------------------

(define-condition lsp-connection-lost (error)
  ((reason :initarg :reason :reader lsp-connection-lost-reason
           :initform "unknown"))
  (:report (lambda (c s)
             (format s "LSP connection lost: ~A"
                     (lsp-connection-lost-reason c))))
  (:documentation "Signaled when the TCP connection to alive-lsp drops or times out.
Distinct from protocol-level LSP error responses (those are re-signaled without
marking the client disconnected)."))

;;; ---------------------------------------------------------------------------
;;; Content-Length framing — write side
;;; ---------------------------------------------------------------------------

(defun %lsp-write-message (client ht)
  "Write HT as a Content-Length–framed LSP message to CLIENT's socket.
Holds the client's write-lock throughout the write.
HT is a hash-table; jzon:stringify serialises it to UTF-8 JSON."
  (with-lock-held ((lsp-client-write-lock client))
    (let* ((json-str  (com.inuoe.jzon:stringify ht))
           ;; Coerce to element-type CHARACTER to avoid base-char serialisation
           ;; issues on the Slynk wire — safe no-op for real sockets too.
           (json-str  (map 'string #'identity json-str))
           (body-bytes (string-to-octets json-str :external-format :utf-8))
           (header     (format nil "Content-Length: ~A~C~C~C~C"
                               (length body-bytes)
                               #\Return #\Newline
                               #\Return #\Newline))
           (hdr-bytes  (string-to-octets header :external-format :utf-8))
           (stream     (socket-stream (lsp-client-socket client))))
      (write-sequence hdr-bytes stream)
      (write-sequence body-bytes stream)
      (force-output stream))))

;;; ---------------------------------------------------------------------------
;;; Content-Length framing — read side
;;; ---------------------------------------------------------------------------

(defun %lsp-read-header-line (flexi-stream)
  "Read one CR+LF–terminated header line from FLEXI-STREAM as a string.
Returns the line content without the trailing CR or LF.
Signals END-OF-FILE when the stream is exhausted."
  (let ((bytes (make-array 0 :element-type '(unsigned-byte 8)
                             :adjustable t :fill-pointer 0)))
    (loop
      (let ((b (read-byte flexi-stream nil nil)))
        (cond
          ;; EOF before any content — treat as EOF
          ((null b)
           (if (zerop (fill-pointer bytes))
               (error 'end-of-file :stream flexi-stream)
               ;; Partial line — return what we have
               (return (octets-to-string bytes :external-format :utf-8))))
          ;; CR — consume the following LF
          ((= b 13)
           (let ((next (read-byte flexi-stream nil nil)))
             (declare (ignore next)))
           (return (octets-to-string bytes :external-format :utf-8)))
          ;; bare LF — accept as line terminator
          ((= b 10)
           (return (octets-to-string bytes :external-format :utf-8)))
          (t
           (vector-push-extend b bytes)))))))

(defun %lsp-read-message (flexi-stream)
  "Read one Content-Length–framed LSP message from FLEXI-STREAM.
Returns a jzon hash-table on success.
Signals END-OF-FILE or STREAM-ERROR on connection loss."
  (let ((content-length nil))
    ;; Read header lines until empty line.
    (loop
      (let ((line (%lsp-read-header-line flexi-stream)))
        (cond
          ((zerop (length line)) (return))
          ((and (>= (length line) 15)
                (string-equal (subseq line 0 15) "Content-Length:"))
           (setf content-length
                 (parse-integer (string-trim '(#\Space)
                                             (subseq line 15))))))))
    (unless content-length
      (error "LSP message missing Content-Length header"))
    ;; Read exactly content-length bytes then decode.
    (let ((buf (make-array content-length :element-type '(unsigned-byte 8))))
      (let ((n (read-sequence buf flexi-stream)))
        (when (< n content-length)
          (error 'end-of-file :stream flexi-stream)))
      (com.inuoe.jzon:parse
       (octets-to-string buf :external-format :utf-8)))))

;;; ---------------------------------------------------------------------------
;;; Reader thread — inbound message dispatch
;;; ---------------------------------------------------------------------------

(defun %make-lsp-response (id result)
  "Build a JSON-RPC 2.0 response hash-table with ID and RESULT."
  (let ((resp (make-hash-table :test 'equal)))
    (setf (gethash "jsonrpc" resp) "2.0"
          (gethash "id"      resp) id
          (gethash "result"  resp) result)
    resp))

(defun %answer-server-request (client msg)
  "Handle a server→client request in MSG (has both 'method' and 'id' keys).
Dispatches known methods to canned replies; unknown requests get a null result."
  (let ((method (gethash "method" msg))
        (id     (gethash "id"     msg)))
    (cond
      ;; workspace/configuration — alive-lsp sends this during rangeFormatting.
      ;; Reply with an empty config so the server unblocks (alive-lsp blocks
      ;; its formatting handler on this round-trip before replying).
      ((string= method "workspace/configuration")
       (let ((resp (%make-lsp-response id (vector (make-hash-table :test 'equal)))))
         (ignore-errors (%lsp-write-message client resp)))
       (log-event :debug "lsp.client.answered-workspace-configuration"
                  "id" id))
      ;; Unknown server→client request — reply with null to unblock it.
      (t
       (let ((resp (%make-lsp-response id :null)))
         (ignore-errors (%lsp-write-message client resp)))
       (log-event :debug "lsp.client.answered-unknown-server-request"
                  "method" method "id" id)))))

;;; Sentinel used as initial value in result cells to distinguish
;;; "not yet delivered" from a legitimate NIL result.
(defvar +pending-sentinel+ '#:pending-sentinel)

(defun %notify-pending (client id result-or-error errorp)
  "Wake a thread waiting on ID in the pending-requests table.
RESULT-OR-ERROR is stored in the result cell.
ERRORP T means the cell holds a condition to be re-signaled."
  (with-lock-held ((lsp-client-pending-lock client))
    (let ((entry (gethash id (lsp-client-pending-requests client))))
      (when entry
        (let ((cv   (car entry))
              (cell (cdr entry)))
          (setf (car cell) result-or-error
                (cadr cell) errorp)
          (condition-notify cv))))))

(defun %mark-client-disconnected (client reason)
  "Mark CLIENT as disconnected and wake all pending waiters with an error."
  (setf (lsp-client-%connected client) nil)
  ;; Wake all pending waiters with lsp-connection-lost.
  (with-lock-held ((lsp-client-pending-lock client))
    (maphash
     (lambda (id entry)
       (declare (ignore id))
       (let ((cv   (car entry))
             (cell (cdr entry)))
         (when (eq (car cell) +pending-sentinel+)
           (setf (car cell) (make-condition 'lsp-connection-lost :reason reason)
                 (cadr cell) t)
           (condition-notify cv))))
     (lsp-client-pending-requests client))))

(defun %result-key-present-p (msg)
  "Return T when MSG (a jzon hash-table) contains a 'result' key, even if null."
  (let ((not-found '#:not-found))
    (not (eq (gethash "result" msg not-found) not-found))))

(defun %reader-thread-body (client)
  "Main body of the reader thread: reads Content-Length frames and dispatches.
Runs until the socket is closed or an I/O error occurs."
  (handler-case
      (loop
        (let ((msg (%lsp-read-message (lsp-client-flexi-stream client))))
          ;; Bump last-active on every received message.
          (setf (lsp-client-last-active client) (get-universal-time))
          (let ((method (gethash "method" msg))
                (id     (gethash "id"     msg))
                (err    (gethash "error"  msg)))
            (cond
              ;; Server→client REQUEST (has method AND id) — must respond.
              ((and method id)
               (%answer-server-request client msg))
              ;; Server→client NOTIFICATION (method, no id) — log and discard.
              (method
               (log-event :debug "lsp.client.server-notification"
                          "method" method))
              ;; Response to our request: has "result" key (even null) or "error".
              ((and id (or err (%result-key-present-p msg)))
               (if err
                   ;; LSP error response — wrap as a condition but do not
                   ;; mark client disconnected (protocol error, not wire error).
                   (let ((ec   (gethash "code"    err))
                         (emsg (gethash "message" err)))
                     (%notify-pending client id
                                      (make-condition 'simple-error
                                                      :format-control "LSP error ~A: ~A"
                                                      :format-arguments (list ec emsg))
                                      t))
                   ;; Success response — pass the result value (may be :null for JSON null).
                   (%notify-pending client id (gethash "result" msg) nil)))
              ;; Message has an id but neither method nor result/error — ignore.
              (id
               (log-event :debug "lsp.client.reader-unknown-message"
                          "id" id))))))
    (end-of-file ()
      (log-event :info "lsp.client.reader-eof" "root"
                 (when (lsp-client-project-root client)
                   (namestring (lsp-client-project-root client))))
      (%mark-client-disconnected client "eof"))
    (stream-error (e)
      (log-event :warn "lsp.client.reader-stream-error"
                 "error" (princ-to-string e))
      (%mark-client-disconnected client "stream-error"))
    (error (e)
      (log-event :warn "lsp.client.reader-error"
                 "error" (princ-to-string e))
      (%mark-client-disconnected client "error"))))

;;; ---------------------------------------------------------------------------
;;; Connect and handshake
;;; ---------------------------------------------------------------------------

(defun %raw-connect (host port timeout)
  "Attempt a TCP connect to HOST:PORT with TIMEOUT seconds.
Returns a usocket socket on success, NIL on connection-refused or timeout.
Uses sb-ext:with-timeout — never the :timeout keyword (cl-mcp PR #67)."
  (handler-case
      (sb-ext:with-timeout timeout
        (socket-connect host port :element-type '(unsigned-byte 8)))
    (sb-ext:timeout ()
      nil)
    (connection-refused-error ()
      nil)
    (error (e)
      (log-event :debug "lsp.client.connect-error" "error" (princ-to-string e))
      nil)))

(defun %perform-initialize-handshake (client project-root)
  "Send the LSP initialize request and initialized notification to CLIENT.
PROJECT-ROOT is the root URI sent in the initialize params (or NIL).
Returns T on success. Signals on wire failure."
  ;; Build initialize request.
  (let* ((params (let ((ht (make-hash-table :test 'equal)))
                   (setf (gethash "processId"   ht) (sb-posix:getpid)
                         (gethash "rootUri"     ht)
                         (if project-root
                             (format nil "file://~A" (namestring project-root))
                             :null)
                         (gethash "capabilities" ht) (make-hash-table :test 'equal))
                   ht))
         (req (let ((ht (make-hash-table :test 'equal)))
                (setf (gethash "jsonrpc" ht) "2.0"
                      (gethash "id"      ht) 1
                      (gethash "method"  ht) "initialize"
                      (gethash "params"  ht) params)
                ht)))
    ;; Write initialize request (reader thread not yet started — write directly).
    (with-lock-held ((lsp-client-write-lock client))
      (let* ((json-str   (com.inuoe.jzon:stringify req))
             (json-str   (map 'string #'identity json-str))
             (body-bytes (string-to-octets json-str :external-format :utf-8))
             (header     (format nil "Content-Length: ~A~C~C~C~C"
                                 (length body-bytes)
                                 #\Return #\Newline
                                 #\Return #\Newline))
             (hdr-bytes  (string-to-octets header :external-format :utf-8))
             (stream     (socket-stream (lsp-client-socket client))))
        (write-sequence hdr-bytes stream)
        (write-sequence body-bytes stream)
        (force-output stream)))
    ;; Read initialize response directly (reader thread not started yet).
    (let ((resp (%lsp-read-message (lsp-client-flexi-stream client))))
      (declare (ignore resp))
      ;; We accept any non-error response — alive-lsp ignores all init params.
      )
    ;; Send initialized notification (no id — a notification).
    (let ((notif (let ((ht (make-hash-table :test 'equal)))
                   (setf (gethash "jsonrpc" ht) "2.0"
                         (gethash "method"  ht) "initialized"
                         (gethash "params"  ht) (make-hash-table :test 'equal))
                   ht)))
      (with-lock-held ((lsp-client-write-lock client))
        (let* ((json-str   (com.inuoe.jzon:stringify notif))
               (json-str   (map 'string #'identity json-str))
               (body-bytes (string-to-octets json-str :external-format :utf-8))
               (header     (format nil "Content-Length: ~A~C~C~C~C"
                                   (length body-bytes)
                                   #\Return #\Newline
                                   #\Return #\Newline))
               (hdr-bytes  (string-to-octets header :external-format :utf-8))
               (stream     (socket-stream (lsp-client-socket client))))
          (write-sequence hdr-bytes stream)
          (write-sequence body-bytes stream)
          (force-output stream)))))
  t)

(defun %start-reader-thread (client)
  "Start the background reader thread for CLIENT."
  (setf (lsp-client-reader-thread client)
        (make-thread
         (lambda () (%reader-thread-body client))
         :name (format nil "lsp-reader-~A"
                       (or (lsp-client-project-root client) "?")))))

(defun connect-lsp-client (host port &key project-root)
  "Connect to an alive-lsp server at HOST:PORT.
Performs the initialize/initialized handshake, starts the reader thread,
and returns a connected LSP-CLIENT on success, or NIL on failure.
PROJECT-ROOT, if provided, is sent in the initialize params."
  (let ((sock (%raw-connect host port 2)))
    (unless sock
      (return-from connect-lsp-client nil))
    (let* ((flexi  (make-flexi-stream (socket-stream sock)))
           (client (make-lsp-client
                    :socket       sock
                    :flexi-stream flexi
                    :attached-p   t       ; caller overrides to NIL for spawned
                    :project-root project-root)))
      (handler-case
          (progn
            (%perform-initialize-handshake client project-root)
            (setf (lsp-client-%connected client) t)
            (%start-reader-thread client)
            (log-event :info "lsp.client.connected"
                       "host" host "port" port
                       "root" (when project-root (namestring project-root)))
            client)
        (error (e)
          (log-event :warn "lsp.client.connect-handshake-failed"
                     "error" (princ-to-string e))
          (ignore-errors (socket-close sock))
          nil)))))

;;; ---------------------------------------------------------------------------
;;; Public API — send request / notification
;;; ---------------------------------------------------------------------------

(defun lsp-send-request (client method params)
  "Send an LSP JSON-RPC request to CLIENT and wait for the response.
Returns the result hash-table on success.
Signals LSP-CONNECTION-LOST on wire loss or connection timeout.
Signals SIMPLE-ERROR for LSP protocol error responses."
  ;; Bump active-requests so the eviction sweep skips this client.
  (with-lock-held ((lsp-client-active-req-lock client))
    (incf (lsp-client-active-requests client)))
  (unwind-protect
       (progn
         (unless (lsp-client-%connected client)
           (error 'lsp-connection-lost :reason "not-connected"))
         ;; Allocate request id and register condition variable + result cell.
         (let* ((id   (with-lock-held ((lsp-client-pending-lock client))
                        (incf (lsp-client-next-id client))))
                (cv   (make-condition-variable :name (format nil "lsp-req-~A" id)))
                ;; result cell: (value errorp)
                ;; initial value is +pending-sentinel+ to distinguish "not yet
                ;; delivered" from a legitimate NIL result.
                (cell (list +pending-sentinel+ nil))
                (req  (let ((ht (make-hash-table :test 'equal)))
                        (setf (gethash "jsonrpc" ht) "2.0"
                              (gethash "id"      ht) id
                              (gethash "method"  ht) method)
                        (when params
                          (setf (gethash "params" ht) params))
                        ht)))
           ;; Register the pending entry.
           (with-lock-held ((lsp-client-pending-lock client))
             (setf (gethash id (lsp-client-pending-requests client))
                   (cons cv cell)))
           (unwind-protect
                (handler-case
                    (let ((value nil) (errorp nil))
                      ;; Write the request.
                      (%lsp-write-message client req)
                      ;; Wait for the reader thread to deliver a result.
                      ;; Read value and errorp while still holding the lock
                      ;; so the write from %notify-pending is fully visible.
                      (with-lock-held ((lsp-client-pending-lock client))
                        (loop while (eq (car cell) +pending-sentinel+)
                              do (condition-wait cv (lsp-client-pending-lock client)
                                                 :timeout 120))
                        ;; Read inside the lock before releasing.
                        (setf value  (car cell)
                              errorp (cadr cell)))
                      (cond
                        ;; Still sentinel after timeout — treat as wire loss.
                        ((eq value +pending-sentinel+)
                         (error 'lsp-connection-lost :reason "response-timeout"))
                        ;; Error cell — re-signal.
                        (errorp
                         (error value))
                        ;; Success.
                        (t value)))
                  (end-of-file ()
                    (error 'lsp-connection-lost :reason "eof"))
                  (stream-error (e)
                    (error 'lsp-connection-lost
                           :reason (princ-to-string e))))
             ;; Always remove the pending entry.
             (with-lock-held ((lsp-client-pending-lock client))
               (remhash id (lsp-client-pending-requests client))))))
    ;; Decrement active-requests.
    (with-lock-held ((lsp-client-active-req-lock client))
      (decf (lsp-client-active-requests client)))
    ;; Touch last-active on every completed request.
    (setf (lsp-client-last-active client) (get-universal-time))))

(defun lsp-send-notification (client method params)
  "Send an LSP JSON-RPC notification to CLIENT (no id, no response expected).
Returns NIL. Signals LSP-CONNECTION-LOST on wire failure."
  (unless (lsp-client-%connected client)
    (error 'lsp-connection-lost :reason "not-connected"))
  (let ((notif (let ((ht (make-hash-table :test 'equal)))
                 (setf (gethash "jsonrpc" ht) "2.0"
                       (gethash "method"  ht) method)
                 (when params
                   (setf (gethash "params" ht) params))
                 ht)))
    (handler-case
        (%lsp-write-message client notif)
      (error (e)
        (error 'lsp-connection-lost :reason (princ-to-string e)))))
  (setf (lsp-client-last-active client) (get-universal-time))
  nil)

(defun lsp-client-connected-p (client)
  "Return T when CLIENT's connection is up and the reader thread is alive."
  (and (lsp-client-%connected client)
       (let ((thr (lsp-client-reader-thread client)))
         (or (null thr) (thread-alive-p thr)))))

;;; ---------------------------------------------------------------------------
;;; URI version counter
;;; ---------------------------------------------------------------------------

(defun bump-uri-version (client uri)
  "Increment and return the version counter for URI on CLIENT.
The counter starts at 1 on first use and increments on each call.
Used by document sync to populate the monotonic version field in
textDocument/didChange — alive-lsp requires a strictly increasing version
per URI to correctly sequence document changes."
  (with-lock-held ((lsp-client-uri-versions-lock client))
    (let ((v (or (gethash uri (lsp-client-uri-versions client)) 0)))
      (setf (gethash uri (lsp-client-uri-versions client)) (1+ v))
      (1+ v))))

;;; ---------------------------------------------------------------------------
;;; Shutdown
;;; ---------------------------------------------------------------------------

(defun %reap-reader-thread (thread)
  "Stop the reader THREAD promptly and return.

Closing the socket from another thread does NOT reliably wake a thread blocked
in a socket read on SBCL, so a plain join waits out its full timeout (~2s) every
time. Instead interrupt the reader to unwind its blocked read, then join under a
short bound. sb-ext:with-timeout signals SB-EXT:TIMEOUT, which is a
SERIOUS-CONDITION and NOT an ERROR -- the join guard must catch serious-condition
or the timeout escapes; on the rare miss, terminate the thread outright."
  (when (and thread (thread-alive-p thread))
    (ignore-errors (interrupt-thread thread #'sb-thread:abort-thread))
    (handler-case
        (sb-ext:with-timeout 1 (join-thread thread))
      (serious-condition () (ignore-errors (destroy-thread thread))))))

(defun lsp-shutdown (client)
  "Close the LSP connection and reap spawned children.
For attached clients: close the socket only (do not kill the process).
For spawned clients: close the socket, SIGTERM→SIGKILL the child process."
  (setf (lsp-client-%connected client) nil)
  ;; Close socket — causes alive-lsp to hit EOF and stop.
  (ignore-errors (socket-close (lsp-client-socket client)))
  (setf (lsp-client-socket client) nil)
  ;; Stop the reader thread.
  (let ((thr (lsp-client-reader-thread client)))
    (when (and thr (thread-alive-p thr))
      (%reap-reader-thread thr)
      (setf (lsp-client-reader-thread client) nil)))
  ;; Reap spawned child (attached servers are left running).
  (unless (lsp-client-attached-p client)
    (let ((proc (lsp-client-process-info client)))
      (when proc
        (handler-case
            (when (sb-ext:process-alive-p proc)
              (sb-ext:process-kill proc 15)
              (loop repeat 20
                    while (sb-ext:process-alive-p proc)
                    do (sleep 0.1))
              (when (sb-ext:process-alive-p proc)
                (sb-ext:process-kill proc 9)
                (sleep 0.2)))
          (error (e)
            (log-event :warn "lsp.client.shutdown.kill-error"
                       "error" (princ-to-string e))))
        (ignore-errors (sb-ext:process-close proc))
        (setf (lsp-client-process-info client) nil))))
  ;; Remove the per-client formatting lock from the bridge table so it does
  ;; not accumulate across the server's lifetime.
  (ignore-errors
    (uiop:symbol-call :dsmr-mcp/src/lsp/bridge :%remove-formatting-lock client))
  (log-event :info "lsp.client.shutdown"
             "root" (when (lsp-client-project-root client)
                      (namestring (lsp-client-project-root client)))
             "attached" (lsp-client-attached-p client))
  nil)

;;; ---------------------------------------------------------------------------
;;; Eviction
;;; ---------------------------------------------------------------------------

(defun %evict-lsp-client (client root-str)
  "Evict CLIENT from the registry. Attached → close socket only.
Spawned → close socket then SIGTERM→SIGKILL."
  (log-event :info "lsp.client.evicting" "root" root-str
             "attached" (lsp-client-attached-p client))
  (if (lsp-client-attached-p client)
      ;; Attached: close socket but do NOT kill the process.
      (progn
        (setf (lsp-client-%connected client) nil)
        (ignore-errors (socket-close (lsp-client-socket client)))
        (setf (lsp-client-socket client) nil)
        (let ((thr (lsp-client-reader-thread client)))
          (when (and thr (thread-alive-p thr))
            (%reap-reader-thread thr)
            (setf (lsp-client-reader-thread client) nil)))
        ;; Remove the per-client formatting lock from the bridge table.
        (ignore-errors
          (uiop:symbol-call :dsmr-mcp/src/lsp/bridge :%remove-formatting-lock client)))
      ;; Spawned: full shutdown (lsp-shutdown handles the lock removal).
      (lsp-shutdown client)))

;;; ---------------------------------------------------------------------------
;;; Registry — find and ensure
;;; ---------------------------------------------------------------------------

(defun find-lsp-client (project-root)
  "Look up PROJECT-ROOT in the registry. Returns the cached client or NIL.
No side effects — does not attach or spawn."
  (with-lock-held (*lsp-registry-lock*)
    (gethash (namestring project-root) *lsp-registry*)))

;;; Per-root connecting locks prevent duplicate initialize handshakes.
;;; A thread reaching the slow path holds this lock for its root while
;;; attaching/spawning; a concurrent caller for the same root blocks here
;;; rather than both completing separate handshakes to the same server.

(defvar *lsp-connecting-locks* (make-hash-table :test 'equal)
  "Hash-table mapping project-root namestring to a per-root lock.
Used to serialize the slow-path attach/spawn for a given root.")

(defvar *lsp-connecting-locks-lock* (make-lock "lsp-connecting-locks-lock")
  "Lock protecting *lsp-connecting-locks* for thread-safe read/write.")

(defun %connecting-lock-for-root (root-str)
  "Return (or create) the per-root connecting lock for ROOT-STR."
  (with-lock-held (*lsp-connecting-locks-lock*)
    (or (gethash root-str *lsp-connecting-locks*)
        (setf (gethash root-str *lsp-connecting-locks*)
              (make-lock (format nil "lsp-connecting-~A" root-str))))))

;;; ---------------------------------------------------------------------------
;;; Spawn support
;;; ---------------------------------------------------------------------------

(defvar *cached-sbcl-path* nil
  "Cached SBCL executable path.")

(defun %find-sbcl-path ()
  "Locate the sbcl executable."
  (or *cached-sbcl-path*
      (setf *cached-sbcl-path*
            (or (let ((argv0 (first sb-ext:*posix-argv*)))
                  (when (and argv0 (search "sbcl" argv0))
                    argv0))
                (handler-case
                    (let ((path (string-trim '(#\Newline #\Return #\Space)
                                  (uiop:run-program
                                   '("which" "sbcl") :output :string))))
                      (if (and path (plusp (length path))) path "sbcl"))
                  (error () "sbcl"))))))

(defun %quicklisp-setup-path ()
  "Return the Quicklisp setup.lisp path if Quicklisp is loaded, else NIL."
  (let ((ql-pkg (find-package :quicklisp)))
    (when ql-pkg
      (let ((sym (find-symbol "*QUICKLISP-HOME*" ql-pkg)))
        (when (and sym (boundp sym))
          (let ((home (symbol-value sym)))
            (when home
              (namestring (merge-pathnames "setup.lisp" (namestring home))))))))))

(defparameter *alive-lsp-dir*
  (let ((v (uiop:getenv "DSMR_ALIVE_LSP_DIR")))
    (if (and v (plusp (length v))) v nil))
  "Filesystem path to the alive-lsp checkout for child-spawn mode.
Set via the DSMR_ALIVE_LSP_DIR environment variable.  When NIL, spawn is
disabled and only attach mode is attempted.  The ASDF source-registry is
pointed here so the child loads alive-lsp without needing it in the parent
image's dependency tree.")

(defun %build-lsp-sbcl-args ()
  "Build argv for spawning a child SBCL running alive-lsp.
Returns NIL when *alive-lsp-dir* is NIL (spawn disabled).

Stdout-redirect ordering:
  1. Redirect *standard-output* → *error-output* before (asdf:load-system)
     so ASDF compile notes go to stderr, not the handshake pipe.
  2. Restore *standard-output* to sb-sys:*stdout* before (alive/server:start).
     alive-lsp's start-server captures *standard-output* at call time and
     uses it in the spawned server thread — the [STARTING] line must reach fd 1.
  3. Redirect again after start returns to suppress runtime noise on fd 1.

--no-userinit prevents ~/.sbclrc from polluting stdout before the STARTING line.

Warning muffling: cold alive-lsp compiles emit warnings that abort without
muffling; handler-bind silences them so first-spawn cold compiles succeed.

Blocking join: alive/server:start is non-blocking — it returns a thread.
The child must block after starting or SBCL exits and kills the server thread.
We bind the result to *alive-lsp-thread* in the child and join it."
  (let ((alive-dir *alive-lsp-dir*)
        (ql-setup  (%quicklisp-setup-path)))
    (unless alive-dir
      (return-from %build-lsp-sbcl-args nil))
    (append
     (list "--noinform" "--non-interactive" "--no-userinit")
     (when ql-setup (list "--load" ql-setup))
     (list
      ;; Step 1: redirect stdout during load.
      "--eval"
      "(setf *standard-output* *error-output*
             *trace-output*    *error-output*
             *debug-io*        (make-two-way-stream *standard-input* *error-output*))"
      ;; Register alive-lsp source tree.
      "--eval"
      (format nil
              "(asdf:initialize-source-registry '(:source-registry :inherit-configuration (:tree ~S)))"
              alive-dir)
      ;; Load alive-lsp with warnings muffled so cold compiles succeed.
      "--eval"
      "(handler-bind ((warning #'muffle-warning)) (asdf:load-system \"alive-lsp\"))"
      ;; Step 2: restore stdout before start so [STARTING] reaches fd 1.
      "--eval" "(setf *standard-output* sb-sys:*stdout*)"
      ;; Start the server and save the returned thread so we can join it.
      "--eval" "(defvar *alive-lsp-thread* (alive/server:start))"
      ;; Step 3: redirect stdout again to suppress runtime noise.
      "--eval" "(setf *standard-output* *error-output*)"
      ;; Block until the server thread exits — keeps the child alive.
      "--eval" "(sb-thread:join-thread *alive-lsp-thread*)"))))

(defun %parse-lsp-started-line (stdout)
  "Read lines from STDOUT until the [STARTING] Started on port N line.
Returns the port integer. Signals on EOF before the line is found."
  (loop for line = (read-line stdout nil nil)
        do (when (null line)
             (error "alive-lsp closed stdout before STARTING line"))
        when (and (search "STARTING" line) (search "port" line))
          do (let ((pos (search "port " line)))
               (when pos
                 (let ((port-str (string-trim '(#\Space #\Newline #\Return)
                                              (subseq line (+ pos 5)))))
                   (let ((port (parse-integer port-str :junk-allowed t)))
                     (when port (return port))))))
        ;; If search found the markers but parse-integer failed, keep looping.
        finally (error "Exhausted stdout without finding port in STARTING line")))

(defun %start-stderr-drain (process root-str)
  "Start a daemon thread that forwards the child's stderr to *error-output*.
Without this the OS pipe buffer fills (64 KB on Linux) and the child blocks
on every stderr write, causing RPC calls to hang."
  (let ((err (sb-ext:process-error process)))
    (when err
      (make-thread
       (lambda ()
         (unwind-protect
              (ignore-errors
               (loop for line = (read-line err nil nil)
                     while line
                     do (ignore-errors
                         (write-string line *error-output*)
                         (terpri *error-output*)
                         (force-output *error-output*))))
           (ignore-errors (close err))))
       :name (format nil "lsp-stderr-~A" root-str)))))

(defun %kill-spawned-process (process)
  "SIGTERM, wait up to 500 ms, SIGKILL if still alive, then close streams."
  (ignore-errors
    (when (sb-ext:process-alive-p process)
      (sb-ext:process-kill process 15)
      (sleep 0.5)
      (when (sb-ext:process-alive-p process)
        (sb-ext:process-kill process 9)))
    (sb-ext:process-close process)))

(defun %spawn-lsp-child (project-root)
  "Spawn a child SBCL running alive-lsp. Returns a connected LSP-CLIENT or NIL.
Reads the [STARTING] port from stdout under *lsp-startup-timeout*.
Returns NIL immediately when DSMR_ALIVE_LSP_DIR is unset — spawn requires a
configured alive-lsp source tree; the operator must set DSMR_ALIVE_LSP_DIR."
  (unless *alive-lsp-dir*
    (log-event :warn "lsp.client.spawn-skipped"
               "reason" "DSMR_ALIVE_LSP_DIR not set; spawn disabled")
    (return-from %spawn-lsp-child nil))
  (let ((sbcl-args (%build-lsp-sbcl-args)))
    (unless sbcl-args
      (return-from %spawn-lsp-child nil))
    (let ((sbcl-path (%find-sbcl-path))
          (root-str  (namestring project-root)))
      (log-event :info "lsp.client.spawning" "root" root-str)
      (let ((process nil))
        (handler-case
            (progn
              (setf process
                    (sb-ext:run-program sbcl-path sbcl-args
                                        :output :stream
                                        :error  :stream
                                        :wait   nil
                                        :search t))
              ;; Read back the ephemeral port under the startup timeout.
              (let ((port
                      (handler-case
                          (sb-ext:with-timeout *lsp-startup-timeout*
                            (%parse-lsp-started-line
                             (sb-ext:process-output process)))
                        (sb-ext:timeout ()
                          (log-event :warn "lsp.client.spawn-timeout"
                                     "root" root-str
                                     "timeout" *lsp-startup-timeout*)
                          nil)
                        (error (e)
                          (log-event :warn "lsp.client.spawn-readback-error"
                                     "root" root-str
                                     "error" (princ-to-string e))
                          nil))))
                (unless port
                  (%kill-spawned-process process)
                  (return-from %spawn-lsp-child nil))
                ;; Drain stderr in the background.
                (%start-stderr-drain process root-str)
                ;; Connect to the ephemeral port.
                (let ((client (connect-lsp-client "127.0.0.1" port
                                                  :project-root project-root)))
                  (unless client
                    (log-event :warn "lsp.client.spawn-connect-failed"
                               "root" root-str "port" port)
                    (%kill-spawned-process process)
                    (return-from %spawn-lsp-child nil))
                  ;; Mark as spawned (not attached) and store the process handle.
                  (setf (lsp-client-attached-p   client) nil
                        (lsp-client-process-info client) process)
                  (log-event :info "lsp.client.spawned"
                             "root" root-str "port" port)
                  client)))
          (error (e)
            (log-event :warn "lsp.client.spawn-error"
                       "root" root-str "error" (princ-to-string e))
            (when process
              (%kill-spawned-process process))
            nil))))))

;;; ---------------------------------------------------------------------------
;;; Attach-else-spawn + registry (D-07 / D-09)
;;; ---------------------------------------------------------------------------

(defun ensure-lsp-client (project-root)
  "Return the cached LSP client for PROJECT-ROOT, creating one if necessary.
Strategy (attach-else-spawn):
  1. Check the registry under *lsp-registry-lock*.
  2. If a live client exists, return it.
  3. Acquire the per-root connecting lock so only one thread attaches/spawns
     per root at a time (prevents duplicate initialize handshakes).
  4. Re-check the registry under the connecting lock (second caller finds
     the first caller's result after the lock is released).
  5. Probe 127.0.0.1:*lsp-attach-port* for an existing alive-lsp.
     On success: cache as attached (attached-p T).
  6. On probe failure: spawn a child alive-lsp, cache as spawned (attached-p NIL).
Returns NIL when both attach and spawn fail."
  (let ((root-str (namestring project-root)))
    ;; Fast path: check the registry (avoids the connecting lock on the common case).
    (let ((cached
            (with-lock-held (*lsp-registry-lock*)
              (let ((c (gethash root-str *lsp-registry*)))
                (when (and c (lsp-client-connected-p c)) c)))))
      (when cached (return-from ensure-lsp-client cached)))
    ;; Slow path: hold the per-root connecting lock so concurrent callers for
    ;; the same root do not both attempt attach/spawn simultaneously.
    (with-lock-held ((%connecting-lock-for-root root-str))
      ;; Re-check inside the connecting lock: a concurrent caller may have
      ;; already established and registered a client while we waited.
      (let ((cached
              (with-lock-held (*lsp-registry-lock*)
                (let ((c (gethash root-str *lsp-registry*)))
                  (when (and c (lsp-client-connected-p c)) c)))))
        (when cached (return-from ensure-lsp-client cached)))
      ;; Neither attach nor spawn has succeeded yet for this root.
      (let ((client
              (or (let ((c (connect-lsp-client *lsp-attach-host* *lsp-attach-port*
                                               :project-root project-root)))
                    (when c
                      (log-event :info "lsp.client.attached"
                                 "root" root-str "port" *lsp-attach-port*)
                      c))
                  (%spawn-lsp-child project-root))))
        (when client
          (with-lock-held (*lsp-registry-lock*)
            (setf (lsp-client-project-root client) project-root)
            (setf (gethash root-str *lsp-registry*) client))
          client)))))

;;; ---------------------------------------------------------------------------
;;; Idle-eviction sweeper (adapted from http.lisp %session-cleanup-loop)
;;; ---------------------------------------------------------------------------

(defvar *lsp-cleanup-thread* nil
  "Background idle-eviction sweep thread, or NIL when stopped.")

(defvar *lsp-cleanup-running* nil
  "T while the LSP eviction loop is running.")

(defun %lsp-cleanup-loop ()
  "Periodically evict idle LSP clients from the registry.
Mirrors http.lisp %session-cleanup-loop: 100ms sub-sleeps so shutdown is
observed within ~100ms, active-requests guard, eviction outside the registry
lock."
  (loop while *lsp-cleanup-running*
        do (loop repeat (max 1 (* 10 *lsp-cleanup-interval*))
                 while *lsp-cleanup-running*
                 do (sleep 1/10))
           (when *lsp-cleanup-running*
             (handler-case
                 (let ((expired nil)
                       (now (get-universal-time)))
                   ;; Identify expired clients under the registry lock.
                   (with-lock-held (*lsp-registry-lock*)
                     (maphash
                      (lambda (root client)
                        (let ((idle (- now (lsp-client-last-active client))))
                          (when (> idle *lsp-idle-timeout*)
                            ;; Check active-requests under its own lock.
                            (let ((active
                                    (with-lock-held ((lsp-client-active-req-lock client))
                                      (lsp-client-active-requests client))))
                              (when (zerop active)
                                (push (cons root client) expired))))))
                      *lsp-registry*)
                     ;; Remove from registry while we still hold the lock.
                     (dolist (pair expired)
                       (remhash (car pair) *lsp-registry*)))
                   ;; Evict outside the lock.
                   (dolist (pair expired)
                     (let ((root-str (car pair))
                           (client   (cdr pair)))
                       (ignore-errors (%evict-lsp-client client root-str))
                       (log-event :info "lsp.client.idle-evicted"
                                  "root" root-str))))
               (error (e)
                 (log-event :error "lsp.cleanup.error"
                            "error" (princ-to-string e)))))))

(defun start-lsp-cleanup ()
  "Start the background LSP idle-eviction sweep thread."
  (setf *lsp-cleanup-running* t
        *lsp-cleanup-thread*
        (make-thread #'%lsp-cleanup-loop
                     :name "dsmr-lsp-cleanup")))

(defun stop-lsp-cleanup ()
  "Stop the background LSP idle-eviction sweep thread."
  (setf *lsp-cleanup-running* nil)
  (when (and *lsp-cleanup-thread*
             (thread-alive-p *lsp-cleanup-thread*))
    (handler-case
        (sb-ext:with-timeout 3
          (join-thread *lsp-cleanup-thread*))
      (error () nil)))
  (setf *lsp-cleanup-thread* nil))
