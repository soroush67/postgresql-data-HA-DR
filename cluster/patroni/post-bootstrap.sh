#!/bin/bash
# Patroni post_bootstrap: runs once on the member that created the cluster.
# Idempotent (also runs after a bootstrap from a pgBackRest backup).
set -euo pipefail
psql -v ON_ERROR_STOP=1 -d "$1" -v app_user="$APP_USER" -v app_password="$APP_PASSWORD" -v app_db="$APP_DB" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'app_user', :'app_password')
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'app_user') \gexec
SELECT format('CREATE DATABASE %I OWNER %I', :'app_db', :'app_user')
 WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'app_db') \gexec
\c :"app_db"
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
SQL
