-- Up Migration

-- Vendas importadas do sistema anterior (I2b): consulta na retaguarda e no histórico do cliente.
-- Quem vê é quem tem sales.view na filial da venda, como nas vendas do PDV.

-- Lista por filial e período (no máximo 500), com o cliente e o número da nota.
CREATE FUNCTION app.list_imported_sales(
  p_branch_id uuid DEFAULT NULL, p_from date DEFAULT NULL, p_to date DEFAULT NULL, p_customer_id uuid DEFAULT NULL
)
RETURNS TABLE (
  id uuid, branch_id uuid, branch_name text, model text, series integer, number bigint, emitted_at timestamptz,
  customer_id uuid, customer_name text, total numeric, item_count integer, payment_methods text[], canceled_at timestamptz
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT s.id, s.branch_id, b.name, s.model, s.series, s.number, s.emitted_at, s.customer_id, c.name, s.total,
         (SELECT pg_catalog.count(*)::integer FROM public.imported_sale_item i WHERE i.imported_sale_id = s.id AND i.deleted_at IS NULL),
         ARRAY(SELECT DISTINCT p.method FROM public.imported_sale_payment p
                WHERE p.imported_sale_id = s.id AND p.deleted_at IS NULL ORDER BY 1),
         s.canceled_at
    FROM public.imported_sale s
    JOIN public.branch b ON b.id = s.branch_id
    LEFT JOIN public.customer c ON c.id = s.customer_id
   WHERE s.deleted_at IS NULL
     AND s.economic_group_id = app.current_user_group()
     AND app.has_permission('sales.view', s.branch_id)
     AND (p_branch_id IS NULL OR s.branch_id = p_branch_id)
     AND (p_customer_id IS NULL OR s.customer_id = p_customer_id)
     AND (p_from IS NULL OR s.emitted_at >= p_from::timestamp AT TIME ZONE 'America/Sao_Paulo')
     AND (p_to IS NULL OR s.emitted_at < (p_to + 1)::timestamp AT TIME ZONE 'America/Sao_Paulo')
   ORDER BY s.emitted_at DESC, s.id DESC
   LIMIT 500
$$;

-- Venda importada completa (sem o XML): itens com o código do sistema anterior e pagamentos.
CREATE FUNCTION app.imported_sale_detail(p_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT pg_catalog.jsonb_build_object(
    'id', s.id, 'branch_name', b.name, 'access_key', s.access_key, 'model', s.model, 'series', s.series,
    'number', s.number, 'emitted_at', s.emitted_at, 'protocol', s.protocol, 'customer_id', s.customer_id,
    'customer_name', c.name, 'customer_code', c.code, 'subtotal', s.subtotal, 'discount_total', s.discount_total,
    'total', s.total, 'change', s.change_amount, 'canceled_at', s.canceled_at, 'imported_at', s.created_at,
    'import_id', s.import_id, 'file_name', d.file_name,
    'items', COALESCE((
      SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'line', i.line, 'product_id', i.product_id, 'product_code', p.code, 'legacy_code', p.legacy_code,
        'product_name', p.display_name, 'quantity', i.quantity, 'unit_price', i.unit_price, 'discount', i.discount,
        'total', i.total, 'cfop', i.cfop
      ) ORDER BY i.line)
        FROM public.imported_sale_item i JOIN public.product p ON p.id = i.product_id
       WHERE i.imported_sale_id = s.id AND i.deleted_at IS NULL
    ), '[]'::jsonb),
    'payments', COALESCE((
      SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'method', p.method, 'description', p.description, 'amount', p.amount, 'card_brand', p.card_brand,
        'authorization_code', p.authorization_code
      ) ORDER BY p.created_at, p.id)
        FROM public.imported_sale_payment p
       WHERE p.imported_sale_id = s.id AND p.deleted_at IS NULL
    ), '[]'::jsonb)
  )
    FROM public.imported_sale s
    JOIN public.branch b ON b.id = s.branch_id
    JOIN public.document_import d ON d.id = s.import_id
    LEFT JOIN public.customer c ON c.id = s.customer_id
   WHERE s.id = p_id AND s.deleted_at IS NULL
     AND s.economic_group_id = app.current_user_group()
     AND app.has_permission('sales.view', s.branch_id)
$$;

-- XML da nota importada, como veio no arquivo.
CREATE FUNCTION app.imported_sale_xml(p_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT pg_catalog.jsonb_build_object('access_key', s.access_key, 'model', s.model, 'xml', s.xml)
    FROM public.imported_sale s
   WHERE s.id = p_id AND s.deleted_at IS NULL
     AND s.economic_group_id = app.current_user_group()
     AND app.has_permission('sales.view', s.branch_id)
$$;

-- Histórico do cliente: as vendas importadas (não canceladas) entram junto com as do PDV. A
-- importada vem com imported = true e o "código" é o número da nota (o caixa mostra como texto).
CREATE OR REPLACE FUNCTION app.customer_history_data(p_customer_id uuid, p_branch_ids uuid[]) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  WITH sales AS (
    SELECT s.id, s.code, s.sold_at, s.total, s.branch_id, false AS imported
      FROM public.sale s
     WHERE s.customer_id = p_customer_id AND s.deleted_at IS NULL AND s.branch_id = ANY (p_branch_ids)
       AND s.sold_at >= pg_catalog.now() - interval '12 months'
    UNION ALL
    SELECT s.id,
           CASE s.model WHEN '65' THEN 'NFC-e ' ELSE 'NF-e ' END || s.series || '/' || s.number,
           s.emitted_at, s.total, s.branch_id, true
      FROM public.imported_sale s
     WHERE s.customer_id = p_customer_id AND s.deleted_at IS NULL AND s.canceled_at IS NULL
       AND s.branch_id = ANY (p_branch_ids)
       AND s.emitted_at >= pg_catalog.now() - interval '12 months'
  ),
  lines AS (
    SELECT i.sale_id, i.product_id, i.quantity
      FROM public.sale_item i
     WHERE i.deleted_at IS NULL AND i.sale_id IN (SELECT s.id FROM sales s WHERE NOT s.imported)
    UNION ALL
    SELECT i.imported_sale_id, i.product_id, i.quantity
      FROM public.imported_sale_item i
     WHERE i.deleted_at IS NULL AND i.imported_sale_id IN (SELECT s.id FROM sales s WHERE s.imported)
  ),
  recent AS (
    SELECT s.id, s.code, s.sold_at, s.total, s.imported, b.name AS branch_name,
           (SELECT pg_catalog.count(*)::integer FROM lines l WHERE l.sale_id = s.id) AS items
      FROM sales s JOIN public.branch b ON b.id = s.branch_id
     WHERE s.sold_at >= pg_catalog.now() - interval '30 days'
     ORDER BY s.sold_at DESC
     LIMIT 50
  ),
  recurring AS (
    SELECT l.product_id, p.display_name AS name,
           pg_catalog.count(DISTINCT l.sale_id)::integer AS purchases,
           pg_catalog.sum(l.quantity) AS quantity,
           pg_catalog.max(s.sold_at) AS last_at
      FROM sales s
      JOIN lines l ON l.sale_id = s.id
      JOIN public.product p ON p.id = l.product_id
     WHERE s.sold_at >= pg_catalog.now() - interval '180 days'
     GROUP BY l.product_id, p.display_name
    HAVING pg_catalog.count(DISTINCT l.sale_id) >= 2
     ORDER BY pg_catalog.count(DISTINCT l.sale_id) DESC, pg_catalog.max(s.sold_at) DESC
     LIMIT 20
  )
  SELECT pg_catalog.jsonb_build_object(
    'sales_12m', (SELECT pg_catalog.count(*)::integer FROM sales),
    'total_12m', (SELECT COALESCE(pg_catalog.sum(total), 0) FROM sales),
    'average_ticket', (SELECT pg_catalog.round(pg_catalog.avg(total), 2) FROM sales),
    'last_purchase_at', (SELECT pg_catalog.max(sold_at) FROM sales),
    'last_30_days', COALESCE((
      SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
               'sale_id', r.id, 'code', r.code, 'sold_at', r.sold_at, 'branch_name', r.branch_name,
               'total', r.total, 'items', r.items, 'imported', r.imported) ORDER BY r.sold_at DESC)
        FROM recent r), '[]'::jsonb),
    'recurring', COALESCE((
      SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
               'product_id', r.product_id, 'name', r.name, 'purchases', r.purchases, 'quantity', r.quantity,
               'last_at', r.last_at) ORDER BY r.purchases DESC, r.last_at DESC)
        FROM recurring r), '[]'::jsonb)
  )
$$;

REVOKE ALL ON FUNCTION
  app.list_imported_sales(uuid, date, date, uuid),
  app.imported_sale_detail(uuid),
  app.imported_sale_xml(uuid)
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  app.list_imported_sales(uuid, date, date, uuid),
  app.imported_sale_detail(uuid),
  app.imported_sale_xml(uuid)
TO farmaerp_app;
