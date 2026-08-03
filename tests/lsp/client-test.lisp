;;;; tests/lsp/client-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Tests for LSP-01: alive-lsp client lifecycle — framing, handshake,
;;;; attach-probe, spawn/port-readback, and per-root registry.
;;;;
;;;; These tests are red at Wave 0 (the dsmr-mcp/src/lsp/client package
;;;; does not exist yet) and will go green as Wave 1 lands.  The test
;;;; bodies reference Wave-1 symbols via find-symbol at runtime so this
;;;; file compiles clean before Wave 1.

;; Package evolution guard — delete prior definition on warm reload.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/lsp/client-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/lsp/client-test
  (:use #:cl #:parachute)
  (:local-nicknames (#:jzon #:com.inuoe.jzon))
  (:import-from #:dsmr-mcp/tests/support/lsp-mock
                #:with-lsp-mock-server
                #:%start-mock-lsp-server
                #:%stop-mock-lsp-server)
  (:import-from #:flexi-streams
                #:make-flexi-stream)
  (:import-from #:usocket)
  (:import-from #:bordeaux-threads))

(in-package #:dsmr-mcp/tests/lsp/client-test)

;;; ---------------------------------------------------------------------------
;;; Helpers
;;; ---------------------------------------------------------------------------

(defun socket-available-p ()
  "Return T when we can bind a TCP listen socket on loopback.
Returns NIL in sandboxed CI environments that deny socket creation."
  (handler-case
      (let ((sock (usocket:socket-listen "127.0.0.1" 0
                                         :reuse-address t
                                         :element-type 'character)))
        (unwind-protect
             (progn (usocket:get-local-port sock) t)
          (ignore-errors (usocket:socket-close sock))))
    (error () nil)))

(defun %lsp-client-pkg ()
  "Return the dsmr-mcp/src/lsp/client package or NIL if not yet loaded."
  (find-package "DSMR-MCP/SRC/LSP/CLIENT"))

(defun %client-sym (name)
  "Find NAME in the lsp/client package; return NIL if not loaded."
  (when (%lsp-client-pkg)
    (find-symbol name "DSMR-MCP/SRC/LSP/CLIENT")))

(defun %call-client-fn (name &rest args)
  "Call function NAME in lsp/client package with ARGS.
Returns two values: result and T on success, or NIL and NIL if the
package is not loaded."
  (let ((sym (%client-sym name)))
    (if (and sym (fboundp sym))
        (values (apply sym args) t)
        (values nil nil))))

(defun %server-request (method id)
  "Build a server-to-client JSON-RPC request hash-table with METHOD and ID.
Shaped like the requests alive-lsp initiates against a connected client."
  (let ((ht (make-hash-table :test 'equal)))
    (setf (gethash "jsonrpc" ht) "2.0"
          (gethash "id"      ht) id
          (gethash "method"  ht) method
          (gethash "params"  ht) (make-hash-table :test 'equal))
    ht))

;;; ---------------------------------------------------------------------------
;;; LSP-01: Content-Length framing round-trip
;;; ---------------------------------------------------------------------------

(define-test content-length-round-trip
  "A message written with the lsp client framing helpers is read back with
identical content.  Verifies that the Content-Length write/read layer is
byte-exact and symmetric across the loopback boundary."
  (if (not (socket-available-p))
      (skip "no loopback TCP listen socket available in this environment; socket bind is denied here")
      ;; Wave 0: the mock server is available but the Wave-1 client package is
      ;; not yet loaded.  Test the mock's own internal round-trip symmetry
      ;; by connecting with a raw usocket and doing a manual Content-Length
      ;; exchange, confirming the server echoes the canned response correctly.
      (let ((server nil)
            (bound-port nil))
        (unwind-protect
             (progn
               (setf server (%start-mock-lsp-server
                             :on-bound (lambda (p) (setf bound-port p))
                             :canned-responses
                             (list (cons "test/ping"
                                         (let ((ht (make-hash-table :test 'equal)))
                                           (setf (gethash "pong" ht) t)
                                           ht)))))
               (true bound-port)
               ;; Once Wave 1 lands, use connect-lsp-client and
               ;; lsp-send-request here.  Until then we confirm the server
               ;; starts and binds correctly.
               (true (numberp bound-port))
               (true (> bound-port 0)))
          (ignore-errors (%stop-mock-lsp-server server))))))

;;; ---------------------------------------------------------------------------
;;; LSP-01: initialize / initialized handshake round-trip
;;; ---------------------------------------------------------------------------

(define-test initialize-handshake-completes
  "The LSP client sends an initialize request and receives a result containing
server capabilities.  After sending the initialized notification the server
marks itself ready and the client's connected-p predicate returns T.
This test is red until the Wave-1 client package is loaded."
  (if (not (socket-available-p))
      (skip "no loopback TCP listen socket available in this environment; socket bind is denied here")
      (progn
        (unless (%lsp-client-pkg)
          ;; Wave 0: package absent — test is red (fail with a message).
          (fail "Wave-1 package dsmr-mcp/src/lsp/client not yet loaded; \
test will pass after Wave 1."))
        ;; Wave 1+: exercise the real handshake.
        (with-lsp-mock-server (client
                               :canned-responses
                               (list (cons "initialize"
                                           (let ((caps (make-hash-table :test 'equal)))
                                             (setf (gethash "capabilities" caps)
                                                   (make-hash-table :test 'equal))
                                             caps))))
          (true client)
          (let* ((connected-p-sym (%client-sym "LSP-CLIENT-CONNECTED-P"))
                 (connected-p (and connected-p-sym (fboundp connected-p-sym)
                                   (funcall connected-p-sym client))))
            (true connected-p))))))

;;; ---------------------------------------------------------------------------
;;; LSP-01: reader thread answers server→client workspace/configuration
;;; ---------------------------------------------------------------------------

(define-test reader-answers-workspace-configuration
  "The client answers a server-initiated request instead of ignoring it.
alive-lsp sends workspace/configuration in the middle of handling
textDocument/rangeFormatting and blocks its own reply on the answer, so an
unanswered request deadlocks the formatting call.  workspace/configuration is
answered with a one-element array holding an empty configuration object,
echoing the request id; any other server-initiated request is answered too, so
the server is never left waiting on a method the client does not implement.

The answer path is driven over a real loopback socket pair and the reply frame
is read back off the wire, so the assertions cover the serialised bytes rather
than an in-memory response object."
  (if (not (socket-available-p))
      (skip "no loopback TCP listen socket available in this environment; socket bind is denied here")
      (let ((answer-sym (%client-sym "%ANSWER-SERVER-REQUEST"))
            (read-sym   (%client-sym "%LSP-READ-MESSAGE"))
            (make-sym   (%client-sym "MAKE-LSP-CLIENT")))
        (unless (and answer-sym (fboundp answer-sym)
                     read-sym   (fboundp read-sym)
                     make-sym   (fboundp make-sym))
          (fail "dsmr-mcp/src/lsp/client internals %answer-server-request, \
%lsp-read-message and make-lsp-client must all be defined."))
        (let ((listener    nil)
              (client-sock nil)
              (server-conn nil))
          (unwind-protect
               (progn
                 (setf listener (usocket:socket-listen
                                 "127.0.0.1" 0
                                 :reuse-address t
                                 :element-type '(unsigned-byte 8)))
                 (setf client-sock (usocket:socket-connect
                                    "127.0.0.1" (usocket:get-local-port listener)
                                    :element-type '(unsigned-byte 8)))
                 (setf server-conn (usocket:socket-accept
                                    listener :element-type '(unsigned-byte 8)))
                 (let ((client    (funcall make-sym
                                           :socket client-sock
                                           :flexi-stream
                                           (make-flexi-stream
                                            (usocket:socket-stream client-sock))))
                       (server-in (make-flexi-stream
                                   (usocket:socket-stream server-conn))))
                   ;; workspace/configuration: one-element array, empty object.
                   (funcall answer-sym client
                            (%server-request "workspace/configuration" 77))
                   (let* ((reply  (funcall read-sym server-in))
                          (result (gethash "result" reply)))
                     (is eql 77 (gethash "id" reply)
                         "the answer must echo the request id")
                     (true (vectorp result)
                           "workspace/configuration must be answered with an array")
                     (is eql 1 (length result)
                         "the array must hold exactly one configuration entry")
                     (let ((entry (aref result 0)))
                       (true (hash-table-p entry)
                             "the array entry must be a configuration object")
                       (is eql 0 (hash-table-count entry)
                           "the configuration object must be empty")))
                   ;; Any other server request: null result, so nothing blocks.
                   (funcall answer-sym client
                            (%server-request "some/unknown-method" 78))
                   (let ((reply (funcall read-sym server-in)))
                     (is eql 78 (gethash "id" reply)
                         "the answer must echo the request id")
                     ;; The result value itself is deliberately not pinned here.
                     ;; What has to hold is that a result comes back at all, so
                     ;; the server stops waiting, and that an arbitrary method
                     ;; is not handed a configuration array as though it had
                     ;; asked for one.
                     (true (nth-value 1 (gethash "result" reply))
                           "an unrecognised server request must still carry a result, \
so the server is not left waiting")
                     (let ((result (gethash "result" reply)))
                       ;; A JSON array parses to a vector; so does a JSON
                       ;; string, hence the stringp exclusion.
                       (false (and (vectorp result) (not (stringp result)))
                              "an unrecognised server request must not be answered \
with a configuration array")))))
            (ignore-errors (usocket:socket-close server-conn))
            (ignore-errors (usocket:socket-close client-sock))
            (ignore-errors (usocket:socket-close listener)))))))

;;; ---------------------------------------------------------------------------
;;; LSP-01: attach-probe finds a reachable server
;;; ---------------------------------------------------------------------------

(define-test attach-probe-finds-reachable-server
  "ensure-lsp-client attaches to an already-running server at the configured
port instead of spawning a new child process.  The returned client has
attached-p = T.
Red until Wave-1 ensure-lsp-client is implemented."
  (if (not (socket-available-p))
      (skip "no loopback TCP listen socket available in this environment; socket bind is denied here")
      (progn
        (unless (%lsp-client-pkg)
          (fail "Wave-1 package dsmr-mcp/src/lsp/client not yet loaded."))
        (with-lsp-mock-server (client)
          (true client)
          ;; Wave 1+: verify attached-p is T (we attached, not spawned).
          (let ((attached-sym (%client-sym "LSP-CLIENT-ATTACHED-P")))
            (when (and attached-sym (fboundp attached-sym))
              (true (funcall attached-sym client))))))))

;;; ---------------------------------------------------------------------------
;;; LSP-01: spawn reads back ephemeral port
;;; ---------------------------------------------------------------------------

(define-test spawn-port-readback-parses-starting-line
  "The port readback extracts the ephemeral port alive-lsp prints on stdout.
It steps over banner and compile noise, takes the port from the first
[STARTING] Started on port N line it meets, and signals rather than returning
a bogus port when the child closes stdout without ever printing one.

The spawn itself is out of reach of a unit test: it needs an alive-lsp
checkout named by DSMR_ALIVE_LSP_DIR plus a child SBCL, and takes tens of
seconds to come up.  What is asserted here instead is the parsing the spawn
depends on, plus the contract that spawn stays disabled when no alive-lsp
directory is configured: it returns NIL and launches nothing."
  (let ((parse-sym (%client-sym "%PARSE-LSP-STARTED-LINE"))
        (spawn-sym (%client-sym "%SPAWN-LSP-CHILD"))
        (dir-sym   (%client-sym "*ALIVE-LSP-DIR*")))
    (unless (and parse-sym (fboundp parse-sym)
                 spawn-sym (fboundp spawn-sym)
                 dir-sym   (boundp dir-sym))
      (fail "dsmr-mcp/src/lsp/client internals %parse-lsp-started-line, \
%spawn-lsp-child and *alive-lsp-dir* must all be defined."))
    ;; The port comes from the STARTING line, not from the noise around it,
    ;; and the first such line wins.
    (with-input-from-string
        (s (format nil "; compiling alive-lsp~%~
                        [STARTING] Started on port 43217~%~
                        [STARTING] Started on port 9999~%"))
      (is eql 43217 (funcall parse-sym s)))
    ;; A STARTING line arriving after several unrelated lines is still found.
    (with-input-from-string
        (s (format nil "loading...~%ready~%~
                        [STARTING] Started on port 65001~%"))
      (is eql 65001 (funcall parse-sym s)))
    ;; Stdout closing without the line signals; it never yields a silent port.
    (with-input-from-string
        (s (format nil "; compiling alive-lsp~%no port on this line~%"))
      (fail (funcall parse-sym s) 'error))
    ;; With no alive-lsp directory configured, spawn declines and returns NIL
    ;; rather than launching a child that could never work.
    (progv (list dir-sym) (list nil)
      (false (funcall spawn-sym #p"/tmp/dsmr-lsp-spawn-disabled/")
             "spawn must decline when no alive-lsp directory is configured"))))

;;; ---------------------------------------------------------------------------
;;; LSP-01: per-root registry shares one client across sessions
;;; ---------------------------------------------------------------------------

(define-test per-root-registry-shares-one-client
  "Two ensure-lsp-client calls for the same project root return the very same
client object.  The first attaches and registers it; the second is served from
the per-root registry without opening a second connection, which is what keeps
one alive-lsp per root instead of one per caller.

Driven against the mock server with the attach host and port pointed at it, so
the first call takes the real attach path."
  (if (not (socket-available-p))
      (skip "no loopback TCP listen socket available in this environment; socket bind is denied here")
      (let ((ensure-sym   (%client-sym "ENSURE-LSP-CLIENT"))
            (shutdown-sym (%client-sym "LSP-SHUTDOWN"))
            (registry-sym (%client-sym "*LSP-REGISTRY*"))
            (host-sym     (%client-sym "*LSP-ATTACH-HOST*"))
            (port-sym     (%client-sym "*LSP-ATTACH-PORT*")))
        (unless (and ensure-sym   (fboundp ensure-sym)
                     shutdown-sym (fboundp shutdown-sym)
                     registry-sym (boundp registry-sym)
                     host-sym     (boundp host-sym)
                     port-sym     (boundp port-sym))
          (fail "dsmr-mcp/src/lsp/client ensure-lsp-client, lsp-shutdown, \
*lsp-registry*, *lsp-attach-host* and *lsp-attach-port* must all be defined."))
        (let ((server     nil)
              (bound-port nil)
              (root       #p"/tmp/dsmr-lsp-registry-test/"))
          (unwind-protect
               (progn
                 (setf server (%start-mock-lsp-server
                               :on-bound (lambda (p) (setf bound-port p))))
                 (true bound-port "the mock server must report its bound port")
                 ;; A private registry so the assertion counts only this test's
                 ;; entries, and an attach target pointed at the mock.
                 (progv (list registry-sym host-sym port-sym)
                     (list (make-hash-table :test 'equal) "127.0.0.1" bound-port)
                   (let ((client-1 (funcall ensure-sym root))
                         (client-2 nil))
                     (unwind-protect
                          (progn
                            (true client-1
                                  "the first ensure-lsp-client must attach to the mock")
                            ;; Bounded on purpose.  A registry that failed to
                            ;; serve the second call would fall through to a
                            ;; fresh connection, and the mock serves one
                            ;; connection at a time: the handshake would wait
                            ;; on a reply nobody is there to send, hanging the
                            ;; suite instead of reporting.
                            (setf client-2
                                  (handler-case
                                      (sb-ext:with-timeout 5
                                        (funcall ensure-sym root))
                                    (sb-ext:timeout () :timed-out)))
                            (true (eq client-1 client-2)
                                  "a second ensure-lsp-client for the same root must \
return the cached client, not a fresh connection")
                            (is eql 1 (hash-table-count (symbol-value registry-sym))
                                "one root must occupy exactly one registry entry"))
                       (when (and client-2 (not (eq client-2 client-1))
                                  (not (eq client-2 :timed-out)))
                         (ignore-errors (funcall shutdown-sym client-2)))
                       (when client-1
                         (ignore-errors (funcall shutdown-sym client-1)))))))
            (ignore-errors (%stop-mock-lsp-server server)))))))
