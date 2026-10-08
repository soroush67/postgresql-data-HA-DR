#!/bin/bash
# Runs once, on the first start (empty data volume): application role +
# database, replication role, pg_stat_statements.
set -euo pipefail
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres \
     -v app_user="$APP_USER" -v app_password="$APP_PASSWORD" -v app_db="$APP_DB" \
     -v repl_password="$POSTGRES_REPLICATION_PASSWORD" <<'SQL'
CREATE ROLE :"app_user" LOGIN PASSWORD :'app_password';
CREATE DATABASE :"app_db" OWNER :"app_user";
CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD :'repl_password';
\c :"app_db"
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
SQL
