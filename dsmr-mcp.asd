;;;; dsmr-mcp.asd

;; Tell ASDF that eclector.parse-result et al. live in :eclector.
(asdf:register-system-packages "eclector"
                               '(:eclector.parse-result
                                 :eclector.reader
                                 :eclector.base))

(asdf:defsystem "dsmr-mcp"
  :class :package-inferred-system
  :description
  "DeepSky Systems Model-Context-Protocol server for Common Lisp: an
attached-image-first MCP exposing the verbs an agent needs to write
and debug Lisp inside a live development image, with hermetic
file-based ICP as a fallback for crash isolation and parallel workers."
  :author "Brian O'Reilly <fade@deepsky.com>"
  :license "AGPL-3.0-or-later"
  :version "0.1.0"
  :depends-on ("alexandria"
               "cl-ppcre"
               "com.inuoe.jzon"
               "closer-mop"
               "ubiquitous"
               "usocket"
               "bordeaux-threads"
               "eclector"
               "hunchentoot"
               "log4cl"
               "slynk-client"
               "dsmr-mcp/src/main"
               "dsmr-mcp/src/protocol"
               "dsmr-mcp/src/attach/registry"
               "dsmr-mcp/src/attach/dispatch"
               "dsmr-mcp/src/hermetic/worker-client"
               "dsmr-mcp/src/hermetic/worker/server"
               "dsmr-mcp/src/hermetic/worker/registry"
               "dsmr-mcp/src/hermetic/worker/inspect"
               "dsmr-mcp/src/hermetic/worker/handlers"
               "dsmr-mcp/src/hermetic/worker/main"
               "dsmr-mcp/src/hermetic/pool"
               "dsmr-mcp/src/hermetic/dispatch"
               "dsmr-mcp/src/project-root"
               "dsmr-mcp/src/fs"
               "dsmr-mcp/src/package-context"
               "dsmr-mcp/src/cst"
               "dsmr-mcp/src/lisp-read-file"
               "dsmr-mcp/src/parinfer"
               "dsmr-mcp/src/lisp-edit-form-core"
               "dsmr-mcp/src/lisp-edit-form"
               "dsmr-mcp/src/lisp-patch-form"
               "dsmr-mcp/src/validate"
               "dsmr-mcp/src/clgrep"
               "dsmr-mcp/src/tools/lisp-check-parens"
               "dsmr-mcp/src/tools/lisp-read-file"
               "dsmr-mcp/src/tools/lisp-edit-form"
               "dsmr-mcp/src/tools/lisp-patch-form"
               "dsmr-mcp/src/tools/fs-set-project-root"
               "dsmr-mcp/src/tools/fs-get-project-info"
               "dsmr-mcp/src/tools/fs-read-file"
               "dsmr-mcp/src/tools/fs-write-file"
               "dsmr-mcp/src/tools/fs-list-directory"
               "dsmr-mcp/src/tools/clgrep-search"
               "dsmr-mcp/src/tools/inspect-object"
               "dsmr-mcp/src/code-core"
               "dsmr-mcp/src/system-loader-core"
               "dsmr-mcp/src/test-runner-core"
               "dsmr-mcp/src/tools/code-find"
               "dsmr-mcp/src/tools/code-describe"
               "dsmr-mcp/src/tools/code-find-references"
               "dsmr-mcp/src/tools/load-system"
               "dsmr-mcp/src/tools/run-tests"
               "dsmr-mcp/src/tools/inspect-thread"
               "dsmr-mcp/src/tools/inspect-restart"
               "dsmr-mcp/src/tools/inspect-condition"
               "dsmr-mcp/src/tools/pool-status"
               "dsmr-mcp/src/tools/pool-kill-worker")
  :in-order-to ((test-op (test-op "dsmr-mcp/tests"))))

(asdf:defsystem "dsmr-mcp/tests"
  :class :package-inferred-system
  :description "Test suite for dsmr-mcp."
  :depends-on ("parachute"
               "slynk"
               "dsmr-mcp"
               "dsmr-mcp/tests/smoke-test"
               "dsmr-mcp/tests/support/json-asserts"
               "dsmr-mcp/tests/support/slynk-fixture"
               "dsmr-mcp/tests/state/session-test"
               "dsmr-mcp/tests/protocol/handshake-test"
               "dsmr-mcp/tests/protocol/version-negotiation-test"
               "dsmr-mcp/tests/protocol/strict-initialize-test"
               "dsmr-mcp/tests/protocol/tools-list-test"
               "dsmr-mcp/tests/protocol/tools-call-test"
               "dsmr-mcp/tests/protocol/prompts-test"
               "dsmr-mcp/tests/protocol/argument-validation-test"
               "dsmr-mcp/tests/transport/stdio-test"
               "dsmr-mcp/tests/transport/stdio-integration-test"
               "dsmr-mcp/tests/run-test"
               "dsmr-mcp/tests/attach/repl-eval-attach-test"
               "dsmr-mcp/tests/attach/registry-test"
               "dsmr-mcp/tests/log/log-test"
               "dsmr-mcp/tests/dispatch/mode-router-test"
               "dsmr-mcp/tests/hermetic/worker-spawn-test"
               "dsmr-mcp/tests/hermetic/pool-affinity-test"
               "dsmr-mcp/tests/hermetic/circuit-breaker-test"
               "dsmr-mcp/tests/hermetic/repl-eval-parity-test"
               "dsmr-mcp/tests/hermetic/inspect-test"
               "dsmr-mcp/tests/attach/inspect-test"
               "dsmr-mcp/tests/attach/inspect-thread-test"
               "dsmr-mcp/tests/attach/inspect-restart-test"
               "dsmr-mcp/tests/attach/inspect-condition-test"
               "dsmr-mcp/tests/support/fs-fixture"
               "dsmr-mcp/tests/fs/sandbox-test"
               "dsmr-mcp/tests/fs/symlink-escape-test"
               "dsmr-mcp/tests/fs/project-root-test"
               "dsmr-mcp/tests/fs/fs-verbs-test"
               "dsmr-mcp/tests/fs/lisp-read-file-test"
               "dsmr-mcp/tests/lisp-edit-form-test"
               "dsmr-mcp/tests/lisp-patch-form-test"
               "dsmr-mcp/tests/validate-test"
               "dsmr-mcp/tests/clgrep-test"
               "dsmr-mcp/tests/code-intelligence/code-core-test"
               "dsmr-mcp/tests/code-intelligence/code-find-test"
               "dsmr-mcp/tests/code-intelligence/code-describe-test"
               "dsmr-mcp/tests/code-intelligence/code-find-refs-test"
               "dsmr-mcp/tests/code-intelligence/load-system-test"
               "dsmr-mcp/tests/code-intelligence/run-tests-test")
  :perform (test-op (o c)
                    (declare (ignore o))
                    (let* ((test-package-names
                            (remove-if-not
                             (lambda (dep)
                               (and (stringp dep)
                                    (uiop:string-prefix-p "dsmr-mcp/tests/" dep)))
                             (asdf:system-depends-on c)))
                           (any-failed nil))
                      (dolist (name test-package-names)
                        (let* ((package (or (find-package (string-upcase name))
                                            (error "Test package ~S not loaded." name)))
                               (result (uiop:symbol-call :parachute :test package)))
                          (when (uiop:symbol-call :parachute :results-with-status
                                                  :failed result)
                            (setf any-failed t))))
                      (when any-failed
                        (error "dsmr-mcp/tests: one or more parachute tests failed.")))))
