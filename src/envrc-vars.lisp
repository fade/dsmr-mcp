;;;; src/envrc-vars.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Per-variable accessors over the text of a project `.envrc`.
;;;;
;;;; Whether the dsmr-mcp settings are present used to be computed as a
;;;; COMBINATION of variable presences. Two variables produced a three-branch
;;;; shape selection; a third would produce eight states, and the state that is
;;;; genuinely new (both older variables present, the newest one absent) fell
;;;; through to the branch that appends the whole managed block, duplicating the
;;;; exports the file already carried. Asking one variable at a time makes that
;;;; state space disappear, and a fourth or fifth variable later costs nothing.
;;;;
;;;; This is also the first code that READS the `# >>> dsmr-mcp ... >>>` /
;;;; `# <<< dsmr-mcp ... <<<` markers back. They have been written since the
;;;; managed block existed and were never read by any code path, which is
;;;; precisely why nothing could tell an old stanza from a current one:
;;;; detection grepped for variable names instead, so every repository already
;;;; carrying an older stanza was invisible to it. Giving the markers a reader
;;;; is what lets a missing declaration join the region that is already there
;;;; instead of arriving as a second copy of the whole block.
;;;;
;;;; The module is pure text. Every function takes and returns strings, does no
;;;; file IO, and knows nothing about sessions, consent, or elicitation, so it
;;;; is testable from literal fixtures. The IO and the consent gate stay in
;;;; src/envrc-init.lisp.
;;;;
;;;; There is deliberately NO setter over a variable's value. The declaration
;;;; form is `export NAME="${NAME:-<default>}"`, so the operator's own
;;;; environment always wins, and overwriting a hand-edited value would be a
;;;; regression dressed as a cleanup. The two operations are "read what is
;;;; declared" and "ensure a defaulting declaration exists".

(defpackage #:dsmr-mcp/src/envrc-vars
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/slynk-port
                #:derive-slynk-port)
  (:export #:managed-variable
           #:variable-name
           #:variable-default
           #:variable-literal
           #:variable-comment
           #:variable-setup-marker-p
           #:managed-variables
           #:project-basename
           #:defaulting-declaration
           #:declaration-line
           #:declared-value
           #:declared-p
           #:ensure-declaration
           #:ensure-declaration-line
           #:undeclared-variables
           #:setup-complete-p
           #:ensure-managed-declarations
           #:managed-block
           #:managed-region-bounds
           #:region-open-prefix
           #:region-close-prefix
           #:region-open-line
           #:region-close-line))

(in-package #:dsmr-mcp/src/envrc-vars)

;;; ---------------------------------------------------------------------------
;;; Wire-safe string coercion
;;; ---------------------------------------------------------------------------

(defun %chars (s)
  "Return S as a string of element-type CHARACTER.
FORMAT, UIOP and literals can all yield a simple-base-string on SBCL, and a
base-string that reaches the JSON-RPC wire serializes as a `#A(... BASE-CHAR
...)` reader literal that breaks framing. Everything this module hands back is
coerced here so a caller can put it on the wire unchanged."
  (map 'string #'identity s))

;;; ---------------------------------------------------------------------------
;;; Line splitting and rejoining
;;; ---------------------------------------------------------------------------

(defun %split-text (text)
  "Return two values: TEXT's lines without their newlines, and whether TEXT ends
in a newline. Splitting on newline yields one more piece than there are lines
when the text ends in a newline, and that final empty piece is what says so;
rejoining with %JOIN-LINES restores the original bytes exactly."
  (let* ((pieces (uiop:split-string text :separator (list #\Newline)))
         (ends-newline (and (> (length pieces) 1)
                            (string= "" (car (last pieces))))))
    (values (if ends-newline (butlast pieces) pieces)
            ends-newline)))

(defun %join-lines (lines ends-newline)
  "Rejoin LINES with newlines, adding a trailing newline when ENDS-NEWLINE.
The inverse of %SPLIT-TEXT."
  (let ((body (format nil "~{~A~^~%~}" lines)))
    (%chars (if ends-newline
                (concatenate 'string body (string #\Newline))
                body))))

(defun %trim (line)
  "Return LINE without surrounding blanks or a trailing carriage return, so a
file written on another platform reads the same as one written here."
  (string-trim '(#\Space #\Tab #\Return) line))

;;; ---------------------------------------------------------------------------
;;; Reading a declaration
;;; ---------------------------------------------------------------------------

(defparameter +export-prefix+ "export "
  "The shell keyword a managed declaration line begins with. A declaration
without it is still a declaration, so the prefix is optional when reading.")

(defun %declaration-value (line name)
  "Return the expression LINE declares NAME to, or NIL when LINE is not a
declaration of NAME. An empty right-hand side (`export NAME=`) is a declaration
and yields the empty string, which is why the answer is NIL-or-string rather
than a truth value. A comment line declares nothing, so a file that merely
mentions a variable in prose is not treated as having set it."
  (let ((trimmed (%trim line)))
    (when (and (plusp (length trimmed))
               (char/= (char trimmed 0) #\#))
      (let ((rest trimmed)
            (prefix-length (length +export-prefix+)))
        (when (and (>= (length rest) prefix-length)
                   (string= +export-prefix+ rest :end2 prefix-length))
          (setf rest (string-left-trim '(#\Space #\Tab)
                                       (subseq rest prefix-length))))
        (let ((n (length name)))
          (when (and (> (length rest) n)
                     (string= name rest :end2 n)
                     (char= (char rest n) #\=))
            (%chars (subseq rest (1+ n)))))))))

(defun declared-value (text name)
  "Return two values: the expression NAME is declared to somewhere in TEXT, and
whether a declaration was found at all.

The WHOLE text is searched, not only the managed regions, because a hand-written
`export DSMR_BUS_AGENT=foo` outside any marker is respected today and that
contract is not being changed: the operator's own line is a declaration and the
answer must say so."
  (dolist (line (%split-text text) (values nil nil))
    (let ((value (%declaration-value line name)))
      (when value
        (return (values value t))))))

(defun declared-p (text name)
  "True when TEXT declares NAME anywhere."
  (nth-value 1 (declared-value text name)))

;;; ---------------------------------------------------------------------------
;;; Reading the managed-region markers
;;; ---------------------------------------------------------------------------

(defparameter +region-open-prefix+ "# >>> dsmr-mcp"
  "Prefix every managed-region opening marker starts with. Matching on the
prefix rather than the whole line is what tolerates the three flavours already
in the wild: unqualified, `(bus)`, and `(slynk)`. Their trailing text differs;
their prefix never has.")

(defparameter +region-close-prefix+ "# <<< dsmr-mcp"
  "Prefix every managed-region closing marker starts with. See
+REGION-OPEN-PREFIX+ for why this is a prefix match.")

(defparameter +region-open-line+
  "# >>> dsmr-mcp (added automatically; edit or remove freely) >>>"
  "The opening marker written when a `.envrc` gains its first managed region.
Names the region as machine-written and says plainly that hand-editing it is
allowed, because the declarations inside it defer to the operator's environment
anyway.")

(defparameter +region-close-line+ "# <<< dsmr-mcp <<<"
  "The closing marker written when a `.envrc` gains its first managed region.")

(defun region-open-prefix () +region-open-prefix+)
(defun region-close-prefix () +region-close-prefix+)
(defun region-open-line () +region-open-line+)
(defun region-close-line () +region-close-line+)

(defun %prefixed-p (line prefix)
  "True when LINE, ignoring surrounding blanks, begins with PREFIX."
  (let ((trimmed (%trim line)))
    (and (>= (length trimmed) (length prefix))
         (string= prefix trimmed :end2 (length prefix)))))

(defun managed-region-bounds (text)
  "Return the managed regions in TEXT as a list of (OPEN-INDEX . CLOSE-INDEX)
line-index pairs, in the order they appear. An opening marker with no closing
marker after it contributes no region, so a half-written region is ignored
rather than swallowing the rest of the file."
  (let ((open nil)
        (regions '()))
    (loop for line in (%split-text text)
          for index from 0
          do (cond ((%prefixed-p line +region-open-prefix+)
                    (setf open index))
                   ((and open (%prefixed-p line +region-close-prefix+))
                    (push (cons open index) regions)
                    (setf open nil))))
    (nreverse regions)))

;;; ---------------------------------------------------------------------------
;;; Ensuring a declaration exists
;;; ---------------------------------------------------------------------------

(defun defaulting-declaration (name default)
  "Return the override-preserving export line for NAME:
`export NAME=\"${NAME:-DEFAULT}\"`. The shell expansion is what keeps the
operator's own environment authoritative: the default applies only when nothing
already set the variable."
  (%chars (format nil "export ~A=\"${~A:-~A}\"" name name default)))

(defun ensure-declaration-line (text name line)
  "Ensure TEXT declares NAME, adding LINE verbatim when it does not.

Returns two values: the resulting text and whether anything changed. When NAME
is already declared the original TEXT is returned unchanged and EQ to what came
in, so an existing declaration, including one the operator hand-edited, is never
rewritten.

A new line joins the LAST managed region when the file has one, which is what
keeps a repeat visit from stacking a fresh block beside the block already there.
With no region at all a new one is appended after a blank-line separator, and a
file that does not end in a newline gets one first so the marker never joins the
operator's last line."
  (if (declared-p text name)
      (values text nil)
      (multiple-value-bind (lines ends-newline) (%split-text text)
        (let ((regions (managed-region-bounds text)))
          (if regions
              (let ((close (cdr (car (last regions)))))
                (values (%join-lines (append (subseq lines 0 close)
                                             (list line)
                                             (nthcdr close lines))
                                     ends-newline)
                        t))
              (values (%join-lines (append lines
                                           (list ""
                                                 +region-open-line+
                                                 line
                                                 +region-close-line+))
                                   t)
                      t))))))

(defun ensure-declaration (text name default)
  "Ensure TEXT declares NAME, adding `export NAME=\"${NAME:-DEFAULT}\"` when it
does not. Returns the resulting text and whether anything changed.

This is the only write this module offers and it is not a setter: it adds a
declaration that was absent and never touches one that was present."
  (ensure-declaration-line text name (defaulting-declaration name default)))

;;; ---------------------------------------------------------------------------
;;; The managed variable table
;;; ---------------------------------------------------------------------------

(defstruct (managed-variable (:conc-name variable-)
                             (:constructor %make-managed-variable))
  "One variable dsmr-mcp declares in a project `.envrc`.

NAME is the shell variable. DEFAULT, when present, computes the default
expression from an optional project root and the declaration takes the
override-preserving `${NAME:-...}` form. LITERAL, used instead of DEFAULT, is
the exact right-hand side for a variable that is not operator-defaultable
because it is derived from the others or is a fixed setting.

COMMENT is the explanatory text that precedes the variable in the shipped
template. The managed block does not emit it; it is carried here so the template
and this table have one place to agree.

SETUP-MARKER-P says whether this variable answers the question \"has this
`.envrc` had the dsmr-mcp settings applied at all\". Only the markers count
towards that, so removing a supporting line by hand does not turn a settled file
back into one that gets offered the settings again every session."
  (name "" :type string)
  (default nil :type (or null function))
  (literal nil :type (or null string))
  (comment nil :type (or null string))
  (setup-marker-p nil :type boolean))

(defun project-basename (project-root)
  "Return the last directory component of PROJECT-ROOT as a CHARACTER string,
for example #p\"/tmp/myproj/\" yields \"myproj\". This is the default bus
identity: a project's stable main-agent name. A NIL root, or one with no
directory component, falls back to the neutral literal \"agent\" so the
declaration is always a valid override-preserving export."
  (let* ((dir (and project-root
                   (pathname-directory
                    (uiop:ensure-directory-pathname project-root))))
         (last-component (and (consp dir) (car (last dir)))))
    (if (and (stringp last-component) (plusp (length last-component)))
        (%chars last-component)
        "agent")))

(defun %derived-slynk-port (project-root)
  "Return the per-project Slynk port for PROJECT-ROOT as a string, falling back
to the legacy literal 4005 when there is no root or the derivation fails. Two
projects brought up in attached mode on one shared port converge on whichever
image grabbed it first, so the derived value is what keeps them apart."
  (let ((derived (and project-root
                      (handler-case (derive-slynk-port project-root)
                        (error () nil)))))
    (if derived (princ-to-string derived) "4005")))

(defparameter +managed-variables+
  (list
   (%make-managed-variable
    :name "LISP_WORKSPACE"
    :default (lambda (project-root)
               (declare (ignore project-root))
               "$HOME/SourceCode/lisp/"))
   (%make-managed-variable
    :name "SLYNK_HOST"
    :comment "# This project's Slynk listener. scripts/dev-boot.sh reads the same two vars,
# so dev-boot and dsmr-mcp stay in sync (single source of truth)."
    :default (lambda (project-root)
               (declare (ignore project-root))
               "127.0.0.1"))
   (%make-managed-variable
    :name "SLYNK_PORT"
    :default #'%derived-slynk-port)
   (%make-managed-variable
    :name "DSMR_MODE"
    :comment "# auto = attach to the image above if reachable, else a private hermetic worker."
    :literal "auto")
   (%make-managed-variable
    :name "DSMR_SLYNK_ATTACH"
    :literal "\"${SLYNK_HOST}:${SLYNK_PORT}\""
    :setup-marker-p t)
   (%make-managed-variable
    :name "DSMR_LOG_LEVEL"
    :literal "info")
   (%make-managed-variable
    :name "DSMR_BUS_AGENT"
    :comment "# This project's stable bus identity. The dsmr-mcp coordination bus uses it so
# this project's main agent resumes its durable message cursor across restarts
# instead of getting a fresh ephemeral id every launch. Defaults to the project
# directory name; override by exporting DSMR_BUS_AGENT before direnv loads."
    :default #'project-basename
    :setup-marker-p t))
  "Every variable dsmr-mcp declares in a project `.envrc`, in the order the
managed block writes them. This is the single place a new variable is added: the
block, the presence question, and the per-variable append all read it, so they
cannot disagree about spelling, order, or defaults.")

(defun managed-variables ()
  "Return the managed variable table in declaration order."
  +managed-variables+)

(defun declaration-line (variable &optional project-root)
  "Return the complete export line VARIABLE contributes to a `.envrc`, with any
defaults resolved against PROJECT-ROOT."
  (let ((default (variable-default variable)))
    (if default
        (defaulting-declaration (variable-name variable)
                                (funcall default project-root))
        (%chars (format nil "~A~A=~A"
                        +export-prefix+
                        (variable-name variable)
                        (variable-literal variable))))))

;;; ---------------------------------------------------------------------------
;;; Table-driven questions and the table-driven append
;;; ---------------------------------------------------------------------------

(defun undeclared-variables (text)
  "Return the managed variables TEXT does not declare, in table order."
  (remove-if (lambda (variable) (declared-p text (variable-name variable)))
             +managed-variables+))

(defun setup-complete-p (text)
  "True when TEXT declares every managed variable that marks the dsmr-mcp
settings as applied.

Only the marker variables are asked about. Widening the question to every
managed variable would re-offer the settings to any file whose operator
deliberately deleted a supporting line, which is the opposite of respecting what
they wrote."
  (every (lambda (variable)
           (or (not (variable-setup-marker-p variable))
               (declared-p text (variable-name variable))))
         +managed-variables+))

(defun ensure-managed-declarations (text &optional project-root)
  "Ensure TEXT declares every managed variable, adding only the ones it lacks.
Returns the resulting text and whether anything changed.

Folding one ensure per variable is what removes the combinatorial shape
selection: a variable already declared contributes nothing, so the whole
already-complete case is the fold reporting no change rather than a separate
check that has to be kept in step with the question that got us here."
  (let ((result text)
        (changed nil))
    (dolist (variable +managed-variables+ (values result changed))
      (multiple-value-bind (next did-change)
          (ensure-declaration-line result
                                   (variable-name variable)
                                   (declaration-line variable project-root))
        (setf result next)
        (when did-change (setf changed t))))))

(defun managed-block (&optional project-root)
  "Return the complete marker-delimited managed block for PROJECT-ROOT: the
opening marker, one declaration per managed variable in table order, and the
closing marker, ending in a newline. This is the creation shape for a `.envrc`
that has no dsmr-mcp region at all."
  (%chars
   (with-output-to-string (out)
     (write-line +region-open-line+ out)
     (dolist (variable +managed-variables+)
       (write-line (declaration-line variable project-root) out))
     (write-line +region-close-line+ out))))
