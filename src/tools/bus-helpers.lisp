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
;;;; namespace, and the tool's optional agent_id is the name within it. A named
;;;; agent resumes its durable cursor; the anonymous default agent (no agent_id)
;;;; is ephemeral and lives under the :default key for the session's lifetime, so
;;;; repeated no-argument calls reuse one identity.

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

(defun session-agent (session &optional agent-id)
  "The bus participant for SESSION under the optional AGENT-ID, connecting and
   caching it on first use. AGENT-ID names a stable agent that resumes its cursor;
   when omitted, the session's ephemeral default agent (key :default) is used.
   Signals NO-PROJECT-ROOT if the session has no namespace."
  (let* ((namespace (bus-namespace session))
         (table (session-bus-agents session))
         (key (or agent-id :default)))
    (or (gethash key table)
        (setf (gethash key table)
              (agent:connect-agent namespace :name agent-id)))))

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
