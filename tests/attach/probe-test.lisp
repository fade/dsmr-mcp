;;;; tests/attach/probe-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Zebra tests for the Slynk port classifier and identity probe.
;;;;
;;;; Network-requiring tests (classify-port against a live Slynk, full
;;;; resolve-slynk-target identity flow) live in the cross-process integration
;;;; suite.  This file covers the pure, non-network functions only.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/attach/probe-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/attach/probe-test
  (:use #:cl #:zebra)
  (:import-from #:dsmr-mcp/src/attach/probe
                #:classify-port
                #:slynk-handshake-path
                #:read-slynk-handshake
                #:resolve-slynk-target))

(in-package #:dsmr-mcp/tests/attach/probe-test)

;;; ---------------------------------------------------------------------------
;;; classify-port — :free case (no listener, should be fast)
;;; ---------------------------------------------------------------------------

(define-test classify-port-returns-free-on-refused-connection
  "classify-port returns :free when nothing listens on the probed port."
  ;; Port 1 is well-known as unprivileged-inaccessible on Linux; we use a
  ;; high ephemeral port that is almost certainly not bound to avoid any
  ;; privilege concern.  This test pays a TCP-connect timeout only if
  ;; something really is listening on 19999, which is exceedingly rare.
  (is eq :free (classify-port "127.0.0.1" 19999 :timeout 0.5)))

;;; ---------------------------------------------------------------------------
;;; slynk-handshake-path
;;; ---------------------------------------------------------------------------

(define-test handshake-path-appends-filename
  "slynk-handshake-path appends .dsmr-slynk.port to the project root."
  (let ((p (slynk-handshake-path "/home/fade/SourceCode/lisp/my-project/")))
    (is string= "/home/fade/SourceCode/lisp/my-project/.dsmr-slynk.port"
        (namestring p))))

(define-test handshake-path-normalises-missing-trailing-slash
  "slynk-handshake-path treats a path without a trailing slash the same way."
  (let ((with-slash    (namestring (slynk-handshake-path "/tmp/proj/")))
        (without-slash (namestring (slynk-handshake-path "/tmp/proj"))))
    (is string= with-slash without-slash)))

;;; ---------------------------------------------------------------------------
;;; read-slynk-handshake — file-system cases
;;; ---------------------------------------------------------------------------

(define-test read-handshake-returns-nil-for-missing-file
  "read-slynk-handshake returns NIL when the handshake file does not exist."
  (is eq nil
      (read-slynk-handshake "/tmp/dsmr-mcp-probe-test-nonexistent-dir-99999/")))

(define-test read-handshake-returns-nil-for-nil-root
  "read-slynk-handshake returns NIL for a NIL project-root."
  (is eq nil (read-slynk-handshake nil)))

(define-test read-handshake-returns-nil-for-empty-root
  "read-slynk-handshake returns NIL for an empty string project-root."
  (is eq nil (read-slynk-handshake "")))

(define-test read-handshake-reads-written-file
  "read-slynk-handshake round-trips through an actual file."
  (let* ((dir (uiop:ensure-directory-pathname
               (format nil "/tmp/dsmr-probe-test-~A/" (get-universal-time))))
         (handshake-content "127.0.0.1:18709"))
    (unwind-protect
         (progn
           (ensure-directories-exist dir)
           (with-open-file (f (merge-pathnames ".dsmr-slynk.port" dir)
                             :direction :output :if-exists :supersede
                             :if-does-not-exist :create)
             (write-string handshake-content f)
             (terpri f))
           (is string= handshake-content (read-slynk-handshake (namestring dir))))
      (ignore-errors (uiop:delete-directory-tree dir :validate t)))))

(define-test read-handshake-trims-whitespace
  "read-slynk-handshake strips trailing newlines and spaces."
  (let* ((dir (uiop:ensure-directory-pathname
               (format nil "/tmp/dsmr-probe-test-trim-~A/" (get-universal-time)))))
    (unwind-protect
         (progn
           (ensure-directories-exist dir)
           (with-open-file (f (merge-pathnames ".dsmr-slynk.port" dir)
                             :direction :output :if-exists :supersede
                             :if-does-not-exist :create)
             (format f "  127.0.0.1:29906~%  ~%"))
           (is string= "127.0.0.1:29906"
               (read-slynk-handshake (namestring dir))))
      (ignore-errors (uiop:delete-directory-tree dir :validate t)))))

(define-test read-handshake-returns-nil-for-no-colon
  "read-slynk-handshake returns NIL when the file has no colon (malformed)."
  (let* ((dir (uiop:ensure-directory-pathname
               (format nil "/tmp/dsmr-probe-test-bad-~A/" (get-universal-time)))))
    (unwind-protect
         (progn
           (ensure-directories-exist dir)
           (with-open-file (f (merge-pathnames ".dsmr-slynk.port" dir)
                             :direction :output :if-exists :supersede
                             :if-does-not-exist :create)
             (write-line "notaportstring" f))
           (is eq nil (read-slynk-handshake (namestring dir))))
      (ignore-errors (uiop:delete-directory-tree dir :validate t)))))

;;; ---------------------------------------------------------------------------
;;; resolve-slynk-target — hermetic short-circuit
;;; ---------------------------------------------------------------------------

(define-test resolve-target-hermetic-skips-probe
  "resolve-slynk-target returns (nil :hermetic) immediately when mode is :hermetic."
  (multiple-value-bind (att mode)
      (resolve-slynk-target "127.0.0.1:18709" "/home/fade/SourceCode/lisp/dsmr-mcp/" :hermetic)
    (is eq nil att)
    (is eq :hermetic mode)))
