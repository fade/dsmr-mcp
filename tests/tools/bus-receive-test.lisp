;;;; tests/tools/bus-receive-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; The bus-receive tool boundary: bounded delivery, the limit guard, and the
;;;; explicit abandonment of a backlog.
;;;;
;;;; The bus core owns the mutation — this verb only translates arguments into a
;;;; call and formats the reply — so these tests assert on what a caller of the
;;;; verb can actually observe: how many messages came back, how many the reply
;;;; says are still waiting, whether a bad limit was refused before it reached
;;;; the core, and what a deliberate skip reports having given up.
;;;;
;;;; A participant now joins at the current head of the log, so every test
;;;; connects its receiving agent BEFORE the traffic it expects to see. The
;;;; backlog is published by a second, separate agent: the receive path filters
;;;; out an agent's own messages, so a self-published backlog would come back
;;;; empty while still consuming the cursor.
;;;;
;;;; Each test isolates XDG_STATE_HOME to a temp directory and runs an in-process
;;;; broker there, so nothing here touches the developer's host-wide bus.

;; Package evolution guard: drop a prior incarnation so a reload picks up the
;; current import/export set rather than stale symbols.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/tools/bus-receive-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/tools/bus-receive-test
  (:use #:cl #:parachute)
  (:local-nicknames (#:broker #:dsmr-mcp/src/bus/broker)
                    (#:agent #:dsmr-mcp/src/bus/agent)
                    (#:zmq #:dsmr-mcp/src/bus/zmq)
                    (#:selector #:dsmr-mcp/src/bus/selector)
                    (#:wal #:dsmr-mcp/src/bus/wal))
  (:import-from #:dsmr-mcp/src/bus/bus
                #:+default-batch-size+)
  (:import-from #:dsmr-mcp/src/tools/base
                #:tool-handle)
  (:import-from #:dsmr-mcp/src/tools/bus-helpers
                #:session-agent
                #:disconnect-session-bus)
  (:import-from #:dsmr-mcp/src/tools/bus-receive
                #:bus-receive-tool)
  (:import-from #:dsmr-mcp/src/state
                #:make-session)
  (:import-from #:dsmr-mcp/tests/support/env-fixture
                #:with-clean-resolution-env))

(in-package #:dsmr-mcp/tests/tools/bus-receive-test)

;;; ---------------------------------------------------------------------------
;;; Fixture: an isolated host bus on a temp XDG_STATE_HOME, served in-process.
;;; ---------------------------------------------------------------------------

(defun %make-temp-directory ()
  "Create a uniquely named temp directory under /tmp and return its pathname.
   The random state is seeded per call: SBCL's default state is identical in
   every fresh image, so an unseeded name repeats across runs and an absence
   assertion can pass on a leftover directory."
  (let ((*random-state* (make-random-state t)))
    (loop
      (let* ((rand-part (format nil "dsmr-bus-recv-~8,'0X" (random #xFFFFFFFF)))
             (dir-pn    (uiop:ensure-directory-pathname
                         (merge-pathnames rand-part #p"/tmp/"))))
        (unless (probe-file dir-pn)
          (ensure-directories-exist dir-pn)
          (return dir-pn))))))

(defun %serve-bus-in-process (paths)
  "Elect a broker on PATHS and serve it on a background thread. Returns a thunk
   that stops it and joins the thread, so a caller holding several of these can
   shut them down in whatever order it needs."
  (broker:ensure-bus-dirs paths)
  (let* ((br (broker:start-broker paths :block nil))
         (stop nil)
         (thread (sb-thread:make-thread
                  (lambda () (broker:serve-broker br (lambda () stop)))
                  :name "bus-receive-test-broker")))
    (lambda ()
      (setf stop t)
      (ignore-errors (sb-thread:join-thread thread))
      (ignore-errors (broker:stop-broker br)))))

(defmacro with-isolated-bus ((&rest bus-names) &body body)
  "Run BODY with XDG_STATE_HOME pointed at a fresh temp directory and an
   in-process broker serving the unnamed bus derived from it, so the tool
   connects to a private bus and never touches the host-wide one.

   Each name in BUS-NAMES additionally gets its own served bus under that same
   temp root, which is how one test can read from two buses at once. With no
   names this is exactly the single-bus fixture it has always been. Brokers stop
   in the reverse of the order they started, then XDG_STATE_HOME is restored and
   the temp tree removed."
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
   DSMR_BUS_AGENT and the other resolution vars neutralized, and disconnect
   every participant the session opened on the way out."
  (let ((root (gensym "ROOT")))
    `(with-clean-resolution-env
       (let* ((,root (%make-temp-directory))
              (,session-var (make-session :id "bus-receive" :project-root ,root)))
         (unwind-protect (progn ,@body)
           (ignore-errors (disconnect-session-bus ,session-var))
           (ignore-errors (uiop:delete-directory-tree
                           ,root :validate t :if-does-not-exist :ignore)))))))

;;; ---------------------------------------------------------------------------
;;; Driving the verb
;;; ---------------------------------------------------------------------------

(defun %args (&rest kvs)
  "An MCP arguments hash-table from alternating string-key/value pairs."
  (let ((ht (make-hash-table :test 'equal)))
    (loop for (k v) on kvs by #'cddr do (setf (gethash k ht) v))
    ht))

(defun %call (session &rest kvs)
  "Invoke bus-receive for SESSION with the given arguments and return the result
   payload (the tool's own hash-table, unwrapped from the JSON-RPC envelope)."
  (let ((tool (make-instance 'bus-receive-tool :session session)))
    (gethash "result" (tool-handle tool 1 (apply #'%args kvs)))))

(defun %field (payload key)
  (gethash key payload))

(defun %messages (payload)
  "The delivered messages as a list of message objects, in delivery order. Each
   is a hash-table carrying the body and the agent that published it."
  (coerce (gethash "messages" payload) 'list))

(defun %texts (payload)
  "Just the bodies of the delivered messages, in delivery order."
  (mapcar (lambda (m) (gethash "text" m)) (%messages payload)))

(defun %authors (payload)
  "The rendered author of each delivered message, in delivery order."
  (mapcar (lambda (m) (gethash "author" m)) (%messages payload)))

(defun %content-text (payload)
  "The human-readable text the verb rendered for the caller."
  (gethash "text" (aref (gethash "content" payload) 0)))

(defun %error-type (payload)
  (and (gethash "isError" payload) (gethash "error_type" payload)))

(defmacro with-bus-session ((session-var) &body body)
  "The common shape of every test here: an isolated bus, a rooted session, and
   the session's receiving participant already connected — so it is positioned
   at the head before any traffic is published."
  `(with-isolated-bus ()
     (with-rooted-session (,session-var)
       ;; Connect first: a participant that has never read starts at the current
       ;; head, so anything published before this call is not addressed to it.
       (session-agent ,session-var)
       ,@body)))

(defmacro with-publisher ((var session) &body body)
  "Bind VAR to a separate publishing participant in SESSION's namespace,
   disconnecting it on exit. Separate because the receive path filters an
   agent's own messages out of what it returns."
  `(let ((,var (agent:connect-agent
                (namestring (dsmr-mcp/src/state:session-project-root ,session))
                :name "backlog-publisher")))
     (unwind-protect (progn ,@body)
       (ignore-errors (agent:disconnect-agent ,var)))))

(defmacro with-named-publisher ((var namespace name) &body body)
  "Bind VAR to a publishing participant called NAME under NAMESPACE, and
   disconnect it on exit. NAMESPACE is given explicitly so a test can publish
   from a project other than the reader's own."
  `(let ((,var (agent:connect-agent ,namespace :name ,name)))
     (unwind-protect (progn ,@body)
       (ignore-errors (agent:disconnect-agent ,var)))))

(defmacro with-publisher-on-bus ((var namespace name bus) &body body)
  "Bind VAR to a publishing participant called NAME under NAMESPACE and
   connected on the named BUS, and disconnect it on exit. The bus is explicit
   because the point of these cases is that a message put on one bus is not
   readable from another."
  `(let ((,var (agent:connect-agent ,namespace :name ,name :bus ,bus)))
     (unwind-protect (progn ,@body)
       (ignore-errors (agent:disconnect-agent ,var)))))

(defun %publish-backlog (publisher n)
  "Publish N numbered messages and return them as a list in publication order."
  (loop for i from 1 to n
        for text = (format nil "m~D" i)
        do (agent:agent-publish publisher text)
        collect text))

(defun %own-namespace (session)
  "The bus namespace the session's own participant lives under."
  (namestring (dsmr-mcp/src/state:session-project-root session)))

(defun %publish-raw (body)
  "Submit BODY to the broker's intake exactly as given, with no envelope wrapped
   around it, and return once the broker has made it durable. This is what a
   message from an older publisher looks like on the wire, and submitting
   straight to the intake is the only way to produce one now that publishing
   always wraps.

   The socket is held open until the record appears in the log: a PUSH closed the
   instant after a send can discard a message that has not yet reached the
   intake, and a test waiting on a record nobody ever wrote fails for a reason
   that has nothing to do with what it is testing."
  (let* ((paths (broker:make-bus-paths))
         (submitter (zmq:make-submitter (broker:bus-paths-submit-endpoint paths))))
    (unwind-protect
         (progn
           (zmq:send-message submitter body)
           (loop repeat 100
                 until (find body (wal:read-records (broker:bus-paths-wal paths))
                             :key #'wal:record-body-string :test #'string=)
                 do (sleep 0.05)))
      (zmq:close-endpoint submitter))))

;;; ---------------------------------------------------------------------------
;;; Bounded delivery
;;; ---------------------------------------------------------------------------

(define-test default-limit-bounds-a-large-backlog
  "A backlog larger than the default batch comes back one page at a time, and
the reply says how much is still waiting. Without the remaining count a caller
cannot tell a page from the whole queue."
  (with-bus-session (session)
    (with-publisher (pub session)
      (%publish-backlog pub 50))
    (let ((payload (%call session)))
      (is = +default-batch-size+ (%field payload "count")
          "a default receive delivers exactly one batch")
      (is = 30 (%field payload "remaining_pending")
          "and reports the 30 records it did not deliver")
      (is string= "m1" (first (%texts payload))
          "delivery is oldest-first")
      (is string= "m20" (car (last (%texts payload)))
          "and stops at the batch boundary"))))

(define-test explicit-limit-overrides-the-default
  "An explicit limit is honoured in place of the default batch size."
  (with-bus-session (session)
    (with-publisher (pub session)
      (%publish-backlog pub 50))
    (let ((payload (%call session "limit" 5)))
      (is = 5 (%field payload "count") "exactly the requested page size")
      (is = 45 (%field payload "remaining_pending") "the rest is still pending")
      (is equal '("m1" "m2" "m3" "m4" "m5") (%texts payload)))))

(define-test successive-calls-walk-the-backlog-without-gap-or-repeat
  "Three default-limit calls over a 50-record backlog concatenate to the whole
backlog exactly once each, in order. Pagination that dropped or repeated a
record would be worse than the unbounded delivery it replaced."
  (with-bus-session (session)
    (with-publisher (pub session)
      (let ((published (%publish-backlog pub 50))
            (seen '()))
        (dotimes (_ 3)
          (setf seen (append seen (%texts (%call session)))))
        (is equal published seen
            "every record delivered once, in publication order")
        (is = 0 (%field (%call session) "remaining_pending")
            "and nothing is left pending afterwards")))))

;;; ---------------------------------------------------------------------------
;;; The limit guard
;;; ---------------------------------------------------------------------------

(define-test non-positive-and-non-integer-limits-are-refused
  "A zero, negative or non-integer limit is refused at the tool boundary and the
cursor does not move. Left to the core a zero would degrade to the default batch
and a string would error deep inside the log reader — both worse than telling
the caller what was wrong with the value it sent."
  (with-bus-session (session)
    (with-publisher (pub session)
      (%publish-backlog pub 25))
    (dolist (bad '(0 -1 "five"))
      (let ((payload (%call session "limit" bad)))
        (is string= "invalid-argument" (%error-type payload)
            (format nil "limit ~S is refused" bad))
        (false (gethash "messages" payload)
               (format nil "limit ~S delivers nothing" bad))))
    ;; The cursor is where it was: the next valid call still starts at m1.
    (let ((payload (%call session)))
      (is string= "m1" (first (%texts payload))
          "a refused call left the cursor unmoved"))))

(define-test timeout-validation-is-unchanged
  "The pre-existing timeout_ms guard still refuses a negative value in the same
shape the new limit guard mirrors."
  (with-bus-session (session)
    (is string= "invalid-argument" (%error-type (%call session "timeout_ms" -1)))
    (is string= "invalid-argument"
        (%error-type (%call session "timeout_ms" "soon")))))

;;; ---------------------------------------------------------------------------
;;; Explicit abandonment
;;; ---------------------------------------------------------------------------

(define-test skip-to-head-abandons-the-backlog-and-says-how-much
  "skip_to_head gives up the whole backlog and reports the count. The count is
the point: a silent discard is the amnesia that made restarting look like a
cure."
  (with-bus-session (session)
    (with-publisher (pub session)
      (%publish-backlog pub 25))
    (let ((payload (%call session "skip_to_head" t)))
      (is = 25 (%field payload "abandoned") "reports what it gave up")
      (is = 0 (%field payload "count") "and delivers nothing in the same call"))
    (let ((payload (%call session)))
      (is = 0 (%field payload "count") "the backlog is gone")
      (is = 0 (%field payload "remaining_pending") "and nothing is pending"))))

(define-test skip-to-head-on-a-current-cursor-abandons-nothing
  "With nothing pending there is nothing to give up, and the count says so
rather than reporting a discard that did not happen."
  (with-bus-session (session)
    (let ((payload (%call session "skip_to_head" t)))
      (is = 0 (%field payload "abandoned")))))

(define-test same-namespace-author-is-the-bare-name
  "A message from an agent in the reader's own project is credited to it by bare
name, both in a field of its own and in the rendered text. The bare name is what
agents in one project already call each other; the encoded id would be a wall of
percent escapes nobody reads."
  (with-bus-session (session)
    (with-named-publisher (pub (%own-namespace session) "sister")
      (agent:agent-publish pub "the log read is bounded now"))
    (let ((payload (%call session)))
      (is = 1 (%field payload "count"))
      (is equal '("sister") (%authors payload)
          "the author is carried as its own field")
      (is equal '("the log read is bounded now") (%texts payload)
          "and the body is untouched")
      (true (search "author: sister" (%content-text payload))
            "the rendered text names the author too"))))

(define-test foreign-namespace-author-is-qualified-by-its-project
  "A message from another project is credited to name@namespace, not to the bare
name. Two projects can both run an agent called valis, and a bare name would put
back the ambiguity the author field exists to remove."
  (with-bus-session (session)
    (with-named-publisher (pub "/tmp/some-other-project/" "valis")
      (agent:agent-publish pub "status?"))
    (let ((author (first (%authors (%call session)))))
      (is string= "valis@/tmp/some-other-project" author
          "a foreign sender is qualified by the project it publishes from")
      (false (string= "valis" author)
             "and is never shown as a bare name that could collide"))))

(define-test unresolvable-author-reads-as-unknown-and-the-message-still-arrives
  "A record with no envelope at all and one whose id will not decode are both
credited to \"unknown\" and are both still delivered. Refusing to deliver a
message because its author cannot be established would lose real traffic through
a staggered rollout; guessing at the author would be worse."
  (with-bus-session (session)
    (%publish-raw "a message from an older publisher")
    (%publish-raw "c1|%ZZ|a message with a mangled id")
    (let ((texts '())
          (authors '()))
      ;; Both records are durable by the time %publish-raw returns, but a bounded
      ;; delivery need not hand back both in one call, so drain until it has.
      (loop repeat 10
            while (< (length texts) 2)
            do (let ((payload (%call session "timeout_ms" 1000)))
                 (setf texts (append texts (%texts payload)))
                 (setf authors (append authors (%authors payload)))))
      (is equal '("a message from an older publisher"
                  "a message with a mangled id")
          texts
          "both records are delivered, bodies intact")
      (is equal '("unknown" "unknown") authors
          "and each is honestly reported as having no establishable author"))))

(define-test a-body-opening-with-a-name-does-not-become-the-author
  "A body that opens with the name of the agent being ADDRESSED is still credited
to the agent that actually sent it. This is the regression the author field
exists to prevent: the convention of leading a message with the recipient's name
reads as a byline, and agents have credited messages to the wrong sender on the
strength of it, warnings notwithstanding."
  (with-bus-session (session)
    (with-named-publisher (pub (%own-namespace session) "sister")
      (agent:agent-publish pub "valis: check the bounded log read"))
    (let ((payload (%call session)))
      (is equal '("sister") (%authors payload)
          "the author is the sender, not the name the body opens with")
      (is equal '("valis: check the bounded log read") (%texts payload)
          "and the body is delivered verbatim")
      (let ((content (%content-text payload)))
        (true (search "author: sister" content)
              "the rendered text credits the sender")
        (false (search "author: valis" content)
               "and never credits the addressee")))))

(define-test omitting-the-bus-reports-the-session-bus
  "A call that names no bus behaves as it always has and reports the bus it
actually read, which for a session with no selector set is the unnamed one,
labelled \"default\". The label is what lets an agent joined to two buses tell
its own traffic apart; a reply that simply omitted the field could not be told
from an older reply that never carried it. Both reply shapes carry it, the
receive and the deliberate abandonment."
  (with-bus-session (session)
    (with-publisher (pub session)
      (%publish-backlog pub 3))
    (let ((payload (%call session "limit" 1)))
      (is string= "default" (%field payload "bus")
          "a receive names the bus it read")
      (is equal '("m1") (%texts payload)
          "and delivers exactly what it always did"))
    (let ((payload (%call session "skip_to_head" t)))
      (is string= "default" (%field payload "bus")
          "an abandonment names it too")
      (is = 2 (%field payload "abandoned")
          "and still reports what it gave up"))))

(define-test a-named-bus-and-the-session-bus-stay-apart
  "Naming a bus reads that bus. One session receives on its own bus and on a
named one in turn, and each call comes back with only the traffic put on the bus
it named. Without this the bus argument would be decorative: an agent leading one
fleet and reporting to another would read one queue and believe it was the
other's."
  (with-isolated-bus ("alpha")
    (with-rooted-session (session)
      ;; Both participants connect before any traffic: a participant that has
      ;; never read starts at the head of its own bus, so anything published
      ;; first is not addressed to it.
      (session-agent session)
      (session-agent session nil :bus "alpha")
      (with-publisher (pub session)
        (agent:agent-publish pub "on the session bus"))
      (with-publisher-on-bus (apub (%own-namespace session) "alpha-sister" "alpha")
        (agent:agent-publish apub "on alpha"))
      (let ((here (%call session)))
        (is string= "default" (%field here "bus"))
        (is equal '("on the session bus") (%texts here)
            "the session's own bus delivers only its own traffic"))
      (let ((there (%call session "bus" "alpha")))
        (is string= "alpha" (%field there "bus")
            "the reply names the bus that was asked for")
        (is equal '("on alpha") (%texts there)
            "and delivers only what was published there")))))

(define-test a-bus-that-is-not-a-non-empty-string-is-refused
  "A bus argument that is not a usable string is refused at the boundary. An
empty string is refused with the rest rather than read as \"no bus named\":
resolved, it would fall through to whatever bus the session already speaks on,
and a caller that asked for one fleet's traffic would be handed another's while
the reply reported success."
  (with-bus-session (session)
    (with-publisher (pub session)
      (%publish-backlog pub 3))
    (dolist (bad (list 7 t ""))
      (let ((payload (%call session "bus" bad)))
        (is string= "invalid-argument" (%error-type payload)
            (format nil "bus ~S is refused" bad))
        (false (gethash "messages" payload)
               (format nil "bus ~S delivers nothing" bad))
        (false (gethash "bus" payload)
               (format nil "and bus ~S reports no bus, having read none" bad))))
    (let ((payload (%call session)))
      (is string= "m1" (first (%texts payload))
          "a refused call left the session's cursor unmoved"))))

(define-test an-unusable-bus-name-is-refused-rather-than-defaulted
  "A name that cannot become a bus root comes back as invalid-argument carrying
the reason, and the call reads nothing. The failure being closed here is the
quiet one: a bad name downgraded to the session's own bus would hand back a
result that looked like success while the caller sat on the wrong bus. The
reserved name \"default\" is in the set because the watcher already prints
bus=default for the unnamed one, so a bus actually called that would be
unreadable in its output."
  (with-bus-session (session)
    (with-publisher (pub session)
      (agent:agent-publish pub "on the session bus"))
    (dolist (bad '("has/slash" "spaces here" "default"))
      (let ((payload (%call session "bus" bad)))
        (is string= "invalid-argument" (%error-type payload)
            (format nil "bus ~S is refused" bad))
        (true (search "bus-receive" (%content-text payload))
              (format nil "the refusal for ~S names the tool" bad))
        (false (gethash "messages" payload)
               (format nil "and bus ~S read nothing from any bus" bad))))
    (let ((payload (%call session)))
      (is equal '("on the session bus") (%texts payload)
          "the session's own traffic was never consumed by a refused call"))))
