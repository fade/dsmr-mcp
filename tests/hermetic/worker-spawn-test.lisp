;;;; tests/hermetic/worker-spawn-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Wave-0 scaffold for HERM-01 (worker spawn + handshake) and HERM-02
;;;; (newline-delimited JSON framing, 16 MB line cap).
;;;;
;;;; Unit tests for the framing cap and happy-path line parsing run cold
;;;; without spawning any process. The integration test that calls
;;;; spawn-worker directly is gated: it is a structural test that verifies
;;;; worker-client plumbing only; full round-trip (worker answering repl-eval)
;;;; becomes green once 04-01 (worker accept loop) lands and makes
;;;; dsmr-mcp/src/hermetic/worker/main:start available.

(defpackage #:dsmr-mcp/tests/hermetic/worker-spawn-test
  (:use #:cl #:parachute)
  (:local-nicknames (#:jzon #:com.inuoe.jzon))
  (:import-from #:dsmr-mcp/src/hermetic/worker-client
                #:+max-json-line-bytes+
                #:%read-line-limited
                #:line-too-long
                #:spawn-worker
                #:worker-pid
                #:worker-tcp-port
                #:kill-worker)
  (:import-from #:dsmr-mcp/src/log
                #:configure-log4cl-for-server))

(in-package #:dsmr-mcp/tests/hermetic/worker-spawn-test)

;;; ---------------------------------------------------------------------------
;;; HERM-02: framing — unit tests (no process spawn, run cold)
;;; ---------------------------------------------------------------------------

(define-test framing-cap-enforced
  "HERM-02: %read-line-limited signals line-too-long when a line exceeds
the explicit limit. Uses a small synthetic limit to avoid allocating 16 MB.
Uses parachute (fail ...) which asserts the form signals a condition of the
given type."
  ;; Feed 10 characters (no newline); limit is 5 — must signal line-too-long.
  (let ((stream (make-string-input-stream "0123456789")))
    (fail (%read-line-limited stream :eof 5) 'line-too-long)))

(define-test framing-cap-constant
  "HERM-02: +max-json-line-bytes+ is exactly 16 MB (16 * 1024 * 1024)."
  (is = (* 16 1024 1024) +max-json-line-bytes+))

(define-test framing-newline-happy-path
  "HERM-02: %read-line-limited reads two newline-delimited JSON lines
correctly from a string-input-stream."
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
  "HERM-02: %read-line-limited returns the supplied eof-value on empty stream."
  (let ((stream (make-string-input-stream "")))
    (is eq :eof (%read-line-limited stream :eof +max-json-line-bytes+))))

(define-test framing-crlf-stripped
  "HERM-02: %read-line-limited strips CR before LF (CRLF tolerance)."
  (let* ((line (concatenate 'string "hello" (string #\Return) (string #\Newline)))
         (stream (make-string-input-stream line))
         (got (%read-line-limited stream :eof +max-json-line-bytes+)))
    ;; The carriage return must not appear in the returned string.
    (is string= "hello" got)))

;;; ---------------------------------------------------------------------------
;;; HERM-01: spawn + handshake integration test
;;;
;;; NOTE: spawn-worker calls (asdf:load-system :dsmr-mcp/src/hermetic/worker/main)
;;; inside the spawned SBCL child. That system does not exist yet in this
;;; Wave-0 foundation build — the worker accept loop lands in plan 04-01.
;;; Therefore this test is commented out. When 04-01 lands, uncomment and
;;; verify the integration path end-to-end.
;;; ---------------------------------------------------------------------------

;; (define-test worker-spawns-and-handshakes
;;   "HERM-01: spawn-worker launches a fresh SBCL image, reads the handshake,
;; connects to the TCP port, and returns a worker with a valid pid.
;; Requires plan 04-01 (worker/main) to be present."
;;   (let* ((capture (make-string-output-stream))
;;          (*error-output* capture))
;;     (configure-log4cl-for-server :debug)
;;     (let ((w nil))
;;       (unwind-protect
;;            (progn
;;              (setf w (spawn-worker))
;;              (true (integerp (worker-pid w)))
;;              (true (plusp (worker-pid w)))
;;              (true (integerp (worker-tcp-port w)))
;;              (true (plusp (worker-tcp-port w))))
;;         (when w
;;           (ignore-errors (kill-worker w)))))))
