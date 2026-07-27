;;;; src/bus/selector.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Bus state-root derivation: the single place that turns an optional bus name
;;;; into the directory every other bus path hangs off.
;;;;
;;;; With no name the derivation is exactly what the bus has always used, so an
;;;; unnamed bus keeps the paths it has today. With a name it is that same root
;;;; plus one directory segment, giving a bus its own write-ahead log, broker
;;;; lock, membership lock, cursors and sockets, isolated from every other bus on
;;;; the host by nothing more exotic than a different directory.
;;;;
;;;; Two guards live here and both refuse rather than repair.
;;;;
;;;; A name is checked against a small alphabet and a short reserved list. The
;;;; segment is created inside the bus root beside entries the bus already owns,
;;;; so a name like "members" or "cursors" would collide with the running bus
;;;; instead of isolating from it, and a name carrying a slash would leave the
;;;; bus directory entirely.
;;;;
;;;; The derived socket path is measured against the limit the kernel enforces on
;;;; a unix-domain socket path. ZeroMQ strips the "ipc://" scheme before binding,
;;;; so the filesystem path is what is measured. Overflowing that limit is
;;;; refused outright and never truncated: a truncated socket path still binds,
;;;; still works, and quietly resolves to a different bus than the one asked for,
;;;; which is indistinguishable from success at runtime.
;;;;
;;;; This is a leaf. It uses #:cl and uiop and nothing else, deliberately. The
;;;; standalone watcher binary depends on it, and that binary carries no ZeroMQ
;;;; transport so a sister repo needs no libzmq to arm a watcher. The three
;;;; copies of this derivation that used to live in the broker, the watcher and
;;;; the heartbeat each existed to protect that property; one leaf that imports
;;;; nothing heavy protects it just as well, without the copies.

(defpackage #:dsmr-mcp/src/bus/selector
  (:use #:cl)
  (:export #:bus-root
           #:validate-bus-name
           #:invalid-bus-name
           #:+max-bus-name-length+
           #:+max-socket-path-length+))

(in-package #:dsmr-mcp/src/bus/selector)

;;; ------------------------------------------------------------------- bounds

(defconstant +max-bus-name-length+ 32
  "How long a bus name may be. A name becomes one directory segment inside the
   bus root, so its whole cost is charged against the socket-path budget below.
   32 leaves ample room under a normal state directory while staying long enough
   for a readable fleet name, which matters because an operator reads these
   directories by hand.")

(defconstant +max-socket-path-length+ 107
  "The longest filesystem path, in characters, that a bus socket may have.

   A unix-domain socket address carries its path in a fixed 108-byte field, one
   byte of which is the NUL terminator, leaving 107 usable. ZeroMQ strips the
   \"ipc://\" scheme before binding, so what is measured is the plain filesystem
   path and not the endpoint string.

   Measured on this machine on 2026-07-27: the default endpoint
   /home/fade/.local/state/dsmr-mcp/bus/submit.ipc is 47 characters of the 107
   available, leaving about 60 for a name segment. That headroom is why a name
   can be stored literally instead of hashed, and the check below is why a
   different XDG_STATE_HOME cannot turn that assumption into a silent failure.")

(defparameter *reserved-bus-names*
  '("default" "cursors" "watch" "roster" "members"
    "bus.wal" "broker.lock" "submit.ipc" "pub.ipc" "." "..")
  "Names a bus may not take, compared case-insensitively.

   A named root is a directory created inside the bus root, beside the entries
   the unnamed bus already writes there, so any of these would land on top of
   live bus state. \"default\" is reserved for a different reason: the watcher
   prints bus=default when no name is set, so a bus actually called default
   would be unreadable in that output.")

;;; ---------------------------------------------------------------- condition

(define-condition invalid-bus-name (error)
  ((name :initarg :name :initform nil :reader invalid-bus-name-name)
   (reason :initarg :reason :initform :malformed :reader invalid-bus-name-reason)
   (detail :initarg :detail :initform nil :reader invalid-bus-name-detail))
  (:report (lambda (condition stream)
             (format stream "dsmr-mcp bus: refusing the bus name ~S. ~A"
                     (invalid-bus-name-name condition)
                     (or (invalid-bus-name-detail condition)
                         "The name is not usable as a bus directory segment."))))
  (:documentation
   "Signalled when a bus name, or the path it derives, cannot be used.

    Always signalled at derivation time and before anything is created, so a
    caller that sees this condition knows no directory, socket or lock was left
    behind. REASON carries a keyword for a caller that wants to branch; DETAIL
    carries the sentence a person reads."))

;;; --------------------------------------------------------------- validation

(defun %acceptable-name-character-p (character)
  "True for the characters a bus name may contain: alphanumerics plus hyphen,
   underscore and period. Everything else, including any separator and any
   whitespace, is refused."
  (or (alphanumericp character)
      (member character (list #\- #\_ #\.) :test #'char=)))

(defun validate-bus-name (name)
  "Return NAME if it is usable as a bus directory segment, or signal
   INVALID-BUS-NAME saying why it is not."
  (unless (stringp name)
    (error 'invalid-bus-name :name name :reason :not-a-string
                             :detail "A bus name must be a string."))
  (when (zerop (length name))
    (error 'invalid-bus-name :name name :reason :empty
                             :detail "A bus name must not be empty."))
  (when (> (length name) +max-bus-name-length+)
    (error 'invalid-bus-name
           :name name :reason :too-long
           :detail (format nil "It is ~D characters; the limit is ~D."
                           (length name) +max-bus-name-length+)))
  (let ((bad (find-if-not #'%acceptable-name-character-p name)))
    (when bad
      (error 'invalid-bus-name
             :name name :reason :bad-character
             :detail (format nil "It contains ~S; a bus name may hold only ~
                                  alphanumerics, hyphen, underscore and period."
                             bad))))
  (when (member name *reserved-bus-names* :test #'string-equal)
    (error 'invalid-bus-name
           :name name :reason :reserved
           :detail "That name is reserved by the bus state directory."))
  name)

;;; --------------------------------------------------------------- derivation

(defun %unnamed-root ()
  "The bus state directory with no name in play: $XDG_STATE_HOME/dsmr-mcp/bus/,
   falling back to ~/.local/state/dsmr-mcp/bus/. Survives a reboot."
  (let ((xdg (uiop:getenv "XDG_STATE_HOME")))
    (merge-pathnames "dsmr-mcp/bus/"
                     (if (and xdg (plusp (length xdg)))
                         (uiop:ensure-directory-pathname xdg)
                         (merge-pathnames ".local/state/" (user-homedir-pathname))))))

(defun %check-socket-path (name root)
  "Signal INVALID-BUS-NAME if a socket bound under ROOT would exceed the
   unix-domain path limit. Checked for the unnamed root too, so an over-long
   XDG_STATE_HOME is caught here rather than producing a bus nobody can bind."
  (let* ((base (namestring root))
         (derived (concatenate 'string base "submit.ipc"))
         (length (length derived)))
    (when (> length +max-socket-path-length+)
      (error 'invalid-bus-name
             :name name :reason :socket-path-too-long
             :detail (format nil "The derived socket path ~S is ~D characters, ~
                                  over the ~D the kernel allows. Nothing was ~
                                  created and nothing was shortened."
                             derived length +max-socket-path-length+))))
  root)

(defun bus-root (&optional name)
  "The state directory for the bus called NAME, as a directory pathname.

   With NAME nil or empty this is the host's unnamed bus root and reproduces the
   path the bus has always used. With a name it is that root plus a NAME/
   segment, which is the whole of how one bus is isolated from another: a
   separate write-ahead log, broker lock, membership lock, cursors directory and
   pair of sockets, all of them derived from what this returns.

   Every bus path in the tree comes through here. The broker, the standalone
   watcher binary and the heartbeat all reach this one function, and it imports
   nothing beyond cl and uiop so the watcher stays free of the ZeroMQ transport
   and a sister repo needs no libzmq installed to arm a watch.

   Signals INVALID-BUS-NAME for a malformed or reserved name, and for a name
   whose derived socket path would not fit the unix-domain limit. Creates
   nothing: a caller that wants the directory on disk asks for it separately."
  (cond ((null name)
         (%check-socket-path nil (%unnamed-root)))
        ((and (stringp name) (zerop (length name)))
         (%check-socket-path nil (%unnamed-root)))
        (t
         (let ((validated (validate-bus-name name)))
           (%check-socket-path
            validated
            (merge-pathnames (concatenate 'string validated "/")
                             (%unnamed-root)))))))
