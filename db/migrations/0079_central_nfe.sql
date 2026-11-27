-- Up Migration

-- NF-e modelo 55 emitida pela central (8B-3b), começando pela devolução ao fornecedor: a nota é
-- montada e assinada na API com o mesmo motor do PDV (@farmaerp/fiscal-js) e transmitida à Sefaz da
-- UF. Fica numa tabela própria (central_nfe), fora das rotinas da NFC-e dos caixas (reenvio,
-- cancelamento e inutilização da NFC-e não enxergam estas notas). Numeração própria por filial, numa
-- série que nenhum caixa usa no modelo 55. As regras fiscais da devolução (CFOP e situação
-- tributária) ficam por filial, com valores sugeridos A CONFIRMAR COM O CONTADOR.

INSERT INTO permission (code, module, name) VALUES ('fiscal.nfe_issue', 'Fiscal', 'Emitir NF-e na retaguarda (devolução ao fornecedor)');

-- Série e último número da NF-e da central, por filial.
CREATE TABLE central_nfe_series (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  branch_id uuid NOT NULL REFERENCES branch (id),
  series integer NOT NULL CONSTRAINT central_nfe_series_series_check CHECK (series BETWEEN 1 AND 889),
  last_used_number bigint NOT NULL DEFAULT 0 CONSTRAINT central_nfe_series_last_used_check CHECK (last_used_number BETWEEN 0 AND 999999999),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE UNIQUE INDEX central_nfe_series_branch_key ON central_nfe_series (branch_id) WHERE deleted_at IS NULL;
CREATE INDEX central_nfe_series_economic_group_id_idx ON central_nfe_series (economic_group_id);
CALL app.apply_table_standard('public.central_nfe_series');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON central_nfe_series
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns('economic_group_id', 'branch_id', 'series', 'deleted_at');
CREATE POLICY central_nfe_series_select ON central_nfe_series FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group()) AND app.has_permission('purchases.view', branch_id));
CREATE VIEW v_central_nfe_series WITH (security_invoker = true) AS SELECT * FROM central_nfe_series WHERE deleted_at IS NULL;
GRANT SELECT ON central_nfe_series, v_central_nfe_series TO farmaerp_app;

-- Regras fiscais da NF-e de devolução de compra, por filial. Os valores padrão são sugestões e
-- precisam ser confirmados com o contador: CFOP 5202/6202 (devolução de compra para comercialização)
-- e 5411/6411 (com substituição tributária); Simples: CSOSN 102 e 500 (com ST); regime normal: CST
-- 00 (com a alíquota do ICMS da nota de compra) e 60 (com ST); PIS e COFINS 49 (outras saídas).
CREATE TABLE purchase_return_tax_setting (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  branch_id uuid NOT NULL REFERENCES branch (id),
  cfop_internal text NOT NULL DEFAULT '5202' CONSTRAINT purchase_return_tax_cfop_internal_check CHECK (cfop_internal ~ '^5[0-9]{3}$'),
  cfop_interstate text NOT NULL DEFAULT '6202' CONSTRAINT purchase_return_tax_cfop_interstate_check CHECK (cfop_interstate ~ '^6[0-9]{3}$'),
  cfop_st_internal text NOT NULL DEFAULT '5411' CONSTRAINT purchase_return_tax_cfop_st_internal_check CHECK (cfop_st_internal ~ '^5[0-9]{3}$'),
  cfop_st_interstate text NOT NULL DEFAULT '6411' CONSTRAINT purchase_return_tax_cfop_st_interstate_check CHECK (cfop_st_interstate ~ '^6[0-9]{3}$'),
  simples_csosn text NOT NULL DEFAULT '102' CONSTRAINT purchase_return_tax_simples_csosn_check CHECK (simples_csosn IN ('102', '103', '300', '400', '500')),
  simples_csosn_st text NOT NULL DEFAULT '500' CONSTRAINT purchase_return_tax_simples_csosn_st_check CHECK (simples_csosn_st IN ('102', '103', '300', '400', '500')),
  normal_cst text NOT NULL DEFAULT '00' CONSTRAINT purchase_return_tax_normal_cst_check CHECK (normal_cst IN ('00', '40', '41', '50', '60')),
  normal_cst_st text NOT NULL DEFAULT '60' CONSTRAINT purchase_return_tax_normal_cst_st_check CHECK (normal_cst_st IN ('00', '40', '41', '50', '60')),
  pis_cst text NOT NULL DEFAULT '49' CONSTRAINT purchase_return_tax_pis_cst_check CHECK (pis_cst IN ('04', '05', '06', '07', '08', '09', '49', '99')),
  cofins_cst text NOT NULL DEFAULT '49' CONSTRAINT purchase_return_tax_cofins_cst_check CHECK (cofins_cst IN ('04', '05', '06', '07', '08', '09', '49', '99')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE UNIQUE INDEX purchase_return_tax_setting_branch_key ON purchase_return_tax_setting (branch_id) WHERE deleted_at IS NULL;
CREATE INDEX purchase_return_tax_setting_economic_group_id_idx ON purchase_return_tax_setting (economic_group_id);
CALL app.apply_table_standard('public.purchase_return_tax_setting');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON purchase_return_tax_setting
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns('economic_group_id', 'branch_id', 'deleted_at');
CREATE POLICY purchase_return_tax_setting_select ON purchase_return_tax_setting FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group()) AND app.has_permission('purchases.view', branch_id));
CREATE VIEW v_purchase_return_tax_setting WITH (security_invoker = true) AS SELECT * FROM purchase_return_tax_setting WHERE deleted_at IS NULL;
GRANT SELECT ON purchase_return_tax_setting, v_purchase_return_tax_setting TO farmaerp_app;

-- NF-e emitida pela central. Autorizada não muda mais; recusada pode ser emitida de novo (com outro
-- número); pendente (sem resposta da Sefaz) pode ser transmitida de novo com o mesmo XML.
CREATE TABLE central_nfe (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  branch_id uuid NOT NULL REFERENCES branch (id),
  kind text NOT NULL CONSTRAINT central_nfe_kind_check CHECK (kind IN ('supplier_return')),
  purchase_return_id uuid REFERENCES purchase_return (id),
  series integer NOT NULL CONSTRAINT central_nfe_series_check CHECK (series BETWEEN 1 AND 889),
  number bigint NOT NULL CONSTRAINT central_nfe_number_check CHECK (number BETWEEN 1 AND 999999999),
  access_key text NOT NULL CONSTRAINT central_nfe_access_key_check CHECK (access_key ~ '^[0-9]{44}$'),
  environment smallint NOT NULL CONSTRAINT central_nfe_environment_check CHECK (environment IN (1, 2)),
  status text NOT NULL CONSTRAINT central_nfe_status_check CHECK (status IN ('pending', 'authorized', 'rejected')),
  protocol text CONSTRAINT central_nfe_protocol_check CHECK (protocol ~ '^[0-9]{15}$'),
  status_code text CONSTRAINT central_nfe_status_code_check CHECK (status_code ~ '^[0-9]{3}$'),
  reason text CONSTRAINT central_nfe_reason_check CHECK (length(reason) <= 500),
  xml text NOT NULL CONSTRAINT central_nfe_xml_check CHECK (length(xml) BETWEEN 100 AND 2000000),
  total_value numeric(15, 2) NOT NULL CONSTRAINT central_nfe_total_value_check CHECK (total_value >= 0),
  emitted_at timestamptz NOT NULL,
  authorized_at timestamptz,
  user_id uuid NOT NULL REFERENCES user_account (id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid,
  CONSTRAINT central_nfe_authorized_check CHECK ((status = 'authorized') = (protocol IS NOT NULL AND authorized_at IS NOT NULL)),
  CONSTRAINT central_nfe_source_check CHECK ((kind = 'supplier_return') = (purchase_return_id IS NOT NULL))
);
CREATE UNIQUE INDEX central_nfe_access_key_key ON central_nfe (access_key) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX central_nfe_number_key ON central_nfe (branch_id, series, number) WHERE deleted_at IS NULL;
-- Uma devolução tem no máximo uma nota viva (pendente ou autorizada); as recusadas ficam no histórico.
CREATE UNIQUE INDEX central_nfe_return_live_key ON central_nfe (purchase_return_id) WHERE deleted_at IS NULL AND status <> 'rejected';
CREATE INDEX central_nfe_purchase_return_idx ON central_nfe (purchase_return_id);
CREATE INDEX central_nfe_user_id_idx ON central_nfe (user_id);
CREATE INDEX central_nfe_economic_group_id_idx ON central_nfe (economic_group_id);
CALL app.apply_table_standard('public.central_nfe');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON central_nfe
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'branch_id', 'kind', 'purchase_return_id', 'series', 'number', 'access_key', 'environment',
    'total_value', 'emitted_at', 'user_id', 'deleted_at'
  );
CREATE FUNCTION app.guard_central_nfe() RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF OLD.status IN ('authorized', 'rejected') AND (NEW.status IS DISTINCT FROM OLD.status OR NEW.xml IS DISTINCT FROM OLD.xml) THEN
    RAISE EXCEPTION 'Esta NF-e já teve resposta da Sefaz e não muda mais.'
      USING ERRCODE = 'FA772', DETAIL = pg_catalog.format('central_nfe %s em %s.', OLD.id, OLD.status);
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER guard_central_nfe BEFORE UPDATE ON central_nfe FOR EACH ROW EXECUTE FUNCTION app.guard_central_nfe();
CREATE POLICY central_nfe_select ON central_nfe FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group()) AND app.has_permission('purchases.view', branch_id));
CREATE VIEW v_central_nfe WITH (security_invoker = true) AS
  SELECT id, economic_group_id, branch_id, kind, purchase_return_id, series, number, access_key, environment, status, protocol,
         status_code, reason, total_value, emitted_at, authorized_at, user_id, created_at, updated_at, deleted_at, version,
         updated_by, trace_id
    FROM central_nfe WHERE deleted_at IS NULL;
GRANT SELECT ON central_nfe, v_central_nfe TO farmaerp_app;

-- Rotina da API que monta e transmite (o usuário já foi conferido ao preparar).
CREATE FUNCTION app.lock_central_nfe_series(p_group_id uuid, p_branch_id uuid) RETURNS public.central_nfe_series
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  found_series public.central_nfe_series;
  free integer;
BEGIN
  SELECT * INTO found_series FROM public.central_nfe_series s WHERE s.branch_id = p_branch_id AND s.deleted_at IS NULL FOR UPDATE;
  IF FOUND THEN
    RETURN found_series;
  END IF;
  -- A menor série que nenhum caixa da filial usa no modelo 55.
  SELECT pg_catalog.min(n) INTO free FROM pg_catalog.generate_series(1, 889) AS n
   WHERE NOT EXISTS (
     SELECT 1 FROM public.terminal_fiscal_series t WHERE t.branch_id = p_branch_id AND t.model = '55' AND t.series = n
   );
  INSERT INTO public.central_nfe_series (economic_group_id, branch_id, series)
  VALUES (p_group_id, p_branch_id, free)
  RETURNING * INTO found_series;
  RETURN found_series;
END;
$$;

-- Alíquota do ICMS do item na nota de compra (pICMS do grupo de ICMS no XML guardado).
CREATE FUNCTION app.purchase_item_icms(p_invoice public.purchase_invoice, p_item_number integer) RETURNS jsonb
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT g.value
    FROM pg_catalog.jsonb_array_elements(COALESCE(p_invoice.content -> 'det', '[]'::jsonb)) AS d(value)
    CROSS JOIN LATERAL pg_catalog.jsonb_each(COALESCE(d.value -> 'imposto' -> 'ICMS', '{}'::jsonb)) AS g(key, value)
   WHERE (d.value ->> '@_nItem')::integer = p_item_number OR (d.value ->> 'nItem')::integer = p_item_number
   LIMIT 1
$$;

-- Prepara a NF-e da devolução: confere tudo, reserva o número e devolve o que o motor precisa
-- (o instante da emissão, o código numérico e o ambiente quem põe é a API). O certificado vai junto,
-- ainda cifrado.
CREATE FUNCTION app.return_nfe_prepare(p_return_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  ret public.purchase_return;
  invoice public.purchase_invoice;
  supplier public.supplier;
  branch_row public.branch;
  company_row public.company;
  rules public.purchase_return_tax_setting;
  numbering public.central_nfe_series;
  interstate boolean;
  simples boolean;
  items jsonb := '[]'::jsonb;
  line record;
  st boolean;
  icms jsonb;
  tax jsonb;
  certificate record;
BEGIN
  SELECT * INTO ret FROM public.purchase_return r
   WHERE r.id = p_return_id AND r.economic_group_id = app.current_user_group() AND r.deleted_at IS NULL
   FOR UPDATE;
  IF ret.id IS NULL THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.' USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('purchase_return %s.', p_return_id);
  END IF;
  PERFORM app.require_purchase_permission('fiscal.nfe_issue', ret.branch_id);
  IF EXISTS (SELECT 1 FROM public.central_nfe n WHERE n.purchase_return_id = ret.id AND n.status <> 'rejected' AND n.deleted_at IS NULL) THEN
    RAISE EXCEPTION 'Esta devolução já tem NF-e emitida ou em transmissão.'
      USING ERRCODE = 'FA773', DETAIL = pg_catalog.format('purchase_return %s.', ret.id);
  END IF;
  SELECT * INTO invoice FROM public.purchase_invoice i WHERE i.id = ret.invoice_id;
  SELECT * INTO supplier FROM public.supplier s WHERE s.id = invoice.supplier_id;
  SELECT * INTO branch_row FROM public.branch b WHERE b.id = ret.branch_id;
  SELECT * INTO company_row FROM public.company c WHERE c.id = branch_row.company_id;
  IF branch_row.state_registration IS NULL OR branch_row.street IS NULL OR branch_row.street_number IS NULL
     OR branch_row.district IS NULL OR branch_row.city IS NULL OR branch_row.city_code IS NULL OR branch_row.state IS NULL
     OR branch_row.postal_code IS NULL OR company_row.tax_regime IS NULL THEN
    RAISE EXCEPTION 'A filial está sem os dados fiscais completos.'
      USING ERRCODE = 'FA724', DETAIL = pg_catalog.format('branch %s.', branch_row.id);
  END IF;
  IF supplier.id IS NULL OR supplier.cnpj IS NULL OR supplier.street IS NULL OR supplier.street_number IS NULL
     OR supplier.district IS NULL OR supplier.city IS NULL OR supplier.city_code IS NULL OR supplier.state IS NULL
     OR supplier.postal_code IS NULL THEN
    RAISE EXCEPTION 'O cadastro do fornecedor está sem o endereço completo para a NF-e.'
      USING ERRCODE = 'FA771', DETAIL = pg_catalog.format('supplier %s.', invoice.supplier_id);
  END IF;
  SELECT * INTO rules FROM public.purchase_return_tax_setting t WHERE t.branch_id = ret.branch_id AND t.deleted_at IS NULL;
  IF rules.id IS NULL THEN
    INSERT INTO public.purchase_return_tax_setting (economic_group_id, branch_id) VALUES (ret.economic_group_id, ret.branch_id)
    RETURNING * INTO rules;
  END IF;
  interstate := supplier.state::text <> branch_row.state::text;
  simples := company_row.tax_regime IN (1, 4);

  FOR line IN
    SELECT ri.*, it.item_number, it.description, it.barcode, it.ncm, it.cest, it.unit AS invoice_unit, it.quantity AS item_quantity,
           it.st_value AS item_st, it.fcp_st_value AS item_fcp_st, p.code AS product_code
      FROM public.purchase_return_item ri
      JOIN public.purchase_invoice_item it ON it.id = ri.invoice_item_id
      JOIN public.product p ON p.id = ri.product_id
     WHERE ri.return_id = ret.id AND ri.deleted_at IS NULL
     ORDER BY it.item_number, ri.id
  LOOP
    IF line.ncm IS NULL THEN
      RAISE EXCEPTION 'Um item da devolução está sem NCM na nota de compra.'
        USING ERRCODE = 'FA774', DETAIL = pg_catalog.format('Item %s da nota %s.', line.item_number, invoice.id);
    END IF;
    st := line.item_st > 0 OR line.item_fcp_st > 0;
    icms := app.purchase_item_icms(invoice, line.item_number);
    tax := pg_catalog.jsonb_build_object(
      'cfop', CASE WHEN interstate THEN CASE WHEN st THEN rules.cfop_st_interstate ELSE rules.cfop_interstate END
                   ELSE CASE WHEN st THEN rules.cfop_st_internal ELSE rules.cfop_internal END END,
      'origin', COALESCE((icms ->> 'orig')::integer, 0),
      'pis_cst', rules.pis_cst, 'pis_rate', 0,
      'cofins_cst', rules.cofins_cst, 'cofins_rate', 0
    );
    IF simples THEN
      tax := tax || pg_catalog.jsonb_build_object('icms_csosn', CASE WHEN st THEN rules.simples_csosn_st ELSE rules.simples_csosn END);
    ELSE
      tax := tax || pg_catalog.jsonb_build_object('icms_cst', CASE WHEN st THEN rules.normal_cst_st ELSE rules.normal_cst END);
      IF icms ? 'pICMS' THEN
        tax := tax || pg_catalog.jsonb_build_object('icms_rate', (icms ->> 'pICMS')::numeric);
      END IF;
    END IF;
    items := items || pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
      'code', line.product_code::text,
      'gtin', line.barcode,
      'description', line.description,
      'ncm', line.ncm,
      'cest', line.cest,
      'unit', line.invoice_unit,
      'quantityMilli', pg_catalog.round(line.invoice_quantity * 1000)::bigint,
      'unitPriceCents', pg_catalog.round(line.unit_price * 100)::bigint,
      'grossCents', pg_catalog.round(line.products_value * 100)::bigint,
      'discountCents', pg_catalog.round(line.discount_value * 100)::bigint,
      'freightCents', pg_catalog.round(line.freight_value * 100)::bigint,
      'insuranceCents', pg_catalog.round(line.insurance_value * 100)::bigint,
      -- ICMS-ST e FCP-ST devolvidos vão em outras despesas (a confirmar com o contador).
      'otherCents', pg_catalog.round((line.other_value + line.st_value + line.fcp_st_value) * 100)::bigint,
      'ipiReturnedCents', pg_catalog.round(line.ipi_value * 100)::bigint,
      'returnPercent', LEAST(pg_catalog.round(line.invoice_quantity / NULLIF(line.item_quantity, 0) * 100, 2), 100),
      'tax', tax
    ));
  END LOOP;

  numbering := app.lock_central_nfe_series(ret.economic_group_id, ret.branch_id);
  UPDATE public.central_nfe_series SET last_used_number = last_used_number + 1 WHERE id = numbering.id
  RETURNING * INTO numbering;

  SELECT bc.encrypted_pfx, bc.encrypted_password INTO certificate
    FROM public.branch_certificate bc WHERE bc.branch_id = ret.branch_id AND bc.deleted_at IS NULL;

  RETURN pg_catalog.jsonb_build_object(
    'returnId', ret.id,
    'branchId', ret.branch_id,
    'companyId', branch_row.company_id,
    'state', branch_row.state,
    'series', numbering.series,
    'number', numbering.last_used_number,
    'totalValue', ret.total_value,
    'hasCertificate', certificate.encrypted_pfx IS NOT NULL,
    'input', pg_catalog.jsonb_build_object(
      'issuer', pg_catalog.jsonb_build_object(
        'cnpj', branch_row.cnpj, 'stateRegistration', branch_row.state_registration, 'legalName', company_row.legal_name,
        'tradeName', company_row.trade_name, 'street', branch_row.street, 'number', branch_row.street_number,
        'complement', branch_row.complement, 'district', branch_row.district, 'cityCode', branch_row.city_code,
        'city', branch_row.city, 'uf', branch_row.state, 'postalCode', branch_row.postal_code, 'phone', branch_row.phone,
        'taxRegime', company_row.tax_regime
      ),
      'recipient', pg_catalog.jsonb_build_object(
        'cnpj', supplier.cnpj, 'name', supplier.legal_name,
        'ieIndicator', CASE WHEN supplier.state_registration IS NULL THEN 9 ELSE 1 END,
        'stateRegistration', supplier.state_registration, 'street', supplier.street, 'number', supplier.street_number,
        'complement', supplier.complement, 'district', supplier.district, 'cityCode', supplier.city_code, 'city', supplier.city,
        'uf', supplier.state, 'postalCode', supplier.postal_code, 'phone', supplier.phone, 'email', supplier.email
      ),
      'items', items,
      'series', numbering.series,
      'number', numbering.last_used_number,
      'operation', 'DEVOLUCAO DE COMPRA',
      'purpose', 4,
      'presence', 0,
      'finalConsumer', false,
      'references', pg_catalog.jsonb_build_array(invoice.access_key),
      'additionalInfo', pg_catalog.format(
        'Devolução %s da NF-e %s série %s de %s. Motivo: %s. ICMS-ST e FCP-ST devolvidos informados em outras despesas.',
        ret.number, invoice.number, invoice.series, invoice.emitter_name, ret.reason)
    )
  );
END;
$$;

-- Certificado da filial, cifrado (a API abre com a chave dela). Só para quem prepara a nota.
CREATE FUNCTION app.return_nfe_certificate(p_return_id uuid) RETURNS TABLE (company_id uuid, encrypted_pfx bytea, encrypted_password bytea)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  ret public.purchase_return;
BEGIN
  SELECT * INTO ret FROM public.purchase_return r
   WHERE r.id = p_return_id AND r.economic_group_id = app.current_user_group() AND r.deleted_at IS NULL;
  IF ret.id IS NULL THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.' USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('purchase_return %s.', p_return_id);
  END IF;
  PERFORM app.require_purchase_permission('fiscal.nfe_issue', ret.branch_id);
  RETURN QUERY
    SELECT b.company_id, bc.encrypted_pfx, bc.encrypted_password
      FROM public.branch b
      LEFT JOIN public.branch_certificate bc ON bc.branch_id = b.id AND bc.deleted_at IS NULL
     WHERE b.id = ret.branch_id;
END;
$$;

-- Guarda a nota assinada (pendente) com o número reservado. Mesma transação do preparo.
CREATE FUNCTION app.return_nfe_store(
  p_return_id uuid, p_series integer, p_number bigint, p_access_key text, p_environment smallint, p_xml text,
  p_emitted_at timestamptz, p_total numeric
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  ret public.purchase_return;
  new_id uuid;
BEGIN
  SELECT * INTO ret FROM public.purchase_return r
   WHERE r.id = p_return_id AND r.economic_group_id = app.current_user_group() AND r.deleted_at IS NULL;
  IF ret.id IS NULL THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.' USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('purchase_return %s.', p_return_id);
  END IF;
  PERFORM app.require_purchase_permission('fiscal.nfe_issue', ret.branch_id);
  IF NOT EXISTS (
    SELECT 1 FROM public.central_nfe_series s
     WHERE s.branch_id = ret.branch_id AND s.series = p_series AND s.last_used_number = p_number AND s.deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Os dados da nota são inválidos.' USING ERRCODE = 'FA931', DETAIL = 'Número fora da reserva.';
  END IF;
  INSERT INTO public.central_nfe (
    economic_group_id, branch_id, kind, purchase_return_id, series, number, access_key, environment, status, xml,
    total_value, emitted_at, user_id
  ) VALUES (
    ret.economic_group_id, ret.branch_id, 'supplier_return', ret.id, p_series, p_number, p_access_key, p_environment, 'pending',
    p_xml, p_total, p_emitted_at, app.current_user_id()
  ) RETURNING id INTO new_id;
  RETURN new_id;
END;
$$;

-- Nota pendente da devolução, para transmitir (de novo) o mesmo XML.
CREATE FUNCTION app.return_nfe_pending(p_return_id uuid) RETURNS TABLE (id uuid, access_key text, environment smallint, xml text, state text)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  ret public.purchase_return;
BEGIN
  SELECT * INTO ret FROM public.purchase_return r
   WHERE r.id = p_return_id AND r.economic_group_id = app.current_user_group() AND r.deleted_at IS NULL;
  IF ret.id IS NULL THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.' USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('purchase_return %s.', p_return_id);
  END IF;
  PERFORM app.require_purchase_permission('fiscal.nfe_issue', ret.branch_id);
  RETURN QUERY
    SELECT n.id, n.access_key, n.environment, n.xml, b.state::text
      FROM public.central_nfe n JOIN public.branch b ON b.id = n.branch_id
     WHERE n.purchase_return_id = ret.id AND n.status = 'pending' AND n.deleted_at IS NULL;
END;
$$;

-- Resposta da Sefaz: authorized (protocolo, data e o XML com o protocolo), rejected (código e motivo)
-- ou unavailable (sem resposta: continua pendente).
CREATE FUNCTION app.central_nfe_result(p_id uuid, p_result jsonb) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  doc public.central_nfe;
  kind text := p_result ->> 'kind';
BEGIN
  SELECT * INTO doc FROM public.central_nfe n
   WHERE n.id = p_id AND n.economic_group_id = app.current_user_group() AND n.deleted_at IS NULL
   FOR UPDATE;
  IF doc.id IS NULL THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.' USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('central_nfe %s.', p_id);
  END IF;
  PERFORM app.require_purchase_permission('fiscal.nfe_issue', doc.branch_id);
  IF doc.status <> 'pending' THEN
    RETURN doc.status;
  END IF;
  CASE kind
    WHEN 'authorized' THEN
      UPDATE public.central_nfe
         SET status = 'authorized', protocol = p_result ->> 'protocol', authorized_at = (p_result ->> 'authorized_at')::timestamptz,
             xml = p_result ->> 'xml', status_code = p_result ->> 'status_code', reason = pg_catalog.left(p_result ->> 'reason', 500)
       WHERE id = doc.id;
    WHEN 'rejected' THEN
      UPDATE public.central_nfe
         SET status = 'rejected', status_code = p_result ->> 'status_code', reason = pg_catalog.left(p_result ->> 'reason', 500)
       WHERE id = doc.id;
    WHEN 'unavailable' THEN
      UPDATE public.central_nfe SET reason = pg_catalog.left(p_result ->> 'reason', 500) WHERE id = doc.id;
    ELSE
      RAISE EXCEPTION 'Os dados da nota são inválidos.' USING ERRCODE = 'FA931', DETAIL = pg_catalog.format('Resultado %s.', kind);
  END CASE;
  RETURN (SELECT n.status FROM public.central_nfe n WHERE n.id = doc.id);
END;
$$;

-- NF-e das devoluções da nota de compra, para a tela.
CREATE FUNCTION app.purchase_invoice_return_nfes(p_invoice_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
           'id', n.id, 'return_id', n.purchase_return_id, 'series', n.series, 'number', n.number, 'access_key', n.access_key,
           'status', n.status, 'protocol', n.protocol, 'status_code', n.status_code, 'reason', n.reason,
           'total_value', n.total_value, 'emitted_at', n.emitted_at, 'authorized_at', n.authorized_at)
           ORDER BY n.created_at, n.id), '[]'::jsonb)
    FROM public.central_nfe n
    JOIN public.purchase_return r ON r.id = n.purchase_return_id
    JOIN public.purchase_invoice i ON i.id = r.invoice_id
   WHERE r.invoice_id = p_invoice_id AND n.deleted_at IS NULL AND i.economic_group_id = app.current_user_group()
     AND app.has_permission('purchases.view', i.branch_id)
$$;

-- XML da NF-e para baixar (e montar o DANFE).
CREATE FUNCTION app.central_nfe_xml(p_id uuid) RETURNS TABLE (access_key text, status text, xml text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT n.access_key, n.status, n.xml FROM public.central_nfe n
   WHERE n.id = p_id AND n.deleted_at IS NULL AND n.economic_group_id = app.current_user_group()
     AND app.has_permission('purchases.view', n.branch_id)
$$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  app.return_nfe_prepare(uuid),
  app.return_nfe_certificate(uuid),
  app.return_nfe_store(uuid, integer, bigint, text, smallint, text, timestamptz, numeric),
  app.return_nfe_pending(uuid),
  app.central_nfe_result(uuid, jsonb),
  app.purchase_invoice_return_nfes(uuid),
  app.central_nfe_xml(uuid)
TO farmaerp_app;
