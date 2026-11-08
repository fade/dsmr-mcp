;;;; tests/repo/repo-classify-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Zebra tests for the declared project disposition, over real git repositories.
;;;;
;;;; The disposition is a fact the operator states once, recorded in the
;;;; repository's own untracked .envrc. These tests hold the reader to the file
;;;; and nothing else: remotes, the process environment and the absence of a
;;;; declaration each get a fixture in which a reader that consulted them would
;;;; answer differently from one that did not.
;;;;
;;;; Every refusal is checked for the bytes it did not write, beside a fixture in
;;;; which the same write does happen, so an instrument aimed at nothing cannot
;;;; pass for one reporting an absence.

;; Package evolution guard - delete prior definition on warm reload.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/repo/repo-classify-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/repo/repo-classify-test
  (:use #:cl #:zebra)
  (:import-from #:dsmr-mcp/src/repo-classify
                #:+dispositions+
                #:+disposition-variable+
                #:resolve-disposition
                #:record-disposition
                #:disposition-profile
                #:disposition-warnings
                #:project-disposition-required
                #:disposition-required-directory
                #:disposition-required-origin-url
                #:project-disposition-conflict
                #:disposition-conflict-declarations
                #:project-disposition-unreadable
                #:disposition-unreadable-path
                #:disposition-unreadable-value
                #:project-disposition-not-recordable
                #:disposition-not-recordable-path)
  (:import-from #:dsmr-mcp/src/envrc-vars
                #:declared-values)
  (:import-from #:dsmr-mcp/src/project-exclude
                #:repo-exclude-path
                #:parse-exclude-patterns)
  (:import-from #:dsmr-mcp/src/git
                #:not-a-repository-error)
  (:import-from #:dsmr-mcp/tests/support/git-fixture
                #:with-temp-git-repo
                #:with-linked-worktree
                #:fixture-commit-file
                #:seed-exclude-patterns
                #:+ours-origin-url+
                #:+third-party-origin-url+
                #:+third-party-upstream-url+)
  (:import-from #:dsmr-mcp/tests/support/fs-fixture
                #:write-fixture-file
                #:%make-temp-directory))

(in-package #:dsmr-mcp/tests/repo/repo-classify-test)

;;; --- helpers ----------------------------------------------------------------

(defun %envrc (root)
  "Return the pathname of ROOT's .envrc."
  (merge-pathnames ".envrc" (uiop:ensure-directory-pathname root)))

(defun %envrc-text (root)
  "Return the text of ROOT's .envrc, or NIL when there is none."
  (let ((path (%envrc root)))
    (when (probe-file path) (uiop:read-file-string path))))

(defun %exclude-text (root)
  "Return the text of ROOT's local exclude, or the empty string."
  (let ((path (repo-exclude-path root)))
    (if (probe-file path) (uiop:read-file-string path) "")))

(defun %excluded-p (root pattern)
  "Return true when ROOT's local exclude lists PATTERN."
  (and (member pattern (parse-exclude-patterns (%exclude-text root))
               :test #'string=)
       t))

(defun %declare (root value)
  "Write a .envrc under ROOT holding one disposition declaration of VALUE."
  (write-fixture-file root ".envrc"
                      (format nil "export DSMR_PROJECT_DISPOSITION=~A~%" value)))

(defun %signalled (type function &rest arguments)
  "Return the condition of TYPE signalled by applying FUNCTION to ARGUMENTS, or
NIL when the call returned. Lets a test read the slots of the refusal."
  (handler-case (progn (apply function arguments) nil)
    (condition (c) (when (typep c type) c))))

(defmacro with-process-variable ((name value) &body body)
  "Run BODY with the process environment variable NAME set to VALUE, restoring
the previous value afterwards."
  (let ((saved (gensym "SAVED-")))
    `(let ((,saved (uiop:getenv ,name)))
       (unwind-protect
            (progn (setf (uiop:getenv ,name) ,value) ,@body)
         (setf (uiop:getenv ,name) (or ,saved ""))))))

;;; --- the vocabulary ---------------------------------------------------------

(define-test the-three-dispositions-and-the-variable-that-records-them
  "The operator's three dispositions, in the order they are offered, and the
shell variable a .envrc records one in."
  (is equal '(:ours :contributing :forked) +dispositions+)
  (is string= "DSMR_PROJECT_DISPOSITION" +disposition-variable+))

(define-test declared-values-returns-every-declaration-in-file-order
  "Every declaration of a name, in file order, so two that disagree can be seen.
A comment that mentions the name declares nothing."
  (is equal '("ours" "\"forked\"")
      (declared-values (format nil "# DSMR_PROJECT_DISPOSITION=contributing~%~
export DSMR_PROJECT_DISPOSITION=ours~%~
X=1~%~
DSMR_PROJECT_DISPOSITION=\"forked\"~%")
                       "DSMR_PROJECT_DISPOSITION"))
  (is equal '() (declared-values "export X=1" "DSMR_PROJECT_DISPOSITION")))

;;; --- nothing recorded: the question -----------------------------------------

(define-test with-nothing-recorded-the-question-is-asked
  "With no declaration and no supplied answer the reader signals the question,
carrying the directory and the origin found. The repository is not written."
  (with-temp-git-repo (root :origin-url +ours-origin-url+
                            :initial-file "seed" :initial-content "seed")
    (let ((exclude-before (%exclude-text root))
          (condition (%signalled 'project-disposition-required
                                 #'resolve-disposition root)))
      (true condition "the question is signalled")
      (when condition
        (is equal +ours-origin-url+ (disposition-required-origin-url condition))
        (true (disposition-required-directory condition)))
      (false (probe-file (%envrc root)) "no .envrc was written")
      (is equal exclude-before (%exclude-text root)
          "the local exclude is untouched"))))

(define-test remotes-decide-nothing
  "An origin under the operator's account, an origin under a third party and no
origin at all each produce the question when nothing is recorded. An upstream
remote decides nothing either."
  (dolist (remotes (list (list :origin +ours-origin-url+)
                         (list :origin +third-party-origin-url+)
                         (list :origin +ours-origin-url+
                               :upstream +third-party-upstream-url+)
                         (list)))
    (with-temp-git-repo (root :origin-url (getf remotes :origin)
                              :upstream-url (getf remotes :upstream)
                              :initial-file "seed" :initial-content "seed")
      (true (%signalled 'project-disposition-required #'resolve-disposition root)
            "remotes ~S settle nothing" remotes))))

(define-test a-plain-directory-is-not-a-repository
  "A directory outside any repository is refused as such."
  (let ((dir (%make-temp-directory)))
    (unwind-protect
         (fail (resolve-disposition dir) 'not-a-repository-error)
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))

;;; --- reading a declaration --------------------------------------------------

(define-test a-declaration-in-the-file-is-the-answer
  "Each of the three values, bare and inside one pair of matching quotes, reads
back as its keyword, and the source is the file it was read from."
  (dolist (case '(("ours" :ours) ("contributing" :contributing)
                  ("forked" :forked) ("\"forked\"" :forked)
                  ("'contributing'" :contributing)))
    (with-temp-git-repo (root :initial-file "seed" :initial-content "seed")
      (%declare root (first case))
      (multiple-value-bind (disposition source) (resolve-disposition root)
        (is eq (second case) disposition "~A reads back" (first case))
        (is equal (namestring (truename (%envrc root)))
            (namestring (truename source))
            "the source is the .envrc")))))

(define-test the-process-environment-is-never-read
  "With the variable set to ours in this process and the file declaring
contributing, the answer is contributing. With the variable set and no file at
all, the question is still asked."
  (with-process-variable ("DSMR_PROJECT_DISPOSITION" "ours")
    (with-temp-git-repo (root :initial-file "seed" :initial-content "seed")
      (%declare root "contributing")
      (is eq :contributing (resolve-disposition root)))
    (with-temp-git-repo (root :initial-file "seed" :initial-content "seed")
      (true (%signalled 'project-disposition-required #'resolve-disposition root)
            "an inherited variable is not a declaration"))))

(define-test an-unreadable-value-is-refused
  "A shell expansion, an unknown word and mismatched quotes are refused, naming
the file and the value, rather than read as a guess."
  (dolist (value '("${X:-ours}" "maybe" "\"ours'" "OURS" ""))
    (with-temp-git-repo (root :initial-file "seed" :initial-content "seed")
      (%declare root value)
      (let ((condition (%signalled 'project-disposition-unreadable
                                   #'resolve-disposition root)))
        (true condition "~S is refused" value)
        (when condition
          (is equal value (disposition-unreadable-value condition))
          (true (disposition-unreadable-path condition)))))))

(define-test declarations-that-disagree-are-refused
  "Two declarations in one file that disagree are refused, never resolved by
taking the first or the last. Two that agree are one answer."
  (with-temp-git-repo (root :initial-file "seed" :initial-content "seed")
    (write-fixture-file root ".envrc"
                        (format nil "export DSMR_PROJECT_DISPOSITION=ours~%~
export DSMR_PROJECT_DISPOSITION=forked~%"))
    (let ((condition (%signalled 'project-disposition-conflict
                                 #'resolve-disposition root)))
      (true condition "the disagreement is refused")
      (when condition
        (is = 2 (length (disposition-conflict-declarations condition))))))
  (with-temp-git-repo (root :initial-file "seed" :initial-content "seed")
    (write-fixture-file root ".envrc"
                        (format nil "export DSMR_PROJECT_DISPOSITION=forked~%~
export DSMR_PROJECT_DISPOSITION=\"forked\"~%"))
    (is eq :forked (resolve-disposition root))))

(define-test a-supplied-answer-is-used-only-when-nothing-is-recorded
  "With nothing recorded a supplied answer is the disposition and its source is
the argument. With a declaration recorded, the same answer agrees and the file
is the source; a different one is refused."
  (with-temp-git-repo (root :initial-file "seed" :initial-content "seed")
    (multiple-value-bind (disposition source)
        (resolve-disposition root :supplied :forked)
      (is eq :forked disposition)
      (is eq :argument source)))
  (with-temp-git-repo (root :initial-file "seed" :initial-content "seed")
    (%declare root "contributing")
    (multiple-value-bind (disposition source)
        (resolve-disposition root :supplied :contributing)
      (is eq :contributing disposition)
      (true (pathnamep source) "the recorded file is the source"))
    (true (%signalled 'project-disposition-conflict
                      #'resolve-disposition root :supplied :ours)
          "a supplied answer that differs from the record is refused")))

;;; --- linked worktrees -------------------------------------------------------

(define-test a-linked-worktree-reads-the-main-worktrees-declaration
  "A linked worktree with no declaration of its own resolves from the main
worktree's .envrc, and neither file is written by the read."
  (with-temp-git-repo (root :initial-file "seed" :initial-content "seed")
    (%declare root "forked")
    (let ((main-before (%envrc-text root)))
      (with-linked-worktree (worktree root)
        (multiple-value-bind (disposition source) (resolve-disposition worktree)
          (is eq :forked disposition)
          (is equal (namestring (truename (%envrc root)))
              (namestring (truename source))
              "the source is the main worktree's .envrc"))
        (false (probe-file (%envrc worktree))
               "nothing was written into the linked worktree")
        (is equal main-before (%envrc-text root)
            "the main worktree's .envrc is unchanged")))))

(define-test worktrees-that-disagree-are-refused-naming-both-files
  "A linked worktree declaring a value different from the main worktree's is
refused, and the refusal names both files."
  (with-temp-git-repo (root :initial-file "seed" :initial-content "seed")
    (%declare root "forked")
    (with-linked-worktree (worktree root)
      (%declare worktree "contributing")
      (let ((condition (%signalled 'project-disposition-conflict
                                   #'resolve-disposition worktree)))
        (true condition "the disagreement is refused")
        (when condition
          (let ((sources (mapcar (lambda (entry)
                                   (namestring (truename (car entry))))
                                 (disposition-conflict-declarations condition))))
            (true (member (namestring (truename (%envrc root))) sources
                          :test #'string=)
                  "the main worktree's file is named")
            (true (member (namestring (truename (%envrc worktree))) sources
                          :test #'string=)
                  "the linked worktree's file is named")))))))

;;; --- recording --------------------------------------------------------------

(define-test recording-creates-the-file-and-excludes-it-first
  "Recording into a repository with no .envrc creates one holding the literal
declaration, lists .envrc in the local exclude, and leaves git status clean. A
second record of the same value changes nothing."
  (with-temp-git-repo (root :initial-file "seed" :initial-content "seed")
    (seed-exclude-patterns root '())
    (false (%excluded-p root ".envrc") "precondition: .envrc is not excluded")
    (let ((result (record-disposition root :contributing)))
      (is eq :created (getf result :action-taken))
      (is eq :contributing (getf result :disposition)))
    (true (search "export DSMR_PROJECT_DISPOSITION=contributing"
                  (or (%envrc-text root) ""))
          "the literal declaration is in the file")
    (is eq :contributing (resolve-disposition root) "and reads back")
    (true (%excluded-p root ".envrc") ".envrc is in the local exclude")
    (is equal '() (dsmr-mcp/src/git:git-status-porcelain root)
        "git status does not list .envrc")
    (let ((text (%envrc-text root)))
      (is eq :already-present
          (getf (record-disposition root :contributing) :action-taken))
      (is equal text (%envrc-text root) "a repeat record writes nothing"))))

(define-test recording-edits-an-existing-file-in-place
  "An existing .envrc with operator lines outside and inside a managed region
gains exactly one line, inside the region, and every other byte is kept."
  (with-temp-git-repo (root :initial-file "seed" :initial-content "seed")
    (let ((before (format nil "# operator's own~%export FOO=bar~%~%~
# >>> dsmr-mcp (added automatically; edit or remove freely) >>>~%~
export DSMR_LOG_LEVEL=info~%~
# <<< dsmr-mcp <<<~%~
export AFTER=1~%")))
      (write-fixture-file root ".envrc" before)
      (is eq :added (getf (record-disposition root :forked) :action-taken))
      (is equal (format nil "# operator's own~%export FOO=bar~%~%~
# >>> dsmr-mcp (added automatically; edit or remove freely) >>>~%~
export DSMR_LOG_LEVEL=info~%~
export DSMR_PROJECT_DISPOSITION=forked~%~
# <<< dsmr-mcp <<<~%~
export AFTER=1~%")
          (%envrc-text root)))))

(define-test a-dry-run-record-writes-nothing
  "A dry run reports that it would record and writes neither the .envrc nor the
local exclude."
  (with-temp-git-repo (root :initial-file "seed" :initial-content "seed")
    (seed-exclude-patterns root '())
    (let ((exclude-before (%exclude-text root)))
      (is eq :would-record
          (getf (record-disposition root :ours :dry-run t) :action-taken))
      (false (probe-file (%envrc root)) "no .envrc was written")
      (is equal exclude-before (%exclude-text root) "the exclude is unchanged"))))

(define-test a-tracked-envrc-is-never-recorded-into
  "A repository that tracks its .envrc is refused: a declaration written there
would be committed. The file and the exclude are left as they were."
  (with-temp-git-repo (root :initial-file "seed" :initial-content "seed")
    (seed-exclude-patterns root '())
    (fixture-commit-file root ".envrc" (format nil "export FOO=bar~%"))
    (let ((text-before (%envrc-text root))
          (exclude-before (%exclude-text root))
          (condition (%signalled 'project-disposition-not-recordable
                                 #'record-disposition root :ours)))
      (true condition "the record is refused")
      (when condition
        (true (disposition-not-recordable-path condition)))
      (is equal text-before (%envrc-text root) "the .envrc is unchanged")
      (is equal exclude-before (%exclude-text root) "the exclude is unchanged"))))

(define-test a-recorded-value-is-never-rewritten
  "Recording a value different from the one already declared is refused and the
file is unchanged: a change of disposition is a hand edit."
  (with-temp-git-repo (root :initial-file "seed" :initial-content "seed")
    (%declare root "contributing")
    (let ((before (%envrc-text root)))
      (true (%signalled 'project-disposition-conflict
                        #'record-disposition root :ours))
      (is equal before (%envrc-text root)))))

;;; --- profile and warnings ---------------------------------------------------

(define-test ours-and-forked-take-the-blocking-profile
  "ours and forked map to the :OURS profile, contributing to :FOREIGN, and
anything else is a type error rather than a default."
  (is eq :ours (disposition-profile :ours))
  (is eq :ours (disposition-profile :forked))
  (is eq :foreign (disposition-profile :contributing))
  (fail (disposition-profile :foreign) 'type-error)
  (fail (disposition-profile nil) 'type-error))

(define-test remote-facts-only-warn
  "ours with an upstream remote warns; contributing with no upstream remote and
no supplied upstream warns; forked warns about neither. The warnings change no
answer."
  (with-temp-git-repo (root :origin-url +ours-origin-url+
                            :upstream-url +third-party-upstream-url+
                            :initial-file "seed" :initial-content "seed")
    (true (disposition-warnings root :ours) "ours plus an upstream warns")
    (is equal '() (disposition-warnings root :forked) "forked with one does not")
    (is equal '() (disposition-warnings root :contributing)
        "contributing with one does not"))
  (with-temp-git-repo (root :origin-url +ours-origin-url+
                            :initial-file "seed" :initial-content "seed")
    (true (disposition-warnings root :contributing)
          "contributing with no upstream warns")
    (is equal '() (disposition-warnings root :contributing
                                        :upstream-url +third-party-upstream-url+)
        "a supplied upstream answers it")
    (is equal '() (disposition-warnings root :forked) "forked without one does not")
    (is equal '() (disposition-warnings root :ours) "ours without one does not")))

(define-test a-declaration-recorded-only-in-a-linked-worktree-warns
  "A declaration held only by a linked worktree warns that a new worktree would
be asked again. The same declaration in the main worktree does not warn."
  (with-temp-git-repo (root :initial-file "seed" :initial-content "seed")
    (with-linked-worktree (worktree root)
      (%declare worktree "forked")
      (true (some (lambda (w) (search "worktree" w))
                  (disposition-warnings worktree :forked))
            "the linked-worktree-only declaration warns"))
    (%declare root "forked")
    (is equal '() (disposition-warnings root :forked)
        "the main worktree's declaration does not")))

(define-test a-dry-run-from-a-linked-worktree-claims-no-record
  "With nothing declared anywhere, the warnings for a supplied answer in a linked
worktree say nothing about where it is recorded: nothing is."
  (with-temp-git-repo (root :initial-file "seed" :initial-content "seed")
    (with-linked-worktree (worktree root)
      (is equal '() (disposition-warnings worktree :forked)
          "no warning claims a record that a dry run did not make"))))

(define-test recording-from-a-linked-worktree-writes-the-main-worktrees-envrc
  "A record made from a linked worktree lands in the main worktree's .envrc,
which every worktree of the repository reads, and nothing is written in the
linked worktree. With the main worktree outside the write jail, the record is
refused and names the main worktree's file."
  (with-temp-git-repo (root :initial-file "seed" :initial-content "seed")
    (with-linked-worktree (worktree root)
      (let ((condition (%signalled 'project-disposition-not-recordable
                                   #'record-disposition worktree :forked
                                   :jail worktree)))
        (true condition "a main worktree outside the jail is refused")
        (when condition
          (true (search (namestring (merge-pathnames ".envrc" (truename root)))
                        (princ-to-string condition))
                "the refusal names the main worktree's file: ~A" condition))
        (false (probe-file (%envrc root)) "nothing was written in main"))
      (let ((result (record-disposition worktree :forked :jail root)))
        (is eq :created (getf result :action-taken)))
      (true (search "DSMR_PROJECT_DISPOSITION=forked" (or (%envrc-text root) ""))
            "the main worktree's .envrc holds the declaration")
      (false (probe-file (%envrc worktree))
             "nothing was written in the linked worktree")
      (is eq :forked (resolve-disposition worktree) "the worktree reads it")
      (is eq :forked (resolve-disposition root) "and so does main"))))

(define-test main-disagreeing-with-a-linked-worktree-is-refused
  "Resolved from the main worktree, a linked worktree's declaration that differs
is refused naming both files, and a supplied answer that differs from a linked
worktree's declaration is refused as well."
  (with-temp-git-repo (root :initial-file "seed" :initial-content "seed")
    (with-linked-worktree (worktree root)
      (%declare worktree "ours")
      (let ((condition (%signalled 'project-disposition-conflict
                                   #'resolve-disposition root
                                   :supplied :contributing)))
        (true condition "the supplied answer is refused")
        (when condition
          (true (find-if (lambda (entry)
                           (and (pathnamep (car entry))
                                (string= (namestring (truename (car entry)))
                                         (namestring (truename (%envrc worktree))))))
                         (disposition-conflict-declarations condition))
                "the linked worktree's file is named")))
      (%declare root "contributing")
      (let ((condition (%signalled 'project-disposition-conflict
                                   #'resolve-disposition root)))
        (true condition "the two declarations are refused from main")
        (when condition
          (let ((sources (mapcar (lambda (entry)
                                   (namestring (truename (car entry))))
                                 (disposition-conflict-declarations condition))))
            (true (member (namestring (truename (%envrc root))) sources
                          :test #'string=)
                  "the main worktree's file is named")
            (true (member (namestring (truename (%envrc worktree))) sources
                          :test #'string=)
                  "the linked worktree's file is named")))))))

(defun %file-mode (path)
  "Return the permission bits of PATH as an octal string."
  (string-right-trim '(#\Newline)
                     (uiop:run-program (list "stat" "-c" "%a" (namestring path))
                                       :output :string)))

(define-test recording-keeps-the-envrc-mode
  "A 0600 .envrc, as one holding a token would be, is still 0600 after a record
adds the declaration."
  (with-temp-git-repo (root :initial-file "seed" :initial-content "seed")
    (write-fixture-file root ".envrc" (format nil "export TOKEN=secret~%"))
    (uiop:run-program (list "chmod" "600" (namestring (%envrc root))))
    (is string= "600" (%file-mode (%envrc root)) "precondition: mode 600")
    (is eq :added (getf (record-disposition root :ours) :action-taken))
    (is string= "600" (%file-mode (%envrc root)) "the mode is kept")))

(define-test a-non-utf-8-envrc-reads-and-records-byte-for-byte
  "An .envrc with a Latin-1 comment is read without a decoding error, a record
adds the declaration, and every other byte comes back unchanged."
  (with-temp-git-repo (root :initial-file "seed" :initial-content "seed")
    (let ((bytes (map '(vector (unsigned-byte 8)) #'char-code
                      (format nil "# caf~C~%export FOO=1~%" (code-char 233)))))
      (with-open-file (out (%envrc root) :direction :output
                                         :element-type '(unsigned-byte 8)
                                         :if-exists :supersede
                                         :if-does-not-exist :create)
        (write-sequence bytes out))
      (true (%signalled 'project-disposition-required #'resolve-disposition root)
            "the file reads, and declares nothing")
      (is eq :added (getf (record-disposition root :ours) :action-taken))
      (let ((after (with-open-file (in (%envrc root)
                                       :element-type '(unsigned-byte 8))
                     (let ((v (make-array (file-length in)
                                          :element-type '(unsigned-byte 8))))
                       (read-sequence v in)
                       v))))
        (is equalp bytes (subseq after 0 (length bytes))
            "the original bytes are kept")
        (is eq :ours (resolve-disposition root) "and the record reads back")))))

(define-test an-export-followed-by-a-tab-is-a-declaration
  "export followed by a tab declares the variable, as the shell reads it."
  (is equal '("ours")
      (declared-values (format nil "export~CDSMR_PROJECT_DISPOSITION=ours~%"
                               #\Tab)
                       +disposition-variable+)))
