;;;; src/validate.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Dual-pass paren/reader validator for lisp-check-parens (VERB-07/D-17).
;;;;
;;;; Pass 1 — scan-parens: character state machine tracking open/close
;;;; delimiters, ignoring delimiters inside double-quoted strings, ; line
;;;; comments, and #| |# block comments (D-17). Character literals #\x are
;;;; consumed so #\( does not count as an open paren.
;;;;
;;;; Pass 2 — try-reader-check: reads the text with the standard CL reader
;;;; (*read-eval* nil) to detect reader errors (malformed dispatch characters,
;;;; etc.) that the paren scanner misses. Skips files using in-readtable to
;;;; avoid false positives on custom syntax. Paren errors take priority.
;;;;
;;;; Re-implemented from cl-mcp/src/validate.lisp (MIT) under AGPL. The
;;;; algorithm is adapted to use plain t/nil for the ok field (jzon encodes
;;;; t → true, nil → false without a json-bool helper) and to expose
;;;; scan-parens / try-reader-check as separate exports for the tool wrapper.

(defpackage #:dsmr-mcp/src/validate
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/log
                #:log-event)
  (:export #:scan-parens
           #:try-reader-check
           #:*check-parens-max-bytes*
           ;; scan-state struct accessors (the tool reads these for position)
           #:scan-state
           #:scan-state-line
           #:scan-state-col
           #:scan-state-stack
           #:scan-state-in-string
           #:scan-state-escape
           #:scan-state-line-comment
           #:scan-state-block-depth
           #:scan-state-block-open-pos))

(in-package #:dsmr-mcp/src/validate)

;;; ---------------------------------------------------------------------------
;;; Constants
;;; ---------------------------------------------------------------------------

(defparameter *check-parens-max-bytes* (* 2 1024 1024)
  "Maximum characters scan-parens / try-reader-check will process. SAFETY-03.")

;;; ---------------------------------------------------------------------------
;;; Scan state
;;; ---------------------------------------------------------------------------

(defstruct scan-state
  "Per-character parser state for the paren-balance scan (pass 1).

LINE and COL are 1-based. STACK holds opener entries (ch line col offset).
IN-STRING / ESCAPE track double-quoted string parsing. LINE-COMMENT is t
from ; until the end of the line. BLOCK-DEPTH / BLOCK-OPEN-POS track
#| |# block comments."
  (line 1 :type fixnum)
  (col 1 :type fixnum)
  (stack '() :type list)
  (in-string nil :type boolean)
  (escape nil :type boolean)
  (line-comment nil :type boolean)
  (block-depth 0 :type fixnum)
  (block-open-pos 0 :type fixnum))

;;; ---------------------------------------------------------------------------
;;; Internal helpers
;;; ---------------------------------------------------------------------------

(defun %closing (opener)
  "Return the matching close delimiter for OPENER."
  (ecase opener
    (#\( #\))
    (#\[ #\])
    (#\{ #\})))

(defun %push-open (stack line col base-offset ch idx)
  "Push an opener entry onto STACK; returns the new stack."
  (cons (list ch line col (+ base-offset idx)) stack))

(defun %pop-open (stack line col base-offset ch idx)
  "Pop the top opener from STACK, checking for mismatch or extra-close.
Returns (VALUES new-stack error-plist) where error-plist is nil on success."
  (if (null stack)
      (values stack
              (list :ok nil
                    :kind "extra-close"
                    :expected nil
                    :found (string ch)
                    :offset (+ base-offset idx)
                    :line line
                    :column col))
      (destructuring-bind (top-ch top-line top-col top-off) (car stack)
        (declare (ignore top-line top-col top-off))
        (let ((expected (%closing top-ch)))
          (if (char= expected ch)
              (values (cdr stack) nil)
              (values stack
                      (list :ok nil
                            :kind "mismatch"
                            :expected (string expected)
                            :found (string ch)
                            :offset (+ base-offset idx)
                            :line line
                            :column col)))))))

(defun %handle-line-comment (state ch)
  "If CH is a newline, exit line-comment mode."
  (when (char= ch #\Newline)
    (setf (scan-state-line-comment state) nil)))

(defun %handle-string (state ch)
  "Update IN-STRING / ESCAPE state for character CH."
  (cond
    ((scan-state-escape state)
     (setf (scan-state-escape state) nil))
    ((char= ch #\\)
     (setf (scan-state-escape state) t))
    ((char= ch #\")
     (setf (scan-state-in-string state) nil))))

(defun %handle-block-comment (state ch next)
  "Check for the closing |# sequence and decrement block-depth.
Returns true if a closing sequence was consumed (caller must advance idx)."
  (when (and (char= ch #\|) next (char= next #\#))
    (decf (scan-state-block-depth state))
    t))

(defun %handle-normal (state ch next idx base-offset text)
  "Handle CH in the normal (non-string, non-comment) parse context.
Returns (VALUES error-plist extra-skip) where EXTRA-SKIP is nil or an
integer count of additional characters to skip past CH."
  (cond
    ;; Semicolon: start of line comment
    ((char= ch #\;)
     (setf (scan-state-line-comment state) t)
     (values nil nil))
    ;; Double-quote: start of string
    ((char= ch #\")
     (setf (scan-state-in-string state) t)
     (values nil nil))
    ;; Character literal: #\x or #\Space etc.
    ;; Consume the backslash plus the character (and trailing alpha for named ones)
    ;; so that #\( is never treated as an open paren.
    ((and (char= ch #\#) next (char= next #\\))
     (let ((skip 1))  ; at minimum skip the backslash
       (let ((char-pos (+ idx 2)))
         (when (< char-pos (length text))
           (incf skip)  ; skip the character following the backslash
           ;; Named character literals: consume remaining alpha chars
           (when (alpha-char-p (char text char-pos))
             (loop for k from (1+ char-pos) below (length text)
                   while (alpha-char-p (char text k))
                   do (incf skip)))))
       (values nil skip)))
    ;; Block comment open: #|
    ((and (char= ch #\#) next (char= next #\|))
     (when (zerop (scan-state-block-depth state))
       (setf (scan-state-block-open-pos state) (+ base-offset idx)))
     (incf (scan-state-block-depth state))
     (values nil 1))
    ;; Open delimiters: push onto stack
    ((or (char= ch #\() (char= ch #\[) (char= ch #\{))
     (setf (scan-state-stack state)
           (%push-open (scan-state-stack state)
                       (scan-state-line state)
                       (scan-state-col state)
                       base-offset ch idx))
     (values nil nil))
    ;; Close delimiters: pop from stack
    ((or (char= ch #\)) (char= ch #\]) (char= ch #\}))
     (multiple-value-bind (new-stack err)
         (%pop-open (scan-state-stack state)
                    (scan-state-line state)
                    (scan-state-col state)
                    base-offset ch idx)
       (setf (scan-state-stack state) new-stack)
       (values err nil)))
    (t
     (values nil nil))))

(defun %advance-position (state ch)
  "Advance the line/col counters for character CH."
  (if (char= ch #\Newline)
      (progn
        (incf (scan-state-line state))
        (setf (scan-state-col state) 1))
      (incf (scan-state-col state))))

;;; ---------------------------------------------------------------------------
;;; Pass 1: scan-parens
;;; ---------------------------------------------------------------------------

(defun scan-parens (text &key (base-offset 0))
  "Walk TEXT character-by-character tracking delimiter balance.
Returns a plist with keys :ok (t or nil), and on failure: :kind, :expected,
:found, :offset, :line, :column.

Delimiters inside double-quoted strings, ; line comments, and #| |# block
comments are NOT counted (D-17). Character literals #\\x are consumed so
#\\( never counts as an open paren."
  (declare (type string text)
           (type fixnum base-offset))
  (let ((state (make-scan-state))
        (len (length text))
        (idx 0))
    (loop while (< idx len)
          for ch   = (char text idx)
          for next = (and (< (1+ idx) len) (char text (1+ idx)))
          do
          (cond
            ;; In a line comment: just watch for newline
            ((scan-state-line-comment state)
             (%handle-line-comment state ch))
            ;; In a double-quoted string
            ((scan-state-in-string state)
             (%handle-string state ch))
            ;; In a block comment
            ((plusp (scan-state-block-depth state))
             (when (%handle-block-comment state ch next)
               ;; Consumed the #| closing sequence — skip the extra char
               (incf idx)
               (incf (scan-state-col state))))
            ;; Normal parse context
            (t
             (multiple-value-bind (err extra-skip)
                 (%handle-normal state ch next idx base-offset text)
               (when err
                 (return-from scan-parens err))
               (when extra-skip
                 (let ((n (if (integerp extra-skip) extra-skip 1)))
                   (incf idx n)
                   (incf (scan-state-col state) n))))))
          (%advance-position state ch)
          (incf idx))
    ;; Check for unclosed block comment
    (when (plusp (scan-state-block-depth state))
      (let* ((open-pos  (scan-state-block-open-pos state))
             (local-pos (- open-pos base-offset))
             (pre       (subseq text 0 (min local-pos (length text))))
             (r-line    (1+ (count #\Newline pre)))
             (col-start (or (position #\Newline pre :from-end t) -1))
             (r-col     (- local-pos col-start)))
        (return-from scan-parens
          (list :ok nil
                :kind "unclosed-block-comment"
                :expected nil
                :found nil
                :offset open-pos
                :line r-line
                :column r-col))))
    ;; Check for unclosed opener
    (when (scan-state-stack state)
      (destructuring-bind (ch l c off) (pop (scan-state-stack state))
        (return-from scan-parens
          (list :ok nil
                :kind "unclosed"
                :expected (string (%closing ch))
                :found nil
                :offset off
                :line l
                :column c))))
    ;; All good
    (list :ok t)))

;;; ---------------------------------------------------------------------------
;;; Pass 2: try-reader-check
;;; ---------------------------------------------------------------------------

(defun %custom-readtable-p (text)
  "Return t when TEXT contains a named-readtable activation (in-readtable).
When a custom readtable is active the standard CL reader would produce
false-positive errors on valid custom syntax."
  (not (null (search "in-readtable" text))))

(defun %truncate-message (condition)
  "Extract a condition message string, truncating to 200 chars to prevent
SBCL stream-representation leakage in reader-error ~A formatting."
  (let ((msg (format nil "~A" condition)))
    (if (> (length msg) 200)
        (concatenate 'string (subseq msg 0 197) "...")
        msg)))

(defun try-reader-check (text &optional (base-offset 0))
  "Attempt to fully read TEXT using the standard CL reader with *read-eval* nil.
Returns a plist with :kind \"reader-error\" plus :message/:offset/:line/:column
if a genuine syntax error is detected, or nil if the text is clean.

Skips the check (returns nil) when:
- TEXT contains \"in-readtable\" (custom readtable active — standard reader
  would give false positives on valid custom syntax).
- A package-error surfaces (missing package is not a file syntax error).

*read-eval* is bound to nil to prevent #. evaluation during the pass."
  (declare (type string text))
  ;; Skip for files using custom readtables
  (when (%custom-readtable-p text)
    (return-from try-reader-check nil))
  (with-input-from-string (stream text)
    (handler-case
        (let ((*read-eval* nil))
          (loop (when (eq :eof (read stream nil :eof)) (return nil))))
      (reader-error (e)
        ;; SB-INT:SIMPLE-READER-PACKAGE-ERROR is a subtype of both
        ;; reader-error and package-error in SBCL — handle it here first.
        ;; A missing package is not a file syntax error.
        (when (typep e 'package-error)
          (return-from try-reader-check nil))
        (let* ((pos      (or (ignore-errors (file-position stream)) 0))
               (safe-pos (min pos (length text)))
               (pre      (subseq text 0 safe-pos))
               (line     (1+ (count #\Newline pre)))
               (nl-pos   (position #\Newline pre :from-end t))
               (col      (- safe-pos (or nl-pos -1))))
          (list :kind    "reader-error"
                :message (%truncate-message e)
                :offset  (+ base-offset pos)
                :line    line
                :column  col)))
      (end-of-file (e)
        ;; end-of-file is NOT a subtype of reader-error in SBCL; capture
        ;; stream position for an accurate error location.
        (declare (ignore e))
        (let* ((pos      (or (ignore-errors (file-position stream)) (length text)))
               (safe-pos (min pos (length text)))
               (pre      (subseq text 0 safe-pos))
               (line     (1+ (count #\Newline pre)))
               (nl-pos   (position #\Newline pre :from-end t))
               (col      (- safe-pos (or nl-pos -1))))
          (list :kind    "reader-error"
                :message "unexpected end of file while reading"
                :offset  (+ base-offset pos)
                :line    line
                :column  col)))
      (package-error (e)
        ;; Package-not-found is not a syntax error in the file.
        (declare (ignore e))
        nil)
      (error (e)
        ;; Catch-all for unexpected non-reader errors.
        (list :kind    "reader-error"
              :message (%truncate-message e)
              :offset  base-offset
              :line    nil
              :column  nil)))))
