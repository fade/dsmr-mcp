;;;; tests/attach/repl-eval-attach-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Integration tests for attached-mode repl-eval against an in-process
;;;; Slynk fixture (with-temporary-slynk-listener, port 0).
;;;; Verifies four integration criteria:
;;;;   1. Eval parity with slime-eval + multi-value return
;;;;   2. Conditions return structured error context
;;;;   3. Dead-listener produces isError; next call reconnects
;;;;   4. Stream output in attached image lands in stdout/stderr fields
;;;; Also covers connection reuse and serial call-lock behaviour.

;;; Package evolution: the original defpackage included a :shadowing-import-from
;;; for dsmr-mcp/src/tools/helpers:result (used with the now-removed
;;; with-attach-dispatch import).  Removing that shadow causes a package-variance
;;; error in warm images where the old definition is resident.  Delete any
;;; prior definition before redefining so the new defpackage is always fresh.
;;; Symbols in this package are all test-local; no other system imports from it.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/attach/repl-eval-attach-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/attach/repl-eval-attach-test
  (:use #:cl #:zebra)
  (:import-from #:dsmr-mcp/tests/support/slynk-fixture
                #:with-temporary-slynk-listener)
  (:import-from #:dsmr-mcp/src/attach/dispatch
                #:repl-eval-tool
                #:repl-eval-tool-slynk-conn
                #:repl-eval-tool-call-lock
                #:%dispatch-attach
                #:try-eager-connect
                #:detach-session)
  (:import-from #:dsmr-mcp/src/attach/connection
                #:parse-slynk-attach
                #:drop-connection)
  (:import-from #:bordeaux-threads
                #:all-threads
                #:thread-name
                #:thread-alive-p)
  (:import-from #:dsmr-mcp/src/state
                #:make-session
                #:*current-session-id*
                #:get-tool-instance
                #:session-slynk-attach)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:make-ht)
  (:import-from #:slynk-client
                #:slime-close)
  (:import-from #:dsmr-mcp/tests/support/bounded-eval
                #:eval-in-image))

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

;;; Eval parity + multi-value return
;;;
;;; Asserts:
;;;   a) slime-eval of (+ 1 2) returns 3 (direct wire parity)
;;;   b) %dispatch-attach "(+ 1 2)" returns no isError, content contains "3"
;;;   c) "(values 1 2 3)" content contains "1", "2", and "3" (all values)

(define-test criterion-1-eval-parity
  "repl-eval results are identical to slime-eval. All returned values are presented."
  (with-temporary-slynk-listener (conn)
    ;; a) Direct slime-eval parity: the in-process listener returns 3 for (+ 1 2).
    (is = 3 (eval-in-image '(+ 1 2) conn :label "eval parity probe"))
    ;; b) %dispatch-attach parity.
    (multiple-value-bind (session tool)
        (%make-attach-session "crit-1-eval" conn)
      (declare (ignore session))
      (let* ((res    (%dispatch-attach tool (make-ht "code" "(+ 1 2)")))
             (ctext  (gethash "text" (aref (gethash "content" res) 0))))
        (false (gethash "isError" res))
        (true  (search "3" ctext))))
    ;; c) Multi-value: (values 1 2 3) must put all three in content text.
    (multiple-value-bind (session tool)
        (%make-attach-session "crit-1-multival" conn)
      (declare (ignore session))
      (let* ((res   (%dispatch-attach tool (make-ht "code" "(values 1 2 3)")))
             (ctext (gethash "text" (aref (gethash "content" res) 0))))
        (false (gethash "isError" res))
        (true  (search "1" ctext))
        (true  (search "2" ctext))
        (true  (search "3" ctext))))))

;;; Structured error context
;;;
;;; A condition raised in the attached image must return a structured
;;; error_context hash-table with non-nil condition_type, message, restarts.
;;; On SBCL, frames must be a non-empty vector (pre-unwind handler-bind).

(define-test criterion-2-structured-error
  "Conditions return condition_type, message, restarts, and SBCL backtrace frames."
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
        ;; frames: SBCL-only assertion, handler-bind fires pre-unwind.
        #+sbcl
        (let ((frames (gethash "frames" ec)))
          (true (vectorp frames))
          (true (plusp (length frames))))
        ;; error_context strings must not contain raw ESC (0x1B); any ANSI
        ;; sequences are stripped by sanitize-control-chars before the wire.
        (false (find #\Escape (gethash "condition_type" ec)))
        (false (find #\Escape (gethash "message" ec)))
        (when (and (vectorp (gethash "restarts" ec))
                   (plusp (length (gethash "restarts" ec))))
          (let ((r0 (aref (gethash "restarts" ec) 0)))
            (false (find #\Escape (gethash "name" r0 "")))
            (false (find #\Escape (gethash "description" r0 "")))))))))

;;; Fail-closed + reconnect on demand
;;;
;;; Flow:
;;;   1. Start listener A on port pA; do one successful %dispatch-attach call.
;;;   2. Kill listener A + nil out the cached connection (simulates network drop).
;;;   3. Call %dispatch-attach -> must return isError t; conn slot must be nil.
;;;   4. Start listener B on port pB; point session slynk-attach at pB.
;;;   5. Call %dispatch-attach -> must reconnect and succeed.

(define-test criterion-3-fail-closed-reconnect
  "Dead listener -> isError; the next call reconnects on demand."
  (let* ((port-a (slynk:create-server :port 0 :dont-close t))
         (session (make-session :id "crit-3-fail"
                                :slynk-attach (format nil "127.0.0.1:~A" port-a)))
         (*current-session-id* "crit-3-fail")
         (tool   (get-tool-instance session "repl-eval")))
    (unwind-protect
         (progn
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
                   (unwind-protect
                        (progn
                          (setf (session-slynk-attach session)
                                (format nil "127.0.0.1:~A" port-b))
                          (sleep 0.1)
                          ;; 5. Third call -> reconnects to listener B and succeeds.
                          (let ((r3 (%dispatch-attach tool (make-ht "code" "(+ 3 3)"))))
                            (false (gethash "isError" r3))
                            ;; Reconnect note appears in stdout of r3.
                            (true (search "reconnected" (gethash "stdout" r3)))))
                     (ignore-errors (slynk:stop-server port-b))))))))
      (ignore-errors (slynk:stop-server port-a)))))

;;; Stream isolation
;;;
;;; Output written to *terminal-io* / *debug-io* / *trace-output* in the
;;; attached image must land in the "stdout" field of the response.
;;; Output written to *error-output* must land in "stderr".
;;; Neither should reach the test process's real *standard-output*.

(define-test criterion-4-stream-isolation
  "Stream output in attached image goes to response fields, not the test process terminal."
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
      ;; b) *debug-io* write lands in stdout (two-way stream backed by stdout).
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

;;; Per-session serialisation lock
;;;
;;; Two sequential %dispatch-attach calls on the same session and connection
;;; must both succeed (the lock is acquired and released cleanly; no deadlock).

(define-test attach-03-serial-lock
  "Sequential %dispatch-attach calls on the same session all succeed."
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

;;; Connection reuse
;;;
;;; Two successive %dispatch-attach calls on the same session must use the
;;; same (eq) connection object — no redundant reconnects.

(define-test attach-02-connection-reuse
  "The same connection object is reused across calls in a session."
  (with-temporary-slynk-listener (conn)
    (multiple-value-bind (session tool)
        (%make-attach-session "attach-02-reuse" conn)
      (declare (ignore session))
      ;; Pre-installed conn is the fixture conn.
      (%dispatch-attach tool (make-ht "code" "(+ 1 1)"))
      ;; After the call the slot must still hold the same eq object.
      (is eq conn (repl-eval-tool-slynk-conn tool)))))

;;; Debugger-entry guards
;;;
;;; Every failure mode below used to reach the Slynk debugger in the attached
;;; image: the rex worker parked there forever (a batch client never answers
;;; :debug events) and the async debugger events landed on the client's
;;; transport.  Each must instead return a structured error_context over the
;;; rex — never a NETWORK_ERROR, never a debugger entry.

(define-test unknown-package-returns-error-context
  "A typo'd evaluation package yields a structured error, not a debugger entry.
The package lookup runs inside the injected form's guarded region."
  (with-temporary-slynk-listener (conn)
    (multiple-value-bind (session tool)
        (%make-attach-session "guard-bad-package" conn)
      (declare (ignore session))
      (let* ((res (%dispatch-attach
                   tool
                   (let ((ht (make-ht "code" "(+ 1 2)")))
                     (setf (gethash "package" ht) "NO-SUCH-PACKAGE-XYZZY")
                     ht)))
             (ec  (gethash "error_context" res)))
        (false (equal "NETWORK_ERROR" (gethash "error_type" res)))
        (true ec)
        (true (search "NO-SUCH-PACKAGE-XYZZY" (gethash "message" ec)))))))

(define-test drop-connection-closes-socket-and-dispatcher-exits
  "drop-connection best-effort-closes the abandoned connection's socket, so
the client-side event-dispatcher thread gets EOF and exits promptly. An
abandoned dispatcher would otherwise linger for the life of the process and
print any late protocol event arriving on the dead connection."
  (let ((port (slynk:create-server :port 0 :dont-close t)))
    (unwind-protect
         (progn
           (sleep 0.1)
           (let* ((before (all-threads))
                  (conn   (slynk-client:slime-connect "127.0.0.1" port))
                  (dispatcher
                    (find-if (lambda (th)
                               (search "slynk dispatcher" (thread-name th)))
                             (set-difference (all-threads) before))))
             (true conn)
             (true dispatcher)
             (multiple-value-bind (session tool)
                 (%make-attach-session "drop-closes-socket" conn)
               (declare (ignore session))
               (drop-connection tool :reason "test-drop")
               ;; Bounded wait — EOF reaches the dispatcher within ~2s.
               (loop repeat 40
                     while (thread-alive-p dispatcher)
                     do (sleep 0.05))
               (false (thread-alive-p dispatcher)))))
      (ignore-errors (slynk:stop-server port)))))
