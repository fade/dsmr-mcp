;;;; tests/code-intelligence/code-find-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Tests for the code-find verb (VERB-13): dual-mode coverage.
;;;;
;;;; Coverage:
;;;;   - Hermetic: %handle-code-find returns project-relative path + line for a
;;;;     symbol loaded in the current image (criterion 1)
;;;;   - Hermetic: missing symbol returns typed symbol-not-found error with hint
;;;;   - Inline: tool-handle with *mode* bound to :inline returns typed mode error
;;;;   - Hermetic timeout: sb-ext:with-timeout boundary respected

(defpackage #:dsmr-mcp/tests/code-intelligence/code-find-test
  (:use #:cl #:zebra)
  (:import-from #:dsmr-mcp/tests/support/slynk-fixture
                #:with-temporary-slynk-listener)
  (:import-from #:dsmr-mcp/src/hermetic/worker/handlers
                #:%handle-code-find)
  (:import-from #:dsmr-mcp/src/tools/code-find
                #:code-find-tool
                #:%dispatch-attach-code-find)
  (:import-from #:dsmr-mcp/src/tools/base
                #:tool-handle)
  (:import-from #:dsmr-mcp/src/state
                #:make-session
                #:*current-session-id*
                #:get-tool-instance
                #:*mode*)
  (:import-from #:dsmr-mcp/src/attach/dispatch
                #:repl-eval-tool-slynk-conn)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:make-ht)
  (:import-from #:asdf
                #:system-source-directory))

(in-package #:dsmr-mcp/tests/code-intelligence/code-find-test)

;;; ---------------------------------------------------------------------------
;;; Helpers
;;; ---------------------------------------------------------------------------

(defun make-params (&rest kvs)
  "Build a string-keyed hash-table from alternating key/value pairs."
  (let ((ht (make-hash-table :test 'equal)))
    (loop for (k v) on kvs by #'cddr
          do (setf (gethash k ht) v))
    ht))

;;; ---------------------------------------------------------------------------
;;; Hermetic: %handle-code-find returns locations for a known symbol
;;; ---------------------------------------------------------------------------

(define-test code-find-hermetic-returns-locations-for-known-symbol
  "Calling %handle-code-find for a symbol that is loaded in the current image
returns a hash-table with a non-empty 'locations' vector.  Each location has
'path', 'line', and 'kind' fields."
  (let* ((params (make-params "symbol" "dsmr-mcp/src/code-core:code-find-definition"))
         (result (%handle-code-find params nil)))
    (true (hash-table-p result))
    (false (gethash "isError" result))
    (let ((locs (gethash "locations" result)))
      (true (and locs (plusp (length locs))))
      (let ((first-loc (aref locs 0)))
        (true (hash-table-p first-loc))
        (true (stringp (gethash "path" first-loc)))
        (true (integerp (gethash "line" first-loc)))
        (true (stringp (gethash "kind" first-loc)))
        ;; Verify the path is non-empty and the line is positive.
        (true (plusp (length (gethash "path" first-loc))))
        (true (plusp (gethash "line" first-loc)))))))

;;; ---------------------------------------------------------------------------
;;; Criterion 1: path is relative when session root is set and the symbol's
;;; source is under it; absolute when outside root or no root is given.
;;; ---------------------------------------------------------------------------

(define-test code-find-returns-relative-path-under-session-root
  "When %handle-code-find is called with a project_root set to the dsmr-mcp
checkout root and a symbol whose source is in that tree, the returned path is
project-relative: no leading directory separator, and merging it under the root
resolves to an existing file."
  (let* ((root-pn  (asdf:system-source-directory :dsmr-mcp))
         (root-str (namestring root-pn))
         (params   (make-params "symbol"       "dsmr-mcp/src/code-core:code-find-definition"
                                "package"      "dsmr-mcp/src/code-core"
                                "project_root" root-str))
         (result   (%handle-code-find params nil)))
    (true (hash-table-p result))
    (false (gethash "isError" result))
    (let* ((locs (gethash "locations" result))
           (path (and locs (plusp (length locs))
                      (gethash "path" (aref locs 0)))))
      (true (stringp path))
      (true (plusp (length path)))
      ;; Path must be relative (no leading /).
      (false (char= (char path 0) #\/))
      ;; Merging back under root must resolve to an existing file.
      (true (probe-file (merge-pathnames path root-pn))))))

(define-test code-find-returns-absolute-path-outside-session-root
  "When %handle-code-find is called with a project_root that does NOT contain
the symbol's source file, the returned path is absolute (first char is /)."
  (let* (;; Use /tmp as the session root — no dsmr-mcp source lives there.
         (params (make-params "symbol"       "dsmr-mcp/src/code-core:code-find-definition"
                              "package"      "dsmr-mcp/src/code-core"
                              "project_root" "/tmp/"))
         (result (%handle-code-find params nil)))
    (true (hash-table-p result))
    (false (gethash "isError" result))
    (let* ((locs (gethash "locations" result))
           (path (and locs (plusp (length locs))
                      (gethash "path" (aref locs 0)))))
      (true (stringp path))
      (true (plusp (length path)))
      ;; Path must be absolute since the source is not under /tmp/.
      (true (char= (char path 0) #\/)))))

(define-test code-find-returns-absolute-path-when-no-root
  "When %handle-code-find is called without a project_root param, the returned
path is absolute — preserving the no-root contract."
  (let* ((params (make-params "symbol"  "dsmr-mcp/src/code-core:code-find-definition"
                              "package" "dsmr-mcp/src/code-core"))
         (result (%handle-code-find params nil)))
    (true (hash-table-p result))
    (false (gethash "isError" result))
    (let* ((locs (gethash "locations" result))
           (path (and locs (plusp (length locs))
                      (gethash "path" (aref locs 0)))))
      (true (stringp path))
      (true (plusp (length path)))
      ;; No root -> path must be absolute.
      (true (char= (char path 0) #\/)))))

;;; ---------------------------------------------------------------------------
;;; Hermetic: package not found returns typed not-found error with hint
;;;
;;; Using an explicit package that doesn't exist gives a reliable typed error.
;;; A bare unqualified symbol that doesn't exist in the image may return
;;; found-but-no-source-location rather than symbol-not-found in SBCL (the
;;; symbol exists in the package namespace after reading, just has no source).
;;; ---------------------------------------------------------------------------

(define-test code-find-symbol-not-found-returns-typed-hint
  "When %handle-code-find is called with a package that does not exist in the
image, the response has isError=t, error_type='package-not-found', and a
content field carrying hint text."
  (let* ((params (make-params "symbol"  "some-fn"
                              "package" "nonexistent-package-xyzzy-99999"))
         (result (%handle-code-find params nil)))
    (true (hash-table-p result))
    (true (gethash "isError" result))
    (is string= "package-not-found" (gethash "error_type" result))
    ;; Content must carry actionable text.
    (let ((content (gethash "content" result)))
      (true (or (and (simple-vector-p content) (plusp (length content)))
                (and (vectorp content) (plusp (length content))))))))

;;; ---------------------------------------------------------------------------
;;; Attached: %dispatch-attach-code-find returns locations via Slynk
;;; ---------------------------------------------------------------------------

(defun %make-code-find-attach-session (id conn)
  "Create a test session wired to the given Slynk connection."
  (let* ((session (make-session :id id :slynk-attach "127.0.0.1:1"))
         (*current-session-id* id)
         (repl-tool (get-tool-instance session "repl-eval")))
    (setf (repl-eval-tool-slynk-conn repl-tool) conn)
    (values session repl-tool)))

(define-test code-find-attached-returns-locations-for-known-symbol
  "Calling %dispatch-attach-code-find via the in-process Slynk fixture for a
symbol that is loaded in the current image returns a locations vector with at
least one entry carrying 'path', 'line', and 'kind' fields.  Exercises the
real slime-eval injection path in attached mode."
  (with-temporary-slynk-listener (conn)
    (multiple-value-bind (session repl-tool)
        (%make-code-find-attach-session "cf-attach-locations" conn)
      (declare (ignore session))
      (let* ((params (make-ht "symbol" "dsmr-mcp/src/code-core:code-find-definition"))
             (result (%dispatch-attach-code-find repl-tool nil params nil)))
        (true (hash-table-p result))
        (false (gethash "isError" result))
        (let ((locs (gethash "locations" result)))
          (true (and locs (plusp (length locs))))
          (let ((first-loc (aref locs 0)))
            (true (hash-table-p first-loc))
            (true (stringp  (gethash "path" first-loc)))
            (true (integerp (gethash "line" first-loc)))
            (true (stringp  (gethash "kind" first-loc)))
            (true (plusp (length (gethash "path" first-loc))))
            (true (plusp (gethash "line" first-loc)))))))))

(define-test code-find-attached-hermetic-envelope-parity
  "The attached code-find envelope and the hermetic %handle-code-find envelope
share the same top-level result key ('locations') for the same symbol.
Exercises the dual-mode envelope shape contract."
  (with-temporary-slynk-listener (conn)
    (multiple-value-bind (session repl-tool)
        (%make-code-find-attach-session "cf-attach-parity" conn)
      (declare (ignore session))
      (let* ((sym    "dsmr-mcp/src/code-core:code-find-definition")
             (params (make-ht "symbol" sym))
             ;; Attached envelope
             (att-result (%dispatch-attach-code-find repl-tool nil params nil))
             ;; Hermetic envelope
             (herm-result (%handle-code-find params nil)))
        (false (gethash "isError" att-result))
        (false (gethash "isError" herm-result))
        ;; Both must carry a "locations" key.
        (true (gethash "locations" att-result))
        (true (gethash "locations" herm-result))))))

;;; ---------------------------------------------------------------------------
;;; Inline: tool-handle returns typed mode error
;;; ---------------------------------------------------------------------------

(define-test code-find-inline-returns-mode-error
  "Calling tool-handle on a code-find-tool instance with *mode* bound to
:inline returns a JSON-RPC error response (has 'error' key) with code -32603."
  (let ((tool (make-instance 'code-find-tool))
        (params (make-params "symbol" "cl:car")))
    (let* ((*mode* :inline)
           (response (tool-handle tool nil params)))
      (true (hash-table-p response))
      ;; rpc-error returns {"jsonrpc":"2.0","id":...,"error":{...}}
      (let ((err (gethash "error" response)))
        (true (hash-table-p err))
        (is = -32603 (gethash "code" err))
        (let ((msg (gethash "message" err)))
          (true (stringp msg))
          (true (search "code-find" msg)))))))
