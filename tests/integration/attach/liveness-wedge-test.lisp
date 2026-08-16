;;;; tests/integration/attach/liveness-wedge-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Planted-fault coverage for the attached liveness classification, against a
;;;; real image in another process.
;;;;
;;;; Two conditions are planted against the same real child, and the pair is the
;;;; point. An image that has stopped answering must be classified wedged and an
;;;; image that is merely busy must not, or the classification distinguishes
;;;; nothing and the surface that renders it is worse than no surface at all.
;;;;
;;;; The wedge is planted by stopping the whole process rather than by occupying
;;;; its evaluation thread. Occupying the evaluation thread is what a legitimately
;;;; busy image looks like, and the probe deliberately asks its question on a
;;;; connection nothing else is using, so an occupied thread is invisible to it by
;;;; design. That case is therefore the busy control here, and it is asserted
;;;; first, because it is the requirement the wedge plant must not contradict.
;;;;
;;;; A stopped process still completes TCP handshakes out of the kernel's accept
;;;; backlog, so its socket stays connectable while nothing inside answers. That
;;;; is precisely the condition this classification exists to name, and the plain
;;;; socket connect is asserted before the classification is, because without it
;;;; a wedged reading and a gone image are indistinguishable.
;;;;
;;;; The child is stopped with a real signal, so the release is issued from a
;;;; cleanup form and the teardown never asks whether the child is worth killing:
;;;; it continues it, terminates it and reaps it unconditionally. A teardown that
;;;; asks a question can be given the wrong answer and skip its kill, and the run
;;;; then reports green with a stopped image still on the machine.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/integration/attach/liveness-wedge-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/integration/attach/liveness-wedge-test
  (:use #:cl #:zebra)
  (:import-from #:dsmr-mcp/src/attach/probe
                #:probe-image-liveness)
  (:import-from #:dsmr-mcp/src/attach/connection
                #:bounded-slime-eval)
  (:import-from #:slynk-client
                #:slime-connect
                #:slime-close)
  (:import-from #:dsmr-mcp/src/attach/dispatch
                #:%dispatch-attach
                #:repl-eval-tool-slynk-conn
                #:repl-eval-tool-connection-epoch
                #:repl-eval-tool-liveness
                #:repl-eval-tool-liveness-checked-at)
  (:import-from #:dsmr-mcp/src/tools/attach-reset
                #:attach-reset-tool)
  (:import-from #:dsmr-mcp/src/tools/base
                #:tool-handle)
  (:import-from #:dsmr-mcp/src/state
                #:*mode*
                #:make-session
                #:get-tool-instance)
  (:import-from #:dsmr-mcp/tests/integration/support
                #:with-foreign-slynk-child-or-skip)
  (:import-from #:usocket)
  (:import-from #:bordeaux-threads)
  (:import-from #:sb-posix)
  ;; Exported so the reset-race leaf reuses this fixture, its long evaluation
  ;; and its teardown rather than growing a second set that can drift from it.
  (:export #:with-stoppable-image
           #:socket-answers-p
           #:process-command-line
           #:process-run-state
           #:image-session
           #:image-tool
           #:dispatch-code
           #:call-attach-reset
           #:key-present-p
           #:response-text
           #:release-path
           #:waiting-form
           #:release-the-waiting-form
           #:+freeze-signal+
           #:+release-signal+))

(in-package #:dsmr-mcp/tests/integration/attach/liveness-wedge-test)

;;; ---------------------------------------------------------------------------
;;; Signals used to plant and release the fault
;;; ---------------------------------------------------------------------------

(defconstant +freeze-signal+ 19
  "SIGSTOP. Halts a process without ending it, which is the one fault that
leaves every existence check, and every plain TCP connect, answering exactly as
it does for a healthy image.")

(defconstant +release-signal+ 18
  "SIGCONT. Resumes a stopped process. Always sent from a cleanup form so a red
assertion cannot leave a stopped image behind.")

;;; ---------------------------------------------------------------------------
;;; Instruments, none of them the code under test
;;; ---------------------------------------------------------------------------

(defun process-command-line (pid)
  "The process's own command line, read out of the process table.

This answers existence and identity in one reading, and it is nothing these
tests check. A teardown or a plant that asked the classification under test
whether a process was worth killing would agree with it by construction, and
would stop working at exactly the moment it was needed."
  (handler-case
      (with-open-file (in (format nil "/proc/~D/cmdline" pid)
                          :element-type '(unsigned-byte 8)
                          :if-does-not-exist nil)
        (when in
          (let* ((buf (make-array 8192 :element-type '(unsigned-byte 8)))
                 (n (read-sequence buf in)))
            (map 'string (lambda (b) (if (zerop b) #\Space (code-char b)))
                 (subseq buf 0 n)))))
    (error () nil)))

(defun process-run-state (pid)
  "The kernel's own one-letter run state for the process: S sleeping, R running,
T stopped, Z zombie. Read from the process table, so a stopped image is
established by the operating system rather than inferred from what it stopped
answering."
  (handler-case
      (let* ((line (uiop:read-file-string (format nil "/proc/~D/stat" pid)))
             (close (position #\) line :from-end t)))
        (when close (string (char line (+ close 2)))))
    (error () nil)))

(defun socket-answers-p (host port)
  "True when a plain TCP connect to HOST and PORT completes.

A raw socket and nothing else. This is what makes a wedged reading mean
something: without it, an image that stopped answering and an image that is gone
produce the same failure and the classification has told the reader nothing."
  (handler-case
      (let ((s (usocket:socket-connect host port :timeout 2)))
        (usocket:socket-close s)
        t)
    (error () nil)))

(defun image-answers-p (port)
  "True when a Slynk client can get an evaluation back out of the image.

Deliberately the client library and not the classification these tests check. A
fixture that asked the classifier whether the image was ready would agree with it
by construction and would stop working at exactly the moment a control blinded
it, which is the failure mode that makes a control look robust while checking
nothing."
  (let ((conn (ignore-errors (slime-connect "127.0.0.1" port))))
    (when conn
      (unwind-protect
           (eql 42 (ignore-errors (bounded-slime-eval '(+ 40 2) conn :timeout 1)))
        (ignore-errors (slime-close conn))
        (ignore-errors (usocket:socket-shutdown (slynk-client::usocket conn) :io))))))

;;; ---------------------------------------------------------------------------
;;; The child image
;;; ---------------------------------------------------------------------------

(defun free-loopback-port ()
  "Bind an OS-assigned loopback port, read it back, release it, return it."
  (let ((l (usocket:socket-listen "127.0.0.1" 0 :reuse-address t)))
    (unwind-protect (usocket:get-local-port l)
      (usocket:socket-close l))))

(defun foreign-child-forms (port)
  "The eval program for a throwaway SBCL that serves Slynk on PORT and then
waits. Foreign package symbols are reached through read-from-string so the forms
never fail to read before their package exists."
  (list
   "--eval" "(require :asdf)"
   "--eval" (concatenate 'string
                         "(let ((q (merge-pathnames \"quicklisp/setup.lisp\""
                         " (user-homedir-pathname))))"
                         " (when (and (probe-file q) (not (find-package :ql)))"
                         " (load q)))")
   "--eval" "(funcall (read-from-string \"ql:quickload\") (list :slynk) :silent t)"
   "--eval" (format nil "(funcall (read-from-string \"slynk:create-server\") :port ~D :dont-close t)"
                    port)
   "--eval" "(loop (sleep 3600))"))

(defmacro with-stoppable-image ((port-var pid-var) &body body)
  "Spawn a throwaway SBCL serving Slynk, bind PORT-VAR and PID-VAR, run BODY,
then always continue, terminate and reap the child.

The teardown asks nothing. It sends the continue signal whether or not anything
stopped the child, terminates it whether or not it looks alive, and waits for it.
A teardown that decides whether to kill can be given the wrong answer, and the
symptom is a real image left running while the suite reports a clean run.

The wait for the child is in two stages, and both are needed: a socket that
accepts is not yet an image that answers, and a test that started against the
first would be racing the second."
  (let ((log (gensym "LOG-")) (proc (gensym "PROC-")) (tmp (gensym "PORT-")))
    `(let* ((,tmp (free-loopback-port))
            (,log (uiop:tmpize-pathname
                   (merge-pathnames "dsmr-attach-wedge.log" (uiop:temporary-directory))))
            (,proc (uiop:launch-program
                    (list* (uiop:native-namestring sb-ext:*runtime-pathname*)
                           "--noinform" "--disable-debugger"
                           (foreign-child-forms ,tmp))
                    :output ,log :error-output ,log))
            (,pid-var (uiop:process-info-pid ,proc))
            (,port-var ,tmp))
       (declare (ignorable ,port-var ,pid-var))
       (unwind-protect
            (progn
              (loop repeat 240
                    until (socket-answers-p "127.0.0.1" ,port-var)
                    do (sleep 0.25))
              (loop repeat 160
                    until (image-answers-p ,port-var)
                    do (sleep 0.25))
              (unless (image-answers-p ,port-var)
                (error "with-stoppable-image: the child never answered on 127.0.0.1:~D~%~
--- child output tail ---~%~A"
                       ,port-var
                       (ignore-errors
                        (let ((s (uiop:read-file-string ,log)))
                          (subseq s (max 0 (- (length s) 2000)))))))
              ,@body)
         (ignore-errors (sb-posix:kill ,pid-var +release-signal+))
         (ignore-errors (uiop:terminate-process ,proc :urgent t))
         (ignore-errors (uiop:wait-process ,proc))
         (ignore-errors (delete-file ,log))))))

;;; ---------------------------------------------------------------------------
;;; Session wiring
;;; ---------------------------------------------------------------------------

(defun image-session (id port)
  "A session addressed at the child image."
  (make-session :id id :slynk-attach (format nil "127.0.0.1:~D" port)))

(defun image-tool (session)
  "The session's own repl-eval instance, carrying its connection and its epoch."
  (get-tool-instance session "repl-eval"))

(defun dispatch-code (tool code &key (timeout 5))
  "Run CODE through the production attached dispatch path and return its
response envelope."
  (let ((params (make-hash-table :test 'equal)))
    (setf (gethash "code" params) code
          (gethash "timeout_seconds" params) timeout)
    (%dispatch-attach tool params)))

(defun call-attach-reset (session)
  "Dispatch the reset verb on a fresh instance bound to SESSION."
  (let ((tool (make-instance 'attach-reset-tool :session session)))
    (gethash "result" (tool-handle tool "attach-reset-call" nil))))

(defun key-present-p (ht key)
  "True when KEY is present in HT, whatever its value."
  (and (hash-table-p ht) (nth-value 1 (gethash key ht))))

(defun response-text (envelope)
  "Concatenate the text of every content block in ENVELOPE."
  (let ((blocks (and (hash-table-p envelope) (gethash "content" envelope))))
    (with-output-to-string (s)
      (when (vectorp blocks)
        (loop for b across blocks
              for txt = (and (hash-table-p b) (gethash "text" b))
              when (stringp txt) do (write-string txt s))))))

;;; ---------------------------------------------------------------------------
;;; A long evaluation the test can end when it chooses
;;; ---------------------------------------------------------------------------

(defun release-path ()
  "A path nothing has created yet, used as the condition a long evaluation waits
on. The evaluation is a real one running in the child image, and the test decides
when it finishes by creating the file."
  (merge-pathnames (format nil "dsmr-attach-wedge-release-~D-~D"
                           (sb-posix:getpid) (random 1000000))
                   (uiop:temporary-directory)))

(defun waiting-form (path)
  "Source for an evaluation that occupies the image until PATH appears."
  (format nil "(progn (loop until (probe-file ~S) do (sleep 0.05)) :released)"
          (namestring path)))

(defun release-the-waiting-form (path)
  "End the long evaluation and remove the file it was waiting on."
  (ignore-errors
    (with-open-file (s path :direction :output :if-exists :supersede)
      (write-string "go" s)))
  nil)

;;; ---------------------------------------------------------------------------
;;; The busy control, asserted first
;;; ---------------------------------------------------------------------------

(define-test a-busy-image-is-read-healthy-while-its-own-connection-is-occupied
  "An image part-way through a long legitimate evaluation is classified healthy
and explicitly not wedged.

This is the requirement the wedge plant must not contradict, so it is asserted
first. The probe opens its own connection precisely so that a session's real work
never makes its image look broken, and if this goes red that design does not hold
on this Slynk: a busy image would be indistinguishable from a stopped one and
attached mode would have no usable liveness at all.

The evaluation is asserted to be genuinely in flight at the moment the probe
answers, and asserted afterwards to have actually run and returned its value. A
control that idles is not a control, and this one would otherwise pass just as
well against an image doing nothing."
  (with-foreign-slynk-child-or-skip
    (let ((*mode* :attached))
      (with-stoppable-image (port pid)
        (let* ((path (release-path))
               (session (image-session "attach-busy-control" port))
               (tool (image-tool session))
               (in-flight t)
               (answer nil)
               (evaluator nil))
          (unwind-protect
               (progn
                 (setf evaluator
                       (bt:make-thread
                        (lambda ()
                          (setf answer (ignore-errors
                                         (dispatch-code tool (waiting-form path) :timeout 20)))
                          (setf in-flight nil))
                        :name "attach-busy-evaluator"))
                 (sleep 2)
                 (true in-flight "the occupying evaluation must be running to be a control")
                 (is equal "S" (process-run-state pid)
                     "and the image itself is running, not stopped")
                 (multiple-value-bind (classification round-trip)
                     (probe-image-liveness "127.0.0.1" port :timeout 0.5)
                   (true in-flight
                         "the occupying evaluation is still in flight now the probe has answered")
                   (is eq :healthy classification
                       "a busy image answers a probe on a connection nobody else is using")
                   (isnt eq :wedged classification
                         "and being busy is never being wedged")
                   (true (integerp round-trip) "with a round trip actually measured")))
            (release-the-waiting-form path)
            ;; Wait for the evaluation to come back on its own, bounded, and only
            ;; then join. join-thread here takes no timeout of its own, and a
            ;; join called with one signals rather than waiting: the error is
            ;; swallowed by the guard, the evaluation is read before it has
            ;; finished, and the control below reports a value that never
            ;; arrived. Measured, exactly that.
            (loop repeat 600 while in-flight do (sleep 0.1))
            (when evaluator (ignore-errors (bt:join-thread evaluator)))
            (ignore-errors (delete-file path)))
          (true (hash-table-p answer)
                "the occupying evaluation must have returned, or this control tests nothing")
          (when (hash-table-p answer)
            (false (gethash "isError" answer) "and returned without error")
            (true (search "RELEASED" (string-upcase (response-text answer)))
                  "carrying the value the evaluation actually produced")))))))

;;; ---------------------------------------------------------------------------
;;; The wedge plant, and the recovery it exists for
;;; ---------------------------------------------------------------------------

(define-test a-stopped-image-is-classified-wedged-and-the-reset-brings-it-back
  "An image stopped mid-life is classified wedged while its socket still answers,
reads healthy again once released, and its session is put back in touch by the
reset verb.

The socket control comes first and everything after it depends on it: a plain
TCP connect to a stopped process still completes out of the kernel's accept
backlog, so the socket is fine and the image is not, which is the whole reason
this classification exists. Without that assertion a wedged reading would be
indistinguishable from an image that had gone.

The classification is then shown moving in both directions, since one that
latches red is as useless as one that never goes red.

The recovery is asserted as it actually happens rather than as it might be
imagined. A failed call is fail-closed and empties the cached connection on its
way out, so by the time a caller has watched a call fail there is nothing left to
drop: the reset's contribution in that situation is that it opens a connection
eagerly, and the epoch correctly stays where it is because no call was
interrupted. A second reset, with a connection open, is what moves the epoch, and
both are checked here so neither claim rests on the other."
  (with-foreign-slynk-child-or-skip
    (let ((*mode* :attached))
      (with-stoppable-image (port pid)
        (let* ((session (image-session "attach-wedge-plant" port))
               (tool (image-tool session)))
          (true (process-command-line pid)
                "the child must be in the process table for any of this to mean anything")
          (let ((healthy (dispatch-code tool "(+ 1 2)")))
            (false (gethash "isError" healthy) "the same session calls cleanly first")
            (false (key-present-p healthy "error_type")
                   "and a healthy call carries no failure name at all"))
          (unwind-protect
               (progn
                 (sb-posix:kill pid +freeze-signal+)
                 (sleep 0.5)
                 (is equal "T" (process-run-state pid)
                     "the kernel reports the image stopped, which is the fault being planted")
                 ;; The control that gives every assertion below its meaning.
                 (true (socket-answers-p "127.0.0.1" port)
                       "a plain socket connect still completes against the stopped image")
                 (let ((started (get-internal-real-time)))
                   (multiple-value-bind (classification round-trip)
                       (probe-image-liveness "127.0.0.1" port :timeout 0.5)
                     (let ((elapsed (/ (- (get-internal-real-time) started)
                                       internal-time-units-per-second)))
                       (true (< elapsed 3)
                             "the probe comes back on its own bound rather than waiting on the image")
                       (is eq :wedged classification
                           "an image that accepts connections and answers nothing is wedged")
                       (true (integerp round-trip) "with the round trip recorded"))))
                 (let ((wedged (dispatch-code tool "(+ 1 2)" :timeout 2)))
                   (true (gethash "isError" wedged) "a call into a stopped image fails")
                   (is equal "backend_wedged" (gethash "error_type" wedged)
                       "and is named as the image having stopped answering")
                   (is eq :wedged (repl-eval-tool-liveness tool)
                       "with the session's recorded classification agreeing")
                   (true (integerp (repl-eval-tool-liveness-checked-at tool))
                         "and a time recorded, which is a reader's only guide to its age")))
            (ignore-errors (sb-posix:kill pid +release-signal+)))
          ;; Released. The classification has to come back on its own.
          (sleep 0.5)
          (is equal "S" (process-run-state pid) "the released image is running again")
          (is eq :healthy (probe-image-liveness "127.0.0.1" port :timeout 0.5)
              "and reads healthy again, so the classification moves in both directions")
          ;; Recovery through the verb.
          (false (repl-eval-tool-slynk-conn tool)
                 "the failed call already emptied the cached connection, which is why \
the reset has to open one rather than only drop one")
          (let* ((before (repl-eval-tool-connection-epoch tool))
                 (reopened (call-attach-reset session)))
            (false (gethash "isError" reopened) "the reset succeeds against the released image")
            (false (key-present-p reopened "error_type") "carrying no failure name")
            (true (repl-eval-tool-slynk-conn tool)
                  "and the session is back in touch with the image")
            (is = before (repl-eval-tool-connection-epoch tool)
                "with the epoch where it was, because no call was interrupted")
            (let ((recovered (dispatch-code tool "(+ 40 2)")))
              (false (gethash "isError" recovered) "the next call goes through")
              (false (key-present-p recovered "error_type") "with no failure name")
              (true (search "42" (response-text recovered))
                    "and the image answers with the value it computed"))
            (let* ((mid (repl-eval-tool-connection-epoch tool))
                   (reset (call-attach-reset session)))
              (false (gethash "isError" reset) "a reset with a connection open also succeeds")
              (true (gethash "reset" reset) "and reports that it dropped one")
              (is = (1+ mid) (repl-eval-tool-connection-epoch tool)
                  "advancing the epoch by exactly one")
              (is = (repl-eval-tool-connection-epoch tool) (gethash "epoch" reset)
                  "and reporting the value the session now holds")
              (let ((after (dispatch-code tool "(+ 40 2)")))
                (false (gethash "isError" after) "the call after the reset goes through")
                (false (key-present-p after "error_type") "with no failure name")))))))))
