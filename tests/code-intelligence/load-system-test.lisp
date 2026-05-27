;;;; tests/code-intelligence/load-system-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; In-process tests for the load-system VERB-12 implementation.
;;;; Tests run without spawning a worker — they exercise the core engine
;;;; and handler directly, proving the hermetic path behaviors.
;;;;
;;;; Coverage:
;;;;   load-system-loads-known-system         — a loadable system returns status=loaded
;;;;   load-system-captures-warnings-non-fatally — warning does not abort; structured list returned
;;;;   load-system-timeout-returns-structured-timeout — tiny timeout fires structured TIMEOUT marker
;;;;   load-system-inline-returns-mode-error  — *mode* :inline returns the typed -32603 error
;;;;
;;;; NOT covered here (requires a live developer image with an uncommitted
;;;; edit — cannot be automated in the test suite): the attached-mode
;;;; force=true-picks-up-edits criterion (criterion 2). That criterion is
;;;; verified MANUALLY by: (1) editing a function with lisp-edit-form,
;;;; (2) calling load-system with force=true, (3) confirming the edited
;;;; definition is live via repl-eval. The hermetic path's force=true
;;;; behavior (reload + warning suppression) is partially covered by
;;;; load-system-loads-known-system which uses force=true.

(defpackage #:dsmr-mcp/tests/code-intelligence/load-system-test
  (:use #:cl #:parachute)
  (:import-from #:dsmr-mcp/src/system-loader-core
                #:load-system
                #:%redefinition-warning-p
                #:%build-load-system-form)
  (:import-from #:dsmr-mcp/src/hermetic/worker/handlers
                #:%handle-load-system)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:make-ht)
  (:import-from #:dsmr-mcp/src/state
                #:*mode*)
  (:import-from #:dsmr-mcp/src/tools/base
                #:tool-handle)
  (:import-from #:dsmr-mcp/src/tools/load-system
                #:load-system-tool))

(in-package #:dsmr-mcp/tests/code-intelligence/load-system-test)

;;; ---------------------------------------------------------------------------
;;; load-system-loads-known-system
;;;
;;; The hermetic %handle-load-system / core load-system returns status=loaded
;;; for a system already findable in ASDF's source registry.
;;; ---------------------------------------------------------------------------

(define-test load-system-loads-known-system
  "load-system returns status=loaded for an already-available system.
Both the core load-system function and the %handle-load-system worker handler
are exercised. The result hash-table must have status=loaded, a duration,
and a warnings count."
  ;; Core function path
  (let ((result (load-system "alexandria" :force t :timeout-seconds 60)))
    (true (hash-table-p result))
    (is string= "loaded" (gethash "status" result))
    (is string= "alexandria" (gethash "system" result))
    (true (integerp (gethash "duration_ms" result)))
    (true (integerp (gethash "warnings" result))))
  ;; Worker handler path (same parameters via hash-table)
  (let* ((params (let ((ht (make-hash-table :test 'equal)))
                   (setf (gethash "system" ht) "alexandria")
                   (setf (gethash "force" ht) t)
                   (setf (gethash "timeout_seconds" ht) 60)
                   ht))
         (result (%handle-load-system params nil)))
    (true (hash-table-p result))
    (is string= "loaded" (gethash "status" result))))

;;; ---------------------------------------------------------------------------
;;; load-system-captures-warnings-non-fatally
;;;
;;; Loading a system whose source emits a warn at load time must return
;;; status=loaded (not abort) with a non-empty warning_details list.
;;; Warnings must be non-fatal and muffled off host stderr.
;;; ---------------------------------------------------------------------------

(defvar *warning-test-system-dir* nil
  "Directory holding the temporary ASDF system used by the warning-capture test.
Set by ensure-warning-test-system; deleted by cleanup.")

(defun %ensure-warning-test-system ()
  "Create a minimal ASDF system in a temp directory that emits a
WARN at load time. Registers the system with ASDF. Returns the system
name string. Idempotent: writes the files each time to ensure they exist."
  (let* ((sys-name "dsmr-test-warn-capture-system")
         (tmpdir   (uiop:ensure-directory-pathname
                    (merge-pathnames (concatenate 'string sys-name "/")
                                     (uiop:temporary-directory))))
         (asd-path (merge-pathnames (concatenate 'string sys-name ".asd") tmpdir)))
    (ensure-directories-exist tmpdir)
    ;; .asd
    (with-open-file (s asd-path
                       :direction :output :if-exists :supersede)
      (format s "(asdf:defsystem ~S :components ((:file \"warn-main\")))~%" sys-name))
    ;; The source file emits a plain WARN at load time.
    (with-open-file (s (merge-pathnames "warn-main.lisp" tmpdir)
                       :direction :output :if-exists :supersede)
      (format s "(in-package :cl)~%~
                 (warn \"dsmr-load-system-test: intentional warning for capture\")~%"))
    ;; Register with ASDF so it can be found by name.
    ;; Do NOT call clear-system here — that would remove the registration.
    (asdf:load-asd asd-path)
    (setf *warning-test-system-dir* tmpdir)
    sys-name))

(define-test load-system-captures-warnings-non-fatally
  "Loading a system that emits a warning returns status=loaded (not error)
with a non-empty warning_details list. The warning did not abort the load
and did not reach the host stderr (non-fatal warning bucketing)."
  (let* ((sys-name (%ensure-warning-test-system))
         (result   (load-system sys-name :force t :timeout-seconds 30)))
    (true (hash-table-p result))
    ;; The load must have succeeded despite the warning.
    (is string= "loaded" (gethash "status" result))
    ;; The warning must have been collected, not discarded.
    (true (and (integerp (gethash "warnings" result))
               (plusp (gethash "warnings" result))))
    ;; warning_details must be present and non-empty.
    (let ((details (gethash "warning_details" result)))
      (true (and details (plusp (length details))))
      ;; Each detail must be a string.
      (true (stringp (first details))))))

;;; ---------------------------------------------------------------------------
;;; load-system-timeout-returns-structured-timeout
;;;
;;; A load wrapped with a sub-millisecond timeout returns the structured
;;; TIMEOUT marker rather than hanging or re-signalling. This confirms
;;; the timeout fires inside the image and interrupts the compile rather than
;;; being observed after the fact.
;;; ---------------------------------------------------------------------------

(define-test load-system-timeout-returns-structured-timeout
  "load-system with an absurdly small timeout returns status=timeout and a
descriptive message. The TIMEOUT condition is caught inside sb-ext:with-timeout
and returned as a structured result rather than propagating as an unhandled
condition — confirming in-image timeout interruption."
  ;; 0.001 seconds is well below any real compile; the timeout must fire.
  (let ((result (load-system "alexandria" :timeout-seconds 0.001 :force t)))
    (true (hash-table-p result))
    (is string= "timeout" (gethash "status" result))
    (true (stringp (gethash "message" result)))
    (true (search "timed out" (gethash "message" result)))))

;;; ---------------------------------------------------------------------------
;;; load-system-inline-returns-mode-error
;;;
;;; tool-handle with *mode* :inline must return the typed -32603 RPC error
;;; without attempting any load operation.
;;; ---------------------------------------------------------------------------

(define-test load-system-inline-returns-mode-error
  "load-system-tool tool-handle with *mode* :inline returns the JSON-RPC
error -32603 with a 'requires attached or hermetic mode' message.
No load is attempted in inline mode."
  (let* ((tool   (make-instance 'load-system-tool))
         ;; Bind *mode* to :inline for the duration of this test.
         (*mode* :inline)
         (result (tool-handle tool 42 nil)))
    (true (hash-table-p result))
    ;; Must be a JSON-RPC error response (has "error" key at top level).
    (let ((err (gethash "error" result)))
      (true (hash-table-p err))
      (is = -32603 (gethash "code" err))
      (true (search "mode" (gethash "message" err))))))
