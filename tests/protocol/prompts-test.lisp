;;;; tests/protocol/prompts-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; MCP-03 / D-03: prompts surface tests.
;;;; - prompts/list returns result.prompts as a length-0 vector (Phase 1 stub).
;;;; - prompts/get for any name returns -32602 "Unknown prompt: ..." (stub).
;;;;
;;;; Phase 1 ships no actual prompt files. The surface is in scope and the
;;;; stubs prove the capability is advertised and the wire is correct.

(defpackage #:dsmr-mcp/tests/protocol/prompts-test
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

(in-package #:dsmr-mcp/tests/protocol/prompts-test)

;;; Helpers -------------------------------------------------------------------

(defun %init+prompts-list (session)
  "Initialize SESSION then call prompts/list. Returns the parsed response."
  (process-json-line
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"t\",\"version\":\"0\"}}}"
    session)
  (jzon:parse
    (process-json-line
      "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"prompts/list\"}"
      session)))

;;; Tests ---------------------------------------------------------------------

(define-test prompts-list-result-prompts-is-vector
  "D-03/MCP-03: result.prompts is a simple-vector. jzon encodes vectors
as JSON arrays, so [] arrives as #() on the wire."
  (let* ((session (make-session :id "pt-vec"))
         (*current-session-id* "pt-vec"))
    (let* ((obj (%init+prompts-list session))
           (prompts (gethash* obj "result" "prompts")))
      (true (vectorp prompts)))))

(define-test prompts-list-result-is-empty
  "D-03/MCP-03: Phase 1 stub returns an empty prompts array (length 0)."
  (let* ((session (make-session :id "pt-empty"))
         (*current-session-id* "pt-empty"))
    (let* ((obj (%init+prompts-list session))
           (prompts (gethash* obj "result" "prompts")))
      (is = 0 (length prompts)))))

(define-test prompts-get-returns-32602
  "D-03/MCP-03: prompts/get for any name returns -32602 with a message
naming the requested prompt (Phase 1 stub — no prompt files shipped)."
  (let* ((session (make-session :id "pt-get"))
         (*current-session-id* "pt-get"))
    ;; Initialize first.
    (process-json-line
      "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"t\",\"version\":\"0\"}}}"
      session)
    (let* ((resp (process-json-line
                   "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"prompts/get\",\"params\":{\"name\":\"repl-driven-development\"}}"
                   session))
           (obj (jzon:parse resp)))
      (is = -32602 (jsonrpc-error-code obj)))))

(define-test prompts-get-message-names-prompt
  "D-03: the -32602 error message from prompts/get includes the prompt name."
  (let* ((session (make-session :id "pt-msg"))
         (*current-session-id* "pt-msg"))
    (process-json-line
      "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"t\",\"version\":\"0\"}}}"
      session)
    (let* ((resp (process-json-line
                   "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"prompts/get\",\"params\":{\"name\":\"my-prompt\"}}"
                   session))
           (obj (jzon:parse resp))
           (msg (gethash* obj "error" "message")))
      (true (and msg (search "my-prompt" msg))))))
