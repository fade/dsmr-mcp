;;;; tests/support/env-fixture.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Environment isolation for config/mode-resolution tests.
;;;;
;;;; resolve-mode, resolve-transport, and %or-from-env read DSMR_* environment
;;;; variables by design — that is how an operator configures the live server. But
;;;; a developer runs the suite inside a direnv shell that exports those very
;;;; variables (DSMR_MODE=auto, DSMR_SLYNK_ATTACH=host:port, …) so the project's
;;;; own MCP attaches to the right per-project Slynk image. Without isolation those
;;;; values leak into resolution tests and flip their results — e.g. DSMR_MODE=auto
;;;; turns a "keyword resolves to :attached" assertion into an :auto probe that
;;;; resolves to :hermetic. The tests then fail in every real dev shell while
;;;; passing in CI's empty environment, which is exactly backwards.
;;;;
;;;; WITH-CLEAN-RESOLUTION-ENV clears the full set of resolution variables for the
;;;; duration of a test and restores the prior values afterward, so resolution is
;;;; driven only by the test's explicit keywords and conf — deterministic in any
;;;; shell. An empty value reads as "absent" to %or-from-env, so clearing is the
;;;; correct neutral state.

(defpackage #:dsmr-mcp/tests/support/env-fixture
  (:use #:cl)
  (:export #:+resolution-env-vars+
           #:with-clean-resolution-env))

(in-package #:dsmr-mcp/tests/support/env-fixture)

(defparameter +resolution-env-vars+
  '("DSMR_MODE" "DSMR_SLYNK_ATTACH" "DSMR_TRANSPORT" "DSMR_PORT" "DSMR_BIND"
    "DSMR_LOG_LEVEL" "DSMR_PROJECT_ROOT" "DSMR_ALLOW_REMOTE" "DSMR_BUS_AGENT"
    "DSMR_BUS_SELECTOR")
  "Every DSMR_* variable the config/mode resolution path consults. A direnv dev
shell commonly exports several of these for the live server; resolution tests must
neutralize them to be deterministic.

DSMR_BUS_SELECTOR earns its place for the same reason DSMR_BUS_AGENT does: a
developer whose shell puts the session on a named bus would otherwise see every
bus-resolution assertion answer with that name, and the suite would fail in a
real shell while passing in CI's empty environment.")

(defmacro with-clean-resolution-env (&body body)
  "Evaluate BODY with every variable in +RESOLUTION-ENV-VARS+ cleared, restoring
   the prior values afterward. Makes config/mode-resolution tests independent of
   the developer's shell environment."
  (let ((saved (gensym "SAVED")) (var (gensym "VAR")) (pair (gensym "PAIR")))
    `(let ((,saved (mapcar (lambda (,var) (cons ,var (uiop:getenv ,var)))
                           +resolution-env-vars+)))
       (unwind-protect
            (progn
              (dolist (,var +resolution-env-vars+) (setf (uiop:getenv ,var) ""))
              ,@body)
         (dolist (,pair ,saved)
           (setf (uiop:getenv (car ,pair)) (or (cdr ,pair) "")))))))
