;;;; tests/bus/watch-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Parachute tests for the cross-agent bus wakeup watcher. The load-bearing
;;;; properties: the watcher fires on a seq strictly above its arm-time baseline
;;;; (so an agent's own just-published message, which is at-or-below the baseline
;;;; once it re-arms, never wakes it), it self-recycles to NIL when the idle
;;;; window passes with nothing new, it tolerates a missing/empty WAL, and the
;;;; streaming step emits exactly one signal per new message. The watch loop is a
;;;; named function exercised directly in-process — no subprocess, no real waiting.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/bus/watch-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/bus/watch-test
  (:use #:cl #:parachute)
  (:import-from #:dsmr-mcp/src/bus/wal
                #:scan
                #:append-record)
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
                ;; internal: argument parsing, identity resolution and baseline
                ;; arming are only observable through main otherwise, and each
                ;; carries behavior worth pinning on its own
                #:%parse-args
                #:%resolve-self-id
                #:%resolve-baseline
                #:%cursor-path
                #:opt-wal
                #:opt-after
                #:opt-agent
                #:opt-namespace
                #:opt-agent-id
                #:opt-cursors-dir
                #:opt-stream-p
                #:opt-poll-ms
                #:opt-recycle-seconds
                #:opt-help-p))

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
