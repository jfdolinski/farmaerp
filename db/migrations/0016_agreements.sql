-- Up Migration

-- Inscrição estadual do cliente e convênios com matrícula e limite.
-- Toda escrita da API passa pelas funções app.*.

-- Tamanho da inscrição estadual por estado. O dígito verificador tem regra própria em cada
-- estado e entra com o Fiscal: aqui só se evita o erro mais comum, que é faltar ou sobrar dígito.
CREATE FUNCTION app.is_valid_state_registration(p_registration text, p_state text) RETURNS boolean
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$
  SELECT p_registration = 'ISENTO'
      OR (
        p_registration ~ '^[0-9]+$'
        AND pg_catalog.length(p_registration) = ANY (CASE p_state
          WHEN 'AC' THEN ARRAY[13]
          WHEN 'AL' THEN ARRAY[9]
          WHEN 'AP' THEN ARRAY[9]
          WHEN 'AM' THEN ARRAY[9]
          WHEN 'BA' THEN ARRAY[8, 9]
          WHEN 'CE' THEN ARRAY[9]
          WHEN 'DF' THEN ARRAY[13]
          WHEN 'ES' THEN ARRAY[9]
          WHEN 'GO' THEN ARRAY[9]
          WHEN 'MA' THEN ARRAY[9]
          WHEN 'MT' THEN ARRAY[11]
          WHEN 'MS' THEN ARRAY[9]
          WHEN 'MG' THEN ARRAY[13]
          WHEN 'PA' THEN ARRAY[9]
          WHEN 'PB' THEN ARRAY[9]
          WHEN 'PR' THEN ARRAY[10]
          WHEN 'PE' THEN ARRAY[9, 14]
          WHEN 'PI' THEN ARRAY[9]
          WHEN 'RJ' THEN ARRAY[8]
          WHEN 'RN' THEN ARRAY[9, 10]
          WHEN 'RS' THEN ARRAY[10]
          WHEN 'RO' THEN ARRAY[9, 14]
          WHEN 'RR' THEN ARRAY[9]
          WHEN 'SC' THEN ARRAY[9]
          WHEN 'SP' THEN ARRAY[12]
          WHEN 'SE' THEN ARRAY[9]
          WHEN 'TO' THEN ARRAY[9, 11]
          ELSE ARRAY[]::int[]
        END)
      )
$$;

ALTER TABLE customer
  ADD COLUMN state_registration text,
  -- Sem estado não há como conferir: a inscrição exige o estado do endereço.
  ADD CONSTRAINT customer_state_registration_check CHECK (
    state_registration IS NULL OR app.is_valid_state_registration(state_registration, state)
  );

-- security_invoker precisa ser repetido: CREATE OR REPLACE substitui as opções da view.
CREATE OR REPLACE VIEW v_customer WITH (security_invoker = true) AS
  SELECT * FROM customer WHERE deleted_at IS NULL;

-- Grava a inscrição pelas funções que já existem: a nova coluna entra no mesmo cadastro.
CREATE OR REPLACE FUNCTION app.create_customer(p_data jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.require_customers_manage();
  new_id uuid;
BEGIN
  INSERT INTO public.customer (
    economic_group_id, person_type, document, name, trade_name, birth_date, phone, email,
    postal_code, street, street_number, complement, district, city, city_code, state, state_registration
  ) VALUES (
    group_id, p_data ->> 'personType', COALESCE(app.clean_document(p_data ->> 'document'), ''),
    COALESCE(app.clean_text(p_data ->> 'name'), ''), app.clean_text(p_data ->> 'tradeName'),
    (p_data ->> 'birthDate')::date, app.clean_digits(p_data ->> 'phone'),
    pg_catalog.lower(app.clean_text(p_data ->> 'email')), app.clean_digits(p_data ->> 'postalCode'),
    app.clean_text(p_data ->> 'street'), app.clean_text(p_data ->> 'streetNumber'),
    app.clean_text(p_data ->> 'complement'), app.clean_text(p_data ->> 'district'),
    app.clean_text(p_data ->> 'city'), app.clean_digits(p_data ->> 'cityCode'),
    pg_catalog.upper(app.clean_text(p_data ->> 'state')),
    app.clean_state_registration(p_data ->> 'stateRegistration')
  ) RETURNING id INTO new_id;
  RETURN new_id;
END;
$$;

CREATE OR REPLACE FUNCTION app.update_customer(p_id uuid, p_data jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.require_customers_manage();
BEGIN
  UPDATE public.customer c
     SET document = COALESCE(app.clean_document(p_data ->> 'document'), ''),
         name = COALESCE(app.clean_text(p_data ->> 'name'), ''),
         trade_name = app.clean_text(p_data ->> 'tradeName'),
         birth_date = (p_data ->> 'birthDate')::date,
         phone = app.clean_digits(p_data ->> 'phone'),
         email = pg_catalog.lower(app.clean_text(p_data ->> 'email')),
         postal_code = app.clean_digits(p_data ->> 'postalCode'),
         street = app.clean_text(p_data ->> 'street'),
         street_number = app.clean_text(p_data ->> 'streetNumber'),
         complement = app.clean_text(p_data ->> 'complement'),
         district = app.clean_text(p_data ->> 'district'),
         city = app.clean_text(p_data ->> 'city'),
         city_code = app.clean_digits(p_data ->> 'cityCode'),
         state = pg_catalog.upper(app.clean_text(p_data ->> 'state')),
         state_registration = app.clean_state_registration(p_data ->> 'stateRegistration')
   WHERE c.id = p_id AND c.economic_group_id = group_id AND c.deleted_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('customer %s.', p_id);
  END IF;
END;
$$;

-- "Isento" em qualquer grafia vira ISENTO; o resto fica só com os dígitos.
CREATE FUNCTION app.clean_state_registration(p_value text) RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$
  SELECT CASE
    WHEN pg_catalog.upper(pg_catalog.btrim(COALESCE(p_value, ''))) = 'ISENTO' THEN 'ISENTO'
    ELSE app.clean_digits(p_value)
  END
$$;

CREATE TABLE agreement (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  name text NOT NULL CONSTRAINT agreement_name_check CHECK (btrim(name) <> '' AND length(name) <= 150),
  -- Empresa conveniada, quando houver.
  cnpj text CONSTRAINT agreement_cnpj_check CHECK (cnpj IS NULL OR app.is_valid_cnpj(cnpj)),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE UNIQUE INDEX agreement_name_active_key
  ON agreement (economic_group_id, lower(name)) WHERE deleted_at IS NULL;

CREATE TABLE customer_agreement (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  customer_id uuid NOT NULL REFERENCES customer (id),
  agreement_id uuid NOT NULL REFERENCES agreement (id),
  registration text NOT NULL CONSTRAINT customer_agreement_registration_check CHECK (
    btrim(registration) <> '' AND length(registration) <= 40
  ),
  -- Limite de compra pelo convênio. O consumo chega com a venda.
  credit_limit numeric(12, 2) NOT NULL CONSTRAINT customer_agreement_credit_limit_check CHECK (credit_limit >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE UNIQUE INDEX customer_agreement_active_key
  ON customer_agreement (customer_id, agreement_id) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX customer_agreement_registration_active_key
  ON customer_agreement (agreement_id, upper(registration)) WHERE deleted_at IS NULL;
CREATE INDEX customer_agreement_agreement_id_idx ON customer_agreement (agreement_id);

CALL app.apply_table_standard('public.agreement');
CALL app.apply_table_standard('public.customer_agreement');

CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON agreement
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns('economic_group_id');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON customer_agreement
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns('economic_group_id', 'customer_id', 'agreement_id');

CREATE FUNCTION app.validate_customer_agreement() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NEW.deleted_at IS NULL AND (
    NOT EXISTS (
      SELECT 1 FROM public.customer c
       WHERE c.id = NEW.customer_id AND c.economic_group_id = NEW.economic_group_id AND c.deleted_at IS NULL
    ) OR NOT EXISTS (
      SELECT 1 FROM public.agreement a
       WHERE a.id = NEW.agreement_id AND a.economic_group_id = NEW.economic_group_id AND a.deleted_at IS NULL
    )
  ) THEN
    RAISE EXCEPTION 'Um dos itens informados não foi encontrado.'
      USING ERRCODE = 'FA004', DETAIL = pg_catalog.format('customer %s, agreement %s.', NEW.customer_id, NEW.agreement_id);
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER validate_parent BEFORE INSERT OR UPDATE ON customer_agreement
  FOR EACH ROW EXECUTE FUNCTION app.validate_customer_agreement();

-- Convênio com cliente vinculado não sai: os vínculos precisam ser encerrados antes.
CREATE FUNCTION app.protect_agreement() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.customer_agreement ca WHERE ca.agreement_id = NEW.id AND ca.deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Este registro ainda tem itens ativos vinculados.'
      USING ERRCODE = 'FA105', DETAIL = pg_catalog.format('agreement %s.', NEW.id);
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER protect_links BEFORE UPDATE ON agreement
  FOR EACH ROW EXECUTE FUNCTION app.protect_agreement();

-- O limite é crédito: só quem tem a permissão em todas as filiais cuida dos convênios.
CREATE FUNCTION app.require_agreements_manage() RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.permission_group('agreements.manage');
BEGIN
  IF group_id IS NULL THEN
    RAISE EXCEPTION 'Você não tem permissão para esta operação.'
      USING ERRCODE = 'FA002', DETAIL = 'Alteração de convênio sem agreements.manage.';
  END IF;
  RETURN group_id;
END;
$$;

CREATE FUNCTION app.create_agreement(p_name text, p_cnpj text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.require_agreements_manage();
  new_id uuid;
BEGIN
  INSERT INTO public.agreement (economic_group_id, name, cnpj)
  VALUES (group_id, COALESCE(app.clean_text(p_name), ''), app.clean_document(p_cnpj))
  RETURNING id INTO new_id;
  RETURN new_id;
END;
$$;

CREATE FUNCTION app.update_agreement(p_id uuid, p_name text, p_cnpj text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.require_agreements_manage();
BEGIN
  UPDATE public.agreement a
     SET name = COALESCE(app.clean_text(p_name), ''), cnpj = app.clean_document(p_cnpj)
   WHERE a.id = p_id AND a.economic_group_id = group_id AND a.deleted_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('agreement %s.', p_id);
  END IF;
END;
$$;

CREATE FUNCTION app.delete_agreement(p_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.require_agreements_manage();
BEGIN
  UPDATE public.agreement a SET deleted_at = pg_catalog.clock_timestamp()
   WHERE a.id = p_id AND a.economic_group_id = group_id AND a.deleted_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('agreement %s.', p_id);
  END IF;
END;
$$;

CREATE FUNCTION app.link_customer_agreement(p_customer_id uuid, p_agreement_id uuid, p_registration text, p_limit numeric) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.require_agreements_manage();
  new_id uuid;
BEGIN
  INSERT INTO public.customer_agreement (economic_group_id, customer_id, agreement_id, registration, credit_limit)
  VALUES (group_id, p_customer_id, p_agreement_id, COALESCE(app.clean_text(p_registration), ''), p_limit)
  RETURNING id INTO new_id;
  RETURN new_id;
END;
$$;

CREATE FUNCTION app.update_customer_agreement(p_id uuid, p_registration text, p_limit numeric) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.require_agreements_manage();
BEGIN
  UPDATE public.customer_agreement ca
     SET registration = COALESCE(app.clean_text(p_registration), ''), credit_limit = p_limit
   WHERE ca.id = p_id AND ca.economic_group_id = group_id AND ca.deleted_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('customer_agreement %s.', p_id);
  END IF;
END;
$$;

CREATE FUNCTION app.unlink_customer_agreement(p_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.require_agreements_manage();
BEGIN
  UPDATE public.customer_agreement ca SET deleted_at = pg_catalog.clock_timestamp()
   WHERE ca.id = p_id AND ca.economic_group_id = group_id AND ca.deleted_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('customer_agreement %s.', p_id);
  END IF;
END;
$$;

-- Quem vê clientes vê os convênios e os vínculos.
CREATE POLICY agreement_select ON agreement FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group())
         AND (SELECT app.has_permission_anywhere('customers.view')
                  OR app.has_permission_anywhere('customers.manage')
                  OR app.has_permission_anywhere('agreements.manage')));
CREATE POLICY customer_agreement_select ON customer_agreement FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group())
         AND (SELECT app.has_permission_anywhere('customers.view')
                  OR app.has_permission_anywhere('customers.manage')
                  OR app.has_permission_anywhere('agreements.manage')));

GRANT SELECT ON agreement, customer_agreement TO farmaerp_app;

CREATE VIEW v_agreement WITH (security_invoker = true) AS
  SELECT * FROM agreement WHERE deleted_at IS NULL;
CREATE VIEW v_customer_agreement WITH (security_invoker = true) AS
  SELECT * FROM customer_agreement WHERE deleted_at IS NULL;
GRANT SELECT ON v_agreement, v_customer_agreement TO farmaerp_app;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  app.is_valid_state_registration(text, text),
  app.create_customer(jsonb),
  app.update_customer(uuid, jsonb),
  app.create_agreement(text, text),
  app.update_agreement(uuid, text, text),
  app.delete_agreement(uuid),
  app.link_customer_agreement(uuid, uuid, text, numeric),
  app.update_customer_agreement(uuid, text, numeric),
  app.unlink_customer_agreement(uuid)
TO farmaerp_app;
