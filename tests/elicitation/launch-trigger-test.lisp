;;;; tests/elicitation/launch-trigger-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Launch-time consent-gated `.envrc` bring-up: the once-per-session prompt,
;;;; the no-clobber guard, the capability gate, and the jailed write.
;;;;
;;;; These exercise the NON-stdio path of maybe-prompt-and-write-envrc
;;;; (in-reader nil), so the intercept obtains consent via
;;;; send-elicitation-request, which blocks on a condition variable. To control
;;;; consent deterministically without a real client, the main thread spawns a
;;;; router thread that polls session-pending-elicitation and, once the pending
;;;; slot is populated, routes a canned accept/decline response back through
;;;; route-elicitation-response -- exercising the real send/route round-trip.
;;;;
;;;;   - prompt-fires-once: a thread-driven accept on a qualifying temp root
;;;;     writes .envrc; a second call is a no-op (once-per-session guard) and
;;;;     does not write again.
;;;;   - no-prompt-when-envrc-exists: a root that already has .envrc yields a
;;;;     false predicate, no write, original content preserved (no clobber).
;;;;   - no-prompt-without-capability: session-elicitation-p nil is a no-op.
;;;;   - jailed-write-on-accept: on accept the written file is exactly the
;;;;     template content and lives at root/.envrc (resolved via the jail).
;;;;   - decline-writes-nothing: a thread-driven decline sets the prompted flag
;;;;     and writes no file.

;; Package evolution guard: drop a prior incarnation so a reload picks up the
;; current import/export set rather than stale symbols.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/elicitation/launch-trigger-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/elicitation/launch-trigger-test
  (:use #:cl #:parachute)
  (:import-from #:dsmr-mcp/src/envrc-init
                #:maybe-prompt-and-write-envrc
                #:lisp-project-without-envrc-p
                #:lisp-project-envrc-needs-setup-p)
  (:import-from #:dsmr-mcp/src/envrc-template
                #:read-envrc-template)
  (:import-from #:dsmr-mcp/src/state
                #:make-session
                #:session-elicitation-p
                #:session-envrc-prompted-p
                #:session-project-root
                #:session-pending-elicitation)
  (:import-from #:dsmr-mcp/src/elicitation
                #:route-elicitation-response)
  (:import-from #:dsmr-mcp/tests/support/fs-fixture
                #:with-temp-project-root
                #:write-fixture-file)
  (:import-from #:bordeaux-threads
                #:make-thread #:join-thread #:thread-alive-p))

(in-package #:dsmr-mcp/tests/elicitation/launch-trigger-test)

;;; ---------------------------------------------------------------------------
;;; Helpers
;;; ---------------------------------------------------------------------------

(defun %response-ht (id &key (action "accept") (confirm t))
  "Build a client elicitation response hash-table: an id, a result carrying
ACTION and a content object whose `confirm` boolean is CONFIRM, and no method."
  (let ((content (make-hash-table :test 'equal))
        (result  (make-hash-table :test 'equal))
        (msg     (make-hash-table :test 'equal)))
    (setf (gethash "confirm" content) confirm)
    (setf (gethash "action" result) action
          (gethash "content" result) content)
    (setf (gethash "jsonrpc" msg) "2.0"
          (gethash "id"      msg) id
          (gethash "result"  msg) result)
    msg))

(defun %make-consent-router (session &key (action "accept") (deadline 15.0))
  "Spawn a thread that waits for SESSION to register a pending elicitation, then
routes a canned response with ACTION. Returns the thread. The caller runs
maybe-prompt-and-write-envrc on the main thread, which blocks in
send-elicitation-request until this router routes the matching-id response."
  (make-thread
   (lambda ()
     (let ((start (get-internal-real-time))
           (limit (* deadline internal-time-units-per-second)))
       (loop for pending = (session-pending-elicitation session)
             when pending
               do (route-elicitation-response
                   session (%response-ht (first pending) :action action))
                  (return)
             when (> (- (get-internal-real-time) start) limit) return nil
             do (sleep 0.005))))
   :name "envrc-consent-router"))

(defun %join-bounded (thread &key (seconds 45))
  "Join THREAD, bounding the wait so a hung test fails rather than pins the run.
The bound is a hang safety-net, not a budget: it must comfortably exceed the
router work deadline so a slow-but-progressing run on a loaded CI box does not
trip it."
  (handler-case (sb-ext:with-timeout seconds (join-thread thread))
    (sb-ext:timeout ()
      (when (thread-alive-p thread)
        (ignore-errors (bordeaux-threads:destroy-thread thread)))
      (fail "consent router thread did not finish in time"))))

(defun %prompt-with-consent (session action &key (deadline 15.0))
  "Drive maybe-prompt-and-write-envrc (non-stdio path) to completion with a
thread-driven ACTION response. Returns the intercept's return value."
  (let* ((router (%make-consent-router session :action action :deadline deadline))
         (ret    (maybe-prompt-and-write-envrc
                  session (make-string-output-stream))))
    (%join-bounded router)
    ret))

;;; ---------------------------------------------------------------------------
;;; Once-per-session: a second call is a no-op
;;; ---------------------------------------------------------------------------

(define-test prompt-fires-once
  "A thread-driven accept on a qualifying root writes .envrc; a second call is a
no-op (prompted flag set) and does not write again."
  (with-temp-project-root (s root)
    (write-fixture-file root "foo.asd" "x")
    (setf (session-elicitation-p s) t)
    (true (lisp-project-without-envrc-p root)
          "qualifying project before the prompt")
    (true (%prompt-with-consent s "accept")
          "accept should write .envrc and return true")
    (let ((envrc (merge-pathnames ".envrc" root)))
      (true (probe-file envrc) ".envrc should exist after accept")
      (true (session-envrc-prompted-p s) "prompted flag should be set")
      ;; Tamper with the file, then prove a second call leaves it untouched.
      ;; No router: the once-per-session guard short-circuits before any
      ;; round-trip, so no pending slot is ever registered.
      (write-fixture-file root ".envrc" "SENTINEL")
      (false (maybe-prompt-and-write-envrc s (make-string-output-stream))
             "second call should be a no-op (already prompted)")
      (is string= "SENTINEL" (uiop:read-file-string envrc)
          "second call must not rewrite .envrc"))))

;;; ---------------------------------------------------------------------------
;;; No-clobber when .envrc already exists
;;; ---------------------------------------------------------------------------

(define-test no-prompt-when-envrc-exists
  "A root whose .envrc is already complete (exports DSMR_SLYNK_ATTACH) yields a
false create predicate AND a false update predicate: neither trigger fires, no
round-trip starts, and the original content is preserved (no clobber)."
  (with-temp-project-root (s root)
    (write-fixture-file root "foo.asd" "x")
    (write-fixture-file root ".envrc"
                        "ORIGINAL
export DSMR_SLYNK_ATTACH=127.0.0.1:4005
")
    (setf (session-elicitation-p s) t)
    (false (lisp-project-without-envrc-p root)
           "an existing .envrc makes the create predicate false")
    (false (lisp-project-envrc-needs-setup-p root)
           "a complete .envrc makes the update predicate false")
    ;; No router needed: the intercept short-circuits before any round-trip.
    (false (maybe-prompt-and-write-envrc s (make-string-output-stream))
           "no write when a complete .envrc already exists")
    (is string= "ORIGINAL
export DSMR_SLYNK_ATTACH=127.0.0.1:4005
"
        (uiop:read-file-string (merge-pathnames ".envrc" root))
        "existing .envrc content must be preserved")))

;;; ---------------------------------------------------------------------------
;;; No prompt without the elicitation capability
;;; ---------------------------------------------------------------------------

(define-test no-prompt-without-capability
  "session-elicitation-p nil makes the intercept a no-op: no write, no prompt."
  (with-temp-project-root (s root)
    (write-fixture-file root "foo.asd" "x")
    ;; elicitation-p left at its nil default.
    (false (maybe-prompt-and-write-envrc s (make-string-output-stream))
           "no write when the client lacks the elicitation capability")
    (false (probe-file (merge-pathnames ".envrc" root))
           "no .envrc written without capability")
    (false (session-envrc-prompted-p s)
           "prompted flag should stay nil when the gate never opens")))

;;; ---------------------------------------------------------------------------
;;; Jailed write on accept lands the template at root/.envrc
;;; ---------------------------------------------------------------------------

(define-test jailed-write-on-accept
  "On a thread-driven accept the written file is exactly the read-envrc-template
content and lives at root/.envrc (resolved through the write jail)."
  (with-temp-project-root (s root)
    (write-fixture-file root "foo.asd" "x")
    (setf (session-elicitation-p s) t)
    (true (%prompt-with-consent s "accept") "accept should write")
    (let ((envrc (merge-pathnames ".envrc" root)))
      (true (probe-file envrc) ".envrc should land at root/.envrc")
      (is string= (read-envrc-template) (uiop:read-file-string envrc)
          "written content should be exactly the template"))))

;;; ---------------------------------------------------------------------------
;;; Decline writes nothing
;;; ---------------------------------------------------------------------------

(define-test decline-writes-nothing
  "A thread-driven decline sets the prompted flag and writes no file."
  (with-temp-project-root (s root)
    (write-fixture-file root "foo.asd" "x")
    (setf (session-elicitation-p s) t)
    (false (%prompt-with-consent s "decline")
           "decline should not write and should return nil")
    (false (probe-file (merge-pathnames ".envrc" root))
           "no .envrc written on decline")
    (true (session-envrc-prompted-p s)
          "prompted flag should be set even on decline")))

;;; ---------------------------------------------------------------------------
;;; Update path: an existing .envrc that lacks the dsmr-mcp setup
;;; ---------------------------------------------------------------------------

(define-test needs-setup-predicate
  "lisp-project-envrc-needs-setup-p is true only for a *.asd dir whose existing
.envrc lacks DSMR_SLYNK_ATTACH; false for a complete .envrc, no .envrc, no
*.asd, or a nil root."
  (with-temp-project-root (s root)
    (setf (session-elicitation-p s) nil) ; s unused by the predicate; touch it.
    ;; No *.asd yet, no .envrc.
    (false (lisp-project-envrc-needs-setup-p root)
           "false with neither *.asd nor .envrc")
    (false (lisp-project-envrc-needs-setup-p nil) "false for a nil root")
    ;; .envrc present but still no *.asd -> not a Lisp project.
    (write-fixture-file root ".envrc" "export FOO=bar
")
    (false (lisp-project-envrc-needs-setup-p root)
           "false without a *.asd even when an incomplete .envrc exists")
    ;; Now a real project with an incomplete .envrc -> needs setup.
    (write-fixture-file root "foo.asd" "x")
    (true (lisp-project-envrc-needs-setup-p root)
          "true for a *.asd dir whose .envrc lacks DSMR_SLYNK_ATTACH")
    ;; The create predicate must be false here (an .envrc exists).
    (false (lisp-project-without-envrc-p root)
           "create predicate is false once an .envrc exists")
    ;; A complete .envrc (carries the marker export) is never flagged.
    (write-fixture-file root ".envrc" "export DSMR_SLYNK_ATTACH=127.0.0.1:4005
")
    (false (lisp-project-envrc-needs-setup-p root)
           "false once the .envrc exports DSMR_SLYNK_ATTACH")))

(define-test update-appends-on-accept
  "A qualifying needs-setup root + thread-driven accept appends the dsmr-mcp
managed block while preserving the user's original content (append, not
clobber)."
  (with-temp-project-root (s root)
    (write-fixture-file root "foo.asd" "x")
    (write-fixture-file root ".envrc" "export FOO=bar
")
    (setf (session-elicitation-p s) t)
    (true (lisp-project-envrc-needs-setup-p root)
          "qualifying needs-setup project before the prompt")
    (true (%prompt-with-consent s "accept")
          "accept should append and return true")
    (let ((text (uiop:read-file-string (merge-pathnames ".envrc" root))))
      (true (search "FOO=bar" text)
            "the user's original line is preserved")
      (true (search "DSMR_SLYNK_ATTACH" text)
            "the dsmr-mcp managed block was appended")
      (true (session-envrc-prompted-p s) "prompted flag set after the update"))))

(define-test update-decline-writes-nothing
  "A thread-driven decline on a needs-setup root leaves the .envrc unchanged."
  (with-temp-project-root (s root)
    (write-fixture-file root "foo.asd" "x")
    (write-fixture-file root ".envrc" "export FOO=bar
")
    (setf (session-elicitation-p s) t)
    (false (%prompt-with-consent s "decline")
           "decline should not append and should return nil")
    (is string= "export FOO=bar
" (uiop:read-file-string (merge-pathnames ".envrc" root))
        "the .envrc is unchanged on decline")
    (true (session-envrc-prompted-p s)
          "prompted flag set even on decline")))

(define-test update-no-double-append
  "An .envrc that already exports DSMR_SLYNK_ATTACH yields a false predicate, no
prompt fires, and the file is left unchanged (idempotent)."
  (with-temp-project-root (s root)
    (write-fixture-file root "foo.asd" "x")
    (write-fixture-file root ".envrc"
                        "export FOO=bar
export DSMR_SLYNK_ATTACH=127.0.0.1:4005
")
    (setf (session-elicitation-p s) t)
    (false (lisp-project-envrc-needs-setup-p root)
           "a complete .envrc does not need setup")
    ;; No router: neither trigger state qualifies, so no round-trip is started.
    (false (maybe-prompt-and-write-envrc s (make-string-output-stream))
           "no prompt and no write for a complete .envrc")
    (is string= "export FOO=bar
export DSMR_SLYNK_ATTACH=127.0.0.1:4005
"
        (uiop:read-file-string (merge-pathnames ".envrc" root))
        "the complete .envrc is left unchanged")
    (false (session-envrc-prompted-p s)
           "prompted flag stays nil when neither trigger state qualifies")))
