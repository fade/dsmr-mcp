;;;; tests/hermetic/worker-client-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Unit tests for how workers are started: the secret a worker
;;;; authenticates with.

(defpackage #:dsmr-mcp/tests/hermetic/worker-client-test
  (:use #:cl #:zebra)
  (:local-nicknames (#:wc #:dsmr-mcp/src/hermetic/worker-client)))

(in-package #:dsmr-mcp/tests/hermetic/worker-client-test)

;;; ---------------------------------------------------------------------------
;;; Secrets
;;; ---------------------------------------------------------------------------

(define-test servers-started-alike-give-their-workers-different-secrets
  "Every server starts from the same image with the same random state, so a
secret drawn from that state would repeat from one server to the next. Two
draws made from identical random states still differ."
  (let ((a (let ((*random-state* (sb-ext:seed-random-state 7)))
             (wc::%generate-worker-secret)))
        (b (let ((*random-state* (sb-ext:seed-random-state 7)))
             (wc::%generate-worker-secret))))
    (is = 32 (length a))
    (true (every (lambda (ch) (digit-char-p ch 16)) a))
    (false (string= a b) "two servers would share the secret ~A" a)))
