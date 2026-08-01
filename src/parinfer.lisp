;;;; src/parinfer.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Minimal Parinfer-like indent-mode repair for LISP-EDIT-FORM.
;;;; Appends missing close parens when indentation decreases and closes
;;;; remaining open parens at EOF, so an LLM-supplied form with a missing
;;;; ')' becomes structurally valid before it is spliced into the file.
;;;;
;;;; Known limitation: block comments (#| ... |#) are NOT tracked by the
;;;; character-level state machine here.  A '#|' inside a block comment
;;;; will be seen as ordinary text; this is a known bug in the upstream
;;;; cl-mcp algorithm that we carry forward intentionally rather than
;;;; over-engineering.  Single-line ';' comments are handled correctly.
;;;;
;;;; Fresh AGPL write adapting the algorithm from cl-mcp/src/parinfer.lisp (MIT).

(defpackage #:dsmr-mcp/src/parinfer
  (:use #:cl)
  (:import-from #:uiop #:split-string)
  (:export #:apply-indent-mode))

(in-package #:dsmr-mcp/src/parinfer)

;;; -------------------------------------------------------------------------
;;; State struct
;;;
;;; Named PARINFER-STATE (not the generic STATE used in cl-mcp) to avoid
;;; symbol collisions in a package-inferred codebase where imports are
;;; explicit.
;;; -------------------------------------------------------------------------

(defstruct (parinfer-state (:constructor %make-parinfer-state))
  "Per-character state machine state for the indent-mode repair pass."
  (stack nil :type list)           ; indentation-column stack for open parens
  (in-string nil :type boolean)    ; inside a string literal?
  (escape nil :type boolean)       ; next char is escaped (inside string)?
  (sharp-seen nil :type boolean)   ; previous char was '#' (outside string)?
  (char-literal nil :type boolean)); previous char was '#\' (skip next)?

;;; -------------------------------------------------------------------------
;;; Helpers
;;; -------------------------------------------------------------------------

(defun %count-leading-spaces (line)
  "Return the number of leading space/tab characters in LINE."
  (loop for ch across line
        while (member ch '(#\Space #\Tab))
        count 1))

(defun %line-empty-or-comment-p (line)
  "Return T when LINE is blank or starts with ';' after stripping leading whitespace."
  (let ((trimmed (string-left-trim '(#\Space #\Tab) line)))
    (or (string= trimmed "")
        (char= (char trimmed 0) #\;))))

(defun %dedent-closes (state indent)
  "Pop open parens from STATE whose column exceeds INDENT.
Returns the count of parens that must be appended to the previous line."
  (let ((pending 0))
    (loop while (and (parinfer-state-stack state)
                     (> (car (parinfer-state-stack state)) indent))
          do (pop (parinfer-state-stack state))
             (incf pending))
    pending))

(defun %append-closes-to-previous (processed-lines count)
  "Destructively append COUNT ')' characters to the first element of
PROCESSED-LINES (which is the most recently pushed = previous line).
Returns PROCESSED-LINES."
  (when (and (plusp count) processed-lines)
    (setf (first processed-lines)
          (format nil "~A~A"
                  (first processed-lines)
                  (make-string count :initial-element #\)))))
  processed-lines)

(defun %process-line-characters (line state)
  "Process every character in LINE, tracking parens, strings, comments,
and character literals so that real open/close parens are correctly pushed/
popped on STATE's stack.  Returns the processed line text."
  (let ((output (make-string-output-stream)))
    (loop for ch across line
          for col from 0
          do (cond
               ;; After '#\': skip this char (it is the literal character).
               ((parinfer-state-char-literal state)
                (write-char ch output)
                (setf (parinfer-state-char-literal state) nil))
               ;; Previous char was '#' outside string, next is '\': this is '#\'.
               ((and (parinfer-state-sharp-seen state) (char= ch #\\))
                (write-char ch output)
                (setf (parinfer-state-sharp-seen state) nil)
                (setf (parinfer-state-char-literal state) t))
               ;; Previous char was '#' but next is not '\': reset flag and
               ;; re-process this char normally (so #( vector literals still
               ;; push the stack, etc.).
               ((parinfer-state-sharp-seen state)
                (setf (parinfer-state-sharp-seen state) nil)
                (cond
                  ((char= ch #\")
                   (write-char ch output)
                   (setf (parinfer-state-in-string state)
                         (not (parinfer-state-in-string state))))
                  ((char= ch #\;)
                   (loop for i from col below (length line)
                         do (write-char (char line i) output))
                   (return))
                  ((char= ch #\()
                   (write-char ch output)
                   (push (1+ col) (parinfer-state-stack state)))
                  ((char= ch #\))
                   (when (parinfer-state-stack state)
                     (pop (parinfer-state-stack state))
                     (write-char ch output)))
                  (t (write-char ch output))))
               ;; Escape sequence inside string.
               ((parinfer-state-escape state)
                (write-char ch output)
                (setf (parinfer-state-escape state) nil))
               ;; Backslash inside string.
               ((and (parinfer-state-in-string state) (char= ch #\\))
                (write-char ch output)
                (setf (parinfer-state-escape state) t))
               ;; String delimiter.
               ((char= ch #\")
                (write-char ch output)
                (setf (parinfer-state-in-string state)
                      (not (parinfer-state-in-string state))))
               ;; '#' outside string: set flag to check next char.
               ((and (not (parinfer-state-in-string state)) (char= ch #\#))
                (write-char ch output)
                (setf (parinfer-state-sharp-seen state) t))
               ;; ';' comment outside string: copy rest of line and stop.
               ((and (not (parinfer-state-in-string state)) (char= ch #\;))
                (loop for i from col below (length line)
                      do (write-char (char line i) output))
                (return))
               ;; Open paren outside string.
               ((and (not (parinfer-state-in-string state)) (char= ch #\())
                (write-char ch output)
                (push (1+ col) (parinfer-state-stack state)))
               ;; Close paren outside string.
               ((and (not (parinfer-state-in-string state)) (char= ch #\)))
                (when (parinfer-state-stack state)
                  (pop (parinfer-state-stack state))
                  (write-char ch output)))
               (t (write-char ch output))))
    ;; Reset per-line transient flags at line end.
    (setf (parinfer-state-escape state) nil
          (parinfer-state-sharp-seen state) nil
          (parinfer-state-char-literal state) nil)
    (get-output-stream-string output)))

(defun %append-remaining-closes (state processed-lines)
  "Append any still-open parens from STATE's stack to the last output line."
  (let ((remaining (length (parinfer-state-stack state))))
    (when (and (plusp remaining) processed-lines)
      (setf (first processed-lines)
            (format nil "~A~A"
                    (first processed-lines)
                    (make-string remaining :initial-element #\))))))
  processed-lines)

;;; -------------------------------------------------------------------------
;;; Public API
;;; -------------------------------------------------------------------------

(defun apply-indent-mode (text)
  "Apply a minimal Parinfer-like indent-mode pass to TEXT.

Closes open forms when indentation decreases, drops excess close parens,
and ignores parentheses inside strings or ';' comments.  Preserves the
trailing-newline state of the input.

A line that begins inside a string literal is copied through with its
indentation ignored: leading whitespace there is text, not structure.  Read as
structure, a docstring continuation flush at column zero looks like a dedent
back to top level, which closes the enclosing form early.  The close paren then
lands inside the docstring and the form's own closing paren, arriving with an
empty stack, is discarded as an excess one.

Typical use: repair LLM-generated content that is missing one or more
closing parens before splicing it into a file."
  (let ((ends-with-newline (and (plusp (length text))
                                (char= (char text (1- (length text))) #\Newline)))
        (lines (uiop:split-string text :separator '(#\Newline)))
        (state (%make-parinfer-state))
        (processed-lines '()))
    (dolist (line lines)
      (unless (parinfer-state-in-string state)
        (let ((indent (%count-leading-spaces line))
              (code-line-p (not (%line-empty-or-comment-p line))))
          (when code-line-p
            (let ((pending (%dedent-closes state indent)))
              (%append-closes-to-previous processed-lines pending)))))
      (push (%process-line-characters line state) processed-lines))
    ;; Close any parens still open at EOF.
    (%append-remaining-closes state processed-lines)
    ;; Rebuild the text, preserving the original trailing-newline state.
    (let ((result (format nil "~{~A~^~%~}" (nreverse processed-lines))))
      (if ends-with-newline
          (concatenate 'string result (string #\Newline))
          result))))
