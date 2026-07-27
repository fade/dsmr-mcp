;;;; tests/bus/roster-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Parachute tests for the per-bus roster: enrolling, departing, the closeable
;;;; enrollment gate, the declared leader, and the two read conventions that make
;;;; the rest trustworthy.
;;;;
;;;; Two of these cases carry more weight than they look:
;;;;
;;;;   - A damaged entry must read as present-and-unreadable, never as absent. If
;;;;     it read as absent, an agent that had departed would report as one that
;;;;     never left, and the departure stamp is what anything aging its cursor
;;;;     out has to key on.
;;;;   - A file holding a reader macro must not run it. The roster sits under a
;;;;     state root other processes can write, so the read path is a place code
;;;;     could otherwise arrive from.
;;;;
;;;; Every entry filename here is built by the real path function running the
;;;; real encoder. A hand-written percent-encoded literal would keep passing
;;;; after an encoder change, leaving the suite green exactly when the two sides
;;;; had stopped agreeing.

(require :sb-posix)

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/bus/roster-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/bus/roster-test
  (:use #:cl #:parachute)
  (:local-nicknames (#:roster #:dsmr-mcp/src/bus/roster)
                    (#:envelope #:dsmr-mcp/src/bus/envelope)
                    (#:broker #:dsmr-mcp/src/bus/broker)
                    (#:selector #:dsmr-mcp/src/bus/selector)))

(in-package #:dsmr-mcp/tests/bus/roster-test)

(defparameter +namespace+ "/tmp/roster-probe-project"
  "The project root the probe ids are built under.")

(defvar *reader-macro-fired* nil
  "Set only by a reader macro planted in a roster file. It must stay NIL: if the
   read path ever evaluates what it reads, this is the witness.")

(defmacro with-roster ((roster-dir state-path) &body body)
  "Bind ROSTER-DIR and STATE-PATH under a fresh empty root and delete the tree
   after. The random suffix is seeded per call: SBCL's default random state
   repeats across fresh images, so an unseeded name would collide between runs,
   and several assertions below are absence assertions, which a leftover
   directory flakes.

   Both bindings are declared ignorable, because a case that exercises only the
   gate has no use for the roster directory and vice versa."
  (let ((root (gensym "ROOT")))
    `(let* ((,root (merge-pathnames
                    (format nil "dsmr-roster-~D-~D/"
                            (sb-posix:getpid)
                            (random 100000000 (make-random-state t)))
                    (uiop:temporary-directory)))
            (,roster-dir (merge-pathnames "roster/" ,root))
            (,state-path (merge-pathnames "roster.state" ,root)))
       (declare (ignorable ,roster-dir ,state-path))
       (ensure-directories-exist ,roster-dir)
       (unwind-protect (progn ,@body)
         (ignore-errors (uiop:delete-directory-tree ,root :validate t))))))

(defmacro with-bus-root ((paths-var) &body body)
  "Bind PATHS-VAR to real bus paths over a fresh empty root, create the
   directories the broker would create, and delete the tree after. Used by the
   cases that check where the roster sits rather than what it holds, so the
   layout is read from the broker instead of restated here."
  (let ((root (gensym "ROOT")))
    `(let* ((,root (merge-pathnames
                    (format nil "dsmr-roster-paths-~D-~D/"
                            (sb-posix:getpid)
                            (random 100000000 (make-random-state t)))
                    (uiop:temporary-directory)))
            (,paths-var (broker:make-bus-paths ,root)))
       (broker:ensure-bus-dirs ,paths-var)
       (unwind-protect (progn ,@body)
         (ignore-errors (uiop:delete-directory-tree ,root :validate t))))))

(defun probe-id (name)
  (envelope:agent-id +namespace+ :name name))

(defun entry-files (roster-dir)
  (remove-if-not (lambda (f) (equal (pathname-type f) "member"))
                 (uiop:directory-files roster-dir)))

(defun scratch-files (dir)
  "Any uncommitted write left behind in DIR."
  (when (uiop:directory-exists-p dir)
    (remove-if-not (lambda (f) (equal (pathname-type f) "tmp"))
                   (uiop:directory-files dir))))

(defun plant (path text)
  "Write TEXT verbatim where a roster file is expected."
  (ensure-directories-exist path)
  (with-open-file (out path :direction :output
                            :if-exists :supersede
                            :if-does-not-exist :create)
    (write-string text out))
  path)

;;; ------------------------------------------------------------------ enroll

(define-test enroll-creates-one-entry
  "Enrolling on an empty roster writes exactly one entry and reports it."
  (with-roster (roster-dir state-path)
    (let ((id (probe-id "valis")))
      (multiple-value-bind (record reason) (roster:enroll id roster-dir state-path)
        (false reason)
        (is equal id (roster:entry-id record))
        (is eq :enrolled (roster:entry-status record))
        (false (roster:entry-departed-at record)))
      (is = 1 (length (entry-files roster-dir)))
      (multiple-value-bind (record present) (roster:entry id roster-dir)
        (true present)
        (is equal id (roster:entry-id record))
        (is eq :enrolled (roster:entry-status record))))))

(define-test unknown-id-is-absent-not-damaged
  "An id nobody enrolled answers absent, and says so with its second value."
  (with-roster (roster-dir state-path)
    (multiple-value-bind (record present) (roster:entry (probe-id "nobody") roster-dir)
      (false record)
      (false present))))

(define-test damaged-entry-is-present-not-absent
  "A file that will not parse must be distinguishable from no file at all."
  (with-roster (roster-dir state-path)
    (let ((id (probe-id "mangled")))
      (plant (roster:roster-entry-path id roster-dir) "(:id \"half a form\"")
      (multiple-value-bind (record present) (roster:entry id roster-dir)
        (false record)
        (true present)))))

(define-test non-plist-entry-is-present-not-absent
  "A file that parses but holds something that is not a plist is damage too."
  (with-roster (roster-dir state-path)
    (let ((id (probe-id "wrong-shape")))
      (plant (roster:roster-entry-path id roster-dir) "42")
      (multiple-value-bind (record present) (roster:entry id roster-dir)
        (false record)
        (true present)))))

(define-test reading-an-entry-never-evaluates-it
  "A reader macro planted in a roster file is not run by reading the file."
  (with-roster (roster-dir state-path)
    (let ((id (probe-id "hostile"))
          (*reader-macro-fired* nil))
      (plant (roster:roster-entry-path id roster-dir)
             "#.(cl:setf dsmr-mcp/tests/bus/roster-test::*reader-macro-fired* :fired)")
      (multiple-value-bind (record present) (roster:entry id roster-dir)
        (false record)
        (true present))
      (false *reader-macro-fired*))))

;;; ---------------------------------------------------------------- departure

(define-test disenroll-marks-departed-and-stamps-when
  "Departing records the status and the time, which is what an aging sweep needs."
  (with-roster (roster-dir state-path)
    (let ((id (probe-id "mercer"))
          (before (get-universal-time)))
      (roster:enroll id roster-dir state-path)
      (let ((record (roster:disenroll id roster-dir)))
        (is eq :departed (roster:entry-status record))
        (true (integerp (roster:entry-departed-at record)))
        (true (>= (roster:entry-departed-at record) before)))
      (is eq :departed (roster:entry-status (roster:entry id roster-dir))))))

(define-test disenroll-of-an-unenrolled-id-still-records-a-departure
  "A self-service departure is always recorded, even with no entry to amend."
  (with-roster (roster-dir state-path)
    (let ((id (probe-id "stranger")))
      (let ((record (roster:disenroll id roster-dir)))
        (is equal id (roster:entry-id record))
        (is eq :departed (roster:entry-status record))
        (true (integerp (roster:entry-departed-at record))))
      (multiple-value-bind (record present) (roster:entry id roster-dir)
        (true present)
        (is eq :departed (roster:entry-status record))))))

(define-test enrolling-a-departed-id-brings-it-back
  "Re-enrolling clears the departure stamp rather than leaving a contradiction."
  (with-roster (roster-dir state-path)
    (let ((id (probe-id "hekate")))
      (roster:enroll id roster-dir state-path)
      (roster:disenroll id roster-dir)
      (multiple-value-bind (record reason) (roster:enroll id roster-dir state-path)
        (false reason)
        (is eq :enrolled (roster:entry-status record))
        (false (roster:entry-departed-at record)))
      (is = 1 (length (entry-files roster-dir))))))

(define-test members-lists-everyone-departed-members-lists-only-the-gone
  "The two listings answer different questions over one directory."
  (with-roster (roster-dir state-path)
    (let ((here (probe-id "fulcrum"))
          (gone (probe-id "seven")))
      (roster:enroll here roster-dir state-path)
      (roster:enroll gone roster-dir state-path)
      (roster:disenroll gone roster-dir)
      (is = 2 (length (roster:members roster-dir)))
      (let ((departed (roster:departed-members roster-dir)))
        (is = 1 (length departed))
        (is equal gone (roster:entry-id (first departed)))))))

;;; ----------------------------------------------------------- the gate

(define-test enrollment-is-open-on-a-bus-nobody-has-closed
  "An absent state file reads as open, which is the right default."
  (with-roster (roster-dir state-path)
    (false (probe-file state-path))
    (true (roster:enrollment-open-p state-path))))

(define-test closed-enrollment-refuses-and-names-the-reason
  "The gate stops the roster growing and reports why, writing no entry."
  (with-roster (roster-dir state-path)
    (roster:close-enrollment state-path)
    (false (roster:enrollment-open-p state-path))
    (let ((id (probe-id "latecomer")))
      (multiple-value-bind (record reason) (roster:enroll id roster-dir state-path)
        (false record)
        (is eq :enrollment-closed reason))
      (false (nth-value 1 (roster:entry id roster-dir)))
      (is = 0 (length (entry-files roster-dir))))))

(define-test everything-but-enroll-still-works-while-closed
  "Closing the gate stops enrollment and stops nothing else."
  (with-roster (roster-dir state-path)
    (let ((id (probe-id "incumbent")))
      (roster:enroll id roster-dir state-path)
      (roster:close-enrollment state-path)
      (is = 1 (length (roster:members roster-dir)))
      (is eq :departed (roster:entry-status (roster:disenroll id roster-dir)))
      (is = 1 (length (roster:departed-members roster-dir)))
      (roster:declare-leader id state-path)
      (is equal id (roster:leader state-path)))))

(define-test reopening-the-gate-lets-enrollment-resume
  "Closed is a gate the leader can also open again."
  (with-roster (roster-dir state-path)
    (let ((id (probe-id "returning")))
      (roster:close-enrollment state-path)
      (is eq :enrollment-closed
          (nth-value 1 (roster:enroll id roster-dir state-path)))
      (roster:open-enrollment state-path)
      (true (roster:enrollment-open-p state-path))
      (multiple-value-bind (record reason) (roster:enroll id roster-dir state-path)
        (false reason)
        (is eq :enrolled (roster:entry-status record))))))

;;; --------------------------------------------------------------- leadership

(define-test a-leader-is-declared-and-read-back
  "Leadership is recorded, and reading it back is the whole of the mechanism."
  (with-roster (roster-dir state-path)
    (false (roster:leader state-path))
    (let ((id (probe-id "valis")))
      (roster:declare-leader id state-path)
      (is equal id (roster:leader state-path)))))

(define-test declaring-a-leader-changes-no-entry
  "Declaring records a fact about the bus, not about anybody's membership."
  (with-roster (roster-dir state-path)
    (let ((lead (probe-id "valis"))
          (other (probe-id "mercer")))
      (roster:enroll lead roster-dir state-path)
      (roster:enroll other roster-dir state-path)
      (roster:declare-leader lead state-path)
      (is eq :enrolled (roster:entry-status (roster:entry lead roster-dir)))
      (is eq :enrolled (roster:entry-status (roster:entry other roster-dir)))
      (is = 2 (length (roster:members roster-dir)))
      (is = 0 (length (roster:departed-members roster-dir))))))

;;; ------------------------------------------------------------ write safety

(define-test writes-leave-no-scratch-files-behind
  "Every write commits by rename, so nothing uncommitted survives the call, and
   what lands parses cleanly."
  (with-roster (roster-dir state-path)
    (let ((id (probe-id "tidy")))
      (roster:enroll id roster-dir state-path)
      (roster:declare-leader id state-path)
      (roster:close-enrollment state-path)
      (roster:open-enrollment state-path)
      (roster:disenroll id roster-dir)
      (roster:enroll id roster-dir state-path)
      (is = 0 (length (scratch-files roster-dir)))
      (is = 0 (length (scratch-files (uiop:pathname-directory-pathname state-path))))
      (is = 1 (length (entry-files roster-dir)))
      (multiple-value-bind (record present) (roster:entry id roster-dir)
        (true present)
        (is eq :enrolled (roster:entry-status record))))))

(define-test roster-paths-are-derived-from-the-bus-root
  "The busmaster owns the layout: both roster paths hang off the bus root it was
   handed, so a bus that resolves elsewhere takes its roster with it."
  (with-bus-root (paths)
    (let ((root (broker:bus-paths-root paths)))
      (is equal (merge-pathnames "roster/" root)
          (broker:bus-paths-roster-dir paths))
      (is equal (merge-pathnames "roster.state" root)
          (broker:bus-paths-roster-state paths))
      (true (uiop:subpathp (broker:bus-paths-roster-dir paths) root))
      (true (uiop:subpathp (broker:bus-paths-roster-state paths) root)))))

(define-test a-named-bus-keeps-its-roster-apart-from-the-unnamed-one
  "Isolation reaches the roster. Two buses never share an enrollment record, which
   is the whole point of giving one a name."
  (let ((named (broker:make-bus-paths (selector:bus-root "roster-probe")))
        (unnamed (broker:make-bus-paths (selector:bus-root nil))))
    (false (equal (broker:bus-paths-roster-dir named)
                  (broker:bus-paths-roster-dir unnamed)))
    (false (equal (broker:bus-paths-roster-state named)
                  (broker:bus-paths-roster-state unnamed)))
    (true (uiop:subpathp (broker:bus-paths-roster-dir named)
                         (broker:bus-paths-root named)))))

(define-test creating-a-bus-creates-its-roster-directory
  "Every bus root that exists at all has a roster directory to list, so nothing
   downstream has to guess whether one was ever made."
  (with-bus-root (paths)
    (true (uiop:directory-exists-p (broker:bus-paths-roster-dir paths)))
    (is = 0 (length (roster:members (broker:bus-paths-roster-dir paths))))))

(define-test creating-a-bus-does-not-decide-its-enrollment
  "The roster STATE file stays absent until somebody actually closes the gate or
   declares a leader. An absent file reads as open, and writing one at creation
   would dress a default up as a decision."
  (with-bus-root (paths)
    (false (probe-file (broker:bus-paths-roster-state paths)))
    (true (roster:enrollment-open-p (broker:bus-paths-roster-state paths)))
    (false (roster:leader (broker:bus-paths-roster-state paths)))))
