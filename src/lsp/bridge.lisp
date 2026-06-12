;;;; src/lsp/bridge.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; LSP-02: four MCP verb implementations that delegate to alive-lsp.
;;;; LSP-04: in-process Eclector fallback when alive-lsp is unavailable.
;;;;
;;;; Verb → LSP method mapping:
;;;;   completions   → textDocument/completion
;;;;   hover         → textDocument/hover
;;;;   diagnostics   → $/alive/tryCompile (default) or $/alive/compile (:load-p)
;;;;   code-actions  → synthesized discover-then-apply menu
;;;;                   backed by: $/alive/macroexpand1, $/alive/macroexpand,
;;;;                              $/alive/unexportSymbol, textDocument/rangeFormatting,
;;;;                              $/alive/getPackageForPosition,
;;;;                              $/alive/surroundingFormBounds,
;;;;                              $/alive/topFormBounds, $/alive/symbol
;;;;
;;;; Fallback policy: when alive-lsp is unavailable —
;;;;   diagnostics  → degraded-diagnostics (Eclector paren/reader check)
;;;;   completions/hover/code-actions → lsp-unavailable error envelope
;;;;
;;;; Security: callers must resolve file_path through allowed-read-path before
;;;; passing it here. The bridge receives only pre-validated paths.
;;;;
;;;; Position semantics: 0-based {line, character} integers.
;;;; The column key is "character" (not "col") — this matches the LSP spec and
;;;; alive-lsp's own position structures.
;;;;
;;;; rangeFormatting serialization: concurrent rangeFormatting calls to the same
;;;; client are serialized via a per-client formatting lock in *formatting-locks*.
;;;; alive-lsp's handle-formatting blocks on a workspace/configuration round-trip
;;;; before replying; the reader thread answers that server-initiated request
;;;; automatically, but interleaving two formatting requests on the same session
;;;; state object corrupts the sequence.

(defpackage #:dsmr-mcp/src/lsp/bridge
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/lsp/client
                #:lsp-send-request
                #:lsp-send-notification
                #:lsp-client-project-root
                #:lsp-client-opened-uris
                #:lsp-client-opened-uris-lock
                #:lsp-connection-lost
                #:bump-uri-version)
  (:import-from #:dsmr-mcp/src/lsp/document
                #:path->file-uri)
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
           #:make-lsp-unavailable-envelope
           #:add-lsp-result-summary
           #:%remove-formatting-lock))

(in-package #:dsmr-mcp/src/lsp/bridge)

;;; ---------------------------------------------------------------------------
;;; Per-client rangeFormatting serialization lock: alive-lsp's formatting
;;; path makes a blocking workspace/configuration round-trip, so concurrent
;;; format calls against one client must be serialized.
;;; ---------------------------------------------------------------------------

(defvar *formatting-locks* (make-hash-table :test 'equal)
  "Hash-table mapping LSP-CLIENT project-root string to a bordeaux-threads lock.
Serializes concurrent textDocument/rangeFormatting calls to the same client.
alive-lsp's handle-formatting blocks on a workspace/configuration round-trip
before replying; interleaving two formatting requests on the same session state
object corrupts the sequence.  Keyed by project-root (a portable, stable string)
rather than object address so the key survives GC and is CL-implementation neutral.")

(defvar *formatting-locks-lock* (make-lock "formatting-locks-lock")
  "Lock protecting *formatting-locks* for thread-safe read/write.")

(defun %formatting-lock-for (client)
  "Return (or create) the serialization lock for rangeFormatting requests to CLIENT.
Keyed by the client's project-root string so the lock is stable across GC and
portable across CL implementations."
  (let ((key (let ((root (lsp-client-project-root client)))
               (if root (namestring root) ""))))
    (with-lock-held (*formatting-locks-lock*)
      (or (gethash key *formatting-locks*)
          (setf (gethash key *formatting-locks*)
                (make-lock (format nil "lsp-formatting-~A" key)))))))

(defun %remove-formatting-lock (client)
  "Remove the rangeFormatting serialization lock for CLIENT from *formatting-locks*.
Called when a client is evicted or shut down to prevent the table growing without
bound across the server's lifetime."
  (let ((key (let ((root (lsp-client-project-root client)))
               (if root (namestring root) ""))))
    (with-lock-held (*formatting-locks-lock*)
      (remhash key *formatting-locks*))))

;;; ---------------------------------------------------------------------------
;;; Position helpers
;;; ---------------------------------------------------------------------------

(defun %make-position (line char)
  "Build a {line, character} LSP Position hash-table (0-based integers).
The column key is \"character\" per the LSP spec and alive-lsp's own
position handling."
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
;;; Result-content summaries
;;; ---------------------------------------------------------------------------

(defun %first-labels (items key cap)
  "Collect up to CAP values of KEY from the ITEMS vector/list of hash-tables."
  (let ((acc nil) (n 0))
    (map nil (lambda (item)
               (when (and (< n cap) (hash-table-p item))
                 (let ((v (gethash key item)))
                   (when (stringp v)
                     (push v acc)
                     (incf n)))))
         items)
    (nreverse acc)))

(defun add-lsp-result-summary (payload verb)
  "Attach a content text block to an LSP bridge result PAYLOAD.
The client renders a tools/call result through its content block alone; the
bridge results carry only structured fields from alive-lsp. VERB selects the
summary shape. A non-hash PAYLOAD (code-actions discover mode returns a bare
descriptor vector) is wrapped into a hash-table first — a JSON-RPC result
must be an object to carry content at all. Returns the (possibly new)
payload hash-table; error envelopes pass through untouched."
  (when (and (hash-table-p payload) (gethash "isError" payload))
    (return-from add-lsp-result-summary payload))
  (let ((ht (if (hash-table-p payload)
                payload
                (make-ht "actions" payload))))
    (unless (nth-value 1 (gethash "content" ht))
      (setf (gethash "content" ht)
            (text-content
             (cond
               ((string= verb "hover")
                (let ((value (gethash "value" ht)))
                  (if (and (stringp value) (plusp (length value)))
                      value
                      "(no hover info at this position)")))
               ((string= verb "completions")
                (let ((items (gethash "items" ht)))
                  (if (and items (plusp (length items)))
                      (format nil "~D completion~:P: ~{~A~^, ~}~
                                   ~[~:; (+~:*~D more)~]"
                              (length items)
                              (%first-labels items "label" 8)
                              (max 0 (- (length items) 8)))
                      "no completions at this position")))
               ((string= verb "diagnostics")
                (let ((messages (gethash "messages" ht))
                      (degraded (gethash "degraded" ht)))
                  (if (and messages (plusp (length messages)))
                      (format nil "~D diagnostic~:P~@[ (degraded: Eclector ~
                                   structural check only)~]: ~{~A~^; ~}~
                                   ~[~:; (+~:*~D more)~]"
                              (length messages)
                              degraded
                              (%first-labels messages "message" 3)
                              (max 0 (- (length messages) 3)))
                      (format nil "no diagnostics~@[ (degraded: Eclector ~
                                   structural check only)~]"
                              degraded))))
               ((string= verb "code-actions")
                (let ((actions (gethash "actions" ht)))
                  (if actions
                      ;; Discover mode (wrapped vector of descriptors).
                      (if (plusp (length actions))
                          (format nil "~D applicable action~:P: ~{~A~^, ~}"
                                  (length actions)
                                  (%first-labels actions "action" 8))
                          "no applicable actions at this position")
                      ;; Apply mode: action echoed alongside its result.
                      (format nil "applied ~A"
                              (or (gethash "action" ht) "action")))))
               (t "(structured result)")))))
    ht))

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
guarantee clean compilation — alive-lsp catches SBCL errors with source locations;
this fallback catches only structural paren/reader issues."
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
;;; Document-open sync — ensure alive-lsp has the current file buffer
;;; ---------------------------------------------------------------------------

(defun %ensure-document-open (client uri path-str)
  "Ensure alive-lsp has an up-to-date in-memory buffer for URI/PATH-STR.

Reads PATH-STR from disk and sends textDocument/didOpen on the first call for
this URI, so alive-lsp allocates a buffer.  Sends textDocument/didChange on
subsequent calls so the buffer reflects current on-disk state.

alive-lsp's completion and hover handlers operate on their in-memory buffer,
not the filesystem.  A URI never opened returns empty results.  The diagnostics
path ($/alive/tryCompile) reads from disk and does not need this priming;
position-based verbs do.

Best-effort: any error (missing file, notification failure) is silently ignored
so the bridge still attempts the LSP request with whatever state the server has."
  (ignore-errors
    (let ((text (uiop:read-file-string path-str)))
      (unless (stringp text) (return-from %ensure-document-open nil))
      (with-lock-held ((lsp-client-opened-uris-lock client))
        (if (gethash uri (lsp-client-opened-uris client))
            ;; Already opened — send didChange with a bumped version.
            (let* ((version (bump-uri-version client uri))
                   (params  (make-hash-table :test 'equal))
                   (doc     (make-hash-table :test 'equal))
                   (change  (make-hash-table :test 'equal)))
              (setf (gethash "uri"            doc)    uri
                    (gethash "version"        doc)    version
                    (gethash "text"           change) text
                    (gethash "textDocument"   params) doc
                    (gethash "contentChanges" params) (vector change))
              (lsp-send-notification client "textDocument/didChange" params)
              (log-event :debug "lsp.bridge.did-change" "uri" uri "version" version))
            ;; First time — send didOpen.
            (let ((params (make-hash-table :test 'equal))
                  (doc    (make-hash-table :test 'equal)))
              (setf (gethash "uri"          doc)    uri
                    (gethash "languageId"   doc)    "lisp"
                    (gethash "version"      doc)    1
                    (gethash "text"         doc)    text
                    (gethash "textDocument" params) doc)
              (lsp-send-notification client "textDocument/didOpen" params)
              (setf (gethash uri (lsp-client-opened-uris client)) t)
              (log-event :debug "lsp.bridge.did-open" "uri" uri))))))
  nil)

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
    ;; Ensure alive-lsp has the file's current text before requesting completions.
    ;; alive-lsp's completion handler reads from its in-memory buffer; a URI
    ;; that was never opened returns an empty items list.
    (%ensure-document-open client uri path-str)
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
Never signals when alive-lsp is up (alive-lsp returns :null rather than an
error when there is no hover at a given position).
Signals LSP-CONNECTION-LOST on wire failure."
  (declare (ignore id))
  (let* ((uri    (path->file-uri path-str))
         (params (%make-text-document-position uri line char)))
    ;; Ensure alive-lsp has the file's current text before requesting hover.
    (%ensure-document-open client uri path-str)
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
tryCompile/compile handlers expect a raw filesystem path, not a URI.
ID is the MCP request id (unused by the LSP layer; kept for logging).

When LOAD-P is NIL (default): issues $/alive/tryCompile (safe, no evaluation).
When LOAD-P is T: issues $/alive/compile (loads and evaluates code in the
alive-lsp image — mutating, opt-in by the agent, documented in tool description).

Returns the result hash-table (contains 'messages' key).
NOTE: an empty messages list does not guarantee clean compilation — some SBCL
compiler errors lack source locations and are silently dropped by alive-lsp's
send-message filter.
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

;;; Helpers for CR-01: extract the form text covered by LSP bounds.

(defun %lsp-position-to-offset (text line char)
  "Convert a 0-based {line, char} LSP position to a character offset in TEXT.
Returns the character offset, or 0 on failure.
Scans TEXT line-by-line counting newlines to reach the target line, then adds
the character column.  Clips to the string length on out-of-range inputs."
  (let ((len (length text)))
    (if (zerop line)
        (min char len)
        (let ((current-line 0)
              (offset 0))
          (loop while (< offset len)
                do (let ((ch (char text offset)))
                     (incf offset)
                     (when (char= ch #\Newline)
                       (incf current-line)
                       (when (= current-line line)
                         (return-from %lsp-position-to-offset
                           (min (+ offset char) len))))))
          len))))

(defun %extract-form-text (text bounds)
  "Extract the substring of TEXT covered by BOUNDS (a cons of start-ht . end-ht).
Each position hash-table has integer 'line' and 'character' keys (0-based).
Returns the extracted substring, or NIL when bounds or text are invalid."
  (when (and text bounds (consp bounds))
    (let* ((start-ht (car bounds))
           (end-ht   (cdr bounds)))
      (when (and (hash-table-p start-ht) (hash-table-p end-ht))
        (let* ((sl (or (gethash "line"      start-ht) 0))
               (sc (or (gethash "character" start-ht) 0))
               (el (or (gethash "line"      end-ht)   0))
               (ec (or (gethash "character" end-ht)   0))
               (start-off (%lsp-position-to-offset text sl sc))
               (end-off   (%lsp-position-to-offset text el ec)))
          (when (and (<= start-off end-off) (<= end-off (length text)))
            (subseq text start-off end-off)))))))

(defun %apply-range-format (client path-str bounds)
  "Format the range given by BOUNDS (a cons of start-ht . end-ht) via
textDocument/rangeFormatting on PATH-STR.
BOUNDS must be a non-nil cons; returns NIL without calling the server when
BOUNDS is nil.
Serializes with the per-client formatting lock — alive-lsp's handle-formatting
blocks on workspace/configuration before replying; the reader thread answers
that server-initiated request automatically.
Returns the result (array of text edit hash-tables), or NIL on failure."
  (unless (consp bounds)
    (return-from %apply-range-format nil))
  (let ((fmt-lock (%formatting-lock-for client))
        (uri      (path->file-uri path-str)))
    (with-lock-held (fmt-lock)
      (handler-case
          (let* ((params  (make-hash-table :test 'equal))
                 (td      (make-hash-table :test 'equal))
                 (options (make-hash-table :test 'equal))
                 ;; Build a proper LSP Range object {start: ..., end: ...}.
                 ;; bounds is (start-ht . end-ht); passing the cons directly
                 ;; would serialize as a JSON array, not an object.
                 (range   (let ((ht (make-hash-table :test 'equal)))
                            (setf (gethash "start" ht) (car bounds)
                                  (gethash "end"   ht) (cdr bounds))
                            ht)))
            (setf (gethash "uri"          td) uri
                  (gethash "tabSize"      options) 2
                  (gethash "insertSpaces" options) t
                  (gethash "textDocument" params) td
                  (gethash "range"        params) range
                  (gethash "options"      params) options)
            (lsp-send-request client "textDocument/rangeFormatting" params))
        (error () nil)))))

;;; Discover mode: probe position and build the applicable action menu.

(defun %discover-code-actions (client uri path-str line char)
  "Probe the position at URI/LINE/CHAR and return a vector of applicable action
descriptors. Each descriptor is a hash-table with 'action' (string key) and
optional context fields ('text', 'package', 'symbol', 'bounds').

Includes 'macroexpand' when a surrounding form is found.
Includes 'format' when a surrounding form is found (rangeFormatting requires
a valid range; without bounds there is no form to format, so the action is
omitted rather than sending a null range).
Includes 'remove-from-export' when a symbol is found at the position."
  ;; Ensure alive-lsp has the file's current text before position probes.
  (%ensure-document-open client uri path-str)
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
    ;; Format action: only offered when bounds are available so that
    ;; %apply-range-format always receives a valid cons range.  A null
    ;; range would produce a protocol error from alive-lsp's rangeFormatting
    ;; handler which expects a proper LSP Range object.
    (when bounds
      (let ((format-ht (make-hash-table :test 'equal)))
        (setf (gethash "action" format-ht) "format"
              (gethash "path"   format-ht) path-str
              (gethash "bounds" format-ht) bounds)
        (push format-ht actions)))
    (coerce (nreverse actions) 'simple-vector)))

;;; Apply mode: dispatch the chosen action.

(defun %apply-action (client path-str action-ht text)
  "Apply the action described by ACTION-HT.
TEXT is the full file content (used for macroexpand form extraction).
Returns a result hash-table with 'action' echoed and 'result' filled in."
  (let ((action  (gethash "action"  action-ht))
        (package (or (gethash "package" action-ht) "CL-USER"))
        (bounds  (gethash "bounds"  action-ht))
        (sym     (gethash "symbol"  action-ht)))
    (cond
      ;; macroexpand: extract form text from bounds, then expand.
      ((string= action "macroexpand")
       (let* (;; Extract only the bounded form text; fall back to full text
              ;; only when bounds are absent (alive-lsp will handle gracefully).
              (form-text (or (%extract-form-text text bounds)
                             (or text "")))
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
    format             → textDocument/rangeFormatting (serialized per client)

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
