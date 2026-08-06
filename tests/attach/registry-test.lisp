;;;; tests/attach/registry-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Integration tests for the image-resident attached object registry.
;;;; Covers result_object_id minting, survival across calls, session
;;;; isolation, register_result gating, and epoch invalidation on
;;;; connection drop.
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
  (:use #:cl #:zebra)
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
  (:import-from #:dsmr-mcp/tests/support/bounded-eval
                #:eval-in-image))

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

;;; result_object_id present for inspectable results -------------------------

(define-test result-object-id-present
  "A repl-eval returning a CLOS instance puts a non-nil result_object_id
string in the response envelope. Primitives (numbers) must NOT produce one."
  (with-temporary-slynk-listener (conn)
    ;; Ensure a throwaway CLOS class is available in the attached image.
    ;; The class must be defined in CL-USER so that code strings read in the
    ;; default CL-USER package can reference it without a package qualifier.
    ;; Using cl-user:: here ensures the symbol is interned in CL-USER at
    ;; test-file read time, matching where the wrap-form reader will look.
    (eval-in-image '(progn
                     (unless (find-class 'cl-user::test-registry-widget nil)
                       (defclass cl-user::test-registry-widget
                           () ((val :initarg :val :initform 0))))
                     nil)
                   conn
                   :label "result-object-id-present fixture class")
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

;;; IDs survive across sequential calls ---------------------------------------

(define-test ids-survive-across-calls
  "Two sequential repl-eval calls in the same session each return a distinct
result_object_id. Both underlying raw IDs remain look-up-able in the image table."
  (with-temporary-slynk-listener (conn)
    (eval-in-image '(progn
                     (unless (find-class 'cl-user::test-registry-widget nil)
                       (defclass cl-user::test-registry-widget
                           () ((val :initarg :val :initform 0))))
                     nil)
                   conn
                   :label "ids-survive-across-calls fixture class")
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

;;; Session isolation between sessions ----------------------------------------

(define-test session-isolation
  "An ID minted by session A, when looked up with session B's session-id,
resolves to :object-not-found — never another session's object."
  (with-temporary-slynk-listener (conn)
    (eval-in-image '(progn
                     (unless (find-class 'cl-user::test-registry-widget nil)
                       (defclass cl-user::test-registry-widget
                           () ((val :initarg :val :initform 0))))
                     nil)
                   conn
                   :label "session-isolation fixture class")
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
               ;; reason as ids-survive-across-calls: slime-eval
               ;; after %dispatch-attach on the same conn can deadlock under
               ;; the BT condition-wait path.
               (lookup-result  (eval isolation-form)))
          ;; Must get :object-not-found — not the actual object.
          (is eq :object-not-found lookup-result))))))

;;; register_result false suppresses the id -----------------------------------

(define-test register-result-false-suppresses-id
  "When register_result is false in the params, result_object_id must be absent
from the response, even for an inspectable (CLOS) result."
  (with-temporary-slynk-listener (conn)
    (eval-in-image '(progn
                     (unless (find-class 'cl-user::test-registry-widget nil)
                       (defclass cl-user::test-registry-widget
                           () ((val :initarg :val :initform 0))))
                     nil)
                   conn
                   :label "register-result-false-suppresses-id fixture class")
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

;;; Epoch invalidation on connection drop -------------------------------------

(define-test epoch-invalidation-on-drop
  "Calling drop-connection on the tool increments repl-eval-tool-connection-epoch
by exactly 1, making IDs minted before the drop carry a stale epoch."
  (with-temporary-slynk-listener (conn)
    (multiple-value-bind (session tool)
        (%make-attach-session "reg-test-epoch" conn)
      (declare (ignore session))
      (let ((epoch-before (repl-eval-tool-connection-epoch tool)))
        ;; drop-connection must bump the epoch.
        (drop-connection tool :reason "test-invalidation")
        (let ((epoch-after (repl-eval-tool-connection-epoch tool)))
          (is = (1+ epoch-before) epoch-after))))))
