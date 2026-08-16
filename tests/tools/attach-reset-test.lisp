;;;; tests/tools/attach-reset-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Coverage for the attach-reset verb.
;;;;
;;;; Every test here stands up a real in-process Slynk listener and opens the
;;;; connection through the production path, so what is reset is a connection
;;;; the ordinary call path made and what reopens it is the ordinary call path
;;;; reopening it. A fixture that installed a stand-in object in the cached slot
;;;; would exercise the bookkeeping and none of the lifecycle.
;;;;
;;;; The assertion that matters most is not the one about the epoch. It is the
;;;; two-session control: the verb claims to reach only the calling session's
;;;; connection, and until a second session is standing beside the first with
;;;; its own connection and its own epoch, that claim is a sentence in a
;;;; docstring rather than a fact about the code.
;;;;
;;;; The failure name is asserted in both directions. A completed reset must
;;;; carry no failure name at all, because a success response carrying one
;;;; teaches a caller to read the field as advisory; a reset whose reopen
;;;; genuinely failed must carry one, or the absence in the first case proves
;;;; only that the field is never set.

(defpackage #:dsmr-mcp/tests/tools/attach-reset-test
  (:use #:cl #:zebra)
  (:import-from #:dsmr-mcp/src/tools/attach-reset
                #:attach-reset-tool)
  (:import-from #:dsmr-mcp/src/tools/base
                #:tool-handle)
  (:import-from #:dsmr-mcp/src/state
                #:*mode*
                #:make-session
                #:get-tool-instance)
  (:import-from #:dsmr-mcp/src/attach/connection
                #:get-or-open-connection
                #:drop-connection)
  (:import-from #:dsmr-mcp/src/attach/dispatch
                #:repl-eval-tool-slynk-conn
                #:repl-eval-tool-connection-epoch)
  (:import-from #:slynk))

(in-package #:dsmr-mcp/tests/tools/attach-reset-test)

;;; ---------------------------------------------------------------------------
;;; Fixture
;;; ---------------------------------------------------------------------------

(defmacro with-listener ((port-var) &body body)
  "Start an in-process Slynk listener on an OS-assigned port, bind PORT-VAR to
it, and stop it again on the way out however BODY leaves.

:dont-close is set so the listen socket keeps accepting: a reset opens a second
connection to the same listener, which is the whole shape under test. The stop
is wrapped so a test that has already stopped the listener on purpose does not
fail in teardown."
  (let ((tmp (gensym "PORT-")))
    `(let ((,tmp (slynk:create-server :port 0 :dont-close t)))
       (unwind-protect
            (let ((,port-var ,tmp))
              (declare (ignorable ,port-var))
              ,@body)
         (ignore-errors (slynk:stop-server ,tmp))))))

(defun attached-session (id port)
  "Return a session addressed at PORT, with no connection opened yet."
  (make-session :id id :slynk-attach (format nil "127.0.0.1:~D" port)))

(defun open-connection-for (session port)
  "Open SESSION's connection through the production path and return its tool."
  (let ((tool (get-tool-instance session "repl-eval")))
    (get-or-open-connection tool "127.0.0.1" port)
    tool))

(defun release (tool)
  "Drop whatever connection TOOL is holding, so no test leaves a reader thread
parked on a listener that is about to go away."
  (ignore-errors (drop-connection tool :reason "test-teardown")))

(defun call-attach-reset (session)
  "Dispatch the verb on a fresh instance bound to SESSION and return the result
payload hash-table."
  (let ((tool (make-instance 'attach-reset-tool :session session)))
    (gethash "result" (tool-handle tool "attach-reset-request" nil))))

(defun key-present-p (ht key)
  "True when KEY is present in HT, whatever its value. Absence and a null value
are different answers and this is what tells them apart."
  (nth-value 1 (gethash key ht)))

;;; ---------------------------------------------------------------------------
;;; The reset itself
;;; ---------------------------------------------------------------------------

(define-test a-reset-advances-the-epoch-and-reports-the-one-it-produced
  "A reset on an open connection moves the epoch by exactly one and hands back
the value the instance now holds.

Reporting the epoch is the whole point of the verb beyond the reconnect: a call
that was in flight compares what it saw at entry against this. So the reported
value is asserted equal to the instance's own, not merely to a number that has
gone up. Were the report taken from somewhere else, or stamped before the drop,
the two would drift apart and every reader of the field would be wrong without
anything saying so."
  (let ((*mode* :attached))
    (with-listener (port)
      (let* ((session (attached-session "attach-reset-epoch" port))
             (tool (open-connection-for session port)))
        (unwind-protect
             (let ((before (repl-eval-tool-connection-epoch tool)))
               (true (repl-eval-tool-slynk-conn tool)
                     "the connection must be open, or there is nothing to reset")
               (let ((payload (call-attach-reset session)))
                 (false (gethash "isError" payload) "a completed reset is not an error")
                 (true (gethash "reset" payload) "and it says it reset something")
                 (is = (1+ before) (repl-eval-tool-connection-epoch tool)
                     "the epoch moves by exactly one")
                 (is = (repl-eval-tool-connection-epoch tool) (gethash "epoch" payload)
                     "and the reported epoch is the one the instance now holds")
                 (true (repl-eval-tool-slynk-conn tool)
                       "the connection is reopened eagerly, not left for the next call")))
          (release tool))))))

(define-test a-reset-leaves-another-sessions-connection-untouched
  "A reset in one session moves nothing in another.

This is the security assertion. The verb takes no arguments and resolves its
target from the session the request arrived on, so there is no way to name
another session; this test is what makes that a fact rather than a claim. The
other session's epoch AND its connection object are both checked, because an
implementation that dropped every session's connection and reopened them all
would leave the epochs looking plausible only until the objects are compared.

The calling session's own epoch is asserted to have moved as well. Without it
the control would pass just as happily against a verb that did nothing at all."
  (let ((*mode* :attached))
    (with-listener (port)
      (let* ((caller (attached-session "attach-reset-caller" port))
             (caller-tool (open-connection-for caller port))
             (bystander (attached-session "attach-reset-bystander" port))
             (bystander-tool (open-connection-for bystander port)))
        (unwind-protect
             (let ((caller-epoch (repl-eval-tool-connection-epoch caller-tool))
                   (bystander-epoch (repl-eval-tool-connection-epoch bystander-tool))
                   (bystander-conn (repl-eval-tool-slynk-conn bystander-tool)))
               (true bystander-conn "the bystander must hold a connection to be able to lose it")
               (call-attach-reset caller)
               (is = (1+ caller-epoch) (repl-eval-tool-connection-epoch caller-tool)
                   "the calling session was reset, or this control tests nothing")
               (is = bystander-epoch (repl-eval-tool-connection-epoch bystander-tool)
                   "the bystander's epoch does not move")
               (is eq bystander-conn (repl-eval-tool-slynk-conn bystander-tool)
                   "and it is still holding the same connection object"))
          (release caller-tool)
          (release bystander-tool))))))

(define-test a-reset-with-nothing-open-says-so-and-leaves-the-epoch-alone
  "With no connection open there is nothing to reset, and the verb says that
rather than erroring.

The epoch must not move here. A reset that reset nothing looking exactly like
one that dropped a live connection would make the field useless to the caller
comparing it, which is the only reader the field has."
  (let ((*mode* :attached))
    (with-listener (port)
      (let* ((session (attached-session "attach-reset-nothing-open" port))
             (tool (get-tool-instance session "repl-eval")))
        (false (repl-eval-tool-slynk-conn tool) "no connection has been opened")
        (let ((before (repl-eval-tool-connection-epoch tool))
              (payload (call-attach-reset session)))
          (false (gethash "isError" payload) "nothing to reset is not a failure")
          (false (gethash "reset" payload) "and it reports that it reset nothing")
          (is = before (repl-eval-tool-connection-epoch tool)
              "the epoch stays where it was")
          (is = before (gethash "epoch" payload)
              "and the reported epoch is that same unmoved value"))))))

(define-test a-reset-off-attached-mode-is-refused-and-changes-nothing
  "Outside attached mode the verb refuses, and the refusal is inert.

A refusal that had already dropped the connection would be worse than no
refusal at all, so the connection object and the epoch are both read afterwards
and both must be exactly what they were."
  (with-listener (port)
    (let* ((session (let ((*mode* :attached))
                      (attached-session "attach-reset-hermetic" port)))
           (tool (let ((*mode* :attached)) (open-connection-for session port))))
      (unwind-protect
           (let ((before-epoch (repl-eval-tool-connection-epoch tool))
                 (before-conn (repl-eval-tool-slynk-conn tool)))
             (let* ((*mode* :hermetic)
                    (payload (call-attach-reset session)))
               (true (gethash "isError" payload) "the verb refuses off attached mode")
               (is = before-epoch (repl-eval-tool-connection-epoch tool)
                   "and the refusal moved no epoch")
               (is eq before-conn (repl-eval-tool-slynk-conn tool)
                   "and dropped no connection")))
        (release tool)))))

;;; ---------------------------------------------------------------------------
;;; The failure name, asserted in both directions
;;; ---------------------------------------------------------------------------

(define-test a-completed-reset-carries-no-failure-name
  "A reset that worked carries no failure name at all, not a null one.

Absence is asserted rather than a null value on purpose. A success response
carrying a failure taxonomy name, even an empty one, teaches every caller to
read the field as advisory, and the name for an interrupted call belongs to the
call that was interrupted, never to the reset that interrupted it."
  (let ((*mode* :attached))
    (with-listener (port)
      (let* ((session (attached-session "attach-reset-no-name" port))
             (tool (open-connection-for session port)))
        (unwind-protect
             (let ((payload (call-attach-reset session)))
               (false (gethash "isError" payload) "the reset completed")
               (false (key-present-p payload "error_type")
                      "a completed reset carries no failure name at all"))
          (release tool))))))

(define-test a-reset-that-cannot-reopen-names-the-backend-gone
  "When the image is gone the reopen fails, and that failure is named.

This is the discrimination for the assertion above: without it, the absence of a
failure name on a completed reset would establish only that the field is never
set. Here the same field is present, carrying the name for a backend that is no
longer there.

The cached connection is left empty afterwards and the epoch has still moved.
Nothing latches: the session is not marked failed anywhere, so the next ordinary
call opens on demand exactly as it always does, and a failed reset costs a
session one call rather than its future."
  (let ((*mode* :attached))
    (with-listener (port)
      (let* ((session (attached-session "attach-reset-gone" port))
             (tool (open-connection-for session port))
             (before (repl-eval-tool-connection-epoch tool)))
        (unwind-protect
             (progn
               ;; Stopping the listener closes the accepting socket while the
               ;; connection already open stays in the slot, so the drop has
               ;; something real to drop and the reopen has nothing to reach.
               (slynk:stop-server port)
               (let ((payload (call-attach-reset session)))
                 (true (gethash "isError" payload) "a reopen that failed is an error")
                 (true (key-present-p payload "error_type") "and it carries a failure name")
                 (is equal "backend_crashed" (gethash "error_type" payload)
                     "naming the backend as gone rather than merely unhappy")
                 (true (> (repl-eval-tool-connection-epoch tool) before)
                       "the drop happened, so the epoch moved")
                 (false (repl-eval-tool-slynk-conn tool)
                        "and the cached slot is empty, so the next call opens on demand")))
          (release tool))))))
