;;;; tests/hermetic/hibernate-helpers-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Unit tests for the parts of a worker's save and resume that need no
;;;; worker: the refusal word for a fork that failed, and covering a resumed
;;;; world's stale descriptor numbers, also under a descriptor limit far below
;;;; the numbers a server usually reaches.
;;;;
;;;; The descriptor case lowers this process's soft descriptor limit for an
;;;; instant and puts it back, and closes every descriptor it opened.

(defpackage #:dsmr-mcp/tests/hermetic/hibernate-helpers-test
  (:use #:cl #:zebra)
  (:local-nicknames (#:hibernate #:dsmr-mcp/src/hermetic/worker/hibernate))
  (:import-from #:dsmr-mcp/src/hermetic/worker/hibernate
                #:install-descriptor-placeholders #:placeholder-floor
                #:descriptor-soft-limit #:*stale-descriptors*)
  (:import-from #:sb-alien)
  (:import-from #:sb-posix))

(in-package #:dsmr-mcp/tests/hermetic/hibernate-helpers-test)

;;; ---------------------------------------------------------------------------
;;; A fork that fails
;;; ---------------------------------------------------------------------------

(define-test a-fork-that-fails-for-memory-is-not-reported-as-threads
  "SBCL's refusal to fork with other threads running reads has-threads; any
other fork failure reads fork-failed."
  (is string= "has-threads"
      (hibernate::%fork-refusal-token
       (make-condition 'simple-error
                       :format-control "Cannot fork with multiple threads running.")))
  (is string= "fork-failed"
      (hibernate::%fork-refusal-token
       (make-condition 'simple-error
                       :format-control "fork(2) failed: Cannot allocate memory"))))

;;; ---------------------------------------------------------------------------
;;; Stale descriptor numbers in a resumed world
;;; ---------------------------------------------------------------------------

(defun %rlimit (&optional new-soft)
  "This process's soft descriptor limit. With NEW-SOFT, set the soft limit to
it first and return the previous one."
  (sb-alien:with-alien ((limits (array (sb-alien:unsigned 64) 2)))
    (sb-alien:alien-funcall
     (sb-alien:extern-alien "getrlimit"
                            (function sb-alien:int sb-alien:int
                                      (* (array (sb-alien:unsigned 64) 2))))
     7 (sb-alien:addr limits))
    (let ((old (sb-alien:deref limits 0)))
      (when new-soft
        (setf (sb-alien:deref limits 0) new-soft)
        (unless (zerop (sb-alien:alien-funcall
                        (sb-alien:extern-alien
                         "setrlimit"
                         (function sb-alien:int sb-alien:int
                                   (* (array (sb-alien:unsigned 64) 2))))
                        7 (sb-alien:addr limits)))
          (error "setrlimit refused ~D" new-soft)))
      old)))

(defun %open-descriptors ()
  "The descriptor numbers open in this process."
  (let ((dir (sb-posix:opendir "/proc/self/fd"))
        (fds '()))
    (unwind-protect
         (loop for entry = (sb-posix:readdir dir)
               until (sb-alien:null-alien entry)
               do (let ((n (ignore-errors
                            (parse-integer (sb-posix:dirent-name entry)))))
                    (when n (push n fds))))
      (sb-posix:closedir dir))
    fds))

(defun %points-at (fd)
  "What descriptor FD of this process is open on, or NIL."
  (ignore-errors (sb-posix:readlink (format nil "/proc/self/fd/~D" fd))))

(define-test the-placeholder-floor-sits-above-every-stale-number-below-the-limit
  "The floor is one above the highest stale number below the soft limit, a
number at or past the limit needs no room, and there is no floor when it
would reach the limit."
  (is = 10 (placeholder-floor '(3 5 9) 512))
  (is = 10 (placeholder-floor '(3 5 9) nil))
  (is = 4 (placeholder-floor '(3 600) 512))
  (false (placeholder-floor '(3 511) 512))
  (false (placeholder-floor '(600 700) 512))
  (false (placeholder-floor '() 512))
  (true (integerp (descriptor-soft-limit))))

(define-test stale-numbers-are-covered-under-a-low-descriptor-limit
  "With the soft descriptor limit far below 900, every free stale number is
covered with /dev/null, also one right under the limit where no placeholder
fits above it, and a number past the limit is reported, not fatal."
  (let* ((top (reduce #'max (%open-descriptors)))
         (limit (+ top 40))
         (stale (loop for fd from (+ top 5) below (+ top 15) collect fd))
         (edge (list (- limit 3) (- limit 1)))
         (beyond (+ limit 5))
         (old nil))
    (true (< limit 900) "the limit ~D is not low enough to test" limit)
    (unwind-protect
         (progn
           (setf old (%rlimit limit))
           (setf *stale-descriptors* stale)
           (multiple-value-bind (covered in-use uncovered)
               (install-descriptor-placeholders)
             (is = (length stale) covered)
             (false in-use)
             (false uncovered))
           (dolist (fd stale)
             (is equal "/dev/null" (%points-at fd) "fd ~D" fd))
           (setf *stale-descriptors* (append edge (list beyond)))
           (multiple-value-bind (covered in-use uncovered)
               (install-descriptor-placeholders)
             (is = 2 covered)
             (false in-use)
             (is equal (list beyond) uncovered))
           (dolist (fd edge)
             (is equal "/dev/null" (%points-at fd) "fd ~D" fd))
           (false *stale-descriptors*))
      (dolist (fd (append stale edge))
        (ignore-errors (sb-posix:close fd)))
      (setf *stale-descriptors* nil)
      (when old (%rlimit old)))))
