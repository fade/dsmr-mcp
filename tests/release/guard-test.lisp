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
                #:guard-report))

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
