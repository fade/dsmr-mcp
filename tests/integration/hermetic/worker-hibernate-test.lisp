;;;; tests/integration/hermetic/worker-hibernate-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; A worker saving its world to a core and a new process resuming it, proven
;;;; across real processes without the pool.
;;;;
;;;; The first test builds up the kinds of state a session accumulates (a
;;;; function, a list, a structure, a closure with its counter, a package, a
;;;; large table, a random state, a registry entry and an inspectable object),
;;;; saves the worker, resumes it in a new process and reads every one back.
;;;; The others check that a stale socket carried in the saved world cannot
;;;; touch what the new process opens, and that every refusal (a thread the
;;;; session started, a save that fails, a path the worker may not write) leaves
;;;; the worker serving.
;;;;
;;;; Every test runs inside WITH-WORKER-CORE-OR-SKIP and gives the workers a
;;;; private XDG_STATE_HOME, so saved cores land in a temporary directory that
;;;; is removed afterwards.

(defpackage #:dsmr-mcp/tests/integration/hermetic/worker-hibernate-test
  (:use #:cl #:zebra)
  (:import-from #:dsmr-mcp/src/hermetic/worker-client
                #:spawn-worker #:kill-worker #:worker-rpc
                #:worker-id #:worker-pid #:worker-boot-kind
                #:worker-boot-milliseconds
                #:worker-stream #:worker-stream-lock #:worker-process-info
                #:worker-rpc-error #:worker-rpc-error-message
                #:*worker-core-disabled*
                #:worker-request-counter
                #:%send-json-rpc #:%read-json-rpc-response)
  (:import-from #:dsmr-mcp/src/hermetic/worker/hibernate
                #:hibernate-directory)
  (:import-from #:dsmr-mcp/src/log
                #:configure-log4cl-for-server)
  (:import-from #:dsmr-mcp/tests/integration/support
                #:with-worker-core-or-skip)
  (:import-from #:bordeaux-threads #:with-lock-held)
  (:import-from #:sb-posix)
  (:import-from #:uiop))

(in-package #:dsmr-mcp/tests/integration/hermetic/worker-hibernate-test)

;;; ---------------------------------------------------------------------------
;;; Helpers
;;; ---------------------------------------------------------------------------

(defmacro %with-quiet-log (&body body)
  "Evaluate BODY with log output captured instead of printed."
  `(let ((*error-output* (make-string-output-stream)))
     (configure-log4cl-for-server :warn)
     ,@body))

(defun %make-temp-directory ()
  "Create a fresh private temporary directory and return its pathname."
  (uiop:ensure-directory-pathname
   (string-trim '(#\Newline #\Return #\Space)
                (uiop:run-program '("mktemp" "-d" "-t" "dsmr-hibernate.XXXXXX")
                                  :output :string))))

(defun %private-directory (dir)
  "Create DIR and every missing parent, then set DIR to mode 0700."
  (ensure-directories-exist dir)
  (sb-posix:chmod (uiop:native-namestring dir) #o700)
  dir)

(defmacro %with-hibernate-home ((owner-var) &body body)
  "Evaluate BODY with XDG_STATE_HOME pointing at a new temporary directory and
OWNER-VAR bound to a mode 0700 directory under the hibernate directory there.
Workers spawned inside inherit the setting. The variable is restored and the
directory removed afterwards."
  (let ((home (gensym "HOME")) (old (gensym "OLD")))
    `(let* ((,home (%make-temp-directory))
            (,old (sb-posix:getenv "XDG_STATE_HOME")))
       (unwind-protect
            (progn
              (sb-posix:setenv "XDG_STATE_HOME" (uiop:native-namestring ,home) 1)
              (let ((,owner-var (%private-directory
                                 (merge-pathnames "test-owner/" (hibernate-directory)))))
                ,@body))
         (if ,old
             (sb-posix:setenv "XDG_STATE_HOME" ,old 1)
             (sb-posix:unsetenv "XDG_STATE_HOME"))
         (ignore-errors (uiop:delete-directory-tree ,home :validate t))))))

(defmacro %with-workers ((&rest vars) &body body)
  "Bind each of VARS to NIL and evaluate BODY, killing every worker the
variables hold afterwards whatever happens."
  `(let ,(mapcar (lambda (v) (list v nil)) vars)
     (unwind-protect (progn ,@body)
       ,@(mapcar (lambda (v) `(when ,v (ignore-errors (kill-worker ,v)))) vars))))

(defun %eval (worker code)
  "Send CODE to WORKER through worker/eval and return the reply table."
  (let ((params (make-hash-table :test 'equal)))
    (setf (gethash "code" params) code)
    (worker-rpc worker "worker/eval" params)))

(defun %eval-text (worker code)
  "The text of the first content block of the reply to CODE, or \"\"."
  (let* ((resp (%eval worker code))
         (content (and (hash-table-p resp) (gethash "content" resp))))
    (or (and (vectorp content) (plusp (length content))
             (gethash "text" (aref content 0)))
        "")))

(defun %answer-p (worker form expected)
  "True when FORM, evaluated in WORKER and printed with ~A, prints EXPECTED.
The form is wrapped so the reply carries a marker string, which makes the
match exact rather than a substring of something larger."
  (let ((text (%eval-text worker (format nil "(format nil \"answer=~~A\" ~A)" form))))
    (values (search (format nil "answer=~A\"" expected) text) text)))

(defun %hibernate (worker path)
  "Ask WORKER to save itself to PATH. Returns (values RESULT NIL) on success or
(values NIL MESSAGE) when the worker refused.

The request goes straight onto the worker's stream under its lock rather than
through worker-rpc, because a successful save ends the connection after the
reply, and worker-rpc would read that end of file as a crash."
  (with-lock-held ((worker-stream-lock worker))
    (let ((id (incf (worker-request-counter worker)))
          (params (make-hash-table :test 'equal)))
      (setf (gethash "path" params) path
            (gethash "deadline_seconds" params) 170)
      (%send-json-rpc (worker-stream worker) id "worker/hibernate" params)
      (handler-case
          (values (%read-json-rpc-response (worker-stream worker) id 200) nil)
        (worker-rpc-error (e)
          (values nil (worker-rpc-error-message e)))))))

(defun %refusal-token (message)
  "The reason token at the front of a refusal MESSAGE, after the server's
\"Internal error: \" prefix, or NIL."
  (when (stringp message)
    (let* ((prefix "Internal error: ")
           (body (if (and (>= (length message) (length prefix))
                          (string= prefix message :end2 (length prefix)))
                     (subseq message (length prefix))
                     message))
           (colon (position #\: body)))
      (and colon (subseq body 0 colon)))))

(defun %exits-within (worker seconds)
  "True when WORKER's process has exited within SECONDS."
  (let ((process (worker-process-info worker)))
    (loop repeat (* 10 seconds)
          unless (sb-ext:process-alive-p process) do (return t)
          do (sleep 0.1)
          finally (return (not (sb-ext:process-alive-p process))))))

(defun %mode (path)
  "Permission bits of PATH."
  (logand #o777 (sb-posix:stat-mode (sb-posix:stat (uiop:native-namestring path)))))

(defun %core-path (owner worker)
  "Native path of WORKER's core in the OWNER directory."
  (uiop:native-namestring
   (merge-pathnames (format nil "~D.core" (worker-id worker)) owner)))

(defun %thread-names-text (worker)
  "The printed list of thread names in WORKER."
  (%eval-text worker
              "(mapcar (function sb-thread:thread-name) (sb-thread:list-all-threads))"))

;;; ---------------------------------------------------------------------------
;;; The world survives
;;; ---------------------------------------------------------------------------

(define-test a-worker-world-survives-hibernate-and-resume
  "Everything a session builds in a worker comes back in the process resumed
from its saved core, and the resumed worker serves with a new pid, a new
secret and a running parent watchdog."
  (with-worker-core-or-skip (core)
    (%with-quiet-log
      (%with-hibernate-home (owner)
        (let ((*worker-core-disabled* nil)
              (registry-dir (uiop:native-namestring
                             (%private-directory (merge-pathnames "registry-entry/" owner)))))
          (%with-workers (w r)
            (setf w (spawn-worker :core core))
            (is eq :core (worker-boot-kind w))
            (%eval w "(defun hib-square (x) (* x x))")
            (%eval w "(defvar *hib-list* (list 1 2 3 \"four\" :five))")
            (%eval w "(defstruct hib-point x y)")
            (%eval w "(defvar *hib-pt* (make-hib-point :x 7 :y 8))")
            (%eval w "(defvar *hib-counter* (let ((n 0)) (lambda () (incf n))))")
            (%eval w "(funcall *hib-counter*)")
            (%eval w "(funcall *hib-counter*)")
            (%eval w "(defpackage :hib-user-pkg (:use :cl))")
            (%eval w "(intern \"HIB-SYM\" :hib-user-pkg)")
            (%eval w "(defvar *hib-table* (let ((h (make-hash-table))) (dotimes (i 10000 h) (setf (gethash i h) (* i i)))))")
            (%eval w "(defvar *rs* (make-random-state t))")
            (%eval w "(defvar *expected* (random 1000000 (make-random-state *rs*)))")
            (%eval w (format nil "(push (pathname ~S) asdf:*central-registry*)" registry-dir))
            (let* ((object-reply (%eval w "(list :hib-object 42)"))
                   (object-id (gethash "result_object_id" object-reply))
                   (path (%core-path owner w))
                   (old-pid (worker-pid w)))
              (true (integerp object-id) "object id ~S" object-id)
              (multiple-value-bind (result refusal) (%hibernate w path)
                (false refusal "refused: ~A" refusal)
                (true (and result (eq t (gethash "hibernated" result))))
                (true (and result (integerp (gethash "bytes" result))
                           (plusp (gethash "bytes" result))))
                (format t "~&hibernate: ~A ms, ~A bytes~%"
                        (and result (gethash "milliseconds" result))
                        (and result (gethash "bytes" result))))
              (true (%exits-within w 5) "the saving worker exited")
              (true (probe-file path))
              (is = #o600 (%mode path))
              (is = #o700 (%mode owner))
              (false (probe-file (concatenate 'string path ".tmp")))
              (setf r (spawn-worker :hibernated-core path :id (worker-id w)))
              (format t "~&resume: ~A ms to an authenticated connection~%"
                      (worker-boot-milliseconds r))
              (is eq :resumed (worker-boot-kind r))
              (is = (worker-id w) (worker-id r))
              (true (/= old-pid (worker-pid r)))
              (true (%answer-p r "(hib-square 12)" "144"))
              (true (%answer-p r "(equal *hib-list* (list 1 2 3 \"four\" :five))" "T"))
              (true (%answer-p r "(hib-point-y *hib-pt*)" "8"))
              (true (%answer-p r "(funcall *hib-counter*)" "3"))
              (true (%answer-p r "(and (find-symbol \"HIB-SYM\" :hib-user-pkg) t)" "T"))
              (true (%answer-p r "(hash-table-count *hib-table*)" "10000"))
              (true (%answer-p r "(gethash 9999 *hib-table*)" "99980001"))
              (true (%answer-p r "(= (random 1000000 *rs*) *expected*)" "T"))
              (true (%answer-p r (format nil "(and (member (pathname ~S) asdf:*central-registry* :test (function equal)) t)"
                                         registry-dir)
                               "T"))
              (let ((params (make-hash-table :test 'equal)))
                (setf (gethash "id" params) object-id)
                (true (hash-table-p (worker-rpc r "worker/inspect-object" params))))
              (true (search "\"parent-watchdog\"" (%thread-names-text r))))))))))

;;; ---------------------------------------------------------------------------
;;; Stale descriptors
;;; ---------------------------------------------------------------------------

(define-test a-stale-socket-cannot-touch-a-file-opened-after-resume
  "A socket and a file stream held in the saved world come back with their old
descriptor numbers covered by /dev/null: the socket's number reads as
/dev/null, and closing the stale socket and stream leaves a file the resumed
process opened readable."
  (with-worker-core-or-skip (core)
    (%with-quiet-log
      (%with-hibernate-home (owner)
        (let* ((*worker-core-disabled* nil)
               (file-a (uiop:native-namestring (merge-pathnames "a.txt" owner)))
               (file-b (uiop:native-namestring (merge-pathnames "b.txt" owner))))
          (with-open-file (s file-a :direction :output :if-exists :supersede)
            (write-string "stale" s))
          (%with-workers (w r)
            (setf w (spawn-worker :core core))
            (%eval w "(defvar *sock* (usocket:socket-listen \"127.0.0.1\" 0))")
            (%eval w (format nil "(defvar *stream-a* (open ~S))" file-a))
            (%eval w "(defvar *sock-fd* (sb-bsd-sockets:socket-file-descriptor (usocket:socket *sock*)))")
            (let ((path (%core-path owner w)))
              (multiple-value-bind (result refusal) (%hibernate w path)
                (declare (ignore result))
                (false refusal "refused: ~A" refusal))
              (true (%exits-within w 5))
              (setf r (spawn-worker :hibernated-core path :id (worker-id w)))
              (true (%answer-p r "(sb-posix:readlink (format nil \"/proc/self/fd/~D\" *sock-fd*))"
                               "/dev/null"))
              (true (%answer-p
                     r
                     (format nil "(progn (with-open-file (o ~S :direction :output :if-exists :supersede) (write-string \"ok\" o)) (with-open-file (in ~S) (ignore-errors (usocket:socket-close *sock*)) (ignore-errors (close *stream-a*)) (read-line in)))"
                             file-b file-b)
                     "ok")))))))))

;;; ---------------------------------------------------------------------------
;;; Refusals leave the worker serving
;;; ---------------------------------------------------------------------------

(define-test a-worker-with-a-session-thread-refuses-and-keeps-serving
  "A worker running a thread the session started refuses to save with
has-threads, writes no core, and still answers."
  (with-worker-core-or-skip (core)
    (%with-quiet-log
      (%with-hibernate-home (owner)
        (let ((*worker-core-disabled* nil))
          (%with-workers (w)
            (setf w (spawn-worker :core core))
            (%eval w "(sb-thread:make-thread (lambda () (sleep 600)) :name \"user-sleeper\")")
            (let ((path (%core-path owner w)))
              (multiple-value-bind (result refusal) (%hibernate w path)
                (false result)
                (is equal "has-threads" (%refusal-token refusal) "~A" refusal))
              (true (%answer-p w "(+ 1 2)" "3"))
              (false (probe-file path)))))))))

(define-test a-failed-save-leaves-the-worker-serving
  "When the save cannot write its scratch file (here a directory stands in its
place), the worker reports save-failed, installs nothing, keeps its parent
watchdog and still answers."
  (with-worker-core-or-skip (core)
    (%with-quiet-log
      (%with-hibernate-home (owner)
        (let ((*worker-core-disabled* nil))
          (%with-workers (w)
            (setf w (spawn-worker :core core))
            (let ((path (%core-path owner w)))
              (ensure-directories-exist (concatenate 'string path ".tmp/"))
              (multiple-value-bind (result refusal) (%hibernate w path)
                (false result)
                (is equal "save-failed" (%refusal-token refusal) "~A" refusal))
              (true (%answer-p w "(+ 1 2)" "3"))
              (false (probe-file path))
              (true (search "\"parent-watchdog\"" (%thread-names-text w))))))))))

(define-test a-path-the-worker-may-not-write-is-refused
  "A path outside the hibernate directory, and a path through a hibernate
directory that has been replaced by a symlink, are both refused with bad-path,
and the worker still answers."
  (with-worker-core-or-skip (core)
    (%with-quiet-log
      (%with-hibernate-home (owner)
        (let ((*worker-core-disabled* nil))
          (%with-workers (w)
            (setf w (spawn-worker :core core))
            (let ((outside (format nil "/tmp/dsmr-hibernate-outside-~D.core" (worker-pid w))))
              (multiple-value-bind (result refusal) (%hibernate w outside)
                (false result)
                (is equal "bad-path" (%refusal-token refusal) "~A" refusal))
              (false (probe-file outside)))
            (true (%answer-p w "(+ 1 2)" "3"))
            (let* ((root (string-right-trim "/" (uiop:native-namestring (hibernate-directory))))
                   (moved (concatenate 'string root "-real"))
                   (path (%core-path owner w)))
              (sb-posix:rename root moved)
              (sb-posix:symlink moved root)
              (multiple-value-bind (result refusal) (%hibernate w path)
                (false result)
                (is equal "bad-path" (%refusal-token refusal) "~A" refusal))
              (false (probe-file (concatenate 'string moved "/test-owner/"
                                              (format nil "~D.core" (worker-id w)))))
              (true (%answer-p w "(+ 1 2)" "3")))))))))
