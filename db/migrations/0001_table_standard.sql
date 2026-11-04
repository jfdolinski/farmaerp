-- Up Migration

-- Padrão aplicado a todas as tabelas: UUID v7, auditoria, versão e exclusão lógica.
CREATE SCHEMA app;
REVOKE ALL ON SCHEMA app FROM PUBLIC;
GRANT USAGE ON SCHEMA app TO farmaerp_app;

-- Usuário da transação atual, definido pela API com set_config('app.user_id', ..., true).
-- Sem contexto retorna NULL; um valor malformado gera erro e nada é liberado.
CREATE FUNCTION app.current_user_id() RETURNS uuid
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT NULLIF(pg_catalog.current_setting('app.user_id', true), '')::uuid
$$;

-- Preenche os campos de auditoria e protege os campos que não podem mudar.
CREATE FUNCTION app.audit_row() RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    NEW.version := 1;
  ELSE
    IF NEW.id IS DISTINCT FROM OLD.id THEN
      RAISE EXCEPTION 'Este registro não pode ter o identificador alterado.'
        USING ERRCODE = 'restrict_violation',
              DETAIL = pg_catalog.format('Alteração de id em %I.%I.', TG_TABLE_SCHEMA, TG_TABLE_NAME);
    END IF;

    IF NEW.created_at IS DISTINCT FROM OLD.created_at THEN
      RAISE EXCEPTION 'A data de criação do registro não pode ser alterada.'
        USING ERRCODE = 'restrict_violation',
              DETAIL = pg_catalog.format('Alteração de created_at em %I.%I.', TG_TABLE_SCHEMA, TG_TABLE_NAME);
    END IF;

    NEW.version := OLD.version + 1;
  END IF;

  NEW.updated_at := pg_catalog.clock_timestamp();
  NEW.updated_by := app.current_user_id();
  RETURN NEW;
END;
$$;

-- Nada é apagado fisicamente: excluir significa preencher deleted_at.
CREATE FUNCTION app.block_physical_delete() RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  RAISE EXCEPTION 'Registros não podem ser apagados. Use a exclusão lógica.'
    USING ERRCODE = 'restrict_violation',
          DETAIL = pg_catalog.format('%s em %I.%I.', TG_OP, TG_TABLE_SCHEMA, TG_TABLE_NAME);
END;
$$;

-- Aplica o padrão a uma tabela. Deve ser chamada para toda tabela nova.
-- Falha se faltar alguma das colunas obrigatórias.
CREATE PROCEDURE app.apply_table_standard(target regclass)
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  table_name text := (SELECT c.relname FROM pg_catalog.pg_class c WHERE c.oid = target);
  missing_columns text;
BEGIN
  SELECT pg_catalog.string_agg(required.column_name, ', ' ORDER BY required.position)
    INTO missing_columns
    FROM pg_catalog.unnest(
      ARRAY['id', 'created_at', 'updated_at', 'deleted_at', 'version', 'updated_by']
    ) WITH ORDINALITY AS required(column_name, position)
   WHERE NOT EXISTS (
     SELECT 1
       FROM pg_catalog.pg_attribute a
      WHERE a.attrelid = target
        AND a.attname = required.column_name
        AND NOT a.attisdropped
   );

  IF missing_columns IS NOT NULL THEN
    RAISE EXCEPTION 'Tabela % sem as colunas obrigatórias: %', target, missing_columns;
  END IF;

  EXECUTE pg_catalog.format(
    'ALTER TABLE %s ADD CONSTRAINT %I CHECK (pg_catalog.uuid_extract_version(id) = 7)',
    target, table_name || '_id_uuid_v7_check');
  EXECUTE pg_catalog.format(
    'ALTER TABLE %s ADD CONSTRAINT %I FOREIGN KEY (updated_by) REFERENCES public.user_account (id)',
    target, table_name || '_updated_by_fkey');
  EXECUTE pg_catalog.format(
    'CREATE TRIGGER audit_row BEFORE INSERT OR UPDATE ON %s
       FOR EACH ROW EXECUTE FUNCTION app.audit_row()', target);
  EXECUTE pg_catalog.format(
    'CREATE TRIGGER block_physical_delete BEFORE DELETE OR TRUNCATE ON %s
       FOR EACH STATEMENT EXECUTE FUNCTION app.block_physical_delete()', target);
  EXECUTE pg_catalog.format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY', target);
END;
$$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;
REVOKE ALL ON PROCEDURE app.apply_table_standard(regclass) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.current_user_id() TO farmaerp_app;
