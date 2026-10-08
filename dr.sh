#!/usr/bin/env bash
# =============================================================================
# dr.sh - backup, restore, disaster recovery and failover operations.
#
#   ./dr.sh <single|cluster> backup [full|diff|incr]   take a backup (default incr;
#                                                      the first one is always full)
#   ./dr.sh <single|cluster> info                      backups + WAL archive range
#   ./dr.sh <single|cluster> check                     archive_command + repo check
#   ./dr.sh <single|cluster> restore-test [--time T]   DR drill: restore the newest
#                          backup (or point in time T) into a THROWAWAY container,
#                          start it, verify the data, remove it. Production untouched.
#   ./dr.sh single  pitr --time T --yes                in-place point-in-time recovery
#   ./dr.sh cluster restore-cluster [--time T] --yes   rebuild the whole cluster from
#                          the backup repository (all 3 data volumes are replaced)
#   ./dr.sh cluster failover-test                      kill the primary, measure the
#                          automatic failover, verify no committed data was lost
#   ./dr.sh cluster switchover                         planned primary change
#   ./dr.sh cluster status                             patronictl list
#   ./dr.sh <single|cluster> cron                      suggested backup schedule
#
# T is a timestamp PostgreSQL understands, e.g. "2026-10-08 10:30:00+00".
# =============================================================================
set -euo pipefail
. "$(dirname "$0")/lib.sh"
[ -f "$ROOT/.env" ] && { set -a; . "$ROOT/.env"; set +a; }

MODE=${1:-}; CMD=${2:-}; shift 2 2>/dev/null || true
TIME=""; YES=0; TYPE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --time) TIME=$2; shift 2 ;;
        --yes) YES=1; shift ;;
        full|diff|incr) TYPE=$1; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
log() { printf '%s  %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

case "$MODE" in
    single)  REPO_VOL=pg-single_pgbackrest-repo; BR_CONF=$ROOT/single/conf/pgbackrest.conf ;;
    cluster) REPO_VOL=pg-cluster_pgbackrest-repo; BR_CONF=$ROOT/cluster/pgbackrest/pgbackrest.conf ;;
    *) usage ;;
esac

# container where pgbackrest runs: the single node, or the current primary
node() {
    if [ "$MODE" = single ]; then echo pg-single; else cluster_leader || die "no cluster leader found"; fi
}
br() { local n; n=$(node); docker exec -u postgres "$n" pgbackrest --stanza=main "$@"; }
psql_node() { docker exec -i -u postgres "$1" psql -X -v ON_ERROR_STOP=1 -At "${@:2}"; }

# restore options: newest (default) or point in time
PITR=()
[ -n "$TIME" ] && PITR=(--type=time "--target=$TIME" --target-action=promote)

# The single node keeps postgresql.conf OUTSIDE the data directory (mounted
# from single/conf), so it is not part of the backup: a restore must use it.
EXTRA_MOUNT=(); EXTRA_OPT=""
if [ "$MODE" = single ]; then
    EXTRA_MOUNT=(-v "$ROOT/single/conf/postgresql.conf:/etc/postgresql/postgresql.conf:ro")
    EXTRA_OPT="-c config_file=/etc/postgresql/postgresql.conf"
fi

summary_sql="SELECT 'tables=' || count(*) FROM pg_tables WHERE schemaname='bench' AND tablename ~ '^t[0-9]+\$';
SELECT 'rows=' || coalesce(sum(c.reltuples)::bigint, 0) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname='bench' AND c.relkind='r' AND c.relname ~ '^t[0-9]+\$';
SELECT 'size=' || pg_size_pretty(pg_database_size(current_database()));"

cmd_backup() {
    local t=${TYPE:-incr}
    log "backup type=$t on $(node) ..."
    br --type="$t" backup
    br info
}

cmd_restore_test() {
    local c=pg-restore-test vol=pg-restore-test-data
    # the throwaway copy is as big as the database
    local dbgb; dbgb=$(psql_node "$(node)" -d postgres -c "select ceil(sum(pg_database_size(datname))/1024.0^3) from pg_database")
    require_space $(( dbgb * 12 / 10 + 5 )) "restore-test (full copy of ${dbgb} GB)"
    docker rm -f "$c" >/dev/null 2>&1 || true
    docker volume rm "$vol" >/dev/null 2>&1 || true
    log "restore-test: restoring ${TIME:-the newest backup + all WAL} into throwaway container $c"
    docker run -d --name "$c" -u postgres \
        -v "$REPO_VOL":/var/lib/pgbackrest \
        -v "$BR_CONF":/etc/pgbackrest/pgbackrest.conf:ro \
        -v "$vol":/var/lib/postgresql/data "${EXTRA_MOUNT[@]}" \
        --entrypoint sleep pgha/postgres:17 infinity >/dev/null
    # KEEP=1 leaves the container for debugging
    [ -n "${KEEP:-}" ] || trap 'docker rm -f '"$c"' >/dev/null 2>&1; docker volume rm '"$vol"' >/dev/null 2>&1' EXIT
    local start=$SECONDS
    docker exec "$c" pgbackrest --stanza=main --log-level-console=warn "${PITR[@]}" restore
    log "restored files in $(( SECONDS - start ))s - starting PostgreSQL (WAL replay) ..."
    # own minimal hba (local trust); never archive from the copy, never wait
    # for (absent) synchronous standbys, no TCP listener
    docker exec "$c" sh -c 'echo "local all all trust" > /tmp/hba.conf'
    docker exec "$c" pg_ctl -D /var/lib/postgresql/data/pgdata -w -t 3600 -l /tmp/pg.log \
        -o "$EXTRA_OPT -c archive_mode=off -c synchronous_standby_names='' -c listen_addresses='' -c port=5432 -c hba_file=/tmp/hba.conf" \
        start >/dev/null || { docker exec "$c" tail -20 /tmp/pg.log; die "restored instance did not start"; }
    for _ in $(seq 1 3600); do
        [ "$(docker exec "$c" psql -X -At -h /var/run/postgresql -d postgres -c 'select pg_is_in_recovery()' 2>/dev/null)" = f ] && break
        sleep 1
    done
    [ "$(docker exec "$c" psql -X -At -h /var/run/postgresql -d postgres -c 'select pg_is_in_recovery()')" = f ] \
        || { docker exec "$c" tail -20 /tmp/pg.log; die "restored instance did not finish recovery"; }
    log "restored instance is up and promoted after $(( SECONDS - start ))s"
    docker exec "$c" grep -E "recovery stopping|redo done|selected new timeline|consistent recovery" /tmp/pg.log | tail -4 | sed 's/^/    /' || true
    docker exec -i "$c" psql -X -At -h /var/run/postgresql -d "${APP_DB:-appdb}" <<<"ANALYZE; $summary_sql" | grep -v "^ANALYZE" | sed 's/^/    restored: /'
    docker exec "$c" psql -X -At -h /var/run/postgresql -d "${APP_DB:-appdb}" -c \
        "select 'dr_marker rows: ' || string_agg(note, ', ' order by id) from public.dr_marker" 2>/dev/null \
        | grep -v '^$' | sed 's/^/    restored: /' || true
    log "restore-test OK (container and volume removed)"
}

cmd_pitr_single() {
    [ "$MODE" = single ] || die "pitr is for single; for the cluster use restore-cluster --time"
    [ -n "$TIME" ] || die "--time is required"
    [ "$YES" = 1 ] || die "this REPLACES the live database with its state at $TIME - add --yes"
    cd "$ROOT/single"
    log "stopping pg-single"
    "${DC[@]}" stop postgres
    log "restoring to $TIME (delta restore, in place)"
    docker run --rm -u postgres -v pg-single_pgdata:/var/lib/postgresql/data \
        -v "$REPO_VOL":/var/lib/pgbackrest -v "$BR_CONF":/etc/pgbackrest/pgbackrest.conf:ro \
        --entrypoint pgbackrest pgha/postgres:17 --stanza=main --delta --log-level-console=warn "${PITR[@]}" restore
    "${DC[@]}" start postgres
    wait_healthy pg-single 600
    for _ in $(seq 1 1800); do
        [ "$(psql_node pg-single -d postgres -c 'select pg_is_in_recovery()')" = f ] && break; sleep 1
    done
    log "pg-single recovered to $TIME and promoted (new timeline $(psql_node pg-single -d postgres -c 'select timeline_id from pg_control_checkpoint()'))"
    log "take a new full backup now: ./dr.sh single backup full"
}

cmd_restore_cluster() {
    [ "$MODE" = cluster ] || die "restore-cluster is for the cluster"
    [ "$YES" = 1 ] || die "this DELETES the data of pg1, pg2, pg3 and rebuilds the cluster from the backup repository - add --yes"
    cd "$ROOT/cluster"
    log "1/5 stopping pg1 pg2 pg3"
    "${DC[@]}" stop pg1 pg2 pg3
    log "2/5 removing the cluster state from etcd"
    docker exec etcd1 etcdctl del --prefix /service/pg-cluster/ >/dev/null
    log "3/5 wiping the data directories"
    for n in 1 2 3; do
        docker run --rm -v "pg-cluster_pg${n}-data:/d" --entrypoint rm pgha/postgres:17 -rf /d/pgdata
    done
    log "4/5 pg1 bootstraps from pgBackRest (${TIME:-newest backup + all WAL})"
    PG1_BOOTSTRAP=pgbackrest RESTORE_TARGET_TIME="$TIME" "${DC[@]}" up -d --no-deps pg1
    local start=$SECONDS l=""
    for _ in $(seq 1 3600); do l=$(cluster_leader 2>/dev/null) && break; sleep 2; done
    [ "$l" = pg1 ] || { docker logs --tail 30 pg1; die "pg1 did not become leader"; }
    log "    pg1 is leader after $(( SECONDS - start ))s"
    log "5/5 pg2 + pg3 rejoin as replicas (cloned from pg1)"
    "${DC[@]}" up -d --no-deps pg2 pg3
    for _ in $(seq 1 3600); do
        n=$(docker exec pg1 patronictl -c /tmp/patroni.yml list -f json | python3 -c \
            "import json,sys; print(sum(1 for x in json.load(sys.stdin) if x['State'] == 'streaming' or (x['Role'] == 'Leader' and x['State'] == 'running')))")
        [ "$n" = 3 ] && break; sleep 3
    done
    docker exec pg1 patronictl -c /tmp/patroni.yml list
    psql_node pg1 -d "${APP_DB:-appdb}" <<<"$summary_sql" | sed 's/^/    /'
    log "cluster restored in $(( SECONDS - start ))s - take a new full backup now: ./dr.sh cluster backup full"
}

cmd_failover_test() {
    [ "$MODE" = cluster ] || die "failover-test is for the cluster"
    local old; old=$(node)
    local w=(timeout 20 docker run --rm -i --network host -e PGPASSWORD="$APP_PASSWORD" -e PGCONNECT_TIMEOUT=5 -e PGOPTIONS="-c client_min_messages=warning"
             pgha/postgres:17 psql -X -q -At -h 127.0.0.1 -p 6432 -U "$APP_USER" -d "$APP_DB" -v ON_ERROR_STOP=1)
    "${w[@]}" -c "CREATE TABLE IF NOT EXISTS public.failover_test (id bigserial PRIMARY KEY, at timestamptz DEFAULT now(), note text)" >/dev/null
    local before; before=$("${w[@]}" -c "INSERT INTO public.failover_test(note) VALUES ('before failover, leader $old') RETURNING id")
    log "committed row id=$before through HAProxy :6432 (leader $old)"
    log "KILLING the primary container $old (simulated crash) ..."
    docker kill "$old" >/dev/null
    local start=$SECONDS id=""
    for _ in $(seq 1 120); do
        id=$("${w[@]}" -c "INSERT INTO public.failover_test(note) VALUES ('after failover') RETURNING id" 2>/dev/null) && break
        sleep 1
    done
    [ -n "$id" ] || die "no writable primary after 120s"
    local new; new=$(node)
    log "writes accepted again after $(( SECONDS - start ))s - new leader: $new"
    [ "$("${w[@]}" -c "SELECT count(*) FROM public.failover_test WHERE id = $before")" = 1 ] \
        && log "row id=$before (committed before the crash) is present - no data loss" \
        || die "row id=$before LOST"
    log "starting $old again - it rejoins as a replica (pg_rewind if needed)"
    docker start "$old" >/dev/null
    for _ in $(seq 1 120); do
        st=$(docker exec "$new" patronictl -c /tmp/patroni.yml list -f json 2>/dev/null | python3 -c \
            "import json,sys; print(sum(1 for x in json.load(sys.stdin) if x['State'] == 'streaming' or (x['Role'] == 'Leader' and x['State'] == 'running')))" 2>/dev/null || echo 0)
        [ "$st" = 3 ] && break; sleep 2
    done
    docker exec "$new" patronictl -c /tmp/patroni.yml list
}

case "$CMD" in
    backup)          cmd_backup ;;
    info)            br info ;;
    check)           br check && log "check OK" ;;
    restore-test)    cmd_restore_test ;;
    pitr)            cmd_pitr_single ;;
    restore-cluster) cmd_restore_cluster ;;
    failover-test)   cmd_failover_test ;;
    switchover)      [ "$MODE" = cluster ] || die "cluster only"; l=$(node)
                     docker exec "$l" patronictl -c /tmp/patroni.yml switchover --leader "$l" --force
                     sleep 5; docker exec "$(node)" patronictl -c /tmp/patroni.yml list ;;
    status)          [ "$MODE" = cluster ] || die "cluster only"; docker exec "$(node)" patronictl -c /tmp/patroni.yml list ;;
    cron)            cat <<CRON
# crontab -e   (on the docker host; adjust the path)
# full backup Sunday 01:00, differential Mon-Sat 01:00, incremental every 4 hours
0 1 * * 0    $ROOT/dr.sh $MODE backup full >> /var/log/pg-backup.log 2>&1
0 1 * * 1-6  $ROOT/dr.sh $MODE backup diff >> /var/log/pg-backup.log 2>&1
0 */4 * * *  $ROOT/dr.sh $MODE backup incr >> /var/log/pg-backup.log 2>&1
# weekly DR drill
0 4 * * 6    $ROOT/dr.sh $MODE restore-test >> /var/log/pg-backup.log 2>&1
CRON
                     ;;
    *) usage ;;
esac
