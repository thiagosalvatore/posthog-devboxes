#!/usr/bin/env bash
# One-time laptop setup for `dbx`: put it on PATH, tell hogli which dotfiles repo
# to hand new devboxes, and add the ignore paths hogli's packaged defaults miss.
# Idempotent; safe to re-run after pulling this repo.
set -euo pipefail

DBX_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
BIN_DIR="${DBX_BIN_DIR:-$HOME/.local/bin}"
HOGLI_DEVBOX_CONFIG="${HOGLI_DEVBOX_CONFIG:-$HOME/.config/posthog/hogli_devbox.json}"
HOGLI_MUTAGEN_CONFIG="${HOGLI_MUTAGEN_CONFIG:-$HOME/.hogli/mutagen.yml}"
DOTFILES_URI=https://github.com/thiagosalvatore/posthog-devboxes.git

log() { printf 'dbx: %s\n' "$*"; }

mkdir -p "$BIN_DIR"
ln -sf "$DBX_ROOT/local/dbx" "$BIN_DIR/dbx"
log "linked $BIN_DIR/dbx -> $DBX_ROOT/local/dbx"
case ":$PATH:" in
*":$BIN_DIR:"*) ;;
*) log "note: $BIN_DIR is not on your PATH" ;;
esac

# Symlinked, not copied, so a `git pull` here updates the agents' copy too.
for agent_dir in "$HOME/.claude/skills" "$HOME/.codex/skills"; do
    [ -d "$(dirname "$agent_dir")" ] || continue
    mkdir -p "$agent_dir"
    for skill in "$DBX_ROOT"/skills/*/; do
        [ -d "$skill" ] || continue
        ln -sfn "${skill%/}" "$agent_dir/$(basename "$skill")"
        log "linked $agent_dir/$(basename "$skill")"
    done
done

python3 - "$HOGLI_DEVBOX_CONFIG" "$DOTFILES_URI" <<'PY'
import json
import pathlib
import sys

path, uri = pathlib.Path(sys.argv[1]), sys.argv[2]
try:
    config = json.loads(path.read_text())
except Exception:
    config = {}
if config.get("dotfiles_uri") == uri:
    print(f"dbx: dotfiles_uri already set to {uri}")
else:
    config["dotfiles_uri"] = uri
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(config, indent=2) + "\n")
    print(f"dbx: set dotfiles_uri={uri} in {path}")
PY

if [ ! -f "$HOGLI_MUTAGEN_CONFIG" ]; then
    log "no $HOGLI_MUTAGEN_CONFIG yet; run \`hogli devbox:sync\` once to seed it, then re-run this script"
    exit 0
fi

# hogli seeds this file from its packaged defaults and refuses to overwrite a
# copy you have edited, so the extra paths have to be appended here rather than
# shipped upstream. The indent is read off the file so it survives a reformat.
appended=0
indent="$(grep -oE "^[[:space:]]+- '" "$HOGLI_MUTAGEN_CONFIG" | tail -1 | sed "s/- '//")"
while IFS= read -r path; do
    case "$path" in '' | '#'*) continue ;; esac
    if grep -qE "^[[:space:]]*- '?${path}'?[[:space:]]*$" "$HOGLI_MUTAGEN_CONFIG"; then
        continue
    fi
    printf "%s- '%s'\n" "$indent" "$path" >>"$HOGLI_MUTAGEN_CONFIG"
    log "added ignore '$path' to $HOGLI_MUTAGEN_CONFIG"
    appended=$((appended + 1))
done <"$DBX_ROOT/local/mutagen-extra-ignores.txt"

if [ "$appended" -gt 0 ]; then
    log "mutagen reads its ignore list when a session is created, so existing sessions keep the old one."
    log "Run \`dbx sync --repoint\` in each affected worktree to pick the new paths up."
else
    log "mutagen ignores: already up to date"
fi
