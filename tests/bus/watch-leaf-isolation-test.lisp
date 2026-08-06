;;;; tests/bus/watch-leaf-isolation-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; A structural guard on the watcher binary's dependency closure.
;;;;
;;;; The watcher is deployed on its own, to machines that have no libzmq and no
;;;; MCP server. That property is not enforced by anything at build time: adding
;;;; one nickname to one defpackage is enough to pull the broker, and with it the
;;;; ZeroMQ transport, into the binary. The build still succeeds here, because
;;;; this machine has libzmq. The failure surfaces later, on a sister's machine,
;;;; as a binary that will not start.
;;;;
;;;; So the closure is asserted directly. A FIND-PACKAGE check cannot answer this
;;;; question: the test image has every package in the project loaded, so every
;;;; such check passes no matter what the watcher actually depends on. Walking
;;;; the ASDF dependency graph is the only thing that answers it in-process.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/bus/watch-leaf-isolation-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/bus/watch-leaf-isolation-test
  (:use #:cl #:zebra))

(in-package #:dsmr-mcp/tests/bus/watch-leaf-isolation-test)

(defparameter *watcher-system* "dsmr-bus-watch"
  "The system whose closure is guarded: the standalone watcher binary.")

(defparameter *forbidden-systems*
  '("dsmr-mcp/src/bus/broker"
    "dsmr-mcp/src/bus/zmq"
    "dsmr-mcp/src/bus/bus"
    "dsmr-mcp/src/bus/agent"
    "dsmr-mcp"
    "pzmq")
  "Systems the watcher must never reach. The broker and the bus facade own the
   ZeroMQ transport; pzmq is the binding that needs libzmq present at run time;
   the MCP server is a different program entirely.")

(defun dependency-name (spec)
  "The system name in a :depends-on entry, or NIL for an entry that names no
   system. Entries can be strings, symbols, or the (:version ...), (:feature ...)
   and (:require ...) forms ASDF allows."
  (cond ((stringp spec) (string-downcase spec))
        ((and spec (symbolp spec)) (string-downcase (symbol-name spec)))
        ((consp spec)
         (let ((head (first spec)))
           (cond ((eq head :version) (dependency-name (second spec)))
                 ((eq head :feature) (dependency-name (third spec)))
                 (t nil))))
        (t nil)))

(defun dependency-closure (root)
  "Every system reachable from ROOT through :depends-on, as a hash table keyed on
   the downcased system name. A name ASDF cannot resolve is recorded and not
   walked, so an optional system that is simply absent reports as absent rather
   than taking the suite down."
  (let ((seen (make-hash-table :test #'equal))
        (queue (list (string-downcase root))))
    (loop while queue
          do (let ((name (pop queue)))
               (unless (gethash name seen)
                 (setf (gethash name seen) t)
                 (let ((system (asdf:find-system name nil)))
                   (when system
                     (dolist (spec (asdf:system-depends-on system))
                       (let ((dep (dependency-name spec)))
                         (when (and dep (not (gethash dep seen)))
                           (push dep queue)))))))))
    seen))

(defun forbidden-reached (closure)
  "The forbidden systems present in CLOSURE, so a failure names the offender
   rather than reporting a bare false."
  (remove-if-not (lambda (name) (gethash name closure)) *forbidden-systems*))

(define-test watcher-closure-is-walkable
  "The walk found a real graph. Without this, every absence assertion below
   would pass just as happily against a walker that returned nothing."
  (let ((closure (dependency-closure *watcher-system*)))
    (true (gethash "dsmr-mcp/src/bus/wal" closure))
    (true (gethash "dsmr-bus-watch/src/bus/watch" closure))
    (true (> (hash-table-count closure) 4))))

(define-test watcher-reaches-the-bus-root-selector
  "The watcher derives its paths from the shared leaf, which is what allows the
   three former copies of that derivation to be gone."
  (let ((closure (dependency-closure *watcher-system*)))
    (true (gethash "dsmr-mcp/src/bus/selector" closure))))

(define-test watcher-reaches-no-transport-or-broker
  "The property the separate deployment rests on. If this fails, the named
   system is the one that got in."
  (let ((closure (dependency-closure *watcher-system*)))
    (is equal '() (forbidden-reached closure))))
