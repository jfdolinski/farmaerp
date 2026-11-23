-- Up Migration

-- Fecha a Etapa 3: clientes buscados pelo PDV e acompanhamento da sincronização na retaguarda.
--
-- Clientes: o PDV busca com internet em dois passos. A busca devolve a lista com o documento
-- mascarado; só o cliente escolhido desce inteiro e fica guardado no terminal. A central anota quem
-- cada terminal guardou e, daí em diante, a descida leva as mudanças (e a retirada) só desses
-- clientes. Os clientes do crediário descem para todos os terminais quando o crediário existir.

CREATE TABLE pdv_customer_cache (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  terminal_id uuid NOT NULL REFERENCES terminal (id),
  customer_id uuid NOT NULL REFERENCES customer (id),
  -- Última vez que o terminal buscou o cliente inteiro.
  fetched_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE UNIQUE INDEX pdv_customer_cache_key ON pdv_customer_cache (terminal_id, customer_id) WHERE deleted_at IS NULL;
CREATE INDEX pdv_customer_cache_customer_idx ON pdv_customer_cache (customer_id);
CREATE INDEX pdv_customer_cache_economic_group_id_idx ON pdv_customer_cache (economic_group_id);

CALL app.apply_table_standard('public.pdv_customer_cache');

CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON pdv_customer_cache
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns('economic_group_id', 'terminal_id', 'customer_id');

CREATE POLICY pdv_customer_cache_select ON pdv_customer_cache FOR SELECT TO farmaerp_app USING (false);
CREATE VIEW v_pdv_customer_cache WITH (security_invoker = true) AS
  SELECT * FROM pdv_customer_cache WHERE deleted_at IS NULL;

ALTER TABLE sync_change DROP CONSTRAINT sync_change_entity_check;
ALTER TABLE sync_change ADD CONSTRAINT sync_change_entity_check CHECK (entity IN (
  'product', 'catalog_product', 'manufacturer', 'stock', 'user', 'role', 'branch', 'fiscal', 'customer'
));

-- Situação da sincronização vista pela central.
ALTER TABLE terminal_status
  ADD COLUMN last_pull_at timestamptz,
  ADD COLUMN last_push_at timestamptz,
  -- O cursor entregue na última descida concluída: o que mudou depois dele ainda não chegou ao PDV.
  ADD COLUMN pull_cursor xid8,
  -- Primeira carga inteira concluída (e a última, se o PDV refez a carga).
  ADD COLUMN initial_load_at timestamptz;

CREATE OR REPLACE VIEW v_terminal_status WITH (security_invoker = true) AS
  SELECT * FROM terminal_status WHERE deleted_at IS NULL;

-- Anota a descida ou a subida do terminal autenticado.
CREATE FUNCTION app.record_terminal_sync(p_kind text, p_cursor xid8, p_full_load boolean) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  now_at timestamptz := pg_catalog.clock_timestamp();
BEGIN
  INSERT INTO public.terminal_status (terminal_id, last_seen_at, last_pull_at, last_push_at, pull_cursor, initial_load_at)
  VALUES (
    app.current_terminal_id(), now_at,
    CASE WHEN p_kind = 'pull' THEN now_at END,
    CASE WHEN p_kind = 'push' THEN now_at END,
    p_cursor,
    CASE WHEN p_full_load THEN now_at END
  )
  ON CONFLICT (terminal_id) WHERE deleted_at IS NULL DO UPDATE
    SET last_seen_at = EXCLUDED.last_seen_at,
        last_pull_at = COALESCE(EXCLUDED.last_pull_at, public.terminal_status.last_pull_at),
        last_push_at = COALESCE(EXCLUDED.last_push_at, public.terminal_status.last_push_at),
        pull_cursor = COALESCE(EXCLUDED.pull_cursor, public.terminal_status.pull_cursor),
        initial_load_at = COALESCE(EXCLUDED.initial_load_at, public.terminal_status.initial_load_at);
END;
$$;

-- Cliente pronto para o PDV: dados de cadastro para a venda e a nota. Vazio se o terminal não o
-- guardou ou se ele foi excluído (o PDV retira da cópia local).
CREATE FUNCTION app.pdv_customer_data(p_terminal_id uuid, p_ids uuid[])
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
           'state', c.state
         ) END
    FROM pg_catalog.unnest(p_ids) AS ids(id)
    LEFT JOIN public.pdv_customer_cache cc
      ON cc.customer_id = ids.id AND cc.terminal_id = p_terminal_id AND cc.deleted_at IS NULL
    LEFT JOIN public.customer c ON c.id = cc.customer_id AND c.deleted_at IS NULL
     AND c.economic_group_id = cc.economic_group_id
$$;

-- Busca do PDV: nome (3 letras ou mais), código ou CPF/CNPJ. Documento sempre mascarado na lista.
CREATE FUNCTION app.pdv_search_customers(p_query text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  terminal_row public.terminal := app.require_active_terminal();
  group_id uuid;
  query_text text := pg_catalog.btrim(COALESCE(p_query, ''));
  query_document text := app.clean_document(p_query);
  patterns text[] := app.search_patterns(p_query);
BEGIN
  IF pg_catalog.length(query_text) > 100
     OR (query_text !~ '^[0-9]+$' AND pg_catalog.length(pg_catalog.regexp_replace(query_text, '[^[:alpha:]]', '', 'g')) < 3
         AND COALESCE(pg_catalog.length(query_document), 0) NOT IN (11, 14)) THEN
    RAISE EXCEPTION 'Digite ao menos 3 letras do nome, o código ou o CPF/CNPJ do cliente.'
      USING ERRCODE = 'FA961', DETAIL = 'Busca de cliente curta demais no PDV.';
  END IF;
  SELECT c.economic_group_id INTO group_id
    FROM public.branch b JOIN public.company c ON c.id = b.company_id
   WHERE b.id = terminal_row.branch_id;

  RETURN COALESCE((
    SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
             'id', found.id, 'code', found.code, 'person_type', found.person_type, 'name', found.name,
             'trade_name', found.trade_name, 'document_masked', app.mask_document(found.document),
             'city', found.city, 'state', found.state) ORDER BY found.name, found.id)
      FROM (
        SELECT c.* FROM public.customer c
         WHERE c.deleted_at IS NULL AND c.economic_group_id = group_id
           AND (c.code::text = query_text OR c.document = query_document
                OR (query_text !~ '^[0-9]+$' AND c.search_text LIKE ALL (patterns)))
         ORDER BY c.name, c.id
         LIMIT 20
      ) found
  ), '[]'::jsonb);
END;
$$;

-- Cliente escolhido no PDV: desce inteiro e passa a ser acompanhado pela descida deste terminal.
CREATE FUNCTION app.pdv_get_customer(p_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  terminal_row public.terminal := app.require_active_terminal();
  group_id uuid;
  result jsonb;
BEGIN
  SELECT c.economic_group_id INTO group_id
    FROM public.branch b JOIN public.company c ON c.id = b.company_id
   WHERE b.id = terminal_row.branch_id;
  IF NOT EXISTS (
    SELECT 1 FROM public.customer c WHERE c.id = p_id AND c.deleted_at IS NULL AND c.economic_group_id = group_id
  ) THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('customer %s para o terminal.', p_id);
  END IF;

  INSERT INTO public.pdv_customer_cache (economic_group_id, terminal_id, customer_id)
  VALUES (group_id, terminal_row.id, p_id)
  ON CONFLICT (terminal_id, customer_id) WHERE deleted_at IS NULL
  DO UPDATE SET fetched_at = pg_catalog.clock_timestamp();

  SELECT d.data INTO result FROM app.pdv_customer_data(terminal_row.id, ARRAY[p_id]) d;
  RETURN pg_catalog.jsonb_build_object('id', p_id, 'data', result);
END;
$$;

-- Mudanças que ainda não chegaram ao terminal (até 10.001, para não pesar a tela). Vazio sem
-- permissão ou antes da primeira descida.
CREATE FUNCTION app.terminal_sync_lag(p_terminal_id uuid) RETURNS integer
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT (
    SELECT pg_catalog.count(*)::integer FROM (
      SELECT 1 FROM public.sync_change sc
       WHERE sc.deleted_at IS NULL AND sc.xid >= s.pull_cursor
         AND (sc.economic_group_id IS NULL OR sc.economic_group_id = c.economic_group_id)
         AND (sc.branch_id IS NULL OR sc.branch_id = t.branch_id)
       LIMIT 10001
    ) pending
  )
    FROM public.terminal t
    JOIN public.branch b ON b.id = t.branch_id
    JOIN public.company c ON c.id = b.company_id
    JOIN public.terminal_status s ON s.terminal_id = t.id AND s.deleted_at IS NULL
   WHERE t.id = p_terminal_id AND s.pull_cursor IS NOT NULL
     AND c.economic_group_id = app.current_user_group()
     AND app.has_permission('terminals.view', t.branch_id)
$$;

CREATE OR REPLACE VIEW v_terminal_monitor WITH (security_invoker = true) AS
  SELECT
    t.id,
    t.branch_id,
    b.name AS branch_name,
    t.name,
    t.profile,
    t.status,
    t.created_at,
    r.platform,
    r.device_name,
    r.key_storage,
    COALESCE(s.app_version, r.app_version) AS app_version,
    s.last_seen_at,
    CASE
      WHEN s.last_seen_at >= now() - interval '3 minutes' THEN 'online'
      ELSE 'offline'
    END AS connectivity,
    s.last_sync_at,
    s.outbox_pending,
    t.number,
    s.initial_load_at,
    s.last_pull_at,
    s.last_push_at,
    app.terminal_sync_lag(t.id) AS pending_changes,
    -- Só conta para quem pode ver os conflitos (a política da tabela decide).
    (SELECT pg_catalog.count(*)::integer FROM sync_conflict sc
      WHERE sc.terminal_id = t.id AND sc.status = 'open' AND sc.deleted_at IS NULL) AS open_conflicts
  FROM terminal t
  JOIN branch b ON b.id = t.branch_id
  LEFT JOIN terminal_status s ON s.terminal_id = t.id AND s.deleted_at IS NULL
  LEFT JOIN terminal_pairing_request r ON r.terminal_id = t.id AND r.deleted_at IS NULL
  WHERE t.deleted_at IS NULL;

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

CREATE TRIGGER track_sync_change AFTER INSERT OR UPDATE ON customer
  FOR EACH ROW EXECUTE FUNCTION app.track_sync_change();

DROP FUNCTION app.pdv_targets(uuid, uuid, xid8, xid8);

-- O que precisa descer para a filial: tudo (carga inicial, sem p_since) ou o que mudou entre
-- p_since e p_until. Ordem de entrega: 1 fiscal, 2 usuários, 3 produtos, 4 estoque, 5 clientes guardados
-- pelo terminal.
CREATE FUNCTION app.pdv_targets(p_branch_id uuid, p_group_id uuid, p_terminal_id uuid, p_since xid8, p_until xid8)
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
  )
  SELECT 1, p_branch_id
   WHERE p_since IS NULL OR EXISTS (SELECT 1 FROM changed WHERE entity IN ('fiscal', 'branch'))
  UNION ALL SELECT 2, users.id FROM users
  UNION ALL SELECT 3, products.id FROM products
  UNION ALL SELECT 4, stock.id FROM stock
  UNION ALL SELECT 5, customers.id FROM customers
$$;

-- Descida para o terminal autenticado na transação.
--   p_cursor: o until da última descida concluída; vazio faz a carga inteira.
--   p_until e p_after: vêm da resposta anterior, para buscar o próximo pacote da mesma janela.
-- Devolve { format, until, total, items: [{ type, id, data }], next }. data vazio: retirar da cópia
-- local. total vem só no primeiro pacote da janela: é o que permite mostrar o progresso da carga.
-- Com next vazio, a janela terminou e o PDV grava until como o novo cursor; a central anota a hora
-- e o cursor na situação do terminal, para a retaguarda acompanhar.
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
     OR (p_after IS NOT NULL AND (p_until IS NULL OR p_after !~ '^[1-5]:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'))
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

-- Subida para o terminal autenticado. p_items: [{ id, sequence, kind, payload }], em ordem.
-- Devolve { results: [{ id, status, code }] }: applied, conflict (com o código) ou duplicate
-- (já recebido antes; result traz como ficou).
CREATE OR REPLACE FUNCTION app.pdv_push(p_items jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  terminal_row public.terminal := app.require_active_terminal();
  group_id uuid;
  item jsonb;
  item_id uuid;
  item_sequence bigint;
  last_sequence bigint := 0;
  existing public.sync_receipt;
  outcome text;
  failure_code text;
  failure_message text;
  results jsonb := '[]'::jsonb;
BEGIN
  IF pg_catalog.jsonb_typeof(p_items) IS DISTINCT FROM 'array'
     OR pg_catalog.jsonb_array_length(p_items) NOT BETWEEN 1 AND 500 THEN
    RAISE EXCEPTION 'Os dados da sincronização são inválidos.'
      USING ERRCODE = 'FA956', DETAIL = 'Lista de itens vazia, grande demais ou fora do formato.';
  END IF;

  SELECT c.economic_group_id INTO group_id
    FROM public.branch b JOIN public.company c ON c.id = b.company_id
   WHERE b.id = terminal_row.branch_id;

  FOR item IN SELECT value FROM pg_catalog.jsonb_array_elements(p_items) LOOP
    -- Item fora do formato recusa o pacote inteiro: é defeito do PDV, não conflito de dados.
    IF pg_catalog.jsonb_typeof(item) IS DISTINCT FROM 'object'
       OR (item ->> 'id') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
       OR (item ->> 'sequence') !~ '^[1-9][0-9]{0,17}$'
       OR (item ->> 'kind') !~ '^[a-z_]{1,40}$'
       OR pg_catalog.jsonb_typeof(item -> 'payload') IS DISTINCT FROM 'object' THEN
      RAISE EXCEPTION 'Os dados da sincronização são inválidos.'
        USING ERRCODE = 'FA956', DETAIL = 'Item da subida fora do formato.';
    END IF;
    item_id := (item ->> 'id')::uuid;
    item_sequence := (item ->> 'sequence')::bigint;
    IF item_sequence <= last_sequence THEN
      RAISE EXCEPTION 'Os dados da sincronização são inválidos.'
        USING ERRCODE = 'FA956', DETAIL = 'Itens da subida fora de ordem.';
    END IF;
    last_sequence := item_sequence;

    SELECT r.* INTO existing FROM public.sync_receipt r WHERE r.id = item_id;
    IF FOUND THEN
      IF existing.terminal_id <> terminal_row.id THEN
        RAISE EXCEPTION 'Os dados da sincronização são inválidos.'
          USING ERRCODE = 'FA956', DETAIL = 'Item já recebido de outro terminal.';
      END IF;
      results := results || pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
        'id', item_id, 'status', 'duplicate', 'result', existing.status,
        'code', (SELECT c.error_code FROM public.sync_conflict c WHERE c.receipt_id = item_id AND c.deleted_at IS NULL)
      ));
      CONTINUE;
    END IF;

    outcome := 'applied';
    failure_code := NULL;
    failure_message := NULL;
    BEGIN
      CASE item ->> 'kind'
        WHEN 'log' THEN
          PERFORM app.sync_apply_log(terminal_row, group_id, item_id, item -> 'payload');
        ELSE
          RAISE EXCEPTION 'O terminal enviou um tipo de registro desconhecido.'
            USING ERRCODE = 'FA959', DETAIL = pg_catalog.format('Tipo %s.', item ->> 'kind');
      END CASE;
    EXCEPTION WHEN OTHERS THEN
      -- Erro do catálogo é decisão do banco: vira conflito. Outro erro é falha e recusa o pacote.
      IF SQLSTATE !~ '^FA[0-9]{3}$' THEN
        RAISE;
      END IF;
      outcome := 'conflict';
      failure_code := SQLSTATE;
      failure_message := SQLERRM;
    END;

    INSERT INTO public.sync_receipt (id, economic_group_id, branch_id, terminal_id, kind, sequence, status)
    VALUES (item_id, group_id, terminal_row.branch_id, terminal_row.id, item ->> 'kind', item_sequence, outcome);
    IF outcome = 'conflict' THEN
      INSERT INTO public.sync_conflict (
        economic_group_id, branch_id, terminal_id, receipt_id, kind, error_code, detail, payload
      ) VALUES (
        group_id, terminal_row.branch_id, terminal_row.id, item_id, item ->> 'kind', failure_code, failure_message,
        item -> 'payload'
      );
    END IF;
    results := results || pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
      'id', item_id, 'status', outcome, 'code', failure_code
    ));
  END LOOP;

  PERFORM app.record_terminal_sync('push', NULL, false);
  RETURN pg_catalog.jsonb_build_object('results', results);
END;
$$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  app.pdv_search_customers(text),
  app.pdv_get_customer(uuid),
  app.terminal_sync_lag(uuid)
TO farmaerp_app;
