;;;; src/tools/status-fields.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; The shared shape every reported status fact is rendered through, and the
;;;; walker that checks a built response against it.
;;;;
;;;; A status answer is only useful if the reader can tell what it covers. A
;;;; bare value cannot say that: "healthy" reads the same whether it came from a
;;;; request that was sent and answered this second or from a membership file
;;;; somebody wrote last week. Every instrument in this codebase that has ever
;;;; misled someone did so by answering confidently without saying what it had
;;;; actually looked at.
;;;;
;;;; So a fact is not a scalar here. It is a small object carrying the value
;;;; together with what the check establishes, what it does NOT establish, how
;;;; the value was obtained, and the condition under which it would flip. The
;;;; constructor refuses to build one that is missing any of that, and the
;;;; walker finds one that was hand-built around the constructor.

(defpackage #:dsmr-mcp/src/tools/status-fields
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:make-ht)
  (:export #:reported-field
           #:*field-basis-values*
           #:field-contract-violations
           #:field-contract-error
           #:field-contract-error-detail))

(in-package #:dsmr-mcp/src/tools/status-fields)

;;; Basis enum ---------------------------------------------------------------

(defparameter *field-basis-values*
  '("active-probe" "passive-inference" "durable-record" "roster-advisory")
  "The closed set of ways a reported value can have been obtained.

Kept small and fixed on purpose, so a reader can see at a glance whether a
value was measured or merely inferred without parsing any prose:

  active-probe       a request was sent and its answer timed on this cycle.
  passive-inference  derived from a side effect of other traffic, not from a
                     check run for this field.
  durable-record     read from a file or a roster, and therefore stale by
                     definition, however recently it was written.
  roster-advisory    read from the advisory membership record, which nothing
                     enforces. Deliberately distinct from every other value
                     here: it must never be confusable with an answer that was
                     verified against a lock.")

;;; Construction-time failure -------------------------------------------------

(define-condition field-contract-error (error)
  ((detail
    :initarg :detail
    :reader field-contract-error-detail
    :documentation "What the caller got wrong, in one sentence."))
  (:report (lambda (c s)
             (format s "Cannot build a reported field: ~A"
                     (field-contract-error-detail c))))
  (:documentation
   "Signalled when a caller tries to build a reported field that does not state
its own bounds. This is deliberately an error rather than a warning or a
silently degraded result. A field with no stated bound is not a slightly worse
field, it is the exact shape of the failure this whole contract exists to
prevent, and shipping one to a reader is worse than failing the call: the
reader has no way to tell it apart from a field whose bounds are genuinely
wide. Failing here puts the defect at the call site, where somebody can fix
it."))

;;; Helpers -------------------------------------------------------------------

(defun %blank-p (x)
  "True when X is not a string, or is a string with nothing but whitespace in it.
An empty bound is a missing bound, so the two are treated alike throughout."
  (or (not (stringp x))
      (zerop (length (string-trim '(#\Space #\Tab #\Newline #\Return) x)))))

(defun %utc-now ()
  "The current UTC time as an ISO-8601 string, matching what the rest of the
server puts on the wire."
  (multiple-value-bind (sec min hour day month year)
      (decode-universal-time (get-universal-time) 0)
    (format nil "~4,'0D-~2,'0D-~2,'0DT~2,'0D:~2,'0D:~2,'0DZ"
            year month day hour min sec)))

(defun %classification-p (value)
  "True when VALUE is enum shaped, which is to say a string.

A string value is a classification: somebody chose one word out of a small set
to describe a condition, and that choice can be wrong. A number is a
measurement and has no failure state of its own, so it is not required to carry
a red condition."
  (stringp value))

;;; Constructor ---------------------------------------------------------------

(defun reported-field (value &key establishes does-not-establish basis
                                  red-condition
                                  (checked-at (%utc-now)))
  "Build one reported fact as a hash-table ready for the wire.

VALUE is the classification or measurement itself.

ESTABLISHES names the check that produced this value, in one sentence, present
tense. It describes the mechanism that actually ran, not the purpose of the
field: \"the worker answered a ping within 2.4 seconds\", never \"reports worker
health\".

DOES-NOT-ESTABLISH names the nearest thing a reader might wrongly conclude from
this value. It is required, and it is required precisely when it feels
unnecessary. A reader who trusts a value further than the check that produced it
is the failure being guarded against, and the only place to stop that is beside
the value itself. A field with no stated bound is a defect, not an omission.

BASIS is one of *FIELD-BASIS-VALUES* and says how the value was obtained.

RED-CONDITION states the testable condition under which this value would flip to
its failure state. It is required for a classification, which is to say for any
string value, and omitted for a pure measurement such as a latency, which has no
failure state of its own. Omitting it leaves the key out of the result rather
than writing an empty one.

CHECKED-AT defaults to now, so a reader can tell a value measured on this call
from one carried over from an earlier cycle.

Signals FIELD-CONTRACT-ERROR rather than building anything non-conforming."
  (when (%blank-p establishes)
    (error 'field-contract-error
           :detail "establishes must be a non-empty string naming the check that ran"))
  (when (%blank-p does-not-establish)
    (error 'field-contract-error
           :detail "does-not-establish must be a non-empty string naming what a reader must not conclude"))
  (unless (and (stringp basis) (member basis *field-basis-values* :test #'string=))
    (error 'field-contract-error
           :detail (format nil "basis must be one of ~{~S~^, ~}, got ~S"
                           *field-basis-values* basis)))
  (when (and (%classification-p value) (%blank-p red-condition))
    (error 'field-contract-error
           :detail "a classification must state the condition under which it would flip"))
  (let ((ht (make-ht "value"              value
                     "establishes"        establishes
                     "does_not_establish" does-not-establish
                     "basis"              basis
                     "checked_at"         checked-at)))
    (unless (%blank-p red-condition)
      (setf (gethash "red_condition" ht) red-condition))
    ht))

;;; Conformance walker --------------------------------------------------------

(defun %proper-list-p (x)
  "True when X is a list that ends in NIL."
  (loop (cond ((null x) (return t))
              ((consp x) (setf x (cdr x)))
              (t (return nil)))))

(defun %sorted-keys (ht)
  "The keys of HT in a stable order, so violations come back the same way twice."
  (let ((keys '()))
    (maphash (lambda (k v) (declare (ignore v)) (push k keys)) ht)
    (sort keys #'string< :key #'princ-to-string)))

(defun field-contract-violations (response)
  "Walk an already-built RESPONSE and return the ways it breaks the contract.

Returns a list of human-readable strings, empty when RESPONSE conforms. Each
string opens with the path at which the offending field sits, so a failure
points at the field rather than at the whole response.

The rule, stated so it is reproducible without reading this code: any
hash-table carrying a \"value\" key is a reported field. Every reported field
must carry a non-empty string \"establishes\" and \"does_not_establish\", and a
\"basis\" drawn from *FIELD-BASIS-VALUES*. A reported field whose \"value\" is a
string must additionally carry a non-empty \"red_condition\".

This lives beside the constructor rather than in the test tree because it is
what every surface asserts against. REPORTED-FIELD refuses to construct a
non-conforming field, but nothing stops a caller assembling one by hand out of
a plain hash-table, and a check that only exists where somebody remembered to
write it reproduces the very problem it was meant to solve. The walk descends
through hash-tables, vectors and lists alike, so nesting a field deeper does not
hide it.

RESPONSE may be any structure; anything that is not a hash-table, vector or
list is a leaf and contributes nothing."
  (let ((violations '()))
    (labels
        ((emit (path text)
           (push (format nil "~A: ~A" path text) violations))
         (check-field (ht path)
           (multiple-value-bind (establishes presentp) (gethash "establishes" ht)
             (cond ((not presentp)
                    (emit path "reported field carries no establishes"))
                   ((%blank-p establishes)
                    (emit path "reported field has an empty establishes"))))
           (multiple-value-bind (bound presentp) (gethash "does_not_establish" ht)
             (cond ((not presentp)
                    (emit path "reported field carries no does_not_establish"))
                   ((%blank-p bound)
                    (emit path "reported field has an empty does_not_establish"))))
           (multiple-value-bind (basis presentp) (gethash "basis" ht)
             (cond ((not presentp)
                    (emit path "reported field carries no basis"))
                   ((not (and (stringp basis)
                              (member basis *field-basis-values* :test #'string=)))
                    (emit path (format nil "reported field has a basis outside the known set: ~S"
                                       basis)))))
           (when (%classification-p (gethash "value" ht))
             (multiple-value-bind (red presentp) (gethash "red_condition" ht)
               (cond ((not presentp)
                      (emit path "classification carries no red_condition"))
                     ((%blank-p red)
                      (emit path "classification has an empty red_condition"))))))
         (walk (node path)
           (cond
             ((hash-table-p node)
              (when (nth-value 1 (gethash "value" node))
                (check-field node path))
              (dolist (k (%sorted-keys node))
                (walk (gethash k node)
                      (format nil "~A.~A" path (princ-to-string k)))))
             ((and (vectorp node) (not (stringp node)))
              (loop for i from 0 below (length node)
                    do (walk (aref node i) (format nil "~A[~D]" path i))))
             ((and (consp node) (%proper-list-p node))
              (loop for item in node
                    for i from 0
                    do (walk item (format nil "~A[~D]" path i))))
             (t nil))))
      (walk response "$"))
    (nreverse violations)))
