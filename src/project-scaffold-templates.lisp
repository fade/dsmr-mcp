;;;; src/project-scaffold-templates.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Template string constants for project-scaffold (VERB-22).
;;;; Kept in a dedicated module so bulk literal content stays out of the
;;;; logic layer. All templates use {{key}} placeholders resolved by
;;;; render-template in project-scaffold-core.
;;;;
;;;; Placeholders used across templates:
;;;;   {{name}}         — project name (kebab-case, e.g. foo-lib)
;;;;   {{description}}  — one-line project description
;;;;   {{author}}       — author string
;;;;   {{license}}      — SPDX license identifier (e.g. AGPL-3.0-or-later)
;;;;   {{spdx}}         — same as {{license}}, used in per-file SPDX headers
;;;;   {{copyright}}    — copyright holder (name or org)
;;;;   {{year}}         — copyright year (e.g. 2026)
;;;;   {{license-body}} — full text of the chosen license

(defpackage #:dsmr-mcp/src/project-scaffold-templates
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/envrc-template
                #:read-envrc-template)
  (:export #:*asd-template*
           #:*main-lisp-template*
           #:*main-test-template*
           #:*build-template*
           #:*dev-boot-template*
           #:*agents-md-template*
           #:*claude-md-template*
           #:*readme-template*
           #:*gitignore-template*
           #:*mallet-config-template*
           #:*lint-lisp-template*
           #:*pre-commit-hook-template*
           #:*prompt-template*
           #:*envrc-template*
           #:*license-template*
           #:license-body-for-spdx))

(in-package #:dsmr-mcp/src/project-scaffold-templates)

;;; ---------------------------------------------------------------------------
;;; .asd template (package-inferred-system; Parachute in tests)
;;; ---------------------------------------------------------------------------

(defparameter *asd-template*
  ";;;; {{name}}.asd
;;;; SPDX-License-Identifier: {{spdx}}

(asdf:defsystem \"{{name}}\"
  :class :package-inferred-system
  :description \"{{description}}\"
  :author \"{{author}}\"
  :license \"{{license}}\"
  :version \"0.1.0\"
  :depends-on (\"{{name}}/src/main\")
  :in-order-to ((test-op (test-op \"{{name}}/tests\"))))

(asdf:defsystem \"{{name}}/tests\"
  :class :package-inferred-system
  :depends-on (\"parachute\"
               \"{{name}}\"
               \"{{name}}/tests/main-test\")
  :perform (test-op (o c)
                    (declare (ignore o))
                    (let* ((test-package-names
                            (remove-if-not
                             (lambda (dep)
                               (and (stringp dep)
                                    (uiop:string-prefix-p \"{{name}}/tests/\" dep)))
                             (asdf:system-depends-on c)))
                           (any-failed nil))
                      (dolist (name test-package-names)
                        (let* ((pkg (or (find-package (string-upcase name))
                                        (error \"Test package ~S not loaded.\" name)))
                               (result (uiop:symbol-call :parachute :test pkg)))
                          (when (uiop:symbol-call :parachute :results-with-status
                                                  :failed result)
                            (setf any-failed t))))
                      (when any-failed
                        (error \"{{name}}/tests: one or more parachute tests failed.\")))))
"
  "Template for the generated project's .asd system definition.
Uses Parachute (not Rove) for the test perform hook, matching the
package-inferred-system + Parachute convention of dsmr-mcp itself.")

;;; ---------------------------------------------------------------------------
;;; src/main.lisp template (empty package + mode-dispatching main)
;;; ---------------------------------------------------------------------------

(defparameter *main-lisp-template*
  ";;;; src/main.lisp
;;;; SPDX-License-Identifier: {{spdx}}
;;;;
;;;; Entry point for {{name}}. Edit the run/daemon/dev mode bodies below;
;;;; the dispatch skeleton is wired — add your own defuns/defclasses here
;;;; and in additional src/*.lisp files.

(defpackage #:{{name}}/src/main
  (:use #:cl))

(in-package #:{{name}}/src/main)

;;; Keep this defvar here so --version works before any other load.
(defvar *version* \"0.1.0\"
  \"Version string for {{name}}.\")

(defun show-help ()
  \"Print usage information and exit.\"
  (format t \"{{name}} v~A~%~%\" *version*)
  (format t \"Usage: {{name}} [options]~%~%\")
  (format t \"Options:~%\")
  (format t \"  --daemon   Run headless in the background~%\")
  (format t \"  --dev      Start with Slynk dev listener (SLYNK_PORT, SLYNK_HOST)~%\")
  (format t \"  --version  Print version and exit~%\")
  (format t \"  --help     Show this message~%\"))

(defun run-foreground ()
  \"Foreground run mode. Replace this with your application logic.\"
  (format t \"{{name}}: running in foreground mode~%\")
  ;; TODO: add foreground run logic here.
  )

(defun run-daemon ()
  \"Headless daemon mode. Replace this with your background logic.\"
  (format t \"{{name}}: running in daemon mode~%\")
  ;; TODO: add daemon/background logic here.
  )

(defun start-dev ()
  \"Dev mode: load Slynk and start a listener so an editor or dsmr-mcp can attach.\"
  (let ((port (or (ignore-errors
                   (parse-integer (uiop:getenv \"SLYNK_PORT\")))
                  4005))
        (host (or (uiop:getenv \"SLYNK_HOST\") \"127.0.0.1\")))
    (asdf:load-system :slynk)
    (uiop:symbol-call :slynk :create-server :port port :interface host :dont-close t)
    (format t \"{{name}}: Slynk listening on ~A:~A~%\" host port)
    ;; Fall through to foreground run so the process stays alive.
    (run-foreground)))

(defun main (&rest args)
  \"Main entry point. Dispatches on command-line arguments.\"
  (let ((mode :run))
    (loop for arg in args do
      (cond ((string= arg \"--daemon\")  (setf mode :daemon))
            ((string= arg \"--dev\")     (setf mode :dev))
            ((string= arg \"--version\")
             (format t \"{{name}} v~A~%\" *version*)
             (return-from main 0))
            ((string= arg \"--help\")
             (show-help)
             (return-from main 0))))
    (ecase mode
      (:run    (run-foreground))
      (:daemon (run-daemon))
      (:dev    (start-dev))))
  0)
"
  "Template for the generated project's src/main.lisp.
Ships an empty package + mode-dispatching main (run/daemon/dev).
No :export and no stub defun — the package starts clean so the first
load-system pins no symbols and there is no package-variance on reload.")

;;; ---------------------------------------------------------------------------
;;; tests/main-test.lisp template (Parachute smoke)
;;; ---------------------------------------------------------------------------

(defparameter *main-test-template*
  ";;;; tests/main-test.lisp
;;;; SPDX-License-Identifier: {{spdx}}
;;;;
;;;; Smoke test for {{name}}: asserts the main package loaded cleanly.
;;;; Replace or extend this file to add real tests for your code.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:{{name}}/tests/main-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:{{name}}/tests/main-test
  (:use #:cl #:parachute))

(in-package #:{{name}}/tests/main-test)

(define-test scaffold-smoke
  \"Asserts the project main package loaded cleanly.\"
  (true (find-package :{{name}}/src/main)))
"
  "Template for the generated project's tests/main-test.lisp.
Uses Parachute (not Rove). The smoke test asserts only package existence
— it holds no reference to any symbol the empty main package does not
export, so the generated project loads and tests cleanly out of the box.")

;;; ---------------------------------------------------------------------------
;;; build script template (sb-ext:save-lisp-and-die, D-09)
;;; ---------------------------------------------------------------------------

(defparameter *build-template*
  "#!/usr/bin/env bash
# build.sh — produce a standalone {{name}} binary via SBCL.
#
# Usage: ./build.sh [--output PATH]
#   --output PATH   where to write the binary (default: bin/{{name}})
#
# Requires SBCL and all ASDF deps available (via LISP_WORKSPACE or Quicklisp).
#
# SPDX-License-Identifier: {{spdx}}

set -euo pipefail

PROJECT_ROOT=\"$(cd \"$(dirname \"$0\")\" && pwd)\"
OUTPUT=\"${1:-$PROJECT_ROOT/bin/{{name}}}\"
QUICKLISP_SETUP=\"${QUICKLISP_SETUP:-${HOME}/quicklisp/setup.lisp}\"
LISP_WORKSPACE=\"${LISP_WORKSPACE:-${HOME}/SourceCode/lisp}\"
LISP_WORKSPACE=\"${LISP_WORKSPACE/#\\~/$HOME}\"

mkdir -p \"$(dirname \"$OUTPUT\")\"

sbcl --noinform \\
     --no-userinit \\
     --eval \"(require :asdf)\" \\
     --eval \"(when (probe-file \\\"$QUICKLISP_SETUP\\\") (load \\\"$QUICKLISP_SETUP\\\"))\" \\
     --eval \"(push \\\"$LISP_WORKSPACE/\\\" asdf:*central-registry*)\" \\
     --eval \"(asdf:load-asd \\\"$PROJECT_ROOT/{{name}}.asd\\\")\" \\
     --eval \"(asdf:load-system :{{name}})\" \\
     --eval \"(sb-ext:save-lisp-and-die \\\"$OUTPUT\\\"
               :toplevel #'{{name}}/src/main:main
               :executable t
               :compression t)\"

echo \"Built: $OUTPUT\"
"
  "Template for the generated project's build script (D-09).
Invokes sb-ext:save-lisp-and-die to produce a standalone binary.
SBCL-only, matching the v1 scope.")

;;; ---------------------------------------------------------------------------
;;; scripts/dev-boot.sh template (D-10)
;;; ---------------------------------------------------------------------------

(defparameter *dev-boot-template*
  "#!/usr/bin/env bash
# scripts/dev-boot.sh — bring up a {{name}} development image.
#
# Starts SBCL with LISP_WORKSPACE source-registry, loads {{name}},
# then starts a Slynk listener so an editor or dsmr-mcp can attach.
# A project-specific dev-tooling hook is called if it exists.
#
# Pass --background to detach; logs go to /tmp/{{name}}-dev.log.
#
# Env (all optional):
#   SLYNK_PORT       slynk listen port      (default: project-specific)
#   SLYNK_HOST       slynk listen address   (default 127.0.0.1)
#   LISP_WORKSPACE   local-projects tree    (default ~/SourceCode/lisp/)
#   QUICKLISP_SETUP  quicklisp setup.lisp   (default ~/quicklisp/setup.lisp)
#
# SPDX-License-Identifier: {{spdx}}

set -euo pipefail

PROJECT_ROOT=\"$(cd \"$(dirname \"$0\")/..\" && pwd)\"
SLYNK_PORT=\"${SLYNK_PORT:-4005}\"
SLYNK_HOST=\"${SLYNK_HOST:-127.0.0.1}\"
LISP_WORKSPACE=\"${LISP_WORKSPACE:-${HOME}/SourceCode/lisp}\"
QUICKLISP_SETUP=\"${QUICKLISP_SETUP:-${HOME}/quicklisp/setup.lisp}\"
BACKGROUND=0

LISP_WORKSPACE=\"${LISP_WORKSPACE/#\\~/$HOME}\"
LISP_WORKSPACE=\"${LISP_WORKSPACE%/}\"

for arg in \"$@\"; do
  case \"$arg\" in
    --background|-b) BACKGROUND=1 ;;
    --help|-h)
      sed -n '3,/^$/p' \"$0\" | sed 's/^# \\{0,1\\}//'
      exit 0
      ;;
    *)
      echo \"unknown arg: $arg (try --help)\" >&2
      exit 2
      ;;
  esac
done

if [ ! -f \"$QUICKLISP_SETUP\" ]; then
  echo \"ERROR: quicklisp setup.lisp not found at $QUICKLISP_SETUP\" >&2
  exit 1
fi

if [ ! -d \"$LISP_WORKSPACE\" ]; then
  echo \"ERROR: LISP_WORKSPACE=$LISP_WORKSPACE does not exist\" >&2
  exit 1
fi

# Bump SLYNK_PORT past any occupied port so concurrent projects use distinct listeners.
while nc -z \"${SLYNK_HOST}\" \"${SLYNK_PORT}\" 2>/dev/null; do
  echo \"[dev-boot] port ${SLYNK_PORT} is occupied, bumping to $((SLYNK_PORT + 1))\" >&2
  SLYNK_PORT=$((SLYNK_PORT + 1))
done

# Remove any stale handshake on exit so dsmr-mcp does not follow a dead pointer.
trap 'rm -f \"${PROJECT_ROOT}/.dsmr-slynk.port\"' EXIT INT TERM

export SLYNK_PORT SLYNK_HOST LISP_WORKSPACE PROJECT_ROOT

SBCL_ARGS=(
  --noinform
  --dynamic-space-size 2048
  --disable-debugger
  --load \"$QUICKLISP_SETUP\"
  --eval \"(push \\\"$LISP_WORKSPACE/\\\" asdf:*central-registry*)\"
  --eval \"(asdf:load-asd \\\"$PROJECT_ROOT/{{name}}.asd\\\")\"
  --eval \"(asdf:load-system :{{name}})\"
  --eval \"(asdf:load-system :slynk)\"
  --eval \"(let ((bound-port (uiop:symbol-call :slynk :create-server
                               :port (parse-integer (uiop:getenv \\\"SLYNK_PORT\\\"))
                               :interface (uiop:getenv \\\"SLYNK_HOST\\\")
                               :dont-close t)))
             (with-open-file (f (concatenate 'string
                                              (uiop:getenv \\\"PROJECT_ROOT\\\")
                                              \\\"/.dsmr-slynk.port\\\")
                                :direction :output :if-exists :supersede
                                :if-does-not-exist :create)
               (format f \\\"~A:~A~%\\\" (uiop:getenv \\\"SLYNK_HOST\\\") bound-port))
             (format t \\\"~&{{name}} dev image live — Slynk on ~A:~A~%\\\"
                       (uiop:getenv \\\"SLYNK_HOST\\\") bound-port))\"
  --eval \";; Project dev-tooling hook: add your dev-only setup in scripts/dev-init.lisp\"
  --eval \"(let ((hook \\\"$PROJECT_ROOT/scripts/dev-init.lisp\\\"))
             (when (probe-file hook) (load hook)))\"
  --eval \"(loop (sleep 60))\"
)

if [ \"$BACKGROUND\" -eq 1 ]; then
  LOG=/tmp/{{name}}-dev.log
  PIDFILE=/tmp/{{name}}-dev.pid
  echo \"[dev-boot] starting in background — log: $LOG\"
  : > \"$LOG\"
  setsid sbcl \"${SBCL_ARGS[@]}\" >\"$LOG\" 2>&1 < /dev/null &
  echo $! > \"$PIDFILE\"
  disown
  echo \"[dev-boot] pid $(cat \"$PIDFILE\") — tail -f $LOG to follow\"
else
  echo \"[dev-boot] starting in foreground (Ctrl-C to stop)\"
  exec sbcl \"${SBCL_ARGS[@]}\"
fi
"
  "Template for the generated project's scripts/dev-boot.sh (D-10).
Generalizes eve-quant's dev-boot.sh: SBCL + LISP_WORKSPACE source-registry
+ load system + Slynk on configurable port + project dev-tooling hook.
App-specific bring-up (postgres, ESI, TUI) stripped out; the new project
adds its own dev-init.lisp hook.")

;;; ---------------------------------------------------------------------------
;;; AGENTS.md template (dependency-preference hierarchy, D-13)
;;; ---------------------------------------------------------------------------

(defparameter *agents-md-template*
  "# Repository Guidelines

@prompts/repl-driven-development.md

## Project: {{name}}

{{description}}

## Dependency Preferences (Lisp ecosystem)

When adding or evaluating Lisp dependencies, follow this priority order:

1. **Our own systems first.** Code already in the project or this workspace
   takes precedence. Search with `clgrep-search` and `code-find` before
   reaching for an external library.

2. **Local checkouts of git forks** under `$LISP_WORKSPACE/`. Fork the
   upstream on GitHub (or clone directly for non-GitHub repos), verify the
   checkout is up to date, then add it as a local ASDF dependency. This keeps
   the dep patchable and structure-aware.

3. **Quicklisp as a last resort** — only when no local checkout exists and the
   dep is stable enough that upstream drift is not a concern. Prefer jzon over
   yason for JSON work.

Per-hacker overrides: each developer's `$LISP_WORKSPACE` may contain
personal forks or additional systems. Those take precedence over the
shared baseline above.

## Build and Test

Load the system:
```lisp
(asdf:load-system :{{name}})
```

Run tests:
```lisp
(asdf:test-system :{{name}})
```

Or via dsmr-mcp: `run-tests` with `{\"system\": \"{{name}}/tests\"}`.

## Coding Style

- 2-space indent, <=100 columns, lisp-case identifiers
- Docstrings on all exported functions
- Symbol names describe behavior, not planning artifacts or ticket numbers
- What + Why in comments, not How
"
  "Template for the generated project's AGENTS.md (D-13).
Encodes the dep-preference hierarchy and references the copied prompt.")

;;; ---------------------------------------------------------------------------
;;; CLAUDE.md template (D-12, D-13)
;;; ---------------------------------------------------------------------------

(defparameter *claude-md-template*
  "# CLAUDE.md

@prompts/repl-driven-development.md

## Project: {{name}}

{{description}}

## Dependency Preferences

Same as AGENTS.md: our own systems → local forks under `$LISP_WORKSPACE/` →
Quicklisp last resort. Per-developer `$LISP_WORKSPACE` overrides apply.
Prefer `com.inuoe.jzon` over `yason` for JSON.

## Development Workflow

1. `fs-set-project-root` with `{\"path\": \".\"}` at session start.
2. Load: `load-system` with `{\"system\": \"{{name}}\"}`.
3. Edit: `lisp-edit-form` or `lisp-patch-form` for existing forms;
   `fs-write-file` for new files.
4. Test: `run-tests` with `{\"system\": \"{{name}}/tests\"}`.
5. Inspect: `repl-eval` for quick checks; `inspect-object` to drill in.

## Repository Structure

`{{name}}.asd`       ASDF system definition (package-inferred-system)
`src/main.lisp`      Entry point + CLI dispatch (run/daemon/dev modes)
`tests/main-test.lisp` Parachute smoke test
`scripts/dev-boot.sh`  Dev image launcher (Slynk on SLYNK_PORT)
`build.sh`           Produce a standalone binary via save-lisp-and-die
`prompts/`           Agent instruction prompts

## Running the Dev Image

```bash
./scripts/dev-boot.sh          # foreground
./scripts/dev-boot.sh --background  # detach; tail /tmp/{{name}}-dev.log
```
"
  "Template for the generated project's CLAUDE.md (D-12, D-13).
References the copied prompt and documents the dev workflow.")

;;; ---------------------------------------------------------------------------
;;; README.md template
;;; ---------------------------------------------------------------------------

(defparameter *readme-template*
  "# {{name}}

{{description}}

## Requirements

- SBCL 2.x
- ASDF 3.x
- All deps available via `$LISP_WORKSPACE/` or Quicklisp

## Load

```lisp
(asdf:load-system :{{name}})
```

## Test

```lisp
(asdf:test-system :{{name}})
```

## Run

```bash
# Foreground:
sbcl --eval '(asdf:load-system :{{name}})' --eval '({{name}}/src/main:main)'

# Build binary:
./build.sh

# Dev image (Slynk listener):
./scripts/dev-boot.sh
```

## License

{{license}} — see `LICENSE`.

Copyright (c) {{year}} {{copyright}}.
"
  "Template for the generated project's README.md.")

;;; ---------------------------------------------------------------------------
;;; .gitignore template
;;; ---------------------------------------------------------------------------

(defparameter *gitignore-template*
  "*.fasl
*.ufasl
*.x86f
*.cfasl
.asdf-cache/
bin/
*.log
*.pid
.dsmr-slynk.port
"
  "Template for the generated project's .gitignore.")

;;; ---------------------------------------------------------------------------
;;; Quality-gate templates: linter config, lint runner, pre-commit hook
;;;
;;; These three are one unit. Across the repositories measured on this host the
;;; linter config and the lint script co-occur exactly, and the hook is what
;;; makes either of them take effect, so a partial install is a shape that does
;;; not occur in practice and should not be reported as three separate misses.
;;; ---------------------------------------------------------------------------

(defparameter *mallet-config-template*
  "(:mallet-config
 (:extends :default)

 ;; This is a package-inferred system: each file's defpackage imports the
 ;; symbols it consumes, and some of those imports exist to be re-exported or
 ;; used across a package boundary by a sibling package. The linter reads one
 ;; file at a time and cannot see the cross-package use, so it reports those
 ;; imports as unused. Keeping them explicit is what documents each file's real
 ;; dependency surface.
 (:disable :unused-imported-symbols)

 ;; The gate is new and the code is not. What it reports on a first run is a
 ;; record of what is already here rather than a claim that any of it is wrong.
 ;; Holding these categories below the failing threshold keeps every site
 ;; visible without blocking a commit, which is the only way the record
 ;; survives: a rule that blocks before the codebase can satisfy it just gets
 ;; switched off, and switched off it reports nothing at all. Raising them is a
 ;; deliberate decision to take once the reports have been worked through.
 (:set-severity :style {{gate-severity}})
 (:set-severity :cleanliness {{gate-severity}}))
"
  "Template for a project's .mallet.lisp linter configuration.
Carries a {{gate-severity}} placeholder for the severity a newly installed
gate starts at, which is supplied per project rather than fixed here. The only
blanket disable is one this project can defend from its own structure; every
other suppression belongs to the repository that needs it, with its own reason
written beside it.")

(defparameter *lint-lisp-template*
  "#!/usr/bin/env bash
# scripts/lint-lisp.sh: run the mallet linter over this project's Lisp sources.
#
# Usage: ./scripts/lint-lisp.sh [file ...]
#   With no arguments, lints every .lisp file under src/ and tests/.
#
# The linter is invoked by absolute path deliberately. A binary named 'mallet'
# on PATH belongs to an unrelated Java toolkit that happens to share the name,
# and reaching it instead would either fail in a confusing way or appear to
# succeed having linted nothing. Set MALLET to override the location.
#
# SPDX-License-Identifier: {{spdx}}

set -euo pipefail

MALLET=\"${MALLET:-$HOME/.local/share/mallet/mallet}\"
PROJECT_ROOT=\"$(cd \"$(dirname \"$0\")/..\" && pwd)\"

if [ ! -x \"$MALLET\" ]; then
  echo \"lint-lisp: no linter at $MALLET\" >&2
  echo \"lint-lisp: install it there, or set MALLET to its location.\" >&2
  exit 127
fi

cd \"$PROJECT_ROOT\"

if [ \"$#\" -gt 0 ]; then
  exec \"$MALLET\" \"$@\"
fi

SOURCES=()
while IFS= read -r file; do
  SOURCES+=(\"$file\")
done < <(find src tests -type f -name '*.lisp' 2>/dev/null | sort)

if [ \"${#SOURCES[@]}\" -eq 0 ]; then
  echo \"lint-lisp: no .lisp files under src/ or tests/; nothing to lint.\" >&2
  exit 0
fi

exec \"$MALLET\" \"${SOURCES[@]}\"
"
  "Template for a project's scripts/lint-lisp.sh.
Runs the linter over src/ and tests/, or over the files named on the command
line. Exits non-zero when the linter reports a violation at or above its
failing threshold, which is what lets the pre-commit hook be a gate rather
than a notification.")

(defparameter *pre-commit-hook-template*
  "#!/usr/bin/env bash
# pre-commit: refuse a commit the Lisp linter rejects.
#
# This hook lives under the repository's git directory, which is never part of
# the working tree and never reaches an upstream. That is what makes it safe to
# install in a repository we do not own: it changes nothing a maintainer sees.
#
# It runs the repository's own scripts/lint-lisp.sh and nothing else, with no
# arguments taken from the commit.
#
# Bypass a single commit with: git commit --no-verify
#
# SPDX-License-Identifier: {{spdx}}

set -euo pipefail

REPO_ROOT=\"$(git rev-parse --show-toplevel)\"
LINT=\"$REPO_ROOT/scripts/lint-lisp.sh\"

if [ ! -x \"$LINT\" ]; then
  echo \"pre-commit: $LINT is missing or not executable.\" >&2
  echo \"pre-commit: the Lisp gate is NOT running for this commit.\" >&2
  exit 0
fi

if ! \"$LINT\"; then
  echo >&2
  echo \"pre-commit: the Lisp linter rejected this tree.\" >&2
  echo \"pre-commit: fix the reports above, or commit with --no-verify.\" >&2
  exit 1
fi
"
  "Template for a project's pre-commit hook.
Invokes only the repository's own lint script, with no data interpolated from
the commit being made. Announces loudly and lets the commit through when the
lint script is absent: an incompletely installed gate should be visible, not a
wall that blocks every commit in the repository until someone reinstalls it.")

;;; ---------------------------------------------------------------------------
;;; REPL-driven-development prompt template (D-12)
;;;
;;; Read at load time from the dsmr-mcp source tree rather than inlined as an
;;; escaped Lisp string: the prompt is markdown full of JSON examples (and thus
;;; double-quotes), and keeping it as a real .md sidecar means it stays editable
;;; and lint-able as markdown.  asdf:system-relative-pathname resolves against
;;; the source directory, so an edit to the .md is picked up on the next load
;;; (no stale-fasl coupling that a read-time #. would introduce).  plan-scaffold
;;; copies the rendered result into every scaffolded project's own prompts/ dir,
;;; so generated projects are self-contained (no parent-pointing @-include).
;;; ---------------------------------------------------------------------------

(defparameter *prompt-template*
  (uiop:read-file-string
   (asdf:system-relative-pathname
    "dsmr-mcp" "templates/repl-driven-development.md"))
  "Template for the generated project's prompts/repl-driven-development.md (D-12).
A dsmr-discipline REPL-driven-development guide reframed for the scaffolded
project; {{name}} and {{spdx}} are substituted by plan-scaffold.  Distinct from
dsmr-mcp's own prompts/repl-driven-development.md seed (D-11), which is the
self-referential version.")

;;; ---------------------------------------------------------------------------
;;; .envrc template (direnv per-project config)
;;;
;;; Read at load time via read-envrc-template, which prefers the operator's
;;; site-wide template (~/.config/dsmr-mcp/envrc.template) over the repo
;;; default. Copied verbatim into the scaffolded project's .envrc — it uses
;;; shell ${VAR:-default} expansion, NOT {{key}} placeholders, so render2
;;; passes it through unchanged.
;;; ---------------------------------------------------------------------------

(defparameter *envrc-template*
  (read-envrc-template)
  "Template for the generated project's .envrc file (direnv per-project config).
Copied verbatim from the site-wide template or the repo default. Uses shell
${VAR:-default} syntax, NOT {{key}} placeholders.")

;;; ---------------------------------------------------------------------------
;;; LICENSE template (placeholder — full body injected from license-body-for-spdx)
;;; ---------------------------------------------------------------------------

(defparameter *license-template*
  "{{license-body}}"
  "Template for the generated project's LICENSE file.
The full text is injected from the license-body-for-spdx lookup table
keyed by the chosen SPDX identifier.")

;;; ---------------------------------------------------------------------------
;;; LICENSE body lookup table (9 bundled license texts, D-14)
;;; ---------------------------------------------------------------------------

(defparameter *license-bodies*
  `(("AGPL-3.0-or-later" .
     "                    GNU AFFERO GENERAL PUBLIC LICENSE
                       Version 3, 19 November 2007

 Copyright (C) {{year}} {{copyright}}

 This program is free software: you can redistribute it and/or modify
 it under the terms of the GNU Affero General Public License as published
 by the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU Affero General Public License for more details.

 You should have received a copy of the GNU Affero General Public License
 along with this program.  If not, see <https://www.gnu.org/licenses/>.

 Full text: https://www.gnu.org/licenses/agpl-3.0.html
")
    ("GPL-3.0-or-later" .
     "                    GNU GENERAL PUBLIC LICENSE
                       Version 3, 29 June 2007

 Copyright (C) {{year}} {{copyright}}

 This program is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with this program.  If not, see <https://www.gnu.org/licenses/>.

 Full text: https://www.gnu.org/licenses/gpl-3.0.html
")
    ("GPL-2.0-or-later" .
     "                    GNU GENERAL PUBLIC LICENSE
                       Version 2, June 1991

 Copyright (C) {{year}} {{copyright}}

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation; either version 2 of the License, or
 (at your option) any later version.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License along
 with this program; if not, see <https://www.gnu.org/licenses/>.

 Full text: https://www.gnu.org/licenses/old-licenses/gpl-2.0.html
")
    ("LGPL-3.0-or-later" .
     "                   GNU LESSER GENERAL PUBLIC LICENSE
                       Version 3, 29 June 2007

 Copyright (C) {{year}} {{copyright}}

 This program is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as
 published by the Free Software Foundation, either version 3 of the
 License, or (at your option) any later version.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU Lesser General Public License for more details.

 You should have received a copy of the GNU Lesser General Public License
 along with this program.  If not, see <https://www.gnu.org/licenses/>.

 Full text: https://www.gnu.org/licenses/lgpl-3.0.html
")
    ("LGPL-2.1-or-later" .
     "                  GNU LESSER GENERAL PUBLIC LICENSE
                       Version 2.1, February 1999

 Copyright (C) {{year}} {{copyright}}

 This library is free software; you can redistribute it and/or
 modify it under the terms of the GNU Lesser General Public
 License as published by the Free Software Foundation; either
 version 2.1 of the License, or (at your option) any later version.

 This library is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 Lesser General Public License for more details.

 You should have received a copy of the GNU Lesser General Public License
 along with this library; if not, see <https://www.gnu.org/licenses/>.

 Full text: https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html
")
    ("MIT" .
     "MIT License

Copyright (c) {{year}} {{copyright}}

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the \"Software\"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED \"AS IS\", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
")
    ("BSD-2-Clause" .
     "BSD 2-Clause License

Copyright (c) {{year}}, {{copyright}}
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice,
   this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS \"AS IS\"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
")
    ("BSD-3-Clause" .
     "BSD 3-Clause License

Copyright (c) {{year}}, {{copyright}}
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice,
   this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its contributors
   may be used to endorse or promote products derived from this software
   without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS \"AS IS\"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
")
    ("Apache-2.0" .
     "Apache License
Version 2.0, January 2004
http://www.apache.org/licenses/

Copyright (c) {{year}} {{copyright}}

Licensed under the Apache License, Version 2.0 (the \"License\");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an \"AS IS\" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
"))
  "Alist mapping SPDX identifier strings to full license body texts.
Values use {{copyright}} and {{year}} placeholders for substitution.")

(defun license-body-for-spdx (spdx-id)
  "Return the license body template string for SPDX-ID, or NIL if unknown.
The body text contains {{copyright}} and {{year}} placeholders that must
be resolved by render-template before writing to disk."
  (let ((entry (assoc spdx-id *license-bodies* :test #'string=)))
    (when entry
      (cdr entry))))
