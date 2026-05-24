;;;; src/hermetic/worker/inspect.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Hermetic worker object walker and inspect-object-by-id.
;;;; Ported from cl-mcp/src/inspect.lisp (MIT) under AGPL.
;;;;
;;;; This file runs inside dsmr-mcp's own SBCL worker process, so SBCL-specific
;;;; introspection (SB-MOP, SB-KERNEL, SB-INTROSPECT) is permitted throughout.
;;;; The walker is structurally identical to cl-mcp's, adapted to:
;;;;   - use an explicit registry argument (no global *object-registry*)
;;;;   - inline safe-prin1 as a local helper (no cl-mcp utils dependency)
;;;;   - import make-ht and text-content from dsmr-mcp/src/tools/helpers
;;;;   - export build-inspect-response (defined here, not in a separate file)
;;;;   - omit define-tool and with-proxy-dispatch (handled in 05-03)
;;;;
;;;; Thread safety: all registry mutations acquire the registry's lock via
;;;; register-object / lookup-object in registry.lisp.

(defpackage #:dsmr-mcp/src/hermetic/worker/inspect
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/hermetic/worker/registry
                #:inspectable-p
                #:register-object
                #:lookup-object)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:make-ht
                #:text-content)
  (:export #:inspect-object-by-id
           #:generate-result-preview
           #:build-inspect-response
           #:format-inspect-elements))

(in-package #:dsmr-mcp/src/hermetic/worker/inspect)

;;; ---------------------------------------------------------------------------
;;; Local helpers
;;; ---------------------------------------------------------------------------

(defun %safe-prin1 (obj)
  "Return the printed representation of OBJ, falling back to a placeholder
on any error (e.g., when a custom print-object method signals)."
  (handler-case (prin1-to-string obj)
    (error () "#<unreadable>")))

(defun %type-name (object)
  "Return the type name of OBJECT as a string."
  (let ((type (type-of object)))
    (if (consp type)
        (symbol-name (car type))
        (symbol-name type))))

;;; ---------------------------------------------------------------------------
;;; Primitive and object-ref representations
;;; ---------------------------------------------------------------------------

(defun %primitive-value-repr (object)
  "Return a hash-table representation of a primitive value."
  (cond
    ((numberp object)
     (make-ht "value" object "type" (%type-name object)))
    ((stringp object)
     (make-ht "value" object "type" (%type-name object)))
    ((characterp object)
     (make-ht "value" (string object) "type" "CHARACTER"))
    ((symbolp object)
     (let ((ht (make-ht "value" (symbol-name object) "type" "SYMBOL")))
       (when (symbol-package object)
         (setf (gethash "package" ht) (package-name (symbol-package object))))
       ht))
    (t
     (make-ht "value" (%safe-prin1 object) "type" (%type-name object)))))

(defun %ensure-object-id (object seen-table registry)
  "Return OBJECT's ID from SEEN-TABLE, registering it in REGISTRY if needed."
  (or (gethash object seen-table)
      (let ((id (register-object object registry)))
        (setf (gethash object seen-table) id)
        id)))

(defun %make-object-ref (object seen-table registry &key circular-p)
  "Return a reference hash-table for OBJECT.
When CIRCULAR-P is true, returns a circular-ref marker."
  (let ((id (%ensure-object-id object seen-table registry)))
    (if circular-p
        (make-ht "kind"    "circular-ref"
                 "ref_id"  id
                 "summary" (format nil "<circular to #~A>" id))
        (make-ht "kind"    "object-ref"
                 "id"      id
                 "summary" (%safe-prin1 object)
                 "type"    (%type-name object)))))

(defun %value-repr (object seen-table active-table registry depth max-depth max-elements)
  "Return a representation of OBJECT, registering it if inspectable.
Detects true cycles via ACTIVE-TABLE and shared refs via SEEN-TABLE."
  (if (inspectable-p object)
      (let ((child-depth (1+ depth)))
        (cond
          ((gethash object active-table)
           (%make-object-ref object seen-table registry :circular-p t))
          ((>= child-depth max-depth)
           (%make-object-ref object seen-table registry))
          ((gethash object seen-table)
           (%make-object-ref object seen-table registry))
          (t
           (%ensure-object-id object seen-table registry)
           (%inspect-object-impl object seen-table active-table registry
                                 child-depth max-depth max-elements))))
      (%primitive-value-repr object)))

;;; ---------------------------------------------------------------------------
;;; Type-specific walkers
;;; ---------------------------------------------------------------------------

(defun %inspect-cons (object seen-table active-table registry depth max-depth max-elements)
  "Inspect a cons/list. Detects circular CDR chains."
  (let ((elements nil)
        (count    0)
        (truncated nil)
        (current  object)
        (cdr-seen (make-hash-table :test #'eq)))
    (setf (gethash object cdr-seen) t)
    (loop while (consp current)
          do (if (>= count max-elements)
                 (progn (setf truncated t) (return))
                 (progn
                   (push (%value-repr (car current) seen-table active-table registry
                                      depth max-depth max-elements)
                         elements)
                   (incf count)
                   (setf current (cdr current))
                   (when (and (consp current) (gethash current cdr-seen))
                     (setf truncated t)
                     (return))
                   (when (consp current)
                     (setf (gethash current cdr-seen) t)))))
    (when (and current (not truncated))
      (push (make-ht "kind"  "dotted-tail"
                     "value" (%value-repr current seen-table active-table registry
                                          depth max-depth max-elements))
            elements))
    (let ((ht (make-ht "kind"     "list"
                       "summary"  (%safe-prin1 object)
                       "elements" (nreverse elements))))
      (setf (gethash "meta" ht)
            (make-ht "length"       (if truncated
                                        (format nil ">~A" max-elements)
                                        count)
                     "truncated"    truncated
                     "max_elements" max-elements))
      ht)))

(defun %inspect-vector (object seen-table active-table registry depth max-depth max-elements)
  "Inspect a 1-dimensional array (vector)."
  (let* ((len      (length object))
         (limit    (min len max-elements))
         (elements (loop for i from 0 below limit
                         collect (%value-repr (aref object i) seen-table active-table
                                              registry depth max-depth max-elements)))
         (truncated (> len max-elements)))
    (let ((ht (make-ht "kind"         "array"
                       "summary"      (%safe-prin1 object)
                       "element_type" (let ((et (array-element-type object)))
                                        (if (eq et t) "T" (prin1-to-string et)))
                       "dimensions"   (list len)
                       "elements"     elements)))
      (setf (gethash "meta" ht)
            (make-ht "total_elements" len
                     "truncated"      truncated
                     "max_elements"   max-elements))
      ht)))

(defun %inspect-array (object seen-table active-table registry depth max-depth max-elements)
  "Inspect a multi-dimensional array."
  (let* ((dims      (array-dimensions object))
         (total     (array-total-size object))
         (limit     (min total max-elements))
         (elements  (loop for i from 0 below limit
                          collect (%value-repr (row-major-aref object i)
                                               seen-table active-table registry
                                               depth max-depth max-elements)))
         (truncated (> total max-elements)))
    (let ((ht (make-ht "kind"         "array"
                       "summary"      (%safe-prin1 object)
                       "element_type" (let ((et (array-element-type object)))
                                        (if (eq et t) "T" (prin1-to-string et)))
                       "dimensions"   dims
                       "elements"     elements)))
      (setf (gethash "meta" ht)
            (make-ht "total_elements" total
                     "truncated"      truncated
                     "max_elements"   max-elements))
      ht)))

(defun %inspect-hash-table (object seen-table active-table registry depth max-depth max-elements)
  "Inspect a hash-table, producing an entries sequence."
  (let ((entries   '())
        (count     0)
        (truncated nil)
        (total     (hash-table-count object)))
    (block collect
      (maphash (lambda (k v)
                 (when (>= count max-elements)
                   (setf truncated t)
                   (return-from collect))
                 (push (make-ht "key"   (%value-repr k seen-table active-table registry
                                                      depth max-depth max-elements)
                                "value" (%value-repr v seen-table active-table registry
                                                      depth max-depth max-elements))
                       entries)
                 (incf count))
               object))
    (let ((ht (make-ht "kind"    "hash-table"
                       "summary" (%safe-prin1 object)
                       "test"    (symbol-name (hash-table-test object))
                       "entries" (nreverse entries))))
      (setf (gethash "meta" ht)
            (make-ht "count"        total
                     "truncated"    truncated
                     "max_elements" max-elements))
      ht)))

(defun %inspect-function (object)
  "Inspect a function, extracting name and lambda-list on SBCL."
  (let ((name nil)
        (lambda-list nil))
    #+sbcl
    (handler-case
        (let ((fun-name-fn     (find-symbol "%FUN-NAME"           "SB-KERNEL"))
              (introspect-pkg  (find-package "SB-INTROSPECT")))
          (when (and fun-name-fn (fboundp fun-name-fn))
            (setf name (funcall fun-name-fn object)))
          (when introspect-pkg
            (let ((lambda-list-fn (find-symbol "FUNCTION-LAMBDA-LIST" introspect-pkg)))
              (when (and lambda-list-fn (fboundp lambda-list-fn))
                (setf lambda-list (funcall lambda-list-fn object))))))
      (error () nil))
    (let ((ht (make-ht "kind"    "function"
                       "summary" (%safe-prin1 object))))
      (when name
        (setf (gethash "name"        ht) (%safe-prin1 name)))
      (when lambda-list
        (setf (gethash "lambda_list" ht) (%safe-prin1 lambda-list)))
      ht)))

#+sbcl
(defun %sbcl-structure-p (object)
  "Return T if OBJECT is an SBCL structure-class instance, not a standard-object."
  (and (not (typep object 'standard-object))
       (typep (class-of object) 'structure-class)))

(defun %inspect-structure (object seen-table active-table registry depth max-depth max-elements)
  "Inspect a structure using SBCL's kernel layout introspection."
  (let ((slots      '())
        (class-name (%type-name object)))
    #+sbcl
    (let ((layout-of-fn   (find-symbol "LAYOUT-OF"        "SB-KERNEL"))
          (dd-slots-fn    (find-symbol "DD-SLOTS"         "SB-KERNEL"))
          (dsd-name-fn    (find-symbol "DSD-NAME"         "SB-KERNEL"))
          (dsd-accessor-fn (find-symbol "DSD-ACCESSOR-NAME" "SB-KERNEL")))
      ;; Modern SBCL path: layout-of -> layout-info -> dd-slots.
      (handler-case
          (let ((layout-info-fn (find-symbol "LAYOUT-INFO" "SB-KERNEL")))
            (when (and layout-of-fn layout-info-fn dd-slots-fn
                       dsd-name-fn dsd-accessor-fn
                       (fboundp layout-of-fn) (fboundp layout-info-fn))
              (let* ((layout (funcall layout-of-fn object))
                     (dd     (funcall layout-info-fn layout)))
                (when dd
                  (dolist (dsd (funcall dd-slots-fn dd))
                    (let* ((slot-name (symbol-name (funcall dsd-name-fn dsd)))
                           (accessor  (funcall dsd-accessor-fn dsd))
                           (value     (handler-case (funcall accessor object)
                                        (error () :unbound))))
                      (push (make-ht "name"  slot-name
                                     "value" (if (eq value :unbound)
                                                 (make-ht "kind"    "unbound"
                                                          "summary" "#<unbound-slot>")
                                                 (%value-repr value seen-table active-table
                                                              registry depth max-depth
                                                              max-elements)))
                            slots)))))))
        (error () nil))
      ;; Legacy SBCL path: layout-of -> wrapper-info -> wrapper-dd -> dd-slots.
      (when (null slots)
        (handler-case
            (let ((wrapper-info-fn (find-symbol "WRAPPER-INFO" "SB-KERNEL"))
                  (wrapper-dd-fn   (find-symbol "WRAPPER-DD"   "SB-KERNEL")))
              (when (and wrapper-info-fn wrapper-dd-fn layout-of-fn
                         dd-slots-fn dsd-name-fn dsd-accessor-fn
                         (fboundp layout-of-fn) (fboundp wrapper-info-fn))
                (let ((layout (funcall wrapper-info-fn
                                       (funcall layout-of-fn object))))
                  (when layout
                    (let ((dd (funcall wrapper-dd-fn layout)))
                      (when dd
                        (dolist (dsd (funcall dd-slots-fn dd))
                          (let* ((slot-name (symbol-name (funcall dsd-name-fn dsd)))
                                 (accessor  (funcall dsd-accessor-fn dsd))
                                 (value     (handler-case (funcall accessor object)
                                              (error () :unbound))))
                            (push (make-ht "name"  slot-name
                                           "value" (if (eq value :unbound)
                                                       (make-ht "kind"    "unbound"
                                                                "summary" "#<unbound-slot>")
                                                       (%value-repr value seen-table
                                                                    active-table registry
                                                                    depth max-depth
                                                                    max-elements)))
                                  slots)))))))))
          (error () nil))))
    (let ((ht (make-ht "kind"    "structure"
                       "class"   class-name
                       "summary" (%safe-prin1 object)
                       "slots"   (nreverse slots))))
      (setf (gethash "meta" ht) (make-ht "slot_count" (length slots)))
      ht)))

(defun %inspect-instance (object seen-table active-table registry depth max-depth max-elements)
  "Inspect a CLOS standard-object using SB-MOP class-slots."
  (let ((slots      '())
        (class      (class-of object))
        (class-name (%type-name object)))
    #+sbcl
    (handler-case
        (let* ((mop-pkg          (find-package "SB-MOP"))
               (class-slots-fn   (when mop-pkg (find-symbol "CLASS-SLOTS"           mop-pkg)))
               (slot-def-name-fn (when mop-pkg (find-symbol "SLOT-DEFINITION-NAME"  mop-pkg))))
          (when (and class-slots-fn slot-def-name-fn
                     (fboundp class-slots-fn) (fboundp slot-def-name-fn))
            (dolist (slot (funcall class-slots-fn class))
              (let* ((slot-def-name (funcall slot-def-name-fn slot))
                     (slot-name     (symbol-name slot-def-name))
                     (bound-p       (slot-boundp object slot-def-name))
                     (value         (if bound-p
                                        (slot-value object slot-def-name)
                                        :unbound)))
                (push (make-ht "name"  slot-name
                               "value" (if (eq value :unbound)
                                           (make-ht "kind"    "unbound"
                                                    "summary" "#<unbound-slot>")
                                           (%value-repr value seen-table active-table
                                                        registry depth max-depth
                                                        max-elements)))
                      slots)))))
      (error () nil))
    #-sbcl
    (declare (ignore class))
    (let ((ht (make-ht "kind"    "instance"
                       "class"   class-name
                       "summary" (%safe-prin1 object)
                       "slots"   (nreverse slots))))
      (setf (gethash "meta" ht) (make-ht "slot_count" (length slots)))
      ht)))

;;; ---------------------------------------------------------------------------
;;; Dispatch
;;; ---------------------------------------------------------------------------

(defun %inspect-object-impl (object seen-table active-table registry depth max-depth max-elements)
  "Walk OBJECT recursively, dispatching to type-specific walkers."
  (setf (gethash object active-table) t)
  (unwind-protect
       (cond
         ((consp object)
          (%inspect-cons object seen-table active-table registry depth max-depth max-elements))
         ((and (arrayp object) (= 1 (array-rank object)))
          (%inspect-vector object seen-table active-table registry depth max-depth max-elements))
         ((arrayp object)
          (%inspect-array object seen-table active-table registry depth max-depth max-elements))
         ((hash-table-p object)
          (%inspect-hash-table object seen-table active-table registry depth max-depth max-elements))
         ((functionp object)
          (%inspect-function object))
         #+sbcl
         ((%sbcl-structure-p object)
          (%inspect-structure object seen-table active-table registry depth max-depth max-elements))
         ((typep object 'standard-object)
          (%inspect-instance object seen-table active-table registry depth max-depth max-elements))
         (t
          (make-ht "kind"    "other"
                   "summary" (%safe-prin1 object)
                   "type"    (%type-name object))))
    (remhash object active-table)))

;;; ---------------------------------------------------------------------------
;;; Public API
;;; ---------------------------------------------------------------------------

(defun inspect-object-by-id (id registry &key (max-depth 1) (max-elements 50))
  "Inspect the object registered under ID in REGISTRY.
Returns a hash-table in the cl-mcp envelope shape
  (kind / summary / slots|elements|entries / meta / id)
on success, or a hash-table with error=t and a typed code on failure:
  OBJECT_NOT_FOUND  — ID not in registry (never registered or evicted)
  INSPECTION_FAILED — ID was found but introspection signalled an error"
  (multiple-value-bind (object found-p)
      (lookup-object id registry)
    (if found-p
        (handler-case
            (let ((seen   (make-hash-table :test 'eq))
                  (active (make-hash-table :test 'eq))
                  (result nil))
              ;; Seed root ID so child references back to the root point to
              ;; the same caller-visible ID rather than registering a duplicate.
              (setf (gethash object seen) id)
              (setf result (%inspect-object-impl object seen active registry
                                                 0 max-depth max-elements))
              (setf (gethash "id" result) id)
              result)
          (serious-condition (e)
            (make-ht "error"   t
                     "code"    "INSPECTION_FAILED"
                     "message" (format nil
                                       "Cannot inspect object ID ~A: ~A ~
(object may have been garbage-collected)"
                                       id e))))
        (make-ht "error"   t
                 "code"    "OBJECT_NOT_FOUND"
                 "message" (format nil
                                   "Object ID ~A not found ~
(may have been evicted from cache)"
                                   id)))))

(defun generate-result-preview (object registry &key (max-depth 1) (max-elements 8))
  "Register OBJECT in REGISTRY and return a lightweight structural preview.
Unlike inspect-object-by-id this takes a raw object (not an ID) and registers
it, then walks shallowly. Suitable for embedding a preview in a repl-eval
response without an additional inspect-object round-trip."
  (let ((id     (register-object object registry))
        (seen   (make-hash-table :test 'eq))
        (active (make-hash-table :test 'eq))
        (result nil))
    (setf (gethash object seen) id)
    (setf result (%inspect-object-impl object seen active registry
                                       0 max-depth max-elements))
    (setf (gethash "id" result) id)
    result))

(defun format-inspect-elements (inspection-result)
  "Format structured inspection data as a human-readable text string.
Handles list elements, hash-table entries, and CLOS/structure slots.
Appends a truncation note when the meta hash-table indicates truncation."
  (flet ((%repr-text (repr)
           (if (hash-table-p repr)
               (let ((v (gethash "value" repr)))
                 (if (and v (not (hash-table-p v)))
                     (princ-to-string v)
                     (or (gethash "summary" repr) "?")))
               (princ-to-string repr))))
    (with-output-to-string (s)
      (format s "[~A] ~A"
              (gethash "kind"    inspection-result)
              (gethash "summary" inspection-result))
      (when (gethash "id" inspection-result)
        (format s "~&[object-id: ~A]" (gethash "id" inspection-result)))
      ;; List/array elements
      (let ((elements (gethash "elements" inspection-result)))
        (when (and elements (plusp (length elements)))
          (format s "~&Elements:")
          (loop for el in (coerce elements 'list)
                for i from 0
                do (if (hash-table-p el)
                       (format s "~&  [~D] ~A~@[ [object-id: ~A]~]"
                               i (%repr-text el) (gethash "id" el))
                       (format s "~&  [~D] ~A" i el)))))
      ;; Hash-table entries
      (let ((entries (gethash "entries" inspection-result)))
        (when (and entries (plusp (length entries)))
          (format s "~&Entries (~A test):"
                  (or (gethash "test" inspection-result) "EQL"))
          (loop for entry in (coerce entries 'list)
                do (when (hash-table-p entry)
                     (let ((k (gethash "key"   entry))
                           (v (gethash "value" entry)))
                       (format s "~&  ~A => ~A~@[ [object-id: ~A]~]"
                               (%repr-text k) (%repr-text v)
                               (when (hash-table-p v) (gethash "id" v))))))))
      ;; CLOS/structure slots
      (let ((slots (gethash "slots" inspection-result)))
        (when (and slots (plusp (length slots)))
          (format s "~&Slots:")
          (loop for slot in (coerce slots 'list)
                do (when (hash-table-p slot)
                     (let ((v (gethash "value" slot)))
                       (format s "~&  ~A: ~A~@[ [object-id: ~A]~]"
                               (gethash "name" slot "?")
                               (%repr-text v)
                               (when (hash-table-p v) (gethash "id" v))))))))
      ;; Truncation note
      (let ((meta (gethash "meta" inspection-result)))
        (when (and meta (hash-table-p meta) (gethash "truncated" meta))
          (let ((total (or (gethash "total_elements" meta)
                           (gethash "count"          meta)
                           (gethash "length"         meta))))
            (format s "~&  ... (truncated, ~A total)" total)))))))

(defun build-inspect-response (inspection-result)
  "Wrap INSPECTION-RESULT in the MCP tools/call response envelope.
When the result carries an error, returns {isError: true, content: [text]}.
Otherwise returns the inspection envelope with a content field containing
human-readable text produced by format-inspect-elements."
  (if (and (hash-table-p inspection-result)
           (gethash "error" inspection-result))
      (make-ht "isError" t
               "content" (text-content
                           (or (gethash "message" inspection-result) "inspection error")))
      (progn
        (setf (gethash "content" inspection-result)
              (text-content (format-inspect-elements inspection-result)))
        inspection-result)))
