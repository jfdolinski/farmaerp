#!/bin/sh
# Roda uma única vez, quando o volume do Postgres é criado no ambiente local.
# Nos ambientes publicados, db/scripts/deploy.mjs aplica o mesmo sql/roles.sql.
set -eu

psql -q -v ON_ERROR_STOP=1 \
  --username "$POSTGRES_USER" \
  --dbname "$POSTGRES_DB" \
  -v migrator_password="$FARMAERP_MIGRATOR_PASSWORD" \
  -v app_password="$FARMAERP_APP_PASSWORD" <<'SQL'
SELECT set_config('farmaerp.migrator_password', :'migrator_password', false);
SELECT set_config('farmaerp.app_password', :'app_password', false);
\i /docker-entrypoint-initdb.d/sql/roles.sql
SQL
