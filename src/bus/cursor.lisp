;;;; src/bus/cursor.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Per-subscriber delivery cursor over the bus write-ahead log. Each subscriber
;;;; owns a durable file holding the sequence number it has acknowledged. The
;;;; cursor is the safety net that makes a missed real-time wakeup degrade to
;;;; catch-up rather than a lost message: whatever the subscriber's liveness, on
;;;; the next delivery it receives the records past its cursor and no other.
;;;;
;;;; Three operations, kept deliberately distinct (see the wakeup module for why
;;;; the first is separate):
;;;;
;;;;   - OBSERVE is read-only and lives in the WAL/wakeup layer — it never moves
;;;;     the cursor.
;;;;   - DELIVER-PENDING is the sole cursor-advancing step on the delivery path.
;;;;     It hands back a bounded batch of the records with seq greater than the
;;;;     cursor, oldest first, then advances the cursor to the last one it
;;;;     delivered. Under a bound that is short of the log head, so the next call
;;;;     resumes there and the backlog is walked forward across calls rather than
;;;;     dumped in one result or silently dropped. It is idempotent: a second
;;;;     call with nothing new delivers nothing and leaves the cursor where it
;;;;     was, so a re-arm or a duplicate wake never replays a message.
;;;;   - SKIP-TO-HEAD is the only way to abandon backlog, and it reports how much
;;;;     it abandoned. Nothing on the delivery path calls it.
;;;;
;;;; A participant with no cursor file yet is seeded at the current head by
;;;; ENSURE-SEEDED at subscribe time. Having never read, it has no claim on
;;;; history; without seeding, an absent cursor reads as 0 and the first delivery
;;;; would be the whole log.
;;;;
;;;; Delivery reads through WAL:READ-FORWARD, which is read-only and stops at a
;;;; torn tail — a subscriber therefore never sees a half-written record and never
;;;; truncates the log (only a successor broker repairs it). READ-FORWARD reads
;;;; only the bytes appended since the previous delivery, which is what keeps a
;;;; subscriber polling a quiet bus from paying for the whole history several
;;;; times a second for the life of the process.

(defpackage #:dsmr-mcp/src/bus/cursor
  (:use #:cl)
  (:local-nicknames (#:wal #:dsmr-mcp/src/bus/wal))
  (:export #:subscriber #:make-subscriber
           #:subscriber-id #:subscriber-wal #:subscriber-cursor-path
           #:cursor-value
           #:deliver-pending
           #:pending-count
           #:skip-to-head
           #:ensure-seeded
           #:+default-batch-size+))

(in-package #:dsmr-mcp/src/bus/cursor)

(defstruct (subscriber (:constructor make-subscriber (id wal cursor-path)))
  "A bus consumer: its stable ID, the WAL path it reads, and the path of its
   durable cursor file.

   READER is process-local scratch rather than state: the byte position the last
   delivery read up to, so the next one covers only what was appended since. It
   is deliberately not durable and not part of the cursor's contract. A fresh
   process starts with a fresh reader, reads the log once in full, and is
   incremental from then on. The durable cursor file remains the only thing that
   decides what this subscriber is owed."
  (id "" :type string)
  (wal "" :type (or string pathname))
  (cursor-path "" :type (or string pathname))
  (reader (wal:make-reader) :type wal:reader))

(defun cursor-value (subscriber)
  "The last sequence number SUBSCRIBER has acknowledged (0 if it has never
   delivered)."
  (let ((path (subscriber-cursor-path subscriber)))
    (if (probe-file path)
        (with-open-file (in path :if-does-not-exist nil)
          (or (and in (let ((v (read in nil nil)))
                        (and (integerp v) (>= v 0) v)))
              0))
        0)))

(defun (setf cursor-value) (seq subscriber)
  ;; The replacement must be atomic. A cursor file is read by processes other
  ;; than the one that writes it, so a reader must never catch it mid-write:
  ;; writing in place would truncate the file first and expose a transiently
  ;; empty cursor, which reads back as 0 and looks like a participant that has
  ;; never read anything. Writing a temporary file in the SAME directory and
  ;; renaming it over the target makes the swap a single filesystem operation —
  ;; a reader sees either the old value or the new one, never neither. The temp
  ;; name is deliberately obvious so a crash mid-write leaves something no one
  ;; mistakes for a cursor.
  (let* ((target (subscriber-cursor-path subscriber))
         (temp (make-pathname :name (format nil "~A.tmp~D"
                                            (or (pathname-name target) "cursor")
                                            (random 100000000))
                              :type (pathname-type target)
                              :defaults target)))
    (unwind-protect
         (progn
           (with-open-file (out temp :direction :output
                                     :if-exists :supersede
                                     :if-does-not-exist :create)
             (prin1 seq out)
             (finish-output out))
           (rename-file temp target)
           (setf temp nil))
      (when temp (ignore-errors (delete-file temp)))))
  seq)

(defun pending-count (subscriber)
  "How many records are deliverable to SUBSCRIBER right now, without delivering
   them or moving the cursor (read-only)."
  (max 0 (- (wal:scan (subscriber-wal subscriber))
            (cursor-value subscriber))))

(defconstant +default-batch-size+ 20
  "How many records one delivery hands back unless the caller says otherwise.
   Sized against the observed mean record on the live bus (~1.8 KB), so a full
   default batch is roughly 36 KB — small enough that a consumer catching up on
   a long absence is never handed more than it can digest in one step.")

(defun deliver-pending (subscriber &key (limit +default-batch-size+))
  "Deliver up to LIMIT records with seq greater than SUBSCRIBER's cursor, oldest
   first, and advance the cursor to the last delivered seq. Returns the list of
   WAL:RECORD delivered (empty if nothing is pending). Idempotent.

   Delivery is bounded, and the bound paginates rather than discards. The cursor
   lands on the last record actually handed over, which under a bound is short of
   the log head, so the next call resumes exactly where this one stopped and the
   backlog is walked forward across as many calls as it takes. Nothing is ever
   dropped implicitly — abandoning backlog requires SKIP-TO-HEAD, which says how
   much it abandoned.

   LIMIT NIL means unbounded, for an internal caller that genuinely wants the
   whole backlog in one go. Only NIL or a positive integer is meaningful; a zero,
   negative or non-integer LIMIT falls back to the default batch rather than to
   unbounded, so a caller cannot reach the unbounded path by accident. Rejecting
   such a value outright belongs at the tool boundary, where the caller can be
   told what was wrong with it.

   This returns ONE value, the records. How many remain pending is deliberately
   not threaded back through here: PENDING-COUNT already answers that question
   for whoever needs it, and returning it as a second value would oblige every
   intermediate caller between here and the tool surface to propagate a value
   none of them reads.

   The read is incremental. This is the busiest call in an otherwise idle
   process, since AWAIT sits on it for the life of the server, and re-reading the
   whole log on every turn made an attached but silent agent cost a sizeable
   fraction of a core, scaling with the length of the history rather than with
   the traffic. The subscriber's reader carries the byte position the previous
   delivery stopped at, so a quiet turn touches only what was appended since."
  (let* ((bound (cond ((null limit) nil)
                      ((and (integerp limit) (plusp limit)) limit)
                      (t +default-batch-size+)))
         (cursor (cursor-value subscriber))
         (reader (subscriber-reader subscriber)))
    ;; The durable cursor decides what is owed; the reader only remembers where
    ;; the bytes ran out last time. A reader that has read PAST the cursor means
    ;; the cursor moved backwards under it, because another process rewrote the
    ;; file, and the records between the two are owed again, so its position is
    ;; thrown away. A reader BEHIND the cursor needs no such thing: it keeps
    ;; reading forward and steps over whatever the cursor already covers.
    (when (> (wal:reader-last-seq reader) cursor)
      (wal:reset-reader reader))
    (let ((records (wal:read-forward (subscriber-wal subscriber) reader
                                     :after cursor
                                     :limit bound)))
      (when records
        (setf (cursor-value subscriber)
              (wal:record-seq (car (last records)))))
      records)))

(defun skip-to-head (subscriber)
  "Abandon SUBSCRIBER's whole backlog: advance its cursor straight to the log
   head and return how many records were skipped over.

   The count is the whole point. Throwing away unread messages is sometimes the
   right call — a returning participant may decide a long-stale backlog is worth
   less than the context it would cost — but it has to be a decision someone
   made and can see the size of. A discard that reports nothing is how a
   coordination bus quietly develops amnesia, and how restarting comes to look
   like it heals things. Nothing on the delivery path calls this."
  (let* ((head (wal:scan (subscriber-wal subscriber)))
         (abandoned (max 0 (- head (cursor-value subscriber)))))
    (setf (cursor-value subscriber) head)
    abandoned))

(defun ensure-seeded (subscriber)
  "Give a never-before-seen SUBSCRIBER a cursor at the current log head, and
   return SUBSCRIBER. If its cursor file already exists this does nothing at all,
   so a participant coming back keeps the position it left.

   A participant that has never read has no claim on history: without this, its
   absent cursor reads as 0 and its first receive is handed the entire log. Every
   ephemeral participant — each short-lived subagent, the background restart
   listener — is in exactly that position on every connect.

   Seeding cannot lose a message. A record appended during the seeding window is
   assigned a seq above the head that was just read, so it is still greater than
   the seeded cursor and arrives on the first real delivery. For a record to be
   missed it would have to carry a seq at or below that head, which would mean it
   was already in the log when the head was read — in which case it is history,
   and history is what the participant has no claim on."
  (unless (probe-file (subscriber-cursor-path subscriber))
    (setf (cursor-value subscriber) (wal:scan (subscriber-wal subscriber))))
  subscriber)
