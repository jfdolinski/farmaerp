-- Up Migration

-- Carta de correção eletrônica (CC-e, evento 110110) da NF-e modelo 55: a de venda (emitida no caixa)
-- e as da central (devolução ao fornecedor e transferência). Só pela retaguarda, por quem emite NF-e
-- na filial. Até 20 cartas por nota (limite da Sefaz); cada carta nova substitui as anteriores e
-- precisa trazer todas as correções. O texto vai para a Sefaz como está: de 15 a 1000 caracteres,
-- numa linha só, só com letras do português e sinais comuns (o que o leiaute aceita).

-- Texto aceito pela Sefaz (TString do leiaute: sem quebra de linha nem caractere de controle, sem
-- espaço nas pontas, até o ÿ).
CREATE FUNCTION app.nfe_correction_text_ok(p_text text) RETURNS boolean
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$
  SELECT p_text IS NOT NULL AND pg_catalog.length(p_text) BETWEEN 15 AND 1000 AND p_text = pg_catalog.btrim(p_text)
         AND p_text ~ '^[ -ÿ]+$'
$$;

CREATE TABLE nfe_correction (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  branch_id uuid NOT NULL REFERENCES branch (id),
  -- A nota corrigida: a de venda ou a da central (uma das duas).
  fiscal_document_id uuid REFERENCES fiscal_document (id),
  central_nfe_id uuid REFERENCES central_nfe (id),
  sequence smallint NOT NULL CONSTRAINT nfe_correction_sequence_check CHECK (sequence BETWEEN 1 AND 20),
  correction text NOT NULL CONSTRAINT nfe_correction_text_check CHECK (app.nfe_correction_text_ok(correction)),
  protocol text NOT NULL CONSTRAINT nfe_correction_protocol_check CHECK (protocol ~ '^[0-9]{15}$'),
  -- 135 registrada e vinculada à nota; 136 registrada, mas ainda não vinculada.
  status_code text NOT NULL CONSTRAINT nfe_correction_status_code_check CHECK (status_code IN ('135', '136')),
  xml text NOT NULL CONSTRAINT nfe_correction_xml_check CHECK (length(xml) BETWEEN 100 AND 200000),
  registered_at timestamptz NOT NULL,
  requested_by uuid NOT NULL REFERENCES user_account (id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid,
  CONSTRAINT nfe_correction_note_check CHECK ((fiscal_document_id IS NULL) <> (central_nfe_id IS NULL))
);
CREATE UNIQUE INDEX nfe_correction_sale_sequence_key ON nfe_correction (fiscal_document_id, sequence)
  WHERE deleted_at IS NULL AND fiscal_document_id IS NOT NULL;
CREATE UNIQUE INDEX nfe_correction_central_sequence_key ON nfe_correction (central_nfe_id, sequence)
  WHERE deleted_at IS NULL AND central_nfe_id IS NOT NULL;
CREATE INDEX nfe_correction_economic_group_id_idx ON nfe_correction (economic_group_id);
CREATE INDEX nfe_correction_branch_id_idx ON nfe_correction (branch_id);
CREATE INDEX nfe_correction_fiscal_document_id_idx ON nfe_correction (fiscal_document_id);
CREATE INDEX nfe_correction_central_nfe_id_idx ON nfe_correction (central_nfe_id);
CREATE INDEX nfe_correction_requested_by_idx ON nfe_correction (requested_by);
CALL app.apply_table_standard('public.nfe_correction');
-- Registrada na Sefaz, a carta não muda mais.
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON nfe_correction
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'branch_id', 'fiscal_document_id', 'central_nfe_id', 'sequence', 'correction', 'protocol', 'status_code',
    'xml', 'registered_at', 'requested_by'
  );
-- Vê a carta quem vê a nota.
CREATE POLICY nfe_correction_select ON nfe_correction FOR SELECT TO farmaerp_app
  USING (EXISTS (SELECT 1 FROM fiscal_document d WHERE d.id = nfe_correction.fiscal_document_id)
         OR EXISTS (SELECT 1 FROM central_nfe n WHERE n.id = nfe_correction.central_nfe_id));
CREATE VIEW v_nfe_correction WITH (security_invoker = true) AS SELECT * FROM nfe_correction WHERE deleted_at IS NULL;
GRANT SELECT ON nfe_correction, v_nfe_correction TO farmaerp_app;

-- A nota da carta: 'sale' (NF-e de venda) ou 'central' (devolução ou transferência). Não achou, é de
-- outro grupo ou quem pede não vê a nota: FA006. Para enviar (p_issue), precisa emitir NF-e na filial.
CREATE FUNCTION app.nfe_correction_note(p_kind text, p_id uuid, p_issue boolean,
  OUT economic_group_id uuid, OUT branch_id uuid, OUT status text, OUT model text, OUT access_key text, OUT environment smallint,
  OUT emission_type smallint, OUT series integer, OUT number bigint, OUT protocol text, OUT authorized_at timestamptz, OUT xml text,
  OUT note_kind text)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_view text;
BEGIN
  IF p_kind = 'sale' THEN
    SELECT d.economic_group_id, d.branch_id, d.status, d.model, d.access_key, d.environment, d.emission_type, d.series, d.number,
           d.protocol, d.authorized_at, d.xml, 'sale'
      INTO economic_group_id, branch_id, status, model, access_key, environment, emission_type, series, number,
           protocol, authorized_at, xml, note_kind
      FROM public.fiscal_document d WHERE d.id = p_id AND d.deleted_at IS NULL;
    v_view := 'sales.view';
  ELSIF p_kind = 'central' THEN
    SELECT n.economic_group_id, n.branch_id, n.status, '55', n.access_key, n.environment, n.emission_type, n.series, n.number,
           n.protocol, n.authorized_at, n.xml, n.kind
      INTO economic_group_id, branch_id, status, model, access_key, environment, emission_type, series, number,
           protocol, authorized_at, xml, note_kind
      FROM public.central_nfe n WHERE n.id = p_id AND n.deleted_at IS NULL;
    v_view := CASE note_kind WHEN 'transfer' THEN 'stock.view' ELSE 'purchases.view' END;
  ELSE
    RAISE EXCEPTION 'Alguns dados informados são inválidos.' USING ERRCODE = 'FA005', DETAIL = pg_catalog.format('Tipo de nota %s.', p_kind);
  END IF;
  IF economic_group_id IS NULL OR economic_group_id <> app.current_user_group() OR NOT app.has_permission(v_view, branch_id) THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.' USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('%s %s.', p_kind, p_id);
  END IF;
  IF p_issue AND NOT app.has_permission('fiscal.nfe_issue', branch_id) THEN
    RAISE EXCEPTION 'Você não tem permissão para esta operação.'
      USING ERRCODE = 'FA002', DETAIL = pg_catalog.format('fiscal.nfe_issue na filial %s.', branch_id);
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION app.nfe_correction_note(text, uuid, boolean) FROM PUBLIC;

-- Cartas já registradas da nota.
CREATE FUNCTION app.nfe_correction_count(p_kind text, p_id uuid) RETURNS integer
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT pg_catalog.count(*)::integer FROM public.nfe_correction c
   WHERE c.deleted_at IS NULL AND CASE p_kind WHEN 'sale' THEN c.fiscal_document_id ELSE c.central_nfe_id END = p_id
$$;
REVOKE ALL ON FUNCTION app.nfe_correction_count(text, uuid) FROM PUBLIC;

-- O que a carta precisa para ir à Sefaz: a NF-e 55 autorizada, o texto aceito, menos de 20 cartas,
-- a sequência da próxima e o certificado da filial (para assinar o evento).
CREATE FUNCTION app.nfe_correction_context(p_kind text, p_id uuid, p_text text) RETURNS TABLE (
  id uuid, company_id uuid, status text, access_key text, environment smallint, protocol text, cnpj text, state text,
  encrypted_pfx bytea, encrypted_password bytea, model text, emission_type smallint, sequence integer
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  note record;
  v_count integer;
BEGIN
  SELECT * INTO note FROM app.nfe_correction_note(p_kind, p_id, true);
  IF note.model <> '55' OR note.status <> 'authorized' THEN
    RAISE EXCEPTION 'Esta NF-e não está numa situação que permita a operação.'
      USING ERRCODE = 'FA787', DETAIL = pg_catalog.format('Modelo %s, %s.', note.model, note.status);
  END IF;
  IF NOT app.nfe_correction_text_ok(p_text) THEN
    RAISE EXCEPTION 'O texto da correção precisa ter de 15 a 1000 caracteres, numa linha só e sem símbolos especiais.'
      USING ERRCODE = 'FA790', DETAIL = pg_catalog.format('%s caracteres.', pg_catalog.length(p_text));
  END IF;
  v_count := app.nfe_correction_count(p_kind, p_id);
  IF v_count >= 20 THEN
    RAISE EXCEPTION 'Esta NF-e já tem 20 cartas de correção, o limite da Sefaz.' USING ERRCODE = 'FA789', DETAIL = pg_catalog.format('%s %s.', p_kind, p_id);
  END IF;
  RETURN QUERY
    SELECT p_id, b.company_id, note.status, note.access_key, note.environment, note.protocol, b.cnpj::text, b.state::text,
           bc.encrypted_pfx, bc.encrypted_password, note.model, note.emission_type,
           (SELECT COALESCE(pg_catalog.max(c.sequence), 0) + 1 FROM public.nfe_correction c
             WHERE c.deleted_at IS NULL AND CASE p_kind WHEN 'sale' THEN c.fiscal_document_id ELSE c.central_nfe_id END = p_id)::integer
      FROM public.branch b
      LEFT JOIN public.branch_certificate bc ON bc.branch_id = b.id AND bc.deleted_at IS NULL
     WHERE b.id = note.branch_id;
END;
$$;

-- Carta registrada na Sefaz. Pedido repetido (o mesmo protocolo) devolve a mesma carta; outra carta
-- com a mesma sequência (dois envios ao mesmo tempo) é FA791. A nota pode ter sido cancelada enquanto
-- a carta ia: o que a Sefaz registrou fica registrado aqui também.
CREATE FUNCTION app.nfe_correction_register(p_kind text, p_id uuid, p_event jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  note record;
  v_sequence integer := (p_event ->> 'sequence')::integer;
  v_existing public.nfe_correction;
  v_id uuid;
BEGIN
  -- Uma carta por vez em cada nota.
  IF p_kind = 'sale' THEN
    PERFORM 1 FROM public.fiscal_document d WHERE d.id = p_id FOR UPDATE;
  ELSIF p_kind = 'central' THEN
    PERFORM 1 FROM public.central_nfe n WHERE n.id = p_id FOR UPDATE;
  END IF;
  SELECT * INTO note FROM app.nfe_correction_note(p_kind, p_id, true);
  IF note.model <> '55' OR note.status NOT IN ('authorized', 'canceled') THEN
    RAISE EXCEPTION 'Esta NF-e não está numa situação que permita a operação.'
      USING ERRCODE = 'FA787', DETAIL = pg_catalog.format('Modelo %s, %s.', note.model, note.status);
  END IF;
  SELECT * INTO v_existing FROM public.nfe_correction c
   WHERE c.deleted_at IS NULL AND c.sequence = v_sequence
     AND CASE p_kind WHEN 'sale' THEN c.fiscal_document_id ELSE c.central_nfe_id END = p_id;
  IF v_existing.id IS NOT NULL THEN
    IF v_existing.protocol = p_event ->> 'protocol' THEN
      RETURN v_existing.id;
    END IF;
    RAISE EXCEPTION 'Outra carta de correção foi registrada nesta NF-e ao mesmo tempo.'
      USING ERRCODE = 'FA791', DETAIL = pg_catalog.format('%s %s, sequência %s.', p_kind, p_id, v_sequence);
  END IF;
  INSERT INTO public.nfe_correction (economic_group_id, branch_id, fiscal_document_id, central_nfe_id, sequence, correction, protocol,
                                     status_code, xml, registered_at, requested_by)
  VALUES (note.economic_group_id, note.branch_id, CASE p_kind WHEN 'sale' THEN p_id END, CASE p_kind WHEN 'central' THEN p_id END,
          v_sequence, p_event ->> 'correction', p_event ->> 'protocol', p_event ->> 'status_code', p_event ->> 'xml',
          (p_event ->> 'registered_at')::timestamptz, app.current_user_id())
  RETURNING nfe_correction.id INTO v_id;
  RETURN v_id;
END;
$$;

-- A tela da carta: a nota, se dá para enviar outra e as cartas já registradas (a última vale).
CREATE FUNCTION app.nfe_corrections(p_kind text, p_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  note record;
  v_count integer;
BEGIN
  SELECT * INTO note FROM app.nfe_correction_note(p_kind, p_id, false);
  v_count := app.nfe_correction_count(p_kind, p_id);
  RETURN pg_catalog.jsonb_build_object(
    'kind', p_kind, 'id', p_id, 'note_kind', note.note_kind, 'model', note.model, 'status', note.status, 'series', note.series,
    'number', note.number, 'access_key', note.access_key, 'authorized_at', note.authorized_at, 'count', v_count,
    'can_send', note.model = '55' AND note.status = 'authorized' AND v_count < 20 AND app.has_permission('fiscal.nfe_issue', note.branch_id),
    'corrections', COALESCE((
      SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
               'id', c.id, 'sequence', c.sequence, 'correction', c.correction, 'protocol', c.protocol, 'status_code', c.status_code,
               'registered_at', c.registered_at, 'requested_by', u.name) ORDER BY c.sequence DESC)
        FROM public.nfe_correction c
        LEFT JOIN public.user_account u ON u.id = c.requested_by
       WHERE c.deleted_at IS NULL AND CASE p_kind WHEN 'sale' THEN c.fiscal_document_id ELSE c.central_nfe_id END = p_id
    ), '[]'::jsonb));
END;
$$;

-- Arquivos de uma carta (XML do evento e, para o PDF, o XML da nota): quem vê a nota.
CREATE FUNCTION app.nfe_correction_file(p_correction_id uuid) RETURNS TABLE (access_key text, sequence integer, xml text, nfe_xml text)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_row public.nfe_correction;
  note record;
BEGIN
  SELECT * INTO v_row FROM public.nfe_correction c WHERE c.id = p_correction_id AND c.deleted_at IS NULL;
  IF v_row.id IS NULL THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.' USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('nfe_correction %s.', p_correction_id);
  END IF;
  SELECT * INTO note FROM app.nfe_correction_note(CASE WHEN v_row.fiscal_document_id IS NOT NULL THEN 'sale' ELSE 'central' END,
                                                  COALESCE(v_row.fiscal_document_id, v_row.central_nfe_id), false);
  RETURN QUERY SELECT note.access_key, v_row.sequence::integer, v_row.xml, note.xml;
END;
$$;

REVOKE ALL ON FUNCTION app.nfe_correction_context(text, uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.nfe_correction_register(text, uuid, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.nfe_corrections(text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.nfe_correction_file(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.nfe_correction_context(text, uuid, text) TO farmaerp_app;
GRANT EXECUTE ON FUNCTION app.nfe_correction_register(text, uuid, jsonb) TO farmaerp_app;
GRANT EXECUTE ON FUNCTION app.nfe_corrections(text, uuid) TO farmaerp_app;
GRANT EXECUTE ON FUNCTION app.nfe_correction_file(uuid) TO farmaerp_app;
