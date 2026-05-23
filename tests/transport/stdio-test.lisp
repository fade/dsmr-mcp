;;;; tests/transport/stdio-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; TRANS-01: serve-streams string-stream round-trip tests.
;;;; Drives the stdio transport via paired string streams (D-10 fixture shape)
;;;; rather than real OS pipes. Asserts the round-trip, the malformed-line
;;;; skip-and-continue, and the stdout-pollution guard.

(defpackage #:dsmr-mcp/tests/transport/stdio-test
  (:use #:cl #:parachute)
  (:local-nicknames (#:jzon #:com.inuoe.jzon))
  (:import-from #:dsmr-mcp/src/transport/stdio
                #:serve-streams)
  (:import-from #:dsmr-mcp/src/state
                #:make-session)
  (:import-from #:dsmr-mcp/src/tools/base
                #:mcp-tool
                #:mcp-tool-class
                #:tool-handle)
  (:import-from #:dsmr-mcp/tests/support/json-asserts
                #:jsonrpc-error-code
                #:jsonrpc-result
                #:gethash*))

(in-package #:dsmr-mcp/tests/transport/stdio-test)

;;; ---------------------------------------------------------------------------
;;; Helpers
;;; ---------------------------------------------------------------------------

(defun %make-req (method id &optional params-json)
  "Build a JSON-RPC request line string."
  (if id
      (format nil "{\"jsonrpc\":\"2.0\",\"id\":~A,\"method\":\"~A\"~A}"
              id method
              (if params-json (format nil ",\"params\":~A" params-json) ""))
      (format nil "{\"jsonrpc\":\"2.0\",\"method\":\"~A\"}" method)))

(defun %init-req (id)
  "Build a well-formed initialize request line."
  (%make-req "initialize" id
             "{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"stdio-test\",\"version\":\"0\"}}"))

(defun %notif-initialized ()
  "Build a notifications/initialized notification line."
  (%make-req "notifications/initialized" nil))

(defun %tools-list-req (id)
  "Build a tools/list request line."
  (%make-req "tools/list" id))

(defun %run-serve-streams (lines)
  "Run serve-streams on LINES (list of strings) with paired string streams.
Returns (values output-string list-of-parsed-responses)."
  (let* ((input (make-string-input-stream
                 (format nil "~{~A~%~}" lines)))
         (output (make-string-output-stream)))
    (serve-streams input output)
    (let* ((out-str (get-output-stream-string output))
           (split   (remove "" (uiop:split-string out-str
                                                   :separator (list #\Newline))
                             :test #'string=))
           (parsed  (mapcar #'jzon:parse split)))
      (values out-str parsed))))

;;; ---------------------------------------------------------------------------
;;; Tests
;;; ---------------------------------------------------------------------------

(define-test initialize-then-tools-list-round-trip
  "TRANS-01 / ROADMAP criterion 3: a three-line initialize + notification +
tools/list exchange through serve-streams yields exactly two parseable
responses with the correct ids and a JSON array for tools (D-10 fixture).

NOTE: we assert (vectorp tools) not (= 0 (length tools)) because other test
files may have registered in-test stub tools in *tool-classes* by the time
this test runs in the shared image. The canonical zero-tools assertion lives
in the cold-process verify command and in the integration test."
  (multiple-value-bind (out-str parsed)
      (%run-serve-streams (list (%init-req 1)
                                (%notif-initialized)
                                (%tools-list-req 2)))
    (declare (ignore out-str))
    ;; Exactly two responses (notification produces nil).
    (is = 2 (length parsed))
    ;; Initialize response shape.
    (let ((init (first parsed)))
      (is equal "2.0" (gethash "jsonrpc" init))
      (is = 1 (gethash "id" init))
      (true (hash-table-p (gethash "result" init))))
    ;; tools/list response shape.
    (let* ((lst   (second parsed))
           (tools (gethash* lst "result" "tools")))
      (is equal "2.0" (gethash "jsonrpc" lst))
      (is = 2 (gethash "id" lst))
      (true (vectorp tools)))))

(define-test malformed-line-skips-and-continues
  "TRANS-01: an invalid JSON line produces a -32700 response with id null,
and the loop continues to serve subsequent valid lines."
  (multiple-value-bind (out-str parsed)
      (%run-serve-streams (list "not json at all"
                                (%init-req 42)))
    (declare (ignore out-str))
    ;; Two responses: one error, one success.
    (is = 2 (length parsed))
    ;; First: parse error; id is JSON null (jzon parses null as the symbol NULL).
    (let ((err (first parsed)))
      (is eq 'null (gethash "id" err))
      (is = -32700 (jsonrpc-error-code err)))
    ;; Second: well-formed initialize result.
    (let ((ok (second parsed)))
      (is = 42 (gethash "id" ok))
      (true (hash-table-p (gethash "result" ok))))))

(define-test stdout-pollution-guard
  "TRANS-01 / T-03-02: a tool whose tool-handle does (format t ...) must NOT
leak that text onto the OUT stream; all lines on OUT must still parse as
valid JSON."
  ;; Define a tool that leaks to *standard-output*.
  (defclass stdio-leak-tool (mcp-tool)
    ((dsmr-mcp/src/tools/base::name
      :allocation :class :initform "stdio-leak-tool")
     (dsmr-mcp/src/tools/base::description
      :allocation :class :initform "Leaks to stdout for testing.")
     (dsmr-mcp/src/tools/base::input-schema
      :allocation :class :initform '(:object :properties () :required ())))
    (:metaclass mcp-tool-class))
  (c2mop:ensure-finalized (find-class 'stdio-leak-tool))

  (defmethod tool-handle ((tool stdio-leak-tool) id args)
    (declare (ignore args))
    (format t "LEAK")  ; intentionally writes to *standard-output*
    (dsmr-mcp/src/tools/helpers:result id (dsmr-mcp/src/tools/helpers:make-ht "ok" t)))

  ;; Run an initialize + tools/call for the leaking tool.
  (let* ((call-req (format nil
                            "{\"jsonrpc\":\"2.0\",\"id\":99,\"method\":\"tools/call\",~
                             \"params\":{\"name\":\"stdio-leak-tool\",\"arguments\":{}}}"))
         (lines (list (%init-req 1)
                      (%notif-initialized)
                      call-req))
         (input  (make-string-input-stream (format nil "~{~A~%~}" lines)))
         (output (make-string-output-stream)))
    (serve-streams input output)
    (let ((out-str (get-output-stream-string output)))
      ;; "LEAK" must NOT appear on OUT.
      (false (search "LEAK" out-str))
      ;; Every non-empty line on OUT must be valid JSON.
      (let ((split (remove "" (uiop:split-string out-str
                                                  :separator (list #\Newline))
                            :test #'string=)))
        (is >= 2 (length split))
        (dolist (line split)
          (true (hash-table-p (jzon:parse line))))))))
