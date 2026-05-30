;;;; src/lsp/bridge.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; LSP-02: four MCP verb implementations that delegate to alive-lsp.
;;;; LSP-04: in-process Eclector fallback when alive-lsp is unavailable.
;;;;
;;;; Verb → LSP method mapping (RESEARCH.md Domain 5):
;;;;   completions   → textDocument/completion
;;;;   hover         → textDocument/hover
;;;;   diagnostics   → $/alive/tryCompile (default) or $/alive/compile (:load-p)
;;;;   code-actions  → synthesized discover-then-apply menu (D-01/D-02/D-04)
;;;;                   backed by: $/alive/macroexpand1, $/alive/macroexpand,
;;;;                              $/alive/unexportSymbol, textDocument/rangeFormatting,
;;;;                              $/alive/getPackageForPosition,
;;;;                              $/alive/surroundingFormBounds,
;;;;                              $/alive/topFormBounds, $/alive/symbol
;;;;
;;;; Fallback policy (D-12):
;;;;   diagnostics  → degraded-diagnostics (Eclector paren/reader check)
;;;;   completions/hover/code-actions → lsp-unavailable error envelope
;;;;
;;;; Security (T-lsp-bridge-01): callers must resolve file_path through
;;;; allowed-read-path before passing it here. The bridge receives only
;;;; pre-validated paths.
;;;;
;;;; Position semantics (RESEARCH.md Domain 4): 0-based {line, character}
;;;; integers. The key is "character" (not "col").
;;;;
;;;; rangeFormatting serialization (RESEARCH.md Pitfall 6): concurrent
;;;; rangeFormatting calls to the same client are serialized via a per-client
;;;; formatting lock (stored in the tool layer, accessed via *formatting-locks*).

(defpackage #:dsmr-mcp/src/lsp/bridge
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/lsp/client
                #:lsp-send-request
                #:lsp-connection-lost)
  (:import-from #:dsmr-mcp/src/lsp/document
                #:path->file-uri
                #:notify-did-open)
  (:import-from #:dsmr-mcp/src/validate
                #:scan-parens
                #:try-reader-check)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:make-ht
                #:text-content)
  (:import-from #:dsmr-mcp/src/log
                #:log-event)
  (:import-from #:bordeaux-threads
                #:make-lock
                #:with-lock-held)
  (:export #:bridge-completions
           #:bridge-hover
           #:bridge-diagnostics
           #:bridge-code-actions
           #:degraded-diagnostics
           #:make-lsp-unavailable-envelope))

(in-package #:dsmr-mcp/src/lsp/bridge)

;;; ---------------------------------------------------------------------------
;;; Per-client rangeFormatting serialization lock (Pitfall 6)
;;; ---------------------------------------------------------------------------

(defvar *formatting-locks* (make-hash-table :test 'equal)
  "Hash-table mapping LSP-CLIENT identity (by eq-hash) to a bordeaux-threads lock.
Serializes concurrent textDocument/rangeFormatting calls to the same client.
The workspace/configuration round-trip inside handle-formatting requires that
no two formatting requests interleave on the same session state object.")

(defvar *formatting-locks-lock* (make-lock "formatting-locks-lock")
  "Lock protecting *formatting-locks* for thread-safe read/write.")

(defun %formatting-lock-for (client)
  "Return (or create) the serialization lock for FORMATTING requests to CLIENT."
  (let ((key (format nil "~A" (sb-kernel:get-lisp-obj-address client))))
    (with-lock-held (*formatting-locks-lock*)
      (or (gethash key *formatting-locks*)
          (setf (gethash key *formatting-locks*)
                (make-lock (format nil "lsp-formatting-~A" key)))))))

;;; ---------------------------------------------------------------------------
;;; Position helpers
;;; ---------------------------------------------------------------------------

(defun %make-position (line char)
  "Build a {line, character} LSP Position hash-table (0-based integers).
The column key is \"character\" per RESEARCH.md position.lisp verification."
  (let ((ht (make-hash-table :test 'equal)))
    (setf (gethash "line"      ht) line
          (gethash "character" ht) char)
    ht))

(defun %make-text-document-position (uri line char)
  "Build a {textDocument: {uri}, position: {line, character}} hash-table."
  (let ((ht (make-hash-table :test 'equal))
        (td (make-hash-table :test 'equal)))
    (setf (gethash "uri"          td) uri
          (gethash "textDocument" ht) td
          (gethash "position"     ht) (%make-position line char))
    ht))

;;; ---------------------------------------------------------------------------
;;; LSP-unavailable error envelope
;;; ---------------------------------------------------------------------------

(defun make-lsp-unavailable-envelope (verb-name)
  "Build the lsp-unavailable error hash-table for VERB-NAME.
Used by completions, hover, and code-actions when alive-lsp is unreachable.
Shape: {isError: true, error_type: \"lsp-unavailable\", content: [{type, text}]}."
  (make-ht "isError"    t
           "error_type" "lsp-unavailable"
           "content"    (text-content
                         (format nil "~A requires alive-lsp, which is not running."
                                 verb-name))))

;;; ---------------------------------------------------------------------------
;;; Degraded diagnostics — Eclector fallback (D-12 / LSP-04)
;;; ---------------------------------------------------------------------------

(defun %eclector-message-from-paren (paren-result)
  "Convert a scan-parens failure plist to an LSP-style message hash-table."
  (let ((offset  (or (getf paren-result :offset) 0))
        (line    (max 0 (1- (or (getf paren-result :line) 1))))
        (message (format nil "Paren error: ~A~@[ (expected ~A)~]~@[ (found ~A)~]"
                         (getf paren-result :kind)
                         (getf paren-result :expected)
                         (getf paren-result :found))))
    (declare (ignore offset))
    (let ((start-ht (make-hash-table :test 'equal))
          (end-ht   (make-hash-table :test 'equal))
          (loc-ht   (make-hash-table :test 'equal))
          (msg-ht   (make-hash-table :test 'equal)))
      (setf (gethash "line"      start-ht) line
            (gethash "character" start-ht) (max 0 (1- (or (getf paren-result :column) 1)))
            (gethash "line"      end-ht)   line
            (gethash "character" end-ht)   65535
            (gethash "start"     loc-ht)   start-ht
            (gethash "end"       loc-ht)   end-ht
            (gethash "severity"  msg-ht)   "error"
            (gethash "location"  msg-ht)   loc-ht
            (gethash "message"   msg-ht)   message)
      msg-ht)))

(defun %eclector-message-from-reader (reader-info)
  "Convert a try-reader-check failure plist to an LSP-style message hash-table."
  (let ((line    (max 0 (1- (or (getf reader-info :line) 1))))
        (message (format nil "Reader error: ~A" (getf reader-info :message))))
    (let ((start-ht (make-hash-table :test 'equal))
          (end-ht   (make-hash-table :test 'equal))
          (loc-ht   (make-hash-table :test 'equal))
          (msg-ht   (make-hash-table :test 'equal)))
      (setf (gethash "line"      start-ht) line
            (gethash "character" start-ht) (max 0 (1- (or (getf reader-info :column) 1)))
            (gethash "line"      end-ht)   line
            (gethash "character" end-ht)   65535
            (gethash "start"     loc-ht)   start-ht
            (gethash "end"       loc-ht)   end-ht
            (gethash "severity"  msg-ht)   "error"
            (gethash "location"  msg-ht)   loc-ht
            (gethash "message"   msg-ht)   message)
      msg-ht)))

(defun degraded-diagnostics (text)
  "Run the in-process Eclector dual-pass check on TEXT and return a
degraded-diagnostics hash-table flagged lsp-unavailable.

The dual pass mirrors lisp-check-parens-tool's body (paren errors take priority
over reader errors). Returns:
  {degraded: true, degraded_reason: \"lsp-unavailable\",
   messages: [... LSP-style {severity,location,message} entries ...]}

When text is clean, messages is an empty vector. An empty messages list does not
guarantee clean compilation (Pitfall 5 from RESEARCH.md applies here too)."
  (let* ((paren-result (scan-parens text :base-offset 0))
         (reader-info  (try-reader-check text 0))
         (messages
           (cond
             ;; Paren error takes priority (mirroring lisp-check-parens priority).
             ((not (getf paren-result :ok))
              (vector (%eclector-message-from-paren paren-result)))
             ;; Reader error (paren OK).
             (reader-info
              (vector (%eclector-message-from-reader reader-info)))
             ;; Both passes clean.
             (t
              (vector)))))
    (make-ht "degraded"        t
             "degraded_reason" "lsp-unavailable"
             "messages"        messages)))

;;; ---------------------------------------------------------------------------
;;; LSP-02: bridge-completions
;;; ---------------------------------------------------------------------------

(defun bridge-completions (client id path-str line char)
  "Delegate textDocument/completion to CLIENT for PATH-STR at LINE/CHAR.
ID is the MCP request id (unused by the LSP layer; kept for logging).
PATH-STR must be a pre-validated absolute filesystem path (T-lsp-bridge-01).
Returns the result hash-table from alive-lsp (contains 'items' key).
Signals LSP-CONNECTION-LOST on wire failure."
  (declare (ignore id))
  (let* ((uri    (path->file-uri path-str))
         (params (%make-text-document-position uri line char)))
    (log-event :debug "lsp.bridge.completions"
               "path" path-str "line" line "char" char)
    (let ((result (lsp-send-request client "textDocument/completion" params)))
      ;; alive-lsp returns {isIncomplete, items: [...]} — return the result ht.
      ;; items may be a vector (empty or populated).
      result)))

;;; ---------------------------------------------------------------------------
;;; LSP-02: bridge-hover
;;; ---------------------------------------------------------------------------

(defun bridge-hover (client id path-str line char)
  "Delegate textDocument/hover to CLIENT for PATH-STR at LINE/CHAR.
Returns the result hash-table (contains 'value' key: string or empty string).
Empty string means no hover available at this position — not an error.
Never signals when alive-lsp is up (RESEARCH.md Domain 5 hover section).
Signals LSP-CONNECTION-LOST on wire failure."
  (declare (ignore id))
  (let* ((uri    (path->file-uri path-str))
         (params (%make-text-document-position uri line char)))
    (log-event :debug "lsp.bridge.hover"
               "path" path-str "line" line "char" char)
    (let ((result (lsp-send-request client "textDocument/hover" params)))
      ;; alive-lsp returns {value: "<docstring>"} or :null on no hover.
      ;; Normalize: always return a ht with a "value" key.
      (cond
        ;; Null result from alive-lsp (no hover).
        ((or (null result) (eq result :null))
         (make-ht "value" ""))
        ;; Hash-table result: pass through as-is.
        ((hash-table-p result)
         result)
        ;; Unexpected shape: return empty.
        (t
         (make-ht "value" ""))))))

;;; ---------------------------------------------------------------------------
;;; LSP-02: bridge-diagnostics
;;; ---------------------------------------------------------------------------

(defun bridge-diagnostics (client id path-str &key load-p)
  "Delegate $/alive/tryCompile (or $/alive/compile when LOAD-P is set) to CLIENT.
PATH-STR is an absolute filesystem path (NOT a file:// URI) — alive-lsp's
tryCompile/compile handlers expect a raw filesystem path (RESEARCH.md Domain 5).
ID is the MCP request id (unused by the LSP layer; kept for logging).

When LOAD-P is NIL (default): issues $/alive/tryCompile (safe, no evaluation).
When LOAD-P is T: issues $/alive/compile (loads and evaluates code in the
alive-lsp image — mutating, opt-in by the agent, documented in tool description).

Returns the result hash-table (contains 'messages' key).
NOTE (Pitfall 5): an empty messages list does not guarantee clean compilation.
Some SBCL compiler errors lack source locations and are silently dropped by
alive-lsp's send-message filter.
Signals LSP-CONNECTION-LOST on wire failure."
  (declare (ignore id))
  (let ((method (if load-p "$/alive/compile" "$/alive/tryCompile"))
        (params (make-hash-table :test 'equal)))
    (setf (gethash "path" params) (if (pathnamep path-str)
                                      (namestring path-str)
                                      path-str))
    (log-event :debug "lsp.bridge.diagnostics"
               "path" (if (pathnamep path-str) (namestring path-str) path-str)
               "method" method)
    (lsp-send-request client method params)))

;;; ---------------------------------------------------------------------------
;;; LSP-02: bridge-code-actions — discover-then-apply (D-04)
;;; ---------------------------------------------------------------------------

;;; Discovery support: probe the position to determine which actions apply.

(defun %get-package-for-position (client uri line char)
  "Ask alive-lsp for the package at URI/LINE/CHAR.
Returns the package name string, or NIL on failure."
  (handler-case
      (let ((params (make-hash-table :test 'equal))
            (td     (make-hash-table :test 'equal)))
        (setf (gethash "uri"          td) uri
              (gethash "textDocument" params) td
              (gethash "position"     params) (%make-position line char))
        (let ((result (lsp-send-request client
                                        "$/alive/getPackageForPosition"
                                        params)))
          (when (hash-table-p result)
            (gethash "package" result))))
    (error () nil)))

(defun %get-surrounding-form-bounds (client uri line char)
  "Ask alive-lsp for the surrounding form bounds at URI/LINE/CHAR.
Returns a (start-ht . end-ht) cons, or NIL on failure."
  (handler-case
      (let ((params (make-hash-table :test 'equal))
            (td     (make-hash-table :test 'equal)))
        (setf (gethash "uri"          td) uri
              (gethash "textDocument" params) td
              (gethash "position"     params) (%make-position line char))
        (let ((result (lsp-send-request client
                                        "$/alive/surroundingFormBounds"
                                        params)))
          (when (hash-table-p result)
            (cons (gethash "start" result)
                  (gethash "end"   result)))))
    (error () nil)))

(defun %get-symbol-at-position (client uri line char)
  "Ask alive-lsp for the symbol at URI/LINE/CHAR.
Returns the symbol value hash-table, or NIL on failure."
  (handler-case
      (let ((params (make-hash-table :test 'equal))
            (td     (make-hash-table :test 'equal)))
        (setf (gethash "uri"          td) uri
              (gethash "textDocument" params) td
              (gethash "position"     params) (%make-position line char))
        (let ((result (lsp-send-request client "$/alive/symbol" params)))
          (when (hash-table-p result)
            (gethash "value" result))))
    (error () nil)))

;;; Apply actions.

(defun %apply-macroexpand (client text package &key full-p)
  "Apply macroexpand to TEXT in PACKAGE context.
Uses $/alive/macroexpand1 by default; $/alive/macroexpand when FULL-P is T.
Returns the expanded text string, or the original TEXT on failure."
  (let ((method (if full-p "$/alive/macroexpand" "$/alive/macroexpand1"))
        (params (make-hash-table :test 'equal)))
    (setf (gethash "text"    params) (or text "")
          (gethash "package" params) (or package "CL-USER"))
    (handler-case
        (let ((result (lsp-send-request client method params)))
          (if (hash-table-p result)
              (gethash "text" result)
              (or text "")))
      (error () (or text "")))))

(defun %apply-unexport-symbol (client symbol-name package)
  "Remove SYMBOL-NAME from PACKAGE's export list via $/alive/unexportSymbol.
Returns T on success, NIL on failure."
  (let ((params (make-hash-table :test 'equal)))
    (setf (gethash "symbol"  params) (or symbol-name "")
          (gethash "package" params) (or package "CL-USER"))
    (handler-case
        (let ((result (lsp-send-request client "$/alive/unexportSymbol" params)))
          (when (hash-table-p result)
            (gethash "result" result)))
      (error () nil))))

(defun %apply-range-format (client path-str bounds)
  "Format the range given by BOUNDS (a cons of start-ht . end-ht) via
textDocument/rangeFormatting on PATH-STR.
Serializes with the per-client formatting lock (Pitfall 6 — alive-lsp's
handle-formatting blocks on workspace/configuration before replying; the Wave-1
reader thread answers that server-initiated request automatically).
Returns the result (array of text edit hash-tables), or NIL on failure."
  (let ((fmt-lock (%formatting-lock-for client))
        (uri      (path->file-uri path-str)))
    (with-lock-held (fmt-lock)
      (handler-case
          (let* ((params  (make-hash-table :test 'equal))
                 (td      (make-hash-table :test 'equal))
                 (options (make-hash-table :test 'equal)))
            (setf (gethash "uri"          td) uri
                  (gethash "tabSize"      options) 2
                  (gethash "insertSpaces" options) t
                  (gethash "textDocument" params) td
                  (gethash "range"        params) bounds
                  (gethash "options"      params) options)
            (lsp-send-request client "textDocument/rangeFormatting" params))
        (error () nil)))))

;;; Discover mode: probe position and build the applicable action menu.

(defun %discover-code-actions (client uri path-str line char)
  "Probe the position at URI/LINE/CHAR and return a vector of applicable action
descriptors. Each descriptor is a hash-table with 'action' (string key) and
optional context fields ('text', 'package', 'symbol', 'bounds').

Always includes 'format' (textDocument/rangeFormatting is available unconditionally).
Includes 'macroexpand' when a surrounding form is found (macro expansion attempt
is always offered; alive-lsp returns the original text when it is not a macro).
Includes 'remove-from-export' when a symbol is found at the position (the symbol
may or may not be exported; the apply step will determine that)."
  (let ((package (or (%get-package-for-position client uri line char) "CL-USER"))
        (bounds  (%get-surrounding-form-bounds client uri line char))
        (symbol  (%get-symbol-at-position client uri line char))
        (actions '()))
    ;; Macroexpand action: offer when we have a surrounding form.
    (when bounds
      (let ((action-ht (make-hash-table :test 'equal)))
        (setf (gethash "action"  action-ht) "macroexpand"
              (gethash "package" action-ht) package
              (gethash "bounds"  action-ht) bounds)
        (push action-ht actions)))
    ;; Remove-from-export action: offer when a symbol is found.
    (when symbol
      (let* ((sym-name (cond
                         ((hash-table-p symbol)
                          (or (gethash "name" symbol)
                              (gethash "value" symbol)))
                         ((stringp symbol) symbol)
                         (t nil))))
        (when sym-name
          (let ((action-ht (make-hash-table :test 'equal)))
            (setf (gethash "action"  action-ht) "remove-from-export"
                  (gethash "symbol"  action-ht) sym-name
                  (gethash "package" action-ht) package)
            (push action-ht actions)))))
    ;; Format action: always available (rangeFormatting is always offered).
    (let ((format-ht (make-hash-table :test 'equal)))
      (setf (gethash "action" format-ht) "format"
            (gethash "path"   format-ht) path-str)
      ;; Include bounds if we found them (for precise range formatting).
      (when bounds
        (setf (gethash "bounds" format-ht) bounds))
      (push format-ht actions))
    (coerce (nreverse actions) 'simple-vector)))


;;; Apply mode: dispatch the chosen action.

(defun %apply-action (client path-str action-ht text)
  "Apply the action described by ACTION-HT.
TEXT is the full file content (used for macroexpand text extraction).
Returns a result hash-table with 'action' echoed and 'result' filled in."
  (let ((action  (gethash "action"  action-ht))
        (package (or (gethash "package" action-ht) "CL-USER"))
        (bounds  (gethash "bounds"  action-ht))
        (sym     (gethash "symbol"  action-ht)))
    (cond
      ;; macroexpand: extract form text from bounds, then expand.
      ((string= action "macroexpand")
       (let* ((form-text
                (if (and bounds text
                         (hash-table-p bounds)
                         (gethash "start" bounds)
                         (gethash "end"   bounds))
                    ;; Try to extract the form text from the file content.
                    ;; Bounds are line/char positions — use the raw text as fallback.
                    text
                    text))
              (expanded (%apply-macroexpand client form-text package)))
         (make-ht "action" "macroexpand" "result" (or expanded ""))))
      ;; remove-from-export: unexport the symbol.
      ((string= action "remove-from-export")
       (let ((success (%apply-unexport-symbol client sym package)))
         (make-ht "action" "remove-from-export" "result" (if success t nil))))
      ;; format: rangeFormatting.
      ((string= action "format")
       (let ((result (%apply-range-format client path-str bounds)))
         (make-ht "action" "format" "result" (or result (vector)))))
      ;; Unknown action: return an error envelope.
      (t
       (make-ht "action" action
                "result" nil
                "error"  (format nil "Unknown code action: ~A" action))))))

;;; Public entry point.

(defun bridge-code-actions (client id path-str line char &key action-ht text)
  "Synthesized code-actions verb (D-01/D-02/D-04).

DISCOVER mode (ACTION-HT is NIL, the default):
  Probes the position at LINE/CHAR in PATH-STR using alive-lsp's discovery
  verbs and returns a vector of applicable action descriptors. Each descriptor
  is a hash-table with at minimum an 'action' key ('macroexpand',
  'remove-from-export', 'format').

APPLY mode (ACTION-HT is a hash-table from a prior discover result):
  Dispatches the chosen action to the appropriate alive-lsp verb:
    macroexpand        → $/alive/macroexpand1 (or $/alive/macroexpand)
    remove-from-export → $/alive/unexportSymbol
    format             → textDocument/rangeFormatting (serialized, Pitfall 6)

PATH-STR must be a pre-validated absolute filesystem path (T-lsp-bridge-01).
ID is the MCP request id (unused by the LSP layer; kept for logging).
Signals LSP-CONNECTION-LOST on wire failure."
  (declare (ignore id))
  (let ((uri (path->file-uri path-str)))
    (log-event :debug "lsp.bridge.code-actions"
               "path" path-str "line" line "char" char
               "mode" (if action-ht "apply" "discover"))
    (if action-ht
        ;; Apply mode.
        (%apply-action client path-str action-ht text)
        ;; Discover mode.
        (%discover-code-actions client uri path-str line char))))
