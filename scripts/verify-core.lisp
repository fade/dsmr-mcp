;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; scripts/verify-core.lisp
;;;;
;;;; Acceptance gate for a freshly built SBCL core image. `make core` writes the
;;;; image to a staging path and then installs it over the file that every
;;;; running MCP server has mmap'd, so a truncated or half-loaded image is not a
;;;; build failure the developer notices later - it is a live outage. A non-empty
;;;; file proves nothing about the contents, so the install is gated on booting
;;;; the staged image and asking it, from the inside, whether it is whole.
;;;;
;;;; Invocation (this is what the Makefile runs, against the STAGED path, before
;;;; the image is moved into place):
;;;;
;;;;   sbcl --core <staged-image> --noinform --disable-debugger \
;;;;        --non-interactive --load scripts/verify-core.lisp
;;;;
;;;; The script therefore runs INSIDE the image under test. It loads nothing and
;;;; quickloads nothing: every check inspects the image it is already running in.
;;;; Exit status is the contract - 0 when every check passes, non-zero when any
;;;; check fails. Results go to stdout so the build log records what was proved.
;;;;
;;;; Deliberately NOT asserted: the total number of registered verbs. Adding an
;;;; MCP verb is routine and must not turn the build red. The count is printed
;;;; for the log; what is asserted is that the registry is non-empty and that a
;;;; named set of verbs the server cannot function without is present. The same
;;;; reasoning applies to package and system counts.
;;;;
;;;; Everything the script touches is resolved by name at runtime via
;;;; FIND-PACKAGE / FIND-SYMBOL rather than by read-time package-qualified
;;;; symbols. A badly broken image is exactly the case where a package may be
;;;; missing, and a reader error there would abort the script with an opaque
;;;; message instead of a named failing check.

(in-package #:cl-user)

(require :asdf)

;;; Result accumulation ------------------------------------------------------

(defvar *verify-core-failures* '()
  "Reversed list of failure description strings recorded by VERIFY-CORE-CHECK.")

(defvar *verify-core-passes* 0
  "Count of checks that passed, for the closing summary line.")

(defun verify-core-note (fmt &rest args)
  "Print an informational line to stdout, tagged like the build script's output."
  (format t "~&[verify-core] ~?~%" fmt args)
  (finish-output))

(defun verify-core-check (label thunk)
  "Run THUNK and report the result of the check named LABEL.

THUNK returns two values: a generalized boolean for pass/fail, and a detail
string describing what was found. A pass prints the detail as context; a
failure prints it as the reason and records the check in *VERIFY-CORE-FAILURES*.
An error signalled inside THUNK is itself a failure - a check that cannot even
run has not passed."
  (multiple-value-bind (ok detail)
      (handler-case (funcall thunk)
        (error (e)
          (values nil (format nil "signalled ~A: ~A" (type-of e) e))))
    (if ok
        (progn
          (incf *verify-core-passes*)
          (format t "~&[verify-core] PASS  ~A~@[ (~A)~]~%" label detail))
        (progn
          (push (format nil "~A: ~A" label (or detail "no detail"))
                *verify-core-failures*)
          (format t "~&[verify-core] FAIL  ~A~@[ - ~A~]~%" label detail)))
    (finish-output)
    ok))

(defmacro verify-core-checking (label &body body)
  "Sugar for VERIFY-CORE-CHECK over BODY, which returns (values ok detail)."
  `(verify-core-check ,label (lambda () ,@body)))

;;; Name resolution helpers --------------------------------------------------

(defun verify-core-symbol (package name)
  "Return the symbol NAME in PACKAGE, or NIL if either is absent.
Both arguments are strings in the canonical upcased reader spelling."
  (let ((pkg (find-package package)))
    (when pkg
      (multiple-value-bind (sym status) (find-symbol name pkg)
        (and status sym)))))

(defun verify-core-missing (required present-p)
  "Return the members of REQUIRED for which PRESENT-P returns false."
  (remove-if present-p required))

(defun verify-core-join (items)
  "Render ITEMS as a comma-separated string for a report line."
  (format nil "~{~A~^, ~}" items))

;;; What a whole image must contain ------------------------------------------

(defparameter *verify-core-required-systems*
  '("dsmr-mcp"
    "dsmr-mcp/src/main"
    "dsmr-mcp/src/run"
    "dsmr-mcp/src/dispatch"
    "dsmr-mcp/src/protocol"
    "dsmr-mcp/src/tools/base"
    "dsmr-mcp/src/bus/wal"
    "dsmr-mcp/tests"
    "dsmr-mcp/tests/integration")
  "ASDF systems that must be registered in the image.

ASDF:REGISTERED-SYSTEM is used rather than ASDF:ALREADY-LOADED-SYSTEMS or
ASDF:FIND-SYSTEM on purpose. ALREADY-LOADED-SYSTEMS does not survive
SAVE-LISP-AND-DIE for the systems loaded during the build itself, so it reports
a false negative on a perfectly good image. FIND-SYSTEM would reach out to the
.asd on disk and succeed even if nothing had been loaded, which is the false
positive this gate exists to catch. REGISTERED-SYSTEM answers purely from the
in-image registry, which is what the question actually is.

The test systems are here because the core is also what `make test` runs
against; an image without them is not the artifact the Makefile promises.")

(defparameter *verify-core-required-packages*
  '("DSMR-MCP"
    "DSMR-MCP/SRC/MAIN"
    "DSMR-MCP/SRC/RUN"
    "DSMR-MCP/SRC/DISPATCH"
    "DSMR-MCP/SRC/PROTOCOL"
    "DSMR-MCP/SRC/STATE"
    "DSMR-MCP/SRC/TOOLS/BASE"
    "DSMR-MCP/SRC/TRANSPORT/STDIO"
    "DSMR-MCP/SRC/HERMETIC/POOL"
    "DSMR-MCP/SRC/ATTACH/CONNECTION"
    "DSMR-MCP/SRC/BUS/WAL"
    "DSMR-MCP/SRC/BUS/AGENT"
    "DSMR-MCP/SRC/BUS/ENVELOPE"
    "DSMR-MCP/SRC/BUS/BROKER"
    "DSMR-MCP/SRC/CODE-CORE"
    "CLOSER-MOP"
    "ZEBRA")
  "Packages that must exist, spanning every major subsystem plus the two
foreign libraries the image cannot work without: closer-mop drives the tool
metaclass and zebra runs the suites.")

(defparameter *verify-core-required-verbs*
  '("repl-eval"
    "load-system"
    "run-tests"
    "fs-read-file"
    "fs-write-file"
    "fs-set-project-root"
    "code-find"
    "lisp-edit-form"
    "bus-publish"
    "bus-receive"
    "bus-status")
  "MCP verbs that must be registered by name. A representative verb from each
tool family, not the full set: the registry total is reported but never
asserted, so adding a verb cannot break the build.")

(defparameter *verify-core-required-functions*
  '(("DSMR-MCP" . "RUN")
    ("DSMR-MCP" . "PROCESS-JSON-LINE")
    ("DSMR-MCP" . "MAKE-SESSION")
    ("DSMR-MCP" . "VERSION")
    ("DSMR-MCP/SRC/BUS/ENVELOPE" . "AUTHOR-DISPLAY")
    ("DSMR-MCP/SRC/BUS/ENVELOPE" . "SPLIT-AGENT-ID")
    ("DSMR-MCP/SRC/BUS/ENVELOPE" . "DECODE-ID")
    ("DSMR-MCP/SRC/BUS/AGENT" . "DELIVERY-AUTHOR")
    ("DSMR-MCP/SRC/BUS/AGENT" . "AGENT-RECEIVE-DETAILED"))
  "Entry points that must be FBOUND. A package can exist with none of its
definitions in it if a file was compiled but never finished loading, so the
package checks alone are not enough.")

;;; Checks -------------------------------------------------------------------

(defun verify-core-check-systems ()
  (verify-core-checking "ASDF systems registered"
    (let* ((missing (verify-core-missing
                     *verify-core-required-systems*
                     (lambda (name) (and (asdf:registered-system name) t))))
           (total 0))
      (maphash (lambda (key value)
                 (declare (ignore value))
                 (when (and (stringp key)
                            (>= (length key) 8)
                            (string= "dsmr-mcp" key :end2 8))
                   (incf total)))
               asdf/system-registry:*registered-systems*)
      (if missing
          (values nil (format nil "not registered: ~A" (verify-core-join missing)))
          (values t (format nil "~D of ~D required; ~D dsmr-mcp systems in registry"
                            (length *verify-core-required-systems*)
                            (length *verify-core-required-systems*)
                            total))))))

(defun verify-core-check-packages ()
  (verify-core-checking "packages present"
    (let ((missing (verify-core-missing *verify-core-required-packages*
                                        (lambda (name) (and (find-package name) t)))))
      (if missing
          (values nil (format nil "missing: ~A" (verify-core-join missing)))
          (values t (format nil "~D required; ~D packages in image"
                            (length *verify-core-required-packages*)
                            (length (list-all-packages))))))))

(defun verify-core-tool-registry ()
  "Return the *TOOL-CLASSES* hash-table, or NIL if it is not in the image."
  (let ((sym (verify-core-symbol "DSMR-MCP/SRC/TOOLS/BASE" "*TOOL-CLASSES*")))
    (when (and sym (boundp sym))
      (let ((value (symbol-value sym)))
        (when (hash-table-p value) value)))))

(defun verify-core-check-registry-populated ()
  (verify-core-checking "verb registry non-empty"
    (let ((registry (verify-core-tool-registry)))
      (cond ((null registry)
             (values nil "DSMR-MCP/SRC/TOOLS/BASE:*TOOL-CLASSES* is absent or not a hash-table"))
            ((zerop (hash-table-count registry))
             (values nil "registry holds zero verbs"))
            (t
             ;; Informational, never asserted: a new verb must not fail the build.
             (values t (format nil "~D verbs registered" (hash-table-count registry))))))))

(defun verify-core-check-required-verbs ()
  (verify-core-checking "essential verbs registered"
    (let ((registry (verify-core-tool-registry)))
      (if (null registry)
          (values nil "no verb registry to inspect")
          (let ((missing (verify-core-missing
                          *verify-core-required-verbs*
                          (lambda (name) (and (gethash name registry) t)))))
            (if missing
                (values nil (format nil "not registered: ~A" (verify-core-join missing)))
                (values t (format nil "all ~D present" (length *verify-core-required-verbs*)))))))))

(defun verify-core-check-verbs-answer ()
  "Every registered verb must answer the tool protocol from its class prototype.

A name key in the registry only proves a DEFCLASS form was read. Taking the
class prototype forces CLOS finalization and reading the class-allocated name,
description and input-schema slots proves the tool file finished loading and
that its schema literal is intact - the part a truncated image loses."
  (verify-core-checking "registered verbs answer name/description/schema"
    (let ((registry (verify-core-tool-registry))
          (prototype (verify-core-symbol "CLOSER-MOP" "CLASS-PROTOTYPE"))
          (tool-name (verify-core-symbol "DSMR-MCP/SRC/TOOLS/BASE" "TOOL-NAME"))
          (tool-description (verify-core-symbol "DSMR-MCP/SRC/TOOLS/BASE" "TOOL-DESCRIPTION"))
          (tool-schema (verify-core-symbol "DSMR-MCP/SRC/TOOLS/BASE" "TOOL-INPUT-SCHEMA")))
      (cond
        ((null registry) (values nil "no verb registry to inspect"))
        ((zerop (hash-table-count registry))
         ;; Not a vacuous pass: an empty registry is the half-loaded case, and a
         ;; green line here would read as though the verbs had been examined.
         (values nil "registry holds zero verbs to examine"))
        ((not (and prototype tool-name tool-description tool-schema))
         (values nil "tool protocol generic functions or closer-mop are missing"))
        (t
         (let ((broken '())
               (checked 0))
           (maphash
            (lambda (name class)
              (incf checked)
              (handler-case
                  (let* ((proto (funcall prototype class))
                         (reported (funcall tool-name proto))
                         (description (funcall tool-description proto))
                         (schema (funcall tool-schema proto)))
                    (unless (and (stringp reported)
                                 (string= reported name)
                                 (stringp description)
                                 (plusp (length description))
                                 schema)
                      (push name broken)))
                (error (e)
                  (push (format nil "~A (~A)" name (type-of e)) broken))))
            registry)
           (if broken
               (values nil (format nil "~D of ~D incomplete: ~A"
                                   (length broken) checked (verify-core-join broken)))
               (values t (format nil "~D verbs answered" checked)))))))))

(defun verify-core-check-functions ()
  (verify-core-checking "entry points fbound"
    (let ((missing (verify-core-missing
                    *verify-core-required-functions*
                    (lambda (spec)
                      (let ((sym (verify-core-symbol (car spec) (cdr spec))))
                        (and sym (fboundp sym) t))))))
      (if missing
          (values nil (format nil "not fbound: ~A"
                              (verify-core-join
                               (mapcar (lambda (spec)
                                         (format nil "~A:~A" (car spec) (cdr spec)))
                                       missing))))
          (values t (format nil "all ~D present"
                            (length *verify-core-required-functions*)))))))

(defun verify-core-check-version ()
  (verify-core-checking "version string readable"
    (let ((sym (verify-core-symbol "DSMR-MCP" "VERSION")))
      (if (and sym (fboundp sym))
          (let ((version (funcall sym)))
            (if (and (stringp version) (plusp (length version)))
                (values t version)
                (values nil (format nil "VERSION returned ~S" version))))
          (values nil "DSMR-MCP:VERSION is not fbound")))))

;;; Driver -------------------------------------------------------------------

(defun verify-core-run ()
  ;; *core-pathname* names the image actually running, which during `make core`
  ;; is the staged file rather than the installed one. Reporting it keeps the
  ;; build log honest about which artifact was verified.
  (verify-core-note "verifying image: ~A"
                    (or (ignore-errors (namestring sb-ext:*core-pathname*))
                        "unknown"))
  (verify-core-note "sbcl ~A" (lisp-implementation-version))
  (verify-core-check-systems)
  (verify-core-check-packages)
  (verify-core-check-registry-populated)
  (verify-core-check-required-verbs)
  (verify-core-check-verbs-answer)
  (verify-core-check-functions)
  (verify-core-check-version)
  (let ((failures (nreverse *verify-core-failures*)))
    (if failures
        (progn
          (format t "~&[verify-core] ~D passed, ~D FAILED - image rejected~%"
                  *verify-core-passes* (length failures))
          (dolist (failure failures)
            (format t "[verify-core]   ~A~%" failure)))
        (format t "~&[verify-core] ~D passed, 0 failed - image accepted~%"
                *verify-core-passes*))
    (finish-output *standard-output*)
    (finish-output *error-output*)
    ;; The exit code is the whole contract with the Makefile, which branches on
    ;; it to decide whether to install this image over a file that live servers
    ;; have mapped. :abort t skips unwinding and exit hooks so nothing downstream
    ;; can turn a rejection back into a success.
    (sb-ext:exit :code (if failures 1 0) :abort t)))

(verify-core-run)
