#!/usr/bin/env bash
# =============================================================================
# script.sh - build a large, realistic test database in PostgreSQL.
#
# Default: 100 tables x 30 columns, 10,000,000 rows in total (100,000 per
# table), ~15 GB on disk (heap + TOAST + indexes). Row size is calibrated on
# the real server first, so the final size lands close to the target.
#
#   ./script.sh generate              # build it (resumable: rerun to continue)
#   ./script.sh verify                # row/column counts, sizes, sanity checks
#   ./script.sh estimate              # calibrate + print the plan, write nothing
#   ./script.sh drop                  # remove the schema
#
# Connection (flags or environment):
#   --target single|cluster   127.0.0.1:5432 (single) or 127.0.0.1:6432 (cluster,
#                             HAProxy read-write). Default: single
#   --host H --port P --user U --password W --db D
#                             default user/password/db = APP_USER/APP_PASSWORD/
#                             APP_DB from .env (app / ... / appdb)
# Shape:
#   --tables 100 --rows 10000000 --size-gb 15 --schema bench
#   --jobs N        parallel loaders (default: CPU cores / 2, max 8)
#   --chunk 25000   rows per INSERT transaction (unit of resume)
#   --force         generate: drop an existing schema and start over
#
# psql: uses the local psql if installed, otherwise runs psql from the
# pgha/postgres:17 (or postgres:17-bookworm) image with --network host.
# =============================================================================
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
[ -f "$HERE/.env" ] && { set -a; . "$HERE/.env"; set +a; }
. "$HERE/lib.sh"

CMD=${1:-help}; shift || true
TARGET=single
PGHOST_=${PGHOST:-}; PGPORT_=${PGPORT:-}
PGUSER_=${PGUSER:-${APP_USER:-app}}
PGPASSWORD_=${PGPASSWORD:-${APP_PASSWORD:-}}
PGDATABASE_=${PGDATABASE:-${APP_DB:-appdb}}
TABLES=100; ROWS=10000000; SIZE_GB=15; SCHEMA=bench; CHUNK=25000; FORCE=0
JOBS=$(( $(nproc) / 2 )); [ "$JOBS" -lt 1 ] && JOBS=1; [ "$JOBS" -gt 8 ] && JOBS=8

while [ $# -gt 0 ]; do
    case "$1" in
        --target) TARGET=$2; shift 2 ;;
        --host) PGHOST_=$2; shift 2 ;;
        --port) PGPORT_=$2; shift 2 ;;
        --user) PGUSER_=$2; shift 2 ;;
        --password) PGPASSWORD_=$2; shift 2 ;;
        --db) PGDATABASE_=$2; shift 2 ;;
        --tables) TABLES=$2; shift 2 ;;
        --rows) ROWS=$2; shift 2 ;;
        --size-gb) SIZE_GB=$2; shift 2 ;;
        --schema) SCHEMA=$2; shift 2 ;;
        --jobs) JOBS=$2; shift 2 ;;
        --chunk) CHUNK=$2; shift 2 ;;
        --force) FORCE=1; shift ;;
        -h|--help) CMD=help; shift ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done
case "$TARGET" in
    single)  : "${PGHOST_:=127.0.0.1}" "${PGPORT_:=5432}" ;;
    cluster) : "${PGHOST_:=127.0.0.1}" "${PGPORT_:=6432}" ;;
    *) echo "--target must be single or cluster" >&2; exit 2 ;;
esac
[[ "$SCHEMA" =~ ^[a-z_][a-z0-9_]*$ ]] || { echo "invalid schema name" >&2; exit 2; }
export PGHOST=$PGHOST_ PGPORT=$PGPORT_ PGUSER=$PGUSER_ PGPASSWORD=$PGPASSWORD_ PGDATABASE=$PGDATABASE_
export PGAPPNAME=script.sh PGCONNECT_TIMEOUT=10 PGOPTIONS="-c client_min_messages=warning"

# ------------------------------------------------------------------ psql
if command -v psql >/dev/null 2>&1; then
    PSQL=(psql)
else
    img=pgha/postgres:17
    docker image inspect "$img" >/dev/null 2>&1 || img=postgres:17-bookworm
    PSQL=(docker run --rm -i --network host -e PGHOST -e PGPORT -e PGUSER -e PGPASSWORD
          -e PGDATABASE -e PGAPPNAME -e PGCONNECT_TIMEOUT -e PGOPTIONS "$img" psql)
fi
export PSQL_CMD="${PSQL[*]}"
q() { "${PSQL[@]}" -X -q -v ON_ERROR_STOP=1 -At "$@"; }

log() { printf '%s  %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
human() { numfmt --to=iec-i --suffix=B "$1" 2>/dev/null || echo "$1 bytes"; }

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; }

# ------------------------------------------------------------- SQL bits
# 30 columns: keys, people/contact data, numbers, dates, network, arrays,
# JSON and three variable-length text columns that carry most of the volume.
table_ddl() {   # table_ddl <qualified-name>
cat <<SQL
CREATE TABLE $1 (
    id             bigint PRIMARY KEY,
    uid            uuid          NOT NULL,
    customer_code  varchar(24)   NOT NULL,
    first_name     varchar(40)   NOT NULL,
    last_name      varchar(40)   NOT NULL,
    email          varchar(120)  NOT NULL,
    phone          varchar(24),
    country        char(2)       NOT NULL,
    city           varchar(60)   NOT NULL,
    address        varchar(200),
    postal_code    varchar(12),
    status         smallint      NOT NULL,
    category       varchar(30)   NOT NULL,
    is_active      boolean       NOT NULL,
    quantity       integer       NOT NULL,
    unit_price     numeric(12,2) NOT NULL,
    total_amount   numeric(14,2) NOT NULL,
    discount_rate  real,
    score          double precision,
    created_at     timestamptz   NOT NULL,
    updated_at     timestamptz   NOT NULL,
    birth_date     date,
    ip_address     inet,
    tags           text[],
    attributes     jsonb,
    description    text,
    notes          text,
    payload        text,
    checksum       char(32)      NOT NULL,
    version        integer       NOT NULL DEFAULT 1
);
-- out-of-line without compression: on-disk size stays predictable
ALTER TABLE $1 ALTER COLUMN description SET STORAGE EXTERNAL,
               ALTER COLUMN notes       SET STORAGE EXTERNAL,
               ALTER COLUMN payload     SET STORAGE EXTERNAL;
SQL
}

# INSERT ... SELECT for ids [lo, hi]; text lengths are means (+-25% per row)
insert_sql() {  # insert_sql <table> <lo> <hi> <desc_len> <notes_len> <payload_len>
cat <<SQL
INSERT INTO $1
SELECT g,
       gen_random_uuid(),
       'C' || lpad((g % 9999991)::text, 10, '0'),
       (ARRAY['Ali','Sara','Reza','Maryam','Hossein','Zahra','Mohammad','Fatemeh','John','Emma','Liam','Olivia','Noah','Ava','Lucas','Mia'])[1 + (random()*15)::int],
       (ARRAY['Ahmadi','Hosseini','Karimi','Rezaei','Moradi','Smith','Johnson','Brown','Garcia','Miller','Davis','Martinez','Wilson','Anderson','Taylor','Thomas'])[1 + (random()*15)::int],
       'user' || g || '@' || (ARRAY['example.com','mail.test','corp.local','company.ir'])[1 + (random()*3)::int],
       '+98' || (9000000000 + (random()*999999999)::bigint),
       (ARRAY['IR','DE','US','GB','FR','TR','AE','NL','CA','JP'])[1 + (random()*9)::int],
       (ARRAY['Tehran','Mashhad','Isfahan','Shiraz','Tabriz','Berlin','London','Paris','Istanbul','Dubai','Toronto','Tokyo'])[1 + (random()*11)::int],
       (1 + (random()*400)::int) || ' ' || $SCHEMA.words(60 + (random()*60)::int),
       lpad(((random()*99999)::int)::text, 5, '0'),
       (random()*5)::smallint,
       (ARRAY['retail','wholesale','online','partner','internal','government'])[1 + (random()*5)::int],
       random() < 0.85,
       (random()*1000)::int,
       round((random()*10000)::numeric, 2),
       round((random()*1000000)::numeric, 2),
       round(random()::numeric, 3)::real,
       random()*100,
       now() - random() * interval '1500 days',
       now() - random() * interval '30 days',
       date '1950-01-01' + (random()*20000)::int,
       ('10.' || (random()*255)::int || '.' || (random()*255)::int || '.' || (random()*255)::int)::inet,
       ARRAY[$SCHEMA.words(8), $SCHEMA.words(8), $SCHEMA.words(8)],
       jsonb_build_object('source', (ARRAY['web','mobile','api','batch'])[1 + (random()*3)::int],
                          'priority', (random()*10)::int,
                          'flags', jsonb_build_array(random() < 0.5, random() < 0.5, random() < 0.5),
                          'meta', $SCHEMA.words(80)),
       $SCHEMA.words(($4 * (0.75 + random()*0.5))::int),
       $SCHEMA.words(($5 * (0.75 + random()*0.5))::int),
       $SCHEMA.hexblob(($6 * (0.75 + random()*0.5))::int),
       md5(g::text),
       1 + (random()*9)::int
FROM generate_series($2, $3) AS g
SQL
}

functions_sql() {
cat <<SQL
CREATE SCHEMA IF NOT EXISTS $SCHEMA;
-- n characters of word-like text (realistic, varied)
CREATE OR REPLACE FUNCTION $SCHEMA.words(n int) RETURNS text
LANGUAGE sql VOLATILE PARALLEL SAFE AS \$\$
  SELECT left(string_agg(w, ' '), greatest(n, 0)) FROM (
    SELECT (ARRAY['data','server','cluster','replica','backup','restore','primary','index','table','query',
                  'transaction','commit','rollback','storage','network','latency','throughput','customer','order','invoice',
                  'payment','product','warehouse','shipment','report','analytics','metric','event','session','account',
                  'security','policy','audit','archive','snapshot','journal','ledger','balance','credit','debit',
                  'tehran','isfahan','shiraz','mashhad','tabriz','alpha','beta','gamma','delta','omega',
                  'quick','brown','fox','jumps','over','lazy','dog','lorem','ipsum','dolor',
                  'sit','amet','consectetur','adipiscing','elit','sed','eiusmod','tempor','incididunt','labore',
                  'magna','aliqua','enim','minim','veniam','quis','nostrud','exercitation','ullamco','laboris',
                  'nisi','aliquip','commodo','consequat','duis','aute','irure','reprehenderit','voluptate','velit',
                  'esse','cillum','fugiat','nulla','pariatur','excepteur','sint','occaecat','cupidatat','proident'])
           [1 + (random()*99)::int] AS w
    FROM generate_series(1, greatest(n, 0) / 6 + 2)) s
\$\$;
-- n characters of random hex (incompressible payload)
CREATE OR REPLACE FUNCTION $SCHEMA.hexblob(n int) RETURNS text
LANGUAGE sql VOLATILE PARALLEL SAFE AS \$\$
  SELECT left(string_agg(md5(random()::text), ''), greatest(n, 0))
  FROM generate_series(1, greatest(n, 0) / 32 + 1)
\$\$;
CREATE TABLE IF NOT EXISTS $SCHEMA.load_log (
    table_name text NOT NULL, lo bigint NOT NULL, hi bigint NOT NULL,
    loaded_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY (table_name, lo));
CREATE TABLE IF NOT EXISTS $SCHEMA.load_meta (k text PRIMARY KEY, v text NOT NULL);
SQL
}

# ------------------------------------------------------------ calibration
# Mean text lengths: description 25%, notes 15%, payload 60% of the "fill".
lens() { local f=$1; echo "$(( f*25/100 )) $(( f*15/100 )) $(( f*60/100 ))"; }

measure() {   # measure <fill> -> bytes per row (heap + toast + 2 indexes + pk)
    local f=$1 d n p n_rows=5000
    read -r d n p <<<"$(lens "$f")"
    q <<SQL
SET client_min_messages = warning;
DROP TABLE IF EXISTS $SCHEMA._calib;
$(table_ddl "$SCHEMA._calib")
$(insert_sql "$SCHEMA._calib" 1 $n_rows "$d" "$n" "$p");
CREATE INDEX ON $SCHEMA._calib (created_at);
CREATE INDEX ON $SCHEMA._calib (customer_code);
VACUUM (ANALYZE) $SCHEMA._calib;
SELECT pg_total_relation_size('$SCHEMA._calib') / $n_rows;
DROP TABLE $SCHEMA._calib;
SQL
}

calibrate() {
    TARGET_ROW=$(awk -v g="$SIZE_GB" -v r="$ROWS" 'BEGIN{printf "%d", g*1024*1024*1024/r}')
    [ "$TARGET_ROW" -ge 600 ] || die "size/rows gives only $TARGET_ROW bytes per row - 30 columns need >= 600 (lower --rows or raise --size-gb)"
    # bisection on the text fill: size per row is not linear (rows per 8 KB
    # page change in steps), so search instead of extrapolating
    local lo=0 hi=$(( TARGET_ROW * 2 )) mid m i best=0 bestd=999999999 d
    for i in 1 2 3 4 5 6 7 8; do
        mid=$(( (lo + hi) / 2 ))
        m=$(measure "$mid")
        d=$(( m > TARGET_ROW ? m - TARGET_ROW : TARGET_ROW - m ))
        log "calibration $i: text fill $mid chars -> $m bytes/row (target $TARGET_ROW)"
        if [ "$d" -lt "$bestd" ]; then best=$mid; bestd=$d; fi
        [ $(( d * 100 )) -le $(( TARGET_ROW * 2 )) ] && break      # within 2 %
        if [ "$m" -lt "$TARGET_ROW" ]; then lo=$mid; else hi=$mid; fi
    done
    FILL=$best
    read -r DESC_LEN NOTES_LEN PAYLOAD_LEN <<<"$(lens "$FILL")"
}

# ------------------------------------------------------------- commands
check_conn() {
    local v
    v=$(q -c "select current_setting('server_version_num')::int >= 130000, pg_is_in_recovery()" 2>&1) \
        || die "cannot connect to $PGUSER@$PGHOST:$PGPORT/$PGDATABASE: $v"
    case "$v" in
        "t|f") ;;
        "t|t") [ "$CMD" = verify ] || die "$PGHOST:$PGPORT is a read-only replica - use the primary (cluster: --target cluster = port 6432)" ;;
        *) die "PostgreSQL 13+ required (gen_random_uuid)" ;;
    esac
    log "connected: $PGUSER@$PGHOST:$PGPORT/$PGDATABASE ($(q -c 'show server_version'))"
}

plan() {
    PER_TABLE=$(( ROWS / TABLES )); EXTRA=$(( ROWS % TABLES ))
    log "plan: $TABLES tables x 30 columns, $ROWS rows (~$PER_TABLE per table), target $SIZE_GB GiB, $JOBS parallel jobs"
}

tname() { printf '%s.t%03d' "$SCHEMA" "$1"; }

cmd_generate() {
    check_conn; plan
    # data + WAL + WAL archive (+ 2 more copies on the replicas of a cluster)
    local factor=3; [ "$PGPORT" = 6432 ] && factor=6
    require_space "$(awk -v g="$SIZE_GB" -v f=$factor 'BEGIN{printf "%d", g*f + 10}')" "generating ${SIZE_GB} GB"
    if [ "$(q -c "select count(*) from information_schema.tables where table_schema='$SCHEMA' and table_name ~ '^t[0-9]+$'")" != 0 ]; then
        if [ "$FORCE" = 1 ]; then
            log "--force: dropping schema $SCHEMA"; q -c "DROP SCHEMA $SCHEMA CASCADE"
        else
            local stored
            stored=$(q -c "select v from $SCHEMA.load_meta where k='shape'" 2>/dev/null || true)
            [ "$stored" = "$TABLES/$ROWS/$SIZE_GB" ] \
                || die "schema $SCHEMA already holds a dataset with another shape ($stored) - use --force to rebuild"
            log "existing dataset found - resuming"
        fi
    fi
    q <<<"$(functions_sql)"
    if [ -z "$(q -c "select v from $SCHEMA.load_meta where k='fill'")" ]; then
        calibrate
        q -c "INSERT INTO $SCHEMA.load_meta VALUES ('shape','$TABLES/$ROWS/$SIZE_GB'),
              ('fill','$DESC_LEN $NOTES_LEN $PAYLOAD_LEN'), ('started', now()::text)"
    fi
    read -r DESC_LEN NOTES_LEN PAYLOAD_LEN <<<"$(q -c "select v from $SCHEMA.load_meta where k='fill'")"
    log "text lengths (mean): description=$DESC_LEN notes=$NOTES_LEN payload=$PAYLOAD_LEN"

    # 1) tables
    local i ddl=""
    for i in $(seq 1 "$TABLES"); do
        ddl+="$(table_ddl "$(tname "$i")" | sed 's/^CREATE TABLE /CREATE TABLE IF NOT EXISTS /')"$'\n'
    done
    q <<<"$ddl"
    log "tables ready"

    # 2) work list: one line per chunk not loaded yet
    WORK=$(mktemp); trap 'rm -f "$WORK"' EXIT
    local done_list; done_list=$(q -c "select table_name||':'||lo from $SCHEMA.load_log")
    local t lo hi n all=0
    for i in $(seq 1 "$TABLES"); do
        t=$(tname "$i"); n=$PER_TABLE; [ "$i" -le "$EXTRA" ] && n=$((n+1))
        for (( lo=1; lo<=n; lo+=CHUNK )); do
            hi=$(( lo + CHUNK - 1 )); [ "$hi" -gt "$n" ] && hi=$n
            all=$((all+1))
            grep -qx "$t:$lo" <<<"$done_list" || echo "$t $lo $hi"
        done
    done > "$WORK"
    local total; total=$(wc -l < "$WORK")
    [ "$total" -gt 0 ] || total=0
    log "loading $total chunk(s) of up to $CHUNK rows ..."
    export SCHEMA DESC_LEN NOTES_LEN PAYLOAD_LEN
    export -f insert_sql
    local start=$SECONDS
    # each chunk: INSERT + its load_log row in ONE transaction -> exactly-once, resumable
    < "$WORK" xargs -P "$JOBS" -L 1 bash -c '
        sql="BEGIN; SET LOCAL synchronous_commit = off;
             $(insert_sql "$0" "$1" "$2" "$DESC_LEN" "$NOTES_LEN" "$PAYLOAD_LEN");
             INSERT INTO $SCHEMA.load_log (table_name, lo, hi) VALUES ('"'"'$0'"'"', $1, $2);
             COMMIT;"
        $PSQL_CMD -X -q -v ON_ERROR_STOP=1 <<<"$sql" || { echo "chunk $0 $1-$2 FAILED" >&2; exit 255; }
        echo "$0 $1-$2"' | {
        local k=0
        while read -r line; do
            k=$((k+1))
            if (( k % JOBS == 0 || k == total )); then
                local el=$(( SECONDS - start )); local eta=$(( el * (total - k) / k ))
                log "  $k/$total chunks  ($(( k*100/total ))%)  elapsed ${el}s  eta ${eta}s"
            fi
        done
    } || true
    [ "$(q -c "select count(*) from $SCHEMA.load_log")" -ge "$all" ] \
        || die "some chunks failed - rerun ./script.sh generate to resume"
    log "data loaded in $(( SECONDS - start ))s"

    # 3) secondary indexes + vacuum/analyze (parallel, idempotent)
    log "creating indexes + VACUUM ANALYZE ..."
    seq 1 "$TABLES" | xargs -P "$JOBS" -I{} bash -c '
        t=$(printf "%s.t%03d" "$SCHEMA" {}); n=$(printf "t%03d" {})
        $PSQL_CMD -X -q -v ON_ERROR_STOP=1 -c "CREATE INDEX IF NOT EXISTS ${n}_created_at_idx ON $t (created_at)" \
                                             -c "CREATE INDEX IF NOT EXISTS ${n}_customer_code_idx ON $t (customer_code)" \
                                             -c "VACUUM (ANALYZE) $t"'
    q -c "INSERT INTO $SCHEMA.load_meta VALUES ('finished', now()::text) ON CONFLICT (k) DO UPDATE SET v = excluded.v"
    log "done in $(( SECONDS - start ))s"
    cmd_verify
}

cmd_verify() {
    [ "$CMD" = verify ] && { check_conn; plan; }
    local role; role=$(q -c "select case when pg_is_in_recovery() then 'replica' else 'primary' end")
    log "verifying schema $SCHEMA on $PGHOST:$PGPORT ($role) ..."
    q <<SQL
\pset format aligned
\pset tuples_only off
\pset footer off
SELECT count(*)                                         AS tables,
       min(cols) AS min_columns, max(cols) AS max_columns
FROM (SELECT c.relname, count(a.attnum) AS cols
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
      JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
      WHERE n.nspname = '$SCHEMA' AND c.relkind = 'r' AND c.relname ~ '^t[0-9]+$'
      GROUP BY c.relname) s;
SQL
    # exact row counts (parallel seq scans)
    export SCHEMA
    local counts
    counts=$(seq 1 "$TABLES" | xargs -P "$JOBS" -I{} bash -c \
        '$PSQL_CMD -X -At -c "select count(*) from $(printf "%s.t%03d" "$SCHEMA" {})"' 2>/dev/null \
        | awk '{s+=$1; if(min==""||$1<min)min=$1; if($1>max)max=$1} END{print s, min, max}')
    export SCHEMA
    read -r sum min max <<<"$counts"
    log "rows: total=$sum  per table min=$min max=$max   (expected total $ROWS)"
    q <<SQL
\pset format aligned
\pset tuples_only off
\pset footer off
SELECT pg_size_pretty(sum(pg_table_size(c.oid)))            AS tables_and_toast,
       pg_size_pretty(sum(pg_indexes_size(c.oid)))          AS indexes,
       pg_size_pretty(sum(pg_total_relation_size(c.oid)))   AS schema_total,
       pg_size_pretty(pg_database_size(current_database())) AS database_total,
       pg_size_pretty(avg(pg_total_relation_size(c.oid))::bigint) AS avg_per_table,
       (sum(pg_total_relation_size(c.oid)) / greatest(sum(c.reltuples), 1))::int AS bytes_per_row
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = '$SCHEMA' AND c.relkind = 'r' AND c.relname ~ '^t[0-9]+$';
SELECT id, customer_code, first_name, last_name, city, total_amount, created_at::date,
       length(description) AS desc_len, length(notes) AS notes_len, length(payload) AS payload_len
FROM $SCHEMA.t001 ORDER BY id LIMIT 3;
SQL
    [ "$sum" = "$ROWS" ] || { echo "WARNING: row total $sum != $ROWS" >&2; return 1; }
    log "verify OK"
}

cmd_estimate() { check_conn; plan; q <<<"$(functions_sql)"; calibrate
    log "estimate: ~$(human $(( TARGET_ROW * ROWS ))) for $ROWS rows; mean text lengths $DESC_LEN/$NOTES_LEN/$PAYLOAD_LEN"; }

cmd_drop() { check_conn; q -c "DROP SCHEMA IF EXISTS $SCHEMA CASCADE"; log "schema $SCHEMA dropped"; }

case "$CMD" in
    generate) cmd_generate ;;
    verify)   cmd_verify ;;
    estimate) cmd_estimate ;;
    drop)     cmd_drop ;;
    help|*)   usage ;;
esac
