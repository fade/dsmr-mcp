;;;; tests/support/gated-load-fixture.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; A temporary ASDF system whose load blocks at a gate the test opens.
;;;;
;;;; Provides:
;;;;   make-gated-system      - write and register a uniquely named system
;;;;                            whose only form calls PASS-GATE.
;;;;   remove-gated-system    - clear the system and delete its directory.
;;;;   open-gate, close-gate  - release or re-arm the gate.
;;;;   wait-for-gate-entered  - wait until a load has reached the gate.
;;;;   gated-load-count       - number of loads that passed the gate.
;;;;   pass-gate              - called by the generated component at load time.
;;;;   *gate-safety-seconds*  - longest a load waits at a closed gate.
;;;;
;;;; A load waiting at a closed gate proceeds after *GATE-SAFETY-SECONDS*, so a
;;;; failed test never parks a load thread longer than that.

(defpackage #:dsmr-mcp/tests/support/gated-load-fixture
  (:use #:cl)
  (:import-from #:bordeaux-threads
                #:make-lock
                #:with-lock-held
                #:make-condition-variable
                #:condition-wait
                #:condition-notify)
  (:import-from #:asdf)
  (:import-from #:uiop)
  (:export #:make-gated-system
           #:remove-gated-system
           #:open-gate
           #:close-gate
           #:wait-for-gate-entered
           #:gated-load-count
           #:pass-gate
           #:*gate-safety-seconds*))

(in-package #:dsmr-mcp/tests/support/gated-load-fixture)

(defvar *gate-safety-seconds* 60
  "Seconds a load waits at a closed gate before proceeding anyway.")

(defvar *gate-lock* (make-lock "gated-load-fixture"))
(defvar *gate-cv* (make-condition-variable :name "gated-load-fixture"))
(defvar *gate-open* t "True when loads pass the gate without waiting.")
(defvar *gate-entered* nil "True once a load has reached the gate.")
(defvar *gate-count* 0 "Loads that have passed the gate.")

(defun %wait-on-gate (predicate seconds)
  "Wait with *GATE-LOCK* held until PREDICATE is true or SECONDS pass.
Return the final value of PREDICATE."
  (let ((deadline (+ (get-internal-real-time)
                     (* seconds internal-time-units-per-second))))
    (loop until (funcall predicate)
          for remaining = (- deadline (get-internal-real-time))
          while (plusp remaining)
          do (condition-wait *gate-cv* *gate-lock*
                             :timeout (/ remaining internal-time-units-per-second)))
    (funcall predicate)))

(defun pass-gate ()
  "Mark the gate entered, wait while it is closed for at most
*GATE-SAFETY-SECONDS*, then count one pass."
  (with-lock-held (*gate-lock*)
    (setf *gate-entered* t)
    (condition-notify *gate-cv*)
    (%wait-on-gate (lambda () *gate-open*) *gate-safety-seconds*)
    (incf *gate-count*)
    (condition-notify *gate-cv*)))

(defun open-gate ()
  "Let every waiting and later load pass."
  (with-lock-held (*gate-lock*)
    (setf *gate-open* t)
    (condition-notify *gate-cv*))
  t)

(defun close-gate ()
  "Make later loads wait at the gate and clear the entered flag."
  (with-lock-held (*gate-lock*)
    (setf *gate-open* nil
          *gate-entered* nil))
  t)

(defun wait-for-gate-entered (seconds)
  "Return T once a load has reached the gate, or NIL after SECONDS."
  (with-lock-held (*gate-lock*)
    (and (%wait-on-gate (lambda () *gate-entered*) seconds) t)))

(defun gated-load-count ()
  "Number of loads that have passed the gate."
  (with-lock-held (*gate-lock*)
    *gate-count*))

(defun make-gated-system (prefix)
  "Write and register a system whose load calls PASS-GATE.
The system name and its directory carry PREFIX, the process id and the
universal time, so each call gets a fresh name. Return the system name."
  (let* ((name (format nil "~(~A~)-~D-~D-~D" prefix
                       (or (ignore-errors (uiop:symbol-call :sb-posix :getpid)) 0)
                       (get-universal-time) (random 1000000 (make-random-state t))))
         (dir (uiop:ensure-directory-pathname
               (merge-pathnames name (uiop:temporary-directory))))
         (asd (merge-pathnames (make-pathname :name name :type "asd") dir)))
    (ensure-directories-exist dir)
    (with-open-file (s asd :direction :output :if-exists :supersede)
      (format s "(asdf:defsystem ~S :components ((:file \"gated\")))~%" name))
    (with-open-file (s (merge-pathnames "gated.lisp" dir)
                       :direction :output :if-exists :supersede)
      (format s "(in-package :cl-user)~%~
                 (uiop:symbol-call ~S ~S)~%"
              "DSMR-MCP/TESTS/SUPPORT/GATED-LOAD-FIXTURE" "PASS-GATE"))
    (asdf:load-asd asd)
    name))

(defun remove-gated-system (name prefix)
  "Clear system NAME and delete its directory. PREFIX must start the
directory name; any other directory is left alone."
  (let ((dir (uiop:ensure-directory-pathname
              (merge-pathnames name (uiop:temporary-directory)))))
    (ignore-errors (asdf:clear-system name))
    (when (uiop:directory-exists-p dir)
      (uiop:delete-directory-tree
       dir :validate (lambda (p)
                       (search (string-downcase prefix) (namestring p))))))
  t)
