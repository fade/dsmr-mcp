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
;;;; Which bus the session speaks on is a second and independent dimension,
;;;; resolved by the same shape minus the ephemeral opt-out: an explicit
;;;; argument, then DSMR_BUS_SELECTOR, then the host's unnamed bus. The cases at
;;;; the foot of this file cover that order and then the reason it matters, which
;;;; is that one session must be able to hold participants on two buses at once
;;;; without either one's traffic reaching the other's reader.
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
                    (#:agent #:dsmr-mcp/src/bus/agent)
                    (#:selector #:dsmr-mcp/src/bus/selector))
  (:import-from #:dsmr-mcp/src/tools/bus-helpers
                #:session-agent
                #:session-bus)
  (:import-from #:dsmr-mcp/src/bus/agent
                #:agent-bus)
  (:import-from #:dsmr-mcp/src/bus/selector
                #:invalid-bus-name)
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
  "Create a uniquely named temp directory under /tmp and return its pathname.
   The suffix is drawn from a state seeded per call, because SBCL's default
   random state is identical in every fresh image: without the seeding two runs
   walk the same names, and a leftover tree from an earlier run turns an
   absence assertion into a flake."
  (loop
    (let* ((rand-part (format nil "dsmr-bus-id-~8,'0X"
                              (random #xFFFFFFFF (make-random-state t))))
           (dir-pn    (uiop:ensure-directory-pathname
                       (merge-pathnames rand-part #p"/tmp/"))))
      (unless (probe-file dir-pn)
        (ensure-directories-exist dir-pn)
        (return dir-pn)))))

(defun %serve-bus-in-process (paths)
  "Elect a broker on PATHS and serve it on a background thread. Returns a thunk
   that stops it and joins the thread, so a caller holding several of these can
   shut them down in whatever order it needs."
  (broker:ensure-bus-dirs paths)
  (let* ((br (broker:start-broker paths :block nil))
         (stop nil)
         (thread (sb-thread:make-thread
                  (lambda () (broker:serve-broker br (lambda () stop)))
                  :name "bus-identity-test-broker")))
    (lambda ()
      (setf stop t)
      (ignore-errors (sb-thread:join-thread thread))
      (ignore-errors (broker:stop-broker br)))))

(defmacro with-isolated-bus ((&rest bus-names) &body body)
  "Run BODY with XDG_STATE_HOME pointed at a fresh temp directory and an
   in-process broker serving the unnamed bus derived from it, so session-agent
   connects to a private bus and never touches the host-wide one.

   Each name in BUS-NAMES additionally gets its own served bus under that same
   temp root, which is how one test can hold participants on two buses at once.
   With no names this is exactly the single-bus fixture it has always been.
   Brokers are stopped in the reverse of the order they started, then
   XDG_STATE_HOME is restored and the temp tree removed."
  (let ((dir (gensym "DIR")) (saved (gensym "SAVED"))
        (stoppers (gensym "STOPPERS")) (stopper (gensym "STOPPER")))
    `(let* ((,dir (%make-temp-directory))
            (,saved (uiop:getenv "XDG_STATE_HOME")))
       (unwind-protect
            (progn
              (setf (uiop:getenv "XDG_STATE_HOME") (namestring ,dir))
              (let ((,stoppers '()))
                (unwind-protect
                     (progn
                       (push (%serve-bus-in-process (broker:make-bus-paths))
                             ,stoppers)
                       ,@(mapcar
                          (lambda (name)
                            `(push (%serve-bus-in-process
                                    (broker:make-bus-paths
                                     (selector:bus-root ,name)))
                                   ,stoppers))
                          bus-names)
                       ,@body)
                  (dolist (,stopper ,stoppers) (funcall ,stopper)))))
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

(define-test selector-precedence-prefers-explicit-argument
  "An explicit bus argument wins over DSMR_BUS_SELECTOR, exactly as an explicit
agent_id wins over DSMR_BUS_AGENT."
  (with-clean-resolution-env
    (setf (uiop:getenv "DSMR_BUS_SELECTOR") "from-the-shell")
    (is string= "explicit" (session-bus "explicit"))))

(define-test selector-precedence-falls-back-to-environment
  "With no argument, DSMR_BUS_SELECTOR names the bus. That is the carrier the
.envrc stanza writes, so a repo lands on its fleet's bus without anyone passing
an argument."
  (with-clean-resolution-env
    (setf (uiop:getenv "DSMR_BUS_SELECTOR") "from-the-shell")
    (is string= "from-the-shell" (session-bus))))

(define-test unset-selector-uses-default-bus
  "Nothing set resolves to NIL, the host's unnamed bus. A session that says
nothing about a bus goes exactly where it went before any of this existed."
  (with-clean-resolution-env
    (is eq nil (session-bus))))

(define-test empty-selector-value-reads-as-absent
  "An empty DSMR_BUS_SELECTOR reads as unset rather than as a bus named by the
empty string, matching how an empty DSMR_BUS_AGENT is treated."
  (with-clean-resolution-env
    (setf (uiop:getenv "DSMR_BUS_SELECTOR") "")
    (is eq nil (session-bus))))

(define-test an-unusable-selector-is-refused-not-downgraded
  "A bus name that cannot become a directory segment is refused outright. Falling
back to the unnamed bus would put a fleet's traffic on the shared one while every
surface still reported success."
  (with-clean-resolution-env
    (fail (session-bus "not a bus name") 'invalid-bus-name)))

(define-test one-bus-and-one-name-reuse-a-single-participant
  "Two calls for the same name on the same bus return the same participant, so a
stable identity keeps one connection and one cursor per bus."
  (with-isolated-bus ("alpha")
    (with-rooted-session (session)
      (with-agent (a (session-agent session "main" :bus "alpha"))
        (is eq a (session-agent session "main" :bus "alpha")
            "a repeat call on the same bus returns the cached participant")))))

(define-test two-buses-in-one-session-stay-separate
  "One session holds a participant on the unnamed bus and another on a named one
under the SAME stable name, and the two are separate all the way down: distinct
handles, distinct roots, distinct write-ahead logs, distinct cursors, and traffic
that does not cross. This is the guard on the participant cache key. Keyed on the
name alone, the second call hands back the first bus's connection and one fleet's
messages arrive in another fleet's reader."
  (with-isolated-bus ("alpha")
    (with-rooted-session (session)
      (with-agent (here (session-agent session "main"))
        (with-agent (there (session-agent session "main" :bus "alpha"))
          (with-agent (sender (session-agent session "sender" :bus "alpha"))
            (false (eq here there)
                   "two buses under one name yield two participants")
            (is eq nil (agent-bus here))
            (is string= "alpha" (agent-bus there))
            (false (equal (broker:bus-paths-root (agent:agent-paths here))
                          (broker:bus-paths-root (agent:agent-paths there)))
                   "the two participants sit on different bus roots")
            (false (equal (broker:bus-paths-wal (agent:agent-paths here))
                          (broker:bus-paths-wal (agent:agent-paths there)))
                   "each bus keeps its own write-ahead log")
            (false (equal (broker:bus-paths-cursors-dir (agent:agent-paths here))
                          (broker:bus-paths-cursors-dir
                           (agent:agent-paths there)))
                   "each bus keeps its own cursor for this identity")
            (agent:agent-publish sender "for the named bus only")
            (is equal '("for the named bus only")
                (agent:agent-receive there :timeout-ms 5000)
                "the named bus delivers the message")
            (is equal '()
                (agent:agent-receive here :timeout-ms 250)
                "and the unnamed bus never sees it")))))))

(define-test the-environment-selector-reaches-the-participant
  "The resolved bus is not merely reported: the participant session-agent hands
back is connected on it."
  (with-isolated-bus ("alpha")
    (with-rooted-session (session)
      (setf (uiop:getenv "DSMR_BUS_SELECTOR") "alpha")
      (with-agent (a (session-agent session "main"))
        (is string= "alpha" (agent-bus a))
        (is string= (namestring (selector:bus-root "alpha"))
            (namestring (broker:bus-paths-root (agent:agent-paths a))))))))
