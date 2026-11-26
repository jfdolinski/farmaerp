-- Up Migration

-- Etapa 8, PR 8C-2: envio do SNGPC à Anvisa.
-- A rotina da API (sem usuário, app.worker = 'sngpc') pega as filiais com credencial e com
-- movimentações conferidas cuja data de envio chegou, monta a remessa (o arquivo é guardado como
-- foi enviado e não muda), transmite e depois consulta o resultado. A primeira remessa da filial é
-- o inventário; as outras só saem depois do inventário aceito. Recusa volta para o farmacêutico,
-- que corrige e confere de novo; ela segura as posteriores do mesmo produto.
-- A credencial do SNGPC é da filial (do farmacêutico responsável) e fica criptografada pela API.

CREATE TABLE sngpc_credential (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  branch_id uuid NOT NULL REFERENCES branch (id),
  encrypted_username bytea NOT NULL,
  encrypted_password bytea NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE UNIQUE INDEX sngpc_credential_branch_key ON sngpc_credential (branch_id) WHERE deleted_at IS NULL;
CREATE INDEX sngpc_credential_economic_group_id_idx ON sngpc_credential (economic_group_id);
CALL app.apply_table_standard('public.sngpc_credential');
-- Trocar é encerrar e incluir: o conteúdo de uma linha nunca muda.
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON sngpc_credential
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'branch_id', 'encrypted_username', 'encrypted_password'
  );
CREATE POLICY sngpc_credential_select ON sngpc_credential FOR SELECT TO farmaerp_app USING (false);
CREATE VIEW v_sngpc_credential WITH (security_invoker = true) AS
  SELECT id, economic_group_id, branch_id, created_at, updated_at, deleted_at, version, updated_by, trace_id
    FROM sngpc_credential WHERE deleted_at IS NULL;

CREATE TABLE sngpc_submission (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  branch_id uuid NOT NULL REFERENCES branch (id),
  kind text NOT NULL CONSTRAINT sngpc_submission_kind_check CHECK (kind IN ('inventory', 'movements')),
  period_start date NOT NULL,
  period_end date NOT NULL,
  status text NOT NULL DEFAULT 'built' CONSTRAINT sngpc_submission_status_check CHECK (status IN ('built', 'sent', 'accepted', 'rejected')),
  -- O arquivo como foi enviado (gravado no envio) e o resumo dele.
  payload text,
  payload_sha256 text CONSTRAINT sngpc_submission_sha_check CHECK (payload_sha256 ~ '^[0-9a-f]{64}$'),
  protocol text CONSTRAINT sngpc_submission_protocol_check CHECK (length(protocol) BETWEEN 1 AND 100),
  sent_at timestamptz,
  result_at timestamptz,
  reject_reason text CONSTRAINT sngpc_submission_reason_check CHECK (length(reject_reason) BETWEEN 1 AND 2000),
  attempts integer NOT NULL DEFAULT 0,
  last_error text CONSTRAINT sngpc_submission_error_check CHECK (length(last_error) <= 500),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid,
  CONSTRAINT sngpc_submission_period_check CHECK (period_end >= period_start),
  CONSTRAINT sngpc_submission_state_check CHECK (
    (status = 'built' AND payload IS NULL AND sent_at IS NULL AND result_at IS NULL)
    OR (status = 'sent' AND payload IS NOT NULL AND payload_sha256 IS NOT NULL AND protocol IS NOT NULL AND sent_at IS NOT NULL AND result_at IS NULL)
    OR (status = 'accepted' AND payload IS NOT NULL AND protocol IS NOT NULL AND result_at IS NOT NULL)
    OR (status = 'rejected' AND payload IS NOT NULL AND protocol IS NOT NULL AND result_at IS NOT NULL AND reject_reason IS NOT NULL)
  )
);
-- Uma remessa em aberto (montada ou enviada sem resultado) por filial.
CREATE UNIQUE INDEX sngpc_submission_open_key ON sngpc_submission (branch_id) WHERE status IN ('built', 'sent') AND deleted_at IS NULL;
CREATE INDEX sngpc_submission_branch_idx ON sngpc_submission (branch_id, created_at DESC);
CREATE INDEX sngpc_submission_economic_group_id_idx ON sngpc_submission (economic_group_id);
CALL app.apply_table_standard('public.sngpc_submission');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON sngpc_submission
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'branch_id', 'kind', 'period_start', 'period_end', 'deleted_at'
  );
CREATE POLICY sngpc_submission_select ON sngpc_submission FOR SELECT TO farmaerp_app USING (false);
CREATE VIEW v_sngpc_submission WITH (security_invoker = true) AS SELECT * FROM sngpc_submission WHERE deleted_at IS NULL;

-- O arquivo enviado não muda; a situação só anda para a frente.
CREATE FUNCTION app.guard_sngpc_submission() RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF OLD.payload IS NOT NULL AND (NEW.payload IS DISTINCT FROM OLD.payload OR NEW.payload_sha256 IS DISTINCT FROM OLD.payload_sha256
                                  OR NEW.protocol IS DISTINCT FROM OLD.protocol OR NEW.sent_at IS DISTINCT FROM OLD.sent_at) THEN
    RAISE EXCEPTION 'Esta remessa do SNGPC não pode mais ser alterada.' USING ERRCODE = 'FA720', DETAIL = 'Arquivo já enviado.';
  END IF;
  IF NOT (NEW.status = OLD.status OR (OLD.status = 'built' AND NEW.status = 'sent')
          OR (OLD.status = 'sent' AND NEW.status IN ('accepted', 'rejected'))) THEN
    RAISE EXCEPTION 'Esta remessa do SNGPC não pode mais ser alterada.'
      USING ERRCODE = 'FA720', DETAIL = pg_catalog.format('De %s para %s.', OLD.status, NEW.status);
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER guard_sngpc_submission BEFORE UPDATE ON sngpc_submission
  FOR EACH ROW EXECUTE FUNCTION app.guard_sngpc_submission();

ALTER TABLE sngpc_movement ADD COLUMN submission_id uuid REFERENCES sngpc_submission (id);
CREATE INDEX sngpc_movement_submission_idx ON sngpc_movement (submission_id);
ALTER TABLE sngpc_movement DROP CONSTRAINT sngpc_movement_state_check;
ALTER TABLE sngpc_movement ADD CONSTRAINT sngpc_movement_state_check CHECK (
  (status = 'pending' AND confirmed_by IS NULL AND send_on IS NULL AND status_reason IS NULL AND submission_id IS NULL)
  OR (status = 'disregarded' AND status_reason IS NOT NULL AND confirmed_by IS NULL AND submission_id IS NULL)
  OR (status = 'confirmed' AND confirmed_by IS NOT NULL AND confirmed_at IS NOT NULL AND send_on IS NOT NULL
      AND batch_id IS NOT NULL AND ms_registration IS NOT NULL)
  OR (status IN ('sent', 'accepted', 'rejected') AND confirmed_by IS NOT NULL AND confirmed_at IS NOT NULL AND send_on IS NOT NULL
      AND batch_id IS NOT NULL AND ms_registration IS NOT NULL AND submission_id IS NOT NULL)
);

-- Conferida segue o envio; recusada volta para pendente (o farmacêutico corrige e confere de novo).
CREATE OR REPLACE FUNCTION app.guard_sngpc_movement() RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF OLD.status = 'pending' THEN
    IF NEW.status NOT IN ('pending', 'confirmed', 'disregarded') THEN
      RAISE EXCEPTION 'Esta movimentação do SNGPC não pode mais ser alterada.'
        USING ERRCODE = 'FA863', DETAIL = pg_catalog.format('De %s para %s.', OLD.status, NEW.status);
    END IF;
    IF NEW.quantity IS DISTINCT FROM OLD.quantity AND OLD.kind <> 'inventory' THEN
      RAISE EXCEPTION 'Esta movimentação do SNGPC não pode mais ser alterada.'
        USING ERRCODE = 'FA863', DETAIL = 'Só a quantidade do inventário muda.';
    END IF;
    RETURN NEW;
  END IF;
  -- Recusada pela Anvisa: volta inteira para pendente, sem a conferência e sem a remessa.
  IF OLD.status = 'rejected' AND NEW.status = 'pending' AND NEW.quantity = OLD.quantity THEN
    RETURN NEW;
  END IF;
  IF NEW.batch_id IS DISTINCT FROM OLD.batch_id OR NEW.quantity IS DISTINCT FROM OLD.quantity
     OR NEW.reported_on IS DISTINCT FROM OLD.reported_on OR NEW.loss_reason IS DISTINCT FROM OLD.loss_reason
     OR NEW.confirmed_by IS DISTINCT FROM OLD.confirmed_by OR NEW.confirmed_at IS DISTINCT FROM OLD.confirmed_at
     OR NEW.send_on IS DISTINCT FROM OLD.send_on OR NEW.ms_registration IS DISTINCT FROM OLD.ms_registration
     OR (OLD.submission_id IS NOT NULL AND NEW.submission_id IS DISTINCT FROM OLD.submission_id)
     OR NOT (NEW.status = OLD.status OR (OLD.status = 'confirmed' AND NEW.status = 'sent')
             OR (OLD.status = 'sent' AND NEW.status IN ('accepted', 'rejected'))) THEN
    RAISE EXCEPTION 'Esta movimentação do SNGPC não pode mais ser alterada.'
      USING ERRCODE = 'FA863', DETAIL = pg_catalog.format('Movimentação em %s.', OLD.status);
  END IF;
  RETURN NEW;
END;
$$;

-- Só a rotina de envio do SNGPC: sem usuário e com o contexto dela.
CREATE FUNCTION app.require_sngpc_worker() RETURNS void
LANGUAGE plpgsql STABLE
SET search_path = ''
AS $$
BEGIN
  IF app.current_user_id() IS NOT NULL OR COALESCE(pg_catalog.current_setting('app.worker', true), '') <> 'sngpc' THEN
    RAISE EXCEPTION 'Você não tem permissão para esta operação.'
      USING ERRCODE = 'FA002', DETAIL = 'Função da rotina do SNGPC chamada fora dela.';
  END IF;
END;
$$;

-- Credencial do SNGPC da filial (a API criptografa antes de gravar).
CREATE FUNCTION app.set_sngpc_credential(p_branch_id uuid, p_username bytea, p_password bytea) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  opened public.sngpc_branch := app.require_sngpc_branch(p_branch_id);
BEGIN
  UPDATE public.sngpc_credential SET deleted_at = pg_catalog.clock_timestamp()
   WHERE branch_id = opened.branch_id AND deleted_at IS NULL;
  INSERT INTO public.sngpc_credential (economic_group_id, branch_id, encrypted_username, encrypted_password)
  VALUES (opened.economic_group_id, opened.branch_id, p_username, p_password);
END;
$$;

-- Código oficial do motivo de perda. Conferir com a documentação da API nova antes de ligar o
-- envio real: os códigos abaixo seguem o SNGPC atual.
CREATE FUNCTION app.sngpc_loss_code(p_reason text) RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$
  SELECT CASE p_reason
    WHEN 'theft' THEN '1' WHEN 'damage' THEN '2' WHEN 'expired' THEN '3' WHEN 'seized' THEN '4'
    WHEN 'quality_sample' THEN '6' WHEN 'recall' THEN '9' ELSE '5' END
$$;

-- Filiais com credencial e com algo a fazer: remessa enviada esperando resultado, remessa montada
-- esperando envio, ou movimentação conferida com a data de envio chegada. Reserva por 10 minutos.
CREATE FUNCTION app.sngpc_claim_branches(p_limit integer DEFAULT 10)
RETURNS TABLE (branch_id uuid, cnpj text, encrypted_username bytea, encrypted_password bytea)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM app.require_sngpc_worker();
  RETURN QUERY
  WITH due AS (
    SELECT sb.id, sb.branch_id
      FROM public.sngpc_branch sb
      JOIN public.sngpc_credential c ON c.branch_id = sb.branch_id AND c.deleted_at IS NULL
     WHERE sb.deleted_at IS NULL
       AND (sb.locked_until IS NULL OR sb.locked_until < pg_catalog.now())
       AND (EXISTS (SELECT 1 FROM public.sngpc_submission s WHERE s.branch_id = sb.branch_id AND s.status IN ('built', 'sent') AND s.deleted_at IS NULL)
            OR EXISTS (SELECT 1 FROM public.sngpc_movement m
                        WHERE m.branch_id = sb.branch_id AND m.status = 'confirmed' AND m.submission_id IS NULL
                          AND m.send_on <= app.local_day(pg_catalog.now())))
     ORDER BY sb.locked_until NULLS FIRST
     LIMIT LEAST(GREATEST(COALESCE(p_limit, 10), 1), 50)
     FOR UPDATE OF sb SKIP LOCKED
  ), claimed AS (
    UPDATE public.sngpc_branch sb SET locked_until = pg_catalog.now() + interval '10 minutes'
      FROM due WHERE sb.id = due.id
    RETURNING sb.branch_id
  )
  SELECT c.branch_id, b.cnpj::text, cr.encrypted_username, cr.encrypted_password
    FROM claimed c
    JOIN public.branch b ON b.id = c.branch_id
    JOIN public.sngpc_credential cr ON cr.branch_id = c.branch_id AND cr.deleted_at IS NULL;
END;
$$;

ALTER TABLE sngpc_branch ADD COLUMN locked_until timestamptz;
CREATE OR REPLACE FUNCTION app.sngpc_release_branch(p_branch_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM app.require_sngpc_worker();
  UPDATE public.sngpc_branch SET locked_until = NULL WHERE branch_id = p_branch_id AND deleted_at IS NULL;
END;
$$;

-- Dados de uma remessa para montar o arquivo: a filial e as movimentações na ordem do SNGPC.
CREATE FUNCTION app.sngpc_submission_data(p_submission_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT pg_catalog.jsonb_build_object(
    'id', s.id, 'kind', s.kind, 'period_start', s.period_start, 'period_end', s.period_end, 'status', s.status,
    'payload', s.payload, 'protocol', s.protocol, 'attempts', s.attempts,
    'branch', pg_catalog.jsonb_build_object('id', b.id, 'name', b.name, 'cnpj', b.cnpj),
    'movements', COALESCE((
      SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
               'id', m.id, 'kind', m.kind, 'reported_on', m.reported_on, 'quantity', m.quantity,
               'ms_registration', m.ms_registration, 'batch_number', pb.batch_number, 'expires_on', pb.expires_on,
               'product_name', p.display_name, 'controlled_class', cp.controlled_class,
               'loss_code', CASE WHEN m.kind IN ('loss', 'adjustment_out') THEN app.sngpc_loss_code(m.loss_reason) END,
               'counterpart_cnpj', CASE
                 WHEN m.kind = 'purchase' THEN (SELECT pi.emitter_cnpj FROM public.purchase_invoice_item pii
                                                 JOIN public.purchase_invoice pi ON pi.id = pii.invoice_id WHERE pii.id = sm.purchase_invoice_item_id)
                 WHEN m.kind IN ('transfer_in', 'transfer_out') THEN (SELECT ob.cnpj FROM public.stock_movement o JOIN public.branch ob ON ob.id = o.branch_id
                                                                     WHERE o.transfer_group = sm.transfer_group AND o.id <> sm.id LIMIT 1)
               END,
               'invoice_number', CASE WHEN m.kind = 'purchase' THEN (SELECT pi.number FROM public.purchase_invoice_item pii
                                     JOIN public.purchase_invoice pi ON pi.id = pii.invoice_id WHERE pii.id = sm.purchase_invoice_item_id) END,
               'prescription', CASE WHEN m.kind = 'sale' THEN pg_catalog.jsonb_build_object(
                 'type', COALESCE(sc.prescription_type, d.prescription_type),
                 'number', COALESCE(sc.prescription_number, d.prescription_number),
                 'date', COALESCE(sc.prescription_date, d.prescription_date),
                 'prescriber_name', COALESCE(sc.prescriber_name, d.prescriber_name),
                 'prescriber_council', COALESCE(sc.prescriber_council, d.prescriber_council),
                 'prescriber_number', COALESCE(sc.prescriber_number, d.prescriber_number),
                 'prescriber_state', COALESCE(sc.prescriber_state, d.prescriber_state),
                 'buyer_name', COALESCE(sc.buyer_name, d.buyer_name),
                 'buyer_document_type', COALESCE(sc.buyer_document_type, d.buyer_document_type),
                 'buyer_document', COALESCE(sc.buyer_document, d.buyer_document),
                 'buyer_issuer', COALESCE(sc.buyer_issuer, d.buyer_issuer),
                 'buyer_state', COALESCE(sc.buyer_state, d.buyer_state),
                 'patient_name', COALESCE(sc.patient_name, d.patient_name),
                 'patient_age', COALESCE(sc.patient_age, d.patient_age),
                 'patient_sex', COALESCE(sc.patient_sex, d.patient_sex)
               ) END
             ) ORDER BY m.reported_on, app.sngpc_rank(m.kind), m.occurred_at, m.id)
        FROM public.sngpc_movement m
        JOIN public.product p ON p.id = m.product_id
        LEFT JOIN public.catalog_product cp ON cp.id = p.catalog_product_id
        LEFT JOIN public.product_batch pb ON pb.id = m.batch_id
        LEFT JOIN public.stock_movement sm ON sm.id = m.stock_movement_id
        LEFT JOIN public.controlled_dispensing d ON d.id = m.dispensing_id
        LEFT JOIN public.sngpc_dispensing_complement sc ON sc.dispensing_id = m.dispensing_id AND sc.deleted_at IS NULL
       WHERE m.submission_id = s.id AND m.deleted_at IS NULL
    ), '[]'::jsonb)
  )
    FROM public.sngpc_submission s
    JOIN public.branch b ON b.id = s.branch_id
   WHERE s.id = p_submission_id
$$;

-- Remessa em aberto da filial, ou uma nova com o que já pode sair. Sem nada, null.
-- Inventário primeiro (sozinho); as movimentações só depois do inventário aceito. Produto com
-- movimentação recusada fica de fora até ser corrigido e conferido de novo.
CREATE FUNCTION app.sngpc_next_submission(p_branch_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  open_id uuid;
  opened public.sngpc_branch;
  today date := app.local_day(pg_catalog.now());
  inventory_accepted boolean;
  new_kind text;
  chosen uuid[];
  new_id uuid;
BEGIN
  PERFORM app.require_sngpc_worker();
  SELECT s.id INTO open_id FROM public.sngpc_submission s
   WHERE s.branch_id = p_branch_id AND s.status IN ('built', 'sent') AND s.deleted_at IS NULL;
  IF open_id IS NOT NULL THEN
    RETURN app.sngpc_submission_data(open_id);
  END IF;
  SELECT sb.* INTO opened FROM public.sngpc_branch sb WHERE sb.branch_id = p_branch_id AND sb.deleted_at IS NULL;
  IF opened.id IS NULL THEN
    RETURN NULL;
  END IF;
  inventory_accepted := EXISTS (
    SELECT 1 FROM public.sngpc_movement m WHERE m.branch_id = p_branch_id AND m.kind = 'inventory' AND m.status = 'accepted'
  ) AND NOT EXISTS (
    SELECT 1 FROM public.sngpc_movement m WHERE m.branch_id = p_branch_id AND m.kind = 'inventory' AND m.status NOT IN ('accepted', 'disregarded')
  );
  new_kind := CASE WHEN inventory_accepted THEN 'movements' ELSE 'inventory' END;
  SELECT pg_catalog.array_agg(m.id) INTO chosen
    FROM public.sngpc_movement m
   WHERE m.branch_id = p_branch_id AND m.status = 'confirmed' AND m.submission_id IS NULL AND m.deleted_at IS NULL
     AND m.send_on <= today
     AND ((new_kind = 'inventory' AND m.kind = 'inventory') OR (new_kind = 'movements' AND m.kind <> 'inventory'))
     AND NOT EXISTS (
       SELECT 1 FROM public.sngpc_movement r
        WHERE r.branch_id = m.branch_id AND r.product_id = m.product_id AND r.status = 'rejected' AND r.deleted_at IS NULL
     );
  IF chosen IS NULL THEN
    RETURN NULL;
  END IF;
  INSERT INTO public.sngpc_submission (economic_group_id, branch_id, kind, period_start, period_end)
  SELECT opened.economic_group_id, p_branch_id, new_kind, pg_catalog.min(m.reported_on), pg_catalog.max(m.reported_on)
    FROM public.sngpc_movement m WHERE m.id = ANY (chosen)
  RETURNING id INTO new_id;
  UPDATE public.sngpc_movement m SET submission_id = new_id WHERE m.id = ANY (chosen);
  RETURN app.sngpc_submission_data(new_id);
END;
$$;

-- Enviada: grava o arquivo como foi, o resumo e o protocolo.
CREATE FUNCTION app.sngpc_mark_sent(p_submission_id uuid, p_payload text, p_sha256 text, p_protocol text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM app.require_sngpc_worker();
  UPDATE public.sngpc_submission
     SET status = 'sent', payload = p_payload, payload_sha256 = p_sha256, protocol = p_protocol, sent_at = pg_catalog.now(),
         attempts = attempts + 1, last_error = NULL
   WHERE id = p_submission_id AND status = 'built';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Esta remessa do SNGPC não pode mais ser alterada.' USING ERRCODE = 'FA720', DETAIL = 'Remessa não está montada.';
  END IF;
  UPDATE public.sngpc_movement SET status = 'sent' WHERE submission_id = p_submission_id AND status = 'confirmed';
END;
$$;

-- Falha de transmissão: a remessa continua montada e a rotina tenta de novo.
CREATE FUNCTION app.sngpc_mark_failed(p_submission_id uuid, p_error text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM app.require_sngpc_worker();
  UPDATE public.sngpc_submission
     SET attempts = attempts + 1, last_error = pg_catalog.left(NULLIF(pg_catalog.btrim(COALESCE(p_error, '')), ''), 500)
   WHERE id = p_submission_id AND status IN ('built', 'sent');
END;
$$;

-- Resultado da Anvisa: aceita, ou recusada com o motivo (as movimentações voltam ao farmacêutico).
CREATE FUNCTION app.sngpc_mark_result(p_submission_id uuid, p_accepted boolean, p_reason text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  reason text := NULLIF(pg_catalog.btrim(COALESCE(p_reason, '')), '');
BEGIN
  PERFORM app.require_sngpc_worker();
  IF NOT p_accepted AND reason IS NULL THEN
    reason := 'A Anvisa recusou a remessa sem informar o motivo.';
  END IF;
  UPDATE public.sngpc_submission
     SET status = CASE WHEN p_accepted THEN 'accepted' ELSE 'rejected' END, result_at = pg_catalog.now(),
         reject_reason = CASE WHEN p_accepted THEN NULL ELSE pg_catalog.left(reason, 2000) END
   WHERE id = p_submission_id AND status = 'sent';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Esta remessa do SNGPC não pode mais ser alterada.' USING ERRCODE = 'FA720', DETAIL = 'Remessa não está enviada.';
  END IF;
  UPDATE public.sngpc_movement
     SET status = CASE WHEN p_accepted THEN 'accepted' ELSE 'rejected' END,
         status_reason = CASE WHEN p_accepted THEN NULL ELSE pg_catalog.left(reason, 500) END
   WHERE submission_id = p_submission_id AND status = 'sent';
END;
$$;

-- Recusada: o farmacêutico reabre para corrigir e conferir de novo (vai na próxima remessa).
CREATE FUNCTION app.sngpc_reopen(p_movement_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.sngpc_movement;
BEGIN
  SELECT m.* INTO target FROM public.sngpc_movement m
   WHERE m.id = p_movement_id AND m.economic_group_id = app.current_user_group() AND m.deleted_at IS NULL FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.' USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('sngpc_movement %s.', p_movement_id);
  END IF;
  PERFORM app.require_branch_permission('sngpc.manage', target.branch_id);
  IF target.status <> 'rejected' THEN
    RAISE EXCEPTION 'Esta movimentação do SNGPC não pode mais ser alterada.'
      USING ERRCODE = 'FA863', DETAIL = pg_catalog.format('Movimentação em %s.', target.status);
  END IF;
  UPDATE public.sngpc_movement
     SET status = 'pending', confirmed_by = NULL, confirmed_at = NULL, send_on = NULL, submission_id = NULL,
         status_reason = NULL, ms_registration = NULL
   WHERE id = target.id;
END;
$$;

-- Remessas da filial para a retaguarda (sem o arquivo).
CREATE FUNCTION app.list_sngpc_submissions(p_branch_id uuid)
RETURNS TABLE (
  id uuid, kind text, status text, period_start date, period_end date, movement_count integer, protocol text,
  sent_at timestamptz, result_at timestamptz, reject_reason text, attempts integer, last_error text, created_at timestamptz
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  opened public.sngpc_branch := app.require_sngpc_branch(p_branch_id);
BEGIN
  RETURN QUERY
  SELECT s.id, s.kind, s.status, s.period_start, s.period_end,
         (SELECT pg_catalog.count(*)::integer FROM public.sngpc_movement m WHERE m.submission_id = s.id),
         s.protocol, s.sent_at, s.result_at, s.reject_reason, s.attempts, s.last_error, s.created_at
    FROM public.sngpc_submission s
   WHERE s.branch_id = opened.branch_id AND s.deleted_at IS NULL
   ORDER BY s.created_at DESC
   LIMIT 200;
END;
$$;

-- Arquivo enviado, para baixar (só quem confere o SNGPC na filial).
CREATE FUNCTION app.sngpc_submission_file(p_submission_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target_submission public.sngpc_submission;
BEGIN
  SELECT s.* INTO target_submission FROM public.sngpc_submission s
   WHERE s.id = p_submission_id AND s.economic_group_id = app.current_user_group() AND s.deleted_at IS NULL;
  IF NOT FOUND OR target_submission.payload IS NULL THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.' USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('sngpc_submission %s.', p_submission_id);
  END IF;
  PERFORM app.require_branch_permission('sngpc.manage', target_submission.branch_id);
  RETURN pg_catalog.jsonb_build_object('payload', target_submission.payload, 'protocol', target_submission.protocol, 'period_end', target_submission.period_end);
END;
$$;

-- Credencial e envios da filial, para a tela (nunca o valor da credencial).
CREATE FUNCTION app.sngpc_send_info(p_branch_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  opened public.sngpc_branch := app.require_sngpc_branch(p_branch_id);
BEGIN
  RETURN pg_catalog.jsonb_build_object(
    'credential_at', (SELECT c.created_at FROM public.sngpc_credential c WHERE c.branch_id = opened.branch_id AND c.deleted_at IS NULL),
    'rejected', (SELECT pg_catalog.count(*)::integer FROM public.sngpc_movement m WHERE m.branch_id = opened.branch_id AND m.status = 'rejected'),
    'overdue', (SELECT pg_catalog.count(*)::integer FROM public.sngpc_movement m
                 WHERE m.branch_id = opened.branch_id AND m.status IN ('confirmed', 'sent') AND m.send_on < app.local_day(pg_catalog.now()))
  );
END;
$$;

-- A situação "recusada" aparece na lista da tela; a 0052 já aceita os demais estados.
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  app.set_sngpc_credential(uuid, bytea, bytea),
  app.sngpc_claim_branches(integer),
  app.sngpc_release_branch(uuid),
  app.sngpc_next_submission(uuid),
  app.sngpc_mark_sent(uuid, text, text, text),
  app.sngpc_mark_failed(uuid, text),
  app.sngpc_mark_result(uuid, boolean, text),
  app.sngpc_reopen(uuid),
  app.list_sngpc_submissions(uuid),
  app.sngpc_submission_file(uuid),
  app.sngpc_send_info(uuid)
TO farmaerp_app;
