-- Up Migration

-- Motor de regras de produto: responde qual regra vale para um produto em uma filial, e por quê.
-- Quem usa a resposta (entrada do XML, descontos, comissão, cashback) chega com cada módulo.

-- Catálogo de tipos: só muda por migration, como as permissões.
CREATE TABLE rule_type (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  code text NOT NULL CONSTRAINT rule_type_code_check CHECK (code ~ '^[a-z_]+$'),
  name text NOT NULL CONSTRAINT rule_type_name_check CHECK (btrim(name) <> ''),
  unit text NOT NULL CONSTRAINT rule_type_unit_check CHECK (unit IN ('percent')),
  min_value numeric(12, 4) NOT NULL,
  max_value numeric(12, 4) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid,
  CONSTRAINT rule_type_range_check CHECK (min_value <= max_value)
);
CREATE UNIQUE INDEX rule_type_code_active_key ON rule_type (code) WHERE deleted_at IS NULL;

CREATE TABLE product_rule (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  rule_type_id uuid NOT NULL REFERENCES rule_type (id),
  level text NOT NULL CONSTRAINT product_rule_level_check CHECK (level IN (
    'product', 'price_family', 'manufacturer', 'subcategory', 'category', 'department',
    'pricing_group', 'commission_group', 'store_default'
  )),
  -- Só a coluna do nível fica preenchida. O padrão da loja não tem alvo.
  product_id uuid REFERENCES product (id),
  product_group_id uuid REFERENCES product_group (id),
  manufacturer_id uuid REFERENCES catalog_manufacturer (id),
  category_id uuid REFERENCES product_category (id),
  -- Vazio: vale na rede inteira.
  branch_id uuid REFERENCES branch (id),
  value numeric(12, 4) NOT NULL,
  -- Só desempata regras no mesmo nível: o maior número vence.
  priority integer CONSTRAINT product_rule_priority_check CHECK (priority BETWEEN 0 AND 9999),
  valid_from timestamptz NOT NULL DEFAULT now(),
  valid_to timestamptz,
  reason text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid,
  CONSTRAINT product_rule_target_check CHECK (
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
  CONSTRAINT product_rule_validity_check CHECK (valid_to IS NULL OR valid_to > valid_from)
);
CREATE INDEX product_rule_lookup_idx ON product_rule (economic_group_id, rule_type_id, level);
CREATE INDEX product_rule_rule_type_id_idx ON product_rule (rule_type_id);
CREATE INDEX product_rule_product_id_idx ON product_rule (product_id);
CREATE INDEX product_rule_product_group_id_idx ON product_rule (product_group_id);
CREATE INDEX product_rule_manufacturer_id_idx ON product_rule (manufacturer_id);
CREATE INDEX product_rule_category_id_idx ON product_rule (category_id);
CREATE INDEX product_rule_branch_id_idx ON product_rule (branch_id);

CALL app.apply_table_standard('public.rule_type');
CALL app.apply_table_standard('public.product_rule');

-- Editar encerra a regra e cria outra, e assim o histórico mostra o valor anterior.
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON product_rule
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'rule_type_id', 'level', 'product_id', 'product_group_id', 'manufacturer_id',
    'category_id', 'branch_id', 'value', 'priority', 'valid_from', 'valid_to', 'reason'
  );

INSERT INTO rule_type (code, name, unit, min_value, max_value) VALUES
  ('cost_tolerance', 'Tolerância de custo', 'percent', 0, 1000),
  ('commission', 'Comissão', 'percent', 0, 100),
  ('cashback', 'Cashback', 'percent', 0, 100),
  ('max_discount', 'Desconto máximo', 'percent', 0, 100);

-- Regras do cadastro, valendo para qualquer caminho de escrita.
CREATE FUNCTION app.validate_product_rule() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  rule_kind public.rule_type;
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

  SELECT * INTO rule_kind FROM public.rule_type t WHERE t.id = NEW.rule_type_id AND t.deleted_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Um dos itens informados não foi encontrado.'
      USING ERRCODE = 'FA004', DETAIL = pg_catalog.format('rule_type %s.', NEW.rule_type_id);
  END IF;
  IF NEW.value < rule_kind.min_value OR NEW.value > rule_kind.max_value THEN
    RAISE EXCEPTION 'O valor da regra está fora da faixa permitida.'
      USING ERRCODE = 'FA701',
            DETAIL = pg_catalog.format('%s: %s fora de %s a %s.', rule_kind.code, NEW.value, rule_kind.min_value, rule_kind.max_value);
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
        SELECT 1 FROM public.catalog_manufacturer m
         WHERE m.id = NEW.manufacturer_id AND m.deleted_at IS NULL))
  THEN
    RAISE EXCEPTION 'O alvo da regra não é válido.'
      USING ERRCODE = 'FA702', DETAIL = pg_catalog.format('Nível %s.', NEW.level);
  END IF;

  IF NEW.branch_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.branch b
      JOIN public.company c ON c.id = b.company_id
     WHERE b.id = NEW.branch_id AND b.deleted_at IS NULL AND c.economic_group_id = NEW.economic_group_id
  ) THEN
    RAISE EXCEPTION 'Um dos itens informados não foi encontrado.'
      USING ERRCODE = 'FA004', DETAIL = pg_catalog.format('branch %s.', NEW.branch_id);
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER validate_parent BEFORE INSERT OR UPDATE ON product_rule
  FOR EACH ROW EXECUTE FUNCTION app.validate_product_rule();

-- Alvo com regra em vigor ou futura não sai. Regra vencida não segura nada.
CREATE FUNCTION app.protect_rule_target() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.product_rule r
     WHERE r.deleted_at IS NULL
       AND (r.valid_to IS NULL OR r.valid_to > pg_catalog.now())
       AND NEW.id = CASE TG_TABLE_NAME WHEN 'product_group' THEN r.product_group_id ELSE r.category_id END
  ) THEN
    RAISE EXCEPTION 'Este registro ainda tem itens ativos vinculados.'
      USING ERRCODE = 'FA105', DETAIL = pg_catalog.format('%s %s tem regra ativa.', TG_TABLE_NAME, NEW.id);
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER protect_rules BEFORE UPDATE ON product_group
  FOR EACH ROW EXECUTE FUNCTION app.protect_rule_target();
CREATE TRIGGER protect_rules BEFORE UPDATE ON product_category
  FOR EACH ROW EXECUTE FUNCTION app.protect_rule_target();

-- Ordem do docs/base.md, do mais específico ao mais geral.
CREATE FUNCTION app.rule_level_rank(p_level text) RETURNS integer
LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path = ''
AS $$
  SELECT pg_catalog.array_position(
    ARRAY['product', 'price_family', 'manufacturer', 'subcategory', 'category', 'department',
          'pricing_group', 'commission_group', 'store_default'],
    p_level
  )
$$;

-- Nome do alvo, para a explicação. Roda como quem chama: o que a pessoa não vê fica vazio.
CREATE FUNCTION app.rule_target_name(p_rule public.product_rule) RETURNS text
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT COALESCE(
    (SELECT p.display_name FROM public.product p WHERE p.id = p_rule.product_id),
    (SELECT g.name FROM public.product_group g WHERE g.id = p_rule.product_group_id),
    (SELECT m.name FROM public.catalog_manufacturer m WHERE m.id = p_rule.manufacturer_id),
    (SELECT c.name FROM public.product_category c WHERE c.id = p_rule.category_id)
  )
$$;

-- O coração do motor. Ordem de decisão: nível; no mesmo nível, a filial vence a rede; depois a
-- prioridade manual; por fim a mais recente. Sem regra, não devolve linha: cada módulo decide.
-- Roda como quem chama, então a RLS vale. As funções dos módulos, que rodam como dono, enxergam tudo.
CREATE FUNCTION app.resolve_product_rule(
  p_type text, p_product_id uuid, p_branch_id uuid, p_at timestamptz DEFAULT NULL
) RETURNS TABLE (
  rule_id uuid, value numeric, unit text, level text, target_name text,
  branch_id uuid, priority integer, valid_to timestamptz
)
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  WITH subject AS (
    SELECT p.id, p.economic_group_id, p.price_family_id, p.pricing_group_id, p.commission_group_id,
           cp.manufacturer_id,
           sub.id AS subcategory_id, cat.id AS category_id, dep.id AS department_id
      FROM public.product p
      LEFT JOIN public.catalog_product cp ON cp.id = p.catalog_product_id
      LEFT JOIN public.product_category sub ON sub.id = p.category_id
      LEFT JOIN public.product_category cat ON cat.id = sub.parent_id
      LEFT JOIN public.product_category dep ON dep.id = cat.parent_id
     WHERE p.id = p_product_id AND p.deleted_at IS NULL
  )
  SELECT r.id, r.value, t.unit, r.level, app.rule_target_name(r), r.branch_id, r.priority, r.valid_to
    FROM subject s
    JOIN public.product_rule r ON r.economic_group_id = s.economic_group_id AND r.deleted_at IS NULL
    JOIN public.rule_type t ON t.id = r.rule_type_id AND t.deleted_at IS NULL
   WHERE t.code = p_type
     AND (r.branch_id IS NULL OR r.branch_id = p_branch_id)
     AND r.valid_from <= COALESCE(p_at, pg_catalog.now())
     AND (r.valid_to IS NULL OR r.valid_to > COALESCE(p_at, pg_catalog.now()))
     AND CASE r.level
       WHEN 'product' THEN r.product_id = s.id
       WHEN 'price_family' THEN r.product_group_id = s.price_family_id
       -- Produto sem Catálogo tem o fabricante vazio, então este nível não se aplica a ele.
       WHEN 'manufacturer' THEN r.manufacturer_id = s.manufacturer_id
       WHEN 'subcategory' THEN r.category_id = s.subcategory_id
       WHEN 'category' THEN r.category_id = s.category_id
       WHEN 'department' THEN r.category_id = s.department_id
       WHEN 'pricing_group' THEN r.product_group_id = s.pricing_group_id
       WHEN 'commission_group' THEN r.product_group_id = s.commission_group_id
       WHEN 'store_default' THEN true
     END
   ORDER BY app.rule_level_rank(r.level),
            (r.branch_id IS NOT NULL) DESC,
            r.priority DESC NULLS LAST,
            r.created_at DESC,
            r.id DESC
   LIMIT 1
$$;

-- Simulador: uma linha por tipo, inclusive os que não têm regra.
CREATE FUNCTION app.simulate_product_rules(p_product_id uuid, p_branch_id uuid, p_at timestamptz DEFAULT NULL)
RETURNS TABLE (
  type_code text, type_name text, unit text, rule_id uuid, value numeric, level text,
  target_name text, branch_id uuid, priority integer, valid_to timestamptz
)
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT t.code, t.name, t.unit, resolved.rule_id, resolved.value, resolved.level,
         resolved.target_name, resolved.branch_id, resolved.priority, resolved.valid_to
    FROM public.rule_type t
    LEFT JOIN LATERAL app.resolve_product_rule(t.code, p_product_id, p_branch_id, p_at) AS resolved ON true
   WHERE t.deleted_at IS NULL
   ORDER BY t.name
$$;

-- Localiza pelo código humano ou por qualquer código de barras, sem expor o UUID na tela.
CREATE FUNCTION app.find_product_id(p_lookup text) RETURNS uuid
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT p.id
    FROM public.product p
   WHERE p.deleted_at IS NULL
     AND p.economic_group_id = app.current_user_group()
     AND (
       p.code::text = pg_catalog.btrim(p_lookup)
       OR EXISTS (
         SELECT 1 FROM public.product_barcode b
          WHERE b.product_id = p.id AND b.code = pg_catalog.btrim(p_lookup) AND b.deleted_at IS NULL
       )
     )
   ORDER BY p.code
   LIMIT 1
$$;

-- Lista com a situação de cada regra. Roda como quem chama.
CREATE FUNCTION app.list_product_rules(p_include_ended boolean DEFAULT false)
RETURNS TABLE (
  id uuid, type_code text, type_name text, unit text, level text, target_name text, branch_id uuid,
  branch_name text, value numeric, priority integer, valid_from timestamptz, valid_to timestamptz,
  reason text, state text, author text, updated_at timestamptz
)
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT r.id, t.code, t.name, t.unit, r.level, app.rule_target_name(r), r.branch_id, b.name,
         r.value, r.priority, r.valid_from, r.valid_to, r.reason,
         CASE
           WHEN r.deleted_at IS NOT NULL THEN 'ended'
           WHEN r.valid_to IS NOT NULL AND r.valid_to <= pg_catalog.now() THEN 'expired'
           WHEN r.valid_from > pg_catalog.now() THEN 'scheduled'
           ELSE 'active'
         END,
         u.name, r.updated_at
    FROM public.product_rule r
    JOIN public.rule_type t ON t.id = r.rule_type_id
    LEFT JOIN public.branch b ON b.id = r.branch_id
    LEFT JOIN public.user_account u ON u.id = r.updated_by
   WHERE COALESCE(p_include_ended, false) OR r.deleted_at IS NULL
   ORDER BY r.deleted_at IS NOT NULL, t.name, app.rule_level_rank(r.level), r.updated_at DESC
   LIMIT 500
$$;

-- Regra de uma filial exige a permissão nela; regra da rede, em todas.
CREATE FUNCTION app.require_rules_manage(p_branch_id uuid) RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT app.has_permission('rules.manage', p_branch_id) THEN
    RAISE EXCEPTION 'Você não tem permissão para esta operação.'
      USING ERRCODE = 'FA002', DETAIL = 'Alteração de regra sem rules.manage.';
  END IF;
END;
$$;

CREATE FUNCTION app.create_product_rule(p_data jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  level_value text := p_data ->> 'level';
  branch uuid := (p_data ->> 'branchId')::uuid;
  type_id uuid;
  new_id uuid;
BEGIN
  PERFORM app.require_rules_manage(branch);

  SELECT t.id INTO type_id FROM public.rule_type t
   WHERE t.code = p_data ->> 'typeCode' AND t.deleted_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Um dos itens informados não foi encontrado.'
      USING ERRCODE = 'FA004', DETAIL = 'Tipo de regra desconhecido.';
  END IF;

  -- Só o alvo do nível escolhido é usado: um campo sobrando na tela não muda a regra.
  INSERT INTO public.product_rule (
    economic_group_id, rule_type_id, level, product_id, product_group_id, manufacturer_id, category_id,
    branch_id, value, priority, valid_from, valid_to, reason
  ) VALUES (
    app.current_user_group(), type_id, level_value,
    CASE WHEN level_value = 'product' THEN app.find_product_id(p_data ->> 'productLookup') END,
    CASE WHEN level_value IN ('price_family', 'pricing_group', 'commission_group') THEN (p_data ->> 'productGroupId')::uuid END,
    CASE WHEN level_value = 'manufacturer' THEN (p_data ->> 'manufacturerId')::uuid END,
    CASE WHEN level_value IN ('subcategory', 'category', 'department') THEN (p_data ->> 'categoryId')::uuid END,
    branch, (p_data ->> 'value')::numeric, (p_data ->> 'priority')::integer,
    COALESCE((p_data ->> 'validFrom')::timestamptz, pg_catalog.now()),
    (p_data ->> 'validTo')::timestamptz,
    NULLIF(pg_catalog.btrim(p_data ->> 'reason'), '')
  ) RETURNING id INTO new_id;
  RETURN new_id;
END;
$$;

CREATE FUNCTION app.lock_product_rule(p_id uuid) RETURNS public.product_rule
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.product_rule;
BEGIN
  SELECT * INTO target FROM public.product_rule r
   WHERE r.id = p_id AND r.economic_group_id = app.current_user_group() AND r.deleted_at IS NULL
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('product_rule %s.', p_id);
  END IF;
  PERFORM app.require_rules_manage(target.branch_id);
  RETURN target;
END;
$$;

-- Tipo, nível, alvo e filial não mudam: para isso, encerre e crie outra.
CREATE FUNCTION app.replace_product_rule(p_id uuid, p_data jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  old_rule public.product_rule := app.lock_product_rule(p_id);
  new_id uuid;
BEGIN
  UPDATE public.product_rule r SET deleted_at = pg_catalog.clock_timestamp() WHERE r.id = old_rule.id;

  INSERT INTO public.product_rule (
    economic_group_id, rule_type_id, level, product_id, product_group_id, manufacturer_id, category_id,
    branch_id, value, priority, valid_from, valid_to, reason
  ) VALUES (
    old_rule.economic_group_id, old_rule.rule_type_id, old_rule.level, old_rule.product_id,
    old_rule.product_group_id, old_rule.manufacturer_id, old_rule.category_id, old_rule.branch_id,
    (p_data ->> 'value')::numeric, (p_data ->> 'priority')::integer,
    COALESCE((p_data ->> 'validFrom')::timestamptz, old_rule.valid_from),
    (p_data ->> 'validTo')::timestamptz,
    NULLIF(pg_catalog.btrim(p_data ->> 'reason'), '')
  ) RETURNING id INTO new_id;
  RETURN new_id;
END;
$$;

CREATE FUNCTION app.end_product_rule(p_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.product_rule := app.lock_product_rule(p_id);
BEGIN
  UPDATE public.product_rule r SET deleted_at = pg_catalog.clock_timestamp() WHERE r.id = target.id;
END;
$$;

INSERT INTO permission (code, module, name) VALUES
  ('rules.view', 'Regras', 'Ver regras e usar o simulador'),
  ('rules.manage', 'Regras', 'Criar, editar e encerrar regras');

CREATE POLICY rule_type_select ON rule_type FOR SELECT TO farmaerp_app
  USING ((SELECT app.current_user_group()) IS NOT NULL);
CREATE POLICY product_rule_select ON product_rule FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group())
         AND (SELECT app.has_permission_anywhere('rules.view')
                  OR app.has_permission_anywhere('rules.manage'))
         AND (branch_id IS NULL OR branch_id = ANY ((SELECT app.allowed_branch_ids())::uuid[])));

GRANT SELECT ON rule_type, product_rule TO farmaerp_app;

CREATE VIEW v_rule_type WITH (security_invoker = true) AS
  SELECT * FROM rule_type WHERE deleted_at IS NULL;
CREATE VIEW v_product_rule WITH (security_invoker = true) AS
  SELECT * FROM product_rule WHERE deleted_at IS NULL;
GRANT SELECT ON v_rule_type, v_product_rule TO farmaerp_app;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  app.rule_level_rank(text),
  app.rule_target_name(public.product_rule),
  app.resolve_product_rule(text, uuid, uuid, timestamptz),
  app.simulate_product_rules(uuid, uuid, timestamptz),
  app.find_product_id(text),
  app.list_product_rules(boolean),
  app.create_product_rule(jsonb),
  app.replace_product_rule(uuid, jsonb),
  app.end_product_rule(uuid)
TO farmaerp_app;
