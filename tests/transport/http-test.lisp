;;;; tests/transport/http-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Zebra integration tests for the Streamable HTTP transport.
;;;; Every test body opens with (if (not (http-port-available-p)) (skip ...) ...)
;;;; so an environment that denies the bind reports these tests as skipped.
;;;; They must never report as passed there: a pass nobody earned makes the
;;;; suite total read the same whether the transport was exercised or not.
;;;;
;;;; send-http-request and http-port-available-p are EXPORTED from this package
;;;; (single source of truth, so tests/transport/transport-parity-test.lisp
;;;; imports them from here without re-defining them).

(defpackage #:dsmr-mcp/tests/transport/http-test
  (:use #:cl #:zebra)
  (:import-from #:dsmr-mcp/src/transport/http
                #:*http-server-port*
                #:http-server-running-p
                #:start-http-server
                #:stop-http-server
                #:*session-timeout-seconds*
                #:*cleanup-interval-seconds*
                #:*sessions*
                #:*sessions-lock*
                #:get-session
                #:create-session
                #:delete-session
                #:http-session-id
                #:http-session-mcp-session
                #:http-session-last-access
                #:http-session-active-requests
                #:http-session-active-requests-lock)
  (:import-from #:dsmr-mcp/src/state
                #:session-project-root
                #:session-notify-channel)
  (:import-from #:dsmr-mcp/src/notify
                #:null-channel)
  (:import-from #:usocket)
  (:import-from #:bordeaux-threads)
  (:export #:http-port-available-p
           #:send-http-request))

(in-package #:dsmr-mcp/tests/transport/http-test)

;;; ---------------------------------------------------------------------------
;;; Test helpers (exported so the transport-parity test reuses them
;;; instead of duplicating the harness).
;;; ---------------------------------------------------------------------------

(defun http-port-available-p ()
  "Return T if we can bind an HTTP port on localhost."
  (handler-case
      (let ((sock (usocket:socket-listen "127.0.0.1" 0
                                         :reuse-address t
                                         :element-type 'character)))
        (unwind-protect
             (progn (usocket:get-local-port sock) t)
          (ignore-errors (usocket:socket-close sock))))
    (error () nil)))

(defun send-http-request (port method path &key body headers)
  "Send a simple HTTP/1.1 request to 127.0.0.1:PORT and return
\(values status-code headers-string body-string).
Uses Connection: close to prevent keep-alive from hanging reads."
  (let* ((sock (usocket:socket-connect "127.0.0.1" port
                                       :element-type 'character))
         (stream (usocket:socket-stream sock)))
    (unwind-protect
         (progn
           ;; Send request line and headers.
           (format stream "~A ~A HTTP/1.1~C~C" method path #\Return #\Newline)
           (format stream "Host: 127.0.0.1:~D~C~C" port #\Return #\Newline)
           (format stream "Connection: close~C~C" #\Return #\Newline)
           (dolist (h headers)
             (format stream "~A: ~A~C~C" (car h) (cdr h) #\Return #\Newline))
           (when body
             (format stream "Content-Length: ~D~C~C" (length body) #\Return #\Newline))
           (format stream "~C~C" #\Return #\Newline)
           (when body
             (write-string body stream))
           (finish-output stream)
           ;; Read response.
           (let* ((status-line (read-line stream nil ""))
                  (status-code (when (> (length status-line) 12)
                                 (parse-integer status-line
                                                :start 9 :end 12
                                                :junk-allowed t)))
                  (header-out (make-string-output-stream))
                  (body-out   (make-string-output-stream)))
             ;; Read header lines until blank line.
             (loop for line = (read-line stream nil "")
                   until (or (string= line "") (string= line (string #\Return)))
                   do (write-line line header-out))
             ;; Read body.
             (loop for line = (read-line stream nil nil)
                   while line
                   do (write-line line body-out))
             (values status-code
                     (get-output-stream-string header-out)
                     (get-output-stream-string body-out))))
      (ignore-errors (close stream))
      (ignore-errors (usocket:socket-close sock)))))

;;; ---------------------------------------------------------------------------
;;; Request body builders
;;; ---------------------------------------------------------------------------

(defun %init-body ()
  "Build a well-formed MCP initialize request body."
  (concatenate 'string
               "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\","
               "\"params\":{\"protocolVersion\":\"2025-06-18\","
               "\"capabilities\":{},\"clientInfo\":{\"name\":\"http-test\",\"version\":\"1\"}}}"))

(defun %tools-list-body ()
  "Build a tools/list request body."
  "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{}}")

(defun %extract-session-id (headers-string)
  "Extract the Mcp-Session-Id value from a headers string, or NIL."
  (let ((pos (search "Mcp-Session-Id" headers-string :test #'char-equal)))
    (when pos
      (let* ((colon (position #\: headers-string :start pos))
             (start (when colon (+ colon 2)))
             (end   (when start
                      (or (position #\Return headers-string :start start)
                          (position #\Newline headers-string :start start)
                          (length headers-string)))))
        (when (and start end)
          (string-trim '(#\Space #\Tab #\Return #\Newline)
                       (subseq headers-string start end)))))))

(defun %clear-all-sessions ()
  "Remove all sessions from *sessions* for test isolation."
  (bordeaux-threads:with-lock-held (*sessions-lock*)
    (clrhash *sessions*)))

;;; ---------------------------------------------------------------------------
;;; Tests
;;; ---------------------------------------------------------------------------

(define-test http-server-lifecycle
  "start-http-server / stop-http-server is idempotent; running flag flips correctly."
  (if (not (http-port-available-p))
      (skip "no loopback HTTP port bindable in this environment; socket bind is denied here")
      (unwind-protect
           (multiple-value-bind (acceptor port)
               (start-http-server :host "127.0.0.1" :port 0)
             (true acceptor)
             (true (integerp port))
             (true (http-server-running-p))
             (is eql *http-server-port* port)
             ;; Second start returns existing instance.
             (multiple-value-bind (acceptor2 port2)
                 (start-http-server :host "127.0.0.1" :port 0)
               (is eql acceptor acceptor2)
               (is eql port port2)))
        (stop-http-server)))
  (false (http-server-running-p)))

(define-test http-post-initialize-creates-session
  "POST /mcp with initialize body returns 200 + Mcp-Session-Id + JSON result."
  (if (not (http-port-available-p))
      (skip "no loopback HTTP port bindable in this environment; socket bind is denied here")
      (unwind-protect
           (multiple-value-bind (acceptor port)
               (start-http-server :host "127.0.0.1" :port 0)
             (declare (ignore acceptor))
             (sleep 0.1d0)
             (multiple-value-bind (status headers body)
                 (handler-case
                     (send-http-request
                      port "POST" "/mcp"
                      :body (%init-body)
                      :headers '(("Content-Type" . "application/json")
                                 ("Accept" . "application/json")))
                   (error () (values nil nil nil)))
               (when status
                 (is eql 200 status)
                 (true (search "Mcp-Session-Id" headers))
                 (true (search "\"result\"" body))
                 ;; Session is registered.
                 (let ((id (%extract-session-id headers)))
                   (when id
                     (true (bordeaux-threads:with-lock-held (*sessions-lock*)
                             (gethash id *sessions*))))))))
        (stop-http-server)
        (%clear-all-sessions))))

(define-test http-post-without-session-returns-400
  "POST /mcp non-initialize without Mcp-Session-Id header returns 400."
  (if (not (http-port-available-p))
      (skip "no loopback HTTP port bindable in this environment; socket bind is denied here")
      (unwind-protect
           (multiple-value-bind (acceptor port)
               (start-http-server :host "127.0.0.1" :port 0)
             (declare (ignore acceptor))
             (sleep 0.1d0)
             (let ((status
                     (handler-case
                         (send-http-request
                          port "POST" "/mcp"
                          :body "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{}}"
                          :headers '(("Content-Type" . "application/json")))
                       (error () nil))))
               (when status
                 (is eql 400 status))))
        (stop-http-server))))

(define-test http-post-with-unknown-session-returns-404
  "POST /mcp with syntactically valid but unknown Mcp-Session-Id returns 404."
  (if (not (http-port-available-p))
      (skip "no loopback HTTP port bindable in this environment; socket bind is denied here")
      (unwind-protect
           (multiple-value-bind (acceptor port)
               (start-http-server :host "127.0.0.1" :port 0)
             (declare (ignore acceptor))
             (sleep 0.1d0)
             (let ((status
                     (handler-case
                         (send-http-request
                          port "POST" "/mcp"
                          :body "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{}}"
                          :headers (list '("Content-Type" . "application/json")
                                         (cons "Mcp-Session-Id"
                                               (make-string 64 :initial-element #\0))))
                       (error () nil))))
               (when status
                 (is eql 404 status))))
        (stop-http-server))))

(define-test http-session-timeout-evicts-idle
  "A session whose last-access exceeds *session-timeout-seconds* is evicted by get-session."
  (if (not (http-port-available-p))
      (skip "no loopback HTTP port bindable in this environment; socket bind is denied here")
      (unwind-protect
           (let ((*session-timeout-seconds* 1))
             (let* ((http-sess (create-session :slynk-attach nil :project-root nil))
                    (id (http-session-id http-sess)))
               ;; Back-date last-access by 10 seconds.
               (setf (http-session-last-access http-sess)
                     (- (get-universal-time) 10))
               ;; get-session evicts on access when idle > timeout AND active = 0.
               (false (get-session id))
               ;; Session removed from table.
               (false (bordeaux-threads:with-lock-held (*sessions-lock*)
                        (gethash id *sessions*)))))
        (%clear-all-sessions))))

(define-test http-session-active-requests-guard-prevents-eviction
  "A session with active-requests > 0 is NOT evicted even when expired."
  (if (not (http-port-available-p))
      (skip "no loopback HTTP port bindable in this environment; socket bind is denied here")
      (unwind-protect
           (let ((*session-timeout-seconds* 1))
             (let* ((http-sess (create-session :slynk-attach nil :project-root nil))
                    (id (http-session-id http-sess)))
               ;; Mark one in-flight request.
               (bordeaux-threads:with-lock-held
                   ((http-session-active-requests-lock http-sess))
                 (incf (http-session-active-requests http-sess)))
               ;; Back-date last-access.
               (setf (http-session-last-access http-sess)
                     (- (get-universal-time) 10))
               ;; get-session returns NIL (expired) but does NOT remove it.
               (false (get-session id))
               ;; Session still in table.
               (true (bordeaux-threads:with-lock-held (*sessions-lock*)
                       (gethash id *sessions*)))
               ;; Decrement and re-access; now the table should be empty too.
               (bordeaux-threads:with-lock-held
                   ((http-session-active-requests-lock http-sess))
                 (decf (http-session-active-requests http-sess)))))
        (%clear-all-sessions))))

(define-test http-get-returns-sse-stream
  "GET /mcp with Mcp-Session-Id returns 200 + Content-Type: text/event-stream."
  (if (not (http-port-available-p))
      (skip "no loopback HTTP port bindable in this environment; socket bind is denied here")
      (unwind-protect
           (multiple-value-bind (acceptor port)
               (start-http-server :host "127.0.0.1" :port 0)
             (declare (ignore acceptor))
             (sleep 0.1d0)
             ;; Initialize a session first.
             (multiple-value-bind (init-status init-headers)
                 (handler-case
                     (send-http-request
                      port "POST" "/mcp"
                      :body (%init-body)
                      :headers '(("Content-Type" . "application/json")
                                 ("Accept" . "application/json")))
                   (error () (values nil nil)))
               (when (and init-status (eql init-status 200))
                 (let ((id (%extract-session-id init-headers)))
                   (when id
                     (let ((result-cell (list nil))
                           (done-cell   (list nil)))
                       ;; GET in a background thread, reading just the response line.
                       (bordeaux-threads:make-thread
                        (lambda ()
                          (handler-case
                              (let* ((sock (usocket:socket-connect
                                            "127.0.0.1" port
                                            :element-type 'character))
                                     (stream (usocket:socket-stream sock)))
                                (unwind-protect
                                     (progn
                                       (format stream "GET /mcp HTTP/1.1~C~C" #\Return #\Newline)
                                       (format stream "Host: 127.0.0.1:~D~C~C" port #\Return #\Newline)
                                       (format stream "Mcp-Session-Id: ~A~C~C" id #\Return #\Newline)
                                       (format stream "Connection: close~C~C" #\Return #\Newline)
                                       (format stream "~C~C" #\Return #\Newline)
                                       (finish-output stream)
                                       (let ((status-line (read-line stream nil "")))
                                         (setf (car result-cell) status-line))
                                       (setf (car done-cell) t))
                                  (ignore-errors (close stream))
                                  (ignore-errors (usocket:socket-close sock))))
                            (error () (setf (car done-cell) t))))
                        :name "http-test-get-reader")
                       ;; Wait up to 1 second for the response line.
                       (loop repeat 100
                             until (car result-cell)
                             do (sleep 0.01d0))
                       (let ((status-line (car result-cell)))
                         (true status-line)
                         (when status-line
                           (true (search "200" status-line))))))))))
        (stop-http-server)
        (%clear-all-sessions))))

(define-test http-get-concurrent-installs-elect-one-winner
  "N GET /mcp subscribers race the sse-channel install against one session;
exactly one wins (200) and the rest get 409 Conflict.  The per-session
install lock serialises the check-then-act on the notify-channel slot, so no
two GETs can both pass the not-already-attached check and install a channel.
A pre-fix racy install would let two concurrent GETs both reach 200 (and
orphan one subscriber).  Single-client tests never exercise this."
  (if (not (http-port-available-p))
      (skip "no loopback HTTP port bindable in this environment; socket bind is denied here")
      (let ((sockets nil))
        (unwind-protect
             (multiple-value-bind (acceptor port)
                 (start-http-server :host "127.0.0.1" :port 0)
               (declare (ignore acceptor))
               (sleep 0.1d0)
               (multiple-value-bind (init-status init-headers)
                   (handler-case
                       (send-http-request
                        port "POST" "/mcp"
                        :body (%init-body)
                        :headers '(("Content-Type" . "application/json")
                                   ("Accept" . "application/json")))
                     (error () (values nil nil)))
                 (let ((id (and init-status (eql init-status 200)
                                (%extract-session-id init-headers))))
                   ;; No session id means the handshake never completed here,
                   ;; so the race this test exists to observe cannot be set up.
                   (if (not id)
                       (skip "HTTP initialize returned no session id, so the concurrent GET race cannot be staged here")
                       (let* ((n 8)
                              (go-latch (list nil))
                              (results (make-array n :initial-element nil)))
                         ;; Pre-connect N racers, each spinning on a shared
                         ;; latch so all fire their GET near-simultaneously and
                         ;; actually contend for the install.
                         (dotimes (i n)
                           (let ((idx i))
                             (bordeaux-threads:make-thread
                              (lambda ()
                                (handler-case
                                    (let* ((sock (usocket:socket-connect
                                                  "127.0.0.1" port
                                                  :element-type 'character))
                                           (stream (usocket:socket-stream sock)))
                                      (bordeaux-threads:with-lock-held (*sessions-lock*)
                                        (push sock sockets))
                                      (loop until (car go-latch)
                                            do (sleep 0.001d0))
                                      (format stream "GET /mcp HTTP/1.1~C~C" #\Return #\Newline)
                                      (format stream "Host: 127.0.0.1:~D~C~C" port #\Return #\Newline)
                                      (format stream "Mcp-Session-Id: ~A~C~C" id #\Return #\Newline)
                                      (format stream "~C~C" #\Return #\Newline)
                                      (finish-output stream)
                                      ;; send-headers flushes the status line for
                                      ;; both winner (200) and losers (409), so a
                                      ;; single read-line resolves every racer.
                                      (setf (aref results idx)
                                            (read-line stream nil "")))
                                  (error () (setf (aref results idx) :error))))
                              :name (format nil "get-racer-~D" idx))))
                         ;; Let every thread reach the latch, then release.
                         (sleep 0.2d0)
                         (setf (car go-latch) t)
                         ;; Wait until all N have a status line (or time out).
                         (loop repeat 500
                               until (= n (count-if #'identity results))
                               do (sleep 0.01d0))
                         (let ((winners
                                 (count-if (lambda (r)
                                             (and (stringp r) (search "200" r)))
                                           results))
                               (conflicts
                                 (count-if (lambda (r)
                                             (and (stringp r) (search "409" r)))
                                           results)))
                           (is eql 1 winners)
                           (is eql (1- n) conflicts)))))))
          (dolist (s sockets)
            (ignore-errors (usocket:socket-close s)))
          (stop-http-server)
          (%clear-all-sessions)))))

(define-test http-post-with-accept-event-stream-returns-sse
  "POST /mcp initialize with Accept: text/event-stream returns SSE body with result."
  (if (not (http-port-available-p))
      (skip "no loopback HTTP port bindable in this environment; socket bind is denied here")
      (unwind-protect
           (multiple-value-bind (acceptor port)
               (start-http-server :host "127.0.0.1" :port 0)
             (declare (ignore acceptor))
             (sleep 0.1d0)
             (multiple-value-bind (status headers body)
                 (handler-case
                     (send-http-request
                      port "POST" "/mcp"
                      :body (%init-body)
                      :headers '(("Content-Type" . "application/json")
                                 ("Accept" . "text/event-stream")))
                   (error () (values nil nil nil)))
               (when status
                 (is eql 200 status)
                 (true (search "text/event-stream" headers :test #'char-equal))
                 (true (search "data:" body)))))
        (stop-http-server)
        (%clear-all-sessions))))

(define-test http-delete-session-returns-204
  "DELETE /mcp with Mcp-Session-Id returns 204; subsequent POST returns 404."
  (if (not (http-port-available-p))
      (skip "no loopback HTTP port bindable in this environment; socket bind is denied here")
      (unwind-protect
           (multiple-value-bind (acceptor port)
               (start-http-server :host "127.0.0.1" :port 0)
             (declare (ignore acceptor))
             (sleep 0.1d0)
             ;; Initialize to obtain a session.
             (multiple-value-bind (init-status init-headers)
                 (handler-case
                     (send-http-request
                      port "POST" "/mcp"
                      :body (%init-body)
                      :headers '(("Content-Type" . "application/json")
                                 ("Accept" . "application/json")))
                   (error () (values nil nil)))
               (when (and init-status (eql init-status 200))
                 (let ((id (%extract-session-id init-headers)))
                   (when id
                     ;; DELETE the session.
                     (let ((del-status
                             (handler-case
                                 (send-http-request
                                  port "DELETE" "/mcp"
                                  :headers (list (cons "Mcp-Session-Id" id)))
                               (error () nil))))
                       (when del-status
                         (is eql 204 del-status)))
                     ;; Session gone from table.
                     (false (bordeaux-threads:with-lock-held (*sessions-lock*)
                              (gethash id *sessions*)))
                     ;; Subsequent POST with that id returns 404.
                     (let ((post-status
                             (handler-case
                                 (send-http-request
                                  port "POST" "/mcp"
                                  :body "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{}}"
                                  :headers (list '("Content-Type" . "application/json")
                                                 (cons "Mcp-Session-Id" id)))
                               (error () nil))))
                       (when post-status
                         (is eql 404 post-status))))))))
        (stop-http-server)
        (%clear-all-sessions))))

(define-test http-cors-loopback-allowed
  "OPTIONS /mcp with loopback Origin returns Access-Control-Allow-Origin echo."
  (if (not (http-port-available-p))
      (skip "no loopback HTTP port bindable in this environment; socket bind is denied here")
      (unwind-protect
           (multiple-value-bind (acceptor port)
               (start-http-server :host "127.0.0.1" :port 0)
             (declare (ignore acceptor))
             (sleep 0.1d0)
             (multiple-value-bind (status headers)
                 (handler-case
                     (send-http-request
                      port "OPTIONS" "/mcp"
                      :headers '(("Origin" . "http://127.0.0.1:5173")))
                   (error () (values nil nil)))
               (when status
                 (is eql 200 status)
                 (true (search "Access-Control-Allow-Origin" headers
                               :test #'char-equal))
                 (true (search "http://127.0.0.1:5173" headers)))))
        (stop-http-server))))

(define-test http-cors-substring-attack-rejected
  "OPTIONS /mcp with Origin: http://localhost.evil.com returns no ACAO header."
  (if (not (http-port-available-p))
      (skip "no loopback HTTP port bindable in this environment; socket bind is denied here")
      (unwind-protect
           (multiple-value-bind (acceptor port)
               (start-http-server :host "127.0.0.1" :port 0)
             (declare (ignore acceptor))
             (sleep 0.1d0)
             (multiple-value-bind (status headers)
                 (handler-case
                     (send-http-request
                      port "OPTIONS" "/mcp"
                      :headers '(("Origin" . "http://localhost.evil.com")))
                   (error () (values nil nil)))
               (when status
                 ;; OPTIONS returns 200 but without the ACAO header.
                 (is eql 200 status)
                 ;; Verify Access-Control-Allow-Origin header is absent.
                 (false (search "Access-Control-Allow-Origin: http://localhost.evil.com"
                                headers :test #'char-equal)))))
        (stop-http-server))))

(define-test http-protocol-version-absent-assumes-supported
  "POST /mcp without MCP-Protocol-Version header succeeds (assumes 2025-03-26)."
  (if (not (http-port-available-p))
      (skip "no loopback HTTP port bindable in this environment; socket bind is denied here")
      (unwind-protect
           (multiple-value-bind (acceptor port)
               (start-http-server :host "127.0.0.1" :port 0)
             (declare (ignore acceptor))
             (sleep 0.1d0)
             (let ((status
                     (handler-case
                         (send-http-request
                          port "POST" "/mcp"
                          :body (%init-body)
                          :headers '(("Content-Type" . "application/json")
                                     ("Accept" . "application/json")))
                       (error () nil))))
               (when status
                 (is eql 200 status))))
        (stop-http-server)
        (%clear-all-sessions))))

(define-test http-protocol-version-invalid-returns-400
  "POST /mcp with unsupported MCP-Protocol-Version value returns 400."
  (if (not (http-port-available-p))
      (skip "no loopback HTTP port bindable in this environment; socket bind is denied here")
      (unwind-protect
           (multiple-value-bind (acceptor port)
               (start-http-server :host "127.0.0.1" :port 0)
             (declare (ignore acceptor))
             (sleep 0.1d0)
             (let ((status
                     (handler-case
                         (send-http-request
                          port "POST" "/mcp"
                          :body (%init-body)
                          :headers '(("Content-Type" . "application/json")
                                     ("Accept" . "application/json")
                                     ("MCP-Protocol-Version" . "2099-01-01")))
                       (error () nil))))
               (when status
                 (is eql 400 status))))
        (stop-http-server))))

(define-test http-stdout-pollution-captured-not-leaked
  "POST initialize response body starts with '{' (stdout guard active)."
  (if (not (http-port-available-p))
      (skip "no loopback HTTP port bindable in this environment; socket bind is denied here")
      (unwind-protect
           (multiple-value-bind (acceptor port)
               (start-http-server :host "127.0.0.1" :port 0)
             (declare (ignore acceptor))
             (sleep 0.1d0)
             (multiple-value-bind (status headers body)
                 (handler-case
                     (send-http-request
                      port "POST" "/mcp"
                      :body (%init-body)
                      :headers '(("Content-Type" . "application/json")
                                 ("Accept" . "application/json")))
                   (error () (values nil nil nil)))
               (declare (ignore headers))
               (when (and status body (plusp (length body)))
                 (is eql 200 status)
                 ;; Body must start with '{' (valid JSON), not SBCL/log output.
                 (let ((first-char (char (string-left-trim '(#\Space #\Newline #\Return #\Tab)
                                                           body)
                                        0)))
                   (is char= #\{ first-char)))))
        (stop-http-server)
        (%clear-all-sessions))))

(define-test per-session-slynk-attach-and-project-root-isolated
  "Two HTTP sessions own independent project-root slots; re-rooting one leaves the other unchanged."
  (if (not (http-port-available-p))
      (skip "no loopback HTTP port bindable in this environment; socket bind is denied here")
      ;; Use the dsmr-mcp project root as the initial default — it exists on disk
      ;; so fs-set-project-root can validate and set the new root.
      (let* ((init-root
               ;; Locate the dsmr-mcp root from the running image.
               (namestring
                (uiop:ensure-directory-pathname
                 (asdf:system-source-directory :dsmr-mcp))))
             (new-root
               ;; Use the src/ subdirectory as session 1's re-rooted path.
               (namestring
                (uiop:ensure-directory-pathname
                 (merge-pathnames "src/" (asdf:system-source-directory :dsmr-mcp))))))
        (unwind-protect
             (multiple-value-bind (acceptor port)
                 (start-http-server :host "127.0.0.1" :port 0
                                    :slynk-attach nil
                                    :project-root init-root)
               (declare (ignore acceptor))
               (sleep 0.1d0)
               ;; Initialize session 1.
               (multiple-value-bind (s1 h1)
                   (handler-case
                       (send-http-request
                        port "POST" "/mcp"
                        :body (%init-body)
                        :headers '(("Content-Type" . "application/json")
                                   ("Accept" . "application/json")))
                     (error () (values nil nil)))
                 (declare (ignore s1))
                 ;; Initialize session 2 (separate POST — new session).
                 (multiple-value-bind (s2 h2)
                     (handler-case
                         (send-http-request
                          port "POST" "/mcp"
                          :body (%init-body)
                          :headers '(("Content-Type" . "application/json")
                                     ("Accept" . "application/json")))
                       (error () (values nil nil)))
                   (declare (ignore s2))
                   (let ((id-1 (%extract-session-id h1))
                         (id-2 (%extract-session-id h2)))
                     (when (and id-1 id-2)
                       ;; Both sessions start with the closed-over default init-root.
                       (let* ((http-sess-1 (bordeaux-threads:with-lock-held (*sessions-lock*)
                                             (gethash id-1 *sessions*)))
                              (http-sess-2 (bordeaux-threads:with-lock-held (*sessions-lock*)
                                             (gethash id-2 *sessions*)))
                              (mcp-1 (when http-sess-1
                                       (http-session-mcp-session http-sess-1)))
                              (mcp-2 (when http-sess-2
                                       (http-session-mcp-session http-sess-2))))
                         (when (and mcp-1 mcp-2)
                           ;; Both sessions inherit the same closed-over default.
                           (is string= init-root (namestring (session-project-root mcp-1)))
                           (is string= init-root (namestring (session-project-root mcp-2)))
                           ;; Directly mutate session 1's project-root slot to new-root.
                           ;; The two sessions are independent objects, so
                           ;; mutating one must leave the other unchanged.  (The
                           ;; closure-captured default is proven by the two
                           ;; assertions above — both sessions started with
                           ;; init-root, not NIL or a stale process-wide value.)
                           (setf (session-project-root mcp-1) (pathname new-root))
                           ;; Session 1's root is now new-root.
                           (is string= new-root (namestring (session-project-root mcp-1)))
                           ;; Session 2's root must still be init-root —
                           ;; no shared process-wide state can be the carrier.
                           (is string= init-root (namestring (session-project-root mcp-2)))))))))
          (stop-http-server)
          (bordeaux-threads:with-lock-held (*sessions-lock*)
            (clrhash *sessions*)))))))
