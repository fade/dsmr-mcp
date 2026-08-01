;;;; src/lisp-edit-comment.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Editing a comment region in place: splice the exact bytes of the run,
;;;; prove the file still holds everything it held outside its comments, and
;;;; only then write.  Mode-independent (dispatcher-side): it reads and writes
;;;; files on disk and never talks to an attached Lisp image.
;;;;
;;;; There are two ways to name the target.  Region mode takes a substring of a
;;;; free-standing run.  Leading mode names the form the run sits flush on top
;;;; of.  Both resolve to one byte span, and the splice covers that span and
;;;; nothing else, so the whitespace separating a run from its neighbours is
;;;; never touched.  Deleting additionally takes the single whitespace run
;;;; following the comment, which is what keeps a removed banner from leaving a
;;;; blank line behind.
;;;;
;;;; Whichever way the target was named, the run has to begin its own line.  A
;;;; comment written after code is prose about that code, and editing it there
;;;; rewrites the line the code sits on while the file still holds every form
;;;; it started with, so nothing after the write reports the loss.  That rule
;;;; belongs to the verb rather than to either way of naming a comment, so it
;;;; is applied once, to the offset the splice will use, and a further way of
;;;; naming a comment inherits it instead of needing its own copy.
;;;;
;;;; Why re-parsing and comparing afterwards is not redundant with the
;;;; delimiter scan: a replacement comment can open a block comment that closes
;;;; on a delimiter already present further down the file, swallowing whole
;;;; definitions into comment text while the file still reads as balanced and
;;;; parses without error.  Comparing the re-parsed file against the original,
;;;; byte for byte at shifted offsets, is the only check here that sees that.
;;;;
;;;; That comparison covers every node the locator does not call comment text.
;;;; Comment text is the one thing this verb may change, so it is the one thing
;;;; excluded, and a single predicate decides it for the half that picks a
;;;; target and the half that checks the result alike.  Excluding anything else
;;;; would leave a hole shaped like the kind of node excluded: a reader
;;;; conditional is skipped by the reader rather than read as an expression, so
;;;; a check written in terms of expressions cannot see one turn into comment
;;;; text, and the file that lost the definition still loads cleanly on the
;;;; machine that made the edit.
;;;;
;;;; A cheaper guard runs in front of all that.  Replacement text that leaves a
;;;; delimiter or a block comment open is refused on sight, before the file is
;;;; even read, since the only thing available to close it is something already
;;;; sitting below the comment.  Every check here runs before the write branch,
;;;; so a rejected edit leaves the file exactly as it was.

(defpackage #:dsmr-mcp/src/lisp-edit-comment
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/cst
                #:cst-node-kind
                #:cst-node-start
                #:cst-node-end
                #:cst-node-start-line
                #:parse-top-level-forms)
  (:import-from #:dsmr-mcp/src/fs
                #:write-file-string-atomically)
  (:import-from #:dsmr-mcp/src/project-root
                #:ensure-write-path)
  (:import-from #:dsmr-mcp/src/lisp-edit-form-core
                #:%locate-target-form)
  (:import-from #:dsmr-mcp/src/lisp-edit-comment-core
                #:comment-locator-error
                #:%comment-runs
                #:%comment-node-p
                #:%leading-comment-run
                #:%match-region-by-substring
                #:%locate-comment-regions
                #:%region-first-node
                #:%region-last-node
                #:%region-text
                #:%region-line-range
                #:%region-anchor-form
                #:%true-end-line)
  (:import-from #:dsmr-mcp/src/validate
                #:scan-parens
                #:try-reader-check)
  (:import-from #:dsmr-mcp/src/log
                #:log-event)
  (:import-from #:dsmr-mcp/src/lsp/client
                #:find-lsp-client
                #:bump-uri-version)
  (:import-from #:dsmr-mcp/src/lsp/document
                #:notify-did-change)
  (:export #:edit-comment
           #:comment-operation-error
           #:comment-operation-reason))

(in-package #:dsmr-mcp/src/lisp-edit-comment)

;;;; -------------------------------------------------------------------------
;;;; comment-operation-error condition
;;;; -------------------------------------------------------------------------

(define-condition comment-operation-error (error)
  ((reason
    :initarg :reason
    :reader comment-operation-reason
    :documentation "Human-readable description of why the comment edit failed."))
  (:report (lambda (c s) (write-string (comment-operation-reason c) s)))
  (:documentation "Signalled for expected comment-edit failures: an anchor that
names no comment region or more than one, replacement text that leaves a
delimiter open, a run that does not begin its own line and so belongs to the
code beside it, and a splice whose result no longer holds everything the file
held outside its comments.  The file is never written when this condition is
signalled."))

;;;; -------------------------------------------------------------------------
;;;; Splice
;;;; -------------------------------------------------------------------------

(defun %blank-char-p (character)
  "Return T when CHARACTER is one of the whitespace characters a delete trims."
  (member character '(#\Space #\Tab #\Newline #\Return)))

(defun %starts-its-own-line-p (text offset)
  "Return T when nothing but whitespace precedes OFFSET on its source line.

A comment written after code on the same line is prose about that code,
whatever happens to sit on the next line.  Either way of naming a comment can
reach such a run, so the verb tests the offset the splice will use rather than
testing it per mode, and it tests it before the splice: editing such a run
damages nothing a later check can see.  Every form in the file stays byte for
byte identical while the comment beside the code is rewritten or gone, so the
edit passes the form comparison and the delimiter scan alike."
  (let ((index offset))
    (loop
      (decf index)
      (when (minusp index)
        (return t))
      (let ((character (char text index)))
        (cond ((char= character #\Newline) (return t))
              ((%blank-char-p character))
              (t (return nil)))))))

(defun %same-line-refusal (mode-key form-type form-name)
  "Return the reason text for refusing a comment that begins after code.

One function builds this for both ways of naming a comment, so the two cannot
drift into saying different things about the same rule.  MODE-KEY only decides
how the run is described back to the caller: a caller who named a form gets the
form named back, a caller who named a substring gets the substring."
  (format nil "~A begins after code on the same line, so it is prose about that ~
code and not a comment of its own. Editing it here would rewrite the line that ~
code sits on, and nothing after the write could report the damage: every form ~
in the file would still be byte for byte identical."
          (if (eq mode-key :leading)
              (format nil "the comment above ~A ~A" form-type form-name)
              "the comment that substring names")))

(defun %file-line-terminator (text)
  "Return the line terminator TEXT already uses, as a string.

Carriage return and newline when the first newline in TEXT is preceded by a
carriage return, a bare newline otherwise.  One sample decides it: a source file
with two conventions in it is already broken in a way this verb cannot repair,
and picking the first tells the caller which one the edit will follow.

A file holding no newline at all answers with a bare newline.  Nothing below the
edit can disagree with that guess, because there is nothing below the edit."
  (let ((break (position #\Newline text)))
    (if (and break (plusp break) (char= (char text (1- break)) #\Return))
        (concatenate 'string (string #\Return) (string #\Newline))
        (string #\Newline))))

(defun %content-with-file-terminator (content terminator)
  "Return CONTENT with every line ending in it rewritten to TERMINATOR.

Replacement text arrives with whatever line endings the caller's own editor
produced, and splicing it verbatim leaves a file with two conventions in it.
The file already states which one it uses, so the caller does not have to."
  (let ((flattened
          (with-output-to-string (out)
            (loop with limit = (length content)
                  for index from 0 below limit
                  for character = (char content index)
                  do (unless (and (char= character #\Return)
                                  (< (1+ index) limit)
                                  (char= (char content (1+ index)) #\Newline))
                       (write-char character out))))))
    (if (string= terminator (string #\Newline))
        flattened
        (with-output-to-string (out)
          (loop for character across flattened
                do (if (char= character #\Newline)
                       (write-string terminator out)
                       (write-char character out)))))))

(defun %splice (text start end operation content)
  "Rewrite TEXT's bytes from START to END according to OPERATION.

Returns four values: the updated text, the first offset removed, the offset one
past the last removed, and the text put in their place.  The three position
values describe the whole edit, which is what lets the form comparison know
exactly how far each later form moved.  The fourth is the text as it was
actually spliced, which is not always the text the caller handed over.

Replace covers the comment run's own bytes and no more, so the whitespace
around it survives untouched.  A run's bytes end after the newline closing its
last line, so replacement text carrying no newline of its own would take the
blank line below the comment with it, leaving the comment flush against the
form beneath and unreachable by substring afterwards.  One terminator is
appended when that would otherwise happen: when the bytes being removed end in
a newline and the content is neither empty nor already newline-terminated.
Empty content is spliced exactly as given, since a caller passing it is saying
there should be nothing here and appending would put the line back.  The
terminator appended, and the terminator inside the content, is the one the file
already uses.

Delete additionally takes the single run of whitespace following the comment so
a removed banner leaves no blank line.  The one exception is a comment that
ends the file: the trim only runs forward, so there is nothing after the
comment for it to absorb and the blank line above the comment stays where it
is.  Harmless, and worth knowing before a whitespace linter reports it."
  (ecase operation
    (:replace
     (let* ((terminator (%file-line-terminator text))
            (normalized (%content-with-file-terminator content terminator))
            (spliced (if (and (plusp (length normalized))
                              (plusp end)
                              (char= (char text (1- end)) #\Newline)
                              (not (char= (char normalized (1- (length normalized)))
                                          #\Newline)))
                         (concatenate 'string normalized terminator)
                         normalized)))
       (values (concatenate 'string (subseq text 0 start) spliced (subseq text end))
               start end spliced)))
    (:delete
     (let* ((suffix (subseq text end))
            (trim (or (position-if-not #'%blank-char-p suffix) (length suffix))))
       (values (concatenate 'string (subseq text 0 start) (subseq suffix trim))
               start (+ end trim) "")))))

;;;; -------------------------------------------------------------------------
;;;; Verification, run before any write
;;;; -------------------------------------------------------------------------

(defun %verify-content-self-contained (content)
  "Signal COMMENT-OPERATION-ERROR when CONTENT leaves a delimiter open.

The cheapest guard in the verb, and the one that kills the whole class at its
source: replacement text that opens a block comment or a delimiter it never
closes can only go on to re-type whatever follows it in the file.  Refusing it
outright costs one scan of the caller's own text, before the file is even read.

Delimiters inside comment text do not count, which is what keeps this from
refusing ordinary prose.  A comment reading `call (foo with one paren` is a
perfectly good comment and stays acceptable; only an opening that would still
be open once the reader leaves the replacement is refused.

The comparison of the whole file after the splice stays where it is.  This
guard sees a replacement that opens something, and that check sees a
replacement that damages something, which are not the same set."
  (let ((parens (scan-parens content)))
    (unless (getf parens :ok)
      (error 'comment-operation-error
             :reason (format nil "the replacement text is not self-contained: ~
it leaves ~A open at line ~A, column ~A of the replacement, so the code below ~
the comment would be re-typed by whatever closes it. Nothing was written."
                             (getf parens :kind)
                             (getf parens :line)
                             (getf parens :column)))))
  t)

(defun %non-comment-nodes (nodes)
  "Return every node of NODES that is not comment text.

The verb is allowed to change comment text and nothing else, so everything the
locator's own predicate rejects is what the edit has to preserve: ordinary
expressions, reader-conditional forms, datum comments, and any other input the
reader skips over.  Selecting by that predicate rather than by a list of node
kinds means a kind nobody has thought of yet is protected by default instead of
being invisible until someone adds it to the list.

The edited run's own nodes are comment text, so they drop out of both the
before list and the after list without any span arithmetic."
  (remove-if #'%comment-node-p nodes))

(defun %node-headline (text node)
  "Return the first line of NODE's text in TEXT, shortened for a message.

Enough for a caller to recognise which piece of the file the check is talking
about without printing a whole definition back at them."
  (let* ((raw (subseq text (cst-node-start node) (cst-node-end node)))
         (break (position #\Newline raw))
         (line (string-trim '(#\Space #\Tab #\Return) (subseq raw 0 break))))
    (if (> (length line) 60)
        (concatenate 'string (subseq line 0 57) "...")
        line)))

(defun %verify-forms-survived (original original-nodes updated readtable
                               removed-start removed-end inserted)
  "Signal COMMENT-OPERATION-ERROR unless UPDATED holds everything but comment text.

The verb may change comment text.  Everything else the file holds has to come
back: the same nodes, in the same order, of the same kind, with the same bytes,
each at the offset it had plus whatever length the edit added or removed.  What
counts as comment text is not decided here, it is asked of the locator's own
predicate, so the half of the editor that chooses a target and the half that
checks the result cannot disagree about which bytes were up for change.

Reader-conditional definitions are the reason this covers more than
expressions.  The reader skips a sharpsign-plus form on an implementation the
feature test excludes, so it arrives as skipped input rather than as an
expression, and a check that looked only at expressions could not see one being
swallowed.  The file that lost the definition still loads cleanly on the
machine that made the edit, which is exactly what makes the loss hard to notice
later.

The comparison is on raw bytes rather than on the values the reader produced:
read values are blind to whitespace damage inside a form and awkward to compare
for floats and uninterned symbols.

This is the check that catches a replacement swallowing its neighbours.  A
delimiter scan cannot: an opening block comment closed by a delimiter already
present further down leaves the file balanced and readable while whole
definitions have quietly become comment text."
  (let* ((delta (- (length inserted) (- removed-end removed-start)))
         (before (%non-comment-nodes original-nodes))
         (after (%non-comment-nodes
                 (parse-top-level-forms updated :readtable readtable))))
    (unless (= (length before) (length after))
      (error 'comment-operation-error
             :reason (format nil "the edit changed what the file holds outside ~
its comments: ~D before, ~D after. The replacement text alters how the reader ~
sees the code around it, most often by opening a block comment that closes ~
further down, so nothing was written."
                             (length before) (length after))))
    (loop for old in before
          for new in after
          for shift = (if (<= (cst-node-end old) removed-start) 0 delta)
          do (unless (and (eq (cst-node-kind new) (cst-node-kind old))
                          (= (cst-node-start new) (+ (cst-node-start old) shift))
                          (= (cst-node-end new) (+ (cst-node-end old) shift))
                          (string= (subseq original
                                           (cst-node-start old) (cst-node-end old))
                                   (subseq updated
                                           (cst-node-start new) (cst-node-end new))))
               (error 'comment-operation-error
                      :reason (format nil "the code beginning on line ~D did not ~
survive the edit unchanged: ~A. Nothing was written."
                                      (cst-node-start-line old)
                                      (%node-headline original old)))))
    t))

(defun %verify-still-reads (original updated)
  "Signal COMMENT-OPERATION-ERROR when the edit cost UPDATED its readability.

Two checks, delimiter balance and a full read, and each runs against ORIGINAL
before it runs against UPDATED.  A check the original already fails proves
nothing at all about the edit: the file arrived in that state, and refusing on
it blames the edit for damage that was already there and locks every comment in
that file out of this verb for good.  Such a check is skipped, and the fact is
reported, so the caller is never told a file came back clean that never was.
When the original passes and the updated text does not, the refusal is exactly
what it was.

Skipping one leaves the edit guarded.  The comparison of everything the file
holds outside its comments runs in every case, whatever state the file arrived
in, and that is the check carrying the guarantee.  These two prove only that the
file as a whole still balances and still reads; neither says anything about
whether what it holds is what it held before.

Returns T when ORIGINAL already failed one of the two, so the report can say the
file was in that state before the edit rather than because of it."
  (let ((already nil))
    (if (getf (scan-parens original) :ok)
        (let ((parens (scan-parens updated)))
          (unless (getf parens :ok)
            (error 'comment-operation-error
                   :reason (format nil "the edited file no longer has balanced ~
delimiters: ~A at line ~A, column ~A. Nothing was written."
                                   (getf parens :kind)
                                   (getf parens :line)
                                   (getf parens :column)))))
        (setf already t))
    (if (try-reader-check original)
        (setf already t)
        (let ((reader (try-reader-check updated)))
          (when reader
            (error 'comment-operation-error
                   :reason (format nil "the edited file no longer reads cleanly: ~A~
~@[ at line ~A~]. Nothing was written."
                                   (getf reader :message)
                                   (getf reader :line))))))
    already))

;;;; -------------------------------------------------------------------------
;;;; Target resolution
;;;; -------------------------------------------------------------------------

(defparameter *datum-comment-note*
  (concatenate 'string
               "A #; datum comment earlier in the file ends the parse there, "
               "which hides everything below it from this verb.")
  "Explanation offered with an anchor failure when a datum comment is why the
anchor is absent from the parse.  The file on its own does not show that, which
is the whole reason for saying it.")

(defun %unparsed-tail (original nodes)
  "Return the text of ORIGINAL the parse never reached, or NIL if it read it all.

The parse stops at input it cannot get past, and NODES then describe only the
part of the file above that point.  Trailing whitespace is not a tail: every
file ends in some, and none of it hides anything."
  (let ((end (if nodes
                 (reduce #'max nodes :key #'cst-node-end)
                 0)))
    (when (< end (length original))
      (let ((tail (subseq original end)))
        (unless (every #'%blank-char-p tail)
          tail)))))

(defun %datum-comment-note (original nodes)
  "Return the datum-comment explanation when it applies to ORIGINAL, else NIL.

Offered with a refusal only when the parse stopped short of the end of the file
and a datum comment sits in the part it never reached.  Attached to every
refusal instead, it would carry no information at all: a reader cannot tell the
occasional case where it names the true cause from the many where it was
printed regardless, so the one time it would have helped it reads as the noise
it has been every other time.

There is no node to look for.  The parse ends at the datum comment, emitting
nothing for it and nothing for anything below it, so the truncation is the only
evidence available.  A file truncated by something else that happens to carry a
datum comment further down is described wrongly, which is why this is worded as
an explanation to consider rather than as a finding."
  (let ((tail (%unparsed-tail original nodes)))
    (when (and tail (search "#;" tail))
      *datum-comment-note*)))

(defun %resolve-leading-target (file-path form-type form-name readtable session-root)
  "Locate the comment run attached above a named form.

Returns eight values: the absolute pathname, the project-relative namestring,
the file text, its CST nodes, the run's first and last byte offsets, and the
run's first and last source line.

Only the failures the shared prologue raises deliberately are retyped as
expected ones.  It signals its own refusals with a format string and a path
that is not there arrives as a file error; anything else reaching here is a
fault, and it travels on so the caller reports a bug instead of retyping an
anchor that was already right."
  (multiple-value-bind (abs rel original nodes target)
      (handler-case
          (%locate-target-form file-path form-type form-name readtable session-root)
        ((or simple-error file-error) (e)
          (error 'comment-operation-error :reason (princ-to-string e))))
    (let ((run (%leading-comment-run nodes target)))
      (unless run
        (error 'comment-operation-error
               :reason (format nil "~A ~A has no comment sitting flush on top of ~
it. A blank line between a comment and the form makes that comment ~
free-standing, so name it by a substring in region mode instead.~@[ ~A~]"
                               form-type form-name
                               (%datum-comment-note original nodes))))
      (let ((first-node (first run))
            (last-node (car (last run))))
        (values abs rel original nodes
                (cst-node-start first-node)
                (cst-node-end last-node)
                (cst-node-start-line first-node)
                (%true-end-line last-node))))))

(defun %form-claiming-substring (nodes original substring)
  "Return the form whose attached comment contains SUBSTRING, or NIL.

A run flush against the form below it belongs to that form and is invisible to
substring anchoring, so a lookup that fails can point at the mode that would
have worked instead of only reporting an absence."
  (loop for run in (%comment-runs nodes original)
        for anchor = (%region-anchor-form nodes run)
        when (and anchor (search substring (%region-text run)))
          return anchor))

(defun %resolve-region-target (file-path substring line-start line-end
                               readtable session-root)
  "Locate the free-standing comment region named by SUBSTRING.

LINE-START and LINE-END constrain which region is meant whenever either of them
is given.  Returns the same eight values as %RESOLVE-LEADING-TARGET.

Only the locator's own condition, and a path that is not there, are retyped as
expected failures.  A type error or any other fault raised inside the locator
travels on untouched, so it reaches the verb's unexpected-failure channel: a
caller told the anchor was wrong retries with a different one, and a caller
told something failed unexpectedly reports it."
  (multiple-value-bind (abs rel original nodes regions)
      (handler-case (%locate-comment-regions file-path readtable session-root)
        ((or comment-locator-error file-error) (e)
          (error 'comment-operation-error :reason (princ-to-string e))))
    (let ((region
            (handler-case
                (%match-region-by-substring regions substring line-start line-end)
              (comment-locator-error (e)
                (let ((anchor (%form-claiming-substring nodes original substring)))
                  (error 'comment-operation-error
                         :reason (format nil "~A~@[~%That text sits in the comment ~
attached to the form beginning on line ~D; name that form in leading mode to ~
reach it.~]~@[~%~A~]"
                                         (princ-to-string e)
                                         (and anchor (cst-node-start-line anchor))
                                         (%datum-comment-note original nodes))))))))
      (multiple-value-bind (region-start-line region-end-line)
          (%region-line-range region)
        (values abs rel original nodes
                (cst-node-start (%region-first-node region))
                (cst-node-end (%region-last-node region))
                region-start-line
                region-end-line)))))

;;;; -------------------------------------------------------------------------
;;;; Reporting
;;;; -------------------------------------------------------------------------

(defun %inserted-end-line (line-start inserted)
  "Return the last line INSERTED occupies, or NIL when nothing was inserted."
  (when (plusp (length inserted))
    (let ((breaks (count #\Newline inserted)))
      (+ line-start
         (if (char= (char inserted (1- (length inserted))) #\Newline)
             (max 0 (1- breaks))
             breaks)))))

(defun %changed-region-report (original removed-start removed-end
                               line-start line-end inserted verified
                               already-unreadable)
  "Return a hash-table describing the span the edit covered.

It carries the comment's line range, the text the splice took out, the text put
in its place, and the line that replacement now ends on, so a caller can show
what moved without reading the file again.

The text reported as removed is the whole span the splice covered rather than
the comment's own bytes.  A delete additionally takes the whitespace run
following the comment, and reporting the comment alone would understate what
went by exactly that whitespace.

VERIFIED is the result of the comparison that ran, not a constant.  It says the
file's nodes outside its comments were compared against the original and every
one of them came back unchanged.  It is false when the edit changed nothing,
because then no comparison was performed and there is nothing to report having
proved.  It is never a claim about the whitespace around the comment: a delete
removes some of that by design, and the comparison never looked at it.

ALREADY-UNREADABLE says the file failed to balance or to read before the edit
was made.  A check the file was already failing was skipped rather than charged
to the edit, and saying so is what keeps the caller from reading the success as
a clean bill of health for a file that never had one."
  (let ((report (make-hash-table :test 'equal)))
    (setf (gethash "line_start"               report) line-start
          (gethash "line_end"                 report) line-end
          (gethash "line_end_after"           report) (%inserted-end-line line-start
                                                                          inserted)
          (gethash "before"                   report) (subseq original
                                                              removed-start
                                                              removed-end)
          (gethash "after"                    report) inserted
          (gethash "forms_verified_unchanged" report) verified
          (gethash "already_unreadable"       report) already-unreadable)
    report))

;;;; -------------------------------------------------------------------------
;;;; Public API
;;;; -------------------------------------------------------------------------

(defun %normalize-mode (mode)
  "Return :REGION or :LEADING for MODE, given as a keyword or a string."
  (let ((name (string-downcase (if (symbolp mode) (symbol-name mode) mode))))
    (cond ((string= name "region") :region)
          ((string= name "leading") :leading)
          (t (error 'comment-operation-error
                    :reason (format nil "unsupported mode ~S: use region or leading"
                                    mode))))))

(defun %normalize-operation (operation)
  "Return :REPLACE or :DELETE for OPERATION, given as a keyword or a string.

Inserting is deliberately absent: placing a new comment relative to a form is
already what the form editor's insert operations do."
  (let ((name (string-downcase (if (symbolp operation)
                                   (symbol-name operation)
                                   operation))))
    (cond ((string= name "replace") :replace)
          ((string= name "delete") :delete)
          (t (error 'comment-operation-error
                    :reason (format nil "unsupported operation ~S: use replace or delete"
                                    operation))))))

(defun edit-comment (session-root file-path mode operation
                     &key substring line-start line-end
                          form-type form-name content dry-run readtable)
  "Replace or delete a comment region in FILE-PATH under SESSION-ROOT.

MODE is \"region\" to name a free-standing comment by a unique SUBSTRING of it,
constrained by LINE-START and LINE-END whenever either is given; or \"leading\"
to name the form the comment sits flush on top of, through FORM-TYPE and
FORM-NAME.

OPERATION is \"replace\", which needs CONTENT, or \"delete\".

An anchor naming no comment or more than one signals COMMENT-OPERATION-ERROR
and writes nothing, as do CONTENT that leaves a delimiter or a block comment
open, a comment that begins after code on the same line, and a splice whose
result no longer holds everything the file held outside its comments.  Every
one of those checks runs before the write branch is reached.

A file that already fails to balance or to read is still editable.  The two
whole-file checks run against the original first, and one the file was already
failing is skipped rather than charged to the edit, with the fact reported.
Refusing there would blame the edit for damage that was already present and
would put every comment in the file out of reach for good.  Nothing is left
unguarded by that: the comparison of everything outside the file's comments
runs whatever state the file arrived in, and it is the check that carries the
guarantee.

When DRY-RUN is true the change is previewed and nothing is written.  After a
real write a textDocument/didChange notification is sent to the project's LSP
instance when one is registered; a failure there never reaches the caller.

Returns:
  On dry run: a hash-table with would_change, original, preview, path, mode,
              operation and changed_region.
  On apply:   (values updated-text changed-p changed-region-report)"
  (let ((mode-key (%normalize-mode mode))
        (operation-key (%normalize-operation operation)))
    (when (eq operation-key :replace)
      (unless (stringp content)
        (error 'comment-operation-error
               :reason "content is required to replace a comment region"))
      ;; Checked before the file is read, since it depends on nothing else.
      (%verify-content-self-contained content))
    (ecase mode-key
      (:region
       (unless (and (stringp substring) (plusp (length substring)))
         (error 'comment-operation-error
                :reason "region mode needs a substring naming the comment to edit")))
      (:leading
       (unless (and (stringp form-type) (plusp (length form-type))
                    (stringp form-name) (plusp (length form-name)))
         (error 'comment-operation-error
                :reason "leading mode needs a form type and a form name"))))
    (multiple-value-bind (abs rel original nodes start end region-start-line region-end-line)
        (ecase mode-key
          (:region (%resolve-region-target file-path substring line-start line-end
                                           readtable session-root))
          (:leading (%resolve-leading-target file-path form-type form-name
                                             readtable session-root)))
      ;; The offset resolved here is the one the splice will use, so testing it
      ;; at this point covers every way of naming a comment and cannot be
      ;; bypassed by adding another.  It refuses both operations rather than
      ;; delete alone: replacing with text that carries no newline of its own
      ;; rewrites the same line of code and takes the blank line with it, and
      ;; the form comparison sees neither case, since the forms stay byte for
      ;; byte identical at shifted offsets in both.
      (unless (%starts-its-own-line-p original start)
        (error 'comment-operation-error
               :reason (%same-line-refusal mode-key form-type form-name)))
      (multiple-value-bind (updated removed-start removed-end inserted)
          (%splice original start end operation-key
                   (if (eq operation-key :delete) "" content))
        (let ((would-change (not (string= original updated)))
              (forms-verified nil)
              (already-unreadable nil))
          (when would-change
            ;; Both report fields are these calls' own answers rather than
            ;; constants, so a reader of the report learns what was checked
            ;; instead of what the verb hoped.
            (setf forms-verified
                  (%verify-forms-survived original nodes updated readtable
                                          removed-start removed-end inserted))
            (setf already-unreadable (%verify-still-reads original updated)))
          (let ((report (%changed-region-report original removed-start removed-end
                                                region-start-line region-end-line
                                                inserted forms-verified
                                                already-unreadable)))
            (log-event :debug "lisp.edit.comment"
                       "path" (namestring abs)
                       "mode" (string-downcase (symbol-name mode-key))
                       "operation" (string-downcase (symbol-name operation-key))
                       "dry_run" dry-run
                       "would_change" would-change)
            (cond
              (dry-run
               (let ((preview (make-hash-table :test 'equal)))
                 (setf (gethash "would_change"   preview) would-change
                       (gethash "original"       preview) (subseq original start end)
                       (gethash "preview"        preview) updated
                       (gethash "path"           preview) (namestring abs)
                       (gethash "mode"           preview) (string-downcase
                                                           (symbol-name mode-key))
                       (gethash "operation"      preview) (string-downcase
                                                           (symbol-name operation-key))
                       (gethash "changed_region" preview) report)
                 preview))
              (would-change
               (let ((abs-write (ensure-write-path rel session-root)))
                 (unless abs-write
                   (error 'comment-operation-error
                          :reason (format nil "write path ~A is outside the session root ~A"
                                          rel session-root)))
                 (write-file-string-atomically abs-write updated)
                 (ignore-errors
                   (let ((lsp-client (find-lsp-client session-root)))
                     (when lsp-client
                       (notify-did-change
                        lsp-client abs-write updated
                        (bump-uri-version lsp-client (namestring abs-write)))))))
               (values updated t report))
              (t (values updated nil report)))))))))
