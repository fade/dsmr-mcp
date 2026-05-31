(:mallet-config
 (:extends :default)
 ;; Arbitrary eval and ignore-errors are intentional in the dispatcher and the
 ;; attached-image injection paths; the threat model documents the trusted,
 ;; localhost-only posture that makes them acceptable.
 (:disable :no-eval)
 (:disable :no-ignore-errors)
 ;; Uniform LET* for sequential binding blocks is a deliberate, codebase-wide
 ;; idiom: it keeps binding forms editable without churning LET<->LET* when a
 ;; later binding starts referencing an earlier one. A style choice, not a
 ;; correctness issue.
 (:disable :needless-let*)
 ;; This is a package-inferred-system: each file's defpackage imports the
 ;; symbols it consumes, and many of those imports exist to be re-exported or
 ;; consumed across the package boundary by a sibling tool/transport package.
 ;; The linter's single-file view cannot see the cross-package use or the
 ;; :export re-surface, so it reports those imports as unused. Keeping the
 ;; imports explicit documents each file's true dependency surface.
 (:disable :unused-imported-symbols)
 ;; A few destructuring/lambda parameters are named deliberately for
 ;; documentation and forward-compatibility even where the current body does
 ;; not reference them.
 (:disable :unused-variables)
 ;; The jzon local nickname is kept on the helpers package for call sites that
 ;; reference it by nickname elsewhere in the dependency tree.
 (:disable :unused-local-nicknames)
 ;; build-wrapping-form takes a positional PACKAGE-NAME followed by keyword
 ;; options (REGISTER-RESULT, SESSION-ID, SURFACE-RAW-VALUE). The mixed
 ;; &optional/&key lambda list is a deliberate, stable API shape shared with
 ;; both call sites; reshaping it on the wire-injection hot path carries more
 ;; risk than the readability nit warrants.
 (:for-paths ("src/attach/wrap-form.lisp")
   (:disable :mixed-optional-and-key)))
