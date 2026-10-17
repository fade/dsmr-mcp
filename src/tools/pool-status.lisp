;;;; src/tools/pool-status.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; MCP tool: pool-status.
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
standby_count, bound_count, max_pool_size, warmup_target, and a workers array.
\
When the host runs short of memory, an idle worker may be hibernated: its \
whole Lisp world is saved to a core file on disk, its process ends, and it is \
resumed with that world on your next call. Threads, open files and sockets, \
timers, values from get-internal-real-time and foreign memory do not survive \
hibernation, so a worker running threads of its own is never hibernated. An \
idle worker that holds no state may be stopped instead, and your next call \
gets a fresh one with nothing lost.
\
Each worker also reports stateful (it has run a call that can leave state \
behind), busy (a call is holding it now), boot (core, source or resumed: how \
its process started), last_activity (Unix seconds of its last call), \
core_bytes (the size of its last saved core), core_age_seconds (how long it \
has been hibernated), last_hibernate_ms and last_resume_ms (how long its last \
save and resume took), and refused_reason (why its last hibernation was \
refused). The pool also reports hibernated_count and resident_count (workers \
on disk and workers with a running process), pressure_relief (active when the \
pool is answering a live host memory service), worker_core (the core new \
workers boot from, or null) and worker_core_status (in use, unset, missing, \
or disabled with the reason).")
   (dsmr-mcp/src/tools/base::input-schema
    :allocation :class
    :initform '(:object :properties () :required ())))
  (:metaclass mcp-tool-class)
  (:documentation "MCP tool: return worker pool diagnostic information.
pool-status returns an informative isError when *mode* is not :hermetic
(the pool is not running)."))

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
