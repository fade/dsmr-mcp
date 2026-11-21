;;;; src/support-package.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Run-time lookup of the support code's own packages.
;;;;
;;;; A run-time lookup (find-package, find-symbol, uiop:symbol-call) must not
;;;; name the dsmr-mcp prefix literally. A worker image may carry its support
;;;; code under another prefix, beside a subject's own dsmr-mcp packages, and a
;;;; literal prefix would then reach the subject's code instead of its own. The
;;;; prefix here is read at call time from this file's own package name, so it
;;;; follows a rename of every support package.

(defpackage #:dsmr-mcp/src/support-package
  (:use #:cl)
  (:export #:support-prefix
           #:support-package
           #:support-symbol-call))

(in-package #:dsmr-mcp/src/support-package)

(defun %prefix-of (package-name)
  "The text of PACKAGE-NAME before its first \"/SRC/\", or the whole name when
it holds none."
  (let ((cut (search "/SRC/" package-name)))
    (if cut (subseq package-name 0 cut) package-name)))

(defun support-prefix ()
  "The prefix the support code's packages carry in this image, \"DSMR-MCP\"
unless the image renamed them."
  (%prefix-of (package-name (symbol-package 'support-prefix))))

(defun support-package (suffix)
  "The support package named by the prefix, \"/\" and SUFFIX (for example
\"SRC/NOTIFY\"), or NIL when no such package exists."
  (find-package (concatenate 'string (support-prefix) "/" (string suffix))))

(defun support-symbol-call (suffix name &rest args)
  "Call the function named NAME in the support package SUFFIX with ARGS and
return its values. Signals an error when the package or the function is
absent."
  (let ((package (support-package suffix)))
    (unless package
      (error "no support package ~A/~A; check the package suffix"
             (support-prefix) suffix))
    (let ((symbol (find-symbol (string name) package)))
      (unless (and symbol (fboundp symbol))
        (error "no function ~A in support package ~A; check the symbol name"
               name (package-name package)))
      (apply symbol args))))
