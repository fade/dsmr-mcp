;;;; src/tools/pool-kill-worker.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; MCP tool: pool-kill-worker.
;;;; Kills the worker bound to the current session when *mode* is :hermetic;
;;;; returns an informative isError when the pool is not running.
;;;;
;;;; CLOS pattern: see pool-status.lisp header — same :initform rule applies.

(defpackage #:dsmr-mcp/src/tools/pool-kill-worker
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/tools/base
                #:mcp-tool #:mcp-tool-class #:tool-handle)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:result #:text-content #:make-ht #:rpc-error)
  (:import-from #:dsmr-mcp/src/state
                #:*mode* #:*current-session-id*)
  (:import-from #:dsmr-mcp/src/hermetic/pool
                #:kill-session-worker)
  ;; closer-mop: c2mop:ensure-finalized is called after the defclass below.
  ;; MUST be declared here or the cold build fails ("Package CLOSER-MOP does not exist").
  (:import-from #:closer-mop))

(in-package #:dsmr-mcp/src/tools/pool-kill-worker)

(defclass pool-kill-worker-tool (mcp-tool)
  ;; CRITICAL: :initform on class-allocated slots, NOT :default-initargs.
  ((dsmr-mcp/src/tools/base::name
    :allocation :class
    :initform "pool-kill-worker")
   (dsmr-mcp/src/tools/base::description
    :allocation :class
    :initform "Kill the hermetic worker bound to the current session. \
A replacement worker is spawned on the next tool call. In-image state \
(loaded systems, REPL definitions) is lost. Use this to recover from a \
stuck or corrupted worker. Only available in hermetic mode.")
   (dsmr-mcp/src/tools/base::input-schema
    :allocation :class
    :initform '(:object
                :properties
                ((reset
                  :type :boolean
                  :description "When true, also clears the session circuit breaker state \
so the next call can spawn without waiting for the 60-second cool-down."))
                :required ())))
  (:metaclass mcp-tool-class)
  (:documentation "MCP tool: kill the hermetic worker for the current session.
Only available when *mode* is :hermetic."))

(defmethod tool-handle ((tool pool-kill-worker-tool) id args)
  (unless (eq *mode* :hermetic)
    (return-from tool-handle
      (result id (make-ht "isError" t
                          "content"
                          (text-content
                           "pool-kill-worker is only available in hermetic mode.")))))
  (let* ((session-id *current-session-id*)
         (reset (and args (gethash "reset" args)))
         (kill-result (kill-session-worker session-id :reset reset)))
    (case kill-result
      (:no-worker
       (result id (make-ht "isError" nil
                           "content"
                           (text-content "No worker is bound to this session."))))
      (:placeholder
       (result id (make-ht "isError" nil
                           "content"
                           (text-content
                            "Worker spawn was in progress and has been cancelled."))))
      (:killed
       (result id (make-ht "isError" nil
                           "content"
                           (text-content
                            "Worker killed. A fresh worker will spawn on the next tool call."))))
      (t
       (result id (make-ht "isError" t
                           "content"
                           (text-content
                            (format nil "Unexpected kill result: ~A" kill-result))))))))

;; CRITICAL: ensure-finalized must appear after defclass.
;; (src/tools/base.lisp line 162; src/attach/dispatch.lisp line 115.)
(c2mop:ensure-finalized (find-class 'pool-kill-worker-tool))
