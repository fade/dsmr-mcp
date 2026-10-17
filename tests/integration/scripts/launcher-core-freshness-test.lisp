;;;; tests/integration/scripts/launcher-core-freshness-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Automated proof of the launcher's worker core decision.
;;;;
;;;; scripts/dsmr-mcp-launch.sh judges dsmr.core.worker by the same shell rule
;;;; it applies to dsmr.core (image and manifest present, recorded sbcl-version
;;;; equal to the running SBCL's, no file under a recorded root newer than the
;;;; image). It exports DSMR_WORKER_CORE to the server only when that rule
;;;; trusts the worker image, unsets it otherwise, and regenerates a stale
;;;; worker image in the background.
;;;;
;;;; The launcher is copied into a throwaway temp repo and the SBCL it runs is
;;;; replaced with a stub. The stub answers the version probe with "SBCL 0.0.0"
;;;; and, when launched as the server, records the DSMR_WORKER_CORE it was given
;;;; in a file and exits 0. A stub Makefile in the temp repo stands in for the
;;;; real build, so a background rebuild finishes at once and leaves a trace in
;;;; the rebuild log naming the target it ran.
;;;;
;;;; Gated integration: spawns subprocesses, so it lives outside the fast
;;;; umbrella. Skips cleanly when bash is unavailable. Temp paths are seeded with
;;;; a fresh random state and the temp tree is removed on exit.

(defpackage #:dsmr-mcp/tests/integration/scripts/launcher-core-freshness-test
  (:use #:cl #:zebra))

(in-package #:dsmr-mcp/tests/integration/scripts/launcher-core-freshness-test)

;;; ---------------------------------------------------------------------------
;;; Environment + temp scaffolding
;;; ---------------------------------------------------------------------------

(defparameter +old-epoch+ 946684800
  "A Unix time (2000-01-01) used to age a file so another one reads as newer.")

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
                   (format nil "dsmr-launch-freshness-~8,'0X" (random #xFFFFFFFF))
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

(defun %age-file (path)
  "Set PATH's modification time to +OLD-EPOCH+."
  (uiop:run-program (list "touch" "-d" (format nil "@~D" +old-epoch+)
                          (uiop:native-namestring path))))

(defun %launcher-source ()
  "Absolute path to the committed launcher script."
  (asdf:system-relative-pathname "dsmr-mcp" "scripts/dsmr-mcp-launch.sh"))

(defun %install-launcher (repo &key (server-sbcl-version nil))
  "Copy the committed launcher into REPO/scripts/, stand up a server core and
manifest, and write a stub Makefile whose core and core-worker targets only
announce themselves. With SERVER-SBCL-VERSION NIL the server manifest is empty,
so the launcher trusts the server core; a version string records that version,
which reads as stale against the stub's 0.0.0. Returns the launcher pathname."
  (let ((launcher (merge-pathnames "scripts/dsmr-mcp-launch.sh" repo)))
    (%write-file launcher (uiop:read-file-string (%launcher-source)))
    (%write-file (merge-pathnames "dsmr.core" repo) "")
    (%write-file (merge-pathnames "dsmr.core.manifest" repo)
                 (if server-sbcl-version
                     (format nil "sbcl-version ~A~%" server-sbcl-version)
                     ""))
    (%write-file (merge-pathnames "Makefile" repo)
                 (format nil "core:~%~C@echo built core~%~%~
                              core-worker:~%~C@echo built core-worker~%"
                         #\Tab #\Tab))
    launcher))

(defun %install-worker-core (repo &key (core-present t) (manifest :fresh)
                                       (source-newer nil))
  "Stand up REPO/dsmr.core.worker and its manifest. MANIFEST is :FRESH
(sbcl-version 0.0.0 plus one root), :FOREIGN-SBCL (sbcl-version 9.9.9 plus the
same root) or :MISSING. The root holds one source file; it is aged so the image
is newer, unless SOURCE-NEWER, in which case the image is aged instead. Returns
the worker core pathname."
  (let* ((core (merge-pathnames "dsmr.core.worker" repo))
         (root (merge-pathnames "roots/src/" repo))
         (source (merge-pathnames "source.lisp" root)))
    (%write-file source "(in-package #:cl-user)")
    (when core-present
      (%write-file core ""))
    (unless (eq manifest :missing)
      (%write-file (merge-pathnames "dsmr.core.worker.manifest" repo)
                   (format nil "sbcl-version ~A~%root ~A~%"
                           (ecase manifest
                             (:fresh "0.0.0")
                             (:foreign-sbcl "9.9.9"))
                           (uiop:native-namestring root))))
    (if (and source-newer core-present)
        (%age-file core)
        (%age-file source))
    core))

(defun %install-stub-sbcl (repo env-file)
  "Install a stub that stands in for SBCL. On a --version probe it prints a
version and exits 0. On a server launch it writes the DSMR_WORKER_CORE it
received (or <unset>) to ENV-FILE and exits 0, printing nothing on stdout.
Returns the stub pathname (executable)."
  (let ((stub (merge-pathnames "stub-sbcl.sh" repo)))
    (%write-file
     stub
     (format nil
             "#!/usr/bin/env bash~%~
              for a in \"$@\"; do~%~
              ~2@Tif [ \"$a\" = \"--version\" ]; then echo \"SBCL 0.0.0\"; exit 0; fi~%~
              done~%~
              printf 'DSMR_WORKER_CORE=%s\\n' \"${DSMR_WORKER_CORE-<unset>}\" > ~S~%~
              exit 0~%"
             (uiop:native-namestring env-file)))
    (uiop:run-program (list "chmod" "+x" (uiop:native-namestring stub)))
    stub))

(defun %inherited-env ()
  "The current process environment as a list of NAME=VALUE strings."
  (uiop:run-program '("env") :output :lines :ignore-error-status t))

(defun %launch (launcher stub &key inherited-worker-core)
  "Run LAUNCHER under bash with SBCL overridden to STUB. DSMR_WORKER_CORE is
removed from the inherited environment, or set to INHERITED-WORKER-CORE when
that is given. Returns the exit code and the launcher's stdout."
  (let* ((bash (%bash-path))
         (base (remove-if (lambda (kv)
                            (or (uiop:string-prefix-p "SBCL=" kv)
                                (uiop:string-prefix-p "DSMR_WORKER_CORE=" kv)))
                          (%inherited-env)))
         (env (append (list (format nil "SBCL=~A" (uiop:native-namestring stub)))
                      (when inherited-worker-core
                        (list (format nil "DSMR_WORKER_CORE=~A"
                                      inherited-worker-core)))
                      base)))
    (multiple-value-bind (out err rc)
        (uiop:run-program
         (list bash (uiop:native-namestring launcher))
         :input nil
         :output :string
         :error-output :string
         :ignore-error-status t
         :environment env)
      (declare (ignore err))
      (values rc out))))

(defun %seen-worker-core (env-file)
  "The DSMR_WORKER_CORE value the stub server recorded, or NIL if it never ran."
  (let ((text (and (probe-file env-file)
                   (string-trim '(#\Newline #\Return #\Space)
                                (uiop:read-file-string env-file))))
        (prefix "DSMR_WORKER_CORE="))
    (and text
         (uiop:string-prefix-p prefix text)
         (subseq text (length prefix)))))

(defun %rebuild-log (repo)
  "The temp repo's rebuild log text, or the empty string when there is none."
  (let ((log (merge-pathnames ".dsmr-core-rebuild.log" repo)))
    (or (and (probe-file log) (ignore-errors (uiop:read-file-string log)))
        "")))

(defun %await-log (repo needle &key (timeout 5))
  "Poll the temp repo's rebuild log for NEEDLE for up to TIMEOUT seconds.
Returns the log text once NEEDLE appears, or NIL when it never does."
  (let ((deadline (+ (get-internal-real-time)
                     (* timeout internal-time-units-per-second))))
    (loop
      (let ((text (%rebuild-log repo)))
        (when (search needle text)
          (return text)))
      (when (> (get-internal-real-time) deadline)
        (return nil))
      (sleep 0.05))))

(defmacro with-launcher-case ((repo env-file) &body body)
  "Skip when bash is unavailable; otherwise bind REPO to a fresh temp directory
and ENV-FILE to the file the stub server writes, and remove the tree on exit."
  `(if (null (%bash-path))
       (skip "bash is unavailable in this environment")
       (let ((,repo (%make-temp-dir)))
         (unwind-protect
              (let ((,env-file (merge-pathnames "server-env" ,repo)))
                ,@body)
           (ignore-errors (uiop:delete-directory-tree
                           ,repo :validate t :if-does-not-exist :ignore))))))

;;; ---------------------------------------------------------------------------
;;; Tests
;;; ---------------------------------------------------------------------------

(define-test a-fresh-worker-core-is-handed-to-the-server
  "A worker core with a matching sbcl-version and no newer source reaches the
server as DSMR_WORKER_CORE, naming the image by its absolute path."
  (with-launcher-case (repo env-file)
    (let* ((launcher (%install-launcher repo))
           (core (%install-worker-core repo))
           (stub (%install-stub-sbcl repo env-file)))
      (multiple-value-bind (rc out) (%launch launcher stub)
        (is = 0 rc "the launcher exited with the stub server's code")
        (is string= (uiop:native-namestring (truename core))
            (%seen-worker-core env-file)
            "the server was told where the worker core is")
        (is string= "" out "the launcher wrote nothing to stdout")))))

(define-test an-absent-worker-core-is-withheld-and-rebuilt-alone
  "With no worker core the server gets no DSMR_WORKER_CORE, and the launcher
rebuilds only the worker core, leaving a fresh server core alone."
  (with-launcher-case (repo env-file)
    (let* ((launcher (%install-launcher repo))
           (stub (%install-stub-sbcl repo env-file)))
      (multiple-value-bind (rc out) (%launch launcher stub)
        (is = 0 rc "the launcher exited with the stub server's code")
        (is string= "<unset>" (%seen-worker-core env-file)
            "the server was given no worker core")
        (is string= "" out "the launcher wrote nothing to stdout"))
      (let ((log (%await-log repo "make core-worker finished")))
        (true log "the rebuild log shows make core-worker ran to completion")
        (true (and log (search "(make core-worker)" log))
              "the rebuild log names the core-worker target")
        (false (and log (search "(make core)" log))
               "the server core was not rebuilt")))))

(define-test a-worker-core-older-than-its-source-is-withheld
  "A file under the worker manifest's recorded root that is newer than the
image makes the image stale, so the server gets no DSMR_WORKER_CORE."
  (with-launcher-case (repo env-file)
    (let* ((launcher (%install-launcher repo))
           (stub (progn (%install-worker-core repo :source-newer t)
                        (%install-stub-sbcl repo env-file))))
      (multiple-value-bind (rc out) (%launch launcher stub)
        (is = 0 rc "the launcher exited with the stub server's code")
        (is string= "<unset>" (%seen-worker-core env-file)
            "a worker core older than its source was withheld")
        (is string= "" out "the launcher wrote nothing to stdout"))
      (true (%await-log repo "make core-worker finished")
            "the stale worker core was rebuilt in the background"))))

(define-test a-worker-core-built-by-another-sbcl-is-withheld
  "A worker manifest recording a different sbcl-version than the running SBCL
makes the image unusable, so the server gets no DSMR_WORKER_CORE."
  (with-launcher-case (repo env-file)
    (let* ((launcher (%install-launcher repo))
           (stub (progn (%install-worker-core repo :manifest :foreign-sbcl)
                        (%install-stub-sbcl repo env-file))))
      (multiple-value-bind (rc out) (%launch launcher stub)
        (is = 0 rc "the launcher exited with the stub server's code")
        (is string= "<unset>" (%seen-worker-core env-file)
            "a worker core from another SBCL build was withheld")
        (is string= "" out "the launcher wrote nothing to stdout"))
      (true (%await-log repo "make core-worker finished")
            "the foreign worker core was rebuilt in the background"))))

(define-test a-worker-core-without-a-manifest-is-withheld
  "A worker core with no manifest cannot be judged, so the server gets no
DSMR_WORKER_CORE."
  (with-launcher-case (repo env-file)
    (let* ((launcher (%install-launcher repo))
           (stub (progn (%install-worker-core repo :manifest :missing)
                        (%install-stub-sbcl repo env-file))))
      (multiple-value-bind (rc out) (%launch launcher stub)
        (is = 0 rc "the launcher exited with the stub server's code")
        (is string= "<unset>" (%seen-worker-core env-file)
            "a worker core with no manifest was withheld")
        (is string= "" out "the launcher wrote nothing to stdout"))
      (true (%await-log repo "make core-worker finished")
            "the unjudgeable worker core was rebuilt in the background"))))

(define-test a-fresh-worker-core-is-handed-over-while-the-server-core-rebuilds
  "The two images are judged independently: a stale server core does not stop
a fresh worker core reaching the server, and the rebuild it triggers is the
server's (make core, which rebuilds both)."
  (with-launcher-case (repo env-file)
    (let* ((launcher (%install-launcher repo :server-sbcl-version "9.9.9"))
           (core (%install-worker-core repo))
           (stub (%install-stub-sbcl repo env-file)))
      (multiple-value-bind (rc out) (%launch launcher stub)
        (is = 0 rc "the launcher exited with the stub server's code")
        (is string= (uiop:native-namestring (truename core))
            (%seen-worker-core env-file)
            "the fresh worker core was handed over despite the stale server core")
        (is string= "" out "the launcher wrote nothing to stdout"))
      (let ((log (%await-log repo "make core finished")))
        (true log "the rebuild log shows make core ran to completion")
        (true (and log (search "(make core)" log))
              "the rebuild log names the core target")
        (false (and log (search "(make core-worker)" log))
               "no separate worker rebuild was started")))))

(define-test an-inherited-worker-core-path-is-not-trusted
  "A DSMR_WORKER_CORE the launcher inherits is never passed through: with no
trustworthy worker core of its own the launcher unsets it."
  (with-launcher-case (repo env-file)
    (let* ((launcher (%install-launcher repo))
           (stub (%install-stub-sbcl repo env-file)))
      (multiple-value-bind (rc out)
          (%launch launcher stub :inherited-worker-core "/elsewhere/dsmr.core.worker")
        (is = 0 rc "the launcher exited with the stub server's code")
        (is string= "<unset>" (%seen-worker-core env-file)
            "the inherited worker core path did not reach the server")
        (is string= "" out "the launcher wrote nothing to stdout"))
      (true (%await-log repo "make core-worker finished")
            "the missing worker core was rebuilt in the background"))))
