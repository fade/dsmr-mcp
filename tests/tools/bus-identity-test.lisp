;;;; tests/tools/bus-identity-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; The bus identity seam: session-agent resolves the participant name within
;;;; the session's project namespace by a four-rule order, so the project's
;;;; long-lived main agent keeps a stable identity (and resumes its cursor)
;;;; across restarts while one-shot subagents stay ephemeral.
;;;;
;;;; The rules, in precedence order:
;;;;   1. ephemeral t       -> the session's ephemeral default, even with an
;;;;                           agent_id or DSMR_BUS_AGENT present (the subagent
;;;;                           opt-out). Two such calls in one session reuse the
;;;;                           one :default participant, so its cursor persists.
;;;;   2. explicit agent_id -> stable <namespace>/<agent_id>.
;;;;   3. DSMR_BUS_AGENT set -> stable <namespace>/<value>; empty reads as absent.
;;;;   4. otherwise         -> the session's ephemeral default (today's path).
;;;;
;;;; These are resolution units, not message-flow tests. To exercise the real
;;;; connect path without touching the developer's host-wide bus, each test
;;;; isolates XDG_STATE_HOME to a temp directory and runs an in-process broker
;;;; there (the default bus paths derive from XDG_STATE_HOME), then asserts on
;;;; the resolved id of the returned agent handle. DSMR_BUS_AGENT is neutralized
;;;; by with-clean-resolution-env and set explicitly per rule.

;; Package evolution guard: drop a prior incarnation so a reload picks up the
;; current import/export set rather than stale symbols.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/tools/bus-identity-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/tools/bus-identity-test
  (:use #:cl #:parachute)
  (:local-nicknames (#:broker #:dsmr-mcp/src/bus/broker)
                    (#:agent #:dsmr-mcp/src/bus/agent))
  (:import-from #:dsmr-mcp/src/tools/bus-helpers
                #:session-agent)
  (:import-from #:dsmr-mcp/src/state
                #:make-session
                #:session-project-root)
  (:import-from #:dsmr-mcp/tests/support/env-fixture
                #:with-clean-resolution-env))

(in-package #:dsmr-mcp/tests/tools/bus-identity-test)

;;; ---------------------------------------------------------------------------
;;; Fixture: an isolated host bus on a temp XDG_STATE_HOME, served in-process.
;;; ---------------------------------------------------------------------------

(defun %make-temp-directory ()
  "Create a uniquely named temp directory under /tmp and return its pathname."
  (loop
    (let* ((rand-part (format nil "dsmr-bus-id-~8,'0X" (random #xFFFFFFFF)))
           (dir-pn    (uiop:ensure-directory-pathname
                       (merge-pathnames rand-part #p"/tmp/"))))
      (unless (probe-file dir-pn)
        (ensure-directories-exist dir-pn)
        (return dir-pn)))))

(defmacro with-isolated-bus (() &body body)
  "Run BODY with XDG_STATE_HOME pointed at a fresh temp directory and an
   in-process broker serving the default bus paths derived from it, so
   session-agent connects to a private bus and never touches the host-wide one.
   Restores XDG_STATE_HOME and cleans up the temp tree on exit."
  (let ((dir (gensym "DIR")) (saved (gensym "SAVED"))
        (paths (gensym "PATHS")) (br (gensym "BR"))
        (stop (gensym "STOP")) (thread (gensym "THREAD")))
    `(let* ((,dir (%make-temp-directory))
            (,saved (uiop:getenv "XDG_STATE_HOME")))
       (unwind-protect
            (progn
              (setf (uiop:getenv "XDG_STATE_HOME") (namestring ,dir))
              (let* ((,paths (broker:make-bus-paths))
                     (,stop nil))
                (broker:ensure-bus-dirs ,paths)
                (let* ((,br (broker:start-broker ,paths :block nil))
                       (,thread (sb-thread:make-thread
                                 (lambda ()
                                   (broker:serve-broker ,br (lambda () ,stop)))
                                 :name "bus-identity-test-broker")))
                  (unwind-protect (progn ,@body)
                    (setf ,stop t)
                    (ignore-errors (sb-thread:join-thread ,thread))
                    (ignore-errors (broker:stop-broker ,br))))))
         (setf (uiop:getenv "XDG_STATE_HOME") (or ,saved ""))
         (ignore-errors (uiop:delete-directory-tree
                         ,dir :validate t :if-does-not-exist :ignore))))))

(defmacro with-rooted-session ((session-var) &body body)
  "Bind SESSION-VAR to a fresh session rooted at a temp project directory, with
   DSMR_BUS_AGENT and the other resolution vars neutralized. The root is a
   distinct temp dir so the namespace is stable and predictable per test."
  (let ((root (gensym "ROOT")))
    `(with-clean-resolution-env
       (let* ((,root (%make-temp-directory))
              (,session-var (make-session :id "bus-identity"
                                          :project-root ,root)))
         (unwind-protect (progn ,@body)
           (ignore-errors (uiop:delete-directory-tree
                           ,root :validate t :if-does-not-exist :ignore)))))))

(defun %root-namespace (session)
  "The namespace string session-agent builds the id under: the session's project
   root as a namestring."
  (namestring (session-project-root session)))

(defun %stable-id (session name)
  "The id session-agent resolves for a stable NAME under SESSION's namespace,
   built exactly as the bus does: <namespace>/<name> (the namespace namestring
   already ends in a slash, so the join yields a double slash)."
  (format nil "~A/~A" (%root-namespace session) name))

(defmacro with-agent ((var agent-form) &body body)
  "Bind VAR to the agent from AGENT-FORM, disconnecting it on exit."
  `(let ((,var ,agent-form))
     (unwind-protect (progn ,@body)
       (ignore-errors (agent:disconnect-agent ,var)))))

;;; ---------------------------------------------------------------------------
;;; Rules
;;; ---------------------------------------------------------------------------

(define-test ephemeral-flag-beats-the-env-identity
  "ephemeral t wins over a set DSMR_BUS_AGENT: two ephemeral calls in one session
return the SAME id (the :default participant, cursor continuity), and that id is
NOT the stable env identity."
  (with-isolated-bus ()
    (with-rooted-session (session)
      (setf (uiop:getenv "DSMR_BUS_AGENT") "main")
      (with-agent (a (session-agent session nil :ephemeral t))
        (with-agent (b (session-agent session nil :ephemeral t))
          (is string= (agent:agent-id a) (agent:agent-id b)
              "two same-session ephemeral calls reuse one participant")
          (false (string= (agent:agent-id a) (%stable-id session "main"))
                 "the ephemeral id is not the stable env identity"))))))

(define-test explicit-agent-id-beats-the-env-identity
  "An explicit agent_id wins over DSMR_BUS_AGENT: the id is <namespace>/worker."
  (with-isolated-bus ()
    (with-rooted-session (session)
      (setf (uiop:getenv "DSMR_BUS_AGENT") "main")
      (with-agent (a (session-agent session "worker"))
        (is string= (%stable-id session "worker") (agent:agent-id a))))))

(define-test env-identity-resolves-when-alone
  "With no flag and no agent_id, a set DSMR_BUS_AGENT yields <namespace>/<value>."
  (with-isolated-bus ()
    (with-rooted-session (session)
      (setf (uiop:getenv "DSMR_BUS_AGENT") "main")
      (with-agent (a (session-agent session))
        (is string= (%stable-id session "main") (agent:agent-id a))))))

(define-test no-inputs-yields-a-reused-ephemeral-identity
  "No flag, no agent_id, no DSMR_BUS_AGENT: the today-default ephemeral path, and
two no-arg calls in one session reuse the one :default participant."
  (with-isolated-bus ()
    (with-rooted-session (session)
      (with-agent (a (session-agent session))
        (with-agent (b (session-agent session))
          (is string= (agent:agent-id a) (agent:agent-id b)
              "two no-arg calls reuse the session's :default participant")
          (true (eql 0 (search (%root-namespace session) (agent:agent-id a)))
                "the ephemeral id is namespaced under the project root"))))))

(define-test empty-env-value-reads-as-absent
  "An empty-string DSMR_BUS_AGENT falls through to the ephemeral default rather
than resolving to a trailing-empty stable name <namespace>/."
  (with-isolated-bus ()
    (with-rooted-session (session)
      (setf (uiop:getenv "DSMR_BUS_AGENT") "")
      (with-agent (a (session-agent session))
        (false (string= (agent:agent-id a) (%root-namespace session))
               "an empty env value does not produce <namespace>/")
        (with-agent (b (session-agent session))
          (is string= (agent:agent-id a) (agent:agent-id b)
              "it falls to the reused :default ephemeral participant"))))))
