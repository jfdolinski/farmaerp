-- Up Migration

-- Sangria, suprimento e fechamento com conferência cega (Etapa 4, PR D1).
-- Sangria em três níveis: até o limite de sangria do operador, ele faz sozinho; acima, alguém com
-- limite que cubra o valor libera no PDV com código e PIN (supervisor e, acima do limite dele, o
-- gerente). O fechamento traz só o que o operador contou: o esperado é calculado aqui, com as vendas
-- e os movimentos do turno, e a diferença fica registrada para a retaguarda.

CREATE TABLE cash_movement (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  branch_id uuid NOT NULL REFERENCES branch (id),
  cash_session_id uuid NOT NULL REFERENCES cash_session (id),
  -- withdrawal: sangria (sai dinheiro da gaveta); supply: suprimento (entra troco).
  kind text NOT NULL CONSTRAINT cash_movement_kind_check CHECK (kind IN ('withdrawal', 'supply')),
  amount numeric(12, 2) NOT NULL CONSTRAINT cash_movement_amount_check CHECK (amount > 0),
  reason text NOT NULL CONSTRAINT cash_movement_reason_check CHECK (length(btrim(reason)) BETWEEN 1 AND 500),
  operator_id uuid NOT NULL REFERENCES user_account (id),
  released_by uuid REFERENCES user_account (id),
  moved_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid,
  CONSTRAINT cash_movement_release_check CHECK (released_by IS NULL OR (kind = 'withdrawal' AND released_by <> operator_id))
);
CREATE INDEX cash_movement_session_idx ON cash_movement (cash_session_id, moved_at);
CREATE INDEX cash_movement_branch_idx ON cash_movement (branch_id, moved_at DESC);
CREATE INDEX cash_movement_economic_group_id_idx ON cash_movement (economic_group_id);
CREATE INDEX cash_movement_operator_idx ON cash_movement (operator_id);
CREATE INDEX cash_movement_released_by_idx ON cash_movement (released_by);
CALL app.apply_table_standard('public.cash_movement');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON cash_movement
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'branch_id', 'cash_session_id', 'kind', 'amount', 'reason', 'operator_id', 'released_by', 'moved_at'
  );

-- Conferência do fechamento: o contado (do PDV) e o esperado (calculado aqui), por forma de pagamento.
CREATE TABLE cash_session_count (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  branch_id uuid NOT NULL REFERENCES branch (id),
  cash_session_id uuid NOT NULL REFERENCES cash_session (id),
  method text NOT NULL CONSTRAINT cash_session_count_method_check CHECK (method IN ('cash', 'credit_card', 'debit_card', 'pix')),
  counted numeric(12, 2) NOT NULL CONSTRAINT cash_session_count_counted_check CHECK (counted >= 0),
  expected numeric(12, 2) NOT NULL,
  difference numeric(12, 2) GENERATED ALWAYS AS (counted - expected) STORED,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE UNIQUE INDEX cash_session_count_method_key ON cash_session_count (cash_session_id, method) WHERE deleted_at IS NULL;
CREATE INDEX cash_session_count_economic_group_id_idx ON cash_session_count (economic_group_id);
CREATE INDEX cash_session_count_branch_idx ON cash_session_count (branch_id);
CALL app.apply_table_standard('public.cash_session_count');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON cash_session_count
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'branch_id', 'cash_session_id', 'method', 'counted', 'expected'
  );

-- O que a central achou no caixa: sangria acima do limite sem liberação válida e diferença no fechamento.
CREATE TABLE cash_alert (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  branch_id uuid NOT NULL REFERENCES branch (id),
  cash_session_id uuid NOT NULL REFERENCES cash_session (id),
  cash_movement_id uuid REFERENCES cash_movement (id),
  kind text NOT NULL CONSTRAINT cash_alert_kind_check CHECK (kind IN ('withdrawal_above_limit', 'closing_difference')),
  detail jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE INDEX cash_alert_session_idx ON cash_alert (cash_session_id);
CREATE INDEX cash_alert_movement_idx ON cash_alert (cash_movement_id);
CREATE INDEX cash_alert_economic_group_id_idx ON cash_alert (economic_group_id);
CREATE INDEX cash_alert_branch_idx ON cash_alert (branch_id);
CALL app.apply_table_standard('public.cash_alert');

ALTER TABLE cash_session ADD COLUMN closing_note text
  CONSTRAINT cash_session_closing_note_check CHECK (length(closing_note) <= 500);

-- Esperado de cada forma de pagamento no turno. Dinheiro: fundo de troco + vendas em dinheiro (menos
-- o troco) + suprimentos - sangrias. Convênio não passa pelo caixa e fica de fora.
CREATE FUNCTION app.cash_expected(p_session_id uuid)
RETURNS TABLE (method text, expected numeric)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT m.method,
         CASE WHEN m.method = 'cash' THEN
           cs.opening_float
           + COALESCE((SELECT pg_catalog.sum(p.amount - p.change_amount) FROM public.sale_payment p
                         JOIN public.sale s ON s.id = p.sale_id
                        WHERE s.cash_session_id = cs.id AND s.deleted_at IS NULL AND p.deleted_at IS NULL AND p.method = 'cash'), 0)
           + COALESCE((SELECT pg_catalog.sum(mv.amount) FROM public.cash_movement mv
                        WHERE mv.cash_session_id = cs.id AND mv.deleted_at IS NULL AND mv.kind = 'supply'), 0)
           - COALESCE((SELECT pg_catalog.sum(mv.amount) FROM public.cash_movement mv
                        WHERE mv.cash_session_id = cs.id AND mv.deleted_at IS NULL AND mv.kind = 'withdrawal'), 0)
         ELSE
           COALESCE((SELECT pg_catalog.sum(p.amount) FROM public.sale_payment p
                       JOIN public.sale s ON s.id = p.sale_id
                      WHERE s.cash_session_id = cs.id AND s.deleted_at IS NULL AND p.deleted_at IS NULL AND p.method = m.method), 0)
         END
    FROM public.cash_session cs
   CROSS JOIN (VALUES ('cash', 1), ('credit_card', 2), ('debit_card', 3), ('pix', 4)) AS m (method, position)
   WHERE cs.id = p_session_id
   ORDER BY m.position
$$;

-- Turno do terminal para um movimento ou fechamento: existe, é deste terminal e está aberto.
CREATE FUNCTION app.terminal_open_session(p_terminal public.terminal, p_session_id uuid) RETURNS public.cash_session
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  found_session public.cash_session;
BEGIN
  SELECT cs.* INTO found_session FROM public.cash_session cs WHERE cs.id = p_session_id AND cs.deleted_at IS NULL;
  IF NOT FOUND OR found_session.terminal_id <> p_terminal.id THEN
    RAISE EXCEPTION 'O movimento ou o fechamento de caixa enviado pelo terminal está inconsistente.'
      USING ERRCODE = 'FA995', DETAIL = pg_catalog.format('Turno %s não é deste terminal.', p_session_id);
  END IF;
  IF found_session.status = 'closed' THEN
    RAISE EXCEPTION 'Este turno de caixa já está fechado.'
      USING ERRCODE = 'FA996', DETAIL = pg_catalog.format('Turno %s.', p_session_id);
  END IF;
  RETURN found_session;
END;
$$;

-- Sangria ou suprimento vindo do PDV. A sangria acima do limite do operador precisa de quem libere
-- com limite que cubra o valor; sem isso, fica aplicada (o dinheiro já saiu) e vira alerta.
CREATE FUNCTION app.sync_apply_cash_movement(p_terminal public.terminal, p_group_id uuid, p_payload jsonb)
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
BEGIN
  IF (p_payload ->> 'id') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
     OR (p_payload ->> 'cash_session_id') !~ uuid_any
     OR (p_payload ->> 'operator_id') !~ uuid_any
     OR (p_payload ->> 'released_by' IS NOT NULL AND (p_payload ->> 'released_by') !~ uuid_any)
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
  BEGIN
    INSERT INTO public.cash_movement (
      id, economic_group_id, branch_id, cash_session_id, kind, amount, reason, operator_id, released_by, moved_at
    ) VALUES (
      movement_id, p_group_id, session_row.branch_id, session_row.id, p_payload ->> 'kind', amount,
      pg_catalog.btrim(COALESCE(p_payload ->> 'reason', '')), operator, releaser, (p_payload ->> 'moved_at')::timestamptz
    );
  EXCEPTION WHEN check_violation OR datetime_field_overflow OR invalid_datetime_format THEN
    RAISE EXCEPTION 'O movimento ou o fechamento de caixa enviado pelo terminal está inconsistente.'
      USING ERRCODE = 'FA995', DETAIL = pg_catalog.format('Movimento %s: %s.', movement_id, SQLERRM);
  END;

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

-- Fechamento com conferência cega: o PDV manda o contado de cada forma; a central calcula o
-- esperado, grava a diferença e fecha o turno. Qualquer diferença vira alerta.
CREATE FUNCTION app.sync_apply_cash_close(p_terminal public.terminal, p_group_id uuid, p_payload jsonb)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  session_row public.cash_session;
  closer uuid;
  counts jsonb := p_payload -> 'counts';
  method_name text;
  differences jsonb := '{}'::jsonb;
  row_expected record;
BEGIN
  IF (p_payload ->> 'cash_session_id') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
     OR (p_payload ->> 'closed_by') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
     OR (p_payload ->> 'closed_at') !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$'
     OR pg_catalog.jsonb_typeof(counts) IS DISTINCT FROM 'object'
     OR (SELECT pg_catalog.array_agg(k ORDER BY k) FROM pg_catalog.jsonb_object_keys(counts) AS k)
        IS DISTINCT FROM ARRAY['cash', 'credit_card', 'debit_card', 'pix']
     OR EXISTS (
       SELECT 1 FROM pg_catalog.jsonb_each(counts) AS c (key, value)
        WHERE pg_catalog.jsonb_typeof(c.value) IS DISTINCT FROM 'number'
           OR c.value::text::numeric NOT BETWEEN 0 AND 9999999999.99
           OR c.value::text::numeric <> round(c.value::text::numeric, 2)
     )
     OR (p_payload ->> 'note' IS NOT NULL AND length(p_payload ->> 'note') > 500) THEN
    RAISE EXCEPTION 'O movimento ou o fechamento de caixa enviado pelo terminal está inconsistente.'
      USING ERRCODE = 'FA995', DETAIL = 'Fechamento de caixa fora do formato.';
  END IF;
  session_row := app.terminal_open_session(p_terminal, (p_payload ->> 'cash_session_id')::uuid);
  closer := (p_payload ->> 'closed_by')::uuid;
  IF NOT EXISTS (SELECT 1 FROM public.user_account u WHERE u.id = closer AND u.economic_group_id = p_group_id) THEN
    RAISE EXCEPTION 'Um dos itens informados não foi encontrado.'
      USING ERRCODE = 'FA004', DETAIL = 'Quem fechou está fora do grupo.';
  END IF;

  FOR row_expected IN SELECT * FROM app.cash_expected(session_row.id) LOOP
    method_name := row_expected.method;
    INSERT INTO public.cash_session_count (economic_group_id, branch_id, cash_session_id, method, counted, expected)
    VALUES (p_group_id, session_row.branch_id, session_row.id, method_name, (counts ->> method_name)::numeric,
            row_expected.expected);
    IF (counts ->> method_name)::numeric <> row_expected.expected THEN
      differences := differences || pg_catalog.jsonb_build_object(method_name,
        (counts ->> method_name)::numeric - row_expected.expected);
    END IF;
  END LOOP;

  BEGIN
    UPDATE public.cash_session
       SET status = 'closed', closed_at = (p_payload ->> 'closed_at')::timestamptz, closed_by = closer,
           closing_note = NULLIF(pg_catalog.btrim(p_payload ->> 'note'), '')
     WHERE id = session_row.id;
  EXCEPTION WHEN datetime_field_overflow OR invalid_datetime_format THEN
    RAISE EXCEPTION 'O movimento ou o fechamento de caixa enviado pelo terminal está inconsistente.'
      USING ERRCODE = 'FA995', DETAIL = 'Data de fechamento impossível.';
  END;

  IF differences <> '{}'::jsonb THEN
    INSERT INTO public.cash_alert (economic_group_id, branch_id, cash_session_id, kind, detail)
    VALUES (p_group_id, session_row.branch_id, session_row.id, 'closing_difference', differences);
  END IF;
END;
$$;

-- Turnos para a retaguarda: abertos e fechados, com vendas, movimentos e a diferença do fechamento.
CREATE FUNCTION app.list_cash_sessions(
  p_branch_id uuid DEFAULT NULL, p_from date DEFAULT NULL, p_to date DEFAULT NULL, p_status text DEFAULT NULL
)
RETURNS TABLE (
  id uuid, branch_id uuid, branch_name text, terminal_name text, opened_by_name text, opened_at timestamptz,
  closed_by_name text, closed_at timestamptz, status text, opening_float numeric, sale_count integer, sales_total numeric,
  withdrawals numeric, supplies numeric, counted_total numeric, difference_total numeric, alert_count integer
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT cs.id, cs.branch_id, b.name, t.name, uo.name, cs.opened_at, uc.name, cs.closed_at, cs.status, cs.opening_float,
         (SELECT pg_catalog.count(*)::integer FROM public.sale s WHERE s.cash_session_id = cs.id AND s.deleted_at IS NULL),
         COALESCE((SELECT pg_catalog.sum(s.total) FROM public.sale s WHERE s.cash_session_id = cs.id AND s.deleted_at IS NULL), 0),
         COALESCE((SELECT pg_catalog.sum(m.amount) FROM public.cash_movement m
                    WHERE m.cash_session_id = cs.id AND m.deleted_at IS NULL AND m.kind = 'withdrawal'), 0),
         COALESCE((SELECT pg_catalog.sum(m.amount) FROM public.cash_movement m
                    WHERE m.cash_session_id = cs.id AND m.deleted_at IS NULL AND m.kind = 'supply'), 0),
         (SELECT pg_catalog.sum(c.counted) FROM public.cash_session_count c WHERE c.cash_session_id = cs.id AND c.deleted_at IS NULL),
         (SELECT pg_catalog.sum(c.difference) FROM public.cash_session_count c WHERE c.cash_session_id = cs.id AND c.deleted_at IS NULL),
         (SELECT pg_catalog.count(*)::integer FROM public.cash_alert a WHERE a.cash_session_id = cs.id AND a.deleted_at IS NULL)
    FROM public.cash_session cs
    JOIN public.branch b ON b.id = cs.branch_id
    JOIN public.terminal t ON t.id = cs.terminal_id
    JOIN public.user_account uo ON uo.id = cs.opened_by
    LEFT JOIN public.user_account uc ON uc.id = cs.closed_by
   WHERE cs.deleted_at IS NULL
     AND cs.economic_group_id = app.current_user_group()
     AND app.has_permission('sales.view', cs.branch_id)
     AND (p_branch_id IS NULL OR cs.branch_id = p_branch_id)
     AND (p_status IS NULL OR cs.status = p_status)
     AND (p_from IS NULL OR cs.opened_at >= p_from::timestamp AT TIME ZONE 'America/Sao_Paulo')
     AND (p_to IS NULL OR cs.opened_at < (p_to + 1)::timestamp AT TIME ZONE 'America/Sao_Paulo')
   ORDER BY cs.opened_at DESC, cs.id DESC
   LIMIT 500
$$;

-- Turno completo: conferência por forma, movimentos com quem liberou, e alertas. No turno aberto, o
-- esperado é o de agora (a retaguarda pode ver; o operador, no PDV, não).
CREATE FUNCTION app.cash_session_detail(p_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT pg_catalog.jsonb_build_object(
    'id', cs.id, 'branch_name', b.name, 'terminal_name', t.name, 'status', cs.status,
    'opened_by_name', uo.name, 'opened_at', cs.opened_at, 'opening_float', cs.opening_float,
    'closed_by_name', uc.name, 'closed_at', cs.closed_at, 'closing_note', cs.closing_note,
    'sale_count', (SELECT pg_catalog.count(*) FROM public.sale s WHERE s.cash_session_id = cs.id AND s.deleted_at IS NULL),
    'sales_total', COALESCE((SELECT pg_catalog.sum(s.total) FROM public.sale s WHERE s.cash_session_id = cs.id AND s.deleted_at IS NULL), 0),
    'counts', CASE WHEN cs.status = 'closed' THEN (
      SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'method', c.method, 'counted', c.counted, 'expected', c.expected, 'difference', c.difference
      ) ORDER BY pg_catalog.array_position(ARRAY['cash', 'credit_card', 'debit_card', 'pix'], c.method))
        FROM public.cash_session_count c WHERE c.cash_session_id = cs.id AND c.deleted_at IS NULL
    ) ELSE (
      SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'method', e.method, 'counted', NULL, 'expected', e.expected, 'difference', NULL))
        FROM app.cash_expected(cs.id) e
    ) END,
    'movements', COALESCE((
      SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', m.id, 'kind', m.kind, 'amount', m.amount, 'reason', m.reason, 'moved_at', m.moved_at,
        'operator_name', uop.name, 'released_by_name', ur.name
      ) ORDER BY m.moved_at, m.id)
        FROM public.cash_movement m
        JOIN public.user_account uop ON uop.id = m.operator_id
        LEFT JOIN public.user_account ur ON ur.id = m.released_by
       WHERE m.cash_session_id = cs.id AND m.deleted_at IS NULL
    ), '[]'::jsonb),
    'alerts', COALESCE((
      SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'kind', a.kind, 'movement_id', a.cash_movement_id, 'detail', a.detail
      ) ORDER BY a.created_at, a.id)
        FROM public.cash_alert a WHERE a.cash_session_id = cs.id AND a.deleted_at IS NULL
    ), '[]'::jsonb)
  )
    FROM public.cash_session cs
    JOIN public.branch b ON b.id = cs.branch_id
    JOIN public.terminal t ON t.id = cs.terminal_id
    JOIN public.user_account uo ON uo.id = cs.opened_by
    LEFT JOIN public.user_account uc ON uc.id = cs.closed_by
   WHERE cs.id = p_id AND cs.deleted_at IS NULL
     AND cs.economic_group_id = app.current_user_group()
     AND app.has_permission('sales.view', cs.branch_id)
$$;

CREATE POLICY cash_movement_select ON cash_movement FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group()) AND app.has_permission('sales.view', branch_id));
CREATE POLICY cash_session_count_select ON cash_session_count FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group()) AND app.has_permission('sales.view', branch_id));
CREATE POLICY cash_alert_select ON cash_alert FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group()) AND app.has_permission('sales.view', branch_id));
GRANT SELECT ON cash_movement, cash_session_count, cash_alert TO farmaerp_app;
CREATE VIEW v_cash_movement WITH (security_invoker = true) AS SELECT * FROM cash_movement WHERE deleted_at IS NULL;
CREATE VIEW v_cash_session_count WITH (security_invoker = true) AS SELECT * FROM cash_session_count WHERE deleted_at IS NULL;
CREATE VIEW v_cash_alert WITH (security_invoker = true) AS SELECT * FROM cash_alert WHERE deleted_at IS NULL;
GRANT SELECT ON v_cash_movement, v_cash_session_count, v_cash_alert TO farmaerp_app;

-- A subida aceita os movimentos e o fechamento do caixa.
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

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  app.list_cash_sessions(uuid, date, date, text),
  app.cash_session_detail(uuid)
TO farmaerp_app;
