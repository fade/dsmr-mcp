;;;; tests/protocol/strict-initialize-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; MCP-04 / D-04: strict-initialize gate test. Any non-initialize,
;;;; non-ping, non-notifications/initialized request before handshake
;;;; completes must return -32002 "Server not initialized".
;;;;
;;;; This is a dsmr-mcp-specific test: cl-mcp does not gate pre-init
;;;; requests (it dispatches them normally). dsmr-mcp's D-04 is deliberate
;;;; and load-bearing — the -32002 arm in %handle-request is placed BEFORE
;;;; the tools/* and prompts/* arms.

(defpackage #:dsmr-mcp/tests/protocol/strict-initialize-test
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

(in-package #:dsmr-mcp/tests/protocol/strict-initialize-test)

;;; Helpers -------------------------------------------------------------------

(defun %fresh ()
  "Return a fresh, uninitialized session bound to *current-session-id*."
  (values (make-session :id "strict-test") "strict-test"))

(defun %parse-line (line session)
  (jzon:parse (process-json-line line session)))

;;; Tests ---------------------------------------------------------------------

(define-test tools-list-before-initialize-returns-32002
  "D-04: tools/list on a fresh (uninitialized) session returns -32002,
not -32601 or a success response."
  (multiple-value-bind (session sid) (%fresh)
    (let* ((*current-session-id* sid)
           (obj (%parse-line
                  "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}"
                  session)))
      (is = -32002 (jsonrpc-error-code obj)))))

(define-test tools-call-before-initialize-returns-32002
  "D-04: tools/call before initialize returns -32002."
  (multiple-value-bind (session sid) (%fresh)
    (let* ((*current-session-id* sid)
           (obj (%parse-line
                  "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"anything\",\"arguments\":{}}}"
                  session)))
      (is = -32002 (jsonrpc-error-code obj)))))

(define-test prompts-list-before-initialize-returns-32002
  "D-04: prompts/list before initialize returns -32002."
  (multiple-value-bind (session sid) (%fresh)
    (let* ((*current-session-id* sid)
           (obj (%parse-line
                  "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"prompts/list\"}"
                  session)))
      (is = -32002 (jsonrpc-error-code obj)))))

(define-test ping-before-initialize-returns-result
  "D-04: ping is explicitly allowed before initialize (liveness probe).
It must return a success result, NOT a -32002 error."
  (multiple-value-bind (session sid) (%fresh)
    (let* ((*current-session-id* sid)
           (obj (%parse-line
                  "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"ping\"}"
                  session)))
      ;; No error key — ping returns an empty result object.
      (false (gethash "error" obj))
      (true (hash-table-p (gethash "result" obj))))))

(define-test unknown-method-before-initialize-returns-32002
  "D-04: an unknown method before initialize returns -32002 (not -32601).
The strict-init gate fires before the method-not-found arm."
  (multiple-value-bind (session sid) (%fresh)
    (let* ((*current-session-id* sid)
           (obj (%parse-line
                  "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"unknown/method\"}"
                  session)))
      (is = -32002 (jsonrpc-error-code obj)))))

(define-test after-initialize-tools-list-allowed
  "D-04 (negative case): after a successful initialize, tools/list is
allowed and returns a success result (no -32002)."
  (multiple-value-bind (session sid) (%fresh)
    (let ((*current-session-id* sid))
      ;; Initialize first.
      (process-json-line
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"t\",\"version\":\"0\"}}}"
        session)
      ;; Now tools/list should succeed.
      (let ((obj (%parse-line
                   "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}"
                   session)))
        (false (gethash "error" obj))
        (true (hash-table-p (gethash "result" obj)))))))
