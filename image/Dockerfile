# PostgreSQL 17 + pgBackRest (backup/DR) + Patroni (HA). One image for both
# the single-node and the 3-node cluster setup.
#   single : official postgres entrypoint (docker-entrypoint.sh postgres ...)
#   cluster: patroni /etc/patroni/patroni.yml
ARG PG_IMAGE=postgres:17-bookworm
FROM ${PG_IMAGE}
# The official image already has the PGDG apt repository configured, so
# pgbackrest/patroni come in versions built for this PostgreSQL major.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends pgbackrest patroni python3-psycopg2 python3-etcd curl ca-certificates; \
    rm -rf /var/lib/apt/lists/*; \
    install -d -o postgres -g postgres -m 0750 /var/lib/pgbackrest /var/log/pgbackrest /var/spool/pgbackrest /etc/pgbackrest; \
    install -d -o postgres -g postgres -m 0700 /var/lib/postgresql/data; \
    pgbackrest version; patroni --version
