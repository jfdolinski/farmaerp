-- Up Migration

-- Tributação própria (I2c): o que a importação das notas cadastrou no próprio cliente desce para
-- o caixa quando o produto não tem os dados no Catálogo.
-- * NCM e CEST: os do Catálogo; sem eles, os próprios do produto (own_ncm, own_cest).
-- * Tributação: a do Catálogo para o regime e a UF da filial; sem nenhuma, a regra própria do
--   produto (product_tax_rule) no mesmo formato, marcada com own = true.
-- * Mudança na regra própria faz o produto descer de novo.

CREATE OR REPLACE FUNCTION app.track_sync_change() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid;
  target record;
BEGIN
  CASE TG_TABLE_NAME
    WHEN 'product' THEN
      PERFORM app.mark_sync_change('product', NEW.id, NEW.economic_group_id, NULL);
    WHEN 'product_branch_status', 'product_price' THEN
      PERFORM app.mark_sync_change('product', NEW.product_id, NEW.economic_group_id, NEW.branch_id);
    WHEN 'product_barcode' THEN
      PERFORM app.mark_sync_change('product', NEW.product_id, NEW.economic_group_id, NULL);
    WHEN 'product_tax_rule' THEN
      PERFORM app.mark_sync_change('product', NEW.product_id, NEW.economic_group_id, NULL);
    WHEN 'catalog_product' THEN
      PERFORM app.mark_sync_change('catalog_product', NEW.id, NULL, NULL);
    WHEN 'catalog_product_tax' THEN
      PERFORM app.mark_sync_change('catalog_product', NEW.catalog_product_id, NULL, NULL);
    WHEN 'catalog_manufacturer' THEN
      PERFORM app.mark_sync_change('manufacturer', NEW.id, NULL, NULL);
    WHEN 'stock_balance', 'product_batch' THEN
      PERFORM app.mark_sync_change('stock', NEW.product_id, NEW.economic_group_id, NEW.branch_id);
    WHEN 'user_account' THEN
      PERFORM app.mark_sync_change('user', NEW.id, NEW.economic_group_id, NULL);
    WHEN 'user_branch', 'user_role' THEN
      SELECT u.economic_group_id INTO group_id FROM public.user_account u WHERE u.id = NEW.user_id;
      PERFORM app.mark_sync_change('user', NEW.user_id, group_id, NULL);
    WHEN 'role' THEN
      PERFORM app.mark_sync_change('role', NEW.id, NEW.economic_group_id, NULL);
    WHEN 'role_permission' THEN
      SELECT r.economic_group_id INTO group_id FROM public.role r WHERE r.id = NEW.role_id;
      PERFORM app.mark_sync_change('role', NEW.role_id, group_id, NULL);
    WHEN 'role_limit' THEN
      PERFORM app.mark_sync_change('role', NEW.role_id, NEW.economic_group_id, NULL);
    WHEN 'branch' THEN
      SELECT c.economic_group_id INTO group_id FROM public.company c WHERE c.id = NEW.company_id;
      -- Estado, região do PMC ou empresa mudam a tributação de todos os produtos da filial.
      IF TG_OP = 'INSERT' OR NEW.state IS DISTINCT FROM OLD.state OR NEW.pmc_region IS DISTINCT FROM OLD.pmc_region
         OR NEW.company_id IS DISTINCT FROM OLD.company_id OR NEW.deleted_at IS DISTINCT FROM OLD.deleted_at THEN
        PERFORM app.mark_sync_change('branch', NEW.id, group_id, NEW.id);
      ELSE
        PERFORM app.mark_sync_change('fiscal', NEW.id, group_id, NEW.id);
      END IF;
    WHEN 'company' THEN
      FOR target IN SELECT b.id FROM public.branch b WHERE b.company_id = NEW.id LOOP
        IF TG_OP = 'UPDATE' AND NEW.tax_regime IS DISTINCT FROM OLD.tax_regime THEN
          PERFORM app.mark_sync_change('branch', target.id, NEW.economic_group_id, target.id);
        ELSE
          PERFORM app.mark_sync_change('fiscal', target.id, NEW.economic_group_id, target.id);
        END IF;
      END LOOP;
    WHEN 'customer' THEN
      PERFORM app.mark_sync_change('customer', NEW.id, NEW.economic_group_id, NULL);
    WHEN 'terminal_fiscal_series' THEN
      PERFORM app.mark_sync_change('fiscal', NEW.branch_id, NEW.economic_group_id, NEW.branch_id);
  END CASE;
  RETURN NULL;
END;
$$;


CREATE TRIGGER track_sync_change AFTER INSERT OR UPDATE ON product_tax_rule
  FOR EACH ROW EXECUTE FUNCTION app.track_sync_change();

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


-- Produtos já importados descem de novo com o NCM e a tributação próprios.
DO $$
DECLARE
  target record;
BEGIN
  FOR target IN
    SELECT p.id, p.economic_group_id FROM public.product p
     WHERE p.deleted_at IS NULL
       AND (p.own_ncm IS NOT NULL OR p.own_cest IS NOT NULL
            OR EXISTS (SELECT 1 FROM public.product_tax_rule r WHERE r.product_id = p.id AND r.deleted_at IS NULL))
  LOOP
    PERFORM app.mark_sync_change('product', target.id, target.economic_group_id, NULL);
  END LOOP;
END;
$$;
