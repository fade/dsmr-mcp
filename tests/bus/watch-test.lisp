;;;; tests/bus/watch-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Parachute tests for the cross-agent bus wakeup watcher. The load-bearing
;;;; properties: the watcher fires on a seq strictly above its arm-time baseline
;;;; (so an agent's own just-published message, which is at-or-below the baseline
;;;; once it re-arms, never wakes it), it self-recycles to NIL when the idle
;;;; window passes with nothing new, it tolerates a missing/empty WAL, and the
;;;; streaming step emits exactly one signal per new message, and the streaming
;;;; LOOP coalesces each poll's batch into a single wake carrying the highest seq
;;;; it turned up. The watch loop is a named function exercised directly
;;;; in-process, with no subprocess and no real waiting.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/bus/watch-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/bus/watch-test
  (:use #:cl #:parachute)
  (:import-from #:dsmr-mcp/src/bus/wal
                #:scan
                #:append-record
                ;; the incremental-read machinery the poll path now rides on
                #:make-reader
                #:reader-offset)
  (:import-from #:dsmr-mcp/src/bus/envelope
                #:agent-id
                #:encode-id
                #:wrap-envelope)
  (:import-from #:dsmr-bus-watch/src/bus/watch
                #:watch-until-foreign
                #:watch-stream
                #:poll-new
                #:default-wal-path
                #:default-cursors-dir
                #:default-watch-dir
                ;; internal: argument parsing, identity resolution and baseline
                ;; arming are only observable through main otherwise, and each
                ;; carries behavior worth pinning on its own
                #:%parse-args
                ;; internal: the bounded poll step both loops now share. Its
                ;; restart verdict is the whole of the rotation defence and is
                ;; not observable through the loops' return values.
                #:%poll-forward
                #:%highest-foreign-seq
                #:%resolve-self-id
                #:%resolve-bus
                #:%resolve-baseline
                #:%cursor-path
                ;; internal: the line --check-live prints. Extracted from the
                ;; probe so the answer can be read as a value instead of being
                ;; inferred from a process that exits as it speaks.
                #:%liveness-line
                #:opt-wal
                #:opt-bus
                #:opt-after
                #:opt-agent
                #:opt-namespace
                #:opt-agent-id
                #:opt-cursors-dir
                #:opt-stream-p
                #:opt-poll-ms
                #:opt-recycle-seconds
                #:opt-check-p
                #:opt-live-window-seconds
                #:opt-help-p)
  ;; The heartbeat helpers moved to a shared leaf so the watcher (writer) and the
  ;; MCP core (reader) share one implementation of the beat filename and format.
  ;; The pure liveness decision and its file-backed classifier both carry behavior
  ;; a caller depends on but cannot observe through main alone.
  ;; The bus a watch arms on is derived and validated by the shared selector
  ;; leaf; the refusal is what stops a bad name arming on the shared bus.
  (:import-from #:dsmr-mcp/src/bus/selector
                #:invalid-bus-name)
  (:import-from #:dsmr-mcp/src/bus/heartbeat
                #:beat-path
                #:write-beat
                #:beat-status
                #:beat-liveness))

(in-package #:dsmr-mcp/tests/bus/watch-test)

;;; helpers (local copies of the wal-test fixtures; do not cross-import test pkgs)

(defun temp-wal ()
  (uiop:with-temporary-file (:pathname p :keep t :type "wal" :prefix "dsmr-bus-watch-")
    p))

(defmacro with-wal ((var) &body body)
  `(let ((,var (temp-wal)))
     (unwind-protect (progn ,@body)
       (ignore-errors (delete-file ,var)))))

(defun write-good-wal (path n &optional (body "x"))
  "Append N contiguous good records 1..N."
  (loop for s from 1 to n do (append-record path s body)))

;;; tests ---------------------------------------------------------------------

(define-test fires-when-record-already-above-baseline
  ;; Level-triggered: a qualifying record present at arm returns on the first poll.
  (with-wal (w)
    (write-good-wal w 3)
    (is = 3 (watch-until-foreign w 0 :poll-ms 5 :recycle-seconds 5))))

(define-test does-not-fire-when-nothing-exceeds-baseline
  ;; Baseline at the current max — the agent's own latest message — never wakes it.
  (with-wal (w)
    (write-good-wal w 3)
    (false (watch-until-foreign w 3 :poll-ms 5 :recycle-seconds 0.05))))

(define-test fires-when-record-appended-after-arm
  ;; Append then poll: the new seq is found on the next scan.
  (with-wal (w)
    (write-good-wal w 2)
    (append-record w 3 "x")
    (is = 3 (watch-until-foreign w 2 :poll-ms 5 :recycle-seconds 5))))

(define-test explicit-baseline-ignores-lower-and-equal
  ;; --after-style baseline: equal/lower seqs are ignored; the next higher fires.
  (with-wal (w)
    (write-good-wal w 3)
    (false (watch-until-foreign w 3 :poll-ms 5 :recycle-seconds 0.05))
    (append-record w 4 "x")
    (is = 4 (watch-until-foreign w 3 :poll-ms 5 :recycle-seconds 5))))

(define-test self-recycles-on-empty-wal
  ;; Missing/empty WAL: baseline 0, scan returns 0, recycles to NIL — no error.
  (with-wal (w)
    (ignore-errors (delete-file w))   ; ensure the file does not exist
    (false (watch-until-foreign w 0 :poll-ms 5 :recycle-seconds 0.05))))

(define-test streaming-emits-one-signal-per-new-seq
  ;; The streaming step emits exactly one signal per new message across appends.
  (with-wal (w)
    (let ((seen '()))
      (flet ((collect (s) (push s seen)))
        (let ((cursor 0))
          (append-record w 1 "x")
          (setf cursor (poll-new w cursor #'collect))
          (append-record w 2 "x")
          (setf cursor (poll-new w cursor #'collect))
          (is = 2 cursor)
          (is equal '(1 2) (nreverse seen)))))))

(defun call-capturing-stderr (thunk)
  "Run THUNK with *error-output* redirected, and return (values result text).
   The watcher's degradations are only observable as stderr diagnostics, so the
   text is as much part of the contract as the value."
  (let* ((stream (make-string-output-stream))
         (result (let ((*error-output* stream)) (funcall thunk))))
    (values result (get-output-stream-string stream))))

(defmacro capturing-stderr (&body body)
  `(call-capturing-stderr (lambda () ,@body)))

(defun call-with-env-agent (value thunk)
  "Run THUNK with DSMR_BUS_AGENT set to VALUE (a NIL VALUE unsets it), then put
   the inherited value back. Every one of these tests runs inside this, because
   the developer's own shell exports DSMR_BUS_AGENT and an unbound test would
   quietly resolve their identity instead of the fixture's."
  (let ((previous (uiop:getenv "DSMR_BUS_AGENT")))
    (flet ((apply-env (v)
             (if v
                 (sb-posix:setenv "DSMR_BUS_AGENT" v 1)
                 (ignore-errors (sb-posix:unsetenv "DSMR_BUS_AGENT")))))
      (unwind-protect
           (progn (apply-env value) (funcall thunk))
        (apply-env previous)))))

(defmacro with-env-agent ((value) &body body)
  `(call-with-env-agent ,value (lambda () ,@body)))

(defun call-with-env-selector (value thunk)
  "Run THUNK with DSMR_BUS_SELECTOR set to VALUE (a NIL VALUE unsets it), then
   put the inherited value back. Same reason as the agent-name fixture: a
   developer running these in a direnv shell already exports a selector, and an
   unbound test would resolve their fleet's bus instead of the fixture's."
  (let ((previous (uiop:getenv "DSMR_BUS_SELECTOR")))
    (flet ((apply-env (v)
             (if v
                 (sb-posix:setenv "DSMR_BUS_SELECTOR" v 1)
                 (ignore-errors (sb-posix:unsetenv "DSMR_BUS_SELECTOR")))))
      (unwind-protect
           (progn (apply-env value) (funcall thunk))
        (apply-env previous)))))

(defmacro with-env-selector ((value) &body body)
  `(call-with-env-selector ,value (lambda () ,@body)))

(defmacro with-cursors-dir ((var) &body body)
  "Bind VAR to a fresh empty cursor directory and remove it afterwards. The
   random suffix is seeded per call: SBCL's default random state repeats across
   fresh images, so an unseeded name would collide between runs and an
   absence assertion would flake on a leftover directory."
  `(let ((,var (ensure-directories-exist
                (merge-pathnames
                 (format nil "dsmr-bus-watch-cursors-~D-~D/"
                         (sb-posix:getpid)
                         (random 100000000 (make-random-state t)))
                 (uiop:temporary-directory)))))
     (unwind-protect (progn ,@body)
       (ignore-errors (uiop:delete-directory-tree ,var :validate t)))))

(defun write-cursor (cursors-dir self-id seq)
  "Seed SELF-ID's cursor under CURSORS-DIR at SEQ, in the same on-disk shape the
   owning consumer writes."
  (with-open-file (out (%cursor-path self-id cursors-dir)
                       :direction :output
                       :if-exists :supersede
                       :if-does-not-exist :create)
    (prin1 seq out))
  seq)

(defun append-from (path seq self-id &optional (text "x"))
  "Append record SEQ to PATH as published by SELF-ID. A NIL SELF-ID writes the
   raw text with no envelope at all — a legacy message from an old-core
   publisher."
  (append-record path seq (if self-id (wrap-envelope "c1" self-id text) text))
  seq)

(defun append-addressed (path seq self-id to &optional (text "x"))
  "Append record SEQ to PATH as published by SELF-ID and addressed to TO, using
   the shared envelope leaf rather than a hand-built body. Building the wire
   string here would let this file and the publisher disagree about the format
   the watcher is supposed to be reading."
  (append-record path seq (wrap-envelope "c1" self-id text :to to))
  seq)

(define-test unknown-flag-warns-and-parsing-continues
  ;; A mistyped flag must not deafen the agent: it is named on stderr, skipped,
  ;; and the flags around it still take effect.
  (multiple-value-bind (opts err)
      (capturing-stderr (%parse-args (list "--bogus" "--poll-ms" "250")))
    (is = 250 (opt-poll-ms opts))
    (is = 600 (opt-recycle-seconds opts))
    (false (opt-wal opts))
    (false (opt-after opts))
    (true (search "--bogus" err))))

(define-test unparseable-value-keeps-that-flags-default
  ;; A value that will not parse costs its own flag only, never the whole run.
  (multiple-value-bind (opts err)
      (capturing-stderr (%parse-args (list "--poll-ms" "banana"
                                           "--recycle-seconds" "30")))
    (is = 1000 (opt-poll-ms opts))
    (is = 30 (opt-recycle-seconds opts))
    (true (search "--poll-ms" err))))

(define-test dangling-value-flag-warns-and-resolves-nothing
  ;; A value-taking flag at the very end of argv has nothing to consume.
  (multiple-value-bind (opts err)
      (capturing-stderr (%parse-args (list "--agent")))
    (false (opt-agent opts))
    (true (search "--agent" err))))

(define-test identity-flags-parse
  (let ((opts (%parse-args (list "--agent" "runciter"
                                 "--namespace" "/p"
                                 "--agent-id" "/p/runciter"
                                 "--cursors-dir" "/tmp/cursors/"))))
    (is equal "runciter" (opt-agent opts))
    (is equal "/p" (opt-namespace opts))
    (is equal "/p/runciter" (opt-agent-id opts))
    (is equal "/tmp/cursors/" (opt-cursors-dir opts))))

(define-test previously-supported-flags-parse-unchanged
  ;; Every combination the arm wrapper passes today, plus the operator-facing
  ;; overrides, must land on the same values they did before the flags grew.
  (let ((opts (%parse-args (list "--wal" "/tmp/x.wal" "--after" "7" "--stream"))))
    (is equal "/tmp/x.wal" (opt-wal opts))
    (is = 7 (opt-after opts))
    (true (opt-stream-p opts)))
  (dolist (cadence '(("500" "60") ("1000" "120") ("1000" "300") ("1000" "600")))
    (destructuring-bind (poll recycle) cadence
      (let ((opts (%parse-args (list "--poll-ms" poll "--recycle-seconds" recycle))))
        (is = (parse-integer poll) (opt-poll-ms opts))
        (is = (parse-integer recycle) (opt-recycle-seconds opts))
        (false (opt-stream-p opts))
        (false (opt-wal opts))
        (false (opt-after opts)))))
  (true (opt-help-p (%parse-args (list "--help"))))
  (true (opt-help-p (%parse-args (list "-h")))))

(define-test bus-flag-parses
  ;; The flag exists so a generated arm line an operator reads says which bus it
  ;; arms on. Absent, the record carries nothing and the default bus is meant.
  (is equal "valis" (opt-bus (%parse-args (list "--bus" "valis"))))
  (false (opt-bus (%parse-args '())))
  ;; It sits beside the other identity flags and does not disturb them.
  (let ((opts (%parse-args (list "--bus" "valis"
                                 "--agent" "runciter"
                                 "--namespace" "/p"))))
    (is equal "valis" (opt-bus opts))
    (is equal "runciter" (opt-agent opts))
    (is equal "/p" (opt-namespace opts))))

(define-test dangling-bus-flag-warns-and-resolves-nothing
  ;; A dangling --bus degrades exactly as every other value-taking flag does:
  ;; named on stderr, then ignored, leaving the watcher on the default bus
  ;; rather than refusing to start.
  (with-env-selector (nil)
    (multiple-value-bind (opts err)
        (capturing-stderr (%parse-args (list "--bus")))
      (false (opt-bus opts))
      (true (search "--bus" err))
      (false (%resolve-bus opts)))))

(define-test bus-resolves-from-flag-then-environment
  ;; The same order the agent name resolves by, reading the same variable the
  ;; .envrc stanza declares and the MCP session resolves its bus from, so the
  ;; watcher and the session it serves cannot land on different buses.
  (with-env-selector (nil)
    (is equal "valis" (%resolve-bus (%parse-args (list "--bus" "valis"))))
    (false (%resolve-bus (%parse-args '()))))
  (with-env-selector ("fromenv")
    (is equal "fromenv" (%resolve-bus (%parse-args '())))
    (is equal "valis" (%resolve-bus (%parse-args (list "--bus" "valis")))))
  ;; An empty environment value reads as absent, not as a bus called "".
  (with-env-selector ("")
    (false (%resolve-bus (%parse-args '())))))

(define-test an-unusable-bus-name-is-refused-not-downgraded
  ;; The one refusal in a binary that otherwise favours availability. Falling
  ;; back to the shared bus here would arm a watch nobody is publishing to,
  ;; which reports healthy and never fires.
  (with-env-selector (nil)
    (fail (%resolve-bus (%parse-args (list "--bus" "nope-not-a/name")))
          'invalid-bus-name)
    (fail (%resolve-bus (%parse-args (list "--bus" "cursors")))
          'invalid-bus-name))
  (with-env-selector ("nope-not-a/name")
    (fail (%resolve-bus (%parse-args '())) 'invalid-bus-name)
    ;; And an explicit good name still wins over a bad environment value.
    (is equal "valis" (%resolve-bus (%parse-args (list "--bus" "valis"))))))

(define-test identity-name-resolves-from-flag-then-environment
  ;; The same order the MCP session uses: explicit name, then DSMR_BUS_AGENT,
  ;; with an empty environment value reading as absent.
  (with-env-agent (nil)
    (is equal (agent-id "/p" :name "flagged")
        (%resolve-self-id (%parse-args (list "--agent" "flagged"
                                             "--namespace" "/p"))))
    (false (%resolve-self-id (%parse-args (list "--namespace" "/p")))))
  (with-env-agent ("fromenv")
    (is equal (agent-id "/p" :name "fromenv")
        (%resolve-self-id (%parse-args (list "--namespace" "/p"))))
    (is equal (agent-id "/p" :name "flagged")
        (%resolve-self-id (%parse-args (list "--agent" "flagged"
                                             "--namespace" "/p")))))
  (with-env-agent ("")
    (false (%resolve-self-id (%parse-args (list "--namespace" "/p"))))))

(define-test full-agent-id-is-taken-verbatim
  ;; A caller that already knows the whole id skips construction entirely.
  (with-env-agent ("fromenv")
    (is equal "/other/name"
        (%resolve-self-id (%parse-args (list "--agent-id" "/other/name"
                                             "--agent" "flagged"
                                             "--namespace" "/p"))))))

(define-test namespace-inferred-from-working-directory-says-so
  ;; The last-resort namespace still works, but never silently: watching the
  ;; wrong cursor because the operator was standing somewhere else is the bug
  ;; this warning exists to make visible.
  (with-env-agent (nil)
    (multiple-value-bind (self-id err)
        (capturing-stderr (%resolve-self-id (%parse-args (list "--agent" "a"))))
      (is equal (agent-id (namestring (uiop:getcwd)) :name "a") self-id)
      (true (search "working directory" err)))))

(define-test baseline-comes-from-the-agents-durable-cursor
  ;; The arm-window fix: a record between the last drain and this arm sits above
  ;; the cursor, so it is still reachable.
  (with-wal (w)
    (write-good-wal w 9)
    (with-cursors-dir (dir)
      (with-env-agent (nil)
        (let* ((opts (%parse-args (list "--agent" "runciter" "--namespace" "/p")))
               (self-id (%resolve-self-id opts)))
          (write-cursor dir self-id 4)
          (is = 4 (%resolve-baseline opts self-id w dir)))))))

(define-test absent-cursor-arms-at-head-never-at-zero
  ;; The structural stop on the fire loop. A missing cursor read as 0 would make
  ;; the whole log pending, fire, and — with the agent draining its real cursor
  ;; elsewhere — fire again on every poll for as long as the watcher lives.
  (with-wal (w)
    (write-good-wal w 9)
    (with-cursors-dir (dir)
      (with-env-agent (nil)
        (let* ((opts (%parse-args (list "--agent" "runciter" "--namespace" "/p")))
               (self-id (%resolve-self-id opts)))
          (multiple-value-bind (baseline err)
              (capturing-stderr (%resolve-baseline opts self-id w dir))
            (is = 9 baseline)
            (isnt = 0 baseline)
            (true (search (namestring (%cursor-path self-id dir)) err))
            ;; Twice over an unchanged fixture: the second arm must not drift
            ;; toward 0 either, since that is how the loop would start.
            (is = 9 (capturing-stderr
                      (%resolve-baseline opts self-id w dir)))))))))

(define-test unreadable-cursor-arms-at-head-never-at-zero
  ;; A cursor file holding something that is not a sequence number is as
  ;; untrustworthy as a missing one, and must degrade the same way.
  (with-wal (w)
    (write-good-wal w 6)
    (with-cursors-dir (dir)
      (with-env-agent (nil)
        (let* ((opts (%parse-args (list "--agent" "runciter" "--namespace" "/p")))
               (self-id (%resolve-self-id opts)))
          (with-open-file (out (%cursor-path self-id dir)
                               :direction :output
                               :if-exists :supersede
                               :if-does-not-exist :create)
            (write-string "not-a-seq" out))
          (multiple-value-bind (baseline err)
              (capturing-stderr (%resolve-baseline opts self-id w dir))
            (is = 6 baseline)
            (isnt = 0 baseline)
            (true (search "cursor" err))))))))

(define-test no-identity-degrades-to-the-head-baseline-and-warns
  ;; The pre-identity behavior, preserved exactly, but no longer silent.
  (with-wal (w)
    (write-good-wal w 5)
    (with-cursors-dir (dir)
      (with-env-agent (nil)
        (let* ((opts (%parse-args '()))
               (self-id (%resolve-self-id opts)))
          (false self-id)
          (multiple-value-bind (baseline err)
              (capturing-stderr (%resolve-baseline opts self-id w dir))
            (is = 5 baseline)
            (true (search "no agent identity" err))))))))

(define-test explicit-after-outranks-the-cursor-baseline
  ;; The operator's manual override keeps the precedence it has always had.
  (with-wal (w)
    (write-good-wal w 9)
    (with-cursors-dir (dir)
      (with-env-agent (nil)
        (let* ((opts (%parse-args (list "--agent" "runciter"
                                        "--namespace" "/p"
                                        "--after" "2")))
               (self-id (%resolve-self-id opts)))
          (write-cursor dir self-id 4)
          (is = 2 (%resolve-baseline opts self-id w dir)))))))

(define-test our-own-publishes-never-fire-the-watch
  ;; The reason arming no longer depends on publishing first.
  (with-wal (w)
    (let ((me (agent-id "/p" :name "me")))
      (append-from w 1 me)
      (append-from w 2 me)
      (false (watch-until-foreign w 0 :poll-ms 5 :recycle-seconds 0.05
                                      :self-id me)))))

(define-test foreign-record-among-our-own-fires-with-its-own-seq
  ;; The fired seq is the foreign record's, not the log head's — the head here
  ;; belongs to this agent and is nothing to wake anyone for.
  (with-wal (w)
    (let ((me (agent-id "/p" :name "me"))
          (them (agent-id "/p" :name "them")))
      (append-from w 1 me)
      (append-from w 2 them)
      (append-from w 3 me)
      (is = 2 (watch-until-foreign w 0 :poll-ms 5 :recycle-seconds 5
                                       :self-id me)))))

(define-test legacy-unenveloped-record-fires
  ;; A body with no envelope carries no author. Reading that as "ours" would
  ;; drop real traffic every time a publisher lagged a core rebuild.
  (with-wal (w)
    (append-from w 1 nil "a plain body from an old-core publisher")
    (is = 1 (watch-until-foreign w 0 :poll-ms 5 :recycle-seconds 5
                                     :self-id (agent-id "/p" :name "me")))))

(define-test without-an-identity-every-record-fires
  ;; No self to recognize means no filter, byte for byte the old behavior.
  (with-wal (w)
    (append-from w 1 (agent-id "/p" :name "me"))
    (is = 1 (watch-until-foreign w 0 :poll-ms 5 :recycle-seconds 5))))

(define-test a-broadcast-still-fires-the-watch
  ;; The default case, pinned explicitly now that the filter asks a second
  ;; question: a record naming nobody is for everybody, and narrowing the filter
  ;; must not have narrowed it to nothing.
  (with-wal (w)
    (let ((me (agent-id "/p" :name "me"))
          (them (agent-id "/p" :name "them")))
      (append-from w 1 them)
      (is = 1 (watch-until-foreign w 0 :poll-ms 5 :recycle-seconds 5
                                       :self-id me)))))

(define-test mail-addressed-to-us-fires-the-watch
  ;; The point of the whole feature at this end: a message that names this
  ;; watcher's identity must wake it, exactly as a broadcast does.
  (with-wal (w)
    (let ((me (agent-id "/p" :name "me"))
          (them (agent-id "/p" :name "them")))
      (append-addressed w 1 them me)
      (is = 1 (watch-until-foreign w 0 :poll-ms 5 :recycle-seconds 5
                                       :self-id me)))))

(define-test mail-for-somebody-else-does-not-fire-the-watch
  ;; The reason the filter narrowed. Waking this agent for a message it will
  ;; never be shown burns a context window and returns nothing, so the watch
  ;; must sit through it and recycle on its own idle window instead.
  (with-wal (w)
    (let ((me (agent-id "/p" :name "me"))
          (them (agent-id "/p" :name "them"))
          (someone-else (agent-id "/p" :name "someone-else")))
      (append-addressed w 1 them someone-else)
      (false (watch-until-foreign w 0 :poll-ms 5 :recycle-seconds 0.05
                                      :self-id me)
             "other people's mail leaves the watch running to its recycle"))))

(define-test a-broadcast-fires-past-mail-for-somebody-else
  ;; Skipping someone else's mail must not skip what follows it, and the fired
  ;; seq is the broadcast's own rather than the head of the log.
  (with-wal (w)
    (let ((me (agent-id "/p" :name "me"))
          (them (agent-id "/p" :name "them"))
          (someone-else (agent-id "/p" :name "someone-else")))
      (append-addressed w 1 them someone-else)
      (append-from w 2 them)
      (append-addressed w 3 them someone-else)
      (is = 2 (watch-until-foreign w 0 :poll-ms 5 :recycle-seconds 5
                                       :self-id me)))))

(define-test without-an-identity-mail-for-somebody-else-still-fires
  ;; The no-identity branch is unchanged. With nothing resolved there is no self
  ;; to recognise and no addressee to compare, so everything counts, which is
  ;; the pre-identity behaviour and still the only safe reading: a watcher that
  ;; cannot tell whose mail it is must not decide it is not ours.
  (with-wal (w)
    (let ((them (agent-id "/p" :name "them"))
          (someone-else (agent-id "/p" :name "someone-else")))
      (append-addressed w 1 them someone-else)
      (is = 1 (watch-until-foreign w 0 :poll-ms 5 :recycle-seconds 5)))))

(define-test mail-addressed-to-us-before-the-arm-fires-on-the-first-poll
  ;; Level-triggered arming, over the narrowed filter. A message that landed
  ;; between the agent's last drain and this arm sits above the cursor, and it
  ;; must still be found on the first look rather than waiting for the next
  ;; record to come along.
  (with-wal (w)
    (let ((me (agent-id "/p" :name "me"))
          (them (agent-id "/p" :name "them")))
      (append-from w 1 me)
      (append-addressed w 2 them me)
      (is = 2 (watch-until-foreign w 0 :poll-ms 5 :recycle-seconds 5
                                       :self-id me)))))

(define-test streaming-skips-our-own-and-still-steps-over-them
  ;; One signal per foreign seq, and the cursor clears the skipped records so
  ;; the next poll does not re-examine them.
  (with-wal (w)
    (let ((me (agent-id "/p" :name "me"))
          (them (agent-id "/p" :name "them"))
          (seen '()))
      (flet ((collect (s) (push s seen)))
        (append-from w 1 me)
        (append-from w 2 them)
        (let ((cursor (poll-new w 0 #'collect me)))
          (is = 2 cursor)
          (is equal '(2) (reverse seen))
          (setf seen '())
          (append-from w 3 me)
          (append-from w 4 them)
          (setf cursor (poll-new w cursor #'collect me))
          (is = 4 cursor)
          (is equal '(4) (reverse seen)))))))

(define-test streaming-skips-mail-for-somebody-else-and-still-steps-over-it
  ;; The streaming step must ask the same question delivery asks. Emitting for
  ;; a third party's mail wakes a sister to read a bus that then shows it
  ;; nothing, and streaming is the mode a fleet actually arms. The cursor must
  ;; clear the withheld record all the same, or a quiet stretch of other
  ;; people's mail pins the log at the first one.
  (with-wal (w)
    (let ((me (agent-id "/p" :name "me"))
          (them (agent-id "/p" :name "them"))
          (someone-else (agent-id "/p" :name "someone-else"))
          (seen '()))
      (flet ((collect (s) (push s seen)))
        (append-addressed w 1 them someone-else)
        (append-from w 2 them)
        (let ((cursor (poll-new w 0 #'collect me)))
          (is = 2 cursor "the cursor clears the mail we were not shown")
          (is equal '(2) (reverse seen)
              "only the record we would be handed is emitted"))
        (setf seen '())
        ;; A step in which every record belongs to somebody else emits nothing
        ;; and still advances, which is what keeps the log from pinning.
        (append-addressed w 3 them someone-else)
        (append-addressed w 4 them someone-else)
        (let ((cursor (poll-new w 2 #'collect me)))
          (is = 4 cursor "a step holding nothing for us still advances")
          (is equal '() (reverse seen) "and emits nothing"))))))

(define-test watch-stream-emits-only-foreign-seqs
  ;; The whole streaming loop, not just one step of it.
  (with-wal (w)
    (let ((me (agent-id "/p" :name "me"))
          (them (agent-id "/p" :name "them"))
          (seen '()))
      (append-from w 1 me)
      (append-from w 2 them)
      (append-from w 3 me)
      (let ((final (watch-stream w 0 :poll-ms 5 :recycle-seconds 0.05
                                     :self-id me
                                     :emit (lambda (s) (push s seen)))))
        (is = 3 final)
        (is equal '(2) (reverse seen))))))

(define-test streaming-wakes-once-per-poll-batch-carrying-the-highest-seq
  ;; The reader on the other end of the signal drains everything pending in one
  ;; call, so a burst that lands between two polls has to produce ONE wake and
  ;; not one per record. The extra wakes were never merely redundant: each one
  ;; costs the woken agent a whole turn to discover the work was already done.
  ;;
  ;; The burst is published from inside the poll thunk, on the second poll, so
  ;; it genuinely arrives between two reads rather than sitting there at arm.
  (with-wal (w)
    (let ((me (agent-id "/p" :name "me"))
          (them (agent-id "/p" :name "them"))
          (seen '())
          (polls 0))
      (flet ((publish-a-burst-on-the-second-poll ()
               (incf polls)
               (when (= polls 2)
                 (append-from w 1 them)
                 (append-from w 2 them)
                 (append-from w 3 them)
                 (append-from w 4 them))))
        (let ((final (watch-stream w 0 :poll-ms 5 :recycle-seconds 0.25
                                       :self-id me
                                       :emit (lambda (s) (push s seen))
                                       :on-poll
                                       #'publish-a-burst-on-the-second-poll)))
          (is = 4 final)
          (is = 1 (length seen)
              "a four-record burst must wake the reader exactly once")
          (is equal '(4) seen
              "and that one wake must carry the highest seq of the batch"))))))

(define-test streaming-wakes-once-for-a-single-record
  ;; The degenerate batch, and most of the traffic on a quiet bus. Coalescing a
  ;; burst must not cost the ordinary case its wake, nor duplicate it.
  (with-wal (w)
    (let ((me (agent-id "/p" :name "me"))
          (them (agent-id "/p" :name "them"))
          (seen '())
          (polls 0))
      (flet ((publish-one-on-the-second-poll ()
               (incf polls)
               (when (= polls 2) (append-from w 1 them))))
        (let ((final (watch-stream w 0 :poll-ms 5 :recycle-seconds 0.25
                                       :self-id me
                                       :emit (lambda (s) (push s seen))
                                       :on-poll #'publish-one-on-the-second-poll)))
          (is = 1 final)
          (is = 1 (length seen) "one record must produce exactly one wake")
          (is equal '(1) seen))))))

(define-test streaming-arm-coalesces-a-standing-backlog-into-one-wake
  ;; The same property on the first poll, which is the one that reads the whole
  ;; log. A backlog waiting at arm time is the largest batch a watch ever sees,
  ;; so it is also the worst case for one-wake-per-record: an agent coming back
  ;; up to a quiet stretch of mail would be woken once for every message in it.
  ;;
  ;; A recycle window of zero puts the deadline in the past, so the loop gets
  ;; exactly one poll and the count cannot be confused by a later one. The
  ;; trailing record is our own publish, which advances the cursor past the
  ;; wake it does not cause.
  (with-wal (w)
    (let ((me (agent-id "/p" :name "me"))
          (them (agent-id "/p" :name "them"))
          (seen '()))
      (append-from w 1 them)
      (append-from w 2 them)
      (append-from w 3 them)
      (append-from w 4 me)
      (let ((final (watch-stream w 0 :poll-ms 5 :recycle-seconds 0
                                     :self-id me
                                     :emit (lambda (s) (push s seen)))))
        (is = 4 final "the cursor clears our own publish too")
        (is = 1 (length seen) "a standing backlog is one wake, not three")
        (is equal '(3) seen
            "carrying the highest seq we would actually be handed")))))

;;; heartbeat -----------------------------------------------------------------

(defmacro with-watch-dir ((var) &body body)
  "Bind VAR to a fresh empty heartbeat directory and remove it afterwards. The
   random suffix is seeded per call for the same reason WITH-CURSORS-DIR seeds
   its own: SBCL's default random state repeats across fresh images, so an
   unseeded name would collide between runs and a `dead`/absent assertion would
   flake on a leftover file."
  `(let ((,var (ensure-directories-exist
                (merge-pathnames
                 (format nil "dsmr-bus-watch-beats-~D-~D/"
                         (sb-posix:getpid)
                         (random 100000000 (make-random-state t)))
                 (uiop:temporary-directory)))))
     (unwind-protect (progn ,@body)
       (ignore-errors (uiop:delete-directory-tree ,var :validate t)))))

(define-test beat-liveness-is-dead-for-a-missing-file
  ;; No heartbeat at all is the `not running` case: an agent whose watch never
  ;; started, or one whose watch unwound cleanly and removed its beat.
  (with-watch-dir (dir)
    (let ((path (merge-pathnames "absent.beat" dir)))
      (is eq :dead (beat-liveness path 100)))))

(define-test beat-liveness-is-live-for-a-just-written-beat
  ;; A beat written this instant is well inside any sane window; a real live
  ;; watch rewrites it every poll, so its beat is never older than a poll.
  (with-watch-dir (dir)
    (let ((path (beat-path (agent-id "/p" :name "me") dir)))
      (write-beat path :mode :stream :baseline 3 :poll-ms 250)
      (multiple-value-bind (status age pid) (beat-liveness path 100)
        (is eq :live status)
        (true (integerp age))
        (is = (sb-posix:getpid) pid)))))

(define-test beat-status-threshold-is-inclusive-of-the-window
  ;; The pure age->status decision, tested straight across the boundary so the
  ;; threshold is pinned without any clock games: at-or-within is live, past is
  ;; stale.
  (is eq :live  (beat-status 0 5))
  (is eq :live  (beat-status 4 5))
  (is eq :live  (beat-status 5 5))
  (is eq :stale (beat-status 6 5))
  (is eq :stale (beat-status 100 5)))

(define-test beat-path-is-stable-for-a-given-identity
  ;; Write and check must name the same file byte for byte, so the path a self-id
  ;; maps to cannot depend on anything but the id and the directory.
  (with-watch-dir (dir)
    (let ((id (agent-id "/p" :name "runciter")))
      (is equal
          (namestring (beat-path id dir))
          (namestring (beat-path id dir))))))

(define-test every-liveness-answer-names-its-bus
  ;; D-05. The field is on every answer, the default bus included: a field that
  ;; appeared only for a named bus could not tell a watcher on the default bus
  ;; apart from a binary too old to know buses have names.
  (is equal "live pid=42 age_s=1 bus=valis" (%liveness-line :live 1 42 "valis"))
  (is equal "live pid=42 age_s=1 bus=default" (%liveness-line :live 1 42 nil))
  (is equal "stale pid=42 age_s=99 bus=valis" (%liveness-line :stale 99 42 "valis"))
  (is equal "stale pid=42 age_s=99 bus=default" (%liveness-line :stale 99 42 nil))
  (is equal "dead bus=valis" (%liveness-line :dead nil nil "valis"))
  (is equal "dead bus=default" (%liveness-line :dead nil nil nil))
  ;; An absent pid still renders as it always did; the bus field is appended,
  ;; never substituted for anything an agent already parses.
  (is equal "live pid=? age_s=1 bus=default" (%liveness-line :live 1 nil nil))
  ;; No line carries a newline: the probe owns the printing.
  (false (find #\Newline (%liveness-line :live 1 42 "valis"))))

(define-test the-unresolved-identity-answer-has-no-bus-to-name
  ;; The `unknown` line is deliberately not this function's business. No bus is
  ;; worth naming beside an identity that did not resolve: it would read as a
  ;; probe that found something. The probe prints that line itself, unchanged.
  (fail (%liveness-line :unknown nil nil "valis")))

(define-test a-named-bus-keeps-its-own-watcher-paths
  ;; D-19. One --check-live per joined bus only means something if the beat
  ;; files differ, and they differ because every path the watcher derives hangs
  ;; off the bus root. Two watchers for one identity on two buses can then not
  ;; overwrite each other's beat, or read each other's cursor.
  (let ((id (agent-id "/p" :name "runciter")))
    (isnt equal
          (beat-path id (default-watch-dir))
          (beat-path id (default-watch-dir "valis")))
    (isnt equal
          (beat-path id (default-watch-dir "valis"))
          (beat-path id (default-watch-dir "fulcrum")))
    (isnt equal (default-wal-path) (default-wal-path "valis"))
    (isnt equal (default-cursors-dir) (default-cursors-dir "valis"))
    ;; The named paths are the unnamed root plus one segment; the unnamed ones
    ;; carry no segment at all.
    (true (search "/valis/" (namestring (default-watch-dir "valis"))))
    (false (search "/valis/" (namestring (default-watch-dir))))
    ;; And nothing changes for a watcher with no bus: an absent name and an
    ;; explicit NIL both land on the paths the binary has always used.
    (is equal (namestring (default-wal-path)) (namestring (default-wal-path nil)))
    (is equal (namestring (default-cursors-dir))
        (namestring (default-cursors-dir nil)))
    (is equal (namestring (beat-path id (default-watch-dir)))
        (namestring (beat-path id (default-watch-dir nil))))))

(defun write-generation (path n &key (ts-base 1000) (body "xxxxxxxx"))
  "Empty PATH and write a fresh log of N contiguous records with deterministic
   timestamps. TS-BASE is what distinguishes one generation of the log from the
   next: two generations written with the same bodies put records of identical
   length carrying identical seqs at identical byte offsets, so the timestamp —
   and the CRC that covers it — is the only thing telling them apart. That is
   exactly the distinction a reader resuming from a remembered offset has to be
   able to make, so the fixture is built to remove every easier cue."
  (with-open-file (out path :direction :output :element-type '(unsigned-byte 8)
                            :if-exists :supersede :if-does-not-exist :create)
    (declare (ignore out)))
  (loop for s from 1 to n do (append-record path s body :ts (+ ts-base s)))
  path)

(defun run-poll-script (wal me &key reader)
  "Drive one fixed publish-and-poll script over WAL and return (values emitted
   cursors). With READER the polls are incremental; without one each poll builds
   its own throwaway reader and reads the whole log, which is what the watcher
   did before it carried a position. From out here the two must be
   indistinguishable, which is the point of driving them through one script."
  (let ((seen '())
        (cursors '())
        (cursor 0)
        (them (agent-id "/p" :name "them")))
    (labels ((collect (s) (push s seen))
             (advance (c)
               (let ((next (if reader
                               (poll-new wal c #'collect me reader)
                               (poll-new wal c #'collect me))))
                 (push next cursors)
                 next)))
      (append-from wal 1 me)
      (append-from wal 2 them)
      (append-from wal 3 them)
      (setf cursor (advance cursor))
      (append-from wal 4 me)
      (setf cursor (advance cursor))
      (setf cursor (advance cursor))       ; a quiet poll: nothing was published
      (append-from wal 5 them)
      (append-from wal 6 them)
      (advance cursor)
      (values (nreverse seen) (nreverse cursors)))))

(define-test incremental-polling-says-what-a-full-read-would-say
  ;; Differential: the same publish-and-poll script run twice, once reading only
  ;; what was appended since the last look and once reading the whole log every
  ;; time. Reading less must not mean seeing less — not the seqs emitted, and not
  ;; the cursor handed back at each step.
  (let (incremental-seen incremental-cursors full-seen full-cursors)
    (with-wal (w)
      (multiple-value-setq (incremental-seen incremental-cursors)
        (run-poll-script w (agent-id "/p" :name "me") :reader (make-reader))))
    (with-wal (w)
      (multiple-value-setq (full-seen full-cursors)
        (run-poll-script w (agent-id "/p" :name "me"))))
    (is equal '(2 3 5 6) full-seen)
    (is equal '(3 4 4 6) full-cursors)
    (is equal full-seen incremental-seen)
    (is equal full-cursors incremental-cursors)))

(define-test a-log-replaced-under-the-watch-is-reread-from-its-new-head
  ;; The trap a remembered byte offset walks into. A rotation empties the log and
  ;; the next broker numbers from 1 again, so a record of the same shape carrying
  ;; the very same seq lands at the very same offset, and the file can be longer
  ;; than before so its length gives nothing away either. A reader that asked only
  ;; "is there a good record where I stopped?" would pass that check, resume in
  ;; the middle of a log it has never read, and never mention anything below it —
  ;; a watch gone silently deaf while every integrity check it makes still passes.
  ;;
  ;; Both generations here are written with identical bodies and identical seqs,
  ;; so the timestamps, and the CRC covering them, are the only evidence the log
  ;; changed. Emitting all eight is what says that evidence was actually used;
  ;; emitting 6, 7 and 8 is precisely the failure being ruled out.
  (with-wal (w)
    (let ((reader (make-reader))
          (seen '()))
      (write-generation w 5 :ts-base 1000)
      (is = 5 (poll-new w 0 (lambda (s) (push s seen)) nil reader))
      (is equal '(1 2 3 4 5) (reverse seen))
      (setf seen '())
      (write-generation w 8 :ts-base 9000)
      (multiple-value-bind (cursor restarted)
          (poll-new w 5 (lambda (s) (push s seen)) nil reader)
        (true restarted "a replaced log must be reported as a restart, not read as growth")
        (is = 8 cursor)
        (is equal '(1 2 3 4 5 6 7 8) (reverse seen))))))

(define-test a-shorter-log-drags-the-cursor-back-instead-of-going-deaf
  ;; The other half of the same problem, and the one a cursor that only ever
  ;; climbs gets wrong. When the replacement log is SHORTER than the seq the watch
  ;; was holding, keeping the larger of the two leaves the watch parked above
  ;; every seq the new log will ever produce: it polls forever, reports itself
  ;; healthy, and can never fire again. The cursor has to come back down with the
  ;; log, because the two numbers count different logs.
  (with-wal (w)
    (let ((reader (make-reader))
          (seen '()))
      (write-generation w 6 :ts-base 1000)
      (is = 6 (poll-new w 0 (lambda (s) (push s seen)) nil reader))
      (setf seen '())
      (write-generation w 2 :ts-base 5000)
      (multiple-value-bind (cursor restarted)
          (poll-new w 6 (lambda (s) (push s seen)) nil reader)
        (true restarted "a truncated log must be reported as a restart")
        (is = 2 cursor)
        (is equal '(1 2) (reverse seen))))))

(define-test a-message-that-landed-before-the-arm-fires-on-the-first-poll
  ;; The window between an agent draining the bus and its watch coming back up.
  ;; A message that lands in there is already on disk before anything is
  ;; watching, so a watch waiting for the log to MOVE would never see it. Arming
  ;; a reader must not quietly turn the check edge-triggered.
  ;;
  ;; A recycle window of zero puts the deadline in the past, so the loop gets
  ;; exactly one poll before it gives up. Firing inside that budget is what pins
  ;; the property; a watch that needed a second poll would return NIL here.
  (with-wal (w)
    (let ((me (agent-id "/p" :name "me"))
          (them (agent-id "/p" :name "them")))
      (append-from w 1 me)
      (append-from w 2 them)
      (is = 2 (watch-until-foreign w 1 :poll-ms 5 :recycle-seconds 0
                                       :self-id me)))))

(define-test streaming-arm-emits-a-message-that-landed-before-it
  ;; The same arm-time property for the streaming mode, which is the one the
  ;; fleet actually arms. Its first poll reads the whole log precisely so that
  ;; what is already sitting above the baseline is emitted rather than skipped
  ;; past on the way to establishing where the log ends.
  (with-wal (w)
    (let ((me (agent-id "/p" :name "me"))
          (them (agent-id "/p" :name "them"))
          (seen '()))
      (append-from w 1 me)
      (append-from w 2 them)
      (let ((final (watch-stream w 1 :poll-ms 5 :recycle-seconds 0
                                     :self-id me
                                     :emit (lambda (s) (push s seen)))))
        (is = 2 final)
        (is equal '(2) (reverse seen))))))

(define-test a-held-reader-still-finds-a-foreign-record-after-quiet-polls
  ;; A reader hands each record over exactly once, so the exit-on-event filter
  ;; sees any given record on one poll only. That is sound here — a poll that
  ;; found nothing foreign has already established there was nothing foreign
  ;; among the records it consumed — but it is sound for a reason rather than by
  ;; construction, so it is worth holding a reader across several barren polls and
  ;; checking the message that eventually arrives is still found.
  (with-wal (w)
    (let* ((me (agent-id "/p" :name "me"))
           (them (agent-id "/p" :name "them"))
           (own (encode-id me))
           (reader (make-reader)))
      (append-from w 1 me)
      (false (%highest-foreign-seq w 0 own reader))
      (false (%highest-foreign-seq w 0 own reader))   ; nothing published since
      (append-from w 2 me)
      (false (%highest-foreign-seq w 0 own reader))
      (append-from w 3 them)
      (is = 3 (%highest-foreign-seq w 0 own reader)))))

(define-test a-quiet-poll-does-not-reread-the-whole-log
  ;; The defect all of the above exists to make safe to fix. Every poll used to
  ;; read the entire history, so an idle watcher's cost tracked how much traffic
  ;; the bus had EVER carried rather than how much it was carrying now. At the
  ;; quarter-second cadence the fleet arms, across every repo at once, that was
  ;; tens of megabytes a second per watcher and a real fraction of the machine
  ;; spent on logs nobody was reading.
  ;;
  ;; Nothing about which seqs come out can catch a regression here, so this
  ;; measures instead. Allocation is the proxy: a whole-log read has to
  ;; materialise the log, so eight quiet polls consing less than ONE file's worth
  ;; is only possible if the reads are bounded. The real ratio is far wider than
  ;; the bound asserted; the bound is loose on purpose so the test measures the
  ;; defect and not the allocator.
  (with-wal (w)
    (let ((reader (make-reader))
          (body (make-string 1024 :initial-element #\z)))
      (loop for s from 1 to 400 do (append-record w s body))
      (let ((size (with-open-file (in w :element-type '(unsigned-byte 8))
                    (file-length in))))
        (poll-new w 0 nil nil reader)            ; arm: this one does read it all
        (is = size (reader-offset reader)
            "the arming read must leave the reader at the end of the log")
        (let ((before (sb-ext:get-bytes-consed)))
          (dotimes (i 8) (poll-new w 400 nil nil reader))
          (let ((consed (- (sb-ext:get-bytes-consed) before)))
            (true (< consed size)
                  "8 quiet polls consed ~:D bytes against a ~:D byte log; ~
                   re-reading the log every poll would cost at least ~:D"
                  consed size (* 8 size))))))))
