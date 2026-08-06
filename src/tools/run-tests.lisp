;;;; src/tools/run-tests.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; run-tests MCP tool (VERB-16): framework-detecting test runner with
;;;; structured per-test pass/fail/duration and source locations, backed by
;;;; src/test-runner-core.lisp shared between this tool and the worker handler.
;;;;
;;;; Dual-mode dispatch:
;;;;   :attached  — builds an injection form via %build-run-tests-form, sends it
;;;;                into the live image via bounded-slime-eval under the
;;;;                per-session call-lock, decodes the result plist.
;;;;   :hermetic  — routes through dispatch-hermetic-call to the worker's
;;;;                worker/run-tests handler, which calls test-runner-core
;;;;                directly in-process.
;;;;   :inline    — returns a typed "requires attached or hermetic mode" error.
;;;;
;;;; The attached path wraps the run in sb-ext:with-timeout inside the target
;;;; image so a runaway test run is actually interrupted rather than polled from
;;;; the dispatcher side.  The hermetic path defers to the worker handler, which
;;;; also wraps the run in sb-ext:with-timeout via the core's run-tests function.

(defpackage #:dsmr-mcp/src/tools/run-tests
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/tools/base
                #:mcp-tool
                #:mcp-tool-class
                #:tool-handle
                #:tool-session)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:make-ht
                #:result
                #:text-content
                #:rpc-error)
  (:import-from #:dsmr-mcp/src/attach/dispatch
                #:repl-eval-tool
                #:repl-eval-tool-slynk-conn
                #:repl-eval-tool-call-lock
                #:attached-connection)
  (:import-from #:dsmr-mcp/src/attach/connection
                #:bounded-slime-eval
                #:drop-connection)
  (:import-from #:dsmr-mcp/src/state
                #:*mode*
                #:get-tool-instance)
  (:import-from #:dsmr-mcp/src/log
                #:log-event)
  (:import-from #:dsmr-mcp/src/hermetic/dispatch
                #:dispatch-hermetic-call)
  (:import-from #:dsmr-mcp/src/test-runner-core
                #:%build-run-tests-form
                #:test-result-summary)
  (:import-from #:slynk-client
                #:slime-network-error)
  (:import-from #:bordeaux-threads
                #:with-lock-held)
  (:export #:run-tests-tool
           #:%dispatch-attach-run-tests))

(in-package #:dsmr-mcp/src/tools/run-tests)

;;; ---------------------------------------------------------------------------
;;; run-tests-tool CLOS class
;;; ---------------------------------------------------------------------------

(defclass run-tests-tool (mcp-tool)
  ((dsmr-mcp/src/tools/base::name
    :allocation :class
    :initform "run-tests")
   (dsmr-mcp/src/tools/base::description
    :allocation :class
    :initform "Run tests for an ASDF system and return structured results with \
per-test pass/fail counts and source locations. \
Supports automatic framework detection (zebra/rove/fiveam) or explicit \
selection via the framework argument. \
By default, the test system is reloaded before running so edits from \
lisp-edit-form become live; pass reload=false to opt out. \
Returns: passed/failed/pending counts, framework name, duration_ms, and a \
failed_tests array with test_name/reason/source{file,line} per failure. \
Requires attached or hermetic mode.")
   (dsmr-mcp/src/tools/base::input-schema
    :allocation :class
    :initform '(:object
                :properties
                ((system
                  :type :string
                  :description "ASDF system name to test (e.g. \"my-project/tests\").")
                 (framework
                  :type :string
                  :description "Force framework: \"zebra\", \"rove\", \"fiveam\", \
or \"auto\" (default: auto-detect from ASDF :depends-on).")
                 (test
                  :type :string
                  :description "Run only this specific test (fully qualified: \
\"package::test-name\"). Supported for Rove.")
                 (tests
                  :type :array
                  :description "Run only these specific tests (array of \
\"package::test-name\" strings). Supported for Rove.")
                 (timeout-seconds
                  :type :integer
                  :description "Timeout in seconds before the run is interrupted \
(default: 300). The timeout fires inside the target image.")
                 (reload
                  :type :boolean
                  :description "Reload the test system before running (default: true). \
Pass false to skip reload for tight hot-reload loops."))
                :required ("system"))))
  (:metaclass mcp-tool-class)
  (:documentation "MCP tool: run tests for an ASDF system with framework detection,
ghost-purge, force-reload, and structured per-test failure reporting.
Attached mode injects a purge+reload+run form into the live image.
Hermetic mode routes to worker/run-tests via dispatch-hermetic-call.
Both paths return the same wire envelope."))

;; ensure-finalized fires the metaclass :after method immediately, registering
;; "run-tests" in *tool-classes* at load time.
(c2mop:ensure-finalized (find-class 'run-tests-tool))

;;; ---------------------------------------------------------------------------
;;; Attached dispatcher
;;; ---------------------------------------------------------------------------

(defun %decode-run-tests-result (raw sys-name start-time)
  "Decode the raw result from the attached injected form into a wire envelope.
RAW is (:ok PLIST), (:timeout S), or (:error MSG).
Returns a hash-table suitable for (result id ...)."
  (let ((elapsed-ms (round (* 1000 (/ (- (get-internal-real-time) start-time)
                                      internal-time-units-per-second)))))
    (cond
      ;; Success: (:ok (:passed N :failed N :pending N :duration N :framework S ...))
      ((and (listp raw) (eq (car raw) :ok))
       (let* ((plist    (second raw))
              (passed   (or (getf plist :passed) 0))
              (failed   (or (getf plist :failed) 0))
              (pending  (or (getf plist :pending) 0))
              (duration (or (getf plist :duration) elapsed-ms))
              (fw       (map 'string #'identity
                             (or (getf plist :framework) "unknown")))
              ;; The injected form carries up to 10 (name reason) pairs so
              ;; the summary can say WHAT failed; rebuild them as
              ;; failure-detail hash-tables for the structured envelope.
              (failures (coerce
                         (mapcar (lambda (pair)
                                   (make-ht "test_name"
                                            (map 'string #'identity
                                                 (or (first pair) "?"))
                                            "reason"
                                            (map 'string #'identity
                                                 (or (second pair) ""))))
                                 (getf plist :failures))
                         'vector))
              (ht       (make-ht "passed"      passed
                                 "failed"      failed
                                 "pending"     pending
                                 "framework"   fw
                                 "duration_ms" duration
                                 "failed_tests" failures
                                 "system"      (map 'string #'identity sys-name)
                                 "content"
                                 (text-content
                                  (test-result-summary passed failed pending
                                                       fw duration failures)))))
         ht))
      ;; Timeout
      ((and (listp raw) (eq (car raw) :timeout))
       (let* ((timeout-secs (second raw))
              (failed-tests
                (vector (make-ht "test_name" "TIMEOUT"
                                 "reason"
                                 (format nil "Tests timed out after ~A seconds"
                                         timeout-secs)))))
         (make-ht "passed"      0
                  "failed"      1
                  "pending"     0
                  "framework"   "timeout"
                  "duration_ms" elapsed-ms
                  "failed_tests" failed-tests
                  "content"
                  (text-content
                   (format nil "tests timed out after ~A seconds" timeout-secs)))))
      ;; Error
      ((and (listp raw) (eq (car raw) :error))
       (let ((msg (map 'string #'identity (or (second raw) "unknown error"))))
         (make-ht "isError"  t
                  "error_type" "RUN_TESTS_ERROR"
                  "content"
                  (text-content (format nil "run-tests: ~A" msg)))))
      ;; Unexpected shape
      (t
       (log-event :warn "run-tests.attach.unexpected-result"
                  "shape" (princ-to-string (and (listp raw) (car raw))))
       (make-ht "isError"  t
                "error_type" "RUN_TESTS_ERROR"
                "content"
                (text-content "run-tests: unexpected result from image."))))))

(defun %dispatch-attach-run-tests (tool id params)
  "Dispatch run-tests to the attached Slynk image.
Builds the injected form via %build-run-tests-form, acquires the call-lock,
and runs bounded-slime-eval. Decodes the result into the wire envelope.
Returns a hash-table (without the result wrapper) so the caller can wrap it."
  (declare (ignore id))
  (let* ((sys-name        (and params (gethash "system"          params)))
         (framework       (and params (gethash "framework"       params)))
         (test            (and params (gethash "test"            params)))
         (tests           (and params (gethash "tests"           params)))
         (timeout-seconds (or (and params (gethash "timeout_seconds" params)) 300))
         ;; reload defaults true when absent.
         (reload          (let ((v (and params (gethash "reload" params))))
                            (if (null v) t v))))
    (unless (and (stringp sys-name) (plusp (length sys-name)))
      (return-from %dispatch-attach-run-tests
        (make-ht "isError" t
                 "content"
                 (text-content "run-tests: 'system' parameter is required."))))
    (let* ((start-time (get-internal-real-time))
           (form       (handler-case
                           (%build-run-tests-form
                            sys-name framework test tests timeout-seconds reload)
                         (error (e)
                           (return-from %dispatch-attach-run-tests
                             (make-ht "isError" t
                                      "content"
                                      (text-content
                                       (format nil "run-tests: form build error: ~A"
                                               e)))))))
           (lock       (repl-eval-tool-call-lock tool))
           ;; Client bound = in-image bound + margin: the injected
           ;; sb-ext:with-timeout owns the real deadline; the +15s margin
           ;; keeps the client wait from firing first on an honest long
           ;; run, which would drop a healthy connection mid-eval.
           (raw        (handler-case
                           (with-lock-held (lock)
                             (bounded-slime-eval form (attached-connection tool)
                                                 :timeout (+ timeout-seconds 15)))
                         (slime-network-error (e)
                           ;; Fail-closed like %dispatch-attach: the rex state
                           ;; on this connection is suspect after a lost reply.
                           (drop-connection tool :reason "network-error")
                           (log-event :warn "run-tests.attach.network-error"
                                      "error" (handler-case (princ-to-string e)
                                                (error () "")))
                           (return-from %dispatch-attach-run-tests
                             (make-ht "isError"    t
                                      "error_type" "NETWORK_ERROR"
                                      "content"
                                      (text-content
                                       (format nil "run-tests: Slynk connection error: ~A"
                                               e))))))))
      (%decode-run-tests-result raw sys-name start-time))))

;;; ---------------------------------------------------------------------------
;;; tool-handle method
;;; ---------------------------------------------------------------------------

(defmethod tool-handle ((tool run-tests-tool) id args)
  "Route run-tests by *mode*.
Attached: injects a ghost-purge + reload + run form into the live image.
Hermetic: routes to worker/run-tests via dispatch-hermetic-call.
Inline: returns a typed mode error."
  (ecase *mode*
    (:attached
     (let ((repl-tool (get-tool-instance (tool-session tool) "repl-eval")))
       (result id (%dispatch-attach-run-tests repl-tool id args))))
    (:hermetic
     (dispatch-hermetic-call (tool-session tool) id "run-tests" args))
    (:inline
     (rpc-error id -32603
                "run-tests requires attached or hermetic mode."))))
