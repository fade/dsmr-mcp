;;;; src/bus/archive.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Orderly archival of the bus write-ahead log. When the LAST member leaves the
;;;; bus on a clean shutdown, the active log has served its purpose and is rotated
;;;; to a timestamped archive, leaving a fresh empty log for the next cohort. When
;;;; a process CRASHES the log must instead survive untouched so the next broker
;;;; can replay it.
;;;;
;;;; Both halves of that come from where the code lives, not from a runtime guess:
;;;;
;;;;   - "Last one out" is decided by upgrading the shared membership lock to
;;;;     exclusive (see the election module). It succeeds only when no other member
;;;;     still holds the shared lock.
;;;;
;;;;   - Rotation is reachable ONLY from a deliberate clean-shutdown path. A crash
;;;;     (SIGKILL, power loss) never runs that path, so it can never archive — the
;;;;     log is simply left for replay. There is no "was this a crash?" check to
;;;;     get wrong; the guarantee is that the rotation call is absent from every
;;;;     non-clean exit.
;;;;
;;;; Before sealing, the log is recovered (any torn tail truncated) so an archive
;;;; is always a clean, replayable prefix.

(defpackage #:dsmr-mcp/src/bus/archive
  (:use #:cl)
  (:local-nicknames (#:wal #:dsmr-mcp/src/bus/wal)
                    (#:election #:dsmr-mcp/src/bus/election))
  (:export #:archive-wal
           #:last-member-p
           #:archive-on-clean-exit))

(in-package #:dsmr-mcp/src/bus/archive)

(defun %empty-file (path)
  "Replace PATH with a zero-length file."
  (close (open path :element-type '(unsigned-byte 8) :direction :output
                    :if-exists :supersede :if-does-not-exist :create))
  path)

(defun %wal-empty-p (wal-path)
  (let ((p (probe-file wal-path)))
    (or (null p)
        (with-open-file (in p :element-type '(unsigned-byte 8))
          (zerop (file-length in))))))

(defun archive-wal (wal-path archive-dir &key (now nil now-supplied-p))
  "Rotate WAL-PATH to a timestamped archive under ARCHIVE-DIR and reset the active
   log to empty. The archive is named <wal-basename>.archive-<ms>. Returns the
   archive pathname, or NIL if the log was already empty (nothing to seal). The
   log is recovered first, so the archive holds a clean, replayable prefix."
  (when (%wal-empty-p wal-path)
    (return-from archive-wal nil))
  (wal:recover wal-path)                 ; truncate any torn tail before sealing
  (let* ((stamp (if now-supplied-p now (wal:now-ms)))
         (archive (merge-pathnames
                   (format nil "~A.archive-~D" (file-namestring wal-path) stamp)
                   (uiop:ensure-directory-pathname archive-dir))))
    (ensure-directories-exist archive)
    (uiop:copy-file wal-path archive)
    (%empty-file wal-path)
    ;; Last, and only once the seal has actually happened. The generation is how
    ;; a reader tells "nothing new" from "I am reading against a log that no
    ;; longer exists", so it has to move exactly when the log it names is
    ;; replaced. An archive that failed to copy leaves the live log where it was
    ;; and must leave the generation there too.
    (wal:bump-generation wal-path)
    archive))

(defun last-member-p (members-fd)
  "True iff this process is the only one still holding the shared membership lock
   on MEMBERS-FD — so a clean shutdown here is the last one out."
  (election:try-upgrade-exclusive members-fd))

(defun archive-on-clean-exit (members-fd wal-path archive-dir)
  "Clean-shutdown hook: if this is the last member out, rotate the WAL to an
   archive and return its pathname; otherwise return NIL. Reachable only from a
   deliberate shutdown path, so a crash never archives."
  (when (last-member-p members-fd)
    (archive-wal wal-path archive-dir)))
