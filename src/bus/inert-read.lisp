;;;; src/bus/inert-read.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; The one Lisp reader for bus state files. Cursors, log generation counters,
;;;; heartbeats, roster entries, host records and broker identities sit under a
;;;; state root that every bus participant of the same user can write, so their
;;;; content is untrusted. READ-STATE-FILE opens a state file without blocking,
;;;; refuses anything but a regular file within its byte limit, and reads its
;;;; data with READ-DATUM. READ-DATUM reads with fixed reader variables and
;;;; read-time evaluation off, bounds size, nesting, prefixes, and token length,
;;;; refuses package-qualified symbols, and refuses the syntax no bus writer
;;;; emits: backquote, comma, vertical bar, #S, #=, ##, #A, #|, #:, #n( and #n*.
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
         :documentation "The file refused, or NIL. Set when READ-STATE-FILE's opener or pre-read
    scan refused the file, or when it wraps another error the reader
    signalled; NIL for syntax the readtable refuses."))
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
    loop forever. Backquote, comma, vertical bar, #| and #: are refused so
    the pre-read scan and the reader always parse a text the same way. A file
    that is not a regular file can block the opener or never end. Any other
    ERROR or STORAGE-CONDITION the reader signals, apart from READER-ERROR and
    END-OF-FILE, arrives as this condition with SUB-CHAR NIL."))

(defconstant +byte-limit+ 8192
  "Default for the most bytes READ-STATE-FILE reads from a file, and the most
   characters READ-DATUM reads from its source. Cursors, generations, beats,
   roster entries and broker identities are far smaller.")

(defconstant +byte-ceiling+ (* 1024 1024)
  "The largest byte limit a READ-STATE-FILE caller may ask for. The host service
   status summary grows with the number of registrations and asks for this.")

(defconstant +nesting-limit+ 32
  "Deepest list nesting the text may hold. Bus writers nest two levels at most.")

(defconstant +prefix-limit+ 64
  "Most quote and # dispatch prefixes the text may hold. Each makes the reader
   recurse; bus writers emit none of them.")

(defconstant +token-limit+ 128
  "Longest token, in characters, the text may hold; strings are exempt. The
   reader's cost for a number grows faster than its length, and bus writers
   emit no token near this long.")

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

(defun %check-text (text path limit)
  "Signal REFUSED-SYNTAX, naming PATH, when TEXT:
   - is longer than LIMIT characters;
   - nests lists deeper than +NESTING-LIMIT+;
   - holds more than +PREFIX-LIMIT+ quote or # dispatch prefixes;
   - holds backquote, comma, vertical bar, #| or #:;
   - holds a token longer than +TOKEN-LIMIT+ characters;
   - holds a token with a package marker after its first character.
   Strings, ; comments, character names and backslash escapes are skipped as
   the reader skips them.

   The scan runs before READ, so a package-qualified symbol is never interned
   and the reader never recurses past the limits. Every construct whose extent
   the scan does not follow is refused here and by the readtable, so the scan
   and the reader cannot parse a text differently. A single leading colon, a
   keyword, still reads."
  (let ((n (length text))
        (i 0)
        (depth 0)
        (prefixes 0)
        (token-length nil))
    (when (> n limit)
      (%refuse-input path "it is longer than ~D characters" limit))
    (flet ((open-list ()
             (when (> (incf depth) +nesting-limit+)
               (%refuse-input path "it nests lists deeper than ~D" +nesting-limit+)))
           (prefix ()
             (when (> (incf prefixes) +prefix-limit+)
               (%refuse-input path "it holds more than ~D quote or dispatch prefixes"
                              +prefix-limit+)))
           (unmodelled (what)
             (%refuse-input path "it holds ~A, which no bus writer emits" what))
           (constituent (next)
             (setf token-length (1+ (or token-length 0))
                   i next)
             (when (> token-length +token-limit+)
               (%refuse-input path "it holds a token longer than ~D characters"
                              +token-limit+))))
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
                       ((char= c #\')
                        (setf token-length nil)
                        (incf i)
                        (prefix))
                       ((member c '(#\` #\,))
                        (unmodelled "backquote or comma syntax"))
                       ((char= c #\|)
                        (unmodelled "a vertical bar"))
                       ((member c '(#\Space #\Tab #\Newline #\Return #\Page #\Linefeed))
                        (setf token-length nil)
                        (incf i))
                       ((and (char= c #\#) (null token-length))
                        (let ((j (1+ i)))
                          (loop while (and (< j n) (digit-char-p (char text j)))
                                do (incf j))
                          (cond ((>= j n) (setf i n))
                                ((char= (char text j) #\|)
                                 (unmodelled "a #| comment"))
                                ((char= (char text j) #\:)
                                 (unmodelled "an uninterned symbol"))
                                ((char= (char text j) #\\)
                                 (constituent (min n (+ j 2))))
                                (t
                                 (prefix)
                                 (setf i (1+ j))
                                 (when (char= (char text j) #\() (open-list))))))
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

(defun %refuse-macro (stream char)
  "Macro character function: signal REFUSED-SYNTAX for CHAR on STREAM."
  (error 'refused-syntax
         :stream stream
         :reason (format nil "~A syntax, which no bus writer emits" char)))

(defun %make-refusing-readtable ()
  "A copy of the standard readtable that refuses backquote, comma, vertical
   bar, #S, #=, ##, #A, #|, #:, #n( and #n*. The entries hold function names,
   not function objects, so a redefinition of a refusing function reaches the
   table. The standard readtable itself is never modified."
  (let ((table (copy-readtable nil)))
    (dolist (char '(#\` #\, #\|))
      (set-macro-character char '%refuse-macro nil table))
    (dolist (sub-char '(#\S #\= #\# #\A #\| #\:))
      (set-dispatch-macro-character #\# sub-char '%refuse table))
    (dolist (sub-char '(#\( #\*) table)
      (set-dispatch-macro-character #\# sub-char '%refuse-counted table))))

(defparameter *refusing-readtable* (%make-refusing-readtable)
  "Readtable READ-DATUM reads under. Rebuilt on every load, so reloading this
   file applies a changed refused set; never mutated otherwise.")

(defun %read-data (text count path limit)
  "A list of up to COUNT data read from TEXT, shorter when TEXT ends first.
   PATH, or NIL, names the source in a refusal. TEXT longer than LIMIT
   characters is refused.

   Binds the reader variables to fixed values, independent of the caller:
   *READ-EVAL* NIL, *READ-BASE* 10, *READ-DEFAULT-FLOAT-FORMAT* SINGLE-FLOAT,
   *READ-SUPPRESS* NIL, *PACKAGE* CL-USER, and *READTABLE* the refusing copy of
   the standard readtable. Printer variables are left as the caller has them."
  (%check-text text path limit)
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
        ;; Only what the reader itself can cause. A timeout, deadline or
        ;; interrupt is neither, and must reach the caller as itself.
        ((or storage-condition error) (c)
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

   Signals these conditions, each an ERROR:
   - READER-ERROR for malformed syntax and for #.;
   - REFUSED-SYNTAX, a READER-ERROR, for the refused syntax (backquote, comma,
     vertical bar, #S, #=, ##, #A, #|, #:, #n( and #n*), for a
     package-qualified symbol, for a token over +TOKEN-LIMIT+ characters,
     for text over +BYTE-LIMIT+ characters, nested
     deeper than +NESTING-LIMIT+ or holding more than +PREFIX-LIMIT+ prefixes,
     and for any other ERROR or STORAGE-CONDITION the reader signals;
   - END-OF-FILE for a form cut off by end of file.
   Any other serious condition raised during the read, such as a timeout or an
   interrupt, passes through unchanged."
  (let ((data (%read-data (if (stringp source) source (%read-stream-text source))
                          1 nil +byte-limit+)))
    (if data (first data) eof-value)))

(defun read-state-file (path &key (count 1) owner (byte-limit +byte-limit+))
  "Read up to COUNT data from the bus state file at PATH. Returns two values: a
   list of the data in file order, shorter than COUNT when the file ends
   first, and T; or NIL and NIL when no file exists at PATH.

   Reads at most BYTE-LIMIT bytes (default +BYTE-LIMIT+, capped at
   +BYTE-CEILING+), then reads the data
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
  (let ((limit (min byte-limit +byte-ceiling+)))
    (multiple-value-bind (text present-p) (%read-file-text path limit owner)
      (if present-p
          (values (%read-data text count path limit) t)
          (values nil nil)))))

#+sbcl
(defun %read-file-text (path byte-limit owner)
  "The text of the regular file at PATH, decoded as UTF-8, and T; or NIL and NIL
   when no file exists there.

   Opens without blocking and without taking a controlling terminal, and checks
   the open descriptor, so a FIFO cannot block the open, a terminal cannot
   become the process's controlling terminal, and a rename after the check
   cannot substitute another file.
   Signals REFUSED-SYNTAX when the file cannot be opened, is not a regular file
   after symlinks are followed, is not owned by uid OWNER (when OWNER is
   non-NIL), holds more than BYTE-LIMIT bytes, or is not UTF-8."
  (let ((fd (handler-case
                (sb-posix:open (sb-ext:native-namestring
                                (translate-logical-pathname (merge-pathnames path)))
                               (logior sb-posix:o-rdonly sb-posix:o-nonblock sb-posix:o-noctty))
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
