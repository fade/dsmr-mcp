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
;;;; SCAN and READ-FORWARD are read-only and are what subscribers and the wakeup
;;;; waiter use: a reader must never clip a broker's in-flight write. RECOVER is
;;;; the successor broker's repair step on failover and is the ONLY operation that
;;;; truncates a torn tail. Keeping those two apart is what makes concurrent
;;;; read-while-write safe.

(defpackage #:dsmr-mcp/src/bus/wal
  (:use #:cl)
  (:export #:crc32
           #:now-ms
           #:record #:record-seq #:record-ts #:record-body #:record-body-string
           #:encode-record
           #:append-record
           #:scan
           #:read-records
           #:reader #:make-reader #:reset-reader
           #:reader-offset #:reader-anchor #:reader-last-seq
           #:read-forward
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

(defun read-file-bytes-from (path start &key end)
  "Read PATH from byte offset START up to END, or to EOF when END is NIL.
   Returns (values bytes total) where TOTAL is the file's current length.

   BYTES is NIL, deliberately rather than an empty vector, whenever the file turns
   out SHORTER than the caller expected: START past EOF, or END past EOF. That is
   how a log which has been rotated or truncated under a reader announces itself,
   and it is the reader's cue to stop trusting the byte offset it was holding. An
   empty vector would say the opposite, that the caller's offset is still the live
   end of the log, which is the reading that goes silently deaf."
  (flet ((absent ()
           (values (if (plusp start)
                       nil
                       (make-array 0 :element-type '(unsigned-byte 8)))
                   0)))
    (if (probe-file path)
        (with-open-file (in path :element-type '(unsigned-byte 8)
                                 :if-does-not-exist nil)
          (if in
              (let ((total (file-length in)))
                (if (or (> start total) (and end (> end total)))
                    (values nil total)
                    (let* ((stop (or end total))
                           (vec (make-array (max 0 (- stop start))
                                            :element-type '(unsigned-byte 8))))
                      (file-position in start)
                      (read-sequence vec in)
                      (values vec total))))
              (absent)))
        (absent))))

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

(defun walk-records (bytes fn &key (initial-seq 0) (base 0))
  "Walk BYTES front-to-back, calling FN with (seq ts payload-start rec-end) for
   each good record. Stops at the first torn record (partial header, impossible
   length, partial payload, or CRC mismatch). Returns (values last-seq good-bytes
   records) where good-bytes is the offset of the end of the last good record.
   Signals an error if the seq column is non-contiguous — only a broken election
   can produce that, so the WAL detects its own correctness.

   INITIAL-SEQ is the seq carried by the record immediately before BYTES, so a
   caller holding a slice of the log rather than the whole of it continues the
   contiguity check across the join instead of demanding that BYTES begin at seq
   1. BASE is that slice's byte offset within the file and is used only so a
   contiguity failure reports a real file offset an operator can seek to. Both
   default to 0, which is the whole-file case."
  (let ((total (length bytes))
        (pos 0)
        (last-seq initial-seq)
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
                         (1+ last-seq) seq (+ base pos)))
                (setf last-seq seq)
                (incf records)
                (funcall fn seq ts payload-start rec-end)
                (setf pos rec-end)))))))
    (values last-seq pos records)))

(defun scan (path)
  "READ-ONLY replay of PATH. Returns (values last-seq good-bytes records total),
   stopping at the torn tail WITHOUT modifying the file. Repairing the torn tail
   is RECOVER's job. This is the whole-log question (how far has the log got?) and
   costs the whole log to answer; a caller that wants the records themselves, and
   especially one that wants them repeatedly, should hold a READER and call
   READ-FORWARD."
  (let* ((bytes (read-file-bytes path))
         (total (length bytes)))
    (multiple-value-bind (last-seq good-bytes records)
        (walk-records bytes (lambda (seq ts pstart pend)
                              (declare (ignore seq ts pstart pend))))
      (values last-seq good-bytes records total))))

;;; ------------------------------------------------- incremental tail reads
;;;
;;; A one-off read of the log costs the whole log, and for a one-off read that is
;;; the right price. A subscriber polling for new messages is not a one-off read:
;;; it asks the same question several times a second for the life of the process,
;;; and paying for every byte written since the bus came up, every time, in every
;;; attached process, turns an idle fleet into a measurable fraction of the
;;; machine. The log is append-only, so a reader that remembers where it stopped
;;; can read the tail instead, and the cost of a quiet poll stops tracking the
;;; size of the history.
;;;
;;; What that trades away is re-verification of records already read and handed
;;; over. What it must not trade away is that no record is EVER handed over
;;; unverified, that the seq column is still asserted contiguous across the join,
;;; and that a remembered offset is never trusted blindly. The last of those is
;;; the sharp edge: the log can be rotated out from under a live reader (see the
;;; archive module), leaving the offset pointing into the middle of a different,
;;; shorter or differently-numbered log. Every incremental read therefore re-reads
;;; and re-verifies the record its offset sits behind before believing it, and
;;; drops back to a full read from the head when that check fails.

(defstruct (reader (:constructor make-reader ()))
  "One consumer's in-memory position in a WAL: where its last read stopped, plus
   enough of the record it stopped on to RECOGNISE that record again, so the next
   read need only cover the bytes appended since.

   This is scratch, not state. It is never written to disk and never shared: a
   fresh READER reads the whole log once and is incremental from then on, which
   is exactly what every process does on its first read. Losing one costs a single
   full read and nothing else."
  (offset 0 :type unsigned-byte)    ; byte just past the last record accounted for
  (anchor 0 :type unsigned-byte)    ; byte at which that record starts
  (last-seq 0 :type unsigned-byte)  ; seq that record carried
  (last-crc 0 :type unsigned-byte)  ; its stored CRC, the identifying half
  (last-ts 0 :type unsigned-byte))  ; its timestamp, the other half

(defun reset-reader (reader)
  "Forget READER's position, sending its next read back to the head of the log."
  (setf (reader-offset reader) 0
        (reader-anchor reader) 0
        (reader-last-seq reader) 0
        (reader-last-crc reader) 0
        (reader-last-ts reader) 0)
  reader)

(defun %anchor-intact-p (path reader)
  "True when PATH still holds, at READER's anchor, THE RECORD READER STOPPED ON.
   Not merely a well-formed record: that one, with the same length, seq, timestamp
   and stored CRC.

   The distinction is the whole check. Rotation empties the active log and the
   next broker numbers from 1 again, so a log which carries records of the same
   shape puts an equally valid record, bearing the very same seq, at the very same
   byte offset. A check that asked only 'is there a good record here?' would pass
   on that, and the reader would resume mid-log with everything below it skipped:
   a subscriber gone silently deaf while looking perfectly healthy. Asking 'is it
   THIS record?' is what rules that out, because the CRC covers the timestamp and
   the body, so a record written at a different moment does not answer to it.

   Cost is the 24-byte prefix (length, CRC, seq, timestamp) and nothing more. A
   false negative costs one full read; a false positive costs messages, so where
   the two trade off the check is deliberately the strong one."
  (let* ((anchor (reader-anchor reader))
         (span (- (reader-offset reader) anchor))
         (probe (+ +header-bytes+ +fixed-payload+)))
    (and (>= span probe)
         (let ((bytes (read-file-bytes-from path anchor :end (+ anchor probe))))
           (and bytes
                (= (get-u32 bytes 0) (- span +header-bytes+))
                (= (get-u32 bytes 4) (reader-last-crc reader))
                (= (get-u64 bytes +header-bytes+) (reader-last-seq reader))
                (= (get-u64 bytes (+ +header-bytes+ 8)) (reader-last-ts reader)))))))

(defun read-forward (path reader &key (after 0) limit)
  "READ-ONLY: the records of PATH with seq > AFTER that READER has not already
   accounted for, oldest first, advancing READER over them. Returns
   (values records restarted-p).

   The result is the same list READ-RECORDS returns for the same PATH, AFTER and
   LIMIT. What differs is how much of the file is touched to produce it: READER
   carries the byte at which the previous call stopped, so a caller polling a
   quiet log pays for the bytes appended since rather than for the whole log
   again. Every guarantee READ-RECORDS makes still holds. Each record is
   CRC-verified on the read that first hands it over, the seq column is asserted
   contiguous across the join, and a torn tail stops the read cleanly, is never
   handed back, and is picked up by a later call once the record completes.

   READER advances to the end of the last record it either handed back or stepped
   over as already consumed (seq <= AFTER), and stops short of anything LIMIT held
   back, so a bounded read never strands the records it declined to return.

   RESTARTED-P is true when READER's offset failed verification and the read fell
   back to the head of the file, which is what a rotated or truncated log looks
   like from here."
  (let ((restarted nil))
    (when (and (plusp (reader-offset reader))
               (not (%anchor-intact-p path reader)))
      (reset-reader reader)
      (setf restarted t))
    (let ((bytes (read-file-bytes-from path (reader-offset reader))))
      (when (null bytes)                 ; offset past EOF: the log shrank
        (reset-reader reader)
        (setf restarted t)
        (setf bytes (read-file-bytes-from path 0)))
      (let ((base (reader-offset reader))
            (kept 0)
            (out '())
            (held nil)
            (frontier-start nil)
            (frontier-end nil)
            (frontier-seq nil)
            (frontier-crc nil)
            (frontier-ts nil))
        (walk-records
         bytes
         (lambda (seq ts pstart pend)
           (unless held
             (cond ((<= seq after))      ; already consumed: step over it
                   ((or (null limit) (< kept limit))
                    (incf kept)
                    (push (%make-record seq ts
                                        (subseq bytes (+ pstart +fixed-payload+) pend))
                          out))
                   (t (setf held t)))
             (unless held
               (setf frontier-start (- pstart +header-bytes+)
                     frontier-end pend
                     frontier-seq seq
                     frontier-ts ts
                     ;; the stored CRC sits in the second half of the header,
                     ;; immediately before the payload this callback was handed
                     frontier-crc (get-u32 bytes (- pstart 4))))))
         :initial-seq (reader-last-seq reader)
         :base base)
        (when frontier-seq
          (setf (reader-anchor reader) (+ base frontier-start)
                (reader-offset reader) (+ base frontier-end)
                (reader-last-seq reader) frontier-seq
                (reader-last-crc reader) frontier-crc
                (reader-last-ts reader) frontier-ts))
        (values (nreverse out) restarted)))))

(defun read-records (path &key (after 0) limit)
  "READ-ONLY: return a list of RECORD structs for every good record with
   seq > AFTER, in order. Stops at the torn tail; never truncates.

   LIMIT, when a positive integer, caps how many records are COLLECTED — the
   oldest LIMIT records past AFTER, so successive calls with an advancing AFTER
   page forward through the log. When NIL (the default) every matching record is
   returned, byte-identical to an uncapped read.

   The file is walked front-to-back in full even under a LIMIT. That walk is the
   WAL's self-correctness check: each record's CRC is verified and the seq column
   is asserted contiguous, so a torn or corrupt record beyond the requested page
   is detected on the very read that skipped it rather than surviving until some
   later call happens to reach that far. What LIMIT removes is the per-record
   payload copy for records past the page, which is where the memory cost of a
   large backlog lives.

   Reading the whole file is the right shape for a one-off question and the wrong
   one for a poll. A caller that asks repeatedly should hold a READER and call
   READ-FORWARD, which answers the same question from the bytes appended since its
   last look; this entry point is for the caller that genuinely wants the whole log
   in one go, and it is implemented as READ-FORWARD over a throwaway reader so the
   two can never disagree about what the log says."
  (values (read-forward path (make-reader) :after after :limit limit)))

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
