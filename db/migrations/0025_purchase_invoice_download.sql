-- Up Migration

-- Download automático das NF-e de compra pela distribuição da Sefaz (Ambiente Nacional), ciência da
-- operação e confirmação de cada nota pela Sefaz. A API conversa com a Sefaz; aqui ficam o estado de
-- cada filial, o que chegou e as regras de confirmação e cancelamento.
--
-- Quem chama as funções do download é a rotina da própria API, sem usuário: elas exigem o contexto
-- app.worker = 'dfe' e nenhum usuário na sessão, para uma requisição comum nunca chegar nelas.

-- Confirmação pela Sefaz: o resumo da assinatura (digest) do XML é comparado com o que a Sefaz
-- informa. Em produção a nota só se lança confirmada; fora dela, a confirmação só aparece na tela.
ALTER TABLE purchase_invoice
  ADD COLUMN digest text CONSTRAINT purchase_invoice_digest_check CHECK (digest ~ '^([A-Za-z0-9+/]{27}=|[A-Za-z0-9+/]{43}=)$'),
  ADD COLUMN source text NOT NULL DEFAULT 'manual' CONSTRAINT purchase_invoice_source_check CHECK (source IN ('manual', 'download')),
  ADD COLUMN confirmation_required boolean NOT NULL DEFAULT false,
  ADD COLUMN confirmation text NOT NULL DEFAULT 'pending' CONSTRAINT purchase_invoice_confirmation_check CHECK (
    confirmation IN ('pending', 'confirmed', 'mismatch', 'unavailable')
  ),
  ADD COLUMN confirmed_at timestamptz,
  ADD COLUMN confirmation_message text CONSTRAINT purchase_invoice_confirmation_message_check CHECK (
    btrim(confirmation_message) <> '' AND length(confirmation_message) <= 500
  ),
  ADD COLUMN cancelled_at timestamptz,
  ADD COLUMN last_query_at timestamptz,
  ADD CONSTRAINT purchase_invoice_confirmed_check CHECK ((confirmation = 'confirmed') = (confirmed_at IS NOT NULL));

-- Cancelada pelo emitente: a nota em conferência não se lança mais. A já lançada fica lançada, com alerta.
ALTER TABLE purchase_invoice DROP CONSTRAINT purchase_invoice_status_check;
ALTER TABLE purchase_invoice ADD CONSTRAINT purchase_invoice_status_check CHECK (status IN ('review', 'not_postable', 'posted', 'cancelled'));

-- A view com SELECT * congela as colunas: recria para mostrar as novas.
CREATE OR REPLACE VIEW v_purchase_invoice WITH (security_invoker = true) AS
  SELECT * FROM purchase_invoice WHERE deleted_at IS NULL;

DROP TRIGGER block_immutable_columns ON purchase_invoice;
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON purchase_invoice
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'branch_id', 'supplier_id', 'access_key', 'series', 'number', 'issued_at', 'operation_type',
    'purpose', 'environment', 'protocol_number', 'authorized_at', 'emitter_cnpj', 'emitter_name', 'products_total',
    'discount_total', 'freight_total', 'insurance_total', 'other_total', 'ipi_total', 'st_total', 'invoice_total',
    'digest', 'source', 'confirmation_required'
  );

-- Vale para qualquer caminho de escrita: nota que exige confirmação só vira lançada confirmada.
CREATE FUNCTION app.validate_invoice_confirmation() RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF NEW.confirmation_required AND NEW.confirmation <> 'confirmed' THEN
    RAISE EXCEPTION 'Esta nota ainda não foi confirmada pela Sefaz.'
      USING ERRCODE = 'FA942', DETAIL = pg_catalog.format('purchase_invoice %s em %s.', NEW.id, NEW.confirmation);
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER validate_invoice_confirmation BEFORE UPDATE OF status ON purchase_invoice
  FOR EACH ROW WHEN (NEW.status = 'posted' AND OLD.status IS DISTINCT FROM 'posted')
  EXECUTE FUNCTION app.validate_invoice_confirmation();

-- Estado do download por filial: ligado, último NSU e quando pode buscar de novo.
CREATE TABLE branch_dfe_sync (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  branch_id uuid NOT NULL REFERENCES branch (id),
  enabled boolean NOT NULL DEFAULT false,
  last_nsu text NOT NULL DEFAULT '000000000000000' CONSTRAINT branch_dfe_sync_last_nsu_check CHECK (last_nsu ~ '^[0-9]{15}$'),
  max_nsu text CONSTRAINT branch_dfe_sync_max_nsu_check CHECK (max_nsu ~ '^[0-9]{15}$'),
  next_run_at timestamptz NOT NULL DEFAULT now(),
  -- Reserva da rodada: duas instâncias da API não buscam a mesma filial ao mesmo tempo.
  locked_until timestamptz,
  last_run_at timestamptz,
  last_status text CONSTRAINT branch_dfe_sync_last_status_check CHECK (last_status ~ '^[0-9]{3}$'),
  last_message text CONSTRAINT branch_dfe_sync_last_message_check CHECK (length(last_message) <= 500),
  last_error text CONSTRAINT branch_dfe_sync_last_error_check CHECK (last_error ~ '^FA[0-9]{3}$'),
  -- Consultas por chave na hora corrente: a Sefaz aceita 20; a rotina para em 15.
  query_window_start timestamptz,
  query_count smallint NOT NULL DEFAULT 0 CONSTRAINT branch_dfe_sync_query_count_check CHECK (query_count >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE UNIQUE INDEX branch_dfe_sync_branch_key ON branch_dfe_sync (branch_id) WHERE deleted_at IS NULL;
CREATE INDEX branch_dfe_sync_due_idx ON branch_dfe_sync (next_run_at) WHERE enabled AND deleted_at IS NULL;
CALL app.apply_table_standard('public.branch_dfe_sync');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON branch_dfe_sync
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns('economic_group_id', 'branch_id');

-- O que a Sefaz entregou, do jeito que veio, uma vez por NSU.
CREATE TABLE dfe_document (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  branch_id uuid NOT NULL REFERENCES branch (id),
  nsu text NOT NULL CONSTRAINT dfe_document_nsu_check CHECK (nsu ~ '^[0-9]{15}$'),
  schema text NOT NULL CONSTRAINT dfe_document_schema_check CHECK (schema ~ '^[A-Za-z]{1,30}_v[0-9]{1,2}\.[0-9]{2}$'),
  -- Documento sem chave (um tipo novo da Sefaz, por exemplo) também fica guardado.
  access_key text CONSTRAINT dfe_document_access_key_check CHECK (access_key IS NULL OR app.is_valid_access_key(access_key)),
  xml text NOT NULL CONSTRAINT dfe_document_xml_check CHECK (length(xml) BETWEEN 1 AND 5242880),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE UNIQUE INDEX dfe_document_nsu_key ON dfe_document (branch_id, nsu) WHERE deleted_at IS NULL;
CREATE INDEX dfe_document_access_key_idx ON dfe_document (access_key) WHERE access_key IS NOT NULL;
CALL app.apply_table_standard('public.dfe_document');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON dfe_document
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'branch_id', 'nsu', 'schema', 'access_key', 'xml', 'deleted_at'
  );

-- Resumo da nota (resNFe): o que a Sefaz mostra antes da ciência, e a base da confirmação.
CREATE TABLE purchase_invoice_summary (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  branch_id uuid NOT NULL REFERENCES branch (id),
  access_key text NOT NULL CONSTRAINT purchase_invoice_summary_access_key_check CHECK (app.is_valid_access_key(access_key)),
  emitter_document text NOT NULL CONSTRAINT purchase_invoice_summary_emitter_document_check CHECK (
    emitter_document ~ '^([0-9]{11}|[0-9A-Z]{12}[0-9]{2})$'
  ),
  emitter_name text NOT NULL CONSTRAINT purchase_invoice_summary_emitter_name_check CHECK (btrim(emitter_name) <> '' AND length(emitter_name) <= 150),
  issued_at timestamptz NOT NULL,
  operation_type smallint NOT NULL CONSTRAINT purchase_invoice_summary_operation_type_check CHECK (operation_type IN (0, 1)),
  total numeric(15, 2) NOT NULL CONSTRAINT purchase_invoice_summary_total_check CHECK (total >= 0),
  digest text NOT NULL CONSTRAINT purchase_invoice_summary_digest_check CHECK (digest ~ '^([A-Za-z0-9+/]{27}=|[A-Za-z0-9+/]{43}=)$'),
  protocol_number text CONSTRAINT purchase_invoice_summary_protocol_check CHECK (protocol_number ~ '^[0-9]{15}$'),
  -- cSitNFe: 1 autorizada, 2 denegada, 3 cancelada.
  situation smallint NOT NULL CONSTRAINT purchase_invoice_summary_situation_check CHECK (situation IN (1, 2, 3)),
  awareness_at timestamptz,
  awareness_by uuid REFERENCES user_account (id),
  awareness_protocol text CONSTRAINT purchase_invoice_summary_awareness_protocol_check CHECK (awareness_protocol ~ '^[0-9]{15}$'),
  invoice_id uuid REFERENCES purchase_invoice (id),
  last_query_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid,
  CONSTRAINT purchase_invoice_summary_awareness_check CHECK ((awareness_at IS NULL) = (awareness_by IS NULL))
);
CREATE UNIQUE INDEX purchase_invoice_summary_key ON purchase_invoice_summary (branch_id, access_key) WHERE deleted_at IS NULL;
CREATE INDEX purchase_invoice_summary_waiting_idx ON purchase_invoice_summary (branch_id, issued_at DESC)
  WHERE invoice_id IS NULL AND deleted_at IS NULL;
CALL app.apply_table_standard('public.purchase_invoice_summary');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON purchase_invoice_summary
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'branch_id', 'access_key', 'emitter_document', 'emitter_name', 'issued_at', 'operation_type',
    'total', 'digest'
  );

-- Só a rotina de download da API: sem usuário na sessão e com o contexto dela.
CREATE FUNCTION app.require_dfe_worker() RETURNS void
LANGUAGE plpgsql STABLE
SET search_path = ''
AS $$
BEGIN
  IF app.current_user_id() IS NOT NULL OR COALESCE(pg_catalog.current_setting('app.worker', true), '') <> 'dfe' THEN
    RAISE EXCEPTION 'Você não tem permissão para esta operação.'
      USING ERRCODE = 'FA002', DETAIL = 'Função da rotina de download chamada fora dela.';
  END IF;
END;
$$;

-- Filial da nota pelo CNPJ do destinatário, dentro do grupo.
CREATE FUNCTION app.invoice_branch(p_group_id uuid, p_cnpj text) RETURNS public.branch
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.branch;
BEGIN
  SELECT b.* INTO target FROM public.branch b
    JOIN public.company c ON c.id = b.company_id AND c.deleted_at IS NULL
   WHERE c.economic_group_id = p_group_id AND b.cnpj = app.clean_document(p_cnpj) AND b.deleted_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Esta nota não é de uma filial da rede.'
      USING ERRCODE = 'FA927', DETAIL = 'Destinatário fora do grupo.';
  END IF;
  RETURN target;
END;
$$;

-- Grava a nota já conferida pela API. Quem chama confere a permissão antes.
CREATE FUNCTION app.store_purchase_invoice(
  p_group_id uuid, p_branch public.branch, p_data jsonb, p_xml text, p_sha256 text, p_source text, p_requires_confirmation boolean
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  emitter_cnpj text := app.clean_document(p_data #>> '{emitter,cnpj}');
  supplier_id uuid;
  reason text;
  new_invoice_id uuid;
  item jsonb;
  item_id uuid;
  batch jsonb;
BEGIN
  reason := CASE
    WHEN EXISTS (
      SELECT 1 FROM public.branch b JOIN public.company c ON c.id = b.company_id
       WHERE c.economic_group_id = p_group_id AND b.cnpj = emitter_cnpj AND b.deleted_at IS NULL
    ) THEN 'own_branch'
    WHEN (p_data ->> 'operationType')::smallint = 0 THEN 'entry'
    WHEN (p_data ->> 'purpose')::smallint <> 1 THEN 'purpose'
  END;
  supplier_id := app.supplier_for_invoice(p_group_id, p_data -> 'emitter');

  INSERT INTO public.purchase_invoice (
    economic_group_id, branch_id, supplier_id, access_key, series, number, issued_at, operation_type, purpose,
    environment, protocol_number, authorized_at, emitter_cnpj, emitter_name, products_total, discount_total,
    freight_total, insurance_total, other_total, ipi_total, st_total, invoice_total, status, not_postable_reason,
    digest, source, confirmation_required, confirmation, confirmed_at
  ) VALUES (
    p_group_id, p_branch.id, supplier_id, COALESCE(p_data ->> 'accessKey', ''), (p_data ->> 'series')::integer,
    (p_data ->> 'number')::bigint, (p_data ->> 'issuedAt')::timestamptz, (p_data ->> 'operationType')::smallint,
    (p_data ->> 'purpose')::smallint, (p_data ->> 'environment')::smallint, COALESCE(p_data ->> 'protocolNumber', ''),
    (p_data ->> 'authorizedAt')::timestamptz, COALESCE(emitter_cnpj, ''),
    COALESCE(pg_catalog.left(app.clean_text(p_data #>> '{emitter,legalName}'), 150), ''),
    (p_data #>> '{totals,products}')::numeric, COALESCE((p_data #>> '{totals,discount}')::numeric, 0),
    COALESCE((p_data #>> '{totals,freight}')::numeric, 0), COALESCE((p_data #>> '{totals,insurance}')::numeric, 0),
    COALESCE((p_data #>> '{totals,other}')::numeric, 0), COALESCE((p_data #>> '{totals,ipi}')::numeric, 0),
    COALESCE((p_data #>> '{totals,st}')::numeric, 0), (p_data #>> '{totals,invoice}')::numeric,
    CASE WHEN reason IS NULL THEN 'review' ELSE 'not_postable' END, reason,
    p_data ->> 'digest', p_source, p_requires_confirmation,
    -- O XML que veio da própria Sefaz já está confirmado.
    CASE WHEN p_source = 'download' THEN 'confirmed' ELSE 'pending' END,
    CASE WHEN p_source = 'download' THEN pg_catalog.clock_timestamp() END
  ) RETURNING id INTO new_invoice_id;

  INSERT INTO public.purchase_invoice_document (economic_group_id, branch_id, invoice_id, xml, sha256)
  VALUES (p_group_id, p_branch.id, new_invoice_id, p_xml, p_sha256);

  FOR item IN SELECT value FROM pg_catalog.jsonb_array_elements(COALESCE(p_data -> 'items', '[]')) AS value LOOP
    INSERT INTO public.purchase_invoice_item (
      economic_group_id, branch_id, invoice_id, item_number, supplier_code, barcode, tax_barcode, description, ncm, cest,
      cfop, unit, quantity, unit_price, products_value, discount_value, freight_value, insurance_value, other_value,
      ipi_value, st_value, fcp_st_value, anvisa_code, pmc
    ) VALUES (
      p_group_id, p_branch.id, new_invoice_id, (item ->> 'number')::smallint, COALESCE(app.clean_text(item ->> 'supplierCode'), ''),
      app.clean_text(item ->> 'barcode'), app.clean_text(item ->> 'taxBarcode'),
      COALESCE(pg_catalog.left(app.clean_text(item ->> 'description'), 120), ''), app.clean_text(item ->> 'ncm'),
      app.clean_text(item ->> 'cest'), COALESCE(item ->> 'cfop', ''), COALESCE(pg_catalog.left(app.clean_text(item ->> 'unit'), 6), ''),
      (item ->> 'quantity')::numeric, (item ->> 'unitPrice')::numeric, (item ->> 'productsValue')::numeric,
      COALESCE((item ->> 'discount')::numeric, 0), COALESCE((item ->> 'freight')::numeric, 0),
      COALESCE((item ->> 'insurance')::numeric, 0), COALESCE((item ->> 'other')::numeric, 0),
      COALESCE((item ->> 'ipi')::numeric, 0), COALESCE((item ->> 'st')::numeric, 0), COALESCE((item ->> 'fcpSt')::numeric, 0),
      pg_catalog.upper(app.clean_text(item ->> 'anvisaCode')), (item ->> 'pmc')::numeric
    ) RETURNING id INTO item_id;
    FOR batch IN SELECT value FROM pg_catalog.jsonb_array_elements(COALESCE(item -> 'batches', '[]')) AS value LOOP
      INSERT INTO public.purchase_invoice_item_batch (
        economic_group_id, branch_id, item_id, batch_number, quantity, manufactured_on, expires_on
      ) VALUES (
        p_group_id, p_branch.id, item_id, pg_catalog.upper(COALESCE(app.clean_text(batch ->> 'number'), '')),
        (batch ->> 'quantity')::numeric, (batch ->> 'manufacturedOn')::date, (batch ->> 'expiresOn')::date
      );
    END LOOP;
    -- Nota fora do estoque não se liga: fica só registrada.
    IF reason IS NULL THEN
      PERFORM app.match_purchase_item(item_id);
    END IF;
  END LOOP;
  IF NOT EXISTS (SELECT 1 FROM public.purchase_invoice_item it WHERE it.invoice_id = new_invoice_id) THEN
    RAISE EXCEPTION 'Os dados da nota são inválidos.'
      USING ERRCODE = 'FA931', DETAIL = 'Nota sem itens.';
  END IF;
  RETURN new_invoice_id;
END;
$$;

-- Cancelamento informado pela Sefaz.
CREATE FUNCTION app.cancel_invoice_by_sefaz(p_invoice_id uuid) RETURNS void
LANGUAGE sql SECURITY DEFINER
SET search_path = ''
AS $$
  UPDATE public.purchase_invoice
     SET cancelled_at = COALESCE(cancelled_at, pg_catalog.clock_timestamp()),
         status = CASE WHEN status = 'review' THEN 'cancelled' ELSE status END
   WHERE id = p_invoice_id AND deleted_at IS NULL
$$;

-- Compara a nota com o resumo da Sefaz: mesma assinatura confirma; outra, ou nota denegada,
-- marca a diferença; cancelada cancela. Liga o resumo à nota.
CREATE FUNCTION app.apply_invoice_summary(p_summary_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  summary public.purchase_invoice_summary;
  invoice public.purchase_invoice;
BEGIN
  SELECT * INTO summary FROM public.purchase_invoice_summary s WHERE s.id = p_summary_id;
  SELECT * INTO invoice FROM public.purchase_invoice i
   WHERE i.economic_group_id = summary.economic_group_id AND i.access_key = summary.access_key AND i.deleted_at IS NULL;
  IF NOT FOUND THEN
    RETURN;
  END IF;
  UPDATE public.purchase_invoice_summary SET invoice_id = invoice.id
   WHERE id = summary.id AND invoice_id IS DISTINCT FROM invoice.id;
  IF summary.situation = 3 THEN
    PERFORM app.cancel_invoice_by_sefaz(invoice.id);
  ELSIF invoice.confirmation <> 'confirmed' THEN
    IF summary.situation = 1 AND invoice.digest = summary.digest THEN
      UPDATE public.purchase_invoice
         SET confirmation = 'confirmed', confirmed_at = pg_catalog.clock_timestamp(), confirmation_message = NULL
       WHERE id = invoice.id;
    ELSE
      UPDATE public.purchase_invoice
         SET confirmation = 'mismatch',
             confirmation_message = CASE WHEN summary.situation = 2 THEN 'A Sefaz informa que esta nota foi denegada.'
                                         ELSE 'O XML importado é diferente do que a Sefaz autorizou.' END
       WHERE id = invoice.id;
    END IF;
  END IF;
END;
$$;

-- Importação manual: a do PR anterior, agora guardando o resumo da assinatura e conferindo com o
-- resumo da Sefaz que já tiver chegado. Em produção (p_accepts_test falso) a nota exige confirmação.
CREATE OR REPLACE FUNCTION app.import_purchase_invoice(p_data jsonb, p_xml text, p_sha256 text, p_accepts_test boolean) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.current_user_group();
  target_branch public.branch := app.invoice_branch(app.current_user_group(), p_data ->> 'destCnpj');
  new_invoice_id uuid;
  summary_id uuid;
BEGIN
  PERFORM app.require_invoice_branch(target_branch.id);
  IF (p_data ->> 'environment')::smallint = 2 AND NOT p_accepts_test THEN
    RAISE EXCEPTION 'Esta nota é do ambiente de teste da Sefaz.'
      USING ERRCODE = 'FA928', DETAIL = pg_catalog.format('Filial %s.', target_branch.id);
  END IF;
  new_invoice_id := app.store_purchase_invoice(group_id, target_branch, p_data, p_xml, p_sha256, 'manual', NOT p_accepts_test);
  SELECT s.id INTO summary_id FROM public.purchase_invoice_summary s
   WHERE s.economic_group_id = group_id AND s.access_key = p_data ->> 'accessKey' AND s.deleted_at IS NULL
   ORDER BY s.id DESC LIMIT 1;
  IF FOUND THEN
    PERFORM app.apply_invoice_summary(summary_id);
  END IF;
  RETURN new_invoice_id;
END;
$$;

-- Filiais com o download ligado, certificado válido e hora de buscar. Reserva cada uma por 10 minutos.
CREATE FUNCTION app.dfe_claim_branches(p_limit integer DEFAULT 10)
RETURNS TABLE (
  branch_id uuid, company_id uuid, cnpj text, state text, last_nsu text,
  encrypted_pfx bytea, encrypted_password bytea
)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM app.require_dfe_worker();
  RETURN QUERY
  WITH due AS (
    SELECT s.id
      FROM public.branch_dfe_sync s
      JOIN public.branch b ON b.id = s.branch_id AND b.deleted_at IS NULL
      JOIN public.branch_certificate bc ON bc.branch_id = s.branch_id AND bc.deleted_at IS NULL
           AND bc.valid_to > pg_catalog.now()
     WHERE s.enabled AND s.deleted_at IS NULL AND s.next_run_at <= pg_catalog.now()
       AND (s.locked_until IS NULL OR s.locked_until < pg_catalog.now())
     ORDER BY s.next_run_at
     LIMIT LEAST(GREATEST(COALESCE(p_limit, 10), 1), 50)
     FOR UPDATE OF s SKIP LOCKED
  ), claimed AS (
    UPDATE public.branch_dfe_sync s SET locked_until = pg_catalog.now() + interval '10 minutes'
      FROM due WHERE s.id = due.id
    RETURNING s.branch_id, s.last_nsu
  )
  SELECT c.branch_id, b.company_id, b.cnpj::text, b.state::text, c.last_nsu, bc.encrypted_pfx, bc.encrypted_password
    FROM claimed c
    JOIN public.branch b ON b.id = c.branch_id
    JOIN public.branch_certificate bc ON bc.branch_id = c.branch_id AND bc.deleted_at IS NULL;
END;
$$;

-- Fim da rodada de uma filial: guarda o NSU, o retorno da Sefaz e quando buscar de novo.
CREATE FUNCTION app.dfe_finish_branch(p_branch_id uuid, p_result jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  wait_minutes integer := LEAST(GREATEST(COALESCE((p_result ->> 'waitMinutes')::integer, 60), 1), 1440);
BEGIN
  PERFORM app.require_dfe_worker();
  UPDATE public.branch_dfe_sync
     SET last_nsu = COALESCE(NULLIF(p_result ->> 'ultNsu', ''), last_nsu),
         max_nsu = COALESCE(NULLIF(p_result ->> 'maxNsu', ''), max_nsu),
         last_status = NULLIF(p_result ->> 'status', ''),
         last_message = pg_catalog.left(NULLIF(p_result ->> 'message', ''), 500),
         last_error = NULLIF(p_result ->> 'error', ''),
         last_run_at = pg_catalog.clock_timestamp(),
         next_run_at = pg_catalog.clock_timestamp() + pg_catalog.make_interval(mins => wait_minutes),
         locked_until = NULL
   WHERE branch_id = p_branch_id AND deleted_at IS NULL;
END;
$$;

-- Guarda o documento recebido. Devolve falso se o NSU já tinha chegado.
CREATE FUNCTION app.dfe_store_document(p_branch_id uuid, p_nsu text, p_schema text, p_access_key text, p_xml text) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  inserted uuid;
BEGIN
  PERFORM app.require_dfe_worker();
  INSERT INTO public.dfe_document (economic_group_id, branch_id, nsu, schema, access_key, xml)
  SELECT c.economic_group_id, b.id, p_nsu, p_schema, p_access_key, p_xml
    FROM public.branch b JOIN public.company c ON c.id = b.company_id
   WHERE b.id = p_branch_id
  ON CONFLICT (branch_id, nsu) WHERE deleted_at IS NULL DO NOTHING
  RETURNING id INTO inserted;
  RETURN inserted IS NOT NULL;
END;
$$;

-- Resumo da nota (resNFe). Chegar de novo atualiza a situação e a confirmação.
CREATE FUNCTION app.dfe_record_summary(p_branch_id uuid, p_data jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid;
  summary_id uuid;
BEGIN
  PERFORM app.require_dfe_worker();
  SELECT c.economic_group_id INTO group_id FROM public.branch b JOIN public.company c ON c.id = b.company_id WHERE b.id = p_branch_id;
  INSERT INTO public.purchase_invoice_summary (
    economic_group_id, branch_id, access_key, emitter_document, emitter_name, issued_at, operation_type, total, digest,
    protocol_number, situation
  ) VALUES (
    group_id, p_branch_id, COALESCE(p_data ->> 'accessKey', ''), COALESCE(app.clean_document(p_data ->> 'emitterDocument'), ''),
    COALESCE(pg_catalog.left(app.clean_text(p_data ->> 'emitterName'), 150), ''), (p_data ->> 'issuedAt')::timestamptz,
    (p_data ->> 'operationType')::smallint, (p_data ->> 'total')::numeric, COALESCE(p_data ->> 'digest', ''),
    NULLIF(p_data ->> 'protocolNumber', ''), (p_data ->> 'situation')::smallint
  )
  ON CONFLICT (branch_id, access_key) WHERE deleted_at IS NULL
  DO UPDATE SET situation = GREATEST(public.purchase_invoice_summary.situation, EXCLUDED.situation),
                protocol_number = COALESCE(EXCLUDED.protocol_number, public.purchase_invoice_summary.protocol_number)
  RETURNING id INTO summary_id;
  PERFORM app.apply_invoice_summary(summary_id);
  RETURN summary_id;
END;
$$;

-- Evento de cancelamento (110111) de uma nota de interesse da filial.
CREATE FUNCTION app.dfe_record_cancellation(p_branch_id uuid, p_access_key text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid;
  target uuid;
BEGIN
  PERFORM app.require_dfe_worker();
  SELECT c.economic_group_id INTO group_id FROM public.branch b JOIN public.company c ON c.id = b.company_id WHERE b.id = p_branch_id;
  UPDATE public.purchase_invoice_summary SET situation = 3
   WHERE economic_group_id = group_id AND access_key = p_access_key AND deleted_at IS NULL;
  FOR target IN
    SELECT i.id FROM public.purchase_invoice i
     WHERE i.economic_group_id = group_id AND i.access_key = p_access_key AND i.deleted_at IS NULL
  LOOP
    PERFORM app.cancel_invoice_by_sefaz(target);
  END LOOP;
END;
$$;

-- XML completo que veio da Sefaz. Se a nota já foi importada à mão, vale como confirmação dela.
CREATE FUNCTION app.dfe_import_invoice(
  p_branch_id uuid, p_data jsonb, p_xml text, p_sha256 text, p_requires_confirmation boolean
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid;
  target_branch public.branch;
  existing public.purchase_invoice;
  result_id uuid;
BEGIN
  PERFORM app.require_dfe_worker();
  SELECT c.economic_group_id INTO group_id FROM public.branch b JOIN public.company c ON c.id = b.company_id WHERE b.id = p_branch_id;
  target_branch := app.invoice_branch(group_id, p_data ->> 'destCnpj');
  SELECT * INTO existing FROM public.purchase_invoice i
   WHERE i.economic_group_id = group_id AND i.access_key = p_data ->> 'accessKey' AND i.deleted_at IS NULL;
  IF FOUND THEN
    result_id := existing.id;
    IF existing.confirmation <> 'confirmed' THEN
      IF existing.digest = p_data ->> 'digest' THEN
        UPDATE public.purchase_invoice
           SET confirmation = 'confirmed', confirmed_at = pg_catalog.clock_timestamp(), confirmation_message = NULL
         WHERE id = existing.id;
      ELSE
        UPDATE public.purchase_invoice
           SET confirmation = 'mismatch', confirmation_message = 'O XML importado é diferente do que a Sefaz autorizou.'
         WHERE id = existing.id;
      END IF;
    END IF;
  ELSE
    result_id := app.store_purchase_invoice(group_id, target_branch, p_data, p_xml, p_sha256, 'download', p_requires_confirmation);
  END IF;
  UPDATE public.purchase_invoice_summary SET invoice_id = result_id
   WHERE economic_group_id = group_id AND access_key = p_data ->> 'accessKey' AND deleted_at IS NULL
     AND purchase_invoice_summary.invoice_id IS NULL;
  RETURN result_id;
END;
$$;

-- Notas para consultar pela chave: as importadas à mão esperando confirmação e as que já tiveram
-- ciência e esperam o XML. Respeita o limite da Sefaz e reserva cada chave por 30 minutos.
CREATE FUNCTION app.dfe_claim_queries(p_environment smallint, p_limit integer DEFAULT 10)
RETURNS TABLE (
  branch_id uuid, company_id uuid, cnpj text, state text, access_key text, kind text,
  encrypted_pfx bytea, encrypted_password bytea
)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  candidate record;
  sync public.branch_dfe_sync;
  taken integer := 0;
BEGIN
  PERFORM app.require_dfe_worker();
  FOR candidate IN
    SELECT q.branch_id, q.access_key, q.kind, q.row_id FROM (
      SELECT i.branch_id, i.access_key, 'confirm'::text AS kind, i.id AS row_id, i.last_query_at
        FROM public.purchase_invoice i
       WHERE i.deleted_at IS NULL AND i.status IN ('review', 'not_postable') AND i.confirmation = 'pending'
         AND i.source = 'manual' AND i.environment = p_environment
         AND (i.last_query_at IS NULL OR i.last_query_at < pg_catalog.now() - interval '30 minutes')
      UNION ALL
      SELECT s.branch_id, s.access_key, 'xml'::text, s.id, s.last_query_at
        FROM public.purchase_invoice_summary s
       WHERE s.deleted_at IS NULL AND s.invoice_id IS NULL AND s.awareness_at IS NOT NULL AND s.situation = 1
         AND (s.last_query_at IS NULL OR s.last_query_at < pg_catalog.now() - interval '10 minutes')
    ) q
    ORDER BY q.last_query_at NULLS FIRST, q.row_id
  LOOP
    EXIT WHEN taken >= LEAST(GREATEST(COALESCE(p_limit, 10), 1), 50);
    SELECT * INTO sync FROM public.branch_dfe_sync s
     WHERE s.branch_id = candidate.branch_id AND s.enabled AND s.deleted_at IS NULL
     FOR UPDATE;
    CONTINUE WHEN NOT FOUND;
    IF sync.query_window_start IS NULL OR sync.query_window_start < pg_catalog.now() - interval '1 hour' THEN
      UPDATE public.branch_dfe_sync SET query_window_start = pg_catalog.now(), query_count = 0 WHERE id = sync.id;
      sync.query_count := 0;
    END IF;
    CONTINUE WHEN sync.query_count >= 15;
    CONTINUE WHEN NOT EXISTS (
      SELECT 1 FROM public.branch_certificate bc
       WHERE bc.branch_id = candidate.branch_id AND bc.deleted_at IS NULL AND bc.valid_to > pg_catalog.now()
    );
    UPDATE public.branch_dfe_sync SET query_count = query_count + 1 WHERE id = sync.id;
    IF candidate.kind = 'confirm' THEN
      UPDATE public.purchase_invoice SET last_query_at = pg_catalog.now() WHERE id = candidate.row_id;
    ELSE
      UPDATE public.purchase_invoice_summary SET last_query_at = pg_catalog.now() WHERE id = candidate.row_id;
    END IF;
    taken := taken + 1;
    RETURN QUERY
      SELECT b.id, b.company_id, b.cnpj::text, b.state::text, candidate.access_key, candidate.kind,
             bc.encrypted_pfx, bc.encrypted_password
        FROM public.branch b
        JOIN public.branch_certificate bc ON bc.branch_id = b.id AND bc.deleted_at IS NULL
       WHERE b.id = candidate.branch_id;
  END LOOP;
END;
$$;

-- Resultado da consulta por chave quando a Sefaz não devolve a nota. 656 (consumo indevido)
-- encerra as consultas da filial nesta hora; outra recusa marca a nota como sem confirmação.
CREATE FUNCTION app.dfe_record_query_failure(p_branch_id uuid, p_access_key text, p_status text, p_message text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM app.require_dfe_worker();
  IF p_status = '656' THEN
    -- A espera de uma hora conta a partir de agora.
    UPDATE public.branch_dfe_sync SET query_window_start = pg_catalog.now(), query_count = 15
     WHERE branch_id = p_branch_id AND deleted_at IS NULL;
    RETURN;
  END IF;
  -- 137: nada localizado ainda. A nota continua esperando e é consultada de novo mais tarde.
  IF p_status = '137' THEN
    RETURN;
  END IF;
  UPDATE public.purchase_invoice
     SET confirmation = 'unavailable',
         confirmation_message = pg_catalog.left(COALESCE(NULLIF(pg_catalog.btrim(p_message), ''), 'A Sefaz não confirmou esta nota.'), 500)
   WHERE branch_id = p_branch_id AND access_key = p_access_key AND deleted_at IS NULL AND confirmation = 'pending';
END;
$$;

-- Liga ou desliga o download da filial. Ligar põe a filial na fila na hora.
CREATE FUNCTION app.set_dfe_sync(p_branch_id uuid, p_enabled boolean) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.branch := app.require_branch_permission('fiscal.certificate', p_branch_id);
BEGIN
  INSERT INTO public.branch_dfe_sync (economic_group_id, branch_id, enabled)
  SELECT c.economic_group_id, target.id, COALESCE(p_enabled, false)
    FROM public.company c WHERE c.id = target.company_id
  ON CONFLICT (branch_id) WHERE deleted_at IS NULL
  DO UPDATE SET enabled = EXCLUDED.enabled,
                next_run_at = CASE WHEN EXCLUDED.enabled AND NOT public.branch_dfe_sync.enabled
                                   THEN LEAST(public.branch_dfe_sync.next_run_at, pg_catalog.now())
                                   ELSE public.branch_dfe_sync.next_run_at END;
END;
$$;

-- Situação do download nas filiais que o usuário vê na tela fiscal.
CREATE FUNCTION app.dfe_sync_status()
RETURNS TABLE (
  branch_id uuid, branch_name text, enabled boolean, has_certificate boolean, certificate_valid_to timestamptz,
  last_run_at timestamptz, next_run_at timestamptz, last_status text, last_message text, last_error text,
  waiting_awareness bigint, can_manage boolean
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT b.id, b.name, COALESCE(s.enabled, false), bc.id IS NOT NULL AND bc.valid_to > pg_catalog.now(), bc.valid_to,
         s.last_run_at, s.next_run_at, s.last_status, s.last_message, s.last_error,
         (SELECT pg_catalog.count(*) FROM public.purchase_invoice_summary ps
           WHERE ps.branch_id = b.id AND ps.deleted_at IS NULL AND ps.invoice_id IS NULL AND ps.awareness_at IS NULL
             AND ps.situation = 1),
         app.has_permission('fiscal.certificate', b.id)
    FROM public.branch b
    JOIN public.company c ON c.id = b.company_id AND c.economic_group_id = app.current_user_group()
    LEFT JOIN public.branch_dfe_sync s ON s.branch_id = b.id AND s.deleted_at IS NULL
    LEFT JOIN public.branch_certificate bc ON bc.branch_id = b.id AND bc.deleted_at IS NULL
   WHERE b.deleted_at IS NULL
     AND (app.has_permission('fiscal.view', b.id) OR app.has_permission('fiscal.certificate', b.id))
   ORDER BY b.name
$$;

-- Notas que a Sefaz mostrou e ainda não viraram nota importada.
CREATE FUNCTION app.list_purchase_summaries(p_branch_id uuid DEFAULT NULL)
RETURNS TABLE (
  id uuid, branch_id uuid, branch_name text, access_key text, emitter_document text, emitter_name text,
  issued_at timestamptz, total numeric, situation smallint, awareness_at timestamptz, awareness_by_name text,
  can_manage boolean
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT s.id, s.branch_id, b.name, s.access_key, s.emitter_document, s.emitter_name, s.issued_at, s.total, s.situation,
         s.awareness_at, u.name, app.has_permission('purchases.manage', s.branch_id)
    FROM public.purchase_invoice_summary s
    JOIN public.branch b ON b.id = s.branch_id
    LEFT JOIN public.user_account u ON u.id = s.awareness_by
   WHERE s.economic_group_id = app.current_user_group() AND s.deleted_at IS NULL AND s.invoice_id IS NULL
     AND s.operation_type = 1
     AND (p_branch_id IS NULL OR s.branch_id = p_branch_id)
     AND (app.has_permission('purchases.view', s.branch_id) OR app.has_permission('purchases.manage', s.branch_id))
   ORDER BY s.issued_at DESC, s.id DESC
   LIMIT 200
$$;

-- Dados para a API assinar e enviar a ciência. Quem pede precisa de purchases.manage na filial.
CREATE FUNCTION app.awareness_target(p_summary_id uuid)
RETURNS TABLE (
  access_key text, cnpj text, state text, company_id uuid, encrypted_pfx bytea, encrypted_password bytea
)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  summary public.purchase_invoice_summary;
BEGIN
  SELECT * INTO summary FROM public.purchase_invoice_summary s
   WHERE s.id = p_summary_id AND s.economic_group_id = app.current_user_group() AND s.deleted_at IS NULL
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('purchase_invoice_summary %s.', p_summary_id);
  END IF;
  PERFORM app.require_invoice_branch(summary.branch_id);
  IF summary.awareness_at IS NOT NULL OR summary.invoice_id IS NOT NULL OR summary.situation <> 1 THEN
    RAISE EXCEPTION 'Esta nota não está mais aguardando ciência.'
      USING ERRCODE = 'FA946', DETAIL = pg_catalog.format('purchase_invoice_summary %s.', summary.id);
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.branch_certificate bc
     WHERE bc.branch_id = summary.branch_id AND bc.deleted_at IS NULL AND bc.valid_to > pg_catalog.now()
  ) THEN
    RAISE EXCEPTION 'A filial não tem certificado digital válido.'
      USING ERRCODE = 'FA943', DETAIL = pg_catalog.format('Filial %s.', summary.branch_id);
  END IF;
  RETURN QUERY
    SELECT summary.access_key, b.cnpj::text, b.state::text, b.company_id, bc.encrypted_pfx, bc.encrypted_password
      FROM public.branch b
      JOIN public.branch_certificate bc ON bc.branch_id = b.id AND bc.deleted_at IS NULL
     WHERE b.id = summary.branch_id;
END;
$$;

-- A Sefaz registrou a ciência: o XML completo chega na próxima consulta.
CREATE FUNCTION app.record_awareness(p_summary_id uuid, p_protocol text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  summary public.purchase_invoice_summary;
BEGIN
  SELECT * INTO summary FROM public.purchase_invoice_summary s
   WHERE s.id = p_summary_id AND s.economic_group_id = app.current_user_group() AND s.deleted_at IS NULL
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('purchase_invoice_summary %s.', p_summary_id);
  END IF;
  PERFORM app.require_invoice_branch(summary.branch_id);
  UPDATE public.purchase_invoice_summary
     SET awareness_at = pg_catalog.clock_timestamp(), awareness_by = app.current_user_id(),
         awareness_protocol = NULLIF(p_protocol, ''), last_query_at = NULL
   WHERE id = summary.id AND awareness_at IS NULL;
END;
$$;

-- As listas de notas passam a mostrar a confirmação e o cancelamento.
DROP FUNCTION app.list_purchase_invoices(uuid, text, integer);
CREATE FUNCTION app.list_purchase_invoices(p_branch_id uuid DEFAULT NULL, p_status text DEFAULT NULL, p_limit integer DEFAULT 100)
RETURNS TABLE (
  id uuid, branch_id uuid, branch_name text, supplier_id uuid, supplier_name text, access_key text, series integer,
  number bigint, issued_at timestamptz, invoice_total numeric, status text, not_postable_reason text, environment smallint,
  item_count bigint, pending_count bigint, created_at timestamptz, source text, confirmation text,
  confirmation_required boolean, cancelled_at timestamptz
)
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT i.id, i.branch_id, b.name, i.supplier_id, COALESCE(s.trade_name, s.legal_name, i.emitter_name), i.access_key,
         i.series, i.number, i.issued_at, i.invoice_total, i.status, i.not_postable_reason, i.environment,
         (SELECT pg_catalog.count(*) FROM public.v_purchase_invoice_item it WHERE it.invoice_id = i.id),
         (SELECT pg_catalog.count(*) FROM public.v_purchase_invoice_item it WHERE it.invoice_id = i.id AND it.product_id IS NULL),
         i.created_at, i.source, i.confirmation, i.confirmation_required, i.cancelled_at
    FROM public.v_purchase_invoice i
    JOIN public.branch b ON b.id = i.branch_id
    LEFT JOIN public.supplier s ON s.id = i.supplier_id
   WHERE (p_branch_id IS NULL OR i.branch_id = p_branch_id)
     AND (p_status IS NULL OR i.status = p_status)
   ORDER BY i.created_at DESC, i.id DESC
   LIMIT LEAST(GREATEST(COALESCE(p_limit, 100), 1), 500)
$$;

-- Quem vê compras na filial vê o que chegou da Sefaz; o estado do download, quem vê a parte fiscal.
CREATE POLICY branch_dfe_sync_select ON branch_dfe_sync FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group())
         AND (app.has_permission('fiscal.view', branch_id) OR app.has_permission('fiscal.certificate', branch_id)));
CREATE POLICY dfe_document_select ON dfe_document FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group())
         AND (app.has_permission('purchases.view', branch_id) OR app.has_permission('purchases.manage', branch_id)));
CREATE POLICY purchase_invoice_summary_select ON purchase_invoice_summary FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group())
         AND (app.has_permission('purchases.view', branch_id) OR app.has_permission('purchases.manage', branch_id)));
GRANT SELECT ON branch_dfe_sync, dfe_document, purchase_invoice_summary TO farmaerp_app;

CREATE VIEW v_branch_dfe_sync WITH (security_invoker = true) AS
  SELECT * FROM branch_dfe_sync WHERE deleted_at IS NULL;
CREATE VIEW v_dfe_document WITH (security_invoker = true) AS
  SELECT * FROM dfe_document WHERE deleted_at IS NULL;
CREATE VIEW v_purchase_invoice_summary WITH (security_invoker = true) AS
  SELECT * FROM purchase_invoice_summary WHERE deleted_at IS NULL;
GRANT SELECT ON v_branch_dfe_sync, v_dfe_document, v_purchase_invoice_summary TO farmaerp_app;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  app.list_purchase_invoices(uuid, text, integer),
  app.dfe_claim_branches(integer),
  app.dfe_finish_branch(uuid, jsonb),
  app.dfe_store_document(uuid, text, text, text, text),
  app.dfe_record_summary(uuid, jsonb),
  app.dfe_record_cancellation(uuid, text),
  app.dfe_import_invoice(uuid, jsonb, text, text, boolean),
  app.dfe_claim_queries(smallint, integer),
  app.dfe_record_query_failure(uuid, text, text, text),
  app.set_dfe_sync(uuid, boolean),
  app.dfe_sync_status(),
  app.list_purchase_summaries(uuid),
  app.awareness_target(uuid),
  app.record_awareness(uuid, text)
TO farmaerp_app;
