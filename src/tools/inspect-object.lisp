;;;; src/tools/inspect-object.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; inspect-object MCP tool: CLOS class, attached Slynk inspector path,
;;;; istate->JSON normaliser, and tool-handle routing.
;;;;
;;;; Attached path: decodes the result_object_id, performs an epoch check,
;;;; then slime-evals a form that drives Slynk's native inspector on the held
;;;; object and registers the inspectable sub-objects it surfaces, returning
;;;; (list :ok ISTATE-PLIST PART-IDS SESSION-ID).  The dispatcher normalises
;;;; the istate plist to the canonical inspect envelope shared with the
;;;; hermetic worker path.
;;;;
;;;; Hermetic path: delegates to dispatch-hermetic-call, which routes by name
;;;; to the worker's inspect handler.
;;;;
;;;; Placement rationale: the attached-inspect helpers live in this tool file
;;;; rather than in src/attach/dispatch.lisp to keep the inspect logic
;;;; co-located with its tool class.  The accessors needed from attach/dispatch
;;;; (the connection, call-lock, and connection-epoch) are imported directly;
;;;; no circular dependency arises because this file depends on attach/dispatch,
;;;; not vice versa.
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
                #:attached-connection
                #:repl-eval-tool-call-lock
                #:repl-eval-tool-connection-epoch)
  (:import-from #:dsmr-mcp/src/attach/connection
                #:bounded-slime-eval)
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
                #:slime-network-error)
  (:import-from #:bordeaux-threads
                #:with-lock-held)
  (:export #:inspect-object-tool
           #:%dispatch-attach-inspect))

(in-package #:dsmr-mcp/src/tools/inspect-object)

;;; ---------------------------------------------------------------------------
;;; inspect-object-tool CLOS class
;;;
;;; Mirrors repl-eval-tool (src/attach/dispatch.lisp): class-allocated
;;; name/description/input-schema with :initform (NOT :default-initargs);
;;; c2mop:ensure-finalized immediately after defclass so the metaclass :after
;;; method registers the tool at load time.
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
Routes to Slynk's native inspector on the attached path and to the worker
inspect handler on the hermetic path.  Both paths return the same envelope
shape (kind/summary/slots/elements/entries/meta/id)."))

;; ensure-finalized fires the metaclass :after method immediately, registering
;; "inspect-object" in *tool-classes* at load time.
(c2mop:ensure-finalized (find-class 'inspect-object-tool))

;;; ---------------------------------------------------------------------------
;;; In-image eval form builder
;;;
;;; Builds the sexp sent to the attached image via slime-eval.  The form:
;;;   1. Looks up RAW-ID in the DSMR-MCP-ATTACH-REGISTRY table.
;;;   2. Verifies the stored session tag matches SESSION-ID.
;;;   3. Drives Slynk's native inspector on the held object: builds an istate,
;;;      runs the backend emacs-inspect method, and renders it to the elisp
;;;      plist (which assigns each inspectable part an index into the istate's
;;;      parts vector).
;;;   4. Registers every inspectable part object (the LIVE object, fetched from
;;;      the istate parts vector by its index) in the dsmr handle table, mapping
;;;      slynk part-index -> dsmr raw-id.
;;;   5. Returns (list :ok ISTATE-PLIST PART-IDS SESSION-ID)
;;;      or (list :not-found RAW-ID) or (list :session-mismatch RAW-ID).
;;;
;;; Sub-object registration MUST happen inside this form because the live
;;; objects cannot cross the slime-eval wire; only their printed representations
;;; do.  Slynk's value-part renders each inspectable value to a string and
;;; stashes the live object in the istate parts vector, so the live object is
;;; reachable only here, in-image, by index.  The form returns
;;; (slynk-index dsmr-raw-id) pairs so the dispatcher can build object-ref
;;; entries carrying persistent dsmr IDs for drill-down.
;;;
;;; Symbol hygiene: every dsmr-side symbol in the form is interned in CL-USER
;;; with the %DSMR-MCP-ATTACH-REG- prefix so the remote reader resolves it
;;; without the dispatcher's (remotely-absent) package; the Slynk internals are
;;; package-qualified and exist in the attached image.  No registry lock is
;;; acquired in-image: the dispatcher's per-session call-lock serialises access,
;;; and acquiring a lock inside an in-process Slynk eval form can deadlock.
;;; ---------------------------------------------------------------------------

(defun %build-attach-inspect-form (raw-id session-id)
  "Return the sexp that, when evaluated in the attached image, looks up RAW-ID,
verifies the session tag, drives Slynk's inspector on the held object, registers
the inspectable sub-objects it surfaces, and returns
(list :ok ISTATE-PLIST PART-IDS SESSION-ID), (list :not-found RAW-ID), or
(list :session-mismatch RAW-ID)."
  (flet ((cs (name) (intern name (find-package :common-lisp-user))))
    (let ((s-tbl     (cs "%DSMR-MCP-ATTACH-REG-INS-TBL"))
          (s-ctr     (cs "%DSMR-MCP-ATTACH-REG-INS-CTR"))
          (s-entry   (cs "%DSMR-MCP-ATTACH-REG-INS-ENTRY"))
          (s-obj     (cs "%DSMR-MCP-ATTACH-REG-INS-OBJ"))
          (s-insp    (cs "%DSMR-MCP-ATTACH-REG-INS-INSP"))
          (s-hist    (cs "%DSMR-MCP-ATTACH-REG-INS-HIST"))
          (s-istate  (cs "%DSMR-MCP-ATTACH-REG-INS-ISTATE"))
          (s-ip      (cs "%DSMR-MCP-ATTACH-REG-INS-ELISP"))
          (s-parts   (cs "%DSMR-MCP-ATTACH-REG-INS-PARTS"))
          (s-cont    (cs "%DSMR-MCP-ATTACH-REG-INS-CONTENT"))
          (s-part-list (cs "%DSMR-MCP-ATTACH-REG-INS-PL"))
          (s-part    (cs "%DSMR-MCP-ATTACH-REG-INS-PART"))
          (s-pids    (cs "%DSMR-MCP-ATTACH-REG-INS-PIDS"))
          (s-nid     (cs "%DSMR-MCP-ATTACH-REG-INS-NID"))
          (s-sobj    (cs "%DSMR-MCP-ATTACH-REG-INS-SOBJ"))
          (s-sidx    (cs "%DSMR-MCP-ATTACH-REG-INS-SIDX")))
      `(let* ((,s-tbl   (symbol-value
                         (intern "*REGISTRY-TABLE*" "DSMR-MCP-ATTACH-REGISTRY")))
              (,s-ctr   (intern "*NEXT-ID*" "DSMR-MCP-ATTACH-REGISTRY"))
              (,s-entry (gethash ,raw-id ,s-tbl)))
         (cond
           ((null ,s-entry)
            (list :not-found ,raw-id))
           ((not (string= (getf ,s-entry :session) ,session-id))
            (list :session-mismatch ,raw-id))
           (t
            (let* ((,s-obj  (getf ,s-entry :object))
                   (,s-ip   nil)
                   (,s-pids nil))
              ;; Drive Slynk's native inspector on the held object, wrapped in
              ;; with-buffer-syntax so value printing matches an interactive
              ;; inspect.  inspect-object renders the elisp plist (assigning
              ;; each inspectable part an index) and leaves the istate at the
              ;; top of the inspector history.
              (slynk::with-buffer-syntax ()
                (setf ,s-ip (slynk::inspect-object ,s-obj)))
              ;; Reach the live part objects via the istate just produced (the
              ;; printed parts crossing the wire carry only indices into this
              ;; per-image parts vector).
              (let* ((,s-insp   (slynk::target-inspector))
                     (,s-hist   (slynk::inspector-%history ,s-insp))
                     (,s-istate (when (and ,s-hist (plusp (fill-pointer ,s-hist)))
                                  (aref ,s-hist (1- (fill-pointer ,s-hist)))))
                     (,s-parts  (when ,s-istate (slynk::istate.parts ,s-istate)))
                     (,s-cont   (getf ,s-ip :content))
                     (,s-part-list (when (listp ,s-cont) (car ,s-cont))))
                ;; For each (:value PRINTED IDX) token, fetch the LIVE object
                ;; from the parts vector by IDX and register the inspectable
                ;; ones, mapping IDX -> a fresh dsmr raw-id.
                (when ,s-parts
                  (dolist (,s-part ,s-part-list)
                    (when (and (consp ,s-part) (eq (car ,s-part) :value))
                      (let* ((,s-sidx (caddr ,s-part))
                             (,s-sobj (when (and (integerp ,s-sidx)
                                                 (< ,s-sidx (length ,s-parts)))
                                        (aref ,s-parts ,s-sidx))))
                        (when (and ,s-sobj
                                   (not (numberp ,s-sobj))
                                   (not (stringp ,s-sobj))
                                   (not (symbolp ,s-sobj))
                                   (not (characterp ,s-sobj)))
                          (let ((,s-nid (incf (symbol-value ,s-ctr))))
                            (setf (gethash ,s-nid ,s-tbl)
                                  (list :object ,s-sobj :session ,session-id))
                            (push (list ,s-sidx ,s-nid) ,s-pids))))))))
              (list :ok ,s-ip (nreverse ,s-pids) ,session-id))))))))

;;; ---------------------------------------------------------------------------
;;; istate->JSON normaliser
;;;
;;; Consumes the (:ok ISTATE-PLIST PART-IDS SESSION-ID) tuple and builds the
;;; canonical inspect envelope hash-table.
;;;
;;; ISTATE-PLIST shape: (:title S :id N :content (PARTS-LIST NEXT-END START END))
;;; PARTS-LIST tokens (after Slynk's prepare-part): plain strings,
;;;   (:value PRINTED-STRING IDX), (:label STRING), (:action LABEL IDX), and
;;;   newline strings.  Slynk renders slot/element values as a label string
;;;   followed by a (:value PRINTED-STRING IDX) token (the live object is kept
;;;   server-side in the parts vector, never on the wire).
;;;
;;; Slots are built by pairing the most recent label string with the following
;;; (:value ...) token.  An inspectable value that was registered in-image
;;; (its IDX appears in PART-IDS) becomes an object-ref carrying a full
;;; encode-object-id string, so drill-down re-enters the dispatcher's id space;
;;; everything else becomes a primitive value carrying the printed string.
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

(defun %istate->inspect-ht (istate-plist part-ids encoded-id epoch session-id)
  "Normalise a Slynk istate plist to the canonical inspect-object envelope.

ISTATE-PLIST: (:title S :id N :content (PARTS-LIST NEXT-END START END))
PART-IDS: list of (SLYNK-IDX DSMR-RAW-ID) pairs from sub-object registration.
ENCODED-ID: the full epoch:session:raw-id string for the root object.
EPOCH, SESSION-ID: current epoch and session for encoding sub-object ids."
  (let* ((title      (getf istate-plist :title))
         (content    (getf istate-plist :content))
         (parts-list (when (listp content) (car content)))
         (next-end   (when (listp content) (second content)))
         (end        (when (listp content) (fourth content)))
         (sidx->raw  (let ((ht (make-hash-table :test 'eql)))
                       (dolist (pair part-ids)
                         (when (and (consp pair) (= 2 (length pair)))
                           (setf (gethash (first pair) ht) (second pair))))
                       ht))
         (slots         nil)
         (pending-label nil)
         (content-text  (make-string-output-stream)))
    (dolist (part (or parts-list '()))
      (cond
        ;; (:value PRINTED-STRING IDX) -> a slot/element value.
        ((and (consp part) (eq (car part) :value))
         (let* ((printed (second part))
                (idx     (third part))
                (raw-id  (gethash idx sidx->raw))
                (printed-str (if (stringp printed) printed (%safe-prin1 printed)))
                (name    (or pending-label (format nil "part-~A" idx)))
                (value   (if raw-id
                             (make-ht "kind"    "object-ref"
                                      "id"      (encode-object-id epoch session-id raw-id)
                                      "summary" printed-str)
                             (make-ht "value" printed-str))))
           (push (make-ht "name" name "value" value) slots)
           (setf pending-label nil)))
        ;; (:action LABEL IDX) -> dropped (UI-only; no Emacs).
        ((and (consp part) (eq (car part) :action))
         nil)
        ;; (:label STRING...) -> folded into content text.
        ((and (consp part) (eq (car part) :label))
         (dolist (s (cdr part))
           (when (stringp s) (write-string s content-text))))
        ;; Plain string -> content text + candidate slot label.
        ((stringp part)
         (write-string part content-text)
         (let ((trimmed (string-trim '(#\Space #\Tab #\Newline #\Return #\:) part)))
           (when (plusp (length trimmed))
             (setf pending-label trimmed))))
        (t nil)))
    (let ((ht (make-hash-table :test 'equal)))
      (setf (gethash "kind"    ht) (%kind-from-title title))
      (setf (gethash "summary" ht) (or title ""))
      (setf (gethash "id"      ht) encoded-id)
      (when slots
        (setf (gethash "slots" ht) (coerce (nreverse slots) 'simple-vector)))
      (let ((ctext (get-output-stream-string content-text)))
        (when (plusp (length ctext))
          (setf (gethash "content" ht) (text-content ctext))))
      ;; meta: mark truncation when Slynk paginated past the first page.
      (when (and next-end end (> next-end (1+ end)))
        (setf (gethash "meta" ht)
              (make-ht "truncated" t "max_elements" (or end 500))))
      ht)))

;;; ---------------------------------------------------------------------------
;;; Bounded, retrying eval for the attached inspect round-trip
;;;
;;; The attached inspect eval is read-only and idempotent: it reads a held
;;; object and asks Slynk's inspector to describe it, never mutating user state.
;;; The rex round-trip can intermittently leave the waiting thread blocked
;;; forever when a reply is not delivered to it, so the wait is bounded by
;;; bounded-slime-eval (the dispatcher-side helper that turns a lost reply into
;;; a clean slime-network-error after a deadline).  This wrapper adds an
;;; idempotent-retry budget on top: a fresh attempt gets an independent chance
;;; to complete, turning a rare indefinite hang into a reliable result (or, once
;;; the budget is spent, a clean network-error envelope).
;;; ---------------------------------------------------------------------------

(defun %slime-eval/retry (form conn &key (timeout 30) (attempts 1))
  "Evaluate FORM on CONN via bounded-slime-eval, bounding each wait to TIMEOUT
seconds.  A lost reply yields a bounded wait rather than the indefinite block
that plain slime-eval would suffer.  Signals slime-network-error once the
ATTEMPTS budget is spent.

ATTEMPTS defaults to 1 and retrying is NOT a safe recovery: when a reply does
not arrive, the in-image inspect may still be running, and a second inspect
request would run concurrently against the connection's shared inspector state
and corrupt it (wedging the connection).  The bounded wait exists only to turn a
pathological non-returning round-trip into a clean error instead of an
indefinite hang.  ATTEMPTS is retained for callers that can guarantee the prior
request has fully settled.  Safe only for idempotent forms; the attached inspect
eval qualifies."
  (dotimes (i attempts (error 'slime-network-error))
    (handler-case
        (return (bounded-slime-eval form conn :timeout timeout))
      (slime-network-error ()
        (log-event :warn "inspect.attach.eval-retry"
                   "attempt" (1+ i) "attempts" attempts)))))

;;; ---------------------------------------------------------------------------
;;; Attached inspector dispatcher
;;; ---------------------------------------------------------------------------

(defun %dispatch-attach-inspect (tool id params)
  "Dispatch inspect-object to the attached Slynk server.

TOOL is the per-session repl-eval-tool instance carrying the connection,
call-lock, and connection-epoch slots.  ID is the JSON-RPC request id (may be
nil in direct test calls).  PARAMS is the tool argument hash-table.

Performs the epoch check BEFORE any slime-eval:
  - If the decoded epoch /= the tool's connection-epoch OR the decoded
    session-id /= the tool's session-id, returns a registry-reset error.
  - If the epoch matches but the raw-id is not in the image table, returns
    OBJECT_NOT_FOUND.
  - On success: normalises the istate plist to the canonical envelope.

Returns the envelope hash-table directly (without the result wrapper) so the
caller decides whether to wrap it in (result id ...) or return it bare."
  (let* ((id-string (and params (gethash "id" params))))
    (unless (and (stringp id-string) (plusp (length id-string)))
      (return-from %dispatch-attach-inspect
        (make-ht "isError" t
                 "content"
                 (text-content "inspect-object: 'id' parameter is required."))))
    (multiple-value-bind (decoded-epoch decoded-session-id decoded-raw-id)
        (handler-case (decode-object-id id-string)
          (error (e)
            (return-from %dispatch-attach-inspect
              (make-ht "isError" t
                       "error_type" "INVALID_ID"
                       "content"
                       (text-content
                        (format nil "inspect-object: malformed id: ~A" e))))))
      ;; Epoch check: short-circuit to registry-reset before any slime-eval.
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
        ;; Acquire the call-lock once, covering the bounded slime-eval.
        (handler-case
            (let* ((form       (%build-attach-inspect-form decoded-raw-id decoded-session-id))
                   (lock       (repl-eval-tool-call-lock tool))
                   (raw-result (with-lock-held (lock)
                                 (%slime-eval/retry
                                  form (attached-connection tool)))))
              (cond
                ;; Object not found or session mismatch -> OBJECT_NOT_FOUND.
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
Attached mode: resolve the repl-eval-tool for this session and call
%dispatch-attach-inspect on it.
Hermetic mode: dispatch-hermetic-call routes the verb by name to the worker
inspect handler."
  (ecase *mode*
    (:attached
     (let ((repl-tool (get-tool-instance (tool-session tool) "repl-eval")))
       (result id (%dispatch-attach-inspect repl-tool id args))))
    (:hermetic
     (dispatch-hermetic-call (tool-session tool) id "inspect-object" args))
    (:inline
     (rpc-error id -32603
                "inspect-object requires attached or hermetic mode."))))
