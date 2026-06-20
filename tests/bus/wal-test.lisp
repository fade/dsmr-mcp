;;;; tests/bus/wal-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Parachute tests for the coordination-bus write-ahead log. The properties
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
  (:use #:cl #:parachute)
  (:import-from #:dsmr-mcp/src/bus/wal
                #:crc32
                #:encode-record
                #:append-record
                #:scan
                #:read-records
                #:recover
                #:record-seq #:record-body-string
                #:recovery-last-seq #:recovery-records #:recovery-truncated-from))

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
