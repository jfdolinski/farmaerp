-- Up Migration

-- Controlados no caixa (Etapa 4, PR C). A venda de controlado leva os dados da receita, do
-- prescritor e do comprador, o lote e a liberação do farmacêutico, conferida no PDV com código e
-- PIN. Com o estoque negativo, o farmacêutico libera a venda sem os dados na hora: ela chega como
-- pendente e os dados do SNGPC são completados depois, na tela de manutenção (Etapa 8).
-- Os dados pessoais do comprador são exigência sanitária: ficam só aqui e no banco local
-- criptografado do PDV, nunca no log.

INSERT INTO permission (code, module, name) VALUES
  ('controlled.dispense', 'Controlados', 'Liberar a venda de controlados no PDV'),
  ('controlled.view', 'Controlados', 'Ver as vendas de controlados e as pendências');

-- Grupos que já existem: o Farmacêutico vende e libera; o Gerente vê.
INSERT INTO role_permission (role_id, permission_id)
SELECT r.id, p.id
  FROM role r
 CROSS JOIN permission p
 WHERE r.deleted_at IS NULL AND r.system_key IS NULL
   AND ((r.name = 'Farmacêutico' AND p.code IN ('controlled.dispense', 'controlled.view', 'sales.sell'))
        OR (r.name = 'Gerente' AND p.code = 'controlled.view'))
   AND NOT EXISTS (
     SELECT 1 FROM role_permission rp WHERE rp.role_id = r.id AND rp.permission_id = p.id AND rp.deleted_at IS NULL
   );

UPDATE role SET description = 'Libera a venda de controlados no PDV. O SNGPC chega na Etapa 8.'
 WHERE name = 'Farmacêutico' AND system_key IS NULL AND description = 'As permissões chegam com o SNGPC.';

CREATE TABLE controlled_dispensing (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  branch_id uuid NOT NULL REFERENCES branch (id),
  sale_id uuid NOT NULL REFERENCES sale (id),
  sale_item_id uuid NOT NULL REFERENCES sale_item (id),
  product_id uuid NOT NULL REFERENCES product (id),
  batch_id uuid REFERENCES product_batch (id),
  quantity numeric(14, 3) NOT NULL CONSTRAINT controlled_dispensing_quantity_check CHECK (quantity > 0),
  -- Classe do produto na hora da venda (lista da Portaria 344 ou antimicrobiano).
  controlled_class text NOT NULL,
  -- complete: com receita e comprador; pending: liberada com estoque negativo, dados depois.
  status text NOT NULL CONSTRAINT controlled_dispensing_status_check CHECK (status IN ('complete', 'pending')),
  pharmacist_id uuid NOT NULL REFERENCES user_account (id),
  pending_reason text CONSTRAINT controlled_dispensing_pending_reason_check CHECK (length(pending_reason) BETWEEN 1 AND 500),
  prescription_type text CONSTRAINT controlled_dispensing_prescription_type_check CHECK (prescription_type IN (
    'notification_a', 'notification_b', 'notification_b2', 'notification_retinoid', 'notification_thalidomide',
    'special_control', 'antimicrobial'
  )),
  prescription_number text CONSTRAINT controlled_dispensing_prescription_number_check CHECK (prescription_number ~ '^[0-9A-Za-z./-]{1,30}$'),
  prescription_date date,
  prescriber_name text CONSTRAINT controlled_dispensing_prescriber_name_check CHECK (length(btrim(prescriber_name)) BETWEEN 3 AND 150),
  prescriber_council text CONSTRAINT controlled_dispensing_prescriber_council_check CHECK (prescriber_council IN ('CRM', 'CRO', 'CRMV', 'COREN', 'CRF', 'RMS')),
  prescriber_number text CONSTRAINT controlled_dispensing_prescriber_number_check CHECK (prescriber_number ~ '^[0-9A-Za-z-]{1,20}$'),
  prescriber_state char(2) CONSTRAINT controlled_dispensing_prescriber_state_check CHECK (prescriber_state ~ '^[A-Z]{2}$'),
  buyer_name text CONSTRAINT controlled_dispensing_buyer_name_check CHECK (length(btrim(buyer_name)) BETWEEN 3 AND 150),
  buyer_document_type text CONSTRAINT controlled_dispensing_buyer_document_type_check CHECK (buyer_document_type IN ('rg', 'cpf', 'cnh', 'passport', 'other')),
  buyer_document text CONSTRAINT controlled_dispensing_buyer_document_check CHECK (buyer_document ~ '^[0-9A-Za-z./-]{3,30}$'),
  buyer_issuer text CONSTRAINT controlled_dispensing_buyer_issuer_check CHECK (length(btrim(buyer_issuer)) BETWEEN 2 AND 20),
  buyer_state char(2) CONSTRAINT controlled_dispensing_buyer_state_check CHECK (buyer_state ~ '^[A-Z]{2}$'),
  patient_name text CONSTRAINT controlled_dispensing_patient_name_check CHECK (length(btrim(patient_name)) BETWEEN 3 AND 150),
  patient_age smallint CONSTRAINT controlled_dispensing_patient_age_check CHECK (patient_age BETWEEN 0 AND 130),
  patient_sex char(1) CONSTRAINT controlled_dispensing_patient_sex_check CHECK (patient_sex IN ('F', 'M')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid,
  -- Completa: lote, receita, prescritor e comprador. Notificação exige o número; antimicrobiano exige
  -- idade e sexo do paciente. Pendente: o motivo, e nada de receita (vem na manutenção).
  CONSTRAINT controlled_dispensing_complete_check CHECK (
    (status = 'pending' AND pending_reason IS NOT NULL AND prescription_type IS NULL)
    OR (status = 'complete' AND pending_reason IS NULL AND batch_id IS NOT NULL
        AND prescription_type IS NOT NULL AND prescription_date IS NOT NULL
        AND prescriber_name IS NOT NULL AND prescriber_council IS NOT NULL AND prescriber_number IS NOT NULL
        AND prescriber_state IS NOT NULL AND buyer_name IS NOT NULL AND buyer_document_type IS NOT NULL
        AND buyer_document IS NOT NULL AND buyer_issuer IS NOT NULL AND buyer_state IS NOT NULL
        AND (prescription_type NOT LIKE 'notification%' OR prescription_number IS NOT NULL)
        AND (prescription_type <> 'antimicrobial' OR (patient_age IS NOT NULL AND patient_sex IS NOT NULL)))
  )
);
CREATE UNIQUE INDEX controlled_dispensing_item_key ON controlled_dispensing (sale_item_id) WHERE deleted_at IS NULL;
CREATE INDEX controlled_dispensing_branch_idx ON controlled_dispensing (branch_id, created_at DESC);
CREATE INDEX controlled_dispensing_pending_idx ON controlled_dispensing (branch_id) WHERE status = 'pending' AND deleted_at IS NULL;
CREATE INDEX controlled_dispensing_economic_group_id_idx ON controlled_dispensing (economic_group_id);
CREATE INDEX controlled_dispensing_sale_idx ON controlled_dispensing (sale_id);
CREATE INDEX controlled_dispensing_product_idx ON controlled_dispensing (product_id);
CREATE INDEX controlled_dispensing_batch_idx ON controlled_dispensing (batch_id);
CREATE INDEX controlled_dispensing_pharmacist_idx ON controlled_dispensing (pharmacist_id);

CALL app.apply_table_standard('public.controlled_dispensing');

-- O registro da venda não muda; a manutenção do SNGPC (Etapa 8) completa a pendência com função própria.
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON controlled_dispensing
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'branch_id', 'sale_id', 'sale_item_id', 'product_id', 'quantity', 'controlled_class',
    'pharmacist_id'
  );

ALTER TABLE sale_alert DROP CONSTRAINT sale_alert_kind_check;
ALTER TABLE sale_alert ADD CONSTRAINT sale_alert_kind_check CHECK (kind IN (
  'price_divergence', 'discount_above_rule', 'discount_above_limit', 'operator_permission',
  'negative_stock', 'product_status', 'agreement_link', 'offline_zero_stock',
  'controlled_missing', 'controlled_release', 'controlled_pending', 'prescription_expired', 'prescription_type'
));

-- Tipo de receita de cada classe (Portaria 344/98 e RDC 471/2021).
CREATE FUNCTION app.prescription_type_for(p_class text) RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$
  SELECT CASE
    WHEN p_class IN ('A1', 'A2', 'A3') THEN 'notification_a'
    WHEN p_class = 'B1' THEN 'notification_b'
    WHEN p_class = 'B2' THEN 'notification_b2'
    WHEN p_class = 'C2' THEN 'notification_retinoid'
    WHEN p_class = 'C3' THEN 'notification_thalidomide'
    WHEN p_class = 'antimicrobial' THEN 'antimicrobial'
    ELSE 'special_control'
  END
$$;

-- Validade da receita em dias, contados da data da receita. Antimicrobiano: 10 dias; demais: 30.
CREATE FUNCTION app.prescription_valid_days(p_type text) RETURNS integer
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$ SELECT CASE WHEN p_type = 'antimicrobial' THEN 10 ELSE 30 END $$;

-- Vendas de controlados das filiais que a pessoa pode ver. O documento do comprador vai mascarado.
CREATE FUNCTION app.list_controlled_dispensings(p_status text DEFAULT NULL, p_from date DEFAULT NULL, p_to date DEFAULT NULL)
RETURNS TABLE (
  id uuid, sale_id uuid, sale_code text, sold_at timestamptz, branch_name text, product_code bigint, product_name text,
  controlled_class text, batch_number text, quantity numeric, status text, pending_reason text, prescription_type text,
  prescription_number text, prescription_date date, prescriber text, buyer_name text, buyer_document_masked text,
  pharmacist_name text
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT d.id, s.id, s.code, s.sold_at, b.name, p.code, p.display_name, d.controlled_class, pb.batch_number, d.quantity,
         d.status, d.pending_reason, d.prescription_type, d.prescription_number, d.prescription_date,
         CASE WHEN d.prescriber_name IS NOT NULL
              THEN d.prescriber_name || ' · ' || d.prescriber_council || ' ' || d.prescriber_number || '/' || d.prescriber_state END,
         d.buyer_name,
         CASE WHEN d.buyer_document IS NOT NULL
              THEN pg_catalog.repeat('*', GREATEST(pg_catalog.length(d.buyer_document) - 3, 0)) || pg_catalog.right(d.buyer_document, 3) END,
         u.name
    FROM public.controlled_dispensing d
    JOIN public.sale s ON s.id = d.sale_id
    JOIN public.branch b ON b.id = d.branch_id
    JOIN public.product p ON p.id = d.product_id
    JOIN public.user_account u ON u.id = d.pharmacist_id
    LEFT JOIN public.product_batch pb ON pb.id = d.batch_id
   WHERE d.deleted_at IS NULL
     AND d.economic_group_id = app.current_user_group()
     AND app.has_permission('controlled.view', d.branch_id)
     AND (p_status IS NULL OR d.status = p_status)
     AND (p_from IS NULL OR s.sold_at >= p_from::timestamp AT TIME ZONE 'America/Sao_Paulo')
     AND (p_to IS NULL OR s.sold_at < (p_to + 1)::timestamp AT TIME ZONE 'America/Sao_Paulo')
   ORDER BY s.sold_at DESC, d.id DESC
   LIMIT 500
$$;

CREATE POLICY controlled_dispensing_select ON controlled_dispensing FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group()) AND app.has_permission('controlled.view', branch_id));
GRANT SELECT ON controlled_dispensing TO farmaerp_app;
CREATE VIEW v_controlled_dispensing WITH (security_invoker = true) AS
  SELECT * FROM controlled_dispensing WHERE deleted_at IS NULL;
GRANT SELECT ON v_controlled_dispensing TO farmaerp_app;


-- Grava a dispensação de controlado que veio com a venda. Dados que a tabela recusa viram conflito
-- (FA990); o que fecha mas merece atenção vira alerta (farmacêutico sem permissão, receita vencida,
-- tipo de receita que não é o da classe, venda pendente de dados).
CREATE FUNCTION app.record_controlled_dispensing(
  p_terminal public.terminal, p_group_id uuid, p_sale_id uuid, p_item_id uuid, p_product public.product, p_item jsonb,
  p_sold_at timestamptz
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  data jsonb := p_item -> 'controlled';
  product_class text;
  expected_type text;
  pharmacist uuid := (data ->> 'pharmacist_id')::uuid;
  sold_day date := (p_sold_at AT TIME ZONE 'America/Sao_Paulo')::date;
BEGIN
  SELECT cp.controlled_class INTO product_class FROM public.catalog_product cp WHERE cp.id = p_product.catalog_product_id;
  IF product_class IS NULL THEN
    RAISE EXCEPTION 'Os dados do controlado vendido estão incompletos ou inválidos.'
      USING ERRCODE = 'FA990', DETAIL = 'Dados de controlado em produto que não é controlado.';
  END IF;
  BEGIN
    INSERT INTO public.controlled_dispensing (
      id, economic_group_id, branch_id, sale_id, sale_item_id, product_id, batch_id, quantity, controlled_class, status,
      pharmacist_id, pending_reason, prescription_type, prescription_number, prescription_date, prescriber_name,
      prescriber_council, prescriber_number, prescriber_state, buyer_name, buyer_document_type, buyer_document,
      buyer_issuer, buyer_state, patient_name, patient_age, patient_sex
    ) VALUES (
      (data ->> 'id')::uuid, p_group_id, p_terminal.branch_id, p_sale_id, p_item_id, p_product.id,
      (p_item ->> 'batch_id')::uuid, (p_item ->> 'quantity')::numeric, product_class, data ->> 'status', pharmacist,
      NULLIF(pg_catalog.btrim(data ->> 'pending_reason'), ''), data ->> 'prescription_type',
      NULLIF(pg_catalog.btrim(data ->> 'prescription_number'), ''), (data ->> 'prescription_date')::date,
      NULLIF(pg_catalog.btrim(data ->> 'prescriber_name'), ''), data ->> 'prescriber_council',
      NULLIF(pg_catalog.btrim(data ->> 'prescriber_number'), ''), data ->> 'prescriber_state',
      NULLIF(pg_catalog.btrim(data ->> 'buyer_name'), ''), data ->> 'buyer_document_type',
      NULLIF(pg_catalog.btrim(data ->> 'buyer_document'), ''), NULLIF(pg_catalog.btrim(data ->> 'buyer_issuer'), ''),
      data ->> 'buyer_state', NULLIF(pg_catalog.btrim(data ->> 'patient_name'), ''), (data ->> 'patient_age')::smallint,
      data ->> 'patient_sex'
    );
  EXCEPTION
    WHEN check_violation OR not_null_violation OR invalid_text_representation OR datetime_field_overflow
         OR invalid_datetime_format OR numeric_value_out_of_range OR string_data_right_truncation OR unique_violation THEN
      RAISE EXCEPTION 'Os dados do controlado vendido estão incompletos ou inválidos.'
        USING ERRCODE = 'FA990', DETAIL = pg_catalog.format('Controlado do item %s: %s.', p_item_id, SQLERRM);
  END;

  IF NOT app.user_has_permission(pharmacist, 'controlled.dispense', p_terminal.branch_id) THEN
    INSERT INTO public.sale_alert (economic_group_id, branch_id, sale_id, sale_item_id, kind, detail)
    VALUES (p_group_id, p_terminal.branch_id, p_sale_id, p_item_id, 'controlled_release',
            pg_catalog.jsonb_build_object('pharmacist_id', pharmacist));
  END IF;
  IF data ->> 'status' = 'pending' THEN
    INSERT INTO public.sale_alert (economic_group_id, branch_id, sale_id, sale_item_id, kind, detail)
    VALUES (p_group_id, p_terminal.branch_id, p_sale_id, p_item_id, 'controlled_pending',
            pg_catalog.jsonb_build_object('reason', NULLIF(pg_catalog.btrim(data ->> 'pending_reason'), '')));
    RETURN;
  END IF;
  expected_type := app.prescription_type_for(product_class);
  IF data ->> 'prescription_type' <> expected_type THEN
    INSERT INTO public.sale_alert (economic_group_id, branch_id, sale_id, sale_item_id, kind, detail)
    VALUES (p_group_id, p_terminal.branch_id, p_sale_id, p_item_id, 'prescription_type',
            pg_catalog.jsonb_build_object('class', product_class, 'expected', expected_type, 'received', data ->> 'prescription_type'));
  END IF;
  IF (data ->> 'prescription_date')::date > sold_day
     OR (data ->> 'prescription_date')::date + app.prescription_valid_days(data ->> 'prescription_type') < sold_day THEN
    INSERT INTO public.sale_alert (economic_group_id, branch_id, sale_id, sale_item_id, kind, detail)
    VALUES (p_group_id, p_terminal.branch_id, p_sale_id, p_item_id, 'prescription_expired',
            pg_catalog.jsonb_build_object('prescription_date', data ->> 'prescription_date', 'sold_on', sold_day,
                                          'valid_days', app.prescription_valid_days(data ->> 'prescription_type')));
  END IF;
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
    (p_group_id, 'Farmacêutico', 'Libera a venda de controlados no PDV. O SNGPC chega na Etapa 8.'),
    (p_group_id, 'Operador de caixa', 'As permissões chegam com o PDV.');

  -- A liberação do custo e o desconto acima do produto ficam só com o Administrador.
  INSERT INTO public.role_permission (role_id, permission_id)
  SELECT manager_id, p.id
    FROM public.permission p
   WHERE p.code IN (
     'users.view', 'users.reset_password', 'terminals.view', 'terminals.request', 'terminals.block',
     'products.view', 'stock.view', 'stock.loss', 'stock.transfer', 'stock.batch_override',
     'customers.view', 'customers.manage', 'fiscal.certificate', 'purchases.view', 'purchases.manage',
     'purchases.post', 'releases.view', 'sync.view', 'sync.resolve', 'sales.sell', 'sales.view', 'sales.zero_stock_release', 'controlled.view'
   );
  INSERT INTO public.role_permission (role_id, permission_id)
  SELECT r.id, p.id
    FROM public.role r
    JOIN public.permission p ON p.code = 'sales.sell'
   WHERE r.economic_group_id = p_group_id AND r.name = 'Operador de caixa';
  INSERT INTO public.role_permission (role_id, permission_id)
  SELECT r.id, p.id
    FROM public.role r
    JOIN public.permission p ON p.code IN ('sales.sell', 'controlled.dispense', 'controlled.view')
   WHERE r.economic_group_id = p_group_id AND r.name = 'Farmacêutico';
  PERFORM app.seed_manager_limits(manager_id, p_group_id);
END;
$$;

-- Venda vinda do PDV. Fora do formato ou com totais que não fecham: conflito (FA962). Venda
-- conferida: aplicada, com alertas para o que merece atenção.
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



REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  app.list_controlled_dispensings(text, date, date),
  app.prescription_type_for(text),
  app.prescription_valid_days(text)
TO farmaerp_app;
