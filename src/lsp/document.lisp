;;;; src/lsp/document.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; LSP-03: document lifecycle notifications — didOpen, didChange, didClose.
;;;; Implements the eager write-then-notify contract (D-10): every dispatcher-
;;;; side edit fires textDocument/didChange with the full new buffer text.
;;;;
;;;; Allow-list policy (D-11): didChange (edit sync) is restricted to the
;;;; write jail (current project root).  A path outside the jail is a silent
;;;; no-op — a notification failure must never fail the edit tool call (D-10).
;;;;
;;;; URI encoding (Linux-only):
;;;;   Path → URI: "file://<namestring>"
;;;;   URI → Path: strip the leading "file://" prefix (7 chars).
;;;; No percent-encoding is applied; typical Linux paths need none.
;;;;
;;;; Version counter: per-URI monotonically increasing integer, owned by
;;;; the LSP client struct (bump-uri-version in client.lisp).
;;;; The caller supplies the version; this module is responsible only for
;;;; building the correct notification payload shape.

(defpackage #:dsmr-mcp/src/lsp/document
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/lsp/client
                #:lsp-client-project-root
                #:lsp-send-notification
                #:lsp-client-connected-p)
  (:import-from #:dsmr-mcp/src/project-root
                #:ensure-write-path)
  (:import-from #:dsmr-mcp/src/log #:log-event)
  (:export #:notify-did-open
           #:notify-did-change
           #:notify-did-close
           #:path->file-uri
           #:file-uri->path))

(in-package #:dsmr-mcp/src/lsp/document)

;;; ---------------------------------------------------------------------------
;;; URI helpers
;;; ---------------------------------------------------------------------------

(defun path->file-uri (pathname)
  "Convert PATHNAME to a file:// URI string.
PATHNAME may be a string or a pathname object.  The namestring is used directly
with a \"file://\" prefix; no percent-encoding is applied (Linux paths, D-11)."
  (format nil "file://~A" (if (pathnamep pathname)
                               (namestring pathname)
                               pathname)))

(defun file-uri->path (uri)
  "Strip the \"file://\" prefix from URI and return the remainder as a string.
Returns the absolute filesystem path corresponding to the URI."
  (subseq uri 7))

;;; ---------------------------------------------------------------------------
;;; Allow-list guard
;;; ---------------------------------------------------------------------------

(defun %jail-guarded-uri (path client)
  "Return the canonical file:// URI for PATH if it is inside CLIENT's write jail.
Returns NIL when PATH is outside the jail, or when CLIENT has no project root.
The root is taken from the client struct (D-11: sync jail mirrors write jail)."
  (let ((root (lsp-client-project-root client)))
    (unless root
      (log-event :debug "lsp.document.no-root" "path" (namestring path))
      (return-from %jail-guarded-uri nil))
    (let ((pn (ensure-write-path (if (pathnamep path)
                                     (namestring path)
                                     path)
                                 root)))
      (unless pn
        (log-event :debug "lsp.document.outside-write-jail"
                   "path" (if (pathnamep path) (namestring path) path))
        (return-from %jail-guarded-uri nil))
      (path->file-uri pn))))

;;; ---------------------------------------------------------------------------
;;; Notification builders
;;; ---------------------------------------------------------------------------

(defun notify-did-open (client path text)
  "Send a textDocument/didOpen notification to CLIENT for PATH with TEXT.
Uses languageId \"lisp\" and version 1 (alive-lsp's didOpen handler requires these).
The path must be inside the client's write jail (D-11).
Returns NIL.  A notification failure (client not connected, outside jail) is a
silent no-op — fire-and-forget (D-10)."
  (ignore-errors
    (let ((uri (%jail-guarded-uri path client)))
      (unless uri (return-from notify-did-open nil))
      (let ((params (make-hash-table :test 'equal))
            (doc    (make-hash-table :test 'equal)))
        (setf (gethash "uri"          doc) uri
              (gethash "languageId"   doc) "lisp"
              (gethash "version"      doc) 1
              (gethash "text"         doc) text
              (gethash "textDocument" params) doc)
        (lsp-send-notification client "textDocument/didOpen" params)
        (log-event :debug "lsp.document.did-open" "uri" uri))))
  nil)

(defun notify-did-change (client path text version)
  "Send a textDocument/didChange notification to CLIENT for PATH with TEXT.
VERSION is the monotonically increasing per-URI version integer.
The caller is responsible for obtaining VERSION via bump-uri-version.
Full document sync: contentChanges carries the entire buffer (D-10).
The path must be inside the client's write jail (D-11).
Returns NIL.  A notification failure is a silent no-op — fire-and-forget (D-10)."
  (ignore-errors
    (let ((uri (%jail-guarded-uri path client)))
      (unless uri (return-from notify-did-change nil))
      (let ((params (make-hash-table :test 'equal))
            (doc    (make-hash-table :test 'equal))
            (change (make-hash-table :test 'equal)))
        (setf (gethash "uri"             doc) uri
              (gethash "version"         doc) version
              (gethash "text"            change) text
              (gethash "textDocument"    params) doc
              (gethash "contentChanges"  params) (vector change))
        (lsp-send-notification client "textDocument/didChange" params)
        (log-event :debug "lsp.document.did-change" "uri" uri "version" version))))
  nil)

(defun notify-did-close (client path)
  "Send a textDocument/didClose notification to CLIENT for PATH.
Returns NIL.  A notification failure is a silent no-op — fire-and-forget (D-10)."
  (ignore-errors
    (let ((uri (%jail-guarded-uri path client)))
      (unless uri (return-from notify-did-close nil))
      (let ((params (make-hash-table :test 'equal))
            (doc    (make-hash-table :test 'equal)))
        (setf (gethash "uri"          doc) uri
              (gethash "textDocument" params) doc)
        (lsp-send-notification client "textDocument/didClose" params)
        (log-event :debug "lsp.document.did-close" "uri" uri))))
  nil)
