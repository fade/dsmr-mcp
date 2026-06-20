;;;; src/slynk-port.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Per-project Slynk port derivation. Every project's `.envrc` used to export a
;;;; shared literal `SLYNK_PORT=4005`, so two projects brought up in attached mode
;;;; converged on whichever single Slynk image grabbed 4005 first — silent
;;;; cross-project bleed. Deriving a stable port from the project path instead
;;;; gives each project its own listener.
;;;;
;;;; The derivation is a deterministic FNV-1a 32 hash of the absolute project path
;;;; mapped into a fixed window below the OS ephemeral range. Two properties are
;;;; load-bearing and therefore fixed by contract:
;;;;
;;;;   1. Deterministic and version-stable. The derived value is written into a
;;;;      project's `.envrc` and must reproduce byte-for-byte when a freshly
;;;;      installed dsmr-mcp recomputes it after an SBCL upgrade. SBCL's SXHASH is
;;;;      explicitly NOT contractually stable across versions, so it cannot be
;;;;      used here; FNV-1a is a fixed published spec.
;;;;   2. Below the ephemeral range. Linux allocates ephemeral client ports from
;;;;      /proc/sys/net/ipv4/ip_local_port_range (commonly 32768+). Keeping the
;;;;      window strictly below 32768 avoids colliding with transient outbound
;;;;      connections.
;;;;
;;;; Derivation makes a shared port rare, not impossible: ~3% of a 278-project
;;;; population still collide, and the rate grows on the birthday curve. The
;;;; runtime guard (the attach-resolution probe + the launcher's bump) closes that
;;;; residual; this file is only the first layer.

(defpackage #:dsmr-mcp/src/slynk-port
  (:use #:cl)
  (:export #:derive-slynk-port
           #:+slynk-port-base+
           #:+slynk-port-span+
           #:fnv1a-32))

(in-package #:dsmr-mcp/src/slynk-port)

(defconstant +slynk-port-base+ 4096
  "Low end of the derived Slynk port window. Clear of the well-known range and of
the legacy default 4005.")

(defconstant +slynk-port-span+ (- 32768 4096)
  "Width of the derived port window (28672). Base+span = 32768, the conventional
Linux ephemeral floor, so every derived port stays below it.")

(defconstant +fnv-offset-basis-32+ 2166136261
  "FNV-1a 32-bit offset basis (the published constant).")

(defconstant +fnv-prime-32+ 16777619
  "FNV-1a 32-bit prime (the published constant).")

(defun fnv1a-32 (string)
  "Return the 32-bit FNV-1a hash of STRING as an (unsigned-byte 32).
A fixed, portable spec — the same bytes in always produce the same hash, on any
Lisp and across SBCL versions, which is why it is preferred over SXHASH for a
value that persists in a project's `.envrc`."
  (let ((hash +fnv-offset-basis-32+))
    (declare (type (unsigned-byte 32) hash))
    (loop for ch across string
          do (setf hash (logand (* (logxor hash (char-code ch)) +fnv-prime-32+)
                                 #xFFFFFFFF)))
    hash))

(defun derive-slynk-port (project-path)
  "Return a deterministic Slynk port in [+slynk-port-base+, 32768) for
PROJECT-PATH, a string naming the project directory.

Keys on the absolute path rather than the project name: two projects can share a
name in different directories, but their paths differ. PROJECT-PATH is coerced to
a namestring if a pathname is supplied; a NIL or empty path signals an error
rather than collapsing every such project onto one port."
  (let ((path (typecase project-path
                (null (error "derive-slynk-port: project-path must not be NIL"))
                (pathname (namestring project-path))
                (string project-path)
                (t (princ-to-string project-path)))))
    (when (zerop (length path))
      (error "derive-slynk-port: project-path must not be empty"))
    (+ +slynk-port-base+ (mod (fnv1a-32 path) +slynk-port-span+))))
