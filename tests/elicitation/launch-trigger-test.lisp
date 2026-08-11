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
  (:use #:cl #:zebra)
  (:import-from #:dsmr-mcp/src/envrc-init
                #:maybe-prompt-and-write-envrc
                #:lisp-project-without-envrc-p
                #:lisp-project-envrc-needs-setup-p
                #:envrc-content-with-derived-port)
  (:import-from #:dsmr-mcp/src/envrc-template
                #:read-envrc-template)
  (:import-from #:dsmr-mcp/src/slynk-port
                #:derive-slynk-port)
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
  "A root whose .envrc is already complete (it declares every marker variable:
DSMR_SLYNK_ATTACH, DSMR_BUS_AGENT and DSMR_BUS_SELECTOR) yields a false create
predicate AND a false update predicate: neither trigger fires, no round-trip
starts, and the original content is preserved (no clobber).

The fixture gained the selector declaration when the selector joined the marker
set. The contract asserted here is the one it always was: a file that carries
everything is left alone and is never offered the settings again."
  (with-temp-project-root (s root)
    (write-fixture-file root "foo.asd" "x")
    (write-fixture-file root ".envrc"
                        "ORIGINAL
export DSMR_SLYNK_ATTACH=127.0.0.1:4005
export DSMR_BUS_AGENT=myproj
export DSMR_BUS_SELECTOR=\"\"
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
export DSMR_BUS_AGENT=myproj
export DSMR_BUS_SELECTOR=\"\"
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
  "On a thread-driven accept the written file carries the project-derived port
and lives at root/.envrc (resolved through the write jail)."
  (with-temp-project-root (s root)
    (write-fixture-file root "foo.asd" "x")
    (setf (session-elicitation-p s) t)
    (true (%prompt-with-consent s "accept") "accept should write")
    (let* ((envrc (merge-pathnames ".envrc" root))
           (written (uiop:read-file-string envrc))
           (port (derive-slynk-port root)))
      (true (probe-file envrc) ".envrc should land at root/.envrc")
      (is string= (envrc-content-with-derived-port (read-envrc-template) root)
          written
          "written content should be the template with the derived port")
      ;; Guard against the substitution silently no-opping (returning the
      ;; template with the default port): the derived port must actually land,
      ;; and the literal default must be gone from the SLYNK_PORT line.
      (true (search (format nil "SLYNK_PORT:-~A}" port) written)
            "the derived port must be substituted into the SLYNK_PORT line")
      (false (search "SLYNK_PORT:-4005}" written)
             "the default port 4005 must not survive substitution"))))

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
  "lisp-project-envrc-needs-setup-p is true for a *.asd dir whose existing
.envrc leaves any marker variable undeclared; false for a fully up-to-date
.envrc, no .envrc, no *.asd, or a nil root. Completion requires EVERY marker;
a file carrying only some of them is still incomplete."
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
    ;; Now a real project with a fully pre-dsmr-mcp .envrc -> needs setup.
    (write-fixture-file root "foo.asd" "x")
    (true (lisp-project-envrc-needs-setup-p root)
          "true for a *.asd dir whose .envrc lacks the dsmr-mcp settings")
    ;; The create predicate must be false here (an .envrc exists).
    (false (lisp-project-without-envrc-p root)
           "create predicate is false once an .envrc exists")
    ;; A slynk-complete-but-bus-missing .envrc (predates the bus) still qualifies.
    (write-fixture-file root ".envrc" "export DSMR_SLYNK_ATTACH=127.0.0.1:4005
")
    (true (lisp-project-envrc-needs-setup-p root)
          "true when slynk is present but DSMR_BUS_AGENT is missing")
    ;; The stanza every repository in the fleet already carries: slynk and bus
    ;; identity, no fleet selector. It used to be the settled shape; it is now
    ;; incomplete, which is what carries the selector out to every repository.
    (write-fixture-file root ".envrc" "export DSMR_SLYNK_ATTACH=127.0.0.1:4005
export DSMR_BUS_AGENT=myproj
")
    (true (lisp-project-envrc-needs-setup-p root)
          "true when the fleet selector is the only marker missing")
    ;; A fully up-to-date .envrc (every marker) is never flagged.
    (write-fixture-file root ".envrc" "export DSMR_SLYNK_ATTACH=127.0.0.1:4005
export DSMR_BUS_AGENT=myproj
export DSMR_BUS_SELECTOR=\"\"
")
    (false (lisp-project-envrc-needs-setup-p root)
           "false once the .envrc declares every marker variable")))

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
      (true (search "DSMR_BUS_SELECTOR" text)
            "the appended block carries the fleet selector")
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

(defun %count-occurrences (needle haystack)
  "Return the number of non-overlapping occurrences of NEEDLE in HAYSTACK.
Char-typed throughout; used to assert an export appears exactly once after an
append (no duplication)."
  (let ((needle (map 'string #'identity needle))
        (haystack (map 'string #'identity haystack)))
    (loop with len = (length needle)
          for start = 0 then (+ pos len)
          for pos = (search needle haystack :start2 start)
          while pos
          count t)))

(define-test slynk-complete-bus-missing-needs-setup
  "A *.asd dir whose .envrc exports DSMR_SLYNK_ATTACH but lacks DSMR_BUS_AGENT
qualifies for the update offer; once every marker is present it does not."
  (with-temp-project-root (s root)
    (write-fixture-file root "foo.asd" "x")
    (write-fixture-file root ".envrc" "export DSMR_SLYNK_ATTACH=127.0.0.1:4005
")
    (true (lisp-project-envrc-needs-setup-p root)
          "slynk present, bus missing => needs setup")
    (write-fixture-file root ".envrc" "export DSMR_SLYNK_ATTACH=127.0.0.1:4005
export DSMR_BUS_AGENT=foo
export DSMR_BUS_SELECTOR=\"\"
")
    (false (lisp-project-envrc-needs-setup-p root)
           "every marker present => done")))

(define-test bus-only-append-preserves-single-slynk
  "Accepting on a slynk-complete-but-bus-missing .envrc appends a bus stanza,
preserves the user's lines, leaves EXACTLY ONE DSMR_SLYNK_ATTACH (no slynk
duplication), and adds DSMR_BUS_AGENT."
  (with-temp-project-root (s root)
    (write-fixture-file root "foo.asd" "x")
    (write-fixture-file root ".envrc"
                        "export FOO=bar
export DSMR_SLYNK_ATTACH=127.0.0.1:4005
")
    (setf (session-elicitation-p s) t)
    (true (lisp-project-envrc-needs-setup-p root)
          "qualifying slynk-complete-but-bus-missing project")
    (true (%prompt-with-consent s "accept")
          "accept should append the bus stanza and return true")
    (let ((text (uiop:read-file-string (merge-pathnames ".envrc" root))))
      (true (search "FOO=bar" text) "the user's original line is preserved")
      (is = 1 (%count-occurrences "DSMR_SLYNK_ATTACH" text)
          "exactly one DSMR_SLYNK_ATTACH after a bus-only append (no duplication)")
      (true (search "DSMR_BUS_AGENT" text) "the bus identity was added")
      (is = 1 (%count-occurrences "export DSMR_BUS_SELECTOR=" text)
          "exactly one DSMR_BUS_SELECTOR after the append (no duplication)")
      (true (search "export DSMR_BUS_SELECTOR=\"${DSMR_BUS_SELECTOR:-}\"" text)
            "the selector arrives with an empty default, so the repository is
still on the shared host-wide bus")
      (true (session-envrc-prompted-p s) "prompted flag set after the update"))))

(define-test slynk-only-append-preserves-single-bus
  "Accepting on a bus-identity-only .envrc (exports DSMR_BUS_AGENT, lacks
DSMR_SLYNK_ATTACH -- e.g. a hand-written bus identity) appends the slynk stanza,
preserves the user's lines, leaves EXACTLY ONE DSMR_BUS_AGENT (no bus
duplication), adds DSMR_SLYNK_ATTACH, and -- the regression this guards --
reaches completion so a subsequent trigger no longer prompts. Before the fix the
handler treated the bus marker as 'done' and wrote nothing, so the trigger
re-prompted every session and Accept could never resolve."
  (with-temp-project-root (s root)
    (write-fixture-file root "foo.asd" "x")
    (write-fixture-file root ".envrc"
                        "export FOO=bar
export DSMR_BUS_AGENT=myproj
")
    (setf (session-elicitation-p s) t)
    (true (lisp-project-envrc-needs-setup-p root)
          "a bus-identity-only .envrc is incomplete (lacks slynk) => needs setup")
    (true (%prompt-with-consent s "accept")
          "accept should append the slynk stanza and return true")
    (let ((text (uiop:read-file-string (merge-pathnames ".envrc" root))))
      (true (search "FOO=bar" text) "the user's original line is preserved")
      (true (search "DSMR_SLYNK_ATTACH" text)
            "the missing slynk attach setup was appended")
      (is = 1 (%count-occurrences "DSMR_BUS_AGENT" text)
          "exactly one DSMR_BUS_AGENT after a slynk-only append (no duplication)")
      (is = 1 (%count-occurrences "export DSMR_BUS_SELECTOR=" text)
          "exactly one DSMR_BUS_SELECTOR after the append (no duplication)")
      (true (session-envrc-prompted-p s) "prompted flag set after the update")
      ;; Completion reached: the trigger and handler now agree, so a fresh
      ;; predicate check on the rewritten file no longer asks to prompt.
      (false (lisp-project-envrc-needs-setup-p root)
             "the appended file is complete (both markers) => no re-prompt"))))

(define-test bus-present-is-noop
  "A .envrc carrying every marker variable is needs-setup false and a
maybe-prompt-and-write call writes nothing (idempotent).

The fixture gained DSMR_BUS_SELECTOR when the selector joined the marker set.
Keeping this case rather than retiring it is the point: the no-op contract is
the one the append path must never lose, and a fixture that stopped being
complete would stop testing it."
  (with-temp-project-root (s root)
    (write-fixture-file root "foo.asd" "x")
    (write-fixture-file root ".envrc"
                        "export DSMR_SLYNK_ATTACH=127.0.0.1:4005
export DSMR_BUS_AGENT=foo
export DSMR_BUS_SELECTOR=\"\"
")
    (setf (session-elicitation-p s) t)
    (false (lisp-project-envrc-needs-setup-p root)
           "a fully-declared .envrc does not need setup")
    (false (maybe-prompt-and-write-envrc s (make-string-output-stream))
           "no prompt and no write for a fully-declared .envrc")
    (is string= "export DSMR_SLYNK_ATTACH=127.0.0.1:4005
export DSMR_BUS_AGENT=foo
export DSMR_BUS_SELECTOR=\"\"
"
        (uiop:read-file-string (merge-pathnames ".envrc" root))
        "the fully-declared .envrc is left unchanged")
    (false (session-envrc-prompted-p s)
           "prompted flag stays nil when neither trigger state qualifies")))

(define-test legacy-append-includes-bus-line
  "The legacy 'lacks slynk entirely' accept still appends the full managed block,
which now also carries the bus line."
  (with-temp-project-root (s root)
    (write-fixture-file root "foo.asd" "x")
    (write-fixture-file root ".envrc" "export FOO=bar
")
    (setf (session-elicitation-p s) t)
    (true (lisp-project-envrc-needs-setup-p root)
          "a fully pre-dsmr-mcp .envrc needs setup")
    (true (%prompt-with-consent s "accept")
          "accept should append the full managed block")
    (let ((text (uiop:read-file-string (merge-pathnames ".envrc" root))))
      (true (search "FOO=bar" text) "the user's original line is preserved")
      (true (search "DSMR_SLYNK_ATTACH" text) "the full block carries slynk")
      (true (search "DSMR_BUS_AGENT" text) "the full block carries the bus line")
      (is = 1 (%count-occurrences "export DSMR_BUS_SELECTOR=" text)
          "the full block carries the fleet selector exactly once"))))

(define-test update-no-double-append
  "An .envrc that already declares every marker variable yields a false
predicate, no prompt fires, and the file is left unchanged (idempotent).

The fixture gained DSMR_BUS_SELECTOR when the selector joined the marker set;
the contract is unchanged and is the reason the fixture was updated rather than
the assertion flipped."
  (with-temp-project-root (s root)
    (write-fixture-file root "foo.asd" "x")
    (write-fixture-file root ".envrc"
                        "export FOO=bar
export DSMR_SLYNK_ATTACH=127.0.0.1:4005
export DSMR_BUS_AGENT=myproj
export DSMR_BUS_SELECTOR=\"\"
")
    (setf (session-elicitation-p s) t)
    (false (lisp-project-envrc-needs-setup-p root)
           "a fully up-to-date .envrc does not need setup")
    ;; No router: neither trigger state qualifies, so no round-trip is started.
    (false (maybe-prompt-and-write-envrc s (make-string-output-stream))
           "no prompt and no write for a fully up-to-date .envrc")
    (is string= "export FOO=bar
export DSMR_SLYNK_ATTACH=127.0.0.1:4005
export DSMR_BUS_AGENT=myproj
export DSMR_BUS_SELECTOR=\"\"
"
        (uiop:read-file-string (merge-pathnames ".envrc" root))
        "the up-to-date .envrc is left unchanged")
    (false (session-envrc-prompted-p s)
           "prompted flag stays nil when neither trigger state qualifies")))

(defun %lines (text)
  "Return TEXT's lines without their newlines, used to count how many lines an
append added."
  (uiop:split-string text :separator (list #\Newline)))

(defparameter +stanza-without-selector+
  "export FOO=bar

# >>> dsmr-mcp (added automatically; edit or remove freely) >>>
export LISP_WORKSPACE=\"${LISP_WORKSPACE:-$HOME/SourceCode/lisp/}\"
export SLYNK_HOST=\"${SLYNK_HOST:-127.0.0.1}\"
export SLYNK_PORT=\"${SLYNK_PORT:-4005}\"
export DSMR_MODE=auto
export DSMR_SLYNK_ATTACH=\"${SLYNK_HOST}:${SLYNK_PORT}\"
export DSMR_LOG_LEVEL=info
export DSMR_BUS_AGENT=\"${DSMR_BUS_AGENT:-myproj}\"
# <<< dsmr-mcp <<<
"
  "The stanza every repository in the fleet is carrying right now: the managed
region as it stood before the fleet selector existed, under one line of the
operator's own. This is the shape the append has to get exactly right, because
it is the shape that actually exists on disk in every repository.")

(define-test old-stanza-gains-only-the-selector
  "An .envrc carrying the full stanza as it stood before the fleet selector
existed gains EXACTLY ONE line, that line declares the selector, every
pre-existing line survives byte for byte and in order, and every managed
variable still appears exactly once.

This is the regression the old shape-selection cond would have failed: with the
two historical markers both present and a third variable absent, it fell through
to the branch that re-appends the whole block, duplicating the exports the file
already carried. The byte-exact expectation below is the evidence that it does
not, and the settled check at the end is the evidence that one accept ends the
prompting rather than starting a loop."
  (with-temp-project-root (s root)
    (write-fixture-file root "foo.asd" "x")
    (write-fixture-file root ".envrc" +stanza-without-selector+)
    (setf (session-elicitation-p s) t)
    (true (lisp-project-envrc-needs-setup-p root)
          "the pre-selector stanza is incomplete, so the offer is made")
    (true (%prompt-with-consent s "accept")
          "accept should append the selector and return true")
    (let ((text (uiop:read-file-string (merge-pathnames ".envrc" root))))
      (is = (1+ (length (%lines +stanza-without-selector+)))
          (length (%lines text))
          "exactly one line was added")
      (is string= "export FOO=bar

# >>> dsmr-mcp (added automatically; edit or remove freely) >>>
export LISP_WORKSPACE=\"${LISP_WORKSPACE:-$HOME/SourceCode/lisp/}\"
export SLYNK_HOST=\"${SLYNK_HOST:-127.0.0.1}\"
export SLYNK_PORT=\"${SLYNK_PORT:-4005}\"
export DSMR_MODE=auto
export DSMR_SLYNK_ATTACH=\"${SLYNK_HOST}:${SLYNK_PORT}\"
export DSMR_LOG_LEVEL=info
export DSMR_BUS_AGENT=\"${DSMR_BUS_AGENT:-myproj}\"
export DSMR_BUS_SELECTOR=\"${DSMR_BUS_SELECTOR:-}\"
# <<< dsmr-mcp <<<
"
          text
          "the operator's line, the markers, and every existing declaration
survive byte for byte, with the selector joining the region already there")
      (dolist (name '("LISP_WORKSPACE" "SLYNK_HOST" "SLYNK_PORT" "DSMR_MODE"
                      "DSMR_SLYNK_ATTACH" "DSMR_LOG_LEVEL" "DSMR_BUS_AGENT"))
        (is = 1 (%count-occurrences (format nil "export ~A=" name) text)
            (format nil "~A must still be declared exactly once" name)))
      (is = 1 (%count-occurrences "export DSMR_BUS_SELECTOR=" text)
          "the selector must be declared exactly once")
      (false (lisp-project-envrc-needs-setup-p root)
             "the appended file is settled, so no re-prompt follows"))))
