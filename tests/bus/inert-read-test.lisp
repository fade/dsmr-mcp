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
                    (#:watch #:dsmr-bus-watch/src/bus/watch)
                    (#:hostfiles #:dsmr-mcp/src/bus/hostfiles)
                    (#:roster #:dsmr-mcp/src/bus/roster)
                    (#:envelope #:dsmr-mcp/src/bus/envelope)
                    (#:broker #:dsmr-mcp/src/bus/broker)
                    (#:status #:dsmr-mcp/src/bus/status)
                    (#:archive #:dsmr-mcp/src/bus/archive)))

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
  "Pathname the INERT-READ-PROBE slot initform creates, or NIL to create nothing.")

(defun touch-struct-marker ()
  "Create the file named by *STRUCT-MARKER* when it is non-NIL. Returns T."
  (when *struct-marker*
    (close (open *struct-marker* :direction :output
                                 :if-exists :supersede
                                 :if-does-not-exist :create)))
  t)

(defstruct (cl-user::inert-read-probe (:predicate read-probe-p))
  "A structure whose second slot initform creates a marker file, so a #S read
   that constructs it leaves visible evidence. Named in CL-USER, the package
   the inert reader reads in, so the probe text needs no package prefix."
  (a nil)
  (b (touch-struct-marker)))

(defun eval-probe (marker value)
  "Text of a #. form that creates MARKER and evaluates to the integer VALUE."
  (format nil "#.(cl:progn (cl:close (cl:open ~S :direction :output ~
               :if-exists :supersede :if-does-not-exist :create)) ~D)"
          (namestring marker) value))

(defun struct-probe (&optional (dispatch "S"))
  "Text of a #S form naming INERT-READ-PROBE, unqualified, and supplying only slot A.
   DISPATCH is the sub-character, \"S\" or \"s\"."
  (let ((*package* (find-package "CL-USER")))
    (format nil "#~A(~S :A 1)" dispatch 'cl-user::inert-read-probe)))

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
  "A cursor file whose generation is a #. form names no generation and runs
   nothing."
  (with-probe (dir marker)
    (let ((path (plant (merge-pathnames "probe.cursor" dir)
                       (format nil "7 ~A" (eval-probe marker 3)))))
      (is eq :returned (refusal-of (lambda () (cursor::%recorded-generation path))))
      (false (cursor::%recorded-generation path))
      (false (probe-file marker) "the planted form did not run"))))

(define-test recorded-generation-refuses-structure-syntax
  "A cursor file whose generation is #S names no generation and constructs
   nothing."
  (with-probe (dir marker)
    (let ((path (plant (merge-pathnames "probe.cursor" dir)
                       (format nil "7 ~A" (struct-probe)))))
      (is eq :returned (refusal-of (lambda () (cursor::%recorded-generation path))))
      (false (cursor::%recorded-generation path))
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

(defun refusal-of (thunk)
  "What calling THUNK signals:
   - the upcased character of a REFUSED-SYNTAX, or :REFUSED when it names none;
   - the type of any other ERROR;
   - :ESCAPED for a STORAGE-CONDITION, which no ERROR handler catches;
   - :RETURNED when THUNK returns."
  (handler-case (progn (funcall thunk) :returned)
    (inert-read:refused-syntax (c)
      (or (inert-read:refused-syntax-character c) :refused))
    (error (c) (type-of c))
    (storage-condition () :escaped)))

(defmacro refusal (form)
  "REFUSAL-OF a thunk evaluating FORM."
  `(refusal-of (lambda () ,form)))

(defmacro contained (form)
  "The value of FORM, or :ESCAPED when FORM signals a STORAGE-CONDITION."
  `(handler-case ,form
     (storage-condition () :escaped)))

(defun plant-fifo (path)
  "Create a FIFO at PATH. Returns PATH."
  (ensure-directories-exist path)
  (sb-posix:mkfifo (namestring path) #o600)
  path)

(defun call-with-deadline (fifo thunk &optional (seconds 5))
  "Call THUNK in a thread and return its value, or :HUNG when it is still
   running after SECONDS. A serious condition from THUNK returns as
   (:SIGNALLED type). On :HUNG, open FIFO for writing and close it, so a reader
   blocked opening FIFO returns and its thread ends."
  (let* ((thread (sb-thread:make-thread
                  (lambda ()
                    (handler-case (funcall thunk)
                      (serious-condition (c) (list :signalled (type-of c)))))
                  :name "inert-read deadline probe"))
         (value (sb-thread:join-thread thread :timeout seconds :default :hung)))
    (when (eq value :hung)
      (ignore-errors
       (sb-posix:close (sb-posix:open (namestring fifo)
                                      (logior sb-posix:o-wronly sb-posix:o-nonblock))))
      (sb-thread:join-thread thread :timeout seconds :default nil))
    value))

(defmacro with-deadline ((fifo &optional (seconds 5)) &body body)
  "CALL-WITH-DEADLINE over a thunk running BODY."
  `(call-with-deadline ,fifo (lambda () ,@body) ,seconds))

(defvar *expander-ran* nil
  "The arguments the INERT-READ-PROBE-TYPE expander last ran with, or NIL.")

(deftype cl-user::inert-read-probe-type (&rest args)
  "Element type whose expander records ARGS in *EXPANDER-RAN*."
  (setf *expander-ran* (or args t))
  'bit)

(define-test read-datum-reads-integers
  "Integers read as CL:READ reads them."
  (is = 42 (read-text "42"))
  (is = -7 (read-text " -7 3")))

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
  "#S, #s, #= and ## each signal REFUSED-SYNTAX naming the sub-character, and
   #S builds nothing. #S and #= are refused inside a skipped #- branch too."
  (with-probe (dir marker)
    (is eql #\S (refusal (read-text (struct-probe "S"))))
    (is eql #\S (refusal (read-text (struct-probe "s"))))
    (false (probe-file marker) "the #S form was not built"))
  (is eql #\= (refusal (read-text "#1=(:a . #1#)")))
  (is eql #\# (refusal (read-text "(1 #1#)")))
  (is eql #\S (refusal (read-text "#-(and) #S(foo :a 1) 1")))
  (is eql #\= (refusal (read-text "#-(and) #1=(1) 1"))))

(define-test read-datum-refuses-counted-vector-syntax
  "#n( and #n* signal REFUSED-SYNTAX before allocating, the 14-byte
   #40000000000*1 included. #( and #* with no count still read."
  (is = 14 (length "#40000000000*1"))
  (is eql #\* (refusal (read-text "#40000000000*1")))
  (is eql #\( (refusal (read-text "#4000000000(1)")))
  (is eql #\( (refusal (read-text "#3(1)")))
  (is eql #\* (refusal (read-text "#3*1")))
  (is equalp #(1 2) (read-text "#(1 2)"))
  (is equal #*101 (read-text "#*101")))

(define-test read-datum-refuses-array-syntax
  "#A and #nA signal REFUSED-SYNTAX, and no type expander named in the text
   runs."
  (setf *expander-ran* nil)
  (is eql #\A (refusal (read-text "#A((2) (inert-read-probe-type :planted) . (1 0))")))
  (false *expander-ran* "the planted type expander did not run")
  (is eql #\A (refusal (read-text "#A((4000000000) t . nil)")))
  (is eql #\A (refusal (read-text "#2A((1 2) (3 4))"))))

(define-test read-datum-turns-other-reader-faults-into-refusals
  "A condition the reader signals that is neither a READER-ERROR nor an
   END-OF-FILE arrives as REFUSED-SYNTAX naming no character: here the
   TYPE-ERROR of a malformed feature expression."
  (is eq :refused (refusal (read-text "#+(:not . 1) 1 2"))))

(define-test read-datum-reads-nil-as-cl-nil-in-any-caller-package
  "NIL and T read as CL:NIL and CL:T while the caller's *PACKAGE* uses no
   package."
  (let ((bare (make-package (symbol-name (gensym "INERT-READ-BARE-")) :use '())))
    (unwind-protect
         (let ((plist (let ((*package* bare)) (read-text "(:a nil :b t)"))))
           (true (eq 'cl:nil (getf plist :a :absent)) "NIL is CL:NIL")
           (true (eq 'cl:t (getf plist :b)) "T is CL:T"))
      (delete-package bare))))

(define-test reloading-the-reader-source-replaces-its-readtable
  "Loading inert-read.lisp again installs a new refusing readtable, and that
   table still refuses #S."
  (let ((before inert-read::*refusing-readtable*))
    (load (asdf:system-relative-pathname "dsmr-mcp" "src/bus/inert-read.lisp"))
    (false (eq before inert-read::*refusing-readtable*)
           "the reload rebuilt the table")
    (is eql #\S (refusal (read-text "#S(foo :a 1)")))))

(define-test read-datum-refuses-deep-nesting
  "Lists nested deeper than 32, and runs of quote or dispatch prefixes, signal
   REFUSED-SYNTAX before the reader recurses into them. 32 levels read."
  (flet ((nested (depth)
           (concatenate 'string (make-string depth :initial-element #\()
                        (make-string depth :initial-element #\)))))
    (true (consp (read-text (nested 32))))
    (is eq :refused (refusal (read-text (nested 33))))
    (is eq :refused (refusal (read-text (make-string 100000 :initial-element #\())))
    (is eq :refused (refusal (read-text (concatenate
                                         'string
                                         (make-string 100 :initial-element #\')
                                         "x"))))
    (is eq :refused (refusal (read-text (apply #'concatenate 'string
                                                (append (make-list 100 :initial-element "#+sbcl ")
                                                        (list "1"))))))))

(define-test read-datum-refuses-input-over-the-byte-limit
  "Text longer than 8192 characters signals REFUSED-SYNTAX; 8192 reads."
  (is eq :refused (refusal (read-text (make-string 8193 :initial-element #\Space))))
  (is = 1 (read-text (concatenate 'string "1" (make-string 8191 :initial-element #\Space))))
  (is eq :refused (refusal (read-text (make-string 100000 :initial-element #\7)))))

(define-test read-datum-refuses-package-qualified-symbols
  "A token with a package marker after its first character signals
   REFUSED-SYNTAX and interns nothing. Keywords, and colons inside strings,
   comments, characters and backslash escapes, still read."
  (let ((name (format nil "ZZ-INERT-READ-PLANTED-~D" (random 1000000000)))
        (target (find-package "DSMR-MCP/SRC/BUS/BROKER")))
    (is eq :refused (refusal (read-text (format nil "dsmr-mcp/src/bus/broker::~A" name))))
    (false (find-symbol name target) "nothing was interned in the named package"))
  (is eq :refused (refusal (read-text "cl::car")))
  (is eq :refused (refusal (read-text "keyword:pid")))
  (is eq :refused (refusal (read-text "::pid")))
  (is eq :refused (refusal (read-text "#+sb-impl::zz-feature 1 2")))
  (is eq :pid (read-text ":pid"))
  (is equal "a::b" (read-text "\"a::b\""))
  (is eql #\: (read-text "#\\:"))
  (is = 7 (read-text (format nil "; a::b~%7")))
  (is equal "A:B" (symbol-name (read-text "a\\:b")))
  (is equal '(:k "x:y" #\: 3) (read-text "(:k \"x:y\" #\\: 3)")))

(define-test read-datum-refuses-syntax-the-scan-does-not-model
  "Backquote, comma, vertical bar, #| comments and #: uninterned symbols signal
   REFUSED-SYNTAX, so the scan and the reader never parse a text differently.
   The two shapes that once hid a package-qualified symbol from the scan intern
   nothing."
  (let ((victim (or (find-package "INERT-READ-VICTIM")
                    (make-package "INERT-READ-VICTIM" :use '()))))
    (is eq :refused (refusal (read-text "(#:#|| inert-read-victim::evil-b |#|)")))
    (is eq :refused (refusal (read-text "`(,@#|\\|#inert-read-victim::evil-c)")))
    (false (find-symbol "EVIL-B" victim) "EVIL-B was not interned")
    (false (find-symbol "EVIL-C" victim) "EVIL-C was not interned"))
  (dolist (text '("`(1)" ",x" "(1 ,@x)" "#| c |# 1" "#:foo" "|a|" "a|b|c" "(:a |x|)"))
    (is eq :refused (refusal (read-text text)) text))
  (is eql #\| (read-text "#\\|"))
  (is equal "a|b`c,d" (read-text "\"a|b`c,d\""))
  (is = 3 (read-text (format nil "; `,|#|~%3"))))

(define-test a-timeout-during-a-read-is-not-turned-into-a-refusal
  "An SB-EXT:TIMEOUT raised while READ-DATUM is reading escapes as itself, never
   as REFUSED-SYNTAX. The input is a slow number of 8190 characters, so each
   timeout lands inside the reader."
  (let ((slow (concatenate 'string "0." (make-string 8187 :initial-element #\0) "1")))
    (dotimes (trial 5)
      (is eq :timeout
          (handler-case (sb-ext:with-timeout 0.01
                          (loop (read-text slow)))
            (sb-ext:timeout () :timeout)
            (inert-read:refused-syntax () :converted))
          (format nil "trial ~D" trial)))))

(define-test read-state-file-reads-up-to-count-data
  "READ-STATE-FILE returns the first COUNT data and T; fewer when the file
   ends first; NIL and NIL for a missing file."
  (with-temp-dir (dir)
    (let ((path (plant (merge-pathnames "state" dir) "5 7 9")))
      (is equal '(5 7) (inert-read:read-state-file path :count 2))
      (is equal '(5) (inert-read:read-state-file path))
      (true (nth-value 1 (inert-read:read-state-file path)))
      (plant path "")
      (is equal '(nil t) (multiple-value-list (inert-read:read-state-file path :count 2)))
      (is equal '(nil nil) (multiple-value-list
                            (inert-read:read-state-file (merge-pathnames "absent" dir))))
      (is equal '(nil nil) (multiple-value-list
                            (inert-read:read-state-file (merge-pathnames "no-dir/absent" dir)))))))

(define-test read-state-file-refuses-what-is-not-a-regular-file
  "A FIFO, a symlink to a character device, and a directory each signal
   REFUSED-SYNTAX without blocking. A symlink to a regular file reads."
  (with-temp-dir (dir)
    (let ((fifo (plant-fifo (merge-pathnames "fifo" dir)))
          (zero (merge-pathnames "zero" dir))
          (target (plant (merge-pathnames "target" dir) "11"))
          (link (merge-pathnames "link" dir)))
      (sb-posix:symlink "/dev/zero" (namestring zero))
      (sb-posix:symlink (namestring target) (namestring link))
      (is eq :refused (with-deadline (fifo 3) (refusal (inert-read:read-state-file fifo))))
      (is eq :refused (with-deadline (fifo 3) (refusal (inert-read:read-state-file zero))))
      (is eq :refused (refusal (inert-read:read-state-file dir)))
      (is equal '(11) (inert-read:read-state-file link)))))

(define-test read-state-file-refuses-oversized-foreign-and-undecodable-files
  "A file over the byte limit, a file not owned by OWNER, and a file that is
   not UTF-8 each signal REFUSED-SYNTAX."
  (with-temp-dir (dir)
    (let ((path (merge-pathnames "state" dir)))
      (plant path (make-string 8193 :initial-element #\Space))
      (is eq :refused (refusal (inert-read:read-state-file path)))
      (plant path (concatenate 'string "1" (make-string 8191 :initial-element #\Space)))
      (is equal '(1) (inert-read:read-state-file path))
      (plant path "12345")
      (is eq :refused (refusal (inert-read:read-state-file path :byte-limit 4)))
      (is eq :refused (refusal (inert-read:read-state-file
                                path :owner (1+ (sb-posix:getuid)))))
      (is equal '(12345) (inert-read:read-state-file path :owner (sb-posix:getuid)))
      (with-open-file (out path :direction :output :if-exists :supersede
                                :element-type '(unsigned-byte 8))
        (write-sequence (coerce #(49 255 50) '(vector (unsigned-byte 8))) out))
      (is eq :refused (refusal (inert-read:read-state-file path))))))

(define-test read-state-file-honours-the-callers-byte-limit
  "A 20 KB file reads under :BYTE-LIMIT 65536 and is refused under the default
   8192. A limit above 1 MiB is capped at 1 MiB."
  (with-temp-dir (dir)
    (let ((path (merge-pathnames "state" dir))
          (big (concatenate 'string "1" (make-string 20000 :initial-element #\Space))))
      (plant path big)
      (is equal '(1) (inert-read:read-state-file path :byte-limit 65536))
      (is eq :refused (refusal (inert-read:read-state-file path)))
      (plant path (concatenate 'string "1" (make-string (* 1536 1024)
                                                        :initial-element #\Space)))
      (is eq :refused (refusal (inert-read:read-state-file
                                path :byte-limit (* 4 1024 1024)))))))

(define-test read-datum-signals-end-of-file-on-a-truncated-form
  "A form cut off by end of file signals END-OF-FILE, as CL:READ does."
  (fail (read-text "(:pid 1") end-of-file))

(define-test generation-refuses-read-time-evaluation
  "A log generation file holding a #. form reads as an unknown generation, NIL,
   and runs nothing."
  (with-probe (dir marker)
    (let ((wal-path (merge-pathnames "bus.wal" dir)))
      (plant (wal:generation-path wal-path) (eval-probe marker 5))
      (is eq :returned (refusal (wal:generation wal-path)))
      (false (wal:generation wal-path))
      (false (probe-file marker) "the planted form did not run"))))

(define-test generation-refuses-structure-syntax
  "A log generation file holding #S reads as an unknown generation, NIL, and
   constructs nothing."
  (with-probe (dir marker)
    (let ((wal-path (merge-pathnames "bus.wal" dir)))
      (plant (wal:generation-path wal-path) (struct-probe))
      (is eq :returned (refusal (wal:generation wal-path)))
      (false (wal:generation wal-path))
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

(define-test read-plist-file-refuses-read-time-evaluation
  "A host record holding a #. form reads as unreadable and runs nothing."
  (with-probe (dir marker)
    (let ((path (plant (merge-pathnames "r.plist" dir)
                       (format nil "(:a ~A)" (eval-probe marker 1)))))
      (is eq :unreadable (nth-value 1 (hostfiles:read-plist-file path)))
      (false (probe-file marker) "the planted form did not run"))))

(define-test read-plist-file-refuses-structure-syntax
  "A host record holding #S reads as unreadable and constructs nothing."
  (with-probe (dir marker)
    (let ((path (plant (merge-pathnames "r.plist" dir)
                       (format nil "(:a ~A)" (struct-probe)))))
      (is eq :unreadable (nth-value 1 (hostfiles:read-plist-file path)))
      (false (probe-file marker) "the planted structure was not built"))))

(define-test read-plist-file-reads-what-its-writer-wrote
  "A host record written by the module's own writer reads back as :OK."
  (with-temp-dir (dir)
    (let ((path (merge-pathnames "r.plist" dir))
          (plist (list :name "host" :pid 4242 :parked nil :live t)))
      (hostfiles:write-plist-file path plist)
      (multiple-value-bind (read status) (hostfiles:read-plist-file path)
        (is eq :ok status)
        (is equal plist read)))))

(define-test a-service-status-over-8-kb-reads-through-the-host-status-reader
  "A service status plist of more than 8192 bytes, 80 registrations, written by
   WRITE-PLIST-FILE, reads back as :OK through READ-PLIST-FILE with the 1 MiB
   limit --host-status passes."
  (with-temp-dir (dir)
    (let* ((path (merge-pathnames "service.status" dir))
           (registrations
             (loop for i from 1 to 80
                   collect (list :id (format nil "/home/operator/SourceCode/project-~2,'0D/agent" i)
                                 :bus "default" :pid (+ 40000 i) :state :armed
                                 :since 1795507912)))
           (plist (list :written-at 1795507912 :pid 4242
                        :buses (list (list :bus "default" :owner :service))
                        :registrations registrations)))
      (hostfiles:write-plist-file path plist)
      (true (> (with-open-file (in path :element-type '(unsigned-byte 8))
                 (file-length in))
               8192)
            "the record is larger than 8192 bytes")
      (multiple-value-bind (read status)
          (hostfiles:read-plist-file path :max-bytes (* 1024 1024))
        (is eq :ok status)
        (is equal plist read)))))

(define-test host-cursor-check-refuses-read-time-evaluation
  "The host service's cursor check answers NIL for a #. form and runs nothing."
  (with-probe (dir marker)
    (let ((path (plant (merge-pathnames "probe.cursor" dir)
                       (eval-probe marker 7))))
      (false (hostfiles::%cursor-holds-seq-p path))
      (false (probe-file marker) "the planted form did not run"))))

(define-test host-cursor-check-refuses-structure-syntax
  "The host service's cursor check answers NIL for #S and constructs nothing."
  (with-probe (dir marker)
    (let ((path (plant (merge-pathnames "probe.cursor" dir) (struct-probe))))
      (false (hostfiles::%cursor-holds-seq-p path))
      (false (probe-file marker) "the planted structure was not built"))))

(define-test host-cursor-check-accepts-a-written-cursor
  "The host service's cursor check answers T for a cursor the cursor writer wrote."
  (with-temp-dir (dir)
    (let ((sub (probe-subscriber dir)))
      (setf (cursor:cursor-value sub) 3)
      (true (hostfiles::%cursor-holds-seq-p (cursor:subscriber-cursor-path sub))))))

(defun probe-roster (dir)
  "The roster directory and bus state path of a bus rooted at DIR."
  (let ((paths (broker:make-bus-paths dir)))
    (values (broker:bus-paths-roster-dir paths)
            (broker:bus-paths-roster-state paths))))

(defun probe-agent-id ()
  "A bus id for a probe agent."
  (envelope:agent-id "/tmp/inert-read-probe-project" :name "probe"))

(define-test roster-entry-refuses-read-time-evaluation
  "A roster entry holding a #. form reads as present but unreadable and runs
   nothing."
  (with-probe (dir marker)
    (let ((roster-dir (probe-roster dir))
          (id (probe-agent-id)))
      (plant (roster:roster-entry-path id roster-dir)
             (format nil "(:id ~A)" (eval-probe marker 1)))
      (multiple-value-bind (entry present-p) (roster:entry id roster-dir)
        (false entry)
        (true present-p))
      (false (probe-file marker) "the planted form did not run"))))

(define-test roster-entry-refuses-structure-syntax
  "A roster entry holding #S reads as present but unreadable and constructs
   nothing."
  (with-probe (dir marker)
    (let ((roster-dir (probe-roster dir))
          (id (probe-agent-id)))
      (plant (roster:roster-entry-path id roster-dir)
             (format nil "(:id ~A)" (struct-probe)))
      (multiple-value-bind (entry present-p) (roster:entry id roster-dir)
        (false entry)
        (true present-p))
      (false (probe-file marker) "the planted structure was not built"))))

(define-test roster-entry-reads-what-enroll-wrote
  "An entry written by ENROLL reads back as a plist, present."
  (with-temp-dir (dir)
    (multiple-value-bind (roster-dir state-path) (probe-roster dir)
      (let ((id (probe-agent-id)))
        (roster:enroll id roster-dir state-path)
        (multiple-value-bind (entry present-p) (roster:entry id roster-dir)
          (true (consp entry))
          (true present-p))))))

(define-test broker-identity-refuses-read-time-evaluation
  "A broker identity record holding a #. form reads as NIL and runs nothing."
  (with-probe (dir marker)
    (let ((paths (broker:make-bus-paths dir)))
      (plant (broker:broker-identity-path paths)
             (format nil "(:pid ~A)" (eval-probe marker 1)))
      (false (broker:read-broker-identity paths))
      (false (probe-file marker) "the planted form did not run"))))

(define-test broker-identity-refuses-structure-syntax
  "A broker identity record holding #S reads as NIL and constructs nothing."
  (with-probe (dir marker)
    (let ((paths (broker:make-bus-paths dir)))
      (plant (broker:broker-identity-path paths)
             (format nil "(:pid ~A)" (struct-probe)))
      (false (broker:read-broker-identity paths))
      (false (probe-file marker) "the planted structure was not built"))))

(define-test broker-identity-reads-what-its-writer-wrote
  "An identity written by the module's own writer reads back with this
   process's pid."
  (with-temp-dir (dir)
    (let ((paths (broker:make-bus-paths dir)))
      (true (broker:write-broker-identity paths) "the record was written")
      (is eql (sb-posix:getpid)
          (getf (broker:read-broker-identity paths) :pid)))))

(define-test every-reader-contains-the-counted-bit-vector-probe
  "Each bus state reader given the 14-byte #40000000000*1 ends in its usual
   unreadable answer or an ERROR, never a STORAGE-CONDITION."
  (with-temp-dir (dir)
    (let* ((probe "#40000000000*1")
           (sub (probe-subscriber dir))
           (cursor-path (plant (cursor:subscriber-cursor-path sub) probe))
           (wal-path (cursor:subscriber-wal sub))
           (beat (plant (merge-pathnames "probe.beat" dir) probe))
           (record (plant (merge-pathnames "r.plist" dir) probe))
           (paths (broker:make-bus-paths dir))
           (id (probe-agent-id))
           (roster-dir (probe-roster dir)))
      (plant (wal:generation-path wal-path) probe)
      (plant (broker:broker-identity-path paths) probe)
      (plant (roster:roster-entry-path id roster-dir) probe)
      (is eql #\* (refusal (cursor:cursor-value sub)) "cursor value")
      (isnt eq :escaped (refusal (cursor::%recorded-generation
                                  (plant (merge-pathnames "second.cursor" dir)
                                         (format nil "5 ~A" probe))))
            "recorded generation")
      (isnt eq :escaped (refusal (wal:generation wal-path)) "log generation")
      (is eq :live (contained (heartbeat:beat-liveness beat 60)) "beat")
      (false (contained (watch::%cursor-holds-seq-p cursor-path)) "watcher check")
      (false (contained (hostfiles::%cursor-holds-seq-p cursor-path)) "host check")
      (is eq :unreadable (contained (nth-value 1 (hostfiles:read-plist-file record)))
          "host record")
      (is eq t (contained (nth-value 1 (roster:entry id roster-dir))) "roster entry")
      (false (contained (broker:read-broker-identity paths)) "broker identity"))))

(define-test every-reader-returns-promptly-from-a-fifo
  "Each bus state reader given a FIFO in place of its file returns its usual
   unreadable answer, or signals an ERROR, within three seconds."
  (with-temp-dir (dir)
    (let* ((sub (probe-subscriber dir))
           (cursor-path (plant-fifo (cursor:subscriber-cursor-path sub)))
           (wal-path (cursor:subscriber-wal sub))
           (generation (plant-fifo (wal:generation-path wal-path)))
           (beat (plant-fifo (merge-pathnames "probe.beat" dir)))
           (record (plant-fifo (merge-pathnames "r.plist" dir)))
           (paths (broker:make-bus-paths dir))
           (identity (plant-fifo (broker:broker-identity-path paths)))
           (id (probe-agent-id))
           (roster-dir (probe-roster dir))
           (entry (plant-fifo (roster:roster-entry-path id roster-dir))))
      (is eq :refused (with-deadline (cursor-path 3) (refusal (cursor:cursor-value sub)))
          "cursor value")
      (isnt eq :hung (with-deadline (cursor-path 3)
                       (refusal (cursor::%recorded-generation cursor-path)))
            "recorded generation")
      (isnt eq :hung (with-deadline (generation 3) (refusal (wal:generation wal-path)))
            "log generation")
      (is eq :live (with-deadline (beat 3) (heartbeat:beat-liveness beat 60)) "beat")
      (false (with-deadline (cursor-path 3) (watch::%cursor-holds-seq-p cursor-path))
             "watcher check")
      (false (with-deadline (cursor-path 3) (hostfiles::%cursor-holds-seq-p cursor-path))
             "host check")
      (is eq :unreadable (with-deadline (record 3)
                           (nth-value 1 (hostfiles:read-plist-file record)))
          "host record")
      (is eq t (with-deadline (entry 3) (nth-value 1 (roster:entry id roster-dir)))
          "roster entry")
      (false (with-deadline (identity 3) (broker:read-broker-identity paths))
             "broker identity"))))

(define-test a-bad-second-value-in-a-cursor-names-no-generation
  "A cursor file holding a sound position followed by a malformed or refused
   value names no generation. The strand check, the host service's heal and the
   status inventory each answer without signalling."
  (dolist (text '("5 )" "5 #1=(1)" "5 #S(foo)" "5 #40000000000*1"))
    (with-temp-dir (dir)
      (let* ((paths (broker:make-bus-paths dir))
             (wal-path (plant (broker:bus-paths-wal paths) ""))
             (cursor-path (plant (merge-pathnames "probe"
                                                  (broker:bus-paths-cursors-dir paths))
                                 text))
             (sub (cursor:make-subscriber "probe" wal-path cursor-path)))
        (is eq :returned (refusal (cursor::%recorded-generation cursor-path)) text)
        (false (cursor::%recorded-generation cursor-path) text)
        (is eq :returned (refusal (cursor:stranded-reason sub :head 10 :log-generation 0))
            text)
        (is eq :returned (refusal (hostfiles:heal-stranded-baseline
                                   "probe" wal-path cursor-path :rebase-p nil))
            text)
        (is eql 1 (getf (getf (contained (ignore-errors (status:cursor-inventory paths)))
                              :count)
                        :value)
            text)))))

(define-test an-unknown-log-generation-keeps-the-bus-serving
  "With a refused log generation file, the generation reads NIL, cursor writes
   continue and record no generation, no cursor reads as stranded by
   generation, and the next rotation writes a readable generation above the
   last one any cursor recorded."
  (with-temp-dir (dir)
    (let* ((sub (probe-subscriber dir))
           (wal-path (cursor:subscriber-wal sub))
           (cursor-path (cursor:subscriber-cursor-path sub)))
      (wal::%write-generation wal-path 5)
      (is = 6 (wal:bump-generation wal-path) "a readable generation advances by one")
      (plant (wal:generation-path wal-path) "#S(foo)")
      (false (wal:generation wal-path))
      (is eq :returned (refusal (setf (cursor:cursor-value sub) 9)))
      (is = 9 (cursor:cursor-value sub))
      (false (cursor::%recorded-generation cursor-path)
             "the write recorded no generation")
      (plant cursor-path "4 6")
      (false (cursor:stranded-reason sub :head 10 :log-generation (wal:generation wal-path))
             "a cursor recorded against generation 6 is not stranded by an unknown one")
      (let ((new (wal:bump-generation wal-path)))
        (true (and (integerp new) (> new 6)) "the rotation wrote a higher generation")
        (is eql new (wal:generation wal-path) "and it reads back")))))

(define-test a-cursor-keeps-its-generation-while-the-logs-is-unknown
  "A cursor at 3 recorded against generation 5 is written again while the
   generation file is refused, and keeps 5. After a rotation and a new log
   grown past 3, the cursor reads as a generation mismatch, so records 1 to 3
   of the new log are not skipped."
  (with-temp-dir (dir)
    (let* ((sub (probe-subscriber dir))
           (wal-path (cursor:subscriber-wal sub))
           (cursor-path (cursor:subscriber-cursor-path sub)))
      (loop for seq from 1 to 4
            do (wal:append-record wal-path seq (format nil "old ~D" seq)))
      (wal::%write-generation wal-path 5)
      (setf (cursor:cursor-value sub) 3)
      (plant (wal:generation-path wal-path) "#S(foo)")
      (setf (cursor:cursor-value sub) 3)
      (is eql 5 (cursor::%recorded-generation cursor-path) "the write kept generation 5")
      (true (archive:archive-wal wal-path dir) "the log was sealed")
      (loop for seq from 1 to 6
            do (wal:append-record wal-path seq (format nil "new ~D" seq)))
      (is eq :generation-mismatch (cursor:stranded-reason sub)))))

(define-test a-directory-at-the-generation-path-does-not-stop-a-rotation
  "With a directory where the generation file belongs, ARCHIVE-WAL seals the log,
   moves the directory aside, and leaves a readable generation."
  (with-temp-dir (dir)
    (let* ((wal-path (merge-pathnames "bus.wal" dir))
           (generation-dir (uiop:ensure-directory-pathname
                            (wal:generation-path wal-path))))
      (loop for seq from 1 to 3
            do (wal:append-record wal-path seq (format nil "old ~D" seq)))
      (plant (merge-pathnames "inside" generation-dir) "x")
      (is eq :returned (refusal (archive:archive-wal wal-path dir)) "the rotation completed")
      (true (integerp (wal:generation wal-path)) "a readable generation was written")
      (is = 0 (wal:scan wal-path) "the live log was emptied")
      (true (find-if (lambda (p)
                       (search "bus.wal.generation.bad-"
                               (namestring p)))
                     (uiop:subdirectories dir))
            "the directory was moved aside"))))

(define-test status-and-the-strand-check-agree-under-an-unknown-generation
  "With a refused generation file and a cursor above the head, the status
   inventory reports the same stranded reason the strand check gives, which is
   what bus-receive reports."
  (with-temp-dir (dir)
    (let* ((paths (broker:make-bus-paths dir))
           (wal-path (plant (broker:bus-paths-wal paths) ""))
           (cursor-path (plant (merge-pathnames "probe"
                                                (broker:bus-paths-cursors-dir paths))
                               "9 5"))
           (sub (cursor:make-subscriber "probe" wal-path cursor-path)))
      (loop for seq from 1 to 2
            do (wal:append-record wal-path seq (format nil "r ~D" seq)))
      (plant (wal:generation-path wal-path) "#S(foo)")
      (let* ((expected (cursor:stranded-reason sub :head (wal:scan wal-path)
                                                   :log-generation (wal:generation wal-path)))
             (inventory (status:cursor-inventory paths))
             (rows (getf (getf inventory :cursors) :value)))
        (is eq :cursor-above-head expected)
        (is eq expected (getf (first rows) :stranded-reason))
        (is eql 1 (getf (getf inventory :stranded-count) :value))))))
