;;;; tests/attach/repl-eval-attach-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Integration tests for attached-mode repl-eval against an in-process
;;;; Slynk fixture (with-temporary-slynk-listener, port 0).
;;;; Verifies all four ROADMAP success criteria:
;;;;   1. Eval parity with slyme-eval + multi-value return (ATTACH-01, VERB-10, D-06)
;;;;   2. Conditions return structured error context (ATTACH-05, D-04)
;;;;   3. Dead-listener produces isError; next call reconnects (ATTACH-06, D-16)
;;;;   4. Stream output in attached image lands in stdout/stderr fields (ATTACH-04, D-07/D-08)
;;;; Also covers ATTACH-02 (connection reuse) and ATTACH-03 (serial lock).

(defpackage #:dsmr-mcp/tests/attach/repl-eval-attach-test
  (:use #:cl #:parachute)
  (:import-from #:dsmr-mcp/tests/support/slynk-fixture
                #:with-temporary-slynk-listener)
  (:import-from #:dsmr-mcp/src/attach/dispatch
                #:repl-eval-tool
                #:repl-eval-tool-slynk-conn
                #:repl-eval-tool-call-lock
                #:%dispatch-attach
                #:with-attach-dispatch
                #:try-eager-connect
                #:detach-session)
  (:import-from #:dsmr-mcp/src/attach/connection
                #:parse-slynk-attach)
  (:import-from #:dsmr-mcp/src/state
                #:make-session
                #:*current-session-id*
                #:get-tool-instance
                #:session-slynk-attach)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:make-ht)
  (:import-from #:slynk-client
                #:slime-eval
                #:slime-close)
  ;; Shadow parachute:result with helpers:result (used in with-attach-dispatch).
  (:shadowing-import-from #:dsmr-mcp/src/tools/helpers
                          #:result))

(in-package #:dsmr-mcp/tests/attach/repl-eval-attach-test)

;;; Test session helper -------------------------------------------------------

(defun %make-attach-session (id conn)
  "Create a test session for attached-mode tests and install CONN as the
cached slynk-connection on the repl-eval tool instance.

Returns (values SESSION TOOL) with CONN installed on TOOL's slynk-conn slot
so %dispatch-attach reuses the already-open fixture connection.  The session
slynk-attach is set to a syntactically valid (but unreachable) placeholder;
tests that need dispatch to open a real connection manage the slynk-attach
value directly on the session object."
  (let* ((session (make-session :id id :slynk-attach "127.0.0.1:1"))
         (*current-session-id* id)
         (tool (get-tool-instance session "repl-eval")))
    (setf (repl-eval-tool-slynk-conn tool) conn)
    (values session tool)))

;;; Criterion 1 — Eval parity + multi-value return (ATTACH-01, VERB-10, D-06)
;;;
;;; Asserts:
;;;   a) slime-eval of (+ 1 2) returns 3 (direct wire parity)
;;;   b) %dispatch-attach "(+ 1 2)" returns no isError, content contains "3"
;;;   c) "(values 1 2 3)" content contains "1", "2", and "3" (D-06 all-values)

(define-test criterion-1-eval-parity
  "ATTACH-01 / VERB-10 / D-06: repl-eval results are identical to slime-eval.
All returned values are presented (not just the last)."
  (with-temporary-slynk-listener (conn)
    ;; a) Direct slime-eval parity: the in-process listener returns 3 for (+ 1 2).
    (is = 3 (slime-eval '(+ 1 2) conn))
    ;; b) %dispatch-attach parity.
    (multiple-value-bind (session tool)
        (%make-attach-session "crit-1-eval" conn)
      (declare (ignore session))
      (let* ((res    (%dispatch-attach tool (make-ht "code" "(+ 1 2)")))
             (ctext  (gethash "text" (aref (gethash "content" res) 0))))
        (false (gethash "isError" res))
        (true  (search "3" ctext))))
    ;; c) Multi-value: (values 1 2 3) must put all three in content text (D-06).
    (multiple-value-bind (session tool)
        (%make-attach-session "crit-1-multival" conn)
      (declare (ignore session))
      (let* ((res   (%dispatch-attach tool (make-ht "code" "(values 1 2 3)")))
             (ctext (gethash "text" (aref (gethash "content" res) 0))))
        (false (gethash "isError" res))
        (true  (search "1" ctext))
        (true  (search "2" ctext))
        (true  (search "3" ctext))))))

;;; Criterion 2 — Structured error context (ATTACH-05, D-04)
;;;
;;; A condition raised in the attached image must return a structured
;;; error_context hash-table with non-nil condition_type, message, restarts.
;;; On SBCL, frames must be a non-empty vector (pre-unwind handler-bind, D-04).

(define-test criterion-2-structured-error
  "ATTACH-05 / D-04: conditions return condition_type, message, restarts, frames."
  (with-temporary-slynk-listener (conn)
    (multiple-value-bind (session tool)
        (%make-attach-session "crit-2-error" conn)
      (declare (ignore session))
      (let* ((res (%dispatch-attach tool (make-ht "code" "(error \"criterion-2-test\")")))
             (ec  (gethash "error_context" res)))
        ;; error_context is present and populated.
        (true ec)
        (true (gethash "condition_type" ec))
        (true (gethash "message" ec))
        ;; restarts is a non-empty vector (compute-restarts is portable CL).
        (let ((restarts (gethash "restarts" ec)))
          (true (vectorp restarts))
          (true (plusp (length restarts))))
        ;; frames: SBCL-only assertion, handler-bind fires pre-unwind (D-04).
        #+sbcl
        (let ((frames (gethash "frames" ec)))
          (true (vectorp frames))
          (true (plusp (length frames))))))))

;;; Criterion 3 — Fail-closed + reconnect on demand (ATTACH-06, D-16)
;;;
;;; Flow:
;;;   1. Start listener A on port pA; do one successful %dispatch-attach call.
;;;   2. Kill listener A + nil out the cached connection (simulates network drop).
;;;   3. Call %dispatch-attach -> must return isError t; conn slot must be nil.
;;;   4. Start listener B on port pB; point session slynk-attach at pB.
;;;   5. Call %dispatch-attach -> must reconnect and succeed.

(define-test criterion-3-fail-closed-reconnect
  "ATTACH-06 / D-16: dead listener -> isError; next call reconnects on demand."
  (let* ((port-a (slynk:create-server :port 0 :dont-close t))
         (session (make-session :id "crit-3-fail"
                                :slynk-attach (format nil "127.0.0.1:~A" port-a)))
         (*current-session-id* "crit-3-fail")
         (tool   (get-tool-instance session "repl-eval")))
    ;; 1. First call — listener A is live; dispatch should connect + succeed.
    (sleep 0.1)
    (let ((r1 (%dispatch-attach tool (make-ht "code" "(+ 2 2)"))))
      (false (gethash "isError" r1))
      ;; 2. Kill listener A; nil out connection to simulate network drop.
      (let ((conn-a (repl-eval-tool-slynk-conn tool)))
        (ignore-errors (slime-close conn-a))
        (ignore-errors (slynk:stop-server port-a))
        (setf (repl-eval-tool-slynk-conn tool) nil)
        (sleep 0.1)
        ;; 3. Second call to dead server -> isError; conn stays nil after drop.
        (let ((r2 (%dispatch-attach tool (make-ht "code" "(+ 1 1)"))))
          (true (gethash "isError" r2))
          (true (null (repl-eval-tool-slynk-conn tool)))
          ;; 4. Start a fresh listener B on a new port; update slynk-attach.
          (let ((port-b (slynk:create-server :port 0 :dont-close t)))
            (setf (session-slynk-attach session)
                  (format nil "127.0.0.1:~A" port-b))
            (sleep 0.1)
            ;; 5. Third call -> reconnects to listener B and succeeds.
            (let ((r3 (%dispatch-attach tool (make-ht "code" "(+ 3 3)"))))
              (ignore-errors (slynk:stop-server port-b))
              (false (gethash "isError" r3))
              ;; D-17: reconnect note appears in stdout of r3.
              (true (search "reconnected" (gethash "stdout" r3))))))))))

;;; Criterion 4 — Stream isolation (ATTACH-04, D-07/D-08)
;;;
;;; Output written to *terminal-io* / *debug-io* / *trace-output* in the
;;; attached image must land in the "stdout" field of the response.
;;; Output written to *error-output* must land in "stderr".
;;; Neither should reach the test process's real *standard-output*.

(define-test criterion-4-stream-isolation
  "ATTACH-04 / D-07 / D-08: stream output in attached image goes to response
fields, not the test process terminal."
  (with-temporary-slynk-listener (conn)
    (multiple-value-bind (session tool)
        (%make-attach-session "crit-4-streams" conn)
      (declare (ignore session))
      ;; a) *terminal-io* write lands in stdout field.
      (let* ((capture (make-string-output-stream))
             (*standard-output* capture)
             (res (%dispatch-attach tool
                                    (make-ht "code"
                                             "(write-string \"hello-terminal\" *terminal-io*)")))
             (host-stdout (get-output-stream-string capture)))
        ;; stdout field must contain the written text.
        (true (search "hello-terminal" (gethash "stdout" res)))
        ;; Real *standard-output* of the test process must have stayed empty
        ;; (proves isolation — not just capture).
        (is equal "" host-stdout))
      ;; b) *debug-io* write lands in stdout (it is a two-way stream to stdout, D-07).
      (let* ((res (%dispatch-attach tool
                                    (make-ht "code"
                                             "(write-string \"hello-debug\" *debug-io*)"))))
        (true (search "hello-debug" (gethash "stdout" res))))
      ;; c) *error-output* write lands in stderr field.
      (let* ((res (%dispatch-attach tool
                                    (make-ht "code"
                                             "(write-string \"hello-error\" *error-output*)"))))
        (true (search "hello-error" (gethash "stderr" res)))
        ;; Stderr output must NOT bleed into stdout.
        (false (search "hello-error" (gethash "stdout" res "")))))))

;;; ATTACH-03 — Per-session serialisation lock
;;;
;;; Two sequential %dispatch-attach calls on the same session and connection
;;; must both succeed (the lock is acquired and released cleanly; no deadlock).

(define-test attach-03-serial-lock
  "ATTACH-03: sequential %dispatch-attach calls on the same session all succeed."
  (with-temporary-slynk-listener (conn)
    (multiple-value-bind (session tool)
        (%make-attach-session "attach-03-lock" conn)
      (declare (ignore session))
      (let ((r1 (%dispatch-attach tool (make-ht "code" "(+ 1 1)")))
            (r2 (%dispatch-attach tool (make-ht "code" "(+ 2 2)")))
            (r3 (%dispatch-attach tool (make-ht "code" "(+ 3 3)"))))
        (false (gethash "isError" r1))
        (false (gethash "isError" r2))
        (false (gethash "isError" r3))))))

;;; ATTACH-02 — Connection reuse
;;;
;;; Two successive %dispatch-attach calls on the same session must use the
;;; same (eq) connection object — no redundant reconnects.

(define-test attach-02-connection-reuse
  "ATTACH-02: the same connection object is reused across calls in a session."
  (with-temporary-slynk-listener (conn)
    (multiple-value-bind (session tool)
        (%make-attach-session "attach-02-reuse" conn)
      (declare (ignore session))
      ;; Pre-installed conn is the fixture conn.
      (%dispatch-attach tool (make-ht "code" "(+ 1 1)"))
      ;; After the call the slot must still hold the same eq object.
      (is eq conn (repl-eval-tool-slynk-conn tool)))))
