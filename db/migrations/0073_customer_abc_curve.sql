-- Up Migration

-- Parte D do lote de 26/11: curva ABC de clientes por filial. Conta as vendas de cada cliente na
-- filial no período (as do PDV e as importadas do sistema anterior; canceladas não contam): A a
-- partir de N vendas, B a partir de M, C o resto. Cada curva tem o seu intervalo de recálculo: na vez
-- dela, entram os clientes que agora se encaixam nela e saem (para a curva certa) os que não se
-- encaixam mais. A rotina da API roda de hora em hora; "Recalcular agora" roda as três. A curva desce
-- para o PDV junto com os dados do cliente.

CREATE TABLE abc_curve_setting (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  branch_id uuid NOT NULL REFERENCES branch (id),
  period_days smallint NOT NULL DEFAULT 180 CONSTRAINT abc_curve_setting_period_check CHECK (period_days BETWEEN 7 AND 730),
  a_min_sales integer NOT NULL DEFAULT 12 CONSTRAINT abc_curve_setting_a_min_check CHECK (a_min_sales BETWEEN 2 AND 100000),
  b_min_sales integer NOT NULL DEFAULT 4 CONSTRAINT abc_curve_setting_b_min_check CHECK (b_min_sales BETWEEN 1 AND 100000),
  a_interval_days smallint NOT NULL DEFAULT 7 CONSTRAINT abc_curve_setting_a_interval_check CHECK (a_interval_days BETWEEN 1 AND 365),
  b_interval_days smallint NOT NULL DEFAULT 15 CONSTRAINT abc_curve_setting_b_interval_check CHECK (b_interval_days BETWEEN 1 AND 365),
  c_interval_days smallint NOT NULL DEFAULT 30 CONSTRAINT abc_curve_setting_c_interval_check CHECK (c_interval_days BETWEEN 1 AND 365),
  a_ran_at timestamptz,
  b_ran_at timestamptz,
  c_ran_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid,
  CONSTRAINT abc_curve_setting_order_check CHECK (b_min_sales < a_min_sales)
);
CREATE UNIQUE INDEX abc_curve_setting_branch_key ON abc_curve_setting (branch_id) WHERE deleted_at IS NULL;
CREATE INDEX abc_curve_setting_economic_group_id_idx ON abc_curve_setting (economic_group_id);
CALL app.apply_table_standard('public.abc_curve_setting');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON abc_curve_setting
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns('economic_group_id', 'branch_id');
CREATE POLICY abc_curve_setting_select ON abc_curve_setting FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group()) AND app.has_permission('customers.view', branch_id));
CREATE VIEW v_abc_curve_setting WITH (security_invoker = true) AS SELECT * FROM abc_curve_setting WHERE deleted_at IS NULL;

-- Curva de agora do cliente na filial.
CREATE TABLE customer_abc (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  branch_id uuid NOT NULL REFERENCES branch (id),
  customer_id uuid NOT NULL REFERENCES customer (id),
  curve text NOT NULL CONSTRAINT customer_abc_curve_check CHECK (curve IN ('A', 'B', 'C')),
  sales_count integer NOT NULL CONSTRAINT customer_abc_sales_count_check CHECK (sales_count >= 0),
  calculated_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE UNIQUE INDEX customer_abc_branch_customer_key ON customer_abc (branch_id, customer_id) WHERE deleted_at IS NULL;
CREATE INDEX customer_abc_customer_idx ON customer_abc (customer_id);
CREATE INDEX customer_abc_curve_idx ON customer_abc (branch_id, curve) WHERE deleted_at IS NULL;
CREATE INDEX customer_abc_economic_group_id_idx ON customer_abc (economic_group_id);
CALL app.apply_table_standard('public.customer_abc');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON customer_abc
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns('economic_group_id', 'branch_id', 'customer_id');
CREATE POLICY customer_abc_select ON customer_abc FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group()) AND app.has_permission('customers.view', branch_id));
CREATE VIEW v_customer_abc WITH (security_invoker = true) AS SELECT * FROM customer_abc WHERE deleted_at IS NULL;

-- Histórico das mudanças de curva. Ninguém altera.
CREATE TABLE customer_abc_event (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  branch_id uuid NOT NULL REFERENCES branch (id),
  customer_id uuid NOT NULL REFERENCES customer (id),
  from_curve text CONSTRAINT customer_abc_event_from_check CHECK (from_curve IN ('A', 'B', 'C')),
  to_curve text NOT NULL CONSTRAINT customer_abc_event_to_check CHECK (to_curve IN ('A', 'B', 'C')),
  sales_count integer NOT NULL CONSTRAINT customer_abc_event_sales_count_check CHECK (sales_count >= 0),
  period_days smallint NOT NULL CONSTRAINT customer_abc_event_period_check CHECK (period_days BETWEEN 7 AND 730),
  occurred_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid,
  CONSTRAINT customer_abc_event_change_check CHECK (from_curve IS DISTINCT FROM to_curve)
);
CREATE INDEX customer_abc_event_customer_idx ON customer_abc_event (customer_id, occurred_at DESC);
CREATE INDEX customer_abc_event_branch_idx ON customer_abc_event (branch_id, occurred_at DESC);
CREATE INDEX customer_abc_event_economic_group_id_idx ON customer_abc_event (economic_group_id);
CALL app.apply_table_standard('public.customer_abc_event');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON customer_abc_event
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'branch_id', 'customer_id', 'from_curve', 'to_curve', 'sales_count', 'period_days', 'occurred_at'
  );
CREATE POLICY customer_abc_event_select ON customer_abc_event FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group()) AND app.has_permission('customers.view', branch_id));
CREATE VIEW v_customer_abc_event WITH (security_invoker = true) AS SELECT * FROM customer_abc_event WHERE deleted_at IS NULL;

-- Parâmetros da filial: os gravados ou os padrões (180 dias, A >= 12, B >= 4; 7, 15 e 30 dias).
CREATE FUNCTION app.abc_setting(p_branch_id uuid) RETURNS public.abc_curve_setting
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  found public.abc_curve_setting;
BEGIN
  SELECT * INTO found FROM public.abc_curve_setting s WHERE s.branch_id = p_branch_id AND s.deleted_at IS NULL;
  IF found.id IS NULL THEN
    found.branch_id := p_branch_id;
    found.period_days := 180;
    found.a_min_sales := 12;
    found.b_min_sales := 4;
    found.a_interval_days := 7;
    found.b_interval_days := 15;
    found.c_interval_days := 30;
  END IF;
  RETURN found;
END;
$$;

-- Grupo da filial.
CREATE FUNCTION app.branch_group(p_branch_id uuid) RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT c.economic_group_id FROM public.branch b JOIN public.company c ON c.id = b.company_id WHERE b.id = p_branch_id
$$;

-- Recalcula uma curva da filial: entram os clientes que agora se encaixam nela e saem (para a curva
-- certa) os que estavam nela e não se encaixam mais. Devolve quantos mudaram de curva.
CREATE FUNCTION app.abc_recalculate(p_branch_id uuid, p_curve text, p_at timestamptz) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  setting public.abc_curve_setting := app.abc_setting(p_branch_id);
  group_id uuid := app.branch_group(p_branch_id);
  since timestamptz;
  target record;
  changed integer := 0;
BEGIN
  IF p_curve IS NULL OR p_curve NOT IN ('A', 'B', 'C') OR group_id IS NULL THEN
    RAISE EXCEPTION 'Alguns dados informados são inválidos.' USING ERRCODE = 'FA005', DETAIL = 'Curva ABC.';
  END IF;
  since := p_at - pg_catalog.make_interval(days => setting.period_days);
  FOR target IN
    WITH counts AS (
      SELECT x.customer_id, pg_catalog.count(*)::integer AS sales_count FROM (
        SELECT s.customer_id FROM public.sale s
         WHERE s.branch_id = p_branch_id AND s.customer_id IS NOT NULL AND s.deleted_at IS NULL AND s.canceled_at IS NULL
           AND s.sold_at > since AND s.sold_at <= p_at
        UNION ALL
        SELECT i.customer_id FROM public.imported_sale i
         WHERE i.branch_id = p_branch_id AND i.customer_id IS NOT NULL AND i.deleted_at IS NULL AND i.canceled_at IS NULL
           AND i.emitted_at > since AND i.emitted_at <= p_at
      ) x GROUP BY x.customer_id
    ), current AS (
      SELECT a.customer_id, a.curve FROM public.customer_abc a WHERE a.branch_id = p_branch_id AND a.deleted_at IS NULL
    ), decided AS (
      SELECT COALESCE(n.customer_id, c.customer_id) AS customer_id, COALESCE(n.sales_count, 0) AS sales_count, c.curve AS old_curve,
             CASE WHEN COALESCE(n.sales_count, 0) >= setting.a_min_sales THEN 'A'
                  WHEN COALESCE(n.sales_count, 0) >= setting.b_min_sales THEN 'B' ELSE 'C' END AS new_curve
        FROM counts n FULL JOIN current c ON c.customer_id = n.customer_id
    )
    SELECT * FROM decided d WHERE d.old_curve = p_curve OR d.new_curve = p_curve
  LOOP
    IF target.old_curve IS NULL THEN
      INSERT INTO public.customer_abc (economic_group_id, branch_id, customer_id, curve, sales_count, calculated_at)
      VALUES (group_id, p_branch_id, target.customer_id, target.new_curve, target.sales_count, p_at);
    ELSE
      UPDATE public.customer_abc a SET curve = target.new_curve, sales_count = target.sales_count, calculated_at = p_at
       WHERE a.branch_id = p_branch_id AND a.customer_id = target.customer_id AND a.deleted_at IS NULL;
    END IF;
    IF target.old_curve IS DISTINCT FROM target.new_curve THEN
      INSERT INTO public.customer_abc_event (
        economic_group_id, branch_id, customer_id, from_curve, to_curve, sales_count, period_days, occurred_at
      ) VALUES (group_id, p_branch_id, target.customer_id, target.old_curve, target.new_curve, target.sales_count, setting.period_days, p_at);
      -- A curva desce para os caixas junto com os dados do cliente.
      PERFORM app.mark_sync_change('customer', target.customer_id, group_id, NULL);
      changed := changed + 1;
    END IF;
  END LOOP;
  IF setting.id IS NULL THEN
    INSERT INTO public.abc_curve_setting (economic_group_id, branch_id) VALUES (group_id, p_branch_id) RETURNING * INTO setting;
  END IF;
  UPDATE public.abc_curve_setting s
     SET a_ran_at = CASE WHEN p_curve = 'A' THEN p_at ELSE s.a_ran_at END,
         b_ran_at = CASE WHEN p_curve = 'B' THEN p_at ELSE s.b_ran_at END,
         c_ran_at = CASE WHEN p_curve = 'C' THEN p_at ELSE s.c_ran_at END
   WHERE s.id = setting.id;
  RETURN changed;
END;
$$;

CREATE FUNCTION app.require_abc_worker() RETURNS void
LANGUAGE plpgsql STABLE
SET search_path = ''
AS $$
BEGIN
  IF app.current_user_id() IS NOT NULL OR COALESCE(pg_catalog.current_setting('app.worker', true), '') <> 'abc' THEN
    RAISE EXCEPTION 'Você não tem permissão para esta operação.'
      USING ERRCODE = 'FA002', DETAIL = 'Curva ABC fora da rotina.';
  END IF;
END;
$$;

-- Rotina (de hora em hora): as curvas que venceram em todas as filiais. Filial sem parâmetros usa os
-- padrões e, na primeira vez, calcula as três.
CREATE FUNCTION app.abc_run_due(p_at timestamptz) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  branch_row record;
  setting public.abc_curve_setting;
  runs integer := 0;
  changed integer := 0;
BEGIN
  PERFORM app.require_abc_worker();
  FOR branch_row IN
    SELECT b.id FROM public.branch b JOIN public.company c ON c.id = b.company_id
     WHERE b.deleted_at IS NULL AND c.deleted_at IS NULL ORDER BY b.id
  LOOP
    setting := app.abc_setting(branch_row.id);
    IF setting.a_ran_at IS NULL OR setting.a_ran_at + pg_catalog.make_interval(days => setting.a_interval_days) <= p_at THEN
      changed := changed + app.abc_recalculate(branch_row.id, 'A', p_at);
      runs := runs + 1;
    END IF;
    IF setting.b_ran_at IS NULL OR setting.b_ran_at + pg_catalog.make_interval(days => setting.b_interval_days) <= p_at THEN
      changed := changed + app.abc_recalculate(branch_row.id, 'B', p_at);
      runs := runs + 1;
    END IF;
    IF setting.c_ran_at IS NULL OR setting.c_ran_at + pg_catalog.make_interval(days => setting.c_interval_days) <= p_at THEN
      changed := changed + app.abc_recalculate(branch_row.id, 'C', p_at);
      runs := runs + 1;
    END IF;
  END LOOP;
  RETURN pg_catalog.jsonb_build_object('runs', runs, 'changed', changed);
END;
$$;

-- Retaguarda: parâmetros e contagem por curva das filiais que a pessoa vê.
CREATE FUNCTION app.abc_settings()
RETURNS TABLE (
  branch_id uuid, branch_name text, period_days smallint, a_min_sales integer, b_min_sales integer,
  a_interval_days smallint, b_interval_days smallint, c_interval_days smallint,
  a_ran_at timestamptz, b_ran_at timestamptz, c_ran_at timestamptz, a_count integer, b_count integer, c_count integer,
  can_manage boolean
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT b.id, b.name, s.period_days, s.a_min_sales, s.b_min_sales, s.a_interval_days, s.b_interval_days, s.c_interval_days,
         s.a_ran_at, s.b_ran_at, s.c_ran_at,
         (SELECT pg_catalog.count(*)::integer FROM public.customer_abc a WHERE a.branch_id = b.id AND a.curve = 'A' AND a.deleted_at IS NULL),
         (SELECT pg_catalog.count(*)::integer FROM public.customer_abc a WHERE a.branch_id = b.id AND a.curve = 'B' AND a.deleted_at IS NULL),
         (SELECT pg_catalog.count(*)::integer FROM public.customer_abc a WHERE a.branch_id = b.id AND a.curve = 'C' AND a.deleted_at IS NULL),
         app.has_permission('customers.manage', b.id)
    FROM public.branch b
    JOIN public.company c ON c.id = b.company_id
    CROSS JOIN LATERAL app.abc_setting(b.id) s
   WHERE b.deleted_at IS NULL AND c.economic_group_id = app.current_user_group() AND app.has_permission('customers.view', b.id)
   ORDER BY b.name, b.id
$$;

-- Troca os parâmetros da filial (quem cadastra clientes nela). Os intervalos novos valem na próxima
-- rodada da rotina.
CREATE FUNCTION app.set_abc_settings(p_branch_id uuid, p_data jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.branch_group(p_branch_id);
  field text;
BEGIN
  IF group_id IS DISTINCT FROM app.current_user_group() OR NOT app.has_permission('customers.manage', p_branch_id) THEN
    RAISE EXCEPTION 'Você não tem permissão para esta operação.' USING ERRCODE = 'FA002', DETAIL = 'Curva ABC sem customers.manage.';
  END IF;
  IF pg_catalog.jsonb_typeof(p_data) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'Alguns dados informados são inválidos.' USING ERRCODE = 'FA005', DETAIL = 'Parâmetros da curva ABC.';
  END IF;
  FOREACH field IN ARRAY ARRAY['periodDays', 'aMinSales', 'bMinSales', 'aIntervalDays', 'bIntervalDays', 'cIntervalDays'] LOOP
    IF pg_catalog.jsonb_typeof(p_data -> field) IS DISTINCT FROM 'number' OR (p_data ->> field) !~ '^\d{1,6}$' THEN
      RAISE EXCEPTION 'Alguns dados informados são inválidos.' USING ERRCODE = 'FA005', DETAIL = pg_catalog.format('Campo %s.', field);
    END IF;
  END LOOP;
  IF NOT EXISTS (SELECT 1 FROM public.abc_curve_setting s WHERE s.branch_id = p_branch_id AND s.deleted_at IS NULL) THEN
    INSERT INTO public.abc_curve_setting (economic_group_id, branch_id) VALUES (group_id, p_branch_id);
  END IF;
  UPDATE public.abc_curve_setting s
     SET period_days = (p_data ->> 'periodDays')::smallint,
         a_min_sales = (p_data ->> 'aMinSales')::integer,
         b_min_sales = (p_data ->> 'bMinSales')::integer,
         a_interval_days = (p_data ->> 'aIntervalDays')::smallint,
         b_interval_days = (p_data ->> 'bIntervalDays')::smallint,
         c_interval_days = (p_data ->> 'cIntervalDays')::smallint
   WHERE s.branch_id = p_branch_id AND s.deleted_at IS NULL;
END;
$$;

-- "Recalcular agora": as três curvas da filial (quem cadastra clientes nela).
CREATE FUNCTION app.abc_recalculate_now(p_branch_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  at timestamptz := pg_catalog.now();
  changed integer := 0;
BEGIN
  IF app.branch_group(p_branch_id) IS DISTINCT FROM app.current_user_group() OR NOT app.has_permission('customers.manage', p_branch_id) THEN
    RAISE EXCEPTION 'Você não tem permissão para esta operação.' USING ERRCODE = 'FA002', DETAIL = 'Curva ABC sem customers.manage.';
  END IF;
  changed := app.abc_recalculate(p_branch_id, 'A', at) + app.abc_recalculate(p_branch_id, 'B', at) + app.abc_recalculate(p_branch_id, 'C', at);
  RETURN pg_catalog.jsonb_build_object('changed', changed);
END;
$$;

-- Clientes da curva na filial (até 500), com busca por nome ou código.
CREATE FUNCTION app.abc_customers(p_branch_id uuid, p_curve text, p_search text DEFAULT NULL)
RETURNS TABLE (customer_id uuid, code bigint, name text, curve text, sales_count integer, calculated_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT c.id, c.code, c.name, a.curve, a.sales_count, a.calculated_at
    FROM public.customer_abc a
    JOIN public.customer c ON c.id = a.customer_id AND c.deleted_at IS NULL
   WHERE a.branch_id = p_branch_id AND a.deleted_at IS NULL AND (p_curve IS NULL OR a.curve = p_curve)
     AND a.economic_group_id = app.current_user_group() AND app.has_permission('customers.view', p_branch_id)
     AND (NULLIF(pg_catalog.btrim(p_search), '') IS NULL
          OR c.name ILIKE '%' || pg_catalog.btrim(p_search) || '%' OR c.code::text = pg_catalog.btrim(p_search))
   ORDER BY a.sales_count DESC, c.name, c.id
   LIMIT 500
$$;

-- Curva do cliente em cada filial que a pessoa vê.
CREATE FUNCTION app.customer_abc_curves(p_customer_id uuid)
RETURNS TABLE (branch_id uuid, branch_name text, curve text, sales_count integer, calculated_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT b.id, b.name, a.curve, a.sales_count, a.calculated_at
    FROM public.customer_abc a
    JOIN public.branch b ON b.id = a.branch_id
   WHERE a.customer_id = p_customer_id AND a.deleted_at IS NULL
     AND a.economic_group_id = app.current_user_group() AND app.has_permission('customers.view', a.branch_id)
   ORDER BY b.name
$$;

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
           'abc_curve', (
             SELECT a.curve FROM public.customer_abc a
              WHERE a.customer_id = c.id AND a.deleted_at IS NULL
                AND a.branch_id = (SELECT t.branch_id FROM public.terminal t WHERE t.id = p_terminal_id)
           ),
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


REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  app.abc_run_due(timestamptz),
  app.abc_settings(),
  app.set_abc_settings(uuid, jsonb),
  app.abc_recalculate_now(uuid),
  app.abc_customers(uuid, text, text),
  app.customer_abc_curves(uuid)
TO farmaerp_app;
