;;;; src/attach/registry.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Dispatcher-side builders for the image-resident attached object registry.
;;;; This file runs on the DISPATCHER side — it builds sexps to inject into
;;;; the user's Slynk image; it does NOT run inside the attached image itself.
;;;;
;;;; The injected package DSMR-MCP-ATTACH-REGISTRY is pure ANSI: a hash-table,
;;;; monotonic counter, and a lock — no MOP, no jzon, no SBCL-specific forms.
;;;; Every symbol inside injected forms follows the %DSMR-MCP-ATTACH-REG-
;;;; CL-USER interning convention so the remote reader can resolve them.
;;;; (See src/attach/wrap-form.lisp Critical Constraint 1.)
;;;;
;;;; Re-implemented from cl-mcp/src/object-registry.lisp (MIT) under AGPL.
;;;; inspectable-p copied verbatim with package renamed.

(defpackage #:dsmr-mcp/src/attach/registry
  (:use #:cl)
  (:import-from #:bordeaux-threads
                #:make-lock
                #:with-lock-held)
  (:import-from #:dsmr-mcp/src/log
                #:log-event)
  (:export #:build-registry-ensure-form
           #:build-register-result-form
           #:build-lookup-form
           #:inspectable-p
           #:encode-object-id
           #:decode-object-id))

(in-package #:dsmr-mcp/src/attach/registry)

;;; Dispatcher-side predicate -------------------------------------------------
;;;
;;; Re-implemented from cl-mcp/src/object-registry.lisp lines 45-51 (MIT)
;;; under AGPL, with package renamed to dsmr-mcp/src/attach/registry.
;;;
;;; This runs on the DISPATCHER side to decide whether to attempt registration.
;;; An analogous inline check (numberp/stringp/symbolp/characterp) is embedded
;;; directly in the injected forms so the attached image does not call back here.

(defun inspectable-p (object)
  "Return T if OBJECT should be registered for inspection.
Primitives (numbers, strings, symbols, characters) are excluded."
  (not (or (numberp object)
           (stringp object)
           (symbolp object)
           (characterp object))))

;;; Object-ID codec -----------------------------------------------------------
;;;
;;; Wire format: "<epoch>:<session-id>:<raw-id>"
;;; The session-id segment must not itself contain a colon;
;;; the session IDs produced by dsmr-mcp/src/state (UUID-style) satisfy this.

(defun encode-object-id (epoch session-id raw-id)
  "Return the wire string for a result_object_id.
Format: \"EPOCH:SESSION-ID:RAW-ID\" where EPOCH and RAW-ID are integers
and SESSION-ID is a string that must not contain a colon."
  (format nil "~A:~A:~A" epoch session-id raw-id))

(defun decode-object-id (id-string)
  "Return (values EPOCH SESSION-ID RAW-ID) parsed from ID-STRING.
Signals a plain error when ID-STRING is not in epoch:session-id:raw-id format
(exactly 3 colon-delimited parts).  SESSION-ID is returned as a string;
EPOCH and RAW-ID are returned as integers."
  (let ((parts (uiop:split-string id-string :separator ":")))
    (unless (= (length parts) 3)
      (error "Malformed object-id (expected epoch:session:raw-id): ~S" id-string))
    (values (parse-integer (first parts))
            (second parts)
            (parse-integer (third parts)))))

;;; Injected-form builders ----------------------------------------------------
;;;
;;; These functions return plain Lisp s-expressions (not strings) intended to
;;; be evaluated inside the user's Slynk image via slynk-client:slime-eval.
;;;
;;; CRITICAL CONSTRAINTS (inherit from wrap-form.lisp):
;;;   1. Every symbol referenced inside the returned form is either a CL
;;;      standard symbol, a string literal, or a symbol interned in CL-USER
;;;      via (intern name (find-package :common-lisp-user)) with the
;;;      %DSMR-MCP-ATTACH-REG- prefix. This prevents the IO-package from
;;;      qualifying them with the dispatcher's package name, which the remote
;;;      reader cannot resolve.
;;;   2. Use do/do* (NOT loop) for any looping inside injected forms.
;;;      loop keywords are not CL symbols; they print as CL-USER::FOR etc.
;;;      under the IO-package and the remote reader fails on them.
;;;   3. The form is pure ANSI — no SBCL-specific symbols, no MOP, no jzon.

(defun build-registry-ensure-form ()
  "Return the idempotent sexp to prepend to every repl-eval wrap-form.
When evaluated in the attached image, installs the DSMR-MCP-ATTACH-REGISTRY
package (if absent) with three interned specials:
  *REGISTRY-TABLE*  — equal hash-table mapping integer id → entry plist
  *NEXT-ID*         — monotonic integer counter (starts at 0)
  *REGISTRY-LOCK*   — bordeaux-threads lock, or NIL when bt is unavailable

A second evaluation is a no-op (idempotent via find-package guard).
All symbols in the returned form are CL standard or CL-USER-interned with
the %DSMR-MCP-ATTACH-REG- prefix (Critical Constraint 1 above)."
  (flet ((cl-user-sym (name)
           (intern name (find-package :common-lisp-user))))
    (let ((s-pkg  (cl-user-sym "%DSMR-MCP-ATTACH-REG-PKG")))
      `(unless (find-package "DSMR-MCP-ATTACH-REGISTRY")
         (let ((,s-pkg (make-package "DSMR-MCP-ATTACH-REGISTRY" :use nil)))
           (setf (symbol-value (intern "*REGISTRY-TABLE*" ,s-pkg))
                 (make-hash-table :test 'eql))
           (setf (symbol-value (intern "*NEXT-ID*" ,s-pkg)) 0)
           (setf (symbol-value (intern "*REGISTRY-LOCK*" ,s-pkg))
                 #+bordeaux-threads
                 (bordeaux-threads:make-lock "dsmr-attach-registry")
                 #-bordeaux-threads nil))))))

(defun build-register-result-form (value-form session-id)
  "Return the sexp that, when evaluated in the attached image, registers the
value of VALUE-FORM in the DSMR-MCP-ATTACH-REGISTRY table and returns the
raw integer ID, or NIL when the value is a primitive (not inspectable).

VALUE-FORM is the sexp that evaluates to the value to register.
SESSION-ID is a string embedded literally as the ownership tag.

The inspectable-p check is inlined (numberp/stringp/symbolp/characterp) so
the remote image does not call back to the dispatcher's inspectable-p.
The registration acquires *REGISTRY-LOCK* (or skips locking when NIL, i.e.,
when bordeaux-threads is absent in the attached image)."
  (flet ((cl-user-sym (name)
           (intern name (find-package :common-lisp-user))))
    (let ((s-val  (cl-user-sym "%DSMR-MCP-ATTACH-REG-VAL"))
          (s-tbl  (cl-user-sym "%DSMR-MCP-ATTACH-REG-TBL"))
          (s-lock (cl-user-sym "%DSMR-MCP-ATTACH-REG-LCK"))
          (s-ctr  (cl-user-sym "%DSMR-MCP-ATTACH-REG-CTR"))
          (s-id   (cl-user-sym "%DSMR-MCP-ATTACH-REG-ID")))
      `(let* ((,s-val  ,value-form)
              (,s-tbl  (symbol-value
                        (intern "*REGISTRY-TABLE*" "DSMR-MCP-ATTACH-REGISTRY")))
              (,s-lock (symbol-value
                        (intern "*REGISTRY-LOCK*" "DSMR-MCP-ATTACH-REGISTRY")))
              (,s-ctr  (intern "*NEXT-ID*" "DSMR-MCP-ATTACH-REGISTRY")))
         (when (and ,s-val
                    (not (numberp ,s-val))
                    (not (stringp ,s-val))
                    (not (symbolp ,s-val))
                    (not (characterp ,s-val)))
           (if ,s-lock
               (bordeaux-threads:with-lock-held (,s-lock)
                 (let ((,s-id (incf (symbol-value ,s-ctr))))
                   (setf (gethash ,s-id ,s-tbl)
                         (list :object ,s-val :session ,session-id))
                   ,s-id))
               (let ((,s-id (incf (symbol-value ,s-ctr))))
                 (setf (gethash ,s-id ,s-tbl)
                       (list :object ,s-val :session ,session-id))
                 ,s-id)))))))

(defun build-lookup-form (raw-id session-id)
  "Return the sexp that, when evaluated in the attached image, looks up RAW-ID
in the DSMR-MCP-ATTACH-REGISTRY table and returns:
  - :FOUND when the entry exists and the stored :session equals SESSION-ID
  - :OBJECT-NOT-FOUND on id miss or session-id mismatch

RAW-ID is an integer; SESSION-ID is a string — both embedded literally.
Returns the keyword :FOUND (not the live object) so the result is readable
across the slime-eval wire.  Used by the session-isolation test and by
the dispatcher's lookup validation step.  The inspect-object path uses a
different form that holds the object locally in the image and calls
slynk::inspect-object on it, returning the readable istate plist."
  (flet ((cl-user-sym (name)
           (intern name (find-package :common-lisp-user))))
    (let ((s-tbl   (cl-user-sym "%DSMR-MCP-ATTACH-REG-LU-TBL"))
          (s-entry (cl-user-sym "%DSMR-MCP-ATTACH-REG-LU-ENTRY")))
      `(let* ((,s-tbl   (symbol-value
                          (intern "*REGISTRY-TABLE*" "DSMR-MCP-ATTACH-REGISTRY")))
               (,s-entry (gethash ,raw-id ,s-tbl)))
         (if (and ,s-entry (string= (getf ,s-entry :session) ,session-id))
             :found
             :object-not-found)))))
