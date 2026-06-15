;;;; src/install/config.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Pure, testable core for the dsmr-mcp installer. Given a parsed
;;;; Claude-style config (a jzon hash-table) it returns a NEW config object
;;;; with the dsmr-mcp MCP server entry ensured under "mcpServers", applying
;;;; the cl-mcp coexistence/migration policy. No file IO lives here so every
;;;; transformation is unit-testable on in-memory objects.

(defpackage #:dsmr-mcp/src/install/config
  (:use #:cl)
  (:local-nicknames (#:jzon #:com.inuoe.jzon))
  (:export #:canonical-server-entry
           #:ensure-server
           #:has-cl-mcp-p
           #:+dsmr-server-name+
           #:+cl-mcp-server-name+))

(in-package #:dsmr-mcp/src/install/config)

;;; Server names -------------------------------------------------------------

(defparameter +dsmr-server-name+ "dsmr-mcp"
  "Key under \"mcpServers\" for the dsmr-mcp server entry.")

(defparameter +cl-mcp-server-name+ "cl-mcp"
  "Key under \"mcpServers\" for the cl-mcp server entry (the predecessor
this installer can optionally migrate away from).")

;;; Hash-table helper --------------------------------------------------------

(defun %ht (&rest kvs)
  "Build an equal-keyed hash-table from alternating KEY VALUE pairs.
jzon emits and consumes equal-keyed string-keyed hash-tables, so every
object that participates in the config wire must use :test 'equal."
  (let ((ht (make-hash-table :test 'equal)))
    (loop for (k v) on kvs by #'cddr
          do (setf (gethash k ht) v))
    ht))

(defun %vec (&rest items)
  "Build a simple-vector from ITEMS so jzon encodes it as a JSON array."
  (coerce items 'simple-vector))

;;; Canonical server entry ---------------------------------------------------

(defun %args-vector (system-name)
  "Return the args simple-vector for an SBCL stdio MCP launcher loading and
running SYSTEM-NAME (a keyword-name string such as \"dsmr-mcp\").

The args mirror the verified ~/.claude.json shape with one hardening: the
launcher keeps stdout free of everything except JSON-RPC.  SBCL is launched
quiet, debugger disabled, with --no-userinit so the operator's ~/.sbclrc
(and its Quicklisp quickload banner, which prints to stdout before any
--eval form runs) never executes.  Because --no-userinit drops the .sbclrc
Quicklisp bootstrap, the launcher loads Quicklisp's setup.lisp explicitly
with its output redirected to *error-output* (and gracefully no-ops when
setup.lisp is absent).  ASDF is required, the local-projects source tree is
pushed onto asdf:*central-registry* (preferring a non-tilde LISP_WORKSPACE,
falling back to ~/SourceCode/lisp/), the system is loaded with ASDF/UIOP
compile+load chatter wrapped to *error-output*, and finally its run entry
takes over a now-pristine stdout on the stdio transport."
  (%vec
   "--noinform"
   "--disable-debugger"
   "--no-userinit"
   "--eval" "(require :asdf)"
   ;; --no-userinit dropped the .sbclrc Quicklisp bootstrap; load setup.lisp
   ;; explicitly so dependencies resolve, redirecting its "To load X:" /
   ;; banner output to stderr and no-opping gracefully when it is absent.
   "--eval"
   (concatenate
    'string
    "(let ((s (merge-pathnames \"quicklisp/setup.lisp\" (user-homedir-pathname)))) "
    "(when (probe-file s) "
    "(let ((*standard-output* *error-output*)) (load s))))")
   "--eval"
   (concatenate
    'string
    "(push (or (let ((w (uiop:getenv \"LISP_WORKSPACE\"))) "
    "(when (and w (not (uiop:string-prefix-p \"~\" w))) w)) "
    "(namestring (merge-pathnames #P\"SourceCode/lisp/\" "
    "(user-homedir-pathname)))) asdf:*central-registry*)")
   ;; ASDF/UIOP compile+load output also goes to stderr so the JSON-RPC
   ;; channel (stdout) carries nothing until run takes over.  *debug-io* and
   ;; *trace-output* are rebound alongside *standard-output* because SLYNK's
   ;; loader prints its "SLYNK's ASDF loader finished." banner to *debug-io*,
   ;; not *standard-output* — binding only the latter still leaks that one line
   ;; onto fd 1 and breaks the handshake.  Mirrors the worker launcher in
   ;; src/hermetic/worker-client.lisp; the LET restores all three after the
   ;; load so run takes over a pristine stdout.
   "--eval" (format nil "(let ((*standard-output* *error-output*) (*trace-output* *error-output*) (*debug-io* (make-two-way-stream *standard-input* *error-output*))) (asdf:load-system :~A))"
                    system-name)
   "--eval" (format nil "(~A:run :transport :stdio)" system-name)))

(defun canonical-server-entry (&optional (system-name +dsmr-server-name+))
  "Return a NEW jzon hash-table describing the canonical stdio MCP server
entry for SYSTEM-NAME (default \"dsmr-mcp\").

The shape is {\"type\":\"stdio\",\"command\":\"sbcl\",\"args\":[...]}.
SYSTEM-NAME is parameterized so the same constructor can describe cl-mcp
or any sibling system that follows the load-then-run launcher convention."
  (%ht "type"    "stdio"
       "command" "sbcl"
       "args"    (%args-vector system-name)))

;;; Detector -----------------------------------------------------------------

(defun %servers (config)
  "Return the \"mcpServers\" hash-table from CONFIG, or NIL when absent or
not a hash-table."
  (when (hash-table-p config)
    (let ((servers (gethash "mcpServers" config)))
      (when (hash-table-p servers)
        servers))))

(defun has-cl-mcp-p (config)
  "Return T when parsed CONFIG contains an \"mcpServers\".\"cl-mcp\" entry.
Used for reporting whether a migration is in scope. Returns NIL when
mcpServers is missing or the cl-mcp key is absent."
  (let ((servers (%servers config)))
    (and servers
         (nth-value 1 (gethash +cl-mcp-server-name+ servers))
         t)))

;;; Shallow copy -------------------------------------------------------------

(defun %copy-ht (ht)
  "Return a fresh equal-keyed shallow copy of hash-table HT.
Top-level keys are copied; values are shared. The installer only mutates
the top-level config object and its \"mcpServers\" child, both of which
are copied here, so unrelated values stay untouched in the original."
  (let ((out (make-hash-table :test 'equal :size (max 1 (hash-table-count ht)))))
    (maphash (lambda (k v) (setf (gethash k out) v)) ht)
    out))

;;; Core transform -----------------------------------------------------------

(defun ensure-server (config &key (system-name +dsmr-server-name+)
                                  (on-existing-cl-mcp :keep))
  "Return a NEW config object derived from parsed CONFIG with the
SYSTEM-NAME server entry ensured under \"mcpServers\" and the cl-mcp
migration policy applied. CONFIG is never mutated.

CONFIG may be a jzon hash-table or NIL; NIL is treated as an empty config
and a minimal {\"mcpServers\":{...}} object is produced. Unrelated
top-level keys and unrelated mcpServers entries are preserved verbatim.

ON-EXISTING-CL-MCP selects what happens to any existing cl-mcp entry:
  :keep    (default) leave cl-mcp untouched; coexist with dsmr-mcp.
  :remove  delete the cl-mcp entry if present; migrate away from it.
  :replace delete cl-mcp and add dsmr-mcp (same end state as :remove for
           this single-server case; accepted as a distinct intent).

The transform is idempotent: applying it twice yields an object equal to
applying it once, because the dsmr-mcp entry is always set to the
canonical value and cl-mcp removal is a no-op when cl-mcp is absent."
  (check-type on-existing-cl-mcp (member :keep :remove :replace))
  (let* ((base (if (hash-table-p config)
                   (%copy-ht config)
                   (make-hash-table :test 'equal)))
         (existing-servers (gethash "mcpServers" base))
         (servers (if (hash-table-p existing-servers)
                      (%copy-ht existing-servers)
                      (make-hash-table :test 'equal))))
    ;; cl-mcp policy.
    (when (member on-existing-cl-mcp '(:remove :replace))
      (remhash +cl-mcp-server-name+ servers))
    ;; Always (re)set the dsmr-mcp entry to the canonical value.
    (setf (gethash system-name servers)
          (canonical-server-entry system-name))
    (setf (gethash "mcpServers" base) servers)
    base))
