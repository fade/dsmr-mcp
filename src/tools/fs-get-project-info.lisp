;;;; src/tools/fs-get-project-info.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; MCP tool: report session project root and its source.
;;;; Mode-independent (dispatcher-side). No worker pool fields.

(defpackage #:dsmr-mcp/src/tools/fs-get-project-info
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/tools/base
                #:mcp-tool
                #:mcp-tool-class
                #:tool-handle
                #:tool-session)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:make-ht
                #:result
                #:text-content)
  (:import-from #:dsmr-mcp/src/state
                #:session-project-root))

(in-package #:dsmr-mcp/src/tools/fs-get-project-info)

(defclass fs-get-project-info-tool (mcp-tool)
  ((dsmr-mcp/src/tools/base::name
    :allocation :class
    :initform "fs-get-project-info")
   (dsmr-mcp/src/tools/base::description
    :allocation :class
    :initform "Report the session project root and how it was set.")
   (dsmr-mcp/src/tools/base::input-schema
    :allocation :class
    :initform '(:object :properties () :required ())))
  (:metaclass mcp-tool-class)
  (:documentation "MCP tool: return project root information for the current session."))

(c2mop:ensure-finalized (find-class 'fs-get-project-info-tool))

(defmethod tool-handle ((tool fs-get-project-info-tool) id args)
  (declare (ignore args))
  (let* ((session (tool-session tool))
         (root    (session-project-root session))
         ;; D-16: no silent cwd default when root is not set
         (root-ns (and root (namestring root)))
         ;; Determine how root was set (env vs explicit)
         (source  (cond
                    ((null root) "not-set")
                    ((uiop:getenv "DSMR_PROJECT_ROOT") "env")
                    (t "explicit")))
         (summary (if root-ns
                      (format nil "Project root: ~A~%Source: ~A" root-ns source)
                      "No project root set. Call fs-set-project-root first.")))
    (result id
            (make-ht "project_root"        root-ns
                     "session_root"        root-ns
                     "project_root_source" source
                     "content" (text-content summary)))))
