-- Up Migration

-- Fornecedores da rede e a relação entre o código do fornecedor e o produto da loja. É a base da
-- entrada de nota: o código que vem no XML aponta o produto e o fracionamento da compra.

CREATE TABLE supplier (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  -- Não muda depois do cadastro: as notas do fornecedor ficam ligadas a ele.
  cnpj text NOT NULL CONSTRAINT supplier_cnpj_check CHECK (app.is_valid_cnpj(cnpj)),
  legal_name text NOT NULL CONSTRAINT supplier_legal_name_check CHECK (btrim(legal_name) <> '' AND length(legal_name) <= 150),
  trade_name text CONSTRAINT supplier_trade_name_check CHECK (length(trade_name) <= 150),
  state_registration text,
  phone text CONSTRAINT supplier_phone_check CHECK (phone ~ '^[0-9]{10,11}$'),
  email text CONSTRAINT supplier_email_check CHECK (email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' AND length(email) <= 200),
  postal_code text CONSTRAINT supplier_postal_code_check CHECK (postal_code ~ '^[0-9]{8}$'),
  street text CONSTRAINT supplier_street_check CHECK (length(street) <= 150),
  street_number text CONSTRAINT supplier_street_number_check CHECK (length(street_number) <= 20),
  complement text CONSTRAINT supplier_complement_check CHECK (length(complement) <= 100),
  district text CONSTRAINT supplier_district_check CHECK (length(district) <= 100),
  city text CONSTRAINT supplier_city_check CHECK (length(city) <= 100),
  city_code text CONSTRAINT supplier_city_code_check CHECK (city_code ~ '^[0-9]{7}$'),
  state char(2) CONSTRAINT supplier_state_check CHECK (state IN (
    'AC', 'AL', 'AP', 'AM', 'BA', 'CE', 'DF', 'ES', 'GO', 'MA', 'MT', 'MS', 'MG', 'PA',
    'PB', 'PR', 'PE', 'PI', 'RJ', 'RN', 'RS', 'RO', 'RR', 'SC', 'SP', 'SE', 'TO'
  )),
  search_text text GENERATED ALWAYS AS (
    app.normalize_search(legal_name || ' ' || COALESCE(trade_name, ''))
  ) STORED,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid,
  -- A inscrição é conferida pelo dígito do estado, então o estado é obrigatório com ela.
  CONSTRAINT supplier_state_registration_check CHECK (
    state_registration IS NULL OR (state IS NOT NULL AND app.is_valid_state_registration(state_registration, state))
  )
);
CREATE UNIQUE INDEX supplier_cnpj_active_key ON supplier (economic_group_id, cnpj) WHERE deleted_at IS NULL;
CREATE INDEX supplier_search_idx ON supplier USING gin (search_text ext.gin_trgm_ops);
CALL app.apply_table_standard('public.supplier');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON supplier
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns('economic_group_id', 'cnpj');

-- O código do fornecedor aponta um produto. Trocar o código é encerrar a relação e criar outra.
CREATE TABLE product_supplier (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  product_id uuid NOT NULL REFERENCES product (id),
  supplier_id uuid NOT NULL REFERENCES supplier (id),
  -- cProd da NF-e: até 60 caracteres, do jeito que o fornecedor manda.
  supplier_code text NOT NULL CONSTRAINT product_supplier_code_check CHECK (
    btrim(supplier_code) <> '' AND supplier_code = btrim(supplier_code) AND length(supplier_code) <= 60
  ),
  -- Vazio: vale o fracionamento do código de barras ou do produto.
  fraction_quantity numeric(10, 3) CONSTRAINT product_supplier_fraction_quantity_check CHECK (fraction_quantity > 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE UNIQUE INDEX product_supplier_code_active_key
  ON product_supplier (supplier_id, supplier_code) WHERE deleted_at IS NULL;
CREATE INDEX product_supplier_product_id_idx ON product_supplier (product_id);
CALL app.apply_table_standard('public.product_supplier');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON product_supplier
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns('economic_group_id', 'product_id', 'supplier_id', 'supplier_code');

-- Produto e fornecedor precisam estar ativos e no grupo da relação, venha a escrita de onde vier.
CREATE FUNCTION app.validate_product_supplier() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NEW.deleted_at IS NULL AND NOT EXISTS (
    SELECT 1 FROM public.product p
     WHERE p.id = NEW.product_id AND p.economic_group_id = NEW.economic_group_id AND p.deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Um dos itens informados não foi encontrado.'
      USING ERRCODE = 'FA004', DETAIL = pg_catalog.format('product %s.', NEW.product_id);
  END IF;
  IF NEW.deleted_at IS NULL AND NOT EXISTS (
    SELECT 1 FROM public.supplier s
     WHERE s.id = NEW.supplier_id AND s.economic_group_id = NEW.economic_group_id AND s.deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Um dos itens informados não foi encontrado.'
      USING ERRCODE = 'FA004', DETAIL = pg_catalog.format('supplier %s.', NEW.supplier_id);
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER validate_parent BEFORE INSERT OR UPDATE ON product_supplier
  FOR EACH ROW EXECUTE FUNCTION app.validate_product_supplier();

-- Três níveis, do mais específico ao mais geral: relação com o fornecedor, código de barras e produto.
DROP FUNCTION app.effective_fraction(uuid, uuid);
CREATE FUNCTION app.effective_fraction(
  p_product_id uuid, p_barcode_id uuid DEFAULT NULL, p_product_supplier_id uuid DEFAULT NULL
) RETURNS numeric
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT COALESCE(
    (SELECT ps.fraction_quantity FROM public.product_supplier ps
      WHERE ps.id = p_product_supplier_id AND ps.product_id = p_product_id AND ps.deleted_at IS NULL),
    (SELECT b.fraction_quantity FROM public.product_barcode b
      WHERE b.id = p_barcode_id AND b.product_id = p_product_id AND b.deleted_at IS NULL),
    (SELECT p.fraction_quantity FROM public.product p WHERE p.id = p_product_id)
  )
$$;

INSERT INTO permission (code, module, name) VALUES
  ('purchases.view', 'Compras', 'Ver fornecedores'),
  ('purchases.manage', 'Compras', 'Cadastrar fornecedores e ligar os códigos deles aos produtos');

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
     'customers.view', 'customers.manage', 'fiscal.certificate', 'purchases.view', 'purchases.manage'
   );
END;
$$;

-- Grupos que já existem: o Gerente, identificado pelo nome, recebe a nota da loja.
INSERT INTO role_permission (role_id, permission_id)
SELECT r.id, p.id
  FROM role r
 CROSS JOIN permission p
 WHERE r.name = 'Gerente' AND r.deleted_at IS NULL AND p.code IN ('purchases.view', 'purchases.manage')
   AND NOT EXISTS (
     SELECT 1 FROM role_permission rp WHERE rp.role_id = r.id AND rp.permission_id = p.id AND rp.deleted_at IS NULL
   );

-- O fornecedor é da rede: quem tem a permissão em qualquer filial cuida dele.
CREATE FUNCTION app.require_purchases_manage() RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT app.has_permission_anywhere('purchases.manage') THEN
    RAISE EXCEPTION 'Você não tem permissão para esta operação.'
      USING ERRCODE = 'FA002', DETAIL = 'Alteração de fornecedor sem purchases.manage.';
  END IF;
  RETURN app.current_user_group();
END;
$$;

-- CNPJ e razão social vazios viram texto vazio: quem recusa é o CHECK, com a mensagem do catálogo.
CREATE FUNCTION app.create_supplier(p_data jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.require_purchases_manage();
  new_id uuid;
BEGIN
  INSERT INTO public.supplier (
    economic_group_id, cnpj, legal_name, trade_name, state_registration, phone, email,
    postal_code, street, street_number, complement, district, city, city_code, state
  ) VALUES (
    group_id, COALESCE(app.clean_document(p_data ->> 'cnpj'), ''),
    COALESCE(app.clean_text(p_data ->> 'legalName'), ''), app.clean_text(p_data ->> 'tradeName'),
    app.clean_state_registration(p_data ->> 'stateRegistration'), app.clean_digits(p_data ->> 'phone'),
    pg_catalog.lower(app.clean_text(p_data ->> 'email')), app.clean_digits(p_data ->> 'postalCode'),
    app.clean_text(p_data ->> 'street'), app.clean_text(p_data ->> 'streetNumber'),
    app.clean_text(p_data ->> 'complement'), app.clean_text(p_data ->> 'district'),
    app.clean_text(p_data ->> 'city'), app.clean_digits(p_data ->> 'cityCode'),
    pg_catalog.upper(app.clean_text(p_data ->> 'state'))
  ) RETURNING id INTO new_id;
  RETURN new_id;
END;
$$;

-- O CNPJ não muda: cadastro com CNPJ errado se encerra e se cria de novo.
CREATE FUNCTION app.update_supplier(p_id uuid, p_data jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.require_purchases_manage();
BEGIN
  UPDATE public.supplier s
     SET legal_name = COALESCE(app.clean_text(p_data ->> 'legalName'), ''),
         trade_name = app.clean_text(p_data ->> 'tradeName'),
         state_registration = app.clean_state_registration(p_data ->> 'stateRegistration'),
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
   WHERE s.id = p_id AND s.economic_group_id = group_id AND s.deleted_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('supplier %s.', p_id);
  END IF;
END;
$$;

-- Encerrar o fornecedor encerra os códigos dele: sem fornecedor, o código não aponta mais nada.
CREATE FUNCTION app.delete_supplier(p_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.require_purchases_manage();
BEGIN
  UPDATE public.supplier s SET deleted_at = pg_catalog.clock_timestamp()
   WHERE s.id = p_id AND s.economic_group_id = group_id AND s.deleted_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('supplier %s.', p_id);
  END IF;
  UPDATE public.product_supplier ps SET deleted_at = pg_catalog.clock_timestamp()
   WHERE ps.supplier_id = p_id AND ps.deleted_at IS NULL;
END;
$$;

-- Código vazio vira texto vazio: quem recusa é o CHECK.
CREATE FUNCTION app.add_product_supplier(p_product_id uuid, p_data jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.require_purchases_manage();
  new_id uuid;
BEGIN
  INSERT INTO public.product_supplier (economic_group_id, product_id, supplier_id, supplier_code, fraction_quantity)
  VALUES (
    group_id, p_product_id, (p_data ->> 'supplierId')::uuid,
    COALESCE(app.clean_text(p_data ->> 'supplierCode'), ''), (p_data ->> 'fractionQuantity')::numeric
  ) RETURNING id INTO new_id;
  RETURN new_id;
END;
$$;

-- Só o fracionamento muda. Vazio volta a valer o do código de barras ou do produto.
CREATE FUNCTION app.update_product_supplier(p_id uuid, p_fraction_quantity numeric) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.require_purchases_manage();
BEGIN
  UPDATE public.product_supplier ps SET fraction_quantity = p_fraction_quantity
   WHERE ps.id = p_id AND ps.economic_group_id = group_id AND ps.deleted_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('product_supplier %s.', p_id);
  END IF;
END;
$$;

CREATE FUNCTION app.remove_product_supplier(p_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.require_purchases_manage();
BEGIN
  UPDATE public.product_supplier ps SET deleted_at = pg_catalog.clock_timestamp()
   WHERE ps.id = p_id AND ps.economic_group_id = group_id AND ps.deleted_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('product_supplier %s.', p_id);
  END IF;
END;
$$;

CREATE POLICY supplier_select ON supplier FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group())
         AND (SELECT app.has_permission_anywhere('purchases.view')
                  OR app.has_permission_anywhere('purchases.manage')));
CREATE POLICY product_supplier_select ON product_supplier FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group())
         AND (SELECT app.has_permission_anywhere('purchases.view')
                  OR app.has_permission_anywhere('purchases.manage')));
GRANT SELECT ON supplier, product_supplier TO farmaerp_app;

CREATE VIEW v_supplier WITH (security_invoker = true) AS
  SELECT * FROM supplier WHERE deleted_at IS NULL;
CREATE VIEW v_product_supplier WITH (security_invoker = true) AS
  SELECT * FROM product_supplier WHERE deleted_at IS NULL;
GRANT SELECT ON v_supplier, v_product_supplier TO farmaerp_app;

-- Busca por nome, por CNPJ completo ou pelo começo do CNPJ, com quantos códigos ativos cada um tem.
CREATE FUNCTION app.search_suppliers(p_query text, p_limit integer DEFAULT 50)
RETURNS TABLE (id uuid, cnpj text, legal_name text, trade_name text, city text, state text, product_count bigint)
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  WITH input AS (
    SELECT app.search_patterns(p_query) AS patterns, app.clean_document(p_query) AS document,
           pg_catalog.btrim(COALESCE(p_query, '')) AS raw
  )
  SELECT s.id, s.cnpj, s.legal_name, s.trade_name, s.city, s.state::text,
         (SELECT pg_catalog.count(*) FROM public.v_product_supplier ps WHERE ps.supplier_id = s.id)
    FROM public.v_supplier s
   CROSS JOIN input
   WHERE input.raw = ''
      OR s.search_text LIKE ALL (input.patterns)
      OR (pg_catalog.length(input.document) >= 8 AND pg_catalog.starts_with(s.cnpj, input.document))
   ORDER BY s.legal_name, s.id
   LIMIT LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200)
$$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  app.effective_fraction(uuid, uuid, uuid),
  app.create_supplier(jsonb),
  app.update_supplier(uuid, jsonb),
  app.delete_supplier(uuid),
  app.add_product_supplier(uuid, jsonb),
  app.update_product_supplier(uuid, numeric),
  app.remove_product_supplier(uuid),
  app.search_suppliers(text, integer)
TO farmaerp_app;
