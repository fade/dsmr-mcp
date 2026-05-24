;;;; src/attach/connection.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Per-session Slynk connection lifecycle: open, reconnect-on-demand,
;;;; call-serialisation lock, graceful close.
;;;;
;;;; Connection cache lives on the repl-eval-tool instance slot, not a global
;;;; table. get-tool-instance identity guarantees one connection per session.
;;;; Per-session call-serialisation lock on the same instance.
;;;; Fail-closed network errors; next call reopens on demand.
;;;; Graceful disconnect via slime-close at session end.
;;;; slynk-client sourced from $LISP_WORKSPACE (dispatcher-resilience patch
;;;; commit 32691172 is load-bearing — do not update from upstream without
;;;; re-verifying the patch).

(defpackage #:dsmr-mcp/src/attach/connection
  (:use #:cl)
  (:import-from #:slynk-client
                #:slime-connect
                #:slime-close
                #:slime-network-error)
  (:import-from #:dsmr-mcp/src/log
                #:log-event)
  (:export #:get-or-open-connection
           #:drop-connection
           #:close-connection
           #:parse-slynk-attach
           #:slynk-attach-configured-p))

(in-package #:dsmr-mcp/src/attach/connection)

;;; Dependency decoupling seam -----------------------------------------
;;;
;;; The slot accessors repl-eval-tool-slynk-conn and repl-eval-tool-call-lock
;;; are defined by the defclass in dsmr-mcp/src/attach/dispatch.  That package
;;; depends on this one, so importing from it would be circular.
;;;
;;; Resolution: access the accessors by name at runtime via uiop:symbol-call
;;; and fdefinition.  The two private helpers below isolate this indirection;
;;; the rest of the file reads cleanly.  Once dispatch loads, the accessor
;;; functions are interned in :dsmr-mcp/src/attach/dispatch and resolve here.

(declaim (ftype function repl-eval-tool-slynk-conn repl-eval-tool-call-lock))

(defun %conn (tool)
  "Read the slynk-conn slot on TOOL via the forward-referenced accessor.
The accessor is defined by 02-03 (dsmr-mcp/src/attach/dispatch)."
  (uiop:symbol-call :dsmr-mcp/src/attach/dispatch
                    :repl-eval-tool-slynk-conn
                    tool))

(defun (setf %conn) (value tool)
  "Write the slynk-conn slot on TOOL via the forward-referenced (setf accessor).
The accessor is defined by 02-03 (dsmr-mcp/src/attach/dispatch)."
  (funcall (fdefinition (list 'setf
                               (find-symbol "REPL-EVAL-TOOL-SLYNK-CONN"
                                            :dsmr-mcp/src/attach/dispatch)))
           value tool))

(defun %call-lock (tool)
  "Read the call-lock slot on TOOL via the forward-referenced accessor.
The accessor is defined by 02-03 (dsmr-mcp/src/attach/dispatch)."
  (uiop:symbol-call :dsmr-mcp/src/attach/dispatch
                    :repl-eval-tool-call-lock
                    tool))

;;; Config parser -----------------------------------------------------------

(defun parse-slynk-attach (attach-string)
  "Parse a \"host:port\" config string into (values HOST PORT).
When ATTACH-STRING is NIL or empty, returns (values nil nil).
HOST is the substring before the last colon; PORT is parsed as an integer.
IPv4 addresses and hostnames are supported; IPv6 literals are not (v1
assumes no colon in the host part — the last colon is always the delimiter).
Signals a plain error for a non-empty string that contains no colon."
  (when (or (null attach-string)
            (zerop (length attach-string)))
    (return-from parse-slynk-attach (values nil nil)))
  (let ((colon-pos (position #\: attach-string :from-end t)))
    (unless colon-pos
      (error "Malformed :slynk-attach value — expected \"host:port\", got: ~S"
             attach-string))
    (values (subseq attach-string 0 colon-pos)
            (parse-integer (subseq attach-string (1+ colon-pos))))))

;;; Configured-p predicate --------------------------------------------------

(defun slynk-attach-configured-p (attach-string)
  "Return non-NIL when ATTACH-STRING is a non-empty string.
Used by 02-03's with-attach-dispatch to gate the attached eval path."
  (and (stringp attach-string) (plusp (length attach-string))))

;;; Connection lifecycle ----------------------------------------------------

(defun get-or-open-connection (tool host port)
  "Return the cached slynk-connection on TOOL, opening one if NIL.
HOST and PORT come from the resolved :slynk-attach config string parsed
by parse-slynk-attach.

On cache hit, returns the existing connection immediately.
On cache miss, calls slime-connect; on failure (returns NIL) signals
slime-network-error naming the target.  On success, caches the connection
on TOOL's slynk-conn slot and logs attach.connection.opened."
  (or (%conn tool)
      (let ((conn (slime-connect host port)))
        (unless conn
          (error 'slime-network-error
                 :format-control
                 "slynk-client:slime-connect to ~A:~A returned NIL"
                 :format-arguments (list host port)))
        (setf (%conn tool) conn)
        (log-event :info "attach.connection.opened"
                   "host" host "port" port)
        conn)))

(defun drop-connection (tool &key (reason "network-error"))
  "Nil out the cached connection on TOOL without calling slime-close.
The connection is presumed dead on a network error; attempting slime-close on
a dead socket could block.  The nil slot causes the next get-or-open-connection
call to reopen on demand (fail-closed semantics).
Returns NIL."
  (setf (%conn tool) nil)
  (log-event :info "attach.connection.dropped" "reason" reason)
  nil)

(defun close-connection (tool &key (reason "session-end"))
  "Gracefully close the Slynk connection on TOOL.
Nils the slot first so concurrent calls see no connection, then calls
slime-close wrapped in handler-case so a teardown error never escapes.
Returns NIL in all cases."
  (let ((conn (%conn tool)))
    (when conn
      (setf (%conn tool) nil)
      (handler-case (slime-close conn)
        (error () nil))
      (log-event :info "attach.connection.closed" "reason" reason)))
  nil)
