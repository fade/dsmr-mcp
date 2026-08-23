;;;; src/project-scaffold.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Effectful I/O layer for project-scaffold (VERB-22).
;;;; Thin wrapper on top of the pure logic in project-scaffold-core.
;;;; Writes the scaffold tree atomically: all files go into a random-suffixed
;;;; temp directory, then a single rename-file commits the whole tree.
;;;; unwind-protect removes the temp dir on any failure so a partial write
;;;; never leaves debris under the session root (D-16).
;;;;
;;;; Route writes through ensure-write-path + write-file-string-atomically
;;;; (the Phase-6 jail primitives), NOT the fs-write-file tool — the tool
;;;; refuses existing .lisp/.asd files and fires LSP didChange, both
;;;; inappropriate for fresh-tree generation.

(defpackage #:dsmr-mcp/src/project-scaffold
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/project-scaffold-core
                #:validate-project-name
                #:validate-destination
                #:validate-text-field
                #:plan-scaffold
                #:invalid-argument-error)
  (:import-from #:dsmr-mcp/src/project-root
                #:ensure-write-path)
  (:import-from #:dsmr-mcp/src/fs
                #:write-file-string-atomically)
  (:import-from #:dsmr-mcp/src/envrc-init
                #:envrc-content-with-derived-port)
  (:export #:write-scaffold))

(in-package #:dsmr-mcp/src/project-scaffold)

(defun %uuid-suffix ()
  "Return a short pseudo-random hex suffix for temp directory naming."
  (format nil "~8,'0X" (random #xFFFFFFFF)))

(defun %absolute-scaffold-paths (session-root destination name)
  "Return (values TARGET-DIR TEMP-DIR) as absolute directory pathnames.
Both paths are inside SESSION-ROOT. TEMP-DIR has a random suffix to avoid
collisions between concurrent scaffold calls."
  (let* ((dest-dir   (uiop:ensure-directory-pathname
                       (merge-pathnames
                        (uiop:ensure-directory-pathname destination)
                        session-root)))
         (target-dir (uiop:ensure-directory-pathname
                       (merge-pathnames
                        (uiop:ensure-directory-pathname name)
                        dest-dir)))
         (temp-dir   (uiop:ensure-directory-pathname
                       (merge-pathnames
                        (uiop:ensure-directory-pathname
                         (format nil ".tmp-~A" (%uuid-suffix)))
                        dest-dir))))
    (values target-dir temp-dir)))

(defun %check-within-root (dir session-root context)
  "Signal INVALID-ARGUMENT-ERROR if DIR is not under SESSION-ROOT.
Uses ensure-write-path for the symlink-safe containment check.
CONTEXT is a string describing which directory is being checked (for
the error message)."
  (unless (ensure-write-path (namestring dir) session-root)
    (error 'invalid-argument-error
           :field "destination"
           :value (namestring dir)
           :reason (format nil "~A resolves outside session root" context))))

(defun %executable-content-p (content)
  "True when CONTENT begins with a #! line, marking the file as a script.

The execute bit is derived from the file's own first two bytes rather than
declared in a table of names kept somewhere else. A script added to the
manifest later cannot then be forgotten, and the mode can never disagree with
the content it describes. Every shebang-bearing file this scaffold emits is one
the generated README and CLAUDE.md tell a person to run directly, so at the
bare process umask those instructions fail on their first step."
  (and (stringp content)
       (>= (length content) 2)
       (string= "#!" content :end2 2)))

(defun %write-plan-to-temp (temp-dir plan session-root)
  "Write all PLAN entries into TEMP-DIR, routing each file through the
Phase-6 write-jail (ensure-write-path) then write-file-string-atomically.
TEMP-DIR must already be inside SESSION-ROOT; this is asserted per-file."
  (ensure-directories-exist temp-dir)
  (let* ((temp-ns (namestring temp-dir))
         ;; ensure trailing slash
         (temp-prefix (if (char= (char temp-ns (1- (length temp-ns))) #\/)
                          temp-ns
                          (concatenate 'string temp-ns "/"))))
    (dolist (entry plan)
      (let* ((rel-in-temp (concatenate 'string temp-prefix (car entry)))
             (pn (ensure-write-path rel-in-temp session-root)))
        (unless pn
          (error 'invalid-argument-error
                 :field "destination"
                 :value rel-in-temp
                 :reason "file path resolves outside session root"))
        (write-file-string-atomically pn (cdr entry))
        (when (%executable-content-p (cdr entry))
          ;; chmod through run-program rather than sb-posix, matching how the
          ;; installer sets the execute bit on the binary it copies. A chmod
          ;; that cannot run must not discard an otherwise complete tree.
          (uiop:run-program (list "chmod" "+x" (namestring pn))
                            :ignore-error-status t))))))

(defun write-scaffold (&key name description author license copyright year
                              destination overwrite session-root)
  "Generate the scaffold project atomically under SESSION-ROOT.
Returns a plist with:
  :target-dir    (absolute directory pathname)
  :relative-path (namestring relative to session-root)
  :files         (list of relative path strings, in manifest order)

On any failure, signals INVALID-ARGUMENT-ERROR or propagates the
underlying error after cleaning up the temp directory (no debris)."
  (unless session-root
    (error 'invalid-argument-error
           :field "session-root" :value nil :reason "session root is required"))
  (validate-project-name name)
  (validate-destination (or destination "scaffolds"))
  (validate-text-field "description" (or description ""))
  (validate-text-field "author" (or author ""))
  (validate-text-field "copyright" (or copyright author ""))
  (let ((effective-destination (or destination "scaffolds")))
    (multiple-value-bind (target-dir temp-dir)
        (%absolute-scaffold-paths session-root effective-destination name)
      ;; Assert both target and temp resolve under the session root
      (%check-within-root target-dir session-root "target directory")
      (%check-within-root temp-dir session-root "temp directory")
      (when (and (uiop:directory-exists-p target-dir) (not overwrite))
        (error 'invalid-argument-error
               :field "name" :value name
               :reason (format nil "target directory already exists: ~A"
                               (namestring target-dir))))
      (let* ((manifest (plan-scaffold :name name
                                      :description (or description "")
                                      :author (or author "")
                                      :license (or license "AGPL-3.0-or-later")
                                      :copyright (or copyright author "Unknown")
                                      ;; year default is owned by plan-scaffold
                                      ;; (live current year); pass through as-is
                                      :year year
                                      :destination effective-destination))
             ;; Substitute the per-project derived Slynk port into the
             ;; generated .envrc and scripts/dev-boot.sh, so the new project
             ;; starts with its own port from day one rather than the shared
             ;; literal 4005.
             (manifest (mapcar
                        (lambda (entry)
                          (if (member (car entry) '(".envrc" "scripts/dev-boot.sh")
                                      :test #'string=)
                              (cons (car entry)
                                    (envrc-content-with-derived-port
                                     (cdr entry) target-dir))
                              entry))
                        manifest))
             (committed nil))
        (unwind-protect
             (progn
               (%write-plan-to-temp temp-dir manifest session-root)
               ;; Delete existing target AFTER temp is ready, preserving
               ;; atomicity: if the write failed, the original survives.
               (when (and overwrite (uiop:directory-exists-p target-dir))
                 (uiop:delete-directory-tree target-dir :validate t))
               (rename-file temp-dir target-dir)
               (setf committed t)
               ;; Auto-register the new system with ASDF
               (let ((abs-asd (namestring
                               (merge-pathnames (format nil "~A.asd" name) target-dir))))
                 (when (probe-file abs-asd)
                   (ignore-errors (asdf:load-asd abs-asd))))
               (list :target-dir target-dir
                     :relative-path (enough-namestring target-dir session-root)
                     :files (mapcar #'car manifest)))
          (unless committed
            (when (uiop:directory-exists-p temp-dir)
              (ignore-errors
               (uiop:delete-directory-tree temp-dir :validate t)))))))))
