;;;; src/tools/inspect-thread.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; inspect-thread MCP tool: VERB-17.  Enumerates threads in the attached
;;;; developer image (attached mode) or in the hermetic worker process
;;;; (hermetic mode), with optional per-thread backtrace capture.
;;;;
;;;; Attached path: builds a self-contained injected form (all helper symbols
;;;; interned in CL-USER with the %DSMR-MCP-ATTACH-THR-* prefix) and
;;;; evaluates it via bounded-slime-eval.  Returns a "threads" vector of
;;;; per-thread descriptors, each carrying "name", "alive", and optionally
;;;; "frames".
;;;;
;;;; Hermetic path: delegates to dispatch-hermetic-call which routes to the
;;;; worker's %handle-inspect-thread handler.
;;;;
;;;; Symbol hygiene: the injected form carries NO dsmr-mcp-package symbols.
;;;; Every binding variable is interned in CL-USER.  The structural guard
;;;; thread-form-is-portable in tests/attach/inspect-thread-test.lisp
;;;; verifies this property automatically.

(defpackage #:dsmr-mcp/src/tools/inspect-thread
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
  (:export #:inspect-thread-tool
           #:%build-attach-thread-form
           #:%dispatch-attach-inspect-thread))

(in-package #:dsmr-mcp/src/tools/inspect-thread)

;;; ---------------------------------------------------------------------------
;;; inspect-thread-tool CLOS class
;;;
;;; Mirrors inspect-object-tool: class-allocated name/description/input-schema
;;; with :initform (NOT :default-initargs); c2mop:ensure-finalized immediately
;;; after defclass so the metaclass :after method registers the tool at load
;;; time.
;;; ---------------------------------------------------------------------------

(defclass inspect-thread-tool (mcp-tool)
  ((dsmr-mcp/src/tools/base::name
    :allocation :class
    :initform "inspect-thread")
   (dsmr-mcp/src/tools/base::description
    :allocation :class
    :initform "Enumerate threads in the attached developer image or the \
hermetic worker process, with optional per-thread backtrace.  In attached \
mode the result reflects the live image's thread list.  In hermetic mode \
the result reflects the worker process's own threads.")
   (dsmr-mcp/src/tools/base::input-schema
    :allocation :class
    :initform '(:object
                :properties
                ((thread-id
                  :type :integer
                  :description "Reserved for future targeted backtrace capture. \
Currently accepted but not used for thread selection.")
                 (backtrace
                  :type :boolean
                  :description "When true, include a per-thread backtrace \
(SBCL only; capped at 20 frames).  Captures the eval thread's call stack."))
                :required ())))
  (:metaclass mcp-tool-class)
  (:documentation "MCP tool: enumerate threads in the attached image or
hermetic worker with optional backtrace.
VERB-17 — attached path uses bordeaux-threads:all-threads; hermetic path
enumerates the worker's own threads."))

;; ensure-finalized fires the metaclass :after method at load time,
;; registering "inspect-thread" in *tool-classes*.
(c2mop:ensure-finalized (find-class 'inspect-thread-tool))

;;; ---------------------------------------------------------------------------
;;; Injected-form builder
;;;
;;; Symbol hygiene rules (all mandatory -- see MEMORY.md / RESEARCH.md):
;;;   1. dolist not loop (loop keywords break the remote reader).
;;;   2. (code-char N) not #\X  (translating-read mangles dispatch chars).
;;;   3. (vector ...) not #()   (same translating-read issue).
;;;   4. (map 'string #'identity s) on ALL wire-bound strings (SIMPLE-BASE-STRING
;;;      prints as #A((N) BASE-CHAR ...) under *print-readably* -> reader error).
;;;   5. Every binding variable interned in CL-USER via (cs "...").
;;;   6. #+sbcl guard around all SBCL-specific backtrace code.
;;;
;;; Design note: interrupt-thread is intentionally avoided.  Cross-thread
;;; backtrace via interrupt-thread is async and requires a sleep; capturing
;;; only the current (eval) thread's backtrace via map-backtrace is simpler,
;;; race-free, and sufficient for the primary use case.
;;; ---------------------------------------------------------------------------

(defun %build-attach-thread-form (target-thread-id backtrace-p)
  "Return the sexp that, when evaluated in the attached image, enumerates
bordeaux-threads:all-threads and returns a list of per-thread plists.
Each plist carries :name, :alive, and (when BACKTRACE-P) :frames.

When BACKTRACE-P is true, the #+sbcl fragment captures the call stack of
the current (eval) thread via sb-debug:map-backtrace, capped at 20 frames,
and includes it in every thread entry.  The #-sbcl fallback yields nil.

TARGET-THREAD-ID is accepted for API parity and ignored; no interrupt-thread
call is issued (avoids async races and portability concerns).

No DSMR-MCP-package symbols cross the wire; the structural portability
guard thread-form-is-portable verifies this for both arities."
  (declare (ignore target-thread-id))
  (flet ((cs (n) (intern n (find-package :common-lisp-user))))
    (let ((s-acc    (cs "%DSMR-MCP-ATTACH-THR-ACC"))
          (s-t      (cs "%DSMR-MCP-ATTACH-THR-T"))
          (s-nm     (cs "%DSMR-MCP-ATTACH-THR-NM"))
          (s-map-fn (cs "%DSMR-MCP-ATTACH-THR-MAPFN"))
          (s-frames (cs "%DSMR-MCP-ATTACH-THR-FRAMES"))
          (s-fidx   (cs "%DSMR-MCP-ATTACH-THR-FIDX"))
          (s-frame  (cs "%DSMR-MCP-ATTACH-THR-FRAME"))
          (s-fcap   (cs "%DSMR-MCP-ATTACH-THR-FCAP"))
          (s-curbt  (cs "%DSMR-MCP-ATTACH-THR-CURBT")))
      (let ((s-nm-raw (cs "%DSMR-MCP-ATTACH-THR-NM-RAW")))
        (if backtrace-p
            `(let* ((,s-acc nil)
                    (,s-curbt
                      #+sbcl
                      (let ((,s-map-fn
                              (ignore-errors
                                (fdefinition
                                 (find-symbol "MAP-BACKTRACE" "SB-DEBUG"))))
                            (,s-frames nil)
                            (,s-fidx   0)
                            (,s-fcap   20))
                        (when ,s-map-fn
                          (funcall ,s-map-fn
                                   (lambda (,s-frame)
                                     (when (< ,s-fidx ,s-fcap)
                                       (push (list
                                              :index ,s-fidx
                                              :function
                                              (handler-case
                                                  (map 'string #'identity
                                                       (prin1-to-string
                                                        (sb-di:debug-fun-name
                                                         (sb-di:frame-debug-fun
                                                          ,s-frame))))
                                                (error () "<unknown>")))
                                             ,s-frames)
                                       (incf ,s-fidx))))
                          (nreverse ,s-frames)))
                      #-sbcl nil))
               (dolist (,s-t (bordeaux-threads:all-threads))
                 (let* ((,s-nm-raw (ignore-errors
                                     (bordeaux-threads:thread-name ,s-t)))
                        ;; bordeaux-threads:thread-name returns whatever the
                        ;; thread was named with — string, symbol, or anything
                        ;; printable.  Coerce defensively before (map 'string ...),
                        ;; which signals TYPE-ERROR on a non-string.  A handler-case
                        ;; ((error () ...)) around the conversion keeps a hostile
                        ;; name (e.g. an unprintable object) from corkscrewing the
                        ;; whole dolist into NETWORK_ERROR.
                        (,s-nm     (handler-case
                                       (cond ((stringp ,s-nm-raw) ,s-nm-raw)
                                             ((null   ,s-nm-raw) "unnamed")
                                             (t (princ-to-string ,s-nm-raw)))
                                     (error () "unnamed"))))
                   (push (list :name   (map 'string #'identity ,s-nm)
                               :alive  (handler-case
                                           (bordeaux-threads:thread-alive-p
                                            ,s-t)
                                         (error () nil))
                               :frames ,s-curbt)
                         ,s-acc)))
               (nreverse ,s-acc))
            `(let ((,s-acc nil))
               (dolist (,s-t (bordeaux-threads:all-threads))
                 (let* ((,s-nm-raw (ignore-errors
                                     (bordeaux-threads:thread-name ,s-t)))
                        (,s-nm     (handler-case
                                       (cond ((stringp ,s-nm-raw) ,s-nm-raw)
                                             ((null   ,s-nm-raw) "unnamed")
                                             (t (princ-to-string ,s-nm-raw)))
                                     (error () "unnamed"))))
                   (push (list :name  (map 'string #'identity ,s-nm)
                               :alive (handler-case
                                          (bordeaux-threads:thread-alive-p
                                           ,s-t)
                                        (error () nil)))
                         ,s-acc)))
               (nreverse ,s-acc)))))))

;;; ---------------------------------------------------------------------------
;;; Decode raw plist result into a wire hash-table
;;; ---------------------------------------------------------------------------

(defun %plist->thread-ht (plist)
  "Convert a single per-thread plist (:name S :alive B [:frames F]) to a
wire hash-table.  Coerces string values to element-type CHARACTER."
  (let ((ht (make-hash-table :test 'equal)))
    (setf (gethash "name"  ht) (let ((n (getf plist :name)))
                                  (if (stringp n)
                                      (map 'string #'identity n)
                                      "unnamed")))
    (setf (gethash "alive" ht) (if (getf plist :alive) t nil))
    (when (getf plist :frames)
      (let ((raw-frames (getf plist :frames)))
        (setf (gethash "frames" ht)
              (if (listp raw-frames)
                  (coerce
                   (mapcar (lambda (f)
                             (let ((fht (make-hash-table :test 'equal)))
                               (setf (gethash "index"    fht) (or (getf f :index) 0))
                               (setf (gethash "function" fht)
                                     (map 'string #'identity
                                          (or (getf f :function) "<unknown>")))
                               fht))
                           raw-frames)
                   'simple-vector)
                  (vector)))))
    ht))

;;; ---------------------------------------------------------------------------
;;; Attached dispatcher
;;; ---------------------------------------------------------------------------

(defun %dispatch-attach-inspect-thread (tool id params)
  "Dispatch inspect-thread to the attached Slynk server.

TOOL is the per-session repl-eval-tool instance.  ID is the JSON-RPC
request id (may be nil in direct test calls).  PARAMS is the tool argument
hash-table (or a fresh empty hash-table when nil).

Acquires the call-lock, evaluates the injected form via bounded-slime-eval,
and normalises the returned plist list to a 'threads' vector.

On slime-network-error returns a make-ht with isError t and
error_type NETWORK_ERROR without propagating the condition."
  (declare (ignore id))
  (let* ((p          (or params (make-hash-table :test 'equal)))
         (thread-id  (gethash "thread_id" p))
         (backtrace-p (gethash "backtrace" p))
         (form       (%build-attach-thread-form thread-id backtrace-p))
         (lock       (repl-eval-tool-call-lock tool)))
    (handler-case
        (let* ((raw (with-lock-held (lock)
                      (bounded-slime-eval form (repl-eval-tool-slynk-conn tool))))
               (threads (if (listp raw)
                            (coerce
                             (mapcar #'%plist->thread-ht raw)
                             'simple-vector)
                            (vector))))
          (make-ht "threads" threads))
      (slime-network-error (e)
        (log-event :warn "inspect-thread.attach.network-error"
                   "error" (handler-case (princ-to-string e) (error () "")))
        (return-from %dispatch-attach-inspect-thread
          (make-ht "isError"    t
                   "error_type" "NETWORK_ERROR"
                   "content"
                   (text-content
                    (format nil "inspect-thread: Slynk connection error: ~A" e))))))))

;;; ---------------------------------------------------------------------------
;;; tool-handle method
;;; ---------------------------------------------------------------------------

(defmethod tool-handle ((tool inspect-thread-tool) id args)
  "Route inspect-thread by *mode*.
Attached: resolve the repl-eval-tool and call %dispatch-attach-inspect-thread.
Hermetic: dispatch-hermetic-call routes to the worker inspect-thread handler.
Inline: returns a typed mode error."
  (ecase *mode*
    (:attached
     (let ((repl-tool (get-tool-instance (tool-session tool) "repl-eval")))
       (result id (%dispatch-attach-inspect-thread repl-tool id args))))
    (:hermetic
     (dispatch-hermetic-call (tool-session tool) id "inspect-thread" args))
    (:inline
     (rpc-error id -32603
                "inspect-thread requires attached or hermetic mode."))))
