-- Up Migration

-- Cancelamento da NF-e 55, segunda parte:
-- * no caixa: a NF-e de venda se cancela como a NFC-e (última venda, supervisor, a venda junto),
--   no prazo da NF-e (24 horas);
-- * na central: a NF-e de devolução ao fornecedor e a de transferência se cancelam até 24 horas.
--   Cancela só a nota: a devolução, a transferência e o estoque ficam como estão, e a operação pode
--   ganhar uma NF-e nova.

-- ===== Caixa =====
DROP FUNCTION app.terminal_cancel_context(uuid, uuid);
CREATE FUNCTION app.terminal_cancel_context(p_document_id uuid, p_supervisor_id uuid) RETURNS TABLE (
  id uuid, economic_group_id uuid, branch_id uuid, company_id uuid, sale_id uuid, status text, access_key text, environment smallint,
  series integer, number bigint, protocol text, xml text, authorized_at timestamptz, cnpj text, state text,
  encrypted_pfx bytea, encrypted_password bytea, model text, emission_type smallint
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
  IF v_doc.status <> 'canceled' THEN
    IF v_doc.status <> 'authorized' THEN
      IF v_doc.model = '55' THEN
        RAISE EXCEPTION 'Esta NF-e não está numa situação que permita a operação.' USING ERRCODE = 'FA787', DETAIL = v_doc.status;
      END IF;
      RAISE EXCEPTION 'Esta NFC-e não está numa situação que permita a operação.' USING ERRCODE = 'FA753', DETAIL = v_doc.status;
    END IF;
    IF v_doc.authorized_at < pg_catalog.now() - app.fiscal_cancel_window(v_doc.model) THEN
      IF v_doc.model = '55' THEN
        RAISE EXCEPTION 'O prazo para cancelar esta NF-e já passou.' USING ERRCODE = 'FA786', DETAIL = v_doc.authorized_at::text;
      END IF;
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
           bc.encrypted_pfx, bc.encrypted_password, v_doc.model, v_doc.emission_type
      FROM public.branch b
      LEFT JOIN public.branch_certificate bc ON bc.branch_id = b.id AND bc.deleted_at IS NULL
     WHERE b.id = v_doc.branch_id;
END;
$$;

-- Registro pedido pelo caixa: a venda é desfeita no prazo do modelo, com 5 minutos de folga.
CREATE OR REPLACE FUNCTION app.terminal_cancel_register(p_document_id uuid, p_supervisor_id uuid, p_event jsonb) RETURNS jsonb
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
  IF v_doc.status = 'canceled' THEN
    RETURN pg_catalog.jsonb_build_object('already', true);
  END IF;
  INSERT INTO public.fiscal_event (economic_group_id, fiscal_document_id, kind, reason, protocol, status_code, xml, registered_at, requested_by, terminal_id)
  VALUES (v_doc.economic_group_id, v_doc.id, 'cancellation', pg_catalog.btrim(p_event ->> 'reason'), p_event ->> 'protocol',
          p_event ->> 'status_code', p_event ->> 'xml', (p_event ->> 'registered_at')::timestamptz, p_supervisor_id, v_terminal.id);
  UPDATE public.fiscal_document d SET status = 'canceled' WHERE d.id = v_doc.id;
  SELECT * INTO v_sale FROM public.sale s WHERE s.id = v_doc.sale_id AND s.deleted_at IS NULL FOR UPDATE;
  IF v_sale.id IS NULL THEN
    RETURN '{}'::jsonb;
  END IF;
  v_blocker := app.sale_cancel_blocker(v_sale);
  IF v_blocker IS NULL AND v_doc.authorized_at < pg_catalog.now() - app.fiscal_cancel_window(v_doc.model) - interval '5 minutes' THEN
    v_blocker := CASE v_doc.model WHEN '55' THEN 'FA786' ELSE 'FA748' END;
  END IF;
  IF v_blocker IS NOT NULL THEN
    UPDATE public.fiscal_document d
       SET cancel_note = 'Nota cancelada na Sefaz, mas a venda não foi desfeita (' || v_blocker || '): acerte pela devolução.',
           alert_dismissed_at = NULL
     WHERE d.id = v_doc.id;
    RETURN pg_catalog.jsonb_build_object('sale_kept', v_blocker);
  END IF;
  RETURN app.cancel_sale_effects(v_sale, p_supervisor_id, p_event ->> 'reason');
END;
$$;

REVOKE ALL ON FUNCTION app.terminal_cancel_context(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.terminal_cancel_context(uuid, uuid) TO farmaerp_app;

-- ===== Central =====
ALTER TABLE central_nfe
  ADD COLUMN cancel_reason text CONSTRAINT central_nfe_cancel_reason_check CHECK (length(btrim(cancel_reason)) BETWEEN 15 AND 255),
  ADD COLUMN cancel_protocol text CONSTRAINT central_nfe_cancel_protocol_check CHECK (cancel_protocol ~ '^[0-9]{15}$'),
  ADD COLUMN cancel_xml text CONSTRAINT central_nfe_cancel_xml_check CHECK (length(cancel_xml) BETWEEN 100 AND 200000),
  ADD COLUMN canceled_at timestamptz,
  ADD COLUMN canceled_by uuid REFERENCES user_account (id);
CREATE INDEX central_nfe_canceled_by_idx ON central_nfe (canceled_by);
ALTER TABLE central_nfe DROP CONSTRAINT central_nfe_status_check;
ALTER TABLE central_nfe ADD CONSTRAINT central_nfe_status_check CHECK (status IN ('pending', 'authorized', 'rejected', 'canceled'));
-- A cancelada continua com o protocolo da autorização.
ALTER TABLE central_nfe DROP CONSTRAINT central_nfe_authorized_check;
ALTER TABLE central_nfe ADD CONSTRAINT central_nfe_authorized_check
  CHECK ((status IN ('authorized', 'canceled')) = (protocol IS NOT NULL AND authorized_at IS NOT NULL));
ALTER TABLE central_nfe ADD CONSTRAINT central_nfe_canceled_check CHECK (
  (status = 'canceled') = (cancel_reason IS NOT NULL AND cancel_protocol IS NOT NULL AND cancel_xml IS NOT NULL
                           AND canceled_at IS NOT NULL AND canceled_by IS NOT NULL)
);

-- A operação tem no máximo uma nota viva (pendente ou autorizada): recusadas e canceladas ficam no
-- histórico e liberam uma nova.
DROP INDEX central_nfe_return_live_key;
CREATE UNIQUE INDEX central_nfe_return_live_key ON central_nfe (purchase_return_id)
  WHERE deleted_at IS NULL AND status IN ('pending', 'authorized');
DROP INDEX central_nfe_transfer_live_key;
CREATE UNIQUE INDEX central_nfe_transfer_live_key ON central_nfe (transfer_group)
  WHERE deleted_at IS NULL AND status IN ('pending', 'authorized');

CREATE OR REPLACE FUNCTION app.guard_central_nfe() RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  -- Com resposta da Sefaz não muda mais; a única passagem é da autorizada para a cancelada, com o
  -- mesmo XML.
  IF OLD.status IN ('authorized', 'rejected', 'canceled') AND (NEW.status IS DISTINCT FROM OLD.status OR NEW.xml IS DISTINCT FROM OLD.xml)
     AND NOT (OLD.status = 'authorized' AND NEW.status = 'canceled' AND NEW.xml IS NOT DISTINCT FROM OLD.xml) THEN
    RAISE EXCEPTION 'Esta NF-e já teve resposta da Sefaz e não muda mais.'
      USING ERRCODE = 'FA772', DETAIL = pg_catalog.format('central_nfe %s em %s.', OLD.id, OLD.status);
  END IF;
  -- Os dados do cancelamento só se gravam nessa passagem.
  IF (NEW.cancel_reason, NEW.cancel_protocol, NEW.cancel_xml, NEW.canceled_at, NEW.canceled_by)
       IS DISTINCT FROM (OLD.cancel_reason, OLD.cancel_protocol, OLD.cancel_xml, OLD.canceled_at, OLD.canceled_by)
     AND NOT (OLD.status = 'authorized' AND NEW.status = 'canceled') THEN
    RAISE EXCEPTION 'Esta NF-e já teve resposta da Sefaz e não muda mais.'
      USING ERRCODE = 'FA772', DETAIL = pg_catalog.format('central_nfe %s: cancelamento.', OLD.id);
  END IF;
  -- Chave e forma de emissão só mudam uma vez: da normal para a SVC (a nota ainda pendente, pela
  -- trava de cima, que barra a mudança do XML depois da resposta).
  IF (NEW.access_key IS DISTINCT FROM OLD.access_key OR NEW.emission_type IS DISTINCT FROM OLD.emission_type)
     AND NOT (OLD.status = 'pending' AND OLD.emission_type = 1 AND NEW.emission_type IN (6, 7)) THEN
    RAISE EXCEPTION 'Esta NF-e já teve resposta da Sefaz e não muda mais.'
      USING ERRCODE = 'FA772', DETAIL = pg_catalog.format('central_nfe %s: chave ou forma de emissão.', OLD.id);
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE VIEW v_central_nfe WITH (security_invoker = true) AS
  SELECT id, economic_group_id, branch_id, kind, purchase_return_id, series, number, access_key, environment, status, protocol,
         status_code, reason, total_value, emitted_at, authorized_at, user_id, created_at, updated_at, deleted_at, version,
         updated_by, trace_id, transfer_group, emission_type, cancel_reason, cancel_protocol, canceled_at, canceled_by
    FROM central_nfe WHERE deleted_at IS NULL;

-- A nota que vai ser cancelada: quem emite NF-e na filial, a autorizada dentro de 24 horas (a já
-- cancelada volta como está, para o pedido repetido responder que está feito). Com o certificado da
-- filial, para assinar o evento.
CREATE FUNCTION app.central_nfe_cancel_context(p_id uuid) RETURNS TABLE (
  id uuid, company_id uuid, status text, access_key text, environment smallint, protocol text, cnpj text, state text,
  encrypted_pfx bytea, encrypted_password bytea, model text, emission_type smallint
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  note public.central_nfe;
BEGIN
  SELECT * INTO note FROM public.central_nfe n
   WHERE n.id = p_id AND n.deleted_at IS NULL AND n.economic_group_id = app.current_user_group();
  IF note.id IS NULL THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.' USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('central_nfe %s.', p_id);
  END IF;
  IF NOT app.has_permission('fiscal.nfe_issue', note.branch_id) THEN
    RAISE EXCEPTION 'Você não tem permissão para esta operação.'
      USING ERRCODE = 'FA002', DETAIL = pg_catalog.format('fiscal.nfe_issue na filial %s.', note.branch_id);
  END IF;
  IF note.status <> 'canceled' THEN
    IF note.status <> 'authorized' THEN
      RAISE EXCEPTION 'Esta NF-e não está numa situação que permita a operação.' USING ERRCODE = 'FA787', DETAIL = note.status;
    END IF;
    IF note.authorized_at < pg_catalog.now() - app.fiscal_cancel_window('55') THEN
      RAISE EXCEPTION 'O prazo para cancelar esta NF-e já passou.' USING ERRCODE = 'FA786', DETAIL = note.authorized_at::text;
    END IF;
  END IF;
  RETURN QUERY
    SELECT note.id, b.company_id, note.status, note.access_key, note.environment, note.protocol, b.cnpj::text, b.state::text,
           bc.encrypted_pfx, bc.encrypted_password, '55'::text, note.emission_type
      FROM public.branch b
      LEFT JOIN public.branch_certificate bc ON bc.branch_id = b.id AND bc.deleted_at IS NULL
     WHERE b.id = note.branch_id;
END;
$$;

-- Cancelamento registrado na Sefaz: a nota fica cancelada, com o motivo, o protocolo e o XML do
-- evento. A devolução ou a transferência não muda. Repetido: responde que já está cancelada.
CREATE FUNCTION app.central_nfe_cancel_register(p_id uuid, p_event jsonb) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  note public.central_nfe;
BEGIN
  SELECT * INTO note FROM public.central_nfe n
   WHERE n.id = p_id AND n.deleted_at IS NULL AND n.economic_group_id = app.current_user_group()
   FOR UPDATE;
  IF note.id IS NULL THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.' USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('central_nfe %s.', p_id);
  END IF;
  IF NOT app.has_permission('fiscal.nfe_issue', note.branch_id) THEN
    RAISE EXCEPTION 'Você não tem permissão para esta operação.'
      USING ERRCODE = 'FA002', DETAIL = pg_catalog.format('fiscal.nfe_issue na filial %s.', note.branch_id);
  END IF;
  IF note.status = 'canceled' THEN
    RETURN 'canceled';
  END IF;
  IF note.status <> 'authorized' THEN
    RAISE EXCEPTION 'Esta NF-e não está numa situação que permita a operação.' USING ERRCODE = 'FA787', DETAIL = note.status;
  END IF;
  UPDATE public.central_nfe n
     SET status = 'canceled', cancel_reason = pg_catalog.btrim(p_event ->> 'reason'), cancel_protocol = p_event ->> 'protocol',
         cancel_xml = p_event ->> 'xml', canceled_at = (p_event ->> 'registered_at')::timestamptz, canceled_by = app.current_user_id()
   WHERE n.id = note.id;
  RETURN 'canceled';
END;
$$;

-- XML do evento de cancelamento, para baixar: quem vê a nota.
CREATE FUNCTION app.central_nfe_cancel_xml(p_id uuid) RETURNS TABLE (access_key text, xml text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT n.access_key, n.cancel_xml FROM public.central_nfe n
   WHERE n.id = p_id AND n.deleted_at IS NULL AND n.status = 'canceled' AND n.economic_group_id = app.current_user_group()
     AND app.has_permission(CASE n.kind WHEN 'transfer' THEN 'stock.view' ELSE 'purchases.view' END, n.branch_id)
$$;

-- As listas das telas dizem até quando a nota se cancela e, na cancelada, quando e por quê.
CREATE OR REPLACE FUNCTION app.purchase_invoice_return_nfes(p_invoice_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
           'id', n.id, 'return_id', n.purchase_return_id, 'series', n.series, 'number', n.number, 'access_key', n.access_key,
           'status', n.status, 'protocol', n.protocol, 'status_code', n.status_code, 'reason', n.reason,
           'total_value', n.total_value, 'emitted_at', n.emitted_at, 'authorized_at', n.authorized_at,
           'canceled_at', n.canceled_at, 'cancel_reason', n.cancel_reason,
           'cancelable_until', CASE WHEN n.status = 'authorized' AND n.authorized_at > pg_catalog.now() - app.fiscal_cancel_window('55')
                                    THEN n.authorized_at + app.fiscal_cancel_window('55') END)
           ORDER BY n.created_at, n.id), '[]'::jsonb)
    FROM public.central_nfe n
    JOIN public.purchase_return r ON r.id = n.purchase_return_id
    JOIN public.purchase_invoice i ON i.id = r.invoice_id
   WHERE r.invoice_id = p_invoice_id AND n.deleted_at IS NULL AND i.economic_group_id = app.current_user_group()
     AND app.has_permission('purchases.view', i.branch_id)
$$;

CREATE OR REPLACE FUNCTION app.transfer_nfes(p_transfers uuid[]) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE(pg_catalog.jsonb_object_agg(x.transfer_group, x.doc), '{}'::jsonb)
    FROM (
      SELECT DISTINCT ON (n.transfer_group) n.transfer_group, pg_catalog.jsonb_build_object(
               'id', n.id, 'series', n.series, 'number', n.number, 'access_key', n.access_key, 'status', n.status,
               'status_code', n.status_code, 'reason', n.reason, 'total_value', n.total_value,
               'authorized_at', n.authorized_at, 'can_issue', app.has_permission('fiscal.nfe_issue', n.branch_id),
               'canceled_at', n.canceled_at, 'cancel_reason', n.cancel_reason,
               'cancelable_until', CASE WHEN n.status = 'authorized' AND n.authorized_at > pg_catalog.now() - app.fiscal_cancel_window('55')
                                        THEN n.authorized_at + app.fiscal_cancel_window('55') END) AS doc
        FROM public.central_nfe n
       WHERE n.transfer_group = ANY (p_transfers) AND n.deleted_at IS NULL
         AND n.economic_group_id = app.current_user_group() AND app.has_permission('stock.view', n.branch_id)
       ORDER BY n.transfer_group, n.created_at DESC, n.id DESC
    ) x
$$;

-- O preparo da nota nova aceita a operação com a nota anterior recusada ou cancelada.
CREATE OR REPLACE FUNCTION app.return_nfe_prepare(p_return_id uuid) RETURNS jsonb
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
  IF EXISTS (SELECT 1 FROM public.central_nfe n WHERE n.purchase_return_id = ret.id AND n.status IN ('pending', 'authorized') AND n.deleted_at IS NULL) THEN
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

CREATE OR REPLACE FUNCTION app.transfer_nfe_prepare(p_transfer uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  moved record;
  origin_row public.branch;
  destination_row public.branch;
  company_row public.company;
  destination_company public.company;
  item public.product;
  catalog public.catalog_product;
  rules public.purchase_return_tax_setting;
  numbering public.central_nfe_series;
  sale_tax jsonb;
  st boolean;
  interstate boolean;
  simples boolean;
  cost numeric;
  gtin text;
  tax jsonb;
  gross bigint;
  group_id uuid := app.current_user_group();
BEGIN
  SELECT * INTO moved FROM app.require_transfer_nfe(p_transfer);
  -- Uma emissão de cada vez para a mesma transferência.
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_transfer::text, 84));
  IF EXISTS (SELECT 1 FROM public.central_nfe n WHERE n.transfer_group = p_transfer AND n.status IN ('pending', 'authorized') AND n.deleted_at IS NULL) THEN
    RAISE EXCEPTION 'Esta transferência já tem NF-e emitida ou em transmissão.'
      USING ERRCODE = 'FA776', DETAIL = pg_catalog.format('transfer %s.', p_transfer);
  END IF;
  SELECT * INTO origin_row FROM public.branch b WHERE b.id = moved.origin;
  SELECT * INTO destination_row FROM public.branch b WHERE b.id = moved.destination;
  SELECT * INTO company_row FROM public.company c WHERE c.id = origin_row.company_id;
  SELECT * INTO destination_company FROM public.company c WHERE c.id = destination_row.company_id;
  -- Transferência fiscal é entre estabelecimentos da mesma empresa (mesma raiz do CNPJ).
  IF pg_catalog.left(origin_row.cnpj, 8) <> pg_catalog.left(destination_row.cnpj, 8) THEN
    RAISE EXCEPTION 'A transferência entre empresas diferentes não tem NF-e de transferência.'
      USING ERRCODE = 'FA777', DETAIL = pg_catalog.format('Origem %s, destino %s.', origin_row.id, destination_row.id);
  END IF;
  IF origin_row.state_registration IS NULL OR origin_row.street IS NULL OR origin_row.street_number IS NULL
     OR origin_row.district IS NULL OR origin_row.city IS NULL OR origin_row.city_code IS NULL OR origin_row.state IS NULL
     OR origin_row.postal_code IS NULL OR company_row.tax_regime IS NULL THEN
    RAISE EXCEPTION 'A filial está sem os dados fiscais completos.'
      USING ERRCODE = 'FA724', DETAIL = pg_catalog.format('branch %s (origem).', origin_row.id);
  END IF;
  IF destination_row.state_registration IS NULL OR destination_row.street IS NULL OR destination_row.street_number IS NULL
     OR destination_row.district IS NULL OR destination_row.city IS NULL OR destination_row.city_code IS NULL
     OR destination_row.state IS NULL OR destination_row.postal_code IS NULL THEN
    RAISE EXCEPTION 'A filial está sem os dados fiscais completos.'
      USING ERRCODE = 'FA724', DETAIL = pg_catalog.format('branch %s (destino).', destination_row.id);
  END IF;

  SELECT * INTO item FROM public.product p WHERE p.id = moved.product_id;
  SELECT * INTO catalog FROM public.catalog_product cp WHERE cp.id = item.catalog_product_id;
  IF COALESCE(catalog.ncm, item.own_ncm) IS NULL THEN
    RAISE EXCEPTION 'O produto da transferência está sem NCM.'
      USING ERRCODE = 'FA779', DETAIL = pg_catalog.format('product %s.', item.id);
  END IF;
  cost := app.average_cost(item.id, origin_row.id);
  IF cost IS NULL OR cost <= 0 THEN
    RAISE EXCEPTION 'O produto não tem custo médio na filial de origem.'
      USING ERRCODE = 'FA778', DETAIL = pg_catalog.format('product %s, branch %s.', item.id, origin_row.id);
  END IF;
  gross := pg_catalog.round(moved.quantity * cost * 100)::bigint;

  SELECT * INTO rules FROM public.purchase_return_tax_setting t WHERE t.branch_id = origin_row.id AND t.deleted_at IS NULL;
  IF rules.id IS NULL THEN
    INSERT INTO public.purchase_return_tax_setting (economic_group_id, branch_id) VALUES (group_id, origin_row.id)
    RETURNING * INTO rules;
  END IF;
  sale_tax := COALESCE(app.product_sale_tax(item.id, origin_row.id), '{}'::jsonb);
  -- ICMS já recolhido por substituição tributária na venda (CSOSN 500 ou CST 10, 30, 60, 70).
  st := sale_tax ->> 'icms_csosn' = '500' OR sale_tax ->> 'icms_cst' IN ('10', '30', '60', '70');
  interstate := origin_row.state::text <> destination_row.state::text;
  simples := company_row.tax_regime IN (1, 4);
  tax := pg_catalog.jsonb_build_object(
    'cfop', CASE WHEN interstate THEN CASE WHEN st THEN rules.transfer_cfop_st_interstate ELSE rules.transfer_cfop_interstate END
                 ELSE CASE WHEN st THEN rules.transfer_cfop_st_internal ELSE rules.transfer_cfop_internal END END,
    'origin', COALESCE((sale_tax ->> 'origin')::integer, 0),
    'pis_cst', rules.pis_cst, 'pis_rate', 0,
    'cofins_cst', rules.cofins_cst, 'cofins_rate', 0
  );
  IF simples THEN
    tax := tax || pg_catalog.jsonb_build_object('icms_csosn', CASE WHEN st THEN rules.simples_csosn_st ELSE rules.simples_csosn END);
  ELSE
    tax := tax || pg_catalog.jsonb_build_object('icms_cst', CASE WHEN st THEN rules.normal_cst_st ELSE rules.normal_cst END);
    IF sale_tax ? 'icms_rate' AND sale_tax ->> 'icms_rate' IS NOT NULL THEN
      tax := tax || pg_catalog.jsonb_build_object('icms_rate', (sale_tax ->> 'icms_rate')::numeric);
    END IF;
  END IF;
  SELECT pb.code INTO gtin FROM public.product_barcode pb
   WHERE pb.product_id = item.id AND pb.deleted_at IS NULL AND NOT pb.is_internal AND app.is_valid_gtin(pb.code)
   ORDER BY pb.is_primary DESC, pb.code LIMIT 1;

  numbering := app.lock_central_nfe_series(group_id, origin_row.id);
  UPDATE public.central_nfe_series SET last_used_number = last_used_number + 1 WHERE id = numbering.id
  RETURNING * INTO numbering;

  RETURN pg_catalog.jsonb_build_object(
    'transferId', p_transfer,
    'branchId', origin_row.id,
    'companyId', origin_row.company_id,
    'state', origin_row.state,
    'series', numbering.series,
    'number', numbering.last_used_number,
    'totalValue', gross / 100.0,
    'input', pg_catalog.jsonb_build_object(
      'issuer', pg_catalog.jsonb_build_object(
        'cnpj', origin_row.cnpj, 'stateRegistration', origin_row.state_registration, 'legalName', company_row.legal_name,
        'tradeName', company_row.trade_name, 'street', origin_row.street, 'number', origin_row.street_number,
        'complement', origin_row.complement, 'district', origin_row.district, 'cityCode', origin_row.city_code,
        'city', origin_row.city, 'uf', origin_row.state, 'postalCode', origin_row.postal_code, 'phone', origin_row.phone,
        'taxRegime', company_row.tax_regime
      ),
      'recipient', pg_catalog.jsonb_build_object(
        'cnpj', destination_row.cnpj, 'name', destination_company.legal_name, 'ieIndicator', 1,
        'stateRegistration', destination_row.state_registration, 'street', destination_row.street,
        'number', destination_row.street_number, 'complement', destination_row.complement, 'district', destination_row.district,
        'cityCode', destination_row.city_code, 'city', destination_row.city, 'uf', destination_row.state,
        'postalCode', destination_row.postal_code, 'phone', destination_row.phone
      ),
      'items', pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
        'code', item.code::text,
        'gtin', gtin,
        'description', COALESCE(catalog.name, item.display_name),
        'ncm', COALESCE(catalog.ncm, item.own_ncm),
        'cest', COALESCE(catalog.cest, item.own_cest),
        'unit', item.unit,
        'quantityMilli', pg_catalog.round(moved.quantity * 1000)::bigint,
        'unitPriceCents', pg_catalog.round(cost * 100)::bigint,
        'grossCents', gross,
        'discountCents', 0,
        'tax', tax
      )),
      'series', numbering.series,
      'number', numbering.last_used_number,
      'operation', 'TRANSFERENCIA DE MERCADORIA',
      'purpose', 1,
      'presence', 0,
      'finalConsumer', false,
      'references', '[]'::jsonb,
      'additionalInfo', pg_catalog.format(
        'Transferência entre filiais: de %s para %s, pelo custo médio da origem. Motivo: %s.',
        origin_row.name, destination_row.name, moved.reason)
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION app.central_nfe_cancel_context(uuid), app.central_nfe_cancel_register(uuid, jsonb),
  app.central_nfe_cancel_xml(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.central_nfe_cancel_context(uuid), app.central_nfe_cancel_register(uuid, jsonb),
  app.central_nfe_cancel_xml(uuid) TO farmaerp_app;
