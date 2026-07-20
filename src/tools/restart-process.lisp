;;;; src/tools/restart-process.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; MCP tool: restart-process — the terminal rung of the recovery ladder.
;;;;
;;;; This verb bounces the whole server process. It returns a structured result
;;;; to the client confirming the impending restart, then exits the process with
;;;; an agreed sentinel code (75, EX_TEMPFAIL) once the SBCL exit hooks have run
;;;; (pool shutdown, bus disconnect). The supervising launcher
;;;; (scripts/dsmr-mcp-launch.sh) relaunches the server ONLY on this exact code;
;;;; every other exit code exits the launcher.
;;;;
;;;; The exit is unconditional: it never waits on a backend reply, so it works
;;;; even when an in-image backend is wedged. All in-image state (loaded systems,
;;;; REPL definitions, attached connection, hermetic workers) is lost — the
;;;; explicit verb name is the operator's consent; there is no confirmation gate.
;;;;
;;;; The sentinel constant and the exit primitive are exported so the background
;;;; bus listener can reuse them for the worker re-exec path: both call ONE
;;;; primitive (%trigger-restart-exit), and it must be called OUTSIDE any lock.
;;;;
;;;; CLOS pattern: see pool-kill-worker.lisp — the same :initform-on-class-slots
;;;; rule and post-defclass ensure-finalized apply.

(defpackage #:dsmr-mcp/src/tools/restart-process
  (:use #:cl)
  (:local-nicknames (#:bt #:bordeaux-threads))
  (:import-from #:dsmr-mcp/src/tools/base
                #:mcp-tool #:mcp-tool-class #:tool-handle)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:result #:text-content #:make-ht)
  (:import-from #:dsmr-mcp/src/log
                #:log-event)
  ;; closer-mop: c2mop:ensure-finalized is called after the defclass below.
  ;; MUST be declared here or the cold build fails ("Package CLOSER-MOP does not exist").
  (:import-from #:closer-mop)
  (:export #:restart-process-tool
           #:+restart-exit-code+
           #:%trigger-restart-exit
           #:*restart-exit-fn*))

(in-package #:dsmr-mcp/src/tools/restart-process)

(defconstant +restart-exit-code+ 75
  "Process exit code that signals the supervising launcher to relaunch the
server (75 = EX_TEMPFAIL from sysexits.h, \"temporary failure; retry\"). SBCL
uses this code for no other purpose, so it cannot collide with an ordinary
error exit. The launcher relaunches ONLY on this exact code; every other code
exits the launcher.")

(defparameter *restart-exit-fn* #'uiop:quit
  "The function called to terminate the process during a restart, taking the
exit code as its sole required argument. Defaults to uiop:quit, which runs
sb-ext:*exit-hooks* (pool shutdown, bus disconnect) before terminating. A test
rebinds this to a recording closure so the restart path is exercised without
killing the test image.")

(defparameter *restart-exit-delay* 0.05
  "Seconds to wait, on the deferred exit thread, before triggering the restart
exit — long enough for the transport to flush the tool result back to the
client before the process dies. Bound to 0 in tests for determinism.")

(defun %trigger-restart-exit (&optional (code +restart-exit-code+))
  "Terminate the process with CODE by invoking the bound *restart-exit-fn*,
after flushing stdout so any pending JSON-RPC response drains. This is the one
primitive shared by the rung-3 verb and the background bus listener; call it
OUTSIDE any lock scope, since *restart-exit-fn* (uiop:quit) does not return."
  (log-event :info "restart.process.exiting" "reason" "operator-restart")
  (ignore-errors (finish-output *standard-output*))
  (funcall *restart-exit-fn* code))

(defun %schedule-restart-exit (&optional (code +restart-exit-code+))
  "Defer the restart exit onto a detached thread so tool-handle can return its
result and the transport can flush it before the process exits. Captures the
current dynamic value of *restart-exit-fn* and rebinds it inside the thread:
SBCL specials are thread-local, so a caller that rebound *restart-exit-fn* (a
test) would otherwise not be seen by the fresh thread. Returns the thread."
  (let ((fn *restart-exit-fn*)
        (delay *restart-exit-delay*))
    (bt:make-thread
     (lambda ()
       (when (and delay (plusp delay)) (sleep delay))
       (let ((*restart-exit-fn* fn))
         (%trigger-restart-exit code)))
     :name "dsmr-restart-exit")))

(defclass restart-process-tool (mcp-tool)
  ;; CRITICAL: :initform on class-allocated slots, NOT :default-initargs.
  ((dsmr-mcp/src/tools/base::name
    :allocation :class
    :initform "restart-process")
   (dsmr-mcp/src/tools/base::description
    :allocation :class
    :initform "Restart the whole dsmr-mcp server process (rung 3, the TERMINAL \
rung of the recovery ladder). The process exits with a sentinel code and the \
supervising launcher relaunches it, re-establishing the session. ALL in-image \
state is lost — loaded systems, REPL definitions, the attached Slynk \
connection, and every hermetic worker. Use this only when an in-place reset \
(reset-local) is insufficient; for a lighter recovery prefer reset-local. The \
exit is unconditional and never waits on a backend, so it works even when a \
backend is wedged. There is no confirmation prompt: invoking this verb is the \
explicit intent.")
   (dsmr-mcp/src/tools/base::input-schema
    :allocation :class
    :initform '(:object
                :properties
                ((scope
                  :type :string
                  :description "Optional restart scope. Omit to restart this \
server process. Reserved for directing a re-exec at a named worker on a future \
worker path."))
                :required ())))
  (:metaclass mcp-tool-class)
  (:documentation "MCP tool: rung-3 terminal restart — return a result, then
exit the process with the restart sentinel so the launcher relaunches it."))

;; CRITICAL: ensure-finalized must appear after defclass.
;; (src/tools/base.lisp line 162; src/attach/dispatch.lisp line 115.)
(c2mop:ensure-finalized (find-class 'restart-process-tool))

(defmethod tool-handle ((tool restart-process-tool) id args)
  (declare (ignore args))
  ;; Build the success result FIRST, then defer the exit so the transport flushes
  ;; the response before the process dies. Per the independence constraint the
  ;; exit is unconditional — never gated on a backend reply. No confirmation gate.
  (let ((response (result id (make-ht "isError" nil
                                      "content"
                                      (text-content
                                       "Restarting the dsmr-mcp server process now. All \
in-image state is lost; the launcher will relaunch the server. Reconnect/retry your next \
tool call once it is back.")))))
    (%schedule-restart-exit)
    response))
