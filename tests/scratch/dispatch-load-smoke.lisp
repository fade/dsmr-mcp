;;;; tests/scratch/dispatch-load-smoke.lisp
;;;; Smoke test: load dsmr-mcp and verify repl-eval-tool is registered.
;;;; Used by Task 1 acceptance criteria (02-03-PLAN.md):
;;;;   (asdf:load-system :dsmr-mcp) + check *tool-classes* entry.

(require :asdf)

;; Load the system
(handler-case
    (asdf:load-system :dsmr-mcp :force t)
  (error (e)
    (format *error-output* "FAIL: load-system :dsmr-mcp signalled: ~A~%" e)
    (uiop:quit 1)))

;; Verify repl-eval-tool auto-registered as "repl-eval"
(let ((cls (gethash "repl-eval" dsmr-mcp/src/tools/base:*tool-classes*)))
  (unless cls
    (format *error-output*
            "FAIL: 'repl-eval' not in *tool-classes* after loading dsmr-mcp~%")
    (uiop:quit 1)))

;; Verify the class has the expected slots
(let* ((cls   (gethash "repl-eval" dsmr-mcp/src/tools/base:*tool-classes*))
       (proto (c2mop:class-prototype cls))
       (name  (ignore-errors (dsmr-mcp/src/tools/base:tool-name proto))))
  (unless (equal name "repl-eval")
    (format *error-output*
            "FAIL: tool-name prototype returned ~S, expected \"repl-eval\"~%"
            name)
    (uiop:quit 1)))

(format t "OK: repl-eval-tool registered as \"repl-eval\" in *tool-classes*~%")
(uiop:quit 0)
