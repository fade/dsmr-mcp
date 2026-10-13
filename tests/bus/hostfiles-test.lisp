;;;; tests/bus/hostfiles-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Zebra tests for the shared host-file leaf: the names the watcher, the MCP
;;;; server and the host service give the files they share, the safe plist
;;;; records under the host directory, the fleet-log line, the process identity
;;;; probes and the stranded-cursor heal. Every fixture lives under a temporary
;;;; state home or a temporary bus root and is removed afterwards, so nothing
;;;; here touches a live fleet's files.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/bus/hostfiles-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/bus/hostfiles-test
  (:use #:cl #:zebra)
  (:local-nicknames (#:hostfiles #:dsmr-mcp/src/bus/hostfiles)
                    (#:wal #:dsmr-mcp/src/bus/wal)))

(in-package #:dsmr-mcp/tests/bus/hostfiles-test)

;;; ------------------------------------------------------------------ fixtures

(defun fresh-temp-dir (prefix)
  "A new empty directory under the system temp directory."
  (let ((name (uiop:with-temporary-file (:pathname p :keep t :prefix prefix) p)))
    (ignore-errors (delete-file name))
    (let ((dir (uiop:ensure-directory-pathname name)))
      (ensure-directories-exist dir)
      dir)))

(defmacro with-temp-dir ((var &optional (prefix "dsmr-hostfiles")) &body body)
  "Bind VAR to a fresh temporary directory, deleted with its contents after."
  `(let ((,var (fresh-temp-dir ,prefix)))
     (declare (ignorable ,var))
     (unwind-protect (progn ,@body)
       (ignore-errors (uiop:delete-directory-tree
                       ,var :validate t :if-does-not-exist :ignore)))))

(defmacro with-env ((name value) &body body)
  "Run BODY with the environment variable NAME set to VALUE, restoring it after."
  (let ((previous (gensym "PREVIOUS")))
    `(let ((,previous (uiop:getenv ,name)))
       (unwind-protect
            (progn (sb-posix:setenv ,name ,value 1) ,@body)
         (if ,previous
             (sb-posix:setenv ,name ,previous 1)
             (ignore-errors (sb-posix:unsetenv ,name)))))))

(defmacro with-state-home ((var) &body body)
  "Bind VAR to a fresh temporary directory and run BODY with XDG_STATE_HOME
   pointing at it, so every host file lands there and nowhere else."
  `(with-temp-dir (,var "dsmr-hostfiles-state")
     (with-env ("XDG_STATE_HOME" (namestring ,var))
       ,@body)))

(defun write-text (path text)
  "Replace PATH with TEXT."
  (ensure-directories-exist path)
  (with-open-file (out path :direction :output :if-exists :supersede
                            :if-does-not-exist :create)
    (write-string text out))
  path)

(defun read-text (path)
  "The whole of PATH as a string."
  (uiop:read-file-string path))

(defun make-log (dir generation count &key (name "bus.wal"))
  "A log under DIR holding COUNT records numbered from 1, recorded at
   GENERATION. Returns the log's path."
  (let ((log (merge-pathnames name dir)))
    (loop for seq from 1 to count
          do (wal:append-record log seq "from another agent"))
    (write-text (wal:generation-path log) (format nil "~D" generation))
    log))

(defun mode-bits (path)
  "The permission bits of PATH."
  (logand #o777 (sb-posix:stat-mode (sb-posix:stat (uiop:native-namestring path)))))

;;; ------------------------------------------------------------------ identity

(define-test detach-stem-reads-agent-name-and-hashes-whole-id
  "The stem keeps the agent name readable and appends a hash of the whole
   normalised id, so two agents of one name in different projects get different
   files. These literal stems are what the watcher wrote before the derivation
   moved, and files on disk are named by them."
  (let ((stem (hostfiles:detach-stem "dsmr-mcp" "/home/x/proj/boomer")))
    (is string= (format nil "dsmr-mcp--boomer--~A"
                        (hostfiles:identity-hash "/home/x/proj/boomer"))
        stem)
    (is = (+ (length "dsmr-mcp--boomer--") 8) (length stem))
    (isnt string= stem (hostfiles:detach-stem "dsmr-mcp" "/home/y/proj/boomer"))
    (is string= "default--boomer--"
        (subseq (hostfiles:detach-stem nil "/home/x/proj/boomer") 0 17))))

(define-test a-doubled-separator-names-the-same-files
  "A doubled or trailing separator spells the same agent, so it must name the
   same files."
  (is string= (hostfiles:detach-stem "dsmr-mcp" "/home/x/proj/boomer")
      (hostfiles:detach-stem "dsmr-mcp" "/home//x/proj//boomer"))
  (is string= "/home/x/proj" (hostfiles:normalise-agent-id "/home//x/proj/"))
  (is eq nil (hostfiles:normalise-agent-id nil))
  (is string= "boomer" (hostfiles:agent-name "/home/x/proj/boomer")))

(define-test the-identity-hash-is-fixed-across-builds
  "The hash names files a later build must find again, so its value is pinned
   here against the FNV-1a reference values."
  (is string= "811c9dc5" (hostfiles:identity-hash ""))
  (is string= "e40c292c" (hostfiles:identity-hash "a")))

(define-test field-token-keeps-one-name-in-one-field
  "Whitespace, comma, equals and control characters cannot survive into a
   field, or one name would split across two."
  (is string= "a_b_c_d_e" (hostfiles:field-token (format nil "a b,c=d~Ce" #\Tab)))
  (is string= "dsmr-mcp" (hostfiles:field-token "dsmr-mcp")))

;;; --------------------------------------------------------------------- paths

(define-test the-state-paths-sit-under-the-state-home
  "Every host file is named under XDG_STATE_HOME, so a test or a second user
   never sees another's records."
  (with-state-home (home)
    (let ((root (namestring home)))
      (is string= (concatenate 'string root "dsmr-mcp/watch/")
          (namestring (hostfiles:watch-state-dir)))
      (is string= (concatenate 'string root "dsmr-mcp/host/")
          (namestring (hostfiles:host-dir)))
      (is string= (concatenate 'string root "dsmr-mcp/watch/a--b--c.log")
          (namestring (hostfiles:watch-state-file "a--b--c" "log")))
      (is string= (concatenate 'string root "dsmr-mcp/host/fleet-error.log")
          (namestring (hostfiles:fleet-log-path)))
      (is string= (concatenate 'string root "dsmr-mcp/host/register/s.reg")
          (namestring (hostfiles:registration-path "s")))
      (is string= (concatenate 'string root "dsmr-mcp/host/register/s.served")
          (namestring (hostfiles:served-path "s")))
      (dolist (path (list (hostfiles:service-pid-path) (hostfiles:service-beat-path)
                          (hostfiles:service-state-path) (hostfiles:service-status-path)
                          (hostfiles:service-lock-path) (hostfiles:clean-stop-path)))
        (true (uiop:string-prefix-p (namestring (hostfiles:host-dir))
                                    (namestring path)))))))

(define-test ensure-host-dir-creates-private-directories
  "The host directory and its two subdirectories are created readable by the
   owner alone, since registrations name sessions and processes."
  (with-state-home (home)
    (is equal (namestring (hostfiles:host-dir))
        (namestring (hostfiles:ensure-host-dir)))
    (dolist (dir (list (hostfiles:host-dir) (hostfiles:register-dir)
                       (hostfiles:degraded-dir)))
      (true (uiop:directory-exists-p dir))
      (is = #o700 (mode-bits dir)))))

;;; -------------------------------------------------------------- plist files

(define-test read-plist-file-tells-absent-from-damaged
  "A missing file and a damaged one need different handling, so they answer
   differently."
  (with-temp-dir (dir)
    (let ((path (merge-pathnames "r.plist" dir)))
      (is eq :absent (nth-value 1 (hostfiles:read-plist-file path)))
      (write-text path "(:a 1 :b \"two\")")
      (multiple-value-bind (plist status) (hostfiles:read-plist-file path)
        (is eq :ok status)
        (is equal '(:a 1 :b "two") plist))
      (write-text path "(:a 1 :b)")
      (is eq :unreadable (nth-value 1 (hostfiles:read-plist-file path))
          "an odd-length list is not a plist")
      (write-text path "")
      (is eq :unreadable (nth-value 1 (hostfiles:read-plist-file path))
          "an empty file is damage, not an empty record")
      (write-text path "(:a #.(error \"evaluated\"))")
      (is eq :unreadable (nth-value 1 (hostfiles:read-plist-file path))))))

(define-test read-plist-file-never-evaluates-what-it-reads
  "The state directory is writable by other processes, so reading a record must
   not run code planted in it."
  (with-temp-dir (dir)
    (let ((path (merge-pathnames "r.plist" dir))
          (probe (intern "HOSTFILES-READ-EVAL-PROBE" "CL-USER")))
      (makunbound probe)
      (write-text path (format nil "(:a #.(progn (setf (symbol-value '~S) t) 1))"
                               probe))
      (is eq :unreadable (nth-value 1 (hostfiles:read-plist-file path)))
      (false (boundp probe) "the planted form did not run"))))

(define-test read-plist-file-refuses-an-oversized-file
  "A record past the size cap is refused rather than read."
  (with-temp-dir (dir)
    (let ((path (merge-pathnames "r.plist" dir)))
      (write-text path (format nil "(:a ~S)" (make-string 200 :initial-element #\x)))
      (is eq :ok (nth-value 1 (hostfiles:read-plist-file path)))
      (is eq :unreadable
          (nth-value 1 (hostfiles:read-plist-file path :max-bytes 64))))))

(define-test write-plist-file-replaces-privately
  "A written record reads back as written and is readable by its owner alone."
  (with-temp-dir (dir)
    (let ((path (merge-pathnames "w.plist" dir)))
      (hostfiles:write-plist-file path '(:x 1 :y "why"))
      (is equal '(:x 1 :y "why") (hostfiles:read-plist-file path))
      (is = #o600 (mode-bits path))
      (hostfiles:write-plist-file path '(:x 2))
      (is equal '(:x 2) (hostfiles:read-plist-file path))
      (is = 1 (length (uiop:directory-files dir)) "no scratch file is left behind"))))

;;; --------------------------------------------------------------- registration

(define-test a-registration-round-trips-every-key
  "Every key a registration carries survives the write and the read, and the
   stem is listed while the file exists."
  (with-state-home (home)
    (let ((record (list :id "/home/x/proj/boomer" :bus "dsmr-mcp" :poll-ms 250
                        :recycle-seconds 3600 :deaf-seconds 900
                        :session-pid 4242 :session-start 123456
                        :token "tok-1" :registered-at 1790000000
                        :cli-version "0.1.0")))
      (hostfiles:write-registration "dsmr-mcp--boomer--1234abcd" record)
      (multiple-value-bind (plist status)
          (hostfiles:read-registration
           (hostfiles:registration-path "dsmr-mcp--boomer--1234abcd"))
        (is eq :ok status)
        (loop for (key value) on record by #'cddr
              do (is equal value (getf plist key) "key ~S" key)))
      (is equal '("dsmr-mcp--boomer--1234abcd") (hostfiles:registration-stems))
      (true (hostfiles:remove-registration "dsmr-mcp--boomer--1234abcd"))
      (false (hostfiles:remove-registration "dsmr-mcp--boomer--1234abcd"))
      (is equal '() (hostfiles:registration-stems)))))

(define-test a-served-ack-round-trips-token-and-pid
  "The service's acknowledgement names the token it answered and its own pid."
  (with-state-home (home)
    (is eq :absent (nth-value 1 (hostfiles:read-served-ack "s1")))
    (hostfiles:write-served-ack "s1" "tok-9" 777)
    (multiple-value-bind (plist status) (hostfiles:read-served-ack "s1")
      (is eq :ok status)
      (is equal "tok-9" (getf plist :token))
      (is = 777 (getf plist :pid))
      (true (integerp (getf plist :served-at))))))

;;; ----------------------------------------------------------------- degraded

(define-test degraded-records-round-trip-for-default-and-named-buses
  "A degradation is recorded per bus, the unnamed bus under `default`, and can
   be listed and cleared."
  (with-state-home (home)
    (is equal '() (hostfiles:degraded-records))
    (hostfiles:write-degraded-record nil '(:bus nil :incumbent-pid 11))
    (hostfiles:write-degraded-record "sx1" '(:bus "sx1" :incumbent-pid 22))
    (is string= "default" (pathname-name (hostfiles:degraded-path nil)))
    (is = 11 (getf (hostfiles:read-degraded-record nil) :incumbent-pid))
    (is = 22 (getf (hostfiles:read-degraded-record "sx1") :incumbent-pid))
    (let ((records (hostfiles:degraded-records)))
      (is = 2 (length records))
      (is = 11 (getf (cdr (assoc "default" records :test #'string=)) :incumbent-pid))
      (is = 22 (getf (cdr (assoc "sx1" records :test #'string=)) :incumbent-pid)))
    (true (hostfiles:clear-degraded-record nil))
    (false (hostfiles:clear-degraded-record nil))
    (is equal '("sx1") (mapcar #'car (hostfiles:degraded-records)))))

;;; ---------------------------------------------------------------- processes

(define-test proc-starttime-identifies-a-process-not-a-pid
  "The start time is what tells a live session from a recycled pid."
  (let* ((pid (sb-posix:getpid))
         (start (hostfiles:proc-starttime pid)))
    (true (integerp start))
    (is eql start (hostfiles:proc-starttime pid))
    (true (hostfiles:process-matches-p pid start))
    (false (hostfiles:process-matches-p pid (1+ start)))
    (is eq nil (hostfiles:proc-starttime 999999999))
    (true (consp (hostfiles:proc-cmdline pid)))
    (is eq nil (hostfiles:proc-cmdline 999999999))))

(define-test session-from-environment-takes-claude-pid-first
  "A session that names itself is believed when the process it names is alive."
  (let ((pid (sb-posix:getpid)))
    (with-env ("CLAUDE_PID" (princ-to-string pid))
      (multiple-value-bind (found start) (hostfiles:session-from-environment)
        (is eql pid found)
        (is eql (hostfiles:proc-starttime pid) start)))))

(define-test service-probes-answer-for-an-absent-service
  "With nothing installed, every service probe answers no rather than failing."
  (with-state-home (home)
    (false (hostfiles:service-installed-p))
    (is eq nil (hostfiles:read-service-pid))
    (is eq nil (hostfiles:service-beat-age))
    (false (hostfiles:service-alive-p))
    (hostfiles:ensure-host-dir)
    (write-text (hostfiles:service-state-path) "(:state :running)")
    (write-text (hostfiles:service-pid-path)
                (format nil "~D~%" (sb-posix:getpid)))
    (write-text (hostfiles:service-beat-path) "beat")
    (true (hostfiles:service-installed-p))
    (is eql (sb-posix:getpid) (hostfiles:read-service-pid))
    (true (<= 0 (hostfiles:service-beat-age) 2))
    (true (hostfiles:service-alive-p))))

;;; ---------------------------------------------------------------- fleet log

(defun iso-stamp-p (text)
  "True when TEXT is a UTC timestamp of the form 2026-10-12T16:30:00Z."
  (and (= (length text) 20)
       (every (lambda (ch) (or (digit-char-p ch) (find ch "T:Z-"))) text)
       (char= (char text 10) #\T)
       (char= (char text 19) #\Z)))

(define-test a-fleet-line-is-one-greppable-line
  "Every field of a fleet line stays in its own field and the line stays one
   line, whatever the names and the message carry."
  (let ((line (hostfiles:fleet-line :error "stranded-cursor" :bus "dsmr-mcp"
                                                             :id "/a b/c"
                                                             :msg (format nil "x~Cy" #\Newline))))
    (true (iso-stamp-p (subseq line 0 20)) "the line opens with a UTC stamp: ~S" line)
    (is string= " FLEET ERROR code=stranded-cursor bus=dsmr-mcp id=/a_b/c msg=x y"
        (subseq line 20))
    (true (hostfiles:fleet-line-p line)))
  (let ((line (hostfiles:fleet-line :warn "x" :bus nil :msg "m")))
    (true (search " FLEET WARN code=x bus=- id=- msg=m" line)))
  (is string= "1970-01-01T00:00:00Z FLEET INFO code=c bus=- id=- msg="
      (hostfiles:fleet-line :info "c" :time 2208988800))
  (false (hostfiles:fleet-line-p "2026-10-12 some other line")))

(define-test append-fleet-line-adds-one-line-per-call
  "Appends land whole, one per line, and create the host directory first."
  (with-state-home (home)
    (hostfiles:append-fleet-line (hostfiles:fleet-line :info "one"))
    (hostfiles:append-fleet-line (hostfiles:fleet-line :warn "two"))
    (let ((lines (uiop:read-file-lines (hostfiles:fleet-log-path))))
      (is = 2 (length lines))
      (true (search "code=one" (first lines)))
      (true (search "code=two" (second lines))))))

;;; --------------------------------------------------------------------- heal

(defparameter *self* "/home/x/proj/boomer"
  "The identity every heal fixture runs for.")

(defmacro with-bus ((log cursor dir) &body body)
  "Bind DIR to a fresh bus root, LOG to its log path and CURSOR to the cursor
   path of *SELF* under it."
  `(with-temp-dir (,dir "dsmr-hostfiles-bus")
     (let ((,log (merge-pathnames "bus.wal" ,dir))
           (,cursor (merge-pathnames "cursors/self.cursor" ,dir)))
       (declare (ignorable ,log))
       (ensure-directories-exist ,cursor)
       ,@body)))

(define-test a-cursor-from-another-generation-is-rebased-to-the-new-log
  "A cursor recorded against the log that was rotated away names nothing in
   the new log. Rebased to 0, the whole new log is owed to the agent."
  (with-bus (log cursor dir)
    (make-log dir 2 5)
    (write-text cursor "372 1")
    (multiple-value-bind (baseline action report)
        (hostfiles:heal-stranded-baseline *self* log cursor)
      (is = 0 baseline)
      (is eq :rebased action)
      (is string= "0 2" (read-text cursor))
      (is equal *self* (getf report :id))
      (is eq :cursor-above-head (getf report :reason))
      (is = 372 (getf report :old-cursor))
      (is = 1 (getf report :old-generation))
      (is = 2 (getf report :generation))
      (is = 5 (getf report :head))
      (is eq nil (getf report :unread-in-archive)))))

(define-test a-refused-rebase-clamps-to-the-head-and-writes-nothing
  "With the rebase refused the baseline is the log head, never the stranded
   value, and the cursor file is left exactly as it was."
  (with-bus (log cursor dir)
    (make-log dir 2 5)
    (write-text cursor "372 1")
    (multiple-value-bind (baseline action report)
        (hostfiles:heal-stranded-baseline *self* log cursor :rebase-p nil)
      (is = 5 baseline)
      (is eq :clamped action)
      (is = 372 (getf report :old-cursor)))
    (is string= "372 1" (read-text cursor))))

(define-test a-sound-cursor-is-returned-and-not-written
  "A cursor in step with its log is the baseline as it stands."
  (with-bus (log cursor dir)
    (make-log dir 2 5)
    (write-text cursor "3 2")
    (let ((before (file-write-date cursor)))
      (multiple-value-bind (baseline action)
          (hostfiles:heal-stranded-baseline *self* log cursor)
        (is = 3 baseline)
        (is eq :sound action))
      (is string= "3 2" (read-text cursor))
      (is = before (file-write-date cursor)))))

(define-test a-cursor-above-a-shortened-log-of-the-same-generation-moves-to-head
  "A log shortened under the same generation still holds the records below the
   cursor, so the cursor moves to the head rather than to 0."
  (with-bus (log cursor dir)
    (make-log dir 2 5)
    (write-text cursor "9 2")
    (multiple-value-bind (baseline action)
        (hostfiles:heal-stranded-baseline *self* log cursor)
      (is = 5 baseline)
      (is eq :rebased action))
    (is string= "5 2" (read-text cursor))))

(define-test a-rebase-counts-what-the-archive-still-held
  "Rebasing discards the old position, so the count of records the agent had
   not read in the archived log is reported with it."
  (with-bus (log cursor dir)
    (make-log dir 2 5)
    (make-log dir 1 7 :name "bus.wal.archive-1000")
    (make-log dir 1 2 :name "bus.wal.archive-900")
    (write-text cursor "3 1")
    (multiple-value-bind (baseline action report)
        (hostfiles:heal-stranded-baseline *self* log cursor)
      (is = 0 baseline)
      (is eq :rebased action)
      (is eq :generation-mismatch (getf report :reason))
      (is = 4 (getf report :unread-in-archive)))))

(define-test a-missing-cursor-is-left-for-the-caller
  "No cursor is not a stranded cursor: the caller arms at the head as before."
  (with-bus (log cursor dir)
    (make-log dir 2 5)
    (multiple-value-bind (baseline action)
        (hostfiles:heal-stranded-baseline *self* log cursor)
      (is eq nil baseline)
      (is eq :no-cursor action))
    (false (probe-file cursor))))
