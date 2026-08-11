;;;; tests/dispatch/result-content-guard-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; The dispatcher's result-content guard: every tools/call result must
;;;; leave handle-tools-call with a content block array, because the client
;;;; renders a result through content alone — a structured-fields-only
;;;; result displays as nothing, silently.

(defpackage #:dsmr-mcp/tests/dispatch/result-content-guard-test
  (:use #:cl #:zebra)
  (:local-nicknames (#:jzon #:com.inuoe.jzon))
  (:import-from #:dsmr-mcp/src/state
                #:make-session
                #:*current-session-id*
                #:*mode*)
  (:import-from #:dsmr-mcp/src/dispatch
                #:handle-tools-call
                #:%ensure-rendered-result
                #:*synthesized-content-max-chars*)
  (:import-from #:dsmr-mcp/src/tools/base
                #:mcp-tool
                #:mcp-tool-class
                #:tool-handle
                #:*tool-classes*)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:make-ht
                #:text-content)
  (:shadowing-import-from #:dsmr-mcp/src/tools/helpers
                          #:result)
  ;; Dependency only: registers the lisp-check-parens tool for the
  ;; end-to-end render test below.
  (:import-from #:dsmr-mcp/src/tools/lisp-check-parens))

(in-package #:dsmr-mcp/tests/dispatch/result-content-guard-test)

;;; Stub tool returning a structured-fields-only result — the shape that
;;; used to render as nothing.

(defclass bare-result-tool (mcp-tool)
  ((dsmr-mcp/src/tools/base::name
    :allocation :class :initform "bare-result-tool")
   (dsmr-mcp/src/tools/base::description
    :allocation :class :initform "Returns structured fields without content.")
   (dsmr-mcp/src/tools/base::input-schema
    :allocation :class :initform '(:object :properties () :required ())))
  (:metaclass mcp-tool-class))
(c2mop:ensure-finalized (find-class 'bare-result-tool))

;; The metaclass registered the stub globally at finalization. Remove it:
;; a test fixture must not be visible to anything that walks the registry
;; (tools/list, the docs/tools.org parity renderer). The tests below hand
;; the dispatcher a registry COPY carrying the stub, scoped dynamically.
(remhash "bare-result-tool" *tool-classes*)

(defparameter *bare-result-payload* nil
  "Payload the stub returns; set per test.")

(defmethod tool-handle ((tool bare-result-tool) id args)
  (declare (ignore args))
  (result id *bare-result-payload*))

(defun %call-with-stub-registry (thunk)
  "Run THUNK with *tool-classes* bound to a copy that includes the stub.
The global registry never carries the fixture."
  (let ((reg (make-hash-table :test 'equal)))
    (maphash (lambda (k v) (setf (gethash k reg) v)) *tool-classes*)
    (setf (gethash "bare-result-tool" reg) (find-class 'bare-result-tool))
    (let ((*tool-classes* reg))
      (funcall thunk))))

(defun %call-bare-tool (payload)
  "Drive PAYLOAD through handle-tools-call via the stub tool.
Returns the result hash-table of the response envelope."
  (%call-with-stub-registry
   (lambda ()
     (let* ((*bare-result-payload* payload)
            (*mode* :attached)
            (*current-session-id* "content-guard")
            (session (make-session :id "content-guard"))
            (resp (handle-tools-call
                   session 7
                   (let ((p (make-ht "name" "bare-result-tool")))
                     (setf (gethash "arguments" p) (make-ht))
                     p))))
       (gethash "result" resp)))))

(define-test guard-synthesizes-content-for-bare-result
  "A tools/call result without content gets a synthesized text block
rendering the structured fields; the fields themselves are untouched."
  (let ((res (%call-bare-tool (make-ht "ok" t "kind" "demo"))))
    (true (hash-table-p res))
    ;; Structured fields intact.
    (is eq t (gethash "ok" res))
    (is equal "demo" (gethash "kind" res))
    ;; Synthesized content present and mentions the fields.
    (let ((content (gethash "content" res)))
      (true (vectorp content))
      (let ((text (gethash "text" (aref content 0))))
        (true (search "\"kind\"" text))
        (true (search "demo" text))))))

(define-test guard-bounds-synthesized-content
  "Synthesized text is capped: a large structured payload yields a content
block bounded near *synthesized-content-max-chars* with an elision marker,
never the full rendering."
  (let* ((big (make-string (* 4 *synthesized-content-max-chars*)
                           :initial-element #\x))
         (res (%call-bare-tool (make-ht "blob" big)))
         (text (gethash "text" (aref (gethash "content" res) 0))))
    (true (< (length text) (+ *synthesized-content-max-chars* 100)))
    (true (search "[elided" text))
    ;; The structured field still carries the full value.
    (is = (length big) (length (gethash "blob" res)))))

(define-test guard-passes-through-existing-content
  "A result that already carries content is not modified."
  (let* ((content (text-content "already rendered"))
         (res (%call-bare-tool (make-ht "ok" t "content" content))))
    (is eq content (gethash "content" res))))

(define-test guard-ignores-error-envelopes
  "JSON-RPC error envelopes (e.g. tool-not-found) pass through untouched."
  (let* ((*mode* :attached)
         (*current-session-id* "content-guard-err")
         (session (make-session :id "content-guard-err"))
         (resp (handle-tools-call
                session 8
                (let ((p (make-ht "name" "no-such-tool-xyzzy")))
                  (setf (gethash "arguments" p) (make-ht))
                  p))))
    (true (gethash "error" resp))
    (false (gethash "result" resp))))

(define-test check-parens-imbalance-renders
  "The defect's decisive repro: an unbalanced snippet must yield a content
text that names the imbalance — previously the result carried only
structured fields and the client displayed nothing."
  (let* ((*mode* :attached)
         (*current-session-id* "content-guard-cp")
         (session (make-session :id "content-guard-cp"))
         (resp (handle-tools-call
                session 9
                (let ((p (make-ht "name" "lisp-check-parens")))
                  (setf (gethash "arguments" p)
                        (make-ht "code" "(defun broken (x"))
                  p)))
         (res (gethash "result" resp))
         (text (gethash "text" (aref (gethash "content" res) 0))))
    (false (gethash "ok" res))
    (true (search "unclosed" text))
    (true (search "line 1" text))
    (true (search "column" text)))
  ;; Balanced input renders too.
  (let* ((*mode* :attached)
         (*current-session-id* "content-guard-cp2")
         (session (make-session :id "content-guard-cp2"))
         (resp (handle-tools-call
                session 10
                (let ((p (make-ht "name" "lisp-check-parens")))
                  (setf (gethash "arguments" p) (make-ht "code" "(+ 1 2)"))
                  p)))
         (res (gethash "result" resp)))
    (is eq t (gethash "ok" res))
    (is equal "balanced"
        (gethash "text" (aref (gethash "content" res) 0)))))
