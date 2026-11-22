;;;; tests/integration/scripts/launcher-release-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Behaviour of the release launcher and the checkout launcher against fake
;;;; releases.
;;;;
;;;; Each case builds a throwaway deploy home under a temp directory:
;;;; <home>/releases/<name>/ holds the release launcher as bin/dsmr-mcp-launch,
;;;; scripts/release-paths.sh, a decoy core/dsmr.core with a manifest, and a
;;;; MANIFEST naming a commit, and <home>/current links to one release. The
;;;; launcher is run through <home>/current, as a registration runs it.
;;;;
;;;; The release launcher installed is the file DSMR_TEST_RELEASE_LAUNCHER
;;;; names, else scripts/release-launch.sh; the checkout launcher is the file
;;;; DSMR_TEST_CHECKOUT_LAUNCHER names, else scripts/dsmr-mcp-launch.sh. Point
;;;; them at an older launcher to show these tests fail against it.
;;;;
;;;; Programs on PATH are stubs. The stub sbcl answers --version with
;;;; "SBCL 2.6.10", the format and version `sbcl --version` printed on the
;;;; development host on 2026-11-20. Called with (sb-ext:exit) it is the boot
;;;; probe and exits 1 when <tmp>/probe-fails exists, else 0. Any other call is
;;;; a server boot: it writes its argv and the five DSMR_ variables the launcher
;;;; controls to <tmp>/boot-<n>, runs <tmp>/after-boot-<n> when present, and
;;;; exits with the status in <tmp>/exit-<n> (default 0). The stub make appends
;;;; its arguments to <tmp>/make.log.
;;;;
;;;; Every launch replaces HOME, XDG_STATE_HOME and DSMR_HOME with paths inside
;;;; the temp tree and drops inherited SBCL, DSMR_, XDG_ and GIT_ variables, so
;;;; no case reads the live deploy home. Skips when bash is unavailable; the
;;;; work-tree cases also skip without git.

(defpackage #:dsmr-mcp/tests/integration/scripts/launcher-release-test
  (:use #:cl #:zebra))

(in-package #:dsmr-mcp/tests/integration/scripts/launcher-release-test)

;;; ---------------------------------------------------------------------------
;;; Scaffolding
;;; ---------------------------------------------------------------------------

(defparameter +refusal-exit-code+ 78
  "Exit code a launcher returns when it refuses to start.")

(defparameter +stub-sbcl-version+ "2.6.10"
  "The version the stub sbcl reports.")

(defparameter +variables+
  '("DSMR_RELEASE_ROOT" "DSMR_BROKER_CORE" "DSMR_WORKER_CORE"
    "DSMR_LAUNCHER_PATH" "DSMR_ALLOW_SOURCE_WORKERS")
  "The variables the stub server records.")

(defun %bash-path ()
  "Absolute path to a bash binary, or NIL if none is available."
  (let ((p (find-if #'probe-file '("/bin/bash" "/usr/bin/bash"))))
    (and p (namestring p))))

(defun %git-available-p ()
  "True when git runs."
  (ignore-errors
   (zerop (nth-value 2 (uiop:run-program '("git" "--version")
                                         :ignore-error-status t)))))

(defun %make-temp-dir ()
  "Create a uniquely named temp directory and return its physical pathname."
  (let ((*random-state* (make-random-state t)))
    (loop
      (let ((dir (uiop:ensure-directory-pathname
                  (merge-pathnames
                   (format nil "dsmr-launch-release-~8,'0X" (random #xFFFFFFFF))
                   (uiop:temporary-directory)))))
        (unless (probe-file dir)
          (ensure-directories-exist dir)
          (return (truename dir)))))))

(defun %path (pathname)
  "PATHNAME as a native namestring with no trailing slash."
  (string-right-trim "/" (uiop:native-namestring pathname)))

(defun %write-file (path string &key executable)
  "Write STRING to PATH, creating parents; mark it executable when EXECUTABLE."
  (ensure-directories-exist path)
  (with-open-file (s path :direction :output
                          :if-exists :supersede :if-does-not-exist :create)
    (write-string string s))
  (when executable
    (uiop:run-program (list "chmod" "755" (%path path))))
  path)

(defun %run (&rest argv)
  "Run ARGV, signalling an error on a non-zero exit."
  (uiop:run-program argv :output nil :error-output :string))

(defun %fill (template tmp)
  "TEMPLATE with every @T@ replaced by TMP's path."
  (let ((key "@T@") (dir (%path tmp)))
    (with-output-to-string (out)
      (loop with start = 0
            for hit = (search key template :start2 start)
            do (write-string template out :start start :end (or hit (length template)))
               (if hit
                   (progn (write-string dir out) (setf start (+ hit (length key))))
                   (return))))))

(defparameter +stub-sbcl+
  "#!/usr/bin/env bash
T='@T@'
case \" $* \" in
  *' --version '*) echo 'SBCL 2.6.10'; exit 0 ;;
  *'(sb-ext:exit)'*) echo probe >> \"$T/probes\"; [ -e \"$T/probe-fails\" ] && exit 1; exit 0 ;;
esac
n=$(cat \"$T/boot-count\" 2>/dev/null || echo 0)
n=$((n + 1))
echo \"$n\" > \"$T/boot-count\"
{
  printf 'ARGV=%s\\n' \"$*\"
  for v in DSMR_RELEASE_ROOT DSMR_BROKER_CORE DSMR_WORKER_CORE DSMR_LAUNCHER_PATH DSMR_ALLOW_SOURCE_WORKERS; do
    if [ -n \"${!v+x}\" ]; then printf '%s=%s\\n' \"$v\" \"${!v}\"; else printf '%s=<unset>\\n' \"$v\"; fi
  done
} > \"$T/boot-$n\"
if [ -x \"$T/after-boot-$n\" ]; then \"$T/after-boot-$n\"; fi
exit \"$(cat \"$T/exit-$n\" 2>/dev/null || echo 0)\"
"
  "The stub sbcl; @T@ stands for the temp directory.")

(defparameter +stub-make+
  "#!/usr/bin/env bash
echo \"$*\" >> '@T@/make.log'
"
  "The stub make; @T@ stands for the temp directory.")

(defun %source (variable default)
  "The file VARIABLE names when set and not empty, else DEFAULT in the tree."
  (let ((v (uiop:getenv variable)))
    (if (and v (plusp (length v)))
        (pathname v)
        (asdf:system-relative-pathname "dsmr-mcp" default))))

(defun %release-launcher-source ()
  "The release launcher the fake releases carry."
  (%source "DSMR_TEST_RELEASE_LAUNCHER" "scripts/release-launch.sh"))

(defun %checkout-launcher-source ()
  "The checkout launcher the trampoline cases run."
  (%source "DSMR_TEST_CHECKOUT_LAUNCHER" "scripts/dsmr-mcp-launch.sh"))

(defun %release-paths-source ()
  "scripts/release-paths.sh in the tree."
  (asdf:system-relative-pathname "dsmr-mcp" "scripts/release-paths.sh"))

(defun %home (tmp)
  "The fake deploy home under TMP."
  (merge-pathnames "home/" tmp))

(defun %make-release (home name &key (sbcl +stub-sbcl-version+) (core t)
                                     (manifest t) worker
                                     (worker-sbcl +stub-sbcl-version+))
  "Build <HOME>/releases/<NAME>/ and return its directory. CORE and MANIFEST
NIL leave out the core or MANIFEST; SBCL is the version the core manifest
records. WORKER adds a worker core whose manifest records WORKER-SBCL."
  (let ((rel (merge-pathnames (format nil "releases/~A/" name) home)))
    (%write-file (merge-pathnames "bin/dsmr-mcp-launch" rel)
                 (uiop:read-file-string (%release-launcher-source)) :executable t)
    (%write-file (merge-pathnames "scripts/release-paths.sh" rel)
                 (uiop:read-file-string (%release-paths-source)))
    (when core
      (%write-file (merge-pathnames "core/dsmr.core" rel) "decoy")
      (%write-file (merge-pathnames "core/dsmr.core.manifest" rel)
                   (format nil "sbcl-version ~A~%kind release~%" sbcl)))
    (when worker
      (%write-file (merge-pathnames "core/dsmr.core.worker" rel) "decoy")
      (%write-file (merge-pathnames "core/dsmr.core.worker.manifest" rel)
                   (format nil "sbcl-version ~A~%kind release-worker~%" worker-sbcl)))
    (when manifest
      (%write-file (merge-pathnames "MANIFEST" rel)
                   (format nil "commit ~A~%ref HEAD~%" (%commit-of name))))
    (%run "chmod" "-R" "go-w" (%path rel))
    rel))

(defun %commit-of (name)
  "The commit the MANIFEST of release NAME records."
  (format nil "c0ffee~A" name))

(defun %point-current (home name)
  "Point <HOME>/current at releases/<NAME>."
  (%run "ln" "-sfn" (format nil "releases/~A" name)
        (%path (merge-pathnames "current" home))))

(defun %entry (home)
  "The path a registration runs: <HOME>/current/bin/dsmr-mcp-launch."
  (%path (merge-pathnames "current/bin/dsmr-mcp-launch" home)))

(defun %install-stubs (tmp)
  "Install the stub sbcl and make under <TMP>/bin/."
  (%write-file (merge-pathnames "bin/sbcl" tmp) (%fill +stub-sbcl+ tmp) :executable t)
  (%write-file (merge-pathnames "bin/make" tmp) (%fill +stub-make+ tmp) :executable t))

(defun %dropped-p (kv)
  "True for an inherited NAME=VALUE the launch replaces or removes."
  (some (lambda (prefix) (uiop:string-prefix-p prefix kv))
        '("SBCL=" "DSMR_" "XDG_" "GIT_" "HOME=" "PATH=")))

(defun %launch (tmp program &key (home t) extra-env)
  "Run PROGRAM under bash with the stubs first on PATH, XDG_STATE_HOME and
DSMR_HOME inside TMP, and HOME inside TMP unless HOME is NIL. EXTRA-ENV is a
list of NAME=VALUE strings. Return the exit code, stdout and stderr."
  (let ((env (append
              (list (format nil "PATH=~A:~A" (%path (merge-pathnames "bin/" tmp))
                            (or (uiop:getenv "PATH") "/usr/bin:/bin"))
                    (format nil "XDG_STATE_HOME=~A" (%path (merge-pathnames "state/" tmp)))
                    (format nil "DSMR_HOME=~A" (%path (%home tmp))))
              (when home
                (list (format nil "HOME=~A" (%path (merge-pathnames "fakehome/" tmp)))))
              extra-env
              (remove-if #'%dropped-p
                         (uiop:run-program '("env") :output :lines
                                                    :ignore-error-status t)))))
    (multiple-value-bind (out err rc)
        (uiop:run-program (list (%bash-path) program)
                          :directory tmp :input nil
                          :output :string :error-output :string
                          :ignore-error-status t :environment env)
      (values rc out err))))

(defun %boot (tmp n key)
  "The value the stub server recorded for KEY at boot N, or NIL when there was
no boot N. KEY is \"ARGV\" or one of +VARIABLES+."
  (let ((file (merge-pathnames (format nil "boot-~D" n) tmp)))
    (when (probe-file file)
      (let ((prefix (format nil "~A=" key)))
        (loop for line in (uiop:read-file-lines file)
              when (uiop:string-prefix-p prefix line)
                return (subseq line (length prefix)))))))

(defun %make-ran-p (tmp &key (wait 0))
  "True when the stub make ran, polling up to WAIT seconds for a background
build."
  (let ((log (merge-pathnames "make.log" tmp))
        (deadline (+ (get-internal-real-time)
                     (* wait internal-time-units-per-second))))
    (loop
      (when (probe-file log) (return t))
      (when (>= (get-internal-real-time) deadline) (return nil))
      (sleep 0.05))))

(defmacro with-fake-release ((tmp home &rest release-args) &body body)
  "Skip without bash; otherwise bind TMP to a fresh physical temp directory
holding the stubs and HOME to its deploy home, build release r1 from
RELEASE-ARGS, point current at it, and remove the tree on exit."
  `(if (null (%bash-path))
       (skip "bash is unavailable in this environment")
       (let* ((,tmp (%make-temp-dir))
              (,home (%home ,tmp)))
         (unwind-protect
              (progn
                (%install-stubs ,tmp)
                (%make-release ,home "r1" ,@release-args)
                (%point-current ,home "r1")
                ,@body)
           (ignore-errors (%run "chmod" "-R" "u+w" (%path ,tmp)))
           (ignore-errors (uiop:delete-directory-tree
                           ,tmp :validate t :if-does-not-exist :ignore))))))

(defun %release-dir (home name)
  "The physical path of release NAME under HOME, as the launcher resolves it."
  (%path (truename (merge-pathnames (format nil "releases/~A/" name) home))))

(defun %refused-p (rc out err tmp remedy)
  "Assert a refusal: exit 78, empty stdout, REMEDY on stderr, no server boot."
  (is = +refusal-exit-code+ rc "the launcher refused with exit 78")
  (is string= "" out "the launcher wrote nothing to stdout")
  (true (search "cannot start" err) "stderr says the server cannot start")
  (true (search remedy err) (format nil "stderr names the remedy ~S" remedy))
  (false (%boot tmp 1 "ARGV") "the server was never started"))

;;; ---------------------------------------------------------------------------
;;; Booting a release
;;; ---------------------------------------------------------------------------

(define-test the-release-core-boots-with-no-init-files
  "The server boots the core of the release current names, reading no SBCL
init file."
  (with-fake-release (tmp home)
    (multiple-value-bind (rc out) (%launch tmp (%entry home))
      (let ((argv (or (%boot tmp 1 "ARGV") "")))
        (is = 0 rc "the launcher exited with the server's status")
        (is string= "" out "the launcher wrote nothing to stdout")
        (true (search (format nil "--core ~A/core/dsmr.core" (%release-dir home "r1")) argv)
              "the server booted the release's core")
        (true (search "--no-sysinit" argv) "the boot reads no system init file")
        (true (search "--no-userinit" argv) "the boot reads no user init file")))))

(define-test release-variables-overwrite-the-callers
  "DSMR_RELEASE_ROOT, DSMR_BROKER_CORE and DSMR_LAUNCHER_PATH come from the
release, whatever the caller set."
  (with-fake-release (tmp home)
    (let ((root (%release-dir home "r1")))
      (%launch tmp (%entry home)
               :extra-env '("DSMR_RELEASE_ROOT=/elsewhere"
                            "DSMR_BROKER_CORE=/elsewhere/dsmr.core"
                            "DSMR_LAUNCHER_PATH=/elsewhere/launch"))
      (is string= root (%boot tmp 1 "DSMR_RELEASE_ROOT") "the release root")
      (is string= (format nil "~A/core/dsmr.core" root) (%boot tmp 1 "DSMR_BROKER_CORE")
          "the broker core is the release's server core")
      (is string= (format nil "~A/bin/dsmr-mcp-launch" root)
          (%boot tmp 1 "DSMR_LAUNCHER_PATH")
          "the launcher path is the launcher's physical path"))))

(define-test the-source-worker-opt-in-is-never-passed-on
  "DSMR_ALLOW_SOURCE_WORKERS from the caller does not reach the server."
  (with-fake-release (tmp home)
    (%launch tmp (%entry home) :extra-env '("DSMR_ALLOW_SOURCE_WORKERS=1"))
    (is string= "<unset>" (%boot tmp 1 "DSMR_ALLOW_SOURCE_WORKERS")
        "the opt-in was removed")))

(define-test the-launcher-never-runs-make
  "A release with no core leaves no make trace, even after a pause long enough
for a background build to start."
  (with-fake-release (tmp home :core nil)
    (%launch tmp (%entry home))
    (false (%make-ran-p tmp :wait 3) "no make ran")))

(define-test the-log-names-the-commit-it-boots
  "The launcher's stderr names the commit the release's MANIFEST records."
  (with-fake-release (tmp home)
    (multiple-value-bind (rc out err) (%launch tmp (%entry home))
      (declare (ignore out))
      (is = 0 rc "the launcher exited with the server's status")
      (true (search (format nil "booting release ~A" (%commit-of "r1")) err)
            "stderr names the commit"))))

;;; ---------------------------------------------------------------------------
;;; Refusals
;;; ---------------------------------------------------------------------------

(define-test a-release-without-a-core-refuses-with-78
  "A release with no server core is refused with the deploy remedy."
  (with-fake-release (tmp home :core nil)
    (multiple-value-bind (rc out err) (%launch tmp (%entry home))
      (%refused-p rc out err tmp "make deploy REF="))))

(define-test a-release-without-a-manifest-refuses-with-78
  "A release with no MANIFEST is refused with the deploy remedy."
  (with-fake-release (tmp home :manifest nil)
    (multiple-value-bind (rc out err) (%launch tmp (%entry home))
      (%refused-p rc out err tmp "make deploy REF="))))

(define-test a-core-from-another-sbcl-refuses-with-78
  "A core whose manifest records another SBCL is refused, naming both
versions."
  (with-fake-release (tmp home :sbcl "9.9.9")
    (multiple-value-bind (rc out err) (%launch tmp (%entry home))
      (%refused-p rc out err tmp "make deploy REF=")
      (true (search "9.9.9" err) "stderr names the recorded version")
      (true (search +stub-sbcl-version+ err) "stderr names the running version"))))

(define-test a-core-that-does-not-boot-refuses-with-78
  "A core the boot probe cannot start is refused before the server runs."
  (with-fake-release (tmp home)
    (%write-file (merge-pathnames "probe-fails" tmp) "")
    (multiple-value-bind (rc out err) (%launch tmp (%entry home))
      (%refused-p rc out err tmp "make deploy REF=")
      (true (probe-file (merge-pathnames "probes" tmp)) "the core was probed"))))

(define-test a-release-inside-a-work-tree-refuses-with-78
  "A release whose root sits inside a git work tree is refused."
  (if (not (%git-available-p))
      (skip "git is unavailable in this environment")
      (with-fake-release (tmp home)
        (%run "git" "init" "-q" (%path tmp))
        (multiple-value-bind (rc out err) (%launch tmp (%entry home))
          (%refused-p rc out err tmp "make register")))))

(define-test a-launcher-linked-from-a-checkout-refuses-with-78
  "A release whose launcher is a link into a git work tree is refused."
  (if (not (%git-available-p))
      (skip "git is unavailable in this environment")
      (with-fake-release (tmp home)
        (let* ((checkout (merge-pathnames "checkout/" tmp))
               (target (merge-pathnames "scripts/release-launch.sh" checkout))
               (link (merge-pathnames "releases/r1/bin/dsmr-mcp-launch" home)))
          (%write-file target (uiop:read-file-string (%release-launcher-source))
                       :executable t)
          (%run "git" "init" "-q" (%path checkout))
          (%run "chmod" "u+w" (%path (merge-pathnames "releases/r1/bin/" home)))
          (%run "ln" "-sfn" (%path target) (%path link))
          (multiple-value-bind (rc out err) (%launch tmp (%entry home))
            (%refused-p rc out err tmp "make register"))))))

(define-test a-group-writable-core-refuses-with-78
  "A server core others can write is refused with the permissions remedy."
  (with-fake-release (tmp home)
    (%run "chmod" "g+w" (%path (merge-pathnames "releases/r1/core/dsmr.core" home)))
    (multiple-value-bind (rc out err) (%launch tmp (%entry home))
      (%refused-p rc out err tmp "restore ownership and permissions"))))

(define-test a-world-writable-release-root-refuses-with-78
  "A release root anyone can write is refused with the permissions remedy."
  (with-fake-release (tmp home)
    (%run "chmod" "o+w" (%release-dir home "r1"))
    (multiple-value-bind (rc out err) (%launch tmp (%entry home))
      (%refused-p rc out err tmp "restore ownership and permissions"))))

(defun %plant-release-paths (home tmp)
  "Replace release r1's scripts/release-paths.sh under HOME with one that
creates <TMP>/planted-ran when sourced."
  (let ((file (merge-pathnames "releases/r1/scripts/release-paths.sh" home)))
    (%run "chmod" "u+w" (%path (merge-pathnames "releases/r1/scripts/" home)))
    (uiop:delete-file-if-exists file)
    (%write-file file (format nil ": > '~A'~%"
                              (%path (merge-pathnames "planted-ran" tmp))))
    (%run "chmod" "go-w" (%path file))
    (%run "chmod" "u-w" (%path (merge-pathnames "releases/r1/scripts/" home)))))

(defun %planted-ran-p (tmp)
  "True when the planted release-paths.sh ran."
  (probe-file (merge-pathnames "planted-ran" tmp)))

(define-test a-world-writable-release-root-is-refused-before-its-scripts-run
  "In a release root anyone can write, scripts/release-paths.sh never runs:
the refusal comes first."
  (with-fake-release (tmp home)
    (%plant-release-paths home tmp)
    (%run "chmod" "o+w" (%release-dir home "r1"))
    (multiple-value-bind (rc out err) (%launch tmp (%entry home))
      (%refused-p rc out err tmp "restore ownership and permissions")
      (false (%planted-ran-p tmp) "the planted release-paths.sh did not run"))))

(define-test a-group-writable-scripts-directory-is-refused-before-it-runs
  "A scripts/ directory others can write is refused before anything in it runs."
  (with-fake-release (tmp home)
    (%plant-release-paths home tmp)
    (%run "chmod" "g+w" (%path (merge-pathnames "releases/r1/scripts/" home)))
    (multiple-value-bind (rc out err) (%launch tmp (%entry home))
      (%refused-p rc out err tmp "restore ownership and permissions")
      (false (%planted-ran-p tmp) "the planted release-paths.sh did not run"))))

(define-test a-world-writable-releases-directory-is-refused-before-scripts-run
  "A releases/ directory anyone can write is refused before anything from the
release runs: a release can be replaced through it."
  (with-fake-release (tmp home)
    (%plant-release-paths home tmp)
    (%run "chmod" "o+w" (%path (merge-pathnames "releases/" home)))
    (multiple-value-bind (rc out err) (%launch tmp (%entry home))
      (%refused-p rc out err tmp "restore ownership and permissions")
      (false (%planted-ran-p tmp) "the planted release-paths.sh did not run"))))

(define-test a-group-writable-deploy-home-is-refused-before-scripts-run
  "A deploy home others can write is refused before anything from the release
runs."
  (with-fake-release (tmp home)
    (%plant-release-paths home tmp)
    (%run "chmod" "g+w" (%path home))
    (multiple-value-bind (rc out err) (%launch tmp (%entry home))
      (%refused-p rc out err tmp "restore ownership and permissions")
      (false (%planted-ran-p tmp) "the planted release-paths.sh did not run"))))

(define-test an-intact-release-runs-its-release-paths
  "The control: in a release with sound permissions the launcher sources
scripts/release-paths.sh, so the planted file runs."
  (with-fake-release (tmp home)
    (%plant-release-paths home tmp)
    (%launch tmp (%entry home))
    (true (%planted-ran-p tmp) "the planted release-paths.sh ran")))

(define-test an-unset-home-refuses-with-78
  "With HOME unset the launcher refuses and asks for HOME."
  (with-fake-release (tmp home)
    (multiple-value-bind (rc out err) (%launch tmp (%entry home) :home nil)
      (%refused-p rc out err tmp "HOME set"))))

;;; ---------------------------------------------------------------------------
;;; The worker core
;;; ---------------------------------------------------------------------------

(define-test a-matching-worker-core-is-handed-over
  "A worker core built by the running SBCL reaches the server, replacing the
caller's value."
  (with-fake-release (tmp home :worker t)
    (%launch tmp (%entry home) :extra-env '("DSMR_WORKER_CORE=/elsewhere/w"))
    (is string= (format nil "~A/core/dsmr.core.worker" (%release-dir home "r1"))
        (%boot tmp 1 "DSMR_WORKER_CORE")
        "the server was given the release's worker core")))

(define-test a-worker-core-from-another-sbcl-is-withheld
  "A worker core another SBCL built is withheld, the caller's value removed,
and the server core still boots."
  (with-fake-release (tmp home :worker t :worker-sbcl "9.9.9")
    (multiple-value-bind (rc out)
        (%launch tmp (%entry home) :extra-env '("DSMR_WORKER_CORE=/elsewhere/w"))
      (is = 0 rc "the launcher exited with the server's status")
      (is string= "" out "the launcher wrote nothing to stdout")
      (is string= "<unset>" (%boot tmp 1 "DSMR_WORKER_CORE")
          "the worker core was withheld"))))

;;; ---------------------------------------------------------------------------
;;; Relaunch
;;; ---------------------------------------------------------------------------

(define-test a-relaunch-follows-current
  "After the server asks for a relaunch, the launcher boots the release
current names at that moment."
  (with-fake-release (tmp home)
    (%make-release home "r2")
    (%write-file (merge-pathnames "exit-1" tmp) "75")
    (%write-file (merge-pathnames "after-boot-1" tmp)
                 (format nil "#!/usr/bin/env bash~%ln -sfn releases/r2 '~A'~%"
                         (%path (merge-pathnames "current" home)))
                 :executable t)
    (multiple-value-bind (rc out) (%launch tmp (%entry home))
      (is = 0 rc "the launcher exited with the second server's status")
      (is string= "" out "the launcher wrote nothing to stdout")
      (is string= (%release-dir home "r1") (%boot tmp 1 "DSMR_RELEASE_ROOT")
          "the first boot ran r1")
      (is string= (%release-dir home "r2") (%boot tmp 2 "DSMR_RELEASE_ROOT")
          "the relaunch ran r2")
      (true (search (format nil "~A/core/dsmr.core" (%release-dir home "r2"))
                    (or (%boot tmp 2 "ARGV") ""))
            "the relaunch booted r2's core"))))

;;; ---------------------------------------------------------------------------
;;; The checkout launcher
;;; ---------------------------------------------------------------------------

(defun %install-checkout-launcher (tmp)
  "Copy the checkout launcher and release-paths.sh into <TMP>/checkout/scripts/
and return the launcher's path."
  (let ((launcher (merge-pathnames "checkout/scripts/dsmr-mcp-launch.sh" tmp)))
    (%write-file launcher (uiop:read-file-string (%checkout-launcher-source))
                 :executable t)
    (%write-file (merge-pathnames "checkout/scripts/release-paths.sh" tmp)
                 (uiop:read-file-string (%release-paths-source)))
    (%path launcher)))

(define-test the-checkout-launcher-forwards-to-the-release
  "The checkout launcher boots the deployed release's core, through the
release launcher, and runs no make."
  (with-fake-release (tmp home)
    (multiple-value-bind (rc out err) (%launch tmp (%install-checkout-launcher tmp))
      (is = 0 rc "the launcher exited with the server's status")
      (is string= "" out "the launcher wrote nothing to stdout")
      (true (search "forwarding to" err) "stderr says it forwards")
      (true (search (format nil "--core ~A/core/dsmr.core" (%release-dir home "r1"))
                    (or (%boot tmp 1 "ARGV") ""))
            "the server booted the release's core")
      (is string= (%release-dir home "r1") (%boot tmp 1 "DSMR_RELEASE_ROOT")
          "the release root reached the server")
      (false (%make-ran-p tmp :wait 1) "no make ran"))))

(define-test the-checkout-launcher-refuses-without-a-release
  "With no current release the checkout launcher exits 78 naming make deploy
and make register, and boots nothing."
  (with-fake-release (tmp home)
    (%run "rm" (%path (merge-pathnames "current" home)))
    (multiple-value-bind (rc out err) (%launch tmp (%install-checkout-launcher tmp))
      (%refused-p rc out err tmp "make deploy REF=")
      (true (search "make register" err) "stderr names make register")
      (false (%make-ran-p tmp :wait 1) "no make ran"))))
