;;;; src/bus/watch.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Cross-agent bus wakeup watcher.
;;;;
;;;; An agent process only runs when its harness invokes it; between turns it is
;;;; dormant, so a message can sit unseen on the coordination bus until someone
;;;; pokes the agent. This binary closes that gap: it watches the bus write-ahead
;;;; log and turns "a new message arrived" into one of the two events a harness
;;;; can wake a dormant agent on — a background process EXITING (exit-on-event
;;;; mode) or STREAMING a line while it runs (streaming mode under a persistent
;;;; monitor).
;;;;
;;;; It reuses the canonical read-only WAL reader (`wal:scan`) as the single
;;;; source of truth for the on-disk format — it never parses frames itself — and
;;;; depends on nothing else from the bus, so the compiled binary stays small and
;;;; carries no ZeroMQ transport code.
;;;;
;;;; Self-wake is avoided without any on-disk change: the watcher seeds a BASELINE
;;;; sequence number at arm time and fires only on a strictly greater seq. The
;;;; agent re-arms the watcher AFTER it publishes, so its own just-sent message is
;;;; already in the baseline and never wakes it. Because the baseline is read at
;;;; arm time and the check is level-triggered, a message that lands between
;;;; "scan" and "first poll" is not lost.

(defpackage #:dsmr-bus-watch/src/bus/watch
  (:use #:cl)
  (:local-nicknames (#:envelope #:dsmr-mcp/src/bus/envelope)
                    (#:cursor #:dsmr-mcp/src/bus/cursor))
  (:import-from #:dsmr-mcp/src/bus/wal #:scan #:now-ms)
  (:export #:main
           #:watch-until-foreign
           #:watch-stream
           #:poll-new
           #:default-wal-path
           #:default-cursors-dir))

(in-package #:dsmr-bus-watch/src/bus/watch)

;;; -------------------------------------------------------------- default path

(defun %warn (control &rest args)
  "Write a diagnostic to *error-output*, tagged with the binary's name.
   Diagnostics never touch *standard-output*, which carries signal lines only —
   a stray line there would be read by the arm wrapper as a wake signal."
  (format *error-output* "dsmr-bus-watch: ~?~%" control args)
  (force-output *error-output*))

(defun default-wal-path ()
  "The default bus WAL path: $XDG_STATE_HOME/dsmr-mcp/bus/bus.wal (falling back
   to ~/.local/state/dsmr-mcp/bus/bus.wal). The state-root derivation is inlined
   rather than reached through the module that owns it, so this binary carries
   no ZeroMQ transport — a sister repo needs no libzmq to arm a watcher."
  (let* ((xdg (uiop:getenv "XDG_STATE_HOME"))
         (root (merge-pathnames
                "dsmr-mcp/bus/"
                (if (and xdg (plusp (length xdg)))
                    (uiop:ensure-directory-pathname xdg)
                    (merge-pathnames ".local/state/" (user-homedir-pathname))))))
    (merge-pathnames "bus.wal" root)))

(defun default-cursors-dir ()
  "The default bus cursor directory: $XDG_STATE_HOME/dsmr-mcp/bus/cursors/
   (falling back to ~/.local/state/dsmr-mcp/bus/cursors/).

   The derivation is inlined here for the same reason DEFAULT-WAL-PATH inlines
   it: reaching for the module that owns the state root would pull the ZeroMQ
   transport into a binary that sister repos must be able to run without libzmq
   installed. Two copies of a path derivation is a real cost, and it is the
   smaller one."
  (let* ((xdg (uiop:getenv "XDG_STATE_HOME"))
         (root (merge-pathnames
                "dsmr-mcp/bus/"
                (if (and xdg (plusp (length xdg)))
                    (uiop:ensure-directory-pathname xdg)
                    (merge-pathnames ".local/state/" (user-homedir-pathname))))))
    (merge-pathnames "cursors/" root)))

;;; ---------------------------------------------------------------- signalling

(defun %signal-seq (seq)
  "Emit a wake signal for SEQ on *standard-output* (the signal channel) and
   flush, so a watching harness sees it immediately."
  (format *standard-output* "bus:~D~%" seq)
  (force-output *standard-output*))

(defun %signal-recycle ()
  "Emit the idle self-recycle signal on *standard-output* and flush."
  (format *standard-output* "recycle:~%")
  (force-output *standard-output*))

;;; ----------------------------------------------------------------- the loops

(defun %last-seq (wal-path)
  "The highest committed seq in WAL-PATH, or 0 for a missing/empty/torn-only
   log. Read-only — never clips a write still in flight."
  (values (scan wal-path)))

(defun watch-until-foreign (wal-path baseline
                            &key (poll-ms 1000) (recycle-seconds 600))
  "Block until the WAL at WAL-PATH holds a record with seq strictly greater than
   BASELINE, then return that highest seq. Return NIL if the recycle window
   elapses with no such record (an idle self-recycle, so a silently-dead watch
   re-arms). Level-triggered: a qualifying record already present returns on the
   first poll. Tolerates a missing/empty WAL (baseline treated as already seen)."
  (let ((deadline (+ (now-ms) (round (* recycle-seconds 1000))))
        (sleep-s (/ poll-ms 1000.0)))
    (loop
      (let ((last (%last-seq wal-path)))
        (when (> last baseline)
          (return last)))
      (when (>= (now-ms) deadline)
        (return nil))
      (sleep sleep-s))))

(defun poll-new (wal-path cursor &optional emit)
  "One streaming step: for each seq in (CURSOR, last-committed] call EMIT (when
   supplied) with that seq, and return the new cursor (the highest committed
   seq). WAL seqs are contiguous, so this emits exactly one signal per new
   message. Pure and side-effect-free apart from EMIT — the unit tests drive it
   directly with a collecting callback."
  (let ((last (%last-seq wal-path)))
    (when (and emit (> last cursor))
      (loop for s from (1+ cursor) to last do (funcall emit s)))
    (max last cursor)))

(defun watch-stream (wal-path baseline
                     &key (poll-ms 1000) (recycle-seconds 600)
                          (emit (lambda (s) (%signal-seq s))))
  "Stream every new seq beyond BASELINE by calling EMIT once per new message,
   looping until the recycle window elapses with no further activity, then
   return the final cursor. Used by the persistent-monitor mode; EMIT defaults
   to printing the bus:<SEQ> signal line."
  (let ((cursor baseline)
        (deadline (+ (now-ms) (round (* recycle-seconds 1000))))
        (sleep-s (/ poll-ms 1000.0)))
    (loop
      (let ((advanced (poll-new wal-path cursor emit)))
        (when (> advanced cursor)
          (setf cursor advanced
                ;; activity resets the idle window
                deadline (+ (now-ms) (round (* recycle-seconds 1000))))))
      (when (>= (now-ms) deadline)
        (return cursor))
      (sleep sleep-s))))

;;; ---------------------------------------------------------------------- main

(defparameter +usage+
  "Usage: dsmr-bus-watch [options]

Watch the coordination-bus WAL and signal a new foreign message so a dormant
sister agent can be re-armed/woken. Signal lines go to STDOUT; everything else
to STDERR.

Options:
  --wal PATH           WAL file to watch (default: $XDG_STATE_HOME/dsmr-mcp/bus/bus.wal)
  --agent NAME         bus agent name to watch for (default: $DSMR_BUS_AGENT).
                       With a name resolved, the watcher arms from that agent's
                       durable cursor and ignores that agent's own publishes.
  --namespace PATH     bus namespace for the agent name. Pass the SAME project
                       root the MCP session uses: the cursor file is keyed on
                       the full <namespace>/<name> id, so a namespace that
                       differs by even a trailing component watches the wrong
                       cursor. Defaults to the working directory, with a warning.
  --agent-id FULL-ID   complete <namespace>/<name> id, for a caller that already
                       knows it. Takes precedence over --agent and --namespace.
  --cursors-dir PATH   cursor directory to read
                       (default: $XDG_STATE_HOME/dsmr-mcp/bus/cursors/)
  --after SEQ          baseline seq; fire on the first foreign seq > SEQ.
                       Overrides the cursor-derived baseline.
                       (default: the resolved agent's cursor, or the WAL's
                        current max seq when no agent resolves; 0 = fire on any
                        record)
  --stream             stream one line per new foreign seq and keep running
                       (for a persistent monitor); default is exit-on-event
  --poll-ms N          poll interval in milliseconds (default 1000)
  --recycle-seconds N  idle self-recycle window in seconds (default 600)
  -h, --help           print this help and exit

An unknown flag, or a flag with an unparseable value, is reported on STDERR and
then ignored — the watcher keeps running on defaults rather than leaving the
agent deaf to the bus.

Exit-on-event prints one `bus:<SEQ>` line then exits 0; on idle recycle it
prints `recycle:` then exits 0. Streaming prints `bus:<SEQ>` per new foreign seq.
")

(defun %usage (&optional (stream *error-output*))
  (write-string +usage+ stream)
  (force-output stream))

(defstruct (options (:conc-name opt-))
  "One parsed command line. A named record rather than a positional tuple: the
   watcher now takes ten settings, and a ten-element VALUES list is a defect
   waiting for the day someone inserts a value in the middle of it."
  (wal nil)
  (after nil)
  (agent nil)
  (namespace nil)
  (agent-id nil)
  (cursors-dir nil)
  (stream-p nil)
  (poll-ms 1000)
  (recycle-seconds 600)
  (help-p nil))

(defun %parse-nonneg (string flag)
  "STRING as a non-negative integer for FLAG, or NIL with a warning when it is
   not one. Returning NIL rather than signalling is what lets a mistyped value
   fall back to that one flag's default instead of taking the whole watcher
   down."
  (multiple-value-bind (n end)
      (ignore-errors (parse-integer string :junk-allowed nil))
    (if (and n (= end (length string)) (>= n 0))
        n
        (progn
          (%warn "~A expects a non-negative integer, got ~S; keeping the default"
                 flag string)
          nil))))

(defun %parse-args (args)
  "Parse ARGS into an OPTIONS record. Absent flags keep their defaults; WAL,
   AFTER and the identity fields stay NIL so the caller can substitute the WAL
   default, the arm-time baseline, and the environment fallback respectively.

   Parsing never signals on bad input. An unrecognized argument, a value that
   will not parse, or a value-taking flag left dangling at the end of the
   argument list is reported on *error-output* and then ignored, and parsing
   continues with what remains. This is a wake primitive, and it favors
   availability over strictness: an agent that mistypes a flag should get a
   watcher on default cadence, not silence. Refusing to start would leave the
   agent deaf to the bus with an empty stdout and nothing to say why."
  (let ((opts (make-options))
        (rest args))
    (labels ((next-value (flag)
               (if rest
                   (pop rest)
                   (progn
                     (%warn "~A requires a value but none followed; ignoring it"
                            flag)
                     nil)))
             (next-nonneg (flag current)
               (let ((raw (next-value flag)))
                 (or (and raw (%parse-nonneg raw flag)) current))))
      (loop while rest
            for arg = (pop rest)
            do (cond
                 ((or (string= arg "-h") (string= arg "--help"))
                  (setf (opt-help-p opts) t))
                 ((string= arg "--stream")
                  (setf (opt-stream-p opts) t))
                 ((string= arg "--wal")
                  (setf (opt-wal opts) (or (next-value "--wal") (opt-wal opts))))
                 ((string= arg "--agent")
                  (setf (opt-agent opts)
                        (or (next-value "--agent") (opt-agent opts))))
                 ((string= arg "--namespace")
                  (setf (opt-namespace opts)
                        (or (next-value "--namespace") (opt-namespace opts))))
                 ((string= arg "--agent-id")
                  (setf (opt-agent-id opts)
                        (or (next-value "--agent-id") (opt-agent-id opts))))
                 ((string= arg "--cursors-dir")
                  (setf (opt-cursors-dir opts)
                        (or (next-value "--cursors-dir") (opt-cursors-dir opts))))
                 ((string= arg "--after")
                  (setf (opt-after opts) (next-nonneg "--after" (opt-after opts))))
                 ((string= arg "--poll-ms")
                  (setf (opt-poll-ms opts)
                        (next-nonneg "--poll-ms" (opt-poll-ms opts))))
                 ((string= arg "--recycle-seconds")
                  (setf (opt-recycle-seconds opts)
                        (next-nonneg "--recycle-seconds" (opt-recycle-seconds opts))))
                 (t (%warn "unknown argument ~S ignored; continuing on defaults"
                           arg)))))
    opts))

(defun %env-agent-name ()
  "The DSMR_BUS_AGENT value, or NIL when unset or empty. An empty string reads
   as absent, matching the convention every other DSMR_* environment read uses."
  (let ((value (uiop:getenv "DSMR_BUS_AGENT")))
    (when (and value (plusp (length value)))
      value)))

(defun %resolve-self-id (opts)
  "The full <namespace>/<name> bus id this watcher watches on behalf of, or NIL
   when no identity resolves.

   The name comes from --agent, falling back to DSMR_BUS_AGENT — the same order
   the MCP session resolves its own name by, extended here rather than forked.
   The one rule not carried over is the ephemeral opt-out: a watcher exists to
   watch for a STABLE identity, one whose cursor outlives a restart.

   The namespace comes from --agent-id (taken whole, no construction) or
   --namespace. The working directory is a last resort and announces itself: the
   cursor file is keyed on the FULL id, so a namespace guessed from wherever the
   operator happened to be standing points at another agent's cursor or at none
   at all, and does it without a word. Construction goes through the shared
   envelope leaf, so the id this builds and the id the publisher stamps into a
   message can never drift apart."
  (let ((explicit (opt-agent-id opts)))
    (if (and explicit (plusp (length explicit)))
        explicit
        (let* ((flagged (opt-agent opts))
               (name (or (and flagged (plusp (length flagged)) flagged)
                         (%env-agent-name))))
          (when name
            (let ((namespace
                    (or (opt-namespace opts)
                        (let ((cwd (namestring (uiop:getcwd))))
                          (%warn "no --namespace given; inferring ~S from the ~
                                  working directory. It must match the project ~
                                  root the MCP session uses, or this watcher ~
                                  reads the wrong cursor."
                                 cwd)
                          cwd))))
              (envelope:agent-id namespace :name name)))))))

(defun %cursor-path (self-id cursors-dir)
  "Where SELF-ID's durable cursor lives under CURSORS-DIR. The filename is the
   encoded id, produced by the shared envelope leaf so this and the owning
   consumer name the same file byte for byte."
  (merge-pathnames (envelope:encode-id self-id)
                   (uiop:ensure-directory-pathname cursors-dir)))

(defun %cursor-holds-seq-p (path)
  "True only when PATH exists and holds a readable non-negative integer.

   The canonical cursor reader answers 0 for a file that is missing or
   unreadable. That default is right for the participant that owns the file —
   it has read nothing, so it starts at nothing — and catastrophic here, where
   the same 0 reads as an entire log's worth of pending records."
  (and (probe-file path)
       (ignore-errors
        (with-open-file (in path :if-does-not-exist nil)
          (let ((value (and in (read in nil nil))))
            (and (integerp value) (>= value 0) t))))))

(defun %cursor-baseline (self-id wal-path cursors-dir)
  "The baseline seq taken from SELF-ID's durable cursor, or NIL when that cursor
   is absent or holds nothing usable.

   Arming from the cursor rather than the log head is what closes the arm
   window. A record that landed between the agent's last drain and this arm sits
   above the cursor, so the level-triggered check fires it on the first poll
   instead of burying it under a head baseline where nothing can ever reach it.

   Answering NIL on an unusable cursor is a structural guard, not tidiness.
   Reading a missing cursor as seq 0 would make the whole log pending and fire
   the watch; the agent would then drain its REAL cursor somewhere else, leaving
   this one still reading the same empty path, still seeing 0, and firing again
   on every poll for as long as it runs. The caller arms at the head instead.

   READ-ONLY. The subscriber handle exists purely to read the value through the
   canonical reader. This binary does not own that file — the MCP session
   consuming the bus does — and writing to it from here would move that
   session's delivery position behind its back."
  (let ((path (%cursor-path self-id cursors-dir)))
    (if (%cursor-holds-seq-p path)
        (cursor:cursor-value (cursor:make-subscriber self-id wal-path path))
        (progn
          (%warn "no readable cursor for ~S at ~A; arming at the log head ~
                  instead. Check --namespace/--agent-id and --cursors-dir ~
                  against what the MCP session uses."
                 self-id (namestring path))
          nil))))

(defun %resolve-baseline (opts self-id wal-path cursors-dir)
  "The seq this watch arms at.

   An explicit --after wins outright; it is the operator's manual override and
   keeps the precedence it has always had. Otherwise a resolved identity arms
   from that agent's cursor, and everything else lands on the log head — the
   behavior from before the watcher had an identity, still correct, just unable
   to see anything that arrived before the arm."
  (or (opt-after opts)
      (and self-id (%cursor-baseline self-id wal-path cursors-dir))
      (progn
        (unless self-id
          (%warn "no agent identity resolved (pass --agent or --agent-id, or ~
                  set DSMR_BUS_AGENT); watching from the log head, with no ~
                  filter on this agent's own publishes."))
        (%last-seq wal-path))))

(defun main ()
  "Entry point. Parse argv, resolve who this watch is for, arm a baseline, and
   watch. Signal lines go to *standard-output*; usage, diagnostics, and errors
   go to *error-output*. Exit 0 on a fired/recycled watch, 64 on an
   unrecoverable failure — a bad flag is not one, and neither is an
   unresolvable identity."
  (handler-case
      (let ((opts (%parse-args (uiop:command-line-arguments))))
        (when (opt-help-p opts)
          (%usage)
          (uiop:quit 0))
        (let* ((wal-path (if (opt-wal opts) (pathname (opt-wal opts)) (default-wal-path)))
               (cursors-dir (if (opt-cursors-dir opts)
                                (uiop:ensure-directory-pathname (opt-cursors-dir opts))
                                (default-cursors-dir)))
               (self-id (%resolve-self-id opts))
               (baseline (%resolve-baseline opts self-id wal-path cursors-dir))
               (poll-ms (opt-poll-ms opts))
               (recycle-seconds (opt-recycle-seconds opts)))
          (if (opt-stream-p opts)
              (progn
                (watch-stream wal-path baseline
                              :poll-ms poll-ms :recycle-seconds recycle-seconds)
                (%signal-recycle))
              (let ((fired (watch-until-foreign wal-path baseline
                                                :poll-ms poll-ms
                                                :recycle-seconds recycle-seconds)))
                (if fired (%signal-seq fired) (%signal-recycle))))
          (uiop:quit 0)))
    (error (e)
      (format *error-output* "dsmr-bus-watch: ~A~%" e)
      (%usage)
      (uiop:quit 64))))
