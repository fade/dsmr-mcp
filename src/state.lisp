;;;; src/state.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Per-session state object and the *current-session-id* special.
;;;; Single module owns all mutable protocol-layer specials; nothing else
;;;; should introduce global state (PROJECT.md decision: "no global state
;;;; outside dsmr-mcp/src/state").
;;;;
;;;; D-07: per-session tool instances — each session carries its own
;;;;       hash-table of tool instances keyed by tool-name string, so
;;;;       tools can hold per-session state (e.g. a cached Slynk
;;;;       connection) in ordinary slots.

(defpackage #:dsmr-mcp/src/state
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/tools/base
                #:*tool-classes*)
  (:export #:session
           #:session-id
           #:initialized-p
           #:protocol-version
           #:client-info
           #:tool-instances
           #:session-slynk-attach
           #:make-session
           #:*current-session-id*
           #:*mode*
           #:get-tool-instance))

(in-package #:dsmr-mcp/src/state)

;;; Session class -----------------------------------------------------------

(defclass session ()
  ((id
    :initarg :id
    :reader session-id
    :documentation "Unique identifier for this session. Stdio sessions
use \"stdio\"; TCP/HTTP sessions use a per-connection UUID assigned at
accept time (Phase 9).")
   (initialized-p
    :accessor initialized-p
    :initform nil
    :documentation "T after a successful MCP initialize handshake.
D-04 strict-initialize: requests arriving before this is T are refused
with -32002.")
   (protocol-version
    :accessor protocol-version
    :initform nil
    :documentation "Negotiated MCP protocol version string (e.g.
\"2025-06-18\") set during initialize handling. NIL before handshake.")
   (client-info
    :accessor client-info
    :initform nil
    :documentation "Client-supplied clientInfo hash-table from the
initialize params, stored for diagnostics and logging.")
   (tool-instances
    :accessor tool-instances
    :initform (make-hash-table :test 'equal)
    :documentation "Per-session tool-instance cache. Maps tool-name
string to the mcp-tool instance for this session. Populated lazily by
get-tool-instance the first time a tool is called.")
   (slynk-attach
    :initarg :slynk-attach
    :accessor session-slynk-attach
    :initform nil
    :documentation "Resolved host:port Slynk-attach config string for
this session, or NIL. Set by run from the resolved config; read by
%handle-initialize to eager-connect (D-13)."))
  (:documentation "Holds all per-connection state for one MCP session.
One session is constructed per transport connection:
  - stdio: one session for the whole process lifetime
  - TCP/HTTP (Phase 9): one session per connection
  - tests: one fresh session per test case
The session is threaded through every protocol handler; it is NOT a
dynamic variable (only *current-session-id* is)."))

(defun make-session (&key (id "stdio") slynk-attach)
  "Create and return a fresh, uninitialised session with the given ID.
ID defaults to \"stdio\" (the Phase 1 transport's logical name).
SLYNK-ATTACH is the resolved host:port config string (or NIL) passed
through from run's resolved-slynk-attach (D-13, ATTACH-07).
The returned session has:
  - initialized-p: NIL
  - protocol-version: NIL
  - client-info: NIL
  - tool-instances: empty equal-keyed hash-table
  - slynk-attach: SLYNK-ATTACH (NIL when not configured)"
  (make-instance 'session :id id :slynk-attach slynk-attach))

;;; Session-ID dynamic variable --------------------------------------------

(defvar *current-session-id* nil
  "Dynamically bound by the transport to the current session-id string
for the duration of one request. Callers must treat this as read-only.

Binding scope by transport:
  - stdio (Phase 1): bound once around the entire serve-streams loop
    (session lifecycle == process lifecycle)
  - TCP (Phase 9): bound per-connection in the accept loop
  - HTTP (Phase 9): bound per-request from the Mcp-Session-Id header
  - tests: bound explicitly or left NIL when testing process-json-line
    in isolation

Phase 3's structured logger reads this to include the session id in
every log line without requiring it to be passed as an argument.

Declared as defvar (not defparameter) so transports can let-bind it
for the duration of one request without triggering
parameter-rebinding warnings on system reload.")

;;; Process-level mode special -----------------------------------------------

(defvar *mode* :attached
  "Current server dispatch mode. One of :ATTACHED, :HERMETIC, or :AUTO.
Set once at startup by run.lisp from the resolved-mode value.

Scope: process-level for the current one-image/one-session topology
(PROJECT.md; see \"Single-image-per-session invariant\").
Per-session *MODE* is deferred to MULTI-01 when multi-image dispatch lands.

:AUTO is an alias for :ATTACHED until Phase 4 introduces real hermetic
execution and the inference logic (HERM-07) has something to enforce.
:HERMETIC before Phase 4 causes handle-tools-call to return a structured
isError explaining that hermetic ICP is not yet available.

Declared as defvar (not defparameter) so tests can let-bind it without
triggering parameter-rebinding warnings on system reload.")

;;; Per-session tool-instance retrieval ------------------------------------

(defun get-tool-instance (session tool-name)
  "Return the per-session instance of the tool named TOOL-NAME for SESSION.
On the first call for a given (session, tool-name) pair the instance is
created via make-instance and cached in SESSION's tool-instances table.
Returns NIL when no class is registered for TOOL-NAME.

Caching invariant: repeated calls for the same (session, tool-name) pair
return the *same* (eq) object — tools accumulate per-session state in
ordinary slots and rely on identity stability within a session.

Different SESSION objects always produce different instances; there is
no cross-session sharing."
  (or (gethash tool-name (tool-instances session))
      (let ((class (gethash tool-name *tool-classes*)))
        (when class
          (setf (gethash tool-name (tool-instances session))
                (make-instance class :session session))))))
