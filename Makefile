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

.PHONY: bridge bus-watch install-bus-watch test test-integration core core-verify test-warm \
        install-skills check-skills install-harness check-harness install-sisters check-sisters \
        preflight check-preflight self-test-preflight install-hooks check-hooks

PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin

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
##   two shared ones when installing into a repository that is not mine:
##   pre-commit legitimately varies per project (not everything runs a Lisp
##   linter), and replacing a deliberate local variant is not the same act as
##   delivering a shared fix.
##
##   Install atomically: a half-written hook makes a repository uncommittable.
HOOKS ?= dsmr-workproduct-lint.sh commit-msg pre-commit
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

## check-hooks: report where a deployed hook differs from this tree.
##
##   Never edits. Checks the SHARED files across every repository in the
##   workspace that carries them, because those are meant to be identical
##   everywhere and a difference is drift. pre-commit is checked for this
##   repository only: it legitimately varies, since not every project runs a
##   Lisp linter.
check-hooks:
	@status=0; \
	for f in dsmr-workproduct-lint.sh commit-msg; do \
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
test:
	$(SBCL) --noinform --disable-debugger --non-interactive \
	     --eval '(require :asdf)' \
	     --eval '(asdf:load-system "dsmr-mcp/tests")' \
	     --eval '(handler-case (asdf:test-system "dsmr-mcp/tests") (serious-condition (c) (uiop:die 1 "test failure: ~A" c)))'

## test-integration: slow cross-process suite (gated, off the push hot-path).
##
##   Runs dsmr-mcp/tests/integration — each leaf spawns a real child SBCL and
##   skips cleanly when none can be spawned. Same CL_SOURCE_REGISTRY and
##   fail-fast contract as `test`. Run on a schedule / label, not every push.
test-integration:
	$(SBCL) --noinform --disable-debugger --non-interactive \
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

## test-warm: run the fast suite against the prebuilt core ($(CORE)).
##
##   Skips the Quicklisp load and the recompile entirely — the core already
##   holds dsmr-mcp + the test leaves — so only the assertions run. Build the
##   core first with `make core`. `make test` remains the no-core load path and
##   works whether or not a core is present.
test-warm:
	$(SBCL) --core $(CORE) --noinform --disable-debugger --non-interactive \
	     --eval '(handler-case (asdf:test-system "dsmr-mcp/tests") (serious-condition (c) (uiop:die 1 "test failure: ~A" c)))'
