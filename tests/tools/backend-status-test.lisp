;;;; tests/tools/backend-status-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Coverage for the backend-status verb.
;;;;
;;;; The centrepiece is the conformance walk, and it runs against the verb's
;;;; real response rather than a constructed sample. That distinction is the
;;;; whole reason this leaf exists: a walker asserted against a fixture proves
;;;; the walker reads a fixture. Driving the verb through the production
;;;; dispatcher, taking the JSON it actually puts on the wire, parsing it back
;;;; the way a client would, and walking the result is what proves the contract
;;;; holds for a shipped payload.
;;;;
;;;; It already caught one. An absent measurement was first written as the
;;;; keyword the parser hands back for JSON null; the encoder wrote that as the
;;;; string "NULL", the parse read a string, and the walker correctly reported a
;;;; classification with no red condition. Nothing else in the suite would have
;;;; noticed, because the verb's own code looked right and only the round trip
;;;; through the encoder was wrong. The null test below is the standing guard on
;;;; that.
;;;;
;;;; The negative control matters as much as the conformance assertion. Without
;;;; a mutated response that the walker is watched rejecting, a NIL from the
;;;; walker is indistinguishable from a walker that never looked at this payload
;;;; shape at all.
;;;;
;;;; The pool fixture builds worker records by hand and binds the pool's own
;;;; specials around them. No worker process is spawned and nothing is left
;;;; behind: every binding is a LET, so a failing assertion cannot strand pool
;;;; state a sibling leaf would then read.

(defpackage #:dsmr-mcp/tests/tools/backend-status-test
  (:use #:cl #:zebra)
  (:local-nicknames (#:jzon #:com.inuoe.jzon))
  (:import-from #:dsmr-mcp/src/tools/status-fields
                #:field-contract-violations)
  (:import-from #:dsmr-mcp/src/dispatch
                #:handle-tools-call)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:make-ht)
  (:import-from #:dsmr-mcp/src/state
                #:*mode* #:*current-session-id* #:make-session)
  (:import-from #:dsmr-mcp/src/hermetic/pool
                #:*pool-lock* #:*pool-running*
                #:*all-workers* #:*standby-workers*
                #:*circuit-breaker-map* #:*crash-history*)
  (:import-from #:dsmr-mcp/src/hermetic/worker-client
                #:make-worker))

(in-package #:dsmr-mcp/tests/tools/backend-status-test)

;;; ---------------------------------------------------------------------------
;;; Driving the verb
;;; ---------------------------------------------------------------------------

(defun %call (session-id)
  "Dispatch backend-status through the production entry point and return the
whole JSON-RPC envelope.

Routed through HANDLE-TOOLS-CALL rather than by building a tool instance and
calling its handler, because the routing is part of what is under test: a verb
the hermetic router sends to a worker instead of serving locally answers
nothing useful, and that failure is invisible to a direct handler call."
  (let ((*current-session-id* session-id))
    (handle-tools-call (make-session :id session-id
                                     :slynk-attach "127.0.0.1:1")
                       "backend-status-call"
                       (make-ht "name" "backend-status"
                                "arguments" (make-ht)))))

(defun %payload (envelope)
  "The verb's answer, parsed back the way a client reads it.

Deliberately a parse of the emitted JSON rather than a peek at the hash-table
the verb built. Everything between the two is where an encoder turns a value
into something a reader will misread, and that gap is exactly what the
conformance walk is here to cover."
  (let* ((res (gethash "result" envelope))
         (content (gethash "content" res)))
    (jzon:parse (gethash "text" (aref content 0)))))

(defun %error-flag (envelope)
  "The isError flag on the verb's result payload."
  (gethash "isError" (gethash "result" envelope)))

;;; ---------------------------------------------------------------------------
;;; Fixtures
;;; ---------------------------------------------------------------------------

(defun %healthy-worker ()
  "An idle worker the health monitor has pinged and found answering."
  (make-worker :id 7 :state :standby :session-id nil
               :tcp-port 41001 :pid 424201
               :liveness :healthy :liveness-basis :active-probe
               :last-ping-milliseconds 3
               :consecutive-missed-pings 0
               :liveness-checked-at (get-universal-time)))

(defun %never-probed-worker ()
  "A worker bound to a session and therefore never actively probed.

Its round trip is genuinely absent rather than zero, which is what makes it the
right fixture for the null test below."
  (make-worker :id 8 :state :bound :session-id "a-session-id-long-enough-to-truncate"
               :tcp-port 41002 :pid 424202
               :liveness :unknown :liveness-basis nil
               :last-ping-milliseconds nil
               :consecutive-missed-pings 2
               :liveness-checked-at nil))

(defmacro with-populated-pool ((&key (breaker t) (crashes t)) &body body)
  "Run BODY against a pool holding two hand-built workers.

Every special is rebound rather than assigned, so nothing survives the form
however BODY leaves. No process is spawned: the verb reads the pool's records,
and records are what this fixture supplies."
  `(let* ((*pool-running* t)
          (*all-workers* (list (%healthy-worker) (%never-probed-worker)))
          (*standby-workers* (list (first *all-workers*)))
          (*circuit-breaker-map*
            (let ((h (make-hash-table :test 'equal)))
              (when ,breaker
                (setf (gethash "tripped-session" h) (get-universal-time)))
              h))
          (*crash-history*
            (let ((h (make-hash-table :test 'equal)))
              (when ,crashes
                (setf (gethash "crashy-session" h)
                      (list (get-universal-time)
                            (- (get-universal-time) 10))))
              h)))
     ,@body))

(defun %pool-field (payload key)
  "One reported field out of the hermetic answer's pool section."
  (gethash key (gethash "pool" payload)))

(defun %worker-field (payload index key)
  "One reported field out of the hermetic answer's INDEXth worker."
  (gethash key (aref (gethash "workers" payload) index)))

(defun %connection-field (payload key)
  "One reported field out of the attached answer's connection section."
  (gethash key (gethash "connection" payload)))

(defun %mentions (field needle)
  "True when FIELD's stated bound carries NEEDLE.

Matched on a phrase rather than a whole sentence on purpose. The assertion is
about what the bound has to say, so rewording it for clarity later must not
turn the test red."
  (let ((bound (gethash "does_not_establish" field)))
    (and (stringp bound) (search needle bound) t)))

;;; ---------------------------------------------------------------------------
;;; The conformance walk over the real response
;;; ---------------------------------------------------------------------------

(define-test the-hermetic-answer-conforms-to-the-field-contract
  "Every field in the hermetic answer states its own bounds, walked over the
payload the verb actually emitted and a client actually parses.

Driven twice: once with workers in the pool and once with none, because the
empty pool takes a different branch for the round-trip field and a walk that
only ever sees the populated shape has not seen that branch."
  (let ((*mode* :hermetic))
    (with-populated-pool ()
      (let ((envelope (%call "backend-status-hermetic")))
        (is eq nil (%error-flag envelope)
            "the verb answers in hermetic mode rather than refusing")
        (is equal '() (field-contract-violations (%payload envelope))
            "the populated hermetic answer conforms")))
    (let* ((*pool-running* nil)
           (*all-workers* '())
           (*standby-workers* '())
           (envelope (%call "backend-status-hermetic-empty")))
      (is equal '() (field-contract-violations (%payload envelope))
          "the answer for a pool that is not running conforms too"))))

(define-test the-attached-answer-conforms-to-the-field-contract
  "Every field in the attached answer states its own bounds, walked over the
emitted payload."
  (let* ((*mode* :attached)
         (envelope (%call "backend-status-attached")))
    (is eq nil (%error-flag envelope)
        "the verb answers in attached mode rather than refusing")
    (is equal '() (field-contract-violations (%payload envelope))
        "the attached answer conforms")))

(define-test a-bound-deleted-from-the-real-answer-is-reported
  "The negative control on the conformance walk.

One key is removed from one classification in a response the verb genuinely
produced, and the walker has to name it. Without this, a NIL from the walker in
the two tests above is equally consistent with a walker that never looked at
this payload shape."
  (let* ((*mode* :attached)
         (payload (%payload (%call "backend-status-attached-mutated"))))
    (remhash "does_not_establish" (%connection-field payload "liveness"))
    (let ((violations (field-contract-violations payload)))
      (true violations "deleting a stated bound produces a violation")
      (true (find-if (lambda (v) (search "connection.liveness" v)) violations)
            "the violation names the field the bound was taken from")))
  (let ((*mode* :hermetic))
    (with-populated-pool ()
      (let ((payload (%payload (%call "backend-status-hermetic-mutated"))))
        (remhash "does_not_establish" (%worker-field payload 0 "liveness"))
        (let ((violations (field-contract-violations payload)))
          (true violations "the same deletion on a worker field is reported")
          (true (find-if (lambda (v) (search "workers[0].liveness" v)) violations)
                "the violation names the worker whose bound was taken"))))))

;;; ---------------------------------------------------------------------------
;;; What the hermetic answer says
;;; ---------------------------------------------------------------------------

(define-test the-hermetic-answer-carries-each-backend-fact-under-its-own-key
  "Liveness, the last ping round trip, breaker state with its remaining
cooldown, the crash count and the incarnation indicator each arrive under a key
of their own, as a field carrying a value rather than as a bare scalar."
  (let ((*mode* :hermetic))
    (with-populated-pool ()
      (let ((payload (%payload (%call "backend-status-hermetic-content"))))
        (is string= "hermetic" (gethash "mode" payload)
            "the answer names the backend it is about")
        (dolist (key '("liveness" "last_ping_ms" "circuit_breaker"
                       "breaker_cooldown_seconds" "crash_history_count"
                       "worker_incarnations_issued"))
          (let ((field (%pool-field payload key)))
            (true (hash-table-p field)
                  (format nil "~A is present as a reported field" key))
            (true (nth-value 1 (gethash "value" field))
                  (format nil "~A carries a value" key))))
        (is string= "running" (gethash "value" (%pool-field payload "liveness"))
            "a running pool reads running")
        (is = 3 (gethash "value" (%pool-field payload "last_ping_ms"))
            "the pool's round trip is the one its freshest worker measured")
        (is string= "tripped" (gethash "value" (%pool-field payload "circuit_breaker"))
            "a live trip reads tripped")
        (true (plusp (gethash "value" (%pool-field payload "breaker_cooldown_seconds")))
              "a live trip leaves cooldown seconds on the clock")
        (is = 2 (gethash "value" (%pool-field payload "crash_history_count"))
            "both crashes inside the window are counted")
        (dolist (key '("state" "liveness" "last_ping_ms"
                       "consecutive_missed_pings" "incarnation"))
          (true (nth-value 1 (gethash "value" (%worker-field payload 0 key)))
                (format nil "each worker carries ~A as a field" key)))
        (is = 7 (gethash "value" (%worker-field payload 0 "incarnation"))
            "a worker's incarnation is the identifier it was spawned with")))))

(define-test a-clear-breaker-reads-clear-and-costs-no-cooldown
  "The other side of the breaker assertion, so the tripped reading above is not
the only thing the field can say."
  (let ((*mode* :hermetic))
    (with-populated-pool (:breaker nil :crashes nil)
      (let ((payload (%payload (%call "backend-status-hermetic-clear"))))
        (is string= "clear" (gethash "value" (%pool-field payload "circuit_breaker"))
            "no live trip reads clear")
        (is = 0 (gethash "value" (%pool-field payload "breaker_cooldown_seconds"))
            "a clear breaker has no cooldown left")
        (is = 0 (gethash "value" (%pool-field payload "crash_history_count"))
            "an empty history counts nothing")))))

(define-test a-worker-liveness-reading-refuses-the-in-image-inference
  "The bound that stops the commonest wrong conclusion: a worker answering a
ping says nothing about the state of the image inside it."
  (let ((*mode* :hermetic))
    (with-populated-pool ()
      (let ((payload (%payload (%call "backend-status-hermetic-bound"))))
        (true (%mentions (%worker-field payload 0 "liveness") "in-image state")
              "a worker's liveness says it does not speak for the image's state")))))

(define-test an-unmeasured-round-trip-is-null-and-not-a-number-or-a-word
  "A worker that has never been probed reports no round trip at all.

The standing guard on a defect the conformance walk caught. Written as the
keyword :NULL, the value went out as the string \"NULL\", came back as a
string, and was then read as a classification with no red condition. The symbol
the encoder writes as null, and hands back on a parse, is CL:NULL. Both wrong
answers are asserted against here, along with the boolean the encoder produces
from a bare NIL."
  (let ((*mode* :hermetic))
    (with-populated-pool ()
      (let* ((payload (%payload (%call "backend-status-hermetic-null")))
             (value (gethash "value" (%worker-field payload 1 "last_ping_ms"))))
        (is eq 'cl:null value "an unmeasured round trip parses back as JSON null")
        (false (stringp value) "it is not the word NULL rendered as text")
        (false (numberp value) "it is not a number, least of all zero")
        (false (eq value t) "and it is not a boolean")))))

;;; ---------------------------------------------------------------------------
;;; What the attached answer says
;;; ---------------------------------------------------------------------------

(define-test the-attached-answer-carries-the-connection-facts-under-their-own-keys
  "Liveness, the last probe round trip and the connection epoch each arrive
under a key of their own."
  (let* ((*mode* :attached)
         (payload (%payload (%call "backend-status-attached-content"))))
    (is string= "attached" (gethash "mode" payload)
        "the answer names the backend it is about")
    (dolist (key '("liveness" "last_probe_ms" "connection_epoch" "connection_open"))
      (let ((field (%connection-field payload key)))
        (true (hash-table-p field)
              (format nil "~A is present as a reported field" key))
        (true (nth-value 1 (gethash "value" field))
              (format nil "~A carries a value" key))))
    (is = 0 (gethash "value" (%connection-field payload "connection_epoch"))
        "a session that has dropped nothing reports the epoch it started at")
    (is string= "closed" (gethash "value" (%connection-field payload "connection_open"))
        "a session holding no connection reports closed")))

(define-test the-attached-breaker-and-crash-count-are-not-applicable-not-zero
  "The misreading this design guards against, asserted directly.

A zero says a counter was read and came back clean. There is no counter on this
side at all, and the two answers point a reader in opposite directions, so the
fields must not be numbers."
  (let* ((*mode* :attached)
         (payload (%payload (%call "backend-status-attached-not-applicable"))))
    (dolist (key '("circuit_breaker" "crash_history"))
      (let ((value (gethash "value" (%connection-field payload key))))
        (false (numberp value)
               (format nil "~A is not reported as a number" key))
        (false (eql value 0)
               (format nil "~A is not reported as zero" key))
        (true (and (stringp value) (plusp (length value)))
              (format nil "~A says in words that the mode has no such counter" key))))))

(define-test an-attached-answer-says-it-speaks-for-one-session-only
  "The bound that stops a leader reading one session's reply as a fleet-wide
fact. Asserted on the meaning rather than on an exact sentence, so the wording
can be improved without turning this red."
  (let* ((*mode* :attached)
         (payload (%payload (%call "backend-status-attached-scope"))))
    (true (%mentions (%connection-field payload "liveness") "other session")
          "the liveness bound says it does not speak for another session")
    (true (search "calling session" (gethash "scope" payload))
          "and the answer as a whole says whose connection it covers")))
