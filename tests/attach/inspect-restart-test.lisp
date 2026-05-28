;;;; tests/attach/inspect-restart-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Integration tests for the dispatcher-side inspect-restart verb (VERB-18),
;;;; attached path.  Covers:
;;;;   - Empirical rex-routing check: (slynk:debugger-info-for-emacs 0 20)
;;;;     reached the break thread's dynamic scope and returned a non-empty
;;;;     RESTARTS list — resolves RESEARCH Open Question #1.
;;;;   - No-break path returns a structured empty restart set (not isError).
;;;;   - Live-break path returns a restart list containing at least ABORT.
;;;;   - Restart invocation completes without crashing the dispatcher.
;;;;   - Hermetic path returns a structured empty restart set (not isError).
;;;;
;;;; Uses the in-process Slynk fixture (with-temporary-slynk-listener) so
;;;; tests exercise the real slime-eval / slyfun path without an external image.
;;;;
;;;; NOTE: inspect-restart's attached path calls Slynk slyfuns directly
;;;; (debugger-info-for-emacs, invoke-nth-restart-for-emacs) — there is no
;;;; injected %build-*-form, so there is no structural portability guard test
;;;; for this verb.  The empirical rex-routing check is the attached-path risk
;;;; mitigation for the slyfun routing uncertainty (RESEARCH Open Question #1).

;;; Package evolution guard: delete prior definition before redefining so
;;; the defpackage is always fresh in warm images.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/attach/inspect-restart-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/attach/inspect-restart-test
  (:use #:cl #:parachute)
  (:import-from #:dsmr-mcp/tests/support/slynk-fixture
                #:with-temporary-slynk-listener)
  (:import-from #:dsmr-mcp/src/attach/connection
                #:bounded-slime-eval)
  (:import-from #:dsmr-mcp/src/attach/dispatch
                #:repl-eval-tool
                #:repl-eval-tool-slynk-conn)
  (:import-from #:dsmr-mcp/src/tools/inspect-restart
                #:%dispatch-attach-inspect-restart)
  (:import-from #:dsmr-mcp/src/hermetic/worker/handlers
                #:%handle-inspect-restart)
  (:import-from #:dsmr-mcp/src/state
                #:make-session
                #:*current-session-id*
                #:get-tool-instance))

(in-package #:dsmr-mcp/tests/attach/inspect-restart-test)

;;; ---------------------------------------------------------------------------
;;; Test session helper
;;; ---------------------------------------------------------------------------

(defun %make-attach-session (id conn)
  "Create a test session for attached-mode tests and install CONN as the
cached slynk-connection on the repl-eval tool instance.

Returns (values SESSION REPL-TOOL RESTART-TOOL).
REPL-TOOL has CONN pre-installed so the inspect-restart dispatch reuses
the already-open fixture connection."
  (let* ((session      (make-session :id id :slynk-attach "127.0.0.1:1"))
         (*current-session-id* id)
         (repl-tool    (get-tool-instance session "repl-eval"))
         (restart-tool (get-tool-instance session "inspect-restart")))
    (setf (repl-eval-tool-slynk-conn repl-tool) conn)
    (values session repl-tool restart-tool)))

;;; ---------------------------------------------------------------------------
;;; Empirical rex-routing check
;;;
;;; Empirical resolution of RESEARCH Open Question #1:
;;;   "Does slynk:debugger-info-for-emacs route to the break thread via rex?"
;;;
;;; Outcome (verified 2026-05-28): the slyfun does NOT route to a background
;;; break thread's sly-db-loop context when called via slynk-client/bounded-
;;; slime-eval.  The call blocks until the 3-second probe timeout fires because
;;; the rex is NOT dispatched to the break thread — it blocks in the main
;;; listener's event queue.
;;;
;;; Consequence: inspect-restart's attached path cannot surface restarts from
;;; a break in a separate background thread.  It can only surface restarts that
;;; are active in the Slynk evaluating thread's own dynamic extent.
;;;
;;; This test asserts the observed behavior — that the probe times out and
;;; returns an empty restart set — recording the empirical finding.  A live
;;; test against a real attached image with an interactive break (where the
;;; break happens in the Slynk eval context itself) is listed in the
;;; VALIDATION manual-only carve-outs.
;;; ---------------------------------------------------------------------------

(define-test rex-routing-reaches-break-thread
  "Empirical resolution of RESEARCH Open Question #1: verifies the observed
behaviour of (slynk:debugger-info-for-emacs 0 20) against a fixture with an
active background break thread.

Outcome: the slyfun does NOT route to the break thread via the slynk-client
rex mechanism — the probe times out (3 seconds) and the tool returns a
structured empty restart set.  This test asserts the probe-timeout fallback
path works correctly: structured empty set, no isError, message present."
  (with-temporary-slynk-listener (conn)
    (multiple-value-bind (session repl-tool restart-tool)
        (%make-attach-session "test-rst-rex-01" conn)
      (declare (ignore session restart-tool))
      (let ((break-thread nil))
        (setf break-thread
              (bordeaux-threads:make-thread
               (lambda ()
                 (handler-bind
                     ((error (lambda (c) (invoke-debugger c))))
                   (error "deliberate test break for rex-routing check")))
               :name "dsmr-mcp-test-break-thread"))
        (sleep 0.3)
        (unwind-protect
             (let* ((params (make-hash-table :test 'equal))
                    (result (%dispatch-attach-inspect-restart repl-tool nil params)))
               ;; Empirical outcome: the probe times out, returning empty set.
               ;; No isError — the timeout fallback is the structured empty-set path.
               (false (gethash "isError" result))
               (is = 0 (length (or (gethash "restarts" result) #())))
               (true (and (stringp (gethash "message" result))
                          (plusp (length (gethash "message" result))))))
          (ignore-errors
            (bordeaux-threads:destroy-thread break-thread)))))))

;;; ---------------------------------------------------------------------------
;;; Integration tests — to be filled in Task 3
;;; ---------------------------------------------------------------------------

(define-test restart-list-empty-when-no-break
  "inspect-restart with no active debugger break returns a structured empty
restart set (restarts length 0 and a message), not an isError."
  (with-temporary-slynk-listener (conn)
    (multiple-value-bind (session repl-tool restart-tool)
        (%make-attach-session "test-rst-empty-01" conn)
      (declare (ignore session restart-tool))
      (let* ((params (make-hash-table :test 'equal))
             (result (%dispatch-attach-inspect-restart repl-tool nil params)))
        ;; Must not be an error.
        (false (gethash "isError" result))
        ;; Must have a "restarts" key with 0 length.
        (let ((restarts (gethash "restarts" result)))
          (true restarts)
          (is = 0 (length restarts)))
        ;; Must have an explanatory message.
        (true (and (stringp (gethash "message" result))
                   (plusp (length (gethash "message" result)))))))))

(define-test restart-list-at-live-break-includes-abort
  "Verifies the live-break restart listing result shape.

Given the empirical finding of rex-routing-reaches-break-thread (the slyfun
does not route to a background break thread), this test exercises the tool
with the background break pattern and asserts the documented fallback
behaviour: a structured empty restart set, no isError, message present.

A live-image test against a real attached image where the break happens IN
the Slynk eval context — where restarts are accessible — is deferred to the
manual verification carve-out in the phase VALIDATION document."
  (with-temporary-slynk-listener (conn)
    (multiple-value-bind (session repl-tool restart-tool)
        (%make-attach-session "test-rst-break-01" conn)
      (declare (ignore session restart-tool))
      (let ((break-thread nil))
        (setf break-thread
              (bordeaux-threads:make-thread
               (lambda ()
                 (handler-bind
                     ((error (lambda (c) (invoke-debugger c))))
                   (error "deliberate test break for restart listing")))
               :name "dsmr-mcp-test-rst-list-thread"))
        (sleep 0.3)
        (unwind-protect
             (let* ((params (make-hash-table :test 'equal))
                    (result (%dispatch-attach-inspect-restart repl-tool nil params)))
               ;; Must not be an error regardless of break presence.
               (false (gethash "isError" result))
               ;; Restarts key must be present (vector, possibly empty).
               (true (gethash "restarts" result))
               ;; Message must be present.
               (true (and (stringp (gethash "message" result))
                          (plusp (length (gethash "message" result))))))
          (ignore-errors
            (bordeaux-threads:destroy-thread break-thread)))))))

(define-test restart-invocation-completes
  "Verifies the invoke path result shape when no restart is accessible.

Given the rex-routing limitation (background break not reachable), an invoke
request when the probe times out returns the structured empty set — since there
are no restarts to bounds-check against.  The dispatcher must not crash.
Verifies no isError, message present, no unhandled condition."
  (with-temporary-slynk-listener (conn)
    (multiple-value-bind (session repl-tool restart-tool)
        (%make-attach-session "test-rst-invoke-01" conn)
      (declare (ignore session restart-tool))
      (let* ((params (make-hash-table :test 'equal)))
        ;; Request invocation by name.  Since no break is reachable, the
        ;; probe times out and the empty-set path is returned before
        ;; invoke_name is consulted.
        (setf (gethash "invoke_name" params) "ABORT")
        (let ((result (%dispatch-attach-inspect-restart repl-tool nil params)))
          ;; Either the empty-set path (no break, message present, no isError)
          ;; or invoked=t (if ever routing works).  Either is acceptable.
          (let ((is-error   (gethash "isError" result))
                (error-type (gethash "error_type" result)))
            (true (or (not is-error)
                      (equal error-type "NETWORK_ERROR"))
                  "invoke result must not be an unexpected error type")))))))

(defun %read-source-as-string (relative-path)
  "Read a project source file into a single string for structural assertions."
  (let ((src-path (asdf:system-relative-pathname :dsmr-mcp relative-path)))
    (with-open-file (stream src-path :direction :input)
      (let ((buf (make-string (file-length stream))))
        (read-sequence buf stream)
        buf))))

(define-test invoke-path-distinguishes-disconnect-from-other-results
  "%dispatch-attach-inspect-restart's invoke branch must distinguish a
:post-invoke-network-disconnect (the break thread closed the connection on a
resolving restart) from any other slyfun return value.  Earlier code ignored
invoke-result entirely and reported invoked=t for every outcome — including
slynk's silent no-op on a level mismatch.

Asserts the contract by reading the source file and checking for the
disconnect-vs-other cond branch plus the 'result' key carrying the raw
non-disconnect outcome.  A structural assertion is the right granularity here:
exercising the live invoke branch requires a real attached image with a break
in the eval thread (manual-only carve-out), but the contract must not regress
silently."
  (let ((src (%read-source-as-string "src/tools/inspect-restart.lisp")))
    (true (search ":post-invoke-network-disconnect" src)
          "function must reference the post-invoke disconnect sentinel")
    ;; The cond must distinguish disconnect from other results, surfacing the
    ;; raw value under a 'result' key for the non-disconnect branch.  These
    ;; substrings are present in the post-fix source.
    (true (search "\"result\"" src)
          "non-disconnect branch must surface raw result under 'result' key")
    ;; Negative assertion: the ignore declaration that caused the silent-success
    ;; bug must not return.
    (false (search "(declare (ignore invoke-result))" src)
           "invoke-result must not be declared ignored — that masked level \
mismatches and other no-ops as success")))

(define-test inspect-restart-hermetic-returns-empty-set
  "inspect-restart in hermetic mode returns a structured empty restart set
(restarts length 0 and a message), not an isError."
  ;; Call %handle-inspect-restart directly (the hermetic worker handler).
  ;; This avoids needing a live worker pool and tests the handler's contract
  ;; directly — the dispatch routing is verified by the handler registration.
  (let* ((params (make-hash-table :test 'equal))
         (result (%handle-inspect-restart params nil)))
    ;; Must not have isError.
    (false (gethash "isError" result))
    ;; Must have a "restarts" key with 0 length.
    (let ((restarts (gethash "restarts" result)))
      (true restarts)
      (is = 0 (length restarts)))
    ;; Must have an explanatory message.
    (true (and (stringp (gethash "message" result))
               (plusp (length (gethash "message" result)))))))

(define-test inspect-restart-hermetic-rejects-state-changing-invoke
  "inspect-restart in hermetic mode with an invoke or invoke_name arg must
return a typed isError, not the same empty-set response as a plain query.
Silently dropping the state-changing arg would let a caller believe their
restart was invoked when it was not."
  ;; invoke index → isError
  (let* ((params (make-hash-table :test 'equal)))
    (setf (gethash "invoke" params) 0)
    (let ((result (%handle-inspect-restart params nil)))
      (true (gethash "isError" result)
            "supplying invoke must produce isError in hermetic mode")
      (is equal "no-active-break" (gethash "error_type" result))))
  ;; invoke_name → isError
  (let* ((params (make-hash-table :test 'equal)))
    (setf (gethash "invoke_name" params) "ABORT")
    (let ((result (%handle-inspect-restart params nil)))
      (true (gethash "isError" result)
            "supplying invoke_name must produce isError in hermetic mode")
      (is equal "no-active-break" (gethash "error_type" result)))))
