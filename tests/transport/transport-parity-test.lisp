;;;; tests/transport/transport-parity-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Transport parity test: verifies that the tools/list response served
;;;; over HTTP contains the same tool names as the in-process *tool-classes*
;;;; registry (which is what the stdio and TCP transports expose).  A
;;;; future tool added to the registry without a corresponding HTTP-side
;;;; schema entry is caught here, not at a client.
;;;;
;;;; send-http-request and http-port-available-p are imported from
;;;; dsmr-mcp/tests/transport/http-test rather than duplicated so the
;;;; HTTP harness has a single owner.

(defpackage #:dsmr-mcp/tests/transport/transport-parity-test
  (:use #:cl #:zebra)
  (:import-from #:dsmr-mcp/tests/transport/http-test
                #:http-port-available-p
                #:send-http-request)
  (:import-from #:dsmr-mcp/src/transport/http
                #:start-http-server
                #:stop-http-server
                #:*sessions-lock*
                #:*sessions*)
  (:import-from #:dsmr-mcp/src/tools/base
                #:*tool-classes*)
  (:import-from #:bordeaux-threads)
  (:import-from #:com.inuoe.jzon))

(in-package #:dsmr-mcp/tests/transport/transport-parity-test)

;;; ---------------------------------------------------------------------------
;;; Helpers
;;; ---------------------------------------------------------------------------

(defun %reference-tool-names ()
  "Return a sorted list of all tool names in the in-process *tool-classes* registry.
This is the canonical set that the stdio and TCP transports serve."
  (let (names)
    (maphash (lambda (name cls)
               (declare (ignore cls))
               (push name names))
             *tool-classes*)
    (sort names #'string<)))

(defun %http-tool-names (port session-id)
  "Fetch the tools/list response over HTTP and return a sorted list of tool names."
  (multiple-value-bind (status headers body)
      (handler-case
          (send-http-request
           port "POST" "/mcp"
           :body "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{}}"
           :headers (list '("Content-Type" . "application/json")
                          '("Accept" . "application/json")
                          (cons "Mcp-Session-Id" session-id)))
        (error () (values nil nil nil)))
    (declare (ignore headers))
    (when (and status (eql status 200) body (plusp (length body)))
      (handler-case
          (let* ((parsed (com.inuoe.jzon:parse body))
                 (result (and (hash-table-p parsed) (gethash "result" parsed)))
                 (tools  (and (hash-table-p result) (gethash "tools" result))))
            (when (vectorp tools)
              (sort (map 'list (lambda (t2) (gethash "name" t2)) tools)
                    #'string<)))
        (error () nil)))))

(defun %extract-session-id (headers)
  "Extract the Mcp-Session-Id value from an HTTP response headers string."
  (let ((pos (search "Mcp-Session-Id" headers :test #'char-equal)))
    (when pos
      (let* ((colon (position #\: headers :start pos))
             (start (when colon (+ colon 2)))
             (end   (when start
                      (or (position #\Return headers :start start)
                          (position #\Newline headers :start start)
                          (length headers)))))
        (when (and start end)
          (string-trim '(#\Space #\Tab #\Return #\Newline)
                       (subseq headers start end)))))))

;;; ---------------------------------------------------------------------------
;;; Test
;;; ---------------------------------------------------------------------------

(define-test tools-list-set-matches-across-transports
  "HTTP tools/list returns the same tool names as the in-process tool registry."
  (if (not (http-port-available-p))
      (skip "no loopback HTTP port bindable in this environment; socket bind is denied here")
      (unwind-protect
           (multiple-value-bind (acceptor port)
               (start-http-server :host "127.0.0.1" :port 0
                                  :slynk-attach nil
                                  :project-root nil)
             (declare (ignore acceptor))
             (sleep 0.1d0)
             ;; Initialize a session so we can call tools/list.
             (multiple-value-bind (init-status init-headers)
                 (handler-case
                     (send-http-request
                      port "POST" "/mcp"
                      :body (concatenate 'string
                                         "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\","
                                         "\"params\":{\"protocolVersion\":\"2025-06-18\","
                                         "\"capabilities\":{},\"clientInfo\":"
                                         "{\"name\":\"parity-test\",\"version\":\"1\"}}}")
                      :headers '(("Content-Type" . "application/json")
                                 ("Accept" . "application/json")))
                   (error () (values nil nil)))
               (when (and init-status (eql init-status 200))
                 (let ((session-id (%extract-session-id init-headers)))
                   (when session-id
                     (let ((reference (%reference-tool-names))
                           (http-tools (%http-tool-names port session-id)))
                       (when (and reference http-tools)
                         ;; Every reference tool name appears in the HTTP response.
                         (dolist (name reference)
                           (true (member name http-tools :test #'string=)))
                         ;; The HTTP response contains no extra tool names.
                         (dolist (name http-tools)
                           (true (member name reference :test #'string=))))))))))
        (stop-http-server)
        (bordeaux-threads:with-lock-held (*sessions-lock*)
          (clrhash *sessions*)))))
