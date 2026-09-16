#!/usr/bin/env bash
# Applied automatically by Coder on devbox creation/restart (via hogli devbox:setup --configure-dotfiles).
# Must stay idempotent: runs on every workspace start.
set -euo pipefail

# --- Shell aliases (managed block, won't clobber manual additions) ---
if ! grep -q '# >>> coder-dotfiles >>>' ~/.bash_aliases 2>/dev/null; then
  cat >> ~/.bash_aliases << 'EOF'
# >>> coder-dotfiles >>>
alias gcm='git checkout master'
alias gcmm='git checkout main'
alias gpp='git pull'
# Re-select the dev-stack intents after `hogli nuke` resets them.
alias slim='bash ~/.config/coderv2/dotfiles/posthog-intents.sh'
# Ghostty's TERM has no terminfo on the box, which breaks clear/less/vim.
[ "$TERM" = xterm-ghostty ] && export TERM=xterm-256color
# <<< coder-dotfiles <<<
EOF
fi

# --- Commit signing safety net ---
# The posthog-linux template configures signing from the POSTHOG_GIT_SIGNING_KEY
# secret at boot, but its bootstrap can race ("Bootstrap did not complete before
# Git identity sync") and leave the box unsigned. Reapply if that happened.
if [ -n "${POSTHOG_GIT_SIGNING_KEY:-}" ] && [ "$(git config --global --get commit.gpgsign || true)" != "true" ]; then
  git config --global gpg.format ssh
  git config --global user.signingkey "key::${POSTHOG_GIT_SIGNING_KEY#key::}"
  git config --global commit.gpgsign true
  git config --global tag.gpgsign true
  echo "coder-dotfiles: reapplied git signing config (template bootstrap had not)"
fi

# --- git credentials over HTTPS ---
# The box ships gh logged in via the GH_TOKEN secret, but git has no credential helper,
# so an HTTPS push hangs on a username prompt. Point git at gh. Idempotent.
if gh auth status >/dev/null 2>&1; then
  gh auth setup-git || echo "coder-dotfiles: gh auth setup-git FAILED"
else
  echo "coder-dotfiles: gh not logged in (GH_TOKEN secret missing?), skipping git credential helper"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Claude Code personal config ---
# Both steps are fast and offline, and must land before the backgrounded plugin
# install: that also rewrites settings.json, and interleaving two read-modify-write
# passes over the same file can drop whichever key was written first.
python3 "$SCRIPT_DIR/claude-settings.py" || echo "coder-dotfiles: claude settings merge FAILED"

mkdir -p ~/.claude/skills
cp -R "$SCRIPT_DIR/claude/skills/." ~/.claude/skills/ \
  || echo "coder-dotfiles: claude skills copy FAILED"

# --- Background work ---
# None block workspace start: ~5 repo clones, a marketplace clone plus 3 plugin installs, the intent selection, a phrocs refresh, and the agent skills install.
nohup bash "$SCRIPT_DIR/clone-repos.sh" >> "$HOME/.coder-dotfiles-clone.log" 2>&1 &
nohup bash "$SCRIPT_DIR/install-claude-plugins.sh" >> "$HOME/.coder-dotfiles-plugins.log" 2>&1 &
nohup bash "$SCRIPT_DIR/posthog-intents.sh" >> "$HOME/.coder-dotfiles-intents.log" 2>&1 &
nohup bash "$SCRIPT_DIR/install-phrocs.sh" >> "$HOME/.coder-dotfiles-phrocs.log" 2>&1 &
nohup bash "$SCRIPT_DIR/install-agent-skills.sh" >> "$HOME/.coder-dotfiles-skills.log" 2>&1 &

# Last line on purpose. `set -euo pipefail` means the stamp only appears when
# every step above succeeded, so the laptop can poll a fact instead of guessing
# from the age of a file the AMI happens to carry.
date -u +%Y-%m-%dT%H:%M:%SZ > ~/.coder-dotfiles-ready

echo "coder-dotfiles: install.sh done (repo clones -> ~/.coder-dotfiles-clone.log, claude plugins -> ~/.coder-dotfiles-plugins.log, intents -> ~/.coder-dotfiles-intents.log, phrocs -> ~/.coder-dotfiles-phrocs.log, skills -> ~/.coder-dotfiles-skills.log)"
