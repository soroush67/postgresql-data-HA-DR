# Shared helpers (sourced by up.sh / down.sh / dr.sh).
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if docker compose version >/dev/null 2>&1; then DC=(docker compose); else DC=(docker-compose); fi

gen() { head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c "${1:-24}"; }

# Create ../.env with random passwords on first use (never overwritten).
ensure_env() {
    ln -sf ../.env "$ROOT/single/.env"; ln -sf ../.env "$ROOT/cluster/.env"   # docker compose reads .env next to the compose file
    if [ ! -f "$ROOT/.env" ]; then
        ( umask 077
          cat > "$ROOT/.env" <<ENV
POSTGRES_SUPERUSER_PASSWORD=$(gen 24)
POSTGRES_REPLICATION_PASSWORD=$(gen 24)
APP_DB=appdb
APP_USER=app
APP_PASSWORD=$(gen 24)
BIND_ADDRESS=127.0.0.1
ENV
        )
        echo "created $ROOT/.env (random passwords)"
    fi
    set -a; . "$ROOT/.env"; set +a
}

# wait_healthy <container> [timeout-seconds]
wait_healthy() {
    local c=$1 t=${2:-300} s
    for _ in $(seq 1 "$t"); do
        s=$(docker inspect -f '{{.State.Health.Status}}' "$c" 2>/dev/null || echo missing)
        [ "$s" = healthy ] && return 0
        sleep 1
    done
    echo "ERROR: $c not healthy after ${t}s (status: $s)" >&2
    docker logs --tail 40 "$c" >&2
    return 1
}

# Current Patroni leader container name (pg1/pg2/pg3)
cluster_leader() {
    local n
    for n in pg1 pg2 pg3; do
        if docker exec "$n" curl -fsS -o /dev/null http://localhost:8008/primary 2>/dev/null; then
            echo "$n"; return 0
        fi
    done
    return 1
}

# Real free space in GB. Under WSL2 `df /` shows the virtual disk (~1 TB)
# while the data actually lives in ext4.vhdx on a Windows drive (default C:)
# that may have far less free space - so check both and use the smaller.
#   WSL_VHDX_DRIVE=/mnt/d   if your distro's vhdx is on another drive
free_gb() {
    local f; f=$(df -BG --output=avail / | tail -1 | tr -dc 0-9)
    if grep -qi microsoft /proc/version 2>/dev/null; then
        local d=${WSL_VHDX_DRIVE:-/mnt/c} w
        w=$(df -BG --output=avail "$d" 2>/dev/null | tail -1 | tr -dc 0-9)
        [ -n "$w" ] && [ "$w" -lt "$f" ] && f=$w
    fi
    echo "$f"
}

# require_space <GB> <what>: stop before filling the disk (SKIP_DISK_CHECK=1 to bypass)
require_space() {
    [ "${SKIP_DISK_CHECK:-0}" = 1 ] && return 0
    local need=$1 have; have=$(free_gb)
    if [ "$have" -lt "$need" ]; then
        echo "ERROR: $2 needs ~${need} GB free, only ${have} GB available" >&2
        grep -qi microsoft /proc/version 2>/dev/null && \
            echo "       (WSL: measured on ${WSL_VHDX_DRIVE:-/mnt/c}, where ext4.vhdx lives - df / is misleading)" >&2
        exit 1
    fi
}
