;;;; src/hermetic/worker/hibernate.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; A worker saving its whole Lisp world to a core file, so the process can
;;;; exit and a later process started from that file carries on with the same
;;;; functions, variables, structures, closures, packages and tables.
;;;;
;;;; Why the save happens in a forked child: SAVE-LISP-AND-DIE leaves the
;;;; process that calls it unusable, and a save can fail or run long on a slow
;;;; disk. If the worker saved itself in place, any failure would cost the
;;;; session the world it built. Instead the worker forks, the child saves and
;;;; exits, and the worker waits. Only when the child reports success does the
;;;; worker install the file and stop serving; on a failure or a timeout it
;;;; restarts its watchdog and goes on serving as if nothing had been asked.
;;;;
;;;; Why only an idle, single-threaded worker can be saved: a process cannot
;;;; fork with other threads running, and a thread cannot be written into a
;;;; core. Between requests a worker has its main thread and the parent
;;;; watchdog; the watchdog is stopped for the fork and restarted afterwards.
;;;; Any other thread (one the session started) makes the worker refuse, and
;;;; it stays resident.
;;;;
;;;; What does not survive a save, and what a session must expect to lose:
;;;;   - threads, and the dynamic bindings and stack of every thread;
;;;;   - open descriptors, sockets and file streams (the resumed process
;;;;     covers the old descriptor numbers with /dev/null so a stale socket
;;;;     object cannot close a descriptor the new process has opened);
;;;;   - timers, which stay marked as scheduled but never fire;
;;;;   - values of GET-INTERNAL-REAL-TIME, whose base restarts with each
;;;;     process, so a stored deadline means nothing after resume;
;;;;   - foreign memory and foreign handles not registered with SBCL.
;;;;
;;;; A partially written core is never installed: the child writes
;;;; <path>.tmp, and the worker renames it to <path>, readable by the owner
;;;; alone, only after the child exited with status 0. The file holds every
;;;; secret the world held, so the directory must belong to the user and be
;;;; private, and a path anywhere else is refused.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-posix))

(defpackage #:dsmr-mcp/src/hermetic/worker/hibernate
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/hermetic/worker/server #:stop-server)
  (:import-from #:dsmr-mcp/src/log #:log-event)
  (:import-from #:dsmr-mcp/src/bus/hostfiles #:state-home)
  (:import-from #:sb-posix)
  (:import-from #:uiop)
  (:export #:hibernate-directory
           #:handle-hibernate
           #:*stale-descriptors*
           #:install-descriptor-placeholders))

(in-package #:dsmr-mcp/src/hermetic/worker/hibernate)

;;; ---------------------------------------------------------------------------
;;; State carried into the saved core
;;; ---------------------------------------------------------------------------

(defvar *stale-descriptors* nil
  "Descriptor numbers that were open in the saving child just before the save,
sorted ascending. The child sets this, so the value is written into the core;
the resumed process covers each number with /dev/null and clears it.")

(defparameter *default-deadline-seconds* 170
  "Seconds a save may take before the worker kills the saving child and goes
on serving. A save is disk-bound and has been seen to take most of a minute
on a busy rotational disk.")

(defparameter *placeholder-floor* 900
  "Lowest descriptor number the /dev/null placeholder source is moved to while
it is copied over the stale numbers, so it never sits on one of them.")

;;; ---------------------------------------------------------------------------
;;; Where cores may be written
;;; ---------------------------------------------------------------------------

(defun hibernate-directory ()
  "The directory hibernated cores live under: dsmr-mcp/hibernate/ in the state
home ($XDG_STATE_HOME, else ~/.local/state/)."
  (merge-pathnames "dsmr-mcp/hibernate/" (state-home)))

(defun %refuse (token fmt &rest args)
  "Log a refusal and signal an error whose message is TOKEN, a colon, and the
formatted reason."
  (let ((message (format nil "~A: ~?" token fmt args)))
    (log-event :warn "worker.hibernate.refused" "reason" message)
    (error "~A" message)))

(defun %lstat (native)
  "The lstat record for NATIVE, or NIL when nothing is there."
  (handler-case (sb-posix:lstat native)
    (sb-posix:syscall-error () nil)))

(defun %strip-slash (native)
  "NATIVE without trailing slashes, keeping a lone root slash."
  (let ((end (length native)))
    (loop while (and (> end 1) (char= (char native (1- end)) #\/))
          do (decf end))
    (subseq native 0 end)))

(defun %check-directory (native &key private)
  "Refuse unless NATIVE is a real directory (not a symlink) owned by this user.
With PRIVATE, also refuse unless its permission bits are exactly 0700."
  (let* ((path (%strip-slash native))
         (st (%lstat path)))
    (cond ((null st)
           (%refuse "bad-path" "directory ~A does not exist" path))
          ((sb-posix:s-islnk (sb-posix:stat-mode st))
           (%refuse "bad-path" "directory ~A is a symlink" path))
          ((not (sb-posix:s-isdir (sb-posix:stat-mode st)))
           (%refuse "bad-path" "~A is not a directory" path))
          ((/= (sb-posix:stat-uid st) (sb-posix:getuid))
           (%refuse "bad-path" "directory ~A is not owned by this user" path))
          ((and private (/= (logand (sb-posix:stat-mode st) #o777) #o700))
           (%refuse "bad-path" "directory ~A has mode ~3,'0O, not 700"
                    path (logand (sb-posix:stat-mode st) #o777))))))

(defun %refuse-symlink (native)
  "Refuse when NATIVE exists and is a symlink."
  (let ((st (%lstat native)))
    (when (and st (sb-posix:s-islnk (sb-posix:stat-mode st)))
      (%refuse "bad-path" "~A is a symlink" native))))

(defun %validate-target (raw)
  "Check the requested core path RAW and return it as a native namestring.

The path must be an absolute string with no relative directory components,
name a file ending in .core inside the hibernate directory, and every
directory from the hibernate directory down to the file's own must be a real
directory owned by this user; the file's own directory must also be mode 0700.
An existing target or <target>.tmp that is a symlink is refused too."
  (unless (and (stringp raw) (plusp (length raw)))
    (%refuse "bad-path" "path must be a non-empty string"))
  (let* ((pathname (uiop:parse-native-namestring raw))
         (root (uiop:ensure-directory-pathname (hibernate-directory)))
         (file (file-namestring pathname)))
    (unless (uiop:absolute-pathname-p pathname)
      (%refuse "bad-path" "~A is not absolute" raw))
    (when (some (lambda (part) (member part '(:up :back)))
                (rest (pathname-directory pathname)))
      (%refuse "bad-path" "~A has a relative directory component" raw))
    (unless (and (> (length file) 5)
                 (string= ".core" file :start2 (- (length file) 5)))
      (%refuse "bad-path" "~A does not name a file ending in .core" raw))
    (unless (uiop:subpathp pathname root)
      (%refuse "bad-path" "~A is outside ~A" raw (uiop:native-namestring root)))
    ;; Every directory from the hibernate root down to the file's own.
    (let* ((root-parts (pathname-directory root))
           (parts (pathname-directory pathname)))
      (loop for depth from (length root-parts) to (length parts)
            for dir = (make-pathname :directory (subseq parts 0 depth)
                                     :name nil :type nil :version nil
                                     :defaults pathname)
            do (%check-directory (uiop:native-namestring dir)
                                 :private (= depth (length parts)))))
    (let ((native (uiop:native-namestring pathname)))
      (%refuse-symlink native)
      (%refuse-symlink (concatenate 'string native ".tmp"))
      native)))

;;; ---------------------------------------------------------------------------
;;; Descriptors
;;; ---------------------------------------------------------------------------

(defun %listed-descriptors ()
  "Descriptor numbers listed in /proc/self/fd, ascending. The listing's own
descriptor appears in the result and is closed by the time it returns."
  (let ((dir (sb-posix:opendir "/proc/self/fd"))
        (fds '()))
    (unwind-protect
         (loop for entry = (sb-posix:readdir dir)
               until (sb-alien:null-alien entry)
               do (let ((n (ignore-errors
                            (parse-integer (sb-posix:dirent-name entry)))))
                    (when n (push n fds))))
      (sb-posix:closedir dir))
    (sort fds #'<)))

(defun %descriptor-open-p (fd)
  "True when FD is an open descriptor of this process."
  (handler-case (progn (sb-posix:fcntl fd sb-posix:f-getfd) t)
    (sb-posix:syscall-error () nil)))

(defun %close-inherited-descriptors ()
  "Close every descriptor at or above 3 and return the numbers that were
actually open, ascending. Run in the saving child only."
  (loop for fd in (%listed-descriptors)
        when (and (>= fd 3)
                  (handler-case (progn (sb-posix:close fd) t)
                    (sb-posix:syscall-error () nil)))
          collect fd))

(defun %silence-stdout ()
  "Point descriptor 1 at /dev/null. The handshake pipe's reader is long gone,
so anything the runtime prints while saving must not reach it."
  (let ((fd (sb-posix:open "/dev/null" sb-posix:o-rdwr)))
    (sb-posix:dup2 fd 1)
    (when (/= fd 1) (sb-posix:close fd))))

(defun install-descriptor-placeholders ()
  "Cover every descriptor number in *STALE-DESCRIPTORS* that this process does
not have open with a descriptor on /dev/null, then clear the list.

A stale socket or stream object carried in the saved world still holds its old
descriptor number. Once that number is covered, closing or reading the stale
object touches /dev/null, never a file or socket this process opened since.

Returns two values: how many numbers were covered, and the numbers that were
already open in this process and so were left alone. Nothing is logged here,
because this runs before logging is set up; the caller reports both values."
  (let ((covered 0) (in-use '()))
    (when *stale-descriptors*
      (let* ((low (sb-posix:open "/dev/null" sb-posix:o-rdwr))
             (high (sb-posix:fcntl low sb-posix:f-dupfd *placeholder-floor*)))
        (sb-posix:close low)
        (unwind-protect
             (dolist (fd *stale-descriptors*)
               (cond ((%descriptor-open-p fd) (push fd in-use))
                     (t (sb-posix:dup2 high fd) (incf covered))))
          (sb-posix:close high))))
    (setf *stale-descriptors* nil)
    (values covered (nreverse in-use))))

;;; ---------------------------------------------------------------------------
;;; Threads
;;; ---------------------------------------------------------------------------

(defun %blocking-threads ()
  "Threads other than the current one, the parent watchdog and SBCL's own
finalizer thread. Any of these makes a save impossible."
  (let ((finalizer (and (boundp 'sb-impl::*finalizer-thread*)
                        (typep (symbol-value 'sb-impl::*finalizer-thread*)
                               'sb-thread:thread)
                        (symbol-value 'sb-impl::*finalizer-thread*))))
    (remove-if (lambda (th)
                 (or (eq th sb-thread:*current-thread*)
                     (eq th finalizer)
                     (equal (sb-thread:thread-name th) "parent-watchdog")))
               (sb-thread:list-all-threads))))

;;; ---------------------------------------------------------------------------
;;; The save
;;; ---------------------------------------------------------------------------

(defun %child-save (tmp toplevel)
  "In the forked child: record and close inherited descriptors, keep the
runtime off the handshake pipe, make the file private, and save the world to
TMP with TOPLEVEL as its entry point. Never returns."
  (handler-case
      (progn
        (setf *stale-descriptors* (%close-inherited-descriptors))
        (%silence-stdout)
        (sb-posix:umask #o077)
        (sb-ext:save-lisp-and-die tmp :toplevel toplevel
                                      :executable nil
                                      :purify t))
    (serious-condition ()
      (sb-ext:exit :code 3 :abort t)))
  (sb-ext:exit :code 3 :abort t))

(defun %delete-quietly (native)
  "Remove the file NATIVE if it is there; a missing file or a directory is
left as it is."
  (ignore-errors (sb-posix:unlink native)))

(defun %describe-status (status)
  "A short description of a waitpid STATUS."
  (cond ((sb-posix:wifexited status)
         (format nil "status ~D" (sb-posix:wexitstatus status)))
        ((sb-posix:wifsignaled status)
         (format nil "signal ~D" (sb-posix:wtermsig status)))
        (t (format nil "raw status ~D" status))))

(defun %wait-for-child (pid deadline-seconds)
  "Poll the child PID until it exits or DEADLINE-SECONDS pass. Returns the
waitpid status, or NIL when the deadline passed and the child was killed and
reaped."
  (let ((limit (+ (get-internal-real-time)
                  (* deadline-seconds internal-time-units-per-second))))
    (loop
      (multiple-value-bind (done status) (sb-posix:waitpid pid sb-posix:wnohang)
        (when (and done (= done pid))
          (return status)))
      (when (>= (get-internal-real-time) limit)
        (ignore-errors (sb-posix:kill pid sb-posix:sigkill))
        (ignore-errors (sb-posix:waitpid pid 0))
        (return nil))
      (sleep 0.05))))

(defun %file-size (native)
  "Size in bytes of the file NATIVE, or NIL when it is not a regular file."
  (let ((st (%lstat native)))
    (and st (sb-posix:s-isreg (sb-posix:stat-mode st)) (sb-posix:stat-size st))))

(defun %deadline (params)
  "The save deadline in seconds from PARAMS, else the default."
  (let ((v (and params (gethash "deadline_seconds" params))))
    (if (and (integerp v) (plusp v)) v *default-deadline-seconds*)))

(defun %fork-refusal-token (condition)
  "The refusal word for a fork that signalled CONDITION: has-threads when SBCL
refused because other threads are running, fork-failed for anything else, such
as the kernel being out of memory or processes. A session must never be told
it runs threads when the host was only short of memory."
  (if (search "multiple threads" (princ-to-string condition))
      "has-threads"
      "fork-failed"))

(defun handle-hibernate (params server toplevel &key stop-watchdog start-watchdog)
  "Save this worker's world to the core file PARAMS names, then stop SERVER.

PARAMS holds \"path\", an absolute file name ending in .core inside the
hibernate directory, and optionally \"deadline_seconds\" (default 170).
TOPLEVEL is the function a process started from the core runs.
STOP-WATCHDOG and START-WATCHDOG stop and restart the parent watchdog thread.

On success the core is installed at the path, readable by the owner alone,
SERVER is stopped so the connection ends after this reply, and the result is
a table with \"hibernated\" true, \"path\", \"bytes\" and \"milliseconds\".

On failure the worker keeps serving, with its watchdog running, and the error
message begins with one of these tokens followed by a colon:
  bad-path     the path is not one the worker may write;
  has-threads  a thread the session started is running;
  fork-failed  the saving child could not be started, as when the host is
               out of memory or processes;
  save-failed  the saving child failed;
  save-timeout the saving child did not finish within the deadline."
  (let* ((started (get-internal-real-time))
         (target (%validate-target (and params (gethash "path" params))))
         (tmp (concatenate 'string target ".tmp"))
         (deadline (%deadline params)))
    (log-event :info "worker.hibernate.start" "path" target
               "deadline_seconds" deadline)
    (let ((others (%blocking-threads)))
      (when others
        (%refuse "has-threads" "~{~A~^, ~}"
                 (mapcar (lambda (th) (or (sb-thread:thread-name th) "unnamed"))
                         others))))
    (when stop-watchdog (funcall stop-watchdog))
    (flet ((recover ()
             (%delete-quietly tmp)
             (when start-watchdog (funcall start-watchdog))))
      (let ((pid (handler-case (sb-posix:fork)
                   (error (e)
                     (when start-watchdog (funcall start-watchdog))
                     (%refuse (%fork-refusal-token e) "~A" e)))))
        (when (zerop pid)
          (%child-save tmp toplevel))
        (let ((status (%wait-for-child pid deadline)))
          (cond
            ((null status)
             (recover)
             (%refuse "save-timeout" "~D" deadline))
            ((not (and (sb-posix:wifexited status)
                       (zerop (sb-posix:wexitstatus status))))
             (recover)
             (%refuse "save-failed" "~A" (%describe-status status)))
            ((not (plusp (or (%file-size tmp) 0)))
             (recover)
             (%refuse "save-failed" "the saved image is missing or empty"))
            (t
             (handler-case
                 (progn
                   (sb-posix:chmod tmp #o600)
                   (sb-posix:rename tmp target))
               (error (e)
                 (recover)
                 (%refuse "save-failed" "installing the image: ~A" e)))
             (let ((bytes (or (%file-size target) 0))
                   (ms (round (* 1000 (- (get-internal-real-time) started))
                              internal-time-units-per-second))
                   (result (make-hash-table :test 'equal)))
               (stop-server server)
               (log-event :info "worker.hibernate.saved"
                          "path" target "bytes" bytes "ms" ms)
               (setf (gethash "hibernated" result) t
                     (gethash "path" result) target
                     (gethash "bytes" result) bytes
                     (gethash "milliseconds" result) ms)
               result))))))))
