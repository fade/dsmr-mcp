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
;;;; The streaming line carries those decoded publishers rather than throwing
;;;; them away. Deciding a record is foreign already establishes who wrote it,
;;;; and a line that named only a seq left the woken agent to spend a turn and a
;;;; bus fetch recovering it. The seq stays at the front of the line, because
;;;; watchers armed across the fleet filter this stream on that prefix and are
;;;; not restarted when this binary changes.
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

;; The detached mode claims its pid file with a POSIX record lock and signals
;; the watcher it reaps, and both are reached through sb-posix. The heartbeat
;; leaf already requires it; requiring it here too keeps this file honest about
;; what it uses rather than relying on load order.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-posix))

(defpackage #:dsmr-bus-watch/src/bus/watch
  (:use #:cl)
  (:local-nicknames (#:envelope #:dsmr-mcp/src/bus/envelope)
                    (#:cursor #:dsmr-mcp/src/bus/cursor)
                    (#:heartbeat #:dsmr-mcp/src/bus/heartbeat)
                    (#:wal #:dsmr-mcp/src/bus/wal)
                    (#:selector #:dsmr-mcp/src/bus/selector))
  (:import-from #:dsmr-mcp/src/bus/wal
                #:scan
                #:now-ms
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
           #:poll-new-records
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

(defun default-wal-path (&optional bus)
  "The bus write-ahead log: bus.wal under the state root for BUS, or under the
   unnamed root when BUS is nil.

   The root comes from the shared selector leaf, which imports nothing beyond cl
   and uiop. That is what keeps this binary free of the ZeroMQ transport, so a
   sister repo needs no libzmq to arm a watcher."
  (merge-pathnames "bus.wal" (selector:bus-root bus)))

(defun default-cursors-dir (&optional bus)
  "The bus cursor directory: cursors/ under the state root for BUS, or under the
   unnamed root when BUS is nil.

   The root comes from the shared selector leaf, which imports nothing beyond cl
   and uiop. That is what keeps this binary free of the ZeroMQ transport, so a
   sister repo needs no libzmq to arm a watcher."
  (merge-pathnames "cursors/" (selector:bus-root bus)))

;;; ---------------------------------------------------------------- signalling

(defun %field-token (name)
  "NAME rendered safe to carry as one field on a signal line: whitespace, a
   comma, an equals sign and any control character each become an underscore.

   A bus name is an ordinary bare word and passes through untouched. A namespace
   is a project root, though, and a path carrying a space would otherwise split
   one name across two fields and make the line lie about who published. The
   comma separates names within a field and the equals sign introduces one, so
   neither can be allowed to occur inside a name either."
  (map 'string
       (lambda (ch)
         (if (or (char<= ch #\Space) (char= ch #\,) (char= ch #\=))
             #\_
             ch))
       name))

(defun %signal-line (seq froms tos)
  "The text of one wake: `bus:<SEQ>`, then `from=` naming every agent that
   published a record in the batch, then `to=` when any of those records named a
   recipient.

   The seq comes first and the prefix is untouched. Watchers armed across the
   fleet filter this stream through ^(bus|error): and read the number after the
   colon, so anything added has to arrive AFTER the seq: a field in front of it,
   or a different prefix, silently deafens every watcher already running.

   FROMS is a list because one poll can turn up several records from several
   publishers. Naming one of them would present a batch as though it were a
   single message, which is precisely the misattribution the author field exists
   to prevent, so all of them are named.

   TOS is omitted entirely when nothing in the batch was addressed. An empty
   `to=` would read as a recipient whose name failed to render, and a reader
   cannot tell that from a broadcast. Note that a mixed batch carries both kinds:
   the recipients named are the ones some record named, never a claim about the
   whole batch."
  (with-output-to-string (line)
    (format line "bus:~D" seq)
    (when froms (format line " from=~{~A~^,~}" froms))
    (when tos (format line " to=~{~A~^,~}" tos))))

(defun %signal-seq (seq &optional froms tos)
  "Emit a wake signal for SEQ on *standard-output* (the signal channel) and
   flush, so a watching harness sees it immediately.

   The line says CHECK THE BUS, not A MESSAGE WITH THIS SEQ IS WAITING. The
   reader re-checks what is actually pending and drains all of it, so in
   streaming mode SEQ is the highest seq the emitting poll turned up and the
   records below it in the same batch get no line of their own. Consecutive
   lines may therefore skip sequence numbers; a gap is normal and never a
   dropped record.

   FROMS and TOS name the agents the batch came from and, where a record said
   so, the agent it was for. They are what stops the woken reader spending a
   turn establishing something the watch already knew: the watch decodes every
   publisher's id to decide the record is not its own, and used to throw that
   answer away. Both are absent on the exit-on-event path, which prints the seq
   alone exactly as it always has."
  (format *standard-output* "~A~%" (%signal-line seq froms tos))
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
   log. Read-only — never clips a write still in flight.

   This is the whole-log question and it costs the whole log to answer, which is
   the right price ONCE, at arm time, where the watcher needs a head to arm
   against and holds no position yet. It is deliberately not on the poll path:
   the loops below ask the same question several times a second for the life of
   the process, and they ask it of %POLL-FORWARD, which answers from the bytes
   appended since the previous look."
  (values (scan wal-path)))

(defun %poll-forward (wal-path reader after)
  "One bounded look at WAL-PATH on behalf of READER. Returns (values records
   last-seq restarted-p): the good records with seq > AFTER that READER has not
   already accounted for, oldest first; the log's highest committed seq; and
   whether the read fell back to the head of the file.

   READER carries the byte offset the previous look stopped at, so a quiet poll
   costs the 24-byte prefix that re-identifies the record behind that offset plus
   whatever has been appended since — not the whole history. Every guarantee the
   whole-log read makes still holds, because this is the whole-log read's own
   machinery: each record is CRC-verified on the read that first hands it over,
   the seq column is asserted contiguous across the incremental join, and a torn
   tail stops the read cleanly and is picked up once the record completes.

   A failed re-identification means the log on disk is no longer the log READER
   was reading. Rotation empties the active log and the next broker numbers from
   1 again, so a seq carried over from the old log names nothing here and would
   filter out every record in the new one — a watch that looks healthy and hears
   nothing. The recovery is therefore to re-read this log from its head with no
   floor at all, and to say so through RESTARTED-P so the caller drops the
   position it was holding. The retry cannot itself restart: READER's offset is
   zero going into it."
  (multiple-value-bind (records restarted)
      (wal:read-forward wal-path reader :after after)
    (if restarted
        (progn
          (wal:reset-reader reader)
          (let ((from-head (wal:read-forward wal-path reader :after 0)))
            (values from-head (wal:reader-last-seq reader) t)))
        (values records (wal:reader-last-seq reader) nil))))

(defun %highest-foreign-seq (wal-path baseline own-encoded
                             &optional (reader (wal:make-reader)))
  "The highest seq above BASELINE belonging to a record this agent would
   actually be handed, or NIL when there is no such record. Returns (values seq
   last-seq restarted-p).

   Without an identity this is just the log head when it exceeds BASELINE. With
   one, the records above BASELINE are read and filtered, so a burst made up
   entirely of this agent's own publishes leaves the watch waiting instead of
   waking it up to find nothing addressed to it.

   The filter asks the SAME question delivery asks, which is now two questions
   rather than one: the record must not be this agent's own publish, and it must
   not be mail naming somebody else. A watcher armed for one agent used to fire
   on a message addressed to another, waking that agent to read a bus that would
   then show it nothing. That is a spurious wake and never a missed one, so it is
   safe rather than dangerous, but a spurious wake costs a whole context window,
   which is the scarce resource in this system.

   Note that this binary deploys separately from the core that publishes for it
   (make install-bus-watch, not make core), so during a staggered rollout a
   watcher still on the old build wakes on addressed mail it will not be shown.
   The failure mode there is extra wakes, never silence, which is the direction
   this component must always fail in: an over-eager watch costs context, and a
   silent one costs messages.

   READER is the caller's position in the log. A caller that supplies one and
   keeps it across polls pays for the tail; the default is a throwaway reader,
   which reads the whole log exactly as this did before it took a position — the
   behavior every one-shot caller and every existing test sees. Handing back a
   record only once is sound for this question because a poll that found no
   foreign record has already established there was none among the records it
   consumed.

   After a restart the log has been rotated or truncated and BASELINE belongs to
   a numbering that no longer applies, so the floor for this look is the head of
   the new log rather than a seq from the old one."
  (multiple-value-bind (records last restarted)
      (%poll-forward wal-path reader baseline)
    (let ((floor (if restarted 0 baseline)))
      (values (if (null own-encoded)
                  (and (> last floor) last)
                  (let ((highest nil))
                    (dolist (record records highest)
                      (when (envelope:deliverable-record-p record own-encoded)
                        (setf highest (record-seq record))))))
              last
              restarted))))

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
   the loop's own logic side-effect-free and the unit tests untouched.

   One reader is held for the life of the watch. The first poll still reads the
   whole log — that is what establishes where the log currently ends, and it is
   also what makes the arm level-triggered — and every poll after it reads only
   what has been appended since. An idle watch therefore costs a fixed handful of
   bytes per poll instead of the entire history, which at a quarter-second cadence
   is the difference between a background process and a busy core."
  (let ((deadline (+ (now-ms) (round (* recycle-seconds 1000))))
        (sleep-s (/ poll-ms 1000.0))
        (own (and self-id (envelope:encode-id self-id)))
        (reader (wal:make-reader))
        (floor baseline))
    (loop
      (when on-poll (funcall on-poll))
      (multiple-value-bind (fired last restarted)
          (%highest-foreign-seq wal-path floor own reader)
        (declare (ignore last))
        (when restarted
          (setf floor 0)
          (%warn "wal rotated or truncated under the watch; re-armed at the head of the new log"))
        (when fired
          (return fired)))
      (when (>= (now-ms) deadline)
        (return nil))
      (sleep sleep-s))))

(defun %batch-parties (records own-namespace)
  "Who RECORDS came from, and who any of them was for: two lists of line-safe
   tokens, each holding distinct names in the order the batch first mentions
   them. OWN-NAMESPACE is the reading agent's namespace, which is what decides
   whether a sender is rendered as a bare name or as name@namespace.

   Every one of these ids was already decoded on the way to deciding the record
   was deliverable. This reads the answer out of the same envelope instead of
   discarding it and leaving the woken agent to fetch the message back to learn
   who sent it, a whole turn spent recovering something the watch held.

   A publisher that cannot be named renders as \"unknown\", the same string the
   delivery path shows for the same record: an un-enveloped message from an older
   core, or an id that will not decode. Failing to name an author must never
   withhold the wake."
  (let ((froms '())
        (tos '()))
    (dolist (record records (values (nreverse froms) (nreverse tos)))
      (multiple-value-bind (text correlation-id self-id addressee)
          (envelope:decode-envelope (record-body-string record))
        (declare (ignore text correlation-id))
        (pushnew (%field-token (envelope:author-display self-id own-namespace))
                 froms :test #'string=)
        (when addressee
          (pushnew (%field-token (envelope:author-display addressee own-namespace))
                   tos :test #'string=))))))

(defun poll-new-records (wal-path cursor self-id
                         &optional (reader (wal:make-reader)))
  "One streaming step, kept as records: the records with seq in (CURSOR,
   last-committed] that this agent would actually be handed, oldest first.
   Returns (values records new-cursor restarted-p).

   This is the whole of POLL-NEW's work; POLL-NEW is now this function with the
   records reduced to their seqs on the way out. Keeping them is what lets the
   streaming loop say who published, since the envelope it would have to re-open
   to find out has already been opened here.

   The returned cursor is the highest committed seq regardless of who published
   what, so a record withheld under either delivery condition is still stepped
   over and never examined twice. Withholding must never hold the cursor back, or
   the log pins at the first record this agent is not shown. With SELF-ID NIL
   nothing is filtered and every record comes back.

   RESTARTED-P is true when the log was rotated or truncated under the reader.
   The cursor returned in that case is the new log's head rather than the old
   cursor carried forward, because the two number different logs and keeping the
   larger would leave this watch permanently above every record the new log can
   produce."
  (let ((own (and self-id (envelope:encode-id self-id))))
    (multiple-value-bind (records last restarted)
        (%poll-forward wal-path reader cursor)
      (values (if (null own)
                  records
                  (remove-if-not (lambda (record)
                                   (envelope:deliverable-record-p record own))
                                 records))
              (if restarted last (max last cursor))
              restarted))))

(defun poll-new (wal-path cursor &optional emit self-id
                                           (reader (wal:make-reader)))
  "One streaming step: call EMIT (when supplied) once per record with seq in
   (CURSOR, last-committed] that this agent would actually be handed, and return
   (values new-cursor restarted-p).

   The filter asks the SAME question delivery asks, which is two questions
   rather than one: the record must not be this agent's own publish, and it must
   not be mail naming somebody else. Streaming is the mode a fleet actually
   arms, so a watch that emitted for another agent's mail woke a sister to read
   a bus that then showed it nothing, and a spurious wake costs a whole context
   window.

   The returned cursor is the highest committed seq regardless of who published
   what, so a record withheld under either condition is still stepped over and
   never examined twice. Withholding an emit must never hold the cursor back, or
   the log pins at the first record this agent is not shown. With SELF-ID NIL
   nothing is filtered and every new seq is emitted. Pure and side-effect-free
   apart from EMIT, so the unit tests drive it directly with a collecting
   callback.

   READER is the caller's position in the log; supplying one and keeping it
   across calls is what makes a quiet poll cost the tail rather than the whole
   history. The default is a throwaway reader, which reads the whole log, which
   is what every one-shot caller wants and what this did before it took a
   position.

   The records and the head seq come out of ONE read rather than a scan followed
   by a separate replay. That closes a small race as a side effect: a record
   appended between those two reads used to be visible to the replay but above
   the cursor the scan had just fixed, and had to be filtered back out to avoid
   returning a cursor that skipped it. One read cannot disagree with itself.

   RESTARTED-P is true when the log was rotated or truncated under the reader.
   The cursor returned in that case is the new log's head, not the old cursor
   carried forward, because the two number different logs and keeping the larger
   would leave this watch permanently above every record the new log can produce.

   This is the seq-only view of POLL-NEW-RECORDS, which is where the step itself
   now lives. Callers that need the records themselves, such as anything that
   has to name the agent a record came from, take them from there rather than
   reopening the envelope this already decoded."
  (multiple-value-bind (records new-cursor restarted)
      (poll-new-records wal-path cursor self-id reader)
    (when emit
      (dolist (record records)
        (funcall emit (record-seq record))))
    (values new-cursor restarted)))

(defun watch-stream
       (wal-path baseline
        &key (poll-ms 1000) (recycle-seconds 600) self-id
        (emit (lambda (seq froms tos) (%signal-seq seq froms tos))) on-poll)
  "Stream new FOREIGN activity beyond BASELINE by calling EMIT at most ONCE per
   poll, looping until the recycle window elapses with no further activity, then
   return the final cursor. Used by the persistent-monitor mode; EMIT defaults to
   printing the signal line.

   EMIT is called with three arguments: the highest foreign seq that poll turned
   up, the distinct agents that published the poll's records, and the distinct
   agents any of those records were addressed to (empty when none of them named
   anybody). The identities cost nothing to report, since the loop decodes each
   publisher's id to decide the record is not its own, and reporting them is
   what saves the woken reader a turn spent rediscovering an author this loop
   already had in hand.

   One wake per poll batch, not one per record. The reader on the other end of
   the signal drains everything pending in a single call, so when several
   records land between two polls only the first wake has anything to deliver
   and the rest wake an agent to discover the work is already done. Each of
   those costs an agent turn, which is the scarce resource here. It also means
   the batch is genuinely plural and its authorship with it, which is why the
   agents are reported as a list rather than as a sender.

   A wake therefore means CHECK THE BUS, never THERE IS EXACTLY ONE MESSAGE
   WAITING. The reader must re-check what is actually pending rather than trust
   the signal to describe it, the same discipline a POSIX condition variable
   mandates for the same reason. A consequence worth stating plainly: consecutive
   bus:<SEQ> lines may SKIP sequence numbers, so anything parsing them has to
   expect gaps and must not treat a gap as a lost record.

   The coalescing happens here rather than in the poll step, which stays a pure
   enumerator: this loop takes the batch and calls the real EMIT once. Nothing is
   remembered between polls, so there is no timer and no debounce window and
   hence none of the lost-wakeup failures those bring. A record appended after a
   poll's read is simply picked up by the next poll, and the cursor advances to
   the head of each read regardless of what was emitted, exactly as before.

   SELF-ID has the same meaning it has for the exit-on-event loop: this agent's
   own publishes advance the cursor but emit nothing. The idle window resets on
   any activity, this agent's own included — the log moved, so the watch is
   demonstrably alive and has no reason to recycle. It also fixes the namespace
   the reported agents are rendered against, so a sister in this agent's own
   project is named plainly and one from another project carries where it is
   from.

   ON-POLL, when supplied, is a nullary thunk called at the top of every poll,
   before the advance check, on the same contract watch-until-foreign gives it:
   fired once at arm with no race window, then every poll. It carries the
   heartbeat refresh, kept out of the pure poll step so the streaming unit tests
   see no new behavior.

   One reader is held for the life of the stream, so a quiet poll reads the bytes
   appended since the last one rather than the whole log. This is the loop that
   made idle watchers expensive: it is the mode the fleet arms, at a
   quarter-second cadence, in every repo at once.

   A rotation counts as activity and resets the idle window. The log demonstrably
   moved, and the cursor moving DOWN to the new log's head is exactly the case a
   plain advance test would read as no activity at all."
  (let ((cursor baseline)
        (deadline (+ (now-ms) (round (* recycle-seconds 1000))))
        (sleep-s (/ poll-ms 1000.0))
        (own-namespace (and self-id
                            (nth-value 0 (envelope:split-agent-id self-id))))
        (reader (wal:make-reader)))
    (loop (when on-poll (funcall on-poll))
          (multiple-value-bind (records advanced restarted)
              (poll-new-records wal-path cursor self-id reader)
            (when restarted
              (%warn
               "wal rotated or truncated under the watch; streaming from the head of the new log"))
            (when (or restarted (> advanced cursor))
              (setf cursor advanced
                    deadline (+ (now-ms) (round (* recycle-seconds 1000)))))
            (when (and emit records)
              (multiple-value-bind (froms tos)
                  (%batch-parties records own-namespace)
                (funcall emit (reduce #'max records :key #'record-seq)
                         froms tos))))
          (when (>= (now-ms) deadline) (return cursor))
          (sleep sleep-s))))

;;; ---------------------------------------------------------------------- main

(defparameter +usage+
  "Usage: dsmr-bus-watch [options]

Watch the coordination-bus WAL and signal a new foreign message so a dormant
sister agent can be re-armed/woken. Signal lines go to STDOUT; everything else
to STDERR.

Options:
  --bus NAME           bus to arm on (default: $DSMR_BUS_SELECTOR, and the
                       shared host-wide bus when that is unset). The value is
                       the fleet tag, normally exported by the repo's .envrc;
                       the flag is here so a generated arm line an operator
                       reads shows which bus it arms on. A name the bus cannot
                       honour is refused outright rather than downgraded to the
                       shared bus, since a watcher on the wrong bus reports
                       healthy and never fires.
  --wal PATH           WAL file to watch (default: bus.wal under the resolved
                       bus's state root)
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
  --cursors-dir PATH   cursor directory to read (default: cursors/ under the
                       resolved bus's state root)
  --after SEQ          baseline seq; fire on the first foreign seq > SEQ.
                       Overrides the cursor-derived baseline.
                       (default: the resolved agent's cursor, or the WAL's
                        current max seq when no agent resolves; 0 = fire on any
                        record)
  --stream             stream one line per POLL that turned up new foreign
                       records on STDOUT (for a persistent monitor), in the form

                         bus:<SEQ> from=<name>[,<name>...] [to=<name>[,<name>...]]

                       SEQ is the highest such seq and comes first, so a monitor
                       filtering on ^(bus|error): and reading the number after
                       the colon behaves exactly as it always has; the named
                       fields follow it.
                       from= lists every agent that published a record in the
                       batch, distinct and in the order the batch mentions them.
                       It is a list because a poll can turn up several records
                       from several agents, and it saves the woken reader the
                       turn it would otherwise spend asking the bus who wrote to
                       it. A publisher whose id is missing or will not decode is
                       named `unknown`, the same way the bus itself renders it.
                       An agent in the reading agent's own project is named
                       plainly; one from another project is name@namespace.
                       to= appears only when some record in the batch named a
                       recipient, and is absent otherwise rather than empty, so
                       an addressed message and a broadcast never look alike. A
                       mixed batch carries both, so the field names who was
                       written to, never that the whole batch was addressed.
                       One wake per batch, not per record: the reader drains
                       everything pending in one call, so a line means `check the
                       bus` rather than `exactly one message is waiting`, and
                       consecutive lines may skip sequence numbers. On an idle
                       window it self-recycles by exiting 0 so a supervisor
                       re-arms it fresh.
                       Recycle/lifecycle notes go to STDERR, never STDOUT.
                       Default is exit-on-event.
  --poll-ms N          poll interval in milliseconds (default 1000)
  --recycle-seconds N  idle self-recycle window in seconds (default 600)
  --check-live         do not watch; report the running watch's heartbeat for
                       the resolved identity and exit. Prints one line to STDOUT
                       (`live pid=<pid> age_s=<n> bus=<name>`,
                       `stale pid=<pid> age_s=<n> bus=<name>`, `dead bus=<name>`,
                       or `unknown` when no identity resolves) and exits
                       0 live / 1 stale-or-dead / 2 unknown. The bus field names
                       the resolved bus on every answer, printing `default` for
                       the shared host-wide one, so a watcher that is live on
                       the wrong bus is readable rather than invisible.
                       The live, stale and dead lines end with ` readers=<n>`:
                       how many processes other than the watcher hold its
                       detached log open for reading (`readers=unknown` where
                       /proc cannot say). `live ... readers=0` means the
                       watcher is listening and nothing is following its log,
                       so the agent it serves cannot hear it.
                       Two fields may follow, each only when it applies:
                       ` parked=1` while the agent is parked (see --park), and
                       ` deaf=<epoch>` while the deafness alarm stands (see
                       --deaf-seconds), the epoch being when the unheard mail
                       was written (`deaf=unknown` when the marker cannot be
                       read).
  --live-window-seconds N
                       how fresh a heartbeat must be to count as live under
                       --check-live (default 5). A live watch refreshes every
                       poll, so this need only exceed --poll-ms with some slack.
  --detach             make sure a detached streaming watcher is running for the
                       resolved identity and bus, then exit. Launch it once per
                       session: it runs in its own session with stdin from
                       /dev/null, survives the shell that started it, re-arms
                       itself in place at every idle recycle, and appends its
                       wake lines to
                         $XDG_STATE_HOME/dsmr-mcp/watch/<bus>--<agent>--<hash>.log
                       where <hash> is a short hash of the full agent identity,
                       so two agents of one name in different namespaces keep
                       separate files, beside a pid file of the same stem. A
                       watcher an earlier build started under the name-only
                       stem is found and used. Running it again while
                       that watcher is up starts nothing. Prints
                         detached pid=<pid> bus=<name> log=<path>
                       (`running` in place of `detached` when one was already
                       up) and then `monitor: <command>`, the tail to run under
                       a persistent monitor. Exits 0, 1 when a watcher under the
                       same name belongs to another namespace or the child did
                       not come up, 2 when no identity resolves. The other watch
                       flags (--poll-ms, --recycle-seconds, --wal, ...) pass
                       through to the detached watcher.
  --reap               stop the detached watcher for the resolved identity and
                       bus, signalling its whole process group with SIGTERM and
                       then SIGKILL after a grace period, and confirm the pid is
                       gone. Prints one line per watcher (`reaped pid=<pid>
                       bus=<name> signal=term|kill`, `none bus=<name>`,
                       `survived pid=<pid> bus=<name>`, or `foreign ...` for a
                       watcher under the same name in another namespace, which
                       is left running) and exits 0 when none is left, 1
                       otherwise.
  --wake               do not watch; wait for the next `bus:` or `error:` line
                       to reach the detached log for the resolved identity and
                       bus, print that line to STDOUT exactly as the watcher
                       wrote it, and exit 0. Lines already in the log are never
                       reported; a log that is rotated or truncated is followed
                       onto its new contents. Run it as a background command
                       and run it again after each drain. When nothing has
                       arrived after --wake-seconds, it prints
                         idle wake-seconds=<N>
                       and exits 0; treat that exactly like a wake: drain,
                       then re-arm. Long silence on a bus is normal, and this
                       keeps the wait inside the time limit a background
                       runner imposes, so re-arming stays the ordinary path.
                       While it waits it holds the log open, so it counts as a
                       reader under --check-live. When no detached watcher is
                       running for a bus it would wait on, at the start or
                       while waiting, it prints `nowatcher bus=<name>` and exits
                       1, so start one with --detach and wake again. Exits 2
                       when no identity resolves, 143 on SIGTERM.
  --wake-seconds N     how long --wake waits before returning `idle` (default
                       6600, under the two-hour limit of a background command;
                       0 waits with no limit).
  --deaf-seconds N     how long a wake line may sit unheard in a detached
                       watcher's log before the watcher raises the deafness
                       alarm (default 600; 0 turns the alarm off). A line
                       counts as unheard when nothing was following the log as
                       it was written and nothing has followed it since. The
                       alarm is one desktop notification through notify-send,
                       naming the agent, the bus and the repository to type
                       in, plus a `.deaf` file beside the watcher's pid file;
                       --check-live reports it as `deaf=<epoch>`. It is raised
                       once per episode and cleared when the agent is heard
                       again. A quiet bus never raises it, and neither does a
                       parked agent.
  --park               do not watch; write the park marker (a `.parked` file
                       beside the pid file) for the resolved identity and bus,
                       or with --all-buses for every bus it has a detached
                       watcher on, print `parked bus=<name>` per bus and exit
                       0. Run it as the park step, before the agent stops
                       listening: while the marker exists no deafness alarm is
                       raised, so a fleet takedown is silent. The watcher keeps
                       running. Exits 2 with `unknown` when no identity
                       resolves.
  --unpark             remove the park marker the same way, printing
                       `unparked bus=<name>`. --detach removes it too, so
                       bring-up ends a park whichever is run.
  --all-buses          with --reap, stop this agent's detached watchers on every
                       bus rather than only the resolved one. With --wake, wait
                       on the log of every detached watcher this agent has a
                       pid file for and return the first line any of them gets
                       (`nowatcher bus=*` when it has none).
  --stall-seconds N    end the watch with status 75 when its poll loop has not
                       come round for N seconds, never less than ten poll
                       intervals (default 120; 0 disables). A watch wedged on a
                       write to a pipe nobody drains is otherwise alive and deaf
                       for good.
  -h, --help           print this help and exit

An unknown flag, or a flag with an unparseable value, is reported on STDERR and
then ignored — the watcher keeps running on defaults rather than leaving the
agent deaf to the bus.

Exit-on-event prints one `bus:<SEQ>` line then exits 0; on idle recycle it
prints `recycle:` then exits 0. Streaming prints one
`bus:<SEQ> from=<name>[,...] [to=<name>[,...]]` line per poll that turned up new
foreign records, carrying the highest of them and naming the agents it came
from, and self-recycles by exiting 0 on an idle window, so its supervising
monitor re-arms it fresh; its recycle/lifecycle diagnostics go only to STDERR.

While a watch runs it refreshes a heartbeat file every poll and removes it on
clean exit; a dead watch leaves no fresh beat. --check-live reads that beat so a
dead watch is distinguishable from a live one — the gap this closes is that a
watch which stopped listening otherwise exits identically to one that never fired.

SIGTERM ends a watch at once with status 143, removing its heartbeat and, for a
detached watcher, its pid file.
")

(defun %usage (&optional (stream *error-output*))
  (write-string +usage+ stream)
  (force-output stream))

(defstruct (options (:conc-name opt-))
  "One parsed command line. A named record rather than a positional tuple: the
   watcher now takes a dozen settings, and a twelve-element VALUES list is a
   defect waiting for the day someone inserts a value in the middle of it.

   BUS is the bus this watch arms on. NIL means the host-wide default bus, which
   is the only bus that existed before buses had names and is still what an
   operator gets by passing nothing."
  (wal nil)
  (after nil)
  (agent nil)
  (namespace nil)
  (bus nil)
  (agent-id nil)
  (cursors-dir nil)
  (stream-p nil)
  (poll-ms 1000)
  (recycle-seconds 600)
  (check-p nil)
  (live-window-seconds 5)
  (detach-p nil)
  (detached-child-p nil)
  (reap-p nil)
  (all-buses-p nil)
  (wake-p nil)
  (wake-seconds 6600)
  (deaf-seconds 600)
  (park-p nil)
  (unpark-p nil)
  (stall-seconds 120)
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
                 ((string= arg "--detach")
                  (setf (opt-detach-p opts) t))
                 ((string= arg "--detached-child")
                  (setf (opt-detached-child-p opts) t
                        (opt-stream-p opts) t))
                 ((string= arg "--reap")
                  (setf (opt-reap-p opts) t))
                 ((string= arg "--park")
                  (setf (opt-park-p opts) t))
                 ((string= arg "--unpark")
                  (setf (opt-unpark-p opts) t))
                 ((string= arg "--all-buses")
                  (setf (opt-all-buses-p opts) t))
                 ((string= arg "--wake")
                  (setf (opt-wake-p opts) t))
                 ((string= arg "--wake-seconds")
                  (setf (opt-wake-seconds opts)
                        (next-nonneg "--wake-seconds" (opt-wake-seconds opts))))
                 ((string= arg "--deaf-seconds")
                  (setf (opt-deaf-seconds opts)
                        (next-nonneg "--deaf-seconds" (opt-deaf-seconds opts))))
                 ((string= arg "--stall-seconds")
                  (setf (opt-stall-seconds opts)
                        (next-nonneg "--stall-seconds" (opt-stall-seconds opts))))
                 ((string= arg "--wal")
                  (setf (opt-wal opts) (or (next-value "--wal") (opt-wal opts))))
                 ((string= arg "--agent")
                  (setf (opt-agent opts)
                        (or (next-value "--agent") (opt-agent opts))))
                 ((string= arg "--namespace")
                  (setf (opt-namespace opts)
                        (or (next-value "--namespace") (opt-namespace opts))))
                 ((string= arg "--bus")
                  (setf (opt-bus opts)
                        (or (next-value "--bus") (opt-bus opts))))
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

(defun %env-bus-selector ()
  "The DSMR_BUS_SELECTOR value, or NIL when unset or empty. An empty string
   reads as absent, matching the convention every other DSMR_* environment read
   uses."
  (let ((value (uiop:getenv "DSMR_BUS_SELECTOR")))
    (when (and value (plusp (length value)))
      value)))

(defun %resolve-bus (opts)
  "The bus this watch arms on: --bus if it carries a value, else
   DSMR_BUS_SELECTOR, else NIL for the host-wide default bus.

   That is the same explicit-then-environment precedence %RESOLVE-SELF-ID uses
   for the agent name, extended rather than forked. It reads the SAME variable
   the .envrc stanza declares and the MCP session resolves its own bus by, so a
   watcher and the session it serves cannot land on different buses while both
   report themselves healthy.

   The name is validated here, at the point the operator's value is read, and an
   unusable one is signalled rather than dropped. This is the one place in this
   binary where refusing to start is right: a mistyped cadence flag costs its own
   default, but a bus name that quietly degrades to the default bus leaves a
   watcher armed on a bus nobody is talking on, reporting live and never firing.
   Arming somewhere else is indistinguishable from arming correctly until a
   message goes unanswered."
  (let* ((flagged (opt-bus opts))
         (name (or (and flagged (plusp (length flagged)) flagged)
                   (%env-bus-selector))))
    (when name
      (selector:validate-bus-name name))))

(defun %normalise-agent-id (id)
  "ID with every run of separators collapsed to one and any trailing separator
   removed, or NIL for NIL.

   A doubled separator names the same agent as a single one, but every file a
   watcher keeps (cursor, heartbeat, log, pid file) is named from the id, so a
   second spelling would be a second set of files, and a probe typed with it
   would read a healthy agent as dead."
  (when id
    (let ((out (make-string-output-stream))
          (previous-separator-p nil))
      (loop for ch across id
            do (let ((separator-p (char= ch #\/)))
                 (unless (and separator-p previous-separator-p)
                   (write-char ch out))
                 (setf previous-separator-p separator-p)))
      (let ((collapsed (get-output-stream-string out)))
        (if (and (> (length collapsed) 1)
                 (char= (char collapsed (1- (length collapsed))) #\/))
            (subseq collapsed 0 (1- (length collapsed)))
            collapsed)))))

(defun %resolve-self-id (opts)
  "The full <namespace>/<name> bus id this watcher watches on behalf of, or NIL
   when no identity resolves.

   The name comes from --agent, falling back to DSMR_BUS_AGENT — the same order
   the MCP session resolves its own name by, extended here rather than forked.
   The one rule not carried over is the ephemeral opt-out: a watcher exists to
   watch for a STABLE identity, one whose cursor outlives a restart.

   The namespace comes from --agent-id (taken whole, no construction, apart from
   collapsing doubled separators) or --namespace. Either way the id passes
   through %NORMALISE-AGENT-ID: a doubled separator names the same agent, and a
   second spelling of it would be a second set of files. The working directory
   is a last resort and announces itself: the cursor file is keyed on the FULL
   id, so a namespace guessed from wherever the operator happened to be standing
   points at another agent's cursor or at none at all, and does it without a
   word. Construction goes through the shared envelope leaf, so the id this
   builds and the id the publisher stamps into a message can never drift apart."
  (let ((explicit (opt-agent-id opts)))
    (%normalise-agent-id
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
               (envelope:agent-id namespace :name name))))))))

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

(defun %liveness-line (status age pid bus &optional readers parked deaf-since)
  "The one status line --check-live prints for STATUS, as a string with no
   trailing newline. Pure: it prints nothing and exits nothing, so the answer
   can be read directly rather than inferred from a process.

   Every answer names the bus it is answering for, the default bus included, and
   NIL renders as the literal `default`. A field present only for a named bus
   could not tell a watcher on the default bus apart from a binary too old to
   know that buses have names, which is the same silence between `armed` and
   `armed somewhere else` that the field exists to break. `default` is
   unambiguous as a literal because the bus refuses it as a name, so the word
   can only ever mean the unnamed bus.

   READERS, when given, is appended last as `readers=<n>`, or `readers=unknown`
   for :UNKNOWN: how many processes other than the watcher hold its detached log
   open for reading. It goes after every existing field so a reader parsing the
   line by position keeps working. `live ... readers=0` is the answer that
   matters: the watcher is listening and nothing is following what it writes, so
   the agent it serves cannot hear it.

   PARKED and DEAF-SINCE follow it, in that order and each only when set, for
   the same reason: `parked=1` while the agent is parked, and `deaf=<epoch>`
   while the watcher's deafness alarm stands, the epoch being when the unheard
   mail was written, or `deaf=unknown` for a marker that cannot be read. An
   unreadable marker is still shown, since leaving the field out would read as
   an agent that can hear.

   The `unknown` answer deliberately has no case here. It is printed when no
   identity resolves, and a bus name printed beside an unresolved identity would
   read as a probe that found something."
  (let ((label (or bus "default"))
        (suffix (with-output-to-string (out)
                  (when readers
                    (format out " readers=~A"
                            (if (eq readers :unknown) "unknown" readers)))
                  (when parked
                    (format out " parked=1"))
                  (when deaf-since
                    (format out " deaf=~A"
                            (if (eq deaf-since :unknown) "unknown" deaf-since))))))
    (concatenate
     'string
     (ecase status
       (:live  (format nil "live pid=~A age_s=~A bus=~A" (or pid "?") age label))
       (:stale (format nil "stale pid=~A age_s=~A bus=~A" (or pid "?") age label))
       (:dead  (format nil "dead bus=~A" label)))
     suffix)))

(defun %check-live (self-id beat-path window-seconds &optional bus)
  "Report the liveness of the watch for SELF-ID on BUS from its heartbeat, then
   exit. Never watches: this is the cheap probe an agent runs to answer `is my
   watch still listening?`.

   A resolved identity is what makes liveness observable at all: the beat file
   is keyed on it, exactly as the cursor is. With none there is no stable key to
   probe, so this prints `unknown` and exits 2 — honest that liveness needs the
   same resolved identity a healthy watch already runs under, not a softer
   answer that would read as `fine`. That line carries no bus field; see
   %LIVENESS-LINE for why.

   Otherwise it prints exactly one status line to *standard-output* — the only
   thing an agent parses — and exits 0 for a live beat, 1 for a stale or absent
   one. Any human-facing detail goes to *error-output*, never stdout.

   BEAT-PATH is derived from BUS, so an agent joined to several buses runs one
   probe per bus and each answers about its own watch. The bus on the line is
   what makes those answers tellable apart.

   The line ends with the reader count for this identity's detached log on BUS
   (see %LOG-READERS). A watcher that is live is only half of an agent that can
   hear: the other half is whatever follows the log, and that half is the one
   the harness has to keep re-arming. The watcher itself is left out of the
   count.

   After it come `parked=1` when the agent is parked and `deaf=<epoch>` when its
   watcher has raised the deafness alarm, read from the marker files beside the
   pid file, so a leader sees both without a process list."
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
        (let* ((stem (%resolve-detach-stem bus self-id))
               (watcher (%live-detached-pid (%detach-file stem "pid")))
               (readers (%log-readers (%detach-file stem "log")
                                      (remove-if-not #'integerp
                                                     (list pid watcher)))))
          (format *standard-output* "~A~%"
                  (%liveness-line status age pid bus readers
                                  (probe-file (%detach-file stem "parked"))
                                  (let ((deaf (%detach-file stem "deaf")))
                                    (and (probe-file deaf)
                                         (%marker-since deaf))))))
        (force-output *standard-output*)
        (uiop:quit (if (eq status :live) 0 1)))))

;;; ------------------------------------------------------ termination and stalls
;;;
;;; A watcher can wedge in one place: a write of a wake line to STDOUT. When the
;;; monitor on the other end of that pipe stops reading but something still holds
;;; the read end open, the pipe fills and the write blocks in the kernel for good.
;;; Everything else stops with it. The recycle deadline is checked after the emit
;;; returns, so it is never reached, and the heartbeat stops advancing. SBCL's
;;; stock SIGTERM handler then makes matters worse: it exits by unwinding and
;;; flushing the standard streams, and the flush blocks on the same full pipe, so
;;; the process sits in the kernel ignoring the signal and only SIGKILL removes it.
;;;
;;; I handle both ends of that here. SIGTERM exits at once without touching the
;;; output streams, and a watchdog thread ends a watch whose poll loop has not
;;; come round for longer than any healthy poll can take. Both remove the files a
;;; clean exit would have removed, so a liveness probe answers `dead` rather than
;;; reading a beat left behind by a process that is gone.

(defvar *last-poll-time* 0
  "Internal real time at which the poll loop last came round. Written by the
   poll thunk on the main thread and read by the stall watchdog.")

(defvar *cleanup-paths* '()
  "Files a watch removes however it ends: its heartbeat, and in detached mode its
   pid file. Held here rather than in an UNWIND-PROTECT because the two exits
   that matter most, SIGTERM and a stall, do not unwind.")

(defun %note-poll ()
  "Record that the poll loop came round just now."
  (setf *last-poll-time* (get-internal-real-time)))

(defun %emergency-cleanup ()
  "Remove every file in *CLEANUP-PATHS*. Best-effort and silent: this runs on the
   way out of a signal handler or a stalled process, where there is nobody left
   to report a failure to and no stream that is safe to write on."
  (dolist (path *cleanup-paths*)
    (ignore-errors (when (probe-file path) (delete-file path)))))

(defun %install-termination-handler ()
  "Make SIGTERM end this process promptly, whatever it is doing.

   The exit is an abort exit: no unwinding and no flush of the standard streams.
   A graceful exit flushes STDOUT, and a STDOUT that is a full pipe nobody reads
   is exactly the state in which a watcher most needs to be stopped. Every wake
   line is already flushed as it is written, so aborting loses nothing. The exit
   status is 143, the conventional one for a process ended by SIGTERM."
  (sb-sys:enable-interrupt
   sb-posix:sigterm
   (lambda (signo context info)
     (declare (ignore signo context info))
     (%emergency-cleanup)
     (sb-ext:exit :code 143 :abort t))))

(defun %effective-stall-seconds (stall-seconds poll-ms)
  "How long the poll loop may go without coming round before the watch counts as
   wedged, or 0 when the watchdog is off. Never less than ten poll intervals, so
   a slow cadence cannot read as a stall."
  (if (zerop stall-seconds)
      0
      (max stall-seconds (ceiling (* 10 poll-ms) 1000))))

(defun %stalled-p (now last stall-seconds)
  "True when more than STALL-SECONDS separate LAST from NOW, both in internal
   real time units."
  (> (- now last) (* stall-seconds internal-time-units-per-second)))

(defun %start-stall-watchdog (stall-seconds)
  "Start a thread that ends this process with status 75 once the poll loop has
   not come round for STALL-SECONDS. Does nothing when STALL-SECONDS is 0.

   A wedged watch is worse than a dead one, because it holds its place: a live
   pid, and for a detached watcher a pid file, that stop anything from starting
   in its stead. Ending it turns silent deafness into an absence that a probe
   reports and a re-arm repairs. The thread writes nothing on the way out, since
   the stream the watch wedged on may be the only one it has."
  (when (plusp stall-seconds)
    (%note-poll)
    (sb-thread:make-thread
     (lambda ()
       (loop
         (sleep (max 0.2 (min 5 (/ stall-seconds 4))))
         (when (%stalled-p (get-internal-real-time) *last-poll-time* stall-seconds)
           (%emergency-cleanup)
           (sb-ext:exit :code 75 :abort t))))
     :name "dsmr-bus-watch stall watchdog")))

;;; ----------------------------------------------------------- detached watchers
;;;
;;; A watcher run under a harness monitor lives exactly as long as the monitor
;;; does, and every re-arm of the monitor is a fresh launch the harness may refuse.
;;; A detached watcher is launched once per session instead. It runs in its own
;;; session with no terminal, writes its wake lines to a log file, and re-arms
;;; itself in place at each recycle, so the monitor becomes a plain tail of that
;;; log and re-arming it launches nothing new.
;;;
;;; The pid file is claimed with a POSIX record lock that the detached watcher
;;; holds for its whole life. The kernel drops the lock when the process dies,
;;; however it dies, so the lock rather than the pid written in the file is what
;;; says a watcher is running, and a pid recycled onto some other process after a
;;; crash can never be mistaken for one.

(defun %state-home ()
  "$XDG_STATE_HOME as a directory, falling back to ~/.local/state/."
  (let ((xdg (uiop:getenv "XDG_STATE_HOME")))
    (if (and xdg (plusp (length xdg)))
        (uiop:ensure-directory-pathname xdg)
        (merge-pathnames ".local/state/" (user-homedir-pathname)))))

(defun %detach-dir ()
  "Where detached watchers keep their logs and pid files: dsmr-mcp/watch/ under
   the state home. One directory for every bus, so a single tail over
   *--<agent>--*.log follows an agent on all the buses it has joined."
  (merge-pathnames "dsmr-mcp/watch/" (%state-home)))

(defun %agent-name (self-id)
  "The name part of the full bus id SELF-ID."
  (nth-value 1 (envelope:split-agent-id self-id)))

(defun %identity-hash (string)
  "The 32-bit FNV-1a hash of STRING's character codes, as eight lowercase hex
   digits.

   The hash names files that outlive the binary that wrote them, and a later
   build has to find them again, so it is computed here from first principles
   rather than with SXHASH or any other function whose value an implementation
   is free to change between builds."
  (let ((hash 2166136261))
    (loop for ch across string
          do (setf hash (ldb (byte 32 0)
                             (* (logxor hash (char-code ch)) 16777619))))
    (format nil "~(~8,'0X~)" hash)))

(defun %detach-stem (bus self-id)
  "The file stem for the detached watcher of the full bus id SELF-ID on BUS:
   <bus>--<agent>--<hash>, with `default` standing for the unnamed bus.

   The agent name stays readable so an operator can find a log by eye. The hash
   is of the whole normalised id (see %IDENTITY-HASH), so two agents with the
   same name in different namespaces get separate files and separate reader
   counts, and a namespace of any length adds only eight characters."
  (let ((id (%normalise-agent-id self-id)))
    (format nil "~A--~A--~A"
            (%field-token (or bus "default"))
            (%field-token (%agent-name id))
            (%identity-hash id))))

(defun %legacy-detach-stem (bus self-id)
  "The stem earlier builds gave the detached watcher of SELF-ID on BUS: the bus
   and the agent name alone, with no trace of the namespace. Watchers those
   builds started are still running under it, and are found by it until they
   are next restarted (see %RESOLVE-DETACH-STEM)."
  (format nil "~A--~A"
          (%field-token (or bus "default"))
          (%field-token (%agent-name (%normalise-agent-id self-id)))))

(defun %detach-file (stem type)
  "The file STEM.TYPE in the detach directory, built from a native namestring so
   nothing in an agent name can be read as a wildcard."
  (uiop:parse-native-namestring
   (concatenate 'string (uiop:native-namestring (%detach-dir)) stem "." type)))

(defun %whole-file-lock (type)
  "A lock record of TYPE covering the whole file."
  (make-instance 'sb-posix:flock :type type :whence sb-posix:seek-set
                                 :start 0 :len 0))

(defun %lock-holder (path)
  "The pid of the process holding the watcher lock on PATH, or NIL when nobody
   holds it or PATH does not exist.

   Never call this from the process that holds the lock. POSIX drops a process's
   record locks on a file when it closes ANY descriptor for that file, and this
   opens and closes one."
  (let ((fd (ignore-errors (sb-posix:open (uiop:native-namestring path)
                                          sb-posix:o-rdonly))))
    (when fd
      (unwind-protect
           (ignore-errors
            (let ((lock (%whole-file-lock sb-posix:f-wrlck)))
              (sb-posix:fcntl fd sb-posix:f-getlk lock)
              (unless (= (sb-posix:flock-type lock) sb-posix:f-unlck)
                (sb-posix:flock-pid lock))))
        (ignore-errors (sb-posix:close fd))))))

(defun %pid-file-contents (path)
  "The pid and the full bus id recorded in the pid file at PATH, as two values,
   either of them NIL when absent. A file holding a bare pid, as a watcher
   launched by hand from a shell writes, yields that pid and no id."
  (let ((lines (ignore-errors (uiop:read-file-lines path))))
    (values (and (first lines)
                 (ignore-errors (parse-integer (first lines) :junk-allowed t)))
            (let ((id (second lines)))
              (and id (plusp (length id)) id)))))

(defun %proc-file (pid name)
  "The text of /proc/PID/NAME, or NIL where there is no such file."
  (ignore-errors
   (uiop:read-file-string (format nil "/proc/~D/~A" pid name))))

(defun %pid-alive-p (pid)
  "True when a process PID exists and is not a zombie. A process owned by another
   user still counts: it exists, and it is not ours to reuse the slot of."
  (and (handler-case (progn (sb-posix:kill pid 0) t)
         (sb-posix:syscall-error (e)
           (/= (sb-posix:syscall-errno e) sb-posix:esrch)))
       (let ((stat (%proc-file pid "stat")))
         ;; The state letter follows the parenthesised command name.
         (not (and stat
                   (let ((close (position #\) stat :from-end t)))
                     (and close
                          (< (+ close 2) (length stat))
                          (char= (char stat (+ close 2)) #\Z))))))))

(defun %looks-like-watcher-p (pid)
  "True when PID's command line names this binary, or when there is no /proc to
   ask. Only consulted for a pid file nobody holds a lock on, where the recorded
   pid may since have been handed to some unrelated process."
  (if (probe-file "/proc/self/")
      (let ((cmdline (%proc-file pid "cmdline")))
        (and cmdline (search "dsmr-bus-watch" cmdline) t))
      t))

(defun %live-detached-pid (pid-path)
  "The pid of the detached watcher behind PID-PATH, or NIL when none is running.

   The lock holder answers first. A pid file with no lock on it still counts when
   its pid is alive and is plainly a watcher, which is how a watcher loop started
   by hand from a shell shows up; leaving that one out would let --detach start a
   second watcher beside it."
  (or (%lock-holder pid-path)
      (let ((pid (%pid-file-contents pid-path)))
        (and pid (%pid-alive-p pid) (%looks-like-watcher-p pid) pid))))

(defun %recorded-id-matches-p (pid-path self-id)
  "True when the pid file at PID-PATH records the same agent as SELF-ID, once
   both are normalised. A file with no recorded id matches nothing."
  (let ((recorded (nth-value 1 (%pid-file-contents pid-path))))
    (and recorded self-id
         (string= (%normalise-agent-id recorded) (%normalise-agent-id self-id)))))

(defun %resolve-detach-stem (bus self-id)
  "The stem to look for SELF-ID's detached watcher on BUS under.

   That is the current stem (%DETACH-STEM) unless a watcher started by an
   earlier build is still running under the older name-only stem and records
   this same identity in its pid file. Then it is that older stem, so the
   running watcher is adopted: --detach does not start a second one beside it,
   and --check-live, --wake and --reap act on the files it is actually writing.
   A same-named watcher from another namespace records another identity and is
   never adopted.

   Only callers looking for an existing watcher use this. A new watcher always
   claims the current stem, and never calls this, since asking who holds a lock
   from the holder drops the lock (see %LOCK-HOLDER)."
  (let ((current (%detach-stem bus self-id))
        (legacy (%legacy-detach-stem bus self-id)))
    (cond ((%live-detached-pid (%detach-file current "pid")) current)
          ((let ((legacy-pid (%detach-file legacy "pid")))
             (and (%live-detached-pid legacy-pid)
                  (%recorded-id-matches-p legacy-pid self-id)))
           legacy)
          (t current))))

(defvar *pid-file-stream* nil
  "The open stream on the pid file this detached watcher has claimed. Held for the
   life of the process: closing it would drop the lock.")

(defun %claim-pid-file (path self-id)
  "Take the watcher lock on PATH for this process and record our pid and SELF-ID
   in it. Returns true on success and NIL when another watcher already holds it,
   or when the file names a live watcher started by hand that holds no lock.

   The descriptor stays open for the life of the process, because the lock goes
   with it. The contents are written through that same descriptor for the same
   reason: POSIX drops a process's record locks on a file as soon as it closes
   any descriptor for it, so the recorded pid is read before the lock is taken
   and nothing opens the file again afterwards."
  (ensure-directories-exist path)
  (let ((recorded (%pid-file-contents path)))
    (unless (and recorded (/= recorded (sb-posix:getpid))
                 (%pid-alive-p recorded) (%looks-like-watcher-p recorded)
                 (null (%lock-holder path)))
      (let ((fd (sb-posix:open (uiop:native-namestring path)
                               (logior sb-posix:o-creat sb-posix:o-rdwr) #o644)))
        (handler-case
            (progn
              (sb-posix:fcntl fd sb-posix:f-setlk
                              (%whole-file-lock sb-posix:f-wrlck))
              (sb-posix:ftruncate fd 0)
              (let ((stream (sb-sys:make-fd-stream fd :input t :output t
                                                      :external-format :utf-8
                                                      :buffering :full)))
                (format stream "~D~%~A~%" (sb-posix:getpid) self-id)
                (finish-output stream)
                (setf *pid-file-stream* stream))
              t)
          (error ()
            (ignore-errors (sb-posix:close fd))
            nil))))))

(defun %shell-quote (string)
  "STRING quoted for a POSIX shell."
  (with-output-to-string (out)
    (write-char #\' out)
    (loop for ch across string
          do (if (char= ch #\')
                 (write-string "'\\''" out)
                 (write-char ch out)))
    (write-char #\' out)))

(defun %monitor-command (log-path)
  "The command a harness monitor runs to follow LOG-PATH: new lines only, still
   following when the file is replaced, filtered to the wake and error lines."
  (format nil "tail -q -n0 -F ~A | grep --line-buffered -E '^(bus|error):'"
          (%shell-quote (uiop:native-namestring log-path))))

(defun %find-on-path (program)
  "The full path of PROGRAM on $PATH, or NIL."
  (dolist (dir (uiop:split-string (or (uiop:getenv "PATH") "") :separator ":"))
    (when (plusp (length dir))
      (let ((candidate (probe-file (concatenate 'string
                                                (string-right-trim "/" dir)
                                                "/" program))))
        (when candidate (return (uiop:native-namestring candidate)))))))

(defun %child-args (args bus self-id)
  "The argument list for the detached child: ARGS without --detach, plus the bus
   and the full identity this parent resolved.

   Passing both explicitly is what frees the child from the parent's working
   directory and environment. It runs from / and outlives the shell that started
   it, so anything it inferred there would be inferred from the wrong place."
  (append (remove "--detach" args :test #'string=)
          (list "--detached-child" "--agent-id" self-id)
          (and bus (list "--bus" bus))))

(defun %spawn-detached (args log-path)
  "Start this binary with ARGS in its own session, appending its output to
   LOG-PATH, with stdin from /dev/null and / as its working directory. Returns
   without waiting.

   setsid(1) supplies the new session where it is installed, so the watcher has
   no controlling terminal and nothing reaches it when the harness session ends.
   Where it is not, the child still gets its own process group, which is what
   --reap signals."
  (let ((self (uiop:native-namestring sb-ext:*runtime-pathname*))
        (setsid (%find-on-path "setsid")))
    (ensure-directories-exist log-path)
    (sb-ext:run-program (or setsid self)
                        (if setsid (cons self args) args)
                        :input nil
                        :output (uiop:native-namestring log-path)
                        :if-output-exists :append
                        :error :output
                        :directory "/"
                        :wait nil)))

(defun %detach (bus self-id args)
  "Make sure a detached watcher is running for SELF-ID on BUS and print where to
   follow it, then exit.

   Idempotent. With a watcher already running for this identity, this reports it
   and starts nothing, so running it on every bring-up is safe. A watcher running
   under the same name for a DIFFERENT namespace is reported as a conflict and
   left alone: it belongs to another agent.

   This is the bring-up step, so it also removes a park marker left for this
   identity and bus (see %PARK).

   Prints two lines on STDOUT, `running` in place of `detached` when a watcher
   was already up:

     detached pid=<pid> bus=<bus> log=<path>
     monitor: <command>

   and exits 0. Exits 1 on a conflict or when the child failed to come up, and 2
   when no identity resolves, since a detached watcher is keyed on one."
  (unless self-id
    (%warn "--detach needs a resolved identity (pass --agent with --namespace, or ~
            --agent-id); a detached watcher is keyed on it.")
    (uiop:quit 2))
  (let* ((stem (%resolve-detach-stem bus self-id))
         (log-path (%detach-file stem "log"))
         (pid-path (%detach-file stem "pid"))
         (label (or bus "default")))
    (flet ((report (verb pid)
             (format *standard-output* "~A pid=~D bus=~A log=~A~%monitor: ~A~%"
                     verb pid label (uiop:native-namestring log-path)
                     (%monitor-command log-path))
             (force-output *standard-output*)
             (uiop:quit 0)))
      ;; Bring-up ends a park: the agent is about to listen again, and a park
      ;; marker left behind would silence the deafness alarm for good.
      (let ((parked (%detach-file stem "parked")))
        (when (probe-file parked)
          (ignore-errors (delete-file parked))))
      (let ((running (%live-detached-pid pid-path)))
        (when running
          (let ((recorded (nth-value 1 (%pid-file-contents pid-path))))
            (when (and recorded (not (%recorded-id-matches-p pid-path self-id)))
              (%warn "a detached watcher (pid ~D) already runs as ~A on bus ~A; ~
                      not starting a second one under the same name"
                     running recorded label)
              (uiop:quit 1)))
          (report "running" running)))
      (%spawn-detached (%child-args args bus self-id) log-path)
      (loop repeat 100
            do (let ((pid (%lock-holder pid-path)))
                 (when pid (report "detached" pid)))
               (sleep 0.1))
      (%warn "the detached watcher did not come up within 10s; see ~A"
             (uiop:native-namestring log-path))
      (uiop:quit 1))))

(defun %run-detached (opts wal-path cursors-dir self-id first-baseline on-poll)
  "The detached watcher's own loop: stream, and at every idle recycle re-arm in
   place. Never returns.

   Each cycle arms afresh from the agent's durable cursor, exactly as a watcher
   relaunched by a monitor would, so a message the agent has not yet drained is
   announced again at the next re-arm rather than depending on the one line that
   first announced it having been seen. A cycle that fails is reported and
   retried after a pause, because giving up would leave the agent deaf with its
   pid file gone and nothing to say why. The same failure is put on STDOUT as an
   `error:` line only once, so a persistent fault does not wake the agent every
   few seconds.

   Every wake or error line written here is also noted for the deafness alarm,
   along with whether anything was following the log to hear it (see
   %NOTE-SIGNAL-LINE)."
  (let ((baseline first-baseline)
        (last-error nil))
    (loop
      (handler-case
          (let ((cursor (watch-stream wal-path baseline
                                      :poll-ms (opt-poll-ms opts)
                                      :recycle-seconds (opt-recycle-seconds opts)
                                      :self-id self-id
                                      :on-poll on-poll
                                      :emit (lambda (seq froms tos)
                                              (%signal-seq seq froms tos)
                                              (%note-signal-line)))))
            (setf last-error nil)
            (%warn "recycle: idle window elapsed; re-arming in place")
            (setf baseline (or (%cursor-baseline self-id wal-path cursors-dir)
                               cursor)))
        (error (e)
          (let ((text (princ-to-string e)))
            (%warn "watch cycle failed: ~A; re-arming in 5s" text)
            (unless (equal text last-error)
              (format *standard-output* "error: detached watcher: ~A~%"
                      (substitute #\Space #\Newline text))
              (force-output *standard-output*)
              (%note-signal-line))
            (setf last-error text))
          (%note-poll)
          (sleep 5)
          (setf baseline (or (ignore-errors
                              (%cursor-baseline self-id wal-path cursors-dir))
                             baseline)))))))

(defun %reap-one (pid-path bus self-id &key (grace-seconds 3))
  "Stop the detached watcher behind PID-PATH and print one line saying what
   happened. Returns true when no watcher is left running there.

   The whole process group is signalled when the watcher leads one, which is
   what takes down a hand-started shell loop along with the watcher inside it.
   SIGTERM comes first, then SIGKILL after GRACE-SECONDS, and the answer is
   decided by whether the pid is actually gone, not by which signal was sent.

   A watcher recorded under a different full id is left running and reported:
   it shares the name but belongs to an agent in another namespace."
  (let ((label (or bus "default"))
        (pid (%live-detached-pid pid-path))
        (recorded (nth-value 1 (%pid-file-contents pid-path))))
    (labels ((say (control &rest args)
               (format *standard-output* "~?~%" control args)
               (force-output *standard-output*))
             (group-empty-p (pgid)
               (handler-case (progn (sb-posix:kill (- pgid) 0) nil)
                 (sb-posix:syscall-error () t)))
             (gone-p (group-p)
               (and (not (%pid-alive-p pid))
                    (or (not group-p) (group-empty-p pid))))
             (send (target signal)
               (handler-case (progn (sb-posix:kill target signal) t)
                 (sb-posix:syscall-error () nil)))
             (await (group-p tenths)
               (loop repeat tenths
                     until (gone-p group-p)
                     do (sleep 0.1))
               (gone-p group-p)))
      (cond
        ((null pid)
         (ignore-errors (when (probe-file pid-path) (delete-file pid-path)))
         (say "none bus=~A" label)
         t)
        ((and recorded self-id (not (%recorded-id-matches-p pid-path self-id)))
         (say "foreign pid=~D bus=~A id=~A" pid label recorded)
         nil)
        (t
         (let* ((group-p (eql (ignore-errors (sb-posix:getpgid pid)) pid))
                (target (if group-p (- pid) pid))
                (how "term"))
           (send target sb-posix:sigterm)
           (unless (await group-p (* 10 grace-seconds))
             (setf how "kill")
             (send target sb-posix:sigkill)
             (await group-p 20))
           (cond ((gone-p group-p)
                  (ignore-errors
                   (when (probe-file pid-path) (delete-file pid-path)))
                  (say "reaped pid=~D bus=~A signal=~A" pid label how)
                  t)
                 (t
                  (say "survived pid=~D bus=~A" pid label)
                  nil))))))))

(defun %reap-targets (bus self-id all-buses-p)
  "The pid files --reap acts on, each paired with the bus it belongs to: the one
   for SELF-ID on BUS, or with ALL-BUSES-P one for every bus SELF-ID has a pid
   file on in the detach directory.

   A bus is found from a pid file under the current stem, or under the older
   name-only stem when that file records this same identity; a same-named agent
   from another namespace is never picked up. Each bus is listed once, under
   whichever stem %RESOLVE-DETACH-STEM settles on for it."
  (if all-buses-p
      (let ((current-suffix (format nil "--~A--~A"
                                    (%field-token (%agent-name self-id))
                                    (%identity-hash (%normalise-agent-id self-id))))
            (legacy-suffix (format nil "--~A" (%field-token (%agent-name self-id))))
            (buses '()))
        (flet ((bus-token (stem suffix)
                 (and (> (length stem) (length suffix))
                      (string= suffix stem
                               :start2 (- (length stem) (length suffix)))
                      (subseq stem 0 (- (length stem) (length suffix))))))
          (dolist (path (directory (merge-pathnames
                                    (make-pathname :name :wild :type "pid")
                                    (%detach-dir))))
            (let* ((stem (pathname-name path))
                   (token (or (bus-token stem current-suffix)
                              (and (%recorded-id-matches-p path self-id)
                                   (bus-token stem legacy-suffix)))))
              (when token
                (pushnew (if (string= token "default") nil token) buses
                         :test #'equal)))))
        (loop for target-bus in (reverse buses)
              collect (cons (%detach-file (%resolve-detach-stem target-bus self-id)
                                          "pid")
                            target-bus)))
      (list (cons (%detach-file (%resolve-detach-stem bus self-id) "pid") bus))))

(defun %reap (opts bus self-id)
  "Stop this agent's detached watcher on BUS, or with --all-buses on every bus,
   then exit 0 when none is left running and 1 otherwise. For use at park, so a
   parked agent leaves nothing listening under its name.

   Prints one line per pid file: `reaped pid=<pid> bus=<bus> signal=term|kill`,
   `none bus=<bus>`, `survived pid=<pid> bus=<bus>`, or `foreign pid=<pid>
   bus=<bus> id=<id>` for a watcher that shares the name but not the namespace."
  (unless self-id
    (%warn "--reap needs a resolved identity (pass --agent with --namespace, or ~
            --agent-id).")
    (uiop:quit 2))
  (let ((targets (%reap-targets bus self-id (opt-all-buses-p opts)))
        (clean t))
    (if (null targets)
        (format *standard-output* "none bus=*~%")
        (dolist (target targets)
          (unless (%reap-one (car target) (cdr target) self-id)
            (setf clean nil))))
    (force-output *standard-output*)
    (uiop:quit (if clean 0 1))))

;;; ------------------------------------------------------------- waking on a log
;;;
;;; The detached watcher keeps listening on its own, but an agent only hears it
;;; through whatever the harness runs to follow its log, and that follower has to
;;; be re-armed by the harness every time it lapses. A re-arm the harness refuses
;;; leaves the watcher live and the agent deaf, and nothing about the watcher
;;; shows it. --wake is the follower as a one-shot: it blocks until the next event
;;; line reaches the log, prints it and exits, so the agent can run it as a
;;; background command with no time limit and run it again after each drain.
;;;
;;; While it waits it holds the log open for reading, exactly as a tail does. That
;;; is what the reader count on --check-live looks for: a log that the watcher is
;;; writing and nobody is reading belongs to an agent that can no longer hear it.

(defun %directory-entries (dir)
  "The names in the directory DIR, without . and .., or NIL when it cannot be
   opened."
  (let ((handle (ignore-errors (sb-posix:opendir dir))))
    (when handle
      (unwind-protect
           (loop for entry = (sb-posix:readdir handle)
                 until (sb-alien:null-alien entry)
                 for name = (sb-posix:dirent-name entry)
                 unless (member name '("." "..") :test #'string=)
                   collect name)
        (sb-posix:closedir handle)))))

(defun %fd-opened-for-reading-p (pid fd)
  "True unless /proc/PID/fdinfo/FD says descriptor FD was opened write-only. An
   fdinfo that cannot be read or parsed counts as reading, since a reader missed
   here would report an agent deaf that is not."
  (let* ((info (%proc-file pid (format nil "fdinfo/~A" fd)))
         (start (and info (search "flags:" info)))
         (flags (and start
                     (ignore-errors
                      (parse-integer info :start (+ start 6) :radix 8
                                          :junk-allowed t)))))
    (or (null flags)
        (/= (logand flags 3) sb-posix:o-wronly))))

(defun %log-readers (log-path &optional exclude-pids)
  "How many processes, other than this one and those in EXCLUDE-PIDS, hold
   LOG-PATH open for reading; or :UNKNOWN where there is no /proc to ask.

   A log that does not exist has no readers, so that answers 0. Processes whose
   descriptors this user may not look at are passed over: they belong to another
   user, and an agent's follower runs as the agent. A descriptor opened
   write-only is not a reader, which is what keeps the watcher's own output, and
   anything else appending to the log, out of the count."
  (if (not (probe-file "/proc/self/fd/"))
      :unknown
      (let ((target (ignore-errors (uiop:native-namestring (truename log-path))))
            (self (sb-posix:getpid))
            (count 0))
        (when target
          (dolist (name (%directory-entries "/proc"))
            (let ((pid (and (every #'digit-char-p name) (parse-integer name))))
              (when (and pid (/= pid self) (not (member pid exclude-pids)))
                (let ((fd-dir (format nil "/proc/~D/fd" pid)))
                  (when (some (lambda (fd)
                                (and (equal target
                                            (ignore-errors
                                             (sb-posix:readlink
                                              (format nil "~A/~A" fd-dir fd))))
                                     (%fd-opened-for-reading-p pid fd)))
                              (%directory-entries fd-dir))
                    (incf count)))))))
        count)))

;;; ------------------------------------------------------------- unheard mail
;;;
;;; A watcher that is live with nothing following its log serves an agent that
;;; cannot hear it. That alone is not an alarm: between turns nothing follows the
;;; log, and a long quiet spell is normal. What is worth telling the operator is
;;; mail that reached the log while nothing was following it and stayed unread.
;;; The detached watcher owns the log for the life of the session, so it is the
;;; one process placed to notice, and it does so without a bus client of its own.

(defstruct (deaf-state (:copier nil))
  "Where one detached watcher stands on the question `can the agent hear me?`.
   UNHEARD-SINCE is when the oldest line nobody has heard was written, or NIL
   when there is none. LATCHED is true once the alarm for the current episode
   has been raised, so it is raised only once."
  (unheard-since nil)
  (latched nil))

(defun %deaf-step (state now &key readers parked-p line-written-p offset-time
                                  (threshold 600))
  "One step of the deafness rule: STATE as it stands at NOW (seconds), given
   what was just observed. Returns (values new-state action), ACTION one of
   :NONE, :RAISE or :CLEAR. Pure: STATE is not modified, and nothing is read or
   written.

   The alarm means mail was written while nothing could hear it, and stayed
   unheard for THRESHOLD seconds. A quiet bus with nobody following the log is
   the normal state between turns and never alarms; it takes a line written
   (LINE-WRITTEN-P) while READERS was 0 to start the clock.

   The agent counts as heard when any sample sees a reader on the log, or when
   OFFSET-TIME, the time a listener last saved its read offset, is newer than
   the unheard line. Being heard ends the episode: :CLEAR when the alarm was
   raised, a silent reset otherwise, so the next episode can raise again.

   While PARKED-P, nothing raises and the pending line is forgotten, so an agent
   that unparks is not alarmed about mail from before its park. The latch is
   left as it was, since parking is not evidence the agent heard anything.

   READERS of :UNKNOWN (no /proc to ask) is never read as zero: it neither
   starts the clock nor raises. A default in place of a measurement would fake
   a positive."
  (let ((since (deaf-state-unheard-since state))
        (latched (deaf-state-latched state))
        (measured (integerp readers)))
    (cond
      (parked-p
       (values (make-deaf-state :unheard-since nil :latched latched) :none))
      ((or (and measured (plusp readers))
           (and offset-time since (> offset-time since)))
       (values (make-deaf-state) (if latched :clear :none)))
      (t
       (let ((since (or since
                        (and line-written-p measured (zerop readers) now))))
         (if (and since measured (not latched)
                  (>= (- now since) threshold))
             (values (make-deaf-state :unheard-since since :latched t) :raise)
             (values (make-deaf-state :unheard-since since :latched latched)
                     :none)))))))

(defun %unix-time (&optional (universal-time (get-universal-time)))
  "UNIVERSAL-TIME, by default now, as seconds since the Unix epoch: the form a
   shell, `date` and a marker file's reader all expect."
  (- universal-time 2208988800))

(defstruct (deaf-watch (:conc-name dw-))
  "What the detached watcher needs to watch for its own deafness: whose log it
   is (SELF-ID on BUS), the file stem its pid file, log and markers share, and
   how long a line may sit unheard (THRESHOLD seconds)."
  self-id bus stem threshold)

(defvar *deaf-watch* nil
  "The deaf-watch of this detached watcher, or NIL when the alarm is off, which
   it is in every mode other than the detached watcher itself.")

(defvar *deaf-state* (make-deaf-state)
  "Where this watcher's current deafness episode stands; see %DEAF-STEP.")

(defvar *deaf-last-sample* nil
  "Internal real time of the last deafness sample, which is taken at most once
   a second however fast the poll loop runs.")

(defvar *deaf-last-warning* nil
  "The text of the last sampler fault reported, so a fault that persists is
   reported once rather than every second.")

(defvar *notify-processes* '()
  "Notification processes started and not yet seen to exit.")

(defun %notify-text (self-id bus elapsed-seconds)
  "The summary and body of the deafness notification, as two values.

   The agent name and the bus pass through %FIELD-TOKEN, and every control
   character in the namespace becomes an underscore, so no name can forge a
   line of its own in the text."
  (multiple-value-bind (namespace name) (envelope:split-agent-id self-id)
    (values (format nil "~A cannot hear the bus" (%field-token (or name self-id)))
            (format nil "bus ~A: mail has waited unread for ~D min. Type in ~A."
                    (%field-token (or bus "default"))
                    (round elapsed-seconds 60)
                    (map 'string
                         (lambda (ch)
                           (if (or (char< ch #\Space) (char= ch (code-char 127)))
                               #\_
                               ch))
                         (or namespace ""))))))

(defun %notify-environment (environment uid)
  "ENVIRONMENT (a list of NAME=VALUE strings) for the notification process:
   unchanged when it names a D-Bus session bus, and otherwise with the per-user
   session bus for UID added. A watcher detached from a desktop session may have
   lost the variable, and notify-send cannot reach the desktop without it."
  (if (find-if (lambda (entry)
                 (let ((prefix "DBUS_SESSION_BUS_ADDRESS="))
                   (and (> (length entry) (length prefix))
                        (string= prefix entry :end2 (length prefix)))))
               environment)
      environment
      (cons (format nil "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/~D/bus" uid)
            (remove-if (lambda (entry)
                         (string= entry "DBUS_SESSION_BUS_ADDRESS="))
                       environment))))

(defun %deaf-file (watch type)
  "The file of TYPE beside the pid file of the watcher WATCH describes."
  (%detach-file (dw-stem watch) type))

(defun %reap-notifiers ()
  "Collect every notification process that has exited, without waiting on one
   that has not, so none is left behind as a zombie."
  (setf *notify-processes*
        (remove-if (lambda (process)
                     (unless (sb-ext:process-alive-p process)
                       (ignore-errors (sb-ext:process-close process))
                       t))
                   *notify-processes*)))

(defun %notify-deaf (watch elapsed-seconds)
  "Tell the operator, on this host's desktop, that the agent WATCH serves has
   left mail unread for ELAPSED-SECONDS. Never waits for the notification and
   never signals: a desktop that cannot be reached must not stop the watch.

   notify-send is started directly with its arguments as a list, never through
   a shell, so nothing in an agent or bus name is interpreted. Where it is not
   installed this says so in the log and does nothing more; the marker file is
   already written by then, so the leader still sees the episode."
  (let ((program (%find-on-path "notify-send")))
    (if (null program)
        (%warn "notify-send is not on PATH; the deafness alarm for ~A is in ~A only"
               (dw-self-id watch)
               (uiop:native-namestring (%deaf-file watch "deaf")))
        (multiple-value-bind (summary body)
            (%notify-text (dw-self-id watch) (dw-bus watch) elapsed-seconds)
          (handler-case
              (push (sb-ext:run-program program
                                        (list "--app-name=dsmr-bus-watch"
                                              "--urgency=critical"
                                              summary body)
                                        :wait nil :input nil :output nil :error nil
                                        :environment (%notify-environment
                                                      (sb-ext:posix-environ)
                                                      (sb-posix:getuid)))
                    *notify-processes*)
            (error (e)
              (%warn "could not run notify-send for the deafness alarm: ~A" e)))))))

(defun %write-deaf-marker (watch since)
  "Write the deafness marker for WATCH: one line naming when the unheard mail
   was written (SINCE, Unix seconds), the agent and the bus."
  (with-open-file (out (%deaf-file watch "deaf")
                       :direction :output :if-exists :supersede
                       :if-does-not-exist :create)
    (format out "since=~D agent=~A bus=~A~%"
            since (%field-token (dw-self-id watch))
            (%field-token (or (dw-bus watch) "default")))))

(defun %deaf-observe (now &rest observation)
  "Feed one OBSERVATION at NOW (Unix seconds) to the deafness rule and act on
   its answer: on a raise write the marker and then notify, on a clear remove
   the marker. Does nothing while the alarm is off.

   A marker that cannot be written is reported and the notification still goes
   out, since the operator hearing about the episode matters more than the file."
  (let ((watch *deaf-watch*))
    (when watch
      (multiple-value-bind (state action)
          (apply #'%deaf-step *deaf-state* now
                 :threshold (dw-threshold watch) observation)
        (setf *deaf-state* state)
        (case action
          (:raise
           (let ((since (deaf-state-unheard-since state)))
             (handler-case (%write-deaf-marker watch since)
               (error (e) (%warn "could not write the deafness marker: ~A" e)))
             (%notify-deaf watch (- now since))))
          (:clear
           (let ((marker (%deaf-file watch "deaf")))
             (when (probe-file marker) (delete-file marker)))))))))

(defun %deaf-guarded (thunk)
  "Call THUNK, reporting any error it signals once and returning. The deafness
   alarm rides on the poll loop, and a fault in it must never stop the watch."
  (handler-case (funcall thunk)
    (error (e)
      (let ((text (princ-to-string e)))
        (unless (equal text *deaf-last-warning*)
          (setf *deaf-last-warning* text)
          (%warn "deafness check failed: ~A" text))))))

(defun %deaf-parked-p (watch)
  "True while the park marker for WATCH exists."
  (and (probe-file (%deaf-file watch "parked")) t))

(defun %note-signal-line ()
  "Record that a wake or error line has just been written to the log, and
   whether anything was following the log to hear it. Called at the one place
   the detached watcher writes such a line, never for a diagnostic: a warning
   about a failed notification must not start an episode of its own."
  (let ((watch *deaf-watch*))
    (when watch
      (%deaf-guarded
       (lambda ()
         (%deaf-observe (%unix-time)
                        :readers (%log-readers (%deaf-file watch "log"))
                        :parked-p (%deaf-parked-p watch)
                        :line-written-p t))))))

(defun %deaf-sample ()
  "Take one deafness sample, at most once a second, from the poll loop of the
   detached watcher: who is following the log, whether the agent is parked, and
   when a listener last saved its read offset. Does nothing while the alarm is
   off, and never blocks or signals."
  (let ((watch *deaf-watch*)
        (now-rt (get-internal-real-time)))
    (when (and watch
               (or (null *deaf-last-sample*)
                   (>= (- now-rt *deaf-last-sample*)
                       internal-time-units-per-second)))
      (setf *deaf-last-sample* now-rt)
      (%deaf-guarded
       (lambda ()
         (%reap-notifiers)
         (let ((offset (probe-file (%deaf-file watch "offset"))))
           (%deaf-observe (%unix-time)
                          :readers (%log-readers (%deaf-file watch "log"))
                          :parked-p (%deaf-parked-p watch)
                          :offset-time (and offset
                                            (let ((date (file-write-date offset)))
                                              (and date (%unix-time date)))))))))))

(defun %arm-deafness-watch (self-id bus deaf-seconds)
  "Start watching this detached watcher's own log for unheard mail, or leave the
   alarm off when DEAF-SECONDS is 0. A marker left by an earlier watcher under
   this stem is removed, since the episode it recorded is not this watcher's
   to clear, and this watcher's marker is removed however it exits.

   Called only from the detached watcher, which holds the lock on its stem, so
   the stem is the current one and never resolved (see %RESOLVE-DETACH-STEM)."
  (let* ((stem (%detach-stem bus self-id))
         (marker (%detach-file stem "deaf")))
    (ignore-errors (when (probe-file marker) (delete-file marker)))
    (push marker *cleanup-paths*)
    (setf *deaf-state* (make-deaf-state)
          *deaf-watch* (and (plusp deaf-seconds)
                            (make-deaf-watch :self-id self-id :bus bus :stem stem
                                             :threshold deaf-seconds)))))

(defun %marker-since (path)
  "The Unix time recorded as `since=` in the marker file at PATH, or :UNKNOWN
   when the file cannot be read or carries no such field."
  (let* ((text (ignore-errors (uiop:read-file-string path)))
         (start (and text (search "since=" text))))
    (or (and start
             (ignore-errors
              (parse-integer text :start (+ start (length "since="))
                                  :junk-allowed t)))
        :unknown)))

(defun %park-targets (bus self-id all-buses-p)
  "The marker stems --park and --unpark act on, each paired with its bus: the
   one for SELF-ID on BUS, or with ALL-BUSES-P one for every bus SELF-ID has a
   detached watcher's pid file on."
  (if all-buses-p
      (loop for (pid-path . target-bus) in (%reap-targets bus self-id t)
            ;; The stem is cut from the native name rather than taken as the
            ;; pathname name, which would stop at a dot inside an agent name.
            collect (let ((name (uiop:native-namestring pid-path)))
                      (cons (subseq name (1+ (position #\/ name :from-end t))
                                    (- (length name) (length ".pid")))
                            target-bus)))
      (list (cons (%resolve-detach-stem bus self-id) bus))))

(defun %park (opts bus self-id parking)
  "Write the park marker for SELF-ID on BUS (or, with --all-buses, on every bus
   it has a detached watcher on) when PARKING, or remove it when not, then exit.

   The park step writes the marker before the agent stops listening, so the
   silence of a fleet takedown raises no deafness alarm, and bring-up removes it
   (--detach does so too). The watcher itself keeps running while parked.

   Prints one line per bus, `parked bus=<bus>` or `unparked bus=<bus>`, or
   `none bus=*` when --all-buses finds no watcher, and exits 0; 1 when a marker
   could not be written or removed. With no resolved identity it prints
   `unknown` and exits 2, as --check-live does."
  (unless self-id
    (%warn "~A needs a resolved identity (pass --agent with --namespace, or ~
            --agent-id); the park marker is keyed on it."
           (if parking "--park" "--unpark"))
    (format *standard-output* "unknown~%")
    (force-output *standard-output*)
    (uiop:quit 2))
  (let ((targets (%park-targets bus self-id (opt-all-buses-p opts)))
        (clean t))
    (if (null targets)
        (format *standard-output* "none bus=*~%")
        (loop for (stem . target-bus) in targets
              for marker = (%detach-file stem "parked")
              do (handler-case
                     (progn
                       (if parking
                           (progn
                             (ensure-directories-exist marker)
                             (with-open-file (out marker :direction :output
                                                         :if-exists :supersede
                                                         :if-does-not-exist :create)
                               (format out "since=~D~%" (%unix-time))))
                           (when (probe-file marker) (delete-file marker)))
                       (format *standard-output* "~:[unparked~;parked~] bus=~A~%"
                               parking (or target-bus "default")))
                   (error (e)
                     (%warn "could not ~:[remove~;write~] ~A: ~A" parking
                            (uiop:native-namestring marker) e)
                     (setf clean nil)))))
    (force-output *standard-output*)
    (uiop:quit (if clean 0 1))))

(defstruct (follower (:conc-name fol-))
  "One log being followed for --wake: where it lives, the stream held open on
   it, how far it has been read, which file that stream is on, and the bytes of
   a line not yet finished."
  (path nil)
  (stream nil)
  (pos 0)
  (ino nil)
  (dev nil)
  (partial (make-array 0 :element-type '(unsigned-byte 8)
                         :adjustable t :fill-pointer 0))
  (skip-p nil))

(defun %follow-open (fol from-end-p)
  "Open FOL's file and hold it. With FROM-END-P, reading starts at the current
   end, and a file that ends partway through a line has the rest of that line
   discarded when it arrives; otherwise reading starts at the top. Returns the
   stream, or NIL when the file cannot be opened."
  (let ((stream (ignore-errors
                 (open (fol-path fol) :element-type '(unsigned-byte 8)))))
    (when stream
      (let* ((stat (sb-posix:fstat (sb-sys:fd-stream-fd stream)))
             (size (sb-posix:stat-size stat)))
        (setf (fol-stream fol) stream
              (fol-ino fol) (sb-posix:stat-ino stat)
              (fol-dev fol) (sb-posix:stat-dev stat)
              (fill-pointer (fol-partial fol)) 0
              (fol-skip-p fol) nil
              (fol-pos fol) 0)
        (when (and from-end-p (plusp size))
          (file-position stream (1- size))
          (setf (fol-skip-p fol) (/= (read-byte stream) 10)
                (fol-pos fol) size))))
    stream))

(defun %follow-drain (fol)
  "The complete lines appended to FOL's open file since the last look, oldest
   first. A file that has shrunk below the read position was truncated, and is
   read again from the top."
  (let* ((stream (fol-stream fol))
         (size (sb-posix:stat-size (sb-posix:fstat (sb-sys:fd-stream-fd stream))))
         (partial (fol-partial fol))
         (lines '()))
    (when (< size (fol-pos fol))
      (setf (fol-pos fol) 0
            (fill-pointer partial) 0
            (fol-skip-p fol) nil))
    (when (> size (fol-pos fol))
      (let ((buffer (make-array (- size (fol-pos fol))
                                :element-type '(unsigned-byte 8))))
        (file-position stream (fol-pos fol))
        (let ((n (read-sequence buffer stream)))
          (incf (fol-pos fol) n)
          (dotimes (i n)
            (let ((byte (aref buffer i)))
              (if (= byte 10)
                  (progn
                    (if (fol-skip-p fol)
                        (setf (fol-skip-p fol) nil)
                        (push (sb-ext:octets-to-string
                               (coerce partial '(simple-array (unsigned-byte 8) (*)))
                               :external-format '(:utf-8 :replacement #\?))
                              lines))
                    (setf (fill-pointer partial) 0))
                  (vector-push-extend byte partial)))))))
    (nreverse lines)))

(defun %follow-lines (fol)
  "The complete lines appended to the log FOL follows since the last look,
   oldest first.

   A log that did not exist yet is opened from the top once it appears, since
   everything in it is new. A log replaced under the same name, as a rotation
   does, is read to its end first and then left for the new file, which is also
   read from the top."
  (let ((lines '()))
    (when (or (fol-stream fol) (%follow-open fol nil))
      (setf lines (%follow-drain fol))
      (let ((now (ignore-errors (sb-posix:stat (uiop:native-namestring
                                                 (fol-path fol))))))
        (when (and now (or (/= (sb-posix:stat-ino now) (fol-ino fol))
                           (/= (sb-posix:stat-dev now) (fol-dev fol))))
          (ignore-errors (close (fol-stream fol)))
          (setf (fol-stream fol) nil)
          (when (%follow-open fol nil)
            (setf lines (append lines (%follow-drain fol)))))))
    lines))

(defun %event-line-p (line)
  "True when LINE is one a woken agent acts on: a wake or an error. The same
   lines the monitor command filters for."
  (or (eql 0 (search "bus:" line)) (eql 0 (search "error:" line))))

(defun %wake-wait (targets poll-ms
                   &key (watcher-alive-p (lambda (pid-path)
                                           (and (%live-detached-pid pid-path) t)))
                        deadline-ms)
  "Wait for the next event line in any of TARGETS and return (values :event
   line bus), or (values :no-watcher nil bus) naming the first bus whose
   detached watcher is not running. Each target is a list (bus log-path
   pid-path). DEADLINE-MS, when given, is a limit in milliseconds after which
   this returns :timeout.

   Every log is read from its end as it stands when this starts, so a line
   already there is never reported again. A watcher that is not running is
   reported at once, and again if it stops while this waits: a wait on a log
   nothing will ever write to again never ends, and the agent running it would
   be as deaf as one running nothing."
  (flet ((dead-bus ()
           (loop for (bus nil pid-path) in targets
                 unless (funcall watcher-alive-p pid-path)
                   return (values t bus))))
    (multiple-value-bind (dead bus) (dead-bus)
      (when dead (return-from %wake-wait (values :no-watcher nil bus))))
    (let ((followers (loop for (bus log-path) in targets
                           collect (let ((fol (make-follower :path log-path)))
                                     (%follow-open fol t)
                                     (cons bus fol))))
          (sleep-s (/ (max poll-ms 1) 1000.0))
          (limit (and deadline-ms (+ (now-ms) deadline-ms))))
      (unwind-protect
           (loop
             (loop for (bus . fol) in followers
                   do (let ((line (find-if #'%event-line-p (%follow-lines fol))))
                        (when line
                          (return-from %wake-wait (values :event line bus)))))
             (multiple-value-bind (dead bus) (dead-bus)
               (when dead (return-from %wake-wait (values :no-watcher nil bus))))
             (when (and limit (>= (now-ms) limit))
               (return-from %wake-wait (values :timeout nil nil)))
             (sleep sleep-s))
        (dolist (entry followers)
          (let ((stream (fol-stream (cdr entry))))
            (when stream (ignore-errors (close stream)))))))))

(defun %wake-targets (bus self-id all-buses-p)
  "What --wake waits on, as (bus log-path pid-path) lists: the detached log for
   SELF-ID on BUS, or with ALL-BUSES-P the log of every detached watcher this
   agent has a pid file for. A bus whose watcher was reaped has no pid file and
   is left out, so a bus the agent has left cannot hold the wait hostage."
  (if all-buses-p
      (loop for (pid-path . target-bus) in (%reap-targets bus self-id t)
            collect (list target-bus
                          (make-pathname :type "log" :defaults pid-path)
                          pid-path))
      (let ((stem (%resolve-detach-stem bus self-id)))
        (list (list bus (%detach-file stem "log") (%detach-file stem "pid"))))))

(defun %wake-deadline-ms (wake-seconds)
  "The wait limit for --wake in milliseconds, or NIL for no limit when
   WAKE-SECONDS is zero."
  (and (plusp wake-seconds) (* 1000 wake-seconds)))

(defun %idle-line (wake-seconds)
  "The line --wake prints when WAKE-SECONDS pass with nothing arriving."
  (format nil "idle wake-seconds=~D" wake-seconds))

(defun %wake (opts bus self-id)
  "Block until the next event line reaches this agent's detached log, print it
   and exit 0. With --all-buses, whichever of the agent's logs gets one first.

   When --wake-seconds pass with nothing arriving, prints `idle
   wake-seconds=<N>` and exits 0. The agent runs this as a background command,
   and its runner kills a background command at a fixed ceiling and tells the
   agent not to start it again, which leaves the agent deaf on a quiet bus.
   Returning on our own before that ceiling means the agent sees an ordinary
   completion and re-arms the way it does after any wake. A limit of 0 waits
   for ever.

   When a bus asked for has no detached watcher running, prints
   `nowatcher bus=<bus>` and exits 1 straight away, so the agent starts one
   with --detach instead of waiting on a log nothing writes to. Exits 2 when no
   identity resolves, and 143 on SIGTERM."
  (unless self-id
    (%warn "--wake needs a resolved identity (pass --agent with --namespace, or ~
            --agent-id); the detached log is keyed on it.")
    (uiop:quit 2))
  (%install-termination-handler)
  (let ((targets (%wake-targets bus self-id (opt-all-buses-p opts)))
        (wake-seconds (opt-wake-seconds opts)))
    (flet ((no-watcher (label)
             (%warn "no detached watcher is running for ~A on bus ~A; start one ~
                     with --detach, then wake again"
                    self-id label)
             (format *standard-output* "nowatcher bus=~A~%" label)
             (force-output *standard-output*)
             (uiop:quit 1))
           (say-and-exit (text)
             (format *standard-output* "~A~%" text)
             (force-output *standard-output*)
             (uiop:quit 0)))
      (when (null targets)
        (no-watcher "*"))
      (multiple-value-bind (outcome line which)
          (%wake-wait targets (opt-poll-ms opts)
                      :deadline-ms (%wake-deadline-ms wake-seconds))
        (case outcome
          (:event (say-and-exit line))
          (:timeout (say-and-exit (%idle-line wake-seconds)))
          (t (no-watcher (or which "default"))))))))

(defun main ()
  "Entry point. Parse argv, resolve who this watch is for, arm a baseline, and
   watch; or, under --check-live, report the running watch's heartbeat and exit
   without watching. Signal lines go to *standard-output*; usage, diagnostics,
   and errors go to *error-output*. Exit 0 on a fired/recycled watch or a live
   heartbeat, 1 on a stale/absent heartbeat, 2 on a liveness probe with no
   resolvable identity, 64 on an unrecoverable failure, 75 when the watch
   wedged, and 143 on SIGTERM. A bad flag is not an unrecoverable failure, and
   neither is an unresolvable identity for a watch; an unusable bus name is,
   because the alternative is a watch armed on a bus nobody is talking on.

   --detach and --reap start and stop a detached watcher and exit; neither
   watches in this process. The detached watcher itself runs this same entry
   point with --detached-child, claims its pid file before anything else, and
   then streams and re-arms in place for as long as it lives. --wake follows
   that watcher's log until its next event line and exits, and writes no
   heartbeat of its own, since the beat it would write is the watcher's.

   Which bus this watch arms on is resolved first, and every default path below
   hangs off it: the write-ahead log it reads, the cursor it arms from, and the
   heartbeat it advertises itself with. An explicit --wal or --cursors-dir still
   wins, so the overrides an operator already uses keep working.

   The heartbeat is written under the watch's own identity: while the watch runs
   it refreshes a beat file every poll, and it is removed on fire, recycle,
   error, SIGTERM and a stall, so an absent beat means `not running` and a stale
   one means `died without cleaning up`. A detached watcher keeps its beat across
   its in-place re-arms, so a probe never catches it between cycles and reads
   `dead`. With no identity resolved there is no stable key to write a beat
   under, so the watch runs without one; --check-live says so rather than
   pretending otherwise."
  (handler-case
      (let* ((args (uiop:command-line-arguments))
             (opts (%parse-args args)))
        (when (opt-help-p opts)
          (%usage)
          (uiop:quit 0))
        (let* ((bus (%resolve-bus opts))
               (wal-path (if (opt-wal opts)
                             (pathname (opt-wal opts))
                             (default-wal-path bus)))
               (cursors-dir (if (opt-cursors-dir opts)
                                (uiop:ensure-directory-pathname (opt-cursors-dir opts))
                                (default-cursors-dir bus)))
               (watch-dir (default-watch-dir bus))
               (self-id (%resolve-self-id opts))
               (beat-path (and self-id (heartbeat:beat-path self-id watch-dir))))
          (when (opt-check-p opts)
            (%check-live self-id beat-path (opt-live-window-seconds opts) bus))
          (when (opt-park-p opts)
            (%park opts bus self-id t))
          (when (opt-unpark-p opts)
            (%park opts bus self-id nil))
          (when (opt-reap-p opts)
            (%reap opts bus self-id))
          (when (opt-wake-p opts)
            (%wake opts bus self-id))
          (when (and (opt-detach-p opts) (not (opt-detached-child-p opts)))
            (%detach bus self-id args))
          (%install-termination-handler)
          (when (opt-detached-child-p opts)
            (ignore-errors (sb-posix:setsid))
            (sb-sys:enable-interrupt sb-posix:sighup :ignore)
            ;; The child always claims the current stem; only callers looking
            ;; for an existing watcher adopt an older one.
            (let ((pid-path (%detach-file (%detach-stem bus self-id) "pid")))
              (unless (%claim-pid-file pid-path self-id)
                (%warn "another detached watcher already holds ~A; exiting"
                       (uiop:native-namestring pid-path))
                (uiop:quit 0))
              (push pid-path *cleanup-paths*)
              (%arm-deafness-watch self-id bus (opt-deaf-seconds opts))
              (%warn "detached watcher pid ~D armed for ~A on bus ~A"
                     (sb-posix:getpid) self-id (or bus "default"))))
          (when beat-path (push beat-path *cleanup-paths*))
          (let* ((baseline (%resolve-baseline opts self-id wal-path cursors-dir))
                 (poll-ms (opt-poll-ms opts))
                 (recycle-seconds (opt-recycle-seconds opts))
                 (mode (if (opt-stream-p opts) :stream :event)))
            (%start-stall-watchdog
             (%effective-stall-seconds (opt-stall-seconds opts) poll-ms))
            (flet ((beat ()
                     (%note-poll)
                     ;; Does nothing outside the detached watcher.
                     (%deaf-sample)
                     (when beat-path
                       (heartbeat:write-beat beat-path :mode mode :baseline baseline
                                                       :poll-ms poll-ms))))
              (unwind-protect
                   (cond
                     ((opt-detached-child-p opts)
                      (%run-detached opts wal-path cursors-dir self-id baseline
                                     #'beat))
                     ((opt-stream-p opts)
                      (watch-stream wal-path baseline
                                    :poll-ms poll-ms :recycle-seconds recycle-seconds
                                    :self-id self-id :on-poll #'beat)
                      (%warn "recycle: idle window elapsed; exiting for supervised re-arm"))
                     (t
                      (let ((fired (watch-until-foreign wal-path baseline
                                                        :poll-ms poll-ms
                                                        :recycle-seconds recycle-seconds
                                                        :self-id self-id
                                                        :on-poll #'beat)))
                        (if fired (%signal-seq fired) (%signal-recycle)))))
                (%emergency-cleanup)))
            (uiop:quit 0))))
    (error (e)
      (format *error-output* "dsmr-bus-watch: ~A~%" e)
      (%usage)
      (uiop:quit 64))))
