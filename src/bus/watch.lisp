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
;;;; carries no ZeroMQ/broker code.
;;;;
;;;; Self-wake is avoided without any on-disk change: the watcher seeds a BASELINE
;;;; sequence number at arm time and fires only on a strictly greater seq. The
;;;; agent re-arms the watcher AFTER it publishes, so its own just-sent message is
;;;; already in the baseline and never wakes it. Because the baseline is read at
;;;; arm time and the check is level-triggered, a message that lands between
;;;; "scan" and "first poll" is not lost.

(defpackage #:dsmr-bus-watch/src/bus/watch
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/bus/wal #:scan #:now-ms)
  (:export #:main
           #:watch-until-foreign
           #:watch-stream
           #:poll-new
           #:default-wal-path))

(in-package #:dsmr-bus-watch/src/bus/watch)

;;; -------------------------------------------------------------- default path

(defun default-wal-path ()
  "The default bus WAL path: $XDG_STATE_HOME/dsmr-mcp/bus/bus.wal (falling back
   to ~/.local/state/dsmr-mcp/bus/bus.wal). Inlined from the broker's
   default-state-root so this binary never has to depend on broker.lisp (which
   would drag in the ZeroMQ transport)."
  (let* ((xdg (uiop:getenv "XDG_STATE_HOME"))
         (root (merge-pathnames
                "dsmr-mcp/bus/"
                (if (and xdg (plusp (length xdg)))
                    (uiop:ensure-directory-pathname xdg)
                    (merge-pathnames ".local/state/" (user-homedir-pathname))))))
    (merge-pathnames "bus.wal" root)))

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
   log. Read-only — never clips an in-flight broker write."
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
to STDERR. Re-arm AFTER you publish so your own message stays below the baseline.

Options:
  --wal PATH           WAL file to watch (default: $XDG_STATE_HOME/dsmr-mcp/bus/bus.wal)
  --after SEQ          baseline seq; fire on the first seq > SEQ
                       (default: the WAL's current max seq, read at arm time;
                        0 = fire on any record)
  --stream             stream one line per new seq and keep running
                       (for a persistent monitor); default is exit-on-event
  --poll-ms N          poll interval in milliseconds (default 1000)
  --recycle-seconds N  idle self-recycle window in seconds (default 600)
  -h, --help           print this help and exit

Exit-on-event prints one `bus:<SEQ>` line then exits 0; on idle recycle it
prints `recycle:` then exits 0. Streaming prints `bus:<SEQ>` per new seq.
")

(defun %usage (&optional (stream *error-output*))
  (write-string +usage+ stream)
  (force-output stream))

(defun %parse-nonneg (string flag)
  "Parse STRING as a non-negative integer for FLAG, or signal a usage error."
  (multiple-value-bind (n end)
      (ignore-errors (parse-integer string :junk-allowed nil))
    (unless (and n (= end (length string)) (>= n 0))
      (error "~A expects a non-negative integer, got ~S" flag string))
    n))

(defun %parse-args (args)
  "Parse ARGS into (values wal after stream-p poll-ms recycle-seconds help-p).
   WAL is NIL when unspecified (caller substitutes the default); AFTER is NIL
   when unspecified (caller seeds from the WAL). Signals on malformed input."
  (let ((wal nil) (after nil) (stream-p nil)
        (poll-ms 1000) (recycle-seconds 600) (help-p nil))
    (loop with rest = args
          while rest
          for arg = (pop rest)
          do (cond
               ((or (string= arg "-h") (string= arg "--help"))
                (setf help-p t))
               ((string= arg "--stream")
                (setf stream-p t))
               ((string= arg "--wal")
                (unless rest (error "--wal requires a PATH argument"))
                (setf wal (pop rest)))
               ((string= arg "--after")
                (unless rest (error "--after requires a SEQ argument"))
                (setf after (%parse-nonneg (pop rest) "--after")))
               ((string= arg "--poll-ms")
                (unless rest (error "--poll-ms requires an N argument"))
                (setf poll-ms (%parse-nonneg (pop rest) "--poll-ms")))
               ((string= arg "--recycle-seconds")
                (unless rest (error "--recycle-seconds requires an N argument"))
                (setf recycle-seconds (%parse-nonneg (pop rest) "--recycle-seconds")))
               (t (error "unknown argument: ~S" arg))))
    (values wal after stream-p poll-ms recycle-seconds help-p)))

(defun main ()
  "Entry point. Parse argv, seed a baseline, and watch. Signal lines go to
   *standard-output*; usage, diagnostics, and errors go to *error-output*.
   Exit 0 on a fired/recycled watch, 64 on a usage error."
  (handler-case
      (multiple-value-bind (wal after stream-p poll-ms recycle-seconds help-p)
          (%parse-args (uiop:command-line-arguments))
        (when help-p
          (%usage)
          (uiop:quit 0))
        (let* ((wal-path (if wal (pathname wal) (default-wal-path)))
               (baseline (or after (%last-seq wal-path))))
          (if stream-p
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
