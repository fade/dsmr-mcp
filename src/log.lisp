;;;; src/log.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Phase-1 logging stub. Emits key=value lines to *log-stream* (stderr).
;;;; Phase 3 will swap the log-event body for jzon-structured JSON output
;;;; without changing the caller surface.
;;;;
;;;; THREAT MODEL T-01-03: log-event NEVER writes to *standard-output*.
;;;; stdout is reserved exclusively for the JSON-RPC channel.

(defpackage #:dsmr-mcp/src/log
  (:use #:cl)
  (:export #:log-event
           #:*log-level*
           #:*log-stream*
           #:should-log-p
           #:set-log-level-from-env))

(in-package #:dsmr-mcp/src/log)

;;; Dynamic variables -------------------------------------------------------

(defvar *log-level* :info
  "Current log verbosity level. One of :debug :info :warn :error.
Set by set-log-level-from-env at load time; can be rebound dynamically.
Default :info means debug messages are suppressed in normal operation.")

(defvar *log-stream* (make-synonym-stream '*error-output*)
  "Stream log-event writes to. Defaults to a synonym stream that always
tracks the current *error-output* binding, so dynamic rebindings of
*error-output* are transparently reflected here.
Tests can capture log output by rebinding *error-output* around
the call; production always writes to stderr.
INVARIANT: this stream must NEVER be *standard-output* — stdout is
reserved for the JSON-RPC channel (MCP spec / THREAT T-01-03).")

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

;;; Logging surface ---------------------------------------------------------

(defun log-event (level event &rest kvs)
  "Emit one log line to *log-stream* when LEVEL passes the *log-level*
filter. FORMAT: \"[LEVEL] EVENT key=value ...\" followed by a newline.

LEVEL  — one of :debug :info :warn :error
EVENT  — a short event-name string (e.g. \"stdio.start\")
KVS    — alternating string/value pairs appended as key=value tokens

Phase 3 will replace the format body with a jzon-structured JSON object
so callers do not notice. The function signature is frozen.

INVARIANT: writes only to *log-stream* (tracked from *error-output*).
NEVER writes to *standard-output*."
  (when (should-log-p level)
    (format *log-stream* "[~A] ~A~{ ~A=~A~}~%" level event kvs)
    (force-output *log-stream*)))

;; Initialise log level from the environment at load time so
;; (asdf:load-system :dsmr-mcp) picks up DSMR_LOG_LEVEL immediately.
(set-log-level-from-env)
