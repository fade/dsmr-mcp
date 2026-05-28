;;;; src/tools/inspect-restart.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; inspect-restart MCP tool: VERB-18.  Surfaces the live restarts at a
;;;; debugger break in the attached image and optionally invokes one by index
;;;; or name.
;;;;
;;;; Attached path: calls Slynk slyfuns directly via bounded-slime-eval —
;;;; NOT via an injected code-string.  Uses debugger-info-for-emacs to list
;;;; restarts at the current break and invoke-nth-restart-for-emacs to invoke
;;;; a chosen restart by index.  The slyfun mechanism routes rex calls to the
;;;; break thread's sly-db-loop where *sly-db-restarts* is bound; plain
;;;; injected slime-eval forms cannot reach that dynamic scope.
;;;;
;;;; Symbol hygiene: there is no %build-*-form for this verb, so the usual
;;;; injected-form package-leak rules do not apply here.  Restart index
;;;; bounds-checking (against the listed restarts) is performed before any
;;;; invoke-nth-restart-for-emacs call.
;;;;
;;;; Post-invoke network-error tolerance: invoking a restart may unwind the
;;;; break thread and close its Slynk connection.  A slime-network-error after
;;;; a successful invoke is treated as expected behaviour (the break resolved),
;;;; not a dispatcher failure.
;;;;
;;;; Hermetic path: returns a structured empty restart set with an explanatory
;;;; message.  No hermetic worker has an interactive debugger break; this is
;;;; correct behaviour, not an error.

(defpackage #:dsmr-mcp/src/tools/inspect-restart
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
  (:import-from #:dsmr-mcp/src/attach/dispatch
                #:repl-eval-tool
                #:repl-eval-tool-slynk-conn
                #:repl-eval-tool-call-lock)
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
  (:export #:inspect-restart-tool
           #:%dispatch-attach-inspect-restart))

(in-package #:dsmr-mcp/src/tools/inspect-restart)

;;; ---------------------------------------------------------------------------
;;; inspect-restart-tool CLOS class
;;;
;;; Mirrors inspect-object-tool: class-allocated name/description/input-schema
;;; with :initform (NOT :default-initargs); c2mop:ensure-finalized immediately
;;; after defclass fires the metaclass :after method that registers the tool.
;;; ---------------------------------------------------------------------------

(defclass inspect-restart-tool (mcp-tool)
  ((dsmr-mcp/src/tools/base::name
    :allocation :class
    :initform "inspect-restart")
   (dsmr-mcp/src/tools/base::description
    :allocation :class
    :initform "List the live restarts at the current SLDB debugger break in \
the attached image, or invoke a chosen restart by index or name.  In attached \
mode this surfaces the restarts visible to the break thread (ABORT, CONTINUE, \
etc.) — the same menu a SLIME user sees.  Invoking a restart is state-changing: \
it unwinds the break thread's stack and resolves the break.  In hermetic mode \
there is no interactive break, so an empty restart set is returned.")
   (dsmr-mcp/src/tools/base::input-schema
    :allocation :class
    :initform '(:object
                :properties
                ((level
                  :type :integer
                  :description "SLDB level for the break to query or invoke against. \
Defaults to 1 (the first break level).  Must match *sly-db-level* in the break \
thread or an invoke call is silently ignored by Slynk.")
                 (invoke
                  :type :integer
                  :description "0-based index of the restart to invoke.  When \
supplied, bounds-checked against the listed restarts before the slyfun call.  \
Mutually exclusive with invoke_name; invoke takes precedence.")
                 (invoke_name
                  :type :string
                  :description "Name of the restart to invoke (e.g. \"ABORT\", \
\"CONTINUE\").  Case-insensitive match against the listed restart names.  \
Resolved to an index before the slyfun call.  Ignored when invoke is supplied."))
                :required ())))
  (:metaclass mcp-tool-class)
  (:documentation "MCP tool: list live SLDB restarts and optionally invoke one.
VERB-18 — attached path uses debugger-info-for-emacs / invoke-nth-restart-for-emacs
slyfuns; hermetic path returns a structured empty set."))

;; ensure-finalized fires the metaclass :after method at load time,
;; registering "inspect-restart" in *tool-classes*.
(c2mop:ensure-finalized (find-class 'inspect-restart-tool))

;;; ---------------------------------------------------------------------------
;;; Restart-entry coercion helper
;;;
;;; debugger-info-for-emacs RESTARTS element: a list of (name description)
;;; pairs.  Both name and description may arrive as SIMPLE-BASE-STRING on
;;; SBCL; coerce to CHARACTER element-type before putting on the wire.
;;; ---------------------------------------------------------------------------

(defun %restart-entry->ht (entry)
  "Convert a (NAME DESCRIPTION) restart entry from debugger-info-for-emacs
to a wire hash-table with string-coerced keys."
  (let ((ht   (make-hash-table :test 'equal))
        (name (car  entry))
        (desc (cadr entry)))
    (setf (gethash "name" ht)
          (map 'string #'identity (if name (princ-to-string name) "")))
    (setf (gethash "description" ht)
          (map 'string #'identity (or desc "")))
    ht))

;;; ---------------------------------------------------------------------------
;;; Resolve invoke_name to an index
;;;
;;; Linear scan over the restarts list from debugger-info-for-emacs, matching
;;; case-insensitively.  Returns NIL when no match.
;;; ---------------------------------------------------------------------------

(defun %find-restart-index (name restarts)
  "Return the 0-based index of the first restart in RESTARTS whose name
matches NAME case-insensitively, or NIL if not found.
RESTARTS is the second element of debugger-info-for-emacs's return value."
  (let ((name-up (string-upcase name)))
    (loop for entry in restarts
          for idx from 0
          when (string= (string-upcase (princ-to-string (car entry))) name-up)
            return idx)))

;;; ---------------------------------------------------------------------------
;;; Attached dispatcher
;;;
;;; Two paths:
;;;   LIST path (no invoke / invoke_name): calls debugger-info-for-emacs,
;;;     decodes RESTARTS into a wire vector.  Empty restarts → structured
;;;     empty set with message (not isError).
;;;   INVOKE path (invoke index or invoke_name present): lists restarts first
;;;     for bounds-checking, then calls invoke-nth-restart-for-emacs.
;;;     Post-invoke slime-network-error is treated as expected.
;;; ---------------------------------------------------------------------------

(defun %dispatch-attach-inspect-restart (tool id params)
  "Dispatch inspect-restart to the attached Slynk server.

TOOL is the per-session repl-eval-tool instance.  ID is the JSON-RPC request id
(may be nil in direct test calls).  PARAMS is the tool argument hash-table.

LIST path (default): calls (slynk:debugger-info-for-emacs START END) via the
rex mechanism and decodes the RESTARTS element.  Returns a make-ht with a
'restarts' simple-vector and 'condition' hash-table.  When no break is active
(empty RESTARTS), returns a structured empty set with a 'message', not isError.

INVOKE path (invoke index or invoke_name given): bounds-checks the index
against the listed restarts, then calls invoke-nth-restart-for-emacs.  A
slime-network-error after invoke is treated as expected (the break resolved),
returning a make-ht with 'invoked' t instead of surfacing the error.

On unexpected slime-network-error (LIST path, or non-post-invoke): logs and
returns a NETWORK_ERROR make-ht."
  (declare (ignore id))
  (let* ((p          (or params (make-hash-table :test 'equal)))
         (level      (or (gethash "level" p) 1))
         (invoke-idx (gethash "invoke" p))
         (invoke-nm  (gethash "invoke_name" p))
         (lock       (repl-eval-tool-call-lock tool))
         (conn       (repl-eval-tool-slynk-conn tool)))
    ;; LIST path: fetch debugger-info and decode.
    (let ((info (handler-case
                    (with-lock-held (lock)
                      (bounded-slime-eval
                       '(slynk:debugger-info-for-emacs 0 20)
                       conn))
                  (slime-network-error (e)
                    (log-event :warn "inspect-restart.attach.network-error"
                               "error"
                               (handler-case (princ-to-string e) (error () "")))
                    (return-from %dispatch-attach-inspect-restart
                      (make-ht "isError"    t
                               "error_type" "NETWORK_ERROR"
                               "content"
                               (text-content
                                (format nil
                                        "inspect-restart: Slynk connection error: ~A"
                                        e))))))))
      ;; debugger-info-for-emacs → (CONDITION-INFO RESTARTS FRAMES PENDING...)
      (let* ((condition-info (first  info))
             (raw-restarts   (second info))
             (restarts-vec   (if (and (listp raw-restarts) raw-restarts)
                                 (coerce (mapcar #'%restart-entry->ht raw-restarts)
                                         'simple-vector)
                                 (vector)))
             (condition-ht   (let ((ht (make-hash-table :test 'equal)))
                               (setf (gethash "message" ht)
                                     (map 'string #'identity
                                          (or (and (consp condition-info)
                                                   (car condition-info))
                                              "")))
                               (setf (gethash "type" ht)
                                     (map 'string #'identity
                                          (or (and (consp condition-info)
                                                   (cadr condition-info))
                                              "")))
                               ht)))
        ;; No active break → structured empty set, not isError.
        (when (zerop (length restarts-vec))
          (return-from %dispatch-attach-inspect-restart
            (make-ht "restarts" restarts-vec
                     "message"  "No active debugger break."
                     "level"    level)))
        ;; INVOKE path: resolve index, bounds-check, then invoke.
        (when (or invoke-idx invoke-nm)
          (let* ((resolved-idx
                   (cond
                     ;; Explicit integer index takes precedence.
                     ((integerp invoke-idx) invoke-idx)
                     ;; Resolve name to index.
                     (invoke-nm
                      (%find-restart-index invoke-nm raw-restarts))
                     (t nil))))
            (cond
              ((null resolved-idx)
               ;; invoke_name supplied but not found.
               (return-from %dispatch-attach-inspect-restart
                 (rpc-error nil -32602
                            (format nil
                                    "inspect-restart: restart name ~S not found in current break."
                                    invoke-nm))))
              ((or (< resolved-idx 0)
                   (>= resolved-idx (length restarts-vec)))
               ;; Out-of-range index.
               (return-from %dispatch-attach-inspect-restart
                 (rpc-error nil -32602
                            (format nil
                                    "inspect-restart: restart index ~D out of range (0–~D)."
                                    resolved-idx
                                    (1- (length restarts-vec))))))
              (t
               ;; Bounds check passed — invoke.
               (let ((invoke-result
                       (handler-case
                           (with-lock-held (lock)
                             (bounded-slime-eval
                              `(slynk:invoke-nth-restart-for-emacs ,level ,resolved-idx)
                              conn))
                         (slime-network-error ()
                           ;; Pitfall 4: break thread may exit and close the
                           ;; connection after a successful restart invoke.
                           ;; Treat this as expected — the break resolved.
                           :post-invoke-network-disconnect))))
                 (declare (ignore invoke-result))
                 (return-from %dispatch-attach-inspect-restart
                   (make-ht "invoked"  t
                            "index"   resolved-idx
                            "level"   level
                            "message" "Restart invoked; the break may have resolved.")))))))
        ;; LIST path result: restarts were found, no invoke requested.
        (make-ht "restarts"  restarts-vec
                 "condition" condition-ht
                 "level"     level)))))

;;; ---------------------------------------------------------------------------
;;; tool-handle method
;;; ---------------------------------------------------------------------------

(defmethod tool-handle ((tool inspect-restart-tool) id args)
  "Route inspect-restart by *mode*.
Attached: resolve the repl-eval-tool and call %dispatch-attach-inspect-restart.
Hermetic: dispatch-hermetic-call routes to the worker inspect-restart handler
which returns a structured empty set (no interactive break in a fresh worker).
Inline: returns a typed mode error."
  (ecase *mode*
    (:attached
     (let ((repl-tool (get-tool-instance (tool-session tool) "repl-eval")))
       (result id (%dispatch-attach-inspect-restart repl-tool id args))))
    (:hermetic
     (dispatch-hermetic-call (tool-session tool) id "inspect-restart" args))
    (:inline
     (rpc-error id -32603
                "inspect-restart requires attached or hermetic mode."))))
