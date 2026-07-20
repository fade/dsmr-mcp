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
           #:ensure-bus-dirs #:reap-orphaned-cursors
           #:broker #:broker-seq
           #:start-broker #:broker-step #:serve-broker #:stop-broker
           #:join-members
           #:broker-running-p #:broker-main #:spawn-broker #:ensure-broker))

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

(defun %ephemeral-name-p (name)
  "True iff NAME is an auto-generated ephemeral agent name — g<digits>-<digits>,
   the shape the envelope leaf builds for an id given no stable name. The match
   is exact rather than a prefix: a stable name that merely starts with a g, or
   carries a dash in some other position, must not answer true."
  (let ((len (length name)))
    (and (> len 3)
         (char= (char name 0) #\g)
         (let ((dash (position #\- name :start 1)))
           (and dash
                (> dash 1)
                (< (1+ dash) len)
                (every #'digit-char-p (subseq name 1 dash))
                (every #'digit-char-p (subseq name (1+ dash))))))))

(defun %ephemeral-cursor-name-p (filename)
  "True iff FILENAME is the cursor file of an ephemeral agent. A cursor is named
   by percent-encoding the whole <namespace>/<name> id, and the encoding's safe
   alphabet covers letters, digits and the dash — so the name survives verbatim
   after the encoded separator, and matching the encoded tail is exact.

   No decoder is involved on purpose: the encoding has no inverse here, and
   writing one would add edge cases to answer a question the tail already
   answers."
  (let* ((separator "%2F")
         (pos (search separator filename :from-end t)))
    (%ephemeral-name-p (if pos
                           (subseq filename (+ pos (length separator)))
                           filename))))

(defun reap-orphaned-cursors (paths &key (max-age-days 7))
  "Delete long-dead ephemeral cursors under PATHS' cursor directory and return
   how many were removed. One cursor is written per subagent session, so the
   directory otherwise grows for the life of the bus.

   A file is removed only when BOTH its name has the ephemeral shape AND it has
   not been written in MAX-AGE-DAYS. Both conditions are required and neither
   may be dropped. Age alone would take a stable identity's cursor whenever that
   identity stayed dormant a while, discarding a real backlog it was entitled to
   walk forward. Shape alone would never terminate, since it would take a live
   subagent's cursor the moment a broker happened to restart.

   A mistake in the conservative direction is cheap: a wrongly-reaped ephemeral
   simply starts again at the log head, which is where a participant that has
   never read starts anyway. A mistake in the other direction destroys delivery
   state a consumer is still using, which is why the count is reported rather
   than the removal being silent.

   Nothing here may abort a broker coming up: a file that cannot be examined or
   removed is named on stderr and skipped, and a directory that cannot be
   scanned at all yields a count of zero."
  (let ((reaped 0))
    (handler-case
        (let ((cutoff (- (get-universal-time)
                         (* max-age-days 24 60 60))))
          (dolist (file (uiop:directory-files (bus-paths-cursors-dir paths)))
            (handler-case
                (when (and (%ephemeral-cursor-name-p (file-namestring file))
                           (let ((written (file-write-date file)))
                             (and written (< written cutoff))))
                  (delete-file file)
                  (incf reaped))
              (error (e)
                (format *error-output*
                        "dsmr-mcp bus: skipping cursor ~A during reap: ~A~%"
                        file e)))))
      (error (e)
        (format *error-output*
                "dsmr-mcp bus: could not scan the cursor directory to reap: ~A~%"
                e)))
    (when (plusp reaped)
      (format *error-output*
              "dsmr-mcp bus: reaped ~D orphaned ephemeral cursor~:P older than ~D day~:P~%"
              reaped max-age-days))
    reaped))

;;; --------------------------------------------------------------- broker

(defstruct (broker (:constructor %make-broker))
  paths lock-fd members-fd intake publisher (seq 0))

(defun start-broker (paths &key (block t) (intake-timeout-ms 100) (join t))
  "Contend for the broker role on PATHS. If another broker holds it and BLOCK is
   true, wait until it dies and take over; if BLOCK is false and the role is
   taken, return NIL. On winning: recover the log (truncating any torn tail) to
   learn the next seq, optionally JOIN membership, and bind the intake and
   publisher sockets. Returns a BROKER.

   Also reaps long-dead ephemeral cursors, once per broker process. The broker
   already owns the cursor directory's lifecycle, and this is the one place
   that runs rarely enough for the sweep to cost nothing."
  (ensure-bus-dirs paths)
  (reap-orphaned-cursors paths)
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

;;; ------------------------------------------------------- process lifecycle

(defun broker-running-p (paths)
  "True iff a broker currently holds the election lock — probed by trying to take
   it non-blocking and immediately releasing on success. Inherently racy against a
   broker starting up, so the authoritative election still happens in the broker
   itself; this only spares the common case a redundant spawn."
  (ensure-bus-dirs paths)
  (let ((fd (election:open-lock (bus-paths-lock paths))))
    (unwind-protect
         (if (election:try-lock-exclusive fd)
             (progn (election:unlock fd) nil)
             t)
      (election:close-lock fd))))

(defvar *broker-stop* nil
  "Set by the broker process's SIGTERM handler to break its serve loop.")

(defun broker-main (root &key (block t))
  "Entry point for a detached broker PROCESS. Elects on the bus rooted at ROOT
   (a string or pathname); with BLOCK it waits as a standby to take over on the
   incumbent's death, without BLOCK it exits 0 if the role is already taken.
   Serves until SIGTERM, then archives on clean exit. SIGHUP is ignored so the
   broker outlives the agent that spawned it."
  (let* ((paths (make-bus-paths (uiop:ensure-directory-pathname root)))
         (br (start-broker paths :block block)))
    (unless br (uiop:quit 0))
    (setf *broker-stop* nil)
    (sb-sys:enable-interrupt sb-unix:sighup :ignore)
    (sb-sys:enable-interrupt sb-unix:sigterm
                             (lambda (&rest _) (declare (ignore _)) (setf *broker-stop* t)))
    (unwind-protect (serve-broker br (lambda () *broker-stop*))
      (stop-broker br :archive t))
    (uiop:quit 0)))

(defun %broker-spawn-args (root &key (block t))
  "The sbcl command line for a detached broker process. Loads only the broker
   subsystem (lighter than the full server) plus its pzmq dependency."
  (let ((sbcl (or (uiop:getenv "SBCL") "sbcl"))
        (project (namestring (asdf:system-source-directory "dsmr-mcp")))
        (ql (namestring (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))))
    (list sbcl "--non-interactive" "--disable-debugger"
          "--eval" (format nil "(when (probe-file ~S) (load ~S))" ql ql)
          "--eval" (format nil "(asdf:initialize-source-registry '(:source-registry (:directory ~S) :inherit-configuration))"
                           project)
          "--eval" "(funcall (read-from-string \"ql:quickload\") \"dsmr-mcp/src/bus/broker\" :silent t)"
          "--eval" (format nil "(funcall (read-from-string \"dsmr-mcp/src/bus/broker:broker-main\") ~S :block ~:[nil~;t~])"
                           (namestring (uiop:ensure-directory-pathname root)) block))))

(defun spawn-broker (paths &key (block t))
  "Launch a detached broker process serving the bus at PATHS, logging to
   broker.log in the bus directory. Returns the uiop process handle (the caller
   need not wait on it)."
  (ensure-bus-dirs paths)
  (uiop:launch-program (%broker-spawn-args (bus-paths-root paths) :block block)
                       :output (merge-pathnames "broker.log" (bus-paths-root paths))
                       :error-output :output))

(defun ensure-broker (paths)
  "Make sure a broker is serving the bus at PATHS. Returns :EXISTS if one already
   holds the role, or :SPAWNED after launching one. The spawned process self-
   elects, so a lost startup race just exits cleanly rather than double-serving."
  (if (broker-running-p paths)
      :exists
      (progn (spawn-broker paths :block nil) :spawned)))
