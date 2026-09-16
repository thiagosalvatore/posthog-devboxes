# shellcheck shell=bash
# Worktree -> devbox bindings, and a log of what each align did.
#
# The align log exists to falsify one assumption: that pause/align/resume yields
# fewer conflicts than it creates. Every align records the count before and
# after, so a positive delta shows up as a fact instead of a hunch.

registry_path() { echo "$DBX_HOME/registry.json"; }

_registry_py() {
    python3 - "$(registry_path)" "$@" <<'PY'
import json
import os
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
action, args = sys.argv[2], sys.argv[3:]

try:
    registry = json.loads(path.read_text())
except (OSError, json.JSONDecodeError):
    registry = {}
registry.setdefault("version", 1)
worktrees = registry.setdefault("worktrees", {})


def save() -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(registry, indent=2, sort_keys=True) + "\n")
    os.replace(tmp, path)


if action == "get":
    entry = worktrees.get(args[0]) or {}
    print(entry.get(args[1], ""))
elif action == "bind":
    root, label, workspace = args
    entry = worktrees.setdefault(root, {})
    entry["label"] = label
    entry["workspace"] = workspace
    save()
elif action == "labels":
    print("\n".join(sorted(e.get("label", "") for e in worktrees.values() if e.get("label"))))
elif action == "owner-of-label":
    label, root = args
    for other, entry in worktrees.items():
        if entry.get("label") == label and other != root:
            print(other)
            break
elif action == "record-align":
    root, sha, before, after = args
    entry = worktrees.setdefault(root, {})
    aligns = entry.setdefault("aligns", [])
    aligns.append({"sha": sha, "conflicts_before": int(before), "conflicts_after": int(after)})
    del aligns[:-20]
    save()
elif action == "last-align":
    entry = worktrees.get(args[0]) or {}
    aligns = entry.get("aligns") or []
    if aligns:
        last = aligns[-1]
        # A paused session reports no conflicts, so align stores -1 for a count
        # it could not read rather than a zero that reads as a real measurement.
        def count(value: int) -> str:
            return "unknown" if value < 0 else str(value)

        print(f"{last['sha']} {count(last['conflicts_before'])} -> {count(last['conflicts_after'])}")
    else:
        print("none")
elif action == "cache-get":
    print(registry.get(args[0], ""))
elif action == "cache-set":
    registry[args[0]] = args[1]
    save()
else:
    raise SystemExit(f"unknown registry action: {action}")
PY
}

registry_get() { _registry_py get "$1" "$2"; }
registry_bind() { _registry_py bind "$1" "$2" "$3"; }
registry_owner_of_label() { _registry_py owner-of-label "$1" "$2"; }
registry_record_align() { _registry_py record-align "$1" "$2" "$3" "$4"; }
registry_last_align() { _registry_py last-align "$1"; }

# Both values come from hogli itself rather than a copy kept here, and both are
# stable per machine, so they are read once and cached.
registry_cached() {
    local key=$1 value
    value="$(_registry_py cache-get "$key")"
    if [ -z "$value" ]; then
        value="$("$2")" || return 1
        [ -n "$value" ] && _registry_py cache-set "$key" "$value"
    fi
    echo "$value"
}

# Reads hogli's own constants rather than restating them here, so a new region
# suffix or a renamed workspace prefix cannot drift out of step.
_hogli_python() {
    local venv
    venv="$(cd "$WORKTREE_ROOT" && . ./bin/helpers/worktree-borrow.sh && posthog_find_venv "$WORKTREE_ROOT")"
    [ -n "$venv" ] || die "$DBX_EXIT_ERROR" \
        "No Python venv under $WORKTREE_ROOT." \
        "Activate flox in that worktree once, or run \`uv sync\`."
    PYTHONPATH="$WORKTREE_ROOT/tools/hogli-commands" "$venv/bin/python" -c "$1"
}

_read_workspace_prefix() {
    _hogli_python 'from hogli_commands.devbox.coder import get_default_workspace_prefix
print(get_default_workspace_prefix())'
}

_read_reserved_suffixes() {
    _hogli_python 'from hogli_commands.devbox.coder import _RESERVED_LABEL_SUFFIXES
print(" ".join(_RESERVED_LABEL_SUFFIXES))'
}

workspace_prefix() { registry_cached workspace_prefix _read_workspace_prefix; }
reserved_suffixes() { registry_cached reserved_suffixes _read_reserved_suffixes; }
