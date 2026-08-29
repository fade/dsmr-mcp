;;;; src/attach/probe.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Slynk port classification and project identity probing.
;;;;
;;;; slime-connect returns a live connection for any TCP listener, so a port
;;;; bound by a non-Slynk service or a foreign project's image looks identical
;;;; to our own Slynk until a bounded eval is sent and the reply inspected.
;;;;
;;;; classify-port performs that bounded eval and returns :free / :live-slynk /
;;;; :foreign.  resolve-slynk-target layers project-identity checks on top and
;;;; is the seam that run.lisp calls at startup to choose the effective attach
;;;; target — preferring the handshake file written by dev-boot.sh when one
;;;; exists.

(defpackage #:dsmr-mcp/src/attach/probe
  (:use #:cl)
  (:import-from #:slynk-client
                #:slime-connect
                #:slime-close)
  (:import-from #:dsmr-mcp/src/attach/connection
                #:bounded-slime-eval
                #:parse-slynk-attach)
  (:import-from #:dsmr-mcp/src/log
                #:log-event)
  (:import-from #:usocket)
  (:export #:classify-port
           #:probe-image-liveness
           #:slynk-handshake-path
           #:read-slynk-handshake
           #:resolve-slynk-target))

(in-package #:dsmr-mcp/src/attach/probe)

;;; ---------------------------------------------------------------------------
;;; Port classifier
;;; ---------------------------------------------------------------------------

(defun classify-port (host port &key (timeout 0.5))
  "Probe the TCP listener at HOST:PORT and return a classification keyword.

  :free        — connection refused; nothing is bound on this port.
  :live-slynk  — a Slynk image answered a sanity eval correctly.
  :foreign     — something answered TCP but timed out or returned the wrong
                 value (non-Slynk service, or a Slynk image from another
                 build that happens to bind the same port).

The probe sends `(+ 40 2)` with TIMEOUT seconds. A loopback Slynk
round-trip is normally under 10 ms, so 0.5 s is generous for genuine Slynk
and tight enough not to stall startup badly when a foreign port is occupied."
  (let ((conn (handler-case (slime-connect host port)
                (error () (return-from classify-port :free)))))
    (unless conn
      (return-from classify-port :free))
    (let ((result (handler-case
                      (bounded-slime-eval '(+ 40 2) conn :timeout timeout)
                    (error () nil))))
      (ignore-errors (slime-close conn))
      (if (eql result 42)
          :live-slynk
          :foreign))))

(defun %release-probe-connection (conn)
  "Release CONN, a throwaway probe connection, and let its reader thread die.

SLIME-CLOSE is a polite goodbye and nothing more: it sends and returns, and
the client's event-dispatcher thread stays parked on its read until the peer
answers.  An image that is not answering never does, so a close on its own
leaves a thread and a socket behind on every probe.  Measured against a
listener that accepts and never speaks: twenty probes, twenty threads, twenty
descriptors, none of them released afterwards.

Shutting the socket down delivers EOF to that parked read, so the dispatcher
unwinds through its connection-closed path and closes the descriptor as it
goes.  The two together give a peer that is answering a clean protocol
farewell and a peer that is not a bounded one.  Shutdown cannot block.

SLYNK-CLIENT does not export its socket reader; this is our fork, so the
internal reference is stable.  The same reasoning and the same call are in
the connection-drop path."
  (ignore-errors (slime-close conn))
  (ignore-errors (usocket:socket-shutdown (slynk-client::usocket conn) :io))
  nil)

(defun probe-image-liveness (host port &key (timeout 0.5))
  "Ask the image at HOST:PORT a real question and return what the answer proves.

Returns two values, the classification and the round trip in milliseconds:

  :healthy  the evaluation returned the expected value.
  :wedged   the connection was accepted and the evaluation did not return
            within TIMEOUT.  The image is alive and no longer answering, which
            a TCP connect on its own reports as healthy forever.
  :dead     the connection was refused or reset.  Nothing is answering the
            port at all, which is a different fact and a different repair.

The three are kept apart rather than collapsed into a single failure, because
a refused socket means the image has gone and a silent socket means it is
still there holding whatever state the developer built up in it.

TIMEOUT defaults to the value the port classifier already uses.  A loopback
round trip against an image that is answering is normally well under 70
milliseconds, so half a second separates a genuine silence from a slow reply
without stalling the caller.  It is a keyword argument so a caller that knows
its image is local can tighten it.

The probe opens its own connection with SLIME-CONNECT and closes it again.  It
never acquires the process-wide lock that serialises attached dispatch, never
acquires a session's own call lock, and never touches a session's cached
connection.  That is the whole point of opening a throwaway connection: a probe
that waits behind the lock real work is holding reports a busy image as a
wedged one, and a busy image is not a dead one.  Sharing the session's cached
connection would have the same effect for the same reason."
  (let ((start (get-internal-real-time)))
    (flet ((elapsed-ms ()
             (round (* 1000 (- (get-internal-real-time) start))
                    internal-time-units-per-second)))
      (let ((conn (handler-case (slime-connect host port)
                    (error () nil))))
        (unless conn
          (return-from probe-image-liveness (values :dead (elapsed-ms))))
        (unwind-protect
             (let ((answered (handler-case
                                 (eql 42 (bounded-slime-eval '(+ 40 2) conn
                                                             :timeout timeout))
                               (error () nil))))
               (values (if answered :healthy :wedged) (elapsed-ms)))
          (%release-probe-connection conn))))))

;;; ---------------------------------------------------------------------------
;;; Project identity probe
;;; ---------------------------------------------------------------------------

(defun %project-dir-name (project-root)
  "Return the last path component of PROJECT-ROOT as a lowercase string.
e.g. \"/home/fade/SourceCode/lisp/dsmr-mcp/\" → \"dsmr-mcp\".
Returns NIL when the path cannot be decoded."
  (when project-root
    (let ((dir (pathname-directory
                (uiop:ensure-directory-pathname project-root))))
      (when (and (listp dir) (cdr dir))
        (let ((last (car (last dir))))
          (when (stringp last)
            (string-downcase last)))))))

(defun %image-is-ours-p (conn project-root &key (timeout 2))
  "Return T when the Slynk image on CONN has PROJECT-ROOT's ASDF system loaded.
Derives the expected system name from the last component of PROJECT-ROOT
(lowercased, matching ASDF's default system-name convention).

Returns T on any probe failure — a transient error should not incorrectly
classify our own image as foreign and drop us into hermetic mode."
  (let ((sys-name (%project-dir-name project-root)))
    (unless sys-name
      ;; Cannot derive a name — assume the image is ours rather than blocking.
      (return-from %image-is-ours-p t))
    (handler-case
        (let ((systems (bounded-slime-eval
                        '(mapcar #'string-downcase (asdf:already-loaded-systems))
                        conn :timeout timeout)))
          (and (listp systems)
               (member sys-name systems :test #'string=)
               t))
      (error ()
        ;; Probe error: fail open.
        t))))

;;; ---------------------------------------------------------------------------
;;; Handshake file
;;; ---------------------------------------------------------------------------

(defun slynk-handshake-path (project-root)
  "Return the handshake file pathname for PROJECT-ROOT.
dev-boot.sh writes the actually-bound host:port here after create-server
returns; dsmr-mcp reads it at startup to locate the image even when a port
bump moved it away from the originally configured port."
  (merge-pathnames ".dsmr-slynk.port"
                   (uiop:ensure-directory-pathname project-root)))

(defun read-slynk-handshake (project-root)
  "Read the handshake file for PROJECT-ROOT. Returns a \"host:port\" string
when the file is present and syntactically valid, otherwise NIL."
  (when (or (null project-root)
            (and (stringp project-root) (zerop (length project-root))))
    (return-from read-slynk-handshake nil))
  (let ((p (handler-case (slynk-handshake-path project-root)
             (error () (return-from read-slynk-handshake nil)))))
    (unless (probe-file p)
      (return-from read-slynk-handshake nil))
    (handler-case
        (let ((raw (string-trim
                    (list #\space #\newline #\tab #\return #\linefeed)
                    (uiop:read-file-string p))))
          ;; Sanity: non-empty and contains a colon (host:port separator).
          (when (and (plusp (length raw)) (find #\: raw))
            raw))
      (error () nil))))

;;; ---------------------------------------------------------------------------
;;; Attach target resolution
;;; ---------------------------------------------------------------------------

(defun %probe-with-identity (slynk-attach project-root
                             &key (classify-timeout 0.5) (identity-timeout 2))
  "Return T when SLYNK-ATTACH names a live Slynk that belongs to PROJECT-ROOT.
Returns NIL when the string is absent, the port is :free or :foreign, or the
identity probe decides the image belongs to another project."
  (when (or (null slynk-attach) (zerop (length slynk-attach)))
    (return-from %probe-with-identity nil))
  (multiple-value-bind (host port)
      (handler-case (parse-slynk-attach slynk-attach)
        (error () (return-from %probe-with-identity nil)))
    (unless (and host port) (return-from %probe-with-identity nil))
    ;; First pass: classify the port.
    (unless (eq :live-slynk (classify-port host port :timeout classify-timeout))
      (return-from %probe-with-identity nil))
    ;; Second pass: open a fresh connection for the identity eval.
    (let ((id-conn (handler-case (slime-connect host port)
                     (error () (return-from %probe-with-identity nil)))))
      (unless id-conn (return-from %probe-with-identity nil))
      (let ((ours-p (%image-is-ours-p id-conn project-root :timeout identity-timeout)))
        (ignore-errors (slime-close id-conn))
        ours-p))))

(defun resolve-slynk-target (configured-attach project-root resolved-mode)
  "Return (values effective-attach effective-mode) for startup attach resolution.

RESOLVED-MODE controls fallback behaviour:

  :hermetic  — skip all probing; return (values nil :hermetic).

  :auto      — probe the handshake file written by dev-boot.sh, then
               CONFIGURED-ATTACH; fall back to :hermetic with a warning
               when neither passes the identity check.

  :attached  — probe the handshake file first (so a port bump by dev-boot.sh
               is honoured even in explicit-attach mode); if the handshake
               passes identity, return it.  If not, return CONFIGURED-ATTACH
               unchanged — explicit :attached preserves fail-at-call-time
               semantics for operators who know what they are connecting to.

In all cases a stale or foreign handshake endpoint is silently skipped."
  (when (eq resolved-mode :hermetic)
    (return-from resolve-slynk-target (values nil :hermetic)))

  ;; Step 1: prefer the handshake file when project-root is known.
  (when project-root
    (let ((handshake (read-slynk-handshake project-root)))
      (when handshake
        (if (%probe-with-identity handshake project-root)
            (progn
              (log-event :info "attach.probe.handshake-used"
                         "target" handshake)
              (return-from resolve-slynk-target
                (values handshake :attached)))
            (log-event :info "attach.probe.handshake-stale"
                       "target" handshake)))))

  ;; Step 2: try the configured target with identity check.
  (when (and configured-attach (plusp (length configured-attach)))
    (cond
      ((%probe-with-identity configured-attach project-root)
       (log-event :info "attach.probe.configured-used"
                  "target" configured-attach)
       (return-from resolve-slynk-target
         (values configured-attach :attached)))
      ((eq resolved-mode :auto)
       ;; Foreign image at configured port — fall back with a warning.
       (log-event :warn "attach.probe.foreign-image"
                  "target" configured-attach
                  "msg" "auto: Slynk at configured target belongs to another project, using hermetic")
       (return-from resolve-slynk-target (values nil :hermetic)))
      (t
       ;; :attached with a foreign image: warn but stay attached — the
       ;; operator explicitly named this endpoint.
       (log-event :warn "attach.probe.identity-mismatch"
                  "target" configured-attach
                  "msg" "attached: Slynk at configured target may belong to another project")
       (return-from resolve-slynk-target
         (values configured-attach :attached)))))

  ;; Step 3: no usable configured target.
  (if (eq resolved-mode :auto)
      (progn
        (log-event :warn "run.auto-mode"
                   "msg" "auto: no Slynk listener found for this project, using hermetic")
        (values nil :hermetic))
      ;; :attached with no target — fall through; each call will fail-fast.
      (values configured-attach :attached)))
