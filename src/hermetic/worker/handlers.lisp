;;;; src/hermetic/worker/handlers.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Method handlers for hermetic worker JSON-RPC server.
;;;; Current verb surface: worker/eval only.
;;;;
;;;; register-all-handlers wires the single handler into the server.
;;;; The handler function takes a params hash-table and returns a
;;;; hash-table payload; worker/server.lisp wraps it in the JSON-RPC
;;;; result envelope.
;;;;
;;;; %handle-eval implements attached/hermetic repl-eval output parity via
;;;; build-wrapping-form + eval + build-eval-response — the same pipeline
;;;; as the attached path with local eval replacing slime-eval. A per-call
;;;; soft timeout (sb-ext:with-timeout) guards against runaway evaluations
;;;; while keeping the worker alive for subsequent calls.

(defpackage #:dsmr-mcp/src/hermetic/worker/handlers
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/hermetic/worker/server #:register-method)
  (:import-from #:dsmr-mcp/src/attach/wrap-form
                #:build-wrapping-form #:truncate-output
                #:*default-max-output-length*)
  (:import-from #:dsmr-mcp/src/attach/dispatch
                #:build-eval-response)
  (:import-from #:dsmr-mcp/src/hermetic/worker/inspect
                #:inspect-object-by-id
                #:build-inspect-response
                #:generate-result-preview)
  (:import-from #:dsmr-mcp/src/hermetic/worker/registry
                #:register-object
                #:inspectable-p)
  (:import-from #:dsmr-mcp/src/code-core
                #:code-find-definition
                #:code-describe-symbol
                #:code-find-references)
  (:import-from #:dsmr-mcp/src/system-loader-core
                #:load-system)
  (:import-from #:dsmr-mcp/src/test-runner-core
                #:run-tests)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:make-ht
                #:text-content)
  (:import-from #:dsmr-mcp/src/log #:log-event)
  (:import-from #:bordeaux-threads
                #:all-threads
                #:thread-name
                #:thread-alive-p)
  (:import-from #:sb-ext)
  (:import-from #:uiop)
  (:export #:register-all-handlers #:*default-eval-timeout*))

(in-package #:dsmr-mcp/src/hermetic/worker/handlers)

;;; ---------------------------------------------------------------------------
;;; Configuration
;;; ---------------------------------------------------------------------------

(defparameter *default-eval-timeout*
  (let ((v (uiop:getenv "DSMR_WORKER_EVAL_TIMEOUT")))
    (if (and v (not (string= v "")))
        (max 1 (parse-integer v :junk-allowed t))
        120))
  "Default per-call eval timeout in seconds. Workers serving autonomous agents
need a bounded default to prevent runaway evaluations.
Override via DSMR_WORKER_EVAL_TIMEOUT environment variable.")

;;; ---------------------------------------------------------------------------
;;; worker/eval handler
;;; ---------------------------------------------------------------------------

(defun %handle-eval (params registry)
  "Evaluate code in-process and return the response structure.

Reads code / package / timeout_seconds / max_output_length / register_result
from PARAMS. Builds the wrapping form via build-wrapping-form with
:surface-raw-value t, evaluates it once inside sb-ext:with-timeout, then
calls build-eval-response — the same pipeline as the attached path, giving
identical output regardless of whether the eval runs in attached or hermetic
mode.

When register_result is true (the default) and the eval succeeds with an
inspectable result, registers the live value in REGISTRY and adds
result_object_id to the response. The live value is the 7th element of the
wrapping-form result list — the actual Lisp object returned by the last
evaluated form, captured during the single evaluation. No re-read or
re-eval of the user code occurs; side effects run exactly once and the
registered object is the same instance the eval returned.

On sb-ext:with-timeout expiry the worker returns a structured TIMEOUT result
and SURVIVES — the condition is caught, not re-signalled.

Returns a hash-table payload; worker/server.lisp wraps it in the JSON-RPC
result envelope before sending to the dispatcher."
  (let* ((code              (gethash "code"             params))
         (package-name      (gethash "package"          params))
         (timeout-seconds   (gethash "timeout_seconds"  params))
         (max-output-length (gethash "max_output_length" params))
         ;; Distinguish absent key (default true) from explicit false.
         (register-result
           (multiple-value-bind (val presentp)
               (gethash "register_result" params)
             (if presentp val t))))
    (unless code
      (error "code is required"))
    ;; :surface-raw-value t adds a 7th element to the result list: the live
    ;; Lisp object from the last evaluated form.  This lets us register the
    ;; actual result in REGISTRY from a single evaluation of the user code.
    (let* ((form (build-wrapping-form code package-name :surface-raw-value t))
           (result-list
             (handler-case
                 (sb-ext:with-timeout (or timeout-seconds *default-eval-timeout*)
                   (eval form))
               (sb-ext:timeout ()
                 (list (format nil "TIMEOUT after ~As"
                               (or timeout-seconds *default-eval-timeout*))
                       nil "" ""
                       (list :condition-type "SB-EXT:TIMEOUT"
                             :message (format nil "Evaluation timed out after ~A seconds"
                                              (or timeout-seconds *default-eval-timeout*))
                             :restarts nil :frames nil)
                       nil nil))))
           (printed       (first  result-list))
           (stdout        (or (third  result-list) ""))
           (stderr        (or (fourth result-list) ""))
           (error-context (fifth  result-list))
           ;; 7th element: live Lisp object from the last form, NIL on error.
           (raw-value     (seventh result-list))
           (effective-limit (or (and (integerp max-output-length)
                                     (plusp max-output-length)
                                     max-output-length)
                                *default-max-output-length*))
           (response
             (build-eval-response
              (truncate-output (or printed "") effective-limit)
              (truncate-output stdout effective-limit)
              (truncate-output stderr effective-limit)
              error-context effective-limit)))
      ;; Register the result object when: no error, register_result true,
      ;; and the live value is inspectable.  The value came from the single
      ;; wrapping-form eval above — no second eval of the user code occurs.
      (when (and register-result (null error-context) raw-value
                 (inspectable-p raw-value))
        (let ((id (register-object raw-value registry)))
          (when id
            (setf (gethash "result_object_id" response) id))))
      response)))

;;; ---------------------------------------------------------------------------
;;; Code-intelligence handlers (worker/code-find, /code-describe, /code-find-references)
;;;
;;; Each handler reads its arguments from the params hash-table, validates the
;;; required "symbol" arg, wraps the in-process code-core call in
;;; sb-ext:with-timeout, and builds the same wire envelope the attached path
;;; produces. The worker survives a timeout — the condition is caught and a
;;; structured TIMEOUT isError is returned.
;;; ---------------------------------------------------------------------------

(defun %build-not-found-response (marker)
  "Convert a typed not-found marker plist from code-core into a wire envelope."
  (let* ((kind  (getf marker :not-found))
         (name  (getf marker :name))
         (hint  (getf marker :hint))
         (etype (ecase kind
                  (:package  "package-not-found")
                  (:symbol   "symbol-not-found")
                  (:source-location "found-but-no-source-location"))))
    (make-ht "isError"    t
             "error_type" etype
             "content"
             (vector (make-ht "type" "text"
                              "text" (format nil "~@[~A: ~]~A" name hint))))))

(defun %not-found-marker-p (result)
  "Return T when RESULT is a typed not-found marker plist from code-core.
Not-found markers start with :not-found as the first plist key (a keyword at
position 0 of the outer list). Location lists are lists-of-plists where the
first element is a cons (:path ...), not a keyword. This lets the handlers
distinguish the two without calling getf on a list-of-plists, which would
signal a malformed-property-list error."
  (and (consp result)
       (eq (car result) :not-found)))

(defun %describe-result-p (result)
  "Return T when RESULT is a successful code-describe plist (starts with :name)."
  (and (consp result)
       (eq (car result) :name)))

(defun %handle-code-find (params registry)
  "Worker handler for code-find: calls code-core in-process inside a timeout.
Reads \"symbol\" (required), \"package\" (optional), and \"project_root\" (optional)
from PARAMS. When \"project_root\" is present, paths under that root are returned
relative (no leading separator); paths outside it remain absolute.
Returns the locations wire envelope or a typed not-found isError."
  (declare (ignore registry))
  (let* ((symbol-name  (gethash "symbol"       params))
         (package-name (gethash "package"      params))
         (project-root (gethash "project_root" params)))
    (unless (and (stringp symbol-name) (plusp (length symbol-name)))
      (error "symbol is required"))
    (handler-case
        (sb-ext:with-timeout 30
          (let ((result (code-find-definition symbol-name
                                              :package package-name
                                              :root project-root)))
            (cond
              ;; Typed not-found marker: outer list starts with :not-found.
              ((%not-found-marker-p result)
               (%build-not-found-response result))
              ;; Location list (may be empty — treat as symbol-not-found when empty).
              ((null result)
               (make-ht "isError"    t
                        "error_type" "symbol-not-found"
                        "content"
                        (vector (make-ht "type" "text"
                                         "text"
                                         (format nil "Symbol ~S not found in image. \
Try load-system first, or clgrep-search for text search." symbol-name)))))
              ((listp result)
               (let ((locs (mapcar (lambda (loc)
                                     (make-ht "path" (or (getf loc :path) "")
                                              "line" (or (getf loc :line) 0)
                                              "kind" (or (getf loc :kind) "")))
                                   result)))
                 (make-ht "locations" (coerce locs 'simple-vector))))
              (t
               (make-ht "isError"    t
                        "error_type" "symbol-not-found"
                        "content"
                        (vector (make-ht "type" "text"
                                         "text" "Unexpected result from code-find.")))))))
      (sb-ext:timeout ()
        (make-ht "isError"    t
                 "error_type" "TIMEOUT"
                 "content"
                 (vector (make-ht "type" "text"
                                  "text" "code-find timed out (30s)")))))))

(defun %handle-code-describe (params registry)
  "Worker handler for code-describe: calls code-core in-process inside a timeout.
Reads \"symbol\" (required), \"package\" (optional), and \"project_root\" (optional)
from PARAMS. When \"project_root\" is present, the source path in the response is
returned relative for files under that root; paths outside it remain absolute.
Returns the describe wire envelope or a typed not-found isError."
  (declare (ignore registry))
  (let* ((symbol-name  (gethash "symbol"       params))
         (package-name (gethash "package"      params))
         (project-root (gethash "project_root" params)))
    (unless (and (stringp symbol-name) (plusp (length symbol-name)))
      (error "symbol is required"))
    (handler-case
        (sb-ext:with-timeout 30
          (let ((result (code-describe-symbol symbol-name
                                              :package package-name
                                              :root    project-root)))
            (cond
              ;; Typed not-found marker: outer list starts with :not-found.
              ((%not-found-marker-p result)
               (%build-not-found-response result))
              ;; Describe plist: starts with :name.
              ((%describe-result-p result)
               (make-ht "name"    (or (getf result :name)    "")
                        "type"    (or (getf result :type)    "")
                        "arglist" (or (getf result :arglist) "()")
                        "doc"     (or (getf result :doc)     "")
                        "path"    (or (getf result :path)    "")
                        "line"    (or (getf result :line)    0)))
              (t
               (make-ht "isError"    t
                        "error_type" "symbol-not-found"
                        "content"
                        (vector (make-ht "type" "text"
                                         "text"
                                         (format nil "Symbol ~S not found. \
Try load-system first, or clgrep-search for text search." symbol-name))))))))
      (sb-ext:timeout ()
        (make-ht "isError"    t
                 "error_type" "TIMEOUT"
                 "content"
                 (vector (make-ht "type" "text"
                                  "text" "code-describe timed out (30s)")))))))

(defun %handle-code-find-references (params registry)
  "Worker handler for code-find-references: calls code-core in-process inside a
timeout. Reads \"symbol\" (required), \"package\", \"project_only\", \"relation\",
and \"project_root\" (optional) from PARAMS. project_only defaults to true.
When \"project_root\" is present, paths under that root are returned relative and
the project_only filter uses it as the boundary.
Returns the references wire envelope or a typed error."
  (declare (ignore registry))
  (let* ((symbol-name  (gethash "symbol"       params))
         (package-name (gethash "package"      params))
         ;; project_only defaults to true when key is absent.
         (project-only (multiple-value-bind (val presentp)
                           (gethash "project_only" params)
                         (if presentp val t)))
         (relation     (gethash "relation"     params))
         (project-root (gethash "project_root" params)))
    (unless (and (stringp symbol-name) (plusp (length symbol-name)))
      (error "symbol is required"))
    (handler-case
        (sb-ext:with-timeout 30
          (let ((result (code-find-references symbol-name
                                              :package      package-name
                                              :project-only project-only
                                              :root         project-root
                                              :relation     (and (stringp relation)
                                                                 (plusp (length relation))
                                                                 relation))))
            (cond
              ;; Typed not-found marker: outer list starts with :not-found.
              ((%not-found-marker-p result)
               (%build-not-found-response result))
              ;; NIL or list of reference plists.
              (t
               (let ((refs (mapcar (lambda (ref)
                                     (make-ht "path"     (or (getf ref :path)     "")
                                              "line"     (or (getf ref :line)     0)
                                              "caller"   (or (getf ref :caller)   "")
                                              "relation" (or (getf ref :relation) "")))
                                   (or result '()))))
                 (make-ht "references" (coerce refs 'simple-vector)))))))
      (sb-ext:timeout ()
        (make-ht "isError"    t
                 "error_type" "TIMEOUT"
                 "content"
                 (vector (make-ht "type" "text"
                                  "text" "code-find-references timed out (30s)")))))))

;;; ---------------------------------------------------------------------------
;;; Public API
;;; ---------------------------------------------------------------------------

(defun %handle-inspect-object (params registry)
  "Inspect a registered object by ID. Returns the cl-mcp envelope shape.
REGISTRY is the per-worker object-registry instance passed at handler
registration. The id parameter is the raw integer ID (the dispatcher
strips the epoch/session prefix before forwarding)."
  (let* ((object-id    (gethash "id"           params))
         (max-depth    (or (gethash "max_depth"    params) 1))
         (max-elements (or (gethash "max_elements" params) 50)))
    (unless object-id
      (error "id is required"))
    (let ((result (inspect-object-by-id object-id registry
                                        :max-depth    max-depth
                                        :max-elements max-elements)))
      (build-inspect-response result))))

(defun %handle-load-system (params registry)
  "Worker handler for load-system: calls system-loader-core:load-system
in-process (already inside the worker) and returns the structured result.
The core's own sb-ext:with-timeout applies, so a runaway compile is
interrupted within the worker. The pool's pool-rpc-with-hard-kill provides
the outer hard-kill backstop.

Reads system (required), force (boolean, default true), clear_fasls
(boolean, default false), and timeout_seconds (integer, default 120) from
PARAMS. Returns the make-ht wire envelope produced by load-system."
  (declare (ignore registry))
  (let* ((sys-name        (gethash "system"          params))
         (force           (multiple-value-bind (v presentp)
                              (gethash "force" params)
                            (if presentp v t)))   ; default true when absent
         (clear-fasls     (gethash "clear_fasls"     params))
         (timeout-seconds (or (gethash "timeout_seconds" params) 120)))
    (unless (and (stringp sys-name) (plusp (length sys-name)))
      (error "system is required"))
    ;; load-system from system-loader-core wraps the work in
    ;; sb-ext:with-timeout internally, so a runaway compile is interrupted
    ;; within this handler call.
    (load-system sys-name
                 :force           force
                 :clear-fasls     clear-fasls
                 :timeout-seconds timeout-seconds)))

(defun %handle-run-tests (params registry)
  "Worker handler for run-tests: calls test-runner-core:run-tests in-process
and returns the structured result envelope.

The core's own sb-ext:with-timeout applies (300 s default), so a runaway
test run is interrupted within the worker. The pool's pool-rpc-with-hard-kill
provides the outer hard-kill backstop.

Reads system (required), framework, test, tests, timeout_seconds (default 300),
and reload (boolean, default true) from PARAMS."
  (declare (ignore registry))
  (let* ((sys-name        (gethash "system"          params))
         (framework       (gethash "framework"       params))
         (test            (gethash "test"            params))
         (tests           (gethash "tests"           params))
         (timeout-seconds (or (gethash "timeout_seconds" params) 300))
         ;; reload defaults true when key is absent.
         (reload          (multiple-value-bind (v presentp)
                              (gethash "reload" params)
                            (if presentp v t))))
    (unless (and (stringp sys-name) (plusp (length sys-name)))
      (error "system is required"))
    ;; Normalize tests from JSON array (vector) to list when present.
    (let ((tests-list (when tests
                        (if (vectorp tests)
                            (coerce tests 'list)
                            tests))))
      ;; test-runner-core:run-tests wraps the work in sb-ext:with-timeout
      ;; internally, so a runaway test is interrupted within this handler.
      (run-tests sys-name
                 :framework framework
                 :test test
                 :tests tests-list
                 :timeout-seconds timeout-seconds
                 :reload reload))))

(defun %handle-inspect-thread (params registry)
  "Enumerate threads in the worker process.
Returns a make-ht with a 'threads' simple-vector of per-thread entries,
each carrying 'name' and 'alive'.  When 'backtrace' is true, also captures
the current thread's call stack (SBCL only) and includes it in every entry.
Interrupting arbitrary worker threads is intentionally avoided.

REGISTRY is accepted but ignored — thread enumeration needs no registry."
  (declare (ignore registry))
  (let* ((backtrace-p (gethash "backtrace" params))
         (map-fn      #+sbcl
                      (when backtrace-p
                        (ignore-errors
                          (fdefinition (find-symbol "MAP-BACKTRACE" "SB-DEBUG"))))
                      #-sbcl nil)
         (cur-frames  (when map-fn
                        (let ((frames nil)
                              (fidx   0)
                              (fcap   20))
                          (funcall map-fn
                                   (lambda (frame)
                                     (when (< fidx fcap)
                                       (push (make-ht
                                              "index"    fidx
                                              "function" (or
                                                          (ignore-errors
                                                            (map 'string #'identity
                                                                 (prin1-to-string
                                                                  (sb-di:debug-fun-name
                                                                   (sb-di:frame-debug-fun frame)))))
                                                          "<unknown>"))
                                             frames)
                                       (incf fidx))))
                          (nreverse frames))))
         (threads     (mapcar
                       (lambda (thr)
                         ;; Defensive name coercion: thread-name returns
                         ;; whatever was passed to make-thread :name (a
                         ;; symbol or any printable object is allowed).
                         ;; Coerce to a string before placing on the wire
                         ;; so (map 'string ...) cannot signal TYPE-ERROR.
                         (let* ((raw-name (ignore-errors (thread-name thr)))
                                (name-str (handler-case
                                              (cond ((stringp raw-name) raw-name)
                                                    ((null   raw-name) "unnamed")
                                                    (t (princ-to-string
                                                        raw-name)))
                                            (error () "unnamed")))
                                (ht (make-ht
                                     "name"  (map 'string #'identity name-str)
                                     "alive" (if (handler-case
                                                     (thread-alive-p thr)
                                                   (error () nil))
                                                 t nil))))
                           (when cur-frames
                             (setf (gethash "frames" ht)
                                   (coerce cur-frames 'simple-vector)))
                           ht))
                       (all-threads))))
    (make-ht "threads" (coerce threads 'simple-vector))))

(defun %handle-inspect-restart (params registry)
  "Return a structured empty restart set for the hermetic worker.
No interactive debugger break exists in a fresh hermetic worker, so this
handler always returns an empty 'restarts' vector with an explanatory message.
This is correct behaviour, not an error — the verb is valid, it simply has
no active restarts to surface."
  (declare (ignore params registry))
  (make-ht "restarts" (vector)
           "message"  "No active debugger break in hermetic mode."))

(defun %handle-inspect-condition (params registry)
  "Inspect a held condition object by registry ID.
Reads the required \"id\" param (a raw integer registry ID as forwarded by the
hermetic dispatcher) and reuses inspect-object-by-id + build-inspect-response
from worker/inspect.lisp — the same in-process SB-MOP path as %handle-inspect-object.

REGISTRY is the per-worker object-registry instance holding the condition."
  (let* ((object-id    (gethash "id" params))
         (max-depth    (or (gethash "max_depth"    params) 1))
         (max-elements (or (gethash "max_elements" params) 50)))
    (unless object-id
      (error "id is required"))
    (let ((result (inspect-object-by-id object-id registry
                                        :max-depth    max-depth
                                        :max-elements max-elements)))
      (build-inspect-response result))))

(defun register-all-handlers (server registry)
  "Register all worker method handlers on SERVER.
REGISTRY is the per-worker object-registry instance; it is closed over by
the handler lambdas so each call shares the same per-process registry.

Registered methods:
  worker/eval                  — evaluate code and return a response
  worker/inspect-object        — inspect a registered object by ID
  worker/code-find             — locate definition(s) for a symbol
  worker/code-describe         — describe a symbol's type/arglist/docstring
  worker/code-find-references  — find xref callers/references for a symbol
  worker/load-system           — load an ASDF system with force/timeout/warning capture
  worker/run-tests             — run tests with framework detection and ghost-purge
  worker/inspect-thread        — enumerate worker threads with optional backtrace
  worker/inspect-restart       — return structured empty restart set (no break in worker)
  worker/inspect-condition     — inspect a held condition object by registry ID"
  (register-method server "worker/eval"
                   (lambda (params) (%handle-eval params registry)))
  (register-method server "worker/inspect-object"
                   (lambda (params) (%handle-inspect-object params registry)))
  (register-method server "worker/code-find"
                   (lambda (params) (%handle-code-find params registry)))
  (register-method server "worker/code-describe"
                   (lambda (params) (%handle-code-describe params registry)))
  (register-method server "worker/code-find-references"
                   (lambda (params) (%handle-code-find-references params registry)))
  (register-method server "worker/load-system"
                   (lambda (params) (%handle-load-system params registry)))
  (register-method server "worker/run-tests"
                   (lambda (params) (%handle-run-tests params registry)))
  (register-method server "worker/inspect-thread"
                   (lambda (params) (%handle-inspect-thread params registry)))
  (register-method server "worker/inspect-restart"
                   (lambda (params) (%handle-inspect-restart params registry)))
  (register-method server "worker/inspect-condition"
                   (lambda (params) (%handle-inspect-condition params registry)))
  (log-event :info "worker.handlers.registered" "count" 10)
  server)
