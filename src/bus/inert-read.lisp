;;;; src/bus/inert-read.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; The one Lisp reader for bus state files. Cursors, log generation counters,
;;;; heartbeats, roster entries, host records and broker identities sit under a
;;;; state root that every bus participant of the same user can write, so their
;;;; content is untrusted. READ-STATE-FILE opens a state file without blocking,
;;;; refuses anything but a small regular file, and reads its data with
;;;; READ-DATUM. READ-DATUM reads with fixed reader variables and read-time
;;;; evaluation off, bounds size, nesting and prefixes, refuses
;;;; package-qualified symbols, and refuses the dispatch syntax no bus writer
;;;; emits: #S, #=, ##, #A, #n( and #n*.
;;;;
;;;; CL only, apart from the descriptor checks in %READ-FILE-TEXT, which use
;;;; sb-posix: the watcher binary loads this leaf and must not pull in a parser
;;;; library or a messaging library.

#+sbcl
(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-posix))

(defpackage #:dsmr-mcp/src/bus/inert-read
  (:use #:cl)
  (:export #:read-datum
           #:read-state-file
           #:refused-syntax
           #:refused-syntax-character
           #:refused-syntax-reason))

(in-package #:dsmr-mcp/src/bus/inert-read)

(define-condition refused-syntax (reader-error)
  ((sub-char :initarg :sub-char :initform nil :reader refused-syntax-character
             :documentation "The # dispatch sub-character refused, upcased, or NIL
                             when the refusal names no syntax.")
   (reason :initarg :reason :initform nil :reader refused-syntax-reason
           :documentation "Why the input was refused, as text, when SUB-CHAR is NIL.")
   (path :initarg :path :initform nil :reader refused-syntax-path
         :documentation "The file refused, when the refusal came from READ-STATE-FILE."))
  (:report
   (lambda (condition stream)
     (let ((source (stream-error-stream condition))
           (sub-char (refused-syntax-character condition)))
       (format stream "Refused a bus state file~@[ ~A~]: ~:[~A~;~:*#~A syntax, ~
                       which no bus writer emits~]. Check what wrote the file."
               (or (refused-syntax-path condition)
                   (and (typep source 'file-stream)
                        (ignore-errors (namestring (pathname source)))))
               sub-char
               (refused-syntax-reason condition)))))
  (:documentation
   "READER-ERROR signalled by READ-DATUM and READ-STATE-FILE for input they
    refuse. #S runs an image-defined constructor and its slot initforms. #A
    runs an image-defined type expander. #n( , #n* and #A allocate from a count
    in the text. #= and ## build circular structure that makes a plist walk
    loop forever. A file that is not a regular file can block the opener or
    never end. Any other condition the reader signals, storage exhaustion
    included, arrives as this condition with SUB-CHAR NIL."))

(defconstant +byte-limit+ 8192
  "Most bytes READ-STATE-FILE reads from a file, and most characters READ-DATUM
   reads from its source. Every bus state file a writer produces is far smaller.")

(defconstant +nesting-limit+ 32
  "Deepest list nesting the text may hold. Bus writers nest two levels at most.")

(defconstant +prefix-limit+ 64
  "Most quote, backquote, comma and # dispatch prefixes the text may hold. Each
   makes the reader recurse; bus writers emit none of them.")

(defun %refuse-input (path control &rest arguments)
  "Signal REFUSED-SYNTAX naming no character, for PATH or NIL, with the reason
   CONTROL formatted with ARGUMENTS."
  (error 'refused-syntax :stream nil :path (and path (namestring path))
                         :reason (apply #'format nil control arguments)))

(defun %skip-delimited (text start close)
  "Index just past the first unescaped CLOSE in TEXT at or after START, or the
   length of TEXT. A backslash escapes the character after it."
  (let ((n (length text)))
    (loop with i = start
          while (< i n)
          do (let ((c (char text i)))
               (cond ((char= c #\\) (incf i 2))
                     ((char= c close) (return (1+ i)))
                     (t (incf i))))
          finally (return n))))

(defun %skip-block-comment (text start)
  "Index just past the |# closing a #| comment whose body starts at START in
   TEXT, counting nested #| |# pairs, or the length of TEXT."
  (let ((n (length text))
        (depth 1)
        (i start))
    (flet ((pair-p (first second)
             (and (char= (char text i) first) (char= (char text (1+ i)) second))))
      (loop while (< i (1- n))
            do (cond ((pair-p #\| #\#)
                      (incf i 2)
                      (when (zerop (decf depth))
                        (return-from %skip-block-comment i)))
                     ((pair-p #\# #\|) (incf depth) (incf i 2))
                     (t (incf i)))))
    n))

(defun %check-text (text path)
  "Signal REFUSED-SYNTAX, naming PATH, when TEXT is longer than +BYTE-LIMIT+,
   nests lists deeper than +NESTING-LIMIT+, holds more than +PREFIX-LIMIT+
   quote, backquote, comma or # dispatch prefixes, or holds a token with a
   package marker after its first character. Strings, comments, character
   names and escaped characters are skipped as the reader skips them.

   The scan runs before READ, so a package-qualified symbol is never interned
   and the reader never recurses past the limits. A single leading colon, a
   keyword, still reads."
  (let ((n (length text))
        (i 0)
        (depth 0)
        (prefixes 0)
        (token-length nil))
    (when (> n +byte-limit+)
      (%refuse-input path "it is longer than ~D characters" +byte-limit+))
    (flet ((open-list ()
             (when (> (incf depth) +nesting-limit+)
               (%refuse-input path "it nests lists deeper than ~D" +nesting-limit+)))
           (prefix ()
             (when (> (incf prefixes) +prefix-limit+)
               (%refuse-input path "it holds more than ~D quote or dispatch prefixes"
                              +prefix-limit+)))
           (constituent (next)
             (setf token-length (1+ (or token-length 0))
                   i next)))
      (loop while (< i n)
            do (let ((c (char text i)))
                 (cond ((char= c #\")
                        (setf token-length nil
                              i (%skip-delimited text (1+ i) #\")))
                       ((char= c #\;)
                        (setf token-length nil
                              i (or (position #\Newline text :start i) n)))
                       ((char= c #\()
                        (setf token-length nil)
                        (incf i)
                        (open-list))
                       ((char= c #\))
                        (setf token-length nil
                              depth (max 0 (1- depth)))
                        (incf i))
                       ((member c '(#\' #\` #\,))
                        (setf token-length nil)
                        (incf i)
                        (prefix))
                       ((member c '(#\Space #\Tab #\Newline #\Return #\Page #\Linefeed))
                        (setf token-length nil)
                        (incf i))
                       ((and (char= c #\#) (null token-length))
                        (let ((j (1+ i)))
                          (loop while (and (< j n) (digit-char-p (char text j)))
                                do (incf j))
                          (cond ((>= j n) (setf i n))
                                ((char= (char text j) #\|)
                                 (setf i (%skip-block-comment text (1+ j))))
                                ((char= (char text j) #\\)
                                 (constituent (min n (+ j 2))))
                                (t
                                 (prefix)
                                 (setf i (1+ j))
                                 (when (char= (char text j) #\() (open-list))))))
                       ((char= c #\|)
                        (constituent (%skip-delimited text (1+ i) #\|)))
                       ((char= c #\\)
                        (constituent (min n (+ i 2))))
                       ((char= c #\:)
                        (when (and token-length (plusp token-length))
                          (%refuse-input path "it holds a package-qualified symbol"))
                        (constituent (1+ i)))
                       (t (constituent (1+ i)))))))))

(defun %refuse (stream sub-char arg)
  "Dispatch macro function: signal REFUSED-SYNTAX for SUB-CHAR on STREAM.
   Signals even while *READ-SUPPRESS* is true, so a skipped #+ or #- branch
   fails closed."
  (declare (ignore arg))
  (error 'refused-syntax :stream stream :sub-char (char-upcase sub-char)))

(defun %refuse-counted (stream sub-char arg)
  "Dispatch macro function for #( and #*: signal REFUSED-SYNTAX when ARG, the
   count, is present, since the standard reader allocates from it before
   reading any content. Without a count, read as the standard readtable does."
  (if arg
      (%refuse stream sub-char arg)
      (funcall (get-dispatch-macro-character #\# sub-char nil) stream sub-char arg)))

(defun %make-refusing-readtable ()
  "A copy of the standard readtable that refuses #S, #=, ##, #A, #n( and #n*.
   The entries hold function names, not function objects, so a redefinition of
   %REFUSE or %REFUSE-COUNTED reaches the table. The standard readtable itself
   is never modified."
  (let ((table (copy-readtable nil)))
    (dolist (sub-char '(#\S #\= #\# #\A))
      (set-dispatch-macro-character #\# sub-char '%refuse table))
    (dolist (sub-char '(#\( #\*) table)
      (set-dispatch-macro-character #\# sub-char '%refuse-counted table))))

(defparameter *refusing-readtable* (%make-refusing-readtable)
  "Readtable READ-DATUM reads under. Rebuilt on every load, so reloading this
   file applies a changed refused set; never mutated otherwise.")

(defun %read-data (text count path)
  "A list of up to COUNT data read from TEXT, shorter when TEXT ends first.
   PATH, or NIL, names the source in a refusal.

   Binds the reader variables to fixed values, independent of the caller:
   *READ-EVAL* NIL, *READ-BASE* 10, *READ-DEFAULT-FLOAT-FORMAT* SINGLE-FLOAT,
   *READ-SUPPRESS* NIL, *PACKAGE* CL-USER, and *READTABLE* the refusing copy of
   the standard readtable. Printer variables are left as the caller has them."
  (%check-text text path)
  (let ((*readtable* *refusing-readtable*)
        (*read-eval* nil)
        (*read-base* 10)
        (*read-default-float-format* 'single-float)
        (*read-suppress* nil)
        (*package* (find-package "CL-USER"))
        (eof '#:eof))
    (with-input-from-string (in text)
      (handler-case
          (loop repeat count
                for datum = (read in nil eof)
                until (eq datum eof)
                collect datum)
        (serious-condition (c)
          (if (typep c '(or reader-error end-of-file))
              (error c)
              (error 'refused-syntax
                     :stream in
                     :path (and path (namestring path))
                     :reason (format nil "the reader signalled ~S" (type-of c)))))))))

(defun %read-stream-text (stream)
  "The characters left on STREAM, at most +BYTE-LIMIT+ of them. Signals
   REFUSED-SYNTAX when more remain, or when the stream cannot be read."
  (let* ((path (and (typep stream 'file-stream) (ignore-errors (pathname stream))))
         (buffer (make-string (1+ +byte-limit+)))
         (end (handler-case (read-sequence buffer stream)
                (error (c)
                  (%refuse-input path "it cannot be read as text: ~A" (type-of c))))))
    (when (> end +byte-limit+)
      (%refuse-input path "it is longer than ~D characters" +byte-limit+))
    (subseq buffer 0 end)))

(defun read-datum (source &optional eof-value)
  "Read one datum from SOURCE, a string or a character stream, and return it,
   or EOF-VALUE when SOURCE holds none. From a stream, consumes the rest of
   the stream, at most +BYTE-LIMIT+ characters.

   Binds the reader variables to fixed values, independent of the caller:
   *READ-EVAL* NIL, *READ-BASE* 10, *READ-DEFAULT-FLOAT-FORMAT* SINGLE-FLOAT,
   *READ-SUPPRESS* NIL, *PACKAGE* CL-USER, and *READTABLE* the refusing copy of
   the standard readtable. Printer variables are left as the caller has them.

   Unqualified symbols intern in CL-USER and keywords in KEYWORD, at most
   +BYTE-LIMIT+ characters of names per read. A package-qualified symbol is
   refused before anything is interned.

   Signals only these conditions, each an ERROR:
   - READER-ERROR for malformed syntax and for #.;
   - REFUSED-SYNTAX, a READER-ERROR, for #S, #=, ##, #A, #n( and #n*, for a
     package-qualified symbol, for text over +BYTE-LIMIT+ characters, nested
     deeper than +NESTING-LIMIT+ or holding more than +PREFIX-LIMIT+ prefixes,
     and for any other condition the reader signals, storage exhaustion
     included;
   - END-OF-FILE for a form cut off by end of file."
  (let ((data (%read-data (if (stringp source) source (%read-stream-text source))
                          1 nil)))
    (if data (first data) eof-value)))

(defun read-state-file (path &key (count 1) owner (byte-limit +byte-limit+))
  "Read up to COUNT data from the bus state file at PATH. Returns two values: a
   list of the data in file order, shorter than COUNT when the file ends
   first, and T; or NIL and NIL when no file exists at PATH.

   Reads at most BYTE-LIMIT bytes, capped at +BYTE-LIMIT+, then reads the data
   from that text as READ-DATUM does. With OWNER, a uid, refuses a file owned
   by any other uid.

   Signals the conditions READ-DATUM signals, and REFUSED-SYNTAX for a file
   that:
   - cannot be opened for a reason other than its absence;
   - is not a regular file once symlinks are followed (a FIFO, a device, or a
     directory);
   - is owned by a uid other than OWNER;
   - is larger than the byte limit;
   - is not UTF-8.
   The type and owner checks run on the open descriptor, and a FIFO is opened
   without blocking."
  (multiple-value-bind (text present-p)
      (%read-file-text path (min byte-limit +byte-limit+) owner)
    (if present-p
        (values (%read-data text count path) t)
        (values nil nil))))

#+sbcl
(defun %read-file-text (path byte-limit owner)
  "The text of the regular file at PATH, decoded as UTF-8, and T; or NIL and NIL
   when no file exists there.

   Opens without blocking and checks the open descriptor, so a FIFO cannot
   block the open and a rename after the check cannot substitute another file.
   Signals REFUSED-SYNTAX when the file cannot be opened, is not a regular file
   after symlinks are followed, is not owned by uid OWNER (when OWNER is
   non-NIL), holds more than BYTE-LIMIT bytes, or is not UTF-8."
  (let ((fd (handler-case
                (sb-posix:open (sb-ext:native-namestring
                                (translate-logical-pathname (merge-pathnames path)))
                               (logior sb-posix:o-rdonly sb-posix:o-nonblock))
              (sb-posix:syscall-error (e)
                (let ((errno (sb-posix:syscall-errno e)))
                  (if (member errno (list sb-posix:enoent sb-posix:enotdir))
                      (return-from %read-file-text (values nil nil))
                      (%refuse-input path "it cannot be opened: ~A"
                                     (sb-int:strerror errno))))))))
    (unwind-protect
         (let ((stat (sb-posix:fstat fd)))
           (unless (= (logand (sb-posix:stat-mode stat) sb-posix:s-ifmt)
                      sb-posix:s-ifreg)
             (%refuse-input path "it is not a regular file"))
           (when (and owner (/= (sb-posix:stat-uid stat) owner))
             (%refuse-input path "it is owned by uid ~D, not ~D"
                            (sb-posix:stat-uid stat) owner))
           (let ((buffer (make-array (1+ byte-limit) :element-type '(unsigned-byte 8)))
                 (filled 0))
             (loop for got = (handler-case
                                 (sb-sys:with-pinned-objects (buffer)
                                   (sb-posix:read fd
                                                  (sb-sys:sap+ (sb-sys:vector-sap buffer)
                                                               filled)
                                                  (- (length buffer) filled)))
                               (sb-posix:syscall-error (e)
                                 (if (= (sb-posix:syscall-errno e) sb-posix:eintr)
                                     -1
                                     (%refuse-input path "it cannot be read: ~A"
                                                    (sb-int:strerror
                                                     (sb-posix:syscall-errno e))))))
                   until (zerop got)
                   when (plusp got)
                     do (incf filled got)
                        (when (> filled byte-limit)
                          (%refuse-input path "it is larger than ~D bytes" byte-limit)))
             (values (handler-case
                         (sb-ext:octets-to-string buffer :end filled :external-format :utf-8)
                       (error () (%refuse-input path "it is not UTF-8 text")))
                     t)))
      (sb-posix:close fd))))
