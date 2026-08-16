;;;; tests/attach/probe-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Zebra tests for the Slynk port classifier and identity probe.
;;;;
;;;; Network-requiring tests (classify-port against a live Slynk, full
;;;; resolve-slynk-target identity flow) live in the cross-process integration
;;;; suite.  This file covers the pure, non-network functions only.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/attach/probe-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/attach/probe-test
  (:use #:cl #:zebra)
  (:import-from #:dsmr-mcp/src/attach/probe
                #:classify-port
                #:probe-image-liveness
                #:slynk-handshake-path
                #:read-slynk-handshake
                #:resolve-slynk-target)
  (:import-from #:dsmr-mcp/src/attach/dispatch
                #:repl-eval-tool
                #:repl-eval-tool-liveness
                #:repl-eval-tool-liveness-basis
                #:repl-eval-tool-last-probe-ms
                #:repl-eval-tool-liveness-checked-at
                #:refresh-attached-liveness
                #:*attach-liveness-probe-interval*))

(in-package #:dsmr-mcp/tests/attach/probe-test)

;;; ---------------------------------------------------------------------------
;;; classify-port — :free case (no listener, should be fast)
;;; ---------------------------------------------------------------------------

(define-test classify-port-returns-free-on-refused-connection
  "classify-port returns :free when nothing listens on the probed port."
  ;; Port 1 is well-known as unprivileged-inaccessible on Linux; we use a
  ;; high ephemeral port that is almost certainly not bound to avoid any
  ;; privilege concern.  This test pays a TCP-connect timeout only if
  ;; something really is listening on 19999, which is exceedingly rare.
  (is eq :free (classify-port "127.0.0.1" 19999 :timeout 0.5)))

;;; ---------------------------------------------------------------------------
;;; slynk-handshake-path
;;; ---------------------------------------------------------------------------

(define-test handshake-path-appends-filename
  "slynk-handshake-path appends .dsmr-slynk.port to the project root."
  (let ((p (slynk-handshake-path "/home/fade/SourceCode/lisp/my-project/")))
    (is string= "/home/fade/SourceCode/lisp/my-project/.dsmr-slynk.port"
        (namestring p))))

(define-test handshake-path-normalises-missing-trailing-slash
  "slynk-handshake-path treats a path without a trailing slash the same way."
  (let ((with-slash    (namestring (slynk-handshake-path "/tmp/proj/")))
        (without-slash (namestring (slynk-handshake-path "/tmp/proj"))))
    (is string= with-slash without-slash)))

;;; ---------------------------------------------------------------------------
;;; read-slynk-handshake — file-system cases
;;; ---------------------------------------------------------------------------

(define-test read-handshake-returns-nil-for-missing-file
  "read-slynk-handshake returns NIL when the handshake file does not exist."
  (is eq nil
      (read-slynk-handshake "/tmp/dsmr-mcp-probe-test-nonexistent-dir-99999/")))

(define-test read-handshake-returns-nil-for-nil-root
  "read-slynk-handshake returns NIL for a NIL project-root."
  (is eq nil (read-slynk-handshake nil)))

(define-test read-handshake-returns-nil-for-empty-root
  "read-slynk-handshake returns NIL for an empty string project-root."
  (is eq nil (read-slynk-handshake "")))

(define-test read-handshake-reads-written-file
  "read-slynk-handshake round-trips through an actual file."
  (let* ((dir (uiop:ensure-directory-pathname
               (format nil "/tmp/dsmr-probe-test-~A/" (get-universal-time))))
         (handshake-content "127.0.0.1:18709"))
    (unwind-protect
         (progn
           (ensure-directories-exist dir)
           (with-open-file (f (merge-pathnames ".dsmr-slynk.port" dir)
                             :direction :output :if-exists :supersede
                             :if-does-not-exist :create)
             (write-string handshake-content f)
             (terpri f))
           (is string= handshake-content (read-slynk-handshake (namestring dir))))
      (ignore-errors (uiop:delete-directory-tree dir :validate t)))))

(define-test read-handshake-trims-whitespace
  "read-slynk-handshake strips trailing newlines and spaces."
  (let* ((dir (uiop:ensure-directory-pathname
               (format nil "/tmp/dsmr-probe-test-trim-~A/" (get-universal-time)))))
    (unwind-protect
         (progn
           (ensure-directories-exist dir)
           (with-open-file (f (merge-pathnames ".dsmr-slynk.port" dir)
                             :direction :output :if-exists :supersede
                             :if-does-not-exist :create)
             (format f "  127.0.0.1:29906~%  ~%"))
           (is string= "127.0.0.1:29906"
               (read-slynk-handshake (namestring dir))))
      (ignore-errors (uiop:delete-directory-tree dir :validate t)))))

(define-test read-handshake-returns-nil-for-no-colon
  "read-slynk-handshake returns NIL when the file has no colon (malformed)."
  (let* ((dir (uiop:ensure-directory-pathname
               (format nil "/tmp/dsmr-probe-test-bad-~A/" (get-universal-time)))))
    (unwind-protect
         (progn
           (ensure-directories-exist dir)
           (with-open-file (f (merge-pathnames ".dsmr-slynk.port" dir)
                             :direction :output :if-exists :supersede
                             :if-does-not-exist :create)
             (write-line "notaportstring" f))
           (is eq nil (read-slynk-handshake (namestring dir))))
      (ignore-errors (uiop:delete-directory-tree dir :validate t)))))

;;; ---------------------------------------------------------------------------
;;; resolve-slynk-target — hermetic short-circuit
;;; ---------------------------------------------------------------------------

(define-test resolve-target-hermetic-skips-probe
  "resolve-slynk-target returns (nil :hermetic) immediately when mode is :hermetic."
  (multiple-value-bind (att mode)
      (resolve-slynk-target "127.0.0.1:18709" "/home/fade/SourceCode/lisp/dsmr-mcp/" :hermetic)
    (is eq nil att)
    (is eq :hermetic mode)))

(defun %free-tcp-port ()
  "Bind port 0, read the port the OS assigned, release it, and return it.

There is a race: something else may take the port between the release and the
test's own bind.  It is the same race every port-bound test in this tree runs,
and the tests below are written so it costs a retry rather than a wrong answer.
This leaf must not run beside another suite that binds ports."
  (let ((listener (usocket:socket-listen "127.0.0.1" 0 :reuse-address t)))
    (unwind-protect (usocket:get-local-port listener)
      (usocket:socket-close listener))))

(define-test an-unanswered-port-is-refused-rather-than-slowly-silent
  "Nothing listening reads as dead, and reads that way at once.

The timing is half the claim.  A probe that returned the right classification
after waiting out its whole timeout would be indistinguishable from one that
had learned nothing, and a refusal that takes as long as a silence gives a
caller no reason to treat them differently."
  (let ((port (%free-tcp-port)))
    (multiple-value-bind (classification elapsed-ms)
        (probe-image-liveness "127.0.0.1" port :timeout 0.5)
      (is eq :dead classification)
      (true (< elapsed-ms 250)
            "a refused connection took ~Dms, which is not well under the 500ms timeout"
            elapsed-ms))))

(define-test a-socket-that-accepts-and-answers-nothing-is-wedged
  "A listener that completes the handshake and never speaks reads as wedged.

This is the discriminating case and the whole reason the probe exists.  The
socket is provably fine, so every check that asks only whether something is
listening passes; the evaluation alone is what fails.  Asserting that the
answer is not the refused one is the point, since collapsing the two would
tell an operator to go looking for a process that is in fact still running."
  (let* ((port (%free-tcp-port))
         (listener (usocket:socket-listen "127.0.0.1" port
                                          :reuse-address t :backlog 8)))
    (unwind-protect
         (multiple-value-bind (classification elapsed-ms)
             (probe-image-liveness "127.0.0.1" port :timeout 0.3)
           (is eq :wedged classification)
           (isnt eq :dead classification)
           (true (>= elapsed-ms 250)
                 "a silent socket answered in ~Dms, so the timeout was never waited out"
                 elapsed-ms))
      (usocket:socket-close listener))))

(define-test a-healthy-answer-is-recorded-with-its-age-and-its-cost
  "A probe of a real listener records what it found, how, how long and when.

A classification on its own cannot be judged.  A reader needs to know that a
request was actually sent rather than a value inferred, how long the answer
took, and how old the answer is, or a value confirmed a minute ago is
indistinguishable from one confirmed a second ago."
  (let ((port (slynk:create-server :port 0 :dont-close t))
        (tool (make-instance 'repl-eval-tool))
        (before (get-universal-time)))
    (unwind-protect
         (progn
           (is eq :unknown (repl-eval-tool-liveness tool))
           (is eq nil (repl-eval-tool-liveness-basis tool))
           (is eq nil (repl-eval-tool-liveness-checked-at tool))
           (is eq :healthy (refresh-attached-liveness tool "127.0.0.1" port))
           (is eq :healthy (repl-eval-tool-liveness tool))
           (is eq :active-probe (repl-eval-tool-liveness-basis tool))
           (true (integerp (repl-eval-tool-last-probe-ms tool))
                 "no round trip was recorded")
           (true (>= (repl-eval-tool-liveness-checked-at tool) before)
                 "the classification carries no time at or after the probe"))
      (ignore-errors (slynk:stop-server port)))))

(define-test a-recorded-answer-is-reused-until-it-goes-stale
  "Inside the interval the recorded answer is handed back untouched.

Without this the probe would run on every call, which is what makes a
per-session probe expensive enough to matter across a fleet.  The control that
could fail is the second half: forced past the interval the same call reaches
the same port and the classification does move, so a refresh that had quietly
stopped probing altogether would not pass this."
  (let ((port (slynk:create-server :port 0 :dont-close t))
        (tool (make-instance 'repl-eval-tool))
        (dead-port (%free-tcp-port))
        (*attach-liveness-probe-interval* 300))
    (unwind-protect
         (progn
           (refresh-attached-liveness tool "127.0.0.1" port)
           (is eq :healthy (repl-eval-tool-liveness tool))
           (let ((stamp (repl-eval-tool-liveness-checked-at tool)))
             ;; A port with nothing on it: were the probe to run again the
             ;; classification would move, so an unchanged one is evidence it
             ;; did not run.
             (refresh-attached-liveness tool "127.0.0.1" dead-port)
             (is eq :healthy (repl-eval-tool-liveness tool))
             (is eql stamp (repl-eval-tool-liveness-checked-at tool)))
           ;; Forced, the same call reaches the dead port and says so.
           (refresh-attached-liveness tool "127.0.0.1" dead-port :force t)
           (is eq :dead (repl-eval-tool-liveness tool)))
      (ignore-errors (slynk:stop-server port)))))
