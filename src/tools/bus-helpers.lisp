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
;;;; Rules 1 and 4 both use the :default cache key with a nil name, so repeated
;;;; ephemeral calls in one session reuse one auto-unique participant (a subagent
;;;; publishes then receives and needs its cursor to persist within its session).
;;;; Cross-session distinctness is automatic: each subagent is a separate session,
;;;; hence a separate :default participant with a naturally distinct id.

(defpackage #:dsmr-mcp/src/tools/bus-helpers
  (:use #:cl)
  (:local-nicknames (#:agent #:dsmr-mcp/src/bus/agent))
  (:import-from #:dsmr-mcp/src/state
                #:session-project-root
                #:session-bus-agents)
  (:export #:bus-namespace #:session-agent #:disconnect-session-bus
           #:no-project-root))

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

(defun session-agent (session &optional agent-id &key ephemeral)
  "The bus participant for SESSION, connecting and caching it on first use.
   Signals NO-PROJECT-ROOT if the session has no namespace.

   The identity name within the namespace is resolved by four rules, in order:
     1. EPHEMERAL true -> the session's ephemeral default (key :default, name
        nil), regardless of AGENT-ID or DSMR_BUS_AGENT. The subagent opt-out.
     2. else AGENT-ID non-nil and non-empty -> stable name = AGENT-ID.
     3. else DSMR_BUS_AGENT set (non-empty) -> stable name = that value.
     4. else -> the session's ephemeral default (key :default, name nil).

   Stable names (rules 2 and 3) cache under the resolved name so repeat calls
   reuse the same participant and resume its durable cursor. The ephemeral rules
   (1 and 4) share the :default key with a nil name, so repeated ephemeral calls
   in one session reuse one auto-unique participant."
  (let* ((namespace (bus-namespace session))
         (table (session-bus-agents session))
         (stable-name
           (unless ephemeral
             (cond ((and agent-id (plusp (length agent-id))) agent-id)
                   (t (%env-bus-agent)))))
         (key (or stable-name :default)))
    (or (gethash key table)
        (setf (gethash key table)
              (agent:connect-agent namespace :name stable-name)))))

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
