#!/usr/bin/env bash
#
# Live probes and transcript reports for the subagent-routing mod.
#
#   make-repo DIR --gsd-core local-pristine
#       Build a scratch git repository that /gsd-quick can run in, holding a
#       project-local gsd-core copy restored to the installer's files.
#   run REPO --session-id UUID [--config-dir DIR] [--plugin-dir DIR]
#       [--capture DIR] [--debug-file FILE] [--append-system-prompt TEXT] -- PROMPT
#       Run one headless Claude Code session in REPO and print its transcript.
#   report TRANSCRIPT
#       Print one TSV row per Agent call in a session: what was asked for,
#       what ran (from the subagent's own records) and what the mod logged.
#   replay RECORDINGS_DIR [--mod DIR]
#       Run the mod's replay tests over every recorded spawn in RECORDINGS_DIR,
#       against a temporary copy of the mod (default: this repository's).
#
# Exit status: 0 success, 1 failure, 64 usage.

set -u

PROGNAME=${0##*/}
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
GATE=$SCRIPT_DIR/../harness/scripts/gsd-routing-gate.sh
CONFIG_HOME=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
# The planning directory gsd-core reads, named once.
PLANNING_DIR=.planning
LOG_DIR=logs/subagent-routing
PROBE_MODEL=claude-opus-5-5
PROBE_TIMEOUT=1800

usage() {
    cat <<EOF
usage: $PROGNAME make-repo DIR --gsd-core local-pristine
       $PROGNAME run REPO --session-id UUID [--config-dir DIR] [--plugin-dir DIR]
                 [--capture DIR] [--debug-file FILE] [--append-system-prompt TEXT] -- PROMPT
       $PROGNAME report TRANSCRIPT
       $PROGNAME replay RECORDINGS_DIR [--mod DIR]
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

write_probe_files() {
    local dir=$1
    mkdir -p "$dir/scripts" "$dir/src" "$dir/docs"
    link_planning "$dir"
    printf '#!/usr/bin/env bash\necho "probe"\n' > "$dir/scripts/probe.sh"
    chmod +x "$dir/scripts/probe.sh"
    printf '(defun probe () "probe")\n' > "$dir/src/probe.lisp"
    printf 'test:\n\ttrue\n' > "$dir/Makefile"
    printf '# Probe\n\nA scratch repository for routing probes.\n' > "$dir/docs/probe.md"

    jq -n '{
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
      planning: { agents: { executor: "lisp-developer", language: "common-lisp", specialized: true } },
      model_overrides: { "gsd-executor": "opus" },
      agent_skills: { "gsd-planner": ["global:executor-routing"] },
      git: { branching_strategy: "none" }
    }' > "$dir/$PLANNING_DIR/config.json"

    cat > "$dir/$PLANNING_DIR/STATE.md" <<'EOF'
# Project State

## Current Position

Phase: none
Status: idle
EOF
    cat > "$dir/$PLANNING_DIR/ROADMAP.md" <<'EOF'
# Roadmap

Quick tasks only.
EOF
    cat > "$dir/$PLANNING_DIR/PROJECT.md" <<'EOF'
# Probe

A scratch repository for routing probes: one shell script, one Lisp file, a
Makefile and one document.
EOF
}

# install_pristine DIR: copy gsd-core, and the installer's scripts it loads,
# into DIR/.claude; restore each patched target from its backup; print the
# proof and return 1 if it does not hold.
install_pristine() {
    local dir=$1 src=$CONFIG_HOME/gsd-core dst=$1/.claude/gsd-core
    local manifest=$CONFIG_HOME/gsd-file-manifest.json
    local row target suffix entries=0 matched=0 bad=0 rel want got gate_out gate_rc nmissing

    [ -d "$src" ] || die "gsd-core not installed under $CONFIG_HOME"
    [ -f "$manifest" ] || die "installer manifest not found: $manifest"
    [ -f "$GATE" ] || die "routing gate not found: $GATE"
    mkdir -p "$dir/.claude"
    cp -a "$src" "$dst" || die "cannot copy $src"
    # gsd-tools loads files from <config>/scripts: copy the ones the installer wrote.
    while IFS= read -r rel; do
        mkdir -p "$dir/.claude/$(dirname "$rel")"
        cp -a "$CONFIG_HOME/$rel" "$dir/.claude/$rel" || die "cannot copy $CONFIG_HOME/$rel"
    done < <(jq -r '.files | keys[] | select(startswith("scripts/"))' "$manifest")

    # Targets and backup suffixes are the gate's units rows.
    while IFS= read -r row; do
        target=$(printf '%s\n' "$row" | cut -d'|' -f2)
        suffix=$(printf '%s\n' "$row" | cut -d'|' -f5)
        [ -f "$dir/.claude/$target$suffix" ] || die "no backup for $target ($suffix)"
        cp "$dir/.claude/$target$suffix" "$dir/.claude/$target"
        echo "restored $target from $suffix"
    done < <(sed -n "s/^  '\([a-z-]*|gsd-core\/[^']*\)'\$/\1/p" "$GATE")
    find "$dst" -name '*.pre-*' -type f -delete

    while IFS=$'\t' read -r rel want; do
        entries=$((entries + 1))
        got=$(sha256sum "$dir/.claude/$rel" 2>/dev/null | cut -d' ' -f1)
        if [ "$got" = "$want" ]; then
            matched=$((matched + 1))
        else
            bad=$((bad + 1))
            echo "mismatch $rel"
        fi
    done < <(jq -r '.files | to_entries[] | select(.key | startswith("gsd-core/") or startswith("scripts/")) | [.key, .value] | @tsv' "$manifest")
    echo "manifest $(jq -r .version "$manifest"): $matched of $entries gsd-core and scripts entries match"

    gate_out=$(bash "$GATE" --root "$dir/.claude")
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

cmd_make_repo() {
    local dir="" gsd=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --gsd-core) [ $# -ge 2 ] || usage_error "--gsd-core needs a value"; gsd=$2; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            -*) usage_error "unknown option $1" ;;
            *) [ -z "$dir" ] || usage_error "one DIR only"; dir=$1; shift ;;
        esac
    done
    [ -n "$dir" ] || usage_error "make-repo needs DIR"
    [ "$gsd" = local-pristine ] || usage_error "--gsd-core takes local-pristine"
    if [ -e "$dir" ] && [ -n "$(ls -A "$dir" 2>/dev/null)" ]; then
        die "$dir exists and is not empty; remove it first"
    fi
    mkdir -p "$dir" || die "cannot create $dir"
    dir=$(cd "$dir" && pwd)

    git -C "$dir" init -q || die "git init failed in $dir"
    write_probe_files "$dir"
    install_pristine "$dir" || exit 1

    # The config dir's global excludes keep .claude and the planning directory
    # out of this scratch history; only the probe files are committed.
    git -C "$dir" add scripts src docs Makefile || die "git add failed"
    git -C "$dir" commit -q -m "Add probe files" || die "git commit failed"
    echo "probe repository ready: $dir"
}

# --- run ---------------------------------------------------------------------

cmd_run() {
    local repo="" sid="" config="" plugin="" capture="" debug="" system="" prompt="" have_prompt=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --session-id) [ $# -ge 2 ] || usage_error "--session-id needs a value"; sid=$2; shift 2 ;;
            --config-dir) [ $# -ge 2 ] || usage_error "--config-dir needs a value"; config=$2; shift 2 ;;
            --plugin-dir) [ $# -ge 2 ] || usage_error "--plugin-dir needs a value"; plugin=$2; shift 2 ;;
            --capture) [ $# -ge 2 ] || usage_error "--capture needs a value"; capture=$2; shift 2 ;;
            --debug-file) [ $# -ge 2 ] || usage_error "--debug-file needs a value"; debug=$2; shift 2 ;;
            --append-system-prompt) [ $# -ge 2 ] || usage_error "--append-system-prompt needs a value"; system=$2; shift 2 ;;
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
    local unset_args=() name
    while IFS= read -r name; do
        case "$name" in
            DSMR_*|CLAUDECODE|CLAUDE_CODE_*|CLAUDE_PID|CLAUDE_EFFORT|CLAUDE_CONFIG_DIR|SUBAGENT_ROUTING_CAPTURE)
                unset_args+=(-u "$name") ;;
        esac
    done < <(compgen -e)
    local set_args=()
    [ -z "$config" ] || set_args+=("CLAUDE_CONFIG_DIR=$config")
    [ -z "$capture" ] || set_args+=("SUBAGENT_ROUTING_CAPTURE=$capture")

    local claude_args=(-p --session-id "$sid" --permission-mode auto --model "$PROBE_MODEL" --debug-file "$debug")
    [ -z "$plugin" ] || claude_args+=(--plugin-dir "$plugin")
    [ -z "$system" ] || claude_args+=(--append-system-prompt "$system")

    local rc
    (cd "$repo" && env "${unset_args[@]}" "${set_args[@]}" timeout "$PROBE_TIMEOUT" claude "${claude_args[@]}" "$prompt")
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

    printf 'tool_use_id\trequested_type\trequested_model\tran_type\tran_models\ttokens\tlogged_action\tlogged_type\tlog_agrees\tagent_id\n'
    local req_type req_model models tokens agent agrees la lt rt
    while IFS=$'\t' read -r id req_type req_model; do
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
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$id" "$req_type" "$req_model" "$rt" "$models" "$tokens" "$la" "$lt" "$agrees" "$agent"
    done < <(jq -r 'select(.type == "assistant") | .message.content[]?
                    | select(.type == "tool_use" and (.name == "Agent" or .name == "Task"))
                    | [.id, (.input.subagent_type // "-"), (.input.model // "-")] | @tsv' "${files[@]}" \
             | awk -F'\t' '!seen[$1]++')
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

# --- main --------------------------------------------------------------------

[ $# -ge 1 ] || usage_error
sub=$1; shift
case "$sub" in
    make-repo) cmd_make_repo "$@" ;;
    run) cmd_run "$@" ;;
    report) cmd_report "$@" ;;
    replay) cmd_replay "$@" ;;
    -h|--help) usage ;;
    *) usage_error "unknown subcommand $sub" ;;
esac
