-- Up Migration

-- Consulta de vendas do cliente: ticket médio dos últimos 12 meses, compras dos últimos 30 dias e
-- produtos recorrentes (em 2 ou mais compras nos últimos 180 dias).
-- Na retaguarda, conta só as filiais que o usuário vê (customers.view ou customers.manage). No
-- caixa (com internet), conta a rede inteira do grupo: o histórico ajuda a atender em qualquer loja.

CREATE FUNCTION app.customer_history_data(p_customer_id uuid, p_branch_ids uuid[]) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  WITH sales AS (
    SELECT s.id, s.code, s.sold_at, s.total, s.branch_id
      FROM public.sale s
     WHERE s.customer_id = p_customer_id AND s.deleted_at IS NULL AND s.branch_id = ANY (p_branch_ids)
       AND s.sold_at >= pg_catalog.now() - interval '12 months'
  ),
  recent AS (
    SELECT s.id, s.code, s.sold_at, s.total, b.name AS branch_name,
           (SELECT pg_catalog.count(*)::integer FROM public.sale_item i WHERE i.sale_id = s.id AND i.deleted_at IS NULL) AS items
      FROM sales s JOIN public.branch b ON b.id = s.branch_id
     WHERE s.sold_at >= pg_catalog.now() - interval '30 days'
     ORDER BY s.sold_at DESC
     LIMIT 50
  ),
  recurring AS (
    SELECT i.product_id, p.display_name AS name,
           pg_catalog.count(DISTINCT i.sale_id)::integer AS purchases,
           pg_catalog.sum(i.quantity) AS quantity,
           pg_catalog.max(s.sold_at) AS last_at
      FROM sales s
      JOIN public.sale_item i ON i.sale_id = s.id AND i.deleted_at IS NULL
      JOIN public.product p ON p.id = i.product_id
     WHERE s.sold_at >= pg_catalog.now() - interval '180 days'
     GROUP BY i.product_id, p.display_name
    HAVING pg_catalog.count(DISTINCT i.sale_id) >= 2
     ORDER BY pg_catalog.count(DISTINCT i.sale_id) DESC, pg_catalog.max(s.sold_at) DESC
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
               'total', r.total, 'items', r.items) ORDER BY r.sold_at DESC)
        FROM recent r), '[]'::jsonb),
    'recurring', COALESCE((
      SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
               'product_id', r.product_id, 'name', r.name, 'purchases', r.purchases, 'quantity', r.quantity,
               'last_at', r.last_at) ORDER BY r.purchases DESC, r.last_at DESC)
        FROM recurring r), '[]'::jsonb)
  )
$$;

-- Retaguarda: filiais que o usuário vê.
CREATE FUNCTION app.customer_purchase_history(p_customer_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT (app.has_permission_anywhere('customers.view') OR app.has_permission_anywhere('customers.manage')) THEN
    RAISE EXCEPTION 'Você não tem permissão para esta operação.'
      USING ERRCODE = 'FA002', DETAIL = 'Histórico do cliente sem customers.view.';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.customer c
     WHERE c.id = p_customer_id AND c.economic_group_id = app.current_user_group() AND c.deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('customer %s.', p_customer_id);
  END IF;
  RETURN app.customer_history_data(p_customer_id, app.allowed_branch_ids());
END;
$$;

-- Caixa: a rede inteira do grupo do terminal.
CREATE FUNCTION app.pdv_customer_history(p_customer_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  terminal_row public.terminal := app.require_active_terminal();
  group_id uuid;
BEGIN
  SELECT c.economic_group_id INTO group_id
    FROM public.branch b JOIN public.company c ON c.id = b.company_id
   WHERE b.id = terminal_row.branch_id;
  IF NOT EXISTS (
    SELECT 1 FROM public.customer c WHERE c.id = p_customer_id AND c.economic_group_id = group_id AND c.deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('customer %s para o terminal.', p_customer_id);
  END IF;
  RETURN app.customer_history_data(p_customer_id, ARRAY(
    SELECT b.id FROM public.branch b JOIN public.company c ON c.id = b.company_id WHERE c.economic_group_id = group_id
  ));
END;
$$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  app.customer_purchase_history(uuid),
  app.pdv_customer_history(uuid)
TO farmaerp_app;
