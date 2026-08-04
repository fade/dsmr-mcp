;;;; src/tools/project-doctor.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; MCP verb: bring an existing repository up to the declared project shape.
;;;;
;;;; Whether a tree whose origin sits under one of our own accounts is our
;;;; software or somebody else's is not readable from anything on disk, and on
;;;; this host that case outnumbers the decidable one three to one. So this verb
;;;; asks. An ambiguous repository produces a result naming the question, the
;;;; origin that was found and the answers the verb accepts, with nothing
;;;; written and nothing decided. The caller answers by calling again with one
;;;; of those answers, or by supplying the upstream, which answers the same
;;;; question and records the missing remote at the same time.
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
                #:report-classification
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
                #:repo-classification-ambiguous-error
                #:repo-classification-ambiguous-directory
                #:repo-classification-ambiguous-origin-url)
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
;;; The answers the classification question accepts
;;; ---------------------------------------------------------------------------

(defvar +accepted-classifications+
  (vector "ours" "foreign-with-upstream" "foreign-orphan")
  "The answers the classification question offers, in the order it offers them.

A simple-vector so it encodes as a JSON array rather than as null when it is
empty of nothing at all.

⚠ This vector and the classification property's enum in the schema below must
name the same three answers. They are written out twice because the schema is a
class-allocated literal and cannot read a variable, and the tool test asserts
that the answers the verb advertises are exactly the ones the schema accepts, so
a drift between them fails rather than producing a question whose answer is
refused.

Named as a constant and defined with DEFVAR: DEFCONSTANT on a vector
re-evaluates to a fresh, non-EQL object on reload and breaks a warm image.")

;;; ---------------------------------------------------------------------------
;;; The verb
;;; ---------------------------------------------------------------------------

(defclass project-doctor-tool (mcp-tool)
  ((dsmr-mcp/src/tools/base::name
    :allocation :class
    :initform "project-doctor")
   (dsmr-mcp/src/tools/base::description
    :allocation :class
    :initform "Normalise an existing repository into the project shape without \
destroying what is there. Assesses by default and writes nothing; repairs, \
records as debt, or accepts a deviation as deliberate only when a policy says \
so, and reports every change separately from what was already correct. A \
repository that cannot be told apart from one of ours is not guessed at: the \
call returns the question, the origin it found and the answers it accepts, and \
a second call carries the answer.")
   (dsmr-mcp/src/tools/base::input-schema
    :allocation :class
    :initform '(:object
                :properties
                ((path
                  :type :string
                  :description "Repository directory, relative to the session \
root. Defaults to the session root itself. Must resolve inside the session \
root.")
                 (classification
                  :type :string
                  :enum ("ours" "foreign-with-upstream" "foreign-orphan")
                  :description "The answer to the classification question, when \
the repository cannot be told apart from one of ours. Supplied by the operator \
and never inferred: guessing that somebody else's software is ours is how our \
tooling ends up tracked in their tree.")
                 (upstream_url
                  :type :string
                  :description "The upstream this repository was forked from. \
Answers the classification question and records the missing remote at the same \
time. Ignored when an upstream is already recorded.")
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

Assessment is the default and it writes nothing. An ambiguous classification is
returned as a question with the answers it accepts, never resolved by a guess."))

(c2mop:ensure-finalized (find-class 'project-doctor-tool))

;;; ---------------------------------------------------------------------------
;;; Turning a report into wire values
;;; ---------------------------------------------------------------------------

(defun %name-string (value)
  "Return VALUE's symbol name in lower case, or NIL when VALUE is NIL.

Every keyword the report carries reaches the wire through here, so a caller
never sees a printed Lisp form where it expected a name."
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

An entry carries the key directly when the repair loop knew it; an entry that
carries only the deviation has it one level down. The local exclude is not a
catalog item at all and legitimately has none."
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

(defun %summary-text (report policy)
  "Return the human-readable summary of REPORT under POLICY."
  (format nil "project-doctor over ~A: classified ~A, assessed as ~A.~%~
~D changed, ~D already correct, ~D recorded as debt, ~D accepted, ~D unresolved.~
~@[~%~A~]~@[~%~A~]"
          (%path-string (report-root report))
          (%name-string (report-classification report))
          (%name-string (report-profile report))
          (length (report-changed report))
          (length (report-already-correct report))
          (length (report-recorded-debt report))
          (length (report-accepted report))
          (length (report-unresolved report))
          (when (report-dry-run report)
            "This was a dry run. Nothing was written.")
          (unless policy
            "No policy was supplied, so nothing was written and every finding \
carries the outcomes it admits. Call again with policy set to act on them.")))

(defun %success-result (id report policy)
  "Return the JSON-RPC result for a completed run described by REPORT."
  (result id
          (make-ht "classification"  (%name-string (report-classification report))
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

(defun %classification-keyword (value)
  "Return the classification keyword VALUE names.

Three values are recognised and nothing else. NIL means the caller did not
answer, which is a different thing from answering wrongly, so it returns NIL and
:INVALID is reserved for a value that was supplied and is not one of the answers
this verb offers.

The comparison is explicit rather than a conversion from the caller's string,
because a conversion would let a caller reach a value the enum never offered and
the failure would land inside the doctor rather than here."
  (cond ((null value)                             nil)
        ((not (stringp value))                    :invalid)
        ((string= value "ours")                   :ours)
        ((string= value "foreign-with-upstream")  :foreign-with-upstream)
        ((string= value "foreign-orphan")         :foreign-orphan)
        (t                                        :invalid)))

(defun %policy-keyword (value)
  "Return the policy keyword VALUE names.

NIL means assess only, which is the default call. :INVALID means a value was
supplied that is not one of the three outcomes. Explicit for the same reason
%CLASSIFICATION-KEYWORD is."
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
          (classification-arg (gethash "classification" args))
          (upstream-arg       (gethash "upstream_url" args))
          (policy-arg         (gethash "policy" args))
          (dry-run            (and (gethash "dry_run" args) t)))
      (when (and path-arg (not (stringp path-arg)))
        (return-from tool-handle
          (%invalid-argument id "project-doctor: path must be a string.")))
      (when (and upstream-arg (not (stringp upstream-arg)))
        (return-from tool-handle
          (%invalid-argument id "project-doctor: upstream_url must be a string.")))
      (let ((classification (%classification-keyword classification-arg))
            (policy         (%policy-keyword policy-arg)))
        (when (eq classification :invalid)
          (return-from tool-handle
            (%invalid-argument
             id
             (format nil "project-doctor: classification must be one of ~{~A~^, ~}."
                     (coerce +accepted-classifications+ 'list)))))
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
                                :declared-classification classification
                                :upstream-url upstream-arg
                                :dry-run dry-run
                                :session-root root)
                               policy)

            ;; The question. Not a failure: this is the most common outcome for
            ;; a repository whose origin is ours, and the answer is one field on
            ;; the next call. Nothing has been written at this point.
            (repo-classification-ambiguous-error (condition)
              (result id
                      (make-ht "isError" t
                               "error_type" "repo-classification-required"
                               "requires_classification" t
                               "directory"
                               (or (%path-string
                                    (repo-classification-ambiguous-directory
                                     condition))
                                   'null)
                               "origin_url"
                               (or (repo-classification-ambiguous-origin-url
                                    condition)
                                   'null)
                               "accepted_classifications"
                               +accepted-classifications+
                               "content"
                               (text-content
                                (format nil "project-doctor is asking, not \
failing, and it has written nothing.~%~A~%Call project-doctor again with \
classification set to one of ~{~A~^, ~}. Supplying upstream_url instead answers \
the same question and records the missing remote at the same time."
                                        (princ-to-string condition)
                                        (coerce +accepted-classifications+
                                                'list))))))

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
