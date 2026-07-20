;;;; tests/bus/cursor-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Parachute tests for the per-subscriber delivery cursor. The contract: a
;;;; subscriber receives every record past its cursor exactly once, catch-up after
;;;; an absence delivers the backlog, and re-delivery is idempotent so a duplicate
;;;; wake never replays a message.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/bus/cursor-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/bus/cursor-test
  (:use #:cl #:parachute)
  (:local-nicknames (#:wal #:dsmr-mcp/src/bus/wal)
                    (#:cursor #:dsmr-mcp/src/bus/cursor)))

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
