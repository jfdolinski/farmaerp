-- Up Migration

-- Correções do 8A-3a (reenvio e conferência no banco):
-- * O lote do reenvio pega primeiro as notas nunca tentadas. Falha que não se resolve sozinha
--   (filial sem certificado, UF não atendida, ambiente diferente) e seis rodadas sem a Sefaz viram
--   aviso e saem do lote: as notas seguintes não ficam paradas atrás delas.
-- * O resultado do reenvio e o registro do cancelamento passam a conferir quem pede: a rotina,
--   quem pode reenviar ou cancelar a nota, ou quem consulta (só a nota cancelada por fora, sem
--   desfazer venda bloqueada). Os núcleos ficam internos.

ALTER TABLE fiscal_document ADD COLUMN resend_attempts integer NOT NULL DEFAULT 0
  CONSTRAINT fiscal_document_resend_attempts_check CHECK (resend_attempts >= 0);

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


DROP FUNCTION app.fiscal_resend_result(uuid, jsonb);
CREATE FUNCTION app.fiscal_apply_result(p_document_id uuid, p_result jsonb) RETURNS text
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
  ELSIF v_kind = 'unavailable' AND v_doc.resend_attempts < 6 THEN
    UPDATE public.fiscal_document d
       SET resend_attempted_at = COALESCE(d.resend_attempted_at, pg_catalog.now()), resend_status = 'unavailable',
           resend_message = pg_catalog.left(p_result ->> 'reason', 500)
     WHERE d.id = v_doc.id;
  ELSIF v_kind IN ('blocked', 'unavailable') THEN
    -- Falha que não se resolve sozinha (sem certificado, UF não atendida, ambiente diferente) ou
    -- seis rodadas sem a Sefaz: vira aviso e sai do lote; a nota fica como está.
    UPDATE public.fiscal_document d
       SET resend_attempted_at = COALESCE(d.resend_attempted_at, pg_catalog.now()), resend_status = 'refused',
           resend_message = pg_catalog.left(COALESCE(p_result ->> 'reason', 'Sem resposta da Sefaz.'), 500), alert_dismissed_at = NULL
     WHERE d.id = v_doc.id;
  ELSE
    RAISE EXCEPTION 'Alguns dados informados são inválidos.' USING ERRCODE = 'FA005', DETAIL = 'Resultado do reenvio.';
  END IF;
  RETURN v_kind;
END;
$$;


-- Entrada pública do resultado do reenvio: a rotina (sem usuário) ou quem pode reenviar a nota.
CREATE FUNCTION app.fiscal_resend_result_checked(p_document_id uuid, p_result jsonb) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF app.current_user_id() IS NULL THEN
    PERFORM app.require_fiscal_worker();
  ELSE
    PERFORM 1 FROM app.fiscal_action_context(p_document_id, 'resend');
  END IF;
  RETURN app.fiscal_apply_result(p_document_id, p_result);
END;
$$;

CREATE OR REPLACE FUNCTION app.fiscal_consult_result(p_document_id uuid, p_result jsonb) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM 1 FROM app.fiscal_action_context(p_document_id, 'consult');
  RETURN app.fiscal_apply_result(p_document_id, p_result);
END;
$$;


DROP FUNCTION app.fiscal_cancel_register(uuid, jsonb);
CREATE FUNCTION app.fiscal_cancel_apply(p_document_id uuid, p_event jsonb, p_permission text) RETURNS jsonb
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
     OR NOT app.has_permission(p_permission, v_doc.branch_id) THEN
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


-- Cancelamento pedido na tela (fiscal.cancel).
CREATE OR REPLACE FUNCTION app.fiscal_cancel_register(p_document_id uuid, p_event jsonb) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT app.fiscal_cancel_apply(p_document_id, p_event, 'fiscal.cancel')
$$;

-- Nota que a consulta mostra cancelada na Sefaz (feito fora daqui): quem pode consultar registra.
-- A venda só é desfeita sem bloqueio e no prazo (senão fica o aviso).
CREATE FUNCTION app.fiscal_consult_canceled(p_document_id uuid, p_event jsonb) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT app.fiscal_cancel_apply(p_document_id, p_event, 'sales.view')
$$;

CREATE OR REPLACE FUNCTION app.list_fiscal_documents(
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
         ((d.resend_status = 'refused' AND d.status IN ('rejected', 'pending', 'contingency')) OR d.cancel_note IS NOT NULL) AND d.alert_dismissed_at IS NULL,
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
     AND (NOT p_alerts OR (((d.resend_status = 'refused' AND d.status IN ('rejected', 'pending', 'contingency')) OR d.cancel_note IS NOT NULL) AND d.alert_dismissed_at IS NULL))
     AND (p_from IS NULL OR d.emitted_at >= p_from::timestamp AT TIME ZONE 'America/Sao_Paulo')
     AND (p_to IS NULL OR d.emitted_at < (p_to + 1)::timestamp AT TIME ZONE 'America/Sao_Paulo')
   ORDER BY d.emitted_at DESC, d.id DESC
   LIMIT 500
$$;


REVOKE ALL ON FUNCTION
  app.fiscal_apply_result(uuid, jsonb),
  app.fiscal_resend_result_checked(uuid, jsonb),
  app.fiscal_cancel_apply(uuid, jsonb, text),
  app.fiscal_cancel_register(uuid, jsonb),
  app.fiscal_consult_canceled(uuid, jsonb)
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  app.fiscal_resend_result_checked(uuid, jsonb),
  app.fiscal_cancel_register(uuid, jsonb),
  app.fiscal_consult_canceled(uuid, jsonb)
TO farmaerp_app;
