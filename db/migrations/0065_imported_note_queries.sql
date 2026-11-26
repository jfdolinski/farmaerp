-- Up Migration

-- Notas de estoque importadas (I3b): compras, devoluções, transferências e outras entradas e
-- saídas trazidas do sistema anterior. Quem vê é quem tem stock.view ou purchases.view numa das
-- filiais da nota (a do cliente ou, na transferência, a que recebeu).

CREATE FUNCTION app.can_see_imported_note(p_branch_id uuid, p_counterpart_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT app.has_permission('stock.view', p_branch_id) OR app.has_permission('purchases.view', p_branch_id)
      OR (p_counterpart_id IS NOT NULL
          AND (app.has_permission('stock.view', p_counterpart_id) OR app.has_permission('purchases.view', p_counterpart_id)))
$$;

-- Lista por filial (a da nota ou a que recebeu), período e natureza (no máximo 500).
CREATE FUNCTION app.list_imported_notes(
  p_branch_id uuid DEFAULT NULL, p_from date DEFAULT NULL, p_to date DEFAULT NULL, p_kind text DEFAULT NULL
)
RETURNS TABLE (
  id uuid, branch_id uuid, branch_name text, counterpart_branch_name text, kind text, series integer, number bigint,
  emitted_at timestamptz, party_document text, party_name text, supplier_id uuid, total numeric, item_count integer,
  canceled_at timestamptz
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT n.id, n.branch_id, b.name, cb.name, n.kind, n.series, n.number, n.emitted_at, n.party_document, n.party_name,
         n.supplier_id, n.total,
         (SELECT pg_catalog.count(*)::integer FROM public.imported_stock_note_item i WHERE i.note_id = n.id AND i.deleted_at IS NULL),
         n.canceled_at
    FROM public.imported_stock_note n
    JOIN public.branch b ON b.id = n.branch_id
    LEFT JOIN public.branch cb ON cb.id = n.counterpart_branch_id
   WHERE n.deleted_at IS NULL
     AND n.economic_group_id = app.current_user_group()
     AND app.can_see_imported_note(n.branch_id, n.counterpart_branch_id)
     AND (p_branch_id IS NULL OR n.branch_id = p_branch_id OR n.counterpart_branch_id = p_branch_id)
     AND (p_kind IS NULL OR n.kind = p_kind)
     AND (p_from IS NULL OR n.emitted_at >= p_from::timestamp AT TIME ZONE 'America/Sao_Paulo')
     AND (p_to IS NULL OR n.emitted_at < (p_to + 1)::timestamp AT TIME ZONE 'America/Sao_Paulo')
   ORDER BY n.emitted_at DESC, n.id DESC
   LIMIT 500
$$;

-- Nota completa (sem o XML): itens com o produto, o código do fornecedor, a quantidade da nota e
-- a do estoque, o custo e os lotes.
CREATE FUNCTION app.imported_note_detail(p_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT pg_catalog.jsonb_build_object(
    'id', n.id, 'branch_name', b.name, 'counterpart_branch_name', cb.name, 'kind', n.kind, 'access_key', n.access_key,
    'series', n.series, 'number', n.number, 'emitted_at', n.emitted_at, 'protocol', n.protocol, 'cfop', n.cfop,
    'supplier_id', n.supplier_id, 'supplier_name', s.legal_name, 'party_document', n.party_document, 'party_name', n.party_name,
    'total', n.total, 'canceled_at', n.canceled_at, 'imported_at', n.created_at, 'import_id', n.import_id, 'file_name', d.file_name,
    'items', COALESCE((
      SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'line', i.line, 'product_id', i.product_id, 'product_code', p.code, 'product_name', p.display_name,
        'supplier_code', i.supplier_code, 'note_quantity', i.note_quantity, 'quantity', i.quantity, 'unit', i.unit,
        'total', i.total, 'unit_cost', i.unit_cost, 'cfop', i.cfop, 'batches', i.batches
      ) ORDER BY i.line)
        FROM public.imported_stock_note_item i JOIN public.product p ON p.id = i.product_id
       WHERE i.note_id = n.id AND i.deleted_at IS NULL
    ), '[]'::jsonb)
  )
    FROM public.imported_stock_note n
    JOIN public.branch b ON b.id = n.branch_id
    LEFT JOIN public.branch cb ON cb.id = n.counterpart_branch_id
    LEFT JOIN public.supplier s ON s.id = n.supplier_id
    JOIN public.document_import d ON d.id = n.import_id
   WHERE n.id = p_id AND n.deleted_at IS NULL
     AND n.economic_group_id = app.current_user_group()
     AND app.can_see_imported_note(n.branch_id, n.counterpart_branch_id)
$$;

-- XML da nota como veio no arquivo.
CREATE FUNCTION app.imported_note_xml(p_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT pg_catalog.jsonb_build_object('access_key', n.access_key, 'xml', n.xml)
    FROM public.imported_stock_note n
   WHERE n.id = p_id AND n.deleted_at IS NULL
     AND n.economic_group_id = app.current_user_group()
     AND app.can_see_imported_note(n.branch_id, n.counterpart_branch_id)
$$;

REVOKE ALL ON FUNCTION
  app.can_see_imported_note(uuid, uuid),
  app.list_imported_notes(uuid, date, date, text),
  app.imported_note_detail(uuid),
  app.imported_note_xml(uuid)
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  app.list_imported_notes(uuid, date, date, text),
  app.imported_note_detail(uuid),
  app.imported_note_xml(uuid)
TO farmaerp_app;
