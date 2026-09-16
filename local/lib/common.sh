# shellcheck shell=bash
# Shared state, logging and remote execution for `dbx`.
#
# Laptop scripts fail loudly: an engineer is waiting on the prompt, so a broken
# step must stop and say so. The devbox scripts do the opposite on purpose --
# they log and retry on the next workspace start, because nobody is watching.

DBX_EXIT_ERROR=1
DBX_EXIT_USAGE=2
DBX_EXIT_BINDING=3
DBX_EXIT_NOT_READY=4
DBX_EXIT_ALIGN_REFUSED=5

REMOTE_REPO_PATH=/home/coder/posthog
ALIGN_REF=refs/heads/devbox-align
LOCAL_ALIGN_REF=refs/dbx/align
# shellcheck disable=SC2016
REMOTE_BUNDLE_PATH='$HOME/.cache/dbx/align.bundle'
# Single-quoted: $HOME is expanded by the devbox's shell, not this one.
# shellcheck disable=SC2016
DOTFILES_READY_STAMP='$HOME/.coder-dotfiles-ready'
DOTFILES_URI=https://github.com/thiagosalvatore/posthog-devboxes.git

DBX_HOME="${DBX_HOME:-$HOME/.config/posthog/dbx}"
HOGLI_DEVBOX_CONFIG="${HOGLI_DEVBOX_CONFIG:-$HOME/.config/posthog/hogli_devbox.json}"
HOGLI_MUTAGEN_CONFIG="${HOGLI_MUTAGEN_CONFIG:-$HOME/.hogli/mutagen.yml}"

log() { printf 'dbx: %s\n' "$*"; }
warn() { printf 'dbx: %s\n' "$*" >&2; }

die() {
    local code=$1
    shift
    local line
    for line in "$@"; do printf 'dbx: %s\n' "$line" >&2; done
    exit "$code"
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "$DBX_EXIT_ERROR" "\`$1\` is not on PATH."
}

# The hogli-managed binaries take precedence: `hogli devbox:setup` installs them
# there and pins their versions, so a stray PATH copy must not win.
coder_bin() {
    if [ -x "$HOME/.hogli/bin/coder" ]; then
        echo "$HOME/.hogli/bin/coder"
    else
        command -v coder || die "$DBX_EXIT_ERROR" "\`coder\` is not installed. Run \`hogli devbox:setup\`."
    fi
}

mutagen_bin() {
    if [ -x "$HOME/.hogli/bin/mutagen" ]; then
        echo "$HOME/.hogli/bin/mutagen"
    else
        command -v mutagen || die "$DBX_EXIT_ERROR" "\`mutagen\` is not installed. Run \`hogli devbox:sync\` once."
    fi
}

# `bin/hogli` rather than a PATH `hogli`: it activates the checkout's own venv,
# so the resolved hogli always matches the worktree dbx is acting on.
hogli() {
    (cd "$WORKTREE_ROOT" && ./bin/hogli "$@")
}

# A single string so the remote login shell does the parsing; -n keeps ssh from
# consuming the caller's stdin inside a loop.
remote() {
    ssh -n -o BatchMode=yes "coder.${WORKSPACE_NAME}" "$1"
}

# Same, but stdin flows through to the remote command (`git apply -`).
remote_stdin() {
    ssh -o BatchMode=yes "coder.${WORKSPACE_NAME}" "$1"
}

remote_repo() {
    remote "cd '$REMOTE_REPO_PATH' && $1"
}

ssh_alias_resolves() {
    ssh -G "coder.${WORKSPACE_NAME}" 2>/dev/null | grep -qi '^proxycommand .'
}

confirm_ssh_alias() {
    ssh_alias_resolves || die "$DBX_EXIT_NOT_READY" \
        "ssh has no ProxyCommand for coder.${WORKSPACE_NAME}." \
        "Run \`hogli devbox:setup\` to install the Coder ssh config block."
}

json_field() {
    python3 -c 'import json,sys; print(json.loads(sys.stdin.read() or "{}").get(sys.argv[1]) or "")' "$1"
}
