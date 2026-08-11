;;;; tests/attach/wire-cross-process-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Cross-process regression guard for the Slynk wire-serialization class.
;;;;
;;;; The injected forms that attached code-intel verbs ship over the wire have
;;;; repeatedly killed the connection when they carried something the *remote*
;;;; reader could not read back:
;;;;   - a SIMPLE-BASE-STRING (jzon / format / native-namestring return these on
;;;;     SBCL) printing as #A((N) BASE-CHAR ...) under *print-readably*; and
;;;;   - a symbol interned in one of dsmr-mcp's own internal packages (e.g. a
;;;;     handler-case error var left as a bare DSMR-MCP/SRC/...::E).
;;;; Both surface as SLIME-NETWORK-ERROR -> a NETWORK_ERROR envelope.
;;;;
;;;; The in-process slynk fixture (with-temporary-slynk-listener) structurally
;;;; CANNOT catch this class: the listener runs inside the test image, so it
;;;; shares the dispatcher's package namespace and readtable.  A base-string
;;;; round-trips on the same SBCL reader, and an internal-package symbol reads
;;;; fine because the package is present.  Only a genuinely foreign image —
;;;; a separate SBCL that has never loaded dsmr-mcp — exercises the real
;;;; read-back path.  This test spawns exactly that: a throwaway SBCL running
;;;; only CL + slynk + alexandria, then drives every attached code-intel verb
;;;; against it and asserts the wire round-tripped (no NETWORK_ERROR).
;;;;
;;;; cl-mcp solved the same class at its wire boundary (sanitize helpers in
;;;; cl-mcp/src/attach.lisp); dsmr-mcp's equivalent is coerce-wire-strings in
;;;; src/wire-strings.lisp, applied by bounded-slime-eval.  This test is the
;;;; cross-process proof that the chokepoint actually holds against a foreign
;;;; reader, not just an in-image one.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/integration/attach/wire-cross-process-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/integration/attach/wire-cross-process-test
  (:use #:cl #:zebra)
  (:import-from #:dsmr-mcp/src/attach/dispatch
                #:repl-eval-tool-slynk-conn
                #:%dispatch-attach)
  (:import-from #:dsmr-mcp/src/tools/code-find
                #:%dispatch-attach-code-find)
  (:import-from #:dsmr-mcp/src/tools/code-describe
                #:%dispatch-attach-code-describe)
  (:import-from #:dsmr-mcp/src/tools/code-find-references
                #:%dispatch-attach-code-find-references)
  (:import-from #:dsmr-mcp/src/state
                #:make-session
                #:*current-session-id*
                #:get-tool-instance)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:make-ht)
  (:import-from #:slynk-client
                #:slime-connect
                #:slime-close)
  (:import-from #:dsmr-mcp/tests/support/bounded-eval
                #:eval-in-image)
  (:import-from #:dsmr-mcp/tests/integration/support
                #:with-foreign-slynk-child-or-skip))

(in-package #:dsmr-mcp/tests/integration/attach/wire-cross-process-test)

;;; ---------------------------------------------------------------------------
;;; This test forks a foreign SBCL that quickloads slynk + alexandria, so it
;;; wraps its body in WITH-FOREIGN-SLYNK-CHILD-OR-SKIP: it runs only when a fresh
;;; child can actually quickload those systems, and skips cleanly otherwise (see
;;; tests/integration/support.lisp). Once that guard passes, an unreachable child
;;; (a lost port-rebind race, a dropped wire) is a genuine failure, not a skip —
;;; with-foreign-slynk-image surfaces it as an error with the child's log tail.
;;; ---------------------------------------------------------------------------

;;; ---------------------------------------------------------------------------
;;; Foreign-image launcher
;;; ---------------------------------------------------------------------------

(defun %free-tcp-port ()
  "Bind an OS-assigned loopback port, read it back, release it, return it.
There is a small race between releasing the socket and the child rebinding it.
The connect loop covers only the benign case where the child loses the rebind
race and retries (a transient EADDRINUSE just costs a retry); it does NOT cover
the case where an unrelated process grabs the just-released port first — then
the test connects to the wrong server, and the (is = 3 (slime-eval '(+ 1 2)))
sanity check is the only thing that catches the mismatch."
  (let ((listener (usocket:socket-listen "127.0.0.1" 0 :reuse-address t)))
    (unwind-protect (usocket:get-local-port listener)
      (usocket:socket-close listener))))

(defun %child-eval-forms (port)
  "Return the --eval program for the foreign image: load quicklisp if present,
quickload slynk + alexandria (alexandria gives a real library symbol with a
physical source file for code-find to locate), start a Slynk server on PORT,
then block so the image stays up until the parent terminates it.  Foreign
package symbols are reached via read-from-string so the forms never fail to
READ before their package exists."
  (list
   "--eval" "(require :asdf)"
   "--eval" (concatenate 'string
                         "(let ((q (merge-pathnames \"quicklisp/setup.lisp\""
                         " (user-homedir-pathname))))"
                         " (when (and (probe-file q) (not (find-package :ql)))"
                         " (load q)))")
   "--eval" "(funcall (read-from-string \"ql:quickload\") (list :slynk :alexandria) :silent t)"
   "--eval" (format nil "(funcall (read-from-string \"slynk:create-server\") :port ~D :dont-close t)"
                    port)
   "--eval" "(loop (sleep 3600))"))

(defmacro with-foreign-slynk-image ((conn-var) &body body)
  "Spawn a throwaway SBCL running only CL + slynk + alexandria, connect a
slynk-client to it, bind CONN-VAR, run BODY, then always tear down: close the
client connection, terminate the child, and reap it.

If the child cannot be reached, signals an error whose report includes the tail
of the child's captured output so an environment problem (no Quicklisp, slynk
unavailable) is diagnosable rather than a bare timeout."
  (let ((port    (gensym "PORT-"))
        (out      (gensym "OUT-"))
        (proc     (gensym "PROC-"))
        (conn-tmp (gensym "CONN-"))
        (tries    (gensym "TRIES-"))
        (i        (gensym "I-")))
    `(let* ((,port (%free-tcp-port))
            (,out  (uiop:tmpize-pathname
                    (merge-pathnames "dsmr-wire-xproc.log"
                                     (uiop:temporary-directory))))
            (,proc (uiop:launch-program
                    (list* (uiop:native-namestring sb-ext:*runtime-pathname*)
                           "--noinform" "--disable-debugger"
                           (%child-eval-forms ,port))
                    :output ,out :error-output ,out))
            (,conn-tmp nil)
            (,tries 160))
       (unwind-protect
            (progn
              ;; Retry connect; bail early (with the child's log) if it died.
              (dotimes (,i ,tries)
                (when (and (uiop:process-alive-p ,proc)
                           (setf ,conn-tmp
                                 (ignore-errors (slime-connect "127.0.0.1" ,port))))
                  (return))
                (unless (uiop:process-alive-p ,proc)
                  (return))
                (sleep 0.25))
              (unless ,conn-tmp
                (error "with-foreign-slynk-image: could not reach foreign Slynk ~
on 127.0.0.1:~D after ~,1Fs (child alive: ~A).~%--- child output tail ---~%~A"
                       ,port (* ,tries 0.25)
                       (uiop:process-alive-p ,proc)
                       (ignore-errors
                        (let ((s (uiop:read-file-string ,out)))
                          (subseq s (max 0 (- (length s) 2000)))))))
              (let ((,conn-var ,conn-tmp))
                ,@body))
         (ignore-errors (when ,conn-tmp (slime-close ,conn-tmp)))
         (ignore-errors (uiop:terminate-process ,proc :urgent t))
         (ignore-errors (uiop:wait-process ,proc))
         (ignore-errors (delete-file ,out))))))

;;; ---------------------------------------------------------------------------
;;; Session / tool wiring
;;; ---------------------------------------------------------------------------

(defun %attach-repl-tool (id conn)
  "Make a test session bound as current, return its repl-eval tool instance with
CONN installed as the cached connection — the same object the real code-intel
tool-handle methods pass to their %dispatch-attach-* functions."
  (let* ((*current-session-id* id)
         (session (make-session :id id :slynk-attach "127.0.0.1:1"))
         (tool    (get-tool-instance session "repl-eval")))
    (setf (repl-eval-tool-slynk-conn tool) conn)
    tool))

(defun %network-error-p (envelope)
  "True when ENVELOPE is the NETWORK_ERROR shape a dropped wire produces."
  (and (hash-table-p envelope)
       (equal "NETWORK_ERROR" (gethash "error_type" envelope))))

(defun %content-text (envelope)
  "Concatenate the text of every content block in ENVELOPE (empty string if none)."
  (let ((blocks (and (hash-table-p envelope) (gethash "content" envelope))))
    (with-output-to-string (s)
      (when (vectorp blocks)
        (loop for b across blocks
              for txt = (and (hash-table-p b) (gethash "text" b))
              when (stringp txt) do (write-string txt s))))))

;;; ---------------------------------------------------------------------------
;;; The regression
;;;
;;; alexandria:flatten is the probe target: it lives in a foreign image that has
;;; never loaded dsmr-mcp, and it has a real physical source file.  Each verb's
;;; injected form must READ cleanly on that foreign image and the reply must READ
;;; cleanly back here.  A reintroduced base-string or internal-package symbol in
;;; any %build-*-form drops the connection -> NETWORK_ERROR -> these fail.
;;; ---------------------------------------------------------------------------

(define-test wire-survives-foreign-reader
  "Every attached code-intel verb round-trips against a foreign Slynk image."
  (with-foreign-slynk-child-or-skip
    (with-foreign-slynk-image (conn)
      ;; Sanity: the foreign image evaluates a trivial form (proves the link).
      (is = 3 (eval-in-image '(+ 1 2) conn :label "foreign wire link probe"))
      (is equal "ALEXANDRIA"
          (eval-in-image '(package-name (symbol-package 'alexandria:flatten)) conn
                         :label "foreign library symbol probe"))

      ;; repl-eval: a base-string-producing expression must survive the round-trip.
      (let* ((tool (%attach-repl-tool "xproc-repl" conn))
             (res  (%dispatch-attach tool (make-ht "code" "(format nil \"~A\" (list 1 2 3))"))))
        (false (%network-error-p res) "repl-eval dropped the wire (NETWORK_ERROR)")
        (false (gethash "isError" res) "repl-eval returned isError")
        (true  (search "(1 2 3)" (%content-text res))
               "repl-eval lost the base-string value across the wire"))

      ;; code-find: locate a foreign library symbol with a physical source file.
      (let* ((tool (%attach-repl-tool "xproc-find" conn))
             (res  (%dispatch-attach-code-find
                    tool 1 (make-ht "symbol" "flatten" "package" "ALEXANDRIA") nil)))
        (false (%network-error-p res) "code-find dropped the wire (NETWORK_ERROR)")
        (false (gethash "isError" res) "code-find returned isError for a known symbol")
        (true  (search "alexandria" (string-downcase (%content-text res)))
               "code-find did not return alexandria's source location"))

      ;; code-describe: same target, different injected form.  The bare symbol with
      ;; a separate package arg also guards describe's package-resolution: the
      ;; builder must qualify the describe name with the package, since
      ;; slynk:describe-symbol resolves in the foreign image's CL-USER where bare
      ;; "flatten" is not visible.
      (let* ((tool (%attach-repl-tool "xproc-describe" conn))
             (res  (%dispatch-attach-code-describe
                    tool 1 (make-ht "symbol" "flatten" "package" "ALEXANDRIA") nil)))
        (false (%network-error-p res) "code-describe dropped the wire (NETWORK_ERROR)")
        (false (gethash "isError" res)
               "code-describe could not resolve a known symbol via its package arg")
        (true  (plusp (length (%content-text res))) "code-describe returned empty content"))

      ;; code-find-references: who-calls form; may be empty, must not drop the wire.
      (let* ((tool (%attach-repl-tool "xproc-refs" conn))
             (res  (%dispatch-attach-code-find-references
                    tool 1 (make-ht "symbol" "flatten" "package" "ALEXANDRIA") nil)))
        (false (%network-error-p res) "code-find-references dropped the wire (NETWORK_ERROR)")
        (true  (hash-table-p res) "code-find-references returned a malformed envelope")))))
