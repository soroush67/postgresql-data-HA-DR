#!/usr/bin/env bash
# Stop the single node. --wipe also deletes data AND backups (volumes).
set -euo pipefail
. "$(dirname "$0")/../lib.sh"
cd "$ROOT/single"
if [ "${1:-}" = --wipe ]; then "${DC[@]}" down -v; else "${DC[@]}" down; fi
