;;;; src/bus/envelope.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; The coordination bus wire format: how a bus id is constructed, how it is
;;;; encoded into a filesystem-safe token, and how a message body is wrapped and
;;;; unwrapped.
;;;;
;;;; This is a leaf. It uses #:cl and the ZeroMQ-free WAL leaf, and nothing else,
;;;; so both the ZeroMQ-coupled bus facade and the standalone watcher binary can
;;;; share ONE implementation of the format. Two processes that must agree on an
;;;; encoded id byte-for-byte cannot be allowed to carry two encoders — a single
;;;; alphabet change on either side would silently desync them.

(require :sb-posix)

(defpackage #:dsmr-mcp/src/bus/envelope
  (:use #:cl)
  (:local-nicknames (#:wal #:dsmr-mcp/src/bus/wal))
  (:export #:encode-id
           #:agent-id
           #:wrap-envelope
           #:decode-envelope
           #:delivered-body-string
           #:+envelope-delimiter+))

(in-package #:dsmr-mcp/src/bus/envelope)

;;; --------------------------------------------------------------- identity

(defvar *local-counter* 0
  "Process-local counter for auto-generated subscriber names.")

(defun %unique-local ()
  "A token unique across processes (pid) and within one (counter) — gensym-style
   for an anonymous, ephemeral subagent."
  (format nil "g~A-~A" (sb-posix:getpid) (incf *local-counter*)))

(defun agent-id (namespace &key name)
  "Construct a bus subscriber id of the form <namespace>/<name>. NAMESPACE is the
   project root (the shared 'generation name'); NAME, when given, is a stable
   subagent name that resumes its cursor across restarts. When NAME is omitted an
   auto-unique ephemeral name is generated, so multiple anonymous subagents in one
   project each get a distinct id under the shared namespace."
  (format nil "~A/~A" namespace (or name (%unique-local))))

(defun encode-id (id)
  "Percent-encode ID into a single filesystem-safe token for a cursor filename.
   Injective, so two distinct ids never share a cursor."
  (with-output-to-string (s)
    (loop for ch across id
          do (if (or (alphanumericp ch) (member ch '(#\. #\- #\_)))
                 (write-char ch s)
                 (format s "%~2,'0X" (char-code ch))))))

;;; ------------------------------------------------------ message envelope
;;;
;;; Two distinct needs ride one body envelope, with NO change to the WAL frame
;;; and none to the append path (which stores the submission verbatim):
;;;
;;;   - SELF-WAKE: the publisher learns the log-assigned seq of its OWN message
;;;     by tagging it with a globally-unique correlation-id, then matching that id
;;;     on the durable record it reads back. Matching by message IDENTITY (not WAL
;;;     position) is what makes this race-free under concurrent cross-process
;;;     publishing — a foreign agent's record simply fails the id match.
;;;
;;;   - SELF-ECHO suppression: the envelope also carries the publisher's stable
;;;     self-id, so the publisher's OWN receive can filter its own messages out of
;;;     the returned set (the agent layer does this) — without ever touching a
;;;     cursor.
;;;
;;; Wire format of the body string:  correlation-id <DELIM> encoded-self-id <DELIM> payload
;;; DELIM is a single char outside both the correlation-id alphabet and ENCODE-ID's
;;; output, so neither field can ever contain it; the payload follows the SECOND
;;; delimiter raw and may itself contain DELIM harmlessly (decoding splits on the
;;; first two only).

(defconstant +envelope-delimiter+ #\|
  "The envelope field separator. Outside the correlation-id alphabet (lowercase
   hex/alphanumerics) and outside ENCODE-ID's output (percent-encoding over
   alphanumerics + . - _), so it can appear only in the payload — never in either
   id field.")

(defun wrap-envelope (correlation-id self-id payload)
  "Build the wire body: CORRELATION-ID + DELIM + (ENCODE-ID SELF-ID) + DELIM +
   PAYLOAD. A NIL SELF-ID embeds an empty encoded field; the wrap always emits two
   delimiters so the format is uniform and decoding is unambiguous."
  (format nil "~A~C~A~C~A"
          correlation-id
          +envelope-delimiter+
          (if self-id (encode-id self-id) "")
          +envelope-delimiter+
          payload))

(defun decode-envelope (body-string)
  "Split a wire body into THREE values: the original user TEXT (everything past the
   second delimiter), the CORRELATION-ID, and the ENCODED SELF-ID (compared
   encoded-vs-encoded against (ENCODE-ID id), so it is returned in its encoded
   form). The payload may itself contain the delimiter — only the first two
   delimiter positions are used. A body WITHOUT two delimiters is a legacy,
   un-enveloped message from an old-core publisher: it is returned verbatim as the
   text with NIL ids, so the decoder is backward-compatible during a staggered
   rollout."
  (let ((d1 (position +envelope-delimiter+ body-string)))
    (if d1
        (let ((d2 (position +envelope-delimiter+ body-string :start (1+ d1))))
          (if d2
              (values (subseq body-string (1+ d2))
                      (subseq body-string 0 d1)
                      (let ((encoded (subseq body-string (1+ d1) d2)))
                        (if (zerop (length encoded)) nil encoded)))
              (values body-string nil nil)))
        (values body-string nil nil))))

(defun delivered-body-string (record)
  "The original user text of RECORD — its body decoded through the envelope. A
   single call for body-only readers that do not need the ids."
  (values (decode-envelope (wal:record-body-string record))))
