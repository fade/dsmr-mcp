;;;; tests/bus/selector-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Zebra tests for bus state-root derivation.
;;;;
;;;; Two properties matter more than the rest. An unnamed bus must land on the
;;;; path it has always used, because every running agent, every cursor and every
;;;; archived log on this machine already lives there. And a name that will not
;;;; fit must be refused rather than shortened, because a shortened socket path
;;;; still binds and quietly serves a different bus.
;;;;
;;;; The expected unnamed path is recomputed here from the environment rather
;;;; than read back from the code under test, so this file keeps answering the
;;;; question after the production copies of the derivation are gone.

(require :sb-posix)

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/bus/selector-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/bus/selector-test
  (:use #:cl #:zebra)
  (:local-nicknames (#:selector #:dsmr-mcp/src/bus/selector)
                    (#:broker #:dsmr-mcp/src/bus/broker)))

(in-package #:dsmr-mcp/tests/bus/selector-test)

;;; ------------------------------------------------------------- environment

(defmacro with-state-home ((value) &body body)
  "Run BODY with XDG_STATE_HOME bound to VALUE, restoring the prior value after.
   An empty string reads as absent, which is how the fallback branch is reached."
  (let ((saved (gensym "SAVED")))
    `(let ((,saved (uiop:getenv "XDG_STATE_HOME")))
       (unwind-protect
            (progn (setf (uiop:getenv "XDG_STATE_HOME") ,value)
                   ,@body)
         (setf (uiop:getenv "XDG_STATE_HOME") (or ,saved ""))))))

(defun temp-state-home ()
  "A short, unique state-home path. Never created: nothing here touches disk.
   The random component is seeded per call because SBCL's default random state
   repeats across fresh images, and two runs sharing a path would let one run's
   leftovers answer the other's absence assertions."
  (namestring
   (merge-pathnames (format nil "dsmr-selector-~D-~D/"
                            (sb-posix:getpid)
                            (random 100000000 (make-random-state t)))
                    (uiop:temporary-directory))))

(defun overflowing-state-home ()
  "A state-home path long enough that any bus socket derived under it overruns
   the unix-domain path limit. Never created."
  (concatenate 'string
               (namestring (uiop:temporary-directory))
               "dsmr-selector-overflow-"
               (make-string 140 :initial-element #\d)
               "/"))

(defun expected-unnamed-root ()
  "The unnamed bus root, recomputed from the environment independently of the
   code under test."
  (let ((xdg (uiop:getenv "XDG_STATE_HOME")))
    (merge-pathnames "dsmr-mcp/bus/"
                     (if (and xdg (plusp (length xdg)))
                         (uiop:ensure-directory-pathname xdg)
                         (merge-pathnames ".local/state/" (user-homedir-pathname))))))

(defun socket-path-length (root)
  "How long the submit socket's filesystem path would be under ROOT."
  (length (concatenate 'string (namestring root) "submit.ipc")))

(defun refusal-text (thunk)
  "Call THUNK and return the printed refusal, or NIL if it did not refuse."
  (handler-case (progn (funcall thunk) nil)
    (selector:invalid-bus-name (condition) (princ-to-string condition))))

;;; ------------------------------------------------------- the unnamed root

(define-test unnamed-root-matches-the-shipped-path
  "With a state home set, no name derives exactly the path the bus already uses."
  (let ((home (temp-state-home)))
    (with-state-home (home)
      (is equal
          (namestring (expected-unnamed-root))
          (namestring (selector:bus-root)))
      (is equal
          (namestring (broker:default-state-root))
          (namestring (selector:bus-root))))))

(define-test unnamed-root-falls-back-to-the-home-directory
  "With no state home in the environment the derivation falls back under
   ~/.local/state/, which is the branch most machines actually take."
  (with-state-home ("")
    (is equal
        (namestring (merge-pathnames ".local/state/dsmr-mcp/bus/"
                                     (user-homedir-pathname)))
        (namestring (selector:bus-root)))
    (is equal
        (namestring (broker:default-state-root))
        (namestring (selector:bus-root)))))

(define-test no-name-and-empty-name-agree
  "NIL and the empty string both mean no name, and must not diverge."
  (let ((home (temp-state-home)))
    (with-state-home (home)
      (is equal
          (namestring (selector:bus-root))
          (namestring (selector:bus-root nil)))
      (is equal
          (namestring (selector:bus-root))
          (namestring (selector:bus-root ""))))))

;;; --------------------------------------------------------- the named root

(define-test named-root-appends-one-segment
  "A name is the unnamed root plus one directory segment, and nothing else."
  (let ((home (temp-state-home)))
    (with-state-home (home)
      (is equal
          (concatenate 'string (namestring (expected-unnamed-root)) "valis/")
          (namestring (selector:bus-root "valis"))))))

(define-test named-roots-are-distinct
  "Two names give two roots. This is the whole of the isolation."
  (let ((home (temp-state-home)))
    (with-state-home (home)
      (isnt equal
            (namestring (selector:bus-root "valis"))
            (namestring (selector:bus-root "fulcrum")))
      (isnt equal
            (namestring (selector:bus-root))
            (namestring (selector:bus-root "valis"))))))

(define-test acceptable-names-are-accepted
  "The permitted alphabet is alphanumerics plus hyphen, underscore and period."
  (dolist (name '("valis" "dsmr-mcp" "fleet_7" "v0.4" "A1" "a"))
    (is equal name (selector:validate-bus-name name))))

;;; ---------------------------------------------------------- name refusals

(define-test over-long-name-is-refused
  "A name past the length bound is refused, and the refusal says the bound."
  (let ((name (make-string (1+ selector:+max-bus-name-length+)
                           :initial-element #\a)))
    (fail (selector:validate-bus-name name) selector:invalid-bus-name)
    (fail (selector:bus-root name) selector:invalid-bus-name)
    (let ((text (refusal-text (lambda () (selector:bus-root name)))))
      (true (search (princ-to-string selector:+max-bus-name-length+) text)))))

(define-test name-at-the-length-bound-is-accepted
  "The bound is inclusive: the refusal starts one character later."
  (let ((name (make-string selector:+max-bus-name-length+ :initial-element #\a)))
    (is equal name (selector:validate-bus-name name))))

(define-test names-with-forbidden-characters-are-refused
  "Anything that could leave the bus directory, or that a shell would mangle,
   is refused. A separator is the one that matters most."
  (dolist (name '("va/lis" "../escape" "with space" "tab	here" "star*" "quote'"
                  "dollar$" "semi;colon" "back\\slash" "new
line"))
    (fail (selector:validate-bus-name name) selector:invalid-bus-name)
    (fail (selector:bus-root name) selector:invalid-bus-name)))

(define-test empty-name-is-not-a-valid-name
  "BUS-ROOT reads an empty name as no name, but the validator refuses it, so a
   caller that means to validate a name gets told rather than silently defaulted."
  (fail (selector:validate-bus-name "") selector:invalid-bus-name))

(define-test non-string-name-is-refused
  "A caller that passes something other than a string is told so."
  (fail (selector:validate-bus-name :valis) selector:invalid-bus-name)
  (fail (selector:bus-root 17) selector:invalid-bus-name))

(define-test reserved-names-are-refused
  "Every entry the bus already writes into its root, plus the dot names and the
   word the watcher prints for an unset bus."
  (dolist (name '("default" "cursors" "watch" "roster" "members"
                  "bus.wal" "broker.lock" "submit.ipc" "pub.ipc" "." ".."))
    (fail (selector:validate-bus-name name) selector:invalid-bus-name)
    (fail (selector:bus-root name) selector:invalid-bus-name)))

(define-test reserved-names-are-refused-case-insensitively
  "The filesystem may or may not fold case; the refusal does not depend on it."
  (dolist (name '("Default" "CURSORS" "Members" "Bus.WAL"))
    (fail (selector:validate-bus-name name) selector:invalid-bus-name)))

;;; -------------------------------------------------------- path-length bound

(define-test over-long-socket-path-is-refused-not-truncated
  "The check that keeps a bus from silently becoming a different bus. The
   refusal names the derived path and the limit, and creates nothing."
  (let ((home (overflowing-state-home)))
    (with-state-home (home)
      (fail (selector:bus-root "x") selector:invalid-bus-name)
      (let ((text (refusal-text (lambda () (selector:bus-root "x")))))
        (true (search "submit.ipc" text))
        (true (search (princ-to-string selector:+max-socket-path-length+) text)))
      (false (probe-file home))
      (false (probe-file (concatenate 'string home "dsmr-mcp/bus/x/"))))))

(define-test over-long-state-home-is-refused-with-no-name-too
  "An over-long state home produces a bus nobody can bind, named or not, so the
   unnamed root is measured by the same rule."
  (let ((home (overflowing-state-home)))
    (with-state-home (home)
      (fail (selector:bus-root) selector:invalid-bus-name)
      (false (probe-file home)))))

(define-test normal-roots-stay-inside-the-limit
  "A named root under an ordinary state home has room to spare."
  (let ((home (temp-state-home)))
    (with-state-home (home)
      (true (<= (socket-path-length (selector:bus-root))
                selector:+max-socket-path-length+))
      (true (<= (socket-path-length (selector:bus-root "valis"))
                selector:+max-socket-path-length+)))))
