;;;; tests/integration/bus/wake-front-end-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Cross-process cases for the bus watcher command as `make bus-watch` builds
;;;; it: the static C front end in bin/dsmr-bus-watch and the SBCL program
;;;; beside it in bin/dsmr-bus-watch-lisp, run against the real
;;;; bin/dsmr-bus-host.
;;;;
;;;; What the cases hold the build to:
;;;; - the front end is small and statically linked;
;;;; - every mode but a wake answers through the front end exactly as the SBCL
;;;;   program answers when run directly;
;;;; - a waiting wake is one small process with one thread and one socket;
;;;; - twenty waiting wakes cost a small share of memory each, where SBCL
;;;;   listeners do not;
;;;; - a fleet-log wake runs the SBCL program;
;;;; - a front end with no SBCL program beside it says so.
;;;;
;;;; Each case runs under its own state root (see host-support) with the real
;;;; service started in it. A missing binary skips the case, and a skip is a
;;;; failure for the runner this file is meant to be run by. Only processes a
;;;; case started are ever signalled.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/integration/bus/wake-front-end-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-posix))

(defpackage #:dsmr-mcp/tests/integration/bus/wake-front-end-test
  (:use #:cl #:zebra)
  (:local-nicknames (#:hostfiles #:dsmr-mcp/src/bus/hostfiles))
  (:import-from #:dsmr-mcp/tests/integration/bus/host-support
                #:watcher-binary
                #:lisp-watcher-binary
                #:host-binary
                #:run-in
                #:identity-args
                #:field
                #:await-true
                #:with-host-state
                #:with-state-home
                #:start-service
                #:stop-process
                #:notify-calls
                #:launch-wake
                #:finish-wake
                #:publish
                #:process-exe
                #:process-comm
                #:process-status-field
                #:process-pss-kb
                #:median-pss-kb
                #:process-fd-targets))

(in-package #:dsmr-mcp/tests/integration/bus/wake-front-end-test)

;;; ------------------------------------------------------------------ fixtures

(defparameter *bus* "fe"
  "The bus every case arms on. Short, so the bus's socket paths stay under the
   kernel's limit beneath a state root in /tmp.")

(defparameter *ns* "/dsmr-host-it/fe/"
  "The namespace the agents the service watches live in.")

(defparameter *other* "/dsmr-host-it/peer/teller"
  "The agent that sends them mail, from a namespace of its own.")

(defparameter +hook-input+ "{\"hook_event_name\":\"Stop\"}"
  "What the harness hands a Stop hook on its standard input.")

(defparameter +varying-keys+
  '("age_s" "beat-age" "status-age" "since" "available" "some")
  "Keys whose values are ages, times or memory pressure, which two runs a moment
   apart may answer differently.")

(defmacro with-binaries (&body body)
  "Run BODY when the front end, the SBCL program and the service are all built,
   and skip the case otherwise. A real branch, so a skip never runs the body."
  `(if (and (watcher-binary) (lisp-watcher-binary) (host-binary))
       (progn ,@body)
       (skip ("bin/dsmr-bus-watch, bin/dsmr-bus-watch-lisp or bin/dsmr-bus-host is missing; run 'make bus-watch bus-host'"))))

(defun agent (n)
  "The name of the Nth agent."
  (format nil "a~D" n))

(defun args (name)
  "The watcher flags naming the agent NAME on the case's bus."
  (identity-args *bus* *ns* name))

(defun detach (state name)
  "Register NAME with the service under STATE through the front end;
   (values stdout stderr code)."
  (apply #'run-in state (watcher-binary) "--detach" "--poll-ms" "50" (args name)))

(defun check-live (state name)
  "NAME's --check-live line under STATE."
  (values (apply #'run-in state (watcher-binary) "--check-live" (args name))))

(defun await-served (state service name &key (seconds 15))
  "True once NAME's probe under STATE answers live with SERVICE as its watcher,
   waiting up to SECONDS. Discovery of a new bus runs every five seconds."
  (await-true (lambda ()
                (eql 0 (search (format nil "live pid=~D " service)
                               (check-live state name))))
              seconds))

(defun register-all (state service names)
  "Register every agent in NAMES with SERVICE under STATE, and return true when
   the service answers for all of them."
  (dolist (name names)
    (detach state name))
  (every (lambda (name) (await-served state service name)) names))

(defun mask (text)
  "TEXT with the value of every KEY=VALUE word whose key is in +VARYING-KEYS+
   replaced by #."
  (format nil "~{~A~^~%~}"
          (mapcar (lambda (line)
                    (format nil "~{~A~^ ~}"
                            (mapcar (lambda (word)
                                      (let ((eq (position #\= word)))
                                        (if (and eq (member (subseq word 0 eq)
                                                            +varying-keys+
                                                            :test #'string=))
                                            (concatenate 'string
                                                         (subseq word 0 (1+ eq)) "#")
                                            word)))
                                    (uiop:split-string line :separator " "))))
                  (uiop:split-string text :separator (string #\Newline)))))

(defun answer (state bin &rest arguments)
  "Run BIN with ARGUMENTS under STATE, and return (stdout stderr code), both
   outputs masked."
  (multiple-value-bind (out err code) (apply #'run-in state bin arguments)
    (list (mask out) (mask err) code)))

(defun both-answers (state &rest arguments)
  "ARGUMENTS run under STATE through the front end and through the SBCL program
   directly, one after the other; (values front-end-answer direct-answer)."
  (values (apply #'answer state (watcher-binary) arguments)
          (apply #'answer state (lisp-watcher-binary) arguments)))

(defun file-size (path)
  "The size of the file at PATH in bytes."
  (with-open-file (in path :element-type '(unsigned-byte 8))
    (file-length in)))

(defun extra-fds (pid)
  "PID's open descriptors other than 0, 1 and 2, as (FD . TARGET) pairs."
  (remove-if (lambda (entry) (<= (car entry) 2)) (process-fd-targets pid)))

(defun average-pss-kb (pids)
  "The mean PSS in kB over PIDS, or NIL when any reading fails."
  (let ((readings (mapcar #'process-pss-kb pids)))
    (unless (member nil readings)
      (/ (reduce #'+ readings) (length readings)))))

(defun launch-waits (state names &key (binary (watcher-binary)) extra)
  "Start one waiting wake per agent in NAMES under STATE, with EXTRA flags, and
   return the processes."
  (mapcar (lambda (name)
            (launch-wake state (append (list "--wake" "--wake-seconds" "120")
                                       extra (args name))
                         :binary binary))
          names))

(defun pids (processes)
  "The pids of PROCESSES."
  (mapcar #'uiop:process-info-pid processes))

;;; ------------------------------------------------------------------ the build

(define-test the-installed-front-end-is-small-and-static
  "The front end `make bus-watch` writes is statically linked and under
   2,000,000 bytes."
  (with-binaries
    (with-host-state (state)
      (start-service state)
      (let ((bin (watcher-binary)))
        (true (search "statically linked"
                      (uiop:run-program (list "file" (uiop:native-namestring bin))
                                        :output :string))
              "file does not call ~A statically linked" bin)
        (true (< (file-size bin) 2000000) "~:D bytes" (file-size bin))))))

(define-test a-front-end-without-its-lisp-program-says-so
  "A copy of the front end alone in a directory, asked for --help, exits 127
   and names the SBCL program it could not run."
  (with-binaries
    (with-host-state (state)
      (start-service state)
      (let ((lone (merge-pathnames "lone/dsmr-bus-watch" state)))
        (ensure-directories-exist lone)
        (uiop:copy-file (watcher-binary) lone)
        (sb-posix:chmod (uiop:native-namestring lone) #o755)
        (multiple-value-bind (out err code) (run-in state lone "--help")
          (is eql 127 code "stdout ~S stderr ~S" out err)
          (is string= "" out)
          (true (search "dsmr-bus-watch-lisp" err) "~S" err))))))

;;; ---------------------------------------------- modes the SBCL program answers

(define-test help-check-live-and-host-status-answer-as-the-sbcl-program
  "--help, --check-live for a registered agent and with no identity, and
   --host-status give the same stdout, stderr and exit code through the front
   end as from the SBCL program run directly, ages and times masked."
  (with-binaries
    (with-host-state (state)
      (let ((service (start-service state)))
        (true (register-all state service (list "alpha")))
        (dolist (arguments (list (list "--help")
                                 (list* "--check-live" (args "alpha"))
                                 (list "--check-live")
                                 (list "--host-status")))
          (multiple-value-bind (front direct) (apply #'both-answers state arguments)
            (is equal direct front "~{~A~^ ~}" arguments)))))))

(define-test host-failed-answers-as-the-sbcl-program
  "--host-failed through the front end and from the SBCL program, each under
   its own state root so neither falls in the other's alarm window, answers
   alike and raises one fleet line and one notification."
  (with-binaries
    (flet ((one-run (bin)
             (with-host-state (state)
               (start-service state)
               (multiple-value-bind (out err code) (run-in state bin "--host-failed")
                 (list (list (mask out) (mask err) code)
                       (length (remove-if-not
                                (lambda (line)
                                  (search " FLEET ERROR code=service-failed " line))
                                (or (ignore-errors
                                     (uiop:read-file-lines
                                      (merge-pathnames "dsmr-mcp/host/fleet-error.log"
                                                       state)))
                                    '())))
                       (length (notify-calls state)))))))
      (let ((front (one-run (watcher-binary)))
            (direct (one-run (lisp-watcher-binary))))
        (is equal (first direct) (first front))
        (is equal '(1 1) (rest front) "fleet lines and notifications: ~S" front)
        (is equal '(1 1) (rest direct) "fleet lines and notifications: ~S" direct)))))

(define-test park-and-reap-answer-as-the-sbcl-program
  "--park, --unpark and --reap give the same stdout, stderr and exit code
   through the front end as from the SBCL program, each run from the same
   starting state."
  (with-binaries
    (with-host-state (state)
      (let ((service (start-service state)))
        (true (register-all state service (list "alpha")))
        (let* ((front-park (apply #'answer state (watcher-binary) "--park" (args "alpha")))
               (front-unpark (apply #'answer state (watcher-binary) "--unpark" (args "alpha")))
               (direct-park (apply #'answer state (lisp-watcher-binary) "--park"
                                   (args "alpha")))
               (direct-unpark (apply #'answer state (lisp-watcher-binary) "--unpark"
                                     (args "alpha"))))
          (is equal direct-park front-park)
          (is equal direct-unpark front-unpark)
          (is eql 0 (third front-park) "~S" front-park))
        (let ((front-reap (apply #'answer state (watcher-binary) "--reap" (args "alpha"))))
          (true (register-all state service (list "alpha")) "re-registered after a reap")
          (let ((direct-reap (apply #'answer state (lisp-watcher-binary) "--reap"
                                    (args "alpha"))))
            (is equal direct-reap front-reap)
            (true (search (format nil "reaped pid=~D " service) (first front-reap))
                  "~S" front-reap)))))))

(define-test detach-through-the-front-end-registers-with-the-service
  "--detach through the front end registers the agent: it names the service as
   its watcher and the service then answers the agent's probe."
  (with-binaries
    (with-host-state (state)
      (let ((service (start-service state)))
        (multiple-value-bind (out err code) (detach state "alpha")
          (is eql 0 code "stderr ~S" err)
          (true (eql 0 (search (format nil "detached pid=~D " service) out)) "~S" out))
        (true (await-served state service "alpha"))))))

;;; ---------------------------------------------------------- a waiting wake

(defun check-one-small-process (pid)
  "Assert that PID is the front end waiting on one socket: its executable and
   command name, one thread, VmRSS under 1024 kB, and exactly one descriptor
   besides 0, 1 and 2, a socket."
  (let ((exe (process-exe pid))
        (extra (extra-fds pid)))
    (true (and exe (uiop:string-suffix-p exe "/dsmr-bus-watch")) "exe ~S" exe)
    (is equal "dsmr-bus-watch" (process-comm pid))
    (is eql 1 (process-status-field pid "Threads"))
    (let ((rss (process-status-field pid "VmRSS")))
      (true (and rss (< rss 1024)) "VmRSS ~S kB" rss)
      (format t "~&  waiting client pid=~D VmRSS=~D kB fds=~S~%"
              pid rss (process-fd-targets pid)))
    (is eql 1 (length extra) "descriptors ~S" extra)
    (true (and extra (uiop:string-prefix-p "socket:" (cdr (first extra))))
          "descriptors ~S" extra)))

(define-test a-waiting-wake-is-one-small-process
  "A registered agent's --wake, and separately its --wake --hook given the
   hook's input, is after a second one process running the front end with one
   thread, VmRSS under 1024 kB and one socket, and each still hears its mail."
  (with-binaries
    (with-host-state (state)
      (let ((service (start-service state)))
        (true (register-all state service (list "alpha")))
        (let ((wake (launch-wake state (list* "--wake" "--wake-seconds" "30"
                                              (args "alpha")))))
          (sleep 1)
          (true (uiop:process-alive-p wake))
          (check-one-small-process (uiop:process-info-pid wake))
          (let ((seq (publish state *bus* *other* :text "for the wake")))
            (multiple-value-bind (code out err) (finish-wake wake 10)
              (is eql 0 code "stderr ~S" err)
              (true (eql 0 (search (format nil "bus:~D from=" seq) out)) "~S" out))))
        (let ((hook (launch-wake state (list* "--wake" "--hook" "--wake-seconds" "30"
                                              (args "alpha"))
                                 :hook-input +hook-input+)))
          (sleep 1)
          (true (uiop:process-alive-p hook))
          (check-one-small-process (uiop:process-info-pid hook))
          (let ((seq (publish state *bus* *other* :text "for the hook")))
            (multiple-value-bind (code out err) (finish-wake hook 10)
              (is eql 2 code "stdout ~S stderr ~S" out err)
              (true (eql 0 (search (format nil "bus:~D from=" seq) err)) "~S" err))))))))

(define-test twenty-waiting-wakes-share-memory
  "Twenty agents' waiting wakes average under 200 kB PSS each, and one
   broadcast wakes all twenty. The control: three SBCL fleet-log listeners
   measured the same way average over 200 kB, so the bound can fail."
  (with-binaries
    (with-host-state (state)
      (let* ((service (start-service state))
             (names (loop for n from 0 below 20 collect (agent n))))
        (true (register-all state service names))
        (let ((wakes (launch-waits state names)))
          (sleep 1)
          (true (every #'uiop:process-alive-p wakes) "every client is still waiting")
          (let ((average (average-pss-kb (pids wakes))))
            (format t "~&  twenty wake clients: average PSS ~,1F kB~%" average)
            (true (and average (< average 200)) "average PSS ~S kB" average))
          (publish state *bus* *other* :text "for all twenty")
          (dolist (wake wakes)
            (multiple-value-bind (code out err) (finish-wake wake 10)
              (is eql 0 code "stdout ~S stderr ~S" out err))))
        (let ((listeners (launch-waits state (subseq names 0 3)
                                       :binary (lisp-watcher-binary)
                                       :extra (list "--fleet-log"))))
          (sleep 2)
          (true (every #'uiop:process-alive-p listeners) "every listener is waiting")
          (let ((average (average-pss-kb (pids listeners))))
            (format t "~&  three SBCL fleet-log listeners: average PSS ~,1F kB~%" average)
            (true (and average (> average 200)) "average PSS ~S kB" average)))))))

;;; ------------------------------------------------------------ the fleet log

(define-test fleet-log-wake-runs-the-sbcl-program
  "--wake --fleet-log through the front end runs the SBCL program, which
   prints the next fleet line and exits 0."
  (with-binaries
    (with-host-state (state)
      (start-service state)
      (let ((wake (launch-wake state (list* "--wake" "--fleet-log" "--wake-seconds" "30"
                                            (args "alpha")))))
        (sleep 1.5)
        (let ((exe (process-exe (uiop:process-info-pid wake))))
          (true (and exe (uiop:string-suffix-p exe "/dsmr-bus-watch-lisp")) "exe ~S" exe))
        (let ((line (hostfiles:fleet-line :error "front-end" :bus *bus*
                                          :msg "through the front end")))
          (with-state-home (state)
            (hostfiles:append-fleet-line line))
          (multiple-value-bind (code out err) (finish-wake wake 10)
            (is eql 0 code "stderr ~S" err)
            (is string= line out)))))))
