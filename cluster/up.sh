#!/usr/bin/env bash
# Start the 3-node Patroni cluster and prepare pgBackRest. Idempotent.
set -euo pipefail
. "$(dirname "$0")/../lib.sh"
ensure_env
require_space 20 "starting PostgreSQL"
cd "$ROOT/cluster"
docker image inspect pgha/postgres:17 >/dev/null 2>&1 || docker build -t pgha/postgres:17 "$ROOT/image"
"${DC[@]}" up -d --build
for c in pg1 pg2 pg3; do wait_healthy "$c" 600; done
leader=""
for _ in $(seq 1 60); do leader=$(cluster_leader) && break; sleep 2; done
[ -n "$leader" ] || { echo "ERROR: no Patroni leader" >&2; exit 1; }
# wait until both replicas stream and one is synchronous
for _ in $(seq 1 90); do
    n=$(docker exec "$leader" patronictl -c /tmp/patroni.yml list -f json | python3 -c \
        "import json,sys; m=json.load(sys.stdin); print(sum(1 for x in m if x['State'] == 'streaming' or (x['Role'] == 'Leader' and x['State'] == 'running')))")
    [ "$n" = 3 ] && break; sleep 2
done
docker exec "$leader" pgbackrest --stanza=main --log-level-console=warn stanza-create
docker exec "$leader" pgbackrest --stanza=main --log-level-console=warn check
docker exec "$leader" patronictl -c /tmp/patroni.yml list
echo
echo "Cluster is up (leader: $leader)"
echo "  read-write  ${BIND_ADDRESS}:6432   (HAProxy -> primary)"
echo "  read-only   ${BIND_ADDRESS}:6433   (HAProxy -> replicas)"
echo "  HAProxy     http://${BIND_ADDRESS}:7000/"
echo "  superuser   postgres / $POSTGRES_SUPERUSER_PASSWORD"
echo "  application $APP_USER / $APP_PASSWORD   (database $APP_DB)"
