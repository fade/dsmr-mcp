;;;; tests/tools/reset-local-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Coverage for the rung-1 local-reset compositor (reset-local-backends) and
;;;; the reset-local operator verb.
;;;;
;;;; The compositor tests drive reset-local-backends directly and assert on the
;;;; structured outcome plist and the live side effects (orphan registry drained,
;;;; circuit-breaker map cleared, scope narrowing honored). The verb tests build a
;;;; reset-local-tool instance and assert the tool-handle result hash-table carries
;;;; the per-subsystem counts and returns promptly without blocking.
;;;;
;;;; These tests mutate process-global state (the orphan registry and the
;;;; circuit-breaker map). Each test leaves both empty so it never strands state a
;;;; sibling leaf would observe.

(defpackage #:dsmr-mcp/tests/tools/reset-local-test
  (:use #:cl #:zebra)
  (:import-from #:dsmr-mcp/src/reset
                #:reset-local-backends)
  (:import-from #:dsmr-mcp/src/tools/reset-local
                #:reset-local-tool)
  (:import-from #:dsmr-mcp/src/tools/base
                #:tool-handle)
  (:import-from #:dsmr-mcp/src/orphan
                #:register-orphan
                #:orphan-count)
  (:import-from #:dsmr-mcp/src/hermetic/pool
                #:*circuit-breaker-map*
                #:*pool-lock*)
  (:import-from #:dsmr-mcp/src/state
                #:*mode*
                #:make-session)
  (:import-from #:bordeaux-threads
                #:with-lock-held))

(in-package #:dsmr-mcp/tests/tools/reset-local-test)

;;; ---------------------------------------------------------------------------
;;; Helpers
;;; ---------------------------------------------------------------------------

(defun %drain-breaker ()
  "Empty the circuit-breaker map under its lock."
  (with-lock-held (*pool-lock*)
    (clrhash *circuit-breaker-map*)))

(defun %seed-breaker (session-id)
  "Record a single circuit-breaker trip for SESSION-ID."
  (with-lock-held (*pool-lock*)
    (setf (gethash session-id *circuit-breaker-map*) (get-universal-time))))

(defun %args (&rest kvs)
  "Build an equal-keyed request-args hash-table from KEY VALUE pairs."
  (let ((ht (make-hash-table :test 'equal)))
    (loop for (k v) on kvs by #'cddr do (setf (gethash k ht) v))
    ht))

;;; ---------------------------------------------------------------------------
;;; Compositor — reset-local-backends
;;; ---------------------------------------------------------------------------

(define-test reset-all-clears-orphans
  "A bare reset drains the orphan registry and reports the count cleared."
  (let ((*mode* :hermetic))
    (register-orphan :request-id "reset-orphan-a" :session-id "s" :thread nil
                                                  :mode :hermetic)
    (register-orphan :request-id "reset-orphan-b" :session-id "s" :thread nil
                                                  :mode :hermetic)
    (true (>= (orphan-count) 2) "two orphans registered for the test")
    (let ((outcome (reset-local-backends nil)))
      (is = 0 (orphan-count) "orphan registry fully drained")
      (is eql :ok (getf outcome :status))
      (true (>= (getf outcome :orphans-cleared) 2) "reports the orphans it cleared"))))

(define-test reset-all-clears-circuit-breaker
  "A bare reset clears the whole circuit-breaker map."
  (let ((*mode* :hermetic))
    (%seed-breaker "breaker-sess")
    (let ((outcome (reset-local-backends nil)))
      (is = 0 (hash-table-count *circuit-breaker-map*) "breaker map emptied")
      (true (getf outcome :circuit-breaker-cleared) "reports the breaker cleared"))))

(define-test reset-without-attached-tool-reports-no-attached-reset
  "In hermetic mode there is no attached connection: the reset does not error and
reports attached-reset NIL."
  (let ((*mode* :hermetic))
    (let ((outcome (reset-local-backends nil)))
      (false (getf outcome :attached-reset) "no attached reset off attached mode")
      (is eql :ok (getf outcome :status)))
    (%drain-breaker)))

(define-test attached-scope-leaves-hermetic-state-intact
  "scope=attached narrows to the attached connection: it neither clears the
circuit breaker nor kills any worker."
  (let ((*mode* :attached))
    (%seed-breaker "keep-sess")
    (let ((outcome (reset-local-backends nil :scope "attached")))
      (is = 1 (hash-table-count *circuit-breaker-map*)
          "breaker untouched under attached scope")
      (false (getf outcome :circuit-breaker-cleared) "reports breaker not cleared")
      (is = 0 (getf outcome :workers-killed) "no workers killed under attached scope"))
    (%drain-breaker)))

(define-test hermetic-scope-leaves-attached-untouched
  "scope=hermetic does not drop the attached connection even in attached mode."
  (let ((*mode* :attached))
    (let ((outcome (reset-local-backends nil :scope "hermetic")))
      (false (getf outcome :attached-reset) "hermetic scope leaves attached alone")
      (is eql :ok (getf outcome :status)))
    (%drain-breaker)))

(define-test reset-returns-structured-outcome
  "The outcome is a plist carrying status, a summary string, and per-subsystem
counts."
  (let ((*mode* :hermetic))
    (let ((outcome (reset-local-backends nil)))
      (true (member (getf outcome :status) '(:ok :partial)) "status is :ok or :partial")
      (true (stringp (getf outcome :summary)) "summary is a string")
      (true (integerp (getf outcome :workers-killed)) "workers-killed is an integer")
      (true (integerp (getf outcome :orphans-cleared)) "orphans-cleared is an integer"))))

;;; ---------------------------------------------------------------------------
;;; Verb — reset-local-tool
;;; ---------------------------------------------------------------------------

(defun %call-reset-verb (args)
  "Dispatch tool-handle on a fresh reset-local-tool instance. ARGS is a
request-args hash-table or NIL. Returns the JSON-RPC result payload hash-table."
  (let* ((session (make-session :id "reset-verb-test"))
         (tool (make-instance 'reset-local-tool :session session))
         (response (tool-handle tool "req-reset" args)))
    (gethash "result" response)))

(define-test verb-reset-all-returns-success
  "A no-arg call resets all backends and returns isError NIL with the structured
counts surfaced on the result."
  (let ((*mode* :hermetic))
    (let ((payload (%call-reset-verb nil)))
      (false (gethash "isError" payload) "reset-all is not an error")
      (true (integerp (gethash "workers_killed" payload)) "workers_killed surfaced")
      (true (integerp (gethash "orphans_cleared" payload)) "orphans_cleared surfaced")
      (true (stringp (gethash "type" (aref (gethash "content" payload) 0)))
            "carries a text content block"))))

(define-test verb-scope-attached-kills-no-workers
  "scope=attached narrows the verb to the attached connection: no worker kill,
no breaker clear."
  (let ((*mode* :attached))
    (let ((payload (%call-reset-verb (%args "scope" "attached"))))
      (false (gethash "isError" payload))
      (is = 0 (gethash "workers_killed" payload) "attached scope kills no workers")
      (false (gethash "circuit_breaker_cleared" payload) "attached scope leaves breaker"))))

(define-test verb-target-narrows-worker-kill
  "A target argument narrows the hermetic kill to one session; an unknown session
kills nothing and still succeeds."
  (let ((*mode* :hermetic))
    (let ((payload (%call-reset-verb (%args "target" "no-such-session"))))
      (false (gethash "isError" payload))
      (is = 0 (gethash "workers_killed" payload) "no worker bound to a bogus session"))))

(define-test verb-returns-promptly
  "The reset verb must not block on a backend; it returns well under a second."
  (let ((*mode* :hermetic))
    (let ((start (get-internal-real-time)))
      (%call-reset-verb nil)
      (let ((elapsed-ms (/ (* 1000 (- (get-internal-real-time) start))
                           internal-time-units-per-second)))
        (true (< elapsed-ms 1000) "reset verb returns in under a second")))))
