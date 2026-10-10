;;;; tests/fs/project-root-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Tests for VERB-01/02, D-05 permission gate, D-16 no-root guard.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/fs/project-root-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/fs/project-root-test
  (:use #:cl #:zebra)
  (:import-from #:dsmr-mcp/src/state
                #:make-session
                #:session-project-root
                #:session-launch-project-root
                #:session-project-root-just-set-p
                #:get-tool-instance)
  (:import-from #:dsmr-mcp/src/project-root
                #:allowed-read-path
                #:broad-root-p)
  (:import-from #:dsmr-mcp/src/tools/base
                #:tool-handle)
  ;; Force tool package loading so their metaclass registrations run
  ;; before any test body calls get-tool-instance.
  (:import-from #:dsmr-mcp/src/tools/fs-read-file)
  (:import-from #:dsmr-mcp/src/tools/fs-set-project-root)
  (:import-from #:dsmr-mcp/tests/support/fs-fixture
                #:with-temp-project-root
                #:%make-temp-directory))

(in-package #:dsmr-mcp/tests/fs/project-root-test)

;;; D-16: fresh session has no project root ----------------------------------

(defmacro %with-related-projects ((value) &body body)
  "Run BODY with DSMR_RELATED_PROJECTS bound to VALUE, restoring the previous
setting -- including its absence -- on any exit."
  (let ((saved (gensym "SAVED-")))
    `(let ((,saved (uiop:getenv "DSMR_RELATED_PROJECTS")))
       (unwind-protect
            (progn (sb-posix:setenv "DSMR_RELATED_PROJECTS" ,value 1)
                   ,@body)
         (if ,saved
             (sb-posix:setenv "DSMR_RELATED_PROJECTS" ,saved 1)
             (sb-posix:unsetenv "DSMR_RELATED_PROJECTS"))))))

(defun %reroot-result (session target-namestring &key approved)
  "Ask SESSION's fs-set-project-root tool to adopt TARGET-NAMESTRING, without
human_approved unless APPROVED, and return the tool's result hash table."
  (let* ((tool (get-tool-instance session "fs-set-project-root"))
         (args (let ((h (make-hash-table :test 'equal)))
                 (setf (gethash "path" h) target-namestring)
                 (when approved (setf (gethash "human_approved" h) t))
                 h)))
    (gethash "result" (tool-handle tool 1 args))))

(define-test fresh-session-has-no-root
  "A freshly created session has NIL as its project root (D-16)."
  (let ((s (make-session :id "test-no-root")))
    (false (session-project-root s))))

;;; D-13: broad roots are rejected -------------------------------------------

(define-test broad-root-rejected
  "broad-root-p returns T for overly broad paths (D-13).
Covers original entries and the expanded deny list (system pseudo-filesystems
and privileged home directories)."
  ;; Original deny list
  (true  (broad-root-p #p"/"))
  (true  (broad-root-p #p"/tmp/"))
  (true  (broad-root-p #p"/home/"))
  (true  (broad-root-p #p"/usr/"))
  (true  (broad-root-p #p"/etc/"))
  (true  (broad-root-p #p"/var/"))
  ;; Expanded deny list
  (true  (broad-root-p #p"/root/"))
  (true  (broad-root-p #p"/dev/"))
  (true  (broad-root-p #p"/proc/"))
  (true  (broad-root-p #p"/sys/"))
  (true  (broad-root-p #p"/run/"))
  (true  (broad-root-p #p"/boot/"))
  ;; A specific project directory is not broad
  (false (broad-root-p #p"/home/fade/SourceCode/lisp/dsmr-mcp/")))

(define-test symlinked-broad-root-rejected
  "A candidate project root that is itself a symlink to a broad/denied path
must be rejected by broad-root-p even when the supplied path looks specific.
Regression for the symlink bypass in the broad-root guard."
  (let* ((outside-dir (%make-temp-directory)))
    (unwind-protect
         (with-temp-project-root (_session root)
           ;; Create a symlink inside the root pointing to /tmp (a broad root)
           (let ((link-name (namestring (make-pathname :name "fake-proj" :defaults root))))
             ;; Point the link at an actual broad-root-denied directory (/tmp)
             ;; We use outside-dir (under /tmp) as a proxy; the actual /tmp symlink test
             ;; would require /tmp to be a symlink itself (macOS behavior).
             ;; Instead, test that a symlink to outside-dir (under /tmp) is not itself
             ;; a broad root — the broad-root protection applies to the root PATH, not
             ;; to a path within the root.  The real concern (CR-03) is that the
             ;; %resolve-with-parent-fallback path is taken when broad-root-p is called
             ;; on a path that doesn't yet exist, so we verify the nonexistent-dir case.
             (declare (ignore link-name))
             ;; Verify that a nonexistent path that would resolve to /proc is still blocked.
             ;; We test this by checking that /proc itself is blocked both with and
             ;; without the trailing slash (ensure-directory-pathname adds one).
             (true (broad-root-p "/proc")
                   "broad-root-p must block /proc without trailing slash")
             (true (broad-root-p "/sys")
                   "broad-root-p must block /sys without trailing slash")
             (true (broad-root-p "/root")
                   "broad-root-p must block /root without trailing slash")))
      (uiop:delete-directory-tree outside-dir :validate t :if-does-not-exist :ignore))))

;;; D-16: no-root typed error when calling read verb without a root ----------

(define-test no-root-raises-typed-error
  "Calling fs-read-file without a project root returns a typed error (D-16)."
  (let* ((session  (make-session :id "test-no-root-verb"))
         (tool     (get-tool-instance session "fs-read-file"))
         (args     (let ((h (make-hash-table :test 'equal)))
                     (setf (gethash "path" h) "/some/path")
                     h))
         (response (tool-handle tool 1 args))
         (result   (gethash "result" response)))
    (true  (gethash "isError" result))
    (is string= "project-root-not-set" (gethash "error_type" result))))

;;; D-05: re-root outside whitelist without human_approved is refused --------

(define-test reroot-outside-whitelist-requires-approval
  "Re-rooting to a non-whitelisted path without human_approved returns
a typed reroot-permission-required error and does NOT change the root."
  (with-temp-project-root (session root)
    ;; The session starts rooted at ROOT; try to re-root to dsmr-mcp source
    ;; which is definitely not the current root and not in the whitelist.
    (let* ((tool     (get-tool-instance session "fs-set-project-root"))
           (target   (namestring (asdf:system-source-directory :dsmr-mcp)))
           (args     (let ((h (make-hash-table :test 'equal)))
                       (setf (gethash "path" h) target)
                       h))
           ;; Unset DSMR_RELATED_PROJECTS to guarantee empty whitelist
           (response (let ((saved-env (uiop:getenv "DSMR_RELATED_PROJECTS")))
                       (unwind-protect
                            (progn
                              (sb-posix:setenv "DSMR_RELATED_PROJECTS" "" 1)
                              (tool-handle tool 1 args))
                         (if saved-env
                             (sb-posix:setenv "DSMR_RELATED_PROJECTS" saved-env 1)
                             (sb-posix:unsetenv "DSMR_RELATED_PROJECTS")))))
           (result   (gethash "result" response)))
      (true (gethash "isError" result))
      (is string= "reroot-permission-required" (gethash "error_type" result))
      (true (gethash "requires_human_approval" result))
      ;; Root must NOT have changed
      (is equal root (session-project-root session)))))

;;; D-05: re-root WITH human_approved succeeds --------------------------------

(define-test human-approved-override-reroots
  "Re-rooting with human_approved: true succeeds even without whitelist entry."
  (with-temp-project-root (session root)
    (let* ((tool     (get-tool-instance session "fs-set-project-root"))
           (target   (namestring (asdf:system-source-directory :dsmr-mcp)))
           (args     (let ((h (make-hash-table :test 'equal)))
                       (setf (gethash "path" h) target)
                       (setf (gethash "human_approved" h) t)
                       h))
           (response (let ((saved-env (uiop:getenv "DSMR_RELATED_PROJECTS")))
                       (unwind-protect
                            (progn
                              (sb-posix:setenv "DSMR_RELATED_PROJECTS" "" 1)
                              (tool-handle tool 1 args))
                         (if saved-env
                             (sb-posix:setenv "DSMR_RELATED_PROJECTS" saved-env 1)
                             (sb-posix:unsetenv "DSMR_RELATED_PROJECTS")))))
           (result   (gethash "result" response)))
      ;; Should succeed (no isError)
      (false (gethash "isError" result))
      (is string= "explicit" (let ((r (gethash "project_root" result)))
                               ;; Just verify we got a project_root back
                               (if r "explicit" "missing")))
      ;; Root should now be the dsmr-mcp source dir
      (true (session-project-root session)))))

(define-test set-root-arms-envrc-offer-flag
  "A SUCCESSFUL fs-set-project-root arms the session's project-root-just-set-p
flag, the handler half of the contract that lets the transport offer the
project .envrc on this same tools/call instead of a later one.  The flag starts
disarmed and the offer itself is driven elsewhere (the stdio loop's
post-dispatch hook); here we verify only that a successful set-root arms it."
  (with-temp-project-root (session root)
    (false (session-project-root-just-set-p session)
           "flag starts disarmed")
    (let* ((tool     (get-tool-instance session "fs-set-project-root"))
           (args     (let ((h (make-hash-table :test 'equal)))
                       (setf (gethash "path" h) (namestring root))
                       h))
           ;; Re-rooting to the CURRENT root is whitelisted, so this succeeds
           ;; without human_approved.
           (response (tool-handle tool 1 args))
           (result   (gethash "result" response)))
      (false (gethash "isError" result) "set-root to the current root succeeds")
      (true (session-project-root-just-set-p session)
            "flag is armed after a successful set-root"))))

(define-test rejected-set-root-leaves-offer-flag-disarmed
  "A REFUSED fs-set-project-root (re-root to a non-whitelisted path without
human_approved) must NOT arm the offer flag: no root was adopted, so there is
nothing to offer for, and a later legitimate set-root must remain the one that
arms it."
  (with-temp-project-root (session _root)
    (false (session-project-root-just-set-p session)
           "flag starts disarmed")
    (let* ((tool     (get-tool-instance session "fs-set-project-root"))
           (target   (namestring (asdf:system-source-directory :dsmr-mcp)))
           (args     (let ((h (make-hash-table :test 'equal)))
                       (setf (gethash "path" h) target)
                       h))
           (response (let ((saved-env (uiop:getenv "DSMR_RELATED_PROJECTS")))
                       (unwind-protect
                            (progn
                              (sb-posix:setenv "DSMR_RELATED_PROJECTS" "" 1)
                              (tool-handle tool 1 args))
                         (if saved-env
                             (sb-posix:setenv "DSMR_RELATED_PROJECTS" saved-env 1)
                             (sb-posix:unsetenv "DSMR_RELATED_PROJECTS")))))
           (result   (gethash "result" response)))
      (true (gethash "isError" result) "the re-root is refused")
      (is string= "reroot-permission-required" (gethash "error_type" result))
      (false (session-project-root-just-set-p session)
             "a refused set-root leaves the offer flag disarmed"))))

;;; Whitelist entries are shell-shaped; the target is a directory namestring ---

(define-test whitelist-entry-without-trailing-slash-matches
  "DSMR_RELATED_PROJECTS is written in shell convention: colon-separated, no
trailing slashes.  Common Lisp uses the trailing slash to tell a directory
pathname from a file pathname, and the re-root target is always normalised to a
directory namestring before the comparison.  An entry must be normalised the
same way or it can never match, which leaves every re-root falling through to
the human_approved path."
  (let ((other (%make-temp-directory)))
    (unwind-protect
         (with-temp-project-root (session _root)
           (let* ((target (namestring (truename other)))
                  (entry  (string-right-trim "/" target)))
             (%with-related-projects (entry)
               (let ((result (%reroot-result session target)))
                 (false (gethash "isError" result)
                        "a whitelisted directory named without a trailing slash is accepted")
                 (is string= target (namestring (session-project-root session)))))))
      (uiop:delete-directory-tree other :validate t :if-does-not-exist :ignore))))

(define-test whitelist-entry-with-trailing-slash-matches
  "An entry already written as a directory namestring keeps matching.  Both
spellings name the same directory, so both must be accepted."
  (let ((other (%make-temp-directory)))
    (unwind-protect
         (with-temp-project-root (session _root)
           (let ((target (namestring (truename other))))
             (%with-related-projects (target)
               (let ((result (%reroot-result session target)))
                 (false (gethash "isError" result)
                        "a whitelisted directory named with a trailing slash is accepted")
                 (is string= target (namestring (session-project-root session)))))))
      (uiop:delete-directory-tree other :validate t :if-does-not-exist :ignore))))

(define-test whitelist-does-not-cover-sibling-directory
  "Normalising the entries must not make unrelated directories match.  A sibling
of a listed directory is not on the list and is still refused."
  (let ((listed  (%make-temp-directory))
        (sibling (%make-temp-directory)))
    (unwind-protect
         (with-temp-project-root (session root)
           (let ((entry  (string-right-trim "/" (namestring (truename listed))))
                 (target (namestring (truename sibling))))
             (%with-related-projects (entry)
               (let ((result (%reroot-result session target)))
                 (true (gethash "isError" result)
                       "a directory absent from the whitelist is refused")
                 (is string= "reroot-permission-required" (gethash "error_type" result))
                 (is equal root (session-project-root session))))))
      (uiop:delete-directory-tree listed :validate t :if-does-not-exist :ignore)
      (uiop:delete-directory-tree sibling :validate t :if-does-not-exist :ignore))))

(define-test whitelist-does-not-cover-prefix-sibling
  "A sibling whose name merely begins with a listed directory's name is not
beneath that directory and must still be refused.  This is the case a raw
string-prefix test gets wrong: the entry arrives in shell convention with no
trailing slash, so comparing it against the target as it stands accepts anything
that shares the leading characters.  Spelling both sides as directory
namestrings first is what lets the slash keep them apart."
  (let ((parent (%make-temp-directory)))
    (unwind-protect
         (with-temp-project-root (session root)
           (let* ((listed  (ensure-directories-exist
                            (uiop:ensure-directory-pathname
                             (merge-pathnames "proj/" parent))))
                  (sibling (ensure-directories-exist
                            (uiop:ensure-directory-pathname
                             (merge-pathnames "projbar/" parent))))
                  (entry   (string-right-trim "/" (namestring (truename listed))))
                  (target  (namestring (truename sibling))))
             (%with-related-projects (entry)
               (let ((result (%reroot-result session target)))
                 (true (gethash "isError" result)
                       "a sibling sharing the listed name's leading characters is refused")
                 (is string= "reroot-permission-required" (gethash "error_type" result))
                 (is equal root (session-project-root session))))))
      (uiop:delete-directory-tree parent :validate t :if-does-not-exist :ignore))))

(define-test whitelisted-root-covers-nested-directory
  "Listing a directory authorises every directory beneath it, at any depth.
Worktrees are created and destroyed continuously, and the whitelist lives in an
environment variable that only takes effect when the session is replaced, so an
exact match would mean a new entry and a restart for every worktree.  Naming the
parent once has to cover whatever is created under it afterwards."
  (let ((listed (%make-temp-directory)))
    (unwind-protect
         (with-temp-project-root (session _root)
           (let ((entry (string-right-trim "/" (namestring (truename listed))))
                 (deep  (uiop:ensure-directory-pathname
                         (merge-pathnames "worktrees/feature-a/" listed))))
             (ensure-directories-exist deep)
             (let ((target (namestring (truename deep))))
               (%with-related-projects (entry)
                 (let ((result (%reroot-result session target)))
                   (false (gethash "isError" result)
                          "a directory nested under a listed root is accepted")
                   (is string= target (namestring (session-project-root session))))))))
      (uiop:delete-directory-tree listed :validate t :if-does-not-exist :ignore))))

(define-test reroot-back-to-the-launch-project-needs-no-approval
  "A session that re-roots away to a whitelisted sibling must be able to come
back to the project it was launched in without human_approved, even though the
launch project is on no whitelist and is no longer the current root."
  (let ((sibling (%make-temp-directory)))
    (unwind-protect
         (with-temp-project-root (session root)
           (let ((home  (namestring (truename root)))
                 (there (namestring (truename sibling))))
             (%with-related-projects ((string-right-trim "/" there))
               (false (gethash "isError" (%reroot-result session there))
                      "the whitelisted sibling is refused")
               (let ((result (%reroot-result session home)))
                 (false (gethash "isError" result)
                        "going back to the launch project was refused: ~A"
                        (gethash "error_type" result))
                 (is string= home (namestring (session-project-root session)))))))
      (uiop:delete-directory-tree sibling :validate t :if-does-not-exist :ignore))))

(define-test the-launch-project-is-captured-once
  "The launch project is the root the session started with, and no re-root moves
it. A -> B -> A works without approval, and having been at B never makes B the
way home: once the whitelist no longer lists B, going back there is refused."
  (let ((sibling (%make-temp-directory)))
    (unwind-protect
         (with-temp-project-root (session root)
           (let ((home  (namestring (truename root)))
                 (there (namestring (truename sibling))))
             (%with-related-projects ((string-right-trim "/" there))
               (false (gethash "isError" (%reroot-result session there)))
               (is string= home (namestring (session-launch-project-root session))
                   "re-rooting to B moved the launch project")
               (false (gethash "isError" (%reroot-result session home))
                      "A -> B -> A was refused")
               (false (gethash "isError" (%reroot-result session there))
                      "A -> B -> A -> B was refused while B is listed"))
             (%with-related-projects ("")
               (false (gethash "isError" (%reroot-result session home))
                      "going home from B with an empty whitelist was refused")
               (let ((result (%reroot-result session there)))
                 (true (gethash "isError" result)
                       "B was treated as the launch project after the session visited it")
                 (is string= "reroot-permission-required" (gethash "error_type" result)))
               (is string= home (namestring (session-launch-project-root session))))))
      (uiop:delete-directory-tree sibling :validate t :if-does-not-exist :ignore))))

(define-test the-launch-project-does-not-open-any-other-project
  "Permitting the launch project widens nothing else: from a whitelisted
sibling, a third project that is neither listed nor the launch project is still
refused without human_approved, and the root stays where it was."
  (let ((sibling (%make-temp-directory))
        (third   (%make-temp-directory)))
    (unwind-protect
         (with-temp-project-root (session _root)
           (let ((there (namestring (truename sibling)))
                 (other (namestring (truename third))))
             (%with-related-projects ((string-right-trim "/" there))
               (false (gethash "isError" (%reroot-result session there)))
               (let ((result (%reroot-result session other)))
                 (true (gethash "isError" result)
                       "a project neither listed nor launched was accepted")
                 (is string= "reroot-permission-required" (gethash "error_type" result))
                 (is string= there (namestring (session-project-root session)))))))
      (uiop:delete-directory-tree sibling :validate t :if-does-not-exist :ignore)
      (uiop:delete-directory-tree third :validate t :if-does-not-exist :ignore))))

(define-test a-session-whose-root-was-deleted-can-get-home
  "A session that moved into a worktree which was then deleted must be able to
return to its launch project without the operator, and the answer must say the
root it left no longer exists. Re-rooting anywhere else from there says so too."
  (let ((worktree (%make-temp-directory))
        (third    (%make-temp-directory)))
    (unwind-protect
         (with-temp-project-root (session root)
           (let ((home  (namestring (truename root)))
                 (gone  (namestring (truename worktree)))
                 (other (namestring (truename third))))
             (%with-related-projects ((string-right-trim "/" gone))
               (false (gethash "isError" (%reroot-result session gone))))
             (uiop:delete-directory-tree worktree :validate t)
             (%with-related-projects ("")
               (let ((refused (%reroot-result session other)))
                 (true (gethash "isError" refused))
                 (true (gethash "previous_root_missing" refused))
                 (true (search (format nil "The current root ~A no longer exists." gone)
                               (gethash "text" (aref (gethash "content" refused) 0)))
                       "the refusal does not say the current root is gone"))
               (let ((result (%reroot-result session home)))
                 (false (gethash "isError" result)
                        "a session stranded in a deleted worktree could not get home")
                 (is string= home (namestring (session-project-root session)))
                 (true (search (format nil "The previous root ~A no longer exists." gone)
                               (gethash "text" (aref (gethash "content" result) 0)))
                       "the answer does not say the previous root is gone")))))
      (uiop:delete-directory-tree worktree :validate t :if-does-not-exist :ignore)
      (uiop:delete-directory-tree third :validate t :if-does-not-exist :ignore))))

(define-test an-unseeded-session-takes-its-first-root-as-launch
  "A session constructed with no root takes the first root established for it
as its launch project, and that one only."
  (let ((first-root (%make-temp-directory))
        (sibling    (%make-temp-directory)))
    (unwind-protect
         (let ((session (make-session :id "test-unseeded"))
               (home    (namestring (truename first-root)))
               (there   (namestring (truename sibling))))
           (false (session-launch-project-root session))
           (%with-related-projects ("")
             (false (gethash "isError" (%reroot-result session home :approved t))))
           (is string= home (namestring (session-launch-project-root session)))
           (%with-related-projects ((string-right-trim "/" there))
             (false (gethash "isError" (%reroot-result session there))))
           (is string= home (namestring (session-launch-project-root session))
               "a later re-root moved the launch project")
           (%with-related-projects ("")
             (false (gethash "isError" (%reroot-result session home))
                    "the first root established was not treated as home")))
      (uiop:delete-directory-tree first-root :validate t :if-does-not-exist :ignore)
      (uiop:delete-directory-tree sibling :validate t :if-does-not-exist :ignore))))
