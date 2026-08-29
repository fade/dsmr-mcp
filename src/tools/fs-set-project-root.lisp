;;;; src/tools/fs-set-project-root.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; MCP tool: set the per-session project root.
;;;;
;;;; D-03: root is session-local state only — no process chdir, no mutation
;;;;        of *default-pathname-defaults*.
;;;; D-04: root is re-rootable; one project is writable at a time.
;;;; D-05: re-root outside the whitelist returns a typed
;;;;        reroot-permission-required error that is NOT agent-self-serviceable.
;;;;        human_approved is read ONLY from the inbound args hash via
;;;;        (gethash "human_approved" args); the dispatcher never defaults it,
;;;;        never derives it, never sets a fallback binding for it.
;;;; D-06: does NOT call uiop:chdir and does NOT assign *default-pathname-defaults*.
;;;; D-13: broad roots (/ /tmp/ /home/ etc.) are rejected before storing.
;;;;
;;;; Re-root whitelist source: env var DSMR_RELATED_PROJECTS (colon-separated
;;;; absolute paths). When empty or unset, every re-root to a new root
;;;; requires human_approved.

(defpackage #:dsmr-mcp/src/tools/fs-set-project-root
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/tools/base
                #:mcp-tool
                #:mcp-tool-class
                #:tool-handle
                #:tool-session)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:make-ht
                #:result
                #:text-content
                #:validate-args)
  (:import-from #:dsmr-mcp/src/state
                #:session-project-root
                #:session-project-root-just-set-p)
  (:import-from #:dsmr-mcp/src/project-root
                #:broad-root-p
                #:broad-root-error)
  (:import-from #:dsmr-mcp/src/log
                #:log-event))

(in-package #:dsmr-mcp/src/tools/fs-set-project-root)

;;; Whitelist helper --------------------------------------------------------

(defun %as-directory-namestring (path-string)
  "Return PATH-STRING spelled as a directory namestring, ending in a slash.
DSMR_RELATED_PROJECTS is written in shell convention, which leaves the trailing
slash off, while the re-root target reaches the gate as a Common Lisp directory
namestring, which always carries one. Bringing both sides to the same spelling
is what lets them be compared at all, and it is also what keeps a sibling whose
name merely begins with a listed directory's name from matching."
  (namestring (uiop:ensure-directory-pathname path-string)))

(defun %related-projects-whitelist ()
  "Return the directories named by DSMR_RELATED_PROJECTS as directory
namestrings. Colon-separated. Empty string or unset returns NIL (empty
whitelist)."
  (let ((env (uiop:getenv "DSMR_RELATED_PROJECTS")))
    (when (and env (plusp (length env)))
      (mapcar #'%as-directory-namestring
              (remove "" (uiop:split-string env :separator ":") :test #'string=)))))

(defun %covered-by-p (target-namestring entry-namestring)
  "Return T when TARGET-NAMESTRING names ENTRY-NAMESTRING itself or a directory
beneath it at any depth. Both arguments must already end in a slash."
  (let ((n (length entry-namestring)))
    (and (>= (length target-namestring) n)
         (string= entry-namestring target-namestring :end2 n))))

(defun %whitelisted-p (target-namestring current-root-namestring)
  "Return T when TARGET-NAMESTRING is the current root, or is a whitelisted
directory, or lies beneath one. Naming a directory authorises everything under
it because worktrees are created and destroyed continuously and the whitelist
only takes effect when the session is replaced: an exact match would mean a new
entry and a restart for every worktree."
  (or (string= target-namestring current-root-namestring)
      (let ((target (%as-directory-namestring target-namestring)))
        (and (some (lambda (entry) (%covered-by-p target entry))
                   (%related-projects-whitelist))
             t))))

;;; Tool class --------------------------------------------------------------

(defclass fs-set-project-root-tool (mcp-tool)
  ;; CRITICAL: use :initform on class-allocated slots, NOT :default-initargs.
  ;; c2mop:class-prototype does not apply :default-initargs; the metaclass
  ;; finalize-inheritance :after reads the prototype for the name slot.
  ;; See src/tools/base.lisp for the documented rationale.
  ((dsmr-mcp/src/tools/base::name
    :allocation :class
    :initform "fs-set-project-root")
   (dsmr-mcp/src/tools/base::description
    :allocation :class
    :initform "Set the session project root directory. All subsequent fs-* verbs \
resolve paths relative to this root. Re-rooting outside the configured whitelist \
(DSMR_RELATED_PROJECTS) requires human_approved: true.")
   (dsmr-mcp/src/tools/base::input-schema
    :allocation :class
    :initform '(:object
                :properties
                ((path
                  :type :string
                  :description "Absolute path to the project root directory.")
                 (human_approved
                  :type :boolean
                  :description "Set to true (by a human, not an agent) to authorize \
re-rooting to a path outside the configured whitelist. An autonomous agent cannot \
self-approve this bypass (D-05)."))
                :required ("path"))))
  (:metaclass mcp-tool-class)
  (:documentation "MCP tool: set the per-session project root.
Mode-independent (dispatcher-side). Does not route through attached image
or hermetic worker. See module docstring for D-03/D-04/D-05/D-06 constraints."))

;; Fire metaclass :after immediately so "fs-set-project-root" appears in
;; *tool-classes* at load time, not at first instantiation.
(c2mop:ensure-finalized (find-class 'fs-set-project-root-tool))

;;; tool-handle -------------------------------------------------------------

(defmethod tool-handle ((tool fs-set-project-root-tool) id args)
  (let* ((session      (tool-session tool))
         (path-str     (gethash "path" args))
         ;; D-05 CRITICAL: human_approved is read ONLY from the inbound args
         ;; hash. The dispatcher NEVER defaults, derives, or sets a fallback
         ;; binding for it. An autonomous agent cannot self-grant the bypass
         ;; because a prior call without human_approved will have returned a
         ;; typed reroot-permission-required error.
         (human-approved (gethash "human_approved" args))
         (prev-root    (session-project-root session)))
    ;; Validate required arg
    (unless (and path-str (stringp path-str) (plusp (length (string-trim '(#\Space #\Tab) path-str))))
      (return-from tool-handle
        (result id (make-ht "isError" t
                            "error_type" "invalid-argument"
                            "content" (text-content "fs-set-project-root: path must be a non-empty string.")))))
    (let* ((requested    (uiop:ensure-directory-pathname path-str))
           (abs-requested (if (uiop:absolute-pathname-p requested)
                              requested
                              (uiop:merge-pathnames* requested (uiop:getcwd))))
           (new-root     (or (handler-case (truename abs-requested) (file-error () nil))
                             abs-requested))
           (new-ns       (namestring new-root))
           (prev-ns      (if prev-root (namestring prev-root) "(not set)")))
      ;; Reject broad roots (D-13)
      (when (broad-root-p new-root)
        (return-from tool-handle
          (result id (make-ht "isError" t
                              "error_type" "broad-root-rejected"
                              "content" (text-content
                                         (format nil "fs-set-project-root: ~A is too broad \
to be used as a project root. Choose a specific project directory." new-ns))
                              "path" new-ns))))
      ;; Verify the directory exists
      (unless (uiop:directory-exists-p new-root)
        (return-from tool-handle
          (result id (make-ht "isError" t
                              "error_type" "directory-not-found"
                              "content" (text-content
                                         (format nil "fs-set-project-root: directory ~A does not exist."
                                                 new-ns))
                              "path" new-ns))))
      ;; D-05 permission gate: non-whitelisted re-root without human_approved
      (unless (%whitelisted-p new-ns prev-ns)
        (unless human-approved
          (return-from tool-handle
            (result id (make-ht "isError" t
                                "error_type" "reroot-permission-required"
                                "content" (text-content
                                           (format nil "Re-rooting to ~A requires human approval. ~
Call fs-set-project-root with human_approved: true after manual verification." new-ns))
                                "path" new-ns
                                "previous_root" prev-ns
                                "requires_human_approval" t)))))
      ;; D-05: log human_approved override BEFORE mutating the root
      (when (and human-approved (not (%whitelisted-p new-ns prev-ns)))
        (log-event :info "fs.set-project-root.human-approved"
                   "previous_root" prev-ns
                   "new_root" new-ns))
      ;; D-06: set root on session ONLY — no uiop:chdir, no *default-pathname-defaults*
      (setf (session-project-root session) new-root)
      ;; Mark that THIS dispatch newly established the session root so the
      ;; transport's post-dispatch hook can offer the project `.envrc` on the
      ;; same tools/call.  The handler runs mid-dispatch with no access to the
      ;; wire, so it cannot drive the elicitation itself; the stdio loop reads
      ;; and clears this flag after writing the response (see serve-streams).
      ;; Set whenever the root is adopted (including a re-root) -- the
      ;; once-per-session prompted-p guard inside maybe-prompt-and-write-envrc
      ;; still bounds it to a single prompt for the session's lifetime.
      (setf (session-project-root-just-set-p session) t)
      (log-event :info "fs.set-project-root"
                 "previous_root" prev-ns
                 "new_root" new-ns)
      ;; session_root field replaces cl-mcp's "cwd" (D-03: no process chdir;
      ;; we report the session root, not the OS CWD). Field renamed from "cwd"
      ;; to "session_root" per D-01 modernize latitude.
      (result id
              (make-ht "project_root" new-ns
                       "session_root"  new-ns
                       "previous_root" prev-ns
                       "status" (format nil "Project root set to ~A" new-ns)
                       "content" (text-content
                                  (format nil "Project root set to ~A" new-ns)))))))
