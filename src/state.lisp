;;;; src/state.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Per-session state object and the *current-session-id* special.
;;;; Single module owns all mutable protocol-layer specials; nothing else
;;;; should introduce global state (PROJECT.md decision: "no global state
;;;; outside dsmr-mcp/src/state").
;;;;
;;;; Per-session tool instances — each session carries its own hash-table of
;;;; tool instances keyed by tool-name string, so tools can hold per-session
;;;; state (e.g. a cached Slynk connection) in ordinary slots.

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
           #:session-project-root
           #:session-notify-channel
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
accept time.")
   (initialized-p
    :accessor initialized-p
    :initform nil
    :documentation "T after a successful MCP initialize handshake.
Strict-initialize: requests arriving before this is T are refused with -32002.")
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
%handle-initialize to eager-connect.")
   (project-root
    :initarg :project-root
    :accessor session-project-root
    :initform nil
    :documentation "Absolute pathname of this session's project root.
NIL until fs-set-project-root is called. Never modified by the process CWD;
changed only via fs-set-project-root.  Session-local: one session's
re-rooting does not reach another.")
   (notify-channel
    :initarg :notify-channel
    :accessor session-notify-channel
    :initform nil
    :documentation "Notification channel for this session.
null-channel: stdio sessions and bare test fixtures (emit is a no-op).
tcp-line-channel: TCP sessions — emit writes one JSON-RPC notification line.
sse-channel: HTTP sessions — emit queues an event for the SSE server thread.
Set by the transport at session-create; never NIL after make-session returns.

Load-order note: src/notify.lisp loads AFTER src/state.lisp in the
package-inferred-system order. make-session installs a null-channel instance
via runtime class lookup (find-symbol / find-package) so this slot's initform
stays nil and no compile-time import of dsmr-mcp/src/notify is required."))
  (:documentation "Holds all per-connection state for one MCP session.
One session is constructed per transport connection:
  - stdio: one session for the whole process lifetime
  - TCP/HTTP (future): one session per connection
  - tests: one fresh session per test case
The session is threaded through every protocol handler; it is NOT a
dynamic variable (only *current-session-id* is)."))

(defun make-session (&key (id "stdio") slynk-attach project-root)
  "Create and return a fresh, uninitialised session with the given ID.
ID defaults to \"stdio\" (the stdio transport's logical name).
SLYNK-ATTACH is the resolved host:port config string (or NIL) passed
through from run's resolved-slynk-attach.
PROJECT-ROOT is the initial project root pathname (or NIL); can be set
later via fs-set-project-root.
The returned session has:
  - initialized-p: NIL
  - protocol-version: NIL
  - client-info: NIL
  - tool-instances: empty equal-keyed hash-table
  - slynk-attach: SLYNK-ATTACH (NIL when not configured)
  - project-root: PROJECT-ROOT (NIL when not configured)
  - notify-channel: a null-channel instance (emit is a no-op until the
    transport installs a real channel via setf session-notify-channel)"
  (let ((result (make-instance 'session :id id :slynk-attach slynk-attach
                                        :project-root project-root)))
    ;; Install a null-channel as the default notify-channel.  Runtime class
    ;; lookup via find-symbol / find-package avoids a compile-time import of
    ;; dsmr-mcp/src/notify, which would create a circular load-order dependency
    ;; (notify.lisp loads after state.lisp in the package-inferred order).
    ;; When notify.lisp is not yet loaded the channel stays nil; tools call
    ;; emit only after full system load, so this is safe.
    (let ((null-channel-class
            (let ((pkg (find-package :dsmr-mcp/src/notify)))
              (when pkg
                (let ((sym (find-symbol "NULL-CHANNEL" pkg)))
                  (when sym (find-class sym nil)))))))
      (when null-channel-class
        (setf (session-notify-channel result)
              (make-instance null-channel-class))))
    result))

;;; Session-ID dynamic variable --------------------------------------------

(defvar *current-session-id* nil
  "Dynamically bound by the transport to the current session-id string
for the duration of one request. Callers must treat this as read-only.

Binding scope by transport:
  - stdio: bound once around the entire serve-streams loop
    (session lifecycle == process lifecycle)
  - TCP (future): bound per-connection in the accept loop
  - HTTP (future): bound per-request from the Mcp-Session-Id header
  - tests: bound explicitly or left NIL when testing process-json-line
    in isolation

The structured logger reads this to include the session id in every log
line without requiring it to be passed as an argument.

Declared as defvar (not defparameter) so transports can let-bind it
for the duration of one request without triggering
parameter-rebinding warnings on system reload.")

;;; Process-level mode special -----------------------------------------------

(defvar *mode* :attached
  "Current server dispatch mode. One of :ATTACHED, :HERMETIC, or :AUTO.
Set once at startup by run.lisp from the resolved-mode value.

Scope: process-level for the current one-image/one-session topology.

:AUTO probes the Slynk listener and resolves to :attached or :hermetic at
startup. :HERMETIC causes the hermetic worker-pool dispatch path.

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
