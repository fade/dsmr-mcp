;;;; tests/run-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Tests for dsmr-mcp:run transport stubs and keyword/env precedence.
;;;; Asserts via the non-blocking resolve-transport seam so tests never
;;;; enter the blocking :stdio loop.

(defpackage #:dsmr-mcp/tests/run-test
  (:use #:cl #:parachute)
  (:import-from #:dsmr-mcp/src/run
                #:run
                #:resolve-transport
                #:resolve-mode
                #:%check-remote-bind
                #:transport-not-implemented-error
                #:invalid-config-value)
  (:import-from #:dsmr-mcp/tests/support/env-fixture
                #:with-clean-resolution-env))

(in-package #:dsmr-mcp/tests/run-test)

;;; ---------------------------------------------------------------------------
;;; Transport gate tests
;;;
;;; :tcp and :http now route to transport packages via runtime symbol resolution
;;; rather than raising transport-not-implemented-error. Without the bind address
;;; being set, both paths hit %check-remote-bind first, so the most observable
;;; error for a bare run :transport :tcp call is now INVALID-CONFIG-VALUE (the
;;; gate rejects the default 127.0.0.1 bind... actually 127.0.0.1 is loopback so
;;; it passes the gate and the error becomes package-not-found for the transport
;;; that doesn't exist yet). Either way the old transport-not-implemented-error
;;; is no longer raised; these tests verify the new error shape.
;;; ---------------------------------------------------------------------------

(define-test tcp-transport-uses-symbol-call
  "run :transport :tcp no longer raises transport-not-implemented-error;
it routes to dsmr-mcp/src/transport/tcp:serve-tcp via runtime symbol resolution.
Without the transport package loaded, uiop:symbol-call raises a package-error."
  ;; Ensure DSMR_ALLOW_REMOTE is clear so loopback passes; default bind is 127.0.0.1.
  (let ((old-val (uiop:getenv "DSMR_ALLOW_REMOTE")))
    (unwind-protect
         (progn
           (setf (uiop:getenv "DSMR_ALLOW_REMOTE") "")
           ;; Must NOT raise transport-not-implemented-error any more.
           (false (handler-case (run :transport :tcp)
                    (transport-not-implemented-error () t)
                    (error () nil))))
      (if old-val
          (setf (uiop:getenv "DSMR_ALLOW_REMOTE") old-val)
          (setf (uiop:getenv "DSMR_ALLOW_REMOTE") "")))))

(define-test http-transport-uses-symbol-call
  "run :transport :http no longer raises transport-not-implemented-error;
it routes to dsmr-mcp/src/transport/http:serve-http via runtime symbol resolution.
Without the transport package loaded, uiop:symbol-call raises a package-error."
  (let ((old-val (uiop:getenv "DSMR_ALLOW_REMOTE")))
    (unwind-protect
         (progn
           (setf (uiop:getenv "DSMR_ALLOW_REMOTE") "")
           ;; Must NOT raise transport-not-implemented-error any more.
           (false (handler-case (run :transport :http)
                    (transport-not-implemented-error () t)
                    (error () nil))))
      (if old-val
          (setf (uiop:getenv "DSMR_ALLOW_REMOTE") old-val)
          (setf (uiop:getenv "DSMR_ALLOW_REMOTE") "")))))

;;; ---------------------------------------------------------------------------
;;; Keyword/env precedence
;;; ---------------------------------------------------------------------------

(define-test keyword-beats-env-for-transport
  "An explicit :transport keyword overrides DSMR_TRANSPORT env var.
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
  "DSMR_TRANSPORT env var overrides the :stdio built-in default
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
  "A legitimately-falsy value stored in the conf plist (nil, 0) must be honoured
over the built-in default.  Tests the sentinel-based %or-from-env logic that
distinguishes 'key present with falsy value' from 'key absent'.
Exercises the :slynk-attach nil and :port 0 cases."
  ;; Clear DSMR_SLYNK_ATTACH / DSMR_PORT so a dev shell that exports them for the
  ;; live server does not outrank the conf values under test.
  (with-clean-resolution-env
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
    (is equal "host:7777" result))))

(define-test bad-dsmr-transport-env-signals-typed-error
  "DSMR_TRANSPORT=banana must signal INVALID-CONFIG-VALUE (a typed error subclass)
rather than a raw case-failure.  Exercises the typed error path without calling run."
  (fail (dsmr-mcp/src/run::%parse-transport "banana") invalid-config-value))

(define-test bad-dsmr-port-env-signals-typed-error
  "A non-integer DSMR_PORT value must signal INVALID-CONFIG-VALUE rather
than crashing with an unhandled parse-integer error.  Uses run with
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
;;; Mode resolution
;;;
;;; resolve-mode is the non-blocking seam mirroring resolve-transport: it runs
;;; the keyword > env > conf > default resolution for the dispatch mode and
;;; performs the real :auto Slynk probe (resolves to :attached when reachable,
;;; emits a :warn and returns :hermetic when not).  These tests assert mode
;;; resolution WITHOUT entering the blocking :stdio loop.
;;; ---------------------------------------------------------------------------

(define-test criterion-1-keyword-slynk-attach-sets-attached
  "With a :slynk-attach target configured, the mode resolves to :ATTACHED.
resolve-mode mirrors resolve-transport's seam and never enters the stdio loop."
  ;; Clear DSMR_MODE so a dev shell exporting DSMR_MODE=auto does not turn this
  ;; into an :auto probe that resolves to :hermetic against the unreachable target.
  (with-clean-resolution-env
    (is eq :attached (resolve-mode :slynk-attach "127.0.0.1:9999"))))

(define-test criterion-1-env-slynk-attach-sets-attached
  "With DSMR_SLYNK_ATTACH bound (and DSMR_MODE unset), mode resolves to :ATTACHED
via the env path.  Bind/restore both env vars with unwind-protect."
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
  "With :mode :auto and no reachable Slynk listener, resolve-mode returns
:hermetic and emits a log4cl :warn. This test covers the no-listener path,
which is the common case in a CI environment."
  ;; No slynk-attach and mode=:auto -> probe fails -> :hermetic
  (let* ((capture (make-string-output-stream))
         (*error-output* capture))
    (dsmr-mcp/src/log:configure-log4cl-for-server :warn)
    (is eq :hermetic (resolve-mode :mode :auto))
    ;; The warn line lands on stderr (not stdout).
    (let ((stderr (get-output-stream-string capture)))
      (true (search "run.auto-mode" stderr)))))

(define-test default-mode-is-attached
  "With nothing configured (no keyword, DSMR_MODE unset), resolve-mode
returns the built-in default :ATTACHED."
  (let ((old-mode (uiop:getenv "DSMR_MODE")))
    (unwind-protect
         (progn
           (setf (uiop:getenv "DSMR_MODE") "")
           (is eq :attached (resolve-mode)))
      (if old-mode
          (setf (uiop:getenv "DSMR_MODE") old-mode)
          (setf (uiop:getenv "DSMR_MODE") "")))))

;;; ---------------------------------------------------------------------------
;;; Remote-bind gate
;;; ---------------------------------------------------------------------------

(define-test remote-bind-non-loopback-without-override-signals
  "A non-loopback bind without DSMR_ALLOW_REMOTE set signals INVALID-CONFIG-VALUE
with name DSMR_BIND before any listener socket is created."
  (let ((old-val (uiop:getenv "DSMR_ALLOW_REMOTE")))
    (unwind-protect
         (progn
           ;; Clear the env var so the gate fires.
           (setf (uiop:getenv "DSMR_ALLOW_REMOTE") "")
           (fail (%check-remote-bind "0.0.0.0") invalid-config-value)
           (fail (%check-remote-bind "10.0.0.1") invalid-config-value)
           (fail (%check-remote-bind "0.0.0.0") invalid-config-value))
      (if old-val
          (setf (uiop:getenv "DSMR_ALLOW_REMOTE") old-val)
          (setf (uiop:getenv "DSMR_ALLOW_REMOTE") "")))))

(define-test remote-bind-non-loopback-with-override-passes
  "With DSMR_ALLOW_REMOTE=1, a non-loopback bind passes the gate without
signalling. The gate is designed to be bypassed when the operator explicitly
opts into remote exposure."
  (let ((old-val (uiop:getenv "DSMR_ALLOW_REMOTE")))
    (unwind-protect
         (progn
           (setf (uiop:getenv "DSMR_ALLOW_REMOTE") "1")
           ;; Should return NIL without signalling.
           (is eq nil (%check-remote-bind "0.0.0.0"))
           ;; Also accepts the other truthy strings.
           (setf (uiop:getenv "DSMR_ALLOW_REMOTE") "true")
           (is eq nil (%check-remote-bind "10.0.0.1"))
           (setf (uiop:getenv "DSMR_ALLOW_REMOTE") "yes")
           (is eq nil (%check-remote-bind "192.168.1.1")))
      (if old-val
          (setf (uiop:getenv "DSMR_ALLOW_REMOTE") old-val)
          (setf (uiop:getenv "DSMR_ALLOW_REMOTE") "")))))

(define-test remote-bind-loopback-bypasses-gate
  "Loopback addresses pass the gate regardless of DSMR_ALLOW_REMOTE, so
operators never need to set the env var for a local-only server."
  (let ((old-val (uiop:getenv "DSMR_ALLOW_REMOTE")))
    (unwind-protect
         (progn
           ;; Gate absent — loopback must still pass.
           (setf (uiop:getenv "DSMR_ALLOW_REMOTE") "")
           (is eq nil (%check-remote-bind "127.0.0.1"))
           (is eq nil (%check-remote-bind "::1"))
           (is eq nil (%check-remote-bind "localhost")))
      (if old-val
          (setf (uiop:getenv "DSMR_ALLOW_REMOTE") old-val)
          (setf (uiop:getenv "DSMR_ALLOW_REMOTE") "")))))

(define-test attach-concurrency-env-resolves
  "DSMR_ATTACH_CONCURRENCY=parallel is accepted by %resolve-attach-concurrency
and produces the :parallel keyword, matching the startup resolution path."
  (let ((old-val (uiop:getenv "DSMR_ATTACH_CONCURRENCY")))
    (unwind-protect
         (progn
           (setf (uiop:getenv "DSMR_ATTACH_CONCURRENCY") "parallel")
           (is eq :parallel
               (dsmr-mcp/src/attach/dispatch::%resolve-attach-concurrency
                (uiop:getenv "DSMR_ATTACH_CONCURRENCY")))
           (setf (uiop:getenv "DSMR_ATTACH_CONCURRENCY") "serialised")
           (is eq :serialised
               (dsmr-mcp/src/attach/dispatch::%resolve-attach-concurrency
                (uiop:getenv "DSMR_ATTACH_CONCURRENCY"))))
      (if old-val
          (setf (uiop:getenv "DSMR_ATTACH_CONCURRENCY") old-val)
          (setf (uiop:getenv "DSMR_ATTACH_CONCURRENCY") "")))))
