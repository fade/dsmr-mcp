;;;; tests/install/config-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Zebra tests for the installer config core and the Claude IO layer.
;;;; All transforms run on in-memory jzon objects and temp files — the real
;;;; ~/.claude.json is never read or written.

(defpackage #:dsmr-mcp/tests/install/config-test
  (:use #:cl #:zebra)
  (:local-nicknames (#:jzon #:com.inuoe.jzon))
  (:import-from #:dsmr-mcp/src/install/config
                #:canonical-server-entry
                #:ensure-server
                #:has-cl-mcp-p
                #:+dsmr-server-name+
                #:+cl-mcp-server-name+)
  (:import-from #:dsmr-mcp/src/install/claude
                #:install-into-claude
                #:dsmr-home
                #:wrapper-launcher-path
                #:launcher-if-present))

(in-package #:dsmr-mcp/tests/install/config-test)

;;; Helpers -------------------------------------------------------------------

(defun ht (&rest kvs)
  "Build an equal-keyed hash-table from alternating KEY VALUE pairs."
  (let ((h (make-hash-table :test 'equal)))
    (loop for (k v) on kvs by #'cddr do (setf (gethash k h) v))
    h))

(defun servers (config)
  (gethash "mcpServers" config))

(defun has-server-p (config name)
  (and (hash-table-p (servers config))
       (nth-value 1 (gethash name (servers config)))))

(defmacro with-env ((&rest bindings) &body body)
  "Run BODY with each (NAME VALUE) of BINDINGS set in the environment, restoring
the previous values on exit. A variable that was absent is restored as the empty
string, which every reader under test treats as unset."
  (let ((saved (gensym "SAVED")) (pair (gensym "PAIR")))
    `(let ((,saved (list ,@(loop for (name) in bindings
                                 collect `(cons ,name (uiop:getenv ,name))))))
       (unwind-protect
            (progn
              ,@(loop for (name value) in bindings
                      collect `(setf (uiop:getenv ,name) ,value))
              ,@body)
         (dolist (,pair ,saved)
           (setf (uiop:getenv (car ,pair)) (or (cdr ,pair) "")))))))

(defun %temp-dir (stem)
  "Create and return a fresh directory under the temporary directory, named for STEM."
  (let ((dir (uiop:ensure-directory-pathname
              (merge-pathnames
               (format nil "~A-~36R" stem (random (expt 2 48) (make-random-state t)))
               (uiop:temporary-directory)))))
    (ensure-directories-exist dir)
    dir))

(defmacro with-temp-dir ((var stem) &body body)
  "Bind VAR to a fresh temp directory for BODY and delete the tree on exit."
  `(let ((,var (%temp-dir ,stem)))
     (unwind-protect (progn ,@body)
       (uiop:delete-directory-tree ,var :validate t :if-does-not-exist :ignore))))

(defun %make-release (home)
  "Create HOME/releases/r1/bin/dsmr-mcp-launch and link HOME/current to releases/r1.
Return the launcher's namestring through current."
  (let ((launcher (merge-pathnames "releases/r1/bin/dsmr-mcp-launch" home)))
    (ensure-directories-exist launcher)
    (with-open-file (s launcher :direction :output :if-exists :supersede)
      (write-line "#!/bin/sh" s))
    (uiop:run-program (list "ln" "-s" "releases/r1"
                            (namestring (merge-pathnames "current" home))))
    (namestring (merge-pathnames "current/bin/dsmr-mcp-launch" home))))

(defmacro with-release ((launcher-var) &body body)
  "Run BODY with DSMR_HOME at a temp deploy home holding a release, LAUNCHER-VAR
bound to the launcher's path through current."
  (let ((home (gensym "HOME")))
    `(with-temp-dir (,home "dsmr-install-release")
       (let ((,launcher-var (%make-release ,home)))
         (declare (ignorable ,launcher-var))
         (with-env (("DSMR_HOME" (namestring ,home)))
           ,@body)))))

(defun %write-json (path object)
  "Write OBJECT to PATH as pretty JSON, replacing any existing file."
  (with-open-file (out path :direction :output :if-exists :supersede
                            :if-does-not-exist :create :external-format :utf-8)
    (write-string (jzon:stringify object :pretty t) out)))

(defun %default-read-roots ()
  "Return the DSMR_READ_ROOTS value the installer writes into an entry that has none."
  (namestring (merge-pathnames "SourceCode/lisp/" (user-homedir-pathname))))

;;; canonical-server-entry ----------------------------------------------------

(defun %find-arg (args predicate)
  "Return the first member of ARGS satisfying PREDICATE, or NIL."
  (find-if predicate args))

(define-test canonical-entry-has-stdio-shape
  (let ((entry (canonical-server-entry +dsmr-server-name+)))
    (is string= "stdio" (gethash "type" entry))
    (is string= "sbcl" (gethash "command" entry))
    (true (vectorp (gethash "args" entry)))
    (let ((args (coerce (gethash "args" entry) 'list)))
      ;; The args carry the stderr-wrapped load + run forms for the named system.
      (true (member "(let ((*standard-output* *error-output*) (*trace-output* *error-output*) (*debug-io* (make-two-way-stream *standard-input* *error-output*))) (asdf:load-system :dsmr-mcp))"
                    args :test #'string=)
            "asdf load is wrapped to *error-output*")
      (true (member "(dsmr-mcp:run :transport :stdio)" args :test #'string=)))))

(define-test canonical-entry-keeps-stdout-clean
  "The launcher must keep stdout (the JSON-RPC channel) free of the SBCL/
Quicklisp bootstrap banner and ASDF load chatter."
  (let* ((entry (canonical-server-entry +dsmr-server-name+))
         (args  (coerce (gethash "args" entry) 'list)))
    ;; --no-userinit so the operator's ~/.sbclrc (and its quickload banner) never runs.
    (true (member "--no-userinit" args :test #'string=)
          "--no-userinit suppresses the .sbclrc quickload banner")
    ;; setup.lisp is loaded explicitly, redirected to *error-output*, and
    ;; guarded by probe-file so it no-ops gracefully when Quicklisp is absent.
    (let ((setup-form (%find-arg args
                                 (lambda (a)
                                   (and (stringp a)
                                        (search "quicklisp/setup.lisp" a))))))
      (true setup-form "explicit setup.lisp load present")
      (when setup-form
        (true (search "*error-output*" setup-form)
              "setup.lisp load redirected to *error-output*")
        (true (search "probe-file" setup-form)
              "setup.lisp load guarded so it no-ops when absent")))
    ;; The asdf load form is wrapped so compile+load output goes to stderr.
    (let ((load-form (%find-arg args
                                (lambda (a)
                                  (and (stringp a)
                                       (search "asdf:load-system" a))))))
      (true load-form "asdf load form present")
      (when load-form
        (true (search "*error-output*" load-form)
              "asdf load wrapped to *error-output*")))))

(define-test canonical-entry-redirects-debug-io
  "SLYNK emits its \"ASDF loader finished.\" banner to *debug-io*, not
*standard-output*. The load form must rebind *debug-io* (and *trace-output*)
to *error-output* alongside *standard-output*, or that one banner line still
leaks onto fd 1 and breaks the stdio handshake."
  (let* ((entry (canonical-server-entry +dsmr-server-name+))
         (args  (coerce (gethash "args" entry) 'list))
         (load-form (%find-arg args
                               (lambda (a)
                                 (and (stringp a)
                                      (search "asdf:load-system" a))))))
    (true load-form "asdf load form present")
    (when load-form
      (true (search "*debug-io*" load-form)
            "load form rebinds *debug-io* (carries the SLYNK loader banner)")
      (true (search "*trace-output*" load-form)
            "load form rebinds *trace-output*")
      (true (search "*standard-output*" load-form)
            "load form rebinds *standard-output*"))))

(define-test canonical-entry-launcher-emits-wrapper-command
  "With a launcher path, the entry invokes the wrapper directly with no args
— the prebuilt-core lifecycle launcher — instead of the source-load argv."
  (let ((entry (canonical-server-entry
                +dsmr-server-name+
                :launcher "/opt/dsmr/scripts/dsmr-mcp-launch.sh")))
    (is string= "stdio" (gethash "type" entry))
    (is string= "/opt/dsmr/scripts/dsmr-mcp-launch.sh" (gethash "command" entry))
    (true (vectorp (gethash "args" entry)))
    (is = 0 (length (gethash "args" entry)) "wrapper launcher takes no args")))

(define-test canonical-entry-without-launcher-is-source-load
  "No launcher keeps the source-load fallback shape (sbcl + a non-empty argv)."
  (let ((entry (canonical-server-entry +dsmr-server-name+)))
    (is string= "sbcl" (gethash "command" entry))
    (true (plusp (length (gethash "args" entry))))))

(define-test ensure-server-threads-launcher
  "ensure-server forwards :launcher so the written dsmr-mcp entry is the
wrapper command."
  (let* ((out (ensure-server nil
                             :launcher "/opt/dsmr/scripts/dsmr-mcp-launch.sh"))
         (entry (gethash +dsmr-server-name+ (servers out))))
    (is string= "/opt/dsmr/scripts/dsmr-mcp-launch.sh" (gethash "command" entry))
    (is = 0 (length (gethash "args" entry)))))

(define-test the-launcher-path-comes-from-dsmr-home
  "The launcher path is <DSMR_HOME>/current/bin/dsmr-mcp-launch, through the
current link, whether or not a release exists; a relative DSMR_HOME signals."
  (with-temp-dir (tmp "dsmr-install-home")
    (let ((home (namestring (merge-pathnames "home/" tmp)))
          (expected (namestring (merge-pathnames "home/current/bin/dsmr-mcp-launch" tmp))))
      (with-env (("DSMR_HOME" home) ("XDG_DATA_HOME" "/nonexistent/data"))
        (is string= expected (wrapper-launcher-path))
        (false (launcher-if-present) "no release, so no launcher"))
      (with-env (("DSMR_HOME" (string-right-trim "/" home)))
        (is string= expected (wrapper-launcher-path)
            "a DSMR_HOME without a trailing slash names the same path"))
      (with-env (("DSMR_HOME" "relative/home"))
        (fail (dsmr-home) error "a relative DSMR_HOME signals")))))

(define-test the-launcher-path-follows-xdg-data-home
  "With DSMR_HOME unset the deploy home is XDG_DATA_HOME/dsmr-mcp/, and with
both unset it is ~/.local/share/dsmr-mcp/."
  (with-temp-dir (tmp "dsmr-install-xdg")
    (with-env (("DSMR_HOME" "")
               ("XDG_DATA_HOME" (namestring (merge-pathnames "data/" tmp))))
      (is string= (namestring (merge-pathnames "data/dsmr-mcp/current/bin/dsmr-mcp-launch" tmp))
          (wrapper-launcher-path)))
    (with-env (("DSMR_HOME" "") ("XDG_DATA_HOME" "") ("HOME" (namestring tmp)))
      (is string= (namestring (merge-pathnames ".local/share/dsmr-mcp/current/bin/dsmr-mcp-launch" tmp))
          (wrapper-launcher-path)))))

(define-test registering-without-a-release-is-refused-and-writes-nothing
  "With no launcher under <DSMR_HOME>/current, install-into-claude signals an
error naming make deploy, leaves an existing config byte-identical with no
backup beside it, and creates no config where none existed."
  (with-temp-dir (tmp "dsmr-install-refuse")
    (let ((path (merge-pathnames "claude.json" tmp))
          (absent (merge-pathnames "absent.json" tmp)))
      (%write-json path (ht "mcpServers" (ht "other" (ht "type" "stdio"))))
      (let ((before (uiop:read-file-string path)))
        (with-env (("DSMR_HOME" (namestring (merge-pathnames "home/" tmp))))
          (let ((c (handler-case (progn (install-into-claude :path path) nil)
                     (error (e) e))))
            (true c "install-into-claude signals without a release")
            (when c
              (true (search "make deploy" (princ-to-string c))
                    "the error names make deploy")))
          (is string= before (uiop:read-file-string path) "config unchanged")
          (is = 1 (length (uiop:directory-files tmp)) "no backup written")
          (fail (install-into-claude :path absent) error)
          (false (probe-file absent) "no config created"))))))

(define-test re-registering-keeps-the-entry-environment
  "Registering over an existing dsmr-mcp entry points it at the release launcher
and keeps its env keys and values, adding DSMR_READ_ROOTS; other servers stay."
  (with-release (launcher)
    (with-temp-dir (tmp "dsmr-install-reregister")
      (let ((path (merge-pathnames "claude.json" tmp)))
        (%write-json path
                     (ht "mcpServers"
                         (ht +dsmr-server-name+
                             (ht "type" "stdio"
                                 "command" "/old/scripts/dsmr-mcp-launch.sh"
                                 "args" (vector)
                                 "env" (ht "DSMR_MODE" "auto"
                                           "DSMR_LOG_LEVEL" "info"
                                           "DSMR_RELATED_PROJECTS" "/x/"))
                             "other" (ht "type" "stdio" "command" "other"))))
        (install-into-claude :path path)
        (let* ((parsed (jzon:parse (uiop:read-file-string path)))
               (entry (gethash +dsmr-server-name+ (servers parsed)))
               (env (gethash "env" entry)))
          (is string= launcher (gethash "command" entry))
          (true (search "/current/bin/dsmr-mcp-launch" (gethash "command" entry))
                "the command goes through current, not the release it names")
          (is = 0 (length (gethash "args" entry)))
          (is string= "auto" (gethash "DSMR_MODE" env))
          (is string= "info" (gethash "DSMR_LOG_LEVEL" env))
          (is string= "/x/" (gethash "DSMR_RELATED_PROJECTS" env))
          (is string= (%default-read-roots) (gethash "DSMR_READ_ROOTS" env))
          (is string= "other" (gethash "command" (gethash "other" (servers parsed)))))))))

(define-test read-roots-are-added-only-when-absent
  "ensure-server adds DSMR_READ_ROOTS with the default value when the entry has
none, and keeps a value the entry already carries."
  (let* ((fresh (ensure-server nil :launcher "/h/current/bin/dsmr-mcp-launch"))
         (env (gethash "env" (gethash +dsmr-server-name+ (servers fresh)))))
    (is string= (%default-read-roots) (gethash "DSMR_READ_ROOTS" env))
    (is = 1 (hash-table-count env) "only the read roots are added"))
  (let* ((config (ht "mcpServers"
                     (ht +dsmr-server-name+
                         (ht "type" "stdio" "command" "x"
                             "env" (ht "DSMR_READ_ROOTS" "/a:/b")))))
         (out (ensure-server config :launcher "/h/current/bin/dsmr-mcp-launch"))
         (env (gethash "env" (gethash +dsmr-server-name+ (servers out)))))
    (is string= "/a:/b" (gethash "DSMR_READ_ROOTS" env))
    (is string= "/a:/b"
        (gethash "DSMR_READ_ROOTS"
                 (gethash "env" (gethash +dsmr-server-name+ (servers config))))
        "the input entry is not mutated")))

(define-test canonical-entry-system-name-parameterized
  (let ((entry (canonical-server-entry "cl-mcp")))
    (let ((args (coerce (gethash "args" entry) 'list)))
      (true (member "(let ((*standard-output* *error-output*) (*trace-output* *error-output*) (*debug-io* (make-two-way-stream *standard-input* *error-output*))) (asdf:load-system :cl-mcp))"
                    args :test #'string=))
      (true (member "(cl-mcp:run :transport :stdio)" args :test #'string=)))))

;;; ensure-server: missing mcpServers -----------------------------------------

(define-test adds-dsmr-when-no-mcpservers
  ;; A config with no mcpServers key at all.
  (let* ((config (ht "theme" "dark"))
         (out (ensure-server config)))
    (true (hash-table-p (servers out)) "mcpServers created")
    (true (has-server-p out +dsmr-server-name+) "dsmr-mcp present")
    ;; Input config is not mutated.
    (false (gethash "mcpServers" config) "input left without mcpServers")))

(define-test handles-nil-config
  (let ((out (ensure-server nil)))
    (true (hash-table-p (servers out)))
    (true (has-server-p out +dsmr-server-name+))))

;;; ensure-server: preservation -----------------------------------------------

(define-test preserves-unrelated-keys-and-servers
  (let* ((srv (ht "other-server" (ht "type" "stdio")))
         (config (ht "mcpServers" srv "theme" "dark" "fontSize" 14))
         (out (ensure-server config)))
    (is string= "dark" (gethash "theme" out) "unrelated top-level key kept")
    (is = 14 (gethash "fontSize" out) "unrelated top-level key kept")
    (true (has-server-p out "other-server") "unrelated server kept")
    (true (has-server-p out +dsmr-server-name+) "dsmr-mcp added")
    ;; Original servers map not mutated.
    (false (nth-value 1 (gethash +dsmr-server-name+ srv))
           "input mcpServers not mutated")))

;;; ensure-server: cl-mcp policy ----------------------------------------------

(define-test keep-leaves-cl-mcp-intact
  (let* ((srv (ht +cl-mcp-server-name+ (canonical-server-entry "cl-mcp")))
         (config (ht "mcpServers" srv))
         (out (ensure-server config :on-existing-cl-mcp :keep)))
    (true (has-server-p out +cl-mcp-server-name+) "cl-mcp kept")
    (true (has-server-p out +dsmr-server-name+) "dsmr-mcp added")))

(define-test remove-deletes-cl-mcp-keeps-dsmr
  (let* ((srv (ht +cl-mcp-server-name+ (canonical-server-entry "cl-mcp")))
         (config (ht "mcpServers" srv))
         (out (ensure-server config :on-existing-cl-mcp :remove)))
    (false (has-server-p out +cl-mcp-server-name+) "cl-mcp removed")
    (true (has-server-p out +dsmr-server-name+) "dsmr-mcp added")))

(define-test replace-deletes-cl-mcp-keeps-dsmr
  (let* ((srv (ht +cl-mcp-server-name+ (canonical-server-entry "cl-mcp")))
         (config (ht "mcpServers" srv))
         (out (ensure-server config :on-existing-cl-mcp :replace)))
    (false (has-server-p out +cl-mcp-server-name+) "cl-mcp removed")
    (true (has-server-p out +dsmr-server-name+) "dsmr-mcp added")))

;;; ensure-server: idempotence ------------------------------------------------

(define-test applying-twice-equals-applying-once
  (let* ((config (ht "theme" "dark"))
         (once (ensure-server config))
         (twice (ensure-server once)))
    (is string= (jzon:stringify once) (jzon:stringify twice)
        "second application is a no-op")))

(define-test idempotent-under-remove-policy
  (let* ((srv (ht +cl-mcp-server-name+ (canonical-server-entry "cl-mcp")))
         (config (ht "mcpServers" srv))
         (once (ensure-server config :on-existing-cl-mcp :remove))
         (twice (ensure-server once :on-existing-cl-mcp :remove)))
    (is string= (jzon:stringify once) (jzon:stringify twice))))

;;; has-cl-mcp-p detector -----------------------------------------------------

(define-test detector-true-when-cl-mcp-present
  (let ((config (ht "mcpServers" (ht +cl-mcp-server-name+ (ht "type" "stdio")))))
    (true (has-cl-mcp-p config))))

(define-test detector-false-when-cl-mcp-absent
  (let ((config (ht "mcpServers" (ht +dsmr-server-name+ (ht "type" "stdio")))))
    (false (has-cl-mcp-p config)))
  ;; Also false when mcpServers is missing entirely.
  (false (has-cl-mcp-p (ht "theme" "dark")))
  (false (has-cl-mcp-p nil)))

;;; Claude IO layer (temp path only) ------------------------------------------

(define-test io-creates-config-when-absent
  (with-release (launcher)
    (with-temp-dir (dir "dsmr-install-io-create")
      (let* ((path (merge-pathnames ".claude.json" dir))
             (result (install-into-claude :path path)))
        (is eq :created (getf result :action-taken))
        (false (getf result :backup-path) "no backup for a fresh create")
        (true (probe-file path) "config file written")
        ;; Result re-parses and carries the dsmr-mcp entry naming the release.
        (let* ((parsed (jzon:parse (uiop:read-file-string path)))
               (srv (gethash "mcpServers" parsed)))
          (is string= launcher
              (gethash "command" (gethash +dsmr-server-name+ srv))))))))

(define-test io-backs-up-and-reparses-on-update
  (with-release (launcher)
    (with-temp-dir (dir "dsmr-install-io-update")
      (let ((path (merge-pathnames ".claude.json" dir)))
        ;; Seed an existing config that already contains a cl-mcp entry.
        (%write-json path
                     (ht "theme" "dark"
                         "mcpServers"
                         (ht +cl-mcp-server-name+ (canonical-server-entry "cl-mcp"))))
        (let ((result (install-into-claude :path path
                                           :on-existing-cl-mcp :keep)))
          (is eq :updated-kept-cl-mcp (getf result :action-taken))
          (true (getf result :cl-mcp-was-present) "cl-mcp detected")
          (let ((backup (getf result :backup-path)))
            (true backup "backup path returned")
            (true (probe-file backup) "backup file created")
            ;; Backup holds the ORIGINAL content (still single-server).
            (let* ((orig (jzon:parse (uiop:read-file-string backup)))
                   (orig-srv (gethash "mcpServers" orig)))
              (false (nth-value 1 (gethash +dsmr-server-name+ orig-srv))
                     "backup is the pre-install config")))
          ;; New file re-parses and has both servers plus the kept top-level key.
          (let* ((parsed (jzon:parse (uiop:read-file-string path)))
                 (srv (gethash "mcpServers" parsed)))
            (is string= "dark" (gethash "theme" parsed))
            (true (nth-value 1 (gethash +dsmr-server-name+ srv)))
            (true (nth-value 1 (gethash +cl-mcp-server-name+ srv)))))))))

(define-test io-migrate-removes-cl-mcp
  (with-release (launcher)
    (with-temp-dir (dir "dsmr-install-io-migrate")
      (let ((path (merge-pathnames ".claude.json" dir)))
        (%write-json path
                     (ht "mcpServers"
                         (ht +cl-mcp-server-name+ (canonical-server-entry "cl-mcp"))))
        (let ((result (install-into-claude :path path
                                           :on-existing-cl-mcp :remove)))
          (is eq :updated-removed-cl-mcp (getf result :action-taken))
          (let* ((parsed (jzon:parse (uiop:read-file-string path)))
                 (srv (gethash "mcpServers" parsed)))
            (false (nth-value 1 (gethash +cl-mcp-server-name+ srv))
                   "cl-mcp removed on migrate")
            (true (nth-value 1 (gethash +dsmr-server-name+ srv))
                  "dsmr-mcp installed")))))))
