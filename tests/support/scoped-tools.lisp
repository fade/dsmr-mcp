;;;; tests/support/scoped-tools.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Keeps test-fixture tools out of the global *tool-classes* registry.
;;;;
;;;; A stub tool defined with :metaclass mcp-tool-class registers itself
;;;; globally at finalization, where everything that walks the registry —
;;;; tools/list and the docs/tools.org parity renderer — would see it and
;;;; advertise a verb that does not ship. A fixture must stay invisible to
;;;; those walkers: unregister it right after its defclass, then run the
;;;; tests that need it inside WITH-SCOPED-TOOLS, which rebinds
;;;; *tool-classes* to a copy carrying the stub. The global table never
;;;; holds the fixture.

(defpackage #:dsmr-mcp/tests/support/scoped-tools
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/tools/base
                #:*tool-classes*)
  (:export #:unregister-tool
           #:call-with-scoped-tools
           #:with-scoped-tools))

(in-package #:dsmr-mcp/tests/support/scoped-tools)

(defun unregister-tool (name)
  "Remove the tool registered under NAME from the global registry.
Call immediately after a fixture's defclass + finalization so the stub is
never visible to tools/list or the documentation renderer."
  (remhash name *tool-classes*)
  name)

(defun call-with-scoped-tools (bindings thunk)
  "Run THUNK with *tool-classes* bound to a copy of the global registry
augmented with BINDINGS, an alist of (NAME . CLASS). The global registry
never carries the fixtures."
  (let ((reg (make-hash-table :test 'equal)))
    (maphash (lambda (k v) (setf (gethash k reg) v)) *tool-classes*)
    (loop for (name . class) in bindings
          do (setf (gethash name reg) class))
    (let ((*tool-classes* reg))
      (funcall thunk))))

(defmacro with-scoped-tools (bindings &body body)
  "Evaluate BODY with *tool-classes* bound to a registry copy carrying the
fixture tools in BINDINGS, a literal list of (NAME-STRING CLASS-NAME) pairs."
  `(call-with-scoped-tools
    (list ,@(loop for (name class) in bindings
                  collect `(cons ,name (find-class ',class))))
    (lambda () ,@body)))
