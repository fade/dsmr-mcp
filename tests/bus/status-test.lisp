;;;; tests/bus/status-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Zebra tests for the read-only bus status aggregator.
;;;;
;;;; Every classification this aggregator can emit is planted here and watched
;;;; changing. A clean run against a healthy bus is deliberately not the bar: a
;;;; field that always answers the same word passes that run, and answering the
;;;; same word whatever the world is doing is the specific way each of these
;;;; fields has been wrong. So each check is driven in both directions inside one
;;;; fixture, and the second direction is what would fail if the answer were a
;;;; constant.
;;;;
;;;; Two properties of the fixture decide what these tests can establish, and
;;;; neither is incidental.
;;;;
;;;; The scratch bus roots live under the user's cache directory rather than in
;;;; the temporary directory. The holder count is correlated to a file by the
;;;; device column the kernel prints in its lock table, and that column is
;;;; learned from the filesystem rather than computed, because a memory
;;;; filesystem and the disk filesystem the real bus roots live on answer
;;;; differently. A correlation exercised only in a memory filesystem passes and
;;;; then matches nothing where it matters.
;;;;
;;;; Every lock descriptor a test opens is closed in a cleanup form. A leaked
;;;; shared lock poisons every later question about the same root, and it does so
;;;; by making an answer plausible rather than by failing.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/bus/status-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/bus/status-test
  (:use #:cl #:zebra)
  (:local-nicknames (#:status #:dsmr-mcp/src/bus/status)
                    (#:broker #:dsmr-mcp/src/bus/broker)
                    (#:election #:dsmr-mcp/src/bus/election)
                    (#:cursor #:dsmr-mcp/src/bus/cursor)
                    (#:wal #:dsmr-mcp/src/bus/wal)
                    (#:archive #:dsmr-mcp/src/bus/archive)
                    (#:roster #:dsmr-mcp/src/bus/roster)))

(in-package #:dsmr-mcp/tests/bus/status-test)

;;; ------------------------------------------------------------------ fixture

(defun scratch-bus-root ()
  "A bus root of this test's own making, on the filesystem the real bus roots
   live on.

   Under the cache directory rather than the temporary directory on purpose: the
   lock-table correlation learns its device column from the filesystem the file
   sits on, and a memory filesystem prints a different one. Exercising it only
   there would be green and would establish nothing about the filesystem the
   answer is actually taken on."
  (let ((dir (merge-pathnames
              (format nil "bus-status-probe-~D-~D/"
                      (sb-posix:getpid) (random 100000000))
              (merge-pathnames "dsmr-mcp/" (uiop:xdg-cache-home)))))
    (ensure-directories-exist dir)
    dir))

(defmacro with-scratch-bus ((paths) &body body)
  "Bind PATHS to a fresh bus of this test's own, removed entirely afterwards."
  (let ((root (gensym "ROOT")))
    `(let* ((,root (scratch-bus-root))
            (,paths (broker:make-bus-paths ,root)))
       (broker:ensure-bus-dirs ,paths)
       (unwind-protect (progn ,@body)
         (ignore-errors (uiop:delete-directory-tree
                         ,root :validate t :if-does-not-exist :ignore))))))

(defmacro with-closed-descriptors ((var) &body body)
  "Bind VAR to a list of held lock descriptors, closing every one still on it
   however BODY leaves. A test that leaks a shared lock does not fail; it makes
   the next answer about the same root wrong and plausible."
  `(let ((,var '()))
     (unwind-protect (progn ,@body)
       (dolist (fd ,var) (ignore-errors (election:close-lock fd))))))

(defun join-within (paths seconds)
  "Take a shared membership lock on PATHS, giving up after SECONDS. Returns the
   descriptor, or NIL when the join did not complete in time.

   The bound is what makes the failure it guards visible. A status read that had
   converted its own shared lock to an exclusive one would leave this join parked
   in the kernel with nothing to time it out, so the test would hang rather than
   fail and the reason would never reach anybody."
  (let ((fd (election:open-lock (broker:bus-paths-members paths)))
        (granted nil))
    (unwind-protect
         (progn
           (handler-case
               (sb-ext:with-timeout seconds
                 (setf granted (election:lock-shared fd)))
             (sb-ext:timeout () (setf granted nil)))
           (and granted fd))
      (unless granted (ignore-errors (election:close-lock fd))))))

(defun kernel-lock-table-answers-p (paths)
  "True when the kernel's lock table can be read and correlated to this bus's
   membership file on this host, which is what decides whether the counted
   answer or the advisory one is in force."
  (let ((fd (broker:join-members paths)))
    (unwind-protect (integerp (getf (status:rotation-armed paths) :holders))
      (ignore-errors (election:close-lock fd)))))

(defun publish-records (log n)
  "Append N records to LOG, continuing its sequence, and return the new head."
  (let ((start (wal:scan log)))
    (loop for i from 1 to n do (wal:append-record log (+ start i) "x"))
    (wal:scan log)))

(defun subscriber-for (paths id)
  "A subscriber over this bus's log, writing the cursor file the bus names for
   ID, so a cursor planted here is at the path the aggregator will look for."
  (cursor:make-subscriber id
                          (broker:bus-paths-wal paths)
                          (broker:cursor-path-for paths id)))

(defun row-named (rows name)
  (find name rows :key (lambda (row) (getf row :name)) :test #'string=))

(defun mentions (needle text)
  "True when TEXT states NEEDLE. Used to assert that a bound is present, never to
   assert its wording."
  (and (stringp text) (search needle text) t))

;;; --------------------------------------------------- whether rotation is armed

(define-test rotation-is-not-armed-with-several-holders-and-armed-with-one
  "The log is sealed by the last member out, so the answer turns on there being
   exactly one holder. Both directions are asserted in one fixture with real
   locks: an answer that is always not-armed satisfies the first assertion on its
   own, and always answering not-armed is how this has been wrong before."
  (with-scratch-bus (paths)
    (if (kernel-lock-table-answers-p paths)
        (with-closed-descriptors (fds)
          (dotimes (i 3) (push (broker:join-members paths) fds))
          (let ((crowded (status:rotation-armed paths)))
            (is equal "not-armed" (getf crowded :value))
            (is = 3 (getf crowded :holders))
            (is equal "active-probe" (getf crowded :basis)))
          (election:close-lock (pop fds))
          (let ((pair (status:rotation-armed paths)))
            (is equal "not-armed" (getf pair :value) "two holders is still not armed")
            (is = 2 (getf pair :holders)))
          (election:close-lock (pop fds))
          (let ((sole (status:rotation-armed paths)))
            (is equal "armed" (getf sole :value) "and the last holder alone is armed")
            (is = 1 (getf sole :holders))))
        (skip ("the kernel's lock table cannot be read or correlated on this host, ~
                so the counted answer is not the one in force here")))))

(define-test asking-whether-rotation-is-armed-still-leaves-the-bus-joinable
  "The control on the mutating-check hazard. The primitive that answers `am I
   last` converts the caller's own shared lock to an exclusive one and there is
   no downgrade, so a read that reached for it would leave every later join
   blocked, invisibly, because whoever ran it believed they were reading."
  (with-scratch-bus (paths)
    (with-closed-descriptors (fds)
      (push (broker:join-members paths) fds)
      (dotimes (i 20) (status:rotation-armed paths))
      (let ((late (join-within paths 5)))
        (true late "a member still joined after twenty reads")
        (when late (push late fds)))
      (let ((after (status:rotation-armed paths)))
        (when (getf after :holders)
          (is = 2 (getf after :holders)
              "and the answer moved with the new member rather than staying put"))))))

(define-test rotation-armed-names-the-check-behind-its-answer
  "Which mechanism answered is read from the answer rather than assumed, so this
   stays true if the mechanism is ever revisited. Each branch asserts a definite
   outcome and neither is satisfied by the other's result."
  (with-scratch-bus (paths)
    (with-closed-descriptors (fds)
      (push (broker:join-members paths) fds)
      (let ((answer (status:rotation-armed paths)))
        (true (member (getf answer :basis) '("active-probe" "roster-advisory")
                      :test #'string=)
              "the answer names one of the two checks that can produce it")
        (true (plusp (length (getf answer :red-condition)))
              "and a chosen word carries the condition that would flip it")
        (if (string= "active-probe" (getf answer :basis))
            (progn
              (true (integerp (getf answer :holders))
                    "the counted answer reports how many holders it counted")
              (true (mentions "lock table" (getf answer :establishes))))
            (progn
              (is eq nil (getf answer :holders)
                  "the advisory answer counted no holders at all")
              (true (mentions "roster" (getf answer :establishes)))))))))

(define-test where-the-lock-table-cannot-be-correlated-the-roster-answers-and-says-so
  "A bus whose membership file does not exist yet cannot be found in the lock
   table, which is the state the fallback exists for. It answers from the roster
   and states plainly that it establishes nothing about who holds a lock. Both
   directions again: one enrolled agent is armed and two are not, with no lock
   anywhere in it."
  (with-scratch-bus (paths)
    (let ((roster-dir (broker:bus-paths-roster-dir paths))
          (state (broker:bus-paths-roster-state paths)))
      (roster:enroll "probe/first" roster-dir state)
      (let ((sole (status:rotation-armed paths)))
        (is equal "armed" (getf sole :value))
        (is equal "roster-advisory" (getf sole :basis))
        (is eq nil (getf sole :holders))
        (true (mentions "weaker" (getf sole :does-not-establish))
              "the weaker answer says it is the weaker one")
        (true (mentions "lock" (getf sole :does-not-establish))
              "and says it settles nothing about who holds a lock"))
      (roster:enroll "probe/second" roster-dir state)
      (let ((pair (status:rotation-armed paths)))
        (is equal "not-armed" (getf pair :value)
            "a second enrolment moves the advisory answer with no lock taken")
        (is equal "roster-advisory" (getf pair :basis))))))

(define-test with-neither-a-lock-table-nor-a-roster-the-answer-is-unknown
  "Defaulting to armed and defaulting to not-armed are both claims, and one of
   them is the claim that turned a quiet bus into a reported hazard. Neither is
   made."
  (with-scratch-bus (paths)
    (let ((answer (status:rotation-armed paths)))
      (is equal "unknown" (getf answer :value))
      (is equal "passive-inference" (getf answer :basis))
      (is eq nil (getf answer :holders))
      (true (mentions "does not establish" (getf answer :does-not-establish))))))

;;; ------------------------------------------------------ what the cursors hold

(define-test a-position-left-above-the-head-is-reported-stranded
  "The production shape. The log is sealed, the next cohort numbers from one, and
   an identity still holds the position it had before, far above the new head."
  (with-scratch-bus (paths)
    (let ((log (broker:bus-paths-wal paths)))
      (publish-records log 20)
      (archive:archive-wal log (broker:bus-paths-root paths) :now 1000)
      (publish-records log 10)
      (setf (cursor:cursor-value (subscriber-for paths "probe/above")) 260)
      (let* ((inventory (status:cursor-inventory paths))
             (rows (getf (getf inventory :cursors) :value))
             (row (row-named rows "probe%2Fabove")))
        (true row "the planted cursor appears in the inventory")
        (is eq :cursor-above-head (getf row :stranded-reason))
        (is = 260 (getf row :cursor))
        (is = 10 (getf row :head))
        (is = 1 (getf (getf inventory :count) :value)
            "and the total counts it")
        (is = 1 (getf (getf inventory :stranded-count) :value))))))

(define-test a-position-taken-against-a-replaced-log-is-stranded-where-its-number-says-behind
  "The shape a comparison of sequence numbers cannot find, and the reason this
   field exists. The replacement log grows past a position recorded against the
   log before it, so the position is numerically BELOW the head and the two
   numbers say nothing worse than behind. This test asserts that reading, so an
   implementation that compared sequence numbers alone would satisfy those
   assertions and fail the last one."
  (with-scratch-bus (paths)
    (let ((log (broker:bus-paths-wal paths)))
      (publish-records log 20)
      (setf (cursor:cursor-value (subscriber-for paths "probe/behind")) 5)
      (archive:archive-wal log (broker:bus-paths-root paths) :now 1000)
      (publish-records log 10)
      (let* ((inventory (status:cursor-inventory paths))
             (rows (getf (getf inventory :cursors) :value))
             (row (row-named rows "probe%2Fbehind")))
        (true row "the planted cursor appears in the inventory")
        (is = 5 (getf row :cursor))
        (is = 10 (getf row :head))
        (true (< (getf row :cursor) (getf row :head))
              "the position is below the head, so its number alone reads as behind")
        (true (/= (getf row :recorded-generation) (getf row :log-generation))
              "and only the generation carries that the log is not the one it read")
        (is eq :generation-mismatch (getf row :stranded-reason))))))

(define-test a-cursor-in-step-with-its-log-is-not-flagged
  "The control on both plants. Without it the answer could be stranded to
   everything and the two above would pass exactly as they do."
  (with-scratch-bus (paths)
    (let ((log (broker:bus-paths-wal paths)))
      (publish-records log 20)
      (archive:archive-wal log (broker:bus-paths-root paths) :now 1000)
      (publish-records log 10)
      (setf (cursor:cursor-value (subscriber-for paths "probe/current")) 4)
      (setf (cursor:cursor-value (subscriber-for paths "probe/above")) 260)
      (let* ((inventory (status:cursor-inventory paths))
             (rows (getf (getf inventory :cursors) :value)))
        (is eq nil (getf (row-named rows "probe%2Fcurrent") :stranded-reason)
            "a reader in step with its log is sound")
        (is eq :cursor-above-head
            (getf (row-named rows "probe%2Fabove") :stranded-reason)
            "while the stranded one beside it is still found")
        (is = 2 (getf (getf inventory :count) :value))
        (is = 1 (getf (getf inventory :stranded-count) :value)
            "so the count is of the stranded ones and not of all of them")))))

(define-test the-inventory-separates-per-process-cursors-from-stable-ones
  "Unreaped accumulation is what makes a cursor directory worth counting, and the
   auto-generated per-process names are the ones that accumulate. Both directions
   in one inventory: an answer calling every name ephemeral, or none of them,
   fails one of these two."
  (with-scratch-bus (paths)
    (let ((log (broker:bus-paths-wal paths)))
      (publish-records log 5)
      (setf (cursor:cursor-value (subscriber-for paths "probe/g900-1")) 3)
      (setf (cursor:cursor-value (subscriber-for paths "probe/g901-2")) 3)
      (setf (cursor:cursor-value (subscriber-for paths "probe/stable-reader")) 3)
      (let* ((inventory (status:cursor-inventory paths))
             (rows (getf (getf inventory :cursors) :value)))
        (is = 3 (getf (getf inventory :count) :value))
        (is = 2 (getf (getf inventory :ephemeral-count) :value))
        (is eq t (getf (row-named rows "probe%2Fg900-1") :ephemeral))
        (is eq nil (getf (row-named rows "probe%2Fstable-reader") :ephemeral))))))

;;; ------------------------------------ who is enrolled, and who is reading

(define-test an-enrolled-identity-with-a-fresh-cursor-reports-enrolled-and-reading
  "The ordinary case, and the one that has to keep working while the two below
   are made visible."
  (with-scratch-bus (paths)
    (let ((log (broker:bus-paths-wal paths))
          (roster-dir (broker:bus-paths-roster-dir paths))
          (state (broker:bus-paths-roster-state paths)))
      (publish-records log 5)
      (roster:enroll "probe/reading" roster-dir state)
      (roster:enroll "probe/silent" roster-dir state)
      (setf (cursor:cursor-value (subscriber-for paths "probe/reading")) 3)
      (let* ((visibility (status:identity-visibility paths))
             (members (getf (getf visibility :members) :value))
             (reading (find "probe/reading" members
                            :key (lambda (m) (getf m :id)) :test #'string=))
             (silent (find "probe/silent" members
                           :key (lambda (m) (getf m :id)) :test #'string=))
             (unenrolled (getf (getf visibility :unenrolled) :value)))
        (is eq t (getf reading :has-cursor))
        (is eq t (getf reading :cursor-advanced-recently))
        (is eq :enrolled (getf reading :status))
        (is eq nil (getf silent :has-cursor)
            "an enrolled identity that has never read holds no position")
        (is eq nil (getf silent :cursor-advanced-recently))
        (is = 0 (length unenrolled)
            "and an enrolled reader is not also reported as unenrolled")))))

(define-test a-stable-cursor-with-no-enrolment-is-reported-apart-from-a-per-process-one
  "The case that is invisible today while it is happening. A per-process cursor
   with no roster entry is ordinary: the session that wrote it has ended. A
   STABLE name holding a position on a bus that never enrolled it is the shape of
   a participant working under a borrowed identity, and the two must not read
   alike. An answer that called both ephemeral, or neither, fails one of these."
  (with-scratch-bus (paths)
    (let ((log (broker:bus-paths-wal paths)))
      (publish-records log 5)
      (setf (cursor:cursor-value (subscriber-for paths "probe/g900-1")) 3)
      (setf (cursor:cursor-value (subscriber-for paths "probe/borrowed")) 3)
      (let* ((visibility (status:identity-visibility paths))
             (unenrolled (getf (getf visibility :unenrolled) :value)))
        (is = 2 (length unenrolled))
        (is equal "ephemeral"
            (getf (row-named unenrolled "probe%2Fg900-1") :kind))
        (is equal "stable-without-enrollment"
            (getf (row-named unenrolled "probe%2Fborrowed") :kind))
        (true (mentions "borrowed identity"
                        (getf (getf visibility :unenrolled) :does-not-establish))
              "and the list says what a stable name here does not by itself prove")))))

(define-test enrolling-a-stable-reader-moves-it-out-of-the-unenrolled-list-and-leaving-does-not-put-it-back
  "The cross-reference driven in the data, both directions. Enrolment moves a
   name across; departure leaves it a member still holding its position rather
   than returning it to the unenrolled side, which is what keeps a departed
   agent's held cursor from reading as a borrowed identity."
  (with-scratch-bus (paths)
    (let ((log (broker:bus-paths-wal paths))
          (roster-dir (broker:bus-paths-roster-dir paths))
          (state (broker:bus-paths-roster-state paths)))
      (publish-records log 5)
      (setf (cursor:cursor-value (subscriber-for paths "probe/borrowed")) 3)
      (flet ((unenrolled-names ()
               (mapcar (lambda (row) (getf row :name))
                       (getf (getf (status:identity-visibility paths) :unenrolled)
                             :value)))
             (member-row (id)
               (find id (getf (getf (status:identity-visibility paths) :members) :value)
                     :key (lambda (m) (getf m :id)) :test #'string=)))
        (is equal '("probe%2Fborrowed") (unenrolled-names))
        (is eq nil (member-row "probe/borrowed"))
        (roster:enroll "probe/borrowed" roster-dir state)
        (is equal '() (unenrolled-names) "enrolment moves it across")
        (is eq t (getf (member-row "probe/borrowed") :has-cursor)
            "and it carries its position with it")
        (roster:disenroll "probe/borrowed" roster-dir)
        (is eq :departed (getf (member-row "probe/borrowed") :status))
        (is eq t (getf (member-row "probe/borrowed") :has-cursor)
            "a departed agent keeps its position")
        (is equal '() (unenrolled-names)
            "and does not reappear as a name with no enrolment")))))

(define-test the-roster-sourced-facts-say-they-do-not-establish-that-anything-is-running
  "The roster is an unenforced record of what agents declared once. Reading it as
   a liveness check is the mistake every one of these bounds exists to stop, and
   a test that checked the values while ignoring the bounds would let them be
   dropped without a word."
  (with-scratch-bus (paths)
    (let ((roster-dir (broker:bus-paths-roster-dir paths))
          (state (broker:bus-paths-roster-state paths)))
      (roster:enroll "probe/declared" roster-dir state)
      (let* ((visibility (status:identity-visibility paths))
             (members (getf visibility :members))
             (unenrolled (getf visibility :unenrolled))
             (beats (getf visibility :watch-beat)))
        (is equal "roster-advisory" (getf members :basis))
        (true (mentions "advisory" (getf members :does-not-establish)))
        (true (mentions "running" (getf members :does-not-establish))
              "it states that an entry is not evidence a process exists")
        (is equal "durable-record" (getf unenrolled :basis))
        (true (mentions "does not establish" (getf beats :does-not-establish))
              "and a watch beat carries its own limit rather than reading as liveness")))))
