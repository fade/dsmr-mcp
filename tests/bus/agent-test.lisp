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
                    (#:agent #:dsmr-mcp/src/bus/agent)))

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
