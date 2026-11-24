-- Up Migration

-- Devolução (Etapa 4, PR E1). Só na loja da compra, vinculada à venda. Gera um documento (D<terminal>-
-- <número>) e o destino do valor: crédito para nova compra, abatimento na fatura do convênio ou
-- dinheiro ao cliente. O dinheiro sai por uma sangria com o documento, que fecha o ciclo. O estoque
-- volta para os lotes da venda. Controlado não volta no caixa (SNGPC, Etapa 8).
-- Quem faz: quem tem "Fazer devolução" (sales.return) ou com a liberação de quem tem. Depois do
-- prazo da filial, sempre com a liberação de outra pessoa que tenha a permissão.

INSERT INTO permission (code, module, name) VALUES
  ('sales.return', 'Vendas', 'Fazer devolução e liberar a devolução de outra pessoa');
INSERT INTO role_permission (role_id, permission_id)
SELECT r.id, p.id
  FROM role r JOIN permission p ON p.code = 'sales.return'
 WHERE r.deleted_at IS NULL AND r.system_key IS NULL AND r.name = 'Gerente'
   AND NOT EXISTS (
     SELECT 1 FROM role_permission rp WHERE rp.role_id = r.id AND rp.permission_id = p.id AND rp.deleted_at IS NULL
   );

ALTER TABLE branch ADD COLUMN return_days smallint NOT NULL DEFAULT 7
  CONSTRAINT branch_return_days_check CHECK (return_days BETWEEN 0 AND 365);
CREATE OR REPLACE VIEW v_branch WITH (security_invoker = true) AS
  SELECT * FROM branch WHERE deleted_at IS NULL;

CREATE FUNCTION app.set_branch_return_days(p_branch_id uuid, p_days integer) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM app.require_branch_permission('structure.manage', p_branch_id);
  IF p_days IS NULL OR p_days NOT BETWEEN 0 AND 365 THEN
    RAISE EXCEPTION 'O prazo de devolução precisa ficar entre 0 e 365 dias.'
      USING ERRCODE = 'FA899', DETAIL = pg_catalog.format('%s dias.', p_days);
  END IF;
  UPDATE public.branch SET return_days = p_days WHERE id = p_branch_id;
END;
$$;

CREATE TABLE sale_return (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  branch_id uuid NOT NULL REFERENCES branch (id),
  terminal_id uuid NOT NULL REFERENCES terminal (id),
  cash_session_id uuid NOT NULL REFERENCES cash_session (id),
  sale_id uuid NOT NULL REFERENCES sale (id),
  number bigint NOT NULL CONSTRAINT sale_return_number_check CHECK (number > 0),
  code text NOT NULL CONSTRAINT sale_return_code_check CHECK (code ~ '^D[0-9]+-[0-9]{6,}$'),
  operator_id uuid NOT NULL REFERENCES user_account (id),
  authorized_by uuid REFERENCES user_account (id),
  customer_id uuid REFERENCES customer (id),
  reason text NOT NULL CONSTRAINT sale_return_reason_check CHECK (length(btrim(reason)) BETWEEN 1 AND 500),
  -- credit: crédito para nova compra; agreement: abatimento na fatura do convênio; cash: dinheiro ao cliente.
  destination text NOT NULL CONSTRAINT sale_return_destination_check CHECK (destination IN ('credit', 'agreement', 'cash')),
  returned_at timestamptz NOT NULL,
  total numeric(12, 2) NOT NULL CONSTRAINT sale_return_total_check CHECK (total > 0),
  -- Sangria que pagou a devolução em dinheiro (fecha o ciclo).
  paid_movement_id uuid REFERENCES cash_movement (id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid,
  CONSTRAINT sale_return_paid_check CHECK (paid_movement_id IS NULL OR destination = 'cash'),
  CONSTRAINT sale_return_authorized_check CHECK (authorized_by IS NULL OR authorized_by <> operator_id)
);
CREATE UNIQUE INDEX sale_return_terminal_number_key ON sale_return (terminal_id, number) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX sale_return_paid_movement_key ON sale_return (paid_movement_id) WHERE paid_movement_id IS NOT NULL;
CREATE INDEX sale_return_branch_idx ON sale_return (branch_id, returned_at DESC);
CREATE INDEX sale_return_code_idx ON sale_return (economic_group_id, code);
CREATE INDEX sale_return_economic_group_id_idx ON sale_return (economic_group_id);
CREATE INDEX sale_return_terminal_idx ON sale_return (terminal_id);
CREATE INDEX sale_return_session_idx ON sale_return (cash_session_id);
CREATE INDEX sale_return_sale_idx ON sale_return (sale_id);
CREATE INDEX sale_return_operator_idx ON sale_return (operator_id);
CREATE INDEX sale_return_authorized_by_idx ON sale_return (authorized_by);
CREATE INDEX sale_return_customer_idx ON sale_return (customer_id);
CALL app.apply_table_standard('public.sale_return');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON sale_return
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'branch_id', 'terminal_id', 'cash_session_id', 'sale_id', 'number', 'code', 'operator_id',
    'authorized_by', 'customer_id', 'reason', 'destination', 'returned_at', 'total'
  );

CREATE TABLE sale_return_item (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  sale_return_id uuid NOT NULL REFERENCES sale_return (id),
  sale_item_id uuid NOT NULL REFERENCES sale_item (id),
  quantity numeric(12, 3) NOT NULL CONSTRAINT sale_return_item_quantity_check CHECK (quantity > 0),
  amount numeric(12, 2) NOT NULL CONSTRAINT sale_return_item_amount_check CHECK (amount >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE UNIQUE INDEX sale_return_item_key ON sale_return_item (sale_return_id, sale_item_id) WHERE deleted_at IS NULL;
CREATE INDEX sale_return_item_sale_item_idx ON sale_return_item (sale_item_id);
CREATE INDEX sale_return_item_economic_group_id_idx ON sale_return_item (economic_group_id);
CALL app.apply_table_standard('public.sale_return_item');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON sale_return_item
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'sale_return_id', 'sale_item_id', 'quantity', 'amount'
  );

-- Movimentação de estoque da devolução, ligada ao item devolvido.
ALTER TABLE stock_movement
  ADD COLUMN sale_return_item_id uuid REFERENCES sale_return_item (id),
  ADD CONSTRAINT stock_movement_sale_return_item_check CHECK (sale_return_item_id IS NULL OR movement_type = 'return');
CREATE INDEX stock_movement_sale_return_item_idx ON stock_movement (sale_return_item_id);
CREATE OR REPLACE VIEW v_stock_movement WITH (security_invoker = true) AS
  SELECT * FROM stock_movement WHERE deleted_at IS NULL;

-- Sangria de devolução: aponta o documento que ela paga.
ALTER TABLE cash_movement ADD COLUMN return_id uuid REFERENCES sale_return (id);
CREATE INDEX cash_movement_return_idx ON cash_movement (return_id);
DROP TRIGGER block_immutable_columns ON cash_movement;
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON cash_movement
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'branch_id', 'cash_session_id', 'kind', 'amount', 'reason', 'operator_id', 'released_by', 'moved_at',
    'return_id'
  );
CREATE OR REPLACE VIEW v_cash_movement WITH (security_invoker = true) AS
  SELECT * FROM cash_movement WHERE deleted_at IS NULL;
ALTER TABLE cash_alert DROP CONSTRAINT cash_alert_kind_check;
ALTER TABLE cash_alert ADD CONSTRAINT cash_alert_kind_check CHECK (kind IN ('withdrawal_above_limit', 'closing_difference', 'return_payout'));
ALTER TABLE sale_alert DROP CONSTRAINT sale_alert_kind_check;
ALTER TABLE sale_alert ADD CONSTRAINT sale_alert_kind_check CHECK (kind IN (
  'price_divergence', 'discount_above_rule', 'discount_above_limit', 'operator_permission',
  'negative_stock', 'product_status', 'agreement_link', 'offline_zero_stock',
  'controlled_missing', 'controlled_release', 'controlled_pending', 'prescription_expired', 'prescription_type',
  'seller_permission', 'quote_status', 'return_permission'
));

-- Fora do prazo? Conta em dias da loja, da data da venda até a data da devolução.
CREATE FUNCTION app.return_is_late(p_sold_at timestamptz, p_returned_at timestamptz, p_days integer) RETURNS boolean
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$
  SELECT (p_returned_at AT TIME ZONE 'America/Sao_Paulo')::date - (p_sold_at AT TIME ZONE 'America/Sao_Paulo')::date > p_days
$$;

-- Devolução vinda do PDV. Fora do formato ou com contas que não fecham: conflito (FA894). A venda
-- precisa ser desta loja (FA891); não devolve mais do que sobrou do item (FA892) nem controlado
-- (FA893); convênio só se a venda teve convênio (FA897). Sem permissão, a devolução vale e fica o
-- alerta na venda.
CREATE FUNCTION app.sync_apply_return(p_terminal public.terminal, p_group_id uuid, p_payload jsonb)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  uuid_v7 constant text := '^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$';
  uuid_any constant text := '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
  money constant text := '^\d{1,10}(\.\d{1,2})?$';
  refund_id uuid;
  refund_at timestamptz;
  sale_row public.sale;
  operator uuid;
  authorizer uuid;
  item jsonb;
  item_row public.sale_item;
  done_quantity numeric;
  done_amount numeric;
  expected numeric;
  sum_items numeric := 0;
  seen uuid[] := '{}';
  refund_item uuid;
  terminal_number smallint;
  late boolean;
  allowed boolean;
  remaining numeric;
  batch_row record;
  take numeric;
BEGIN
  IF (p_payload ->> 'id') !~ uuid_v7
     OR (p_payload ->> 'number') !~ '^[1-9][0-9]{0,8}$'
     OR (p_payload ->> 'cash_session_id') IS NULL OR (p_payload ->> 'cash_session_id') !~ uuid_any
     OR (p_payload ->> 'sale_id') IS NULL OR (p_payload ->> 'sale_id') !~ uuid_any
     OR (p_payload ->> 'operator_id') IS NULL OR (p_payload ->> 'operator_id') !~ uuid_any
     OR (p_payload ->> 'authorized_by') !~ uuid_any
     OR pg_catalog.length(pg_catalog.btrim(COALESCE(p_payload ->> 'reason', ''))) NOT BETWEEN 1 AND 500
     OR (p_payload ->> 'destination') IS NULL OR (p_payload ->> 'destination') NOT IN ('credit', 'agreement', 'cash')
     OR (p_payload ->> 'returned_at') IS NULL
     OR (p_payload ->> 'returned_at') !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$'
     OR pg_catalog.jsonb_typeof(p_payload -> 'items') IS DISTINCT FROM 'array'
     OR pg_catalog.jsonb_array_length(p_payload -> 'items') NOT BETWEEN 1 AND 999
     OR (p_payload ->> 'total') !~ money THEN
    RAISE EXCEPTION 'A devolução enviada pelo terminal está inconsistente.'
      USING ERRCODE = 'FA894', DETAIL = 'Devolução fora do formato.';
  END IF;
  refund_id := (p_payload ->> 'id')::uuid;
  operator := (p_payload ->> 'operator_id')::uuid;
  authorizer := (p_payload ->> 'authorized_by')::uuid;
  BEGIN
    refund_at := (p_payload ->> 'returned_at')::timestamptz;
  EXCEPTION WHEN datetime_field_overflow OR invalid_datetime_format THEN
    RAISE EXCEPTION 'A devolução enviada pelo terminal está inconsistente.'
      USING ERRCODE = 'FA894', DETAIL = 'Data da devolução impossível.';
  END;
  IF EXISTS (SELECT 1 FROM public.sale_return r WHERE r.id = refund_id)
     OR EXISTS (
       SELECT 1 FROM public.sale_return r
        WHERE r.terminal_id = p_terminal.id AND r.number = (p_payload ->> 'number')::bigint AND r.deleted_at IS NULL
     ) THEN
    RAISE EXCEPTION 'A devolução enviada pelo terminal está inconsistente.'
      USING ERRCODE = 'FA894', DETAIL = pg_catalog.format('Devolução %s repetida.', refund_id);
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.cash_session cs
     WHERE cs.id = (p_payload ->> 'cash_session_id')::uuid AND cs.terminal_id = p_terminal.id AND cs.deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'A devolução enviada pelo terminal está inconsistente.'
      USING ERRCODE = 'FA894', DETAIL = 'Turno de caixa desconhecido neste terminal.';
  END IF;
  SELECT s.* INTO sale_row FROM public.sale s
   WHERE s.id = (p_payload ->> 'sale_id')::uuid AND s.economic_group_id = p_group_id AND s.deleted_at IS NULL;
  IF NOT FOUND
     OR NOT EXISTS (SELECT 1 FROM public.user_account u WHERE u.id = operator AND u.economic_group_id = p_group_id)
     OR (authorizer IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM public.user_account u WHERE u.id = authorizer AND u.economic_group_id = p_group_id)) THEN
    RAISE EXCEPTION 'Um dos itens informados não foi encontrado.'
      USING ERRCODE = 'FA004', DETAIL = 'Venda, operador ou quem autorizou fora do grupo.';
  END IF;
  IF sale_row.branch_id <> p_terminal.branch_id THEN
    RAISE EXCEPTION 'Venda não encontrada nesta loja.'
      USING ERRCODE = 'FA891', DETAIL = pg_catalog.format('Venda %s de outra filial.', sale_row.code);
  END IF;
  IF p_payload ->> 'destination' = 'agreement' AND NOT EXISTS (
    SELECT 1 FROM public.sale_payment p WHERE p.sale_id = sale_row.id AND p.method = 'agreement' AND p.deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Só a venda feita no convênio pode ter o valor abatido na fatura.'
      USING ERRCODE = 'FA897', DETAIL = sale_row.code;
  END IF;

  -- Itens: do item da venda, sem controlado, até o que sobrou; o valor é a parte do total do item
  -- (na última devolução do item, o que falta, para fechar no centavo).
  FOR item IN SELECT value FROM pg_catalog.jsonb_array_elements(p_payload -> 'items') LOOP
    IF pg_catalog.jsonb_typeof(item) IS DISTINCT FROM 'object'
       OR (item ->> 'id') !~ uuid_v7 OR (item ->> 'sale_item_id') IS NULL OR (item ->> 'sale_item_id') !~ uuid_any
       OR (item ->> 'quantity') !~ '^\d{1,9}(\.\d{1,3})?$' OR (item ->> 'quantity')::numeric <= 0
       OR (item ->> 'amount') !~ money THEN
      RAISE EXCEPTION 'A devolução enviada pelo terminal está inconsistente.'
        USING ERRCODE = 'FA894', DETAIL = 'Item da devolução fora do formato.';
    END IF;
    SELECT i.* INTO item_row FROM public.sale_item i
     WHERE i.id = (item ->> 'sale_item_id')::uuid AND i.sale_id = sale_row.id AND i.deleted_at IS NULL;
    IF NOT FOUND OR item_row.id = ANY (seen) THEN
      RAISE EXCEPTION 'A devolução enviada pelo terminal está inconsistente.'
        USING ERRCODE = 'FA894', DETAIL = 'Item que não é da venda, ou repetido.';
    END IF;
    seen := seen || item_row.id;
    IF EXISTS (
      SELECT 1 FROM public.product p JOIN public.catalog_product cp ON cp.id = p.catalog_product_id
       WHERE p.id = item_row.product_id AND cp.controlled_class IS NOT NULL
    ) THEN
      RAISE EXCEPTION 'Controlado não é devolvido no caixa.'
        USING ERRCODE = 'FA893', DETAIL = pg_catalog.format('Item %s.', item_row.line);
    END IF;
    SELECT COALESCE(pg_catalog.sum(ri.quantity), 0), COALESCE(pg_catalog.sum(ri.amount), 0)
      INTO done_quantity, done_amount
      FROM public.sale_return_item ri WHERE ri.sale_item_id = item_row.id AND ri.deleted_at IS NULL;
    IF (item ->> 'quantity')::numeric > item_row.quantity - done_quantity THEN
      RAISE EXCEPTION 'A quantidade passa do que ainda pode ser devolvido.'
        USING ERRCODE = 'FA892', DETAIL = pg_catalog.format('Item %s: %s de %s.', item_row.line, item ->> 'quantity', item_row.quantity - done_quantity);
    END IF;
    expected := CASE
      WHEN (item ->> 'quantity')::numeric = item_row.quantity - done_quantity THEN item_row.total - done_amount
      ELSE round(item_row.total * (item ->> 'quantity')::numeric / item_row.quantity, 2)
    END;
    IF (item ->> 'amount')::numeric <> expected THEN
      RAISE EXCEPTION 'A devolução enviada pelo terminal está inconsistente.'
        USING ERRCODE = 'FA894', DETAIL = pg_catalog.format('Valor do item %s: %s, esperado %s.', item_row.line, item ->> 'amount', expected);
    END IF;
    sum_items := sum_items + expected;
  END LOOP;
  IF sum_items <> (p_payload ->> 'total')::numeric OR sum_items <= 0 THEN
    RAISE EXCEPTION 'A devolução enviada pelo terminal está inconsistente.'
      USING ERRCODE = 'FA894', DETAIL = 'Total da devolução não fecha.';
  END IF;

  SELECT t.number INTO terminal_number FROM public.terminal t WHERE t.id = p_terminal.id;
  BEGIN
    INSERT INTO public.sale_return (
      id, economic_group_id, branch_id, terminal_id, cash_session_id, sale_id, number, code, operator_id, authorized_by,
      customer_id, reason, destination, returned_at, total
    ) VALUES (
      refund_id, p_group_id, p_terminal.branch_id, p_terminal.id, (p_payload ->> 'cash_session_id')::uuid, sale_row.id,
      (p_payload ->> 'number')::bigint, 'D' || terminal_number || '-' || pg_catalog.lpad(p_payload ->> 'number', 6, '0'),
      operator, authorizer, sale_row.customer_id, pg_catalog.btrim(p_payload ->> 'reason'), p_payload ->> 'destination',
      refund_at, sum_items
    );
  EXCEPTION WHEN check_violation THEN
    RAISE EXCEPTION 'A devolução enviada pelo terminal está inconsistente.'
      USING ERRCODE = 'FA894', DETAIL = SQLERRM;
  END;

  -- Estoque: volta para os lotes que saíram na venda, descontado o que já voltou em cada um.
  FOR item IN SELECT value FROM pg_catalog.jsonb_array_elements(p_payload -> 'items') LOOP
    refund_item := (item ->> 'id')::uuid;
    SELECT i.* INTO item_row FROM public.sale_item i WHERE i.id = (item ->> 'sale_item_id')::uuid;
    INSERT INTO public.sale_return_item (id, economic_group_id, sale_return_id, sale_item_id, quantity, amount)
    VALUES (refund_item, p_group_id, refund_id, item_row.id, (item ->> 'quantity')::numeric, (item ->> 'amount')::numeric);
    remaining := (item ->> 'quantity')::numeric;
    FOR batch_row IN
      SELECT m.batch_id,
             -pg_catalog.sum(m.quantity) - COALESCE((
               SELECT pg_catalog.sum(r.quantity) FROM public.stock_movement r
                 JOIN public.sale_return_item ri ON ri.id = r.sale_return_item_id
                WHERE ri.sale_item_id = item_row.id AND r.batch_id IS NOT DISTINCT FROM m.batch_id AND r.deleted_at IS NULL
                  AND ri.id <> refund_item
             ), 0) AS available
        FROM public.stock_movement m
       WHERE m.sale_item_id = item_row.id AND m.movement_type = 'sale' AND m.deleted_at IS NULL
       GROUP BY m.batch_id
       ORDER BY m.batch_id NULLS LAST
    LOOP
      EXIT WHEN remaining <= 0;
      take := LEAST(remaining, batch_row.available);
      CONTINUE WHEN take <= 0;
      INSERT INTO public.stock_movement (
        economic_group_id, branch_id, product_id, batch_id, movement_type, quantity, occurred_at, sale_return_item_id
      ) VALUES (p_group_id, p_terminal.branch_id, item_row.product_id, batch_row.batch_id, 'return', take, refund_at, refund_item);
      remaining := remaining - take;
    END LOOP;
    IF remaining > 0 THEN
      INSERT INTO public.stock_movement (
        economic_group_id, branch_id, product_id, movement_type, quantity, occurred_at, sale_return_item_id
      ) VALUES (p_group_id, p_terminal.branch_id, item_row.product_id, 'return', remaining, refund_at, refund_item);
    END IF;
  END LOOP;

  -- Quem pode: no prazo, o operador com a permissão ou a liberação de quem tem; fora do prazo,
  -- sempre a liberação de outra pessoa que tenha a permissão. Sem isso, vale e fica o alerta.
  late := app.return_is_late(sale_row.sold_at, refund_at,
    (SELECT b.return_days FROM public.branch b WHERE b.id = p_terminal.branch_id));
  allowed := (authorizer IS NOT NULL AND app.user_has_permission(authorizer, 'sales.return', p_terminal.branch_id))
             OR (NOT late AND app.user_has_permission(operator, 'sales.return', p_terminal.branch_id));
  IF NOT allowed THEN
    INSERT INTO public.sale_alert (economic_group_id, branch_id, sale_id, kind, detail)
    VALUES (p_group_id, p_terminal.branch_id, sale_row.id, 'return_permission', pg_catalog.jsonb_build_object(
      'return_code', 'D' || terminal_number || '-' || pg_catalog.lpad(p_payload ->> 'number', 6, '0'),
      'late', late, 'operator_id', operator, 'authorized_by', authorizer
    ));
  END IF;
END;
$$;

-- Venda para devolver, pelo código do comprovante (só desta loja): itens com o que ainda pode voltar.
CREATE FUNCTION app.pdv_sale_for_return(p_code text) RETURNS jsonb
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

-- Documento de devolução para a sangria: só desta loja, em dinheiro e ainda não pago.
CREATE FUNCTION app.pdv_return(p_code text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  terminal_row public.terminal := app.require_active_terminal();
  found_return public.sale_return;
BEGIN
  SELECT r.* INTO found_return FROM public.sale_return r
   WHERE r.branch_id = terminal_row.branch_id AND r.code = pg_catalog.upper(pg_catalog.btrim(COALESCE(p_code, ''))) AND r.deleted_at IS NULL;
  IF NOT FOUND OR found_return.destination <> 'cash' OR found_return.paid_movement_id IS NOT NULL THEN
    RAISE EXCEPTION 'O documento de devolução não está disponível para pagar em dinheiro.'
      USING ERRCODE = 'FA896', DETAIL = pg_catalog.format('Código %s.', p_code);
  END IF;
  RETURN pg_catalog.jsonb_build_object(
    'id', found_return.id, 'code', found_return.code, 'total', found_return.total,
    'sale_code', (SELECT s.code FROM public.sale s WHERE s.id = found_return.sale_id)
  );
END;
$$;

-- Devoluções para a retaguarda. Até 500, mais recentes primeiro.
CREATE FUNCTION app.list_returns(p_branch_id uuid DEFAULT NULL, p_from date DEFAULT NULL, p_to date DEFAULT NULL)
RETURNS TABLE (
  id uuid, code text, branch_name text, terminal_name text, returned_at timestamptz, sale_id uuid, sale_code text,
  operator_name text, authorized_by_name text, reason text, destination text, total numeric, paid boolean,
  item_count integer, alert boolean
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT r.id, r.code, b.name, t.name, r.returned_at, s.id, s.code, uo.name, ua.name, r.reason, r.destination, r.total,
         r.paid_movement_id IS NOT NULL,
         (SELECT pg_catalog.count(*)::integer FROM public.sale_return_item i WHERE i.sale_return_id = r.id AND i.deleted_at IS NULL),
         EXISTS (
           SELECT 1 FROM public.sale_alert a
            WHERE a.sale_id = r.sale_id AND a.kind = 'return_permission' AND a.detail ->> 'return_code' = r.code AND a.deleted_at IS NULL
         )
    FROM public.sale_return r
    JOIN public.branch b ON b.id = r.branch_id
    JOIN public.terminal t ON t.id = r.terminal_id
    JOIN public.sale s ON s.id = r.sale_id
    JOIN public.user_account uo ON uo.id = r.operator_id
    LEFT JOIN public.user_account ua ON ua.id = r.authorized_by
   WHERE r.deleted_at IS NULL
     AND r.economic_group_id = app.current_user_group()
     AND app.has_permission('sales.view', r.branch_id)
     AND (p_branch_id IS NULL OR r.branch_id = p_branch_id)
     AND (p_from IS NULL OR r.returned_at >= p_from::timestamp AT TIME ZONE 'America/Sao_Paulo')
     AND (p_to IS NULL OR r.returned_at < (p_to + 1)::timestamp AT TIME ZONE 'America/Sao_Paulo')
   ORDER BY r.returned_at DESC, r.id DESC
   LIMIT 500
$$;

CREATE FUNCTION app.return_detail(p_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT pg_catalog.jsonb_build_object(
    'id', r.id, 'code', r.code, 'branch_name', b.name, 'terminal_name', t.name, 'returned_at', r.returned_at,
    'sale_id', s.id, 'sale_code', s.code, 'sold_at', s.sold_at, 'operator_name', uo.name, 'authorized_by_name', ua.name,
    'customer_name', c.name, 'reason', r.reason, 'destination', r.destination, 'total', r.total,
    'paid_at', m.moved_at, 'paid_by_name', um.name,
    'items', (
      SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'line', i.line, 'product_id', i.product_id, 'product_code', p.code, 'product_name', p.display_name,
        'quantity', ri.quantity, 'amount', ri.amount
      ) ORDER BY i.line)
        FROM public.sale_return_item ri
        JOIN public.sale_item i ON i.id = ri.sale_item_id
        JOIN public.product p ON p.id = i.product_id
       WHERE ri.sale_return_id = r.id AND ri.deleted_at IS NULL
    )
  )
    FROM public.sale_return r
    JOIN public.branch b ON b.id = r.branch_id
    JOIN public.terminal t ON t.id = r.terminal_id
    JOIN public.sale s ON s.id = r.sale_id
    JOIN public.user_account uo ON uo.id = r.operator_id
    LEFT JOIN public.user_account ua ON ua.id = r.authorized_by
    LEFT JOIN public.customer c ON c.id = r.customer_id
    LEFT JOIN public.cash_movement m ON m.id = r.paid_movement_id
    LEFT JOIN public.user_account um ON um.id = m.operator_id
   WHERE r.id = p_id AND r.deleted_at IS NULL
     AND r.economic_group_id = app.current_user_group()
     AND app.has_permission('sales.view', r.branch_id)
$$;

CREATE POLICY sale_return_select ON sale_return FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group()) AND app.has_permission('sales.view', branch_id));
CREATE POLICY sale_return_item_select ON sale_return_item FOR SELECT TO farmaerp_app
  USING (EXISTS (SELECT 1 FROM sale_return r WHERE r.id = sale_return_id));
GRANT SELECT ON sale_return, sale_return_item TO farmaerp_app;
CREATE VIEW v_sale_return WITH (security_invoker = true) AS SELECT * FROM sale_return WHERE deleted_at IS NULL;
CREATE VIEW v_sale_return_item WITH (security_invoker = true) AS SELECT * FROM sale_return_item WHERE deleted_at IS NULL;
GRANT SELECT ON v_sale_return, v_sale_return_item TO farmaerp_app;

-- Estoque: a devolução volta para os lotes da venda.
CREATE OR REPLACE FUNCTION app.validate_stock_movement() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  original public.stock_movement;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.product p
     WHERE p.id = NEW.product_id AND p.economic_group_id = NEW.economic_group_id AND p.deleted_at IS NULL
  ) OR NOT EXISTS (
    SELECT 1 FROM public.branch b
      JOIN public.company c ON c.id = b.company_id
     WHERE b.id = NEW.branch_id AND b.deleted_at IS NULL AND c.economic_group_id = NEW.economic_group_id
  ) THEN
    RAISE EXCEPTION 'Um dos itens informados não foi encontrado.'
      USING ERRCODE = 'FA004', DETAIL = pg_catalog.format('Produto %s, filial %s.', NEW.product_id, NEW.branch_id);
  END IF;

  IF NEW.batch_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.product_batch b
     WHERE b.id = NEW.batch_id AND b.branch_id = NEW.branch_id
       AND b.product_id = NEW.product_id AND b.deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Lote não encontrado neste produto e filial.'
      USING ERRCODE = 'FA808', DETAIL = pg_catalog.format('product_batch %s.', NEW.batch_id);
  END IF;

  -- Devolução de venda: volta para os lotes que saíram (ou sem lote, se a venda saiu sem).
  IF NEW.movement_type = 'return' AND NEW.sale_return_item_id IS NOT NULL THEN
    RETURN NEW;
  END IF;

  IF NEW.reversal_of IS NOT NULL THEN
    SELECT * INTO original FROM public.stock_movement m WHERE m.id = NEW.reversal_of;
    IF NOT FOUND
       OR original.reversal_of IS NOT NULL
       OR original.branch_id <> NEW.branch_id
       OR original.product_id <> NEW.product_id
       OR original.batch_id IS DISTINCT FROM NEW.batch_id
       OR original.quantity <> -NEW.quantity THEN
      RAISE EXCEPTION 'Esta movimentação não pode ser estornada.'
        USING ERRCODE = 'FA811', DETAIL = pg_catalog.format('Estorno de %s.', NEW.reversal_of);
    END IF;
    -- O estorno devolve exatamente o que a original fez, então não passa pelas regras de lote.
    RETURN NEW;
  END IF;

  IF app.batch_required(NEW.product_id, NEW.branch_id) THEN
    -- Só uma saída sem lote é aceita, para zerar o saldo antigo de um produto que passou a
    -- exigir lote. Sem isso, esse saldo não teria como ser regularizado.
    -- A venda também sai sem lote quando o produto ainda não tem nenhum lote na filial: a venda já
    -- aconteceu, e a regularização fica para a retaguarda.
    IF NEW.batch_id IS NULL AND NOT (
      NEW.movement_type = 'sale' AND NEW.quantity < 0 AND NOT EXISTS (
        SELECT 1 FROM public.product_batch pb
         WHERE pb.branch_id = NEW.branch_id AND pb.product_id = NEW.product_id AND pb.deleted_at IS NULL
      )
    ) AND NOT (
      NEW.quantity < 0 AND EXISTS (
        SELECT 1 FROM public.stock_balance sb
         WHERE sb.branch_id = NEW.branch_id AND sb.product_id = NEW.product_id
           AND sb.batch_id IS NULL AND sb.quantity > 0 AND sb.deleted_at IS NULL
      )
    ) THEN
      RAISE EXCEPTION 'Este produto exige lote nesta filial.'
        USING ERRCODE = 'FA802', DETAIL = pg_catalog.format('Produto %s, filial %s.', NEW.product_id, NEW.branch_id);
    END IF;
  ELSIF NEW.batch_id IS NOT NULL THEN
    RAISE EXCEPTION 'Este produto não controla lote nesta filial.'
      USING ERRCODE = 'FA803', DETAIL = pg_catalog.format('Produto %s, filial %s.', NEW.product_id, NEW.branch_id);
  END IF;
  RETURN NEW;
END;
$$;


-- Sangria: a de devolução paga o documento.
CREATE OR REPLACE FUNCTION app.sync_apply_cash_movement(p_terminal public.terminal, p_group_id uuid, p_payload jsonb)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  uuid_any constant text := '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
  movement_id uuid;
  session_row public.cash_session;
  operator uuid;
  releaser uuid;
  amount numeric;
  operator_limit numeric;
  releaser_limit numeric;
  refund_id uuid;
  refund public.sale_return;
  problem text;
BEGIN
  IF (p_payload ->> 'id') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
     OR (p_payload ->> 'cash_session_id') !~ uuid_any
     OR (p_payload ->> 'operator_id') !~ uuid_any
     OR (p_payload ->> 'released_by' IS NOT NULL AND (p_payload ->> 'released_by') !~ uuid_any)
     OR (p_payload ->> 'return_id' IS NOT NULL AND ((p_payload ->> 'return_id') !~ uuid_any OR p_payload ->> 'kind' <> 'withdrawal'))
     OR (p_payload ->> 'kind') IS NULL OR (p_payload ->> 'kind') NOT IN ('withdrawal', 'supply')
     OR (p_payload ->> 'moved_at') !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$'
     OR pg_catalog.jsonb_typeof(p_payload -> 'amount') IS DISTINCT FROM 'number'
     OR (p_payload ->> 'amount')::numeric NOT BETWEEN 0.01 AND 9999999999.99
     OR (p_payload ->> 'amount')::numeric <> round((p_payload ->> 'amount')::numeric, 2) THEN
    RAISE EXCEPTION 'O movimento ou o fechamento de caixa enviado pelo terminal está inconsistente.'
      USING ERRCODE = 'FA995', DETAIL = 'Movimento de caixa fora do formato.';
  END IF;
  movement_id := (p_payload ->> 'id')::uuid;
  IF EXISTS (SELECT 1 FROM public.cash_movement m WHERE m.id = movement_id) THEN
    RAISE EXCEPTION 'Esta venda ou turno já foi recebido com outro registro.'
      USING ERRCODE = 'FA963', DETAIL = pg_catalog.format('cash_movement %s.', movement_id);
  END IF;
  session_row := app.terminal_open_session(p_terminal, (p_payload ->> 'cash_session_id')::uuid);
  operator := (p_payload ->> 'operator_id')::uuid;
  releaser := (p_payload ->> 'released_by')::uuid;
  IF NOT EXISTS (SELECT 1 FROM public.user_account u WHERE u.id = operator AND u.economic_group_id = p_group_id)
     OR (releaser IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM public.user_account u WHERE u.id = releaser AND u.economic_group_id = p_group_id)) THEN
    RAISE EXCEPTION 'Um dos itens informados não foi encontrado.'
      USING ERRCODE = 'FA004', DETAIL = 'Operador ou quem liberou fora do grupo.';
  END IF;
  amount := (p_payload ->> 'amount')::numeric;
  refund_id := (p_payload ->> 'return_id')::uuid;
  IF refund_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.sale_return r WHERE r.id = refund_id AND r.economic_group_id = p_group_id
  ) THEN
    RAISE EXCEPTION 'Um dos itens informados não foi encontrado.'
      USING ERRCODE = 'FA004', DETAIL = 'Devolução da sangria fora do grupo.';
  END IF;
  BEGIN
    INSERT INTO public.cash_movement (
      id, economic_group_id, branch_id, cash_session_id, kind, amount, reason, operator_id, released_by, moved_at, return_id
    ) VALUES (
      movement_id, p_group_id, session_row.branch_id, session_row.id, p_payload ->> 'kind', amount,
      pg_catalog.btrim(COALESCE(p_payload ->> 'reason', '')), operator, releaser, (p_payload ->> 'moved_at')::timestamptz,
      refund_id
    );
  EXCEPTION WHEN check_violation OR datetime_field_overflow OR invalid_datetime_format THEN
    RAISE EXCEPTION 'O movimento ou o fechamento de caixa enviado pelo terminal está inconsistente.'
      USING ERRCODE = 'FA995', DETAIL = pg_catalog.format('Movimento %s: %s.', movement_id, SQLERRM);
  END;

  -- Devolução em dinheiro: a sangria paga o documento. Se não bater, o dinheiro já saiu: alerta.
  IF refund_id IS NOT NULL THEN
    SELECT r.* INTO refund FROM public.sale_return r WHERE r.id = refund_id FOR UPDATE;
    problem := CASE
      WHEN refund.branch_id <> session_row.branch_id THEN 'other_branch'
      WHEN refund.destination <> 'cash' THEN 'not_cash'
      WHEN refund.paid_movement_id IS NOT NULL THEN 'already_paid'
      WHEN refund.total <> amount THEN 'amount'
    END;
    IF problem IS NULL THEN
      UPDATE public.sale_return SET paid_movement_id = movement_id WHERE id = refund_id;
    ELSE
      INSERT INTO public.cash_alert (economic_group_id, branch_id, cash_session_id, cash_movement_id, kind, detail)
      VALUES (p_group_id, session_row.branch_id, session_row.id, movement_id, 'return_payout',
              pg_catalog.jsonb_build_object('return_code', refund.code, 'problem', problem, 'amount', amount, 'return_total', refund.total));
    END IF;
  END IF;

  IF p_payload ->> 'kind' = 'withdrawal' THEN
    operator_limit := app.user_limit(operator, session_row.branch_id, 'cash_withdrawal');
    IF operator_limit IS NOT NULL AND amount > operator_limit THEN
      releaser_limit := CASE WHEN releaser IS NOT NULL THEN app.user_limit(releaser, session_row.branch_id, 'cash_withdrawal') END;
      IF releaser IS NULL OR (releaser_limit IS NOT NULL AND amount > releaser_limit) THEN
        INSERT INTO public.cash_alert (economic_group_id, branch_id, cash_session_id, cash_movement_id, kind, detail)
        VALUES (p_group_id, session_row.branch_id, session_row.id, movement_id, 'withdrawal_above_limit',
                pg_catalog.jsonb_build_object('amount', amount, 'operator_limit', operator_limit,
                                              'released_by', releaser, 'releaser_limit', releaser_limit));
      ELSE
        INSERT INTO public.supervisor_release (
          economic_group_id, branch_id, action, limit_type_id, requested_by, released_by, value, requester_limit,
          releaser_limit, reason, reference_id
        )
        SELECT p_group_id, session_row.branch_id, 'cash.withdrawal', t.id, operator, releaser, amount, operator_limit,
               releaser_limit, pg_catalog.btrim(p_payload ->> 'reason'), movement_id
          FROM public.limit_type t WHERE t.code = 'cash_withdrawal' AND t.deleted_at IS NULL;
      END IF;
    END IF;
  END IF;
END;
$$;


-- Subida: aceita a devolução.
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
        WHEN 'cash_session_open' THEN
          PERFORM app.sync_apply_cash_open(terminal_row, group_id, item -> 'payload');
        WHEN 'sale' THEN
          PERFORM app.sync_apply_sale(terminal_row, group_id, item -> 'payload');
        WHEN 'sale_return' THEN
          PERFORM app.sync_apply_return(terminal_row, group_id, item -> 'payload');
        WHEN 'quote' THEN
          PERFORM app.sync_apply_quote(terminal_row, group_id, item -> 'payload');
        WHEN 'cash_movement' THEN
          PERFORM app.sync_apply_cash_movement(terminal_row, group_id, item -> 'payload');
        WHEN 'cash_session_close' THEN
          PERFORM app.sync_apply_cash_close(terminal_row, group_id, item -> 'payload');
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


-- Perfis padrão: o Gerente faz devolução.
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
    (p_group_id, 'Farmacêutico', 'Libera a venda de controlados no PDV. O SNGPC chega na Etapa 8.'),
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
     'purchases.post', 'releases.view', 'sync.view', 'sync.resolve', 'sales.sell', 'sales.view', 'sales.zero_stock_release', 'controlled.view', 'sales.quote', 'sales.return'
   );
  INSERT INTO public.role_permission (role_id, permission_id)
  SELECT r.id, p.id
    FROM public.role r
    JOIN public.permission p ON p.code IN ('sales.sell', 'sales.quote')
   WHERE r.economic_group_id = p_group_id AND r.name = 'Operador de caixa';
  INSERT INTO public.role_permission (role_id, permission_id)
  SELECT r.id, p.id
    FROM public.role r
    JOIN public.permission p ON p.code = 'sales.quote'
   WHERE r.economic_group_id = p_group_id AND r.name = 'Balconista';
  INSERT INTO public.role_permission (role_id, permission_id)
  SELECT r.id, p.id
    FROM public.role r
    JOIN public.permission p ON p.code IN ('sales.sell', 'sales.quote', 'controlled.dispense', 'controlled.view')
   WHERE r.economic_group_id = p_group_id AND r.name = 'Farmacêutico';
  PERFORM app.seed_manager_limits(manager_id, p_group_id);
END;
$$;


-- Dados fiscais: prazo de devolução e o último número de devolução do terminal.
CREATE OR REPLACE FUNCTION app.pdv_fiscal_data(p_branch_id uuid, p_terminal_id uuid)
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
           'offline_zero_stock_minutes', COALESCE(
             (SELECT t.offline_zero_stock_minutes FROM public.terminal t WHERE t.id = p_terminal_id),
             b.offline_zero_stock_minutes
           ),
           'terminal_profile', (SELECT t.profile FROM public.terminal t WHERE t.id = p_terminal_id),
           'fixed_seller_id', (SELECT t.fixed_seller_id FROM public.terminal t WHERE t.id = p_terminal_id),
           'quote_validity_days', b.quote_validity_days,
           'return_days', b.return_days,
           'last_return_number', (
             SELECT pg_catalog.max(r.number) FROM public.sale_return r WHERE r.terminal_id = p_terminal_id AND r.deleted_at IS NULL
           ),
           'seller_pin_required', b.seller_pin_required,
           'last_quote_number', (
             SELECT pg_catalog.max(q.number) FROM public.quote q WHERE q.terminal_id = p_terminal_id AND q.deleted_at IS NULL
           ),
           'last_sale_number', (
             SELECT pg_catalog.max(s.number) FROM public.sale s WHERE s.terminal_id = p_terminal_id AND s.deleted_at IS NULL
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


-- Detalhe da venda com as devoluções.
CREATE OR REPLACE FUNCTION app.sale_detail(p_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT pg_catalog.jsonb_build_object(
    'id', s.id, 'code', s.code, 'branch_name', b.name, 'terminal_name', t.name, 'sold_at', s.sold_at,
    'quote_id', s.quote_id, 'quote_code', (SELECT q.code FROM public.quote q WHERE q.id = s.quote_id),
    'operator_name', u.name, 'seller_name', (SELECT us.name FROM public.user_account us WHERE us.id = s.seller_id),
    'customer_name', c.name, 'customer_code', c.code, 'fiscal_model', s.fiscal_model,
    'fiscal_status', s.fiscal_status, 'subtotal', s.subtotal, 'discount_total', s.discount_total, 'total', s.total,
    'received_at', s.created_at,
    'items', (
      SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', i.id, 'line', i.line, 'product_id', i.product_id, 'product_code', p.code, 'product_name', p.display_name,
        'quantity', i.quantity, 'unit_price', i.unit_price, 'central_price', i.central_price, 'discount', i.discount,
        'total', i.total,
        'batches', COALESCE((
          SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('number', pb.batch_number, 'quantity', -m.quantity) ORDER BY pb.batch_number)
            FROM public.stock_movement m JOIN public.product_batch pb ON pb.id = m.batch_id
           WHERE m.sale_item_id = i.id AND m.deleted_at IS NULL
        ), '[]'::jsonb)
      ) ORDER BY i.line)
        FROM public.sale_item i JOIN public.product p ON p.id = i.product_id
       WHERE i.sale_id = s.id AND i.deleted_at IS NULL
    ),
    'payments', (
      SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'method', p.method, 'amount', p.amount, 'change', p.change_amount, 'card_brand', p.card_brand,
        'authorization_code', p.authorization_code, 'agreement_name', a.name, 'agreement_registration', p.agreement_registration
      ) ORDER BY p.created_at, p.id)
        FROM public.sale_payment p LEFT JOIN public.agreement a ON a.id = p.agreement_id
       WHERE p.sale_id = s.id AND p.deleted_at IS NULL
    ),
    'returns', COALESCE((
      SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', r.id, 'code', r.code, 'returned_at', r.returned_at, 'total', r.total, 'destination', r.destination,
        'reason', r.reason, 'paid', r.paid_movement_id IS NOT NULL
      ) ORDER BY r.returned_at, r.id)
        FROM public.sale_return r WHERE r.sale_id = s.id AND r.deleted_at IS NULL
    ), '[]'::jsonb),
    'alerts', COALESCE((
      SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'kind', al.kind, 'line', i.line, 'detail', al.detail
      ) ORDER BY i.line NULLS FIRST, al.created_at)
        FROM public.sale_alert al LEFT JOIN public.sale_item i ON i.id = al.sale_item_id
       WHERE al.sale_id = s.id AND al.deleted_at IS NULL
    ), '[]'::jsonb)
  )
    FROM public.sale s
    JOIN public.branch b ON b.id = s.branch_id
    JOIN public.terminal t ON t.id = s.terminal_id
    JOIN public.user_account u ON u.id = s.sold_by
    LEFT JOIN public.customer c ON c.id = s.customer_id
   WHERE s.id = p_id AND s.deleted_at IS NULL
     AND s.economic_group_id = app.current_user_group()
     AND app.has_permission('sales.view', s.branch_id)
$$;


REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  app.set_branch_return_days(uuid, integer),
  app.pdv_sale_for_return(text),
  app.pdv_return(text),
  app.list_returns(uuid, date, date),
  app.return_detail(uuid)
TO farmaerp_app;
