;;;; tests/bus/agent-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Tests for the bus agent layer and its identity model. Identity construction
;;;; and cursor-filename encoding are pure-unit; the connect/publish/receive flow
;;;; runs against an in-process broker thread (the detached-process path is covered
;;;; by the integration suite).

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/bus/agent-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/bus/agent-test
  (:use #:cl #:parachute)
  (:local-nicknames (#:broker #:dsmr-mcp/src/bus/broker)
                    (#:bus #:dsmr-mcp/src/bus/bus)
                    (#:agent #:dsmr-mcp/src/bus/agent)
                    (#:heartbeat #:dsmr-mcp/src/bus/heartbeat)
                    (#:selector #:dsmr-mcp/src/bus/selector)
                    (#:wal #:dsmr-mcp/src/bus/wal)))

(in-package #:dsmr-mcp/tests/bus/agent-test)

;;; identity (pure) ------------------------------------------------------------

(define-test named-id-is-stable
  "A given name yields the same project-namespaced id every time."
  (is string= "/home/fade/proj/worker"
      (bus:agent-id "/home/fade/proj" :name "worker"))
  (is string= (bus:agent-id "/home/fade/proj" :name "worker")
      (bus:agent-id "/home/fade/proj" :name "worker")))

(define-test anonymous-ids-are-unique
  "Omitting the name yields distinct ids under the shared namespace."
  (let ((a (bus:agent-id "/p"))
        (b (bus:agent-id "/p")))
    (false (string= a b) "two anonymous ids differ")
    (true (eql 0 (search "/p/" a)) "namespaced under the project")))

(define-test encode-id-is-filesystem-safe-and-injective
  "Encoding strips path separators and keeps distinct ids distinct."
  (let ((e1 (bus:encode-id "/home/fade/proj/worker"))
        (e2 (bus:encode-id "/home/fade/proj_worker")))
    (false (find #\/ e1) "no slashes survive in the cursor filename")
    (false (string= e1 e2) "two different ids encode differently")))

;;; flow against an in-process broker ------------------------------------------

(defmacro with-bus ((paths) &body body)
  (let ((name (gensym)) (root (gensym)))
    `(let* ((,name (uiop:with-temporary-file (:pathname p :keep t :prefix "dsmr-bus-agent") p))
            (,root (progn (ignore-errors (delete-file ,name))
                          (uiop:ensure-directory-pathname ,name)))
            (,paths (broker:make-bus-paths ,root)))
       (broker:ensure-bus-dirs ,paths)
       (unwind-protect (progn ,@body)
         (ignore-errors (uiop:delete-directory-tree
                         ,root :validate t :if-does-not-exist :ignore))))))

(defmacro with-running-broker ((br paths) &body body)
  (let ((stop (gensym)) (thread (gensym)))
    `(let* ((,br (broker:start-broker ,paths :block nil))
            (,stop nil)
            (,thread (sb-thread:make-thread
                      (lambda () (broker:serve-broker ,br (lambda () ,stop)))
                      :name "agent-test-broker")))
       (unwind-protect (progn ,@body)
         (setf ,stop t)
         (ignore-errors (sb-thread:join-thread ,thread))
         (ignore-errors (broker:stop-broker ,br))))))

(define-test publish-and-receive
  "A named agent publishes and another receives over the in-process broker."
  (with-bus (paths)
    (with-running-broker (br paths)
      (let ((a (agent:connect-agent "/proj" :name "pub" :paths paths :ensure-broker nil))
            (b (agent:connect-agent "/proj" :name "sub" :paths paths :ensure-broker nil)))
        (unwind-protect
             (progn
               (agent:agent-publish a "ping")
               (is equal '("ping") (agent:agent-receive b :timeout-ms 3000)))
          (agent:disconnect-agent a)
          (agent:disconnect-agent b))))))

(define-test named-agent-resumes-after-reconnect
  "A named agent that disconnects and reconnects resumes after its last message.
   It joins before the traffic starts, because a participant's claim on the bus
   begins when it first joins — what arrives while it is away is its backlog, and
   that is what must survive the reconnect."
  (with-bus (paths)
    (with-running-broker (br paths)
      (let ((pub (agent:connect-agent "/proj" :name "pub" :paths paths :ensure-broker nil))
            (joiner (agent:connect-agent "/proj" :name "resumer" :paths paths
                                                 :ensure-broker nil)))
        (agent:disconnect-agent joiner)
        (unwind-protect
             (progn
               (agent:agent-publish pub "first")
               (let ((s (agent:connect-agent "/proj" :name "resumer" :paths paths :ensure-broker nil)))
                 (is equal '("first") (agent:agent-receive s :timeout-ms 3000))
                 (agent:disconnect-agent s))
               (agent:agent-publish pub "second")
               (let ((s (agent:connect-agent "/proj" :name "resumer" :paths paths :ensure-broker nil)))
                 (unwind-protect
                      (is equal '("second") (agent:agent-receive s :timeout-ms 3000))
                   (agent:disconnect-agent s))))
          (agent:disconnect-agent pub))))))

(define-test status-reports-pending
  "agent-status reports a live broker and the pending count without consuming."
  (with-bus (paths)
    (with-running-broker (br paths)
      (let ((pub (agent:connect-agent "/proj" :name "p" :paths paths :ensure-broker nil))
            (sub (agent:connect-agent "/proj" :name "s" :paths paths :ensure-broker nil)))
        (unwind-protect
             (progn
               (agent:agent-publish pub "x")
               ;; wait for it to land
               (loop repeat 50 until (plusp (getf (agent:agent-status sub) :pending))
                     do (sleep 0.05))
               (let ((st (agent:agent-status sub)))
                 (is eq t (getf st :broker-running))
                 (is = 1 (getf st :pending)))
               ;; still pending — status did not consume it
               (is = 1 (length (agent:agent-receive sub :timeout-ms 1000))))
          (agent:disconnect-agent pub)
          (agent:disconnect-agent sub))))))

(define-test agent-reads-back-its-own-stable-identity
  "A named agent can read its own name, namespace, and stable flag from the agent
   layer — so it never has to infer its handle from message traffic. The name is
   the supplied name even when the namespace ends with the same token."
  (with-bus (paths)
    (with-running-broker (br paths)
      (let ((a (agent:connect-agent "/home/fade/seven/" :name "seven"
                                    :paths paths :ensure-broker nil)))
        (unwind-protect
             (progn
               (is string= "seven" (agent:agent-name a)
                   "name is the supplied name, not the look-alike namespace")
               (is string= "/home/fade/seven/" (agent:agent-namespace a))
               (is eq t (agent:agent-stable-p a))
               (let ((st (agent:agent-status a)))
                 (is string= "seven" (getf st :name))
                 (is eq t (getf st :stable))))
          (agent:disconnect-agent a))))))

(define-test anonymous-agent-reports-itself-ephemeral
  "An unnamed agent reads back stable=NIL and a name distinct from the namespace,
   so the tool can warn that its cursor will not persist."
  (with-bus (paths)
    (with-running-broker (br paths)
      (let ((a (agent:connect-agent "/proj" :paths paths :ensure-broker nil)))
        (unwind-protect
             (progn
               (is eq nil (agent:agent-stable-p a))
               (false (string= "/proj" (agent:agent-name a))
                      "the ephemeral name is not the bare namespace")
               (is eq nil (getf (agent:agent-status a) :stable)))
          (agent:disconnect-agent a))))))

;;; joining, backlog, and abandonment -------------------------------------------

(define-test new-agent-does-not-replay-the-log-it-arrived-after
  "An agent joining a bus that already carries traffic receives nothing on its
   first read. It has never read, so it has no claim on what came before it —
   without this its first receive is the whole log."
  (with-bus (paths)
    (with-running-broker (br paths)
      (let ((pub (agent:connect-agent "/proj" :name "pub" :paths paths :ensure-broker nil)))
        (unwind-protect
             (progn
               (dotimes (i 5) (agent:agent-publish pub (format nil "old-~D" i)))
               (let ((newcomer (agent:connect-agent "/proj" :name "newcomer"
                                                            :paths paths :ensure-broker nil)))
                 (unwind-protect
                      (progn
                        (is = 0 (length (agent:agent-receive newcomer)))
                        (is = 0 (getf (agent:agent-status newcomer) :pending))
                        ;; but it does get what arrives after it joined
                        (agent:agent-publish pub "after-joining")
                        (is equal '("after-joining")
                            (agent:agent-receive newcomer :timeout-ms 3000)))
                   (agent:disconnect-agent newcomer))))
          (agent:disconnect-agent pub))))))

(define-test returning-agent-gets-its-backlog-a-batch-at-a-time
  "A returning agent's backlog is intact but handed over in bounded batches, so
   joining seeded it without clobbering the position it had earned."
  (with-bus (paths)
    (with-running-broker (br paths)
      (let ((pub (agent:connect-agent "/proj" :name "pub" :paths paths :ensure-broker nil))
            (joiner (agent:connect-agent "/proj" :name "returner" :paths paths
                                                 :ensure-broker nil)))
        (agent:disconnect-agent joiner)
        (unwind-protect
             (progn
               (dotimes (i 9) (agent:agent-publish pub (format nil "m-~D" i)))
               (let ((s (agent:connect-agent "/proj" :name "returner"
                                                     :paths paths :ensure-broker nil)))
                 (unwind-protect
                      (let ((first-batch (agent:agent-receive s :timeout-ms 3000 :limit 4)))
                        (is = 4 (length first-batch))
                        (is equal '("m-0" "m-1" "m-2" "m-3") first-batch)
                        (is = 5 (getf (agent:agent-status s) :pending))
                        (is equal '("m-4" "m-5" "m-6" "m-7" "m-8")
                            (agent:agent-receive s :timeout-ms 3000))
                        (is = 0 (getf (agent:agent-status s) :pending)))
                   (agent:disconnect-agent s))))
          (agent:disconnect-agent pub))))))

(define-test skipping-ahead-reports-the-backlog-it-gave-up
  "An agent can abandon its backlog deliberately, and is told how much it gave
   up — the discard is never silent."
  (with-bus (paths)
    (with-running-broker (br paths)
      (let ((pub (agent:connect-agent "/proj" :name "pub" :paths paths :ensure-broker nil))
            (joiner (agent:connect-agent "/proj" :name "skipper" :paths paths
                                                 :ensure-broker nil)))
        (agent:disconnect-agent joiner)
        (unwind-protect
             (progn
               (dotimes (i 6) (agent:agent-publish pub (format nil "stale-~D" i)))
               (let ((s (agent:connect-agent "/proj" :name "skipper"
                                                     :paths paths :ensure-broker nil)))
                 (unwind-protect
                      (progn
                        (loop repeat 50 until (= 6 (getf (agent:agent-status s) :pending))
                              do (sleep 0.05))
                        (is = 6 (agent:agent-skip-to-head s))
                        (is = 0 (getf (agent:agent-status s) :pending))
                        (is = 0 (length (agent:agent-receive s))))
                   (agent:disconnect-agent s))))
          (agent:disconnect-agent pub))))))

;;; pending count matches delivery ---------------------------------------------

(define-test pending-count-counts-only-what-a-receive-would-return
  "The self-aware pending count matches delivery exactly. An agent that both
   publishes and consumes has its OWN un-consumed publishes ABOVE its cursor, but
   receive filters those out — so a pending count that included them would promise
   messages a receive then silently drops. The reported count is the FOREIGN
   records only (== what receive returns); the raw count still includes this
   agent's own. This is the regression guard for the status/receive mismatch."
  (with-bus (paths)
    (with-running-broker (br paths)
      (let ((me (agent:connect-agent "/proj" :name "me" :paths paths :ensure-broker nil))
            (them (agent:connect-agent "/proj" :name "them" :paths paths :ensure-broker nil)))
        (unwind-protect
             (progn
               ;; K = 2 of my own publishes, M = 3 foreign, interleaved above my
               ;; cursor (which seeded at the empty-log head when I connected).
               (agent:agent-publish me "mine-0")
               (agent:agent-publish them "foreign-0")
               (agent:agent-publish me "mine-1")
               (agent:agent-publish them "foreign-1")
               (agent:agent-publish them "foreign-2")
               (loop repeat 200
                     until (= 5 (wal:scan (broker:bus-paths-wal paths)))
                     do (sleep 0.02))
               ;; Reported pending == M: only the deliverable foreign records.
               (is = 3 (getf (agent:agent-status me) :pending)
                   "pending counts the 3 foreign records, not my own 2")
               ;; Raw count is K+M: the unfiltered position delta.
               (is = 5 (bus:poll-count (agent::agent-subscriber me))
                   "the raw count still includes my own un-consumed publishes")
               ;; And a receive returns EXACTLY those M foreign, in order — the
               ;; count promised what delivery delivers.
               (is equal '("foreign-0" "foreign-1" "foreign-2")
                   (agent:agent-receive me :timeout-ms 3000))
               (is = 0 (getf (agent:agent-status me) :pending)
                   "after draining, nothing foreign remains"))
          (agent:disconnect-agent me)
          (agent:disconnect-agent them))))))

(define-test legacy-unenveloped-record-is-pending-and-delivered
  "A record with no self-id — a legacy body from an old-core publisher — counts as
   foreign in BOTH the pending count and the receive, so a staggered rollout never
   drops or under-reports real traffic."
  (with-bus (paths)
    (with-running-broker (br paths)
      (let ((me (agent:connect-agent "/proj" :name "me" :paths paths :ensure-broker nil)))
        (unwind-protect
             (progn
               ;; Append a raw, un-enveloped record directly, as an old core would.
               (wal:append-record (broker:bus-paths-wal paths) 1 "a plain old body")
               (is = 1 (getf (agent:agent-status me) :pending)
                   "the un-enveloped record is counted as deliverable")
               (is equal '("a plain old body")
                   (agent:agent-receive me :timeout-ms 1000)
                   "and it is actually delivered"))
          (agent:disconnect-agent me))))))

(defun call-with-direct-addressing (enabled thunk)
  "Run THUNK with direct addressing definitively on or off, whatever the ambient
   shell says. The capability reads a special variable and an environment
   variable, so a test that set only the first would still answer differently in
   a developer's direnv shell from in an empty CI environment. The inherited
   value is put back afterwards."
  (let ((previous (uiop:getenv "DSMR_BUS_DIRECT_ADDRESSING"))
        (agent:*direct-addressing-enabled* enabled))
    (unwind-protect
         (progn (ignore-errors (sb-posix:unsetenv "DSMR_BUS_DIRECT_ADDRESSING"))
                (funcall thunk))
      (if previous
          (sb-posix:setenv "DSMR_BUS_DIRECT_ADDRESSING" previous 1)
          (ignore-errors (sb-posix:unsetenv "DSMR_BUS_DIRECT_ADDRESSING"))))))

(define-test addressing-hands-a-message-to-the-participant-it-names
  "A message that names a recipient reaches that recipient and nobody else, with
   the author that sent it attached. The capability is switched on explicitly
   here: it is off in every shipped configuration and no assertion in this suite
   leans on the default behaving otherwise."
  (with-bus (paths)
    (with-running-broker (br paths)
      (let ((sender (agent:connect-agent "/proj" :name "sender"
                                                 :paths paths :ensure-broker nil))
            (named (agent:connect-agent "/proj" :name "named"
                                                :paths paths :ensure-broker nil))
            (bystander (agent:connect-agent "/proj" :name "bystander"
                                                    :paths paths :ensure-broker nil)))
        (unwind-protect
             (call-with-direct-addressing t
               (lambda ()
                 (agent:agent-publish sender "for you alone"
                                      :to (agent:agent-id named))
                 (let ((mail (agent:agent-receive-detailed named :timeout-ms 3000)))
                   (is = 1 (length mail))
                   (is string= "for you alone" (agent:delivery-text (first mail)))
                   (is string= "sender" (agent:delivery-author (first mail))
                       "the recipient can see who addressed it"))
                 (is = 0 (length (agent:agent-receive bystander :timeout-ms 1000))
                     "a participant the message does not name is shown nothing")
                 (is = 0 (length (agent:agent-receive sender :timeout-ms 500))
                     "and the sender does not take delivery of its own message")))
          (agent:disconnect-agent sender)
          (agent:disconnect-agent named)
          (agent:disconnect-agent bystander))))))

(define-test a-bystander-cursor-advances-past-mail-for-somebody-else
  "The invariant addressing must never break. A participant that is not the
   recipient is shown nothing, and its cursor still moves past the record:
   after the receive nothing at all remains above it, and the next broadcast
   arrives normally. A reader that stopped at other people's mail would pin the
   write-ahead log, once per participant."
  (with-bus (paths)
    (with-running-broker (br paths)
      (let ((sender (agent:connect-agent "/proj" :name "sender"
                                                 :paths paths :ensure-broker nil))
            (named (agent:connect-agent "/proj" :name "named"
                                                :paths paths :ensure-broker nil))
            (bystander (agent:connect-agent "/proj" :name "bystander"
                                                    :paths paths :ensure-broker nil)))
        (unwind-protect
             (call-with-direct-addressing t
               (lambda ()
                 (agent:agent-publish sender "not for you"
                                      :to (agent:agent-id named))
                 (loop repeat 200
                       until (= 1 (wal:scan (broker:bus-paths-wal paths)))
                       do (sleep 0.02))
                 (is = 0 (length (agent:agent-receive bystander :timeout-ms 1000))
                     "nothing is handed to a participant the message does not name")
                 (is = 0 (bus:poll-count (agent::agent-subscriber bystander))
                     "and the raw count is zero: the cursor moved past the record")
                 (agent:agent-publish sender "everyone")
                 (is equal '("everyone")
                     (agent:agent-receive bystander :timeout-ms 3000)
                     "so a later broadcast is delivered normally")))
          (agent:disconnect-agent sender)
          (agent:disconnect-agent named)
          (agent:disconnect-agent bystander))))))

(define-test pending-count-leaves-out-mail-addressed-to-somebody-else
  "The count a status reports and the batch a receive hands back stay one
   verdict once addressing exists. Mail for another participant is in neither,
   while the raw position delta still counts it, which is what shows the record
   was passed over rather than held back."
  (with-bus (paths)
    (with-running-broker (br paths)
      (let ((sender (agent:connect-agent "/proj" :name "sender"
                                                 :paths paths :ensure-broker nil))
            (named (agent:connect-agent "/proj" :name "named"
                                                :paths paths :ensure-broker nil))
            (bystander (agent:connect-agent "/proj" :name "bystander"
                                                    :paths paths :ensure-broker nil)))
        (unwind-protect
             (call-with-direct-addressing t
               (lambda ()
                 (agent:agent-publish sender "for the named one"
                                      :to (agent:agent-id named))
                 (agent:agent-publish sender "for everyone")
                 (loop repeat 200
                       until (= 2 (wal:scan (broker:bus-paths-wal paths)))
                       do (sleep 0.02))
                 (is = 1 (getf (agent:agent-status bystander) :pending)
                     "only the broadcast is promised to the bystander")
                 (is = 2 (bus:poll-count (agent::agent-subscriber bystander))
                     "though both records sit above its cursor")
                 (is equal '("for everyone")
                     (agent:agent-receive bystander :timeout-ms 3000)
                     "and the batch is exactly what the count promised")
                 (is = 0 (getf (agent:agent-status bystander) :pending))))
          (agent:disconnect-agent sender)
          (agent:disconnect-agent named)
          (agent:disconnect-agent bystander))))))

(define-test an-addressed-publish-is-refused-while-the-capability-is-off
  "In the configuration everything ships in, naming a recipient is refused and
   nothing reaches the log. The refusal is the point: quietly broadcasting
   instead would put a message its sender believed had one reader in front of
   the whole fleet, with nothing to tell the sender it had happened. A publish
   that names nobody is untouched by the switch."
  (with-bus (paths)
    (with-running-broker (br paths)
      (let ((sender (agent:connect-agent "/proj" :name "sender"
                                                 :paths paths :ensure-broker nil))
            (other (agent:connect-agent "/proj" :name "other"
                                                :paths paths :ensure-broker nil)))
        (unwind-protect
             (call-with-direct-addressing nil
               (lambda ()
                 (fail (agent:agent-publish sender "psst"
                                            :to (agent:agent-id other))
                       agent:direct-addressing-disabled)
                 (is = 0 (wal:scan (broker:bus-paths-wal paths))
                     "the refused message never reached the log")
                 (agent:agent-publish sender "everyone")
                 (is equal '("everyone")
                     (agent:agent-receive other :timeout-ms 3000)
                     "a publish that names nobody is unaffected by the switch")))
          (agent:disconnect-agent sender)
          (agent:disconnect-agent other))))))

;;; watcher liveness surfaced through status -----------------------------------

(defun call-with-xdg-state (dir thunk)
  "Run THUNK with XDG_STATE_HOME set to DIR so the shared heartbeat's default
   watch directory resolves under a temp root, then restore the inherited value."
  (let ((previous (uiop:getenv "XDG_STATE_HOME")))
    (unwind-protect
         (progn (sb-posix:setenv "XDG_STATE_HOME" (namestring dir) 1)
                (funcall thunk))
      (if previous
          (sb-posix:setenv "XDG_STATE_HOME" previous 1)
          (ignore-errors (sb-posix:unsetenv "XDG_STATE_HOME"))))))

(define-test status-reports-watcher-liveness
  "agent-status surfaces whether a wakeup watcher is listening for THIS agent, read
   from the shared heartbeat under the agent's own identity. A fresh beat reads
   live; its absence reads dead. The temp XDG root's random suffix is seeded per
   call so a leftover from a prior fresh image never turns a `dead` assertion into
   a flake."
  (with-bus (paths)
    (with-running-broker (br paths)
      (let ((state-root (ensure-directories-exist
                         (merge-pathnames
                          (format nil "dsmr-agent-status-watch-~D-~D/"
                                  (sb-posix:getpid)
                                  (random 100000000 (make-random-state t)))
                          (uiop:temporary-directory)))))
        (unwind-protect
             (call-with-xdg-state state-root
               (lambda ()
                 (let ((me (agent:connect-agent "/proj" :name "watched"
                                                       :paths paths :ensure-broker nil)))
                   (unwind-protect
                        (progn
                          ;; No beat yet: the watch is not running.
                          (let ((st (agent:agent-status me)))
                            (is eq nil (getf st :live-watcher))
                            (is string= "dead" (getf st :watcher-status))
                            (is eq nil (getf st :watcher-age-seconds)))
                          ;; A running watch refreshes a beat under this identity.
                          (let ((beat (heartbeat:beat-path
                                       (agent:agent-id me) (heartbeat:default-watch-dir))))
                            (heartbeat:write-beat beat :mode :event :baseline 0 :poll-ms 250)
                            (let ((st (agent:agent-status me)))
                              (is eq t (getf st :live-watcher))
                              (is string= "live" (getf st :watcher-status))
                              (true (integerp (getf st :watcher-age-seconds))))
                            ;; Removed on clean exit: back to dead.
                            (heartbeat:remove-beat beat)
                            (is eq nil (getf (agent:agent-status me) :live-watcher)
                                "an absent beat reads as no watcher")))
                     (agent:disconnect-agent me)))))
          (ignore-errors (uiop:delete-directory-tree state-root :validate t)))))))

(define-test connect-agent-records-the-bus-it-joined
  "A participant knows which bus it is on, and the handle is where every surface
   downstream reads it from rather than assuming there is only one bus. With no
   :bus the paths are exactly the ones this has always derived; with a name they
   sit under that name's own root, with a write-ahead log of their own. The temp
   XDG root's suffix is seeded per call so a leftover tree from an earlier image
   cannot turn an assertion about a fresh root into a flake."
  (let ((state-root (ensure-directories-exist
                     (merge-pathnames
                      (format nil "dsmr-agent-named-bus-~D-~D/"
                              (sb-posix:getpid)
                              (random 100000000 (make-random-state t)))
                      (uiop:temporary-directory)))))
    (unwind-protect
         (call-with-xdg-state state-root
           (lambda ()
             (let ((here (agent:connect-agent "/proj" :name "here"
                                                      :ensure-broker nil))
                   (there (agent:connect-agent "/proj" :name "there" :bus "alpha"
                                                       :ensure-broker nil)))
               (unwind-protect
                    (progn
                      (is eq nil (agent:agent-bus here)
                          "no :bus means the host's unnamed bus")
                      (is string= "alpha" (agent:agent-bus there))
                      (is string= (namestring (selector:bus-root nil))
                          (namestring (broker:bus-paths-root
                                       (agent:agent-paths here)))
                          "the unnamed participant keeps today's root")
                      (is string= (namestring (selector:bus-root "alpha"))
                          (namestring (broker:bus-paths-root
                                       (agent:agent-paths there)))
                          "the named participant sits under its own root")
                      (false (equal (broker:bus-paths-wal
                                     (agent:agent-paths here))
                                    (broker:bus-paths-wal
                                     (agent:agent-paths there)))
                             "the two buses keep separate write-ahead logs"))
                 (agent:disconnect-agent here)
                 (agent:disconnect-agent there)))))
      (ignore-errors (uiop:delete-directory-tree state-root :validate t)))))
