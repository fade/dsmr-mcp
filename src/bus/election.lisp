;;;; src/bus/election.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Broker election and membership for the coordination bus, built on flock(2).
;;;;
;;;; A flock advisory lock is tied to an open file description and is released
;;;; automatically when the holding process dies — even on SIGKILL. That gives us
;;;; election and crash-detection from one primitive, with no heartbeat to tune
;;;; and no stale-socket EADDRINUSE trap that a bind-based election would hit:
;;;;
;;;;   - The first process to take an exclusive non-blocking lock on the broker
;;;;     lockfile is the BROKER. Every other process becomes a CLIENT and takes a
;;;;     *blocking* exclusive lock; when the broker dies the OS drops its lock and
;;;;     exactly one waiter wakes to take over. That is the failover.
;;;;
;;;;   - Membership uses a *shared* lock on a separate file, held for a process's
;;;;     whole life. A process about to shut down cleanly tries to UPGRADE its
;;;;     shared lock to exclusive, non-blocking: success means no other member
;;;;     still holds the shared lock, so it is the last one out. That is the hook
;;;;     the orderly-archive step hangs on (a crash never runs that path, so a
;;;;     crash never looks like the last clean exit).
;;;;
;;;; sb-posix does not expose flock, so we bind libc flock(2) through sb-alien.
;;;; This is dsmr-mcp's own single-host infrastructure and is intentionally
;;;; SBCL-specific; it is never injected into a foreign attached image.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-posix))

(defpackage #:dsmr-mcp/src/bus/election
  (:use #:cl)
  (:export #:open-lock #:close-lock
           #:try-lock-exclusive #:lock-exclusive
           #:lock-shared #:try-upgrade-exclusive
           #:unlock
           #:with-lock #:elect #:await-broker))

(in-package #:dsmr-mcp/src/bus/election)

(sb-alien:define-alien-routine ("flock" %flock) sb-alien:int
  (fd sb-alien:int) (operation sb-alien:int))

(defconstant +lock-sh+ 1 "LOCK_SH — shared advisory lock.")
(defconstant +lock-ex+ 2 "LOCK_EX — exclusive advisory lock.")
(defconstant +lock-nb+ 4 "LOCK_NB — fail instead of block.")
(defconstant +lock-un+ 8 "LOCK_UN — release.")

(defun open-lock (path)
  "Open (creating if needed) PATH for locking and return its file descriptor.
   The caller owns the fd and must CLOSE-LOCK it; closing also releases any lock
   held on it."
  (sb-posix:open (namestring path)
                 (logior sb-posix:o-creat sb-posix:o-rdwr)
                 #o644))

(defun close-lock (fd)
  "Close the lock file descriptor, releasing any lock held on it."
  (sb-posix:close fd))

(defun try-lock-exclusive (fd)
  "Try to take an exclusive lock without blocking. Returns T if acquired, NIL if
   another open file description already holds it (this is the election test)."
  (zerop (%flock fd (logior +lock-ex+ +lock-nb+))))

(defun lock-exclusive (fd)
  "Take an exclusive lock, BLOCKING until it is free. When called by a waiting
   client this returns the moment the current broker dies — the failover wakeup.
   Returns T."
  (zerop (%flock fd +lock-ex+)))

(defun lock-shared (fd)
  "Take a shared lock, blocking until granted. Many holders coexist; the lock is
   a per-process liveness token for membership. Returns T."
  (zerop (%flock fd +lock-sh+)))

(defun try-upgrade-exclusive (fd)
  "Try to upgrade a shared lock held on FD to exclusive, without blocking.
   Returns T only when no other open file description holds the shared lock — the
   caller is then the last member still alive (the last-one-out test)."
  (zerop (%flock fd (logior +lock-ex+ +lock-nb+))))

(defun unlock (fd)
  "Release whatever lock FD holds, keeping the fd open. Returns T."
  (zerop (%flock fd +lock-un+)))

(defmacro with-lock ((fd-var path) &body body)
  "Open a lock fd on PATH, bind it to FD-VAR for BODY, and close it afterward
   (releasing any lock taken inside)."
  `(let ((,fd-var (open-lock ,path)))
     (unwind-protect (progn ,@body)
       (ignore-errors (close-lock ,fd-var)))))

(defun elect (fd)
  "Contend for the broker role on FD without blocking. Returns :BROKER if this
   process won the exclusive lock, or :CLIENT if a broker already holds it."
  (if (try-lock-exclusive fd) :broker :client))

(defun await-broker (fd)
  "Block on FD until the broker role becomes available (the current broker died),
   then take it. Returns T once this process is the new broker."
  (lock-exclusive fd))
