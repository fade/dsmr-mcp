;;;; src/protocol.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Protocol kernel: pure (I/O-free) JSON-RPC 2.0 framing, MCP handshake
;;;; with version negotiation, strict-initialize gate, dispatch table,
;;;; and error envelopes. The only public entry point is process-json-line.
;;;;
;;;; Divergences from cl-mcp (read-only MIT reference):
;;;;   handle-initialize does NOT emit -32602 on version mismatch.
;;;;   Instead, it replies with the server's highest supported version.
;;;;   InitializeResult.capabilities advertises BOTH tools AND prompts;
;;;;   cl-mcp advertises only tools.
;;;;   Strict-initialize gate: -32002 arm is placed BEFORE tools/prompts
;;;;   arms; cl-mcp does not gate pre-init requests at all.
;;;;
;;;; JSON-RPC error code map:
;;;;   -32700  Parse error          malformed JSON or parse-limit exceeded
;;;;   -32600  Invalid Request      bad jsonrpc version, missing method, etc.
;;;;   -32601  Method not found     unknown method or unknown tool name
;;;;   -32602  Invalid params       missing required tool argument
;;;;   -32603  Internal error       unexpected error in protocol/dispatch layer
;;;;   -32002  Server not initialized  pre-handshake request (strict gate)
;;;;     NOTE: -32002 is the MCP/TypeScript-SDK convention. The MCP 2025-06-18
;;;;     spec does not number a "server not initialized" code explicitly — it
;;;;     only documents -32602 for the version-mismatch case that dsmr-mcp
;;;;     deliberately does not use. -32002 matches cl-mcp behaviour and what
;;;;     Claude Code/Codex clients expect.
;;;;
;;;; Parser-resource-exhaustion mitigation:
;;;;   jzon:parse is called with explicit :max-depth and :max-string-length
;;;;   bounds. jzon raises json-parse-limit-error (a subtype of
;;;;   json-parse-error) when either bound is exceeded; the inner
;;;;   handler-case catches it and returns a bounded -32700 Parse error
;;;;   instead of allocating unboundedly.

(defpackage #:dsmr-mcp/src/protocol
  (:use #:cl)
  (:local-nicknames (#:jzon #:com.inuoe.jzon))
  (:import-from #:dsmr-mcp/src/state
                #:session
                #:initialized-p
                #:protocol-version
                #:client-info
                #:*current-session-id*)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:make-ht
                #:result
                #:rpc-error
                #:schema->json
                #:validate-args
                #:arg-validation-error
                #:arg-validation-field
                #:arg-validation-message)
  (:import-from #:dsmr-mcp/src/tools/base
                #:*tool-classes*
                #:tool-name
                #:tool-input-schema
                #:tool-description)
  (:import-from #:dsmr-mcp/src/log
                #:log-event
                #:*log-session-id*
                #:*log-request-id*)
  (:import-from #:dsmr-mcp/src/dispatch
                #:handle-tools-call)
  (:import-from #:dsmr-mcp/src/wire-strings
                #:coerce-wire-strings)
  (:export #:process-json-line
           #:+supported-protocol-versions+))

(in-package #:dsmr-mcp/src/protocol)

;;; Protocol version set -------------------------------------------------------

(defparameter +supported-protocol-versions+ '("2025-06-18" "2025-03-26")
  "Supported MCP protocol versions, newest first.
The car (\"2025-06-18\") is returned on version mismatch.
2024-11-05 is intentionally dropped: it predates Streamable HTTP
and adds a maintenance burden for clients we do not have.")

;;; Parser resource-exhaustion bounds ------------------------------------------

(defconstant +max-json-depth+ 64
  "Maximum nesting depth accepted by jzon:parse on untrusted input.
Exceeding this causes jzon to signal json-parse-limit-error (a subtype of
json-parse-error), which process-json-line catches and maps to -32700.
Defends against unbounded parser resource use.")

(defconstant +max-json-string-length+ #x100000
  "Maximum individual string length (1 MB) accepted by jzon:parse on
untrusted input. Exceeding this causes jzon to signal
json-parse-limit-error. Defends against unbounded parser resource use.")

;;; Encoding helper ------------------------------------------------------------

(defun %encode-line (obj)
  "Stringify OBJ to a JSON line using jzon:stringify.
Returns a canned error JSON literal on jzon:json-write-error so the
transport always has a valid string to write. Never passes :pretty t
(embedded newlines are forbidden on the MCP stdio wire)."
  (handler-case
      (jzon:stringify obj)
    (jzon:json-write-error ()
      "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32603,\"message\":\"Response encoding failed\"}}")))

;;; Handshake ------------------------------------------------------------------

(defun %handle-initialize (session id params)
  "Handle an initialize request. Negotiates protocolVersion:
if the client requests a supported version, echo it back; otherwise return
the server's highest supported version. Never emits -32602 on mismatch.

Capability: both tools AND prompts with listChanged t.

After the initialized-p flag flips, calls try-eager-connect via runtime
symbol resolution. The surrounding ignore-errors guards against the attach
subsystem being absent in a stripped build; try-eager-connect itself swallows
slime-network-error and logs attach.eager-connect.failed so a misconfigured or
unreachable target fails fast and visibly without derailing this response. The
post-death reopen shares the same get-or-open-connection path.

Note: serverInfo.version is resolved at call time via uiop:symbol-call
rather than a compile-time package reference, so this file can be compiled
before dsmr-mcp/src/main is loaded."
  (let* ((client-version (and params (gethash "protocolVersion" params)))
         (negotiated (or (find client-version +supported-protocol-versions+
                               :test #'string=)
                         (first +supported-protocol-versions+)))
         (caps (make-ht "tools"   (make-ht "listChanged" t)
                        "prompts" (make-ht "listChanged" t))))
    (setf (protocol-version session) negotiated
          (initialized-p session) t)
    (when (and params (gethash "clientInfo" params))
      (setf (client-info session) (gethash "clientInfo" params)))
    ;; Eager connect AFTER initialized-p flips.
    ;; Runtime symbol resolution (uiop:symbol-call) avoids a compile-time dep
    ;; on dsmr-mcp/src/attach/dispatch, matching the existing version lookup
    ;; pattern below. ignore-errors guards against the attach system being
    ;; absent in a stripped build; try-eager-connect handles network errors.
    (ignore-errors
     (uiop:symbol-call :dsmr-mcp/src/attach/dispatch :try-eager-connect session))
    (result id (make-ht "protocolVersion" negotiated
                        "capabilities"    caps
                        "serverInfo"      (make-ht "name"    "dsmr-mcp"
                                                   "version" (uiop:symbol-call
                                                               :dsmr-mcp/src/main
                                                               :version))))))

;;; Tool listing ---------------------------------------------------------------

(defun %handle-tools-list (id)
  "Return the tools/list result. Walks *tool-classes* to build descriptors.
Returns result.tools as a simple-vector (#() when no tools are registered)
so jzon encodes it as a JSON array, never null."
  (let ((descriptors '()))
    (maphash (lambda (name class)
               (declare (ignore name))
               (let* ((proto (c2mop:class-prototype class))
                      (desc (make-ht
                             "name"        (tool-name proto)
                             "description" (tool-description proto)
                             "inputSchema" (schema->json (tool-input-schema proto)))))
                 (push desc descriptors)))
             *tool-classes*)
    (result id (make-ht "tools" (coerce descriptors 'simple-vector)))))

;;; Prompts stubs --------------------------------------------------------------

(defun %handle-prompts-list (id)
  "Return the prompts/list result. Stub: always an empty array.
Result.prompts is a simple-vector so jzon encodes it as []."
  (result id (make-ht "prompts" #())))

(defun %handle-prompts-get (id params)
  "Return -32602 for any prompts/get request.
The error message names the requested prompt name for diagnostics."
  (rpc-error id -32602
             (format nil "Unknown prompt: ~A"
                     (and params (gethash "name" params)))))

;;; Notifications --------------------------------------------------------------

(defun %handle-notification (session method params)
  "Handle a JSON-RPC notification (no response expected, returns nil).
notifications/initialized: no-op (the gate already flipped during
handle-initialize). Unknown notifications are silently ignored per
JSON-RPC 2.0 spec."
  (declare (ignore session params))
  (cond
    ((string= method "notifications/initialized")
     ;; The session is already marked initialized by handle-initialize.
     ;; Nothing to do here.
     nil)
    (t
     (log-event :debug "rpc.notification.unknown"
                "method" method
                "session" (and (boundp '*current-session-id*)
                               *current-session-id*))
     nil)))

;;; Request dispatch -----------------------------------------------------------

(defun %handle-request (session id method params)
  "Dispatch a JSON-RPC request to the appropriate handler.
Order matters:
  1. initialize  — always allowed, sets up the session
  2. ping        — allowed before init (MCP spec explicitly permits)
  3. strict-init gate — any other method before init -> -32002
  4. tools/list, tools/call, prompts/list, prompts/get
  5. t           — -32601 Method not found

The -32002 arm is deliberately placed BEFORE tools/prompts arms.
dsmr-mcp is strict here; cl-mcp does not gate pre-init requests."
  (cond
    ((string= method "initialize")
     (%handle-initialize session id params))

    ((string= method "ping")
     ;; ping is allowed before initialization (liveness probe use case).
     (result id (make-ht)))

    ((not (initialized-p session))
     ;; Strict gate: all non-init, non-ping requests before handshake
     ;; return -32002.  This arm is BEFORE the tools/* and prompts/*
     ;; arms — that ordering is load-bearing.
     (rpc-error id -32002 "Server not initialized"))

    ((string= method "tools/list")
     (%handle-tools-list id))

    ((string= method "tools/call")
     (handle-tools-call session id params))

    ((string= method "prompts/list")
     (%handle-prompts-list id))

    ((string= method "prompts/get")
     (%handle-prompts-get id params))

    (t
     (rpc-error id -32601 (format nil "Method not found: ~A" method)))))

;;; Correlation-ID helpers ---------------------------------------------------

(defvar *notif-counter* 0
  "Monotonic counter for notification request-id fallback strings.
Single-threaded stdio serialises access; no lock needed.
Each notification that lacks a JSON-RPC id gets a distinct 'notif-N'
correlation id in the log context for the duration of its handling.")

(defun %generate-notif-id ()
  "Return a unique 'notif-<n>' string for a notification without a JSON-RPC id."
  (format nil "notif-~A" (incf *notif-counter*)))

;;; Wire-string normalisation is shared with the attached-eval funnel; the
;;; rationale and the recursive coercion live in dsmr-mcp/src/wire-strings.
;;; The inbound JSON-RPC parse runs coerce-wire-strings so no jzon
;;; SIMPLE-BASE-STRING survives into a form bound for the Slynk wire.

;;; Public entry point ---------------------------------------------------------

(defun process-json-line (line session)
  "Parse one JSON-RPC 2.0 line and return a JSON line string to send, or NIL
for notifications. Pure of I/O: reads LINE, writes nothing.

CONTRACT:
  line    -- a single MCP stdio line (string); may have trailing whitespace
  session -- the dsmr-mcp/src/state:session for the current connection
  returns -- a JSON string (the response line) for requests, or NIL for
            notifications; also NIL for empty lines after trim.

Error handling:
  jzon:json-parse-error (inc. json-parse-limit-error) -> -32700 Parse error
  any other error in dispatch -> -32603 Internal error
  both cases log to stderr via log-event, never leak details onto the wire.

Parser bounds:
  jzon:parse is called with :max-depth +max-json-depth+ and
  :max-string-length +max-json-string-length+. Payloads exceeding these
  limits raise json-parse-limit-error before allocating unboundedly.

Note on JSON null encoding: the MCP spec requires id=null in parse-error
responses when the request id is unknown. jzon encodes the symbol 'NULL
(i.e. CL:NULL = NIL) as JSON null; it encodes NIL as JSON false. So
error-with-unknown-id responses use 'null as the id value."
  (let ((trimmed (string-trim '(#\Space #\Tab #\Newline #\Return) line)))
    (when (string= trimmed "")
      (return-from process-json-line nil))
    (handler-case
        ;; Outer handler: catches any unhandled error from dispatch/encoding.
        ;; Returns -32603 Internal error (never leaks condition text on wire).
        (let ((msg
               ;; Inner handler: catches JSON parse failures specifically.
               ;; Returns -32700 Parse error with id null (using 'null, not nil,
               ;; because jzon encodes nil as false, not null).
               (coerce-wire-strings
                (handler-case
                    (jzon:parse trimmed
                                :max-depth +max-json-depth+
                                :max-string-length +max-json-string-length+)
                  (jzon:json-parse-error (e)
                    (log-event :warn "rpc.parse-error"
                               "error" (princ-to-string e))
                    (return-from process-json-line
                      (%encode-line (rpc-error 'null -32700 "Parse error"))))))))
          ;; Envelope validation: must be a hash-table with jsonrpc = "2.0".
          (unless (hash-table-p msg)
            (return-from process-json-line
              (%encode-line (rpc-error 'null -32600 "Invalid Request"))))
          (let ((jsonrpc (gethash "jsonrpc" msg))
                (id      (gethash "id" msg))
                (method  (gethash "method" msg))
                (params  (gethash "params" msg)))
            (unless (and (stringp jsonrpc) (string= jsonrpc "2.0"))
              (return-from process-json-line
                (%encode-line (rpc-error id -32600 "Invalid Request"))))
            ;; Bind correlation IDs for the duration of this request/notification
            ;; so log-event includes them in every JSON log line.
            (let ((*log-session-id* *current-session-id*)
                  (*log-request-id* (or id (%generate-notif-id))))
              (cond
                ((and method id)
                 ;; Request: has both method and id -> dispatch and return response.
                 (%encode-line (%handle-request session id method params)))
                ((and method (not id))
                 ;; Notification: has method, no id -> handle, return nil (no response).
                 (%handle-notification session method params)
                 nil)
                (t
                 ;; Missing method: malformed request.
                 (%encode-line (rpc-error id -32600 "Invalid Request")))))))
      (error (e)
        (log-event :error "rpc.internal" "error" (princ-to-string e))
        (%encode-line (rpc-error 'null -32603 "Internal error"))))))
