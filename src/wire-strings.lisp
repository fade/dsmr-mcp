;;;; src/wire-strings.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; One recursive coercion that keeps SIMPLE-BASE-STRINGs off the Slynk wire.
;;;;
;;;; A SIMPLE-BASE-STRING anywhere in a form bound for slynk-client prints,
;;;; under the rex encoder's *print-readably* t, as #A((N) BASE-CHAR ...) — an
;;;; array literal longer than the byte count Slynk's length prefix was computed
;;;; from. The remote reader hits EOF mid-message and drops the connection,
;;;; surfacing as slime-network-error. This class has recurred repeatedly; the
;;;; guard belongs in ONE place so the two wire boundaries can't drift:
;;;;
;;;;   - inbound:  the freshly parsed JSON-RPC message (dsmr-mcp/src/protocol),
;;;;               where jzon hands back SIMPLE-BASE-STRINGs for ASCII JSON.
;;;;   - outbound: the attached-eval funnel (dsmr-mcp/src/attach/connection),
;;;;               where a form builder can introduce a base-string the inbound
;;;;               pass never saw — e.g. (namestring project-root), a
;;;;               SIMPLE-BASE-STRING on SBCL for an ASCII path.

(defpackage #:dsmr-mcp/src/wire-strings
  (:use #:cl)
  (:export #:coerce-wire-strings
           #:%wire-string-to-character))

(in-package #:dsmr-mcp/src/wire-strings)

(defun %wire-string-to-character (s)
  "Return S as a (SIMPLE-ARRAY CHARACTER (*)); a no-op when S already is one."
  (if (typep s '(simple-array character (*)))
      s
      (map '(simple-array character (*)) #'identity s)))

(defun coerce-wire-strings (value)
  "Recursively rebuild VALUE, coercing every embedded string to element-type
CHARACTER so no SIMPLE-BASE-STRING reaches the rex encoder.

Conses (Lisp forms, including improper/dotted tails), vectors (JSON arrays), and
hash-tables (JSON objects) are rebuilt with their contents coerced; every other
atom passes through unchanged. The cons branch makes this safe for outbound Lisp
forms; the vector/hash-table branches make it safe for inbound parsed JSON. A
string already of element-type CHARACTER is returned as-is."
  (typecase value
    (string (%wire-string-to-character value))
    (cons (cons (coerce-wire-strings (car value))
                (coerce-wire-strings (cdr value))))
    (hash-table
     (let ((out (make-hash-table :test (hash-table-test value)
                                 :size (hash-table-count value))))
       (maphash (lambda (k v)
                  (setf (gethash (coerce-wire-strings k) out)
                        (coerce-wire-strings v)))
                value)
       out))
    ((and vector (not string))
     (map 'vector #'coerce-wire-strings value))
    (t value)))
