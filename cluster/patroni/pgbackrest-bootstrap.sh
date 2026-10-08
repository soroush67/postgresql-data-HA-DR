#!/bin/bash
# Patroni custom bootstrap (PATRONI_BOOTSTRAP=pgbackrest): restore the newest
# backup + all archived WAL, or up to RESTORE_TARGET_TIME (point in time).
set -euo pipefail
args=(--stanza=main --delta)
if [ -n "${RESTORE_TARGET_TIME:-}" ]; then
    args+=(--type=time "--target=${RESTORE_TARGET_TIME}" --target-action=promote)
fi
mkdir -p /var/lib/postgresql/data/pgdata && chmod 0700 /var/lib/postgresql/data/pgdata
echo "pgbackrest restore ${args[*]}"
exec pgbackrest "${args[@]}" restore
