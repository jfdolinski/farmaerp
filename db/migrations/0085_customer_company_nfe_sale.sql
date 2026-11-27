-- Up Migration

-- NF-e de venda no caixa (8B-2a): o cliente pessoa jurídica com cadastro completo.
-- * Indicador de IE do cliente (1 contribuinte, 2 contribuinte isento, 9 não contribuinte). Vazio
--   segue a inscrição estadual: com número é contribuinte, ISENTO é isento, sem inscrição é não
--   contribuinte. A inscrição e o indicador descem para o caixa.
-- * O caixa cadastra pessoa jurídica: CNPJ, razão social, inscrição, e-mail e endereço completo
--   (o que a NF-e exige do destinatário).
-- * A central recebe do caixa a NF-e modelo 55, pela série 55 do terminal, no mesmo item "nfce" da
--   outbox (com o modelo no item). Cancelar, reenviar e consultar a NF-e 55 pela central ficam para
--   a etapa da CC-e: até lá a central recusa com aviso.

-- ===== Indicador de IE do cliente =====

ALTER TABLE customer
  ADD COLUMN ie_indicator smallint,
  ADD CONSTRAINT customer_ie_indicator_check CHECK (
    ie_indicator IS NULL
    OR (ie_indicator = 1 AND COALESCE(state_registration, '') ~ '^[0-9]+$')
    OR (ie_indicator = 2 AND (state_registration IS NULL OR state_registration = 'ISENTO'))
    OR ie_indicator = 9
  );

-- O indicador que vale para a nota: o informado, ou o que a inscrição diz.
CREATE FUNCTION app.customer_ie_indicator(p_indicator smallint, p_registration text) RETURNS smallint
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$
  SELECT COALESCE(p_indicator, CASE
    WHEN p_registration ~ '^[0-9]+$' THEN 1
    WHEN p_registration = 'ISENTO' THEN 2
    ELSE 9
  END)::smallint
$$;

-- Texto vazio é "pela inscrição"; o resto precisa ser 1, 2 ou 9 (o CHECK recusa o que não for).
CREATE FUNCTION app.clean_ie_indicator(p_value text) RETURNS smallint
LANGUAGE plpgsql IMMUTABLE
SET search_path = ''
AS $$
BEGIN
  IF app.clean_text(p_value) IS NULL THEN
    RETURN NULL;
  END IF;
  IF pg_catalog.btrim(p_value) !~ '^[0-9]$' THEN
    RAISE EXCEPTION 'O indicador de IE não confere com a inscrição estadual.' USING ERRCODE = 'FA964', DETAIL = 'Indicador fora do formato.';
  END IF;
  RETURN pg_catalog.btrim(p_value)::smallint;
END;
$$;

CREATE OR REPLACE VIEW v_customer WITH (security_invoker = true) AS
  SELECT * FROM customer WHERE deleted_at IS NULL;

CREATE OR REPLACE FUNCTION app.create_customer(p_data jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.require_customers_manage();
  new_id uuid;
BEGIN
  INSERT INTO public.customer (
    economic_group_id, person_type, document, name, trade_name, birth_date, phone, email,
    postal_code, street, street_number, complement, district, city, city_code, state, state_registration, ie_indicator
  ) VALUES (
    group_id, p_data ->> 'personType', COALESCE(app.clean_document(p_data ->> 'document'), ''),
    COALESCE(app.clean_text(p_data ->> 'name'), ''), app.clean_text(p_data ->> 'tradeName'),
    (p_data ->> 'birthDate')::date, app.clean_digits(p_data ->> 'phone'),
    pg_catalog.lower(app.clean_text(p_data ->> 'email')), app.clean_digits(p_data ->> 'postalCode'),
    app.clean_text(p_data ->> 'street'), app.clean_text(p_data ->> 'streetNumber'),
    app.clean_text(p_data ->> 'complement'), app.clean_text(p_data ->> 'district'),
    app.clean_text(p_data ->> 'city'), app.clean_digits(p_data ->> 'cityCode'),
    pg_catalog.upper(app.clean_text(p_data ->> 'state')),
    app.clean_state_registration(p_data ->> 'stateRegistration'),
    app.clean_ie_indicator(p_data ->> 'ieIndicator')
  ) RETURNING id INTO new_id;
  RETURN new_id;
END;
$$;

CREATE OR REPLACE FUNCTION app.update_customer(p_id uuid, p_data jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.require_customers_manage();
BEGIN
  UPDATE public.customer c
     SET document = COALESCE(app.clean_document(p_data ->> 'document'), ''),
         name = COALESCE(app.clean_text(p_data ->> 'name'), ''),
         trade_name = app.clean_text(p_data ->> 'tradeName'),
         birth_date = (p_data ->> 'birthDate')::date,
         phone = app.clean_digits(p_data ->> 'phone'),
         email = pg_catalog.lower(app.clean_text(p_data ->> 'email')),
         postal_code = app.clean_digits(p_data ->> 'postalCode'),
         street = app.clean_text(p_data ->> 'street'),
         street_number = app.clean_text(p_data ->> 'streetNumber'),
         complement = app.clean_text(p_data ->> 'complement'),
         district = app.clean_text(p_data ->> 'district'),
         city = app.clean_text(p_data ->> 'city'),
         city_code = app.clean_digits(p_data ->> 'cityCode'),
         state = pg_catalog.upper(app.clean_text(p_data ->> 'state')),
         state_registration = app.clean_state_registration(p_data ->> 'stateRegistration'),
         ie_indicator = app.clean_ie_indicator(p_data ->> 'ieIndicator')
   WHERE c.id = p_id AND c.economic_group_id = group_id AND c.deleted_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('customer %s.', p_id);
  END IF;
END;
$$;

-- ===== O caixa recebe a inscrição e o indicador =====

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
           'state_registration', c.state_registration,
           'ie_indicator', app.customer_ie_indicator(c.ie_indicator, c.state_registration),
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

-- ===== Cadastro de pessoa jurídica no caixa =====

-- Pessoa jurídica precisa do endereço completo (a NF-e exige do destinatário) e de município do
-- estado informado (o código IBGE começa pelo código do estado).
CREATE FUNCTION app.ibge_state_code(p_state text) RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$
  SELECT CASE p_state
    WHEN 'RO' THEN '11' WHEN 'AC' THEN '12' WHEN 'AM' THEN '13' WHEN 'RR' THEN '14' WHEN 'PA' THEN '15'
    WHEN 'AP' THEN '16' WHEN 'TO' THEN '17' WHEN 'MA' THEN '21' WHEN 'PI' THEN '22' WHEN 'CE' THEN '23'
    WHEN 'RN' THEN '24' WHEN 'PB' THEN '25' WHEN 'PE' THEN '26' WHEN 'AL' THEN '27' WHEN 'SE' THEN '28'
    WHEN 'BA' THEN '29' WHEN 'MG' THEN '31' WHEN 'ES' THEN '32' WHEN 'RJ' THEN '33' WHEN 'SP' THEN '35'
    WHEN 'PR' THEN '41' WHEN 'SC' THEN '42' WHEN 'RS' THEN '43' WHEN 'MS' THEN '50' WHEN 'MT' THEN '51'
    WHEN 'GO' THEN '52' WHEN 'DF' THEN '53'
  END
$$;

CREATE OR REPLACE FUNCTION app.pdv_create_customer(p_operator_id uuid, p_data jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  terminal_row public.terminal := app.require_active_terminal();
  group_id uuid;
  new_id uuid;
  purpose text;
  result jsonb;
  kind text;
  uf text;
  city_code text;
BEGIN
  SELECT c.economic_group_id INTO group_id
    FROM public.branch b JOIN public.company c ON c.id = b.company_id
   WHERE b.id = terminal_row.branch_id;
  IF p_operator_id IS NULL OR NOT EXISTS (
       SELECT 1 FROM public.user_account u
        WHERE u.id = p_operator_id AND u.economic_group_id = group_id AND u.deleted_at IS NULL AND u.is_active
     ) OR NOT app.user_has_permission(p_operator_id, 'pdv.customer_create', terminal_row.branch_id) THEN
    RAISE EXCEPTION 'Você não tem permissão para esta operação.'
      USING ERRCODE = 'FA002', DETAIL = 'Cadastro de cliente no PDV sem pdv.customer_create.';
  END IF;
  IF pg_catalog.jsonb_typeof(p_data) IS DISTINCT FROM 'object'
     OR app.clean_text(p_data ->> 'name') IS NULL OR pg_catalog.length(app.clean_text(p_data ->> 'name')) < 3 THEN
    RAISE EXCEPTION 'Os dados do cliente são inválidos.' USING ERRCODE = 'FA904', DETAIL = 'Nome do cliente no PDV.';
  END IF;
  kind := COALESCE(app.clean_text(p_data ->> 'personType'), 'individual');
  uf := pg_catalog.upper(app.clean_text(p_data ->> 'state'));
  city_code := app.clean_digits(p_data ->> 'cityCode');
  IF kind = 'company' AND (
       app.clean_digits(p_data ->> 'postalCode') IS NULL OR app.clean_text(p_data ->> 'street') IS NULL
       OR app.clean_text(p_data ->> 'streetNumber') IS NULL OR app.clean_text(p_data ->> 'district') IS NULL
       OR app.clean_text(p_data ->> 'city') IS NULL OR city_code IS NULL OR uf IS NULL
     ) THEN
    RAISE EXCEPTION 'Os dados do cliente são inválidos.' USING ERRCODE = 'FA904', DETAIL = 'Endereço incompleto da pessoa jurídica.';
  END IF;
  IF city_code IS NOT NULL AND pg_catalog.left(city_code, 2) IS DISTINCT FROM app.ibge_state_code(uf) THEN
    RAISE EXCEPTION 'Os dados do cliente são inválidos.' USING ERRCODE = 'FA904', DETAIL = 'Município de outro estado.';
  END IF;

  INSERT INTO public.customer (
    economic_group_id, person_type, document, name, trade_name, birth_date, phone, email,
    postal_code, street, street_number, complement, district, city, city_code, state, state_registration, ie_indicator
  ) VALUES (
    group_id, kind, COALESCE(app.clean_document(p_data ->> 'document'), ''), app.clean_text(p_data ->> 'name'),
    CASE WHEN kind = 'company' THEN app.clean_text(p_data ->> 'tradeName') END,
    CASE WHEN kind = 'individual' THEN NULLIF(p_data ->> 'birthDate', '')::date END,
    app.clean_digits(p_data ->> 'phone'), pg_catalog.lower(app.clean_text(p_data ->> 'email')),
    app.clean_digits(p_data ->> 'postalCode'), app.clean_text(p_data ->> 'street'), app.clean_text(p_data ->> 'streetNumber'),
    app.clean_text(p_data ->> 'complement'), app.clean_text(p_data ->> 'district'), app.clean_text(p_data ->> 'city'),
    city_code, uf, app.clean_state_registration(p_data ->> 'stateRegistration'), app.clean_ie_indicator(p_data ->> 'ieIndicator')
  ) RETURNING id INTO new_id;

  FOREACH purpose IN ARRAY ARRAY['cashback', 'marketing'] LOOP
    IF (p_data -> 'consents' ->> purpose) = 'true' THEN
      INSERT INTO public.customer_consent_event (economic_group_id, customer_id, purpose, granted, channel)
      VALUES (group_id, new_id, purpose, true, 'store');
    END IF;
  END LOOP;

  INSERT INTO public.pdv_customer_cache (economic_group_id, terminal_id, customer_id)
  VALUES (group_id, terminal_row.id, new_id);
  SELECT d.data INTO result FROM app.pdv_customer_data(terminal_row.id, ARRAY[new_id]) d;
  RETURN pg_catalog.jsonb_build_object('id', new_id, 'data', result);
END;
$$;

-- A consulta do CNPJ no caixa (para preencher o cadastro) é só para quem pode cadastrar cliente ali
-- (a permissão já confere usuário ativo e do grupo da filial).
CREATE FUNCTION app.pdv_can_create_customer(p_operator_id uuid) RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  terminal_row public.terminal := app.require_active_terminal();
BEGIN
  RETURN app.user_has_permission(p_operator_id, 'pdv.customer_create', terminal_row.branch_id);
END;
$$;

-- ===== A central recebe a NF-e modelo 55 do caixa =====

ALTER TABLE fiscal_document DROP CONSTRAINT fiscal_document_model_check;
ALTER TABLE fiscal_document ADD CONSTRAINT fiscal_document_model_check CHECK (model IN ('55', '65'));
-- A NF-e 55 do caixa ainda não tem contingência: sai só em emissão normal.
ALTER TABLE fiscal_document ADD CONSTRAINT fiscal_document_model_emission_check CHECK (model = '65' OR emission_type = 1);

CREATE OR REPLACE VIEW v_fiscal_document WITH (security_invoker = true) AS
  SELECT id, economic_group_id, branch_id, terminal_id, sale_id, model, series, number, access_key, environment,
         emission_type, status, protocol, status_code, reason, emitted_at, authorized_at,
         created_at, updated_at, deleted_at, version, updated_by, trace_id
    FROM fiscal_document WHERE deleted_at IS NULL;

-- O item "nfce" leva o modelo (sem ele, 65). A série é a do terminal naquele modelo (modelo
-- desconhecido não tem série), e o modelo é o da venda. A NF-e 55 só sai para venda com cliente.
CREATE OR REPLACE FUNCTION app.sync_apply_nfce(p_terminal public.terminal, p_group_id uuid, p_payload jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  doc_id uuid;
  target_sale public.sale;
  doc_series integer;
  doc_model text := COALESCE(p_payload ->> 'model', '65');
BEGIN
  BEGIN
    doc_id := (p_payload ->> 'id')::uuid;
    doc_series := (p_payload ->> 'series')::integer;
  EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
    RAISE EXCEPTION 'A NFC-e recebida do caixa é inválida.' USING ERRCODE = 'FA735', DETAIL = 'Id ou série fora do formato.';
  END;
  IF EXISTS (
    SELECT 1 FROM public.fiscal_document d
     WHERE d.id = doc_id AND d.terminal_id = p_terminal.id AND d.sale_id::text = p_payload ->> 'sale_id'
       AND d.status IN ('authorized', 'canceled') AND d.deleted_at IS NULL
  ) THEN
    RETURN;
  END IF;
  SELECT s.* INTO target_sale FROM public.sale s
   WHERE s.id = (p_payload ->> 'sale_id')::uuid AND s.terminal_id = p_terminal.id AND s.deleted_at IS NULL;
  IF target_sale.id IS NULL THEN
    RAISE EXCEPTION 'A NFC-e recebida do caixa é inválida.' USING ERRCODE = 'FA735', DETAIL = 'Venda não encontrada neste terminal.';
  END IF;
  IF COALESCE(target_sale.fiscal_model, '65') <> doc_model THEN
    RAISE EXCEPTION 'A NFC-e recebida do caixa é inválida.' USING ERRCODE = 'FA735', DETAIL = 'Modelo diferente do da venda.';
  END IF;
  IF doc_model = '55' AND target_sale.customer_id IS NULL THEN
    RAISE EXCEPTION 'A NFC-e recebida do caixa é inválida.' USING ERRCODE = 'FA735', DETAIL = 'NF-e sem cliente na venda.';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.terminal_fiscal_series fs
     WHERE fs.terminal_id = p_terminal.id AND fs.model = doc_model AND fs.series = doc_series AND fs.deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'A NFC-e recebida do caixa é inválida.' USING ERRCODE = 'FA735', DETAIL = 'Série que não é a do terminal.';
  END IF;
  BEGIN
    INSERT INTO public.fiscal_document AS d (
      id, economic_group_id, branch_id, terminal_id, sale_id, model, series, number, access_key, environment,
      emission_type, status, protocol, status_code, reason, xml, emitted_at, authorized_at
    ) VALUES (
      doc_id, p_group_id, p_terminal.branch_id, p_terminal.id, target_sale.id, doc_model, doc_series,
      (p_payload ->> 'number')::bigint, p_payload ->> 'access_key', (p_payload ->> 'environment')::smallint,
      (p_payload ->> 'emission_type')::smallint, p_payload ->> 'status', NULLIF(p_payload ->> 'protocol', ''),
      NULLIF(p_payload ->> 'status_code', ''), NULLIF(pg_catalog.left(p_payload ->> 'reason', 500), ''), p_payload ->> 'xml',
      (p_payload ->> 'emitted_at')::timestamptz, (p_payload ->> 'authorized_at')::timestamptz
    )
    ON CONFLICT (id) DO UPDATE
      SET status = EXCLUDED.status, emission_type = EXCLUDED.emission_type, protocol = EXCLUDED.protocol,
          status_code = EXCLUDED.status_code, reason = EXCLUDED.reason, xml = EXCLUDED.xml,
          authorized_at = EXCLUDED.authorized_at
      WHERE d.terminal_id = p_terminal.id AND d.sale_id = EXCLUDED.sale_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'A NFC-e recebida do caixa é inválida.' USING ERRCODE = 'FA735', DETAIL = 'Id de outra nota.';
    END IF;
  EXCEPTION
    WHEN check_violation OR not_null_violation OR unique_violation OR invalid_text_representation
         OR invalid_datetime_format OR datetime_field_overflow OR numeric_value_out_of_range THEN
      RAISE EXCEPTION 'A NFC-e recebida do caixa é inválida.' USING ERRCODE = 'FA735', DETAIL = SQLERRM;
  END;
END;
$$;

-- O reenvio automático da central fala com a Sefaz da NFC-e: a NF-e 55 fica com o caixa.
CREATE OR REPLACE FUNCTION app.claim_fiscal_resend(p_limit integer DEFAULT 30) RETURNS SETOF uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_group uuid;
BEGIN
  PERFORM app.require_fiscal_worker();
  FOR v_group IN
    SELECT DISTINCT d.economic_group_id FROM public.fiscal_document d
     WHERE d.model = '65' AND d.status IN ('pending', 'contingency') AND d.deleted_at IS NULL
       AND (d.resend_attempted_at IS NULL OR d.resend_status = 'unavailable')
  LOOP
    CONTINUE WHEN EXISTS (
      SELECT 1 FROM public.fiscal_document d
       WHERE d.economic_group_id = v_group AND d.resend_attempted_at > pg_catalog.now() - interval '55 minutes'
    );
    RETURN QUERY
      WITH picked AS (
        SELECT d.id FROM public.fiscal_document d
          JOIN public.branch b ON b.id = d.branch_id
         WHERE d.economic_group_id = v_group AND d.model = '65' AND d.status IN ('pending', 'contingency') AND d.deleted_at IS NULL
           AND (d.resend_attempted_at IS NULL OR d.resend_status = 'unavailable')
           AND d.emitted_at < pg_catalog.now() - pg_catalog.make_interval(mins => b.nfce_contingency_hours * 30)
         ORDER BY (d.resend_attempted_at IS NOT NULL), d.emitted_at, d.id
         LIMIT GREATEST(1, LEAST(p_limit, 30))
         FOR UPDATE OF d SKIP LOCKED
      )
      UPDATE public.fiscal_document d SET resend_attempted_at = pg_catalog.now(), resend_status = NULL, resend_message = NULL,
             resend_attempts = d.resend_attempts + 1
        FROM picked WHERE d.id = picked.id
      RETURNING d.id;
  END LOOP;
END;
$$;

-- O caixa também não cancela a NF-e 55 por enquanto (os serviços são os da NFC-e).
CREATE OR REPLACE FUNCTION app.terminal_cancel_context(p_document_id uuid, p_supervisor_id uuid) RETURNS TABLE (
  id uuid, economic_group_id uuid, branch_id uuid, company_id uuid, sale_id uuid, status text, access_key text, environment smallint,
  series integer, number bigint, protocol text, xml text, authorized_at timestamptz, cnpj text, state text,
  encrypted_pfx bytea, encrypted_password bytea
)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_terminal public.terminal := app.require_active_terminal();
  v_doc public.fiscal_document := app.terminal_fiscal_document(v_terminal, p_document_id);
  v_sale public.sale;
  v_blocker text;
BEGIN
  PERFORM app.require_cancel_supervisor(v_terminal, p_supervisor_id);
  IF v_doc.model = '55' THEN
    RAISE EXCEPTION 'Esta operação ainda não está disponível para a NF-e de venda.' USING ERRCODE = 'FA780', DETAIL = 'cancel';
  END IF;
  IF v_doc.status <> 'canceled' THEN
    IF v_doc.status <> 'authorized' THEN
      RAISE EXCEPTION 'Esta NFC-e não está numa situação que permita a operação.' USING ERRCODE = 'FA753', DETAIL = v_doc.status;
    END IF;
    IF v_doc.authorized_at < pg_catalog.now() - interval '30 minutes' THEN
      RAISE EXCEPTION 'O prazo para cancelar esta NFC-e já passou.' USING ERRCODE = 'FA748', DETAIL = v_doc.authorized_at::text;
    END IF;
    SELECT * INTO v_sale FROM public.sale s WHERE s.id = v_doc.sale_id;
    v_blocker := app.sale_cancel_blocker(v_sale);
    IF v_blocker IS NOT NULL THEN
      RAISE EXCEPTION '%', CASE v_blocker
        WHEN 'FA749' THEN 'Esta venda já teve devolução e não pode ser cancelada.'
        WHEN 'FA750' THEN 'Esta venda já entrou numa fatura do convênio e não pode ser cancelada.'
        WHEN 'FA751' THEN 'Esta venda tem controlado já conferido no SNGPC e não pode ser cancelada.'
        ELSE 'Esta venda tem parcela do crediário já paga e não pode ser cancelada.' END
        USING ERRCODE = v_blocker, DETAIL = pg_catalog.format('Venda %s.', v_sale.id);
    END IF;
  END IF;
  RETURN QUERY
    SELECT v_doc.id, v_doc.economic_group_id, v_doc.branch_id, b.company_id, v_doc.sale_id, v_doc.status, v_doc.access_key, v_doc.environment,
           v_doc.series, v_doc.number, v_doc.protocol, v_doc.xml, v_doc.authorized_at, b.cnpj::text, b.state::text,
           bc.encrypted_pfx, bc.encrypted_password
      FROM public.branch b
      LEFT JOIN public.branch_certificate bc ON bc.branch_id = b.id AND bc.deleted_at IS NULL
     WHERE b.id = v_doc.branch_id;
END;
$$;

-- Reenviar, consultar ou cancelar pela central usa os serviços da NFC-e: a NF-e 55 é recusada.
CREATE OR REPLACE FUNCTION app.fiscal_action_context(p_document_id uuid, p_action text) RETURNS TABLE (
  id uuid, economic_group_id uuid, branch_id uuid, company_id uuid, sale_id uuid, status text, access_key text, environment smallint,
  series integer, number bigint, protocol text, xml text, authorized_at timestamptz, cnpj text, state text,
  encrypted_pfx bytea, encrypted_password bytea
)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_doc public.fiscal_document;
  v_sale public.sale;
  v_blocker text;
BEGIN
  SELECT * INTO v_doc FROM public.fiscal_document d WHERE d.id = p_document_id AND d.deleted_at IS NULL;
  IF app.current_user_id() IS NULL THEN
    PERFORM app.require_fiscal_worker();
    IF p_action <> 'resend' THEN
      RAISE EXCEPTION 'Você não tem permissão para esta operação.' USING ERRCODE = 'FA002', DETAIL = 'Rotina só reenvia.';
    END IF;
  ELSIF v_doc.id IS NULL OR v_doc.economic_group_id <> app.current_user_group()
        OR NOT app.has_permission(CASE p_action WHEN 'cancel' THEN 'fiscal.cancel' WHEN 'resend' THEN 'fiscal.void' ELSE 'sales.view' END, v_doc.branch_id) THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.' USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('fiscal_document %s.', p_document_id);
  END IF;
  IF v_doc.id IS NULL THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.' USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('fiscal_document %s.', p_document_id);
  END IF;
  IF v_doc.model = '55' THEN
    RAISE EXCEPTION 'Esta operação ainda não está disponível para a NF-e de venda.' USING ERRCODE = 'FA780', DETAIL = p_action;
  END IF;
  IF p_action = 'cancel' THEN
    IF v_doc.status <> 'authorized' THEN
      RAISE EXCEPTION 'Esta NFC-e não está numa situação que permita a operação.' USING ERRCODE = 'FA753', DETAIL = v_doc.status;
    END IF;
    IF v_doc.authorized_at < pg_catalog.now() - interval '30 minutes' THEN
      RAISE EXCEPTION 'O prazo para cancelar esta NFC-e já passou.' USING ERRCODE = 'FA748', DETAIL = v_doc.authorized_at::text;
    END IF;
    SELECT * INTO v_sale FROM public.sale s WHERE s.id = v_doc.sale_id;
    v_blocker := app.sale_cancel_blocker(v_sale);
    IF v_blocker IS NOT NULL THEN
      RAISE EXCEPTION '%', CASE v_blocker
        WHEN 'FA749' THEN 'Esta venda já teve devolução e não pode ser cancelada.'
        WHEN 'FA750' THEN 'Esta venda já entrou numa fatura do convênio e não pode ser cancelada.'
        WHEN 'FA751' THEN 'Esta venda tem controlado já conferido no SNGPC e não pode ser cancelada.'
        ELSE 'Esta venda tem parcela do crediário já paga e não pode ser cancelada.' END
        USING ERRCODE = v_blocker, DETAIL = pg_catalog.format('Venda %s.', v_sale.id);
    END IF;
  ELSIF p_action = 'resend' AND v_doc.status NOT IN ('pending', 'contingency', 'rejected') THEN
    RAISE EXCEPTION 'Esta NFC-e não está numa situação que permita a operação.' USING ERRCODE = 'FA753', DETAIL = v_doc.status;
  ELSIF p_action NOT IN ('cancel', 'resend', 'consult') THEN
    RAISE EXCEPTION 'Alguns dados informados são inválidos.' USING ERRCODE = 'FA005', DETAIL = p_action;
  END IF;
  RETURN QUERY
    SELECT v_doc.id, v_doc.economic_group_id, v_doc.branch_id, b.company_id, v_doc.sale_id, v_doc.status, v_doc.access_key, v_doc.environment,
           v_doc.series, v_doc.number, v_doc.protocol, v_doc.xml, v_doc.authorized_at, b.cnpj::text, b.state::text,
           bc.encrypted_pfx, bc.encrypted_password
      FROM public.branch b
      LEFT JOIN public.branch_certificate bc ON bc.branch_id = b.id AND bc.deleted_at IS NULL
     WHERE b.id = v_doc.branch_id;
END;
$$;

-- A lista e os arquivos dizem o modelo (o DANFE A4 sai só da NF-e 55; a NFC-e tem o cupom).
DROP FUNCTION app.list_fiscal_documents(uuid, date, date, text, boolean);
CREATE FUNCTION app.list_fiscal_documents(
  p_branch_id uuid DEFAULT NULL, p_from date DEFAULT NULL, p_to date DEFAULT NULL, p_status text DEFAULT NULL, p_alerts boolean DEFAULT false
)
RETURNS TABLE (
  id uuid, sale_id uuid, sale_code text, branch_id uuid, branch_name text, terminal_name text, model text, series integer, number bigint,
  access_key text, environment smallint, emission_type smallint, status text, status_code text, reason text, emitted_at timestamptz,
  authorized_at timestamptz, total numeric, resend_attempted_at timestamptz, resend_status text, resend_message text,
  alert boolean, cancel_note text, cancelable_until timestamptz
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT d.id, d.sale_id, s.code, d.branch_id, b.name, t.name, d.model, d.series, d.number, d.access_key, d.environment, d.emission_type,
         d.status, d.status_code, d.reason, d.emitted_at, d.authorized_at, s.total, d.resend_attempted_at, d.resend_status,
         d.resend_message,
         ((d.resend_status = 'refused' AND d.status IN ('rejected', 'pending', 'contingency')) OR d.cancel_note IS NOT NULL) AND d.alert_dismissed_at IS NULL,
         d.cancel_note,
         CASE WHEN d.model = '65' AND d.status = 'authorized' AND d.authorized_at > pg_catalog.now() - interval '30 minutes'
              THEN d.authorized_at + interval '30 minutes' END
    FROM public.fiscal_document d
    JOIN public.sale s ON s.id = d.sale_id
    JOIN public.branch b ON b.id = d.branch_id
    JOIN public.terminal t ON t.id = d.terminal_id
   WHERE d.deleted_at IS NULL AND d.economic_group_id = app.current_user_group()
     AND app.has_permission('sales.view', d.branch_id)
     AND (p_branch_id IS NULL OR d.branch_id = p_branch_id)
     AND (p_status IS NULL OR d.status = p_status)
     AND (NOT p_alerts OR (((d.resend_status = 'refused' AND d.status IN ('rejected', 'pending', 'contingency')) OR d.cancel_note IS NOT NULL) AND d.alert_dismissed_at IS NULL))
     AND (p_from IS NULL OR d.emitted_at >= p_from::timestamp AT TIME ZONE 'America/Sao_Paulo')
     AND (p_to IS NULL OR d.emitted_at < (p_to + 1)::timestamp AT TIME ZONE 'America/Sao_Paulo')
   ORDER BY d.emitted_at DESC, d.id DESC
   LIMIT 500
$$;

CREATE OR REPLACE FUNCTION app.fiscal_document_files(p_document_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT pg_catalog.jsonb_build_object(
    'access_key', d.access_key, 'status', d.status, 'xml', d.xml, 'model', d.model,
    'cancellation', (SELECT pg_catalog.jsonb_build_object('reason', e.reason, 'protocol', e.protocol, 'registered_at', e.registered_at, 'xml', e.xml)
                       FROM public.fiscal_event e WHERE e.fiscal_document_id = d.id AND e.kind = 'cancellation' AND e.deleted_at IS NULL))
    FROM public.fiscal_document d
   WHERE d.id = p_document_id AND d.deleted_at IS NULL AND d.economic_group_id = app.current_user_group()
     AND app.has_permission('sales.view', d.branch_id)
$$;

CREATE OR REPLACE FUNCTION app.sale_fiscal_document(p_sale_id uuid) RETURNS jsonb
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT pg_catalog.jsonb_build_object(
    'id', d.id, 'model', d.model, 'series', d.series, 'number', d.number, 'access_key', d.access_key, 'environment', d.environment,
    'emission_type', d.emission_type, 'status', d.status, 'protocol', d.protocol, 'status_code', d.status_code,
    'reason', d.reason, 'emitted_at', d.emitted_at, 'authorized_at', d.authorized_at)
    FROM public.v_fiscal_document d WHERE d.sale_id = p_sale_id
$$;

REVOKE ALL ON FUNCTION app.customer_ie_indicator(smallint, text), app.pdv_can_create_customer(uuid), app.clean_ie_indicator(text), app.ibge_state_code(text),
  app.list_fiscal_documents(uuid, date, date, text, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.customer_ie_indicator(smallint, text), app.pdv_can_create_customer(uuid), app.list_fiscal_documents(uuid, date, date, text, boolean)
  TO farmaerp_app;
