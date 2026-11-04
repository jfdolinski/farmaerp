#!/bin/sh
# Prepara o banco e sobe a API. Qualquer falha impede a nova versão de subir.
set -eu

node apps/api/dist/config/check.js
node db/scripts/deploy.mjs

# A API roda só com o papel sujeito à RLS: as senhas de dono e de administrador
# não chegam ao processo. Elas continuam visíveis para quem acessa o painel.
unset FARMAERP_MIGRATOR_PASSWORD POSTGRES_ADMIN_PASSWORD

cd apps/api
exec node dist/main.js
