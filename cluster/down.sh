#!/usr/bin/env bash
# Stop the cluster. --wipe also deletes data, etcd state AND backups (volumes).
set -euo pipefail
. "$(dirname "$0")/../lib.sh"
cd "$ROOT/cluster"
if [ "${1:-}" = --wipe ]; then "${DC[@]}" down -v; else "${DC[@]}" down; fi
