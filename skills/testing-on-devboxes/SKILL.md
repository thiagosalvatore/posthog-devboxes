---
name: testing-on-devboxes
description: Run a PostHog worktree's code on a Coder devbox so it can be exercised end to end, then tear the box down. Use when a change needs the app actually running to test — browser and Playwright work, a scene or API you have to click through, reproducing a bug that needs live data — and when asked to start, sync, align, inspect or destroy a devbox, or when `dbx`, `hogli devbox:*` or `hogli devbox:sync` appears in the request. Covers the one-worktree-one-box binding, the alignment that keeps mutagen from filling up with conflicts, what "the stack is up" actually has to mean, and when to destroy rather than stop.
---

# Testing on a devbox

A devbox runs the dev stack so your laptop does not have to. `dbx` drives one from a
worktree: it creates the box, makes the box's checkout match your tree, syncs your edits,
selects the dev-stack units, and migrates.

Run every command from inside the worktree you are testing. `dbx -C <path> <command>` acts
on a worktree somewhere else.

## Getting a box up

```sh
dbx up          # create or resume, align, sync, apply intents, verify, migrate
dbx status      # what is actually running right now
```

`dbx up` is idempotent. Run it again after a rebase, or whenever you are unsure of the
state, instead of reasoning about what changed.

To drive the app in a browser, forward it first and then browse `localhost`:

```sh
hogli devbox:forward     # PostHog UI -> localhost
```

## The daily loop

Mutagen syncs your edits to the box continuously once `dbx up` has created the session, so
ordinary editing needs no command. Reach for one when:

| Situation | Command |
|---|---|
| You committed, rebased, or switched branches | `dbx sync` |
| Something looks stale and you want the facts | `dbx status` |
| You changed which products you are working on | `dbx services` |
| A one-off command on the box | `dbx exec -- <cmd>` |

## Tearing it down

```sh
hogli devbox:destroy     # done with the task: takes the disk too
hogli devbox:stop        # coming back soon: keeps the disk, stops the compute
```

Destroy when the task is finished, not between two runs in one session. A rebuild costs a
fresh AMI plus a full dependency install, and the first Rust build after that is long.

**Only destroy a box you created.** Look before you do. `dbx align --dry-run` answers it:
`commits only on the box` and `unexplained working-tree paths on the box` should both read
`0`. Raw git over `dbx exec` is worse for this — your own unpushed branch counts as "not on
a remote" and reads as stranded work when it is safely on the laptop. Note that `~` in a
`dbx exec` command is expanded by your local shell, so remote paths must be absolute.

## Four things that will otherwise surprise you

### One worktree, one box, and `dbx` is the only thing that checks

`hogli devbox:sync` looks a session up by label and returns before it ever reads which
local checkout you are in. Run it from worktree B against a box serving worktree A and it
prints "Sync already running", exits 0, and keeps serving A while you edit B.

`dbx` compares the live session's path against the worktree you are in and refuses with
exit 3, printing both. `dbx sync --repoint` moves the box to the worktree you are in.

So: if a command exits 3, you are not in the worktree you think you are.

### A drifted checkout produces a conflict storm, and align is the cure

Mutagen ignores `.git`, so the box keeps its own checkout. Once it drifts far enough, every
differing file reads as "created on both sides" and `one-way-safe` refuses to overwrite the
remote. A checkout 40 commits behind produced 150 conflicts; one much further behind
produced 428.

`dbx align` removes the drift rather than resolving it: it sends your HEAD to the box as a
git bundle, checks it out there, and applies your uncommitted tracked changes as a patch.
`dbx sync` and `dbx up` align first, so you rarely call it directly. `dbx align --dry-run`
prints the plan without touching the checkout.

Align refuses with exit 5 when the box holds commits reachable from neither your HEAD nor
`origin/master`, or content matching neither your tree nor the box's own last commit. That
is work done on the box. Copy it off, or pass `--force` once you are sure it is disposable.
Align tags `devbox-prealign-<epoch>` before it touches anything.

### "The stack started" does not mean the stack works

`phrocs wait` counts `stopped` as ready, which is exactly an `autostart: false` unit, so it
cannot prove a service is running. `dbx status` layers five checks instead: container
health, the phrocs verdict, per-unit state from the phrocs socket, a direct probe of the
Temporal frontend port, and a Celery inspect ping.

Read the per-unit lines, not just the summary. A yellow `phrocs:` line with
`temporal-worker running` beneath it means one unrelated unit is down, which is usually
fine. The reverse is not.

### Commands on the box must run inside flox

An ssh command runs no login profile, so `pnpm`, `uv`, `sqlx` and `node` are all absent and
most of the stack dies on "command not found". A `PATH` prepend is not a substitute:
`node-rdkafka` then fails to load `liblz4.so.1`, because activation sets up shared-library
resolution that no `PATH` entry provides.

`dbx` wraps every remote command in `flox activate --` already. This matters when you ssh
in by hand: run `flox activate -- bash -c '<cmd>'` from `~/posthog`, or use `dbx exec`.

## When something is wrong

Start with `dbx doctor`. It checks the ssh config block, the mutagen daemon, whether
`dotfiles_uri` is set, and whether your mutagen ignore list has drifted from the one this
repo expects. It is read-only.

- **Conflicts above zero.** `dbx status` classifies them against `local/expected-conflicts.txt`.
  Mutagen caps its inline path list at ten while reporting the true total, so a truncated
  list is flagged rather than guessed at. Unexpected conflicts usually mean the box drifted:
  `dbx sync`.
- **A box that never ran its boot scripts.** Coder applies `dotfiles_uri` when it *builds* a
  workspace. A box already running when you set it needs `hogli devbox:stop`, then `dbx up`.
  `dbx` copies the scripts it calls to the box itself, so it works either way.
- **Migrations.** `dbx sync` and `dbx up` migrate as their last step; `--no-migrate` skips
  it. `dbx status` reports orphaned migrations too, which `dbx migrate` cannot undo: a box
  that served another worktree carries migrations this checkout's code no longer has.
- **A unit down after all that.** Read its log on the box under
  `~/posthog/.posthog/.generated/logs/<unit>.log`. `embedding-worker` panics without an
  `OPENAI_API_KEY` secret and needs no fixing.
