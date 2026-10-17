;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; scripts/verify-core-worker.lisp
;;;;
;;;; Acceptance gate for a freshly built worker core image. `make core-worker`
;;;; writes the image to a staging path and installs it only after this script,
;;;; run INSIDE the staged image, says the image is the one workers should boot
;;;; from. A non-empty file proves nothing about the contents.
;;;;
;;;; Invocation (this is what the Makefile runs, against the STAGED path, before
;;;; the image is moved into place):
;;;;
;;;;   sbcl --core <staged-image> --noinform --disable-debugger \
;;;;        --non-interactive --no-userinit --load scripts/verify-core-worker.lisp
;;;;
;;;; What a worker image must be, and therefore what is asserted:
;;;;
;;;;   - it holds the worker entry point and its method table, so a worker can
;;;;     reach its handshake without loading anything;
;;;;   - it can save a worker's world to a core and come back from one: the
;;;;     resume entry point is there and a worker server answers the save method;
;;;;   - it holds no test systems and no test framework, because a worker image
;;;;     that carried them would carry them into every image a worker saves;
;;;;   - it holds no setting taken from the build host's environment, because a
;;;;     worker reads its timeouts from its own environment when it starts, and a
;;;;     value frozen at build time would silently win over the one it was given;
;;;;   - it holds Quicklisp and can still find a Quicklisp system, so a worker
;;;;     asked to load one is not stranded.
;;;;
;;;; Package and system counts are printed for the build log and never asserted,
;;;; so a new dependency cannot turn the build red.
;;;;
;;;; Exit status is the contract: 0 when every check passes, non-zero when any
;;;; check fails. Everything is resolved by name at run time with FIND-PACKAGE and
;;;; FIND-SYMBOL, so an image missing a package fails a named check instead of
;;;; dying on a reader error.

(in-package #:cl-user)

(require :asdf)

;;; Result accumulation ------------------------------------------------------

(defvar *verify-core-failures* '()
  "Reversed list of failure description strings recorded by VERIFY-CORE-CHECK.")

(defvar *verify-core-passes* 0
  "Count of checks that passed, for the closing summary line.")

(defun verify-core-note (fmt &rest args)
  "Print an informational line to stdout, tagged with this script's prefix."
  (format t "~&[verify-core-worker] ~?~%" fmt args)
  (finish-output))

(defun verify-core-check (label thunk)
  "Run THUNK and report the result of the check named LABEL.

THUNK returns two values: a generalized boolean for pass/fail, and a detail
string describing what was found. A pass prints the detail as context; a
failure prints it as the reason and records the check in *VERIFY-CORE-FAILURES*.
An error signalled inside THUNK is itself a failure: a check that cannot even
run has not passed."
  (multiple-value-bind (ok detail)
      (handler-case (funcall thunk)
        (error (e)
          (values nil (format nil "signalled ~A: ~A" (type-of e) e))))
    (if ok
        (progn
          (incf *verify-core-passes*)
          (format t "~&[verify-core-worker] PASS  ~A~@[ (~A)~]~%" label detail))
        (progn
          (push (format nil "~A: ~A" label (or detail "no detail"))
                *verify-core-failures*)
          (format t "~&[verify-core-worker] FAIL  ~A~@[ - ~A~]~%" label detail)))
    (finish-output)
    ok))

(defmacro verify-core-checking (label &body body)
  "Sugar for VERIFY-CORE-CHECK over BODY, which returns (values ok detail)."
  `(verify-core-check ,label (lambda () ,@body)))

;;; Name resolution helpers --------------------------------------------------

(defparameter *verify-core-worker-main* "DSMR-MCP/SRC/HERMETIC/WORKER/MAIN")
(defparameter *verify-core-worker-handlers* "DSMR-MCP/SRC/HERMETIC/WORKER/HANDLERS")
(defparameter *verify-core-worker-client* "DSMR-MCP/SRC/HERMETIC/WORKER-CLIENT")

(defparameter *verify-core-worker-hibernate* "DSMR-MCP/SRC/HERMETIC/WORKER/HIBERNATE")

(defparameter *verify-core-worker-server* "DSMR-MCP/SRC/HERMETIC/WORKER/SERVER")

(defparameter *verify-core-worker-registry* "DSMR-MCP/SRC/HERMETIC/WORKER/REGISTRY")

(defun verify-core-symbol (package name)
  "Return the symbol NAME in PACKAGE, or NIL if either is absent.
Both arguments are strings in the canonical upcased reader spelling."
  (let ((pkg (find-package package)))
    (when pkg
      (multiple-value-bind (sym status) (find-symbol name pkg)
        (and status sym)))))

(defun verify-core-fbound-check (label package name)
  "Check that NAME in PACKAGE names a function."
  (verify-core-checking label
    (let ((sym (verify-core-symbol package name)))
      (cond ((null (find-package package))
             (values nil (format nil "package ~A is absent" package)))
            ((null sym)
             (values nil (format nil "~A:~A is absent" package name)))
            ((not (fboundp sym))
             (values nil (format nil "~A:~A is not fbound" package name)))
            (t (values t (format nil "~A:~A" package name)))))))

(defun verify-core-unset-check (label package names)
  "Check that every symbol in NAMES (strings) in PACKAGE is bound to NIL.

These are the settings a worker reads from its own environment when it starts.
NIL in the image means nothing from the build host's environment was frozen in;
a missing symbol is a failure too, since the check would otherwise pass on an
image that does not hold the worker at all."
  (verify-core-checking label
    (let ((problems '()))
      (dolist (name names)
        (let ((sym (verify-core-symbol package name)))
          (cond ((null sym)
                 (push (format nil "~A:~A is absent" package name) problems))
                ((not (boundp sym))
                 (push (format nil "~A:~A is unbound" package name) problems))
                ((symbol-value sym)
                 (push (format nil "~A:~A holds ~S" package name (symbol-value sym))
                       problems)))))
      (if problems
          (values nil (format nil "~{~A~^; ~}" (nreverse problems)))
          (values t (format nil "~{~A~^, ~} NIL" names))))))

;;; Checks -------------------------------------------------------------------

(defun verify-core-check-entry-point ()
  (verify-core-fbound-check "worker entry point fbound"
                            *verify-core-worker-main* "START"))

(defun verify-core-check-handlers ()
  (verify-core-fbound-check "worker method table installer fbound"
                            *verify-core-worker-handlers* "REGISTER-ALL-HANDLERS"))

(defun verify-core-check-hibernate-wiring ()
  "A worker image must be able to save itself and come back: the resume entry
point, the method installer and the save handler are fbound, and a server
given the worker's methods over a fresh object registry answers the method
that saves it."
  (verify-core-fbound-check "worker resume entry point fbound"
                            *verify-core-worker-main* "RESUME")
  (verify-core-fbound-check "worker method installer fbound"
                            *verify-core-worker-main* "REGISTER-WORKER-METHODS")
  (verify-core-fbound-check "worker save handler fbound"
                            *verify-core-worker-hibernate* "HANDLE-HIBERNATE")
  (verify-core-checking "worker/hibernate registered on a worker server"
    (let ((make-server (verify-core-symbol *verify-core-worker-server*
                                           "MAKE-WORKER-SERVER"))
          (stop (verify-core-symbol *verify-core-worker-server* "STOP-SERVER"))
          (methods (verify-core-symbol *verify-core-worker-server*
                                       "WORKER-SERVER-METHODS"))
          (install (verify-core-symbol *verify-core-worker-main*
                                       "REGISTER-WORKER-METHODS"))
          (make-registry (verify-core-symbol *verify-core-worker-registry*
                                             "MAKE-OBJECT-REGISTRY")))
      (if (notevery (lambda (s) (and s (fboundp s)))
                    (list make-server stop methods install make-registry))
          (values nil "a function needed to build a worker server is absent")
          (let ((server (funcall make-server)))
            (unwind-protect
                 (progn
                   (funcall install server (funcall make-registry))
                   (if (gethash "worker/hibernate" (funcall methods server))
                       (values t (format nil "~D methods"
                                         (hash-table-count (funcall methods server))))
                       (values nil "worker/hibernate is not in the method table")))
              (funcall stop server)))))))

(defun verify-core-check-no-test-systems ()
  (verify-core-checking "no test packages in image"
    (let ((test-packages
            (loop for pkg in (list-all-packages)
                  for name = (package-name pkg)
                  when (and (>= (length name) 14)
                            (string= "DSMR-MCP/TESTS" name :end2 14))
                    collect name)))
      (if test-packages
          (values nil (format nil "~D present, first ~A"
                              (length test-packages) (first test-packages)))
          (values t (format nil "~D packages in image" (length (list-all-packages))))))))

(defun verify-core-check-no-test-framework ()
  (verify-core-checking "no test framework in image"
    (if (find-package "ZEBRA")
        (values nil "package ZEBRA is present")
        (values t "ZEBRA absent"))))

(defun verify-core-check-eval-timeout-unset ()
  (verify-core-unset-check "eval timeout not baked in"
                           *verify-core-worker-handlers*
                           '("*DEFAULT-EVAL-TIMEOUT*" "*RESOLVED-EVAL-TIMEOUT*")))

(defun verify-core-check-startup-timeout-unset ()
  (verify-core-unset-check "startup timeout not baked in"
                           *verify-core-worker-client*
                           '("*WORKER-STARTUP-TIMEOUT*"
                             "*RESOLVED-WORKER-STARTUP-TIMEOUT*")))

(defun verify-core-check-quicklisp ()
  (verify-core-checking "Quicklisp present"
    (if (find-package "QUICKLISP")
        (values t "package QUICKLISP present")
        (values nil "package QUICKLISP is absent"))))

(defun verify-core-check-quicklisp-system-findable ()
  (verify-core-checking "a Quicklisp system can be found"
    (let ((system (asdf:find-system "alexandria" nil)))
      (if system
          (values t (format nil "alexandria at ~A"
                            (or (ignore-errors
                                 (namestring (asdf:system-source-directory system)))
                                "unknown")))
          (values nil "asdf:find-system \"alexandria\" returned NIL")))))

;;; Driver -------------------------------------------------------------------

(defun verify-core-run ()
  ;; *core-pathname* names the image actually running, which during
  ;; `make core-worker` is the staged file rather than the installed one.
  (verify-core-note "verifying image: ~A"
                    (or (ignore-errors (namestring sb-ext:*core-pathname*))
                        "unknown"))
  (verify-core-note "sbcl ~A" (lisp-implementation-version))
  (verify-core-check-entry-point)
  (verify-core-check-handlers)
  (verify-core-check-hibernate-wiring)
  (verify-core-check-no-test-systems)
  (verify-core-check-no-test-framework)
  (verify-core-check-eval-timeout-unset)
  (verify-core-check-startup-timeout-unset)
  (verify-core-check-quicklisp)
  (verify-core-check-quicklisp-system-findable)
  (let ((failures (nreverse *verify-core-failures*)))
    (if failures
        (progn
          (format t "~&[verify-core-worker] ~D passed, ~D FAILED - image rejected~%"
                  *verify-core-passes* (length failures))
          (dolist (failure failures)
            (format t "[verify-core-worker]   ~A~%" failure)))
        (format t "~&[verify-core-worker] ~D passed, 0 failed - image accepted~%"
                *verify-core-passes*))
    (finish-output *standard-output*)
    (finish-output *error-output*)
    ;; The exit code is the whole contract with the Makefile, which installs the
    ;; image only on 0. :abort t skips unwinding and exit hooks so nothing
    ;; downstream can turn a rejection back into a success.
    (sb-ext:exit :code (if failures 1 0) :abort t)))

(verify-core-run)
