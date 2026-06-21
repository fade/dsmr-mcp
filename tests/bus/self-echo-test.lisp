;;;; tests/bus/self-echo-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Self-wake and self-echo, the two behaviors that ride the publish envelope,
;;;; verified against an in-process broker thread. The publisher learns its OWN
;;;; broker-assigned seq by a globally-unique correlation-id (race-free under
;;;; concurrent cross-process publishing), and an agent never receives its own
;;;; messages back — while a foreign message interleaved below its own publish is
;;;; STILL delivered (no message lost across the gap, the regression the forbidden
;;;; cursor-advance design would have broken).

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/bus/self-echo-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/bus/self-echo-test
  (:use #:cl #:parachute)
  (:local-nicknames (#:broker #:dsmr-mcp/src/bus/broker)
                    (#:bus #:dsmr-mcp/src/bus/bus)
                    (#:agent #:dsmr-mcp/src/bus/agent)
                    (#:wal #:dsmr-mcp/src/bus/wal)))

(in-package #:dsmr-mcp/tests/bus/self-echo-test)

;;; harness (copied from agent-test.lisp) --------------------------------------

(defmacro with-bus ((paths) &body body)
  (let ((name (gensym)) (root (gensym)))
    `(let* ((,name (uiop:with-temporary-file (:pathname p :keep t :prefix "dsmr-bus-self-echo") p))
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
                      :name "self-echo-test-broker")))
       (unwind-protect (progn ,@body)
         (setf ,stop t)
         (ignore-errors (sb-thread:join-thread ,thread))
         (ignore-errors (broker:stop-broker ,br))))))

(defun wait-durable (paths n)
  "Wait until at least N records are durably logged (the flow-test sync pattern)."
  (loop repeat 200
        until (>= (wal:scan (broker:bus-paths-wal paths)) n)
        do (sleep 0.02)))

(defun decoded-text-at-seq (paths seq)
  "Read back the WAL record at SEQ and return its decoded user text — so a test can
   assert the seq the publisher returned actually points at the publisher's OWN
   payload, not a concurrent foreign agent's."
  (let ((record (first (wal:read-records (broker:bus-paths-wal paths) :after (1- seq)))))
    (and record (bus:delivered-body-string record))))

;;; tests ----------------------------------------------------------------------

(define-test publish-returns-assigned-seq
  "agent-publish returns a positive integer that is the seq the broker assigned to
   that exact payload."
  (with-bus (paths)
    (with-running-broker (br paths)
      (let ((a (agent:connect-agent "/proj" :name "pub" :paths paths :ensure-broker nil)))
        (unwind-protect
             (let ((seq (agent:agent-publish a "m1")))
               (true (and (integerp seq) (plusp seq)) "seq is a positive integer")
               (wait-durable paths seq)
               (is string= "m1" (decoded-text-at-seq paths seq)
                   "the returned seq points at the published payload"))
          (agent:disconnect-agent a))))))

(define-test successive-seqs-increase
  "Two publishes by the same agent return strictly increasing seqs."
  (with-bus (paths)
    (with-running-broker (br paths)
      (let ((a (agent:connect-agent "/proj" :name "pub" :paths paths :ensure-broker nil)))
        (unwind-protect
             (let ((s1 (agent:agent-publish a "a")))
               (wait-durable paths s1)
               (let ((s2 (agent:agent-publish a "b")))
                 (wait-durable paths s2)
                 (true (> s2 s1) "the second seq is strictly greater than the first")))
          (agent:disconnect-agent a))))))

(define-test concurrent-publishers-get-their-own-seq
  "The seq race-freedom proof: two agents interleave publishes; EACH returned seq,
   read back, carries that agent's OWN payload — never the other's — and each
   agent's own receive is empty (self-filtered)."
  (with-bus (paths)
    (with-running-broker (br paths)
      (let ((a (agent:connect-agent "/proj" :name "agent-a" :paths paths :ensure-broker nil))
            (b (agent:connect-agent "/proj" :name "agent-b" :paths paths :ensure-broker nil)))
        (unwind-protect
             (let ((a-seqs '()) (b-seqs '()))
               (dotimes (i 3)
                 (let ((sa (agent:agent-publish a "from-a")))
                   (wait-durable paths sa) (push sa a-seqs))
                 (let ((sb (agent:agent-publish b "from-b")))
                   (wait-durable paths sb) (push sb b-seqs)))
               (dolist (sa a-seqs)
                 (is string= "from-a" (decoded-text-at-seq paths sa)
                     "agent A's returned seq carries A's own payload"))
               (dolist (sb b-seqs)
                 (is string= "from-b" (decoded-text-at-seq paths sb)
                     "agent B's returned seq carries B's own payload"))
               ;; Each agent filters out ONLY its own messages: A's receive carries
               ;; none of "from-a" (every surviving record is B's "from-b"), and
               ;; symmetrically for B. The foreign messages still arrive — that is
               ;; the no-message-loss guarantee, not a self-echo leak.
               (let ((a-got (agent:agent-receive a :timeout-ms 200)))
                 (false (member "from-a" a-got :test #'string=)
                        "agent A receives none of its OWN messages")
                 (true (every (lambda (m) (string= m "from-b")) a-got)
                       "every message A receives is foreign (B's)"))
               (let ((b-got (agent:agent-receive b :timeout-ms 200)))
                 (false (member "from-b" b-got :test #'string=)
                        "agent B receives none of its OWN messages")
                 (true (every (lambda (m) (string= m "from-a")) b-got)
                       "every message B receives is foreign (A's)")))
          (agent:disconnect-agent a)
          (agent:disconnect-agent b))))))

(define-test foreign-message-not-skipped-across-publish
  "No-message-loss across the gap: a foreign agent F publishes, THEN agent A
   publishes its own message above F's. A's receive must still return F's message
   — A's own is filtered, but F's (sitting BELOW A's) was NOT skipped. A
   cursor-advance self-echo design would lose 'foreign' here; receive-side
   filtering does not."
  (with-bus (paths)
    (with-running-broker (br paths)
      (let ((a (agent:connect-agent "/proj" :name "agent-a" :paths paths :ensure-broker nil))
            (f (agent:connect-agent "/proj" :name "agent-f" :paths paths :ensure-broker nil)))
        (unwind-protect
             (let ((sf (agent:agent-publish f "foreign")))
               (wait-durable paths sf)
               (let ((sa (agent:agent-publish a "mine")))
                 (wait-durable paths sa)
                 (is equal '("foreign") (agent:agent-receive a :timeout-ms 1000)
                     "A receives the foreign message below its own publish, not its own")))
          (agent:disconnect-agent a)
          (agent:disconnect-agent f))))))

(define-test other-subscriber-receives-stripped-text
  "A distinct agent B receives the BARE user text — delivery works for B and the
   correlation-id / self-id envelope is stripped (a leaked prefix would fail this)."
  (with-bus (paths)
    (with-running-broker (br paths)
      (let ((a (agent:connect-agent "/proj" :name "agent-a" :paths paths :ensure-broker nil))
            (b (agent:connect-agent "/proj" :name "agent-b" :paths paths :ensure-broker nil)))
        (unwind-protect
             (progn
               (agent:agent-publish a "to-b")
               (is equal '("to-b") (agent:agent-receive b :timeout-ms 3000)
                   "B receives the original text, envelope stripped"))
          (agent:disconnect-agent a)
          (agent:disconnect-agent b))))))

(define-test cross-agent-ordering-intact
  "A fresh subscriber C receives every message with contiguous, gap-free seqs, each
   decoded to its text."
  (with-bus (paths)
    (with-running-broker (br paths)
      (let ((a (agent:connect-agent "/proj" :name "agent-a" :paths paths :ensure-broker nil))
            (b (agent:connect-agent "/proj" :name "agent-b" :paths paths :ensure-broker nil)))
        (unwind-protect
             (progn
               (let ((sa (agent:agent-publish a "a1"))) (wait-durable paths sa))
               (let ((sb (agent:agent-publish b "b1"))) (wait-durable paths sb))
               (is = 2 (wal:scan (broker:bus-paths-wal paths))
                   "two contiguous gap-free seqs were assigned")
               (let ((c (agent:connect-agent "/proj" :name "agent-c" :paths paths :ensure-broker nil)))
                 (unwind-protect
                      (let ((got (agent:agent-receive c :timeout-ms 3000)))
                        (is equal '("a1" "b1") got
                            "C receives both messages, in order, decoded to their text"))
                   (agent:disconnect-agent c))))
          (agent:disconnect-agent a)
          (agent:disconnect-agent b))))))
