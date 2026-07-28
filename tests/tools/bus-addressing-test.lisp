;;;; tests/tools/bus-addressing-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; The publish verb's recipient argument, end to end over a real bus.
;;;;
;;;; Three participants share one isolated in-process bus: a sender, the
;;;; participant it names, and a bystander that is named by nobody. What these
;;;; tests pin down is the whole of what a caller of the verb can observe:
;;;;
;;;;   - naming a recipient while the capability is off refuses, says how to
;;;;     turn it on, and publishes nothing at all;
;;;;   - with the capability on, the named participant is handed the message and
;;;;     the bystander is not;
;;;;   - the bystander's DURABLE CURSOR still moves past that record. That is the
;;;;     invariant addressing must never break: a reader that stopped at other
;;;;     people's mail would pin the log for everyone;
;;;;   - a bare name and a full NAMESPACE/NAME id name the same participant;
;;;;   - omitting the argument broadcasts exactly as it always did, and does so
;;;;     in the DEFAULT configuration with the capability off;
;;;;   - a recipient that is not a usable string is refused as invalid-argument
;;;;     before anything is published.
;;;;
;;;; The capability is switched on explicitly, and restored on unwind, inside
;;;; only the cases that need it. No case here requires addressed delivery to
;;;; work in the configuration this project ships.

;; Package evolution guard: drop a prior incarnation so a reload picks up the
;; current import/export set rather than stale symbols.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/tools/bus-addressing-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/tools/bus-addressing-test
  (:use #:cl #:parachute)
  (:local-nicknames (#:broker #:dsmr-mcp/src/bus/broker)
                    (#:agent #:dsmr-mcp/src/bus/agent)
                    (#:envelope #:dsmr-mcp/src/bus/envelope))
  (:import-from #:dsmr-mcp/src/tools/base
                #:tool-handle)
  (:import-from #:dsmr-mcp/src/tools/bus-helpers
                #:session-agent
                #:disconnect-session-bus)
  (:import-from #:dsmr-mcp/src/tools/bus-publish
                #:bus-publish-tool)
  (:import-from #:dsmr-mcp/src/tools/bus-receive
                #:bus-receive-tool)
  (:import-from #:dsmr-mcp/src/state
                #:make-session
                #:session-project-root)
  (:import-from #:dsmr-mcp/tests/support/env-fixture
                #:with-clean-resolution-env))

(in-package #:dsmr-mcp/tests/tools/bus-addressing-test)

;;; ---------------------------------------------------------------------------
;;; Fixture: an isolated host bus on a temp XDG_STATE_HOME, served in-process.
;;; ---------------------------------------------------------------------------

(defun %make-temp-directory ()
  "Create a uniquely named temp directory under /tmp and return its pathname.
   The suffix is drawn from a state seeded per call, because SBCL's default
   random state is identical in every fresh image: without the seeding two runs
   walk the same names, and a leftover tree from an earlier run turns an absence
   assertion into a flake."
  (loop
    (let* ((rand-part (format nil "dsmr-bus-addr-~8,'0X"
                              (random #xFFFFFFFF (make-random-state t))))
           (dir-pn (uiop:ensure-directory-pathname
                    (merge-pathnames rand-part #p"/tmp/"))))
      (unless (probe-file dir-pn)
        (ensure-directories-exist dir-pn)
        (return dir-pn)))))

(defun %serve-bus-in-process (paths)
  "Elect a broker on PATHS and serve it on a background thread. Returns a thunk
   that stops it and joins the thread."
  (broker:ensure-bus-dirs paths)
  (let* ((br (broker:start-broker paths :block nil))
         (stop nil)
         (thread (sb-thread:make-thread
                  (lambda () (broker:serve-broker br (lambda () stop)))
                  :name "bus-addressing-test-broker")))
    (lambda ()
      (setf stop t)
      (ignore-errors (sb-thread:join-thread thread))
      (ignore-errors (broker:stop-broker br)))))

(defmacro with-isolated-bus (&body body)
  "Run BODY with XDG_STATE_HOME pointed at a fresh temp directory and an
   in-process broker serving the unnamed bus derived from it, so the verbs
   connect to a private bus and never touch the developer's host-wide one."
  (let ((dir (gensym "DIR")) (saved (gensym "SAVED")) (stop (gensym "STOP")))
    `(let* ((,dir (%make-temp-directory))
            (,saved (uiop:getenv "XDG_STATE_HOME")))
       (unwind-protect
            (progn
              (setf (uiop:getenv "XDG_STATE_HOME") (namestring ,dir))
              (let ((,stop (%serve-bus-in-process (broker:make-bus-paths))))
                (unwind-protect (progn ,@body)
                  (funcall ,stop))))
         (setf (uiop:getenv "XDG_STATE_HOME") (or ,saved ""))
         (ignore-errors (uiop:delete-directory-tree
                         ,dir :validate t :if-does-not-exist :ignore))))))

(defmacro with-rooted-session ((session-var) &body body)
  "Bind SESSION-VAR to a fresh session rooted at a temp project directory, with
   DSMR_BUS_AGENT and the other resolution vars neutralized, and disconnect every
   participant the session opened on the way out."
  (let ((root (gensym "ROOT")))
    `(with-clean-resolution-env
       (let* ((,root (%make-temp-directory))
              (,session-var (make-session :id "bus-addressing"
                                          :project-root ,root)))
         (unwind-protect (progn ,@body)
           (ignore-errors (disconnect-session-bus ,session-var))
           (ignore-errors (uiop:delete-directory-tree
                           ,root :validate t :if-does-not-exist :ignore)))))))

(defun call-with-direct-addressing (enabled thunk)
  "Run THUNK with direct addressing definitively on or off, whatever the ambient
   shell says. The capability reads a special variable and an environment
   variable, so a test that set only the first would still answer one way in a
   developer's direnv shell and another in an empty CI environment. The inherited
   value is put back afterwards."
  (let ((previous (uiop:getenv "DSMR_BUS_DIRECT_ADDRESSING"))
        (agent:*direct-addressing-enabled* enabled))
    (unwind-protect
         (progn (ignore-errors (sb-posix:unsetenv "DSMR_BUS_DIRECT_ADDRESSING"))
                (funcall thunk))
      (if previous
          (sb-posix:setenv "DSMR_BUS_DIRECT_ADDRESSING" previous 1)
          (ignore-errors (sb-posix:unsetenv "DSMR_BUS_DIRECT_ADDRESSING"))))))

(defmacro with-direct-addressing ((enabled) &body body)
  `(call-with-direct-addressing ,enabled (lambda () ,@body)))

;;; ---------------------------------------------------------------------------
;;; Driving the verbs
;;; ---------------------------------------------------------------------------

(defun %args (&rest kvs)
  "An MCP arguments hash-table from alternating string-key/value pairs."
  (let ((ht (make-hash-table :test 'equal)))
    (loop for (k v) on kvs by #'cddr do (setf (gethash k ht) v))
    ht))

(defun %invoke (class session kvs)
  "Invoke the tool CLASS for SESSION and return its result payload, unwrapped
   from the JSON-RPC envelope."
  (let ((tool (make-instance class :session session)))
    (gethash "result" (tool-handle tool 1 (apply #'%args kvs)))))

(defun %publish (session &rest kvs)
  (%invoke 'bus-publish-tool session kvs))

(defun %receive (session &rest kvs)
  (%invoke 'bus-receive-tool session kvs))

(defun %field (payload key)
  (gethash key payload))

(defun %error-type (payload)
  (and (gethash "isError" payload) (gethash "error_type" payload)))

(defun %content-text (payload)
  (gethash "text" (aref (gethash "content" payload) 0)))

(defun %texts (payload)
  "The bodies of the messages a receive handed back, in delivery order."
  (map 'list (lambda (m) (gethash "text" m)) (gethash "messages" payload)))

(defun %own-namespace (session)
  "The bus namespace this session's participants live under."
  (namestring (session-project-root session)))

(defun %qualified (session name)
  "The full bus id a bare NAME resolves to under SESSION's namespace, built the
   way the bus builds it."
  (format nil "~A/~A" (%own-namespace session) name))

(defun %durable-cursor (a)
  "The seq A's durable cursor file holds, or 0 when there is nothing readable
   there. Read straight off disk rather than through a handle: the point of the
   assertion is that the position a NON-recipient persists really did move past
   somebody else's mail."
  (let ((path (merge-pathnames (envelope:encode-id (agent:agent-id a))
                               (broker:bus-paths-cursors-dir
                                (agent:agent-paths a)))))
    (or (and (probe-file path)
             (with-open-file (in path :if-does-not-exist nil)
               (let ((value (and in (read in nil nil))))
                 (and (integerp value) (>= value 0) value))))
        0)))

(defmacro with-three-participants ((session sender named bystander) &body body)
  "The common shape of every case here: an isolated bus, a rooted session, and
   three participants already connected under stable names.

   Connected BEFORE any traffic on purpose. A participant that has never read
   joins at the current head, so anything published before it connects is not
   owed to it and an absence assertion would pass for the wrong reason."
  `(with-isolated-bus
     (with-rooted-session (,session)
       (let ((,sender (session-agent ,session "sender"))
             (,named (session-agent ,session "named"))
             (,bystander (session-agent ,session "bystander")))
         (declare (ignorable ,sender ,named ,bystander))
         ,@body))))

;;; ---------------------------------------------------------------------------
;;; The capability is off in every shipped configuration
;;; ---------------------------------------------------------------------------

(define-test naming-a-recipient-is-refused-while-the-capability-is-off
  "The default configuration. The refusal carries an error_type of its own so a
caller can branch on the taxonomy rather than the prose, the text names the
environment variable that turns the capability on, and nothing whatever is put
on the log: the participant that was named is shown no message at all."
  (with-three-participants (session sender named bystander)
    (declare (ignore sender bystander))
    (with-direct-addressing (nil)
      (let ((refused (%publish session "message" "for you alone"
                               "agent_id" "sender" "to" "named")))
        (is string= "direct-addressing-disabled" (%error-type refused)
            "the refusal names the disabled capability, not a generic error")
        (true (search "DSMR_BUS_DIRECT_ADDRESSING" (%content-text refused))
              "and says how to turn the capability on")
        (false (%field refused "published")
               "nothing reports itself as published"))
      (let ((mail (%receive session "agent_id" "named" "timeout_ms" 0)))
        (is = 0 (%field mail "count")
            "the named participant is handed nothing, so nothing was published")
        (is = 0 (%field mail "remaining_pending")
            "and nothing is waiting for it either"))
      (is = 0 (%durable-cursor named)
          "a refused publish leaves the log with nothing on it to walk past"))))

(define-test omitting-a-recipient-broadcasts-in-the-default-configuration
  "The whole existing behaviour of the verb, unchanged, with the capability off.
Every subscribed participant is handed the message and the reply reports no
recipient. A broadcast must never depend on a switch that ships off."
  (with-three-participants (session sender named bystander)
    (declare (ignore sender named bystander))
    (with-direct-addressing (nil)
      (let ((sent (%publish session "message" "for everyone"
                            "agent_id" "sender")))
        (true (%field sent "published"))
        (is eq 'null (%field sent "to")
            "an un-addressed publish reports no recipient")
        (true (integerp (%field sent "seq"))
              "and still reports the seq the broker assigned it"))
      (is equal '("for everyone")
          (%texts (%receive session "agent_id" "named" "timeout_ms" 0)))
      (is equal '("for everyone")
          (%texts (%receive session "agent_id" "bystander" "timeout_ms" 0))))))

;;; ---------------------------------------------------------------------------
;;; With the capability explicitly on
;;; ---------------------------------------------------------------------------

(define-test an-addressed-message-reaches-only-the-participant-it-names
  "The capability is switched on explicitly here, as it is in every case below.
The named participant gets the message; the bystander gets nothing; the sender
does not take delivery of its own."
  (with-three-participants (session sender named bystander)
    (declare (ignore sender named bystander))
    (with-direct-addressing (t)
      (let ((sent (%publish session "message" "for you alone"
                            "agent_id" "sender" "to" "named")))
        (true (%field sent "published"))
        (is string= (%qualified session "named") (%field sent "to")
            "the reply reports the full id the bare name qualified to")
        (true (search (%qualified session "named") (%content-text sent))
              "and the rendered text names the recipient rather than the bus"))
      (is equal '("for you alone")
          (%texts (%receive session "agent_id" "named" "timeout_ms" 0))
          "the participant it names is handed it")
      (is = 0 (%field (%receive session "agent_id" "bystander" "timeout_ms" 0)
                      "count")
          "a participant the message does not name is shown nothing")
      (is = 0 (%field (%receive session "agent_id" "sender" "timeout_ms" 0)
                      "count")
          "and the sender does not take delivery of its own message"))))

(define-test a-full-bus-id-names-the-same-participant-a-bare-name-does
  "A caller that already holds a sister's full NAMESPACE/NAME id passes it
straight through. A bare name is qualified with THIS session's namespace and can
therefore never reach an identically named agent in another project."
  (with-three-participants (session sender named bystander)
    (declare (ignore sender named bystander))
    (with-direct-addressing (t)
      (let ((sent (%publish session "message" "by full id"
                            "agent_id" "sender"
                            "to" (%qualified session "named"))))
        (true (%field sent "published"))
        (is string= (%qualified session "named") (%field sent "to")
            "a value carrying a separator is used exactly as given"))
      (is equal '("by full id")
          (%texts (%receive session "agent_id" "named" "timeout_ms" 0)))
      (is = 0 (%field (%receive session "agent_id" "bystander" "timeout_ms" 0)
                      "count")))))

(define-test a-bystander-cursor-still-walks-past-mail-for-somebody-else
  "The invariant addressing must never break. A participant that is not the
recipient is shown nothing AND its durable cursor moves past the record anyway.
A reader that stopped at other people's mail would hold the log's oldest
outstanding position for as long as it ran, which pins the log for the whole
fleet."
  (with-three-participants (session sender named bystander)
    (declare (ignore sender named))
    (with-direct-addressing (t)
      (let ((seq (%field (%publish session "message" "not for you"
                                   "agent_id" "sender" "to" "named")
                         "seq")))
        (true (integerp seq))
        (let ((skipped (%receive session "agent_id" "bystander"
                                 "timeout_ms" 0)))
          (is = 0 (%field skipped "count")
              "the bystander is shown nothing")
          (is = 0 (%field skipped "remaining_pending")
              "and is told nothing is waiting for it"))
        (is = seq (%durable-cursor bystander)
            "the bystander's persisted cursor sits ON the addressed record")
        (%publish session "message" "for everyone" "agent_id" "sender")
        (is equal '("for everyone")
            (%texts (%receive session "agent_id" "bystander" "timeout_ms" 0))
            "and the next broadcast still reaches it")))))

;;; ---------------------------------------------------------------------------
;;; Argument refusals
;;; ---------------------------------------------------------------------------

(define-test a-recipient-that-is-not-a-string-is-refused
  "Refused as invalid-argument before anything is published, with the capability
ON so the refusal is unmistakably about the value and not about the switch."
  (with-three-participants (session sender named bystander)
    (declare (ignore sender named bystander))
    (with-direct-addressing (t)
      (is string= "invalid-argument"
          (%error-type (%publish session "message" "hello"
                                 "agent_id" "sender" "to" 42)))
      (is string= "invalid-argument"
          (%error-type (%publish session "message" "hello"
                                 "agent_id" "sender" "to" t)))
      (is = 0 (%field (%receive session "agent_id" "named" "timeout_ms" 0)
                      "count")
          "a refused call publishes nothing"))))

(define-test an-empty-recipient-is-refused-rather-than-naming-nobody
  "An empty string qualified with the namespace would name <namespace>/ , which
is no participant at all, and the message would then be delivered to no reader
while the call reported success."
  (with-three-participants (session sender named bystander)
    (declare (ignore sender named bystander))
    (with-direct-addressing (t)
      (is string= "invalid-argument"
          (%error-type (%publish session "message" "hello"
                                 "agent_id" "sender" "to" "")))
      (is = 0 (%field (%receive session "agent_id" "named" "timeout_ms" 0)
                      "count")
          "a refused call publishes nothing"))))
