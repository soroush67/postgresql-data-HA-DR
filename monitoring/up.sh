#!/usr/bin/env bash
# Start monitoring for the single node. Idempotent.
#   Grafana    http://127.0.0.1:3000   (admin / GRAFANA_ADMIN_PASSWORD in ../.env)
#   Prometheus http://127.0.0.1:9090   (alerts: /alerts)
set -euo pipefail
. "$(dirname "$0")/../lib.sh"
ensure_env
# passwords added to an existing .env (ensure_env never rewrites it)
for v in MONITOR_PASSWORD GRAFANA_ADMIN_PASSWORD; do
    grep -q "^$v=" "$ROOT/.env" || echo "$v=$(gen 24)" >> "$ROOT/.env"
done
set -a; . "$ROOT/.env"; set +a
require_space 5 "starting monitoring"

[ "$(docker inspect -f '{{.State.Running}}' pg-single 2>/dev/null)" = true ] || {
    echo "ERROR: pg-single is not running - start it first: ../single/up.sh" >&2; exit 1; }

# read-only monitoring role (pg_monitor = all pg_stat_* views incl. pg_stat_statements)
docker exec -i -u postgres pg-single psql -X -q -v ON_ERROR_STOP=1 -d postgres \
     -v pw="$MONITOR_PASSWORD" -v db="$APP_DB" <<'SQL'
SELECT NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'monitor') AS create_role \gset
\if :create_role
CREATE ROLE monitor LOGIN;
\endif
ALTER ROLE monitor WITH LOGIN PASSWORD :'pw' CONNECTION LIMIT 5;
GRANT pg_monitor TO monitor;
GRANT CONNECT ON DATABASE :"db" TO monitor;
SQL

cd "$ROOT/monitoring"
"${DC[@]}" up -d --build
for _ in $(seq 1 60); do
    curl -fsS -o /dev/null http://127.0.0.1:9090/-/ready 2>/dev/null &&
    curl -fsS -o /dev/null http://127.0.0.1:3000/api/health 2>/dev/null && break
    sleep 2
done
echo
echo "Monitoring is up:"
echo "  Grafana    http://${BIND_ADDRESS}:3000   admin / $GRAFANA_ADMIN_PASSWORD"
echo "  Prometheus http://${BIND_ADDRESS}:9090   (targets: /targets, alerts: /alerts)"
