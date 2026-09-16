# shellcheck shell=bash
# Resolve the worktree dbx acts on, and the devbox bound to it.

resolve_worktree() {
    local start=${1:-$PWD} root
    root="$(cd "$start" 2>/dev/null && pwd -P)" \
        || die "$DBX_EXIT_USAGE" "No such directory: $start"
    while [ "$root" != "/" ]; do
        if [ -f "$root/hogli.yaml" ] && [ -e "$root/.git" ]; then
            WORKTREE_ROOT="$root"
            return 0
        fi
        root="$(dirname "$root")"
    done
    die "$DBX_EXIT_USAGE" \
        "No PostHog checkout at or above $start." \
        "Run dbx from inside a worktree, or pass -C <path>."
}

# Coder rejects workspace names over 32 characters at build time, while hogli's
# own _validate_label enforces no cap -- so the budget has to be applied here.
_label_budget() {
    local prefix
    prefix="$(workspace_prefix)"
    echo $((32 - ${#prefix} - 1))
}

# Deterministic from the resolved path, so the aliases that symlink onto one
# worktree all collapse onto the same box.
_label_hash() {
    printf '%s' "$1" | shasum -a 1 | cut -c1-4
}

derive_label() {
    local root=$1 slug budget suffix
    slug="$(basename "$root" | tr '[:upper:]' '[:lower:]' | sed -E -e 's/[^a-z0-9]+/-/g' -e 's/^-+//' -e 's/-+$//')"
    [ -n "$slug" ] || slug="wt"

    # A label that collides with a region suffix is indistinguishable from a
    # region-suffixed workspace name, and hogli rejects it outright. The hash is
    # hex, so appending it always breaks the collision.
    for suffix in $(reserved_suffixes); do
        case "$slug" in
        "$suffix" | *-"$suffix")
            slug="$slug-$(_label_hash "$root")"
            break
            ;;
        esac
    done

    budget="$(_label_budget)"
    [ "$budget" -ge 6 ] || die "$DBX_EXIT_ERROR" "Workspace prefix leaves no room for a label."
    if [ "${#slug}" -gt "$budget" ]; then
        slug="$(printf '%s' "${slug:0:$((budget - 5))}" | sed -E 's/-+$//')-$(_label_hash "$root")"
    fi
    echo "$slug"
}

# Binding order, most explicit first. A live sync session counts as a binding so
# a box set up before dbx existed keeps working instead of being abandoned for a
# freshly named one.
resolve_workspace() {
    local prefix explicit=0
    prefix="$(workspace_prefix)"

    if [ -n "${DBX_WORKSPACE:-}" ]; then
        WORKSPACE_NAME="$DBX_WORKSPACE"
        explicit=1
    elif [ -n "$(registry_get "$WORKTREE_ROOT" workspace)" ]; then
        WORKSPACE_NAME="$(registry_get "$WORKTREE_ROOT" workspace)"
    elif [ -n "$(_workspace_of_session_for_worktree)" ]; then
        WORKSPACE_NAME="$(_workspace_of_session_for_worktree)"
        log "Adopted the existing sync session's box: $WORKSPACE_NAME"
    else
        WORKSPACE_NAME="$prefix-$(derive_label "$WORKTREE_ROOT")"
    fi

    if [ "$WORKSPACE_NAME" = "$prefix" ]; then
        WORKSPACE_LABEL=""
    else
        WORKSPACE_LABEL="${WORKSPACE_NAME#"$prefix"-}"
    fi

    HOGLI_WS_ARGS=()
    if [ -n "$WORKSPACE_LABEL" ]; then
        HOGLI_WS_ARGS=(-n "$WORKSPACE_LABEL")
    fi

    # A derived name that lands on someone else's box is an accident. An
    # explicit --workspace is a decision, and the live-session guard in
    # assert_binding still catches it if the box is serving another worktree.
    if [ "$explicit" = "0" ]; then
        local other
        other="$(registry_owner_of_label "$WORKSPACE_LABEL" "$WORKTREE_ROOT")"
        if [ -n "$other" ]; then
            die "$DBX_EXIT_BINDING" \
                "Devbox '$WORKSPACE_NAME' is already bound to another worktree:" \
                "  $other" \
                "Pass --workspace <name> to bind this one to a different box."
        fi
    fi
}

# The alpha path of any hogli-created session that points at this worktree.
_workspace_of_session_for_worktree() {
    "$(mutagen_bin)" sync list --template '{{ json . }}' 2>/dev/null \
        | python3 -c '
import json
import sys

root = sys.argv[1]
try:
    sessions = json.loads(sys.stdin.read() or "[]")
except json.JSONDecodeError:
    sessions = []
for session in sessions:
    alpha = session.get("alpha") or {}
    if alpha.get("path") == root:
        workspace = (session.get("labels") or {}).get("hogli-workspace")
        if workspace:
            print(workspace)
            break
' "$WORKTREE_ROOT"
}
