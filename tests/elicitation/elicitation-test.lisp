;;;; tests/elicitation/elicitation-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Elicitation capability negotiation, graceful degradation, and the
;;;; server->client request/response round-trip (ENVRC-05..07 and the T-13-01
;;;; spoof/replay guard).
;;;;
;;;;   - capability-set-when-declared: an initialize carrying
;;;;     capabilities.elicitation {} sets session-elicitation-p true.
;;;;   - capability-unset-when-omitted: an initialize with empty capabilities
;;;;     leaves the flag false and still returns a normal result (no error).
;;;;   - response-routes-not-errors: an id-with-result message and no method
;;;;     returns nil from process-json-line (no -32600 envelope).
;;;;   - round-trip-accept: a worker thread blocked in send-elicitation-request
;;;;     returns :accept once the matching-id accept response is routed.
;;;;   - mismatched-id-ignored: a non-matching response id leaves the worker
;;;;     blocked until its bounded timeout, which returns :timeout.

;; Package evolution guard: drop a prior incarnation so a reload picks up the
;; current import/export set rather than stale symbols.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/elicitation/elicitation-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/elicitation/elicitation-test
  (:use #:cl #:parachute)
  (:local-nicknames (#:jzon #:com.inuoe.jzon))
  (:import-from #:dsmr-mcp/src/elicitation
                #:send-elicitation-request
                #:route-elicitation-response
                #:elicitation-response-message-p)
  (:import-from #:dsmr-mcp/src/state
                #:make-session
                #:session-elicitation-p
                #:session-pending-elicitation)
  (:import-from #:dsmr-mcp/src/protocol
                #:process-json-line)
  (:import-from #:bordeaux-threads
                #:make-thread #:join-thread #:thread-alive-p))

(in-package #:dsmr-mcp/tests/elicitation/elicitation-test)

;;; ---------------------------------------------------------------------------
;;; Helpers
;;; ---------------------------------------------------------------------------

(defun %response-ht (id &key (action "accept") content)
  "Build a client elicitation response hash-table: an id, a result carrying
ACTION (and CONTENT when supplied), and no method."
  (let ((result (make-hash-table :test 'equal))
        (msg    (make-hash-table :test 'equal)))
    (setf (gethash "action" result) action)
    (when content
      (setf (gethash "content" result) content))
    (setf (gethash "jsonrpc" msg) "2.0"
          (gethash "id"      msg) id
          (gethash "result"  msg) result)
    msg))

(defun %await-pending (session &key (deadline 5.0))
  "Spin until SESSION has a pending elicitation registered or DEADLINE seconds
elapse. Returns the pending holder or NIL. Closes the notify-before-wait race:
the routing thread must not deliver before the worker has registered its
pending entry."
  (let ((start (get-internal-real-time))
        (limit (* deadline internal-time-units-per-second)))
    (loop for pending = (session-pending-elicitation session)
          when pending return pending
          when (> (- (get-internal-real-time) start) limit) return nil
          do (sleep 0.01))))

;;; ---------------------------------------------------------------------------
;;; Capability negotiation (ENVRC-05 / ENVRC-06)
;;; ---------------------------------------------------------------------------

(define-test capability-set-when-declared
  "An initialize declaring capabilities.elicitation {} sets the flag true."
  (let ((s (make-session :id "cap-set")))
    (process-json-line
     "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{\"elicitation\":{}}}}"
     s)
    (true (session-elicitation-p s)
          "elicitation flag should be true after a declaring initialize")))

(define-test capability-unset-when-omitted
  "An initialize with empty capabilities leaves the flag false and returns a
normal result (no error)."
  (let* ((s (make-session :id "cap-unset"))
         (resp (process-json-line
                "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{}}}"
                s)))
    (false (session-elicitation-p s)
           "elicitation flag should stay false when the capability is omitted")
    (true (stringp resp) "initialize should return a response line")
    (let ((parsed (jzon:parse resp)))
      (true (nth-value 1 (gethash "result" parsed))
            "initialize response should be a result, not an error")
      (false (nth-value 1 (gethash "error" parsed))
             "initialize response should carry no error object"))))

;;; ---------------------------------------------------------------------------
;;; Response routing / graceful degradation (ENVRC-07)
;;; ---------------------------------------------------------------------------

(define-test response-routes-not-errors
  "An id-with-result message and no method returns nil (no -32600 envelope)."
  (let ((s (make-session :id "route")))
    (is eq nil
        (process-json-line
         "{\"jsonrpc\":\"2.0\",\"id\":99,\"result\":{\"action\":\"cancel\"}}"
         s)
        "an elicitation response should produce no wire response")))

;;; ---------------------------------------------------------------------------
;;; Round-trip (T-13-01 plus the accept/timeout paths)
;;; ---------------------------------------------------------------------------

(define-test round-trip-accept
  "A worker blocked in send-elicitation-request returns :accept once the
matching-id accept response is routed to the session."
  (let* ((s   (make-session :id "round-trip"))
         (out (make-string-output-stream))
         (result-box (list nil))
         (worker
           (make-thread
            (lambda ()
              (setf (car result-box)
                    (multiple-value-list
                     (send-elicitation-request
                      s out "create .envrc?"
                      (make-hash-table :test 'equal)
                      :timeout 5))))
            :name "elicit-round-trip-worker")))
    (let ((pending (%await-pending s)))
      (true pending "worker should register a pending elicitation")
      (let ((id (first pending)))
        (true (route-elicitation-response s (%response-ht id :action "accept"))
              "routing a matching-id accept should notify the waiter")))
    (handler-case (sb-ext:with-timeout 5 (join-thread worker))
      (sb-ext:timeout ()
        (when (thread-alive-p worker)
          (ignore-errors (bordeaux-threads:destroy-thread worker)))
        (fail "worker did not return after the response was routed")))
    (is eq :accept (first (car result-box))
        "send-elicitation-request should return :accept")))

(define-test mismatched-id-ignored
  "A non-matching response id leaves the worker blocked until its bounded
timeout, which returns :timeout (T-13-01 spoof/replay guard)."
  (let* ((s   (make-session :id "mismatch"))
         (out (make-string-output-stream))
         (result-box (list nil))
         (worker
           (make-thread
            (lambda ()
              (setf (car result-box)
                    (multiple-value-list
                     (send-elicitation-request
                      s out "create .envrc?"
                      (make-hash-table :test 'equal)
                      :timeout 1))))
            :name "elicit-mismatch-worker")))
    (let ((pending (%await-pending s)))
      (true pending "worker should register a pending elicitation")
      (let ((id (first pending)))
        ;; Route a response whose id does NOT match the pending request.
        (false (route-elicitation-response s (%response-ht (+ id 1000)
                                                           :action "accept"))
               "a non-matching id must not notify the waiter")))
    (handler-case (sb-ext:with-timeout 5 (join-thread worker))
      (sb-ext:timeout ()
        (when (thread-alive-p worker)
          (ignore-errors (bordeaux-threads:destroy-thread worker)))
        (fail "worker did not time out after a mismatched-id response")))
    (is eq :timeout (first (car result-box))
        "send-elicitation-request should return :timeout when no matching response arrives")))
