;;;; tests/envrc-template/envrc-vars-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Per-variable accessors over a `.envrc` text. Everything here runs against
;;;; literal fixture strings: the module under test does no file IO, so a temp
;;;; project would add nothing but time.
;;;;
;;;; The fixtures are the shapes actually met in the wild: a bare pre-dsmr-mcp
;;;; file, a file carrying the older slynk-only region, a hand-written bus
;;;; identity with no markers at all, the full managed block, and a file that
;;;; collected two marker regions over time. The assertions are byte equality on
;;;; whole lines rather than substring hits, because the contract being guarded
;;;; is that the operator's own lines survive an append untouched and in order.

;; Package evolution guard: drop a prior incarnation so a reload picks up the
;; current import set rather than stale symbols.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/envrc-template/envrc-vars-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/envrc-template/envrc-vars-test
  (:use #:cl #:parachute)
  (:import-from #:dsmr-mcp/src/envrc-vars
                #:declared-value
                #:declared-p
                #:ensure-declaration
                #:ensure-declaration-line
                #:ensure-managed-declarations
                #:undeclared-variables
                #:setup-complete-p
                #:managed-variables
                #:variable-name
                #:declaration-line
                #:managed-block
                #:managed-region-bounds
                #:region-open-line
                #:region-close-line
                #:project-basename)
  (:import-from #:dsmr-mcp/src/slynk-port
                #:derive-slynk-port))

(in-package #:dsmr-mcp/tests/envrc-template/envrc-vars-test)

;;; ---------------------------------------------------------------------------
;;; Fixtures
;;; ---------------------------------------------------------------------------

(defparameter +bare-envrc+
  "export FOO=bar
"
  "A fully pre-dsmr-mcp file: one operator line, no markers, no managed
variables.")

(defparameter +slynk-only-envrc+
  "export FOO=bar

# >>> dsmr-mcp (slynk) (added automatically; edit or remove freely) >>>
export LISP_WORKSPACE=\"${LISP_WORKSPACE:-$HOME/SourceCode/lisp/}\"
export SLYNK_HOST=\"${SLYNK_HOST:-127.0.0.1}\"
export SLYNK_PORT=\"${SLYNK_PORT:-4005}\"
export DSMR_MODE=auto
export DSMR_SLYNK_ATTACH=\"${SLYNK_HOST}:${SLYNK_PORT}\"
export DSMR_LOG_LEVEL=info
# <<< dsmr-mcp (slynk) <<<
"
  "A file that received the slynk region before the coordination bus existed.
Its marker carries the `(slynk)` qualifier, which is one of the three flavours
the region reader must tolerate.")

(defparameter +bus-only-envrc+
  "export FOO=bar
export DSMR_BUS_AGENT=myproj
"
  "A hand-written bus identity with no markers anywhere. Nothing here was
machine-written, and the declaration must still be respected as one.")

(defparameter +two-region-envrc+
  "export FOO=bar

# >>> dsmr-mcp (slynk) (added automatically; edit or remove freely) >>>
export SLYNK_HOST=\"${SLYNK_HOST:-127.0.0.1}\"
# <<< dsmr-mcp (slynk) <<<

# >>> dsmr-mcp (bus) (added automatically; edit or remove freely) >>>
export DSMR_BUS_AGENT=\"${DSMR_BUS_AGENT:-myproj}\"
# <<< dsmr-mcp (bus) <<<
"
  "A repository that collected the slynk region and then the bus region on
separate visits, so it carries two managed regions.")

;;; ---------------------------------------------------------------------------
;;; Helpers
;;; ---------------------------------------------------------------------------

(defun %lines (text)
  "Split TEXT on newlines. A text ending in a newline yields a final empty
element, which is what makes a byte-for-byte line comparison possible."
  (uiop:split-string text :separator (list #\Newline)))

(defun %ordered-subsequence-p (needles haystack)
  "True when every element of NEEDLES appears in HAYSTACK, matched whole by
STRING=, in the same relative order."
  (let ((rest haystack))
    (dolist (needle needles t)
      (let ((pos (position needle rest :test #'string=)))
        (unless pos (return nil))
        (setf rest (nthcdr (1+ pos) rest))))))

(defun %count-lines-mentioning (needle text)
  "Return how many lines of TEXT contain NEEDLE."
  (count-if (lambda (line) (search needle line)) (%lines text)))

;;; ---------------------------------------------------------------------------
;;; Reading a declaration
;;; ---------------------------------------------------------------------------

(define-test declared-value-reads-a-hand-written-export
  "A hand-written declaration outside any marker region is read as a
declaration, and its expression comes back verbatim."
  (multiple-value-bind (value present)
      (declared-value +bus-only-envrc+ "DSMR_BUS_AGENT")
    (true present "a hand-written export must count as a declaration")
    (is string= "myproj" value "the declared expression is returned verbatim")))

(define-test declared-value-reads-a-defaulting-export
  "The override-preserving form is read back whole, so the caller sees the
`${NAME:-...}` expression rather than a guess at the value it resolves to."
  (multiple-value-bind (value present)
      (declared-value +two-region-envrc+ "DSMR_BUS_AGENT")
    (true present "a defaulting export must count as a declaration")
    (is string= "\"${DSMR_BUS_AGENT:-myproj}\"" value
        "the whole right-hand side is returned, expansion and all")))

(define-test declared-value-of-an-undeclared-variable-is-nil
  "An undeclared variable reads as NIL with a false present-p, so absence is
never confused with an empty value."
  (multiple-value-bind (value present)
      (declared-value +bare-envrc+ "DSMR_BUS_AGENT")
    (false present "an absent variable must not report as declared")
    (false value "an absent variable must read as NIL")))

(define-test a-comment-mentioning-a-variable-is-not-a-declaration
  "Prose that names a variable, including the shipped template's own guidance
about overriding it, sets nothing and must not read as a declaration."
  (false (declared-p "# override by exporting DSMR_BUS_AGENT before direnv loads
"
                     "DSMR_BUS_AGENT")
         "a comment must not be mistaken for a declaration"))

(define-test an-empty-right-hand-side-is-still-a-declaration
  "`export NAME=` sets the variable to the empty string. That is a declaration
and overwriting it would discard what the operator wrote."
  (multiple-value-bind (value present)
      (declared-value "export DSMR_LOG_LEVEL=
"
                      "DSMR_LOG_LEVEL")
    (true present "an empty assignment is a declaration")
    (is string= "" value "an empty assignment reads as the empty string")))

;;; ---------------------------------------------------------------------------
;;; Ensuring a declaration exists
;;; ---------------------------------------------------------------------------

(define-test ensure-declaration-leaves-a-declared-variable-alone
  "Ensuring a variable that is already declared returns the identical text and
reports no change, so a hand-edited value survives."
  (multiple-value-bind (text changed)
      (ensure-declaration +bus-only-envrc+ "DSMR_BUS_AGENT" "somethingelse")
    (false changed "an already-declared variable must report no change")
    (true (eq text +bus-only-envrc+) "the original text object is returned")
    (is string= +bus-only-envrc+ text "not one byte may differ")))

(define-test ensure-declaration-adds-one-line-inside-the-region
  "Ensuring an undeclared variable adds exactly one export line, and it lands
inside the managed region the file already has rather than in a second block."
  (multiple-value-bind (text changed)
      (ensure-declaration +slynk-only-envrc+ "DSMR_BUS_AGENT" "myproj")
    (true changed "an undeclared variable must report a change")
    (is = 1 (%count-lines-mentioning "DSMR_BUS_AGENT" text)
        "exactly one DSMR_BUS_AGENT line is added")
    (is = 1 (length (managed-region-bounds text))
        "no second region is created when one already exists")
    (let ((region (first (managed-region-bounds text)))
          (pos (position-if (lambda (line) (search "DSMR_BUS_AGENT" line))
                            (%lines text))))
      (true (and pos (< (car region) pos) (< pos (cdr region)))
            "the new declaration sits between the region markers"))))

(define-test ensure-declaration-preserves-every-original-line
  "Every line the file already had survives byte for byte and in order, and the
result is longer by exactly the one line that was added."
  (let* ((result (ensure-declaration +slynk-only-envrc+ "DSMR_BUS_AGENT" "myproj"))
         (before (%lines +slynk-only-envrc+))
         (after (%lines result)))
    (true (%ordered-subsequence-p before after)
          "every original line survives, in its original order")
    (is = (1+ (length before)) (length after)
        "exactly one line was added")))

(define-test ensure-declaration-creates-a-region-when-there-is-none
  "A file with no managed region gains one, after a blank-line separator, and it
holds only the declaration that was missing."
  (let* ((result (ensure-declaration +bare-envrc+ "DSMR_BUS_AGENT" "myproj"))
         (lines (%lines result)))
    (is equal (list "export FOO=bar"
                    ""
                    (region-open-line)
                    "export DSMR_BUS_AGENT=\"${DSMR_BUS_AGENT:-myproj}\""
                    (region-close-line)
                    "")
              lines
              "a new region is appended after a blank line, holding one export")))

(define-test ensure-declaration-adds-the-missing-final-newline-first
  "A file that does not end in a newline gets one before the separator, so the
opening marker can never join the operator's last line."
  (let ((result (ensure-declaration "export FOO=bar" "DSMR_MODE" "auto")))
    (is string= "export FOO=bar

# >>> dsmr-mcp (added automatically; edit or remove freely) >>>
export DSMR_MODE=\"${DSMR_MODE:-auto}\"
# <<< dsmr-mcp <<<
"
        result
        "the last line is terminated before the blank-line separator")))

(define-test ensure-declaration-is-idempotent
  "The second ensure of the same variable changes nothing, which is what makes
the append path safe to re-run."
  (let ((once (ensure-declaration +bare-envrc+ "DSMR_BUS_AGENT" "myproj")))
    (multiple-value-bind (twice changed)
        (ensure-declaration once "DSMR_BUS_AGENT" "myproj")
      (false changed "a repeat ensure must report no change")
      (is string= once twice "a repeat ensure must not touch the text"))))

(define-test insertion-goes-in-the-last-of-two-regions
  "A file carrying two managed regions keeps both, and the new declaration joins
the last one."
  (let* ((result (ensure-declaration +two-region-envrc+ "DSMR_LOG_LEVEL" "info"))
         (regions (managed-region-bounds result))
         (pos (position-if (lambda (line) (search "DSMR_LOG_LEVEL" line))
                           (%lines result))))
    (is = 2 (length regions) "both regions survive")
    (let ((last-region (car (last regions))))
      (true (and pos (< (car last-region) pos) (< pos (cdr last-region)))
            "the new declaration lands inside the last region"))
    (true (%ordered-subsequence-p (%lines +two-region-envrc+) (%lines result))
          "every original line survives, in order")))

(define-test ensure-declaration-line-writes-the-line-verbatim
  "The primitive takes a complete export line and writes it unchanged, which is
how a variable whose shipped form is not the defaulting one keeps its spelling."
  (let ((result (ensure-declaration-line +bare-envrc+ "DSMR_MODE"
                                         "export DSMR_MODE=auto")))
    (true (member "export DSMR_MODE=auto" (%lines result) :test #'string=)
          "the supplied line appears verbatim")))

;;; ---------------------------------------------------------------------------
;;; Region reading
;;; ---------------------------------------------------------------------------

(define-test region-bounds-tolerate-every-marker-flavour
  "Unqualified, `(slynk)` and `(bus)` markers are all recognised, because the
reader matches the prefix the three share rather than the trailing text they do
not."
  (is = 1 (length (managed-region-bounds (managed-block)))
      "the unqualified marker is recognised")
  (is = 1 (length (managed-region-bounds +slynk-only-envrc+))
      "the (slynk) marker is recognised")
  (is = 2 (length (managed-region-bounds +two-region-envrc+))
      "both (slynk) and (bus) markers are recognised")
  (is = 0 (length (managed-region-bounds +bus-only-envrc+))
      "a file with no markers has no regions"))

(define-test an-unclosed-region-is-not-a-region
  "An opening marker with no closing marker after it contributes no region, so a
truncated file does not swallow everything below it."
  (is = 0 (length (managed-region-bounds "export FOO=bar
# >>> dsmr-mcp (added automatically; edit or remove freely) >>>
export DSMR_MODE=auto
"))
      "a half-written region is ignored"))

;;; ---------------------------------------------------------------------------
;;; The table and the questions asked of it
;;; ---------------------------------------------------------------------------

(define-test managed-block-matches-the-shipped-shape
  "The block built from the table is byte for byte the block dsmr-mcp has always
written. This is the guard against the table and the shipped shape drifting
apart."
  (is string= "# >>> dsmr-mcp (added automatically; edit or remove freely) >>>
export LISP_WORKSPACE=\"${LISP_WORKSPACE:-$HOME/SourceCode/lisp/}\"
export SLYNK_HOST=\"${SLYNK_HOST:-127.0.0.1}\"
export SLYNK_PORT=\"${SLYNK_PORT:-4005}\"
export DSMR_MODE=auto
export DSMR_SLYNK_ATTACH=\"${SLYNK_HOST}:${SLYNK_PORT}\"
export DSMR_LOG_LEVEL=info
export DSMR_BUS_AGENT=\"${DSMR_BUS_AGENT:-agent}\"
export DSMR_BUS_SELECTOR=\"${DSMR_BUS_SELECTOR:-}\"
# <<< dsmr-mcp <<<
"
      (managed-block)
      "the managed block's export lines, order and markers are unchanged"))

(define-test managed-block-is-the-table-in-order
  "The block is exactly the markers wrapped around one declaration per managed
variable, in table order, so a variable added to the table reaches the block
without a second edit."
  (let* ((lines (%lines (managed-block)))
         (body (subseq lines 1 (- (length lines) 2))))
    (is string= (region-open-line) (first lines) "the block opens with the marker")
    (is string= (region-close-line) (nth (- (length lines) 2) lines)
        "the block closes with the marker")
    (is equal (mapcar (lambda (variable) (declaration-line variable))
                      (managed-variables))
              body
              "the body is the table's declarations, in table order")))

(define-test managed-block-derives-the-per-project-defaults
  "With a project root the block carries that project's derived Slynk port and
its directory name as the bus identity, so two projects do not converge on one
Slynk image or one bus name."
  (let* ((root #p"/tmp/dsmr-envrc-vars-example/")
         (text (managed-block root))
         (port (derive-slynk-port root)))
    (true (search (format nil "SLYNK_PORT:-~A}" port) text)
          "the derived port lands on the SLYNK_PORT line")
    (false (search "SLYNK_PORT:-4005}" text)
           "the legacy default must not survive derivation")
    (is string= "dsmr-envrc-vars-example" (project-basename root)
        "the bus identity default is the project directory name")
    (true (search "DSMR_BUS_AGENT:-dsmr-envrc-vars-example}" text)
          "the derived bus identity lands on the DSMR_BUS_AGENT line")))

(define-test undeclared-variables-answers-in-table-order
  "The undeclared set skips what is already declared and keeps table order, so a
caller folding over it writes the block's own sequence."
  (is equal '("LISP_WORKSPACE" "SLYNK_PORT" "DSMR_MODE" "DSMR_SLYNK_ATTACH"
              "DSMR_LOG_LEVEL" "DSMR_BUS_AGENT" "DSMR_BUS_SELECTOR")
      (mapcar #'variable-name
              (undeclared-variables "export SLYNK_HOST=1.2.3.4
"))
      "the declared variable is dropped and the rest keep their order"))

(define-test setup-complete-p-keys-on-the-marker-variables
  "The settled question is answered by the marker variables alone. A file
carrying all of them is settled even without the supporting lines, which is what
stops an operator's deliberate deletion turning into a prompt every session.

The fleet selector joined the marker set, which is what makes every repository
already carrying the older stanza incomplete again and therefore reachable by
the offer. That is deliberate and it is how the selector reaches the fleet: the
declaration it gains defaults to empty, which is the shared host-wide bus, so
nobody is moved by receiving it."
  (false (setup-complete-p +bare-envrc+)
         "a file with neither marker is not settled")
  (false (setup-complete-p "export DSMR_SLYNK_ATTACH=127.0.0.1:4005
")
         "a file with only the slynk marker is not settled")
  (false (setup-complete-p +bus-only-envrc+)
         "a file with only the bus marker is not settled")
  (false (setup-complete-p "export DSMR_SLYNK_ATTACH=127.0.0.1:4005
export DSMR_BUS_AGENT=myproj
")
         "the stanza as it stood before the selector existed is not settled")
  (true (setup-complete-p "export DSMR_SLYNK_ATTACH=127.0.0.1:4005
export DSMR_BUS_AGENT=myproj
export DSMR_BUS_SELECTOR=\"\"
")
        "a file carrying every marker is settled")
  (true (setup-complete-p "export DSMR_SLYNK_ATTACH=127.0.0.1:4005
export DSMR_BUS_AGENT=myproj
export DSMR_BUS_SELECTOR=fulcrum
")
        "a selector naming a fleet is settled exactly as an empty one is"))

;;; ---------------------------------------------------------------------------
;;; The fold the append path uses
;;; ---------------------------------------------------------------------------

(define-test the-fold-on-a-bare-file-reproduces-the-managed-block
  "Ensuring every managed variable on a file that declares none produces exactly
the text the managed block has always appended: a blank-line separator, then the
block. This is the byte-level evidence that answering per variable did not
change what gets written."
  (multiple-value-bind (text changed) (ensure-managed-declarations +bare-envrc+)
    (true changed "a bare file must gain the declarations")
    (is string= (concatenate 'string +bare-envrc+ (string #\Newline)
                             (managed-block))
        text
        "the fold reproduces the managed block byte for byte")))

(define-test the-fold-on-a-complete-file-changes-nothing
  "A file that already declares every managed variable is left identical and
reports no change, so the append path's do-nothing case falls out of the fold
rather than needing its own check."
  (let ((complete (concatenate 'string +bare-envrc+ (string #\Newline)
                               (managed-block))))
    (multiple-value-bind (text changed) (ensure-managed-declarations complete)
      (false changed "a complete file must report no change")
      (is string= complete text "a complete file must not be touched"))))

(define-test the-fold-adds-only-what-is-missing
  "A file carrying the older slynk region gains the two declarations it lacks
and nothing else: the six it already has are not written a second time."
  (multiple-value-bind (text changed)
      (ensure-managed-declarations +slynk-only-envrc+)
    (true changed "a slynk-only file must gain the missing declarations")
    (is = 1 (%count-lines-mentioning "DSMR_SLYNK_ATTACH" text)
        "the slynk attach line is not duplicated")
    (is = 1 (%count-lines-mentioning "DSMR_BUS_AGENT" text)
        "the bus identity is added exactly once")
    (is = 1 (%count-lines-mentioning "DSMR_BUS_SELECTOR" text)
        "the fleet selector is added exactly once")
    (is = (+ 2 (length (%lines +slynk-only-envrc+))) (length (%lines text))
        "exactly the two missing declarations were added")
    (true (setup-complete-p text)
          "the file reaches the settled state, so no re-prompt follows")))
