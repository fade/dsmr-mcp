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
               "slynk-client"
               "dsmr-mcp/src/main"
               "dsmr-mcp/src/protocol"
               "dsmr-mcp/src/attach/dispatch")
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
               "dsmr-mcp/tests/run-test")
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
