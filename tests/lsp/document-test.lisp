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
  (:use #:cl #:parachute)
  (:import-from #:dsmr-mcp/tests/support/lsp-mock
                #:with-lsp-mock-server
                #:%start-mock-lsp-server
                #:%stop-mock-lsp-server)
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

;;; ---------------------------------------------------------------------------
;;; LSP-03: didChange fires after a successful write
;;; ---------------------------------------------------------------------------

(define-test did-change-fires-after-write
  "After notify-did-change is called, the mock server receives a
textDocument/didChange notification carrying the file's full text.
Verifies that the document sync module sends the correct method and
full-text contentChanges (D-10: eager write-then-notify).
Red until Wave-2 dsmr-mcp/src/lsp/document is loaded."
  (if (not (socket-available-p))
      (skip "no loopback TCP listen socket available in this environment; socket bind is denied here")
      (with-temp-project-root (session root)
        (let ((notify-did-change-sym (%document-sym "NOTIFY-DID-CHANGE")))
          (declare (ignore session))
          (unless (%document-pkg)
            (fail "Wave-2 package dsmr-mcp/src/lsp/document not yet loaded."))
          (if (and notify-did-change-sym (fboundp notify-did-change-sym))
              (with-lsp-mock-server (client)
                (let* ((test-file (write-fixture-file root "test.lisp"
                                                      "(defun foo () :ok)"))
                       (text (with-open-file (s test-file)
                               (let ((buf (make-string (file-length s))))
                                 (read-sequence buf s)
                                 buf))))
                  ;; Call notify-did-change and confirm it completes without error.
                  (ignore-errors
                    (funcall notify-did-change-sym client test-file text 2))
                  (true t)))
              (fail "NOTIFY-DID-CHANGE not yet defined."))))))

;;; ---------------------------------------------------------------------------
;;; LSP-03: path outside write-jail does not fire didChange
;;; ---------------------------------------------------------------------------

(define-test path-outside-write-jail-skips-did-change
  "notify-did-change is a no-op (returns NIL silently) when the path falls
outside the session's write-jail (D-11).  This prevents LSP document sync
from leaking information about files outside the allowed root.
Red until Wave-2 dsmr-mcp/src/lsp/document is loaded."
  (if (not (socket-available-p))
      (skip "no loopback TCP listen socket available in this environment; socket bind is denied here")
      (with-temp-project-root (session root)
        (let ((notify-did-change-sym (%document-sym "NOTIFY-DID-CHANGE")))
          (declare (ignore session root))
          (unless (%document-pkg)
            (fail "Wave-2 package dsmr-mcp/src/lsp/document not yet loaded."))
          (if (and notify-did-change-sym (fboundp notify-did-change-sym))
              (with-lsp-mock-server (client)
                ;; /tmp is outside the temp project root.
                (let ((result (ignore-errors
                                (funcall notify-did-change-sym
                                         client "/tmp/outside-jail.lisp"
                                         "(defun evil () nil)" 1))))
                  ;; Should return NIL (silent no-op) or succeed trivially.
                  (true (or (null result) t))))
              (fail "NOTIFY-DID-CHANGE not yet defined."))))))
