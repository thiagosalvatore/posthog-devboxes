# shellcheck shell=bash
# Bring the devbox checkout to this worktree's tree.
#
# The commit is pushed straight to the box over ssh, never through origin, so a
# local HEAD that was never pushed anywhere still aligns. Uncommitted tracked
# changes follow as a patch. Untracked files are left to mutagen: they do not
# exist on the box, so they create cleanly with no conflict to resolve.

_align_count() {
    [ "$1" -lt 0 ] && echo "unknown" || echo "$1"
}

align_target_sha() { git -C "$WORKTREE_ROOT" rev-parse HEAD; }

align_target_branch() {
    local branch
    branch="$(git -C "$WORKTREE_ROOT" rev-parse --abbrev-ref HEAD)"
    [ "$branch" = "HEAD" ] && branch="devbox-detached"
    echo "$branch"
}

# The commit reaches the box as a bundle rather than a push. `git push` over the
# coder ssh alias stalls in git-receive-pack against this repo, and it would run
# the repo's own pre-push hook -- which refuses outright while you are on master
# and otherwise spends minutes in ci:preflight, neither of which says anything
# about a devbox. A bundle is a plain file: scp it and fetch from it.
_align_deliver() {
    local sha=$1 basis bundle_dir bundle
    if remote_repo "git cat-file -e '$sha'" 2>/dev/null; then
        remote_repo "git update-ref '$ALIGN_REF' '$sha'" \
            || die "$DBX_EXIT_ERROR" "Could not move $ALIGN_REF on $WORKSPACE_NAME."
        return 0
    fi

    # Bundling against what the box already has keeps the transfer to the
    # commits it is actually missing.
    basis="$(remote_repo 'git rev-parse HEAD' 2>/dev/null || true)"
    if [ -z "$basis" ] || ! git -C "$WORKTREE_ROOT" cat-file -e "$basis" 2>/dev/null; then
        basis=""
    fi

    bundle_dir="$(mktemp -d)"
    bundle="$bundle_dir/align.bundle"
    git -C "$WORKTREE_ROOT" update-ref "$LOCAL_ALIGN_REF" "$sha"
    if [ -n "$basis" ]; then
        git -C "$WORKTREE_ROOT" bundle create "$bundle" "$LOCAL_ALIGN_REF" --not "$basis" >/dev/null 2>&1
    else
        log "the devbox shares no history with this worktree; sending the full branch"
        git -C "$WORKTREE_ROOT" bundle create "$bundle" "$LOCAL_ALIGN_REF" >/dev/null 2>&1
    fi
    git -C "$WORKTREE_ROOT" update-ref -d "$LOCAL_ALIGN_REF"

    remote "mkdir -p \"\$(dirname $REMOTE_BUNDLE_PATH)\""
    if ! scp -q "$bundle" "coder.${WORKSPACE_NAME}:.cache/dbx/align.bundle"; then
        rm -rf "$bundle_dir"
        die "$DBX_EXIT_ERROR" "Could not copy the align bundle to $WORKSPACE_NAME."
    fi
    rm -rf "$bundle_dir"

    remote_repo "git fetch --quiet $REMOTE_BUNDLE_PATH '$LOCAL_ALIGN_REF:$ALIGN_REF'" \
        || die "$DBX_EXIT_ERROR" "Could not unbundle $sha on $WORKSPACE_NAME."
}

# Commits that exist only on the box. Unlike its working tree -- which mutagen
# owns and rewrites -- a commit there is work that a reset would destroy.
_align_stranded_commits() {
    local excludes="^$ALIGN_REF"
    remote_repo "git rev-parse --verify --quiet origin/master >/dev/null" && excludes="$excludes ^origin/master"
    remote_repo "git rev-list --count HEAD $excludes"
}

expected_box_changes_file() { echo "$DBX_ROOT/local/expected-box-changes.txt"; }

# Working-tree content on the box that matches neither the tree we are about to
# check out nor the box's own last commit, minus whatever our patch explains and
# minus the paths the box's own boot scripts are known to rewrite.
# A file mutagen already overwrote matches our tree; a file mutagen refused to
# overwrite matches the box's commit; only an edit made on the box matches
# neither.
_align_unexplained_paths() {
    local excused
    excused="$(mktemp)"
    {
        git -C "$WORKTREE_ROOT" diff HEAD --name-only
        grep -vE '^\s*(#|$)' "$(expected_box_changes_file)" 2>/dev/null
    } | sort -u >"$excused"
    comm -12 \
        <(remote_repo "git diff --name-only $ALIGN_REF" | sort -u) \
        <(remote_repo "git diff --name-only HEAD" | sort -u) \
        | comm -23 - "$excused"
    rm -f "$excused"
}

align_plan() {
    local sha branch stranded unexplained
    sha="$(align_target_sha)"
    branch="$(align_target_branch)"
    # The plan compares the box against the target tree, so the target has to be
    # on the box first. Only the scratch ref moves; the checkout is untouched.
    _align_deliver "$sha"
    log "align plan for $WORKSPACE_NAME"
    log "  target:  $sha on $branch"
    log "  box now: $(remote_repo 'git rev-parse HEAD') on $(remote_repo 'git rev-parse --abbrev-ref HEAD')"
    stranded="$(_align_stranded_commits)"
    log "  commits only on the box: $stranded"
    unexplained="$(_align_unexplained_paths)"
    if [ -n "$unexplained" ]; then
        log "  unexplained working-tree paths on the box:"
        printf '%s\n' "$unexplained" | sed 's/^/    /'
    else
        log "  unexplained working-tree paths on the box: 0"
    fi
    log "  patch: $(git -C "$WORKTREE_ROOT" diff HEAD --name-only | wc -l | tr -d ' ') tracked files with uncommitted changes"
}

_align_assert_safe() {
    local stranded unexplained
    stranded="$(_align_stranded_commits)"
    if [ "$stranded" != "0" ]; then
        die "$DBX_EXIT_ALIGN_REFUSED" \
            "The devbox has $stranded commit(s) reachable from neither this worktree's HEAD nor origin/master." \
            "Push or cherry-pick them before aligning, or re-run with --force."
    fi
    unexplained="$(_align_unexplained_paths)"
    if [ -n "$unexplained" ]; then
        warn "Working-tree changes on the box that this align would discard:"
        printf '%s\n' "$unexplained" | sed 's/^/  /' >&2
        die "$DBX_EXIT_ALIGN_REFUSED" \
            "Copy them off the box, or re-run with --force."
    fi
}

_align_checkout() {
    local sha=$1 branch=$2 stamp
    # Nothing to preserve when the box is already on the target commit, and
    # tagging anyway leaves a new ref behind on every run.
    if [ "$(remote_repo 'git rev-parse HEAD')" != "$sha" ]; then
        stamp="devbox-prealign-$(date +%s)"
        # update-ref, not `git tag`: the box signs tags, and a signed tag is an
        # annotated one, which opens an editor over a non-interactive ssh.
        remote_repo "git update-ref 'refs/tags/$stamp' HEAD" \
            || die "$DBX_EXIT_ERROR" "Could not tag the devbox's pre-align HEAD."
        log "tagged the box's pre-align HEAD as $stamp"
    fi
    ALIGN_MUTATED=1
    # --force discards the working-tree content mutagen wrote; the tag above is
    # what makes that recoverable. Detach first so no named branch is clobbered.
    remote_repo "git checkout --force --detach '$sha' >/dev/null 2>&1 && git checkout -B '$branch' '$sha' >/dev/null 2>&1" \
        || die "$DBX_EXIT_ERROR" "Could not check $sha out on the devbox."
}

# A failed apply leaves the box holding the target commit with some of our
# uncommitted work missing, which is an inconsistent tree. Resuming the sync
# onto it would paper over that, so we stop and keep the sync paused.
_align_apply_patch() {
    local patch_file
    git -C "$WORKTREE_ROOT" diff HEAD --binary --quiet && return 0
    patch_file="$DBX_HOME/patches/${WORKSPACE_NAME}-$(date +%s).patch"
    mkdir -p "$(dirname "$patch_file")"
    git -C "$WORKTREE_ROOT" diff HEAD --binary >"$patch_file"
    if remote_stdin "cd '$REMOTE_REPO_PATH' && git apply -" <"$patch_file"; then
        rm -f "$patch_file"
        return 0
    fi
    die "$DBX_EXIT_ALIGN_REFUSED" \
        "Applying this worktree's uncommitted changes to the devbox failed." \
        "The patch is at $patch_file and the sync is left paused." \
        "Resolve it on the box, then run \`dbx sync\`."
}

# Ordering is what keeps this from causing the conflict storm it exists to
# prevent. --pause/--resume, never --terminate: terminating discards the
# ancestor snapshot, and the next scan then sees every differing file as
# "created on both sides", which is the no-ancestor case one-way-safe refuses to
# resolve. With no session at all, align runs first so the initial scan compares
# two trees that already match.
align_run() {
    local force=$1 sha branch before after had_session
    sha="$(align_target_sha)"
    branch="$(align_target_branch)"

    had_session=0
    before=-1
    ALIGN_MUTATED=0
    if session_exists; then
        had_session=1
        # A paused session reports no conflicts, so its count says nothing about
        # the state align is meant to be measured against. Record it as unknown
        # rather than as zero.
        [ "$(session_state)" = "paused" ] || before="$(session_conflicts)"
        sync_pause
        # A failure before the checkout starts has changed nothing, so leaving
        # the sync paused would just strand it. Once the checkout has begun the
        # tree is inconsistent, and staying paused is the point.
        trap '[ "$ALIGN_MUTATED" = "0" ] && sync_resume' EXIT
    fi

    _align_deliver "$sha"
    [ "$force" = "1" ] || _align_assert_safe
    _align_checkout "$sha" "$branch"
    _align_apply_patch

    trap - EXIT
    if [ "$had_session" = "1" ]; then
        sync_resume
        sync_flush
        sync_wait_settled
        after="$(session_conflicts)"
    else
        after=-1
    fi

    registry_record_align "$WORKTREE_ROOT" "$sha" "$before" "$after"
    log "aligned $WORKSPACE_NAME to $sha on $branch (conflicts $(_align_count "$before") -> $(_align_count "$after"))"
    if [ "$before" -ge 0 ] && [ "$after" -gt "$before" ]; then
        warn "align raised the conflict count. The pause/align/resume ordering is not holding; inspect \`dbx status\`."
    fi
}
