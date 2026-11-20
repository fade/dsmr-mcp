;;;; tests/code-intelligence/load-system-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; In-process tests for the load-system implementation.
;;;; Tests run without spawning a worker — they exercise the core engine
;;;; and handler directly, proving the hermetic path behaviors.
;;;;
;;;; Coverage:
;;;;   load-system-loads-known-system         — a loadable system returns status=loaded
;;;;   load-system-captures-warnings-non-fatally — warning does not abort; structured list returned
;;;;   load-system-timeout-returns-structured-timeout - a load past its limit answers
;;;;                                            timeout with still_running, uninterrupted
;;;;   abandoned-load-runs-to-completion      - the abandoned load finishes once the gate opens
;;;;   load-during-abandoned-load-answers-busy - a further load answers busy, naming it
;;;;   load-after-abandoned-load-completes-succeeds - the next load after it succeeds
;;;;   nested-guarded-call-runs               - a guarded call inside a guarded operation runs
;;;;   escaped-condition-reaches-caller-and-clears-guard - an escaped error reaches the caller
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
  (:use #:cl #:zebra)
  (:import-from #:dsmr-mcp/tests/support/slynk-fixture
                #:with-temporary-slynk-listener)
  (:import-from #:dsmr-mcp/src/system-loader-core
                #:load-system
                #:%redefinition-warning-p
                #:%build-load-system-form)
  (:import-from #:dsmr-mcp/src/load-guard
                #:call-with-load-guard
                #:running-operation
                #:wait-for-guarded-operations)
  (:import-from #:dsmr-mcp/tests/support/gated-load-fixture
                #:make-gated-system
                #:remove-gated-system
                #:open-gate
                #:close-gate
                #:wait-for-gate-entered
                #:gated-load-count)
  (:import-from #:dsmr-mcp/src/hermetic/worker/handlers
                #:%handle-load-system)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:make-ht)
  (:import-from #:dsmr-mcp/src/state
                #:make-session
                #:*current-session-id*
                #:get-tool-instance
                #:*mode*)
  (:import-from #:dsmr-mcp/src/attach/dispatch
                #:repl-eval-tool-slynk-conn)
  (:import-from #:dsmr-mcp/src/attach/connection
                #:drop-connection)
  (:import-from #:dsmr-mcp/src/tools/base
                #:tool-handle)
  (:import-from #:dsmr-mcp/src/tools/load-system
                #:load-system-tool
                #:%dispatch-attach-load-system))

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
;;; load-system-timeout-returns-structured-timeout and the abandoned load
;;;
;;; A load parked at a closed gate outlasts its limit. The reply is structured
;;; and prompt, with still_running true; the load is left to finish and
;;; nothing interrupts it. While it runs, later calls answer busy; once it has
;;; finished, the next load succeeds.
;;; ---------------------------------------------------------------------------

(defmacro with-gated-system ((var) &body body)
  "Bind VAR to a fresh gated system with the gate closed and run BODY.
Cleanup opens the gate, asserts the guard clears within 30 s, and removes the
system, so no abandoned load outlives the test."
  `(let ((,var (make-gated-system "dsmr-gated-load")))
     (close-gate)
     (unwind-protect (progn ,@body)
       (open-gate)
       (true (wait-for-guarded-operations 30))
       (remove-gated-system ,var "dsmr-gated-load"))))

(defun %wall-seconds-since (start)
  "Seconds of wall time since internal real time START."
  (/ (- (get-internal-real-time) start) internal-time-units-per-second))

(define-test load-system-timeout-returns-structured-timeout
  "load-system on a load parked at a closed gate, with a 0.5 s limit, returns
status=timeout within 2.5 s, with a message, an integer duration_ms and
still_running true. The load is left to finish; nothing interrupts it."
  (with-gated-system (sys)
    (let* ((start  (get-internal-real-time))
           (result (load-system sys :timeout-seconds 0.5 :force t)))
      (true (< (%wall-seconds-since start) 2.5))
      (true (hash-table-p result))
      (is string= "timeout" (gethash "status" result))
      (true (stringp (gethash "message" result)))
      (true (search "timed out" (gethash "message" result)))
      (is eq t (gethash "still_running" result))
      (true (integerp (gethash "duration_ms" result))))))

(define-test abandoned-load-runs-to-completion
  "A load abandoned at its limit reaches the gate, and once the gate opens it
finishes: the guard clears, the system is loaded, and exactly one more load
passed the gate."
  (with-gated-system (sys)
    (let ((before (gated-load-count))
          (result (load-system sys :timeout-seconds 0.5 :force t)))
      (is string= "timeout" (gethash "status" result))
      (true (wait-for-gate-entered 30))
      (open-gate)
      (true (wait-for-guarded-operations 30))
      (true (asdf:component-loaded-p sys))
      (is = (1+ before) (gated-load-count)))))

(define-test load-during-abandoned-load-answers-busy
  "While an abandoned load waits at the closed gate, the worker handler's
load-system for another system answers status=busy naming the running load,
and starts nothing."
  (with-gated-system (sys)
    (is string= "timeout"
        (gethash "status" (load-system sys :timeout-seconds 0.5 :force t)))
    (true (wait-for-gate-entered 30))
    (let ((result (%handle-load-system
                   (make-ht "system" "alexandria" "timeout_seconds" 30)
                   nil)))
      (is string= "busy" (gethash "status" result))
      (is string= "load-system" (gethash "running_operation" result))
      (is string= sys (gethash "running_system" result))
      (let ((secs (gethash "elapsed_seconds" result)))
        (true (and (integerp secs) (>= secs 0))))
      (true (search sys (gethash "message" result)))
      (let ((content (gethash "content" result)))
        (true (vectorp content))
        (true (plusp (length (gethash "text" (aref content 0)))))))))

(define-test load-after-abandoned-load-completes-succeeds
  "Once an abandoned load has finished, the next load-system on the same
system returns status=loaded."
  (with-gated-system (sys)
    (is string= "timeout"
        (gethash "status" (load-system sys :timeout-seconds 0.5 :force t)))
    (true (wait-for-gate-entered 30))
    (open-gate)
    (true (wait-for-guarded-operations 30))
    (is string= "loaded"
        (gethash "status" (load-system sys :timeout-seconds 30 :force t)))))

(define-test nested-guarded-call-runs
  "A load-system made from inside a guarded run-tests operation runs and
returns status=loaded; the caller's own ancestors never make it busy."
  (with-gated-system (sys)
    (open-gate)
    (let ((result (call-with-load-guard
                   "run-tests" "dsmr-nested-outer" 60
                   (lambda () (load-system sys :timeout-seconds 30 :force t))
                   :on-timeout (lambda (ms) (declare (ignore ms)) :timeout)
                   :on-busy (lambda (&rest args) (declare (ignore args)) :busy))))
      (true (hash-table-p result))
      (is string= "loaded" (gethash "status" result)))))

(define-test escaped-condition-reaches-caller-and-clears-guard
  "An error escaping a guarded thunk is signalled in the waiting caller with
its own text, and leaves no operation registered."
  (let ((caught nil))
    (handler-case
        (call-with-load-guard
         "load-system" "dsmr-escaped-condition" 30
         (lambda () (error "dsmr-guard-escaped-condition-marker"))
         :on-timeout (lambda (ms) (declare (ignore ms)) :timeout)
         :on-busy (lambda (&rest args) (declare (ignore args)) :busy))
      (error (e)
        (setf caught (princ-to-string e))))
    (true (and caught (search "dsmr-guard-escaped-condition-marker" caught)))
    (false (running-operation))))

;;; ---------------------------------------------------------------------------
;;; load-system-attached-loads-known-system
;;;
;;; The attached path injects a with-timeout + handler-bind form via Slynk.
;;; For a system already in ASDF's source registry (alexandria is always
;;; available in this image), the result must be status=loaded.
;;; ---------------------------------------------------------------------------

(defun %make-load-system-attach-session (id conn)
  "Create a test session wired to the given Slynk connection."
  (let* ((session (make-session :id id :slynk-attach "127.0.0.1:1"))
         (*current-session-id* id)
         (repl-tool (get-tool-instance session "repl-eval")))
    (setf (repl-eval-tool-slynk-conn repl-tool) conn)
    (values session repl-tool)))

(define-test load-system-attached-loads-known-system
  "Calling %dispatch-attach-load-system via the in-process Slynk fixture for
'alexandria' — always available in this image — returns status=loaded with
a duration_ms integer.  Exercises the real slime-eval injection path and
the (:ok N WARNS) result decoder in attached mode."
  (with-temporary-slynk-listener (conn)
    (multiple-value-bind (session repl-tool)
        (%make-load-system-attach-session "ls-attach-known" conn)
      (declare (ignore session))
      (let* ((params (make-ht "system"          "alexandria"
                              "force"           t
                              "timeout_seconds" 120))
             (result (%dispatch-attach-load-system repl-tool nil params)))
        (true (hash-table-p result))
        (false (gethash "isError" result))
        (is string= "loaded" (gethash "status" result))
        (is string= "alexandria" (gethash "system" result))
        (true (integerp (gethash "duration_ms" result)))
        ;; The client renders results through content alone — the summary
        ;; text block must be present alongside the structured fields.
        (let ((content (gethash "content" result)))
          (true (vectorp content))
          (true (search "loaded alexandria"
                        (gethash "text" (aref content 0)))))))))

;;; ---------------------------------------------------------------------------
;;; load-system-attached-reopens-after-drop
;;;
;;; The dispatcher resolves its connection via attached-connection, so a call
;;; made after drop-connection nils the cached slot must reopen on demand
;;; from the session's :slynk-attach config — never evaluate against the nil
;;; slot (which crashed instead of reconnecting).
;;; ---------------------------------------------------------------------------

(define-test load-system-attached-reopens-after-drop
  "An attached load-system call with a nil cached connection opens one from
the session's :slynk-attach config; after drop-connection, the next call
reopens and succeeds rather than failing on the nil slot."
  (let* ((port (slynk:create-server :port 0 :dont-close t))
         (session (make-session :id "ls-attach-reopen"
                                :slynk-attach (format nil "127.0.0.1:~A" port)))
         (*current-session-id* "ls-attach-reopen")
         (repl-tool (get-tool-instance session "repl-eval")))
    (unwind-protect
         (progn
           (sleep 0.1)
           ;; Cached slot starts nil — the dispatcher must open on demand.
           (true (null (repl-eval-tool-slynk-conn repl-tool)))
           (let ((r1 (%dispatch-attach-load-system
                      repl-tool nil
                      (make-ht "system"          "alexandria"
                               "force"           t
                               "timeout_seconds" 120))))
             (false (gethash "isError" r1))
             (is string= "loaded" (gethash "status" r1))
             (true (repl-eval-tool-slynk-conn repl-tool)))
           ;; Drop: slot is nil again; the next call must reopen, not crash.
           (drop-connection repl-tool :reason "test-drop")
           (true (null (repl-eval-tool-slynk-conn repl-tool)))
           (let ((r2 (%dispatch-attach-load-system
                      repl-tool nil
                      (make-ht "system"          "alexandria"
                               "force"           t
                               "timeout_seconds" 120))))
             (false (gethash "isError" r2))
             (is string= "loaded" (gethash "status" r2))
             (true (repl-eval-tool-slynk-conn repl-tool))))
      (ignore-errors (slynk:stop-server port)))))

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

;;; ---------------------------------------------------------------------------
;;; load-system-injected-form-is-portable
;;;
;;; The form built by %build-load-system-form is serialized and READ in the
;;; attached image, which has only the developer's own system + Slynk loaded —
;;; never dsmr-mcp. Any symbol interned in a DSMR-MCP-internal package prints
;;; package-qualified on the wire and makes the remote READ fail
;;; ("Package ... does not exist"), surfacing as a reader-error / NETWORK_ERROR
;;; that aborts the load before it runs. CL / CL-USER / KEYWORD / SB-EXT / ASDF
;;; symbols all resolve in a real SBCL dev image; only DSMR-MCP-package symbols
;;; are the hazard. The in-process Slynk fixture cannot catch this because its
;;; target image IS the dsmr-mcp image, where the package exists — so this is a
;;; pure structural guard on the emitted form, covering both the force-only and
;;; the clear-fasls branches.
;;; ---------------------------------------------------------------------------

(defun %collect-symbols (form)
  "Flat list of every symbol appearing in FORM (a tree of conses and atoms,
descending into non-string vectors)."
  (let ((acc '()))
    (labels ((walk (x)
               (cond ((and (symbolp x) x) (push x acc))
                     ((consp x) (walk (car x)) (walk (cdr x)))
                     ((and (vectorp x) (not (stringp x))) (map nil #'walk x)))))
      (walk form))
    acc))

(defun %dsmr-package-leaks (form)
  "Symbols in FORM whose home package name contains \"DSMR-MCP\" — symbols that
cannot be READ in an attached image that does not have dsmr-mcp loaded."
  (remove-duplicates
   (remove-if-not
    (lambda (s)
      (let ((pkg (symbol-package s)))
        (and pkg (search "DSMR-MCP" (package-name pkg)))))
    (%collect-symbols form))))

(define-test load-system-injected-form-is-portable
  "%build-load-system-form must emit no symbol from a DSMR-MCP-internal package;
such a symbol breaks the remote READ in a real attached image. Covers both the
force-only and the clear-fasls branches."
  (is equal '() (%dsmr-package-leaks (%build-load-system-form "alexandria" t nil 120)))
  (is equal '() (%dsmr-package-leaks (%build-load-system-form "alexandria" t t   120))))
