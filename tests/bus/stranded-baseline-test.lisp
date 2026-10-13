;;;; tests/bus/stranded-baseline-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Zebra tests for the watcher's baseline when the agent's cursor is stranded:
;;;; above the head of the log, or recorded against a generation of the log that
;;;; has since been rotated away. Armed from such a cursor the watcher filters
;;;; out every record in the new log, so the agent hears nothing while every
;;;; probe calls it live. These cases pin the heal (rewrite the cursor and say so
;;;; in the fleet log), the clamp when the rewrite is refused, and that a sound
;;;; or missing cursor behaves exactly as before.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/bus/stranded-baseline-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/bus/stranded-baseline-test
  (:use #:cl #:zebra)
  (:local-nicknames (#:wal #:dsmr-mcp/src/bus/wal)
                    (#:envelope #:dsmr-mcp/src/bus/envelope)
                    (#:hostfiles #:dsmr-mcp/src/bus/hostfiles))
  (:import-from #:dsmr-bus-watch/src/bus/watch
                #:%cursor-baseline))

(in-package #:dsmr-mcp/tests/bus/stranded-baseline-test)

(defparameter *self* "/home/x/proj/boomer"
  "The identity every fixture arms a watch for.")

(defun fresh-temp-dir (prefix)
  "A new empty directory under the system temp directory."
  (let ((name (uiop:with-temporary-file (:pathname p :keep t :prefix prefix) p)))
    (ignore-errors (delete-file name))
    (let ((dir (uiop:ensure-directory-pathname name)))
      (ensure-directories-exist dir)
      dir)))

(defun write-text (path text)
  "Replace PATH with TEXT."
  (ensure-directories-exist path)
  (with-open-file (out path :direction :output :if-exists :supersede
                            :if-does-not-exist :create)
    (write-string text out))
  path)

(defmacro with-stranded-bus ((log cursors cursor &key cursor-text) &body body)
  "Run BODY over a bus root whose log holds seqs 1 to 5 from another agent at
   generation 2, with *SELF*'s cursor holding CURSOR-TEXT (no cursor file when
   NIL), and with XDG_STATE_HOME pointing at a fresh directory so the fleet log
   lands there. LOG, CURSORS and CURSOR are bound to the log path, the cursors
   directory and *SELF*'s cursor path. Everything is removed afterwards."
  (let ((root (gensym "ROOT")) (state (gensym "STATE")) (previous (gensym "PREVIOUS")))
    `(let* ((,root (fresh-temp-dir "dsmr-stranded-bus"))
            (,state (fresh-temp-dir "dsmr-stranded-state"))
            (,previous (uiop:getenv "XDG_STATE_HOME"))
            (,log (merge-pathnames "bus.wal" ,root))
            (,cursors (merge-pathnames "cursors/" ,root))
            (,cursor (merge-pathnames (envelope:encode-id *self*) ,cursors)))
       (declare (ignorable ,cursor))
       (unwind-protect
            (progn
              (sb-posix:setenv "XDG_STATE_HOME" (namestring ,state) 1)
              (ensure-directories-exist ,cursors)
              (loop for seq from 1 to 5
                    do (wal:append-record ,log seq "from another agent"))
              (write-text (wal:generation-path ,log) "2")
              (let ((text ,cursor-text))
                (when text (write-text ,cursor text)))
              ,@body)
         (ignore-errors (sb-posix:chmod (uiop:native-namestring ,cursors) #o700))
         (if ,previous
             (sb-posix:setenv "XDG_STATE_HOME" ,previous 1)
             (ignore-errors (sb-posix:unsetenv "XDG_STATE_HOME")))
         (ignore-errors (uiop:delete-directory-tree ,root :validate t
                                                          :if-does-not-exist :ignore))
         (ignore-errors (uiop:delete-directory-tree ,state :validate t
                                                           :if-does-not-exist :ignore))))))

(defun fleet-lines ()
  "The lines of the fleet log under the current state home, or NIL."
  (let ((path (hostfiles:fleet-log-path)))
    (and (probe-file path) (uiop:read-file-lines path))))

(defun baseline-and-stderr (log cursors)
  "The baseline %CURSOR-BASELINE answers for *SELF*, and what it wrote to
   *ERROR-OUTPUT*, as two values."
  (let* ((baseline nil)
         (text (with-output-to-string (*error-output*)
                 (setf baseline (%cursor-baseline *self* log cursors)))))
    (values baseline text)))

(define-test a-cursor-from-a-rotated-log-is-rebased-and-reported
  "The post-reboot shape: the cursor names a position in the log that was
   rotated away. The watch arms at 0 so the new log's mail wakes the agent, the
   cursor is rewritten against the current log, and the old position reaches
   the fleet log before it is lost."
  (with-stranded-bus (log cursors cursor :cursor-text "372 1")
    (multiple-value-bind (baseline stderr) (baseline-and-stderr log cursors)
      (is eql 0 baseline "the watch arms where the new log starts")
      (true (search "stranded" stderr) "the heal is announced on stderr"))
    (is string= "0 2" (uiop:read-file-string cursor))
    (let ((lines (fleet-lines)))
      (is = 1 (length lines))
      (let ((line (first lines)))
        (true (search " FLEET WARN code=stranded-cursor " line) "~S" line)
        (true (search "old-cursor=372" line))
        (true (search "old-generation=1" line))
        (true (search "generation=2" line))
        (true (search "head=5" line))
        (true (search "unread-in-archive=" line))))))

(define-test a-refused-rebase-clamps-to-the-head-and-says-so
  "With the cursors directory read-only the rewrite cannot happen. The watch
   then arms at the log head, never at the stranded value, the cursor file is
   left exactly as it was, and the failure is an error in the fleet log."
  (with-stranded-bus (log cursors cursor :cursor-text "372 1")
    (sb-posix:chmod (uiop:native-namestring cursors) #o500)
    (is eql 5 (baseline-and-stderr log cursors))
    (sb-posix:chmod (uiop:native-namestring cursors) #o700)
    (is string= "372 1" (uiop:read-file-string cursor))
    (let ((lines (fleet-lines)))
      (is = 1 (length lines))
      (true (search " FLEET ERROR code=stranded-cursor-clamped " (first lines))
            "~S" (first lines))
      (true (search "old-cursor=372" (first lines))))))

(define-test a-sound-cursor-arms-where-it-stands-and-logs-nothing
  "The control on both cases above: a cursor in step with its log is the
   baseline, untouched, and the fleet log stays empty."
  (with-stranded-bus (log cursors cursor :cursor-text "3 2")
    (is eql 3 (baseline-and-stderr log cursors))
    (is string= "3 2" (uiop:read-file-string cursor))
    (is equal '() (fleet-lines))))

(define-test a-missing-cursor-still-arms-at-the-head
  "No cursor is not a stranded cursor. The answer stays NIL with the warning
   it always gave, so the caller arms at the head, and nothing is written."
  (with-stranded-bus (log cursors cursor)
    (multiple-value-bind (baseline stderr) (baseline-and-stderr log cursors)
      (is eq nil baseline)
      (true (search "no readable cursor" stderr)))
    (false (probe-file cursor))
    (is equal '() (fleet-lines))))
