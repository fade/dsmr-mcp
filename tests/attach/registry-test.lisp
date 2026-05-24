;;;; tests/attach/registry-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Integration tests for the image-resident attached object registry.
;;;; Covers ATTACH-09: result_object_id minting, survival across calls,
;;;; session isolation (D-07), register_result gating (D-06), and epoch
;;;; invalidation on connection drop (D-08).
;;;;
;;;; Uses the in-process Slynk fixture (with-temporary-slynk-listener)
;;;; so tests exercise the real slime-eval path without an external image.

;;; Package evolution guard: delete prior definition before redefining so
;;; the defpackage is always fresh in warm images.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/attach/registry-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/attach/registry-test
  (:use #:cl #:parachute)
  (:import-from #:dsmr-mcp/tests/support/slynk-fixture
                #:with-temporary-slynk-listener)
  (:import-from #:dsmr-mcp/src/attach/dispatch
                #:repl-eval-tool
                #:repl-eval-tool-slynk-conn
                #:%dispatch-attach
                #:repl-eval-tool-connection-epoch)
  (:import-from #:dsmr-mcp/src/attach/connection
                #:drop-connection)
  (:import-from #:dsmr-mcp/src/attach/registry
                #:build-lookup-form)
  (:import-from #:dsmr-mcp/src/state
                #:make-session
                #:*current-session-id*
                #:get-tool-instance
                #:session-slynk-attach)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:make-ht)
  (:import-from #:slynk-client
                #:slime-eval))

(in-package #:dsmr-mcp/tests/attach/registry-test)

;;; Test session helper -------------------------------------------------------

(defun %make-attach-session (id conn)
  "Create a test session for attached-mode tests and install CONN as the
cached slynk-connection on the repl-eval tool instance.

Returns (values SESSION TOOL) with CONN installed on TOOL's slynk-conn slot
so %dispatch-attach reuses the already-open fixture connection."
  (let* ((session (make-session :id id :slynk-attach "127.0.0.1:1"))
         (*current-session-id* id)
         (tool (get-tool-instance session "repl-eval")))
    (setf (repl-eval-tool-slynk-conn tool) conn)
    (values session tool)))

;;; ATTACH-09: result_object_id present for inspectable results ---------------

(define-test attach09-result-object-id-present
  "A repl-eval returning a CLOS instance puts a non-nil result_object_id
string in the response envelope. Primitives (numbers) must NOT produce one."
  (with-temporary-slynk-listener (conn)
    ;; Ensure a throwaway CLOS class is available in the attached image.
    (slime-eval '(progn
                  (unless (find-class 'test-registry-widget nil)
                    (defclass test-registry-widget () ((val :initarg :val :initform 0))))
                  nil)
                conn)
    (multiple-value-bind (session tool)
        (%make-attach-session "reg-test-present" conn)
      (declare (ignore session))
      ;; Inspectable result: a fresh CLOS instance.
      (let* ((res (%dispatch-attach tool
                                    (make-ht "code"
                                             "(make-instance 'test-registry-widget :val 42)")))
             (oid (gethash "result_object_id" res)))
        (false (gethash "isError" res))
        (true  oid)
        (true  (stringp oid))
        ;; id must match the epoch:session:raw-id format.
        (true  (find #\: oid)))
      ;; Primitive result (number): no result_object_id key.
      (let* ((res2 (%dispatch-attach tool (make-ht "code" "42")))
             (oid2 (gethash "result_object_id" res2)))
        (false (gethash "isError" res2))
        (true  (null oid2))))))

;;; ATTACH-09: IDs survive across sequential calls ----------------------------

(define-test attach09-ids-survive-across-calls
  "Two sequential repl-eval calls in the same session each return a distinct
result_object_id. Both underlying raw IDs remain look-up-able in the image table."
  (with-temporary-slynk-listener (conn)
    (slime-eval '(progn
                  (unless (find-class 'test-registry-widget nil)
                    (defclass test-registry-widget () ((val :initarg :val :initform 0))))
                  nil)
                conn)
    (multiple-value-bind (session tool)
        (%make-attach-session "reg-test-survive" conn)
      (declare (ignore session))
      (let* ((r1 (%dispatch-attach tool
                                   (make-ht "code"
                                            "(make-instance 'test-registry-widget :val 1)")))
             (r2 (%dispatch-attach tool
                                   (make-ht "code"
                                            "(make-instance 'test-registry-widget :val 2)")))
             (oid1 (gethash "result_object_id" r1))
             (oid2 (gethash "result_object_id" r2)))
        (false (gethash "isError" r1))
        (false (gethash "isError" r2))
        ;; Both IDs present and distinct.
        (true  oid1)
        (true  oid2)
        (isnt equal oid1 oid2)
        ;; Both raw IDs still live in the image table: look up each.
        ;; Decode: "<epoch>:<session-id>:<raw-id>" — raw-id is the 3rd colon-part.
        (flet ((raw-id-of (oid)
                 (let* ((parts (uiop:split-string oid :separator ":"))
                        (raw (parse-integer (third parts))))
                   raw))
               (sess-id-of (oid)
                 (let* ((parts (uiop:split-string oid :separator ":")))
                   (second parts))))
          (let* ((raw1 (raw-id-of oid1))
                 (sid1 (sess-id-of oid1))
                 (raw2 (raw-id-of oid2))
                 (sid2 (sess-id-of oid2))
                 ;; Use eval (not slime-eval) for in-process lookup.
                 ;; slime-eval condition-wait can deadlock under specific BT
                 ;; lock nesting when called on the same conn immediately after
                 ;; %dispatch-attach.  The fixture is in-process so eval is
                 ;; equivalent and correct here — we only want to verify
                 ;; that both entries survive in the image-resident table.
                 (found1 (eval (build-lookup-form raw1 sid1)))
                 (found2 (eval (build-lookup-form raw2 sid2))))
            ;; Look up must return the object (not :object-not-found).
            (isnt eq :object-not-found found1)
            (isnt eq :object-not-found found2)))))))

;;; ATTACH-09: session isolation (D-07) ----------------------------------------

(define-test attach09-session-isolation
  "An ID minted by session A, when looked up with session B's session-id,
resolves to :object-not-found — never another session's object (D-07)."
  (with-temporary-slynk-listener (conn)
    (slime-eval '(progn
                  (unless (find-class 'test-registry-widget nil)
                    (defclass test-registry-widget () ((val :initarg :val :initform 0))))
                  nil)
                conn)
    ;; Session A mints an ID.
    (multiple-value-bind (session-a tool-a)
        (%make-attach-session "reg-test-session-a" conn)
      (declare (ignore session-a))
      (let* ((ra (%dispatch-attach tool-a
                                   (make-ht "code"
                                            "(make-instance 'test-registry-widget :val 99)")))
             (oid-a (gethash "result_object_id" ra)))
        (true oid-a)
        ;; Decode oid-a: raw-id is position 3, session-id is position 2.
        (let* ((parts (uiop:split-string oid-a :separator ":"))
               (raw-id-a (parse-integer (third parts)))
               ;; Build a lookup using session-B's id instead of session-A's.
               (wrong-session-id "reg-test-session-b")
               (isolation-form (build-lookup-form raw-id-a wrong-session-id))
               ;; Use eval (not slime-eval) for in-process lookup — same
               ;; reason as attach09-ids-survive-across-calls: slime-eval
               ;; after %dispatch-attach on the same conn can deadlock under
               ;; the BT condition-wait path.
               (lookup-result  (eval isolation-form)))
          ;; Must get :object-not-found — not the actual object.
          (is eq :object-not-found lookup-result))))))

;;; ATTACH-09: register_result false suppresses id (D-06) ----------------------

(define-test attach09-register-result-false
  "When register_result is false in the params, result_object_id must be absent
from the response, even for an inspectable (CLOS) result (D-06)."
  (with-temporary-slynk-listener (conn)
    (slime-eval '(progn
                  (unless (find-class 'test-registry-widget nil)
                    (defclass test-registry-widget () ((val :initarg :val :initform 0))))
                  nil)
                conn)
    (multiple-value-bind (session tool)
        (%make-attach-session "reg-test-no-register" conn)
      (declare (ignore session))
      (let* ((res (%dispatch-attach
                   tool
                   (make-ht "code"
                            "(make-instance 'test-registry-widget :val 7)"
                            "register_result" nil)))
             (oid (gethash "result_object_id" res)))
        (false (gethash "isError" res))
        ;; No result_object_id key when register_result is false.
        (true  (null oid))))))

;;; ATTACH-09: epoch invalidation on drop-connection (D-08) -------------------

(define-test attach09-epoch-invalidation
  "Calling drop-connection on the tool increments repl-eval-tool-connection-epoch
by exactly 1, making IDs minted before the drop carry a stale epoch (D-08)."
  (with-temporary-slynk-listener (conn)
    (multiple-value-bind (session tool)
        (%make-attach-session "reg-test-epoch" conn)
      (declare (ignore session))
      (let ((epoch-before (repl-eval-tool-connection-epoch tool)))
        ;; drop-connection must bump the epoch.
        (drop-connection tool :reason "test-invalidation")
        (let ((epoch-after (repl-eval-tool-connection-epoch tool)))
          (is = (1+ epoch-before) epoch-after))))))
