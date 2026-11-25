-- Up Migration

-- Etapa 7, PR 7B-1: crediário (banco e retaguarda).
-- Cada cliente pode ter uma conta de crediário com limite. Dependentes marcados compram na conta do
-- titular. A venda no crediário (forma store_credit) gera parcelas imutáveis; os recebimentos, feitos
-- no caixa de qualquer loja, abatem primeiro multa e juros de todas as parcelas em atraso e depois o
-- valor das parcelas, da mais antiga para a mais nova. Multa (até 2%, uma vez por parcela) e juros
-- (simples, por dia) seguem os parâmetros da filial da conta. Vencimento por fechamento (fatura
-- mensal) ou por dias corridos, com padrão da filial e exceção por conta, valendo para compras novas.
-- As contas (vencimentos, divisão das parcelas, encargos e abatimento) são funções puras conferidas
-- pelos mesmos casos do PDV (packages/credit-cases/cases.json). Na central, a venda acima do limite,
-- com a conta bloqueada, em atraso ou com vencimentos diferentes vale (já aconteceu) e vira alerta.
-- Clientes com débito descem para todos os terminais da rede.

INSERT INTO permission (code, module, name) VALUES
  ('credit.view', 'Crediário', 'Ver o crediário dos clientes'),
  ('credit.manage', 'Crediário', 'Abrir crediário, mudar limite e bloquear'),
  ('credit.policy', 'Crediário', 'Definir multa, juros e vencimentos do crediário da filial');
INSERT INTO role_permission (role_id, permission_id)
SELECT r.id, p.id
  FROM role r JOIN permission p ON p.code IN ('credit.view', 'credit.manage')
 WHERE r.deleted_at IS NULL AND r.system_key IS NULL AND r.name = 'Gerente'
   AND NOT EXISTS (SELECT 1 FROM role_permission rp WHERE rp.role_id = r.id AND rp.permission_id = p.id);

-- Parâmetros do crediário da filial. Sem linha, valem os padrões (app.credit_policy_json).
CREATE TABLE credit_policy (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  branch_id uuid NOT NULL REFERENCES branch (id),
  -- Multa por atraso: o Código de Defesa do Consumidor limita a 2%.
  late_fee_percent numeric(5, 2) NOT NULL DEFAULT 2 CONSTRAINT credit_policy_fee_check CHECK (late_fee_percent BETWEEN 0 AND 2),
  monthly_interest_percent numeric(5, 2) NOT NULL DEFAULT 1
    CONSTRAINT credit_policy_interest_check CHECK (monthly_interest_percent BETWEEN 0 AND 10),
  max_installments smallint NOT NULL DEFAULT 3 CONSTRAINT credit_policy_installments_check CHECK (max_installments BETWEEN 1 AND 24),
  -- Limite sugerido: média mensal das compras dos últimos 6 meses vezes o fator.
  limit_factor numeric(5, 2) NOT NULL DEFAULT 1 CONSTRAINT credit_policy_factor_check CHECK (limit_factor BETWEEN 0.1 AND 10),
  -- Parcela vencida há mais que isso bloqueia novas compras no crediário.
  block_after_days smallint NOT NULL DEFAULT 30 CONSTRAINT credit_policy_block_check CHECK (block_after_days BETWEEN 1 AND 365),
  due_mode text NOT NULL DEFAULT 'closing' CONSTRAINT credit_policy_mode_check CHECK (due_mode IN ('closing', 'days')),
  closing_day smallint NOT NULL DEFAULT 25 CONSTRAINT credit_policy_closing_check CHECK (closing_day BETWEEN 1 AND 28),
  due_day smallint NOT NULL DEFAULT 10 CONSTRAINT credit_policy_due_check CHECK (due_day BETWEEN 1 AND 28),
  interval_days smallint NOT NULL DEFAULT 30 CONSTRAINT credit_policy_interval_check CHECK (interval_days BETWEEN 7 AND 90),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE UNIQUE INDEX credit_policy_branch_key ON credit_policy (branch_id) WHERE deleted_at IS NULL;
CREATE INDEX credit_policy_economic_group_id_idx ON credit_policy (economic_group_id);

CREATE TABLE credit_account (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  customer_id uuid NOT NULL REFERENCES customer (id),
  -- Filial da conta: os parâmetros dela valem para a conta, e quem vê e mexe é quem tem permissão nela.
  home_branch_id uuid NOT NULL REFERENCES branch (id),
  credit_limit numeric(12, 2) NOT NULL CONSTRAINT credit_account_limit_check CHECK (credit_limit BETWEEN 0 AND 9999999.99),
  status text NOT NULL DEFAULT 'active' CONSTRAINT credit_account_status_check CHECK (status IN ('active', 'blocked')),
  -- Exceção da conta; vazio usa o padrão da filial.
  due_mode text CONSTRAINT credit_account_mode_check CHECK (due_mode IN ('closing', 'days')),
  closing_day smallint CONSTRAINT credit_account_closing_check CHECK (closing_day BETWEEN 1 AND 28),
  due_day smallint CONSTRAINT credit_account_due_check CHECK (due_day BETWEEN 1 AND 28),
  interval_days smallint CONSTRAINT credit_account_interval_check CHECK (interval_days BETWEEN 7 AND 90),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid,
  CONSTRAINT credit_account_terms_check CHECK (
    (due_mode IS NULL AND closing_day IS NULL AND due_day IS NULL AND interval_days IS NULL)
    OR (due_mode = 'closing' AND closing_day IS NOT NULL AND due_day IS NOT NULL AND interval_days IS NULL)
    OR (due_mode = 'days' AND closing_day IS NULL AND due_day IS NULL AND interval_days IS NOT NULL)
  )
);
CREATE UNIQUE INDEX credit_account_customer_key ON credit_account (customer_id) WHERE deleted_at IS NULL;
CREATE INDEX credit_account_economic_group_id_idx ON credit_account (economic_group_id);
CREATE INDEX credit_account_home_branch_idx ON credit_account (home_branch_id);

-- Histórico da conta: abertura, limite, bloqueio e vencimentos. Quem, quando, antes, depois e por quê.
CREATE TABLE credit_account_event (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  account_id uuid NOT NULL REFERENCES credit_account (id),
  kind text NOT NULL CONSTRAINT credit_account_event_kind_check CHECK (kind IN ('opened', 'limit', 'blocked', 'unblocked', 'terms')),
  old_limit numeric(12, 2),
  new_limit numeric(12, 2),
  suggested_limit numeric(12, 2),
  detail jsonb NOT NULL DEFAULT '{}'::jsonb,
  reason text CONSTRAINT credit_account_event_reason_check CHECK (length(reason) BETWEEN 1 AND 500),
  changed_by uuid NOT NULL REFERENCES user_account (id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE INDEX credit_account_event_account_idx ON credit_account_event (account_id, created_at);
CREATE INDEX credit_account_event_economic_group_id_idx ON credit_account_event (economic_group_id);
CREATE INDEX credit_account_event_changed_by_idx ON credit_account_event (changed_by);

-- Parcelas da compra no crediário. Não mudam: o que muda é o que foi pago, nos abatimentos.
CREATE TABLE credit_installment (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  account_id uuid NOT NULL REFERENCES credit_account (id),
  sale_id uuid NOT NULL REFERENCES sale (id),
  sale_payment_id uuid NOT NULL REFERENCES sale_payment (id),
  branch_id uuid NOT NULL REFERENCES branch (id),
  -- Dependente que comprou na conta do titular.
  dependent_id uuid REFERENCES customer_dependent (id),
  number smallint NOT NULL CONSTRAINT credit_installment_number_check CHECK (number BETWEEN 1 AND 24),
  due_date date NOT NULL,
  amount numeric(12, 2) NOT NULL CONSTRAINT credit_installment_amount_check CHECK (amount > 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE UNIQUE INDEX credit_installment_payment_number_key ON credit_installment (sale_payment_id, number) WHERE deleted_at IS NULL;
CREATE INDEX credit_installment_account_idx ON credit_installment (account_id, due_date);
CREATE INDEX credit_installment_economic_group_id_idx ON credit_installment (economic_group_id);
CREATE INDEX credit_installment_sale_idx ON credit_installment (sale_id);
CREATE INDEX credit_installment_branch_idx ON credit_installment (branch_id);
CREATE INDEX credit_installment_dependent_idx ON credit_installment (dependent_id);

-- Recebimento no caixa. O id vem do PDV. excess: o que passou do devido (a central achou menos em
-- aberto que o PDV, por exemplo outro caixa recebeu antes); fica registrado e vira alerta do caixa.
CREATE TABLE credit_payment (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  account_id uuid NOT NULL REFERENCES credit_account (id),
  branch_id uuid NOT NULL REFERENCES branch (id),
  terminal_id uuid NOT NULL REFERENCES terminal (id),
  cash_session_id uuid NOT NULL REFERENCES cash_session (id),
  received_by uuid NOT NULL REFERENCES user_account (id),
  received_at timestamptz NOT NULL,
  method text NOT NULL CONSTRAINT credit_payment_method_check CHECK (method IN ('cash', 'credit_card', 'debit_card', 'pix')),
  amount numeric(12, 2) NOT NULL CONSTRAINT credit_payment_amount_check CHECK (amount > 0),
  excess numeric(12, 2) NOT NULL DEFAULT 0 CONSTRAINT credit_payment_excess_check CHECK (excess >= 0 AND excess <= amount),
  card_brand text CONSTRAINT credit_payment_card_brand_check CHECK (length(card_brand) <= 30),
  authorization_code text CONSTRAINT credit_payment_authorization_check CHECK (length(authorization_code) <= 30),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE INDEX credit_payment_account_idx ON credit_payment (account_id, received_at);
CREATE INDEX credit_payment_economic_group_id_idx ON credit_payment (economic_group_id);
CREATE INDEX credit_payment_branch_idx ON credit_payment (branch_id);
CREATE INDEX credit_payment_terminal_idx ON credit_payment (terminal_id);
CREATE INDEX credit_payment_session_idx ON credit_payment (cash_session_id);
CREATE INDEX credit_payment_received_by_idx ON credit_payment (received_by);

-- Quanto de cada recebimento foi para cada parcela. accrued_on: até quando os juros foram contados
-- (só depois do vencimento); interest_open_after: juros que ficaram em aberto nessa data.
CREATE TABLE credit_allocation (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  payment_id uuid NOT NULL REFERENCES credit_payment (id),
  installment_id uuid NOT NULL REFERENCES credit_installment (id),
  received_on date NOT NULL,
  fee numeric(12, 2) NOT NULL CONSTRAINT credit_allocation_fee_check CHECK (fee >= 0),
  interest numeric(12, 2) NOT NULL CONSTRAINT credit_allocation_interest_check CHECK (interest >= 0),
  principal numeric(12, 2) NOT NULL CONSTRAINT credit_allocation_principal_check CHECK (principal >= 0),
  interest_open_after numeric(12, 2) NOT NULL DEFAULT 0 CONSTRAINT credit_allocation_open_check CHECK (interest_open_after >= 0),
  accrued_on date,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid,
  CONSTRAINT credit_allocation_total_check CHECK (fee + interest + principal > 0)
);
CREATE UNIQUE INDEX credit_allocation_key ON credit_allocation (payment_id, installment_id) WHERE deleted_at IS NULL;
CREATE INDEX credit_allocation_installment_idx ON credit_allocation (installment_id);
CREATE INDEX credit_allocation_economic_group_id_idx ON credit_allocation (economic_group_id);

-- Dependente que pode comprar no crediário do titular.
ALTER TABLE customer_dependent ADD COLUMN credit_allowed boolean NOT NULL DEFAULT false;
CREATE OR REPLACE VIEW v_customer_dependent WITH (security_invoker = true) AS
  SELECT * FROM customer_dependent WHERE deleted_at IS NULL;

ALTER TABLE sale_payment DROP CONSTRAINT sale_payment_method_check;
ALTER TABLE sale_payment ADD CONSTRAINT sale_payment_method_check CHECK (
  method IN ('cash', 'credit_card', 'debit_card', 'pix', 'agreement', 'return_credit', 'store_credit')
);
ALTER TABLE sale_alert DROP CONSTRAINT sale_alert_kind_check;
ALTER TABLE sale_alert ADD CONSTRAINT sale_alert_kind_check CHECK (kind IN (
  'price_divergence', 'discount_above_rule', 'discount_above_limit', 'operator_permission',
  'negative_stock', 'product_status', 'agreement_link', 'offline_zero_stock',
  'controlled_missing', 'controlled_release', 'controlled_pending', 'prescription_expired', 'prescription_type',
  'seller_permission', 'quote_status', 'return_permission', 'return_credit', 'auto_discount',
  'credit_limit', 'credit_blocked', 'credit_overdue', 'credit_schedule', 'credit_dependent'
));
ALTER TABLE cash_alert DROP CONSTRAINT cash_alert_kind_check;
ALTER TABLE cash_alert ADD CONSTRAINT cash_alert_kind_check CHECK (kind IN (
  'withdrawal_above_limit', 'closing_difference', 'return_payout', 'credit_overpayment'
));

CALL app.apply_table_standard('public.credit_policy');
CALL app.apply_table_standard('public.credit_account');
CALL app.apply_table_standard('public.credit_account_event');
CALL app.apply_table_standard('public.credit_installment');
CALL app.apply_table_standard('public.credit_payment');
CALL app.apply_table_standard('public.credit_allocation');

CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON credit_policy
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns('economic_group_id', 'branch_id');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON credit_account
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns('economic_group_id', 'customer_id', 'home_branch_id');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON credit_account_event
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'account_id', 'kind', 'old_limit', 'new_limit', 'suggested_limit', 'detail', 'reason',
    'changed_by', 'deleted_at'
  );
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON credit_installment
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'account_id', 'sale_id', 'sale_payment_id', 'branch_id', 'dependent_id', 'number', 'due_date',
    'amount', 'deleted_at'
  );
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON credit_payment
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'account_id', 'branch_id', 'terminal_id', 'cash_session_id', 'received_by', 'received_at',
    'method', 'amount', 'excess', 'card_brand', 'authorization_code', 'deleted_at'
  );
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON credit_allocation
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'payment_id', 'installment_id', 'received_on', 'fee', 'interest', 'principal',
    'interest_open_after', 'accrued_on', 'deleted_at'
  );

-- Conta e parcelas no mesmo grupo do cliente, da filial e da venda.
CREATE FUNCTION app.validate_credit_account() RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.customer c WHERE c.id = NEW.customer_id AND c.economic_group_id = NEW.economic_group_id)
     OR NOT EXISTS (
       SELECT 1 FROM public.branch b JOIN public.company co ON co.id = b.company_id
        WHERE b.id = NEW.home_branch_id AND co.economic_group_id = NEW.economic_group_id
     ) THEN
    RAISE EXCEPTION 'Um dos itens informados não foi encontrado.'
      USING ERRCODE = 'FA004', DETAIL = 'Cliente ou filial do crediário fora do grupo.';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER validate_group BEFORE INSERT ON credit_account
  FOR EACH ROW EXECUTE FUNCTION app.validate_credit_account();

CREATE FUNCTION app.validate_credit_installment() RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.credit_account a WHERE a.id = NEW.account_id AND a.economic_group_id = NEW.economic_group_id)
     OR NOT EXISTS (
       SELECT 1 FROM public.sale_payment p JOIN public.sale s ON s.id = p.sale_id
        WHERE p.id = NEW.sale_payment_id AND p.method = 'store_credit' AND s.id = NEW.sale_id
          AND s.economic_group_id = NEW.economic_group_id
     ) THEN
    RAISE EXCEPTION 'Um dos itens informados não foi encontrado.'
      USING ERRCODE = 'FA004', DETAIL = 'Parcela fora da conta ou da venda.';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER validate_group BEFORE INSERT ON credit_installment
  FOR EACH ROW EXECUTE FUNCTION app.validate_credit_installment();

-- O cliente desce de novo para os terminais quando o crediário dele muda.
CREATE FUNCTION app.track_credit_change() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  customer uuid;
BEGIN
  IF TG_TABLE_NAME = 'credit_account' THEN
    customer := NEW.customer_id;
  ELSIF TG_TABLE_NAME = 'customer_dependent' THEN
    customer := NEW.customer_id;
  ELSE
    SELECT a.customer_id INTO customer FROM public.credit_account a WHERE a.id = NEW.account_id;
  END IF;
  PERFORM app.mark_sync_change('customer', customer, NEW.economic_group_id, NULL);
  RETURN NULL;
END;
$$;
CREATE TRIGGER track_sync_change AFTER INSERT OR UPDATE ON credit_account
  FOR EACH ROW EXECUTE FUNCTION app.track_credit_change();
CREATE TRIGGER track_sync_change AFTER INSERT ON credit_installment
  FOR EACH ROW EXECUTE FUNCTION app.track_credit_change();
CREATE TRIGGER track_sync_change AFTER INSERT ON credit_payment
  FOR EACH ROW EXECUTE FUNCTION app.track_credit_change();
CREATE TRIGGER track_credit_change AFTER UPDATE OF credit_allowed ON customer_dependent
  FOR EACH ROW EXECUTE FUNCTION app.track_credit_change();

-- Parâmetros da filial mudaram: descem de novo os clientes com conta nela.
CREATE FUNCTION app.track_credit_policy() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM app.mark_sync_change('customer', a.customer_id, a.economic_group_id, NULL)
     FROM public.credit_account a WHERE a.home_branch_id = NEW.branch_id AND a.deleted_at IS NULL;
  RETURN NULL;
END;
$$;
CREATE TRIGGER track_sync_change AFTER INSERT OR UPDATE ON credit_policy
  FOR EACH ROW EXECUTE FUNCTION app.track_credit_policy();

-- Parâmetros da filial, com os padrões quando ela não definiu.
CREATE FUNCTION app.credit_policy_json(p_branch_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT pg_catalog.jsonb_build_object(
    'late_fee_percent', COALESCE(p.late_fee_percent, 2),
    'monthly_interest_percent', COALESCE(p.monthly_interest_percent, 1),
    'max_installments', COALESCE(p.max_installments, 3),
    'limit_factor', COALESCE(p.limit_factor, 1),
    'block_after_days', COALESCE(p.block_after_days, 30),
    'due_mode', COALESCE(p.due_mode, 'closing'),
    'closing_day', COALESCE(p.closing_day, 25),
    'due_day', COALESCE(p.due_day, 10),
    'interval_days', COALESCE(p.interval_days, 30)
  )
    FROM (SELECT 1) one
    LEFT JOIN public.credit_policy p ON p.branch_id = p_branch_id AND p.deleted_at IS NULL
$$;

-- Vencimentos da conta: a exceção dela ou o padrão da filial.
CREATE FUNCTION app.credit_terms(p_account public.credit_account) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT CASE WHEN p_account.due_mode IS NOT NULL THEN pg_catalog.jsonb_build_object(
           'due_mode', p_account.due_mode, 'closing_day', COALESCE(p_account.closing_day, (policy ->> 'closing_day')::int),
           'due_day', COALESCE(p_account.due_day, (policy ->> 'due_day')::int),
           'interval_days', COALESCE(p_account.interval_days, (policy ->> 'interval_days')::int), 'own', true)
         ELSE pg_catalog.jsonb_build_object(
           'due_mode', policy ->> 'due_mode', 'closing_day', (policy ->> 'closing_day')::int,
           'due_day', (policy ->> 'due_day')::int, 'interval_days', (policy ->> 'interval_days')::int, 'own', false)
         END
    FROM (SELECT app.credit_policy_json(p_account.home_branch_id) AS policy) p
$$;

-- Parcelas de uma compra: vencimentos e valores. Centavo que sobra da divisão fica na primeira.
--   Fechamento: compra até o dia do fechamento entra na fatura que fecha naquele mês; depois, na do
--   mês seguinte. A fatura vence no dia do vencimento seguinte ao fechamento.
--   Dias corridos: a cada intervalo, a partir da data da compra.
CREATE FUNCTION app.credit_schedule(p_terms jsonb, p_sold_on date, p_amount numeric, p_count integer) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE
SET search_path = ''
AS $$
DECLARE
  closing integer := (p_terms ->> 'closing_day')::integer;
  due integer := (p_terms ->> 'due_day')::integer;
  step integer := (p_terms ->> 'interval_days')::integer;
  cents bigint := pg_catalog.round(p_amount * 100)::bigint;
  base bigint := cents / p_count;
  close_date date;
  first_due date;
  result jsonb := '[]'::jsonb;
BEGIN
  IF p_terms ->> 'due_mode' = 'closing' THEN
    close_date := pg_catalog.make_date(
      pg_catalog.date_part('year', p_sold_on)::integer, pg_catalog.date_part('month', p_sold_on)::integer, closing);
    IF pg_catalog.date_part('day', p_sold_on) > closing THEN
      close_date := (close_date + pg_catalog.make_interval(months => 1))::date;
    END IF;
    first_due := pg_catalog.make_date(
      pg_catalog.date_part('year', close_date)::integer, pg_catalog.date_part('month', close_date)::integer, due);
    IF due <= closing THEN
      first_due := (first_due + pg_catalog.make_interval(months => 1))::date;
    END IF;
  END IF;
  FOR n IN 1..p_count LOOP
    result := result || pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
      'number', n,
      'due_date', CASE WHEN p_terms ->> 'due_mode' = 'closing'
                       THEN (first_due + pg_catalog.make_interval(months => n - 1))::date
                       ELSE p_sold_on + step * n END,
      'amount', pg_catalog.round((base + CASE WHEN n = 1 THEN cents - base * p_count ELSE 0 END)::numeric / 100, 2)
    ));
  END LOOP;
  RETURN result;
END;
$$;

-- Encargos de uma parcela numa data. Multa: uma vez, sobre o que estava em aberto no vencimento.
-- Juros: simples, por dia (taxa mensal / 30), sobre o valor em aberto, desde o vencimento ou desde
-- a última vez que foram contados. Centavos arredondados metade para cima.
CREATE FUNCTION app.credit_position(p_state jsonb, p_at date, p_policy jsonb) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE
SET search_path = ''
AS $$
DECLARE
  due date := (p_state ->> 'due_date')::date;
  principal numeric := (p_state ->> 'principal_open')::numeric;
  fee numeric := 0;
  interest numeric := COALESCE((p_state ->> 'interest_open')::numeric, 0);
  since date := GREATEST(due, COALESCE((p_state ->> 'accrued_until')::date, due));
BEGIN
  IF p_at > due THEN
    fee := GREATEST(
      pg_catalog.round((p_state ->> 'fee_base')::numeric * (p_policy ->> 'late_fee_percent')::numeric / 100, 2)
        - COALESCE((p_state ->> 'fee_paid')::numeric, 0),
      0);
    interest := interest + pg_catalog.round(
      principal * (p_policy ->> 'monthly_interest_percent')::numeric * GREATEST(p_at - since, 0) / 3000, 2);
  END IF;
  RETURN pg_catalog.jsonb_build_object('fee', fee, 'interest', interest, 'principal', principal);
END;
$$;

-- Como um recebimento se divide: primeiro multa e juros de cada parcela (da que vence antes para a
-- que vence depois), depois o valor das parcelas, na mesma ordem. O que sobra volta em excess.
CREATE FUNCTION app.credit_allocate(p_states jsonb, p_amount numeric, p_at date, p_policy jsonb) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE
SET search_path = ''
AS $$
DECLARE
  remaining numeric := p_amount;
  state jsonb;
  position jsonb;
  entries jsonb := '[]'::jsonb;
  entry jsonb;
  fee_pay numeric;
  interest_pay numeric;
  principal_pay numeric;
  result jsonb := '[]'::jsonb;
BEGIN
  FOR state IN
    SELECT s.value FROM pg_catalog.jsonb_array_elements(p_states) s
     ORDER BY (s.value ->> 'due_date')::date, (s.value ->> 'number')::integer NULLS LAST, s.value ->> 'id'
  LOOP
    position := app.credit_position(state, p_at, p_policy);
    fee_pay := LEAST(remaining, (position ->> 'fee')::numeric);
    remaining := remaining - fee_pay;
    interest_pay := LEAST(remaining, (position ->> 'interest')::numeric);
    remaining := remaining - interest_pay;
    entries := entries || pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
      'id', state -> 'id', 'fee', fee_pay, 'interest', interest_pay,
      'interest_open_after', (position ->> 'interest')::numeric - interest_pay,
      'principal_open', (position ->> 'principal')::numeric
    ));
  END LOOP;
  FOR entry IN SELECT value FROM pg_catalog.jsonb_array_elements(entries) LOOP
    principal_pay := LEAST(remaining, (entry ->> 'principal_open')::numeric);
    remaining := remaining - principal_pay;
    IF (entry ->> 'fee')::numeric + (entry ->> 'interest')::numeric + principal_pay > 0 THEN
      result := result || pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
        'id', entry -> 'id', 'fee', (entry ->> 'fee')::numeric, 'interest', (entry ->> 'interest')::numeric,
        'principal', principal_pay, 'interest_open_after', (entry ->> 'interest_open_after')::numeric
      ));
    END IF;
  END LOOP;
  RETURN pg_catalog.jsonb_build_object('allocations', result, 'excess', remaining);
END;
$$;

-- Situação de cada parcela em aberto da conta, no formato das funções acima (é também o que desce
-- para o PDV calcular sem internet).
CREATE FUNCTION app.credit_states(p_account_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
           'id', i.id, 'sale_id', i.sale_id, 'number', i.number, 'due_date', i.due_date, 'amount', i.amount,
           'principal_open', i.amount - COALESCE(paid.principal, 0),
           'fee_base', i.amount - COALESCE(paid.principal_by_due, 0),
           'fee_paid', COALESCE(paid.fee, 0),
           'interest_open', COALESCE(last_accrual.interest_open_after, 0),
           'accrued_until', COALESCE(last_accrual.accrued_on, i.due_date)
         ) ORDER BY i.due_date, i.number, i.id), '[]'::jsonb)
    FROM public.credit_installment i
    LEFT JOIN LATERAL (
      SELECT pg_catalog.sum(al.principal) AS principal,
             pg_catalog.sum(al.principal) FILTER (WHERE al.received_on <= i.due_date) AS principal_by_due,
             pg_catalog.sum(al.fee) AS fee
        FROM public.credit_allocation al WHERE al.installment_id = i.id AND al.deleted_at IS NULL
    ) paid ON true
    LEFT JOIN LATERAL (
      SELECT al.accrued_on, al.interest_open_after
        FROM public.credit_allocation al
       WHERE al.installment_id = i.id AND al.accrued_on IS NOT NULL AND al.deleted_at IS NULL
       ORDER BY al.accrued_on DESC, al.created_at DESC, al.id DESC
       LIMIT 1
    ) last_accrual ON true
   WHERE i.account_id = p_account_id AND i.deleted_at IS NULL
     AND i.amount - COALESCE(paid.principal, 0) > 0
$$;

-- Resumo da conta numa data: valor em aberto, encargos, disponível e atraso.
CREATE FUNCTION app.credit_summary(p_account public.credit_account, p_at date) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  WITH policy AS (SELECT app.credit_policy_json(p_account.home_branch_id) AS value),
  positions AS (
    SELECT (s.value ->> 'due_date')::date AS due_date, app.credit_position(s.value, p_at, policy.value) AS position
      FROM pg_catalog.jsonb_array_elements(app.credit_states(p_account.id)) s, policy
  ),
  totals AS (
    SELECT COALESCE(pg_catalog.sum((p.position ->> 'principal')::numeric), 0) AS principal,
           COALESCE(pg_catalog.sum((p.position ->> 'fee')::numeric + (p.position ->> 'interest')::numeric), 0) AS charges,
           COALESCE(pg_catalog.sum((p.position ->> 'principal')::numeric) FILTER (WHERE p.due_date < p_at), 0) AS overdue,
           pg_catalog.min(p.due_date) FILTER (WHERE p.due_date < p_at) AS oldest_due
      FROM positions p
  )
  SELECT pg_catalog.jsonb_build_object(
    'principal_open', t.principal, 'charges_open', t.charges, 'total_open', t.principal + t.charges,
    'available', GREATEST(p_account.credit_limit - t.principal, 0), 'overdue_principal', t.overdue,
    'oldest_due', t.oldest_due, 'overdue_days', COALESCE(p_at - t.oldest_due, 0),
    'blocked_by_overdue', COALESCE(p_at - t.oldest_due, 0) > (policy.value ->> 'block_after_days')::integer
  )
    FROM totals t, policy
$$;

CREATE FUNCTION app.credit_has_debt(p_customer_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.credit_installment i
      JOIN public.credit_account a ON a.id = i.account_id AND a.deleted_at IS NULL
     WHERE a.customer_id = p_customer_id AND i.deleted_at IS NULL
       AND i.amount > COALESCE((
         SELECT pg_catalog.sum(al.principal) FROM public.credit_allocation al
          WHERE al.installment_id = i.id AND al.deleted_at IS NULL), 0)
  )
$$;

-- Limite sugerido: média mensal das compras dos últimos 6 meses vezes o fator da filial.
CREATE FUNCTION app.credit_suggested_limit(p_customer_id uuid, p_branch_id uuid) RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT pg_catalog.round(
    COALESCE((
      SELECT pg_catalog.sum(s.total) FROM public.sale s
       WHERE s.customer_id = p_customer_id AND s.deleted_at IS NULL
         AND s.sold_at >= pg_catalog.now() - pg_catalog.make_interval(months => 6)
    ), 0) / 6 * (app.credit_policy_json(p_branch_id) ->> 'limit_factor')::numeric, 2)
$$;

CREATE FUNCTION app.credit_today() RETURNS date
LANGUAGE sql STABLE
SET search_path = ''
AS $$ SELECT (pg_catalog.now() AT TIME ZONE 'America/Sao_Paulo')::date $$;

-- Conta do cliente para quem pode mexer nela (FA834 se não houver ou se a pessoa não a vê).
CREATE FUNCTION app.credit_account_for(p_account_id uuid, p_permission text) RETURNS public.credit_account
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  found_account public.credit_account;
BEGIN
  SELECT a.* INTO found_account FROM public.credit_account a
   WHERE a.id = p_account_id AND a.deleted_at IS NULL AND a.economic_group_id = app.current_user_group()
     AND app.has_permission('credit.view', a.home_branch_id)
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Este cliente não tem crediário.'
      USING ERRCODE = 'FA834', DETAIL = pg_catalog.format('credit_account %s.', p_account_id);
  END IF;
  PERFORM app.require_branch_permission(p_permission, found_account.home_branch_id);
  RETURN found_account;
END;
$$;

-- Abre o crediário do cliente, com o limite e o registro de quem abriu.
CREATE FUNCTION app.open_credit_account(p_customer_id uuid, p_home_branch_id uuid, p_limit numeric, p_reason text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.current_user_group();
  account_id uuid;
BEGIN
  PERFORM app.require_branch_permission('credit.manage', p_home_branch_id);
  IF NOT EXISTS (
    SELECT 1 FROM public.customer c WHERE c.id = p_customer_id AND c.economic_group_id = group_id AND c.deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('customer %s.', p_customer_id);
  END IF;
  IF EXISTS (SELECT 1 FROM public.credit_account a WHERE a.customer_id = p_customer_id AND a.deleted_at IS NULL) THEN
    RAISE EXCEPTION 'Este cliente já tem crediário.'
      USING ERRCODE = 'FA835', DETAIL = pg_catalog.format('customer %s.', p_customer_id);
  END IF;
  INSERT INTO public.credit_account (economic_group_id, customer_id, home_branch_id, credit_limit)
  VALUES (group_id, p_customer_id, p_home_branch_id, p_limit)
  RETURNING id INTO account_id;
  INSERT INTO public.credit_account_event (economic_group_id, account_id, kind, new_limit, suggested_limit, reason, changed_by)
  VALUES (group_id, account_id, 'opened', p_limit, app.credit_suggested_limit(p_customer_id, p_home_branch_id),
          NULLIF(pg_catalog.btrim(COALESCE(p_reason, '')), ''), app.current_user_id());
  RETURN account_id;
END;
$$;

-- Novo limite, com o motivo, o anterior e o sugerido no momento.
CREATE FUNCTION app.set_credit_limit(p_account_id uuid, p_limit numeric, p_reason text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.credit_account := app.credit_account_for(p_account_id, 'credit.manage');
  note text := pg_catalog.btrim(COALESCE(p_reason, ''));
BEGIN
  IF note = '' THEN
    RAISE EXCEPTION 'Informe o motivo desta ação.' USING ERRCODE = 'FA302';
  END IF;
  UPDATE public.credit_account SET credit_limit = p_limit WHERE id = target.id;
  INSERT INTO public.credit_account_event (
    economic_group_id, account_id, kind, old_limit, new_limit, suggested_limit, reason, changed_by
  ) VALUES (
    target.economic_group_id, target.id, 'limit', target.credit_limit, p_limit,
    app.credit_suggested_limit(target.customer_id, target.home_branch_id), note, app.current_user_id()
  );
END;
$$;

-- Bloqueia ou libera a conta para novas compras no crediário. Recebimentos continuam.
CREATE FUNCTION app.set_credit_status(p_account_id uuid, p_status text, p_reason text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.credit_account := app.credit_account_for(p_account_id, 'credit.manage');
  note text := pg_catalog.btrim(COALESCE(p_reason, ''));
BEGIN
  IF note = '' THEN
    RAISE EXCEPTION 'Informe o motivo desta ação.' USING ERRCODE = 'FA302';
  END IF;
  IF p_status IS NULL OR p_status NOT IN ('active', 'blocked') OR p_status = target.status THEN
    RAISE EXCEPTION 'Este crediário já está nesta situação.'
      USING ERRCODE = 'FA836', DETAIL = pg_catalog.format('credit_account %s: %s para %s.', target.id, target.status, p_status);
  END IF;
  UPDATE public.credit_account SET status = p_status WHERE id = target.id;
  INSERT INTO public.credit_account_event (economic_group_id, account_id, kind, reason, changed_by)
  VALUES (target.economic_group_id, target.id, CASE p_status WHEN 'blocked' THEN 'blocked' ELSE 'unblocked' END, note,
          app.current_user_id());
END;
$$;

-- Vencimentos próprios da conta ({"due_mode": null} volta ao padrão da filial). Valem para compras novas.
CREATE FUNCTION app.set_credit_terms(p_account_id uuid, p_terms jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.credit_account := app.credit_account_for(p_account_id, 'credit.manage');
  mode text := p_terms ->> 'due_mode';
BEGIN
  UPDATE public.credit_account
     SET due_mode = mode,
         closing_day = CASE WHEN mode = 'closing' THEN (p_terms ->> 'closing_day')::smallint END,
         due_day = CASE WHEN mode = 'closing' THEN (p_terms ->> 'due_day')::smallint END,
         interval_days = CASE WHEN mode = 'days' THEN (p_terms ->> 'interval_days')::smallint END
   WHERE id = target.id;
  INSERT INTO public.credit_account_event (economic_group_id, account_id, kind, detail, changed_by)
  SELECT target.economic_group_id, target.id, 'terms', app.credit_terms(a), app.current_user_id()
    FROM public.credit_account a WHERE a.id = target.id;
END;
$$;

-- Marca se o dependente pode comprar no crediário do titular.
CREATE FUNCTION app.set_dependent_credit(p_dependent_id uuid, p_allowed boolean) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  dependent public.customer_dependent;
  account_id uuid;
BEGIN
  SELECT d.* INTO dependent FROM public.customer_dependent d
   WHERE d.id = p_dependent_id AND d.deleted_at IS NULL AND d.economic_group_id = app.current_user_group();
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('customer_dependent %s.', p_dependent_id);
  END IF;
  SELECT a.id INTO account_id FROM public.credit_account a WHERE a.customer_id = dependent.customer_id AND a.deleted_at IS NULL;
  PERFORM app.credit_account_for(account_id, 'credit.manage');
  UPDATE public.customer_dependent SET credit_allowed = COALESCE(p_allowed, false) WHERE id = dependent.id;
END;
$$;

-- Parâmetros do crediário das filiais que a pessoa vê.
CREATE FUNCTION app.list_credit_policies()
RETURNS TABLE (branch_id uuid, branch_name text, policy jsonb, customized boolean, can_edit boolean)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT b.id, b.name, app.credit_policy_json(b.id),
         EXISTS (SELECT 1 FROM public.credit_policy p WHERE p.branch_id = b.id AND p.deleted_at IS NULL),
         app.has_permission('credit.policy', b.id)
    FROM public.branch b
    JOIN public.company co ON co.id = b.company_id
   WHERE b.deleted_at IS NULL AND co.economic_group_id = app.current_user_group()
     AND app.has_permission('credit.view', b.id)
   ORDER BY b.name
$$;

-- Grava os parâmetros da filial. Campo ausente mantém o valor atual.
CREATE FUNCTION app.set_credit_policy(p_branch_id uuid, p_data jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  current_policy jsonb;
  merged jsonb;
BEGIN
  PERFORM app.require_branch_permission('credit.policy', p_branch_id);
  current_policy := app.credit_policy_json(p_branch_id);
  merged := current_policy || pg_catalog.jsonb_strip_nulls(COALESCE(p_data, '{}'::jsonb));
  UPDATE public.credit_policy SET
    late_fee_percent = (merged ->> 'late_fee_percent')::numeric,
    monthly_interest_percent = (merged ->> 'monthly_interest_percent')::numeric,
    max_installments = (merged ->> 'max_installments')::smallint,
    limit_factor = (merged ->> 'limit_factor')::numeric,
    block_after_days = (merged ->> 'block_after_days')::smallint,
    due_mode = merged ->> 'due_mode',
    closing_day = (merged ->> 'closing_day')::smallint,
    due_day = (merged ->> 'due_day')::smallint,
    interval_days = (merged ->> 'interval_days')::smallint
   WHERE branch_id = p_branch_id AND deleted_at IS NULL;
  IF NOT FOUND THEN
    INSERT INTO public.credit_policy (
      economic_group_id, branch_id, late_fee_percent, monthly_interest_percent, max_installments, limit_factor,
      block_after_days, due_mode, closing_day, due_day, interval_days
    ) VALUES (
      app.current_user_group(), p_branch_id, (merged ->> 'late_fee_percent')::numeric,
      (merged ->> 'monthly_interest_percent')::numeric, (merged ->> 'max_installments')::smallint,
      (merged ->> 'limit_factor')::numeric, (merged ->> 'block_after_days')::smallint, merged ->> 'due_mode',
      (merged ->> 'closing_day')::smallint, (merged ->> 'due_day')::smallint, (merged ->> 'interval_days')::smallint
    );
  END IF;
END;
$$;

-- Contas de crediário que a pessoa vê, com o resumo de hoje. Situação: all, debt, overdue, blocked.
CREATE FUNCTION app.list_credit_accounts(p_situation text DEFAULT 'all', p_search text DEFAULT NULL)
RETURNS TABLE (
  account_id uuid, customer_id uuid, customer_code bigint, customer_name text, home_branch_name text,
  credit_limit numeric, status text, principal_open numeric, charges_open numeric, total_open numeric,
  available numeric, overdue_principal numeric, oldest_due date, overdue_days integer, blocked_by_overdue boolean
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT a.id, c.id, c.code, c.name, b.name, a.credit_limit, a.status,
         (s.value ->> 'principal_open')::numeric, (s.value ->> 'charges_open')::numeric, (s.value ->> 'total_open')::numeric,
         (s.value ->> 'available')::numeric, (s.value ->> 'overdue_principal')::numeric, (s.value ->> 'oldest_due')::date,
         (s.value ->> 'overdue_days')::integer, (s.value ->> 'blocked_by_overdue')::boolean
    FROM public.credit_account a
    JOIN public.customer c ON c.id = a.customer_id
    JOIN public.branch b ON b.id = a.home_branch_id
    CROSS JOIN LATERAL (SELECT app.credit_summary(a, app.credit_today()) AS value) s
   WHERE a.deleted_at IS NULL AND a.economic_group_id = app.current_user_group()
     AND app.has_permission('credit.view', a.home_branch_id)
     AND (p_search IS NULL OR pg_catalog.btrim(p_search) = ''
          OR c.search_text LIKE '%' || app.normalize_search(p_search) || '%'
          OR c.code::text = pg_catalog.btrim(p_search))
     AND CASE COALESCE(p_situation, 'all')
           WHEN 'debt' THEN (s.value ->> 'principal_open')::numeric > 0
           WHEN 'overdue' THEN (s.value ->> 'overdue_principal')::numeric > 0
           WHEN 'blocked' THEN a.status = 'blocked' OR (s.value ->> 'blocked_by_overdue')::boolean
           ELSE true
         END
   ORDER BY (s.value ->> 'overdue_days')::integer DESC, c.name, a.id
   LIMIT 500
$$;

-- Crediário do cliente para a retaguarda: conta, resumo, parcelas, recebimentos, histórico e
-- dependentes. Sem conta (ou sem permissão), devolve só o que é preciso para abrir uma.
CREATE FUNCTION app.credit_account_detail(p_customer_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT CASE WHEN a.id IS NULL THEN pg_catalog.jsonb_build_object(
           'account', NULL,
           'can_open', EXISTS (
             SELECT 1 FROM public.branch b JOIN public.company co ON co.id = b.company_id
              WHERE co.economic_group_id = c.economic_group_id AND b.deleted_at IS NULL
                AND app.has_permission('credit.manage', b.id)),
           'suggested_limits', (
             SELECT COALESCE(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
                      'branch_id', b.id, 'branch_name', b.name,
                      'suggested_limit', app.credit_suggested_limit(c.id, b.id)) ORDER BY b.name), '[]'::jsonb)
               FROM public.branch b JOIN public.company co ON co.id = b.company_id
              WHERE co.economic_group_id = c.economic_group_id AND b.deleted_at IS NULL
                AND app.has_permission('credit.manage', b.id))
         ) ELSE pg_catalog.jsonb_build_object(
           'account', pg_catalog.jsonb_build_object(
             'id', a.id, 'home_branch_id', a.home_branch_id, 'home_branch_name', hb.name, 'credit_limit', a.credit_limit,
             'status', a.status, 'terms', app.credit_terms(a), 'created_at', a.created_at),
           'can_manage', app.has_permission('credit.manage', a.home_branch_id),
           'policy', app.credit_policy_json(a.home_branch_id),
           'summary', app.credit_summary(a, app.credit_today()),
           'suggested_limit', app.credit_suggested_limit(c.id, a.home_branch_id),
           'installments', COALESCE((
             SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
                      'id', i.id, 'sale_id', i.sale_id, 'sale_code', s.code, 'sold_at', s.sold_at, 'branch_name', ib.name,
                      'dependent_name', d.name, 'number', i.number,
                      'count', (SELECT pg_catalog.count(*) FROM public.credit_installment x
                                 WHERE x.sale_payment_id = i.sale_payment_id AND x.deleted_at IS NULL),
                      'due_date', i.due_date, 'amount', i.amount,
                      'paid_principal', COALESCE((SELECT pg_catalog.sum(al.principal) FROM public.credit_allocation al
                                                   WHERE al.installment_id = i.id AND al.deleted_at IS NULL), 0),
                      'paid_charges', COALESCE((SELECT pg_catalog.sum(al.fee + al.interest) FROM public.credit_allocation al
                                                 WHERE al.installment_id = i.id AND al.deleted_at IS NULL), 0),
                      'position', (
                        SELECT app.credit_position(st.value, app.credit_today(), app.credit_policy_json(a.home_branch_id))
                          FROM pg_catalog.jsonb_array_elements(app.credit_states(a.id)) st
                         WHERE (st.value ->> 'id')::uuid = i.id)
                    ) ORDER BY i.due_date, s.sold_at, i.number)
               FROM public.credit_installment i
               JOIN public.sale s ON s.id = i.sale_id
               JOIN public.branch ib ON ib.id = i.branch_id
               LEFT JOIN public.customer_dependent d ON d.id = i.dependent_id
              WHERE i.account_id = a.id AND i.deleted_at IS NULL
           ), '[]'::jsonb),
           'payments', COALESCE((
             SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
                      'id', p.id, 'received_at', p.received_at, 'branch_name', pb.name, 'received_by_name', ru.name,
                      'method', p.method, 'amount', p.amount, 'excess', p.excess,
                      'fee', COALESCE((SELECT pg_catalog.sum(al.fee) FROM public.credit_allocation al WHERE al.payment_id = p.id), 0),
                      'interest', COALESCE((SELECT pg_catalog.sum(al.interest) FROM public.credit_allocation al WHERE al.payment_id = p.id), 0),
                      'principal', COALESCE((SELECT pg_catalog.sum(al.principal) FROM public.credit_allocation al WHERE al.payment_id = p.id), 0)
                    ) ORDER BY p.received_at DESC, p.id DESC)
               FROM public.credit_payment p
               JOIN public.branch pb ON pb.id = p.branch_id
               JOIN public.user_account ru ON ru.id = p.received_by
              WHERE p.account_id = a.id AND p.deleted_at IS NULL
           ), '[]'::jsonb),
           'events', COALESCE((
             SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
                      'kind', e.kind, 'old_limit', e.old_limit, 'new_limit', e.new_limit, 'suggested_limit', e.suggested_limit,
                      'detail', e.detail, 'reason', e.reason, 'changed_by_name', eu.name, 'created_at', e.created_at
                    ) ORDER BY e.created_at DESC, e.id DESC)
               FROM public.credit_account_event e JOIN public.user_account eu ON eu.id = e.changed_by
              WHERE e.account_id = a.id AND e.deleted_at IS NULL
           ), '[]'::jsonb),
           'dependents', COALESCE((
             SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
                      'id', d.id, 'name', d.name, 'relationship', d.relationship, 'credit_allowed', d.credit_allowed
                    ) ORDER BY d.name, d.id)
               FROM public.customer_dependent d WHERE d.customer_id = c.id AND d.deleted_at IS NULL
           ), '[]'::jsonb)
         ) END
    FROM public.customer c
    LEFT JOIN public.credit_account a
      ON a.customer_id = c.id AND a.deleted_at IS NULL AND app.has_permission('credit.view', a.home_branch_id)
    LEFT JOIN public.branch hb ON hb.id = a.home_branch_id
   WHERE c.id = p_customer_id AND c.deleted_at IS NULL AND c.economic_group_id = app.current_user_group()
$$;

-- Recebimento de parcelas vindo do PDV. Abate na ordem do crediário (app.credit_allocate) com os
-- parâmetros da filial da conta, na data do recebimento. Se o PDV recebeu mais que o devido (outro
-- caixa recebeu antes), o dinheiro já entrou: fica o excesso no recebimento e o alerta do caixa.
CREATE FUNCTION app.sync_apply_credit_payment(p_terminal public.terminal, p_group_id uuid, p_payload jsonb)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  uuid_any constant text := '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
  payment_id uuid;
  session_row public.cash_session;
  account public.credit_account;
  receiver uuid;
  amount numeric;
  received timestamptz;
  received_on date;
  allocation jsonb;
  entry jsonb;
  due date;
BEGIN
  IF (p_payload ->> 'id') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
     OR (p_payload ->> 'cash_session_id') !~ uuid_any
     OR (p_payload ->> 'customer_id') !~ uuid_any
     OR (p_payload ->> 'received_by') !~ uuid_any
     OR (p_payload ->> 'received_at') !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$'
     OR (p_payload ->> 'method') IS NULL OR (p_payload ->> 'method') NOT IN ('cash', 'credit_card', 'debit_card', 'pix')
     OR pg_catalog.jsonb_typeof(p_payload -> 'amount') IS DISTINCT FROM 'number'
     OR (p_payload ->> 'amount')::numeric NOT BETWEEN 0.01 AND 9999999999.99
     OR (p_payload ->> 'amount')::numeric <> round((p_payload ->> 'amount')::numeric, 2)
     OR pg_catalog.length(p_payload ->> 'card_brand') > 30 OR pg_catalog.length(p_payload ->> 'authorization_code') > 30 THEN
    RAISE EXCEPTION 'A venda enviada pelo terminal está inconsistente.'
      USING ERRCODE = 'FA962', DETAIL = 'Recebimento do crediário fora do formato.';
  END IF;
  payment_id := (p_payload ->> 'id')::uuid;
  IF EXISTS (SELECT 1 FROM public.credit_payment p WHERE p.id = payment_id) THEN
    RAISE EXCEPTION 'Esta venda ou turno já foi recebido com outro registro.'
      USING ERRCODE = 'FA963', DETAIL = pg_catalog.format('credit_payment %s.', payment_id);
  END IF;
  session_row := app.terminal_open_session(p_terminal, (p_payload ->> 'cash_session_id')::uuid);
  receiver := (p_payload ->> 'received_by')::uuid;
  IF NOT EXISTS (SELECT 1 FROM public.user_account u WHERE u.id = receiver AND u.economic_group_id = p_group_id) THEN
    RAISE EXCEPTION 'Um dos itens informados não foi encontrado.'
      USING ERRCODE = 'FA004', DETAIL = 'Quem recebeu fora do grupo.';
  END IF;
  SELECT a.* INTO account FROM public.credit_account a
   WHERE a.customer_id = (p_payload ->> 'customer_id')::uuid AND a.economic_group_id = p_group_id AND a.deleted_at IS NULL
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Este cliente não tem crediário.'
      USING ERRCODE = 'FA834', DETAIL = 'Recebimento de cliente sem conta.';
  END IF;
  BEGIN
    received := (p_payload ->> 'received_at')::timestamptz;
  EXCEPTION WHEN datetime_field_overflow OR invalid_datetime_format THEN
    RAISE EXCEPTION 'A venda enviada pelo terminal está inconsistente.'
      USING ERRCODE = 'FA962', DETAIL = 'Data do recebimento impossível.';
  END;
  received_on := (received AT TIME ZONE 'America/Sao_Paulo')::date;
  amount := (p_payload ->> 'amount')::numeric;
  allocation := app.credit_allocate(app.credit_states(account.id), amount, received_on, app.credit_policy_json(account.home_branch_id));

  INSERT INTO public.credit_payment (
    id, economic_group_id, account_id, branch_id, terminal_id, cash_session_id, received_by, received_at, method, amount,
    excess, card_brand, authorization_code
  ) VALUES (
    payment_id, p_group_id, account.id, session_row.branch_id, p_terminal.id, session_row.id, receiver, received,
    p_payload ->> 'method', amount, (allocation ->> 'excess')::numeric,
    NULLIF(pg_catalog.btrim(p_payload ->> 'card_brand'), ''), NULLIF(pg_catalog.btrim(p_payload ->> 'authorization_code'), '')
  );
  FOR entry IN SELECT value FROM pg_catalog.jsonb_array_elements(allocation -> 'allocations') LOOP
    SELECT i.due_date INTO due FROM public.credit_installment i WHERE i.id = (entry ->> 'id')::uuid;
    INSERT INTO public.credit_allocation (
      economic_group_id, payment_id, installment_id, received_on, fee, interest, principal, interest_open_after, accrued_on
    ) VALUES (
      p_group_id, payment_id, (entry ->> 'id')::uuid, received_on, (entry ->> 'fee')::numeric, (entry ->> 'interest')::numeric,
      (entry ->> 'principal')::numeric, (entry ->> 'interest_open_after')::numeric,
      CASE WHEN received_on > due THEN received_on END
    );
  END LOOP;
  IF (allocation ->> 'excess')::numeric > 0 THEN
    INSERT INTO public.cash_alert (economic_group_id, branch_id, cash_session_id, kind, detail)
    VALUES (p_group_id, session_row.branch_id, session_row.id, 'credit_overpayment', pg_catalog.jsonb_build_object(
      'credit_payment_id', payment_id, 'amount', amount, 'excess', (allocation ->> 'excess')::numeric));
  END IF;
END;
$$;

-- Venda no crediário: grava as parcelas que o PDV mostrou ao cliente e confere com a central. Conta
-- bloqueada, em atraso, sem limite, dependente sem autorização ou vencimentos diferentes do cálculo
-- da central: a venda vale (já aconteceu) e fica o alerta.
CREATE FUNCTION app.credit_record_sale(
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

-- Parcelas enviadas pelo PDV no formato certo: 1 a 24, números em sequência, datas válidas a partir
-- da venda e em ordem, valores positivos que somam o pagamento.
CREATE FUNCTION app.credit_installments_valid(p_payment jsonb, p_sold_at timestamptz) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE
SET search_path = ''
AS $$
DECLARE
  item jsonb;
  position integer := 0;
  previous date;
  due date;
  total numeric := 0;
BEGIN
  IF pg_catalog.jsonb_typeof(p_payment -> 'installments') IS DISTINCT FROM 'array'
     OR pg_catalog.jsonb_array_length(p_payment -> 'installments') NOT BETWEEN 1 AND 24 THEN
    RETURN false;
  END IF;
  previous := (p_sold_at AT TIME ZONE 'America/Sao_Paulo')::date;
  FOR item IN SELECT value FROM pg_catalog.jsonb_array_elements(p_payment -> 'installments') LOOP
    position := position + 1;
    IF pg_catalog.jsonb_typeof(item) IS DISTINCT FROM 'object'
       OR (item ->> 'number') IS DISTINCT FROM position::text
       OR (item ->> 'due_date') !~ '^\d{4}-\d{2}-\d{2}$'
       OR (item ->> 'amount') !~ '^\d{1,10}(\.\d{1,2})?$' OR (item ->> 'amount')::numeric <= 0 THEN
      RETURN false;
    END IF;
    BEGIN
      due := (item ->> 'due_date')::date;
    EXCEPTION WHEN datetime_field_overflow OR invalid_datetime_format THEN
      RETURN false;
    END;
    IF due <= previous THEN
      RETURN false;
    END IF;
    previous := due;
    total := total + (item ->> 'amount')::numeric;
  END LOOP;
  RETURN total = (p_payment ->> 'amount')::numeric;
END;
$$;

-- Tabelas do crediário só pelas funções.
CREATE POLICY credit_policy_select ON credit_policy FOR SELECT TO farmaerp_app USING (false);
CREATE POLICY credit_account_select ON credit_account FOR SELECT TO farmaerp_app USING (false);
CREATE POLICY credit_account_event_select ON credit_account_event FOR SELECT TO farmaerp_app USING (false);
CREATE POLICY credit_installment_select ON credit_installment FOR SELECT TO farmaerp_app USING (false);
CREATE POLICY credit_payment_select ON credit_payment FOR SELECT TO farmaerp_app USING (false);
CREATE POLICY credit_allocation_select ON credit_allocation FOR SELECT TO farmaerp_app USING (false);
CREATE VIEW v_credit_policy WITH (security_invoker = true) AS SELECT * FROM credit_policy WHERE deleted_at IS NULL;
CREATE VIEW v_credit_account WITH (security_invoker = true) AS SELECT * FROM credit_account WHERE deleted_at IS NULL;
CREATE VIEW v_credit_account_event WITH (security_invoker = true) AS SELECT * FROM credit_account_event WHERE deleted_at IS NULL;
CREATE VIEW v_credit_installment WITH (security_invoker = true) AS SELECT * FROM credit_installment WHERE deleted_at IS NULL;
CREATE VIEW v_credit_payment WITH (security_invoker = true) AS SELECT * FROM credit_payment WHERE deleted_at IS NULL;
CREATE VIEW v_credit_allocation WITH (security_invoker = true) AS SELECT * FROM credit_allocation WHERE deleted_at IS NULL;

CREATE OR REPLACE FUNCTION app.pdv_sync_format() RETURNS integer
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$ SELECT 5 $$;

-- Subida: recebimento do crediário.
CREATE OR REPLACE FUNCTION app.pdv_apply_item(
  p_terminal public.terminal, p_group_id uuid, p_kind text, p_item_id uuid, p_payload jsonb
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  CASE p_kind
    WHEN 'log' THEN
      PERFORM app.sync_apply_log(p_terminal, p_group_id, p_item_id, p_payload);
    WHEN 'cash_session_open' THEN
      PERFORM app.sync_apply_cash_open(p_terminal, p_group_id, p_payload);
    WHEN 'sale' THEN
      PERFORM app.sync_apply_sale(p_terminal, p_group_id, p_payload);
    WHEN 'sale_return' THEN
      PERFORM app.sync_apply_return(p_terminal, p_group_id, p_payload);
    WHEN 'quote' THEN
      PERFORM app.sync_apply_quote(p_terminal, p_group_id, p_payload);
    WHEN 'cash_movement' THEN
      PERFORM app.sync_apply_cash_movement(p_terminal, p_group_id, p_payload);
    WHEN 'cash_session_close' THEN
      PERFORM app.sync_apply_cash_close(p_terminal, p_group_id, p_payload);
    WHEN 'auth_event' THEN
      PERFORM app.sync_apply_auth_event(p_terminal, p_group_id, p_payload);
    WHEN 'face_enrollment' THEN
      PERFORM app.sync_apply_face_enrollment(p_terminal, p_group_id, p_payload);
    WHEN 'credit_payment' THEN
      PERFORM app.sync_apply_credit_payment(p_terminal, p_group_id, p_payload);
    ELSE
      RAISE EXCEPTION 'O terminal enviou um tipo de registro desconhecido.'
        USING ERRCODE = 'FA959', DETAIL = pg_catalog.format('Tipo %s.', p_kind);
  END CASE;
END;
$$;

-- Caixa: recebimentos do crediário no esperado.
CREATE OR REPLACE FUNCTION app.cash_expected(p_session_id uuid)
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
           + COALESCE((SELECT pg_catalog.sum(cp.amount) FROM public.credit_payment cp
                        WHERE cp.cash_session_id = cs.id AND cp.deleted_at IS NULL AND cp.method = 'cash'), 0)
           - COALESCE((SELECT pg_catalog.sum(mv.amount) FROM public.cash_movement mv
                        WHERE mv.cash_session_id = cs.id AND mv.deleted_at IS NULL AND mv.kind = 'withdrawal'), 0)
         ELSE
           COALESCE((SELECT pg_catalog.sum(p.amount) FROM public.sale_payment p
                       JOIN public.sale s ON s.id = p.sale_id
                      WHERE s.cash_session_id = cs.id AND s.deleted_at IS NULL AND p.deleted_at IS NULL AND p.method = m.method), 0)
           + COALESCE((SELECT pg_catalog.sum(cp.amount) FROM public.credit_payment cp
                        WHERE cp.cash_session_id = cs.id AND cp.deleted_at IS NULL AND cp.method = m.method), 0)
         END
    FROM public.cash_session cs
   CROSS JOIN (VALUES ('cash', 1), ('credit_card', 2), ('debit_card', 3), ('pix', 4)) AS m (method, position)
   WHERE cs.id = p_session_id
   ORDER BY m.position
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
     'purchases.post', 'releases.view', 'sync.view', 'sync.resolve', 'sales.sell', 'sales.view', 'sales.zero_stock_release', 'controlled.view', 'sales.quote', 'sales.return',
     'users.release_login', 'users.biometrics', 'credit.view', 'credit.manage'
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

CREATE OR REPLACE FUNCTION app.pdv_targets(p_branch_id uuid, p_group_id uuid, p_terminal_id uuid, p_since xid8, p_until xid8)
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
    -- Crediário: quem deve desce para toda a rede. Mudança no crediário desce (ou retira, quando o
    -- débito acaba e o terminal não guardou o cliente).
    UNION
    SELECT a.customer_id FROM public.credit_account a
     WHERE p_since IS NULL AND a.economic_group_id = p_group_id AND a.deleted_at IS NULL
       AND app.credit_has_debt(a.customer_id)
    UNION
    SELECT c.entity_id FROM changed c
      JOIN public.credit_account a ON a.customer_id = c.entity_id AND a.economic_group_id = p_group_id
     WHERE c.entity = 'customer'
  ),
  discounts AS (
    SELECT r.id FROM public.discount_rule r
     WHERE p_since IS NULL AND r.economic_group_id = p_group_id AND r.deleted_at IS NULL
       AND (r.branch_id IS NULL OR r.branch_id = p_branch_id)
       AND (r.valid_to IS NULL OR r.valid_to > pg_catalog.now())
    UNION
    SELECT c.entity_id FROM changed c WHERE c.entity = 'discount_rule'
  )
  SELECT 1, p_branch_id
   WHERE p_since IS NULL OR EXISTS (SELECT 1 FROM changed WHERE entity IN ('fiscal', 'branch'))
  UNION ALL SELECT 2, users.id FROM users
  UNION ALL SELECT 3, products.id FROM products
  UNION ALL SELECT 4, stock.id FROM stock
  UNION ALL SELECT 5, customers.id FROM customers
  UNION ALL SELECT 6, discounts.id FROM discounts
$$;

-- Cliente para o PDV: guardado pelo terminal ou com débito no crediário.
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
                      'credit_limit', ca.credit_limit) ORDER BY a.name)
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

-- Venda vinda do PDV, agora com o crediário.
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
       OR (payment ->> 'dependent_id' IS NOT NULL AND (payment ->> 'method') <> 'store_credit') THEN
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

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  app.open_credit_account(uuid, uuid, numeric, text),
  app.set_credit_limit(uuid, numeric, text),
  app.set_credit_status(uuid, text, text),
  app.set_credit_terms(uuid, jsonb),
  app.set_dependent_credit(uuid, boolean),
  app.list_credit_policies(),
  app.set_credit_policy(uuid, jsonb),
  app.list_credit_accounts(text, text),
  app.credit_account_detail(uuid),
  app.credit_schedule(jsonb, date, numeric, integer),
  app.credit_position(jsonb, date, jsonb),
  app.credit_allocate(jsonb, numeric, date, jsonb)
TO farmaerp_app;
