;;;; src/log.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Structured logging via log4cl. The log-event surface is frozen at
;;;; (log-event level event &rest kvs) — no call site changes are needed.
;;;; The body delegates to log4cl; a custom json-layout serialises each
;;;; event as a single-line JSON object on *error-output* (stderr).
;;;;
;;;; THREAT MODEL T-03-LOG-01: log4cl's default console-appender writes to
;;;; *debug-io*, which can reach stdout in a Slynk REPL child process.
;;;; configure-log4cl-for-server MUST be called before serve-streams; it
;;;; removes all default appenders and installs ONE fixed-stream-appender
;;;; targeting (make-synonym-stream '*error-output*) — never *debug-io* or
;;;; *standard-output*.

(defpackage #:dsmr-mcp/src/log
  (:use #:cl)
  (:local-nicknames (#:jzon #:com.inuoe.jzon))
  (:export #:log-event
           #:*log-level*
           #:*log-stream*
           #:should-log-p
           #:set-log-level-from-env
           #:*log-session-id*
           #:*log-request-id*
           #:configure-log4cl-for-server))

(in-package #:dsmr-mcp/src/log)

;;; Dynamic variables -------------------------------------------------------

(defvar *log-level* :info
  "Current log verbosity level. One of :debug :info :warn :error.
Set by set-log-level-from-env at load time; kept in sync with log4cl's
root-logger level by configure-log4cl-for-server.
Default :info means debug messages are suppressed in normal operation.")

(defvar *log-stream* (make-synonym-stream '*error-output*)
  "Retained for API compatibility. The log4cl fixed-stream-appender uses
its own synonym stream targeting *error-output*; this var is no longer
used for output but may be read by tests written against the Phase-1 API.
INVARIANT: this stream must NEVER be *standard-output* — stdout is
reserved for the JSON-RPC channel (MCP spec / THREAT T-01-03).")

(defvar *log-session-id* nil
  "Dynamically bound to the session-id string for the duration of one
request. Read by json-layout to include session_id in every JSON log line.
NIL outside request scope (startup/teardown log events omit the field).")

(defvar *log-request-id* nil
  "Dynamically bound to the JSON-RPC request id (string or integer) or a
server-generated 'notif-<n>' string for notifications, for the duration of
one request. NIL outside request scope.")

;;; Level helpers -----------------------------------------------------------

(defun %level->int (level)
  "Map a log LEVEL keyword to its numeric priority.
Higher number = higher severity."
  (ecase level
    (:debug 10)
    (:info  20)
    (:warn  30)
    (:error 40)))

(defun %parse-level (s)
  "Parse a case-insensitive level string S into a keyword.
Returns NIL for unrecognised or NIL input."
  (cond
    ((null s) nil)
    ((string= s "debug")   :debug)
    ((string= s "info")    :info)
    ((string= s "warn")    :warn)
    ((string= s "warning") :warn)
    ((string= s "error")   :error)
    (t nil)))

(defun should-log-p (level)
  "Return T when LEVEL is at least as severe as *log-level*.
:debug < :info < :warn < :error."
  (>= (%level->int level) (%level->int *log-level*)))

;;; Configuration -----------------------------------------------------------

(defun set-log-level-from-env ()
  "Read DSMR_LOG_LEVEL from the environment and set *log-level*.
Recognised values: debug, info, warn, warning, error (case-insensitive).
Unset or unrecognised values leave *log-level* unchanged."
  (let* ((env (uiop:getenv "DSMR_LOG_LEVEL"))
         (lvl (%parse-level (and env (string-downcase env)))))
    (when lvl
      (setf *log-level* lvl))
    *log-level*))

;;; Timestamp helper --------------------------------------------------------

(defun %iso8601-utc-now ()
  "Return the current UTC time as an ISO-8601 string \"YYYY-MM-DDTHH:MM:SSZ\".
Uses get-universal-time + decode-universal-time; no local-time dep needed."
  (multiple-value-bind (sec min hour day month year)
      (decode-universal-time (get-universal-time) 0)
    (format nil "~4,'0D-~2,'0D-~2,'0DT~2,'0D:~2,'0D:~2,'0DZ"
            year month day hour min sec)))

;;; log4cl level mapping ---------------------------------------------------

(defun dsmr-level->log4cl (level)
  "Map a dsmr-mcp log level keyword to the corresponding log4cl integer level."
  (ecase level
    (:debug log4cl:+log-level-debug+)   ; 5
    (:info  log4cl:+log-level-info+)    ; 4
    (:warn  log4cl:+log-level-warn+)    ; 3
    (:error log4cl:+log-level-error+))) ; 2

;;; JSON layout -------------------------------------------------------------

(defclass json-layout (log4cl:layout) ()
  (:documentation "Writes one JSON line per log event to the appender stream.
Fields: ts (ISO-8601 UTC), level (downcased string), msg (event + kvs),
session_id and request_id when *log-session-id*/*log-request-id* are non-nil.
Uses com.inuoe.jzon:stringify — output is single-line, no embedded newlines.
INVARIANT: writes only to the stream argument; never to *standard-output*."))

(defmethod log4cl:layout-to-stream
    ((layout json-layout) stream logger level log-func)
  "Serialise one log event as a JSON line to STREAM.
LEVEL is a log4cl integer level constant. LOG-FUNC is a (lambda (stream) ...)
that writes the message text when called."
  (declare (ignore logger))
  (let* ((msg (with-output-to-string (s) (funcall log-func s)))
         (ht  (make-hash-table :test 'equal)))
    (setf (gethash "ts"    ht) (%iso8601-utc-now))
    (setf (gethash "level" ht) (string-downcase (log4cl:log-level-to-string level)))
    (setf (gethash "msg"   ht) msg)
    (when *log-session-id*
      (setf (gethash "session_id" ht) *log-session-id*))
    (when *log-request-id*
      (setf (gethash "request_id" ht) *log-request-id*))
    (write-string (jzon:stringify ht) stream)
    (terpri stream))
  (values))

;;; Appender configuration -------------------------------------------------

(defun configure-log4cl-for-server (log-level)
  "Remove all log4cl default appenders and install a single
fixed-stream-appender writing JSON to *error-output* (stderr).

MUST be called before serve-streams so no log output reaches *debug-io*
or *standard-output* (THREAT T-03-LOG-01, D-08).

LOG-LEVEL is one of :debug :info :warn :error; both the *log-level* shim
gate and log4cl's root-logger level are set to the same value so they
stay in sync."
  ;; 1. Tear down whatever log4cl installed by default (console-appender
  ;;    writes to *global-console* = (make-synonym-stream '*debug-io*)
  ;;    — exactly the stdout-pollution landmine).
  (log4cl:remove-all-appenders log4cl:*root-logger*)
  ;; 2. Install ONE stderr-only JSON appender.
  ;;    (make-synonym-stream '*error-output*) ensures the appender tracks
  ;;    dynamic rebindings of *error-output*, which lets tests capture
  ;;    log output by rebinding that var around the call.
  (let ((appender (make-instance 'log4cl:fixed-stream-appender
                                 :stream (make-synonym-stream '*error-output*)
                                 :immediate-flush t
                                 :layout (make-instance 'json-layout))))
    (log4cl:add-appender log4cl:*root-logger* appender))
  ;; 3. Set level on log4cl root logger and sync the shim gate.
  (log4cl:set-log-level log4cl:*root-logger* (dsmr-level->log4cl log-level))
  (setf *log-level* log-level))

;;; Logging surface ---------------------------------------------------------

(defun log-event (level event &rest kvs)
  "Emit one structured JSON log line to *error-output* via log4cl.

Signature frozen (D-07): (log-event level event &rest kvs).
LEVEL  — one of :debug :info :warn :error
EVENT  — a short event-name string (e.g. \"stdio.start\")
KVS    — alternating string/value pairs appended as \"key=value\" tokens

The JSON line includes ts, level, msg (event + kvs), and session_id /
request_id when *log-session-id* / *log-request-id* are non-nil.

The should-log-p gate runs first; log4cl's own level gate provides a
second check. Both are kept in sync by configure-log4cl-for-server.

INVARIANT: writes only to *error-output* (via the fixed-stream-appender).
NEVER writes to *standard-output* (THREAT T-03-LOG-01)."
  (when (should-log-p level)
    (let ((msg (format nil "~A~{ ~A=~S~}" event kvs)))
      (ecase level
        (:debug (log:debug "~A" msg))
        (:info  (log:info  "~A" msg))
        (:warn  (log:warn  "~A" msg))
        (:error (log:error "~A" msg))))))

;; Initialise log level from the environment at load time so
;; (asdf:load-system :dsmr-mcp) picks up DSMR_LOG_LEVEL immediately.
(set-log-level-from-env)
