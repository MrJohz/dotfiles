#!/usr/bin/env bash
# Back up $HOME to this machine's offsite repository, apply retention, and
# prune once a day.
#
# Runs every two hours. `forget` is cheap and runs every time; `prune` is not
# and is gated to one successful run per calendar day.
set -euo pipefail

conf="${XDG_CONFIG_HOME:-$HOME/.config}/restic"
state="${XDG_STATE_HOME:-$HOME/.local/state}/restic"

if [ ! -r "$conf/env" ]; then
    echo "no $conf/env — run mise bootstrap --prompt-secrets" >&2
    exit 78   # EX_CONFIG
fi

set -a; . "$conf/env"; set +a
mkdir -p "$state"

# Initialise the repository on first run. restic exits 10 specifically for "no
# repository here", so a network or credential failure surfaces as itself
# rather than being mistaken for an empty box.
restic cat config >/dev/null 2>&1 || status=$?
if [ "${status:-0}" -eq 10 ]; then
    echo "no repository at $RESTIC_REPOSITORY — initialising" >&2
    restic init
elif [ "${status:-0}" -ne 0 ]; then
    exit "$status"
fi

restic backup "$HOME" \
    --exclude-file "$conf/exclude" \
    --exclude-caches \
    --exclude-if-present .nobackup \
    --tag auto

restic forget \
    --keep-within 72h \
    --keep-daily 14 \
    --keep-monthly 6 \
    --keep-yearly unlimited \
    --group-by host

# Prune at most once a day. It rewrites pack files and takes an exclusive
# lock, so it must not run on every two-hourly backup.
#
# The stamp is written only after prune succeeds: a failure is retried on the
# next run rather than silently skipped until tomorrow.
stamp="$state/last-prune"
today=$(date +%F)
if [ "$(cat "$stamp" 2>/dev/null || true)" != "$today" ]; then
    restic prune
    echo "$today" > "$stamp"
fi
