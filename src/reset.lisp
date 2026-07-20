;;;; src/reset.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Rung-1 local backend reset compositor.
;;;;
;;;; reset-local-backends composes the four existing local-reset primitives —
;;;; attached-connection drop, hermetic worker kill across bound sessions,
;;;; circuit-breaker clear, and orphan-registry clear — into one synchronous,
;;;; non-blocking operation that never waits for a wedged backend to answer.
;;;; This is the foundation the operator restart/recovery ladder reuses: the
;;;; rung-1 operator verb calls it directly, and the background bus listener
;;;; invokes it on an incoming reset command.
;;;;
;;;; Independence: every primitive acts on in-process state or fire-and-forget
;;;; socket/process teardown. drop-connection only shuts a socket down (no
;;;; round-trip on the dead peer); kill-session-worker signals and SIGKILLs a
;;;; child without an RPC; the breaker and orphan registries are in-process
;;;; hash-tables. None of them blocks on the component being reset.
;;;;
;;;; Lock discipline: kill-session-worker re-acquires *pool-lock* internally, so
;;;; the reset-all path snapshots the bound session-ids UNDER *pool-lock*,
;;;; releases the lock, and only THEN kills each worker. A kill issued while
;;;; holding *pool-lock* would deadlock — see %kill-workers.

(defpackage #:dsmr-mcp/src/reset
  (:use #:cl)
  (:import-from #:bordeaux-threads
                #:with-lock-held)
  (:import-from #:dsmr-mcp/src/log
                #:log-event)
  (:import-from #:dsmr-mcp/src/state
                #:*mode*
                #:get-tool-instance)
  (:import-from #:dsmr-mcp/src/attach/connection
                #:drop-connection)
  (:import-from #:dsmr-mcp/src/attach/dispatch
                #:repl-eval-tool-connection-epoch)
  (:import-from #:dsmr-mcp/src/hermetic/pool
                #:kill-session-worker
                #:*circuit-breaker-map*
                #:*pool-lock*)
  (:import-from #:dsmr-mcp/src/orphan
                #:orphan-list
                #:clear-orphan
                #:orphan-count)
  (:export #:reset-local-backends))

(in-package #:dsmr-mcp/src/reset)

;;; ---------------------------------------------------------------------------
;;; Scope normalization
;;; ---------------------------------------------------------------------------

(defun %normalize-scope (scope target)
  "Return (values SCOPE-KEYWORD EFFECTIVE-TARGET) from a caller-supplied SCOPE.

SCOPE may be NIL, a keyword (:all/:attached/:hermetic), or a string. A string
that is not \"all\"/\"attached\"/\"hermetic\" is read as a session-id and narrows
the hermetic kill to that worker (the EFFECTIVE-TARGET). An explicit TARGET is
preserved when SCOPE does not itself name one."
  (cond
    ((null scope) (values :all target))
    ((keywordp scope) (values scope target))
    ((stringp scope)
     (cond
       ((or (zerop (length scope)) (string-equal scope "all"))
        (values :all target))
       ((string-equal scope "attached") (values :attached target))
       ((string-equal scope "hermetic") (values :hermetic target))
       (t (values :hermetic (or target scope)))))
    (t (values :all target))))

;;; ---------------------------------------------------------------------------
;;; Sub-operations
;;; ---------------------------------------------------------------------------

(defun %clear-orphans ()
  "Clear every tracked orphan and return the number removed. Lock-free hygiene:
orphan-list and clear-orphan each serialise on the orphan registry's own lock."
  (let ((before (orphan-count)))
    (dolist (entry (orphan-list))
      (clear-orphan (dsmr-mcp/src/orphan::orphan-entry-request-id entry)))
    (- before (orphan-count))))

(defun %drop-attached (session)
  "Drop the attached connection for SESSION's repl-eval tool when the server is
in attached mode. Return (values ATTACHED-RESET-P EPOCH). Reports NIL when there
is no session, no attached tool, or the server is not in attached mode (the
hermetic/non-attach case). Never errors."
  (when (and session (eq *mode* :attached))
    (let ((tool (ignore-errors (get-tool-instance session "repl-eval"))))
      (when tool
        (ignore-errors (drop-connection tool :reason "operator-reset"))
        (return-from %drop-attached
          (values t (ignore-errors (repl-eval-tool-connection-epoch tool)))))))
  (values nil nil))

(defun %kill-workers (eff-target)
  "Kill hermetic workers and return the count actually killed.

With EFF-TARGET, kill only that session's worker. Otherwise snapshot every bound
session-id UNDER *pool-lock*, release the lock, and kill each — the mandatory
snapshot-then-act discipline, since kill-session-worker re-acquires *pool-lock*
and calling it inside the lock would deadlock. :reset t also clears each killed
session's circuit-breaker entry."
  (if eff-target
      (if (eq (kill-session-worker eff-target :reset t) :killed) 1 0)
      (let ((session-ids
              (with-lock-held (*pool-lock*)
                (loop for sid being the hash-keys
                        of dsmr-mcp/src/hermetic/pool::*affinity-map*
                      collect sid))))
        (loop for sid in session-ids
              count (eq (kill-session-worker sid :reset t) :killed)))))

(defun %clear-circuit-breaker ()
  "Clear the whole circuit-breaker map under *pool-lock*, resetting the
fail-fast window for every session."
  (with-lock-held (*pool-lock*)
    (clrhash *circuit-breaker-map*)))

;;; ---------------------------------------------------------------------------
;;; Compositor
;;; ---------------------------------------------------------------------------

(defun reset-local-backends (session &key (scope :all) target)
  "Reset the local backend surface and return a structured outcome plist.

SESSION is the per-request session object (or NIL); the attached drop uses it to
find the session's repl-eval tool. SCOPE selects the blast radius:
  NIL / :all / \"all\"        -> everything (the big hammer)
  :attached / \"attached\"    -> drop only the attached connection
  :hermetic / \"hermetic\"    -> kill workers and clear the circuit breaker
  a session-id string        -> narrow the hermetic kill to that one worker
TARGET likewise narrows the hermetic kill to one session-id.

A bare call (reset-all) is the default. The call is synchronous and never blocks
on a backend acknowledging. Order of operations: orphan clear (always), attached
drop, hermetic worker kill, circuit-breaker clear.

Returns a plist:
  (:status :ok | :partial
   :summary STRING
   :attached-reset BOOLEAN
   :epoch INTEGER | NIL
   :workers-killed INTEGER
   :circuit-breaker-cleared BOOLEAN
   :orphans-cleared INTEGER)
:status is :partial when one of the sub-operations signalled (and was contained)
rather than completing cleanly."
  (multiple-value-bind (scope-kw eff-target) (%normalize-scope scope target)
    (let ((attached-reset nil)
          (epoch nil)
          (workers-killed 0)
          (cb-cleared nil)
          (orphans-cleared 0)
          (failures 0))
      ;; 1. Orphan clear — always, cheapest hygiene.
      (handler-case (setf orphans-cleared (%clear-orphans))
        (error () (incf failures)))
      ;; 2. Attached connection drop — scope :all / :attached, attached mode only.
      (when (member scope-kw '(:all :attached))
        (handler-case
            (multiple-value-setq (attached-reset epoch) (%drop-attached session))
          (error () (incf failures))))
      ;; 3. Hermetic worker kill — scope :all / :hermetic (or a session-id narrowing).
      (when (member scope-kw '(:all :hermetic))
        (handler-case (setf workers-killed (%kill-workers eff-target))
          (error () (incf failures))))
      ;; 4. Circuit-breaker clear — scope :all / :hermetic.
      (when (member scope-kw '(:all :hermetic))
        (handler-case
            (cond
              ;; A per-session narrowing already cleared that session's breaker
              ;; entry via kill-session-worker :reset t.
              (eff-target (setf cb-cleared t))
              (t (%clear-circuit-breaker) (setf cb-cleared t)))
          (error () (incf failures))))
      (let* ((status (if (plusp failures) :partial :ok))
             (summary
               (format nil
                       "Reset ~(~A~): ~:[attached untouched~;attached conn dropped~]~
~@[ (epoch ~D)~], ~D worker~:P killed, circuit breaker ~:[unchanged~;cleared~], ~
~D orphan~:P cleared."
                       scope-kw attached-reset epoch workers-killed cb-cleared
                       orphans-cleared)))
        (log-event :info "reset.local.complete"
                   "scope" (string-downcase (string scope-kw))
                   "attached_reset" attached-reset
                   "workers_killed" workers-killed
                   "circuit_breaker_cleared" cb-cleared
                   "orphans_cleared" orphans-cleared
                   "status" (string-downcase (string status)))
        (list :status status
              :summary summary
              :attached-reset attached-reset
              :epoch epoch
              :workers-killed workers-killed
              :circuit-breaker-cleared cb-cleared
              :orphans-cleared orphans-cleared)))))
