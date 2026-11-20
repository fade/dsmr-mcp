;;;; tests/support/socket-scratch.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Scratch directories for tests that bind a bus socket.
;;;;
;;;; A unix-domain socket address holds at most 107 characters of path, so every
;;;; character of a scratch path counts against that limit. The first candidate
;;;; parent that leaves room is used: the XDG cache directory, then the fallback
;;;; cache directory (the home cache directory unless rebound). Both sit on a
;;;; disk filesystem, like the real bus roots. When no candidate leaves room, the
;;;; fixture signals an error instead of skipping.

;; Package evolution guard: drop a prior incarnation so a reload picks up the
;; current export set.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/support/socket-scratch)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/support/socket-scratch
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/bus/selector
                #:+max-socket-path-length+)
  (:export #:*fallback-cache-directory*
           #:socket-path-fits-p
           #:socket-scratch-parents
           #:make-socket-scratch-directory
           #:with-overlong-cache-home))

(in-package #:dsmr-mcp/tests/support/socket-scratch)

(defparameter *fallback-cache-directory*
  (merge-pathnames ".cache/" (user-homedir-pathname))
  "Parent tried after the XDG cache directory when the socket does not fit
   there. Defaults to the home cache directory. Tests that force the fallback
   bind it to a temporary directory of their own.")

(defun %child-directory (parent name)
  "The directory pathname NAME directly under PARENT."
  (merge-pathnames (make-pathname :directory (list :relative name))
                   (uiop:ensure-directory-pathname parent)))

(defun %socket-namestring (directory socket-path)
  "The namestring of SOCKET-PATH merged onto DIRECTORY."
  (namestring (merge-pathnames socket-path
                               (uiop:ensure-directory-pathname directory))))

(defun socket-path-fits-p (directory &optional (socket-path "submit.ipc"))
  "True when SOCKET-PATH under DIRECTORY is at most +MAX-SOCKET-PATH-LENGTH+
   characters, the bound the bus enforces."
  (<= (length (%socket-namestring directory socket-path))
      +max-socket-path-length+))

(defun socket-scratch-parents ()
  "The candidate parents in order: the XDG cache directory, then
   *FALLBACK-CACHE-DIRECTORY*. NILs and a later duplicate namestring are
   dropped."
  (remove-duplicates (remove nil (list (uiop:xdg-cache-home)
                                       *fallback-cache-directory*))
                     :key #'namestring :test #'string= :from-end t))

(defun %random-name (prefix)
  "PREFIX followed by eight upper-case hex digits. A fresh random state per call
   keeps names distinct across new images, whose default state is identical."
  (format nil "~A~8,'0X" prefix (random #xFFFFFFFF (make-random-state t))))

(defun make-socket-scratch-directory
    (prefix &key (socket-path "submit.ipc") (parents (socket-scratch-parents)))
  "Create and return a fresh directory named PREFIX plus eight hex digits, mode
   0700, under the first of PARENTS where SOCKET-PATH beneath it fits within
   +MAX-SOCKET-PATH-LENGTH+ characters. PARENTS defaults to
   SOCKET-SCRATCH-PARENTS. The chosen parent is created when missing; an
   existing name is never reused.

   Signals ERROR, creating nothing, when no parent leaves room. The caller
   removes the directory."
  (let* ((name (%random-name prefix))
         (parent (find-if (lambda (p)
                            (socket-path-fits-p (%child-directory p name)
                                                socket-path))
                          parents)))
    (unless parent
      (error "No scratch parent leaves room for a bus socket within ~D ~
              characters: ~{~A gives ~D~^; ~}. Set XDG_CACHE_HOME to a shorter ~
              directory."
             +max-socket-path-length+
             (loop for p in parents
                   for s = (%socket-namestring (%child-directory p name)
                                               socket-path)
                   collect s collect (length s))))
    (ensure-directories-exist (uiop:ensure-directory-pathname parent))
    (loop
      (let ((dir (%child-directory parent name)))
        (handler-case
            (progn (sb-posix:mkdir (uiop:native-namestring dir) #o700)
                   (return dir))
          (sb-posix:syscall-error (e)
            (unless (= (sb-posix:syscall-errno e) sb-posix:eexist)
              (error e))
            (setf name (%random-name prefix))))))))

(defmacro with-overlong-cache-home ((var &optional (fallback (gensym "FALLBACK")))
                                    &body body)
  "Run BODY with XDG_CACHE_HOME set to VAR, an existing directory whose
   namestring alone exceeds +MAX-SOCKET-PATH-LENGTH+, and with
   *FALLBACK-CACHE-DIRECTORY* bound to FALLBACK, a fresh short directory. Both
   are made under /tmp; nothing is created in the home cache directory.

   Afterwards XDG_CACHE_HOME is restored, or unset when it was unset, and both
   temporary trees are removed by their exact paths."
  (let ((base (gensym "BASE")) (saved (gensym "SAVED")))
    `(let ((,base (make-socket-scratch-directory "dsmr-ov-"
                                                 :parents (list #p"/tmp/")))
           (,fallback nil)
           (,saved (uiop:getenv "XDG_CACHE_HOME")))
       (unwind-protect
            (let ((,var (%child-directory ,base
                                          (make-string 90 :initial-element #\c))))
              (ensure-directories-exist ,var)
              (assert (> (length (namestring ,var)) +max-socket-path-length+))
              (setf ,fallback (make-socket-scratch-directory
                               "dsmr-fb-" :parents (list #p"/tmp/")))
              (let ((*fallback-cache-directory* ,fallback))
                (setf (uiop:getenv "XDG_CACHE_HOME") (namestring ,var))
                ,@body))
         ;; An empty value would reach child processes; unset instead.
         (if ,saved
             (setf (uiop:getenv "XDG_CACHE_HOME") ,saved)
             (sb-posix:unsetenv "XDG_CACHE_HOME"))
         (uiop:delete-directory-tree ,base :validate t :if-does-not-exist :ignore)
         (when ,fallback
           (uiop:delete-directory-tree ,fallback :validate t
                                                 :if-does-not-exist :ignore))))))
