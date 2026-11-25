-- Up Migration

-- Etapa 7, PR 7C-1: cashback (banco e retaguarda).
-- O percentual vem do motor de regras (tipo "cashback", por produto, família, categoria... ou loja).
-- Só com o consentimento de cashback do cliente na hora da venda. O ganho é sobre o valor pago,
-- sem a parte paga com cashback. Cada ganho é um lote com carência e validade; o uso abate dos
-- lotes que vencem antes; o vencido sai do saldo por um lançamento de expiração. Nada é apagado:
-- o extrato é a soma dos lançamentos.
-- O uso é só com internet: o PDV reserva o valor na central (app.pdv_cashback_reserve), a venda
-- confirma a reserva. Reserva não confirmada em 2 horas volta para o saldo.
-- Devolução: o ganho da venda devolvida é estornado na proporção e o cashback usado nela volta
-- como lote novo, na mesma proporção. O resto (refund_amount) é o que vai para o destino da
-- devolução (crédito, convênio, dinheiro ou crediário).

-- Parâmetros do cashback do cliente (grupo). Sem linha, valem os padrões.
CREATE TABLE cashback_policy (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  -- Dias até o ganho poder ser usado.
  waiting_days smallint NOT NULL DEFAULT 0 CONSTRAINT cashback_policy_waiting_check CHECK (waiting_days BETWEEN 0 AND 365),
  -- Dias de validade, contados de quando o ganho fica disponível.
  validity_days smallint NOT NULL DEFAULT 90 CONSTRAINT cashback_policy_validity_check CHECK (validity_days BETWEEN 1 AND 3650),
  -- Quanto da compra o cashback pode pagar, em %.
  max_use_percent numeric(5, 2) NOT NULL DEFAULT 50 CONSTRAINT cashback_policy_max_use_check CHECK (max_use_percent BETWEEN 1 AND 100),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE UNIQUE INDEX cashback_policy_group_key ON cashback_policy (economic_group_id) WHERE deleted_at IS NULL;

-- Lançamentos do cashback do cliente. Lotes (earn: ganho na venda; refund: volta do usado numa
-- devolução) têm carência e validade. use: uso numa venda (reservado, confirmado ou liberado);
-- reverse: estorno do ganho na devolução; expire: o que venceu sem uso.
CREATE TABLE cashback_entry (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  customer_id uuid NOT NULL REFERENCES customer (id),
  branch_id uuid REFERENCES branch (id),
  kind text NOT NULL CONSTRAINT cashback_entry_kind_check CHECK (kind IN ('earn', 'refund', 'use', 'reverse', 'expire')),
  amount numeric(12, 2) NOT NULL CONSTRAINT cashback_entry_amount_check CHECK (amount > 0),
  sale_id uuid REFERENCES sale (id),
  sale_return_id uuid REFERENCES sale_return (id),
  -- Lote: a partir de quando pode ser usado e até quando vale.
  available_at timestamptz,
  expires_at timestamptz,
  -- Uso: reservado pelo PDV, confirmado pela venda, ou liberado (venda desistida ou reserva vencida).
  status text CONSTRAINT cashback_entry_status_check CHECK (status IN ('reserved', 'confirmed', 'released')),
  terminal_id uuid REFERENCES terminal (id),
  detail jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid,
  CONSTRAINT cashback_entry_lot_check CHECK (
    (kind IN ('earn', 'refund')) = (available_at IS NOT NULL AND expires_at IS NOT NULL AND expires_at > available_at)
  ),
  CONSTRAINT cashback_entry_use_check CHECK ((kind = 'use') = (status IS NOT NULL))
);
CREATE INDEX cashback_entry_customer_idx ON cashback_entry (customer_id, created_at);
CREATE INDEX cashback_entry_economic_group_id_idx ON cashback_entry (economic_group_id);
CREATE INDEX cashback_entry_branch_idx ON cashback_entry (branch_id);
CREATE INDEX cashback_entry_sale_idx ON cashback_entry (sale_id);
CREATE INDEX cashback_entry_return_idx ON cashback_entry (sale_return_id);
CREATE INDEX cashback_entry_terminal_idx ON cashback_entry (terminal_id);
CREATE UNIQUE INDEX cashback_entry_sale_earn_key ON cashback_entry (sale_id) WHERE kind = 'earn' AND deleted_at IS NULL;

-- De quais lotes saiu cada uso, estorno ou expiração.
CREATE TABLE cashback_allocation (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  entry_id uuid NOT NULL REFERENCES cashback_entry (id),
  lot_id uuid NOT NULL REFERENCES cashback_entry (id),
  amount numeric(12, 2) NOT NULL CONSTRAINT cashback_allocation_amount_check CHECK (amount > 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE INDEX cashback_allocation_entry_idx ON cashback_allocation (entry_id);
CREATE INDEX cashback_allocation_lot_idx ON cashback_allocation (lot_id);
CREATE INDEX cashback_allocation_economic_group_id_idx ON cashback_allocation (economic_group_id);

CALL app.apply_table_standard('public.cashback_policy');
CALL app.apply_table_standard('public.cashback_entry');
CALL app.apply_table_standard('public.cashback_allocation');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON cashback_policy
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns('economic_group_id');
-- Só a situação do uso (e a venda que o confirmou) muda depois de gravado.
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON cashback_entry
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'customer_id', 'branch_id', 'kind', 'amount', 'sale_return_id', 'available_at', 'expires_at',
    'terminal_id', 'deleted_at'
  );
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON cashback_allocation
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns('economic_group_id', 'entry_id', 'lot_id', 'amount', 'deleted_at');
CREATE POLICY cashback_policy_select ON cashback_policy FOR SELECT TO farmaerp_app USING (false);
CREATE POLICY cashback_entry_select ON cashback_entry FOR SELECT TO farmaerp_app USING (false);
CREATE POLICY cashback_allocation_select ON cashback_allocation FOR SELECT TO farmaerp_app USING (false);
CREATE VIEW v_cashback_policy WITH (security_invoker = true) AS SELECT * FROM cashback_policy WHERE deleted_at IS NULL;
CREATE VIEW v_cashback_entry WITH (security_invoker = true) AS SELECT * FROM cashback_entry WHERE deleted_at IS NULL;
CREATE VIEW v_cashback_allocation WITH (security_invoker = true) AS SELECT * FROM cashback_allocation WHERE deleted_at IS NULL;

-- Venda: forma cashback. Devolução: a parte do cashback volta como cashback; o resto é o que vai
-- para o destino.
ALTER TABLE sale_payment DROP CONSTRAINT sale_payment_method_check;
ALTER TABLE sale_payment ADD CONSTRAINT sale_payment_method_check CHECK (
  method IN ('cash', 'credit_card', 'debit_card', 'pix', 'agreement', 'return_credit', 'store_credit', 'cashback')
);
ALTER TABLE sale_return ADD COLUMN cashback_refund numeric(12, 2) NOT NULL DEFAULT 0
  CONSTRAINT sale_return_cashback_refund_check CHECK (cashback_refund >= 0 AND cashback_refund <= total);
ALTER TABLE sale_return ADD COLUMN refund_amount numeric(12, 2) GENERATED ALWAYS AS (total - cashback_refund) STORED;
CREATE OR REPLACE VIEW v_sale_return WITH (security_invoker = true) AS SELECT * FROM sale_return WHERE deleted_at IS NULL;
ALTER TABLE sale_alert DROP CONSTRAINT sale_alert_kind_check;
ALTER TABLE sale_alert ADD CONSTRAINT sale_alert_kind_check CHECK (kind IN (
  'price_divergence', 'discount_above_rule', 'discount_above_limit', 'operator_permission',
  'negative_stock', 'product_status', 'agreement_link', 'offline_zero_stock',
  'controlled_missing', 'controlled_release', 'controlled_pending', 'prescription_expired', 'prescription_type',
  'seller_permission', 'quote_status', 'return_permission', 'return_credit', 'auto_discount',
  'credit_limit', 'credit_blocked', 'credit_overdue', 'credit_schedule', 'credit_dependent', 'credit_release',
  'cashback_use'
));

CREATE FUNCTION app.cashback_policy_json(p_group_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT pg_catalog.jsonb_build_object(
    'waiting_days', COALESCE(p.waiting_days, 0), 'validity_days', COALESCE(p.validity_days, 90),
    'max_use_percent', COALESCE(p.max_use_percent, 50))
    FROM (SELECT 1) one
    LEFT JOIN public.cashback_policy p ON p.economic_group_id = p_group_id AND p.deleted_at IS NULL
$$;

-- Consentimento de cashback do cliente numa data: a decisão mais recente até ali.
CREATE FUNCTION app.cashback_consent_at(p_customer_id uuid, p_at timestamptz) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE((
    SELECT e.granted FROM public.customer_consent_event e
     WHERE e.customer_id = p_customer_id AND e.purpose = 'cashback' AND e.deleted_at IS NULL AND e.created_at <= p_at
     ORDER BY e.created_at DESC, e.id DESC LIMIT 1
  ), false)
$$;

-- Uso que conta: confirmado, ou reservado há menos de 2 horas.
CREATE FUNCTION app.cashback_use_active(p_entry public.cashback_entry, p_at timestamptz) RETURNS boolean
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT p_entry.kind <> 'use' OR p_entry.status = 'confirmed'
         OR (p_entry.status = 'reserved' AND p_entry.created_at > p_at - interval '2 hours')
$$;

-- Lotes do cliente com o que sobra de cada um numa data.
CREATE FUNCTION app.cashback_lots(p_customer_id uuid, p_at timestamptz)
RETURNS TABLE (lot_id uuid, available_at timestamptz, expires_at timestamptz, amount numeric, remaining numeric)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT l.id, l.available_at, l.expires_at, l.amount,
         l.amount - COALESCE((
           SELECT pg_catalog.sum(al.amount) FROM public.cashback_allocation al
             JOIN public.cashback_entry e ON e.id = al.entry_id AND e.deleted_at IS NULL
            WHERE al.lot_id = l.id AND al.deleted_at IS NULL AND app.cashback_use_active(e, p_at)
         ), 0)
    FROM public.cashback_entry l
   WHERE l.customer_id = p_customer_id AND l.kind IN ('earn', 'refund') AND l.deleted_at IS NULL
$$;

-- Saldo que pode ser usado numa data (disponível e não vencido) e o que ainda está na carência.
CREATE FUNCTION app.cashback_balance(p_customer_id uuid, p_at timestamptz DEFAULT pg_catalog.now()) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT pg_catalog.jsonb_build_object(
    'available', COALESCE(pg_catalog.sum(l.remaining) FILTER (WHERE l.available_at <= p_at AND l.expires_at > p_at), 0),
    'waiting', COALESCE(pg_catalog.sum(l.remaining) FILTER (WHERE l.available_at > p_at), 0),
    'next_expiry', pg_catalog.min(l.expires_at) FILTER (WHERE l.available_at <= p_at AND l.expires_at > p_at AND l.remaining > 0)
  )
    FROM app.cashback_lots(p_customer_id, p_at) l
$$;

-- Tira dos lotes, do que vence antes para o que vence depois (só os que valem em p_at).
CREATE FUNCTION app.cashback_take(p_entry_id uuid, p_customer_id uuid, p_amount numeric, p_at timestamptz) RETURNS numeric
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  remaining numeric := p_amount;
  lot record;
  take numeric;
  group_id uuid;
BEGIN
  SELECT e.economic_group_id INTO group_id FROM public.cashback_entry e WHERE e.id = p_entry_id;
  FOR lot IN
    SELECT l.* FROM app.cashback_lots(p_customer_id, p_at) l
     WHERE l.available_at <= p_at AND l.expires_at > p_at AND l.remaining > 0
     ORDER BY l.expires_at, l.lot_id
  LOOP
    EXIT WHEN remaining <= 0;
    take := LEAST(remaining, lot.remaining);
    INSERT INTO public.cashback_allocation (economic_group_id, entry_id, lot_id, amount) VALUES (group_id, p_entry_id, lot.lot_id, take);
    remaining := remaining - take;
  END LOOP;
  RETURN remaining;
END;
$$;

-- Vencidos sem uso saem do saldo por um lançamento de expiração (rodado em cada gravação do cliente).
CREATE FUNCTION app.cashback_expire(p_customer_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  lot record;
  entry_id uuid;
BEGIN
  FOR lot IN
    SELECT l.*, e.economic_group_id, e.branch_id FROM app.cashback_lots(p_customer_id, pg_catalog.now()) l
      JOIN public.cashback_entry e ON e.id = l.lot_id
     WHERE l.expires_at <= pg_catalog.now() AND l.remaining > 0
  LOOP
    INSERT INTO public.cashback_entry (economic_group_id, customer_id, branch_id, kind, amount, detail)
    VALUES (lot.economic_group_id, p_customer_id, lot.branch_id, 'expire', lot.remaining,
            pg_catalog.jsonb_build_object('lot_id', lot.lot_id, 'expired_at', lot.expires_at))
    RETURNING id INTO entry_id;
    INSERT INTO public.cashback_allocation (economic_group_id, entry_id, lot_id, amount)
    VALUES (lot.economic_group_id, entry_id, lot.lot_id, lot.remaining);
  END LOOP;
  -- Reservas não confirmadas em 2 horas ficam liberadas de vez.
  UPDATE public.cashback_entry SET status = 'released'
   WHERE customer_id = p_customer_id AND kind = 'use' AND status = 'reserved'
     AND created_at <= pg_catalog.now() - interval '2 hours' AND deleted_at IS NULL;
END;
$$;

-- Saldo para o caixa (só com internet): consentimento, saldo e o máximo de uso da filial.
CREATE FUNCTION app.pdv_cashback(p_customer_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  terminal_row public.terminal := app.require_active_terminal();
  group_id uuid;
BEGIN
  SELECT co.economic_group_id INTO group_id FROM public.branch b JOIN public.company co ON co.id = b.company_id WHERE b.id = terminal_row.branch_id;
  IF NOT EXISTS (SELECT 1 FROM public.customer c WHERE c.id = p_customer_id AND c.economic_group_id = group_id AND c.deleted_at IS NULL) THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.' USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('customer %s.', p_customer_id);
  END IF;
  RETURN app.cashback_balance(p_customer_id) || pg_catalog.jsonb_build_object(
    'consent', app.cashback_consent_at(p_customer_id, pg_catalog.now()),
    'policy', app.cashback_policy_json(group_id));
END;
$$;

-- Reserva do uso no caixa: o valor sai do saldo agora e a venda confirma. Devolve o id da reserva.
CREATE FUNCTION app.pdv_cashback_reserve(p_customer_id uuid, p_amount numeric, p_sale_total numeric) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  terminal_row public.terminal := app.require_active_terminal();
  group_id uuid;
  policy jsonb;
  balance jsonb;
  entry_id uuid;
BEGIN
  SELECT co.economic_group_id INTO group_id FROM public.branch b JOIN public.company co ON co.id = b.company_id WHERE b.id = terminal_row.branch_id;
  PERFORM 1 FROM public.customer c WHERE c.id = p_customer_id AND c.economic_group_id = group_id AND c.deleted_at IS NULL FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.' USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('customer %s.', p_customer_id);
  END IF;
  IF NOT app.cashback_consent_at(p_customer_id, pg_catalog.now()) THEN
    RAISE EXCEPTION 'Este cliente não autorizou o cashback.' USING ERRCODE = 'FA849';
  END IF;
  IF p_amount IS NULL OR p_amount <= 0 OR p_amount <> pg_catalog.round(p_amount, 2) OR p_sale_total IS NULL OR p_sale_total <= 0 THEN
    RAISE EXCEPTION 'Alguns dados informados são inválidos.' USING ERRCODE = 'FA005', DETAIL = 'Valor do cashback.';
  END IF;
  policy := app.cashback_policy_json(group_id);
  IF p_amount > pg_catalog.round(p_sale_total * (policy ->> 'max_use_percent')::numeric / 100, 2) THEN
    RAISE EXCEPTION 'O cashback passa do máximo que pode pagar desta compra.'
      USING ERRCODE = 'FA851', DETAIL = pg_catalog.format('%s de %s (máximo %s%%).', p_amount, p_sale_total, policy ->> 'max_use_percent');
  END IF;
  PERFORM app.cashback_expire(p_customer_id);
  balance := app.cashback_balance(p_customer_id);
  IF p_amount > (balance ->> 'available')::numeric THEN
    RAISE EXCEPTION 'O saldo de cashback não cobre este valor.'
      USING ERRCODE = 'FA850', DETAIL = pg_catalog.format('%s com saldo %s.', p_amount, balance ->> 'available');
  END IF;
  INSERT INTO public.cashback_entry (economic_group_id, customer_id, branch_id, kind, amount, status, terminal_id)
  VALUES (group_id, p_customer_id, terminal_row.branch_id, 'use', p_amount, 'reserved', terminal_row.id)
  RETURNING id INTO entry_id;
  PERFORM app.cashback_take(entry_id, p_customer_id, p_amount, pg_catalog.now());
  RETURN pg_catalog.jsonb_build_object('reservation_id', entry_id, 'balance', (balance ->> 'available')::numeric - p_amount);
END;
$$;

-- Venda desistida: a reserva volta para o saldo.
CREATE FUNCTION app.pdv_cashback_release(p_reservation_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  terminal_row public.terminal := app.require_active_terminal();
BEGIN
  UPDATE public.cashback_entry SET status = 'released'
   WHERE id = p_reservation_id AND kind = 'use' AND status = 'reserved' AND terminal_id = terminal_row.id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'A reserva de cashback não está mais valendo.' USING ERRCODE = 'FA852', DETAIL = pg_catalog.format('Reserva %s.', p_reservation_id);
  END IF;
END;
$$;

-- Venda que chegou: confirma o uso reservado e grava o ganho. Sem consentimento, não ganha. Uso
-- sem reserva válida (vencida, de outro cliente ou com outro valor): a venda vale, o uso é feito com
-- o saldo de agora e fica o alerta.
CREATE FUNCTION app.cashback_record_sale(
  p_group_id uuid, p_branch_id uuid, p_sale_id uuid, p_customer_id uuid, p_sold_at timestamptz, p_payload jsonb
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  payment jsonb;
  reservation public.cashback_entry;
  used numeric := 0;
  sale_total numeric := (p_payload ->> 'total')::numeric;
  policy jsonb := app.cashback_policy_json(p_group_id);
  earn numeric;
  percents jsonb;
  available timestamptz;
  shortfall numeric;
  entry_id uuid;
BEGIN
  IF p_customer_id IS NULL THEN
    RETURN;
  END IF;
  PERFORM 1 FROM public.customer c WHERE c.id = p_customer_id FOR UPDATE;
  PERFORM app.cashback_expire(p_customer_id);
  FOR payment IN SELECT value FROM pg_catalog.jsonb_array_elements(p_payload -> 'payments') WHERE value ->> 'method' = 'cashback' LOOP
    used := used + (payment ->> 'amount')::numeric;
    SELECT e.* INTO reservation FROM public.cashback_entry e
     WHERE e.id = (payment ->> 'reservation_id')::uuid AND e.kind = 'use' AND e.deleted_at IS NULL FOR UPDATE;
    IF reservation.id IS NOT NULL AND reservation.customer_id = p_customer_id AND reservation.amount = (payment ->> 'amount')::numeric
       AND app.cashback_use_active(reservation, pg_catalog.now()) AND reservation.status = 'reserved' THEN
      UPDATE public.cashback_entry SET status = 'confirmed', sale_id = p_sale_id WHERE id = reservation.id;
    ELSE
      INSERT INTO public.cashback_entry (economic_group_id, customer_id, branch_id, kind, amount, status, sale_id, detail)
      VALUES (p_group_id, p_customer_id, p_branch_id, 'use', (payment ->> 'amount')::numeric, 'confirmed', p_sale_id,
              pg_catalog.jsonb_build_object('reservation_id', payment ->> 'reservation_id'))
      RETURNING id INTO entry_id;
      shortfall := app.cashback_take(entry_id, p_customer_id, (payment ->> 'amount')::numeric, p_sold_at);
      INSERT INTO public.sale_alert (economic_group_id, branch_id, sale_id, kind, detail)
      VALUES (p_group_id, p_branch_id, p_sale_id, 'cashback_use', pg_catalog.jsonb_build_object(
        'amount', (payment ->> 'amount')::numeric, 'problem', 'reservation', 'shortfall', shortfall));
    END IF;
  END LOOP;
  IF used > pg_catalog.round(sale_total * (policy ->> 'max_use_percent')::numeric / 100, 2) THEN
    INSERT INTO public.sale_alert (economic_group_id, branch_id, sale_id, kind, detail)
    VALUES (p_group_id, p_branch_id, p_sale_id, 'cashback_use', pg_catalog.jsonb_build_object(
      'amount', used, 'problem', 'max_use', 'max_use_percent', policy -> 'max_use_percent'));
  END IF;

  -- Ganho: percentual do motor por item, sobre a parte paga sem cashback. Só com consentimento.
  IF sale_total <= 0 OR NOT app.cashback_consent_at(p_customer_id, p_sold_at) THEN
    RETURN;
  END IF;
  SELECT pg_catalog.round(COALESCE(pg_catalog.sum(i.total * COALESCE(r.value, 0)), 0) / 100 * (sale_total - used) / sale_total, 2),
         COALESCE(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('line', i.line, 'percent', r.value) ORDER BY i.line)
                    FILTER (WHERE r.value > 0), '[]'::jsonb)
    INTO earn, percents
    FROM public.sale_item i
    LEFT JOIN LATERAL (SELECT x.value FROM app.resolve_product_rule('cashback', i.product_id, p_branch_id, p_sold_at) x LIMIT 1) r ON true
   WHERE i.sale_id = p_sale_id AND i.deleted_at IS NULL;
  IF earn > 0 THEN
    available := p_sold_at + pg_catalog.make_interval(days => (policy ->> 'waiting_days')::integer);
    INSERT INTO public.cashback_entry (economic_group_id, customer_id, branch_id, kind, amount, sale_id, available_at, expires_at, detail)
    VALUES (p_group_id, p_customer_id, p_branch_id, 'earn', earn, p_sale_id, available,
            available + pg_catalog.make_interval(days => (policy ->> 'validity_days')::integer),
            pg_catalog.jsonb_build_object('items', percents, 'paid_with_cashback', used));
  END IF;
END;
$$;

-- Parte do cashback numa devolução: proporção acumulada do que já voltou da venda, para a soma das
-- devoluções fechar no centavo com o que foi usado.
CREATE FUNCTION app.cashback_refund_for(p_sale_id uuid, p_return_total numeric) RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  WITH sold AS (
    SELECT s.total,
           COALESCE((SELECT pg_catalog.sum(p.amount) FROM public.sale_payment p
                      WHERE p.sale_id = s.id AND p.method = 'cashback' AND p.deleted_at IS NULL), 0) AS used,
           COALESCE((SELECT pg_catalog.sum(r.total) FROM public.sale_return r WHERE r.sale_id = s.id AND r.deleted_at IS NULL), 0) AS returned,
           COALESCE((SELECT pg_catalog.sum(r.cashback_refund) FROM public.sale_return r WHERE r.sale_id = s.id AND r.deleted_at IS NULL), 0) AS refunded
      FROM public.sale s WHERE s.id = p_sale_id
  )
  SELECT CASE WHEN total <= 0 OR used <= 0 THEN 0
              ELSE LEAST(p_return_total, pg_catalog.round(used * (returned + p_return_total) / total, 2) - refunded) END
    FROM sold
$$;

-- Devolução gravada: estorna o ganho da venda na proporção (do que sobrou do lote) e devolve o
-- cashback usado como lote novo, com a carência zerada e a validade da política.
CREATE FUNCTION app.cashback_record_return(p_return public.sale_return) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  sale_row public.sale;
  earn_lot public.cashback_entry;
  lot_remaining numeric;
  reverse_amount numeric;
  reversed_before numeric;
  entry_id uuid;
  policy jsonb := app.cashback_policy_json(p_return.economic_group_id);
BEGIN
  SELECT s.* INTO sale_row FROM public.sale s WHERE s.id = p_return.sale_id;
  IF sale_row.customer_id IS NULL OR sale_row.total <= 0 THEN
    RETURN;
  END IF;
  PERFORM 1 FROM public.customer c WHERE c.id = sale_row.customer_id FOR UPDATE;
  SELECT e.* INTO earn_lot FROM public.cashback_entry e WHERE e.sale_id = sale_row.id AND e.kind = 'earn' AND e.deleted_at IS NULL;
  IF earn_lot.id IS NOT NULL THEN
    SELECT COALESCE(pg_catalog.sum(e.amount + COALESCE((e.detail ->> 'shortfall')::numeric, 0)), 0) INTO reversed_before
      FROM public.cashback_entry e WHERE e.sale_id = sale_row.id AND e.kind = 'reverse' AND e.deleted_at IS NULL;
    reverse_amount := pg_catalog.round(earn_lot.amount * (
      SELECT COALESCE(pg_catalog.sum(r.total), 0) FROM public.sale_return r WHERE r.sale_id = sale_row.id AND r.deleted_at IS NULL
    ) / sale_row.total, 2) - reversed_before;
    SELECT l.remaining INTO lot_remaining FROM app.cashback_lots(sale_row.customer_id, pg_catalog.now()) l WHERE l.lot_id = earn_lot.id;
    IF reverse_amount > 0 THEN
      -- O que o cliente já usou não volta: fica registrado como diferença.
      IF LEAST(reverse_amount, lot_remaining) > 0 THEN
        INSERT INTO public.cashback_entry (economic_group_id, customer_id, branch_id, kind, amount, sale_id, sale_return_id, detail)
        VALUES (p_return.economic_group_id, sale_row.customer_id, p_return.branch_id, 'reverse', LEAST(reverse_amount, lot_remaining),
                sale_row.id, p_return.id,
                pg_catalog.jsonb_build_object('shortfall', reverse_amount - LEAST(reverse_amount, lot_remaining)))
        RETURNING id INTO entry_id;
        INSERT INTO public.cashback_allocation (economic_group_id, entry_id, lot_id, amount)
        VALUES (p_return.economic_group_id, entry_id, earn_lot.id, LEAST(reverse_amount, lot_remaining));
      END IF;
    END IF;
  END IF;
  IF p_return.cashback_refund > 0 THEN
    INSERT INTO public.cashback_entry (economic_group_id, customer_id, branch_id, kind, amount, sale_id, sale_return_id, available_at, expires_at)
    VALUES (p_return.economic_group_id, sale_row.customer_id, p_return.branch_id, 'refund', p_return.cashback_refund, sale_row.id,
            p_return.id, p_return.returned_at,
            p_return.returned_at + pg_catalog.make_interval(days => (policy ->> 'validity_days')::integer));
  END IF;
END;
$$;

-- Extrato do cliente para a retaguarda (quem vê clientes).
CREATE FUNCTION app.cashback_statement(p_customer_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.customer c WHERE c.id = p_customer_id AND c.deleted_at IS NULL AND c.economic_group_id = app.current_user_group()
  ) OR NOT (app.has_permission_anywhere('customers.view') OR app.has_permission_anywhere('customers.manage')) THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.' USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('customer %s.', p_customer_id);
  END IF;
  RETURN app.cashback_balance(p_customer_id) || pg_catalog.jsonb_build_object(
    'consent', app.cashback_consent_at(p_customer_id, pg_catalog.now()),
    'entries', COALESCE((
      SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
               'id', e.id, 'kind', e.kind, 'amount', e.amount, 'status', e.status, 'created_at', e.created_at,
               'available_at', e.available_at, 'expires_at', e.expires_at, 'sale_code', s.code, 'return_code', r.code,
               'branch_name', b.name,
               'remaining', CASE WHEN e.kind IN ('earn', 'refund') THEN (
                 SELECT l.remaining FROM app.cashback_lots(p_customer_id, pg_catalog.now()) l WHERE l.lot_id = e.id) END
             ) ORDER BY e.created_at DESC, e.id DESC)
        FROM public.cashback_entry e
        LEFT JOIN public.sale s ON s.id = e.sale_id
        LEFT JOIN public.sale_return r ON r.id = e.sale_return_id
        LEFT JOIN public.branch b ON b.id = e.branch_id
       WHERE e.customer_id = p_customer_id AND e.deleted_at IS NULL
         AND NOT (e.kind = 'use' AND e.status = 'released')
    ), '[]'::jsonb)
  );
END;
$$;

CREATE FUNCTION app.get_cashback_policy() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT app.cashback_policy_json(app.current_user_group())
         || pg_catalog.jsonb_build_object('can_edit', app.has_permission('rules.manage'))
$$;

-- Parâmetros do cashback do cliente: quem define as regras da rede. Campo ausente mantém o atual.
CREATE FUNCTION app.set_cashback_policy(p_data jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.permission_group('rules.manage');
  merged jsonb;
BEGIN
  IF group_id IS NULL THEN
    RAISE EXCEPTION 'Você não tem permissão para esta operação.' USING ERRCODE = 'FA002', DETAIL = 'rules.manage em todas as filiais.';
  END IF;
  merged := app.cashback_policy_json(group_id) || pg_catalog.jsonb_strip_nulls(COALESCE(p_data, '{}'::jsonb));
  UPDATE public.cashback_policy SET
    waiting_days = (merged ->> 'waiting_days')::smallint,
    validity_days = (merged ->> 'validity_days')::smallint,
    max_use_percent = (merged ->> 'max_use_percent')::numeric
   WHERE economic_group_id = group_id AND deleted_at IS NULL;
  IF NOT FOUND THEN
    INSERT INTO public.cashback_policy (economic_group_id, waiting_days, validity_days, max_use_percent)
    VALUES (group_id, (merged ->> 'waiting_days')::smallint, (merged ->> 'validity_days')::smallint, (merged ->> 'max_use_percent')::numeric);
  END IF;
END;
$$;

-- Venda vinda do PDV: forma cashback, ganho e o crédito de devolução pelo valor a devolver.
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
    END IF;
  END LOOP;
  PERFORM app.cashback_record_sale(p_group_id, p_terminal.branch_id, sale_id, buyer_id, sale_at, p_payload);
END;
$$;

-- Devolução vinda do PDV: parte do cashback.
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
      customer_id, reason, destination, returned_at, total, cashback_refund
    ) VALUES (
      refund_id, p_group_id, p_terminal.branch_id, p_terminal.id, (p_payload ->> 'cash_session_id')::uuid, sale_row.id,
      (p_payload ->> 'number')::bigint, 'D' || terminal_number || '-' || pg_catalog.lpad(p_payload ->> 'number', 6, '0'),
      operator, authorizer, sale_row.customer_id, pg_catalog.btrim(p_payload ->> 'reason'), p_payload ->> 'destination',
      refund_at, sum_items, app.cashback_refund_for(sale_row.id, sum_items)
    );
  EXCEPTION WHEN check_violation THEN
    RAISE EXCEPTION 'A devolução enviada pelo terminal está inconsistente.'
      USING ERRCODE = 'FA894', DETAIL = SQLERRM;
  END;

  -- Cashback: estorno do ganho e volta do usado.
  PERFORM app.cashback_record_return(r) FROM public.sale_return r WHERE r.id = refund_id;

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

-- Devolução no crediário: abate só o que não voltou como cashback.
CREATE OR REPLACE FUNCTION app.credit_record_return(p_return public.sale_return) RETURNS void
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
  IF p_return.refund_amount <= 0 THEN
    RETURN;
  END IF;
  SELECT a.* INTO account FROM public.credit_account a
   WHERE a.customer_id = p_return.customer_id AND a.economic_group_id = p_return.economic_group_id AND a.deleted_at IS NULL
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Este cliente não tem crediário.'
      USING ERRCODE = 'FA834', DETAIL = pg_catalog.format('Devolução %s sem conta do cliente.', p_return.code);
  END IF;
  allocation := app.credit_allocate(
    app.credit_states(account.id), p_return.refund_amount, received_on, app.credit_policy_json(account.home_branch_id));
  INSERT INTO public.credit_payment (
    economic_group_id, account_id, branch_id, terminal_id, cash_session_id, received_by, received_at, method, amount,
    excess, return_id
  ) VALUES (
    p_return.economic_group_id, account.id, p_return.branch_id, p_return.terminal_id, p_return.cash_session_id,
    p_return.operator_id, p_return.returned_at, 'return', p_return.refund_amount, (allocation ->> 'excess')::numeric, p_return.id
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
                                          'amount', p_return.refund_amount, 'excess', (allocation ->> 'excess')::numeric));
  END IF;
END;
$$;

-- Sangria de devolução: paga o valor a devolver (sem a parte do cashback).
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
      WHEN refund.refund_amount <> amount THEN 'amount'
    END;
    IF problem IS NULL THEN
      UPDATE public.sale_return SET paid_movement_id = movement_id WHERE id = refund_id;
    ELSE
      INSERT INTO public.cash_alert (economic_group_id, branch_id, cash_session_id, cash_movement_id, kind, detail)
      VALUES (p_group_id, session_row.branch_id, session_row.id, movement_id, 'return_payout',
              pg_catalog.jsonb_build_object('return_code', refund.code, 'problem', problem, 'amount', amount, 'return_total', refund.refund_amount));
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

-- Documento da devolução para a sangria: o valor a devolver.
CREATE OR REPLACE FUNCTION app.pdv_return(p_code text) RETURNS jsonb
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
    'id', found_return.id, 'code', found_return.code, 'total', found_return.refund_amount,
    'sale_code', (SELECT s.code FROM public.sale s WHERE s.id = found_return.sale_id)
  );
END;
$$;

-- Crédito de devolução: o valor a devolver.
CREATE OR REPLACE FUNCTION app.pdv_return_credit(p_code text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  terminal_row public.terminal := app.require_active_terminal();
  found_return public.sale_return;
  used numeric;
BEGIN
  SELECT r.* INTO found_return FROM public.sale_return r
   WHERE r.branch_id = terminal_row.branch_id AND r.code = pg_catalog.upper(pg_catalog.btrim(COALESCE(p_code, ''))) AND r.deleted_at IS NULL;
  used := CASE WHEN FOUND THEN app.return_credit_used(found_return.id) END;
  IF found_return.id IS NULL OR found_return.destination <> 'credit' OR used >= found_return.refund_amount THEN
    RAISE EXCEPTION 'Este crédito de devolução não está disponível.'
      USING ERRCODE = 'FA872', DETAIL = pg_catalog.format('Código %s.', p_code);
  END IF;
  RETURN pg_catalog.jsonb_build_object(
    'id', found_return.id, 'code', found_return.code, 'total', found_return.refund_amount, 'used', used,
    'balance', found_return.refund_amount - used
  );
END;
$$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  app.pdv_cashback(uuid),
  app.pdv_cashback_reserve(uuid, numeric, numeric),
  app.pdv_cashback_release(uuid),
  app.cashback_statement(uuid),
  app.get_cashback_policy(),
  app.set_cashback_policy(jsonb)
TO farmaerp_app;
