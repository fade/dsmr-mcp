;;;; src/envrc-init.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Launch-time, consent-gated `.envrc` bring-up. When dsmr-mcp serves a
;;;; session in a Lisp project (a `*.asd` is present) that has no `.envrc`, and
;;;; the client declared the MCP `elicitation` capability, the operator is
;;;; prompted -- at most once per session, before the first qualifying tool
;;;; call -- to create a `.envrc`. On accept the file is written through the
;;;; per-session write jail; on decline / cancel / timeout nothing is written.
;;;; An existing `.envrc` is never clobbered.
;;;;
;;;; Single function, two code paths keyed on an optional in-reader:
;;;;
;;;;   maybe-prompt-and-write-envrc (session out &optional in-reader)
;;;;
;;;; stdio is single-threaded: the loop thread that runs this intercept is the
;;;; same thread that must read the client's elicitation response. So when the
;;;; transport supplies an in-reader (a thunk that reads the next client line),
;;;; this code must NOT block on a condition-variable wait that another thread
;;;; would have to satisfy -- there is no other thread. Instead it registers a
;;;; pending cell, writes the elicitation/create request, then drives the read
;;;; loop itself: each line it reads is fed to process-json-line, which routes a
;;;; matching response into the pending cell and returns a reply string for any
;;;; non-response request -- those replies are written straight back so no
;;;; client request is dropped while we wait. This MIRRORS (does not call)
;;;; send-elicitation-request's register/write front half, keeping the whole
;;;; round-trip on the one stdio thread.
;;;;
;;;; When in-reader is nil (tests and any future multi-threaded transport) the
;;;; consent action comes from send-elicitation-request, which blocks on a
;;;; condition variable until another thread routes the response.
;;;;
;;;; Trust boundary: the elicitation response is untrusted; an accept authorizes
;;;; a filesystem write. The write goes only through ensure-write-path (the
;;;; session write jail) plus a re-check that the file still does not exist, so
;;;; a path that resolves outside the session root yields no write and an
;;;; existing `.envrc` is never overwritten.

(defpackage #:dsmr-mcp/src/envrc-init
  (:use #:cl)
  (:local-nicknames (#:jzon #:com.inuoe.jzon))
  (:import-from #:bordeaux-threads
                #:make-condition-variable
                #:with-lock-held)
  (:import-from #:dsmr-mcp/src/state
                #:session-elicitation-p
                #:session-envrc-prompted-p
                #:session-project-root
                #:session-elicitation-id-counter
                #:session-elicitation-lock
                #:session-pending-elicitation)
  (:import-from #:dsmr-mcp/src/elicitation
                #:send-elicitation-request)
  (:import-from #:dsmr-mcp/src/protocol
                #:process-json-line)
  (:import-from #:dsmr-mcp/src/project-root
                #:ensure-write-path)
  (:import-from #:dsmr-mcp/src/fs
                #:write-file-string-atomically)
  (:import-from #:dsmr-mcp/src/envrc-template
                #:read-envrc-template)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:make-ht)
  (:import-from #:dsmr-mcp/src/log
                #:log-event)
  (:export #:lisp-project-without-envrc-p
           #:maybe-prompt-and-write-envrc
           #:envrc-elicitation-schema))

(in-package #:dsmr-mcp/src/envrc-init)

;;; ---------------------------------------------------------------------------
;;; Qualifying-project predicate
;;; ---------------------------------------------------------------------------

(defun lisp-project-without-envrc-p (project-root)
  "Return T when PROJECT-ROOT names a directory that holds at least one `*.asd`
system definition and does NOT already contain a `.envrc`. Nil-safe: a NIL
root yields NIL. This is the launch-time trigger gate -- a `.envrc` that
already exists makes the predicate false, which is the no-clobber guard."
  (and project-root
       (some #'identity (directory (merge-pathnames "*.asd" project-root)))
       (not (probe-file (merge-pathnames ".envrc" project-root)))
       t))

;;; ---------------------------------------------------------------------------
;;; Wire-string coercion
;;; ---------------------------------------------------------------------------

(defun %wire-string (s)
  "Coerce S to a string of element-type CHARACTER.
Strings produced by FORMAT, UIOP, or literals can be simple-base-string on
SBCL; a base-string that reaches the JSON-RPC wire serializes as a
`#A(... BASE-CHAR ...)` reader literal that breaks framing. Coercing here keeps
the round-trip's wire payload safe."
  (map 'string #'identity s))

;;; ---------------------------------------------------------------------------
;;; Elicitation schema
;;; ---------------------------------------------------------------------------

(defun envrc-elicitation-schema ()
  "Return the flat requestedSchema hash-table for the `.envrc` consent prompt.

A single required boolean property `confirm`. MCP elicitation schemas are
restricted to flat objects of primitive properties, so there is no nesting.
Built with make-ht and a fresh vector so nothing on the wire is a
simple-base-string or a reader literal."
  (make-ht "type" "object"
           "properties"
           (make-ht "confirm"
                    (make-ht "type" "boolean"
                             "title" "Create .envrc"
                             "description"
                             (%wire-string
                              "Create a .envrc for this project from the dsmr-mcp template, then run 'direnv allow .' to load it.")))
           "required" (vector "confirm")))

;;; ---------------------------------------------------------------------------
;;; Consent action -> keyword (mirrors elicitation's mapping for the stdio path)
;;; ---------------------------------------------------------------------------

(defun %result-action-keyword (result)
  "Map a resolved elicitation RESULT hash-table to its action keyword.
\"accept\" -> :accept, \"decline\" -> :decline, anything else -> :cancel.
Mirrors send-elicitation-request's mapping so the stdio path (which inspects
the routed cell directly) reaches the same verdict as the non-stdio path."
  (let ((action (and (hash-table-p result) (gethash "action" result))))
    (cond ((and (stringp action) (string= action "accept"))  :accept)
          ((and (stringp action) (string= action "decline")) :decline)
          (t                                                  :cancel))))

;;; ---------------------------------------------------------------------------
;;; stdio path: in-line driven round-trip (no CV wait on the loop thread)
;;; ---------------------------------------------------------------------------

(defun %elicit-via-read-loop (session out message requested-schema in-reader
                              &key (timeout 30))
  "Run the elicitation round-trip in-line on the calling (stdio loop) thread.

Register a pending cell on the session, write the elicitation/create request to
OUT, then drive a bounded read loop via IN-READER. Each line read is fed to
process-json-line, which routes a matching response into the pending cell (via
route-elicitation-response) and returns a reply string for any non-response
request -- every non-nil reply is written back to OUT so no client request is
dropped while we wait. The loop ends when the pending cell resolves, the reader
yields :eof, or the wall-clock TIMEOUT elapses.

Returns (values ACTION CONTENT), action one of :accept :decline :cancel
:timeout; CONTENT is the response content hash-table on :accept, else NIL.

This MIRRORS the register/write front half of send-elicitation-request rather
than calling it, because send-elicitation-request blocks on a condition wait
that, on the single stdio thread, nothing else could ever satisfy."
  (let* ((id     (with-lock-held ((session-elicitation-lock session))
                   (incf (session-elicitation-id-counter session))))
         (cv     (make-condition-variable :name (format nil "elicit-~A" id)))
         ;; A private fresh-cons marker as the cell's initial result: resolution
         ;; is detectable with EQ once route-elicitation-response replaces it.
         (marker (list :unset))
         (cell   (list marker nil))
         (req    (make-ht "jsonrpc" "2.0"
                          "id"      id
                          "method"  "elicitation/create"
                          "params"  (make-ht "message"         (%wire-string message)
                                              "requestedSchema" requested-schema))))
    (with-lock-held ((session-elicitation-lock session))
      (setf (session-pending-elicitation session) (list id cv cell)))
    (unwind-protect
         (progn
           (write-line (%wire-string (jzon:stringify req)) out)
           (force-output out)
           (log-event :debug "envrc.elicit.sent" "id" id)
           (let* ((deadline (+ (get-internal-real-time)
                               (* timeout internal-time-units-per-second)))
                  (resolved-result
                    (loop
                      ;; Resolved? route-elicitation-response replaced the marker.
                      (let ((current (with-lock-held
                                         ((session-elicitation-lock session))
                                       (car cell))))
                        (unless (eq current marker)
                          (return current)))
                      (when (> (get-internal-real-time) deadline)
                        (return :timeout))
                      (let ((line (funcall in-reader)))
                        (when (eq line :eof)
                          (return :eof))
                        (let ((reply (ignore-errors
                                      (process-json-line line session))))
                          (when reply
                            (handler-case
                                (progn (write-line reply out) (force-output out))
                              (stream-error () (return :eof)))))))))
             (cond
               ((member resolved-result '(:timeout :eof))
                (log-event :debug "envrc.elicit.timeout" "id" id)
                (values :timeout nil))
               (t
                (let ((kw (%result-action-keyword resolved-result)))
                  (values kw
                          (and (eq kw :accept)
                               (hash-table-p resolved-result)
                               (gethash "content" resolved-result))))))))
      (with-lock-held ((session-elicitation-lock session))
        (setf (session-pending-elicitation session) nil)))))

;;; ---------------------------------------------------------------------------
;;; The intercept
;;; ---------------------------------------------------------------------------

(defparameter +envrc-prompt-message+
  "No .envrc found. Create one for this project?"
  "The human-readable prompt shown to the operator for the .envrc consent.")

(defparameter +envrc-prompt-timeout+ 30
  "Seconds to wait for the operator's elicitation response before giving up.")

(defun %write-envrc-on-accept (session content)
  "Write `.envrc` under the session root when the operator confirmed.
Returns T when a file was written, NIL otherwise. The write goes only through
the session write jail (ensure-write-path) and is skipped when the operator's
submitted `confirm` is explicitly false or when a `.envrc` already exists
(re-checked here -- no clobber). CONTENT is the accept response content."
  ;; Honour an explicit false confirm; a missing confirm defaults to write
  ;; (the accept action already expressed consent).
  (when (and (hash-table-p content)
             (nth-value 1 (gethash "confirm" content))
             (not (gethash "confirm" content)))
    (log-event :info "envrc.write.declined-in-content")
    (return-from %write-envrc-on-accept nil))
  (let* ((root   (session-project-root session))
         (target (ensure-write-path ".envrc" root)))
    (cond
      ((null target)
       (log-event :warn "envrc.write.outside-jail")
       nil)
      ((probe-file target)
       (log-event :info "envrc.write.exists-no-clobber"
                  "path" (namestring target))
       nil)
      (t
       (write-file-string-atomically target (read-envrc-template))
       (log-event :info "envrc.write.created" "path" (namestring target))
       t))))

(defun maybe-prompt-and-write-envrc (session out &optional in-reader)
  "Launch-time consent gate for creating a project `.envrc`.

A no-op (returns NIL, writes nothing, sets no flag) unless ALL hold: the client
declared elicitation, this session has not been prompted yet, and the session's
project root is a Lisp project (`*.asd` present) with no `.envrc`. When all
hold, set the once-per-session guard FIRST (so a decline / cancel / timeout
still suppresses any later prompt this session), obtain the operator's consent,
and on :accept write `.envrc` through the write jail.

The consent action is obtained on ONE of two paths keyed on IN-READER:
  - IN-READER supplied (stdio, single-threaded): drive the round-trip in-line
    via %elicit-via-read-loop -- no condition-variable wait on the loop thread.
  - IN-READER nil (tests / non-stdio): send-elicitation-request, which blocks
    on a condition variable until another thread routes the response.

OUT is the JSON-RPC output stream. Returns T when a `.envrc` was written, NIL
otherwise."
  (when (and (session-elicitation-p session)
             (not (session-envrc-prompted-p session))
             (lisp-project-without-envrc-p (session-project-root session)))
    ;; Once-per-session guard fires before the round-trip, so even a decline or
    ;; a timeout suppresses any later prompt this session.
    (setf (session-envrc-prompted-p session) t)
    (let ((schema (envrc-elicitation-schema)))
      (multiple-value-bind (action content)
          (if in-reader
              (%elicit-via-read-loop session out +envrc-prompt-message+ schema
                                     in-reader :timeout +envrc-prompt-timeout+)
              (send-elicitation-request session out +envrc-prompt-message+ schema
                                        :timeout +envrc-prompt-timeout+))
        ;; Validate the action before acting (V5): only the known keywords are
        ;; honoured, and only :accept can reach the write path.
        (case action
          (:accept (%write-envrc-on-accept session content))
          ((:decline :cancel :timeout)
           (log-event :info "envrc.prompt.outcome" "action" action)
           nil)
          (t
           (log-event :warn "envrc.prompt.unexpected-action" "action" action)
           nil))))))
