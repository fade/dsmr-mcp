;;;; src/attach/dispatch.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; repl-eval-tool CLOS class, tool-handle specialisation for attached mode,
;;;; and the %dispatch-attach function that serialises slime-eval calls.
;;;; Re-implemented from cl-mcp/src/attach.lisp §391-477 (MIT) under AGPL.
;;;;
;;;; Key divergences from cl-mcp:
;;;;   Per-instance connection/lock slots, no global hash-tables.
;;;;   Fail-closed on network errors; drop-connection on slime-network-error.
;;;;   Reconnect note prepended to stdout when connection was reopened.
;;;;   detach-session closes the connection gracefully at session end.
;;;;   try-eager-connect opens the connection at session initialize time
;;;;   (NOT lazy-on-first-call); the post-death reopen shares the same
;;;;   get-or-open-connection path.

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
                #:session-notify-channel
                #:get-tool-instance
                #:tool-instances)
  (:import-from #:dsmr-mcp/src/notify
                #:emit)
  (:import-from #:dsmr-mcp/src/log
                #:log-event)
  (:import-from #:dsmr-mcp/src/attach/connection
                #:get-or-open-connection
                #:drop-connection
                #:close-connection
                #:parse-slynk-attach
                #:slynk-attach-configured-p
                #:bounded-slime-eval)
  (:import-from #:dsmr-mcp/src/attach/wrap-form
                #:build-wrapping-form
                #:truncate-output
                #:sanitize-control-chars
                #:*default-max-output-length*)
  (:import-from #:dsmr-mcp/src/attach/registry
                #:encode-object-id
                #:decode-object-id)
  (:import-from #:slynk-client
                #:slime-network-error)
  (:import-from #:bordeaux-threads
                #:with-lock-held
                #:make-lock)
  (:export #:repl-eval-tool
           #:repl-eval-tool-slynk-conn
           #:repl-eval-tool-call-lock
           #:repl-eval-tool-connection-epoch
           #:%dispatch-attach
           #:try-eager-connect
           #:detach-session
           #:*attach-call-lock*
           #:*attach-waiters*
           #:*attach-waiters-lock*
           #:*attach-holder-session-id*
           #:*attach-concurrency*
           #:with-serialised-attach-call
           #:%resolve-attach-concurrency))

(in-package #:dsmr-mcp/src/attach/dispatch)

;;; ---------------------------------------------------------------------------
;;; Process-wide attach call-lock and concurrency policy
;;; ---------------------------------------------------------------------------

(defparameter *attach-call-lock*
  (bordeaux-threads:make-lock "attach-call-lock")
  "Process-wide lock serialising attached-mode tool-handle calls.
Held for the duration of every bounded-slime-eval when *attach-concurrency*
is :serialised (the default).  Sessions operating in :parallel mode never
acquire this lock.  Hermetic mode is unaffected; hermetic workers run in
separate processes and are session-affined.")

(defparameter *attach-waiters-lock*
  (bordeaux-threads:make-lock "attach-waiters-lock")
  "Lock protecting *attach-waiters* and *attach-holder-session-id*.")

(defparameter *attach-waiters*
  nil
  "Ordered list of session-id strings currently waiting for *attach-call-lock*.
Entries are appended at enqueue and removed after the lock is acquired.
Protected by *attach-waiters-lock*.")

(defparameter *attach-holder-session-id*
  nil
  "Session-id string of the session currently holding *attach-call-lock*, or NIL.
Set to the entering session's id when the lock is acquired and reset to NIL
in the unwind-protect cleanup.  Protected by *attach-waiters-lock*.")

(defparameter *attach-concurrency*
  :serialised
  "Concurrency policy for attached-mode tool calls.
:SERIALISED (default) — *attach-call-lock* is held around every
  bounded-slime-eval so concurrent sessions take turns inside the developer's
  live image, preventing interleaved eval state.
:PARALLEL — lock is never acquired; concurrent sessions may race inside the
  image.  Only set this when you know the agents are read-mostly and will not
  corrupt shared image state.
Set once at startup from DSMR_ATTACH_CONCURRENCY; never toggled at runtime.")

;;; Concurrency env-var parser ------------------------------------------------

(defun %resolve-attach-concurrency (value)
  "Coerce VALUE (string or keyword) to :SERIALISED or :PARALLEL.
Signals INVALID-CONFIG-VALUE (from dsmr-mcp/src/run) for any other value."
  (let ((kw (etypecase value
               (keyword value)
               (string  (intern (string-upcase value) :keyword)))))
    (case kw
      (:serialised :serialised)
      (:parallel   :parallel)
      (t (error (find-symbol "INVALID-CONFIG-VALUE"
                             (find-package :dsmr-mcp/src/run))
                :name "DSMR_ATTACH_CONCURRENCY"
                :raw  value)))))

;;; Serialised-attach-call macro ----------------------------------------------

(defmacro with-serialised-attach-call ((session) &body body)
  "Execute BODY holding the process-wide *attach-call-lock* when
*attach-concurrency* is :SERIALISED, or execute BODY immediately when :PARALLEL.

Before blocking on the lock, emits a notifications/dsmr-mcp/attach/queued
notification over SESSION's notify-channel carrying the current waiter
position and holder_session_id.  The notification fires before the session
blocks so the client can render a status indicator immediately.

The position number reflects the length of *attach-waiters* at enqueue
time and is approximate — the mutex does not guarantee strict FIFO, so
position is advisory.

SESSION is a dsmr-mcp session object; its session-id and notify-channel
are used for the queued notification and the holder-tracking bookkeeping."
  (let ((session-var (gensym "SESSION"))
        (sid-var     (gensym "SID"))
        (pos-var     (gensym "POSITION"))
        (holder-var  (gensym "HOLDER")))
    `(if (eq *attach-concurrency* :parallel)
         (progn ,@body)
         (let* ((,session-var ,session)
                (,sid-var     (session-id ,session-var))
                ,pos-var
                ,holder-var)
           ;; Register this session in the waiter list and snapshot the
           ;; current holder before blocking.  Protected by *attach-waiters-lock*.
           (bordeaux-threads:with-lock-held (*attach-waiters-lock*)
             (setf *attach-waiters*
                   (append *attach-waiters* (list ,sid-var)))
             (setf ,pos-var   (length *attach-waiters*))
             (setf ,holder-var *attach-holder-session-id*))
           ;; Emit the queued notification BEFORE blocking so the client sees
           ;; it immediately.  Only fire when there is actually a holder
           ;; (position > 0 and holder is non-nil means we will have to wait).
           (when (and (> ,pos-var 0) ,holder-var)
             (emit (session-notify-channel ,session-var)
                   "notifications/dsmr-mcp/attach/queued"
                   (make-ht "position"          ,pos-var
                            "holder_session_id" ,holder-var)))
           ;; Acquire the process-wide lock.  bordeaux-threads:with-lock-held
           ;; blocks here until the current holder releases it.
           (bordeaux-threads:with-lock-held (*attach-call-lock*)
             ;; Announce ourselves as the holder under the waiters lock so
             ;; concurrently-enqueueing sessions read the current holder-id.
             ;; Must use setf (not dynamic let) so all threads see the update.
             (bordeaux-threads:with-lock-held (*attach-waiters-lock*)
               (setf *attach-holder-session-id* ,sid-var))
             (unwind-protect
                  (progn ,@body)
               ;; Cleanup under the waiters lock: remove from the waiter list
               ;; and clear the global holder-id.
               (bordeaux-threads:with-lock-held (*attach-waiters-lock*)
                 (setf *attach-waiters*
                       (remove ,sid-var *attach-waiters* :test #'string= :count 1))
                 (setf *attach-holder-session-id* nil))))))))

;;; repl-eval-tool CLOS class -------------------------------------------------
;;;
;;; Class-allocated name/description/input-schema use :initform (NOT
;;; :default-initargs) because c2mop:class-prototype does not apply
;;; :default-initargs; the metaclass registration :after method reads those
;;; slots via class-prototype and would see NIL if :default-initargs were used.
;;; (See src/tools/base.lisp lines 150-154 for the metaclass registration detail.)

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
                  :description "Maximum characters for captured stdout/stderr output (default: 50000).")
                 (register-result
                  :type :boolean
                  :description "When true (the default), registers the last form's first \
return value in the image-resident handle table and returns result_object_id. \
Set to false to suppress registration for hot loops or uninteresting results."))
                :required ("code")))
   ;; Per-instance (per-session) connection state — NOT :allocation :class.
   ;; One connection cache per session, living on the tool instance.
   (slynk-conn
    :initform nil
    :accessor repl-eval-tool-slynk-conn
    :documentation "Cached slynk-connection for this session, or NIL.
Set by get-or-open-connection; nilled by drop-connection on network error.")
   ;; Per-session call-serialisation lock.
   (call-lock
    :initform (bordeaux-threads:make-lock "dsmr-repl-eval-lock")
    :reader repl-eval-tool-call-lock
    :documentation "Serialises concurrent slime-eval calls on this session's connection.")
   ;; Per-session connection-incarnation epoch counter.
   (connection-epoch
    :initform 0
    :accessor repl-eval-tool-connection-epoch
    :documentation "Monotonic integer incremented on each drop-connection call.
Embedded in result_object_id so that IDs minted before a connection drop carry
a stale epoch and can be short-circuited to a registry-reset error at lookup
time without a round-trip to the image."))
  (:metaclass mcp-tool-class)
  (:documentation "MCP tool: evaluate Lisp forms in the attached Slynk image.
Per-session slots carry the connection, call-serialisation lock, and
connection-incarnation epoch so sessions are fully isolated from each other."))

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
;;; JSON shape:
;;;   condition_type, message, restarts (array of {name,description}),
;;;   frames (array of {index,function,source_file,source_line,locals}).

(defun %build-error-context-ht (error-context effective-limit)
  "Convert the wrap-form error-context plist to a JSON-encodable hash-table.
Returns an equal-keyed hash-table suitable for jzon encoding.

All string fields originating in the remote image are routed through
sanitize-control-chars.  The :message field is additionally bounded
by EFFECTIVE-LIMIT via truncate-output so it is consistent with the cap
applied to printed/stdout/stderr.  Per-value local truncation (~200 chars)
applied in the wrap-form remains in effect — this sanitisation is in
addition to, not instead of, those existing bounds."
  (let* ((ht (make-hash-table :test 'equal))
         (ctype   (getf error-context :condition-type))
         (message (getf error-context :message))
         (restarts (getf error-context :restarts))
         (frames   (getf error-context :frames)))
    ;; condition_type: sanitise for consistency.
    (setf (gethash "condition_type" ht)
          (sanitize-control-chars (or ctype "")))
    ;; message: sanitise + bound by effective-limit.
    (setf (gethash "message" ht)
          (truncate-output (sanitize-control-chars (or message "")) effective-limit))
    ;; Restarts: list of (:name S :description S) plists -> array of hash-tables.
    ;; Each string sanitised.
    (setf (gethash "restarts" ht)
          (coerce
           (mapcar (lambda (r)
                     (make-ht "name"        (sanitize-control-chars (or (getf r :name) ""))
                              "description" (sanitize-control-chars (or (getf r :description) ""))))
                   (or restarts '()))
           'simple-vector))
    ;; Frames: list of (:index N :function S :locals L) plists -> array of hash-tables.
    ;; function name and each local value sanitised.
    (setf (gethash "frames" ht)
          (coerce
           (mapcar (lambda (f)
                     (let* ((locals (getf f :locals))
                            (locals-vec
                              (coerce
                               (mapcar (lambda (lv)
                                         (make-ht "name"  (sanitize-control-chars (or (getf lv :name) ""))
                                                  "value" (sanitize-control-chars (or (getf lv :value) ""))))
                                       (or locals '()))
                               'simple-vector)))
                       (make-ht "index"       (or (getf f :index) 0)
                                "function"    (sanitize-control-chars (or (getf f :function) ""))
                                "source_file" (or (getf f :source-file) "")
                                "source_line" (or (getf f :source-line) 0)
                                "locals"      locals-vec)))
                   (or frames '()))
           'simple-vector))
    ht))

;;; Response builder ----------------------------------------------------------
;;;
;;; Adapted from cl-mcp/src/tools/response-builders.lisp §77-169 (MIT) under AGPL.

(defun build-eval-response (printed stdout stderr error-context effective-limit
                            &key result-object-id)
  "Build the repl-eval response hash-table from the dispatcher-side processed
fields (truncation and sanitisation already applied to printed/stdout/stderr).

EFFECTIVE-LIMIT is threaded through to %build-error-context-ht so the
error_context message field is bounded consistently with the other output fields.

RESULT-OBJECT-ID when non-nil is the already-encoded wire string (epoch:sess:id)
added as the \"result_object_id\" key and appended to the enriched content text.

Returns a hash-table with:
  \"content\"         : text-content array with enriched text (value + context)
  \"stdout\"          : captured stdout string
  \"stderr\"          : captured stderr string
  \"error_context\"   : (only when error-context non-nil) structured hash-table
                       with condition_type, message, restarts, frames
  \"result_object_id\": (only when result-object-id non-nil) the object handle
                       string for use with inspect-object"
  (let ((ht (make-hash-table :test 'equal)))
    (setf (gethash "stdout" ht) (or stdout ""))
    (setf (gethash "stderr" ht) (or stderr ""))
    (when error-context
      (setf (gethash "error_context" ht)
            (%build-error-context-ht error-context effective-limit)))
    (when result-object-id
      (setf (gethash "result_object_id" ht) result-object-id))
    ;; Build enriched text for content[].text.
    (let ((enriched
            (with-output-to-string (s)
              (write-string (or printed "") s)
              (when result-object-id
                (format s "~&[object-id: ~A]" result-object-id))
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
;;; Translates global-table slot access to per-instance slot access.

(defun %dispatch-attach (tool params)
  "Dispatch a repl-eval call to the attached Slynk server.

TOOL is the per-session repl-eval-tool instance carrying the cached
connection, call-lock, and connection-epoch slots. PARAMS is the equal-keyed
argument hash-table from the tools/call request.

Serialises slime-eval under the per-session call-lock. On slime-network-error:
drops the dead connection and returns a structured isError envelope; the next
call reopens on demand. When the connection was nil and reopened successfully,
prepends a reconnect note to the stdout field.

When register_result is true (the default) and the last form's result is
inspectable, the response includes a result_object_id encoded as
epoch:session-id:raw-id. The epoch is the current connection-incarnation epoch
so IDs minted before a drop-connection can be detected as stale."
  (let* ((code              (gethash "code" params))
         (package-name      (gethash "package" params))
         (max-output-length (gethash "max_output_length" params))
         ;; register_result: absent or true => t; explicit jzon false/nil => nil.
         (register-result   (let ((v (gethash "register_result" params :missing)))
                              (if (eq v :missing) t (not (null v)))))
         (reconnectedp      nil))
    ;; Validate code parameter.
    (unless (and (stringp code) (plusp (length code)))
      (return-from %dispatch-attach
        (make-ht "isError" t
                 "content"
                 (text-content
                  "attach: 'code' parameter is required and must be a non-empty string."))))
    ;; Resolve host/port from the session slynk-attach config string.
    ;; Parse once; reuse host/port for both the guard check and the live path.
    (multiple-value-bind (host port)
        (parse-slynk-attach (session-slynk-attach (tool-session tool)))
      ;; Fail-fast guard: config was present at dispatch gate but could not be parsed.
      (unless (and host port)
        (return-from %dispatch-attach
          (make-ht "isError" t
                   "content"
                   (text-content
                    "attach: :slynk-attach config is missing or malformed."))))
      (handler-case
          (let* (;; Acquire lock BEFORE get-or-open-connection so concurrent
                 ;; first-callers cannot both see conn=nil and both open a connection,
                 ;; leaking one socket on the Slynk listener side.
                 (lock (repl-eval-tool-call-lock tool))
                 (raw-result
                   (with-lock-held (lock)
                     ;; Track whether we are opening a new connection (reconnect path).
                     ;; Check BEFORE get-or-open-connection; the flag captures whether
                     ;; the slot was nil at entry, not after the open.
                     (when (null (repl-eval-tool-slynk-conn tool))
                       (setf reconnectedp t))
                     (let* ((conn     (get-or-open-connection tool host port))
                            (sess-id  (session-id (tool-session tool)))
                            (form     (build-wrapping-form code package-name
                                                           :register-result register-result
                                                           :session-id sess-id)))
                       ;; Bounded slime-eval inside the lock: a lost reply
                       ;; becomes a clean slime-network-error after the timeout
                       ;; instead of blocking the caller indefinitely.
                       (bounded-slime-eval form conn :timeout 30)))))
            ;; Destructure the 6-element result tuple from the remote image.
            ;; Shape: (printed raw stdout stderr error-context raw-id-or-nil)
            ;; Pad with nils when the remote returns a shorter list (defensive).
            (let* ((result-list
                     (if (listp raw-result)
                         (let ((r raw-result))
                           (append r (loop repeat (max 0 (- 6 (length r)))
                                          collect nil)))
                         (list (princ-to-string raw-result)
                               raw-result "" "" nil nil)))
                   (printed       (first  result-list))
                   ;; raw (second) ignored: raw == printed.
                   (stdout        (or (third  result-list) ""))
                   (stderr        (or (fourth result-list) ""))
                   (error-context (fifth  result-list))
                   (raw-id-or-nil (sixth  result-list))
                   (effective-limit (or (and (integerp max-output-length)
                                             (plusp max-output-length)
                                             max-output-length)
                                        *default-max-output-length*))
                   ;; Compute result_object_id. Suppress on the reconnect path:
                   ;; the just-reinstalled table holds nothing prior; do not hand
                   ;; back an id whose epoch the caller cannot have seen.
                   (result-object-id
                     (when (and raw-id-or-nil (not reconnectedp))
                       (encode-object-id (repl-eval-tool-connection-epoch tool)
                                         (session-id (tool-session tool))
                                         raw-id-or-nil))))
              ;; Apply truncation+sanitise to the main output fields.
              ;; Reconnect note prepended to stdout AFTER truncation so the note
              ;; is never silently dropped when effective-limit is very small.
              (let ((trunc-stdout (truncate-output stdout effective-limit)))
                (when reconnectedp
                  (setf trunc-stdout
                        (concatenate 'string
                                     "[reconnected to Slynk listener -- in-image state may have reset]"
                                     (string #\Newline)
                                     trunc-stdout)))
                (build-eval-response
                 (truncate-output (or printed "") effective-limit)
                 trunc-stdout
                 (truncate-output stderr          effective-limit)
                 error-context
                 effective-limit
                 :result-object-id result-object-id))))
        (slime-network-error (e)
          ;; Fail-closed: nil the cached connection so next call reopens.
          (drop-connection tool :reason "network-error")
          (log-event :warn "attach.network-error"
                     "error" (handler-case (princ-to-string e)
                               (error () "")))
          (make-ht "isError" t
                   "content"
                   (text-content
                    (format nil "attach: Slynk connection error: ~A" e))))))))

;;; Attach-dispatch gate macro ------------------------------------------------
;;;
;;; Adapted from cl-mcp/src/attach.lisp §463-477 (MIT) under AGPL.
;;; Gates on the session slynk-attach config string being non-nil/non-empty
;;; (via slynk-attach-configured-p) rather than a global attach-active-p flag.

(defmacro with-attach-dispatch ((id tool params) &body body)
  "When the tool session has a configured :slynk-attach target, route the
call to the attached Slynk server inside with-serialised-attach-call, then
return (result ID (%dispatch-attach TOOL PARAMS)), short-circuiting BODY.
Otherwise evaluate BODY.

ID is the JSON-RPC request id. TOOL must be the repl-eval-tool instance.
PARAMS is the equal-keyed argument hash-table from the tools/call request.

The with-serialised-attach-call wrapper ensures all attached tool calls
observe *attach-concurrency* policy: sessions serialise through
*attach-call-lock* by default, giving each session exclusive access to
the developer's live image for the duration of the eval."
  (let ((tool-sym    (gensym "TOOL"))
        (id-sym      (gensym "ID"))
        (params-sym  (gensym "PARAMS"))
        (session-sym (gensym "SESSION")))
    ;; Bind the argument forms once so callers can pass side-effecting
    ;; expressions (or anything other than a parameter access) without
    ;; observing them re-evaluated in each macro-expanded position.
    `(let* ((,tool-sym ,tool)
            (,id-sym ,id)
            (,params-sym ,params)
            (,session-sym (tool-session ,tool-sym)))
       (if (slynk-attach-configured-p (session-slynk-attach ,session-sym))
           (with-serialised-attach-call (,session-sym)
             (result ,id-sym (%dispatch-attach ,tool-sym ,params-sym)))
           (progn ,@body)))))

;;; tool-handle method --------------------------------------------------------

(defmethod tool-handle ((tool repl-eval-tool) id args)
  "Dispatch the repl-eval tool call. Routes to the attached Slynk server
when :slynk-attach is configured (with-attach-dispatch). The fallback (no
Slynk listener configured) returns a -32603 error; hermetic mode dispatch
replaces this body when the session is in hermetic mode."
  (with-attach-dispatch (id tool args)
    (rpc-error id -32603
               "repl-eval requires an attached Slynk listener.")))

;;; Session lifecycle hooks ---------------------------------------------------

(defun try-eager-connect (session)
  "Open the Slynk connection eagerly at session-initialize time.
When :slynk-attach is configured, finds the repl-eval-tool instance and
calls get-or-open-connection. On slime-network-error logs a :warn event and
returns NIL so the initialize response is never derailed — the next call will
reconnect via the same get-or-open-connection path.
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
  "Gracefully close the Slynk connection for SESSION.
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
