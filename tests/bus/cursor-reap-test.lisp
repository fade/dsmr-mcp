;;;; tests/bus/cursor-reap-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Parachute tests for the broker's cursor-directory reap. The contract has two
;;;; halves and the second is the load-bearing one: aged ephemeral cursors are
;;;; removed, and a stable identity's cursor is not removable at any age.
;;;;
;;;; Every filename here is built by running a real id through the real encoder.
;;;; A hand-written percent-encoded literal would keep passing after an encoder
;;;; change, leaving the suite green precisely when the shape match had stopped
;;;; matching anything.

(require :sb-posix)

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/bus/cursor-reap-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/bus/cursor-reap-test
  (:use #:cl #:parachute)
  (:local-nicknames (#:broker #:dsmr-mcp/src/bus/broker)
                    (#:envelope #:dsmr-mcp/src/bus/envelope)))

(in-package #:dsmr-mcp/tests/bus/cursor-reap-test)

(defparameter +namespace+ "/tmp/reap-probe-project"
  "The project root the probe ids are built under. Its own characters are
   irrelevant to the match — only the tail after the last encoded separator is.")

(defmacro with-bus-root ((paths-var) &body body)
  "Bind PATHS-VAR to bus paths over a fresh empty root and delete the tree after.
   The random suffix is seeded per call: SBCL's default random state repeats
   across fresh images, so an unseeded name would collide between runs and every
   assertion below is an absence assertion, which a leftover directory flakes."
  (let ((root (gensym "ROOT")))
    `(let* ((,root (merge-pathnames
                    (format nil "dsmr-cursor-reap-~D-~D/"
                            (sb-posix:getpid)
                            (random 100000000 (make-random-state t)))
                    (uiop:temporary-directory)))
            (,paths-var (broker:make-bus-paths ,root)))
       (broker:ensure-bus-dirs ,paths-var)
       (unwind-protect (progn ,@body)
         (ignore-errors (uiop:delete-directory-tree ,root :validate t))))))

(defun cursor-path (paths id)
  "Where ID's cursor lives — through the real encoder, never a literal."
  (merge-pathnames (envelope:encode-id id)
                   (broker:bus-paths-cursors-dir paths)))

(defun seed-cursor (paths id &key (age-days 0) (seq 5))
  "Write ID's cursor holding SEQ and backdate it AGE-DAYS. Returns its path."
  (let ((path (cursor-path paths id)))
    (with-open-file (out path :direction :output
                              :if-exists :supersede
                              :if-does-not-exist :create)
      (prin1 seq out))
    (when (plusp age-days)
      (let ((when-unix (- (get-universal-time)
                          (encode-universal-time 0 0 0 1 1 1970 0)
                          (* age-days 24 60 60))))
        (sb-posix:utimes (namestring path) when-unix when-unix)))
    path))

(defun ephemeral-id ()
  "An auto-generated ephemeral id — no stable name."
  (envelope:agent-id +namespace+))

(defun stable-id (name)
  (envelope:agent-id +namespace+ :name name))

(define-test aged-ephemeral-is-reaped
  "An ephemeral cursor untouched for a month is removed and counted."
  (with-bus-root (paths)
    (let ((path (seed-cursor paths (ephemeral-id) :age-days 30)))
      (is = 1 (broker:reap-orphaned-cursors paths))
      (false (probe-file path)))))

(define-test recent-ephemeral-survives
  "A live subagent's cursor is not touched by a broker restart."
  (with-bus-root (paths)
    (let ((path (seed-cursor paths (ephemeral-id))))
      (is = 0 (broker:reap-orphaned-cursors paths))
      (true (probe-file path)))))

(define-test aged-stable-cursor-survives
  "The load-bearing case: a stable identity dormant for years keeps its cursor,
   and the reap reports having removed nothing."
  (with-bus-root (paths)
    (let ((path (seed-cursor paths (stable-id "dsmr-mcp") :age-days 3650)))
      (is = 0 (broker:reap-orphaned-cursors paths))
      (true (probe-file path)))))

(define-test stable-lookalikes-survive
  "Names that resemble the ephemeral shape without matching it are stable names,
   and the match must be precise enough to tell them apart."
  (with-bus-root (paths)
    (let ((paths-list (mapcar (lambda (name)
                                (seed-cursor paths (stable-id name) :age-days 3650))
                              '("g-agent" "gateway" "g12" "g12-" "g-1" "gauge-7x"))))
      (is = 0 (broker:reap-orphaned-cursors paths))
      (dolist (path paths-list)
        (true (probe-file path))))))

(define-test mixed-directory-reaps-only-aged-ephemerals
  "In a directory holding all four combinations, exactly the aged ephemerals go."
  (with-bus-root (paths)
    (let ((doomed (list (seed-cursor paths (ephemeral-id) :age-days 30)
                        (seed-cursor paths (ephemeral-id) :age-days 8)
                        (seed-cursor paths (ephemeral-id) :age-days 400)))
          (spared (list (seed-cursor paths (ephemeral-id))
                        (seed-cursor paths (stable-id "runciter") :age-days 3650)
                        (seed-cursor paths (stable-id "pure-tls"))
                        (seed-cursor paths (stable-id "gateway") :age-days 900))))
      (is = 3 (broker:reap-orphaned-cursors paths))
      (dolist (path doomed)
        (false (probe-file path)))
      (dolist (path spared)
        (true (probe-file path))))))

(define-test threshold-is-honored
  "The same fixture reaped against a far larger threshold removes nothing, so the
   default is a parameter the operator can move rather than a constant."
  (with-bus-root (paths)
    (let ((aged (list (seed-cursor paths (ephemeral-id) :age-days 30)
                      (seed-cursor paths (ephemeral-id) :age-days 400))))
      (is = 0 (broker:reap-orphaned-cursors paths :max-age-days 3650))
      (dolist (path aged)
        (true (probe-file path)))
      (is = 2 (broker:reap-orphaned-cursors paths :max-age-days 7)))))
