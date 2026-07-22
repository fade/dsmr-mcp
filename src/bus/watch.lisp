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
;;;; It reuses the canonical read-only WAL reader as the single source of truth
;;;; for the on-disk format — it never parses frames itself — and reads the wire
;;;; envelope through the shared envelope leaf. It depends on nothing else from
;;;; the bus, so the compiled binary stays small and carries no ZeroMQ transport
;;;; code: a sister repo needs no libzmq to arm a watcher.
;;;;
;;;; WHO the watch runs for decides both of the things that make it correct.
;;;;
;;;; Self-wake is avoided by identity, not by ordering. Every published body
;;;; already carries its publisher's encoded self-id, so with an identity
;;;; resolved the watcher fires only on records that id did NOT publish — the
;;;; same encoded-against-encoded comparison the receive path makes. A message
;;;; with no self-id is a legacy un-enveloped one and counts as foreign, so a
;;;; staggered rollout drops nothing.
;;;;
;;;; The BASELINE it arms at comes from that same identity's durable cursor: the
;;;; position the agent has actually consumed to. A message that landed while
;;;; the agent was between a drain and this arm is above that cursor, so the
;;;; level-triggered check fires it on the first poll rather than burying it
;;;; under a head baseline where nothing could ever reach it. The cursor is read
;;;; and never written — the MCP session that consumes the bus owns that file.
;;;;
;;;; With no identity resolvable the watcher degrades to the log head with no
;;;; filter, fires on anything new, and says so on stderr. That is the whole of
;;;; the pre-identity behavior, kept working and made visible.

(defpackage #:dsmr-bus-watch/src/bus/watch
  (:use #:cl)
  (:local-nicknames (#:envelope #:dsmr-mcp/src/bus/envelope)
                    (#:cursor #:dsmr-mcp/src/bus/cursor)
                    (#:heartbeat #:dsmr-mcp/src/bus/heartbeat))
  (:import-from #:dsmr-mcp/src/bus/wal
                #:scan
                #:now-ms
                #:read-records
                #:record-seq
                #:record-body-string)
  ;; The heartbeat lives in a shared leaf so the name a running watch writes and
  ;; the name a --check-live probe (or the MCP core) reads stay identical byte
  ;; for byte; DEFAULT-WATCH-DIR is imported and re-exported so this package's
  ;; public surface is unchanged.
  (:import-from #:dsmr-mcp/src/bus/heartbeat
                #:default-watch-dir)
  (:export #:main
           #:watch-until-foreign
           #:watch-stream
           #:poll-new
           #:default-wal-path
           #:default-cursors-dir
           #:default-watch-dir))

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

;;; ----------------------------------------------------------------- heartbeat
;;;
;;; The heartbeat — how a running watch advertises that it is still listening,
;;; and how a probe reads that advertisement back — lives in the shared
;;; dsmr-mcp/src/bus/heartbeat leaf (reached here through the HEARTBEAT nickname).
;;; The watcher WRITES the beat and the MCP core READS it, so both sides share one
;;; implementation of the filename and format rather than each carrying a copy
;;; that could drift. The write/refresh/remove calls are wired into MAIN's poll
;;; thunk and unwind; the liveness read is what %CHECK-LIVE reports.

;;; ----------------------------------------------------------------- the loops

(defun %last-seq (wal-path)
  "The highest committed seq in WAL-PATH, or 0 for a missing/empty/torn-only
   log. Read-only — never clips a write still in flight."
  (values (scan wal-path)))

(defun %highest-foreign-seq (wal-path baseline own-encoded)
  "The highest seq above BASELINE belonging to a record this agent did not
   publish, or NIL when there is no such record.

   Without an identity this is just the log head when it exceeds BASELINE, and
   the log is never re-read past its tail. With one, the records above BASELINE
   are read and filtered, so a burst made up entirely of this agent's own
   publishes leaves the watch waiting instead of waking it up to find nothing
   addressed to it."
  (if (null own-encoded)
      (let ((last (%last-seq wal-path)))
        (and (> last baseline) last))
      (let ((highest nil))
        (dolist (record (read-records wal-path :after baseline) highest)
          (when (envelope:foreign-record-p record own-encoded)
            (setf highest (record-seq record)))))))

(defun watch-until-foreign (wal-path baseline
                            &key (poll-ms 1000) (recycle-seconds 600) self-id
                                 on-poll)
  "Block until the WAL at WAL-PATH holds a FOREIGN record with seq strictly
   greater than BASELINE, then return that highest foreign seq. Return NIL if
   the recycle window elapses with no such record (an idle self-recycle, so a
   silently-dead watch re-arms). Level-triggered: a qualifying record already
   present returns on the first poll. Tolerates a missing/empty WAL (baseline
   treated as already seen).

   SELF-ID is the full <namespace>/<name> id this watch runs for. Records
   carrying that id are this agent's own and never fire it, which is what makes
   arming independent of publish ordering. With SELF-ID NIL nothing is filtered
   and every new seq fires, the behavior from before the watcher had an
   identity.

   ON-POLL, when supplied, is a nullary thunk called at the top of every poll,
   before the fired check — so a freshly-armed watch runs it once immediately,
   with no race window, and again every poll thereafter. It is where the
   heartbeat refresh lives; keeping it out of the pure fired-check body leaves
   the loop's own logic side-effect-free and the unit tests untouched."
  (let ((deadline (+ (now-ms) (round (* recycle-seconds 1000))))
        (sleep-s (/ poll-ms 1000.0))
        (own (and self-id (envelope:encode-id self-id))))
    (loop
      (when on-poll (funcall on-poll))
      (let ((fired (%highest-foreign-seq wal-path baseline own)))
        (when fired
          (return fired)))
      (when (>= (now-ms) deadline)
        (return nil))
      (sleep sleep-s))))

(defun poll-new (wal-path cursor &optional emit self-id)
  "One streaming step: call EMIT (when supplied) once per FOREIGN record with
   seq in (CURSOR, last-committed], and return the new cursor.

   The returned cursor is the highest committed seq regardless of who published
   what, so records skipped as this agent's own are still stepped over and never
   examined twice. With SELF-ID NIL nothing is filtered and every new seq is
   emitted; WAL seqs are contiguous, so that path needs no read at all. Pure and
   side-effect-free apart from EMIT — the unit tests drive it directly with a
   collecting callback.

   SELF-ID is positional rather than a keyword only because EMIT already is:
   mixing the two lambda-list kinds is legal but draws a style warning, and the
   positional EMIT is the older contract."
  (let ((own (and self-id (envelope:encode-id self-id)))
        (last (%last-seq wal-path)))
    (when (and emit (> last cursor))
      (if (null own)
          (loop for s from (1+ cursor) to last do (funcall emit s))
          (dolist (record (read-records wal-path :after cursor))
            (when (and (<= (record-seq record) last)
                       (envelope:foreign-record-p record own))
              (funcall emit (record-seq record))))))
    (max last cursor)))

(defun watch-stream (wal-path baseline
                     &key (poll-ms 1000) (recycle-seconds 600) self-id
                          (emit (lambda (s) (%signal-seq s)))
                          on-poll)
  "Stream every new FOREIGN seq beyond BASELINE by calling EMIT once per such
   message, looping until the recycle window elapses with no further activity,
   then return the final cursor. Used by the persistent-monitor mode; EMIT
   defaults to printing the bus:<SEQ> signal line.

   SELF-ID has the same meaning it has for the exit-on-event loop: this agent's
   own publishes advance the cursor but emit nothing. The idle window resets on
   any activity, this agent's own included — the log moved, so the watch is
   demonstrably alive and has no reason to recycle.

   ON-POLL, when supplied, is a nullary thunk called at the top of every poll,
   before the advance check, on the same contract watch-until-foreign gives it:
   fired once at arm with no race window, then every poll. It carries the
   heartbeat refresh, kept out of the pure poll-new step so the streaming unit
   tests see no new behavior."
  (let ((cursor baseline)
        (deadline (+ (now-ms) (round (* recycle-seconds 1000))))
        (sleep-s (/ poll-ms 1000.0)))
    (loop
      (when on-poll (funcall on-poll))
      (let ((advanced (poll-new wal-path cursor emit self-id)))
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
  --check-live         do not watch; report the running watch's heartbeat for
                       the resolved identity and exit. Prints one line to STDOUT
                       (`live pid=<pid> age_s=<n>`, `stale pid=<pid> age_s=<n>`,
                       `dead`, or `unknown` when no identity resolves) and exits
                       0 live / 1 stale-or-dead / 2 unknown.
  --live-window-seconds N
                       how fresh a heartbeat must be to count as live under
                       --check-live (default 5). A live watch refreshes every
                       poll, so this need only exceed --poll-ms with some slack.
  -h, --help           print this help and exit

An unknown flag, or a flag with an unparseable value, is reported on STDERR and
then ignored — the watcher keeps running on defaults rather than leaving the
agent deaf to the bus.

Exit-on-event prints one `bus:<SEQ>` line then exits 0; on idle recycle it
prints `recycle:` then exits 0. Streaming prints `bus:<SEQ>` per new foreign seq.

While a watch runs it refreshes a heartbeat file every poll and removes it on
clean exit; a dead watch leaves no fresh beat. --check-live reads that beat so a
dead watch is distinguishable from a live one — the gap this closes is that a
watch which stopped listening otherwise exits identically to one that never fired.
")

(defun %usage (&optional (stream *error-output*))
  (write-string +usage+ stream)
  (force-output stream))

(defstruct (options (:conc-name opt-))
  "One parsed command line. A named record rather than a positional tuple: the
   watcher now takes a dozen settings, and a twelve-element VALUES list is a
   defect waiting for the day someone inserts a value in the middle of it."
  (wal nil)
  (after nil)
  (agent nil)
  (namespace nil)
  (agent-id nil)
  (cursors-dir nil)
  (stream-p nil)
  (poll-ms 1000)
  (recycle-seconds 600)
  (check-p nil)
  (live-window-seconds 5)
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
                 ((string= arg "--check-live")
                  (setf (opt-check-p opts) t))
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
                 ((string= arg "--live-window-seconds")
                  (setf (opt-live-window-seconds opts)
                        (next-nonneg "--live-window-seconds"
                                     (opt-live-window-seconds opts))))
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

(defun %check-live (self-id beat-path window-seconds)
  "Report the liveness of the watch for SELF-ID from its heartbeat, then exit.
   Never watches — this is the cheap probe an agent runs to answer `is my watch
   still listening?`.

   A resolved identity is what makes liveness observable at all: the beat file
   is keyed on it, exactly as the cursor is. With none there is no stable key to
   probe, so this prints `unknown` and exits 2 — honest that liveness needs the
   same resolved identity a healthy watch already runs under, not a softer
   answer that would read as `fine`.

   Otherwise it prints exactly one status line to *standard-output* — the only
   thing an agent parses — and exits 0 for a live beat, 1 for a stale or absent
   one. Any human-facing detail goes to *error-output*, never stdout."
  (if (null self-id)
      (progn
        (%warn "--check-live needs a resolved identity (pass --agent or ~
                --agent-id, or set DSMR_BUS_AGENT); cannot locate a heartbeat ~
                without one.")
        (format *standard-output* "unknown~%")
        (force-output *standard-output*)
        (uiop:quit 2))
      (multiple-value-bind (status age pid)
          (heartbeat:beat-liveness beat-path window-seconds)
        (ecase status
          (:live  (format *standard-output* "live pid=~A age_s=~A~%"
                          (or pid "?") age))
          (:stale (format *standard-output* "stale pid=~A age_s=~A~%"
                          (or pid "?") age))
          (:dead  (format *standard-output* "dead~%")))
        (force-output *standard-output*)
        (uiop:quit (if (eq status :live) 0 1)))))

(defun main ()
  "Entry point. Parse argv, resolve who this watch is for, arm a baseline, and
   watch — or, under --check-live, report the running watch's heartbeat and exit
   without watching. Signal lines go to *standard-output*; usage, diagnostics,
   and errors go to *error-output*. Exit 0 on a fired/recycled watch or a live
   heartbeat, 1 on a stale/absent heartbeat, 2 on a liveness probe with no
   resolvable identity, 64 on an unrecoverable failure — a bad flag is not one,
   and neither is an unresolvable identity for a watch.

   The heartbeat is written under the watch's own identity: while the watch runs
   it refreshes a beat file every poll, and an UNWIND-PROTECT removes that file
   on fire, recycle, AND error, so an absent beat means `not running` and a
   stale one means `died without unwinding`. With no identity resolved there is
   no stable key to write a beat under, so the watch runs without one — liveness
   observability is the one thing that requires the identity the healthy fleet
   already uses, and --check-live says so rather than pretending otherwise."
  (handler-case
      (let ((opts (%parse-args (uiop:command-line-arguments))))
        (when (opt-help-p opts)
          (%usage)
          (uiop:quit 0))
        (let* ((wal-path (if (opt-wal opts) (pathname (opt-wal opts)) (default-wal-path)))
               (cursors-dir (if (opt-cursors-dir opts)
                                (uiop:ensure-directory-pathname (opt-cursors-dir opts))
                                (default-cursors-dir)))
               (watch-dir (default-watch-dir))
               (self-id (%resolve-self-id opts))
               (beat-path (and self-id (heartbeat:beat-path self-id watch-dir))))
          (when (opt-check-p opts)
            (%check-live self-id beat-path (opt-live-window-seconds opts)))
          (let* ((baseline (%resolve-baseline opts self-id wal-path cursors-dir))
                 (poll-ms (opt-poll-ms opts))
                 (recycle-seconds (opt-recycle-seconds opts))
                 (mode (if (opt-stream-p opts) :stream :event)))
            (flet ((beat ()
                     (when beat-path
                       (heartbeat:write-beat beat-path :mode mode :baseline baseline
                                                       :poll-ms poll-ms))))
              (unwind-protect
                   (if (opt-stream-p opts)
                       (progn
                         (watch-stream wal-path baseline
                                       :poll-ms poll-ms :recycle-seconds recycle-seconds
                                       :self-id self-id :on-poll #'beat)
                         (%signal-recycle))
                       (let ((fired (watch-until-foreign wal-path baseline
                                                         :poll-ms poll-ms
                                                         :recycle-seconds recycle-seconds
                                                         :self-id self-id
                                                         :on-poll #'beat)))
                         (if fired (%signal-seq fired) (%signal-recycle))))
                (when beat-path (heartbeat:remove-beat beat-path))))
            (uiop:quit 0))))
    (error (e)
      (format *error-output* "dsmr-bus-watch: ~A~%" e)
      (%usage)
      (uiop:quit 64))))
