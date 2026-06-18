;;;; tests/install/config-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Parachute tests for the installer config core and the Claude IO layer.
;;;; All transforms run on in-memory jzon objects and temp files — the real
;;;; ~/.claude.json is never read or written.

(defpackage #:dsmr-mcp/tests/install/config-test
  (:use #:cl #:parachute)
  (:local-nicknames (#:jzon #:com.inuoe.jzon))
  (:import-from #:dsmr-mcp/src/install/config
                #:canonical-server-entry
                #:ensure-server
                #:has-cl-mcp-p
                #:+dsmr-server-name+
                #:+cl-mcp-server-name+)
  (:import-from #:dsmr-mcp/src/install/claude
                #:install-into-claude
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

;;; canonical-server-entry ----------------------------------------------------

(defun %find-arg (args predicate)
  "Return the first member of ARGS satisfying PREDICATE, or NIL."
  (find-if predicate args))

(define-test canonical-entry-has-stdio-shape
  (let ((entry (canonical-server-entry)))
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
  (let* ((entry (canonical-server-entry))
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
  (let* ((entry (canonical-server-entry))
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
  (let ((entry (canonical-server-entry)))
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

(define-test wrapper-launcher-path-names-and-finds-shipped-script
  "The resolver names the wrapper shipped in the repo, and it exists in this
checkout — so a real install emits a launcher that is actually present and
executable."
  (let ((p (wrapper-launcher-path)))
    (true (search "scripts/dsmr-mcp-launch.sh" p) "names the shipped wrapper")
    (true (probe-file p) "wrapper exists in the checkout")
    (is string= p (launcher-if-present)
        "launcher-if-present returns the path when the script exists")))

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
  (let* ((dir (uiop:ensure-directory-pathname
               (format nil "/tmp/dsmr-install-io-create-~A" (get-universal-time))))
         (path (merge-pathnames ".claude.json" dir)))
    (unwind-protect
         (progn
           (ensure-directories-exist dir)
           (let ((result (install-into-claude :path path)))
             (is eq :created (getf result :action-taken))
             (false (getf result :backup-path) "no backup for a fresh create")
             (true (probe-file path) "config file written")
             ;; Result re-parses and carries the dsmr-mcp entry.
             (let* ((parsed (jzon:parse (uiop:read-file-string path)))
                    (srv (gethash "mcpServers" parsed)))
               (true (nth-value 1 (gethash +dsmr-server-name+ srv))))))
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))

(define-test io-backs-up-and-reparses-on-update
  (let* ((dir (uiop:ensure-directory-pathname
               (format nil "/tmp/dsmr-install-io-update-~A" (get-universal-time))))
         (path (merge-pathnames ".claude.json" dir)))
    (unwind-protect
         (progn
           (ensure-directories-exist dir)
           ;; Seed an existing config that already contains a cl-mcp entry.
           (with-open-file (out path :direction :output :if-exists :supersede
                                     :if-does-not-exist :create)
             (write-string
              (jzon:stringify
               (ht "theme" "dark"
                   "mcpServers"
                   (ht +cl-mcp-server-name+ (canonical-server-entry "cl-mcp")))
               :pretty t)
              out))
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
               (true (nth-value 1 (gethash +cl-mcp-server-name+ srv))))))
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))

(define-test io-migrate-removes-cl-mcp
  (let* ((dir (uiop:ensure-directory-pathname
               (format nil "/tmp/dsmr-install-io-migrate-~A" (get-universal-time))))
         (path (merge-pathnames ".claude.json" dir)))
    (unwind-protect
         (progn
           (ensure-directories-exist dir)
           (with-open-file (out path :direction :output :if-exists :supersede
                                     :if-does-not-exist :create)
             (write-string
              (jzon:stringify
               (ht "mcpServers"
                   (ht +cl-mcp-server-name+ (canonical-server-entry "cl-mcp")))
               :pretty t)
              out))
           (let ((result (install-into-claude :path path
                                              :on-existing-cl-mcp :remove)))
             (is eq :updated-removed-cl-mcp (getf result :action-taken))
             (let* ((parsed (jzon:parse (uiop:read-file-string path)))
                    (srv (gethash "mcpServers" parsed)))
               (false (nth-value 1 (gethash +cl-mcp-server-name+ srv))
                      "cl-mcp removed on migrate")
               (true (nth-value 1 (gethash +dsmr-server-name+ srv))
                     "dsmr-mcp installed"))))
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))
