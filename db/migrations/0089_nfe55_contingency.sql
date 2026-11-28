-- Up Migration

-- Contingência da NF-e 55 na Sefaz Virtual (SVC): tpEmis 6 (SVC-AN) ou 7 (SVC-RS), automática por
-- nota quando a Sefaz da UF não responde (ou está parada). Vale para a NF-e de venda do caixa e para
-- as da central (devolução ao fornecedor e transferência). A NFC-e continua com 1 e 9.

-- ===== Nota do caixa (fiscal_document) =====
ALTER TABLE fiscal_document DROP CONSTRAINT fiscal_document_emission_type_check;
ALTER TABLE fiscal_document ADD CONSTRAINT fiscal_document_emission_type_check CHECK (emission_type IN (1, 6, 7, 9));
ALTER TABLE fiscal_document DROP CONSTRAINT fiscal_document_model_emission_check;
ALTER TABLE fiscal_document ADD CONSTRAINT fiscal_document_model_emission_check CHECK (
  (model = '65' AND emission_type IN (1, 9)) OR (model = '55' AND emission_type IN (1, 6, 7))
);

-- ===== Nota da central (central_nfe) =====
ALTER TABLE central_nfe
  ADD COLUMN emission_type smallint NOT NULL DEFAULT 1 CONSTRAINT central_nfe_emission_type_check CHECK (emission_type IN (1, 6, 7));

-- A chave muda quando a nota vai para a SVC (o tpEmis faz parte dela): deixa de ser imutável na
-- trava geral, e a guarda abaixo diz quando pode.
DROP TRIGGER block_immutable_columns ON central_nfe;
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON central_nfe
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'branch_id', 'kind', 'purchase_return_id', 'series', 'number', 'environment',
    'total_value', 'emitted_at', 'user_id', 'deleted_at'
  );

CREATE OR REPLACE FUNCTION app.guard_central_nfe() RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF OLD.status IN ('authorized', 'rejected') AND (NEW.status IS DISTINCT FROM OLD.status OR NEW.xml IS DISTINCT FROM OLD.xml) THEN
    RAISE EXCEPTION 'Esta NF-e já teve resposta da Sefaz e não muda mais.'
      USING ERRCODE = 'FA772', DETAIL = pg_catalog.format('central_nfe %s em %s.', OLD.id, OLD.status);
  END IF;
  -- Chave e forma de emissão só mudam uma vez: da normal para a SVC, com a nota ainda pendente.
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
         updated_by, trace_id, transfer_group, emission_type
    FROM central_nfe WHERE deleted_at IS NULL;

-- A nota pendente da central passa para a SVC: a mesma numeração, a chave e o XML novos. Quem pode
-- emitir a NF-e da filial; só a nota pendente e ainda normal.
CREATE FUNCTION app.central_nfe_contingency(p_id uuid, p_access_key text, p_xml text, p_emission_type smallint) RETURNS void
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
  UPDATE public.central_nfe n SET access_key = p_access_key, xml = p_xml, emission_type = p_emission_type WHERE n.id = note.id;
END;
$$;

-- A retransmissão da pendente precisa saber se ela está na SVC (o endereço muda).
DROP FUNCTION app.return_nfe_pending(uuid);
CREATE FUNCTION app.return_nfe_pending(p_return_id uuid)
RETURNS TABLE (id uuid, access_key text, environment smallint, xml text, state text, emission_type smallint)
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
    SELECT n.id, n.access_key, n.environment, n.xml, b.state::text, n.emission_type
      FROM public.central_nfe n JOIN public.branch b ON b.id = n.branch_id
     WHERE n.purchase_return_id = ret.id AND n.status = 'pending' AND n.deleted_at IS NULL;
END;
$$;

DROP FUNCTION app.transfer_nfe_pending(uuid);
CREATE FUNCTION app.transfer_nfe_pending(p_transfer uuid)
RETURNS TABLE (id uuid, access_key text, environment smallint, xml text, state text, emission_type smallint)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  moved record;
BEGIN
  SELECT * INTO moved FROM app.require_transfer_nfe(p_transfer);
  RETURN QUERY
    SELECT n.id, n.access_key, n.environment, n.xml, b.state::text, n.emission_type
      FROM public.central_nfe n JOIN public.branch b ON b.id = n.branch_id
     WHERE n.transfer_group = p_transfer AND n.status = 'pending' AND n.deleted_at IS NULL;
END;
$$;

REVOKE ALL ON FUNCTION app.central_nfe_contingency(uuid, text, text, smallint), app.return_nfe_pending(uuid),
  app.transfer_nfe_pending(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.central_nfe_contingency(uuid, text, text, smallint), app.return_nfe_pending(uuid),
  app.transfer_nfe_pending(uuid) TO farmaerp_app;
