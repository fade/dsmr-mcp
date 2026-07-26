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
           #:decode-id
           #:split-agent-id
           #:author-display
           #:agent-id
           #:wrap-envelope
           #:decode-envelope
           #:delivered-body-string
           #:foreign-self-id-p
           #:foreign-record-p
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

(defun decode-id (encoded)
  "Invert ENCODE-ID: turn a percent-encoded id token back into the plain
   <namespace>/<name> string it was built from. Returns NIL for a NIL token and
   for one that is not well-formed percent-encoding, so a reader can say the
   author is unknown rather than present a mangled id as if it were a name. A
   half-decoded id is worse than no id at all."
  (when encoded
    (handler-case
        (with-output-to-string (s)
          (let ((i 0)
                (n (length encoded)))
            (loop while (< i n)
                  do (let ((ch (char encoded i)))
                       (cond ((char= ch #\%)
                              (when (> (+ i 3) n)
                                (return-from decode-id nil))
                              (write-char (code-char
                                           (parse-integer encoded
                                                          :start (1+ i)
                                                          :end (+ i 3)
                                                          :radix 16))
                                          s)
                              (incf i 3))
                             (t
                              (write-char ch s)
                              (incf i)))))))
      (error () nil))))

(defun split-agent-id (id)
  "Split a bus id into its namespace and the name within that namespace: two
   values, everything before the LAST separator and everything after it. An id
   with no separator has no namespace and comes back whole as the name. The last
   separator is the split point because the namespace is a project root path and
   carries separators of its own, while a name never does."
  (let ((sep (position #\/ id :from-end t)))
    (if sep
        (values (subseq id 0 sep) (subseq id (1+ sep)))
        (values nil id))))

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

(defun author-display (encoded-self-id own-namespace)
  "Render the agent that published a record as a short string a reader can trust.
   ENCODED-SELF-ID is the third value DECODE-ENVELOPE returns; OWN-NAMESPACE is
   the reading agent's namespace.

   A sender in the reader's own namespace renders as its bare name, which is how
   agents in one project already refer to each other. A sender from any other
   namespace renders as name@namespace: a bare name that collides across projects
   would restore exactly the ambiguity an author field exists to remove, and the
   raw encoded id is a wall of percent escapes nobody reads.

   A record with no self-id (an un-enveloped message from an older publisher) or
   one whose id will not decode renders as \"unknown\". Delivery of a message must
   never depend on being able to name its author."
  (let ((id (decode-id encoded-self-id)))
    (if (null id)
        "unknown"
        (multiple-value-bind (namespace name) (split-agent-id id)
          (cond ((null namespace) id)
                ((and own-namespace (string= namespace own-namespace)) name)
                (t (format nil "~A@~A" name
                           (string-right-trim "/" namespace))))))))

(defun foreign-self-id-p (encoded-self-id own-encoded)
  "True when a record whose decoded ENCODED-SELF-ID is ENCODED-SELF-ID is FOREIGN
   to the agent whose encoded id is OWN-ENCODED — i.e. that agent did not publish
   it, so delivery would return it. This is the one comparison the whole delivery
   filter turns on, factored to a single place so the receive path, the pending
   count, and the watcher cannot drift apart the first time either alphabet
   changes.

   Two cases deliberately count as foreign. A NIL OWN-ENCODED means no identity
   resolved, so there is no self to recognize and everything counts (exactly the
   pre-identity watcher behavior). A NIL ENCODED-SELF-ID is a legacy un-enveloped
   message from an old-core publisher; treating it as this agent's own would drop
   real traffic on the floor through a staggered rollout."
  (or (null own-encoded)
      (not (and encoded-self-id (string= encoded-self-id own-encoded)))))

(defun foreign-record-p (record own-encoded)
  "True when RECORD was not published by the agent whose encoded id is
   OWN-ENCODED — i.e. RECORD is deliverable to that agent. Decodes RECORD's body
   through the shared envelope and defers the verdict to FOREIGN-SELF-ID-P, so the
   comparison is encoded-against-encoded on the self-id this leaf pulls out of the
   body — the same comparison every consumer of this leaf makes."
  (multiple-value-bind (text correlation-id self-id)
      (decode-envelope (wal:record-body-string record))
    (declare (ignore text correlation-id))
    (foreign-self-id-p self-id own-encoded)))
