-- Up Migration

-- Preço, PMC e status por filial. Preço e PMC são só incluídos: a última linha vale e as demais
-- são o histórico. Toda escrita da API passa pelas funções app.* deste arquivo.

-- O PMC depende de onde a filial fica. Vazio até alguém informar.
ALTER TABLE branch
  ADD COLUMN state char(2) CONSTRAINT branch_state_check CHECK (state IN (
    'AC', 'AL', 'AP', 'AM', 'BA', 'CE', 'DF', 'ES', 'GO', 'MA', 'MT', 'MS', 'MG', 'PA',
    'PB', 'PR', 'PE', 'PI', 'RJ', 'RN', 'RS', 'RO', 'RR', 'SC', 'SP', 'SE', 'TO'
  )),
  ADD COLUMN pmc_region text CONSTRAINT branch_pmc_region_check CHECK (pmc_region IN (
    'free_trade_area', 'manaus_free_zone'
  ));

-- security_invoker precisa ser repetido: CREATE OR REPLACE substitui as opções da view.
CREATE OR REPLACE VIEW v_branch WITH (security_invoker = true) AS
  SELECT * FROM branch WHERE deleted_at IS NULL;

CREATE TABLE product_price (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  product_id uuid NOT NULL REFERENCES product (id),
  -- Vazio: preço padrão da rede. Preenchido: exceção da filial.
  branch_id uuid REFERENCES branch (id),
  -- Vazio só em filial: encerra a exceção, e a filial volta ao preço da rede.
  price numeric(12, 2) CONSTRAINT product_price_price_check CHECK (price > 0),
  reason text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid,
  CONSTRAINT product_price_network_check CHECK (branch_id IS NOT NULL OR price IS NOT NULL)
);
CREATE INDEX product_price_lookup_idx ON product_price (product_id, branch_id, created_at DESC, id DESC);
CREATE INDEX product_price_branch_id_idx ON product_price (branch_id);

CREATE TABLE product_pmc (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  product_id uuid NOT NULL REFERENCES product (id),
  state char(2) NOT NULL CONSTRAINT product_pmc_state_check CHECK (state IN (
    'AC', 'AL', 'AP', 'AM', 'BA', 'CE', 'DF', 'ES', 'GO', 'MA', 'MT', 'MS', 'MG', 'PA',
    'PB', 'PR', 'PE', 'PI', 'RJ', 'RN', 'RS', 'RO', 'RR', 'SC', 'SP', 'SE', 'TO'
  )),
  pmc_region text CONSTRAINT product_pmc_region_check CHECK (pmc_region IN (
    'free_trade_area', 'manaus_free_zone'
  )),
  value numeric(12, 2) NOT NULL CONSTRAINT product_pmc_value_check CHECK (value > 0),
  -- A entrada do XML vai usar 'invoice'.
  source text NOT NULL DEFAULT 'manual' CONSTRAINT product_pmc_source_check CHECK (source IN ('manual', 'invoice')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE INDEX product_pmc_lookup_idx ON product_pmc (product_id, state, created_at DESC, id DESC);

-- PMC da CMED, carregado pela importação do Catálogo.
CREATE TABLE catalog_product_pmc (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  catalog_product_id uuid NOT NULL REFERENCES catalog_product (id),
  state char(2) NOT NULL CONSTRAINT catalog_product_pmc_state_check CHECK (state IN (
    'AC', 'AL', 'AP', 'AM', 'BA', 'CE', 'DF', 'ES', 'GO', 'MA', 'MT', 'MS', 'MG', 'PA',
    'PB', 'PR', 'PE', 'PI', 'RJ', 'RN', 'RS', 'RO', 'RR', 'SC', 'SP', 'SE', 'TO'
  )),
  pmc_region text CONSTRAINT catalog_product_pmc_region_check CHECK (pmc_region IN (
    'free_trade_area', 'manaus_free_zone'
  )),
  value numeric(12, 2) NOT NULL CONSTRAINT catalog_product_pmc_value_check CHECK (value > 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE INDEX catalog_product_pmc_lookup_idx ON catalog_product_pmc (catalog_product_id, state, created_at DESC, id DESC);

CREATE TABLE product_branch_status (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  product_id uuid NOT NULL REFERENCES product (id),
  branch_id uuid NOT NULL REFERENCES branch (id),
  status text NOT NULL DEFAULT 'active' CONSTRAINT product_branch_status_status_check CHECK (
    status IN ('active', 'on_order', 'blocked', 'inactive')
  ),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE UNIQUE INDEX product_branch_status_active_key
  ON product_branch_status (product_id, branch_id) WHERE deleted_at IS NULL;
CREATE INDEX product_branch_status_branch_id_idx ON product_branch_status (branch_id);

-- Quem, quando (colunas padrão) e por quê.
CREATE TABLE product_status_event (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  product_branch_status_id uuid NOT NULL REFERENCES product_branch_status (id),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  branch_id uuid NOT NULL REFERENCES branch (id),
  old_status text NOT NULL CONSTRAINT product_status_event_old_status_check CHECK (
    old_status IN ('active', 'on_order', 'blocked', 'inactive')
  ),
  new_status text NOT NULL CONSTRAINT product_status_event_new_status_check CHECK (
    new_status IN ('active', 'on_order', 'blocked', 'inactive')
  ),
  reason text NOT NULL CONSTRAINT product_status_event_reason_check CHECK (btrim(reason) <> ''),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE INDEX product_status_event_status_idx ON product_status_event (product_branch_status_id, created_at DESC);
CREATE INDEX product_status_event_branch_id_idx ON product_status_event (branch_id);

CALL app.apply_table_standard('public.product_price');
CALL app.apply_table_standard('public.product_pmc');
CALL app.apply_table_standard('public.catalog_product_pmc');
CALL app.apply_table_standard('public.product_branch_status');
CALL app.apply_table_standard('public.product_status_event');

-- Histórico não muda: correção é uma linha nova.
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON product_price
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns('economic_group_id', 'product_id', 'branch_id', 'price', 'reason');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON product_pmc
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns('economic_group_id', 'product_id', 'state', 'pmc_region', 'value', 'source');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON catalog_product_pmc
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns('catalog_product_id', 'state', 'pmc_region', 'value');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON product_branch_status
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns('economic_group_id', 'product_id', 'branch_id');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON product_status_event
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'product_branch_status_id', 'economic_group_id', 'branch_id', 'old_status', 'new_status', 'reason'
  );

-- Linha por filial: nasce ativa, em produto novo e em filial nova.
CREATE FUNCTION app.create_status_for_product() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  INSERT INTO public.product_branch_status (economic_group_id, product_id, branch_id)
  SELECT NEW.economic_group_id, NEW.id, b.id
    FROM public.branch b
    JOIN public.company c ON c.id = b.company_id
   WHERE c.economic_group_id = NEW.economic_group_id AND b.deleted_at IS NULL;
  RETURN NULL;
END;
$$;

CREATE TRIGGER create_branch_status AFTER INSERT ON product
  FOR EACH ROW EXECUTE FUNCTION app.create_status_for_product();

CREATE FUNCTION app.create_status_for_branch() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  INSERT INTO public.product_branch_status (economic_group_id, product_id, branch_id)
  SELECT p.economic_group_id, p.id, NEW.id
    FROM public.product p
    JOIN public.company c ON c.economic_group_id = p.economic_group_id
   WHERE c.id = NEW.company_id AND p.deleted_at IS NULL;
  RETURN NULL;
END;
$$;

CREATE TRIGGER create_product_status AFTER INSERT ON branch
  FOR EACH ROW EXECUTE FUNCTION app.create_status_for_branch();

-- Produtos e filiais que já existem.
INSERT INTO product_branch_status (economic_group_id, product_id, branch_id)
SELECT p.economic_group_id, p.id, b.id
  FROM product p
  JOIN company c ON c.economic_group_id = p.economic_group_id
  JOIN branch b ON b.company_id = c.id AND b.deleted_at IS NULL
 WHERE p.deleted_at IS NULL;

-- Preço em vigor: a exceção da filial, se houver, senão o da rede.
CREATE FUNCTION app.effective_price(p_product_id uuid, p_branch_id uuid) RETURNS numeric
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT COALESCE(
    (SELECT pp.price FROM public.product_price pp
      WHERE pp.product_id = p_product_id AND pp.branch_id = p_branch_id AND pp.deleted_at IS NULL
      ORDER BY pp.created_at DESC, pp.id DESC LIMIT 1),
    (SELECT pp.price FROM public.product_price pp
      WHERE pp.product_id = p_product_id AND pp.branch_id IS NULL AND pp.deleted_at IS NULL
      ORDER BY pp.created_at DESC, pp.id DESC LIMIT 1)
  )
$$;

-- PMC em vigor: o valor mais recente, venha da loja ou do Catálogo. A região especial tem
-- prioridade; sem valor para ela, vale o do estado.
CREATE FUNCTION app.effective_pmc(p_product_id uuid, p_state text, p_region text) RETURNS numeric
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT candidates.value
    FROM (
      SELECT pm.value, pm.pmc_region, pm.created_at, pm.id
        FROM public.product_pmc pm
       WHERE pm.product_id = p_product_id AND pm.state = p_state AND pm.deleted_at IS NULL
      UNION ALL
      SELECT cm.value, cm.pmc_region, cm.created_at, cm.id
        FROM public.catalog_product_pmc cm
        JOIN public.product p ON p.catalog_product_id = cm.catalog_product_id
       WHERE p.id = p_product_id AND cm.state = p_state AND cm.deleted_at IS NULL
    ) AS candidates
   WHERE candidates.pmc_region IS NOT DISTINCT FROM p_region OR candidates.pmc_region IS NULL
   ORDER BY (candidates.pmc_region IS NOT DISTINCT FROM p_region) DESC,
            candidates.created_at DESC, candidates.id DESC
   LIMIT 1
$$;

-- Vender acima do PMC pode gerar sanção: ao salvar o preço, bloqueia.
CREATE FUNCTION app.assert_price_within_pmc(p_product public.product, p_branch public.branch, p_price numeric) RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  limit_value numeric;
BEGIN
  IF NOT p_product.uses_pmc OR p_price IS NULL THEN
    RETURN;
  END IF;
  IF p_branch.state IS NULL THEN
    RAISE EXCEPTION 'O estado da filial não foi informado.'
      USING ERRCODE = 'FA612', DETAIL = pg_catalog.format('branch %s.', p_branch.id);
  END IF;
  limit_value := app.effective_pmc(p_product.id, p_branch.state, p_branch.pmc_region);
  IF limit_value IS NOT NULL AND p_price > limit_value THEN
    RAISE EXCEPTION 'O preço está acima do PMC desta filial.'
      USING ERRCODE = 'FA610',
            DETAIL = pg_catalog.format('product %s, branch %s, preço %s, PMC %s.', p_product.id, p_branch.id, p_price, limit_value);
  END IF;
END;
$$;

CREATE FUNCTION app.lock_product(p_product_id uuid) RETURNS public.product
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.product;
BEGIN
  SELECT * INTO target FROM public.product p
   WHERE p.id = p_product_id AND p.economic_group_id = app.current_user_group() AND p.deleted_at IS NULL
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('product %s.', p_product_id);
  END IF;
  RETURN target;
END;
$$;

-- Filial vazia altera o preço da rede, o que exige a permissão em todas as filiais. Na rede,
-- só confere as filiais que seguem esse preço: quem tem exceção não muda.
-- Preço vazio em filial encerra a exceção.
CREATE FUNCTION app.set_product_price(p_product_id uuid, p_branch_id uuid, p_price numeric, p_reason text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.product := app.lock_product(p_product_id);
  branch_row public.branch;
  new_id uuid;
BEGIN
  IF NOT app.has_permission('products.price', p_branch_id) THEN
    RAISE EXCEPTION 'Você não tem permissão para esta operação.'
      USING ERRCODE = 'FA002', DETAIL = 'set_product_price sem products.price.';
  END IF;

  IF p_branch_id IS NOT NULL THEN
    SELECT b.* INTO branch_row
      FROM public.branch b
      JOIN public.company c ON c.id = b.company_id
     WHERE b.id = p_branch_id AND b.deleted_at IS NULL AND c.economic_group_id = target.economic_group_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Um dos itens informados não foi encontrado.'
        USING ERRCODE = 'FA004', DETAIL = pg_catalog.format('branch %s.', p_branch_id);
    END IF;
    -- Sem exceção, a filial volta ao preço da rede, que também precisa caber no PMC dela.
    PERFORM app.assert_price_within_pmc(
      target, branch_row,
      COALESCE(p_price, (
        SELECT pp.price FROM public.product_price pp
         WHERE pp.product_id = target.id AND pp.branch_id IS NULL AND pp.deleted_at IS NULL
         ORDER BY pp.created_at DESC, pp.id DESC LIMIT 1
      ))
    );
  ELSE
    FOR branch_row IN
      SELECT b.*
        FROM public.branch b
        JOIN public.company c ON c.id = b.company_id
       WHERE c.economic_group_id = target.economic_group_id AND b.deleted_at IS NULL
         AND (
           SELECT pp.price FROM public.product_price pp
            WHERE pp.product_id = target.id AND pp.branch_id = b.id AND pp.deleted_at IS NULL
            ORDER BY pp.created_at DESC, pp.id DESC LIMIT 1
         ) IS NULL
    LOOP
      PERFORM app.assert_price_within_pmc(target, branch_row, p_price);
    END LOOP;
  END IF;

  INSERT INTO public.product_price (economic_group_id, product_id, branch_id, price, reason)
  VALUES (target.economic_group_id, target.id, p_branch_id, p_price, NULLIF(pg_catalog.btrim(p_reason), ''))
  RETURNING id INTO new_id;
  RETURN new_id;
END;
$$;

-- PMC digitado. Um valor menor que o preço atual não bloqueia nada: aparece como alerta na grade.
CREATE FUNCTION app.add_product_pmc(p_product_id uuid, p_state text, p_region text, p_value numeric) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.product := app.lock_product(p_product_id);
  new_id uuid;
BEGIN
  IF NOT app.has_permission('products.price') THEN
    RAISE EXCEPTION 'Você não tem permissão para esta operação.'
      USING ERRCODE = 'FA002', DETAIL = 'add_product_pmc sem products.price.';
  END IF;

  INSERT INTO public.product_pmc (economic_group_id, product_id, state, pmc_region, value)
  VALUES (target.economic_group_id, target.id, p_state, NULLIF(p_region, ''), p_value)
  RETURNING id INTO new_id;
  RETURN new_id;
END;
$$;

-- Muda o status em várias filiais de uma vez: ou todas, ou nenhuma. A ordem fixa das travas
-- evita bloqueio mútuo entre duas ações em massa.
CREATE FUNCTION app.apply_product_status(
  p_product_id uuid, p_branch_ids uuid[], p_status text, p_reason text, p_code text, p_reactivating boolean
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.product := app.lock_product(p_product_id);
  requested uuid;
  current_row public.product_branch_status;
BEGIN
  IF pg_catalog.btrim(COALESCE(p_reason, '')) = '' THEN
    RAISE EXCEPTION 'Informe o motivo desta ação.'
      USING ERRCODE = 'FA302', DETAIL = 'Mudança de status sem motivo.';
  END IF;
  IF COALESCE(pg_catalog.cardinality(p_branch_ids), 0) = 0 THEN
    RAISE EXCEPTION 'Alguns dados informados são inválidos.'
      USING ERRCODE = 'FA005', DETAIL = 'Mudança de status sem filial.';
  END IF;

  FOR requested IN SELECT DISTINCT value FROM pg_catalog.unnest(p_branch_ids) AS value ORDER BY value LOOP
    SELECT * INTO current_row FROM public.product_branch_status s
     WHERE s.product_id = target.id AND s.branch_id = requested AND s.deleted_at IS NULL
     FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Um dos itens informados não foi encontrado.'
        USING ERRCODE = 'FA004', DETAIL = pg_catalog.format('Status do produto %s na filial %s.', target.id, requested);
    END IF;
    IF NOT app.has_permission(p_code, requested) THEN
      RAISE EXCEPTION 'Você não tem permissão para esta operação.'
        USING ERRCODE = 'FA002', DETAIL = pg_catalog.format('%s na filial %s.', p_code, requested);
    END IF;

    IF p_reactivating AND current_row.status <> 'inactive' THEN
      RAISE EXCEPTION 'Só produto inativo pode ser reativado.'
        USING ERRCODE = 'FA616', DETAIL = pg_catalog.format('Filial %s está em %s.', requested, current_row.status);
    END IF;
    IF NOT p_reactivating AND current_row.status = 'inactive' AND p_status <> 'inactive' THEN
      RAISE EXCEPTION 'Este produto está inativo nesta filial.'
        USING ERRCODE = 'FA611', DETAIL = pg_catalog.format('Filial %s.', requested);
    END IF;

    -- Nada muda: não há o que registrar.
    CONTINUE WHEN current_row.status = p_status;

    UPDATE public.product_branch_status s SET status = p_status WHERE s.id = current_row.id;
    INSERT INTO public.product_status_event (
      product_branch_status_id, economic_group_id, branch_id, old_status, new_status, reason
    ) VALUES (
      current_row.id, current_row.economic_group_id, requested, current_row.status, p_status,
      pg_catalog.btrim(p_reason)
    );
  END LOOP;
END;
$$;

CREATE FUNCTION app.set_product_status(p_product_id uuid, p_branch_ids uuid[], p_status text, p_reason text) RETURNS void
LANGUAGE sql SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT app.apply_product_status(p_product_id, p_branch_ids, p_status, p_reason, 'products.status', false)
$$;

-- A senha é conferida pela API, que guarda o Argon2, antes de chamar esta função.
CREATE FUNCTION app.reactivate_product(p_product_id uuid, p_branch_ids uuid[], p_status text, p_reason text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF p_status = 'inactive' THEN
    RAISE EXCEPTION 'O status informado é inválido.'
      USING ERRCODE = 'FA615', DETAIL = 'Reativação para inativo.';
  END IF;
  PERFORM app.apply_product_status(p_product_id, p_branch_ids, p_status, p_reason, 'products.reactivate', true);
END;
$$;

CREATE FUNCTION app.set_branch_location(p_branch_id uuid, p_state text, p_region text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT app.has_permission('structure.manage', p_branch_id) THEN
    RAISE EXCEPTION 'Você não tem permissão para esta operação.'
      USING ERRCODE = 'FA002', DETAIL = 'set_branch_location sem structure.manage.';
  END IF;
  UPDATE public.branch b
     SET state = NULLIF(p_state, ''), pmc_region = NULLIF(p_region, '')
   WHERE b.id = p_branch_id AND b.deleted_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('branch %s.', p_branch_id);
  END IF;
END;
$$;

-- A importação do Catálogo passa a aceitar o PMC. Valor igual ao vigente não gera linha.
CREATE OR REPLACE FUNCTION app.upsert_catalog_product(p_item jsonb) RETURNS uuid
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  manufacturer_name text := NULLIF(pg_catalog.btrim(p_item ->> 'manufacturer'), '');
  manufacturer uuid;
  codes text[] := ARRAY(
    SELECT DISTINCT pg_catalog.btrim(value)
      FROM pg_catalog.jsonb_array_elements_text(COALESCE(p_item -> 'barcodes', '[]')) AS value
  );
  item_id uuid;
  pmc_item jsonb;
  pmc_state text;
  pmc_region_value text;
  pmc_value numeric;
BEGIN
  IF manufacturer_name IS NOT NULL THEN
    SELECT m.id INTO manufacturer FROM public.catalog_manufacturer m
     WHERE m.name = manufacturer_name AND m.deleted_at IS NULL;
    IF NOT FOUND THEN
      INSERT INTO public.catalog_manufacturer (name) VALUES (manufacturer_name)
      RETURNING id INTO manufacturer;
    END IF;
  END IF;

  INSERT INTO public.catalog_product (
    source_key, name, active_ingredient, manufacturer_id, ms_registration, controlled_class, ncm, cest
  ) VALUES (
    p_item ->> 'sourceKey', pg_catalog.btrim(p_item ->> 'name'),
    NULLIF(pg_catalog.btrim(p_item ->> 'activeIngredient'), ''), manufacturer,
    NULLIF(p_item ->> 'msRegistration', ''), NULLIF(p_item ->> 'controlledClass', ''),
    NULLIF(p_item ->> 'ncm', ''), NULLIF(p_item ->> 'cest', '')
  )
  ON CONFLICT (source_key) WHERE deleted_at IS NULL DO UPDATE
    SET name = EXCLUDED.name,
        active_ingredient = EXCLUDED.active_ingredient,
        manufacturer_id = EXCLUDED.manufacturer_id,
        ms_registration = EXCLUDED.ms_registration,
        controlled_class = EXCLUDED.controlled_class,
        ncm = EXCLUDED.ncm,
        cest = EXCLUDED.cest
    -- Item igual não muda de versão, para não descer de novo aos terminais na Etapa 3.
    WHERE (public.catalog_product.name, public.catalog_product.active_ingredient,
           public.catalog_product.manufacturer_id, public.catalog_product.ms_registration,
           public.catalog_product.controlled_class, public.catalog_product.ncm, public.catalog_product.cest)
          IS DISTINCT FROM
          (EXCLUDED.name, EXCLUDED.active_ingredient, EXCLUDED.manufacturer_id, EXCLUDED.ms_registration,
           EXCLUDED.controlled_class, EXCLUDED.ncm, EXCLUDED.cest)
  RETURNING id INTO item_id;

  IF item_id IS NULL THEN
    SELECT cp.id INTO item_id FROM public.catalog_product cp
     WHERE cp.source_key = p_item ->> 'sourceKey' AND cp.deleted_at IS NULL;
  END IF;

  UPDATE public.catalog_product_barcode cb
     SET deleted_at = pg_catalog.clock_timestamp()
   WHERE cb.catalog_product_id = item_id AND cb.deleted_at IS NULL AND cb.code <> ALL (codes);

  INSERT INTO public.catalog_product_barcode (catalog_product_id, code)
  SELECT item_id, requested.code
    FROM pg_catalog.unnest(codes) AS requested(code)
   WHERE NOT EXISTS (
     SELECT 1 FROM public.catalog_product_barcode cb
      WHERE cb.catalog_product_id = item_id AND cb.code = requested.code AND cb.deleted_at IS NULL
   );

  FOR pmc_item IN SELECT value FROM pg_catalog.jsonb_array_elements(COALESCE(p_item -> 'pmc', '[]')) AS value LOOP
    pmc_state := pmc_item ->> 'state';
    pmc_region_value := NULLIF(pmc_item ->> 'region', '');
    pmc_value := (pmc_item ->> 'value')::numeric;
    IF pmc_value IS DISTINCT FROM (
      SELECT cm.value FROM public.catalog_product_pmc cm
       WHERE cm.catalog_product_id = item_id AND cm.state = pmc_state
         AND cm.pmc_region IS NOT DISTINCT FROM pmc_region_value AND cm.deleted_at IS NULL
       ORDER BY cm.created_at DESC, cm.id DESC LIMIT 1
    ) THEN
      INSERT INTO public.catalog_product_pmc (catalog_product_id, state, pmc_region, value)
      VALUES (item_id, pmc_state, pmc_region_value, pmc_value);
    END IF;
  END LOOP;
  RETURN item_id;
END;
$$;

CREATE POLICY product_price_select ON product_price FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group())
         AND (SELECT app.has_permission_anywhere('products.view')
                  OR app.has_permission_anywhere('products.manage'))
         AND (branch_id IS NULL OR branch_id = ANY ((SELECT app.allowed_branch_ids())::uuid[])));
CREATE POLICY product_pmc_select ON product_pmc FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group())
         AND (SELECT app.has_permission_anywhere('products.view')
                  OR app.has_permission_anywhere('products.manage')));
CREATE POLICY catalog_product_pmc_select ON catalog_product_pmc FOR SELECT TO farmaerp_app
  USING ((SELECT app.current_user_group()) IS NOT NULL);
CREATE POLICY product_branch_status_select ON product_branch_status FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group())
         AND (SELECT app.has_permission_anywhere('products.view')
                  OR app.has_permission_anywhere('products.manage'))
         AND branch_id = ANY ((SELECT app.allowed_branch_ids())::uuid[]));
CREATE POLICY product_status_event_select ON product_status_event FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group())
         AND (SELECT app.has_permission_anywhere('products.view')
                  OR app.has_permission_anywhere('products.manage'))
         AND branch_id = ANY ((SELECT app.allowed_branch_ids())::uuid[]));

GRANT SELECT ON product_price, product_pmc, catalog_product_pmc, product_branch_status, product_status_event TO farmaerp_app;

CREATE VIEW v_product_price WITH (security_invoker = true) AS
  SELECT * FROM product_price WHERE deleted_at IS NULL;
CREATE VIEW v_product_pmc WITH (security_invoker = true) AS
  SELECT * FROM product_pmc WHERE deleted_at IS NULL;
CREATE VIEW v_catalog_product_pmc WITH (security_invoker = true) AS
  SELECT * FROM catalog_product_pmc WHERE deleted_at IS NULL;
CREATE VIEW v_product_branch_status WITH (security_invoker = true) AS
  SELECT * FROM product_branch_status WHERE deleted_at IS NULL;
CREATE VIEW v_product_status_event WITH (security_invoker = true) AS
  SELECT * FROM product_status_event WHERE deleted_at IS NULL;
GRANT SELECT ON v_product_price, v_product_pmc, v_catalog_product_pmc, v_product_branch_status, v_product_status_event TO farmaerp_app;

-- Grade do cadastro: uma linha por filial que o usuário enxerga. Só avisa acima do PMC se o
-- produto respeita PMC: é assim que um PMC novo, menor que o preço, aparece sem bloquear.
CREATE FUNCTION app.product_branch_grid(p_product_id uuid)
RETURNS TABLE (
  branch_id uuid, branch_name text, state text, pmc_region text, status text,
  exception_price numeric, effective_price numeric, pmc numeric, above_pmc boolean
)
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT computed.branch_id, computed.name, computed.state, computed.pmc_region, computed.status,
         computed.exception_price, computed.effective_price, computed.pmc,
         COALESCE(computed.uses_pmc AND computed.effective_price > computed.pmc, false)
    FROM (
      SELECT s.branch_id, b.name, b.state::text AS state, b.pmc_region, s.status, p.uses_pmc,
             (SELECT pp.price FROM public.product_price pp
               WHERE pp.product_id = p.id AND pp.branch_id = s.branch_id AND pp.deleted_at IS NULL
               ORDER BY pp.created_at DESC, pp.id DESC LIMIT 1) AS exception_price,
             app.effective_price(p.id, s.branch_id) AS effective_price,
             app.effective_pmc(p.id, b.state, b.pmc_region) AS pmc
        FROM public.product_branch_status s
        JOIN public.product p ON p.id = s.product_id AND p.deleted_at IS NULL
        JOIN public.branch b ON b.id = s.branch_id AND b.deleted_at IS NULL
       WHERE s.product_id = p_product_id AND s.deleted_at IS NULL
    ) AS computed
   ORDER BY computed.name
$$;

-- A busca passa a esconder o produto inativo em todas as filiais que o usuário enxerga.
DROP FUNCTION app.search_products(text, integer);
CREATE FUNCTION app.search_products(p_query text, p_limit integer DEFAULT 50, p_show_inactive boolean DEFAULT false)
RETURNS TABLE (
  id uuid, code bigint, display_name text, catalog_product_id uuid, active_ingredient text,
  manufacturer text, primary_barcode text, online_sale_blocked boolean, all_inactive boolean
)
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  WITH input AS (
    SELECT app.search_patterns(p_query) AS patterns, pg_catalog.btrim(COALESCE(p_query, '')) AS raw
  )
  SELECT p.id, p.code, p.display_name, p.catalog_product_id, cp.active_ingredient,
         COALESCE(m.name, p.own_manufacturer), b.code, p.online_sale_blocked, visibility.all_inactive
    FROM public.product p
   CROSS JOIN input
   CROSS JOIN LATERAL (
     -- bool_and é vazio sem linhas: quem não enxerga nenhuma filial continua vendo o produto.
     SELECT COALESCE(pg_catalog.bool_and(s.status = 'inactive'), false) AS all_inactive
       FROM public.product_branch_status s
      WHERE s.product_id = p.id AND s.deleted_at IS NULL
   ) AS visibility
    LEFT JOIN public.catalog_product cp ON cp.id = p.catalog_product_id
    LEFT JOIN public.catalog_manufacturer m ON m.id = cp.manufacturer_id
    LEFT JOIN public.product_barcode b ON b.product_id = p.id AND b.is_primary AND b.deleted_at IS NULL
   WHERE p.deleted_at IS NULL
     AND (COALESCE(p_show_inactive, false) OR NOT visibility.all_inactive)
     AND (
       input.raw = ''
       OR (p.search_text || ' ' || COALESCE(cp.search_text, '')) LIKE ALL (input.patterns)
       OR p.code::text = input.raw
       OR EXISTS (
         SELECT 1 FROM public.product_barcode exact
          WHERE exact.product_id = p.id AND exact.code = input.raw AND exact.deleted_at IS NULL
       )
     )
   ORDER BY p.display_name, p.id
   LIMIT LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200)
$$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  app.effective_price(uuid, uuid),
  app.effective_pmc(uuid, text, text),
  app.product_branch_grid(uuid),
  app.search_products(text, integer, boolean),
  app.set_product_price(uuid, uuid, numeric, text),
  app.add_product_pmc(uuid, text, text, numeric),
  app.set_product_status(uuid, uuid[], text, text),
  app.reactivate_product(uuid, uuid[], text, text),
  app.set_branch_location(uuid, text, text)
TO farmaerp_app;
