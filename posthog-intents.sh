#!/usr/bin/env bash
# Apply the devbox's dev-stack intents in ~/posthog. Cold-start fallback for the
# laptop's `dbx services`, and the recovery path after `hogli nuke` resets the
# selection (the `slim` alias runs this).
# Uses bin/hogli because the boot context has no flox shell.
set -uo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POSTHOG_DIR="${POSTHOG_DIR:-$HOME/posthog}"
HOGLI="$POSTHOG_DIR/bin/hogli"
[ -x "$HOGLI" ] || { echo "coder-dotfiles: $HOGLI not found, skipping intents"; exit 0; }

INTENTS=()
read -r -a INTENTS <<< "$(sed -e 's/#.*//' "$DOTFILES_DIR/intents.default" | tr '\n' ' ')"
[ "${#INTENTS[@]}" -gt 0 ] || { echo "coder-dotfiles: intents.default is empty, skipping intents"; exit 0; }

source "$DOTFILES_DIR/wait-for.sh"
wait_for "posthog checkout pull" 900 checkout_ready || exit 0

cd "$POSTHOG_DIR" || exit 0
"$HOGLI" dev:apply "${INTENTS[@]}" \
  && echo "coder-dotfiles: intents applied (${INTENTS[*]})" \
  || echo "coder-dotfiles: intents apply FAILED (will retry next start)"
