;;;; tests/integration/bus/watch-integration-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Cross-process integration tests for the compiled bus-watch binary. These
;;;; spawn the REAL `bin/dsmr-bus-watch` executable against a temp WAL and assert
;;;; the property that only shows up across the process boundary an agent actually
;;;; lives behind: the binary signals a new foreign message on STDOUT and exits.
;;;;
;;;; Gated: if the binary has not been built (`make bus-watch`), the tests SKIP
;;;; cleanly rather than fail — the binary is a build artifact, not a source dep.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/integration/bus/watch-integration-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/integration/bus/watch-integration-test
  (:use #:cl #:parachute)
  (:local-nicknames (#:wal #:dsmr-mcp/src/bus/wal)
                    (#:envelope #:dsmr-mcp/src/bus/envelope)))

(in-package #:dsmr-mcp/tests/integration/bus/watch-integration-test)

;;; helpers -------------------------------------------------------------------

(defun watcher-binary ()
  "The built watcher binary path, or NIL if it has not been built."
  (let ((p (merge-pathnames "bin/dsmr-bus-watch"
                            (asdf:system-source-directory "dsmr-mcp"))))
    (when (probe-file p) p)))

(defun temp-wal ()
  (uiop:with-temporary-file (:pathname p :keep t :type "wal" :prefix "dsmr-bus-watch-it-")
    p))

(defmacro with-wal ((var) &body body)
  `(let ((,var (temp-wal)))
     (unwind-protect (progn ,@body)
       (ignore-errors (delete-file ,var)))))

(defun temp-cursors-dir ()
  "A fresh, empty cursor directory under the system temp root.

   The random state is re-seeded from the OS on every call. SBCL's default
   *RANDOM-STATE* is identical in every fresh image, so an un-seeded generator
   hands the SAME name to every run of the suite — and several cases below assert
   that a cursor is ABSENT, which one leftover directory from a previous run
   turns into a failure that reproduces only on the second run."
  (let* ((suffix (let ((*random-state* (make-random-state t)))
                   (format nil "~36R" (random (expt 36 10)))))
         (dir (merge-pathnames (format nil "dsmr-bus-watch-it-cursors-~A/" suffix)
                               (uiop:temporary-directory))))
    (ensure-directories-exist dir)
    dir))

(defmacro with-cursors-dir ((var) &body body)
  "Bind VAR to a private cursor directory, removed on unwind.

   Every identity-bearing case passes this to --cursors-dir. The binary's default
   cursor directory holds the delivery positions of the live agents on the
   machine; a test that read from there would be reading whatever the operator
   happened to be doing at the time, and a test that wrote there would move a
   running agent's delivery position behind its back."
  `(let ((,var (temp-cursors-dir)))
     (unwind-protect (progn ,@body)
       (ignore-errors (uiop:delete-directory-tree ,var :validate t)))))

(defun seed-wal (path n &optional (body "x"))
  (loop for s from 1 to n do (wal:append-record path s body)))

(defparameter *namespace* "/dsmr-bus-watch-it/project"
  "The namespace every identity in this file is built under. A fixed literal
   rather than the working directory: a cursor file is keyed on the full
   <namespace>/<name> id, so a namespace that moved with the test runner's cwd
   would name a different cursor on a different machine.")

(defun watch-id (&optional (name "primary"))
  "A full bus id, built through the shared envelope leaf — the same construction
   the publisher and the binary use, so the id seeded here and the id resolved
   there cannot drift apart."
  (envelope:agent-id *namespace* :name name))

(defun seed-cursor (dir id seq)
  "Write SEQ as ID's durable cursor under DIR.

   The filename comes from ENCODE-ID rather than a percent-encoded literal. That
   encoding is the contract between this test and the binary, and spelling it out
   by hand would leave the test passing happily against a cursor file the binary
   no longer looks for."
  (with-open-file (out (merge-pathnames (envelope:encode-id id)
                                        (uiop:ensure-directory-pathname dir))
                       :direction :output
                       :if-exists :supersede
                       :if-does-not-exist :create)
    (format out "~D~%" seq)))

(defun enveloped (publisher-id payload)
  "A real wire body published by PUBLISHER-ID, built by the shared wrap so the
   self-id field is encoded exactly as a live publisher would encode it."
  (envelope:wrap-envelope (format nil "corr-~36R" (random (expt 36 8)))
                          publisher-id
                          payload))

(defun %spawn (bin env-args args)
  "Run BIN through env(1) with ENV-ARGS applied, returning
   (values stdout stderr exit-code).

   Everything goes through env(1) because DSMR_BUS_AGENT is INHERITED. A
   developer or CI runner carrying a bus identity of their own in the environment
   would otherwise hand it to a child that is asserting what happens with no
   identity, or with a different one, and the case would pass or fail on whose
   shell started it. Setting the variable on the test process itself is not an
   alternative: that leaks into every case that runs after it."
  (uiop:run-program (append (list "env") env-args (list (namestring bin)) args)
                    :output '(:string :stripped t)
                    :error-output '(:string :stripped t)
                    :ignore-error-status t))

(defun run-watcher (bin &rest args)
  "Run BIN with ARGS synchronously and NO ambient bus identity, returning
   (values stdout stderr exit-code)."
  (%spawn bin (list "-u" "DSMR_BUS_AGENT") args))

(defun run-watcher-as (bin agent-name &rest args)
  "Run BIN with ARGS and DSMR_BUS_AGENT set to AGENT-NAME for the CHILD only."
  (%spawn bin (list (format nil "DSMR_BUS_AGENT=~A" agent-name)) args))

(defun run-watcher-on-growing-wal (bin wal &rest args)
  "Launch BIN with ARGS and no ambient identity, append a short series of records
   to WAL while it runs, and return (values stdout stderr exit-code).

   With no identity the watch arms at the log head AS IT STANDS AT ARM TIME, so
   a record can only fire it by landing after the process is up. Appending a
   series rather than a single record is what takes the startup race out of it:
   wherever in the series the arm lands, records above it still follow. The loop
   stops as soon as the watcher exits, so the log stays contiguous."
  (let ((p (uiop:launch-program
            (append (list "env" "-u" "DSMR_BUS_AGENT" (namestring bin)) args)
            :output :stream :error-output :stream)))
    (loop for s from 1 to 6
          while (uiop:process-alive-p p)
          do (sleep 0.2)
             (wal:append-record wal s "a message from a sister agent"))
    (let ((code (uiop:wait-process p)))
      (values (uiop:slurp-stream-string (uiop:process-info-output p))
              (uiop:slurp-stream-string (uiop:process-info-error-output p))
              code))))

(defun fast-watch-args (wal cursors)
  "The --wal/--cursors-dir/cadence arguments the identity-bearing cases share.
   The cadence is deliberately tight: a case that must NOT fire has to sit
   through its whole recycle window before it can be believed, so that window is
   one second."
  (list "--wal" (namestring wal)
        "--cursors-dir" (namestring cursors)
        "--poll-ms" "50"
        "--recycle-seconds" "1"))

;;; tests ---------------------------------------------------------------------

(define-test exit-on-event-signals-new-seq-and-exits-zero
  (let ((bin (watcher-binary)))
    (if (null bin)
        (skip ("dsmr-bus-watch not built; run 'make bus-watch' to enable this test"))
        (with-wal (w)
          ;; baseline = 3; a record at seq 4 is already present, so the watcher
          ;; fires on its first poll and exits — deterministic, no timing race.
          (seed-wal w 4)
          (multiple-value-bind (out err code)
              (run-watcher bin "--wal" (namestring w)
                           "--after" "3" "--poll-ms" "50" "--recycle-seconds" "10")
            (declare (ignore err))
            (is = 0 code)
            (true (search "bus:4" out)))))))

(define-test idle-watch-self-recycles-and-exits-zero
  (let ((bin (watcher-binary)))
    (if (null bin)
        (skip ("dsmr-bus-watch not built; run 'make bus-watch' to enable this test"))
        (with-wal (w)
          ;; baseline at the current max (3) with nothing newer: the watcher must
          ;; self-recycle within the window and exit 0 with a recycle: line.
          (seed-wal w 3)
          (multiple-value-bind (out err code)
              (run-watcher bin "--wal" (namestring w)
                           "--after" "3" "--poll-ms" "50" "--recycle-seconds" "1")
            (declare (ignore err))
            (is = 0 code)
            (true (search "recycle:" out)))))))

(define-test agent-flag-is-a-recognized-argument
  "--agent and --namespace are accepted, not swallowed by the unknown-argument
   path. Worth its own case because an unknown flag is only WARNED about: a
   watcher started with a name it silently ignored looks exactly like a healthy
   one on stdout, and differs only in that it is watching the wrong thing."
  (let ((bin (watcher-binary)))
    (if (null bin)
        (skip ("dsmr-bus-watch not built; run 'make bus-watch' to enable this test"))
        (with-wal (w)
          (with-cursors-dir (c)
            (let ((id (watch-id)))
              (seed-wal w 4)
              (seed-cursor c id 2)
              (multiple-value-bind (out err code)
                  (apply #'run-watcher bin
                         (append (fast-watch-args w c)
                                 (list "--agent" "primary"
                                       "--namespace" *namespace*)))
                (is = 0 code)
                (false (search "unknown argument" err))
                ;; the name was not merely tolerated — it resolved, and the watch
                ;; armed from THAT id's cursor rather than the log head.
                (true (search "bus:4" out)))))))))

(define-test agent-name-falls-back-to-the-environment
  "With no --agent, the name comes from DSMR_BUS_AGENT in the child's environment
   and resolves to the same full id."
  (let ((bin (watcher-binary)))
    (if (null bin)
        (skip ("dsmr-bus-watch not built; run 'make bus-watch' to enable this test"))
        (with-wal (w)
          (with-cursors-dir (c)
            (seed-wal w 3)
            (multiple-value-bind (out err code)
                (apply #'run-watcher-as bin "primary"
                       (append (fast-watch-args w c)
                               (list "--namespace" *namespace*)))
              (declare (ignore out))
              (is = 0 code)
              ;; the cursor directory is empty, so the binary names the id it
              ;; resolved while reporting the miss — the observable that proves
              ;; the environment fallback ran, and what it produced.
              (true (search (watch-id) err))))))))

(define-test cursor-derived-baseline-fires-on-a-pending-record
  "A record that landed while the agent was dormant sits above that agent's
   durable cursor, so the watch arms below it and fires on the first poll. This
   is the whole point of arming from the cursor: at the log head the same record
   would be buried where nothing could ever reach it."
  (let ((bin (watcher-binary)))
    (if (null bin)
        (skip ("dsmr-bus-watch not built; run 'make bus-watch' to enable this test"))
        (with-wal (w)
          (with-cursors-dir (c)
            (let ((id (watch-id)))
              (seed-wal w 10)
              (seed-cursor c id 5)
              (multiple-value-bind (out err code)
                  (apply #'run-watcher bin
                         (append (fast-watch-args w c)
                                 (list "--agent" "primary"
                                       "--namespace" *namespace*)))
                (declare (ignore err))
                (is = 0 code)
                (true (search "bus:10" out))
                (false (search "recycle:" out)))))))))

(define-test current-cursor-leaves-the-watch-idle
  "A cursor level with the log head means the agent has consumed everything, so
   the same fixture must NOT fire."
  (let ((bin (watcher-binary)))
    (if (null bin)
        (skip ("dsmr-bus-watch not built; run 'make bus-watch' to enable this test"))
        (with-wal (w)
          (with-cursors-dir (c)
            (let ((id (watch-id)))
              (seed-wal w 10)
              (seed-cursor c id 10)
              (multiple-value-bind (out err code)
                  (apply #'run-watcher bin
                         (append (fast-watch-args w c)
                                 (list "--agent" "primary"
                                       "--namespace" *namespace*)))
                (declare (ignore err))
                (is = 0 code)
                (true (search "recycle:" out))
                (false (search "bus:" out)))))))))

(define-test own-publishes-do-not-fire-the-watch
  "Records above the cursor that this agent published itself are not news to it.
   Without the self-id filter an agent that publishes and then re-arms wakes
   itself immediately, every time, and the wake carries nothing to act on."
  (let ((bin (watcher-binary)))
    (if (null bin)
        (skip ("dsmr-bus-watch not built; run 'make bus-watch' to enable this test"))
        (with-wal (w)
          (with-cursors-dir (c)
            (let ((id (watch-id)))
              (seed-wal w 5)
              (loop for s from 6 to 10
                    do (wal:append-record w s (enveloped id "my own publish")))
              (seed-cursor c id 5)
              (multiple-value-bind (out err code)
                  (apply #'run-watcher bin
                         (append (fast-watch-args w c)
                                 (list "--agent" "primary"
                                       "--namespace" *namespace*)))
                (declare (ignore err))
                (is = 0 code)
                (true (search "recycle:" out))
                (false (search "bus:" out)))))))))

(define-test a-foreign-record-among-own-publishes-fires
  "One sister agent's message inside a burst of this agent's own publishes still
   fires the watch, and fires it at that message's seq — the filter drops this
   agent's records, it does not stop reading at the first one."
  (let ((bin (watcher-binary)))
    (if (null bin)
        (skip ("dsmr-bus-watch not built; run 'make bus-watch' to enable this test"))
        (with-wal (w)
          (with-cursors-dir (c)
            (let ((id (watch-id))
                  (sister (watch-id "sister")))
              (seed-wal w 5)
              (loop for s from 6 to 10
                    do (wal:append-record
                        w s
                        (if (= s 8)
                            (enveloped sister "from a sister agent")
                            (enveloped id "my own publish"))))
              (seed-cursor c id 5)
              (multiple-value-bind (out err code)
                  (apply #'run-watcher bin
                         (append (fast-watch-args w c)
                                 (list "--agent" "primary"
                                       "--namespace" *namespace*)))
                (declare (ignore err))
                (is = 0 code)
                ;; seq 8 specifically: 9 and 10 are this agent's own and must not
                ;; be what the wake reports.
                (true (search "bus:8" out)))))))))

(define-test legacy-unenveloped-record-counts-as-foreign
  "A body with no envelope delimiters comes from a publisher that predates the
   wire envelope. It has no self-id to match, and treating that as this agent's
   own would drop real traffic on the floor for the length of a staggered
   rollout — so it counts as foreign and it fires."
  (let ((bin (watcher-binary)))
    (if (null bin)
        (skip ("dsmr-bus-watch not built; run 'make bus-watch' to enable this test"))
        (with-wal (w)
          (with-cursors-dir (c)
            (let ((id (watch-id)))
              (seed-wal w 5)
              (loop for s from 6 to 10
                    do (wal:append-record
                        w s
                        (if (= s 9)
                            "an old-core body with no envelope"
                            (enveloped id "my own publish"))))
              (seed-cursor c id 5)
              (multiple-value-bind (out err code)
                  (apply #'run-watcher bin
                         (append (fast-watch-args w c)
                                 (list "--agent" "primary"
                                       "--namespace" *namespace*)))
                (declare (ignore err))
                (is = 0 code)
                (true (search "bus:9" out)))))))))

(define-test unknown-flag-degrades-to-a-running-watch
  "A mistyped flag must cost the agent that one setting, not the bus. Refusing to
   start would leave it deaf with an empty stdout and nothing to say why, so the
   flag is reported on stderr and the watch runs."
  (let ((bin (watcher-binary)))
    (if (null bin)
        (skip ("dsmr-bus-watch not built; run 'make bus-watch' to enable this test"))
        (with-wal (w)
          (with-cursors-dir (c)
            (let ((id (watch-id)))
              (seed-wal w 4)
              (seed-cursor c id 3)
              (multiple-value-bind (out err code)
                  (apply #'run-watcher bin
                         (append (fast-watch-args w c)
                                 (list "--bogus"
                                       "--agent" "primary"
                                       "--namespace" *namespace*)))
                (is = 0 code)
                (isnt = 64 code)
                (false (zerop (length out)))
                (true (search "bus:4" out))
                (true (search "--bogus" err)))))))))

(define-test unparseable-flag-value-degrades-to-the-default
  "A value that will not parse falls back to that one flag's default rather than
   taking the watcher down with it."
  (let ((bin (watcher-binary)))
    (if (null bin)
        (skip ("dsmr-bus-watch not built; run 'make bus-watch' to enable this test"))
        (with-wal (w)
          (with-cursors-dir (c)
            (let ((id (watch-id)))
              (seed-wal w 4)
              (seed-cursor c id 3)
              (multiple-value-bind (out err code)
                  (run-watcher bin
                               "--wal" (namestring w)
                               "--cursors-dir" (namestring c)
                               "--poll-ms" "banana"
                               "--recycle-seconds" "1"
                               "--agent" "primary"
                               "--namespace" *namespace*)
                (is = 0 code)
                (isnt = 64 code)
                (true (search "--poll-ms" err))
                (true (search "bus:4" out)))))))))

(define-test absent-cursor-arms-at-head-not-zero
  "An identity with no cursor file arms at the log head, NOT at zero.

   Reading a missing cursor as seq 0 would make an entire log pending and fire
   the watch at once. The agent would then drain its real cursor somewhere else,
   leaving this watch still reading the same empty path, still seeing 0, and
   firing again on every poll for as long as it ran. The second run is what
   proves the difference: an armed-at-zero watcher fires identically every time
   it starts."
  (let ((bin (watcher-binary)))
    (if (null bin)
        (skip ("dsmr-bus-watch not built; run 'make bus-watch' to enable this test"))
        (with-wal (w)
          (with-cursors-dir (c)
            (seed-wal w 10)
            (let ((args (append (fast-watch-args w c)
                                (list "--agent" "primary"
                                      "--namespace" *namespace*))))
              (multiple-value-bind (out err code) (apply #'run-watcher bin args)
                (is = 0 code)
                (false (search "bus:" out))
                (true (search "recycle:" out))
                (true (search "no readable cursor" err)))
              ;; unchanged fixture, second arm: still nothing to report.
              (multiple-value-bind (out err code) (apply #'run-watcher bin args)
                (declare (ignore err))
                (is = 0 code)
                (false (search "bus:" out))
                (true (search "recycle:" out)))))))))

(define-test no-identity-degrades-to-head-baseline
  "With neither --agent nor DSMR_BUS_AGENT the watcher keeps the behavior it had
   before it had an identity: it arms at the log head, filters nothing, and fires
   on anything new — while saying on stderr that it is running blind, because a
   watcher that cannot recognize its own publishes will wake its agent on them."
  (let ((bin (watcher-binary)))
    (if (null bin)
        (skip ("dsmr-bus-watch not built; run 'make bus-watch' to enable this test"))
        (with-wal (w)
          (with-cursors-dir (c)
            ;; start from an empty log so the head baseline is 0 and every record
            ;; the appender adds while the watch runs is above it.
            (ignore-errors (delete-file w))
            (multiple-value-bind (out err code)
                (run-watcher-on-growing-wal bin w
                                            "--wal" (namestring w)
                                            "--cursors-dir" (namestring c)
                                            "--poll-ms" "50"
                                            "--recycle-seconds" "10")
              (is = 0 code)
              (true (search "bus:" out))
              (true (search "no agent identity resolved" err))))))))

(define-test streaming-signals-on-stdout-and-recycles-to-stderr
  "Streaming mode keeps STDOUT clean for the persistent monitor: it prints only
   `bus:<SEQ>` there, and routes its idle self-recycle notice to STDERR. The
   exit-on-event mode still prints `recycle:` on stdout (a separate documented
   contract); this guards that streaming does not, so a monitor reading each
   stdout line never mistakes a recycle for a wake."
  (let ((bin (watcher-binary)))
    (if (null bin)
        (skip ("dsmr-bus-watch not built; run 'make bus-watch' to enable this test"))
        (progn
          ;; (a) idle WAL: streaming self-recycles by exiting 0, and its recycle
          ;; notice lands on STDERR, never STDOUT.
          (with-wal (w)
            (seed-wal w 3)
            (multiple-value-bind (out err code)
                (run-watcher bin "--stream"
                             "--wal" (namestring w)
                             "--after" "3"
                             "--poll-ms" "50"
                             "--recycle-seconds" "1")
              (is = 0 code)
              (false (search "recycle:" out))
              (true (search "recycle:" err))))
          ;; (b) growing WAL: each new foreign seq is signalled on STDOUT.
          (with-wal (w)
            (ignore-errors (delete-file w))
            (multiple-value-bind (out err code)
                (run-watcher-on-growing-wal bin w
                                            "--stream"
                                            "--wal" (namestring w)
                                            "--poll-ms" "50"
                                            "--recycle-seconds" "2")
              (declare (ignore err))
              (is = 0 code)
              (true (search "bus:" out))))))))
