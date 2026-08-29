;;;; tests/bus/cursor-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Zebra tests for the per-subscriber delivery cursor. The contract: a
;;;; subscriber receives every record past its cursor exactly once, catch-up after
;;;; an absence delivers the backlog, and re-delivery is idempotent so a duplicate
;;;; wake never replays a message.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/bus/cursor-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/bus/cursor-test
  (:use #:cl #:zebra)
  (:local-nicknames (#:wal #:dsmr-mcp/src/bus/wal)
                    (#:cursor #:dsmr-mcp/src/bus/cursor)
                    (#:archive #:dsmr-mcp/src/bus/archive)))

(in-package #:dsmr-mcp/tests/bus/cursor-test)

(defmacro with-sub ((var) &body body)
  "Bind VAR to a fresh subscriber over a temp WAL + temp cursor, cleaned up after."
  (let ((wal-path (gensym)) (cur-path (gensym)))
    `(let ((,wal-path (uiop:with-temporary-file (:pathname p :keep t :type "wal") p))
           (,cur-path (uiop:with-temporary-file (:pathname p :keep t :type "cursor") p)))
       (let ((,var (cursor:make-subscriber "sub-1" ,wal-path ,cur-path)))
         (unwind-protect (progn ,@body)
           (ignore-errors (delete-file ,wal-path))
           (ignore-errors (delete-file ,cur-path)))))))

(defun publish (sub n &optional (body "x"))
  "Append records (last-seq+1 .. last-seq+n) to the subscriber's WAL."
  (let ((start (wal:scan (cursor:subscriber-wal sub))))
    (loop for i from 1 to n
          do (wal:append-record (cursor:subscriber-wal sub) (+ start i) body))))

(define-test fresh-cursor-is-zero
  "A subscriber that has never delivered has cursor 0."
  (with-sub (s)
    (is = 0 (cursor:cursor-value s))))

(define-test delivers-all-then-advances
  "First delivery hands back every record and advances the cursor to the last."
  (with-sub (s)
    (publish s 5)
    (let ((recs (cursor:deliver-pending s)))
      (is equal '(1 2 3 4 5) (mapcar #'wal:record-seq recs))
      (is = 5 (cursor:cursor-value s)))))

(define-test idempotent-redelivery
  "A second delivery with nothing new returns nothing and leaves the cursor put."
  (with-sub (s)
    (publish s 3)
    (cursor:deliver-pending s)
    (let ((again (cursor:deliver-pending s)))
      (is = 0 (length again))
      (is = 3 (cursor:cursor-value s)))))

(define-test catch-up-after-absence
  "Records published while the subscriber was away are all delivered on return."
  (with-sub (s)
    (publish s 2)
    (cursor:deliver-pending s)                 ; cursor -> 2
    (publish s 3)                              ; 3,4,5 arrive while "asleep"
    (let ((recs (cursor:deliver-pending s)))
      (is equal '(3 4 5) (mapcar #'wal:record-seq recs))
      (is = 5 (cursor:cursor-value s)))))

(define-test delivers-bodies
  "Delivered records carry their payloads intact."
  (with-sub (s)
    (wal:append-record (cursor:subscriber-wal s) 1 "first")
    (wal:append-record (cursor:subscriber-wal s) 2 "second")
    (let ((recs (cursor:deliver-pending s)))
      (is equal '("first" "second") (mapcar #'wal:record-body-string recs)))))

(define-test pending-count-is-read-only
  "PENDING-COUNT reports the backlog without delivering or moving the cursor."
  (with-sub (s)
    (publish s 4)
    (is = 4 (cursor:pending-count s))
    (is = 0 (cursor:cursor-value s))           ; unchanged by the observation
    (cursor:deliver-pending s)
    (is = 0 (cursor:pending-count s))))

;;; bounded, paginated delivery ------------------------------------------------

(define-test default-delivery-is-bounded-at-twenty
  "With no explicit limit a delivery hands back at most the default batch, and
   the cursor lands on the last delivered record rather than the log head."
  (with-sub (s)
    (publish s 50)
    (let ((recs (cursor:deliver-pending s)))
      (is = cursor:+default-batch-size+ (length recs))
      (is = 20 cursor:+default-batch-size+)
      (is equal (loop for i from 1 to 20 collect i) (mapcar #'wal:record-seq recs))
      (is = 20 (cursor:cursor-value s))
      (is = 30 (cursor:pending-count s)))))

(define-test bounded-pages-reconstruct-the-whole-backlog
  "Successive bounded deliveries walk the backlog forward with no gap and no
   duplicate — the pages concatenate to exactly what an unbounded read would
   have returned, which is what makes bounding pagination and not discard."
  (with-sub (s)
    (publish s 50)
    (let ((seen '()))
      (loop for page = (cursor:deliver-pending s :limit 7)
            while page
            do (setf seen (append seen (mapcar #'wal:record-seq page))))
      (is equal (loop for i from 1 to 50 collect i) seen)
      (is = 50 (cursor:cursor-value s))
      (is = 0 (cursor:pending-count s)))))

(define-test explicit-nil-limit-is-unbounded
  "An internal caller can still ask for the whole backlog in one go."
  (with-sub (s)
    (publish s 45)
    (is = 45 (length (cursor:deliver-pending s :limit nil)))))

(define-test deliver-pending-returns-one-value
  "Delivery stays single-valued. The remaining-pending count is PENDING-COUNT's
   job, so nothing downstream can come to depend on a second value that is
   deliberately not plumbed through the delivery stack."
  (with-sub (s)
    (publish s 30)
    (is eq nil (nth-value 1 (cursor:deliver-pending s)))
    (is = 10 (cursor:pending-count s))))

;;; explicit abandonment -------------------------------------------------------

(define-test skip-to-head-reports-what-it-abandoned
  "Skipping ahead returns the number of records dropped and leaves nothing
   pending — the discard is explicit and countable."
  (with-sub (s)
    (publish s 12)
    (is = 12 (cursor:skip-to-head s))
    (is = 12 (cursor:cursor-value s))
    (is = 0 (cursor:pending-count s))
    (is = 0 (length (cursor:deliver-pending s)))))

(define-test skip-to-head-on-a-current-cursor-abandons-nothing
  "A caller already at the head skips nothing and is told so."
  (with-sub (s)
    (publish s 4)
    (cursor:deliver-pending s)
    (is = 0 (cursor:skip-to-head s))
    (is = 4 (cursor:cursor-value s))))

;;; seeding --------------------------------------------------------------------

(defmacro with-unseeded-sub ((var) &body body)
  "Like WITH-SUB but the cursor file does NOT exist yet — the state a
   never-before-seen participant is actually in."
  (let ((wal-path (gensym)) (cur-path (gensym)))
    `(let* ((,wal-path (uiop:with-temporary-file (:pathname p :keep t :type "wal") p))
            (,cur-path (uiop:with-temporary-file (:pathname p :keep t :type "cursor") p)))
       (ignore-errors (delete-file ,cur-path))
       (let ((,var (cursor:make-subscriber "sub-new" ,wal-path ,cur-path)))
         (unwind-protect (progn ,@body)
           (ignore-errors (delete-file ,wal-path))
           (ignore-errors (delete-file ,cur-path)))))))

(define-test seeding-a-new-participant-starts-it-at-the-head
  "A participant with no cursor file starts at the current head, so its first
   delivery is empty rather than the entire log."
  (with-unseeded-sub (s)
    (publish s 25)
    (cursor:ensure-seeded s)
    (is = 25 (cursor:cursor-value s))
    (is = 0 (cursor:pending-count s))
    (is = 0 (length (cursor:deliver-pending s)))
    ;; and it receives what arrives after it joined
    (publish s 3)
    (is equal '(26 27 28) (mapcar #'wal:record-seq (cursor:deliver-pending s)))))

(define-test seeding-leaves-a-returning-participant-alone
  "An existing cursor file is untouched by seeding — a participant coming back
   keeps its position and its backlog."
  (with-sub (s)
    (publish s 9)
    (cursor:deliver-pending s :limit 4)          ; cursor -> 4
    (cursor:ensure-seeded s)
    (is = 4 (cursor:cursor-value s))
    (is = 5 (cursor:pending-count s))))

;;; durability -----------------------------------------------------------------

(define-test cursor-write-leaves-no-temp-file-behind
  "The cursor is replaced by rename, and the transient file it renames from does
   not survive the write."
  (with-sub (s)
    (setf (cursor:cursor-value s) 7)
    (is = 7 (cursor:cursor-value s))
    (let* ((path (cursor:subscriber-cursor-path s))
           (dir (uiop:pathname-directory-pathname path))
           (stem (concatenate 'string (pathname-name path) ".tmp"))
           (leftovers (remove-if-not
                       (lambda (p) (eql 0 (search stem (file-namestring p))))
                       (uiop:directory-files dir))))
      (is = 0 (length leftovers) "no transient cursor file remains"))))

;;; incremental delivery -------------------------------------------------------
;;;
;;; Delivery reads only the bytes appended since the previous call. The durable
;;; cursor still decides what is owed; what these pin is that the cheaper read
;;; hands back the same records the whole-log read did, including across the
;;; events that invalidate a remembered byte position.

(defun empty-wal (path)
  "Reset PATH to a zero-length file, what archival does to the active log when
   the last member leaves."
  (close (open path :element-type '(unsigned-byte 8) :direction :output
                    :if-exists :supersede :if-does-not-exist :create))
  path)

(define-test many-quiet-polls-do-not-cost-the-next-message
  "The shape of an idle subscriber's life: poll, poll, poll, then a message. The
   quiet polls deliver nothing and move nothing, and the record that finally
   arrives is delivered once, in order, exactly as a single poll would have."
  (with-sub (s)
    (publish s 6)
    (is equal '(1 2 3 4 5 6) (mapcar #'wal:record-seq (cursor:deliver-pending s)))
    (dotimes (i 50)
      (is eq nil (cursor:deliver-pending s)))
    (is = 6 (cursor:cursor-value s))
    (publish s 2)
    (is equal '(7 8) (mapcar #'wal:record-seq (cursor:deliver-pending s)))
    (is = 8 (cursor:cursor-value s))
    (is eq nil (cursor:deliver-pending s) "and delivery is still idempotent")))

(define-test delivery-survives-the-log-being-rotated-underneath-it
  "Archival empties the log under a live subscriber and the next cohort starts
   numbering again. Delivery must fall back to reading the replacement from its
   head and hand back everything the cursor does not already cover. A subscriber
   that kept trusting a stale byte position would report itself healthy and
   deliver nothing ever again."
  (with-sub (s)
    (publish s 8)
    (is = 3 (length (cursor:deliver-pending s :limit 3)))    ; cursor -> 3
    (empty-wal (cursor:subscriber-wal s))
    (loop for i from 1 to 9
          do (wal:append-record (cursor:subscriber-wal s) i "post-rotation"))
    (is equal '(4 5 6 7 8 9)
        (mapcar #'wal:record-seq (cursor:deliver-pending s :limit nil))
        "everything above the cursor in the new log is delivered")
    (is = 9 (cursor:cursor-value s))))

;;; positions that cannot be right ---------------------------------------------
;;;
;;; Sealing the log empties it and the next cohort numbers from 1 again, while
;;; every stable identity keeps the position it held. The count of what is
;;; deliverable clamps at zero, so that position reads as nothing pending, which
;;; is what a whole constellation read as an idle bus for three and a half days.
;;; The plants below are the two shapes it takes, both pure filesystem setup: no
;;; timing, no subprocess, nothing to race.

(defmacro with-sealable-sub ((var dir) &body body)
  "Like WITH-SUB, but the log and the cursor live in a temp directory of their
   own, so the log can be sealed into an archive beside it and the whole tree
   deleted after."
  (let ((name (gensym "NAME")))
    `(let* ((,name (uiop:with-temporary-file (:pathname p :keep t :prefix "dsmr-bus-strand") p))
            (,dir (progn (ignore-errors (delete-file ,name))
                         (uiop:ensure-directory-pathname ,name))))
       (ensure-directories-exist ,dir)
       (let ((,var (cursor:make-subscriber "sub-1"
                                           (merge-pathnames "bus.wal" ,dir)
                                           (merge-pathnames "sub-1.cursor" ,dir))))
         (unwind-protect (progn ,@body)
           (ignore-errors (uiop:delete-directory-tree
                           ,dir :validate t :if-does-not-exist :ignore)))))))

(defun write-bare-cursor (subscriber seq)
  "Write SUBSCRIBER's cursor the way it was written before a generation was
   recorded beside the position: the position alone and nothing else. Every
   cursor file on the fleet is this shape."
  (with-open-file (out (cursor:subscriber-cursor-path subscriber)
                       :direction :output
                       :if-exists :supersede
                       :if-does-not-exist :create)
    (prin1 seq out))
  seq)

(define-test a-position-left-above-the-head-is-stranded
  "The production shape, planted. The log is sealed, the next cohort numbers
   from 1, and a stable identity still holds the position it had before, far
   above the new head. The count answers 0, and that answer is asserted here
   rather than corrected: it is what a leader read as an idle bus while nothing
   was reaching it. What has changed is that the same position now also reaches
   a caller as it is, and a caller asking whether it is sound is told that it is
   not, and why."
  (with-sealable-sub (s dir)
    (publish s 8)
    (cursor:deliver-pending s :limit nil)
    (archive:archive-wal (cursor:subscriber-wal s) dir :now 1000)
    (publish s 2)
    (setf (cursor:cursor-value s) 260)
    (is = 0 (cursor:pending-count s)
        "the count still says nothing is pending, exactly as it did on the live bus")
    (multiple-value-bind (cursor head) (cursor:cursor-and-head s)
      (is = 260 cursor)
      (is = 2 head)
      (true (> cursor head) "and the pair reaches a caller unclamped"))
    (is eq :cursor-above-head (cursor:stranded-reason s))))

(define-test a-position-below-the-head-of-a-log-it-never-read-is-stranded
  "The shape a comparison of sequence numbers cannot find. The replacement log
   grows past a position recorded against the log before it, so the position is
   numerically BELOW the head and the two numbers say nothing worse than behind.
   The count agrees with them, and is asserted here saying so. Only the
   generation carries the fact that the log being counted against is not the log
   the position came from."
  (with-sealable-sub (s dir)
    (publish s 20)
    (cursor:deliver-pending s :limit 3)
    (archive:archive-wal (cursor:subscriber-wal s) dir :now 1000)
    (publish s 9)
    (multiple-value-bind (cursor head) (cursor:cursor-and-head s)
      (is = 3 cursor)
      (is = 9 head)
      (true (< cursor head) "the position is below the head, so it reads as behind"))
    (is = 6 (cursor:pending-count s) "and the count says merely behind")
    (is eq :generation-mismatch (cursor:stranded-reason s))))

(define-test a-position-taken-against-the-log-being-read-is-not-stranded
  "The control on both plants. Without it the answer could be stranded to
   everything and the two above would pass exactly as they do. A reader in step
   with its log is sound, is not sound once the log has been sealed under it,
   and is sound again the moment its position is put back to the start of the
   log that replaced it, which is the repair that recovered the live buses."
  (with-sealable-sub (s dir)
    (publish s 10)
    (cursor:deliver-pending s :limit 4)
    (is = 4 (cursor:cursor-value s))
    (is eq nil (cursor:stranded-reason s))
    (archive:archive-wal (cursor:subscriber-wal s) dir :now 1000)
    (publish s 6)
    (is eq :generation-mismatch (cursor:stranded-reason s)
        "sealed under it, the same position is not sound")
    (setf (cursor:cursor-value s) 0)
    (is eq nil (cursor:stranded-reason s) "and the repair makes it sound again")
    (is = 6 (cursor:pending-count s) "with the whole replacement log owed to it")))

(define-test a-cursor-that-names-no-generation-is-not-stranded
  "The control that keeps this from going off everywhere at once. Every cursor
   file on the fleet was written before a generation was recorded, so its
   generation is unknown rather than different. An unknown read as a
   disagreement would report every stable identity on every bus stranded on the
   day this shipped, which is indistinguishable from the alarm being wrong."
  (with-sealable-sub (s dir)
    (publish s 6)
    (archive:archive-wal (cursor:subscriber-wal s) dir :now 1000)
    (publish s 9)
    (write-bare-cursor s 4)
    (is = 4 (cursor:cursor-value s) "the position still reads")
    (is = 5 (cursor:pending-count s) "and delivery still knows what is owed")
    (is eq nil (cursor:stranded-reason s))))
