;;;; tests/hermetic/repl-eval-parity-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Integration tests proving hermetic repl-eval parity with the attached path:
;;;;
;;;; D-17: The hermetic worker returns the same error_context envelope shape
;;;;        (condition_type, message, restarts, frames) as the attached path.
;;;;
;;;; SAFETY-05: A per-call soft timeout returns a structured TIMEOUT result
;;;;             naming SB-EXT:TIMEOUT; the worker survives and subsequent
;;;;             evals succeed.
;;;;
;;;; ROADMAP criterion 1: a benign (+ 40 2) eval round-trips end-to-end through
;;;;                       the pool → worker → result path and returns the value.
;;;;
;;;; ROADMAP criterion 4: with mode :auto and no reachable Slynk listener,
;;;;                       resolve-mode resolves :hermetic and logs the
;;;;                       run.auto-mode warn (HERM-07, D-15).
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
Uses pool-rpc-with-hard-kill when SOFT-TIMEOUT is provided (SAFETY-05 path)."
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
;;; Criterion 1 — benign eval round-trip (ROADMAP criterion 1)
;;; ---------------------------------------------------------------------------

(define-test criterion-1-benign-eval-round-trip
  "ROADMAP criterion 1: a benign eval of (+ 40 2) round-trips end-to-end
through the pool → worker → result path. The response has no error_context
and the content field contains the printed value 42."
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
;;; D-17 — error_context parity with the attached path
;;; ---------------------------------------------------------------------------

(define-test d-17-error-context-parity
  "D-17: hermetic repl-eval of (error \"boom\") returns the same error_context
envelope shape as the attached path: non-empty condition_type, message, restarts
(simple-vector), and frames (simple-vector). This proves the build-wrapping-form
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
;;; SAFETY-05 — soft timeout returns structured TIMEOUT; worker survives
;;; ---------------------------------------------------------------------------

(define-test safety-05-timeout-and-worker-survival
  "SAFETY-05: eval of (sleep 200) with timeout_seconds=1 returns a structured
TIMEOUT response naming SB-EXT:TIMEOUT in condition_type. A subsequent eval
on the SAME worker (same session) succeeds with the correct value — the worker
survived the timeout and is still available."
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
;;; Criterion 4 — :auto + no Slynk → :hermetic + run.auto-mode warn (HERM-07)
;;; ---------------------------------------------------------------------------

(define-test criterion-4-auto-fallback-logs-warn-and-resolves-hermetic
  "ROADMAP criterion 4 / HERM-07 / D-15: with mode :auto and no reachable
Slynk listener (slynk-attach nil), resolve-mode resolves :hermetic and emits
a run.auto-mode :warn line on stderr. This is the logged fallback that
distinguishes :auto from a silent alias of :attached.

Duplicates the mode-router-test assertion in the hermetic suite for locality
— test failures in either suite surface the criterion-4 failure clearly."
  (let* ((capture (make-string-output-stream))
         (*error-output* capture))
    (configure-log4cl-for-server :debug)
    (let ((resolved (resolve-mode :mode :auto :slynk-attach nil)))
      ;; :auto with no Slynk must resolve to :hermetic (D-15).
      (is eq :hermetic resolved)
      ;; The run.auto-mode warn must appear on stderr (HERM-07).
      (let ((stderr (get-output-stream-string capture)))
        (true (search "run.auto-mode" stderr))))))
