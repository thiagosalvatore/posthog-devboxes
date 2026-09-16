# shellcheck shell=bash
# The sync session: its binding, its conflicts, and its lifecycle.

# One `hogli devbox:sync --json` per dbx run unless a lifecycle op invalidates it.
session_json() {
    if [ -z "${SESSION_JSON_CACHE:-}" ]; then
        SESSION_JSON_CACHE="$(hogli devbox:sync ${HOGLI_WS_ARGS[@]+"${HOGLI_WS_ARGS[@]}"} --json 2>/dev/null)"
        [ -n "$SESSION_JSON_CACHE" ] || SESSION_JSON_CACHE="[]"
    fi
    echo "$SESSION_JSON_CACHE"
}

session_forget() { SESSION_JSON_CACHE=""; }

# The session JSON travels on argv, not stdin: a `python3 -` heredoc claims
# stdin for the program text, so a piped payload would never arrive.
_session_py() {
    python3 - "$(session_json)" "$@" <<'PY'
import json
import sys

payload, action, args = sys.argv[1], sys.argv[2], sys.argv[3:]
try:
    sessions = json.loads(payload or "[]")
except json.JSONDecodeError:
    sessions = []
session = sessions[0] if sessions else None

if action == "exists":
    raise SystemExit(0 if session else 1)
if session is None:
    raise SystemExit(1)
if action == "alpha":
    print(session.get("alpha") or "")
elif action == "state":
    print(session.get("state") or "")
elif action == "conflicts":
    print(session.get("conflicts") or 0)
elif action == "conflict-paths":
    print("\n".join(session.get("conflictPaths") or []))
elif action == "paths-truncated":
    # conflictPaths is capped at 10 while conflicts is the true total, so a
    # short list can never prove which paths are conflicting.
    shown = len(session.get("conflictPaths") or [])
    raise SystemExit(0 if shown < int(session.get("conflicts") or 0) else 1)
elif action == "last-error":
    print(session.get("lastError") or "")
PY
}

session_exists() { _session_py exists; }
session_alpha() { _session_py alpha; }
session_state() { _session_py state; }
session_conflicts() { _session_py conflicts || echo 0; }
session_conflict_paths() { _session_py conflict-paths; }
session_paths_truncated() { _session_py paths-truncated; }
session_last_error() { _session_py last-error; }

# The guard this whole helper exists for. `hogli devbox:sync` looks a session up
# by label and returns before it ever reads the local checkout path, so running
# it from worktree B against a box serving worktree A prints "Sync already
# running", exits 0, and keeps serving A.
assert_binding() {
    local alpha
    if ! session_exists; then
        registry_bind "$WORKTREE_ROOT" "$WORKSPACE_LABEL" "$WORKSPACE_NAME"
        return 0
    fi
    alpha="$(session_alpha)"
    if [ "$alpha" = "$WORKTREE_ROOT" ]; then
        registry_bind "$WORKTREE_ROOT" "$WORKSPACE_LABEL" "$WORKSPACE_NAME"
        return 0
    fi
    die "$DBX_EXIT_BINDING" \
        "Devbox '$WORKSPACE_NAME' is syncing a different worktree." \
        "  box serves: $alpha" \
        "  you are in: $WORKTREE_ROOT" \
        "Run \`dbx sync --repoint\` to point it at this worktree, or \`dbx -C $alpha sync\`."
}

expected_conflicts_file() { echo "$DBX_ROOT/local/expected-conflicts.txt"; }

# Paths that conflict permanently by design, one per line. `.env` is generated
# on both sides from the same template with different values, so one-way-safe
# can only ever report it.
unexpected_conflicts() {
    local expected
    expected="$(expected_conflicts_file)"
    session_conflict_paths | while IFS= read -r path; do
        [ -n "$path" ] || continue
        grep -qxF "$path" "$expected" 2>/dev/null || echo "$path"
    done
}

report_conflicts() {
    local total unexpected
    total="$(session_conflicts)"
    if [ "$total" -eq 0 ]; then
        log "conflicts: 0"
        return 0
    fi
    if session_paths_truncated; then
        warn "conflicts: $total (mutagen lists only the first 10, so the rest are unclassified)"
        session_conflict_paths | sed 's/^/  /' >&2
        return 1
    fi
    unexpected="$(unexpected_conflicts)"
    if [ -z "$unexpected" ]; then
        log "conflicts: $total, all expected (see $(expected_conflicts_file))"
        return 0
    fi
    warn "conflicts: $total, $(printf '%s\n' "$unexpected" | wc -l | tr -d ' ') unexpected"
    printf '%s\n' "$unexpected" | sed 's/^/  /' >&2
    return 1
}

# mutagen recomputes conflicts on the scan that follows a flush, so reading the
# count straight after one reports the pre-flush state.
sync_wait_settled() {
    local waited=0
    while [ "$waited" -lt 60 ]; do
        session_forget
        case "$(session_state)" in
        watching | "") return 0 ;;
        esac
        sleep 2
        waited=$((waited + 2))
    done
    warn "sync did not settle within 60s (state: $(session_state))"
}

sync_pause() { hogli devbox:sync ${HOGLI_WS_ARGS[@]+"${HOGLI_WS_ARGS[@]}"} --pause >/dev/null && session_forget; }
sync_resume() { hogli devbox:sync ${HOGLI_WS_ARGS[@]+"${HOGLI_WS_ARGS[@]}"} --resume >/dev/null && session_forget; }
sync_flush() { hogli devbox:sync ${HOGLI_WS_ARGS[@]+"${HOGLI_WS_ARGS[@]}"} --flush >/dev/null && session_forget; }
sync_terminate() { hogli devbox:sync ${HOGLI_WS_ARGS[@]+"${HOGLI_WS_ARGS[@]}"} --terminate >/dev/null && session_forget; }
sync_create() { hogli devbox:sync ${HOGLI_WS_ARGS[@]+"${HOGLI_WS_ARGS[@]}"} && session_forget; }
