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
        install-skills check-skills

PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin

# Where the harness skills are deployed for the agent that reads them. Claude is
# the first target and deliberately not the only one; a second agent gets its own
# directory rather than this one being generalized in place.
SKILLDIR ?= $(HOME)/.claude/skills

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
