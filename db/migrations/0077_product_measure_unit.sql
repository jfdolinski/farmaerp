-- Up Migration

-- Unidade de medida do produto (unidade, caixa, litro, quilo...). A lista é fixa e fica aqui, numa
-- função só: o cadastro confere por ela e a retaguarda mostra a mesma lista. O PDV recebe a unidade
-- com o produto e usa na NFC-e. Produto que já existe fica com UN, que é o que a NFC-e já levava.

-- Unidades aceitas: sigla, nome e se a quantidade pode ter casas decimais.
CREATE FUNCTION app.measure_units()
RETURNS TABLE (code text, name text, fractional boolean)
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$
  VALUES
    ('UN', 'Unidade', false),
    ('CX', 'Caixa', false),
    ('FR', 'Frasco', false),
    ('AMP', 'Ampola', false),
    ('TB', 'Tubo', false),
    ('BIS', 'Bisnaga', false),
    ('PCT', 'Pacote', false),
    ('KIT', 'Kit', false),
    ('PAR', 'Par', false),
    ('DZ', 'Dúzia', false),
    ('L', 'Litro', true),
    ('ML', 'Mililitro', true),
    ('KG', 'Quilograma', true),
    ('G', 'Grama', true),
    ('M', 'Metro', true),
    ('CM', 'Centímetro', true)
$$;

CREATE FUNCTION app.is_measure_unit(p_code text) RETURNS boolean
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$ SELECT EXISTS (SELECT 1 FROM app.measure_units() u WHERE u.code = p_code) $$;

ALTER TABLE product
  ADD COLUMN unit text NOT NULL DEFAULT 'UN' CONSTRAINT product_unit_check CHECK (app.is_measure_unit(unit));

-- A view com SELECT * congela as colunas: recria para mostrar a nova.
CREATE OR REPLACE VIEW v_product WITH (security_invoker = true) AS
  SELECT * FROM product WHERE deleted_at IS NULL;

-- Unidade informada: precisa ser uma da lista. Vazia: UN (no cadastro) ou a que já tem (na alteração).
CREATE FUNCTION app.product_unit_from(p_data jsonb, p_current text) RETURNS text
LANGUAGE plpgsql IMMUTABLE
SET search_path = ''
AS $$
DECLARE
  given text := NULLIF(pg_catalog.upper(pg_catalog.btrim(p_data ->> 'unit')), '');
BEGIN
  IF given IS NULL THEN
    RETURN COALESCE(p_current, 'UN');
  END IF;
  IF NOT app.is_measure_unit(given) THEN
    RAISE EXCEPTION 'Esta unidade de medida não existe.'
      USING ERRCODE = 'FA766', DETAIL = pg_catalog.format('Unidade %s.', pg_catalog.left(given, 10));
  END IF;
  RETURN given;
END;
$$;

-- Cadastro e alteração passam a gravar a unidade.
CREATE OR REPLACE FUNCTION app.create_product(p_data jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.require_products_manage();
  catalog_id uuid := (p_data ->> 'catalogProductId')::uuid;
  primary_code text := pg_catalog.btrim(p_data ->> 'barcode');
  new_id uuid;
BEGIN
  INSERT INTO public.product (
    economic_group_id, catalog_product_id, display_name, own_manufacturer, category_id,
    commission_group_id, pricing_group_id, price_family_id, uses_pmc, online_sale_blocked,
    fraction_quantity, unit
  ) VALUES (
    group_id, catalog_id, pg_catalog.btrim(p_data ->> 'displayName'),
    CASE WHEN catalog_id IS NULL THEN NULLIF(pg_catalog.btrim(p_data ->> 'ownManufacturer'), '') END,
    (p_data ->> 'categoryId')::uuid, (p_data ->> 'commissionGroupId')::uuid,
    (p_data ->> 'pricingGroupId')::uuid, (p_data ->> 'priceFamilyId')::uuid,
    COALESCE((p_data ->> 'usesPmc')::boolean, false),
    COALESCE((p_data ->> 'onlineSaleBlocked')::boolean, false),
    COALESCE((p_data ->> 'fractionQuantity')::numeric, 1),
    app.product_unit_from(p_data, NULL)
  ) RETURNING id INTO new_id;

  IF NULLIF(primary_code, '') IS NULL THEN
    RAISE EXCEPTION 'O produto precisa ter um código de barras principal.'
      USING ERRCODE = 'FA603', DETAIL = 'create_product sem código.';
  END IF;

  PERFORM app.insert_product_barcode(
    group_id, new_id, primary_code, (p_data ->> 'barcodeIsInternal')::boolean, true,
    true, true, NULL, NULL
  );

  IF catalog_id IS NOT NULL THEN
    INSERT INTO public.product_barcode (economic_group_id, product_id, code)
    SELECT group_id, new_id, cb.code
      FROM public.catalog_product_barcode cb
     WHERE cb.catalog_product_id = catalog_id AND cb.deleted_at IS NULL
    ON CONFLICT (economic_group_id, code) WHERE deleted_at IS NULL DO NOTHING;
  END IF;
  RETURN new_id;
END;
$$;

CREATE OR REPLACE FUNCTION app.update_product(p_product_id uuid, p_data jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.require_products_manage();
  catalog_id uuid := (p_data ->> 'catalogProductId')::uuid;
BEGIN
  UPDATE public.product p
     SET catalog_product_id = catalog_id,
         display_name = pg_catalog.btrim(p_data ->> 'displayName'),
         own_manufacturer = CASE WHEN catalog_id IS NULL
                                 THEN NULLIF(pg_catalog.btrim(p_data ->> 'ownManufacturer'), '') END,
         category_id = (p_data ->> 'categoryId')::uuid,
         commission_group_id = (p_data ->> 'commissionGroupId')::uuid,
         pricing_group_id = (p_data ->> 'pricingGroupId')::uuid,
         price_family_id = (p_data ->> 'priceFamilyId')::uuid,
         uses_pmc = COALESCE((p_data ->> 'usesPmc')::boolean, false),
         online_sale_blocked = COALESCE((p_data ->> 'onlineSaleBlocked')::boolean, false),
         fraction_quantity = COALESCE((p_data ->> 'fractionQuantity')::numeric, 1),
         unit = app.product_unit_from(p_data, p.unit)
   WHERE p.id = p_product_id AND p.economic_group_id = group_id AND p.deleted_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('product %s.', p_product_id);
  END IF;
END;
$$;

-- Cadastro novo a partir de um parecido: leva também a unidade do original.
CREATE OR REPLACE FUNCTION app.duplicate_product_for_item(p_item_id uuid, p_source_product_id uuid, p_data jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  item public.purchase_invoice_item;
  source public.product;
  new_id uuid;
BEGIN
  SELECT * INTO item FROM public.purchase_invoice_item it
   WHERE it.id = p_item_id AND it.economic_group_id = app.current_user_group() AND it.deleted_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('purchase_invoice_item %s.', p_item_id);
  END IF;
  PERFORM app.invoice_for_review(item.invoice_id);
  SELECT * INTO source FROM public.product p
   WHERE p.id = p_source_product_id AND p.economic_group_id = item.economic_group_id AND p.deleted_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Um dos itens informados não foi encontrado.'
      USING ERRCODE = 'FA004', DETAIL = pg_catalog.format('product %s.', p_source_product_id);
  END IF;
  -- O vínculo com o Catálogo é único por produto: a cópia nasce sem ele.
  new_id := app.create_product(pg_catalog.jsonb_build_object(
    'displayName', COALESCE(app.clean_text(p_data ->> 'displayName'), item.description),
    'barcode', COALESCE(app.clean_text(p_data ->> 'barcode'), item.barcode),
    'barcodeIsInternal', COALESCE((p_data ->> 'barcodeIsInternal')::boolean, false),
    'categoryId', source.category_id,
    'commissionGroupId', source.commission_group_id,
    'pricingGroupId', source.pricing_group_id,
    'priceFamilyId', source.price_family_id,
    'usesPmc', source.uses_pmc,
    'onlineSaleBlocked', source.online_sale_blocked,
    'ownManufacturer', source.own_manufacturer,
    'unit', source.unit
  ));
  PERFORM app.link_purchase_item(p_item_id, new_id, 'duplicate');
  RETURN new_id;
END;
$$;

-- O produto desce ao PDV com a unidade (a NFC-e usa em uCom e uTrib).
CREATE OR REPLACE FUNCTION app.pdv_product_data(p_branch_id uuid, p_ids uuid[])
RETURNS TABLE (id uuid, data jsonb)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT ids.id,
         CASE WHEN app.pdv_product_in_scope(ids.id, p_branch_id) THEN pg_catalog.jsonb_build_object(
           'code', p.code,
           'name', p.display_name,
           'unit', p.unit,
           'manufacturer', COALESCE(m.name, p.own_manufacturer),
           'active_ingredient', cp.active_ingredient,
           'controlled_class', cp.controlled_class,
           'ms_registration', cp.ms_registration,
           -- Sem o Catálogo, vale o NCM/CEST próprio (vindo da importação das notas).
           'ncm', COALESCE(cp.ncm, p.own_ncm),
           'cest', COALESCE(cp.cest, p.own_cest),
           'status', s.status,
           'price', app.effective_price(p.id, p_branch_id),
           'fraction_quantity', p.fraction_quantity,
           'batch_required', app.batch_required(p.id, p_branch_id),
           -- Hierarquia do motor de regras, para o PDV aplicar os descontos automáticos.
           'discount_subject', app.product_discount_subject(p.id),
           -- Desconto máximo em vigor (motor de regras) e até quando vale; vazio é sem regra.
           'max_discount', (SELECT r.value FROM app.resolve_product_rule('max_discount', p.id, p_branch_id) r LIMIT 1),
           'max_discount_until', (SELECT r.valid_to FROM app.resolve_product_rule('max_discount', p.id, p_branch_id) r LIMIT 1),
           'cashback', (SELECT r.value FROM app.resolve_product_rule('cashback', p.id, p_branch_id) r LIMIT 1),
           'barcodes', COALESCE((
             SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
                      'id', pb.id, 'code', pb.code, 'is_primary', pb.is_primary,
                      'fraction_quantity', pb.fraction_quantity) ORDER BY pb.code)
               FROM public.product_barcode pb
              WHERE pb.product_id = p.id AND pb.deleted_at IS NULL AND pb.scan_enabled
           ), '[]'::jsonb),
           -- Tributação do Catálogo; sem ela, a própria do cliente (importação), no mesmo formato.
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
           ), (
             SELECT pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
                      'id', r.id,
                      'valid_from', (r.source_emitted_at AT TIME ZONE 'America/Sao_Paulo')::date,
                      'cfop', r.cfop, 'origin', r.origin, 'benefit_code', r.benefit_code,
                      'icms_cst', r.icms_cst, 'icms_csosn', r.icms_csosn, 'icms_rate', r.icms_rate,
                      'pis_cst', r.pis_cst, 'pis_rate', r.pis_rate, 'cofins_cst', r.cofins_cst, 'cofins_rate', r.cofins_rate,
                      'own', true))
               FROM public.product_tax_rule r
              WHERE r.product_id = p.id AND r.tax_regime = c.tax_regime AND r.state = b.state AND r.deleted_at IS NULL
                -- O caixa precisa de PIS e COFINS para montar a nota.
                AND r.pis_cst IS NOT NULL AND r.cofins_cst IS NOT NULL
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

-- Permissão nova não vem dada a nenhum perfil: cada rede escolhe em /perfis. O "Cancelar nota de
-- entrada" sai do Gerente dos grupos novos (nos que já existem, fica como o perfil está).
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
    (p_group_id, 'Farmacêutico', 'Libera a venda de controlados no PDV e confere o SNGPC.'),
    (p_group_id, 'Operador de caixa', 'Abre o caixa, vende e orça no PDV.'),
    (p_group_id, 'Balconista', 'Monta orçamentos no PDV para o caixa fechar a venda.');

  -- A liberação do custo e o desconto acima do produto ficam só com o Administrador.
  INSERT INTO public.role_permission (role_id, permission_id)
  SELECT manager_id, p.id
    FROM public.permission p
   WHERE p.code IN (
     'users.view', 'users.reset_password', 'terminals.view', 'terminals.request', 'terminals.block',
     'products.view', 'stock.view', 'stock.loss', 'stock.transfer', 'stock.batch_override',
     'customers.view', 'customers.manage', 'fiscal.certificate', 'purchases.view', 'purchases.manage',
     'purchases.post', 'releases.view', 'sync.view', 'sync.resolve', 'sales.sell', 'sales.view', 'sales.zero_stock_release', 'controlled.view', 'sales.quote', 'sales.return',
     'users.release_login', 'users.biometrics', 'credit.view', 'credit.manage', 'health_professionals.manage',
     'pdv.quote_clear', 'pdv.sale_cancel', 'pdv.self_service_cancel', 'pdv.customer_create', 'pdv.prescriber_create'
   );
  INSERT INTO public.role_permission (role_id, permission_id)
  SELECT r.id, p.id
    FROM public.role r
    JOIN public.permission p ON p.code IN ('sales.sell', 'sales.quote', 'pdv.quote_clear', 'pdv.customer_create', 'pdv.prescriber_create')
   WHERE r.economic_group_id = p_group_id AND r.name = 'Operador de caixa';
  INSERT INTO public.role_permission (role_id, permission_id)
  SELECT r.id, p.id
    FROM public.role r
    JOIN public.permission p ON p.code IN ('sales.quote', 'pdv.quote_clear', 'pdv.customer_create')
   WHERE r.economic_group_id = p_group_id AND r.name = 'Balconista';
  INSERT INTO public.role_permission (role_id, permission_id)
  SELECT r.id, p.id
    FROM public.role r
    JOIN public.permission p ON p.code IN ('sales.sell', 'sales.quote', 'controlled.dispense', 'controlled.view', 'sngpc.manage',
                                           'health_professionals.manage', 'pdv.quote_clear', 'pdv.sale_cancel',
                                           'pdv.self_service_cancel', 'pdv.customer_create', 'pdv.prescriber_create')
   WHERE r.economic_group_id = p_group_id AND r.name = 'Farmacêutico';
  PERFORM app.seed_manager_limits(manager_id, p_group_id);
END;
$$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.measure_units() TO farmaerp_app;
