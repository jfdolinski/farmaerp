-- Up Migration

-- Etapa 7, PR 7D: fatura do convênio.
-- Cada convênio tem o dia de fechamento. A fatura fecha, à mão na retaguarda, as vendas do convênio
-- até a data e abate as devoluções com destino convênio (o valor que vai para o destino, sem a parte
-- do cashback). Fechada não muda; devolução depois do fechamento entra na fatura seguinte como
-- abatimento. Situação: fechada, paga (a empresa pagou a farmácia) ou cancelada (com motivo: as
-- vendas voltam para o próximo fechamento). O limite do cliente no convênio conta o que ainda não
-- está em fatura paga; venda acima do limite (PDV sem internet) vale e vira alerta.

ALTER TABLE agreement ADD COLUMN closing_day smallint NOT NULL DEFAULT 25
  CONSTRAINT agreement_closing_day_check CHECK (closing_day BETWEEN 1 AND 28);
CREATE OR REPLACE VIEW v_agreement WITH (security_invoker = true) AS SELECT * FROM agreement WHERE deleted_at IS NULL;

CREATE TABLE agreement_invoice (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  agreement_id uuid NOT NULL REFERENCES agreement (id),
  period_start date NOT NULL,
  period_end date NOT NULL,
  status text NOT NULL DEFAULT 'closed' CONSTRAINT agreement_invoice_status_check CHECK (status IN ('closed', 'paid', 'cancelled')),
  total numeric(12, 2) NOT NULL,
  closed_by uuid NOT NULL REFERENCES user_account (id),
  paid_on date,
  paid_note text CONSTRAINT agreement_invoice_paid_note_check CHECK (length(paid_note) <= 500),
  paid_by uuid REFERENCES user_account (id),
  cancel_reason text CONSTRAINT agreement_invoice_cancel_reason_check CHECK (length(cancel_reason) BETWEEN 1 AND 500),
  cancelled_by uuid REFERENCES user_account (id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid,
  CONSTRAINT agreement_invoice_period_check CHECK (period_end >= period_start),
  CONSTRAINT agreement_invoice_state_check CHECK (
    (status = 'closed' AND paid_on IS NULL AND paid_by IS NULL AND cancel_reason IS NULL AND cancelled_by IS NULL)
    OR (status = 'paid' AND paid_on IS NOT NULL AND paid_by IS NOT NULL AND cancel_reason IS NULL)
    OR (status = 'cancelled' AND cancel_reason IS NOT NULL AND cancelled_by IS NOT NULL AND paid_on IS NULL)
  )
);
CREATE INDEX agreement_invoice_agreement_idx ON agreement_invoice (agreement_id, period_end DESC);
CREATE INDEX agreement_invoice_economic_group_id_idx ON agreement_invoice (economic_group_id);
CREATE INDEX agreement_invoice_closed_by_idx ON agreement_invoice (closed_by);
CREATE INDEX agreement_invoice_paid_by_idx ON agreement_invoice (paid_by);
CREATE INDEX agreement_invoice_cancelled_by_idx ON agreement_invoice (cancelled_by);

-- Vendas (positivo) e devoluções (negativo) da fatura. Fatura cancelada: os itens saem (exclusão
-- lógica) e voltam para o próximo fechamento.
CREATE TABLE agreement_invoice_item (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  invoice_id uuid NOT NULL REFERENCES agreement_invoice (id),
  kind text NOT NULL CONSTRAINT agreement_invoice_item_kind_check CHECK (kind IN ('sale', 'return')),
  sale_payment_id uuid REFERENCES sale_payment (id),
  sale_return_id uuid REFERENCES sale_return (id),
  customer_id uuid REFERENCES customer (id),
  registration text,
  occurred_at timestamptz NOT NULL,
  amount numeric(12, 2) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid,
  CONSTRAINT agreement_invoice_item_source_check CHECK (
    (kind = 'sale' AND sale_payment_id IS NOT NULL AND sale_return_id IS NULL AND amount > 0)
    OR (kind = 'return' AND sale_return_id IS NOT NULL AND sale_payment_id IS NULL AND amount <= 0)
  )
);
CREATE UNIQUE INDEX agreement_invoice_item_payment_key ON agreement_invoice_item (sale_payment_id) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX agreement_invoice_item_return_key ON agreement_invoice_item (sale_return_id) WHERE deleted_at IS NULL;
CREATE INDEX agreement_invoice_item_invoice_idx ON agreement_invoice_item (invoice_id);
CREATE INDEX agreement_invoice_item_economic_group_id_idx ON agreement_invoice_item (economic_group_id);
CREATE INDEX agreement_invoice_item_customer_idx ON agreement_invoice_item (customer_id);

CALL app.apply_table_standard('public.agreement_invoice');
CALL app.apply_table_standard('public.agreement_invoice_item');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON agreement_invoice
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'agreement_id', 'period_start', 'period_end', 'total', 'closed_by', 'deleted_at'
  );
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON agreement_invoice_item
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'invoice_id', 'kind', 'sale_payment_id', 'sale_return_id', 'customer_id', 'registration',
    'occurred_at', 'amount'
  );
CREATE POLICY agreement_invoice_select ON agreement_invoice FOR SELECT TO farmaerp_app USING (false);
CREATE POLICY agreement_invoice_item_select ON agreement_invoice_item FOR SELECT TO farmaerp_app USING (false);
CREATE VIEW v_agreement_invoice WITH (security_invoker = true) AS SELECT * FROM agreement_invoice WHERE deleted_at IS NULL;
CREATE VIEW v_agreement_invoice_item WITH (security_invoker = true) AS SELECT * FROM agreement_invoice_item WHERE deleted_at IS NULL;

ALTER TABLE sale_alert DROP CONSTRAINT sale_alert_kind_check;
ALTER TABLE sale_alert ADD CONSTRAINT sale_alert_kind_check CHECK (kind IN (
  'price_divergence', 'discount_above_rule', 'discount_above_limit', 'operator_permission',
  'negative_stock', 'product_status', 'agreement_link', 'offline_zero_stock',
  'controlled_missing', 'controlled_release', 'controlled_pending', 'prescription_expired', 'prescription_type',
  'seller_permission', 'quote_status', 'return_permission', 'return_credit', 'auto_discount',
  'credit_limit', 'credit_blocked', 'credit_overdue', 'credit_schedule', 'credit_dependent', 'credit_release',
  'cashback_use', 'agreement_limit'
));

CREATE FUNCTION app.local_day(p_at timestamptz) RETURNS date
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$ SELECT (p_at AT TIME ZONE 'America/Sao_Paulo')::date $$;

-- O que ainda não está em fatura (fechada ou paga) do convênio, até a data: vendas pagas no
-- convênio e devoluções com destino convênio de vendas dele (pelo valor que vai para o destino).
CREATE FUNCTION app.agreement_open_items(p_agreement_id uuid, p_until date)
RETURNS TABLE (
  kind text, sale_payment_id uuid, sale_return_id uuid, customer_id uuid, customer_name text, registration text,
  occurred_at timestamptz, sale_code text, return_code text, amount numeric
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT 'sale', p.id, NULL::uuid, s.customer_id, c.name,
         (SELECT ca.registration FROM public.customer_agreement ca
           WHERE ca.customer_id = s.customer_id AND ca.agreement_id = p_agreement_id
           ORDER BY ca.deleted_at NULLS FIRST, ca.created_at DESC LIMIT 1),
         s.sold_at, s.code, NULL::text, p.amount
    FROM public.sale_payment p
    JOIN public.sale s ON s.id = p.sale_id AND s.deleted_at IS NULL
    LEFT JOIN public.customer c ON c.id = s.customer_id
   WHERE p.agreement_id = p_agreement_id AND p.method = 'agreement' AND p.deleted_at IS NULL
     AND app.local_day(s.sold_at) <= p_until
     AND NOT EXISTS (SELECT 1 FROM public.agreement_invoice_item i WHERE i.sale_payment_id = p.id AND i.deleted_at IS NULL)
  UNION ALL
  SELECT 'return', NULL::uuid, r.id, s.customer_id, c.name,
         (SELECT ca.registration FROM public.customer_agreement ca
           WHERE ca.customer_id = s.customer_id AND ca.agreement_id = p_agreement_id
           ORDER BY ca.deleted_at NULLS FIRST, ca.created_at DESC LIMIT 1),
         r.returned_at, s.code, r.code, -r.refund_amount
    FROM public.sale_return r
    JOIN public.sale s ON s.id = r.sale_id AND s.deleted_at IS NULL
    LEFT JOIN public.customer c ON c.id = s.customer_id
   WHERE r.destination = 'agreement' AND r.deleted_at IS NULL
     AND EXISTS (SELECT 1 FROM public.sale_payment p
                  WHERE p.sale_id = s.id AND p.method = 'agreement' AND p.agreement_id = p_agreement_id AND p.deleted_at IS NULL)
     AND app.local_day(r.returned_at) <= p_until
     AND NOT EXISTS (SELECT 1 FROM public.agreement_invoice_item i WHERE i.sale_return_id = r.id AND i.deleted_at IS NULL)
$$;

-- Último fechamento até hoje (o dia de fechamento deste mês, se já passou; senão o do mês anterior).
CREATE FUNCTION app.agreement_last_closing(p_closing_day smallint, p_today date) RETURNS date
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$
  SELECT CASE WHEN pg_catalog.date_part('day', p_today) >= p_closing_day
              THEN pg_catalog.make_date(pg_catalog.date_part('year', p_today)::integer, pg_catalog.date_part('month', p_today)::integer, p_closing_day)
              ELSE (pg_catalog.make_date(pg_catalog.date_part('year', p_today)::integer, pg_catalog.date_part('month', p_today)::integer, p_closing_day)
                    - pg_catalog.make_interval(months => 1))::date END
$$;

-- Convênio do grupo para quem administra convênios (FA006 se não for).
CREATE FUNCTION app.agreement_for_invoice(p_agreement_id uuid) RETURNS public.agreement
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.require_agreements_manage();
  found_agreement public.agreement;
BEGIN
  SELECT a.* INTO found_agreement FROM public.agreement a
   WHERE a.id = p_agreement_id AND a.economic_group_id = group_id AND a.deleted_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.' USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('agreement %s.', p_agreement_id);
  END IF;
  RETURN found_agreement;
END;
$$;

CREATE FUNCTION app.set_agreement_closing_day(p_agreement_id uuid, p_day integer) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.agreement := app.agreement_for_invoice(p_agreement_id);
BEGIN
  UPDATE public.agreement SET closing_day = p_day WHERE id = target.id;
END;
$$;

-- O que vai para a próxima fatura: período sugerido, itens e total por cliente.
CREATE FUNCTION app.agreement_invoice_preview(p_agreement_id uuid, p_until date DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.agreement := app.agreement_for_invoice(p_agreement_id);
  until date := COALESCE(p_until, app.agreement_last_closing(target.closing_day, app.local_day(pg_catalog.now())));
BEGIN
  RETURN pg_catalog.jsonb_build_object(
    'agreement_id', target.id, 'agreement_name', target.name, 'closing_day', target.closing_day,
    'period_start', (SELECT pg_catalog.max(i.period_end) + 1 FROM public.agreement_invoice i
                      WHERE i.agreement_id = target.id AND i.status <> 'cancelled' AND i.deleted_at IS NULL),
    'period_end', until,
    'items', COALESCE((SELECT pg_catalog.jsonb_agg(pg_catalog.to_jsonb(o) ORDER BY o.customer_name, o.occurred_at)
                         FROM app.agreement_open_items(target.id, until) o), '[]'::jsonb),
    'total', COALESCE((SELECT pg_catalog.sum(o.amount) FROM app.agreement_open_items(target.id, until) o), 0)
  );
END;
$$;

-- Fecha a fatura até a data (no máximo hoje, depois da fatura anterior). Sem nada a faturar, FA856.
CREATE FUNCTION app.close_agreement_invoice(p_agreement_id uuid, p_until date) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.agreement := app.agreement_for_invoice(p_agreement_id);
  previous_end date;
  first_day date;
  invoice_id uuid;
  invoice_total numeric;
BEGIN
  PERFORM 1 FROM public.agreement a WHERE a.id = target.id FOR UPDATE;
  SELECT pg_catalog.max(i.period_end) INTO previous_end FROM public.agreement_invoice i
   WHERE i.agreement_id = target.id AND i.status <> 'cancelled' AND i.deleted_at IS NULL;
  IF p_until IS NULL OR p_until > app.local_day(pg_catalog.now()) OR p_until <= previous_end THEN
    RAISE EXCEPTION 'Confira a data de fechamento da fatura.'
      USING ERRCODE = 'FA857', DETAIL = pg_catalog.format('Até %s, anterior %s.', p_until, previous_end);
  END IF;
  SELECT pg_catalog.sum(o.amount), pg_catalog.min(app.local_day(o.occurred_at)) INTO invoice_total, first_day
    FROM app.agreement_open_items(target.id, p_until) o;
  IF invoice_total IS NULL THEN
    RAISE EXCEPTION 'Não há vendas do convênio para faturar até esta data.'
      USING ERRCODE = 'FA856', DETAIL = pg_catalog.format('Convênio %s até %s.', target.id, p_until);
  END IF;
  INSERT INTO public.agreement_invoice (economic_group_id, agreement_id, period_start, period_end, total, closed_by)
  VALUES (target.economic_group_id, target.id, LEAST(COALESCE(previous_end + 1, first_day), first_day, p_until), p_until,
          invoice_total, app.current_user_id())
  RETURNING id INTO invoice_id;
  INSERT INTO public.agreement_invoice_item (
    economic_group_id, invoice_id, kind, sale_payment_id, sale_return_id, customer_id, registration, occurred_at, amount
  )
  SELECT target.economic_group_id, invoice_id, o.kind, o.sale_payment_id, o.sale_return_id, o.customer_id, o.registration,
         o.occurred_at, o.amount
    FROM app.agreement_open_items(target.id, p_until) o;
  RETURN invoice_id;
END;
$$;

CREATE FUNCTION app.agreement_invoice_for(p_invoice_id uuid) RETURNS public.agreement_invoice
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.require_agreements_manage();
  found_invoice public.agreement_invoice;
BEGIN
  SELECT i.* INTO found_invoice FROM public.agreement_invoice i
   WHERE i.id = p_invoice_id AND i.economic_group_id = group_id AND i.deleted_at IS NULL FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.' USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('agreement_invoice %s.', p_invoice_id);
  END IF;
  RETURN found_invoice;
END;
$$;

-- A empresa conveniada pagou a fatura.
CREATE FUNCTION app.pay_agreement_invoice(p_invoice_id uuid, p_paid_on date, p_note text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.agreement_invoice := app.agreement_invoice_for(p_invoice_id);
BEGIN
  IF target.status <> 'closed' THEN
    RAISE EXCEPTION 'Esta fatura não pode mais ser alterada.' USING ERRCODE = 'FA858', DETAIL = pg_catalog.format('Fatura em %s.', target.status);
  END IF;
  IF p_paid_on IS NULL OR p_paid_on > app.local_day(pg_catalog.now()) THEN
    RAISE EXCEPTION 'Confira a data de fechamento da fatura.' USING ERRCODE = 'FA857', DETAIL = pg_catalog.format('Pagamento em %s.', p_paid_on);
  END IF;
  UPDATE public.agreement_invoice
     SET status = 'paid', paid_on = p_paid_on, paid_note = NULLIF(pg_catalog.btrim(COALESCE(p_note, '')), ''), paid_by = app.current_user_id()
   WHERE id = target.id;
END;
$$;

-- Cancela a fatura fechada (com motivo): as vendas voltam para o próximo fechamento.
CREATE FUNCTION app.cancel_agreement_invoice(p_invoice_id uuid, p_reason text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.agreement_invoice := app.agreement_invoice_for(p_invoice_id);
  note text := pg_catalog.btrim(COALESCE(p_reason, ''));
BEGIN
  IF note = '' THEN
    RAISE EXCEPTION 'Informe o motivo desta ação.' USING ERRCODE = 'FA302';
  END IF;
  IF target.status <> 'closed' THEN
    RAISE EXCEPTION 'Esta fatura não pode mais ser alterada.' USING ERRCODE = 'FA858', DETAIL = pg_catalog.format('Fatura em %s.', target.status);
  END IF;
  -- Só a última fatura fechada do convênio: as anteriores dependem do período dela.
  IF EXISTS (SELECT 1 FROM public.agreement_invoice i WHERE i.agreement_id = target.agreement_id AND i.status <> 'cancelled'
               AND i.deleted_at IS NULL AND i.period_end > target.period_end) THEN
    RAISE EXCEPTION 'Esta fatura não pode mais ser alterada.' USING ERRCODE = 'FA858', DETAIL = 'Há fatura posterior.';
  END IF;
  UPDATE public.agreement_invoice SET status = 'cancelled', cancel_reason = note, cancelled_by = app.current_user_id() WHERE id = target.id;
  UPDATE public.agreement_invoice_item SET deleted_at = pg_catalog.now() WHERE invoice_id = target.id AND deleted_at IS NULL;
END;
$$;

CREATE FUNCTION app.list_agreement_invoices(p_agreement_id uuid)
RETURNS TABLE (
  id uuid, period_start date, period_end date, status text, total numeric, item_count integer, closed_by_name text,
  created_at timestamptz, paid_on date
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.agreement := app.agreement_for_invoice(p_agreement_id);
BEGIN
  RETURN QUERY
  SELECT i.id, i.period_start, i.period_end, i.status, i.total,
         (SELECT pg_catalog.count(*)::integer FROM public.agreement_invoice_item it WHERE it.invoice_id = i.id),
         u.name, i.created_at, i.paid_on
    FROM public.agreement_invoice i JOIN public.user_account u ON u.id = i.closed_by
   WHERE i.agreement_id = target.id AND i.deleted_at IS NULL
   ORDER BY i.period_end DESC, i.created_at DESC;
END;
$$;

-- Fatura para a retaguarda (e para imprimir e exportar): itens e total por cliente.
CREATE FUNCTION app.agreement_invoice_detail(p_invoice_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.require_agreements_manage();
  result jsonb;
BEGIN
  SELECT pg_catalog.jsonb_build_object(
    'id', i.id, 'agreement_id', a.id, 'agreement_name', a.name, 'agreement_cnpj', a.cnpj,
    'period_start', i.period_start, 'period_end', i.period_end, 'status', i.status, 'total', i.total,
    'closed_by_name', uc.name, 'created_at', i.created_at, 'paid_on', i.paid_on, 'paid_note', i.paid_note,
    'cancel_reason', i.cancel_reason,
    'items', COALESCE((
      SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
               'kind', it.kind, 'customer_name', c.name, 'registration', it.registration, 'occurred_at', it.occurred_at,
               'sale_code', s.code, 'return_code', r.code, 'amount', it.amount
             ) ORDER BY c.name, it.occurred_at)
        FROM public.agreement_invoice_item it
        LEFT JOIN public.customer c ON c.id = it.customer_id
        LEFT JOIN public.sale_payment p ON p.id = it.sale_payment_id
        LEFT JOIN public.sale_return r ON r.id = it.sale_return_id
        LEFT JOIN public.sale s ON s.id = COALESCE(p.sale_id, r.sale_id)
       WHERE it.invoice_id = i.id AND (it.deleted_at IS NULL OR i.status = 'cancelled')
    ), '[]'::jsonb),
    'customers', COALESCE((
      SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('customer_name', t.name, 'registration', t.registration, 'total', t.total)
                                  ORDER BY t.name)
        FROM (SELECT c.name, it.registration, pg_catalog.sum(it.amount) AS total
                FROM public.agreement_invoice_item it LEFT JOIN public.customer c ON c.id = it.customer_id
               WHERE it.invoice_id = i.id AND (it.deleted_at IS NULL OR i.status = 'cancelled')
               GROUP BY c.name, it.registration) t
    ), '[]'::jsonb)
  ) INTO result
    FROM public.agreement_invoice i
    JOIN public.agreement a ON a.id = i.agreement_id
    JOIN public.user_account uc ON uc.id = i.closed_by
   WHERE i.id = p_invoice_id AND i.economic_group_id = group_id AND i.deleted_at IS NULL;
  IF result IS NULL THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.' USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('agreement_invoice %s.', p_invoice_id);
  END IF;
  RETURN result;
END;
$$;

-- Quanto do limite do cliente no convênio está usado: compras menos devoluções que não estão em
-- fatura paga.
CREATE FUNCTION app.agreement_used(p_customer_id uuid, p_agreement_id uuid) RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE((
    SELECT pg_catalog.sum(p.amount) FROM public.sale_payment p JOIN public.sale s ON s.id = p.sale_id AND s.deleted_at IS NULL
     WHERE s.customer_id = p_customer_id AND p.agreement_id = p_agreement_id AND p.method = 'agreement' AND p.deleted_at IS NULL
       AND NOT EXISTS (SELECT 1 FROM public.agreement_invoice_item it JOIN public.agreement_invoice i ON i.id = it.invoice_id
                        WHERE it.sale_payment_id = p.id AND it.deleted_at IS NULL AND i.status = 'paid')
  ), 0) - COALESCE((
    SELECT pg_catalog.sum(r.refund_amount) FROM public.sale_return r JOIN public.sale s ON s.id = r.sale_id AND s.deleted_at IS NULL
     WHERE s.customer_id = p_customer_id AND r.destination = 'agreement' AND r.deleted_at IS NULL
       AND EXISTS (SELECT 1 FROM public.sale_payment p WHERE p.sale_id = s.id AND p.method = 'agreement'
                    AND p.agreement_id = p_agreement_id AND p.deleted_at IS NULL)
       AND NOT EXISTS (SELECT 1 FROM public.agreement_invoice_item it JOIN public.agreement_invoice i ON i.id = it.invoice_id
                        WHERE it.sale_return_id = r.id AND it.deleted_at IS NULL AND i.status = 'paid')
  ), 0)
$$;

-- O cliente desce de novo para os PDVs quando o limite usado no convênio muda pela fatura paga.
CREATE FUNCTION app.track_agreement_invoice() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NEW.status = 'paid' AND OLD.status IS DISTINCT FROM 'paid' THEN
    PERFORM app.mark_sync_change('customer', it.customer_id, NEW.economic_group_id, NULL)
       FROM (SELECT DISTINCT customer_id FROM public.agreement_invoice_item WHERE invoice_id = NEW.id AND customer_id IS NOT NULL) it;
  END IF;
  RETURN NULL;
END;
$$;
CREATE TRIGGER track_sync_change AFTER UPDATE ON agreement_invoice
  FOR EACH ROW EXECUTE FUNCTION app.track_agreement_invoice();

-- Venda vinda do PDV: limite do convênio.
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

-- Cliente para o PDV: o limite usado em cada convênio (formato 7 da descida).
CREATE OR REPLACE FUNCTION app.pdv_customer_data(p_terminal_id uuid, p_ids uuid[])
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
           'state', c.state,
           'customer_group_id', c.customer_group_id,
           'agreements', COALESCE((
             SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
                      'agreement_id', a.id, 'name', a.name, 'registration', ca.registration,
                      'credit_limit', ca.credit_limit, 'used', app.agreement_used(c.id, a.id)) ORDER BY a.name)
               FROM public.customer_agreement ca
               JOIN public.agreement a ON a.id = ca.agreement_id AND a.deleted_at IS NULL
              WHERE ca.customer_id = c.id AND ca.deleted_at IS NULL
           ), '[]'::jsonb),
           -- Crediário: limite, parâmetros e parcelas em aberto, para vender e receber sem internet.
           'credit', (
             SELECT pg_catalog.jsonb_build_object(
                      'account_id', a.id, 'status', a.status, 'credit_limit', a.credit_limit,
                      'terms', app.credit_terms(a), 'policy', app.credit_policy_json(a.home_branch_id),
                      'installments', app.credit_states(a.id),
                      'dependents', COALESCE((
                        SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
                                 'id', d.id, 'name', d.name, 'relationship', d.relationship) ORDER BY d.name, d.id)
                          FROM public.customer_dependent d
                         WHERE d.customer_id = c.id AND d.credit_allowed AND d.deleted_at IS NULL
                      ), '[]'::jsonb))
               FROM public.credit_account a WHERE a.customer_id = c.id AND a.deleted_at IS NULL
           )
         ) END
    FROM pg_catalog.unnest(p_ids) AS ids(id)
    LEFT JOIN public.pdv_customer_cache cc
      ON cc.customer_id = ids.id AND cc.terminal_id = p_terminal_id AND cc.deleted_at IS NULL
    LEFT JOIN public.customer c ON c.id = ids.id AND c.deleted_at IS NULL
     AND c.economic_group_id = (
       SELECT co.economic_group_id FROM public.terminal t
         JOIN public.branch b ON b.id = t.branch_id JOIN public.company co ON co.id = b.company_id
        WHERE t.id = p_terminal_id)
     AND (cc.id IS NOT NULL OR app.credit_has_debt(ids.id))
$$;

CREATE OR REPLACE FUNCTION app.pdv_sync_format() RETURNS integer
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$ SELECT 7 $$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  app.set_agreement_closing_day(uuid, integer),
  app.agreement_invoice_preview(uuid, date),
  app.close_agreement_invoice(uuid, date),
  app.pay_agreement_invoice(uuid, date, text),
  app.cancel_agreement_invoice(uuid, text),
  app.list_agreement_invoices(uuid),
  app.agreement_invoice_detail(uuid)
TO farmaerp_app;
