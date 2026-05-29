;;;; src/transport/http.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Streamable HTTP transport (MCP 2025-03-26 / 2025-06-18).
;;;; Delivers: POST /mcp (JSON-only and SSE response modes), GET /mcp (long-lived
;;;; SSE notification stream), DELETE /mcp (session teardown), OPTIONS /mcp (CORS
;;;; preflight).
;;;;
;;;; Per-session slynk-attach and project-root are closure-captured from
;;;; serve-http's keyword args and flowed into every create-session call via
;;;; the Hunchentoot request-handler closures — no process-wide special holds
;;;; either value, so fs-set-project-root in one session never reaches another.
;;;;
;;;; Auth posture: no Bearer-token / CORS-token / client-certificate — the
;;;; loopback origin check is the entire trust boundary.
;;;; CORS: loopback-only allow-list (%loopback-origin-p, ported verbatim from
;;;; cl-mcp/src/http.lisp lines 399-416).
;;;; Session eviction: 1h idle, 1-min sweep, active-requests guard.
;;;;
;;;; Ported and adapted from cl-mcp/src/http.lisp (MIT) under AGPL:
;;;;   - defstruct http-session → defclass (project CLOS convention)
;;;;   - make-state → make-session with :slynk-attach :project-root from closure
;;;;   - release-session → uiop:symbol-call detach-session
;;;;   - yason:encode/parse → jzon:stringify/parse
;;;;   - Bearer-token auth removed entirely
;;;;   - *session-timeout-seconds* 86400 → 3600 to bound the per-session
;;;;     Slynk client lifetime
;;;;   - *cleanup-interval-seconds* 300 → 60 for tighter eviction cadence
;;;;   - handle-mcp-get 405 stub → real SSE implementation
;;;;   - POST SSE path added

(defpackage #:dsmr-mcp/src/transport/http
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/state
                #:make-session
                #:session-id
                #:session-notify-channel
                #:session-slynk-attach
                #:session-project-root
                #:*current-session-id*)
  (:import-from #:dsmr-mcp/src/protocol
                #:process-json-line)
  (:import-from #:dsmr-mcp/src/log
                #:log-event)
  (:import-from #:dsmr-mcp/src/notify
                #:null-channel
                #:sse-channel
                #:sse-channel-stream
                #:sse-channel-lock
                #:sse-channel-cv
                #:sse-channel-queue
                #:sse-channel-done-p
                #:%write-sse-event
                #:%drain-sse-queue)
  (:import-from #:dsmr-mcp/src/transport/stdio
                #:%dispatch-with-stdout-guard)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:make-ht
                #:rpc-error)
  (:import-from #:bordeaux-threads
                #:make-lock
                #:with-lock-held
                #:make-thread
                #:make-condition-variable
                #:condition-wait
                #:condition-notify)
  (:import-from #:hunchentoot)
  (:import-from #:flexi-streams
                #:make-flexi-stream)
  (:import-from #:com.inuoe.jzon)
  (:export #:serve-http
           #:start-http-server
           #:stop-http-server
           #:http-server-running-p
           #:*http-server*
           #:*http-server-port*
           #:*http-server-thread*
           #:*sessions*
           #:*sessions-lock*
           #:*session-timeout-seconds*
           #:*cleanup-interval-seconds*
           #:http-session
           #:http-session-id
           #:http-session-mcp-session
           #:http-session-created-at
           #:http-session-last-access
           #:http-session-active-requests
           #:http-session-active-requests-lock
           #:get-session
           #:create-session
           #:delete-session
           #:%loopback-origin-p))

(in-package #:dsmr-mcp/src/transport/http)

;;; ---------------------------------------------------------------------------
;;; Process-level specials
;;; ---------------------------------------------------------------------------

(defparameter *http-server* nil
  "The running Hunchentoot mcp-acceptor instance, or NIL when not started.")

(defparameter *http-server-port* nil
  "Resolved port of the currently running HTTP server.
Set to the actual bound port (even when 0 was requested) by START-HTTP-SERVER.
NIL when no server is running.")

(defparameter *http-server-thread* nil
  "Background thread started by START-HTTP-SERVER, if any.
NIL when serve-http was called in the foreground (blocking mode).")

(defvar *sessions* (make-hash-table :test 'equal)
  "Hash-table mapping Mcp-Session-Id string to HTTP-SESSION.
Protected by *SESSIONS-LOCK*.")

(defvar *sessions-lock* (bordeaux-threads:make-lock "http-sessions-lock")
  "Lock protecting *SESSIONS* for thread-safe read/write.")

(defparameter *session-timeout-seconds* 3600
  "Seconds a session may be idle before eviction.
Default 3600 (1 hour) — tighter than cl-mcp's 24h because each idle session
holds a live Slynk client connection into the developer's image.
Set to NIL to disable timeout (not recommended).
Operator-tunable via DSMR_HTTP_SESSION_TIMEOUT (resolved in src/run.lisp).")

(defparameter *cleanup-interval-seconds* 60
  "Seconds between session cleanup sweeps.
Default 60 (1 minute). Operator-tunable via DSMR_HTTP_CLEANUP_INTERVAL.")

(defvar *cleanup-thread* nil
  "Background session cleanup thread, or NIL when stopped.")

(defvar *cleanup-running* nil
  "T while the session cleanup loop is active.")

;;; ---------------------------------------------------------------------------
;;; HTTP session class
;;; ---------------------------------------------------------------------------

(defclass http-session ()
  ((id
    :initarg :id
    :reader http-session-id
    :documentation "The Mcp-Session-Id string for this session.
64-char hex, generated by %GENERATE-SESSION-ID at create-session time.")
   (mcp-session
    :initarg :mcp-session
    :reader http-session-mcp-session
    :documentation "The dsmr-mcp session object (carries notify-channel,
tool-instances, session-slynk-attach, session-project-root, etc.).
Created by CREATE-SESSION with the closed-over default-slynk-attach and
default-project-root from serve-http's lexical scope — never from any
process-wide special, so per-session project-root mutations stay
within that session.")
   (created-at
    :initform (get-universal-time)
    :reader http-session-created-at
    :documentation "Universal time when this session was created.")
   (last-access
    :initform (get-universal-time)
    :accessor http-session-last-access
    :documentation "Universal time of the most recent request on this session.
Updated by GET-SESSION on each access.")
   (active-requests
    :initform 0
    :accessor http-session-active-requests
    :documentation "Count of in-flight requests currently being served.
A session with active-requests > 0 is never evicted even when expired,
so a long tool call is not killed mid-flight.")
   (active-requests-lock
    :initform (bordeaux-threads:make-lock "active-requests-lock")
    :reader http-session-active-requests-lock
    :documentation "Per-session lock serialising active-requests mutation."))
  (:documentation "Wrapper around a dsmr-mcp session for HTTP transport.
One HTTP-SESSION is created per POST /mcp initialize request and lives
until DELETE /mcp terminates it or the idle-eviction sweep removes it.
The MCP-SESSION slot holds the dsmr-mcp session object; tools and protocol
handlers access it as a regular session (same API as stdio/TCP)."))

;;; ---------------------------------------------------------------------------
;;; Session ID generation
;;; ---------------------------------------------------------------------------

(defun %generate-session-id ()
  "Generate a random 64-character lowercase hex session ID.
Uses (random (expt 2 256)) for 256 bits of entropy, making spoofing
infeasible for the loopback threat model."
  (format nil "~64,'0x" (random (expt 2 256))))

;;; ---------------------------------------------------------------------------
;;; Session table operations
;;; ---------------------------------------------------------------------------

(defun get-session (session-id)
  "Look up SESSION-ID in *SESSIONS* and return the HTTP-SESSION, or NIL.
Updates HTTP-SESSION-LAST-ACCESS on a successful hit.
An expired session (last-access older than *SESSION-TIMEOUT-SECONDS*) is
evicted and NIL is returned — UNLESS active-requests > 0, in which case
the session remains in the table (its eviction is deferred until after the
in-flight request completes)."
  (let ((result nil)
        (evict-id nil)
        (evict-sess nil))
    (bordeaux-threads:with-lock-held (*sessions-lock*)
      (let ((http-sess (gethash session-id *sessions*)))
        (when http-sess
          (let ((now (get-universal-time)))
            (cond
              ;; Timeout disabled: touch last-access and return.
              ((null *session-timeout-seconds*)
               (setf (http-session-last-access http-sess) now)
               (setf result http-sess))
              ;; Session has exceeded idle timeout.
              ((> (- now (http-session-last-access http-sess))
                  *session-timeout-seconds*)
               ;; Check active-requests under its own lock.
               (let ((active
                       (bordeaux-threads:with-lock-held
                           ((http-session-active-requests-lock http-sess))
                         (http-session-active-requests http-sess))))
                 (when (zerop active)
                   (remhash session-id *sessions*)
                   (setf evict-id session-id
                         evict-sess http-sess))))
              (t
               (setf (http-session-last-access http-sess) now)
               (setf result http-sess)))))))
    ;; Detach the Slynk connection outside the sessions lock to avoid
    ;; holding the lock during potentially blocking cleanup. The session
    ;; has already been removed from *SESSIONS*, so the cleanup sweep
    ;; can never see it — without this branch the Slynk client connection
    ;; cached on the session's repl-eval-tool instance would leak until
    ;; process exit.
    (when evict-sess
      (%wake-sse-subscriber (http-session-mcp-session evict-sess))
      (ignore-errors
       (uiop:symbol-call :dsmr-mcp/src/attach/dispatch :detach-session
                         (http-session-mcp-session evict-sess)))
      (log-event :info "http.session.evicted"
                 "session" evict-id
                 "reason" "idle-expired-on-access"))
    result))

(defun create-session (&key slynk-attach project-root)
  "Create and register a new HTTP-SESSION.
SLYNK-ATTACH and PROJECT-ROOT come from serve-http's closed-over defaults —
they are NEVER read from any process-wide special.
Returns the new HTTP-SESSION."
  (let* ((id (map 'string #'identity (%generate-session-id)))
         (mcp-sess (make-session :id id
                                 :slynk-attach slynk-attach
                                 :project-root project-root))
         (http-sess (make-instance 'http-session
                                   :id id
                                   :mcp-session mcp-sess)))
    (bordeaux-threads:with-lock-held (*sessions-lock*)
      (setf (gethash id *sessions*) http-sess))
    (log-event :info "http.session.created" "session" id)
    http-sess))

(defun %wake-sse-subscriber (mcp-sess)
  "If MCP-SESS currently has an sse-channel installed, mark it done and
notify the condition variable so a GET handler blocked in condition-wait
unblocks and exits.  Safe to call when the channel is a null-channel."
  (let ((channel (session-notify-channel mcp-sess)))
    (when (typep channel 'sse-channel)
      (bordeaux-threads:with-lock-held ((sse-channel-lock channel))
        (setf (sse-channel-done-p channel) t)
        (bordeaux-threads:condition-notify (sse-channel-cv channel))))))

(defun delete-session (session-id)
  "Remove SESSION-ID from *SESSIONS* and close its Slynk connection.
Returns the evicted HTTP-SESSION, or NIL if the session was not found.
Wakes any GET subscriber blocked on the session's sse-channel so the
handler exits instead of parking indefinitely on a dead session."
  (let ((http-sess nil))
    (bordeaux-threads:with-lock-held (*sessions-lock*)
      (setf http-sess (gethash session-id *sessions*))
      (remhash session-id *sessions*))
    (when http-sess
      (%wake-sse-subscriber (http-session-mcp-session http-sess))
      (ignore-errors
       (uiop:symbol-call :dsmr-mcp/src/attach/dispatch :detach-session
                         (http-session-mcp-session http-sess)))
      (log-event :info "http.delete" "session" session-id))
    http-sess))

;;; ---------------------------------------------------------------------------
;;; Session cleanup loop
;;; ---------------------------------------------------------------------------

(defun %session-cleanup-loop ()
  "Periodically sweep *SESSIONS* for idle-expired entries and evict them.
Runs in a background thread until *CLEANUP-RUNNING* becomes NIL.
Uses 1-second sub-sleeps for responsive shutdown.
Sessions with active-requests > 0 are skipped so a tool call in flight
is never killed mid-request."
  (loop while *cleanup-running*
        do (loop repeat (max 1 (ceiling *cleanup-interval-seconds*))
                 while *cleanup-running*
                 do (sleep 1))
           (when *cleanup-running*
             (handler-case
                 (let ((expired-ids nil)
                       (now (get-universal-time)))
                   ;; Identify expired sessions under the lock.
                   (bordeaux-threads:with-lock-held (*sessions-lock*)
                     (when *session-timeout-seconds*
                       (maphash
                        (lambda (id http-sess)
                          (let ((idle (- now (http-session-last-access http-sess))))
                            (when (> idle *session-timeout-seconds*)
                              (let ((active
                                      (bordeaux-threads:with-lock-held
                                          ((http-session-active-requests-lock http-sess))
                                        (http-session-active-requests http-sess))))
                                (if (zerop active)
                                    (push (cons id http-sess) expired-ids)
                                    ;; In-flight: skip eviction so the tool call completes.
                                    nil)))))
                        *sessions*)
                       ;; Remove expired entries under the same lock pass.
                       (dolist (pair expired-ids)
                         (remhash (car pair) *sessions*))))
                   ;; Detach Slynk connections outside the lock.
                   (dolist (pair expired-ids)
                     (let ((id (car pair))
                           (http-sess (cdr pair)))
                       (%wake-sse-subscriber (http-session-mcp-session http-sess))
                       (ignore-errors
                        (uiop:symbol-call :dsmr-mcp/src/attach/dispatch :detach-session
                                          (http-session-mcp-session http-sess)))
                       (log-event :info "http.session.evicted"
                                  "session" id
                                  "idle_seconds" (- now (http-session-last-access http-sess))))))
               (error (e)
                 (log-event :error "http.cleanup.error"
                            "error" (princ-to-string e)))))))

(defun %start-session-cleanup ()
  "Start the background session cleanup thread."
  (setf *cleanup-running* t
        *cleanup-thread*
        (bordeaux-threads:make-thread #'%session-cleanup-loop
                                      :name "dsmr-http-session-cleanup")))

(defun %stop-session-cleanup ()
  "Stop the background session cleanup thread, waiting up to 3 seconds."
  (setf *cleanup-running* nil)
  (when (and *cleanup-thread*
             (bordeaux-threads:thread-alive-p *cleanup-thread*))
    (handler-case
        (sb-ext:with-timeout 3
          (bordeaux-threads:join-thread *cleanup-thread*))
      (error () nil)))
  (setf *cleanup-thread* nil))

;;; ---------------------------------------------------------------------------
;;; CORS validation
;;; ---------------------------------------------------------------------------

(defun %loopback-origin-p (origin)
  "Return T only when ORIGIN is a loopback address.
Validates the character after the hostname to prevent substring attacks
like http://localhost.evil.com being treated as loopback.
Ported verbatim from cl-mcp/src/http.lisp lines 399-416 (the security
invariant — do not simplify this function)."
  (flet ((check-prefix (prefix)
           (let ((len (length prefix)))
             (and (>= (length origin) len)
                  (string-equal origin prefix :end1 len)
                  ;; Character after the prefix must be: end-of-string,
                  ;; a port separator ':', or a path separator '/'.
                  (or (= (length origin) len)
                      (char= (char origin len) #\:)
                      (char= (char origin len) #\/))))))
    (or (check-prefix "http://localhost")
        (check-prefix "https://localhost")
        (check-prefix "http://127.0.0.1")
        (check-prefix "https://127.0.0.1")
        (check-prefix "http://[::1]")
        (check-prefix "https://[::1]"))))

;;; ---------------------------------------------------------------------------
;;; MCP-Protocol-Version header validation
;;; ---------------------------------------------------------------------------

(defparameter %supported-protocol-versions
  '("2025-06-18" "2025-03-26" "2024-11-05")
  "Protocol versions accepted in MCP-Protocol-Version request headers.")

(defun %check-protocol-version-header (request)
  "Return T when the MCP-Protocol-Version header is acceptable.
Absent header is assumed to be 2025-03-26 (spec SHOULD behaviour).
An empty-string header is treated the same as absent so the 400
diagnostic does not echo \"Unsupported MCP-Protocol-Version: \" with
the empty value, which read as a parser bug rather than a client error.
Returns NIL when the header is present, non-empty, and not in the
supported set."
  (let ((v (hunchentoot:header-in :mcp-protocol-version request)))
    (or (null v)
        (and (stringp v) (string= v ""))
        (member v %supported-protocol-versions :test #'string=))))

;;; ---------------------------------------------------------------------------
;;; CORS header application
;;; ---------------------------------------------------------------------------

(defun %apply-cors-headers (request)
  "Apply CORS response headers when the request Origin is a loopback address.
Non-loopback origins receive no Access-Control-Allow-Origin so a
browser-sourced cross-origin request is blocked at the wire.
Always sets Access-Control-Expose-Headers so clients can read Mcp-Session-Id."
  (let ((origin (hunchentoot:header-in :origin request)))
    (when (and origin (%loopback-origin-p origin))
      (setf (hunchentoot:header-out :access-control-allow-origin) origin)
      (log-event :debug "http.cors.allowed" "origin" origin))
    (when (and origin (not (%loopback-origin-p origin)))
      (log-event :warn "http.cors.rejected" "origin" origin)))
  (setf (hunchentoot:header-out :access-control-expose-headers)
        "Mcp-Session-Id, MCP-Protocol-Version"))

;;; ---------------------------------------------------------------------------
;;; JSON helpers
;;; ---------------------------------------------------------------------------

(defun %http-error-json (code message)
  "Build a JSON-RPC error envelope string with id null and the given CODE/MESSAGE."
  (let ((err (make-ht "code" code "message" message))
        (outer (make-ht "jsonrpc" "2.0" "id" 'null "error" nil)))
    (setf (gethash "error" outer) err)
    (com.inuoe.jzon:stringify outer)))

(defun %json-response (content &key (status 200))
  "Set the response status and Content-Type then return CONTENT as the body."
  (setf (hunchentoot:return-code*) status)
  (setf (hunchentoot:content-type*) "application/json")
  content)

(defun %parse-json-body ()
  "Parse the POST body as JSON. Returns a hash-table or NIL on parse error."
  (let ((raw (hunchentoot:raw-post-data :force-text t)))
    (when (and raw (plusp (length raw)))
      (handler-case
          (com.inuoe.jzon:parse raw)
        (error (e)
          (log-event :warn "http.parse-error" "error" (princ-to-string e))
          nil)))))

;;; ---------------------------------------------------------------------------
;;; POST handler (JSON-only and SSE response modes)
;;; ---------------------------------------------------------------------------

(defun handle-mcp-post (default-slynk-attach default-project-root)
  "Handle POST /mcp for this acceptor invocation.
DEFAULT-SLYNK-ATTACH and DEFAULT-PROJECT-ROOT are the closure-captured
defaults from serve-http — never from any process-wide special, so
per-session mutations stay within that session.
Supports both application/json and text/event-stream Accept modes."
  (let* ((request hunchentoot:*request*)
         (session-id-header (hunchentoot:header-in :mcp-session-id request))
         (accept (hunchentoot:header-in :accept request))
         (body (%parse-json-body)))

    ;; Check MCP-Protocol-Version header (absent = assume 2025-03-26).
    (unless (%check-protocol-version-header request)
      (return-from handle-mcp-post
        (%json-response
         (%http-error-json -32600
                           (format nil "Unsupported MCP-Protocol-Version: ~A"
                                   (hunchentoot:header-in :mcp-protocol-version request)))
         :status 400)))

    ;; Missing body is a parse error.
    (unless body
      (return-from handle-mcp-post
        (%json-response (%http-error-json -32700 "Parse error") :status 400)))

    (let ((method (when (hash-table-p body) (gethash "method" body)))
          (body-id (when (hash-table-p body) (gethash "id" body))))

      ;; Client notification or response (no id in body): 202 Accepted, no body.
      (when (and (not (null method)) (null body-id))
        (unless (string= method "initialize")
          (setf (hunchentoot:return-code*) 202)
          (return-from handle-mcp-post "")))

      ;; initialize: create a new session; no Mcp-Session-Id required.
      (when (and (stringp method) (string= method "initialize"))
        (return-from handle-mcp-post
          (let* ((http-sess (create-session :slynk-attach default-slynk-attach
                                          :project-root default-project-root))
               (mcp-sess (http-session-mcp-session http-sess))
               (id (http-session-id http-sess))
               (line (map 'string #'identity (com.inuoe.jzon:stringify body))))
          ;; Echo the session id back in the response header.
          (setf (hunchentoot:header-out :mcp-session-id) id)
          (let ((*current-session-id* id))
            (bordeaux-threads:with-lock-held
                ((http-session-active-requests-lock http-sess))
              (incf (http-session-active-requests http-sess)))
            (let* ((sse-p (and accept (search "text/event-stream" accept)))
                   ;; Capture the channel installed by any concurrent GET
                   ;; subscriber so we can reuse it (and never overwrite it
                   ;; with a null-channel on cleanup) when this POST is in
                   ;; SSE mode. When no SSE subscriber exists prior is a
                   ;; null-channel; we then own the swap and must restore it.
                   (prior-channel (session-notify-channel mcp-sess))
                   (reuse-prior   (and sse-p (typep prior-channel 'sse-channel)))
                   (fresh-channel (if reuse-prior
                                      prior-channel
                                      (make-instance 'sse-channel :stream nil))))
              (when (and sse-p (not reuse-prior))
                (setf (session-notify-channel mcp-sess) fresh-channel))
              (unwind-protect
                   (if sse-p
                       ;; SSE mode: open a response stream and write the
                       ;; result as a single SSE message event.
                       (let ((response (multiple-value-bind (resp captured)
                                           (%dispatch-with-stdout-guard line mcp-sess)
                                         (when (plusp (length captured))
                                           (log-event :warn "transport.stdout-pollution"
                                                      "session" id
                                                      "bytes" (length captured)))
                                         resp)))
                         ;; Now open the SSE response and drain queued events + final.
                         (setf (hunchentoot:content-type*) "text/event-stream")
                         (setf (hunchentoot:header-out :cache-control) "no-cache")
                         (let ((stream (make-flexi-stream
                                        (hunchentoot:send-headers)
                                        :external-format :utf-8)))
                           ;; Drain any notifications queued during dispatch —
                           ;; but only when we own a fresh channel. When we
                           ;; reused the GET subscriber's channel, the GET
                           ;; thread is the queue drainer.
                           (unless reuse-prior
                             (handler-case
                                 (%drain-sse-queue fresh-channel stream)
                               (stream-error () nil)))
                           ;; Write the final response as a message event.
                           (when response
                             (handler-case
                                 (%write-sse-event stream "message" response)
                               (stream-error () nil)))
                           (ignore-errors (finish-output stream)))
                         ;; Return empty string — Hunchentoot uses send-headers output.
                         "")
                       ;; JSON mode: return the response as a plain body.
                       (let ((response (multiple-value-bind (resp captured)
                                           (%dispatch-with-stdout-guard line mcp-sess)
                                         (when (plusp (length captured))
                                           (log-event :warn "transport.stdout-pollution"
                                                      "session" id
                                                      "bytes" (length captured)))
                                         resp)))
                         (%json-response response)))
                ;; Cleanup runs whether dispatch returned normally or threw.
                ;; Restore the prior channel only when we installed a fresh
                ;; one ourselves — otherwise we'd overwrite the GET
                ;; subscriber's live sse-channel with a null-channel, and
                ;; the GET handler's condition-wait would block forever.
                (when (and sse-p (not reuse-prior))
                  (setf (session-notify-channel mcp-sess) prior-channel))
                (bordeaux-threads:with-lock-held
                    ((http-session-active-requests-lock http-sess))
                  (decf (http-session-active-requests http-sess)))))))))

      ;; Non-initialize: Mcp-Session-Id is required.
      (unless session-id-header
        (return-from handle-mcp-post
          (%json-response
           (%http-error-json -32600 "Missing Mcp-Session-Id header")
           :status 400)))

      ;; Look up the session.
      (let ((http-sess (get-session session-id-header)))
        (unless http-sess
          (return-from handle-mcp-post
            (%json-response
             (%http-error-json -32600 "Session not found")
             :status 404)))

        ;; Dispatch the request, guarding active-requests.
        (let ((mcp-sess (http-session-mcp-session http-sess))
              (line (map 'string #'identity (com.inuoe.jzon:stringify body))))
          (bordeaux-threads:with-lock-held
              ((http-session-active-requests-lock http-sess))
            (incf (http-session-active-requests http-sess)))
          (let* ((sse-p (and accept (search "text/event-stream" accept)))
                 ;; Reuse the GET subscriber's sse-channel when one is
                 ;; already installed so the POST does not stomp it on
                 ;; cleanup (any notification emitted during dispatch
                 ;; reaches the GET stream, matching MCP Streamable HTTP
                 ;; semantics: GET is the canonical notification channel,
                 ;; POST returns the call result inline).
                 (prior-channel (session-notify-channel mcp-sess))
                 (reuse-prior   (and sse-p (typep prior-channel 'sse-channel)))
                 (fresh-channel (if reuse-prior
                                    prior-channel
                                    (make-instance 'sse-channel :stream nil))))
            (when (and sse-p (not reuse-prior))
              (setf (session-notify-channel mcp-sess) fresh-channel))
            (unwind-protect
                 (let ((*current-session-id* session-id-header))
                   (if sse-p
                       ;; SSE mode for an existing session.
                       (let ((response (multiple-value-bind (resp captured)
                                           (%dispatch-with-stdout-guard line mcp-sess)
                                         (when (plusp (length captured))
                                           (log-event :warn "transport.stdout-pollution"
                                                      "session" session-id-header
                                                      "bytes" (length captured)))
                                         resp)))
                         (setf (hunchentoot:content-type*) "text/event-stream")
                         (setf (hunchentoot:header-out :cache-control) "no-cache")
                         (let ((stream (make-flexi-stream
                                        (hunchentoot:send-headers)
                                        :external-format :utf-8)))
                           ;; Drain queued events only when we own the
                           ;; channel; otherwise the GET handler is the
                           ;; designated drainer.
                           (unless reuse-prior
                             (handler-case
                                 (%drain-sse-queue fresh-channel stream)
                               (stream-error () nil)))
                           (when response
                             (handler-case
                                 (%write-sse-event stream "message" response)
                               (stream-error () nil)))
                           (ignore-errors (finish-output stream)))
                         "")
                       ;; JSON mode.
                       (multiple-value-bind (response captured)
                           (%dispatch-with-stdout-guard line mcp-sess)
                         (when (plusp (length captured))
                           (log-event :warn "transport.stdout-pollution"
                                      "session" session-id-header
                                      "bytes" (length captured)))
                         (if response
                             (%json-response response)
                             (progn
                               (setf (hunchentoot:return-code*) 202)
                               "")))))
              ;; Cleanup runs whether dispatch returned normally or threw.
              ;; Restore the prior channel only when we owned the swap —
              ;; never overwrite a GET subscriber's live sse-channel.
              (when (and sse-p (not reuse-prior))
                (setf (session-notify-channel mcp-sess) prior-channel))
              (bordeaux-threads:with-lock-held
                  ((http-session-active-requests-lock http-sess))
                (decf (http-session-active-requests http-sess))))))))))

;;; ---------------------------------------------------------------------------
;;; GET handler — long-lived SSE notification stream
;;; ---------------------------------------------------------------------------

(defun handle-mcp-get ()
  "Handle GET /mcp — open a long-lived SSE stream for unsolicited notifications.
Validates Mcp-Session-Id (400 missing, 404 unknown), sets SSE headers,
installs an sse-channel on the mcp-session, then blocks waiting for events
or client disconnect.
On disconnect (stream-error), restores the null-channel and returns."
  (let* ((request hunchentoot:*request*)
         (session-id-header (hunchentoot:header-in :mcp-session-id request)))

    (unless session-id-header
      (return-from handle-mcp-get
        (%json-response (%http-error-json -32600 "Missing Mcp-Session-Id header")
                        :status 400)))

    (let ((http-sess (get-session session-id-header)))
      (unless http-sess
        (return-from handle-mcp-get
          (%json-response (%http-error-json -32600 "Session not found")
                          :status 404)))

      (let* ((mcp-sess (http-session-mcp-session http-sess)))

        ;; Set SSE response headers BEFORE send-headers.
        (setf (hunchentoot:content-type*) "text/event-stream")
        (setf (hunchentoot:header-out :cache-control) "no-cache")
        (setf (hunchentoot:header-out :x-accel-buffering) "no")

        ;; send-headers flushes the response headers to the client and returns
        ;; a binary chunked stream.  Wrap it in a flexi-stream for character
        ;; output so %write-sse-event / %drain-sse-queue can use write-string.
        (let* ((stream (make-flexi-stream (hunchentoot:send-headers)
                                          :external-format :utf-8))
               (channel (make-instance 'sse-channel :stream stream))
               (done-p nil))

          ;; Install the SSE channel on the session.
          (setf (session-notify-channel mcp-sess) channel)

          (unwind-protect
               ;; Block until the channel is marked done or the client disconnects.
               (loop
                 (bordeaux-threads:with-lock-held ((sse-channel-lock channel))
                   ;; Wait with spurious-wakeup-safe loop (Pitfall 4).
                   (loop until (or (sse-channel-done-p channel)
                                   (sse-channel-queue channel))
                         do (bordeaux-threads:condition-wait
                             (sse-channel-cv channel)
                             (sse-channel-lock channel)))
                   (setf done-p (sse-channel-done-p channel)))
                 (handler-case
                     (%drain-sse-queue channel stream)
                   (stream-error ()
                     ;; Client disconnected mid-drain — exit the loop.
                     (setf done-p t)))
                 (when done-p (return)))
            ;; Cleanup: restore null-channel so emit calls don't hit a dead stream.
            (setf (session-notify-channel mcp-sess) (make-instance 'null-channel))
            (ignore-errors (finish-output stream)))

          ;; Return empty string so Hunchentoot doesn't try to write a body.
          "")))))

;;; ---------------------------------------------------------------------------
;;; DELETE handler
;;; ---------------------------------------------------------------------------

(defun handle-mcp-delete ()
  "Handle DELETE /mcp — terminate a session.
Returns 204 No Content on success, 400 for missing header, 404 for unknown."
  (let* ((request hunchentoot:*request*)
         (session-id-header (hunchentoot:header-in :mcp-session-id request)))
    (cond
      ((null session-id-header)
       (%json-response (%http-error-json -32600 "Missing Mcp-Session-Id header")
                       :status 400))
      ((null (delete-session session-id-header))
       (%json-response (%http-error-json -32600 "Session not found")
                       :status 404))
      (t
       (setf (hunchentoot:return-code*) 204)
       ""))))

;;; ---------------------------------------------------------------------------
;;; OPTIONS handler
;;; ---------------------------------------------------------------------------

(defun handle-mcp-options ()
  "Handle OPTIONS /mcp — CORS preflight response."
  (setf (hunchentoot:header-out :access-control-allow-methods)
        "POST, GET, DELETE, OPTIONS")
  (setf (hunchentoot:header-out :access-control-allow-headers)
        "Content-Type, Mcp-Session-Id, MCP-Protocol-Version, Accept")
  (setf (hunchentoot:header-out :access-control-max-age) "86400")
  (setf (hunchentoot:return-code*) 200)
  "")

;;; ---------------------------------------------------------------------------
;;; Hunchentoot acceptor
;;; ---------------------------------------------------------------------------

(defclass mcp-acceptor (hunchentoot:acceptor)
  ((post-handler
    :initarg :post-handler
    :reader mcp-acceptor-post-handler
    :documentation "Closure that handles POST /mcp for this acceptor invocation.
Captures default-slynk-attach and default-project-root from serve-http's
lexical scope so per-session mutations never escape to other sessions.")
   (get-handler
    :initarg :get-handler
    :reader mcp-acceptor-get-handler
    :documentation "Closure that handles GET /mcp.")
   (delete-handler
    :initarg :delete-handler
    :reader mcp-acceptor-delete-handler
    :documentation "Closure that handles DELETE /mcp.")
   (options-handler
    :initarg :options-handler
    :reader mcp-acceptor-options-handler
    :documentation "Closure that handles OPTIONS /mcp."))
  (:documentation "Hunchentoot acceptor subclass for the MCP HTTP transport.
Carries per-invocation handler closures so concurrent serve-http invocations
(theoretical but not supported in v1) would own independent defaults."))

(defmethod hunchentoot:acceptor-dispatch-request ((acceptor mcp-acceptor) request)
  "Dispatch an incoming request to the appropriate MCP handler.
Handles /mcp with POST/GET/DELETE/OPTIONS; returns 404 for all other paths."
  (let ((path (hunchentoot:script-name* request))
        (method (hunchentoot:request-method* request)))
    (if (string= path "/mcp")
        (progn
          ;; Apply CORS headers on every /mcp request.
          (%apply-cors-headers request)
          (case method
            (:post    (funcall (mcp-acceptor-post-handler acceptor)))
            (:get     (funcall (mcp-acceptor-get-handler acceptor)))
            (:delete  (funcall (mcp-acceptor-delete-handler acceptor)))
            (:options (funcall (mcp-acceptor-options-handler acceptor)))
            (otherwise
             (setf (hunchentoot:return-code*) 405)
             (%http-error-json -32601 "Method not allowed"))))
        (call-next-method))))

;;; ---------------------------------------------------------------------------
;;; serve-http — blocking entry point
;;; ---------------------------------------------------------------------------

(defun serve-http (&key (host "127.0.0.1") (port 3000)
                        slynk-attach project-root
                        (session-timeout 3600)
                        (cleanup-interval 60))
  "Start a Streamable HTTP MCP server (MCP 2025-03-26/2025-06-18) on HOST:PORT.

Blocks until STOP-HTTP-SERVER is called.  Returns the acceptor.

The operator precondition is that %CHECK-REMOTE-BIND has already been called
in src/run.lisp before SERVE-HTTP is invoked — this function does not
re-check the bind address.

Arguments:
  HOST              — bind address (default \"127.0.0.1\")
  PORT              — listener port; 0 picks an ephemeral port
  SLYNK-ATTACH      — Slynk host:port string, or NIL
  PROJECT-ROOT      — initial session project root pathname, or NIL
  SESSION-TIMEOUT   — idle eviction threshold in seconds (default 3600)
  CLEANUP-INTERVAL  — sweep interval in seconds (default 60)

SLYNK-ATTACH and PROJECT-ROOT are let-bound as DEFAULT-SLYNK-ATTACH and
DEFAULT-PROJECT-ROOT in this function's lexical scope.  The four
per-method handler closures capture those local bindings.  Every
CREATE-SESSION call receives the captured values as keyword arguments.
No process-wide special holds either value — so fs-set-project-root on
one HTTP session updates only that session's SESSION-PROJECT-ROOT slot,
never another session's."
  ;; Apply operator-supplied timeouts to the process-wide specials.
  (setf *session-timeout-seconds* session-timeout
        *cleanup-interval-seconds* cleanup-interval)

  ;; Let-bind the two per-invocation defaults from keyword args; these
  ;; names are the ONLY carrier — no defvar/defparameter is created, so
  ;; one session's fs-set-project-root cannot reach any other session.
  (let* ((default-slynk-attach slynk-attach)
         (default-project-root project-root)

         ;; Build per-method handler closures capturing the two defaults.
         (post-closure    (lambda ()
                            (handle-mcp-post default-slynk-attach
                                             default-project-root)))
         (get-closure     #'handle-mcp-get)
         (delete-closure  #'handle-mcp-delete)
         (options-closure #'handle-mcp-options)

         ;; Construct the acceptor with the closures on slots.
         (acceptor (make-instance 'mcp-acceptor
                                  :address host
                                  :port port
                                  :access-log-destination nil
                                  :message-log-destination nil
                                  :post-handler post-closure
                                  :get-handler get-closure
                                  :delete-handler delete-closure
                                  :options-handler options-closure)))

    (hunchentoot:start acceptor)
    (setf *http-server* acceptor)
    (setf *http-server-port* (hunchentoot:acceptor-port acceptor))

    ;; Start the idle-eviction background thread.
    (%start-session-cleanup)

    (log-event :info "http.start"
               "host" host
               "port" *http-server-port*
               "url" (format nil "http://~A:~D/mcp" host *http-server-port*))

    acceptor))

;;; ---------------------------------------------------------------------------
;;; start-http-server / stop-http-server / http-server-running-p
;;; ---------------------------------------------------------------------------

(defun http-server-running-p ()
  "Return T when the HTTP server is running."
  (and *http-server*
       (hunchentoot:started-p *http-server*)))

(defun start-http-server (&key (host "127.0.0.1") (port 3000)
                               slynk-attach project-root
                               (session-timeout 3600)
                               (cleanup-interval 60))
  "Start the HTTP server, returning (values acceptor port).
When already running, returns the existing acceptor and port without
starting a second one."
  (when (http-server-running-p)
    (return-from start-http-server
      (values *http-server* *http-server-port*)))
  (let ((acceptor (serve-http :host host :port port
                               :slynk-attach slynk-attach
                               :project-root project-root
                               :session-timeout session-timeout
                               :cleanup-interval cleanup-interval)))
    (values acceptor *http-server-port*)))

(defun stop-http-server ()
  "Stop the running HTTP server, cleanup threads, and clear sessions.
Returns T whether or not a server was running.

Each session's Slynk connection is detached before *SESSIONS* is cleared
so the host listener gets a clean disconnect.  This matters for the
test harness (stop-http-server is called from unwind-protect on a live
process) and for operator-driven shutdown (Ctrl-C of a foreground server
otherwise leaves the Slynk peer without a FIN)."
  (when (http-server-running-p)
    (log-event :info "http.stop" "port" *http-server-port*)
    (%stop-session-cleanup)
    (hunchentoot:stop *http-server*)
    (bordeaux-threads:with-lock-held (*sessions-lock*)
      (maphash (lambda (id http-sess)
                 (declare (ignore id))
                 (%wake-sse-subscriber (http-session-mcp-session http-sess))
                 (ignore-errors
                  (uiop:symbol-call :dsmr-mcp/src/attach/dispatch :detach-session
                                    (http-session-mcp-session http-sess))))
               *sessions*)
      (clrhash *sessions*))
    (setf *http-server* nil
          *http-server-port* nil))
  t)
