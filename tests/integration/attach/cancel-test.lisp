;;;; tests/integration/attach/cancel-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Cross-process regression guard for the attached cooperative-abort path.
;;;;
;;;; cancel-attached-eval drives a two-phase Slynk interrupt — slime-interrupt
;;;; then an invoke-nth-restart-for-emacs rex — across the wire into the
;;;; developer's image. Both control sexps must READ cleanly on a foreign image
;;;; that has never loaded dsmr-mcp, or the connection drops with a
;;;; SLIME-NETWORK-ERROR (the recurring wire-serialization class). The in-process
;;;; slynk fixture structurally CANNOT catch that class: it shares this image's
;;;; package namespace and readtable, so a base-string or internal-package symbol
;;;; round-trips fine. Only a genuinely foreign SBCL exercises the real
;;;; read-back path, so these tests spawn one (CL + slynk + alexandria) and drive
;;;; the cancel path against it.
;;;;
;;;; Two behaviors are covered:
;;;;   - clean abort: a long eval is interrupted and unwinds within the grace
;;;;     window; cancel-attached-eval reports :aborted-clean and no orphan is
;;;;     recorded.
;;;;   - no-take: the eval does not report an abort within the grace window;
;;;;     cancel-attached-eval reports :orphaned, records a :mode :attached orphan,
;;;;     leaves the connection open, and — crucially — raises no
;;;;     slime-network-error (the wire-literal regression assertion).

(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/integration/attach/cancel-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/integration/attach/cancel-test
  (:use #:cl #:zebra)
  (:import-from #:dsmr-mcp/src/attach/cancel
                #:cancel-attached-eval
                #:*cancel-grace-seconds*)
  (:import-from #:dsmr-mcp/src/transport/dispatch-pool
                #:make-dispatch-promise
                #:fulfill-promise)
  (:import-from #:dsmr-mcp/src/orphan
                #:orphan-list
                #:orphan-count
                #:clear-orphan
                #:orphan-entry-request-id
                #:orphan-entry-mode)
  (:import-from #:slynk-client
                #:slime-connect
                #:slime-close
                #:slime-eval-async
                #:slime-network-error)
  (:import-from #:dsmr-mcp/tests/support/bounded-eval
                #:eval-in-image)
  (:import-from #:bordeaux-threads
                #:current-thread)
  (:import-from #:dsmr-mcp/tests/integration/support
                #:with-foreign-slynk-child-or-skip))

(in-package #:dsmr-mcp/tests/integration/attach/cancel-test)

;;; ---------------------------------------------------------------------------
;;; This test forks a foreign SBCL that quickloads slynk + alexandria, so it
;;; wraps its body in WITH-FOREIGN-SLYNK-CHILD-OR-SKIP: it runs only when a fresh
;;; child can actually quickload those systems, and skips cleanly otherwise (see
;;; tests/integration/support.lisp). Once that guard passes, an unreachable child
;;; (a lost port-rebind race, a dropped wire) is a genuine failure, not a skip —
;;; with-foreign-slynk-image surfaces it as an error with the child's log tail.
;;; ---------------------------------------------------------------------------

;;; ---------------------------------------------------------------------------
;;; Foreign-image launcher (copied verbatim from wire-cross-process-test.lisp)
;;; ---------------------------------------------------------------------------

(defun %free-tcp-port ()
  "Bind an OS-assigned loopback port, read it back, release it, return it.
There is a small race between releasing the socket and the child rebinding it.
The connect loop covers only the benign case where the child loses the rebind
race and retries (a transient EADDRINUSE just costs a retry); it does NOT cover
the case where an unrelated process grabs the just-released port first — then
the test connects to the wrong server, and the (is = 3 (slime-eval '(+ 1 2)))
sanity check is the only thing that catches the mismatch."
  (let ((listener (usocket:socket-listen "127.0.0.1" 0 :reuse-address t)))
    (unwind-protect (usocket:get-local-port listener)
      (usocket:socket-close listener))))

(defun %child-eval-forms (port)
  "Return the --eval program for the foreign image: load quicklisp if present,
quickload slynk + alexandria (alexandria gives a real library symbol with a
physical source file for code-find to locate), start a Slynk server on PORT,
then block so the image stays up until the parent terminates it.  Foreign
package symbols are reached via read-from-string so the forms never fail to
READ before their package exists."
  (list
   "--eval" "(require :asdf)"
   "--eval" (concatenate 'string
                         "(let ((q (merge-pathnames \"quicklisp/setup.lisp\""
                         " (user-homedir-pathname))))"
                         " (when (and (probe-file q) (not (find-package :ql)))"
                         " (load q)))")
   "--eval" "(funcall (read-from-string \"ql:quickload\") (list :slynk :alexandria) :silent t)"
   "--eval" (format nil "(funcall (read-from-string \"slynk:create-server\") :port ~D :dont-close t)"
                    port)
   "--eval" "(loop (sleep 3600))"))

(defmacro with-foreign-slynk-image ((conn-var) &body body)
  "Spawn a throwaway SBCL running only CL + slynk + alexandria, connect a
slynk-client to it, bind CONN-VAR, run BODY, then always tear down: close the
client connection, terminate the child, and reap it.

If the child cannot be reached, signals an error whose report includes the tail
of the child's captured output so an environment problem (no Quicklisp, slynk
unavailable) is diagnosable rather than a bare timeout."
  (let ((port    (gensym "PORT-"))
        (out      (gensym "OUT-"))
        (proc     (gensym "PROC-"))
        (conn-tmp (gensym "CONN-"))
        (tries    (gensym "TRIES-"))
        (i        (gensym "I-")))
    `(let* ((,port (%free-tcp-port))
            (,out  (uiop:tmpize-pathname
                    (merge-pathnames "dsmr-cancel-xproc.log"
                                     (uiop:temporary-directory))))
            (,proc (uiop:launch-program
                    (list* (uiop:native-namestring sb-ext:*runtime-pathname*)
                           "--noinform" "--disable-debugger"
                           (%child-eval-forms ,port))
                    :output ,out :error-output ,out))
            (,conn-tmp nil)
            (,tries 160))
       (unwind-protect
            (progn
              ;; Retry connect; bail early (with the child's log) if it died.
              (dotimes (,i ,tries)
                (when (and (uiop:process-alive-p ,proc)
                           (setf ,conn-tmp
                                 (ignore-errors (slime-connect "127.0.0.1" ,port))))
                  (return))
                (unless (uiop:process-alive-p ,proc)
                  (return))
                (sleep 0.25))
              (unless ,conn-tmp
                (error "with-foreign-slynk-image: could not reach foreign Slynk ~
on 127.0.0.1:~D after ~,1Fs (child alive: ~A).~%--- child output tail ---~%~A"
                       ,port (* ,tries 0.25)
                       (uiop:process-alive-p ,proc)
                       (ignore-errors
                        (let ((s (uiop:read-file-string ,out)))
                          (subseq s (max 0 (- (length s) 2000)))))))
              (let ((,conn-var ,conn-tmp))
                ,@body))
         (ignore-errors (when ,conn-tmp (slime-close ,conn-tmp)))
         (ignore-errors (uiop:terminate-process ,proc :urgent t))
         (ignore-errors (uiop:wait-process ,proc))
         (ignore-errors (delete-file ,out))))))

;;; ---------------------------------------------------------------------------
;;; Helpers
;;; ---------------------------------------------------------------------------

(defun %find-orphan (request-id)
  "Return the orphan-entry registered under REQUEST-ID, or NIL."
  (find request-id (orphan-list)
        :key #'orphan-entry-request-id :test #'equal))

;;; ---------------------------------------------------------------------------
;;; The regressions
;;; ---------------------------------------------------------------------------

(define-test cancel-attached-eval-aborts-cleanly
  "A long attached eval is interrupted and unwinds within the grace window:
cancel-attached-eval reports :aborted-clean and records no orphan."
  (with-foreign-slynk-child-or-skip
    (with-foreign-slynk-image (conn)
      ;; Sanity: the foreign image evaluates a trivial form (proves the link).
      (is = 3 (eval-in-image '(+ 1 2) conn
                             :label "clean-abort link probe"))
      (let ((promise (make-dispatch-promise
                      :request-id "cancel-clean-1"
                      :session-id "cancel-clean-session"
                      :mode :attached
                      :slynk-conn conn))
            (orphans-before (orphan-count)))
        ;; Launch the long eval; its continuation fulfills the promise with the
        ;; reply.  On a clean abort slime-eval-async fires the continuation with
        ;; (cons +abort+ condition) — exactly what cancel-attached-eval reads
        ;; back to report :aborted-clean.
        (slime-eval-async '(sleep 30) conn
                          (lambda (x) (fulfill-promise promise x)))
        ;; Let the eval reach the foreign image and start sleeping before the
        ;; interrupt is sent.
        (sleep 0.5)
        (let ((outcome (cancel-attached-eval promise)))
          (is eq :aborted-clean outcome
              "cancel-attached-eval did not report a clean abort")
          (is = orphans-before (orphan-count)
              "a clean abort must not register an orphan"))))))

(define-test cancel-attached-eval-orphans-on-no-take
  "When the interrupted eval does not report an abort within the grace window,
cancel-attached-eval reports :orphaned, records a :mode :attached orphan, leaves
the connection open, and raises no slime-network-error (wire-literal guard)."
  (with-foreign-slynk-child-or-skip
    (with-foreign-slynk-image (conn)
      (is = 3 (eval-in-image '(+ 1 2) conn
                             :label "orphan-path link probe"))
      (let* ((request-id "cancel-orphan-1")
             (promise (make-dispatch-promise
                       :request-id request-id
                       :session-id "cancel-orphan-session"
                       :mode :attached
                       :thread (current-thread)
                       :slynk-conn conn))
             (orphans-before (orphan-count))
             (network-error nil)
             (outcome nil))
        ;; Launch a long eval whose continuation deliberately does NOT fulfill
        ;; the promise: this models a no-take — the eval never reports an abort
        ;; back through this promise, so the grace window must expire and the
        ;; cancel path must fall through to orphan registration.  The control
        ;; sexps still cross the wire to the foreign image, so a reintroduced
        ;; wire-literal in the abort form would drop the connection here.
        (slime-eval-async '(sleep 30) conn
                          (lambda (x) (declare (ignore x)) nil))
        (sleep 0.5)
        (handler-case
            (let ((*cancel-grace-seconds* 1))
              (setf outcome (cancel-attached-eval promise)))
          (slime-network-error ()
            (setf network-error t)))
        (false network-error
               "cancel path raised slime-network-error (wire-literal regression)")
        (is eq :orphaned outcome
            "cancel-attached-eval did not report :orphaned on a no-take")
        (is = (1+ orphans-before) (orphan-count)
            "a no-take must register exactly one orphan")
        (let ((entry (%find-orphan request-id)))
          (true entry "no orphan registered for the cancelled request")
          (when entry
            (is eq :attached (orphan-entry-mode entry)
                "orphan was not recorded with :mode :attached")))
        ;; Hygiene: drop the orphan we registered so it does not leak into other
        ;; tests' registry-count assertions.
        (clear-orphan request-id)))))
