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
  (:import-from #:dsmr-mcp/src/slynk-port
                #:derive-slynk-port)
  (:import-from #:cl-ppcre
                #:regex-replace)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:make-ht)
  (:import-from #:dsmr-mcp/src/log
                #:log-event)
  (:export #:lisp-project-without-envrc-p
           #:lisp-project-envrc-needs-setup-p
           #:maybe-prompt-and-write-envrc
           #:envrc-elicitation-schema
           #:envrc-content-with-derived-port))

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

(defun lisp-project-envrc-needs-setup-p (project-root)
  "Return T when PROJECT-ROOT names a Lisp project (`*.asd` present) whose
`.envrc` EXISTS but is not yet up to date with the dsmr-mcp settings. The file
qualifies when it is missing `DSMR_SLYNK_ATTACH` (a fully pre-dsmr-mcp file) OR
missing `DSMR_BUS_AGENT` (a slynk-complete file that predates the coordination
bus). Keying the \"done\" state on `DSMR_BUS_AGENT` presence is sufficient
because the template and managed block always write both exports together, so a
file carrying the bus line necessarily has the slynk line too.

This is the update trigger gate: an `.envrc` created from the current template
already carries both markers, so it is never re-nagged, and a hand-written one
that already exports them is respected. Nil-safe: a NIL root yields NIL. The
`.envrc` is read under IGNORE-ERRORS so an unreadable file yields NIL rather
than an error."
  (and project-root
       (some #'identity (directory (merge-pathnames "*.asd" project-root)))
       (let ((envrc (merge-pathnames ".envrc" project-root)))
         (and (probe-file envrc)
              (let ((text (ignore-errors (uiop:read-file-string envrc))))
                (and text
                     (or (not (search "DSMR_SLYNK_ATTACH" text))
                         (not (search "DSMR_BUS_AGENT" text)))))))
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
;;; Project-basename default for the bus identity
;;; ---------------------------------------------------------------------------

(defun %project-basename (project-root)
  "Return the basename of PROJECT-ROOT's directory as a CHARACTER string -- the
last directory component of the pathname (e.g. #p\"/tmp/myproj/\" -> \"myproj\").
This is the default value for DSMR_BUS_AGENT: a project's stable main-agent bus
identity. When PROJECT-ROOT is nil, or no directory component can be derived,
fall back to the neutral literal \"agent\" so the managed block is always a
valid override-preserving export."
  (let ((dir (and project-root
                  (pathname-directory (uiop:ensure-directory-pathname project-root)))))
    (let ((last (and (consp dir) (car (last dir)))))
      (if (and (stringp last) (plusp (length last)))
          (%wire-string last)
          "agent"))))

;;; ---------------------------------------------------------------------------
;;; Managed append block (marker-delimited)
;;; ---------------------------------------------------------------------------

(defun envrc-managed-block (&optional project-root)
  "Return the dsmr-mcp managed `.envrc` block as an element-type CHARACTER
string. The block is wrapped in `# >>> dsmr-mcp ... >>>` / `# <<< dsmr-mcp <<<`
markers so it can be located, re-edited, or removed by hand, and carries the
same export lines (values and forms) as the body of
templates/dsmr-mcp.envrc.template -- without that file's header comment. It is
appended verbatim to an existing `.envrc` that lacks the dsmr-mcp setup; the
user's own lines are never touched. Built via FORMAT then coerced through
%wire-string so nothing on it is a simple-base-string.

When PROJECT-ROOT is supplied, the SLYNK_PORT default is derived from it via
FNV-1a into a stable per-project value in [4096, 32768), so concurrent projects
get distinct ports and do not converge on one shared Slynk image. When
PROJECT-ROOT is nil the legacy literal 4005 is used — valid for hand-editable
blocks and operator overrides."
  (let* ((derived (and project-root
                       (handler-case (derive-slynk-port project-root)
                         (error () nil))))
         (port    (if derived (princ-to-string derived) "4005"))
         (agent   (%project-basename project-root)))
    (%wire-string
     (format nil
"# >>> dsmr-mcp (added automatically; edit or remove freely) >>>
export LISP_WORKSPACE=\"${LISP_WORKSPACE:-$HOME/SourceCode/lisp/}\"
export SLYNK_HOST=\"${SLYNK_HOST:-127.0.0.1}\"
export SLYNK_PORT=\"${SLYNK_PORT:-~A}\"
export DSMR_MODE=auto
export DSMR_SLYNK_ATTACH=\"${SLYNK_HOST}:${SLYNK_PORT}\"
export DSMR_LOG_LEVEL=info
export DSMR_BUS_AGENT=\"${DSMR_BUS_AGENT:-~A}\"
# <<< dsmr-mcp <<<
"
             port agent))))

(defun envrc-bus-stanza (&optional project-root)
  "Return the marker-delimited dsmr-mcp BUS stanza as an element-type CHARACTER
string: only the DSMR_BUS_AGENT export, wrapped in its own
`# >>> dsmr-mcp (bus) ... >>>` / `# <<< dsmr-mcp (bus) <<<` markers. This is the
append shape for a `.envrc` that is already slynk-complete (exports
DSMR_SLYNK_ATTACH) but predates the coordination bus -- appending the full
managed block would duplicate the slynk exports, so only the missing bus
identity is added. The default value is the project-directory basename. Built
via FORMAT then coerced through %wire-string so nothing on it is a
simple-base-string."
  (let ((agent (%project-basename project-root)))
    (%wire-string
     (format nil
"# >>> dsmr-mcp (bus) (added automatically; edit or remove freely) >>>
export DSMR_BUS_AGENT=\"${DSMR_BUS_AGENT:-~A}\"
# <<< dsmr-mcp (bus) <<<
"
             agent))))

;;; ---------------------------------------------------------------------------
;;; Template port substitution
;;; ---------------------------------------------------------------------------

(defun %envrc-with-derived-port (template project-root)
  "Return TEMPLATE (a `.envrc` content string) with the SLYNK_PORT default
substituted to the per-project derived value when PROJECT-ROOT is known.

The substitution targets the shell expression `:-NNNN}` on the SLYNK_PORT line —
the same override-preserving shape the template already uses. When derivation
signals an error, or when no SLYNK_PORT line is found, TEMPLATE is returned
unchanged rather than writing a broken file."
  (when (or (null project-root)
            (not (stringp template))
            (zerop (length template)))
    (return-from %envrc-with-derived-port template))
  (let ((derived (handler-case (derive-slynk-port project-root) (error () nil))))
    (unless derived (return-from %envrc-with-derived-port template))
    ;; Rebuild the whole SLYNK_PORT="${SLYNK_PORT:-<port>}" line with the derived
    ;; default. The prefix/suffix are fixed literals, so a register-free literal
    ;; replacement is enough — and is the *only* safe form here: a `\1`-style
    ;; back-reference would sit immediately before the port digits, and cl-ppcre
    ;; reads `\16762` as register 16762, signals "non-existent register", and the
    ;; surrounding handler-case would silently return the template with the
    ;; default port unchanged.
    (let ((port-str (princ-to-string derived)))
      (handler-case
          (%wire-string
           (regex-replace
            "SLYNK_PORT=\"\\$\\{SLYNK_PORT:-[0-9]+\\}\""
            template
            (format nil "SLYNK_PORT=\"${SLYNK_PORT:-~A}\"" port-str)))
        (error () template)))))

(defun envrc-content-with-derived-port (content project-root)
  "Return CONTENT (a `.envrc` template string) with the SLYNK_PORT default
replaced by the per-project derived port for PROJECT-ROOT. Public seam used
by the project scaffold and the per-project write paths."
  (%envrc-with-derived-port content project-root))

;;; ---------------------------------------------------------------------------
;;; Elicitation schema
;;; ---------------------------------------------------------------------------

(defun envrc-elicitation-schema ()
  "Return the requestedSchema hash-table for the `.envrc` consent prompt.

A confirmation-only elicitation: the accept/decline action already carries the
operator's consent, so the schema requests no input fields (an empty flat
object). MCP elicitation schemas are restricted to flat objects of primitive
properties; an empty `properties` renders as a plain Accept/Decline
confirmation with no field for the client to demand. (A required boolean here
made the client reject an accept until the box was ticked -- only decline could
clear the dialog.) Built with make-ht so nothing on the wire is a
simple-base-string or a reader literal."
  (make-ht "type" "object"
           "properties" (make-ht)))

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
  "No .envrc found. Create one for this project from the dsmr-mcp template? You'll then run 'direnv allow .' to load it."
  "The human-readable prompt shown to the operator for the .envrc CREATE consent.")

(defparameter +envrc-update-message+
  "Your .envrc is missing some dsmr-mcp settings. Bring it up to date? You'll need to run 'direnv allow' again."
  "The human-readable prompt shown when an existing .envrc is missing one or more
dsmr-mcp settings (either the full slynk setup, or just the bus identity on a
file that predates the coordination bus) and the operator is asked to APPEND the
missing settings. Worded to be accurate for both cases -- it does not claim the
entire dsmr-mcp setup is absent.")

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
       (let ((content (%envrc-with-derived-port (read-envrc-template) root)))
         (write-file-string-atomically target content))
       (log-event :info "envrc.write.created" "path" (namestring target))
       t))))

(defun %append-envrc-on-accept (session content)
  "Append the missing dsmr-mcp settings to an EXISTING `.envrc` under the session
root when the operator confirmed. Returns T when something was appended, NIL
otherwise. The write goes only through the session write jail
(ensure-write-path) and is skipped when the operator's submitted `confirm` is
explicitly false, when the file no longer exists (never created here -- the
create path owns that), or when the file already exports `DSMR_BUS_AGENT`
(re-checked here so a concurrent edit cannot double-append -- the bus marker is
the \"done\" state because the managed block always writes slynk + bus
together).

The append SHAPE adapts to what is already present:
  - file already exports `DSMR_SLYNK_ATTACH` but lacks `DSMR_BUS_AGENT` (a
    slynk-complete file that predates the bus): append ONLY the bus stanza, so
    the slynk exports are NOT duplicated.
  - file lacks slynk entirely (a fully pre-dsmr-mcp file): append the full
    managed block (which now includes the bus line).

The user's existing lines are preserved: the stanza is appended after a
blank-line separator (an extra newline is added when the file does not already
end in one, so lines never join). CONTENT is the accept response content."
  ;; Honour an explicit false confirm; a missing confirm defaults to write
  ;; (the accept action already expressed consent).
  (when (and (hash-table-p content)
             (nth-value 1 (gethash "confirm" content))
             (not (gethash "confirm" content)))
    (log-event :info "envrc.append.declined-in-content")
    (return-from %append-envrc-on-accept nil))
  (let* ((root   (session-project-root session))
         (target (ensure-write-path ".envrc" root)))
    (cond
      ((null target)
       (log-event :warn "envrc.append.outside-jail")
       nil)
      ((not (probe-file target))
       (log-event :info "envrc.append.missing-no-create"
                  "path" (namestring target))
       nil)
      (t
       (let ((existing (ignore-errors (uiop:read-file-string target))))
         (cond
           ((null existing)
            (log-event :warn "envrc.append.unreadable" "path" (namestring target))
            nil)
           ;; Idempotency re-check: a `.envrc` that already carries the bus
           ;; marker is fully up to date and left untouched (no double-append).
           ((search "DSMR_BUS_AGENT" existing)
            (log-event :info "envrc.append.already-present"
                       "path" (namestring target))
            nil)
           (t
            (let* ((ends-nl (and (plusp (length existing))
                                 (char= #\Newline
                                        (char existing (1- (length existing))))))
                   ;; A blank line precedes the stanza. When the file already
                   ;; ends in a newline a single newline yields that blank line;
                   ;; otherwise two are needed (one to end the last line, one
                   ;; blank) so the appended marker never joins a user line.
                   (sep (if ends-nl (format nil "~%") (format nil "~%~%")))
                   ;; Slynk already present => add only the bus stanza (no slynk
                   ;; duplication); otherwise append the full managed block.
                   (stanza (if (search "DSMR_SLYNK_ATTACH" existing)
                               (envrc-bus-stanza root)
                               (envrc-managed-block root)))
                   (full (%wire-string
                          (concatenate 'string existing sep stanza))))
              (write-file-string-atomically target full)
              (log-event :info "envrc.append.added" "path" (namestring target))
              t))))))))

(defun %prompt-and-act (session out in-reader message on-accept-fn)
  "Run one consent round-trip for MESSAGE and act on the verdict.

The consent action is obtained on ONE of two paths keyed on IN-READER:
  - IN-READER supplied (stdio, single-threaded): drive the round-trip in-line
    via %elicit-via-read-loop -- no condition-variable wait on the loop thread.
  - IN-READER nil (tests / non-stdio): send-elicitation-request, which blocks
    on a condition variable until another thread routes the response.

Both create and update share this front half (same flat `confirm` schema); they
differ only in MESSAGE and ON-ACCEPT-FN. The action is validated before acting
(V5): only the known keywords are honoured, and only :accept reaches ON-ACCEPT-FN
(called with SESSION and the response CONTENT). Returns whatever ON-ACCEPT-FN
returns on :accept, NIL otherwise."
  (let ((schema (envrc-elicitation-schema)))
    (multiple-value-bind (action content)
        (if in-reader
            (%elicit-via-read-loop session out message schema
                                   in-reader :timeout +envrc-prompt-timeout+)
            (send-elicitation-request session out message schema
                                      :timeout +envrc-prompt-timeout+))
      (case action
        (:accept (funcall on-accept-fn session content))
        ((:decline :cancel :timeout)
         (log-event :info "envrc.prompt.outcome" "action" action)
         nil)
        (t
         (log-event :warn "envrc.prompt.unexpected-action" "action" action)
         nil)))))

(defun maybe-prompt-and-write-envrc (session out &optional in-reader)
  "Launch-time consent gate for bringing a project `.envrc` up to date.

A no-op (returns NIL, writes nothing, sets no flag) unless the client declared
elicitation and this session has not been prompted yet. When those hold, the
session's project root is matched against two mutually exclusive trigger states,
in order:
  - no `.envrc` at all (a qualifying Lisp project): prompt to CREATE one from
    the template; on :accept write through the write jail.
  - an `.envrc` that exists but lacks the dsmr-mcp setup: prompt to APPEND the
    managed block; on :accept append (the user's lines are preserved).
A complete `.envrc` (one that already exports DSMR_SLYNK_ATTACH) matches neither
state, so it is never re-prompted. When a branch fires, the once-per-session
guard is set FIRST (inside the branch) so even a decline / cancel / timeout
suppresses any later prompt this session; when neither state qualifies the guard
is left untouched so a later qualifying call can still prompt.

OUT is the JSON-RPC output stream; IN-READER selects the stdio vs non-stdio
consent path (see %prompt-and-act). Returns T when a `.envrc` was written or
appended, NIL otherwise."
  (when (and (session-elicitation-p session)
             (not (session-envrc-prompted-p session)))
    (let ((root (session-project-root session)))
      (cond
        ((lisp-project-without-envrc-p root)
         (setf (session-envrc-prompted-p session) t)
         (%prompt-and-act session out in-reader
                          +envrc-prompt-message+ #'%write-envrc-on-accept))
        ((lisp-project-envrc-needs-setup-p root)
         (setf (session-envrc-prompted-p session) t)
         (%prompt-and-act session out in-reader
                          +envrc-update-message+ #'%append-envrc-on-accept))))))
