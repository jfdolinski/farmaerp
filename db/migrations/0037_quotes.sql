-- Up Migration

-- Orçamento e vendedor (Etapa 4, PR D2a). O terminal de orçamento monta o orçamento com o código do
-- vendedor (o PIN é exigido se a filial ligar o parâmetro), entrega uma plaquinha numerada e/ou
-- imprime o cupom, e o orçamento sobe pela outbox. No caixa, cada venda também leva o vendedor.
-- A validade do orçamento é parâmetro da filial, em dias (0: até o fim do dia).

INSERT INTO permission (code, module, name) VALUES
  ('sales.quote', 'Vendas', 'Montar orçamentos no PDV e atender como vendedor');

-- Grupos que já existem: quem vende ou libera também orça; o Balconista só orça.
INSERT INTO role_permission (role_id, permission_id)
SELECT r.id, p.id
  FROM role r
 CROSS JOIN permission p
 WHERE r.deleted_at IS NULL AND r.system_key IS NULL AND p.code = 'sales.quote'
   AND r.name IN ('Operador de caixa', 'Gerente', 'Farmacêutico')
   AND NOT EXISTS (
     SELECT 1 FROM role_permission rp WHERE rp.role_id = r.id AND rp.permission_id = p.id AND rp.deleted_at IS NULL
   );
UPDATE role SET description = 'Abre o caixa, vende e orça no PDV.'
 WHERE name = 'Operador de caixa' AND system_key IS NULL AND description = 'As permissões chegam com o PDV.';
INSERT INTO role (economic_group_id, name, description)
SELECT g.id, 'Balconista', 'Monta orçamentos no PDV para o caixa fechar a venda.'
  FROM economic_group g
 WHERE g.deleted_at IS NULL
   AND NOT EXISTS (SELECT 1 FROM role r WHERE r.economic_group_id = g.id AND r.name = 'Balconista' AND r.deleted_at IS NULL);
INSERT INTO role_permission (role_id, permission_id)
SELECT r.id, p.id
  FROM role r JOIN permission p ON p.code = 'sales.quote'
 WHERE r.name = 'Balconista' AND r.system_key IS NULL AND r.deleted_at IS NULL
   AND NOT EXISTS (
     SELECT 1 FROM role_permission rp WHERE rp.role_id = r.id AND rp.permission_id = p.id AND rp.deleted_at IS NULL
   );

-- Parâmetros da venda por filial.
ALTER TABLE branch ADD COLUMN quote_validity_days smallint NOT NULL DEFAULT 0
  CONSTRAINT branch_quote_validity_days_check CHECK (quote_validity_days BETWEEN 0 AND 90);
ALTER TABLE branch ADD COLUMN seller_pin_required boolean NOT NULL DEFAULT false;
-- Autoatendimento: o vendedor é fixo no terminal (o modo chega com o TEF).
ALTER TABLE terminal ADD COLUMN fixed_seller_id uuid REFERENCES user_account (id);
CREATE INDEX terminal_fixed_seller_idx ON terminal (fixed_seller_id);
-- As views de "SELECT *" guardam as colunas da criação: recria para mostrar as novas.
CREATE OR REPLACE VIEW v_branch WITH (security_invoker = true) AS
  SELECT * FROM branch WHERE deleted_at IS NULL;
CREATE OR REPLACE VIEW v_terminal WITH (security_invoker = true) AS
  SELECT * FROM terminal WHERE deleted_at IS NULL;

CREATE FUNCTION app.set_branch_sale_settings(p_branch_id uuid, p_quote_validity_days integer, p_seller_pin_required boolean)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM app.require_branch_permission('structure.manage', p_branch_id);
  IF p_quote_validity_days IS NULL OR p_quote_validity_days NOT BETWEEN 0 AND 90 OR p_seller_pin_required IS NULL THEN
    RAISE EXCEPTION 'A validade do orçamento precisa ficar entre 0 e 90 dias.'
      USING ERRCODE = 'FA884', DETAIL = pg_catalog.format('%s dias, PIN %s.', p_quote_validity_days, p_seller_pin_required);
  END IF;
  UPDATE public.branch
     SET quote_validity_days = p_quote_validity_days, seller_pin_required = p_seller_pin_required
   WHERE id = p_branch_id;
END;
$$;

-- Perfil de um terminal já aprovado (caixa, orçamento ou autoatendimento): quem aprova terminais
-- troca. O PDV muda de modo na próxima sincronização.
CREATE FUNCTION app.set_terminal_profile(p_terminal_id uuid, p_profile text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.terminal := app.lock_terminal(p_terminal_id, 'terminals.approve');
BEGIN
  IF target.status NOT IN ('active', 'blocked') THEN
    RAISE EXCEPTION 'Esta mudança de situação não é permitida para o terminal.'
      USING ERRCODE = 'FA303', DETAIL = pg_catalog.format('Perfil com situação %s.', target.status);
  END IF;
  IF p_profile IS NULL OR p_profile NOT IN ('quote', 'cashier', 'self_service') THEN
    RAISE EXCEPTION 'O perfil do terminal é inválido.'
      USING ERRCODE = 'FA218', DETAIL = pg_catalog.format('Perfil %s.', p_profile);
  END IF;
  UPDATE public.terminal SET profile = p_profile WHERE id = p_terminal_id;
END;
$$;

-- Vendedor que atendeu a venda (no caixa, pedido a cada venda; vindo do orçamento, o do orçamento).
ALTER TABLE sale ADD COLUMN seller_id uuid REFERENCES user_account (id);
CREATE INDEX sale_seller_idx ON sale (seller_id);
CREATE OR REPLACE VIEW v_sale WITH (security_invoker = true) AS
  SELECT * FROM sale WHERE deleted_at IS NULL;
DROP TRIGGER block_immutable_columns ON sale;
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON sale
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'branch_id', 'terminal_id', 'cash_session_id', 'number', 'code', 'sold_by', 'customer_id',
    'sold_at', 'fiscal_model', 'subtotal', 'discount_total', 'total', 'seller_id'
  );
ALTER TABLE sale_alert DROP CONSTRAINT sale_alert_kind_check;
ALTER TABLE sale_alert ADD CONSTRAINT sale_alert_kind_check CHECK (kind IN (
  'price_divergence', 'discount_above_rule', 'discount_above_limit', 'operator_permission',
  'negative_stock', 'product_status', 'agreement_link', 'offline_zero_stock',
  'controlled_missing', 'controlled_release', 'controlled_pending', 'prescription_expired', 'prescription_type',
  'seller_permission'
));

-- Orçamento: feito no PDV, com código O<terminal>-<número>. Plaquinha é o cartão numerado da loja.
CREATE TABLE quote (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  branch_id uuid NOT NULL REFERENCES branch (id),
  terminal_id uuid NOT NULL REFERENCES terminal (id),
  number bigint NOT NULL CONSTRAINT quote_number_check CHECK (number > 0),
  code text NOT NULL CONSTRAINT quote_code_check CHECK (code ~ '^O[0-9]+-[0-9]{6,}$'),
  seller_id uuid NOT NULL REFERENCES user_account (id),
  customer_id uuid REFERENCES customer (id),
  card_number integer CONSTRAINT quote_card_number_check CHECK (card_number BETWEEN 1 AND 9999),
  -- open: aguardando o caixa; converted: virou venda; replaced: a plaquinha foi para outro orçamento;
  -- expired: passou da validade; cancelled: desistência.
  status text NOT NULL DEFAULT 'open' CONSTRAINT quote_status_check CHECK (status IN ('open', 'converted', 'replaced', 'expired', 'cancelled')),
  quoted_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  subtotal numeric(12, 2) NOT NULL CONSTRAINT quote_subtotal_check CHECK (subtotal >= 0),
  discount_total numeric(12, 2) NOT NULL CONSTRAINT quote_discount_total_check CHECK (discount_total >= 0),
  total numeric(12, 2) NOT NULL CONSTRAINT quote_total_check CHECK (total >= 0),
  replaced_by uuid REFERENCES quote (id) DEFERRABLE INITIALLY DEFERRED,
  converted_sale_id uuid REFERENCES sale (id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid,
  CONSTRAINT quote_replaced_check CHECK ((status = 'replaced') = (replaced_by IS NOT NULL)),
  CONSTRAINT quote_converted_check CHECK ((status = 'converted') = (converted_sale_id IS NOT NULL)),
  CONSTRAINT quote_expiry_check CHECK (expires_at > quoted_at)
);
CREATE UNIQUE INDEX quote_terminal_number_key ON quote (terminal_id, number) WHERE deleted_at IS NULL;
-- Uma plaquinha só segura um orçamento aberto por loja.
CREATE UNIQUE INDEX quote_open_card_key ON quote (branch_id, card_number) WHERE status = 'open' AND card_number IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX quote_branch_idx ON quote (branch_id, quoted_at DESC);
CREATE INDEX quote_code_idx ON quote (economic_group_id, code);
CREATE INDEX quote_economic_group_id_idx ON quote (economic_group_id);
CREATE INDEX quote_terminal_idx ON quote (terminal_id);
CREATE INDEX quote_seller_idx ON quote (seller_id);
CREATE INDEX quote_customer_idx ON quote (customer_id);
CREATE INDEX quote_replaced_by_idx ON quote (replaced_by);
CREATE INDEX quote_converted_sale_idx ON quote (converted_sale_id);
CALL app.apply_table_standard('public.quote');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON quote
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'branch_id', 'terminal_id', 'number', 'code', 'seller_id', 'customer_id', 'card_number',
    'quoted_at', 'expires_at', 'subtotal', 'discount_total', 'total'
  );

CREATE TABLE quote_item (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  quote_id uuid NOT NULL REFERENCES quote (id),
  line smallint NOT NULL CONSTRAINT quote_item_line_check CHECK (line BETWEEN 1 AND 999),
  product_id uuid NOT NULL REFERENCES product (id),
  quantity numeric(12, 3) NOT NULL CONSTRAINT quote_item_quantity_check CHECK (quantity > 0),
  unit_price numeric(12, 2) NOT NULL CONSTRAINT quote_item_unit_price_check CHECK (unit_price >= 0),
  discount numeric(12, 2) NOT NULL CONSTRAINT quote_item_discount_check CHECK (discount >= 0),
  total numeric(12, 2) NOT NULL CONSTRAINT quote_item_total_check CHECK (total >= 0),
  -- Desconto liberado pelo supervisor no terminal de orçamento; o caixa leva para a venda.
  released_by uuid REFERENCES user_account (id),
  release_reason text CONSTRAINT quote_item_release_reason_check CHECK (length(btrim(release_reason)) BETWEEN 1 AND 500),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid,
  CONSTRAINT quote_item_release_check CHECK ((released_by IS NULL) = (release_reason IS NULL))
);
CREATE UNIQUE INDEX quote_item_line_key ON quote_item (quote_id, line) WHERE deleted_at IS NULL;
CREATE INDEX quote_item_economic_group_id_idx ON quote_item (economic_group_id);
CREATE INDEX quote_item_product_idx ON quote_item (product_id);
CREATE INDEX quote_item_released_by_idx ON quote_item (released_by);
CALL app.apply_table_standard('public.quote_item');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON quote_item
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'quote_id', 'line', 'product_id', 'quantity', 'unit_price', 'discount', 'total',
    'released_by', 'release_reason'
  );

-- Situação de agora: o aberto que passou da validade é vencido, mesmo antes de alguém mexer nele.
CREATE FUNCTION app.quote_status_now(p_status text, p_expires_at timestamptz) RETURNS text
LANGUAGE sql STABLE
SET search_path = ''
AS $$ SELECT CASE WHEN p_status = 'open' AND p_expires_at <= pg_catalog.now() THEN 'expired' ELSE p_status END $$;

-- Orçamento vindo do PDV. Fora do formato ou com contas que não fecham: conflito (FA883).
-- A plaquinha passa para o orçamento mais novo; o anterior fica substituído (ou vencido).
CREATE FUNCTION app.sync_apply_quote(p_terminal public.terminal, p_group_id uuid, p_payload jsonb)
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
    id, economic_group_id, quote_id, line, product_id, quantity, unit_price, discount, total, released_by, release_reason
  )
  SELECT (value ->> 'id')::uuid, p_group_id, quote_id, (value ->> 'line')::smallint, (value ->> 'product_id')::uuid,
         (value ->> 'quantity')::numeric, (value ->> 'unit_price')::numeric, (value ->> 'discount')::numeric,
         (value ->> 'total')::numeric, (value -> 'release' ->> 'supervisor_id')::uuid,
         NULLIF(pg_catalog.btrim(value -> 'release' ->> 'reason'), '')
    FROM pg_catalog.jsonb_array_elements(p_payload -> 'items');
END;
$$;

-- Orçamentos para a retaguarda. Até 500, mais recentes primeiro. A situação é a de agora.
CREATE FUNCTION app.list_quotes(p_branch_id uuid DEFAULT NULL, p_from date DEFAULT NULL, p_to date DEFAULT NULL, p_status text DEFAULT NULL)
RETURNS TABLE (
  id uuid, code text, branch_id uuid, branch_name text, terminal_name text, seller_name text, customer_name text,
  card_number integer, status text, quoted_at timestamptz, expires_at timestamptz, total numeric, item_count integer,
  sale_id uuid, sale_code text
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT q.id, q.code, q.branch_id, b.name, t.name, u.name, c.name, q.card_number,
         app.quote_status_now(q.status, q.expires_at), q.quoted_at, q.expires_at, q.total,
         (SELECT pg_catalog.count(*)::integer FROM public.quote_item i WHERE i.quote_id = q.id AND i.deleted_at IS NULL),
         s.id, s.code
    FROM public.quote q
    JOIN public.branch b ON b.id = q.branch_id
    JOIN public.terminal t ON t.id = q.terminal_id
    JOIN public.user_account u ON u.id = q.seller_id
    LEFT JOIN public.customer c ON c.id = q.customer_id
    LEFT JOIN public.sale s ON s.id = q.converted_sale_id
   WHERE q.deleted_at IS NULL
     AND q.economic_group_id = app.current_user_group()
     AND app.has_permission('sales.view', q.branch_id)
     AND (p_branch_id IS NULL OR q.branch_id = p_branch_id)
     AND (p_status IS NULL OR app.quote_status_now(q.status, q.expires_at) = p_status)
     AND (p_from IS NULL OR q.quoted_at >= p_from::timestamp AT TIME ZONE 'America/Sao_Paulo')
     AND (p_to IS NULL OR q.quoted_at < (p_to + 1)::timestamp AT TIME ZONE 'America/Sao_Paulo')
   ORDER BY q.quoted_at DESC, q.id DESC
   LIMIT 500
$$;

CREATE FUNCTION app.quote_detail(p_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT pg_catalog.jsonb_build_object(
    'id', q.id, 'code', q.code, 'branch_name', b.name, 'terminal_name', t.name, 'seller_name', u.name,
    'customer_name', c.name, 'customer_code', c.code, 'card_number', q.card_number,
    'status', app.quote_status_now(q.status, q.expires_at), 'quoted_at', q.quoted_at, 'expires_at', q.expires_at,
    'subtotal', q.subtotal, 'discount_total', q.discount_total, 'total', q.total,
    'replaced_by_code', (SELECT r.code FROM public.quote r WHERE r.id = q.replaced_by),
    'sale_id', s.id, 'sale_code', s.code,
    'items', (
      SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'line', i.line, 'product_id', i.product_id, 'product_code', p.code, 'product_name', p.display_name,
        'quantity', i.quantity, 'unit_price', i.unit_price, 'discount', i.discount, 'total', i.total,
        'released_by_name', ur.name, 'release_reason', i.release_reason
      ) ORDER BY i.line)
        FROM public.quote_item i
        JOIN public.product p ON p.id = i.product_id
        LEFT JOIN public.user_account ur ON ur.id = i.released_by
       WHERE i.quote_id = q.id AND i.deleted_at IS NULL
    )
  )
    FROM public.quote q
    JOIN public.branch b ON b.id = q.branch_id
    JOIN public.terminal t ON t.id = q.terminal_id
    JOIN public.user_account u ON u.id = q.seller_id
    LEFT JOIN public.customer c ON c.id = q.customer_id
    LEFT JOIN public.sale s ON s.id = q.converted_sale_id
   WHERE q.id = p_id AND q.deleted_at IS NULL
     AND q.economic_group_id = app.current_user_group()
     AND app.has_permission('sales.view', q.branch_id)
$$;

CREATE POLICY quote_select ON quote FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group()) AND app.has_permission('sales.view', branch_id));
CREATE POLICY quote_item_select ON quote_item FOR SELECT TO farmaerp_app
  USING (EXISTS (SELECT 1 FROM quote q WHERE q.id = quote_id));
GRANT SELECT ON quote, quote_item TO farmaerp_app;
CREATE VIEW v_quote WITH (security_invoker = true) AS SELECT * FROM quote WHERE deleted_at IS NULL;
CREATE VIEW v_quote_item WITH (security_invoker = true) AS SELECT * FROM quote_item WHERE deleted_at IS NULL;
GRANT SELECT ON v_quote, v_quote_item TO farmaerp_app;

-- O terminal manda de novo os dados fiscais quando muda o perfil, o vendedor fixo ou o tempo sem internet.
CREATE OR REPLACE FUNCTION app.track_terminal_offline_minutes() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NEW.offline_zero_stock_minutes IS DISTINCT FROM OLD.offline_zero_stock_minutes
     OR NEW.profile IS DISTINCT FROM OLD.profile
     OR NEW.fixed_seller_id IS DISTINCT FROM OLD.fixed_seller_id THEN
    PERFORM app.mark_sync_change('fiscal', NEW.branch_id, c.economic_group_id, NEW.branch_id)
       FROM public.branch b JOIN public.company c ON c.id = b.company_id WHERE b.id = NEW.branch_id;
  END IF;
  RETURN NULL;
END;
$$;


-- Dados fiscais do PDV: perfil do terminal, validade do orçamento, PIN do vendedor e o último orçamento.
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


-- Venda vinda do PDV, agora com o vendedor.
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
     OR (p_payload ->> 'seller_id') !~ uuid_any
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
  seller := (p_payload ->> 'seller_id')::uuid;
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
     )) THEN
    RAISE EXCEPTION 'Um dos itens informados não foi encontrado.'
      USING ERRCODE = 'FA004', DETAIL = 'Operador, vendedor ou cliente fora do grupo.';
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
    fiscal_model, subtotal, discount_total, total, seller_id
  ) VALUES (
    sale_id, p_group_id, p_terminal.branch_id, p_terminal.id, (p_payload ->> 'cash_session_id')::uuid,
    (p_payload ->> 'number')::bigint,
    terminal_number || '-' || pg_catalog.lpad(p_payload ->> 'number', 6, '0'),
    operator_id, buyer_id, sale_at, p_payload ->> 'fiscal_model', sum_gross, sum_discount, sum_items, seller
  );
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


-- Perfis padrão dos grupos novos, com o Balconista e quem orça.
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
     'purchases.post', 'releases.view', 'sync.view', 'sync.resolve', 'sales.sell', 'sales.view', 'sales.zero_stock_release', 'controlled.view', 'sales.quote'
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


-- Detalhe da venda, agora com o vendedor.
CREATE OR REPLACE FUNCTION app.sale_detail(p_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT pg_catalog.jsonb_build_object(
    'id', s.id, 'code', s.code, 'branch_name', b.name, 'terminal_name', t.name, 'sold_at', s.sold_at,
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


-- A subida aceita o orçamento.
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


REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  app.set_branch_sale_settings(uuid, integer, boolean),
  app.set_terminal_profile(uuid, text),
  app.list_quotes(uuid, date, date, text),
  app.quote_detail(uuid)
TO farmaerp_app;
