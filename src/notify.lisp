;;;; src/notify.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Polymorphic notification channel protocol for dsmr-mcp sessions.
;;;; Each session carries a notify-channel slot; tools call
;;;;   (emit channel method params)
;;;; to push a JSON-RPC notification without knowing the underlying transport.
;;;;
;;;; Three specialisations:
;;;;   null-channel    -- no-op; installed on stdio sessions and bare tests.
;;;;   tcp-line-channel -- writes one JSON-RPC line + force-output to a stream,
;;;;                       serialised under a per-channel write lock.
;;;;   sse-channel     -- queues (method params) and condition-notifies the SSE
;;;;                       server thread; the server thread owns the stream.
;;;;
;;;; Load order note: src/state.lisp loads BEFORE src/notify.lisp in the
;;;; package-inferred-system order.  src/state.lisp installs a null-channel on
;;;; new sessions via make-instance using runtime class lookup (find-symbol /
;;;; find-package) to avoid a compile-time circular dependency.  This file
;;;; must NOT import from dsmr-mcp/src/state for the same reason.

(defpackage #:dsmr-mcp/src/notify
  (:use #:cl)
  (:import-from #:bordeaux-threads
                #:make-lock
                #:with-lock-held
                #:make-condition-variable
                #:condition-wait
                #:condition-notify)
  (:import-from #:com.inuoe.jzon)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:make-ht)
  (:export #:null-channel
           #:tcp-line-channel
           #:sse-channel
           #:emit
           #:tcp-line-channel-stream
           #:tcp-line-channel-lock
           #:sse-channel-stream
           #:sse-channel-lock
           #:sse-channel-cv
           #:sse-channel-queue
           #:sse-channel-done-p
           #:%write-sse-event
           #:%drain-sse-queue
           #:%build-notification-json))

(in-package #:dsmr-mcp/src/notify)

;;; ---------------------------------------------------------------------------
;;; Channel classes
;;; ---------------------------------------------------------------------------

(defclass null-channel ()
  ()
  (:documentation "No-op notification channel.
Installed on stdio sessions and bare test fixtures where no notifications
are expected.  emit on a null-channel is a no-op that returns NIL."))

(defclass tcp-line-channel ()
  ((stream
    :initarg :stream
    :reader tcp-line-channel-stream
    :documentation "Output stream for this connection.  Owned by the TCP
connection thread; emit writes one JSON-RPC notification line + force-output.")
   (lock
    :initform (bordeaux-threads:make-lock "tcp-line-channel")
    :reader tcp-line-channel-lock
    :documentation "Per-channel write lock preventing interleaved notification
lines when multiple emit callers race on the same connection stream."))
  (:documentation "Notification channel for TCP sessions.
emit serialises under the per-channel lock and writes one JSON-RPC
notification line followed by force-output to the underlying stream.
A stream-error (e.g. broken-pipe) is caught and suppressed; the caller
does not need to guard against a dead client."))

(defclass sse-channel ()
  ((stream
    :initarg :stream
    :reader sse-channel-stream
    :documentation "Hunchentoot chunked output stream for this SSE connection.
Owned exclusively by the SSE server thread; emit must NOT write to it directly.")
   (lock
    :initform (bordeaux-threads:make-lock "sse-channel")
    :reader sse-channel-lock
    :documentation "Per-channel lock protecting queue and done-p.")
   (cv
    :initform (bordeaux-threads:make-condition-variable :name "sse-cv")
    :reader sse-channel-cv
    :documentation "Condition variable; the SSE server thread waits on this.
emit condition-notifies after pushing an event so the server thread wakes
and drains the queue.")
   (queue
    :initform nil
    :accessor sse-channel-queue
    :documentation "LIFO accumulator of (method params) pairs pending drain.
Protected by lock.  The server thread reverses before iterating to preserve
emit order (FIFO delivery).")
   (done-p
    :initform nil
    :accessor sse-channel-done-p
    :documentation "T when the SSE connection should be closed.
The server thread checks this after each condition-wait wakeup."))
  (:documentation "Notification channel for HTTP Streamable SSE sessions.
emit pushes events onto a queue and wakes the SSE server thread via a
condition variable.  The server thread owns the stream and drains the queue
via %drain-sse-queue.  emit never writes to the stream directly."))

;;; ---------------------------------------------------------------------------
;;; JSON helper
;;; ---------------------------------------------------------------------------

(defun %build-notification-json (method params)
  "Build a JSON-RPC 2.0 notification string for METHOD with PARAMS.
METHOD is a string (e.g. \"notifications/dsmr-mcp/attach/queued\").
PARAMS is a hash-table (or NIL; when NIL, the params key is omitted).
Returns a UTF-8 JSON string ready for wire emission."
  (let ((ht (make-ht "jsonrpc" "2.0" "method" method)))
    (when params
      (setf (gethash "params" ht) params))
    (com.inuoe.jzon:stringify ht)))

;;; ---------------------------------------------------------------------------
;;; emit generic function
;;; ---------------------------------------------------------------------------

(defgeneric emit (channel method params)
  (:documentation "Send a JSON-RPC notification over CHANNEL.
METHOD is the notification method string (e.g. \"notifications/dsmr-mcp/attach/queued\").
PARAMS is a jzon-encodable hash-table built via make-ht, or NIL.
Thread-safe: each specialisation holds a per-channel lock (or queue mutex)
so concurrent emit callers on the same channel are serialised."))

(defmethod emit ((channel null-channel) method params)
  "No-op: null-channel discards all notifications.
stdio sessions and bare test fixtures install a null-channel so existing
code paths can call emit unconditionally without any I/O side effects."
  (declare (ignore method params))
  nil)

(defmethod emit ((channel tcp-line-channel) method params)
  "Write one JSON-RPC notification line to the TCP stream and force-output.
Acquires the per-channel write lock to prevent line interleaving.
A stream-error (broken-pipe, closed client) is logged at debug level and
suppressed — silent recovery is the correct behaviour, but a breadcrumb
helps operators investigating dropped notifications."
  (bordeaux-threads:with-lock-held ((tcp-line-channel-lock channel))
    (handler-case
        (let ((json (%build-notification-json method params)))
          (write-line json (tcp-line-channel-stream channel))
          (force-output (tcp-line-channel-stream channel)))
      (stream-error (e)
        (uiop:symbol-call :dsmr-mcp/src/log :log-event
                          :debug "notify.tcp.stream-error"
                          "method" method
                          "error" (handler-case (princ-to-string e)
                                    (error () "<unprintable>")))
        nil))))

(defmethod emit ((channel sse-channel) method params)
  "Queue a (method params) pair and wake the SSE server thread.
Does NOT write to the channel stream directly; the SSE server thread owns
the stream and is the only writer (via %drain-sse-queue).
Acquires the per-channel lock, pushes the pair, and condition-notifies."
  (bordeaux-threads:with-lock-held ((sse-channel-lock channel))
    (push (list method params) (sse-channel-queue channel))
    (bordeaux-threads:condition-notify (sse-channel-cv channel))))

;;; ---------------------------------------------------------------------------
;;; SSE helpers
;;; ---------------------------------------------------------------------------

(defun %write-sse-event (stream event-type json-string)
  "Write one SSE event block to STREAM and force-output.
Format: \"event: <event-type>\\ndata: <json-string>\\n\\n\".
Signals STREAM-ERROR on client disconnect; callers must handle this."
  (write-string (format nil "event: ~A~%data: ~A~%~%" event-type json-string)
                stream)
  (force-output stream))

(defun %drain-sse-queue (channel stream)
  "Drain all queued events from CHANNEL and write them to STREAM as SSE events.
Called by the SSE server thread while holding no locks; acquires and releases
the channel lock once to snapshot the queue.
Events are emitted in FIFO order (the queue is reversed before iteration since
emit prepends with push).
Callers must handle STREAM-ERROR to detect client disconnect."
  (let ((events nil))
    ;; Snapshot and clear the queue under the lock.
    (bordeaux-threads:with-lock-held ((sse-channel-lock channel))
      (setf events (nreverse (sse-channel-queue channel)))
      (setf (sse-channel-queue channel) nil))
    ;; Write each event to the stream outside the lock so the stream write
    ;; cannot block other emit callers.
    (dolist (pair events)
      (let* ((method (first pair))
             (params (second pair))
             (json   (%build-notification-json method params)))
        (%write-sse-event stream "message" json)))))
