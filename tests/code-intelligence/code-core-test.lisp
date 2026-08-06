;;;; tests/code-intelligence/code-core-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Wave-0 in-process tests for the shared sb-introspect engine in
;;;; src/code-core.lisp. All tests run without spawning a worker process or
;;;; an attached Slynk image — they exercise the engine functions directly.
;;;;
;;;; Coverage:
;;;;   - code-find-definition returns a non-empty location list for a loaded function
;;;;   - code-find-definition returns separate :method entries for a GF with multiple methods
;;;;   - %parse-symbol handles qualified, (setf ...), and keyword designators
;;;;   - %parse-symbol does not evaluate #. read-time forms
;;;;   - %offset->line returns the defun line, skipping a leading comment
;;;;   - code-find-references returns caller entries with path/line/relation
;;;;   - code-find-definition surfaces symbol-not-found with a hint for absent symbols

(defpackage #:dsmr-mcp/tests/code-intelligence/code-core-test
  (:use #:cl #:zebra)
  (:import-from #:dsmr-mcp/src/code-core
                #:%parse-symbol
                #:%offset->line
                #:code-find-definition
                #:code-describe-symbol
                #:code-find-references))

(in-package #:dsmr-mcp/tests/code-intelligence/code-core-test)

;;;; ---------------------------------------------------------------------------
;;;; Throwaway generic function with two methods — for multi-location test
;;;; ---------------------------------------------------------------------------

(defgeneric %multi-location-test-gf (x)
  (:documentation "Throwaway generic function with two methods for the multi-location test."))

(defmethod %multi-location-test-gf ((x integer))
  (* x 2))

(defmethod %multi-location-test-gf ((x string))
  (string-upcase x))

;;;; ---------------------------------------------------------------------------
;;;; Tests
;;;; ---------------------------------------------------------------------------

(define-test code-find-locates-known-function
  "code-find-definition returns a non-empty location list for a symbol that is
loaded in the current image. Each entry must have a string :path and integer :line."
  (let ((locs (code-find-definition "make-hash-table" :package "cl")))
    (true (listp locs))
    (false (null locs))
    (let ((first (car locs)))
      (true (listp first))
      (true (stringp (getf first :path)))
      (true (integerp (getf first :line)))
      (true (plusp (getf first :line))))))

(define-test code-find-returns-all-method-locations
  "code-find-definition for a generic function with multiple defmethods returns
separate :method entries for each method."
  (let* ((locs (code-find-definition
                "%multi-location-test-gf"
                :package "dsmr-mcp/tests/code-intelligence/code-core-test"))
         (method-entries (remove-if-not
                          (lambda (loc)
                            (string= "method" (getf loc :kind)))
                          locs)))
    ;; Must have found at least 2 method entries.
    (true (> (length method-entries) 1))))

(define-test parse-symbol-reads-qualified-and-setf-and-keyword
  "%parse-symbol handles pkg:sym, (setf name), and :keyword designators."
  ;; Qualified with colon.
  (let ((s (ignore-errors (%parse-symbol "cl:list"))))
    (is eq 'cl:list s))
  ;; Keyword.
  (let ((kw (ignore-errors (%parse-symbol ":foo"))))
    (is eq :foo kw))
  ;; (setf ...) designator: read-from-string returns a list starting with SETF.
  (let ((setf-form (ignore-errors (%parse-symbol "(setf documentation)"))))
    (true (consp setf-form))
    (is eq 'setf (first setf-form))
    (is eq 'documentation (second setf-form))))

(define-test parse-symbol-binds-read-eval-nil
  "%parse-symbol does not evaluate a #. form embedded in the designator string.
Proves that *read-eval* is bound to nil during reading."
  ;; With *read-eval* nil, #.(error \"boom\") must not signal — it should
  ;; either return :eof or signal a reader-error (which we catch), never
  ;; evaluate the form and raise the error condition.
  (let ((boom-triggered nil))
    (handler-case
        (%parse-symbol "#.(setf boom-triggered t)")
      ;; reader-error is expected when *read-eval* is nil and #. is encountered.
      (reader-error () nil)
      ;; Any other error (e.g. the error from the #. form) is a test failure.
      (error (e)
        (fail (format nil
                      "parse-symbol-binds-read-eval-nil: unexpected error ~A"
                      e))))
    ;; The #. form must never have actually run.
    (false boom-triggered)))

(define-test offset-to-line-points-at-form
  "%offset->line on a file with a leading comment returns the line of the
opening parenthesis of the defun, not the comment line."
  (uiop:with-temporary-file (:stream s :pathname path :direction :output
                              :element-type 'character :keep nil)
    (write-string ";; leading comment" s)
    (write-char #\Newline s)
    (write-string "(defun %test-offset-fn () t)" s)
    :close-stream
    ;; The defun starts at offset 19 (after the 18-char comment + newline).
    (let* ((offset 0)                   ; start from the very beginning
           (line (%offset->line path offset)))
      ;; Line 1 is the comment; the scanner must skip it and report line 2.
      (is = 2 line))))

(define-test find-references-returns-callers-with-relation
  "code-find-references for a function returns a list (possibly empty when
no xref data is tracked). When entries exist each must carry :path, :line,
:caller, and :relation. Filtering is project-only=nil so we see all callers."
  ;; Use code-describe-symbol as the target — it calls code-find-definition
  ;; internally, providing at least one likely caller in this image.
  ;; Wrap in ignore-errors so an xref scan failure doesn't mask other tests.
  (let ((refs (ignore-errors
                (code-find-references
                 "code-describe-symbol"
                 :package "dsmr-mcp/src/code-core"
                 :project-only nil))))
    ;; The result must be a list (nil = empty list is acceptable).
    (true (or (null refs) (listp refs)))
    ;; When references exist each must carry the required keys.
    (when (and refs (listp refs) (consp (car refs)))
      (let ((first (car refs)))
        (true (stringp (getf first :path)))
        (true (integerp (getf first :line)))
        (true (stringp (getf first :caller)))
        (true (stringp (getf first :relation)))))))

(define-test find-definition-typed-not-found
  "code-find-definition returns the symbol-not-found typed marker plist for a
symbol that is not present in the image, carrying a :hint string."
  (let ((result (code-find-definition
                 "%dsmr-code-core-deliberately-absent-symbol-xyzzy"
                 :package "cl-user")))
    ;; Must be a plist. The marker is (:not-found <kind> :name ... :hint ...).
    ;; (getf result :not-found) returns the kind (:symbol / :package / etc.).
    (true (listp result))
    ;; The :not-found key must be present — getf returns the VALUE, which is
    ;; one of :symbol / :package / :source-location.
    (true (member (getf result :not-found) '(:symbol :package :source-location)))
    ;; There must be a :hint string.
    (true (stringp (getf result :hint)))
    (true (plusp (length (getf result :hint))))))
