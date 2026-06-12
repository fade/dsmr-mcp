;;;; src/run.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Top-level entry point for dsmr-mcp: resolves keyword/env/conf precedence
;;;; and dispatches to the appropriate transport.  All three transports are
;;;; served: :stdio blocks reading the wire (returns T at EOF); :tcp and
;;;; :http start their listeners after the loopback bind check.
;;;;
;;;; Config precedence: keyword > DSMR_<KEYWORD> env var > .dsmr-mcp.conf > built-in default.
;;;; .dsmr-mcp.conf is read via ubiquitous:value (never defaulted-value, which writes the
;;;; file on first read); absence is silent.
;;;;
;;;; src/main.lisp owns the dsmr-mcp:run re-export nickname.  DO NOT edit src/main.lisp.

(defpackage #:dsmr-mcp/src/run
  (:use #:cl)
  (:local-nicknames (#:ubiquitous #:ubiquitous))
  (:import-from #:dsmr-mcp/src/transport/stdio
                #:serve-streams
                #:isolate-stdio-wire)
  (:import-from #:dsmr-mcp/src/state
                #:make-session
                #:*mode*)
  (:import-from #:dsmr-mcp/src/log
                #:log-event
                #:set-log-level-from-env
                #:*log-level*
                #:configure-log4cl-for-server)
  (:import-from #:dsmr-mcp/src/attach/connection
                #:parse-slynk-attach)
  (:import-from #:dsmr-mcp/src/attach/dispatch
                #:*attach-concurrency*
                #:%resolve-attach-concurrency)
  (:import-from #:dsmr-mcp/src/hermetic/pool
                #:initialize-pool #:shutdown-pool #:release-session)
  (:import-from #:usocket)
  (:import-from #:sb-ext)
  ;; process-json-line is re-exported from here so src/main.lisp's
  ;; existing :import-from dsmr-mcp/src/run #:process-json-line
  ;; continues to resolve. The canonical definition lives in
  ;; dsmr-mcp/src/protocol; this export shadows
  ;; the stub that was previously defined locally in this package.
  (:shadowing-import-from #:dsmr-mcp/src/protocol
                          #:process-json-line)
  (:export #:run
           #:resolve-transport
           #:resolve-mode
           #:%check-remote-bind
           #:transport-not-implemented-error
           #:invalid-config-value
           #:invalid-config-value-name
           #:invalid-config-value-raw
           #:process-json-line))

(in-package #:dsmr-mcp/src/run)

;;; ---------------------------------------------------------------------------
;;; Conditions
;;; ---------------------------------------------------------------------------

(define-condition transport-not-implemented-error (error)
  ((transport :initarg :transport :reader transport-not-implemented-transport))
  (:report (lambda (c s)
             (format s "Transport ~A is not yet implemented."
                     (transport-not-implemented-transport c))))
  (:documentation "Retained for callers and tests that assert a transport
does NOT signal it: all three transports (:stdio, :tcp, :http) are served,
so RUN no longer signals this condition for any accepted transport value."))

(define-condition invalid-config-value (error)
  ((name :initarg :name :reader invalid-config-value-name
         :documentation "Name of the config key or env var (e.g. \"DSMR_TRANSPORT\").")
   (raw  :initarg :raw  :reader invalid-config-value-raw
         :documentation "The raw value that was rejected."))
  (:report (lambda (c s)
             (format s "Invalid value ~S for ~A"
                     (invalid-config-value-raw c)
                     (invalid-config-value-name c))))
  (:documentation "Signaled when a DSMR_* environment variable or conf entry carries
a value that cannot be coerced to the expected type.  Typed so callers can catch
config errors distinctly from other run failures."))

;;; ---------------------------------------------------------------------------
;;; Parse helpers
;;; ---------------------------------------------------------------------------

(defun %parse-transport (value)
  "Coerce VALUE (string or keyword) to one of :STDIO, :TCP, or :HTTP.
Signals INVALID-CONFIG-VALUE for any other value so env-var mistakes
produce a human-readable typed error rather than a raw case-failure."
  (let ((kw (etypecase value
               (keyword value)
               (string  (intern (string-upcase value) :keyword)))))
    (case kw
      (:stdio :stdio)
      (:tcp   :tcp)
      (:http  :http)
      (t (error 'invalid-config-value
                :name "DSMR_TRANSPORT"
                :raw  value)))))

(defun %parse-mode (value)
  "Coerce VALUE (string or keyword) to one of :ATTACHED, :HERMETIC, or :AUTO.
Signals INVALID-CONFIG-VALUE for any other value."
  (let ((kw (etypecase value
               (keyword value)
               (string  (intern (string-upcase value) :keyword)))))
    (case kw
      (:attached :attached)
      (:hermetic :hermetic)
      (:auto     :auto)
      (t (error 'invalid-config-value
                :name "DSMR_MODE"
                :raw  value)))))

(defun %parse-log-level (value)
  "Coerce VALUE (string or keyword) to one of :DEBUG, :INFO, :WARN, or :ERROR.
Signals INVALID-CONFIG-VALUE for any other value."
  (let ((kw (etypecase value
               (keyword value)
               (string  (intern (string-upcase value) :keyword)))))
    (case kw
      (:debug :debug)
      (:info  :info)
      (:warn  :warn)
      (:error :error)
      (t (error 'invalid-config-value
                :name "DSMR_LOG_LEVEL"
                :raw  value)))))

;;; ---------------------------------------------------------------------------
;;; Conf reader
;;; ---------------------------------------------------------------------------

(defun %read-conf-into-defaults (project-root)
  "Read .dsmr-mcp.conf at PROJECT-ROOT (if present) and return a plist of
config values.  Returns NIL when the file is absent (absence is silent,
no file is created).

Uses ubiquitous:value (NEVER defaulted-value, which writes the file on first
read) inside with-local-storage :transaction nil so no automatic offload occurs."
  (let ((path (merge-pathnames ".dsmr-mcp.conf" project-root)))
    (when (probe-file path)
      (ubiquitous:with-local-storage (path :type :lisp :transaction nil)
        (list :transport    (ubiquitous:value :transport)
              :mode         (ubiquitous:value :mode)
              :port         (ubiquitous:value :port)
              :bind         (ubiquitous:value :bind)
              :log-level    (ubiquitous:value :log-level)
              :slynk-attach (ubiquitous:value :slynk-attach))))))

;;; ---------------------------------------------------------------------------
;;; Precedence helper
;;; ---------------------------------------------------------------------------

(defun %or-from-env (supplied-p keyword-value env-name conf-plist default
                     &key (parse #'identity))
  "Apply keyword > env > conf > default precedence for one config value.

SUPPLIED-P     -- the supplied-p flag from the &key lambda-list.
KEYWORD-VALUE  -- value the caller passed explicitly (only consulted when SUPPLIED-P).
ENV-NAME       -- DSMR_* environment variable name (e.g. \"DSMR_TRANSPORT\").
CONF-PLIST     -- plist from %READ-CONF-INTO-DEFAULTS, or NIL when conf absent.
DEFAULT        -- built-in fallback value.
PARSE          -- function applied to string/keyword values before return.

The conf check uses a sentinel so any Lisp-false value stored in the conf
(e.g. :slynk-attach nil, :port 0) is correctly honoured over DEFAULT rather
than being discarded as though the key were absent."
  (cond
    ;; Explicit keyword argument wins unconditionally over env and conf.
    (supplied-p
     (funcall parse keyword-value))
    (t
     (let ((env-val (uiop:getenv env-name)))
       (cond
         ;; Non-empty env var beats conf and default.
         ((and env-val (not (string= env-val "")))
          (funcall parse env-val))
         ;; Conf value beats built-in default.
         ;; Use a unique sentinel so a legitimately-falsy conf value
         ;; (nil, 0, "") is honoured over DEFAULT rather than treated as absent.
         (t
          ;; Conf key is derived by stripping the DSMR_ prefix and
          ;; folding underscores to dashes.  Assert the prefix so a
          ;; future non-DSMR_ env var name does not silently misderive
          ;; the conf key.
          (assert (and (>= (length env-name) 5)
                       (string= env-name "DSMR_" :end1 5))
                  () "%or-from-env requires DSMR_-prefixed env var, got ~S"
                  env-name)
          (let* ((bare  (subseq env-name 5))
                 (pkey  (intern (string-upcase (substitute #\- #\_ bare)) :keyword))
                 (missing '#:missing)
                 (conf-val (if conf-plist (getf conf-plist pkey missing) missing)))
            (if (eq conf-val missing)
                default
                (funcall parse conf-val)))))))))

;;; ---------------------------------------------------------------------------
;;; resolve-transport -- non-blocking seam
;;; ---------------------------------------------------------------------------

(defun %resolve-project-root (supplied-p value)
  "Resolve the effective project root pathname from the supplied-p flag and VALUE.

Precedence: explicit VALUE (when SUPPLIED-P) > DSMR_PROJECT_ROOT env var > getcwd.
When SUPPLIED-P is true and VALUE is nil, falls back to getcwd so callers can
pass :project-root nil to mean \"use the cwd explicitly\"."
  (if supplied-p
      (if value (pathname value) (uiop:getcwd))
      (let ((env (uiop:getenv "DSMR_PROJECT_ROOT")))
        (if (and env (not (string= env "")))
            (pathname env)
            (uiop:getcwd)))))

;;; ---------------------------------------------------------------------------
;;; Remote-bind safety gate
;;; ---------------------------------------------------------------------------

(defun %check-remote-bind (bind)
  "Signal INVALID-CONFIG-VALUE when BIND is a non-loopback address and the
operator has not set DSMR_ALLOW_REMOTE to 1, true, or yes. Called before
any listener socket is created so no network surface is exposed on accident."
  (let ((loopback-p (or (string= bind "127.0.0.1")
                        (string= bind "::1")
                        (string= bind "localhost"))))
    (unless (or loopback-p
                (member (uiop:getenv "DSMR_ALLOW_REMOTE")
                        '("1" "true" "yes") :test #'string=))
      (error 'invalid-config-value
             :name "DSMR_BIND"
             :raw  bind))))

;;; ---------------------------------------------------------------------------
;;; :auto Slynk reachability probe
;;; ---------------------------------------------------------------------------

(defun %slynk-reachable-p (slynk-attach)
  "Probe whether the Slynk listener at SLYNK-ATTACH is reachable.
Returns T when a TCP connection to host:port succeeds within 3 seconds,
NIL when SLYNK-ATTACH is nil/empty or when the connect times out or
is refused (connection-refused-error, end-of-file, general error).

The probe uses sb-ext:with-timeout — NOT usocket:socket-connect :timeout
which sets SO_RCVTIMEO and causes IO-TIMEOUT on subsequent reads
(documented in usocket as a known pitfall)."
  (when (or (null slynk-attach) (string= slynk-attach ""))
    (return-from %slynk-reachable-p nil))
  (multiple-value-bind (host port)
      (handler-case (parse-slynk-attach slynk-attach)
        (error () (return-from %slynk-reachable-p nil)))
    (unless (and host port)
      (return-from %slynk-reachable-p nil))
    (handler-case
        (sb-ext:with-timeout 3
          (let ((sock (usocket:socket-connect host port :element-type 'character)))
            (ignore-errors (usocket:socket-close sock))
            t))
      (sb-ext:timeout ()
        nil)
      (usocket:connection-refused-error ()
        nil)
      (usocket:socket-error ()
        nil)
      (error ()
        nil))))

(defun resolve-transport (&key (transport nil transport-supplied-p)
                                 (project-root nil project-root-supplied-p))
  "Resolve the effective transport keyword WITHOUT entering the blocking loop.

Applies precedence: keyword > DSMR_TRANSPORT env > .dsmr-mcp.conf > :stdio.

This is the non-blocking seam tests assert the precedence rules against.
RUN calls %RESOLVE-PROJECT-ROOT and %OR-FROM-ENV through the same helpers
this function uses, so the tested seam and the live path share identical
logic.  Tests can call RESOLVE-TRANSPORT directly without triggering the
stdio loop."
  (let* ((root (%resolve-project-root project-root-supplied-p project-root))
         (conf (%read-conf-into-defaults root)))
    (%or-from-env transport-supplied-p transport "DSMR_TRANSPORT" conf :stdio
                  :parse #'%parse-transport)))

(defun resolve-mode (&key (mode nil mode-supplied-p)
                          (slynk-attach nil slynk-attach-supplied-p)
                          (project-root nil project-root-supplied-p))
  "Resolve the effective dispatch mode keyword WITHOUT entering the blocking loop.

Applies precedence: keyword > DSMR_MODE env > .dsmr-mcp.conf > :attached.
When the resolved mode is :auto, probes the Slynk listener via %slynk-reachable-p:
  - Reachable -> :attached
  - Unreachable -> :hermetic (emits a log4cl :warn; configure-log4cl-for-server must
    have been called before this function runs or the warn goes to the wrong appender)

Explicit :attached never falls back; :auto is an explicit opt-in for the logged
fallback. The warn emitted on :auto -> :hermetic resolution is a startup-time
notice only (not per-call).

This is the non-blocking seam tests assert against, mirroring RESOLVE-TRANSPORT.
It shares %RESOLVE-PROJECT-ROOT, %READ-CONF-INTO-DEFAULTS, %OR-FROM-ENV, and
%PARSE-MODE with RUN's live path, so the tested seam and the live binding of
*MODE* resolve identically."
  (declare (ignore slynk-attach-supplied-p))
  (let* ((root (%resolve-project-root project-root-supplied-p project-root))
         (conf (%read-conf-into-defaults root))
         (m    (%or-from-env mode-supplied-p mode "DSMR_MODE" conf :attached
                             :parse #'%parse-mode)))
    (if (eq m :auto)
        (if (%slynk-reachable-p slynk-attach)
            :attached
            (progn
              (log-event :warn "run.auto-mode"
                         "msg" "auto: no attached Slynk listener, using hermetic")
              :hermetic))
        m)))

;;; ---------------------------------------------------------------------------
;;; Entry point
;;; ---------------------------------------------------------------------------

(defun run (&key (transport nil transport-supplied-p)
                 (slynk-attach nil slynk-attach-supplied-p)
                 (mode nil mode-supplied-p)
                 (port nil port-supplied-p)
                 (bind nil bind-supplied-p)
                 (log-level nil log-level-supplied-p)
                 (project-root nil project-root-supplied-p))
  "Start the dsmr-mcp MCP server.

Keyword arguments (all optional):
  :transport     {:stdio | :tcp | :http}        -- defaults to :stdio
  :slynk-attach  \"host:port\" string | nil        -- Slynk listener (attached mode)
  :mode          {:attached | :hermetic | :auto} -- defaults to :attached
  :port          integer                         -- :tcp/:http listener port
  :bind          string                          -- bind address; default \"127.0.0.1\"
  :log-level     {:debug | :info | :warn | :error} -- defaults to :info
  :project-root  pathname-designator | nil       -- server working root

Config precedence: keyword > DSMR_<KEYWORD> env var >
.dsmr-mcp.conf (via ubiquitous:value, file never written) > built-in default.

Blocking behaviour:
  :stdio  -- blocks reading *STANDARD-INPUT* until EOF, then returns T.
  :tcp    -- blocks accepting TCP connections; per-connection sessions until stop signal.
  :http   -- blocks running Hunchentoot acceptor; per-session lifecycle managed by the HTTP layer.

Malformed DSMR_* env values signal INVALID-CONFIG-VALUE (a typed subclass
of ERROR) so operator mistakes produce a clean diagnostic.  This includes
DSMR_TRANSPORT, DSMR_MODE, DSMR_LOG_LEVEL, and DSMR_PORT.

The dsmr-mcp:run nickname (re-exported by src/main.lisp) resolves to this function."
  ;; Resolve project root first (needed by conf reader).
  (let* ((resolved-root
           (%resolve-project-root project-root-supplied-p project-root))
         (conf (%read-conf-into-defaults resolved-root))

         ;; Resolve each setting with keyword > env > conf > default precedence.
         (resolved-transport
           (%or-from-env transport-supplied-p transport "DSMR_TRANSPORT" conf :stdio
                         :parse #'%parse-transport))

         (resolved-mode
           (%or-from-env mode-supplied-p mode "DSMR_MODE" conf :attached
                         :parse #'%parse-mode))

         (resolved-log-level
           (%or-from-env log-level-supplied-p log-level "DSMR_LOG_LEVEL" conf :info
                         :parse #'%parse-log-level))

         (resolved-bind
           (%or-from-env bind-supplied-p bind "DSMR_BIND" conf "127.0.0.1"
                         :parse #'identity))

         (resolved-port
           (%or-from-env port-supplied-p port "DSMR_PORT" conf nil
                         :parse (lambda (v)
                                  (etypecase v
                                    (integer v)
                                    ;; Guard against DSMR_PORT=abc at startup.
                                    ;; A malformed value signals INVALID-CONFIG-VALUE
                                    ;; rather than an unhandled parse-integer error.
                                    (string
                                     (handler-case
                                         (parse-integer v :junk-allowed nil)
                                       (error ()
                                         (error 'invalid-config-value
                                                :name "DSMR_PORT"
                                                :raw  v))))))))

         (resolved-slynk-attach
           (%or-from-env slynk-attach-supplied-p slynk-attach
                         "DSMR_SLYNK_ATTACH" conf nil
                         :parse #'identity))

         (resolved-attach-concurrency
           (%or-from-env nil nil "DSMR_ATTACH_CONCURRENCY" conf :serialised
                         :parse #'%resolve-attach-concurrency))

         (resolved-http-session-timeout
           (%or-from-env nil nil "DSMR_HTTP_SESSION_TIMEOUT" conf 3600
                         :parse (lambda (v)
                                  (etypecase v
                                    (integer v)
                                    (string
                                     (handler-case
                                         (parse-integer v :junk-allowed nil)
                                       (error ()
                                         (error 'invalid-config-value
                                                :name "DSMR_HTTP_SESSION_TIMEOUT"
                                                :raw  v))))))))

         (resolved-http-cleanup-interval
           (%or-from-env nil nil "DSMR_HTTP_CLEANUP_INTERVAL" conf 60
                         :parse (lambda (v)
                                  (etypecase v
                                    (integer v)
                                    (string
                                     (handler-case
                                         (parse-integer v :junk-allowed nil)
                                       (error ()
                                         (error 'invalid-config-value
                                                :name "DSMR_HTTP_CLEANUP_INTERVAL"
                                                :raw  v)))))))))

    ;; Apply resolved log level.
    (setf *log-level* resolved-log-level)

    ;; Install the log4cl stderr appender BEFORE mode resolution so the :auto
    ;; Slynk probe's :warn log line lands on stderr, never on the JSON-RPC
    ;; stdout channel.
    (configure-log4cl-for-server resolved-log-level)

    ;; Apply attach-concurrency policy before any session accepts requests.
    (setf *attach-concurrency* resolved-attach-concurrency)

    ;; Resolve the effective mode, performing the real :auto Slynk probe now
    ;; that the log appender is installed.
    (setf *mode* (resolve-mode :mode resolved-mode
                                :slynk-attach resolved-slynk-attach))

    ;; When hermetic mode is active, initialize the worker pool and register
    ;; the shutdown hook so workers are reaped when the process exits.
    (when (eq *mode* :hermetic)
      (initialize-pool)
      (pushnew 'shutdown-pool sb-ext:*exit-hooks*))

    ;; Dispatch to the selected transport.
    (unwind-protect
         (ecase resolved-transport
           (:stdio
            (log-event :info "run.start" "transport" :stdio "mode" *mode*)
            ;; Claim stdio for the wire and wall off the global standard
            ;; streams BEFORE serving: any thread spawned during the session
            ;; (Slynk client dispatchers in attached mode, pool workers, ...)
            ;; inherits the re-pointed globals, so nothing it prints — or
            ;; reads — can touch the JSON-RPC channel.  The restore matters
            ;; only for in-image callers (tests); the real server exits.
            (multiple-value-bind (wire-out wire-in restore-streams)
                (isolate-stdio-wire)
              (unwind-protect
                   (serve-streams wire-in wire-out
                                  :session (make-session :id "stdio"
                                                         :slynk-attach resolved-slynk-attach
                                                         :project-root resolved-root))
                (funcall restore-streams))))
           (:tcp
            (%check-remote-bind resolved-bind)
            (log-event :info "run.start" "transport" :tcp "mode" *mode*)
            (uiop:symbol-call :dsmr-mcp/src/transport/tcp :serve-tcp
                              :host resolved-bind
                              :port resolved-port
                              :slynk-attach resolved-slynk-attach
                              :project-root resolved-root))
           (:http
            (%check-remote-bind resolved-bind)
            (log-event :info "run.start" "transport" :http "mode" *mode*)
            (uiop:symbol-call :dsmr-mcp/src/transport/http :serve-http
                              :host resolved-bind
                              :port resolved-port
                              :slynk-attach resolved-slynk-attach
                              :project-root resolved-root
                              :session-timeout resolved-http-session-timeout
                              :cleanup-interval resolved-http-cleanup-interval)))
      ;; Cleanup: always log run.stop, even on unwind from typed errors.
      ;; When hermetic, release the stdio session worker so it is reaped.
      (when (eq *mode* :hermetic)
        (ignore-errors (release-session "stdio")))
      (log-event :info "run.stop" "transport" resolved-transport))))
