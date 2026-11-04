-- Up Migration

-- Estrutura societária: grupo econômico > empresa > filial > terminal.
-- Organização das filiais: grupo econômico > grupo de filial > região > filial.

-- Valida CNPJ numérico e alfanumérico (IN RFB 2.229/2024).
-- Cada caractere vale o código ASCII menos 48; os dois últimos são dígitos verificadores.
CREATE FUNCTION app.is_valid_cnpj(cnpj text) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE
SET search_path = ''
AS $$
DECLARE
  first_weights  constant int[] := ARRAY[5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2];
  second_weights constant int[] := ARRAY[6, 5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2];
  total int := 0;
  remainder int;
  first_digit int;
  second_digit int;
BEGIN
  IF cnpj IS NULL OR cnpj !~ '^[0-9A-Z]{12}[0-9]{2}$' OR cnpj ~ '^(.)\1{13}$' THEN
    RETURN false;
  END IF;

  FOR pos IN 1..12 LOOP
    total := total + (pg_catalog.ascii(pg_catalog.substr(cnpj, pos, 1)) - 48) * first_weights[pos];
  END LOOP;
  remainder := total % 11;
  first_digit := CASE WHEN remainder < 2 THEN 0 ELSE 11 - remainder END;

  total := 0;
  FOR pos IN 1..12 LOOP
    total := total + (pg_catalog.ascii(pg_catalog.substr(cnpj, pos, 1)) - 48) * second_weights[pos];
  END LOOP;
  total := total + first_digit * second_weights[13];
  remainder := total % 11;
  second_digit := CASE WHEN remainder < 2 THEN 0 ELSE 11 - remainder END;

  RETURN pg_catalog.substr(cnpj, 13, 1)::int = first_digit
     AND pg_catalog.substr(cnpj, 14, 1)::int = second_digit;
END;
$$;

CREATE TABLE economic_group (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  name text NOT NULL CHECK (btrim(name) <> ''),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid
);

CREATE TABLE company (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  legal_name text NOT NULL CHECK (btrim(legal_name) <> ''),
  trade_name text NOT NULL CHECK (btrim(trade_name) <> ''),
  cnpj_root char(8) NOT NULL CHECK (cnpj_root ~ '^[0-9A-Z]{8}$'),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid
);
CREATE INDEX company_economic_group_id_idx ON company (economic_group_id);
CREATE UNIQUE INDEX company_cnpj_root_active_key ON company (cnpj_root) WHERE deleted_at IS NULL;

CREATE TABLE branch_group (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  name text NOT NULL CHECK (btrim(name) <> ''),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid
);
CREATE UNIQUE INDEX branch_group_name_active_key ON branch_group (economic_group_id, name) WHERE deleted_at IS NULL;

CREATE TABLE region (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  branch_group_id uuid NOT NULL REFERENCES branch_group (id),
  name text NOT NULL CHECK (btrim(name) <> ''),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid
);
CREATE UNIQUE INDEX region_name_active_key ON region (branch_group_id, name) WHERE deleted_at IS NULL;

-- Todo estabelecimento é uma filial, inclusive a matriz.
CREATE TABLE branch (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  company_id uuid NOT NULL REFERENCES company (id),
  region_id uuid REFERENCES region (id),
  name text NOT NULL CHECK (btrim(name) <> ''),
  cnpj char(14) NOT NULL CHECK (app.is_valid_cnpj(cnpj)),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid
);
CREATE INDEX branch_region_id_idx ON branch (region_id);
CREATE UNIQUE INDEX branch_cnpj_active_key ON branch (cnpj) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX branch_name_active_key ON branch (company_id, name) WHERE deleted_at IS NULL;

-- O nome e o perfil são definidos na aprovação; antes disso o terminal fica pendente.
CREATE TABLE terminal (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  branch_id uuid NOT NULL REFERENCES branch (id),
  name text CHECK (btrim(name) <> ''),
  profile text CHECK (profile IN ('quote', 'cashier', 'self_service')),
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'active', 'blocked', 'revoked')),
  public_key text NOT NULL CHECK (btrim(public_key) <> ''),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  CONSTRAINT terminal_approved_has_name_and_profile CHECK (
    status = 'pending' OR (name IS NOT NULL AND profile IS NOT NULL)
  )
);
CREATE INDEX terminal_branch_id_idx ON terminal (branch_id);
CREATE UNIQUE INDEX terminal_public_key_active_key ON terminal (public_key) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX terminal_name_active_key ON terminal (branch_id, name) WHERE deleted_at IS NULL;

-- Mínimo para a RLS funcionar; login e perfis entram na Etapa 2.
-- is_group_admin é provisório, até existirem as permissões granulares.
CREATE TABLE user_account (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  name text NOT NULL CHECK (btrim(name) <> ''),
  is_group_admin boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid
);
CREATE INDEX user_account_economic_group_id_idx ON user_account (economic_group_id);

CREATE TABLE user_branch (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  user_id uuid NOT NULL REFERENCES user_account (id),
  branch_id uuid NOT NULL REFERENCES branch (id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid
);
CREATE INDEX user_branch_branch_id_idx ON user_branch (branch_id);
CREATE INDEX user_branch_user_id_idx ON user_branch (user_id);
CREATE UNIQUE INDEX user_branch_active_key ON user_branch (user_id, branch_id) WHERE deleted_at IS NULL;

CALL app.apply_table_standard('public.economic_group');
CALL app.apply_table_standard('public.company');
CALL app.apply_table_standard('public.branch_group');
CALL app.apply_table_standard('public.region');
CALL app.apply_table_standard('public.branch');
CALL app.apply_table_standard('public.terminal');
CALL app.apply_table_standard('public.user_account');
CALL app.apply_table_standard('public.user_branch');

-- Colunas que definem a posição do registro na hierarquia não mudam:
-- isso impede mover dados entre grupos econômicos. Argumentos: nomes das colunas.
CREATE FUNCTION app.block_immutable_columns() RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  column_name text;
BEGIN
  FOREACH column_name IN ARRAY TG_ARGV LOOP
    IF (pg_catalog.to_jsonb(NEW) -> column_name) IS DISTINCT FROM (pg_catalog.to_jsonb(OLD) -> column_name) THEN
      RAISE EXCEPTION 'Este dado não pode ser alterado depois do cadastro.'
        USING ERRCODE = 'restrict_violation',
              DETAIL = pg_catalog.format('Alteração de %I em %I.%I.', column_name, TG_TABLE_SCHEMA, TG_TABLE_NAME);
    END IF;
  END LOOP;
  RETURN NEW;
END;
$$;

CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON company
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns('economic_group_id', 'cnpj_root');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON branch_group
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns('economic_group_id');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON branch
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns('company_id');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON user_account
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns('economic_group_id');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON user_branch
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns('user_id', 'branch_id');

-- Impede a exclusão lógica de um registro com filhos ativos.
-- Argumentos: pares de tabela filha e coluna de ligação.
-- SECURITY DEFINER para enxergar filhos que a RLS esconderia de quem está excluindo.
CREATE FUNCTION app.block_soft_delete_with_active_children() RETURNS trigger
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
      RAISE EXCEPTION 'Este registro ainda tem itens ativos vinculados. Exclua ou mova esses itens primeiro.'
        USING ERRCODE = 'restrict_violation',
              DETAIL = pg_catalog.format('%I possui filhos ativos em %I.', TG_TABLE_NAME, TG_ARGV[i * 2]);
    END IF;
  END LOOP;

  RETURN NEW;
END;
$$;

CREATE TRIGGER block_soft_delete_with_active_children BEFORE UPDATE ON economic_group
  FOR EACH ROW EXECUTE FUNCTION app.block_soft_delete_with_active_children(
    'company', 'economic_group_id',
    'branch_group', 'economic_group_id',
    'user_account', 'economic_group_id');
CREATE TRIGGER block_soft_delete_with_active_children BEFORE UPDATE ON company
  FOR EACH ROW EXECUTE FUNCTION app.block_soft_delete_with_active_children('branch', 'company_id');
CREATE TRIGGER block_soft_delete_with_active_children BEFORE UPDATE ON branch_group
  FOR EACH ROW EXECUTE FUNCTION app.block_soft_delete_with_active_children('region', 'branch_group_id');
CREATE TRIGGER block_soft_delete_with_active_children BEFORE UPDATE ON region
  FOR EACH ROW EXECUTE FUNCTION app.block_soft_delete_with_active_children('branch', 'region_id');
CREATE TRIGGER block_soft_delete_with_active_children BEFORE UPDATE ON branch
  FOR EACH ROW EXECUTE FUNCTION app.block_soft_delete_with_active_children(
    'terminal', 'branch_id',
    'user_branch', 'branch_id');
CREATE TRIGGER block_soft_delete_with_active_children BEFORE UPDATE ON user_account
  FOR EACH ROW EXECUTE FUNCTION app.block_soft_delete_with_active_children('user_branch', 'user_id');

-- As validações abaixo travam o registro pai com FOR SHARE. Assim, uma exclusão lógica
-- concorrente do pai espera esta transação e passa a enxergar o novo filho.

-- Grupo econômico do pai precisa estar ativo. Usado por company, branch_group e user_account.
CREATE FUNCTION app.validate_economic_group_parent() RETURNS trigger
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
        USING ERRCODE = 'foreign_key_violation',
              DETAIL = pg_catalog.format('economic_group %s inativo em %I.', NEW.economic_group_id, TG_TABLE_NAME);
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER validate_parent BEFORE INSERT OR UPDATE ON company
  FOR EACH ROW EXECUTE FUNCTION app.validate_economic_group_parent();
CREATE TRIGGER validate_parent BEFORE INSERT OR UPDATE ON branch_group
  FOR EACH ROW EXECUTE FUNCTION app.validate_economic_group_parent();
CREATE TRIGGER validate_parent BEFORE INSERT OR UPDATE ON user_account
  FOR EACH ROW EXECUTE FUNCTION app.validate_economic_group_parent();

-- A região só pode ser movida para um grupo de filial do mesmo grupo econômico.
CREATE FUNCTION app.validate_region() RETURNS trigger
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
        USING ERRCODE = 'foreign_key_violation',
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
        USING ERRCODE = 'check_violation',
              DETAIL = pg_catalog.format('region %s entre grupos econômicos.', NEW.id);
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER validate_parent BEFORE INSERT OR UPDATE ON region
  FOR EACH ROW EXECUTE FUNCTION app.validate_region();

-- O CNPJ precisa ter a raiz da empresa, e a região precisa ser do mesmo grupo econômico.
CREATE FUNCTION app.validate_branch() RETURNS trigger
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
      USING ERRCODE = 'check_violation',
            DETAIL = pg_catalog.format('branch.cnpj %s, company.cnpj_root %s.', NEW.cnpj, company_root);
  END IF;

  IF NEW.deleted_at IS NULL THEN
    IF company_deleted_at IS NOT NULL THEN
      RAISE EXCEPTION 'A empresa informada não está ativa.'
        USING ERRCODE = 'foreign_key_violation',
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
          USING ERRCODE = 'foreign_key_violation',
                DETAIL = pg_catalog.format('region %s inativa.', NEW.region_id);
      END IF;

      IF region_group_id IS DISTINCT FROM company_group_id THEN
        RAISE EXCEPTION 'A região precisa ser do mesmo grupo econômico da empresa.'
          USING ERRCODE = 'check_violation',
                DETAIL = pg_catalog.format('region %s, company %s.', NEW.region_id, NEW.company_id);
      END IF;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER validate_parent BEFORE INSERT OR UPDATE ON branch
  FOR EACH ROW EXECUTE FUNCTION app.validate_branch();

CREATE FUNCTION app.validate_terminal() RETURNS trigger
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
        USING ERRCODE = 'foreign_key_violation',
              DETAIL = pg_catalog.format('branch %s inativa.', NEW.branch_id);
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER validate_parent BEFORE INSERT OR UPDATE ON terminal
  FOR EACH ROW EXECUTE FUNCTION app.validate_terminal();

-- O usuário só pode ser vinculado a filiais do seu grupo econômico.
CREATE FUNCTION app.validate_user_branch() RETURNS trigger
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
      USING ERRCODE = 'foreign_key_violation',
            DETAIL = pg_catalog.format('user_account %s inativo.', NEW.user_id);
  END IF;

  SELECT c.economic_group_id INTO branch_economic_group_id
    FROM public.branch b
    JOIN public.company c ON c.id = b.company_id
   WHERE b.id = NEW.branch_id AND b.deleted_at IS NULL
     FOR SHARE OF b;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'A filial informada não está ativa.'
      USING ERRCODE = 'foreign_key_violation',
            DETAIL = pg_catalog.format('branch %s inativa.', NEW.branch_id);
  END IF;

  IF user_group_id IS DISTINCT FROM branch_economic_group_id THEN
    RAISE EXCEPTION 'O usuário só pode ser vinculado a filiais do seu grupo econômico.'
      USING ERRCODE = 'check_violation',
            DETAIL = pg_catalog.format('user_account %s, branch %s.', NEW.user_id, NEW.branch_id);
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER validate_parent BEFORE INSERT OR UPDATE ON user_branch
  FOR EACH ROW EXECUTE FUNCTION app.validate_user_branch();

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.current_user_id() TO farmaerp_app;
GRANT EXECUTE ON FUNCTION app.is_valid_cnpj(text) TO farmaerp_app;
