#!/usr/bin/env bash
# Start the single-node PostgreSQL and prepare pgBackRest. Idempotent.
set -euo pipefail
. "$(dirname "$0")/../lib.sh"
ensure_env
require_space 20 "starting PostgreSQL"
cd "$ROOT/single"
"${DC[@]}" up -d --build
wait_healthy pg-single 300
# pgBackRest stanza (repository metadata) - safe to rerun
docker exec -u postgres pg-single pgbackrest --stanza=main --log-level-console=warn stanza-create
docker exec -u postgres pg-single pgbackrest --stanza=main --log-level-console=warn check
echo
echo "PostgreSQL single node is up:  ${BIND_ADDRESS}:5432"
echo "  superuser   postgres / $POSTGRES_SUPERUSER_PASSWORD"
echo "  application $APP_USER / $APP_PASSWORD   (database $APP_DB)"
echo "  psql: docker exec -it -u postgres pg-single psql -d $APP_DB"
