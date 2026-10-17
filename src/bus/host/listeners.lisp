;;;; src/bus/host/listeners.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; The host service's wake clients: a Unix socket in the host directory where
;;;; each waiting client sends one request line, and the queues wake lines are
;;;; handed out of.
;;;;
;;;; There is one queue of connected clients per identity file stem. A hook
;;;; client stands at the head, at most one per stem, a newer one replacing the
;;;; older; background clients follow in arrival order. An event goes to the
;;;; head alone, which leaves every queue the moment its line is sent, and the
;;;; next client is promoted and handed whatever arrived after the stem's
;;;; delivered position. Every send is reported through DELIVERED-FN, so the
;;;; service can persist the position; nothing here writes a file.
;;;;
;;;; Identities, the log and its wake lines belong to the service, which plugs
;;;; them in through callbacks, so every rule here runs in-process against
;;;; fakes. One recursive mutex guards the queues, the service's own when it is
;;;; given. Writes to clients are non-blocking and never raise SIGPIPE, so a
;;;; stuck or vanished client fails its own connection and no other.
;;;;
;;;; Only a connection's reader thread closes its socket. Any other thread ends
;;;; a connection by shutting it down, which wakes the reader with end of file
;;;; and keeps the descriptor number from being reused while the reader still
;;;; polls it.
;;;;
;;;; Wire protocol, version 1: one LF-terminated line each way, fields
;;;; separated by single spaces, every value percent-encoded or the bare `-`
;;;; for absent.
;;;;
;;;; Requests, fields as key=value:
;;;;   WAKE 1 hook= allbuses= agent= ns= agentid= envagent= bus= envbus= cwd= pid=
;;;;   READERS 1 id= bus=
;;;;
;;;; Replies:
;;;;   EXIT <status> <kind> <out> <err>
;;;;   READERS <n>
;;;;   ERR bad-request <text>
;;;;   ERR version <text>
;;;;   ERR busy <text>
;;;;   ERR bad-bus <text>
;;;;
;;;; EXIT is the final reply to a wake client. OUT and ERR are the texts the
;;;; client writes verbatim to stdout and stderr, already worded for its mode
;;;; (default or hook), and STATUS, 0, 1 or 2, is the code it exits with. KIND
;;;; is event, nowatcher or superseded, and matches [a-z-]{1,16}. A text is `-`
;;;; for nothing, else its UTF-8 octets with each outside [A-Za-z0-9._~/]
;;;; written %XX in uppercase hex. Bounds:
;;;;   - a decoded text is at most 4096 octets;
;;;;   - a decoded text holds only octets 0x09, 0x0A, 0x20-0x7E and 0x80-0xFF;
;;;;   - the reply line is at most 32768 octets with its LF.
;;;; The client prints no ERR text: it retries on busy, version and
;;;; bad-request, and on bad-bus runs the Lisp watcher program, which reports
;;;; the refusal itself.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-posix)
  (require :sb-bsd-sockets))

(defpackage #:dsmr-bus-host/src/bus/host/listeners
  (:use #:cl)
  (:local-nicknames (#:hostfiles #:dsmr-mcp/src/bus/hostfiles)
                    (#:envelope #:dsmr-mcp/src/bus/envelope)
                    (#:selector #:dsmr-mcp/src/bus/selector))
  (:import-from #:dsmr-bus-watch/src/bus/watch
                #:%unix-time)
  (:export
   ;; requests
   #:parse-request
   #:request-identity
   ;; replies
   #:+max-reply-text-octets+
   #:exit-reply
   #:event-reply
   #:nowatcher-reply
   #:superseded-reply
   ;; the hub
   #:hub
   #:hub-p
   #:make-hub
   #:hub-socket-path
   #:start-hub
   #:stop-hub
   #:hub-offer
   #:hub-release-stem
   #:hub-retry-pending
   #:hub-refresh
   #:hub-ensure-delivered
   #:hub-delivered
   #:hub-reader-count
   #:hub-last-delivery
   #:hub-progress
   #:hub-stems
   #:hub-snapshot))

(in-package #:dsmr-bus-host/src/bus/host/listeners)

;;; ----------------------------------------------------------------- constants

(defconstant +max-request-bytes+ 8192
  "The longest request line accepted, in bytes, not counting its newline.")

(defconstant +max-socket-path-bytes+ 107
  "The longest socket path a unix-domain address holds, in bytes.")

(defparameter *accept-wait-seconds* 0.25
  "How long the accept loop waits for a connection before it comes round.")

(defparameter *reader-wait-seconds* 1
  "How long a reader thread waits for input before it checks whether the hub
   is stopping.")

;;; ------------------------------------------------------------------ requests

(defparameter *wake-keys*
  '(("hook" . :hook-p) ("allbuses" . :all-buses-p) ("agent" . :agent)
    ("ns" . :namespace) ("agentid" . :agent-id) ("envagent" . :env-agent)
    ("bus" . :bus) ("envbus" . :env-bus) ("cwd" . :cwd) ("pid" . :pid))
  "The keys a WAKE request may carry, with the plist key each is read into.")

(defparameter *readers-keys*
  '(("id" . :id) ("bus" . :bus))
  "The keys a READERS request may carry, with the plist key each is read into.")

(defun %request-character-p (ch)
  "True when CH may appear in a request line: printable ASCII or a space."
  (<= 32 (char-code ch) 126))

(defun %present (value)
  "VALUE when it is a non-empty string, else NIL."
  (and (stringp value) (plusp (length value)) value))

(defun parse-request (line)
  "LINE, one request without its newline, as two values: a plist and NIL, or
   NIL and the refusal code :BAD-REQUEST or :VERSION.

   The plist has :KIND (:WAKE or :READERS) and one key per field of that kind,
   NIL for a field that is absent or `-`; :PID is an integer. Field keys:
     WAKE     :HOOK-P :ALL-BUSES-P :AGENT :NAMESPACE :AGENT-ID :ENV-AGENT
              :BUS :ENV-BUS :CWD :PID
     READERS  :ID :BUS

   A decimal version other than 1 is refused as :VERSION. Refused as
   :BAD-REQUEST:
     - a character outside printable ASCII;
     - an unknown kind, or a version that is not decimal;
     - an empty token, a token with no `=`, or an unknown or repeated key;
     - a flag other than 0 or 1, or a pid that is not decimal;
     - a malformed percent escape."
  (block parse
    (flet ((refuse (code) (return-from parse (values nil code))))
      (unless (and (stringp line) (plusp (length line))
                   (every #'%request-character-p line))
        (refuse :bad-request))
      (let* ((tokens (uiop:split-string line :separator " "))
             (kind (first tokens))
             (version (second tokens))
             (keys (cond ((string= kind "WAKE") *wake-keys*)
                         ((string= kind "READERS") *readers-keys*)
                         (t (refuse :bad-request))))
             (plist (list :kind (if (eq keys *wake-keys*) :wake :readers)))
             (seen '()))
        (unless (and version (plusp (length version)) (every #'digit-char-p version))
          (refuse :bad-request))
        (unless (string= version "1")
          (refuse :version))
        (dolist (token (cddr tokens))
          (let* ((split (position #\= token))
                 (name (and split (subseq token 0 split)))
                 (raw (and split (subseq token (1+ split))))
                 (entry (and name (assoc name keys :test #'string=))))
            (when (or (null entry) (member name seen :test #'string=))
              (refuse :bad-request))
            (push name seen)
            (setf (getf plist (cdr entry))
                  (case (cdr entry)
                    ((:hook-p :all-buses-p)
                     (cond ((string= raw "1") t)
                           ((string= raw "0") nil)
                           (t (refuse :bad-request))))
                    (:pid
                     (cond ((string= raw "-") nil)
                           ((and (<= 1 (length raw) 10) (every #'digit-char-p raw))
                            (parse-integer raw))
                           (t (refuse :bad-request))))
                    (t
                     (handler-case (hostfiles:percent-decode-field raw)
                       (error () (refuse :bad-request))))))))
        (dolist (entry keys)
          (unless (member (car entry) seen :test #'string=)
            (setf (getf plist (cdr entry)) nil)))
        (values plist nil)))))

(defun request-identity (request)
  "The identity a parsed wake REQUEST names, as three values:
     - the normalized full bus id, or NIL;
     - the bus name, or NIL for the unnamed bus;
     - true when the request covers every bus.

   The id is :AGENT-ID when non-empty. Otherwise the name is :AGENT, else
   :ENV-AGENT, whichever is first non-empty, placed in :NAMESPACE when that is
   present (an empty namespace counts as present) and else in the directory
   :CWD names. NIL when no name resolves or no namespace can be found. The bus
   is :BUS, else :ENV-BUS, whichever is first non-empty; signals
   INVALID-BUS-NAME for one that cannot name a bus."
  (let* ((explicit (%present (getf request :agent-id)))
         (name (or (%present (getf request :agent))
                   (%present (getf request :env-agent))))
         (namespace (getf request :namespace))
         (cwd (%present (getf request :cwd)))
         (self-id (cond (explicit explicit)
                        ((null name) nil)
                        (namespace (envelope:agent-id namespace :name name))
                        (cwd (envelope:agent-id
                              (namestring (uiop:ensure-directory-pathname
                                           (uiop:parse-native-namestring cwd)))
                              :name name))
                        (t nil)))
         (bus (or (%present (getf request :bus))
                  (%present (getf request :env-bus)))))
    (values (hostfiles:normalise-agent-id self-id)
            (and bus (selector:validate-bus-name bus))
            (and (getf request :all-buses-p) t))))

;;; ------------------------------------------------------------- the structures

(defstruct (hub (:constructor %make-hub))
  "The wake clients of one host service. Made by MAKE-HUB.

   SOCKET is the listening socket at SOCKET-PATH, bound when BOUND-P. The
   callbacks and caps are as MAKE-HUB describes. MUTEX guards:
     QUEUES      stem to its clients, head first
     POSITIONS   stem to its delivered position
     DELIVERIES  stem to the Unix time of its last send
     PENDING     clients the service could not resolve yet
     CONNS       every open client
   PROGRESS counts turns of the accept loop; STOPPING asks every thread to end."
  socket
  socket-path
  (bound-p nil)
  mutex
  resolve-fn
  gap-fn
  nowatcher-fn
  delivered-fn
  report-fn
  per-identity-cap
  global-cap
  request-seconds
  service-pid
  (queues (make-hash-table :test 'equal))
  (positions (make-hash-table :test 'equal))
  (deliveries (make-hash-table :test 'equal))
  (pending '())
  (conns '())
  (progress 0)
  (stopping nil)
  accept-thread)

(defstruct (conn (:constructor %make-conn (socket)))
  "One connected wake client. SOCKET is its connection and MUTEX serializes
   writes to it. REQUEST is its parsed request, HOOK-P and PID copied from it.
   TARGETS lists the (STEM . LABEL) pairs it waits on. CONNECTED-AT is Unix
   seconds. DONE-P says it has been ended; THREAD reads from it."
  socket
  (mutex (sb-thread:make-mutex :name "wake client"))
  request
  (hook-p nil)
  pid
  (targets '())
  connected-at
  (done-p nil)
  thread)

(defun make-hub (&key socket-path mutex resolve-fn gap-fn nowatcher-fn delivered-fn
                      report-fn (per-identity-cap 8) (global-cap 256)
                      (request-seconds 5) service-pid)
  "A hub listening, once started, at SOCKET-PATH (the host's wake socket by
   default), guarded by MUTEX (a fresh one by default).

   RESOLVE-FN takes a parsed wake request and returns (:TARGETS ((STEM .
   LABEL) ...)), (:NOWATCHER ID LABEL), (:BAD-BUS TEXT) or (:UNREADY).
   GAP-FN takes a stem and its delivered position (NIL when unknown) and
   returns the line and seq owed to a newly promoted head, or NIL.
   NOWATCHER-FN takes an id and whether the client is a hook, and returns true
   when the hourly no-watcher notice is due. DELIVERED-FN takes a stem, its new
   delivered position and the time, after each send. REPORT-FN takes (LEVEL
   CODE &key BUS ID SUBJECT MSG).

   PER-IDENTITY-CAP bounds the clients waiting on one stem, GLOBAL-CAP the
   open connections, and REQUEST-SECONDS the time a client has to send its
   request line."
  (%make-hub :socket-path (or socket-path (hostfiles:wake-socket-path))
             :mutex (or mutex (sb-thread:make-mutex :name "wake hub"))
             :resolve-fn (or resolve-fn (constantly (list :unready)))
             :gap-fn (or gap-fn (constantly nil))
             :nowatcher-fn (or nowatcher-fn (constantly nil))
             :delivered-fn delivered-fn
             :report-fn report-fn
             :per-identity-cap per-identity-cap
             :global-cap global-cap
             :request-seconds request-seconds
             :service-pid service-pid))

(defmacro with-hub-lock ((hub) &body body)
  "Run BODY holding HUB's mutex."
  `(sb-thread:with-recursive-lock ((hub-mutex ,hub))
     ,@body))

(defun %report (hub level code &rest args &key bus id subject msg)
  "Hand a report to HUB's report function, when it has one. A failing report
   function is ignored."
  (declare (ignore bus id subject msg))
  (let ((report-fn (hub-report-fn hub)))
    (when report-fn
      (ignore-errors (apply report-fn level code args)))))

(defun %label (conn stem)
  "The label CONN's events for STEM carry."
  (cdr (assoc stem (conn-targets conn) :test #'string=)))

;;; --------------------------------------------------------------- reply texts

(defconstant +max-reply-text-octets+ 4096
  "The longest text a final reply carries for one stream, in UTF-8 octets.")

(defconstant +max-name-characters+ 256
  "The most characters of a label or an id a reply text carries.")

(defparameter *hook-advice*
  "This hook arms the next listener itself when your turn ends; do not start one."
  "The sentence closing every hook-mode text. The hook re-arms itself at the
   end of a turn, so the woken session must not start a listener.")

(defun %reply-character-p (ch)
  "True when CH may appear in a reply text: TAB, LF, or any code point from 32
   up other than 127."
  (let ((code (char-code ch)))
    (or (= code 9) (= code 10) (and (>= code 32) (/= code 127)))))

(defun %printable (text)
  "TEXT, or `-` for NIL, with every character %REPLY-CHARACTER-P rejects
   replaced by `?`."
  (substitute-if-not #\? #'%reply-character-p (or text "-")))

(defun %clip (text)
  "TEXT through %PRINTABLE, cut to its first +MAX-NAME-CHARACTERS+ characters."
  (let ((text (%printable text)))
    (subseq text 0 (min (length text) +max-name-characters+))))

(defun %utf-8-length (text)
  "The length of TEXT in UTF-8 octets."
  (length (sb-ext:string-to-octets text :external-format :utf-8)))

(defun exit-reply (status kind out err)
  "The final reply line ending a wake client, without its newline:
     EXIT <status> <kind> <out> <err>

   STATUS is the exit code the client ends with: 0, 1 or 2. KIND names the
   outcome, 1 to 16 of [a-z-]. OUT and ERR are the texts the client writes
   verbatim to stdout and stderr, each percent-encoded, or `-` when NIL or
   empty. With each text at most +MAX-REPLY-TEXT-OCTETS+ octets, the line stays
   under 32768 octets.

   Signals ERROR when the client would reject the reply:
     - STATUS or KIND outside those sets;
     - a text over +MAX-REPLY-TEXT-OCTETS+ octets;
     - a text holding a control character other than TAB and LF."
  (unless (member status '(0 1 2))
    (error "The exit status ~S is not 0, 1 or 2." status))
  (unless (and (stringp kind) (<= 1 (length kind) 16)
               (every (lambda (ch) (or (char<= #\a ch #\z) (char= ch #\-))) kind))
    (error "The reply kind ~S is not 1 to 16 of [a-z-]." kind))
  (flet ((field (text)
           (let ((bad (and text (find-if-not #'%reply-character-p text))))
             (cond ((or (null text) (zerop (length text))) "-")
                   (bad
                    (error "A reply text holds the control character ~D." (char-code bad)))
                   ((> (%utf-8-length text) +max-reply-text-octets+)
                    (error "A reply text is ~D octets; the limit is ~D."
                           (%utf-8-length text) +max-reply-text-octets+))
                   (t (hostfiles:percent-encode-field text))))))
    (format nil "EXIT ~D ~A ~A ~A" status kind (field out) (field err))))

(defun %event-text (hook-p label line)
  "The text an event client prints: LINE and LF, followed in hook mode by the
   advice to drain bus LABEL."
  (if hook-p
      (format nil "~A~%dsmr-bus-watch: mail has arrived for you on bus ~A. ~
                   Drain the bus now with bus-receive and act on what it holds. ~A~%"
              line label *hook-advice*)
      (format nil "~A~%" line)))

(defun %first-token (line)
  "LINE up to its first space, the `bus:<seq>` token of a wake line, cut to
   +MAX-NAME-CHARACTERS+ characters."
  (let ((token (subseq line 0 (position #\Space line))))
    (subseq token 0 (min (length token) +max-name-characters+))))

(defun event-reply (hook-p label line)
  "The final reply handing a client the wake LINE that arrived on bus LABEL,
   worded for its mode:
     default  exit 0, LINE on stdout;
     hook     exit 2, LINE and the drain advice on stderr.

   Control characters in LINE and LABEL become `?` and LABEL is cut to 256
   characters. A LINE whose text would pass +MAX-REPLY-TEXT-OCTETS+ octets is
   replaced by its leading `bus:<seq>` token."
  (let* ((label (%clip label))
         (line (%printable line))
         (text (%event-text hook-p label line)))
    (when (> (%utf-8-length text) +max-reply-text-octets+)
      (setf text (%event-text hook-p label (%first-token line))))
    (if hook-p
        (exit-reply 2 "event" nil text)
        (exit-reply 0 "event" text nil))))

(defun %no-watcher-diagnostic (id label tail)
  "The stderr line saying no detached watcher runs for ID on bus LABEL,
   finished by TAIL and LF."
  (format nil "dsmr-bus-watch: no detached watcher is running for ~A on bus ~A~A~%"
          id label tail))

(defun nowatcher-reply (hook-p label id due)
  "The final reply telling a client that no detached watcher serves ID on bus
   LABEL, worded for its mode:
     default         exit 1, the nowatcher line on stdout, the warning on stderr;
     hook, DUE       exit 2, the nowatcher line and the advice on stderr;
     hook, not DUE   exit 0, nothing.

   DUE says the hourly notice is due; it applies to hook clients alone. A NIL
   ID renders as `-`. Control characters in LABEL and ID become `?`, and each
   is cut to 256 characters."
  (let* ((label (%clip label))
         (id (%clip id))
         (line (format nil "nowatcher bus=~A~%" label)))
    (cond
      ((not hook-p)
       (exit-reply 1 "nowatcher" line
                   (%no-watcher-diagnostic id label
                                           "; start one with --detach, then wake again")))
      (due
       (exit-reply 2 "nowatcher" nil
                   (concatenate 'string line
                                (%no-watcher-diagnostic
                                 id label
                                 (format nil ", so no mail can wake you. Start one with ~
                                              dsmr-bus-watch --detach and your usual --bus ~
                                              and identity flags. ~A"
                                         *hook-advice*)))))
      (t
       (exit-reply 0 "nowatcher" nil nil)))))

(defun superseded-reply ()
  "The final reply to a hook client a newer one replaced: exit 0, nothing
   printed."
  (exit-reply 0 "superseded" nil nil))

;;; ------------------------------------------------------------------- writing

(defun %one-line (text)
  "TEXT with every carriage return and newline turned into a space, followed
   by one newline."
  (concatenate 'string
               (substitute #\Space #\Return (substitute #\Space #\Newline text))
               (string #\Newline)))

(defun %end-conn-locked (conn)
  "End CONN, holding its mutex: mark it done and shut its socket down both
   ways, which wakes its reader thread with end of file."
  (unless (conn-done-p conn)
    (setf (conn-done-p conn) t)
    (ignore-errors (sb-bsd-sockets:socket-shutdown (conn-socket conn) :direction :io))))

(defun %end-conn (conn)
  "End CONN: mark it done and shut its socket down both ways."
  (sb-thread:with-mutex ((conn-mutex conn))
    (%end-conn-locked conn)))

(defun %send-line (conn text)
  "Send TEXT and a newline to CONN in one non-blocking write. True when the
   whole line went; otherwise CONN is ended and NIL returned."
  (let ((octets (sb-ext:string-to-octets (%one-line text) :external-format :utf-8)))
    (sb-thread:with-mutex ((conn-mutex conn))
      (unless (conn-done-p conn)
        (let ((sent (handler-case
                        (sb-bsd-sockets:socket-send (conn-socket conn) octets nil
                                                    :nosignal t :dontwait t)
                      (error () nil))))
          (or (eql sent (length octets))
              (progn (%end-conn-locked conn) nil)))))))

(defun %field (value)
  "VALUE percent-encoded as a reply field, or `-` for NIL."
  (if value (hostfiles:percent-encode-field value) "-"))

(defun %refuse (conn code text)
  "Answer CONN with ERR CODE and TEXT, and end it."
  (%send-line conn (format nil "ERR ~A ~A" code (%field text)))
  (%end-conn conn))

(defun %send-nowatcher (hub conn id label)
  "Answer CONN that no watcher serves ID on LABEL, worded for CONN's mode and
   for whether NOWATCHER-FN says the hourly notice is due, and end it."
  (let ((due (handler-case (funcall (hub-nowatcher-fn hub) id (conn-hook-p conn))
               (error (e)
                 (%report hub :warn "wake-nowatcher-failed" :id id :msg (princ-to-string e))
                 nil))))
    (%send-line conn (nowatcher-reply (conn-hook-p conn) label id due))
    (%end-conn conn)))

;;; -------------------------------------------------------------------- queues

(defun %remove-conn (hub conn)
  "Take CONN out of HUB's pending list and every queue, under the hub mutex,
   and return the stems whose head it was."
  (setf (hub-pending hub) (remove conn (hub-pending hub)))
  (let ((headed '()))
    (dolist (target (conn-targets conn))
      (let* ((stem (car target))
             (queue (gethash stem (hub-queues hub))))
        (when (member conn queue)
          (when (eq conn (first queue))
            (push stem headed))
          (let ((rest (remove conn queue)))
            (if rest
                (setf (gethash stem (hub-queues hub)) rest)
                (remhash stem (hub-queues hub)))))))
    (nreverse headed)))

(defun %deliver (hub stem conn label seq line now)
  "Send CONN the event reply for LINE, the event for STEM, worded for CONN's
   mode, under the hub mutex, and return true when it went.

   Sent or not, CONN is ended and leaves every queue, and each other queue it
   headed hands its gap to its next client; STEM's own queue is left to the
   caller. After a send:
     - STEM's delivered position rises to SEQ and the time is noted;
     - DELIVERED-FN receives the stem, its position and the time;
     - the send is reported as wake-delivered."
  (let ((sent (%send-line conn (event-reply (conn-hook-p conn) label line))))
    (%end-conn conn)
    (let ((headed (remove stem (%remove-conn hub conn) :test #'string=)))
      (when sent
        (let ((old (gethash stem (hub-positions hub))))
          (when seq
            (setf (gethash stem (hub-positions hub)) (if old (max old seq) seq))))
        (setf (gethash stem (hub-deliveries hub)) now)
        (when (hub-delivered-fn hub)
          (handler-case (funcall (hub-delivered-fn hub) stem
                                 (gethash stem (hub-positions hub)) now)
            (error (e)
              (%report hub :error "wake-delivered-failed" :subject stem
                       :msg (princ-to-string e)))))
        (%report hub :info "wake-delivered" :bus label :subject stem
                 :msg (format nil "seq=~A label=~A pid=~A ~A" seq label (conn-pid conn)
                              (if (conn-hook-p conn) "hook" "background"))))
      (dolist (other headed)
        (%hand-gap hub other now))
      sent)))

(defun %hand-gap (hub stem &optional (now (%unix-time)))
  "Offer STEM's head whatever GAP-FN says it is owed, under the hub mutex, and
   repeat for each new head until GAP-FN owes nothing or the queue is empty."
  (loop
    (let ((head (first (gethash stem (hub-queues hub)))))
      (unless head
        (return))
      (multiple-value-bind (line seq)
          (handler-case (funcall (hub-gap-fn hub) stem (gethash stem (hub-positions hub)))
            (error (e)
              (%report hub :error "wake-gap-failed" :subject stem :msg (princ-to-string e))
              nil))
        (unless line
          (return))
        (%deliver hub stem head (%label head stem) seq line now)))))

(defun %over-cap-p (hub conn targets)
  "True when queueing CONN on TARGETS would put more than the per-identity cap
   of clients on one stem. A hook client replaces any hook already queued, so
   that one is not counted."
  (some (lambda (target)
          (let* ((queue (gethash (car target) (hub-queues hub)))
                 (staying (if (conn-hook-p conn) (remove-if #'conn-hook-p queue) queue)))
            (>= (length staying) (hub-per-identity-cap hub))))
        targets))

(defun %supersede (hub old keep-stems)
  "Tell the hook client OLD it has been replaced, end it and take it out of
   every queue, handing the gap on in each queue it headed outside KEEP-STEMS."
  (%send-line old (superseded-reply))
  (%end-conn old)
  (dolist (stem (set-difference (%remove-conn hub old) keep-stems :test #'string=))
    (%hand-gap hub stem)))

(defun %enqueue (hub conn targets)
  "Queue CONN on each of TARGETS, under the hub mutex: a hook client at the
   head, replacing any older hook client, a background client at the tail.
   Each queue CONN now heads hands it its gap. A client over the cap is
   answered busy instead."
  (let ((targets (remove-duplicates targets :key #'car :test #'string= :from-end t)))
    (cond
      ((null targets)
       (%refuse conn "bad-request" "no identity to wait on"))
      ((%over-cap-p hub conn targets)
       (%refuse conn "busy" "too many clients are waiting for this identity"))
      (t
       (setf (conn-targets conn) targets)
       (let ((stems (mapcar #'car targets))
             (headed '()))
         (dolist (stem stems)
           (if (conn-hook-p conn)
               (let ((old (find-if #'conn-hook-p (gethash stem (hub-queues hub)))))
                 (when old
                   (%supersede hub old stems))
                 (push conn (gethash stem (hub-queues hub)))
                 (push stem headed))
               (let ((queue (gethash stem (hub-queues hub))))
                 (setf (gethash stem (hub-queues hub)) (append queue (list conn)))
                 (unless queue
                   (push stem headed)))))
         (dolist (stem (nreverse headed))
           (%hand-gap hub stem)))))))

(defun %dispatch (hub conn)
  "Resolve CONN's wake request through RESOLVE-FN and act on the answer, under
   the hub mutex: queue CONN, hold it as pending, or answer it and end it."
  (with-hub-lock (hub)
    (setf (hub-pending hub) (remove conn (hub-pending hub)))
    (unless (or (conn-done-p conn) (hub-stopping hub))
      (let ((answer (handler-case (funcall (hub-resolve-fn hub) (conn-request conn))
                      (error (e)
                        (%report hub :error "wake-resolve-failed" :msg (princ-to-string e))
                        (list :failed (princ-to-string e))))))
        (case (first answer)
          (:targets (%enqueue hub conn (second answer)))
          (:nowatcher (%send-nowatcher hub conn (second answer) (third answer)))
          (:bad-bus (%refuse conn "bad-bus" (second answer)))
          (:unready (push conn (hub-pending hub)))
          (t (%refuse conn "bad-request" (or (second answer) "the request could not be resolved"))))))))

(defun %forget-conn (hub conn)
  "End CONN and drop it from HUB, handing the gap on in every queue it headed
   unless the hub is stopping."
  (%end-conn conn)
  (with-hub-lock (hub)
    (setf (hub-conns hub) (remove conn (hub-conns hub)))
    (let ((headed (%remove-conn hub conn)))
      (unless (hub-stopping hub)
        (dolist (stem headed)
          (%hand-gap hub stem))))))

;;; ------------------------------------------------------------------- readers

(defun %receive (conn buffer)
  "Read what is waiting on CONN into BUFFER and return the octet count, 0 at
   end of file or on an error."
  (handler-case
      (or (nth-value 1 (sb-bsd-sockets:socket-receive (conn-socket conn) buffer nil)) 0)
    (error () 0)))

(defun %read-request-line (hub conn)
  "CONN's request line within HUB's request window, as two values: the line
   without its newline, or NIL and one of :TOO-LONG, :TIMEOUT or :EOF."
  (let* ((fd (sb-bsd-sockets:socket-file-descriptor (conn-socket conn)))
         (deadline (+ (get-internal-real-time)
                      (round (* (hub-request-seconds hub) internal-time-units-per-second))))
         (line (make-array 256 :element-type '(unsigned-byte 8) :adjustable t
                               :fill-pointer 0))
         (chunk (make-array 1024 :element-type '(unsigned-byte 8))))
    (loop
      (when (or (conn-done-p conn) (hub-stopping hub))
        (return (values nil :eof)))
      (let ((remaining (/ (- deadline (get-internal-real-time))
                          internal-time-units-per-second)))
        (when (<= remaining 0)
          (return (values nil :timeout)))
        (when (sb-sys:wait-until-fd-usable fd :input (min remaining *reader-wait-seconds*) nil)
          (let ((count (%receive conn chunk)))
            (when (zerop count)
              (return (values nil :eof)))
            (dotimes (index count)
              (let ((octet (aref chunk index)))
                (when (= octet 10)
                  (return-from %read-request-line
                    (values (map 'string #'code-char line) nil)))
                (when (>= (fill-pointer line) +max-request-bytes+)
                  (return-from %read-request-line (values nil :too-long)))
                (vector-push-extend octet line)))))))))

(defun %await-end (hub conn)
  "Wait until CONN is ended, its client hangs up or HUB stops, discarding
   anything the client sends."
  (let ((fd (sb-bsd-sockets:socket-file-descriptor (conn-socket conn)))
        (chunk (make-array 256 :element-type '(unsigned-byte 8))))
    (loop until (or (conn-done-p conn) (hub-stopping hub))
          do (when (and (sb-sys:wait-until-fd-usable fd :input *reader-wait-seconds* nil)
                        (zerop (%receive conn chunk)))
               (return)))))

(defun %answer-readers (hub conn request)
  "Answer CONN's readers REQUEST with the number of clients waiting for its id
   on its bus, and end it."
  (let ((id (%present (getf request :id))))
    (if (null id)
        (%refuse conn "bad-request" "a readers request needs an id")
        (let ((count (hub-reader-count
                      hub (hostfiles:detach-stem (getf request :bus)
                                                 (hostfiles:normalise-agent-id id)))))
          (%send-line conn (format nil "READERS ~D" count))
          (%end-conn conn)))))

(defun %serve-conn (hub conn)
  "The body of CONN's reader thread: read and act on its request, wait for it
   to end, then drop it from HUB and close its socket."
  (unwind-protect
       (handler-case
           (progn
             (multiple-value-bind (line problem) (%read-request-line hub conn)
               (case problem
                 (:too-long
                  (%refuse conn "bad-request"
                           (format nil "request line over ~D bytes" +max-request-bytes+)))
                 (:timeout
                  (%refuse conn "bad-request"
                           (format nil "request not complete within ~A seconds"
                                   (hub-request-seconds hub))))
                 (:eof (%end-conn conn))
                 (t
                  (multiple-value-bind (request code) (parse-request line)
                    (cond
                      ((null request)
                       (%refuse conn (string-downcase (symbol-name code))
                                (if (eq code :version)
                                    "unknown protocol version"
                                    "malformed request")))
                      ((eq (getf request :kind) :readers)
                       (%answer-readers hub conn request))
                      (t
                       (setf (conn-request conn) request
                             (conn-hook-p conn) (getf request :hook-p)
                             (conn-pid conn) (getf request :pid))
                       (%dispatch hub conn)))))))
             (%await-end hub conn))
         (error (e)
           (%report hub :warn "wake-client-failed" :msg (princ-to-string e))))
    (ignore-errors (%forget-conn hub conn))
    (ignore-errors (sb-bsd-sockets:socket-close (conn-socket conn)))))

;;; ---------------------------------------------------------------- accepting

(defun %admit (hub socket)
  "Take the accepted connection SOCKET into HUB and start its reader thread,
   or answer it busy and close it when HUB already holds its global cap."
  (let ((conn (%make-conn socket)))
    (setf (conn-connected-at conn) (%unix-time))
    (if (with-hub-lock (hub)
          (when (< (length (hub-conns hub)) (hub-global-cap hub))
            (push conn (hub-conns hub))
            t))
        (handler-case
            (setf (conn-thread conn)
                  (sb-thread:make-thread #'%serve-conn :name "wake client"
                                                       :arguments (list hub conn)))
          (error (e)
            (with-hub-lock (hub)
              (setf (hub-conns hub) (remove conn (hub-conns hub))))
            (ignore-errors (sb-bsd-sockets:socket-close socket))
            (%report hub :error "wake-client-failed" :msg (princ-to-string e))))
        (progn
          (%send-line conn (format nil "ERR busy ~A" (%field "too many open connections")))
          (ignore-errors (sb-bsd-sockets:socket-close socket))))))

(defun %accept-loop (hub)
  "Accept wake clients on HUB's socket until HUB stops, counting each turn in
   its progress."
  (let* ((socket (hub-socket hub))
         (fd (sb-bsd-sockets:socket-file-descriptor socket)))
    (loop until (hub-stopping hub)
          do (incf (hub-progress hub))
             (handler-case
                 (when (sb-sys:wait-until-fd-usable fd :input *accept-wait-seconds* nil)
                   (let ((client (sb-bsd-sockets:socket-accept socket)))
                     (when client
                       (%admit hub client))))
               (error (e)
                 (%report hub :warn "wake-accept-failed" :msg (princ-to-string e))
                 (sleep *accept-wait-seconds*))))))

(defun %private-directory-p (dir)
  "True when DIR is owned by this uid with mode 0700."
  (handler-case
      (let ((stat (sb-posix:stat (uiop:native-namestring dir))))
        (and (= (sb-posix:stat-uid stat) (sb-posix:getuid))
             (= (logand (sb-posix:stat-mode stat) #o777) #o700)))
    (error () nil)))

(defun start-hub (hub)
  "Bind HUB's socket, owner-only, start accepting wake clients and return HUB.
   Returns NIL after reporting wake-socket-refused when:
     - the socket path is over 107 bytes;
     - its directory is not owned by this uid with mode 0700;
     - the socket cannot be bound.

   A file already at the path is removed first; the service lock makes this
   process the socket's only owner."
  (let* ((native (uiop:native-namestring (hub-socket-path hub)))
         (dir (uiop:pathname-directory-pathname (hub-socket-path hub)))
         (bytes (length (sb-ext:string-to-octets native :external-format :utf-8))))
    (flet ((refuse (message)
             (%report hub :error "wake-socket-refused" :subject native :msg message)
             (return-from start-hub nil)))
      (when (> bytes +max-socket-path-bytes+)
        (refuse (format nil "the socket path is ~D bytes; the limit is ~D"
                        bytes +max-socket-path-bytes+)))
      (unless (%private-directory-p dir)
        (refuse (format nil "~A must be owned by uid ~D with mode 0700"
                        (uiop:native-namestring dir) (sb-posix:getuid))))
      (let ((socket (make-instance 'sb-bsd-sockets:local-socket :type :stream)))
        (handler-case
            (progn
              (ignore-errors (sb-posix:unlink native))
              (sb-bsd-sockets:socket-bind socket native)
              (sb-posix:chmod native #o600)
              (sb-bsd-sockets:socket-listen socket 128)
              (setf (sb-bsd-sockets:non-blocking-mode socket) t))
          (error (e)
            (ignore-errors (sb-bsd-sockets:socket-close socket))
            (refuse (princ-to-string e))))
        (setf (hub-socket hub) socket
              (hub-bound-p hub) t
              (hub-stopping hub) nil)
        (setf (hub-accept-thread hub)
              (sb-thread:make-thread #'%accept-loop :name "wake accept"
                                                    :arguments (list hub)))
        hub))))

(defun %join (thread seconds)
  "Wait up to SECONDS for THREAD to end, unless it is this thread or gone."
  (when (and thread
             (not (eq thread sb-thread:*current-thread*))
             (sb-thread:thread-alive-p thread))
    (sb-thread:join-thread thread :default nil :timeout (max 0.01 (float seconds)))))

(defun stop-hub (hub &key (join-seconds 1))
  "Stop HUB and return it; safe to call more than once. In order:
     - end the accept loop and close the listening socket;
     - end every client, so each reads end of file;
     - wait up to JOIN-SECONDS for the threads;
     - remove the socket file."
  (setf (hub-stopping hub) t)
  (%join (hub-accept-thread hub) join-seconds)
  (when (hub-socket hub)
    (ignore-errors (sb-bsd-sockets:socket-close (hub-socket hub)))
    (setf (hub-socket hub) nil))
  (let ((conns (with-hub-lock (hub) (copy-list (hub-conns hub))))
        (deadline (+ (get-internal-real-time) (* join-seconds internal-time-units-per-second))))
    (dolist (conn conns)
      (%end-conn conn))
    (dolist (conn conns)
      (%join (conn-thread conn)
             (/ (- deadline (get-internal-real-time)) internal-time-units-per-second))))
  (with-hub-lock (hub)
    (clrhash (hub-queues hub))
    (setf (hub-pending hub) '()))
  (when (hub-bound-p hub)
    (ignore-errors (sb-posix:unlink (uiop:native-namestring (hub-socket-path hub))))
    (setf (hub-bound-p hub) nil))
  hub)

;;; ---------------------------------------------------------- the service side

(defun hub-offer (hub stem label seq line &key (now (%unix-time)))
  "Send LINE, the event at SEQ for STEM on bus LABEL, to the head of STEM's
   queue as the event reply for its mode, and return true when a client took
   it.

   A head whose write fails is ended and the next tried. The client that took
   it leaves every queue at once and STEM's next client is offered its gap.
   The delivered position is never used to filter: a repeated event repairs a
   wake that was lost."
  (with-hub-lock (hub)
    (loop for head = (first (gethash stem (hub-queues hub)))
          while head
          when (%deliver hub stem head label seq line now)
            do (%hand-gap hub stem now)
               (return t))))

(defun hub-release-stem (hub stem label id)
  "Let STEM go: every client waiting on STEM alone is answered that no
   watcher serves ID on LABEL, in its mode, and ended, and a client also waiting on another stem keeps waiting there.
   Returns the number of clients the stem held."
  (with-hub-lock (hub)
    (let ((queue (gethash stem (hub-queues hub))))
      (remhash stem (hub-queues hub))
      (dolist (conn queue)
        (setf (conn-targets conn)
              (remove stem (conn-targets conn) :key #'car :test #'string=))
        (unless (conn-targets conn)
          (%send-nowatcher hub conn id label)))
      (length queue))))

(defun hub-retry-pending (hub)
  "Resolve again every client held because the service was not ready."
  (with-hub-lock (hub)
    (dolist (conn (reverse (hub-pending hub)))
      (%dispatch hub conn))))

(defun hub-refresh (hub stem)
  "Offer STEM's head its gap again, as on promotion."
  (with-hub-lock (hub)
    (%hand-gap hub stem)))

(defun hub-ensure-delivered (hub stem value)
  "Set STEM's delivered position to VALUE when HUB has none for it yet, and
   return the position it holds."
  (with-hub-lock (hub)
    (multiple-value-bind (current found) (gethash stem (hub-positions hub))
      (if (or found (null value))
          current
          (setf (gethash stem (hub-positions hub)) value)))))

(defun hub-delivered (hub stem)
  "STEM's delivered position, or NIL when HUB has none."
  (with-hub-lock (hub)
    (values (gethash stem (hub-positions hub)))))

(defun hub-reader-count (hub stem)
  "How many clients are waiting on STEM."
  (with-hub-lock (hub)
    (length (gethash stem (hub-queues hub)))))

(defun hub-last-delivery (hub stem)
  "When STEM last had an event sent, in Unix seconds, or NIL."
  (with-hub-lock (hub)
    (values (gethash stem (hub-deliveries hub)))))

(defun hub-stems (hub)
  "The stems with clients waiting, sorted."
  (with-hub-lock (hub)
    (sort (loop for stem being the hash-keys of (hub-queues hub) collect stem)
          #'string<)))

(defun hub-snapshot (hub)
  "Every stem with clients waiting, as a list of (STEM (PID HOOK-P
   CONNECTED-AT) ...), each queue head first."
  (with-hub-lock (hub)
    (loop for stem in (hub-stems hub)
          collect (cons stem
                        (mapcar (lambda (conn)
                                  (list (conn-pid conn) (conn-hook-p conn)
                                        (conn-connected-at conn)))
                                (gethash stem (hub-queues hub)))))))
