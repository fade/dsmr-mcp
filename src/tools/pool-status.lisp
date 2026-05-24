;;;; src/tools/pool-status.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; MCP tool: pool-status (HERM-06, OPS-03).
;;;; Returns structured pool diagnostic JSON when *mode* is :hermetic;
;;;; returns an informative isError when the pool is not running.
;;;;
;;;; CLOS pattern: class-allocated name/description/input-schema use :initform
;;;; (NOT :default-initargs) because c2mop:class-prototype does not apply
;;;; :default-initargs; the metaclass registration :after hook would see NIL
;;;; for the name slot and skip registration if :default-initargs were used.
;;;; (src/tools/base.lisp lines 138-154.)

(defpackage #:dsmr-mcp/src/tools/pool-status
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/tools/base
                #:mcp-tool #:mcp-tool-class #:tool-handle)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:result #:text-content #:make-ht #:rpc-error)
  (:import-from #:dsmr-mcp/src/state #:*mode*)
  (:import-from #:dsmr-mcp/src/hermetic/pool
                #:pool-status-info)
  ;; closer-mop: c2mop:ensure-finalized is called after the defclass below.
  ;; MUST be declared here or the cold build fails ("Package CLOSER-MOP does not exist").
  (:import-from #:closer-mop)
  ;; com.inuoe.jzon: pool-status stringifies the pool-status-info hash-table.
  ;; MUST be declared here or the cold build fails ("Package COM.INUOE.JZON does not exist").
  (:import-from #:com.inuoe.jzon))

(in-package #:dsmr-mcp/src/tools/pool-status)

(defclass pool-status-tool (mcp-tool)
  ;; CRITICAL: use :initform on class-allocated slots, NOT :default-initargs.
  ;; c2mop:class-prototype does not apply :default-initargs so the metaclass
  ;; registration :after hook would see NIL and skip registration.
  ;; (src/tools/base.lisp lines 138-154; src/attach/dispatch.lisp lines 63-69.)
  ((dsmr-mcp/src/tools/base::name
    :allocation :class
    :initform "pool-status")
   (dsmr-mcp/src/tools/base::description
    :allocation :class
    :initform "Return the current status of the hermetic worker pool \
(active workers, standbys, session affinity map, circuit breaker state). \
Only available in hermetic mode. Returns pool_running, total_workers, \
standby_count, bound_count, max_pool_size, warmup_target, and a workers array.")
   (dsmr-mcp/src/tools/base::input-schema
    :allocation :class
    :initform '(:object :properties () :required ())))
  (:metaclass mcp-tool-class)
  (:documentation "MCP tool: return worker pool diagnostic information.
pool-status returns an informative isError when *mode* is not :hermetic
(the pool is not running). HERM-06 / OPS-03."))

(defmethod tool-handle ((tool pool-status-tool) id args)
  (declare (ignore args))
  (unless (eq *mode* :hermetic)
    (return-from tool-handle
      (result id (make-ht "isError" t
                          "content"
                          (text-content
                           "pool-status is only available in hermetic mode.")))))
  (let ((info (pool-status-info)))
    (result id (make-ht "isError" nil
                        "content"
                        (text-content (com.inuoe.jzon:stringify info))))))

;; CRITICAL: ensure-finalized must appear after defclass so the metaclass
;; finalize-inheritance :after hook fires at load time and registers
;; "pool-status" in *tool-classes*.
;; (src/tools/base.lisp line 162; src/attach/dispatch.lisp line 115.)
(c2mop:ensure-finalized (find-class 'pool-status-tool))
