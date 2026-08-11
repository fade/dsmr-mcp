;;;; tests/log/log-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Unit tests for the log4cl-backed log-event shim.
;;;; Covers: JSON output on *error-output*, no stdout leak, level filtering,
;;;; and per-request correlation fields (session_id, request_id).

(defpackage #:dsmr-mcp/tests/log/log-test
  (:use #:cl #:zebra)
  (:local-nicknames (#:jzon #:com.inuoe.jzon))
  (:import-from #:dsmr-mcp/src/log
                #:log-event
                #:*log-level*
                #:*log-session-id*
                #:*log-request-id*
                #:configure-log4cl-for-server))

(in-package #:dsmr-mcp/tests/log/log-test)

;;; ---------------------------------------------------------------------------
;;; Structured JSON output on *error-output*
;;; ---------------------------------------------------------------------------

(define-test ops-01-json-output-on-stderr
  "log-event emits a valid JSON object to *error-output*, with level and a
message field. Rebinds *error-output* to a string stream to capture output.
Calls configure-log4cl-for-server first to ensure stderr-only appender is active."
  (configure-log4cl-for-server :debug)
  (let* ((capture (make-string-output-stream))
         (*error-output* capture)
         (*log-level* :debug))
    (log-event :info "test.event" "key" "value")
    (let* ((output (get-output-stream-string capture))
           (line   (string-trim '(#\Newline #\Return) output))
           (parsed (jzon:parse line)))
      (true (hash-table-p parsed)
            "Output must parse as a JSON object")
      (is string= "info" (gethash "level" parsed)
          "JSON 'level' field must be \"info\"")
      (true (stringp (gethash "msg" parsed))
            "JSON 'msg' field must be a string")
      (true (search "test.event" (gethash "msg" parsed))
            "JSON 'msg' must contain the event name")
      (true (stringp (gethash "ts" parsed))
            "JSON 'ts' field must be a timestamp string"))))

;;; ---------------------------------------------------------------------------
;;; No output leaks to *standard-output*
;;; ---------------------------------------------------------------------------

(define-test ops-01-no-stdout-leak
  "log-event must not write anything to *standard-output*.
stdout is reserved exclusively for the JSON-RPC channel."
  (configure-log4cl-for-server :debug)
  (let* ((capture (make-string-output-stream))
         (*standard-output* capture)
         (*log-level* :debug))
    (log-event :info "test.event" "key" "value")
    (is equal "" (get-output-stream-string capture)
        "Nothing must be written to *standard-output*")))

;;; ---------------------------------------------------------------------------
;;; Level filtering — events below threshold are suppressed
;;; ---------------------------------------------------------------------------

(define-test ops-01-level-filter
  "With *log-level* :warn, a :info event produces no output on stderr."
  (configure-log4cl-for-server :warn)
  (let* ((capture (make-string-output-stream))
         (*error-output* capture)
         (*log-level* :warn))
    (log-event :info "below.threshold")
    (is equal "" (get-output-stream-string capture)
        "No output expected when event level is below *log-level*")))

;;; ---------------------------------------------------------------------------
;;; Correlation fields present when in request scope
;;; ---------------------------------------------------------------------------

(define-test ops-02-correlation-fields-in-request-scope
  "When *log-session-id* and *log-request-id* are bound, the JSON line
includes session_id and request_id fields with the bound values."
  (configure-log4cl-for-server :debug)
  (let* ((capture (make-string-output-stream))
         (*error-output* capture)
         (*log-level* :debug)
         (*log-session-id* "sess-1")
         (*log-request-id* "req-7"))
    (log-event :info "corr.test")
    (let* ((output (get-output-stream-string capture))
           (line   (string-trim '(#\Newline #\Return) output))
           (parsed (jzon:parse line)))
      (is string= "sess-1" (gethash "session_id" parsed)
          "session_id field must equal *log-session-id*")
      (is string= "req-7" (gethash "request_id" parsed)
          "request_id field must equal *log-request-id*"))))

;;; ---------------------------------------------------------------------------
;;; Correlation fields absent (or null) outside request scope
;;; ---------------------------------------------------------------------------

(define-test ops-02-correlation-absent-outside-scope
  "When *log-session-id* and *log-request-id* are nil (default),
the JSON line either omits those keys or maps them to JSON null — not a
non-nil string."
  (configure-log4cl-for-server :debug)
  (let* ((capture (make-string-output-stream))
         (*error-output* capture)
         (*log-level* :debug)
         (*log-session-id* nil)
         (*log-request-id* nil))
    (log-event :info "outside.scope")
    (let* ((output (get-output-stream-string capture))
           (line   (string-trim '(#\Newline #\Return) output))
           (parsed (jzon:parse line)))
      ;; Either the key is absent, or it maps to JSON null (CL nil).
      ;; Both are acceptable; what is NOT acceptable is a non-nil string.
      (true (not (stringp (gethash "session_id" parsed)))
            "session_id must not be a non-nil string outside request scope")
      (true (not (stringp (gethash "request_id" parsed)))
            "request_id must not be a non-nil string outside request scope"))))
