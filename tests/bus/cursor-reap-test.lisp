;;;; tests/bus/cursor-reap-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Zebra tests for the broker's cursor-directory reap. The contract has two
;;;; halves and the second is the load-bearing one: aged ephemeral cursors are
;;;; removed, and a stable identity's cursor is not removable at any age.
;;;;
;;;; Every filename here is built by running a real id through the real encoder.
;;;; A hand-written percent-encoded literal would keep passing after an encoder
;;;; change, leaving the suite green precisely when the shape match had stopped
;;;; matching anything.

(require :sb-posix)

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/bus/cursor-reap-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/bus/cursor-reap-test
  (:use #:cl #:zebra)
  (:local-nicknames (#:broker #:dsmr-mcp/src/bus/broker)
                    (#:cursor #:dsmr-mcp/src/bus/cursor)
                    (#:envelope #:dsmr-mcp/src/bus/envelope)
                    (#:roster #:dsmr-mcp/src/bus/roster)
                    (#:wal #:dsmr-mcp/src/bus/wal)))

(in-package #:dsmr-mcp/tests/bus/cursor-reap-test)

(defparameter +namespace+ "/tmp/reap-probe-project"
  "The project root the probe ids are built under. Its own characters are
   irrelevant to the match — only the tail after the last encoded separator is.")

(defmacro with-bus-root ((paths-var) &body body)
  "Bind PATHS-VAR to bus paths over a fresh empty root and delete the tree after.
   The random suffix is seeded per call: SBCL's default random state repeats
   across fresh images, so an unseeded name would collide between runs and every
   assertion below is an absence assertion, which a leftover directory flakes."
  (let ((root (gensym "ROOT")))
    `(let* ((,root (merge-pathnames
                    (format nil "dsmr-cursor-reap-~D-~D/"
                            (sb-posix:getpid)
                            (random 100000000 (make-random-state t)))
                    (uiop:temporary-directory)))
            (,paths-var (broker:make-bus-paths ,root)))
       (broker:ensure-bus-dirs ,paths-var)
       (unwind-protect (progn ,@body)
         (ignore-errors (uiop:delete-directory-tree ,root :validate t))))))

(defun cursor-path (paths id)
  "Where ID's cursor lives — through the real encoder, never a literal."
  (merge-pathnames (envelope:encode-id id)
                   (broker:bus-paths-cursors-dir paths)))

(defun seed-cursor (paths id &key (age-days 0) (seq 5))
  "Write ID's cursor holding SEQ and backdate it AGE-DAYS. Returns its path."
  (let ((path (cursor-path paths id)))
    (with-open-file (out path :direction :output
                              :if-exists :supersede
                              :if-does-not-exist :create)
      (prin1 seq out))
    (when (plusp age-days)
      (let ((when-unix (- (get-universal-time)
                          (encode-universal-time 0 0 0 1 1 1970 0)
                          (* age-days 24 60 60))))
        (sb-posix:utimes (namestring path) when-unix when-unix)))
    path))

(defun ephemeral-id ()
  "An auto-generated ephemeral id — no stable name."
  (envelope:agent-id +namespace+))

(defun stable-id (name)
  (envelope:agent-id +namespace+ :name name))

(define-test aged-ephemeral-is-reaped
  "An ephemeral cursor untouched for a month is removed and counted."
  (with-bus-root (paths)
    (let ((path (seed-cursor paths (ephemeral-id) :age-days 30)))
      (is = 1 (broker:reap-orphaned-cursors paths))
      (false (probe-file path)))))

(define-test recent-ephemeral-survives
  "A live subagent's cursor is not touched by a broker restart."
  (with-bus-root (paths)
    (let ((path (seed-cursor paths (ephemeral-id))))
      (is = 0 (broker:reap-orphaned-cursors paths))
      (true (probe-file path)))))

(define-test aged-stable-cursor-survives
  "The load-bearing case: a stable identity dormant for years keeps its cursor,
   and the reap reports having removed nothing."
  (with-bus-root (paths)
    (let ((path (seed-cursor paths (stable-id "dsmr-mcp") :age-days 3650)))
      (is = 0 (broker:reap-orphaned-cursors paths))
      (true (probe-file path)))))

(define-test stable-lookalikes-survive
  "Names that resemble the ephemeral shape without matching it are stable names,
   and the match must be precise enough to tell them apart."
  (with-bus-root (paths)
    (let ((paths-list (mapcar (lambda (name)
                                (seed-cursor paths (stable-id name) :age-days 3650))
                              '("g-agent" "gateway" "g12" "g12-" "g-1" "gauge-7x"))))
      (is = 0 (broker:reap-orphaned-cursors paths))
      (dolist (path paths-list)
        (true (probe-file path))))))

(define-test mixed-directory-reaps-only-aged-ephemerals
  "In a directory holding all four combinations, exactly the aged ephemerals go."
  (with-bus-root (paths)
    (let ((doomed (list (seed-cursor paths (ephemeral-id) :age-days 30)
                        (seed-cursor paths (ephemeral-id) :age-days 8)
                        (seed-cursor paths (ephemeral-id) :age-days 400)))
          (spared (list (seed-cursor paths (ephemeral-id))
                        (seed-cursor paths (stable-id "runciter") :age-days 3650)
                        (seed-cursor paths (stable-id "pure-tls"))
                        (seed-cursor paths (stable-id "gateway") :age-days 900))))
      (is = 3 (broker:reap-orphaned-cursors paths))
      (dolist (path doomed)
        (false (probe-file path)))
      (dolist (path spared)
        (true (probe-file path))))))

(define-test threshold-is-honored
  "The same fixture reaped against a far larger threshold removes nothing, so the
   default is a parameter the operator can move rather than a constant."
  (with-bus-root (paths)
    (let ((aged (list (seed-cursor paths (ephemeral-id) :age-days 30)
                      (seed-cursor paths (ephemeral-id) :age-days 400))))
      (is = 0 (broker:reap-orphaned-cursors paths :max-age-days 3650))
      (dolist (path aged)
        (true (probe-file path)))
      (is = 2 (broker:reap-orphaned-cursors paths :max-age-days 7)))))

;;; -------------------------------------------------- cursors held for the gone
;;;
;;; A cursor whose owner recorded leaving is the busmaster's to keep: it is
;;; advanced with fleet traffic so it can never pin the log, and retired once the
;;; departure is old enough. Everything below turns on where the age comes from.
;;; A held cursor is written every time the bus is swept, so its modification
;;; time is always current; only the departure stamp on the roster can say how
;;; long ago the agent actually went.

(defun cursor-seq (path)
  "The sequence a cursor file holds, read the way every reader reads it."
  (with-open-file (in path :if-does-not-exist nil)
    (and in (read in nil nil))))

(defun record-departure (paths id &key (age-days 0))
  "Put ID on the roster as having departed AGE-DAYS ago, and return the entry's
   path.

   The real disenroll writes it first, so the entry's shape is whatever the
   roster actually writes rather than a restatement of it here. Backdating then
   rewrites the one field, because nothing in the roster can stamp the past and
   nothing should be able to."
  (let* ((dir (broker:bus-paths-roster-dir paths))
         (record (roster:disenroll id dir))
         (path (roster:roster-entry-path id dir)))
    (when (plusp age-days)
      (let ((amended (copy-list record)))
        (setf (getf amended :departed-at)
              (- (get-universal-time) (* age-days 24 60 60)))
        (with-open-file (out path :direction :output
                                  :if-exists :supersede
                                  :if-does-not-exist :create)
          (with-standard-io-syntax (prin1 amended out)))))
    path))

(defun enroll-agent (paths id)
  (roster:enroll id
                 (broker:bus-paths-roster-dir paths)
                 (broker:bus-paths-roster-state paths)))

(define-test the-busmaster-and-the-subscriber-name-one-cursor-file
  "The busmaster writes the file the participant reads. Two derivations of the
   same name is the way that stops being true without anything saying so."
  (with-bus-root (paths)
    (let ((id (stable-id "shared-name")))
      (is equal (cursor-path paths id) (broker:cursor-path-for paths id)))))

(define-test a-departed-cursor-is-advanced-to-the-head
  "Custody has transferred, so the busmaster moves the cursor up to the log head
   and reports having done it."
  (with-bus-root (paths)
    (let* ((id (stable-id "leaver"))
           (path (seed-cursor paths id :seq 2)))
      (record-departure paths id)
      (is = 1 (broker:advance-held-cursors paths 9))
      (is = 9 (cursor-seq path)))))

(define-test a-held-cursor-still-leads-with-its-bare-position
  "The position is still the first thing in the file and still a bare
   non-negative integer.

   What that protects is the older reader. Every reader of a cursor file takes a
   single form from it and treats anything that is not a non-negative integer as
   position zero, silently, so a file it cannot make sense of does not fail
   against it: it quietly sends that agent back to the start of the log. A file
   that leads with the position survives such a reader unchanged; one that leads
   with anything else, or that prints the position inside a larger structure,
   does not. The file may now carry the generation the position was taken
   against, after the position, and that is the whole of what it may add here."
  (with-bus-root (paths)
    (let* ((id (stable-id "plain"))
           (path (seed-cursor paths id :seq 1)))
      (record-departure paths id)
      (broker:advance-held-cursors paths 12)
      (let ((text (string-trim '(#\Space #\Newline #\Return)
                               (uiop:read-file-string path))))
        (is equal "12" (first (uiop:split-string text :separator " "))
            "the position leads the file, unadorned"))
      (is eql 12 (with-open-file (in path) (read in nil nil))
          "one form off the front is the position itself, not zero"))))

(define-test a-held-cursor-pins-nothing
  "Having tracked the head, a departed agent has nothing pending, so it can never
   be the cursor holding the log back from retention."
  (with-bus-root (paths)
    (let* ((id (stable-id "gone-quiet"))
           (log (broker:bus-paths-wal paths))
           (path (seed-cursor paths id :seq 0)))
      (dotimes (i 3)
        (wal:append-record log (1+ i) (format nil "record ~D" (1+ i))))
      (record-departure paths id)
      (broker:advance-held-cursors paths (wal:scan log))
      (is = 0 (cursor:pending-count (cursor:make-subscriber id log path))))))

(define-test an-enrolled-agents-cursor-is-never-written
  "A live participant owns its own delivery position. Nothing here may move it."
  (with-bus-root (paths)
    (let* ((id (stable-id "present"))
           (path (seed-cursor paths id :seq 2)))
      (enroll-agent paths id)
      (is = 0 (broker:advance-held-cursors paths 9))
      (is = 2 (cursor-seq path)))))

(define-test a-cursor-with-no-roster-entry-is-never-written
  "No departure record means no transfer of custody, whatever the file looks
   like."
  (with-bus-root (paths)
    (let ((path (seed-cursor paths (stable-id "unrecorded") :seq 2)))
      (is = 0 (broker:advance-held-cursors paths 9))
      (is = 2 (cursor-seq path)))))

(define-test a-departed-agent-with-no-cursor-gets-none-created
  "It read nothing, so it holds nothing back. A file invented for it would only
   have to be retired later."
  (with-bus-root (paths)
    (let ((id (stable-id "never-read")))
      (record-departure paths id)
      (is = 0 (broker:advance-held-cursors paths 9))
      (false (probe-file (cursor-path paths id))))))

(define-test an-aged-departure-retires-its-cursor-and-its-entry
  "Past the threshold both the held cursor and the record of the departure go,
   and the sweep says how many."
  (with-bus-root (paths)
    (let* ((id (stable-id "long-gone"))
           (path (seed-cursor paths id :seq 4))
           (entry (record-departure paths id :age-days 30)))
      (is = 1 (broker:age-departed-cursors paths))
      (false (probe-file path))
      (false (probe-file entry)))))

(define-test a-recent-departure-is-left-alone
  "Inside the threshold nothing is taken, so an agent that comes straight back
   finds its position where it left it."
  (with-bus-root (paths)
    (let* ((id (stable-id "just-left"))
           (path (seed-cursor paths id :seq 4))
           (entry (record-departure paths id)))
      (is = 0 (broker:age-departed-cursors paths))
      (true (probe-file path))
      (true (probe-file entry)))))

(define-test an-aged-departure-retires-though-its-cursor-was-just-written
  "The regression this sweep exists to protect. The cursor file is written last,
   so its modification time is seconds old while the departure is a month old.
   Anything keyed on the file's own age would spare this forever, which is
   exactly what advancing a held cursor would cause."
  (with-bus-root (paths)
    (let* ((id (stable-id "held-forever"))
           (entry (record-departure paths id :age-days 30))
           (path (seed-cursor paths id :seq 4)))
      (true (> (file-write-date path) (- (get-universal-time) 120))
            "the held cursor's modification time is current")
      (is = 1 (broker:age-departed-cursors paths))
      (false (probe-file path))
      (false (probe-file entry)))))

(define-test an-enrolled-agent-is-never-aged-out-however-dormant
  "Aging keys on a departure, never on inactivity. A named agent that has not
   read for years is quiet, not gone."
  (with-bus-root (paths)
    (let* ((id (stable-id "dormant"))
           (path (seed-cursor paths id :age-days 3650)))
      (enroll-agent paths id)
      (is = 0 (broker:age-departed-cursors paths))
      (true (probe-file path)))))

(define-test the-aging-threshold-is-a-parameter
  "The same fixture swept against a far larger threshold retires nothing."
  (with-bus-root (paths)
    (let* ((id (stable-id "borderline"))
           (path (seed-cursor paths id :seq 4)))
      (record-departure paths id :age-days 30)
      (is = 0 (broker:age-departed-cursors paths :max-age-days 3650))
      (true (probe-file path))
      (is = 1 (broker:age-departed-cursors paths :max-age-days 7))
      (false (probe-file path)))))

(define-test the-two-sweeps-do-not-handle-each-others-files
  "An ephemeral cursor nobody recorded leaving is the reaper's; a departed
   agent's is the aging sweep's. Neither takes the other's, and the second pass
   finds nothing left to do."
  (with-bus-root (paths)
    (let* ((ephemeral (seed-cursor paths (ephemeral-id) :age-days 30))
           (id (stable-id "departed"))
           (held (seed-cursor paths id))
           (entry (record-departure paths id :age-days 30)))
      (is = 1 (broker:reap-orphaned-cursors paths))
      (false (probe-file ephemeral))
      (true (probe-file held))
      (is = 1 (broker:age-departed-cursors paths))
      (false (probe-file held))
      (false (probe-file entry))
      (is = 0 (broker:age-departed-cursors paths))
      (is = 0 (broker:reap-orphaned-cursors paths)))))

(define-test the-custodial-tick-advances-at-most-once-an-interval
  "The sweeps run off the serve loop, which turns several times a second. The
   tick is what keeps that from meaning a file write per turn."
  (with-bus-root (paths)
    (let* ((id (stable-id "ticking"))
           (path (seed-cursor paths id :seq 0))
           (br (dsmr-mcp/src/bus/broker::%make-broker :paths paths :seq 7)))
      (record-departure paths id)
      (broker:custodial-tick br)
      (is = 7 (cursor-seq path))
      ;; A second tick inside the interval must not sweep again, so a head that
      ;; moved between them is not picked up until the interval is out.
      (setf (dsmr-mcp/src/bus/broker::broker-seq br) 11)
      (broker:custodial-tick br)
      (is = 7 (cursor-seq path))
      (broker:custodial-tick br :advance-seconds 0)
      (is = 11 (cursor-seq path)))))
