;;;; tests/tools/bus-roster-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; The two operator-facing roster verbs at the tool boundary: bus-roster, which
;;;; a leader drives to assemble and maintain a fleet, and bus-leave, which an
;;;; agent drives to depart one cleanly.
;;;;
;;;; The roster core owns the durable state and the departure path owns the
;;;; drain, so these tests assert on what a caller of the verbs can observe: what
;;;; came back in the reply, what the next call sees, and, for the case that
;;;; matters most, what the bus still carries for an agent the roster refused.
;;;;
;;;; That last one is the point of the file. The roster is advisory: closing
;;;; enrollment stops a leader listing new participants and stops nothing else,
;;;; because isolation between fleets is the separate state root and its
;;;; filesystem permissions, and the transport has no security surface that could
;;;; back a membership check. A refused agent connecting, publishing and
;;;; receiving is therefore correct behaviour, and a test that did not pin it
;;;; down would let somebody quietly turn the gate into an access control list.
;;;;
;;;; Each test isolates XDG_STATE_HOME to a temp directory and runs an in-process
;;;; broker there, so nothing here touches the developer's host-wide bus.

;; Package evolution guard: drop a prior incarnation so a reload picks up the
;; current import/export set rather than stale symbols.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/tools/bus-roster-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/tools/bus-roster-test
  (:use #:cl #:parachute)
  (:local-nicknames (#:broker #:dsmr-mcp/src/bus/broker)
                    (#:agent #:dsmr-mcp/src/bus/agent)
                    (#:selector #:dsmr-mcp/src/bus/selector))
  (:import-from #:dsmr-mcp/src/tools/base
                #:tool-handle)
  (:import-from #:dsmr-mcp/src/tools/bus-helpers
                #:session-agent
                #:disconnect-session-bus)
  (:import-from #:dsmr-mcp/src/tools/bus-roster
                #:bus-roster-tool)
  (:import-from #:dsmr-mcp/src/tools/bus-leave
                #:bus-leave-tool)
  (:import-from #:dsmr-mcp/src/state
                #:make-session
                #:session-project-root)
  (:import-from #:dsmr-mcp/tests/support/env-fixture
                #:with-clean-resolution-env))

(in-package #:dsmr-mcp/tests/tools/bus-roster-test)

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
    (let* ((rand-part (format nil "dsmr-bus-roster-~8,'0X"
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
                  :name "bus-roster-test-broker")))
    (lambda ()
      (setf stop t)
      (ignore-errors (sb-thread:join-thread thread))
      (ignore-errors (broker:stop-broker br)))))

(defmacro with-isolated-bus ((&rest bus-names) &body body)
  "Run BODY with XDG_STATE_HOME pointed at a fresh temp directory and an
   in-process broker serving the unnamed bus derived from it. Each name in
   BUS-NAMES additionally gets its own served bus under that same temp root, so
   one test can act on two buses at once."
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
   DSMR_BUS_AGENT and the other resolution vars neutralized, and disconnect every
   participant the session opened on the way out."
  (let ((root (gensym "ROOT")))
    `(with-clean-resolution-env
       (let* ((,root (%make-temp-directory))
              (,session-var (make-session :id "bus-roster" :project-root ,root)))
         (unwind-protect (progn ,@body)
           (ignore-errors (disconnect-session-bus ,session-var))
           (ignore-errors (uiop:delete-directory-tree
                           ,root :validate t :if-does-not-exist :ignore)))))))

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

(defun %roster (session &rest kvs)
  (%invoke 'bus-roster-tool session kvs))

(defun %leave (session &rest kvs)
  (%invoke 'bus-leave-tool session kvs))

(defun %field (payload key)
  (gethash key payload))

(defun %content-text (payload)
  (gethash "text" (aref (gethash "content" payload) 0)))

(defun %error-type (payload)
  (and (gethash "isError" payload) (gethash "error_type" payload)))

(defun %members (payload)
  (coerce (gethash "members" payload) 'list))

(defun %member-named (payload id)
  "The listed entry whose agent_id is ID, or NIL. Entries come back in whatever
   order the roster directory lists, so nothing here indexes by position."
  (find id (%members payload) :key (lambda (m) (gethash "agent_id" m))
                              :test #'equal))

(defun %own-namespace (session)
  "The bus namespace this session's participants live under."
  (namestring (session-project-root session)))

(defun %qualified (session name)
  "The full bus id a bare NAME resolves to under SESSION's namespace, built the
   way the bus builds it: the project root with its trailing separator serving as
   the single separator at the join."
  (concatenate 'string (%own-namespace session) name))

(defun %doubled (session name)
  "The full bus id for NAME with two separators at the join.

   A leader listing a sister that lives in another repository cannot pass a bare
   name, because a bare name is qualified with the calling session's own project
   and would reach the wrong one. So it types the full id, and typing a project
   root that already ends in a separator produces this. Nothing builds it any
   more, and the state written before the join was normalized is full of it."
  (concatenate 'string (%own-namespace session) "/" name))

(defmacro with-participant ((var namespace &rest connect-args) &body body)
  "Bind VAR to a participant connected under NAMESPACE and disconnect it on the
   way out."
  `(let ((,var (agent:connect-agent ,namespace ,@connect-args)))
     (unwind-protect (progn ,@body)
       (ignore-errors (agent:disconnect-agent ,var)))))

;;; ---------------------------------------------------------------------------
;;; Listing
;;; ---------------------------------------------------------------------------

(define-test an-empty-roster-lists-as-open-with-no-leader
  "A bus nobody has decided anything about lists as open, leaderless and empty.
The state file is not written until something is decided, so this is also the
guard that an absent file reads as a usable answer rather than as a failure."
  (with-isolated-bus ()
    (with-rooted-session (session)
      (let ((payload (%roster session "action" "list")))
        (is = 0 (%field payload "count"))
        (is eq t (%field payload "enrollment_open"))
        (is eq 'null (%field payload "leader")
            "no leader reads as JSON null, not as an empty name")
        (is string= "default" (%field payload "bus")
            "the unnamed host bus is labelled the way the watcher labels it")))))

(define-test a-listing-carries-status-times-and-role-for-every-entry
  "Every entry comes back with who it names, whether it is enrolled or departed,
when it was enrolled, when it left if it has, and the role recorded for it. A
listing that showed only names would leave the leader unable to tell a departure
from a deletion."
  (with-isolated-bus ()
    (with-rooted-session (session)
      (%roster session "action" "enroll" "agent" "sister")
      (%roster session "action" "enroll" "agent" "cousin")
      (%roster session "action" "disenroll" "agent" "cousin")
      (let* ((payload (%roster session "action" "list"))
             (here (%member-named payload (%qualified session "sister")))
             (gone (%member-named payload (%qualified session "cousin"))))
        (is = 2 (%field payload "count"))
        (true here "the enrolled agent is listed")
        (is string= "enrolled" (gethash "status" here))
        (is string= "member" (gethash "role" here))
        (true (integerp (gethash "enrolled_at" here))
              "an enrolled entry carries when it was enrolled")
        (is eq 'null (gethash "departed_at" here)
            "and carries no departure time while it is still here")
        (true gone "the departed agent is still listed")
        (is string= "departed" (gethash "status" gone))
        (true (integerp (gethash "departed_at" gone))
              "a departed entry is stamped with when it left")
        (true (search "departed" (%content-text payload))
              "and the rendered listing says so")))))

;;; ---------------------------------------------------------------------------
;;; Enrolling and disenrolling
;;; ---------------------------------------------------------------------------

(define-test enrolling-a-bare-name-qualifies-it-with-this-project
  "A bare name is qualified with the session's own namespace, so an operator
names a sister by the name it answers to and never types a project root. It also
means a bare name can never reach into another project's namespace: two projects
may both run an agent called valis."
  (with-isolated-bus ()
    (with-rooted-session (session)
      (let ((payload (%roster session "action" "enroll" "agent" "valis")))
        (is eq t (%field payload "enrolled"))
        (is string= (%qualified session "valis") (%field payload "agent_id"))))))

(define-test enrolling-a-full-id-uses-it-as-given
  "An argument that already carries a namespace separator is taken as a full bus
id, so a leader can list an agent from a repo other than the one it is sitting
in. A doubled separator at the join names that same agent, and the entry is
written under the single-separator spelling: that is what every id the bus builds
carries, and what the busmaster derives the agent's held cursor filename from."
  (with-isolated-bus ()
    (with-rooted-session (session)
      (let ((payload (%roster session "action" "enroll"
                                      "agent" "/tmp/other-project/fulcrum")))
        (is string= "/tmp/other-project/fulcrum" (%field payload "agent_id"))
        (true (%member-named (%roster session "action" "list")
                             "/tmp/other-project/fulcrum")
              "and it is listed under that id"))
      (%roster session "action" "enroll" "agent" "/tmp/other-project//mercer")
      (true (%member-named (%roster session "action" "list")
                           "/tmp/other-project/mercer")
            "a doubled separator is listed under the single-separator spelling"))))

(define-test disenrolling-marks-departed-and-stamps-the-time
  "Disenroll records that the agent left and when. The stamp is what the
busmaster ages the held cursor against, so a departure with no time on it would
leave that cursor with nothing to be judged by."
  (with-isolated-bus ()
    (with-rooted-session (session)
      (%roster session "action" "enroll" "agent" "sister")
      (let ((payload (%roster session "action" "disenroll" "agent" "sister")))
        (true (integerp (%field payload "departed_at")))
        (is string= "departed" (gethash "status" (%field payload "member")))
        (is string= (%qualified session "sister") (%field payload "agent_id"))))))

(define-test disenrolling-an-agent-that-was-never-enrolled-still-records-it
  "An id with no entry gets a departed one rather than a refusal. A departure
with no record would leave that agent's cursor with nothing to age against, and
an unlisted agent is exactly the one nobody is watching."
  (with-isolated-bus ()
    (with-rooted-session (session)
      (let ((payload (%roster session "action" "disenroll" "agent" "stranger")))
        (true (integerp (%field payload "departed_at")))
        (is string= "departed" (gethash "status" (%field payload "member")))))))

(define-test an-agent-listed-by-hand-departs-when-it-leaves-under-its-own-id
  "The case measured live, driven through the verbs. A leader lists a sister by
   typing its full id, which carries one separator at the join. That sister later
   leaves, and leaving can only ever depart the identity its own session
   resolves, which carries two.

   One agent, one line on the roster, and it is departed. Treated as two, the
   typed line would be stranded as enrolled with nothing able to reach it, and
   the listing would show one sister in both states at once."
  (with-isolated-bus ()
    (with-rooted-session (session)
      (%roster session "action" "enroll" "agent" (%doubled session "sister"))
      (let ((payload (%leave session "agent_id" "sister")))
        (is eq t (%field payload "left")))
      (let ((listing (%roster session "action" "list")))
        (is = 1 (%field listing "count")
            "the typed listing and the agent's own departure are one entry")
        (let ((entry (%member-named listing (%qualified session "sister"))))
          (true entry "listed under the id the agent resolves for itself")
          (is string= "departed" (gethash "status" entry))
          (true (integerp (gethash "departed_at" entry))))))))

(define-test disenrolling-by-hand-departs-the-entry-the-agent-was-listed-under
  "The same collision the other way about: the sister was listed under the id its
   session resolves, and an operator departs it by typing one separator. Still
   one entry, and it is the one that was there."
  (with-isolated-bus ()
    (with-rooted-session (session)
      (%roster session "action" "enroll" "agent" "sister")
      (let ((payload (%roster session "action" "disenroll"
                              "agent" (%doubled session "sister"))))
        (true (integerp (%field payload "departed_at")))
        (is string= "departed" (gethash "status" (%field payload "member"))))
      (let ((listing (%roster session "action" "list")))
        (is = 1 (%field listing "count") "no second entry was written")
        (is string= "departed"
            (gethash "status"
                     (%member-named listing (%qualified session "sister")))
            "and the entry that was listed is the one that departed")))))

;;; ---------------------------------------------------------------------------
;;; The gate
;;; ---------------------------------------------------------------------------

(define-test closing-and-reopening-the-gate-reports-the-new-state
  "Closing and reopening flip the gate and report what it now is, read back from
the roster rather than assumed from the request."
  (with-isolated-bus ()
    (with-rooted-session (session)
      (let ((closed (%roster session "action" "close-enrollment")))
        (is eq nil (%field closed "enrollment_open"))
        (true (search "closed" (%content-text closed))))
      (is eq nil (%field (%roster session "action" "list") "enrollment_open")
          "and a later listing agrees")
      (let ((opened (%roster session "action" "open-enrollment")))
        (is eq t (%field opened "enrollment_open")))
      (is eq t (%field (%roster session "action" "list") "enrollment_open")))))

(define-test a-closed-gate-refuses-an-enroll-and-says-why
  "An enroll against a closed gate is refused with a named reason and writes
nothing. A silent no-op would leave a leader believing it had assembled a fleet
it had not."
  (with-isolated-bus ()
    (with-rooted-session (session)
      (%roster session "action" "close-enrollment")
      (let ((payload (%roster session "action" "enroll" "agent" "latecomer")))
        (is eq nil (%field payload "enrolled"))
        (is string= "enrollment-closed" (%field payload "reason"))
        (true (search "enrollment is closed" (%content-text payload))
              "and the text states the reason"))
      (is = 0 (%field (%roster session "action" "list") "count")
          "nothing was written"))))

(define-test an-agent-refused-by-the-gate-still-uses-the-bus
  "The whole point of an advisory roster, and the case that stops the gate being
turned into an access control list by degrees. With enrollment closed and an
enroll refused, that same agent connects, publishes and receives on the very
same bus. Isolation is the separate state root and its filesystem permissions;
the transport has no security surface that could back a membership check, so a
refusal is a roster answer and never a transport one."
  (with-isolated-bus ()
    (with-rooted-session (session)
      (%roster session "action" "close-enrollment")
      (is eq nil (%field (%roster session "action" "enroll" "agent" "outsider")
                         "enrolled")
          "the roster refuses it")
      (let ((ns (%own-namespace session)))
        (with-participant (reader ns :name "insider")
          (with-participant (outsider ns :name "outsider")
            (agent:agent-publish outsider "refused, and still talking")
            (is equal '("refused, and still talking")
                (agent:agent-receive reader :timeout-ms 5000)
                "a refused agent publishes and the bus carries it")
            (agent:agent-publish reader "heard you")
            (is equal '("heard you")
                (agent:agent-receive outsider :timeout-ms 5000)
                "and a refused agent receives")))))))

;;; ---------------------------------------------------------------------------
;;; Leadership
;;; ---------------------------------------------------------------------------

(define-test declaring-a-leader-records-it-and-changes-no-entry
  "Declaring a leader writes down who leads and touches nothing else. It is a
record, not a grant: leadership belongs to whoever assembled the bus, and the
declared leader gains no ability an ordinary member lacks."
  (with-isolated-bus ()
    (with-rooted-session (session)
      (%roster session "action" "enroll" "agent" "valis")
      (let ((payload (%roster session "action" "declare-leader" "agent" "valis")))
        (is string= (%qualified session "valis") (%field payload "leader")))
      (let* ((listing (%roster session "action" "list"))
             (entry (%member-named listing (%qualified session "valis"))))
        (is string= (%qualified session "valis") (%field listing "leader")
            "a later listing reads the leader back")
        (is = 1 (%field listing "count") "and no entry was added or removed")
        (is string= "enrolled" (gethash "status" entry)
            "the declared leader's status is untouched")))))

(define-test a-leader-declared-by-hand-and-again-by-name-is-one-leader
  "Declaring the same agent by typed id and by bare name records one leader,
   spelled the way its entry is spelled. Two spellings would leave a listing
   naming a leader that matches none of the entries printed under it."
  (with-isolated-bus ()
    (with-rooted-session (session)
      (%roster session "action" "enroll" "agent" "valis")
      (%roster session "action" "declare-leader"
               "agent" (%doubled session "valis"))
      (%roster session "action" "declare-leader" "agent" "valis")
      (let ((listing (%roster session "action" "list")))
        (is string= (%qualified session "valis") (%field listing "leader"))
        (is = 1 (%field listing "count") "and no entry was added")
        (true (%member-named listing (%field listing "leader"))
              "the declared leader matches a listed entry")))))

(define-test two-buses-keep-separate-leaders-and-separate-gates
  "Each bus carries its own roster, its own gate and its own leader, which is the
whole of the answer to two fleets sharing a machine. Nothing cryptographic is
involved and nothing needs to be: each fleet names its own bus."
  (with-isolated-bus ("alpha")
    (with-rooted-session (session)
      (%roster session "action" "declare-leader" "agent" "valis")
      (%roster session "action" "declare-leader" "agent" "fulcrum" "bus" "alpha")
      (%roster session "action" "close-enrollment" "bus" "alpha")
      (let ((here (%roster session "action" "list"))
            (there (%roster session "action" "list" "bus" "alpha")))
        (is string= (%qualified session "valis") (%field here "leader"))
        (is string= (%qualified session "fulcrum") (%field there "leader")
            "the named bus keeps its own leader")
        (is eq t (%field here "enrollment_open")
            "and closing one gate leaves the other open")
        (is eq nil (%field there "enrollment_open"))
        (is string= "default" (%field here "bus"))
        (is string= "alpha" (%field there "bus"))))))

(define-test an-action-on-a-named-bus-does-not-reach-the-default-one
  "An enroll carrying a bus argument lands on that bus's roster and on no other.
A roster that leaked across buses would put one fleet's membership in another
fleet's listing."
  (with-isolated-bus ("alpha")
    (with-rooted-session (session)
      (%roster session "action" "enroll" "agent" "sister" "bus" "alpha")
      (is = 1 (%field (%roster session "action" "list" "bus" "alpha") "count"))
      (is = 0 (%field (%roster session "action" "list") "count")
          "the session's default bus knows nothing about it"))))

;;; ---------------------------------------------------------------------------
;;; Refusals
;;; ---------------------------------------------------------------------------

(define-test an-unknown-action-is-refused-and-names-the-accepted-set
  "An action outside the closed set is refused before anything reaches the
roster, and the refusal lists what would have worked. Validating after the fact
would leave durable state changed by a call the caller was told was invalid."
  (with-isolated-bus ()
    (with-rooted-session (session)
      (dolist (bad '("delete" "" 7))
        (let ((payload (%roster session "action" bad)))
          (is string= "invalid-argument" (%error-type payload)
              (format nil "action ~S is refused" bad))
          (true (search "declare-leader" (%content-text payload))
                "and the refusal names the accepted actions"))))))

(define-test the-actions-that-need-an-agent-refuse-without-one
  "Enroll, disenroll and declare-leader each act on one named agent, so each
refuses when none was given rather than inventing a target."
  (with-isolated-bus ()
    (with-rooted-session (session)
      (dolist (action '("enroll" "disenroll" "declare-leader"))
        (is string= "invalid-argument"
            (%error-type (%roster session "action" action))
            (format nil "~A without an agent is refused" action))
        (is string= "invalid-argument"
            (%error-type (%roster session "action" action "agent" ""))
            (format nil "~A with an empty agent is refused" action))))))

(define-test an-unusable-bus-name-is-refused-as-an-argument
  "A bus name that cannot become a directory segment is refused as a bad
argument. Falling back to the default bus would act on the shared roster while
the reply reported success on the named one."
  (with-isolated-bus ()
    (with-rooted-session (session)
      (is string= "invalid-argument"
          (%error-type (%roster session "action" "list" "bus" "not a bus name"))))))

(define-test a-bus-that-is-not-a-non-empty-string-is-refused-by-the-roster-verb
  "A bus argument that is not a usable string is refused at the boundary, the
empty string with the rest. Read as \"no bus named\" it would fall through to the
session's own bus, so an enroll meant for one fleet would land on another's
roster while the reply reported success. Every action is checked, because a
refusal that held for listing and not for enrolling would be the dangerous half
missing."
  (with-isolated-bus ()
    (with-rooted-session (session)
      (dolist (bad (list "" 7 t))
        (let ((payload (%roster session "action" "enroll" "agent" "sister"
                                "bus" bad)))
          (is string= "invalid-argument" (%error-type payload)
              (format nil "enroll with bus ~S is refused" bad))
          (true (search "bus-roster" (%content-text payload))
                (format nil "the refusal for ~S names the tool" bad)))
        (is string= "invalid-argument"
            (%error-type (%roster session "action" "list" "bus" bad))
            (format nil "list with bus ~S is refused" bad))
        (is string= "invalid-argument"
            (%error-type (%roster session "action" "declare-leader"
                                  "agent" "sister" "bus" bad))
            (format nil "declare-leader with bus ~S is refused" bad))
        (is string= "invalid-argument"
            (%error-type (%roster session "action" "close-enrollment"
                                  "bus" bad))
            (format nil "close-enrollment with bus ~S is refused" bad)))
      ;; Nothing durable was touched: no enrolment recorded, no leader named,
      ;; and the gate still open.
      (let ((listing (%roster session "action" "list")))
        (is = 0 (%field listing "count")
            "no refused enroll reached the session's own roster")
        (is eq 'null (%field listing "leader")
            "and no refused declare-leader named one")
        (is eq t (%field listing "enrollment_open")
            "and no refused close-enrollment shut the gate")))))

(define-test the-roster-verb-needs-a-project-root
  "With no project root there is no namespace to act under, and the verb says so
in the shape every bus verb uses rather than failing somewhere deeper."
  (with-isolated-bus ()
    (with-clean-resolution-env
      (let ((session (make-session :id "rootless")))
        (is string= "project-root-not-set"
            (%error-type (%roster session "action" "list")))))))

;;; ---------------------------------------------------------------------------
;;; Leaving
;;; ---------------------------------------------------------------------------

(define-test leaving-drains-records-the-departure-and-disconnects
  "Leaving reads out what was waiting, puts a dated departure on the roster, and
releases the connection. The drained count is what tells a departing agent
whether it left mail behind."
  (with-isolated-bus ()
    (with-rooted-session (session)
      ;; Connect first: a participant that has never read starts at the current
      ;; head, so anything published before this is not addressed to it.
      (session-agent session "sister")
      (with-participant (pub (%own-namespace session) :name "publisher")
        (agent:agent-publish pub "one")
        (agent:agent-publish pub "two"))
      (let ((payload (%leave session "agent_id" "sister")))
        (is eq t (%field payload "left"))
        (is = 2 (%field payload "drained") "it read out what was waiting")
        (true (integerp (%field payload "departed_at"))
              "and the departure is dated")
        (is string= "default" (%field payload "bus"))
        (is string= (%qualified session "sister") (%field payload "agent_id")))
      (let ((entry (%member-named (%roster session "action" "list")
                                  (%qualified session "sister"))))
        (true entry "the departure is on the roster")
        (is string= "departed" (gethash "status" entry))))))

(define-test the-session-forgets-a-departed-participant
  "A later bus call in the same session reconnects instead of reaching for a
handle whose client and subscriber were already released. A cached departed
participant fails in a way that looks nothing like its cause."
  (with-isolated-bus ()
    (with-rooted-session (session)
      (let ((before (session-agent session "sister")))
        (%leave session "agent_id" "sister")
        (let ((after (session-agent session "sister")))
          (false (eq before after) "the cached participant was dropped")
          (is string= (agent:agent-id before) (agent:agent-id after)
              "and the stable identity comes back as itself")
          (true (agent:agent-publish after "back on the bus")
                "the reconnected participant works"))))))

(define-test leaving-twice-drains-nothing-and-keeps-the-first-departure-time
  "The second leave is quiet and, crucially, does not restamp the departure. A
stamp pushed forward on every repeat would keep the held cursor alive past every
threshold, which is holding a cursor turning into keeping it forever."
  (with-isolated-bus ()
    (with-rooted-session (session)
      (session-agent session "sister")
      (let* ((first (%leave session "agent_id" "sister"))
             (second (%leave session "agent_id" "sister")))
        (is eq t (%field second "left") "leaving twice is not an error")
        (is = 0 (%field second "drained") "and there was nothing left to read")
        (is = (%field first "departed_at") (%field second "departed_at")
            "the original departure time stands")))))

(define-test leaving-departs-only-this-session-s-own-identity
  "One agent can never evict another. Leaving as one identity leaves every other
participant connected and delivering, and the reply names the identity that
actually left."
  (with-isolated-bus ()
    (with-rooted-session (session)
      (session-agent session "sister")
      (let ((cousin (session-agent session "cousin")))
        (let ((payload (%leave session "agent_id" "sister")))
          (is string= (%qualified session "sister") (%field payload "agent_id")
              "the reply names the departing identity")
          (false (string= (%qualified session "cousin")
                          (%field payload "agent_id"))))
        (with-participant (pub (%own-namespace session) :name "publisher")
          (agent:agent-publish pub "still delivering"))
        (is equal '("still delivering")
            (agent:agent-receive cousin :timeout-ms 5000)
            "the other participant is untouched")
        (false (%member-named (%roster session "action" "list")
                              (%qualified session "cousin"))
               "and nothing was recorded against it")))))

(define-test leaving-a-named-bus-leaves-only-that-one
  "A leave carrying a bus argument departs that bus and no other, so an agent can
stop reporting into a neighbouring fleet without leaving its own."
  (with-isolated-bus ("alpha")
    (with-rooted-session (session)
      (let ((here (session-agent session "sister")))
        (session-agent session "sister" :bus "alpha")
        (let ((payload (%leave session "agent_id" "sister" "bus" "alpha")))
          (is string= "alpha" (%field payload "bus"))
          (true (integerp (%field payload "departed_at"))))
        (true (%member-named (%roster session "action" "list" "bus" "alpha")
                             (%qualified session "sister"))
              "the named bus records the departure")
        (false (%member-named (%roster session "action" "list")
                              (%qualified session "sister"))
               "and the default bus records nothing")
        (is eq here (session-agent session "sister")
            "the participant on the default bus is still the cached one")
        (with-participant (pub (%own-namespace session) :name "publisher")
          (agent:agent-publish pub "still here"))
        (is equal '("still here")
            (agent:agent-receive here :timeout-ms 5000)
            "and it still receives")))))

(define-test the-leave-verb-needs-a-project-root
  "With no project root there is no identity to depart, and the verb says so in
the shape every bus verb uses."
  (with-isolated-bus ()
    (with-clean-resolution-env
      (let ((session (make-session :id "rootless")))
        (is string= "project-root-not-set" (%error-type (%leave session)))))))

(define-test an-unusable-bus-name-is-refused-by-the-leave-verb
  "A bus name that cannot become a directory segment is refused rather than
downgraded to the default bus, which would depart the wrong bus while reporting
success."
  (with-isolated-bus ()
    (with-rooted-session (session)
      (is string= "invalid-argument"
          (%error-type (%leave session "bus" "not a bus name"))))))

(define-test a-bus-that-is-not-a-non-empty-string-is-refused-by-the-leave-verb
  "The leave verb refuses the same set the other bus verbs do. An empty bus read
as \"no bus named\" would depart the session's own bus while the reply named it as
a success, which is the one departure the caller did not ask for."
  (with-isolated-bus ()
    (with-rooted-session (session)
      (let ((here (session-agent session "sister")))
        (dolist (bad (list "" 7 t))
          (let ((payload (%leave session "agent_id" "sister" "bus" bad)))
            (is string= "invalid-argument" (%error-type payload)
                (format nil "leaving with bus ~S is refused" bad))
            (false (%field payload "left")
                   (format nil "and bus ~S left nothing" bad))
            (true (search "bus-leave" (%content-text payload))
                  (format nil "the refusal for ~S names the tool" bad))))
        ;; No departure was stamped and the participant is untouched: still the
        ;; cached one, still connected, still delivering.
        (false (%member-named (%roster session "action" "list")
                              (%qualified session "sister"))
               "no refused leave stamped a departure on the roster")
        (is eq here (session-agent session "sister")
            "and the participant was never forgotten")
        (with-participant (pub (%own-namespace session) :name "publisher")
          (agent:agent-publish pub "still here"))
        (is equal '("still here")
            (agent:agent-receive here :timeout-ms 5000)
            "so it still receives")))))
