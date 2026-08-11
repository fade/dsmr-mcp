;;;; tests/bus-listener-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Coverage for the background bus listener's pure command core,
;;;; %handle-restart-message. The core parses one restart-command envelope,
;;;; validates it against this server's own namespace and bus name, and
;;;; dispatches to injected thunks — so every branch is unit-testable with no
;;;; bus, no thread, and no real process exit.
;;;;
;;;; The six branches:
;;;;   :reset                     rung 1, namespace+target match  -> on-reset fired once
;;;;   :reexec                    rung 3, namespace+target match  -> on-reexec fired once
;;;;   :ignored-foreign-namespace namespace differs (the D-05 cross-namespace block)
;;;;   :ignored-wrong-target      target differs from this server's name
;;;;   :ignored-type              not a restart command (or an unknown rung)
;;;;   :ignored-malformed         not parseable JSON (no signal escapes)
;;;;
;;;; The rung-3 branch is exercised with a recording thunk — the real
;;;; %trigger-restart-exit would terminate the test image, so it is never called
;;;; here.

;; Package evolution guard: drop a prior incarnation so a reload picks up the
;; current import/export set rather than stale symbols.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/bus-listener-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/bus-listener-test
  (:use #:cl #:zebra)
  (:import-from #:dsmr-mcp/src/bus-listener
                #:%handle-restart-message))

(in-package #:dsmr-mcp/tests/bus-listener-test)

;;; ---------------------------------------------------------------------------
;;; Envelopes
;;; ---------------------------------------------------------------------------

(defun %envelope (&key (type "dsmr:restart") (namespace "ns") (target "me")
                       (rung 1) (scope "null"))
  "Build a restart-command JSON string. SCOPE is spliced literally, so pass
\"null\" for the JSON null sentinel or \"\\\"attached\\\"\" for a JSON string."
  (format nil
          "{\"type\":~S,\"namespace\":~S,\"target\":~S,\"rung\":~D,\"scope\":~A}"
          type namespace target rung scope))

;;; ---------------------------------------------------------------------------
;;; Dispatch branches
;;; ---------------------------------------------------------------------------

(define-test rung-1-match-dispatches-a-local-reset
  "A well-formed rung-1 envelope whose namespace and target match this server
returns :reset and fires the reset thunk exactly once; the reexec thunk never
fires."
  (let ((reset-scopes '())
        (reexec-count 0))
    (let ((outcome (%handle-restart-message
                    (%envelope :rung 1 :scope "null")
                    "ns" "me"
                    :on-reset (lambda (scope) (push scope reset-scopes))
                    :on-reexec (lambda () (incf reexec-count)))))
      (is eql :reset outcome "rung-1 match returns :reset")
      (is = 1 (length reset-scopes) "on-reset fired exactly once")
      (false (first reset-scopes) "a null scope reaches the thunk as nil")
      (is = 0 reexec-count "on-reexec did not fire"))))

(define-test rung-1-passes-an-explicit-scope-through
  "An explicit scope rides the envelope and reaches the reset thunk verbatim."
  (let ((reset-scopes '()))
    (%handle-restart-message
     (%envelope :rung 1 :scope "\"attached\"")
     "ns" "me"
     :on-reset (lambda (scope) (push scope reset-scopes))
     :on-reexec (lambda () nil))
    (is string= "attached" (first reset-scopes)
        "an explicit scope reaches the reset thunk")))

(define-test rung-3-match-dispatches-a-reexec
  "A rung-3 envelope matching namespace and target returns :reexec and fires the
reexec thunk exactly once; the reset thunk never fires. The real exit primitive
is NOT called — a recording thunk stands in for it."
  (let ((reset-count 0)
        (reexec-count 0))
    (let ((outcome (%handle-restart-message
                    (%envelope :rung 3 :scope "null")
                    "ns" "me"
                    :on-reset (lambda (scope) (declare (ignore scope)) (incf reset-count))
                    :on-reexec (lambda () (incf reexec-count)))))
      (is eql :reexec outcome "rung-3 match returns :reexec")
      (is = 1 reexec-count "on-reexec fired exactly once")
      (is = 0 reset-count "on-reset did not fire"))))

(define-test foreign-namespace-is-rejected
  "An envelope from a different namespace is ignored and fires neither thunk —
the cross-namespace block."
  (let ((reset-count 0)
        (reexec-count 0))
    (let ((outcome (%handle-restart-message
                    (%envelope :namespace "other" :target "me" :rung 1)
                    "ns" "me"
                    :on-reset (lambda (s) (declare (ignore s)) (incf reset-count))
                    :on-reexec (lambda () (incf reexec-count)))))
      (is eql :ignored-foreign-namespace outcome
          "a foreign namespace is rejected")
      (is = 0 reset-count "no reset on a foreign namespace")
      (is = 0 reexec-count "no reexec on a foreign namespace"))))

(define-test wrong-target-is-ignored
  "An envelope addressed to a different agent name in this namespace is ignored
and fires neither thunk."
  (let ((reset-count 0)
        (reexec-count 0))
    (let ((outcome (%handle-restart-message
                    (%envelope :namespace "ns" :target "someone-else" :rung 1)
                    "ns" "me"
                    :on-reset (lambda (s) (declare (ignore s)) (incf reset-count))
                    :on-reexec (lambda () (incf reexec-count)))))
      (is eql :ignored-wrong-target outcome "a wrong target is ignored")
      (is = 0 reset-count "no reset on a wrong target")
      (is = 0 reexec-count "no reexec on a wrong target"))))

(define-test non-restart-type-is-ignored
  "A message whose type is not the restart discriminator is ignored and fires
neither thunk."
  (let ((reset-count 0)
        (reexec-count 0))
    (let ((outcome (%handle-restart-message
                    (%envelope :type "chat" :rung 1)
                    "ns" "me"
                    :on-reset (lambda (s) (declare (ignore s)) (incf reset-count))
                    :on-reexec (lambda () (incf reexec-count)))))
      (is eql :ignored-type outcome "a non-restart type is ignored")
      (is = 0 reset-count "no reset on a non-restart type")
      (is = 0 reexec-count "no reexec on a non-restart type"))))

(define-test unknown-rung-is-ignored
  "A restart command naming a rung this listener does not act on is ignored and
fires neither thunk."
  (let ((reset-count 0)
        (reexec-count 0))
    (let ((outcome (%handle-restart-message
                    (%envelope :rung 2)
                    "ns" "me"
                    :on-reset (lambda (s) (declare (ignore s)) (incf reset-count))
                    :on-reexec (lambda () (incf reexec-count)))))
      (is eql :ignored-type outcome "an unknown rung is ignored")
      (is = 0 reset-count "no reset on an unknown rung")
      (is = 0 reexec-count "no reexec on an unknown rung"))))

(define-test malformed-json-is-ignored-without-signalling
  "A message that is not parseable JSON returns :ignored-malformed and does not
signal — a single bad message can never crash the listener."
  (let ((reset-count 0)
        (reexec-count 0))
    (let ((outcome (%handle-restart-message
                    "this is not json {{{"
                    "ns" "me"
                    :on-reset (lambda (s) (declare (ignore s)) (incf reset-count))
                    :on-reexec (lambda () (incf reexec-count)))))
      (is eql :ignored-malformed outcome
          "malformed input returns :ignored-malformed without signalling")
      (is = 0 reset-count "no reset on malformed input")
      (is = 0 reexec-count "no reexec on malformed input"))))
