;;;; tests/tools/restart-process-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Coverage for the rung-3 terminal restart verb (restart-process), the
;;;; sentinel exit code, and the mockable exit primitive.
;;;;
;;;; The verb's whole point is to exit the process, which would kill the test
;;;; image. To exercise the restart path safely, *restart-exit-fn* is rebound to
;;;; a recording closure: the tests then assert the sentinel code is delivered
;;;; exactly once without the image dying. A semaphore synchronizes with the
;;;; deferred exit thread so the assertions never race it.

;; Package evolution guard: drop a prior incarnation so a reload picks up the
;; current import/export set rather than stale symbols.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/tools/restart-process-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/tools/restart-process-test
  (:use #:cl #:zebra)
  (:import-from #:dsmr-mcp/src/tools/restart-process
                #:restart-process-tool
                #:+restart-exit-code+
                #:%trigger-restart-exit
                #:*restart-exit-fn*
                ;; Internal knob: import (not exported) so tests can pin the
                ;; deferral delay to 0 for determinism.
                #:*restart-exit-delay*)
  (:import-from #:dsmr-mcp/src/tools/base
                #:tool-handle))

(in-package #:dsmr-mcp/tests/tools/restart-process-test)

;;; ---------------------------------------------------------------------------
;;; Sentinel constant
;;; ---------------------------------------------------------------------------

(define-test sentinel-is-ex-tempfail
  "The restart sentinel is 75 (EX_TEMPFAIL), the value the launcher keys on."
  (is = 75 +restart-exit-code+))

;;; ---------------------------------------------------------------------------
;;; The exit primitive, mocked
;;; ---------------------------------------------------------------------------

(define-test trigger-invokes-bound-exit-fn-once-with-sentinel
  "Calling %trigger-restart-exit invokes the bound exit function exactly once
with the sentinel code, and does NOT terminate the test image."
  (let* ((codes '())
         (*restart-exit-fn* (lambda (code) (push code codes))))
    (%trigger-restart-exit)
    (is = 1 (length codes) "exit fn invoked exactly once")
    (is = +restart-exit-code+ (first codes) "with the sentinel code")))

;;; ---------------------------------------------------------------------------
;;; The verb: result first, then the deferred sentinel exit
;;; ---------------------------------------------------------------------------

(define-test verb-returns-result-then-triggers-sentinel-exit
  "tool-handle returns a result with isError nil, then the deferred exit fires
exactly once with the sentinel — the image is not killed. The recording closure
signals a semaphore the test waits on so it never races the exit thread."
  (let* ((codes '())
         (sem (sb-thread:make-semaphore))
         (*restart-exit-fn* (lambda (code)
                              (push code codes)
                              (sb-thread:signal-semaphore sem)))
         (*restart-exit-delay* 0)
         (tool (make-instance 'restart-process-tool))
         (response (tool-handle tool "req-restart-process" nil))
         (payload (gethash "result" response)))
    (false (gethash "isError" payload)
           "the result is returned with isError nil before the exit fires")
    (true (gethash "content" payload) "the result carries content")
    (true (sb-thread:wait-on-semaphore sem :timeout 5)
          "the deferred restart exit fires")
    (is = 1 (length codes) "exit fn invoked exactly once")
    (is = +restart-exit-code+ (first codes) "with the sentinel code")))
