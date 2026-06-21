;;;; tests/bus/election-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Parachute tests for the flock-based broker election and membership.
;;;;
;;;; flock is tied to the open file DESCRIPTION, not the process, so two open fds
;;;; on the same file genuinely contend within a single process. That lets these
;;;; unit tests exercise the real lock semantics — mutual exclusion, blocking
;;;; takeover readiness, and the shared->exclusive upgrade that detects the last
;;;; member out — without spawning anything. The end-to-end multi-process failover
;;;; under SIGKILL belongs in the slow integration suite.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/bus/election-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/bus/election-test
  (:use #:cl #:parachute)
  (:local-nicknames (#:e #:dsmr-mcp/src/bus/election)))

(in-package #:dsmr-mcp/tests/bus/election-test)

(defmacro with-lockfile ((path) &body body)
  `(let ((,path (uiop:with-temporary-file (:pathname p :keep t :type "lock") p)))
     (unwind-protect (progn ,@body)
       (ignore-errors (delete-file ,path)))))

(defmacro with-fd ((fd path) &body body)
  `(let ((,fd (e:open-lock ,path)))
     (unwind-protect (progn ,@body)
       (ignore-errors (e:close-lock ,fd)))))

;;; election -------------------------------------------------------------------

(define-test first-claimant-becomes-broker
  "On a free lockfile the first contender is elected broker."
  (with-lockfile (path)
    (with-fd (fd path)
      (is eq :broker (e:elect fd)))))

(define-test second-contender-is-client
  "While one fd holds the broker lock, a second contender on the same file is a
   client — mutual exclusion across open file descriptions."
  (with-lockfile (path)
    (with-fd (broker path)
      (is eq :broker (e:elect broker))
      (with-fd (other path)
        (is eq :client (e:elect other))))))

(define-test release-allows-re-election
  "Once the broker releases (or closes) its lock, a waiting contender can win it."
  (with-lockfile (path)
    (with-fd (a path)
      (is eq :broker (e:elect a))
      (with-fd (b path)
        (is eq :client (e:elect b))
        (e:unlock a)                      ; broker steps down
        (is eq :broker (e:elect b))))))   ; successor takes over

(define-test closing-fd-releases-lock
  "Closing the holder's fd (as a dying process would) frees the lock for a new
   broker — the crash-failover primitive."
  (with-lockfile (path)
    (let ((a (e:open-lock path)))
      (is eq :broker (e:elect a))
      (e:close-lock a))                   ; "process death" drops the lock
    (with-fd (b path)
      (is eq :broker (e:elect b)))))

;;; membership / last-one-out --------------------------------------------------

(define-test shared-locks-coexist
  "Multiple members can hold the shared membership lock at once."
  (with-lockfile (path)
    (with-fd (m1 path)
      (with-fd (m2 path)
        (true (e:lock-shared m1) "first member joined")
        (true (e:lock-shared m2) "second member joined")))))

(define-test upgrade-blocked-while-others-present
  "A member cannot upgrade shared->exclusive while another member still holds the
   shared lock — so it does not look like the last one out."
  (with-lockfile (path)
    (with-fd (m1 path)
      (with-fd (m2 path)
        (e:lock-shared m1)
        (e:lock-shared m2)
        (false (e:try-upgrade-exclusive m1)
               "upgrade must fail while m2 still holds shared")))))

(define-test upgrade-succeeds-when-last
  "When every other member has gone, the survivor can upgrade shared->exclusive —
   it is the last one out, the hook the orderly archive hangs on."
  (with-lockfile (path)
    (with-fd (m1 path)
      (e:lock-shared m1)
      (let ((m2 (e:open-lock path)))
        (e:lock-shared m2)
        (false (e:try-upgrade-exclusive m1) "not last while m2 present")
        (e:close-lock m2))               ; m2 leaves
      (true (e:try-upgrade-exclusive m1)
            "now sole member: upgrade succeeds"))))