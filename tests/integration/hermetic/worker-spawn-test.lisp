;;;; tests/hermetic/worker-spawn-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Tests for worker spawn + handshake and newline-delimited JSON framing
;;;; (16 MB line cap).
;;;;
;;;; Unit tests for the framing cap and happy-path line parsing run cold
;;;; without spawning any process. The integration test that calls
;;;; spawn-worker directly is gated: it verifies worker-client plumbing only;
;;;; the full round-trip requires the worker accept loop to be present.

(defpackage #:dsmr-mcp/tests/integration/hermetic/worker-spawn-test
  (:use #:cl #:zebra)
  (:local-nicknames (#:jzon #:com.inuoe.jzon))
  (:import-from #:dsmr-mcp/src/hermetic/worker-client
                #:+max-json-line-bytes+
                #:%read-line-limited
                #:%read-json-rpc-response
                #:line-too-long
                #:spawn-worker
                #:worker-pid
                #:worker-tcp-port
                #:kill-worker)
  (:import-from #:dsmr-mcp/src/log
                #:configure-log4cl-for-server)
  (:import-from #:dsmr-mcp/tests/integration/support
                #:with-worker-child-or-skip))

(in-package #:dsmr-mcp/tests/integration/hermetic/worker-spawn-test)

;;; ---------------------------------------------------------------------------
;;; The handshake test forks a real SBCL worker subprocess, so it skips cleanly
;;; (and only when the environment genuinely cannot build a worker child) via
;;; WITH-WORKER-CHILD-OR-SKIP — see tests/integration/support.lisp for why a
;;; presence check alone is insufficient. The framing tests below are pure
;;; in-process units and need no guard.
;;; ---------------------------------------------------------------------------

;;; ---------------------------------------------------------------------------
;;; Framing — unit tests (no process spawn, run cold)
;;; ---------------------------------------------------------------------------

(define-test framing-cap-enforced
  "%read-line-limited signals line-too-long when a line exceeds the explicit
limit. Uses a small synthetic limit to avoid allocating 16 MB."
  ;; Feed 10 characters (no newline); limit is 5 — must signal line-too-long.
  (let ((stream (make-string-input-stream "0123456789")))
    (fail (%read-line-limited stream :eof 5) 'line-too-long)))

(define-test framing-cap-constant
  "+max-json-line-bytes+ is exactly 16 MB (16 * 1024 * 1024)."
  (is = (* 16 1024 1024) +max-json-line-bytes+))

(define-test framing-newline-happy-path
  "%read-line-limited reads two newline-delimited JSON lines correctly."
  (let* ((line1 "{\"a\":1}")
         (line2 "{\"b\":2}")
         (input (concatenate 'string line1 (string #\Newline)
                             line2 (string #\Newline)))
         (stream (make-string-input-stream input)))
    ;; First line
    (let ((got1 (%read-line-limited stream :eof +max-json-line-bytes+)))
      (true (stringp got1))
      (is string= line1 got1)
      (let ((parsed1 (jzon:parse got1)))
        (true (hash-table-p parsed1))
        (is = 1 (gethash "a" parsed1))))
    ;; Second line
    (let ((got2 (%read-line-limited stream :eof +max-json-line-bytes+)))
      (true (stringp got2))
      (is string= line2 got2)
      (let ((parsed2 (jzon:parse got2)))
        (true (hash-table-p parsed2))
        (is = 2 (gethash "b" parsed2))))))

(define-test framing-eof-returns-eof-value
  "%read-line-limited returns the supplied eof-value on empty stream."
  (let ((stream (make-string-input-stream "")))
    (is eq :eof (%read-line-limited stream :eof +max-json-line-bytes+))))

(define-test framing-crlf-stripped
  "%read-line-limited strips CR before LF (CRLF tolerance)."
  (let* ((line (concatenate 'string "hello" (string #\Return) (string #\Newline)))
         (stream (make-string-input-stream line))
         (got (%read-line-limited stream :eof +max-json-line-bytes+)))
    ;; The carriage return must not appear in the returned string.
    (is string= "hello" got)))

(define-test a-late-answer-to-an-abandoned-request-is-skipped
  "A reply carrying an id older than the one being waited for is discarded.

A caller that stops waiting leaves its answer in flight. Reading that answer as
though it belonged to the next request would report the wrong result or condemn
a channel that is working, so the reader steps over it and keeps going. This is
what lets a liveness probe give up on one ping and still read the next one
correctly."
  (let* ((stale  "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"which\":\"stale\"}}")
         (wanted "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"which\":\"wanted\"}}")
         (stream (make-string-input-stream
                  (concatenate 'string stale (string #\Newline)
                               wanted (string #\Newline))))
         (got    (%read-json-rpc-response stream 2 nil)))
    (true (hash-table-p got))
    (is string= "wanted" (gethash "which" got))))

(define-test an-answer-to-a-request-never-sent-is-still-a-protocol-error
  "A reply carrying an id ahead of the one being waited for still fails.

This is the control on the test above. Skipping older replies is a narrow
allowance with a reason behind it, and if it widened into skipping every
mismatch the reader would sit quietly on a desynchronised channel forever.
Nothing can legitimately answer a request that has not been sent, so an id
ahead of the current one is corruption and is treated as such."
  (let* ((line   "{\"jsonrpc\":\"2.0\",\"id\":5,\"result\":{}}")
         (stream (make-string-input-stream
                  (concatenate 'string line (string #\Newline)))))
    (fail (%read-json-rpc-response stream 2 nil) 'error)))

;;; ---------------------------------------------------------------------------
;;; Spawn + handshake integration test
;;; ---------------------------------------------------------------------------

(define-test worker-spawns-and-handshakes
  "spawn-worker launches a fresh SBCL image, reads the handshake,
connects to the TCP port, and returns a worker with a valid pid."
  (with-worker-child-or-skip
    (let* ((capture (make-string-output-stream))
           (*error-output* capture))
      (configure-log4cl-for-server :debug)
      (let ((w nil))
        (unwind-protect
             (progn
               (setf w (spawn-worker))
               (true (integerp (worker-pid w)))
               (true (plusp (worker-pid w)))
               (true (integerp (worker-tcp-port w)))
               (true (plusp (worker-tcp-port w))))
          (when w
            (ignore-errors (kill-worker w))))))))
