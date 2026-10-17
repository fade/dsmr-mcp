;;;; tests/bus/host-listeners-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Zebra tests for the host service's wake-client hub, run in this process
;;;; against fake callbacks and real local-socket clients. Covered:
;;;;   - head-only delivery, and promotion with the gap handed to the next client;
;;;;   - the delivered position reported on every send;
;;;;   - the hook replace rule;
;;;;   - the readers answer and the other replies;
;;;;   - refused requests;
;;;;   - an orderly stop.
;;;;
;;;; The state home is a fresh short directory under /tmp (a socket path has to
;;;; fit in 107 bytes), and every hub and client socket a case opens is closed
;;;; when it ends.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/bus/host-listeners-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-posix)
  (require :sb-bsd-sockets))

(defpackage #:dsmr-mcp/tests/bus/host-listeners-test
  (:use #:cl #:zebra)
  (:local-nicknames (#:listeners #:dsmr-bus-host/src/bus/host/listeners)
                    (#:hostfiles #:dsmr-mcp/src/bus/hostfiles)
                    (#:selector #:dsmr-mcp/src/bus/selector)))

(in-package #:dsmr-mcp/tests/bus/host-listeners-test)

;;; ------------------------------------------------------------------ fixtures

(defvar *hubs* '()
  "Hubs started during the current case, stopped when it ends.")

(defvar *clients* '()
  "Client sockets opened during the current case, closed when it ends.")

(defstruct client
  "A test client: its socket and the octets read but not yet returned."
  socket
  (pending (make-array 0 :element-type '(unsigned-byte 8) :adjustable t
                         :fill-pointer 0)))

(defun short-temp-dir ()
  "A new empty directory directly under /tmp with a short name, so a socket
   inside it fits the unix-domain path limit."
  (loop for dir = (format nil "/tmp/h45ls-~36R~36R/" (sb-posix:getpid) (random 1000000))
        unless (probe-file dir)
          do (ensure-directories-exist dir)
             (return (pathname dir))))

(defun call-with-state (thunk)
  "Call THUNK with XDG_STATE_HOME pointing at a fresh short directory whose host
   directory exists and is private. Afterwards every client is closed, every hub
   stopped and the directory removed."
  (let ((state (short-temp-dir))
        (previous (uiop:getenv "XDG_STATE_HOME"))
        (*hubs* '())
        (*clients* '()))
    (unwind-protect
         (progn
           (sb-posix:setenv "XDG_STATE_HOME" (namestring state) 1)
           (hostfiles:ensure-host-dir)
           (funcall thunk state))
      (dolist (client *clients*)
        (ignore-errors (sb-bsd-sockets:socket-close (client-socket client))))
      (dolist (hub *hubs*)
        (ignore-errors (listeners:stop-hub hub)))
      (if previous
          (sb-posix:setenv "XDG_STATE_HOME" previous 1)
          (ignore-errors (sb-posix:unsetenv "XDG_STATE_HOME")))
      (ignore-errors (uiop:delete-directory-tree state :validate t
                                                       :if-does-not-exist :ignore)))))

(defmacro with-state ((state) &body body)
  "Run BODY inside CALL-WITH-STATE with STATE bound to the state home."
  `(call-with-state (lambda (,state) (declare (ignorable ,state)) ,@body)))

(defun targets (&rest pairs)
  "A resolve function that always answers (:TARGETS PAIRS)."
  (lambda (request)
    (declare (ignore request))
    (list :targets pairs)))

(defun start-test-hub (&rest args &key (resolve-fn (targets '("s1" . "b")))
                       &allow-other-keys)
  "A started hub made with ARGS, resolving every request with RESOLVE-FN, which
   defaults to the single target s1 labelled b."
  (let ((hub (apply #'listeners:make-hub :resolve-fn resolve-fn
                    (loop for (key value) on args by #'cddr
                          unless (eq key :resolve-fn) append (list key value)))))
    (push hub *hubs*)
    (unless (listeners:start-hub hub)
      (error "The test hub did not start."))
    hub))

(defun connect (&optional (path (hostfiles:wake-socket-path)))
  "A client connected to the socket at PATH."
  (let ((socket (make-instance 'sb-bsd-sockets:local-socket :type :stream)))
    (sb-bsd-sockets:socket-connect socket (uiop:native-namestring path))
    (let ((client (make-client :socket socket)))
      (push client *clients*)
      client)))

(defun send-text (client text)
  "Send TEXT from CLIENT as UTF-8."
  (sb-bsd-sockets:socket-send (client-socket client)
                              (sb-ext:string-to-octets text :external-format :utf-8)
                              nil :nosignal t))

(defun hang-up (client)
  "Close CLIENT's socket."
  (sb-bsd-sockets:socket-close (client-socket client))
  (setf *clients* (remove client *clients*)))

(defun wake-line (&key (hook 0) (pid 100) (agent "a"))
  "A version 1 wake request with a newline."
  (format nil "WAKE 1 hook=~D allbuses=0 agent=~A ns=/home/x agentid=- envagent=- ~
               bus=- envbus=- cwd=- pid=~D~%"
          hook agent pid))

(defun read-reply (client &optional (seconds 2))
  "The next line CLIENT receives within SECONDS, without its newline, :EOF when
   the connection was closed, or :TIMEOUT when no whole line arrived."
  (let* ((socket (client-socket client))
         (fd (sb-bsd-sockets:socket-file-descriptor socket))
         (deadline (+ (get-internal-real-time)
                      (round (* seconds internal-time-units-per-second))))
         (chunk (make-array 4096 :element-type '(unsigned-byte 8))))
    (loop
      (let* ((buffer (client-pending client))
             (newline (position 10 buffer)))
        (when newline
          (let ((line (sb-ext:octets-to-string (subseq buffer 0 newline)
                                               :external-format :utf-8))
                (rest (make-array (- (length buffer) newline 1)
                                  :element-type '(unsigned-byte 8) :adjustable t
                                  :fill-pointer (- (length buffer) newline 1))))
            (replace rest buffer :start2 (1+ newline))
            (setf (client-pending client) rest)
            (return line))))
      (let ((remaining (/ (- deadline (get-internal-real-time))
                          internal-time-units-per-second)))
        (when (<= remaining 0)
          (return :timeout))
        (when (sb-sys:wait-until-fd-usable fd :input remaining nil)
          (let ((count (handler-case
                           (nth-value 1 (sb-bsd-sockets:socket-receive socket chunk nil))
                         (error () 0))))
            (if (or (null count) (zerop count))
                (return :eof)
                (loop for index below count
                      do (vector-push-extend (aref chunk index)
                                             (client-pending client))))))))))

(defun eventually (thunk &optional (seconds 3))
  "The first true value THUNK returns within SECONDS, or NIL."
  (loop with deadline = (+ (get-internal-real-time)
                           (* seconds internal-time-units-per-second))
        for value = (funcall thunk)
        when value
          return value
        when (> (get-internal-real-time) deadline)
          return nil
        do (sleep 0.02)))

(defun queued (hub stem count)
  "True once STEM has COUNT clients waiting on HUB."
  (eventually (lambda () (= count (listeners:hub-reader-count hub stem)))))

(defun mode-bits (path)
  "The permission bits of PATH."
  (logand #o777 (sb-posix:stat-mode (sb-posix:stat (uiop:native-namestring path)))))

;;; ------------------------------------------------------------- the requests

(define-test parse-request-reads-every-field
  "A wake request yields every field decoded, missing fields read as absent,
   and the readers request yields its id and bus."
  (multiple-value-bind (request code)
      (listeners:parse-request
       "WAKE 1 hook=1 allbuses=0 agent=a%20b ns=/home/x agentid=- envagent=e bus=dsmr envbus=- cwd=/w pid=42")
    (is eq nil code)
    (is eq :wake (getf request :kind))
    (is eq t (getf request :hook-p))
    (is eq nil (getf request :all-buses-p))
    (is string= "a b" (getf request :agent))
    (is string= "/home/x" (getf request :namespace))
    (is eq nil (getf request :agent-id))
    (is string= "e" (getf request :env-agent))
    (is string= "dsmr" (getf request :bus))
    (is eq nil (getf request :env-bus))
    (is string= "/w" (getf request :cwd))
    (is eql 42 (getf request :pid)))
  (let ((request (listeners:parse-request "WAKE 1 agent=a")))
    (is eq :wake (getf request :kind))
    (is eq nil (getf request :cwd))
    (is eq nil (getf request :pid)))
  (let ((request (listeners:parse-request "READERS 1 id=/home/x/a bus=-")))
    (is eq :readers (getf request :kind))
    (is string= "/home/x/a" (getf request :id))
    (is eq nil (getf request :bus))))

(define-test malformed-requests-are-refused-by-the-parser
  "A request the parser cannot trust is refused with a code and no plist."
  (dolist (line '("" "WAKE" "FOO 1 agent=a" "WAKE x agent=a" "WAKE 1 hook=2"
                  "WAKE 1 agent=%G1" "WAKE 1 agent=a agent=b" "WAKE 1  agent=a"
                  "WAKE 1 agent=a " "WAKE 1 colour=red" "WAKE 1 pid=12a"
                  "READERS 1 agent=a" "WAKE 1 agent"))
    (multiple-value-bind (request code) (listeners:parse-request line)
      (is eq nil request)
      (is eq :bad-request code)))
  (multiple-value-bind (request code) (listeners:parse-request "WAKE 2 agent=a")
    (is eq nil request)
    (is eq :version code)))

(define-test request-identity-resolves-like-the-watcher
  "The id comes from agentid, else the agent name in the namespace, else the
   name in the working directory; the bus from bus, else envbus."
  (flet ((ident (&rest request) (multiple-value-list (listeners:request-identity request))))
    (is equal '("/p/q" nil nil) (ident :agent-id "/p//q/" :agent "a" :namespace "/n"))
    (is equal '("/n/a" nil nil) (ident :agent "a" :namespace "/n/"))
    (is equal '("/n/e" nil nil) (ident :agent "" :env-agent "e" :namespace "/n"))
    (is equal '("a" nil nil) (ident :agent "a" :namespace "" :cwd "/w"))
    (is equal '("/w/x/a" nil nil) (ident :agent "a" :cwd "/w/x"))
    (is equal '(nil nil nil) (ident :namespace "/n"))
    (is equal '("/n/a" "dsmr" t) (ident :agent "a" :namespace "/n" :bus "dsmr"
                                        :env-bus "other" :all-buses-p t))
    (is equal '("/n/a" "other" nil) (ident :agent "a" :namespace "/n" :bus ""
                                           :env-bus "other"))
    (fail (listeners:request-identity '(:agent "a" :namespace "/n" :bus "a/b"))
        selector:invalid-bus-name)))

;;; ------------------------------------------------------------------ delivery

(define-test an-event-goes-to-the-head-only
  "Two clients wait; an event reaches the first alone, which leaves the queue
   at once, so the next event reaches the second."
  (with-state (state)
    (let ((hub (start-test-hub))
          (a (connect)))
      (send-text a (wake-line :pid 1))
      (true (queued hub "s1" 1))
      (let ((b (connect)))
        (send-text b (wake-line :pid 2))
        (true (queued hub "s1" 2))
        (true (listeners:hub-offer hub "s1" "b" 7 "bus:7 from=x"))
        (is string= "EVENT b bus:7 from=x" (read-reply a))
        (is eq :timeout (read-reply b 0.3))
        (is = 1 (listeners:hub-reader-count hub "s1"))
        (true (listeners:hub-offer hub "s1" "b" 8 "bus:8 from=x"))
        (is string= "EVENT b bus:8 from=x" (read-reply b))
        (is eq :eof (read-reply a))
        (false (listeners:hub-offer hub "s1" "b" 9 "bus:9"))))))

(define-test a-closed-head-hands-the-gap-to-the-next
  "When the head goes without a delivery, the next client is promoted and
   handed what arrived since the delivered position."
  (with-state (state)
    (let* ((gap-ready nil)
           (asked '())
           (hub (start-test-hub
                 :gap-fn (lambda (stem delivered)
                           (push (list stem delivered) asked)
                           (when gap-ready (values "bus:9 from=y" 9)))))
           (a (connect))
           (b (connect)))
      (send-text a (wake-line :pid 1))
      (true (queued hub "s1" 1))
      (send-text b (wake-line :pid 2))
      (true (queued hub "s1" 2))
      (setf gap-ready t)
      (hang-up a)
      (is string= "EVENT b bus:9 from=y" (read-reply b))
      (is eql 9 (listeners:hub-delivered hub "s1"))
      (is = 0 (listeners:hub-reader-count hub "s1"))
      (true (member '("s1" nil) asked :test #'equal)))))

(define-test every-send-reports-the-delivered-position
  "Each send hands the new position to DELIVERED-FN and writes no file; a hub
   that has not been told a position knows none until it is supplied, and then
   asks for the gap from it."
  (with-state (state)
    (let* ((calls '())
           (hub (start-test-hub
                 :delivered-fn (lambda (stem seq now) (push (list stem seq now) calls))))
           (a (connect)))
      (send-text a (wake-line))
      (true (queued hub "s1" 1))
      (true (listeners:hub-offer hub "s1" "b" 12 "bus:12" :now 1000))
      (is equal '(("s1" 12 1000)) calls)
      (is eql 12 (listeners:hub-delivered hub "s1"))
      (is eql 1000 (listeners:hub-last-delivery hub "s1"))
      (false (probe-file (hostfiles:delivered-position-path "s1")))
      (let* ((path (merge-pathnames "wake2.sock" (hostfiles:host-dir)))
             (asked '())
             (hub2 (start-test-hub :socket-path path
                                   :gap-fn (lambda (stem delivered)
                                             (push (list stem delivered) asked)
                                             nil))))
        (is eq nil (listeners:hub-delivered hub2 "s1"))
        (listeners:hub-ensure-delivered hub2 "s1" 12)
        (let ((c (connect path)))
          (send-text c (wake-line))
          (true (eventually (lambda () asked)))
          (is equal '(("s1" 12)) asked))))))

(define-test ensure-delivered-sets-a-position-once-and-writes-no-file
  "A supplied starting position is kept, a later one is ignored, and nothing
   lands on disk."
  (with-state (state)
    (let ((hub (start-test-hub)))
      (listeners:hub-ensure-delivered hub "s2" 30)
      (is eql 30 (listeners:hub-delivered hub "s2"))
      (listeners:hub-ensure-delivered hub "s2" 40)
      (is eql 30 (listeners:hub-delivered hub "s2"))
      (false (probe-file (hostfiles:delivered-position-path "s2")))
      (is eq nil (ignore-errors (uiop:directory-files (hostfiles:watch-state-dir)))))))

(define-test every-send-is-reported-as-wake-delivered
  "Each send is reported once at INFO, naming the seq, the label, the client's
   pid and whether it was a hook or a background client."
  (with-state (state)
    (let* ((reports '())
           (hub (start-test-hub
                 :report-fn (lambda (level code &key bus id subject msg)
                              (declare (ignore id subject))
                              (push (list level code bus msg) reports))))
           (h (connect)))
      (send-text h (wake-line :hook 1 :pid 41))
      (true (queued hub "s1" 1))
      (true (listeners:hub-offer hub "s1" "b" 5 "bus:5"))
      (let ((b (connect)))
        (send-text b (wake-line :pid 42))
        (true (queued hub "s1" 1))
        (true (listeners:hub-offer hub "s1" "b" 6 "bus:6")))
      (let ((sent (reverse (remove "wake-delivered" reports :key #'second
                                                            :test-not #'string=))))
        (is = 2 (length sent))
        (destructuring-bind (level code bus msg) (first sent)
          (is eq :info level)
          (is string= "wake-delivered" code)
          (is string= "b" bus)
          (true (search "seq=5" msg))
          (true (search "label=b" msg))
          (true (search "pid=41" msg))
          (true (search "hook" msg)))
        (true (search "seq=6" (fourth (second sent))))
        (true (search "pid=42" (fourth (second sent))))
        (true (search "background" (fourth (second sent))))))))

;;; ---------------------------------------------------------------- hook rule

(define-test a-newer-hook-supersedes-the-older
  "A second hook client for an identity replaces the first, which is told it
   was superseded and closed."
  (with-state (state)
    (let ((hub (start-test-hub))
          (h1 (connect)))
      (send-text h1 (wake-line :hook 1 :pid 1))
      (true (queued hub "s1" 1))
      (let ((h2 (connect)))
        (send-text h2 (wake-line :hook 1 :pid 2))
        (is string= "SUPERSEDED" (read-reply h1))
        (is eq :eof (read-reply h1))
        (is = 1 (listeners:hub-reader-count hub "s1"))
        (true (listeners:hub-offer hub "s1" "b" 3 "bus:3"))
        (is string= "EVENT b bus:3" (read-reply h2))))))

(define-test a-hook-is-served-ahead-of-background-clients
  "A hook client goes to the head of the queue; background clients keep their
   order behind it."
  (with-state (state)
    (let ((hub (start-test-hub))
          (b (connect)))
      (send-text b (wake-line :pid 1))
      (true (queued hub "s1" 1))
      (let ((h (connect)))
        (send-text h (wake-line :hook 1 :pid 2))
        (true (queued hub "s1" 2))
        (is equal '((2 t) (1 nil))
            (mapcar (lambda (entry) (subseq entry 0 2))
                    (rest (first (listeners:hub-snapshot hub)))))
        (true (listeners:hub-offer hub "s1" "b" 4 "bus:4"))
        (is string= "EVENT b bus:4" (read-reply h))
        (is eq :timeout (read-reply b 0.3))
        (true (listeners:hub-offer hub "s1" "b" 5 "bus:5"))
        (is string= "EVENT b bus:5" (read-reply b))))))

;;; ------------------------------------------------------------------- answers

(define-test readers-counts-the-clients-of-one-identity
  "A readers request is answered with the number of clients waiting for that
   identity, then closed."
  (with-state (state)
    (let* ((stem (hostfiles:detach-stem nil "/home/x/a"))
           (hub (start-test-hub :resolve-fn (targets (cons stem "default")))))
      (dolist (pid '(1 2))
        (send-text (connect) (wake-line :pid pid)))
      (true (queued hub stem 2))
      (is equal (list stem) (listeners:hub-stems hub))
      (let ((probe (connect)))
        (send-text probe (format nil "READERS 1 id=/home/x/a bus=-~%"))
        (is string= "READERS 2" (read-reply probe))
        (is eq :eof (read-reply probe)))
      (let ((probe (connect)))
        (send-text probe (format nil "READERS 1 id=/home/x/nobody bus=-~%"))
        (is string= "READERS 0" (read-reply probe))))))

(define-test an-unready-service-holds-the-client-until-retry
  "While the service cannot resolve yet, the client is held with no reply; a
   retry once it can queues the client."
  (with-state (state)
    (let* ((ready nil)
           (hub (start-test-hub :resolve-fn (lambda (request)
                                              (declare (ignore request))
                                              (if ready
                                                  (list :targets '(("s1" . "b")))
                                                  (list :unready)))))
           (c (connect)))
      (send-text c (wake-line))
      (is eq :timeout (read-reply c 0.3))
      (is = 0 (listeners:hub-reader-count hub "s1"))
      (setf ready t)
      (listeners:hub-retry-pending hub)
      (true (queued hub "s1" 1)))))

(define-test nowatcher-answers-carry-the-due-flag
  "An identity with no watcher is answered NOWATCHER with the label, the
   encoded id and whether the hourly notice is due."
  (with-state (state)
    (let ((due t)
          (asked '()))
      (start-test-hub :resolve-fn (lambda (request)
                                    (declare (ignore request))
                                    (list :nowatcher "ns/a b" "b"))
                      :nowatcher-fn (lambda (id hook-p)
                                      (push (list id hook-p) asked)
                                      due))
      (let ((c (connect)))
        (send-text c (wake-line :hook 1))
        (is string= "NOWATCHER b ns/a%20b due=1" (read-reply c))
        (is eq :eof (read-reply c)))
      (setf due nil)
      (let ((c (connect)))
        (send-text c (wake-line))
        (is string= "NOWATCHER b ns/a%20b due=0" (read-reply c)))
      (is equal '(("ns/a b" nil) ("ns/a b" t)) asked))))

(define-test releasing-a-stem-ends-only-clients-left-with-nothing
  "A released identity tells a client waiting on it alone that no watcher
   remains; a client still waiting on another identity keeps waiting."
  (with-state (state)
    (let* ((hub (start-test-hub
                 :resolve-fn (lambda (request)
                               (if (eql 1 (getf request :pid))
                                   (list :targets '(("s1" . "b")))
                                   (list :targets '(("s1" . "b") ("s2" . "c")))))))
           (one (connect))
           (two (connect)))
      (send-text one (wake-line :pid 1))
      (true (queued hub "s1" 1))
      (send-text two (wake-line :pid 2))
      (true (queued hub "s2" 1))
      (listeners:hub-release-stem hub "s1" "b" "ns/a")
      (is string= "NOWATCHER b ns/a due=0" (read-reply one))
      (is eq :eof (read-reply one))
      (is eq :timeout (read-reply two 0.3))
      (is = 0 (listeners:hub-reader-count hub "s1"))
      (is = 1 (listeners:hub-reader-count hub "s2")))))

(define-test a-bad-bus-is-answered-with-err
  "A bus name the service rejects is answered ERR bad-bus with the reason."
  (with-state (state)
    (start-test-hub :resolve-fn (lambda (request)
                                  (declare (ignore request))
                                  (list :bad-bus "x")))
    (let ((c (connect)))
      (send-text c (wake-line))
      (is string= "ERR bad-bus x" (read-reply c))
      (is eq :eof (read-reply c)))))

;;; ----------------------------------------------------------------- refusals

(define-test an-oversized-request-is-refused
  "A request line over 8192 bytes is answered ERR bad-request and closed."
  (with-state (state)
    (start-test-hub)
    (let ((c (connect)))
      (send-text c (format nil "~A~%" (make-string 9000 :initial-element #\A)))
      (let ((reply (read-reply c)))
        (true (and (stringp reply) (uiop:string-prefix-p "ERR bad-request " reply))))
      (is eq :eof (read-reply c)))))

(define-test an-unknown-version-or-key-is-refused
  "A request in another protocol version is answered ERR version, one with an
   unknown key ERR bad-request, and neither disturbs a waiting client."
  (with-state (state)
    (let ((hub (start-test-hub))
          (waiting (connect)))
      (send-text waiting (wake-line))
      (true (queued hub "s1" 1))
      (let ((c (connect)))
        (send-text c (format nil "WAKE 2 hook=0~%"))
        (let ((reply (read-reply c)))
          (true (and (stringp reply) (uiop:string-prefix-p "ERR version " reply)))))
      (let ((c (connect)))
        (send-text c (format nil "WAKE 1 colour=red~%"))
        (let ((reply (read-reply c)))
          (true (and (stringp reply) (uiop:string-prefix-p "ERR bad-request " reply)))))
      (is = 1 (listeners:hub-reader-count hub "s1"))
      (true (listeners:hub-offer hub "s1" "b" 1 "bus:1"))
      (is string= "EVENT b bus:1" (read-reply waiting)))))

(define-test a-slow-request-is-closed-after-the-window
  "A client that sends half a line and waits is answered ERR bad-request and
   closed once the request window ends."
  (with-state (state)
    (start-test-hub :request-seconds 1)
    (let ((c (connect)))
      (send-text c "WAKE 1 hook=0")
      (is eq :timeout (read-reply c 0.5))
      (let ((reply (read-reply c 2)))
        (true (and (stringp reply) (uiop:string-prefix-p "ERR bad-request " reply))))
      (is eq :eof (read-reply c)))))

(define-test a-full-queue-answers-busy
  "Past the per-identity cap a new client is answered ERR busy."
  (with-state (state)
    (let ((hub (start-test-hub :per-identity-cap 2)))
      (dolist (pid '(1 2))
        (send-text (connect) (wake-line :pid pid)))
      (true (queued hub "s1" 2))
      (let ((c (connect)))
        (send-text c (wake-line :pid 3))
        (let ((reply (read-reply c)))
          (true (and (stringp reply) (uiop:string-prefix-p "ERR busy " reply))))
        (is eq :eof (read-reply c)))
      (is = 2 (listeners:hub-reader-count hub "s1")))))

(define-test a-vanished-client-does-not-stop-the-hub
  "A client that goes before its event fails only its own connection: the
   event reaches the next client, and a later client is still served."
  (with-state (state)
    (let ((hub (start-test-hub))
          (a (connect)))
      (send-text a (wake-line :pid 1))
      (true (queued hub "s1" 1))
      (hang-up a)
      (false (listeners:hub-offer hub "s1" "b" 1 "bus:1"))
      (let ((b (connect))
            (c (connect)))
        (send-text b (wake-line :pid 2))
        (true (queued hub "s1" 1))
        (send-text c (wake-line :pid 3))
        (true (queued hub "s1" 2))
        (hang-up b)
        (true (listeners:hub-offer hub "s1" "b" 2 "bus:2"))
        (is string= "EVENT b bus:2" (read-reply c)))
      (let ((d (connect)))
        (send-text d (wake-line :pid 4))
        (true (queued hub "s1" 1))
        (true (listeners:hub-offer hub "s1" "b" 3 "bus:3"))
        (is string= "EVENT b bus:3" (read-reply d))))))

;;; -------------------------------------------------------- the socket itself

(define-test stopping-the-hub-closes-every-client
  "The accept loop makes progress while the hub runs; a stop closes every
   client and removes the socket file."
  (with-state (state)
    (let ((hub (start-test-hub))
          (a (connect))
          (b (connect)))
      (send-text a (wake-line :pid 1))
      (send-text b (wake-line :pid 2))
      (true (queued hub "s1" 2))
      (let ((before (listeners:hub-progress hub)))
        (true (eventually (lambda () (> (listeners:hub-progress hub) before)))))
      (listeners:stop-hub hub)
      (is eq :eof (read-reply a))
      (is eq :eof (read-reply b))
      (false (probe-file (hostfiles:wake-socket-path)))
      (is = 0 (listeners:hub-reader-count hub "s1")))))

(define-test the-socket-is-private-and-refused-when-unsafe
  "The socket is readable by its owner alone; a path too long for a socket or
   a host directory open to others stops the hub from listening."
  (with-state (state)
    (start-test-hub)
    (is = #o600 (mode-bits (hostfiles:wake-socket-path)))
    (let* ((reports '())
           (report (lambda (level code &key bus id subject msg)
                     (declare (ignore bus id subject msg))
                     (push (list level code) reports)))
           (long (format nil "/tmp/~A/wake.sock" (make-string 110 :initial-element #\a))))
      (is eq nil (listeners:start-hub
                  (listeners:make-hub :socket-path long :report-fn report)))
      (true (member '(:error "wake-socket-refused") reports :test #'equal))
      (setf reports '())
      (let ((dir (merge-pathnames "open/" state)))
        (ensure-directories-exist dir)
        (sb-posix:chmod (uiop:native-namestring dir) #o755)
        (is eq nil (listeners:start-hub
                    (listeners:make-hub :socket-path (merge-pathnames "wake.sock" dir)
                                        :report-fn report)))
        (true (member '(:error "wake-socket-refused") reports :test #'equal))
        (false (probe-file (merge-pathnames "wake.sock" dir)))))))
