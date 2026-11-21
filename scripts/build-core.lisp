;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; scripts/build-core.lisp
;;;;
;;;; Builds a prebuilt SBCL core image and writes it via sb-ext:save-lisp-and-die.
;;;; It builds three kinds of image, chosen by $DSMR_CORE_KIND:
;;;;
;;;;   server (the default)  dsmr-mcp, its dependencies, and the test systems.
;;;;                         The core amortizes the two dominant cold costs, the
;;;;                         Quicklisp/ASDF load and the system + test-leaf
;;;;                         compile, so a warm test run starts from an image
;;;;                         that already holds everything and only has to run
;;;;                         assertions.
;;;;
;;;;   worker                only the hermetic worker system and its
;;;;                         dependencies, plus Quicklisp so a worker can still
;;;;                         load Quicklisp systems on request. A worker booted
;;;;                         from it reaches its handshake without loading
;;;;                         anything. It deliberately holds no test systems: a
;;;;                         worker image that carried them would carry them into
;;;;                         every image a worker later saves.
;;;;
;;;;   release-server        the server a deployed release runs: the
;;;;                         dsmr-mcp/release closure, built from an exported
;;;;                         release tree and its bundled dependencies only, with
;;;;                         no Quicklisp and no test systems. Requires
;;;;                         $DSMR_RELEASE_ROOT (the release directory) and
;;;;                         $DSMR_RELEASE_COMMIT (the commit it was exported
;;;;                         from). The caller loads <root>/deps/setup.lisp first.
;;;;                         Refuses an ASDF other than 3.3.7.4, seals the
;;;;                         registry before saving, and refuses any loaded system
;;;;                         whose source lies outside the release and the SBCL
;;;;                         contrib directory.
;;;;
;;;; Any other value is an error naming the accepted ones.
;;;;
;;;; List mode: with $DSMR_CORE_SOURCES set, nothing is built. The script writes
;;;; to that file one `TARGET: PATH` line per file the image of this kind is
;;;; built from, with $DSMR_CORE_OUTPUT as TARGET, and exits 0. It finds the
;;;; systems through scripts/bus-binary-sources.lisp and never loads them. The
;;;; mode lives in this file so the list resolves under exactly the setup the
;;;; build uses, for every kind.
;;;;
;;;; The server kind runs AFTER Quicklisp's setup.lisp (the `make core` target
;;;; and a dev box's ~/.sbclrc both arrange that). The worker kind is built with
;;;; --no-userinit, so nothing from a personal init file is frozen into it, and
;;;; loads ~/quicklisp/setup.lisp itself when Quicklisp is not already present.
;;;; Both kinds push $LISP_WORKSPACE onto the source registry the same way
;;;; scripts/dev-boot.lisp does so the local checkouts resolve; the
;;;; release-server kind does neither. All load output goes to stderr so a
;;;; caller capturing stdout sees nothing structured.
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
;;;; project source change. Every kind shares the same staleness manifest rule.

(in-package #:cl-user)

(require :asdf)

(defun build-core-getenv (name default)
  (let ((v (uiop:getenv name)))
    (if (and v (plusp (length v))) v default)))

(defun build-core-die (control &rest args)
  "Print one [build-core] line built from CONTROL and ARGS on stderr and exit 1."
  (format *error-output* "~&[build-core] ~?~%" control args)
  (finish-output *error-output*)
  (uiop:quit 1))

;;; Which image to build. Checked before anything loads, so a mistyped kind
;;; fails in a second rather than after a full build of the wrong thing.
(defparameter *build-core-kind* (build-core-getenv "DSMR_CORE_KIND" "server"))

(unless (member *build-core-kind* '("server" "worker" "release-server")
                :test #'string=)
  (error "DSMR_CORE_KIND is ~S; the accepted values are \"server\", \"worker\" and \"release-server\""
         *build-core-kind*))

(defun build-core-worker-p ()
  (string= *build-core-kind* "worker"))

(defun build-core-release-p ()
  (string= *build-core-kind* "release-server"))

(defun build-core-systems ()
  "The systems loaded into the image of this kind, in load order."
  (cond ((build-core-worker-p)
         '("dsmr-mcp/src/hermetic/worker/main"))
        ((build-core-release-p)
         '("dsmr-mcp/release"))
        (t
         '("dsmr-mcp" "dsmr-mcp/tests" "dsmr-mcp/tests/integration"))))

;;; The ASDF version a release build accepts. SBCL's built-in ASDF is older and
;;; fails on :local-nicknames; the qlfile's asdf line supplies this one.
(defparameter *build-core-release-asdf-version* "3.3.7.4")

;;; Release kind: the release directory as a truename, or NIL for other kinds.
;;; Validated before anything loads.
(defparameter *build-core-release-root*
  (when (build-core-release-p)
    (let* ((root (build-core-getenv "DSMR_RELEASE_ROOT" nil))
           (dir (and root (uiop:ensure-directory-pathname root))))
      (unless (and dir (uiop:absolute-pathname-p dir) (uiop:directory-exists-p dir))
        (build-core-die "DSMR_RELEASE_ROOT is ~S; set it to the release's absolute directory"
                        root))
      (truename dir))))

;;; Release kind: the commit the release tree was exported from.
(defparameter *build-core-release-commit*
  (when (build-core-release-p)
    (or (build-core-getenv "DSMR_RELEASE_COMMIT" nil)
        (build-core-die "DSMR_RELEASE_COMMIT is empty; set it to the commit the release was exported from"))))

;;; The worker kind is built without the user's init file, so it brings in
;;; Quicklisp itself. A worker asked to load a Quicklisp system needs it in the
;;; image, and the setup chatter stays off stdout like every other load.
(when (and (build-core-worker-p) (not (find-package "QUICKLISP")))
  (let ((setup (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
    (when (probe-file setup)
      (format *error-output* "~&[build-core] loading Quicklisp from ~A~%" setup)
      (let ((*standard-output* *error-output*))
        (load setup)))))

;;; Defensive tilde expansion: some shells export LISP_WORKSPACE as a literal
;;; "~/..." that never expanded. Resolve a leading ~ so the registry push points
;;; at a real tree (mirrors scripts/dev-boot.lisp).
(defun build-core-expand-tilde (path)
  (if (and (plusp (length path)) (char= (char path 0) #\~))
      (namestring (merge-pathnames (subseq path 2)
                                   (user-homedir-pathname)))
      path))

(unless (build-core-release-p)
  (let* ((workspace (build-core-expand-tilde
                     (build-core-getenv "LISP_WORKSPACE"
                                        (namestring
                                         (merge-pathnames "SourceCode/lisp/"
                                                          (user-homedir-pathname))))))
         (workspace (uiop:ensure-directory-pathname workspace)))
    (pushnew workspace asdf:*central-registry* :test #'equal)
    (format *error-output* "~&[build-core] source-registry root: ~A~%" workspace)))

;;; Release kind: limit the source registry to the release, load the bundle's
;;; asdf.lisp, and refuse any other ASDF version; then resolve dsmr-mcp from the
;;; release directory alone. The bundle's searcher, installed by
;;; deps/setup.lisp, resolves every dependency. The bundled asdf.lisp is loaded
;;; as a file rather than through LOAD-SYSTEM: that searcher knows only primary
;;; system names, so ASDF's build of asdf/defsystem would resolve through any
;;; registry still open and regenerate another checkout's build/asdf.lisp.
(when (build-core-release-p)
  (asdf:initialize-source-registry
   `(:source-registry (:directory ,*build-core-release-root*)
                      :ignore-inherited-configuration))
  (let ((asdf-source (merge-pathnames "deps/local-projects/asdf/build/asdf.lisp"
                                      *build-core-release-root*))
        (*standard-output* *error-output*))
    (unless (probe-file asdf-source)
      (build-core-die "no ASDF source at ~A; check the qlfile's asdf line"
                      (namestring asdf-source)))
    (load asdf-source))
  (let ((found (asdf:asdf-version)))
    (unless (string= found *build-core-release-asdf-version*)
      (build-core-die "ASDF ~A is loaded; a release build needs ~A from ~Adeps/; check the qlfile's asdf line"
                      found *build-core-release-asdf-version*
                      (namestring *build-core-release-root*))))
  (asdf:initialize-source-registry
   `(:source-registry (:directory ,*build-core-release-root*)
                      :ignore-inherited-configuration))
  (setf asdf:*central-registry* nil)
  (format *error-output* "~&[build-core] release root: ~A (ASDF ~A)~%"
          (namestring *build-core-release-root*) (asdf:asdf-version)))

;;; List mode: with DSMR_CORE_SOURCES set, write the make prerequisite list for
;;; the image and quit before any system of this kind is loaded. It runs after
;;; this kind's registry setup, so the list resolves as the build below would.
(let ((sources (build-core-getenv "DSMR_CORE_SOURCES" nil)))
  (when sources
    (load (merge-pathnames "bus-binary-sources.lisp" *load-truename*))
    (let ((count (uiop:symbol-call '#:bus-binary-sources '#:write-prerequisites
                                   (build-core-systems)
                                   (build-core-getenv "DSMR_CORE_OUTPUT" "dsmr.core")
                                   sources)))
      (format *error-output* "~&[build-core] listed ~D source files in ~A~%"
              count sources))
    (uiop:quit 0)))

;;; Load the systems for this kind, all compilation chatter on stderr.
;;; For the server kind, loading dsmr-mcp/tests and dsmr-mcp/tests/integration
;;; puts zebra and every test leaf in the image, so both `make test` and
;;; `make test-integration` can run against the core without any load-system
;;; step. The worker kind loads the worker entry point and what it depends on.
;;; The release-server kind loads the release closure.
(dolist (system (build-core-systems))
  (format *error-output* "~&[build-core] loading ~A …~%" system)
  (let ((*standard-output* *error-output*))
    (asdf:load-system system)))

;;; Release kind: seal the registry. Only the package-inferred search function
;;; remains, so a system already loaded still resolves and any other system
;;; signals MISSING-COMPONENT instead of being found on the host.
(defun build-core-seal ()
  (setf asdf:*central-registry* nil
        asdf:*default-source-registries* nil
        asdf:*system-definition-search-functions*
        (list (uiop:find-symbol* '#:sysdef-package-inferred-system-search
                                 '#:asdf/package-inferred-system)))
  (asdf:clear-source-registry)
  (format *error-output* "~&[build-core] sealed: ~D search function, no source registry~%"
          (length asdf:*system-definition-search-functions*)))

(defun build-core-under-p (dir root)
  "True when directory DIR lies under directory ROOT, both compared as truenames."
  (let ((dir (or (ignore-errors (truename dir)) dir))
        (root (or (ignore-errors (truename root)) root)))
    (uiop:subpathp dir root)))

(defun build-core-check-release-closure ()
  "Exit 1 naming every loaded system whose source lies outside the release root
and the SBCL contrib directory. Systems with no source directory are allowed."
  (let ((contrib (merge-pathnames "contrib/" (sb-int:sbcl-homedir-pathname)))
        (outside '()))
    (dolist (name (asdf:already-loaded-systems))
      (let* ((system (asdf:registered-system name))
             (dir (and system (ignore-errors (asdf:system-source-directory system)))))
        (when (and dir
                   (not (build-core-under-p dir *build-core-release-root*))
                   (not (build-core-under-p dir contrib)))
          (push (cons name dir) outside))))
    (when outside
      (dolist (entry (nreverse outside))
        (format *error-output* "~&[build-core] outside release: ~A ~A~%"
                (car entry) (namestring (cdr entry))))
      (build-core-die "~D loaded system~:P resolve outside ~A; check that the qlfile pins them"
                      (length outside) (namestring *build-core-release-root*)))))

(when (build-core-release-p)
  (build-core-seal)
  (build-core-check-release-closure))

;;; Staleness manifest. A launch wrapper reads this (with plain shell tools, so
;;; an SBCL upgrade can't break the check) to decide whether the image is still
;;; current or must be regenerated. It records the SBCL identity plus the source
;;; root of every system the build loaded, so a patched workspace library or a
;;; Quicklisp dist update is detected the same way a project edit is. A release
;;; kind also records its kind and the commit it was built from.
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
        (when (build-core-release-p)
          (format out "kind ~A~%" *build-core-kind*)
          (format out "commit ~A~%" *build-core-release-commit*))
        (dolist (r (nreverse roots))
          (format out "root ~A~%" r)))
      (format *error-output* "~&[build-core] wrote staleness manifest ~A~%"
              manifest))))

(let ((output (build-core-getenv "DSMR_CORE_OUTPUT" "dsmr.core")))
  (build-core-write-manifest output)
  (format *error-output* "~&[build-core] saving ~A core to ~A …~%"
          *build-core-kind* output)
  (finish-output *error-output*)
  ;; :purify t maps the static heap read-only (smaller, faster start). The save
  ;; terminates the process; nothing after this form runs.
  (sb-ext:save-lisp-and-die output :executable nil :purify t))
