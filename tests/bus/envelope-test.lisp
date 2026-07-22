;;;; tests/bus/envelope-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Parachute tests for the bus wire format. Two processes that never share
;;;; memory — the MCP session and the standalone watcher — both read and write
;;;; this format, so the properties pinned here are what make their agreement
;;;; possible: the round trip is exact, the payload is transparent to the
;;;; framing, an un-enveloped body from an older publisher still reads, and an
;;;; encoded id can never contain the delimiter that separates the fields.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/bus/envelope-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/bus/envelope-test
  (:use #:cl #:parachute)
  (:local-nicknames (#:envelope #:dsmr-mcp/src/bus/envelope)))

(in-package #:dsmr-mcp/tests/bus/envelope-test)

(defun delimiter-count (string)
  (count envelope:+envelope-delimiter+ string))

(define-test envelope-round-trips-payload-and-ids
  "A wrapped body decodes back to the payload, the correlation id, and the
   ENCODED form of the self id — encoded, because the receive-side filter
   compares encoded against encoded."
  (let* ((self "/home/fade/proj/worker")
         (wire (envelope:wrap-envelope "c1x2x3" self "hello there")))
    (multiple-value-bind (text cid sid) (envelope:decode-envelope wire)
      (is string= "hello there" text)
      (is string= "c1x2x3" cid)
      (is string= (envelope:encode-id self) sid
          "the self id comes back encoded, ready to compare against ENCODE-ID"))))

(define-test nil-self-id-wraps-empty-and-decodes-nil
  "A publisher with no stable identity still emits both delimiters, so the
   framing is uniform, and the absent id decodes to NIL rather than an empty
   string."
  (let ((wire (envelope:wrap-envelope "c9" nil "body")))
    (is = 2 (delimiter-count wire)
        "the format stays uniform even with an empty id field")
    (multiple-value-bind (text cid sid) (envelope:decode-envelope wire)
      (is string= "body" text)
      (is string= "c9" cid)
      (false sid "an empty encoded field decodes to NIL, not \"\""))))

(define-test payload-may-contain-the-delimiter
  "Only the first two delimiters frame the message, so a payload carrying the
   delimiter itself survives verbatim — otherwise any message quoting bus wire
   text would corrupt its own framing."
  (let* ((payload (format nil "a~Cb~Cc" envelope:+envelope-delimiter+
                          envelope:+envelope-delimiter+))
         (wire (envelope:wrap-envelope "c7" "/p/n" payload)))
    (multiple-value-bind (text cid sid) (envelope:decode-envelope wire)
      (is string= payload text)
      (is string= "c7" cid)
      (is string= (envelope:encode-id "/p/n") sid))))

(define-test un-enveloped-bodies-decode-verbatim
  "A body from a publisher running an older core carries no envelope. It must
   read back as its own text with no ids, so a staggered rollout never drops or
   garbles a message."
  (let ((bare "plain old message")
        (one-delim (format nil "half~Cenveloped" envelope:+envelope-delimiter+)))
    (multiple-value-bind (text cid sid) (envelope:decode-envelope bare)
      (is string= bare text)
      (false cid)
      (false sid))
    (multiple-value-bind (text cid sid) (envelope:decode-envelope one-delim)
      (is string= one-delim text
          "one delimiter is not an envelope — the whole body is the text")
      (false cid)
      (false sid))))

(define-test encode-id-is-injective-and-delimiter-free
  "Ids that differ only in a character that percent-encodes must still encode
   differently, or two agents would share a cursor file. And no encoded id may
   contain the delimiter, or it could not be a wire field at all."
  (let ((slash (envelope:encode-id "a/b"))
        (dash (envelope:encode-id "a-b"))
        (piped (envelope:encode-id
                (format nil "a~Cb" envelope:+envelope-delimiter+))))
    (false (string= slash dash)
           "a percent-encoded character stays distinguishable from a safe one")
    (is = 0 (delimiter-count slash))
    (is = 0 (delimiter-count dash))
    (is = 0 (delimiter-count piped)
        "even an id containing the delimiter encodes to a delimiter-free token")))

(define-test agent-id-is-stable-when-named-and-unique-when-not
  "A named agent gets the same id every time so it resumes its own cursor; an
   anonymous one gets a fresh id per call so concurrent subagents never collide."
  (is string= "/home/fade/proj/worker"
      (envelope:agent-id "/home/fade/proj" :name "worker"))
  (is string= (envelope:agent-id "/home/fade/proj" :name "worker")
      (envelope:agent-id "/home/fade/proj" :name "worker"))
  (let ((a (envelope:agent-id "/p"))
        (b (envelope:agent-id "/p")))
    (false (string= a b) "two ephemeral ids in one namespace differ")
    (is = 0 (search "/p/" a) "an ephemeral id is still scoped to its namespace")))

(define-test foreign-self-id-p-recognizes-own-foreign-and-legacy
  "The shared delivery predicate, the single comparison the receive filter, the
   pending count, and the watcher all turn on. An agent's OWN encoded id is not
   foreign (delivery drops it); any other id is foreign (delivery returns it); a
   record with NO self-id is a legacy un-enveloped message and counts as foreign
   so a staggered rollout never drops it; and with no identity resolved (a NIL
   own-encoded) everything is foreign, the pre-identity default."
  (let ((mine (envelope:encode-id "/p/me"))
        (theirs (envelope:encode-id "/p/them")))
    (false (envelope:foreign-self-id-p mine mine)
           "an agent's own record is not foreign to it")
    (true (envelope:foreign-self-id-p theirs mine)
          "another agent's record is foreign")
    (true (envelope:foreign-self-id-p nil mine)
          "a legacy record with no self-id counts as foreign")
    (true (envelope:foreign-self-id-p mine nil)
          "with no identity resolved, everything is foreign")
    (true (envelope:foreign-self-id-p nil nil)
          "no identity and no self-id is still foreign")))
