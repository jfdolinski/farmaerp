-- Up Migration

-- Descida para o PDV. Os triggers anotam, em sync_change, o que mudou e para qual escopo vale
-- (Catálogo, grupo inteiro ou uma filial). O terminal pede as mudanças desde o cursor dele, e o
-- banco devolve o estado pronto de cada item: preço efetivo da filial, tributação, estoque, etc.
--
-- O cursor é o xmin do snapshot (pg_snapshot_xmin): toda transação com número menor já terminou,
-- então nada que ficou abaixo do cursor aparece depois. Assim uma gravação demorada nunca fica
-- para trás do ponto que o PDV já leu. Cada item tem uma linha só: a próxima mudança atualiza o
-- número da transação, e a tabela cresce com o número de itens, não com o de alterações.

CREATE TABLE sync_change (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  -- Vazio: Catálogo, que vale para todos os grupos.
  economic_group_id uuid REFERENCES economic_group (id),
  -- Vazio: vale para todas as filiais do grupo.
  branch_id uuid REFERENCES branch (id),
  entity text NOT NULL CONSTRAINT sync_change_entity_check CHECK (entity IN (
    'product', 'catalog_product', 'manufacturer', 'stock', 'user', 'role', 'branch', 'fiscal'
  )),
  entity_id uuid NOT NULL,
  xid xid8 NOT NULL DEFAULT pg_current_xact_id(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid,
  CONSTRAINT sync_change_scope_check CHECK (
    (economic_group_id IS NULL) = (entity IN ('catalog_product', 'manufacturer'))
    AND (branch_id IS NULL OR economic_group_id IS NOT NULL)
  )
);
CREATE UNIQUE INDEX sync_change_key
  ON sync_change (entity, entity_id, COALESCE(branch_id, '00000000-0000-0000-0000-000000000000'::uuid))
  WHERE deleted_at IS NULL;
CREATE INDEX sync_change_xid_idx ON sync_change (xid);
CREATE INDEX sync_change_economic_group_id_idx ON sync_change (economic_group_id);
CREATE INDEX sync_change_branch_id_idx ON sync_change (branch_id);

CALL app.apply_table_standard('public.sync_change');

-- Ninguém lê direto: só as funções do PDV.
CREATE POLICY sync_change_select ON sync_change FOR SELECT TO farmaerp_app USING (false);
CREATE VIEW v_sync_change WITH (security_invoker = true) AS
  SELECT * FROM sync_change WHERE deleted_at IS NULL;

-- Formato do que desce. Mudou o formato (campo novo, item novo), o PDV refaz a carga inteira.
CREATE FUNCTION app.pdv_sync_format() RETURNS integer
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$ SELECT 1 $$;

-- Anota a mudança. Várias mudanças do mesmo item na mesma transação gravam uma vez só.
CREATE FUNCTION app.mark_sync_change(p_entity text, p_entity_id uuid, p_group_id uuid, p_branch_id uuid)
RETURNS void
LANGUAGE sql SECURITY DEFINER
SET search_path = ''
AS $$
  INSERT INTO public.sync_change (economic_group_id, branch_id, entity, entity_id)
  VALUES (p_group_id, p_branch_id, p_entity, p_entity_id)
  ON CONFLICT (entity, entity_id, COALESCE(branch_id, '00000000-0000-0000-0000-000000000000'::uuid))
    WHERE deleted_at IS NULL
  DO UPDATE SET xid = pg_catalog.pg_current_xact_id()
   WHERE public.sync_change.xid <> pg_catalog.pg_current_xact_id()
$$;

CREATE FUNCTION app.track_sync_change() RETURNS trigger
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
    WHEN 'terminal_fiscal_series' THEN
      PERFORM app.mark_sync_change('fiscal', NEW.branch_id, NEW.economic_group_id, NEW.branch_id);
  END CASE;
  RETURN NULL;
END;
$$;

DO $$
DECLARE
  table_name text;
BEGIN
  FOREACH table_name IN ARRAY ARRAY[
    'product', 'product_branch_status', 'product_price', 'product_barcode', 'catalog_product',
    'catalog_product_tax', 'catalog_manufacturer', 'stock_balance', 'product_batch', 'user_account',
    'user_branch', 'user_role', 'role', 'role_permission', 'role_limit', 'branch', 'company',
    'terminal_fiscal_series'
  ] LOOP
    EXECUTE pg_catalog.format(
      'CREATE TRIGGER track_sync_change AFTER INSERT OR UPDATE ON public.%I
         FOR EACH ROW EXECUTE FUNCTION app.track_sync_change()',
      table_name
    );
  END LOOP;
END;
$$;

-- O produto desce para a filial quando está ativo ou por encomenda; bloqueado, só enquanto houver
-- saldo; inativo não desce.
CREATE FUNCTION app.pdv_product_in_scope(p_product_id uuid, p_branch_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE((
    SELECT s.status IN ('active', 'on_order')
           OR (s.status = 'blocked' AND app.branch_stock_quantity(p.id, p_branch_id) > 0)
      FROM public.product p
      JOIN public.branch b ON b.id = p_branch_id AND b.deleted_at IS NULL
      JOIN public.company c ON c.id = b.company_id AND c.economic_group_id = p.economic_group_id
      JOIN public.product_branch_status s ON s.product_id = p.id AND s.branch_id = b.id AND s.deleted_at IS NULL
     WHERE p.id = p_product_id AND p.deleted_at IS NULL
  ), false)
$$;

-- Estado pronto do produto na filial. Vazio quando ele não desce (o PDV retira da cópia local).
-- A tributação traz a regra em vigor e as que entram em vigor depois: o PDV escolhe pela data,
-- mesmo sem internet na virada.
CREATE FUNCTION app.pdv_product_data(p_branch_id uuid, p_ids uuid[])
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

-- Cópia do estoque da filial, por lote. Desce junto com o produto.
CREATE FUNCTION app.pdv_stock_data(p_branch_id uuid, p_ids uuid[])
RETURNS TABLE (id uuid, data jsonb)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT ids.id,
         CASE WHEN app.pdv_product_in_scope(ids.id, p_branch_id) THEN pg_catalog.jsonb_build_object(
           'quantity', app.branch_stock_quantity(ids.id, p_branch_id),
           'batches', COALESCE((
             SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
                      'id', pb.id, 'number', pb.batch_number, 'expires_on', pb.expires_on,
                      'quantity', sb.quantity) ORDER BY pb.expires_on, pb.batch_number)
               FROM public.stock_balance sb
               JOIN public.product_batch pb ON pb.id = sb.batch_id AND pb.deleted_at IS NULL
              WHERE sb.product_id = ids.id AND sb.branch_id = p_branch_id AND sb.deleted_at IS NULL
                AND sb.quantity <> 0
           ), '[]'::jsonb)
         ) END
    FROM pg_catalog.unnest(p_ids) AS ids(id)
$$;

-- Usuário com algum perfil na filial, com permissões e limites prontos. Nenhuma senha desce.
CREATE FUNCTION app.pdv_user_data(p_branch_id uuid, p_ids uuid[])
RETURNS TABLE (id uuid, data jsonb)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT ids.id,
         CASE WHEN EXISTS (SELECT 1 FROM app.user_roles_at(ids.id, p_branch_id)) THEN pg_catalog.jsonb_build_object(
           'code', u.code,
           'name', u.name,
           'is_admin', EXISTS (
             SELECT 1 FROM app.user_roles_at(ids.id, p_branch_id) r WHERE r.system_key = 'administrator'
           ),
           'roles', (
             SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('id', r.id, 'name', r.name) ORDER BY r.name, r.id)
               FROM app.user_roles_at(ids.id, p_branch_id) r
           ),
           'permissions', COALESCE((
             SELECT pg_catalog.jsonb_agg(p.code ORDER BY p.code)
               FROM public.permission p
              WHERE p.deleted_at IS NULL AND app.user_has_permission(ids.id, p.code, p_branch_id)
           ), '[]'::jsonb),
           'limits', COALESCE((
             SELECT pg_catalog.jsonb_object_agg(t.code, app.user_limit(ids.id, p_branch_id, t.code))
               FROM public.limit_type t
              WHERE t.deleted_at IS NULL
           ), '{}'::jsonb)
         ) END
    FROM pg_catalog.unnest(p_ids) AS ids(id)
    LEFT JOIN public.user_account u ON u.id = ids.id
$$;

-- Dados fiscais da filial e as séries deste terminal. Certificado e CSC não descem.
CREATE FUNCTION app.pdv_fiscal_data(p_branch_id uuid, p_terminal_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT pg_catalog.jsonb_build_object(
           'branch', pg_catalog.jsonb_build_object(
             'id', b.id, 'name', b.name, 'cnpj', b.cnpj, 'state_registration', b.state_registration,
             'state', b.state, 'pmc_region', b.pmc_region, 'postal_code', b.postal_code, 'street', b.street,
             'street_number', b.street_number, 'complement', b.complement, 'district', b.district,
             'city', b.city, 'city_code', b.city_code, 'phone', b.phone
           ),
           'company', pg_catalog.jsonb_build_object(
             'id', c.id, 'legal_name', c.legal_name, 'trade_name', c.trade_name, 'tax_regime', c.tax_regime
           ),
           'series', COALESCE((
             SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
                      'id', s.id, 'model', s.model, 'series', s.series, 'initial_number', s.initial_number,
                      'last_used_number', s.last_used_number) ORDER BY s.model)
               FROM public.terminal_fiscal_series s
              WHERE s.terminal_id = p_terminal_id AND s.deleted_at IS NULL
           ), '[]'::jsonb)
         )
    FROM public.branch b
    JOIN public.company c ON c.id = b.company_id
   WHERE b.id = p_branch_id AND b.deleted_at IS NULL
$$;

-- O que precisa descer para a filial: tudo (carga inicial, sem p_since) ou o que mudou entre
-- p_since e p_until. Ordem de entrega: 1 fiscal, 2 usuários, 3 produtos, 4 estoque.
CREATE FUNCTION app.pdv_targets(p_branch_id uuid, p_group_id uuid, p_since xid8, p_until xid8)
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
  )
  SELECT 1, p_branch_id
   WHERE p_since IS NULL OR EXISTS (SELECT 1 FROM changed WHERE entity IN ('fiscal', 'branch'))
  UNION ALL SELECT 2, users.id FROM users
  UNION ALL SELECT 3, products.id FROM products
  UNION ALL SELECT 4, stock.id FROM stock
$$;

-- Descida para o terminal autenticado na transação.
--   p_cursor: o until da última descida concluída; vazio faz a carga inteira.
--   p_until e p_after: vêm da resposta anterior, para buscar o próximo pacote da mesma janela.
-- Devolve { format, until, total, items: [{ type, id, data }], next }. data vazio: retirar da cópia
-- local. total vem só no primeiro pacote da janela: é o que permite mostrar o progresso da carga.
-- Com next vazio, a janela terminou e o PDV grava until como o novo cursor.
CREATE FUNCTION app.pdv_pull(p_cursor text, p_until text, p_after text, p_limit integer)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
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
     OR (p_after IS NOT NULL AND (p_until IS NULL OR p_after !~ '^[1-4]:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'))
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
      FROM (SELECT DISTINCT tg.rank, tg.id FROM app.pdv_targets(terminal_row.branch_id, group_id, since, until) tg) t;
  END IF;

  SELECT pg_catalog.array_agg(t.rank ORDER BY t.rank, t.id), pg_catalog.array_agg(t.id ORDER BY t.rank, t.id)
    INTO page_rank, page_id
    FROM (
      SELECT DISTINCT tg.rank, tg.id
        FROM app.pdv_targets(terminal_row.branch_id, group_id, since, until) tg
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
    ) page;

  RETURN pg_catalog.jsonb_build_object(
    'format', app.pdv_sync_format(),
    'until', until::text,
    'total', total,
    'items', items,
    'next', next_token
  );
END;
$$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  app.pdv_sync_format(),
  app.pdv_pull(text, text, text, integer)
TO farmaerp_app;
