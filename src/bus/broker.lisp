;;;; src/bus/broker.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; The bus broker: the single elected process that owns the write-ahead log.
;;;; Everything the earlier modules built meets here. The broker
;;;;
;;;;   1. wins the flock election (or blocks until the incumbent dies),
;;;;   2. recovers the log — replaying and truncating any torn tail a crashed
;;;;      predecessor left — to learn the next sequence number,
;;;;   3. binds the ZeroMQ intake (PULL) and fan-out (PUB) sockets, then
;;;;   4. loops: receive a submission, append it to the log under the next seq,
;;;;      and publish a nudge so live subscribers wake.
;;;;
;;;; Because the broker is the SOLE writer, the sequence stays strictly monotonic
;;;; and a successor can rebuild all state by replaying the log — no consensus.
;;;; On a clean shutdown the broker, if it is the last member out, rotates the log
;;;; to an archive; a crash skips that path and leaves the log for the next broker.
;;;;
;;;; This file provides the broker as composable steps (START-BROKER / BROKER-STEP
;;;; / STOP-BROKER) plus a SERVE-BROKER loop, so it can run in a thread under test
;;;; and as a detached process in production. BUS-PATHS centralises the on-disk
;;;; and socket layout under the bus state directory shared with the facade.

(defpackage #:dsmr-mcp/src/bus/broker
  (:use #:cl)
  (:local-nicknames (#:wal #:dsmr-mcp/src/bus/wal)
                    (#:election #:dsmr-mcp/src/bus/election)
                    (#:archive #:dsmr-mcp/src/bus/archive)
                    (#:tz #:dsmr-mcp/src/bus/zmq))
  (:export #:bus-paths #:make-bus-paths #:default-state-root
           #:bus-paths-root #:bus-paths-wal #:bus-paths-lock #:bus-paths-members
           #:bus-paths-cursors-dir #:bus-paths-submit-endpoint #:bus-paths-pub-endpoint
           #:ensure-bus-dirs
           #:broker #:broker-seq
           #:start-broker #:broker-step #:serve-broker #:stop-broker
           #:join-members))

(in-package #:dsmr-mcp/src/bus/broker)

;;; --------------------------------------------------------------- paths

(defun default-state-root ()
  "The default bus state directory: $XDG_STATE_HOME/dsmr-mcp/bus/ (falling back
   to ~/.local/state/dsmr-mcp/bus/). Survives a reboot."
  (let ((xdg (uiop:getenv "XDG_STATE_HOME")))
    (merge-pathnames "dsmr-mcp/bus/"
                     (if (and xdg (plusp (length xdg)))
                         (uiop:ensure-directory-pathname xdg)
                         (merge-pathnames ".local/state/" (user-homedir-pathname))))))

(defstruct (bus-paths (:constructor %make-bus-paths))
  root wal lock members cursors-dir submit-endpoint pub-endpoint)

(defun %ipc (root name)
  (format nil "ipc://~A~A" (namestring root) name))

(defun make-bus-paths (&optional (root (default-state-root)))
  "Derive every on-disk and socket path for a bus rooted at ROOT."
  (let ((root (uiop:ensure-directory-pathname root)))
    (%make-bus-paths
     :root root
     :wal (merge-pathnames "bus.wal" root)
     :lock (merge-pathnames "broker.lock" root)
     :members (merge-pathnames "members" root)
     :cursors-dir (merge-pathnames "cursors/" root)
     :submit-endpoint (%ipc root "submit.ipc")
     :pub-endpoint (%ipc root "pub.ipc"))))

(defun ensure-bus-dirs (paths)
  "Create the bus root and cursors directory if absent."
  (ensure-directories-exist (bus-paths-root paths))
  (ensure-directories-exist (bus-paths-cursors-dir paths))
  paths)

(defun join-members (paths)
  "Take a shared membership lock for this process's lifetime and return its fd.
   Used by clients, subscribers, and the broker alike; the last holder out is the
   one that archives on a clean shutdown."
  (let ((fd (election:open-lock (bus-paths-members paths))))
    (election:lock-shared fd)
    fd))

;;; --------------------------------------------------------------- broker

(defstruct (broker (:constructor %make-broker))
  paths lock-fd members-fd intake publisher (seq 0))

(defun start-broker (paths &key (block t) (intake-timeout-ms 100) (join t))
  "Contend for the broker role on PATHS. If another broker holds it and BLOCK is
   true, wait until it dies and take over; if BLOCK is false and the role is
   taken, return NIL. On winning: recover the log (truncating any torn tail) to
   learn the next seq, optionally JOIN membership, and bind the intake and
   publisher sockets. Returns a BROKER."
  (ensure-bus-dirs paths)
  (let ((lock-fd (election:open-lock (bus-paths-lock paths))))
    (cond
      ((election:try-lock-exclusive lock-fd))      ; won immediately
      (block (election:await-broker lock-fd))      ; wait out the incumbent
      (t (election:close-lock lock-fd)
         (return-from start-broker nil)))
    (let* ((seq (wal:recovery-last-seq (wal:recover (bus-paths-wal paths))))
           (members-fd (when join (join-members paths)))
           (intake (tz:make-intake (bus-paths-submit-endpoint paths)
                                   :timeout-ms intake-timeout-ms))
           (publisher (tz:make-publisher (bus-paths-pub-endpoint paths))))
      (%make-broker :paths paths :lock-fd lock-fd :members-fd members-fd
                    :intake intake :publisher publisher :seq seq))))

(defun broker-step (broker)
  "Receive at most one submission (bounded by the intake's timeout), append it to
   the log under the next sequence number, and publish a nudge carrying that seq.
   Returns the appended seq, or NIL if nothing arrived this step."
  (let ((msg (tz:recv-message (broker-intake broker))))
    (when msg
      (let ((seq (incf (broker-seq broker))))
        (wal:append-record (bus-paths-wal (broker-paths broker)) seq msg)
        (tz:send-message (broker-publisher broker) (princ-to-string seq))
        seq))))

(defun serve-broker (broker stop-fn)
  "Run BROKER-STEP until STOP-FN returns true. Returns the broker."
  (loop until (funcall stop-fn) do (broker-step broker))
  broker)

(defun stop-broker (broker &key (archive t))
  "Shut the broker down cleanly: optionally, if it is the last member out, rotate
   the log to an archive; then close the sockets and release the locks. Only ever
   called from a deliberate shutdown path, so a crash never archives."
  (when (and archive (broker-members-fd broker))
    (archive:archive-on-clean-exit (broker-members-fd broker)
                                   (bus-paths-wal (broker-paths broker))
                                   (bus-paths-root (broker-paths broker))))
  (when (broker-intake broker) (tz:close-endpoint (broker-intake broker)))
  (when (broker-publisher broker) (tz:close-endpoint (broker-publisher broker)))
  (when (broker-members-fd broker)
    (ignore-errors (election:close-lock (broker-members-fd broker))))
  (when (broker-lock-fd broker)
    (ignore-errors (election:close-lock (broker-lock-fd broker))))
  (values))
