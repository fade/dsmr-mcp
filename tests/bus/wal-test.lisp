;;;; tests/bus/wal-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Zebra tests for the coordination-bus write-ahead log. The properties
;;;; under test are the ones a successor broker's correctness rests on: a record
;;;; survives a round trip, a clean log replays exactly, and every shape of torn
;;;; tail a crash can leave (partial header, short payload, bit-flipped CRC) is
;;;; detected and truncated so the sequence continues with no gap or duplicate.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/bus/wal-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/bus/wal-test
  (:use #:cl #:zebra)
  (:import-from #:dsmr-mcp/src/bus/wal
                #:crc32
                #:encode-record
                #:append-record
                #:scan
                #:generation #:generation-path
                #:read-records
                #:make-reader #:read-forward #:reader-offset
                #:recover
                #:record-seq #:record-body-string
                #:recovery-last-seq #:recovery-records #:recovery-truncated-from)
  (:import-from #:dsmr-mcp/src/bus/archive
                #:archive-wal))

(in-package #:dsmr-mcp/tests/bus/wal-test)

;;; helpers --------------------------------------------------------------------

(defun temp-wal ()
  (uiop:with-temporary-file (:pathname p :keep t :type "wal" :prefix "dsmr-bus-wal-")
    p))

(defmacro with-wal ((var) &body body)
  `(let ((,var (temp-wal)))
     (unwind-protect (progn ,@body)
       (ignore-errors (delete-file ,var)))))

(defun write-good-wal (path n &optional (body "x"))
  "Append N contiguous good records 1..N."
  (loop for s from 1 to n do (append-record path s body)))

(defun file-bytes (path)
  (with-open-file (in path :element-type '(unsigned-byte 8) :if-does-not-exist nil)
    (if in
        (let ((v (make-array (file-length in) :element-type '(unsigned-byte 8))))
          (read-sequence v in) v)
        (make-array 0 :element-type '(unsigned-byte 8)))))

(defun append-raw (path bytes)
  (with-open-file (out path :element-type '(unsigned-byte 8)
                            :direction :output :if-exists :append
                            :if-does-not-exist :create)
    (write-sequence bytes out)))

(defun last-seq (path) (recovery-last-seq (recover path)))

(defun empty-wal (path)
  "Reset PATH to a zero-length file, exactly what archival does to the active log
   when the last member leaves, and the event a live reader has to survive."
  (close (open path :element-type '(unsigned-byte 8) :direction :output
                    :if-exists :supersede :if-does-not-exist :create))
  path)

;;; CRC ------------------------------------------------------------------------

(define-test crc32-published-vector
  "CRC-32 of \"123456789\" is the canonical IEEE-802.3 check value."
  (is = #xCBF43926
      (crc32 (sb-ext:string-to-octets "123456789"))))

;;; round trip + clean replay --------------------------------------------------

(define-test record-round-trip
  "A record written then read back preserves seq and body."
  (with-wal (w)
    (append-record w 1 "hello bus")
    (let ((recs (read-records w)))
      (is = 1 (length recs))
      (is = 1 (record-seq (first recs)))
      (is string= "hello bus" (record-body-string (first recs))))))

(define-test clean-wal-replays-exactly
  "Ten good records replay with last-seq 10, ten records, no truncation."
  (with-wal (w)
    (write-good-wal w 10)
    (let ((r (recover w)))
      (is = 10 (recovery-last-seq r))
      (is = 10 (recovery-records r))
      (false (recovery-truncated-from r)))))

(define-test read-records-after-cursor
  "READ-RECORDS with :after returns only the records past the cursor, in order."
  (with-wal (w)
    (write-good-wal w 5)
    (let ((recs (read-records w :after 3)))
      (is equal '(4 5) (mapcar #'record-seq recs)))))

(define-test read-records-limit-returns-oldest-page
  "READ-RECORDS with :limit returns the OLDEST limit records past the cursor —
   pagination walks forward from the backlog's head, it does not skip to the
   newest and drop history."
  (with-wal (w)
    (write-good-wal w 40)
    (let ((recs (read-records w :after 0 :limit 5)))
      (is = 5 (length recs))
      (is equal '(1 2 3 4 5) (mapcar #'record-seq recs)))
    ;; an omitted or NIL limit is the uncapped read it has always been
    (is = 40 (length (read-records w :after 0)))
    (is = 40 (length (read-records w :after 0 :limit nil)))))

(define-test read-records-limit-preserves-torn-tail-detection
  "A bounded read stops COLLECTING early but the integrity walk still runs to the
   torn boundary, so SCAN on the same file reports the full good-record count.
   Bounding the page must not blind the WAL to corruption past it."
  (with-wal (w)
    (write-good-wal w 12)
    (let ((rec (encode-record 13 "x")))
      (setf (aref rec (+ 8 16)) (logxor (aref rec (+ 8 16)) 1)) ; flip a body bit
      (append-raw w rec))
    (let ((recs (read-records w :after 0 :limit 4)))
      (is = 4 (length recs))
      (is equal '(1 2 3 4) (mapcar #'record-seq recs)))
    (multiple-value-bind (last-seq good-bytes records) (scan w)
      (declare (ignore good-bytes))
      (is = 12 last-seq)
      (is = 12 records "the unbounded scan still sees every good record"))))

;;; torn-tail recovery ---------------------------------------------------------

(define-test torn-partial-header-truncated
  "A crash after a few header bytes is detected; the tail is truncated and a
   successor continues with no gap or duplicate."
  (with-wal (w)
    (write-good-wal w 5)
    (append-raw w (make-array 3 :element-type '(unsigned-byte 8)
                                :initial-contents '(16 0 0)))
    (let ((r (recover w)))
      (is = 5 (recovery-last-seq r))
      (true (recovery-truncated-from r) "torn tail was truncated"))
    ;; the WAL is clean now: a successor appends 6 and replays contiguously
    (append-record w 6 "x")
    (let ((r2 (recover w)))
      (is = 6 (recovery-last-seq r2))
      (false (recovery-truncated-from r2)))))

(define-test torn-short-payload-truncated
  "A full header promising a payload that was never fully written is torn."
  (with-wal (w)
    (write-good-wal w 5)
    (let* ((full (encode-record 6 "x"))
           (cut  (+ 8 (floor (- (length full) 8) 2))))   ; header + half the payload
      (append-raw w (subseq full 0 cut)))
    (let ((r (recover w)))
      (is = 5 (recovery-last-seq r))
      (true (recovery-truncated-from r) "short-payload tail was truncated"))))

(define-test torn-bad-crc-truncated
  "A complete record on disk whose payload bit was flipped fails CRC and is torn."
  (with-wal (w)
    (write-good-wal w 5)
    (let ((rec (encode-record 6 "x")))
      (setf (aref rec (+ 8 16)) (logxor (aref rec (+ 8 16)) 1)) ; flip a body bit
      (append-raw w rec))
    (let ((r (recover w)))
      (is = 5 (recovery-last-seq r))
      (true (recovery-truncated-from r) "bad-CRC tail was truncated"))))

;;; read-only contract ---------------------------------------------------------

(define-test scan-never-truncates
  "SCAN reports the last good seq but leaves a torn tail on disk — only RECOVER
   repairs it (so a reader can never clip a broker's in-flight write)."
  (with-wal (w)
    (write-good-wal w 4)
    (let* ((full (encode-record 5 "x"))
           (torn (subseq full 0 (+ 8 4))))   ; partial record 5
      (append-raw w torn)
      (let ((before (length (file-bytes w))))
        (is = 4 (scan w))                     ; sees 4, ignores torn 5
        (is = before (length (file-bytes w))) ; bytes untouched
        ;; RECOVER is what truncates
        (recover w)
        (is = (- before (length torn)) (length (file-bytes w)))))))

;;; failover replay ------------------------------------------------------------

(define-test failover-replay-continuous
  "Broker A writes 1..7 then crashes mid-record-8; broker B recovers, truncates
   the torn 8, and continues 8..12. The final log is 1..12 with no hole or dup."
  (with-wal (w)
    (write-good-wal w 7 "A")
    (let ((torn (encode-record 8 "A")))
      (append-raw w (subseq torn 0 (+ 8 4))))   ; partial record 8
    (is = 7 (last-seq w))                        ; B recovers A's log
    (loop for s from 8 to 12 do (append-record w s "B"))
    (let ((r (recover w)))
      (is = 12 (recovery-last-seq r))
      (is = 12 (recovery-records r))
      (false (recovery-truncated-from r)))
    (is equal (loop for s from 1 to 12 collect s)
        (mapcar #'record-seq (read-records w)))))

;;; incremental tail reads -----------------------------------------------------
;;;
;;; A polling subscriber reads through READ-FORWARD, which remembers a byte
;;; position and covers only what was appended since. The saving is real but the
;;; failure it invites is silent: a reader that trusts a position it should not
;;; skips records and reports nothing wrong. These tests pin the equivalence with
;;; the full read, and each of the three ways a remembered position goes bad.

(define-test incremental-read-matches-full-read
  "Paged reads through one reader return exactly what an unbounded READ-RECORDS
   returns: same seqs, same bodies, same order. If the two ever disagree the
   cheap path is not an optimisation, it is a second implementation."
  (with-wal (w)
    (loop for s from 1 to 40 do (append-record w s (format nil "body-~D" s)))
    (let ((r (make-reader))
          (paged '()))
      (loop for page = (read-forward w r :limit 7)
            while page do (setf paged (append paged page)))
      (let ((full (read-records w)))
        (is equal (mapcar #'record-seq full) (mapcar #'record-seq paged))
        (is equal (mapcar #'record-body-string full)
            (mapcar #'record-body-string paged))))))

(define-test drained-reader-sits-at-the-end-of-the-log
  "Having read everything, the reader's position IS the end of the file, so the
   next read of a quiet log covers no record bytes at all. That is the whole
   point of the exercise, and it must not cost the record appended next."
  (with-wal (w)
    (write-good-wal w 20)
    (let ((r (make-reader)))
      (is = 20 (length (read-forward w r :limit nil)))
      (is = (length (file-bytes w)) (reader-offset r))
      (is eq nil (read-forward w r) "a quiet log delivers nothing")
      (is = (length (file-bytes w)) (reader-offset r) "and moves nothing")
      (append-record w 21 "x")
      (is equal '(21) (mapcar #'record-seq (read-forward w r))))))

(define-test bounded-read-strands-nothing-it-declined-to-return
  "A LIMIT stops the reader at the last record it handed over, never past it, so
   the records it declined are the very next ones the following read returns. A
   position that ran ahead of the batch would drop them with no error anywhere."
  (with-wal (w)
    (write-good-wal w 25)
    (let ((r (make-reader))
          (seen '()))
      (loop repeat 3
            do (setf seen (append seen (read-forward w r :limit 4))))
      (is equal '(1 2 3 4 5 6 7 8 9 10 11 12) (mapcar #'record-seq seen))
      (is equal (loop for s from 13 to 25 collect s)
          (mapcar #'record-seq (read-forward w r :limit nil))))))

(define-test emptied-log-sends-the-reader-back-to-the-head
  "Archival empties the active log under a live reader. Its remembered position
   now describes a file that no longer exists, and the replacement has to be read
   from the head. Trusting the position here is how a subscriber goes deaf at
   exactly the moment the next cohort comes up."
  (with-wal (w)
    (write-good-wal w 12 "old")
    (let ((r (make-reader)))
      (is = 12 (length (read-forward w r :limit nil)))
      (empty-wal w)
      (loop for s from 1 to 6 do (append-record w s "new"))
      (multiple-value-bind (recs restarted) (read-forward w r :limit nil)
        (true restarted "the reader reports that it restarted")
        (is equal '(1 2 3 4 5 6) (mapcar #'record-seq recs))
        (is equal '("new")
            (remove-duplicates (mapcar #'record-body-string recs) :test #'string=)
            "and the records are the new log's, not the old one's")))))

(define-test replacement-log-of-the-same-shape-is-not-mistaken-for-the-old-one
  "The rotation that hides. The replacement log carries records of the SAME size
   and starts numbering again from 1, so at the reader's remembered offset there
   sits a perfectly valid record bearing exactly the seq the reader is expecting;
   and the file has grown past that offset again, so its length gives nothing
   away either. Catching the substitution takes recognising the individual record
   by its CRC and its timestamp, not merely establishing that it is well formed.
   Get this wrong and the whole head of the new log is skipped, silently, with
   every integrity check still passing."
  (with-wal (w)
    (write-good-wal w 50 "aaaaaaaaaaaaaaaaaaaa")
    (let* ((r (make-reader))
           (stale (progn (read-forward w r :limit nil) (reader-offset r))))
      (empty-wal w)
      (loop for s from 1 to 90 do (append-record w s "bbbbbbbbbbbbbbbbbbbb"))
      (true (> (length (file-bytes w)) stale)
            "the replacement must grow past the stale offset for this to bite")
      (multiple-value-bind (recs restarted) (read-forward w r :limit nil)
        (true restarted "the reader reports that it restarted")
        (is = 90 (length recs) "the new log's head is not skipped")
        (is = 1 (record-seq (first recs)))
        (is equal (mapcar #'record-seq (read-records w))
            (mapcar #'record-seq recs))))))

(define-test torn-tail-stops-the-read-and-is-picked-up-once-it-completes
  "A partial trailing record stops the read and is never handed over. The reader
   does not step past it either, so when the writer finishes the record a later
   read returns it in its proper place. The file is not touched: repairing a torn
   tail belongs to a successor broker, never to a reader."
  (with-wal (w)
    (write-good-wal w 5)
    (let ((r (make-reader))
          (full (encode-record 6 "x")))
      (is equal '(1 2 3 4 5) (mapcar #'record-seq (read-forward w r :limit nil)))
      (append-raw w (subseq full 0 (+ 8 4)))         ; header plus four payload bytes
      (let ((torn-size (length (file-bytes w))))
        (is eq nil (read-forward w r) "the torn record is not delivered")
        (is = torn-size (length (file-bytes w)) "and the log is left alone"))
      (append-raw w (subseq full (+ 8 4)))           ; the writer finishes it
      (is equal '(6) (mapcar #'record-seq (read-forward w r)))
      (is equal '(1 2 3 4 5 6) (mapcar #'record-seq (read-records w))))))

;;; the log's generation -------------------------------------------------------
;;;
;;; Sealing the log is the only event that makes it a different log. These pin
;;; that its identity moves exactly then, and the last of them pins the case
;;; that matters most: a seal that did not happen.

(defmacro with-sealable-wal ((dir wal) &body body)
  "A fresh temp directory holding an active log, so the log can be sealed into
   an archive beside it and the whole tree deleted after. A unique name is
   borrowed from a temp FILE, which is then deleted and recreated as a directory
   so the path cannot collide across runs."
  (let ((name (gensym "NAME")))
    `(let* ((,name (uiop:with-temporary-file (:pathname p :keep t :prefix "dsmr-bus-gen") p))
            (,dir (progn (ignore-errors (delete-file ,name))
                         (uiop:ensure-directory-pathname ,name)))
            (,wal (merge-pathnames "bus.wal" ,dir)))
       (ensure-directories-exist ,dir)
       (unwind-protect (progn ,@body)
         (ignore-errors (uiop:delete-directory-tree
                         ,dir :validate t :if-does-not-exist :ignore))))))

(define-test a-log-that-has-never-been-sealed-is-generation-zero
  "An absent generation file is an answer, not a missing one. Every bus already
   on disk is in exactly this position, and a reader that raised instead of
   answering would break all of them on the day this shipped."
  (with-sealable-wal (dir w)
    (write-good-wal w 3)
    (false (probe-file (generation-path w)) "no generation file has been written")
    (is = 0 (generation w))))

(define-test sealing-the-log-advances-the-generation-and-resets-the-head
  "One seal, one step, and the head back to nothing. Both are asserted together
   because they are two halves of one event: a generation that moved without the
   head resetting, or a head that reset without the generation moving, would
   mean the identity and the log it names had come apart, which is the state
   every reader of both is being asked to trust cannot arise."
  (with-sealable-wal (dir w)
    (write-good-wal w 6)
    (is = 6 (scan w))
    (archive-wal w dir :now 1000)
    (is = 1 (generation w))
    (is = 0 (scan w))))

(define-test a-second-seal-advances-the-generation-again
  "The generation counts seals rather than recording that one has happened, so
   a position recorded two cohorts ago is as plainly not this log's as one
   recorded during the last."
  (with-sealable-wal (dir w)
    (write-good-wal w 2)
    (archive-wal w dir :now 1000)
    (loop for s from 1 to 3 do (append-record w s "x"))
    (archive-wal w dir :now 2000)
    (is = 2 (generation w))
    (is = 0 (scan w))))

(define-test a-seal-that-failed-leaves-the-generation-where-it-was
  "The control on the three above. The identity has to be tied to the seal
   actually happening rather than merely written near it. An archive that could
   not be written leaves the log exactly where it was, and every reader holding
   a position against that log is still reading the right one: telling them
   otherwise would manufacture the alarm this identity exists to make truthful."
  (with-sealable-wal (dir w)
    (let ((sealed (merge-pathnames "sealed/" dir)))
      (ensure-directories-exist sealed)
      (write-good-wal w 4)
      (unwind-protect
           (progn
             (uiop:run-program (list "chmod" "500" (uiop:native-namestring sealed)))
             (is eq :refused
                 (handler-case (progn (archive-wal w sealed :now 1000) :sealed)
                   (error () :refused))
                 "the archive could not be written")
             (is = 0 (generation w) "so the generation did not move")
             (is = 4 (scan w) "and the log is still the one readers hold a position against"))
        (uiop:run-program (list "chmod" "700" (uiop:native-namestring sealed))
                          :ignore-error-status t)))))
