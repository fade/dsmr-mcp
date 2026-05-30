;;;; src/tools/clhs-lookup.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; MCP tool: query the Common Lisp HyperSpec by symbol or section number.
;;;; Mode-independent (dispatcher-side) and rootless — a HyperSpec lookup is a
;;;; pure read of a local doc tree, so this tool imports no session root or
;;;; write-jail. An unresolvable HyperSpec returns a structured isError (D-04),
;;;; never a wire-level signal.

(defpackage #:dsmr-mcp/src/tools/clhs-lookup
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/tools/base
                #:mcp-tool
                #:mcp-tool-class
                #:tool-handle)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:make-ht
                #:result
                #:text-content)
  (:import-from #:dsmr-mcp/src/clhs
                #:clhs-lookup))

(in-package #:dsmr-mcp/src/tools/clhs-lookup)

(defclass clhs-lookup-tool (mcp-tool)
  ((dsmr-mcp/src/tools/base::name
    :allocation :class
    :initform "clhs-lookup")
   (dsmr-mcp/src/tools/base::description
    :allocation :class
    :initform "Look up a symbol or section in the Common Lisp HyperSpec (ANSI standard). \
Accepts a symbol name (loop, format, handler-case) or a section number (22.3, 3.1.2, \
auto-detected by the digit.dot shape) and returns the resolved entry URL plus extracted \
plain text. Reads a local HyperSpec tree; resolves nothing over the network on the \
primary path. Returns a structured not-found error when no HyperSpec is available.")
   (dsmr-mcp/src/tools/base::input-schema
    :allocation :class
    :initform '(:object
                :properties
                ((query
                  :type :string
                  :description "Symbol name or section number (e.g. loop, 22.3).")
                 (include-content
                  :type :boolean
                  :description "Include extracted text content (default: true).")
                 (brief
                  :type :boolean
                  :description "Return only Syntax + Arguments (compact; omits \
Description, Examples, Notes for token efficiency)."))
                :required ("query"))))
  (:metaclass mcp-tool-class)
  (:documentation "MCP tool: Common Lisp HyperSpec lookup by symbol or section.
Rootless read-only verb. Fail-closed: an unresolvable HyperSpec yields a
structured isError, never a crash."))

(c2mop:ensure-finalized (find-class 'clhs-lookup-tool))

(defmethod tool-handle ((tool clhs-lookup-tool) id args)
  (let ((query (gethash "query" args)))
    (unless (and query (stringp query))
      (return-from tool-handle
        (result id (make-ht "isError" t
                            "error_type" "invalid-argument"
                            "content" (text-content "clhs-lookup: query must be a string.")))))
    ;; include_content defaults to true when the client omits it; an explicit
    ;; false (jzon -> NIL) must be honoured, so distinguish absent from false.
    (let ((include-content (if (nth-value 1 (gethash "include_content" args))
                               (gethash "include_content" args)
                               t))
          (brief (gethash "brief" args)))
      (handler-case
          (let ((res (clhs-lookup query :include-content include-content :brief brief)))
            (if (null res)
                ;; Fail-closed: no HyperSpec resolved (D-04).
                (result id (make-ht "isError" t
                                    "error_type" "hyperspec-not-found"
                                    "content"
                                    (text-content "HyperSpec not found — set DSMR_HYPERSPEC_DIR, \
place a tree at $LISP_WORKSPACE/HyperSpec/, or install :clhs locally.")))
                (result id res)))
        (error (e)
          (result id (make-ht "isError" t
                              "error_type" "clhs-lookup-error"
                              "content" (text-content
                                         (format nil "clhs-lookup: ~A" (princ-to-string e))))))))))
