;;;; tests/support/socket-scratch-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Contract for the socket scratch fixture: where a scratch directory is made,
;;;; its mode, the refusal when no parent leaves room, and the inclusive bound.
;;;; Nothing here creates anything in the home cache directory.

;; Package evolution guard: drop a prior incarnation so a reload picks up the
;; current import set.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/support/socket-scratch-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/support/socket-scratch-test
  (:use #:cl #:zebra)
  (:import-from #:dsmr-mcp/tests/support/socket-scratch
                #:*fallback-cache-directory*
                #:socket-path-fits-p
                #:socket-scratch-parents
                #:make-socket-scratch-directory
                #:with-overlong-cache-home)
  (:import-from #:dsmr-mcp/src/bus/selector
                #:+max-socket-path-length+))

(in-package #:dsmr-mcp/tests/support/socket-scratch-test)

(defun %private-temp-directory ()
  "A fresh mode-0700 directory under /tmp. The caller removes it."
  (make-socket-scratch-directory "dsmr-ss-t-" :parents (list #p"/tmp/")))

(defun %remove (dir)
  "Remove DIR by its exact path, ignoring a missing tree."
  (when dir
    (ignore-errors (uiop:delete-directory-tree
                    dir :validate t :if-does-not-exist :ignore))))

(defun %mode (dir)
  "The permission bits of DIR."
  (logand (sb-posix:stat-mode (sb-posix:stat (uiop:native-namestring dir)))
          #o777))

(define-test the-cache-directory-is-used-while-a-socket-fits-under-it
  "A cache directory with room receives each scratch directory directly, fresh
   and mode 0700."
  (let ((short (%private-temp-directory))
        (fallback (%private-temp-directory))
        (saved (uiop:getenv "XDG_CACHE_HOME"))
        (made '()))
    (unwind-protect
         (let ((*fallback-cache-directory* fallback))
           (setf (uiop:getenv "XDG_CACHE_HOME") (namestring short))
           (dotimes (i 2)
             (push (make-socket-scratch-directory
                    "dsmr-ss-" :socket-path "dsmr-mcp/bus/submit.ipc")
                   made))
           (dolist (dir made)
             (is string= (namestring short)
                 (namestring (uiop:pathname-parent-directory-pathname dir))
                 "~A is directly under the cache directory" dir)
             (is = #o700 (%mode dir) "~A has mode 0700" dir))
           (false (equal (namestring (first made)) (namestring (second made)))
                  "two calls make two distinct directories"))
      (if saved
          (setf (uiop:getenv "XDG_CACHE_HOME") saved)
          (sb-posix:unsetenv "XDG_CACHE_HOME"))
      (mapc #'%remove made)
      (%remove short)
      (%remove fallback))))

(define-test an-overlong-cache-directory-falls-back-to-the-fallback-cache-directory
  "A cache directory too long for the socket yields a scratch directory under the
   fallback cache directory, and nothing under the overlong one."
  (with-overlong-cache-home (overlong fallback)
    (let ((dir (make-socket-scratch-directory
                "dsmr-ss-" :socket-path "dsmr-mcp/bus/submit.ipc")))
      (unwind-protect
           (progn
             (is string= (namestring fallback)
                 (namestring (uiop:pathname-parent-directory-pathname dir))
                 "~A is directly under the fallback cache directory" dir)
             (true (socket-path-fits-p dir "dsmr-mcp/bus/submit.ipc")
                   "the bus socket under ~A fits within the limit" dir)
             (is equal '() (uiop:subdirectories overlong)
                 "no directory is made under the overlong cache directory")
             (is equal '() (uiop:directory-files overlong)
                 "no file is made under the overlong cache directory"))
        (%remove dir)))))

(define-test the-fallback-defaults-to-the-home-cache-directory
  "Unbound, the fallback parent is the home cache directory, listed after the
   XDG cache directory."
  (let ((home-cache (merge-pathnames ".cache/" (user-homedir-pathname))))
    (is string= (namestring home-cache) (namestring *fallback-cache-directory*)
        "the default fallback is the home cache directory")
    (is string= (namestring home-cache)
        (namestring (car (last (socket-scratch-parents))))
        "the home cache directory is the last candidate")))

(define-test with-no-parent-that-fits-the-fixture-refuses-and-creates-nothing
  "When no candidate parent leaves room, the fixture signals an error naming the
   limit and every candidate, and creates nothing."
  (with-overlong-cache-home (overlong fallback)
    (let* ((deeper (merge-pathnames "deeper/" overlong))
           (condition (handler-case
                          (progn (make-socket-scratch-directory
                                  "x" :parents (list overlong deeper))
                                 nil)
                        (error (e) e)))
           (text (and condition (princ-to-string condition))))
      (true condition "an error is signalled")
      (true (search (princ-to-string +max-socket-path-length+) text)
            "the report names the limit")
      (true (search (namestring overlong) text)
            "the report names the first candidate")
      (true (search (namestring deeper) text)
            "the report names the second candidate")
      (false (probe-file deeper) "the second candidate is not created")
      (is equal '() (uiop:subdirectories overlong)
          "nothing is made under the first candidate")
      (is equal '() (uiop:subdirectories fallback)
          "nothing is made under the fallback cache directory")
      (fail (make-socket-scratch-directory "x" :parents (list overlong))
            error))))

(define-test the-socket-path-bound-is-inclusive
  "A socket path of exactly the limit fits and one character more does not."
  (flet ((dir (n)
           (pathname (format nil "/~A/" (make-string n :initial-element #\a)))))
    (let* ((n (- +max-socket-path-length+ 12))
           (at (dir n))
           (over (dir (1+ n))))
      (is = 107 (length (namestring (merge-pathnames "submit.ipc" at)))
          "the fixture path at the limit is 107 characters")
      (is = 108 (length (namestring (merge-pathnames "submit.ipc" over)))
          "the fixture path past the limit is 108 characters")
      (true (socket-path-fits-p at "submit.ipc") "107 characters fit")
      (false (socket-path-fits-p over "submit.ipc") "108 characters do not"))))
