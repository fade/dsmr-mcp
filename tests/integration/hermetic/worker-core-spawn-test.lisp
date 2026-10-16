;;;; tests/integration/hermetic/worker-core-spawn-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Workers booted from the worker core, and the fall-back to loading from
;;;; source when the core is absent or will not boot.
;;;;
;;;; A worker from the core starts in a fraction of a second, which is what lets
;;;; the pool keep nothing warm: the last test here starts a pool with no
;;;; environment and checks that no worker exists until a session asks for one.
;;;;
;;;; Every test runs inside WITH-WORKER-CORE-OR-SKIP, which builds a core from
;;;; this tree once per run (or uses DSMR_TEST_WORKER_CORE) and skips only when
;;;; no core can be built. The fall-back tests spawn from source as well, so
;;;; they take tens of seconds each.

(defpackage #:dsmr-mcp/tests/integration/hermetic/worker-core-spawn-test
  (:use #:cl #:zebra)
  (:import-from #:dsmr-mcp/src/hermetic/worker-client
                #:spawn-worker #:kill-worker #:worker-rpc
                #:worker-id #:worker-pid
                #:worker-boot-kind #:worker-boot-milliseconds
                #:*worker-core* #:*worker-core-disabled*)
  (:import-from #:dsmr-mcp/src/hermetic/pool
                #:initialize-pool #:shutdown-pool
                #:get-or-assign-worker #:pool-status-info)
  (:import-from #:dsmr-mcp/src/state
                #:*mode*)
  (:import-from #:dsmr-mcp/src/log
                #:configure-log4cl-for-server)
  (:import-from #:dsmr-mcp/tests/integration/support
                #:with-worker-core-or-skip)
  (:import-from #:sb-posix)
  (:import-from #:uiop))

(in-package #:dsmr-mcp/tests/integration/hermetic/worker-core-spawn-test)

;;; ---------------------------------------------------------------------------
;;; Helpers
;;; ---------------------------------------------------------------------------

(defun %eval-text (worker code)
  "Send CODE to WORKER through worker/eval and return the text of the first
content block of the reply, or NIL when there is none."
  (let ((params (make-hash-table :test 'equal)))
    (setf (gethash "code" params) code)
    (let* ((resp (worker-rpc worker "worker/eval" params))
           (content (and (hash-table-p resp) (gethash "content" resp))))
      (when (and (vectorp content) (plusp (length content)))
        (gethash "text" (aref content 0))))))

(defmacro %with-env ((name value) &body body)
  "Evaluate BODY with environment variable NAME set to VALUE (or unset when
VALUE is NIL), restoring its previous state afterwards."
  (let ((old (gensym "OLD")) (n (gensym "NAME")) (v (gensym "VALUE")))
    `(let* ((,n ,name) (,v ,value) (,old (sb-posix:getenv ,n)))
       (unwind-protect
            (progn
              (if ,v (sb-posix:setenv ,n ,v 1) (sb-posix:unsetenv ,n))
              ,@body)
         (if ,old (sb-posix:setenv ,n ,old 1) (sb-posix:unsetenv ,n))))))

(defmacro %with-quiet-log (&body body)
  "Evaluate BODY with log output captured instead of printed."
  `(let ((*error-output* (make-string-output-stream)))
     (configure-log4cl-for-server :warn)
     ,@body))

(defmacro %with-spawned ((var form) &body body)
  "Bind VAR to the worker FORM returns and evaluate BODY, killing the worker
afterwards whatever happens."
  `(let ((,var nil))
     (unwind-protect
          (progn (setf ,var ,form) ,@body)
       (when ,var (ignore-errors (kill-worker ,var))))))

;;; ---------------------------------------------------------------------------
;;; Booting from the core
;;; ---------------------------------------------------------------------------

(define-test a-worker-boots-from-the-core-and-evaluates
  "A worker spawned with a core boots from it and answers an eval."
  (with-worker-core-or-skip (core)
    (%with-quiet-log
      (let ((*worker-core-disabled* nil))
        (%with-spawned (w (spawn-worker :core core))
          (format t "~&core boot, first spawn: ~D ms~%" (worker-boot-milliseconds w))
          (is eq :core (worker-boot-kind w))
          (true (search "42" (or (%eval-text w "(+ 40 2)") ""))))))))

(define-test a-warm-core-boot-takes-under-a-second
  "Once the page cache holds the core, a worker reaches its handshake and
authenticates in under a second."
  (with-worker-core-or-skip (core)
    (%with-quiet-log
      (let ((*worker-core-disabled* nil))
        (%with-spawned (warm (spawn-worker :core core))
          (is eq :core (worker-boot-kind warm)))
        (%with-spawned (w (spawn-worker :core core))
          (format t "~&core boot, warm spawn: ~D ms~%" (worker-boot-milliseconds w))
          (is eq :core (worker-boot-kind w))
          (true (integerp (worker-boot-milliseconds w)))
          (true (< (worker-boot-milliseconds w) 1000)))))))

(define-test a-core-booted-worker-reads-its-own-eval-timeout
  "The core is built with DSMR_WORKER_EVAL_TIMEOUT=7; a worker booted from it
with the variable set to 11 answers 11, so the setting is read when the worker
starts and not frozen into the image."
  (with-worker-core-or-skip (core)
    (%with-quiet-log
      (let ((*worker-core-disabled* nil))
        (%with-env ("DSMR_WORKER_EVAL_TIMEOUT" "11")
          (%with-spawned (w (spawn-worker :core core))
            (is eq :core (worker-boot-kind w))
            (let ((text (%eval-text
                         w (concatenate
                            'string
                            "(format nil \"eval-timeout=~D\" "
                            "(dsmr-mcp/src/hermetic/worker/handlers:effective-eval-timeout))"))))
              (true (search "eval-timeout=11\"" (or text "")) "~A" text))))))))

(define-test a-core-booted-worker-finds-workspace-and-quicklisp-systems
  "A worker from the core can still find a Quicklisp system and the project
system itself."
  (with-worker-core-or-skip (core)
    (%with-quiet-log
      (let ((*worker-core-disabled* nil))
        (%with-spawned (w (spawn-worker :core core))
          (is eq :core (worker-boot-kind w))
          (let ((text (%eval-text
                       w (concatenate
                          'string
                          "(format nil \"systems-found=~A\" "
                          "(and (asdf:find-system \"alexandria\" nil) "
                          "(asdf:find-system \"dsmr-mcp\" nil) t))"))))
            (true (search "systems-found=T" (or text "")) "~A" text)))))))

;;; ---------------------------------------------------------------------------
;;; Falling back to source
;;; ---------------------------------------------------------------------------

(define-test a-missing-core-falls-back-to-source
  "A core path naming no file yields a working worker loaded from source, and
no condition escapes."
  (with-worker-core-or-skip (core)
    (%with-quiet-log
      (let ((*worker-core-disabled* nil))
        (%with-spawned (w (spawn-worker :core "/nonexistent/dsmr.core.worker"))
          (is eq :source (worker-boot-kind w))
          (true (search "42" (or (%eval-text w "(+ 40 2)") ""))))))))

(define-test a-core-that-will-not-boot-is-dropped-for-the-process
  "A core that fails to boot (here 4 KB of zero bytes) yields a working worker
loaded from source, records why the core was dropped, and later default spawns
go straight to source even with a good core configured."
  (with-worker-core-or-skip (core)
    (%with-quiet-log
      (let* ((*worker-core-disabled* nil)
             (dir (uiop:ensure-directory-pathname
                   (string-trim '(#\Newline)
                                (uiop:run-program '("mktemp" "-d") :output :string))))
             (bad (namestring (merge-pathnames "zero.core" dir))))
        (unwind-protect
             (progn
               (with-open-file (s bad :direction :output
                                      :element-type '(unsigned-byte 8)
                                      :if-exists :supersede)
                 (write-sequence (make-array 4096 :element-type '(unsigned-byte 8)
                                                  :initial-element 0)
                                 s))
               (%with-spawned (w (spawn-worker :core bad))
                 (is eq :source (worker-boot-kind w))
                 (true (search "42" (or (%eval-text w "(+ 40 2)") ""))))
               (true (stringp *worker-core-disabled*))
               (true (plusp (length (or *worker-core-disabled* ""))))
               (let ((*worker-core* core))
                 (%with-spawned (w (spawn-worker))
                   (is eq :source (worker-boot-kind w)))))
          (ignore-errors (uiop:delete-directory-tree dir :validate t)))))))

;;; ---------------------------------------------------------------------------
;;; No standby: workers exist only for sessions that asked
;;; ---------------------------------------------------------------------------

(define-test a-pool-with-no-environment-keeps-no-worker-warm
  "A pool started with no warmup setting holds no worker. Each session's first
request spawns exactly one worker bound to it, a second session gets its own,
and the first session keeps the worker it was given."
  (with-worker-core-or-skip (core)
    (%with-quiet-log
      (let ((*mode* :hermetic)
            (*worker-core* nil)
            (*worker-core-disabled* nil)
            (dsmr-mcp/src/hermetic/pool:*worker-pool-warmup* nil)
            (dsmr-mcp/src/hermetic/pool:*max-pool-size* 4))
        (%with-env ("DSMR_WORKER_POOL_WARMUP" nil)
          (%with-env ("DSMR_WORKER_CORE" core)
            (initialize-pool)
            (unwind-protect
                 (progn
                   (sleep 2)
                   (let ((info (pool-status-info)))
                     (is = 0 (gethash "standby_count" info))
                     (is = 0 (gethash "total_workers" info)))
                   (let ((a (get-or-assign-worker "no-standby-session-a")))
                     (is = 1 (gethash "total_workers" (pool-status-info)))
                     (is eq :core (worker-boot-kind a))
                     (let ((b (get-or-assign-worker "no-standby-session-b")))
                       (is = 2 (gethash "total_workers" (pool-status-info)))
                       (true (/= (worker-id a) (worker-id b)))
                       (let ((a-again (get-or-assign-worker "no-standby-session-a")))
                         (is eq a a-again)
                         (is = 2 (gethash "total_workers" (pool-status-info)))))))
              (ignore-errors (shutdown-pool)))))))))
