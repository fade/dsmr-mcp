;;;; src/bus/hostfiles.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; The files a host's bus watching is coordinated through, named in one place.
;;;;
;;;; Three programs read and write these files: the standalone watcher binary,
;;;; the MCP server an agent runs, and the host service that watches every
;;;; registered agent on the host. Each has to name the same file for the same
;;;; agent byte for byte, or a registration is written where the service never
;;;; looks and a heartbeat is read from where nobody writes it. One
;;;; implementation shared by all three is what keeps them from drifting, so the
;;;; per-identity file stem, the state paths, the host service's own records,
;;;; the fleet-log line and the stranded-cursor heal all live here.
;;;;
;;;; This is a leaf. It uses cl, uiop, sb-posix and four ZeroMQ-free bus leaves
;;;; (selector, cursor, wal and envelope), and nothing else. The watcher binary
;;;; is deployed on machines with no libzmq and must stay free of the ZeroMQ
;;;; transport while still reading the host service's records, so nothing that
;;;; reaches the broker or the transport may be added here.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-posix))

(defpackage #:dsmr-mcp/src/bus/hostfiles
  (:use #:cl)
  (:local-nicknames (#:selector #:dsmr-mcp/src/bus/selector)
                    (#:cursor #:dsmr-mcp/src/bus/cursor)
                    (#:wal #:dsmr-mcp/src/bus/wal)
                    (#:envelope #:dsmr-mcp/src/bus/envelope))
  (:export
   ;; paths
   #:state-home
   #:watch-state-dir
   #:watch-state-file
   #:host-dir
   #:ensure-host-dir
   #:register-dir
   #:degraded-dir
   #:service-pid-path
   #:service-beat-path
   #:service-state-path
   #:service-status-path
   #:service-lock-path
   #:clean-stop-path
   #:fleet-log-path
   ;; identity
   #:field-token
   #:normalise-agent-id
   #:agent-name
   #:identity-hash
   #:detach-stem
   ;; plist records
   #:read-plist-file
   #:write-plist-file
   ;; registration
   #:registration-path
   #:served-path
   #:write-registration
   #:read-registration
   #:remove-registration
   #:registration-stems
   #:write-served-ack
   #:read-served-ack
   ;; degraded buses
   #:degraded-path
   #:write-degraded-record
   #:read-degraded-record
   #:clear-degraded-record
   #:degraded-records
   ;; processes
   #:proc-starttime
   #:proc-cmdline
   #:process-matches-p
   #:session-from-environment
   ;; the service
   #:read-service-pid
   #:service-installed-p
   #:service-beat-age
   #:service-alive-p
   ;; fleet log
   #:fleet-line
   #:fleet-line-p
   #:append-fleet-line
   ;; stranded cursors
   #:heal-stranded-baseline))

(in-package #:dsmr-mcp/src/bus/hostfiles)

;;; --------------------------------------------------------------------- paths

(defun state-home ()
  "$XDG_STATE_HOME as a directory, falling back to ~/.local/state/."
  (let ((xdg (uiop:getenv "XDG_STATE_HOME")))
    (if (and xdg (plusp (length xdg)))
        (uiop:ensure-directory-pathname xdg)
        (merge-pathnames ".local/state/" (user-homedir-pathname)))))

(defun watch-state-dir ()
  "Where per-identity watch files live (logs, pid files, offsets, markers):
   dsmr-mcp/watch/ under the state home. One directory for every bus, so a
   single tail over *--<agent>--*.log follows an agent on all the buses it has
   joined."
  (merge-pathnames "dsmr-mcp/watch/" (state-home)))

(defun %file-in (dir name)
  "The file NAME in directory DIR, built from a native namestring so nothing in
   an agent or bus name can be read as a wildcard."
  (uiop:parse-native-namestring
   (concatenate 'string (uiop:native-namestring dir) name)))

(defun watch-state-file (stem type)
  "The file STEM.TYPE in the watch state directory, built from a native
   namestring so nothing in an agent name can be read as a wildcard."
  (%file-in (watch-state-dir) (concatenate 'string stem "." type)))

(defun host-dir ()
  "Where the host service keeps its own records: dsmr-mcp/host/ under the state
   home."
  (merge-pathnames "dsmr-mcp/host/" (state-home)))

(defun register-dir ()
  "Where agents leave their registrations for the host service, and where the
   service acknowledges them."
  (merge-pathnames "register/" (host-dir)))

(defun degraded-dir ()
  "Where a bus whose broker was elected by a client, rather than run by the
   host service, is recorded until order is restored."
  (merge-pathnames "degraded/" (host-dir)))

(defun ensure-host-dir ()
  "Create the host directory and its register/ and degraded/ subdirectories,
   readable by the owner alone, and return the host directory.

   The mode is set on every call, not only on creation, because these records
   name sessions and processes and a directory created earlier under a looser
   umask would otherwise stay readable to everyone."
  (dolist (dir (list (host-dir) (register-dir) (degraded-dir)))
    (ensure-directories-exist dir)
    (sb-posix:chmod (uiop:native-namestring dir) #o700))
  (host-dir))

(defun service-pid-path ()
  "The host service's pid file."
  (merge-pathnames "service.pid" (host-dir)))

(defun service-beat-path ()
  "The file whose modification time says the host service is still running."
  (merge-pathnames "service.beat" (host-dir)))

(defun service-state-path ()
  "The host service's state record. Its presence says the service is installed
   on this host."
  (merge-pathnames "service.state" (host-dir)))

(defun service-status-path ()
  "The host service's status summary, for probes that report on it."
  (merge-pathnames "service.status" (host-dir)))

(defun service-lock-path ()
  "The file the running host service holds a lock on, so a second copy cannot
   start beside it."
  (merge-pathnames "service.lock" (host-dir)))

(defun clean-stop-path ()
  "The marker a host service leaves when it stops on purpose, so the next start
   can tell a deliberate stop from a crash."
  (merge-pathnames "clean-stop" (host-dir)))

(defun fleet-log-path ()
  "The fleet error log: every fault that was not healed, one line per record,
   for fleet leaders to watch."
  (merge-pathnames "fleet-error.log" (host-dir)))

;;; ------------------------------------------------------------------ identity

(defun field-token (name)
  "NAME rendered safe to carry as one field on a signal line: whitespace, a
   comma, an equals sign and any control character each become an underscore.

   A bus name is an ordinary bare word and passes through untouched. A namespace
   is a project root, though, and a path carrying a space would otherwise split
   one name across two fields and make the line lie about who published. The
   comma separates names within a field and the equals sign introduces one, so
   neither can be allowed to occur inside a name either."
  (map 'string
       (lambda (ch)
         (if (or (char<= ch #\Space) (char= ch #\,) (char= ch #\=))
             #\_
             ch))
       name))

(defun normalise-agent-id (id)
  "ID with every run of separators collapsed to one and any trailing separator
   removed, or NIL for NIL.

   A doubled separator names the same agent as a single one, but every file a
   watcher keeps (cursor, heartbeat, log, pid file) is named from the id, so a
   second spelling would be a second set of files, and a probe typed with it
   would read a healthy agent as dead."
  (when id
    (let ((out (make-string-output-stream))
          (previous-separator-p nil))
      (loop for ch across id
            do (let ((separator-p (char= ch #\/)))
                 (unless (and separator-p previous-separator-p)
                   (write-char ch out))
                 (setf previous-separator-p separator-p)))
      (let ((collapsed (get-output-stream-string out)))
        (if (and (> (length collapsed) 1)
                 (char= (char collapsed (1- (length collapsed))) #\/))
            (subseq collapsed 0 (1- (length collapsed)))
            collapsed)))))

(defun agent-name (self-id)
  "The name part of the full bus id SELF-ID."
  (nth-value 1 (envelope:split-agent-id self-id)))

(defun identity-hash (string)
  "The 32-bit FNV-1a hash of STRING's character codes, as eight lowercase hex
   digits.

   The hash names files that outlive the binary that wrote them, and a later
   build has to find them again, so it is computed here from first principles
   rather than with SXHASH or any other function whose value an implementation
   is free to change between builds."
  (let ((hash 2166136261))
    (loop for ch across string
          do (setf hash (ldb (byte 32 0)
                             (* (logxor hash (char-code ch)) 16777619))))
    (format nil "~(~8,'0X~)" hash)))

(defun detach-stem (bus self-id)
  "The file stem for the watch of the full bus id SELF-ID on BUS:
   <bus>--<agent>--<hash>, with `default` standing for the unnamed bus.

   The agent name stays readable so an operator can find a log by eye. The hash
   is of the whole normalised id (see IDENTITY-HASH), so two agents with the
   same name in different namespaces get separate files and separate reader
   counts, and a namespace of any length adds only eight characters."
  (let ((id (normalise-agent-id self-id)))
    (format nil "~A--~A--~A"
            (field-token (or bus "default"))
            (field-token (agent-name id))
            (identity-hash id))))

;;; ------------------------------------------------------------ plist records

(defun %plain-text (value)
  "VALUE with every string inside it held as a full CHARACTER string.

   An ASCII string can come back from this implementation as a base string,
   which prints readably as an array literal rather than a plain string. A
   record a person reads at a glance is worth the coercion."
  (typecase value
    (string (map '(simple-array character (*)) #'identity value))
    (cons (cons (%plain-text (car value)) (%plain-text (cdr value))))
    (t value)))

(defun %proper-plist-p (form)
  "True when FORM is a proper list of even length whose keys are keywords."
  (and (listp form)
       (let ((length (ignore-errors (list-length form))))
         (and length (evenp length)))
       (loop for key in form by #'cddr always (keywordp key))))

(defun %owned-by-me-p (path)
  "True when PATH is owned by the uid this process runs as."
  (= (sb-posix:stat-uid (sb-posix:stat (uiop:native-namestring path)))
     (sb-posix:getuid)))

(defun read-plist-file (path &key (max-bytes 8192))
  "The plist stored at PATH, and a status saying how the read went: :OK with the
   plist, :ABSENT when there is no file, or :UNREADABLE with NIL.

   Absent and unreadable are kept apart because they need different handling:
   a missing registration means nobody registered, a damaged one means someone
   did and the record cannot be trusted.

   Unreadable covers a file over MAX-BYTES, a file owned by another user,
   anything that does not read as a plist with keyword keys, and an empty file.
   The read runs under standard io syntax with *READ-EVAL* off, because these
   files sit under a state root other processes can write, and looking at one
   must never run code planted in it."
  (handler-case
      (if (not (probe-file path))
          (values nil :absent)
          (let ((stat (sb-posix:stat (uiop:native-namestring path))))
            (if (or (> (sb-posix:stat-size stat) max-bytes)
                    (not (%owned-by-me-p path)))
                (values nil :unreadable)
                (let* ((eof '#:eof)
                       (form (with-standard-io-syntax
                               (let ((*read-eval* nil))
                                 (with-open-file (in path :if-does-not-exist nil)
                                   (if in (read in nil eof) eof))))))
                  (if (and (not (eq form eof)) (%proper-plist-p form))
                      (values form :ok)
                      (values nil :unreadable))))))
    (error () (values nil :unreadable))))

(defun write-plist-file (path plist)
  "Write PLIST to PATH, readable by its owner alone, and return what landed.

   The new contents go to a scratch file in the same directory, which is then
   renamed over PATH, so a reader in another process sees the old record or the
   new one and never a half-written file. A failed write removes the scratch
   file and leaves the previous record intact. Signals on failure."
  (ensure-directories-exist path)
  (let ((plain (%plain-text plist))
        (temp (%file-in (uiop:pathname-directory-pathname path)
                        (format nil ".~A.tmp~D" (file-namestring path)
                                (random 100000000)))))
    (unwind-protect
         (progn
           (with-open-file (out temp :direction :output
                                     :if-exists :supersede
                                     :if-does-not-exist :create)
             (with-standard-io-syntax
               (prin1 plain out))
             (finish-output out))
           (sb-posix:chmod (uiop:native-namestring temp) #o600)
           ;; A native rename, because RENAME-FILE merges the scratch name's
           ;; type into a target that has none (degraded/default would land as
           ;; default.tmpNNN).
           (sb-posix:rename (uiop:native-namestring temp)
                            (uiop:native-namestring path))
           (setf temp nil))
      (when temp (ignore-errors (delete-file temp))))
    plain))

;;; -------------------------------------------------------------- registration

(defun %unix-time ()
  "Now, as seconds since the Unix epoch."
  (- (get-universal-time) 2208988800))

(defun registration-path (stem)
  "The registration file an agent leaves for the host service under STEM."
  (%file-in (register-dir) (concatenate 'string stem ".reg")))

(defun served-path (stem)
  "The file the host service writes to acknowledge the registration under STEM."
  (%file-in (register-dir) (concatenate 'string stem ".served")))

(defun write-registration (stem plist)
  "Register an agent with the host service: write PLIST as the registration
   under STEM, creating the host directory first. Keys: :ID :BUS :POLL-MS
   :RECYCLE-SECONDS :DEAF-SECONDS :SESSION-PID :SESSION-START :TOKEN
   :REGISTERED-AT :CLI-VERSION."
  (ensure-host-dir)
  (write-plist-file (registration-path stem) plist))

(defun read-registration (path)
  "The registration at PATH and its read status, as READ-PLIST-FILE answers."
  (read-plist-file path))

(defun remove-registration (stem)
  "Remove the registration under STEM and any acknowledgement of it. True when a
   registration file was there to remove, so a caller can tell a deregistration
   from a repeat of one."
  (let ((removed (and (probe-file (registration-path stem))
                      (delete-file (registration-path stem))
                      t)))
    (ignore-errors (when (probe-file (served-path stem))
                     (delete-file (served-path stem))))
    removed))

(defun registration-stems ()
  "The stems that have a registration file, sorted."
  (let ((suffix ".reg"))
    (sort (loop for file in (ignore-errors (uiop:directory-files (register-dir)))
                for name = (file-namestring file)
                when (and (> (length name) (length suffix))
                          (string= suffix name :start2 (- (length name) (length suffix))))
                  collect (subseq name 0 (- (length name) (length suffix))))
          #'string<)))

(defun write-served-ack (stem token pid)
  "Acknowledge the registration under STEM: the service with PID is serving the
   registration that carried TOKEN. :SERVED-AT is Unix seconds."
  (ensure-host-dir)
  (write-plist-file (served-path stem)
                    (list :token token :pid pid :served-at (%unix-time))))

(defun read-served-ack (stem)
  "The acknowledgement of the registration under STEM and its read status."
  (read-plist-file (served-path stem)))

;;; ----------------------------------------------------------- degraded buses

(defun %bus-token (bus)
  "The file name a degraded record for BUS is kept under: `default` for the
   unnamed bus, and otherwise the validated bus name. `default` is reserved and
   cannot be a real bus name, so it is accepted here as the unnamed bus and a
   name read back from DEGRADED-RECORDS finds its record again."
  (if (or (null bus) (zerop (length bus)) (string= bus "default"))
      "default"
      (field-token (selector:validate-bus-name bus))))

(defun degraded-path (bus)
  "The record that says BUS is degraded. Signals INVALID-BUS-NAME for a bus
   name that could not name a bus, so no name can reach outside the directory."
  (%file-in (degraded-dir) (%bus-token bus)))

(defun write-degraded-record (bus plist)
  "Record BUS as degraded. Keys: :BUS :ROOT :INCUMBENT-PID :INCUMBENT-START
   :PPID-AT-START :STARTED-AT :IMAGE :DETECTED-AT."
  (ensure-host-dir)
  (write-plist-file (degraded-path bus) plist))

(defun read-degraded-record (bus)
  "The degraded record for BUS and its read status."
  (read-plist-file (degraded-path bus)))

(defun clear-degraded-record (bus)
  "Remove BUS's degraded record. True when there was one to remove."
  (let ((path (degraded-path bus)))
    (and (probe-file path) (delete-file path) t)))

(defun degraded-records ()
  "Every readable degraded record, as a list of (BUS . PLIST) where BUS is the
   record's file name, `default` for the unnamed bus. Unreadable records are
   left out."
  (loop for file in (sort (ignore-errors (uiop:directory-files (degraded-dir)))
                          #'string< :key #'file-namestring)
        for name = (file-namestring file)
        unless (char= (char name 0) #\.)
          append (multiple-value-bind (plist status) (read-plist-file file)
                   (when (eq status :ok)
                     (list (cons name plist))))))

;;; ---------------------------------------------------------------- processes

(defun %proc-file (pid name)
  "The text of /proc/PID/NAME, or NIL where there is no such file."
  (ignore-errors
   (uiop:read-file-string (format nil "/proc/~D/~A" pid name))))

(defun %stat-fields (pid)
  "The fields of /proc/PID/stat after the command name, as strings, the first
   being field 3 (the state letter). The command name is parenthesised and may
   hold spaces or parentheses itself, so the split starts after the LAST close
   parenthesis. NIL when there is no such process."
  (let* ((stat (and (integerp pid) (plusp pid) (%proc-file pid "stat")))
         (close (and stat (position #\) stat :from-end t))))
    (when close
      (remove "" (uiop:split-string (subseq stat (1+ close)) :separator " ")
              :test #'string=))))

(defun proc-starttime (pid)
  "When PID started, in clock ticks since boot (field 22 of /proc/PID/stat), or
   NIL when there is no such process. A pid can be reused; a pid with its start
   time cannot, which is what makes the pair an identity."
  (let ((field (nth 19 (%stat-fields pid))))
    (and field (ignore-errors (parse-integer field)))))

(defun %proc-ppid (pid)
  "The parent of PID (field 4 of /proc/PID/stat), or NIL."
  (let ((field (nth 1 (%stat-fields pid))))
    (and field (ignore-errors (parse-integer field)))))

(defun proc-cmdline (pid)
  "PID's argument vector as a list of strings, or NIL when there is no such
   process or it has none (a kernel thread)."
  (let ((text (and (integerp pid) (plusp pid) (%proc-file pid "cmdline"))))
    (when (and text (plusp (length text)))
      (let ((args (uiop:split-string text :separator (string (code-char 0)))))
        (if (and args (string= (car (last args)) ""))
            (butlast args)
            args)))))

(defun process-matches-p (pid starttime)
  "True when PID is running and is the process that started at STARTTIME, not
   some later process handed the same pid."
  (and pid starttime
       (eql (proc-starttime pid) starttime)))

(defun session-from-environment ()
  "The agent session this process belongs to, as two values: its pid and its
   start time, or NIL and NIL when none can be found.

   CLAUDE_PID is believed first, when it names a live process. Otherwise the
   nearest ancestor whose command name is `claude` is taken. A registration is
   only as good as the session it names: the host service drops it when that
   process goes, so a guess is worse than no answer."
  (let* ((named (ignore-errors (parse-integer (or (uiop:getenv "CLAUDE_PID") ""))))
         (named-start (and named (proc-starttime named))))
    (if named-start
        (values named named-start)
        (loop for steps from 0 below 64
              for pid = (sb-posix:getppid) then (%proc-ppid pid)
              while (and pid (> pid 1))
              when (let ((comm (%proc-file pid "comm")))
                     (and comm (string= (string-right-trim '(#\Newline) comm)
                                        "claude")))
                do (let ((start (proc-starttime pid)))
                     (when start (return (values pid start))))
              finally (return (values nil nil))))))

;;; ---------------------------------------------------------------- the service

(defun read-service-pid ()
  "The pid in the host service's pid file, or NIL when there is none."
  (let ((first (first (ignore-errors (uiop:read-file-lines (service-pid-path))))))
    (and first (ignore-errors (parse-integer first :junk-allowed t)))))

(defun service-installed-p ()
  "True when the host service is installed here: it keeps a state record."
  (and (probe-file (service-state-path)) t))

(defun service-beat-age ()
  "Seconds since the host service last beat, or NIL when it has no beat file."
  (let ((written (ignore-errors (file-write-date (service-beat-path)))))
    (and written (max 0 (- (get-universal-time) written)))))

(defun %pid-exists-p (pid)
  "True when a process PID exists, whoever owns it."
  (handler-case (progn (sb-posix:kill pid 0) t)
    (sb-posix:syscall-error (e)
      (/= (sb-posix:syscall-errno e) sb-posix:esrch))))

(defun service-alive-p (&key (window 5))
  "True when the host service beat within WINDOW seconds and the pid it
   recorded, if any, is still a running process. A fresh beat from a process
   that has since died is not a live service."
  (let ((age (service-beat-age))
        (pid (read-service-pid)))
    (and age (<= age window)
         (or (null pid) (%pid-exists-p pid))
         t)))

;;; ----------------------------------------------------------------- fleet log

(defun %iso-utc (universal-time)
  "UNIVERSAL-TIME as 2026-10-12T16:30:00Z."
  (multiple-value-bind (s mi h d mo y) (decode-universal-time universal-time 0)
    (format nil "~4,'0D-~2,'0D-~2,'0DT~2,'0D:~2,'0D:~2,'0DZ" y mo d h mi s)))

(defun %level-word (level)
  "LEVEL as the word a fleet line carries. Signals for anything but an error, a
   warning or a note, since a leader's watch filters on exactly these three."
  (let ((word (string-upcase (string level))))
    (unless (member word '("ERROR" "WARN" "INFO") :test #'string=)
      (error "A fleet line's level is ERROR, WARN or INFO, not ~S." level))
    word))

(defun %field-or-dash (value)
  "VALUE as one field, or `-` when there is none."
  (if (or (null value) (and (stringp value) (zerop (length value))))
      "-"
      (field-token (princ-to-string value))))

(defun fleet-line (level code &key bus id msg (time (get-universal-time)))
  "One fleet-log line, without its newline:
   <ISO-8601 UTC> FLEET <LEVEL> code=<code> bus=<bus> id=<id> msg=<text>.

   Each field before the message is one token, so a leader's watch can grep for
   a code, a bus or an identity and never be split by a space in a project
   path; an absent bus or identity reads `-`. The message runs to the end of the
   line and any control character in it becomes a space, so one record is
   always one line."
  (format nil "~A FLEET ~A code=~A bus=~A id=~A msg=~A"
          (%iso-utc time)
          (%level-word level)
          (%field-or-dash code)
          (%field-or-dash bus)
          (%field-or-dash id)
          (map 'string (lambda (ch)
                         (if (or (< (char-code ch) 32) (= (char-code ch) 127))
                             #\Space
                             ch))
               (if msg (princ-to-string msg) ""))))

(defun fleet-line-p (line)
  "True when LINE is a fleet-log line."
  (and (search " FLEET " line) t))

(defun append-fleet-line (line &optional (path (fleet-log-path)))
  "Append LINE and a newline to the fleet log at PATH in a single write on a
   descriptor opened for appending, creating the host directory first.

   One write on an appending descriptor is what keeps lines from the service,
   the watcher and the MCP server whole when they land at the same moment;
   a buffered stream may split a long line across several writes, and another
   writer's line could land between them."
  (if (equal (namestring path) (namestring (fleet-log-path)))
      (ensure-host-dir)
      (ensure-directories-exist path))
  (let* ((octets (sb-ext:string-to-octets (concatenate 'string line (string #\Newline))
                                          :external-format :utf-8))
         (fd (sb-posix:open (uiop:native-namestring path)
                            (logior sb-posix:o-wronly sb-posix:o-append
                                    sb-posix:o-creat)
                            #o600)))
    (unwind-protect
         (sb-sys:with-pinned-objects (octets)
           (let ((written (sb-posix:write fd (sb-sys:vector-sap octets)
                                          (length octets))))
             (unless (= written (length octets))
               (error "Only ~D of ~D bytes reached the fleet log ~A."
                      written (length octets) (namestring path)))))
      (sb-posix:close fd)))
  line)

;;; ---------------------------------------------------------- stranded cursors

(defun %cursor-holds-seq-p (path)
  "True only when PATH exists and holds a readable non-negative integer. The
   canonical reader answers 0 for a missing file, and 0 here would read as a
   whole log's worth of pending records."
  (and (probe-file path)
       (ignore-errors
        (with-open-file (in path :if-does-not-exist nil)
          (let ((value (and in (with-standard-io-syntax
                                 (let ((*read-eval* nil)) (read in nil nil))))))
            (and (integerp value) (>= value 0) t))))))

(defun %newest-archive (wal-path)
  "The newest archive of WAL-PATH beside it (<log>.archive-<ms>), or NIL."
  (let ((prefix (concatenate 'string (file-namestring wal-path) ".archive-"))
        (best nil)
        (best-stamp -1))
    (dolist (file (ignore-errors
                   (uiop:directory-files (uiop:pathname-directory-pathname wal-path))))
      (let ((name (file-namestring file)))
        (when (uiop:string-prefix-p prefix name)
          (let ((stamp (ignore-errors (parse-integer name :start (length prefix)))))
            (when (and stamp (> stamp best-stamp))
              (setf best file best-stamp stamp))))))
    best))

(defun %unread-in-archive (wal-path old-cursor)
  "How many records the newest archive of WAL-PATH held above OLD-CURSOR, or NIL
   when there is no readable archive."
  (let ((archive (%newest-archive wal-path)))
    (when archive
      (let ((head (ignore-errors (wal:scan archive))))
        (and (integerp head) (max 0 (- head old-cursor)))))))

(defun heal-stranded-baseline (self-id wal-path cursor-path &key (rebase-p t))
  "The baseline a watch of SELF-ID should arm at, taken from its cursor at
   CURSOR-PATH over the log at WAL-PATH, as three values: the baseline, the
   action taken and a report.

   ACTION is one of:
     :SOUND      the cursor is a position in this log; it is the baseline.
     :REBASED    the cursor was stranded and has been rewritten.
     :CLAMPED    the cursor was stranded and the rewrite was refused or failed;
                 the baseline is the log head and the cursor file is unchanged.
     :NO-CURSOR  there is no readable cursor; the baseline is NIL and the caller
                 arms at the head as it would have anyway.

   A stranded cursor is above the head of the log, or was recorded against a
   different generation of it. Used as a baseline it filters out every record
   in the new log, so the agent hears nothing while every probe calls it
   healthy. Rewriting the cursor is the only repair that lets mail already in
   the new log wake the agent, so it is done here, and only when the cursor is
   provably stranded. It moves to 0 when the log it named is gone (the new log
   is wholly owed), or to the head when the same log was shortened under it.
   With REBASE-P false, or when the rewrite fails, the baseline clamps to the
   head instead: never silence, at worst a missed backlog that the report
   names.

   The rewrite discards the only record of the old position, so the REPORT
   carries it for the caller to log before anything else: :ID :REASON
   :OLD-CURSOR :OLD-GENERATION :GENERATION :HEAD :UNREAD-IN-ARCHIVE, where the
   last is how many records the newest archive held above the old position, or
   NIL when no archive can be read."
  (let ((report (list :id self-id :reason nil :old-cursor nil :old-generation nil
                      :generation nil :head nil :unread-in-archive nil)))
    (unless (%cursor-holds-seq-p cursor-path)
      (return-from heal-stranded-baseline (values nil :no-cursor report)))
    (let* ((subscriber (cursor:make-subscriber self-id wal-path cursor-path))
           (head (wal:scan wal-path))
           (generation (wal:generation wal-path)))
      (multiple-value-bind (value read-head recorded)
          (cursor:cursor-and-head subscriber :head head :log-generation generation)
        (declare (ignore read-head))
        (let ((reason (cursor:stranded-reason subscriber :head head
                                                         :log-generation generation)))
          (setf (getf report :reason) reason
                (getf report :old-cursor) value
                (getf report :old-generation) recorded
                (getf report :generation) generation
                (getf report :head) head)
          (unless reason
            (return-from heal-stranded-baseline (values value :sound report)))
          (setf (getf report :unread-in-archive) (%unread-in-archive wal-path value))
          (let ((target (if (and (eq reason :cursor-above-head)
                                 recorded (= recorded generation))
                            head
                            0)))
            (if (not rebase-p)
                (values head :clamped report)
                (handler-case
                    (progn
                      (setf (cursor:cursor-value subscriber) target)
                      (values target :rebased report))
                  (error (e)
                    (values head :clamped
                            (append report (list :error (princ-to-string e)))))))))))))
