;;;; tests/protocol/wire-string-normalization-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Regression guard for the wire-in string normalisation in process-json-line.
;;;;
;;;; jzon returns SIMPLE-BASE-STRING for pure-ASCII JSON strings on SBCL. A
;;;; base-string that reaches a form passed to slynk-client:slime-eval prints as
;;;; #A((N) BASE-CHAR ...), which breaks Slynk's length-prefixed framing on the
;;;; remote reader -> EOF -> SLIME-NETWORK-ERROR. The failure only manifests
;;;; against a real external image (an in-process eval shares one reader), so no
;;;; in-process functional test can catch it. The catchable invariant is the
;;;; one these tests assert: after the parse boundary, no parsed string is a
;;;; base-string.

(defpackage #:dsmr-mcp/tests/protocol/wire-string-normalization-test
  (:use #:cl #:zebra)
  (:local-nicknames (#:jzon #:com.inuoe.jzon))
  (:import-from #:dsmr-mcp/src/wire-strings
                #:%wire-string-to-character
                #:coerce-wire-strings))

(in-package #:dsmr-mcp/tests/protocol/wire-string-normalization-test)

;;; Helpers -------------------------------------------------------------------

(defun character-string-p (s)
  "True iff S is a (SIMPLE-ARRAY CHARACTER (*)) — i.e. NOT a base-string. This
is exactly the property that serialises safely over the Slynk rex wire."
  (typep s '(simple-array character (*))))

(defparameter +ascii-form+ "(+ 1 2)"
  "A pure-ASCII source string — the case that fails over the wire as a base-string.")

;;; %wire-string-to-character -------------------------------------------------

(define-test base-string-coerced-to-character
  "A base-string is coerced to a character string with identical contents."
  (let* ((base (coerce +ascii-form+ 'base-string))
         (out  (%wire-string-to-character base)))
    (true (typep base '(simple-array base-char (*)))) ; precondition: it IS a base-string
    (true (character-string-p out))
    (is string= +ascii-form+ out)))

(define-test character-string-passes-through
  "An already-character string is returned as a character string, unchanged in
contents (no double-coercion hazard)."
  (let* ((s   (make-array (length +ascii-form+)
                          :element-type 'character
                          :initial-contents (coerce +ascii-form+ 'list)))
         (out (%wire-string-to-character s)))
    (true (character-string-p out))
    (is string= +ascii-form+ out)))

(define-test empty-string-coerced
  "An empty base-string normalises to an empty character string."
  (let ((out (%wire-string-to-character (coerce "" 'base-string))))
    (true (character-string-p out))
    (is string= "" out)))

;;; coerce-wire-strings — recursion -------------------------------------------

(define-test nested-object-and-array-strings-normalised
  "Strings nested in JSON objects and arrays are all coerced to character
strings; scalars pass through untouched."
  (let ((ht (make-hash-table :test 'equal)))
    (setf (gethash (coerce "code" 'base-string) ht) (coerce +ascii-form+ 'base-string))
    (setf (gethash "n" ht) 42)
    (setf (gethash "items" ht)
          (vector (coerce "a" 'base-string) (coerce "b" 'base-string) 7))
    (let* ((out   (coerce-wire-strings ht))
           (items (gethash "items" out)))
      ;; Value coerced.
      (true (character-string-p (gethash "code" out)))
      (is string= +ascii-form+ (gethash "code" out))
      ;; Key coerced (no base-string survives anywhere).
      (true (every #'character-string-p
                   (loop for k being the hash-keys of out collect k)))
      ;; Scalar preserved.
      (is = 42 (gethash "n" out))
      ;; Array element strings coerced, non-strings preserved.
      (true (character-string-p (aref items 0)))
      (true (character-string-p (aref items 1)))
      (is = 7 (aref items 2)))))

;;; Outbound forms: the attached-eval funnel path -----------------------------

(define-test form-tree-base-strings-coerced
  "The outbound boundary (bounded-slime-eval) coerces base-strings embedded in a
Lisp form — including in nested sublists and an improper/dotted tail — while
preserving the form's structure and its non-string atoms. This is the case a
form builder introduces after the wire-in parse (e.g. a pathname namestring)."
  (let* ((form (list 'foo
                     (coerce "ascii-arg" 'base-string)
                     (list :path (coerce "/tmp/x.lisp" 'base-string) :line 7)
                     ;; improper tail: a dotted pair ending in a base-string
                     (cons 'bar (coerce "tail" 'base-string))))
         (out  (coerce-wire-strings form)))
    ;; Structure preserved.
    (is eq 'foo (first out))
    (is eq :path (first (third out)))
    (is = 7 (getf (third out) :line))
    ;; Every embedded string coerced; no base-string survives anywhere.
    (true (character-string-p (second out)))
    (is string= "ascii-arg" (second out))
    (true (character-string-p (getf (third out) :path)))
    (is string= "/tmp/x.lisp" (getf (third out) :path))
    ;; Dotted tail coerced in place.
    (is eq 'bar (car (fourth out)))
    (true (character-string-p (cdr (fourth out))))
    (is string= "tail" (cdr (fourth out)))))

;;; End-to-end: the actual jzon parse path ------------------------------------

(define-test parsed-ascii-json-yields-no-base-string
  "Parsing a pure-ASCII JSON-RPC payload then normalising leaves every string a
character string — the post-condition that prevents the SLIME-NETWORK-ERROR,
independent of whatever element-type jzon chose."
  (let* ((line "{\"jsonrpc\":\"2.0\",\"method\":\"tools/call\",\"params\":{\"name\":\"repl-eval\",\"arguments\":{\"code\":\"(+ 1 2)\"}}}")
         (msg  (coerce-wire-strings (jzon:parse line)))
         (args (gethash "arguments" (gethash "params" msg))))
    (true (character-string-p (gethash "name" (gethash "params" msg))))
    (true (character-string-p (gethash "code" args)))
    (is string= "(+ 1 2)" (gethash "code" args))))
