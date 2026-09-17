# shellcheck shell=bash
# Intents, the dev stack, and proving it actually came up.

REMOTE_HOGLI="./bin/hogli"
REMOTE_PHROCS="./tools/phrocs/dist/phrocs"
# Single-quoted: these expand on the devbox, not here.
# shellcheck disable=SC2016
REMOTE_PROC_STATUS='$HOME/.config/coderv2/dotfiles/proc-status.sh'
# Same search order as the repo's own bin/helpers/worktree-borrow.sh.
# shellcheck disable=SC2016
REMOTE_VENV_EXPR='for v in .flox/cache/venv .venv env; do [ -d "$v" ] && echo "$v" && break; done'
# shellcheck disable=SC2016
REMOTE_FLOX_PATH='PATH="$(printf "%s:" .flox/run/*/bin)$PATH"'
REMOTE_PYTHON="\"\$($REMOTE_VENV_EXPR)/bin/python\""
TEMPORAL_FRONTEND_PORT=7233

# The scopes that bring a checkout's database up to its code. `async` is left
# out: it applies no non-noop migration of its own, and its --check fails on a
# 1.40-era backfill nobody runs locally. `tasks-oauth` and `temporal-schedules`
# are deploy-time concerns and no-ops under DEBUG=1.
MIGRATION_SCOPES="--scope=postgres --scope=clickhouse --scope=persons --scope=cyclotron --scope=behavioral-cohorts --scope=flags-read-store"

# bin/migrate retries the Django step ten times with a doubling backoff, which
# assumes the database is briefly unreachable. On a devbox it is not: the stack
# is verified up before this runs, so a failure is a schema conflict that will
# fail the same way ten times. Ten attempts spend about 25 minutes sleeping;
# three spend nine seconds and still ride out a real hiccup.
MIGRATION_RETRY_ENV="MIGRATE_MAX_RETRIES=3"

default_intents() {
    sed -e 's/#.*//' "$DBX_ROOT/intents.default" | tr '\n' ' ' | tr -s ' ' | sed -e 's/^ //' -e 's/ $//'
}

_generated_config_sha() {
    remote_repo "sha256sum .posthog/.generated/mprocs.yaml 2>/dev/null | cut -d' ' -f1"
}

# Whether a detached phrocs is listening at all, which is a different question
# from whether it is ready: `phrocs wait` exits non-zero for a single crashed
# process, and reading that as "not running" restarts a healthy stack.
_stack_is_up() {
    remote_repo "bash $REMOTE_PROC_STATUS >/dev/null 2>&1; [ \$? -ne 2 ]"
}

# `dev:apply` only rewrites the generated mprocs config; phrocs reads it at
# launch, so a live stack keeps whatever units it started with until restarted.
apply_intents() {
    local intents before after
    intents="$(default_intents)"
    [ -n "$intents" ] || die "$DBX_EXIT_ERROR" "$DBX_ROOT/intents.default lists no intents."

    before="$(_generated_config_sha)"
    remote_repo "$REMOTE_HOGLI dev:apply $intents" >/dev/null \
        || die "$DBX_EXIT_ERROR" "\`hogli dev:apply $intents\` failed on $WORKSPACE_NAME."
    after="$(_generated_config_sha)"
    log "intents: $intents"

    if ! _stack_is_up; then
        log "dev stack is not running; starting it"
        _start_stack
        return 0
    fi
    if [ "$before" != "$after" ]; then
        log "generated stack config changed; restarting"
        remote_repo "$REMOTE_HOGLI stop" >/dev/null || true
        _start_stack
        return 0
    fi
    log "generated stack config unchanged; leaving the running stack alone"
}

_start_stack() {
    remote_repo "$REMOTE_HOGLI start -y -d" \
        || die "$DBX_EXIT_ERROR" "\`hogli start -y -d\` failed on $WORKSPACE_NAME."
}

# Five layers, because none of them alone proves the stack is usable.
# $1 caps how long the container health poll may block.
verify_services() {
    local container_timeout=${1:-300} failed=0

    if remote_repo "WAIT_FOR_DOCKER_TIMEOUT=$container_timeout $REMOTE_HOGLI services:ready temporal" >/dev/null 2>&1; then
        log "containers: healthy (core + temporal)"
    else
        warn "containers: some are not healthy (\`hogli services:ready temporal\`)"
        failed=1
    fi

    # The coarse gate. It cannot stand alone: phrocs's classify() counts
    # `stopped` as ready, which is the steady state of an autostart: false unit.
    if remote_repo "$REMOTE_PHROCS wait --timeout ${DBX_WAIT_TIMEOUT:-600} --json" >/dev/null 2>&1; then
        log "phrocs: no process is crashed or pending"
    else
        warn "phrocs: processes are crashed or still pending (\`$REMOTE_PHROCS wait --json\`)"
        failed=1
    fi

    if remote_repo "bash $REMOTE_PROC_STATUS temporal-worker celery-worker celery-beat"; then
        log "units: temporal-worker, celery-worker and celery-beat are running"
    else
        warn "units: at least one of temporal-worker, celery-worker, celery-beat is not running"
        failed=1
    fi

    # The check that catches the original failure: a worker process that is
    # running but has nothing to talk to. Materializing a view died on
    # ConnectionRefused to this port with every layer above reporting healthy.
    if remote_repo "timeout 5 bash -c '</dev/tcp/127.0.0.1/$TEMPORAL_FRONTEND_PORT'" 2>/dev/null; then
        log "temporal frontend: accepting connections on $TEMPORAL_FRONTEND_PORT"
    else
        warn "temporal frontend: nothing is listening on 127.0.0.1:$TEMPORAL_FRONTEND_PORT"
        failed=1
    fi

    # DEBUG=1 because a bare celery loads production settings and refuses to
    # start on the dev SECRET_KEY before it ever reaches the broker.
    if remote_repo "timeout 60 env DEBUG=1 \"\$($REMOTE_VENV_EXPR)/bin/celery\" -A posthog inspect ping" >/dev/null 2>&1; then
        log "celery: workers answered inspect ping"
    else
        warn "celery: no worker answered \`celery -A posthog inspect ping\`"
        failed=1
    fi

    return "$failed"
}

# Django migrations only, and advisory: `dbx sync` and `dbx up` migrate
# unconditionally, so this is here to explain a box, not to gate one. It reports
# orphans too: a devbox that has served another worktree carries migrations that
# this checkout's code no longer has, which `dbx migrate` cannot undo.
#
# Through hogli, because every manage.py check needs the env it loads:
# migrate_clickhouse --check reads the migrations table out of `default` without
# CLICKHOUSE_DATABASE and dies on UNKNOWN_TABLE. `hogli migrations:check` is no
# use either, since it also runs `run_async_migrations --check`, which fails on
# a 1.40-era backfill local dev never runs.
migration_state() {
    local report state=""
    report="$(remote_repo "$REMOTE_FLOX_PATH $REMOTE_HOGLI migrations:status" 2>/dev/null)" || {
        echo "unknown"
        return 0
    }
    case "$report" in *"Migrations are in sync"*)
        echo "in sync"
        return 0
        ;;
    esac
    case "$report" in *"Pending migrations"*) state="pending" ;; esac
    case "$report" in *"Orphaned migrations"*) state="${state:+$state and }orphaned (run \`hogli migrations:sync\` on the box)" ;; esac
    echo "${state:-unknown}"
}

# Through hogli, which activates the venv bin/migrate's bare `python` needs and
# supplies DEBUG=1. The flox prepend is still ours to add: bin/migrate shells out
# to sqlx for the Rust migrators, sqlx lives only in the flox environment, and an
# ssh command runs no profile that would put it on PATH.
run_migrations() {
    log "applying migrations on $WORKSPACE_NAME"
    remote_repo "$REMOTE_FLOX_PATH $MIGRATION_RETRY_ENV $REMOTE_HOGLI migrations:run $MIGRATION_SCOPES" \
        || die "$DBX_EXIT_ERROR" "Migrations failed on $WORKSPACE_NAME."
}
