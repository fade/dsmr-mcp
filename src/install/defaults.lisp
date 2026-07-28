;;;; src/install/defaults.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Install-time site-wide `.envrc` defaults. Renders a personalized copy of
;;;; the canonical `.envrc` template — the same verbatim-copy shell form, with
;;;; the operator's own Slynk host/port, LISP_WORKSPACE, mode, and related
;;;; projects substituted into the `${VAR:-DEFAULT}` defaults — and writes it to
;;;; the XDG site-wide path (~/.config/dsmr-mcp/envrc.template). Once written,
;;;; envrc-template-path (src/envrc-template.lisp) prefers it, so every project
;;;; the operator scaffolds or brings up inherits these defaults.
;;;;
;;;; render-site-defaults-template is a pure transform (no IO);
;;;; write-site-defaults-template is the atomic IO; collect-site-defaults is the
;;;; interactive prompt; install-envrc-defaults is the gated installer entry
;;;; that turns into a no-op under --print, --no-envrc-defaults, or a
;;;; non-interactive stdin.

(defpackage #:dsmr-mcp/src/install/defaults
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/envrc-template
                #:read-envrc-template
                #:site-defaults-template-path)
  (:import-from #:dsmr-mcp/src/fs
                #:write-file-string-atomically)
  (:import-from #:dsmr-mcp/src/log
                #:log-event)
  (:export #:render-site-defaults-template
           #:collect-site-defaults
           #:write-site-defaults-template
           #:install-envrc-defaults))

(in-package #:dsmr-mcp/src/install/defaults)

;;; Shipped defaults ---------------------------------------------------------
;;; These mirror the values in templates/dsmr-mcp.envrc.template. Keeping them
;;; here (rather than parsing the shipped file) makes render a pure transform
;;; that produces a complete, self-consistent template from a plist.

(defparameter +default-slynk-host+ "127.0.0.1")
(defparameter +default-slynk-port+ "4005")
(defparameter +default-lisp-workspace+ "$HOME/SourceCode/lisp/")
(defparameter +default-dsmr-mode+ "auto")

(defun %as-string (value default)
  "Return VALUE rendered as a string, or DEFAULT when VALUE is nil.
Integers (e.g. a Slynk port) are accepted and printed without decoration."
  (cond ((null value) default)
        ((stringp value) value)
        (t (princ-to-string value))))

;;; Pure render --------------------------------------------------------------

(defun render-site-defaults-template
    (&key slynk-host slynk-port lisp-workspace dsmr-mode related-projects)
  "Return a complete `.envrc`-format string in verbatim-copy form, with the
supplied values substituted into the `${VAR:-DEFAULT}` defaults. PURE — no IO.

Shape matches the shipped templates/dsmr-mcp.envrc.template: same exports, same
comments, same `direnv allow` instruction. That is no longer a claim kept by
convention: a parity test asserts this function's output with the shipped
defaults is byte-equal to that file, so the two cannot drift apart unnoticed.
A nil argument keeps the shipped default (127.0.0.1 / 4005 /
$HOME/SourceCode/lisp/ / auto). RELATED-PROJECTS,
when supplied as a non-empty string, becomes an active export; otherwise the
example line stays commented out. The output never contains a `{{` substring —
it is shell syntax, not a render-template target."
  (let ((host  (%as-string slynk-host    +default-slynk-host+))
        (port  (%as-string slynk-port     +default-slynk-port+))
        (ws    (%as-string lisp-workspace +default-lisp-workspace+))
        (mode  (%as-string dsmr-mode      +default-dsmr-mode+))
        (related (and (stringp related-projects)
                      (plusp (length related-projects))
                      related-projects)))
    (format nil
            "# .envrc — dsmr-mcp per-project configuration (direnv). Run `direnv allow` to activate.~@
             # These DSMR_* vars are inherited by the dsmr-mcp MCP server when you launch your~@
             # agent (e.g. `claude`) from this directory — so the server drives THIS project's~@
             # image without hardcoding anything in your global ~~/.claude.json.~2%~
             export LISP_WORKSPACE=\"${LISP_WORKSPACE:-~A}\"~2%~
             # This project's Slynk listener. scripts/dev-boot.sh reads the same two vars,~@
             # so dev-boot and dsmr-mcp stay in sync (single source of truth).~@
             export SLYNK_HOST=\"${SLYNK_HOST:-~A}\"~@
             export SLYNK_PORT=\"${SLYNK_PORT:-~A}\"~2%~
             # auto = attach to the image above if reachable, else a private hermetic worker.~@
             export DSMR_MODE=~A~@
             export DSMR_SLYNK_ATTACH=\"${SLYNK_HOST}:${SLYNK_PORT}\"~@
             export DSMR_LOG_LEVEL=info~2%~
             # This project's stable bus identity. The dsmr-mcp coordination bus uses it so~@
             # this project's main agent resumes its durable message cursor across restarts~@
             # instead of getting a fresh ephemeral id every launch. Defaults to the project~@
             # directory name; override by exporting DSMR_BUS_AGENT before direnv loads.~@
             export DSMR_BUS_AGENT=\"${DSMR_BUS_AGENT:-$(basename \"$PWD\")}\"~2%~
             # The fleet this project's agent belongs to. An empty value means the shared~@
             # host-wide bus, so a repository that gains this line has not moved anywhere:~@
             # distributing the stanza across every repository puts nobody on somebody~@
             # else's bus. Set it to the fleet tag the leader named to put this project's~@
             # agent on that fleet's private bus, or override by exporting~@
             # DSMR_BUS_SELECTOR before direnv loads. The MCP session and any watcher armed~@
             # from this directory read the same variable, so one value here keeps both on~@
             # one bus rather than letting them drift apart while both report success.~@
             export DSMR_BUS_SELECTOR=\"${DSMR_BUS_SELECTOR:-}\"~2%~
             # Sibling projects this one may re-root into (filesystem sandbox whitelist):~@
             ~:[# export DSMR_RELATED_PROJECTS=\"$HOME/SourceCode/lisp/cl-mcp:$HOME/SourceCode/lisp/eve-quant\"~;export DSMR_RELATED_PROJECTS=\"~:*~A\"~]~%"
            ws host port mode related)))

;;; Interactive collect ------------------------------------------------------

(defun %prompt (label default)
  "Prompt for LABEL on *standard-output*, showing DEFAULT in brackets, and read
one line from *standard-input*. An empty line (or EOF) keeps DEFAULT."
  (format *standard-output* "  ~A [~A]: " label default)
  (finish-output *standard-output*)
  (let ((line (read-line *standard-input* nil nil)))
    (if (and line (plusp (length (string-trim '(#\Space #\Tab #\Return) line))))
        (string-trim '(#\Space #\Tab #\Return) line)
        default)))

(defun collect-site-defaults (&key (interactive t))
  "Collect site-wide `.envrc` defaults from the operator and return them as a
plist of (:slynk-host :slynk-port :lisp-workspace :dsmr-mode :related-projects).

When INTERACTIVE is nil, return nil immediately — no prompt, no read. Otherwise
prompt for each value on *standard-output*, reading from *standard-input*; an
empty line keeps the shipped default and EOF is treated as the default. (The
interactive branch is exercised manually; tests drive :interactive nil.)"
  (when interactive
    (format *standard-output*
            "~&dsmr-mcp site-wide .envrc defaults — press Enter to accept each default.~%")
    (let ((host (%prompt "Slynk host"      +default-slynk-host+))
          (port (%prompt "Slynk port"      +default-slynk-port+))
          (ws   (%prompt "LISP_WORKSPACE"  +default-lisp-workspace+))
          (mode (%prompt "DSMR_MODE"       +default-dsmr-mode+))
          (related (%prompt "Related projects (colon-separated, blank for none)" "")))
      (list :slynk-host host
            :slynk-port port
            :lisp-workspace ws
            :dsmr-mode mode
            :related-projects related))))

;;; Atomic write -------------------------------------------------------------

(defun write-site-defaults-template (defaults)
  "Render DEFAULTS (a plist as returned by collect-site-defaults, or nil for the
shipped defaults) and write the result atomically to site-defaults-template-path
(~/.config/dsmr-mcp/envrc.template), creating the parent directory. Return the
written pathname."
  (let ((content (apply #'render-site-defaults-template defaults))
        (path (site-defaults-template-path)))
    (write-file-string-atomically path content)
    (log-event :info "install.envrc-defaults.write"
               "path" (namestring path))
    path))

;;; Gated installer entry ----------------------------------------------------

(defun install-envrc-defaults (&key (mode :interactive))
  "Installer entry for the site-wide-defaults step.

MODE selects behavior:
  :skip         no-op; return nil. (Wired to the --no-envrc-defaults flag.)
  :interactive  when stdin is interactive, collect defaults and write the
                site-wide template, returning the written pathname; when stdin
                is NOT interactive (piped / CI), return nil without prompting so
                an automated install never blocks on a read.

Returns the written pathname on a successful write, nil otherwise."
  (ecase mode
    (:skip nil)
    (:interactive
     (if (interactive-stream-p *standard-input*)
         (write-site-defaults-template (collect-site-defaults :interactive t))
         nil))))
