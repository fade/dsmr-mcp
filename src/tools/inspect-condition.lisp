;;;; src/tools/inspect-condition.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; inspect-condition MCP tool: VERB-19.  At a live SLDB break, drills into
;;;; the current debugger condition's slot values and reports its type hierarchy
;;;; (class-precedence-list) — giving the agent the condition-inspection view a
;;;; SLIME user sees in the debugger buffer.
;;;;
;;;; Attached path: builds a self-contained injected form (all helper symbols
;;;; interned in CL-USER with the %DSMR-MCP-ATTACH-COND-* prefix) and evaluates
;;;; it via bounded-slime-eval.  Two branches:
;;;;   - Live-break: reads SLYNK::*SLYNK-DEBUGGER-CONDITION*, enumerates slots
;;;;     via SB-MOP find-symbol, and returns a plist with :condition-p t,
;;;;     :type, :hierarchy, and :slots.
;;;;   - Held-object (object-id non-nil): resolves the condition by raw-id from
;;;;     the DSMR-MCP-ATTACH-REGISTRY table; same slot drill-down.
;;;;   - Not-at-break / no held-object: returns :condition-p nil with empty
;;;;     slots — the dispatcher renders this as a structured result (NOT isError).
;;;;
;;;; Hermetic path: delegates to dispatch-hermetic-call, which routes to the
;;;; worker's %handle-inspect-condition handler that uses inspect-object-by-id.
;;;;
;;;; Symbol hygiene (CRITICAL — see MEMORY.md):
;;;;   - Every binding in the injected form is interned in CL-USER via (cs "...").
;;;;   - handler-case uses (error () ...) with NO named variable — named vars
;;;;     interned in this package become DSMR-MCP/.../... on the wire and the
;;;;     target READ fails → NETWORK_ERROR (root cause of commit 6ca196d).
;;;;   - All wire-bound strings coerced via (map 'string #'identity ...) —
;;;;     SIMPLE-BASE-STRING prints as #A((N) BASE-CHAR ...) under *print-readably*
;;;;     (root cause of commit e46f8e2).
;;;;   - No #\X char literals or #() vector literals (use (code-char N) /
;;;;     (vector ...) per MEMORY.md — no character or void-vector literals used).
;;;;   - SB-MOP accessed via find-symbol (not compile-time hard reference) so
;;;;     the form is portable to non-SBCL attached images.
;;;;
;;;; Note on arbitrary captured-condition drill-down: inspecting a condition
;;;; held only in repl-eval's error_context (not registered as a result object)
;;;; is a follow-on capability (Open Question #2 in 08-RESEARCH.md) and is not
;;;; delivered in this phase.  The object-id branch handles conditions that WERE
;;;; explicitly registered via result_object_id.

(defpackage #:dsmr-mcp/src/tools/inspect-condition
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
                #:get-tool-instance)
  (:import-from #:dsmr-mcp/src/log
                #:log-event)
  (:import-from #:dsmr-mcp/src/hermetic/dispatch
                #:dispatch-hermetic-call)
  (:import-from #:slynk-client
                #:slime-network-error)
  (:import-from #:bordeaux-threads
                #:with-lock-held)
  (:export #:inspect-condition-tool
           #:%build-attach-condition-form
           #:%dispatch-attach-inspect-condition))

(in-package #:dsmr-mcp/src/tools/inspect-condition)

;;; ---------------------------------------------------------------------------
;;; inspect-condition-tool CLOS class
;;;
;;; Mirrors inspect-object-tool: class-allocated name/description/input-schema
;;; with :initform (NOT :default-initargs); c2mop:ensure-finalized immediately
;;; after defclass fires the metaclass :after method that registers the tool.
;;; ---------------------------------------------------------------------------

(defclass inspect-condition-tool (mcp-tool)
  ((dsmr-mcp/src/tools/base::name
    :allocation :class
    :initform "inspect-condition")
   (dsmr-mcp/src/tools/base::description
    :allocation :class
    :initform "Drill into the current debugger condition at a live SLDB break: \
returns the condition's slot values and its class-precedence-list type hierarchy. \
When supplied with a result_object_id pointing to a held condition, inspects that \
object instead of the live break condition.  When not at a break (and no id given), \
returns a structured not-at-break result with condition_p=false — not an error. \
Inspecting an arbitrary captured condition that was not registered as a result \
object is a follow-on capability not yet delivered.")
   (dsmr-mcp/src/tools/base::input-schema
    :allocation :class
    :initform '(:object
                :properties
                ((id
                  :type :string
                  :description "Optional result_object_id from a previous repl-eval \
or inspect-object call pointing to a held condition.  When supplied, inspects that \
registered object instead of the live debugger condition.")
                 (max_elements
                  :type :integer
                  :description "Maximum number of slots to return (default: 50)."))
                :required ())))
  (:metaclass mcp-tool-class)
  (:documentation "MCP tool: inspect the current debugger condition at a live break.
VERB-19 — attached path evaluates a portable injected form that reads
*slynk-debugger-condition* or a registry-held condition; hermetic path routes
to the worker inspect handler."))

;; ensure-finalized fires the metaclass :after method at load time,
;; registering \"inspect-condition\" in *tool-classes*.
(c2mop:ensure-finalized (find-class 'inspect-condition-tool))

;;; ---------------------------------------------------------------------------
;;; Injected-form builder
;;;
;;; Symbol hygiene rules (ALL MANDATORY — see comment at top of file):
;;;   1. dolist not loop.
;;;   2. (code-char N) not #\X.
;;;   3. (vector ...) not #().
;;;   4. (map 'string #'identity s) on ALL wire-bound strings.
;;;   5. Every binding interned in CL-USER via (cs "...").
;;;   6. handler-case uses (error () ...) with NO named variable.
;;;   7. MOP accessed via find-package + find-symbol against a probe list
;;;      (closer-mop, c2mop, sb-mop, ccl, mop, clos) — the attached image's
;;;      CL implementation is not known at form-build time, so the form
;;;      degrades cleanly to an empty :slots / :hierarchy when no MOP
;;;      package is available rather than hard-failing.
;;;   8. ANSI-portable: condition slot inspection via ANSI slot-boundp/
;;;      slot-value works across CL implementations.  Slot enumeration
;;;      itself needs MOP — see rule 7 for the discovery strategy.
;;;
;;; Return value from the injected form:
;;;   A plist: (:condition-p BOOL :type STRING-OR-NIL
;;;             :hierarchy LIST-OF-STRINGS :slots LIST-OF-PLISTS)
;;; where each slot plist is (:name STRING :value STRING).
;;; When condition-p is nil, type is nil, hierarchy is nil, slots is nil.
;;;
;;; Shared slot-drill logic factored into %build-condition-slot-drill-fragment
;;; to avoid repeating the identical dolist body in both branches.
;;; ---------------------------------------------------------------------------

(defun %make-slot-drill-fragment (cs s-cond s-csf s-sdn s-cplf s-cnfn
                                  s-slots s-hier s-slot s-nm s-val s-cls
                                  s-cpl s-cname)
  "Return the shared (when ,s-cond ...) body used in both form branches.
All symbols are pre-interned in CL-USER by the caller."
  (declare (ignore cs))
  `(when ,s-cond
     ;; Type hierarchy via class-precedence-list.
     (when (and ,s-cplf ,s-cnfn)
       (handler-case
           (let ((,s-cpl (funcall ,s-cplf (class-of ,s-cond))))
             (dolist (,s-cls ,s-cpl)
               (let ((,s-cname (funcall ,s-cnfn ,s-cls)))
                 (let ((,s-nm (symbol-name ,s-cname)))
                   (unless (or (string= ,s-nm "T")
                               (string= ,s-nm "STANDARD-OBJECT")
                               (string= ,s-nm "STRUCTURE-OBJECT"))
                     (push (map 'string #'identity ,s-nm)
                           ,s-hier))))))
         (error () nil))
       (setf ,s-hier (nreverse ,s-hier)))
     ;; Slot drill-down via SB-MOP (found via find-symbol).
     (when (and ,s-csf ,s-sdn)
       (handler-case
           (dolist (,s-slot (funcall ,s-csf (class-of ,s-cond)))
             (let* ((,s-nm  (funcall ,s-sdn ,s-slot))
                    (,s-val (if (slot-boundp ,s-cond ,s-nm)
                                (handler-case
                                    (let ((*print-level* 3)
                                          (*print-readably* nil))
                                      (prin1-to-string
                                       (slot-value ,s-cond ,s-nm)))
                                  (error () "<unreadable>"))
                                "#<unbound>")))
               (push (list :name  (map 'string #'identity (symbol-name ,s-nm))
                           :value (map 'string #'identity ,s-val))
                     ,s-slots)))
         (error () nil))
       (setf ,s-slots (nreverse ,s-slots)))))

(defun %build-attach-condition-form (object-id)
  "Return the sexp that, when evaluated in the attached image, inspects the
current debugger condition (or a held condition by OBJECT-ID) and returns a
plist with :condition-p, :type, :hierarchy, and :slots.

When OBJECT-ID is nil: reads SLYNK::*SLYNK-DEBUGGER-CONDITION*.
When OBJECT-ID is non-nil: resolves the condition from DSMR-MCP-ATTACH-REGISTRY
by raw integer id.  The registry table lookup is keyed on raw-id alone — no
session qualifier needed because each session has its own per-tool registry.

Returns :condition-p nil (not an error) when no condition is accessible.

No DSMR-MCP-package symbols cross the wire; condition-form-is-portable in
tests/attach/inspect-condition-test.lisp verifies this for both arities."
  (flet ((cs (n) (intern n (find-package :common-lisp-user))))
    (let ((s-cond  (cs "%DSMR-MCP-ATTACH-COND-C"))
          (s-slots (cs "%DSMR-MCP-ATTACH-COND-SLOTS"))
          (s-slot  (cs "%DSMR-MCP-ATTACH-COND-SL"))
          (s-nm    (cs "%DSMR-MCP-ATTACH-COND-NM"))
          (s-val   (cs "%DSMR-MCP-ATTACH-COND-VL"))
          (s-hier  (cs "%DSMR-MCP-ATTACH-COND-HIER"))
          (s-cls   (cs "%DSMR-MCP-ATTACH-COND-CLS"))
          (s-cpl   (cs "%DSMR-MCP-ATTACH-COND-CPL"))
          (s-cname (cs "%DSMR-MCP-ATTACH-COND-CNAME"))
          (s-mopkg (cs "%DSMR-MCP-ATTACH-COND-MOPKG"))
          (s-csf   (cs "%DSMR-MCP-ATTACH-COND-CSF"))
          (s-sdn   (cs "%DSMR-MCP-ATTACH-COND-SDN"))
          (s-cplf  (cs "%DSMR-MCP-ATTACH-COND-CPLF"))
          (s-cnfn  (cs "%DSMR-MCP-ATTACH-COND-CNFN"))
          ;; cs-interned symbols for registry-lookup branch.
          (s-rpkg  (cs "%DSMR-MCP-ATTACH-COND-RPKG"))
          (s-rsym  (cs "%DSMR-MCP-ATTACH-COND-RSYM"))
          (s-tbl   (cs "%DSMR-MCP-ATTACH-COND-TBL"))
          (s-entry (cs "%DSMR-MCP-ATTACH-COND-ENTRY"))
          ;; cs-interned symbols for live-break branch.
          (s-slpkg (cs "%DSMR-MCP-ATTACH-COND-SLPKG"))
          (s-slsym (cs "%DSMR-MCP-ATTACH-COND-SLSYM")))
      (let ((drill (%make-slot-drill-fragment
                    #'cs s-cond s-csf s-sdn s-cplf s-cnfn
                    s-slots s-hier s-slot s-nm s-val s-cls s-cpl s-cname))
            (mop-bindings
              ;; Probe known MOP package names in priority order — the
              ;; attached image's CL implementation is not known at form-
              ;; build time, so a hard-coded "SB-MOP" silently empties the
              ;; slots vector on CCL/ECL/CLISP/ACL.  closer-mop and c2mop
              ;; are the portable shims that wrap whichever native MOP
              ;; package the implementation exposes; sb-mop/ccl/mop/clos
              ;; are the direct native packages.  If none resolve the
              ;; result form will surface :hierarchy nil :slots nil
              ;; without crashing.
              `((,s-mopkg  (or (find-package "CLOSER-MOP")
                               (find-package "C2MOP")
                               (find-package "SB-MOP")
                               (find-package "CCL")
                               (find-package "MOP")
                               (find-package "CLOS")))
                (,s-csf    (when ,s-mopkg
                             (find-symbol "CLASS-SLOTS" ,s-mopkg)))
                (,s-sdn    (when ,s-mopkg
                             (find-symbol "SLOT-DEFINITION-NAME" ,s-mopkg)))
                (,s-cplf   (when ,s-mopkg
                             (find-symbol "CLASS-PRECEDENCE-LIST" ,s-mopkg)))
                (,s-cnfn   (ignore-errors
                             (find-symbol "CLASS-NAME" "COMMON-LISP")))))
            (result-form
              `(list :condition-p (not (null ,s-cond))
                     :type        (when ,s-cond
                                    (map 'string #'identity
                                         (prin1-to-string (type-of ,s-cond))))
                     :hierarchy   ,s-hier
                     :slots       ,s-slots)))
        (if object-id
            ;; Held-object branch: resolve from DSMR-MCP-ATTACH-REGISTRY.
            ;; find-package / find-symbol (not intern) — the registry package may
            ;; not exist in the attached image (common case for an image dsmr-mcp
            ;; has not been loaded into).  intern would signal package-error;
            ;; find-package / find-symbol return NIL gracefully, the inner WHENs
            ;; short-circuit, and the form yields a not-found result.
            `(let* (,@mop-bindings
                    (,s-cond   (let* ((,s-rpkg  (find-package
                                                 "DSMR-MCP-ATTACH-REGISTRY"))
                                      (,s-rsym  (and ,s-rpkg
                                                     (find-symbol
                                                      "*REGISTRY-TABLE*"
                                                      ,s-rpkg)))
                                      (,s-tbl   (when (and ,s-rsym
                                                           (boundp ,s-rsym))
                                                  (symbol-value ,s-rsym)))
                                      (,s-entry (when ,s-tbl
                                                  (gethash ,object-id ,s-tbl))))
                                 (when ,s-entry (getf ,s-entry :object))))
                    (,s-slots  nil)
                    (,s-hier   nil))
               ,drill
               ,result-form)
            ;; Live-break branch: read *slynk-debugger-condition*.
            `(let* (,@mop-bindings
                    (,s-cond   (let ((,s-slpkg (find-package "SLYNK")))
                                 (when ,s-slpkg
                                   (let ((,s-slsym (find-symbol
                                                    "*SLYNK-DEBUGGER-CONDITION*"
                                                    ,s-slpkg)))
                                     (when (and ,s-slsym (boundp ,s-slsym))
                                       (symbol-value ,s-slsym))))))
                    (,s-slots  nil)
                    (,s-hier   nil))
               ,drill
               ,result-form))))))

;;; ---------------------------------------------------------------------------
;;; Decode plist result into wire hash-table
;;; ---------------------------------------------------------------------------

(defun %plist->condition-ht (plist max-elements)
  "Convert the plist returned by the injected form to a wire hash-table.
Shapes the response regardless of whether condition-p is true or false."
  (let* ((condition-p (getf plist :condition-p))
         (ht          (make-hash-table :test 'equal)))
    (setf (gethash "condition_p" ht) (if condition-p t nil))
    (when condition-p
      (let ((type-str (getf plist :type)))
        (when type-str
          (setf (gethash "condition_type" ht)
                (map 'string #'identity type-str))))
      ;; Type hierarchy: vector of class-name strings.
      (let ((hier (getf plist :hierarchy)))
        (setf (gethash "hierarchy" ht)
              (if (listp hier)
                  (coerce (mapcar (lambda (s) (map 'string #'identity s)) hier)
                          'simple-vector)
                  (vector))))
      ;; Slots: cap at max-elements, build vector of {name, value} hash-tables.
      (let* ((raw-slots  (getf plist :slots))
             (cap        (or max-elements 50))
             (capped     (if (and (listp raw-slots) (> (length raw-slots) cap))
                             (subseq raw-slots 0 cap)
                             raw-slots)))
        (setf (gethash "slots" ht)
              (if (listp capped)
                  (coerce
                   (mapcar (lambda (sp)
                             (make-ht "name"  (map 'string #'identity
                                                   (or (getf sp :name) ""))
                                      "value" (map 'string #'identity
                                                   (or (getf sp :value) ""))))
                           capped)
                   'simple-vector)
                  (vector)))))
    ht))

;;; ---------------------------------------------------------------------------
;;; Attached dispatcher
;;; ---------------------------------------------------------------------------

(defun %dispatch-attach-inspect-condition (tool id params)
  "Dispatch inspect-condition to the attached Slynk server.

TOOL is the per-session repl-eval-tool instance.  ID is the JSON-RPC request id
(may be nil in direct test calls).  PARAMS is the tool argument hash-table.

When params includes \"id\" (a result_object_id string), decodes the raw id and
uses the held-object branch.  Otherwise uses the live-break branch.

Returns a make-ht with condition_p, condition_type (when applicable),
hierarchy vector, and slots vector.  A not-at-break result has condition_p=false
and no isError.  On slime-network-error returns a NETWORK_ERROR make-ht.

The MCP request ID is kept available (declared ignorable rather than ignored)
so future rpc-error emission can echo the caller's id per JSON-RPC 2.0
without broadening the function signature."
  (declare (ignorable id))
  (let* ((p            (or params (make-hash-table :test 'equal)))
         (id-string    (gethash "id" p))
         (max-elements (gethash "max_elements" p))
         ;; Decode the object id when present; if malformed treat as live-break.
         (raw-id       (when (and (stringp id-string) (plusp (length id-string)))
                         (handler-case
                             (multiple-value-bind (ep sid rid)
                                 (decode-object-id id-string)
                               (declare (ignore ep sid))
                               rid)
                           (error () nil))))
         (form         (%build-attach-condition-form raw-id))
         (lock         (repl-eval-tool-call-lock tool)))
    (handler-case
        (let* ((raw (with-lock-held (lock)
                      (bounded-slime-eval form (attached-connection tool))))
               (ht  (%plist->condition-ht (if (listp raw) raw '()) max-elements)))
          ht)
      (slime-network-error (e)
        (log-event :warn "inspect-condition.attach.network-error"
                   "error" (handler-case (princ-to-string e) (error () "")))
        (return-from %dispatch-attach-inspect-condition
          (make-ht "isError"    t
                   "error_type" "NETWORK_ERROR"
                   "content"
                   (text-content
                    (format nil "inspect-condition: Slynk connection error: ~A"
                            e))))))))

;;; ---------------------------------------------------------------------------
;;; tool-handle method
;;; ---------------------------------------------------------------------------

(defmethod tool-handle ((tool inspect-condition-tool) id args)
  "Route inspect-condition by *mode*.
Attached: resolve the repl-eval-tool and call %dispatch-attach-inspect-condition.
Hermetic: dispatch-hermetic-call routes to the worker inspect-condition handler.
Inline: returns a typed mode error."
  (ecase *mode*
    (:attached
     (let ((repl-tool (get-tool-instance (tool-session tool) "repl-eval")))
       (result id (%dispatch-attach-inspect-condition repl-tool id args))))
    (:hermetic
     (dispatch-hermetic-call (tool-session tool) id "inspect-condition" args))
    (:inline
     (rpc-error id -32603
                "inspect-condition requires attached or hermetic mode."))))
