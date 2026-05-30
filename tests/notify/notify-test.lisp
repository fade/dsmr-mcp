;;;; tests/notify/notify-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Unit tests for the notify-channel polymorphic emit protocol.
;;;; Tests run entirely with string streams — no sockets, no Slynk.

(defpackage #:dsmr-mcp/tests/notify/notify-test
  (:use #:cl #:parachute)
  (:import-from #:dsmr-mcp/src/notify
                #:null-channel
                #:tcp-line-channel
                #:tcp-line-channel-stream
                #:tcp-line-channel-lock
                #:sse-channel
                #:sse-channel-queue
                #:sse-channel-cv
                #:sse-channel-lock
                #:emit
                #:%build-notification-json
                #:%write-sse-event)
  (:import-from #:bordeaux-threads
                #:make-thread
                #:join-thread
                #:make-lock
                #:with-lock-held)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:make-ht))

(in-package #:dsmr-mcp/tests/notify/notify-test)

;;; ---------------------------------------------------------------------------
;;; Tests
;;; ---------------------------------------------------------------------------

(define-test null-channel-emit-is-noop
  "emit on a null-channel returns NIL and writes no output."
  (let ((ch (make-instance 'null-channel)))
    ;; Returns nil.
    (is eq nil (emit ch "notifications/test" nil))
    ;; Calling with params also returns nil.
    (is eq nil (emit ch "notifications/test/two"
                     (make-ht "key" "value")))))

(define-test tcp-line-channel-emit-writes-json-line
  "emit on a tcp-line-channel writes exactly one JSON line containing
jsonrpc, method, and the supplied method name to the underlying stream."
  (let* ((out (make-string-output-stream))
         (ch  (make-instance 'tcp-line-channel :stream out)))
    (emit ch "notifications/dsmr-mcp/attach/queued"
          (make-ht "position" 1 "holder_session_id" "test-session"))
    (let ((line (get-output-stream-string out)))
      ;; Should contain a newline (write-line appends one).
      (true (search (string #\Newline) line))
      ;; Must contain jsonrpc field.
      (true (search "jsonrpc" line))
      ;; Must contain method field.
      (true (search "method" line))
      ;; Must contain the supplied method name.
      (true (search "notifications/dsmr-mcp/attach/queued" line))
      ;; Must contain params-level keys.
      (true (search "position" line))
      (true (search "holder_session_id" line)))))

(define-test tcp-line-channel-emit-is-thread-safe
  "Two concurrent threads each emitting 50 messages via the same
tcp-line-channel produce exactly 100 complete JSON lines.
The channel's internal write lock prevents interleaving."
  (let* ((out (make-string-output-stream))
         (ch  (make-instance 'tcp-line-channel :stream out))
         (count 50)
         (t1 (bordeaux-threads:make-thread
              (lambda ()
                (dotimes (i count)
                  (emit ch "notifications/test/thread-a"
                        (make-ht "n" i))))
              :name "notify-test-thread-a"))
         (t2 (bordeaux-threads:make-thread
              (lambda ()
                (dotimes (i count)
                  (emit ch "notifications/test/thread-b"
                        (make-ht "n" i))))
              :name "notify-test-thread-b")))
    (bordeaux-threads:join-thread t1)
    (bordeaux-threads:join-thread t2)
    (let* ((captured (get-output-stream-string out))
           (lines (remove "" (uiop:split-string captured
                                                :separator (list #\Newline))
                          :test #'string=)))
      ;; Exactly 100 non-empty lines.
      (is = 100 (length lines))
      ;; Every line must contain both "jsonrpc" and "method".
      (dolist (line lines)
        (true (search "jsonrpc" line))
        (true (search "method" line))))))

(define-test sse-channel-emit-queues-and-notifies
  "emit on an sse-channel pushes (method params) onto sse-channel-queue
and does NOT write anything to the underlying stream."
  (let* ((out (make-string-output-stream))
         (ch  (make-instance 'sse-channel :stream out)))
    ;; Initially the queue is empty.
    (is eq nil (sse-channel-queue ch))
    ;; Emit two events.
    (emit ch "notifications/dsmr-mcp/attach/queued"
          (make-ht "position" 1 "holder_session_id" "sess-a"))
    (emit ch "notifications/test/second" nil)
    ;; Queue should hold two entries.
    (is = 2 (length (sse-channel-queue ch)))
    ;; The stream should be untouched — emit must not write to it directly.
    (is equal "" (get-output-stream-string out))))
