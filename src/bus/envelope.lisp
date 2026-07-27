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
           #:record-addressee
           #:deliverable-p
           #:deliverable-record-p
           #:+envelope-delimiter+
           #:+routing-separator+))

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

(defconstant +routing-separator+ #\>
  "Separates the publisher's encoded self-id from an encoded addressee INSIDE the
   envelope's second field, which is why that field is a routing field rather
   than a self-id field.

   Chosen for two properties, both of which the format depends on. It is outside
   ENCODE-ID's output alphabet (percent-encoding over alphanumerics + . - _), so
   neither half of the field can ever contain it and the split is unambiguous by
   construction. And it is not the envelope delimiter, so carrying an addressee
   leaves the delimiter count at two and changes nothing about how the payload is
   found.

   Nesting the addressee here rather than adding a third delimiter-bounded field
   is deliberate and is the only decidable choice. A payload may itself contain
   the delimiter, so a record published before addressing existed can already
   present three delimiters; a reader that counted them would take part of the
   message body as an addressee and silently truncate the rest.")

(defun %routing-field (self-id to)
  "Build the envelope's routing field: the encoded SELF-ID on its own for a
   broadcast, or the encoded self-id, the routing separator, and the encoded
   addressee TO for an addressed record. A NIL SELF-ID contributes an empty
   first half, so a publisher with no identity can still address a message."
  (let ((self (if self-id (encode-id self-id) "")))
    (if to
        (format nil "~A~C~A" self +routing-separator+ (encode-id to))
        self)))

(defun wrap-envelope (correlation-id self-id payload &key to)
  "Build the wire body: CORRELATION-ID + DELIM + routing field + DELIM + PAYLOAD.
   The routing field is (ENCODE-ID SELF-ID); a NIL SELF-ID embeds an empty one.
   The wrap always emits two delimiters so the format is uniform and decoding is
   unambiguous.

   TO, when given, is the bus id of the one participant this message is for. It
   is encoded and appended to the routing field after +ROUTING-SEPARATOR+, so an
   addressed record is CID + DELIM + ENCODED-SELF + SEP + ENCODED-TO + DELIM +
   PAYLOAD. With TO NIL the string produced is byte for byte the one this
   function has always produced.

   The reason the addressee rides inside the routing field, and the reason the
   delimiter count does not change, is that decoding has to stay decidable
   against records already on the log. Reading is a three-rung ladder:

     zero delimiters, or one, is a legacy un-enveloped body from a publisher
     running an older core, returned verbatim as the text;

     two delimiters with a plain routing field is a broadcast, decoded exactly as
     it always was;

     two delimiters with a routing field carrying the separator is an addressed
     record, and only then is an addressee read.

   The degradation is in the safe direction. A reader that has not been upgraded
   compares the whole routing field against its own encoded id, finds no match,
   judges the record foreign and delivers it. It over-delivers rather than
   mis-parsing, and no message text is ever altered. The one cost is that such a
   reader also fails to recognise its own addressed publish and takes delivery of
   its own message, which can only happen once someone has deliberately turned
   addressing on."
  (format nil "~A~C~A~C~A"
          correlation-id
          +envelope-delimiter+
          (%routing-field self-id to)
          +envelope-delimiter+
          payload))

(defun %nonempty (string)
  "STRING, or NIL when it is empty. An absent envelope field is written as an
   empty one, and a caller wants to see the absence rather than a blank string."
  (if (zerop (length string)) nil string))

(defun %split-routing-field (routing)
  "Split the envelope's routing field into TWO values: the encoded self-id and
   the encoded addressee, each NIL when absent.

   A field with no separator is a broadcast and is all self-id. A field with one
   is an addressed record. The separator cannot occur in either half, because
   both halves are ENCODE-ID output, so the first occurrence is the split point
   and there is nothing left to disambiguate."
  (let ((sep (position +routing-separator+ routing)))
    (if sep
        (values (%nonempty (subseq routing 0 sep))
                (%nonempty (subseq routing (1+ sep))))
        (values (%nonempty routing) nil))))

(defun decode-envelope (body-string)
  "Split a wire body into FOUR values: the original user TEXT (everything past
   the second delimiter), the CORRELATION-ID, the ENCODED SELF-ID, and the
   ENCODED ADDRESSEE. Both ids come back in their encoded form, because every
   comparison against them is made encoded against encoded.

   The first three values are exactly what this function has always returned,
   for every body that decodes today. The payload may itself contain the
   delimiter, so only the first two delimiter positions are ever used. A body
   WITHOUT two delimiters is a legacy, un-enveloped message from an old-core
   publisher: it is returned verbatim as the text with NIL ids, so the decoder
   is backward-compatible during a staggered rollout.

   The fourth value is NIL for every broadcast and every legacy record, and is
   the addressee only when the routing field carries +ROUTING-SEPARATOR+. It is
   read out of the second field rather than a third one precisely so that a
   legacy payload containing the delimiter cannot be mistaken for routing
   information. Adding a value is safe for callers that destructure the first
   three: a MULTIPLE-VALUE-BIND drops the extra silently."
  (let ((d1 (position +envelope-delimiter+ body-string)))
    (if d1
        (let ((d2 (position +envelope-delimiter+ body-string :start (1+ d1))))
          (if d2
              (multiple-value-bind (self-id addressee)
                  (%split-routing-field (subseq body-string (1+ d1) d2))
                (values (subseq body-string (1+ d2))
                        (subseq body-string 0 d1)
                        self-id
                        addressee))
              (values body-string nil nil nil)))
        (values body-string nil nil nil))))

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

(defun record-addressee (record)
  "The ENCODED addressee RECORD names, or NIL when it names nobody. A broadcast
   and a legacy un-enveloped record both answer NIL, which is what makes an
   un-addressed record deliverable to everyone."
  (multiple-value-bind (text correlation-id self-id addressee)
      (decode-envelope (wal:record-body-string record))
    (declare (ignore text correlation-id self-id))
    addressee))

(defun deliverable-p (encoded-self-id encoded-addressee own-encoded)
  "True when a record whose routing field decoded to ENCODED-SELF-ID and
   ENCODED-ADDRESSEE should be handed to the agent whose encoded id is
   OWN-ENCODED. This is the whole delivery verdict in one place, so the receive
   path and the pending count cannot drift apart the first time either half of
   it changes, exactly as FOREIGN-SELF-ID-P already is for the first half.

   Two things must both hold. The record must be foreign, which is
   FOREIGN-SELF-ID-P unchanged: an agent is never handed back its own publish.
   And the record must be for this agent, which means it names nobody or names
   this agent.

   With no identity resolved (a NIL OWN-ENCODED) everything is deliverable,
   addressed mail included. There is no self to recognise and nothing to compare
   an addressee against, so the only safe reading is the pre-identity one: show
   the reader everything rather than silently withhold a message.

   This decides what a reader is SHOWN, never where its cursor sits. A cursor
   advances over every record regardless of who it names. A recipient that
   stopped at other people's mail would pin the log, which is the retirement
   problem multiplied."
  (and (foreign-self-id-p encoded-self-id own-encoded)
       (or (null own-encoded)
           (null encoded-addressee)
           (string= encoded-addressee own-encoded))
       t))

(defun deliverable-record-p (record own-encoded)
  "True when RECORD should be handed to the agent whose encoded id is
   OWN-ENCODED. Decodes RECORD's body through the shared envelope and defers the
   verdict to DELIVERABLE-P, which is the same shape FOREIGN-RECORD-P takes over
   FOREIGN-SELF-ID-P: one decode, one comparison, one place to change.

   This is the predicate the delivery path and the pending count both use.
   FOREIGN-RECORD-P is deliberately left alone and still means only what it has
   always meant, because the standalone watcher binary reads it and is deployed
   on a schedule of its own; a shift in its meaning would reach the fleet at a
   different time from the core that publishes for it."
  (multiple-value-bind (text correlation-id self-id addressee)
      (decode-envelope (wal:record-body-string record))
    (declare (ignore text correlation-id))
    (deliverable-p self-id addressee own-encoded)))
