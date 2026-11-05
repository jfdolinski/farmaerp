-- Up Migration

-- Clientes: cadastro único na rede, dependentes e consentimento LGPD por finalidade.
-- Toda escrita da API passa pelas funções app.*. Mensagens de erro e detalhes nunca levam dados
-- do cliente, só identificadores: o log não pode receber dados pessoais.

CREATE FUNCTION app.is_valid_cpf(p_cpf text) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE
SET search_path = ''
AS $$
DECLARE
  total int;
  digit int;
BEGIN
  IF p_cpf IS NULL OR p_cpf !~ '^[0-9]{11}$' OR p_cpf ~ '^(.)\1{10}$' THEN
    RETURN false;
  END IF;
  FOR check_position IN 10..11 LOOP
    total := 0;
    FOR pos IN 1..check_position - 1 LOOP
      total := total + (pg_catalog.substr(p_cpf, pos, 1))::int * (check_position + 1 - pos);
    END LOOP;
    digit := (total * 10) % 11;
    IF digit = 10 THEN
      digit := 0;
    END IF;
    IF digit <> (pg_catalog.substr(p_cpf, check_position, 1))::int THEN
      RETURN false;
    END IF;
  END LOOP;
  RETURN true;
END;
$$;

-- Só para exibição em listas: 123.***.***-09 ou 11.222.***/****-81.
CREATE FUNCTION app.mask_document(p_document text) RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$
  SELECT CASE pg_catalog.length(p_document)
    WHEN 11 THEN pg_catalog.substr(p_document, 1, 3) || '.***.***-' || pg_catalog.substr(p_document, 10, 2)
    WHEN 14 THEN pg_catalog.substr(p_document, 1, 2) || '.' || pg_catalog.substr(p_document, 3, 3) || '.***/****-' || pg_catalog.substr(p_document, 13, 2)
  END
$$;

CREATE TABLE customer (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  code bigint NOT NULL,
  person_type text NOT NULL CONSTRAINT customer_person_type_check CHECK (person_type IN ('individual', 'company')),
  -- CPF ou CNPJ, sem pontuação.
  document text NOT NULL,
  name text NOT NULL CONSTRAINT customer_name_check CHECK (btrim(name) <> '' AND length(name) <= 150),
  trade_name text CONSTRAINT customer_trade_name_check CHECK (trade_name IS NULL OR length(trade_name) <= 150),
  birth_date date,
  phone text CONSTRAINT customer_phone_check CHECK (phone ~ '^[0-9]{10,11}$'),
  email text CONSTRAINT customer_email_check CHECK (email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' AND length(email) <= 200),
  postal_code text CONSTRAINT customer_postal_code_check CHECK (postal_code ~ '^[0-9]{8}$'),
  street text CONSTRAINT customer_street_check CHECK (length(street) <= 150),
  street_number text CONSTRAINT customer_street_number_check CHECK (length(street_number) <= 20),
  complement text CONSTRAINT customer_complement_check CHECK (length(complement) <= 100),
  district text CONSTRAINT customer_district_check CHECK (length(district) <= 100),
  city text CONSTRAINT customer_city_check CHECK (length(city) <= 100),
  -- Código IBGE do município, exigido na nota modelo 55.
  city_code text CONSTRAINT customer_city_code_check CHECK (city_code ~ '^[0-9]{7}$'),
  state char(2) CONSTRAINT customer_state_check CHECK (state IN (
    'AC', 'AL', 'AP', 'AM', 'BA', 'CE', 'DF', 'ES', 'GO', 'MA', 'MT', 'MS', 'MG', 'PA',
    'PB', 'PR', 'PE', 'PI', 'RJ', 'RN', 'RS', 'RO', 'RR', 'SC', 'SP', 'SE', 'TO'
  )),
  search_text text GENERATED ALWAYS AS (
    app.normalize_search(name || ' ' || COALESCE(trade_name, ''))
  ) STORED,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid,
  CONSTRAINT customer_document_check CHECK (
    CASE person_type
      WHEN 'individual' THEN app.is_valid_cpf(document)
      WHEN 'company' THEN app.is_valid_cnpj(document)
      -- Tipo desconhecido é recusado pelo CHECK do tipo, com a mensagem certa.
      ELSE true
    END
  ),
  CONSTRAINT customer_birth_date_check CHECK (birth_date IS NULL OR birth_date >= DATE '1900-01-01')
);
CREATE UNIQUE INDEX customer_document_active_key
  ON customer (economic_group_id, document) WHERE deleted_at IS NULL;
CREATE INDEX customer_search_idx ON customer USING gin (search_text ext.gin_trgm_ops);

CREATE TABLE customer_dependent (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  customer_id uuid NOT NULL REFERENCES customer (id),
  name text NOT NULL CONSTRAINT customer_dependent_name_check CHECK (btrim(name) <> '' AND length(name) <= 150),
  relationship text NOT NULL CONSTRAINT customer_dependent_relationship_check CHECK (relationship IN (
    'spouse', 'child', 'parent', 'sibling', 'grandchild', 'grandparent', 'other'
  )),
  birth_date date CONSTRAINT customer_dependent_birth_date_check CHECK (birth_date IS NULL OR birth_date >= DATE '1900-01-01'),
  cpf text CONSTRAINT customer_dependent_cpf_check CHECK (cpf IS NULL OR app.is_valid_cpf(cpf)),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE INDEX customer_dependent_customer_id_idx ON customer_dependent (customer_id);
CREATE UNIQUE INDEX customer_dependent_cpf_active_key
  ON customer_dependent (customer_id, cpf) WHERE deleted_at IS NULL AND cpf IS NOT NULL;

-- Cada concessão ou revogação é uma linha: a mais recente vale, e as demais são a prova.
CREATE TABLE customer_consent_event (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  customer_id uuid NOT NULL REFERENCES customer (id),
  purpose text NOT NULL CONSTRAINT customer_consent_event_purpose_check CHECK (purpose IN (
    'marketing', 'facial_recognition', 'cashback'
  )),
  granted boolean NOT NULL,
  channel text NOT NULL CONSTRAINT customer_consent_event_channel_check CHECK (channel IN (
    'store', 'phone', 'app', 'website', 'whatsapp'
  )),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE INDEX customer_consent_event_lookup_idx ON customer_consent_event (customer_id, purpose, created_at DESC, id DESC);

CALL app.apply_table_standard('public.customer');
CALL app.apply_table_standard('public.customer_dependent');
CALL app.apply_table_standard('public.customer_consent_event');
CALL app.apply_human_code('public.customer', 'customer');

CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON customer
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns('economic_group_id', 'person_type');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON customer_dependent
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns('economic_group_id', 'customer_id');
-- A prova do consentimento não muda, nem a exclusão lógica.
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON customer_consent_event
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'customer_id', 'purpose', 'granted', 'channel', 'deleted_at'
  );

-- Dependente e consentimento só em cliente ativo do mesmo grupo, por qualquer caminho.
CREATE FUNCTION app.validate_customer_child() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NEW.deleted_at IS NULL AND NOT EXISTS (
    SELECT 1 FROM public.customer c
     WHERE c.id = NEW.customer_id AND c.economic_group_id = NEW.economic_group_id AND c.deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Um dos itens informados não foi encontrado.'
      USING ERRCODE = 'FA004', DETAIL = pg_catalog.format('customer %s.', NEW.customer_id);
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER validate_parent BEFORE INSERT OR UPDATE ON customer_dependent
  FOR EACH ROW EXECUTE FUNCTION app.validate_customer_child();
CREATE TRIGGER validate_parent BEFORE INSERT ON customer_consent_event
  FOR EACH ROW EXECUTE FUNCTION app.validate_customer_child();

-- Nascimento no futuro é erro de digitação. Fica fora do CHECK porque a data de hoje muda.
CREATE FUNCTION app.validate_birth_date() RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF NEW.birth_date > app.local_today() THEN
    RAISE EXCEPTION 'Os dados do cliente são inválidos.'
      USING ERRCODE = 'FA904', DETAIL = pg_catalog.format('Nascimento no futuro em %I.', TG_TABLE_NAME);
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER validate_birth_date BEFORE INSERT OR UPDATE ON customer
  FOR EACH ROW EXECUTE FUNCTION app.validate_birth_date();
CREATE TRIGGER validate_birth_date BEFORE INSERT OR UPDATE ON customer_dependent
  FOR EACH ROW EXECUTE FUNCTION app.validate_birth_date();

INSERT INTO permission (code, module, name) VALUES
  ('customers.view', 'Clientes', 'Ver clientes'),
  ('customers.manage', 'Clientes', 'Cadastrar e editar clientes e registrar consentimento'),
  ('agreements.manage', 'Clientes', 'Cadastrar convênios e vincular matrícula e limite');

CREATE OR REPLACE FUNCTION app.create_default_roles(p_group_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  manager_id uuid;
BEGIN
  INSERT INTO public.role (economic_group_id, name, description, system_key)
  VALUES (p_group_id, 'Administrador', 'Acesso total. Não pode ser alterado.', 'administrator');

  INSERT INTO public.role (economic_group_id, name, description)
  VALUES (p_group_id, 'Gerente', 'Urgências da loja: terminais e senhas temporárias.')
  RETURNING id INTO manager_id;

  INSERT INTO public.role (economic_group_id, name, description) VALUES
    (p_group_id, 'Farmacêutico', 'As permissões chegam com o SNGPC.'),
    (p_group_id, 'Operador de caixa', 'As permissões chegam com o PDV.');

  INSERT INTO public.role_permission (role_id, permission_id)
  SELECT manager_id, p.id
    FROM public.permission p
   WHERE p.code IN (
     'users.view', 'users.reset_password', 'terminals.view', 'terminals.request', 'terminals.block',
     'products.view', 'stock.view', 'stock.loss', 'stock.transfer', 'stock.batch_override',
     'customers.view', 'customers.manage'
   );
END;
$$;

-- Grupos que já existem: o Gerente, identificado pelo nome, atende clientes.
INSERT INTO role_permission (role_id, permission_id)
SELECT r.id, p.id
  FROM role r
 CROSS JOIN permission p
 WHERE r.name = 'Gerente' AND r.deleted_at IS NULL
   AND p.code IN ('customers.view', 'customers.manage');

-- O cliente é da rede: quem tem a permissão em qualquer filial cuida dele.
CREATE FUNCTION app.require_customers_manage() RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT app.has_permission_anywhere('customers.manage') THEN
    RAISE EXCEPTION 'Você não tem permissão para esta operação.'
      USING ERRCODE = 'FA002', DETAIL = 'Alteração de cliente sem customers.manage.';
  END IF;
  RETURN app.current_user_group();
END;
$$;

-- Documento só com letras e números, em caixa alta: aceita o que vier com pontuação.
CREATE FUNCTION app.clean_document(p_document text) RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$
  SELECT NULLIF(pg_catalog.upper(pg_catalog.regexp_replace(COALESCE(p_document, ''), '[^0-9A-Za-z]', '', 'g')), '')
$$;

CREATE FUNCTION app.clean_digits(p_value text) RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$
  SELECT NULLIF(pg_catalog.regexp_replace(COALESCE(p_value, ''), '[^0-9]', '', 'g'), '')
$$;

CREATE FUNCTION app.clean_text(p_value text) RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$
  SELECT NULLIF(pg_catalog.btrim(COALESCE(p_value, '')), '')
$$;

-- Nome e documento vazios viram texto vazio: assim quem recusa é o CHECK, com a mensagem do
-- catálogo, e não o NOT NULL, que chegaria à tela como erro genérico.
CREATE FUNCTION app.create_customer(p_data jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.require_customers_manage();
  new_id uuid;
BEGIN
  INSERT INTO public.customer (
    economic_group_id, person_type, document, name, trade_name, birth_date, phone, email,
    postal_code, street, street_number, complement, district, city, city_code, state
  ) VALUES (
    group_id, p_data ->> 'personType', COALESCE(app.clean_document(p_data ->> 'document'), ''),
    COALESCE(app.clean_text(p_data ->> 'name'), ''), app.clean_text(p_data ->> 'tradeName'),
    (p_data ->> 'birthDate')::date, app.clean_digits(p_data ->> 'phone'),
    pg_catalog.lower(app.clean_text(p_data ->> 'email')), app.clean_digits(p_data ->> 'postalCode'),
    app.clean_text(p_data ->> 'street'), app.clean_text(p_data ->> 'streetNumber'),
    app.clean_text(p_data ->> 'complement'), app.clean_text(p_data ->> 'district'),
    app.clean_text(p_data ->> 'city'), app.clean_digits(p_data ->> 'cityCode'),
    pg_catalog.upper(app.clean_text(p_data ->> 'state'))
  ) RETURNING id INTO new_id;
  RETURN new_id;
END;
$$;

-- O tipo de pessoa não muda. O documento muda, para corrigir digitação, e fica no histórico de auditoria.
CREATE FUNCTION app.update_customer(p_id uuid, p_data jsonb) RETURNS void
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
         state = pg_catalog.upper(app.clean_text(p_data ->> 'state'))
   WHERE c.id = p_id AND c.economic_group_id = group_id AND c.deleted_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('customer %s.', p_id);
  END IF;
END;
$$;

CREATE FUNCTION app.add_customer_dependent(p_customer_id uuid, p_data jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.require_customers_manage();
  new_id uuid;
BEGIN
  INSERT INTO public.customer_dependent (economic_group_id, customer_id, name, relationship, birth_date, cpf)
  VALUES (
    group_id, p_customer_id, COALESCE(app.clean_text(p_data ->> 'name'), ''), p_data ->> 'relationship',
    (p_data ->> 'birthDate')::date, app.clean_digits(p_data ->> 'cpf')
  ) RETURNING id INTO new_id;
  RETURN new_id;
END;
$$;

CREATE FUNCTION app.update_customer_dependent(p_id uuid, p_data jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.require_customers_manage();
BEGIN
  UPDATE public.customer_dependent d
     SET name = COALESCE(app.clean_text(p_data ->> 'name'), ''),
         relationship = p_data ->> 'relationship',
         birth_date = (p_data ->> 'birthDate')::date,
         cpf = app.clean_digits(p_data ->> 'cpf')
   WHERE d.id = p_id AND d.economic_group_id = group_id AND d.deleted_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('customer_dependent %s.', p_id);
  END IF;
END;
$$;

CREATE FUNCTION app.remove_customer_dependent(p_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.require_customers_manage();
BEGIN
  UPDATE public.customer_dependent d SET deleted_at = pg_catalog.clock_timestamp()
   WHERE d.id = p_id AND d.economic_group_id = group_id AND d.deleted_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('customer_dependent %s.', p_id);
  END IF;
END;
$$;

-- Registra só se mudar: repetir o estado atual não gera prova nova, nem confusão.
CREATE FUNCTION app.record_customer_consent(p_customer_id uuid, p_purpose text, p_granted boolean, p_channel text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.require_customers_manage();
  new_id uuid;
BEGIN
  IF p_granted IS NULL THEN
    RAISE EXCEPTION 'Os dados do consentimento são inválidos.'
      USING ERRCODE = 'FA905', DETAIL = 'Consentimento sem decisão.';
  END IF;
  -- Trava o cliente: dois registros ao mesmo tempo não podem passar pela conferência juntos.
  PERFORM 1 FROM public.customer c
   WHERE c.id = p_customer_id AND c.economic_group_id = group_id AND c.deleted_at IS NULL
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('customer %s.', p_customer_id);
  END IF;

  IF p_granted IS NOT DISTINCT FROM (
    SELECT e.granted FROM public.customer_consent_event e
     WHERE e.customer_id = p_customer_id AND e.purpose = p_purpose AND e.deleted_at IS NULL
     ORDER BY e.created_at DESC, e.id DESC LIMIT 1
  ) THEN
    RETURN NULL;
  END IF;
  -- Revogar o que nunca foi concedido não muda nada.
  IF NOT p_granted AND NOT EXISTS (
    SELECT 1 FROM public.customer_consent_event e
     WHERE e.customer_id = p_customer_id AND e.purpose = p_purpose AND e.deleted_at IS NULL
  ) THEN
    RETURN NULL;
  END IF;

  INSERT INTO public.customer_consent_event (economic_group_id, customer_id, purpose, granted, channel)
  VALUES (group_id, p_customer_id, p_purpose, p_granted, p_channel)
  RETURNING id INTO new_id;
  RETURN new_id;
END;
$$;

CREATE POLICY customer_select ON customer FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group())
         AND (SELECT app.has_permission_anywhere('customers.view')
                  OR app.has_permission_anywhere('customers.manage')));
CREATE POLICY customer_dependent_select ON customer_dependent FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group())
         AND (SELECT app.has_permission_anywhere('customers.view')
                  OR app.has_permission_anywhere('customers.manage')));
CREATE POLICY customer_consent_event_select ON customer_consent_event FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group())
         AND (SELECT app.has_permission_anywhere('customers.view')
                  OR app.has_permission_anywhere('customers.manage')));

GRANT SELECT ON customer, customer_dependent, customer_consent_event TO farmaerp_app;

CREATE VIEW v_customer WITH (security_invoker = true) AS
  SELECT * FROM customer WHERE deleted_at IS NULL;
CREATE VIEW v_customer_dependent WITH (security_invoker = true) AS
  SELECT * FROM customer_dependent WHERE deleted_at IS NULL;
CREATE VIEW v_customer_consent_event WITH (security_invoker = true) AS
  SELECT * FROM customer_consent_event WHERE deleted_at IS NULL;
GRANT SELECT ON v_customer, v_customer_dependent, v_customer_consent_event TO farmaerp_app;

-- Busca por nome, código ou documento. O documento sai mascarado: a ficha mostra completo.
-- Roda como quem chama, então a RLS decide o que aparece.
CREATE FUNCTION app.search_customers(p_query text, p_limit integer DEFAULT 50)
RETURNS TABLE (id uuid, code bigint, person_type text, name text, trade_name text, document_masked text, city text, state text)
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  WITH input AS (
    SELECT app.search_patterns(p_query) AS patterns, pg_catalog.btrim(COALESCE(p_query, '')) AS raw,
           app.clean_document(p_query) AS document
  )
  SELECT c.id, c.code, c.person_type, c.name, c.trade_name, app.mask_document(c.document), c.city, c.state::text
    FROM public.customer c
   CROSS JOIN input
   WHERE c.deleted_at IS NULL
     AND (
       input.raw = ''
       OR c.search_text LIKE ALL (input.patterns)
       OR c.code::text = input.raw
       OR c.document = input.document
     )
   ORDER BY c.name, c.id
   LIMIT LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200)
$$;

-- Situação atual de cada finalidade, com a data e o canal da última decisão.
CREATE FUNCTION app.customer_consents(p_customer_id uuid)
RETURNS TABLE (purpose text, granted boolean, channel text, decided_at timestamptz, author text)
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT purposes.purpose, latest.granted, latest.channel, latest.created_at, latest.author
    FROM (VALUES ('marketing'), ('facial_recognition'), ('cashback')) AS purposes(purpose)
    LEFT JOIN LATERAL (
      SELECT e.granted, e.channel, e.created_at, u.name AS author
        FROM public.customer_consent_event e
        LEFT JOIN public.user_account u ON u.id = e.updated_by
       WHERE e.customer_id = p_customer_id AND e.purpose = purposes.purpose AND e.deleted_at IS NULL
       ORDER BY e.created_at DESC, e.id DESC LIMIT 1
    ) AS latest ON true
   -- Sem acesso ao cliente, nada aparece.
   WHERE EXISTS (SELECT 1 FROM public.customer c WHERE c.id = p_customer_id)
$$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  app.is_valid_cpf(text),
  app.mask_document(text),
  app.clean_document(text),
  app.create_customer(jsonb),
  app.update_customer(uuid, jsonb),
  app.add_customer_dependent(uuid, jsonb),
  app.update_customer_dependent(uuid, jsonb),
  app.remove_customer_dependent(uuid),
  app.record_customer_consent(uuid, text, boolean, text),
  app.search_customers(text, integer),
  app.customer_consents(uuid)
TO farmaerp_app;
