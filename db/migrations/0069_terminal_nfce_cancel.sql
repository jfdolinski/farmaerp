-- Up Migration

-- 8A-3c (central): o caixa pede à central o cancelamento da NFC-e de uma venda dele. A central
-- conversa com a Sefaz e desfaz a venda, com as mesmas regras da retaguarda (até 30 minutos,
-- bloqueios da venda). Quem libera é um supervisor com "Cancelar NFC-e" na filial, conferido no
-- caixa pelo PIN e aqui pela permissão. Pedido repetido (o caixa não viu a resposta) responde que
-- já está cancelada.

-- Supervisor ativo do grupo do terminal com fiscal.cancel na filial.
CREATE FUNCTION app.require_cancel_supervisor(p_terminal public.terminal, p_supervisor_id uuid) RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF p_supervisor_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.user_account u
      JOIN public.branch b ON b.id = p_terminal.branch_id
      JOIN public.company c ON c.id = b.company_id
     WHERE u.id = p_supervisor_id AND u.economic_group_id = c.economic_group_id AND u.deleted_at IS NULL AND u.is_active
  ) OR NOT app.user_has_permission(p_supervisor_id, 'fiscal.cancel', p_terminal.branch_id) THEN
    RAISE EXCEPTION 'Você não tem permissão para esta operação.'
      USING ERRCODE = 'FA002', DETAIL = 'Cancelamento no caixa sem supervisor com fiscal.cancel.';
  END IF;
END;
$$;

-- Nota deste terminal, travada para a operação.
CREATE FUNCTION app.terminal_fiscal_document(p_terminal public.terminal, p_document_id uuid) RETURNS public.fiscal_document
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_doc public.fiscal_document;
BEGIN
  SELECT * INTO v_doc FROM public.fiscal_document d
   WHERE d.id = p_document_id AND d.terminal_id = p_terminal.id AND d.deleted_at IS NULL
   FOR UPDATE;
  IF v_doc.id IS NULL THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.' USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('fiscal_document %s.', p_document_id);
  END IF;
  RETURN v_doc;
END;
$$;

-- Contexto do cancelamento pedido pelo caixa (com o certificado selado). Nota já cancelada volta
-- com status "canceled" (a API responde que já está feito).
CREATE FUNCTION app.terminal_cancel_context(p_document_id uuid, p_supervisor_id uuid) RETURNS TABLE (
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

-- Cancelamento registrado na Sefaz a pedido do caixa: evento com o terminal e o supervisor, nota
-- cancelada e a venda desfeita (sem bloqueio e no prazo; senão fica o aviso, como na retaguarda).
CREATE FUNCTION app.terminal_cancel_register(p_document_id uuid, p_supervisor_id uuid, p_event jsonb) RETURNS jsonb
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
  RETURN app.cancel_sale_effects(v_sale, p_supervisor_id, p_event ->> 'reason');
END;
$$;

REVOKE ALL ON FUNCTION
  app.require_cancel_supervisor(public.terminal, uuid),
  app.terminal_fiscal_document(public.terminal, uuid),
  app.terminal_cancel_context(uuid, uuid),
  app.terminal_cancel_register(uuid, uuid, jsonb)
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  app.terminal_cancel_context(uuid, uuid),
  app.terminal_cancel_register(uuid, uuid, jsonb)
TO farmaerp_app;
