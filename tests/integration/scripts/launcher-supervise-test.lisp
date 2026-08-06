;;;; tests/integration/scripts/launcher-supervise-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Automated proof of the launcher supervise loop.
;;;;
;;;; scripts/dsmr-mcp-launch.sh relaunches the server ONLY when it exits with
;;;; the restart sentinel (75 / EX_TEMPFAIL) and exits the launcher on any other
;;;; code. A live MCP client cannot be scripted here, so the SBCL the launcher
;;;; runs is replaced with a stub: the launcher is copied into a throwaway temp
;;;; repo whose dsmr.core/manifest are present-and-fresh, so the launcher takes
;;;; the fast (core) path and runs the stub instead of a real image. The stub
;;;; counts its server invocations through a file and chooses an exit code by
;;;; invocation number; the test then asserts the relaunch behavior from the
;;;; invocation count and the launcher's own exit code.
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
  "Absolute path to the committed launcher script."
  (asdf:system-relative-pathname "dsmr-mcp" "scripts/dsmr-mcp-launch.sh"))

(defun %install-launcher (repo)
  "Copy the committed launcher into REPO/scripts/ and stand up a present,
fresh-looking core + manifest there, so the launcher resolves REPO from its own
location and takes the fast (core) path. The manifest is intentionally empty: no
recorded sbcl-version and no source roots means core_is_fresh skips both
staleness checks and trusts the core. Returns the installed launcher pathname."
  (let ((launcher (merge-pathnames "scripts/dsmr-mcp-launch.sh" repo))
        (core (merge-pathnames "dsmr.core" repo))
        (manifest (merge-pathnames "dsmr.core.manifest" repo)))
    (%write-file launcher (uiop:read-file-string (%launcher-source)))
    (%write-file core "")
    (%write-file manifest "")
    launcher))

(defun %install-stub-sbcl (repo count-file exit-plan)
  "Install a stub that stands in for SBCL. On a --version probe it prints a
version and exits 0 WITHOUT counting (core_is_fresh probes the version). On a
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
  "Run LAUNCHER under bash with SBCL overridden to STUB in an otherwise inherited
environment. Returns the launcher's integer exit code."
  (let ((bash (%bash-path))
        (env (cons (format nil "SBCL=~A" (namestring stub))
                   (remove-if (lambda (kv) (uiop:string-prefix-p "SBCL=" kv))
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
  "Bind REPO-VAR to a fresh temp directory and remove the tree on exit."
  `(let ((,repo-var (%make-temp-dir)))
     (unwind-protect (progn ,@body)
       (ignore-errors (uiop:delete-directory-tree
                       ,repo-var :validate t :if-does-not-exist :ignore)))))

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
