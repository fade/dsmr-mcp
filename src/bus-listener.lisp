;;;; src/bus-listener.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Stub — implementation follows.

(defpackage #:dsmr-mcp/src/bus-listener
  (:use #:cl)
  (:local-nicknames (#:bt #:bordeaux-threads)
                    (#:jzon #:com.inuoe.jzon))
  (:import-from #:dsmr-mcp/src/bus/agent
                #:connect-agent #:agent-receive #:disconnect-agent)
  (:import-from #:dsmr-mcp/src/reset
                #:reset-local-backends)
  (:import-from #:dsmr-mcp/src/tools/restart-process
                #:%trigger-restart-exit)
  (:import-from #:dsmr-mcp/src/log
                #:log-event)
  (:export #:start-bus-listener #:stop-bus-listener))

(in-package #:dsmr-mcp/src/bus-listener)

(defun %handle-restart-message (message own-namespace own-name
                                &key on-reset on-reexec)
  (declare (ignore message own-namespace own-name on-reset on-reexec))
  nil)

(defun start-bus-listener (namespace own-name &key (poll-ms 2000) session)
  (declare (ignore namespace own-name poll-ms session))
  nil)

(defun stop-bus-listener ()
  nil)
