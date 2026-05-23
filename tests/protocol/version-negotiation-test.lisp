;;;; tests/protocol/version-negotiation-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; MCP-02: version negotiation matrix test.
;;;; D-01: supported versions are "2025-06-18" and "2025-03-26" only.
;;;; D-02: unsupported versions return server-highest in result (NOT an
;;;;       error). This diverges from cl-mcp which returns -32602.

(defpackage #:dsmr-mcp/tests/protocol/version-negotiation-test
  (:use #:cl #:parachute)
  (:local-nicknames (#:jzon #:com.inuoe.jzon))
  (:import-from #:dsmr-mcp/src/protocol
                #:process-json-line)
  (:import-from #:dsmr-mcp/src/state
                #:make-session
                #:*current-session-id*)
  (:import-from #:dsmr-mcp/tests/support/json-asserts
                #:jsonrpc-error-code
                #:jsonrpc-result
                #:gethash*))

(in-package #:dsmr-mcp/tests/protocol/version-negotiation-test)

;;; Helpers -------------------------------------------------------------------

(defun %negotiate (client-version)
  "Initialize a fresh session with CLIENT-VERSION and return the parsed
response. Binds *current-session-id* for the call."
  (let* ((session (make-session :id "version-test"))
         (*current-session-id* "version-test")
         (line (format nil
                       "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",~
                        \"params\":{\"protocolVersion\":\"~A\",\"capabilities\":{},~
                        \"clientInfo\":{\"name\":\"t\",\"version\":\"0\"}}}"
                       client-version)))
    (jzon:parse (process-json-line line session))))

(defun %negotiated-version (client-version)
  "Return the negotiated protocolVersion string from an initialize call."
  (gethash* (%negotiate client-version) "result" "protocolVersion"))

(defun %is-error-response (obj)
  "True if OBJ is a JSON-RPC error response (has an \"error\" key)."
  (and (hash-table-p obj) (gethash "error" obj)))

;;; Tests — one per matrix row (D-01/D-02) ------------------------------------

(define-test supported-version-2025-06-18-echoed
  "D-01/D-02: requesting \"2025-06-18\" returns \"2025-06-18\" in result."
  (is equal "2025-06-18" (%negotiated-version "2025-06-18")))

(define-test supported-version-2025-03-26-echoed
  "D-01/D-02: requesting \"2025-03-26\" returns \"2025-03-26\" in result."
  (is equal "2025-03-26" (%negotiated-version "2025-03-26")))

(define-test dropped-version-2024-11-05-returns-highest
  "D-01/D-02: \"2024-11-05\" is not in the supported set (D-01 dropped it).
Response must be a RESULT (not an error) containing the server's highest
version \"2025-06-18\". This diverges from cl-mcp which returns -32602."
  (let ((obj (%negotiate "2024-11-05")))
    ;; Must be a result, NOT an error.
    (false (%is-error-response obj))
    ;; The negotiated version is the server's highest.
    (is equal "2025-06-18" (gethash* obj "result" "protocolVersion"))))

(define-test future-version-returns-highest
  "D-01/D-02: a future version string unknown to this server returns a RESULT
with the server's highest version. Clients may proceed if they choose to."
  (let ((obj (%negotiate "2099-01-01")))
    (false (%is-error-response obj))
    (is equal "2025-06-18" (gethash* obj "result" "protocolVersion"))))

(define-test empty-protocol-version-returns-highest
  "D-02: when protocolVersion is an empty string the server picks its highest."
  (let ((obj (%negotiate "")))
    (false (%is-error-response obj))
    (is equal "2025-06-18" (gethash* obj "result" "protocolVersion"))))
