#!/usr/bin/env bash
#
# Give a branch its own git worktree and its own sister session.
#
# create makes a worktree of a main checkout under the scratch root, gives it a
# private view of the repository's planning bucket, writes an .envrc that gives
# the session a stable bus identity and a hermetic worker rooted at the
# worktree, registers the sister in the bucket as sisters/<name>/WORKTREE, and
# opens a /worker tab for it through the fleet launcher.
#
# The view is the directory sisters/<name>/ in the bucket. It holds a relative
# symlink to every other top-level bucket entry, and her own real PARK*,
# BLOCKED*, CURRENT-CONTEXT* and LEFT files, so a write to one of those never
# reaches the leader's copy. The worktree's .planning links to the path the
# SessionStart hook computes for the worktree, and that path links to the view,
# so the hook finds .planning already linked and leaves it alone.
#
# Exit status: 0 done, 1 refused, 2 usage error, 3 environment unsupported.

set -euo pipefail

PROGNAME=${0##*/}
SELF_DIR=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")
SCRATCH_ROOT=${DSMR_SCRATCH_ROOT:-$HOME/SourceCode/lisp-scratch}
RESERVED=(default cursors watch roster members bus.wal broker.lock submit.ipc pub.ipc . ..)

usage() {
    cat <<EOF
$PROGNAME - give a branch its own worktree and sister session.

Usage:
  $PROGNAME create [options] REPO BRANCH
  $PROGNAME teardown [--repo R] [--force] [-n] NAME

create:
  Makes a worktree of REPO (a main checkout with a .planning bucket) at
  \$DSMR_SCRATCH_ROOT/<repo>-<slug> (default root: ~/SourceCode/lisp-scratch),
  on BRANCH. BRANCH is created from --base when it does not exist locally.
  REPO's checked-out branch, HEAD and tracked files are not changed.

      --name N      Sister name and bus identity (default: <repo>-integration)
      --bus B       Bus to join (default: \$DSMR_BUS_SELECTOR; one is required)
      --slug S      Worktree directory suffix (default: BRANCH's last component)
      --base REF    Start point for a new BRANCH (default: REPO's HEAD)
      --no-launch   Create and register, but open no tab
  -n, --dry-run     Validate, print each step, and change nothing

  Names, buses and slugs take [A-Za-z0-9._-] only, at most 32 characters, and
  not one of: ${RESERVED[*]}.

teardown:
  Removes a sister's worktree once she has parked at its HEAD, left the bus and
  stopped her watcher, and the worktree is clean with every commit on a remote.
  Her records move to sisters-retired/ in the bucket, and the branch is kept.

      --repo R      Main checkout holding the registration (default: the
                    repository containing the working directory)
      --force       Remove even when unparked, blocked, dirty or unpushed;
                    never while her watcher answers live
  -n, --dry-run     Run the checks, print what would be removed, change nothing

Exit status: 0 done, 1 refused, 2 usage error, 3 environment unsupported.
EOF
}

refuse()      { printf '%s: %s\n' "$PROGNAME" "$*" >&2; exit 1; }
usage_error() { printf '%s: %s (try --help)\n' "$PROGNAME" "$*" >&2; exit 2; }
unsupported() { printf '%s: %s\n' "$PROGNAME" "$*" >&2; exit 3; }

contains() {
    local needle=$1 item
    shift
    for item in "$@"; do
        [[ $item == "$needle" ]] && return 0
    done
    return 1
}

# Print the reason WORD (labelled KIND) breaks the name rules, or nothing.
name_problem() {
    local kind=$1 word=$2
    if [[ -z $word ]]; then
        printf '%s is empty' "$kind"
    elif ((${#word} > 32)); then
        printf '%s %s is longer than 32 characters' "$kind" "$word"
    elif [[ ! $word =~ ^[A-Za-z0-9._-]+$ ]]; then
        printf '%s %s holds characters outside [A-Za-z0-9._-]' "$kind" "$word"
    elif contains "$word" "${RESERVED[@]}"; then
        printf '%s %s is reserved' "$kind" "$word"
    fi
}

has_space() { [[ $1 =~ [[:space:]] ]]; }

# Print the value of KEY from a key: value registration FILE.
field() { awk -v k="$2:" '$1 == k { print $2; exit }' "$1"; }

# Print the planning directory the SessionStart hook computes for the project
# root DIR (a real path): <cache>/opencode/projects/<name>_<hash>/planning,
# where name is the lowercased basename cut to 32 characters of [a-z0-9-] and
# hash the first 8 hex digits of the SHA-256 of DIR.
hook_planning_dir() {
    local real=$1 name hash LC_ALL=C
    name=$(printf '%s' "${real##*/}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | tr -s '-' |
           sed 's/^-//; s/-$//' | cut -c1-32)
    [[ -n $name ]] || name=project
    hash=$(printf '%s' "$real" | sha256sum | cut -c1-8)
    printf '%s/opencode/projects/%s_%s/planning\n' "${XDG_CACHE_HOME:-$HOME/.cache}" "$name" "$hash"
}

# Bucket entries a sister keeps as her own files instead of links to the shared
# ones: her park, block, context and departure records.
own_entry() {
    case $1 in PARK*|BLOCKED*|CURRENT-CONTEXT*|LEFT|WORKTREE) return 0 ;; esac
    return 1
}

# The fleet launcher: $DSMR_START_SISTERS, else the one beside this script,
# else the maintained checkout's copy.
find_launcher() {
    local c
    for c in "${DSMR_START_SISTERS:-}" "$SELF_DIR/start-sisters.sh" \
             "$HOME/SourceCode/lisp/dsmr-mcp/scripts/start-sisters.sh"; do
        [[ -n $c && -x $c ]] && { printf '%s\n' "$c"; return 0; }
    done
    return 1
}

cmd_create() {
    local name="" bus=${DSMR_BUS_SELECTOR:-} slug="" base="" launch=1 dry=0
    local args=()
    while (($#)); do
        case $1 in
            --name=*|--bus=*|--slug=*|--base=*) set -- "${1%%=*}" "${1#*=}" "${@:2}"; continue ;;
            --name)  (($# >= 2)) || usage_error "$1 needs a value"; name=$2; shift 2 ;;
            --bus)   (($# >= 2)) || usage_error "$1 needs a value"; bus=$2; shift 2 ;;
            --slug)  (($# >= 2)) || usage_error "$1 needs a value"; slug=$2; shift 2 ;;
            --base)  (($# >= 2)) || usage_error "$1 needs a value"; base=$2; shift 2 ;;
            --no-launch)    launch=0; shift ;;
            -n|--dry-run)   dry=1; shift ;;
            -h|--help)      usage; exit 0 ;;
            --)             shift; args+=("$@"); break ;;
            -*)             usage_error "unknown option: $1" ;;
            *)              args+=("$1"); shift ;;
        esac
    done
    ((${#args[@]} == 2)) || usage_error "create takes REPO and BRANCH"
    local repo_arg=${args[0]} branch=${args[1]}

    command -v git >/dev/null || unsupported "git not found on PATH"
    command -v direnv >/dev/null || unsupported "direnv not found on PATH; the worktree's .envrc needs it"

    # Every check runs before anything is changed.
    [[ -d $repo_arg ]] || refuse "not a directory: $repo_arg"
    local repo top common
    repo=$(cd -- "$repo_arg" && pwd -P)
    has_space "$repo" && refuse "repository path holds whitespace: $repo; move it or use another checkout"
    top=$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null) ||
        refuse "not a git repository: $repo"
    common=$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir)
    [[ $top == "$repo" && $(dirname -- "$common") == "$repo" ]] ||
        refuse "$repo is not a main checkout; name the repository's main checkout, not a linked worktree or a subdirectory"
    local repo_name=${repo##*/}
    [[ -d $repo/.planning ]] ||
        refuse "$repo/.planning does not resolve to a directory; the sister shares the repository's planning bucket"
    local bucket
    bucket=$(readlink -f -- "$repo/.planning")

    git check-ref-format --branch "$branch" >/dev/null 2>&1 ||
        refuse "not a valid branch name: $branch"

    [[ -n $name ]] || name=$repo_name-integration
    if [[ -z $slug ]]; then
        slug=${branch##*/}
        slug=${slug//[^A-Za-z0-9._-]/-}
    fi
    [[ -n $bus ]] || refuse "no bus: pass --bus, or set DSMR_BUS_SELECTOR"
    local kind word problem
    for kind in name bus slug; do
        case $kind in name) word=$name ;; bus) word=$bus ;; slug) word=$slug ;; esac
        problem=$(name_problem "$kind" "$word")
        [[ -z $problem ]] || refuse "$problem; choose another with --$kind"
    done
    [[ $name != "$repo_name" ]] ||
        refuse "name $name is the repository's own bus name; choose another with --name"

    local reg=$bucket/sisters/$name/WORKTREE
    if [[ -e $reg ]]; then
        refuse "$name is already registered for $(field "$reg" worktree); retire it first with: $PROGNAME teardown --repo $repo $name"
    fi

    local root=$SCRATCH_ROOT
    [[ -d $root ]] && root=$(cd -- "$root" && pwd -P)
    local dest=$root/$repo_name-$slug
    has_space "$dest" && refuse "destination path holds whitespace: $dest; set DSMR_SCRATCH_ROOT"
    [[ -e $dest || -L $dest ]] && refuse "destination exists: $dest; choose another with --slug"
    # The hook path the worktree's .planning will link to. Only an empty
    # directory or a link into a sisters/ view may already stand there.
    local hookdir
    hookdir=$(hook_planning_dir "$dest")
    if [[ -L $hookdir ]]; then
        [[ $(readlink -- "$hookdir") == "$bucket"/sisters/* ]] ||
            refuse "$hookdir is a link that points elsewhere; remove it, then run again"
    elif [[ -e $hookdir ]]; then
        [[ -d $hookdir && -z $(ls -A -- "$hookdir") ]] ||
            refuse "$hookdir exists and is not empty; move it aside, then run again"
    fi

    local start have_branch=0
    if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
        have_branch=1
        [[ -z $base ]] || refuse "branch $branch exists, so --base $base would not be used; drop --base"
        start=$branch
    else
        start=${base:-HEAD}
    fi
    git -C "$repo" rev-parse --verify --quiet "$start^{commit}" >/dev/null ||
        refuse "start point is not a commit: $start"
    if git -C "$repo" cat-file -e "$start:.envrc" 2>/dev/null; then
        refuse "$start tracks .envrc, which the worktree's generated .envrc would overwrite; start from a commit without it"
    fi
    if [[ -e $repo/.envrc ]] && ! direnv exec "$repo" true >/dev/null 2>&1; then
        refuse "direnv will not load $repo/.envrc; run 'direnv allow $repo' after reading it, then run again"
    fi

    local launcher="" logdir=""
    if ((launch)); then
        launcher=$(find_launcher) || unsupported "start-sisters.sh not found; set DSMR_START_SISTERS"
        logdir=${DSMR_BRINGUP_LOG_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/dsmr-mcp/bringup}/$name-$(date -u +%Y%m%dT%H%M%SZ)
    fi

    if ((dry)); then
        if ((have_branch)); then
            printf 'would run: git -C %s worktree add %s %s\n' "$repo" "$dest" "$branch"
        else
            printf 'would run: git -C %s worktree add -b %s %s %s\n' "$repo" "$branch" "$dest" "$start"
        fi
        printf 'would write: %s, with a link to each shared entry of %s\n' "$reg" "$bucket"
        printf 'would link: %s -> %s\n' "$hookdir" "$bucket/sisters/$name"
        printf 'would link: %s/.planning -> %s\n' "$dest" "$hookdir"
        printf 'would ignore .planning and .envrc in the common info/exclude, where not already ignored\n'
        printf 'would write: %s/.envrc (bus %s, agent %s, hermetic)\n' "$dest" "$bus" "$name"
        printf 'would run: direnv allow %s\n' "$dest"
        if ((launch)); then
            printf 'would run: %s --no-scan --extra %s --no-stagger --permission-mode auto --session-log %s\n' \
                "$launcher" "$dest" "$logdir"
        fi
        return 0
    fi

    if ((have_branch)); then
        git -C "$repo" worktree add "$dest" "$branch" >&2 || refuse "git worktree add failed; nothing was created"
    else
        git -C "$repo" worktree add -b "$branch" "$dest" "$start" >&2 || refuse "git worktree add failed; nothing was created"
    fi

    # From here a failure leaves a worktree; say which step and how to clear it.
    failed() {
        printf '%s: %s failed after the worktree was created at %s\n' "$PROGNAME" "$1" "$dest" >&2
        printf 'clear it with: %s teardown --repo %s --force %s\n' "$PROGNAME" "$repo" "$name" >&2
        exit 1
    }

    dest=$(cd -- "$dest" && pwd -P) || failed "resolving the worktree path"
    mkdir -p -- "$bucket/sisters" "$bucket/sisters/$name" || failed "creating the registration directory"
    printf 'name: %s\nrepo: %s\nworktree: %s\nbranch: %s\nbus: %s\ncreated: %s\n' \
        "$name" "$repo" "$dest" "$branch" "$bus" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        >"$reg" || failed "writing $reg"
    local entry
    while IFS= read -r -d '' entry; do
        entry=${entry##*/}
        own_entry "$entry" && continue
        ln -s -- "../../$entry" "$bucket/sisters/$name/$entry" || failed "linking $entry into the view"
    done < <(find "$bucket" -mindepth 1 -maxdepth 1 -print0)
    hookdir=$(hook_planning_dir "$dest")
    mkdir -p -- "${hookdir%/*}" || failed "creating ${hookdir%/*}"
    [[ -L $hookdir ]] && { rm -- "$hookdir" || failed "replacing $hookdir"; }
    [[ -d $hookdir ]] && { rmdir -- "$hookdir" || failed "replacing $hookdir"; }
    ln -s -- "$bucket/sisters/$name" "$hookdir" || failed "linking $hookdir"
    ln -s -- "$hookdir" "$dest/.planning" || failed "linking $dest/.planning"

    local exclude path
    exclude=$(git -C "$dest" rev-parse --path-format=absolute --git-path info/exclude) ||
        failed "locating info/exclude"
    for path in .planning .envrc; do
        git -C "$dest" check-ignore -q -- "$path" && continue
        mkdir -p -- "$(dirname -- "$exclude")" || failed "creating $(dirname -- "$exclude")"
        if [[ -s $exclude && -n $(tail -c1 -- "$exclude") ]]; then
            printf '\n' >>"$exclude" || failed "writing $exclude"
        fi
        printf '%s\n' "$path" >>"$exclude" || failed "writing $exclude"
    done

    {
        printf '# Generated by %s for worktree sister %s.\n' "$PROGNAME" "$name"
        printf '# The repository .envrc follows unchanged, then the worktree sister block.\n'
        [[ -e $repo/.envrc ]] && cat -- "$repo/.envrc"
        printf '\n# >>> worktree sister >>>\n'
        printf 'export DSMR_WORKTREE_SISTER=%q\n' "$name"
        printf 'export DSMR_BUS_AGENT=%q\n' "$name"
        printf 'export DSMR_BUS_SELECTOR=%q\n' "$bus"
        printf 'export DSMR_BUS_DIRECT_ADDRESSING=1\n'
        # shellcheck disable=SC2016  # the expansion belongs in the written .envrc
        printf 'export DSMR_RELATED_PROJECTS=%q"${DSMR_RELATED_PROJECTS:+:$DSMR_RELATED_PROJECTS}"\n' "$dest/"
        printf 'export DSMR_MODE=hermetic\n'
        printf 'unset DSMR_SLYNK_ATTACH\n'
        printf '# <<< worktree sister <<<\n'
    } >"$dest/.envrc" || failed "writing $dest/.envrc"

    direnv allow "$dest" || failed "direnv allow $dest"

    if ((launch)); then
        mkdir -p -- "$logdir" || failed "creating $logdir"
        (cd -- "$dest" && "$launcher" --no-scan --extra "$dest" --no-stagger \
            --permission-mode auto --session-log "$logdir") || failed "the launcher"
    fi

    printf '\nworktree  %s\nbranch    %s\nbus       %s\nname      %s\n' "$dest" "$branch" "$bus" "$name"
    printf '\nShe enrolls herself on bus %s at bring-up.\n' "$bus"
    if ((launch)); then
        printf 'Her tab is titled %s and may wait at the folder-trust question.\n' "${dest##*/}"
        printf 'She is up only when RESUMED %s arrives on the bus.\n' "$name"
    else
        printf 'No tab was opened (--no-launch).\n'
    fi
}

cmd_teardown() {
    local repo_opt="" force=0 dry=0 args=()
    while (($#)); do
        case $1 in
            --repo=*)       set -- --repo "${1#*=}" "${@:2}"; continue ;;
            --repo)         (($# >= 2)) || usage_error "$1 needs a value"; repo_opt=$2; shift 2 ;;
            --force)        force=1; shift ;;
            -n|--dry-run)   dry=1; shift ;;
            -h|--help)      usage; exit 0 ;;
            --)             shift; args+=("$@"); break ;;
            -*)             usage_error "unknown option: $1" ;;
            *)              args+=("$1"); shift ;;
        esac
    done
    ((${#args[@]} == 1)) || usage_error "teardown takes NAME"
    local name=${args[0]}
    command -v git >/dev/null || unsupported "git not found on PATH"

    local problem
    problem=$(name_problem name "$name")
    [[ -z $problem ]] || refuse "$problem"
    local where
    if [[ -n $repo_opt ]]; then
        where=$repo_opt
    else
        where=$(git rev-parse --show-toplevel 2>/dev/null) ||
            refuse "the working directory is not in a repository; pass --repo"
    fi
    [[ -d $where/.planning ]] || refuse "$where/.planning does not resolve to a directory; pass --repo"
    local bucket sdir reg
    bucket=$(readlink -f -- "$where/.planning")
    sdir=$bucket/sisters/$name
    reg=$sdir/WORKTREE
    if [[ ! -f $reg ]]; then
        local registered=() r
        for r in "$bucket"/sisters/*/WORKTREE; do
            [[ -f $r ]] && registered+=("$(basename -- "$(dirname -- "$r")")")
        done
        refuse "$name is not registered in $bucket; registered: ${registered[*]:-none}"
    fi
    local repo wt branch bus
    repo=$(field "$reg" repo)
    wt=$(field "$reg" worktree)
    branch=$(field "$reg" branch)
    bus=$(field "$reg" bus)
    [[ -n $repo && -n $wt && -n $branch && -n $bus ]] ||
        refuse "$reg lacks a repo, worktree, branch or bus field; repair it by hand"

    local leave="send to $name by name, then run teardown again: LEAVE: commit and push $branch, park, bus-leave, reap your watcher"
    local hard=() soft=() advice=() need_leave=0 left_forced=0

    # a. Removing the directory the caller stands in strands its shell.
    local here
    here=$(pwd -P)
    [[ $here == "$wt" || $here == "$wt"/* ]] &&
        hard+=("the working directory is inside $wt; run teardown from the main checkout")

    # b. Only a directory git lists as a worktree is ever removed.
    local listed=0
    if git -C "$repo" worktree list --porcelain 2>/dev/null | grep -qxF "worktree $wt"; then
        listed=1
    else
        hard+=("git does not list $wt as a worktree of $repo; nothing is removed, inspect it by hand")
    fi

    # c. A live watcher means she is still listening; --force never overrides it.
    local watch=${DSMR_BUS_WATCH:-$HOME/.local/bin/dsmr-bus-watch} answer rc
    if [[ ! -x $watch ]]; then
        hard+=("cannot tell whether $name is listening: $watch not found; set DSMR_BUS_WATCH")
    else
        rc=0
        answer=$("$watch" --check-live --bus "$bus" --agent "$name" --namespace "$wt/" 2>/dev/null) || rc=$?
        case $rc in
            1) ;;
            0)  hard+=("$name is still listening ($answer)")
                need_leave=1
                advice+=("if her session is gone, stop her watcher with: ~/.local/bin/dsmr-bus-watch --reap --all-buses --agent $name --namespace $wt/") ;;
            *)  hard+=("cannot tell whether $name is listening: --check-live exited $rc (${answer:-no answer})") ;;
        esac
    fi

    # d. Her LEFT file says she parked, replied and left the bus.
    if [[ ! -s $sdir/LEFT ]]; then
        soft+=("$name has not left: $sdir/LEFT is missing or empty")
        if ((force)); then left_forced=1; else need_leave=1; fi
    fi

    # e. PARK.md names the worktree's HEAD.
    local head="" parked
    if ((listed)); then head=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || head=""; fi
    if [[ ! -f $sdir/PARK.md ]]; then
        soft+=("$name has not parked: $sdir/PARK.md is missing")
    elif [[ $(grep -c '^sha:' "$sdir/PARK.md") != 1 ]]; then
        soft+=("$sdir/PARK.md holds other than exactly one sha: line")
    else
        parked=$(awk '/^sha:/ { print $2 }' "$sdir/PARK.md")
        if ((${#parked} < 7)) || [[ -z $head || ${head#"$parked"} == "$head" ]]; then
            soft+=("$sdir/PARK.md names ${parked:-no sha}, not the worktree HEAD ${head:-(unreadable)}")
        fi
    fi

    # f. An open block is a question nobody has answered.
    [[ -s $sdir/BLOCKED.md ]] && soft+=("$sdir/BLOCKED.md is open; resolve it first")

    # g, h. Work that exists only in this worktree.
    if ((listed)) && [[ -d $wt ]]; then
        # git worktree remove deletes ignored files too, so they count.
        local dirty
        dirty=$(git -C "$wt" status --porcelain --untracked-files=all --ignored 2>/dev/null |
                grep -vxE '!! (\.planning|\.envrc)' || true)
        [[ -z $dirty ]] ||
            soft+=("$wt holds uncommitted, untracked or ignored files: $(head -3 <<<"$dirty" | tr '\n' ' ')")
        local unpushed
        unpushed=$(git -C "$wt" rev-list --count HEAD --not --remotes 2>/dev/null || echo unknown)
        [[ $unpushed == 0 ]] ||
            soft+=("$wt holds $unpushed commit(s) on no remote-tracking ref; push $branch")
    fi

    local m
    if ((${#hard[@]})) || { ((${#soft[@]})) && ((!force)); }; then
        for m in ${hard[@]+"${hard[@]}"} ${soft[@]+"${soft[@]}"}; do
            printf '%s: refused: %s\n' "$PROGNAME" "$m" >&2
        done
        ((need_leave)) && printf '%s: %s\n' "$PROGNAME" "$leave" >&2
        for m in ${advice[@]+"${advice[@]}"}; do printf '%s: %s\n' "$PROGNAME" "$m" >&2; done
        ((${#soft[@]})) && ((!${#hard[@]})) &&
            printf '%s: --force removes it anyway, keeping the branch and her records\n' "$PROGNAME" >&2
        exit 1
    fi
    for m in ${soft[@]+"${soft[@]}"}; do
        printf '%s: forced past: %s\n' "$PROGNAME" "$m" >&2
    done

    local stamp archive
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    archive=$bucket/sisters-retired/$name-$stamp
    if ((dry)); then
        printf 'would remove the worktree %s (branch %s is kept)\n' "$wt" "$branch"
        printf 'would archive %s to %s\n' "$sdir" "$archive"
        return 0
    fi

    # The links go first and alone, so nothing below can reach the bucket. The
    # hook path is removed only when it links to her own view.
    local link=$wt/.planning target="" hookdir hooktarget=""
    hookdir=$(hook_planning_dir "$wt")
    if [[ -L $link ]]; then
        target=$(readlink -- "$link")
        rm -- "$link"
    elif [[ -e $link ]]; then
        refuse "$link is not a symlink; nothing is removed, inspect it by hand"
    fi
    if [[ -L $hookdir && $(readlink -- "$hookdir") == "$sdir" ]]; then
        hooktarget=$sdir
        rm -- "$hookdir"
        rmdir -- "${hookdir%/*}" 2>/dev/null || true
    fi
    local remove=(worktree remove)
    ((force)) && remove+=(--force)
    if ! git -C "$repo" "${remove[@]}" "$wt"; then
        if [[ -n $hooktarget ]]; then
            mkdir -p -- "${hookdir%/*}" && ln -s -- "$hooktarget" "$hookdir"
        fi
        [[ -n $target ]] && ln -s -- "$target" "$link"
        refuse "git worktree remove $wt failed; the .planning links are restored"
    fi
    mkdir -p -- "$bucket/sisters-retired"
    mv -- "$sdir" "$archive"

    printf 'removed   %s\nbranch    %s (kept)\narchived  %s\n' "$wt" "$branch" "$archive"
    if ((left_forced)); then
        printf 'she never left the bus; disenroll her with:\n'
        printf '  bus-roster {"action": "disenroll", "agent": "%s/%s", "bus": "%s"}\n' "$wt" "$name" "$bus"
    fi
    printf 'close the tab titled %s\n' "${wt##*/}"
}

(($#)) || { usage >&2; exit 2; }
case $1 in
    create)    shift; cmd_create "$@" ;;
    teardown)  shift; cmd_teardown "$@" ;;
    -h|--help) usage ;;
    *)         usage_error "unknown subcommand: $1" ;;
esac
