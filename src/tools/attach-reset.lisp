;;;; src/tools/attach-reset.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; MCP tool: attach-reset.
;;;; Force-drops and reopens the calling session's own connection to the
;;;; developer's image, so a connection that has stopped being useful can be
;;;; re-established without restarting the server and losing the session.
;;;;
;;;; The blast radius stops at the calling session, and that is structural
;;;; rather than checked: the tool instance is reached through get-tool-instance
;;;; for the session the request arrived on, and no session identifier is read
;;;; from the request arguments. There is no cross-session reset primitive in
;;;; this tree and none is to be added; a verb that could drop another session's
;;;; connection would let any client with tool access pull a live image out from
;;;; under the developer using it.
;;;;
;;;; Nothing here latches. The drop nils a cached connection slot and the reopen
;;;; refills it, so a reopen that fails leaves the slot empty and the next
;;;; ordinary call opens on demand exactly as it always does. A failed reset
;;;; therefore costs the session one call, not its future.
;;;;
;;;; CLOS pattern: see pool-kill-worker.lisp and pool-status.lisp. The same
;;;; rule about where a class-allocated slot's value goes applies here, and so
;;;; does the explicit finalization after the class definition.

(defpackage #:dsmr-mcp/src/tools/attach-reset
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/tools/base
                #:mcp-tool #:mcp-tool-class #:tool-handle #:tool-session)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:result #:text-content #:make-ht)
  (:import-from #:dsmr-mcp/src/state
                #:*mode* #:get-tool-instance #:session-slynk-attach)
  (:import-from #:dsmr-mcp/src/attach/connection
                #:drop-connection #:get-or-open-connection #:parse-slynk-attach)
  (:import-from #:dsmr-mcp/src/attach/dispatch
                #:repl-eval-tool-slynk-conn #:repl-eval-tool-connection-epoch)
  ;; closer-mop: the class is finalized explicitly after the defclass below.
  ;; MUST be declared here or the cold build fails ("Package CLOSER-MOP does not exist").
  (:import-from #:closer-mop)
  (:export #:attach-reset-tool))

(in-package #:dsmr-mcp/src/tools/attach-reset)

(defclass attach-reset-tool (mcp-tool)
  ;; CRITICAL: class-allocated slots carry their value in an :initform. The
  ;; registration hook reads the class prototype, which never applies the
  ;; per-class default initargs, so a value supplied that way is invisible to
  ;; it and the verb silently fails to register.
  ((dsmr-mcp/src/tools/base::name
    :allocation :class
    :initform "attach-reset")
   (dsmr-mcp/src/tools/base::description
    :allocation :class
    :initform "Force-drop and reopen this session's connection to the \
developer's Lisp image, in place and without restarting the server. Use it \
when the image accepts connections and answers nothing, or when a connection \
has to be re-established after a fault. In-image state is untouched: this \
resets the wire, not the image, so definitions and application state built up \
in the developer's image survive. \
It affects only the calling session's own connection. No other session's \
connection is dropped, and no other session can be named: the verb takes no \
arguments at all. \
The response reports the connection epoch after the reset. That is what makes \
a reset observable to somebody else: a call already in flight when the reset \
lands sees the epoch move under it and can tell it was reset rather than that \
it merely failed. When no connection was open, one is opened and the epoch \
stays where it is, since no call was interrupted. Only available in attached \
mode.")
   (dsmr-mcp/src/tools/base::input-schema
    :allocation :class
    :initform '(:object :properties () :required ())))
  (:metaclass mcp-tool-class)
  (:documentation "MCP tool: force-drop and reopen the calling session's
connection to the attached image. Only available when *mode* is :attached."))

;; CRITICAL: ensure-finalized must appear after defclass.
;; (src/tools/base.lisp line 162; src/attach/dispatch.lisp line 115.)
(c2mop:ensure-finalized (find-class 'attach-reset-tool))

(defun %reset-connection (target host port)
  "Put TARGET back in touch with the image at HOST and PORT, and say what it took.

Returns (values OUTCOME EPOCH DETAIL DROPPED), where OUTCOME is one of:

  :reset          a connection was open, it was dropped, and a fresh one was
                  opened in its place. The epoch moved.
  :reopened       nothing was open, so nothing was dropped, and a connection
                  was opened. The epoch does not move: a reset that interrupted
                  nobody must not look like one that did, because the only
                  reader of that number is a call comparing it against what it
                  saw at entry.
  :reopen-failed  the image could not be reached. DROPPED says whether a live
                  connection was thrown away first.

Opening in the nothing-was-open case is what makes the verb useful rather than
merely tidy. A failed call is fail-closed: it empties the cached slot on its way
out, so by the time somebody has watched a call fail and reached for this verb,
there is usually nothing left to drop. Measured against a real image stopped
with SIGSTOP: the failing call reported the wedge and emptied the slot, and a
reset that only dropped would have done nothing at all for the operator who
asked for it.

Nothing is recorded on failure. The slot is empty either way, so the next
ordinary call opens on demand exactly as it always does, and a reset that could
not reach the image costs the session one call rather than its future.

DETAIL carries the failure's printed condition and is NIL otherwise. The
condition is printed inside its own guard, because printing one that names a
dead connection can itself signal."
  (let ((was-open (and (repl-eval-tool-slynk-conn target) t)))
    (when was-open
      (drop-connection target :reason "manual-reset"))
    (handler-case
        (progn
          (get-or-open-connection target host port)
          (values (if was-open :reset :reopened)
                  (repl-eval-tool-connection-epoch target)
                  nil
                  was-open))
      (error (e)
        (values :reopen-failed
                (repl-eval-tool-connection-epoch target)
                (handler-case (princ-to-string e)
                  (error () "<unprintable>"))
                was-open)))))

(defmethod tool-handle ((tool attach-reset-tool) id args)
  (declare (ignore args))
  (unless (eq *mode* :attached)
    (return-from tool-handle
      (result id (make-ht "isError" t
                          "content"
                          (text-content
                           "attach-reset is only available in attached mode.")))))
  ;; The session is the one the request arrived on, and the instance is reached
  ;; through it. Nothing here consults the request arguments, so there is no
  ;; path by which a client names a session other than its own.
  (let* ((session (tool-session tool))
         (target (and session (get-tool-instance session "repl-eval"))))
    (unless target
      (return-from tool-handle
        (result id (make-ht "isError" t
                            "content"
                            (text-content
                             "attach-reset: this session has no attached-image tool to reset.")))))
    (multiple-value-bind (host port)
        (parse-slynk-attach (session-slynk-attach session))
      (unless (and host port)
        (return-from tool-handle
          (result id (make-ht "isError" t
                              "content"
                              (text-content
                               "attach-reset: this session has no image address configured, so there is nothing to reconnect to.")))))
      (multiple-value-bind (outcome epoch detail dropped)
          (%reset-connection target host port)
        (case outcome
          (:reopened
           (result id (make-ht "isError" nil
                               "content"
                               (text-content
                                (format nil "No connection to the image was open, so nothing was interrupted. A fresh connection is open now and the connection epoch stays at ~D." epoch))
                               "reset" nil
                               "epoch" epoch)))
          (:reset
           (result id (make-ht "isError" nil
                               "content"
                               (text-content
                                (format nil "Connection to the image dropped and reopened. Connection epoch is now ~D; a call that was in flight sees that move and knows it was reset." epoch))
                               "reset" t
                               "epoch" epoch)))
          (:reopen-failed
           (let ((envelope
                   (make-ht "isError" t
                            "content"
                            (text-content
                             (format nil "~:[No connection was open, and opening one failed~;Connection to the image dropped, and reopening it failed~]: ~A. Nothing is answering at the image's address. The next call will try again. Connection epoch is ~D." dropped detail epoch))
                            "reset" (and dropped t)
                            "epoch" epoch)))
             (setf (gethash "error_type" envelope) "backend_crashed")
             (result id envelope)))
          (t
           (result id (make-ht "isError" t
                               "content"
                               (text-content
                                (format nil "attach-reset: unexpected outcome ~A" outcome))))))))))
