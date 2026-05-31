;;;; src/elicitation.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Server->client MCP elicitation plumbing: a server-initiated
;;;; `elicitation/create` request and the routing of the client's response
;;;; back to the blocked caller.
;;;;
;;;; The request/response round-trip mirrors src/lsp/client.lisp's proven
;;;; pending-request / condition-variable / id-correlation idiom, collapsed to
;;;; the single outstanding request the session holds in its
;;;; pending-elicitation slot. The roles are reversed relative to lsp/client:
;;;; here dsmr-mcp is the requester and the MCP client is the responder.
;;;;
;;;; Wire direction:
;;;;   request  (server->client): {"jsonrpc":"2.0","id":N,"method":"elicitation/create",
;;;;             "params":{"message":...,"requestedSchema":{flat primitive props}}}
;;;;   response (client->server): {"jsonrpc":"2.0","id":N,
;;;;             "result":{"action":"accept","content":{...}}}
;;;;             or {..,"result":{"action":"decline"}} / {..,"action":"cancel"}
;;;;
;;;; The response has an id and a result/error but NO method; protocol.lisp
;;;; recognises that shape via elicitation-response-message-p and hands it to
;;;; route-elicitation-response, which wakes the waiting caller.
;;;;
;;;; Trust boundary: the client's response is untrusted input.
;;;;   - route-elicitation-response drops any response whose id does not match
;;;;     the pending request id (spoof/replay guard), so a forged or replayed
;;;;     `accept` cannot satisfy a request that is not in flight.
;;;;   - send-elicitation-request's condition-wait is bounded by :timeout, so a
;;;;     client that never replies yields :timeout and frees the pending slot
;;;;     rather than pinning the caller.

(defpackage #:dsmr-mcp/src/elicitation
  (:use #:cl)
  (:local-nicknames (#:jzon #:com.inuoe.jzon))
  (:import-from #:bordeaux-threads
                #:make-condition-variable #:condition-wait #:condition-notify
                #:with-lock-held)
  (:import-from #:dsmr-mcp/src/state
                #:session-elicitation-id-counter
                #:session-elicitation-lock
                #:session-pending-elicitation)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:make-ht)
  (:import-from #:dsmr-mcp/src/log
                #:log-event)
  (:export #:send-elicitation-request
           #:route-elicitation-response
           #:elicitation-response-message-p))

(in-package #:dsmr-mcp/src/elicitation)

;;; ---------------------------------------------------------------------------
;;; Sentinel
;;; ---------------------------------------------------------------------------

;;; Distinguishes "the response has not been delivered yet" from a legitimate
;;; NIL result. Mirrors lsp/client's +pending-sentinel+.
(defvar +pending-sentinel+ '#:pending-sentinel
  "Initial value of a pending-elicitation cell's result field. While the cell
still holds this sentinel no response has arrived; a wait that finds it after
its bounded timeout treats the request as timed out.")

;;; ---------------------------------------------------------------------------
;;; Response-shape predicate
;;; ---------------------------------------------------------------------------

(defun elicitation-response-message-p (msg)
  "Return T when MSG is the client's response to a server-initiated request.

That shape is a hash-table carrying an `id` and either a `result` (even a JSON
null result) or an `error` key, and NO `method` key. A request always carries a
`method`; a notification carries a `method` and no `id`; only a response to a
server-initiated request has an id without a method. The `result` key is probed
with a private not-found marker so a genuine null result still counts as present
\(mirrors lsp/client's %result-key-present-p)."
  (and (hash-table-p msg)
       (let ((not-found '#:not-found))
         (and (not (eq (gethash "id" msg not-found) not-found))
              (eq (gethash "method" msg not-found) not-found)
              (or (not (eq (gethash "result" msg not-found) not-found))
                  (not (eq (gethash "error" msg not-found) not-found)))))))

;;; ---------------------------------------------------------------------------
;;; Action-string -> keyword
;;; ---------------------------------------------------------------------------

(defun %action-keyword (action)
  "Map an elicitation response ACTION string to its keyword.
\"accept\" -> :accept, \"decline\" -> :decline, anything else -> :cancel.
A missing or unrecognised action is treated as :cancel (the most conservative
outcome — no .envrc is written), matching the MCP elicitation action set."
  (cond ((and (stringp action) (string= action "accept"))  :accept)
        ((and (stringp action) (string= action "decline")) :decline)
        (t                                                  :cancel)))

;;; ---------------------------------------------------------------------------
;;; Request: send and block for the response
;;; ---------------------------------------------------------------------------

(defun send-elicitation-request (session out message requested-schema
                                 &key (timeout 30))
  "Send an `elicitation/create` request to the client over OUT and block until
the matching-id response arrives or TIMEOUT seconds elapse.

Returns (values ACTION CONTENT) where ACTION is one of :accept, :decline,
:cancel, or :timeout. CONTENT is the response's `content` hash-table on an
accept (the operator's submitted values), NIL otherwise.

SESSION supplies the per-session id counter, lock, and pending slot. MESSAGE is
the human-readable prompt string. REQUESTED-SCHEMA is the flat primitive-prop
JSON Schema hash-table the client renders into a form.

Mirrors lsp/client:lsp-send-request: allocate an id under the session lock,
register a (id cv cell) holder in the session's single pending slot, write the
request, then condition-wait while the cell still holds the sentinel. The cell
result and errorp are read under the lock so the write from
route-elicitation-response is fully visible. The pending slot is always cleared
before return."
  (let* ((id   (with-lock-held ((session-elicitation-lock session))
                 (incf (session-elicitation-id-counter session))))
         (cv   (make-condition-variable
                :name (format nil "elicit-~A" id)))
         ;; cell: (result errorp). Initial result is the sentinel so a timeout
         ;; (cell never written) is distinguishable from a delivered NIL.
         (cell (list +pending-sentinel+ nil))
         (req  (make-ht "jsonrpc" "2.0"
                        "id"      id
                        "method"  "elicitation/create"
                        "params"  (make-ht "message"         message
                                            "requestedSchema" requested-schema))))
    ;; Register the pending holder before writing the request, so a response
    ;; that races in immediately can find a matching id.
    (with-lock-held ((session-elicitation-lock session))
      (setf (session-pending-elicitation session) (list id cv cell)))
    (unwind-protect
         (progn
           ;; Write the request line. jzon:stringify produces a single line
           ;; (no :pretty), which the MCP stdio wire requires.
           (write-line (jzon:stringify req) out)
           (force-output out)
           (log-event :debug "elicitation.request.sent"
                      "id" id "message" message)
           (let ((value nil) (errorp nil))
             ;; Wait for route-elicitation-response to fill the cell, reading
             ;; value+errorp while still holding the lock so the notifier's
             ;; write is fully visible before release. condition-wait with a
             ;; :timeout returns NIL when the deadline elapses with no notify;
             ;; a single wait then a re-test of the cell distinguishes a real
             ;; delivery from a timeout (the cell still holding the sentinel).
             (with-lock-held ((session-elicitation-lock session))
               (when (eq (car cell) +pending-sentinel+)
                 (condition-wait cv (session-elicitation-lock session)
                                 :timeout timeout))
               (setf value  (car cell)
                     errorp (cadr cell)))
             (cond
               ;; Still the sentinel after the bounded wait: timed out.
               ((eq value +pending-sentinel+)
                (log-event :debug "elicitation.request.timeout" "id" id)
                (values :timeout nil))
               ;; Error cell: the response carried a JSON-RPC error object.
               (errorp
                (log-event :debug "elicitation.request.error" "id" id)
                (values :cancel nil))
               ;; Success: VALUE is the response `result` hash-table.
               (t
                (let* ((result value)
                       (action (and (hash-table-p result)
                                    (gethash "action" result)))
                       (kw     (%action-keyword action)))
                  (values kw
                          (and (eq kw :accept)
                               (hash-table-p result)
                               (gethash "content" result))))))))
      ;; Always clear the pending slot, whether we returned a value, timed out,
      ;; or unwound on a non-local exit.
      (with-lock-held ((session-elicitation-lock session))
        (setf (session-pending-elicitation session) nil)))))

;;; ---------------------------------------------------------------------------
;;; Response: route a client reply to the waiting caller
;;; ---------------------------------------------------------------------------

(defun route-elicitation-response (session msg)
  "Route the client's elicitation response MSG to the caller blocked in
send-elicitation-request.

MSG is a response-shaped hash-table (id, result-or-error, no method). Under the
session lock, fetch the single pending holder; if its id does NOT equal the
response id, log a debug line and return NIL without notifying anyone — this is
the spoof/replay guard: a forged or replayed response cannot satisfy a request
that is not the one in flight. On a matching id, store the response `result`
\(or an error marker when the response carried `error`) into the holder's cell,
mark errorp accordingly, and condition-notify the waiting caller. Returns T on a
matched-and-notified response, NIL otherwise."
  (let ((response-id (gethash "id" msg)))
    (with-lock-held ((session-elicitation-lock session))
      (let ((pending (session-pending-elicitation session)))
        (if (and pending
                 (eql (first pending) response-id))
            (let* ((cv   (second pending))
                   (cell (third pending))
                   (errp (nth-value 1 (gethash "error" msg)))
                   (errv (gethash "error" msg)))
              (if errp
                  (setf (car cell) errv
                        (cadr cell) t)
                  (setf (car cell) (gethash "result" msg)
                        (cadr cell) nil))
              (condition-notify cv)
              (log-event :debug "elicitation.response.routed" "id" response-id)
              t)
            (progn
              (log-event :debug "elicitation.response.unmatched"
                         "response-id" response-id
                         "pending-id" (and pending (first pending)))
              nil))))))
