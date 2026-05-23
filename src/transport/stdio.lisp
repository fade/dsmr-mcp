;;;; src/transport/stdio.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Stdio transport: reads newline-delimited JSON-RPC from an input stream,
;;;; writes one response line per request to the output stream with
;;;; force-output, and returns T at EOF.
;;;;
;;;; Key design decisions (from 01-CONTEXT.md):
;;;;   D-10: serve-streams is the thin entry point string-stream injection
;;;;         drives as the default end-to-end fixture.
;;;;   %dispatch-with-stdout-guard captures any stray *standard-output* writes
;;;;         so tool code can never corrupt the JSON-RPC channel.
;;;;   %read-line-limited caps accumulated bytes at +max-json-line-bytes+
;;;;         (8 MB) and signals line-too-long; oversized lines return a
;;;;         literal -32600 "Request too large" envelope (T-03-01 mitigation).
;;;;
;;;; Divergences from cl-mcp (read-only MIT reference,
;;;;   $LISP_WORKSPACE/cl-mcp/src/run.lisp):
;;;;   - No worker-pool calls (initialize-pool / shutdown-pool) — Phase 4.
;;;;   - No attach-disconnect-all — Phase 2.
;;;;   - Moved out of run.lisp into its own transport package.

(defpackage #:dsmr-mcp/src/transport/stdio
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/state
                #:make-session
                #:session-id
                #:*current-session-id*)
  (:import-from #:dsmr-mcp/src/protocol
                #:process-json-line)
  (:import-from #:dsmr-mcp/src/log
                #:log-event)
  (:export #:serve-streams
           #:+max-json-line-bytes+
           #:line-too-long))

(in-package #:dsmr-mcp/src/transport/stdio)

;;; ---------------------------------------------------------------------------
;;; Constants
;;; ---------------------------------------------------------------------------

(defparameter +max-json-line-bytes+ (* 8 1024 1024)
  "Maximum byte count for a single JSON-RPC input line (8 MB).
Lines that exceed this cap are rejected with a -32600 error envelope;
the loop continues so subsequent well-formed lines are still served.
This is the Phase-1 mitigation for threat T-03-01 (oversized-input DoS).

NOTE: Phase 1 counts characters, not bytes, as an approximation for
ASCII-heavy JSON payloads.  A future phase can use babel:string-size-in-octets
or a manual UTF-8 width accumulator if the approximation proves inadequate.")

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
is non-empty (T-03-02 mitigation)."
  (let* ((capture (make-string-output-stream))
         (response (let ((*standard-output* capture))
                     (process-json-line line session))))
    (values response (get-output-stream-string capture))))

;;; ---------------------------------------------------------------------------
;;; Entry point
;;; ---------------------------------------------------------------------------

(defun serve-streams (in out &key (session (make-session :id "stdio")))
  "Read newline-delimited JSON-RPC requests from IN and write response lines
to OUT.  Returns T when IN reaches EOF.

SESSION is the MCP session object; it defaults to a fresh session with
id \"stdio\".  *CURRENT-SESSION-ID* is let-bound to (SESSION-ID SESSION)
for the lifetime of the loop so every downstream call site can read it
without receiving it as a function argument.

Behaviour:
  - Each request line is dispatched via PROCESS-JSON-LINE inside
    %DISPATCH-WITH-STDOUT-GUARD, which captures any stray *STANDARD-OUTPUT*
    writes so they cannot corrupt the JSON-RPC channel.
  - Each response is followed by FORCE-OUTPUT so a piped reader sees it
    immediately (D-10, T-03-03 partial mitigation for broken-pipe recovery).
  - An oversized input line (> +MAX-JSON-LINE-BYTES+ chars) causes a literal
    -32600 \"Request too large\" envelope to be written; the loop then
    continues reading subsequent lines rather than aborting (T-03-01).
  - A STREAM-ERROR on the write path (broken pipe, closed client) ends the
    loop cleanly without signaling further up.
  - STDIO.START fires on loop entry; STDIO.STOP fires in the unwind-protect
    cleanup so it logs even on abnormal exit.

Divergences from cl-mcp src/run.lisp:
  - No worker-pool calls (Phase 4).
  - No ATTACH-DISCONNECT-ALL (Phase 2)."
  (let ((*current-session-id* (session-id session)))
    (log-event :info "stdio.start" "session" (session-id session))
    (unwind-protect
         (loop
           ;; Read the next line, capped at +max-json-line-bytes+.
           (let ((line (handler-case
                           (%read-line-limited in :eof +max-json-line-bytes+)
                         (line-too-long (e)
                           (log-event :warn "stdio.read.line-too-long"
                                      "error" (princ-to-string e))
                           ;; Drain remaining bytes up to the newline so the
                           ;; next iteration starts at a fresh line boundary.
                           (loop for ch = (read-char in nil nil)
                                 while (and ch (not (char= ch #\Newline))))
                           :too-long))))
             (cond
               ;; EOF — client closed the pipe; return t to the caller.
               ((eq line :eof)
                (return t))

               ;; Oversized line — emit the literal error envelope and continue.
               ((eq line :too-long)
                (handler-case
                    (progn
                      (write-line
                       "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32600,\"message\":\"Request too large\"}}"
                       out)
                      (force-output out))
                  (stream-error (e)
                    (log-event :warn "stdio.write.error"
                               "error" (princ-to-string e))
                    (return t))))

               ;; Normal line — dispatch with stdout guard, then flush.
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
                        (progn
                          (write-line resp out)
                          (force-output out))
                      (stream-error (e)
                        (log-event :warn "stdio.write.error"
                                   "error" (princ-to-string e))
                        (return t)))))))))
      ;; Cleanup: always log stdio.stop, even on abnormal exit.
      (log-event :info "stdio.stop" "session" (session-id session)))))
