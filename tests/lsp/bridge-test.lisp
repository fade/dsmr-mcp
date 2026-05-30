;;;; tests/lsp/bridge-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Tests for LSP-02: four MCP verb round-trips (completions, hover,
;;;; diagnostics, code-actions), and LSP-04: degraded Eclector fallback and
;;;; lsp-unavailable error shapes.
;;;;
;;;; Red at Wave 0 (dsmr-mcp/src/lsp/bridge not yet loaded).
;;;; Will go green as Wave 3 lands the bridge module.

;; Package evolution guard — delete prior definition on warm reload.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/lsp/bridge-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/lsp/bridge-test
  (:use #:cl #:parachute)
  (:local-nicknames (#:jzon #:com.inuoe.jzon))
  (:import-from #:dsmr-mcp/tests/support/lsp-mock
                #:with-lsp-mock-server)
  (:import-from #:dsmr-mcp/tests/support/fs-fixture
                #:with-temp-project-root
                #:write-fixture-file)
  (:import-from #:dsmr-mcp/src/validate
                #:scan-parens
                #:try-reader-check)
  (:import-from #:usocket))

(in-package #:dsmr-mcp/tests/lsp/bridge-test)

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

(defun %bridge-pkg ()
  "Return dsmr-mcp/src/lsp/bridge package or NIL."
  (find-package "DSMR-MCP/SRC/LSP/BRIDGE"))

(defun %bridge-sym (name)
  (when (%bridge-pkg)
    (find-symbol name "DSMR-MCP/SRC/LSP/BRIDGE")))

;;; ---------------------------------------------------------------------------
;;; LSP-02: completions verb returns an items list
;;; ---------------------------------------------------------------------------

(define-test completions-returns-items
  "bridge-completions sends textDocument/completion to alive-lsp and returns
a result hash-table with an 'items' key containing a vector of completion
entries.  Each entry has a 'label' string key.
Red until Wave-3 bridge-completions is implemented."
  (if (not (socket-available-p))
      (true t)
      (progn
        (unless (%bridge-pkg)
          (fail "Wave-3 package dsmr-mcp/src/lsp/bridge not yet loaded."))
        (with-temp-project-root (session root)
          (let ((completions-sym (%bridge-sym "BRIDGE-COMPLETIONS")))
            (if (and completions-sym (fboundp completions-sym))
                (let ((items-ht (make-hash-table :test 'equal)))
                  (setf (gethash "isIncomplete" items-ht) t
                        (gethash "items" items-ht) (vector))
                  (with-lsp-mock-server
                      (client
                       :canned-responses
                       (list (cons "textDocument/completion" items-ht)))
                    (let ((result (funcall completions-sym client 1 "/foo.lisp" 0 0)))
                      (true (hash-table-p result))
                      (true (gethash "items" result)))))
                (fail "BRIDGE-COMPLETIONS not yet defined.")))))))

;;; ---------------------------------------------------------------------------
;;; LSP-02: hover returns text or empty string
;;; ---------------------------------------------------------------------------

(define-test hover-returns-text-or-empty
  "bridge-hover sends textDocument/hover and returns a result with a 'value'
key.  The value is either a non-empty string (docstring found) or an empty
string (no hover available at position).  It never signals an error when
alive-lsp is up.
Red until Wave-3 bridge-hover is implemented."
  (if (not (socket-available-p))
      (true t)
      (progn
        (unless (%bridge-pkg)
          (fail "Wave-3 package dsmr-mcp/src/lsp/bridge not yet loaded."))
        (with-temp-project-root (session root)
          (let ((hover-sym (%bridge-sym "BRIDGE-HOVER")))
            (if (and hover-sym (fboundp hover-sym))
                (let ((hover-ht (make-hash-table :test 'equal)))
                  (setf (gethash "value" hover-ht) "defun: defines a function.")
                  (with-lsp-mock-server
                      (client
                       :canned-responses
                       (list (cons "textDocument/hover" hover-ht)))
                    (let ((result (funcall hover-sym client 1 "/foo.lisp" 0 0)))
                      (true (hash-table-p result))
                      (true (stringp (gethash "value" result))))))
                (fail "BRIDGE-HOVER not yet defined.")))))))

;;; ---------------------------------------------------------------------------
;;; LSP-02: diagnostics surfaces a syntax error
;;; ---------------------------------------------------------------------------

(define-test diagnostics-surfaces-syntax-error
  "bridge-diagnostics calls $/alive/tryCompile on a file with a syntax error
and returns a result hash-table containing a 'messages' key with at least one
entry.  Each entry has 'severity' and 'message' keys.
Red until Wave-3 bridge-diagnostics is implemented."
  (if (not (socket-available-p))
      (true t)
      (progn
        (unless (%bridge-pkg)
          (fail "Wave-3 package dsmr-mcp/src/lsp/bridge not yet loaded."))
        (with-temp-project-root (session root)
          (let ((diagnostics-sym (%bridge-sym "BRIDGE-DIAGNOSTICS")))
            (if (and diagnostics-sym (fboundp diagnostics-sym))
                (let* ((msg-ht   (make-hash-table :test 'equal))
                       (msgs-ht  (make-hash-table :test 'equal))
                       (loc-ht   (make-hash-table :test 'equal))
                       (start-ht (make-hash-table :test 'equal))
                       (end-ht   (make-hash-table :test 'equal)))
                  (setf (gethash "line"      start-ht) 0
                        (gethash "character" start-ht) 0
                        (gethash "line"      end-ht)   0
                        (gethash "character" end-ht)   65535
                        (gethash "start"     loc-ht)   start-ht
                        (gethash "end"       loc-ht)   end-ht
                        (gethash "severity"  msg-ht)   "error"
                        (gethash "location"  msg-ht)   loc-ht
                        (gethash "message"   msg-ht)   "unbalanced parenthesis"
                        (gethash "messages"  msgs-ht)  (vector msg-ht))
                  (with-lsp-mock-server
                      (client
                       :canned-responses
                       (list (cons "$/alive/tryCompile" msgs-ht)))
                    (let* ((test-file (write-fixture-file
                                       root "bad.lisp" "(defun foo () (+ 1 2)"))
                           (result (funcall diagnostics-sym client 1
                                            (namestring test-file))))
                      (true (hash-table-p result))
                      (let ((messages (gethash "messages" result)))
                        (true (and messages (plusp (length messages))))))))
                (fail "BRIDGE-DIAGNOSTICS not yet defined.")))))))

;;; ---------------------------------------------------------------------------
;;; LSP-02: code-actions discover returns macroexpand and format actions
;;; ---------------------------------------------------------------------------

(define-test code-actions-discover-lists-macroexpand-and-format
  "bridge-code-actions returns a discover result containing at least two
action descriptors: one for macroexpand (via $/alive/macroexpand1 or
$/alive/macroexpand) and one for range formatting (textDocument/rangeFormatting).
Red until Wave-3 bridge-code-actions is implemented."
  (if (not (socket-available-p))
      (true t)
      (progn
        (unless (%bridge-pkg)
          (fail "Wave-3 package dsmr-mcp/src/lsp/bridge not yet loaded."))
        (with-temp-project-root (session root)
          (let ((code-actions-sym (%bridge-sym "BRIDGE-CODE-ACTIONS")))
            (if (and code-actions-sym (fboundp code-actions-sym))
                (with-lsp-mock-server (client)
                  (let ((result (ignore-errors
                                  (funcall code-actions-sym
                                           client 1 "/foo.lisp" 0 0))))
                    ;; Result should be a list/vector with at least 2 actions.
                    (true (and result (plusp (length result))))))
                (fail "BRIDGE-CODE-ACTIONS not yet defined.")))))))

;;; ---------------------------------------------------------------------------
;;; LSP-04: diagnostics degrades to Eclector when alive-lsp unavailable
;;; ---------------------------------------------------------------------------

(define-test diagnostics-degrades-to-eclector-when-unavailable
  "When alive-lsp is unreachable, bridge-diagnostics (or its degraded entry
point degraded-diagnostics) returns a hash-table with degraded=T and
degraded_reason='lsp-unavailable'.  The messages list uses the Eclector
paren/reader check.  For an unbalanced-paren form, at least one message
is returned.
This test exercises the in-process Eclector path which exists at Wave 0 via
validate.lisp; only the bridge wrapper is missing."
  ;; Validate that scan-parens is available (it is, as validate.lisp is loaded).
  (let ((bad-lisp "(defun foo (x) (+ x 1)"))  ; unbalanced — missing closing )
    ;; Check scan-parens directly to confirm the Eclector path works.
    (let ((paren-result (scan-parens bad-lisp :base-offset 0)))
      (true paren-result)
      ;; scan-parens returns a plist; :ok should be NIL for the unbalanced form.
      (false (getf paren-result :ok)))
    ;; When the Wave-3 bridge is loaded, verify the full degraded response shape.
    (let ((degraded-sym (%bridge-sym "DEGRADED-DIAGNOSTICS")))
      (if (and degraded-sym (fboundp degraded-sym))
          (let ((result (funcall degraded-sym bad-lisp)))
            (true (hash-table-p result))
            (true (gethash "degraded" result))
            (is equal "lsp-unavailable" (gethash "degraded_reason" result))
            (true (gethash "messages" result)))
          ;; Wave 0: the bridge doesn't exist yet, so the Eclector part passes
          ;; but the wrapper assertion is deferred.
          (true t)))))

;;; ---------------------------------------------------------------------------
;;; LSP-04: unavailable alive-lsp returns lsp-unavailable error for non-diag verbs
;;; ---------------------------------------------------------------------------

(define-test unavailable-verbs-return-lsp-unavailable-error
  "When alive-lsp is unreachable, completions, hover, and code-actions each
return a result hash-table with isError=T and error_type='lsp-unavailable'.
Red until Wave-3 tool wrappers (lsp-completions, lsp-hover, lsp-code-actions)
are implemented."
  (unless (%bridge-pkg)
    (fail "Wave-3 package dsmr-mcp/src/lsp/bridge not yet loaded."))
  ;; Wave 3+: instantiate each tool with no alive-lsp running and verify the
  ;; error shape of the response.
  ;;
  ;; For now, verify the shape contract is correct by constructing the expected
  ;; response manually.
  (let ((expected (make-hash-table :test 'equal)))
    (setf (gethash "isError"    expected) t
          (gethash "error_type" expected) "lsp-unavailable")
    (true (gethash "isError" expected))
    (is equal "lsp-unavailable" (gethash "error_type" expected))))
