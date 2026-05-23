;;;; tests/scratch/session-wiring-smoke.lisp
;;;; Smoke test: verify session slynk-attach slot is wired correctly.
;;;; Used by Task 2 acceptance criteria (02-03-PLAN.md):
;;;;   - session has slynk-attach slot with session-slynk-attach accessor
;;;;   - make-session accepts :slynk-attach
;;;;   - session created with :slynk-attach "h:1" returns "h:1"

(require :asdf)

;; Load the system
(handler-case
    (asdf:load-system :dsmr-mcp :force t)
  (error (e)
    (format *error-output* "FAIL: load-system :dsmr-mcp signalled: ~A~%" e)
    (uiop:quit 1)))

;; Verify session-slynk-attach is exported from dsmr-mcp/src/state
(unless (find-symbol "SESSION-SLYNK-ATTACH"
                     (find-package :dsmr-mcp/src/state))
  (format *error-output*
          "FAIL: SESSION-SLYNK-ATTACH not exported from dsmr-mcp/src/state~%")
  (uiop:quit 1))

;; Verify make-session accepts :slynk-attach keyword
(let ((s (handler-case
              (dsmr-mcp/src/state:make-session :id "smoke-test" :slynk-attach "h:1")
            (error (e)
              (format *error-output*
                      "FAIL: make-session :slynk-attach signalled: ~A~%" e)
              (uiop:quit 1)))))
  ;; Verify accessor returns the configured value
  (let ((val (dsmr-mcp/src/state:session-slynk-attach s)))
    (unless (equal val "h:1")
      (format *error-output*
              "FAIL: session-slynk-attach returned ~S, expected \"h:1\"~%"
              val)
      (uiop:quit 1))))

;; Verify a session without :slynk-attach returns nil
(let ((s (dsmr-mcp/src/state:make-session :id "smoke-no-attach")))
  (let ((val (dsmr-mcp/src/state:session-slynk-attach s)))
    (unless (null val)
      (format *error-output*
              "FAIL: session-slynk-attach with no arg returned ~S, expected NIL~%"
              val)
      (uiop:quit 1))))

(format t "OK: session slynk-attach slot and make-session :slynk-attach wired correctly~%")
(uiop:quit 0)
