-- Up Migration

-- NFC-e emitida no caixa (8A-2b): o PDV transmite direto à Sefaz e manda a nota pela outbox
-- (item "nfce"), depois da venda. A central guarda o XML (autorizado, com o protocolo, ou o
-- assinado quando a nota ficou pendente), a situação e a numeração; a venda passa a mostrar a
-- situação fiscal. Nota autorizada não muda mais; pendente ou em contingência pode ser
-- atualizada pelo caixa (contingência transmitida depois, no 8A-2b2).

ALTER TABLE sale DROP CONSTRAINT sale_fiscal_status_check;
ALTER TABLE sale ADD CONSTRAINT sale_fiscal_status_check
  CHECK (fiscal_status IN ('pending', 'authorized', 'rejected', 'contingency'));

CREATE TABLE fiscal_document (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  branch_id uuid NOT NULL REFERENCES branch (id),
  terminal_id uuid NOT NULL REFERENCES terminal (id),
  sale_id uuid NOT NULL REFERENCES sale (id),
  model text NOT NULL CONSTRAINT fiscal_document_model_check CHECK (model = '65'),
  series integer NOT NULL CONSTRAINT fiscal_document_series_check CHECK (series BETWEEN 1 AND 999),
  number bigint NOT NULL CONSTRAINT fiscal_document_number_check CHECK (number BETWEEN 1 AND 999999999),
  access_key text NOT NULL CONSTRAINT fiscal_document_access_key_check CHECK (access_key ~ '^[0-9]{44}$'),
  environment smallint NOT NULL CONSTRAINT fiscal_document_environment_check CHECK (environment IN (1, 2)),
  emission_type smallint NOT NULL CONSTRAINT fiscal_document_emission_type_check CHECK (emission_type IN (1, 9)),
  status text NOT NULL CONSTRAINT fiscal_document_status_check CHECK (status IN ('authorized', 'rejected', 'pending', 'contingency')),
  protocol text CONSTRAINT fiscal_document_protocol_check CHECK (protocol ~ '^[0-9]{15}$'),
  status_code text CONSTRAINT fiscal_document_status_code_check CHECK (status_code ~ '^[0-9]{3}$'),
  reason text CONSTRAINT fiscal_document_reason_check CHECK (length(reason) <= 500),
  xml text NOT NULL CONSTRAINT fiscal_document_xml_check CHECK (length(xml) BETWEEN 100 AND 500000),
  emitted_at timestamptz NOT NULL,
  authorized_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid,
  CONSTRAINT fiscal_document_authorized_check CHECK (
    (status = 'authorized') = (protocol IS NOT NULL AND authorized_at IS NOT NULL)
  )
);
CREATE UNIQUE INDEX fiscal_document_sale_key ON fiscal_document (sale_id) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX fiscal_document_access_key_key ON fiscal_document (access_key) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX fiscal_document_number_key ON fiscal_document (branch_id, model, series, number) WHERE deleted_at IS NULL;
CREATE INDEX fiscal_document_terminal_idx ON fiscal_document (terminal_id);
CREATE INDEX fiscal_document_economic_group_id_idx ON fiscal_document (economic_group_id);
CREATE INDEX fiscal_document_status_idx ON fiscal_document (branch_id, status) WHERE status <> 'authorized' AND deleted_at IS NULL;
CALL app.apply_table_standard('public.fiscal_document');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON fiscal_document
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'branch_id', 'terminal_id', 'sale_id', 'model', 'series', 'number', 'access_key', 'environment',
    'emitted_at', 'deleted_at'
  );
CREATE POLICY fiscal_document_select ON fiscal_document FOR SELECT TO farmaerp_app
  USING (branch_id = ANY (app.allowed_branch_ids()) AND app.has_permission('sales.view', branch_id));
CREATE VIEW v_fiscal_document WITH (security_invoker = true) AS
  SELECT id, economic_group_id, branch_id, terminal_id, sale_id, model, series, number, access_key, environment,
         emission_type, status, protocol, status_code, reason, emitted_at, authorized_at,
         created_at, updated_at, deleted_at, version, updated_by, trace_id
    FROM fiscal_document WHERE deleted_at IS NULL;
GRANT SELECT ON fiscal_document, v_fiscal_document TO farmaerp_app;

-- Nota autorizada não volta atrás; os outros estados podem andar.
CREATE FUNCTION app.guard_fiscal_document() RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF OLD.status = 'authorized' AND (NEW.status <> 'authorized' OR NEW.xml IS DISTINCT FROM OLD.xml
                                    OR NEW.protocol IS DISTINCT FROM OLD.protocol) THEN
    RAISE EXCEPTION 'A NFC-e recebida do caixa é inválida.'
      USING ERRCODE = 'FA735', DETAIL = 'Nota autorizada não muda.';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER guard_fiscal_document BEFORE UPDATE ON fiscal_document
  FOR EACH ROW EXECUTE FUNCTION app.guard_fiscal_document();

-- A venda mostra a situação da nota; a série do terminal anda com o número usado.
CREATE FUNCTION app.track_fiscal_document() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  UPDATE public.sale s SET fiscal_status = NEW.status WHERE s.id = NEW.sale_id AND s.fiscal_status IS DISTINCT FROM NEW.status;
  UPDATE public.terminal_fiscal_series fs SET last_used_number = NEW.number
   WHERE fs.terminal_id = NEW.terminal_id AND fs.model = NEW.model AND fs.series = NEW.series AND fs.deleted_at IS NULL
     AND (fs.last_used_number IS NULL OR fs.last_used_number < NEW.number);
  RETURN NULL;
END;
$$;
CREATE TRIGGER track_fiscal_document AFTER INSERT OR UPDATE ON fiscal_document
  FOR EACH ROW EXECUTE FUNCTION app.track_fiscal_document();

-- Item "nfce" da outbox. A venda precisa ter chegado antes (mesma ordem da outbox) e ser deste
-- terminal; a série é a do terminal para o modelo 65. Repetido pelo mesmo id atualiza a situação.
CREATE FUNCTION app.sync_apply_nfce(p_terminal public.terminal, p_group_id uuid, p_payload jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  doc_id uuid;
  target_sale public.sale;
  doc_series integer;
BEGIN
  BEGIN
    doc_id := (p_payload ->> 'id')::uuid;
    doc_series := (p_payload ->> 'series')::integer;
  EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
    RAISE EXCEPTION 'A NFC-e recebida do caixa é inválida.' USING ERRCODE = 'FA735', DETAIL = 'Id ou série fora do formato.';
  END;
  SELECT s.* INTO target_sale FROM public.sale s
   WHERE s.id = (p_payload ->> 'sale_id')::uuid AND s.terminal_id = p_terminal.id AND s.deleted_at IS NULL;
  IF target_sale.id IS NULL THEN
    RAISE EXCEPTION 'A NFC-e recebida do caixa é inválida.' USING ERRCODE = 'FA735', DETAIL = 'Venda não encontrada neste terminal.';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.terminal_fiscal_series fs
     WHERE fs.terminal_id = p_terminal.id AND fs.model = '65' AND fs.series = doc_series AND fs.deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'A NFC-e recebida do caixa é inválida.' USING ERRCODE = 'FA735', DETAIL = 'Série que não é a do terminal.';
  END IF;
  BEGIN
    INSERT INTO public.fiscal_document AS d (
      id, economic_group_id, branch_id, terminal_id, sale_id, model, series, number, access_key, environment,
      emission_type, status, protocol, status_code, reason, xml, emitted_at, authorized_at
    ) VALUES (
      doc_id, p_group_id, p_terminal.branch_id, p_terminal.id, target_sale.id, '65', doc_series,
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

-- Situação da nota de uma venda, para a tela da venda (sem o XML).
CREATE FUNCTION app.sale_fiscal_document(p_sale_id uuid) RETURNS jsonb
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT pg_catalog.jsonb_build_object(
    'id', d.id, 'series', d.series, 'number', d.number, 'access_key', d.access_key, 'environment', d.environment,
    'emission_type', d.emission_type, 'status', d.status, 'protocol', d.protocol, 'status_code', d.status_code,
    'reason', d.reason, 'emitted_at', d.emitted_at, 'authorized_at', d.authorized_at)
    FROM public.v_fiscal_document d WHERE d.sale_id = p_sale_id
$$;

-- XML da nota, para baixar na retaguarda (a RLS da tabela decide quem vê).
CREATE FUNCTION app.sale_fiscal_xml(p_sale_id uuid) RETURNS jsonb
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT pg_catalog.jsonb_build_object('access_key', d.access_key, 'status', d.status, 'xml', d.xml)
    FROM public.fiscal_document d WHERE d.sale_id = p_sale_id AND d.deleted_at IS NULL
$$;

-- Subida: a nota do caixa entra como o tipo "nfce".
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
    WHEN 'health_professional' THEN
      PERFORM app.sync_apply_health_professional(p_group_id, p_payload);
    WHEN 'nfce' THEN
      PERFORM app.sync_apply_nfce(p_terminal, p_group_id, p_payload);
    ELSE
      RAISE EXCEPTION 'O terminal enviou um tipo de registro desconhecido.'
        USING ERRCODE = 'FA959', DETAIL = pg_catalog.format('Tipo %s.', p_kind);
  END CASE;
END;
$$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  app.sale_fiscal_document(uuid),
  app.sale_fiscal_xml(uuid)
TO farmaerp_app;
