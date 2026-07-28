;;;; tests/integration/bus/segmentation-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Cross-process cover for named bus segmentation. Every claim here needs a
;;;; real broker PROCESS, which is why none of it can live in the fast suite:
;;;;
;;;;   - two named buses on one machine each elect their own broker, and neither
;;;;     one's traffic reaches the other's log, socket pair or reader;
;;;;   - the unnamed bus that nobody asked for stays empty while two named
;;;;     fleets run beside it, so an untagged agent is unaffected;
;;;;   - killing one bus's broker leaves the other serving, because election is
;;;;     per state root rather than per host;
;;;;   - a clean departure recorded on the roster hands the departing agent's
;;;;     cursor to that bus's busmaster, which then keeps it at the head of the
;;;;     log while leaving every still-connected participant's cursor alone.
;;;;
;;;; The custodial sweep that advances a held cursor runs inside the broker's
;;;; serve loop on an interval, so proving it needs a live broker and a wait
;;;; past that interval. An in-process fixture cannot reach it at all.
;;;;
;;;; XDG_STATE_HOME is redirected to a fresh temp directory for every test and
;;;; restored on the way out. Every bus root in this file derives from it, so no
;;;; broker spawned here can bind a socket the developer's live fleet is using.
;;;;
;;;; Gated: each spawn cold-loads the broker subsystem (and libzmq), so a test
;;;; SKIPs cleanly where that environment cannot be built and otherwise FAILs on
;;;; a genuine bring-up problem, which is the regression signal it exists for.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/integration/bus/segmentation-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/integration/bus/segmentation-test
  (:use #:cl #:parachute)
  (:local-nicknames (#:agent #:dsmr-mcp/src/bus/agent)
                    (#:broker #:dsmr-mcp/src/bus/broker)
                    (#:bus #:dsmr-mcp/src/bus/bus)
                    (#:cursor #:dsmr-mcp/src/bus/cursor)
                    (#:roster #:dsmr-mcp/src/bus/roster)
                    (#:selector #:dsmr-mcp/src/bus/selector)
                    (#:wal #:dsmr-mcp/src/bus/wal))
  (:import-from #:dsmr-mcp/tests/integration/support
                #:with-mcp-server-child-or-skip))

(in-package #:dsmr-mcp/tests/integration/bus/segmentation-test)

;;; ---------------------------------------------------------------- helpers

(defparameter *ready-timeout* 120
  "Seconds to allow a cold-spawned broker to come up and bind its sockets.")

(defparameter *advance-timeout* 180
  "Seconds to allow a serving broker to run the sweep that moves a departed
   agent's cursor up to the head. The sweep is due every thirty seconds and the
   loop it rides ticks on the intake timeout, so this is several times the
   interval rather than a guess at it: a false timeout here would report a
   working busmaster as broken.")

(defparameter *first-bus* "alpha-fleet"
  "The name of the first bus these tests assemble. Two ordinary names, so the
   derivation under test is the one an operator would actually exercise.")

(defparameter *second-bus* "beta-fleet"
  "The name of the second bus, unrelated to the first in every way that matters
   on disk.")

(defun wait-until (predicate &key (timeout 30) (poll 0.2))
  "Poll PREDICATE until it returns true or TIMEOUT seconds pass. Returns the
   truthy value, or NIL on timeout."
  (let ((deadline (+ (get-internal-real-time)
                     (* timeout internal-time-units-per-second))))
    (loop for v = (funcall predicate)
          when v return v
          when (> (get-internal-real-time) deadline) return nil
          do (sleep poll))))

(defun make-temp-directory ()
  "Create a uniquely named temp directory under /tmp and return its pathname.
   The suffix is drawn from a state seeded per call, because SBCL's default
   random state is identical in every fresh image: without the seeding two runs
   walk the same names, and a leftover tree from an earlier run turns an
   absence assertion into a flake."
  (loop
    (let* ((rand-part (format nil "dsmr-bus-seg-~8,'0X"
                              (random #xFFFFFFFF (make-random-state t))))
           (dir-pn (uiop:ensure-directory-pathname
                    (merge-pathnames rand-part #p"/tmp/"))))
      (unless (probe-file dir-pn)
        (ensure-directories-exist dir-pn)
        (return dir-pn)))))

(defmacro with-private-state-home ((&optional dir-var) &body body)
  "Run BODY with XDG_STATE_HOME pointed at a fresh temp directory, restoring the
   inherited value and deleting the tree on the way out.

   Everything downstream of the selector derives from this variable, so this is
   what keeps a spawned broker off the developer's live bus: the roots these
   tests resolve exist only inside the temp tree, and the sockets bound under
   them cannot collide with the ones a running fleet holds."
  (let ((dir (or dir-var (gensym "DIR")))
        (saved (gensym "SAVED")))
    `(let ((,dir (make-temp-directory))
           (,saved (uiop:getenv "XDG_STATE_HOME")))
       (declare (ignorable ,dir))
       (unwind-protect
            (progn (setf (uiop:getenv "XDG_STATE_HOME") (namestring ,dir))
                   ,@body)
         (setf (uiop:getenv "XDG_STATE_HOME") (or ,saved ""))
         (ignore-errors (uiop:delete-directory-tree
                         ,dir :validate t :if-does-not-exist :ignore))))))

(defun submit-socket-path (paths)
  (merge-pathnames "submit.ipc" (broker:bus-paths-root paths)))

(defun broker-ready-p (paths)
  "A broker is ready once it holds the election lock and has bound its intake.
   Read from the filesystem and the lock rather than the process table, because
   a process-table scan matches the monitoring shell as readily as the broker."
  (and (broker:broker-running-p paths)
       (probe-file (submit-socket-path paths))))

(defun spawn-ready-broker (paths &key (block t))
  "Spawn a detached broker and wait until it is serving. Returns the process."
  (let ((proc (broker:spawn-broker paths :block block)))
    (unless (wait-until (lambda () (broker-ready-p paths)) :timeout *ready-timeout*)
      (error "broker did not become ready within ~Ds" *ready-timeout*))
    proc))

(defmacro with-killable ((proc-var spawn-form) &body body)
  "Bind PROC-VAR to a spawned process for BODY; SIGKILL it on the way out unless
   the body already reaped it, so a failed run leaves no broker holding a lock."
  `(let ((,proc-var ,spawn-form))
     (declare (ignorable ,proc-var))
     (unwind-protect (progn ,@body)
       (ignore-errors (uiop:terminate-process ,proc-var :urgent t)))))

(defun bodies (records) (mapcar #'bus:delivered-body-string records))

(defun logged-bodies (paths)
  "Every record body on the bus at PATHS, straight off the log. An absent log
   reads as no records, which is the answer wanted for a bus nobody used."
  (mapcar #'wal:record-body-string
          (wal:read-records (broker:bus-paths-wal paths))))

(defun carries-p (bodies text)
  "True when TEXT appears in any of BODIES. The bodies come off the log with
   their envelope still on, so this looks inside rather than comparing whole."
  (and (some (lambda (body) (search text body)) bodies) t))

(defun cursor-at (paths id)
  "The sequence number recorded in ID's cursor file on the bus at PATHS, or 0
   when it holds nothing readable. Read from the file every call, so a poller
   sees what the busmaster wrote rather than a value it cached."
  (cursor:cursor-value
   (cursor:make-subscriber id
                           (broker:bus-paths-wal paths)
                           (broker:cursor-path-for paths id))))

;;; ----------------------------------------------------------------- tests

(define-test named-buses-derive-separate-state-roots
  "Two names resolve to two state roots that share no file and no socket. This
   is the whole of how one bus is isolated from another, so it is asserted on
   the derived paths rather than assumed from the naming."
  (with-private-state-home ()
    (let ((a (broker:make-bus-paths (selector:bus-root *first-bus*)))
          (b (broker:make-bus-paths (selector:bus-root *second-bus*))))
      (isnt equal (broker:bus-paths-root a) (broker:bus-paths-root b)
            "the two roots are different directories")
      (isnt equal (broker:bus-paths-wal a) (broker:bus-paths-wal b)
            "each bus writes its own log")
      (isnt equal (broker:bus-paths-lock a) (broker:bus-paths-lock b)
            "each bus elects on its own broker lock")
      (isnt equal (broker:bus-paths-members a) (broker:bus-paths-members b)
            "each bus counts its own membership")
      (isnt equal (broker:bus-paths-cursors-dir a) (broker:bus-paths-cursors-dir b)
            "each bus keeps its own cursors")
      (isnt equal (broker:bus-paths-roster-dir a) (broker:bus-paths-roster-dir b)
            "each bus keeps its own roster")
      (isnt equal (broker:bus-paths-submit-endpoint a)
            (broker:bus-paths-submit-endpoint b)
            "each bus takes submissions on its own socket")
      (isnt equal (broker:bus-paths-pub-endpoint a)
            (broker:bus-paths-pub-endpoint b)
            "each bus publishes on its own socket"))))

(define-test named-buses-do-not-share-traffic
  "Two named buses, each with a broker process of its own, deliver only their
   own traffic. Neither one's message reaches the other's log or reader, and the
   unnamed bus beside them stays empty."
  (with-mcp-server-child-or-skip
    (with-private-state-home ()
      (let ((a (broker:make-bus-paths (selector:bus-root *first-bus*)))
            (b (broker:make-bus-paths (selector:bus-root *second-bus*)))
            (default (broker:make-bus-paths (selector:bus-root))))
        (with-killable (proc-a (spawn-ready-broker a :block nil))
          (with-killable (proc-b (spawn-ready-broker b :block nil))
            (true (broker-ready-p a) "the first bus elected its own broker")
            (true (broker-ready-p b) "the second bus elected its own broker")
            (let ((client-a (bus:connect-client a))
                  (client-b (bus:connect-client b))
                  (sub-a (bus:subscribe a "reader-on-the-first-bus"))
                  (sub-b (bus:subscribe b "reader-on-the-second-bus")))
              (unwind-protect
                   (progn
                     (bus:publish client-a "alpha-only-traffic")
                     (bus:publish client-b "beta-only-traffic")
                     (is equal '("alpha-only-traffic")
                         (bodies (bus:await sub-a :timeout-ms 5000))
                         "the first bus delivers its own message")
                     (is equal '("beta-only-traffic")
                         (bodies (bus:await sub-b :timeout-ms 5000))
                         "the second bus delivers its own message")
                     (let ((logged-a (logged-bodies a))
                           (logged-b (logged-bodies b)))
                       (is = 1 (length logged-a)
                           "the first bus logged one record and no more")
                       (is = 1 (length logged-b)
                           "the second bus logged one record and no more")
                       (true (carries-p logged-a "alpha-only-traffic")
                             "the first bus logged its own message")
                       (false (carries-p logged-a "beta-only-traffic")
                              "the second bus's message never reached the first bus's log")
                       (true (carries-p logged-b "beta-only-traffic")
                             "the second bus logged its own message")
                       (false (carries-p logged-b "alpha-only-traffic")
                              "the first bus's message never reached the second bus's log"))
                     ;; Nothing asked for the unnamed bus, so nothing should have
                     ;; given it a log or a cursor. An untagged agent is
                     ;; unaffected by two named fleets running beside it.
                     (false (probe-file (broker:bus-paths-wal default))
                            "the unnamed bus gained no log")
                     (false (uiop:directory-exists-p
                             (broker:bus-paths-cursors-dir default))
                            "the unnamed bus gained no cursors")
                     (false (probe-file (submit-socket-path default))
                            "the unnamed bus gained no socket"))
                (bus:disconnect-client client-a)
                (bus:disconnect-client client-b)
                (bus:unsubscribe sub-a)
                (bus:unsubscribe sub-b)))))))))

(define-test killing-one-broker-leaves-the-other-serving
  "Election is per state root, so the death of one bus's broker is invisible to
   the next bus along: it keeps its lock and keeps delivering."
  (with-mcp-server-child-or-skip
    (with-private-state-home ()
      (let ((a (broker:make-bus-paths (selector:bus-root *first-bus*)))
            (b (broker:make-bus-paths (selector:bus-root *second-bus*))))
        (with-killable (proc-b (spawn-ready-broker b :block nil))
          (let ((proc-a (spawn-ready-broker a :block nil)))
            (uiop:terminate-process proc-a :urgent t)
            (uiop:wait-process proc-a))
          (true (wait-until (lambda () (not (broker:broker-running-p a)))
                            :timeout 30)
                "the killed broker released the first bus's lock")
          (true (broker-ready-p b)
                "the second bus's broker still holds its lock and its socket")
          (let ((client (bus:connect-client b))
                (sub (bus:subscribe b "reader-after-the-neighbour-died")))
            (unwind-protect
                 (progn
                   (bus:publish client "still-serving")
                   (is equal '("still-serving")
                       (bodies (bus:await sub :timeout-ms 5000))
                       "the surviving bus still round-trips a message"))
              (bus:disconnect-client client)
              (bus:unsubscribe sub))))))))

(define-test clean-departure-hands-the-cursor-to-the-busmaster
  "An agent that leaves cleanly is recorded on its bus's roster with the time it
   left, and from then on the busmaster keeps its cursor at the head of the log.
   A participant that stayed is left alone: its cursor is written by nobody but
   itself, which is what makes the advance a custody transfer rather than a
   sweep over every file in the directory."
  (with-mcp-server-child-or-skip
    (with-private-state-home ()
      (let* ((paths (broker:make-bus-paths (selector:bus-root *first-bus*)))
             (roster-dir (broker:bus-paths-roster-dir paths))
             (namespace "/tmp/a-repository-that-joined-a-fleet"))
        (with-killable (proc (spawn-ready-broker paths :block nil))
          (let ((publisher (agent:connect-agent namespace :name "publisher"
                                                          :bus *first-bus*
                                                          :ensure-broker nil))
                (leaver (agent:connect-agent namespace :name "leaver"
                                                       :bus *first-bus*
                                                       :ensure-broker nil))
                (stayer (agent:connect-agent namespace :name "stayer"
                                                       :bus *first-bus*
                                                       :ensure-broker nil)))
            (let ((leaver-id (agent:agent-id leaver))
                  (stayer-id (agent:agent-id stayer)))
              (unwind-protect
                   (progn
                     ;; Both readers take delivery of the same two messages, so
                     ;; each has a cursor of its own at the same position.
                     (agent:agent-publish publisher "first")
                     (agent:agent-publish publisher "second")
                     (is = 2 (length (agent:agent-receive leaver :timeout-ms 5000))
                         "the departing agent read what was waiting for it")
                     (is = 2 (length (agent:agent-receive stayer :timeout-ms 5000))
                         "the staying agent read the same two messages")
                     (is = 2 (cursor-at paths leaver-id)
                         "the departing agent's cursor sits at what it read")
                     (is = 2 (cursor-at paths stayer-id)
                         "the staying agent's cursor sits at what it read")

                     ;; Leave cleanly.
                     (multiple-value-bind (drained departed-at)
                         (agent:quiesce-and-leave leaver)
                       (is = 0 drained
                           "nothing was still waiting for the departing agent")
                       (true (integerp departed-at)
                             "leaving recorded a departure time"))
                     (let ((entry (roster:entry leaver-id roster-dir)))
                       (is eq :departed (roster:entry-status entry)
                           "the roster records the agent as departed")
                       (true (integerp (roster:entry-departed-at entry))
                             "the roster entry carries the time it left"))
                     (is equal (list leaver-id)
                         (mapcar #'roster:entry-id
                                 (roster:departed-members roster-dir))
                         "only the agent that left is recorded as departed")

                     ;; Traffic the departed agent will never read. Its cursor
                     ;; must follow the head anyway, or it pins the log.
                     (let ((head (agent:agent-publish publisher "third")))
                       (setf head (agent:agent-publish publisher "fourth"))
                       (setf head (agent:agent-publish publisher "fifth"))
                       (wait-until (lambda () (>= (cursor-at paths leaver-id) head))
                                   :timeout *advance-timeout* :poll 1)
                       (is = head (cursor-at paths leaver-id)
                           "the busmaster advanced the departed agent's cursor to the head")
                       (is = 2 (cursor-at paths stayer-id)
                           "a still-connected agent's cursor was not written by the broker")

                       ;; And it keeps following: a held cursor that fell behind
                       ;; once would be back to pinning the log.
                       (let ((later (agent:agent-publish publisher "sixth")))
                         (wait-until (lambda () (>= (cursor-at paths leaver-id) later))
                                     :timeout *advance-timeout* :poll 1)
                         (is = later (cursor-at paths leaver-id)
                             "the held cursor tracks the head as the log grows")
                         (is = 2 (cursor-at paths stayer-id)
                             "the staying agent's cursor is still its own"))))
                (ignore-errors (agent:disconnect-agent publisher))
                (ignore-errors (agent:disconnect-agent leaver))
                (ignore-errors (agent:disconnect-agent stayer))))))))))
