;;;; src/tools/reset-peer.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; MCP tool: reset-peer — the rung-2 cross-session restart verb (publish side).
;;;;
;;;; Resolves this session's bus agent, builds a structured restart-command JSON
;;;; envelope, and publishes it onto the host-wide coordination bus addressed to a
;;;; named peer in the same project namespace. Fire-and-forget: it returns the
;;;; broker-assigned seq immediately and never waits for the target to respond —
;;;; delivery rides the durable bus log, so the command reaches a peer whose own
;;;; read loop is wedged.
;;;;
;;;; This verb DEFINES the restart-command envelope contract; the receive side (a
;;;; background listener that consumes the envelope and runs a local reset) reads
;;;; the same keys. The envelope is built with a string-keyed hash-table and
;;;; serialized with com.inuoe.jzon — never hand-formatted.
;;;;
;;;; CLOS pattern: see pool-kill-worker.lisp / bus-publish.lisp — the same
;;;; :initform-on-class-slots rule and post-defclass ensure-finalized apply.

(defpackage #:dsmr-mcp/src/tools/reset-peer
  (:use #:cl)
  (:local-nicknames (#:jzon #:com.inuoe.jzon))
  (:import-from #:dsmr-mcp/src/tools/base
                #:mcp-tool #:mcp-tool-class #:tool-handle #:tool-session)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:make-ht #:result #:text-content)
  (:import-from #:dsmr-mcp/src/tools/bus-helpers
                #:session-agent #:identity-summary #:no-project-root)
  (:import-from #:dsmr-mcp/src/bus/agent
                #:agent-publish #:agent-name #:agent-namespace)
  ;; closer-mop: c2mop:ensure-finalized is called after the defclass below.
  ;; MUST be declared here or the cold build fails ("Package CLOSER-MOP does not exist").
  (:import-from #:closer-mop))

(in-package #:dsmr-mcp/src/tools/reset-peer)

(defparameter +restart-command-type+ "dsmr:restart"
  "The discriminator value the restart-command envelope carries under \"type\".
The receive-side listener dispatches on this string, so the publish and receive
sides share this one literal.")

(defun %build-restart-command (&key namespace target (rung 1) scope)
  "Build the restart-command envelope addressed to peer TARGET within NAMESPACE
and return it as a JSON string. The envelope is a JSON object with string keys:

  \"type\"      => \"dsmr:restart\"   (command discriminator)
  \"namespace\" => NAMESPACE          (the publisher's own namespace; the receiver
                                      rejects any command whose namespace differs
                                      from its own)
  \"target\"    => TARGET             (the peer agent name within the namespace)
  \"rung\"      => RUNG               (1 = a local reset on the target)
  \"scope\"     => SCOPE | null       (an absent scope serializes as JSON null)

Pure: builds a string-keyed hash-table and serializes it with jzon. No I/O, so it
is unit-testable. An absent SCOPE is encoded as the jzon null sentinel."
  (jzon:stringify
   (make-ht "type"      +restart-command-type+
            "namespace" namespace
            "target"    target
            "rung"      rung
            "scope"     (or scope 'null))))

(defclass reset-peer-tool (mcp-tool)
  ;; CRITICAL: :initform on class-allocated slots, NOT :default-initargs.
  ((dsmr-mcp/src/tools/base::name
    :allocation :class
    :initform "reset-peer")
   (dsmr-mcp/src/tools/base::description
    :allocation :class
    :initform "Direct a local reset at a NAMED peer agent in this project's bus \
namespace (rung 2 of the recovery ladder). Publishes a restart command onto the \
coordination bus addressed to the target peer; the peer's background listener \
runs a local reset of its own backends on receipt. Bidirectional within the \
namespace — a leader can reset a worker and a worker can reset the leader, as \
long as both share this project's namespace. Delivery rides the durable bus log, \
so it reaches a peer whose own read loop is wedged. Fire-and-forget: it returns \
the assigned bus seq immediately and never waits for the peer to acknowledge. \
Use bus-status to list the peers in this namespace. Optional scope narrows the \
reset the peer performs (\"attached\", \"hermetic\", or a session-id).")
   (dsmr-mcp/src/tools/base::input-schema
    :allocation :class
    :initform '(:object
                :properties
                ((target
                  :type :string
                  :description "The peer agent NAME within this project's bus \
namespace to restart (as shown by bus-status). Required.")
                 (scope
                  :type :string
                  :description "Optional reset scope passed to the peer: \
\"attached\", \"hermetic\", or a session-id. Omit to reset all of the peer's \
local backends."))
                :required ("target"))))
  (:metaclass mcp-tool-class)
  (:documentation "MCP tool: rung-2 cross-session restart — publish a restart
command to a named peer in this project's bus namespace, fire-and-forget."))

;; CRITICAL: ensure-finalized must appear after defclass.
;; (src/tools/base.lisp line 162; src/attach/dispatch.lisp line 115.)
(c2mop:ensure-finalized (find-class 'reset-peer-tool))

(defun %arg (args key)
  "Read KEY from request ARGS, treating absent and the jzon null sentinel alike
as NIL so a client-supplied JSON null falls through to the default."
  (let ((v (and args (gethash key args))))
    (if (eq v 'null) nil v)))

(defmethod tool-handle ((tool reset-peer-tool) id args)
  (let ((target (%arg args "target"))
        (scope (%arg args "scope")))
    (unless (and target (stringp target) (plusp (length target)))
      (return-from tool-handle
        (result id (make-ht "isError" t
                            "error_type" "invalid-argument"
                            "content" (text-content
                                       "reset-peer: target must be a non-empty peer agent name.")))))
    (handler-case
        (let* ((a (session-agent (tool-session tool)))
               (envelope (%build-restart-command
                          :namespace (agent-namespace a)
                          :target target
                          :rung 1
                          :scope scope))
               (seq (agent-publish a envelope)))
          (result id (make-ht "published" t
                              "target" target
                              "seq" (or seq 'null)
                              "content"
                              (text-content
                               (format nil "Sent reset-local command to peer ~S in this \
namespace~@[ (seq ~D)~], from ~A. Fire-and-forget; not waiting for the peer to acknowledge."
                                       target seq (identity-summary a))))))
      (no-project-root ()
        (result id (make-ht "isError" t
                            "error_type" "project-root-not-set"
                            "content" (text-content "reset-peer: no project root set. Call fs-set-project-root first.")))))))
