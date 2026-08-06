;;;; tests/bus/zmq-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Zebra tests for the ZeroMQ bus transport. In-process round trips over
;;;; ipc://: PUSH/PULL (client→broker submit) delivers every part in order;
;;;; PUB/SUB (broker→subscriber fan-out) delivers a live message; a quiet socket
;;;; returns NIL at its receive timeout rather than blocking. libzmq is a core
;;;; dependency of the bus, so these run in the fast suite; the multi-process
;;;; failover round trip lives in the slow integration suite.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/bus/zmq-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/bus/zmq-test
  (:use #:cl #:zebra)
  (:local-nicknames (#:tz #:dsmr-mcp/src/bus/zmq)))

(in-package #:dsmr-mcp/tests/bus/zmq-test)

(defvar *endpoint-counter* 0)

(defun fresh-endpoint ()
  "A unique ipc:// endpoint under the temp dir for one test."
  (format nil "ipc://~Adsmr-bus-zmq-~A-~A.ipc"
          (namestring (uiop:temporary-directory))
          (sb-posix:getpid)
          (incf *endpoint-counter*)))

(defun s (octets)
  "Decode received octets to a string for comparison."
  (and octets (sb-ext:octets-to-string octets :external-format :utf-8)))

(define-test push-pull-delivers-in-order
  "Every part PUSHed by a client arrives at the broker's PULL intake, in order."
  (let* ((addr (fresh-endpoint))
         (intake (tz:make-intake addr :timeout-ms 500))
         (submitter (tz:make-submitter addr)))
    (unwind-protect
         (let ((n 50))
           (dotimes (i n) (tz:send-message submitter (format nil "m~D" i)))
           (let ((got (loop repeat n collect (s (tz:recv-message intake)))))
             (is equal (loop for i below n collect (format nil "m~D" i)) got)))
      (tz:close-endpoint submitter)
      (tz:close-endpoint intake))))

(define-test quiet-intake-times-out-to-nil
  "A PULL intake with nothing to read returns NIL at its timeout, not an error."
  (let* ((addr (fresh-endpoint))
         (intake (tz:make-intake addr :timeout-ms 50)))
    (unwind-protect
         (is eq nil (tz:recv-message intake))
      (tz:close-endpoint intake))))

(define-test pub-sub-delivers-live-message
  "A subscriber connected to the broker's publisher receives a fanned-out
   message. PUB/SUB has a slow-joiner window, so the publisher resends until the
   subscription has propagated or the overall deadline passes."
  (let* ((addr (fresh-endpoint))
         (publisher (tz:make-publisher addr))
         (feed (tz:make-feed addr :timeout-ms 50)))
    (unwind-protect
         (let ((received nil)
               (deadline (+ (get-internal-real-time)
                            (* 3 internal-time-units-per-second))))
           (loop until (or received (> (get-internal-real-time) deadline))
                 do (tz:send-message publisher "live")
                    (let ((msg (tz:recv-message feed)))
                      (when msg (setf received (s msg)))))
           (is string= "live" received))
      (tz:close-endpoint feed)
      (tz:close-endpoint publisher))))

(define-test binary-clean-payload
  "Transport carries arbitrary bytes intact, not just text."
  (let* ((addr (fresh-endpoint))
         (intake (tz:make-intake addr :timeout-ms 500))
         (submitter (tz:make-submitter addr))
         (payload (make-array 5 :element-type '(unsigned-byte 8)
                                :initial-contents '(0 255 16 0 7))))
    (unwind-protect
         (progn
           (tz:send-message submitter payload)
           (let ((got (tz:recv-message intake)))
             (is equalp payload got)))
      (tz:close-endpoint submitter)
      (tz:close-endpoint intake))))