#!/bin/sh
# Roda uma única vez, quando o volume do Postgres é criado no ambiente local.
# Em produção, os mesmos papéis serão criados na preparação do EasyPanel.
set -eu

psql -v ON_ERROR_STOP=1 \
  --username "$POSTGRES_USER" \
  --dbname "$POSTGRES_DB" \
  -v db_name="$POSTGRES_DB" \
  -v migrator_password="$FARMAERP_MIGRATOR_PASSWORD" \
  -v app_password="$FARMAERP_APP_PASSWORD" <<'SQL'
-- Dono das tabelas. Não é superusuário.
CREATE ROLE farmaerp_migrator
  LOGIN PASSWORD :'migrator_password'
  NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;

-- Papel da API. Não é dono de nada e nunca ignora a RLS.
CREATE ROLE farmaerp_app
  LOGIN PASSWORD :'app_password'
  NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;

GRANT CREATE ON DATABASE :"db_name" TO farmaerp_migrator;
GRANT CREATE, USAGE ON SCHEMA public TO farmaerp_migrator;
GRANT USAGE ON SCHEMA public TO farmaerp_app;
SQL
