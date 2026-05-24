;;;; src/tools/base.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; CLOS tool-registry protocol: abstract base class, auto-registering
;;;; metaclass, generic-function surface, and the *tool-classes* registry.
;;;;
;;;; Tools are CLOS classes, not a define-tool macro.
;;;; The mcp-tool-class metaclass auto-registers each concrete subclass
;;;;   in *tool-classes* at class-finalization time — no register-tool
;;;;   call required. Hot-reload friendly: re-evaluating a defclass
;;;;   re-runs finalize-inheritance and refreshes the entry.
;;;; closer-mop powers the metaclass machinery (validate-superclass,
;;;;   finalize-inheritance :after, class-prototype).

(defpackage #:dsmr-mcp/src/tools/base
  (:use #:cl)
  (:export #:mcp-tool
           #:mcp-tool-class
           #:*tool-classes*
           #:tool-handle
           #:tool-name
           #:tool-description
           #:tool-input-schema
           #:tool-session))

(in-package #:dsmr-mcp/src/tools/base)

;;; Registry ----------------------------------------------------------------

(defparameter *tool-classes* (make-hash-table :test 'equal)
  "Maps tool name (string) -> tool class (CLASS). Populated by the
mcp-tool-class metaclass at class-finalization time. Last defclass
wins for a given name string — this is intentional for hot-reload:
re-evaluating a tool defclass refreshes its entry here. Treat
name collisions as a developer footgun; there is no collision-detection
or warning because the hot-reload benefit outweighs the risk in a
single-image dev workflow.")

;;; Metaclass ---------------------------------------------------------------

(defclass mcp-tool-class (standard-class)
  ()
  (:documentation
   "Metaclass for mcp-tool and its subclasses. Inheriting this metaclass
causes SBCL/closer-mop to invoke (finalize-inheritance :after) at
class-definition time, which auto-registers the class in *tool-classes*
keyed by its :allocation :class name slot. The abstract mcp-tool base
class is never registered (guarded by the class-name check below).
Every concrete tool file must call (c2mop:ensure-finalized (find-class
'my-tool)) after its defclass so the :after method fires eagerly at
load time rather than being deferred to first instantiation."))

(defmethod c2mop:validate-superclass ((class mcp-tool-class)
                                      (super standard-class))
  "Allow mcp-tool-class to be used as a metaclass for classes whose
direct superclasses are standard-class (or another mcp-tool-class)."
  t)

(defmethod c2mop:finalize-inheritance :after ((class mcp-tool-class))
  "Auto-register CLASS in *tool-classes* keyed by its tool-name.
Skips the abstract mcp-tool base class itself (name check) and any
class whose prototype does not carry a non-nil name string."
  (let ((proto (c2mop:class-prototype class)))
    (when (and (typep proto 'mcp-tool)
               (not (eq (class-name class) 'mcp-tool)))
      (let ((name (ignore-errors (tool-name proto))))
        (when (and name (stringp name))
          (setf (gethash name *tool-classes*) class))))))

;;; Generic functions -------------------------------------------------------

(defgeneric tool-handle (tool id args)
  (:documentation "Dispatch a tools/call for TOOL with request-id ID and
argument hash-table ARGS. Returns a JSON-RPC result or error hash-table
built by dsmr-mcp/src/tools/helpers:result or rpc-error. Concrete tool
subclasses specialize this method."))

(defgeneric tool-name (tool)
  (:documentation "Return the MCP tool-name string for TOOL (e.g.
\"repl-eval\"). Backed by a :allocation :class slot so every instance
of a given subclass shares one canonical name without allocation cost."))

(defgeneric tool-description (tool)
  (:documentation "Return the MCP tool-description string for TOOL.
Backed by a :allocation :class slot."))

(defgeneric tool-input-schema (tool)
  (:documentation "Return the s-expression input-schema literal for TOOL.
The schema is a class-allocated s-expr converted to a JSON Schema hash-table
at tools/list time by dsmr-mcp/src/tools/helpers:schema->json. Backed by a
:allocation :class slot so all instances share one literal."))

(defgeneric tool-session (tool)
  (:documentation "Return the per-instance session object this TOOL
instance was created for. Set at make-instance time via :session initarg.
Lets tool method bodies access per-session state (Slynk connection cache,
etc.) without needing a dynamic variable."))

;;; Abstract base class -----------------------------------------------------

(defclass mcp-tool ()
  ((session
    :initarg :session
    :reader tool-session
    :documentation "Per-instance session — set at construction time by
get-tool-instance (src/state.lisp). Tool methods use this to access
per-session state. Lives as a normal per-instance slot so each
session gets its own tool object.")
   (name
    :initarg :name
    :reader tool-name
    :allocation :class
    :documentation "JSON tool-name string (e.g. \"repl-eval\").
Class-allocated so it is shared by all instances; set via :default-initargs
or by (:default-initargs :name \"...\") on the concrete subclass.")
   (description
    :initarg :description
    :reader tool-description
    :allocation :class
    :documentation "Human-readable MCP tool-description string.
Class-allocated; shared across all instances of the subclass.")
   (input-schema
    :initarg :input-schema
    :reader tool-input-schema
    :allocation :class
    :documentation "Lisp s-expression schema literal (e.g.
(:object :properties ((code :type :string)) :required (\"code\"))).
Class-allocated; converted to a JSON Schema hash-table once per
tools/list call by schema->json."))
  (:metaclass mcp-tool-class)
  (:documentation "Abstract base class for all MCP tools in dsmr-mcp.
Subclass this and add :metaclass mcp-tool-class to get auto-registration
in *tool-classes* at class-definition time. Specialize tool-handle to
implement the tool's behaviour.

Concrete subclass template:

  (defclass my-tool (mcp-tool)
    ((name        :allocation :class :initform \"my-tool\")
     (description :allocation :class :initform \"Does the thing.\")
     (input-schema :allocation :class
                   :initform '(:object :properties ((arg :type :string))
                                       :required (\"arg\"))))
    (:metaclass mcp-tool-class))

  (defmethod tool-handle ((tool my-tool) id args)
    (result id (text-content \"ok\")))

  (c2mop:ensure-finalized (find-class 'my-tool))

CRITICAL: use :initform on the slot spec for class-allocated slots,
NOT :default-initargs. c2mop:class-prototype does not apply
:default-initargs, so finalize-inheritance :after would see NIL for
the name slot and skip registration if :default-initargs were used."))

;; Ensure the abstract base class is finalized at load time so
;; closer-mop's finalize-inheritance :after fires now and does NOT wait
;; until first instantiation. The :after method skips mcp-tool itself
;; (the class-name guard above), so this call is a no-op for the
;; registry — its purpose is to warm up the MOP machinery before any
;; concrete subclasses arrive.
(c2mop:ensure-finalized (find-class 'mcp-tool))
