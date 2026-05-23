;;;; tests/support/slynk-fixture.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; In-process Slynk fixture for attached-mode integration tests.
;;;; Starts a Slynk listener on OS-assigned port 0 and connects
;;;; slynk-client to it so tests exercise the real slime-eval path
;;;; without an external image.
;;;;
;;;; Confirmed Slynk server API (verified against
;;;;   $LISP_WORKSPACE/sly/slynk/slynk.lisp lines 935-998
;;;;   on 2026-05-23 — resolves RESEARCH open questions A2/A3):
;;;;
;;;;   slynk:create-server &key port style dont-close interface backlog
;;;;     -> port-integer
;;;;     With :port 0, setup-server calls socket-quest 0 which lets the OS
;;;;     assign the ephemeral port; setup-server returns the local-port of
;;;;     the bound socket (line 994: "(let* ((socket ...) (port (local-port socket)))
;;;;     ... port)").  Both :style defaults to *communication-style* (typically
;;;;     :spawn — threads) and :dont-close defaults to *dont-close* (NIL).
;;;;     Pass :dont-close t so the listen socket accepts more than one
;;;;     connection (required by criterion-3 reconnect test).
;;;;
;;;;   slynk:stop-server port -> ()
;;;;     Sends (:stop-server :port port) to the Slynk sentinel thread which
;;;;     shuts down the listener socket for PORT (lines 996-998).
;;;;     Both create-server and stop-server are EXPORTED from package SLYNK
;;;;     (package declaration lines 16-19).
;;;;
;;;; D-13 (RESEARCH §6): fixture shape locked in Phase 1.

(defpackage #:dsmr-mcp/tests/support/slynk-fixture
  (:use #:cl)
  (:import-from #:slynk-client
                #:slime-connect
                #:slime-close)
  (:export #:with-temporary-slynk-listener))

(in-package #:dsmr-mcp/tests/support/slynk-fixture)

(defmacro with-temporary-slynk-listener ((conn-var) &body body)
  "Start an in-process Slynk listener on an OS-assigned port (port 0),
bind CONN-VAR to the slynk-client connection, run BODY, then tear down
cleanly via unwind-protect.

The listener is started with :dont-close t so the listen socket accepts
multiple connections — required for criterion-3 (reconnect) test which
opens, closes, then reopens a connection to the same fixture.

Connection race: slime-connect is retried up to 20 times with a 50ms
sleep between attempts because the Slynk :spawn listener starts an OS
thread; the accept loop may not be ready the instant create-server
returns.  All 20 attempts failing signals a plain error naming the port.

Teardown (always runs, even on non-local-exit from BODY):
  (ignore-errors (slime-close CONN-VAR))  — graceful client-side FIN
  (ignore-errors (slynk:stop-server PORT)) — shut down the listen socket
Both are wrapped in ignore-errors so a half-open connection or a
partially-torn-down sentinel never masks a test assertion failure
(T-02-TEST-01: no listener resource leaks)."
  (let ((port-var  (gensym "PORT-"))
        (conn-tmp  (gensym "CONN-"))
        (attempt   (gensym "ATTEMPT-"))
        (max-tries (gensym "MAX-TRIES-")))
    `(let* ((,port-var  (slynk:create-server :port 0 :dont-close t))
            (,max-tries 20)
            (,conn-tmp  nil))
       ;; Retry connect up to max-tries times — the :spawn listener may not
       ;; have its accept loop live yet when create-server returns.
       (dotimes (,attempt ,max-tries)
         (setf ,conn-tmp (slime-connect "127.0.0.1" ,port-var))
         (when ,conn-tmp (return))
         (sleep 0.05))
       (unless ,conn-tmp
         (ignore-errors (slynk:stop-server ,port-var))
         (error "with-temporary-slynk-listener: slime-connect returned NIL \
after ~D attempts on port ~A" ,max-tries ,port-var))
       (let ((,conn-var ,conn-tmp))
         (unwind-protect
              (progn ,@body)
           ;; Teardown — both in ignore-errors (T-02-TEST-01, T-02-TEST-02).
           (ignore-errors (slime-close ,conn-var))
           (ignore-errors (slynk:stop-server ,port-var)))))))
