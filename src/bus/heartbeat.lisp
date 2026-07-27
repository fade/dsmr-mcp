;;;; src/bus/heartbeat.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; The watcher heartbeat: how a running bus watch advertises that it is still
;;;; listening, and how a probe reads that advertisement back.
;;;;
;;;; A watch that has gone silently deaf looks, from outside, exactly like one
;;;; still doing its job: exit-on-event exits 0 after it fires, byte for byte the
;;;; same exit as a watch that never fired at all, so a dead watch and a live one
;;;; are indistinguishable from their exit alone. The heartbeat closes that gap.
;;;; While the watch runs it rewrites a small file once per poll; that file's
;;;; MTIME is the liveness signal — a live watch keeps it within one poll of now,
;;;; a dead one lets it age without bound. On any clean exit (fire, recycle, or
;;;; error) the file is removed, so an absent beat reads as "not running" rather
;;;; than "stale". The contents are diagnostics only; nothing keys off them, and
;;;; a beat that cannot be written is dropped rather than allowed to take the
;;;; watch down.
;;;;
;;;; This is a leaf. It uses #:cl and the ZeroMQ-free envelope leaf (for the id
;;;; encoding the beat filename is keyed on), and nothing else. The standalone
;;;; watcher binary WRITES the beat and the MCP core READS it, so the two must
;;;; agree on the filename and format byte for byte — one implementation shared
;;;; between writer and reader is exactly what keeps them from drifting. Pulling
;;;; the ZeroMQ transport in here would break the watcher, which deliberately
;;;; links no libzmq.

(require :sb-posix)

(defpackage #:dsmr-mcp/src/bus/heartbeat
  (:use #:cl)
  (:local-nicknames (#:envelope #:dsmr-mcp/src/bus/envelope)
                    (#:selector #:dsmr-mcp/src/bus/selector))
  (:export #:default-watch-dir
           #:beat-path
           #:write-beat
           #:remove-beat
           #:beat-status
           #:beat-liveness
           #:+default-live-window-seconds+))

(in-package #:dsmr-mcp/src/bus/heartbeat)

(defconstant +default-live-window-seconds+ 5
  "How fresh a heartbeat must be, in seconds, to count as live. A live watch
   refreshes its beat every poll, so this need only exceed the poll interval with
   some slack. The single source of truth for the freshness window: the watcher's
   --check-live default and the MCP core's own liveness read both take it from
   here, so the writer's cadence and every reader's window can never drift apart.")

(defun default-watch-dir (&optional bus)
  "The watcher-heartbeat directory: watch/ under the state root for BUS, or
   under the unnamed root when BUS is nil.

   The root comes from the shared selector leaf, which imports nothing beyond cl
   and uiop. That is what keeps the watcher binary free of the ZeroMQ transport,
   so a sister repo needs no libzmq to arm a watch."
  (merge-pathnames "watch/" (selector:bus-root bus)))

(defun beat-path (self-id watch-dir)
  "The heartbeat file for SELF-ID under WATCH-DIR. Keyed on the SAME encoded id
   the cursor path uses, so the name a running watch writes and the name a
   --check-live probe (or the MCP core's liveness read) reads are identical byte
   for byte."
  (merge-pathnames (concatenate 'string (envelope:encode-id self-id) ".beat")
                   (uiop:ensure-directory-pathname watch-dir)))

(defun write-beat (path &key mode baseline poll-ms)
  "Refresh the heartbeat at PATH: rewrite it with a single readable diagnostic
   plist and let its MTIME advance. Called at the top of every poll, so a live
   watch keeps the file within one poll interval of now.

   Wrapped in IGNORE-ERRORS deliberately: a beat-write failure — a full disk, a
   vanished directory — must never take the watcher down, and must never leak a
   line onto *standard-output*, where it would be read as a wake signal. A
   dropped beat costs one poll of liveness resolution; an unhandled error would
   cost the watch."
  (ignore-errors
   (ensure-directories-exist path)
   (with-open-file (out path :direction :output
                             :if-exists :supersede
                             :if-does-not-exist :create)
     (prin1 (list :pid (sb-posix:getpid)
                  :mode mode
                  :baseline baseline
                  :poll-ms poll-ms)
            out)))
  (values))

(defun remove-beat (path)
  "Remove the heartbeat at PATH if present. Called on every clean exit so an
   absent beat reads as `not running` rather than `stale`. Best-effort: a
   failure to unlink is never worth signalling over."
  (ignore-errors (when (probe-file path) (delete-file path))))

(defun beat-status (age-seconds window-seconds)
  "The liveness verdict for a beat AGE-SECONDS old measured against
   WINDOW-SECONDS: :LIVE when at or within the window, :STALE when past it.
   Factored out of BEAT-LIVENESS so the threshold is unit-testable directly,
   without arranging a file of a controlled age."
  (if (<= age-seconds window-seconds) :live :stale))

(defun beat-liveness (path window-seconds)
  "Read the heartbeat at PATH and classify it. Returns (VALUES STATUS AGE PID):

     :DEAD  — no file, or nothing readable there (AGE and PID both NIL)
     :LIVE  — the beat is at most WINDOW-SECONDS old
     :STALE — the beat is older than that

   Age is (now - file-write-date) in whole seconds, matching FILE-WRITE-DATE's
   one-second resolution: a live watch refreshes every poll so its beat is about
   a second old at most, a dead one grows without bound, and the window separates
   the two with room to spare. PID is read best-effort from the file's plist for
   the diagnostic line; a beat present but unreadable as a plist still counts by
   its age, just without a pid to name."
  (let ((mtime (ignore-errors (file-write-date path))))
    (if (null mtime)
        (values :dead nil nil)
        (let ((age (- (get-universal-time) mtime))
              (pid (ignore-errors
                    (with-open-file (in path :if-does-not-exist nil)
                      (getf (and in (read in nil nil)) :pid)))))
          (values (beat-status age window-seconds) age pid)))))
