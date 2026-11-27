-- Up Migration

-- Parte C do lote de 26/11: orçamento igual ao caixa, venda com estoque negativo e orçamentos
-- juntados no caixa.
-- 1. Estoque negativo: sempre liberável (com ou sem internet). Quem tem "Vender com estoque
--    negativo" (a permissão sales.zero_stock_release, renomeada) vende direto; quem não tem chama o
--    supervisor no PDV. O orçamento pede a liberação ao incluir o item e ela vai no item; no caixa,
--    o item que veio liberado não pede de novo. A venda guarda o alerta com quem liberou e o saldo.
-- 2. Vários orçamentos numa venda: cada item com o vendedor e o orçamento de origem; todos os
--    orçamentos juntados viram a venda.

UPDATE permission SET name = 'Vender com estoque negativo' WHERE code = 'sales.zero_stock_release';

-- Liberação do estoque negativo no orçamento (quem liberou e o saldo da hora).
ALTER TABLE quote_item ADD COLUMN stock_released_by uuid REFERENCES user_account (id);
ALTER TABLE quote_item ADD COLUMN stock_release_balance numeric(12, 3);
ALTER TABLE quote_item ADD CONSTRAINT quote_item_stock_release_check
  CHECK (stock_release_balance IS NULL OR stock_released_by IS NOT NULL);
CREATE INDEX quote_item_stock_released_by_idx ON quote_item (stock_released_by);

-- Item da venda: quem vendeu (orçamentos juntados têm vendedores diferentes) e o orçamento de origem.
ALTER TABLE sale_item ADD COLUMN seller_id uuid REFERENCES user_account (id);
ALTER TABLE sale_item ADD COLUMN quote_id uuid REFERENCES quote (id);
CREATE INDEX sale_item_seller_idx ON sale_item (seller_id);
CREATE INDEX sale_item_quote_idx ON sale_item (quote_id);
-- Itens antigos: o vendedor e o orçamento da venda.
UPDATE sale_item i SET seller_id = s.seller_id, quote_id = s.quote_id
  FROM sale s WHERE s.id = i.sale_id AND (s.seller_id IS NOT NULL OR s.quote_id IS NOT NULL);

CREATE OR REPLACE FUNCTION app.sync_apply_quote(p_terminal public.terminal, p_group_id uuid, p_payload jsonb)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  uuid_v7 constant text := '^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$';
  uuid_any constant text := '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
  money constant text := '^\d{1,10}(\.\d{1,2})?$';
  quote_id uuid;
  quote_at timestamptz;
  seller uuid;
  buyer uuid;
  card integer;
  item jsonb;
  line_gross numeric;
  sum_gross numeric := 0;
  sum_discount numeric := 0;
  sum_items numeric := 0;
  lines integer[] := '{}';
  terminal_number smallint;
  validity smallint;
  expiry timestamptz;
  newer uuid;
BEGIN
  IF (p_payload ->> 'id') !~ uuid_v7
     OR (p_payload ->> 'number') !~ '^[1-9][0-9]{0,8}$'
     OR (p_payload ->> 'seller_id') IS NULL OR (p_payload ->> 'seller_id') !~ uuid_any
     OR (p_payload ->> 'customer_id') !~ uuid_any
     OR (p_payload -> 'card_number' IS NOT NULL AND p_payload -> 'card_number' <> 'null'::jsonb
         AND (pg_catalog.jsonb_typeof(p_payload -> 'card_number') <> 'number' OR (p_payload ->> 'card_number') !~ '^[1-9][0-9]{0,3}$'))
     OR (p_payload ->> 'quoted_at') IS NULL
     OR (p_payload ->> 'quoted_at') !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$'
     OR pg_catalog.jsonb_typeof(p_payload -> 'items') IS DISTINCT FROM 'array'
     OR pg_catalog.jsonb_array_length(p_payload -> 'items') NOT BETWEEN 1 AND 999
     OR (p_payload ->> 'subtotal') !~ money OR (p_payload ->> 'discount_total') !~ money
     OR (p_payload ->> 'total') !~ money THEN
    RAISE EXCEPTION 'O orçamento enviado pelo terminal está inconsistente.'
      USING ERRCODE = 'FA883', DETAIL = 'Orçamento fora do formato.';
  END IF;
  quote_id := (p_payload ->> 'id')::uuid;
  seller := (p_payload ->> 'seller_id')::uuid;
  buyer := (p_payload ->> 'customer_id')::uuid;
  card := (p_payload ->> 'card_number')::integer;
  BEGIN
    quote_at := (p_payload ->> 'quoted_at')::timestamptz;
  EXCEPTION WHEN datetime_field_overflow OR invalid_datetime_format THEN
    RAISE EXCEPTION 'O orçamento enviado pelo terminal está inconsistente.'
      USING ERRCODE = 'FA883', DETAIL = 'Data do orçamento impossível.';
  END;
  IF EXISTS (SELECT 1 FROM public.quote q WHERE q.id = quote_id)
     OR EXISTS (
       SELECT 1 FROM public.quote q
        WHERE q.terminal_id = p_terminal.id AND q.number = (p_payload ->> 'number')::bigint AND q.deleted_at IS NULL
     ) THEN
    RAISE EXCEPTION 'O orçamento enviado pelo terminal está inconsistente.'
      USING ERRCODE = 'FA883', DETAIL = pg_catalog.format('Orçamento %s, número %s, repetido.', quote_id, p_payload ->> 'number');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.user_account u WHERE u.id = seller AND u.economic_group_id = p_group_id)
     OR (buyer IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM public.customer c WHERE c.id = buyer AND c.economic_group_id = p_group_id
     )) THEN
    RAISE EXCEPTION 'Um dos itens informados não foi encontrado.'
      USING ERRCODE = 'FA004', DETAIL = 'Vendedor ou cliente fora do grupo.';
  END IF;

  FOR item IN SELECT value FROM pg_catalog.jsonb_array_elements(p_payload -> 'items') LOOP
    IF pg_catalog.jsonb_typeof(item) IS DISTINCT FROM 'object'
       OR (item ->> 'id') !~ uuid_v7 OR (item ->> 'product_id') !~ uuid_any
       OR (item ->> 'line') !~ '^[1-9][0-9]{0,2}$'
       OR (item ->> 'quantity') !~ '^\d{1,9}(\.\d{1,3})?$' OR (item ->> 'quantity')::numeric <= 0
       OR (item ->> 'unit_price') !~ money OR (item ->> 'discount') !~ money OR (item ->> 'total') !~ money
       OR (item -> 'release' IS NOT NULL AND item -> 'release' <> 'null'::jsonb AND (
            pg_catalog.jsonb_typeof(item -> 'release') <> 'object'
            OR (item -> 'release' ->> 'supervisor_id') !~ uuid_any
            OR pg_catalog.btrim(COALESCE(item -> 'release' ->> 'reason', '')) = ''
          ))
       OR (item -> 'zero_stock_release' IS NOT NULL AND item -> 'zero_stock_release' <> 'null'::jsonb AND (
            pg_catalog.jsonb_typeof(item -> 'zero_stock_release') <> 'object'
            OR item -> 'zero_stock_release' ->> 'supervisor_id' IS NULL
            OR (item -> 'zero_stock_release' ->> 'supervisor_id') !~ uuid_any
            OR (item -> 'zero_stock_release' ->> 'stock') !~ '^-?\d{1,9}(\.\d{1,3})?$'
          )) THEN
      RAISE EXCEPTION 'O orçamento enviado pelo terminal está inconsistente.'
        USING ERRCODE = 'FA883', DETAIL = 'Item do orçamento fora do formato.';
    END IF;
    IF (item ->> 'line')::integer = ANY (lines) THEN
      RAISE EXCEPTION 'O orçamento enviado pelo terminal está inconsistente.'
        USING ERRCODE = 'FA883', DETAIL = 'Linha repetida.';
    END IF;
    lines := lines || (item ->> 'line')::integer;
    IF NOT EXISTS (
         SELECT 1 FROM public.product p WHERE p.id = (item ->> 'product_id')::uuid AND p.economic_group_id = p_group_id
       )
       OR (item -> 'release' ->> 'supervisor_id' IS NOT NULL AND NOT EXISTS (
         SELECT 1 FROM public.user_account u
          WHERE u.id = (item -> 'release' ->> 'supervisor_id')::uuid AND u.economic_group_id = p_group_id
       ))
       OR (item -> 'zero_stock_release' ->> 'supervisor_id' IS NOT NULL AND NOT EXISTS (
         SELECT 1 FROM public.user_account u
          WHERE u.id = (item -> 'zero_stock_release' ->> 'supervisor_id')::uuid AND u.economic_group_id = p_group_id
       )) THEN
      RAISE EXCEPTION 'Um dos itens informados não foi encontrado.'
        USING ERRCODE = 'FA004', DETAIL = 'Produto ou supervisor fora do grupo.';
    END IF;
    line_gross := round((item ->> 'quantity')::numeric * (item ->> 'unit_price')::numeric, 2);
    IF (item ->> 'discount')::numeric > line_gross
       OR (item ->> 'total')::numeric <> line_gross - (item ->> 'discount')::numeric THEN
      RAISE EXCEPTION 'O orçamento enviado pelo terminal está inconsistente.'
        USING ERRCODE = 'FA883', DETAIL = pg_catalog.format('Contas do item da linha %s.', item ->> 'line');
    END IF;
    sum_gross := sum_gross + line_gross;
    sum_discount := sum_discount + (item ->> 'discount')::numeric;
    sum_items := sum_items + (item ->> 'total')::numeric;
  END LOOP;
  IF sum_gross <> (p_payload ->> 'subtotal')::numeric OR sum_discount <> (p_payload ->> 'discount_total')::numeric
     OR sum_items <> (p_payload ->> 'total')::numeric THEN
    RAISE EXCEPTION 'O orçamento enviado pelo terminal está inconsistente.'
      USING ERRCODE = 'FA883', DETAIL = 'Totais do orçamento não fecham.';
  END IF;

  -- Validade: até o fim do dia da loja, mais os dias da filial.
  SELECT b.quote_validity_days INTO validity FROM public.branch b WHERE b.id = p_terminal.branch_id;
  expiry := (((quote_at AT TIME ZONE 'America/Sao_Paulo')::date + validity + 1)::timestamp) AT TIME ZONE 'America/Sao_Paulo';

  -- Plaquinha: se já há orçamento aberto mais novo com ela, este chega substituído; senão, ele
  -- substitui os abertos mais antigos (ou os marca vencidos).
  IF card IS NOT NULL THEN
    SELECT q.id INTO newer FROM public.quote q
     WHERE q.branch_id = p_terminal.branch_id AND q.card_number = card AND q.status = 'open' AND q.deleted_at IS NULL
       AND q.quoted_at > quote_at;
    IF newer IS NULL THEN
      UPDATE public.quote q
         SET status = CASE WHEN q.expires_at <= quote_at THEN 'expired' ELSE 'replaced' END,
             replaced_by = CASE WHEN q.expires_at <= quote_at THEN NULL ELSE quote_id END
       WHERE q.branch_id = p_terminal.branch_id AND q.card_number = card AND q.status = 'open' AND q.deleted_at IS NULL;
    END IF;
  END IF;

  SELECT t.number INTO terminal_number FROM public.terminal t WHERE t.id = p_terminal.id;
  INSERT INTO public.quote (
    id, economic_group_id, branch_id, terminal_id, number, code, seller_id, customer_id, card_number, status,
    quoted_at, expires_at, subtotal, discount_total, total, replaced_by
  ) VALUES (
    quote_id, p_group_id, p_terminal.branch_id, p_terminal.id, (p_payload ->> 'number')::bigint,
    'O' || terminal_number || '-' || pg_catalog.lpad(p_payload ->> 'number', 6, '0'),
    seller, buyer, card, CASE WHEN newer IS NULL THEN 'open' ELSE 'replaced' END,
    quote_at, expiry, sum_gross, sum_discount, sum_items, newer
  );
  INSERT INTO public.quote_item (
    id, economic_group_id, quote_id, line, product_id, quantity, unit_price, discount, total, released_by, release_reason,
    stock_released_by, stock_release_balance
  )
  SELECT (value ->> 'id')::uuid, p_group_id, quote_id, (value ->> 'line')::smallint, (value ->> 'product_id')::uuid,
         (value ->> 'quantity')::numeric, (value ->> 'unit_price')::numeric, (value ->> 'discount')::numeric,
         (value ->> 'total')::numeric, (value -> 'release' ->> 'supervisor_id')::uuid,
         NULLIF(pg_catalog.btrim(value -> 'release' ->> 'reason'), ''),
         (value -> 'zero_stock_release' ->> 'supervisor_id')::uuid, (value -> 'zero_stock_release' ->> 'stock')::numeric
    FROM pg_catalog.jsonb_array_elements(p_payload -> 'items');
END;
$$;


CREATE OR REPLACE FUNCTION app.pdv_quote(p_key text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  terminal_row public.terminal := app.require_active_terminal();
  key text := pg_catalog.upper(pg_catalog.btrim(COALESCE(p_key, '')));
  found_quote public.quote;
BEGIN
  IF key ~ '^[0-9]{1,4}$' THEN
    SELECT q.* INTO found_quote FROM public.quote q
     WHERE q.branch_id = terminal_row.branch_id AND q.card_number = key::integer AND q.status = 'open' AND q.deleted_at IS NULL;
  ELSIF key ~ '^O[0-9]+-[0-9]{6,}$' THEN
    SELECT q.* INTO found_quote FROM public.quote q
     WHERE q.branch_id = terminal_row.branch_id AND q.code = key AND q.deleted_at IS NULL;
  END IF;
  IF found_quote.id IS NULL OR found_quote.status = 'cancelled' THEN
    RAISE EXCEPTION 'Orçamento não encontrado nesta loja.'
      USING ERRCODE = 'FA885', DETAIL = pg_catalog.format('Chave %s.', key);
  END IF;
  IF found_quote.status = 'converted' THEN
    RAISE EXCEPTION 'Este orçamento já virou venda.'
      USING ERRCODE = 'FA886', DETAIL = found_quote.code;
  END IF;
  IF found_quote.status = 'replaced' THEN
    RAISE EXCEPTION 'A plaquinha deste orçamento foi usada em outro orçamento.'
      USING ERRCODE = 'FA888', DETAIL = found_quote.code;
  END IF;
  IF found_quote.status = 'expired' OR found_quote.expires_at <= pg_catalog.now() THEN
    RAISE EXCEPTION 'Este orçamento venceu.'
      USING ERRCODE = 'FA887', DETAIL = found_quote.code;
  END IF;
  RETURN pg_catalog.jsonb_build_object(
    'id', found_quote.id, 'code', found_quote.code, 'card_number', found_quote.card_number,
    'seller_id', found_quote.seller_id, 'customer_id', found_quote.customer_id, 'expires_at', found_quote.expires_at,
    'total', found_quote.total,
    'items', (
      SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'line', i.line, 'product_id', i.product_id, 'quantity', i.quantity, 'unit_price', i.unit_price,
        'discount', i.discount, 'total', i.total,
        'release', CASE WHEN i.released_by IS NULL THEN NULL
                        ELSE pg_catalog.jsonb_build_object('supervisor_id', i.released_by, 'reason', i.release_reason) END,
        'zero_stock_release', CASE WHEN i.stock_released_by IS NULL THEN NULL
                                   ELSE pg_catalog.jsonb_build_object('supervisor_id', i.stock_released_by, 'stock', i.stock_release_balance) END
      ) ORDER BY i.line)
        FROM public.quote_item i WHERE i.quote_id = found_quote.id AND i.deleted_at IS NULL
    )
  );
END;
$$;


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
  merged uuid;
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
         OR (item -> 'zero_stock_release' ->> 'stock') !~ '^-?\d{1,9}(\.\d{1,3})?$'
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
    -- Item de orçamento juntado no caixa: o vendedor e o orçamento de origem.
    IF (item ->> 'seller_id') !~ uuid_any OR (item ->> 'quote_id') !~ uuid_any THEN
      RAISE EXCEPTION 'A venda enviada pelo terminal está inconsistente.'
        USING ERRCODE = 'FA962', DETAIL = pg_catalog.format('Vendedor ou orçamento do item da linha %s.', item ->> 'line');
    END IF;
    IF (item ->> 'seller_id' IS NOT NULL AND NOT EXISTS (
         SELECT 1 FROM public.user_account u WHERE u.id = (item ->> 'seller_id')::uuid AND u.economic_group_id = p_group_id
       ))
       OR (item ->> 'quote_id' IS NOT NULL AND NOT EXISTS (
         SELECT 1 FROM public.quote q WHERE q.id = (item ->> 'quote_id')::uuid AND q.economic_group_id = p_group_id
       )) THEN
      RAISE EXCEPTION 'Um dos itens informados não foi encontrado.'
        USING ERRCODE = 'FA004', DETAIL = 'Vendedor ou orçamento do item fora do grupo.';
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
       OR (payment ->> 'method') NOT IN ('cash', 'credit_card', 'debit_card', 'pix', 'agreement', 'return_credit', 'store_credit', 'cashback')
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
       OR (payment ->> 'reservation_id') !~ uuid_any
       OR ((payment ->> 'method') = 'cashback') <> (payment ->> 'reservation_id' IS NOT NULL)
       OR (payment ->> 'method' = 'cashback' AND buyer_id IS NULL)
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
  -- Orçamentos juntados no caixa: todos (o da venda e os dos itens) viram esta venda.
  FOR merged IN
    SELECT DISTINCT x.quote_id FROM (
      SELECT from_quote AS quote_id
      UNION ALL
      SELECT (value ->> 'quote_id')::uuid FROM pg_catalog.jsonb_array_elements(p_payload -> 'items')
    ) x WHERE x.quote_id IS NOT NULL
  LOOP
    SELECT q.* INTO quote_row FROM public.quote q WHERE q.id = merged FOR UPDATE;
    IF quote_row.status = 'open' AND quote_row.expires_at > sale_at AND quote_row.branch_id = p_terminal.branch_id THEN
      UPDATE public.quote SET status = 'converted', converted_sale_id = sale_id WHERE id = merged;
    ELSE
      INSERT INTO public.sale_alert (economic_group_id, branch_id, sale_id, kind, detail)
      VALUES (p_group_id, p_terminal.branch_id, sale_id, 'quote_status', pg_catalog.jsonb_build_object(
        'quote_code', quote_row.code,
        'status', CASE WHEN quote_row.branch_id <> p_terminal.branch_id THEN 'other_branch'
                       WHEN quote_row.status = 'open' THEN 'expired' ELSE quote_row.status END
      ));
    END IF;
  END LOOP;
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
      auto_discount, seller_id, quote_id
    ) VALUES (
      item_id, p_group_id, sale_id, (item ->> 'line')::smallint, product_row.id, (item ->> 'barcode_id')::uuid,
      (item ->> 'quantity')::numeric, (item ->> 'unit_price')::numeric, central, (item ->> 'discount')::numeric,
      (item ->> 'total')::numeric, (item ->> 'batch_id')::uuid, COALESCE((item ->> 'auto_discount')::numeric, 0),
      COALESCE((item ->> 'seller_id')::uuid, seller), (item ->> 'quote_id')::uuid
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

    -- Venda com estoque negativo liberada (quem vendeu com a permissão ou o supervisor; com ou sem
    -- internet): fica o registro completo, com o saldo da hora.
    IF item -> 'zero_stock_release' ->> 'supervisor_id' IS NOT NULL THEN
      INSERT INTO public.sale_alert (economic_group_id, branch_id, sale_id, sale_item_id, kind, detail)
      VALUES (p_group_id, p_terminal.branch_id, sale_id, item_id, 'offline_zero_stock', pg_catalog.jsonb_build_object(
        'supervisor_id', (item -> 'zero_stock_release' ->> 'supervisor_id')::uuid,
        'supervisor_allowed', app.user_has_permission(
          (item -> 'zero_stock_release' ->> 'supervisor_id')::uuid, 'sales.zero_stock_release', p_terminal.branch_id),
        'minutes_offline', (item -> 'zero_stock_release' ->> 'minutes_offline')::integer,
        'stock', (item -> 'zero_stock_release' ->> 'stock')::numeric
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
        WHEN credit_used > credit.refund_amount THEN 'balance'
      END;
      IF credit_problem IS NOT NULL THEN
        INSERT INTO public.sale_alert (economic_group_id, branch_id, sale_id, kind, detail)
        VALUES (p_group_id, p_terminal.branch_id, sale_id, 'return_credit', pg_catalog.jsonb_build_object(
          'return_code', credit.code, 'problem', credit_problem, 'amount', (payment ->> 'amount')::numeric,
          'balance', credit.refund_amount - (credit_used - (payment ->> 'amount')::numeric)
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
    ELSIF payment ->> 'agreement_id' IS NOT NULL AND app.agreement_used(buyer_id, (payment ->> 'agreement_id')::uuid) > (
      SELECT ca.credit_limit FROM public.customer_agreement ca
       WHERE ca.customer_id = buyer_id AND ca.agreement_id = (payment ->> 'agreement_id')::uuid AND ca.deleted_at IS NULL
       ORDER BY ca.created_at DESC LIMIT 1
    ) THEN
      INSERT INTO public.sale_alert (economic_group_id, branch_id, sale_id, kind, detail)
      VALUES (p_group_id, p_terminal.branch_id, sale_id, 'agreement_limit', pg_catalog.jsonb_build_object(
        'agreement_id', payment ->> 'agreement_id', 'amount', (payment ->> 'amount')::numeric,
        'used', app.agreement_used(buyer_id, (payment ->> 'agreement_id')::uuid)));
    END IF;
  END LOOP;
  PERFORM app.cashback_record_sale(p_group_id, p_terminal.branch_id, sale_id, buyer_id, sale_at, p_payload);
END;
$$;


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
    'received_at', s.created_at, 'coupon', s.coupon,
    'items', (
      SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', i.id, 'line', i.line, 'product_id', i.product_id, 'product_code', p.code, 'product_name', p.display_name,
        'quantity', i.quantity, 'unit_price', i.unit_price, 'central_price', i.central_price, 'discount', i.discount,
        'auto_discount', i.auto_discount, 'total', i.total,
        'seller_name', (SELECT us.name FROM public.user_account us WHERE us.id = i.seller_id),
        'quote_code', (SELECT q.code FROM public.quote q WHERE q.id = i.quote_id),
        'discount_rules', COALESCE((
          SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('rule_id', d.discount_rule_id, 'name', r.name, 'amount', d.amount) ORDER BY r.name)
            FROM public.sale_item_discount d JOIN public.discount_rule r ON r.id = d.discount_rule_id
           WHERE d.sale_item_id = i.id AND d.deleted_at IS NULL
        ), '[]'::jsonb),
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
        'authorization_code', p.authorization_code, 'agreement_name', a.name, 'agreement_registration', p.agreement_registration,
        'return_id', p.return_id, 'return_code', (SELECT r.code FROM public.sale_return r WHERE r.id = p.return_id)
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
