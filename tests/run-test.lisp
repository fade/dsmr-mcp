;;;; tests/run-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Tests for dsmr-mcp:run transport stubs and keyword/env precedence.
;;;; Asserts via the non-blocking resolve-transport seam so tests never
;;;; enter the blocking :stdio loop (D-17).

(defpackage #:dsmr-mcp/tests/run-test
  (:use #:cl #:parachute)
  (:import-from #:dsmr-mcp/src/run
                #:run
                #:resolve-transport
                #:resolve-mode
                #:transport-not-implemented-error
                #:invalid-config-value))

(in-package #:dsmr-mcp/tests/run-test)

;;; ---------------------------------------------------------------------------
;;; Transport stub tests (D-17)
;;; ---------------------------------------------------------------------------

(define-test tcp-stub-signals-transport-not-implemented
  "D-17: run :transport :tcp signals transport-not-implemented-error in Phase 1."
  (fail (run :transport :tcp) transport-not-implemented-error))

(define-test http-stub-signals-transport-not-implemented
  "D-17: run :transport :http signals transport-not-implemented-error in Phase 1."
  (fail (run :transport :http) transport-not-implemented-error))

;;; ---------------------------------------------------------------------------
;;; Keyword/env precedence (D-15)
;;; ---------------------------------------------------------------------------

(define-test keyword-beats-env-for-transport
  "D-15: an explicit :transport keyword overrides DSMR_TRANSPORT env var.
Uses resolve-transport to avoid entering the blocking :stdio loop."
  (let ((old-val (uiop:getenv "DSMR_TRANSPORT")))
    (unwind-protect
         (progn
           ;; Set env to "tcp" — keyword :stdio should still win.
           (setf (uiop:getenv "DSMR_TRANSPORT") "tcp")
           (is eq :stdio (resolve-transport :transport :stdio)))
      ;; Restore original env value.
      (if old-val
          (setf (uiop:getenv "DSMR_TRANSPORT") old-val)
          (setf (uiop:getenv "DSMR_TRANSPORT") "")))))

(define-test env-beats-default-for-transport
  "D-15: DSMR_TRANSPORT env var overrides the :stdio built-in default
when no keyword is passed.  Uses resolve-transport (non-blocking seam)."
  (let ((old-val (uiop:getenv "DSMR_TRANSPORT")))
    (unwind-protect
         (progn
           ;; Set env to "tcp" — no keyword passed, so env should win.
           (setf (uiop:getenv "DSMR_TRANSPORT") "tcp")
           (is eq :tcp (resolve-transport)))
      ;; Restore original env value.
      (if old-val
          (setf (uiop:getenv "DSMR_TRANSPORT") old-val)
          (setf (uiop:getenv "DSMR_TRANSPORT") "")))))

(define-test falsy-conf-value-beats-built-in-default
  "WR-01: a legitimately-falsy value stored in the conf plist (nil, 0) must
be honoured over the built-in default.  Tests the sentinel-based fix to
%or-from-env that distinguishes 'key present with falsy value' from 'key absent'.
Exercises the :slynk-attach nil and :port 0 cases that were previously
silently replaced by the built-in default."
  ;; :slynk-attach nil in conf => result should be nil, NOT the default "host:7777"
  (let ((result (dsmr-mcp/src/run::%or-from-env
                 nil            ; not supplied by caller
                 nil            ; keyword-value irrelevant
                 "DSMR_SLYNK_ATTACH"
                 '(:slynk-attach nil)  ; conf explicitly stores nil
                 "host:7777"           ; built-in default
                 :parse #'identity)))
    (is eq nil result))
  ;; :port 0 in conf => result should be 0, NOT the default 8080
  (let ((result (dsmr-mcp/src/run::%or-from-env
                 nil nil "DSMR_PORT"
                 '(:port 0)   ; conf explicitly stores 0
                 8080
                 :parse #'identity)))
    (is = 0 result))
  ;; Absent key => result should be the default (not nil)
  (let ((result (dsmr-mcp/src/run::%or-from-env
                 nil nil "DSMR_SLYNK_ATTACH"
                 '(:transport :stdio)  ; slynk-attach key absent
                 "host:7777"
                 :parse #'identity)))
    (is equal "host:7777" result)))

(define-test bad-dsmr-transport-env-signals-typed-error
  "WR-02: DSMR_TRANSPORT=banana must signal INVALID-CONFIG-VALUE (a typed
error subclass) rather than a raw case-failure.  Exercises the typed error
path without calling run (which would block on stdio)."
  (fail (dsmr-mcp/src/run::%parse-transport "banana") invalid-config-value))

(define-test bad-dsmr-port-env-signals-typed-error
  "WR-02: a non-integer DSMR_PORT value must signal INVALID-CONFIG-VALUE
rather than crashing with an unhandled parse-integer error.  Uses run with
an explicit :transport :tcp to avoid entering the stdio loop; the port
parse fires eagerly inside the let* before the transport dispatch."
  (let ((old-val (uiop:getenv "DSMR_PORT")))
    (unwind-protect
         (progn
           (setf (uiop:getenv "DSMR_PORT") "abc")
           ;; run with :tcp avoids the stdio loop; port is resolved eagerly
           ;; in the let* so the invalid-config-value fires first.
           (fail (run :transport :tcp) invalid-config-value))
      (if old-val
          (setf (uiop:getenv "DSMR_PORT") old-val)
          (setf (uiop:getenv "DSMR_PORT") "")))))

;;; ---------------------------------------------------------------------------
;;; Mode resolution — criterion 1 (D-01, D-02, D-15, HERM-07)
;;;
;;; resolve-mode is the non-blocking seam mirroring resolve-transport: it runs
;;; the keyword > env > conf > default resolution for the dispatch mode and
;;; performs the real :auto Slynk probe (Phase 4: resolves to :attached when
;;; reachable, emits a :warn and returns :hermetic when not).  These tests
;;; assert mode resolution WITHOUT entering the blocking :stdio loop.
;;; ---------------------------------------------------------------------------

(define-test criterion-1-keyword-slynk-attach-sets-attached
  "Criterion 1: with a :slynk-attach target configured, the mode resolves to
:ATTACHED (the default).  resolve-mode mirrors resolve-transport's seam and
never enters the stdio loop."
  (is eq :attached (resolve-mode :slynk-attach "127.0.0.1:9999")))

(define-test criterion-1-env-slynk-attach-sets-attached
  "Criterion 1: with DSMR_SLYNK_ATTACH bound (and DSMR_MODE unset), mode
resolves to :ATTACHED via the env path.  Bind/restore both env vars with
unwind-protect so the test leaves the environment unchanged."
  (let ((old-sa (uiop:getenv "DSMR_SLYNK_ATTACH"))
        (old-mode (uiop:getenv "DSMR_MODE")))
    (unwind-protect
         (progn
           (setf (uiop:getenv "DSMR_SLYNK_ATTACH") "127.0.0.1:9999")
           ;; DSMR_MODE empty so the default (:attached) governs.
           (setf (uiop:getenv "DSMR_MODE") "")
           (is eq :attached (resolve-mode)))
      (if old-sa
          (setf (uiop:getenv "DSMR_SLYNK_ATTACH") old-sa)
          (setf (uiop:getenv "DSMR_SLYNK_ATTACH") ""))
      (if old-mode
          (setf (uiop:getenv "DSMR_MODE") old-mode)
          (setf (uiop:getenv "DSMR_MODE") "")))))

(define-test criterion-1-auto-aliases-attached
  "D-15 / HERM-07: with :mode :auto and no reachable Slynk listener,
resolve-mode returns :hermetic and emits a log4cl :warn. With a reachable
listener it returns :attached. This test covers the no-listener path, which
is the common case in a CI environment."
  ;; No slynk-attach and mode=:auto -> probe fails -> :hermetic
  (let* ((capture (make-string-output-stream))
         (*error-output* capture))
    (dsmr-mcp/src/log:configure-log4cl-for-server :warn)
    (is eq :hermetic (resolve-mode :mode :auto))
    ;; The warn line lands on stderr (not stdout).
    (let ((stderr (get-output-stream-string capture)))
      (true (search "run.auto-mode" stderr)))))

(define-test default-mode-is-attached
  "D-02: with nothing configured (no keyword, DSMR_MODE unset), resolve-mode
returns the built-in default :ATTACHED."
  (let ((old-mode (uiop:getenv "DSMR_MODE")))
    (unwind-protect
         (progn
           (setf (uiop:getenv "DSMR_MODE") "")
           (is eq :attached (resolve-mode)))
      (if old-mode
          (setf (uiop:getenv "DSMR_MODE") old-mode)
          (setf (uiop:getenv "DSMR_MODE") "")))))
