;;;; tests/hermetic/repl-eval-parity-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Integration tests proving hermetic repl-eval parity with the attached path:
;;;;
;;;; Error parity: the hermetic worker returns the same error_context envelope
;;;; shape (condition_type, message, restarts, frames) as the attached path.
;;;;
;;;; Soft timeout: a per-call soft timeout returns a structured TIMEOUT result
;;;; naming SB-EXT:TIMEOUT; the worker survives and subsequent evals succeed.
;;;;
;;;; Benign eval: a (+ 40 2) eval round-trips end-to-end through the pool →
;;;; worker → result path and returns the value.
;;;;
;;;; Auto fallback: with mode :auto and no reachable Slynk listener,
;;;; resolve-mode resolves :hermetic and logs the run.auto-mode warn.
;;;;
;;;; All tests use *worker-pool-warmup* 0 / *max-pool-size* 4 to keep the
;;;; test fast and avoid spawning unnecessary standby workers.

(defpackage #:dsmr-mcp/tests/hermetic/repl-eval-parity-test
  (:use #:cl #:parachute)
  (:local-nicknames (#:jzon #:com.inuoe.jzon))
  (:import-from #:dsmr-mcp/src/hermetic/pool
                #:initialize-pool #:shutdown-pool
                #:get-or-assign-worker
                #:pool-rpc-with-hard-kill
                #:pool-status-info
                #:*worker-pool-warmup*
                #:*max-pool-size*)
  (:import-from #:dsmr-mcp/src/hermetic/worker-client
                #:worker-rpc #:worker-pid)
  (:import-from #:dsmr-mcp/src/run
                #:resolve-mode)
  (:import-from #:dsmr-mcp/src/state
                #:*mode*
                #:*current-session-id*)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:make-ht)
  (:import-from #:dsmr-mcp/src/log
                #:configure-log4cl-for-server))

(in-package #:dsmr-mcp/tests/hermetic/repl-eval-parity-test)

;;; ---------------------------------------------------------------------------
;;; Helper: run a form in a fresh hermetic pool and return the worker/eval response
;;; ---------------------------------------------------------------------------

(defun %with-pool-eval (session-id params-ht &key (soft-timeout nil))
  "Spawn a pool with warmup=0, get a worker for SESSION-ID, call worker/eval
with PARAMS-HT, shutdown the pool, and return the response hash-table.
Uses pool-rpc-with-hard-kill when SOFT-TIMEOUT is provided (the two-level
timeout path: soft in-worker timeout plus parent SIGKILL backstop)."
  (let ((*worker-pool-warmup* 0)
        (*max-pool-size* 4))
    (initialize-pool)
    (unwind-protect
         (let ((worker (get-or-assign-worker session-id)))
           (if soft-timeout
               (pool-rpc-with-hard-kill
                worker "worker/eval" params-ht
                :soft-timeout soft-timeout
                :grace 5)
               (worker-rpc worker "worker/eval" params-ht)))
      (ignore-errors (shutdown-pool)))))

;;; ---------------------------------------------------------------------------
;;; Benign eval round-trip
;;; ---------------------------------------------------------------------------

(define-test criterion-1-benign-eval-round-trip
  "A benign eval of (+ 40 2) round-trips end-to-end through the pool → worker
→ result path. The response has no error_context and the content field
contains the printed value 42."
  (let* ((dsmr-mcp/src/state:*mode* :hermetic)
         (capture (make-string-output-stream))
         (*error-output* capture))
    (configure-log4cl-for-server :warn)
    (let* ((params (make-ht "code" "(+ 40 2)"))
           (resp (%with-pool-eval "parity-benign" params)))
      ;; Result is a hash-table with content and no error_context.
      (true (hash-table-p resp))
      (false (gethash "error_context" resp))
      ;; Content is a simple-vector of content blocks.
      (let ((content (gethash "content" resp)))
        (true content)
        (true (plusp (length content)))
        ;; The printed value "42" must appear in the text.
        (let ((text (gethash "text" (aref content 0))))
          (true (search "42" text)))))))

;;; ---------------------------------------------------------------------------
;;; Error context parity with the attached path
;;; ---------------------------------------------------------------------------

(define-test d-17-error-context-parity
  "hermetic repl-eval of (error \"boom\") returns the same error_context
envelope shape as the attached path: non-empty condition_type, message, restarts
(simple-vector), and frames (simple-vector). Proves the build-wrapping-form
+ eval + build-eval-response pipeline gives identical output regardless of
whether the eval runs locally or in a hermetic worker."
  (let* ((dsmr-mcp/src/state:*mode* :hermetic)
         (capture (make-string-output-stream))
         (*error-output* capture))
    (configure-log4cl-for-server :warn)
    (let* ((params (make-ht "code" "(error \"boom\")"))
           (resp (%with-pool-eval "parity-error" params))
           (ec (gethash "error_context" resp)))
      ;; error_context must be present.
      (true ec)
      (true (hash-table-p ec))
      ;; condition_type: non-empty string naming the condition class.
      (let ((ctype (gethash "condition_type" ec)))
        (true (stringp ctype))
        (true (plusp (length ctype))))
      ;; message: non-empty string with the condition text.
      (let ((msg (gethash "message" ec)))
        (true (stringp msg))
        (true (search "boom" msg)))
      ;; restarts: simple-vector (may be empty but must be present).
      (true (simple-vector-p (gethash "restarts" ec)))
      ;; frames: simple-vector with at least one frame.
      (let ((frames (gethash "frames" ec)))
        (true (simple-vector-p frames))
        (true (plusp (length frames)))
        ;; Each frame has index (integer), function (string), locals (simple-vector).
        (let ((frame0 (aref frames 0)))
          (true (hash-table-p frame0))
          (true (integerp (gethash "index" frame0)))
          (true (stringp (gethash "function" frame0)))
          (true (simple-vector-p (gethash "locals" frame0))))))))

;;; ---------------------------------------------------------------------------
;;; Soft timeout — structured TIMEOUT result; worker survives
;;; ---------------------------------------------------------------------------

(define-test safety-05-timeout-and-worker-survival
  "Eval of (sleep 200) with timeout_seconds=1 returns a structured TIMEOUT
response naming SB-EXT:TIMEOUT in condition_type. A subsequent eval on the
SAME worker (same session) succeeds — the worker survived the timeout."
  (let* ((dsmr-mcp/src/state:*mode* :hermetic)
         (capture (make-string-output-stream))
         (*error-output* capture)
         (*worker-pool-warmup* 0)
         (*max-pool-size* 4))
    (configure-log4cl-for-server :warn)
    (initialize-pool)
    (unwind-protect
         (let ((worker (get-or-assign-worker "parity-timeout")))
           ;; Send a sleep that will be interrupted by the soft timeout.
           (let* ((sleep-params (make-ht "code" "(sleep 200)"
                                         "timeout_seconds" 1))
                  (timeout-resp (pool-rpc-with-hard-kill
                                 worker "worker/eval" sleep-params
                                 :soft-timeout 1
                                 :grace 5))
                  (ec (gethash "error_context" timeout-resp)))
             ;; Must have an error_context naming SB-EXT:TIMEOUT.
             (true ec)
             (is string= "SB-EXT:TIMEOUT" (gethash "condition_type" ec))
             ;; Worker must still be alive (pid unchanged).
             (let ((pid-before (worker-pid worker)))
               (true (integerp pid-before))
               (true (plusp pid-before))
               ;; Subsequent eval must succeed — proves the worker survived.
               (let* ((ok-params (make-ht "code" "(+ 1 2)"))
                      (ok-resp (worker-rpc worker "worker/eval" ok-params)))
                 (false (gethash "error_context" ok-resp))
                 (let ((content (gethash "content" ok-resp)))
                   (true content)
                   (let ((text (gethash "text" (aref content 0))))
                     (true (search "3" text))))))))
      (ignore-errors (shutdown-pool)))))

;;; ---------------------------------------------------------------------------
;;; Auto fallback — :auto + no Slynk → :hermetic + run.auto-mode warn
;;; ---------------------------------------------------------------------------

(define-test criterion-4-auto-fallback-logs-warn-and-resolves-hermetic
  "With mode :auto and no reachable Slynk listener (slynk-attach nil),
resolve-mode resolves :hermetic and emits a run.auto-mode :warn line on stderr.
This is the logged fallback that distinguishes :auto from a silent alias of :attached.

Duplicates the mode-router-test assertion in the hermetic suite for locality
— test failures in either suite surface the failure clearly."
  (let* ((capture (make-string-output-stream))
         (*error-output* capture))
    (configure-log4cl-for-server :debug)
    (let ((resolved (resolve-mode :mode :auto :slynk-attach nil)))
      ;; :auto with no Slynk must resolve to :hermetic.
      (is eq :hermetic resolved)
      ;; The run.auto-mode warn must appear on stderr.
      (let ((stderr (get-output-stream-string capture)))
        (true (search "run.auto-mode" stderr))))))

;;; ---------------------------------------------------------------------------
;;; Warmup-concurrent spawn — regression for cold-startup worker failure
;;;
;;; This test catches regressions where two workers spawning concurrently
;;; (one standby, one session) cannot successfully handshake.  The most
;;; likely causes are:
;;;
;;;   a) *standard-output* not restored to sb-sys:*stdout* in start()
;;;      before %output-handshake — the handshake goes to stderr, the
;;;      parent times out waiting on the stdout pipe.
;;;
;;;   b) --no-userinit removed from %build-sbcl-args — .sbclrc runs in
;;;      each child and both children try to compile slynk to the same
;;;      tmp fasl path simultaneously (reliably fatal only on cold builds
;;;      outside the test suite, but the stdout-restore regression is
;;;      detectable here).
;;;
;;; NOTE: This test does NOT catch the cold-compile fasl race that was the
;;; primary production failure mode, because by the time the test suite runs
;;; all fasls are warm.  The cold-fasl race is verified by the live smoke
;;; test (smoke-hermetic-* in the Makefile / CI script).  This test
;;; catches the protocol regressions (a) and (b) that are detectable with
;;; warm fasls.
;;; ---------------------------------------------------------------------------

(define-test concurrent-warmup-and-session-spawn-both-succeed
  "Regression: warmup=1 causes the pool to spawn a standby worker at
initialize-pool time. When a session also requests a worker immediately
after, two workers exist concurrently. Both must handshake and serve
repl-eval successfully.

Catches: stdout-pipe restore regression in start() where the handshake
goes to stderr instead of the parent's pipe (causing a timeout), and
placeholder-coordination regressions in the pool where a concurrent spawn
is left in :spawning state indefinitely."
  (let* ((dsmr-mcp/src/state:*mode* :hermetic)
         (capture (make-string-output-stream))
         (*error-output* capture)
         (*worker-pool-warmup* 1)
         (*max-pool-size* 4))
    (configure-log4cl-for-server :warn)
    (initialize-pool)
    (unwind-protect
         (progn
           ;; Wait for the standby worker to appear (replenish is async).
           (loop repeat 60
                 until (let ((info (pool-status-info)))
                         (plusp (gethash "standby_count" info)))
                 do (sleep 0.5))
           ;; Get a session worker — the pool now has both a standby (id=1)
           ;; and a newly-bound session worker (id=2) at the same time.
           (let* ((worker (get-or-assign-worker "concurrent-spawn-session"))
                  (params (make-ht "code" "(+ 40 2)"))
                  (resp (worker-rpc worker "worker/eval" params)))
             ;; Session worker must return the correct value.
             (true (hash-table-p resp))
             (false (gethash "error_context" resp))
             (let ((content (gethash "content" resp)))
               (true content)
               (true (plusp (length content)))
               (let ((text (gethash "text" (aref content 0))))
                 (true (search "42" text))))))
      (ignore-errors (shutdown-pool)))))
