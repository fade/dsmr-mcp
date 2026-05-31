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
  (:import-from #:bordeaux-threads
                #:make-lock)
  (:export #:session
           #:session-id
           #:initialized-p
           #:protocol-version
           #:client-info
           #:tool-instances
           #:session-slynk-attach
           #:session-project-root
           #:session-notify-channel
           #:session-notify-channel-lock
           #:session-elicitation-p
           #:session-envrc-prompted-p
           #:session-elicitation-id-counter
           #:session-elicitation-lock
           #:session-pending-elicitation
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
Seeded at launch from the resolved root (precedence: explicit :project-root >
DSMR_PROJECT_ROOT env > getcwd) for every transport (stdio, TCP, HTTP), so the
launch-time .envrc consent prompt can fire on the first qualifying tool call
without a prior fs-set-project-root.  Session-local: one session's root never
leaks to another.  May be RE-ROOTED later via fs-set-project-root, which is
permission-gated: re-rooting away from the launch root to a non-whitelisted
directory requires human_approved:true (D-05).  Directly-constructed sessions
(e.g. unit fixtures that call make-session without :project-root) start NIL.")
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
stays nil and no compile-time import of dsmr-mcp/src/notify is required.")
   (notify-channel-lock
    :reader session-notify-channel-lock
    :initform (make-lock "session-notify-channel-lock")
    :documentation "Guards the critical section around the notify-channel slot.
HTTP GET and POST handlers run concurrently against the same session; without
this lock the install half (read-prior + check + setf) of the channel swap is
a check-then-act race that can orphan a subscriber or lose notifications.
Every read-modify-write of notify-channel by a transport must hold this lock.")
   (elicitation-p
    :accessor session-elicitation-p
    :initform nil
    :documentation "T when the client declared the MCP `elicitation`
capability in its initialize params. Gates whether the server may issue a
server->client elicitation/create request; when NIL the launch-time .envrc
prompt degrades to a silent no-op.")
   (envrc-prompted-p
    :accessor session-envrc-prompted-p
    :initform nil
    :documentation "Once-per-session guard for the launch-time .envrc prompt.
Set T the first time the qualifying-project check runs, regardless of the
operator's answer, so the dialog cannot re-fire on every tool call.")
   (elicitation-id-counter
    :accessor session-elicitation-id-counter
    :initform 0
    :documentation "Per-session source of monotonically increasing ids for
server-initiated elicitation requests, so each in-flight request's id is
unique within the session.")
   (elicitation-lock
    :reader session-elicitation-lock
    :initform (make-lock "session-elicitation-lock")
    :documentation "Guards the pending-elicitation cell. The request-issuing
thread waits on a condition variable under this lock while the read loop
fills the cell from the client's response; every read-modify-write of the
pending cell must hold it.")
   (pending-elicitation
    :accessor session-pending-elicitation
    :initform nil
    :documentation "Single-slot pending-request holder for an in-flight
elicitation request: (id cv cell) while a request awaits its response, NIL
otherwise. cell is (result errorp) — the result hash-table from the client's
response, or an error marker. Mirrors lsp/client's pending-request idiom,
collapsed to one outstanding request per session."))
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
PROJECT-ROOT is the initial project root pathname (or NIL). run seeds it at
launch from the resolved root (explicit :project-root > DSMR_PROJECT_ROOT >
getcwd) for every transport; callers that construct a session directly (e.g.
unit fixtures) may omit it, in which case it defaults to NIL.  The root is
session-local and may be re-rooted later via the permission-gated
fs-set-project-root.
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
