;;;; src/run.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Top-level entry point for dsmr-mcp: resolves keyword/env/conf precedence
;;;; and dispatches to the appropriate transport.  For :stdio this call is
;;;; blocking (returns T at EOF); :tcp and :http raise transport-not-implemented-error
;;;; until Phase 9 delivers those transports.
;;;;
;;;; Design decisions (from 01-CONTEXT.md):
;;;;   D-14: Full keyword surface (:transport :slynk-attach :mode :port
;;;;         :bind :log-level :project-root).
;;;;   D-15: Every keyword has a DSMR_<KEYWORD> env-var fallback; keyword
;;;;         takes precedence over env.
;;;;   D-16: .dsmr-mcp.conf backed by ubiquitous:value (NEVER defaulted-value
;;;;         which writes the file on first read); absence is silent.
;;;;         Precedence: keyword > env > conf > built-in default.
;;;;   D-17: run is blocking for :stdio (returns T at EOF).  :tcp and :http
;;;;         raise transport-not-implemented-error in Phase 1.
;;;;
;;;; src/main.lisp ownership: Plan 01-01 already wired the run re-export
;;;; (:import-from dsmr-mcp/src/run #:run) so the dsmr-mcp:run nickname
;;;; resolves as soon as this file is loaded.  DO NOT edit src/main.lisp.

(defpackage #:dsmr-mcp/src/run
  (:use #:cl)
  (:local-nicknames (#:ubiquitous #:ubiquitous))
  (:import-from #:dsmr-mcp/src/transport/stdio
                #:serve-streams)
  (:import-from #:dsmr-mcp/src/state
                #:make-session)
  (:import-from #:dsmr-mcp/src/log
                #:log-event
                #:set-log-level-from-env
                #:*log-level*)
  ;; process-json-line is re-exported from here so src/main.lisp's
  ;; existing :import-from dsmr-mcp/src/run #:process-json-line
  ;; (wired by Plan 01-01) continues to resolve. The canonical
  ;; definition lives in dsmr-mcp/src/protocol; this export shadows
  ;; the stub that was previously defined locally in this package.
  (:shadowing-import-from #:dsmr-mcp/src/protocol
                          #:process-json-line)
  (:export #:run
           #:resolve-transport
           #:transport-not-implemented-error
           #:process-json-line))

(in-package #:dsmr-mcp/src/run)

;;; ---------------------------------------------------------------------------
;;; Conditions
;;; ---------------------------------------------------------------------------

(define-condition transport-not-implemented-error (error)
  ((transport :initarg :transport :reader transport-not-implemented-transport))
  (:report (lambda (c s)
             (format s "Transport ~A is not yet implemented (lands in Phase 9)."
                     (transport-not-implemented-transport c))))
  (:documentation "Signaled by RUN when :transport is :tcp or :http.
These transports are Phase-9 work; in Phase 1 they raise this typed condition
so tests can assert the correct condition class rather than a generic error.
When Phase 9 delivers the TCP/HTTP transports, the arms that signal this
condition are replaced with the real implementations."))

;;; ---------------------------------------------------------------------------
;;; Parse helpers
;;; ---------------------------------------------------------------------------

(defun %parse-transport (value)
  "Coerce VALUE (string or keyword) to one of :STDIO, :TCP, or :HTTP.
Signals an error for any other value."
  (let ((kw (etypecase value
               (keyword value)
               (string  (intern (string-upcase value) :keyword)))))
    (ecase kw
      (:stdio :stdio)
      (:tcp   :tcp)
      (:http  :http))))

(defun %parse-mode (value)
  "Coerce VALUE (string or keyword) to one of :ATTACHED, :HERMETIC, or :AUTO."
  (let ((kw (etypecase value
               (keyword value)
               (string  (intern (string-upcase value) :keyword)))))
    (ecase kw
      (:attached :attached)
      (:hermetic :hermetic)
      (:auto     :auto))))

(defun %parse-log-level (value)
  "Coerce VALUE (string or keyword) to one of :DEBUG, :INFO, :WARN, or :ERROR."
  (let ((kw (etypecase value
               (keyword value)
               (string  (intern (string-upcase value) :keyword)))))
    (ecase kw
      (:debug :debug)
      (:info  :info)
      (:warn  :warn)
      (:error :error))))

;;; ---------------------------------------------------------------------------
;;; Conf reader (D-16)
;;; ---------------------------------------------------------------------------

(defun %read-conf-into-defaults (project-root)
  "Read .dsmr-mcp.conf at PROJECT-ROOT (if present) and return a plist of
config values.  Returns NIL when the file is absent (absence is silent,
no file is created).

Uses ubiquitous:value (NEVER defaulted-value, which writes the file on first
read) inside with-local-storage :transaction nil so no automatic offload
occurs.  See D-16 and 01-RESEARCH.md pitfalls section on ubiquitous."
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
;;; Precedence helper (D-15)
;;; ---------------------------------------------------------------------------

(defun %or-from-env (supplied-p keyword-value env-name conf-plist default
                     &key (parse #'identity))
  "Apply keyword > env > conf > default precedence for one config value.

SUPPLIED-P     -- the supplied-p flag from the &key lambda-list.
KEYWORD-VALUE  -- value the caller passed explicitly (only consulted when SUPPLIED-P).
ENV-NAME       -- DSMR_* environment variable name (e.g. \"DSMR_TRANSPORT\").
CONF-PLIST     -- plist from %READ-CONF-INTO-DEFAULTS, or NIL when conf absent.
DEFAULT        -- built-in fallback value.
PARSE          -- function applied to string/keyword values before return."
  (cond
    ;; Explicit keyword argument wins unconditionally (D-15).
    (supplied-p
     (funcall parse keyword-value))
    (t
     (let ((env-val (uiop:getenv env-name)))
       (cond
         ;; Non-empty env var beats conf and default.
         ((and env-val (not (string= env-val "")))
          (funcall parse env-val))
         ;; Conf value beats built-in default.
         (t
          ;; Derive the conf plist key from env-name:
          ;;   "DSMR_TRANSPORT" -> :transport
          ;;   "DSMR_LOG_LEVEL" -> :log-level
          (let* ((bare  (subseq env-name 5))
                 (pkey  (intern (string-upcase (substitute #\- #\_ bare)) :keyword))
                 (conf-val (and conf-plist (getf conf-plist pkey))))
            (if conf-val
                (funcall parse conf-val)
                default))))))))

;;; ---------------------------------------------------------------------------
;;; resolve-transport -- non-blocking seam (D-15, D-17)
;;; ---------------------------------------------------------------------------

(defun resolve-transport (&key (transport nil transport-supplied-p)
                                 (project-root nil project-root-supplied-p))
  "Resolve the effective transport keyword WITHOUT entering the blocking loop.

Applies precedence: keyword > DSMR_TRANSPORT env > .dsmr-mcp.conf > :stdio.

This is the non-blocking seam tests assert the precedence rules against.
RUN itself calls RESOLVE-TRANSPORT so the public and tested surfaces stay
identical.  Tests can call this directly without triggering the stdio loop."
  (let* ((root (if project-root-supplied-p
                   (if project-root (pathname project-root) (uiop:getcwd))
                   (let ((env (uiop:getenv "DSMR_PROJECT_ROOT")))
                     (if (and env (not (string= env "")))
                         (pathname env)
                         (uiop:getcwd)))))
         (conf (%read-conf-into-defaults root)))
    (%or-from-env transport-supplied-p transport "DSMR_TRANSPORT" conf :stdio
                  :parse #'%parse-transport)))

;;; ---------------------------------------------------------------------------
;;; Entry point (D-14, D-15, D-16, D-17)
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

Config precedence (D-15, D-16): keyword > DSMR_<KEYWORD> env var >
.dsmr-mcp.conf (via ubiquitous:value, file never written) > built-in default.

Blocking behaviour (D-17):
  :stdio  -- blocks reading *STANDARD-INPUT* until EOF, then returns T.
  :tcp    -- PHASE 9 (currently signals TRANSPORT-NOT-IMPLEMENTED-ERROR).
  :http   -- PHASE 9 (currently signals TRANSPORT-NOT-IMPLEMENTED-ERROR).

The dsmr-mcp:run nickname (re-exported by src/main.lisp, owned by Plan 01-01)
resolves to this function."
  ;; Resolve project root first (needed by conf reader).
  (let* ((resolved-root
           (cond
             (project-root-supplied-p
              (if project-root (pathname project-root) (uiop:getcwd)))
             (t
              (let ((env (uiop:getenv "DSMR_PROJECT_ROOT")))
                (if (and env (not (string= env "")))
                    (pathname env)
                    (uiop:getcwd))))))
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
                                    (string  (parse-integer v))))))

         (resolved-slynk-attach
           (%or-from-env slynk-attach-supplied-p slynk-attach
                         "DSMR_SLYNK_ATTACH" conf nil
                         :parse #'identity)))

    ;; Suppress unused-variable notes for Phase-1 settings not yet wired.
    (declare (ignore resolved-mode resolved-bind resolved-port
                     resolved-slynk-attach))

    ;; Apply resolved log level.
    (setf *log-level* resolved-log-level)

    ;; Dispatch to the selected transport.
    (unwind-protect
         (ecase resolved-transport
           (:stdio
            (log-event :info "run.start" "transport" :stdio)
            (serve-streams *standard-input* *standard-output*
                           :session (make-session :id "stdio")))
           ((:tcp :http)
            (error 'transport-not-implemented-error :transport resolved-transport)))
      ;; Cleanup: always log run.stop, even on unwind from typed errors.
      (log-event :info "run.stop" "transport" resolved-transport))))
