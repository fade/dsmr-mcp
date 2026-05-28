;;;; tests/support/portability-guard.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Shared structural portability helpers for injected-form package-leak
;;;; guards.  Every %build-attach-*-form in the codebase carries a structural
;;;; guard test that asserts no symbol in the emitted sexp comes from a
;;;; DSMR-MCP-internal package — the in-process Slynk fixture shares dsmr-mcp's
;;;; package namespace so it cannot catch leaks; only this structural check
;;;; defends the wire against real attached images.
;;;;
;;;; The helpers were duplicated verbatim across load-system-test, run-tests-test,
;;;; inspect-thread-test, and inspect-condition-test before extraction.  Each
;;;; copy could drift independently; bugs found in one would not propagate.
;;;; This support file is the single source of truth.
;;;;
;;;; Circle-safety: walk-form tracks visited cons cells in a hash-table so a
;;;; future regression that produces a circular form (e.g. a backquote macro
;;;; that double-references a gensym) diagnoses the bug as an empty leak set
;;;; rather than hanging the test runner.

(defpackage #:dsmr-mcp/tests/support/portability-guard
  (:use #:cl)
  (:export #:collect-symbols-in-form
           #:dsmr-package-leaks-in))

(in-package #:dsmr-mcp/tests/support/portability-guard)

(defun collect-symbols-in-form (form)
  "Return a flat list of every symbol appearing in FORM (a tree of conses,
strings, and atoms, descending into non-string vectors).

Circle-safe: a visited-set hash-table guards against infinite recursion if
FORM contains a circular cons structure.  In normal use FORM is the output
of a %build-attach-*-form builder, which produces only fresh quasiquote
output and never carries circles — but the visited-set keeps a regression
diagnosable rather than hanging."
  (let ((acc     '())
        (visited (make-hash-table :test 'eq)))
    (labels ((walk (x)
               (cond ((and (symbolp x) x) (push x acc))
                     ((consp x)
                      (unless (gethash x visited)
                        (setf (gethash x visited) t)
                        (walk (car x))
                        (walk (cdr x))))
                     ((and (vectorp x) (not (stringp x)))
                      (unless (gethash x visited)
                        (setf (gethash x visited) t)
                        (map nil #'walk x))))))
      (walk form))
    acc))

(defun dsmr-package-leaks-in (form)
  "Return the symbols in FORM whose home package name contains \"DSMR-MCP\"
— symbols that cannot be READ in an attached image that does not have
dsmr-mcp loaded.  Returns the empty list when no leaks are present (the
expected outcome for a correctly portable form)."
  (remove-duplicates
   (remove-if-not
    (lambda (s)
      (let ((pkg (symbol-package s)))
        (and pkg (search "DSMR-MCP" (package-name pkg)))))
    (collect-symbols-in-form form))))
