;;;; tests/integration/release/seal-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Child-process tests of the release seal and of the start-up refusal of an
;;;; unsealed release image.
;;;;
;;;; Each seal probe runs in a fresh SBCL started with --no-userinit and this
;;;; process's environment, so CL_SOURCE_REGISTRY names the same checkout. The
;;;; child loads dsmr-mcp/src/release, makes a probe system reachable through
;;;; the central registry, and prints one `@@ LABEL VALUE` line per probe. The
;;;; unsealed control runs the same probes without the seal and must still find
;;;; the probe system, which is what shows the sealed assertions can fail.

(defpackage #:dsmr-mcp/tests/integration/release/seal-test
  (:use #:cl #:zebra)
  (:import-from #:dsmr-mcp/tests/integration/support
                #:sbcl-path
                #:launch-server-child
                #:with-server-child-state-home))

(in-package #:dsmr-mcp/tests/integration/release/seal-test)

(defparameter *probe-system* "dsmr-seal-probe"
  "Name of the system planted outside every configured tree.")

(defparameter *child-timeout* 180
  "Seconds a child SBCL may run before it is killed.")

(defun %temporary-directory ()
  "Create a fresh directory under the temporary directory and return it as a
directory pathname."
  (uiop:ensure-directory-pathname
   (string-trim '(#\Newline #\Return #\Space)
                (uiop:run-program (list "mktemp" "-d"
                                        (namestring
                                         (merge-pathnames "dsmr-seal.XXXXXXXX"
                                                          (uiop:temporary-directory))))
                                  :output :string))))

(defun %plant-probe-system (directory)
  "Write a component-free definition of *PROBE-SYSTEM* into DIRECTORY."
  (with-open-file (out (merge-pathnames (concatenate 'string *probe-system* ".asd")
                                        directory)
                       :direction :output :if-exists :supersede)
    (format out "(asdf:defsystem ~S)~%" *probe-system*)))

(defun %probe-forms (sealp)
  "The probe form a child evaluates after loading dsmr-mcp/src/release. With
SEALP the child seals its registry between the first probe and the rest."
  (format nil "(flet ((probe (label thunk)
           (format t \"~~&@@ ~~A ~~S~~%\" label
                   (handler-case (funcall thunk)
                     (error (e)
                       (list :error (string (type-of e))
                             (typep e 'asdf/find-component:missing-component)))))))
  (probe \"source\" (lambda () (namestring (truename (asdf:system-source-directory \"dsmr-mcp\")))))
  (probe \"located-before\" (lambda () (and (nth-value 2 (asdf:locate-system ~S)) t)))
  ~:[~;(dsmr-mcp/src/release:seal-source-registry)~]
  (probe \"sealed-p\" (lambda () (and (dsmr-mcp/src/release:sealed-p) t)))
  (probe \"find\" (lambda () (and (asdf:find-system ~S nil) t)))
  (probe \"load\" (lambda () (asdf:load-system ~S) :loaded))
  (asdf:clear-source-registry)
  (probe \"sealed-p-after-clear\" (lambda () (and (dsmr-mcp/src/release:sealed-p) t)))
  (probe \"find-after-clear\" (lambda () (and (asdf:find-system ~S nil) t)))
  (probe \"load-loaded\" (lambda () (asdf:load-system \"dsmr-mcp/src/release\") :loaded))
  (probe \"require-contrib\" (lambda () (require :sb-md5) (and (find-package :sb-md5) t)))
  (finish-output))"
          *probe-system* sealp *probe-system* *probe-system* *probe-system*))

(defun %parse-probe-lines (text)
  "Return an alist of (LABEL . VALUE) from the `@@ LABEL VALUE` lines in TEXT."
  (let ((result '()))
    (with-input-from-string (in text)
      (loop for line = (read-line in nil)
            while line
            when (uiop:string-prefix-p "@@ " line)
              do (let* ((rest (subseq line 3))
                        (space (position #\Space rest)))
                   (when space
                     (push (cons (subseq rest 0 space)
                                 (ignore-errors
                                  (let ((*read-eval* nil)
                                        (*package* (find-package '#:cl-user)))
                                    (read-from-string rest t nil :start (1+ space)))))
                           result)))))
    (nreverse result)))

(defun run-seal-child (sealp)
  "Run the probe child, sealed when SEALP, and return (values PROBES OUTPUT):
PROBES is the alist of probe results, OUTPUT the child's stdout and stderr."
  (let ((directory (%temporary-directory))
        (proc nil))
    (unwind-protect
         (progn
           (%plant-probe-system directory)
           (let ((stdout (merge-pathnames "stdout" directory))
                 (stderr (merge-pathnames "stderr" directory)))
             (setf proc (uiop:launch-program
                         (list (sbcl-path) "--noinform" "--non-interactive" "--no-userinit"
                               "--eval" "(require :asdf)"
                               "--eval" (format nil "(push ~S asdf:*central-registry*)"
                                                (namestring directory))
                               "--eval" "(let ((*standard-output* *error-output*)) (asdf:load-system \"dsmr-mcp/src/release\"))"
                               "--eval" (%probe-forms sealp))
                         :output stdout :error-output stderr))
             (loop repeat (ceiling *child-timeout* 0.25)
                   while (uiop:process-alive-p proc)
                   do (sleep 0.25))
             (when (uiop:process-alive-p proc)
               (ignore-errors (uiop:terminate-process proc :urgent t)))
             (ignore-errors (uiop:wait-process proc))
             (let ((out (or (ignore-errors (uiop:read-file-string stdout)) ""))
                   (err (or (ignore-errors (uiop:read-file-string stderr)) "")))
               (values (%parse-probe-lines out)
                       (concatenate 'string out err)))))
      (when (and proc (uiop:process-alive-p proc))
        (ignore-errors (uiop:terminate-process proc :urgent t)))
      (ignore-errors (uiop:delete-directory-tree directory :validate t)))))

(defun probe-value (probes label)
  "The value the child printed for LABEL, or :ABSENT when it printed none."
  (let ((entry (assoc label probes :test #'string=)))
    (if entry (cdr entry) :absent)))

(defun %tail (string)
  "The last 2000 characters of STRING."
  (subseq string (max 0 (- (length string) 2000))))

(defun this-checkout ()
  "The truename namestring of the directory dsmr-mcp resolves to in this image."
  (namestring (truename (asdf:system-source-directory "dsmr-mcp"))))

(define-test a-sealed-image-cannot-find-an-unloaded-system
  "After the seal the probe system, found before it, is not found, its load
signals MISSING-COMPONENT, and SEALED-P is true."
  (multiple-value-bind (probes output) (run-seal-child t)
    (is string= (this-checkout) (probe-value probes "source")
        "the child printed no source line or loaded dsmr-mcp from another checkout; output:~%~A" (%tail output))
    (true (eq t (probe-value probes "located-before"))
          "the probe system was not reachable before the seal; check the planted .asd; output:~%~A"
          (%tail output))
    (true (eq t (probe-value probes "sealed-p"))
          "SEALED-P is not T after SEAL-SOURCE-REGISTRY; output:~%~A" (%tail output))
    (true (null (probe-value probes "find"))
          "a sealed image found the unloaded probe system; output:~%~A" (%tail output))
    (let ((load (probe-value probes "load")))
      (true (and (consp load) (eq :error (first load)) (eq t (third load)))
            "loading an unloaded system under the seal gave ~S, not MISSING-COMPONENT" load))))

(define-test clearing-the-source-registry-does-not-unseal
  "ASDF:CLEAR-SOURCE-REGISTRY leaves the seal in place."
  (multiple-value-bind (probes output) (run-seal-child t)
    (true (eq t (probe-value probes "sealed-p-after-clear"))
          "SEALED-P is not T after CLEAR-SOURCE-REGISTRY; output:~%~A" (%tail output))
    (true (null (probe-value probes "find-after-clear"))
          "the probe system was found after CLEAR-SOURCE-REGISTRY; output:~%~A" (%tail output))))

(define-test a-loaded-system-and-a-contrib-still-load-under-the-seal
  "LOAD-SYSTEM of a loaded system returns normally and REQUIRE of an SBCL
contrib succeeds under the seal."
  (multiple-value-bind (probes output) (run-seal-child t)
    (true (eq :loaded (probe-value probes "load-loaded"))
          "LOAD-SYSTEM of a loaded system under the seal gave ~S; output:~%~A"
          (probe-value probes "load-loaded") (%tail output))
    (true (eq t (probe-value probes "require-contrib"))
          "REQUIRE :SB-MD5 under the seal gave ~S; output:~%~A"
          (probe-value probes "require-contrib") (%tail output))))

(define-test an-unsealed-image-still-finds-the-probe
  "Without the seal the same child finds and loads the probe system and
SEALED-P is false."
  (multiple-value-bind (probes output) (run-seal-child nil)
    (is string= (this-checkout) (probe-value probes "source")
        "the child printed no source line or loaded dsmr-mcp from another checkout; output:~%~A" (%tail output))
    (true (null (probe-value probes "sealed-p"))
          "SEALED-P is not NIL in an unsealed image; output:~%~A" (%tail output))
    (true (eq t (probe-value probes "find"))
          "an unsealed image did not find the probe system; output:~%~A" (%tail output))
    (true (eq :loaded (probe-value probes "load"))
          "an unsealed image did not load the probe system; output:~%~A" (%tail output))))

(defun %drain (stream)
  "Read STREAM to end of file and return the text, or an empty string."
  (or (ignore-errors
       (with-output-to-string (out)
         (loop for line = (read-line stream nil)
               while line
               do (write-line line out))))
      ""))

(define-test an-unsealed-release-server-exits-78
  "A server booted from an unsealed core with DSMR_RELEASE_ROOT set exits 78
and logs run.release.unsealed."
  (let ((core (uiop:getenv "DSMR_BROKER_CORE")))
    (if (not (and core (plusp (length core)) (probe-file core)))
        (skip "DSMR_BROKER_CORE names no core file; run under make test-integration or set it to the test core")
        (with-server-child-state-home (state)
          (let* ((release (ensure-directories-exist (merge-pathnames "release/" state)))
                 (proc (launch-server-child
                        (list (sbcl-path) "--core" core "--noinform" "--disable-debugger"
                              "--no-sysinit" "--no-userinit" "--non-interactive"
                              "--eval" "(dsmr-mcp:run :transport :stdio)")
                        state
                        :assignments (list (concatenate 'string "DSMR_RELEASE_ROOT="
                                                        (namestring release))))))
            (ignore-errors (close (uiop:process-info-input proc)))
            (loop repeat (ceiling *child-timeout* 0.25)
                  while (uiop:process-alive-p proc)
                  do (sleep 0.25))
            (when (uiop:process-alive-p proc)
              (ignore-errors (uiop:terminate-process proc :urgent t)))
            (let ((status (ignore-errors (uiop:wait-process proc)))
                  (stderr (%drain (uiop:process-info-error-output proc))))
              (ignore-errors (%drain (uiop:process-info-output proc)))
              (is eql 78 status
                  "an unsealed release server exited ~S, not 78; stderr:~%~A"
                  status (%tail stderr))
              (true (search "run.release.unsealed" stderr)
                    "stderr does not name run.release.unsealed; stderr:~%~A"
                    (%tail stderr))))))))
