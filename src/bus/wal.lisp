;;;; src/bus/wal.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Write-ahead log for the coordination bus. The bus elects a broker by flock
;;;; and treats this append-only log as the single source of truth: the monotonic
;;;; sequence number is the global message index, and a successor broker recovers
;;;; simply by replaying the log — no consensus, no replication. That makes two
;;;; properties load-bearing, and both are enforced here rather than assumed:
;;;;
;;;;   1. A broker SIGKILLed mid-write leaves a TORN TAIL — a partial final
;;;;      record. Recovery must detect it and refuse to hand a corrupt record to
;;;;      the successor. Each record is therefore self-describing and CRC-checked;
;;;;      the first record that fails any check is the torn tail.
;;;;
;;;;   2. Only one broker writes at a time (flock guarantees it). The sequence
;;;;      column must read 1,2,3,... with no hole and no repeat. Recovery asserts
;;;;      that as it replays, so the log is the detector of its own correctness:
;;;;      a gap can only mean two brokers wrote concurrently — an election bug.
;;;;
;;;; On-disk record (little-endian):
;;;;
;;;;   [u32 payload-length]   bytes of payload that follow the CRC
;;;;   [u32 crc32]            IEEE-802.3 CRC of the payload bytes
;;;;   payload = [u64 seq][u64 timestamp-ms][body bytes]
;;;;
;;;; SCAN is read-only and is what subscribers and the wakeup waiter use — a
;;;; reader must never clip a broker's in-flight write. RECOVER is the successor
;;;; broker's repair step on failover and is the ONLY operation that truncates a
;;;; torn tail. Keeping those two apart is what makes concurrent read-while-write
;;;; safe.

(defpackage #:dsmr-mcp/src/bus/wal
  (:use #:cl)
  (:export #:crc32
           #:now-ms
           #:record #:record-seq #:record-ts #:record-body #:record-body-string
           #:encode-record
           #:append-record
           #:scan
           #:read-records
           #:recover
           #:recovery #:recovery-last-seq #:recovery-good-bytes
           #:recovery-records #:recovery-truncated-from))

(in-package #:dsmr-mcp/src/bus/wal)

;;; ----------------------------------------------------------------- CRC-32

(defparameter *crc32-table*
  (let ((table (make-array 256 :element-type '(unsigned-byte 32))))
    (dotimes (n 256 table)
      (let ((c n))
        (dotimes (k 8)
          (setf c (if (logbitp 0 c)
                      (logxor #xEDB88320 (ash c -1))
                      (ash c -1))))
        (setf (aref table n) c))))
  "Reflected IEEE-802.3 CRC-32 lookup table (polynomial #xEDB88320).")

(defun crc32 (bytes &optional (start 0) (end (length bytes)))
  "Standard CRC-32 of BYTES[start,end). crc32(#\"123456789\") = #xCBF43926."
  (let ((crc #xFFFFFFFF))
    (loop for i from start below end
          for b = (aref bytes i)
          do (setf crc (logxor (ash crc -8)
                               (aref *crc32-table* (logand (logxor crc b) #xFF)))))
    (logxor crc #xFFFFFFFF)))

;;; ------------------------------------------------------- byte primitives

(declaim (inline put-u32 get-u32 put-u64 get-u64))

(defun put-u32 (vec pos value)
  (setf (aref vec (+ pos 0)) (ldb (byte 8 0)  value)
        (aref vec (+ pos 1)) (ldb (byte 8 8)  value)
        (aref vec (+ pos 2)) (ldb (byte 8 16) value)
        (aref vec (+ pos 3)) (ldb (byte 8 24) value))
  (+ pos 4))

(defun get-u32 (vec pos)
  (logior (aref vec (+ pos 0))
          (ash (aref vec (+ pos 1)) 8)
          (ash (aref vec (+ pos 2)) 16)
          (ash (aref vec (+ pos 3)) 24)))

(defun put-u64 (vec pos value)
  (dotimes (i 8 (+ pos 8))
    (setf (aref vec (+ pos i)) (ldb (byte 8 (* 8 i)) value))))

(defun get-u64 (vec pos)
  (let ((v 0))
    (dotimes (i 8 v)
      (setf v (logior v (ash (aref vec (+ pos i)) (* 8 i)))))))

(defconstant +header-bytes+ 8 "u32 payload-length + u32 crc32")
(defconstant +fixed-payload+ 16 "u64 seq + u64 timestamp-ms, before the body")

(defun now-ms ()
  "Wall-clock milliseconds since the epoch."
  (multiple-value-bind (sec usec) (sb-ext:get-time-of-day)
    (+ (* sec 1000) (floor usec 1000))))

(defun to-octets (body)
  "Coerce BODY (octet vector or string) to a simple octet vector."
  (etypecase body
    (string (sb-ext:string-to-octets body :external-format :utf-8))
    ((vector (unsigned-byte 8)) body)))

;;; ------------------------------------------------------------- records

(defstruct (record (:constructor %make-record (seq ts body)))
  (seq 0 :type unsigned-byte)
  (ts 0 :type unsigned-byte)
  (body #() :type (vector (unsigned-byte 8))))

(defun record-body-string (record)
  "The record body decoded as a UTF-8 string."
  (sb-ext:octets-to-string (record-body record) :external-format :utf-8))

(defun encode-record (seq body &key (ts (now-ms)))
  "Build the on-disk byte vector for one record. BODY is an octet vector or a
   string (UTF-8 encoded)."
  (let* ((body-bytes (to-octets body))
         (payload-len (+ +fixed-payload+ (length body-bytes)))
         (vec (make-array (+ +header-bytes+ payload-len)
                          :element-type '(unsigned-byte 8)))
         (payload (make-array payload-len :element-type '(unsigned-byte 8))))
    (put-u64 payload 0 seq)
    (put-u64 payload 8 ts)
    (replace payload body-bytes :start1 +fixed-payload+)
    (put-u32 vec 0 payload-len)
    (put-u32 vec 4 (crc32 payload))
    (replace vec payload :start1 +header-bytes+)
    vec))

;;; --------------------------------------------------------------- file I/O

(defun read-file-bytes (path)
  (if (probe-file path)
      (with-open-file (in path :element-type '(unsigned-byte 8) :if-does-not-exist nil)
        (if in
            (let ((vec (make-array (file-length in) :element-type '(unsigned-byte 8))))
              (read-sequence vec in)
              vec)
            (make-array 0 :element-type '(unsigned-byte 8))))
      (make-array 0 :element-type '(unsigned-byte 8))))

(defun append-record (path seq body &key (ts (now-ms)))
  "Append one record to PATH and return SEQ."
  (let ((rec (encode-record seq body :ts ts)))
    (with-open-file (out path :element-type '(unsigned-byte 8)
                              :direction :output :if-exists :append
                              :if-does-not-exist :create)
      (write-sequence rec out)
      (finish-output out))
    seq))

;;; -------------------------------------------------------------- replay

(defun walk-records (bytes fn)
  "Walk BYTES front-to-back, calling FN with (seq ts payload-start rec-end) for
   each good record. Stops at the first torn record (partial header, impossible
   length, partial payload, or CRC mismatch). Returns (values last-seq good-bytes
   records) where good-bytes is the offset of the end of the last good record.
   Signals an error if the seq column is non-contiguous — only a broken election
   can produce that, so the WAL detects its own correctness."
  (let ((total (length bytes))
        (pos 0)
        (last-seq 0)
        (records 0))
    (loop
      (let ((remaining (- total pos)))
        (when (zerop remaining) (return))            ; clean EOF
        (when (< remaining +header-bytes+) (return)) ; torn: partial header
        (let ((payload-len (get-u32 bytes pos))
              (stored-crc  (get-u32 bytes (+ pos 4))))
          (let ((rec-end (+ pos +header-bytes+ payload-len)))
            (when (or (< payload-len +fixed-payload+) ; impossible length: torn
                      (> rec-end total))              ; torn: partial payload
              (return))
            (let ((payload-start (+ pos +header-bytes+)))
              (unless (= stored-crc (crc32 bytes payload-start rec-end))
                (return))                             ; torn: CRC mismatch
              (let ((seq (get-u64 bytes payload-start))
                    (ts  (get-u64 bytes (+ payload-start 8))))
                (unless (= seq (1+ last-seq))
                  (error "WAL seq non-contiguous: expected ~D, found ~D at offset ~D"
                         (1+ last-seq) seq pos))
                (setf last-seq seq)
                (incf records)
                (funcall fn seq ts payload-start rec-end)
                (setf pos rec-end)))))))
    (values last-seq pos records)))

(defun scan (path)
  "READ-ONLY replay of PATH. Returns (values last-seq good-bytes records total),
   stopping at the torn tail WITHOUT modifying the file. Subscribers and the
   wakeup waiter use this — repairing the torn tail is RECOVER's job."
  (let* ((bytes (read-file-bytes path))
         (total (length bytes)))
    (multiple-value-bind (last-seq good-bytes records)
        (walk-records bytes (lambda (seq ts pstart pend)
                              (declare (ignore seq ts pstart pend))))
      (values last-seq good-bytes records total))))

(defun read-records (path &key (after 0))
  "READ-ONLY: return a list of RECORD structs for every good record with
   seq > AFTER, in order. Stops at the torn tail; never truncates."
  (let ((bytes (read-file-bytes path))
        (out '()))
    (walk-records bytes
                  (lambda (seq ts pstart pend)
                    (when (> seq after)
                      (push (%make-record seq ts
                                          (subseq bytes (+ pstart +fixed-payload+) pend))
                            out))))
    (nreverse out)))

(defun write-prefix (path bytes end)
  (with-open-file (out path :element-type '(unsigned-byte 8)
                            :direction :output :if-exists :supersede
                            :if-does-not-exist :create)
    (write-sequence bytes out :end end)
    (finish-output out)))

(defstruct recovery
  (last-seq 0)          ; highest good seq replayed (0 = empty WAL)
  (good-bytes 0)        ; byte offset of the end of the last good record
  (records 0)           ; count of good records
  (truncated-from nil)) ; original length if a torn tail was cut, else NIL

(defun recover (path)
  "Replay PATH and TRUNCATE any torn tail to the end of the last good record.
   This is the successor broker's repair step on failover — the only WAL-mutating
   recovery operation. Returns a RECOVERY describing the result."
  (multiple-value-bind (last-seq good-bytes records total) (scan path)
    (let ((truncated (when (< good-bytes total)
                       (write-prefix path (read-file-bytes path) good-bytes)
                       total)))
      (make-recovery :last-seq last-seq :good-bytes good-bytes
                     :records records :truncated-from truncated))))
