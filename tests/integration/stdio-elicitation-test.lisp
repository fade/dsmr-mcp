;;;; tests/integration/stdio-elicitation-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Cross-process regression guard for the launch-time `.envrc` elicitation
;;;; round-trip over the REAL stdio transport.
;;;;
;;;; In-process fixtures (tests/elicitation/launch-trigger-test) drive the
;;;; non-stdio path: a router thread satisfies the condition-variable wait.
;;;; They structurally CANNOT cover the stdio path, because that path depends
;;;; on the single-threaded read loop itself reading the client's elicitation
;;;; response as the very next stdin line (%elicit-via-read-loop's in-reader),
;;;; interleaved with dispatching held tool-call lines.  Only a genuine server
;;;; subprocess speaking JSON-RPC over OS pipes exercises that loop.  This test
;;;; spawns exactly that and drives the four UAT scenarios end-to-end with a
;;;; pre-queued stdin sequence.
;;;;
;;;; The child is launched with the SAME clean invocation the installer now
;;;; generates (--no-userinit + explicit Quicklisp setup.lisp to stderr +
;;;; stderr-wrapped asdf load + run :stdio), so a regression in that command's
;;;; stdout hygiene also surfaces here: a bootstrap banner on stdout would make
;;;; the first response line fail to parse.
;;;;
;;;; Each scenario spawns a cold-ish child (~10-12s), so this leaf lives under
;;;; the SEPARATE dsmr-mcp/tests/integration system, NOT the fast
;;;; dsmr-mcp/tests umbrella.  It skips cleanly (parachute skip, not fail) when
;;;; the environment cannot spawn a server (no sbcl on PATH, no Quicklisp
;;;; setup.lisp), so a constrained CI is never red-flagged.

(defpackage #:dsmr-mcp/tests/integration/stdio-elicitation-test
  (:use #:cl #:parachute)
  (:local-nicknames (#:jzon #:com.inuoe.jzon))
  (:import-from #:dsmr-mcp/src/install/config
                #:canonical-server-entry)
  (:import-from #:dsmr-mcp/src/envrc-template
                #:read-envrc-template))

(in-package #:dsmr-mcp/tests/integration/stdio-elicitation-test)

;;; ---------------------------------------------------------------------------
;;; Environment probes / spawn
;;; ---------------------------------------------------------------------------

(defun %sbcl-path ()
  "Return the path string to the sbcl binary, or NIL when not on PATH."
  (or (ignore-errors
        (let ((result (string-trim
                       '(#\Newline #\Return #\Space)
                       (uiop:run-program '("which" "sbcl")
                                         :output :string
                                         :ignore-error-status t))))
          (and (plusp (length result)) result)))
      (find-if #'probe-file
               (list "/usr/local/bin/sbcl"
                     "/usr/bin/sbcl"
                     "/opt/local/bin/sbcl"))))

(defun %quicklisp-setup-present-p ()
  "True when Quicklisp's setup.lisp exists in the home directory.
The generated launcher resolves its dependencies through it, so without it
a spawned server cannot load dsmr-mcp."
  (and (probe-file (merge-pathnames "quicklisp/setup.lisp"
                                    (user-homedir-pathname)))
       t))

(defun %spawnable-p ()
  "True when this environment can spawn a real dsmr-mcp server subprocess."
  (and (%sbcl-path) (%quicklisp-setup-present-p)))

(defun %launch-args ()
  "Return the SBCL args list the installer would generate for dsmr-mcp.
Reused verbatim so this test guards the SAME launch command operators run."
  (coerce (gethash "args" (canonical-server-entry)) 'list))

(defun %spawn-server (&key project-root)
  "Spawn a child sbcl running dsmr-mcp :stdio with the generated launch args.
Returns a UIOP process-info with :stream input/output/error.  The caller
closes the input stream to trigger EOF and reaps the process.

When PROJECT-ROOT is supplied, DSMR_PROJECT_ROOT is set in the CHILD's
environment to that path so run seeds the stdio session's root at launch
(precedence: explicit :project-root > DSMR_PROJECT_ROOT > getcwd).  The child's
cwd is not relied upon -- it is harder to control across spawn backends, and the
env var is exactly the launch seam the operator's .envrc itself exports."
  (apply #'uiop:launch-program
         (cons (%sbcl-path) (%launch-args))
         :input        :stream
         :output       :stream
         :error-output :stream
         (when project-root
           (list :environment
                 (cons (format nil "DSMR_PROJECT_ROOT=~A" (namestring project-root))
                       (sb-ext:posix-environ))))))

;;; ---------------------------------------------------------------------------
;;; JSON-RPC line plumbing
;;; ---------------------------------------------------------------------------

(defun %obj (&rest kvs)
  "Build an equal-keyed hash-table from alternating KEY VALUE pairs."
  (let ((h (make-hash-table :test 'equal)))
    (loop for (k v) on kvs by #'cddr do (setf (gethash k h) v))
    h))

(defun %line (obj)
  "Stringify OBJ to a single JSON line."
  (jzon:stringify obj))

(defun %initialize-line (&key elicitation)
  "Return an initialize request line.  When ELICITATION is true the client
advertises the elicitation capability; otherwise it advertises none."
  (%line (%obj "jsonrpc" "2.0"
               "id" 0
               "method" "initialize"
               "params" (%obj "protocolVersion" "2025-06-18"
                              "capabilities" (if elicitation
                                                 (%obj "elicitation" (%obj))
                                                 (%obj))
                              "clientInfo" (%obj "name" "integration"
                                                 "version" "0")))))

(defun %initialized-line ()
  (%line (%obj "jsonrpc" "2.0" "method" "notifications/initialized")))

(defun %set-root-line (id path)
  "A fs-set-project-root tools/call with human_approved true (D-05: re-rooting
to a non-whitelisted dir is consent-gated)."
  (%line (%obj "jsonrpc" "2.0"
               "id" id
               "method" "tools/call"
               "params" (%obj "name" "fs-set-project-root"
                              "arguments" (%obj "path" path
                                                "human_approved" t)))))

(defun %trigger-line (id)
  "A tools/call line that trips the (search \"tools/call\" ...) intercept gate.
pool-status is used because its argument map is empty and it need not succeed
for the intercept to fire."
  (%line (%obj "jsonrpc" "2.0"
               "id" id
               "method" "tools/call"
               "params" (%obj "name" "pool-status"
                              "arguments" (%obj)))))

(defun %elicit-response-line (&key (action "accept"))
  "The client's elicitation response.  The first prompt id is 1 (the session
counter incf's from 0)."
  (%line (%obj "jsonrpc" "2.0"
               "id" 1
               "result" (%obj "action" action
                              "content" (%obj "confirm" t)))))

(defun %parse-json-line (line)
  "Parse LINE as JSON, returning the hash-table or NIL for a non-JSON line.
Non-JSON lines (a stray banner that slipped through) are ignored defensively."
  (and line (ignore-errors (jzon:parse line))))

(defun %elicitation-create-p (obj)
  "True when OBJ is a server->client elicitation/create request (method-bearing)."
  (and (hash-table-p obj)
       (equal "elicitation/create" (gethash "method" obj))))

(defun %drain-stdout (out &key (deadline-seconds 120))
  "Read every line available on OUT until EOF or DEADLINE-SECONDS elapse,
returning the parsed JSON objects (non-JSON lines dropped).  The caller closes
the child's stdin first so the child reaches EOF, exits, and closes its stdout
end, terminating this drain."
  (let ((objs '())
        (deadline (+ (get-internal-real-time)
                     (* deadline-seconds internal-time-units-per-second))))
    (loop
      (when (> (get-internal-real-time) deadline) (return))
      (let ((line (handler-case
                      (sb-ext:with-timeout deadline-seconds (read-line out nil :eof))
                    (sb-ext:timeout () :eof))))
        (when (eq line :eof) (return))
        (let ((obj (%parse-json-line line)))
          (when obj (push obj objs)))))
    (nreverse objs)))

(defun %count-elicitation-creates (objs)
  (count-if #'%elicitation-create-p objs))

(defun %result-with-id-p (obj id)
  "True when OBJ is a JSON-RPC response (result OR error) bearing ID.
Used by the handshake reader to detect that a specific request has been
answered -- proof the server processed everything up to and including it."
  (and (hash-table-p obj)
       (eql id (gethash "id" obj))
       (or (nth-value 1 (gethash "result" obj))
           (nth-value 1 (gethash "error" obj)))))

(defun %send-line (line in)
  "Write LINE to the child's stdin and flush it immediately, so the child's
single-threaded read loop sees it without waiting on buffer fill."
  (write-line line in)
  (finish-output in))

(defun %read-until (out predicate accumulator &key (deadline-seconds 120))
  "Read JSON-RPC lines from OUT, pushing each parsed object onto ACCUMULATOR (a
list, returned extended), until one SATISFIES PREDICATE or the deadline / EOF is
reached.  Each individual READ-LINE is itself bounded so a child that never
answers cannot pin the reader forever.  Returns two values: the (reverse-built)
accumulator with newly-read objects appended in arrival order, and the matching
object (or NIL when the deadline/EOF was hit first).

This is the core of the request/response handshake: rather than blasting all
input and guessing at timing, each step writes its line(s) then waits here for
the server's own acknowledgement (a specific result id, or an
elicitation/create) before proceeding.  Waiting on the server's reply -- not a
wall clock -- is what makes the driver deterministic across the child's
variable boot time."
  (let ((deadline (+ (get-internal-real-time)
                     (* deadline-seconds internal-time-units-per-second)))
        (match nil)
        (objs accumulator))
    (loop
      (when (> (get-internal-real-time) deadline) (return))
      (let* ((budget (max 1 (/ (- deadline (get-internal-real-time))
                               internal-time-units-per-second)))
             (line (handler-case
                       (sb-ext:with-timeout budget (read-line out nil :eof))
                     (sb-ext:timeout () :eof))))
        (when (eq line :eof) (return))
        (let ((obj (%parse-json-line line)))
          (when obj
            (push obj objs)
            (when (funcall predicate obj)
              (setf match obj)
              (return))))))
    (values objs match)))

;;; ---------------------------------------------------------------------------
;;; Scenario driver
;;; ---------------------------------------------------------------------------

(defmacro %with-temp-root ((root-var &key envrc-content) &body body)
  "Bind ROOT-VAR to a fresh temp directory holding a `.asd` file (so it is a
qualifying Lisp project).  When ENVRC-CONTENT is non-nil, seed a `.envrc` with
that content first.  Always tear the directory down."
  (let ((dir (gensym "DIR-")))
    `(let* ((,dir (uiop:ensure-directory-pathname
                   (format nil "/tmp/dsmr-stdio-elicit-~A-~A"
                           (get-universal-time) (random 1000000))))
            (,root-var ,dir))
       (unwind-protect
            (progn
              (ensure-directories-exist ,dir)
              (with-open-file (s (merge-pathnames "project.asd" ,dir)
                                 :direction :output :if-exists :supersede
                                 :if-does-not-exist :create)
                (write-string "(asdf:defsystem :stub)" s))
              ,@(when envrc-content
                  `((with-open-file (s (merge-pathnames ".envrc" ,dir)
                                       :direction :output :if-exists :supersede
                                       :if-does-not-exist :create)
                      (write-string ,envrc-content s))))
              ,@body)
         (ignore-errors
          (uiop:delete-directory-tree ,dir :validate t
                                           :if-does-not-exist :ignore))))))

(defun %run-scenario (root &key elicitation (response-action "accept")
                                (second-trigger t))
  "Spawn a real server, feed the pre-queued client sequence over stdin, drain
stdout, and return the parsed response objects.

The stdin sequence: initialize, notifications/initialized, fs-set-project-root,
trigger.  The launch root is seeded (via DSMR_PROJECT_ROOT in the child env) to
the non-qualifying `/tmp` directory -- /tmp holds no `*.asd`, so the intercept
no-ops on the first tools/call line (fs-set-project-root), preserving the
original pre-launch-seeding precondition.  That line's dispatch then re-roots
the session to ROOT (a qualifying temp dir).  The NEXT tools/call (the trigger)
is the first qualifying one, so it fires the prompt against ROOT.  When
ELICITATION and RESPONSE-ACTION are set, the elicitation response line is queued
immediately after the trigger so the in-line read loop consumes it.  When
SECOND-TRIGGER is true, a second trigger follows to prove the once-per-session
guard yields no further prompt.

Seeding the launch root at `/tmp` is necessary because run now seeds the
session's project root at launch (parity with the tcp/http transports): without
the override the launch root would be the harness cwd (the dsmr-mcp project
directory), which IS qualifying, and the intercept would fire on the
fs-set-project-root line itself -- writing a `.envrc` into the project tree.

stdin is closed after the last line so the child reaches EOF and exits."
  (let ((proc (%spawn-server :project-root #p"/tmp/"))
        (root-str (namestring root)))
    (unwind-protect
         (let ((in  (uiop:process-info-input proc))
               (out (uiop:process-info-output proc)))
           (write-line (%initialize-line :elicitation elicitation) in)
           (write-line (%initialized-line) in)
           (write-line (%set-root-line 2 root-str) in)
           (write-line (%trigger-line 3) in)
           (when (and elicitation response-action)
             (write-line (%elicit-response-line :action response-action) in))
           (when second-trigger
             (write-line (%trigger-line 4) in))
           (force-output in)
           ;; Close stdin -> child hits EOF on the loop -> exits cleanly.
           (close in)
           (prog1 (%drain-stdout out :deadline-seconds 120)
             (ignore-errors (uiop:wait-process proc))))
      (ignore-errors (close (uiop:process-info-input proc)))
      (ignore-errors (uiop:terminate-process proc))
      (ignore-errors (uiop:wait-process proc)))))

(defun %run-launch-seeded-scenario (root &key elicitation (response-action "accept"))
  "Spawn a real server with the launch root seeded via DSMR_PROJECT_ROOT in the
CHILD environment (NO fs-set-project-root sent), feed the client sequence over
stdin, drain stdout, and return the parsed response objects.

The stdin sequence is initialize, notifications/initialized, then a SINGLE
tools/call trigger.  Because the root is already seeded at launch, that first
qualifying tools/call is the one that fires the prompt -- proving the
seeded-at-launch behavior end-to-end with no prior re-root.  When ELICITATION
and RESPONSE-ACTION are set, the elicitation response line is queued right after
the trigger so the in-line read loop consumes it.

stdin is closed after the last line so the child reaches EOF and exits."
  (let ((proc (%spawn-server :project-root root)))
    (unwind-protect
         (let ((in  (uiop:process-info-input proc))
               (out (uiop:process-info-output proc)))
           (write-line (%initialize-line :elicitation elicitation) in)
           (write-line (%initialized-line) in)
           (write-line (%trigger-line 1) in)
           (when (and elicitation response-action)
             (write-line (%elicit-response-line :action response-action) in))
           (force-output in)
           (close in)
           (prog1 (%drain-stdout out :deadline-seconds 120)
             (ignore-errors (uiop:wait-process proc))))
      (ignore-errors (close (uiop:process-info-input proc)))
      (ignore-errors (uiop:terminate-process proc))
      (ignore-errors (uiop:wait-process proc)))))

;;; ---------------------------------------------------------------------------
;;; Scenarios (mirror 13-UAT.md, all assert hard)
;;; ---------------------------------------------------------------------------

(define-test stdio-elicitation-launch-seeded-root-prompts
  "Launch-time seeding: with the root seeded at launch via DSMR_PROJECT_ROOT and
NO fs-set-project-root sent, the FIRST qualifying tools/call fires exactly ONE
elicitation/create; on accept the .envrc is created byte-for-byte equal to the
template.  This proves run seeds the stdio session root at launch (the prompt
fires without any prior re-root)."
  (unless (%spawnable-p)
    (skip "cannot spawn a server subprocess (sbcl / quicklisp setup.lisp absent)"))
  (%with-temp-root (root)
    (let* ((objs (%run-launch-seeded-scenario root :elicitation t
                                                   :response-action "accept"))
           (prompts (remove-if-not #'%elicitation-create-p objs)))
      (is = 1 (length prompts)
          "exactly one elicitation/create on the first qualifying tools/call")
      (when (= 1 (length prompts))
        (is = 1 (gethash "id" (first prompts)) "first prompt id is 1"))
      (let ((envrc (merge-pathnames ".envrc" root)))
        (true (probe-file envrc) ".envrc written on accept")
        (when (probe-file envrc)
          (is string= (read-envrc-template) (uiop:read-file-string envrc)
              ".envrc is byte-for-byte the template"))))))

(define-test stdio-elicitation-accept-writes-envrc
  "Accept + once-per-session: exactly ONE elicitation/create (id 1) despite two
tool triggers; .envrc created byte-for-byte equal to the template; the second
trigger produces no further prompt."
  (unless (%spawnable-p)
    (skip "cannot spawn a server subprocess (sbcl / quicklisp setup.lisp absent)"))
  (%with-temp-root (root)
    (let* ((objs (%run-scenario root :elicitation t :response-action "accept"))
           (prompts (remove-if-not #'%elicitation-create-p objs)))
      (is = 1 (length prompts) "exactly one elicitation/create across two triggers")
      (when (= 1 (length prompts))
        (is = 1 (gethash "id" (first prompts)) "first prompt id is 1"))
      (let ((envrc (merge-pathnames ".envrc" root)))
        (true (probe-file envrc) ".envrc written on accept")
        (when (probe-file envrc)
          (is string= (read-envrc-template) (uiop:read-file-string envrc)
              ".envrc is byte-for-byte the template"))))))

(define-test stdio-elicitation-no-clobber
  "A pre-existing COMPLETE .envrc (one that already exports DSMR_SLYNK_ATTACH)
yields ZERO elicitation/create and is left unchanged: neither the create nor the
update trigger fires."
  (unless (%spawnable-p)
    (skip "cannot spawn a server subprocess (sbcl / quicklisp setup.lisp absent)"))
  (%with-temp-root (root :envrc-content "export DSMR_SLYNK_ATTACH=127.0.0.1:4005
")
    (let ((objs (%run-scenario root :elicitation t :response-action nil)))
      (is = 0 (%count-elicitation-creates objs)
          "no prompt when a complete .envrc already exists")
      (is string= "export DSMR_SLYNK_ATTACH=127.0.0.1:4005
"
          (uiop:read-file-string (merge-pathnames ".envrc" root))
          "pre-existing complete .envrc content unchanged"))))

(define-test stdio-elicitation-update-appends-block
  "An existing .envrc that lacks the dsmr-mcp setup fires exactly ONE
elicitation/create; on accept the dsmr-mcp managed block is APPENDED while the
user's original lines are preserved (append, not clobber)."
  (unless (%spawnable-p)
    (skip "cannot spawn a server subprocess (sbcl / quicklisp setup.lisp absent)"))
  (%with-temp-root (root :envrc-content "export FOO=bar
")
    (let* ((objs (%run-scenario root :elicitation t :response-action "accept"))
           (prompts (remove-if-not #'%elicitation-create-p objs)))
      (is = 1 (length prompts)
          "exactly one elicitation/create for the update prompt")
      (let ((text (uiop:read-file-string (merge-pathnames ".envrc" root))))
        (true (search "FOO=bar" text)
              "the user's original line is preserved")
        (true (search "DSMR_SLYNK_ATTACH" text)
              "the dsmr-mcp managed block was appended")))))

(define-test stdio-elicitation-decline-writes-nothing
  "Decline: exactly one elicitation/create; no .envrc written afterward."
  (unless (%spawnable-p)
    (skip "cannot spawn a server subprocess (sbcl / quicklisp setup.lisp absent)"))
  (%with-temp-root (root)
    (let ((objs (%run-scenario root :elicitation t :response-action "decline")))
      (is = 1 (%count-elicitation-creates objs)
          "exactly one elicitation/create on decline")
      (false (probe-file (merge-pathnames ".envrc" root))
             "no .envrc written on decline"))))

(define-test stdio-elicitation-no-capability
  "Without the elicitation capability: zero elicitation/create, no error, the
tool is still answered."
  (unless (%spawnable-p)
    (skip "cannot spawn a server subprocess (sbcl / quicklisp setup.lisp absent)"))
  (%with-temp-root (root)
    (let ((objs (%run-scenario root :elicitation nil :response-action nil)))
      (is = 0 (%count-elicitation-creates objs)
          "no prompt without the elicitation capability")
      (false (probe-file (merge-pathnames ".envrc" root))
             "no .envrc written without capability")
      ;; The trigger tools/call still received a JSON-RPC response (id 3 or 4),
      ;; proving the server stayed alive and answered.
      (true (some (lambda (o)
                    (and (hash-table-p o)
                         (member (gethash "id" o) '(3 4) :test #'eql)))
                  objs)
            "trigger tool call was answered"))))
