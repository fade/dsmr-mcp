;;;; tests/hermetic/pool-records-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Zebra tests for the files the session pools and the host service share:
;;;; the private directories hibernated cores are written under, the worker
;;;; records a pool publishes, the hibernate requests the service leaves, the
;;;; sweep that clears what a dead server left behind, and the free-disk and
;;;; memory readings the pressure path decides with.
;;;;
;;;; Every test runs under its own temporary state home, set in the environment
;;;; and restored afterwards, and removes every tree it made, so nothing here
;;;; touches a live server's files.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/hermetic/pool-records-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/hermetic/pool-records-test
  (:use #:cl #:zebra)
  (:local-nicknames (#:records #:dsmr-mcp/src/hermetic/pool-records)
                    (#:hostfiles #:dsmr-mcp/src/bus/hostfiles)
                    (#:hibernate #:dsmr-mcp/src/hermetic/worker/hibernate)))

(in-package #:dsmr-mcp/tests/hermetic/pool-records-test)

;;; ------------------------------------------------------------------ fixtures

(defun make-temp-dir (prefix)
  "A new empty directory under the system temp directory, named from a freshly
   seeded random state so two runs never collide on a name."
  (let ((*random-state* (make-random-state t)))
    (loop
      (let ((dir (uiop:ensure-directory-pathname
                  (merge-pathnames
                   (format nil "~A-~8,'0X" prefix (random #xFFFFFFFF))
                   (uiop:temporary-directory)))))
        (unless (probe-file dir)
          (ensure-directories-exist dir)
          (return dir))))))

(defun delete-tree (dir)
  "Remove DIR and everything under it, never following a symbolic link out of
   it."
  (ignore-errors
   (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore)))

(defmacro with-temp-dir ((var prefix) &body body)
  "Bind VAR to a fresh temporary directory, deleted with its contents after."
  `(let ((,var (make-temp-dir ,prefix)))
     (declare (ignorable ,var))
     (unwind-protect (progn ,@body)
       (delete-tree ,var))))

(defmacro with-state-home ((var) &body body)
  "Run BODY with XDG_STATE_HOME pointing at a fresh temporary directory bound to
   VAR, restoring the previous value and deleting the directory after."
  (let ((previous (gensym "PREVIOUS")))
    `(with-temp-dir (,var "dsmr-pool-records")
       (let ((,previous (uiop:getenv "XDG_STATE_HOME")))
         (unwind-protect
              (progn
                (sb-posix:setenv "XDG_STATE_HOME" (uiop:native-namestring ,var) 1)
                ,@body)
           (if ,previous
               (sb-posix:setenv "XDG_STATE_HOME" ,previous 1)
               (ignore-errors (sb-posix:unsetenv "XDG_STATE_HOME"))))))))

(defun native-no-slash (path)
  "PATH as a native namestring without a trailing slash, so lstat and symlink
   see the entry itself rather than what it points at."
  (string-right-trim "/" (uiop:native-namestring path)))

(defun mode-bits (path)
  "The permission bits of PATH."
  (logand #o777 (sb-posix:stat-mode (sb-posix:stat (native-no-slash path)))))

(defun entry-exists-p (path)
  "True when something, even a dangling link, is at PATH."
  (handler-case (progn (sb-posix:lstat (native-no-slash path)) t)
    (sb-posix:syscall-error () nil)))

(defun write-text (path text)
  "Replace PATH with TEXT."
  (ensure-directories-exist path)
  (with-open-file (out path :direction :output :if-exists :supersede
                            :if-does-not-exist :create)
    (write-string text out))
  path)

(defun own-stem ()
  "The stem naming this test process: its pid and its start time."
  (format nil "~D-~D" (sb-posix:getpid)
          (hostfiles:proc-starttime (sb-posix:getpid))))

(defun stale-stem ()
  "A stem with this process's pid and a start time it did not start at, as a
   server that died and had its pid handed on would leave."
  (format nil "~D-~D" (sb-posix:getpid)
          (1+ (hostfiles:proc-starttime (sb-posix:getpid)))))

(defun recorder ()
  "A report function and a reader for what it was given. Each record is the
   list (level code subject msg)."
  (let ((records '()))
    (values (lambda (level code &key subject msg)
              (push (list level code subject msg) records))
            (lambda () (reverse records)))))

(defun df-available-bytes (dir)
  "The free space at DIR as `df` reports it to an unprivileged user, or NIL when
   `df` cannot be run here."
  (ignore-errors
   (let* ((text (uiop:run-program (list "df" "--output=avail" "-B1"
                                        (uiop:native-namestring dir))
                                  :output :string))
          (lines (remove "" (uiop:split-string text :separator (string #\Newline))
                         :test #'string=)))
     (parse-integer (string-trim " " (car (last lines)))))))

;;; ------------------------------------------------------------------- layout

(define-test the-hibernate-root-is-where-workers-save
  "The pool and the worker must name one directory for hibernated cores, or a
   world is saved where the pool never looks."
  (with-state-home (home)
    (is string= (uiop:native-namestring (merge-pathnames "dsmr-mcp/hibernate/" home))
        (uiop:native-namestring (records:hibernate-root)))
    (is string= (uiop:native-namestring (hibernate:hibernate-directory))
        (uiop:native-namestring (records:hibernate-root)))))

(define-test a-server-stem-is-pid-and-start-time
  "A stem names one process, not one pid, and reads back to the same pair."
  (let ((stem (records:server-stem)))
    (is string= (own-stem) stem)
    (multiple-value-bind (pid start) (records:parse-server-stem stem)
      (is eql (sb-posix:getpid) pid)
      (is eql (hostfiles:proc-starttime (sb-posix:getpid)) start)))
  (is eq nil (records:server-stem 999999999)))

(define-test a-malformed-stem-is-not-a-stem
  "Anything but digits, one hyphen and digits is refused, so no stem can reach
   outside the directory it names a file in."
  (dolist (bad '("12" "a-1" "1-2-3" "../1-2" "1-2/" "" "-1" "1-" "0-5" "1 -2"))
    (is eq nil (records:parse-server-stem bad))))

(define-test the-owner-directory-is-private-on-every-call
  "Every level a hibernated core sits under is created owner-only, and a level
   left looser by an earlier umask is tightened again."
  (with-state-home (home)
    (let* ((stem (own-stem))
           (dir (records:ensure-owner-directory stem)))
      (true (probe-file dir))
      (is string= (uiop:native-namestring (records:owner-directory stem))
          (uiop:native-namestring dir))
      (is = #o700 (mode-bits (records:hibernate-root)))
      (is = #o700 (mode-bits dir))
      (sb-posix:chmod (native-no-slash (records:hibernate-root)) #o755)
      (sb-posix:chmod (native-no-slash dir) #o755)
      (records:ensure-owner-directory stem)
      (is = #o700 (mode-bits (records:hibernate-root)))
      (is = #o700 (mode-bits dir)))))

(define-test a-symlinked-hibernate-root-is-refused
  "A link in place of the hibernate root would let a write land wherever the
   link points, so it is refused rather than followed."
  (with-state-home (home)
    (with-temp-dir (elsewhere "dsmr-pool-records-elsewhere")
      (ensure-directories-exist (merge-pathnames "dsmr-mcp/" home))
      (sb-posix:symlink (native-no-slash elsewhere)
                        (native-no-slash (records:hibernate-root)))
      (fail (records:ensure-owner-directory (own-stem))
          records:unsafe-hibernate-path)
      (is eq nil (uiop:directory-files elsewhere))
      (is eq nil (uiop:subdirectories elsewhere)))))

(define-test a-symlinked-owner-directory-is-refused
  "The same holds one level down, at the server's own directory."
  (with-state-home (home)
    (with-temp-dir (elsewhere "dsmr-pool-records-elsewhere")
      (let ((stem (own-stem)))
        (records:ensure-owner-directory stem)
        (records:remove-owner-directory stem)
        (sb-posix:symlink (native-no-slash elsewhere)
                          (native-no-slash (records:owner-directory stem)))
        (fail (records:ensure-owner-directory stem)
            records:unsafe-hibernate-path)))))

(define-test a-core-path-takes-a-positive-integer-id
  "The core path is computed from the pool's own stem and a worker id that has
   been checked, so nothing read from a file can choose where a world lands."
  (with-state-home (home)
    (let ((path (uiop:native-namestring (records:hibernated-core-path (own-stem) 7))))
      (true (uiop:string-suffix-p path "/7.core"))
      (true (uiop:string-prefix-p
             (uiop:native-namestring (records:owner-directory (own-stem))) path)))
    (dolist (bad (list 0 -1 "7" 7.5))
      (fail (records:hibernated-core-path (own-stem) bad)))
    (fail (records:hibernated-core-path "../1-2" 7))))

;;; ------------------------------------------------------------------ records

(define-test a-worker-record-reads-back-as-written
  "What a pool publishes is what the service reads, kept owner-only."
  (with-state-home (home)
    (let* ((stem (own-stem))
           (plist (list :server-pid (sb-posix:getpid)
                        :server-start (hostfiles:proc-starttime (sb-posix:getpid))
                        :written-at 1000 :service-seen nil
                        :workers (list (list :id 1 :pid 4242 :state :bound
                                             :session "s-1" :stateful t :busy nil
                                             :spawned-at 900 :last-activity 990
                                             :refused-reason nil :refused-at nil
                                             :core-bytes nil))
                        :last-action nil)))
      (records:write-worker-record stem plist)
      (let ((path (records:worker-record-path stem)))
        (multiple-value-bind (read status) (records:read-worker-record path)
          (is eq :ok status)
          (is equal plist read))
        (is = #o600 (mode-bits path))
        (is = #o700 (mode-bits (records:workers-record-dir)))
        (is = #o700 (mode-bits (records:hibernate-request-dir)))
        (is equal (list stem) (records:worker-record-stems))
        (true (records:remove-worker-record stem))
        (false (records:remove-worker-record stem))
        (is eq nil (records:worker-record-stems))))))

(define-test an-oversized-worker-record-is-unreadable
  "A record past the size cap is refused rather than read."
  (with-state-home (home)
    (let ((stem (own-stem)))
      (records:write-worker-record
       stem (list :server-pid 1 :padding (make-string 70000 :initial-element #\x)))
      (is eq :unreadable
          (nth-value 1 (records:read-worker-record (records:worker-record-path stem)))))))

;;; ----------------------------------------------------------------- requests

(define-test a-hibernate-request-reads-back-as-written
  "A request names a server, a worker and an action, and nothing else."
  (with-state-home (home)
    (let ((stem (own-stem)))
      (records:write-hibernate-request stem 3 :hibernate :now 1234 :reason "pressure")
      (multiple-value-bind (plist reason)
          (records:read-hibernate-request (records:request-path stem 3))
        (is eq nil reason)
        (is eql (sb-posix:getpid) (getf plist :server-pid))
        (is eql (hostfiles:proc-starttime (sb-posix:getpid)) (getf plist :server-start))
        (is eql 3 (getf plist :worker-id))
        (is eq :hibernate (getf plist :action))
        (is eql 1234 (getf plist :requested-at))
        (is equal "pressure" (getf plist :reason)))
      (records:write-hibernate-request stem 4 :kill :now 1)
      (is eq :kill (getf (records:read-hibernate-request (records:request-path stem 4))
                         :action))
      (fail (records:write-hibernate-request stem 5 :delete))
      (fail (records:write-hibernate-request stem 0 :kill)))))

(defun write-raw-request (stem worker-id plist)
  "Write PLIST as the request file for STEM and WORKER-ID without any check, as
   a forged or damaged request would arrive."
  (records:ensure-pool-record-dirs)
  (hostfiles:write-plist-file (records:request-path stem worker-id) plist)
  (records:request-path stem worker-id))

(define-test a-request-that-disagrees-with-its-name-is-rejected
  "The name of a request file and its contents must say the same thing, and
   only the two known actions are accepted."
  (with-state-home (home)
    (let* ((stem (own-stem))
           (pid (sb-posix:getpid))
           (start (hostfiles:proc-starttime pid)))
      (flet ((rejected (path)
               (multiple-value-bind (plist reason) (records:read-hibernate-request path)
                 (is eq nil plist)
                 (true (stringp reason)))))
        (rejected (write-raw-request stem 3 (list :server-pid (1+ pid) :server-start start
                                                  :worker-id 3 :action :hibernate)))
        (rejected (write-raw-request stem 3 (list :server-pid pid :server-start (1+ start)
                                                  :worker-id 3 :action :hibernate)))
        (rejected (write-raw-request stem 3 (list :server-pid pid :server-start start
                                                  :worker-id 4 :action :hibernate)))
        (rejected (write-raw-request stem 3 (list :server-pid pid :server-start start
                                                  :worker-id 3 :action :delete)))
        (let ((path (records:request-path stem 3)))
          (write-text path "this is not a plist")
          (rejected path))
        (rejected (records:request-path stem 9))))))

(define-test a-request-cannot-carry-a-path
  "A request that names a path is read without it: where a world is written is
   decided by the pool alone."
  (with-state-home (home)
    (let* ((stem (own-stem))
           (pid (sb-posix:getpid))
           (path (write-raw-request stem 3 (list :server-pid pid
                                                 :server-start (hostfiles:proc-starttime pid)
                                                 :worker-id 3 :action :hibernate
                                                 :path "/etc/passwd"))))
      (multiple-value-bind (plist reason) (records:read-hibernate-request path)
        (is eq nil reason)
        (is eq :hibernate (getf plist :action))
        (is eq :absent (getf plist :path :absent))
        (true (loop for key in plist by #'cddr
                    always (member key '(:server-pid :server-start :worker-id :action
                                         :requested-at :reason))))))))

(define-test pending-requests-removes-what-it-rejects
  "A valid request is handed over; a rejected one is removed and named, so it
   cannot be read again."
  (with-state-home (home)
    (let* ((stem (own-stem))
           (pid (sb-posix:getpid))
           (start (hostfiles:proc-starttime pid)))
      (records:write-hibernate-request stem 1 :hibernate :now 10)
      (let ((bad (write-raw-request stem 2 (list :server-pid pid :server-start start
                                                 :worker-id 2 :action :delete))))
        (multiple-value-bind (pending rejected) (records:pending-requests stem)
          (is = 1 (length pending))
          (is eql 1 (getf (cdr (first pending)) :worker-id))
          (is = 1 (length rejected))
          (false (probe-file bad)))
        (is = 1 (length (records:pending-requests)))
        (is eq nil (records:pending-requests (stale-stem)))
        (true (records:remove-request (car (first (records:pending-requests stem)))))
        (is eq nil (records:pending-requests stem))))))

;;; -------------------------------------------------------------------- sweep

(define-test the-sweep-removes-what-dead-servers-left
  "Directories, records and requests of a server that is gone are removed and
   counted; a live server's are kept; a link inside a dead directory is removed
   as a link and what it points at is left alone."
  (with-state-home (home)
    (with-temp-dir (outside "dsmr-pool-records-outside")
      (let* ((live (own-stem))
             (dead-stems (list "999999999-1" (stale-stem)))
             (target (write-text (merge-pathnames "precious" outside) "keep me")))
        (dolist (stem (cons live dead-stems))
          (write-text (records:hibernated-core-path stem 1)
                      (make-string 100 :initial-element #\c))
          (records:ensure-owner-directory stem)
          (records:write-worker-record stem (list :server-pid 1))
          (records:write-hibernate-request stem 1 :hibernate :now 5))
        (sb-posix:symlink (uiop:native-namestring target)
                          (concatenate 'string
                                       (native-no-slash
                                        (records:owner-directory (first dead-stems)))
                                       "/link.core"))
        (multiple-value-bind (report-fn records-given) (recorder)
          (let ((counts (records:sweep-dead-owners :report-fn report-fn)))
            (is = 2 (getf counts :directories))
            (is = 2 (getf counts :records))
            (is = 2 (getf counts :requests))
            (true (>= (getf counts :bytes) 200))
            (is = 6 (length (funcall records-given)))))
        (dolist (stem dead-stems)
          (false (entry-exists-p (records:owner-directory stem)))
          (false (probe-file (records:worker-record-path stem)))
          (false (probe-file (records:request-path stem 1))))
        (true (probe-file (records:hibernated-core-path live 1)))
        (true (probe-file (records:worker-record-path live)))
        (true (probe-file (records:request-path live 1)))
        (is string= "keep me" (uiop:read-file-string target))))))

(define-test the-sweep-keeps-what-it-cannot-tell-is-dead
  "When reading whether a server runs fails (out of descriptors, out of
memory), the sweep removes nothing of that server and reports it once."
  (with-state-home (home)
    (let ((stems (list "999999999-1" (stale-stem))))
      (dolist (stem stems)
        (write-text (records:hibernated-core-path stem 1) "world")
        (records:ensure-owner-directory stem)
        (records:write-worker-record stem (list :server-pid 1))
        (records:write-hibernate-request stem 1 :hibernate :now 5))
      (multiple-value-bind (report-fn records-given) (recorder)
        (let ((counts (let ((records:*owner-starttime-function*
                              (lambda (pid)
                                (declare (ignore pid))
                                (error "Too many open files"))))
                        (records:sweep-dead-owners :report-fn report-fn))))
          (is = 0 (getf counts :directories))
          (is = 0 (getf counts :records))
          (is = 0 (getf counts :requests)))
        (let ((unknown (remove "owner-state-unknown" (funcall records-given)
                               :key #'second :test-not #'string=)))
          (is = 2 (length unknown))
          (true (every (lambda (r) (eq :warn (first r))) unknown))))
      (dolist (stem stems)
        (true (probe-file (records:hibernated-core-path stem 1)))
        (true (probe-file (records:worker-record-path stem)))
        (true (probe-file (records:request-path stem 1)))))))

;;; ------------------------------------------------------------ host readings

(define-test free-disk-agrees-with-df
  "The free space read through statvfs matches what `df` reports for the same
   directory, which is what would catch a wrong structure layout."
  (with-temp-dir (dir "dsmr-pool-records-disk")
    (let ((free (records:free-disk-bytes dir))
          (df (df-available-bytes dir)))
      (true (integerp free))
      (true (plusp free))
      (if df
          (true (<= (abs (- free df)) (max 1 (floor df 100))))
          (skip ("df is not available here to compare against")))))
  (is eq nil (records:free-disk-bytes #p"/nonexistent-dsmr-pool-records/")))

(define-test hibernation-needs-twice-the-core-size-free
  "A save is allowed only with room for twice the expected core, and an
   unreadable figure counts as no room."
  (multiple-value-bind (allowed free)
      (records:disk-allows-hibernation-p "/tmp/" 100 :free-fn (constantly 199))
    (false allowed)
    (is eql 199 free))
  (multiple-value-bind (allowed free)
      (records:disk-allows-hibernation-p "/tmp/" 100 :free-fn (constantly 200))
    (true allowed)
    (is eql 200 free))
  (multiple-value-bind (allowed free)
      (records:disk-allows-hibernation-p "/tmp/" 100 :free-fn (constantly nil))
    (false allowed)
    (is eq nil free)))

(define-test memory-readings-name-a-live-process
  "Resident and proportional memory are read for a live process and are absent
   for one that does not exist."
  (let ((pid (sb-posix:getpid)))
    (true (and (integerp (records:read-rss-kb pid)) (plusp (records:read-rss-kb pid))))
    (true (and (integerp (records:read-pss-kb pid)) (plusp (records:read-pss-kb pid))))
    (is eq nil (records:read-rss-kb 999999999))
    (is eq nil (records:read-pss-kb 999999999))
    (true (>= (records:expected-core-bytes pid) 209715200))
    ;; Resident memory moves while the test runs, since reading it allocates,
    ;; so the estimate is checked against readings taken either side of it.
    (let* ((before (records:read-rss-kb pid))
           (expected (records:expected-core-bytes pid :floor-bytes 1))
           (after (records:read-rss-kb pid)))
      (true (<= (* 1024 (min before after)) expected (* 1024 (max before after)))
            "expected ~D bytes, resident ~D then ~D KiB" expected before after))
    (is eql 209715200 (records:expected-core-bytes 999999999))))

(defun %fail-core (stem id now)
  "Write a core for the server STEM's worker ID and keep it as failed at NOW,
asserting it moved into the failed directory."
  (let ((core (records:hibernated-core-path stem id)))
    (records:ensure-owner-directory stem)
    (write-text core "world")
    (let ((moved (records:retain-failed-core core stem id :now now)))
      (true (uiop:string-prefix-p
             (uiop:native-namestring (records:failed-core-directory))
             (uiop:native-namestring moved)))
      (false (probe-file core)))))

(defun %failed-names ()
  "The names in the failed directory, sorted."
  (sort (mapcar #'file-namestring
                (uiop:directory-files (records:failed-core-directory)))
        #'string<))

(define-test a-burst-of-failures-keeps-every-running-servers-world
  "Failed cores of five workers of a running server are all kept, however
many fail at once: one session's failure never deletes another's world."
  (with-state-home (home)
    (let ((stem (own-stem)))
      (loop for id from 1 to 5
            for now from 100
            do (%fail-core stem id now))
      (is equal (loop for id from 1 to 5
                      for now from 100
                      collect (format nil "~A-~D-~D.core" stem id now))
          (%failed-names))
      (is = #o700 (mode-bits (records:failed-core-directory))))))

(define-test failed-cores-of-gone-servers-and-older-copies-are-capped
  "Beyond the newest core of each worker of a running server, only the two
newest stay: cores of a server that is gone are dropped past those, and so is
an older core of the same worker."
  (with-state-home (home)
    (let ((live (own-stem))
          (gone "999999999-1"))
      (%fail-core live 7 50)
      (%fail-core live 7 60)
      (loop for id from 1 to 4
            for now from 100
            do (%fail-core gone id now))
      (is equal (sort (list (format nil "~A-7-60.core" live)
                            (format nil "~A-3-102.core" gone)
                            (format nil "~A-4-103.core" gone))
                      #'string<)
          (%failed-names)))))

(define-test a-failed-core-whose-server-cannot-be-read-is-kept
  "When whether a server runs cannot be read, its failed cores are kept as if
it were running."
  (with-state-home (home)
    (let ((stem "999999999-1"))
      (let ((records:*owner-starttime-function*
              (lambda (pid)
                (declare (ignore pid))
                (error "Too many open files"))))
        (loop for id from 1 to 4
              for now from 100
              do (%fail-core stem id now)))
      (is = 4 (length (%failed-names))))))
