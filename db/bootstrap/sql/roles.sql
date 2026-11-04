-- Papéis do banco. Pode rodar mais de uma vez; nesse caso, atualiza as senhas.
-- Quem chama define antes farmaerp.migrator_password e farmaerp.app_password com set_config.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'farmaerp_migrator') THEN
    CREATE ROLE farmaerp_migrator;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'farmaerp_app') THEN
    CREATE ROLE farmaerp_app;
  END IF;

  -- Dono das tabelas. Não é superusuário.
  EXECUTE format(
    'ALTER ROLE farmaerp_migrator LOGIN PASSWORD %L NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS',
    current_setting('farmaerp.migrator_password'));

  -- Papel da API. Não é dono de nada e nunca ignora a RLS.
  EXECUTE format(
    'ALTER ROLE farmaerp_app LOGIN PASSWORD %L NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS',
    current_setting('farmaerp.app_password'));

  EXECUTE format('GRANT CREATE ON DATABASE %I TO farmaerp_migrator', current_database());
END;
$$;

GRANT CREATE, USAGE ON SCHEMA public TO farmaerp_migrator;
GRANT USAGE ON SCHEMA public TO farmaerp_app;
