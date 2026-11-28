-- Up Migration

-- NF-e 55 de venda (emitida no caixa) pela central: reenvio, consulta e cancelamento passam a valer,
-- com os serviços da NF-e (a API escolhe o endereço pelo modelo e pela forma de emissão). Cancelar a
-- NF-e desfaz a venda junto, como na NFC-e, mas o prazo é de 24 horas (a NFC-e segue com 30 minutos).
-- O caixa continua sem cancelar a NF-e (FA780 em app.terminal_cancel_context) até a próxima etapa.

-- Prazo do cancelamento contado da autorização, pelo modelo.
CREATE FUNCTION app.fiscal_cancel_window(p_model text) RETURNS interval
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$
  SELECT CASE p_model WHEN '55' THEN interval '24 hours' ELSE interval '30 minutes' END
$$;

-- Contexto da ação diz o modelo e a forma de emissão (a NF-e em SVC fala com a SVC).
DROP FUNCTION app.fiscal_action_context(uuid, text);
CREATE FUNCTION app.fiscal_action_context(p_document_id uuid, p_action text) RETURNS TABLE (
  id uuid, economic_group_id uuid, branch_id uuid, company_id uuid, sale_id uuid, status text, access_key text, environment smallint,
  series integer, number bigint, protocol text, xml text, authorized_at timestamptz, cnpj text, state text,
  encrypted_pfx bytea, encrypted_password bytea, model text, emission_type smallint
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
  ELSIF p_action = 'resend' AND v_doc.status NOT IN ('pending', 'contingency', 'rejected') THEN
    IF v_doc.model = '55' THEN
      RAISE EXCEPTION 'Esta NF-e não está numa situação que permita a operação.' USING ERRCODE = 'FA787', DETAIL = v_doc.status;
    END IF;
    RAISE EXCEPTION 'Esta NFC-e não está numa situação que permita a operação.' USING ERRCODE = 'FA753', DETAIL = v_doc.status;
  ELSIF p_action NOT IN ('cancel', 'resend', 'consult') THEN
    RAISE EXCEPTION 'Alguns dados informados são inválidos.' USING ERRCODE = 'FA005', DETAIL = p_action;
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

-- Registro do cancelamento: a venda é desfeita no prazo do modelo (com 5 minutos de folga para a ida
-- à Sefaz). Fora do prazo ou com bloqueio, a nota fica cancelada e a venda vira aviso.
CREATE OR REPLACE FUNCTION app.fiscal_cancel_apply(p_document_id uuid, p_event jsonb, p_permission text) RETURNS jsonb
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
    v_effects := app.cancel_sale_effects(v_sale, v_user, p_event ->> 'reason');
  END IF;
  RETURN COALESCE(v_effects, '{}'::jsonb);
END;
$$;

-- A lista diz até quando cada nota pode ser cancelada (NF-e: 24 horas).
CREATE OR REPLACE FUNCTION app.list_fiscal_documents(
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
         CASE WHEN d.status = 'authorized' AND d.authorized_at > pg_catalog.now() - app.fiscal_cancel_window(d.model)
              THEN d.authorized_at + app.fiscal_cancel_window(d.model) END
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

REVOKE ALL ON FUNCTION app.fiscal_cancel_window(text), app.fiscal_action_context(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.fiscal_action_context(uuid, text) TO farmaerp_app;
