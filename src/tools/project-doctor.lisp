;;;; src/tools/project-doctor.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; MCP verb: bring an existing repository up to the declared project shape.
;;;;
;;;; What a repository is to the operator (ours, contributing or forked) is
;;;; declared once and recorded in the repository's untracked .envrc. With
;;;; nothing recorded this verb asks: the result names the question, the three
;;;; answers and what each means, and the origin and upstream found as facts,
;;;; with nothing written. The caller answers with the disposition argument; a
;;;; writing run records it and every later run reads it from the file.
;;;;
;;;; The ask is an ordinary result and an ordinary follow-up call. It asks for
;;;; no capability of the client beyond reading a field out of a response it
;;;; already received, so a client that cannot present a prompt with a required
;;;; field can still answer it.
;;;;
;;;; A restart established inside this call is gone the moment the call returns,
;;;; and the caller's next call cannot resume one. The three outcomes therefore
;;;; cross the wire as a policy argument in and a report out. Their names
;;;; survive as the vocabulary of that argument and of that report; the
;;;; condition and restart machinery stays inside the image, where it works.
;;;;
;;;; Assessment is the default. A call with no policy writes nothing and returns
;;;; every finding together with the outcomes it admits, because an unattended
;;;; run must not decide on its own what to do to a repository.

(defpackage #:dsmr-mcp/src/tools/project-doctor
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/tools/base
                #:mcp-tool
                #:mcp-tool-class
                #:tool-handle
                #:tool-session)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:make-ht
                #:result
                #:text-content)
  (:import-from #:dsmr-mcp/src/state
                #:session-project-root)
  (:import-from #:dsmr-mcp/src/project-root
                #:ensure-write-path)
  (:import-from #:dsmr-mcp/src/project-doctor
                #:normalise-repository
                #:report-root
                #:report-disposition
                #:report-disposition-source
                #:report-disposition-recorded
                #:report-warnings
                #:report-profile
                #:report-changed
                #:report-already-correct
                #:report-recorded-debt
                #:report-accepted
                #:report-unresolved
                #:report-exclude
                #:report-debt-baseline
                #:report-remote-added
                #:report-dry-run
                #:head-moved-error
                #:write-outside-root-error
                #:write-outside-root-path)
  (:import-from #:dsmr-mcp/src/repo-classify
                #:+dispositions+
                #:+disposition-meanings+
                #:disposition-name
                #:project-disposition-required
                #:disposition-required-directory
                #:disposition-required-origin-url
                #:disposition-required-upstream-url
                #:project-disposition-conflict
                #:project-disposition-unreadable
                #:project-disposition-not-recordable)
  (:import-from #:dsmr-mcp/src/project-deviation
                #:deviation-item
                #:deviation-report-line
                #:available-restarts
                #:foreign-apparatus-tracked
                #:policy-not-applicable-error
                #:policy-not-applicable-deviation)
  (:import-from #:dsmr-mcp/src/project-shape
                #:shape-item-key)
  (:import-from #:dsmr-mcp/src/git
                #:not-a-repository-error
                #:not-a-repository-path
                #:git-command-error
                #:git-command-error-exit-code)
  (:import-from #:dsmr-mcp/src/project-scaffold-core
                #:invalid-argument-error))

(in-package #:dsmr-mcp/src/tools/project-doctor)

;;; ---------------------------------------------------------------------------
;;; The answers the disposition question accepts
;;; ---------------------------------------------------------------------------

(defvar +accepted-dispositions+
  (vector "ours" "contributing" "forked")
  "The answers the disposition question offers, in the order it offers them.

A simple-vector so it encodes as a JSON array.

⚠ This vector and the disposition property's enum in the schema below must
name the same three answers. The schema is a class-allocated literal and cannot
read a variable; the tool test asserts the two agree.

DEFVAR rather than DEFCONSTANT: DEFCONSTANT on a vector re-evaluates to a
fresh, non-EQL object on reload and breaks a warm image.")

;;; ---------------------------------------------------------------------------
;;; The verb
;;; ---------------------------------------------------------------------------

(defclass project-doctor-tool (mcp-tool)
  ((dsmr-mcp/src/tools/base::name
    :allocation :class
    :initform "project-doctor")
   (dsmr-mcp/src/tools/base::description
    :allocation :class
    :initform "Normalize an existing repository into the project shape without \
destroying what is there. Assesses by default and writes nothing; repairs, \
records as debt, or accepts a deviation as deliberate only when a policy says \
so, and reports every change separately from what was already correct. The \
repository's disposition (ours, contributing or forked) is read from its \
untracked .envrc. With none recorded the call returns the question, the three \
answers and what each means, and writes nothing; a second call carries the \
answer in disposition, and a writing run records it. For contributing the lint \
gate reports the findings in the forms a commit changes and never refuses the \
commit; for ours and forked it refuses a commit whose changed forms carry a \
warning or an error.")
   (dsmr-mcp/src/tools/base::input-schema
    :allocation :class
    :initform '(:object
                :properties
                ((path
                  :type :string
                  :description "Repository directory, relative to the session \
root. Defaults to the session root itself. Must resolve inside the session \
root.")
                 (disposition
                  :type :string
                  :enum ("ours" "contributing" "forked")
                  :description "What the repository is, when its .envrc records \
nothing: ours, code originating with the operator; contributing, a third-party \
project the operator only contributes to; forked, forked to shorten the \
acceptance chain or because upstream is unmaintained. A writing run records it \
in .envrc. Refused when it differs from the recorded value.")
                 (upstream_url
                  :type :string
                  :description "The upstream this repository was forked from. \
Recorded as the upstream remote when none is recorded; it decides nothing about \
the disposition.")
                 (policy
                  :type :string
                  :enum ("repair" "record-as-debt" "accept-as-deliberate")
                  :description "What to do about each deviation found. Omitted \
means assess only, which writes nothing and returns each finding with the \
outcomes it admits.")
                 (dry_run
                  :type :boolean
                  :description "Report what would change and write nothing. The \
report has the same shape either way."))
                :required ())))
  (:metaclass mcp-tool-class)
  (:documentation "MCP tool: bring a repository up to the declared project shape.
Mode-independent (dispatcher-side). No-root guard at entry: call
fs-set-project-root first, and every path is resolved through the write jail.

Assessment is the default and it writes nothing. A repository with no recorded
disposition is returned as a question with the answers it accepts."))

(c2mop:ensure-finalized (find-class 'project-doctor-tool))

;;; ---------------------------------------------------------------------------
;;; Turning a report into wire values
;;; ---------------------------------------------------------------------------

(defun %name-string (value)
  "Return VALUE's symbol name in lower case, or NIL when VALUE is NIL.

Every keyword the report carries reaches the wire through here, so a caller
never receives a printed Lisp form in place of a name."
  (and value (string-downcase (symbol-name value))))

(defun %path-string (value)
  "Return VALUE as a string suitable for the wire, or NIL when VALUE is NIL."
  (typecase value
    (null      nil)
    (pathname  (namestring value))
    (string    value)
    (t         (princ-to-string value))))

(defun %entry-item (entry)
  "Return the shape item key ENTRY is about, or NIL when it names none.

An entry carries the key directly when the repair loop had it; an entry that
carries only the deviation has it one level down. The local exclude is not a
catalogue item at all and legitimately has none."
  (or (getf entry :item)
      (let* ((deviation (getf entry :deviation))
             (item (and deviation (deviation-item deviation))))
        (and item (shape-item-key item)))))

(defun %entry-hash (entry)
  "Return the wire hash for one report ENTRY.

Fields are present on their own terms: a change carries the action taken, a
finding carries its reason and the outcomes it admits, a recorded debt carries
the baseline it was frozen into. One shape with the inapplicable fields left out
means a caller does not have to know which list an entry came from to read it."
  (let ((deviation (getf entry :deviation))
        (path      (getf entry :path))
        (action    (getf entry :action-taken))
        (reason    (getf entry :reason))
        (restarts  (getf entry :restarts))
        (baseline  (getf entry :baseline))
        (hash      (make-ht "item" (or (%name-string (%entry-item entry)) 'null))))
    (when deviation
      (setf (gethash "deviation" hash) (deviation-report-line deviation)))
    (when path
      (setf (gethash "path" hash) (%path-string path)))
    (when action
      (setf (gethash "action_taken" hash) (%name-string action)))
    (when reason
      (setf (gethash "reason" hash) reason))
    (when restarts
      (setf (gethash "available_outcomes" hash)
            (map 'simple-vector #'%name-string restarts)))
    (when baseline
      (setf (gethash "baseline" hash) (%baseline-hash baseline)))
    hash))

(defun %entries (list)
  "Return LIST as a simple-vector of entry hashes, #() when it is empty."
  (map 'simple-vector #'%entry-hash list))

(defun %baseline-hash (baseline)
  "Return the wire hash for the frozen debt baseline BASELINE, or NIL.

The site count is the reason this is a hash rather than a path. A baseline
written after a scan and one that could not be enumerated because no scanner was
reachable are different outcomes, and a caller must be able to tell them apart
without reading the repository."
  (and baseline
       (make-ht "path"         (or (%path-string (getf baseline :path)) 'null)
                "site_count"   (or (getf baseline :site-count) 'null)
                "action_taken" (or (%name-string (getf baseline :action-taken))
                                   'null))))

(defun %exclude-hash (exclude)
  "Return the wire hash for the local exclude repair EXCLUDE, or NIL."
  (and exclude
       (make-ht "path"            (or (%path-string (getf exclude :path)) 'null)
                "backup_path"     (or (%path-string (getf exclude :backup-path))
                                      'null)
                "action_taken"    (or (%name-string (getf exclude :action-taken))
                                      'null)
                "added_patterns"  (coerce (getf exclude :added-patterns)
                                          'simple-vector))))

(defun %remote-hash (remote)
  "Return the wire hash for the upstream remote REMOTE, or NIL."
  (and remote
       (make-ht "remote"       (or (getf remote :remote) 'null)
                "url"          (or (getf remote :url) 'null)
                "action_taken" (or (%name-string (getf remote :action-taken))
                                   'null))))

(defun %source-string (source)
  "Return the wire form of a disposition SOURCE: \"argument\" or the file's path."
  (if (eq source :argument) "argument" (%path-string source)))

(defun %recorded-hash (recorded)
  "Return the wire hash for the disposition record plist RECORDED, or NIL."
  (and recorded
       (make-ht "path"         (or (%path-string (getf recorded :path)) 'null)
                "disposition"  (or (%name-string (getf recorded :disposition))
                                   'null)
                "action_taken" (or (%name-string (getf recorded :action-taken))
                                   'null))))

(defun %summary-text (report policy)
  "Return the prose summary of REPORT under POLICY."
  (format nil "project-doctor over ~A: disposition ~A (~A), assessed as ~A.~%~
~D changed, ~D already correct, ~D recorded as debt, ~D accepted, ~D unresolved.~
~{~%Warning: ~A~}~@[~%~A~]~@[~%~A~]"
          (%path-string (report-root report))
          (%name-string (report-disposition report))
          (%source-string (report-disposition-source report))
          (%name-string (report-profile report))
          (length (report-changed report))
          (length (report-already-correct report))
          (length (report-recorded-debt report))
          (length (report-accepted report))
          (length (report-unresolved report))
          (report-warnings report)
          (when (report-dry-run report)
            "This was a dry run. Nothing was written.")
          (unless policy
            "No policy was supplied, so nothing was written and every finding \
carries the outcomes it admits. Call again with policy set to act on them.")))

(defun %success-result (id report policy)
  "Return the JSON-RPC result for a completed run described by REPORT."
  (result id
          (make-ht "disposition"     (%name-string (report-disposition report))
                   "disposition_source" (%source-string
                                         (report-disposition-source report))
                   "disposition_recorded" (or (%recorded-hash
                                               (report-disposition-recorded report))
                                              'null)
                   "warnings"        (coerce (report-warnings report)
                                             'simple-vector)
                   "profile"         (%name-string (report-profile report))
                   "path"            (%path-string (report-root report))
                   "changed"         (%entries (report-changed report))
                   "already_correct" (map 'simple-vector #'%name-string
                                          (report-already-correct report))
                   "recorded_debt"   (%entries (report-recorded-debt report))
                   "accepted"        (%entries (report-accepted report))
                   "unresolved"      (%entries (report-unresolved report))
                   "exclude"         (or (%exclude-hash (report-exclude report))
                                         'null)
                   "debt_baseline"   (or (%baseline-hash
                                          (report-debt-baseline report))
                                         'null)
                   "remote_added"    (or (%remote-hash
                                          (report-remote-added report))
                                         'null)
                   "dry_run"         (and (report-dry-run report) t)
                   "content"         (text-content (%summary-text report policy)))))

;;; ---------------------------------------------------------------------------
;;; Reading the arguments
;;; ---------------------------------------------------------------------------

(defun %disposition-keyword (value)
  "Return the disposition keyword VALUE names.

NIL means the caller did not answer and returns NIL. :INVALID is a supplied
value that is not one of the answers offered. The comparison is explicit, so no
caller string becomes a keyword the enum never offered."
  (cond ((null value)                    nil)
        ((not (stringp value))           :invalid)
        ((string= value "ours")          :ours)
        ((string= value "contributing")  :contributing)
        ((string= value "forked")        :forked)
        (t                               :invalid)))

(defun %policy-keyword (value)
  "Return the policy keyword VALUE names.

NIL means assess only, which is the default call. :INVALID means a value was
supplied that is not one of the three outcomes. Explicit for the same reason
%DISPOSITION-KEYWORD is."
  (cond ((null value)                             nil)
        ((not (stringp value))                    :invalid)
        ((string= value "repair")                 :repair)
        ((string= value "record-as-debt")         :record-as-debt)
        ((string= value "accept-as-deliberate")   :accept-as-deliberate)
        (t                                        :invalid)))

(defun %resolve-target (path root)
  "Return the repository directory PATH names under ROOT, or NIL when it escapes.

An absent or blank PATH is the session root itself: that is the default call,
and the one an agent reaches for first. Any other value goes through the write
jail's symlink-safe containment check before anything is done with it, so a
parent symlink cannot carry a run out of the tree it was asked about."
  (if (or (null path)
          (zerop (length (string-trim '(#\Space #\Tab) path))))
      (uiop:ensure-directory-pathname root)
      (ensure-write-path (uiop:ensure-directory-pathname path) root)))

(defun %invalid-argument (id message)
  "Return the JSON-RPC result rejecting an argument, carrying MESSAGE."
  (result id (make-ht "isError" t
                      "error_type" "invalid-argument"
                      "content" (text-content message))))

(defun %refusal (id error-type condition)
  "Return the JSON-RPC result for a disposition refusal of ERROR-TYPE, carrying
CONDITION's report and the statement that nothing was written."
  (result id (make-ht "isError" t
                      "error_type" error-type
                      "content"
                      (text-content
                       (format nil "project-doctor refused and has written nothing.~%~A"
                               (princ-to-string condition))))))

(defun %meanings-hash ()
  "Return a hash of each accepted disposition's name to what declaring it means."
  (let ((hash (make-hash-table :test 'equal)))
    (dolist (entry +disposition-meanings+ hash)
      (setf (gethash (disposition-name (car entry)) hash) (cdr entry)))))

;;; ---------------------------------------------------------------------------
;;; The call
;;; ---------------------------------------------------------------------------

(defmethod tool-handle ((tool project-doctor-tool) id args)
  (let* ((session (tool-session tool))
         (root    (session-project-root session))
         (args    (or args (make-hash-table :test 'equal))))
    ;; No-root guard: every path this verb touches is resolved under the
    ;; session root, and there is nothing to resolve against without one.
    (unless root
      (return-from tool-handle
        (result id (make-ht "isError" t
                            "error_type" "project-root-not-set"
                            "content"
                            (text-content "project-doctor: no project root set. \
Call fs-set-project-root first.")))))
    (let ((path-arg           (gethash "path" args))
          (disposition-arg    (gethash "disposition" args))
          (upstream-arg       (gethash "upstream_url" args))
          (policy-arg         (gethash "policy" args))
          (dry-run            (and (gethash "dry_run" args) t)))
      (when (and path-arg (not (stringp path-arg)))
        (return-from tool-handle
          (%invalid-argument id "project-doctor: path must be a string.")))
      (when (and upstream-arg (not (stringp upstream-arg)))
        (return-from tool-handle
          (%invalid-argument id "project-doctor: upstream_url must be a string.")))
      (let ((disposition (%disposition-keyword disposition-arg))
            (policy      (%policy-keyword policy-arg)))
        (when (eq disposition :invalid)
          (return-from tool-handle
            (%invalid-argument
             id
             (format nil "project-doctor: disposition must be one of ~{~A~^, ~}."
                     (coerce +accepted-dispositions+ 'list)))))
        (when (eq policy :invalid)
          (return-from tool-handle
            (%invalid-argument
             id
             "project-doctor: policy must be one of repair, record-as-debt, \
accept-as-deliberate.")))
        (let ((target (%resolve-target path-arg root)))
          (unless target
            (return-from tool-handle
              (result id (make-ht "isError" t
                                  "error_type" "sandbox-violation"
                                  "content"
                                  (text-content
                                   (format nil "project-doctor: ~A resolves \
outside the session root and was not read."
                                           path-arg))))))
          (handler-case
              (%success-result id
                               (normalise-repository
                                target
                                :policy policy
                                :disposition disposition
                                :upstream-url upstream-arg
                                :dry-run dry-run
                                :session-root root)
                               policy)

            ;; The question. Not a failure: the answer is one field on the next
            ;; call. Nothing has been written at this point.
            (project-disposition-required (condition)
              (result id
                      (make-ht "isError" t
                               "error_type" "project-disposition-required"
                               "requires_disposition" t
                               "directory"
                               (or (%path-string
                                    (disposition-required-directory condition))
                                   'null)
                               "origin_url"
                               (or (disposition-required-origin-url condition)
                                   'null)
                               "upstream_url"
                               (or (disposition-required-upstream-url condition)
                                   'null)
                               "accepted_dispositions" +accepted-dispositions+
                               "disposition_meanings" (%meanings-hash)
                               "content"
                               (text-content
                                (format nil "project-doctor is asking, not \
failing, and it has written nothing.~%~A~%~{~A~%~}Call project-doctor again with \
disposition set to one of those. The remotes are reported as facts and decide \
nothing."
                                        (princ-to-string condition)
                                        (mapcar (lambda (entry)
                                                  (format nil "  ~A: ~A"
                                                          (disposition-name
                                                           (car entry))
                                                          (cdr entry)))
                                                +disposition-meanings+))))))

            (project-disposition-conflict (condition)
              (%refusal id "project-disposition-conflict" condition))
            (project-disposition-unreadable (condition)
              (%refusal id "project-disposition-unreadable" condition))
            (project-disposition-not-recordable (condition)
              (%refusal id "project-disposition-not-recordable" condition))

            (not-a-repository-error (condition)
              (result id (make-ht "isError" t
                                  "error_type" "not-a-git-repository"
                                  "path" (or (%path-string
                                              (not-a-repository-path condition))
                                             'null)
                                  "content"
                                  (text-content (princ-to-string condition)))))

            (git-command-error (condition)
              (result id (make-ht "isError" t
                                  "error_type" "git-command-failed"
                                  "exit_code"
                                  (git-command-error-exit-code condition)
                                  "content"
                                  (text-content (princ-to-string condition)))))

            (policy-not-applicable-error (condition)
              (let* ((deviation (policy-not-applicable-deviation condition))
                     (outcomes  (if deviation (available-restarts deviation) '())))
                (result id
                        (make-ht "isError" t
                                 "error_type" "policy-not-applicable"
                                 "deviation" (if deviation
                                                 (deviation-report-line deviation)
                                                 'null)
                                 "available_outcomes"
                                 (map 'simple-vector #'%name-string outcomes)
                                 "content"
                                 (text-content (princ-to-string condition))))))

            ;; Our apparatus reached the repository's index. Reported with its
            ;; own type rather than as a generic failure, because it is the one
            ;; outcome whose consequence lands in somebody else's tree.
            (foreign-apparatus-tracked (condition)
              (result id (make-ht "isError" t
                                  "error_type" "apparatus-tracked"
                                  "content"
                                  (text-content (princ-to-string condition)))))

            ;; A run that makes no commits found the head somewhere else
            ;; afterwards. Surfaced rather than swallowed: it means something
            ;; ran that should not have.
            (head-moved-error (condition)
              (result id (make-ht "isError" t
                                  "error_type" "repository-head-moved"
                                  "content"
                                  (text-content (princ-to-string condition)))))

            (write-outside-root-error (condition)
              (result id (make-ht "isError" t
                                  "error_type" "sandbox-violation"
                                  "path" (or (%path-string
                                              (write-outside-root-path condition))
                                             'null)
                                  "content"
                                  (text-content (princ-to-string condition)))))

            (invalid-argument-error (condition)
              (%invalid-argument id (princ-to-string condition)))))))))
