-- Up Migration

-- Cadastro de empresas e filiais pela retaguarda. Toda escrita da API passa pelas funções deste
-- arquivo, e só quem tem structure.manage em todas as filiais do grupo altera a estrutura.

-- Endereço do estabelecimento: a nota fiscal exige. Fica vazio até alguém informar, e quem
-- confere se está completo é a emissão.
ALTER TABLE branch
  ADD COLUMN postal_code text CONSTRAINT branch_postal_code_check CHECK (postal_code ~ '^[0-9]{8}$'),
  ADD COLUMN street text CONSTRAINT branch_street_check CHECK (length(street) <= 150),
  ADD COLUMN street_number text CONSTRAINT branch_street_number_check CHECK (length(street_number) <= 20),
  ADD COLUMN complement text CONSTRAINT branch_complement_check CHECK (length(complement) <= 100),
  ADD COLUMN district text CONSTRAINT branch_district_check CHECK (length(district) <= 100),
  ADD COLUMN city text CONSTRAINT branch_city_check CHECK (length(city) <= 100),
  ADD COLUMN city_code text CONSTRAINT branch_city_code_check CHECK (city_code ~ '^[0-9]{7}$'),
  ADD COLUMN phone text CONSTRAINT branch_phone_check CHECK (phone ~ '^[0-9]{10,11}$');
CREATE OR REPLACE VIEW v_branch WITH (security_invoker = true) AS
  SELECT * FROM branch WHERE deleted_at IS NULL;

-- Histórico de mudança de empresa. É ele que libera a troca: só a função de mover escreve aqui.
CREATE TABLE branch_company_event (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  branch_id uuid NOT NULL REFERENCES branch (id),
  from_company_id uuid NOT NULL REFERENCES company (id),
  to_company_id uuid NOT NULL REFERENCES company (id),
  transaction_id xid8 NOT NULL DEFAULT pg_current_xact_id(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE INDEX branch_company_event_branch_idx ON branch_company_event (branch_id);
CALL app.apply_table_standard('public.branch_company_event');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON branch_company_event
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'branch_id', 'from_company_id', 'to_company_id', 'transaction_id'
  );

CREATE POLICY branch_company_event_select ON branch_company_event FOR SELECT TO farmaerp_app
  USING (
    economic_group_id = (SELECT app.permission_group('structure.manage'))
    OR economic_group_id = (SELECT app.permission_group('branches.view_all'))
  );
GRANT SELECT ON branch_company_event TO farmaerp_app;
CREATE VIEW v_branch_company_event WITH (security_invoker = true) AS
  SELECT * FROM branch_company_event WHERE deleted_at IS NULL;
GRANT SELECT ON v_branch_company_event TO farmaerp_app;

-- A empresa da filial só muda com o registro feito nesta mesma transação, sempre dentro do grupo.
DROP TRIGGER block_immutable_columns ON branch;
CREATE FUNCTION app.guard_branch_company() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NEW.company_id IS DISTINCT FROM OLD.company_id AND NOT EXISTS (
    SELECT 1 FROM public.branch_company_event e
     WHERE e.branch_id = NEW.id
       AND e.from_company_id = OLD.company_id
       AND e.to_company_id = NEW.company_id
       AND e.transaction_id = pg_catalog.pg_current_xact_id()
  ) THEN
    RAISE EXCEPTION 'Este dado não pode ser alterado depois do cadastro.'
      USING ERRCODE = 'FA104',
            DETAIL = pg_catalog.format('Alteração de company_id em public.branch %s.', NEW.id);
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER guard_branch_company BEFORE UPDATE ON branch
  FOR EACH ROW EXECUTE FUNCTION app.guard_branch_company();

CREATE FUNCTION app.require_structure_manage() RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.permission_group('structure.manage');
BEGIN
  IF group_id IS NULL THEN
    RAISE EXCEPTION 'Você não tem permissão para esta operação.'
      USING ERRCODE = 'FA002', DETAIL = 'structure.manage em todas as filiais.';
  END IF;
  RETURN group_id;
END;
$$;

CREATE FUNCTION app.clean_cnpj(p_cnpj text) RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$
  SELECT pg_catalog.upper(pg_catalog.regexp_replace(COALESCE(p_cnpj, ''), '[^0-9A-Za-z]', '', 'g'))
$$;

CREATE FUNCTION app.require_valid_cnpj(p_cnpj text) RETURNS text
LANGUAGE plpgsql IMMUTABLE
SET search_path = ''
AS $$
DECLARE
  clean text := app.clean_cnpj(p_cnpj);
BEGIN
  IF NOT app.is_valid_cnpj(clean) THEN
    RAISE EXCEPTION 'O CNPJ informado é inválido.' USING ERRCODE = 'FA211';
  END IF;
  RETURN clean;
END;
$$;

CREATE FUNCTION app.only_digits(p_value text) RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$
  SELECT NULLIF(pg_catalog.regexp_replace(COALESCE(p_value, ''), '[^0-9]', '', 'g'), '')
$$;

CREATE FUNCTION app.blank_to_null(p_value text) RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$
  SELECT NULLIF(pg_catalog.btrim(COALESCE(p_value, '')), '')
$$;

-- Certificado de outra raiz não serve mais para a filial: encerra, e a tela avisa.
CREATE FUNCTION app.end_branch_certificate(p_branch_id uuid, p_keep_root text) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  UPDATE public.branch_certificate bc SET deleted_at = pg_catalog.clock_timestamp()
   WHERE bc.branch_id = p_branch_id AND bc.deleted_at IS NULL
     AND (p_keep_root IS NULL OR pg_catalog.left(bc.cnpj, 8) <> p_keep_root);
  RETURN FOUND;
END;
$$;

CREATE FUNCTION app.create_branch(p_company_id uuid, p_data jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.require_structure_manage();
  new_id uuid;
BEGIN
  PERFORM 1 FROM public.company c
    WHERE c.id = p_company_id AND c.economic_group_id = group_id AND c.deleted_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'A empresa informada não está ativa.'
      USING ERRCODE = 'FA204', DETAIL = pg_catalog.format('company %s.', p_company_id);
  END IF;

  INSERT INTO public.branch (
    company_id, name, cnpj, state, pmc_region, postal_code, street, street_number, complement,
    district, city, city_code, phone
  ) VALUES (
    p_company_id,
    COALESCE(pg_catalog.btrim(p_data ->> 'name'), ''),
    app.require_valid_cnpj(p_data ->> 'cnpj'),
    app.blank_to_null(p_data ->> 'state'),
    app.blank_to_null(p_data ->> 'pmcRegion'),
    app.only_digits(p_data ->> 'postalCode'),
    app.blank_to_null(p_data ->> 'street'),
    app.blank_to_null(p_data ->> 'streetNumber'),
    app.blank_to_null(p_data ->> 'complement'),
    app.blank_to_null(p_data ->> 'district'),
    app.blank_to_null(p_data ->> 'city'),
    app.only_digits(p_data ->> 'cityCode'),
    app.only_digits(p_data ->> 'phone')
  ) RETURNING id INTO new_id;
  RETURN new_id;
END;
$$;

-- A raiz vem do CNPJ informado. A primeira filial é opcional, e entra junto ou nada entra.
CREATE FUNCTION app.create_company(p_cnpj text, p_legal_name text, p_trade_name text, p_branch jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.require_structure_manage();
  clean text := app.require_valid_cnpj(p_cnpj);
  company_id uuid;
  branch_id uuid;
BEGIN
  INSERT INTO public.company (economic_group_id, legal_name, trade_name, cnpj_root)
  VALUES (
    group_id, COALESCE(pg_catalog.btrim(p_legal_name), ''), COALESCE(pg_catalog.btrim(p_trade_name), ''),
    pg_catalog.left(clean, 8)
  ) RETURNING id INTO company_id;

  IF p_branch IS NOT NULL THEN
    branch_id := app.create_branch(company_id, p_branch || pg_catalog.jsonb_build_object('cnpj', clean));
  END IF;
  RETURN pg_catalog.jsonb_build_object('id', company_id, 'branchId', branch_id);
END;
$$;

CREATE FUNCTION app.update_company(p_id uuid, p_legal_name text, p_trade_name text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.require_structure_manage();
BEGIN
  UPDATE public.company c
     SET legal_name = COALESCE(pg_catalog.btrim(p_legal_name), ''),
         trade_name = COALESCE(pg_catalog.btrim(p_trade_name), '')
   WHERE c.id = p_id AND c.economic_group_id = group_id AND c.deleted_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('company %s.', p_id);
  END IF;
END;
$$;

-- Com filial ativa, o gatilho de filhos ativos recusa.
CREATE FUNCTION app.delete_company(p_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.require_structure_manage();
BEGIN
  UPDATE public.company c SET deleted_at = pg_catalog.clock_timestamp()
   WHERE c.id = p_id AND c.economic_group_id = group_id AND c.deleted_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('company %s.', p_id);
  END IF;
END;
$$;

-- Devolve se o certificado precisou ser encerrado porque o CNPJ mudou de raiz.
CREATE FUNCTION app.update_branch(p_id uuid, p_data jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.require_structure_manage();
  clean text := app.require_valid_cnpj(p_data ->> 'cnpj');
BEGIN
  UPDATE public.branch b
     SET name = COALESCE(pg_catalog.btrim(p_data ->> 'name'), ''),
         cnpj = clean,
         state = app.blank_to_null(p_data ->> 'state'),
         pmc_region = app.blank_to_null(p_data ->> 'pmcRegion'),
         postal_code = app.only_digits(p_data ->> 'postalCode'),
         street = app.blank_to_null(p_data ->> 'street'),
         street_number = app.blank_to_null(p_data ->> 'streetNumber'),
         complement = app.blank_to_null(p_data ->> 'complement'),
         district = app.blank_to_null(p_data ->> 'district'),
         city = app.blank_to_null(p_data ->> 'city'),
         city_code = app.only_digits(p_data ->> 'cityCode'),
         phone = app.only_digits(p_data ->> 'phone')
    FROM public.company c
   WHERE b.id = p_id AND b.deleted_at IS NULL
     AND c.id = b.company_id AND c.economic_group_id = group_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('branch %s.', p_id);
  END IF;
  RETURN pg_catalog.jsonb_build_object(
    'certificateEnded', app.end_branch_certificate(p_id, pg_catalog.left(clean, 8))
  );
END;
$$;

-- Terminais, estoque e preços são da filial e continuam com ela. O certificado sai, porque a
-- criptografia dele é por empresa; o CSC é por filial e continua valendo.
CREATE FUNCTION app.move_branch(p_id uuid, p_company_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.require_structure_manage();
  current_company uuid;
BEGIN
  SELECT b.company_id INTO current_company
    FROM public.branch b
    JOIN public.company c ON c.id = b.company_id
   WHERE b.id = p_id AND b.deleted_at IS NULL AND c.economic_group_id = group_id
     FOR UPDATE OF b;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('branch %s.', p_id);
  END IF;

  PERFORM 1 FROM public.company c
    WHERE c.id = p_company_id AND c.economic_group_id = group_id AND c.deleted_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'A empresa informada não está ativa.'
      USING ERRCODE = 'FA204', DETAIL = pg_catalog.format('company %s.', p_company_id);
  END IF;

  IF current_company = p_company_id THEN
    RETURN pg_catalog.jsonb_build_object('moved', false, 'certificateEnded', false);
  END IF;

  INSERT INTO public.branch_company_event (economic_group_id, branch_id, from_company_id, to_company_id)
  VALUES (group_id, p_id, current_company, p_company_id);
  UPDATE public.branch b SET company_id = p_company_id WHERE b.id = p_id;
  RETURN pg_catalog.jsonb_build_object(
    'moved', true, 'certificateEnded', app.end_branch_certificate(p_id, NULL)
  );
END;
$$;

-- Só encerra sem terminal em uso e sem estoque. Terminais revogados, vínculos de usuário,
-- certificado e CSC da filial terminam junto; o histórico continua no banco.
CREATE FUNCTION app.delete_branch(p_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.require_structure_manage();
BEGIN
  PERFORM 1 FROM public.branch b
    JOIN public.company c ON c.id = b.company_id
   WHERE b.id = p_id AND b.deleted_at IS NULL AND c.economic_group_id = group_id
     FOR UPDATE OF b;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('branch %s.', p_id);
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.terminal t
     WHERE t.branch_id = p_id AND t.deleted_at IS NULL AND t.status <> 'revoked'
  ) THEN
    RAISE EXCEPTION 'A filial ainda tem terminal em uso ou saldo em estoque.'
      USING ERRCODE = 'FA224', DETAIL = pg_catalog.format('branch %s com terminal em uso.', p_id);
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.stock_balance s
     WHERE s.branch_id = p_id AND s.deleted_at IS NULL AND s.quantity <> 0
  ) THEN
    RAISE EXCEPTION 'A filial ainda tem terminal em uso ou saldo em estoque.'
      USING ERRCODE = 'FA224', DETAIL = pg_catalog.format('branch %s com saldo em estoque.', p_id);
  END IF;

  UPDATE public.terminal t SET deleted_at = pg_catalog.clock_timestamp()
   WHERE t.branch_id = p_id AND t.deleted_at IS NULL;
  UPDATE public.user_role ur SET deleted_at = pg_catalog.clock_timestamp()
   WHERE ur.branch_id = p_id AND ur.deleted_at IS NULL;
  UPDATE public.user_branch ub SET deleted_at = pg_catalog.clock_timestamp()
   WHERE ub.branch_id = p_id AND ub.deleted_at IS NULL;
  UPDATE public.branch_certificate bc SET deleted_at = pg_catalog.clock_timestamp()
   WHERE bc.branch_id = p_id AND bc.deleted_at IS NULL;
  UPDATE public.branch_csc bc SET deleted_at = pg_catalog.clock_timestamp()
   WHERE bc.branch_id = p_id AND bc.deleted_at IS NULL;
  UPDATE public.branch b SET deleted_at = pg_catalog.clock_timestamp() WHERE b.id = p_id;
END;
$$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  app.create_company(text, text, text, jsonb),
  app.update_company(uuid, text, text),
  app.delete_company(uuid),
  app.create_branch(uuid, jsonb),
  app.update_branch(uuid, jsonb),
  app.move_branch(uuid, uuid),
  app.delete_branch(uuid)
TO farmaerp_app;
