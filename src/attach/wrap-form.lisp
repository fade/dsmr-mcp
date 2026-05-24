;;;; src/attach/wrap-form.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Builds the wrapping form sent to the remote Slynk image via slime-eval,
;;;; plus the dispatcher-side truncate-output / sanitize-control-chars helpers.
;;;; Re-implemented from cl-mcp/src/attach.lisp §222-358 (MIT) under AGPL.
;;;;
;;;; Enhancements over the cl-mcp attach path:
;;;;   handler-bind (not handler-case) so the stack is live at capture time.
;;;;   all multiple values collected, not just last.
;;;;   end-of-file conditions annotated with stdin hint.
;;;;   symbol prefix changed to %DSMR-MCP-ATTACH-.
;;;;   *read-eval* seam left clean for a future safety pass.
;;;;
;;;; Full 7-stream rebinding — *standard-output* *error-output*
;;;;   *trace-output* *debug-io* *query-io* *terminal-io*
;;;;   *standard-input* — so TUI applications in the attached image
;;;;   never corrupt the dispatcher's JSON-RPC stdout channel.
;;;;   (cl-mcp commit 0797438c rationale)
;;;;
;;;; truncate-output / sanitize-control-chars live here and are called
;;;; by the dispatcher AFTER the result returns from the remote image
;;;; (not inside the wrap-form itself).

(defpackage #:dsmr-mcp/src/attach/wrap-form
  (:use #:cl)
  (:import-from #:cl-ppcre #:regex-replace-all)
  (:import-from #:dsmr-mcp/src/attach/registry
                #:build-registry-ensure-form
                #:build-register-result-form)
  (:export #:build-wrapping-form
           #:truncate-output
           #:sanitize-control-chars
           #:*default-max-output-length*))

(in-package #:dsmr-mcp/src/attach/wrap-form)

;;; Output length knob -------------------------------------------------------

(defparameter *default-max-output-length* 50000
  "Default maximum characters for captured output strings (stdout, stderr,
printed values).  Prevents unbounded output from exhausting memory or
flooding the JSON-RPC wire.  50 KB matches cl-mcp's *default-max-output-length*.")

;;; Control-character sanitisation ------------------------------------------
;;;
;;; Re-implemented from cl-mcp/src/utils/sanitize.lisp §27-125 (MIT) under
;;; AGPL.  Strips ANSI/ECMA-48 escape sequence families (CSI, OSC, DCS, SOS,
;;; PM, APC, and 2-byte ESC sequences), control chars 0-31 (keeping tab,
;;; newline, CR), DEL (127), and replaces code points above the BMP with
;;; U+FFFD.  Applied by truncate-output before strings cross the wire.

(defun %strip-ansi (string)
  "Remove ANSI/ECMA-48 escape sequences from STRING via cl-ppcre.
Handles CSI (ESC [), OSC (ESC ]), DCS/SOS/PM/APC (ESC P/X/^/_),
and bare 2-byte ESC + 0x40-0x5F sequences."
  ;; CSI: ESC [ <params> <final 0x40-0x7E>
  (let ((s (regex-replace-all "\\x1b\\[[^\\x40-\\x7e]*[\\x40-\\x7e]" string "")))
    ;; OSC: ESC ] <text> BEL or ESC \
    (setf s (regex-replace-all "\\x1b\\][^\\a\\x1b]*(?:\\a|\\x1b\\\\)" s ""))
    ;; DCS/SOS/PM/APC: ESC [P X ^ _] <text> ESC \
    (setf s (regex-replace-all "\\x1b[PX\\^_][^\\x1b]*(?:\\x1b\\\\)?" s ""))
    ;; Remaining 2-byte ESC sequences (ESC + 0x40-0x5F, e.g. SS2 ESC N, SS3 ESC O)
    (setf s (regex-replace-all "\\x1b[\\x40-\\x5f]" s ""))
    ;; Bare ESC not consumed above
    (setf s (regex-replace-all "\\x1b" s ""))
    s))

(defun sanitize-control-chars (string)
  "Remove characters that are invalid in JSON strings from STRING.
Strips ANSI/ECMA-48 escape sequences first (via cl-ppcre regex), then
scans char-by-char: drops control codes 0-31 except tab (#x09),
newline (#x0A), and carriage return (#x0D); drops DEL (#x7F); replaces
supplemental-plane code points (> U+FFFF) with U+FFFD.

Returns STRING unchanged when it contains no problematic characters (fast
path).  Returns NIL when given NIL."
  (when (null string) (return-from sanitize-control-chars nil))
  (unless (stringp string)
    (return-from sanitize-control-chars
      (sanitize-control-chars (princ-to-string string))))
  ;; Fast path: scan for anything that needs work.
  (let ((needs-work nil)
        (len (length string)))
    (dotimes (i len)
      (let ((code (char-code (char string i))))
        (when (or (= code 27)          ; ESC — possible ANSI prefix
                  (and (< code 32)
                       (/= code 9)     ; keep tab
                       (/= code 10)    ; keep newline
                       (/= code 13))   ; keep CR
                  (= code 127)         ; DEL
                  (> code #xFFFF))     ; supplemental plane
          (setf needs-work t)
          (return))))
    (unless needs-work (return-from sanitize-control-chars string)))
  ;; Full path: strip ANSI sequences, then char-by-char control-code pass.
  (let* ((stripped (%strip-ansi string))
         (result (make-array (length stripped) :element-type 'character
                                               :fill-pointer 0 :adjustable t))
         (slen (length stripped)))
    (dotimes (i slen)
      (let* ((char (char stripped i))
             (code (char-code char)))
        (cond
          ;; Keep allowed whitespace
          ((member char '(#\Tab #\Newline #\Return))
           (vector-push-extend char result))
          ;; Drop remaining control codes 0-31
          ((< code 32))
          ;; Drop DEL
          ((= code 127))
          ;; Replace supplemental plane with U+FFFD
          ((> code #xFFFF)
           (vector-push-extend (code-char #xFFFD) result))
          ;; Pass everything else through
          (t
           (vector-push-extend char result)))))
    (coerce result 'string)))

;;; Output truncation --------------------------------------------------------
;;;
;;; Re-implemented from cl-mcp/src/repl-core.lisp §59-69 (MIT) under AGPL.
;;; Truncate BEFORE sanitising — avoids sanitising data that will be
;;; discarded, which can be a 5x speedup on large captured outputs.

(defun truncate-output (string max-output-length)
  "Truncate STRING to MAX-OUTPUT-LENGTH chars then sanitize control characters.
Appends the literal marker \"...(truncated)\" when truncation occurs.
When MAX-OUTPUT-LENGTH is not a positive integer, sanitize only (no cap).
Returns NIL when STRING is NIL."
  (if (and max-output-length
           (integerp max-output-length)
           (> (length string) max-output-length))
      (concatenate 'string
                   (sanitize-control-chars (subseq string 0 max-output-length))
                   "...(truncated)")
      (sanitize-control-chars string)))

;;; Wrap-form builder --------------------------------------------------------
;;;
;;; Re-implemented from cl-mcp/src/attach.lisp §222-358 (MIT) under AGPL.
;;;
;;; CRITICAL CONSTRAINTS (cl-mcp attach.lisp §247-266 docstring):
;;;
;;; 1. Every helper symbol used INSIDE the returned form is interned in
;;;    CL-USER via (intern name (find-package :common-lisp-user)) with the
;;;    %DSMR-MCP-ATTACH- prefix.  slynk-client's slime-net-send
;;;    prints the form with *package* bound to an IO-package that imports
;;;    only nil/t/quote.  Any symbol not in CL or CL-USER gets
;;;    package-qualified with the dispatcher's home package
;;;    (DSMR-MCP/SRC/ATTACH/WRAP-FORM::...), which the remote reader cannot
;;;    resolve.
;;;
;;; 2. Use do*/do (NOT loop) for reader and eval loops inside the returned
;;;    form.  loop keywords (for, in, collect, with) are NOT CL symbols —
;;;    they print as CL-USER::FOR etc. under the IO-package, and the remote
;;;    reader sees those as unknown symbols, not loop syntax.  (Verified by
;;;    with-standard-io-syntax tests in the REPL.)
;;;
;;; 3. The form is pure CL + SB-* (no dsmr-mcp symbols), so it can be
;;;    locally eval'd in the test suite AND sent to a real remote image.
;;;
;;; Block/return structure note:
;;;    The handler-bind error handlers use (return) to exit an enclosing
;;;    (block nil ...) early (the stack is still live at that point).
;;;    The 6-element (list ...) result is the THIRD body form of the outer
;;;    let*, placed AFTER the ensure prologue and the block, so it always
;;;    executes — whether the block completed normally (s-err-ctx = nil) or
;;;    via (return) (s-err-ctx set).

(defun build-wrapping-form (code-string &optional package-name
                                        &key (register-result t) session-id)
  "Return the s-expression to pass to slynk-client:slime-eval.

The remote evaluation produces a 6-element list:
  (printed raw stdout stderr error-context raw-id)

  printed       : prin1-to-string of all values from all evaluated forms,
                  values within a form separated by \", \", forms by newline.
  raw           : same as printed (wire-safe, avoids #<...> reader errors).
  stdout        : captured *standard-output* + *trace-output* + *terminal-io*
                  + *debug-io* + *query-io* output.
  stderr        : captured *error-output*.
  error-context : NIL on success; on error a plist
                  (:condition-type S :message S
                   :restarts ((:name S :description S) ...)
                   :frames   ((:index N :function S :locals L) ...))
  raw-id        : integer handle-table ID when REGISTER-RESULT is true and the
                  last form's first value is inspectable (not a number, string,
                  symbol, or character); NIL otherwise.

CODE-STRING is the source text; one or more top-level forms are read from it.
PACKAGE-NAME is the evaluation package name (string); defaults to \"CL-USER\".
REGISTER-RESULT when true (the default) registers the last form's first return
  value in the image-resident DSMR-MCP-ATTACH-REGISTRY table and returns its
  raw integer ID as the 6th element.  Pass :register-result nil to suppress
  registration for hot loops or uninteresting results.
SESSION-ID is the dsmr session identifier embedded in the table entry for
  isolation between concurrent sessions sharing one image.

*read-eval* SEAM: *read-eval* is T in the reader call below (trusted
  localhost posture).  A future safety pass will wrap the
  with-input-from-string reader call with (*read-eval* nil) without
  needing to reshape the wrapper."
  (flet ((cl-user-sym (name)
           (intern name (find-package :common-lisp-user))))
    ;; Intern every helper symbol in CL-USER before building the backquote
    ;; — keeps all variable symbols out of this package's namespace in
    ;; the printed form; see Critical Constraint 1 above.
    (let ((s-stdout    (cl-user-sym "%DSMR-MCP-ATTACH-STDOUT"))
          (s-stderr    (cl-user-sym "%DSMR-MCP-ATTACH-STDERR"))
          (s-io        (cl-user-sym "%DSMR-MCP-ATTACH-IO"))
          (s-err-ctx   (cl-user-sym "%DSMR-MCP-ATTACH-ERROR-CONTEXT"))
          (s-all-vals  (cl-user-sym "%DSMR-MCP-ATTACH-ALL-VALS"))
          (s-printed   (cl-user-sym "%DSMR-MCP-ATTACH-PRINTED"))
          (s-pkg-name  (cl-user-sym "%DSMR-MCP-ATTACH-PKG-NAME"))
          (s-pkg       (cl-user-sym "%DSMR-MCP-ATTACH-PKG"))
          (s-forms     (cl-user-sym "%DSMR-MCP-ATTACH-FORMS"))
          (s-stream    (cl-user-sym "%DSMR-MCP-ATTACH-STREAM"))
          (s-eof       (cl-user-sym "%DSMR-MCP-ATTACH-EOF"))
          (s-acc       (cl-user-sym "%DSMR-MCP-ATTACH-ACC"))
          (s-read-form (cl-user-sym "%DSMR-MCP-ATTACH-READ-FORM"))
          (s-rest      (cl-user-sym "%DSMR-MCP-ATTACH-REST"))
          (s-cond      (cl-user-sym "%DSMR-MCP-ATTACH-CONDITION"))
          ;; Restarts do-loop variables
          (s-rlist     (cl-user-sym "%DSMR-MCP-ATTACH-RLIST"))
          (s-racc      (cl-user-sym "%DSMR-MCP-ATTACH-RACC"))
          ;; Frames variables (SBCL only)
          (s-frames    (cl-user-sym "%DSMR-MCP-ATTACH-FRAMES"))
          (s-fidx      (cl-user-sym "%DSMR-MCP-ATTACH-FRAME-IDX"))
          (s-fcap      (cl-user-sym "%DSMR-MCP-ATTACH-FRAME-CAP"))
          (s-map-fn    (cl-user-sym "%DSMR-MCP-ATTACH-MAP-FN"))
          (s-frame     (cl-user-sym "%DSMR-MCP-ATTACH-FRAME"))
          ;; Local value print truncation variables
          (s-vstr      (cl-user-sym "%DSMR-MCP-ATTACH-VSTR"))
          (s-vlen      (cl-user-sym "%DSMR-MCP-ATTACH-VLEN"))
          ;; All-vals variable and locals accumulator for frame walk
          (s-vals      (cl-user-sym "%DSMR-MCP-ATTACH-VALS"))
          (s-lacc      (cl-user-sym "%DSMR-MCP-ATTACH-LACC")))
      ;;
      ;; The returned form has three body forms in the outer let*:
      ;;   1. (unless ...) — registry-ensure prologue; idempotent ANSI form
      ;;      that installs DSMR-MCP-ATTACH-REGISTRY in the image if absent.
      ;;   2. (block nil ...) — runs the eval/capture logic; error handlers
      ;;      call (return) to exit early with s-err-ctx set.
      ;;   3. (list ...) — always executes after the block, whether the
      ;;      block exited normally or via (return).
      ;;
      `(let* ((,s-stdout  (make-string-output-stream))
              (,s-stderr  (make-string-output-stream))
              ;; s-io: two-way stream — reads see empty input,
              ;; writes to *debug-io*/*query-io*/*terminal-io* land in
              ;; the stdout buffer (TUI-safe stream isolation).
              (,s-io      (make-two-way-stream (make-string-input-stream "") ,s-stdout))
              (,s-err-ctx nil)
              (,s-all-vals nil)
              (,s-printed nil))
         ;;
         ;; BODY FORM 1: registry-ensure prologue (idempotent, ANSI, pure CL).
         ;; Installs DSMR-MCP-ATTACH-REGISTRY in the attached image if absent;
         ;; no-op on subsequent evals (self-healing after reconnect to fresh image).
         ;;
         ,(build-registry-ensure-form)
         ;;
         ;; BODY FORM 2: the eval/capture block.
         ;; *read-eval* is T here — a future safety pass can wrap the
         ;; with-input-from-string reader call with (*read-eval* nil).
         ;;
         (block nil
           (let* ((,s-pkg-name ,(or package-name "CL-USER"))
                  (,s-pkg (or (find-package ,s-pkg-name)
                              (error "Package ~S not found in the attached image"
                                     ,s-pkg-name)))
                  ;; Read all forms from CODE-STRING using do* (not loop —
                  ;; see Critical Constraint 2 above).
                  (,s-forms
                    (let ((*package* ,s-pkg))
                      (with-input-from-string (,s-stream ,code-string)
                        (do* ((,s-eof  '#:eof)
                              (,s-acc  nil)
                              (,s-read-form (read ,s-stream nil ,s-eof)
                                            (read ,s-stream nil ,s-eof)))
                             ((eq ,s-read-form ,s-eof) (nreverse ,s-acc))
                          (push ,s-read-form ,s-acc))))))
             ;; handler-bind (not handler-case!) so the stack is live when
             ;; the handler runs — restarts and frames are non-nil.
             (handler-bind
                 ;; end-of-file: annotate with the stdin-empty hint.
                 ((end-of-file
                    (lambda (,s-cond)
                      (setf ,s-err-ctx
                            (list :condition-type
                                  (prin1-to-string (type-of ,s-cond))
                                  :message
                                  (concatenate 'string
                                               (handler-case (princ-to-string ,s-cond)
                                                 (error () "<error formatting condition>"))
                                               " [attached eval has no interactive *standard-input*]")
                                  :restarts
                                  ;; do-based restarts collector (not loop —
                                  ;; Critical Constraint 2).
                                  (do ((,s-rlist (compute-restarts) (cdr ,s-rlist))
                                       (,s-racc  nil))
                                      ((null ,s-rlist) (nreverse ,s-racc))
                                    (push (list :name
                                                (string (restart-name (car ,s-rlist)))
                                                :description
                                                (or (ignore-errors
                                                      (princ-to-string (car ,s-rlist)))
                                                    ""))
                                          ,s-racc))
                                  :frames nil))
                      (return)))
                  ;; error: full restarts + SBCL backtrace.
                  (error
                    (lambda (,s-cond)
                      (setf ,s-err-ctx
                            (list :condition-type
                                  (prin1-to-string (type-of ,s-cond))
                                  :message
                                  (handler-case (princ-to-string ,s-cond)
                                    (error () "<error formatting condition>"))
                                  :restarts
                                  ;; do-based restarts collector (not loop).
                                  (do ((,s-rlist (compute-restarts) (cdr ,s-rlist))
                                       (,s-racc  nil))
                                      ((null ,s-rlist) (nreverse ,s-racc))
                                    (push (list :name
                                                (string (restart-name (car ,s-rlist)))
                                                :description
                                                (or (ignore-errors
                                                      (princ-to-string (car ,s-rlist)))
                                                    ""))
                                          ,s-racc))
                                  ;; Frames: SBCL only, resolved at runtime via
                                  ;; fdefinition/find-symbol to avoid a hard
                                  ;; compile-time SB-DEBUG dep.
                                  ;; Cap: 20 frames; per-value locals truncated at ~200 chars.
                                  ;; #-sbcl: nil fallback.
                                  :frames
                                  #+sbcl
                                  (let ((,s-map-fn
                                          (ignore-errors
                                            (fdefinition
                                             (find-symbol "MAP-BACKTRACE"
                                                          "SB-DEBUG")))))
                                    (when ,s-map-fn
                                      (let ((,s-frames nil)
                                            (,s-fidx   0)
                                            (,s-fcap   20))
                                        (funcall ,s-map-fn
                                                 (lambda (,s-frame)
                                                   (when (< ,s-fidx ,s-fcap)
                                                     (push
                                                      (list :index ,s-fidx
                                                            :function
                                                            (handler-case
                                                                (prin1-to-string
                                                                 (sb-di:debug-fun-name
                                                                  (sb-di:frame-debug-fun
                                                                   ,s-frame)))
                                                              (error () "<unknown>"))
                                                            :locals
                                                            (ignore-errors
                                                              (let ((,s-lacc nil))
                                                                (sb-di:do-debug-fun-vars
                                                                    (,s-vals
                                                                     (sb-di:frame-debug-fun
                                                                      ,s-frame))
                                                                  (when (eq
                                                                         (sb-di:debug-var-validity
                                                                          ,s-vals
                                                                          (sb-di:frame-code-location
                                                                           ,s-frame))
                                                                         :valid)
                                                                    (push
                                                                     (list :name
                                                                           (symbol-name
                                                                            (sb-di:debug-var-symbol
                                                                             ,s-vals))
                                                                           :value
                                                                           (let* ((,s-vstr
                                                                                    (handler-case
                                                                                        (let ((*print-level*  3)
                                                                                              (*print-length* 10))
                                                                                          (prin1-to-string
                                                                                           (sb-di:debug-var-value
                                                                                            ,s-vals ,s-frame)))
                                                                                      (error ()
                                                                                        "<unreadable>")))
                                                                                  (,s-vlen
                                                                                    (length ,s-vstr)))
                                                                             (if (> ,s-vlen 200)
                                                                                 (subseq ,s-vstr 0 200)
                                                                                 ,s-vstr)))
                                                                     ,s-lacc)))
                                                                (nreverse ,s-lacc))))
                                                      ,s-frames)
                                                     (incf ,s-fidx))))
                                        (nreverse ,s-frames))))
                                  #-sbcl nil))
                      (return))))
               ;; FULL 7-stream rebinding — all interactive and standard
               ;; streams shadowed so TUI applications and Quicklisp banners in
               ;; the attached image never reach the dispatcher's JSON-RPC stdout.
               (let ((*standard-output* ,s-stdout)
                     (*error-output*    ,s-stderr)
                     (*trace-output*    ,s-stdout) ; trace → stdout buffer
                     (*debug-io*        ,s-io)
                     (*query-io*        ,s-io)
                     (*terminal-io*     ,s-io)     ; TUI-safe
                     (*standard-input*  (make-string-input-stream ""))
                     (*package*         ,s-pkg))
                 ;; Eval loop: collect ALL values from ALL forms using
                 ;; do (not loop — Critical Constraint 2).
                 (do ((,s-rest ,s-forms (cdr ,s-rest)))
                     ((null ,s-rest))
                   (push (multiple-value-list (eval (car ,s-rest)))
                         ,s-all-vals)))
               ;; Success path: format the printed value string.
               (setf ,s-all-vals (nreverse ,s-all-vals))
               ;; Format: values within a form separated by ", ",
               ;; forms by newline.
               (let ((*print-readably* nil) (*print-circle* t))
                 (setf ,s-printed
                       (format nil "~{~{~A~^, ~}~^~%~}"
                               (mapcar (lambda (,s-vals)
                                         (mapcar #'prin1-to-string ,s-vals))
                                       ,s-all-vals))))))) ; closes: inner-mapcar, lambda,
                                                          ;   outer-mapcar, format, setf,
                                                          ;   let (*print-readably*), block
         ;;
         ;; BODY FORM 3 of outer let* — always executes after the block.
         ;; When (return) fires in a handler-bind clause, the block above exits
         ;; (returning nil) with s-err-ctx set and s-printed nil.  This form
         ;; runs regardless, producing the wire tuple.
         ;; raw == printed: avoids #<...> reader errors on round-trip.
         ;; The 6th element is the raw integer handle-table ID, or nil.
         (list ,s-printed
               ,s-printed                            ; raw = printed
               (get-output-stream-string ,s-stdout)  ; stdout
               (get-output-stream-string ,s-stderr)  ; stderr
               ,s-err-ctx                            ; error-context or nil
               ;; 6th element: register the last form's first return value.
               ;; The build-register-result-form call runs at macro-expansion time
               ;; (dispatcher side) to produce the injected sexp; the generated
               ;; sexp runs in the attached image and returns the raw-id integer.
               ;; When register-result is nil, the 6th element is literally nil.
               ,(when register-result
                  (build-register-result-form
                   `(when (and (null ,s-err-ctx) ,s-all-vals)
                      (car (car ,s-all-vals)))
                   (or session-id ""))))))))   ; closes: list, outer-let*, flet, defun
