#!/usr/bin/env bash
#
# Live probes and transcript reports for the subagent-routing mod.
#
#   make-repo DIR --gsd-core global|local-pristine [--specialized true|false]
#       [--shapes LIST] [--executor-model opus|inherit]
#       Build a scratch git repository that the GSD commands can run in, with
#       the frozen probe fixtures. local-pristine adds a project-local gsd-core
#       copy restored to the installer's files; global leaves the live install.
#   make-config DIR
#       Build a throwaway Claude Code config directory with an unpatched
#       gsd-core copied from the live one and proven against the installer's
#       manifest. It holds no credentials and no bus hook; the live install is
#       read only and proven unchanged. DIR must be new, empty, or one an
#       earlier make-config built (it holds .routing-probe-config).
#       Copied markdown, and every copied file the installer did not write,
#       that names the live config root (~/.claude, $HOME/.claude, its absolute
#       path) is rewritten to name DIR, as the installer does for a config
#       directory of its own; the installer's scripts keep their bytes. Each
#       rewritten file that is not markdown is listed.
#   repoint DIR
#       Redo that rewrite in a directory make-config built, in place, and put
#       back the installer's bytes in any installer script an earlier rewrite
#       changed. Only agents, skills, hooks, commands, scripts, gsd-core and
#       CLAUDE.md under DIR are touched; credentials, settings, projects and
#       logs never are.
#   check-config DIR
#       Re-check a config directory: every gsd-core, scripts, agents, skills
#       and hooks manifest entry matches (markdown once the config-root rewrite
#       is undone, anything else byte for byte), no copied file still names the
#       live root, and the routing gate reports five units missing under DIR.
#   reads-outside DIR TRANSCRIPT [--live LIVE]
#       List what a session (and its subagents) touched outside DIR and the
#       session's working directory: file tool paths, and every command,
#       tool input, tool result, user message, loaded instruction file and
#       hook run that names the live config root LIVE (default $HOME/.claude,
#       whatever CLAUDE_CONFIG_DIR says) in any spelling. Exit 1 when anything
#       lies under or names LIVE, or when a transcript does not parse.
#   tree-hash DIR
#       Print a sorted SHA-256 listing of every file under DIR.
#   describe SHAPE
#       Print the task description for a probe shape: shell, lisp, mixed, docs.
#   run REPO --session-id UUID [--config-dir DIR] [--plugin-dir DIR]
#       [--capture DIR] [--debug-file FILE] [--append-system-prompt TEXT]
#       [--model MODEL] [--env KEY=VAL]... -- PROMPT
#       Run one headless Claude Code session in REPO and print its transcript.
#   run-arm ARM --gsd-core global|local-pristine --evidence DIR [--config-dir DIR]
#       [--plugin-dir DIR|none] [--executor-model opus|inherit] [--capture DIR]
#       [--orchestrator-model MODEL] [--only PATH[:SHAPE],...] [--env KEY=VAL]...
#       Run the probe cells one session at a time and write the evidence.
#       --orchestrator-model sets the model of every session in the arm and is
#       recorded per session in sessions.tsv.
#   report TRANSCRIPT
#       Print one TSV row per Agent call in a session: what was asked for,
#       what ran (from the subagent's own records) and what the mod logged.
#   ledger-row TRANSCRIPT...
#       Print one TSV row per transcript: path, turns, cache_read, cache_write,
#       output and models, each counted once per distinct message id.
#   cap-check TRANSCRIPT
#       Print cache_read summed over the transcript and its subagent
#       transcripts, the cap, and over or under; exit 3 when over or when a
#       transcript cannot be read. A torn line is skipped and reported.
#   check ARM EXPECTED_TSV [--dropped PATH,...]
#       Compare the arm's report files, in the directory holding EXPECTED_TSV,
#       with the expected routing; exit 1 on any mismatch. An expected cell of
#       a listed PATH that did not run is reported dropped-by-ruling and does
#       not fail.
#   bus-silent ROOT
#       Exit 1 and list the files when the bus state mentions ROOT.
#   replay RECORDINGS_DIR [--mod DIR]
#       Run the mod's replay tests over every recorded spawn in RECORDINGS_DIR,
#       against a temporary copy of the mod (default: this repository's).
#   record-history --out DIR [--types LIST] [--max-per-session N] TRANSCRIPT...
#       Write one recording per Agent call of a listed subagent type found in
#       each TRANSCRIPT, with a tape of the files the decision reads as they
#       stand now. An `expected` block already in DIR for that call is kept.
#
# Environment: ROUTING_PROBE_PATH_MAP=FROM=TO makes report read a plan file
# under TO where the dispatch named one under FROM (recorded transcripts).
#
# Exit status: 0 success, 1 failure, 64 usage.

set -u

PROGNAME=${0##*/}
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
GATE=$SCRIPT_DIR/../harness/scripts/gsd-routing-gate.sh
CONFIG_HOME=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
# The planning directory gsd-core reads, named once.
PLANNING_DIR=.planning
# Written by make-config into each directory it builds; reuse requires it.
CONFIG_MARKER=.routing-probe-config
LOG_DIR=logs/subagent-routing
PROBE_MODEL=claude-opus-5-5
LEADER_MODEL=claude-sonnet-5-5
PROBE_TIMEOUT=1800
# A session whose orchestrator and subagent transcripts sum past this many
# cache-read tokens (ledger-row accounting) stops the arm. Never raised.
CACHE_READ_CAP=5000000
PROBE_FILES=(scripts/probe.sh src/probe.lisp Makefile docs/probe.md)
SHAPES=(shell lisp mixed docs)
# Agent types whose rows are routed executors; the rest must run as requested.
EXECUTOR_TYPES=" gsd-executor shell-developer lisp-developer "

usage() {
    cat <<EOF
usage: $PROGNAME make-config DIR
       $PROGNAME repoint DIR
       $PROGNAME check-config DIR
       $PROGNAME reads-outside DIR TRANSCRIPT [--live LIVE]
       $PROGNAME tree-hash DIR
       $PROGNAME make-repo DIR --gsd-core global|local-pristine [--specialized true|false]
                 [--shapes LIST] [--executor-model opus|inherit]
       $PROGNAME describe shell|lisp|mixed|docs
       $PROGNAME run REPO --session-id UUID [--config-dir DIR] [--plugin-dir DIR]
                 [--capture DIR] [--debug-file FILE] [--append-system-prompt TEXT]
                 [--model MODEL] [--env KEY=VAL]... -- PROMPT
       $PROGNAME run-arm ARM --gsd-core global|local-pristine --evidence DIR [--config-dir DIR]
                 [--plugin-dir DIR|none] [--executor-model opus|inherit] [--capture DIR]
                 [--orchestrator-model MODEL] [--only PATH[:SHAPE],...] [--env KEY=VAL]...
       $PROGNAME report TRANSCRIPT
       $PROGNAME ledger-row TRANSCRIPT...
       $PROGNAME cap-check TRANSCRIPT
       $PROGNAME check ARM EXPECTED_TSV [--dropped PATH,...]
       $PROGNAME bus-silent ROOT
       $PROGNAME replay RECORDINGS_DIR [--mod DIR]
       $PROGNAME record-history --out DIR [--types LIST] [--max-per-session N] TRANSCRIPT...
EOF
}

die() { echo "$PROGNAME: $*" >&2; exit 1; }
usage_error() { [ $# -gt 0 ] && echo "$PROGNAME: $*" >&2; usage >&2; exit 64; }

# --- make-repo ---------------------------------------------------------------

# link_planning DIR: where this site keeps planning state outside each
# repository (an identity script under the config dir names the place), make
# DIR's planning directory a link to it, as the session-start hook would;
# otherwise make a plain directory. A non-empty target is refused.
link_planning() {
    local dir=$1 ident=$CONFIG_HOME/scripts/project-identity.js target
    if [ -f "$ident" ] && target=$(node -e '
            const id = require(process.argv[1]).resolveProjectIdentity(process.argv[2]);
            if (id.metaProject) process.exit(1);
            process.stdout.write(id.planningDir);' "$ident" "$dir"); then
        [ -z "$(ls -A "$target" 2>/dev/null)" ] || die "planning target $target is not empty; move it aside first"
        mkdir -p "$target" || die "cannot create $target"
        ln -s "$target" "$dir/$PLANNING_DIR" || die "cannot link $dir/$PLANNING_DIR"
        echo "planning directory linked to $target"
    else
        mkdir -p "$dir/$PLANNING_DIR" || die "cannot create $dir/$PLANNING_DIR"
    fi
}

# --- fixtures ----------------------------------------------------------------

# probe_line FILE: the comment line a probe appends to FILE.
probe_line() {
    case "$1" in
        scripts/probe.sh|Makefile) printf '%s\n' '# routing probe' ;;
        src/probe.lisp) printf '%s\n' ';; routing probe' ;;
        docs/probe.md) printf '%s\n' 'Routing probe.' ;;
        *) return 1 ;;
    esac
}

# shape_files SHAPE: the probe files a shape touches, space separated.
shape_files() {
    case "$1" in
        shell) printf '%s\n' scripts/probe.sh ;;
        lisp) printf '%s\n' src/probe.lisp ;;
        mixed) printf '%s\n' 'src/probe.lisp Makefile' ;;
        docs) printf '%s\n' docs/probe.md ;;
        *) return 1 ;;
    esac
}

# shape_number SHAPE: the two-digit plan number of a shape in the execute-phase fixture.
shape_number() {
    case "$1" in
        shell) printf '%s\n' 01 ;;
        lisp) printf '%s\n' 02 ;;
        mixed) printf '%s\n' 03 ;;
        docs) printf '%s\n' 04 ;;
        *) return 1 ;;
    esac
}

cmd_describe() {
    [ $# -eq 1 ] || usage_error "describe needs one SHAPE"
    case "$1" in
        shell) printf '%s\n' 'Append the comment line "# routing probe" as the last line of scripts/probe.sh and change nothing else.' ;;
        lisp) printf '%s\n' 'Append the comment line ";; routing probe" as the last line of src/probe.lisp using the structure-aware Lisp tools, and change nothing else. Do not load a system or run tests.' ;;
        mixed) printf '%s\n' 'Append the comment line ";; routing probe" as the last line of src/probe.lisp using the structure-aware Lisp tools, and the comment line "# routing probe" as the last line of Makefile, and change nothing else. Do not load a system or run tests.' ;;
        docs) printf '%s\n' 'Append the line "Routing probe." as the last line of docs/probe.md and change nothing else.' ;;
        *) usage_error "unknown shape $1" ;;
    esac
}

# write_plan DIR SHAPE: the execute-phase plan for one shape.
write_plan() {
    local dir=$1 shape=$2 num files hint=- f line verify="" out
    local -a list
    num=$(shape_number "$shape") || return 1
    files=$(shape_files "$shape")
    read -ra list <<<"$files"
    [ "$shape" != shell ] || hint=shell-developer
    for f in "${list[@]}"; do
        line=$(probe_line "$f")
        verify+="${verify:+ && }tail -n 1 $f | grep -qxF '$line'"
    done
    out=$dir/$PLANNING_DIR/phases/01-probe/01-$num-PLAN.md
    {
        printf -- '---\nphase: 01-probe\nplan: %s\ntype: execute\nwave: 1\ndepends_on: []\nfiles_modified:\n' "$num"
        for f in "${list[@]}"; do printf '  - %s\n' "$f"; done
        printf 'autonomous: true\n'
        [ "$hint" = - ] || printf 'agent_hint: %s\n' "$hint"
        printf 'requirements: []\n\nmust_haves:\n  truths:\n'
        for f in "${list[@]}"; do
            # shellcheck disable=SC2016 # backticks are literal plan text
            printf '    - "The last line of %s is exactly `%s`"\n' "$f" "$(probe_line "$f")"
        done
        printf -- '---\n\n<objective>\nAppend one comment line to the probe file%s named below.\n</objective>\n\n' \
            "$([ "${#list[@]}" -eq 1 ] || printf s)"
        printf '<tasks>\n\n<task type="auto">\n  <name>Task 1: Append the probe line</name>\n  <files>%s</files>\n  <action>\n' "$files"
        for f in "${list[@]}"; do
            # shellcheck disable=SC2016 # backticks are literal plan text
            printf '    Append the line `%s` as the last line of %s.\n' "$(probe_line "$f")" "$f"
        done
        printf '    Change nothing else.\n'
        case "$files" in *probe.lisp*)
            printf '    Use the structure-aware Lisp tools for the Lisp file. Do not load a system or run tests.\n' ;;
        esac
        printf '  </action>\n  <verify>\n    <automated>%s</automated>\n  </verify>\n' "$verify"
        printf '  <done>Each file named above ends with its probe line.</done>\n</task>\n\n</tasks>\n'
    } > "$out"
}

# write_verification DIR: four high-severity findings, one per probe shape.
write_verification() {
    cat > "$1/$PLANNING_DIR/phases/01-probe/01-VERIFICATION.md" <<'EOF'
---
phase: 01-probe
status: gaps_found
---

# Probe Verification

Four gaps remain, one per probe shape. Each probe file must end with its probe line.

## Gaps

### F-01 (high): the shell probe lacks its trailing line

Files: scripts/probe.sh

The last line of scripts/probe.sh must be the comment `# routing probe`.

### F-02 (high): the Lisp probe lacks its trailing line

Files: src/probe.lisp

The last line of src/probe.lisp must be the comment `;; routing probe`.

### F-03 (high): the mixed probe lacks both trailing lines

Files: src/probe.lisp, Makefile

The last line of src/probe.lisp must be `;; routing probe` and the last line of Makefile must be `# routing probe`.

### F-04 (high): the document lacks its trailing line

Files: docs/probe.md

The last line of docs/probe.md must be `Routing probe.`
EOF
}

# write_probe_files DIR SPECIALIZED SHAPES EXECUTOR_MODEL: sources, planning
# state, config and the frozen plan and finding fixtures. SHAPES is a comma
# list of the execute-phase plans to write (empty for none).
write_probe_files() {
    local dir=$1 specialized=$2 shapes=$3 exmodel=$4 s n=0 plans=""
    local -a want=()
    mkdir -p "$dir/scripts" "$dir/src" "$dir/docs"
    link_planning "$dir"
    printf '#!/usr/bin/env bash\necho "probe"\n' > "$dir/scripts/probe.sh"
    chmod +x "$dir/scripts/probe.sh"
    printf '(defun probe () "probe")\n' > "$dir/src/probe.lisp"
    printf 'test:\n\ttrue\n' > "$dir/Makefile"
    printf '# Probe\n\nA scratch repository for routing probes.\n' > "$dir/docs/probe.md"

    jq -n --argjson specialized "$specialized" --arg exmodel "$exmodel" '{
      mode: "yolo",
      model_profile: "balanced",
      parallelization: false,
      commit_docs: true,
      workflow: {
        research: false,
        plan_check: false,
        verifier: false,
        nyquist_validation: false,
        auto_advance: false,
        use_worktrees: false
      },
      planning: { agents: { executor: "lisp-developer", language: "common-lisp", specialized: $specialized } },
      model_overrides: { "gsd-executor": $exmodel },
      agent_skills: { "gsd-planner": ["global:executor-routing"] },
      git: { branching_strategy: "none" }
    }' > "$dir/$PLANNING_DIR/config.json"

    mkdir -p "$dir/$PLANNING_DIR/phases/01-probe"
    write_verification "$dir"
    IFS=, read -ra want <<<"$shapes"
    for s in "${want[@]}"; do
        [ -n "$s" ] || continue
        write_plan "$dir" "$s" || die "unknown shape $s"
        n=$((n + 1))
        plans+="- [ ] 01-$(shape_number "$s")-PLAN.md - $s probe"$'\n'
    done

    cat > "$dir/$PLANNING_DIR/STATE.md" <<EOF
# Project State

## Current Position

Phase: 1 of 1 (Probe)
Plan: 0 of $n
Status: Ready to execute
EOF
    cat > "$dir/$PLANNING_DIR/ROADMAP.md" <<EOF
# Roadmap

## Phases

- [ ] **Phase 1: Probe** - append one comment line to each probe file

### Phase 1: Probe

**Goal:** Append one comment line to each probe file.
**Depends on:** Nothing
**Requirements:** none
**Plans:** $n plans

Plans:
$plans
EOF
    cat > "$dir/$PLANNING_DIR/PROJECT.md" <<'EOF'
# Probe

A scratch repository for routing probes: one shell script, one Lisp file, a
Makefile and one document.
EOF
}

# pristine_restore ROOT: restore each patched gsd-core target under ROOT from
# its backup, then delete every backup. Targets and suffixes are the gate's
# units rows.
pristine_restore() {
    local root=$1 row target suffix
    [ -f "$GATE" ] || die "routing gate not found: $GATE"
    while IFS= read -r row; do
        target=$(printf '%s\n' "$row" | cut -d'|' -f2)
        suffix=$(printf '%s\n' "$row" | cut -d'|' -f5)
        [ -f "$root/$target$suffix" ] || die "no backup for $target ($suffix)"
        cp "$root/$target$suffix" "$root/$target"
        echo "restored $target from $suffix"
    done < <(sed -n "s/^  '\([a-z-]*|gsd-core\/[^']*\)'\$/\1/p" "$GATE")
    find "$root/gsd-core" -name '*.pre-*' -type f -delete
}

# Subtrees of a config directory that hold copied artifacts naming the config
# root; repoint and the isolation check read and rewrite nothing else.
CONFIG_ARTIFACTS=(agents skills hooks commands scripts gsd-core CLAUDE.md)

# root_rel ROOT: ROOT relative to $HOME (".claude" for ~/.claude); a root
# outside $HOME comes out in ../..-form, which "~/" followed by it resolves.
root_rel() {
    realpath -m --relative-to="$HOME" -- "$1"
}

# swap_prepare FROM TO: set the exported names swap_root and names_root read,
# computed once per call site.
swap_prepare() {
    SWAP_FROM_REL=$(root_rel "$1"); SWAP_FROM_ABS=$(realpath -m -- "$1")
    SWAP_TO_REL=$(root_rel "$2"); SWAP_TO_ABS=$(realpath -m -- "$2")
    export SWAP_FROM_REL SWAP_FROM_ABS SWAP_TO_REL SWAP_TO_ABS
}

# A name of the config root ends where its path component ends: not before a
# word character, a hyphen, or a dot that opens an extension, so
# ~/.claude-plugin and ~/.claude.json are left alone while a sentence ending in
# ~/.claude. is not. ~/.claude.json is Claude Code's state file, kept under
# CLAUDE_CONFIG_DIR as .claude.json; it is not a path under the config root.

# swap_root: stdin to stdout, every name of config root FROM (see swap_prepare)
# replaced by the same form of TO: ~/REL, $HOME/REL and the absolute path.
# Each form keeps its kind, so swapping back restores the original bytes.
swap_root() {
    perl -pe '
        BEGIN { ($fr, $fa, $tr, $ta) = @ENV{qw(SWAP_FROM_REL SWAP_FROM_ABS SWAP_TO_REL SWAP_TO_ABS)}; }
        s{(?:(~|\$HOME)/\Q$fr\E|(?<![\w./-])\Q$fa\E)(?![\w-]|\.\w)}{defined $1 ? "$1/$tr" : $ta}ge;'
}

# names_root FILE: succeed when FILE names config root FROM in a form swap_root rewrites.
names_root() {
    perl -ne '
        BEGIN { ($r, $a) = @ENV{qw(SWAP_FROM_REL SWAP_FROM_ABS)}; }
        if (/(?:(?:~|\$HOME)\/\Q$r\E|(?<![\w.\/-])\Q$a\E)(?![\w-]|\.\w)/) { $f = 1; last }
        END { exit($f ? 0 : 1) }' "$1"
}

# artifact_files DIR: NUL-separated text files of the copied artifacts under DIR
# that contain config root FROM (set by swap_prepare) as a substring.
artifact_files() {
    local dir=$1 sub
    for sub in "${CONFIG_ARTIFACTS[@]}"; do
        [ -e "$dir/$sub" ] || continue
        find "$dir/$sub" -type f -print0
    done | xargs -0 -r grep -IlZF -e "$SWAP_FROM_REL" -e "$SWAP_FROM_ABS" 2>/dev/null
}

# load_owned DIR: fill OWNED with every path the installer manifest under DIR lists.
declare -A OWNED=()
load_owned() {
    local rel list
    OWNED=()
    [ -f "$1/gsd-file-manifest.json" ] || return 0
    list=$(jq -r '.files | keys[]' "$1/gsd-file-manifest.json") || die "cannot read $1/gsd-file-manifest.json"
    while IFS= read -r rel; do
        [ -n "$rel" ] && OWNED[$rel]=1
    done <<<"$list"
}

# rewritable REL: whether repoint rewrites REL (relative to the config dir).
# The installer rewrites the config root in its markdown only, so its other
# files keep their bytes; every file it did not write is rewritten.
rewritable() {
    case "$1" in *.md) return 0 ;; esac
    [ -z "${OWNED[$1]:-}" ]
}

# swap_in_place FILE: replace FILE with swap_root of itself, keeping its mode.
# The new content goes to a temporary file mktemp creates beside FILE, so a
# link already standing at any fixed name there is never written through.
swap_in_place() {
    local f=$1 tmp
    tmp=$(mktemp -- "$f.repoint.XXXXXX") || die "cannot create a temporary file beside $f"
    swap_root < "$f" > "$tmp" || { rm -f -- "$tmp"; die "cannot rewrite $f"; }
    if ! { chmod --reference="$f" "$tmp" && mv -f -- "$tmp" "$f"; }; then
        rm -f -- "$tmp"; die "cannot replace $f"
    fi
}

# restore_installer_code DIR FROM: put the installer's bytes back in each
# installer file under DIR that is not markdown and matches the manifest once
# DIR is swapped back to FROM; print each one restored.
restore_installer_code() {
    local dir=$1 from=$2 rel want list
    [ -f "$dir/gsd-file-manifest.json" ] || return 0
    list=$(jq -r '.files | to_entries[] | select(.key | endswith(".md") | not) | [.key, .value] | @tsv' \
        "$dir/gsd-file-manifest.json") || die "cannot read $dir/gsd-file-manifest.json"
    swap_prepare "$dir" "$from"
    while IFS=$'\t' read -r rel want; do
        [ -n "$rel" ] && [ -f "$dir/$rel" ] && [ ! -L "$dir/$rel" ] || continue
        [ "$(sha256sum < "$dir/$rel" | cut -d' ' -f1)" != "$want" ] || continue
        [ "$(swap_root < "$dir/$rel" | sha256sum | cut -d' ' -f1)" = "$want" ] || continue
        swap_in_place "$dir/$rel"
        echo "restored $rel"
    done <<<"$list"
}

# drop_bytecode_caches DIR: remove each __pycache__ directory under the copied
# artifacts in DIR, printing it. Python bytecode embeds the path of its source
# and is rebuilt from the rewritten source on use.
drop_bytecode_caches() {
    local dir=$1 sub d
    for sub in "${CONFIG_ARTIFACTS[@]}"; do
        [ -d "$dir/$sub" ] && [ ! -L "$dir/$sub" ] || continue
        while IFS= read -r -d '' d; do
            rm -r -- "$d" || die "cannot remove $d"
            echo "removed bytecode cache ${d#"$dir"/}"
        done < <(find "$dir/$sub" -type d -name __pycache__ -prune -print0)
    done
}

# repoint_tree DIR FROM: rewrite each copied artifact under DIR that names
# config root FROM to name DIR (rewritable files only), and restore installer
# files an earlier rewrite changed; print each file that is not markdown and
# the count. Return 1, naming them, when a file cannot be read or is binary
# and names FROM.
repoint_tree() {
    local dir=$1 from=$2 f rel n=0
    if [ "$(realpath -m -- "$from")" != "$(realpath -m -- "$dir")" ]; then
        load_owned "$dir"
        restore_installer_code "$dir" "$from"
        drop_bytecode_caches "$dir"
        swap_prepare "$from" "$dir"
        while IFS= read -r -d '' f; do
            rel=${f#"$dir"/}
            rewritable "$rel" || continue
            names_root "$f" || continue
            swap_in_place "$f"
            case "$rel" in *.md) ;; *) echo "rewrote $rel (not installer markdown)" ;; esac
            n=$((n + 1))
        done < <(artifact_files "$dir")
    fi
    echo "repointed $n files to $dir"
    local rows kind bad=0
    rows=$(scan_live "$dir" "$from") || die "cannot scan $dir"
    while IFS=$'\t' read -r rel kind; do
        case "$kind" in
            unreadable|binary) echo "cannot rewrite $rel: $kind"; bad=1 ;;
        esac
    done <<<"$rows"
    [ "$bad" -eq 0 ]
}

# scan_live DIR LIVE: one REL<TAB>KIND line per finding in the copied
# artifacts under DIR (REL relative to DIR). KIND is unreadable (a file or
# directory that cannot be read), binary (a file holding a NUL byte that names
# LIVE), abs (names LIVE by absolute path), home (names LIVE from the home
# directory) or join (joins the home directory with LIVE's last component at
# run time).
scan_live() {
    local dir=$1 live=$2 sub base join_re
    base=$(basename -- "$(realpath -ms -- "$live")")
    join_re="(?:homedir\\(\\)|env\\.HOME|env\\[[\"']HOME[\"']\\])\\s*,\\s*[\"']$(re_quote "$base")[\"']"
    for sub in "${CONFIG_ARTIFACTS[@]}"; do
        [ -e "$dir/$sub" ] || continue
        find "$dir/$sub" \( -type f -o -type d \( ! -readable -o ! -executable \) \) -print0 2>/dev/null
    done | SCAN_DIR=$dir ABS_RE=$(live_abs_re "$live") HOME_RE=$(live_home_re "$live") JOIN_RE=$join_re perl -0 -ne '
        BEGIN { $abs = qr/$ENV{ABS_RE}/; $home = qr/$ENV{HOME_RE}/; $join = qr/$ENV{JOIN_RE}/; $d = $ENV{SCAN_DIR}; }
        chomp; my $f = $_; my $rel = substr($f, length($d) + 1);
        if (-d $f) { print "$rel\tunreadable\n"; next }
        my $h;
        unless (open($h, "<", $f)) { print "$rel\tunreadable\n"; next }
        my $c = do { local $/; <$h> };
        close $h;
        unless (defined $c) { print "$rel\tunreadable\n"; next }
        my @k = grep { defined } ($c =~ $abs ? "abs" : undef, $c =~ $home ? "home" : undef, $c =~ $join ? "join" : undef);
        next unless @k;
        if ($c =~ /\0/) { print "$rel\tbinary\n"; next }
        print "$rel\t$_\n" for @k;'
}

# live_references DIR LIVE: print each copied artifact under DIR that still
# names config root LIVE in any spelling (live_text_re), cannot be read, or is
# binary and names it, and each link out of the config directory (live_links);
# return 1 when there is one. Installer code that is not
# markdown keeps its home-relative names, as the installer leaves them, and is
# listed without failing, as are run-time joins of the home directory with
# LIVE's name.
live_references() {
    local dir=$1 live=$2 rel kind line rows n=0
    local -A said=()
    [ "$(realpath -m -- "$live")" != "$(realpath -m -- "$dir")" ] || return 0
    load_owned "$dir"
    rows=$(scan_live "$dir" "$live") || die "cannot scan $dir"
    while IFS=$'\t' read -r rel kind; do
        [ -n "$rel" ] || continue
        case "$kind" in
            unreadable) line="unreadable $rel" ;;
            binary) line="binary file names the live root $rel" ;;
            abs) line="live-root reference $rel" ;;
            home)
                if rewritable "$rel"; then line="live-root reference $rel"
                else line="installer code names the home config root $rel"; fi ;;
            join) line="runtime home join $rel" ;;
            *) continue ;;
        esac
        [ -z "${said[$line]:-}" ] || continue
        said[$line]=1
        printf '%s\n' "$line"
        case "$line" in "installer code "*|"runtime home join "*) ;; *) n=$((n + 1)) ;; esac
    done <<<"$rows"
    rows=$(live_links "$dir" "$live") || die "cannot scan $dir for links"
    [ -z "$rows" ] || { printf '%s\n' "$rows"; n=$((n + 1)); }
    [ "$n" -eq 0 ]
}

# live_links DIR LIVE: print each symbolic link under DIR that resolves into
# config root LIVE, and each one under the copied artifacts that resolves
# outside DIR, with its resolved target.
live_links() {
    local dir live_l live_p link target rel top
    dir=$(realpath -m -- "$1"); live_l=$(realpath -ms -- "$2"); live_p=$(realpath -m -- "$2")
    while IFS= read -r -d '' link; do
        target=$(realpath -m -- "$link")
        rel=${link#"$dir"/}
        top=${rel%%/*}
        if path_under "$target" "$live_l" "$live_p" \
                || { [[ " ${CONFIG_ARTIFACTS[*]} " == *" $top "* ]] && ! path_under "$target" "$dir"; }; then
            printf 'link out of the config directory %s -> %s\n' "$rel" "$target"
        fi
    done < <(find "$dir" -type l -print0)
}

# settings_references DIR LIVE: print the JSON path of each string in DIR's
# settings.json, settings.local.json and .claude.json that names config root
# LIVE in any spelling (live_text_re); return 1 when there is one. The files
# are only read. A path into an env block stops at the block, so no variable
# name or value is printed.
settings_references() {
    local dir=$1 re f rows n=0
    re=$(live_text_re "$2")
    for f in settings.json settings.local.json .claude.json; do
        [ -f "$dir/$f" ] || continue
        # shellcheck disable=SC2016 # jq program
        if ! rows=$(jq -r --arg re "$re" '
                [ paths(type == "string") as $p | select(getpath($p) | test($re))
                  | ($p | index("env")) as $e
                  | (if $e == null then $p else $p[:$e + 1] end)
                  | map(if type == "number" then "[\(.)]" else ".\(.)" end) | join("") ]
                | unique[]' "$dir/$f"); then
            echo "unreadable $f"
            n=$((n + 1))
            continue
        fi
        [ -n "$rows" ] || continue
        while IFS= read -r p; do
            echo "settings reference $f $p"
            n=$((n + 1))
        done <<<"$rows"
    done
    [ "$n" -eq 0 ]
}

# Installer manifest subtrees check-config and make-config prove.
PROVEN_PREFIXES=(gsd-core/ scripts/ agents/ skills/ hooks/)

# pristine_prove ROOT [LIVE [PREFIX...]]: print the proof and return 1 if it
# does not hold: every installer manifest entry under ROOT whose path starts
# with a PREFIX (default gsd-core/ and scripts/) matches by SHA-256, and the
# gate exits 1 printing five missing lines. Markdown that names ROOT matches
# once ROOT is swapped back to LIVE, the config root the manifest was written
# for; any other file must match byte for byte.
pristine_prove() {
    local root=$1 live=${2:-$1} manifest=$1/gsd-file-manifest.json
    local entries=0 matched=0 bad=0 rel want got gate_out gate_rc nmissing
    local -a prefixes=(gsd-core/ scripts/)
    [ $# -le 2 ] || prefixes=("${@:3}")
    swap_prepare "$root" "$live"
    [ -f "$manifest" ] || { echo "no manifest: $manifest"; return 1; }
    while IFS=$'\t' read -r rel want; do
        entries=$((entries + 1))
        got=$(sha256sum "$root/$rel" 2>/dev/null | cut -d' ' -f1)
        if [ "$got" != "$want" ] && [ -f "$root/$rel" ] && [ "${rel%.md}" != "$rel" ]; then
            got=$(swap_root < "$root/$rel" | sha256sum | cut -d' ' -f1)
        fi
        if [ "$got" = "$want" ]; then
            matched=$((matched + 1))
        else
            bad=$((bad + 1))
            echo "mismatch $rel"
        fi
    done < <(jq -r '.files | to_entries[] | select(.key as $k | any($ARGS.positional[]; . as $p | $k | startswith($p)))
                    | [.key, .value] | @tsv' --args "${prefixes[@]}" < "$manifest")
    echo "manifest $(jq -r .version "$manifest"): $matched of $entries entries under ${prefixes[*]} match"

    gate_out=$(bash "$GATE" --root "$root")
    gate_rc=$?
    printf '%s\n' "$gate_out"
    echo "gate exit $gate_rc"
    nmissing=$(printf '%s\n' "$gate_out" | grep -c '^missing ')
    [ "$bad" -eq 0 ] && [ "$entries" -gt 0 ] && [ "$gate_rc" -eq 1 ] && [ "$nmissing" -eq 5 ] || {
        echo "pristine check FAILED"
        return 1
    }
    echo "pristine check passed"
}

# copy_installer_scripts SRC DST: copy the scripts the installer wrote under
# SRC into DST; gsd-tools loads files from <config>/scripts.
copy_installer_scripts() {
    local src=$1 dst=$2 rel
    while IFS= read -r rel; do
        mkdir -p "$dst/$(dirname "$rel")"
        cp -a "$src/$rel" "$dst/$rel" || die "cannot copy $src/$rel"
    done < <(jq -r '.files | keys[] | select(startswith("scripts/"))' "$src/gsd-file-manifest.json")
}

# copy_hook_scripts LIVE DIR: copy into DIR/scripts each script under
# LIVE/scripts that a hook copied into DIR/hooks names by absolute path, so
# the hook still finds it once repointed; print each one.
copy_hook_scripts() {
    local live=$1 dir=$2 rel names
    [ -d "$dir/hooks" ] || return 0
    # shellcheck disable=SC2016 # perl program
    names=$(find "$dir/hooks" -type f -print0 | LIVE=$live xargs -0 -r perl -ne '
        BEGIN { $l = $ENV{LIVE} }
        print "$1\n" while m{\Q$l\E/(scripts/[\w.-]+)}g;' | sort -u) || die "cannot read $dir/hooks"
    while IFS= read -r rel; do
        [ -n "$rel" ] && [ -f "$live/$rel" ] || continue
        mkdir -p "$dir/${rel%/*}" || die "cannot create $dir/${rel%/*}"
        cp -a "$live/$rel" "$dir/$rel" || die "cannot copy $live/$rel"
        echo "copied $rel (a copied hook requires it)"
    done <<<"$names"
}

# install_pristine DIR: copy gsd-core, and the installer's scripts it loads,
# into DIR/.claude; restore each patched target from its backup; print the
# proof and return 1 if it does not hold.
install_pristine() {
    local dir=$1 src=$CONFIG_HOME/gsd-core
    [ -d "$src" ] || die "gsd-core not installed under $CONFIG_HOME"
    [ -f "$CONFIG_HOME/gsd-file-manifest.json" ] || die "installer manifest not found: $CONFIG_HOME/gsd-file-manifest.json"
    mkdir -p "$dir/.claude"
    cp -a "$src" "$dir/.claude/gsd-core" || die "cannot copy $src"
    cp -a "$CONFIG_HOME/gsd-file-manifest.json" "$dir/.claude/gsd-file-manifest.json" || die "cannot copy the manifest"
    copy_installer_scripts "$CONFIG_HOME" "$dir/.claude"
    pristine_restore "$dir/.claude"
    pristine_prove "$dir/.claude"
}

# --- make-config -------------------------------------------------------------

# tree_hash DIR: sorted SHA-256 listing of every file under DIR.
tree_hash() {
    [ -d "$1" ] || die "no such directory: $1"
    (cd "$1" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum)
}

cmd_tree_hash() {
    [ $# -eq 1 ] || usage_error "tree-hash needs one DIR"
    tree_hash "$1"
}

cmd_check_config() {
    [ $# -eq 1 ] || usage_error "check-config needs one DIR"
    [ -d "$1" ] || die "no such directory: $1"
    local dir live refs rc=0
    dir=$(cd "$1" && pwd)
    live=$(realpath -m "$CONFIG_HOME")
    pristine_prove "$dir" "$live" "${PROVEN_PREFIXES[@]}" || rc=1
    local lrc
    refs=$(live_references "$dir" "$live"); lrc=$?
    [ -z "$refs" ] || printf '%s\n' "$refs"
    [ "$lrc" -eq 0 ] || { echo "isolation check FAILED: copied files name $live"; rc=1; }
    settings_references "$dir" "$live" || { echo "isolation check FAILED: settings name $live"; rc=1; }
    [ "$rc" -ne 0 ] || echo "isolation check passed"
    return "$rc"
}

# cmd_repoint DIR: repoint_tree for a directory make-config built.
cmd_repoint() {
    [ $# -eq 1 ] || usage_error "repoint needs one DIR"
    [ -d "$1" ] || die "no such directory: $1"
    local live dir
    live=$(realpath -m "$CONFIG_HOME")
    dir=$(realpath -m "$1")
    case "$dir" in
        "$live"|"$live"/*) die "refusing $dir: it is inside the live config directory $live" ;;
    esac
    case "$live" in "$dir"/*) die "refusing $dir: it contains the live config directory $live" ;; esac
    [ -f "$dir/$CONFIG_MARKER" ] || die "refusing $dir: make-config did not build it (no $CONFIG_MARKER)"
    repoint_tree "$dir" "$live"
}

# re_quote TEXT: TEXT as a regular expression matching itself, for perl and jq.
re_quote() {
    printf '%s' "$1" | sed 's/[][\\.^$|?*+(){}\/]/\\&/g'
}

# live_abs_re LIVE: a regular expression (perl and jq) matching config root
# LIVE by absolute path, logical and physical, each also JSON-escaped.
live_abs_re() {
    local a alts=()
    for a in "$(realpath -ms -- "$1")" "$(realpath -m -- "$1")"; do
        alts+=("$(re_quote "$a")" "$(re_quote "${a//\//\\/}")")
    done
    local IFS='|'
    printf '(?:%s)[\x22\x27]?(?![\\w-])' "${alts[*]}"
}

# live_home_re LIVE: a regular expression matching LIVE named from the home
# directory: ~/REL, $HOME/REL and ${HOME}/REL, with optional quotes around the
# slash. Matches nothing when LIVE does not lie under $HOME.
live_home_re() {
    local a home rel alts=()
    for a in "$(realpath -ms -- "$1")" "$(realpath -m -- "$1")"; do
        for home in "$(realpath -ms -- "$HOME")" "$(realpath -m -- "$HOME")"; do
            case "$a" in "$home"/*) rel=${a#"$home"/} ;; *) continue ;; esac
            alts+=("(?:~|\\\$HOME|\\\$\\{HOME\\})[\"']?/[\"']?$(re_quote "$rel")")
        done
    done
    [ "${#alts[@]}" -gt 0 ] || { printf '(?!)'; return 0; }
    local IFS='|'
    printf '(?:%s)[\x22\x27]?(?![\\w-])' "${alts[*]}"
}

# live_text_re LIVE: config root LIVE named in text in any of those spellings.
# Broader than the forms repoint rewrites.
live_text_re() {
    printf '(?:%s|%s)' "$(live_abs_re "$1")" "$(live_home_re "$1")"
}

# path_under PATH ROOT...: whether PATH is one of the ROOTs or lies under one.
path_under() {
    local p=$1 r
    shift
    for r in "$@"; do
        case "$p" in "$r"|"$r"/*) return 0 ;; esac
    done
    return 1
}

# cmd_reads_outside DIR TRANSCRIPT [--live LIVE]: what the session and its
# subagents touched outside DIR and the session's cwd, one channel and value
# per line. Paths come from Read, Grep, Glob, Edit, Write, MultiEdit and
# NotebookEdit calls; text from every other tool call's input, tool results,
# user messages and the paths, commands and output of attachments (loaded
# instructions, hooks) is searched for LIVE in any spelling (live_text_re).
# LIVE defaults to $HOME/.claude, whatever CLAUDE_CONFIG_DIR says. Exit 1
# when anything names or lies under LIVE, or when a transcript cannot be
# parsed.
cmd_reads_outside() {
    local -
    set -o pipefail
    local dir="" t="" live_arg="" live_l live_p cwd re out rows="" kind tool p lp pp breach=0 f
    local -a files=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --live) [ $# -ge 2 ] || usage_error "--live needs a value"; live_arg=$2; shift 2 ;;
            -*) usage_error "unknown option $1" ;;
            *) if [ -z "$dir" ]; then dir=$1; elif [ -z "$t" ]; then t=$1; else usage_error "reads-outside needs DIR and TRANSCRIPT"; fi; shift ;;
        esac
    done
    [ -n "$dir" ] && [ -n "$t" ] || usage_error "reads-outside needs DIR and TRANSCRIPT"
    [ -d "$dir" ] || die "no such directory: $dir"
    [ -f "$t" ] || die "no such transcript: $t"
    [ -n "$live_arg" ] || live_arg=$HOME/.claude
    live_l=$(realpath -ms -- "$live_arg"); live_p=$(realpath -m -- "$live_arg")
    dir=$(realpath -m -- "$dir")
    if path_under "$dir" "$live_l" "$live_p" || path_under "$live_l" "$dir" || path_under "$live_p" "$dir"; then
        die "refusing $dir: it is, holds or lies under the live config root $live_p"
    fi
    files=("$t")
    if [ -d "${t%.jsonl}/subagents" ]; then
        for f in "${t%.jsonl}"/subagents/*.jsonl; do [ -f "$f" ] && files+=("$f"); done
        [ "${#files[@]}" -gt 1 ] || die "${t%.jsonl}/subagents holds no subagent transcripts"
    fi
    re=$(live_text_re "$live_arg")
    for f in "${files[@]}"; do
        # shellcheck disable=SC2016 # jq program
        out=$(jq -r --arg re "$re" '
            def hit($ch): select(type == "string" and test($re))
                | match($re) as $m
                | [ "hit", $ch, (.[([$m.offset - 40, 0] | max):($m.offset + $m.length + 40)] | gsub("[\t\n\r]"; " ")) ];
            def pathrow($tool): select(type == "string" and . != "")
                | if (startswith("/") or . == "~" or startswith("~/")) then ["path", $tool, .] else hit($tool) end;
            if .type == "assistant" then
                .message.content[]? | select(.type == "tool_use") | .name as $n | .input as $i
                | if $n == "Read" then $i.file_path | pathrow($n)
                  elif $n == "Grep" then $i.path | pathrow($n)
                  elif $n == "Glob" then ($i.path, $i.pattern) | pathrow($n)
                  elif ($n == "Edit" or $n == "Write" or $n == "MultiEdit") then $i.file_path | pathrow($n)
                  elif $n == "NotebookEdit" then $i.notebook_path | pathrow($n)
                  else $i | .. | hit($n) end
            elif .type == "user" then
                .message.content
                | if type == "string" then hit("user")
                  else .[]? | if .type == "tool_result" then .content | .. | hit("result")
                              elif .type == "text" then .text | hit("user")
                              else empty end
                  end
            elif .type == "attachment" then
                (.attachment.type // "-") as $at
                | .attachment | .. | objects | to_entries[]
                | select(.key == "path" or .key == "filePath" or .key == "file_path"
                         or .key == "command" or .key == "stdout" or .key == "stderr")
                | .value | hit("attachment:" + $at)
            else empty end
            | @tsv' "$f" 2>&1) || die "cannot parse $f: $out"
        rows+=$out$'\n'
    done
    cwd=$(jq -rn 'first(inputs | select(.cwd != null) | .cwd) // empty' "$t") || die "cannot parse $t"
    while IFS=$'\t' read -r kind tool p; do
        [ -n "$kind" ] || continue
        if [ "$kind" = hit ]; then
            printf '%s\t%s\n' "$tool" "$p"
            breach=1
            continue
        fi
        case "$p" in \~) p=$HOME ;; \~/*) p=$HOME/${p#\~/} ;; esac
        lp=$(realpath -ms -- "$p"); pp=$(realpath -m -- "$p")
        if path_under "$lp" "$live_l" "$live_p" || path_under "$pp" "$live_l" "$live_p"; then
            printf '%s\t%s\n' "$tool" "$pp"
            breach=1
            continue
        fi
        path_under "$pp" "$dir" && continue
        if [ -n "$cwd" ] && path_under "$pp" "$cwd"; then continue; fi
        printf '%s\t%s\n' "$tool" "$pp"
    done < <(printf '%s' "$rows" | LC_ALL=C sort -u)
    [ "$breach" -eq 0 ]
}

# live_gate_present: the count of present lines the gate prints for the live config.
live_gate_present() {
    bash "$GATE" --root "$CONFIG_HOME" | grep -c '^present '
}

cmd_make_config() {
    [ $# -eq 1 ] || usage_error "make-config needs one DIR"
    case "$1" in -h|--help) usage; exit 0 ;; -*) usage_error "unknown option $1" ;; esac
    local live repo dir sub lj before after nbefore
    live=$(realpath -m "$CONFIG_HOME")
    repo=$(realpath -m "$SCRIPT_DIR/..")
    dir=$(realpath -m "$1")
    case "$dir" in
        "$live"|"$live"/*) die "refusing $dir: it is inside the live config directory $live" ;;
        "$repo"|"$repo"/*) die "refusing $dir: it is inside the repository $repo" ;;
    esac
    case "$live" in "$dir"/*) die "refusing $dir: it contains the live config directory $live" ;; esac
    case "$repo" in "$dir"/*) die "refusing $dir: it contains the repository $repo" ;; esac
    [ ! -e "$dir" ] || [ -d "$dir" ] || die "refusing $dir: it is not a directory"
    # A directory that cannot be listed counts as not empty.
    if [ -d "$dir" ] && [ ! -f "$dir/$CONFIG_MARKER" ]; then
        local entries
        { [ -r "$dir" ] && [ -x "$dir" ]; } || die "refusing $dir: it cannot be listed"
        entries=$(find "$dir" -mindepth 1 -maxdepth 1 -print -quit) || die "refusing $dir: it cannot be listed"
        [ -z "$entries" ] || die "refusing $dir: it is not empty and make-config did not build it (no $CONFIG_MARKER)"
    fi
    [ -d "$live/gsd-core" ] || die "gsd-core not installed under $live"
    [ -f "$live/gsd-file-manifest.json" ] || die "installer manifest not found under $live"
    [ -f "$live/settings.json" ] || die "no settings.json under $live"
    if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then lj=$live/.claude.json; else lj=$HOME/.claude.json; fi
    [ -f "$lj" ] || die "no $lj to take mcpServers from"

    before=$(tree_hash "$live/gsd-core") || exit 1
    nbefore=$(printf '%s\n' "$before" | wc -l)

    mkdir -p "$dir" || die "cannot create $dir"
    chmod 700 "$dir" || die "cannot chmod $dir"
    [ -f "$dir/$CONFIG_MARKER" ] || printf 'built by routing-probe.sh make-config\n' > "$dir/$CONFIG_MARKER" \
        || die "cannot write $dir/$CONFIG_MARKER"
    # Only the paths named here are replaced; a login already in DIR stays.
    for sub in agents skills hooks gsd-core; do
        rm -rf "${dir:?}/$sub"
        cp -a "$live/$sub" "$dir/$sub" || die "cannot copy $live/$sub"
    done
    cp -a "$live/CLAUDE.md" "$dir/CLAUDE.md" || die "cannot copy CLAUDE.md"
    cp -a "$live/gsd-file-manifest.json" "$dir/gsd-file-manifest.json" || die "cannot copy the manifest"
    copy_installer_scripts "$live" "$dir"
    copy_hook_scripts "$live" "$dir"

    # Live paths in the settings and the MCP servers point into DIR; bus hooks
    # and a mod list from the environment block are dropped, so the mod loads
    # only through --plugin-dir.
    # shellcheck disable=SC2016 # jq program
    local swap_def='def swap:
            if type == "string" then (if . == $live then $dir else (split($live + "/") | join($dir + "/")) end)
            elif type == "array" then map(swap)
            elif type == "object" then map_values(swap)
            else . end;'
    if ! jq --arg live "$live" --arg dir "$dir" "$swap_def"'
        swap
        | if (.hooks | type) == "object" then
              .hooks |= map_values(
                  map(if has("hooks") then .hooks |= map(select((.command // "") | contains("dsmr-bus-watch") | not)) else . end)
                  | map(select((.hooks // [1]) | length > 0)))
          else . end
        | if (.env | type) == "object" then
              (.env |= del(.CLAUDE_CODE_PLUGIN_DIRS)) | (if .env == {} then del(.env) else . end)
          else . end' "$live/settings.json" > "$dir/settings.json.tmp"; then
        rm -f "$dir/settings.json.tmp"; die "cannot build settings.json"
    fi
    mv -f "$dir/settings.json.tmp" "$dir/settings.json" || die "cannot write settings.json"
    if ! jq --arg live "$live" --arg dir "$dir" "$swap_def"'{mcpServers: (.mcpServers // {} | swap)}' "$lj" > "$dir/.claude.json.tmp"; then
        rm -f "$dir/.claude.json.tmp"; die "cannot build .claude.json"
    fi
    mv -f "$dir/.claude.json.tmp" "$dir/.claude.json" || die "cannot write .claude.json"

    pristine_restore "$dir"
    repoint_tree "$dir" "$live" || return 1
    pristine_prove "$dir" "$live" "${PROVEN_PREFIXES[@]}" || return 1
    live_references "$dir" "$live" || { echo "isolation check FAILED: copied files name $live"; return 1; }
    settings_references "$dir" "$live" || { echo "isolation check FAILED: settings name $live"; return 1; }

    after=$(tree_hash "$live/gsd-core") || exit 1
    echo "live gsd-core tree: $nbefore files, listing sha256 $(printf '%s\n' "$before" | sha256sum | cut -d' ' -f1) before"
    echo "live gsd-core tree: $(printf '%s\n' "$after" | wc -l) files, listing sha256 $(printf '%s\n' "$after" | sha256sum | cut -d' ' -f1) after"
    [ "$before" = "$after" ] || { echo "live gsd-core CHANGED"; return 1; }
    echo "live gsd-core identical before and after"
    [ "$(live_gate_present)" -eq 5 ] || { echo "live gate no longer prints five present"; return 1; }
    echo "live gate: five present"
    if [ -e "$dir/.credentials.json" ]; then
        echo "credentials already present in $dir (kept)"
    else
        echo "no credentials in $dir (sign in with CLAUDE_CONFIG_DIR=$dir claude auth login)"
    fi
    echo "config directory ready: $dir"
}

cmd_make_repo() {
    local dir="" gsd="" specialized=true shapes=shell,lisp,mixed,docs exmodel=opus
    while [ $# -gt 0 ]; do
        case "$1" in
            --gsd-core) [ $# -ge 2 ] || usage_error "--gsd-core needs a value"; gsd=$2; shift 2 ;;
            --specialized) [ $# -ge 2 ] || usage_error "--specialized needs a value"; specialized=$2; shift 2 ;;
            --shapes) [ $# -ge 2 ] || usage_error "--shapes needs a value"; shapes=$2; shift 2 ;;
            --executor-model) [ $# -ge 2 ] || usage_error "--executor-model needs a value"; exmodel=$2; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            -*) usage_error "unknown option $1" ;;
            *) [ -z "$dir" ] || usage_error "one DIR only"; dir=$1; shift ;;
        esac
    done
    [ -n "$dir" ] || usage_error "make-repo needs DIR"
    case "$gsd" in global|local-pristine) ;; *) usage_error "--gsd-core takes global or local-pristine" ;; esac
    case "$specialized" in true|false) ;; *) usage_error "--specialized takes true or false" ;; esac
    case "$exmodel" in opus|inherit) ;; *) usage_error "--executor-model takes opus or inherit" ;; esac
    if [ -e "$dir" ] && [ -n "$(ls -A "$dir" 2>/dev/null)" ]; then
        die "$dir exists and is not empty; remove it first"
    fi
    mkdir -p "$dir" || die "cannot create $dir"
    dir=$(cd "$dir" && pwd)

    git -C "$dir" init -q || die "git init failed in $dir"
    write_probe_files "$dir" "$specialized" "$shapes" "$exmodel"
    if [ "$gsd" = local-pristine ]; then
        install_pristine "$dir" || exit 1
    fi

    # The config dir's global excludes keep .claude and the planning directory
    # out of this scratch history; only the probe files are committed.
    git -C "$dir" add scripts src docs Makefile || die "git add failed"
    git -C "$dir" commit -q -m "Add probe files" || die "git commit failed"
    echo "probe repository ready: $dir"
}

# --- run ---------------------------------------------------------------------

# collect_unsets: UNSET_ARGS holds an `env -u NAME` pair for every inherited
# variable that would let a probe reach the calling session, the coordination
# bus or the attached Lisp image.
collect_unsets() {
    local name
    UNSET_ARGS=()
    while IFS= read -r name; do
        case "$name" in
            DSMR_*|CLAUDECODE|CLAUDE_CODE_*|CLAUDE_PID|CLAUDE_EFFORT|CLAUDE_CONFIG_DIR|SUBAGENT_ROUTING_CAPTURE)
                UNSET_ARGS+=(-u "$name") ;;
        esac
    done < <(compgen -e)
}

cmd_run() {
    local repo="" sid="" config="" plugin="" capture="" debug="" system="" prompt="" have_prompt=0
    local model=$PROBE_MODEL extra=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --session-id) [ $# -ge 2 ] || usage_error "--session-id needs a value"; sid=$2; shift 2 ;;
            --config-dir) [ $# -ge 2 ] || usage_error "--config-dir needs a value"; config=$2; shift 2 ;;
            --plugin-dir) [ $# -ge 2 ] || usage_error "--plugin-dir needs a value"; plugin=$2; shift 2 ;;
            --capture) [ $# -ge 2 ] || usage_error "--capture needs a value"; capture=$2; shift 2 ;;
            --debug-file) [ $# -ge 2 ] || usage_error "--debug-file needs a value"; debug=$2; shift 2 ;;
            --append-system-prompt) [ $# -ge 2 ] || usage_error "--append-system-prompt needs a value"; system=$2; shift 2 ;;
            --model) [ $# -ge 2 ] || usage_error "--model needs a value"; model=$2; shift 2 ;;
            --env)
                [ $# -ge 2 ] || usage_error "--env needs KEY=VAL"
                [[ $2 =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || usage_error "--env takes KEY=VAL"
                case "$2" in DSMR_*) usage_error "--env refuses DSMR_ variables" ;; esac
                extra+=("$2"); shift 2 ;;
            --dangerously-skip-permissions|--allow-dangerously-skip-permissions|--permission-mode)
                usage_error "$1 is refused: probes run in auto permission mode" ;;
            --) shift; [ $# -eq 1 ] || usage_error "one PROMPT after --"; prompt=$1; have_prompt=1; shift ;;
            -h|--help) usage; exit 0 ;;
            -*) usage_error "unknown option $1" ;;
            *) [ -z "$repo" ] || usage_error "one REPO only"; repo=$1; shift ;;
        esac
    done
    [ -n "$repo" ] && [ -n "$sid" ] && [ "$have_prompt" -eq 1 ] || usage_error "run needs REPO, --session-id and -- PROMPT"
    [[ $sid =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || usage_error "--session-id must be a lowercase UUID"
    [ -d "$repo" ] || die "no such repository: $repo"
    repo=$(cd "$repo" && pwd)

    # Paths given relative to the caller are made absolute before the cd.
    [ -z "$config" ] || config=$(realpath -m "$config")
    [ -z "$plugin" ] || plugin=$(realpath -m "$plugin")
    [ -z "$capture" ] || { capture=$(realpath -m "$capture"); mkdir -p "$capture" || die "cannot create $capture"; }
    [ -n "$debug" ] || debug=${XDG_CACHE_HOME:-$HOME/.cache}/dsmr-routing-probes/$sid.debug.log
    debug=$(realpath -m "$debug")
    mkdir -p "$(dirname "$debug")" || die "cannot create $(dirname "$debug")"

    # A probe is its own session: nothing of the calling session, the
    # coordination bus or a mod list reaches it except what the flags give.
    collect_unsets
    local set_args=("${extra[@]}")
    [ -z "$config" ] || set_args+=("CLAUDE_CONFIG_DIR=$config")
    [ -z "$capture" ] || set_args+=("SUBAGENT_ROUTING_CAPTURE=$capture")

    local claude_args=(-p --session-id "$sid" --permission-mode auto --model "$model" --debug-file "$debug")
    [ -z "$plugin" ] || claude_args+=(--plugin-dir "$plugin")
    [ -z "$system" ] || claude_args+=(--append-system-prompt "$system")

    local rc
    (cd "$repo" && env "${UNSET_ARGS[@]}" "${set_args[@]}" timeout "$PROBE_TIMEOUT" claude "${claude_args[@]}" "$prompt")
    rc=$?
    echo "claude exit $rc" >&2
    echo "debug log: $debug" >&2

    local home=${config:-$HOME/.claude} found
    found=$(compgen -G "$home/projects/*/$sid.jsonl" | head -n 1)
    [ -n "$found" ] || die "no transcript for session $sid under $home/projects"
    printf '%s\n' "$found"
    return "$rc"
}

# --- report ------------------------------------------------------------------

# frontmatter_files FILE: the files_modified entries of FILE's frontmatter,
# one per line, from a block list or an inline list.
frontmatter_files() {
    awk 'NR == 1 { if ($0 !~ /^---[[:space:]]*$/) exit; next }
         /^---[[:space:]]*$/ { exit }
         /^files_modified:/ {
             line = $0; sub(/^files_modified:[[:space:]]*/, "", line)
             if (line ~ /^\[/) {
                 gsub(/\[|\]|"|\047/, "", line)
                 n = split(line, a, /,[[:space:]]*/)
                 for (i = 1; i <= n; i++) if (a[i] != "") print a[i]
             } else inlist = 1
             next }
         inlist && /^[[:space:]]+-[[:space:]]/ {
             s = $0; sub(/^[[:space:]]+-[[:space:]]+/, "", s); sub(/[[:space:]]+#.*$/, "", s)
             gsub(/^"|"$|^\047|\047$/, "", s); print s; next }
         inlist && /^[^[:space:]]/ { inlist = 0 }' "$1"
}

# is_probe_file NAME: whether NAME is one of the probe files.
is_probe_file() {
    local f
    for f in "${PROBE_FILES[@]}"; do [ "$f" = "$1" ] && return 0; done
    return 1
}

# call_target PROMPT CWD: print "TARGET<TAB>HINT" for an executor dispatch: the
# probe files its plan modifies (joined with +) and the plan's agent_hint, or
# the files a "Fix finding" prompt lists. Each is "-" when unknown.
call_target() {
    local prompt=$1 cwd=$2 plan resolved f from to listed item
    local -a found=() items=()
    local target=- hint=-
    if [ "${prompt#Fix finding }" != "$prompt" ]; then
        listed=$(printf '%s\n' "$prompt" | sed -n 's/.*Files: \(.*\)\. Make the minimal change.*/\1/p' | head -n 1)
        IFS=', ' read -ra items <<<"$listed"
        for item in "${items[@]}"; do
            [ -n "$item" ] && found+=("$item")
        done
    else
        while IFS= read -r plan; do
            [ -n "$plan" ] || continue
            resolved=$(resolve_plan "$plan" "$cwd" "$prompt")
            if [ -n "${ROUTING_PROBE_PATH_MAP:-}" ]; then
                from=${ROUTING_PROBE_PATH_MAP%%=*}
                to=${ROUTING_PROBE_PATH_MAP#*=}
                [ "${resolved#"$from"}" = "$resolved" ] || resolved=$to${resolved#"$from"}
            fi
            [ -f "$resolved" ] || continue
            while IFS= read -r f; do
                is_probe_file "$f" && found+=("$f")
            done < <(frontmatter_files "$resolved")
            hint=$(frontmatter_hint "$resolved")
            [ -n "$hint" ] || hint=-
            break
        done < <(printf '%s\n' "$prompt" | grep -oE "[^[:space:]\`'\"()<>]+-PLAN\.md")
    fi
    if [ "${#found[@]}" -gt 0 ]; then
        target=$(IFS=+; printf '%s' "${found[*]}")
    fi
    printf '%s\t%s\n' "$target" "$hint"
}

cmd_report() {
    [ $# -eq 1 ] || usage_error "report needs one TRANSCRIPT"
    local transcript=$1
    [ -f "$transcript" ] || die "no such transcript: $transcript"
    local session_dir=${transcript%.jsonl}
    local sid=${session_dir##*/}
    local config
    config=$(cd "$(dirname "$transcript")/../.." && pwd)
    local modlog=$config/$LOG_DIR/$sid.jsonl
    local subdir=$session_dir/subagents

    local files=("$transcript") f
    if [ -d "$subdir" ]; then
        for f in "$subdir"/*.jsonl; do [ -f "$f" ] && files+=("$f"); done
    fi

    # tool_use id -> agent type and transcript, from each subagent's meta.json.
    declare -A ran_type=() ran_file=()
    local id type file
    if [ -d "$subdir" ]; then
        while IFS=$'\t' read -r id type file; do
            [ -n "$id" ] || continue
            ran_type[$id]=$type
            ran_file[$id]=${file%.meta.json}.jsonl
        done < <(for f in "$subdir"/*.meta.json; do
                     [ -f "$f" ] && jq -r --arg f "$f" '[.toolUseId // "", .agentType // "-", $f] | @tsv' "$f"
                 done)
    fi

    # tool_use id -> logged action and type, the last line for each id.
    declare -A log_action=() log_type=()
    local action
    if [ -f "$modlog" ]; then
        while IFS=$'\t' read -r id action type; do
            log_action[$id]=$action
            log_type[$id]=$type
        done < <(jq -r 'select(.toolUseId != null) | [.toolUseId, .action, (.set.type // "-")] | @tsv' "$modlog")
    fi

    printf 'tool_use_id\trequested_type\trequested_model\tran_type\tran_models\ttokens\tlogged_action\tlogged_type\tlog_agrees\ttarget\tplan_hint\tagent_id\n'
    local req_type req_model models tokens agent agrees la lt rt pb cb prompt cwd tt target hint
    while IFS=$'\t' read -r id req_type req_model pb cb; do
        rt=${ran_type[$id]:--}
        models=- tokens=- agent=-
        file=${ran_file[$id]:-}
        if [ -n "$file" ] && [ -f "$file" ]; then
            agent=${file##*/agent-}; agent=${agent%.jsonl}
            # One API message spans several records; count each message id once.
            IFS='|' read -r models tokens < <(jq -rs '
                [ .[] | select(.type == "assistant" and .message.id != null) ]
                | unique_by(.message.id) as $m
                | [ ($m | map(.message.model) | map(select(. != null and . != "<synthetic>"))
                       | group_by(.) | map("\(.[0]):\(length)") | join(",")),
                    ($m | map(.message.usage // {}
                              | (.input_tokens // 0) + (.output_tokens // 0)
                                + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0))
                        | add // 0) ]
                | map(tostring) | join("|")' "$file")
            [ -n "$models" ] || models=-
        fi
        la=${log_action[$id]:--}
        lt=${log_type[$id]:--}
        if [ "$la" = - ]; then agrees=-
        elif [ "$lt" = "$rt" ]; then agrees=yes
        else agrees=no
        fi
        target=- hint=-
        prompt=$(printf '%s' "${pb#x}" | base64 -d)
        cwd=$(printf '%s' "${cb#x}" | base64 -d)
        if case "$EXECUTOR_TYPES" in *" $req_type "*) true ;; *) false ;; esac \
            || [ "${prompt#Fix finding }" != "$prompt" ]; then
            tt=$(call_target "$prompt" "$cwd")
            target=${tt%%$'\t'*}
            hint=${tt#*$'\t'}
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$id" "$req_type" "$req_model" "$rt" "$models" "$tokens" "$la" "$lt" "$agrees" "$target" "$hint" "$agent"
    done < <(jq -r 'select(.type == "assistant") | (.cwd // "") as $cwd | .message.content[]?
                    | select(.type == "tool_use" and (.name == "Agent" or .name == "Task"))
                    | [.id, (.input.subagent_type // "-"), (.input.model // "-"),
                       ("x" + ((.input.prompt // "") | @base64)), ("x" + ($cwd | @base64))] | @tsv' "${files[@]}" \
             | awk -F'\t' '!seen[$1]++')
}

# --- ledger-row --------------------------------------------------------------

# ledger_body FILE...: one TSV row per transcript. Records of one API message
# repeat its usage once per content block, so each field is summed once per
# distinct message id. Synthetic records are not API messages and are left out.
# A line that does not parse (a session killed mid-write) is skipped and
# counted on stderr; a file that cannot be read is fatal.
ledger_body() {
    local - f torn
    set -o pipefail
    for f in "$@"; do
        [ -f "$f" ] || die "no such transcript: $f"
        [ -r "$f" ] || die "cannot read $f"
        torn=$(jq -nR '[inputs | try (fromjson | 0) catch 1] | add // 0' "$f") || die "cannot read $f"
        [ "$torn" -eq 0 ] || echo "$PROGNAME: $f: skipped $torn unparsable lines" >&2
        jq -R 'fromjson? // empty' "$f" | jq -rs --arg p "$f" '
            [ .[] | select(.type == "assistant" and .message.id != null
                           and .message.model != "<synthetic>") ]
            | unique_by(.message.id) as $m
            | def sum(k): $m | map(.message.usage[k] // 0) | add // 0;
              [ $p, ($m | length), sum("cache_read_input_tokens"),
                sum("cache_creation_input_tokens"), sum("output_tokens"),
                (($m | map(.message.model // "unknown") | group_by(.)
                  | map("\(.[0]):\(length)") | join(",")) | if . == "" then "-" else . end) ]
            | map(tostring) | @tsv' || die "cannot read $f"
    done
}

cmd_ledger_row() {
    [ $# -ge 1 ] || usage_error "ledger-row needs at least one TRANSCRIPT"
    printf 'path\tturns\tcache_read\tcache_write\toutput\tmodels\n'
    ledger_body "$@"
}

# session_files TRANSCRIPT: the transcript and every subagent transcript of its session.
session_files() {
    local t=$1 f
    printf '%s\n' "$t"
    for f in "${t%.jsonl}"/subagents/agent-*.jsonl; do [ -f "$f" ] && printf '%s\n' "$f"; done
    return 0
}

# session_cache_read TRANSCRIPT: cache-read tokens summed over the session's
# transcripts, one count per message id. Fails, printing nothing, when any
# transcript cannot be read.
session_cache_read() {
    local - total
    local -a files
    set -o pipefail
    mapfile -t files < <(session_files "$1")
    total=$(ledger_body "${files[@]}" | awk -F'\t' '{ s += $3 } END { print s + 0 }') || return 1
    [[ $total =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$total"
}

# cap-check TRANSCRIPT: prints cache_read, the cap and over or under; exits 3
# when over, or when the session cannot be totalled (printed as unknown, over).
cmd_cap_check() {
    [ $# -eq 1 ] || usage_error "cap-check needs one TRANSCRIPT"
    local total
    if ! total=$(session_cache_read "$1"); then
        echo "$PROGNAME: cannot total the cache reads of $1; treated as over the cap" >&2
        printf 'unknown\t%s\tover\n' "$CACHE_READ_CAP"
        return 3
    fi
    if [ "$total" -gt "$CACHE_READ_CAP" ]; then
        printf '%s\t%s\tover\n' "$total" "$CACHE_READ_CAP"
        return 3
    fi
    printf '%s\t%s\tunder\n' "$total" "$CACHE_READ_CAP"
}

# --- check -------------------------------------------------------------------

# norm_target LIST: a + joined target with its items sorted, so the order a
# plan or finding lists its files in does not matter.
norm_target() {
    printf '%s\n' "$1" | tr '+' '\n' | LC_ALL=C sort | paste -sd+
}

# model_in_family MODELS FAMILY: whether every model in a model:count list
# starts with FAMILY.
model_in_family() {
    local models=$1 family=$2 m
    local -a list
    [ "$models" != - ] || return 1
    IFS=, read -ra list <<<"$models"
    for m in "${list[@]}"; do
        [ "${m#"$family"}" != "$m" ] || return 1
    done
}

# model_matches_alias MODELS ALIAS: whether every model in the list names ALIAS.
model_matches_alias() {
    local models=$1 alias=$2 m
    local -a list
    [ "$models" != - ] || return 1
    IFS=, read -ra list <<<"$models"
    for m in "${list[@]}"; do
        case "${m%:*}" in *"$alias"*) ;; *) return 1 ;; esac
    done
}

cmd_check() {
    local arm="" expected="" dropped=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --dropped) [ $# -ge 2 ] || usage_error "--dropped needs a value"; dropped=$2; shift 2 ;;
            -*) usage_error "unknown option $1" ;;
            *)
                if [ -z "$arm" ]; then arm=$1
                elif [ -z "$expected" ]; then expected=$1
                else usage_error "check takes ARM and EXPECTED_TSV only"
                fi
                shift ;;
        esac
    done
    [ -n "$expected" ] || usage_error "check needs ARM and EXPECTED_TSV"
    [[ $arm =~ ^[a-z0-9][a-z0-9-]*$ ]] || usage_error "ARM is a lowercase name"
    [ -f "$expected" ] || die "no such file: $expected"
    local ev
    ev=$(cd "$(dirname "$expected")" && pwd)
    [ -f "$ev/sessions.tsv" ] || die "no sessions.tsv beside $expected"

    local -a e_path=() e_target=() e_hint=() e_type=() e_family=() e_req=()
    local -a hits=() r_type=() r_models=() r_hint=() r_req=()
    local n=0 p t h rt fam req i
    while IFS=$'\t' read -r p t h rt fam req; do
        case "$p" in ''|'#'*|path) continue ;; esac
        e_path[n]=$p; e_target[n]=$(norm_target "$t"); e_hint[n]=$h
        e_type[n]=$rt; e_family[n]=$fam; e_req[n]=${req:--}
        hits[n]=0
        n=$((n + 1))
    done < "$expected"
    [ "$n" -gt 0 ] || die "no expected cells in $expected"

    local fail=0 sid path tag transcript rest report
    local id rq rmodel ran models tokens la lt agrees target hint agent nt alias matched
    while IFS=$'\t' read -r sid path tag transcript rest; do
        case "$sid" in ''|session_id) continue ;; esac
        report=$ev/report-$tag.tsv
        if [ ! -f "$report" ]; then
            echo "FAIL $path: no report-$tag.tsv for session $sid"
            fail=1
            continue
        fi
        while IFS=$'\t' read -r id rq rmodel ran models tokens la lt agrees target hint agent; do
            [ "$id" != tool_use_id ] || continue
            if [ "$la" != - ] && [ "$agrees" != yes ]; then
                echo "FAIL $path $id: mod logged $lt, transcript shows $ran"
                fail=1
            fi
            case "$EXECUTOR_TYPES" in
                *" $rq "*)
                    nt=$(norm_target "$target")
                    matched=-1
                    for ((i = 0; i < n; i++)); do
                        if [ "${e_path[i]}" = "$path" ] && [ "${e_target[i]}" = "$nt" ]; then matched=$i; break; fi
                    done
                    if [ "$matched" -lt 0 ]; then
                        echo "recorded $path $target requested=$rq ran=$ran models=$models"
                        continue
                    fi
                    hits[matched]=$((hits[matched] + 1))
                    r_type[matched]=$ran; r_models[matched]=$models; r_hint[matched]=$hint
                    r_req[matched]=$rq
                    ;;
                *)
                    if [ "$ran" != "$rq" ]; then
                        echo "FAIL $path $id: requested $rq, ran $ran"
                        fail=1
                    fi
                    case "$rmodel" in
                        sonnet|opus|haiku)
                            alias=$rmodel
                            if ! model_matches_alias "$models" "$alias"; then
                                echo "FAIL $path $id: requested model $rmodel, ran $models"
                                fail=1
                            fi ;;
                    esac
                    ;;
            esac
        done < "$report"
    done < "$ev/sessions.tsv"

    local want_type want_family verdict reason
    for ((i = 0; i < n; i++)); do
        if [ "${hits[i]}" -eq 0 ] && [[ ",$dropped," == *",${e_path[i]},"* ]]; then
            echo "dropped-by-ruling ${e_path[i]} ${e_target[i]}"
            continue
        fi
        if [ "${hits[i]}" -eq 0 ]; then
            echo "FAIL ${e_path[i]} ${e_target[i]}: no matching executor row"
            fail=1
            continue
        fi
        if [ "${hits[i]}" -gt 1 ]; then
            echo "FAIL ${e_path[i]} ${e_target[i]}: ${hits[i]} executor rows match, expected one"
            fail=1
            continue
        fi
        want_type=${e_type[i]} want_family=${e_family[i]} verdict=ok reason=""
        if [ "${r_hint[i]}" != "${e_hint[i]}" ]; then
            verdict=planner-deviation
            case "${r_hint[i]}" in
                shell-developer) want_type=shell-developer want_family=claude-sonnet ;;
                -) want_type=lisp-developer want_family=claude-opus ;;
                *) verdict=FAIL reason="plan hint ${r_hint[i]} has no routing rule in this table" ;;
            esac
        fi
        if [ "$verdict" != FAIL ]; then
            if [ "${r_type[i]}" != "$want_type" ]; then
                verdict=FAIL reason="ran ${r_type[i]}, expected $want_type"
            elif ! model_in_family "${r_models[i]}" "$want_family"; then
                verdict=FAIL reason="models ${r_models[i]} are not in $want_family"
            elif [ "${e_req[i]}" != - ] && [ "${r_req[i]}" != "${e_req[i]}" ]; then
                verdict=FAIL reason="requested ${r_req[i]}, expected ${e_req[i]}"
            fi
        fi
        [ "$verdict" != FAIL ] || fail=1
        printf '%s %s %s: requested=%s hint=%s ran=%s models=%s%s\n' \
            "$verdict" "${e_path[i]}" "${e_target[i]}" "${r_req[i]}" "${r_hint[i]}" \
            "${r_type[i]}" "${r_models[i]}" "${reason:+ ($reason)}"
    done
    echo "arm $arm: $n expected cells, status $([ "$fail" -eq 0 ] && echo pass || echo FAIL)"
    return "$fail"
}

# --- bus-silent --------------------------------------------------------------

cmd_bus_silent() {
    [ $# -eq 1 ] || usage_error "bus-silent needs ROOT"
    local root=$1 bus=${XDG_STATE_HOME:-$HOME/.local/state}/dsmr-mcp/bus found
    [ -d "$bus" ] || die "no bus state directory: $bus"
    found=$(grep -rlaF -- "$root" "$bus")
    if [ -n "$found" ]; then
        printf '%s\n' "$found"
        return 1
    fi
    return 0
}

# --- run-arm -----------------------------------------------------------------

# bus_precondition REPO: whether a bus watcher started in REPO, with the bus
# variables removed, refuses for want of an identity (exit 2).
bus_precondition() {
    local rc
    collect_unsets
    (cd "$1" && env "${UNSET_ARGS[@]}" dsmr-bus-watch --wake --wake-seconds 1) >/dev/null 2>&1
    rc=$?
    [ "$rc" -eq 2 ]
}

# arm_selected PATH SHAPE ONLY...: whether a cell is named by --only (all are when none is).
arm_selected() {
    local path=$1 shape=$2 spec
    shift 2
    [ $# -gt 0 ] || return 0
    for spec in "$@"; do
        [ -n "$spec" ] || continue
        if [ "${spec%%:*}" = "$path" ]; then
            [ "$spec" = "$path" ] && return 0
            [ "${spec#*:}" = "$shape" ] && return 0
            [ "$path" != quick ] && return 0
        fi
    done
    return 1
}

cmd_run_arm() {
    local arm="" gsd="" evidence="" config="" plugin="" exmodel=opus capture="" only="" envs=() orch=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --gsd-core) [ $# -ge 2 ] || usage_error "--gsd-core needs a value"; gsd=$2; shift 2 ;;
            --evidence) [ $# -ge 2 ] || usage_error "--evidence needs a value"; evidence=$2; shift 2 ;;
            --config-dir) [ $# -ge 2 ] || usage_error "--config-dir needs a value"; config=$2; shift 2 ;;
            --plugin-dir) [ $# -ge 2 ] || usage_error "--plugin-dir needs a value"; plugin=$2; shift 2 ;;
            --executor-model) [ $# -ge 2 ] || usage_error "--executor-model needs a value"; exmodel=$2; shift 2 ;;
            --capture) [ $# -ge 2 ] || usage_error "--capture needs a value"; capture=$2; shift 2 ;;
            --orchestrator-model) [ $# -ge 2 ] || usage_error "--orchestrator-model needs a value"; orch=$2; shift 2 ;;
            --only) [ $# -ge 2 ] || usage_error "--only needs a value"; only=$2; shift 2 ;;
            --env) [ $# -ge 2 ] || usage_error "--env needs KEY=VAL"; envs+=(--env "$2"); shift 2 ;;
            -h|--help) usage; exit 0 ;;
            -*) usage_error "unknown option $1" ;;
            *) [ -z "$arm" ] || usage_error "one ARM only"; arm=$1; shift ;;
        esac
    done
    [[ $arm =~ ^[a-z0-9][a-z0-9-]*$ ]] || usage_error "run-arm needs a lowercase ARM name"
    case "$gsd" in global|local-pristine) ;; *) usage_error "--gsd-core takes global or local-pristine" ;; esac
    [ -n "$evidence" ] || usage_error "run-arm needs --evidence DIR"
    command -v dsmr-bus-watch >/dev/null || die "dsmr-bus-watch is not on PATH: cannot assert the bus precondition"
    command -v claude >/dev/null || die "claude is not on PATH"

    [ "$plugin" != none ] || plugin=""
    local -a run_extra=()
    [ -z "$config" ] || run_extra+=(--config-dir "$config")
    [ -z "$plugin" ] || run_extra+=(--plugin-dir "$plugin")
    [ -z "$capture" ] || run_extra+=(--capture "$capture")
    run_extra+=("${envs[@]}")
    local home=${config:-$CONFIG_HOME}

    local ev
    mkdir -p "$evidence/mod-log" || die "cannot create $evidence"
    ev=$(cd "$evidence" && pwd)
    local cache=${XDG_CACHE_HOME:-$HOME/.cache}/dsmr-routing-probes/$arm
    [ -f "$ev/sessions.tsv" ] || printf 'session_id\tpath\ttag\ttranscript\tstart\tend\ttokens\tnotes\tmodel\n' > "$ev/sessions.tsv"
    [ -f "$ev/tokens.txt" ] || printf 'tag\tcell\ttranscript\tturns\tcache_read\tcache_write\toutput\tmodels\n' > "$ev/tokens.txt"

    local -a only_list=() cells=(execute-phase: quick:shell quick:lisp quick:mixed quick:docs quick-batch: audit-fix: execute-phase-leader:)
    IFS=, read -ra only_list <<<"$only"
    local -A built=()
    local cell path shape tag repo sid prompt model transcript start end rc total cache_read subdir item
    local -a ledger_files
    for cell in "${cells[@]}"; do
        path=${cell%%:*}; shape=${cell#*:}
        arm_selected "$path" "$shape" "${only_list[@]}" || continue
        tag=$path${shape:+-$shape}
        repo=$cache/$path/repo

        if [ -z "${built[$path]:-}" ]; then
            [ ! -e "$repo" ] || die "$repo exists; move it aside before this cell runs again"
            (
                case "$path" in
                    execute-phase-leader)
                        cmd_make_repo "$repo" --gsd-core "$gsd" --specialized false --shapes lisp --executor-model "$exmodel" ;;
                    audit-fix)
                        cmd_make_repo "$repo" --gsd-core "$gsd" --shapes "" --executor-model "$exmodel" ;;
                    *)
                        cmd_make_repo "$repo" --gsd-core "$gsd" --executor-model "$exmodel" ;;
                esac
            ) > "$ev/make-repo-$path.txt" 2>&1 || die "make-repo failed for $path; see $ev/make-repo-$path.txt"
            built[$path]=1
        fi
        bus_precondition "$repo" || die "bus precondition failed in $repo: a bus watcher did not refuse"

        model=$PROBE_MODEL
        case "$path" in
            execute-phase|execute-phase-leader) prompt='/gsd-execute-phase 1' ;;
            quick) prompt="/gsd-quick $(cmd_describe "$shape")" ;;
            quick-batch)
                prompt='/gsd-quick-batch'
                for item in "${SHAPES[@]}"; do prompt+=$'\n'"- $(cmd_describe "$item")"; done ;;
            audit-fix) prompt='/gsd-audit-fix --source audit-uat --severity all --max 4' ;;
        esac
        [ "$path" != execute-phase-leader ] || model=$LEADER_MODEL
        [ -z "$orch" ] || model=$orch

        sid=$(cat /proc/sys/kernel/random/uuid)
        start=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        transcript=$(cmd_run "$repo" --session-id "$sid" --model "$model" "${run_extra[@]}" \
            --debug-file "$ev/debug-$tag.log" -- "$prompt" 2> "$ev/probe-$tag.err")
        rc=$?
        end=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        printf '%s\n' "$transcript" > "$ev/probe-$tag.out"
        transcript=$(printf '%s\n' "$transcript" | tail -n 1)
        if [ ! -f "$transcript" ]; then
            printf '%s\t%s\t%s\t-\t%s\t%s\t0\tno transcript, claude exit %s\t%s\n' "$sid" "$path" "$tag" "$start" "$end" "$rc" "$model" >> "$ev/sessions.tsv"
            die "$tag: no transcript (claude exit $rc); see $ev/probe-$tag.err"
        fi
        [ ! -f "$home/$LOG_DIR/$sid.jsonl" ] || cp "$home/$LOG_DIR/$sid.jsonl" "$ev/mod-log/$tag.jsonl"
        cmd_report "$transcript" > "$ev/report-$tag.tsv" || die "$tag: report failed"
        subdir=${transcript%.jsonl}/subagents
        ledger_files=("$transcript")
        for item in "$subdir"/agent-*.jsonl; do [ -f "$item" ] && ledger_files+=("$item"); done
        ledger_body "${ledger_files[@]}" | sed "s/^/$tag\t$path\t/" >> "$ev/tokens.txt"
        total=$(awk -F'\t' 'NR > 1 && $6 ~ /^[0-9]+$/ { s += $6 } END { print s + 0 }' "$ev/report-$tag.tsv")
        if ! cache_read=$(session_cache_read "$transcript"); then
            echo "$PROGNAME: $tag: cannot total its cache reads, so it may be over the $CACHE_READ_CAP cap; arm stopped" >&2
            return 3
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\tclaude exit %s\t%s\n' "$sid" "$path" "$tag" "$transcript" "$start" "$end" "$total" "$rc" "$model" >> "$ev/sessions.tsv"
        echo "$tag: session $sid, subagent tokens $total, cache read $cache_read, claude exit $rc"
        if [ "$cache_read" -gt "$CACHE_READ_CAP" ]; then
            echo "$PROGNAME: $tag read $cache_read cached tokens, over the $CACHE_READ_CAP cap; arm stopped" >&2
            return 3
        fi
    done
}

# --- replay ------------------------------------------------------------------

cmd_replay() {
    local recordings="" mod=$SCRIPT_DIR/../harness/mods/subagent-routing
    while [ $# -gt 0 ]; do
        case "$1" in
            --mod) [ $# -ge 2 ] || usage_error "--mod needs a value"; mod=$2; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            -*) usage_error "unknown option $1" ;;
            *) [ -z "$recordings" ] || usage_error "one RECORDINGS_DIR only"; recordings=$1; shift ;;
        esac
    done
    [ -n "$recordings" ] || usage_error "replay needs RECORDINGS_DIR"
    [ -d "$recordings" ] || usage_error "no such directory: $recordings"
    local files=() f
    for f in "$recordings"/*.json; do [ -f "$f" ] && files+=("$f"); done
    [ "${#files[@]}" -gt 0 ] || usage_error "no recordings in $recordings"
    [ -f "$mod/.claude-plugin/plugin.json" ] || die "not a mod folder: $mod"

    # Recordings hold dispatch prompts: they are copied only into a temporary
    # copy of the mod, never into the mod's own folder.
    local work
    work=$(mktemp -d) || die "mktemp failed"
    # shellcheck disable=SC2064 # expand $work now: the trap runs after it leaves scope
    trap "rm -rf '$work'" EXIT
    cp -a "$mod/." "$work/" || die "cannot copy $mod"
    rm -rf "$work/.claude-plugin/types"
    jq -s . "${files[@]}" | { printf 'export default '; cat; printf '\n'; } > "$work/test/recordings.ts" \
        || die "cannot read the recordings"
    printf "import recordings from './recordings'\nimport { replay } from './replay'\nreplay(recordings)\n" \
        > "$work/test/replay.test.ts"

    local rc
    claude plugin test "$work"
    rc=$?
    echo "replayed ${#files[@]} recordings"
    return "$rc"
}

# --- record-history ----------------------------------------------------------

# resolve_plan PATH CWD PROMPT: absolute form of a plan path as the mod's
# decision resolves it; prints nothing for a tilde path when HOME is unset.
resolve_plan() {
    local path=$1 cwd=${2%/} prompt=$3 root rest
    # shellcheck disable=SC2016 # the literal variable reference a dispatch prompt carries
    case "$path" in
        '${PROJECT_ROOT}/'*|'$PROJECT_ROOT/'*)
            rest=/${path#*/}
            root=$(printf '%s\n' "$prompt" \
                   | sed -n "s/^[[:space:]]*PROJECT_ROOT=['\"]\{0,1\}\(\/[^'\"[:space:]]*\)['\"]\{0,1\}[[:space:]]*\$/\1/p" \
                   | head -n 1)
            path=${root:-$cwd}
            path=${path%/}$rest
            ;;
    esac
    case "$path" in
        /*) printf '%s\n' "$path" ;;
        \~/*) [ -n "${HOME:-}" ] && printf '%s\n' "${HOME%/}${path#\~}" ;;
        *) while [ "${path#./}" != "$path" ]; do path=${path#./}; done
           printf '%s/%s\n' "$cwd" "$path" ;;
    esac
}

# frontmatter_hint FILE: the agent_hint value in FILE's frontmatter, unquoted.
frontmatter_hint() {
    awk 'NR == 1 { if ($0 !~ /^---[[:space:]]*$/) exit; next }
         /^---[[:space:]]*$/ { exit }
         /^agent_hint:/ { sub(/^agent_hint:[[:space:]]*/, ""); sub(/[[:space:]]+#.*$/, "");
                          gsub(/^["'\'']|["'\'']$/, ""); print; exit }' "$1"
}

# tape_read PATH: one fs.read tape entry; the result is null for a missing file.
tape_read() {
    if [ -f "$1" ] && [ -r "$1" ]; then
        jq -n --arg p "$1" --rawfile t "$1" '{op: "fs.read", arg: $p, result: $t}'
    else
        jq -n --arg p "$1" '{op: "fs.read", arg: $p, result: null}'
    fi
}

tape_exists() {
    local found=false
    [ -e "$1" ] && found=true
    jq -n --arg p "$1" --argjson f "$found" '{op: "fs.exists", arg: $p, result: $f}'
}

# record_one TRANSCRIPT CALL OUTDIR CAPTURED: write OUTDIR/<tool_use_id>.json.
record_one() {
    local transcript=$1 call=$2 out=$3 captured=$4
    local id cwd prompt sid config_home config_file plan resolved hint name meta
    local entries=() names=(gsd-executor shell-developer lisp-developer) seen=" "
    id=$(jq -r .id <<<"$call")
    [[ $id =~ ^[A-Za-z0-9_-]+$ ]] || { echo "skipping unsafe id $id" >&2; return 0; }
    cwd=$(jq -r '.cwd // ""' <<<"$call")
    cwd=${cwd%/}
    prompt=$(jq -r .prompt <<<"$call")
    sid=$(jq -r '.session // ""' <<<"$call")
    [ -n "$sid" ] || { sid=${transcript##*/}; sid=${sid%.jsonl}; }
    # The tape answers CLAUDE_CONFIG_DIR unset, so the decision reads $HOME/.claude.
    config_home=${HOME%/}/.claude

    entries+=("$(jq -n --arg h "${HOME:-}" '{op: "env.get", arg: "CLAUDE_CONFIG_DIR", result: null},
                                           {op: "env.get", arg: "HOME", result: $h}')")
    entries+=("$(jq -n --arg c "$cwd" '{op: "session.cwd", arg: "", result: $c}')")
    entries+=("$(jq -n --arg s "$sid" '{op: "session.id", arg: "", result: $s}')")

    config_file=$cwd/$PLANNING_DIR/config.json
    entries+=("$(tape_read "$config_file")")
    if [ -f "$config_file" ]; then
        name=$(jq -r '.planning.agents.executor // "" | strings' "$config_file" 2>/dev/null)
        [ -n "$name" ] && names+=("$name")
    fi

    while IFS= read -r plan; do
        [ -n "$plan" ] || continue
        resolved=$(resolve_plan "$plan" "$cwd" "$prompt")
        [ -n "$resolved" ] || continue
        case "$seen" in *" $resolved "*) continue ;; esac
        seen="$seen$resolved "
        entries+=("$(tape_read "$resolved")")
        if [ -f "$resolved" ]; then
            hint=$(frontmatter_hint "$resolved")
            [ -n "$hint" ] && names+=("$hint")
        fi
    done < <(printf '%s\n' "$prompt" | grep -oE "[^[:space:]\`'\"()<>]+-PLAN\.md")

    seen=" "
    for name in "${names[@]}"; do
        [[ $name =~ ^[a-z0-9][a-z0-9-]*$ ]] || continue
        case "$seen" in *" $name "*) continue ;; esac
        seen="$seen$name "
        entries+=("$(tape_exists "$config_home/agents/$name.md")")
        entries+=("$(tape_exists "$cwd/.claude/agents/$name.md")")
    done

    # What ran, from the subagent's own records, when they are still on disk.
    local truth=null subdir=${transcript%.jsonl}/subagents f
    if [ -d "$subdir" ]; then
        for f in "$subdir"/*.meta.json; do
            [ -f "$f" ] || continue
            [ "$(jq -r '.toolUseId // ""' "$f")" = "$id" ] || continue
            meta=$f
            truth=$(jq -n --arg type "$(jq -r '.agentType // ""' "$meta")" \
                --argjson models "$(jq -s '[ .[] | select(.type == "assistant" and .message.id != null) ]
                    | unique_by(.message.id) | map(.message.model)
                    | map(select(. != null and . != "<synthetic>")) | unique' "${meta%.meta.json}.jsonl" 2>/dev/null || echo null)" \
                '{ranType: $type, ranModels: $models}')
            break
        done
    fi

    local previous=null dest=$out/$id.json
    [ -f "$dest" ] && previous=$(jq '.expected // null' "$dest")

    printf '%s\n' "${entries[@]}" | jq -s \
        --argjson call "$call" --argjson truth "$truth" --argjson expected "$previous" \
        --arg session "${transcript##*/}" --arg captured "$captured" '
        { input: { subagentType: $call.type, model: $call.model, prompt: $call.prompt,
                   description: $call.description, tool_use_id: $call.id, cwd: $call.cwd },
          tape: .,
          source: { kind: "transcript", session: $session, capturedAt: $captured,
                    dispatchedAt: $call.ts, parentModel: $call.parentModel },
          truth: $truth }
        + (if $expected == null then {} else { expected: $expected } end)' > "$dest.tmp" \
        || { rm -f "$dest.tmp"; die "cannot build $dest"; }
    mv "$dest.tmp" "$dest" || die "cannot write $dest"
    echo "recorded $id ($(jq -r .type <<<"$call"), $sid)"
}

cmd_record_history() {
    local out="" types=gsd-executor,shell-developer,lisp-developer max=0 transcripts=() t
    while [ $# -gt 0 ]; do
        case "$1" in
            --out) [ $# -ge 2 ] || usage_error "--out needs a value"; out=$2; shift 2 ;;
            --types) [ $# -ge 2 ] || usage_error "--types needs a value"; types=$2; shift 2 ;;
            --max-per-session) [ $# -ge 2 ] || usage_error "--max-per-session needs a value"; max=$2; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            -*) usage_error "unknown option $1" ;;
            *) transcripts+=("$1"); shift ;;
        esac
    done
    [ -n "$out" ] || usage_error "record-history needs --out DIR"
    [ "${#transcripts[@]}" -gt 0 ] || usage_error "record-history needs at least one TRANSCRIPT"
    [[ $max =~ ^[0-9]+$ ]] || usage_error "--max-per-session takes a whole number"
    mkdir -p "$out" || die "cannot create $out"
    local captured count=0 call
    captured=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    for t in "${transcripts[@]}"; do
        [ -f "$t" ] || die "no such transcript: $t"
        while IFS= read -r call; do
            record_one "$t" "$call" "$out" "$captured"
            count=$((count + 1))
        done < <(jq -c --arg types "$types" '
                select(.type == "assistant") | . as $r | .message.content[]?
                | select(.type == "tool_use" and (.name == "Agent" or .name == "Task")
                         and ((.input.subagent_type // "") as $s | $types | split(",") | index($s)))
                | { id, type: .input.subagent_type, model: (.input.model // null),
                    prompt: (.input.prompt // ""), description: (.input.description // ""),
                    cwd: ($r.cwd // null), session: ($r.sessionId // null),
                    ts: ($r.timestamp // null), parentModel: ($r.message.model // null) }' "$t" \
                 | jq -sc --argjson max "$max" '
                     reduce .[] as $c ([]; if any(.[]; .id == $c.id) then . else . + [$c] end)
                     | if $max > 0 then .[:$max] else . end | .[]')
    done
    echo "recorded $count calls into $out"
}

# --- main --------------------------------------------------------------------

[ $# -ge 1 ] || usage_error
sub=$1; shift
case "$sub" in
    make-config) cmd_make_config "$@" ;;
    repoint) cmd_repoint "$@" ;;
    check-config) cmd_check_config "$@" ;;
    reads-outside) cmd_reads_outside "$@" ;;
    tree-hash) cmd_tree_hash "$@" ;;
    make-repo) cmd_make_repo "$@" ;;
    describe) cmd_describe "$@" ;;
    run) cmd_run "$@" ;;
    run-arm) cmd_run_arm "$@" ;;
    report) cmd_report "$@" ;;
    ledger-row) cmd_ledger_row "$@" ;;
    cap-check) cmd_cap_check "$@" ;;
    check) cmd_check "$@" ;;
    bus-silent) cmd_bus_silent "$@" ;;
    replay) cmd_replay "$@" ;;
    record-history) cmd_record_history "$@" ;;
    -h|--help) usage ;;
    *) usage_error "unknown subcommand $sub" ;;
esac
