;;;; src/test-runner-core.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Server-side facade over the test-runner engine
;;;; (src/test-runner-engine.lisp) shared between the attached-injection
;;;; path and the hermetic worker handler.
;;;;
;;;; The engine — framework detection, ghost purges, the framework
;;;; extractors, and the uniform result envelope — lives in a
;;;; dependency-free file so it can run in images where no dsmr-mcp
;;;; system exists.  This facade re-exports the engine's entry points for
;;;; in-process callers (the hermetic worker handler, tests), wires the
;;;; engine's log hook to the server's structured logger, and owns the
;;;; attached-injection form builder, which must not enter a foreign image.

(defpackage #:dsmr-mcp/src/test-runner-core
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/log
                #:log-event)
  (:import-from #:dsmr-mcp/src/test-runner-engine
                #:run-tests
                #:detect-test-framework
                #:test-result-summary
                #:%parachute-purge-ghost-suites
                #:%rove-purge-ghost-suites
                #:*test-debug-output*
                #:*log-hook*
                #:*loaded-fingerprint*)
  (:import-from #:asdf)
  (:import-from #:uiop)
  (:import-from #:sb-ext)
  (:export #:run-tests
           #:detect-test-framework
           #:test-result-summary
           #:%parachute-purge-ghost-suites
           #:%rove-purge-ghost-suites
           #:*test-debug-output*
           #:%build-run-tests-form))

(in-package #:dsmr-mcp/src/test-runner-core)

;;; Route the engine's diagnostics to the server's structured logger.  In a
;;; foreign attached image the hook stays NIL and the engine is silent.
(setf *log-hook* #'log-event)

;;; ---------------------------------------------------------------------------
;;; Injected form
;;; ---------------------------------------------------------------------------

(defun %build-run-tests-form (system-name framework test tests
                              timeout-seconds reload)
  "Return the sexp that, when evaluated in the attached image, runs tests for
SYSTEM-NAME under sb-ext:with-timeout.

The form performs ghost-purge + ASDF reload (unless reload=false) inside the
attached image so edits made via lisp-edit-form become live before the run.
All helper symbols are interned in CL-USER with the %DSMR-RUNNER- prefix to
satisfy the Slynk IO-package constraint (symbols not in CL or CL-USER get
package-qualified and the remote reader fails). No loop keyword inside the form
— uses dolist/do*.

Returns one of:
  (list :ok RESULT-HASH-PLIST)    — run completed; result is encoded as a plist
  (list :timeout TIMEOUT-SECS)   — sb-ext:with-timeout fired
  (list :error ERROR-STRING)     — error signalled during setup"
  (let* ((effective-timeout (or timeout-seconds 300))
         (fw-str (and framework
                      (if (stringp framework) framework (symbol-name framework)))))
    (flet ((cs (n) (intern n (find-package :common-lisp-user))))
      (let ((s-sys     (cs "%DSMR-RUNNER-SYS"))
            (s-fw      (cs "%DSMR-RUNNER-FW"))
            (s-result  (cs "%DSMR-RUNNER-RESULT"))
            (s-passed  (cs "%DSMR-RUNNER-PASSED"))
            (s-failed  (cs "%DSMR-RUNNER-FAILED"))
            (s-pending (cs "%DSMR-RUNNER-PENDING"))
            (s-dur     (cs "%DSMR-RUNNER-DUR"))
            (s-fails   (cs "%DSMR-RUNNER-FAILS"))
            (s-pkg     (cs "%DSMR-RUNNER-PKG"))
            (s-testfn  (cs "%DSMR-RUNNER-TESTFN"))
            (s-e       (cs "%DSMR-RUNNER-E"))
            (s-hook    (cs "%DSMR-RUNNER-DEBUG-HOOK"))
            (s-c       (cs "%DSMR-RUNNER-C"))
            (s-h       (cs "%DSMR-RUNNER-H")))
        ;; Debugger backstop + serious-condition arm: same rationale and
        ;; same shape as %build-load-system-form (system-loader-core.lisp) —
        ;; a debugger entry in the attached image parks the rex worker
        ;; forever, so BREAK / INVOKE-DEBUGGER inside a test body must be
        ;; converted to the (:error MSG) arm via throw.
        `(catch :%dsmr-runner-debug-unwind
           (let ((,s-hook (lambda (,s-c ,s-h)
                            (declare (ignore ,s-h))
                            (throw :%dsmr-runner-debug-unwind
                              (list :error
                                    (or (ignore-errors
                                          (map 'string #'identity
                                               (princ-to-string ,s-c)))
                                        "<error formatting condition>"))))))
             (let ((*debugger-hook* ,s-hook)
                   (sb-ext:*invoke-debugger-hook* ,s-hook))
               (handler-case
                   (sb-ext:with-timeout ,effective-timeout
               (let ((,s-sys ,system-name))
                 ;; Run via the test-runner-core's run-tests function in-image.
                 ;; The core is loaded in the attached image since dsmr-mcp is
                 ;; the server itself; find it dynamically.
                 (let* ((,s-pkg    (find-package :dsmr-mcp/src/test-runner-core))
                        (,s-testfn (and ,s-pkg
                                        (find-symbol "RUN-TESTS" ,s-pkg))))
                   (if ,s-testfn
                       (let ((,s-result (funcall ,s-testfn ,s-sys
                                                 :framework ,(and fw-str fw-str)
                                                 :test ,test
                                                 :tests ,tests
                                                 :timeout-seconds ,(max 1 (- effective-timeout 1))
                                                 :reload ,reload)))
                         ;; Encode the result hash-table as a plist for wire transfer.
                         ;; Only encode the fields we need; hash-tables can't cross the rex.
                         (let ((,s-passed  (gethash "passed"      ,s-result 0))
                               (,s-failed  (gethash "failed"      ,s-result 0))
                               (,s-pending (gethash "pending"     ,s-result 0))
                               (,s-dur     (gethash "duration_ms" ,s-result 0))
                               (,s-fw      (gethash "framework"   ,s-result "unknown"))
                               ;; (vector) not #(): this form crosses the Slynk wire, whose
                               ;; SWANK->SLYNK translating reader cannot read the #( dispatch
                               ;; and corrupts the message. (vector) is an empty-vector
                               ;; constructor in plain list syntax that survives the wire.
                               (,s-fails   (gethash "failed_tests" ,s-result (vector))))
                           (list :ok
                                 (list :passed  ,s-passed
                                       :failed  ,s-failed
                                       :pending ,s-pending
                                       :duration ,s-dur
                                       :framework (map 'string #'identity ,s-fw)
                                       :failed-count (length ,s-fails)))))
                       ;; test-runner-core not loaded in attached image — fall back.
                       (list :error (map 'string #'identity
                                         "test-runner-core not loaded in attached image; use hermetic mode"))))))
                 ;; sb-ext:timeout is a serious-condition, not error — the
                 ;; earlier-clause rule routes it here, not to the arm below.
                 (sb-ext:timeout ()
                   (list :timeout ,effective-timeout))
                 ;; serious-condition, not error: STORAGE-CONDITION and
                 ;; SB-SYS:INTERACTIVE-INTERRUPT are serious-but-not-error and
                 ;; would otherwise reach the image's debugger.
                 (serious-condition (,s-e)
                   (list :error (map 'string #'identity
                                     (princ-to-string ,s-e))))))))))))
