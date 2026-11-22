;;;; tests/integration/scripts/launcher-supervise-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Automated proof of the launcher supervise loop.
;;;;
;;;; scripts/release-launch.sh relaunches the server ONLY when it exits with
;;;; the restart sentinel (75 / EX_TEMPFAIL) and exits the launcher on any other
;;;; code. A live MCP client cannot be scripted here, so the SBCL the launcher
;;;; runs is replaced with a stub: the launcher is installed as bin/dsmr-mcp-launch
;;;; of a throwaway fake release holding a decoy core whose manifest records the
;;;; stub's SBCL version, so the launcher boots the stub in place of a real
;;;; image. The stub passes the boot probe, counts its server invocations
;;;; through a file and chooses an exit code by invocation number; the test
;;;; then asserts the relaunch behaviour from the invocation count and the
;;;; launcher's own exit code.
;;;;
;;;; Gated integration: spawns subprocesses, so it lives outside the fast
;;;; umbrella. Skips cleanly when bash is unavailable. Temp paths are seeded with
;;;; a fresh random state and the temp tree is removed on exit.

(defpackage #:dsmr-mcp/tests/integration/scripts/launcher-supervise-test
  (:use #:cl #:zebra))

(in-package #:dsmr-mcp/tests/integration/scripts/launcher-supervise-test)

;;; ---------------------------------------------------------------------------
;;; Environment + temp scaffolding
;;; ---------------------------------------------------------------------------

(defun %bash-path ()
  "Absolute path to a bash binary, or NIL if none is available."
  (or (ignore-errors
        (let ((r (string-trim '(#\Newline #\Return #\Space)
                              (uiop:run-program '("which" "bash")
                                                :output :string
                                                :ignore-error-status t))))
          (and (plusp (length r)) r)))
      (let ((p (find-if #'probe-file '("/bin/bash" "/usr/bin/bash"))))
        (and p (namestring p)))))

(defun %make-temp-dir ()
  "Create and return a uniquely named temp directory. Seeds a fresh random
state per call so two calls in the same image never collide on the name."
  (let ((*random-state* (make-random-state t)))
    (loop
      (let ((dir (uiop:ensure-directory-pathname
                  (merge-pathnames
                   (format nil "dsmr-launch-supervise-~8,'0X" (random #xFFFFFFFF))
                   (uiop:temporary-directory)))))
        (unless (probe-file dir)
          (ensure-directories-exist dir)
          (return dir))))))

(defun %write-file (path string)
  "Write STRING to PATH, creating parents."
  (ensure-directories-exist path)
  (with-open-file (s path :direction :output
                          :if-exists :supersede :if-does-not-exist :create)
    (write-string string s))
  path)

(defun %launcher-source ()
  "Absolute path to the release launcher script."
  (asdf:system-relative-pathname "dsmr-mcp" "scripts/release-launch.sh"))

(defun %install-launcher (repo)
  "Make REPO a fake release: the release launcher as bin/dsmr-mcp-launch,
scripts/release-paths.sh, a decoy core/dsmr.core whose manifest records
sbcl-version 0.0.0 (the version the stub SBCL reports), and a MANIFEST. Removes
group and world write so the launcher accepts it. Returns the launcher
pathname."
  (let ((launcher (merge-pathnames "bin/dsmr-mcp-launch" repo)))
    (%write-file launcher (uiop:read-file-string (%launcher-source)))
    (%write-file (merge-pathnames "scripts/release-paths.sh" repo)
                 (uiop:read-file-string
                  (asdf:system-relative-pathname "dsmr-mcp" "scripts/release-paths.sh")))
    (%write-file (merge-pathnames "core/dsmr.core" repo) "")
    (%write-file (merge-pathnames "core/dsmr.core.manifest" repo)
                 (format nil "sbcl-version 0.0.0~%"))
    (%write-file (merge-pathnames "MANIFEST" repo) (format nil "commit 0~%"))
    (uiop:run-program (list "chmod" "-R" "go-w" (namestring repo)))
    launcher))

(defun %install-stub-sbcl (repo count-file exit-plan)
  "Install a stub that stands in for SBCL. On a --version probe it prints a
version, and on the boot probe ((sb-ext:exit)) it exits 0, neither counted. On a
server launch it increments COUNT-FILE and exits with the code EXIT-PLAN maps
its invocation number to: EXIT-PLAN is an alist of (n . code); an invocation
number absent from the plan exits 0. Returns the stub pathname (executable)."
  (let* ((stub (merge-pathnames "stub-sbcl.sh" repo))
         (cases (with-output-to-string (s)
                  (loop for (n . code) in exit-plan
                        do (format s "  if [ \"$n\" -eq ~D ]; then exit ~D; fi~%"
                                   n code)))))
    (%write-file
     stub
     (format nil
             "#!/usr/bin/env bash~%~
              for a in \"$@\"; do~%~
              ~2@Tif [ \"$a\" = \"--version\" ]; then echo \"SBCL 0.0.0\"; exit 0; fi~%~
              ~2@Tif [ \"$a\" = \"(sb-ext:exit)\" ]; then exit 0; fi~%~
              done~%~
              count_file=~S~%~
              n=$(cat \"$count_file\" 2>/dev/null || echo 0)~%~
              n=$((n + 1))~%~
              echo \"$n\" > \"$count_file\"~%~
              ~Aexit 0~%"
             (namestring count-file)
             cases))
    (uiop:run-program (list "chmod" "+x" (namestring stub)))
    stub))

(defun %inherited-env ()
  "The current process environment as a list of NAME=VALUE strings."
  (uiop:run-program '("env") :output :lines :ignore-error-status t))

(defun %launch (launcher stub)
  "Run LAUNCHER under bash with SBCL overridden to STUB and XDG_STATE_HOME
inside the fake release, in an otherwise inherited environment with no DSMR_
variable. Returns the launcher's integer exit code."
  (let* ((bash (%bash-path))
         (state (merge-pathnames "state/"
                                 (uiop:pathname-parent-directory-pathname
                                  (uiop:pathname-directory-pathname launcher))))
         (env (list* (format nil "SBCL=~A" (namestring stub))
                     (format nil "XDG_STATE_HOME=~A"
                             (string-right-trim "/" (uiop:native-namestring state)))
                     (remove-if (lambda (kv)
                                  (or (uiop:string-prefix-p "SBCL=" kv)
                                      (uiop:string-prefix-p "XDG_STATE_HOME=" kv)
                                      (uiop:string-prefix-p "DSMR_" kv)))
                                (%inherited-env)))))
    (nth-value
     2
     (uiop:run-program
      (list bash (namestring launcher))
      :input nil
      :output :string
      :error-output :string
      :ignore-error-status t
      :environment env))))

(defmacro with-temp-repo ((repo-var) &body body)
  "Bind REPO-VAR to <tmp>/home/releases/r/ under a fresh temp directory, laid
out as a deploy home so the launcher's checks of the home and releases/ pass,
and remove the tree on exit."
  (let ((tmp (gensym "TMP")))
    `(let* ((,tmp (%make-temp-dir))
            (,repo-var (merge-pathnames "home/releases/r/" ,tmp)))
       (ensure-directories-exist ,repo-var)
       (unwind-protect (progn ,@body)
         (ignore-errors (uiop:delete-directory-tree
                         ,tmp :validate t :if-does-not-exist :ignore))))))

;;; ---------------------------------------------------------------------------
;;; Tests
;;; ---------------------------------------------------------------------------

(define-test relaunches-once-on-the-sentinel-then-exits-clean
  "A stub that exits 75 on its first server launch and 0 on its second proves
the supervise loop: the launcher relaunches once on the sentinel and then exits
0 when the relaunched server exits cleanly."
  (let ((bash (%bash-path)))
    (if (null bash)
        (skip "bash is unavailable in this environment")
        (with-temp-repo (repo)
          (let* ((launcher (%install-launcher repo))
                 (count-file (merge-pathnames "invocations" repo))
                 (stub (%install-stub-sbcl repo count-file '((1 . 75) (2 . 0))))
                 (rc (%launch launcher stub))
                 (invocations (parse-integer
                               (string-trim '(#\Newline #\Return #\Space)
                                            (uiop:read-file-string count-file)))))
            (is = 2 invocations
                "the launcher ran the server twice (relaunched once on 75)")
            (is = 0 rc "the launcher exited 0 after the clean second run"))))))

(define-test does-not-relaunch-on-a-non-sentinel-exit
  "A stub that exits with a non-sentinel code (1) on its first launch proves the
launcher does NOT relaunch: it runs the server once and exits with that same
code."
  (let ((bash (%bash-path)))
    (if (null bash)
        (skip "bash is unavailable in this environment")
        (with-temp-repo (repo)
          (let* ((launcher (%install-launcher repo))
                 (count-file (merge-pathnames "invocations" repo))
                 (stub (%install-stub-sbcl repo count-file '((1 . 1))))
                 (rc (%launch launcher stub))
                 (invocations (parse-integer
                               (string-trim '(#\Newline #\Return #\Space)
                                            (uiop:read-file-string count-file)))))
            (is = 1 invocations "the launcher ran the server exactly once")
            (is = 1 rc "the launcher propagated the non-sentinel exit code"))))))
