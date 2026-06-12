;;;; src/tools/lisp-check-parens.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; MCP tool: lisp-check-parens (VERB-07/D-17).
;;;; Dual-pass paren/reader validator that reports the first imbalance or
;;;; reader error with line/column/offset. Mode-independent (dispatcher-side).
;;;;
;;;; Input: path XOR code (mutually exclusive). Path branch applies the D-16
;;;; no-root guard, the D-14 allowed-read-path sandbox check, and the 2 MB cap
;;;; (SAFETY-03). Code branch uses inline text directly (no sandbox needed).
;;;;
;;;; Wire: {ok: true} on success; {ok: false, kind, position{line,col,offset},
;;;; expected?, found?, message?} on failure. ok is CL t/nil — jzon encodes
;;;; t→true, nil→false without a json-bool wrapper.

(defpackage #:dsmr-mcp/src/tools/lisp-check-parens
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/tools/base
                #:mcp-tool
                #:mcp-tool-class
                #:tool-handle
                #:tool-session)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:make-ht
                #:result
                #:text-content)
  (:import-from #:dsmr-mcp/src/state
                #:session-project-root)
  (:import-from #:dsmr-mcp/src/project-root
                #:allowed-read-path)
  (:import-from #:dsmr-mcp/src/fs
                #:read-file-string)
  (:import-from #:dsmr-mcp/src/validate
                #:scan-parens
                #:try-reader-check
                #:*check-parens-max-bytes*)
  (:import-from #:dsmr-mcp/src/log
                #:log-event))

(in-package #:dsmr-mcp/src/tools/lisp-check-parens)

;;; ---------------------------------------------------------------------------
;;; lisp-check-parens-tool CLOS class
;;; ---------------------------------------------------------------------------

(defclass lisp-check-parens-tool (mcp-tool)
  ;; CRITICAL: use :initform on class-allocated slots, NOT :default-initargs.
  ;; c2mop:class-prototype does not apply :default-initargs; the metaclass
  ;; finalize-inheritance :after reads the prototype for the name slot.
  ((dsmr-mcp/src/tools/base::name
    :allocation :class
    :initform "lisp-check-parens")
   (dsmr-mcp/src/tools/base::description
    :allocation :class
    :initform "Check balanced parentheses and reader syntax in a Lisp file or \
inline code snippet. Reports the first imbalance or reader error with \
line/column/offset. Ignores delimiters inside double-quoted strings, ; line \
comments, and #| |# block comments. Character literals #\\x are not counted. \
Provide either path (file read under sandbox) or code (inline text) — not both.")
   (dsmr-mcp/src/tools/base::input-schema
    :allocation :class
    :initform '(:object
                :properties
                ((path
                  :type :string
                  :description "Absolute or project-relative path to a Lisp file \
(mutually exclusive with code).")
                 (code
                  :type :string
                  :description "Raw Lisp code string to check (mutually exclusive \
with path).")
                 (offset
                  :type :integer
                  :description "0-based character offset when reading from path (optional).")
                 (limit
                  :type :integer
                  :description "Maximum characters to read from path (optional)."))
                ;; Neither path nor code is individually required — the XOR
                ;; constraint is enforced in tool-handle.
                :required ())))
  (:metaclass mcp-tool-class)
  (:documentation "MCP tool: dual-pass paren/reader validator for Lisp source.
Pass 1 scans delimiter balance (parentheses, brackets, braces) while ignoring
delimiters inside strings, ; comments, and #| |# block comments (D-17).
Pass 2 runs the standard CL reader with *read-eval* nil to catch reader errors
that the paren scan misses (malformed dispatch characters, etc.). Paren errors
take priority over reader errors. Files using in-readtable are exempt from
reader checking to avoid false positives on custom syntax."))

;; Fire metaclass :after immediately so \"lisp-check-parens\" appears in
;; *tool-classes* at load time, not at first instantiation.
(c2mop:ensure-finalized (find-class 'lisp-check-parens-tool))

;;; ---------------------------------------------------------------------------
;;; Wire-envelope builder
;;; ---------------------------------------------------------------------------

(defun %build-failure-envelope (id paren-result reader-info base-offset)
  "Build the error wire envelope. Paren errors take priority over reader errors.
Every envelope carries a content text block — the client renders the result
through content alone, so a structured-fields-only response displays as
nothing."
  (destructuring-bind (&key ok kind expected found
                            (offset base-offset) (line 1) (column 1)
                       &allow-other-keys)
      paren-result
    (cond
      ((not ok)
       ;; Paren error — priority
       (let ((pos (make-ht "line"   line
                            "column" column
                            "offset" offset)))
         (let ((ht (make-ht "ok"       nil
                             "kind"     kind
                             "position" pos
                             "content"
                             (text-content
                              (format nil "~A at line ~A, column ~A (offset ~A)~
                                           ~@[ — expected ~A~]~@[, found ~A~]"
                                      kind line column offset expected found)))))
           (when expected (setf (gethash "expected" ht) expected))
           (when found    (setf (gethash "found"    ht) found))
           (result id ht))))
      (reader-info
       ;; Paren OK but reader error detected
       (let* ((r-line (getf reader-info :line))
              (r-col  (getf reader-info :column))
              (pos    (make-ht "offset" (getf reader-info :offset))))
         (when r-line (setf (gethash "line"   pos) r-line))
         (when r-col  (setf (gethash "column" pos) r-col))
         (result id (make-ht "ok"       nil
                              "kind"     (getf reader-info :kind)
                              "message"  (getf reader-info :message)
                              "position" pos
                              "content"
                              (text-content
                               (format nil "~A~@[ at line ~A~]~@[, column ~A~]: ~A"
                                       (getf reader-info :kind)
                                       r-line r-col
                                       (or (getf reader-info :message) "")))))))
      (t
       ;; Both passes clean
       (result id (make-ht "ok" t
                            "content" (text-content "balanced")))))))

;;; ---------------------------------------------------------------------------
;;; tool-handle
;;; ---------------------------------------------------------------------------

(defmethod tool-handle ((tool lisp-check-parens-tool) id args)
  (let* ((path-str  (gethash "path" args))
         (code      (gethash "code" args))
         (offset    (gethash "offset" args))
         (limit     (gethash "limit" args))
         (base-off  (or offset 0)))
    ;; Input validation: exactly one of path / code required
    (when (and path-str code)
      (return-from tool-handle
        (result id (make-ht "isError"    t
                             "error_type" "invalid-argument"
                             "content"
                             (text-content
                              "lisp-check-parens: provide either path or code, not both.")))))
    (when (and (null path-str) (null code))
      (return-from tool-handle
        (result id (make-ht "isError"    t
                             "error_type" "invalid-argument"
                             "content"
                             (text-content
                              "lisp-check-parens: either path or code is required.")))))
    ;; Obtain text (path branch applies sandbox; code branch uses inline text)
    (let ((text
           (if code
               ;; Inline code: no sandbox needed
               code
               ;; File path: D-16 no-root guard → sandbox check → read
               (let ((session (tool-session tool))
                     (root    (session-project-root (tool-session tool))))
                 (declare (ignore session))
                 (unless root
                   (return-from tool-handle
                     (result id (make-ht "isError"    t
                                          "error_type" "project-root-not-set"
                                          "content"
                                          (text-content
                                           "lisp-check-parens: no project root set. \
Call fs-set-project-root first.")))))
                 (let ((pn (allowed-read-path path-str root)))
                   (unless pn
                     (return-from tool-handle
                       (result id (make-ht "isError"    t
                                            "error_type" "sandbox-violation"
                                            "content"
                                            (text-content
                                             (format nil "lisp-check-parens: ~A is outside \
the read allow-list (project root + ASDF source dirs)." path-str))
                                            "path" path-str))))
                   (log-event :info "validate.check-parens"
                              "path" (namestring pn)
                              "offset" offset
                              "limit" limit)
                   (handler-case
                       (values (read-file-string pn :offset offset :limit limit))
                     (error (e)
                       (return-from tool-handle
                         (result id (make-ht "isError"    t
                                              "error_type" "read-error"
                                              "content"
                                              (text-content
                                               (format nil "lisp-check-parens: ~A"
                                                       (princ-to-string e)))))))))))))
      ;; SAFETY-03: reject over-size text
      (when (> (length text) *check-parens-max-bytes*)
        (return-from tool-handle
          (result id (make-ht "ok"       nil
                               "kind"     "too-large"
                               "position" (make-ht "offset" base-off
                                                    "line"   1
                                                    "column" 1)
                               "content"
                               (text-content
                                (format nil "input is ~D characters — exceeds the ~
                                             ~D-character check limit"
                                        (length text)
                                        *check-parens-max-bytes*))))))
      ;; Run both passes; apply priority
      (let ((paren-result (scan-parens text :base-offset base-off))
            (reader-info  (try-reader-check text base-off)))
        (%build-failure-envelope id paren-result reader-info base-off)))))
