;;;; src/attach/dispatch.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; repl-eval-tool CLOS class, tool-handle specialisation for attached mode,
;;;; and the %dispatch-attach function that serialises slime-eval calls.
;;;; Re-implemented from cl-mcp/src/attach.lisp §391-477 (MIT) under AGPL.
;;;;
;;;; Key divergences from cl-mcp:
;;;;   D-14/D-15: per-instance connection/lock slots, no global hash-tables.
;;;;   D-16: fail-closed network errors; drop-connection on slime-network-error.
;;;;   D-17: reconnect note prepended to stdout when connection was reopened.
;;;;   D-18: detach-session closes the connection gracefully at session end.
;;;;   D-13: try-eager-connect opens the connection at session initialize time
;;;;         (NOT lazy-on-first-call); the post-death reopen shares the same
;;;;         get-or-open-connection path.

(defpackage #:dsmr-mcp/src/attach/dispatch
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
  (:import-from #:dsmr-mcp/src/state
                #:session
                #:session-id
                #:session-slynk-attach
                #:get-tool-instance
                #:tool-instances)
  (:import-from #:dsmr-mcp/src/log
                #:log-event)
  (:import-from #:dsmr-mcp/src/attach/connection
                #:get-or-open-connection
                #:drop-connection
                #:close-connection
                #:parse-slynk-attach
                #:slynk-attach-configured-p)
  (:import-from #:dsmr-mcp/src/attach/wrap-form
                #:build-wrapping-form
                #:truncate-output
                #:*default-max-output-length*)
  (:import-from #:slynk-client
                #:slime-eval
                #:slime-network-error)
  (:import-from #:bordeaux-threads
                #:with-lock-held
                #:make-lock)
  (:export #:repl-eval-tool
           #:repl-eval-tool-slynk-conn
           #:repl-eval-tool-call-lock
           #:%dispatch-attach
           #:try-eager-connect
           #:detach-session))

(in-package #:dsmr-mcp/src/attach/dispatch)

;;; repl-eval-tool CLOS class -------------------------------------------------
;;;
;;; Class-allocated name/description/input-schema use :initform (NOT
;;; :default-initargs) because c2mop:class-prototype does not apply
;;; :default-initargs; the metaclass registration :after method reads those
;;; slots via class-prototype and would see NIL if :default-initargs were used.
;;; (See src/tools/base.lisp lines 150-154 and 02-PATTERNS.md cross-cutting note 2.)

(defclass repl-eval-tool (mcp-tool)
  ((dsmr-mcp/src/tools/base::name
    :allocation :class
    :initform "repl-eval")
   (dsmr-mcp/src/tools/base::description
    :allocation :class
    :initform "Evaluate Common Lisp forms in the attached Slynk image. \
Returns printed values, captured stdout/stderr, and structured error context \
(condition type, message, restarts, SBCL backtrace frames). \
Requires :slynk-attach / DSMR_SLYNK_ATTACH to be configured.")
   (dsmr-mcp/src/tools/base::input-schema
    :allocation :class
    :initform '(:object
                :properties
                ((code
                  :type :string
                  :description "One or more top-level Common Lisp forms to evaluate.")
                 (package
                  :type :string
                  :description "Package name in which to evaluate; defaults to CL-USER.")
                 (max-output-length
                  :type :integer
                  :description "Maximum characters for captured stdout/stderr output (default: 50000)."))
                :required ("code")))
   ;; Per-instance (per-session) connection state — NOT :allocation :class.
   ;; (D-14): one connection cache per session, living on the tool instance.
   (slynk-conn
    :initform nil
    :accessor repl-eval-tool-slynk-conn
    :documentation "Cached slynk-connection for this session, or NIL.
Set by get-or-open-connection; nilled by drop-connection on network error (D-16).")
   ;; (D-15): per-session call-serialisation lock (ATTACH-03).
   (call-lock
    :initform (bordeaux-threads:make-lock "dsmr-repl-eval-lock")
    :reader repl-eval-tool-call-lock
    :documentation "Serialises concurrent slime-eval calls on this session's connection (ATTACH-03, D-15)."))
  (:metaclass mcp-tool-class)
  (:documentation "MCP tool: evaluate Lisp forms in the attached Slynk image.
Per-session slots carry the connection and call-serialisation lock so sessions
are fully isolated from each other (D-14, T-02-DISP-03)."))

;; CRITICAL: ensure-finalized must appear after defclass so the metaclass
;; :after finalize-inheritance method fires at load time and registers
;; \"repl-eval\" in *tool-classes*. (See src/tools/base.lisp line 162.)
(c2mop:ensure-finalized (find-class 'repl-eval-tool))

;;; Error-context hash-table builder ------------------------------------------
;;;
;;; Converts the wrap-form error-context plist into JSON-encodable hash-tables.
;;; Plist shape: (:condition-type S :message S
;;;               :restarts ((:name S :description S) ...)
;;;               :frames   ((:index N :function S :locals L) ...))
;;; JSON shape (RESEARCH.md §3 / 02-03-PLAN.md Task 1 action):
;;;   condition_type, message, restarts (array of {name,description}),
;;;   frames (array of {index,function,source_file,source_line,locals}).

(defun %build-error-context-ht (error-context)
  "Convert the wrap-form error-context plist to a JSON-encodable hash-table.
Returns an equal-keyed hash-table suitable for jzon encoding."
  (let* ((ht (make-hash-table :test 'equal))
         (ctype   (getf error-context :condition-type))
         (message (getf error-context :message))
         (restarts (getf error-context :restarts))
         (frames   (getf error-context :frames)))
    (setf (gethash "condition_type" ht) (or ctype ""))
    (setf (gethash "message"        ht) (or message ""))
    ;; Restarts: list of (:name S :description S) plists -> array of hash-tables.
    (setf (gethash "restarts" ht)
          (coerce
           (mapcar (lambda (r)
                     (make-ht "name"        (or (getf r :name) "")
                              "description" (or (getf r :description) "")))
                   (or restarts '()))
           'simple-vector))
    ;; Frames: list of (:index N :function S :locals L) plists -> array of hash-tables.
    (setf (gethash "frames" ht)
          (coerce
           (mapcar (lambda (f)
                     (let* ((locals (getf f :locals))
                            (locals-vec
                              (coerce
                               (mapcar (lambda (lv)
                                         (make-ht "name"  (or (getf lv :name) "")
                                                  "value" (or (getf lv :value) "")))
                                       (or locals '()))
                               'simple-vector)))
                       (make-ht "index"       (or (getf f :index) 0)
                                "function"    (or (getf f :function) "")
                                "source_file" (or (getf f :source-file) "")
                                "source_line" (or (getf f :source-line) 0)
                                "locals"      locals-vec)))
                   (or frames '()))
           'simple-vector))
    ht))

;;; Response builder ----------------------------------------------------------
;;;
;;; Adapted from cl-mcp/src/tools/response-builders.lisp §77-169 (MIT) under
;;; AGPL. Phase 2 omits result_object_id / result_preview (ATTACH-09, Phase 5).

(defun build-eval-response (printed stdout stderr error-context)
  "Build the repl-eval response hash-table from the dispatcher-side processed
fields (truncation and sanitisation already applied).

Returns a hash-table with:
  \"content\"       : text-content array with enriched text (value + context)
  \"stdout\"        : captured stdout string
  \"stderr\"        : captured stderr string
  \"error_context\" : (only when error-context non-nil) structured hash-table
                     with condition_type, message, restarts, frames

Phase 2 does NOT include result_object_id / result_preview (those are ATTACH-09,
deferred to Phase 5)."
  (let ((ht (make-hash-table :test 'equal)))
    (setf (gethash "stdout" ht) (or stdout ""))
    (setf (gethash "stderr" ht) (or stderr ""))
    (when error-context
      (setf (gethash "error_context" ht)
            (%build-error-context-ht error-context)))
    ;; Build enriched text for content[].text (cl-mcp §117-161 pattern;
    ;; Phase 2 simplified — no object-id section).
    (let ((enriched
            (with-output-to-string (s)
              (write-string (or printed "") s)
              (when (and stdout (plusp (length stdout)))
                (format s "~&~%;; stdout~%~A" stdout))
              (when (and stderr (plusp (length stderr)))
                (format s "~&~%;; stderr~%~A" stderr))
              (when error-context
                (let ((ctype   (getf error-context :condition-type))
                      (msg     (getf error-context :message))
                      (restarts (getf error-context :restarts))
                      (frames   (getf error-context :frames)))
                  (format s "~&~%[~A] ~A"
                          (or ctype "ERROR")
                          (or msg ""))
                  (when restarts
                    (format s "~&Restarts: ~{~A~^, ~}"
                            (mapcar (lambda (r) (or (getf r :name) ""))
                                    restarts)))
                  (when frames
                    (format s "~&Backtrace:")
                    (loop for frame in frames
                          for shown from 1
                          do (format s "~&  ~A: ~A"
                                     (or (getf frame :index) "?")
                                     (or (getf frame :function) ""))
                          until (>= shown 5))))))))
      (setf (gethash "content" ht) (text-content enriched)))
    ht))

;;; Main dispatcher -----------------------------------------------------------
;;;
;;; Adapted from cl-mcp/src/attach.lisp §391-461 (MIT) under AGPL.
;;; Translates global-table slot access to per-instance slot access (D-14/D-15).

(defun %dispatch-attach (tool params)
  "Dispatch a repl-eval call to the attached Slynk server.

TOOL is the per-session repl-eval-tool instance carrying the cached
connection and call-lock slots. PARAMS is the equal-keyed argument
hash-table from the tools/call request.

Serialises slime-eval under the per-session call-lock (ATTACH-03, D-15).
On slime-network-error: drops the dead connection and returns a structured
isError envelope; the next call reopens on demand (D-16, criterion 3).
When the connection was nil and reopened successfully, prepends the D-17
reconnect note to the stdout field."
  (let* ((code              (gethash "code" params))
         (package-name      (gethash "package" params))
         (max-output-length (gethash "max_output_length" params))
         (reconnectedp      nil))
    ;; Validate code parameter.
    (unless (and (stringp code) (plusp (length code)))
      (return-from %dispatch-attach
        (make-ht "isError" t
                 "content"
                 (text-content
                  "attach: 'code' parameter is required and must be a non-empty string."))))
    ;; Resolve host/port from the session slynk-attach config string.
    (let* ((attach-config (session-slynk-attach (tool-session tool))))
      (multiple-value-bind (host port)
          (parse-slynk-attach attach-config)
        ;; Fail-fast guard: config was present at dispatch gate but could not be parsed.
        (unless (and host port)
          (return-from %dispatch-attach
            (make-ht "isError" t
                     "content"
                     (text-content
                      "attach: :slynk-attach config is missing or malformed.")))))
      (multiple-value-bind (host port)
          (parse-slynk-attach attach-config)
        (handler-case
            (let* (;; Track whether we are opening a new connection (reconnect path).
                   ;; Check BEFORE calling get-or-open-connection so the flag captures
                   ;; whether the slot was nil at entry, not after the open.
                   (was-nil (null (repl-eval-tool-slynk-conn tool)))
                   (conn    (progn
                              (when was-nil (setf reconnectedp t))
                              (get-or-open-connection tool host port)))
                   (lock    (repl-eval-tool-call-lock tool))
                   (form    (build-wrapping-form code package-name))
                   ;; ATTACH-03 / D-15: serialise the slime-eval call.
                   (raw-result (with-lock-held (lock)
                                 (slime-eval form conn))))
              ;; Destructure the 5-element result tuple from the remote image.
              ;; Shape: (printed raw stdout stderr error-context)
              ;; Pad with nils when the remote returns a shorter list (defensive).
              (let* ((result-list
                       (if (listp raw-result)
                           (let ((r raw-result))
                             (append r (loop repeat (max 0 (- 5 (length r)))
                                            collect nil)))
                           (list (princ-to-string raw-result)
                                 raw-result "" "" nil)))
                     (printed       (first  result-list))
                     ;; raw (second) ignored: raw == printed per D-05/b2c9812f.
                     (stdout        (or (third  result-list) ""))
                     (stderr        (or (fourth result-list) ""))
                     (error-context (fifth  result-list))
                     (effective-limit (or (and (integerp max-output-length)
                                               (plusp max-output-length)
                                               max-output-length)
                                          *default-max-output-length*)))
                ;; D-17: reconnect note prepended to stdout when connection was reopened.
                (when reconnectedp
                  (setf stdout
                        (concatenate 'string
                                     "[reconnected to Slynk listener -- in-image state may have reset]"
                                     (string #\Newline)
                                     stdout)))
                ;; Apply truncation+sanitise (D-11/D-12) in the dispatcher,
                ;; not in the remote image (RESEARCH.md §3 "truncation and sanitisation").
                (build-eval-response
                 (truncate-output (or printed "") effective-limit)
                 (truncate-output stdout          effective-limit)
                 (truncate-output stderr          effective-limit)
                 error-context)))
          (slime-network-error (e)
            ;; D-16 fail-closed: nil the cached connection so next call reopens.
            (drop-connection tool :reason "network-error")
            (log-event :warn "attach.network-error"
                       "error" (handler-case (princ-to-string e)
                                 (error () "")))
            (make-ht "isError" t
                     "content"
                     (text-content
                      (format nil "attach: Slynk connection error: ~A" e)))))))))

;;; Attach-dispatch gate macro ------------------------------------------------
;;;
;;; Adapted from cl-mcp/src/attach.lisp §463-477 (MIT) under AGPL.
;;; Gates on the session slynk-attach config string being non-nil/non-empty
;;; (via slynk-attach-configured-p) rather than a global attach-active-p flag.

(defmacro with-attach-dispatch ((id tool params) &body body)
  "When the tool session has a configured :slynk-attach target, route the
call to the attached Slynk server and return (result ID (%dispatch-attach TOOL PARAMS)),
short-circuiting BODY. Otherwise evaluate BODY.

ID is the JSON-RPC request id. TOOL must be the repl-eval-tool instance.
PARAMS is the equal-keyed argument hash-table from the tools/call request."
  `(if (slynk-attach-configured-p
        (session-slynk-attach (tool-session ,tool)))
       (result ,id (%dispatch-attach ,tool ,params))
       (progn ,@body)))

;;; tool-handle method --------------------------------------------------------

(defmethod tool-handle ((tool repl-eval-tool) id args)
  "Dispatch the repl-eval tool call. Routes to the attached Slynk server
when :slynk-attach is configured (with-attach-dispatch). In Phase 2, the
fallback (no Slynk listener configured) returns a -32603 error; Phase 3
replaces this body with the hermetic mode dispatch."
  (with-attach-dispatch (id tool args)
    (rpc-error id -32603
               "repl-eval requires an attached Slynk listener.")))

;;; Session lifecycle hooks ---------------------------------------------------

(defun try-eager-connect (session)
  "Open the Slynk connection eagerly at session-initialize time (D-13).
When :slynk-attach is configured, finds the repl-eval-tool instance and
calls get-or-open-connection. On slime-network-error logs a :warn event and
returns NIL so the initialize response is never derailed (D-13 rationale:
fail fast and visibly, but not fatally — the next call will reconnect via
the same get-or-open-connection path).
Returns NIL in all cases."
  (let ((attach-config (session-slynk-attach session)))
    (when (slynk-attach-configured-p attach-config)
      (let ((tool (get-tool-instance session "repl-eval")))
        (when tool
          (multiple-value-bind (host port)
              (parse-slynk-attach attach-config)
            (when (and host port)
              (handler-case
                  (get-or-open-connection tool host port)
                (slime-network-error (e)
                  (log-event :warn "attach.eager-connect.failed"
                             "host" (or host "")
                             "port" (or port "")
                             "error" (handler-case (princ-to-string e)
                                       (error () "")))
                  nil))))))))
  nil)

(defun detach-session (session)
  "Gracefully close the Slynk connection for SESSION (D-18, ATTACH-08).
Iterates the session's tool-instances and calls close-connection on any
repl-eval-tool instance that carries an open connection. This ensures the
host Slynk listener receives a clean FIN rather than a reset-by-peer.
Returns NIL in all cases."
  (maphash (lambda (name instance)
             (declare (ignore name))
             (when (typep instance 'repl-eval-tool)
               (close-connection instance :reason "session-end")))
           (tool-instances session))
  nil)
