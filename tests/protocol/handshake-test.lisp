;;;; tests/protocol/handshake-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Initialize round-trip test. Verifies that process-json-line on a
;;;; well-formed initialize request returns the correct JSON-RPC 2.0 shape
;;;; with protocolVersion, capabilities (tools + prompts), and serverInfo.

(defpackage #:dsmr-mcp/tests/protocol/handshake-test
  (:use #:cl #:zebra)
  (:local-nicknames (#:jzon #:com.inuoe.jzon))
  (:import-from #:dsmr-mcp/src/protocol
                #:process-json-line)
  (:import-from #:dsmr-mcp/src/state
                #:make-session
                #:*current-session-id*
                #:initialized-p
                #:protocol-version)
  (:import-from #:dsmr-mcp/tests/support/json-asserts
                #:jsonrpc-error-code
                #:jsonrpc-result
                #:gethash*))

(in-package #:dsmr-mcp/tests/protocol/handshake-test)

;;; Helpers -------------------------------------------------------------------

(defun %init-line (id &optional (version "2025-06-18"))
  "Build a well-formed initialize JSON-RPC request line."
  (format nil
          "{\"jsonrpc\":\"2.0\",\"id\":~A,\"method\":\"initialize\",~
           \"params\":{\"protocolVersion\":\"~A\",\"capabilities\":{},~
           \"clientInfo\":{\"name\":\"test-client\",\"version\":\"1.0\"}}}"
          id version))

(defun %parse-response (line session)
  "Call process-json-line and parse the result."
  (let ((resp (process-json-line line session)))
    (and resp (jzon:parse resp))))

;;; Tests ---------------------------------------------------------------------

(define-test initialize-round-trip
  "A well-formed initialize request returns a JSON-RPC 2.0 success response
with the correct envelope shape."
  (let* ((session (make-session :id "handshake-test"))
         (*current-session-id* "handshake-test")
         (obj (%parse-response (%init-line 1) session)))
    ;; Envelope shape.
    (is equal "2.0" (gethash "jsonrpc" obj))
    (is = 1 (gethash "id" obj))
    (true (hash-table-p (gethash "result" obj)))
    ;; No error key.
    (false (gethash "error" obj))))

(define-test initialize-result-has-protocol-version
  "result.protocolVersion echoes the requested supported version."
  (let* ((session (make-session :id "handshake-proto"))
         (*current-session-id* "handshake-proto")
         (obj (%parse-response (%init-line 2 "2025-06-18") session))
         (result (gethash "result" obj)))
    (is equal "2025-06-18" (gethash "protocolVersion" result))))

(define-test initialize-result-has-capabilities-tools-and-prompts
  "result.capabilities contains both tools and prompts keys with listChanged
values. Diverges from cl-mcp which only advertises tools."
  (let* ((session (make-session :id "handshake-caps"))
         (*current-session-id* "handshake-caps")
         (obj (%parse-response (%init-line 3) session))
         (caps (gethash* obj "result" "capabilities")))
    (true (hash-table-p caps))
    (true (hash-table-p (gethash "tools" caps)))
    (true (hash-table-p (gethash "prompts" caps)))))

(define-test initialize-result-has-server-info
  "result.serverInfo has name and version keys."
  (let* ((session (make-session :id "handshake-info"))
         (*current-session-id* "handshake-info")
         (obj (%parse-response (%init-line 4) session))
         (sinfo (gethash* obj "result" "serverInfo")))
    (true (hash-table-p sinfo))
    (is equal "dsmr-mcp" (gethash "name" sinfo))
    (true (stringp (gethash "version" sinfo)))))

(define-test initialize-marks-session-initialized
  "After a successful initialize, the session's initialized-p is T and
protocol-version is set."
  (let* ((session (make-session :id "handshake-state"))
         (*current-session-id* "handshake-state"))
    (process-json-line (%init-line 5) session)
    (true (initialized-p session))
    (is equal "2025-06-18" (protocol-version session))))

(define-test notification-returns-nil
  "A JSON-RPC notification (no id) returns NIL, not a string."
  (let* ((session (make-session :id "handshake-notify"))
         (*current-session-id* "handshake-notify")
         (notif "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}"))
    (is eq nil (process-json-line notif session))))

(define-test empty-line-returns-nil
  "An empty (or whitespace-only) line returns NIL without error."
  (let* ((session (make-session :id "handshake-empty"))
         (*current-session-id* "handshake-empty"))
    (is eq nil (process-json-line "" session))
    (is eq nil (process-json-line "   " session))
    (is eq nil (process-json-line (format nil "~C" #\Newline) session))))
