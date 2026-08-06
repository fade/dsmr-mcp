;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; scripts/build-core.lisp
;;;;
;;;; Builds a prebuilt SBCL core image with dsmr-mcp, its dependencies, and the
;;;; test systems preloaded, then writes it via sb-ext:save-lisp-and-die. The
;;;; core amortizes the two dominant cold costs — the Quicklisp/ASDF load and the
;;;; system + test-leaf compile — so a warm test run starts from an image that
;;;; already holds everything and only has to run assertions.
;;;;
;;;; Run it AFTER Quicklisp's setup.lisp (the `make core` target and a dev box's
;;;; ~/.sbclrc both arrange that); the script pushes $LISP_WORKSPACE onto the
;;;; source registry the same way scripts/dev-boot.lisp does so the local
;;;; checkouts resolve. All load output goes to stderr so a caller capturing
;;;; stdout sees nothing structured.
;;;;
;;;; Single-thread constraint: save-lisp-and-die requires exactly one running
;;;; thread, so this script only LOADS systems — it never calls dsmr-mcp:run or
;;;; anything that spawns the hermetic worker pool. A bare load is single-threaded,
;;;; exactly like the bridge program-op build.
;;;;
;;;; The core is GC-safe by construction: SBCL refuses to load a --core produced
;;;; by a different build/version, so the MARK-REGION/GENCGC fasl-cache hazard
;;;; cannot apply to it.
;;;;
;;;; Output path: $DSMR_CORE_OUTPUT if set, else dsmr.core in the current
;;;; directory (matches the .gitignore entry). The file is large and is never
;;;; committed; rebuild it whenever the dependencies, the SBCL build, or the
;;;; project source change.

(in-package #:cl-user)

(require :asdf)

(defun build-core-getenv (name default)
  (let ((v (uiop:getenv name)))
    (if (and v (plusp (length v))) v default)))

;;; Defensive tilde expansion: some shells export LISP_WORKSPACE as a literal
;;; "~/..." that never expanded. Resolve a leading ~ so the registry push points
;;; at a real tree (mirrors scripts/dev-boot.lisp).
(defun build-core-expand-tilde (path)
  (if (and (plusp (length path)) (char= (char path 0) #\~))
      (namestring (merge-pathnames (subseq path 2)
                                   (user-homedir-pathname)))
      path))

(let* ((workspace (build-core-expand-tilde
                   (build-core-getenv "LISP_WORKSPACE"
                                      (namestring
                                       (merge-pathnames "SourceCode/lisp/"
                                                        (user-homedir-pathname))))))
       (workspace (uiop:ensure-directory-pathname workspace)))
  (pushnew workspace asdf:*central-registry* :test #'equal)
  (format *error-output* "~&[build-core] source-registry root: ~A~%" workspace))

;;; Load the system and the test systems, all compilation chatter on stderr.
;;; Loading dsmr-mcp/tests and dsmr-mcp/tests/integration puts zebra and
;;; every test leaf in the image, so both `make test` and `make test-integration`
;;; can run against the core without any load-system step.
(dolist (system '("dsmr-mcp" "dsmr-mcp/tests" "dsmr-mcp/tests/integration"))
  (format *error-output* "~&[build-core] loading ~A …~%" system)
  (let ((*standard-output* *error-output*))
    (asdf:load-system system)))

;;; Staleness manifest. A launch wrapper reads this (with plain shell tools, so
;;; an SBCL upgrade can't break the check) to decide whether the image is still
;;; current or must be regenerated. It records the SBCL identity plus the source
;;; root of every system the build loaded, so a patched workspace library or a
;;; Quicklisp dist update is detected the same way a project edit is.
(defun build-core-write-manifest (output)
  (let* ((project-dir (ignore-errors
                       (namestring (asdf:system-source-directory :dsmr-mcp))))
         (roots '()))
    (flet ((add (p) (when p (pushnew (namestring p) roots :test #'string=))))
      ;; Project: scan only src/ and the .asd, never the whole repo — the repo
      ;; root also holds .git, the core itself, and generated output, any of
      ;; which would otherwise trip a false "stale" on unrelated activity.
      (when project-dir
        (add (merge-pathnames "src/" project-dir))
        (add (merge-pathnames "dsmr-mcp.asd" project-dir)))
      ;; Every other loaded system contributes its source directory. Test-only
      ;; systems resolve to the project root and are skipped here on purpose:
      ;; the server core does not change behavior when only tests change.
      (dolist (name (asdf:already-loaded-systems))
        (let ((sys (asdf:find-system name nil)))
          (when sys
            (let ((dir (ignore-errors (asdf:system-source-directory sys))))
              (when (and dir
                         (not (and project-dir
                                   (string= (namestring dir) project-dir))))
                (add dir)))))))
    (let ((manifest (concatenate 'string output ".manifest")))
      (with-open-file (out manifest :direction :output :if-exists :supersede
                                    :if-does-not-exist :create)
        (format out "sbcl-version ~A~%" (lisp-implementation-version))
        (dolist (r (nreverse roots))
          (format out "root ~A~%" r)))
      (format *error-output* "~&[build-core] wrote staleness manifest ~A~%"
              manifest))))

(let ((output (build-core-getenv "DSMR_CORE_OUTPUT" "dsmr.core")))
  (build-core-write-manifest output)
  (format *error-output* "~&[build-core] saving core to ~A …~%" output)
  (finish-output *error-output*)
  ;; :purify t maps the static heap read-only (smaller, faster start). The save
  ;; terminates the process; nothing after this form runs.
  (sb-ext:save-lisp-and-die output :executable nil :purify t))
