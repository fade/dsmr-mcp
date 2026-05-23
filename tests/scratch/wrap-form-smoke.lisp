;;;; tests/scratch/wrap-form-smoke.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Smoke tests for build-wrapping-form (Task 2, 02-02-PLAN.md).
;;;; The wrap-form is pure CL + SB-* and self-contained, so it can be
;;;; locally eval'd in this test process rather than requiring a real
;;;; remote Slynk image.
;;;;
;;;; Run:
;;;;   sbcl --noinform --non-interactive \
;;;;        --load tests/scratch/wrap-form-smoke.lisp --quit 2>&1 \
;;;;     | grep -iE "FAIL|unhandled|fatal"
;;;; Zero output on exit 0 = all tests passed.

(require :asdf)
(asdf:load-system :dsmr-mcp/src/attach/wrap-form)

(defpackage #:dsmr-mcp/tests/scratch/wrap-form-smoke
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/attach/wrap-form
                #:build-wrapping-form))

(in-package #:dsmr-mcp/tests/scratch/wrap-form-smoke)

(defvar *failures* 0)

(defmacro check (description &body body)
  "Run BODY; print FAIL + description and increment *failures* if it signals or
returns NIL."
  `(handler-case
       (let ((result (progn ,@body)))
         (unless result
           (format *error-output* "FAIL: ~A~%" ,description)
           (incf *failures*)))
     (error (e)
       (format *error-output* "FAIL (unhandled ~A): ~A — ~A~%"
               ,description (type-of e) e)
       (incf *failures*))))

;;; Helper: evaluate the wrap-form locally and return the 5-element result.
(defun run-wrap-form (code &optional (pkg "CL-USER"))
  (eval (build-wrapping-form code pkg)))

;;; Test 1: (+ 1 2) — printed = "3", error-context = nil
(check "Test 1: (+ 1 2) printed=3, no error"
  (let ((result (run-wrap-form "(+ 1 2)")))
    (and (equal "3" (first result))
         (null (fifth result)))))

;;; Test 2: (values 1 2 3) — printed contains "1", "2", "3"
(check "Test 2: (values 1 2 3) all values in printed"
  (let* ((result (run-wrap-form "(values 1 2 3)"))
         (printed (first result)))
    (and (search "1" printed)
         (search "2" printed)
         (search "3" printed))))

;;; Test 3: write to *terminal-io* → stdout field contains the text
(check "Test 3: *terminal-io* write lands in stdout field"
  (let* ((result (run-wrap-form "(write-string \"hi\" *terminal-io*)"))
         (stdout (third result)))
    (and (stringp stdout)
         (search "hi" stdout))))

;;; Test 4: write to *error-output* → stderr field contains the text
(check "Test 4: *error-output* write lands in stderr field"
  (let* ((result (run-wrap-form "(write-string \"oops\" *error-output*)"))
         (stderr (fourth result)))
    (and (stringp stderr)
         (search "oops" stderr))))

;;; Test 5: (error "boom") → error-context plist with required keys
(check "Test 5: (error ...) yields non-nil error-context with required keys"
  (let* ((result (run-wrap-form "(error \"boom\")"))
         (ec (fifth result)))
    (and ec
         (getf ec :condition-type)
         (getf ec :message)
         (listp (getf ec :restarts))
         ;; On SBCL frames must be non-nil; on other impls nil is acceptable
         #+sbcl (listp (getf ec :frames)))))

;;; Test 6: (read) on the empty *standard-input* → error-context :message
;;; contains the D-09 stdin hint
(check "Test 6: (read) on empty stdin has stdin hint in :message"
  (let* ((result (run-wrap-form "(read)"))
         (ec (fifth result))
         (msg (when ec (getf ec :message))))
    (and msg
         (search "no interactive *standard-input*" msg))))

;;; Summary
(if (zerop *failures*)
    (format *error-output* "wrap-form-smoke: all tests passed.~%")
    (progn
      (format *error-output* "wrap-form-smoke: ~A test(s) FAILED.~%" *failures*)
      (uiop:quit 1)))
