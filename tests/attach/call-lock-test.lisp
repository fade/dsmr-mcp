;;;; tests/attach/call-lock-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Unit tests for the process-wide *attach-call-lock* serialisation policy,
;;;; the :parallel opt-out, the queued-position notification side effect, and
;;;; the source audit ensuring no tool reaches the developer's live image
;;;; without serialising the call. The audit's own red condition is covered
;;;; here too, against fixtures, so a green run on a clean tree is evidence
;;;; the audit is working rather than evidence it is silent.

(defpackage #:dsmr-mcp/tests/attach/call-lock-test
  (:use #:cl #:zebra)
  (:import-from #:dsmr-mcp/src/attach/dispatch
                #:*attach-call-lock*
                #:*attach-concurrency*
                #:*attach-waiters*
                #:*attach-waiters-lock*
                #:*attach-holder-session-id*
                #:with-serialised-attach-call
                #:%resolve-attach-concurrency)
  (:import-from #:dsmr-mcp/src/state
                #:make-session
                #:session-id
                #:session-notify-channel)
  (:import-from #:dsmr-mcp/src/notify
                #:null-channel
                #:tcp-line-channel)
  (:import-from #:bordeaux-threads
                #:make-thread
                #:join-thread
                #:make-lock
                #:with-lock-held))

(in-package #:dsmr-mcp/tests/attach/call-lock-test)

;;; ---------------------------------------------------------------------------
;;; Helpers
;;; ---------------------------------------------------------------------------

(defun %session-with-tcp-channel (id)
  "Create a session with a tcp-line-channel wrapping a fresh string-output-stream.
Returns (values session stream)."
  (let* ((out (make-string-output-stream))
         (ch  (make-instance 'tcp-line-channel :stream out))
         (s   (make-session :id id)))
    (setf (session-notify-channel s) ch)
    (values s out)))

(defun %reset-attach-state ()
  "Reset the process-wide attach call-lock state between tests.
Clears *attach-waiters* and *attach-holder-session-id* so tests don't
interfere with each other."
  (bordeaux-threads:with-lock-held (*attach-waiters-lock*)
    (setf *attach-waiters* nil)
    (setf *attach-holder-session-id* nil)))

;;; ---------------------------------------------------------------------------
;;; Tests
;;; ---------------------------------------------------------------------------

(define-test serialised-concurrency-sequences-calls
  "Under :serialised concurrency two threads calling with-serialised-attach-call
execute their bodies sequentially: the second thread's body starts only after
the first thread's body completes."
  ;; Reset global attach state from any prior test.
  (%reset-attach-state)
  ;; We use a shared timestamp log to verify sequential execution.
  ;; Thread 1 enters first, holds the lock for 60 ms, then records :t1-done.
  ;; Thread 2 also tries to enter; it should record :t2-start only after t1-done.
  (let ((*attach-concurrency* :serialised)
        (log nil)
        (log-lock (bordeaux-threads:make-lock "call-lock-test-log")))
    (let ((s1 (make-session :id "lock-test-s1"))
          (s2 (make-session :id "lock-test-s2")))
      (let ((t1 (bordeaux-threads:make-thread
                 (lambda ()
                   (with-serialised-attach-call (s1)
                     (sleep 0.06d0)
                     (bordeaux-threads:with-lock-held (log-lock)
                       (push :t1-done log))))
                 :name "call-lock-test-t1")))
        ;; Small sleep so t1 enters the lock first.
        (sleep 0.01d0)
        (let ((t2 (bordeaux-threads:make-thread
                   (lambda ()
                     (with-serialised-attach-call (s2)
                       (bordeaux-threads:with-lock-held (log-lock)
                         (push :t2-start log))))
                   :name "call-lock-test-t2")))
          (bordeaux-threads:join-thread t1)
          (bordeaux-threads:join-thread t2)
          ;; Log is in reverse push order: (:t2-start :t1-done)
          ;; meaning t1-done happened before t2-start.
          (is = 2 (length log))
          (is eq :t1-done (second log))
          (is eq :t2-start (first log)))))))

(define-test parallel-concurrency-does-not-block
  "Under :parallel concurrency two threads calling with-serialised-attach-call
execute their bodies without waiting for each other."
  (%reset-attach-state)
  ;; Use setf (not let) so spawned threads also see :parallel.
  (let ((saved-concurrency *attach-concurrency*)
        (counter 0)
        (counter-lock (bordeaux-threads:make-lock "parallel-test-lock")))
    (setf *attach-concurrency* :parallel)
    (unwind-protect
         (let ((s1 (make-session :id "parallel-test-s1"))
               (s2 (make-session :id "parallel-test-s2")))
           (let ((t1 (bordeaux-threads:make-thread
                      (lambda ()
                        (with-serialised-attach-call (s1)
                          (bordeaux-threads:with-lock-held (counter-lock)
                            (incf counter))))
                      :name "parallel-test-t1"))
                 (t2 (bordeaux-threads:make-thread
                      (lambda ()
                        (with-serialised-attach-call (s2)
                          (bordeaux-threads:with-lock-held (counter-lock)
                            (incf counter))))
                      :name "parallel-test-t2")))
             (bordeaux-threads:join-thread t1)
             (bordeaux-threads:join-thread t2)
             ;; Both threads ran.
             (is = 2 counter)))
      (setf *attach-concurrency* saved-concurrency))))

(define-test queued-session-receives-position-notification
  "When session B enters with-serialised-attach-call while session A holds
the lock, session B's notify-channel receives a
notifications/dsmr-mcp/attach/queued notification with 'position' and
'holder_session_id' before session B blocks."
  (%reset-attach-state)
  (let ((*attach-concurrency* :serialised))
    (multiple-value-bind (s-a out-a)
        (%session-with-tcp-channel "holder-a")
      (declare (ignore out-a))
      (multiple-value-bind (s-b out-b)
          (%session-with-tcp-channel "waiter-b")
        ;; Thread A holds the lock for 150 ms.
        (let* ((a-holding nil)
               (a-hold-lock (bordeaux-threads:make-lock "a-hold-lock"))
               (t-a (bordeaux-threads:make-thread
                     (lambda ()
                       (with-serialised-attach-call (s-a)
                         (bordeaux-threads:with-lock-held (a-hold-lock)
                           (setf a-holding t))
                         (sleep 0.15d0)))
                     :name "queued-test-holder")))
          ;; Wait until A has entered the critical section before spawning t-b.
          (loop until (bordeaux-threads:with-lock-held (a-hold-lock)
                        a-holding)
                do (sleep 0.005d0))
          (let ((t-b (bordeaux-threads:make-thread
                      (lambda ()
                        (with-serialised-attach-call (s-b)
                          nil))
                      :name "queued-test-waiter")))
            (bordeaux-threads:join-thread t-a)
            (bordeaux-threads:join-thread t-b)
            ;; Session B's channel should have received a queued notification.
            (let ((captured (get-output-stream-string out-b)))
              (true (search "notifications/dsmr-mcp/attach/queued" captured))
              (true (search "position" captured))
              (true (search "holder-a" captured)))))))))

(define-test concurrency-env-parser-rejects-invalid
  "%%resolve-attach-concurrency signals invalid-config-value for unknown values."
  (fail (%resolve-attach-concurrency "bogus")
        dsmr-mcp/src/run:invalid-config-value))

(defun %token-delimited-search (needle text)
  "True when NEEDLE occurs in TEXT and is not immediately followed by another
symbol character.

A plain SEARCH for \"(:attached\" also matches the keyword :ATTACHED-RESET,
which names a field in the reset-local result and has nothing to do with the
attached dispatch path. Requiring a delimiter after the match keeps a tool
that merely reports on the attached connection out of the audit's scope."
  (let ((needle-length (length needle))
        (text-length   (length text)))
    (loop with start = 0
          for position = (search needle text :start2 start)
          while position
          do (let* ((index     (+ position needle-length))
                    (following (when (< index text-length)
                                 (char text index))))
               (when (or (null following)
                         (not (or (alphanumericp following)
                                  (find following "-_/*+<>=?!%&."))))
                 (return t))
               (setf start (1+ position)))
          finally (return nil))))

(defparameter +audit-exemption-marker+
  "ATTACH-CALL-AUDIT: does not serialise"
  "The marker a file carries to declare that it reaches the developer's image
and deliberately holds no lock while doing so.

An earlier attempt at this exempted a file by whether it named one of a fixed
list of connection operators. Such a list is incomplete by construction: a file
reaching the image through a helper the list does not name is exempted in
silence, which is the failure the whole audit exists to prevent arriving through
the audit's own front door. A declaration cannot be reached by accident. The
reason goes beside the marker in the file, and the set of files carrying one is
asserted below, so an exemption cannot be added without somebody editing the
expected set and being seen to do it.")

(defun %declares-no-serialisation-p (text)
  "True when TEXT declares itself a deliberate exception to the lock rule."
  (and (search +audit-exemption-marker+ text) t))

(defun %reaches-attached-image-p (text)
  "True when TEXT belongs to code that evaluates something in the developer's
live image: it either names the wire call directly or carries an :attached
dispatch arm.

Either signal on its own is enough, and neither is qualified any further.
Naming bounded-slime-eval catches a caller whose attached branch is selected
some other way, and the :attached arm catches one that reaches the image
through a helper this audit cannot see. That second case is the whole reason
the arm counts on its own, so nothing may narrow it: a file that reaches the
image by a route nobody thought to enumerate is exactly the file this has to
keep catching. A caller that reaches the image and holds no lock on purpose
says so with the exemption marker instead."
  (or (search "bounded-slime-eval" text)
      (%token-delimited-search "(:attached" text)))

(defun %serialises-attach-call-p (text)
  "True when TEXT shows one of the idioms that give a caller exclusive use of
the attached image for the duration of its eval.

Three idioms are in use and all three are correct:

  with-attach-dispatch        routes the whole call through the process-wide
                              attach call-lock.
  with-serialised-attach-call the same process-wide lock, taken directly.
  with-lock-held on the       the per-session lock carried by the session's
  repl-eval-tool-call-lock    repl-eval-tool instance. This is how every tool
                              outside src/attach/ serialises its own round
                              trip on the shared connection.

Recognising only the first two names flags nine tools that serialise correctly.
An audit that cries wolf gets deleted by whoever it blocks, so the third idiom
belongs here."
  (or (search "with-serialised-attach-call" text)
      (search "with-attach-dispatch" text)
      (and (search "repl-eval-tool-call-lock" text)
           (search "with-lock-held" text))))

(defun %in-audit-scope-p (text)
  "True when TEXT is source this audit is answerable for.

Tool handlers are the bulk of it. The cancellation path is the other one, and
it was missed for as long as this gate read only the tool-handler marker: the
transport's :attached arm calls CANCEL-ATTACHED-EVAL, which puts a real
interrupt and a real restart rex on the wire, and neither that call site nor the
machinery behind it defines a tool handler. Being outside the gate is not the
same as being judged safe, and a file the audit never opened cannot be said to
have passed it."
  (or (search "defmethod tool-handle" text)
      (search "cancel-attached-eval" text)))

(defun %unserialised-attach-arms (directory)
  "Scan DIRECTORY recursively for source that reaches the attached image without
serialising the call and without declaring that it does so on purpose.

Returns (values violations scanned exempt). VIOLATIONS and EXEMPT are lists of
namestrings. SCANNED is how many files were in scope, which is what lets a
caller tell a clean tree apart from a file walk that found nothing to look at.

Scope is decided by %IN-AUDIT-SCOPE-P and then by whether the file reaches the
image at all. A file that reaches it and holds no lock is a violation unless it
carries the exemption marker, in which case it is returned in EXEMPT and the
caller asserts on the whole set.

The audit is per file, not per call site: a file that serialises one eval and
leaves a second one bare still passes. That bound is deliberate. What this
catches is a new caller arriving with no serialisation at all, which is the
shape the omission actually takes."
  (let ((violations nil)
        (exempt nil)
        (scanned 0))
    (dolist (file (directory (merge-pathnames "**/*.lisp" directory)))
      (let ((text (uiop:read-file-string file)))
        (when (and (%in-audit-scope-p text)
                   (%reaches-attached-image-p text))
          (incf scanned)
          (cond ((%serialises-attach-call-p text))
                ((%declares-no-serialisation-p text)
                 (push (namestring file) exempt))
                (t (push (namestring file) violations))))))
    (values (nreverse violations) scanned (nreverse exempt))))

(defun %fresh-audit-fixture-directory ()
  "Create and return a fresh empty directory under the system temporary
directory.

SBCL's default random state repeats across runs, so a name drawn from it
collides with the previous run's leftovers and the fixture would inherit files
it never wrote. Seeding from the environment keeps each run's directory
its own."
  (let ((path (merge-pathnames
               (format nil "dsmr-attach-call-audit-~36R/"
                       (random (expt 2 64) (make-random-state t)))
               (uiop:temporary-directory))))
    (ensure-directories-exist path)
    path))

(defun %write-audit-fixture (directory name text)
  "Write TEXT to NAME under DIRECTORY and return the path.
The fixtures are read as text by the audit and never compiled, so they only
have to look like tool source, not load."
  (let ((path (merge-pathnames name directory)))
    (with-open-file (out path :direction :output
                              :if-exists :supersede
                              :if-does-not-exist :create)
      (write-string text out))
    path))

(define-test every-attached-arm-uses-serialised-call
  "Every caller that reaches the developer's live image either serialises the
call or declares in the file why it must not.

Two evals in flight on one Slynk connection interleave their rex traffic and
read each other's replies, so a caller that talks to the attached image while
holding neither the process-wide attach call-lock nor its session's own
call-lock is a bug the moment two sessions are active.

The second assertion is the one that keeps the first honest. Exemptions are
listed here by name, so adding one is an edit to this test that a reader will
see, rather than a property a new file can acquire by how it happens to be
written. Each name below is a decision, and the reason for it sits beside the
marker in the file itself:

  backend-status.lisp  reports recorded state and puts nothing on the wire.
  cancel.lisp          drives the interrupt and the abort.
  stdio.lisp           calls that path from the transport's :attached arm.

The audit is a source scan over src/, described in %unserialised-attach-arms
along with what it does and does not see. Its ability to report a violation is
covered by attach-call-audit-flags-an-unserialised-tool."
  (multiple-value-bind (violations scanned exempt)
      (%unserialised-attach-arms
       (merge-pathnames "src/"
                        (asdf:system-source-directory
                         (asdf:find-system :dsmr-mcp))))
    ;; Without this the audit passes vacuously whenever the file walk finds
    ;; nothing, and a broken walk looks exactly like a clean tree.
    (true (plusp scanned)
          "attach-call audit scanned no files at all; the src/ walk is broken")
    (is equal '() violations
        "caller reaches the attached image without serialising the call: ~{~A~^, ~}"
        violations)
    (is equal '("backend-status.lisp" "cancel.lisp" "stdio.lisp")
        (sort (mapcar #'file-namestring exempt) #'string<)
        "the set of files exempted from the lock rule has changed: ~{~A~^, ~}"
        exempt)))

(define-test attach-call-audit-flags-an-unserialised-tool
  "The audit reports a caller that reaches the attached image holding no lock,
and stays quiet for each of the idioms that do serialise and for a file that
declares why it must not.

A green result on a clean tree says nothing about whether the audit can speak at
all, so the red condition is planted here rather than left to be discovered the
first time it matters.

Three of these fixtures pin edges that were previously unpinned or wrongly
pinned, and each says which:

  helper-route          reaches the image through a helper whose name appears
                        in no list anywhere in this file. An earlier version of
                        this fixture called ATTACHED-CONNECTION, which meant it
                        agreed with the predicate of the day by construction and
                        could not have detected a narrowing. Named this way it
                        goes red the moment the arm stops counting on its own.
  cancel-shaped         the shape the transport actually has: an :attached arm
                        calling the cancellation path, and no tool handler
                        anywhere in the file. It is what the scope gate missed
                        while it read only the tool-handler marker.
  declared-exempt       the same shape carrying the marker, which must be
                        exempted rather than reported, and must show up in the
                        exempt set rather than vanishing from both.

The reporting fixture pins the other half of the token test: a file whose only
mention of the word is the :attached-reset result field must not be reported,
because a false name in the list makes the real ones easy to miss."
  (let ((dir (%fresh-audit-fixture-directory)))
    (unwind-protect
         (progn
           (%write-audit-fixture
            dir "bare.lisp"
            "(defmethod tool-handle ((tool bare-tool) id args)
  (case (session-backend-mode (tool-session tool))
    (:attached (result id (bounded-slime-eval form (attached-connection tool))))))")
           (%write-audit-fixture
            dir "session-lock.lisp"
            "(defmethod tool-handle ((tool session-lock-tool) id args)
  (case (session-backend-mode (tool-session tool))
    (:attached
     (let ((lock (repl-eval-tool-call-lock tool)))
       (with-lock-held (lock)
         (result id (bounded-slime-eval form (attached-connection tool))))))))")
           (%write-audit-fixture
            dir "process-lock.lisp"
            "(defmethod tool-handle ((tool process-lock-tool) id args)
  (case (session-backend-mode (tool-session tool))
    (:attached
     (with-serialised-attach-call ((tool-session tool))
       (result id (bounded-slime-eval form (attached-connection tool)))))))")
           (%write-audit-fixture
            dir "dispatch-macro.lisp"
            "(defmethod tool-handle ((tool dispatch-macro-tool) id args)
  (with-attach-dispatch (id tool args)
    (rpc-error id -32603 \"requires an attached Slynk listener\")))
(defun helper () (bounded-slime-eval form conn))")
           (%write-audit-fixture
            dir "no-attached-arm.lisp"
            "(defmethod tool-handle ((tool reporting-tool) id args)
  (result id (make-ht \"attached_reset\" (getf outcome :attached-reset))))")
           (%write-audit-fixture
            dir "helper-route.lisp"
            "(defmethod tool-handle ((tool helper-route-tool) id args)
  (case *mode*
    (:attached (result id (ask-the-developers-image tool)))))")
           (%write-audit-fixture
            dir "cancel-shaped.lisp"
            "(defun stop-in-flight (p)
  (case (promise-mode p)
    (:attached (cancel-attached-eval p))))")
           (%write-audit-fixture
            dir "declared-exempt.lisp"
            ";;;; ATTACH-CALL-AUDIT: does not serialise. Cancelling reaches the
;;;; image while the call being cancelled holds the lock.
(defun stop-in-flight-declared (p)
  (case (promise-mode p)
    (:attached (cancel-attached-eval p))))")
           (%write-audit-fixture
            dir "reads-recorded-state.lisp"
            ";;;; ATTACH-CALL-AUDIT: does not serialise. Reads recorded state only.
(defmethod tool-handle ((tool status-tool) id args)
  (case *mode*
    (:attached
     (result id (make-ht \"liveness\" (repl-eval-tool-liveness tool)
                         \"epoch\" (repl-eval-tool-connection-epoch tool))))))")
           (multiple-value-bind (violations scanned exempt)
               (%unserialised-attach-arms dir)
             ;; Eight fixtures are in scope and reach the image. The reporting
             ;; tool is the one that does not: its only mention of the word is a
             ;; result field, which the token test rejects.
             (is = 8 scanned)
             (is equal '("bare.lisp" "cancel-shaped.lisp" "helper-route.lisp")
                 (sort (mapcar #'file-namestring violations) #'string<))
             (is equal '("declared-exempt.lisp" "reads-recorded-state.lisp")
                 (sort (mapcar #'file-namestring exempt) #'string<))))
      (uiop:delete-directory-tree dir :validate t))))
