-- Up Migration

-- Erros do banco passam a usar os códigos de packages/error-catalog como SQLSTATE.
-- Toda alteração passa a registrar o ID de rastreio da operação.

-- ID de rastreio da transação, definido pela API com set_config('app.trace_id', ..., true).
CREATE FUNCTION app.current_trace_id() RETURNS uuid
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT NULLIF(pg_catalog.current_setting('app.trace_id', true), '')::uuid
$$;
REVOKE ALL ON FUNCTION app.current_trace_id() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.current_trace_id() TO farmaerp_app;

ALTER TABLE economic_group ADD COLUMN trace_id uuid;
ALTER TABLE company ADD COLUMN trace_id uuid;
ALTER TABLE branch_group ADD COLUMN trace_id uuid;
ALTER TABLE region ADD COLUMN trace_id uuid;
ALTER TABLE branch ADD COLUMN trace_id uuid;
ALTER TABLE terminal ADD COLUMN trace_id uuid;
ALTER TABLE user_account ADD COLUMN trace_id uuid;
ALTER TABLE user_branch ADD COLUMN trace_id uuid;

-- security_invoker precisa ser repetido: CREATE OR REPLACE substitui as opções da view.
CREATE OR REPLACE VIEW v_economic_group WITH (security_invoker = true) AS
  SELECT * FROM economic_group WHERE deleted_at IS NULL;
CREATE OR REPLACE VIEW v_company WITH (security_invoker = true) AS
  SELECT * FROM company WHERE deleted_at IS NULL;
CREATE OR REPLACE VIEW v_branch_group WITH (security_invoker = true) AS
  SELECT * FROM branch_group WHERE deleted_at IS NULL;
CREATE OR REPLACE VIEW v_region WITH (security_invoker = true) AS
  SELECT * FROM region WHERE deleted_at IS NULL;
CREATE OR REPLACE VIEW v_branch WITH (security_invoker = true) AS
  SELECT * FROM branch WHERE deleted_at IS NULL;
CREATE OR REPLACE VIEW v_terminal WITH (security_invoker = true) AS
  SELECT * FROM terminal WHERE deleted_at IS NULL;
CREATE OR REPLACE VIEW v_user_account WITH (security_invoker = true) AS
  SELECT * FROM user_account WHERE deleted_at IS NULL;
CREATE OR REPLACE VIEW v_user_branch WITH (security_invoker = true) AS
  SELECT * FROM user_branch WHERE deleted_at IS NULL;

CREATE OR REPLACE FUNCTION app.audit_row() RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    NEW.version := 1;
  ELSE
    IF NEW.id IS DISTINCT FROM OLD.id THEN
      RAISE EXCEPTION 'Este registro não pode ter o identificador alterado.'
        USING ERRCODE = 'FA101',
              DETAIL = pg_catalog.format('Alteração de id em %I.%I.', TG_TABLE_SCHEMA, TG_TABLE_NAME);
    END IF;

    IF NEW.created_at IS DISTINCT FROM OLD.created_at THEN
      RAISE EXCEPTION 'A data de criação do registro não pode ser alterada.'
        USING ERRCODE = 'FA102',
              DETAIL = pg_catalog.format('Alteração de created_at em %I.%I.', TG_TABLE_SCHEMA, TG_TABLE_NAME);
    END IF;

    NEW.version := OLD.version + 1;
  END IF;

  NEW.updated_at := pg_catalog.clock_timestamp();
  NEW.updated_by := app.current_user_id();
  NEW.trace_id := app.current_trace_id();
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION app.block_physical_delete() RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  RAISE EXCEPTION 'Registros não podem ser apagados. Use a exclusão lógica.'
    USING ERRCODE = 'FA103',
          DETAIL = pg_catalog.format('%s em %I.%I.', TG_OP, TG_TABLE_SCHEMA, TG_TABLE_NAME);
END;
$$;

-- Toda tabela nova também precisa de trace_id.
CREATE OR REPLACE PROCEDURE app.apply_table_standard(target regclass)
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
      ARRAY['id', 'created_at', 'updated_at', 'deleted_at', 'version', 'updated_by', 'trace_id']
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

CREATE OR REPLACE FUNCTION app.block_immutable_columns() RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  column_name text;
BEGIN
  FOREACH column_name IN ARRAY TG_ARGV LOOP
    IF (pg_catalog.to_jsonb(NEW) -> column_name) IS DISTINCT FROM (pg_catalog.to_jsonb(OLD) -> column_name) THEN
      RAISE EXCEPTION 'Este dado não pode ser alterado depois do cadastro.'
        USING ERRCODE = 'FA104',
              DETAIL = pg_catalog.format('Alteração de %I em %I.%I.', column_name, TG_TABLE_SCHEMA, TG_TABLE_NAME);
    END IF;
  END LOOP;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION app.block_soft_delete_with_active_children() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  has_children boolean;
BEGIN
  IF NEW.deleted_at IS NULL OR OLD.deleted_at IS NOT NULL THEN
    RETURN NEW;
  END IF;

  FOR i IN 0..(TG_NARGS / 2 - 1) LOOP
    EXECUTE pg_catalog.format(
      'SELECT EXISTS (SELECT 1 FROM public.%I WHERE %I = $1 AND deleted_at IS NULL)',
      TG_ARGV[i * 2], TG_ARGV[i * 2 + 1])
      INTO has_children USING NEW.id;

    IF has_children THEN
      RAISE EXCEPTION 'Este registro ainda tem itens ativos vinculados.'
        USING ERRCODE = 'FA105',
              DETAIL = pg_catalog.format('%I possui filhos ativos em %I.', TG_TABLE_NAME, TG_ARGV[i * 2]);
    END IF;
  END LOOP;

  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION app.validate_economic_group_parent() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NEW.deleted_at IS NULL THEN
    PERFORM 1 FROM public.economic_group g
      WHERE g.id = NEW.economic_group_id AND g.deleted_at IS NULL
      FOR SHARE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'O grupo econômico informado não está ativo.'
        USING ERRCODE = 'FA201',
              DETAIL = pg_catalog.format('economic_group %s inativo em %I.', NEW.economic_group_id, TG_TABLE_NAME);
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION app.validate_region() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  new_economic_group_id uuid;
  old_economic_group_id uuid;
BEGIN
  IF NEW.deleted_at IS NULL THEN
    SELECT bg.economic_group_id INTO new_economic_group_id
      FROM public.branch_group bg
     WHERE bg.id = NEW.branch_group_id AND bg.deleted_at IS NULL
       FOR SHARE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'O grupo de filial informado não está ativo.'
        USING ERRCODE = 'FA202',
              DETAIL = pg_catalog.format('branch_group %s inativo.', NEW.branch_group_id);
    END IF;
  ELSE
    SELECT bg.economic_group_id INTO new_economic_group_id
      FROM public.branch_group bg WHERE bg.id = NEW.branch_group_id;
  END IF;

  IF TG_OP = 'UPDATE' AND NEW.branch_group_id IS DISTINCT FROM OLD.branch_group_id THEN
    SELECT bg.economic_group_id INTO old_economic_group_id
      FROM public.branch_group bg WHERE bg.id = OLD.branch_group_id;
    IF new_economic_group_id IS DISTINCT FROM old_economic_group_id THEN
      RAISE EXCEPTION 'A região só pode ser movida para um grupo de filial do mesmo grupo econômico.'
        USING ERRCODE = 'FA207',
              DETAIL = pg_catalog.format('region %s entre grupos econômicos.', NEW.id);
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION app.validate_branch() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  company_group_id uuid;
  company_root text;
  company_deleted_at timestamptz;
  region_group_id uuid;
BEGIN
  SELECT c.economic_group_id, c.cnpj_root, c.deleted_at
    INTO company_group_id, company_root, company_deleted_at
    FROM public.company c
   WHERE c.id = NEW.company_id
     FOR SHARE;

  IF NEW.cnpj IS NOT NULL AND pg_catalog.left(NEW.cnpj, 8) <> company_root THEN
    RAISE EXCEPTION 'O CNPJ da filial precisa ter a mesma raiz do CNPJ da empresa.'
      USING ERRCODE = 'FA203',
            DETAIL = pg_catalog.format('branch.cnpj %s, company.cnpj_root %s.', NEW.cnpj, company_root);
  END IF;

  IF NEW.deleted_at IS NULL THEN
    IF company_deleted_at IS NOT NULL THEN
      RAISE EXCEPTION 'A empresa informada não está ativa.'
        USING ERRCODE = 'FA204',
              DETAIL = pg_catalog.format('company %s inativa.', NEW.company_id);
    END IF;

    IF NEW.region_id IS NOT NULL THEN
      SELECT bg.economic_group_id INTO region_group_id
        FROM public.region r
        JOIN public.branch_group bg ON bg.id = r.branch_group_id
       WHERE r.id = NEW.region_id AND r.deleted_at IS NULL
         FOR SHARE OF r;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'A região informada não está ativa.'
          USING ERRCODE = 'FA205',
                DETAIL = pg_catalog.format('region %s inativa.', NEW.region_id);
      END IF;

      IF region_group_id IS DISTINCT FROM company_group_id THEN
        RAISE EXCEPTION 'A região precisa ser do mesmo grupo econômico da empresa.'
          USING ERRCODE = 'FA206',
                DETAIL = pg_catalog.format('region %s, company %s.', NEW.region_id, NEW.company_id);
      END IF;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION app.validate_terminal() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NEW.deleted_at IS NULL THEN
    PERFORM 1 FROM public.branch b
      WHERE b.id = NEW.branch_id AND b.deleted_at IS NULL
      FOR SHARE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'A filial informada não está ativa.'
        USING ERRCODE = 'FA208',
              DETAIL = pg_catalog.format('branch %s inativa.', NEW.branch_id);
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION app.validate_user_branch() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  user_group_id uuid;
  branch_economic_group_id uuid;
BEGIN
  IF NEW.deleted_at IS NOT NULL THEN
    RETURN NEW;
  END IF;

  SELECT u.economic_group_id INTO user_group_id
    FROM public.user_account u
   WHERE u.id = NEW.user_id AND u.deleted_at IS NULL
     FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O usuário informado não está ativo.'
      USING ERRCODE = 'FA209',
            DETAIL = pg_catalog.format('user_account %s inativo.', NEW.user_id);
  END IF;

  SELECT c.economic_group_id INTO branch_economic_group_id
    FROM public.branch b
    JOIN public.company c ON c.id = b.company_id
   WHERE b.id = NEW.branch_id AND b.deleted_at IS NULL
     FOR SHARE OF b;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'A filial informada não está ativa.'
      USING ERRCODE = 'FA208',
            DETAIL = pg_catalog.format('branch %s inativa.', NEW.branch_id);
  END IF;

  IF user_group_id IS DISTINCT FROM branch_economic_group_id THEN
    RAISE EXCEPTION 'O usuário só pode ser vinculado a filiais do seu grupo econômico.'
      USING ERRCODE = 'FA210',
            DETAIL = pg_catalog.format('user_account %s, branch %s.', NEW.user_id, NEW.branch_id);
  END IF;

  RETURN NEW;
END;
$$;
