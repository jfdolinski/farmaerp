-- Up Migration

-- Etapa 7, PR 7C-2: cashback no PDV.
-- O produto desce com o percentual de cashback do motor (para o comprovante mostrar o ganho), e a
-- venda buscada para a devolução diz quanto foi pago com cashback e quanto já voltou, para o PDV
-- separar a parte do cashback do valor a devolver (a mesma conta de app.cashback_refund_for).
-- Formato 6 da descida: os PDVs refazem a carga para receber o percentual.

CREATE OR REPLACE FUNCTION app.pdv_sync_format() RETURNS integer
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$ SELECT 6 $$;

-- Produto para o PDV: com o percentual de cashback.
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
           'cashback', (SELECT r.value FROM app.resolve_product_rule('cashback', p.id, p_branch_id) r LIMIT 1),
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

-- Venda para a devolução no PDV: com o cashback usado e o que já voltou.
CREATE OR REPLACE FUNCTION app.pdv_sale_for_return(p_code text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  terminal_row public.terminal := app.require_active_terminal();
  found_sale public.sale;
  days smallint;
BEGIN
  SELECT s.* INTO found_sale FROM public.sale s
   WHERE s.branch_id = terminal_row.branch_id AND s.code = pg_catalog.btrim(COALESCE(p_code, '')) AND s.deleted_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Venda não encontrada nesta loja.'
      USING ERRCODE = 'FA891', DETAIL = pg_catalog.format('Código %s.', p_code);
  END IF;
  SELECT b.return_days INTO days FROM public.branch b WHERE b.id = terminal_row.branch_id;
  RETURN pg_catalog.jsonb_build_object(
    'id', found_sale.id, 'code', found_sale.code, 'sold_at', found_sale.sold_at, 'total', found_sale.total,
    'customer_id', found_sale.customer_id,
    'customer_name', (SELECT c.name FROM public.customer c WHERE c.id = found_sale.customer_id),
    'late', app.return_is_late(found_sale.sold_at, pg_catalog.now(), days), 'return_days', days,
    'cashback_used', COALESCE((SELECT pg_catalog.sum(p.amount) FROM public.sale_payment p
                                 WHERE p.sale_id = found_sale.id AND p.method = 'cashback' AND p.deleted_at IS NULL), 0),
    'returned_total', COALESCE((SELECT pg_catalog.sum(r.total) FROM public.sale_return r
                                 WHERE r.sale_id = found_sale.id AND r.deleted_at IS NULL), 0),
    'cashback_refunded', COALESCE((SELECT pg_catalog.sum(r.cashback_refund) FROM public.sale_return r
                                    WHERE r.sale_id = found_sale.id AND r.deleted_at IS NULL), 0),
    'has_store_credit', EXISTS (
      SELECT 1 FROM public.sale_payment p WHERE p.sale_id = found_sale.id AND p.method = 'store_credit' AND p.deleted_at IS NULL
    ),
    'has_agreement', EXISTS (
      SELECT 1 FROM public.sale_payment p WHERE p.sale_id = found_sale.id AND p.method = 'agreement' AND p.deleted_at IS NULL
    ),
    'items', (
      SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', i.id, 'line', i.line, 'product_id', i.product_id, 'product_code', p.code, 'product_name', p.display_name,
        'quantity', i.quantity, 'total', i.total,
        'returned_quantity', COALESCE(done.quantity, 0), 'returned_amount', COALESCE(done.amount, 0),
        'controlled', cp.controlled_class IS NOT NULL
      ) ORDER BY i.line)
        FROM public.sale_item i
        JOIN public.product p ON p.id = i.product_id
        LEFT JOIN public.catalog_product cp ON cp.id = p.catalog_product_id
        LEFT JOIN LATERAL (
          SELECT pg_catalog.sum(ri.quantity) AS quantity, pg_catalog.sum(ri.amount) AS amount
            FROM public.sale_return_item ri WHERE ri.sale_item_id = i.id AND ri.deleted_at IS NULL
        ) done ON true
       WHERE i.sale_id = found_sale.id AND i.deleted_at IS NULL
    )
  );
END;
$$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;
