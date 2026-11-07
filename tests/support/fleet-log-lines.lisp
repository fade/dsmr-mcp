;;;; tests/support/fleet-log-lines.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Fleet-log lines recorded from a host's fleet error log, shared by the
;;;; fleet-log wake's unit and cross-process tests. Each line is copied exactly
;;;; from a dated file under ~/.local/state/dsmr-mcp/host/; the comment above it
;;;; names the file and the line number.

(defpackage #:dsmr-mcp/tests/support/fleet-log-lines
  (:use #:cl)
  (:export #:*recorded-info-roster-gap*
           #:*recorded-info-recovered*
           #:*recorded-warn-memory-pressure*
           #:*recorded-error-unrelieved*))

(in-package #:dsmr-mcp/tests/support/fleet-log-lines)

;; fleet-error.log.20261013 line 64
(defparameter *recorded-info-roster-gap*
  "2026-10-13T22:18:47Z FLEET INFO code=roster-gap bus=dsmr-mcp id=/tmp/uat-deaf2/uat-deaf2 msg=recovered after 1 sighting over 655 s"
  "An INFO roster-gap note: the kind that arrives every few seconds while a
   fleet restarts.")

;; fleet-error.log.20261105 line 30
(defparameter *recorded-info-recovered*
  "2026-11-05T15:11:20Z FLEET INFO code=memory-pressure bus=- id=- msg=recovered after 1 sighting over 33 s"
  "An INFO `recovered` note closing a memory-pressure episode.")

;; fleet-error.log.20261105 line 29
(defparameter *recorded-warn-memory-pressure*
  "2026-11-05T15:10:47Z FLEET WARN code=memory-pressure bus=- id=- msg=the host is short of memory: some avg10=2.8 available=67%"
  "A WARN memory-pressure line.")

;; fleet-error.log.20261019 line 12
(defparameter *recorded-error-unrelieved*
  "2026-10-19T06:53:38Z FLEET ERROR code=memory-pressure-unrelieved bus=- id=- msg=short of memory for 61 s with no idle worker left to ask; 1 resident, 8 hibernated"
  "An ERROR memory-pressure-unrelieved line.")
