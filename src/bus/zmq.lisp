;;;; src/bus/zmq.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; ZeroMQ transport for the coordination bus — the live message path. This is a
;;;; core, required component, not an optional accelerator: clients submit work to
;;;; the broker over it and the broker fans out notifications over it. The durable
;;;; WAL+cursor layer guarantees nothing is lost across a crash or a sleep, but the
;;;; moment-to-moment movement of messages is ZeroMQ's job.
;;;;
;;;; Two socket pairs, both over `ipc://` (single host):
;;;;
;;;;   - SUBMIT  PUSH (client, connect) → PULL (broker, bind). Fan-IN of work to
;;;;     the single broker; PUSH/PULL load-balances and never drops a part.
;;;;   - FANOUT  PUB (broker, bind) → SUB (subscriber, connect). Fan-OUT of live
;;;;     "a message landed" nudges; a subscriber that misses a nudge (slow joiner,
;;;;     was asleep) still catches up from its WAL cursor, so PUB/SUB's lossiness
;;;;     is covered by the durable layer rather than fought.
;;;;
;;;; Sockets here are LONG-LIVED (a broker holds its intake + pub for its whole
;;;; run), so this uses the raw context/socket calls rather than pzmq's scope
;;;; macros, which close on scope exit. Each endpoint owns its own context for a
;;;; self-contained lifecycle; :linger 0 keeps close/terminate from blocking on
;;;; undelivered messages, and a receive timeout turns a quiet socket into a NIL
;;;; return instead of an indefinite block.

(defpackage #:dsmr-mcp/src/bus/zmq
  (:use #:cl)
  (:local-nicknames (#:zmq #:pzmq))
  (:export #:endpoint #:endpoint-role #:close-endpoint
           #:make-intake #:make-publisher #:make-submitter #:make-feed
           #:send-message #:recv-message))

(in-package #:dsmr-mcp/src/bus/zmq)

(defstruct (endpoint (:constructor %make-endpoint (role context socket)))
  (role nil :type keyword)
  (context nil)
  (socket nil))

(defun %ipc-path (endpoint-string)
  "The filesystem path backing an ipc:// endpoint, or NIL for other transports."
  (let ((prefix "ipc://"))
    (when (and (>= (length endpoint-string) (length prefix))
               (string= prefix endpoint-string :end2 (length prefix)))
      (subseq endpoint-string (length prefix)))))

(defun %open (role type endpoint-string &key bind subscribe rcvtimeo-ms)
  "Create a context + socket of TYPE, apply options, and bind or connect it.
   Returns an ENDPOINT. A stale ipc socket file left by a dead binder is removed
   before binding so the broker (which won the election) always reclaims its
   endpoint instead of failing with EADDRINUSE."
  (let* ((context (zmq:ctx-new))
         (socket (zmq:socket context type)))
    (handler-case
        (progn
          (zmq:setsockopt socket :linger 0)        ; don't block close on backlog
          (when rcvtimeo-ms
            (zmq:setsockopt socket :rcvtimeo rcvtimeo-ms))
          (when subscribe
            (zmq:setsockopt socket :subscribe subscribe))
          (cond
            (bind
             (let ((path (%ipc-path endpoint-string)))
               (when (and path (probe-file path)) (ignore-errors (delete-file path))))
             (zmq:bind socket endpoint-string))
            (t (zmq:connect socket endpoint-string)))
          (%make-endpoint role context socket))
      (error (e)
        ;; tear down the half-built endpoint before re-signalling
        (ignore-errors (zmq:close socket))
        (ignore-errors (zmq:ctx-term context))
        (error e)))))

;;; ------------------------------------------------------------- broker side

(defun make-intake (endpoint-string &key (timeout-ms 100))
  "Broker work-intake: a PULL socket bound to ENDPOINT-STRING. RECV-MESSAGE
   returns NIL after TIMEOUT-MS of silence so the broker loop can do other work."
  (%open :intake :pull endpoint-string :bind t :rcvtimeo-ms timeout-ms))

(defun make-publisher (endpoint-string)
  "Broker fan-out: a PUB socket bound to ENDPOINT-STRING."
  (%open :publisher :pub endpoint-string :bind t))

;;; ------------------------------------------------------------- client side

(defun make-submitter (endpoint-string)
  "Client work-submit: a PUSH socket connected to the broker's intake."
  (%open :submitter :push endpoint-string))

(defun make-feed (endpoint-string &key (timeout-ms 100) (subscribe ""))
  "Subscriber live-feed: a SUB socket connected to the broker's publisher.
   SUBSCRIBE defaults to the empty prefix (all messages). RECV-MESSAGE returns NIL
   after TIMEOUT-MS of silence."
  (%open :feed :sub endpoint-string :subscribe subscribe :rcvtimeo-ms timeout-ms))

;;; ------------------------------------------------------------- I/O

(defun send-message (endpoint payload)
  "Send PAYLOAD (a string or octet vector) on a PUSH or PUB ENDPOINT."
  (zmq:send (endpoint-socket endpoint) payload)
  payload)

(defun recv-message (endpoint)
  "Receive one message on a PULL or SUB ENDPOINT as an octet vector, or NIL if the
   socket's receive timeout elapsed with nothing to read. Binary-clean."
  (handler-case
      (zmq:recv-octets (endpoint-socket endpoint))
    (zmq:eagain () nil)))

;;; ------------------------------------------------------------- lifecycle

(defun close-endpoint (endpoint)
  "Close the socket and terminate the context. Safe to call more than once."
  (when (endpoint-socket endpoint)
    (ignore-errors (zmq:close (endpoint-socket endpoint)))
    (setf (endpoint-socket endpoint) nil))
  (when (endpoint-context endpoint)
    (ignore-errors (zmq:ctx-term (endpoint-context endpoint)))
    (setf (endpoint-context endpoint) nil))
  (values))
