;;;; tests/lsp/document-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Tests for LSP-03: document lifecycle — didOpen, didChange, didClose —
;;;; with the write-jail allow-list policy (D-11).
;;;;
;;;; Red at Wave 0 (dsmr-mcp/src/lsp/document not yet loaded).
;;;; Will go green as Wave 2 lands the document notification module.

;; Package evolution guard — delete prior definition on warm reload.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/lsp/document-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/lsp/document-test
  (:use #:cl #:zebra)
  (:import-from #:dsmr-mcp/tests/support/lsp-mock
                #:with-lsp-mock-server
                #:%start-mock-lsp-server
                #:%stop-mock-lsp-server
                #:mock-lsp-server-received-methods)
  (:import-from #:dsmr-mcp/tests/support/fs-fixture
                #:with-temp-project-root
                #:write-fixture-file)
  (:import-from #:usocket))

(in-package #:dsmr-mcp/tests/lsp/document-test)

;;; ---------------------------------------------------------------------------
;;; Helpers
;;; ---------------------------------------------------------------------------

(defun socket-available-p ()
  "Return T when we can bind a TCP listen socket on loopback."
  (handler-case
      (let ((sock (usocket:socket-listen "127.0.0.1" 0
                                         :reuse-address t
                                         :element-type 'character)))
        (unwind-protect
             (progn (usocket:get-local-port sock) t)
          (ignore-errors (usocket:socket-close sock))))
    (error () nil)))

(defun %document-pkg ()
  "Return the dsmr-mcp/src/lsp/document package or NIL if not yet loaded."
  (find-package "DSMR-MCP/SRC/LSP/DOCUMENT"))

(defun %document-sym (name)
  "Find NAME in the lsp/document package; return NIL if not loaded."
  (when (%document-pkg)
    (find-symbol name "DSMR-MCP/SRC/LSP/DOCUMENT")))

(defun %client-sym (name)
  "Find NAME in the lsp/client package; return NIL if not loaded."
  (when (find-package "DSMR-MCP/SRC/LSP/CLIENT")
    (find-symbol name "DSMR-MCP/SRC/LSP/CLIENT")))

(defun %await-method (server method &key (timeout 2.0))
  "Return T once SERVER has recorded an inbound METHOD, NIL after TIMEOUT seconds.
The mock's accept thread records methods as it reads them, so a test asserting
on the wire has to let the notification cross rather than read the list the
instant the notify call returns."
  (let ((deadline (+ (get-internal-real-time)
                     (* timeout internal-time-units-per-second))))
    (loop
      (when (find method (mock-lsp-server-received-methods server)
                  :test #'string=)
        (return t))
      (when (> (get-internal-real-time) deadline)
        (return nil))
      (sleep 0.02))))

(defmacro %with-jailed-client ((client-var server-var root) &body body)
  "Run BODY with CLIENT-VAR bound to an LSP client connected to a fresh mock
server, and SERVER-VAR bound to that mock server.  Both are torn down on every
exit path.  The client carries ROOT as its project root, which is the jail the
document module consults before it will send anything for a path."
  (let ((port-var     (gensym "PORT-"))
        (connect-var  (gensym "CONNECT-"))
        (shutdown-var (gensym "SHUTDOWN-")))
    `(let ((,port-var     nil)
           (,server-var   nil)
           (,client-var   nil)
           (,connect-var  (%client-sym "CONNECT-LSP-CLIENT"))
           (,shutdown-var (%client-sym "LSP-SHUTDOWN")))
       (if (not (and ,connect-var  (fboundp ,connect-var)
                     ,shutdown-var (fboundp ,shutdown-var)))
           (fail "CONNECT-LSP-CLIENT and LSP-SHUTDOWN must be defined in \
dsmr-mcp/src/lsp/client.")
           (unwind-protect
                (progn
                  (setf ,server-var (%start-mock-lsp-server
                                     :on-bound (lambda (p) (setf ,port-var p))))
                  (setf ,client-var (funcall ,connect-var "127.0.0.1" ,port-var
                                             :project-root ,root))
                  (true ,client-var "the client must connect to the mock server")
                  ,@body)
             (when ,client-var
               (ignore-errors (funcall ,shutdown-var ,client-var)))
             (ignore-errors (%stop-mock-lsp-server ,server-var)))))))

;;; ---------------------------------------------------------------------------
;;; LSP-03: didChange fires after a successful write
;;; ---------------------------------------------------------------------------

(define-test did-change-fires-after-write
  "notify-did-change puts a textDocument/didChange notification on the wire for
a file inside the client's write jail.  The mock server records every inbound
method, so the assertion is that the notification actually reached the server.
The return value proves nothing here: notify-did-change returns NIL whether it
sent the notification or refused the path (D-10 fire-and-forget)."
  (if (not (socket-available-p))
      (skip "no loopback TCP listen socket available in this environment; socket bind is denied here")
      (with-temp-project-root (session root)
        (let ((notify-sym (%document-sym "NOTIFY-DID-CHANGE")))
          (declare (ignore session))
          (if (not (and notify-sym (fboundp notify-sym)))
              (fail "NOTIFY-DID-CHANGE not defined in dsmr-mcp/src/lsp/document.")
              (%with-jailed-client (client server root)
                (let* ((test-file (write-fixture-file root "test.lisp"
                                                      "(defun foo () :ok)"))
                       (text (with-open-file (s test-file)
                               (let ((buf (make-string (file-length s))))
                                 (read-sequence buf s)
                                 buf))))
                  (funcall notify-sym client test-file text 2)
                  (true (%await-method server "textDocument/didChange")
                        "notify-did-change must put textDocument/didChange on the wire \
for a file inside the jail"))))))))

;;; ---------------------------------------------------------------------------
;;; LSP-03: path outside write-jail does not fire didChange
;;; ---------------------------------------------------------------------------

(define-test path-outside-write-jail-skips-did-change
  "notify-did-change is a silent no-op for a path outside the client's write
jail: nothing reaches the server (D-11).  The assertion has to be on the wire,
because the return value is NIL on the allowed path too and so cannot tell the
two apart.
A control follows the refusal: the same client, same connection, a path inside
the jail, and that one must arrive.  Without it, a dead connection or a broken
mock would produce the same silence and read as a pass."
  (if (not (socket-available-p))
      (skip "no loopback TCP listen socket available in this environment; socket bind is denied here")
      (with-temp-project-root (session root)
        (let ((notify-sym (%document-sym "NOTIFY-DID-CHANGE")))
          (declare (ignore session))
          (if (not (and notify-sym (fboundp notify-sym)))
              (fail "NOTIFY-DID-CHANGE not defined in dsmr-mcp/src/lsp/document.")
              (%with-jailed-client (client server root)
                ;; /tmp is the parent of the temp root, so a file directly in it
                ;; is outside the jail.
                (funcall notify-sym client "/tmp/outside-jail.lisp"
                         "(defun evil () nil)" 1)
                (false (%await-method server "textDocument/didChange" :timeout 0.5)
                       "a path outside the write jail must not reach the server")
                ;; Control: an in-jail path over the same connection does arrive,
                ;; so the silence above is the jail refusing, not a dead wire.
                (let ((inside (write-fixture-file root "inside.lisp"
                                                  "(defun ok () t)")))
                  (funcall notify-sym client inside "(defun ok () t)" 1)
                  (true (%await-method server "textDocument/didChange")
                        "control: a path inside the jail must reach the server"))))))))
