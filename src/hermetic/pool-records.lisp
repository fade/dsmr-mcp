;;;; src/hermetic/pool-records.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; The files the session pools and the host service share for memory
;;;; pressure relief, named and checked in one place.
;;;;
;;;; Every MCP server runs its own pool of hermetic workers, and one host
;;;; service watches the memory of the whole machine. When memory runs short
;;;; the service has to ask some pool to hibernate or stop a worker, and it
;;;; needs to know which workers exist to choose one. I couple the two through
;;;; files in the service's state directory rather than a connection, because
;;;; either side may restart at any moment and a file outlives both: a pool
;;;; publishes a record of its workers, the service leaves a request beside it,
;;;; and whichever process comes up next finds the other's last word waiting.
;;;;
;;;; A request names a worker by its id and says what to do with it, and never
;;;; names a path. The pool alone decides where a world is written, from its
;;;; own pid and start time and a worker id it has checked, so nothing another
;;;; process puts in a request can point a save, or a delete, at a file of its
;;;; choosing. A request that carries more is read without the extra keys.
;;;;
;;;; Free disk is read with statvfs(3) rather than by running `df`. The check
;;;; runs exactly when the host is short of memory, and a call into the C
;;;; library costs nothing there while a child process costs a fork and an
;;;; exec. The structure layout is the glibc one for 64-bit Linux, the only
;;;; platform this server runs on; the unit test compares the answer with `df`
;;;; so a wrong layout cannot pass unnoticed.
;;;;
;;;; This is a leaf both the MCP server and the host service load. It uses cl,
;;;; uiop, sb-posix, sb-alien and the host-file leaf, and nothing that reaches
;;;; ZeroMQ or the worker, so the service stays free of both.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-posix))

(defpackage #:dsmr-mcp/src/hermetic/pool-records
  (:use #:cl)
  (:local-nicknames (#:hostfiles #:dsmr-mcp/src/bus/hostfiles))
  (:import-from #:sb-posix)
  (:import-from #:uiop)
  (:export
   ;; layout of hibernated cores
   #:hibernate-root
   #:server-stem
   #:parse-server-stem
   #:owner-directory
   #:ensure-owner-directory
   #:unsafe-hibernate-path
   #:unsafe-hibernate-path-path
   #:unsafe-hibernate-path-reason
   #:hibernated-core-path
   #:remove-owner-directory
   #:failed-core-directory
   #:retain-failed-core
   ;; worker records
   #:workers-record-dir
   #:hibernate-request-dir
   #:ensure-pool-record-dirs
   #:worker-record-path
   #:write-worker-record
   #:read-worker-record
   #:worker-record-stems
   #:remove-worker-record
   ;; hibernate requests
   #:request-path
   #:write-hibernate-request
   #:read-hibernate-request
   #:pending-requests
   #:remove-request
   ;; sweep
   #:sweep-dead-owners
   ;; host readings
   #:free-disk-bytes
   #:disk-allows-hibernation-p
   #:read-rss-kb
   #:read-pss-kb
   #:expected-core-bytes))

(in-package #:dsmr-mcp/src/hermetic/pool-records)

;;; ------------------------------------------------------------------ helpers

(defun %unix-time ()
  "Now, as seconds since the Unix epoch."
  (- (get-universal-time) 2208988800))

(defun %file-in (dir name)
  "The file NAME in directory DIR, built from a native namestring so nothing in
   NAME can be read as a wildcard."
  (uiop:parse-native-namestring
   (concatenate 'string (uiop:native-namestring dir) name)))

(defun %native (path)
  "PATH as a native namestring without a trailing slash, so lstat and unlink
   act on the entry itself and never on what a link at that name points to."
  (let ((native (string-right-trim "/" (uiop:native-namestring path))))
    (if (zerop (length native)) "/" native)))

(defun %lstat (native)
  "The lstat record for NATIVE, or NIL when nothing is there."
  (handler-case (sb-posix:lstat native)
    (sb-posix:syscall-error () nil)))

(defun %kind (stat)
  "The file type bits of STAT."
  (logand (sb-posix:stat-mode stat) sb-posix:s-ifmt))

(defun %ascii-digits-p (string)
  "True when STRING is one or more of the characters 0 to 9 and nothing else."
  (and (plusp (length string))
       (every (lambda (ch) (char<= #\0 ch #\9)) string)))

(defun %directory-entries (native)
  "The names in directory NATIVE, without . and .., or NIL when it cannot be
   listed. The listing reads the directory itself, so a link inside it is
   reported by its own name and never resolved."
  (handler-case
      (let ((dir (sb-posix:opendir native))
            (names '()))
        (unwind-protect
             (loop for entry = (sb-posix:readdir dir)
                   until (sb-alien:null-alien entry)
                   do (let ((name (sb-posix:dirent-name entry)))
                        (unless (member name '("." "..") :test #'string=)
                          (push name names))))
          (sb-posix:closedir dir))
        (sort names #'string<))
    (sb-posix:syscall-error () nil)))

(defun %unlink-if-present (native)
  "Remove the entry NATIVE without following it. True when something was there
   to remove."
  (handler-case (progn (sb-posix:unlink native) t)
    (sb-posix:syscall-error () nil)))

;;; ---------------------------------------------------------- server identity

(defun server-stem (&optional (pid (sb-posix:getpid)))
  "The stem naming the server process PID: <pid>-<starttime>, the start time
   read from /proc, or NIL when there is no such process. A pid alone can be
   handed to a later process; the pair cannot."
  (let ((start (hostfiles:proc-starttime pid)))
    (and start (format nil "~D-~D" pid start))))

(defun parse-server-stem (string)
  "The pid and start time STRING names, as two values, or NIL when STRING is
   anything but digits, one hyphen and digits with a nonzero pid. Nothing else
   is accepted, so no stem can carry a separator or a relative path."
  (let ((hyphen (and (stringp string)
                     (<= (length string) 48)
                     (position #\- string))))
    (when hyphen
      (let ((pid-part (subseq string 0 hyphen))
            (start-part (subseq string (1+ hyphen))))
        (when (and (%ascii-digits-p pid-part)
                   (%ascii-digits-p start-part))
          (let ((pid (parse-integer pid-part)))
            (when (plusp pid)
              (values pid (parse-integer start-part)))))))))

(defun %check-stem (stem)
  "STEM, when it is a server stem; otherwise signal."
  (unless (parse-server-stem stem)
    (error "~S is not a server stem (<pid>-<starttime>)." stem))
  stem)

(defun %check-worker-id (worker-id)
  "WORKER-ID, when it is a positive integer; otherwise signal."
  (unless (typep worker-id '(integer 1))
    (error "~S is not a worker id (a positive integer)." worker-id))
  worker-id)

(defun %owner-alive-p (stem)
  "True when the server STEM names is still the running process it was."
  (multiple-value-bind (pid start) (parse-server-stem stem)
    (and pid (hostfiles:process-matches-p pid start))))

;;; --------------------------------------------------------- hibernated cores

(define-condition unsafe-hibernate-path (error)
  ((path :initarg :path :reader unsafe-hibernate-path-path)
   (reason :initarg :reason :reader unsafe-hibernate-path-reason))
  (:report (lambda (condition stream)
             (format stream "Refusing to use ~A for hibernated cores: ~A."
                     (unsafe-hibernate-path-path condition)
                     (unsafe-hibernate-path-reason condition))))
  (:documentation
   "A directory hibernated cores would be written under, or deleted from, is a
    symbolic link, is not a directory, or belongs to another user."))

(defun %refuse-path (native reason)
  "Signal UNSAFE-HIBERNATE-PATH for NATIVE with REASON."
  (error 'unsafe-hibernate-path :path native :reason reason))

(defun %check-real-directory (native stat)
  "Signal unless STAT, the lstat of NATIVE, is a directory owned by this user."
  (cond ((= (%kind stat) sb-posix:s-iflnk)
         (%refuse-path native "it is a symbolic link"))
        ((/= (%kind stat) sb-posix:s-ifdir)
         (%refuse-path native "it is not a directory"))
        ((/= (sb-posix:stat-uid stat) (sb-posix:getuid))
         (%refuse-path native "it belongs to another user"))))

(defun %ensure-private-directory (dir)
  "Create DIR when it is missing and make it readable by its owner alone,
   refusing it when it is a link, not a directory, or another user's. Returns
   DIR.

   The mode is set on every call, not only on creation, because a directory
   made earlier under a looser umask would otherwise stay open, and a core
   holds every secret its world held. The mode is changed through a
   descriptor opened without following links, so a link swapped in after the
   check cannot redirect the change."
  (let ((native (%native dir)))
    (unless (%lstat native)
      (handler-case (sb-posix:mkdir native #o700)
        (sb-posix:syscall-error (e)
          (unless (= (sb-posix:syscall-errno e) sb-posix:eexist)
            (error e)))))
    (let ((stat (%lstat native)))
      (unless stat
        (%refuse-path native "it could not be created"))
      (%check-real-directory native stat))
    (let ((fd (handler-case
                  (sb-posix:open native (logior sb-posix:o-rdonly
                                                sb-posix:o-directory
                                                sb-posix:o-nofollow))
                (sb-posix:syscall-error ()
                  (%refuse-path native "it changed while it was being checked")))))
      (unwind-protect
           (progn
             (unless (= (sb-posix:stat-uid (sb-posix:fstat fd)) (sb-posix:getuid))
               (%refuse-path native "it belongs to another user"))
             (sb-posix:fchmod fd #o700))
        (sb-posix:close fd)))
    dir))

(defun hibernate-root ()
  "The directory hibernated cores live under: dsmr-mcp/hibernate/ in the state
   home. The worker that writes a core names the same directory."
  (merge-pathnames "dsmr-mcp/hibernate/" (hostfiles:state-home)))

(defun %ensure-hibernate-root ()
  "Create the hibernate root, private, and return it."
  (ensure-directories-exist (merge-pathnames "dsmr-mcp/" (hostfiles:state-home)))
  (%ensure-private-directory (hibernate-root)))

(defun owner-directory (stem)
  "The directory the server STEM names keeps its hibernated cores in. Signals
   for anything that is not a server stem."
  (uiop:ensure-directory-pathname
   (%file-in (hibernate-root) (%check-stem stem))))

(defun ensure-owner-directory (stem)
  "Create the server STEM's core directory and the hibernate root above it,
   each readable by its owner alone, and return the directory. Signals
   UNSAFE-HIBERNATE-PATH when either level is a link or not this user's."
  (%check-stem stem)
  (%ensure-hibernate-root)
  (%ensure-private-directory (owner-directory stem)))

(defun hibernated-core-path (stem worker-id)
  "Where the server STEM saves the world of worker WORKER-ID:
   <owner directory>/<worker id>.core. The id must be a positive integer."
  (%check-worker-id worker-id)
  (%file-in (owner-directory stem) (format nil "~D.core" worker-id)))

(defun %remove-tree (native)
  "Remove the entry NATIVE and, when it is a directory, everything inside it,
   never following a link: a link is removed as a link. Returns the bytes of
   regular files removed, or NIL when nothing was there. Signals
   UNSAFE-HIBERNATE-PATH for a directory owned by another user."
  (let ((stat (%lstat native)))
    (cond ((null stat) nil)
          ((= (%kind stat) sb-posix:s-ifdir)
           (unless (= (sb-posix:stat-uid stat) (sb-posix:getuid))
             (%refuse-path native "it belongs to another user"))
           (let ((bytes 0))
             (dolist (name (%directory-entries native))
               (incf bytes (or (%remove-tree (concatenate 'string native "/" name)) 0)))
             (sb-posix:rmdir native)
             bytes))
          (t
           (let ((size (if (= (%kind stat) sb-posix:s-ifreg)
                           (sb-posix:stat-size stat)
                           0)))
             (sb-posix:unlink native)
             size)))))

(defun remove-owner-directory (stem)
  "Delete the server STEM's core directory and the files inside it, removing
   any link as a link and never what it points at. Returns the bytes freed, or
   NIL when there was no directory."
  (%remove-tree (%native (owner-directory stem))))

(defun failed-core-directory ()
  "Where a core that failed to save is kept for diagnosis."
  (merge-pathnames "failed/" (hibernate-root)))

(defun %failed-core-time (name)
  "The Unix time a kept failed core's NAME records, or 0 when it has none."
  (let* ((base (if (uiop:string-suffix-p name ".core")
                   (subseq name 0 (- (length name) 5))
                   name))
         (hyphen (position #\- base :from-end t))
         (digits (and hyphen (subseq base (1+ hyphen)))))
    (if (and digits (%ascii-digits-p digits))
        (parse-integer digits)
        0)))

(defun retain-failed-core (path stem worker-id &key (keep 2) now)
  "Move the core at PATH, which the server STEM's worker WORKER-ID failed to
   save, to failed/<stem>-<id>-<unix time>.core and return its new path. Only
   the KEEP newest failed cores are kept; older ones are deleted, so repeated
   failures cannot fill the disk. NOW, Unix seconds, defaults to the clock.
   Signals UNSAFE-HIBERNATE-PATH when PATH is a link or not a regular file."
  (%check-stem stem)
  (%check-worker-id worker-id)
  (let* ((now (or now (%unix-time)))
         (source (%native path))
         (stat (%lstat source)))
    (cond ((null stat)
           (error "There is no core at ~A to keep." source))
          ((/= (%kind stat) sb-posix:s-ifreg)
           (%refuse-path source "it is not a regular file")))
    (%ensure-hibernate-root)
    (let* ((failed (%ensure-private-directory (failed-core-directory)))
           (target (%file-in failed (format nil "~A-~D-~D.core" stem worker-id now))))
      (sb-posix:rename source (%native target))
      (let ((kept (sort (remove-if-not (lambda (name) (uiop:string-suffix-p name ".core"))
                                       (%directory-entries (%native failed)))
                        (lambda (a b)
                          (let ((ta (%failed-core-time a))
                                (tb (%failed-core-time b)))
                            (or (> ta tb) (and (= ta tb) (string> a b))))))))
        (dolist (old (nthcdr keep kept))
          (ignore-errors (%remove-tree (concatenate 'string (%native failed) "/" old)))))
      target)))

;;; ----------------------------------------------------------- worker records

(defun workers-record-dir ()
  "Where each pool publishes the record of its workers: workers/ under the
   host service's directory."
  (merge-pathnames "workers/" (hostfiles:host-dir)))

(defun hibernate-request-dir ()
  "Where the host service leaves its requests for the pools: hibernate/ under
   the host service's directory."
  (merge-pathnames "hibernate/" (hostfiles:host-dir)))

(defun ensure-pool-record-dirs ()
  "Create the host directory, the worker record directory and the request
   directory, each readable by its owner alone, and return the host directory.
   The mode is set on every call, because these files name sessions and
   processes."
  (hostfiles:ensure-host-dir)
  (%ensure-private-directory (workers-record-dir))
  (%ensure-private-directory (hibernate-request-dir))
  (hostfiles:host-dir))

(defun worker-record-path (stem)
  "The record the server STEM publishes of its workers: workers/<stem>.rec."
  (%file-in (workers-record-dir) (concatenate 'string (%check-stem stem) ".rec")))

(defun write-worker-record (stem plist)
  "Publish PLIST as the server STEM's worker record, owner-only, replacing the
   last one in a single rename. Keys: :SERVER-PID :SERVER-START :WRITTEN-AT
   :SERVICE-SEEN :WORKERS :LAST-ACTION, where each worker is a plist of :ID :PID
   :STATE :SESSION :STATEFUL :BUSY :SPAWNED-AT :LAST-ACTIVITY :REFUSED-REASON
   :REFUSED-AT :CORE-BYTES, and the last action, when there is one, is a plist
   of :WORKER-ID :ACTION :RESULT :AT."
  (let ((path (worker-record-path stem)))
    (ensure-pool-record-dirs)
    (hostfiles:write-plist-file path plist)))

(defun read-worker-record (path)
  "The worker record at PATH and its read status, :OK, :ABSENT or :UNREADABLE.
   A record over 65536 bytes is unreadable."
  (hostfiles:read-plist-file path :max-bytes 65536))

(defun %names-with-suffix (dir suffix)
  "The names in DIR that end in SUFFIX and do not start with a dot (a scratch
   file mid-write starts with one)."
  (remove-if-not (lambda (name)
                   (and (> (length name) (length suffix))
                        (char/= (char name 0) #\.)
                        (uiop:string-suffix-p name suffix)))
                 (%directory-entries (%native dir))))

(defun worker-record-stems ()
  "The stems that have a worker record, sorted."
  (loop for name in (%names-with-suffix (workers-record-dir) ".rec")
        for stem = (subseq name 0 (- (length name) 4))
        when (parse-server-stem stem)
          collect stem))

(defun remove-worker-record (stem)
  "Remove the server STEM's worker record. True when there was one."
  (%unlink-if-present (%native (worker-record-path stem))))

;;; -------------------------------------------------------- hibernate requests

(defparameter *request-actions* '(:hibernate :kill)
  "The only things a request may ask a pool to do with a worker.")

(defparameter *request-keys*
  '(:server-pid :server-start :worker-id :action :requested-at :reason)
  "The keys a request is read with. Any other key in a request file is
   dropped, so a request cannot smuggle a path or anything else to the pool.")

(defun request-path (stem worker-id)
  "The request file for worker WORKER-ID of the server STEM:
   hibernate/<stem>.<worker id>.req."
  (%check-stem stem)
  (%check-worker-id worker-id)
  (%file-in (hibernate-request-dir) (format nil "~A.~D.req" stem worker-id)))

(defun write-hibernate-request (stem worker-id action &key now reason)
  "Ask the server STEM to apply ACTION, :HIBERNATE or :KILL, to its worker
   WORKER-ID, and return the request's path. REASON, a string, says why; NOW,
   Unix seconds, defaults to the clock."
  (unless (member action *request-actions*)
    (error "~S is not a request action; expected one of ~S." action *request-actions*))
  (unless (or (null reason) (stringp reason))
    (error "A request's reason is a string, not ~S." reason))
  (let ((path (request-path stem worker-id)))
    (multiple-value-bind (pid start) (parse-server-stem stem)
      (ensure-pool-record-dirs)
      (hostfiles:write-plist-file path (list :server-pid pid
                                             :server-start start
                                             :worker-id worker-id
                                             :action action
                                             :requested-at (or now (%unix-time))
                                             :reason reason)))
    path))

(defun %parse-request-name (name)
  "The stem and worker id a request file NAME carries, as two values, or NIL
   when NAME is not <stem>.<worker id>.req."
  (when (and (> (length name) 4) (uiop:string-suffix-p name ".req"))
    (let* ((base (subseq name 0 (- (length name) 4)))
           (dot (position #\. base :from-end t)))
      (when dot
        (let ((stem (subseq base 0 dot))
              (id-part (subseq base (1+ dot))))
          (when (and (parse-server-stem stem)
                     (%ascii-digits-p id-part)
                     (<= (length id-part) 18)
                     (plusp (parse-integer id-part)))
            (values stem (parse-integer id-part))))))))

(defun read-hibernate-request (path)
  "The request at PATH as a plist of the known keys and NIL, or NIL and a
   sentence saying why it was rejected.

   A request is accepted only when its file name is <stem>.<worker id>.req,
   the server pid and start time inside equal the stem, the worker id inside
   equals the one in the name, and the action is :HIBERNATE or :KILL. Only the
   known keys are returned, whatever else the file holds."
  (let* ((pathname (if (stringp path) (uiop:parse-native-namestring path) path))
         (name (file-namestring pathname)))
    (multiple-value-bind (stem worker-id) (%parse-request-name name)
      (unless stem
        (return-from read-hibernate-request
          (values nil (format nil "~A is not named <stem>.<worker id>.req" name))))
      (multiple-value-bind (plist status) (hostfiles:read-plist-file pathname)
        (case status
          (:absent
           (return-from read-hibernate-request
             (values nil (format nil "there is no request at ~A" name))))
          (:unreadable
           (return-from read-hibernate-request
             (values nil (format nil "~A is not a readable plist of ours" name)))))
        (multiple-value-bind (pid start) (parse-server-stem stem)
          (let ((reason
                  (cond ((not (eql (getf plist :server-pid) pid))
                         "its server pid differs from the one in its name")
                        ((not (eql (getf plist :server-start) start))
                         "its server start time differs from the one in its name")
                        ((not (eql (getf plist :worker-id) worker-id))
                         "its worker id differs from the one in its name")
                        ((not (member (getf plist :action) *request-actions*))
                         (format nil "its action ~S is not one of ~S"
                                 (getf plist :action) *request-actions*))
                        ((not (typep (getf plist :requested-at) '(or null integer)))
                         "its request time is not a number of seconds")
                        ((not (typep (getf plist :reason) '(or null string)))
                         "its reason is not a string"))))
            (if reason
                (values nil (format nil "~A: ~A" name reason))
                (values (loop for key in *request-keys*
                              append (list key (getf plist key)))
                        nil))))))))

(defun pending-requests (&optional stem)
  "The requests waiting for the server STEM, or for every server when STEM is
   NIL, as a list of (PATH . PLIST) sorted by file name. A second value lists
   the requests that were rejected, as (PATH . REASON); each of those has been
   removed, so a damaged or forged request is reported once and never acted
   on."
  (when stem (%check-stem stem))
  (let ((dir (hibernate-request-dir))
        (prefix (and stem (concatenate 'string stem ".")))
        (pending '())
        (rejected '()))
    (dolist (name (%names-with-suffix dir ".req"))
      (when (or (null prefix) (uiop:string-prefix-p prefix name))
        (let ((path (%file-in dir name)))
          (multiple-value-bind (plist reason) (read-hibernate-request path)
            (if plist
                (push (cons path plist) pending)
                (progn
                  (%unlink-if-present (%native path))
                  (push (cons path reason) rejected)))))))
    (values (nreverse pending) (nreverse rejected))))

(defun remove-request (path)
  "Remove the request at PATH. True when there was one."
  (%unlink-if-present (%native path)))

;;; -------------------------------------------------------------------- sweep

(defun %listable-directory-p (native report)
  "True when NATIVE is a directory of ours that may be listed and cleared.
   Absent is quietly false; a link or another user's directory is reported
   through REPORT and false."
  (let ((stat (%lstat native)))
    (and stat
         (handler-case (progn (%check-real-directory native stat) t)
           (unsafe-hibernate-path (c)
             (funcall report :warn "hibernate-path-refused" native
                      (princ-to-string c))
             nil)))))

(defun sweep-dead-owners (&key report-fn)
  "Remove every core directory, worker record and request whose server is no
   longer the running process its stem names, and return the counts as a plist
   (:DIRECTORIES n :RECORDS n :REQUESTS n :BYTES n), BYTES being what the core
   directories held.

   Both the pools and the host service call this, so whichever side outlives a
   dead server clears what it left. A server is alive only when its pid is
   running and started at the recorded time, so a pid handed to a later
   process does not keep a dead server's files. Nothing is followed through a
   link: a link at a server's level is removed as a link when its server is
   gone and reported either way, and a link in place of a whole directory
   makes the sweep leave that directory alone.

   REPORT-FN, when given, is called as (funcall REPORT-FN level code :subject
   path :msg text) once for each removal and each refusal."
  (let ((directories 0) (records 0) (requests 0) (bytes 0))
    (flet ((report (level code subject msg)
             (when report-fn
               (funcall report-fn level code :subject subject :msg msg))))
      (let ((root (%native (hibernate-root))))
        (when (%listable-directory-p root #'report)
          (dolist (name (%directory-entries root))
            (when (parse-server-stem name)
              (let* ((child (concatenate 'string root "/" name))
                     (stat (%lstat child))
                     (alive (%owner-alive-p name)))
                (cond ((null stat))
                      ((= (%kind stat) sb-posix:s-iflnk)
                       (if alive
                           (report :warn "hibernate-link-refused" child
                                   "a link stands where a server's core directory belongs")
                           (when (%unlink-if-present child)
                             (report :warn "hibernate-link-removed" child
                                     (format nil "server ~A is gone; its link was removed, not followed"
                                             name)))))
                      (alive)
                      (t
                       (handler-case
                           (let ((freed (%remove-tree child)))
                             (when freed
                               (incf directories)
                               (incf bytes freed)
                               (report :info "hibernate-owner-swept" child
                                       (format nil "server ~A is gone; removed ~D bytes of cores"
                                               name freed))))
                         ((or unsafe-hibernate-path sb-posix:syscall-error) (c)
                           (report :warn "hibernate-path-refused" child
                                   (princ-to-string c)))))))))))
      (let ((dir (%native (workers-record-dir))))
        (when (%listable-directory-p dir #'report)
          (dolist (name (%names-with-suffix (workers-record-dir) ".rec"))
            (let ((stem (subseq name 0 (- (length name) 4))))
              (when (and (parse-server-stem stem) (not (%owner-alive-p stem)))
                (let ((path (concatenate 'string dir "/" name)))
                  (when (%unlink-if-present path)
                    (incf records)
                    (report :info "worker-record-swept" path
                            (format nil "server ~A is gone; its worker record was removed"
                                    stem)))))))))
      (let ((dir (%native (hibernate-request-dir))))
        (when (%listable-directory-p dir #'report)
          (dolist (name (%names-with-suffix (hibernate-request-dir) ".req"))
            (let ((stem (%parse-request-name name)))
              (when (and stem (not (%owner-alive-p stem)))
                (let ((path (concatenate 'string dir "/" name)))
                  (when (%unlink-if-present path)
                    (incf requests)
                    (report :info "hibernate-request-swept" path
                            (format nil "server ~A is gone; its request was removed"
                                    stem))))))))))
    (list :directories directories :records records :requests requests :bytes bytes)))

;;; ------------------------------------------------------------ host readings

;;; struct statvfs as glibc lays it out on 64-bit Linux: eleven unsigned longs
;;; followed by six ints of padding and reserved space.
(sb-alien:define-alien-type nil
    (sb-alien:struct statvfs-buffer
                     (bsize sb-alien:unsigned-long)
                     (frsize sb-alien:unsigned-long)
                     (blocks sb-alien:unsigned-long)
                     (bfree sb-alien:unsigned-long)
                     (bavail sb-alien:unsigned-long)
                     (files sb-alien:unsigned-long)
                     (ffree sb-alien:unsigned-long)
                     (favail sb-alien:unsigned-long)
                     (fsid sb-alien:unsigned-long)
                     (flag sb-alien:unsigned-long)
                     (namemax sb-alien:unsigned-long)
                     (spare (array sb-alien:int 6))))

(sb-alien:define-alien-routine ("statvfs" %statvfs) sb-alien:int
  (path sb-alien:c-string)
  (buffer (* (sb-alien:struct statvfs-buffer))))

(defun free-disk-bytes (directory)
  "The bytes an unprivileged user may still write on the filesystem holding
   DIRECTORY, or NIL when it cannot be read (no such directory, or the call
   failed)."
  (handler-case
      (let ((native (uiop:native-namestring directory)))
        (sb-alien:with-alien ((buffer (sb-alien:struct statvfs-buffer)))
          (when (zerop (%statvfs native (sb-alien:addr buffer)))
            (* (sb-alien:slot buffer 'bavail)
               (sb-alien:slot buffer 'frsize)))))
    (error () nil)))

(defun disk-allows-hibernation-p (directory expected-bytes
                                  &key (free-fn #'free-disk-bytes))
  "Whether a core of about EXPECTED-BYTES may be saved under DIRECTORY, and the
   free bytes the answer rests on, as two values. A save is allowed only with
   at least twice the expected size free, which leaves room for the scratch
   file and for whatever else the disk is doing; a figure that cannot be read
   counts as no room. FREE-FN reads the free bytes of a directory."
  (let* ((free (funcall free-fn directory))
         (allowed (and (integerp free)
                       (integerp expected-bytes)
                       (>= free (* 2 expected-bytes)))))
    (values (and allowed t) free)))

(defun %proc-file (pid name)
  "The text of /proc/PID/NAME, or NIL where there is no such file."
  (and (integerp pid) (plusp pid)
       (ignore-errors
        (uiop:read-file-string (format nil "/proc/~D/~A" pid name)))))

(defun %kilobyte-field (text label)
  "The number on the line of TEXT that starts with LABEL, as /proc writes a
   size in kilobytes, or NIL when there is no such line."
  (when text
    (dolist (line (uiop:split-string text :separator (string #\Newline)))
      (when (uiop:string-prefix-p label line)
        (return (ignore-errors
                 (parse-integer line :start (length label) :junk-allowed t)))))))

(defun read-rss-kb (pid)
  "The resident memory of PID in kilobytes (VmRSS), or NIL when there is no
   such process."
  (%kilobyte-field (%proc-file pid "status") "VmRSS:"))

(defun read-pss-kb (pid)
  "The proportional memory of PID in kilobytes (Pss from smaps_rollup): its
   resident memory with each shared page divided among the processes sharing
   it, or NIL when there is no such process or it cannot be read."
  (%kilobyte-field (%proc-file pid "smaps_rollup") "Pss:"))

(defun expected-core-bytes (pid &key (floor-bytes 209715200))
  "The size a core saved from PID is expected to reach: its resident memory in
   bytes, but never less than FLOOR-BYTES, since a saved world carries the
   whole image whatever part of it happens to be resident."
  (let ((rss (read-rss-kb pid)))
    (max floor-bytes (if rss (* 1024 rss) 0))))
