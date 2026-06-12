;;;; src/system-loader-core.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; ASDF system-loader engine shared between the attached-injection path and
;;;; the hermetic worker handler.
;;;;
;;;; Provides:
;;;;   load-system          — the in-process entry point (hermetic path calls
;;;;                          this directly; runs under its own with-timeout).
;;;;   %build-load-system-form — builds the sexp injected into the attached
;;;;                          image (attached path); contains the same
;;;;                          with-timeout + handler-bind + force/clear-fasls
;;;;                          logic as load-system, expressed as a quoted form
;;;;                          with CL-USER symbol hygiene.
;;;;   %redefinition-warning-p — recognises SBCL redefinition-warning by class
;;;;                          first, then by the "redefining ... in ..." text
;;;;                          prefix, so force-reload noise can be silently
;;;;                          muffled without hiding real warnings.
;;;;
;;;; Design notes:
;;;;   The attached path wraps asdf:load-system in sb-ext:with-timeout INSIDE
;;;;   the target image so a runaway compile is actually interrupted,
;;;;   not merely observed from the dispatcher side. sb-ext:timeout is a
;;;;   serious-condition, not error, so the load's own handler-case (error ...)
;;;;   cannot swallow it.
;;;;
;;;;   Warnings are collected non-fatally into a structured list and muffled
;;;;   off the host stderr. Errors abort the load and return the
;;;;   structured error shape. The calling tool wrapper decides how to present
;;;;   the result — load-system returns a hash-table with "status", "duration_ms",
;;;;   and either "warnings"/"warning_details" (success) or "message" (error/timeout).
;;;;
;;;;   The default timeout is 120 seconds, matching cl-mcp's default and
;;;;   providing enough headroom for large first-time compiles while bounding
;;;;   the worst-case runaway.

(defpackage #:dsmr-mcp/src/system-loader-core
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/log
                #:log-event)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:make-ht
                #:text-content)
  ;; sb-ext for with-timeout (SBCL-specific, intentional):
  (:import-from #:sb-ext)
  ;; asdf always present:
  (:import-from #:asdf)
  (:import-from #:uiop)
  (:export #:load-system
           #:%redefinition-warning-p
           #:%build-load-system-form))

(in-package #:dsmr-mcp/src/system-loader-core)

;;; ---------------------------------------------------------------------------
;;; %redefinition-warning-p
;;;
;;; Force-reload (force=true) triggers SBCL "redefining X in DEFUN" noise for
;;; every form re-evaluated. These are pure noise under an intentional reload
;;; and must be silently muffled so real warnings (style-warnings, package
;;; variances, type errors) still surface. The SBCL class check is preferred;
;;; the text prefix fallback works on other CL implementations or when the
;;; class is unavailable.
;;; ---------------------------------------------------------------------------

(defun %redefinition-warning-p (warning)
  "Return T when WARNING is an SBCL redefinition notification.
Checks the sb-kernel:redefinition-warning class first (SBCL-specific), then
falls back to a text prefix match on 'redefining ... in ...' so the filter
works across CL implementations and against string-message conditions."
  (or #+sbcl
      (let ((cls (find-class 'sb-kernel:redefinition-warning nil)))
        (and cls (typep warning cls)))
      (let ((text (ignore-errors (princ-to-string warning))))
        (and (stringp text)
             (uiop:string-prefix-p "redefining " text)
             ;; Require " in " to avoid muffling unrelated warnings that
             ;; happen to start with "redefining " (e.g. method-combination
             ;; chatter on some implementations).
             (search " in " text)))))

;;; ---------------------------------------------------------------------------
;;; %build-load-system-form
;;;
;;; Builds the sexp sent to the attached image via slime-eval (attached path).
;;; The form wraps asdf:load-system in sb-ext:with-timeout inside the image so
;;; a runaway compile is actually interrupted. All helpers are interned
;;; in CL-USER with the %DSMR-LOADER- prefix (Critical Constraint 1 from
;;; wrap-form.lisp: the slynk-client IO-package does not import our package,
;;; so any symbol not in CL or CL-USER gets package-qualified and the remote
;;; reader fails). No loop inside the form (Critical Constraint 2).
;;;
;;; The form returns one of:
;;;   (list :ok WARN-COUNT WARNS)    — load succeeded; WARNS is a list of strings
;;;   (list :timeout TIMEOUT-SECS)  — sb-ext:with-timeout fired
;;;   (list :error ERROR-STRING)    — error signalled during load
;;; ---------------------------------------------------------------------------

(defun %build-load-system-form (sys-name force clear-fasls timeout-seconds)
  "Return the sexp that, when evaluated in the attached image, loads
SYS-NAME under sb-ext:with-timeout with the given options.

FORCE when true clears loaded state before loading (force-reload).
CLEAR-FASLS when true forces full recompilation from source.
TIMEOUT-SECONDS is the number of seconds before sb-ext:with-timeout fires.

Returns (list :ok WARN-COUNT WARNS), (list :timeout TIMEOUT), or
(list :error ERROR-STRING)."
  (flet ((cs (n) (intern n (find-package :common-lisp-user))))
    (let ((s-warns    (cs "%DSMR-LOADER-WARNS"))
          (s-w        (cs "%DSMR-LOADER-W"))
          (s-e        (cs "%DSMR-LOADER-E"))
          (s-sys      (cs "%DSMR-LOADER-SYS"))
          (s-hook     (cs "%DSMR-LOADER-DEBUG-HOOK"))
          (s-c        (cs "%DSMR-LOADER-C"))
          (s-h        (cs "%DSMR-LOADER-H")))
      ;; Debugger backstop around the whole load: anything that would enter
      ;; the image's debugger despite the handler-case (BREAK or a direct
      ;; INVOKE-DEBUGGER in compile-time code of the system being loaded)
      ;; is converted to the (:error MSG) arm via throw.  A parked debugger
      ;; in a rex worker hangs the batch client forever; see wrap-form.lisp
      ;; for the full rationale.  This form already requires an SBCL target
      ;; (sb-ext:with-timeout), so SB-EXT:*INVOKE-DEBUGGER-HOOK* — the hook
      ;; BREAK cannot bypass — is referenced directly.
      `(catch :%dsmr-loader-debug-unwind
         (let ((,s-hook (lambda (,s-c ,s-h)
                          (declare (ignore ,s-h))
                          (throw :%dsmr-loader-debug-unwind
                            (list :error
                                  (or (ignore-errors
                                        (map 'string #'identity
                                             (princ-to-string ,s-c)))
                                      "<error formatting condition>"))))))
           (let ((*debugger-hook* ,s-hook)
                 (sb-ext:*invoke-debugger-hook* ,s-hook))
             (handler-case
                 (sb-ext:with-timeout ,(or timeout-seconds 120)
             ;; Force-reload: clear loaded state so changed definitions
             ;; are recompiled and become live.
             ,@(when force
                 `((when (member ,sys-name (asdf:already-loaded-systems)
                                 :test #'string-equal)
                     (asdf:clear-system ,sys-name))))
             ;; Clear-fasls: wipe the image's ASDF output cache so the
             ;; next load triggers a full source recompile. Runs in-image
             ;; so it clears the image's cache, not the dispatcher's.
             ,@(when clear-fasls
                 `((let ((,s-sys (asdf:find-system ,sys-name nil)))
                     (when ,s-sys
                       (asdf:clear-system ,sys-name)))))
             ;; collect warnings non-fatally, muffle off host stderr.
             ;; do not muffle errors (they abort and flow to the error arm).
             (let ((,s-warns nil))
               (handler-bind
                   ((warning (lambda (,s-w)
                               (push (map 'string #'identity
                                          (princ-to-string ,s-w))
                                     ,s-warns)
                               (when (find-restart 'muffle-warning)
                                 (invoke-restart 'muffle-warning)))))
                       ,(if clear-fasls
                            `(asdf:load-system ,sys-name :force t)
                            `(asdf:load-system ,sys-name)))
                     (list :ok (length ,s-warns) (nreverse ,s-warns))))
               ;; sb-ext:timeout is a serious-condition, not error — the
               ;; earlier-clause rule routes it here, not to the arm below.
               (sb-ext:timeout ()
                 (list :timeout ,(or timeout-seconds 120)))
               ;; serious-condition, not error: STORAGE-CONDITION and
               ;; SB-SYS:INTERACTIVE-INTERRUPT are serious-but-not-error and
               ;; would otherwise reach the image's debugger.
               (serious-condition (,s-e)
                 (list :error (map 'string #'identity
                                   (princ-to-string ,s-e)))))))))))

;;; ---------------------------------------------------------------------------
;;; load-system
;;;
;;; In-process entry point used by the hermetic worker handler. The worker is
;;; already in-process, so this runs the same logic as the injected form but
;;; as ordinary CL code rather than a quoted form. Wraps the work in
;;; sb-ext:with-timeout so a runaway compile is interrupted in the worker
;;; (the pool's pool-rpc-with-hard-kill provides the outer hard-kill backstop).
;;;
;;; Returns a hash-table with:
;;;   "status"          : "loaded" | "timeout" | "error"
;;;   "system"          : sys-name string
;;;   "duration_ms"     : elapsed time in milliseconds
;;;   "forced"          : boolean (on success)
;;;   "warnings"        : integer warning count (on success)
;;;   "warning_details" : list of warning message strings, when count > 0
;;;   "message"         : error/timeout message string (on error/timeout)
;;; ---------------------------------------------------------------------------

(defun load-system (sys-name &key (force t) (clear-fasls nil) (timeout-seconds 120))
  "Load ASDF system SYS-NAME in-process with structured result.

FORCE (default true) clears loaded state before loading so changed files
are picked up. CLEAR-FASLS forces full recompilation from source.
TIMEOUT-SECONDS defaults to 120; the load is wrapped in sb-ext:with-timeout
so a runaway compile is actually interrupted rather than polled.

Warnings are collected non-fatally via handler-bind and muffled off the
host stderr. Errors abort the load and return status=error. A timeout
returns status=timeout."
  (check-type sys-name string)
  (let ((sys-name  (string-downcase sys-name))
        (start     (get-internal-real-time))
        (warns     nil))
    (log-event :info "load-system" "system" sys-name "force" force
               "clear_fasls" clear-fasls "timeout" timeout-seconds)
    (flet ((elapsed-ms ()
             (round (* 1000 (/ (- (get-internal-real-time) start)
                               internal-time-units-per-second))))
           (collect-warning (w)
             ;; Filter redefinition noise when force=true to avoid drowning
             ;; real warnings in hundreds of "redefining X in DEFUN" lines.
             (unless (and force (%redefinition-warning-p w))
               (push (map 'string #'identity (princ-to-string w)) warns))
             (when (find-restart 'muffle-warning)
               (invoke-restart 'muffle-warning))))
      (handler-case
          (sb-ext:with-timeout (or timeout-seconds 120)
            ;; Force-reload: clear loaded state so edits become live.
            (when (and force
                       (member sys-name (asdf:already-loaded-systems)
                               :test #'string-equal))
              (let ((asd-src (ignore-errors
                               (asdf:system-source-file
                                (asdf:find-system sys-name nil)))))
                (asdf:clear-system sys-name)
                (when asd-src
                  (ignore-errors (asdf:load-asd asd-src)))))
            ;; collect warnings non-fatally, muffle off host stderr.
            (handler-bind ((warning #'collect-warning))
              (if clear-fasls
                  (asdf:load-system sys-name :force t)
                  (asdf:load-system sys-name)))
            ;; Build success result hash-table.
            (let* ((elapsed  (elapsed-ms))
                   (n-warns  (length warns))
                   (ht       (make-ht "status"   "loaded"
                                      "system"   sys-name
                                      "duration_ms" elapsed
                                      "forced"   force
                                      "warnings" n-warns)))
              (when (plusp n-warns)
                (setf (gethash "warning_details" ht) (nreverse warns)))
              (log-event :info "load-system-complete"
                         "system" sys-name "duration_ms" elapsed
                         "warnings" n-warns)
              ht))
        ;; sb-ext:timeout is a serious-condition that passes through any
        ;; inner (error ...) handler-case arms without being caught by them,
        ;; so this arm reliably fires on true compile timeouts.
        (sb-ext:timeout ()
          (let ((elapsed (elapsed-ms)))
            (log-event :warn "load-system-timeout"
                       "system" sys-name "timeout" timeout-seconds)
            (make-ht "status"      "timeout"
                     "system"      sys-name
                     "duration_ms" elapsed
                     "message"     (format nil "Load timed out after ~A seconds"
                                           (or timeout-seconds 120)))))
        (error (e)
          (let ((elapsed  (elapsed-ms))
                (msg      (map 'string #'identity (princ-to-string e))))
            (log-event :error "load-system-error" "system" sys-name "error" msg)
            (make-ht "status"      "error"
                     "system"      sys-name
                     "duration_ms" elapsed
                     "message"     msg)))))))
