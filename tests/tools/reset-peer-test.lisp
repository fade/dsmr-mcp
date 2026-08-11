;;;; tests/tools/reset-peer-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Coverage for the rung-2 cross-session restart verb (reset-peer) and the
;;;; restart-command envelope contract it defines.
;;;;
;;;; Two layers:
;;;;   1. The envelope builder is pure, so it is unit-tested directly: build,
;;;;      parse back with jzon, and assert every contract key (type, namespace,
;;;;      target, rung, scope). This locks the wire shape the receive-side
;;;;      listener consumes.
;;;;   2. The verb is exercised through tool-handle on a real reset-peer-tool
;;;;      instance: missing-target rejection, no-project-root handling, and an
;;;;      end-to-end publish onto an isolated in-process bus where a foreign-id
;;;;      subscriber receives the envelope and it parses to the contract shape.
;;;;
;;;; The publish test isolates XDG_STATE_HOME to a temp directory and runs an
;;;; in-process broker there, exactly like the bus identity seam, so it never
;;;; touches the developer's host-wide bus.

;; Package evolution guard: drop a prior incarnation so a reload picks up the
;; current import/export set rather than stale symbols.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/tools/reset-peer-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/tools/reset-peer-test
  (:use #:cl #:zebra)
  (:local-nicknames (#:jzon #:com.inuoe.jzon)
                    (#:broker #:dsmr-mcp/src/bus/broker)
                    (#:agent #:dsmr-mcp/src/bus/agent))
  (:import-from #:dsmr-mcp/src/tools/reset-peer
                #:reset-peer-tool
                #:%build-restart-command)
  (:import-from #:dsmr-mcp/src/tools/base
                #:tool-handle)
  (:import-from #:dsmr-mcp/src/state
                #:make-session
                #:session-project-root)
  (:import-from #:dsmr-mcp/tests/support/env-fixture
                #:with-clean-resolution-env))

(in-package #:dsmr-mcp/tests/tools/reset-peer-test)

;;; ---------------------------------------------------------------------------
;;; Helpers
;;; ---------------------------------------------------------------------------

(defun %args (&rest kvs)
  "Build an equal-keyed request-args hash-table from KEY VALUE pairs."
  (let ((ht (make-hash-table :test 'equal)))
    (loop for (k v) on kvs by #'cddr do (setf (gethash k ht) v))
    ht))

(defun %make-temp-directory ()
  "Create a uniquely named temp directory under /tmp and return its pathname."
  (loop
    (let* ((rand-part (format nil "dsmr-reset-peer-~8,'0X" (random #xFFFFFFFF)))
           (dir-pn    (uiop:ensure-directory-pathname
                       (merge-pathnames rand-part #p"/tmp/"))))
      (unless (probe-file dir-pn)
        (ensure-directories-exist dir-pn)
        (return dir-pn)))))

(defmacro with-isolated-bus (() &body body)
  "Run BODY with XDG_STATE_HOME pointed at a fresh temp directory and an
   in-process broker serving the default bus paths derived from it, so the verb
   publishes onto a private bus and never touches the host-wide one. Restores
   XDG_STATE_HOME and cleans up the temp tree on exit."
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
                                 :name "reset-peer-test-broker")))
                  (unwind-protect (progn ,@body)
                    (setf ,stop t)
                    (ignore-errors (sb-thread:join-thread ,thread))
                    (ignore-errors (broker:stop-broker ,br))))))
         (setf (uiop:getenv "XDG_STATE_HOME") (or ,saved ""))
         (ignore-errors (uiop:delete-directory-tree
                         ,dir :validate t :if-does-not-exist :ignore))))))

(defmacro with-rooted-session ((session-var) &body body)
  "Bind SESSION-VAR to a fresh session rooted at a temp project directory, with
   DSMR_BUS_AGENT and the other resolution vars neutralized so the verb resolves
   the session's ephemeral default agent (a distinct id from any named peer)."
  (let ((root (gensym "ROOT")))
    `(with-clean-resolution-env
       (let* ((,root (%make-temp-directory))
              (,session-var (make-session :id "reset-peer"
                                          :project-root ,root)))
         (unwind-protect (progn ,@body)
           (ignore-errors (uiop:delete-directory-tree
                           ,root :validate t :if-does-not-exist :ignore)))))))

(defun %call-verb (session args)
  "Dispatch tool-handle on a fresh reset-peer-tool bound to SESSION. ARGS is a
request-args hash-table or NIL. Returns the JSON-RPC result payload hash-table."
  (let* ((tool (make-instance 'reset-peer-tool :session session))
         (response (tool-handle tool "req-reset-peer" args)))
    (gethash "result" response)))

;;; ---------------------------------------------------------------------------
;;; Envelope builder (pure)
;;; ---------------------------------------------------------------------------

(define-test envelope-round-trips-with-null-scope
  "An absent scope serializes as JSON null and the other keys carry the contract
values for a rung-1 command."
  (let ((env (jzon:parse (%build-restart-command
                          :namespace "ns" :target "peer" :rung 1 :scope nil))))
    (is string= "dsmr:restart" (gethash "type" env) "type discriminator")
    (is string= "ns" (gethash "namespace" env) "publisher namespace")
    (is string= "peer" (gethash "target" env) "target peer name")
    (is = 1 (gethash "rung" env) "rung 1 = local reset on the target")
    (is eql 'null (gethash "scope" env) "absent scope is JSON null")))

(define-test envelope-carries-an-explicit-scope
  "A supplied scope rides the envelope verbatim under \"scope\"."
  (let ((env (jzon:parse (%build-restart-command
                          :namespace "ns" :target "peer" :rung 1 :scope "attached"))))
    (is string= "attached" (gethash "scope" env) "explicit scope preserved")
    (is string= "dsmr:restart" (gethash "type" env))
    (is = 1 (gethash "rung" env))))

;;; ---------------------------------------------------------------------------
;;; Target validation
;;; ---------------------------------------------------------------------------

(define-test missing-target-is-an-invalid-argument
  "tool-handle with no \"target\" returns isError t and a machine-readable
error_type, without touching the bus or needing a project root."
  (let* ((session (make-session :id "reset-peer-no-target"))
         (payload (%call-verb session (%args))))
    (true (gethash "isError" payload) "missing target is an error")
    (is string= "invalid-argument" (gethash "error_type" payload)
        "error_type names the bad argument")))

(define-test empty-target-is-an-invalid-argument
  "An empty-string target is rejected the same as an absent one."
  (let* ((session (make-session :id "reset-peer-empty-target"))
         (payload (%call-verb session (%args "target" ""))))
    (true (gethash "isError" payload) "empty target is an error")
    (is string= "invalid-argument" (gethash "error_type" payload))))

(define-test no-project-root-is-reported
  "With a valid target but no project root there is no namespace to publish
under: the verb returns isError t with error_type project-root-not-set."
  (with-clean-resolution-env
    (let* ((session (make-session :id "reset-peer-no-root"))
           (payload (%call-verb session (%args "target" "peer"))))
      (true (gethash "isError" payload) "no project root is an error")
      (is string= "project-root-not-set" (gethash "error_type" payload)))))

;;; ---------------------------------------------------------------------------
;;; End-to-end publish onto an isolated bus
;;; ---------------------------------------------------------------------------

(define-test publish-reaches-a-namespace-peer
  "A valid call publishes the restart command fire-and-forget; a foreign-id
subscriber in the same namespace receives it and it parses to the contract
shape (type/namespace/target/rung)."
  (with-isolated-bus ()
    (with-rooted-session (session)
      (let* ((namespace (namestring (session-project-root session)))
             (peer (agent:connect-agent namespace :name "peer")))
        (unwind-protect
             (let ((payload (%call-verb session (%args "target" "peer"))))
               (false (gethash "isError" payload) "publish is not an error")
               (true (gethash "published" payload) "reports published")
               (is string= "peer" (gethash "target" payload) "echoes the target")
               (let ((msgs (agent:agent-receive peer :timeout-ms 2000)))
                 (true (plusp (length msgs)) "peer received the restart command")
                 (let ((env (jzon:parse (first msgs))))
                   (is string= "dsmr:restart" (gethash "type" env) "type on the wire")
                   (is string= namespace (gethash "namespace" env)
                       "carries the publisher's own namespace")
                   (is string= "peer" (gethash "target" env) "addressed to the peer")
                   (is = 1 (gethash "rung" env) "rung 1 on the wire"))))
          (ignore-errors (agent:disconnect-agent peer)))))))
