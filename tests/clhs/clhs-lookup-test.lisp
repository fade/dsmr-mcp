;;;; tests/clhs/clhs-lookup-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Parachute tests for the clhs-lookup verb (VERB-09): section filename
;;;; math, section-vs-symbol auto-detection, local content extraction
;;;; (guarded on a resolvable HyperSpec), and the fail-closed not-found path.
;;;;
;;;; The content-dependent cases are guarded by with-clhs-or-skip so the suite
;;;; is green with OR without a HyperSpec install and never triggers a network
;;;; :clhs auto-install in CI.

;; Package evolution guard: drop a stale package so re-loading this leaf into a
;; warm image picks up an evolved import list instead of erroring on conflicts.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/clhs/clhs-lookup-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/clhs/clhs-lookup-test
  (:use #:cl #:parachute)
  (:import-from #:dsmr-mcp/src/clhs
                #:clhs-lookup
                #:%section-to-filename
                #:%section-number-p))

(in-package #:dsmr-mcp/tests/clhs/clhs-lookup-test)

;;; --- HyperSpec availability guard ------------------------------------------

(defun %hyperspec-available-p ()
  "T iff the 3-tier resolver finds a HyperSpec carrying Data/Map_Sym.txt.
The local-content cases skip when none resolves so the suite stays green
with or without a spec install, and never reaches the tier-3 network path."
  (and (dsmr-mcp/src/clhs::%resolve-hyperspec-root) t))

(defmacro with-clhs-or-skip (&body body)
  "Run BODY when a HyperSpec resolves; otherwise emit a Parachute skip."
  `(if (%hyperspec-available-p)
       (progn ,@body)
       (skip "no HyperSpec resolvable (DSMR_HYPERSPEC_DIR / $LISP_WORKSPACE/HyperSpec/ both absent)")))

(defun %content-text (result)
  "Pull the extracted text out of a clhs-lookup result's MCP content vector,
or NIL when absent. content is a one-element vector of {type,text} objects."
  (let ((vec (and (hash-table-p result) (gethash "content" result))))
    (when (and (vectorp vec) (plusp (length vec)))
      (gethash "text" (aref vec 0)))))

;;; --- Section filename math (pure; no HyperSpec needed) ----------------------

(define-test section-resolves-to-filename
  "Section numbers map to HyperSpec filenames: chapter zero-padded to two
digits, each subsection a letter (a=1, b=2, ...). 22.3 -> 22_c.htm."
  (is string= "22_c.htm"  (%section-to-filename "22.3"))
  (is string= "03_.htm"   (%section-to-filename "3"))
  (is string= "07_a.htm"  (%section-to-filename "7.1"))
  (is string= "22_ca.htm" (%section-to-filename "22.3.1")))

(define-test section-vs-symbol-detection
  "A digits-and-dots token starting with a digit routes to section lookup;
anything with letters routes to symbol lookup."
  (true  (%section-number-p "22.3"))
  (true  (%section-number-p "3"))
  (false (%section-number-p "format"))
  (false (%section-number-p "loop"))
  (false (%section-number-p "")))

;;; --- Local content extraction (guarded on a resolvable HyperSpec) ----------

(define-test symbol-returns-local-content
  "With a resolvable HyperSpec, a symbol lookup returns a hash-table whose
extracted content is non-empty and whose URL points at the local entry."
  (with-clhs-or-skip
    (let ((result (clhs-lookup "loop")))
      (true (hash-table-p result))
      (is string= "loop" (gethash "symbol" result))
      (is string= "local" (gethash "source" result))
      (let ((text (%content-text result)))
        (true (stringp text) "extracted content text present")
        (true (plusp (length text)) "extracted content is non-empty"))
      (true (search "loop" (gethash "url" result))
            "URL resolves to the local loop entry"))))

(define-test section-lookup-url
  "With a resolvable HyperSpec, a section lookup resolves 22.3 to the
zero-padded 22_c filename in the result URL."
  (with-clhs-or-skip
    (let ((result (clhs-lookup "22.3")))
      (true (hash-table-p result))
      (is string= "22.3" (gethash "section" result))
      (true (search "22_c" (gethash "url" result))
            "URL uses the zero-padded section filename 22_c"))))

;;; --- Fail-closed not-found path (T-11-06) ----------------------------------

(define-test absent-hyperspec-is-error
  "A directory with no Data/Map_Sym.txt resolves to NIL (fail-closed), so the
tool surfaces a structured not-found rather than crashing on the wire. Both an
existing directory lacking the map and a nonexistent directory yield NIL."
  (false (dsmr-mcp/src/clhs::%hyperspec-root-if-mapped "/tmp/"))
  (false (dsmr-mcp/src/clhs::%hyperspec-root-if-mapped
          "/nonexistent-dsmr-clhs-probe-dir-xyz/")))
