;;;; src/project-gate-scan.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Discovering the sites a quality gate would fire on in a repository that is
;;;; about to get one.
;;;;
;;;; The baseline this feeds is a record of a particular tree at a particular
;;;; moment, so the sites in it have to come from that tree. A template listing
;;;; sites someone expected to find would describe no repository at all while
;;;; reading exactly like one that had been examined.
;;;;
;;;; Two properties are the reason this module exists rather than each caller
;;;; shelling out for itself.
;;;;
;;;; 1. An absent linter is reported, never returned as an absence of findings.
;;;;    A baseline asserting zero sites and a baseline nobody managed to populate
;;;;    are indistinguishable once written, and the written one gets believed.
;;;;    So the first thing here is a check, and its failure is a signal.
;;;;
;;;; 2. A non-zero exit is the ordinary case, not a failure. The linter exits
;;;;    non-zero precisely when it found something, which is what we came for.
;;;;    Only output that will not parse is a failure, and that one signals with
;;;;    the exit code and a bounded piece of what was written.
;;;;
;;;; The linter is invoked by absolute path. A binary of the same name earlier on
;;;; PATH belongs to an unrelated toolkit, and reaching it would either fail
;;;; confusingly or appear to succeed having examined nothing.
;;;;
;;;; Every site this returns is categorised as examined-and-frozen, and its
;;;; callee knowability is left explicitly undetermined. Neither is a hedge: a
;;;; linter running one rule over one file cannot tell that a site is correct as
;;;; written or demonstrably defective, and callee knowability is a property of
;;;; condition-handling sites that no rule here measures. Recording that the site
;;;; existed and was not examined for those things is the whole of what was
;;;; learned.

(defpackage #:dsmr-mcp/src/project-gate-scan
  (:use #:cl)
  (:local-nicknames (#:jzon #:com.inuoe.jzon))
  (:export #:*linter-path*
           #:linter-path
           #:gate-scanner-available-p
           #:collect-debt-sites
           #:gate-scanner-unavailable-error
           #:gate-scanner-unavailable-path
           #:gate-scan-failed-error
           #:gate-scan-failed-argv
           #:gate-scan-failed-exit-code
           #:gate-scan-failed-output))

(in-package #:dsmr-mcp/src/project-gate-scan)

;;; ---------------------------------------------------------------------------
;;; Conditions
;;; ---------------------------------------------------------------------------

(define-condition gate-scanner-unavailable-error (error)
  ((path :initarg :path :reader gate-scanner-unavailable-path))
  (:documentation
   "Signaled when the linter is not present where the scanner expects it.

This is the condition that keeps \"nobody could look\" from being recorded as
\"there was nothing to find\". A caller that wants to proceed anyway handles it
and records the debt as not enumerated; nothing here decides that for it.")
  (:report
   (lambda (condition stream)
     (format stream "No quality-gate scanner at ~A. Debt was not enumerated."
             (gate-scanner-unavailable-path condition)))))

(setf (documentation 'gate-scanner-unavailable-path 'function)
      "Return the path the scanner was looked for at and not found.")

(define-condition gate-scan-failed-error (error)
  ((argv      :initarg :argv      :reader gate-scan-failed-argv)
   (exit-code :initarg :exit-code :reader gate-scan-failed-exit-code)
   (output    :initarg :output    :reader gate-scan-failed-output))
  (:documentation
   "Signaled when the scanner ran but produced output that will not parse.

Distinct from a non-zero exit, which is what the linter does whenever it finds
anything and is the case this module exists to handle. Carries the argument
vector, the exit code, and a bounded prefix of what was written, so a report can
say what was run without a caller reconstructing it.")
  (:report
   (lambda (condition stream)
     (format stream "Quality-gate scan ~S exited ~A and its output did not parse: ~A"
             (gate-scan-failed-argv condition)
             (gate-scan-failed-exit-code condition)
             (gate-scan-failed-output condition)))))

(setf (documentation 'gate-scan-failed-argv 'function)
      "Return the full argument vector of the scan that failed.")
(setf (documentation 'gate-scan-failed-exit-code 'function)
      "Return the exit code of the scan whose output did not parse.")
(setf (documentation 'gate-scan-failed-output 'function)
      "Return a bounded prefix of what the failing scan wrote.")

;;; ---------------------------------------------------------------------------
;;; Where the linter is
;;; ---------------------------------------------------------------------------

(defvar *linter-path*
  (merge-pathnames ".local/share/mallet/mallet" (user-homedir-pathname))
  "Absolute path to the Lisp linter the quality gate is built around.

Absolute rather than a bare command name on purpose. A binary of the same name
earlier on PATH belongs to an unrelated toolkit that happens to share the word,
and running it would either fail in a way nobody could read or appear to succeed
having examined nothing at all.")

(defvar +output-prefix-limit+ 400
  "How much of a failing scan's output is carried in the condition.

Bounded because the thing that failed to parse may be arbitrarily large, and a
condition report is read by a person. Named as a constant, defined with DEFVAR,
so a reload does not break a warm image.")

(defun linter-path ()
  "Return the path the linter is invoked at.

Reads DSMR_LINTER at call time, so a test or a developer with the linter
installed elsewhere can point at it without editing anything."
  (let ((override (uiop:getenv "DSMR_LINTER")))
    (if (and override (plusp (length (string-trim '(#\Space #\Tab) override))))
        (pathname (string-trim '(#\Space #\Tab) override))
        *linter-path*)))

(defun gate-scanner-available-p (&optional (path (linter-path)))
  "Return true when a linter is present at PATH.

Presence only. Whether it runs is answered by running it, and a linter that is
present and broken produces a scan failure rather than an absence of findings."
  (and (probe-file path) t))

;;; ---------------------------------------------------------------------------
;;; Enumerating what to scan
;;; ---------------------------------------------------------------------------

(defun %git-directory-p (directory)
  "Return true when DIRECTORY is a repository's .git directory."
  (let ((last (car (last (pathname-directory directory)))))
    (and (stringp last) (string= last ".git"))))

(defun %lisp-files-under (root)
  "Return every .lisp file under ROOT, sorted, skipping the git directory.

The git directory is skipped rather than filtered afterwards: a repository's
object store holds no Lisp source, and walking it on a large repository costs
more than the whole scan."
  (let ((found '()))
    (uiop:collect-sub*directories
     (uiop:ensure-directory-pathname root)
     (lambda (directory) (not (%git-directory-p directory)))
     (lambda (directory) (not (%git-directory-p directory)))
     (lambda (directory)
       (dolist (file (uiop:directory-files directory "*.lisp"))
         (push file found))))
    (sort found #'string< :key #'namestring)))

(defun %chunks (list size)
  "Return LIST split into consecutive sublists of at most SIZE elements.

The argument list handed to a subprocess has a length limit, and a repository
large enough to exceed it would otherwise be scanned in part with no sign that
the rest was skipped."
  (loop with remaining = list
        while remaining
        collect (subseq remaining 0 (min size (length remaining)))
        do (setf remaining (nthcdr size remaining))))

;;; ---------------------------------------------------------------------------
;;; Running the linter and reading what it said
;;; ---------------------------------------------------------------------------

(defun %scan-argv (linter config chunk)
  "Return the argument vector for one scan of CHUNK.

Built as a list. Nothing reaches a shell, so a path carrying a space, a quote or
a semicolon is a path and cannot become syntax."
  (append (list (namestring linter) "--format" "json" "--no-color")
          (when config (list "--config" (namestring config)))
          (mapcar #'namestring chunk)))

(defun %bounded (string)
  "Return at most +OUTPUT-PREFIX-LIMIT+ characters of STRING."
  (let ((text (or string "")))
    (subseq text 0 (min (length text) +output-prefix-limit+))))

(defun %parse-scan-output (stdout argv exit-code)
  "Return the parsed linter report, or signal GATE-SCAN-FAILED-ERROR.

A report that will not parse is the one genuine failure here. Everything else,
including a non-zero exit, is the linter answering the question it was asked."
  (handler-case (jzon:parse (or stdout ""))
    (error ()
      (error 'gate-scan-failed-error
             :argv argv
             :exit-code exit-code
             :output (%bounded stdout)))))

(defun %json-field (object key)
  "Return OBJECT's KEY, or NIL when the object does not carry it."
  (and (hash-table-p object) (gethash key object)))

(defun %relative-to (path root)
  "Return PATH as it reads from ROOT, or its whole namestring when it is outside.

The linter echoes back whatever paths it was handed, and it is handed absolute
ones. A baseline naming absolute paths on the machine that generated it stops
being readable the moment the repository is cloned somewhere else."
  (let* ((absolute        (merge-pathnames (or path "")
                                           (uiop:ensure-directory-pathname root)))
         (root-string     (namestring (uiop:ensure-directory-pathname root)))
         (absolute-string (namestring absolute)))
    (if (and (>= (length absolute-string) (length root-string))
             (string= root-string absolute-string :end2 (length root-string)))
        (subseq absolute-string (length root-string))
        absolute-string)))

(defun %site-from-violation (file violation)
  "Return the site plist FILE's VIOLATION describes.

The category is fixed at :FROZEN-WITH-DIAGNOSIS and callee knowability at
:NOT-DETERMINED for every site, because those are the only honest answers a
linter can give. The linter's own rule category is carried through separately,
under a name that cannot be mistaken for the debt category."
  (list :file             file
        :line             (%json-field violation "line")
        :column           (%json-field violation "column")
        :rule             (%json-field violation "rule")
        :severity         (%json-field violation "severity")
        :message          (%json-field violation "message")
        :rule-category    (%json-field violation "category")
        :callee-knowable  :not-determined
        :category         :frozen-with-diagnosis
        :note             nil))

(defun %sites-from-report (report root)
  "Return every site the parsed REPORT describes, with paths relative to ROOT."
  (let ((sites '()))
    (when (or (vectorp report) (listp report))
      (map nil
           (lambda (entry)
             (let ((file       (%relative-to (%json-field entry "file") root))
                   (violations (%json-field entry "violations")))
               (when violations
                 (map nil
                      (lambda (violation)
                        (push (%site-from-violation file violation) sites))
                      violations))))
           report))
    (nreverse sites)))

(defun collect-debt-sites (root &key (config (merge-pathnames
                                              ".mallet.lisp"
                                              (uiop:ensure-directory-pathname root)))
                                     files)
  "Return the sites the quality gate would report across the repository at ROOT.

FILES, when given, is the exact set to scan; otherwise every .lisp file under
ROOT outside its git directory. CONFIG is used when it names an existing file,
so a repository with no linter configuration is scanned against the linter's own
defaults rather than refused.

Signals GATE-SCANNER-UNAVAILABLE-ERROR when no linter is installed, before any
subprocess is started. It does not return NIL in that case: NIL is the answer
for a repository that was scanned and found clean, and the two must never be
written down the same way.

Signals GATE-SCAN-FAILED-ERROR when the linter's output will not parse. A
non-zero exit on its own is not a failure: the linter exits non-zero whenever it
found something, which is the case this function exists to serve."
  (let ((linter (linter-path))
        (root   (uiop:ensure-directory-pathname root)))
    (unless (gate-scanner-available-p linter)
      (error 'gate-scanner-unavailable-error :path linter))
    (let* ((config  (and config (probe-file config)))
           (targets (or files (%lisp-files-under root)))
           (sites   '()))
      (dolist (chunk (%chunks targets 200) (nreverse sites))
        (let ((argv (%scan-argv linter config chunk)))
          (multiple-value-bind (stdout stderr exit-code)
              (uiop:run-program argv
                                :output :string
                                :error-output :string
                                :ignore-error-status t)
            (declare (ignore stderr))
            (dolist (site (%sites-from-report
                           (%parse-scan-output stdout argv exit-code)
                           root))
              (push site sites))))))))
