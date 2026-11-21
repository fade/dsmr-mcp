;;;; tests/release/guard-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Unit tests of the release guard: which loaded systems and which launcher
;;;; tie a release image to a development checkout or to a path outside the
;;;; release.
;;;;
;;;; Every test passes SYSTEMS and LAUNCHER explicitly, so the test image's own
;;;; loaded systems are never judged. The planted tree under a fresh temporary
;;;; directory holds a release, a checkout beside it, a checkout inside it, a
;;;; linked work tree whose .git is a file, a plain outside directory and an
;;;; exceptions directory. The clean set is the green control; each planted
;;;; tie is a red case that passes only while the check it exercises exists.

(defpackage #:dsmr-mcp/tests/release/guard-test
  (:use #:cl #:zebra)
  (:import-from #:dsmr-mcp/src/release
                #:release-ties
                #:guard-report
                #:release-manifest
                #:release-commit)
  (:import-from #:dsmr-mcp/src/main
                #:version))

(in-package #:dsmr-mcp/tests/release/guard-test)

(defun %temporary-directory ()
  "Create a fresh directory under the temporary directory and return its
physical directory pathname."
  (truename
   (uiop:ensure-directory-pathname
    (string-trim '(#\Newline #\Return #\Space)
                 (uiop:run-program (list "mktemp" "-d"
                                         (namestring
                                          (merge-pathnames "dsmr-guard.XXXXXXXX"
                                                           (uiop:temporary-directory))))
                                   :output :string)))))

(defun %dir (base relative)
  "Create RELATIVE (a directory namestring ending in /) under BASE and return
its physical namestring."
  (let ((dir (merge-pathnames relative base)))
    (ensure-directories-exist dir)
    (namestring (truename dir))))

(defun %file (base relative)
  "Create an empty file RELATIVE under BASE and return its physical namestring."
  (let ((path (merge-pathnames relative base)))
    (ensure-directories-exist path)
    (with-open-file (out path :direction :output :if-exists :supersede)
      (write-string "" out))
    (namestring (truename path))))

(defun %contrib-directory ()
  "The physical SBCL contrib directory of this image."
  (namestring (truename (merge-pathnames "contrib/" (sb-int:sbcl-homedir-pathname)))))

(defstruct (tree (:conc-name tree-) (:copier nil))
  root release-system checkout-system inner-checkout-system linked-worktree-system
  outside-system exceptions exception-system launcher checkout-launcher
  outside-launcher)

(defun %plant ()
  "Plant the test tree and return a TREE naming its parts."
  (let ((base (%temporary-directory)))
    (%dir base "checkout/.git/")
    (%dir base "release/vendor/inner/.git/")
    (%file base "linked/.git")
    (make-tree
     :root (%dir base "release/")
     :release-system (%dir base "release/deps/clean-system/")
     :checkout-system (%dir base "checkout/src/tied-system/")
     :inner-checkout-system (%dir base "release/vendor/inner/src/")
     :linked-worktree-system (%dir base "linked/src/")
     :outside-system (%dir base "outside/lib/stray-system/")
     :exceptions (%dir base "quicklisp/")
     :exception-system (%dir base "quicklisp/quicklisp/")
     :launcher (%file base "release/bin/dsmr-mcp-launch")
     :checkout-launcher (%file base "checkout/scripts/dsmr-mcp-launch.sh")
     :outside-launcher (%file base "outside/bin/dsmr-mcp-launch"))))

(defun %clean-systems (tree)
  "A system set that resolves only inside the release and the contrib directory."
  (list (cons "clean-system" (tree-release-system tree))
        (cons "sb-posix" (%contrib-directory))
        (cons "asdf" nil)
        (cons "uiop" nil)
        (cons "sb-introspect" nil)))

(defun %ties (tree &key (extra '()) (launcher (tree-launcher tree)) exceptions)
  "RELEASE-TIES for the clean set of TREE plus EXTRA systems."
  (release-ties (tree-root tree)
                :systems (append (%clean-systems tree) extra)
                :launcher launcher
                :exceptions exceptions))

(defun %reasons (ties)
  "The reason of each tie in TIES, in order."
  (mapcar (lambda (tie) (getf tie :reason)) ties))

(defun %setenv (name value)
  "Set the environment variable NAME to VALUE, or to the empty string when
VALUE is NIL."
  (setf (uiop:getenv name) (or value "")))

(defmacro with-env ((&rest bindings) &body body)
  "Evaluate BODY with each (NAME VALUE) of BINDINGS set in the environment,
restoring every previous value afterwards. A NIL VALUE sets the empty string,
which every reader here treats as unset."
  (let ((saved (gensym "SAVED")))
    `(let ((,saved (list ,@(mapcar (lambda (b) `(cons ,(first b) (uiop:getenv ,(first b))))
                                   bindings))))
       (unwind-protect
            (progn
              ,@(mapcar (lambda (b) `(%setenv ,(first b) ,(second b)))
                        bindings)
              ,@body)
         (dolist (pair ,saved)
           (%setenv (car pair) (cdr pair)))))))

;;; ---------------------------------------------------------------------------
;;; release-ties
;;; ---------------------------------------------------------------------------

(define-test a-clean-release-has-no-ties
  "Systems under the release or the contrib directory, preloaded systems
without source, and a launcher inside the release give no tie."
  (let ((tree (%plant)))
    (is equal '() (%ties tree))))

(define-test a-system-in-a-checkout-is-a-tie
  "A system in a tree holding a .git directory or a .git file is a :checkout
tie, also when it is outside the release and also when it is inside it."
  (let* ((tree (%plant))
         (ties (%ties tree :extra (list (cons "tied-system" (tree-checkout-system tree))))))
    (is equal '(:checkout) (%reasons ties))
    (is equal "tied-system" (getf (first ties) :name))
    (is equal (tree-checkout-system tree) (getf (first ties) :directory)))
  (let ((tree (%plant)))
    (is equal '(:checkout)
        (%reasons (%ties tree :extra (list (cons "inner" (tree-inner-checkout-system tree)))))
        "a checkout inside the release is still a checkout")
    (is equal '(:checkout)
        (%reasons (%ties tree :extra (list (cons "linked" (tree-linked-worktree-system tree)))))
        "a linked work tree's .git file marks a checkout")))

(define-test a-system-outside-the-release-is-a-tie
  "A system outside the release and outside every work tree is an
:outside-release tie."
  (let* ((tree (%plant))
         (ties (%ties tree :extra (list (cons "stray-system" (tree-outside-system tree))))))
    (is equal '(:outside-release) (%reasons ties))
    (is equal (tree-outside-system tree) (getf (first ties) :directory))))

(define-test a-named-exception-is-not-a-tie
  "A system under a directory passed in EXCEPTIONS is not reported; without
the exception the same system is an :outside-release tie."
  (let* ((tree (%plant))
         (extra (list (cons "quicklisp" (tree-exception-system tree)))))
    (is equal '() (%ties tree :extra extra :exceptions (list (tree-exceptions tree))))
    (is equal '(:outside-release) (%reasons (%ties tree :extra extra)))))

(define-test a-launcher-in-a-work-tree-is-a-tie
  "A launcher inside a work tree is :launcher-in-work-tree, one outside the
release is :launcher-outside-release, and no launcher is no tie."
  (let ((tree (%plant)))
    (is equal '(:launcher-in-work-tree)
        (%reasons (%ties tree :launcher (tree-checkout-launcher tree))))
    (is equal '(:launcher-outside-release)
        (%reasons (%ties tree :launcher (tree-outside-launcher tree))))
    (is equal '() (%ties tree :launcher nil))))

(define-test the-launcher-defaults-to-dsmr-launcher-path
  "With no LAUNCHER argument the launcher is read from DSMR_LAUNCHER_PATH, and
an empty value means no launcher."
  (let ((tree (%plant)))
    (with-env (("DSMR_LAUNCHER_PATH" (tree-checkout-launcher tree)))
      (is equal '(:launcher-in-work-tree)
          (%reasons (release-ties (tree-root tree) :systems (%clean-systems tree)))))
    (with-env (("DSMR_LAUNCHER_PATH" nil))
      (is equal '() (release-ties (tree-root tree) :systems (%clean-systems tree))))))

(define-test a-preloaded-system-without-source-is-allowed
  "asdf, uiop and sb-* contribs without a source directory are allowed; any
other system without one is a :no-source tie."
  (let ((tree (%plant)))
    (is equal '() (%ties tree :extra (list (cons "sb-md5" nil))))
    (is equal '(:no-source) (%reasons (%ties tree :extra (list (cons "mystery" nil)))))))

(define-test asdf-package-system-without-source-is-allowed
  "asdf-package-system, which ASDF registers itself with no source directory,
is allowed."
  (let ((tree (%plant)))
    (is equal '() (%ties tree :extra (list (cons "asdf-package-system" nil))))))

(define-test a-source-less-system-off-the-list-is-a-tie
  "A system without a source directory whose name only resembles an allowed
one is a :no-source tie."
  (let ((tree (%plant)))
    (dolist (name '("asdf-package-system-extra" "asdf-extra" "uiop-extra" "sb-"))
      (is equal '(:no-source) (%reasons (%ties tree :extra (list (cons name nil))))
          "~a without source is a tie" name))))

(define-test a-bundled-dependency-holding-git-metadata-is-a-tie
  "A dependency inside the release whose directory still holds a .git entry,
as qlot leaves in a bundled git source, is a :checkout tie."
  (let* ((tree (%plant))
         (dep (%dir (tree-root tree) "deps/local-projects/asdf/"))
         (extra (list (cons "asdf-source" dep))))
    (%file (tree-root tree) "deps/local-projects/asdf/.git/HEAD")
    (is equal '(:checkout) (%reasons (%ties tree :extra extra)))
    (is equal dep (getf (first (%ties tree :extra extra)) :directory))))

;;; ---------------------------------------------------------------------------
;;; guard-report
;;; ---------------------------------------------------------------------------

(define-test the-report-is-red-when-any-tie-exists
  "A sealed clean set reports green with no ties; a planted tie reports red
and names the tie's directory and reason; an unsealed clean set reports red."
  (let ((tree (%plant)))
    (with-env (("DSMR_ALIVE_LSP_DIR" nil))
      (let ((green (guard-report :root (tree-root tree) :systems (%clean-systems tree)
                                 :launcher (tree-launcher tree) :sealed t))
            (red (guard-report :root (tree-root tree)
                               :systems (append (%clean-systems tree)
                                                (list (cons "tied-system"
                                                            (tree-checkout-system tree))))
                               :launcher (tree-launcher tree) :sealed t))
            (unsealed (guard-report :root (tree-root tree) :systems (%clean-systems tree)
                                    :launcher (tree-launcher tree) :sealed nil)))
        (is equal "green" (gethash "status" green))
        (is = 0 (length (gethash "ties" green)))
        (is equal (tree-root tree) (gethash "release_root" green))
        (is equal "red" (gethash "status" red))
        (is = 1 (length (gethash "ties" red)))
        (let ((tie (aref (gethash "ties" red) 0)))
          (is equal "tied-system" (gethash "name" tie))
          (is equal (tree-checkout-system tree) (gethash "directory" tie))
          (is equal "checkout" (gethash "reason" tie)))
        (is equal "red" (gethash "status" unsealed))))))

(define-test alive-lsp-is-reported-as-a-residual-not-a-tie
  "With DSMR_ALIVE_LSP_DIR set the report lists alive-lsp under residuals and
stays green; unset, there is no residual."
  (let ((tree (%plant)))
    (with-env (("DSMR_ALIVE_LSP_DIR" (tree-outside-system tree)))
      (let ((report (guard-report :root (tree-root tree) :systems (%clean-systems tree)
                                  :launcher (tree-launcher tree) :sealed t)))
        (is equal "green" (gethash "status" report))
        (is = 1 (length (gethash "residuals" report)))
        (let ((residual (aref (gethash "residuals" report) 0)))
          (is equal "alive-lsp" (gethash "name" residual))
          (is equal (tree-outside-system tree) (gethash "directory" residual))
          (true (stringp (gethash "reason" residual))))))
    (with-env (("DSMR_ALIVE_LSP_DIR" nil))
      (is = 0 (length (gethash "residuals"
                               (guard-report :root (tree-root tree)
                                             :systems (%clean-systems tree)
                                             :launcher (tree-launcher tree)
                                             :sealed t)))))))

;;; ---------------------------------------------------------------------------
;;; The release MANIFEST and the server version
;;; ---------------------------------------------------------------------------

(defparameter *recorded-manifest*
  "commit c9189ea76b7974ee9c11ca4151361dd63de8a7b3
ref HEAD
dirty false
sbcl-version 2.6.10
build-host ghost
build-time 2026-11-21T15:30:33Z
unpublished-ref-allowed yes
qlfile-lock-sha256 aad1973881891e9679a560202a64b5489ccdd8112e11213ca306351d68bb7674
dependency quicklisp 2026-01-01
dependency slynk-client github-67b65da7210b4f9a6e373077373528a4c7bed4b5
dependency zebra git-a36e393027746c65e41031f9c111f3fdf46877e7
"
  "The head of a MANIFEST written by `make deploy REF=HEAD` into a scratch
deploy home, release c9189ea76b7974ee9c11ca4151361dd63de8a7b3.")

(defun %release-with-manifest (text)
  "A fresh directory holding a MANIFEST with TEXT, or none when TEXT is NIL."
  (let ((dir (%temporary-directory)))
    (when text
      (with-open-file (out (merge-pathnames "MANIFEST" dir)
                           :direction :output :if-exists :supersede)
        (write-string text out)))
    (namestring dir)))

(define-test a-release-manifest-names-its-commit
  "The recorded MANIFEST parses into its key values, with every dependency line
kept, and its commit is the release commit."
  (with-env (("DSMR_RELEASE_ROOT" (%release-with-manifest *recorded-manifest*)))
    (let ((manifest (release-manifest)))
      (is equal "c9189ea76b7974ee9c11ca4151361dd63de8a7b3"
          (cdr (assoc "commit" manifest :test #'string=)))
      (is equal "2.6.10" (cdr (assoc "sbcl-version" manifest :test #'string=)))
      (is equal '("quicklisp 2026-01-01"
                  "slynk-client github-67b65da7210b4f9a6e373077373528a4c7bed4b5"
                  "zebra git-a36e393027746c65e41031f9c111f3fdf46877e7")
          (cdr (assoc "dependency" manifest :test #'string=))))
    (is equal "c9189ea76b7974ee9c11ca4151361dd63de8a7b3" (release-commit))))

(define-test the-version-carries-the-release-commit
  "Inside a release the version is 0.1.0+<commit>; with no release root it is
0.1.0."
  (with-env (("DSMR_RELEASE_ROOT" (%release-with-manifest *recorded-manifest*)))
    (is equal "0.1.0+c9189ea76b7974ee9c11ca4151361dd63de8a7b3" (version)))
  (with-env (("DSMR_RELEASE_ROOT" nil))
    (is eq nil (release-commit))
    (is eq nil (release-manifest))
    (is equal "0.1.0" (version))))

(define-test a-manifest-without-a-commit-leaves-the-version-plain
  "A MANIFEST with no commit line, and a release root with no MANIFEST, give
0.1.0 and signal nothing."
  (with-env (("DSMR_RELEASE_ROOT" (%release-with-manifest
                                   (format nil "ref HEAD~%dirty false~%"))))
    (is eq nil (release-commit))
    (is equal "0.1.0" (version)))
  (with-env (("DSMR_RELEASE_ROOT" (%release-with-manifest nil)))
    (is eq nil (release-manifest))
    (is eq nil (release-commit))
    (is equal "0.1.0" (version))))
