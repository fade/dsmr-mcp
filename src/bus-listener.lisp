;;;; src/bus-listener.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; The background bus listener — the receive side of the cross-session restart
;;;; rung and the worker side of the process-re-exec rung.
;;;;
;;;; A peer cannot drive recovery through a wedged server's own MCP read loop,
;;;; because that loop is the wedged thing. So the actuator is a background
;;;; bordeaux-threads listener spawned at server startup. SBCL uses real pthreads,
;;;; so this thread keeps running and acting on commands even while the read loop
;;;; is blocked in read-char — that independence is the whole point.
;;;;
;;;; The listener connects an EPHEMERAL receiving agent (no stable name) so it
;;;; never steals the main agent's durable cursor, and polls the bus on a short
;;;; timeout. It listens on the bus its session resolved rather than
;;;; unconditionally on the host's unnamed one, so a server belonging to a fleet
;;;; takes commands from that fleet's bus and from nowhere else. Each message is parsed and validated by the pure core
;;;; %handle-restart-message: it acts only on a command whose namespace equals
;;;; this server's own namespace (the cross-namespace block) AND whose target
;;;; equals this server's own bus name. Validation is keyed on the resolved
;;;; DSMR_BUS_AGENT name and the project-root namespace — NOT on the ephemeral
;;;; subscriber id — so "how it receives" is decoupled from "what name it answers
;;;; to".
;;;;
;;;; A matching rung-1 command runs a local reset; a rung-3 command exits the
;;;; process through the shared restart sentinel so the launcher (leader) or the
;;;; pool health monitor (worker) brings it back. Both dispatch thunks run in the
;;;; loop body, NEVER under a lock: %trigger-restart-exit runs the SBCL exit hooks
;;;; (pool shutdown), which take *pool-lock*, so triggering it from a lock-held
;;;; context would deadlock. The loop body is wrapped so no single bad message can
;;;; kill the listener.

(defpackage #:dsmr-mcp/src/bus-listener
  (:use #:cl)
  (:local-nicknames (#:bt #:bordeaux-threads)
                    (#:jzon #:com.inuoe.jzon))
  (:import-from #:dsmr-mcp/src/bus/agent
                #:connect-agent #:agent-receive #:disconnect-agent)
  (:import-from #:dsmr-mcp/src/reset
                #:reset-local-backends)
  (:import-from #:dsmr-mcp/src/tools/restart-process
                #:%trigger-restart-exit)
  (:import-from #:dsmr-mcp/src/log
                #:log-event)
  (:export #:start-bus-listener #:stop-bus-listener))

(in-package #:dsmr-mcp/src/bus-listener)

(defparameter +restart-command-type+ "dsmr:restart"
  "The discriminator value an incoming restart-command envelope carries under
\"type\". This MUST match the literal the publish side stamps
(src/tools/reset-peer.lisp); both the publish and receive sides are locked to
this one string by their respective round-trip tests.")

;;; ---------------------------------------------------------------------------
;;; Pure parse / validate / dispatch core
;;; ---------------------------------------------------------------------------

(defun %handle-restart-message (message own-namespace own-name
                                &key on-reset on-reexec)
  "Parse, validate, and dispatch one restart-command MESSAGE for a server whose
namespace is OWN-NAMESPACE and whose addressable bus name is OWN-NAME.

Pure: the side effects are the injected thunks ON-RESET and ON-REEXEC, so every
branch is unit-testable with no bus, no thread, and no real process exit.
ON-RESET is funcalled with one argument — the parsed scope (a string, or NIL for
an absent/null scope). ON-REEXEC is funcalled with no arguments.

Returns a keyword naming the outcome:
  :reset                      rung 1, namespace+target match — ON-RESET fired
  :reexec                     rung 3, namespace+target match — ON-REEXEC fired
  :ignored-foreign-namespace  namespace differs from OWN-NAMESPACE (D-05)
  :ignored-wrong-target       target differs from OWN-NAME
  :ignored-type               not a restart command, or an unknown rung
  :ignored-malformed          MESSAGE is not parseable JSON (logged, no signal)

A single malformed or unaddressed message never signals — the listener loop must
survive every message."
  (let ((parsed (handler-case (jzon:parse message)
                  (error (e)
                    (log-event :warn "bus-listener.malformed"
                               "error" (princ-to-string e))
                    (return-from %handle-restart-message :ignored-malformed)))))
    (unless (hash-table-p parsed)
      (return-from %handle-restart-message :ignored-type))
    (let ((type (gethash "type" parsed)))
      (unless (and (stringp type) (string= type +restart-command-type+))
        (return-from %handle-restart-message :ignored-type)))
    (unless (equal (gethash "namespace" parsed) own-namespace)
      (log-event :warn "bus-listener.foreign-namespace"
                 "namespace" (princ-to-string (gethash "namespace" parsed))
                 "own_namespace" (princ-to-string own-namespace))
      (return-from %handle-restart-message :ignored-foreign-namespace))
    (unless (equal (gethash "target" parsed) own-name)
      (return-from %handle-restart-message :ignored-wrong-target))
    (let ((rung (gethash "rung" parsed))
          (scope (let ((s (gethash "scope" parsed)))
                   ;; jzon decodes JSON null to the symbol NULL; treat it as
                   ;; "no scope", i.e. reset everything.
                   (if (eq s 'null) nil s))))
      (cond
        ((and (realp rung) (= rung 1))
         (when on-reset (funcall on-reset scope))
         :reset)
        ((and (realp rung) (= rung 3))
         (when on-reexec (funcall on-reexec))
         :reexec)
        (t :ignored-type)))))

;;; ---------------------------------------------------------------------------
;;; Background listener thread
;;; ---------------------------------------------------------------------------

(defvar *listener-thread* nil
  "The background listener thread, or NIL when no listener is running.")

(defvar *listener-agent* nil
  "The ephemeral receiving agent the listener polls, or NIL.")

(defvar *listener-stop* nil
  "Cooperative stop flag. The loop checks it each iteration and exits when true.
A plain global the stopping thread mutates — not a per-thread dynamic binding —
so stop-bus-listener in one thread is seen by the listener in another.")

(defun start-bus-listener (namespace own-name &key (poll-ms 2000) session bus)
  "Spawn the background bus listener and return its thread.

NAMESPACE is this server's project-root namespace and OWN-NAME its addressable
bus name (the resolved DSMR_BUS_AGENT). BUS names which bus to listen on, NIL
meaning the host's unnamed one. The listener is per bus, so a server running on
a named bus takes its restart commands from that bus and not from the shared
one: a command published where the server is not a member reaches nobody, which
is the point of running a fleet on a bus of its own.

The listener connects an EPHEMERAL agent in NAMESPACE — no stable name, so it
never resumes (or steals) the main agent's durable cursor — and polls every
POLL-MS for restart commands. Each message is validated against NAMESPACE and
OWN-NAME, not against the ephemeral agent's own id, then dispatched: rung 1 runs
a local reset of SESSION's backends, rung 3 exits the process through the shared
restart sentinel. The cross-namespace refusal is unchanged and still applies
within a bus.

SESSION, when supplied, is the live transport session whose attached connection
the reset can drop; absent it the reset still kills hermetic workers and clears
the breaker and orphan registries. The dispatch runs in the loop body, never
under a lock (the exit primitive runs exit hooks that take *pool-lock*). The loop
body is wrapped so no single message kills the thread."
  (setf *listener-stop* nil)
  (let ((agent (connect-agent namespace :bus bus)))
    (setf *listener-agent* agent)
    (setf *listener-thread*
          (bt:make-thread
           (lambda ()
             (log-event :info "bus-listener.start"
                        "namespace" namespace "name" own-name
                        "bus" (or bus "default"))
             (unwind-protect
                  (loop until *listener-stop* do
                    (handler-case
                        (dolist (message (agent-receive agent :timeout-ms poll-ms))
                          ;; LOOP BODY — never inside a lock. %trigger-restart-exit
                          ;; runs the exit hooks (pool shutdown) which take
                          ;; *pool-lock*, so dispatching it from a lock-held
                          ;; context would deadlock.
                          (%handle-restart-message
                           message namespace own-name
                           :on-reset (lambda (scope)
                                       (reset-local-backends (or session "stdio")
                                                             :scope (or scope :all)))
                           :on-reexec (lambda () (%trigger-restart-exit))))
                      (error (e)
                        ;; Warn and continue: a transient bus error must not kill
                        ;; the listener.
                        (log-event :warn "bus-listener.error"
                                   "error" (princ-to-string e)))))
               (log-event :info "bus-listener.stop")))
           :name "dsmr-bus-listener"))
    *listener-thread*))

(defun stop-bus-listener ()
  "Signal the listener loop to stop and release its agent. Best-effort and
idempotent — safe from a shutdown hook or unwind-protect even when no listener
was ever started. The loop exits after its current poll returns (up to its
poll interval)."
  (setf *listener-stop* t)
  (let ((agent *listener-agent*))
    (when agent
      (ignore-errors (disconnect-agent agent))
      (setf *listener-agent* nil)))
  (setf *listener-thread* nil)
  (values))
