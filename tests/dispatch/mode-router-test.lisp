;;;; tests/dispatch/mode-router-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Integration tests for the Phase 3 mode router in handle-tools-call.
;;;; Covers ROADMAP criterion 3: with *MODE* :hermetic (before the Phase 4
;;;; hermetic backend lands), a tools/call returns a structured isError per
;;;; call AND logs dispatch.mode-not-ready to stderr, without crashing.
;;;;
;;;; The router branches ONLY on :hermetic; the :attached path is the
;;;; unchanged Phase 2 dispatch (not re-tested here — covered by
;;;; tests/attach/repl-eval-attach-test.lisp).

(defpackage #:dsmr-mcp/tests/dispatch/mode-router-test
  (:use #:cl #:parachute)
  (:local-nicknames (#:jzon #:com.inuoe.jzon))
  (:import-from #:dsmr-mcp/src/state
                #:make-session
                #:*current-session-id*
                #:*mode*)
  (:import-from #:dsmr-mcp/src/dispatch
                #:handle-tools-call)
  (:import-from #:dsmr-mcp/src/log
                #:*log-level*
                #:*log-session-id*
                #:*log-request-id*
                #:configure-log4cl-for-server)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:make-ht))

(in-package #:dsmr-mcp/tests/dispatch/mode-router-test)

;;; ---------------------------------------------------------------------------
;;; Criterion 3 — hermetic mode returns isError + logs, no crash (D-05)
;;; ---------------------------------------------------------------------------

(define-test criterion-3-hermetic-returns-iserror
  "Criterion 3 / D-05: with *mode* :hermetic, a tools/call returns an envelope
whose result has isError=t and a non-empty content naming the Phase-4 deferral.
The router fires before tool lookup so the mode-not-ready message surfaces
regardless of the requested tool name."
  (let* ((*mode* :hermetic)
         (capture (make-string-output-stream))
         (*error-output* capture)
         (*log-level* :debug)
         (session (make-session :id "hermetic-iserror"))
         (*current-session-id* "hermetic-iserror"))
    (configure-log4cl-for-server :debug)
    (let* ((env (handle-tools-call
                 session "req-1"
                 (make-ht "name" "repl-eval"
                          "arguments" (make-ht "code" "(+ 1 2)"))))
           (payload (gethash "result" env)))
      ;; A success envelope (jsonrpc/id/result), not an rpc-error.
      (true payload)
      (true (gethash "isError" payload))
      ;; content is a non-empty vector of text-content objects.
      (let ((content (gethash "content" payload)))
        (true (vectorp content))
        (true (plusp (length content)))
        ;; The message names the deferral / requested tool.
        (let ((text (gethash "text" (aref content 0))))
          (true (search "hermetic" (string-downcase text)))
          (true (search "repl-eval" text)))))))

(define-test criterion-3-hermetic-miss-is-logged
  "Criterion 3 / D-05: the hermetic-not-ready miss is logged via log-event :warn
as a dispatch.mode-not-ready JSON line on *error-output* (the log4cl appender is
pinned to stderr — T-03-LOG-01), in addition to being returned."
  (let* ((*mode* :hermetic)
         (capture (make-string-output-stream))
         (*error-output* capture)
         (*log-level* :debug)
         (session (make-session :id "hermetic-logged"))
         (*current-session-id* "hermetic-logged"))
    (configure-log4cl-for-server :debug)
    (handle-tools-call session "req-2"
                       (make-ht "name" "repl-eval"
                                "arguments" (make-ht "code" "(+ 1 2)")))
    (let ((stderr (get-output-stream-string capture)))
      ;; Something landed on stderr (the log line did not go to stdout).
      (true (plusp (length stderr)))
      ;; The JSON log line names the mode-not-ready event.
      (true (search "dispatch.mode-not-ready" stderr))
      ;; And parses as a JSON object carrying that event in its msg field.
      (let* ((line   (string-trim '(#\Newline #\Return #\Space) stderr))
             (parsed (jzon:parse line)))
        (is string= "warn" (gethash "level" parsed))
        (true (search "dispatch.mode-not-ready" (gethash "msg" parsed)))))))

(define-test server-does-not-crash
  "Criterion 3 / T-03-MODE-01: the hermetic call returns normally — no unhandled
error escapes handle-tools-call, so the serve loop stays up regardless of
DSMR_MODE.  Also exercises an unknown tool name under :hermetic: the router
must still surface mode-not-ready rather than a -32601."
  (let* ((*mode* :hermetic)
         (capture (make-string-output-stream))
         (*error-output* capture)
         (*log-level* :debug)
         (session (make-session :id "hermetic-nocrash"))
         (*current-session-id* "hermetic-nocrash"))
    (configure-log4cl-for-server :debug)
    ;; A normal, known tool name returns without signalling.
    (finish (handle-tools-call
             session "req-3"
             (make-ht "name" "repl-eval"
                      "arguments" (make-ht "code" "(+ 1 2)"))))
    ;; An UNKNOWN tool name under :hermetic still surfaces mode-not-ready
    ;; (the router fires before tool lookup), not a -32601 error envelope.
    (let* ((env (handle-tools-call
                 session "req-4"
                 (make-ht "name" "no-such-tool" "arguments" (make-ht))))
           (payload (gethash "result" env)))
      (true payload)
      (true (gethash "isError" payload))
      ;; It is the success-shaped isError envelope, NOT an rpc-error.
      (false (gethash "error" env)))))
