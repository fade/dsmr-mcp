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

(defun %spawn-server ()
  "Spawn a child sbcl running dsmr-mcp :stdio with the generated launch args.
Returns a UIOP process-info with :stream input/output/error.  The caller
closes the input stream to trigger EOF and reaps the process."
  (uiop:launch-program
   (cons (%sbcl-path) (%launch-args))
   :input        :stream
   :output       :stream
   :error-output :stream))

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

(defun %drain-stdout (out &key (deadline-seconds 30))
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
trigger.  The first tools/call line is fs-set-project-root, on which the
intercept is a no-op (root still NIL); that line's dispatch sets the root.  The
NEXT tools/call (the trigger) is the first qualifying one, so it fires the
prompt.  When ELICITATION and RESPONSE-ACTION are set, the elicitation response
line is queued immediately after the trigger so the in-line read loop consumes
it.  When SECOND-TRIGGER is true, a second trigger follows to prove the
once-per-session guard yields no further prompt.

stdin is closed after the last line so the child reaches EOF and exits."
  (let ((proc (%spawn-server))
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
           (prog1 (%drain-stdout out :deadline-seconds 30)
             (ignore-errors (uiop:wait-process proc))))
      (ignore-errors (close (uiop:process-info-input proc)))
      (ignore-errors (uiop:terminate-process proc))
      (ignore-errors (uiop:wait-process proc)))))

;;; ---------------------------------------------------------------------------
;;; Scenarios (mirror 13-UAT.md, all assert hard)
;;; ---------------------------------------------------------------------------

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
  "A pre-existing .envrc yields ZERO elicitation/create and is left unchanged."
  (unless (%spawnable-p)
    (skip "cannot spawn a server subprocess (sbcl / quicklisp setup.lisp absent)"))
  (%with-temp-root (root :envrc-content "SENTINEL")
    (let ((objs (%run-scenario root :elicitation t :response-action nil)))
      (is = 0 (%count-elicitation-creates objs)
          "no prompt when .envrc already exists")
      (is string= "SENTINEL"
          (uiop:read-file-string (merge-pathnames ".envrc" root))
          "pre-existing .envrc content unchanged"))))

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
