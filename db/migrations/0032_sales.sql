-- Up Migration

-- Venda na central. A venda acontece no PDV, mesmo sem internet, e sobe pela outbox. O banco
-- confere e aplica: grava a venda, baixa o estoque por lote e registra as liberações. O que não
-- fecha (totais, itens de outro grupo, número repetido) vira conflito. O que fecha mas merece
-- atenção (preço diferente do da central, desconto acima da regra, estoque negativo) é aplicado,
-- porque a venda já aconteceu na loja, e fica como alerta da venda para a retaguarda.
-- A nota fiscal fica "pendente de emissão": NFC-e e NF-e chegam na Etapa 8.

INSERT INTO permission (code, module, name) VALUES
  ('sales.sell', 'Vendas', 'Vender no PDV e abrir o caixa'),
  ('sales.view', 'Vendas', 'Ver as vendas e os alertas');

-- Turno de caixa: aberto no PDV com o fundo de troco. O fechamento chega com a conferência cega.
CREATE TABLE cash_session (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  branch_id uuid NOT NULL REFERENCES branch (id),
  terminal_id uuid NOT NULL REFERENCES terminal (id),
  opened_by uuid NOT NULL REFERENCES user_account (id),
  opened_at timestamptz NOT NULL,
  opening_float numeric(12, 2) NOT NULL CONSTRAINT cash_session_opening_float_check CHECK (opening_float >= 0),
  status text NOT NULL DEFAULT 'open' CONSTRAINT cash_session_status_check CHECK (status IN ('open', 'closed')),
  closed_at timestamptz,
  closed_by uuid REFERENCES user_account (id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid,
  CONSTRAINT cash_session_closing_check CHECK ((status = 'closed') = (closed_at IS NOT NULL AND closed_by IS NOT NULL))
);
CREATE INDEX cash_session_terminal_idx ON cash_session (terminal_id, opened_at DESC);
CREATE INDEX cash_session_branch_idx ON cash_session (branch_id, opened_at DESC);
CREATE INDEX cash_session_economic_group_id_idx ON cash_session (economic_group_id);
CREATE INDEX cash_session_opened_by_idx ON cash_session (opened_by);
CREATE INDEX cash_session_closed_by_idx ON cash_session (closed_by);

CREATE TABLE sale (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  branch_id uuid NOT NULL REFERENCES branch (id),
  terminal_id uuid NOT NULL REFERENCES terminal (id),
  cash_session_id uuid NOT NULL REFERENCES cash_session (id),
  -- Contador do terminal; o código humano é o número do terminal + este contador (2-000123).
  number bigint NOT NULL CONSTRAINT sale_number_check CHECK (number BETWEEN 1 AND 999999999),
  code text NOT NULL CONSTRAINT sale_code_check CHECK (code ~ '^[0-9]{1,3}-[0-9]{6,9}$'),
  sold_by uuid NOT NULL REFERENCES user_account (id),
  customer_id uuid REFERENCES customer (id),
  -- Hora do PDV: a venda pode chegar horas depois, se a loja ficou sem internet.
  sold_at timestamptz NOT NULL,
  fiscal_model text CONSTRAINT sale_fiscal_model_check CHECK (fiscal_model IN ('65', '55')),
  fiscal_status text NOT NULL DEFAULT 'pending' CONSTRAINT sale_fiscal_status_check CHECK (fiscal_status IN ('pending')),
  subtotal numeric(12, 2) NOT NULL CONSTRAINT sale_subtotal_check CHECK (subtotal >= 0),
  discount_total numeric(12, 2) NOT NULL CONSTRAINT sale_discount_total_check CHECK (discount_total >= 0),
  total numeric(12, 2) NOT NULL CONSTRAINT sale_total_check CHECK (total >= 0 AND total = subtotal - discount_total),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE UNIQUE INDEX sale_terminal_number_key ON sale (terminal_id, number) WHERE deleted_at IS NULL;
CREATE INDEX sale_branch_sold_idx ON sale (branch_id, sold_at DESC, id DESC);
CREATE INDEX sale_economic_group_id_idx ON sale (economic_group_id);
CREATE INDEX sale_cash_session_idx ON sale (cash_session_id);
CREATE INDEX sale_sold_by_idx ON sale (sold_by);
CREATE INDEX sale_customer_idx ON sale (customer_id);

CREATE TABLE sale_item (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  sale_id uuid NOT NULL REFERENCES sale (id),
  line smallint NOT NULL CONSTRAINT sale_item_line_check CHECK (line BETWEEN 1 AND 999),
  product_id uuid NOT NULL REFERENCES product (id),
  barcode_id uuid REFERENCES product_barcode (id),
  -- Em unidades do produto (o PDV já converte o fracionamento do código lido).
  quantity numeric(14, 3) NOT NULL CONSTRAINT sale_item_quantity_check CHECK (quantity > 0),
  unit_price numeric(12, 2) NOT NULL CONSTRAINT sale_item_unit_price_check CHECK (unit_price >= 0),
  -- Preço que a central tinha para a filial na hora da venda (para o alerta de divergência).
  central_price numeric(12, 2),
  discount numeric(12, 2) NOT NULL DEFAULT 0 CONSTRAINT sale_item_discount_check CHECK (discount >= 0),
  total numeric(12, 2) NOT NULL CONSTRAINT sale_item_total_check CHECK (total >= 0),
  -- Lote escolhido no PDV (controlados). Sem ele, a central baixa pelo vencimento mais próximo.
  batch_id uuid REFERENCES product_batch (id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid,
  CONSTRAINT sale_item_values_check CHECK (discount <= round(quantity * unit_price, 2) AND total = round(quantity * unit_price, 2) - discount)
);
CREATE UNIQUE INDEX sale_item_line_key ON sale_item (sale_id, line) WHERE deleted_at IS NULL;
CREATE INDEX sale_item_product_idx ON sale_item (product_id);
CREATE INDEX sale_item_economic_group_id_idx ON sale_item (economic_group_id);
CREATE INDEX sale_item_barcode_idx ON sale_item (barcode_id);
CREATE INDEX sale_item_batch_idx ON sale_item (batch_id);

CREATE TABLE sale_payment (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  sale_id uuid NOT NULL REFERENCES sale (id),
  -- Cartão e PIX registrados à mão (maquininha à parte) até a integração com TEF e PIX.
  method text NOT NULL CONSTRAINT sale_payment_method_check CHECK (
    method IN ('cash', 'credit_card', 'debit_card', 'pix', 'agreement')
  ),
  amount numeric(12, 2) NOT NULL CONSTRAINT sale_payment_amount_check CHECK (amount > 0),
  change_amount numeric(12, 2) NOT NULL DEFAULT 0 CONSTRAINT sale_payment_change_check CHECK (
    change_amount >= 0 AND change_amount < amount AND (change_amount = 0 OR method = 'cash')
  ),
  card_brand text CONSTRAINT sale_payment_card_brand_check CHECK (length(card_brand) <= 30),
  authorization_code text CONSTRAINT sale_payment_authorization_check CHECK (length(authorization_code) <= 30),
  agreement_id uuid REFERENCES agreement (id),
  agreement_registration text CONSTRAINT sale_payment_registration_check CHECK (length(agreement_registration) <= 40),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid,
  CONSTRAINT sale_payment_agreement_check CHECK ((method = 'agreement') = (agreement_id IS NOT NULL))
);
CREATE INDEX sale_payment_sale_idx ON sale_payment (sale_id);
CREATE INDEX sale_payment_economic_group_id_idx ON sale_payment (economic_group_id);
CREATE INDEX sale_payment_agreement_idx ON sale_payment (agreement_id);

-- O que a central achou ao receber a venda. A venda vale; o alerta é para a retaguarda olhar.
CREATE TABLE sale_alert (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  branch_id uuid NOT NULL REFERENCES branch (id),
  sale_id uuid NOT NULL REFERENCES sale (id),
  sale_item_id uuid REFERENCES sale_item (id),
  kind text NOT NULL CONSTRAINT sale_alert_kind_check CHECK (kind IN (
    'price_divergence', 'discount_above_rule', 'discount_above_limit', 'operator_permission',
    'negative_stock', 'product_status', 'agreement_link'
  )),
  detail jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE INDEX sale_alert_sale_idx ON sale_alert (sale_id);
CREATE INDEX sale_alert_branch_idx ON sale_alert (branch_id, created_at DESC);
CREATE INDEX sale_alert_economic_group_id_idx ON sale_alert (economic_group_id);
CREATE INDEX sale_alert_item_idx ON sale_alert (sale_item_id);

CALL app.apply_table_standard('public.cash_session');
CALL app.apply_table_standard('public.sale');
CALL app.apply_table_standard('public.sale_item');
CALL app.apply_table_standard('public.sale_payment');
CALL app.apply_table_standard('public.sale_alert');

-- Venda, itens, pagamentos e alertas são fatos: não mudam depois de gravados.
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON sale
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'branch_id', 'terminal_id', 'cash_session_id', 'number', 'code', 'sold_by', 'customer_id',
    'sold_at', 'fiscal_model', 'subtotal', 'discount_total', 'total'
  );
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON sale_item
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'sale_id', 'line', 'product_id', 'barcode_id', 'quantity', 'unit_price', 'central_price',
    'discount', 'total', 'batch_id'
  );
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON sale_payment
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'sale_id', 'method', 'amount', 'change_amount', 'card_brand', 'authorization_code',
    'agreement_id', 'agreement_registration'
  );
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON sale_alert
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'branch_id', 'sale_id', 'sale_item_id', 'kind', 'detail'
  );
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON cash_session
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'branch_id', 'terminal_id', 'opened_by', 'opened_at', 'opening_float'
  );

-- A baixa da venda aponta para o item vendido.
ALTER TABLE stock_movement
  ADD COLUMN sale_item_id uuid REFERENCES sale_item (id),
  ADD CONSTRAINT stock_movement_sale_item_check CHECK (sale_item_id IS NULL OR movement_type = 'sale');
CREATE INDEX stock_movement_sale_item_idx ON stock_movement (sale_item_id) WHERE sale_item_id IS NOT NULL;
CREATE OR REPLACE VIEW v_stock_movement WITH (security_invoker = true) AS
  SELECT * FROM stock_movement WHERE deleted_at IS NULL;

-- Preço efetivo da filial num instante: a exceção da loja mais recente até ali; sem ela, o da rede.
CREATE FUNCTION app.effective_price_at(p_product_id uuid, p_branch_id uuid, p_at timestamptz) RETURNS numeric
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT COALESCE(
    (SELECT pp.price FROM public.product_price pp
      WHERE pp.product_id = p_product_id AND pp.branch_id = p_branch_id AND pp.deleted_at IS NULL
        AND pp.created_at <= p_at
      ORDER BY pp.created_at DESC, pp.id DESC LIMIT 1),
    (SELECT pp.price FROM public.product_price pp
      WHERE pp.product_id = p_product_id AND pp.branch_id IS NULL AND pp.deleted_at IS NULL
        AND pp.created_at <= p_at
      ORDER BY pp.created_at DESC, pp.id DESC LIMIT 1)
  )
$$;

-- Lotes para a baixa da venda: o vencimento mais próximo primeiro, só com saldo. O que faltar sai
-- do último lote usado (ou do mais novo), deixando o saldo negativo, como a venda permite. Produto
-- que exige lote e ainda não tem nenhum sai sem lote (a regularização fica para a retaguarda).
CREATE FUNCTION app.allocate_sale_batches(p_branch_id uuid, p_product_id uuid, p_quantity numeric)
RETURNS TABLE (batch_id uuid, quantity numeric)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  remaining numeric := p_quantity;
  candidate record;
  last_batch uuid;
BEGIN
  FOR candidate IN
    SELECT pb.id, sb.quantity AS available
      FROM public.product_batch pb
      JOIN public.stock_balance sb ON sb.batch_id = pb.id AND sb.deleted_at IS NULL AND sb.quantity > 0
     WHERE pb.branch_id = p_branch_id AND pb.product_id = p_product_id AND pb.deleted_at IS NULL
     ORDER BY pb.expires_on, pb.batch_number, pb.id
  LOOP
    EXIT WHEN remaining <= 0;
    batch_id := candidate.id;
    quantity := LEAST(remaining, candidate.available);
    remaining := remaining - quantity;
    last_batch := candidate.id;
    RETURN NEXT;
  END LOOP;
  IF remaining > 0 THEN
    IF last_batch IS NULL THEN
      SELECT pb.id INTO last_batch FROM public.product_batch pb
       WHERE pb.branch_id = p_branch_id AND pb.product_id = p_product_id AND pb.deleted_at IS NULL
       ORDER BY pb.expires_on DESC, pb.created_at DESC, pb.id DESC LIMIT 1;
    END IF;
    batch_id := last_batch;
    quantity := remaining;
    RETURN NEXT;
  END IF;
END;
$$;

-- Abertura de turno vinda do PDV.
CREATE FUNCTION app.sync_apply_cash_open(p_terminal public.terminal, p_group_id uuid, p_payload jsonb)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  session_id uuid;
  operator_id uuid;
BEGIN
  IF (p_payload ->> 'id') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
     OR (p_payload ->> 'operator_id') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
     OR (p_payload ->> 'opened_at') !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$'
     OR pg_catalog.jsonb_typeof(p_payload -> 'opening_float') IS DISTINCT FROM 'number'
     OR (p_payload ->> 'opening_float')::numeric NOT BETWEEN 0 AND 9999999999.99
     OR (p_payload ->> 'opening_float')::numeric <> round((p_payload ->> 'opening_float')::numeric, 2) THEN
    RAISE EXCEPTION 'A venda enviada pelo terminal está inconsistente.'
      USING ERRCODE = 'FA962', DETAIL = 'Abertura de turno fora do formato.';
  END IF;
  session_id := (p_payload ->> 'id')::uuid;
  operator_id := (p_payload ->> 'operator_id')::uuid;
  IF EXISTS (SELECT 1 FROM public.cash_session s WHERE s.id = session_id) THEN
    RAISE EXCEPTION 'Esta venda ou turno já foi recebido com outro registro.'
      USING ERRCODE = 'FA963', DETAIL = pg_catalog.format('cash_session %s.', session_id);
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.user_account u WHERE u.id = operator_id AND u.economic_group_id = p_group_id
  ) THEN
    RAISE EXCEPTION 'Um dos itens informados não foi encontrado.'
      USING ERRCODE = 'FA004', DETAIL = pg_catalog.format('Operador %s.', operator_id);
  END IF;
  BEGIN
    INSERT INTO public.cash_session (id, economic_group_id, branch_id, terminal_id, opened_by, opened_at, opening_float)
    VALUES (session_id, p_group_id, p_terminal.branch_id, p_terminal.id, operator_id,
            (p_payload ->> 'opened_at')::timestamptz, (p_payload ->> 'opening_float')::numeric);
  EXCEPTION WHEN datetime_field_overflow OR invalid_datetime_format THEN
    RAISE EXCEPTION 'A venda enviada pelo terminal está inconsistente.'
      USING ERRCODE = 'FA962', DETAIL = 'Data de abertura impossível.';
  END;
END;
$$;

-- Venda vinda do PDV. Fora do formato ou com totais que não fecham: conflito (FA962). Venda
-- conferida: aplicada, com alertas para o que merece atenção.
CREATE FUNCTION app.sync_apply_sale(p_terminal public.terminal, p_group_id uuid, p_payload jsonb)
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
BEGIN
  -- Forma geral.
  IF (p_payload ->> 'id') !~ uuid_v7
     OR (p_payload ->> 'cash_session_id') !~ uuid_any
     OR (p_payload ->> 'operator_id') !~ uuid_any
     OR (p_payload ->> 'customer_id') !~ uuid_any
     OR (p_payload ->> 'number') !~ '^[1-9][0-9]{0,8}$'
     OR p_payload ->> 'sold_at' IS NULL
     OR (p_payload ->> 'sold_at') !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$'
     OR (p_payload ->> 'fiscal_model') NOT IN ('65', '55')
     OR pg_catalog.jsonb_typeof(p_payload -> 'items') IS DISTINCT FROM 'array'
     OR pg_catalog.jsonb_array_length(p_payload -> 'items') NOT BETWEEN 1 AND 999
     OR pg_catalog.jsonb_typeof(p_payload -> 'payments') IS DISTINCT FROM 'array'
     OR pg_catalog.jsonb_array_length(p_payload -> 'payments') NOT BETWEEN 1 AND 20
     OR (p_payload ->> 'subtotal') !~ money OR (p_payload ->> 'discount_total') !~ money
     OR (p_payload ->> 'total') !~ money THEN
    RAISE EXCEPTION 'A venda enviada pelo terminal está inconsistente.'
      USING ERRCODE = 'FA962', DETAIL = 'Venda fora do formato.';
  END IF;
  sale_id := (p_payload ->> 'id')::uuid;
  operator_id := (p_payload ->> 'operator_id')::uuid;
  buyer_id := (p_payload ->> 'customer_id')::uuid;
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
     )) THEN
    RAISE EXCEPTION 'Um dos itens informados não foi encontrado.'
      USING ERRCODE = 'FA004', DETAIL = 'Operador ou cliente fora do grupo.';
  END IF;

  -- Itens: forma, produto do grupo e contas.
  FOR item IN SELECT value FROM pg_catalog.jsonb_array_elements(p_payload -> 'items') LOOP
    IF pg_catalog.jsonb_typeof(item) IS DISTINCT FROM 'object'
       OR (item ->> 'id') !~ uuid_v7 OR (item ->> 'product_id') !~ uuid_any
       OR (item ->> 'barcode_id') !~ uuid_any OR (item ->> 'batch_id') !~ uuid_any
       OR (item ->> 'line') !~ '^[1-9][0-9]{0,2}$'
       OR (item ->> 'quantity') !~ '^\d{1,11}(\.\d{1,3})?$' OR (item ->> 'quantity')::numeric <= 0
       OR (item ->> 'unit_price') !~ money OR (item ->> 'discount') !~ money OR (item ->> 'total') !~ money
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
    line_gross := round((item ->> 'quantity')::numeric * (item ->> 'unit_price')::numeric, 2);
    IF (item ->> 'discount')::numeric > line_gross
       OR (item ->> 'total')::numeric <> line_gross - (item ->> 'discount')::numeric THEN
      RAISE EXCEPTION 'A venda enviada pelo terminal está inconsistente.'
        USING ERRCODE = 'FA962', DETAIL = pg_catalog.format('Conta do item da linha %s.', item ->> 'line');
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
       OR (payment ->> 'method') NOT IN ('cash', 'credit_card', 'debit_card', 'pix', 'agreement')
       OR (payment ->> 'amount') !~ money OR (payment ->> 'amount')::numeric <= 0
       OR (payment ->> 'change') !~ money
       OR COALESCE((payment ->> 'change')::numeric, 0) >= (payment ->> 'amount')::numeric
       OR (COALESCE((payment ->> 'change')::numeric, 0) > 0 AND payment ->> 'method' <> 'cash')
       OR pg_catalog.length(payment ->> 'card_brand') > 30 OR pg_catalog.length(payment ->> 'authorization_code') > 30
       OR (payment ->> 'agreement_id') !~ uuid_any OR pg_catalog.length(payment ->> 'agreement_registration') > 40
       OR ((payment ->> 'method') = 'agreement') <> (payment ->> 'agreement_id' IS NOT NULL) THEN
      RAISE EXCEPTION 'A venda enviada pelo terminal está inconsistente.'
        USING ERRCODE = 'FA962', DETAIL = 'Pagamento fora do formato.';
    END IF;
    IF payment ->> 'agreement_id' IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.agreement a WHERE a.id = (payment ->> 'agreement_id')::uuid AND a.economic_group_id = p_group_id
    ) THEN
      RAISE EXCEPTION 'Um dos itens informados não foi encontrado.'
        USING ERRCODE = 'FA004', DETAIL = 'Convênio fora do grupo.';
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
    fiscal_model, subtotal, discount_total, total
  ) VALUES (
    sale_id, p_group_id, p_terminal.branch_id, p_terminal.id, (p_payload ->> 'cash_session_id')::uuid,
    (p_payload ->> 'number')::bigint,
    terminal_number || '-' || pg_catalog.lpad(p_payload ->> 'number', 6, '0'),
    operator_id, buyer_id, sale_at, p_payload ->> 'fiscal_model', sum_gross, sum_discount, sum_items
  );

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
      id, economic_group_id, sale_id, line, product_id, barcode_id, quantity, unit_price, central_price, discount, total, batch_id
    ) VALUES (
      item_id, p_group_id, sale_id, (item ->> 'line')::smallint, product_row.id, (item ->> 'barcode_id')::uuid,
      (item ->> 'quantity')::numeric, (item ->> 'unit_price')::numeric, central, (item ->> 'discount')::numeric,
      (item ->> 'total')::numeric, (item ->> 'batch_id')::uuid
    );

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

    -- Desconto: regra do produto e limite do operador, com a liberação feita no PDV.
    IF (item ->> 'discount')::numeric > 0 THEN
      line_gross := round((item ->> 'quantity')::numeric * (item ->> 'unit_price')::numeric, 2);
      percent := round((item ->> 'discount')::numeric * 100 / line_gross, 4);
      SELECT r.value INTO rule_max FROM app.resolve_product_rule('max_discount', product_row.id, p_terminal.branch_id, sale_at) r;
      IF rule_max IS NOT NULL AND percent > rule_max
         AND NOT app.user_has_permission(operator_id, 'sales.discount_override', p_terminal.branch_id) THEN
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

  FOR payment IN SELECT value FROM pg_catalog.jsonb_array_elements(p_payload -> 'payments') LOOP
    INSERT INTO public.sale_payment (
      id, economic_group_id, sale_id, method, amount, change_amount, card_brand, authorization_code, agreement_id,
      agreement_registration
    ) VALUES (
      (payment ->> 'id')::uuid, p_group_id, sale_id, payment ->> 'method', (payment ->> 'amount')::numeric,
      COALESCE((payment ->> 'change')::numeric, 0), NULLIF(pg_catalog.btrim(payment ->> 'card_brand'), ''),
      NULLIF(pg_catalog.btrim(payment ->> 'authorization_code'), ''), (payment ->> 'agreement_id')::uuid,
      NULLIF(pg_catalog.btrim(payment ->> 'agreement_registration'), '')
    );
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

-- Vendas para a retaguarda, com o número de alertas. Até 500, mais recentes primeiro.
CREATE FUNCTION app.list_sales(p_branch_id uuid DEFAULT NULL, p_from date DEFAULT NULL, p_to date DEFAULT NULL)
RETURNS TABLE (
  id uuid, code text, branch_id uuid, branch_name text, terminal_name text, sold_at timestamptz, operator_name text,
  customer_name text, total numeric, item_count integer, payment_methods text[], fiscal_status text, alert_count integer
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT s.id, s.code, s.branch_id, b.name, t.name, s.sold_at, u.name, c.name, s.total,
         (SELECT pg_catalog.count(*)::integer FROM public.sale_item i WHERE i.sale_id = s.id AND i.deleted_at IS NULL),
         ARRAY(SELECT DISTINCT p.method FROM public.sale_payment p WHERE p.sale_id = s.id AND p.deleted_at IS NULL ORDER BY 1),
         s.fiscal_status,
         (SELECT pg_catalog.count(*)::integer FROM public.sale_alert a WHERE a.sale_id = s.id AND a.deleted_at IS NULL)
    FROM public.sale s
    JOIN public.branch b ON b.id = s.branch_id
    JOIN public.terminal t ON t.id = s.terminal_id
    JOIN public.user_account u ON u.id = s.sold_by
    LEFT JOIN public.customer c ON c.id = s.customer_id
   WHERE s.deleted_at IS NULL
     AND s.economic_group_id = app.current_user_group()
     AND app.has_permission('sales.view', s.branch_id)
     AND (p_branch_id IS NULL OR s.branch_id = p_branch_id)
     AND (p_from IS NULL OR s.sold_at >= p_from::timestamp AT TIME ZONE 'America/Sao_Paulo')
     AND (p_to IS NULL OR s.sold_at < (p_to + 1)::timestamp AT TIME ZONE 'America/Sao_Paulo')
   ORDER BY s.sold_at DESC, s.id DESC
   LIMIT 500
$$;

-- Venda completa: itens, pagamentos, baixas de estoque e alertas.
CREATE FUNCTION app.sale_detail(p_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT pg_catalog.jsonb_build_object(
    'id', s.id, 'code', s.code, 'branch_name', b.name, 'terminal_name', t.name, 'sold_at', s.sold_at,
    'operator_name', u.name, 'customer_name', c.name, 'customer_code', c.code, 'fiscal_model', s.fiscal_model,
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
    (p_group_id, 'Farmacêutico', 'As permissões chegam com o SNGPC.'),
    (p_group_id, 'Operador de caixa', 'As permissões chegam com o PDV.');

  -- A liberação do custo e o desconto acima do produto ficam só com o Administrador.
  INSERT INTO public.role_permission (role_id, permission_id)
  SELECT manager_id, p.id
    FROM public.permission p
   WHERE p.code IN (
     'users.view', 'users.reset_password', 'terminals.view', 'terminals.request', 'terminals.block',
     'products.view', 'stock.view', 'stock.loss', 'stock.transfer', 'stock.batch_override',
     'customers.view', 'customers.manage', 'fiscal.certificate', 'purchases.view', 'purchases.manage',
     'purchases.post', 'releases.view', 'sync.view', 'sync.resolve', 'sales.sell', 'sales.view'
   );
  INSERT INTO public.role_permission (role_id, permission_id)
  SELECT r.id, p.id
    FROM public.role r
    JOIN public.permission p ON p.code = 'sales.sell'
   WHERE r.economic_group_id = p_group_id AND r.name = 'Operador de caixa';
  PERFORM app.seed_manager_limits(manager_id, p_group_id);
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
        WHEN 'cash_session_open' THEN
          PERFORM app.sync_apply_cash_open(terminal_row, group_id, item -> 'payload');
        WHEN 'sale' THEN
          PERFORM app.sync_apply_sale(terminal_row, group_id, item -> 'payload');
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

-- Grupos que já existem: o Operador de caixa vende; o Gerente vende e vê as vendas.
INSERT INTO role_permission (role_id, permission_id)
SELECT r.id, p.id
  FROM role r
 CROSS JOIN permission p
 WHERE r.deleted_at IS NULL AND r.system_key IS NULL
   AND ((r.name = 'Operador de caixa' AND p.code = 'sales.sell')
        OR (r.name = 'Gerente' AND p.code IN ('sales.sell', 'sales.view')))
   AND NOT EXISTS (
     SELECT 1 FROM role_permission rp WHERE rp.role_id = r.id AND rp.permission_id = p.id AND rp.deleted_at IS NULL
   );

-- Leitura para quem vê as vendas da filial; escrita só pelas funções.
CREATE POLICY cash_session_select ON cash_session FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group()) AND app.has_permission('sales.view', branch_id));
CREATE POLICY sale_select ON sale FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group()) AND app.has_permission('sales.view', branch_id));
CREATE POLICY sale_item_select ON sale_item FOR SELECT TO farmaerp_app
  USING (EXISTS (SELECT 1 FROM sale s WHERE s.id = sale_id));
CREATE POLICY sale_payment_select ON sale_payment FOR SELECT TO farmaerp_app
  USING (EXISTS (SELECT 1 FROM sale s WHERE s.id = sale_id));
CREATE POLICY sale_alert_select ON sale_alert FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group()) AND app.has_permission('sales.view', branch_id));
GRANT SELECT ON cash_session, sale, sale_item, sale_payment, sale_alert TO farmaerp_app;

CREATE VIEW v_cash_session WITH (security_invoker = true) AS SELECT * FROM cash_session WHERE deleted_at IS NULL;
CREATE VIEW v_sale WITH (security_invoker = true) AS SELECT * FROM sale WHERE deleted_at IS NULL;
CREATE VIEW v_sale_item WITH (security_invoker = true) AS SELECT * FROM sale_item WHERE deleted_at IS NULL;
CREATE VIEW v_sale_payment WITH (security_invoker = true) AS SELECT * FROM sale_payment WHERE deleted_at IS NULL;
CREATE VIEW v_sale_alert WITH (security_invoker = true) AS SELECT * FROM sale_alert WHERE deleted_at IS NULL;
GRANT SELECT ON v_cash_session, v_sale, v_sale_item, v_sale_payment, v_sale_alert TO farmaerp_app;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  app.effective_price_at(uuid, uuid, timestamptz),
  app.list_sales(uuid, date, date),
  app.sale_detail(uuid)
TO farmaerp_app;
