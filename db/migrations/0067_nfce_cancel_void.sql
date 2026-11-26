-- Up Migration

-- 8A-3a: a central consulta, reenvia, cancela e inutiliza NFC-e na Sefaz da UF.
-- * Consulta pela chave: acerta a nota que chegou na Sefaz mas ficou sem o protocolo no caixa.
-- * Reenvio automático: até 30 notas por grupo por hora, das que passaram da metade do prazo de
--   contingência sem o caixa transmitir. A nota tentada fica marcada; recusada de novo vira
--   aviso e não volta para o lote (só pelo botão). Sefaz fora: tenta na próxima hora.
-- * Cancelamento (evento 110111): só a autorizada, até 30 minutos, e a venda é desfeita junto
--   (estoque, SNGPC, cashback, crediário, convênio, crédito de devolução, caixa e orçamento).
-- * Inutilização: dos buracos de numeração, com confirmação de quem pede.
-- As regras ficam aqui; a API só conversa com a Sefaz.

-- ===== Situações novas da NFC-e, eventos, inutilização e reenvio pela central =====

ALTER TABLE sale DROP CONSTRAINT sale_fiscal_status_check;
ALTER TABLE sale ADD CONSTRAINT sale_fiscal_status_check
  CHECK (fiscal_status IN ('pending', 'authorized', 'rejected', 'contingency', 'canceled'));

ALTER TABLE fiscal_document DROP CONSTRAINT fiscal_document_status_check;
ALTER TABLE fiscal_document ADD CONSTRAINT fiscal_document_status_check
  CHECK (status IN ('authorized', 'rejected', 'pending', 'contingency', 'canceled'));
ALTER TABLE fiscal_document DROP CONSTRAINT fiscal_document_authorized_check;
ALTER TABLE fiscal_document ADD CONSTRAINT fiscal_document_authorized_check CHECK (
  (status IN ('authorized', 'canceled')) = (protocol IS NOT NULL AND authorized_at IS NOT NULL)
);
-- Reenvio pela central: a nota tentada fica marcada (não volta para o lote automático).
-- resend_status: authorized, refused (recusada de novo: vira aviso) ou unavailable (Sefaz fora: tenta na próxima hora).
ALTER TABLE fiscal_document
  ADD COLUMN resend_attempted_at timestamptz,
  ADD COLUMN resend_status text CONSTRAINT fiscal_document_resend_status_check CHECK (resend_status IN ('authorized', 'refused', 'unavailable')),
  ADD COLUMN resend_message text CONSTRAINT fiscal_document_resend_message_check CHECK (length(resend_message) <= 500),
  -- Aviso visto: some do painel de avisos.
  ADD COLUMN alert_dismissed_at timestamptz,
  -- Cancelada na Sefaz sem desfazer a venda (bloqueio ou fora do prazo): aviso para tratar à mão.
  ADD COLUMN cancel_note text CONSTRAINT fiscal_document_cancel_note_check CHECK (length(cancel_note) <= 500);
CREATE INDEX fiscal_document_resend_idx ON fiscal_document (economic_group_id, emitted_at)
  WHERE status IN ('pending', 'contingency') AND deleted_at IS NULL;

-- A nota autorizada só muda para cancelada (pelo evento registrado).
CREATE OR REPLACE FUNCTION app.guard_fiscal_document() RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF OLD.status = 'canceled' AND (NEW.status <> 'canceled' OR NEW.xml IS DISTINCT FROM OLD.xml OR NEW.protocol IS DISTINCT FROM OLD.protocol) THEN
    RAISE EXCEPTION 'A NFC-e recebida do caixa é inválida.'
      USING ERRCODE = 'FA735', DETAIL = 'Nota cancelada não muda.';
  END IF;
  IF OLD.status = 'authorized' AND (NEW.status NOT IN ('authorized', 'canceled') OR NEW.xml IS DISTINCT FROM OLD.xml
                                    OR NEW.protocol IS DISTINCT FROM OLD.protocol) THEN
    RAISE EXCEPTION 'A NFC-e recebida do caixa é inválida.'
      USING ERRCODE = 'FA735', DETAIL = 'Nota autorizada não muda.';
  END IF;
  RETURN NEW;
END;
$$;

-- Eventos da NFC-e registrados na Sefaz (por enquanto, o cancelamento).
CREATE TABLE fiscal_event (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  fiscal_document_id uuid NOT NULL REFERENCES fiscal_document (id),
  kind text NOT NULL CONSTRAINT fiscal_event_kind_check CHECK (kind IN ('cancellation')),
  reason text NOT NULL CONSTRAINT fiscal_event_reason_check CHECK (length(btrim(reason)) BETWEEN 15 AND 255),
  protocol text NOT NULL CONSTRAINT fiscal_event_protocol_check CHECK (protocol ~ '^[0-9]{15}$'),
  status_code text NOT NULL CONSTRAINT fiscal_event_status_code_check CHECK (status_code ~ '^[0-9]{3}$'),
  xml text NOT NULL CONSTRAINT fiscal_event_xml_check CHECK (length(xml) BETWEEN 100 AND 100000),
  registered_at timestamptz NOT NULL,
  -- Quem pediu: usuário da retaguarda ou o terminal (com o supervisor que liberou).
  requested_by uuid REFERENCES user_account (id),
  terminal_id uuid REFERENCES terminal (id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE UNIQUE INDEX fiscal_event_kind_key ON fiscal_event (fiscal_document_id, kind) WHERE deleted_at IS NULL;
CREATE INDEX fiscal_event_economic_group_id_idx ON fiscal_event (economic_group_id);
CALL app.apply_table_standard('public.fiscal_event');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON fiscal_event
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'fiscal_document_id', 'kind', 'reason', 'protocol', 'status_code', 'xml', 'registered_at', 'requested_by', 'terminal_id'
  );
CREATE POLICY fiscal_event_select ON fiscal_event FOR SELECT TO farmaerp_app
  USING (EXISTS (SELECT 1 FROM fiscal_document d WHERE d.id = fiscal_event.fiscal_document_id));
CREATE VIEW v_fiscal_event WITH (security_invoker = true) AS SELECT * FROM fiscal_event WHERE deleted_at IS NULL;
GRANT SELECT ON fiscal_event, v_fiscal_event TO farmaerp_app;

-- Faixas de numeração inutilizadas na Sefaz.
CREATE TABLE fiscal_number_void (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  branch_id uuid NOT NULL REFERENCES branch (id),
  model text NOT NULL CONSTRAINT fiscal_number_void_model_check CHECK (model = '65'),
  series integer NOT NULL CONSTRAINT fiscal_number_void_series_check CHECK (series BETWEEN 1 AND 999),
  first_number bigint NOT NULL CONSTRAINT fiscal_number_void_first_check CHECK (first_number BETWEEN 1 AND 999999999),
  last_number bigint NOT NULL CONSTRAINT fiscal_number_void_last_check CHECK (last_number BETWEEN 1 AND 999999999),
  environment smallint NOT NULL CONSTRAINT fiscal_number_void_environment_check CHECK (environment IN (1, 2)),
  reason text NOT NULL CONSTRAINT fiscal_number_void_reason_check CHECK (length(btrim(reason)) BETWEEN 15 AND 255),
  protocol text NOT NULL CONSTRAINT fiscal_number_void_protocol_check CHECK (protocol ~ '^[0-9]{15}$'),
  xml text NOT NULL CONSTRAINT fiscal_number_void_xml_check CHECK (length(xml) BETWEEN 100 AND 100000),
  voided_at timestamptz NOT NULL,
  requested_by uuid REFERENCES user_account (id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid,
  CONSTRAINT fiscal_number_void_range_check CHECK (last_number >= first_number AND last_number - first_number < 10000)
);
CREATE INDEX fiscal_number_void_branch_idx ON fiscal_number_void (branch_id, model, series, first_number);
CREATE INDEX fiscal_number_void_economic_group_id_idx ON fiscal_number_void (economic_group_id);
CALL app.apply_table_standard('public.fiscal_number_void');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON fiscal_number_void
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'branch_id', 'model', 'series', 'first_number', 'last_number', 'environment', 'reason', 'protocol',
    'xml', 'voided_at', 'requested_by'
  );
CREATE POLICY fiscal_number_void_select ON fiscal_number_void FOR SELECT TO farmaerp_app
  USING (branch_id = ANY (app.allowed_branch_ids()) AND app.has_permission('sales.view', branch_id));
CREATE VIEW v_fiscal_number_void WITH (security_invoker = true) AS SELECT * FROM fiscal_number_void WHERE deleted_at IS NULL;
GRANT SELECT ON fiscal_number_void, v_fiscal_number_void TO farmaerp_app;

INSERT INTO permission (code, module, name) VALUES
  ('fiscal.cancel', 'Fiscal', 'Cancelar NFC-e (e a venda)'),
  ('fiscal.void', 'Fiscal', 'Inutilizar numeração e reenviar NFC-e pela central');

-- Rotina do reenvio (na API, sem usuário).
CREATE FUNCTION app.require_fiscal_worker() RETURNS void
LANGUAGE plpgsql STABLE
SET search_path = ''
AS $$
BEGIN
  IF app.current_user_id() IS NOT NULL OR COALESCE(pg_catalog.current_setting('app.worker', true), '') <> 'fiscal' THEN
    RAISE EXCEPTION 'Você não tem permissão para esta operação.'
      USING ERRCODE = 'FA002', DETAIL = 'Função da rotina fiscal chamada fora dela.';
  END IF;
END;
$$;

-- O caixa retransmitindo uma nota que a central já resolveu (autorizada pelo reenvio, ou
-- cancelada) não muda nada e não trava a fila do caixa.
CREATE OR REPLACE FUNCTION app.sync_apply_nfce(p_terminal public.terminal, p_group_id uuid, p_payload jsonb) RETURNS void
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


-- Dados que a API precisa para falar com a Sefaz sobre uma nota (com o certificado selado).
CREATE FUNCTION app.fiscal_document_context(p_document_id uuid) RETURNS TABLE (
  id uuid, economic_group_id uuid, branch_id uuid, company_id uuid, sale_id uuid, status text, access_key text, environment smallint,
  emission_type smallint, series integer, number bigint, protocol text, xml text, emitted_at timestamptz, cnpj text, state text,
  encrypted_pfx bytea, encrypted_password bytea
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT d.id, d.economic_group_id, d.branch_id, b.company_id, d.sale_id, d.status, d.access_key, d.environment, d.emission_type,
         d.series, d.number, d.protocol, d.xml, d.emitted_at, b.cnpj::text, b.state::text, bc.encrypted_pfx, bc.encrypted_password
    FROM public.fiscal_document d
    JOIN public.branch b ON b.id = d.branch_id
    LEFT JOIN public.branch_certificate bc ON bc.branch_id = d.branch_id AND bc.deleted_at IS NULL
   WHERE d.id = p_document_id AND d.deleted_at IS NULL
$$;

-- Lote do reenvio automático: até 30 notas por grupo, só se o grupo não teve lote na última
-- hora. Nota em contingência ou pendente que passou da metade do prazo da filial e ainda não foi
-- tentada (ou ficou sem Sefaz na tentativa). A nota sai marcada.
CREATE FUNCTION app.claim_fiscal_resend(p_limit integer DEFAULT 30) RETURNS SETOF uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_group uuid;
BEGIN
  PERFORM app.require_fiscal_worker();
  FOR v_group IN
    SELECT DISTINCT d.economic_group_id FROM public.fiscal_document d
     WHERE d.status IN ('pending', 'contingency') AND d.deleted_at IS NULL
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
         WHERE d.economic_group_id = v_group AND d.status IN ('pending', 'contingency') AND d.deleted_at IS NULL
           AND (d.resend_attempted_at IS NULL OR d.resend_status = 'unavailable')
           AND d.emitted_at < pg_catalog.now() - pg_catalog.make_interval(mins => b.nfce_contingency_hours * 30)
         ORDER BY d.emitted_at, d.id
         LIMIT GREATEST(1, LEAST(p_limit, 30))
         FOR UPDATE OF d SKIP LOCKED
      )
      UPDATE public.fiscal_document d SET resend_attempted_at = pg_catalog.now(), resend_status = NULL, resend_message = NULL
        FROM picked WHERE d.id = picked.id
      RETURNING d.id;
  END LOOP;
END;
$$;

-- Resultado da conversa com a Sefaz sobre uma nota (reenvio automático ou pelo botão).
-- p_result: {kind: authorized|rejected|unavailable|canceled, protocol, authorized_at, xml, status_code, reason}.
CREATE FUNCTION app.fiscal_resend_result(p_document_id uuid, p_result jsonb) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_doc public.fiscal_document;
  v_kind text := p_result ->> 'kind';
BEGIN
  SELECT * INTO v_doc FROM public.fiscal_document d WHERE d.id = p_document_id AND d.deleted_at IS NULL FOR UPDATE;
  IF v_doc.id IS NULL THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.' USING ERRCODE = 'FA006', DETAIL = 'fiscal_document.';
  END IF;
  IF v_doc.status IN ('authorized', 'canceled') THEN
    RETURN v_doc.status;
  END IF;
  IF v_kind = 'authorized' THEN
    UPDATE public.fiscal_document d
       SET status = 'authorized', protocol = p_result ->> 'protocol', authorized_at = (p_result ->> 'authorized_at')::timestamptz,
           xml = p_result ->> 'xml', status_code = p_result ->> 'status_code', reason = pg_catalog.left(p_result ->> 'reason', 500),
           resend_attempted_at = COALESCE(d.resend_attempted_at, pg_catalog.now()), resend_status = 'authorized', resend_message = NULL
     WHERE d.id = v_doc.id;
  ELSIF v_kind = 'rejected' THEN
    -- Recusada de novo: vira aviso e não volta para o lote automático.
    UPDATE public.fiscal_document d
       SET status = 'rejected', status_code = NULLIF(p_result ->> 'status_code', ''), reason = pg_catalog.left(p_result ->> 'reason', 500),
           resend_attempted_at = COALESCE(d.resend_attempted_at, pg_catalog.now()), resend_status = 'refused',
           resend_message = pg_catalog.left(COALESCE(p_result ->> 'status_code', '') || ' ' || COALESCE(p_result ->> 'reason', ''), 500),
           alert_dismissed_at = NULL
     WHERE d.id = v_doc.id;
  ELSIF v_kind = 'unavailable' THEN
    UPDATE public.fiscal_document d
       SET resend_attempted_at = COALESCE(d.resend_attempted_at, pg_catalog.now()), resend_status = 'unavailable',
           resend_message = pg_catalog.left(p_result ->> 'reason', 500)
     WHERE d.id = v_doc.id;
  ELSE
    RAISE EXCEPTION 'Alguns dados informados são inválidos.' USING ERRCODE = 'FA005', DETAIL = 'Resultado do reenvio.';
  END IF;
  RETURN v_kind;
END;
$$;

-- ===== Cancelamento da venda junto com a NFC-e (até 30 minutos da autorização) =====

ALTER TABLE sale
  ADD COLUMN canceled_at timestamptz,
  ADD COLUMN canceled_by uuid REFERENCES user_account (id),
  ADD COLUMN cancel_reason text CONSTRAINT sale_cancel_reason_check CHECK (length(btrim(cancel_reason)) BETWEEN 15 AND 255),
  ADD CONSTRAINT sale_canceled_check CHECK ((canceled_at IS NULL) = (cancel_reason IS NULL));

-- O estoque volta com estorno dos movimentos da venda, ligado à venda cancelada (fora do SNGPC:
-- as saídas da venda são desconsideradas lá).
ALTER TABLE stock_movement ADD COLUMN canceled_sale_id uuid REFERENCES sale (id);
ALTER TABLE stock_movement ADD CONSTRAINT stock_movement_canceled_sale_check
  CHECK (canceled_sale_id IS NULL OR (movement_type = 'sale' AND reversal_of IS NOT NULL));
CREATE INDEX stock_movement_canceled_sale_idx ON stock_movement (canceled_sale_id) WHERE canceled_sale_id IS NOT NULL;
DROP TRIGGER track_sngpc_movement ON stock_movement;
CREATE TRIGGER track_sngpc_movement AFTER INSERT ON stock_movement
  FOR EACH ROW WHEN (NEW.movement_type <> 'import' AND NEW.stock_count_id IS NULL AND NEW.canceled_sale_id IS NULL)
  EXECUTE FUNCTION app.track_sngpc_movement();

-- Crediário da venda cancelada: um recebimento do tipo "cancel" quita as parcelas dela.
ALTER TABLE credit_payment DROP CONSTRAINT credit_payment_method_check;
ALTER TABLE credit_payment ADD CONSTRAINT credit_payment_method_check
  CHECK (method IN ('cash', 'credit_card', 'debit_card', 'pix', 'return', 'cancel'));
ALTER TABLE credit_payment ADD COLUMN canceled_sale_id uuid REFERENCES sale (id);
ALTER TABLE credit_payment ADD CONSTRAINT credit_payment_cancel_check CHECK ((method = 'cancel') = (canceled_sale_id IS NOT NULL));
CREATE UNIQUE INDEX credit_payment_cancel_key ON credit_payment (canceled_sale_id) WHERE deleted_at IS NULL AND canceled_sale_id IS NOT NULL;

-- Dinheiro devolvido ao cliente quando o turno da venda já fechou: sai do turno aberto.
ALTER TABLE cash_movement ADD COLUMN canceled_sale_id uuid REFERENCES sale (id);
CREATE INDEX cash_movement_canceled_sale_idx ON cash_movement (canceled_sale_id) WHERE canceled_sale_id IS NOT NULL;

-- O que impede desfazer a venda com segurança (o código do erro), ou NULL.
CREATE FUNCTION app.sale_cancel_blocker(p_sale public.sale) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT CASE
    WHEN EXISTS (SELECT 1 FROM public.sale_return r WHERE r.sale_id = p_sale.id AND r.deleted_at IS NULL) THEN 'FA749'
    WHEN EXISTS (
      SELECT 1 FROM public.agreement_invoice_item ii JOIN public.sale_payment p ON p.id = ii.sale_payment_id
       WHERE p.sale_id = p_sale.id AND ii.deleted_at IS NULL
    ) THEN 'FA750'
    WHEN EXISTS (
      SELECT 1 FROM public.sngpc_movement sm JOIN public.stock_movement m ON m.id = sm.stock_movement_id
        JOIN public.sale_item i ON i.id = m.sale_item_id
       WHERE i.sale_id = p_sale.id AND sm.deleted_at IS NULL AND sm.status NOT IN ('pending', 'disregarded')
    ) THEN 'FA751'
    WHEN EXISTS (
      SELECT 1 FROM public.credit_allocation a JOIN public.credit_installment ci ON ci.id = a.installment_id
       WHERE ci.sale_id = p_sale.id AND a.deleted_at IS NULL
    ) THEN 'FA752'
  END
$$;

-- Desfaz a venda: estoque, SNGPC, cashback, crediário, pagamentos, caixa e orçamento. Devolve o
-- que aconteceu com o dinheiro (para avisar na tela).
CREATE FUNCTION app.cancel_sale_effects(p_sale public.sale, p_user uuid, p_reason text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_movement public.stock_movement;
  v_lot record;
  v_entry uuid;
  v_payment uuid;
  v_account uuid;
  v_open numeric;
  v_cash numeric;
  v_session public.cash_session;
  v_open_session public.cash_session;
  v_cash_note text := 'none';
BEGIN
  -- Estoque: estorno de cada saída da venda (exatamente o que saiu, no mesmo lote).
  FOR v_movement IN
    SELECT m.* FROM public.stock_movement m JOIN public.sale_item i ON i.id = m.sale_item_id
     WHERE i.sale_id = p_sale.id AND m.reversal_of IS NULL AND m.deleted_at IS NULL
       AND NOT EXISTS (SELECT 1 FROM public.stock_movement r WHERE r.reversal_of = m.id AND r.deleted_at IS NULL)
  LOOP
    INSERT INTO public.stock_movement (economic_group_id, branch_id, product_id, batch_id, movement_type, quantity, reason, reversal_of, canceled_sale_id)
    VALUES (v_movement.economic_group_id, v_movement.branch_id, v_movement.product_id, v_movement.batch_id, 'sale', -v_movement.quantity,
            'Venda cancelada', v_movement.id, p_sale.id);
  END LOOP;

  -- SNGPC: as saídas da venda ainda pendentes deixam de valer; a dispensação some.
  UPDATE public.sngpc_movement sm SET status = 'disregarded', status_reason = 'Venda cancelada (NFC-e cancelada).'
    FROM public.stock_movement m JOIN public.sale_item i ON i.id = m.sale_item_id
   WHERE sm.stock_movement_id = m.id AND i.sale_id = p_sale.id AND sm.status = 'pending' AND sm.deleted_at IS NULL;
  UPDATE public.controlled_dispensing d SET deleted_at = pg_catalog.now()
   WHERE d.sale_id = p_sale.id AND d.deleted_at IS NULL;

  -- Cashback ganho: estorna o que sobra do lote. Cashback usado: a utilização é liberada.
  FOR v_lot IN
    SELECT l.lot_id, l.remaining FROM public.cashback_entry e
      JOIN app.cashback_lots(e.customer_id, pg_catalog.now()) l ON l.lot_id = e.id
     WHERE e.sale_id = p_sale.id AND e.kind = 'earn' AND e.deleted_at IS NULL AND l.remaining > 0
  LOOP
    INSERT INTO public.cashback_entry (economic_group_id, customer_id, branch_id, kind, amount, sale_id, detail)
    VALUES (p_sale.economic_group_id, p_sale.customer_id, p_sale.branch_id, 'reverse', v_lot.remaining, p_sale.id,
            pg_catalog.jsonb_build_object('reason', 'canceled_sale'))
    RETURNING id INTO v_entry;
    INSERT INTO public.cashback_allocation (economic_group_id, entry_id, lot_id, amount)
    VALUES (p_sale.economic_group_id, v_entry, v_lot.lot_id, v_lot.remaining);
  END LOOP;
  UPDATE public.cashback_entry e SET status = 'released'
   WHERE e.sale_id = p_sale.id AND e.kind = 'use' AND e.status = 'confirmed' AND e.deleted_at IS NULL;

  -- Crediário: as parcelas da venda são quitadas por um recebimento "cancel" (não passa pelo caixa).
  SELECT ci.account_id, pg_catalog.sum(ci.amount) INTO v_account, v_open FROM public.credit_installment ci
   WHERE ci.sale_id = p_sale.id AND ci.deleted_at IS NULL GROUP BY ci.account_id;
  IF v_open > 0 THEN
    INSERT INTO public.credit_payment (
      economic_group_id, account_id, branch_id, terminal_id, cash_session_id, received_by, received_at, method, amount, canceled_sale_id
    ) VALUES (
      p_sale.economic_group_id, v_account, p_sale.branch_id, p_sale.terminal_id, p_sale.cash_session_id,
      COALESCE(p_user, p_sale.sold_by), pg_catalog.now(), 'cancel', v_open, p_sale.id
    ) RETURNING id INTO v_payment;
    INSERT INTO public.credit_allocation (economic_group_id, payment_id, installment_id, received_on, fee, interest, principal)
    SELECT p_sale.economic_group_id, v_payment, ci.id, app.local_today(), 0, 0, ci.amount
      FROM public.credit_installment ci WHERE ci.sale_id = p_sale.id AND ci.deleted_at IS NULL;
    PERFORM app.mark_sync_change('customer', p_sale.customer_id, p_sale.economic_group_id, NULL);
  END IF;

  -- Dinheiro: com o turno da venda aberto, tirar a venda do esperado basta (entrou e saiu da
  -- mesma gaveta). Com o turno fechado, a devolução sai do turno aberto do terminal.
  SELECT COALESCE(pg_catalog.sum(p.amount - p.change_amount), 0) INTO v_cash FROM public.sale_payment p
   WHERE p.sale_id = p_sale.id AND p.method = 'cash' AND p.deleted_at IS NULL;
  SELECT * INTO v_session FROM public.cash_session cs WHERE cs.id = p_sale.cash_session_id;
  IF v_cash > 0 THEN
    IF v_session.status = 'open' THEN
      v_cash_note := 'same_session';
    ELSE
      SELECT * INTO v_open_session FROM public.cash_session cs
       WHERE cs.terminal_id = p_sale.terminal_id AND cs.status = 'open' AND cs.deleted_at IS NULL
       ORDER BY cs.opened_at DESC LIMIT 1;
      IF v_open_session.id IS NOT NULL THEN
        INSERT INTO public.cash_movement (economic_group_id, branch_id, cash_session_id, kind, amount, reason, operator_id, moved_at, canceled_sale_id)
        VALUES (p_sale.economic_group_id, p_sale.branch_id, v_open_session.id, 'withdrawal', v_cash,
                'Devolução ao cliente: venda ' || p_sale.code || ' cancelada', COALESCE(p_user, p_sale.sold_by), pg_catalog.now(), p_sale.id);
        v_cash_note := 'open_session';
      ELSE
        v_cash_note := 'no_session';
      END IF;
    END IF;
  END IF;

  -- Pagamentos fora do esperado do caixa, do limite do convênio e do saldo do crédito de devolução.
  UPDATE public.sale_payment p SET deleted_at = pg_catalog.now() WHERE p.sale_id = p_sale.id AND p.deleted_at IS NULL;
  -- O orçamento convertido nesta venda volta a ficar aberto.
  UPDATE public.quote q SET status = 'open', converted_sale_id = NULL WHERE q.converted_sale_id = p_sale.id;
  UPDATE public.sale s
     SET canceled_at = pg_catalog.now(), canceled_by = p_user, cancel_reason = pg_catalog.btrim(p_reason), deleted_at = pg_catalog.now()
   WHERE s.id = p_sale.id;
  RETURN pg_catalog.jsonb_build_object('cash', v_cash, 'cash_refund', v_cash_note);
END;
$$;

-- Contexto para falar com a Sefaz sobre uma nota (com o certificado selado), conferindo quem pede:
-- consult (sales.view), resend (fiscal.void ou a rotina), cancel (fiscal.cancel, autorizada, até
-- 30 minutos e venda que pode ser desfeita).
CREATE FUNCTION app.fiscal_action_context(p_document_id uuid, p_action text) RETURNS TABLE (
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

-- Cancelamento registrado na Sefaz: guarda o evento, a nota fica cancelada e a venda é desfeita.
-- Também vale quando a consulta mostra a nota cancelada (feito fora daqui).
-- p_event: {reason, protocol, status_code, xml, registered_at}.
CREATE FUNCTION app.fiscal_cancel_register(p_document_id uuid, p_event jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_doc public.fiscal_document;
  v_sale public.sale;
  v_user uuid := app.current_user_id();
  v_effects jsonb;
  v_blocker text;
BEGIN
  SELECT * INTO v_doc FROM public.fiscal_document d WHERE d.id = p_document_id AND d.deleted_at IS NULL FOR UPDATE;
  IF v_doc.id IS NULL OR v_doc.economic_group_id <> app.current_user_group()
     OR NOT (app.has_permission('fiscal.cancel', v_doc.branch_id) OR app.has_permission('sales.view', v_doc.branch_id)) THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.' USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('fiscal_document %s.', p_document_id);
  END IF;
  IF v_doc.status = 'canceled' THEN
    RETURN pg_catalog.jsonb_build_object('already', true);
  END IF;
  INSERT INTO public.fiscal_event (economic_group_id, fiscal_document_id, kind, reason, protocol, status_code, xml, registered_at, requested_by)
  VALUES (v_doc.economic_group_id, v_doc.id, 'cancellation', pg_catalog.btrim(p_event ->> 'reason'), p_event ->> 'protocol',
          p_event ->> 'status_code', p_event ->> 'xml', (p_event ->> 'registered_at')::timestamptz, v_user);
  UPDATE public.fiscal_document d SET status = 'canceled' WHERE d.id = v_doc.id;
  SELECT * INTO v_sale FROM public.sale s WHERE s.id = v_doc.sale_id AND s.deleted_at IS NULL FOR UPDATE;
  IF v_sale.id IS NOT NULL THEN
    -- A venda só é desfeita sem bloqueio e no prazo (30 minutos, com folga para a ida à Sefaz).
    -- Senão a nota fica cancelada, a venda fica como está e vira aviso para tratar à mão.
    v_blocker := app.sale_cancel_blocker(v_sale);
    IF v_blocker IS NULL AND v_doc.authorized_at < pg_catalog.now() - interval '35 minutes' THEN
      v_blocker := 'FA748';
    END IF;
    IF v_blocker IS NOT NULL THEN
      UPDATE public.fiscal_document d
         SET cancel_note = 'Nota cancelada na Sefaz, mas a venda não foi desfeita (' || v_blocker || '): acerte pela devolução.',
             alert_dismissed_at = NULL
       WHERE d.id = v_doc.id;
      RETURN pg_catalog.jsonb_build_object('sale_kept', v_blocker);
    END IF;
    v_effects := app.cancel_sale_effects(v_sale, v_user, p_event ->> 'reason');
  END IF;
  RETURN COALESCE(v_effects, '{}'::jsonb);
END;
$$;

-- Resultado de uma consulta feita por alguém na tela (mesmo efeito do reenvio).
CREATE FUNCTION app.fiscal_consult_result(p_document_id uuid, p_result jsonb) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM 1 FROM app.fiscal_action_context(p_document_id, 'consult');
  RETURN app.fiscal_resend_result(p_document_id, p_result);
END;
$$;

-- Aviso visto: sai do painel.
CREATE FUNCTION app.dismiss_fiscal_alert(p_document_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM 1 FROM app.fiscal_action_context(p_document_id, 'consult');
  UPDATE public.fiscal_document d SET alert_dismissed_at = pg_catalog.now() WHERE d.id = p_document_id;
END;
$$;

-- ===== Inutilização =====

-- Buracos de numeração por filial, série e terminal: números entre a primeira nota e o último
-- usado sem nota válida e sem inutilização (inclui as rejeitadas). "safe": o terminal já
-- mandou tudo depois do buraco (nada na fila dele), então o número não vai aparecer depois.
CREATE FUNCTION app.fiscal_number_gaps(p_branch_id uuid DEFAULT NULL)
RETURNS TABLE (
  branch_id uuid, branch_name text, terminal_id uuid, terminal_name text, series integer, first_number bigint, last_number bigint,
  quantity bigint, rejected integer, safe boolean
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  WITH series_range AS (
    SELECT fs.terminal_id, t.branch_id, t.name AS terminal_name, fs.series, fs.last_used_number,
           (SELECT pg_catalog.min(d.number) FROM public.fiscal_document d
             WHERE d.branch_id = t.branch_id AND d.model = '65' AND d.series = fs.series AND d.deleted_at IS NULL) AS first_seen
      FROM public.terminal_fiscal_series fs
      JOIN public.terminal t ON t.id = fs.terminal_id
     WHERE fs.model = '65' AND fs.deleted_at IS NULL AND fs.last_used_number IS NOT NULL
       AND fs.economic_group_id = app.current_user_group()
       AND (app.has_permission('fiscal.void', t.branch_id) OR app.has_permission('sales.view', t.branch_id))
       AND (p_branch_id IS NULL OR t.branch_id = p_branch_id)
  ),
  missing AS (
    SELECT r.*, n.n
      FROM series_range r
      CROSS JOIN LATERAL pg_catalog.generate_series(r.first_seen, r.last_used_number) AS n(n)
     WHERE r.first_seen IS NOT NULL AND r.last_used_number - r.first_seen < 200000
       AND NOT EXISTS (
         SELECT 1 FROM public.fiscal_document d
          WHERE d.branch_id = r.branch_id AND d.model = '65' AND d.series = r.series AND d.number = n.n
            AND d.status <> 'rejected' AND d.deleted_at IS NULL)
       AND NOT EXISTS (
         SELECT 1 FROM public.fiscal_number_void v
          WHERE v.branch_id = r.branch_id AND v.model = '65' AND v.series = r.series AND n.n BETWEEN v.first_number AND v.last_number
            AND v.deleted_at IS NULL)
  ),
  islands AS (
    SELECT m.*, m.n - pg_catalog.row_number() OVER (PARTITION BY m.terminal_id, m.series ORDER BY m.n) AS island FROM missing m
  )
  SELECT i.branch_id, b.name, i.terminal_id, i.terminal_name, i.series, pg_catalog.min(i.n), pg_catalog.max(i.n), pg_catalog.count(*),
         (SELECT pg_catalog.count(*)::integer FROM public.fiscal_document d
           WHERE d.branch_id = i.branch_id AND d.model = '65' AND d.series = i.series AND d.status = 'rejected' AND d.deleted_at IS NULL
             AND d.number BETWEEN pg_catalog.min(i.n) AND pg_catalog.max(i.n)),
         COALESCE((SELECT ts.outbox_pending = 0 FROM public.terminal_status ts WHERE ts.terminal_id = i.terminal_id), false)
    FROM islands i JOIN public.branch b ON b.id = i.branch_id
   GROUP BY i.branch_id, b.name, i.terminal_id, i.terminal_name, i.series, i.island
   ORDER BY b.name, i.terminal_name, i.series, pg_catalog.min(i.n)
$$;

-- Contexto da inutilização: a faixa tem de ser buraco (sem nota válida, sem inutilização).
CREATE FUNCTION app.fiscal_void_context(p_branch_id uuid, p_series integer, p_first bigint, p_last bigint) RETURNS TABLE (
  branch_id uuid, company_id uuid, cnpj text, state text, environment smallint, encrypted_pfx bytea, encrypted_password bytea
)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT app.has_permission('fiscal.void', p_branch_id) OR NOT EXISTS (
    SELECT 1 FROM public.branch b JOIN public.company c ON c.id = b.company_id
     WHERE b.id = p_branch_id AND c.economic_group_id = app.current_user_group() AND b.deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Você não tem permissão para esta operação.' USING ERRCODE = 'FA002', DETAIL = 'Inutilização sem fiscal.void.';
  END IF;
  IF p_series IS NULL OR p_first IS NULL OR p_last IS NULL OR p_first < 1 OR p_last < p_first OR p_last - p_first >= 10000
     OR EXISTS (
       SELECT 1 FROM public.fiscal_document d
        WHERE d.branch_id = p_branch_id AND d.model = '65' AND d.series = p_series AND d.number BETWEEN p_first AND p_last
          AND d.status <> 'rejected' AND d.deleted_at IS NULL)
     OR EXISTS (
       SELECT 1 FROM public.fiscal_number_void v
        WHERE v.branch_id = p_branch_id AND v.model = '65' AND v.series = p_series AND v.deleted_at IS NULL
          AND v.first_number <= p_last AND v.last_number >= p_first) THEN
    RAISE EXCEPTION 'A faixa para inutilizar é inválida.' USING ERRCODE = 'FA755',
      DETAIL = pg_catalog.format('Série %s, %s a %s.', p_series, p_first, p_last);
  END IF;
  RETURN QUERY
    SELECT b.id, b.company_id, b.cnpj::text, b.state::text, b.nfce_environment, bc.encrypted_pfx, bc.encrypted_password
      FROM public.branch b
      LEFT JOIN public.branch_certificate bc ON bc.branch_id = b.id AND bc.deleted_at IS NULL
     WHERE b.id = p_branch_id;
END;
$$;

-- Inutilização homologada na Sefaz. p_result: {protocol, xml, voided_at, environment}.
CREATE FUNCTION app.fiscal_void_register(p_branch_id uuid, p_series integer, p_first bigint, p_last bigint, p_reason text, p_result jsonb)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_group uuid := app.current_user_group();
  v_id uuid;
BEGIN
  PERFORM 1 FROM app.fiscal_void_context(p_branch_id, p_series, p_first, p_last);
  INSERT INTO public.fiscal_number_void (
    economic_group_id, branch_id, model, series, first_number, last_number, environment, reason, protocol, xml, voided_at, requested_by
  ) VALUES (
    v_group, p_branch_id, '65', p_series, p_first, p_last, (p_result ->> 'environment')::smallint, pg_catalog.btrim(p_reason),
    p_result ->> 'protocol', p_result ->> 'xml', (p_result ->> 'voided_at')::timestamptz, app.current_user_id()
  ) RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

-- ===== Consultas da tela "Notas fiscais" =====

CREATE FUNCTION app.list_fiscal_documents(
  p_branch_id uuid DEFAULT NULL, p_from date DEFAULT NULL, p_to date DEFAULT NULL, p_status text DEFAULT NULL, p_alerts boolean DEFAULT false
)
RETURNS TABLE (
  id uuid, sale_id uuid, sale_code text, branch_id uuid, branch_name text, terminal_name text, series integer, number bigint,
  access_key text, environment smallint, emission_type smallint, status text, status_code text, reason text, emitted_at timestamptz,
  authorized_at timestamptz, total numeric, resend_attempted_at timestamptz, resend_status text, resend_message text,
  alert boolean, cancel_note text, cancelable_until timestamptz
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT d.id, d.sale_id, s.code, d.branch_id, b.name, t.name, d.series, d.number, d.access_key, d.environment, d.emission_type,
         d.status, d.status_code, d.reason, d.emitted_at, d.authorized_at, s.total, d.resend_attempted_at, d.resend_status,
         d.resend_message,
         ((d.resend_status = 'refused' AND d.status = 'rejected') OR d.cancel_note IS NOT NULL) AND d.alert_dismissed_at IS NULL,
         d.cancel_note,
         CASE WHEN d.status = 'authorized' AND d.authorized_at > pg_catalog.now() - interval '30 minutes'
              THEN d.authorized_at + interval '30 minutes' END
    FROM public.fiscal_document d
    JOIN public.sale s ON s.id = d.sale_id
    JOIN public.branch b ON b.id = d.branch_id
    JOIN public.terminal t ON t.id = d.terminal_id
   WHERE d.deleted_at IS NULL AND d.economic_group_id = app.current_user_group()
     AND app.has_permission('sales.view', d.branch_id)
     AND (p_branch_id IS NULL OR d.branch_id = p_branch_id)
     AND (p_status IS NULL OR d.status = p_status)
     AND (NOT p_alerts OR (((d.resend_status = 'refused' AND d.status = 'rejected') OR d.cancel_note IS NOT NULL) AND d.alert_dismissed_at IS NULL))
     AND (p_from IS NULL OR d.emitted_at >= p_from::timestamp AT TIME ZONE 'America/Sao_Paulo')
     AND (p_to IS NULL OR d.emitted_at < (p_to + 1)::timestamp AT TIME ZONE 'America/Sao_Paulo')
   ORDER BY d.emitted_at DESC, d.id DESC
   LIMIT 500
$$;

-- Eventos e XML de uma nota (o XML só para quem vê a venda).
CREATE FUNCTION app.fiscal_document_files(p_document_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT pg_catalog.jsonb_build_object(
    'access_key', d.access_key, 'status', d.status, 'xml', d.xml,
    'cancellation', (SELECT pg_catalog.jsonb_build_object('reason', e.reason, 'protocol', e.protocol, 'registered_at', e.registered_at, 'xml', e.xml)
                       FROM public.fiscal_event e WHERE e.fiscal_document_id = d.id AND e.kind = 'cancellation' AND e.deleted_at IS NULL))
    FROM public.fiscal_document d
   WHERE d.id = p_document_id AND d.deleted_at IS NULL AND d.economic_group_id = app.current_user_group()
     AND app.has_permission('sales.view', d.branch_id)
$$;

CREATE FUNCTION app.list_fiscal_voids(p_branch_id uuid DEFAULT NULL)
RETURNS TABLE (
  id uuid, branch_name text, series integer, first_number bigint, last_number bigint, reason text, protocol text, voided_at timestamptz,
  requested_by_name text
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT v.id, b.name, v.series, v.first_number, v.last_number, v.reason, v.protocol, v.voided_at, u.name
    FROM public.fiscal_number_void v
    JOIN public.branch b ON b.id = v.branch_id
    LEFT JOIN public.user_account u ON u.id = v.requested_by
   WHERE v.deleted_at IS NULL AND v.economic_group_id = app.current_user_group()
     AND app.has_permission('sales.view', v.branch_id)
     AND (p_branch_id IS NULL OR v.branch_id = p_branch_id)
   ORDER BY v.voided_at DESC
   LIMIT 200
$$;

REVOKE ALL ON FUNCTION
  app.require_fiscal_worker(),
  app.claim_fiscal_resend(integer),
  app.fiscal_resend_result(uuid, jsonb),
  app.sale_cancel_blocker(public.sale),
  app.cancel_sale_effects(public.sale, uuid, text),
  app.fiscal_action_context(uuid, text),
  app.fiscal_cancel_register(uuid, jsonb),
  app.fiscal_consult_result(uuid, jsonb),
  app.dismiss_fiscal_alert(uuid),
  app.fiscal_number_gaps(uuid),
  app.fiscal_void_context(uuid, integer, bigint, bigint),
  app.fiscal_void_register(uuid, integer, bigint, bigint, text, jsonb),
  app.list_fiscal_documents(uuid, date, date, text, boolean),
  app.fiscal_document_files(uuid),
  app.list_fiscal_voids(uuid)
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  app.claim_fiscal_resend(integer),
  app.fiscal_resend_result(uuid, jsonb),
  app.fiscal_action_context(uuid, text),
  app.fiscal_cancel_register(uuid, jsonb),
  app.fiscal_consult_result(uuid, jsonb),
  app.dismiss_fiscal_alert(uuid),
  app.fiscal_number_gaps(uuid),
  app.fiscal_void_context(uuid, integer, bigint, bigint),
  app.fiscal_void_register(uuid, integer, bigint, bigint, text, jsonb),
  app.list_fiscal_documents(uuid, date, date, text, boolean),
  app.fiscal_document_files(uuid),
  app.list_fiscal_voids(uuid)
TO farmaerp_app;
