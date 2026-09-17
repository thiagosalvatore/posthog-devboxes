# coder-dotfiles

Personal tooling for PostHog Coder devboxes, in two halves.

- **Runs on the devbox.** Coder clones this repo onto every workspace and runs `install.sh` on each start.
- **Runs on your laptop.** `local/dbx` drives a devbox from a worktree: start it, align its checkout, sync, select the dev stack, migrate.

## Runs on your laptop

`dbx` runs a PostHog worktree's code on a devbox so your machine does not have to run the
stack. It is one command to get a box working and one to keep it that way.

### Install

```bash
bash local/bootstrap.sh
```

It links `local/dbx` into `~/.local/bin`, installs the `testing-on-devboxes` skill for
Claude Code and Codex, saves this repo as the `dotfiles_uri` new devboxes clone, and adds
the ignore paths hogli's packaged mutagen defaults miss. Re-run it after a `git pull`.

Prerequisites are whatever `hogli devbox:setup` installs: the Coder CLI, a login, and the
`Host coder.*` block in your ssh config. `dbx doctor` tells you if any of it is missing.

### Get a box working

From inside the worktree you want to test:

```bash
dbx up
```

That creates the devbox if it does not exist, brings the box's checkout to your tree, starts
the file sync, selects the dev-stack units, verifies they are actually up, and migrates. On a
brand-new box expect a long first run: a fresh AMI, a full dependency install, and a cold
Rust build.

Then check what you got, and put the app on localhost so a browser can reach it:

```bash
dbx status
hogli devbox:forward
```

`dbx up` is idempotent. Re-run it after a rebase, or any time you are unsure of the state,
rather than working out what changed.

### While you work

Your edits sync continuously once the session exists, so ordinary editing needs no command.

| When | Run |
|---|---|
| You committed, rebased, or switched branches | `dbx sync` |
| Something looks stale | `dbx status` |
| You changed which products you work on (edit `intents.default`) | `dbx services` |
| You want one command on the box | `dbx exec -- <cmd>` |
| Anything is broken | `dbx doctor` |

### Finish up

```bash
hogli devbox:destroy    # done with the task; takes the 100GB disk with it
hogli devbox:stop       # back tomorrow; keeps the disk, stops the compute
```

Check for work stranded on the box before destroying. `dbx align --dry-run` answers it
directly: `commits only on the box` and `unexplained working-tree paths on the box` should
both read `0`.

```bash
dbx align --dry-run
```

### Every command

Run from inside a worktree. `-C <path>` acts on a worktree somewhere else.

| Command | Does |
|---|---|
| `dbx up` | Start the box, align it, sync, apply intents, verify services, migrate |
| `dbx sync` | Guard the worktree binding, align, flush, report conflicts, migrate |
| `dbx align` | Bring the devbox checkout to this worktree's tree (`--dry-run` prints the plan) |
| `dbx status` | Label, box state, unexpected conflicts, migration state, per-service verdict |
| `dbx services` | Apply the intents, restart if the generated config changed, verify |
| `dbx migrate` | Migrations only (schema scopes; see below) |
| `dbx exec -- <cmd>` | `hogli devbox:exec` with the box name filled in |
| `dbx doctor` | ssh block, mutagen daemon, `dotfiles_uri`, ignore-list drift |

Flags: `--workspace <name>` binds this worktree to a named box, `--repoint` moves a box to
the worktree you are in, `--no-migrate` skips the migration step, `--force` aligns over
changes made on the box, `--dry-run` prints an align plan.

Exit codes: `2` bad arguments, `3` the box serves a different worktree, `4` the box is not
reachable, `5` align refused.

### For agents

`skills/testing-on-devboxes/` is a skill covering this workflow, installed into
`~/.claude/skills` and `~/.codex/skills` by `local/bootstrap.sh` as a symlink, so it tracks
the repo. Clone this repo and run bootstrap to pick it up.

## How it works

### One worktree, one devbox

Every subcommand resolves the worktree to one box, in this order: `--workspace`, the binding recorded in `~/.config/posthog/dbx/registry.json`, a live sync session already serving this worktree, then a name derived from the directory. Symlinks resolve first, so the aliases under `~/conductor/workspaces/posthog/` that point at one worktree all reach the same box.

`dbx` refuses to act on a box whose sync serves a different worktree, and prints both paths. `hogli devbox:sync` cannot: it looks a session up by label and returns before it reads the local checkout path, so from the wrong worktree it prints "Sync already running" and exits 0 while still serving the other one. `dbx sync --repoint` moves the box to the worktree you are in.

### Alignment

Mutagen ignores `.git`, so the devbox keeps an independent checkout. Once it drifts far enough, every differing file reads as "created on both sides" and `one-way-safe` refuses to overwrite the remote: 428 conflicts from one stale checkout.

`dbx align` removes the drift instead of resolving it. It sends your HEAD to the box as a git bundle over ssh, so the commit never has to reach `origin`, checks it out there, and applies your uncommitted tracked changes as a patch. Untracked files are left to mutagen, which creates them cleanly.

A bundle rather than a `git push`: `git push` over the coder ssh alias stalls in `git-receive-pack` against this repo, and it runs the repo's own `pre-push` hook, which refuses outright while you are on `master` and otherwise spends minutes in `ci:preflight`. Neither says anything about a devbox. A bundle is a plain file: `scp` it, then `git fetch` from it.

The sync is paused for the duration and resumed after, never terminated: terminating discards the ancestor snapshot, and the next scan is then exactly the no-ancestor case that produces the storm. With no session yet, align runs first so the initial scan compares two trees that already match.

Align refuses (exit 5) when the box holds commits reachable from neither your HEAD nor `origin/master`, or working-tree content matching neither your tree nor the box's own last commit. It tags `devbox-prealign-<epoch>` before touching the checkout. Every run records the conflict count before and after in the registry, so a positive delta shows the ordering above is wrong.

### Migrations

`dbx sync` and `dbx up` migrate the devbox database as their last step; `--no-migrate` skips it.

They apply the schema scopes only: `postgres`, `clickhouse`, `persons`, `cyclotron`, `behavioral-cohorts`, `flags-read-store`. `async` is left out: it applies no non-noop migration of its own, and its `--check` fails on a 1.40-era backfill nobody runs locally. `tasks-oauth` and `temporal-schedules` are deploy-time concerns and no-ops under `DEBUG=1`.

Every remote command runs inside `flox activate`. `bin/migrate` shells out to `sqlx` for the Rust migrators, `sqlx` exists only inside flox, and an ssh command runs no profile that would set it up. A `PATH` prepend is not a substitute: it finds the binaries, and `node-rdkafka` then fails to load `liblz4.so.1`, because activation sets up shared-library resolution no `PATH` entry provides. Without it most of the dev stack dies on "command not found".

`dbx status` reports pending Django migrations only, and reports them advisorily: `sync` and `up` migrate whether or not it says anything.

### Conflicts

`dbx status` counts conflicts against `local/expected-conflicts.txt` and reports the rest. Mutagen caps the inline path list at 10 while reporting the true total separately, so a truncated list is flagged rather than classified.

## Runs on the devbox

Wired up once via `hogli devbox:setup --configure-dotfiles`, or by `local/bootstrap.sh`.

- Selects the dev-stack intents from `intents.default` (`posthog-intents.sh`, backgrounded). `hogli nuke` resets the selection; run `slim` to re-apply. `dbx services` applies the same file from the laptop
- Serves per-process state over the phrocs socket (`proc-status.sh`). `phrocs wait` cannot answer this: its `classify()` counts `stopped` as ready, which is exactly the steady state of an `autostart: false` unit
- Clones the PostHog repo landscape (`clone-repos.sh`, backgrounded, shallow, idempotent)
- Adds shell aliases (`gcm`, `gcmm`, `gpp`, `slim`) via a managed block in `~/.bash_aliases`
- Refreshes phrocs from the `phrocs-latest` release into `tools/phrocs/dist` (`install-phrocs.sh`, backgrounded). The image bakes a stale build that fails `hogli start` units with a bash syntax error, and hogli never checks the version. Wait for `~/.coder-dotfiles-phrocs.log` to say `refreshed` before the first `hogli start`
- Points git at `gh` for HTTPS credentials (`gh auth setup-git`), so pushes do not hang on a username prompt. Needs the `GH_TOKEN` secret
- Reapplies git commit-signing config from the `POSTHOG_GIT_SIGNING_KEY` secret if the template's boot-time bootstrap raced and left the box unconfigured
- Merges an `env` block into `~/.claude/settings.json` (`claude-settings.py`): LLM Analytics session capture and the PostHog MCP exec allow-list
- Installs `~/.claude/skills/` from `claude/skills/`, currently the `phs` skills-store bridge
- Installs the user-level agent skills from `mattpocock/skills` and `find-skills` from `vercel-labs/skills` into `~/.claude/skills` (`install-agent-skills.sh`, backgrounded, non-interactive via `npx skills add -g -a claude-code -s '*' -y`). Skipped once installed; refresh with `npx skills update -g -y`
- Installs the Claude Code marketplace and plugins (`install-claude-plugins.sh`, backgrounded): `posthog` and `slack` user-scoped, `typescript-lsp` project-scoped in `~/posthog`
- Writes `~/.coder-dotfiles-ready` as its last line. `install.sh` runs under `set -euo pipefail`, so the stamp exists only when every step succeeded, and the laptop polls that fact instead of guessing from a file's age

Logs: `~/.coder-dotfiles-clone.log`, `~/.coder-dotfiles-plugins.log`, `~/.coder-dotfiles-intents.log`, `~/.coder-dotfiles-phrocs.log`, and `~/.coder-dotfiles-skills.log`.

## Still manual on a new box

- **MCP OAuth.** After the plugins install, `claude mcp list` shows `! Needs authentication` — the posthog and slack servers use OAuth. Auth via `/mcp`, or copy the `mcpOAuth` block of `~/.claude/.credentials.json` from a box that is already authed (that block only; account refresh tokens rotate, so sharing `claudeAiOauth` invalidates the other boxes).
- **Claude Code login.** If the `CLAUDE_CODE_OAUTH_TOKEN` secret has gone stale, a fresh box 401s even though the env var is set. `/login` once on the box, or refresh the secret with `claude setup-token` + `hogli devbox:setup --configure-claude`.
- **Dotfiles on a box that predates them.** Coder applies `dotfiles_uri` when it builds a workspace. A box already running when you set it needs `hogli devbox:stop` then `dbx up`. `dbx` copies the scripts it calls to the box itself, so it works either way.

See `/phs alex-lebedev-devbox` for the full bring-up checklist.

## Rules

- Keep `install.sh` idempotent — it runs on every start
- Laptop scripts use `set -euo pipefail` and fail loudly. Devbox scripts log the failure and retry on the next start: right at an unattended boot, wrong when someone is waiting at a prompt
- No secrets in this repo (it is public); secrets go in `hogli devbox:secret:set`. The `POSTHOG_API_KEY` in `claude-settings.py` is a public write-only ingest key, not a secret
- Don't duplicate what the platform already handles: git identity, Claude token, gh auth
- Anything slow or network-bound gets backgrounded from `install.sh` so workspace start isn't blocked
- Coder runs dotfiles before the template's bootstrap finishes (claude install, `~/posthog` pull). Background scripts poll for their prerequisite via `wait-for.sh` instead of assuming it exists
- `intents.default` is the one source of truth for the dev stack; both halves read it
