;;;; src/tools/backend-status.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; MCP tool: backend-status.
;;;;
;;;; ATTACH-CALL-AUDIT: does not serialise. The attached branch reads state
;;;; the connection machinery recorded earlier and puts nothing on the wire,
;;;; so it has no traffic for another call to interleave with. Taking the
;;;; per-session call lock would queue this verb behind the very evaluation
;;;; an operator runs it to ask about, which is the one moment it has to
;;;; answer.
;;;;
;;;; One verb that answers for whichever backend this server is actually using.
;;;; In hermetic mode the backend is a shared pool of worker processes; in
;;;; attached mode it is one connection to the developer's own image, belonging
;;;; to the session that asked. Those are different subjects, so the verb
;;;; branches on the mode rather than refusing outside one of them: an operator
;;;; who has to know which backend is running before they can ask how it is
;;;; doing has been given a puzzle instead of an answer.
;;;;
;;;; It answers about the backend and nothing else. Bus state is a separate
;;;; subject with its own verb, and merging the two produces the kind of
;;;; everything-report nobody reads to the end.
;;;;
;;;; Every classification here is rendered through the shared field contract,
;;;; so each one arrives carrying the check that produced it, the nearest wrong
;;;; conclusion a reader might draw, how the value was obtained, and what would
;;;; flip it. Pure measurements, such as a round trip in milliseconds, have no
;;;; failure state of their own and carry no red condition, which the contract
;;;; allows.
;;;;
;;;; Two bounds in here are the point of the whole file rather than decoration.
;;;; A worker that answers a ping has established that its process is running
;;;; and answering, and nothing whatever about the state of its image. And an
;;;; attached answer is one session's answer: the pool is shared, the attached
;;;; connection is not, and a leader querying one session must not read the
;;;; reply as a fact about the fleet.
;;;;
;;;; CLOS pattern: see pool-status.lisp. Class-allocated slots carry their
;;;; value in an :initform, because the registration hook reads the class
;;;; prototype and the prototype never applies per-class default initargs; a
;;;; value supplied that way is invisible to it and the verb silently fails to
;;;; register. The explicit finalization after the class definition is what
;;;; makes the registration happen at load time.

(defpackage #:dsmr-mcp/src/tools/backend-status
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/tools/base
                #:mcp-tool #:mcp-tool-class #:tool-handle #:tool-session)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:result #:text-content #:make-ht)
  (:import-from #:dsmr-mcp/src/tools/status-fields
                #:reported-field)
  (:import-from #:dsmr-mcp/src/state
                #:*mode* #:get-tool-instance)
  (:import-from #:dsmr-mcp/src/hermetic/pool
                #:pool-status-info
                #:*circuit-breaker-map* #:*circuit-breaker-cooldown*
                #:*crash-breaker-window* #:*crash-history* #:*pool-lock*)
  (:import-from #:dsmr-mcp/src/hermetic/worker-client
                #:*worker-id-counter*)
  (:import-from #:dsmr-mcp/src/attach/dispatch
                #:repl-eval-tool-slynk-conn
                #:repl-eval-tool-connection-epoch
                #:repl-eval-tool-liveness
                #:repl-eval-tool-liveness-basis
                #:repl-eval-tool-last-probe-ms
                #:repl-eval-tool-liveness-checked-at)
  (:import-from #:bordeaux-threads
                #:with-lock-held)
  ;; closer-mop: the class is finalized explicitly after the defclass below.
  ;; MUST be declared here or the cold build fails ("Package CLOSER-MOP does not exist").
  (:import-from #:closer-mop)
  ;; com.inuoe.jzon: the built payload is stringified into the text content.
  ;; MUST be declared here or the cold build fails ("Package COM.INUOE.JZON does not exist").
  (:import-from #:com.inuoe.jzon)
  (:export #:backend-status-tool))

(in-package #:dsmr-mcp/src/tools/backend-status)

;;; ---------------------------------------------------------------------------
;;; Shared wording
;;; ---------------------------------------------------------------------------

(defparameter +image-state-bound+
  "Nothing about whether the worker's in-image state is intact. A wedge that later resolves may have left the image inconsistent, and a healthy ping says nothing about which systems are loaded or what the bindings hold."
  "The bound on every worker liveness classification.

A ping establishes that a process is running and answering a ping. Readers
reliably take it to mean the worker is fit to be given work, which is a
different and much stronger claim, and the gap between the two is where a
recovered-but-inconsistent image gets handed the next call.

Held as one long line rather than continued across several. A backslash before
a newline inside a string literal keeps the newline, so a continued literal
puts hard line breaks in the middle of a sentence that goes out on the wire.")

(defparameter +one-session-only-bound+
  "Nothing about any other session's connection, and nothing about the backend fleet-wide. The attached connection is a per-session resource while the pool is a shared one, so one session's answer here is one session's answer."
  "The bound on every attached classification.

Stated as its own sentence because the asymmetry is invisible from the reply
otherwise: a leader that queries one session and generalises the answer has
made a mistake the response itself has to head off.")

(defparameter +retirement-bound+
  "It does not establish that no worker was recently found unresponsive: a worker is retired in the same step it is classified unresponsive, and this server keeps no record of it afterwards, so a quiet reading here is consistent with a worker having been retired moments ago."
  "The bound on the pool's own liveness reading, and on its crash count.

Worth stating in the reply rather than in a comment. The retirement is
immediate and leaves nothing behind: a standby worker retired for not answering
is dropped from the worker list and never reaches the crash history, so no
field in this response can be read as evidence that nothing has gone wrong
lately.

Written to stand on its own after a full stop, so a caller appends it rather
than folding it into a sentence of its own making.")

;;; ---------------------------------------------------------------------------
;;; Small helpers
;;; ---------------------------------------------------------------------------

(defun %iso-time (universal-time)
  "UNIVERSAL-TIME as an ISO-8601 UTC string, or the current time when it is NIL.

A field's stamp is the age of the answer, so a classification established two
minutes ago is stamped two minutes ago rather than now. A field with no earlier
check to point at was read on this call and is stamped accordingly."
  (multiple-value-bind (sec min hour day month year)
      (decode-universal-time (or universal-time (get-universal-time)) 0)
    (format nil "~4,'0D-~2,'0D-~2,'0DT~2,'0D:~2,'0D:~2,'0DZ"
            year month day hour min sec)))

(defun %basis-for (recorded)
  "Map a recorded liveness basis keyword onto the contract's closed enum.

An active probe is the only thing in this tree that earns the strong answer.
Everything else, including the absence of any check at all, is an inference
from traffic that happened for another reason, and saying so is the whole
value of the field."
  (if (eq recorded :active-probe) "active-probe" "passive-inference"))

(defun %keyword-name (value)
  "VALUE rendered for the wire: a keyword downcased, a string unchanged."
  (cond ((keywordp value) (string-downcase (symbol-name value)))
        ((stringp value) value)
        ((null value) "unknown")
        (t (princ-to-string value))))

(defun %or-null (value)
  "VALUE, or the marker the JSON encoder writes as null, when it is NIL.

Two wrong answers sit either side of this and both were produced before this
existed. A bare NIL is written as the JSON literal false, so a round trip that
has never been measured arrives as a boolean and invites a reader to conclude
something from it. The keyword :NULL is written as the string \"NULL\" rather
than as null, so the value comes out as text and the contract walker then reads
it as a classification and demands a red condition of it.

The symbol the encoder writes as null, and hands back on a parse, is CL:NULL,
which is what the rest of the server uses. An absent measurement is null: nobody has measured,
which is a different statement from any value at all."
  (or value 'cl:null))

;;; ---------------------------------------------------------------------------
;;; The hermetic branch
;;; ---------------------------------------------------------------------------

(defun %breaker-remaining-seconds ()
  "The largest number of seconds left in any live circuit-breaker cooldown.

Zero when no session is inside one. Trips whose cooldown has already run out
are ignored rather than reported as expired, because a cooldown that has ended
is not a fact about now."
  (let ((now (get-universal-time))
        (worst 0))
    (maphash (lambda (session trip-time)
               (declare (ignore session))
               (when (integerp trip-time)
                 (let ((remaining (- (+ trip-time *circuit-breaker-cooldown*) now)))
                   (when (> remaining worst)
                     (setf worst remaining)))))
             *circuit-breaker-map*)
    (max 0 (ceiling worst))))

(defun %crash-count-in-window ()
  "How many crashes the pool has recorded inside the current crash window.

Counted across every session the pool is tracking, under the pool lock, since
the crash-recovery path writes this table from its own threads. Timestamps
older than the window are excluded here rather than trusted to have been pruned
already: the pruning rides the health monitor's tick, so between ticks the table
legitimately holds entries that no longer count."
  (let ((cutoff (- (get-universal-time) *crash-breaker-window*))
        (total 0))
    (with-lock-held (*pool-lock*)
      (maphash (lambda (session history)
                 (declare (ignore session))
                 (dolist (stamp history)
                   (when (and (integerp stamp) (>= stamp cutoff))
                     (incf total))))
               *crash-history*))
    total))

(defun %freshest-ping (workers)
  "Return (values MILLISECONDS CHECKED-AT) for the most recently classified worker
that has a completed round trip to report, or (values NIL NIL) when none has.

The pool has no single round trip of its own. The freshest one any worker has is
the closest honest answer, and the field that carries it says that is what it is."
  (let ((best-ms nil) (best-at nil))
    (loop for w across workers
          for ms = (gethash "last_ping_ms" w)
          for at = (gethash "liveness_checked_at" w)
          do (when (and (realp ms)
                        (or (null best-at)
                            (and (integerp at) (> at best-at))))
               (setf best-ms ms
                     best-at (and (integerp at) at))))
    (values best-ms best-at)))

(defun %worker-payload (w)
  "Render one worker's entry from POOL-STATUS-INFO into contract-bearing fields.

The identifier and the truncated session pass through as plain values: they
name the worker rather than judging it, and a field contract on an identifier
would be noise. Everything that is a judgement is a field."
  (let ((checked-at (%iso-time (gethash "liveness_checked_at" w))))
    (make-ht
     "id" (gethash "id" w)
     "session" (%or-null (gethash "session" w))
     "incarnation"
     (reported-field (gethash "id" w)
                     :establishes "the identifier this worker was issued when it was spawned, which every object id minted against it carries"
                     :does-not-establish "nothing about how long the worker has been running, and nothing about whether it is the worker a given session had earlier"
                     :basis "passive-inference")
     "state"
     (reported-field (%keyword-name (gethash "state" w))
                     :establishes "the state the pool records for this worker, which is what the assignment path reads when a session asks for one"
                     :does-not-establish "nothing about whether the worker is answering. This is bookkeeping the pool writes about the worker, not anything the worker said."
                     :basis "passive-inference"
                     :red-condition "the worker crashes, is retired, or is bound to a session, each of which makes the pool rewrite this")
     "liveness"
     (reported-field (%keyword-name (gethash "liveness" w))
                     :establishes "the classification the pool's health monitor last established for this worker, by pinging it while idle or by reading whether its process is still there"
                     :does-not-establish +image-state-bound+
                     :basis (%basis-for (let ((b (gethash "liveness_basis" w)))
                                          (and (stringp b)
                                               (intern (string-upcase b) :keyword))))
                     :red-condition "the worker leaves enough consecutive pings unanswered to cross the wedge threshold, or its process is found gone"
                     :checked-at checked-at)
     "last_ping_ms"
     (reported-field (%or-null (gethash "last_ping_ms" w))
                     :establishes "the round trip in milliseconds of the last liveness ping this worker answered"
                     :does-not-establish "nothing about what the next call will cost, and nothing about how long an evaluation in this worker will take"
                     :basis "active-probe"
                     :checked-at checked-at)
     "consecutive_missed_pings"
     (reported-field (gethash "consecutive_missed_pings" w)
                     :establishes "how many liveness pings in a row this worker has left unanswered since the last one it answered"
                     :does-not-establish "nothing on its own. One unanswered ping is the ordinary shape of a garbage collection pause, and only a run of them means anything."
                     :basis "active-probe"
                     :checked-at checked-at))))

(defun %hermetic-payload ()
  "Build the whole hermetic answer: the pool, then every worker in it."
  (let* ((info (pool-status-info))
         (workers (gethash "workers" info))
         (running (and (gethash "pool_running" info) t))
         (remaining (%breaker-remaining-seconds))
         (crashes (%crash-count-in-window)))
    (multiple-value-bind (ping-ms ping-at) (%freshest-ping workers)
      (make-ht
       "mode" "hermetic"
       "scope" "The backend here is the hermetic worker pool, which every session on this server shares. Bus state is a separate subject with its own verb and is not answered here."
       "pool"
       (make-ht
        "total_workers" (gethash "total_workers" info)
        "standby_count" (gethash "standby_count" info)
        "bound_count" (gethash "bound_count" info)
        "max_pool_size" (gethash "max_pool_size" info)
        "liveness"
        (reported-field (if running "running" "stopped")
                        :establishes "the pool's own running flag was read on this call, and while it is set the pool will assign workers to sessions and replenish the ones it loses"
                        :does-not-establish (concatenate 'string
                                                         "Nothing about whether any individual worker answers. "
                                                         +retirement-bound+)
                        :basis "passive-inference"
                        :red-condition "the pool is shut down, or every spawn fails while the flag stays set")
        "last_ping_ms"
        (if ping-ms
            (reported-field ping-ms
                            :establishes "the round trip in milliseconds of the most recently completed liveness ping, taken from whichever worker was classified last"
                            :does-not-establish "nothing about any other worker's round trip. This is one worker's measurement, not an average and not a property of the pool."
                            :basis "active-probe"
                            :checked-at (%iso-time ping-at))
            (reported-field (%or-null nil)
                            :establishes "that no liveness ping has completed on this pool yet, so there is no round trip to report"
                            :does-not-establish "nothing about whether the workers would answer if one were sent. No ping has been attempted and failed here; none has finished."
                            :basis "passive-inference"))
        "circuit_breaker"
        (reported-field (if (plusp remaining) "tripped" "clear")
                        :establishes "the breaker map was read on this call and says whether any session is currently inside its fail-fast cooldown"
                        :does-not-establish "which session is affected, and nothing about whether the calling session's own next call will be refused"
                        :basis "passive-inference"
                        :red-condition "a session accumulates the crash threshold within the crash window, which trips the breaker and starts its cooldown")
        "breaker_cooldown_seconds"
        (reported-field remaining
                        :establishes "the seconds left in the longest live breaker cooldown, computed from the recorded trip time and the configured cooldown length"
                        :does-not-establish "nothing about whether calls will succeed once it reaches zero. The cooldown ending only means calls are attempted again."
                        :basis "passive-inference")
        "crash_history_count"
        (reported-field crashes
                        :establishes "how many worker crashes the pool has recorded inside the current crash window, counted across every session it is tracking"
                        :does-not-establish (concatenate 'string
                                                         "It counts crashes and nothing else: a standby worker retired for not answering never reaches this table, so a zero here is not a quiet pool. "
                                                         +retirement-bound+)
                        :basis "passive-inference")
        "worker_incarnations_issued"
        (reported-field *worker-id-counter*
                        :establishes "how many worker identifiers this server has issued since it started, one per worker process spawned"
                        :does-not-establish "nothing about why any worker was replaced and nothing about when. A number larger than the current worker count says a replacement happened at some point, and says nothing about what caused it."
                        :basis "passive-inference"))
       "workers" (map 'vector #'%worker-payload workers)))))

;;; ---------------------------------------------------------------------------
;;; The attached branch
;;; ---------------------------------------------------------------------------

(defparameter +no-breaker-here+
  "There is no circuit breaker in attached mode. This server has one and it belongs to the hermetic worker pool."
  "What the breaker field says when the backend is an attached image.")

(defparameter +no-crash-history-here+
  "There is no crash history in attached mode. The pool counts crashes because it owns the processes that crash; the developer's image is not this server's to count."
  "What the crash-history field says when the backend is an attached image.")

(defun %attached-payload (target)
  "Build the attached answer from TARGET, the calling session's own eval tool.

Reported as not applicable rather than as zero: the breaker and the crash
history do not exist on this side, and a zero reads as a measurement that came
back clean. Those are opposite answers to a reader deciding whether to worry."
  (let ((checked-at (%iso-time (repl-eval-tool-liveness-checked-at target))))
    (make-ht
     "mode" "attached"
     "scope" "The backend here is this session's own connection to the developer's Lisp image. Every value below covers the calling session's connection only and says nothing about any other session or about the backend fleet-wide. Bus state is a separate subject with its own verb and is not answered here."
     "connection"
     (make-ht
      "liveness"
      (reported-field (%keyword-name (repl-eval-tool-liveness target))
                      :establishes "the classification the last bounded probe of this session's connection established, by opening a connection of its own and timing the image's answer"
                      :does-not-establish (concatenate 'string
                                                       +one-session-only-bound+
                                                       " And it establishes nothing about whether the image's own state is intact: an image that answers may still have been left inconsistent by whatever went wrong earlier.")
                      :basis (%basis-for (repl-eval-tool-liveness-basis target))
                      :red-condition "a bounded probe gets no answer inside its deadline, or the image refuses the connection"
                      :checked-at checked-at)
      "last_probe_ms"
      (reported-field (%or-null (repl-eval-tool-last-probe-ms target))
                      :establishes "the round trip in milliseconds of the last probe of this session's connection"
                      :does-not-establish "nothing about what the next evaluation will cost. A probe asks the image a trivial question; a real form is not bounded by that."
                      :basis "active-probe"
                      :checked-at checked-at)
      "connection_epoch"
      (reported-field (repl-eval-tool-connection-epoch target)
                      :establishes "how many times this session's connection has been dropped, which is what a call already in flight compares against to tell a reset from a plain failure"
                      :does-not-establish (concatenate 'string
                                                       "Nothing about whether the current connection is healthy. "
                                                       +one-session-only-bound+)
                      :basis "passive-inference")
      "connection_open"
      (reported-field (if (repl-eval-tool-slynk-conn target) "open" "closed")
                      :establishes "whether this session is currently holding a connection object to the image"
                      :does-not-establish (concatenate 'string
                                                       "That the connection would answer. A held connection to a stopped image reads open here. "
                                                       +one-session-only-bound+)
                      :basis "passive-inference"
                      :red-condition "a failing call drops the connection, which empties the slot until the next call opens one")
      "circuit_breaker"
      (reported-field +no-breaker-here+
                      :establishes "that this mode has no such counter, so the field is answered rather than left out"
                      :does-not-establish "This is not a count of zero. Nothing has been measured here and found clear, and reading it as a clean result is the misreading it exists to prevent."
                      :basis "passive-inference"
                      :red-condition "a circuit breaker is added to attached mode, at which point this answer stops being correct")
      "crash_history"
      (reported-field +no-crash-history-here+
                      :establishes "that this mode has no such counter, so the field is answered rather than left out"
                      :does-not-establish "This is not a count of zero. The developer's image may well have crashed and been restarted; this server does not own it and did not count."
                      :basis "passive-inference"
                      :red-condition "attached mode starts owning the image's lifecycle, at which point there would be something to count")))))

;;; ---------------------------------------------------------------------------
;;; The verb
;;; ---------------------------------------------------------------------------

(defclass backend-status-tool (mcp-tool)
  ;; CRITICAL: class-allocated slots carry their value in an :initform. The
  ;; registration hook reads the class prototype, which never applies the
  ;; per-class default initargs, so a value supplied that way is invisible to
  ;; it and the verb silently fails to register.
  ((dsmr-mcp/src/tools/base::name
    :allocation :class
    :initform "backend-status")
   (dsmr-mcp/src/tools/base::description
    :allocation :class
    :initform "Report the health of whichever backend this server is using: the \
hermetic worker pool, or this session's connection to the developer's Lisp \
image. It answers in both modes, so you do not have to know which one is \
running before you can ask. \
In hermetic mode it reports the pool's liveness, the most recent ping round \
trip, circuit-breaker state with the seconds left in any cooldown, the crash \
count inside the current window, how many worker incarnations have been issued, \
and a per-worker breakdown of state, liveness, last ping and missed pings. \
In attached mode it reports this session's liveness classification, last probe \
round trip, connection epoch and whether a connection is open. It covers the \
calling session's own connection only: it says nothing about any other \
session's connection and nothing about the backend fleet-wide, because the \
attached connection is a per-session resource while the pool is a shared one. \
The breaker and crash-history fields are reported as not applicable in attached \
mode rather than as zero, since a zero would read as a clean measurement where \
in fact nothing was measured. \
Every classification comes back with what it establishes, what it does not, how \
it was obtained and what would flip it, so no value has to be read on trust. \
This verb answers about the backend. Bus state is a separate subject with its \
own verb; ask that one instead of expecting this to say how everything is.")
   (dsmr-mcp/src/tools/base::input-schema
    :allocation :class
    :initform '(:object :properties () :required ())))
  (:metaclass mcp-tool-class)
  (:documentation "MCP tool: report backend health for the active mode.
Branches on *mode* rather than gating on it, so it answers for the hermetic
worker pool and for an attached image alike. The attached branch resolves the
calling session's own tool instance and reads nothing from the request
arguments, so no client can name a session other than its own."))

;; CRITICAL: ensure-finalized must appear after defclass so the metaclass
;; finalize-inheritance :after hook fires at load time and registers
;; "backend-status" in *tool-classes*.
;; (src/tools/base.lisp line 162.)
(c2mop:ensure-finalized (find-class 'backend-status-tool))

(defmethod tool-handle ((tool backend-status-tool) id args)
  (declare (ignore args))
  (case *mode*
    (:hermetic
     (let ((payload (%hermetic-payload)))
       (result id (make-ht "isError" nil
                           "content" (text-content
                                      (com.inuoe.jzon:stringify payload))))))
    (:attached
     ;; The session is the one the request arrived on and the instance is
     ;; reached through it. Nothing here consults the request arguments, so
     ;; there is no path by which a client names a session other than its own.
     (let* ((session (tool-session tool))
            (target (and session (get-tool-instance session "repl-eval"))))
       (if target
           (let ((payload (%attached-payload target)))
             (result id (make-ht "isError" nil
                                 "content" (text-content
                                            (com.inuoe.jzon:stringify payload)))))
           (result id (make-ht "isError" t
                               "content"
                               (text-content
                                "backend-status: this session has no attached-image tool, so there is no connection to report on."))))))
    (t
     (result id (make-ht "isError" t
                         "content"
                         (text-content
                          (format nil "backend-status: the server's backend mode is ~A, which is neither hermetic nor attached, so there is no backend to report on." *mode*)))))))
