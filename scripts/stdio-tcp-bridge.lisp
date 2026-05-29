;;;; scripts/stdio-tcp-bridge.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Stdio↔TCP line bridge for MCP.
;;;;
;;;; Translates between a stdio-speaking MCP client (e.g. the Codex MCP
;;;; runtime) and a dsmr-mcp TCP server.  The client machine needs no Python
;;;; interpreter and no SBCL installation — the binary produced by
;;;; (asdf:make :dsmr-mcp-bridge) embeds the SBCL runtime and all deps.
;;;;
;;;; Wire shape (matching the Python reference in cl-mcp):
;;;;   stdin  → TCP server  (newline-delimited JSON-RPC requests)
;;;;   TCP server → stdout  (newline-delimited JSON-RPC responses)
;;;;   TCP server log lines → stderr (filtered by %log-line-p)
;;;;
;;;; Exit codes:
;;;;   0  — clean shutdown (stdin EOF after the bridge was connected)
;;;;   2  — TCP connection refused (never-connected path)
;;;;   3  — TCP connection timeout (never-connected path)
;;;;  64  — invalid CLI arguments (sysexits.h EX_USAGE; e.g. --port abc)
;;;;
;;;; Per D-07: standalone source, depends only on usocket + bordeaux-threads
;;;; + sb-ext.  No dsmr-mcp/src/... package imports allowed here.

(defpackage #:dsmr-mcp-bridge/scripts/stdio-tcp-bridge
  (:use #:cl)
  (:import-from #:usocket
                #:socket-connect
                #:socket-stream
                #:socket-close
                #:connection-refused-error
                #:socket-error)
  (:import-from #:bordeaux-threads
                #:make-thread
                #:join-thread
                #:thread-alive-p
                #:make-lock
                #:with-lock-held
                #:make-condition-variable
                #:condition-wait
                #:condition-notify)
  (:import-from #:sb-ext
                #:with-timeout
                #:timeout)
  (:export #:main))

(in-package #:dsmr-mcp-bridge/scripts/stdio-tcp-bridge)

;;; ---------------------------------------------------------------------------
;;; Log-line heuristic
;;; ---------------------------------------------------------------------------

;; D-09 substring check (not prefix) — jzon key order is non-deterministic; see RESEARCH.md Pitfall 5.
(defun %log-line-p (line)
  "Return T when LINE looks like a log4cl JSON layout output line.
Uses substring search for \"ts\": or \"level\": rather than a prefix check
because jzon serialises hash-table keys in implementation-defined order —
the \"ts\" key may not appear first in every log line."
  (and (stringp line)
       (or (search "\"ts\":" line)
           (search "\"level\":" line))
       t))

;;; ---------------------------------------------------------------------------
;;; Stop-event: a (lock . (condition-var . done-flag)) triple
;;; ---------------------------------------------------------------------------

(defun %make-stop-event ()
  "Return a stop-event triple (lock condition-var done-flag-cell).
The done-flag-cell is a cons whose car is the boolean; mutating it under
the lock and notifying the cv is the completion signal."
  (list (make-lock "bridge-stop-lock")
        (make-condition-variable :name "bridge-stop-cv")
        nil))

(defun %stop-event-lock (ev)  (first ev))
(defun %stop-event-cv   (ev)  (second ev))
(defun %stop-event-done (ev)  (third ev))

(defun %signal-stop (ev)
  "Signal stop-event EV under its lock."
  (with-lock-held ((%stop-event-lock ev))
    (setf (third ev) t)
    (condition-notify (%stop-event-cv ev))))

(defun %wait-for-stop (ev)
  "Block until stop-event EV is signalled."
  (with-lock-held ((%stop-event-lock ev))
    (loop until (%stop-event-done ev)
          do (condition-wait (%stop-event-cv ev)
                             (%stop-event-lock ev)))))

;;; ---------------------------------------------------------------------------
;;; Pump threads
;;; ---------------------------------------------------------------------------

(defun pump-stdin-to-tcp (tcp-stream stop-event)
  "Forward lines from *standard-input* to TCP-STREAM.
Returns on stdin EOF (the connected-then-stdin-EOF path — exit 0 follows).
Signals stop-event on return so the main thread can proceed to shutdown."
  (handler-case
      (loop
        (let ((line (read-line *standard-input* nil nil)))
          (unless line (return))
          (write-line line tcp-stream)
          (force-output tcp-stream)))
    (error (e)
      (format *error-output* "[bridge] stdin->tcp error: ~A~%" e)
      (force-output *error-output*)))
  (%signal-stop stop-event))

(defun pump-tcp-to-stdout (tcp-stream stop-event)
  "Forward lines from TCP-STREAM to *standard-output*.
Lines that look like log4cl JSON output (contain \"ts\": or \"level\":
substrings) are redirected to *error-output* so the JSON-RPC channel on
stdout stays uncorrupted.
Returns on TCP read EOF (server-side close)."
  (handler-case
      (loop
        (let ((line (read-line tcp-stream nil nil)))
          (unless line (return))
          (if (%log-line-p line)
              (progn (write-line line *error-output*)
                     (force-output *error-output*))
              (progn (write-line line *standard-output*)
                     (force-output *standard-output*)))))
    (error (e)
      (format *error-output* "[bridge] tcp->stdout error: ~A~%" e)
      (force-output *error-output*)))
  (%signal-stop stop-event))

;;; ---------------------------------------------------------------------------
;;; Argument parsing
;;; ---------------------------------------------------------------------------

(defun %parse-args (argv)
  "Parse ARGV (a list of strings) and return five values:
  HOST PORT CONNECT-TIMEOUT HELP-REQUESTED-P ERROR-P.
Recognised flags: --host, --port, --connect-timeout, --help, -h, --version.
Missing values fall back to env vars DSMR_MCP_HOST / DSMR_MCP_PORT, then
hard-coded defaults (127.0.0.1 / 3000 / 5.0d0)."
  (let ((host nil)
        (port-str nil)
        (timeout-str nil)
        (help-p nil)
        (error-p nil))
    (loop for rest on argv by #'cddr
          for flag = (car rest)
          for value = (cadr rest)
          do (cond
               ((member flag '("--help" "-h" "--version") :test #'string=)
                (setf help-p t))
               ((string= flag "--host")
                (when value (setf host value)))
               ((string= flag "--port")
                (when value (setf port-str value)))
               ((string= flag "--connect-timeout")
                (when value (setf timeout-str value)))))
    ;; Apply env fallbacks.
    (unless host
      (setf host (or (uiop:getenv "DSMR_MCP_HOST") "127.0.0.1")))
    (let ((port
            (handler-case
                (parse-integer (or port-str
                                   (uiop:getenv "DSMR_MCP_PORT")
                                   "3000"))
              (error (e)
                (format *error-output*
                        "[bridge] invalid --port value: ~A~%" e)
                (force-output *error-output*)
                (setf error-p t)
                3000)))
          (timeout
            (if timeout-str
                (handler-case (read-from-string timeout-str)
                  (error () 5.0d0))
                5.0d0)))
      (values host port timeout help-p error-p))))

;;; ---------------------------------------------------------------------------
;;; Usage block
;;; ---------------------------------------------------------------------------

(defun %print-usage ()
  "Print a usage block to *error-output* describing the bridge's purpose
and accepted arguments."
  (format *error-output*
          "~&dsmr-mcp-bridge — proxy stdio MCP clients to a dsmr-mcp TCP server~%~
           ~%~
           Clients that only speak stdio (e.g. the Codex MCP runtime) connect~%~
           to this bridge instead of the TCP server directly.  The bridge~%~
           forwards their JSON-RPC requests over TCP and relays responses back~%~
           to stdout, keeping the JSON-RPC channel clean by routing log lines~%~
           to stderr.~%~
           ~%~
           Usage:~%~
             dsmr-mcp-bridge [--host HOST] [--port PORT]~%~
                             [--connect-timeout SECONDS]~%~
           ~%~
           Options:~%~
             --host HOST             TCP server hostname (default: 127.0.0.1)~%~
             --port PORT             TCP server port    (default: 3000)~%~
             --connect-timeout SECS  Connect phase timeout in seconds~%~
                                     (default: 5.0)~%~
             --help, -h              Show this message and exit 0~%~
             --version               Show version and exit 0~%~
           ~%~
           Environment variable fallbacks:~%~
             DSMR_MCP_HOST   — overrides default host when --host is absent~%~
             DSMR_MCP_PORT   — overrides default port when --port is absent~%~
           ~%")
  (force-output *error-output*))

;;; ---------------------------------------------------------------------------
;;; Bridge driver (three distinct exit paths — W-4)
;;; ---------------------------------------------------------------------------

(defun run-bridge (host port connect-timeout)
  "Connect to HOST:PORT and run the stdin↔TCP pump loop.

Returns an integer exit code:
  0  — clean shutdown after stdin EOF (CONNECTED-then-stdin-EOF path)
  2  — connection refused (NEVER-CONNECTED path)
  3  — connection timeout (NEVER-CONNECTED path)

The three exit paths (0 / 2 / 3) are textually distinct code paths (W-4)."
  (let ((sock
          (handler-case
              (with-timeout connect-timeout
                (usocket:socket-connect host port :element-type 'character))
            ;; Exit 3: connect timed out — never-connected path.
            (sb-ext:timeout ()
              (format *error-output*
                      "[bridge] connect timeout after ~As~%" connect-timeout)
              (force-output *error-output*)
              (return-from run-bridge 3))
            ;; Exit 2: connection refused or unreachable — never-connected path.
            (usocket:connection-refused-error ()
              (format *error-output*
                      "[bridge] connect refused to ~A:~D~%" host port)
              (force-output *error-output*)
              (return-from run-bridge 2))
            (usocket:socket-error (e)
              (format *error-output*
                      "[bridge] connect refused to ~A:~D (~A)~%"
                      host port e)
              (force-output *error-output*)
              (return-from run-bridge 2)))))
    ;; Connected path — run pumps and wait for stdin EOF.
    (format *error-output* "[bridge] connected tcp://~A:~D~%" host port)
    (force-output *error-output*)
    (let* ((tcp-str (usocket:socket-stream sock))
           (stop-ev (%make-stop-event))
           (t-stdin (make-thread
                     (lambda () (pump-stdin-to-tcp tcp-str stop-ev))
                     :name "bridge-stdin-pump"))
           (t-tcp   (make-thread
                     (lambda () (pump-tcp-to-stdout tcp-str stop-ev))
                     :name "bridge-tcp-pump")))
      (unwind-protect
           (progn
             ;; Wait until one of the pumps signals stop.
             (%wait-for-stop stop-ev)
             ;; Give the other pump 1 second to drain before we close.
             (handler-case
                 (with-timeout 1
                   (when (thread-alive-p t-stdin)
                     (join-thread t-stdin))
                   (when (thread-alive-p t-tcp)
                     (join-thread t-tcp)))
               (sb-ext:timeout () nil)))
        ;; Cleanup regardless of how we got here.
        (ignore-errors (close tcp-str))
        (ignore-errors (usocket:socket-close sock))))
    ;; Exit 0: clean shutdown — connected-then-stdin-EOF path.
    0))

;;; ---------------------------------------------------------------------------
;;; Entry point
;;; ---------------------------------------------------------------------------

(defun main ()
  "Bridge entry point.  Parse argv, connect to TCP server, proxy stdin/stdout."
  (let ((args (uiop:command-line-arguments)))
    (multiple-value-bind (host port timeout help-p error-p)
        (%parse-args args)
      (when help-p
        (%print-usage)
        (uiop:quit 0))
      ;; Bad CLI usage exits 64 (sysexits.h EX_USAGE) so wrapper scripts
      ;; and supervisors can distinguish a malformed invocation from a
      ;; clean --help shutdown.  Without this distinction a supervisor
      ;; watching the exit code would either restart on a typo (because
      ;; 0 looked clean) or treat the bridge as healthy.
      (when error-p
        (%print-usage)
        (uiop:quit 64))
      (let ((rc (run-bridge host port timeout)))
        (format *error-output* "[bridge] exit ~D~%" rc)
        (force-output *error-output*)
        (uiop:quit rc)))))
