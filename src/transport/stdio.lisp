;;;; src/transport/stdio.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Stdio transport: reads newline-delimited JSON-RPC from an input stream,
;;;; writes one response line per request to the output stream with
;;;; force-output, and returns T at EOF.
;;;;
;;;; Key design decisions:
;;;;   serve-streams is the thin entry point; string-stream injection drives it
;;;;   as the default end-to-end test fixture.
;;;;   %dispatch-with-stdout-guard captures any stray *standard-output* writes
;;;;         so tool code can never corrupt the JSON-RPC channel.
;;;;   %read-line-limited caps accumulated bytes at +max-json-line-bytes+
;;;;         (8 MB) and signals line-too-long; oversized lines return a
;;;;         literal -32600 "Request too large" envelope.
;;;;
;;;; Divergences from cl-mcp (read-only MIT reference):
;;;;   - No worker-pool calls (initialize-pool / shutdown-pool).
;;;;   - No attach-disconnect-all.
;;;;   - Moved out of run.lisp into its own transport package.
;;;;
;;;; Launch-time .envrc consent (in-line round-trip model):
;;;;   Before dispatching the first qualifying tools/call line, serve-streams
;;;;   runs the consent intercept (maybe-prompt-and-write-envrc). stdio is
;;;;   single-threaded -- the loop thread that runs the intercept is the same
;;;;   thread that must read the client's elicitation response -- so the
;;;;   intercept cannot block on a condition wait another thread would have to
;;;;   satisfy. Instead it completes the round-trip IN-LINE: it writes the
;;;;   elicitation/create request, then reads and answers interleaved client
;;;;   lines itself (each fed through process-json-line, which routes the
;;;;   response and replies to any non-response request, so no client request
;;;;   is dropped) until the response resolves or the timeout elapses. The held
;;;;   original tools/call line is dispatched normally afterward. The intercept
;;;;   is wired via runtime symbol resolution so this file carries no
;;;;   compile-time dependency on the envrc-init system (same technique as the
;;;;   detach-session teardown call).

(defpackage #:dsmr-mcp/src/transport/stdio
  (:use #:cl)
  (:local-nicknames (#:jzon #:com.inuoe.jzon))
  (:import-from #:bordeaux-threads
                #:make-lock
                #:with-lock-held)
  (:import-from #:dsmr-mcp/src/state
                #:make-session
                #:session-id
                #:session-project-root-just-set-p
                #:*current-session-id*
                #:*mode*)
  (:import-from #:dsmr-mcp/src/protocol
                #:process-json-line
                #:+max-json-depth+
                #:+max-json-string-length+)
  (:import-from #:dsmr-mcp/src/dispatch
                #:%backend-call-p)
  (:import-from #:dsmr-mcp/src/transport/dispatch-pool
                #:dispatch-pool-submit
                #:dispatch-pool-shutdown
                #:ensure-dispatch-pool
                #:await-promise
                #:dispatch-promise-lock
                #:dispatch-promise-cancelled
                #:dispatch-promise-mode
                #:dispatch-promise-thread
                #:dispatch-promise-session-id)
  (:import-from #:dsmr-mcp/src/hermetic/pool
                #:kill-session-worker)
  (:import-from #:dsmr-mcp/src/attach/cancel
                #:cancel-attached-eval
                #:*cancel-grace-seconds*)
  (:import-from #:dsmr-mcp/src/orphan
                #:orphan-count)
  (:import-from #:dsmr-mcp/src/notify
                #:%build-notification-json)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:make-ht)
  (:import-from #:dsmr-mcp/src/log
                #:log-event)
  (:import-from #:sb-ext)
  (:export #:serve-streams
           #:isolate-stdio-wire
           #:+max-json-line-bytes+
           #:line-too-long
           #:%read-line-limited
           #:%dispatch-with-stdout-guard
           #:%write-wire-line))

(in-package #:dsmr-mcp/src/transport/stdio)

;;; ---------------------------------------------------------------------------
;;; Constants
;;; ---------------------------------------------------------------------------

(defparameter +max-json-line-bytes+ (* 8 1024 1024)
  "Maximum byte count for a single JSON-RPC input line (8 MB).
Lines that exceed this cap are rejected with a -32600 error envelope;
the loop continues so subsequent well-formed lines are still served.
Defends against oversized-input resource exhaustion.

NOTE: counts characters, not bytes, as an approximation for ASCII-heavy
JSON payloads.  babel:string-size-in-octets or a manual UTF-8 width
accumulator can be substituted if the approximation proves inadequate.")

;;; ---------------------------------------------------------------------------
;;; Conditions
;;; ---------------------------------------------------------------------------

(define-condition line-too-long (error)
  ((bytes :initarg :bytes :reader line-too-long-bytes
          :documentation "Accumulated character count when the limit was hit."))
  (:report (lambda (c s)
             (format s "JSON-RPC line exceeds ~D character limit"
                     (line-too-long-bytes c))))
  (:documentation "Signaled by %READ-LINE-LIMITED when the accumulated character
count of a single JSON-RPC line exceeds +MAX-JSON-LINE-BYTES+.
Allows serve-streams to distinguish size violations from other I/O errors
and respond with a -32600 envelope rather than crashing the server."))

;;; ---------------------------------------------------------------------------
;;; Helpers
;;; ---------------------------------------------------------------------------

(defun %read-line-limited (stream eof-value max-bytes)
  "Read a line from STREAM up to MAX-BYTES characters.
Returns the line as a string on success, or EOF-VALUE when the stream is
at EOF before any character is read.  Handles both LF and CRLF line
endings.  Signals LINE-TOO-LONG when the accumulated character count
exceeds MAX-BYTES."
  (let ((buf (make-array 256 :element-type 'character
                             :adjustable t :fill-pointer 0))
        (count 0))
    (loop
      (let ((ch (read-char stream nil nil)))
        (cond
          ((null ch)
           ;; EOF — return eof-value if nothing read yet, else partial line.
           (return (if (zerop count) eof-value buf)))
          ((char= ch #\Newline)
           (return buf))
          ((char= ch #\Return)
           ;; Skip CR in CRLF — next char will be LF.
           nil)
          (t
           (incf count)
           (when (> count max-bytes)
             (error 'line-too-long :bytes count))
           (vector-push-extend ch buf)))))))

(defun %dispatch-with-stdout-guard (line session)
  "Call PROCESS-JSON-LINE with *STANDARD-OUTPUT* rebound to a capture stream.
Any text that tool code (or any library it calls) writes via FORMAT T or
WRITE to *STANDARD-OUTPUT* is intercepted here and never reaches the
OUT stream that carries the JSON-RPC protocol.

Returns two values:
  RESPONSE — the JSON-RPC response string, or NIL for notifications.
  CAPTURED — a string holding any intercepted *standard-output* text
             (empty string when nothing was leaked).

The caller logs a STDIO.TRANSPORT.STDOUT-POLLUTION warning when CAPTURED
is non-empty."
  (let* ((capture (make-string-output-stream))
         (response (let ((*standard-output* capture))
                     (process-json-line line session))))
    (values response (get-output-stream-string capture))))

;;; ---------------------------------------------------------------------------
;;; Process-wide wire isolation
;;; ---------------------------------------------------------------------------
;;;
;;; %dispatch-with-stdout-guard above is thread-local: it protects the wire
;;; from tool code running on the serve loop thread, and nothing else.  Any
;;; OTHER thread in the image — a Slynk client event dispatcher, a worker
;;; pool thread, a library timer — sees the GLOBAL values of the standard
;;; streams, and on a stdio server those point at the JSON-RPC wire.  A
;;; single stray print from such a thread corrupts the protocol stream and
;;; the client tears the connection down.
;;;
;;; isolate-stdio-wire closes that hole at the process level: it captures
;;; the real stdio streams privately for the wire, then re-points the global
;;; standard streams so that
;;;   - all output specials drain to *error-output* (stderr), and
;;;   - all input specials read from an always-EOF stream — stdin IS the
;;;     request wire, so a stray (read-line) anywhere must never eat a
;;;     JSON-RPC request.
;;; After this, no thread can reach the wire except through the two captured
;;; stream objects, which only serve-streams holds.

(defparameter *isolated-stream-specials*
  '(*standard-input* *standard-output* *trace-output*
    *terminal-io* *debug-io* *query-io*)
  "The standard stream specials re-pointed by isolate-stdio-wire.
*error-output* is deliberately absent: stderr is the one channel that must
keep working as-is — it is where everything else is redirected to.")

(defun isolate-stdio-wire ()
  "Claim the current stdio streams for the JSON-RPC wire and wall off the
global standard streams from every thread in the process.

Captures *STANDARD-INPUT* / *STANDARD-OUTPUT* (the wire), then sets BOTH the
thread-local and the global value of each special in
*ISOLATED-STREAM-SPECIALS*:
  output specials -> a synonym stream of *ERROR-OUTPUT*
  input specials  -> an empty (always-EOF) concatenated stream
  *TERMINAL-IO*   -> a two-way stream of the two above
Threads created after this call inherit the global values, so no library
code on any thread can write to — or read from — the wire again.

Returns three values: WIRE-OUT, WIRE-IN, and a restore thunk that puts every
saved value back (used by tests and by the server's unwind path; for the
real server process the restore is moot — the process exits)."
  (let* ((wire-in    *standard-input*)
         (wire-out   *standard-output*)
         (to-stderr  (make-synonym-stream '*error-output*))
         (always-eof (make-concatenated-stream))
         (terminal   (make-two-way-stream always-eof to-stderr))
         (saved-globals (mapcar (lambda (sym)
                                  (cons sym (sb-ext:symbol-global-value sym)))
                                *isolated-stream-specials*))
         (saved-locals  (mapcar (lambda (sym)
                                  (cons sym (symbol-value sym)))
                                *isolated-stream-specials*)))
    (flet ((repoint (sym value)
             ;; Global value first (covers threads created from here on),
             ;; then the current binding (covers this thread, which may be
             ;; running under a dynamic rebinding, e.g. a test harness).
             (setf (sb-ext:symbol-global-value sym) value)
             (setf (symbol-value sym) value)))
      (repoint '*standard-input*  always-eof)
      (repoint '*standard-output* to-stderr)
      (repoint '*trace-output*    to-stderr)
      (repoint '*terminal-io*     terminal)
      (repoint '*debug-io*        (make-synonym-stream '*terminal-io*))
      (repoint '*query-io*        (make-synonym-stream '*terminal-io*))
      (values wire-out
              wire-in
              (lambda ()
                (dolist (entry saved-globals)
                  (setf (sb-ext:symbol-global-value (car entry)) (cdr entry)))
                (dolist (entry saved-locals)
                  (setf (symbol-value (car entry)) (cdr entry))))))))

;;; ---------------------------------------------------------------------------
;;; Serialized wire writes
;;; ---------------------------------------------------------------------------

(defun %write-wire-line (line out lock)
  "Write LINE + newline to OUT and FORCE-OUTPUT, holding LOCK.
The stdio loop is single-threaded today (stdio sessions carry a
null notify-channel and the elicitation round-trip runs in-line on the loop
thread), so the lock is the single-writer guarantee for any future
server-initiated message path, not a fix for a current race."
  (with-lock-held (lock)
    (write-line line out)
    (force-output out)))

;;; ---------------------------------------------------------------------------
;;; Entry point
;;; ---------------------------------------------------------------------------

;;; ---------------------------------------------------------------------------
;;; Lightweight request classification (offload-by-predicate)
;;; ---------------------------------------------------------------------------

(defun %classify-request-line (line)
  "Lightly parse LINE to extract (values METHOD ID NAME) for offload routing.
METHOD is the JSON-RPC method string (or NIL), ID is the request id as parsed
\(string or number, or NIL for notifications), and NAME is the tools/call tool
name string (or NIL). Parses with the SAME jzon depth/string bounds as
process-json-line so a hostile line cannot allocate unboundedly here (T-19-13),
and is fully guarded: any parse failure or unexpected shape returns
\(values nil nil nil), so the caller falls through to the inline dispatch path,
which produces the proper -32700 / -32600 envelope. This is a cheap routing
probe, not the authoritative parse -- the chosen path re-parses via
process-json-line."
  (handler-case
      (let ((msg (jzon:parse line
                             :max-depth +max-json-depth+
                             :max-string-length +max-json-string-length+)))
        (if (hash-table-p msg)
            (let ((method (gethash "method" msg))
                  (id     (gethash "id" msg))
                  (params (gethash "params" msg)))
              (values (and (stringp method) method)
                      id
                      (and (hash-table-p params)
                           (let ((name (gethash "name" params)))
                             (and (stringp name) name)))))
            (values nil nil nil)))
    (error () (values nil nil nil))))

(defun %cancel-params (line)
  "Parse a notifications/cancelled LINE and return (values REQUEST-ID REASON).
REQUEST-ID is the params.requestId (a string or number) used ONLY as an
exact-match hash key into the in-flight map -- never interpolated into code
\(ASVS V5, T-19-02). REASON is the optional reason string or NIL. Parses with
the SAME jzon depth/string bounds as process-json-line so a hostile line cannot
allocate unboundedly here, and is fully guarded: any parse failure or
unexpected shape returns (values nil nil)."
  (handler-case
      (let ((msg (jzon:parse line
                             :max-depth +max-json-depth+
                             :max-string-length +max-json-string-length+)))
        (if (hash-table-p msg)
            (let ((params (gethash "params" msg)))
              (if (hash-table-p params)
                  (values (gethash "requestId" params)
                          (let ((r (gethash "reason" params)))
                            (and (stringp r) r)))
                  (values nil nil)))
            (values nil nil)))
    (error () (values nil nil))))

(defun %cancel-message (outcome)
  "Human-readable message for a cancel-result OUTCOME, so the agent's mental
model of the image state stays accurate (D-03)."
  (cond
    ((string= outcome "aborted_clean")
     "The in-flight call was cooperatively aborted; the image is clean.")
    ((string= outcome "orphaned")
     "The in-flight call did not abort within the grace window; its thread is tracked as an orphan and the image may still be running it.")
    ((string= outcome "killed")
     "The hermetic worker running the call was killed and respawned; the call was dropped and the session remains usable.")
    ((string= outcome "dropped_queued")
     "The call was cancelled before it started running; it produced no result.")
    (t "The call was cancelled.")))

(defun serve-streams (in out &key (session (make-session :id "stdio")))
  "Read newline-delimited JSON-RPC requests from IN and write response lines
to OUT.  Returns T when IN reaches EOF.

SESSION is the MCP session object; it defaults to a fresh session with
id \"stdio\".  *CURRENT-SESSION-ID* is let-bound to (SESSION-ID SESSION)
for the lifetime of the loop so every downstream call site can read it
without receiving it as a function argument.

Behaviour:
  - Each request line is classified (offload-by-predicate, D-07). A backend
    tools/call (a verb that touches the hermetic worker pool or an attached
    Slynk eval, per %backend-call-p) carrying an id is submitted to the
    dispatch pool and its response is written from the WORKER thread through
    %write-wire-line; the read loop continues immediately without awaiting,
    so ping and new requests stay responsive while a long backend call runs.
    Every other line (pure verbs, notifications, dispatcher-side tools, and
    anything that fails to classify) is dispatched INLINE on the read loop,
    exactly as before.
  - Inline dispatch runs PROCESS-JSON-LINE inside %DISPATCH-WITH-STDOUT-GUARD,
    which captures any stray *STANDARD-OUTPUT* writes so they cannot corrupt
    the JSON-RPC channel; the offloaded worker thunk uses the same guard. The
    worker thunk also re-binds *CURRENT-SESSION-ID* to (SESSION-ID SESSION),
    because dynamic bindings are thread-local: the pool worker does not inherit
    the read loop's binding, and handle-tools-call requires it bound.
  - Each response is followed by FORCE-OUTPUT so a piped reader sees it
    immediately.
  - A per-session in-flight map (request-id -> dispatch-promise) is populated
    at submit and cleaned at fulfill, under in-flight-lock. Submit + register
    are atomic with respect to the worker's removal, and the removal runs in an
    unwind-protect so a worker error still cleans the entry. This is the lookup
    table the cancel handler needs; lookup-in-flight / register-in-flight /
    remove-in-flight are local closures over the map so the cancel branch can
    reuse them inline on the read loop.
  - An oversized input line (> +MAX-JSON-LINE-BYTES+ chars) causes a literal
    -32600 \"Request too large\" envelope to be written; the loop then
    continues reading subsequent lines rather than aborting. The drain that
    follows a too-long read is itself bounded to +MAX-JSON-LINE-BYTES+: a
    newline-free hostile stream terminates the connection rather than pinning
    the loop.
  - A STREAM-ERROR on the write path (broken pipe, closed client) ends the
    loop cleanly without signaling further up.
  - STDIO.START fires on loop entry; STDIO.STOP fires in the unwind-protect
    cleanup so it logs even on abnormal exit.

Divergences from cl-mcp src/run.lisp:
  - No worker-pool calls.
  - detach-session closes the attached Slynk connection on teardown; called
    before the stdio.stop log via runtime symbol resolution so this file
    compiles before dsmr-mcp/src/attach/dispatch is loaded."
  (let ((*current-session-id* (session-id session))
        (write-lock (make-lock "dsmr-stdio-wire-write"))
        (in-flight (make-hash-table :test 'equal))
        (in-flight-lock (make-lock "dsmr-stdio-in-flight")))
    (labels ((lookup-in-flight (id)
               "Return the dispatch-promise registered under ID, or NIL.
Provided for the cancel handler (Plan 06), which runs inline on the read loop."
               (with-lock-held (in-flight-lock) (gethash id in-flight)))
             (remove-in-flight (id)
               "Drop ID from the in-flight map. Idempotent (a missing id is a
no-op), so it is safe in the worker's unwind-protect cleanup."
               (with-lock-held (in-flight-lock) (remhash id in-flight)))
             (register-in-flight (id thunk)
               "Submit THUNK to the dispatch pool under ID and record its promise
in the in-flight map. The in-flight-lock is held ACROSS submit + record so a
worker that starts running immediately cannot reach remove-in-flight before the
entry is recorded -- registration always happens-before removal. Returns the
promise."
               (with-lock-held (in-flight-lock)
                 (let ((promise (dispatch-pool-submit
                                 (ensure-dispatch-pool) thunk
                                 :session-id (session-id session)
                                 :request-id id
                                 :mode *mode*)))
                   (setf (gethash id in-flight) promise)
                   promise)))
             (emit-cancel-result (request-id outcome)
               "Write a server-initiated cancel-result notification to THIS
session's own wire via %write-wire-line (D-03). NOT emit: a stdio session
carries a null notify-channel where emit is a silent no-op (Pitfall 5). Carries
request_id, outcome, orphan_count, and a human-readable message."
               (let* ((params (make-ht "request_id"   request-id
                                       "outcome"       outcome
                                       "orphan_count"  (orphan-count)
                                       "message"       (%cancel-message outcome)))
                      (json (%build-notification-json
                             "notifications/dsmr-mcp/cancel-result" params)))
                 (handler-case
                     (%write-wire-line json out write-lock)
                   (stream-error (e)
                     (log-event :warn "stdio.write.error"
                                "error" (princ-to-string e))))
                 (log-event :info "stdio.cancel.result"
                            "request_id" (princ-to-string request-id)
                            "outcome" outcome)))
             (handle-cancelled-notification (line)
               "Handle a notifications/cancelled inline on the read loop (D-07).
Looks up the requestId in THIS session's in-flight map (T-19-02: a session can
cancel only its own calls; the key is an exact-match hash lookup, never
interpolated). An unknown or absent requestId is a logged no-op. A found promise
is marked cancelled, then cancelled per backend mode: a still-queued call is
dropped via the pool worker's lazy-skip (no queue scan); a running hermetic call
is hard-killed and respawned; a running attached call is cooperatively aborted.
Always emits a cancel-result and returns nil -- a notification gets no JSON-RPC
response and the session stays usable, never throwing on a bad id."
               (multiple-value-bind (request-id reason) (%cancel-params line)
                 (declare (ignore reason))
                 (if (not (or (stringp request-id) (numberp request-id)))
                     (progn (log-event :warn "stdio.cancel.bad-request-id") nil)
                     (let ((promise (lookup-in-flight request-id)))
                       (if (null promise)
                           (progn
                             (log-event :info "stdio.cancel.unknown"
                                        "request_id" (princ-to-string request-id))
                             nil)
                           (let (thread mode)
                             ;; Snapshot mode + running-thread atomically with the
                             ;; cancel mark so the worker either lazy-skips a still
                             ;; queued thunk or is seen already running -- never a
                             ;; torn read.
                             (with-lock-held ((dispatch-promise-lock promise))
                               (setf (dispatch-promise-cancelled promise) t)
                               (setf thread (dispatch-promise-thread promise)
                                     mode   (dispatch-promise-mode promise)))
                             (let ((outcome
                                     (cond
                                       ((null thread)
                                        ;; Queued: the pool worker lazy-skips a
                                        ;; cancelled thunk before running it, so it
                                        ;; never runs and emits no response (D-04).
                                        ;; The worker thunk's unwind cleanup never
                                        ;; runs for a skipped task, so drop the map
                                        ;; entry here.
                                        (remove-in-flight request-id)
                                        "dropped_queued")
                                       ((eq mode :hermetic)
                                        ;; Running hermetic: hard-kill + respawn
                                        ;; frees the disposable worker; the blocked
                                        ;; dispatch worker unblocks and cleans its
                                        ;; own in-flight entry (D-01).
                                        (kill-session-worker (session-id session))
                                        "killed")
                                       ((eq mode :attached)
                                        ;; Running attached: cooperative two-phase
                                        ;; abort (clean) or tracked orphan (no-take).
                                        (ecase (cancel-attached-eval promise)
                                          (:aborted-clean "aborted_clean")
                                          (:orphaned      "orphaned")))
                                       (t
                                        (log-event :warn "stdio.cancel.unknown-mode"
                                                   "mode" (princ-to-string mode))
                                        "dropped_queued"))))
                               (emit-cancel-result request-id outcome)
                               nil)))))))
             (drain-in-flight-on-eof ()
               "On EOF with in-flight calls, drain them within the grace window
instead of hanging (Critical Item 4 / T-19-16). With nothing in flight this is a
no-op and EOF returns immediately, unchanged. Otherwise mark every in-flight
promise cancelled, fire the per-mode cancel for the running ones (hermetic
hard-kill is non-blocking; attached drives the cooperative abort), await the
promises bounded by *cancel-grace-seconds*, then shut the dispatch pool down so
its workers join and the unwind path (detach-session + stdio.stop) runs."
               (let ((promises (with-lock-held (in-flight-lock)
                                 (loop for p being the hash-values of in-flight
                                       collect p))))
                 (when promises
                   (log-event :info "stdio.eof.drain" "in_flight" (length promises))
                   (dolist (p promises)
                     (let (thread mode)
                       (with-lock-held ((dispatch-promise-lock p))
                         (setf (dispatch-promise-cancelled p) t)
                         (setf thread (dispatch-promise-thread p)
                               mode   (dispatch-promise-mode p)))
                       (when thread
                         (ignore-errors
                          (case mode
                            (:hermetic (kill-session-worker
                                        (dispatch-promise-session-id p)))
                            (:attached (cancel-attached-eval p)))))))
                   (let ((deadline (+ (get-internal-real-time)
                                      (round (* *cancel-grace-seconds*
                                                internal-time-units-per-second)))))
                     (dolist (p promises)
                       (let ((remaining (/ (- deadline (get-internal-real-time))
                                           internal-time-units-per-second)))
                         (when (plusp remaining)
                           (ignore-errors (await-promise p :timeout remaining))))))
                   (ignore-errors
                    (dispatch-pool-shutdown (ensure-dispatch-pool)))))))
      (declare (ignorable #'lookup-in-flight #'remove-in-flight
                          #'register-in-flight
                          #'emit-cancel-result
                          #'handle-cancelled-notification
                          #'drain-in-flight-on-eof))
      (log-event :info "stdio.start" "session" (session-id session))
      (unwind-protect
           (loop
             ;; Read the next line, capped at +max-json-line-bytes+.
             (let ((line (handler-case
                             (%read-line-limited in :eof +max-json-line-bytes+)
                           (line-too-long (e)
                             (log-event :warn "stdio.read.line-too-long"
                                        "error" (princ-to-string e))
                             ;; Drain remaining bytes up to the newline, but cap
                             ;; the drain at +max-json-line-bytes+ too.  A hostile
                             ;; peer that never sends a newline must not pin us
                             ;; here indefinitely — terminate the connection if the
                             ;; drain budget is exceeded — terminate rather than pinning indefinitely.
                             (loop with drained = 0
                                   for ch = (read-char in nil nil)
                                   while ch
                                   until (char= ch #\Newline)
                                   do (when (> (incf drained) +max-json-line-bytes+)
                                        (log-event :warn "stdio.read.drain-exceeded")
                                        (return-from serve-streams t)))
                             :too-long))))
               (cond
                 ;; EOF — client closed the pipe. Drain any in-flight calls
                 ;; within the grace window (no-op when none), then return t.
                 ((eq line :eof)
                  (drain-in-flight-on-eof)
                  (return t))

                 ;; Oversized line — emit the literal error envelope and continue.
                 ((eq line :too-long)
                  (handler-case
                      (%write-wire-line
                       "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32600,\"message\":\"Request too large\"}}"
                       out write-lock)
                    (stream-error (e)
                      (log-event :warn "stdio.write.error"
                                 "error" (princ-to-string e))
                      (return t))))

                 ;; Normal line — classify, then either offload a backend call to
                 ;; the dispatch pool or dispatch inline.
                 (t
                  ;; Launch-time .envrc consent: on the first qualifying
                  ;; tools/call line, complete the elicitation round-trip in-line
                  ;; (reading and answering interleaved client lines through the
                  ;; in-reader thunk) BEFORE dispatching the held tool-call line.
                  ;; The cheap (search "tools/call" ...) gate may produce false
                  ;; positives; the intercept body re-checks capability /
                  ;; once-per-session / qualifying-project, so a false positive is
                  ;; harmless. Runtime symbol resolution avoids a compile-time dep
                  ;; on dsmr-mcp/src/envrc-init.
                  (when (search "tools/call" line)
                    (ignore-errors
                     (uiop:symbol-call :dsmr-mcp/src/envrc-init
                                       :maybe-prompt-and-write-envrc
                                       session out
                                       (lambda ()
                                         (%read-line-limited
                                          in :eof +max-json-line-bytes+)))))
                  (multiple-value-bind (method id name)
                      (%classify-request-line line)
                    (cond
                      ;; notifications/cancelled (a method, no id): handle inline
                      ;; on the read loop (D-07) -- look up this session's
                      ;; in-flight map and cancel per backend mode. Never
                      ;; offloaded; never throws on an unknown/absent requestId.
                      ((and (null id) (stringp method)
                            (string= method "notifications/cancelled"))
                       (handle-cancelled-notification line))
                      ((and id (%backend-call-p method name *mode*))
                        ;; Backend tools/call with an id: run it OFF the read
                        ;; thread on a dispatch-pool worker. The worker re-parses
                        ;; and dispatches via process-json-line (same stdout
                        ;; guard), writes its response through %write-wire-line
                        ;; under write-lock, and removes its in-flight entry in an
                        ;; unwind-protect so a worker error still cleans the map.
                        ;; The read loop does NOT await — it returns to the next
                        ;; read immediately. out / write-lock / session / line are
                        ;; captured by closure; *current-session-id* is re-bound on
                        ;; the worker thread (bindings are thread-local).
                        (register-in-flight
                         id
                         (lambda ()
                           (let ((*current-session-id* (session-id session)))
                             (unwind-protect
                                  (multiple-value-bind (resp captured)
                                      (%dispatch-with-stdout-guard line session)
                                    (when (plusp (length captured))
                                      (log-event :warn "stdio.transport.stdout-pollution"
                                                 "bytes" (length captured)
                                                 "preview" (subseq captured 0
                                                                    (min 200 (length captured)))))
                                    (when resp
                                      (handler-case
                                          (%write-wire-line resp out write-lock)
                                        (stream-error (e)
                                          (log-event :warn "stdio.write.error"
                                                     "error" (princ-to-string e))))))
                               (remove-in-flight id))))))
                      ;; Inline path (pure verbs, notifications this loop does not
                      ;; special-case, dispatcher-side tools, and anything that
                      ;; did not classify): dispatch on the read loop as before.
                      (t
                       (multiple-value-bind (resp captured)
                           (%dispatch-with-stdout-guard line session)
                         (when (plusp (length captured))
                           (log-event :warn "stdio.transport.stdout-pollution"
                                      "bytes" (length captured)
                                      "preview" (subseq captured 0
                                                         (min 200 (length captured)))))
                         (when resp
                           (handler-case
                               (%write-wire-line resp out write-lock)
                             (stream-error (e)
                               (log-event :warn "stdio.write.error"
                                          "error" (princ-to-string e))
                               (return t))))
                         ;; Post-dispatch .envrc consent: when the line just
                         ;; dispatched was the fs-set-project-root call that newly
                         ;; adopted this session's root, the pre-dispatch intercept
                         ;; above could not have offered the `.envrc` -- the root is
                         ;; set mid-dispatch, so it was still NIL when that intercept
                         ;; ran.  Consume the one-shot flag here, AFTER the response
                         ;; is on the wire, and drive the elicitation in-line on this
                         ;; loop thread (the only place it is safe to read/write the
                         ;; wire on stdio).  Clear the flag unconditionally first so a
                         ;; non-qualifying root or a declined prompt does not leave it
                         ;; armed for the next call.  The once-per-session prompted-p
                         ;; guard inside maybe-prompt-and-write-envrc keeps this from
                         ;; double-firing with the pre-dispatch path.  Runtime symbol
                         ;; resolution and ignore-errors mirror the pre-dispatch
                         ;; intercept.
                         (when (session-project-root-just-set-p session)
                           (setf (session-project-root-just-set-p session) nil)
                           (ignore-errors
                            (uiop:symbol-call :dsmr-mcp/src/envrc-init
                                              :maybe-prompt-and-write-envrc
                                              session out
                                              (lambda ()
                                                (%read-line-limited
                                                 in :eof +max-json-line-bytes+)))))))))))))
        ;; Cleanup: close the attached Slynk connection before logging stop so
        ;; the host Slynk listener gets a clean FIN on EOF or abnormal exit.
        ;; Runtime symbol resolution avoids a compile-time dep on
        ;; dsmr-mcp/src/attach/dispatch (same technique as the version lookup
        ;; in protocol.lisp %handle-initialize). ignore-errors guards against
        ;; the attach system being absent in a stripped build.
        (ignore-errors
         (uiop:symbol-call :dsmr-mcp/src/attach/dispatch :detach-session session))
        ;; Always log stdio.stop, even on abnormal exit.
        (log-event :info "stdio.stop" "session" (session-id session))))))
