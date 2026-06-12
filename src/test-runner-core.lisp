;;;; src/test-runner-core.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Server-side facade over the test-runner engine
;;;; (src/test-runner-engine.lisp) shared between the attached-injection
;;;; path and the hermetic worker handler.
;;;;
;;;; The engine — framework detection, ghost purges, the framework
;;;; extractors, and the uniform result envelope — lives in a
;;;; dependency-free file so the attach path can load it into the
;;;; OPERATOR'S OWN image, where no dsmr-mcp system exists.  This facade
;;;; re-exports the engine's entry points for in-process callers (the
;;;; hermetic worker handler, tests), wires the engine's log hook to the
;;;; server's structured logger, and owns everything that must NOT enter a
;;;; foreign image:
;;;;
;;;;   %build-run-tests-form    — the sexp injected into the attached image:
;;;;                              a version-gated engine bootstrap (load the
;;;;                              engine file when its package is absent OR
;;;;                              its stamped fingerprint differs from the
;;;;                              file the server ships) followed by the
;;;;                              engine run and plist encoding.
;;;;   engine-source-path       — resolves the engine file the bootstrap
;;;;                              loads (override via *engine-source-path*
;;;;                              for tests).
;;;;   engine-fingerprint       — deterministic FNV-1a 64 content hash of
;;;;                              the engine file, computed per call on the
;;;;                              dispatcher; the bootstrap stamps it into
;;;;                              the image after a successful load.
;;;;
;;;; The version gate exists because attached dev images are long-lived
;;;; while the server restarts and upgrades under them: package presence
;;;; alone would pin an image to the first engine it ever loaded.

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
           #:%build-run-tests-form
           #:%build-engine-ensure-form
           #:*engine-source-path*
           #:engine-source-path
           #:engine-fingerprint))

(in-package #:dsmr-mcp/src/test-runner-core)

;;; Route the engine's diagnostics to the server's structured logger.  In a
;;; foreign attached image the hook stays NIL and the engine is silent.
(setf *log-hook* #'log-event)

;;; ---------------------------------------------------------------------------
;;; Engine source resolution and fingerprint
;;; ---------------------------------------------------------------------------

(defvar *engine-source-path* nil
  "When non-NIL, the engine file the attach bootstrap loads instead of the
one resolved from the dsmr-mcp checkout.  Tests point this at a temporary
copy to exercise the stale-engine reload path.")

(defun engine-source-path ()
  "Absolute namestring of the engine source file the bootstrap loads,
coerced to a character string so it can be embedded in an injected form."
  (let ((path (or *engine-source-path*
                  (asdf:system-relative-pathname
                   "dsmr-mcp" "src/test-runner-engine.lisp"))))
    (map 'string #'identity (namestring (truename path)))))

(defun engine-fingerprint (path)
  "Deterministic content fingerprint of the file at PATH: FNV-1a 64 over
its octets, rendered as a fixed-width hex string.  Implementation-portable
on purpose — the value is compared against a copy stamped into a possibly
different Lisp image, so it must not depend on sxhash."
  (with-open-file (s path :element-type '(unsigned-byte 8))
    (let ((hash 14695981039346656037))
      (loop for byte = (read-byte s nil nil)
            while byte
            do (setf hash (ldb (byte 64 0)
                               (* (logxor hash byte) 1099511628211))))
      (map 'string #'identity (format nil "fnv1a64:~16,'0X" hash)))))

;;; ---------------------------------------------------------------------------
;;; Injected forms
;;; ---------------------------------------------------------------------------

(defun %build-engine-ensure-form (engine-path fingerprint)
  "Return the version-gated engine-bootstrap sexp.

Evaluated in the attached image, it returns :CURRENT when the engine
package exists and its stamped *LOADED-FINGERPRINT* equals FINGERPRINT,
otherwise loads ENGINE-PATH (compile/load chatter muffled), stamps
FINGERPRINT, and returns :LOADED.  Errors during the load propagate to the
caller's handler — %build-run-tests-form converts them to its (:error ...)
arm with an \"engine bootstrap failed\" prefix.

Wire discipline matches the registry ensure-form (src/attach/registry.lisp):
bound vars interned in CL-USER under the %DSMR-RUNNER- prefix, package and
symbol names as character-string literals, no loop / #\\ / #( syntax."
  (flet ((cs (n) (intern n (find-package :common-lisp-user))))
    (let ((s-pkg   (cs "%DSMR-RUNNER-ENSURE-PKG"))
          (s-fpsym (cs "%DSMR-RUNNER-ENSURE-FPSYM"))
          (s-stamp (cs "%DSMR-RUNNER-ENSURE-STAMP")))
      `(let* ((,s-pkg (find-package ,(map 'string #'identity
                                          "DSMR-MCP/SRC/TEST-RUNNER-ENGINE")))
              (,s-fpsym (and ,s-pkg
                             (find-symbol ,(map 'string #'identity
                                                "*LOADED-FINGERPRINT*")
                                          ,s-pkg)))
              (,s-stamp (and ,s-fpsym
                             (boundp ,s-fpsym)
                             (symbol-value ,s-fpsym))))
         (if (and ,s-pkg (equal ,s-stamp ,fingerprint))
             :current
             (let ((*load-verbose* nil)
                   (*compile-verbose* nil)
                   (*load-print* nil)
                   (*compile-print* nil)
                   (*standard-output* (make-broadcast-stream))
                   (*error-output* (make-broadcast-stream)))
               (load ,engine-path)
               (setf (symbol-value
                      (find-symbol
                       ,(map 'string #'identity "*LOADED-FINGERPRINT*")
                       (find-package ,(map 'string #'identity
                                           "DSMR-MCP/SRC/TEST-RUNNER-ENGINE"))))
                     ,fingerprint)
               :loaded))))))

(defun %build-run-tests-form (system-name framework test tests
                              timeout-seconds reload)
  "Return the sexp that, when evaluated in the attached image, ensures the
test-runner engine is present and current, then runs tests for SYSTEM-NAME
under sb-ext:with-timeout.

Bootstrap (version-gated, idempotent): when the engine package is absent
from the image, or its stamped *LOADED-FINGERPRINT* differs from the
fingerprint of the engine file the server ships, the form loads the engine
source (compile/load chatter muffled) and stamps the new fingerprint.  When
package and fingerprint match, the gate is two lookups and a string
compare.  A bootstrap failure returns (:error ...) naming the bootstrap and
carrying the condition text.

All helper symbols are interned in CL-USER with the %DSMR-RUNNER- prefix to
satisfy the Slynk IO-package constraint (symbols not in CL or CL-USER get
package-qualified and the remote reader fails).  No loop keyword inside the
form — uses dolist/do*.  Strings embedded in the form are coerced to
character strings dispatcher-side so no base-string literal crosses the
wire.

Returns one of:
  (list :ok RESULT-HASH-PLIST)    — run completed; result is encoded as a plist
  (list :timeout TIMEOUT-SECS)   — sb-ext:with-timeout fired
  (list :error ERROR-STRING)     — error signalled during bootstrap or setup"
  (let* ((effective-timeout (or timeout-seconds 300))
         (fw-str (and framework
                      (if (stringp framework) framework (symbol-name framework))))
         (engine-path (engine-source-path))
         (fingerprint (engine-fingerprint engine-path)))
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
            (s-stamp   (cs "%DSMR-RUNNER-STAMP"))
            (s-testfn  (cs "%DSMR-RUNNER-TESTFN"))
            (s-e       (cs "%DSMR-RUNNER-E"))
            (s-be      (cs "%DSMR-RUNNER-BE"))
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
               (progn
                 ;; Engine bootstrap, version-gated.  The package may exist
                 ;; with a different (or no) fingerprint — a long-lived
                 ;; image under an upgraded server, or the server's own
                 ;; image where the engine arrived via ASDF — and both
                 ;; cases reload so image and server agree on one engine.
                 (let* ((,s-pkg (find-package ,(map 'string #'identity
                                                    "DSMR-MCP/SRC/TEST-RUNNER-ENGINE")))
                        (,s-stamp (and ,s-pkg
                                       (let ((,s-testfn (find-symbol
                                                         ,(map 'string #'identity
                                                               "*LOADED-FINGERPRINT*")
                                                         ,s-pkg)))
                                         (and ,s-testfn
                                              (boundp ,s-testfn)
                                              (symbol-value ,s-testfn))))))
                   (unless (and ,s-pkg (equal ,s-stamp ,fingerprint))
                     (handler-case
                         (let ((*load-verbose* nil)
                               (*compile-verbose* nil)
                               (*load-print* nil)
                               (*compile-print* nil)
                               (*standard-output* (make-broadcast-stream))
                               (*error-output* (make-broadcast-stream)))
                           (load ,engine-path)
                           (setf (symbol-value
                                  (find-symbol
                                   ,(map 'string #'identity "*LOADED-FINGERPRINT*")
                                   (find-package ,(map 'string #'identity
                                                       "DSMR-MCP/SRC/TEST-RUNNER-ENGINE"))))
                                 ,fingerprint))
                       (serious-condition (,s-be)
                         (throw :%dsmr-runner-debug-unwind
                           (list :error
                                 (concatenate
                                  'string
                                  (map 'string #'identity
                                       "engine bootstrap failed: ")
                                  (or (ignore-errors
                                        (map 'string #'identity
                                             (princ-to-string ,s-be)))
                                      "<error formatting condition>"))))))))
                 (let ((,s-sys ,system-name))
                   ;; Run via the engine's run-tests, present after the
                   ;; bootstrap above; found dynamically so this form never
                   ;; names a symbol the reader must resolve at read time.
                   (let* ((,s-pkg    (find-package ,(map 'string #'identity
                                                         "DSMR-MCP/SRC/TEST-RUNNER-ENGINE")))
                          (,s-testfn (and ,s-pkg
                                          (find-symbol ,(map 'string #'identity
                                                             "RUN-TESTS")
                                                       ,s-pkg))))
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
                         ;; Unreachable unless the bootstrap loaded a file
                         ;; that does not define the engine — report it.
                         (list :error (map 'string #'identity
                                           "engine bootstrap failed: package or RUN-TESTS missing after load")))))))
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
