;;;; tests/tools/project-doctor-tool-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Zebra tests for the project-doctor verb, driven through TOOL-HANDLE.
;;;;
;;;; Everything here is measured on the wire shape rather than on the function
;;;; underneath it. The engine has its own suite; what this file defends is the
;;;; contract a caller across a process boundary actually sees, and the two are
;;;; not the same thing. An engine that refuses to guess is worth nothing if the
;;;; verb in front of it supplies a default on the caller's behalf.
;;;;
;;;; The mechanism under test is a question asked across two calls. A restart
;;;; established inside one call is gone when that call returns, so the ask has
;;;; to be a result the caller can read and the answer has to be an argument the
;;;; caller can send back. Testing either half alone proves nothing: a verb can
;;;; advertise answers it will not accept, and a verb can accept an answer it
;;;; never advertised. The two-call control does the whole round trip and takes
;;;; the answer out of the first result rather than out of this file.
;;;;
;;;; Assertions about absence are paired with the same instrument seen answering
;;;; the other way. A status required to be empty has been seen non-empty first,
;;;; and a path required to be refused sits beside one required to be accepted,
;;;; so a run in which every call failed cannot pass for a run in which the right
;;;; one failed.

;; Package evolution guard - delete prior definition on warm reload.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/tools/project-doctor-tool-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/tools/project-doctor-tool-test
  (:use #:cl #:zebra)
  (:import-from #:dsmr-mcp/src/tools/project-doctor
                #:project-doctor-tool)
  (:import-from #:dsmr-mcp/src/tools/base
                #:tool-handle
                #:tool-input-schema)
  (:import-from #:dsmr-mcp/src/state
                #:make-session)
  (:import-from #:dsmr-mcp/src/project-exclude
                #:*exclude-template-path*
                #:repo-exclude-path)
  (:import-from #:dsmr-mcp/src/project-hook
                #:gate-hook-path
                #:configured-hooks-supported-p)
  (:import-from #:dsmr-mcp/src/git
                #:git-remote-url
                #:git-head-sha
                #:run-git
                #:git-status-porcelain)
  (:import-from #:dsmr-mcp/tests/support/git-fixture
                #:with-temp-git-repo
                #:fixture-commit-file
                #:seed-exclude-patterns
                #:+ours-origin-url+
                #:+third-party-origin-url+
                #:+third-party-upstream-url+)
  (:import-from #:dsmr-mcp/tests/support/fs-fixture
                #:write-fixture-file
                #:%make-temp-directory))

(in-package #:dsmr-mcp/tests/tools/project-doctor-tool-test)

;;; ---------------------------------------------------------------------------
;;; Calling the verb the way the wire does
;;; ---------------------------------------------------------------------------

(defun %args (&rest kvs)
  "Build an equal-keyed request-args hash-table from KEY VALUE pairs.

Equal-keyed and string-keyed because that is what the JSON decoder hands the
dispatcher. A test using symbols or an EQ table would be exercising a shape no
caller can produce."
  (let ((hash (make-hash-table :test 'equal)))
    (loop for (k v) on kvs by #'cddr do (setf (gethash k hash) v))
    hash))

(defun %call (root args)
  "Dispatch TOOL-HANDLE on a fresh verb instance rooted at ROOT.

ROOT becomes the session's project root, which is both the default target and
the write jail. Returns the result payload hash-table, which is the object a
caller reads."
  (let* ((session (make-session :id "project-doctor-verb-test"
                                :project-root root))
         (tool (make-instance 'project-doctor-tool :session session))
         (response (tool-handle tool "req-doctor" args)))
    (gethash "result" response)))

;;; ---------------------------------------------------------------------------
;;; A pattern set that does not vary with the machine the suite runs on
;;; ---------------------------------------------------------------------------

(defvar +fixture-template-patterns+
  '(".claude/" "AGENTS.md" "CLAUDE.md")
  "The exclude patterns of record for the extent of this file.

Written to a file each test creates. A suite reading the developer's own
template measures something different on every machine, and nothing at all on a
build host that has none.")

(defun %write-fixture-template (directory patterns)
  "Write PATTERNS to a template file under DIRECTORY and return its pathname."
  (let ((path (merge-pathnames "info/exclude"
                               (uiop:ensure-directory-pathname directory))))
    (ensure-directories-exist path)
    (with-open-file (out path :direction :output :if-exists :supersede
                              :if-does-not-exist :create
                              :element-type 'character)
      (write-line "# A fixture pattern set, written by the test that reads it." out)
      (dolist (pattern patterns)
        (write-line pattern out)))
    path))

(defmacro with-fixture-template (&body body)
  "Make a freshly written template the pattern set of record for BODY.

The environment override is cleared as well as the variable bound, so a shell
that already points the check elsewhere cannot change what this suite measures."
  (let ((dir (gensym "TEMPLATE-DIR-"))
        (path (gensym "TEMPLATE-"))
        (saved (gensym "SAVED-")))
    `(let* ((,dir (%make-temp-directory))
            (,path (%write-fixture-template ,dir +fixture-template-patterns+))
            (,saved (uiop:getenv "DSMR_GIT_EXCLUDE_TEMPLATE"))
            (*exclude-template-path* ,path))
       (unwind-protect
            (progn
              (setf (uiop:getenv "DSMR_GIT_EXCLUDE_TEMPLATE") "")
              ,@body)
         (setf (uiop:getenv "DSMR_GIT_EXCLUDE_TEMPLATE") (or ,saved ""))
         (uiop:delete-directory-tree ,dir :validate t :if-does-not-exist :ignore)))))

;;; ---------------------------------------------------------------------------
;;; Fixture shapes
;;; ---------------------------------------------------------------------------

(defun %prepare (root)
  "Give ROOT the committed shape of a working Lisp library with a bare exclude.

The local exclude is emptied rather than left as the host's git template seeded
it, so the drift the doctor is asked to repair is the same drift on every
machine. Any gate script at GATE-HOOK-PATH goes for the same reason: a fixture
that starts with part of the gate already installed measures a different repair
from the one written down."
  (seed-exclude-patterns root '())
  (uiop:delete-file-if-exists (gate-hook-path root))
  (fixture-commit-file root "example.asd" "(asdf:defsystem \"example\")")
  (fixture-commit-file root "src/main.lisp" ";; source")
  (fixture-commit-file root "tests/main-test.lisp" ";; tests")
  root)

(defun %worktree-clean-p (root)
  "Return true when ROOT's worktree carries nothing git would report.

GIT-STATUS-PORCELAIN answers NIL for a clean tree rather than the empty string,
so a test comparing it against \"\" fails on a repository that is in exactly the
state the test required. Measured here once instead of at every call site."
  (let ((status (git-status-porcelain root)))
    (or (null status) (zerop (length status)))))

(defun %apparatus-present-p (root)
  "Return true when any of our operational apparatus sits in ROOT's worktree.

Named files rather than a walk of the tree: these are the paths a repair would
create, and a run that wrote none of them wrote none of ours."
  (let ((dir (uiop:ensure-directory-pathname root)))
    (some (lambda (relative) (and (probe-file (merge-pathnames relative dir)) t))
          '(".mallet.lisp" "scripts/lint-lisp.sh" ".gate-baseline.md"))))

(defun %exclude-text (root)
  "Return the current text of ROOT's local exclude, or the empty string."
  (let ((path (repo-exclude-path root)))
    (if (probe-file path) (uiop:read-file-string path) "")))

(defun %envrc-text (root)
  "Return the text of ROOT's .envrc, or NIL when there is none."
  (let ((path (merge-pathnames ".envrc" (uiop:ensure-directory-pathname root))))
    (when (probe-file path) (uiop:read-file-string path))))

(defun %repository-state (root)
  "Return everything a disposition question must leave unchanged in ROOT: the
head, the local exclude, the gate script, the local config, the .envrc and the
status of the worktree."
  (let ((dir (uiop:ensure-directory-pathname root)))
    (flet ((text (path) (when (probe-file path) (uiop:read-file-string path))))
      (list :head (git-head-sha root)
            :exclude (%exclude-text root)
            :gate (text (gate-hook-path root))
            :config (values (run-git (list "config" "--local" "--list")
                                     :directory root))
            :envrc (text (merge-pathnames ".envrc" dir))
            :status (git-status-porcelain root)))))

(defun %error-type (payload)
  "Return the error_type of PAYLOAD, or NIL for a completed run."
  (and (gethash "isError" payload) (gethash "error_type" payload)))

(defun %schema-enum (property-name)
  "Return the enum the verb's schema declares for PROPERTY-NAME.

Read off the class prototype, which is where the class-allocated schema lives
and where TOOLS/LIST reads it from, so this is the same literal the client is
served rather than a copy of it."
  (let* ((proto (c2mop:class-prototype (find-class 'project-doctor-tool)))
         (schema (tool-input-schema proto))
         (properties (getf (rest schema) :properties))
         (entry (find property-name properties
                      :key (lambda (property) (string (first property)))
                      :test #'string-equal)))
    (getf (rest entry) :enum)))

;;; ---------------------------------------------------------------------------
;;; The guard before anything else
;;; ---------------------------------------------------------------------------

(define-test the-verb-refuses-to-run-without-a-session-root
  "With no session root there is nothing to resolve a path against, and the verb
says so rather than operating on whatever directory the process happens to be
sitting in."
  (let* ((session (make-session :id "no-root"))
         (tool (make-instance 'project-doctor-tool :session session))
         (payload (gethash "result" (tool-handle tool "req-doctor" nil))))
    (true (gethash "isError" payload) "a rootless call is an error")
    (is equal "project-root-not-set" (gethash "error_type" payload))))

;;; ---------------------------------------------------------------------------
;;; CONTROL 1 - the ask control
;;; ---------------------------------------------------------------------------

(define-test a-repository-with-no-disposition-is-asked-about-and-left-alone
  "CONTROL: the ask control. A repository with no recorded disposition produces
the question, naming the three answers and what each means, with the origin
found reported as a fact. HEAD, the local exclude, the gate script, the local
config and the .envrc are byte-identical afterwards, and no .envrc exists.

The status instrument is seen reporting a change before it is required to
report none, so an empty answer cannot come from the instrument being aimed at
nothing."
  (with-fixture-template
    (with-temp-git-repo (root :origin-url +ours-origin-url+
                              :initial-file "seed" :initial-content "seed")
      (%prepare root)
      (write-fixture-file root "stray.txt" "not committed")
      (true (plusp (length (git-status-porcelain root)))
            "git status lists an untracked file")
      (uiop:delete-file-if-exists
       (merge-pathnames "stray.txt" (uiop:ensure-directory-pathname root)))
      (let ((before (%repository-state root))
            (payload (%call root nil)))
        (true (gethash "isError" payload) "the ask is carried as an error result")
        (is equal "project-disposition-required" (gethash "error_type" payload))
        (true (gethash "requires_disposition" payload)
              "the caller is told an answer is required")
        (is equalp #("ours" "contributing" "forked")
            (gethash "accepted_dispositions" payload)
            "the three answers are advertised in order")
        (let ((meanings (gethash "disposition_meanings" payload)))
          (true (hash-table-p meanings) "each answer carries its meaning")
          (when (hash-table-p meanings)
            (dolist (answer '("ours" "contributing" "forked"))
              (true (stringp (gethash answer meanings))
                    "~A has a meaning" answer))))
        (is equal +ours-origin-url+ (gethash "origin_url" payload)
            "the origin is reported as a fact")
        (true (stringp (gethash "text" (aref (gethash "content" payload) 0)))
              "the question carries text a person can read")
        (is equal before (%repository-state root)
            "HEAD, exclude, gate, config and .envrc are unchanged")
        (false (%envrc-text root) "no .envrc was written")
        (false (%apparatus-present-p root) "no apparatus of ours was written")))))

;;; ---------------------------------------------------------------------------
;;; CONTROL 2 - the two-call control
;;; ---------------------------------------------------------------------------

(define-test the-answer-is-recorded-once-and-never-asked-for-again
  "CONTROL: the three-call control. The answer is read out of the first call's
own accepted_dispositions array. A second call carrying it under a repair policy
records the literal declaration in .envrc, lists .envrc in the local exclude,
installs the informational gate and leaves .envrc out of git status. A third
call with no answer reads it back and asks nothing."
  (with-fixture-template
    (with-temp-git-repo (root :origin-url +ours-origin-url+
                              :initial-file "seed" :initial-content "seed")
      (%prepare root)
      (let* ((ask (%call root nil))
             (answers (gethash "accepted_dispositions" ask))
             (answer (and (vectorp answers)
                          (find "contributing" answers :test #'equal))))
        (is equal "project-disposition-required" (gethash "error_type" ask))
        (true answer "the ask advertises contributing")
        (when answer
          (let ((recorded (%call root (%args "disposition" answer
                                             "policy" "repair"))))
            (false (gethash "isError" recorded) "the answer resolves the question")
            (is equal "contributing" (gethash "disposition" recorded))
            (is equal "argument" (gethash "disposition_source" recorded))
            (let ((entry (gethash "disposition_recorded" recorded)))
              (true (hash-table-p entry) "the record is reported")
              (when (hash-table-p entry)
                (true (member (gethash "action_taken" entry)
                              '("created" "added") :test #'equal)
                      "the declaration was written: ~S"
                      (gethash "action_taken" entry))))
            (true (search (format nil "~%export DSMR_PROJECT_DISPOSITION=contributing~%")
                          (or (%envrc-text root) ""))
                  "the .envrc holds the literal declaration")
            (true (search (format nil "~%.envrc~%")
                          (format nil "~%~A" (%exclude-text root)))
                  "the local exclude lists .envrc")
            (when (configured-hooks-supported-p root)
              (true (search "GATE_MODE='informational'"
                            (uiop:read-file-string (gate-hook-path root)))
                    "the installed gate is informational"))
            (true (%worktree-clean-p root)
                  "git status does not list .envrc"))
          (let ((again (%call root nil)))
            (false (gethash "isError" again) "the third call asks nothing")
            (is equal "contributing" (gethash "disposition" again))
            (true (search ".envrc" (or (gethash "disposition_source" again) ""))
                  "and names the file it read")))))))

;;; ---------------------------------------------------------------------------
;;; CONTROL 3 - the no-inference control
;;; ---------------------------------------------------------------------------

(define-test an-unanswered-question-never-becomes-a-successful-run
  "CONTROL: the no-inference control. With nothing recorded, omitting the
disposition yields the question and never a completed run, with a policy and
without one, whatever the remotes say: an origin under the operator's account,
one under a third party, one with an upstream recorded, and none at all.

The writing policies are exercised beside the read-only call because the danger
is a verb that asks on one path and infers on the other."
  (dolist (remotes (list (list :origin +ours-origin-url+)
                         (list :origin +third-party-origin-url+)
                         (list :origin +ours-origin-url+
                               :upstream +third-party-upstream-url+)
                         (list)))
    (with-fixture-template
      (with-temp-git-repo (root :origin-url (getf remotes :origin)
                                :upstream-url (getf remotes :upstream)
                                :initial-file "seed" :initial-content "seed")
        (%prepare root)
        (let ((before (%repository-state root)))
          (dolist (args (list nil
                              (%args "policy" "repair")
                              (%args "policy" "repair" "dry_run" t)
                              (%args "policy" "repair"
                                     "upstream_url" +third-party-upstream-url+)))
            (let ((payload (%call root args)))
              (is equal "project-disposition-required" (%error-type payload)
                  "remotes ~S settle nothing" remotes)
              (false (gethash "disposition" payload)
                     "no disposition is reported for a question")))
          (is equal before (%repository-state root)
              "none of those calls wrote anything"))))))

;;; ---------------------------------------------------------------------------
;;; CONTROL 4 - the sandbox control
;;; ---------------------------------------------------------------------------

(define-test a-path-that-leaves-the-session-root-is-refused
  "CONTROL: the sandbox control. A path resolving outside the session root is
refused and nothing is written.

Paired with a path that resolves inside it and is accepted, so a run in which
every call was refused cannot pass for one in which the right call was refused."
  (with-fixture-template
    (with-temp-git-repo (root :origin-url +third-party-origin-url+
                              :initial-file "seed" :initial-content "seed")
      (%prepare root)
      (let ((escaping (%call root (%args "path" "../.." "policy" "repair"
                                         "disposition" "contributing"))))
        (true (gethash "isError" escaping) "an escaping path is an error")
        (is equal "sandbox-violation" (gethash "error_type" escaping)))
      (true (%worktree-clean-p root)
          "the refused call wrote nothing")
      (false (%apparatus-present-p root)
             "the refused call wrote no apparatus")
      ;; The same instrument accepting a path inside the root.
      (let ((inside (%call root (%args "path" "." "disposition" "contributing"))))
        (false (gethash "isError" inside)
               "a path inside the session root is accepted")))))

;;; ---------------------------------------------------------------------------
;;; What a run reports
;;; ---------------------------------------------------------------------------

(define-test changed-and-already-correct-are-separate-and-a-repeat-changes-nothing
  "A repair reports what it changed apart from what it found already correct,
and a second run over the repaired repository reports no changes at all.

The second run is what makes the first one's report mean something. A verb that
listed every item it looked at under changed would pass the first assertion and
fail here.

One file of ours is put in place before the first call so that already-correct
has something true to carry on that call as well as on the second."
  (with-fixture-template
    (with-temp-git-repo (root :origin-url +third-party-origin-url+
                              :initial-file "seed" :initial-content "seed")
      (%prepare root)
      (write-fixture-file root "AGENTS.md" "# already in place")
      (let ((first-run (%call root (%args "policy" "repair"
                                          "disposition" "contributing"))))
        (false (gethash "isError" first-run) "the repair completed")
        (is equal "contributing" (gethash "disposition" first-run))
        (is equal "foreign" (gethash "profile" first-run))
        (true (plusp (length (gethash "changed" first-run)))
              "the repair reports at least one change")
        (true (plusp (length (gethash "already_correct" first-run)))
              "the repair reports what was already correct")
        (true (vectorp (gethash "recorded_debt" first-run)))
        (true (vectorp (gethash "accepted" first-run)))
        (true (vectorp (gethash "unresolved" first-run)))
        (true (hash-table-p (gethash "exclude" first-run))
              "the local exclude repair is reported")
        (flet ((gate-entry (file)
                 (find-if (lambda (entry)
                            (and (equal "pre-commit" (gethash "item" entry))
                                 (stringp (gethash "path" entry))
                                 (string= file (file-namestring
                                                (gethash "path" entry)))))
                          (concatenate 'list
                                       (gethash "changed" first-run)
                                       (gethash "unresolved" first-run)))))
          (if (configured-hooks-supported-p root)
              (let ((wiring (gate-entry "config")))
                (true wiring "the gate's wiring is reported on the wire")
                (true (search "/.git/" (gethash "path" wiring))
                      "with a path naming the repository's local config: ~S"
                      (gethash "path" wiring))
                (true (find wiring (gethash "changed" first-run))
                      "in the changed array")
                (is equal "created" (gethash "action_taken" wiring)))
              (let ((gate (gate-entry "lisp-gate")))
                (true (find gate (gethash "unresolved" first-run))
                      "a git without configured hooks reports the gate unresolved")
                (is equal "not-installed" (gethash "action_taken" gate))
                (true (search "configured hooks" (gethash "reason" gate))
                      "with the reason: ~S" (gethash "reason" gate))
                (false (probe-file (gate-hook-path root))
                       "and no gate file was written")))))
      (let ((second-run (%call root (%args "policy" "repair"))))
        (false (gethash "isError" second-run) "the second run completed")
        (is = 0 (length (gethash "changed" second-run))
            "a repaired repository has nothing left to change")
        (true (plusp (length (gethash "already_correct" second-run)))
              "and is still reported as already correct")))))

(define-test a-dry-run-reports-the-same-shape-and-writes-nothing
  "A dry run names what would change, reports the same fields as a real run, and
leaves the repository exactly as it found it.

The exclude text is captured before and compared after, because the local
exclude is the one thing a run writes that git status cannot see."
  (with-fixture-template
    (with-temp-git-repo (root :origin-url +third-party-origin-url+
                              :initial-file "seed" :initial-content "seed")
      (%prepare root)
      (let ((exclude-before (%exclude-text root))
            (dry (%call root (%args "policy" "repair" "dry_run" t
                                    "disposition" "forked"))))
        (false (gethash "isError" dry) "a dry run completes")
        (true (gethash "dry_run" dry) "and says it was one")
        (true (plusp (length (gethash "changed" dry)))
              "a dry run still names what would change")
        (let ((entry (gethash "disposition_recorded" dry)))
          (true (hash-table-p entry) "the record it would make is reported")
          (when (hash-table-p entry)
            (is equal "would-record" (gethash "action_taken" entry))))
        (false (%envrc-text root) "a dry run writes no .envrc")
        (dolist (key '("disposition" "disposition_source" "disposition_recorded"
                       "warnings" "profile" "changed" "already_correct"
                       "recorded_debt" "accepted" "unresolved" "exclude"
                       "content"))
          (true (nth-value 1 (gethash key dry))
                (format nil "a dry run reports ~A like a real one" key)))
        (is equal exclude-before (%exclude-text root)
            "a dry run leaves the local exclude alone")
        (true (%worktree-clean-p root)
            "a dry run leaves the worktree alone")
        (false (%apparatus-present-p root)
               "a dry run writes no apparatus")))))

(define-test a-supplied-upstream-is-recorded-and-decides-nothing
  "A supplied upstream is written down as the upstream remote, and answers no
question: with a disposition it is proposed without a policy and added with
one; without a disposition the call is still the question.

Without a policy the remote is reported as one that WOULD be added, with
nothing written, which is the no-policy contract holding over the remote as it
holds over everything else."
  (with-fixture-template
    (with-temp-git-repo (root :origin-url +ours-origin-url+
                              :initial-file "seed" :initial-content "seed")
      (%prepare root)
      (false (git-remote-url root "upstream")
             "the fixture records no upstream to begin with")
      (is equal "project-disposition-required"
          (%error-type (%call root (%args "upstream_url"
                                          +third-party-upstream-url+
                                          "policy" "repair")))
          "an upstream alone answers nothing")
      (false (git-remote-url root "upstream")
             "and the question wrote no remote")
      (let* ((assessed (%call root (%args "upstream_url"
                                          +third-party-upstream-url+
                                          "disposition" "forked")))
             (proposed (gethash "remote_added" assessed)))
        (false (gethash "isError" assessed) "the assessment completed")
        (is equal "forked" (gethash "disposition" assessed))
        (true (hash-table-p proposed) "the remote it would add is reported")
        (when (hash-table-p proposed)
          (is equal "would-add" (gethash "action_taken" proposed)))
        (false (git-remote-url root "upstream")
               "and a call with no policy wrote nothing"))
      (let* ((payload (%call root (%args "upstream_url"
                                         +third-party-upstream-url+
                                         "disposition" "forked"
                                         "policy" "repair")))
             (remote (gethash "remote_added" payload)))
        (false (gethash "isError" payload) "the repair completed")
        (is equal "forked" (gethash "disposition" payload))
        (true (hash-table-p remote) "the remote it added is reported")
        (when (hash-table-p remote)
          (is equal "upstream" (gethash "remote" remote))
          (is equal +third-party-upstream-url+ (gethash "url" remote))
          (is equal "added" (gethash "action_taken" remote)))
        (is equal +third-party-upstream-url+ (git-remote-url root "upstream")
            "and the remote is really there")))))

;;; ---------------------------------------------------------------------------
;;; Failures that must arrive typed rather than as an unhandled error
;;; ---------------------------------------------------------------------------

(define-test a-directory-that-is-not-a-repository-is-named-as-such
  "A directory outside any repository is reported with its own type, not as a
generic failure and not as a crash out of the handler."
  (let ((dir (%make-temp-directory)))
    (unwind-protect
         (let ((payload (%call dir nil)))
           (true (gethash "isError" payload))
           (is equal "not-a-git-repository" (gethash "error_type" payload)))
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))

(define-test a-failing-git-invocation-is-reported-with-its-exit-code
  "A git invocation that fails reaches the caller as a typed result carrying the
exit code, rather than escaping the verb as an unhandled condition.

The upstream URL used here begins with a hyphen, which git would read as an
option rather than a location. It is rejected before any process starts, which
is reported as exit code -1: no remote was added and none could have been.

A policy is supplied because the remote is only written under one. Without it
the run reports what it would add and never reaches git at all, so the failure
this test is aimed at could not occur."
  (with-fixture-template
    (with-temp-git-repo (root :origin-url +ours-origin-url+
                              :initial-file "seed" :initial-content "seed")
      (%prepare root)
      (let ((payload (%call root (%args "upstream_url" "--upload-pack=x"
                                        "disposition" "forked"
                                        "policy" "repair"))))
        (true (gethash "isError" payload))
        (is equal "git-command-failed" (gethash "error_type" payload))
        (is = -1 (gethash "exit_code" payload)
            "the exit code the invocation failed with is reported")
        (false (git-remote-url root "upstream")
               "and no remote was added")))))

(define-test a-value-outside-the-enum-is-refused-rather-than-becoming-a-keyword
  "A disposition or policy the verb does not offer is refused as an invalid
argument. Nothing the caller sends is converted into a keyword, so a value the
enum never offered cannot reach the engine by construction."
  (with-fixture-template
    (with-temp-git-repo (root :origin-url +ours-origin-url+
                              :initial-file "seed" :initial-content "seed")
      (%prepare root)
      (let ((before (%repository-state root)))
        (dolist (args (list (%args "disposition" "theirs")
                            (%args "disposition" "OURS ")
                            (%args "disposition" "foreign")
                            (%args "policy" "delete-everything")
                            (%args "policy" "repair " "disposition" "ours")))
          (let ((payload (%call root args)))
            (true (gethash "isError" payload)
                  "a value outside the enum is an error")
            (is equal "invalid-argument" (gethash "error_type" payload))))
        (is equal before (%repository-state root)
            "a refused argument wrote nothing")))))

;;; ---------------------------------------------------------------------------
;;; The advertised answers and the accepted answers are one set
;;; ---------------------------------------------------------------------------

(define-test the-answers-advertised-are-the-answers-the-schema-accepts
  "Every answer the question advertises is one the schema's enum accepts, and
the two lists are the same length.

They are written out twice, in the ask and in the class-allocated schema, and a
drift between them would produce a question whose own answer is rejected by
argument validation before it ever reached the verb."
  (with-fixture-template
    (with-temp-git-repo (root :origin-url +ours-origin-url+
                              :initial-file "seed" :initial-content "seed")
      (%prepare root)
      (let ((advertised (gethash "accepted_dispositions" (%call root nil)))
            (declared (%schema-enum "disposition")))
        (true (and (vectorp advertised) (plusp (length advertised)))
              "the ask advertises answers")
        (true (and (listp declared) (plusp (length declared)))
              "the schema declares an enum for disposition")
        (is = (length declared) (length advertised)
            "the two lists name the same number of answers")
        (when (vectorp advertised)
          (loop for answer across advertised
                do (true (member answer declared :test #'string=)
                         (format nil "~A is one the schema accepts" answer))))
        (false (%schema-enum "classification")
               "the schema no longer offers a classification")))))

(define-test every-disposition-refusal-writes-nothing
  "Each refusal comes back typed and leaves the repository as it was: a supplied
answer differing from the recorded one, a recorded value that cannot be read,
two recorded values that disagree, and a tracked .envrc on a run that would
record. Paired with the same fixture's repair succeeding once the cause is
gone, so the refusals are not every call failing."
  (flet ((refused (expected setup args)
           (with-fixture-template
             (with-temp-git-repo (root :origin-url +third-party-origin-url+
                                       :initial-file "seed" :initial-content "seed")
               (%prepare root)
               (funcall setup root)
               (let ((before (%repository-state root))
                     (payload (%call root args)))
                 (is equal expected (%error-type payload)
                     "~A is refused as ~A" args expected)
                 (true (search "written nothing"
                               (or (gethash "text"
                                            (aref (gethash "content" payload) 0))
                                   ""))
                       "the refusal says it wrote nothing")
                 (is equal before (%repository-state root)
                     "and nothing was written"))))))
    (refused "project-disposition-conflict"
             (lambda (root)
               (write-fixture-file root ".envrc"
                                   (format nil "export DSMR_PROJECT_DISPOSITION=contributing~%")))
             (%args "disposition" "ours" "policy" "repair"))
    (refused "project-disposition-unreadable"
             (lambda (root)
               (write-fixture-file root ".envrc"
                                   (format nil "export DSMR_PROJECT_DISPOSITION=\"${X:-ours}\"~%")))
             (%args "policy" "repair"))
    (refused "project-disposition-unreadable"
             (lambda (root)
               (write-fixture-file root ".envrc"
                                   (format nil "export DSMR_PROJECT_DISPOSITION=maybe~%")))
             (%args "policy" "repair"))
    (refused "project-disposition-conflict"
             (lambda (root)
               (write-fixture-file root ".envrc"
                                   (format nil "export DSMR_PROJECT_DISPOSITION=ours~%~
export DSMR_PROJECT_DISPOSITION=forked~%")))
             (%args "policy" "repair"))
    (refused "project-disposition-not-recordable"
             (lambda (root)
               (fixture-commit-file root ".envrc" (format nil "export FOO=bar~%")))
             (%args "disposition" "contributing" "policy" "repair")))
  ;; The control: the same fixture with nothing in the way completes.
  (with-fixture-template
    (with-temp-git-repo (root :origin-url +third-party-origin-url+
                              :initial-file "seed" :initial-content "seed")
      (%prepare root)
      (false (gethash "isError"
                      (%call root (%args "disposition" "contributing"
                                         "policy" "repair")))
             "with nothing in the way the repair completes"))))

(define-test remote-facts-arrive-as-warnings-and-change-nothing
  "Declared ours with an upstream remote recorded completes, as ours, with a
warning on the wire. Declared forked with the same remotes carries none."
  (with-fixture-template
    (with-temp-git-repo (root :origin-url +ours-origin-url+
                              :upstream-url +third-party-upstream-url+
                              :initial-file "seed" :initial-content "seed")
      (%prepare root)
      (let ((ours (%call root (%args "disposition" "ours"))))
        (false (gethash "isError" ours))
        (is equal "ours" (gethash "disposition" ours) "the warning decides nothing")
        (true (plusp (length (gethash "warnings" ours)))
              "ours with an upstream remote warns"))
      (let ((forked (%call root (%args "disposition" "forked"))))
        (is equal "forked" (gethash "disposition" forked))
        (is = 0 (length (gethash "warnings" forked))
            "forked with an upstream is normal")))))
