;;;; tests/bus/inert-read-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Zebra tests for reading bus state files inertly. A state file is written by
;;;; one process and read by others, so its content is untrusted: reading it must
;;;; not evaluate a #. form or run a structure constructor named by #S. Each
;;;; reader gets a #. probe, a #S probe and a well-formed control; two positive
;;;; controls show that each probe does run when the reader lets it.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/bus/inert-read-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/bus/inert-read-test
  (:use #:cl #:zebra)
  (:local-nicknames (#:wal #:dsmr-mcp/src/bus/wal)
                    (#:cursor #:dsmr-mcp/src/bus/cursor)
                    (#:inert-read #:dsmr-mcp/src/bus/inert-read)
                    (#:heartbeat #:dsmr-mcp/src/bus/heartbeat)
                    (#:watch #:dsmr-bus-watch/src/bus/watch)))

(in-package #:dsmr-mcp/tests/bus/inert-read-test)

;;; ------------------------------------------------------------------ fixtures

(defun fresh-temp-dir (prefix)
  "A new empty directory under the system temp directory."
  (let ((name (uiop:with-temporary-file (:pathname p :keep t :prefix prefix) p)))
    (ignore-errors (delete-file name))
    (let ((dir (uiop:ensure-directory-pathname name)))
      (ensure-directories-exist dir)
      dir)))

(defmacro with-temp-dir ((var &optional (prefix "dsmr-inert-read")) &body body)
  "Bind VAR to a fresh temporary directory, deleted with its contents after."
  `(let ((,var (fresh-temp-dir ,prefix)))
     (declare (ignorable ,var))
     (unwind-protect (progn ,@body)
       (ignore-errors (uiop:delete-directory-tree
                       ,var :validate t :if-does-not-exist :ignore)))))

(defun plant (path text)
  "Write TEXT verbatim to PATH, replacing any existing file. Returns PATH."
  (ensure-directories-exist path)
  (with-open-file (out path :direction :output
                            :if-exists :supersede
                            :if-does-not-exist :create)
    (write-string text out))
  path)

(defvar *struct-marker* nil
  "Pathname the READ-PROBE slot initform creates, or NIL to create nothing.")

(defun touch-struct-marker ()
  "Create the file named by *STRUCT-MARKER* when it is non-NIL. Returns T."
  (when *struct-marker*
    (close (open *struct-marker* :direction :output
                                 :if-exists :supersede
                                 :if-does-not-exist :create)))
  t)

(defstruct read-probe
  "A structure whose second slot initform creates a marker file, so a #S read
   that constructs it leaves visible evidence."
  (a nil)
  (b (touch-struct-marker)))

(defun eval-probe (marker value)
  "Text of a #. form that creates MARKER and evaluates to the integer VALUE."
  (format nil "#.(cl:progn (cl:close (cl:open ~S :direction :output ~
               :if-exists :supersede :if-does-not-exist :create)) ~D)"
          (namestring marker) value))

(defun struct-probe (&optional (dispatch "S"))
  "Text of a #S form naming READ-PROBE fully qualified and supplying only slot A.
   DISPATCH is the sub-character, \"S\" or \"s\"."
  (let ((*package* (find-package "CL-USER")))
    (format nil "#~A(~S :A 1)" dispatch 'read-probe)))

(defmacro with-probe ((dir marker) &body body)
  "Bind DIR to a fresh temporary directory and MARKER to a marker path inside
   it, with *STRUCT-MARKER* bound to MARKER for the extent of BODY."
  `(with-temp-dir (,dir)
     (let* ((,marker (merge-pathnames "marker" ,dir))
            (*struct-marker* ,marker))
       (declare (ignorable ,marker))
       ,@body)))

(defun probe-subscriber (dir)
  "A subscriber over a log and cursor file inside DIR."
  (cursor:make-subscriber "probe"
                          (merge-pathnames "bus.wal" dir)
                          (merge-pathnames "probe.cursor" dir)))

;;; ---------------------------------------------------------- positive controls

(define-test eval-probe-runs-with-read-time-evaluation-enabled
  "The #. probe creates its marker when read-time evaluation is on."
  (with-probe (dir marker)
    (let ((*read-eval* t)
          (*package* (find-package "CL-USER")))
      (is = 42 (read-from-string (eval-probe marker 42))))
    (true (probe-file marker) "the #. probe ran")))

(define-test struct-probe-runs-under-standard-syntax
  "The #S probe creates its marker when read under standard syntax."
  (with-probe (dir marker)
    (true (read-probe-p (with-standard-io-syntax
                          (read-from-string (struct-probe)))))
    (true (probe-file marker) "the #S probe ran")))

;;; ------------------------------------------------------------------- cursor

(define-test cursor-value-refuses-read-time-evaluation
  "A cursor file holding a #. form signals and runs nothing."
  (with-probe (dir marker)
    (let ((sub (probe-subscriber dir)))
      (plant (cursor:subscriber-cursor-path sub) (eval-probe marker 42))
      (fail (cursor:cursor-value sub) reader-error)
      (false (probe-file marker) "the planted form did not run"))))

(define-test cursor-value-refuses-structure-syntax
  "A cursor file holding #S signals and constructs nothing."
  (with-probe (dir marker)
    (let ((sub (probe-subscriber dir)))
      (plant (cursor:subscriber-cursor-path sub) (struct-probe))
      (fail (cursor:cursor-value sub) reader-error)
      (false (probe-file marker) "the planted structure was not built"))))

(define-test recorded-generation-refuses-read-time-evaluation
  "A cursor file whose generation is a #. form signals and runs nothing."
  (with-probe (dir marker)
    (let ((path (plant (merge-pathnames "probe.cursor" dir)
                       (format nil "7 ~A" (eval-probe marker 3)))))
      (fail (cursor::%recorded-generation path) reader-error)
      (false (probe-file marker) "the planted form did not run"))))

(define-test recorded-generation-refuses-structure-syntax
  "A cursor file whose generation is #S signals and constructs nothing."
  (with-probe (dir marker)
    (let ((path (plant (merge-pathnames "probe.cursor" dir)
                       (format nil "7 ~A" (struct-probe)))))
      (fail (cursor::%recorded-generation path) reader-error)
      (false (probe-file marker) "the planted structure was not built"))))

(define-test cursor-reads-what-its-writer-wrote
  "A cursor written by the module's own writer reads back its position and the
   log's generation."
  (with-temp-dir (dir)
    (let ((sub (probe-subscriber dir)))
      (setf (cursor:cursor-value sub) 42)
      (is = 42 (cursor:cursor-value sub))
      (is = (wal:generation (cursor:subscriber-wal sub))
          (cursor::%recorded-generation (cursor:subscriber-cursor-path sub))))))

(defun read-text (text &optional eof-value)
  "READ-DATUM over a string stream holding TEXT."
  (with-input-from-string (in text)
    (inert-read:read-datum in eof-value)))

(define-test read-datum-reads-integers
  "Integers read as CL:READ reads them, one datum per call."
  (is = 42 (read-text "42"))
  (with-input-from-string (in "42 3")
    (is = 42 (inert-read:read-datum in))
    (is = 3 (inert-read:read-datum in))))

(define-test read-datum-reads-keyword-plists
  "A keyword plist of strings, integers, NIL and T reads EQUAL to CL:READ."
  (let ((text "(:id \"sister-1\" :pid 4242 :parked nil :live t)"))
    (is equal (with-standard-io-syntax (read-from-string text))
        (read-text text))))

(define-test read-datum-returns-the-eof-value
  "An empty stream returns NIL, or the EOF value passed."
  (is eq nil (read-text ""))
  (is eq :eof (read-text "   " :eof)))

(define-test read-datum-ignores-the-callers-reader-variables
  "Reads are the same whatever *READ-BASE*, *READ-EVAL*, *READ-SUPPRESS* and
   *READTABLE* the caller binds."
  (let ((*read-base* 16))
    (is = 10 (read-text "10") "*read-base* 16"))
  (let ((*read-suppress* t))
    (is = 42 (read-text "42") "*read-suppress* t"))
  (with-probe (dir marker)
    (let ((*read-eval* t))
      (fail (read-text (eval-probe marker 1)) reader-error))
    (false (probe-file marker) "the #. form did not run under *read-eval* t"))
  (with-probe (dir marker)
    (let ((*readtable* (copy-readtable nil)))
      (fail (read-text (struct-probe)) reader-error))
    (false (probe-file marker) "the #S form was not built under a standard readtable")))

(define-test read-datum-refuses-structure-and-circular-syntax
  "#S and #s signal REFUSED-SYNTAX and construct nothing; #= and ## signal
   READER-ERROR, also inside a skipped #- branch."
  (with-probe (dir marker)
    (fail (read-text (struct-probe "S")) inert-read:refused-syntax)
    (fail (read-text (struct-probe "s")) inert-read:refused-syntax)
    (false (probe-file marker) "the #S form was not built"))
  (fail (read-text "#1=(:a . #1#)") reader-error)
  (fail (read-text "(#1#)") reader-error)
  (fail (read-text "#-(and) #S(foo :a 1) 1") reader-error))

(define-test read-datum-signals-end-of-file-on-a-truncated-form
  "A form cut off by end of file signals END-OF-FILE, as CL:READ does."
  (fail (read-text "(:pid 1") end-of-file))

(define-test generation-refuses-read-time-evaluation
  "A log generation file holding a #. form signals and runs nothing."
  (with-probe (dir marker)
    (let ((wal-path (merge-pathnames "bus.wal" dir)))
      (plant (wal:generation-path wal-path) (eval-probe marker 5))
      (fail (wal:generation wal-path) reader-error)
      (false (probe-file marker) "the planted form did not run"))))

(define-test generation-refuses-structure-syntax
  "A log generation file holding #S signals and constructs nothing."
  (with-probe (dir marker)
    (let ((wal-path (merge-pathnames "bus.wal" dir)))
      (plant (wal:generation-path wal-path) (struct-probe))
      (fail (wal:generation wal-path) reader-error)
      (false (probe-file marker) "the planted structure was not built"))))

(define-test generation-reads-what-its-writer-wrote
  "A generation written by the module's own writer reads back."
  (with-temp-dir (dir)
    (let ((wal-path (merge-pathnames "bus.wal" dir)))
      (wal::%write-generation wal-path 5)
      (is = 5 (wal:generation wal-path)))))

(define-test beat-liveness-ignores-read-time-evaluation
  "A heartbeat whose pid is a #. form reads live by age, with no pid, and runs
   nothing."
  (with-probe (dir marker)
    (let ((path (plant (merge-pathnames "probe.beat" dir)
                       (format nil "(:pid ~A)" (eval-probe marker 4242)))))
      (multiple-value-bind (status age pid) (heartbeat:beat-liveness path 60)
        (declare (ignore age))
        (is eq :live status)
        (false pid "no pid is read from the planted beat"))
      (false (probe-file marker) "the planted form did not run"))))

(define-test beat-liveness-ignores-structure-syntax
  "A heartbeat whose pid is #S reads live by age, with no pid, and constructs
   nothing."
  (with-probe (dir marker)
    (let ((path (plant (merge-pathnames "probe.beat" dir)
                       (format nil "(:pid ~A)" (struct-probe)))))
      (multiple-value-bind (status age pid) (heartbeat:beat-liveness path 60)
        (declare (ignore age))
        (is eq :live status)
        (false pid "no pid is read from the planted beat"))
      (false (probe-file marker) "the planted structure was not built"))))

(define-test beat-liveness-reads-what-its-writer-wrote
  "A heartbeat written by the module's own writer reads live with this
   process's pid."
  (with-temp-dir (dir)
    (let ((path (merge-pathnames "probe.beat" dir)))
      (heartbeat:write-beat path :mode :foreign :baseline 0 :poll-ms 250)
      (multiple-value-bind (status age pid) (heartbeat:beat-liveness path 60)
        (declare (ignore age))
        (is eq :live status)
        (is eql (sb-posix:getpid) pid)))))

(define-test watcher-cursor-check-refuses-read-time-evaluation
  "The watcher's cursor check answers NIL for a #. form and runs nothing."
  (with-probe (dir marker)
    (let ((path (plant (merge-pathnames "probe.cursor" dir)
                       (eval-probe marker 7))))
      (false (watch::%cursor-holds-seq-p path))
      (false (probe-file marker) "the planted form did not run"))))

(define-test watcher-cursor-check-refuses-structure-syntax
  "The watcher's cursor check answers NIL for #S and constructs nothing."
  (with-probe (dir marker)
    (let ((path (plant (merge-pathnames "probe.cursor" dir) (struct-probe))))
      (false (watch::%cursor-holds-seq-p path))
      (false (probe-file marker) "the planted structure was not built"))))

(define-test watcher-cursor-check-accepts-a-written-cursor
  "The watcher's cursor check answers T for a cursor the cursor writer wrote."
  (with-temp-dir (dir)
    (let ((sub (probe-subscriber dir)))
      (setf (cursor:cursor-value sub) 3)
      (true (watch::%cursor-holds-seq-p (cursor:subscriber-cursor-path sub))))))
