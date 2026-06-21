;;;; tests/bus/archive-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Parachute tests for orderly WAL archival. The contract: a non-empty log
;;;; rotates to a clean, replayable archive and resets to empty; an empty log is a
;;;; no-op; and the last-member gate only fires when no other member holds the
;;;; shared lock — so only the genuine last-one-out archives. (A real SIGKILL
;;;; never running the shutdown path is covered structurally + by the integration
;;;; suite.)

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/bus/archive-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/bus/archive-test
  (:use #:cl #:parachute)
  (:local-nicknames (#:wal #:dsmr-mcp/src/bus/wal)
                    (#:election #:dsmr-mcp/src/bus/election)
                    (#:archive #:dsmr-mcp/src/bus/archive)))

(in-package #:dsmr-mcp/tests/bus/archive-test)

(defmacro with-bus-dir ((dir wal) &body body)
  "A fresh temp directory holding an active bus WAL, cleaned up after. A unique
   name is borrowed from a temp FILE, which is then deleted and recreated as a
   directory so the path is guaranteed not to collide across runs."
  (let ((name (gensym "NAME")))
    `(let* ((,name (uiop:with-temporary-file (:pathname p :keep t :prefix "dsmr-bus-arch") p))
            (,dir (progn (ignore-errors (delete-file ,name))
                         (uiop:ensure-directory-pathname ,name)))
            (,wal (merge-pathnames "bus.wal" ,dir)))
       (ensure-directories-exist ,dir)
       (unwind-protect (progn ,@body)
         (ignore-errors (uiop:delete-directory-tree
                         ,dir :validate t :if-does-not-exist :ignore))))))

(defun fill-wal (wal n)
  (loop for s from 1 to n do (wal:append-record wal s "x")))

(defun bytes-on-disk (path)
  (if (probe-file path)
      (with-open-file (in path :element-type '(unsigned-byte 8)) (file-length in))
      0))

(define-test archive-rotates-and-resets
  "A non-empty WAL is sealed into an archive that replays cleanly, and the active
   log is reset to empty."
  (with-bus-dir (dir wal)
    (fill-wal wal 6)
    (let ((archive (archive:archive-wal wal dir :now 1000)))
      (true archive "an archive path was returned")
      (true (probe-file archive) "archive file exists on disk")
      (is = 6 (length (wal:read-records archive)) "archive holds all 6 records")
      (is = 0 (bytes-on-disk wal) "active WAL reset to empty"))))

(define-test archive-name-carries-timestamp
  "The archive is named for the WAL basename plus the supplied timestamp."
  (with-bus-dir (dir wal)
    (fill-wal wal 1)
    (let ((archive (archive:archive-wal wal dir :now 424242)))
      (is string= "bus.wal.archive-424242" (file-namestring archive)))))

(define-test empty-wal-is-noop
  "Archiving an empty log seals nothing and creates no archive file."
  (with-bus-dir (dir wal)
    (wal:append-record wal 1 "x")
    (archive:archive-wal wal dir :now 1)          ; reset to empty
    (let ((again (archive:archive-wal wal dir :now 2)))
      (is eq nil again "second archive of the now-empty log is a no-op")
      (is = 1 (length (directory (merge-pathnames "*.archive-*" dir)))
          "only the first archive exists"))))

(define-test last-member-gates-archive
  "ARCHIVE-ON-CLEAN-EXIT seals only when this is the last member; while another
   member holds the shared lock it does nothing and the log survives."
  (with-bus-dir (dir wal)
    (fill-wal wal 3)
    (let ((members (merge-pathnames "members" dir)))
      (let ((m1 (election:open-lock members))
            (m2 (election:open-lock members)))
        (unwind-protect
             (progn
               (election:lock-shared m1)
               (election:lock-shared m2)
               ;; m1 tries to leave while m2 is still present -> not last out
               (is eq nil (archive:archive-on-clean-exit m1 wal dir)
                   "no archive while another member is alive")
               (is = 3 (length (wal:read-records wal)) "log survives")
               ;; m2 leaves; m1 is now the last one out -> archives
               (election:close-lock m2)
               (let ((archive (archive:archive-on-clean-exit m1 wal dir)))
                 (true archive "last member out archives")
                 (is = 0 (bytes-on-disk wal) "active WAL reset after last-out archive")))
          (ignore-errors (election:close-lock m1)))))))