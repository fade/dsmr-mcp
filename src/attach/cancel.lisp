;;;; src/attach/cancel.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Cooperative abort of an in-flight attached eval.
;;;;
;;;; A cancel request drives a headless two-phase Slynk interrupt against a
;;;; running eval on the developer's attached image, then waits a bounded grace
;;;; window for the eval to unwind. A clean abort is reported as such; a no-take
;;;; (grace expiry) records the eval thread as a tracked orphan and leaves the
;;;; connection OPEN. The developer's image thread is never hard-killed: a forced
;;;; unwind of an arbitrary user form would leave the image in an indeterminate
;;;; state, so a no-take is bounded and handed to the orphan registry instead.
;;;;
;;;; Two-phase protocol:
;;;;   1. (:emacs-interrupt t) via slime-interrupt — drops the running eval
;;;;      thread into the Slynk debugger loop.
;;;;   2. a brief pause so the asynchronous thread-interrupt is delivered before
;;;;      the restart rex arrives (a restart invoked before the thread reaches
;;;;      the debugger loop is a no-op against debug level 0).
;;;;   3. invoke the ABORT restart (index 1 at debug level 1) on the interrupted
;;;;      thread via a rex.
;;;; The abort fires the original eval's continuation with (cons +abort+ cond);
;;;; the worker thread fulfills the dispatch-promise with that value, which this
;;;; function reads back to tell a clean abort from a no-take.
;;;;
;;;; Wire-literal discipline (recurring connection-drop class): the abort form is
;;;; a slynk symbol plus two integers built with LIST — plain and printable, with
;;;; no base-string / #\ / #() / internal-package-symbol literal that the foreign
;;;; reader could choke on. The injected sexp stays portable ANSI; the target is
;;;; the developer's image of unknown implementation. The cross-process
;;;; foreign-SBCL test is the only guard that can catch a regression here.

(defpackage #:dsmr-mcp/src/attach/cancel
  (:use #:cl)
  (:import-from #:slynk-client
                #:slime-interrupt)
  (:import-from #:bordeaux-threads
                #:make-lock
                #:with-lock-held)
  (:import-from #:dsmr-mcp/src/transport/dispatch-pool
                #:await-promise
                #:dispatch-promise-lock
                #:dispatch-promise-cancelled
                #:dispatch-promise-slynk-conn
                #:dispatch-promise-request-id
                #:dispatch-promise-session-id
                #:dispatch-promise-thread)
  (:import-from #:dsmr-mcp/src/orphan
                #:register-orphan)
  (:import-from #:dsmr-mcp/src/log
                #:log-event)
  (:export #:cancel-attached-eval
           #:*cancel-grace-seconds*))

(in-package #:dsmr-mcp/src/attach/cancel)

;;; ---------------------------------------------------------------------------
;;; Configuration
;;; ---------------------------------------------------------------------------

(defun %env-positive-int (name default)
  "Read a positive integer from environment variable NAME, returning DEFAULT
when NAME is unset, empty, unparseable, or non-positive. Read once per process
at load time so operators can tune the grace window without editing source."
  (let ((s (uiop:getenv name)))
    (if (or (null s) (zerop (length s)))
        default
        (handler-case
            (let ((n (parse-integer s)))
              (if (plusp n) n default))
          (error () default)))))

(defvar *cancel-grace-seconds*
  (%env-positive-int "DSMR_CANCEL_GRACE_SECONDS" 5)
  "Seconds to wait for an interrupted attached eval to unwind after the ABORT
restart is invoked, before giving up and recording it as an orphan. A clean
cooperative abort unwinds in well under a second, so a value materially above
this is genuinely suspect — past the window the eval is treated as a no-take.
Default 5; override with DSMR_CANCEL_GRACE_SECONDS (a positive integer).")

;;; ---------------------------------------------------------------------------
;;; Two-phase cooperative abort
;;; ---------------------------------------------------------------------------

(defun %abort-interrupted-thread (conn)
  "Invoke the ABORT restart (index 1 at debug level 1) on the thread the
preceding interrupt dropped into the Slynk debugger.

The restart rex must be routed to that already-debugging thread, not to a fresh
worker. A plain slime-eval-async sends thread T, which Slynk maps to a NEW
worker thread whose debug level is 0, so invoke-nth-restart-for-emacs would be a
no-op there. Dispatching with :find-existing routes the rex to
\(car active-threads) — the interrupted eval thread sitting in the debugger loop,
where the debug level is 1 and the ABORT restart is live. slime-rex hard-codes
thread T, so the rex is handed to slynk-client's dispatch entry point directly
with the thread slot set to :find-existing.

The form is a slynk symbol plus two integers built with LIST, and the package
name is the same plain literal slime-rex uses — plain and printable, with no
literal a foreign reader could choke on. The no-op continuation absorbs the
abandoned reply harmlessly: invoking ABORT unwinds the interrupted eval, so the
restart rex itself need not return a usable value."
  (slynk-client::slime-dispatch-event
   (list :emacs-rex
         (list 'slynk:invoke-nth-restart-for-emacs 1 1)
         "COMMON-LISP-USER"
         :find-existing
         (lambda (x) (declare (ignore x)) nil))
   conn))

(defun cancel-attached-eval (promise)
  "Drive a cooperative two-phase ABORT against the in-flight attached eval
backing PROMISE, then wait up to *cancel-grace-seconds* for it to unwind.

Returns :ABORTED-CLEAN when the eval aborted within the grace window — the
promise fulfilled with the slynk-client +abort+ sentinel. Returns :ORPHANED when
the window expired without a clean abort: the eval thread is recorded in the
orphan registry (:mode :attached) and the connection is left OPEN, since the
eval may still complete and force-unwinding the developer's image thread is
unsafe. Always returns a keyword, never the raw +abort+ cons."
  (let ((conn (dispatch-promise-slynk-conn promise)))
    ;; Step 1: interrupt the remote eval thread into the Slynk debugger.
    (slime-interrupt conn)
    ;; Step 2: let the asynchronous thread-interrupt be delivered before the
    ;; restart rex arrives — a restart rex landing before the thread reaches the
    ;; debugger loop is a no-op against debug level 0.
    (sleep 0.05)
    ;; Step 3: invoke the ABORT restart (index 1 at debug level 1) on the
    ;; interrupted thread now sitting in the debugger. Routed via :find-existing
    ;; so the rex reaches that thread rather than a fresh worker at debug level 0
    ;; (where the restart would be a no-op).
    (%abort-interrupted-thread conn)
    (log-event :info "attach.cancel.interrupt"
               "request_id" (dispatch-promise-request-id promise)
               "session_id" (dispatch-promise-session-id promise))
    ;; Wait the grace window for the eval to unwind. await-promise is the
    ;; bounded deadline/condvar wait extracted from bounded-slime-eval; it
    ;; returns once the promise is fulfilled or the deadline elapses.
    (multiple-value-bind (result errorp fulfilled)
        (await-promise promise :timeout *cancel-grace-seconds*)
      (declare (ignore errorp))
      (cond
        ((and fulfilled
              (consp result)
              (eq (car result) slynk-client::+abort+))
         (log-event :info "attach.cancel.aborted"
                    "request_id" (dispatch-promise-request-id promise))
         :aborted-clean)
        (t
         (with-lock-held ((dispatch-promise-lock promise))
           (setf (dispatch-promise-cancelled promise) t))
         (register-orphan :request-id (dispatch-promise-request-id promise)
                          :session-id (dispatch-promise-session-id promise)
                          :thread     (dispatch-promise-thread promise)
                          :mode       :attached)
         (log-event :warn "attach.cancel.orphaned"
                    "request_id" (dispatch-promise-request-id promise)
                    "session_id" (dispatch-promise-session-id promise))
         :orphaned)))))
