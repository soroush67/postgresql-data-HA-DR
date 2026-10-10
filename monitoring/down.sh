#!/usr/bin/env bash
# Stop monitoring. --wipe also deletes Prometheus/Grafana data (never the
# database or the backups).
set -euo pipefail
. "$(dirname "$0")/../lib.sh"
cd "$ROOT/monitoring"
if [ "${1:-}" = --wipe ]; then
    "${DC[@]}" down
    docker volume rm pg-monitoring_prometheus-data pg-monitoring_grafana-data 2>/dev/null || true
else "${DC[@]}" down; fi
