;;;; tests/bus/broker-image-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; How a detached broker is launched, and what it can say afterwards about the
;;;; image it launched from.
;;;;
;;;; Both branches of the launch are driven here rather than whichever one this
;;;; checkout happens to support. A test that only ever sees the branch taken on
;;;; the developer's machine passes on the machine where the other branch is the
;;;; one that runs, and says nothing about it.
;;;;
;;;; The provenance is measured from the running process rather than passed in,
;;;; so these tests take it the same way a broker does and check the record that
;;;; comes out, not the value that went in.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/bus/broker-image-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/bus/broker-image-test
  (:use #:cl #:zebra)
  (:local-nicknames (#:broker #:dsmr-mcp/src/bus/broker)
                    (#:status #:dsmr-mcp/src/bus/status)))

(in-package #:dsmr-mcp/tests/bus/broker-image-test)

;;; ------------------------------------------------------------------ fixture

(defmacro with-scratch-bus ((paths) &body body)
  "Bind PATHS to a bus of this test's own making, removed entirely afterwards.

   Under the cache directory rather than the temporary directory because a bus
   binds unix sockets under its root and that address has a hard length limit;
   a deep temporary path overflows it and the failure names zeromq rather than
   the path."
  (let ((root (gensym "ROOT")))
    `(let* ((,root (merge-pathnames
                    (format nil "broker-image-probe-~D-~D/"
                            (sb-posix:getpid) (random 100000000))
                    (merge-pathnames "dsmr-mcp/" (uiop:xdg-cache-home))))
            (,paths (broker:make-bus-paths ,root)))
       (ensure-directories-exist ,root)
       (broker:ensure-bus-dirs ,paths)
       (unwind-protect (progn ,@body)
         (ignore-errors (uiop:delete-directory-tree
                         ,root :validate t :if-does-not-exist :ignore))))))

(defmacro with-image-path ((value) &body body)
  "Run BODY with the prebuilt-image probe answering VALUE.

   Stubbed so both launch branches are exercised wherever this runs. Deciding
   the branch from whatever is on disk would leave one of them untested on every
   machine, and untested in different halves on different machines."
  (let ((real (gensym "REAL")))
    `(let ((,real (fdefinition 'broker::%prebuilt-image-path)))
       (unwind-protect
            (progn
              (setf (fdefinition 'broker::%prebuilt-image-path)
                    (lambda () ,value))
              ,@body)
         (setf (fdefinition 'broker::%prebuilt-image-path) ,real)))))

(defun arg-after (flag args)
  "The argument following FLAG in ARGS, or NIL when FLAG is not there."
  (let ((tail (member flag args :test #'string=)))
    (second tail)))

(defun any-arg-contains (text args)
  "True when some argument in ARGS contains TEXT."
  (some (lambda (a) (and (stringp a) (search text a))) args))

;;; ------------------------------------------------------------ how it launches

(define-test a-prebuilt-image-is-launched-directly-and-builds-nothing
  "With an image on disk the broker is started from it, and none of the
   source-loading preamble is sent. The point of the image is the time it saves,
   so a launch that loaded quicklisp anyway would be the same wait wearing a
   different command line."
  (with-image-path ("/tmp/some-dsmr.core")
    (let ((args (broker::%broker-spawn-args "/tmp/a-bus/" :block nil)))
      (is string= "/tmp/some-dsmr.core" (arg-after "--core" args)
          "the image on disk is the one launched")
      (false (any-arg-contains "quickload" args)
             "and nothing is built from source on the way up")
      (false (any-arg-contains "initialize-source-registry" args)
             "nor is a source registry set up for a build that does not happen")
      (true (member "--no-userinit" args :test #'string=)
            "the development init file is skipped, since it loads a working environment into what is meant to be a frozen image")
      (true (member "--disable-debugger" args :test #'string=)
            "and an error kills the process rather than stopping it in a debugger nobody is attached to")
      (true (any-arg-contains "broker-main" args)
            "and the process is asked to serve"))))

(define-test without-an-image-the-broker-is-still-built-from-source
  "A checkout that was never built still brings a bus up. The slow path is the
   fallback and not the failure."
  (with-image-path (nil)
    (let ((args (broker::%broker-spawn-args "/tmp/a-bus/" :block nil)))
      (false (member "--core" args :test #'string=)
             "no image is named")
      (true (any-arg-contains "quickload" args)
            "and the broker subsystem is built from source instead")
      (true (any-arg-contains "broker-main" args)
            "before the process is asked to serve"))))

(define-test the-bus-root-reaches-the-launched-process-either-way
  "Whichever branch is taken, the process is told which bus to serve. A launch
   that dropped the root would come up and serve the wrong bus, which reads as
   a broker that started fine."
  (dolist (image '("/tmp/some-dsmr.core" nil))
    (with-image-path (image)
      (let ((args (broker::%broker-spawn-args "/tmp/a-particular-bus/" :block nil)))
        (true (any-arg-contains "/tmp/a-particular-bus/" args)
              "the bus root is named on the command line")))))

;;; -------------------------------------------------------- what it records

(define-test a-broker-records-the-image-it-booted-from
  "Taken from the running process, so a broker states its own provenance without
   being told and without a flag that could be wrong."
  (with-scratch-bus (paths)
    (let ((written (broker:write-broker-identity paths)))
      (true written "the record was written")
      (let* ((record (broker:read-broker-identity paths))
             (image (broker:broker-identity-image record))
             (when-written (broker:broker-identity-image-written record)))
        (true (stringp image) "the record names an image")
        (true (probe-file image) "which is a file that exists")
        (is = (file-write-date image) when-written
            "and the write time recorded is that file's own")))))

(define-test the-image-and-its-age-are-reported-as-stated-facts
  "Both fields carry what they establish and what they do not. The one that
   matters is the second: nothing here compares the image with the working tree,
   and a reader who takes a clean report as agreement has the wrong answer."
  (with-scratch-bus (paths)
    (broker:write-broker-identity paths)
    (let* ((identity (status:broker-identity paths))
           (image (getf identity :image))
           (age (getf identity :image-written)))
      (true (probe-file (getf image :value))
            "the image field names a file that exists")
      (is equal "durable-record" (getf image :basis)
          "read from the record the broker wrote, and labelled as such")
      (true (search "does not establish that the image agrees with the working tree"
                    (getf image :does-not-establish))
            "and it says outright that it settles no comparison with the tree")
      (true (stringp (getf image :red-condition))
            "with the condition that would flip it stated")
      (true (integerp (getf age :value))
            "the age field carries the write time")
      (true (search "does not establish how old the code in that image is"
                    (getf age :does-not-establish))
            "and separates the file's age from the age of what is in it"))))

(define-test a-bus-whose-record-predates-image-provenance-says-so-and-does-not-guess
  "A broker that started before brokers recorded their image leaves a record
   with no image in it. That is reported as unavailable rather than as an empty
   string or a plausible path, because a reader cannot tell a guess from a
   measurement once it is printed."
  (with-scratch-bus (paths)
    (with-open-file (out (broker:broker-identity-path paths)
                         :direction :output
                         :if-exists :supersede
                         :if-does-not-exist :create)
      (with-standard-io-syntax
        (prin1 (list :pid (sb-posix:getpid)
                     :ppid-at-start (sb-posix:getppid)
                     :started-at (get-universal-time))
               out)))
    (let* ((identity (status:broker-identity paths))
           (image (getf identity :image))
           (age (getf identity :image-written)))
      (is equal "unavailable" (getf image :value)
          "the image reads unavailable")
      (is equal "unavailable" (getf age :value)
          "and so does its age")
      (true (search "does not establish that the broker is serving current code"
                    (getf image :does-not-establish))
            "and neither absence is read as a verdict about the code being served"))))
