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
  "A named agent that disconnects and reconnects resumes after its last message."
  (with-bus (paths)
    (with-running-broker (br paths)
      (let ((pub (agent:connect-agent "/proj" :name "pub" :paths paths :ensure-broker nil)))
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
