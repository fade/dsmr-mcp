# Makefile — dsmr-mcp build targets

# Canonical SBCL. CI overrides this to the pinned upstream sbcl-bin (a fixed
# GENCGC build) for reproducibility; a core-image run may instead add
# `--core dsmr.core`.
SBCL ?= sbcl

# Isolate the fasl cache to a project-local dir so a test run never loads the
# shared ~/.cache/common-lisp fasls. Those may have been built under a different
# SBCL GC flavor (MARK-REGION vs GENCGC); loading them with a mismatched sbcl
# crashes with INVALID-FASL-FEATURES. Isolation turns that crash into a clean
# cache miss + recompile. Safe to override in the environment on a warm runner.
export XDG_CACHE_HOME ?= $(CURDIR)/.ci-cache

# Prebuilt core image (deps+system+test-deps via save-lisp-and-die). Override
# CORE to point `test-warm` at an alternate path; rebuild with `make core`
# whenever the dependencies, the SBCL build, or the project source change.
CORE ?= dsmr.core

# Prebuilt worker core image: only the hermetic worker system, its dependencies
# and Quicklisp. Hermetic workers boot from it instead of loading the system on
# every spawn. WORKER_CORE_IMAGE is the image `core-verify-worker` checks.
WORKER_CORE ?= dsmr.core.worker
WORKER_CORE_IMAGE ?= $(WORKER_CORE)

.PHONY: bridge bus-watch bus-host install-bus-watch install-bus-host install-host-unit check-host-unit test test-integration core core-verify core-worker core-verify-worker test-warm \
        install-skills check-skills install-agents check-agents install-harness check-harness install-sisters check-sisters \
        preflight check-preflight self-test-preflight install-hooks check-hooks test-hooks test-restart-session install-restart-session check-restart-session test-routing-probe

PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin
LIBDIR ?= $(PREFIX)/lib/dsmr-mcp

# Where this site's Lisp checkouts live, and therefore where a fleet's member
# repositories are resolved from. The environment wins so a clone elsewhere
# needs no edit here.
WORKSPACE ?= $(or $(LISP_WORKSPACE),$(HOME)/SourceCode/lisp)

# Where the harness skills are deployed for the agent that reads them. Claude is
# the first target and deliberately not the only one; a second agent gets its own
# directory rather than this one being generalized in place.
SKILLDIR ?= $(HOME)/.claude/skills

# Where harness artefacts that are not skills are deployed: the status line, and
# anything else the agent reads from its own configuration root rather than from
# a project. Same reasoning as SKILLDIR, one level up.
#
# These deploy GLOBALLY on purpose. An artefact that identifies a session, or
# that every session is expected to share, is wrong the moment it is scoped to
# one project: it cannot reach the others, and a fleet restart cannot widen it.
AGENTDIR ?= $(HOME)/.claude

# Where subagent definitions are deployed: the agents directory under the agent
# configuration root. Global for the same reason as AGENTDIR, since a plan in
# any project can be routed to one of these agents.
SUBAGENTDIR ?= $(AGENTDIR)/agents

# Where the host bus service's systemd user units are deployed. The user
# manager reads its own units from here, and the service is a per-user one: it
# serves the buses under this user's state directory, needs no root, and keeps
# running between logins when linger is enabled for the user.
UNITDIR ?= $(HOME)/.config/systemd/user

## bridge: build the standalone stdio<->TCP bridge binary.
##
##   Produces bin/dsmr-mcp-bridge via ASDF program-op (save-lisp-and-die).
##   The binary needs no SBCL or Python installation on the client machine.
##   Build artefact is .gitignored; rebuild with 'make bridge' after any
##   change to scripts/stdio-tcp-bridge.lisp.
bridge:
	@mkdir -p bin
	sbcl --noinform --disable-debugger \
	     --eval '(asdf:load-asd (truename "dsmr-mcp-bridge.asd"))' \
	     --eval '(asdf:make :dsmr-mcp-bridge)' \
	     --eval '(quit)'

## bus-watch: build the standalone coordination-bus wakeup watcher binary.
##
##   Produces bin/dsmr-bus-watch via ASDF program-op (save-lisp-and-die).
##   A sister repo arms it by bare command name; the machine needs no SBCL or
##   Python of its own. Build artefact is .gitignored; rebuild with
##   'make bus-watch' after any change to src/bus/watch.lisp.
##
##   Built with --no-userinit/--no-sysinit so the saved image carries ONLY the
##   WAL leaf + watcher (no Quicklisp/slynk) — the watcher's closure needs
##   nothing beyond CL, so both .asd files are registered explicitly.
bus-watch:
	@mkdir -p bin
	sbcl --noinform --no-sysinit --no-userinit --disable-debugger \
	     --eval '(require :asdf)' \
	     --eval '(asdf:load-asd (truename "dsmr-mcp.asd"))' \
	     --eval '(asdf:load-asd (truename "dsmr-bus-watch.asd"))' \
	     --eval '(asdf:make :dsmr-bus-watch)' \
	     --eval '(quit)'

## bus-host: build the host bus service binary.
##
##   Produces bin/dsmr-bus-host via ASDF program-op (save-lisp-and-die). One
##   process per host runs every bus broker and the watch for every agent
##   registered with it. While it runs it takes over from the broker elected by
##   whichever client came first and the detached watcher process per agent per
##   bus; those remain the fallback whenever the service is down. Build
##   artefact is .gitignored; rebuild with 'make bus-host' after any change
##   under src/bus/host/ or to the bus leaves it shares.
##
##   Unlike the watcher it runs brokers, so it needs the ZeroMQ binding and
##   log4cl: it is built with Quicklisp and the Lisp workspace visible (the
##   workspace carries the vetted pzmq fork), but still without the user's init
##   file, so nothing from a development session ends up in the saved image.
##
##   Before the image is saved, every system loaded in it except dsmr-bus-host
##   itself is registered as immutable, and so are two systems named
##   explicitly: dsmr-mcp, which the broker asks ASDF about when it records its
##   own version, and dsmr-bus-watch. The service's own system is left out
##   because ASDF builds nothing for an immutable system. Without that, the
##   saved image answers the broker by scanning the whole source registry,
##   which on a workspace this size kept the first broker from serving for
##   minutes. The old binary is removed first because ASDF sees no reason to
##   save the image again when only this recipe has changed.
bus-host:
	@mkdir -p bin
	@rm -f bin/dsmr-bus-host
	sbcl --noinform --no-sysinit --no-userinit --disable-debugger \
	     --eval '(require :asdf)' \
	     --eval '(let ((ql (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))) (when (probe-file ql) (load ql)))' \
	     --eval '(pushnew (uiop:ensure-directory-pathname "$(WORKSPACE)") asdf:*central-registry* :test (function equal))' \
	     --eval '(pushnew (uiop:ensure-directory-pathname "$(WORKSPACE)/pzmq") asdf:*central-registry* :test (function equal))' \
	     --eval '(asdf:load-asd (truename "dsmr-mcp.asd"))' \
	     --eval '(asdf:load-asd (truename "dsmr-bus-watch.asd"))' \
	     --eval '(asdf:load-asd (truename "dsmr-bus-host.asd"))' \
	     --eval '(asdf:load-system :dsmr-bus-host)' \
	     --eval '(map nil (function asdf:register-immutable-system) (remove "dsmr-bus-host" (list* "dsmr-mcp" "dsmr-bus-watch" (asdf:already-loaded-systems)) :test (function equal)))' \
	     --eval '(asdf:make :dsmr-bus-host)' \
	     --eval '(quit)'
	@test -x bin/dsmr-bus-host || { echo "bin/dsmr-bus-host was not written" >&2; exit 1; }

## install-bus-watch: publish the built watcher onto PATH.
##
##   Agents invoke 'dsmr-bus-watch' by name, so the copy under $(BINDIR) — not
##   bin/ — is the one every session actually runs. Skipping this step leaves
##   the operator docs describing flags the deployed binary rejects, and a
##   watcher that exits on them is deaf to the bus rather than noisy about it.
##   Install atomically: agents arm watchers continuously, and cp over a running
##   binary's inode can hand a session a half-written image.
install-bus-watch: bus-watch
	@mkdir -p "$(BINDIR)"
	@cp bin/dsmr-bus-watch "$(BINDIR)/.dsmr-bus-watch.tmp"
	@chmod 755 "$(BINDIR)/.dsmr-bus-watch.tmp"
	@mv -f "$(BINDIR)/.dsmr-bus-watch.tmp" "$(BINDIR)/dsmr-bus-watch"
	@echo "installed $(BINDIR)/dsmr-bus-watch"
	@echo "running watchers keep the previous image until each is re-armed"

## install-bus-host: publish the built host bus service binary onto PATH.
##
##   The service's unit runs the copy under $(BINDIR), so this is the step that
##   changes what the host runs. Installed atomically for the same reason as the
##   watcher. The running service keeps the image it started with until it is
##   restarted, and a restart is a deliberate act because every agent on the
##   host hears the bus through it.
install-bus-host: bus-host
	@mkdir -p "$(BINDIR)"
	@cp bin/dsmr-bus-host "$(BINDIR)/.dsmr-bus-host.tmp"
	@chmod 755 "$(BINDIR)/.dsmr-bus-host.tmp"
	@mv -f "$(BINDIR)/.dsmr-bus-host.tmp" "$(BINDIR)/dsmr-bus-host"
	@echo "installed $(BINDIR)/dsmr-bus-host"
	@echo "the running service keeps the previous image until 'systemctl --user restart dsmr-bus-host'"

## install-host-unit: deploy the host bus service's systemd user units.
##
##   Copies the service unit and its failure alarm unit into $(UNITDIR), reloads
##   the user manager and enables the service so it starts at the next login or
##   boot. It does not start it: starting the service moves every agent on the
##   host onto it, and that is a step to take on purpose.
##
##   A deployed unit that differs from this tree is refused, with the
##   difference, unless FORCE=1: a unit edited in place on a host is usually a
##   local fix, and this target would destroy it. Run check-host-unit first and
##   port the edit back here if it should be kept.
HOST_UNITS = dsmr-bus-host.service dsmr-bus-host-failed.service
install-host-unit:
	@set -e; \
	mkdir -p "$(UNITDIR)"; \
	for u in $(HOST_UNITS); do \
	  if [ -f "$(UNITDIR)/$$u" ] && ! cmp -s "scripts/units/$$u" "$(UNITDIR)/$$u" && [ "$(FORCE)" != 1 ]; then \
	    echo "REFUSED: $(UNITDIR)/$$u differs from scripts/units/$$u" >&2; \
	    diff -u "$(UNITDIR)/$$u" "scripts/units/$$u" | head -40 >&2; \
	    echo "port the deployed edit into this tree, or pass FORCE=1 to replace it" >&2; \
	    exit 1; \
	  fi; \
	done; \
	for u in $(HOST_UNITS); do \
	  cp "scripts/units/$$u" "$(UNITDIR)/.$$u.tmp"; \
	  chmod 644 "$(UNITDIR)/.$$u.tmp"; \
	  mv -f "$(UNITDIR)/.$$u.tmp" "$(UNITDIR)/$$u"; \
	  echo "installed $(UNITDIR)/$$u"; \
	done; \
	systemctl --user daemon-reload; \
	systemctl --user enable dsmr-bus-host.service; \
	echo "enabled, not started: 'systemctl --user start dsmr-bus-host' moves this host's agents onto it"

## check-host-unit: report whether the deployed units match this tree.
##
##   Never edits. Prints match, DIFFERS (with the difference) or NOT DEPLOYED for
##   each unit, then whether the user lingers (without it the service stops at
##   logout) and whether the service is enabled and running.
##
##   Each deployed unit is also put through systemd-analyze verify on its own,
##   and any line it prints fails the check. Its exit status cannot be used:
##   verify exits 0 after warning about a misspelled directive, which systemd
##   then ignores. The alarm unit is verified separately because verifying the
##   service does not notice that the unit its OnFailure= names is missing.
check-host-unit:
	@status=0; \
	for u in $(HOST_UNITS); do \
	  if [ ! -f "$(UNITDIR)/$$u" ]; then echo "NOT DEPLOYED: $(UNITDIR)/$$u"; continue; \
	  elif cmp -s "scripts/units/$$u" "$(UNITDIR)/$$u"; then echo "match: $(UNITDIR)/$$u"; \
	  else echo "DIFFERS: $(UNITDIR)/$$u"; diff -u "$(UNITDIR)/$$u" "scripts/units/$$u" | head -40; fi; \
	  out=$$(systemd-analyze --user verify "$(UNITDIR)/$$u" 2>&1); \
	  if [ -z "$$out" ]; then echo "verify clean: $$u"; \
	  else echo "VERIFY WARNS: $$u"; echo "$$out" | sed 's/^/  /'; status=1; fi; \
	done; \
	echo "linger: $$(loginctl show-user "$$(id -un)" -p Linger --value 2>/dev/null || echo unknown)"; \
	echo "enabled: $$(systemctl --user is-enabled dsmr-bus-host.service 2>/dev/null || true)"; \
	echo "active: $$(systemctl --user is-active dsmr-bus-host.service 2>/dev/null || true)"; \
	exit $$status

## preflight: check this host can run a fleet, establishing what is safe to.
##
##   Registers the MCP server if it is absent, consents to the named repos'
##   .envrc files, and verifies the prebuilt core actually boots here. Anything
##   needing root, and anything that takes minutes, is reported with a remedy
##   instead of being run: a check that rebuilt the core on every launch would
##   ship whatever branch happens to be checked out to the whole fleet.
##
##   `sisters.sh` runs this before it starts anything and refuses to launch on a
##   non-zero answer. Run it by hand to provision a new host, or to find out why
##   a launch was refused.
##
##   Name the repos to check with REPOS: make preflight REPOS="mallet boomer"
preflight:
	@./scripts/preflight.sh --fleet-dir "$(WORKSPACE)" \
	   $(foreach r,$(REPOS),--repo $(r))

## check-preflight: the same checks, changing nothing. Reports and exits.
check-preflight:
	@./scripts/preflight.sh --check-only --fleet-dir "$(WORKSPACE)" \
	   $(foreach r,$(REPOS),--repo $(r))

## self-test-preflight: prove every host check can report red.
##
##   A checker that cannot fail reports the same clean answer whether the host
##   is healthy or the check itself is broken. This plants each failing
##   condition and asserts the matching check notices it. It caught a real
##   defect on its first run, so it earns its place rather than decorating the
##   suite.
self-test-preflight:
	@./scripts/preflight.sh --self-test

## install-hooks: install this tree's git hooks into a repository.
##
##   Defaults to this repository; pass REPO=<path> to install elsewhere.
##
##   The hooks used to exist ONLY as copies under .git/hooks in fifteen
##   repositories, tracked by nothing and installed by nothing. They gate every
##   commit in both fleets, so an edit to one copy was invisible everywhere else
##   and there was no origin to diff against. pre-commit had already drifted into
##   three variants before anyone looked.
##
##   HOOKS names which files to install; it defaults to all of them. Pass the
##   three shared ones when installing into a repository that is not mine:
##   pre-commit legitimately varies per project (not everything runs a Lisp
##   linter), and replacing a deliberate local variant is not the same act as
##   delivering a shared fix.
##
##   Install atomically: a half-written hook makes a repository uncommittable.
HOOKS ?= dsmr-workproduct-lint.sh dsmr-shell-lint.sh commit-msg pre-commit
install-hooks:
	@set -e; \
	target="$(if $(REPO),$(REPO),$(CURDIR))"; \
	dest="$$target/.git/hooks"; \
	test -d "$$dest" || { echo "not a git repository: $$target" >&2; exit 1; }; \
	for f in $(HOOKS); do \
	  cp "scripts/githooks/$$f" "$$dest/.$$f.tmp"; \
	  chmod 755 "$$dest/.$$f.tmp"; \
	  mv -f "$$dest/.$$f.tmp" "$$dest/$$f"; \
	done; \
	echo "installed hooks into $$dest"

## test-hooks: drive real commits through the hooks in a scratch repository.
##
##   Each blocking rule has a commit it must refuse and one it must accept, so a
##   lint that refuses everything fails, as does one that refuses nothing.
test-hooks:
	@bash tests/githooks/workproduct-style-test.sh

## test-restart-session: drive the in-place session restart against a stub kitten.
##
##   No kitty is involved. Each refusal has a case that would fail if the
##   refusal were removed, and a positive control that proves the same fixture
##   restarts when nothing is wrong.
test-restart-session:
	@bash tests/scripts/restart-session-in-place-test.sh

## test-routing-probe: check the routing probe readers against recorded sessions.
##
##   Needs ROUTING_PROBE_RECORDED, the directory holding the recorded sessions
##   (without it the target stops with a usage line). Runs no live session and
##   never reads the live bus. Every planted mismatch is an edit of the recording
##   and must make `routing-probe.sh check` exit 1 (a cap case, exit 3).
test-routing-probe:
	@bash tests/scripts/routing-probe-test.sh

## check-hooks: report where a deployed hook differs from this tree.
##
##   Never edits. Checks the SHARED files across every repository in the
##   workspace that carries them, because those are meant to be identical
##   everywhere and a difference is drift. pre-commit is checked for this
##   repository only: it legitimately varies, since not every project runs a
##   Lisp linter.
check-hooks:
	@status=0; \
	for f in dsmr-workproduct-lint.sh dsmr-shell-lint.sh commit-msg; do \
	  for d in $(WORKSPACE)/*/.git/hooks $(WORKSPACE)/*/*/.git/hooks; do \
	    test -f "$$d/$$f" || continue; \
	    repo=$$(cd "$$d/../.." && basename "$$PWD"); \
	    if ! cmp -s "scripts/githooks/$$f" "$$d/$$f"; then \
	      echo "  DIFFERS  $$repo  $$f"; status=1; \
	    fi; \
	  done; \
	done; \
	if cmp -s scripts/githooks/pre-commit .git/hooks/pre-commit; then :; \
	else echo "  DIFFERS  dsmr-mcp  pre-commit"; status=1; fi; \
	if [ $$status = 0 ]; then echo "hooks in sync across the workspace"; \
	else echo "run 'make install-hooks REPO=<path>' to deploy this tree, or port the other way first"; fi; \
	exit $$status

## install-sisters: publish the fleet bring-up wrapper onto PATH.
##
##   The operator starts a fleet by name from his own shell, so the copy under
##   $(BINDIR) is the one that actually runs; this tree is where it is
##   maintained. Keeping it here rather than loose in $$HOME means a fleet's
##   invocation is reviewed and versioned like anything else, and a wrong
##   --extra is caught in a diff instead of by a sister's silence.
##   Install atomically for the same reason as the watcher: a half-written
##   wrapper brings up a partial fleet that looks like a whole one.
install-sisters:
	@mkdir -p "$(BINDIR)"
	@cp scripts/sisters.sh "$(BINDIR)/.sisters.sh.tmp"
	@chmod 755 "$(BINDIR)/.sisters.sh.tmp"
	@mv -f "$(BINDIR)/.sisters.sh.tmp" "$(BINDIR)/sisters.sh"
	@echo "installed $(BINDIR)/sisters.sh"
	@command -v sisters.sh >/dev/null 2>&1 \
	  || echo "NOTE: $(BINDIR) is not on this shell's PATH, so 'sisters.sh' will not resolve by name"

## check-sisters: report whether the deployed wrapper matches this tree.
##
##   Never edits. The deployed copy is what a bring-up runs, so a tree edited
##   without a deploy is a fix nobody is getting; a deployed copy edited in
##   place is a fix this tree will overwrite.
check-sisters:
	@if [ ! -f "$(BINDIR)/sisters.sh" ]; then echo "NOT DEPLOYED: $(BINDIR)/sisters.sh"; \
	elif cmp -s scripts/sisters.sh "$(BINDIR)/sisters.sh"; then echo "match: $(BINDIR)/sisters.sh"; \
	else echo "DIFFERS: $(BINDIR)/sisters.sh"; diff -u "$(BINDIR)/sisters.sh" scripts/sisters.sh | head -40; \
	     echo "run 'make install-sisters' to deploy this tree, or port the other way first"; fi

## install-restart-session: publish the in-place session restart onto PATH.
##
##   The script finds its socket library beside itself in a checkout and under
##   ../lib/dsmr-mcp once installed, so both files are deployed together, the
##   library first. That lookup assumes BINDIR is $$(PREFIX)/bin.
##   Install atomically: a half-written script is run by a leader that is
##   about to type into live sessions.
install-restart-session:
	@set -e; \
	mkdir -p "$(BINDIR)" "$(LIBDIR)"; \
	cp scripts/kitty-sockets.sh "$(LIBDIR)/.kitty-sockets.sh.tmp"; \
	chmod 644 "$(LIBDIR)/.kitty-sockets.sh.tmp"; \
	mv -f "$(LIBDIR)/.kitty-sockets.sh.tmp" "$(LIBDIR)/kitty-sockets.sh"; \
	echo "installed $(LIBDIR)/kitty-sockets.sh"; \
	cp scripts/restart-session-in-place.sh "$(BINDIR)/.restart-session-in-place.sh.tmp"; \
	chmod 755 "$(BINDIR)/.restart-session-in-place.sh.tmp"; \
	mv -f "$(BINDIR)/.restart-session-in-place.sh.tmp" "$(BINDIR)/restart-session-in-place.sh"; \
	echo "installed $(BINDIR)/restart-session-in-place.sh"; \
	command -v restart-session-in-place.sh >/dev/null 2>&1 \
	  || echo "NOTE: $(BINDIR) is not on this shell's PATH, so 'restart-session-in-place.sh' will not resolve by name"

## check-restart-session: report whether the deployed restart script and its library match this tree.
##
##   Never edits. The deployed copies are what a leader runs, so a tree edited
##   without a deploy is a fix nobody is getting.
check-restart-session:
	@for pair in "scripts/restart-session-in-place.sh:$(BINDIR)/restart-session-in-place.sh" \
	             "scripts/kitty-sockets.sh:$(LIBDIR)/kitty-sockets.sh"; do \
	  src=$${pair%%:*}; dst=$${pair#*:}; \
	  if [ ! -f "$$dst" ]; then echo "NOT DEPLOYED: $$dst"; \
	  elif cmp -s "$$src" "$$dst"; then echo "match: $$dst"; \
	  else echo "DIFFERS: $$dst"; diff -u "$$dst" "$$src" | head -40; \
	       echo "run 'make install-restart-session' to deploy this tree, or port the other way first"; fi; \
	done

## check-skills: report where the deployed skills differ from this tree.
##
##   A skill is a directory, so only files inside one are deployable; anything
##   at the top of skills/ is documentation about the collection and stays here.
##
##   A skill tracked here but never deployed is worse than one that was never
##   tracked: it reads as version-controlled while the thing an agent actually
##   loads is something else. That is how the scaffold-project copy rotted 19
##   lines behind without anyone noticing. This reports drift in both directions
##   and never edits, so it is safe to run against a live fleet.
check-skills:
	@status=0; \
	for f in $$(cd skills && find . -mindepth 2 -type f ! -path '*__pycache__*' | sed 's|^\./||'); do \
	  if [ ! -f "$(SKILLDIR)/$$f" ]; then \
	    echo "  NOT DEPLOYED  $$f"; status=1; \
	  elif ! cmp -s "skills/$$f" "$(SKILLDIR)/$$f"; then \
	    echo "  DIFFERS       $$f"; status=1; \
	  fi; \
	done; \
	for f in $$(cd "$(SKILLDIR)" 2>/dev/null && find . -type f ! -path '*__pycache__*' | sed 's|^\./||'); do \
	  case "$$f" in gsd-*|*/gsd-*) continue;; esac; \
	  if [ -d "skills/$$(dirname $$f)" ] && [ ! -f "skills/$$f" ]; then \
	    echo "  DEPLOYED ONLY $$f"; status=1; \
	  fi; \
	done; \
	if [ $$status -eq 0 ]; then echo "skills in sync with $(SKILLDIR)"; \
	else echo "run 'make install-skills' to deploy this tree, or port the other way first"; fi; \
	exit $$status

## install-skills: deploy this tree's harness skills to the agent that reads them.
##
##   ⛔ The migration direction is global -> repo. If a deployed skill has been
##   edited in place, that edit is the newer one and this target would destroy
##   it. Run check-skills first and port the other way before deploying.
##   Deployment is per-file so an agent's unrelated skills are left alone.
install-skills:
	@for f in $$(cd skills && find . -mindepth 2 -type f ! -path '*__pycache__*' | sed 's|^\./||'); do \
	  mkdir -p "$(SKILLDIR)/$$(dirname $$f)"; \
	  cp -p "skills/$$f" "$(SKILLDIR)/$$f"; \
	  echo "  deployed $$f"; \
	done
	@echo "installed into $(SKILLDIR)"

## check-agents: report where the deployed agent definitions differ from this tree.
##
##   An agents directory is flat, so README.md at the top of agents/ is
##   documentation and is never deployed: in the deployed directory it would be
##   read as an agent. Only agents tracked here are inspected. The gsd-* roster
##   and lisp-developer are deployed by other means and are never reported.
##
##   Reports drift in both directions: a tracked agent missing or different in
##   the deployed directory, and a deployed backup sibling of a tracked agent
##   (<name>.md.<suffix>) that this tree does not carry. Never edits, so it is
##   safe to run against a live fleet.
check-agents:
	@status=0; \
	for f in $$(cd agents && find . -maxdepth 1 -type f -name '*.md' ! -name README.md | sed 's|^\./||'); do \
	  if [ ! -f "$(SUBAGENTDIR)/$$f" ]; then \
	    echo "  NOT DEPLOYED  $$f"; status=1; \
	  elif ! cmp -s "agents/$$f" "$(SUBAGENTDIR)/$$f"; then \
	    echo "  DIFFERS       $$f"; status=1; \
	  fi; \
	  for b in "$(SUBAGENTDIR)/$$f".*; do \
	    [ -e "$$b" ] || continue; \
	    echo "  DEPLOYED ONLY $$(basename "$$b")"; status=1; \
	  done; \
	done; \
	if [ $$status -eq 0 ]; then echo "agents in sync with $(SUBAGENTDIR)"; \
	else echo "run 'make install-agents' to deploy this tree, or port the other way first"; fi; \
	exit $$status

## install-agents: deploy this tree's agent definitions to the agent that reads them.
##
##   ⛔ The migration direction is deployed -> repo. If a deployed definition
##   has been edited in place, that edit is the newer one and this target would
##   destroy it. Run check-agents first and port the other way before deploying.
##   Deployment is per-file over the agents tracked here, so the gsd-* roster
##   and lisp-developer are left alone.
install-agents:
	@for f in $$(cd agents && find . -maxdepth 1 -type f -name '*.md' ! -name README.md | sed 's|^\./||'); do \
	  mkdir -p "$(SUBAGENTDIR)"; \
	  cp -p "agents/$$f" "$(SUBAGENTDIR)/$$f"; \
	  echo "  deployed $$f"; \
	done
	@echo "installed into $(SUBAGENTDIR)"

## check-harness: report drift between harness/ and the deployed agent root.
##
##   Same contract as check-skills, and the same hazard: a live correction is
##   usually made to the DEPLOYED copy, so the tracked tree is the stale one
##   more often than not. Always run this before install-harness, and when it
##   reports DIFFERS, look before deciding which way to copy.
check-harness:
	@status=0; \
	for f in $$(cd harness && find . -type f | sed 's|^\./||'); do \
	  if [ ! -f "$(AGENTDIR)/$$f" ]; then \
	    echo "  NOT DEPLOYED  $$f"; status=1; \
	  elif ! cmp -s "harness/$$f" "$(AGENTDIR)/$$f"; then \
	    echo "  DIFFERS       $$f"; status=1; \
	  fi; \
	done; \
	if [ $$status -eq 0 ]; then echo "harness in sync with $(AGENTDIR)"; \
	else echo "run 'make install-harness' to deploy this tree, or port the other way first"; fi; \
	exit $$status

## install-harness: deploy harness/ into the agent configuration root.
##
##   Reaches every session on the host, not just this project's. The status
##   line lands immediately for sessions started afterwards; a running session
##   keeps the one it started with.
install-harness:
	@for f in $$(cd harness && find . -type f | sed 's|^\./||'); do \
	  mkdir -p "$(AGENTDIR)/$$(dirname $$f)"; \
	  cp -p "harness/$$f" "$(AGENTDIR)/$$f"; \
	  chmod +x "$(AGENTDIR)/$$f"; \
	  echo "  deployed $$f"; \
	done
	@echo "installed into $(AGENTDIR)"

## TEST_STATE_HOME: the shell prefix that gives a test run its own state.
##
##   I run the unit and integration suites under a fresh XDG_STATE_HOME made with mktemp and
##   removed when the recipe ends, however it ends. The suites start a session
##   pool, and a pool sweeps state and publishes its worker records under
##   $XDG_STATE_HOME/dsmr-mcp/host/, which is exactly where a running host
##   service looks for workers to stop or hibernate. A test run must never be
##   something the live service acts on. XDG_CACHE_HOME is left alone, so the
##   fasl cache stays shared between runs.
TEST_STATE_HOME = state=$$(mktemp -d /tmp/dsmr-test-state.XXXXXX) || exit 1; \
	trap 'rm -rf "$$state"' EXIT; trap 'exit 130' HUP INT TERM; \
	XDG_STATE_HOME=$$state; export XDG_STATE_HOME;

## test: fast in-process unit suite (the push hot-path).
##
##   Runs the dsmr-mcp/tests umbrella — true in-process units, no child SBCLs.
##   ASDF must locate the checkout + deps via CL_SOURCE_REGISTRY: local dev
##   resolves them through $LISP_WORKSPACE (and ~/.sbclrc / Quicklisp); CI sets
##   CL_SOURCE_REGISTRY to the checkout or lets Qlot/Quicklisp resolve. The
##   test-system call is wrapped so a failing leaf exits non-zero promptly: the
##   suite loads slynk (a test dependency) which installs a debugger hook, and
##   without the wrapper an unhandled :perform error is caught by that hook and
##   the process hangs waiting for a debugger connection instead of failing.
##
##   Each run gets a fresh state home of its own (TEST_STATE_HOME below).
test:
	$(TEST_STATE_HOME) $(SBCL) --noinform --disable-debugger --non-interactive \
	     --eval '(require :asdf)' \
	     --eval '(asdf:load-system "dsmr-mcp/tests")' \
	     --eval '(handler-case (asdf:test-system "dsmr-mcp/tests") (serious-condition (c) (uiop:die 1 "test failure: ~A" c)))'

## test-integration: slow cross-process suite (gated, off the push hot-path).
##
##   Runs dsmr-mcp/tests/integration — each leaf spawns a real child SBCL and
##   skips cleanly when none can be spawned. Same CL_SOURCE_REGISTRY,
##   fail-fast contract and private state home as `test`, because several
##   leaves start a pool too. Run on a schedule / label, not every push.
test-integration:
	$(TEST_STATE_HOME) $(SBCL) --noinform --disable-debugger --non-interactive \
	     --eval '(require :asdf)' \
	     --eval '(asdf:load-system "dsmr-mcp/tests/integration")' \
	     --eval '(handler-case (asdf:test-system "dsmr-mcp/tests/integration") (serious-condition (c) (uiop:die 1 "test failure: ~A" c)))'

## core: build the prebuilt deps+system+test-deps core image ($(CORE)).
##
##   Runs scripts/build-core.lisp (save-lisp-and-die) to amortize the Quicklisp
##   load and the system+test compile. The core is GC-safe (SBCL refuses a
##   cross-build --core) and large — it is .gitignored, never committed.
##   Rebuild after any dependency, SBCL-build, or project-source change.
##
##   Builds to a temporary path and renames into place, because a running server
##   has the core file mmap'd: writing the new image over it would fault every
##   live server. The rename swaps in a new inode and leaves running processes
##   holding the old one until they exit. The previous image is kept as
##   $(CORE).prev, both as a rollback and so core size and dependency drift can
##   be diffed across builds.
##
##   Every step that can fail happens while the working core is still installed,
##   so a build that produces a truncated or partially-loaded image is rejected
##   rather than installed. File size alone cannot establish that, and it was
##   all the previous check rested on.
##
##   $(CORE).prev is a hard link to the outgoing image rather than a rename of
##   it, so $(CORE) names a valid image at every instant: the final rename
##   replaces one complete file with another and there is no window where the
##   path is missing. Rollback is `mv $(CORE).prev $(CORE)`.
##
##   Once $(CORE) is installed it builds the worker core too (core-worker), so a
##   worker core that fails to build or verify does so after $(CORE) is already
##   in place and cannot touch it.
core:
	@rm -f "$(CORE).tmp" "$(CORE).tmp.manifest"
	DSMR_CORE_OUTPUT=$(CORE).tmp $(SBCL) --noinform --disable-debugger \
	     --load scripts/build-core.lisp
	@test -s "$(CORE).tmp" || { echo "core build produced no image; $(CORE) left untouched" >&2; exit 1; }
	@test -s "$(CORE).tmp.manifest" || { echo "core build produced no manifest; $(CORE) left untouched" >&2; exit 1; }
	@$(MAKE) --no-print-directory core-verify CORE_IMAGE="$(CORE).tmp"
	@rm -f "$(CORE).prev" "$(CORE).manifest.prev"
	@if [ -e "$(CORE)" ]; then ln "$(CORE)" "$(CORE).prev" 2>/dev/null || cp -p "$(CORE)" "$(CORE).prev"; fi
	@if [ -e "$(CORE).manifest" ]; then ln "$(CORE).manifest" "$(CORE).manifest.prev" 2>/dev/null || cp -p "$(CORE).manifest" "$(CORE).manifest.prev"; fi
	@mv -f "$(CORE).tmp" "$(CORE)"
	@mv -f "$(CORE).tmp.manifest" "$(CORE).manifest"
	@echo "installed $(CORE) (previous image kept as $(CORE).prev)"
	@echo "running servers keep the previous core until each restarts"
	@$(MAKE) --no-print-directory core-worker

## core-verify: boot a core image and assert it is a complete, working build.
##
##   Run by `make core` against the staged image before it is installed, so the
##   build refuses to replace a working core with a broken one. Also useful on
##   its own to check the installed image (`make core-verify`) or any other
##   (`make core-verify CORE_IMAGE=some.core`) without rebuilding anything.
##
##   Two kinds of broken image fail here by two different routes, and only one
##   of them reaches the script. An image damaged badly enough not to boot kills
##   SBCL as it maps the file, so the check that rejects it is the exit status,
##   not anything scripts/verify-core.lisp does. An image that boots but loaded
##   only part of the system is the case the script itself catches.
##
##   A truncated image therefore reports "Bus error" here, which is alarming to
##   read in a build log given that faulting live servers is the thing this
##   whole arrangement exists to prevent. It is the opposite: the fault is this
##   throwaway check process touching a bad file it never installed, and the
##   servers still hold the working image.
CORE_IMAGE ?= $(CORE)
core-verify:
	@test -s "$(CORE_IMAGE)" || { echo "no core image at $(CORE_IMAGE)" >&2; exit 1; }
	@$(SBCL) --core "$(CORE_IMAGE)" --noinform --disable-debugger --non-interactive \
	     --load scripts/verify-core.lisp

## core-worker: build the hermetic worker core image ($(WORKER_CORE)).
##
##   A hermetic worker booted from this image reaches its handshake in well
##   under a second instead of loading the worker system from source on every
##   spawn, and every worker on the host shares the image's pages. That spawn
##   cost was the only reason to keep a warm standby worker around.
##
##   The image holds the worker system, its dependencies and Quicklisp, and no
##   test systems: a worker image that carried them would carry them into every
##   image a worker saves. It is built with --no-userinit so nothing from a
##   personal init file is frozen into it, and core-verify-worker refuses an
##   image that holds a setting taken from the build host's environment.
##
##   Same staged, verified, atomic install as `core`: build to .tmp, boot the
##   staged image and check it from the inside, keep the outgoing image as
##   .prev by hard link, then rename into place. A failed build or a rejected
##   image leaves the installed worker core untouched. `make core` runs this
##   after it has installed $(CORE); run on its own, this target never touches
##   $(CORE).
core-worker:
	@rm -f "$(WORKER_CORE).tmp" "$(WORKER_CORE).tmp.manifest"
	DSMR_CORE_KIND=worker DSMR_CORE_OUTPUT=$(WORKER_CORE).tmp $(SBCL) --noinform --disable-debugger \
	     --no-userinit --non-interactive --load scripts/build-core.lisp
	@test -s "$(WORKER_CORE).tmp" || { echo "worker core build produced no image; $(WORKER_CORE) left untouched" >&2; exit 1; }
	@test -s "$(WORKER_CORE).tmp.manifest" || { echo "worker core build produced no manifest; $(WORKER_CORE) left untouched" >&2; exit 1; }
	@$(MAKE) --no-print-directory core-verify-worker WORKER_CORE_IMAGE="$(WORKER_CORE).tmp"
	@rm -f "$(WORKER_CORE).prev" "$(WORKER_CORE).manifest.prev"
	@if [ -e "$(WORKER_CORE)" ]; then ln "$(WORKER_CORE)" "$(WORKER_CORE).prev" 2>/dev/null || cp -p "$(WORKER_CORE)" "$(WORKER_CORE).prev"; fi
	@if [ -e "$(WORKER_CORE).manifest" ]; then ln "$(WORKER_CORE).manifest" "$(WORKER_CORE).manifest.prev" 2>/dev/null || cp -p "$(WORKER_CORE).manifest" "$(WORKER_CORE).manifest.prev"; fi
	@mv -f "$(WORKER_CORE).tmp" "$(WORKER_CORE)"
	@mv -f "$(WORKER_CORE).tmp.manifest" "$(WORKER_CORE).manifest"
	@echo "installed $(WORKER_CORE) (previous image kept as $(WORKER_CORE).prev)"

## core-verify-worker: boot a worker core image and assert it is fit for workers.
##
##   Run by `make core-worker` against the staged image before it is installed.
##   Checks from inside the image that the worker entry point is there, that no
##   test system and no environment-derived setting is, and that Quicklisp can
##   still find a system. Useful on its own against the installed image or any
##   other (`make core-verify-worker WORKER_CORE_IMAGE=some.core`).
core-verify-worker:
	@test -s "$(WORKER_CORE_IMAGE)" || { echo "no worker core image at $(WORKER_CORE_IMAGE)" >&2; exit 1; }
	@$(SBCL) --core "$(WORKER_CORE_IMAGE)" --noinform --disable-debugger --non-interactive \
	     --no-userinit --load scripts/verify-core-worker.lisp

## test-warm: run the fast suite against the prebuilt core ($(CORE)).
##
##   Skips the Quicklisp load and the recompile entirely — the core already
##   holds dsmr-mcp + the test leaves — so only the assertions run. Build the
##   core first with `make core`. `make test` remains the no-core load path and
##   works whether or not a core is present. Like `test`, each run gets a fresh
##   state home of its own (TEST_STATE_HOME).
test-warm:
	$(TEST_STATE_HOME) $(SBCL) --core $(CORE) --noinform --disable-debugger --non-interactive \
	     --eval '(handler-case (asdf:test-system "dsmr-mcp/tests") (serious-condition (c) (uiop:die 1 "test failure: ~A" c)))'
