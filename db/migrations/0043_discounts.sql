-- Up Migration

-- Etapa 7, PR 7A-1: descontos automáticos no motor de regras.
-- Dez tipos de desconto, cada regra acumulável ou exclusiva: as acumuláveis se somam; entre as
-- exclusivas vale a de maior desconto, e só ela fica quando passa da soma das acumuláveis. O alvo
-- usa a hierarquia do motor (produto, família, fabricante, subcategoria, categoria, departamento,
-- grupo de precificação, grupo de comissão ou toda a loja). O cálculo é uma função pura
-- (app.discount_calculation), espelhada no PDV e conferida pelos mesmos casos nos dois lados.
-- Também: grupos de clientes (para o desconto por grupo) e a descida das regras para o PDV.

-- Grupos de clientes (idosos, funcionários, clínicas...).
CREATE TABLE customer_group (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  name text NOT NULL CONSTRAINT customer_group_name_check CHECK (btrim(name) <> '' AND length(name) <= 60),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE UNIQUE INDEX customer_group_name_key ON customer_group (economic_group_id, lower(btrim(name))) WHERE deleted_at IS NULL;
CALL app.apply_table_standard('public.customer_group');
CREATE POLICY customer_group_select ON customer_group FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group()));
GRANT SELECT ON customer_group TO farmaerp_app;
CREATE VIEW v_customer_group WITH (security_invoker = true) AS
  SELECT * FROM customer_group WHERE deleted_at IS NULL;
GRANT SELECT ON v_customer_group TO farmaerp_app;

ALTER TABLE customer ADD COLUMN customer_group_id uuid REFERENCES customer_group (id);
CREATE INDEX customer_customer_group_id_idx ON customer (customer_group_id);
CREATE OR REPLACE VIEW v_customer WITH (security_invoker = true) AS
  SELECT * FROM customer WHERE deleted_at IS NULL;

-- Cria ou renomeia um grupo de clientes.
CREATE FUNCTION app.save_customer_group(p_id uuid, p_name text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.current_user_group();
  saved uuid;
BEGIN
  IF NOT app.has_permission('customers.manage') THEN
    RAISE EXCEPTION 'Você não tem permissão para esta operação.'
      USING ERRCODE = 'FA002', DETAIL = 'Grupo de clientes sem customers.manage.';
  END IF;
  IF p_id IS NULL THEN
    INSERT INTO public.customer_group (economic_group_id, name) VALUES (group_id, pg_catalog.btrim(COALESCE(p_name, '')))
    RETURNING id INTO saved;
  ELSE
    UPDATE public.customer_group SET name = pg_catalog.btrim(COALESCE(p_name, ''))
     WHERE id = p_id AND economic_group_id = group_id AND deleted_at IS NULL
    RETURNING id INTO saved;
    IF saved IS NULL THEN
      RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
        USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('customer_group %s.', p_id);
    END IF;
  END IF;
  RETURN saved;
END;
$$;

-- Tira o grupo. Com clientes ou com desconto em vigor, não sai.
CREATE FUNCTION app.remove_customer_group(p_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT app.has_permission('customers.manage') THEN
    RAISE EXCEPTION 'Você não tem permissão para esta operação.'
      USING ERRCODE = 'FA002', DETAIL = 'Grupo de clientes sem customers.manage.';
  END IF;
  IF EXISTS (SELECT 1 FROM public.customer c WHERE c.customer_group_id = p_id AND c.deleted_at IS NULL)
     OR EXISTS (
       SELECT 1 FROM public.discount_rule r
        WHERE r.customer_group_id = p_id AND r.deleted_at IS NULL AND (r.valid_to IS NULL OR r.valid_to > pg_catalog.now())
     ) THEN
    RAISE EXCEPTION 'Este registro ainda tem itens ativos vinculados.'
      USING ERRCODE = 'FA105', DETAIL = pg_catalog.format('customer_group %s em uso.', p_id);
  END IF;
  UPDATE public.customer_group SET deleted_at = pg_catalog.now()
   WHERE id = p_id AND economic_group_id = app.current_user_group() AND deleted_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('customer_group %s.', p_id);
  END IF;
END;
$$;

-- Coloca o cliente num grupo (ou tira, com vazio).
CREATE FUNCTION app.set_customer_group(p_customer_id uuid, p_group_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.current_user_group();
BEGIN
  IF NOT app.has_permission('customers.manage') THEN
    RAISE EXCEPTION 'Você não tem permissão para esta operação.'
      USING ERRCODE = 'FA002', DETAIL = 'Grupo do cliente sem customers.manage.';
  END IF;
  IF p_group_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.customer_group g WHERE g.id = p_group_id AND g.economic_group_id = group_id AND g.deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Um dos itens informados não foi encontrado.'
      USING ERRCODE = 'FA004', DETAIL = pg_catalog.format('customer_group %s.', p_group_id);
  END IF;
  UPDATE public.customer SET customer_group_id = p_group_id
   WHERE id = p_customer_id AND economic_group_id = group_id AND deleted_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('customer %s.', p_customer_id);
  END IF;
END;
$$;

-- Regras de desconto. Editar é encerrar e criar outra (o histórico fica).
CREATE TABLE discount_rule (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  -- Vazio: vale na rede inteira.
  branch_id uuid REFERENCES branch (id),
  name text NOT NULL CONSTRAINT discount_rule_name_check CHECK (btrim(name) <> '' AND length(name) <= 80),
  kind text NOT NULL CONSTRAINT discount_rule_kind_check CHECK (kind IN (
    'product', 'promotion', 'buy_x_pay_y', 'quantity', 'payment_method', 'customer_group', 'agreement',
    'birthday', 'cart_total', 'coupon'
  )),
  level text NOT NULL CONSTRAINT discount_rule_level_check CHECK (level IN (
    'product', 'price_family', 'manufacturer', 'subcategory', 'category', 'department',
    'pricing_group', 'commission_group', 'store_default'
  )),
  product_id uuid REFERENCES product (id),
  product_group_id uuid REFERENCES product_group (id),
  manufacturer_id uuid REFERENCES catalog_manufacturer (id),
  category_id uuid REFERENCES product_category (id),
  percent numeric(7, 4) CONSTRAINT discount_rule_percent_check CHECK (percent > 0 AND percent <= 100),
  buy_quantity integer CONSTRAINT discount_rule_buy_check CHECK (buy_quantity BETWEEN 2 AND 99),
  pay_quantity integer CONSTRAINT discount_rule_pay_check CHECK (pay_quantity >= 1 AND pay_quantity < buy_quantity),
  min_quantity integer CONSTRAINT discount_rule_min_quantity_check CHECK (min_quantity BETWEEN 2 AND 99),
  payment_method text CONSTRAINT discount_rule_payment_check CHECK (payment_method IN (
    'cash', 'credit_card', 'debit_card', 'pix', 'agreement'
  )),
  customer_group_id uuid REFERENCES customer_group (id),
  agreement_id uuid REFERENCES agreement (id),
  min_total numeric(12, 2) CONSTRAINT discount_rule_min_total_check CHECK (min_total > 0),
  coupon text CONSTRAINT discount_rule_coupon_check CHECK (coupon ~ '^[A-Z0-9]{3,20}$'),
  stacking text NOT NULL CONSTRAINT discount_rule_stacking_check CHECK (stacking IN ('cumulative', 'exclusive')),
  valid_from timestamptz NOT NULL DEFAULT now(),
  valid_to timestamptz,
  reason text CONSTRAINT discount_rule_reason_check CHECK (length(reason) <= 500),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid,
  -- Cada tipo usa só os campos dele.
  CONSTRAINT discount_rule_fields_check CHECK (
    (percent IS NOT NULL) = (kind <> 'buy_x_pay_y')
    AND (buy_quantity IS NOT NULL) = (kind = 'buy_x_pay_y')
    AND (pay_quantity IS NOT NULL) = (kind = 'buy_x_pay_y')
    AND (min_quantity IS NOT NULL) = (kind = 'quantity')
    AND (payment_method IS NOT NULL) = (kind = 'payment_method')
    AND (customer_group_id IS NOT NULL) = (kind = 'customer_group')
    AND (agreement_id IS NOT NULL) = (kind = 'agreement')
    AND (min_total IS NOT NULL) = (kind = 'cart_total')
    AND (coupon IS NOT NULL) = (kind = 'coupon')
  ),
  -- Promoção tem começo e fim.
  CONSTRAINT discount_rule_promotion_check CHECK (kind <> 'promotion' OR valid_to IS NOT NULL),
  CONSTRAINT discount_rule_target_check CHECK (
    pg_catalog.num_nonnulls(product_id, product_group_id, manufacturer_id, category_id)
      = CASE WHEN level = 'store_default' THEN 0 ELSE 1 END
    AND CASE level
      WHEN 'product' THEN product_id IS NOT NULL
      WHEN 'price_family' THEN product_group_id IS NOT NULL
      WHEN 'pricing_group' THEN product_group_id IS NOT NULL
      WHEN 'commission_group' THEN product_group_id IS NOT NULL
      WHEN 'manufacturer' THEN manufacturer_id IS NOT NULL
      WHEN 'subcategory' THEN category_id IS NOT NULL
      WHEN 'category' THEN category_id IS NOT NULL
      WHEN 'department' THEN category_id IS NOT NULL
      ELSE true
    END
  ),
  CONSTRAINT discount_rule_validity_check CHECK (valid_to IS NULL OR valid_to > valid_from)
);
CREATE INDEX discount_rule_lookup_idx ON discount_rule (economic_group_id, branch_id) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX discount_rule_coupon_key ON discount_rule (economic_group_id, coupon) WHERE deleted_at IS NULL AND coupon IS NOT NULL;
CREATE INDEX discount_rule_product_id_idx ON discount_rule (product_id);
CREATE INDEX discount_rule_product_group_id_idx ON discount_rule (product_group_id);
CREATE INDEX discount_rule_manufacturer_id_idx ON discount_rule (manufacturer_id);
CREATE INDEX discount_rule_category_id_idx ON discount_rule (category_id);
CREATE INDEX discount_rule_customer_group_id_idx ON discount_rule (customer_group_id);
CREATE INDEX discount_rule_agreement_id_idx ON discount_rule (agreement_id);
CALL app.apply_table_standard('public.discount_rule');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON discount_rule
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'branch_id', 'name', 'kind', 'level', 'product_id', 'product_group_id', 'manufacturer_id',
    'category_id', 'percent', 'buy_quantity', 'pay_quantity', 'min_quantity', 'payment_method', 'customer_group_id',
    'agreement_id', 'min_total', 'coupon', 'stacking', 'valid_from', 'valid_to'
  );
CREATE POLICY discount_rule_select ON discount_rule FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group())
         AND (app.has_permission('rules.view', branch_id) OR app.has_permission('rules.manage', branch_id)));
GRANT SELECT ON discount_rule TO farmaerp_app;
CREATE VIEW v_discount_rule WITH (security_invoker = true) AS
  SELECT * FROM discount_rule WHERE deleted_at IS NULL;
GRANT SELECT ON v_discount_rule TO farmaerp_app;

-- Alvo, grupo de clientes, convênio e filial precisam ser do mesmo grupo econômico.
CREATE FUNCTION app.validate_discount_rule() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  expected_kind text := CASE NEW.level
    WHEN 'price_family' THEN 'price_family'
    WHEN 'pricing_group' THEN 'pricing'
    WHEN 'commission_group' THEN 'commission'
  END;
  expected_level smallint := CASE NEW.level
    WHEN 'department' THEN 1
    WHEN 'category' THEN 2
    WHEN 'subcategory' THEN 3
  END;
BEGIN
  IF NEW.deleted_at IS NOT NULL THEN
    RETURN NEW;
  END IF;
  IF (NEW.product_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.product p
         WHERE p.id = NEW.product_id AND p.economic_group_id = NEW.economic_group_id AND p.deleted_at IS NULL))
     OR (NEW.product_group_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.product_group g
         WHERE g.id = NEW.product_group_id AND g.economic_group_id = NEW.economic_group_id
           AND g.kind = expected_kind AND g.deleted_at IS NULL))
     OR (NEW.category_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.product_category c
         WHERE c.id = NEW.category_id AND c.economic_group_id = NEW.economic_group_id
           AND c.level = expected_level AND c.deleted_at IS NULL))
     OR (NEW.manufacturer_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.catalog_manufacturer m WHERE m.id = NEW.manufacturer_id AND m.deleted_at IS NULL))
  THEN
    RAISE EXCEPTION 'O alvo da regra não é válido.'
      USING ERRCODE = 'FA702', DETAIL = pg_catalog.format('Desconto no nível %s.', NEW.level);
  END IF;
  IF (NEW.customer_group_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.customer_group g
         WHERE g.id = NEW.customer_group_id AND g.economic_group_id = NEW.economic_group_id AND g.deleted_at IS NULL))
     OR (NEW.agreement_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.agreement a
         WHERE a.id = NEW.agreement_id AND a.economic_group_id = NEW.economic_group_id AND a.deleted_at IS NULL))
     OR (NEW.branch_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.branch b JOIN public.company c ON c.id = b.company_id
         WHERE b.id = NEW.branch_id AND b.deleted_at IS NULL AND c.economic_group_id = NEW.economic_group_id))
  THEN
    RAISE EXCEPTION 'Um dos itens informados não foi encontrado.'
      USING ERRCODE = 'FA004', DETAIL = 'Grupo de clientes, convênio ou filial do desconto fora do grupo.';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER validate_parent BEFORE INSERT OR UPDATE ON discount_rule
  FOR EACH ROW EXECUTE FUNCTION app.validate_discount_rule();

-- Regra nova ou encerrada desce para os PDVs (da filial dela, ou de todas).
CREATE FUNCTION app.track_discount_rule_change() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM app.mark_sync_change('discount_rule', NEW.id, NEW.economic_group_id, NEW.branch_id);
  RETURN NULL;
END;
$$;
CREATE TRIGGER track_sync_change AFTER INSERT OR UPDATE ON discount_rule
  FOR EACH ROW EXECUTE FUNCTION app.track_discount_rule_change();

ALTER TABLE sync_change DROP CONSTRAINT sync_change_entity_check;
ALTER TABLE sync_change ADD CONSTRAINT sync_change_entity_check CHECK (entity IN (
  'product', 'catalog_product', 'manufacturer', 'stock', 'user', 'role', 'branch', 'fiscal', 'customer', 'discount_rule'
));

-- Regra no formato do cálculo (o mesmo que desce para o PDV).
CREATE FUNCTION app.discount_rule_json(p_rule public.discount_rule) RETURNS jsonb
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$
  SELECT pg_catalog.jsonb_build_object(
    'id', p_rule.id, 'name', p_rule.name, 'kind', p_rule.kind, 'level', p_rule.level,
    'target_id', COALESCE(p_rule.product_id, p_rule.product_group_id, p_rule.manufacturer_id, p_rule.category_id),
    'branch_id', p_rule.branch_id, 'percent', p_rule.percent, 'buy_quantity', p_rule.buy_quantity,
    'pay_quantity', p_rule.pay_quantity, 'min_quantity', p_rule.min_quantity, 'payment_method', p_rule.payment_method,
    'customer_group_id', p_rule.customer_group_id, 'agreement_id', p_rule.agreement_id, 'min_total', p_rule.min_total,
    'coupon', p_rule.coupon, 'stacking', p_rule.stacking, 'valid_from', p_rule.valid_from, 'valid_to', p_rule.valid_to
  )
$$;

-- O cálculo, sem tabela nenhuma: regras, itens e contexto entram em JSON; sai, por item, o desconto
-- e as regras que valeram. O PDV faz a mesma conta (os casos de teste são os mesmos).
--   regra: o formato de app.discount_rule_json
--   item: {line, quantity, unit_price, product: {id, price_family_id, manufacturer_id, subcategory_id,
--          category_id, department_id, pricing_group_id, commission_group_id}}
--   contexto: {at, today, branch_id, payment_methods: [], customer: {group_id, birth_date} | null,
--              agreement_ids: [], coupon}
-- Valores em centavos, arredondando cada regra (metade para cima). O desconto do item nunca passa do item.
CREATE FUNCTION app.discount_calculation(p_rules jsonb, p_lines jsonb, p_context jsonb) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE
SET search_path = ''
AS $$
DECLARE
  line jsonb;
  rule jsonb;
  product jsonb;
  at timestamptz := (p_context ->> 'at')::timestamptz;
  today date := (p_context ->> 'today')::date;
  methods jsonb := COALESCE(p_context -> 'payment_methods', '[]'::jsonb);
  customer jsonb := p_context -> 'customer';
  coupon text := pg_catalog.upper(pg_catalog.btrim(COALESCE(p_context ->> 'coupon', '')));
  cart_cents bigint := 0;
  gross_cents bigint;
  price_cents bigint;
  units bigint;
  amount bigint;
  target text;
  applies boolean;
  best jsonb;
  best_amount bigint;
  cumulative jsonb;
  cumulative_sum bigint;
  chosen jsonb;
  remaining bigint;
  applied jsonb;
  total bigint;
  result jsonb := '[]'::jsonb;
BEGIN
  FOR line IN SELECT value FROM pg_catalog.jsonb_array_elements(COALESCE(p_lines, '[]'::jsonb)) LOOP
    cart_cents := cart_cents + pg_catalog.round((line ->> 'unit_price')::numeric * (line ->> 'quantity')::numeric * 100)::bigint;
  END LOOP;

  FOR line IN SELECT value FROM pg_catalog.jsonb_array_elements(COALESCE(p_lines, '[]'::jsonb)) LOOP
    product := line -> 'product';
    gross_cents := pg_catalog.round((line ->> 'unit_price')::numeric * (line ->> 'quantity')::numeric * 100)::bigint;
    price_cents := pg_catalog.round((line ->> 'unit_price')::numeric * 100)::bigint;
    units := pg_catalog.floor((line ->> 'quantity')::numeric)::bigint;
    best := NULL;
    best_amount := 0;
    cumulative := '[]'::jsonb;
    cumulative_sum := 0;
    FOR rule IN SELECT value FROM pg_catalog.jsonb_array_elements(COALESCE(p_rules, '[]'::jsonb)) ORDER BY value ->> 'id' LOOP
      IF (rule ->> 'valid_from')::timestamptz > at
         OR (rule ->> 'valid_to' IS NOT NULL AND (rule ->> 'valid_to')::timestamptz <= at)
         OR (rule ->> 'branch_id' IS NOT NULL AND rule ->> 'branch_id' IS DISTINCT FROM p_context ->> 'branch_id') THEN
        CONTINUE;
      END IF;
      target := rule ->> 'target_id';
      applies := CASE rule ->> 'level'
        WHEN 'product' THEN target = product ->> 'id'
        WHEN 'price_family' THEN target = product ->> 'price_family_id'
        WHEN 'manufacturer' THEN target = product ->> 'manufacturer_id'
        WHEN 'subcategory' THEN target = product ->> 'subcategory_id'
        WHEN 'category' THEN target = product ->> 'category_id'
        WHEN 'department' THEN target = product ->> 'department_id'
        WHEN 'pricing_group' THEN target = product ->> 'pricing_group_id'
        WHEN 'commission_group' THEN target = product ->> 'commission_group_id'
        WHEN 'store_default' THEN true
        ELSE false
      END;
      IF applies IS NOT TRUE THEN
        CONTINUE;
      END IF;
      applies := CASE rule ->> 'kind'
        WHEN 'payment_method' THEN pg_catalog.jsonb_array_length(methods) > 0
          AND NOT EXISTS (SELECT 1 FROM pg_catalog.jsonb_array_elements_text(methods) m WHERE m.value <> rule ->> 'payment_method')
        WHEN 'customer_group' THEN customer IS NOT NULL AND customer ->> 'group_id' = rule ->> 'customer_group_id'
        WHEN 'agreement' THEN COALESCE(p_context -> 'agreement_ids', '[]'::jsonb) ? (rule ->> 'agreement_id')
        WHEN 'birthday' THEN customer IS NOT NULL AND customer ->> 'birth_date' IS NOT NULL
          AND pg_catalog.date_part('month', (customer ->> 'birth_date')::date) = pg_catalog.date_part('month', today)
        WHEN 'cart_total' THEN cart_cents >= pg_catalog.round((rule ->> 'min_total')::numeric * 100)
        WHEN 'coupon' THEN coupon <> '' AND coupon = rule ->> 'coupon'
        ELSE true
      END;
      IF applies IS NOT TRUE THEN
        CONTINUE;
      END IF;
      amount := CASE rule ->> 'kind'
        WHEN 'buy_x_pay_y' THEN
          (units / (rule ->> 'buy_quantity')::bigint) * ((rule ->> 'buy_quantity')::bigint - (rule ->> 'pay_quantity')::bigint) * price_cents
        WHEN 'quantity' THEN
          pg_catalog.round(price_cents * GREATEST(0, units - ((rule ->> 'min_quantity')::bigint - 1)) * (rule ->> 'percent')::numeric / 100)::bigint
        ELSE pg_catalog.round(gross_cents * (rule ->> 'percent')::numeric / 100)::bigint
      END;
      amount := LEAST(amount, gross_cents);
      IF amount <= 0 THEN
        CONTINUE;
      END IF;
      IF rule ->> 'stacking' = 'exclusive' THEN
        IF amount > best_amount THEN
          best := rule;
          best_amount := amount;
        END IF;
      ELSE
        cumulative := cumulative || pg_catalog.jsonb_build_array(rule || pg_catalog.jsonb_build_object('amount_cents', amount));
        cumulative_sum := cumulative_sum + amount;
      END IF;
    END LOOP;

    applied := '[]'::jsonb;
    total := 0;
    IF best IS NOT NULL AND best_amount > cumulative_sum THEN
      applied := pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
        'rule_id', best ->> 'id', 'name', best ->> 'name', 'kind', best ->> 'kind', 'amount_cents', best_amount));
      total := best_amount;
    ELSE
      remaining := gross_cents;
      FOR chosen IN SELECT value FROM pg_catalog.jsonb_array_elements(cumulative) LOOP
        amount := LEAST((chosen ->> 'amount_cents')::bigint, remaining);
        EXIT WHEN amount <= 0;
        applied := applied || pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
          'rule_id', chosen ->> 'id', 'name', chosen ->> 'name', 'kind', chosen ->> 'kind', 'amount_cents', amount));
        remaining := remaining - amount;
        total := total + amount;
      END LOOP;
    END IF;
    result := result || pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
      'line', (line ->> 'line')::integer, 'total_cents', total, 'applied', applied));
  END LOOP;
  RETURN result;
END;
$$;

-- Onde o produto está na hierarquia do motor (o que o cálculo compara com o alvo da regra).
CREATE FUNCTION app.product_discount_subject(p_product_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT pg_catalog.jsonb_build_object(
    'id', p.id, 'price_family_id', p.price_family_id, 'manufacturer_id', cp.manufacturer_id,
    'subcategory_id', sub.id, 'category_id', cat.id, 'department_id', dep.id,
    'pricing_group_id', p.pricing_group_id, 'commission_group_id', p.commission_group_id
  )
    FROM public.product p
    LEFT JOIN public.catalog_product cp ON cp.id = p.catalog_product_id
    LEFT JOIN public.product_category sub ON sub.id = p.category_id
    LEFT JOIN public.product_category cat ON cat.id = sub.parent_id
    LEFT JOIN public.product_category dep ON dep.id = cat.parent_id
   WHERE p.id = p_product_id
$$;

-- Os descontos automáticos de uma venda, com as regras e os cadastros da central.
--   itens: [{line, product_id, quantity, unit_price}]
--   contexto: {at, payment_methods: [], customer_id, agreement_ids: [], coupon}
CREATE FUNCTION app.auto_discounts(p_branch_id uuid, p_lines jsonb, p_context jsonb) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  WITH grp AS (
    SELECT c.economic_group_id AS id FROM public.branch b JOIN public.company c ON c.id = b.company_id WHERE b.id = p_branch_id
  ),
  at AS (SELECT COALESCE((p_context ->> 'at')::timestamptz, pg_catalog.now()) AS value)
  SELECT app.discount_calculation(
    COALESCE((
      SELECT pg_catalog.jsonb_agg(app.discount_rule_json(r) ORDER BY r.id)
        FROM public.discount_rule r, grp, at
       WHERE r.economic_group_id = grp.id AND r.deleted_at IS NULL
         AND (r.branch_id IS NULL OR r.branch_id = p_branch_id)
         AND r.valid_from <= at.value AND (r.valid_to IS NULL OR r.valid_to > at.value)
    ), '[]'::jsonb),
    COALESCE((
      SELECT pg_catalog.jsonb_agg(item || pg_catalog.jsonb_build_object('product', app.product_discount_subject((item ->> 'product_id')::uuid)))
        FROM pg_catalog.jsonb_array_elements(COALESCE(p_lines, '[]'::jsonb)) item
    ), '[]'::jsonb),
    pg_catalog.jsonb_build_object(
      'at', (SELECT value FROM at),
      'today', ((SELECT value FROM at) AT TIME ZONE 'America/Sao_Paulo')::date,
      'branch_id', p_branch_id,
      'payment_methods', COALESCE(p_context -> 'payment_methods', '[]'::jsonb),
      'agreement_ids', COALESCE(p_context -> 'agreement_ids', '[]'::jsonb),
      'coupon', p_context ->> 'coupon',
      'customer', (
        SELECT pg_catalog.jsonb_build_object('group_id', c.customer_group_id, 'birth_date', c.birth_date)
          FROM public.customer c, grp
         WHERE c.id = (p_context ->> 'customer_id')::uuid AND c.economic_group_id = grp.id AND c.deleted_at IS NULL
      )
    )
  )
$$;

-- Cria uma regra de desconto. Filial exige a permissão nela; rede, em todas.
CREATE FUNCTION app.create_discount_rule(p_data jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  level_value text := p_data ->> 'level';
  branch uuid := (p_data ->> 'branchId')::uuid;
  new_id uuid;
BEGIN
  PERFORM app.require_rules_manage(branch);
  INSERT INTO public.discount_rule (
    economic_group_id, branch_id, name, kind, level, product_id, product_group_id, manufacturer_id, category_id,
    percent, buy_quantity, pay_quantity, min_quantity, payment_method, customer_group_id, agreement_id, min_total,
    coupon, stacking, valid_from, valid_to, reason
  ) VALUES (
    app.current_user_group(), branch, pg_catalog.btrim(COALESCE(p_data ->> 'name', '')), p_data ->> 'kind', level_value,
    CASE WHEN level_value = 'product' THEN app.find_product_id(p_data ->> 'productLookup') END,
    CASE WHEN level_value IN ('price_family', 'pricing_group', 'commission_group') THEN (p_data ->> 'productGroupId')::uuid END,
    CASE WHEN level_value = 'manufacturer' THEN (p_data ->> 'manufacturerId')::uuid END,
    CASE WHEN level_value IN ('subcategory', 'category', 'department') THEN (p_data ->> 'categoryId')::uuid END,
    (p_data ->> 'percent')::numeric, (p_data ->> 'buyQuantity')::integer, (p_data ->> 'payQuantity')::integer,
    (p_data ->> 'minQuantity')::integer, p_data ->> 'paymentMethod', (p_data ->> 'customerGroupId')::uuid,
    (p_data ->> 'agreementId')::uuid, (p_data ->> 'minTotal')::numeric,
    NULLIF(pg_catalog.upper(pg_catalog.btrim(p_data ->> 'coupon')), ''), p_data ->> 'stacking',
    COALESCE((p_data ->> 'validFrom')::timestamptz, pg_catalog.now()), (p_data ->> 'validTo')::timestamptz,
    NULLIF(pg_catalog.btrim(p_data ->> 'reason'), '')
  ) RETURNING id INTO new_id;
  RETURN new_id;
END;
$$;

-- Encerra a regra: some do PDV na próxima sincronização e fica no histórico.
CREATE FUNCTION app.end_discount_rule(p_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.discount_rule;
BEGIN
  SELECT * INTO target FROM public.discount_rule r
   WHERE r.id = p_id AND r.economic_group_id = app.current_user_group() AND r.deleted_at IS NULL
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('discount_rule %s.', p_id);
  END IF;
  PERFORM app.require_rules_manage(target.branch_id);
  UPDATE public.discount_rule r SET deleted_at = pg_catalog.clock_timestamp() WHERE r.id = target.id;
END;
$$;

-- Regras de desconto para a retaguarda: em vigor (ou futuras) e, se pedido, as encerradas.
CREATE FUNCTION app.list_discount_rules(p_branch_id uuid DEFAULT NULL, p_include_ended boolean DEFAULT false)
RETURNS TABLE (
  id uuid, name text, kind text, level text, target_name text, branch_id uuid, branch_name text, percent numeric,
  buy_quantity integer, pay_quantity integer, min_quantity integer, payment_method text, customer_group_name text,
  agreement_name text, min_total numeric, coupon text, stacking text, valid_from timestamptz, valid_to timestamptz,
  ended_at timestamptz, reason text, status text
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT r.id, r.name, r.kind, r.level,
         COALESCE(
           (SELECT p.display_name FROM public.product p WHERE p.id = r.product_id),
           (SELECT g.name FROM public.product_group g WHERE g.id = r.product_group_id),
           (SELECT m.name FROM public.catalog_manufacturer m WHERE m.id = r.manufacturer_id),
           (SELECT c.name FROM public.product_category c WHERE c.id = r.category_id)
         ),
         r.branch_id, b.name, r.percent, r.buy_quantity, r.pay_quantity, r.min_quantity, r.payment_method,
         cg.name, a.name, r.min_total, r.coupon, r.stacking, r.valid_from, r.valid_to, r.deleted_at, r.reason,
         CASE
           WHEN r.deleted_at IS NOT NULL THEN 'ended'
           WHEN r.valid_to IS NOT NULL AND r.valid_to <= pg_catalog.now() THEN 'expired'
           WHEN r.valid_from > pg_catalog.now() THEN 'scheduled'
           ELSE 'active'
         END
    FROM public.discount_rule r
    LEFT JOIN public.branch b ON b.id = r.branch_id
    LEFT JOIN public.customer_group cg ON cg.id = r.customer_group_id
    LEFT JOIN public.agreement a ON a.id = r.agreement_id
   WHERE r.economic_group_id = app.current_user_group()
     AND (app.has_permission('rules.view', r.branch_id) OR app.has_permission('rules.manage', r.branch_id))
     AND (p_branch_id IS NULL OR r.branch_id IS NULL OR r.branch_id = p_branch_id)
     AND (p_include_ended OR (r.deleted_at IS NULL AND (r.valid_to IS NULL OR r.valid_to > pg_catalog.now())))
   ORDER BY r.deleted_at IS NOT NULL, r.valid_from DESC, r.id DESC
   LIMIT 500
$$;

-- Simulador: os descontos automáticos de uma venda de exemplo, para a retaguarda conferir as regras.
CREATE FUNCTION app.simulate_discounts(p_branch_id uuid, p_lines jsonb, p_context jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT (app.has_permission('rules.view', p_branch_id) OR app.has_permission('rules.manage', p_branch_id))
     OR NOT EXISTS (
       SELECT 1 FROM public.branch b JOIN public.company c ON c.id = b.company_id
        WHERE b.id = p_branch_id AND c.economic_group_id = app.current_user_group()
     ) THEN
    RAISE EXCEPTION 'Você não tem permissão para esta operação.'
      USING ERRCODE = 'FA002', DETAIL = 'Simulação de desconto sem rules.view.';
  END IF;
  RETURN app.auto_discounts(p_branch_id, p_lines, p_context);
END;
$$;

-- Regra de desconto para o PDV: em vigor ou futura, da filial ou da rede. Encerrada ou vencida desce
-- vazia (o PDV apaga).
CREATE FUNCTION app.pdv_discount_rule_data(p_branch_id uuid, p_ids uuid[])
RETURNS TABLE (id uuid, data jsonb)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT ids.id,
         CASE WHEN r.id IS NOT NULL THEN app.discount_rule_json(r) END
    FROM pg_catalog.unnest(p_ids) AS ids(id)
    LEFT JOIN public.discount_rule r
      ON r.id = ids.id AND r.deleted_at IS NULL
     AND (r.branch_id IS NULL OR r.branch_id = p_branch_id)
     AND (r.valid_to IS NULL OR r.valid_to > pg_catalog.now())
$$;

-- Descida: as regras de desconto entram como o 6º tipo.
CREATE OR REPLACE FUNCTION app.pdv_targets(p_branch_id uuid, p_group_id uuid, p_terminal_id uuid, p_since xid8, p_until xid8)
RETURNS TABLE (rank integer, id uuid)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  WITH changed AS (
    SELECT sc.entity, sc.entity_id
      FROM public.sync_change sc
     WHERE p_since IS NOT NULL AND sc.deleted_at IS NULL
       AND sc.xid >= p_since AND sc.xid < p_until
       AND (sc.economic_group_id IS NULL OR sc.economic_group_id = p_group_id)
       AND (sc.branch_id IS NULL OR sc.branch_id = p_branch_id)
  ),
  branch_products AS (
    SELECT s.product_id AS id
      FROM public.product_branch_status s
      JOIN public.product p ON p.id = s.product_id AND p.deleted_at IS NULL
     WHERE s.branch_id = p_branch_id AND s.deleted_at IS NULL AND p.economic_group_id = p_group_id
       AND app.pdv_product_in_scope(s.product_id, p_branch_id)
  ),
  products AS (
    SELECT bp.id FROM branch_products bp
     WHERE p_since IS NULL OR EXISTS (SELECT 1 FROM changed WHERE entity = 'branch')
    UNION
    SELECT c.entity_id FROM changed c WHERE c.entity = 'product'
    UNION
    SELECT p.id FROM changed c
      JOIN public.product p ON p.catalog_product_id = c.entity_id AND p.economic_group_id = p_group_id
     WHERE c.entity = 'catalog_product'
    UNION
    SELECT p.id FROM changed c
      JOIN public.catalog_product cp ON cp.manufacturer_id = c.entity_id
      JOIN public.product p ON p.catalog_product_id = cp.id AND p.economic_group_id = p_group_id
     WHERE c.entity = 'manufacturer'
    -- Bloqueado só desce com saldo: a mudança no estoque pode incluir ou retirar o produto.
    UNION
    SELECT c.entity_id FROM changed c
      JOIN public.product_branch_status s ON s.product_id = c.entity_id AND s.branch_id = p_branch_id
       AND s.deleted_at IS NULL AND s.status = 'blocked'
     WHERE c.entity = 'stock'
  ),
  stock AS (
    SELECT bp.id FROM branch_products bp WHERE p_since IS NULL
    UNION
    SELECT c.entity_id FROM changed c WHERE c.entity IN ('stock', 'product')
  ),
  users AS (
    SELECT u.id FROM public.user_account u
     WHERE p_since IS NULL AND u.economic_group_id = p_group_id AND u.deleted_at IS NULL
       AND EXISTS (SELECT 1 FROM app.user_roles_at(u.id, p_branch_id))
    UNION
    SELECT c.entity_id FROM changed c WHERE c.entity = 'user'
    UNION
    SELECT ur.user_id FROM changed c
      JOIN public.user_role ur ON ur.role_id = c.entity_id
     WHERE c.entity = 'role'
  ),
  customers AS (
    SELECT cc.customer_id AS id FROM public.pdv_customer_cache cc
     WHERE p_since IS NULL AND cc.terminal_id = p_terminal_id AND cc.deleted_at IS NULL
    UNION
    SELECT c.entity_id FROM changed c
      JOIN public.pdv_customer_cache cc
        ON cc.customer_id = c.entity_id AND cc.terminal_id = p_terminal_id AND cc.deleted_at IS NULL
     WHERE c.entity = 'customer'
  ),
  discounts AS (
    SELECT r.id FROM public.discount_rule r
     WHERE p_since IS NULL AND r.economic_group_id = p_group_id AND r.deleted_at IS NULL
       AND (r.branch_id IS NULL OR r.branch_id = p_branch_id)
       AND (r.valid_to IS NULL OR r.valid_to > pg_catalog.now())
    UNION
    SELECT c.entity_id FROM changed c WHERE c.entity = 'discount_rule'
  )
  SELECT 1, p_branch_id
   WHERE p_since IS NULL OR EXISTS (SELECT 1 FROM changed WHERE entity IN ('fiscal', 'branch'))
  UNION ALL SELECT 2, users.id FROM users
  UNION ALL SELECT 3, products.id FROM products
  UNION ALL SELECT 4, stock.id FROM stock
  UNION ALL SELECT 5, customers.id FROM customers
  UNION ALL SELECT 6, discounts.id FROM discounts
$$;


CREATE OR REPLACE FUNCTION app.pdv_pull(p_cursor text, p_until text, p_after text, p_limit integer)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  terminal_row public.terminal;
  group_id uuid;
  since xid8;
  until xid8;
  after_rank integer := 0;
  after_id uuid := '00000000-0000-0000-0000-000000000000';
  page_rank integer[];
  page_id uuid[];
  items jsonb := '[]'::jsonb;
  next_token text;
  total bigint;
  fiscal jsonb;
BEGIN
  SELECT t.* INTO terminal_row FROM public.terminal t
   WHERE t.id = app.current_terminal_id() AND t.deleted_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Não foi possível confirmar a identidade do terminal.'
      USING ERRCODE = 'FA306', DETAIL = 'Descida sem app.terminal_id válido.';
  ELSIF terminal_row.status = 'pending' THEN
    RAISE EXCEPTION 'Este terminal ainda não foi aprovado.' USING ERRCODE = 'FA307';
  ELSIF terminal_row.status = 'blocked' THEN
    RAISE EXCEPTION 'Este terminal está bloqueado.' USING ERRCODE = 'FA304';
  ELSIF terminal_row.status = 'revoked' THEN
    RAISE EXCEPTION 'Este terminal foi revogado.' USING ERRCODE = 'FA305';
  END IF;

  IF (p_cursor IS NOT NULL AND p_cursor !~ '^[0-9]{1,19}$')
     OR (p_until IS NOT NULL AND p_until !~ '^[0-9]{1,19}$')
     OR (p_after IS NOT NULL AND (p_until IS NULL OR p_after !~ '^[1-6]:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'))
     OR p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 5000 THEN
    RAISE EXCEPTION 'Os dados da sincronização são inválidos.'
      USING ERRCODE = 'FA956', DETAIL = 'Cursor, janela, posição ou tamanho do pacote fora do formato.';
  END IF;

  SELECT c.economic_group_id INTO group_id
    FROM public.branch b JOIN public.company c ON c.id = b.company_id
   WHERE b.id = terminal_row.branch_id;

  since := p_cursor::xid8;
  until := COALESCE(p_until::xid8, pg_catalog.pg_snapshot_xmin(pg_catalog.pg_current_snapshot()));
  -- O cursor nunca volta: sem janela nova, nada desce.
  IF since IS NOT NULL AND since > until THEN
    until := since;
  END IF;
  IF p_after IS NOT NULL THEN
    after_rank := pg_catalog.split_part(p_after, ':', 1)::integer;
    after_id := pg_catalog.split_part(p_after, ':', 2)::uuid;
  END IF;

  IF p_after IS NULL THEN
    SELECT pg_catalog.count(*) INTO total
      FROM (SELECT DISTINCT tg.rank, tg.id FROM app.pdv_targets(terminal_row.branch_id, group_id, terminal_row.id, since, until) tg) t;
  END IF;

  SELECT pg_catalog.array_agg(t.rank ORDER BY t.rank, t.id), pg_catalog.array_agg(t.id ORDER BY t.rank, t.id)
    INTO page_rank, page_id
    FROM (
      SELECT DISTINCT tg.rank, tg.id
        FROM app.pdv_targets(terminal_row.branch_id, group_id, terminal_row.id, since, until) tg
       WHERE (tg.rank, tg.id) > (after_rank, after_id)
       ORDER BY tg.rank, tg.id
       LIMIT p_limit + 1
    ) t;

  IF pg_catalog.cardinality(page_id) > p_limit THEN
    next_token := page_rank[p_limit] || ':' || page_id[p_limit];
    page_rank := page_rank[1:p_limit];
    page_id := page_id[1:p_limit];
  END IF;

  IF 1 = ANY (page_rank) THEN
    fiscal := app.pdv_fiscal_data(terminal_row.branch_id, terminal_row.id);
    items := items || pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
      'type', 'fiscal', 'id', terminal_row.branch_id, 'data', fiscal));
  END IF;

  SELECT items || COALESCE(pg_catalog.jsonb_agg(page.item ORDER BY page.rank_order, page.id), '[]'::jsonb) INTO items
    FROM (
      SELECT 2 AS rank_order, d.id, pg_catalog.jsonb_build_object('type', 'user', 'id', d.id, 'data', d.data) AS item
        FROM app.pdv_user_data(terminal_row.branch_id, ARRAY(
          SELECT page_id[i] FROM pg_catalog.generate_subscripts(page_id, 1) i WHERE page_rank[i] = 2)) d
      UNION ALL
      SELECT 3, d.id, pg_catalog.jsonb_build_object('type', 'product', 'id', d.id, 'data', d.data)
        FROM app.pdv_product_data(terminal_row.branch_id, ARRAY(
          SELECT page_id[i] FROM pg_catalog.generate_subscripts(page_id, 1) i WHERE page_rank[i] = 3)) d
      UNION ALL
      SELECT 4, d.id, pg_catalog.jsonb_build_object('type', 'stock', 'id', d.id, 'data', d.data)
        FROM app.pdv_stock_data(terminal_row.branch_id, ARRAY(
          SELECT page_id[i] FROM pg_catalog.generate_subscripts(page_id, 1) i WHERE page_rank[i] = 4)) d
      UNION ALL
      SELECT 5, d.id, pg_catalog.jsonb_build_object('type', 'customer', 'id', d.id, 'data', d.data)
        FROM app.pdv_customer_data(terminal_row.id, ARRAY(
          SELECT page_id[i] FROM pg_catalog.generate_subscripts(page_id, 1) i WHERE page_rank[i] = 5)) d
      UNION ALL
      SELECT 6, d.id, pg_catalog.jsonb_build_object('type', 'discount_rule', 'id', d.id, 'data', d.data)
        FROM app.pdv_discount_rule_data(terminal_row.branch_id, ARRAY(
          SELECT page_id[i] FROM pg_catalog.generate_subscripts(page_id, 1) i WHERE page_rank[i] = 6)) d
    ) page;

  IF next_token IS NULL THEN
    PERFORM app.record_terminal_sync('pull', until, since IS NULL);
  END IF;

  RETURN pg_catalog.jsonb_build_object(
    'format', app.pdv_sync_format(),
    'until', until::text,
    'total', total,
    'items', items,
    'next', next_token
  );
END;
$$;


-- Produto para o PDV, agora com a hierarquia do motor.
CREATE OR REPLACE FUNCTION app.pdv_product_data(p_branch_id uuid, p_ids uuid[])
RETURNS TABLE (id uuid, data jsonb)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT ids.id,
         CASE WHEN app.pdv_product_in_scope(ids.id, p_branch_id) THEN pg_catalog.jsonb_build_object(
           'code', p.code,
           'name', p.display_name,
           'manufacturer', COALESCE(m.name, p.own_manufacturer),
           'active_ingredient', cp.active_ingredient,
           'controlled_class', cp.controlled_class,
           'ms_registration', cp.ms_registration,
           'ncm', cp.ncm,
           'cest', cp.cest,
           'status', s.status,
           'price', app.effective_price(p.id, p_branch_id),
           'fraction_quantity', p.fraction_quantity,
           'batch_required', app.batch_required(p.id, p_branch_id),
           -- Hierarquia do motor de regras, para o PDV aplicar os descontos automáticos.
           'discount_subject', app.product_discount_subject(p.id),
           -- Desconto máximo em vigor (motor de regras) e até quando vale; vazio é sem regra.
           'max_discount', (SELECT r.value FROM app.resolve_product_rule('max_discount', p.id, p_branch_id) r LIMIT 1),
           'max_discount_until', (SELECT r.valid_to FROM app.resolve_product_rule('max_discount', p.id, p_branch_id) r LIMIT 1),
           'barcodes', COALESCE((
             SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
                      'id', pb.id, 'code', pb.code, 'is_primary', pb.is_primary,
                      'fraction_quantity', pb.fraction_quantity) ORDER BY pb.code)
               FROM public.product_barcode pb
              WHERE pb.product_id = p.id AND pb.deleted_at IS NULL AND pb.scan_enabled
           ), '[]'::jsonb),
           'taxes', COALESCE((
             SELECT pg_catalog.jsonb_agg(
                      pg_catalog.to_jsonb(t) - ARRAY[
                        'catalog_product_id', 'tax_regime', 'state', 'created_at', 'updated_at', 'deleted_at',
                        'version', 'updated_by', 'trace_id'
                      ] ORDER BY t.valid_from)
               FROM public.catalog_product_tax t
              WHERE t.catalog_product_id = p.catalog_product_id AND t.tax_regime = c.tax_regime
                AND t.state = b.state AND t.deleted_at IS NULL
                AND t.valid_from >= COALESCE((
                  SELECT pg_catalog.max(cur.valid_from) FROM public.catalog_product_tax cur
                   WHERE cur.catalog_product_id = p.catalog_product_id AND cur.tax_regime = c.tax_regime
                     AND cur.state = b.state AND cur.deleted_at IS NULL AND cur.valid_from <= app.local_today()
                ), '-infinity'::date)
           ), '[]'::jsonb)
         ) END
    FROM pg_catalog.unnest(p_ids) AS ids(id)
    LEFT JOIN public.product p ON p.id = ids.id
    LEFT JOIN public.branch b ON b.id = p_branch_id
    LEFT JOIN public.company c ON c.id = b.company_id
    LEFT JOIN public.product_branch_status s ON s.product_id = p.id AND s.branch_id = p_branch_id AND s.deleted_at IS NULL
    LEFT JOIN public.catalog_product cp ON cp.id = p.catalog_product_id
    LEFT JOIN public.catalog_manufacturer m ON m.id = cp.manufacturer_id
$$;


-- Cliente para o PDV, agora com o grupo.
CREATE OR REPLACE FUNCTION app.pdv_customer_data(p_terminal_id uuid, p_ids uuid[])
RETURNS TABLE (id uuid, data jsonb)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT ids.id,
         CASE WHEN c.id IS NOT NULL THEN pg_catalog.jsonb_build_object(
           'code', c.code, 'person_type', c.person_type, 'name', c.name, 'trade_name', c.trade_name,
           'document', c.document, 'birth_date', c.birth_date, 'phone', c.phone, 'email', c.email,
           'postal_code', c.postal_code, 'street', c.street, 'street_number', c.street_number,
           'complement', c.complement, 'district', c.district, 'city', c.city, 'city_code', c.city_code,
           'state', c.state,
           'customer_group_id', c.customer_group_id,
           'agreements', COALESCE((
             SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
                      'agreement_id', a.id, 'name', a.name, 'registration', ca.registration,
                      'credit_limit', ca.credit_limit) ORDER BY a.name)
               FROM public.customer_agreement ca
               JOIN public.agreement a ON a.id = ca.agreement_id AND a.deleted_at IS NULL
              WHERE ca.customer_id = c.id AND ca.deleted_at IS NULL
           ), '[]'::jsonb)
         ) END
    FROM pg_catalog.unnest(p_ids) AS ids(id)
    LEFT JOIN public.pdv_customer_cache cc
      ON cc.customer_id = ids.id AND cc.terminal_id = p_terminal_id AND cc.deleted_at IS NULL
    LEFT JOIN public.customer c ON c.id = cc.customer_id AND c.deleted_at IS NULL
     AND c.economic_group_id = cc.economic_group_id
$$;


REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  app.save_customer_group(uuid, text),
  app.remove_customer_group(uuid),
  app.set_customer_group(uuid, uuid),
  app.create_discount_rule(jsonb),
  app.end_discount_rule(uuid),
  app.list_discount_rules(uuid, boolean),
  app.simulate_discounts(uuid, jsonb, jsonb)
TO farmaerp_app;
