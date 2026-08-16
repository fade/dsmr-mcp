;;;; tests/integration/attach/reset-race-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; The one attached failure name whose detection is real new logic rather than
;;;; a rename, driven against a real image.
;;;;
;;;; Three of the attached failure names are established by asking the image what
;;;; state it is in. The fourth is not: it fires when a call's connection epoch
;;;; advances while that call is in flight, which is a fact about this process and
;;;; not about the image at all. Nothing else in the surrounding work drives that
;;;; path, and a classification that ships without ever being watched firing is
;;;; the exact gap this work exists to close.
;;;;
;;;; It needs no operating system fault. The race is entirely in the test's hands:
;;;; a call is put in flight against an evaluation that waits for a file the test
;;;; creates, the reset verb is fired while it is provably still waiting, and the
;;;; call is then let go and its answer read.
;;;;
;;;; The negative control is the whole reason the assertion means anything. A
;;;; detection that called every long call reset would satisfy the positive
;;;; assertion perfectly, so an identical call, released the same way with nothing
;;;; fired against it, is run beside it and the two answers are compared directly.
;;;;
;;;; The child image, its teardown, and the long evaluation come from the wedge
;;;; leaf beside this one rather than being written a second time, so the two
;;;; cannot drift apart.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/integration/attach/reset-race-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/integration/attach/reset-race-test
  (:use #:cl #:zebra)
  (:import-from #:dsmr-mcp/tests/integration/attach/liveness-wedge-test
                #:with-stoppable-image
                #:image-session
                #:image-tool
                #:dispatch-code
                #:call-attach-reset
                #:key-present-p
                #:response-text
                #:release-path
                #:waiting-form
                #:release-the-waiting-form)
  (:import-from #:dsmr-mcp/src/attach/dispatch
                #:repl-eval-tool-connection-epoch)
  (:import-from #:dsmr-mcp/src/state
                #:*mode*)
  (:import-from #:dsmr-mcp/tests/integration/support
                #:with-foreign-slynk-child-or-skip)
  (:import-from #:bordeaux-threads))

(in-package #:dsmr-mcp/tests/integration/attach/reset-race-test)

;;; ---------------------------------------------------------------------------
;;; A call the test can hold in flight and let go when it chooses
;;; ---------------------------------------------------------------------------

(defstruct (long-call (:constructor %make-long-call))
  "A dispatch call running on its own thread against an evaluation that waits.

IN-FLIGHT is what makes the race provable rather than presumed: the reset is
fired only once this reads true, and it is read again immediately afterwards, so
the call is known to have been running on both sides of the reset."
  thread
  (in-flight t)
  response)

(defun start-long-call (tool path &key (timeout 3))
  "Start a call occupying TOOL's connection until PATH appears."
  (let ((call (%make-long-call)))
    (setf (long-call-thread call)
          (bt:make-thread
           (lambda ()
             (let ((response (ignore-errors
                               (dispatch-code tool (waiting-form path) :timeout timeout))))
               (setf (long-call-response call) response
                     (long-call-in-flight call) nil)))
           :name "attach-reset-race-call"))
    call))

(defun finish-long-call (call path)
  "Let the evaluation go, wait for the call to come back, and return its response.

The wait is bounded and then joined, rather than joined with a time limit: the
join here takes none, and one called with a limit signals instead of waiting,
which reads as an instant answer and hands back a response that never arrived."
  (release-the-waiting-form path)
  (loop repeat 900 while (long-call-in-flight call) do (sleep 0.1))
  (when (long-call-thread call)
    (ignore-errors (bt:join-thread (long-call-thread call))))
  (ignore-errors (delete-file path))
  (long-call-response call))

;;; ---------------------------------------------------------------------------
;;; The race, with the control it needs to mean anything
;;; ---------------------------------------------------------------------------

(define-test a-call-interrupted-by-a-reset-is-told-so-and-an-uninterrupted-one-is-not
  "A call whose connection is reset under it is told that is what happened, and a
call nothing interrupted is told nothing.

The positive case names one outcome and no other result satisfies it. The call is
proved to be in flight before the reset is fired and proved to be still in flight
immediately after, so the reset is known to have landed underneath it rather than
before it started or after it finished.

The control is what turns that into a discrimination. An identical call, of the
same shape and released the same way, with nothing fired against it, must come
back carrying no failure name at all. Without it, a detection that called every
long call interrupted would pass the assertion above and be wrong about every
call the server ever makes.

The two answers are then compared against each other in a single assertion, so
the difference the whole test exists to show is one line a reader can find rather
than two facts they have to hold in their head at once."
  (with-foreign-slynk-child-or-skip
    (let ((*mode* :attached))
      (with-stoppable-image (port pid)
        (let (interrupted-response
              clean-response)
          ;; The interrupted call.
          (let* ((path (release-path))
                 (session (image-session "attach-reset-race-interrupted" port))
                 (tool (image-tool session))
                 (call nil))
            (dispatch-code tool "(+ 1 2)")
            (unwind-protect
                 (progn
                   (setf call (start-long-call tool path))
                   (sleep 2)
                   (true (long-call-in-flight call)
                         "the call must be in flight, or there is no race to run")
                   (let* ((before (repl-eval-tool-connection-epoch tool))
                          (reset (call-attach-reset session)))
                     (false (gethash "isError" reset) "the reset itself succeeds")
                     (is = (1+ before) (repl-eval-tool-connection-epoch tool)
                         "and advances the epoch, which is what the call in flight observes")
                     (true (long-call-in-flight call)
                           "with the call still in flight, so the reset landed under it")))
              (when call
                (setf interrupted-response (finish-long-call call path)))
              (ignore-errors (delete-file path))))
          ;; The control: the same call, nothing fired against it.
          (let* ((path (release-path))
                 (session (image-session "attach-reset-race-clean" port))
                 (tool (image-tool session))
                 (call nil))
            (unwind-protect
                 (progn
                   (setf call (start-long-call tool path :timeout 30))
                   (sleep 2)
                   (true (long-call-in-flight call)
                         "the control must occupy the connection the same way"))
              (when call
                (setf clean-response (finish-long-call call path)))
              (ignore-errors (delete-file path))))
          ;; What each was told.
          (true (hash-table-p interrupted-response)
                "the interrupted call must have come back for its answer to be read")
          (when (hash-table-p interrupted-response)
            (true (gethash "isError" interrupted-response)
                  "an abandoned call is an error to its caller")
            (is equal "backend_reset" (gethash "error_type" interrupted-response)
                "and is named as the connection having been reset under it"))
          (true (hash-table-p clean-response)
                "the control must have come back too")
          (when (hash-table-p clean-response)
            (false (gethash "isError" clean-response)
                   "a call nothing interrupted is not an error")
            (false (key-present-p clean-response "error_type")
                   "and carries no failure name at all")
            (true (search "RELEASED" (string-upcase (response-text clean-response)))
                  "having actually run and returned its value, so the control is not an idle call"))
          ;; The discrimination itself, in one place.
          (when (and (hash-table-p interrupted-response) (hash-table-p clean-response))
            (isnt equal
                  (gethash "error_type" interrupted-response)
                  (gethash "error_type" clean-response)
                  "the two calls differ in exactly the field the detection sets")))))))
