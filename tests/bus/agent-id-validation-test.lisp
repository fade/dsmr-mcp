;;;; tests/bus/agent-id-validation-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Zebra tests for the check that decides whether a string may name an agent
;;;; on the bus, and for the one place that check has to stand in front of: the
;;;; subscribe path, where reading is what brings a cursor into existence.
;;;;
;;;; The suite is deliberately weighted towards what must be ACCEPTED. The
;;;; namespace half of an id is a project root, so it may carry a space, an
;;;; accented letter, a quote or an angle bracket, and a rule tightened past the
;;;; refusals below would reject somebody's working directory. A test that only
;;;; pinned the refusals would stay green through exactly that mistake.
;;;;
;;;; Every control character here is built with CODE-CHAR rather than written
;;;; literally, so what each case is testing is legible in the source instead of
;;;; being an invisible byte a later editor would silently normalise away.

(require :sb-posix)

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/bus/agent-id-validation-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/bus/agent-id-validation-test
  (:use #:cl #:zebra)
  (:local-nicknames (#:broker #:dsmr-mcp/src/bus/broker)
                    (#:bus #:dsmr-mcp/src/bus/bus)
                    (#:envelope #:dsmr-mcp/src/bus/envelope)))

(in-package #:dsmr-mcp/tests/bus/agent-id-validation-test)

(defun refusal-reason (id)
  "The REASON keyword the validator refuses ID with, or NIL when it accepts it."
  (handler-case (progn (envelope:validate-agent-id id) nil)
    (envelope:malformed-agent-id (condition)
      (envelope:malformed-agent-id-reason condition))))

(defun accepted-p (id)
  "True when the validator hands ID back rather than refusing it."
  (handler-case (string= id (envelope:validate-agent-id id))
    (envelope:malformed-agent-id () nil)))

(defun with-character (code &optional (prefix "/home/fade/project/worker"))
  "PREFIX with the character CODE names appended: an id that starts out
   perfectly ordinary and picks up one character that must sink it."
  (concatenate 'string prefix (string (code-char code))))

(defmacro with-bus-root ((paths-var) &body body)
  "Bind PATHS-VAR to bus paths over a fresh empty root, with the bus directories
   already made, and delete the tree afterwards.

   The suffix is seeded per call because SBCL's default random state repeats
   across fresh images: an unseeded name would collide between runs, and the
   assertion below is that a directory is EMPTY, which a leftover file flakes."
  (let ((root (gensym "ROOT")))
    `(let* ((,root (merge-pathnames
                    (format nil "dsmr-agent-id-~D-~D/"
                            (sb-posix:getpid)
                            (random 100000000 (make-random-state t)))
                    (uiop:temporary-directory)))
            (,paths-var (broker:make-bus-paths ,root)))
       (broker:ensure-bus-dirs ,paths-var)
       (unwind-protect (progn ,@body)
         (ignore-errors (uiop:delete-directory-tree ,root :validate t))))))

;;; ------------------------------------------------------------- refusals

(define-test newline-in-an-id-is-refused
  "The case the rule exists for. An id that picked up a stray fragment of
   something else carries the newline that joined them, and the encoder
   downstream cannot fail, so an unchecked id of this shape mints a cursor
   filename and then goes on to take part in resolving a recipient."
  (let ((id (concatenate 'string (with-character 10) "<tool-call>")))
    (is eq :control-character (refusal-reason id))
    (false (accepted-p id))))

(define-test another-control-character-is-refused
  "The rule is the whole C0 range plus DEL, not the newline alone. Tab, NUL,
   escape and DEL each sink an id that is otherwise perfectly ordinary."
  (dolist (code (list 0 9 13 27 31 127))
    (is eq :control-character (refusal-reason (with-character code))
        (format nil "the character with code ~D belongs in no agent id" code))))

(define-test an-id-that-names-nobody-is-refused
  "An empty id and an id of nothing but separators both name no agent. They are
   refused for that reason rather than for carrying anything, so they answer
   with their own keywords and a caller can tell the two apart."
  (is eq :empty (refusal-reason ""))
  (is eq :no-name (refusal-reason "/"))
  (is eq :no-name (refusal-reason "///"))
  (is eq :not-a-string (refusal-reason nil)))

;;; ----------------------------------------------------------- acceptances

(define-test real-project-roots-are-accepted
  "What the rule must not break. Each of these is a plausible working directory
   and every one of them would fail a tighter alphabet: a space in the path, an
   accented letter, a quote, an angle bracket, a name with no namespace at all."
  (let ((accented (concatenate 'string "/home/fade/caf" (string (code-char 233))
                               "/worker")))
    (true (accepted-p "/home/fade/project/worker"))
    (true (accepted-p "/home/fade/My Projects/worker")
          "a space in a project root is ordinary, not malformed")
    (true (accepted-p accented)
          "a non-ASCII project root is ordinary, not malformed")
    (true (accepted-p "/home/fade/it's/worker"))
    (true (accepted-p "/home/fade/<odd>/worker"))
    (true (accepted-p "worker")
          "an id with no namespace is still an id")))

(define-test an-accepted-id-comes-back-unchanged
  "The validator is a gate and not a filter. An id it accepts is returned as it
   arrived, so no caller can come to depend on it quietly repairing one."
  (let ((id "/home/fade/My Projects/worker"))
    (is string= id (envelope:validate-agent-id id))))

;;; ------------------------------------------------ the cursor never appears

(define-test subscribe-refuses-a-malformed-id-and-leaves-nothing-behind
  "The refusal has to land before the cursor path is computed, because a cursor
   is created by the act of reading and nothing afterwards revokes it. The sweep
   that clears abandoned cursors spares any name that is not ephemeral, so a
   cursor minted from a malformed id would outlive every agent that saw it."
  (with-bus-root (paths)
    (let ((id (concatenate 'string (with-character 10) "<tool-call>")))
      (is eq :control-character
          (handler-case (progn (bus:subscribe paths id :join nil) nil)
            (envelope:malformed-agent-id (condition)
              (envelope:malformed-agent-id-reason condition)))
          "subscribe refuses the id rather than opening on it")
      (false (uiop:directory-files (broker:bus-paths-cursors-dir paths))
             "and no cursor file was minted on the way to refusing"))))
