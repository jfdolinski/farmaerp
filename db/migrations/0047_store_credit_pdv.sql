-- Up Migration

-- Etapa 7, PR 7B-2: crediário no PDV.
-- Venda no crediário acima do limite do operador ("venda no crediário", por perfil) precisa da
-- liberação de outra pessoa com limite que cubra o valor; a liberação vem no pagamento e fica
-- registrada (supervisor_release). Sem ela, a venda vale (já aconteceu) e fica o alerta.
-- Devolução de venda feita no crediário pode abater o crediário do cliente (destino store_credit):
-- vira um recebimento do tipo "return", que abate na ordem do crediário e não passa pelo caixa.

ALTER TABLE credit_payment DROP CONSTRAINT credit_payment_method_check;
ALTER TABLE credit_payment ADD CONSTRAINT credit_payment_method_check
  CHECK (method IN ('cash', 'credit_card', 'debit_card', 'pix', 'return'));
ALTER TABLE credit_payment ADD COLUMN return_id uuid REFERENCES sale_return (id);
ALTER TABLE credit_payment ADD CONSTRAINT credit_payment_return_check CHECK ((method = 'return') = (return_id IS NOT NULL));
CREATE UNIQUE INDEX credit_payment_return_key ON credit_payment (return_id) WHERE deleted_at IS NULL AND return_id IS NOT NULL;
DROP TRIGGER block_immutable_columns ON credit_payment;
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON credit_payment
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'account_id', 'branch_id', 'terminal_id', 'cash_session_id', 'received_by', 'received_at',
    'method', 'amount', 'excess', 'card_brand', 'authorization_code', 'return_id', 'deleted_at'
  );
CREATE OR REPLACE VIEW v_credit_payment WITH (security_invoker = true) AS SELECT * FROM credit_payment WHERE deleted_at IS NULL;

ALTER TABLE sale_return DROP CONSTRAINT sale_return_destination_check;
ALTER TABLE sale_return ADD CONSTRAINT sale_return_destination_check
  CHECK (destination IN ('credit', 'agreement', 'cash', 'store_credit'));

ALTER TABLE sale_alert DROP CONSTRAINT sale_alert_kind_check;
ALTER TABLE sale_alert ADD CONSTRAINT sale_alert_kind_check CHECK (kind IN (
  'price_divergence', 'discount_above_rule', 'discount_above_limit', 'operator_permission',
  'negative_stock', 'product_status', 'agreement_link', 'offline_zero_stock',
  'controlled_missing', 'controlled_release', 'controlled_pending', 'prescription_expired', 'prescription_type',
  'seller_permission', 'quote_status', 'return_permission', 'return_credit', 'auto_discount',
  'credit_limit', 'credit_blocked', 'credit_overdue', 'credit_schedule', 'credit_dependent', 'credit_release'
));

-- Devolução que abate o crediário: um recebimento do tipo "return", na ordem do crediário, com os
-- parâmetros da filial da conta, na data da devolução. O que passar do débito fica como excesso e
-- vira alerta do caixa (o cliente já tinha pago: a loja devolve de outra forma).
CREATE FUNCTION app.credit_record_return(p_return public.sale_return) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  account public.credit_account;
  received_on date := (p_return.returned_at AT TIME ZONE 'America/Sao_Paulo')::date;
  allocation jsonb;
  entry jsonb;
  due date;
  payment_id uuid;
BEGIN
  SELECT a.* INTO account FROM public.credit_account a
   WHERE a.customer_id = p_return.customer_id AND a.economic_group_id = p_return.economic_group_id AND a.deleted_at IS NULL
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Este cliente não tem crediário.'
      USING ERRCODE = 'FA834', DETAIL = pg_catalog.format('Devolução %s sem conta do cliente.', p_return.code);
  END IF;
  allocation := app.credit_allocate(
    app.credit_states(account.id), p_return.total, received_on, app.credit_policy_json(account.home_branch_id));
  INSERT INTO public.credit_payment (
    economic_group_id, account_id, branch_id, terminal_id, cash_session_id, received_by, received_at, method, amount,
    excess, return_id
  ) VALUES (
    p_return.economic_group_id, account.id, p_return.branch_id, p_return.terminal_id, p_return.cash_session_id,
    p_return.operator_id, p_return.returned_at, 'return', p_return.total, (allocation ->> 'excess')::numeric, p_return.id
  ) RETURNING id INTO payment_id;
  FOR entry IN SELECT value FROM pg_catalog.jsonb_array_elements(allocation -> 'allocations') LOOP
    SELECT i.due_date INTO due FROM public.credit_installment i WHERE i.id = (entry ->> 'id')::uuid;
    INSERT INTO public.credit_allocation (
      economic_group_id, payment_id, installment_id, received_on, fee, interest, principal, interest_open_after, accrued_on
    ) VALUES (
      p_return.economic_group_id, payment_id, (entry ->> 'id')::uuid, received_on, (entry ->> 'fee')::numeric,
      (entry ->> 'interest')::numeric, (entry ->> 'principal')::numeric, (entry ->> 'interest_open_after')::numeric,
      CASE WHEN received_on > due THEN received_on END
    );
  END LOOP;
  IF (allocation ->> 'excess')::numeric > 0 THEN
    INSERT INTO public.cash_alert (economic_group_id, branch_id, cash_session_id, kind, detail)
    VALUES (p_return.economic_group_id, p_return.branch_id, p_return.cash_session_id, 'credit_overpayment',
            pg_catalog.jsonb_build_object('credit_payment_id', payment_id, 'return_code', p_return.code,
                                          'amount', p_return.total, 'excess', (allocation ->> 'excess')::numeric));
  END IF;
END;
$$;

-- Venda para a devolução no PDV: diz se foi no crediário.
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

-- Venda no crediário: agora com o limite do operador.
CREATE OR REPLACE FUNCTION app.credit_record_sale(
  p_group_id uuid, p_branch_id uuid, p_sale_id uuid, p_customer_id uuid, p_sold_at timestamptz, p_payment jsonb
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  account public.credit_account;
  sold_on date := (p_sold_at AT TIME ZONE 'America/Sao_Paulo')::date;
  amount numeric := (p_payment ->> 'amount')::numeric;
  policy jsonb;
  summary jsonb;
  dependent uuid := (p_payment ->> 'dependent_id')::uuid;
  count integer := pg_catalog.jsonb_array_length(p_payment -> 'installments');
  expected jsonb;
  sent jsonb;
  installment jsonb;
  operator uuid;
  operator_limit numeric;
  releaser uuid;
  releaser_limit numeric;
BEGIN
  SELECT a.* INTO account FROM public.credit_account a
   WHERE a.customer_id = p_customer_id AND a.economic_group_id = p_group_id AND a.deleted_at IS NULL
   FOR UPDATE;
  policy := app.credit_policy_json(account.home_branch_id);
  summary := app.credit_summary(account, sold_on);

  IF account.status = 'blocked' THEN
    INSERT INTO public.sale_alert (economic_group_id, branch_id, sale_id, kind, detail)
    VALUES (p_group_id, p_branch_id, p_sale_id, 'credit_blocked', pg_catalog.jsonb_build_object('amount', amount));
  END IF;
  IF (summary ->> 'blocked_by_overdue')::boolean THEN
    INSERT INTO public.sale_alert (economic_group_id, branch_id, sale_id, kind, detail)
    VALUES (p_group_id, p_branch_id, p_sale_id, 'credit_overdue', pg_catalog.jsonb_build_object(
      'oldest_due', summary -> 'oldest_due', 'overdue_days', summary -> 'overdue_days',
      'block_after_days', policy -> 'block_after_days'));
  END IF;
  IF amount > (summary ->> 'available')::numeric THEN
    INSERT INTO public.sale_alert (economic_group_id, branch_id, sale_id, kind, detail)
    VALUES (p_group_id, p_branch_id, p_sale_id, 'credit_limit', pg_catalog.jsonb_build_object(
      'amount', amount, 'available', summary -> 'available', 'credit_limit', account.credit_limit));
  END IF;
  IF dependent IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.customer_dependent d
     WHERE d.id = dependent AND d.customer_id = p_customer_id AND d.credit_allowed AND d.deleted_at IS NULL
  ) THEN
    INSERT INTO public.sale_alert (economic_group_id, branch_id, sale_id, kind, detail)
    VALUES (p_group_id, p_branch_id, p_sale_id, 'credit_dependent', pg_catalog.jsonb_build_object('dependent_id', dependent));
  END IF;
  expected := app.credit_schedule(app.credit_terms(account), sold_on, amount, count);
  SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
           'number', (i.value ->> 'number')::integer, 'due_date', (i.value ->> 'due_date')::date,
           'amount', (i.value ->> 'amount')::numeric) ORDER BY (i.value ->> 'number')::integer)
    INTO sent FROM pg_catalog.jsonb_array_elements(p_payment -> 'installments') i;
  IF count > (policy ->> 'max_installments')::integer OR sent IS DISTINCT FROM (
       SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
                'number', (e.value ->> 'number')::integer, 'due_date', (e.value ->> 'due_date')::date,
                'amount', (e.value ->> 'amount')::numeric) ORDER BY (e.value ->> 'number')::integer)
         FROM pg_catalog.jsonb_array_elements(expected) e) THEN
    INSERT INTO public.sale_alert (economic_group_id, branch_id, sale_id, kind, detail)
    VALUES (p_group_id, p_branch_id, p_sale_id, 'credit_schedule', pg_catalog.jsonb_build_object(
      'sent', sent, 'expected', expected, 'max_installments', policy -> 'max_installments'));
  END IF;

  -- Acima do limite do operador: precisa de outra pessoa, do grupo, com limite que cubra o valor.
  SELECT s.sold_by INTO operator FROM public.sale s WHERE s.id = p_sale_id;
  operator_limit := app.user_limit(operator, p_branch_id, 'credit_sale');
  IF operator_limit IS NOT NULL AND amount > operator_limit THEN
    IF (p_payment -> 'release' ->> 'supervisor_id') ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
      SELECT u.id INTO releaser FROM public.user_account u
       WHERE u.id = (p_payment -> 'release' ->> 'supervisor_id')::uuid AND u.economic_group_id = p_group_id AND u.id <> operator;
    END IF;
    releaser_limit := CASE WHEN releaser IS NOT NULL THEN app.user_limit(releaser, p_branch_id, 'credit_sale') END;
    IF releaser IS NULL OR (releaser_limit IS NOT NULL AND amount > releaser_limit) THEN
      INSERT INTO public.sale_alert (economic_group_id, branch_id, sale_id, kind, detail)
      VALUES (p_group_id, p_branch_id, p_sale_id, 'credit_release', pg_catalog.jsonb_build_object(
        'amount', amount, 'operator_limit', operator_limit, 'released_by', releaser, 'releaser_limit', releaser_limit));
    ELSE
      INSERT INTO public.supervisor_release (
        economic_group_id, branch_id, action, limit_type_id, requested_by, released_by, value, requester_limit,
        releaser_limit, reason, reference_id
      )
      SELECT p_group_id, p_branch_id, 'sales.store_credit', t.id, operator, releaser, amount, operator_limit, releaser_limit,
             COALESCE(NULLIF(pg_catalog.left(pg_catalog.btrim(COALESCE(p_payment -> 'release' ->> 'reason', '')), 500), ''),
                      'Venda no crediário acima do limite do operador'),
             (p_payment ->> 'id')::uuid
        FROM public.limit_type t WHERE t.code = 'credit_sale' AND t.deleted_at IS NULL;
    END IF;
  END IF;

  FOR installment IN SELECT value FROM pg_catalog.jsonb_array_elements(sent) LOOP
    INSERT INTO public.credit_installment (
      economic_group_id, account_id, sale_id, sale_payment_id, branch_id, dependent_id, number, due_date, amount
    ) VALUES (
      p_group_id, account.id, p_sale_id, (p_payment ->> 'id')::uuid, p_branch_id, dependent,
      (installment ->> 'number')::smallint, (installment ->> 'due_date')::date, (installment ->> 'amount')::numeric
    );
  END LOOP;
END;
$$;

-- Venda vinda do PDV: a liberação do crediário no pagamento.
CREATE OR REPLACE FUNCTION app.sync_apply_sale(p_terminal public.terminal, p_group_id uuid, p_payload jsonb)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  uuid_v7 constant text := '^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$';
  uuid_any constant text := '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
  money constant text := '^\d{1,10}(\.\d{1,2})?$';
  sale_id uuid;
  sale_at timestamptz;
  operator_id uuid;
  buyer_id uuid;
  seller uuid;
  from_quote uuid;
  credit public.sale_return;
  credit_used numeric;
  credit_problem text;
  quote_row public.quote;
  item jsonb;
  payment jsonb;
  item_id uuid;
  product_row public.product;
  line_gross numeric;
  sum_gross numeric := 0;
  sum_discount numeric := 0;
  sum_items numeric := 0;
  sum_paid numeric := 0;
  sum_change numeric := 0;
  lines integer[] := '{}';
  central numeric;
  percent numeric;
  rule_max numeric;
  operator_limit numeric;
  releaser uuid;
  releaser_limit numeric;
  allocation record;
  balance numeric;
  status_now text;
  terminal_number smallint;
  auto numeric;
  manual numeric;
  sale_lines jsonb := '[]'::jsonb;
  expected jsonb;
  expected_cents numeric;
BEGIN
  -- Forma geral.
  IF (p_payload ->> 'id') !~ uuid_v7
     OR (p_payload ->> 'cash_session_id') !~ uuid_any
     OR (p_payload ->> 'operator_id') !~ uuid_any
     OR (p_payload ->> 'customer_id') !~ uuid_any
     OR (p_payload ->> 'seller_id') !~ uuid_any
     OR (p_payload ->> 'quote_id') !~ uuid_any
     OR (p_payload ->> 'number') !~ '^[1-9][0-9]{0,8}$'
     OR p_payload ->> 'sold_at' IS NULL
     OR (p_payload ->> 'sold_at') !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$'
     OR (p_payload ->> 'fiscal_model') NOT IN ('65', '55')
     OR pg_catalog.jsonb_typeof(p_payload -> 'items') IS DISTINCT FROM 'array'
     OR pg_catalog.jsonb_array_length(p_payload -> 'items') NOT BETWEEN 1 AND 999
     OR pg_catalog.jsonb_typeof(p_payload -> 'payments') IS DISTINCT FROM 'array'
     OR pg_catalog.jsonb_array_length(p_payload -> 'payments') NOT BETWEEN 1 AND 20
     OR (p_payload ->> 'subtotal') !~ money OR (p_payload ->> 'discount_total') !~ money
     OR (p_payload ->> 'total') !~ money
     OR (p_payload ? 'coupon' AND p_payload -> 'coupon' <> 'null'::jsonb
         AND (pg_catalog.jsonb_typeof(p_payload -> 'coupon') <> 'string' OR pg_catalog.length(p_payload ->> 'coupon') > 40)) THEN
    RAISE EXCEPTION 'A venda enviada pelo terminal está inconsistente.'
      USING ERRCODE = 'FA962', DETAIL = 'Venda fora do formato.';
  END IF;
  sale_id := (p_payload ->> 'id')::uuid;
  operator_id := (p_payload ->> 'operator_id')::uuid;
  buyer_id := (p_payload ->> 'customer_id')::uuid;
  seller := (p_payload ->> 'seller_id')::uuid;
  from_quote := (p_payload ->> 'quote_id')::uuid;
  BEGIN
    sale_at := (p_payload ->> 'sold_at')::timestamptz;
  EXCEPTION WHEN datetime_field_overflow OR invalid_datetime_format THEN
    RAISE EXCEPTION 'A venda enviada pelo terminal está inconsistente.'
      USING ERRCODE = 'FA962', DETAIL = 'Data da venda impossível.';
  END;

  IF EXISTS (SELECT 1 FROM public.sale s WHERE s.id = sale_id)
     OR EXISTS (
       SELECT 1 FROM public.sale s
        WHERE s.terminal_id = p_terminal.id AND s.number = (p_payload ->> 'number')::bigint AND s.deleted_at IS NULL
     ) THEN
    RAISE EXCEPTION 'Esta venda ou turno já foi recebido com outro registro.'
      USING ERRCODE = 'FA963', DETAIL = pg_catalog.format('Venda %s, número %s.', sale_id, p_payload ->> 'number');
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.cash_session s
     WHERE s.id = (p_payload ->> 'cash_session_id')::uuid AND s.terminal_id = p_terminal.id AND s.deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'A venda enviada pelo terminal está inconsistente.'
      USING ERRCODE = 'FA962', DETAIL = 'Turno de caixa desconhecido neste terminal.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.user_account u WHERE u.id = operator_id AND u.economic_group_id = p_group_id)
     OR (buyer_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM public.customer c WHERE c.id = buyer_id AND c.economic_group_id = p_group_id
     ))
     OR (seller IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM public.user_account u WHERE u.id = seller AND u.economic_group_id = p_group_id
     ))
     OR (from_quote IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM public.quote q WHERE q.id = from_quote AND q.economic_group_id = p_group_id
     )) THEN
    RAISE EXCEPTION 'Um dos itens informados não foi encontrado.'
      USING ERRCODE = 'FA004', DETAIL = 'Operador, vendedor, cliente ou orçamento fora do grupo.';
  END IF;

  -- Itens: forma, produto do grupo e contas.
  FOR item IN SELECT value FROM pg_catalog.jsonb_array_elements(p_payload -> 'items') LOOP
    IF pg_catalog.jsonb_typeof(item) IS DISTINCT FROM 'object'
       OR (item ->> 'id') !~ uuid_v7 OR (item ->> 'product_id') !~ uuid_any
       OR (item ->> 'barcode_id') !~ uuid_any OR (item ->> 'batch_id') !~ uuid_any
       OR (item ->> 'line') !~ '^[1-9][0-9]{0,2}$'
       OR (item ->> 'quantity') !~ '^\d{1,11}(\.\d{1,3})?$' OR (item ->> 'quantity')::numeric <= 0
       OR (item ->> 'unit_price') !~ money OR (item ->> 'discount') !~ money OR (item ->> 'total') !~ money
       OR (item ->> 'auto_discount') !~ money
       OR (item ? 'discount_rules' AND item -> 'discount_rules' <> 'null'::jsonb AND (
             pg_catalog.jsonb_typeof(item -> 'discount_rules') <> 'array'
             OR pg_catalog.jsonb_array_length(item -> 'discount_rules') > 20
             OR EXISTS (
               SELECT 1 FROM pg_catalog.jsonb_array_elements(item -> 'discount_rules') r
                WHERE pg_catalog.jsonb_typeof(r.value) <> 'object' OR (r.value ->> 'rule_id') !~ uuid_any
                   OR (r.value ->> 'amount') !~ money OR (r.value ->> 'amount')::numeric <= 0)
             OR (SELECT COALESCE(pg_catalog.sum((r.value ->> 'amount')::numeric), 0)
                   FROM pg_catalog.jsonb_array_elements(item -> 'discount_rules') r)
                <> COALESCE((item ->> 'auto_discount')::numeric, 0)))
       OR (COALESCE((item ->> 'auto_discount')::numeric, 0) > 0
           AND (item -> 'discount_rules' IS NULL OR item -> 'discount_rules' = 'null'::jsonb))
       OR COALESCE((item ->> 'auto_discount')::numeric, 0) > COALESCE((item ->> 'discount')::numeric, 0)
       OR (item ->> 'line')::integer = ANY (lines) THEN
      RAISE EXCEPTION 'A venda enviada pelo terminal está inconsistente.'
        USING ERRCODE = 'FA962', DETAIL = 'Item fora do formato.';
    END IF;
    lines := lines || (item ->> 'line')::integer;
    IF NOT EXISTS (
         SELECT 1 FROM public.product p WHERE p.id = (item ->> 'product_id')::uuid AND p.economic_group_id = p_group_id
       )
       OR (item ->> 'barcode_id' IS NOT NULL AND NOT EXISTS (
         SELECT 1 FROM public.product_barcode pb
          WHERE pb.id = (item ->> 'barcode_id')::uuid AND pb.product_id = (item ->> 'product_id')::uuid
       ))
       OR (item ->> 'batch_id' IS NOT NULL AND NOT EXISTS (
         SELECT 1 FROM public.product_batch pb
          WHERE pb.id = (item ->> 'batch_id')::uuid AND pb.product_id = (item ->> 'product_id')::uuid
            AND pb.branch_id = p_terminal.branch_id AND pb.deleted_at IS NULL
       )) THEN
      RAISE EXCEPTION 'Um dos itens informados não foi encontrado.'
        USING ERRCODE = 'FA004', DETAIL = pg_catalog.format('Item da linha %s.', item ->> 'line');
    END IF;
    IF EXISTS (
      SELECT 1 FROM pg_catalog.jsonb_array_elements(COALESCE(NULLIF(item -> 'discount_rules', 'null'::jsonb), '[]'::jsonb)) r
       WHERE NOT EXISTS (
         SELECT 1 FROM public.discount_rule d WHERE d.id = (r.value ->> 'rule_id')::uuid AND d.economic_group_id = p_group_id
       )
    ) THEN
      RAISE EXCEPTION 'Um dos itens informados não foi encontrado.'
        USING ERRCODE = 'FA004', DETAIL = pg_catalog.format('Regra de desconto do item da linha %s.', item ->> 'line');
    END IF;
    line_gross := round((item ->> 'quantity')::numeric * (item ->> 'unit_price')::numeric, 2);
    IF (item ->> 'discount')::numeric > line_gross
       OR (item ->> 'total')::numeric <> line_gross - (item ->> 'discount')::numeric THEN
      RAISE EXCEPTION 'A venda enviada pelo terminal está inconsistente.'
        USING ERRCODE = 'FA962', DETAIL = pg_catalog.format('Conta do item da linha %s.', item ->> 'line');
    END IF;
    IF item ? 'zero_stock_release' AND item -> 'zero_stock_release' <> 'null'::jsonb AND (
         pg_catalog.jsonb_typeof(item -> 'zero_stock_release') <> 'object'
         OR (item -> 'zero_stock_release' ->> 'supervisor_id') !~ uuid_any
         OR (item -> 'zero_stock_release' ->> 'minutes_offline') !~ '^[0-9]{1,7}$'
       ) THEN
      RAISE EXCEPTION 'A venda enviada pelo terminal está inconsistente.'
        USING ERRCODE = 'FA962', DETAIL = pg_catalog.format('Venda sem estoque do item da linha %s.', item ->> 'line');
    END IF;
    IF item -> 'zero_stock_release' ->> 'supervisor_id' IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.user_account u
       WHERE u.id = (item -> 'zero_stock_release' ->> 'supervisor_id')::uuid AND u.economic_group_id = p_group_id
    ) THEN
      RAISE EXCEPTION 'Um dos itens informados não foi encontrado.'
        USING ERRCODE = 'FA004', DETAIL = 'Quem autorizou a venda sem estoque está fora do grupo.';
    END IF;
    -- Controlado: objeto com o identificador, a situação e quem liberou; o resto a tabela confere.
    IF item ? 'controlled' AND item -> 'controlled' <> 'null'::jsonb AND (
         pg_catalog.jsonb_typeof(item -> 'controlled') <> 'object'
         OR (item -> 'controlled' ->> 'id') !~ uuid_v7
         OR (item -> 'controlled' ->> 'pharmacist_id') !~ uuid_any
         OR item -> 'controlled' ->> 'status' IS NULL
         OR (item -> 'controlled' ->> 'status') NOT IN ('complete', 'pending')
       ) THEN
      RAISE EXCEPTION 'Os dados do controlado vendido estão incompletos ou inválidos.'
        USING ERRCODE = 'FA990', DETAIL = pg_catalog.format('Controlado do item da linha %s.', item ->> 'line');
    END IF;
    IF item -> 'controlled' ->> 'pharmacist_id' IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.user_account u
       WHERE u.id = (item -> 'controlled' ->> 'pharmacist_id')::uuid AND u.economic_group_id = p_group_id
    ) THEN
      RAISE EXCEPTION 'Um dos itens informados não foi encontrado.'
        USING ERRCODE = 'FA004', DETAIL = 'Farmacêutico fora do grupo.';
    END IF;
    IF item ? 'release' AND item -> 'release' <> 'null'::jsonb AND (
         pg_catalog.jsonb_typeof(item -> 'release') <> 'object'
         OR (item -> 'release' ->> 'supervisor_id') !~ uuid_any
         OR pg_catalog.length(pg_catalog.btrim(COALESCE(item -> 'release' ->> 'reason', ''))) NOT BETWEEN 1 AND 500
       ) THEN
      RAISE EXCEPTION 'A venda enviada pelo terminal está inconsistente.'
        USING ERRCODE = 'FA962', DETAIL = pg_catalog.format('Liberação do item da linha %s.', item ->> 'line');
    END IF;
    sum_gross := sum_gross + line_gross;
    sum_discount := sum_discount + (item ->> 'discount')::numeric;
    sum_items := sum_items + (item ->> 'total')::numeric;
  END LOOP;

  -- Pagamentos.
  FOR payment IN SELECT value FROM pg_catalog.jsonb_array_elements(p_payload -> 'payments') LOOP
    IF pg_catalog.jsonb_typeof(payment) IS DISTINCT FROM 'object'
       OR (payment ->> 'id') !~ uuid_v7
       OR payment ->> 'method' IS NULL
       OR (payment ->> 'method') NOT IN ('cash', 'credit_card', 'debit_card', 'pix', 'agreement', 'return_credit', 'store_credit')
       OR (payment ->> 'amount') !~ money OR (payment ->> 'amount')::numeric <= 0
       OR (payment ->> 'change') !~ money
       OR COALESCE((payment ->> 'change')::numeric, 0) >= (payment ->> 'amount')::numeric
       OR (COALESCE((payment ->> 'change')::numeric, 0) > 0 AND payment ->> 'method' <> 'cash')
       OR pg_catalog.length(payment ->> 'card_brand') > 30 OR pg_catalog.length(payment ->> 'authorization_code') > 30
       OR (payment ->> 'agreement_id') !~ uuid_any OR pg_catalog.length(payment ->> 'agreement_registration') > 40
       OR ((payment ->> 'method') = 'agreement') <> (payment ->> 'agreement_id' IS NOT NULL)
       OR (payment ->> 'return_id') !~ uuid_any
       OR ((payment ->> 'method') = 'return_credit') <> (payment ->> 'return_id' IS NOT NULL)
       OR (payment ->> 'dependent_id') !~ uuid_any
       OR ((payment ->> 'method') = 'store_credit') <> (payment -> 'installments' IS NOT NULL)
       OR (payment ->> 'dependent_id' IS NOT NULL AND (payment ->> 'method') <> 'store_credit')
       OR (payment -> 'release' IS NOT NULL AND payment -> 'release' <> 'null'::jsonb AND (
             (payment ->> 'method') <> 'store_credit' OR pg_catalog.jsonb_typeof(payment -> 'release') <> 'object'
             OR (payment -> 'release' ->> 'supervisor_id') !~ uuid_any
             OR pg_catalog.length(payment -> 'release' ->> 'reason') > 500)) THEN
      RAISE EXCEPTION 'A venda enviada pelo terminal está inconsistente.'
        USING ERRCODE = 'FA962', DETAIL = 'Pagamento fora do formato.';
    END IF;
    -- Crediário: parcelas no formato e cliente com conta.
    IF payment ->> 'method' = 'store_credit' THEN
      IF NOT app.credit_installments_valid(payment, sale_at) THEN
        RAISE EXCEPTION 'A venda enviada pelo terminal está inconsistente.'
          USING ERRCODE = 'FA962', DETAIL = 'Parcelas do crediário fora do formato.';
      END IF;
      IF NOT EXISTS (
        SELECT 1 FROM public.credit_account a
         WHERE a.customer_id = buyer_id AND a.economic_group_id = p_group_id AND a.deleted_at IS NULL
      ) THEN
        RAISE EXCEPTION 'Este cliente não tem crediário.'
          USING ERRCODE = 'FA834', DETAIL = 'Venda no crediário sem conta do cliente.';
      END IF;
      IF payment ->> 'dependent_id' IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.customer_dependent d
         WHERE d.id = (payment ->> 'dependent_id')::uuid AND d.economic_group_id = p_group_id
      ) THEN
        RAISE EXCEPTION 'Um dos itens informados não foi encontrado.'
          USING ERRCODE = 'FA004', DETAIL = 'Dependente do crediário fora do grupo.';
      END IF;
    END IF;
    IF payment ->> 'agreement_id' IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.agreement a WHERE a.id = (payment ->> 'agreement_id')::uuid AND a.economic_group_id = p_group_id
    ) THEN
      RAISE EXCEPTION 'Um dos itens informados não foi encontrado.'
        USING ERRCODE = 'FA004', DETAIL = 'Convênio fora do grupo.';
    END IF;
    IF payment ->> 'return_id' IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.sale_return r WHERE r.id = (payment ->> 'return_id')::uuid AND r.economic_group_id = p_group_id
    ) THEN
      RAISE EXCEPTION 'Um dos itens informados não foi encontrado.'
        USING ERRCODE = 'FA004', DETAIL = 'Devolução do crédito fora do grupo.';
    END IF;
    sum_paid := sum_paid + (payment ->> 'amount')::numeric;
    sum_change := sum_change + COALESCE((payment ->> 'change')::numeric, 0);
  END LOOP;

  IF (p_payload ->> 'subtotal')::numeric <> sum_gross OR (p_payload ->> 'discount_total')::numeric <> sum_discount
     OR (p_payload ->> 'total')::numeric <> sum_items OR sum_paid - sum_change <> sum_items THEN
    RAISE EXCEPTION 'A venda enviada pelo terminal está inconsistente.'
      USING ERRCODE = 'FA962', DETAIL = pg_catalog.format(
        'Totais: bruto %s/%s, desconto %s/%s, total %s/%s, pago %s menos troco %s.',
        p_payload ->> 'subtotal', sum_gross, p_payload ->> 'discount_total', sum_discount,
        p_payload ->> 'total', sum_items, sum_paid, sum_change);
  END IF;

  -- Conferida: grava.
  SELECT t.number INTO terminal_number FROM public.terminal t WHERE t.id = p_terminal.id;
  INSERT INTO public.sale (
    id, economic_group_id, branch_id, terminal_id, cash_session_id, number, code, sold_by, customer_id, sold_at,
    fiscal_model, subtotal, discount_total, total, seller_id, quote_id, coupon
  ) VALUES (
    sale_id, p_group_id, p_terminal.branch_id, p_terminal.id, (p_payload ->> 'cash_session_id')::uuid,
    (p_payload ->> 'number')::bigint,
    terminal_number || '-' || pg_catalog.lpad(p_payload ->> 'number', 6, '0'),
    operator_id, buyer_id, sale_at, p_payload ->> 'fiscal_model', sum_gross, sum_discount, sum_items, seller, from_quote,
    NULLIF(pg_catalog.upper(pg_catalog.btrim(p_payload ->> 'coupon')), '')
  );
  -- Orçamento aberto e válido na hora da venda, da mesma loja: vira venda. Senão, a venda vale e
  -- fica o alerta (outro caixa já fechou, venceu ou a plaquinha foi para outro orçamento).
  IF from_quote IS NOT NULL THEN
    SELECT q.* INTO quote_row FROM public.quote q WHERE q.id = from_quote FOR UPDATE;
    IF quote_row.status = 'open' AND quote_row.expires_at > sale_at AND quote_row.branch_id = p_terminal.branch_id THEN
      UPDATE public.quote SET status = 'converted', converted_sale_id = sale_id WHERE id = from_quote;
    ELSE
      INSERT INTO public.sale_alert (economic_group_id, branch_id, sale_id, kind, detail)
      VALUES (p_group_id, p_terminal.branch_id, sale_id, 'quote_status', pg_catalog.jsonb_build_object(
        'quote_code', quote_row.code,
        'status', CASE WHEN quote_row.branch_id <> p_terminal.branch_id THEN 'other_branch'
                       WHEN quote_row.status = 'open' THEN 'expired' ELSE quote_row.status END
      ));
    END IF;
  END IF;
  -- Vendedor precisa poder orçar ou vender na filial; sem isso, a venda vale e vira alerta.
  IF seller IS NOT NULL
     AND NOT app.user_has_permission(seller, 'sales.quote', p_terminal.branch_id)
     AND NOT app.user_has_permission(seller, 'sales.sell', p_terminal.branch_id) THEN
    INSERT INTO public.sale_alert (economic_group_id, branch_id, sale_id, kind, detail)
    VALUES (p_group_id, p_terminal.branch_id, sale_id, 'seller_permission', pg_catalog.jsonb_build_object('seller_id', seller));
  END IF;

  IF NOT app.user_has_permission(operator_id, 'sales.sell', p_terminal.branch_id) THEN
    INSERT INTO public.sale_alert (economic_group_id, branch_id, sale_id, kind, detail)
    VALUES (p_group_id, p_terminal.branch_id, sale_id, 'operator_permission', pg_catalog.jsonb_build_object('operator_id', operator_id));
  END IF;
  operator_limit := app.user_limit(operator_id, p_terminal.branch_id, 'sale_discount');

  FOR item IN SELECT value FROM pg_catalog.jsonb_array_elements(p_payload -> 'items') ORDER BY (value ->> 'line')::integer LOOP
    item_id := (item ->> 'id')::uuid;
    SELECT p.* INTO product_row FROM public.product p WHERE p.id = (item ->> 'product_id')::uuid;
    central := app.effective_price_at(product_row.id, p_terminal.branch_id, sale_at);
    INSERT INTO public.sale_item (
      id, economic_group_id, sale_id, line, product_id, barcode_id, quantity, unit_price, central_price, discount, total, batch_id,
      auto_discount
    ) VALUES (
      item_id, p_group_id, sale_id, (item ->> 'line')::smallint, product_row.id, (item ->> 'barcode_id')::uuid,
      (item ->> 'quantity')::numeric, (item ->> 'unit_price')::numeric, central, (item ->> 'discount')::numeric,
      (item ->> 'total')::numeric, (item ->> 'batch_id')::uuid, COALESCE((item ->> 'auto_discount')::numeric, 0)
    );
    INSERT INTO public.sale_item_discount (economic_group_id, sale_item_id, discount_rule_id, amount)
    SELECT p_group_id, item_id, (r.value ->> 'rule_id')::uuid, (r.value ->> 'amount')::numeric
      FROM pg_catalog.jsonb_array_elements(COALESCE(NULLIF(item -> 'discount_rules', 'null'::jsonb), '[]'::jsonb)) r;
    sale_lines := sale_lines || pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
      'line', (item ->> 'line')::integer, 'product_id', product_row.id,
      'quantity', (item ->> 'quantity')::numeric, 'unit_price', (item ->> 'unit_price')::numeric));

    IF central IS DISTINCT FROM (item ->> 'unit_price')::numeric THEN
      INSERT INTO public.sale_alert (economic_group_id, branch_id, sale_id, sale_item_id, kind, detail)
      VALUES (p_group_id, p_terminal.branch_id, sale_id, item_id, 'price_divergence',
              pg_catalog.jsonb_build_object('pdv_price', (item ->> 'unit_price')::numeric, 'central_price', central));
    END IF;

    SELECT s.status INTO status_now FROM public.product_branch_status s
     WHERE s.product_id = product_row.id AND s.branch_id = p_terminal.branch_id AND s.deleted_at IS NULL;
    IF product_row.deleted_at IS NOT NULL OR status_now IS DISTINCT FROM 'active' AND status_now IS DISTINCT FROM 'on_order' THEN
      INSERT INTO public.sale_alert (economic_group_id, branch_id, sale_id, sale_item_id, kind, detail)
      VALUES (p_group_id, p_terminal.branch_id, sale_id, item_id, 'product_status',
              pg_catalog.jsonb_build_object('status', COALESCE(status_now, 'unknown'), 'deleted', product_row.deleted_at IS NOT NULL));
    END IF;

    -- Desconto manual (o que passa dos automáticos): regra do produto e limite do operador, com a
    -- liberação feita no PDV.
    manual := (item ->> 'discount')::numeric - COALESCE((item ->> 'auto_discount')::numeric, 0);
    IF manual > 0 THEN
      line_gross := round((item ->> 'quantity')::numeric * (item ->> 'unit_price')::numeric, 2);
      percent := round(manual * 100 / line_gross, 4);
      SELECT r.value INTO rule_max FROM app.resolve_product_rule('max_discount', product_row.id, p_terminal.branch_id, sale_at) r;
      releaser := NULLIF(item -> 'release' ->> 'supervisor_id', '')::uuid;
      -- Acima da regra do produto: vale se o operador ou o supervisor que liberou pode passar dela.
      IF rule_max IS NOT NULL AND percent > rule_max
         AND NOT app.user_has_permission(operator_id, 'sales.discount_override', p_terminal.branch_id)
         AND NOT (releaser IS NOT NULL AND releaser <> operator_id
                  AND app.user_has_permission(releaser, 'sales.discount_override', p_terminal.branch_id)) THEN
        INSERT INTO public.sale_alert (economic_group_id, branch_id, sale_id, sale_item_id, kind, detail)
        VALUES (p_group_id, p_terminal.branch_id, sale_id, item_id, 'discount_above_rule',
                pg_catalog.jsonb_build_object('percent', percent, 'rule_max', rule_max));
      END IF;
      IF operator_limit IS NOT NULL AND percent > operator_limit THEN
        releaser := NULLIF(item -> 'release' ->> 'supervisor_id', '')::uuid;
        releaser_limit := CASE WHEN releaser IS NOT NULL THEN app.user_limit(releaser, p_terminal.branch_id, 'sale_discount') END;
        IF releaser IS NULL OR releaser = operator_id
           OR NOT EXISTS (SELECT 1 FROM public.user_account u WHERE u.id = releaser AND u.economic_group_id = p_group_id)
           OR (releaser_limit IS NOT NULL AND percent > releaser_limit) THEN
          INSERT INTO public.sale_alert (economic_group_id, branch_id, sale_id, sale_item_id, kind, detail)
          VALUES (p_group_id, p_terminal.branch_id, sale_id, item_id, 'discount_above_limit',
                  pg_catalog.jsonb_build_object('percent', percent, 'operator_limit', operator_limit,
                                                'supervisor_id', releaser, 'supervisor_limit', releaser_limit));
        ELSE
          INSERT INTO public.supervisor_release (
            economic_group_id, branch_id, action, limit_type_id, requested_by, released_by, value, requester_limit,
            releaser_limit, reason, reference_id
          )
          SELECT p_group_id, p_terminal.branch_id, 'sales.discount', t.id, operator_id, releaser, percent, operator_limit,
                 releaser_limit, pg_catalog.btrim(item -> 'release' ->> 'reason'), item_id
            FROM public.limit_type t WHERE t.code = 'sale_discount' AND t.deleted_at IS NULL;
        END IF;
      END IF;
    END IF;

    -- Controlado: registro da dispensação (receita, comprador, lote, farmacêutico) ou alerta.
    IF item -> 'controlled' IS NOT NULL AND item -> 'controlled' <> 'null'::jsonb THEN
      PERFORM app.record_controlled_dispensing(p_terminal, p_group_id, sale_id, item_id, product_row, item, sale_at);
    ELSIF (SELECT cp.controlled_class FROM public.catalog_product cp WHERE cp.id = product_row.catalog_product_id) IS NOT NULL THEN
      INSERT INTO public.sale_alert (economic_group_id, branch_id, sale_id, sale_item_id, kind, detail)
      VALUES (p_group_id, p_terminal.branch_id, sale_id, item_id, 'controlled_missing', '{}'::jsonb);
    END IF;

    -- Venda sem estoque autorizada com o PDV sem internet: fica o registro completo.
    IF item -> 'zero_stock_release' ->> 'supervisor_id' IS NOT NULL THEN
      INSERT INTO public.sale_alert (economic_group_id, branch_id, sale_id, sale_item_id, kind, detail)
      VALUES (p_group_id, p_terminal.branch_id, sale_id, item_id, 'offline_zero_stock', pg_catalog.jsonb_build_object(
        'supervisor_id', (item -> 'zero_stock_release' ->> 'supervisor_id')::uuid,
        'supervisor_allowed', app.user_has_permission(
          (item -> 'zero_stock_release' ->> 'supervisor_id')::uuid, 'sales.zero_stock_release', p_terminal.branch_id),
        'minutes_offline', (item -> 'zero_stock_release' ->> 'minutes_offline')::integer
      ));
    END IF;

    -- Estoque: o lote do PDV, ou o vencimento mais próximo.
    IF item ->> 'batch_id' IS NOT NULL THEN
      INSERT INTO public.stock_movement (economic_group_id, branch_id, product_id, batch_id, movement_type, quantity, occurred_at, sale_item_id)
      VALUES (p_group_id, p_terminal.branch_id, product_row.id, (item ->> 'batch_id')::uuid, 'sale',
              -(item ->> 'quantity')::numeric, sale_at, item_id);
    ELSIF app.batch_required(product_row.id, p_terminal.branch_id) THEN
      FOR allocation IN SELECT * FROM app.allocate_sale_batches(p_terminal.branch_id, product_row.id, (item ->> 'quantity')::numeric) LOOP
        INSERT INTO public.stock_movement (economic_group_id, branch_id, product_id, batch_id, movement_type, quantity, occurred_at, sale_item_id)
        VALUES (p_group_id, p_terminal.branch_id, product_row.id, allocation.batch_id, 'sale', -allocation.quantity, sale_at, item_id);
      END LOOP;
    ELSE
      INSERT INTO public.stock_movement (economic_group_id, branch_id, product_id, movement_type, quantity, occurred_at, sale_item_id)
      VALUES (p_group_id, p_terminal.branch_id, product_row.id, 'sale', -(item ->> 'quantity')::numeric, sale_at, item_id);
    END IF;
    balance := app.branch_stock_quantity(product_row.id, p_terminal.branch_id);
    IF balance < 0 OR EXISTS (
      SELECT 1 FROM public.stock_balance sb
        JOIN public.stock_movement m ON m.sale_item_id = item_id AND m.batch_id IS NOT DISTINCT FROM sb.batch_id
       WHERE sb.branch_id = p_terminal.branch_id AND sb.product_id = product_row.id AND sb.deleted_at IS NULL AND sb.quantity < 0
    ) THEN
      INSERT INTO public.sale_alert (economic_group_id, branch_id, sale_id, sale_item_id, kind, detail)
      VALUES (p_group_id, p_terminal.branch_id, sale_id, item_id, 'negative_stock', pg_catalog.jsonb_build_object('balance', balance));
    END IF;
  END LOOP;

  -- Descontos automáticos: a central refaz a conta com as regras da hora da venda. Deu mais que o
  -- esperado: a venda vale e fica o alerta.
  expected := app.auto_discounts(p_terminal.branch_id, sale_lines, pg_catalog.jsonb_build_object(
    'at', sale_at,
    'payment_methods', (SELECT pg_catalog.jsonb_agg(p.value ->> 'method') FROM pg_catalog.jsonb_array_elements(p_payload -> 'payments') p),
    'customer_id', buyer_id,
    'agreement_ids', COALESCE((
      SELECT pg_catalog.jsonb_agg(DISTINCT p.value ->> 'agreement_id')
        FROM pg_catalog.jsonb_array_elements(p_payload -> 'payments') p WHERE p.value ->> 'agreement_id' IS NOT NULL
    ), '[]'::jsonb),
    'coupon', p_payload ->> 'coupon'
  ));
  FOR item IN SELECT value FROM pg_catalog.jsonb_array_elements(p_payload -> 'items') LOOP
    auto := COALESCE((item ->> 'auto_discount')::numeric, 0);
    CONTINUE WHEN auto = 0;
    SELECT (e.value ->> 'total_cents')::numeric INTO expected_cents
      FROM pg_catalog.jsonb_array_elements(expected) e WHERE (e.value ->> 'line')::integer = (item ->> 'line')::integer;
    IF auto * 100 > COALESCE(expected_cents, 0) THEN
      INSERT INTO public.sale_alert (economic_group_id, branch_id, sale_id, sale_item_id, kind, detail)
      VALUES (p_group_id, p_terminal.branch_id, sale_id, (item ->> 'id')::uuid, 'auto_discount', pg_catalog.jsonb_build_object(
        'pdv_discount', auto, 'expected_discount', COALESCE(expected_cents, 0) / 100, 'rules', item -> 'discount_rules'));
    END IF;
  END LOOP;

  FOR payment IN SELECT value FROM pg_catalog.jsonb_array_elements(p_payload -> 'payments') LOOP
    INSERT INTO public.sale_payment (
      id, economic_group_id, sale_id, method, amount, change_amount, card_brand, authorization_code, agreement_id,
      agreement_registration, return_id
    ) VALUES (
      (payment ->> 'id')::uuid, p_group_id, sale_id, payment ->> 'method', (payment ->> 'amount')::numeric,
      COALESCE((payment ->> 'change')::numeric, 0), NULLIF(pg_catalog.btrim(payment ->> 'card_brand'), ''),
      NULLIF(pg_catalog.btrim(payment ->> 'authorization_code'), ''), (payment ->> 'agreement_id')::uuid,
      NULLIF(pg_catalog.btrim(payment ->> 'agreement_registration'), ''), (payment ->> 'return_id')::uuid
    );
    -- Crédito de devolução: da loja, de crédito e com saldo. Senão, a venda vale (já aconteceu) e fica o alerta.
    IF payment ->> 'return_id' IS NOT NULL THEN
      SELECT r.* INTO credit FROM public.sale_return r WHERE r.id = (payment ->> 'return_id')::uuid FOR UPDATE;
      SELECT COALESCE(pg_catalog.sum(sp.amount), 0) INTO credit_used
        FROM public.sale_payment sp WHERE sp.return_id = credit.id AND sp.deleted_at IS NULL;
      credit_problem := CASE
        WHEN credit.branch_id <> p_terminal.branch_id THEN 'other_branch'
        WHEN credit.destination <> 'credit' THEN 'not_credit'
        WHEN credit_used > credit.total THEN 'balance'
      END;
      IF credit_problem IS NOT NULL THEN
        INSERT INTO public.sale_alert (economic_group_id, branch_id, sale_id, kind, detail)
        VALUES (p_group_id, p_terminal.branch_id, sale_id, 'return_credit', pg_catalog.jsonb_build_object(
          'return_code', credit.code, 'problem', credit_problem, 'amount', (payment ->> 'amount')::numeric,
          'balance', credit.total - (credit_used - (payment ->> 'amount')::numeric)
        ));
      END IF;
    END IF;
    IF payment ->> 'method' = 'store_credit' THEN
      PERFORM app.credit_record_sale(p_group_id, p_terminal.branch_id, sale_id, buyer_id, sale_at, payment);
    END IF;
    -- Convênio sem o cliente vinculado a ele (ou sem cliente): a venda vale, a retaguarda confere.
    IF payment ->> 'agreement_id' IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.customer_agreement ca
       WHERE ca.customer_id = buyer_id AND ca.agreement_id = (payment ->> 'agreement_id')::uuid AND ca.deleted_at IS NULL
    ) THEN
      INSERT INTO public.sale_alert (economic_group_id, branch_id, sale_id, kind, detail)
      VALUES (p_group_id, p_terminal.branch_id, sale_id, 'agreement_link',
              pg_catalog.jsonb_build_object('agreement_id', payment ->> 'agreement_id'));
    END IF;
  END LOOP;
END;
$$;

-- Devolução vinda do PDV: destino crediário.
CREATE OR REPLACE FUNCTION app.sync_apply_return(p_terminal public.terminal, p_group_id uuid, p_payload jsonb)
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
     OR (p_payload ->> 'destination') IS NULL OR (p_payload ->> 'destination') NOT IN ('credit', 'agreement', 'cash', 'store_credit')
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

  IF p_payload ->> 'destination' = 'store_credit' AND NOT EXISTS (
    SELECT 1 FROM public.sale_payment p WHERE p.sale_id = sale_row.id AND p.method = 'store_credit' AND p.deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Só a venda feita no crediário pode ter o valor abatido no crediário.'
      USING ERRCODE = 'FA846', DETAIL = sale_row.code;
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

  -- Crediário: o valor abate o débito do cliente.
  IF p_payload ->> 'destination' = 'store_credit' THEN
    PERFORM app.credit_record_return(r) FROM public.sale_return r WHERE r.id = refund_id;
  END IF;

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

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;
