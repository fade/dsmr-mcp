;;;; tests/protocol/tools-doc-parity-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Drift guard for docs/tools.org.
;;;;
;;;; docs/tools.org is the verb reference: every shipped tool's name,
;;;; description, and input schema. A hand-maintained reference rots the
;;;; moment a schema changes, so the doc is not hand-maintained — it is the
;;;; output of render-tools-reference, a deterministic renderer that walks the
;;;; live *tool-classes* registry and runs each tool's input-schema literal
;;;; through the same schema->json the wire (tools/list) uses. The doc is that
;;;; rendered string; tools-doc-matches-registry regenerates it and asserts
;;;; byte-equality against the committed file. Any divergence — a hand edit, or
;;;; a schema change without a doc regeneration — fails the suite.
;;;;
;;;; Determinism (so the comparison never flakes): tool names are sorted with
;;;; string<, and every JSON object's keys are emitted in sorted order, so the
;;;; rendered string is byte-stable across runs and images.

(defpackage #:dsmr-mcp/tests/protocol/tools-doc-parity-test
  (:use #:cl #:parachute)
  (:local-nicknames (#:jzon #:com.inuoe.jzon))
  (:import-from #:dsmr-mcp/src/tools/base
                #:*tool-classes*
                #:tool-name
                #:tool-description
                #:tool-input-schema)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:schema->json))

(in-package #:dsmr-mcp/tests/protocol/tools-doc-parity-test)

;;; Renderer ------------------------------------------------------------------

(defparameter +doc-preamble+
  "#+TITLE: dsmr-mcp Tool Reference

# Generated file — do not edit by hand. Every heading below is rendered from
# the live tool registry and the same schema encoder the wire (tools/list)
# uses. Edit a tool's class definition and regenerate; a hand edit will
# diverge from the schema the server actually advertises and fail the parity
# test. Regenerate instead of editing.

"
  "Fixed file header. The do-not-edit note states the regeneration behaviour as
its own rationale: the doc is mechanically derived, so a manual edit cannot
survive the next render and is therefore a drift bug. Org comment lines (lines
beginning with \"# \") carry the note without rendering into exported output.")

(defparameter +doc-postamble+
  (format nil "~%")
  "Fixed trailing newline so the file ends cleanly.")

(defun %canonicalize (value)
  "Return VALUE rewritten so com.inuoe.jzon:stringify emits it
deterministically. jzon preserves the insertion order of an equal-keyed
hash-table, so every hash-table is rebuilt with its keys inserted in
string< order; vectors (JSON arrays) are canonicalized element-wise.
Scalars pass through. This is what makes the rendered schema byte-stable
across runs and across images regardless of the hash-table iteration
order schema->json happened to produce."
  (typecase value
    (hash-table
     (let ((keys (sort (loop for k being the hash-keys of value collect k)
                       #'string<))
           (out (make-hash-table :test 'equal)))
       (dolist (k keys out)
         (setf (gethash k out) (%canonicalize (gethash k value))))))
    ((and vector (not string))
     (map 'vector #'%canonicalize value))
    (t value)))

(defun %tool-prototype (class)
  "Read CLASS's class-allocated tool descriptor off its prototype, exactly as
the metaclass registration hook does (base.lisp finalize-inheritance :after).
The name/description/input-schema slots are :allocation :class, so the
prototype carries them without instantiating a real per-session tool."
  (c2mop:class-prototype class))

(defun render-tools-reference ()
  "Render the full intended contents of docs/tools.org as a single string.

Walks *tool-classes* in string< name order. For each tool, emits a top-level
org heading \"* <name>\", the tool's description as a paragraph (skipped when
empty), and its input schema rendered as canonical, pretty-printed JSON inside
a #+begin_src json / #+end_src org source block — the schema produced by the
wire's own schema->json, so the doc matches what tools/list advertises
byte-for-byte. Wrapped in a fixed preamble/postamble so the return value is the
complete file. Deterministic by construction (sorted names, sorted JSON keys)."
  (let ((names (sort (loop for k being the hash-keys of *tool-classes* collect k)
                     #'string<)))
    (with-output-to-string (out)
      (write-string +doc-preamble+ out)
      (dolist (name names)
        (let* ((class (gethash name *tool-classes*))
               (proto (%tool-prototype class))
               (description (tool-description proto))
               (schema-json (%canonicalize
                             (schema->json (tool-input-schema proto)))))
          (format out "* ~A~%~%" (tool-name proto))
          (when (and description (plusp (length description)))
            (format out "~A~%~%" description))
          (format out "#+begin_src json~%")
          (write-string (jzon:stringify schema-json :pretty t) out)
          (format out "~%#+end_src~%~%")))
      (write-string +doc-postamble+ out))))

;;; Tests ---------------------------------------------------------------------

(define-test tools-doc-matches-registry
  "docs/tools.org must equal render-tools-reference byte-for-byte. The renderer
walks the live *tool-classes* registry and the same schema->json the wire uses,
so any drift — a hand edit, or a schema change without regenerating the doc —
fails here. The file is read from the system source tree via
asdf:system-relative-pathname; a missing file is reported as a clear string=
mismatch (empty file vs rendered content), not an unparseable error."
  (let* ((expected (render-tools-reference))
         (path (asdf:system-relative-pathname "dsmr-mcp" "docs/tools.org"))
         (actual (if (probe-file path)
                     (uiop:read-file-string path)
                     "")))
    (is string= expected actual
        "docs/tools.org is stale. Regenerate it from render-tools-reference ~
         (the doc is the renderer's output, never hand-edited).")))
