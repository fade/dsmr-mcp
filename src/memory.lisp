;;;; src/memory.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Finding and reading Claude Code memory pages: which store belongs to a
;;;; session, which files in a store may be read, and what a page's
;;;; frontmatter says about its status.

(defpackage #:dsmr-mcp/src/memory
  (:use #:cl)
  (:import-from #:cl-ppcre
                #:split)
  (:import-from #:dsmr-mcp/src/log
                #:log-event)
  (:export #:*claude-config-dir*
           #:claude-config-dir
           #:projects-directory
           #:store-name-for
           #:repository-root
           #:project-store-directory
           #:memory-page-path
           #:list-store-pages))

(in-package #:dsmr-mcp/src/memory)

;;; ---------------------------------------------------------------------------
;;; Where the stores live
;;; ---------------------------------------------------------------------------

(defvar *claude-config-dir* nil
  "When non-NIL, the Claude config directory to use instead of the
environment. Tests bind it to a fixture so the real config is never read.")

(defun %safe-truename (path)
  "The truename of PATH, or NIL when it does not exist or cannot be resolved."
  (and path (ignore-errors (truename path))))

(defun claude-config-dir ()
  "The Claude config directory as a directory pathname: *CLAUDE-CONFIG-DIR*
when bound, else a non-empty $CLAUDE_CONFIG_DIR, else ~/.claude/. The harness
honours the same variable, so a relocated config is followed here too."
  (let ((env (uiop:getenv "CLAUDE_CONFIG_DIR")))
    (cond (*claude-config-dir*
           (uiop:ensure-directory-pathname *claude-config-dir*))
          ((and env (plusp (length env)))
           (uiop:ensure-directory-pathname (uiop:parse-native-namestring env)))
          (t (merge-pathnames ".claude/" (user-homedir-pathname))))))

(defun projects-directory ()
  "The truename of <config>/projects/, or NIL when it does not exist."
  (let ((dir (%safe-truename (merge-pathnames "projects/" (claude-config-dir)))))
    (and dir (uiop:directory-exists-p dir) dir)))

;;; ---------------------------------------------------------------------------
;;; Store naming and the repository root
;;; ---------------------------------------------------------------------------

(defun %ascii-alnum-p (char)
  "True for ASCII letters and digits only. The standard alphanumeric
predicate accepts non-ASCII letters too, and the harness maps those to a
hyphen, so it would derive the wrong store name."
  (let ((code (char-code char)))
    (or (<= 48 code 57) (<= 65 code 90) (<= 97 code 122))))

(defun store-name-for (directory)
  "The store name the harness derives for DIRECTORY: its native path with the
trailing slash removed and every character outside ASCII letters and digits
replaced by a hyphen."
  (let* ((native (uiop:native-namestring (uiop:ensure-directory-pathname directory)))
         (trimmed (if (and (> (length native) 1)
                           (char= #\/ (char native (1- (length native)))))
                      (subseq native 0 (1- (length native)))
                      native)))
    (map 'string (lambda (c) (if (%ascii-alnum-p c) c #\-)) trimmed)))

(defun %git-marker-p (dir)
  "True when DIR holds a .git entry, either a directory or a file."
  (ignore-errors
   (or (uiop:directory-exists-p (merge-pathnames ".git/" dir))
       (probe-file (merge-pathnames ".git" dir)))))

(defun %first-line (file)
  "The first line of FILE, trimmed of surrounding whitespace, or NIL."
  (ignore-errors
   (with-open-file (in file :external-format '(:utf-8 :replacement #\?))
     (let ((line (read-line in nil nil)))
       (and line (string-trim '(#\Space #\Tab #\Return #\Newline) line))))))

(defun %resolve-dir-text (text base)
  "Resolve the directory named by TEXT, taken relative to BASE when it is not
absolute. Returns a truename, or NIL when it does not exist."
  (when (and text (plusp (length text)))
    (let ((pn (uiop:ensure-directory-pathname (uiop:parse-native-namestring text))))
      (%safe-truename (if (uiop:absolute-pathname-p pn)
                          pn
                          (uiop:merge-pathnames* pn base))))))

(defun %root-from-marker (dir)
  "The repository root for DIR, which holds a .git entry. A .git directory
makes DIR the root. A .git file names the real git directory; when that
directory carries a commondir file (a linked worktree), the common directory
it names is the main checkout's .git, and its parent is the root. Anything
that cannot be followed leaves DIR as the root."
  (if (uiop:directory-exists-p (merge-pathnames ".git/" dir))
      dir
      (let* ((line (%first-line (merge-pathnames ".git" dir)))
             (gitdir (and line
                          (> (length line) 7)
                          (string-equal "gitdir:" line :end2 7)
                          (%resolve-dir-text (string-trim " " (subseq line 7)) dir)))
             (common (and gitdir
                          (%resolve-dir-text
                           (%first-line (merge-pathnames "commondir" gitdir))
                           gitdir))))
        (if (and common
                 (equal ".git" (car (last (pathname-directory common)))))
            (uiop:pathname-parent-directory-pathname common)
            dir))))

(defun repository-root (directory)
  "The root of the git repository holding DIRECTORY, found by walking up to
the first directory with a .git entry. A linked worktree maps back to its main
checkout, so every worktree of a repository shares one store. DIRECTORY itself
is returned when no .git exists above it. Reads files only, runs no git
process, and never signals."
  (let* ((start (uiop:ensure-directory-pathname directory))
         (start (or (%safe-truename start) start))
         (components (pathname-directory start)))
    (or (ignore-errors
         (loop for n from (length components) downto 1
               for dir = (make-pathname :directory (subseq components 0 n)
                                        :name nil :type nil :version nil
                                        :defaults start)
               when (%git-marker-p dir)
                 return (%root-from-marker dir)))
        start)))

(defun project-store-directory (session-root)
  "The memory store directory for SESSION-ROOT, whether or not it exists:
<config>/projects/<store name of the repository root>/memory/. Nothing is
cached, because the config dir and the stores can change during a session."
  (let* ((dir (uiop:ensure-directory-pathname session-root))
         (root (repository-root (or (%safe-truename dir) dir))))
    (merge-pathnames (make-pathname :directory (list :relative "projects"
                                                     (store-name-for root)
                                                     "memory"))
                     (claude-config-dir))))

;;; ---------------------------------------------------------------------------
;;; Read confinement
;;; ---------------------------------------------------------------------------

(defun memory-page-path (file projects-dir)
  "The resolved pathname of FILE when it is a memory page, else NIL.
A memory page is a regular file of type exactly md sitting directly inside
<store>/memory/ under PROJECTS-DIR. Both paths are resolved before the
containment test, so a symlink inside a store cannot reach a file outside the
projects directory. This check is separate from the general read allow-list on
purpose: memory stores are readable here and nowhere else."
  (let ((resolved (%safe-truename file))
        (root (and projects-dir
                   (%safe-truename (uiop:ensure-directory-pathname projects-dir)))))
    (when (and resolved root
               (pathname-name resolved)
               (not (ignore-errors (uiop:directory-exists-p resolved)))
               (equal "md" (pathname-type resolved))
               (uiop:subpathp resolved root))
      (let ((below (nthcdr (length (pathname-directory root))
                           (pathname-directory resolved))))
        (when (and (= 2 (length below))
                   (equal "memory" (second below)))
          resolved)))))

(defun list-store-pages (store-dir projects-dir)
  "List the readable pages directly inside STORE-DIR. Returns three values:
the resolved page pathnames sorted by filename; an alist from skip reason to
count, the reasons being :INDEX (MEMORY.md, which the harness already loads
every session), :NOT-MARKDOWN (type not exactly md, such as a .md.bak copy)
and :OUTSIDE-STORE (refused by MEMORY-PAGE-PATH); and the number of
subdirectories left unsearched. Stores are flat, so the listing does not
recurse. A missing store yields no pages."
  (let ((dir (%safe-truename (uiop:ensure-directory-pathname store-dir)))
        (pages '())
        (skipped '()))
    (flet ((skip (reason)
             (let ((cell (assoc reason skipped)))
               (if cell
                   (incf (cdr cell))
                   (push (cons reason 1) skipped)))))
      (unless dir
        (return-from list-store-pages (values '() '() 0)))
      (dolist (file (ignore-errors (uiop:directory-files dir)))
        (cond ((and (equal "MEMORY" (pathname-name file))
                    (equal "md" (pathname-type file)))
               (skip :index))
              ((not (equal "md" (pathname-type file)))
               (skip :not-markdown))
              (t
               (let ((page (memory-page-path file projects-dir)))
                 (if page
                     (push (cons (file-namestring file) page) pages)
                     (skip :outside-store))))))
      (values (mapcar #'cdr (sort pages #'string< :key #'car))
              (nreverse skipped)
              (length (ignore-errors (uiop:subdirectories dir)))))))
