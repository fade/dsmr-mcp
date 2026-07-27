;;;; src/tools/bus-helpers.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Glue between the MCP session and the coordination bus. The bus tools
;;;; (bus-publish / bus-receive / bus-status) all need the same thing: the bus
;;;; participant for this session and an optional agent name. This module resolves
;;;; that participant — lazily connecting on first use and caching it on the
;;;; session — and tears every participant down at session end.
;;;;
;;;; Identity follows the locked model: the session's project root is the
;;;; namespace, and the name within it is resolved by a four-rule order so the
;;;; project's long-lived main agent keeps a stable identity (and resumes its
;;;; durable cursor) across restarts, while one-shot subagents stay ephemeral.
;;;;
;;;; The four rules, in order:
;;;;   1. ephemeral t      -> the session's ephemeral default (key :default, name
;;;;                          nil). The subagent opt-out: a subagent inherits the
;;;;                          same DSMR_BUS_AGENT env as the main agent (same
;;;;                          process), so this is how it avoids stealing the main
;;;;                          agent's cursor. Bypasses rules 2 and 3 entirely.
;;;;   2. explicit agent-id -> stable <namespace>/<agent-id>, resumes its cursor.
;;;;   3. DSMR_BUS_AGENT set -> stable <namespace>/<value>; the project's main
;;;;                          agent identity, read from the inherited direnv env
;;;;                          (an empty value reads as absent).
;;;;   4. otherwise         -> the session's ephemeral default (key :default,
;;;;                          name nil), preserved byte-for-byte from before this
;;;;                          phase.
;;;;
;;;; Rules 1 and 4 both use the :default name key with a nil name, so repeated
;;;; ephemeral calls in one session reuse one auto-unique participant (a subagent
;;;; publishes then receives and needs its cursor to persist within its session).
;;;; Cross-session distinctness is automatic: each subagent is a separate session,
;;;; hence a separate :default participant with a naturally distinct id.
;;;;
;;;; The bus a session speaks on is a second and independent dimension, and the
;;;; four name rules above are unchanged by it. It resolves by the same shape,
;;;; minus the ephemeral opt-out which has no meaning for a bus: an explicit
;;;; argument, then DSMR_BUS_SELECTOR, then the host's unnamed bus. A cached
;;;; participant is keyed on both, so an agent joined to two buses under one
;;;; stable name gets one participant per bus rather than a single shared
;;;; connection that would hand one fleet's traffic to another fleet's reader.

(defpackage #:dsmr-mcp/src/tools/bus-helpers
  (:use #:cl)
  (:local-nicknames (#:agent #:dsmr-mcp/src/bus/agent)
                    (#:selector #:dsmr-mcp/src/bus/selector))
  (:import-from #:dsmr-mcp/src/state
                #:session-project-root
                #:session-bus-agents)
  (:export #:bus-namespace #:session-bus #:session-agent #:disconnect-session-bus
           #:identity-summary #:no-project-root))

(in-package #:dsmr-mcp/src/tools/bus-helpers)

(define-condition no-project-root (error) ()
  (:report "the bus needs a project root for its namespace; call \
fs-set-project-root first")
  (:documentation "Signalled when a bus tool runs in a session with no project
root — there is no namespace to give the agent an identity under."))

(defun bus-namespace (session)
  "The bus namespace for SESSION: its project root as a string. Signals
   NO-PROJECT-ROOT when none is set."
  (let ((root (session-project-root session)))
    (unless root (error 'no-project-root))
    (namestring root)))

(defun %env-bus-agent ()
  "The DSMR_BUS_AGENT value from the inherited environment, or NIL when unset or
   empty. An empty string reads as absent, mirroring the convention the other
   DSMR_* env reads use (see fs-set-project-root)."
  (let ((value (uiop:getenv "DSMR_BUS_AGENT")))
    (when (and value (plusp (length value)))
      value)))

(defun %env-bus-selector ()
  "The DSMR_BUS_SELECTOR value from the inherited environment, or NIL when unset
   or empty. An empty string reads as absent, exactly as %ENV-BUS-AGENT treats an
   empty name.

   This is the same variable the .envrc stanza declares and the same one the
   standalone watcher reads, deliberately: one carrier for the bus means a session
   and the watcher armed for it cannot drift onto different buses while both
   report success."
  (let ((value (uiop:getenv "DSMR_BUS_SELECTOR")))
    (when (and value (plusp (length value)))
      value)))

(defun session-bus (&optional bus)
  "The bus this session speaks on: a validated name string, or NIL for the
   host's unnamed bus.

   Resolution mirrors the four-rule identity order above on purpose, minus the
   ephemeral opt-out, which has no meaning for a bus: an explicit non-empty BUS
   argument wins, then DSMR_BUS_SELECTOR from the environment, then the
   documented default. One mental model covers both a participant's name and the
   bus it carries that name on, rather than two orders a reader has to keep
   apart.

   Signals SELECTOR:INVALID-BUS-NAME for a name that cannot become a bus root.
   A bad selector is never quietly downgraded to the default bus: that would put
   a fleet's traffic on the shared bus while every surface reported success."
  (let ((resolved (or (and (stringp bus) (plusp (length bus)) bus)
                      (%env-bus-selector))))
    (when resolved
      (selector:validate-bus-name resolved))))

(defun session-agent (session &optional agent-id &key ephemeral bus)
  "The bus participant for SESSION on the resolved bus, connecting and caching it
   on first use. Signals NO-PROJECT-ROOT if the session has no namespace.

   The identity name within the namespace is resolved by four rules, in order:
     1. EPHEMERAL true -> the session's ephemeral default (name nil), regardless
        of AGENT-ID or DSMR_BUS_AGENT. The subagent opt-out.
     2. else AGENT-ID non-nil and non-empty -> stable name = AGENT-ID.
     3. else DSMR_BUS_AGENT set (non-empty) -> stable name = that value.
     4. else -> the session's ephemeral default (name nil).

   The bus is a second, independent dimension, resolved by SESSION-BUS: explicit
   BUS argument, then DSMR_BUS_SELECTOR, then the host's unnamed bus. The cache
   key carries both, so one session can hold a participant on each of several
   buses under one stable name, each with its own connection, membership and
   cursor. Two calls differing only in the bus therefore return two distinct
   participants, and never one shared connection that would leak one fleet's
   traffic into another fleet's reader.

   Stable names (rules 2 and 3) cache under the resolved name so repeat calls on
   one bus reuse the same participant and resume its durable cursor. The
   ephemeral rules (1 and 4) share the :default name key, so repeated ephemeral
   calls in one session and on one bus reuse one auto-unique participant."
  (let* ((namespace (bus-namespace session))
         (table (session-bus-agents session))
         (resolved-bus (session-bus bus))
         (stable-name
           (unless ephemeral
             (cond ((and agent-id (plusp (length agent-id))) agent-id)
                   (t (%env-bus-agent)))))
         (key (cons (or resolved-bus :default) (or stable-name :default))))
    (or (gethash key table)
        (setf (gethash key table)
              (agent:connect-agent namespace :name stable-name
                                             :bus resolved-bus)))))

(defun identity-summary (a)
  "A labeled \"who am I\" phrase for the bus participant A: its name, whether the
   identity is stable or anonymous/ephemeral, and the project namespace it lives
   under. The bus tools lead their output with this so an agent reads its own
   identity from the tool result instead of inferring it from message traffic —
   the inference path that lets an agent misattribute itself."
  (if (agent:agent-stable-p a)
      (format nil "~S (stable identity) in project namespace ~A"
              (agent:agent-name a) (agent:agent-namespace a))
      (format nil "~S (anonymous/ephemeral — no agent_id or DSMR_BUS_AGENT set, \
so this cursor will not persist across restarts) in project namespace ~A"
              (agent:agent-name a) (agent:agent-namespace a))))

(defun disconnect-session-bus (session)
  "Disconnect every bus participant this session opened and forget them. Durable
   cursors are left in place so named agents resume next time. Best-effort: never
   signals, so it is safe in a teardown unwind-protect."
  (let ((table (session-bus-agents session)))
    (maphash (lambda (key a)
               (declare (ignore key))
               (ignore-errors (agent:disconnect-agent a)))
             table)
    (clrhash table))
  (values))
