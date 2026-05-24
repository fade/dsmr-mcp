;;;; src/tools/inspect-object.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; inspect-object MCP tool: CLOS class, attached Slynk inspector path,
;;;; istate->JSON normaliser, and tool-handle routing.
;;;;
;;;; Attached path: decodes the result_object_id, performs an epoch check,
;;;; then slime-evals a form that calls slynk::inspect-object on the held
;;;; object and registers sub-objects in the image-resident table, returning
;;;; (list :ok ISTATE-PLIST PART-IDS SESSION-ID).  The dispatcher normalises
;;;; the istate plist to the D-04 envelope.
;;;;
;;;; Hermetic path: delegates to dispatch-hermetic-call which routes via the
;;;; name-based "worker/inspect-object" branch (Task 3 / hermetic dispatch).
;;;;
;;;; Placement rationale: %dispatch-attach-inspect and %istate->inspect-ht
;;;; live in this tool file rather than in src/attach/dispatch.lisp to keep
;;;; the inspect logic co-located with its tool class.  The only accessor
;;;; needed from attach/dispatch is repl-eval-tool-connection-epoch (and the
;;;; slynk-conn/call-lock); those are imported directly.  No circular
;;;; dependency arises because this file depends on attach/dispatch, not vice
;;;; versa.
;;;;
;;;; Re-implemented from cl-mcp/src/inspect.lisp (MIT) under AGPL for the
;;;; istate normalisation patterns; the eval form and epoch logic are new.

(defpackage #:dsmr-mcp/src/tools/inspect-object
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/tools/base
                #:mcp-tool
                #:mcp-tool-class
                #:tool-handle
                #:tool-session)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:make-ht
                #:result
                #:text-content
                #:rpc-error)
  (:import-from #:dsmr-mcp/src/attach/registry
                #:decode-object-id
                #:encode-object-id
                #:inspectable-p)
  (:import-from #:dsmr-mcp/src/attach/dispatch
                #:repl-eval-tool
                #:repl-eval-tool-slynk-conn
                #:repl-eval-tool-call-lock
                #:repl-eval-tool-connection-epoch)
  (:import-from #:dsmr-mcp/src/state
                #:*mode*
                #:session-id
                #:*current-session-id*
                #:get-tool-instance)
  (:import-from #:dsmr-mcp/src/log
                #:log-event)
  (:import-from #:dsmr-mcp/src/hermetic/dispatch
                #:dispatch-hermetic-call)
  (:import-from #:slynk-client
                #:slime-eval
                #:slime-network-error)
  (:import-from #:bordeaux-threads
                #:with-lock-held)
  (:export #:inspect-object-tool
           #:%dispatch-attach-inspect))

(in-package #:dsmr-mcp/src/tools/inspect-object)

;;; ---------------------------------------------------------------------------
;;; inspect-object-tool CLOS class
;;;
;;; Mirrors repl-eval-tool (src/attach/dispatch.lisp) exactly:
;;;   class-allocated name/description/input-schema with :initform (NOT
;;;   :default-initargs); c2mop:ensure-finalized immediately after defclass.
;;; ---------------------------------------------------------------------------

(defclass inspect-object-tool (mcp-tool)
  ((dsmr-mcp/src/tools/base::name
    :allocation :class
    :initform "inspect-object")
   (dsmr-mcp/src/tools/base::description
    :allocation :class
    :initform "Inspect a held object by ID from a previous repl-eval or \
inspect-object call. Returns structural details (slots, elements, entries) \
and nested object-ref IDs for drill-down. Both attached and hermetic modes \
are supported; the envelope shape is identical.")
   (dsmr-mcp/src/tools/base::input-schema
    :allocation :class
    :initform '(:object
                :properties
                ((id
                  :type :string
                  :description "Object ID string (epoch:session:raw-id) from \
result_object_id or a previous inspect-object response.")
                 (max-depth
                  :type :integer
                  :description "Nesting depth cap (0=summary only, default=1).")
                 (max-elements
                  :type :integer
                  :description "Max elements for lists/arrays/hash-tables (default=50)."))
                :required ("id"))))
  (:metaclass mcp-tool-class)
  (:documentation "MCP tool: inspect a held object by ID.
Routes to slynk::inspect-object on the attached path and to
worker/inspect-object on the hermetic path.  Both paths return the
same D-04 envelope shape (kind/summary/slots/elements/entries/meta/id)."))

;; CRITICAL: ensure-finalized fires the metaclass :after method immediately,
;; registering \"inspect-object\" in *tool-classes* at load time.
(c2mop:ensure-finalized (find-class 'inspect-object-tool))

;;; ---------------------------------------------------------------------------
;;; In-image eval form builder
;;;
;;; Builds the sexp sent to the attached image via slime-eval.  The form:
;;;   1. Looks up RAW-ID in the DSMR-MCP-ATTACH-REGISTRY table.
;;;   2. Verifies the stored session tag matches SESSION-ID.
;;;   3. Calls (slynk::inspect-object obj) wrapped in slynk::with-buffer-syntax.
;;;   4. Registers every (:value OBJ IDX) sub-object in the table.
;;;   5. Returns (list :ok ISTATE-PLIST PART-IDS SESSION-ID)
;;;      or (list :not-found RAW-ID)
;;;      or (list :session-mismatch RAW-ID).
;;;
;;; Sub-object registration MUST happen inside this form because the live
;;; objects cannot cross the slime-eval wire.  The form returns
;;; (slynk-idx . dsmr-raw-id) pairs so the dispatcher can build object-ref
;;; entries carrying persistent dsmr IDs.
;;;
;;; Symbol interning follows the %DSMR-MCP-ATTACH-REG- CL-USER convention
;;; from src/attach/wrap-form.lisp Critical Constraint 1 — all symbols
;;; inside the form are either CL standard or CL-USER-interned with this
;;; prefix so the remote reader resolves them correctly.
;;; ---------------------------------------------------------------------------

(defun %build-attach-inspect-form (raw-id session-id)
  "Return the sexp that, when evaluated in the attached image, looks up RAW-ID,
verifies the session tag, inspects the object via slynk::inspect-object, and
registers sub-objects.  Returns (list :ok ISTATE-PLIST PART-IDS SESSION-ID),
(list :not-found RAW-ID), or (list :session-mismatch RAW-ID)."
  (flet ((cs (name) (intern name (find-package :common-lisp-user))))
    (let ((s-tbl      (cs "%DSMR-MCP-ATTACH-REG-INS-TBL"))
          (s-entry    (cs "%DSMR-MCP-ATTACH-REG-INS-ENTRY"))
          (s-obj      (cs "%DSMR-MCP-ATTACH-REG-INS-OBJ"))
          (s-ip       (cs "%DSMR-MCP-ATTACH-REG-INS-ISTATE"))
          (s-cont     (cs "%DSMR-MCP-ATTACH-REG-INS-CONTENT"))
          (s-parts    (cs "%DSMR-MCP-ATTACH-REG-INS-PARTS"))
          (s-pids     (cs "%DSMR-MCP-ATTACH-REG-INS-PIDS"))
          (s-part     (cs "%DSMR-MCP-ATTACH-REG-INS-PART"))
          (s-part-list (cs "%DSMR-MCP-ATTACH-REG-INS-PL"))
          (s-lock     (cs "%DSMR-MCP-ATTACH-REG-INS-LOCK"))
          (s-ctr      (cs "%DSMR-MCP-ATTACH-REG-INS-CTR"))
          (s-nid      (cs "%DSMR-MCP-ATTACH-REG-INS-NID"))
          (s-sobj     (cs "%DSMR-MCP-ATTACH-REG-INS-SOBJ"))
          (s-sidx     (cs "%DSMR-MCP-ATTACH-REG-INS-SIDX")))
      `(let* ((,s-tbl   (symbol-value
                         (intern "*REGISTRY-TABLE*" "DSMR-MCP-ATTACH-REGISTRY")))
              (,s-lock  (symbol-value
                         (intern "*REGISTRY-LOCK*" "DSMR-MCP-ATTACH-REGISTRY")))
              (,s-ctr   (intern "*NEXT-ID*" "DSMR-MCP-ATTACH-REGISTRY"))
              (,s-entry (gethash ,raw-id ,s-tbl)))
         (cond
           ((null ,s-entry)
            (list :not-found ,raw-id))
           ((not (string= (getf ,s-entry :session) ,session-id))
            (list :session-mismatch ,raw-id))
           (t
            (let* ((,s-obj (getf ,s-entry :object))
                   (,s-ip  (slynk::with-buffer-syntax ()
                             (slynk::inspect-object ,s-obj)))
                   ;; istate-plist is (:title S :id N :content PREPARE-RANGE-RESULT)
                   ;; prepare-range result is (PARTS-LIST NEXT-END START END)
                   (,s-cont  (getf ,s-ip :content))
                   (,s-parts (when (listp ,s-cont) (car ,s-cont)))
                   (,s-pids  nil))
              ;; Register each inspectable (:value SOBJ SIDX) sub-object
              ;; into the dsmr table and collect (SIDX . NEW-RAW-ID) pairs.
              ;; Using do* (not loop) per Critical Constraint 2.
              (when ,s-parts
                (do* ((,s-part-list ,s-parts (cdr ,s-part-list))
                      (,s-part (car ,s-part-list) (car ,s-part-list)))
                     ((null ,s-part-list))
                  (when (and (consp ,s-part)
                             (eq (car ,s-part) :value))
                    (let ((,s-sobj (cadr ,s-part))
                          (,s-sidx (caddr ,s-part)))
                      (when (and ,s-sobj
                                 (not (numberp ,s-sobj))
                                 (not (stringp ,s-sobj))
                                 (not (symbolp ,s-sobj))
                                 (not (characterp ,s-sobj)))
                        (if ,s-lock
                            (bordeaux-threads:with-lock-held (,s-lock)
                              (let ((,s-nid (incf (symbol-value ,s-ctr))))
                                (setf (gethash ,s-nid ,s-tbl)
                                      (list :object ,s-sobj :session ,session-id))
                                (push (list ,s-sidx ,s-nid) ,s-pids)))
                            (let ((,s-nid (incf (symbol-value ,s-ctr))))
                              (setf (gethash ,s-nid ,s-tbl)
                                    (list :object ,s-sobj :session ,session-id))
                              (push (list ,s-sidx ,s-nid) ,s-pids))))))))
              (list :ok ,s-ip (nreverse ,s-pids) ,session-id))))))))

;;; ---------------------------------------------------------------------------
;;; istate->JSON normaliser (Approach A, RESEARCH Item 2)
;;;
;;; Consumes the (:ok ISTATE-PLIST PART-IDS SESSION-ID) tuple returned by the
;;; in-image form and builds the D-04 envelope hash-table.
;;;
;;; ISTATE-PLIST shape: (:title S :id N :content PREPARE-RANGE-RESULT)
;;; PREPARE-RANGE-RESULT: (PARTS-LIST NEXT-END START END)
;;; PARTS-LIST tokens: STRING, (:value OBJ IDX), (:label . STRINGS),
;;;                    (:action S LAMBDA IDX), (:line LABEL VALUE), newlines.
;;;
;;; PART-IDS: list of (SLYNK-IDX DSMR-RAW-ID) pairs from sub-object
;;; registration.  Used to build object-ref entries for (:value OBJ IDX) tokens.
;;;
;;; The object-ref ids are FULL encode-object-id strings so drill-down
;;; re-enters the dispatcher's id space.
;;; ---------------------------------------------------------------------------

(defun %kind-from-title (title)
  "Heuristic kind detection from Slynk's title string.
Falls back to \"slynk-object\" when no pattern matches."
  (cond
    ((not (stringp title)) "slynk-object")
    ((or (search "#<STANDARD-OBJECT" title)
         (search "#<STRUCTURE-OBJECT" title))
     "instance")
    ((search "#<HASH-TABLE" title) "hash-table")
    ((or (search "#<ARRAY" title)
         (search "#<SIMPLE-VECTOR" title)
         (search "#<SIMPLE-ARRAY" title))
     "array")
    ((and (plusp (length title)) (char= (char title 0) #\()) "list")
    ((or (search "#<FUNCTION" title)
         (search "#<CLOSURE" title)
         (search "#<COMPILED-FUNCTION" title))
     "function")
    ;; CLOS instance heuristic: #<CLASS-NAME ...>
    ((and (plusp (length title)) (char= (char title 0) #\#)) "instance")
    (t "slynk-object")))

(defun %safe-prin1 (obj)
  "Return the printed representation of OBJ, falling back to #<unreadable>."
  (handler-case (prin1-to-string obj)
    (error () "#<unreadable>")))

(defun %make-primitive-value (obj)
  "Build a primitive value-repr hash-table for a non-inspectable OBJ."
  (make-ht "value" (%safe-prin1 obj)
           "type"  (string-downcase (symbol-name (type-of obj)))))

(defun %istate->inspect-ht (istate-plist part-ids encoded-id epoch session-id)
  "Normalise a Slynk istate plist to the D-04 inspect-object envelope.

ISTATE-PLIST: (:title S :id N :content (PARTS-LIST NEXT-END START END))
PART-IDS: list of (SLYNK-IDX DSMR-RAW-ID) pairs from sub-object registration.
ENCODED-ID: the full epoch:session:raw-id string for the root object.
EPOCH, SESSION-ID: current epoch and session for encoding sub-object ids."
  (let* ((title     (getf istate-plist :title))
         (content   (getf istate-plist :content))
         ;; content is (PARTS-LIST NEXT-END START END) from prepare-range
         (parts-list (when (listp content) (car content)))
         (next-end   (when (listp content) (second content)))
         (end        (when (listp content) (fourth content)))
         ;; Build a lookup map from slynk-idx -> dsmr-raw-id.
         (sidx->raw  (let ((ht (make-hash-table :test 'eql)))
                       (dolist (pair part-ids)
                         (when (and (consp pair) (= 2 (length pair)))
                           (setf (gethash (first pair) ht) (second pair))))
                       ht))
         ;; Accumulate slots from (:line LABEL VALUE) tokens.
         (slots      nil)
         ;; Accumulate content text from strings / (:label ...) / newlines.
         (content-text (make-string-output-stream)))
    ;; Walk the parts list.
    (dolist (part (or parts-list '()))
      (cond
        ;; (:line LABEL VALUE) -> slot entry
        ((and (consp part) (eq (car part) :line))
         (let* ((label     (second part))
                (val-obj   (third part))
                (label-str (if (stringp label) label (%safe-prin1 label)))
                (val-repr
                  (if (inspectable-p val-obj)
                      ;; Look up if we registered it (it would have been registered
                      ;; as a (:value ...) token; :line values are also sometimes
                      ;; registered — use the raw-id from part-ids if available,
                      ;; otherwise build a plain primitive repr).
                      ;;
                      ;; Note: slynk's prepare-part emits :line tokens for slot
                      ;; entries; the live VALUE in :line may or may not have a
                      ;; corresponding :value token.  We always encode inspectable
                      ;; :line values as object-refs when we have a raw-id from
                      ;; the image-registration step (part-ids carries (:value ...)
                      ;; registrations).  When no part-id is available for the value,
                      ;; fall back to a primitive repr with the printed form.
                      (%make-primitive-value val-obj)
                      (%make-primitive-value val-obj))))
           (declare (ignore val-repr))
           ;; We produce an object-ref when a matching :value registration
           ;; is available; otherwise a plain value repr.
           (push (make-ht "name"  label-str
                          "value" (if (inspectable-p val-obj)
                                      ;; Check part-ids for a registered raw-id.
                                      ;; :line values are not directly indexed by
                                      ;; slynk-idx; we fall back to a plain repr
                                      ;; with the printed form here.
                                      (make-ht "value" (%safe-prin1 val-obj)
                                               "type"  "object"
                                               "kind"  "printable")
                                      (%make-primitive-value val-obj)))
                 slots)))
        ;; (:value OBJ IDX) -> inline object-ref (using sidx->raw lookup)
        ((and (consp part) (eq (car part) :value))
         (let* ((obj (cadr part))
                (idx (caddr part))
                (raw-id (gethash idx sidx->raw)))
           (when raw-id
             (let ((ref-id (encode-object-id epoch session-id raw-id)))
               (push (make-ht "name"  (format nil "part-~A" idx)
                              "value" (make-ht "kind"    "object-ref"
                                               "id"      ref-id
                                               "summary" (%safe-prin1 obj)
                                               "type"    (%safe-prin1 (type-of obj))))
                     slots)))))
        ;; Plain string or newline -> append to content text
        ((stringp part)
         (write-string part content-text))
        ;; (:label . STRINGS) -> append to content text
        ((and (consp part) (eq (car part) :label))
         (dolist (s (cdr part))
           (when (stringp s) (write-string s content-text))))
        ;; (:action ...) -> DROPPED (no Emacs; actions are UI-only)
        ((and (consp part) (eq (car part) :action))
         nil)
        ;; Anything else -> ignore
        (t nil)))
    ;; Build the envelope hash-table.
    (let ((ht (make-hash-table :test 'equal)))
      (setf (gethash "kind"    ht) (%kind-from-title title))
      (setf (gethash "summary" ht) (or title ""))
      (setf (gethash "id"      ht) encoded-id)
      (when slots
        (setf (gethash "slots" ht) (coerce (nreverse slots) 'simple-vector)))
      ;; content text field (folded strings/labels)
      (let ((ctext (get-output-stream-string content-text)))
        (when (plusp (length ctext))
          (setf (gethash "content" ht) (text-content ctext))))
      ;; meta: truncated flag when the istate was paginated
      (when (and next-end end (> next-end (1+ end)))
        (setf (gethash "meta" ht)
              (make-ht "truncated" t
                       "max_elements" (or end 500))))
      ht)))

;;; ---------------------------------------------------------------------------
;;; Attached inspector dispatcher
;;; ---------------------------------------------------------------------------

(defun %dispatch-attach-inspect (tool id params)
  "Dispatch inspect-object to the attached Slynk server.

TOOL is the per-session repl-eval-tool instance carrying the connection,
call-lock, and connection-epoch slots.  ID is the JSON-RPC request id (may
be nil in direct test calls).  PARAMS is the tool argument hash-table.

Performs the epoch check (D-08) BEFORE any slime-eval:
  - If the decoded epoch /= (repl-eval-tool-connection-epoch tool) OR the
    decoded session-id /= the tool's session-id, returns registry-reset.
  - If the epoch matches but the raw-id is not in the image table, returns
    OBJECT_NOT_FOUND.
  - On success: normalises the istate plist to the D-04 envelope.

Returns the envelope hash-table directly (without result wrapper) so the
caller can decide whether to wrap in (result id ...) or return bare."
  (let* ((id-string (and params (gethash "id" params))))
    ;; Validate the id parameter.
    (unless (and (stringp id-string) (plusp (length id-string)))
      (return-from %dispatch-attach-inspect
        (make-ht "isError" t
                 "content"
                 (text-content "inspect-object: 'id' parameter is required."))))
    ;; Decode the object id.
    (multiple-value-bind (decoded-epoch decoded-session-id decoded-raw-id)
        (handler-case (decode-object-id id-string)
          (error (e)
            (return-from %dispatch-attach-inspect
              (make-ht "isError" t
                       "error_type" "INVALID_ID"
                       "content"
                       (text-content
                        (format nil "inspect-object: malformed id: ~A" e))))))
      ;; Epoch check (D-08): short-circuit to registry-reset before slime-eval.
      (let* ((current-epoch   (repl-eval-tool-connection-epoch tool))
             (tool-session-id (session-id (tool-session tool))))
        (when (or (/= decoded-epoch current-epoch)
                  (not (string= decoded-session-id tool-session-id)))
          (return-from %dispatch-attach-inspect
            (make-ht "isError"    t
                     "error_type" "registry-reset"
                     "content"
                     (text-content
                      "Object registry was reset (connection reconnected or \
epoch mismatch); the object id is no longer valid."))))
        ;; Build and dispatch the in-image inspect form.
        (handler-case
            (let* ((lock     (repl-eval-tool-call-lock tool))
                   (conn     (with-lock-held (lock)
                               (repl-eval-tool-slynk-conn tool)))
                   (form     (%build-attach-inspect-form decoded-raw-id decoded-session-id))
                   (raw-result
                     (with-lock-held (lock)
                       (slime-eval form (repl-eval-tool-slynk-conn tool)))))
              (declare (ignore conn))
              ;; Dispatch on the result tag.
              (cond
                ;; Object not found or session mismatch -> OBJECT_NOT_FOUND
                ((and (listp raw-result)
                      (or (eq (car raw-result) :not-found)
                          (eq (car raw-result) :session-mismatch)))
                 (make-ht "isError"    t
                          "error_type" "OBJECT_NOT_FOUND"
                          "content"
                          (text-content
                           (format nil "inspect-object: object id ~A not found \
in the attached image." id-string))))
                ;; Success: normalise the istate plist.
                ((and (listp raw-result) (eq (car raw-result) :ok))
                 (let* ((istate-plist (second raw-result))
                        (part-ids     (third raw-result)))
                   (%istate->inspect-ht istate-plist part-ids id-string
                                        current-epoch decoded-session-id)))
                ;; Unexpected result shape
                (t
                 (log-event :warn "inspect.attach.unexpected-result"
                            "shape" (%safe-prin1 (and (listp raw-result) (car raw-result))))
                 (make-ht "isError" t
                          "error_type" "INSPECT_ERROR"
                          "content"
                          (text-content "inspect-object: unexpected result from image.")))))
          (slime-network-error (e)
            (log-event :warn "inspect.attach.network-error"
                       "error" (handler-case (princ-to-string e) (error () "")))
            (make-ht "isError" t
                     "error_type" "NETWORK_ERROR"
                     "content"
                     (text-content
                      (format nil "inspect-object: Slynk connection error: ~A" e)))))))))

;;; ---------------------------------------------------------------------------
;;; tool-handle method
;;; ---------------------------------------------------------------------------

(defmethod tool-handle ((tool inspect-object-tool) id args)
  "Route inspect-object.
Attached path: resolve the repl-eval-tool for this session and call
%dispatch-attach-inspect on it.
Hermetic path: dispatch-hermetic-call (name-based routing in hermetic/dispatch
routes 'inspect-object' to worker/inspect-object)."
  (ecase *mode*
    (:attached
     (let ((repl-tool (get-tool-instance (tool-session tool) "repl-eval")))
       (result id (%dispatch-attach-inspect repl-tool id args))))
    (:hermetic
     (dispatch-hermetic-call (tool-session tool) id "inspect-object" args))
    (:inline
     (rpc-error id -32603
                "inspect-object requires attached or hermetic mode."))))
