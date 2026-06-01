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

(in-package #:dsmr-mcp/tests/integration/hermetic/worker-spawn-test)

;;; ---------------------------------------------------------------------------
;;; Spawn guard: the handshake test forks a real SBCL worker subprocess, so it
;;; skips cleanly (parachute skip, not fail) when the environment cannot spawn
;;; one — no sbcl on PATH, or no Quicklisp setup.lisp for the child to load
;;; dsmr-mcp. The framing tests below are pure in-process units and need no guard.
;;; ---------------------------------------------------------------------------

(defun %sbcl-path ()
  (or (ignore-errors
        (let ((r (string-trim '(#\Newline #\Return #\Space)
                              (uiop:run-program '("which" "sbcl")
                                                :output :string
                                                :ignore-error-status t))))
          (and (plusp (length r)) r)))
      (find-if #'probe-file '("/usr/local/bin/sbcl" "/usr/bin/sbcl" "/opt/local/bin/sbcl"))))

(defun %quicklisp-setup-present-p ()
  (and (probe-file (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))) t))

(defun %spawnable-p ()
  (and (%sbcl-path) (%quicklisp-setup-present-p)))

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

;;; ---------------------------------------------------------------------------
;;; Spawn + handshake integration test
;;; ---------------------------------------------------------------------------

(define-test worker-spawns-and-handshakes
  "spawn-worker launches a fresh SBCL image, reads the handshake,
connects to the TCP port, and returns a worker with a valid pid."
  (unless (%spawnable-p)
    (skip "cannot spawn a worker subprocess (sbcl / quicklisp setup.lisp absent)"))
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
          (ignore-errors (kill-worker w)))))))
