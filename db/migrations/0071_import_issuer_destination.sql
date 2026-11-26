-- Up Migration

-- Parte B do lote de 26/11: importação do sistema anterior.
-- 1. NFC-e de empresa ou filial que o cliente ainda não tem não cria mais nada sozinha: a nota fica
--    esperando ("waiting") e o CNPJ aparece para o administrador da plataforma, que cria a empresa
--    (ou só a filial, na empresa de mesma raiz) no cliente que importou, ou recusa. Criado, as
--    notas que esperavam entram pela rotina da importação; recusado, ficam ignoradas com o motivo.
--    NF-e de filial nova de uma empresa do cliente (ou de CNPJ que já espera) espera junto.
-- 2. Produtos nascem só das NFC-e: na NF-e (compra ou emitida pelo cliente) o produto é só
--    procurado; o item sem produto fica de fora, anotado na nota (skipped_items) e no relatório.

ALTER TABLE document_import_note DROP CONSTRAINT document_import_note_result_check;
ALTER TABLE document_import_note ADD CONSTRAINT document_import_note_result_check
  CHECK (result IN ('imported', 'duplicate', 'canceled', 'ignored', 'failed', 'waiting'));

ALTER TABLE imported_sale ADD COLUMN skipped_items jsonb NOT NULL DEFAULT '[]'::jsonb
  CONSTRAINT imported_sale_skipped_items_check CHECK (jsonb_typeof(skipped_items) = 'array');
ALTER TABLE imported_stock_note ADD COLUMN skipped_items jsonb NOT NULL DEFAULT '[]'::jsonb
  CONSTRAINT imported_stock_note_skipped_items_check CHECK (jsonb_typeof(skipped_items) = 'array');

-- CNPJ da nota que o cliente ainda não tem como filial. Um por cliente e CNPJ.
CREATE TABLE import_pending_issuer (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  cnpj text NOT NULL CONSTRAINT import_pending_issuer_cnpj_check CHECK (app.is_valid_cnpj(cnpj)),
  -- Dados da parte, como vieram na primeira nota (nome, fantasia, UF, IE, endereço, CRT).
  issuer jsonb NOT NULL CONSTRAINT import_pending_issuer_issuer_check CHECK (jsonb_typeof(issuer) = 'object'),
  status text NOT NULL DEFAULT 'pending' CONSTRAINT import_pending_issuer_status_check CHECK (status IN ('pending', 'created', 'refused')),
  branch_id uuid REFERENCES branch (id),
  decided_by uuid REFERENCES user_account (id),
  decided_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid,
  CONSTRAINT import_pending_issuer_decision_check CHECK (
    (status = 'pending') = (decided_at IS NULL) AND (status = 'created') = (branch_id IS NOT NULL)
  )
);
CREATE UNIQUE INDEX import_pending_issuer_cnpj_key ON import_pending_issuer (economic_group_id, cnpj) WHERE deleted_at IS NULL;
CREATE INDEX import_pending_issuer_pending_idx ON import_pending_issuer (created_at) WHERE status = 'pending' AND deleted_at IS NULL;
CREATE INDEX import_pending_issuer_branch_id_idx ON import_pending_issuer (branch_id);
CREATE INDEX import_pending_issuer_decided_by_idx ON import_pending_issuer (decided_by);
CALL app.apply_table_standard('public.import_pending_issuer');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON import_pending_issuer
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns('economic_group_id', 'cnpj');
CREATE POLICY import_pending_issuer_select ON import_pending_issuer FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group()));
CREATE VIEW v_import_pending_issuer WITH (security_invoker = true) AS SELECT * FROM import_pending_issuer WHERE deleted_at IS NULL;

-- Nota guardada (já lida do XML) esperando o destino do CNPJ. released: decidido, falta entrar.
CREATE TABLE import_waiting_note (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  import_id uuid NOT NULL REFERENCES document_import (id),
  import_note_id uuid NOT NULL REFERENCES document_import_note (id),
  pending_issuer_id uuid NOT NULL REFERENCES import_pending_issuer (id),
  entry_name text NOT NULL CONSTRAINT import_waiting_note_entry_check CHECK (length(entry_name) BETWEEN 1 AND 300),
  access_key text NOT NULL CONSTRAINT import_waiting_note_key_check CHECK (access_key ~ '^[0-9]{44}$'),
  model text NOT NULL CONSTRAINT import_waiting_note_model_check CHECK (model IN ('55', '65')),
  note jsonb NOT NULL CONSTRAINT import_waiting_note_note_check CHECK (jsonb_typeof(note) = 'object'),
  status text NOT NULL DEFAULT 'waiting' CONSTRAINT import_waiting_note_status_check CHECK (status IN ('waiting', 'released', 'done')),
  locked_until timestamptz,
  processed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid,
  CONSTRAINT import_waiting_note_done_check CHECK ((status = 'done') = (processed_at IS NOT NULL))
);
CREATE UNIQUE INDEX import_waiting_note_key ON import_waiting_note (access_key) WHERE status <> 'done' AND deleted_at IS NULL;
CREATE INDEX import_waiting_note_pending_idx ON import_waiting_note (pending_issuer_id, status);
CREATE INDEX import_waiting_note_released_idx ON import_waiting_note (created_at) WHERE status = 'released' AND deleted_at IS NULL;
CREATE INDEX import_waiting_note_import_idx ON import_waiting_note (import_id, status);
CREATE INDEX import_waiting_note_import_note_id_idx ON import_waiting_note (import_note_id);
CALL app.apply_table_standard('public.import_waiting_note');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON import_waiting_note
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'import_id', 'import_note_id', 'entry_name', 'access_key', 'model', 'note'
  );
CREATE POLICY import_waiting_note_select ON import_waiting_note FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group()));
CREATE VIEW v_import_waiting_note WITH (security_invoker = true) AS SELECT * FROM import_waiting_note WHERE deleted_at IS NULL;

-- A chave já espera o destino (fora a própria nota que volta agora pela importação dela)?
CREATE FUNCTION app.import_key_waiting(p_key text, p_import_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.import_waiting_note w
     WHERE w.access_key = p_key AND w.status <> 'done' AND w.deleted_at IS NULL
       AND NOT (w.import_id = p_import_id AND w.status = 'released')
  )
$$;

-- Filial do cliente pelo CNPJ da parte. Sem filial: o CNPJ que espera (ou foi recusado). p_own: a
-- parte é com certeza do cliente (emitente da NFC-e): CNPJ inválido ou de outro cliente recusa a
-- nota e o CNPJ novo passa a esperar. Nas outras partes, só espera a filial nova de uma empresa do
-- cliente (mesma raiz); de fora, sem filial.
CREATE FUNCTION app.import_branch_or_wait(
  p_group_id uuid, p_party jsonb, p_own boolean, OUT out_branch uuid, OUT out_pending uuid, OUT out_refused boolean
)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_cnpj text := app.clean_document(p_party ->> 'cnpj');
  v_found public.branch;
  v_pending public.import_pending_issuer;
  v_ours boolean;
BEGIN
  out_refused := false;
  IF v_cnpj IS NULL OR pg_catalog.length(v_cnpj) <> 14 OR NOT app.is_valid_cnpj(v_cnpj) THEN
    IF p_own THEN
      RAISE EXCEPTION 'A nota não pôde ser importada.' USING ERRCODE = 'FA743', DETAIL = 'CNPJ do emitente inválido.';
    END IF;
    RETURN;
  END IF;
  SELECT b.* INTO v_found FROM public.branch b WHERE b.cnpj = v_cnpj AND b.deleted_at IS NULL;
  IF v_found.id IS NOT NULL THEN
    IF EXISTS (SELECT 1 FROM public.company c WHERE c.id = v_found.company_id AND c.economic_group_id = p_group_id) THEN
      out_branch := v_found.id;
    ELSIF p_own THEN
      RAISE EXCEPTION 'O CNPJ do emitente é de uma filial de outro cliente.' USING ERRCODE = 'FA742', DETAIL = v_cnpj;
    END IF;
    RETURN;
  END IF;
  SELECT * INTO v_pending FROM public.import_pending_issuer p
   WHERE p.economic_group_id = p_group_id AND p.cnpj = v_cnpj AND p.deleted_at IS NULL;
  IF v_pending.id IS NOT NULL THEN
    out_refused := v_pending.status = 'refused';
    IF v_pending.status = 'pending' THEN
      out_pending := v_pending.id;
    END IF;
    RETURN;
  END IF;
  v_ours := EXISTS (
    SELECT 1 FROM public.company c
     WHERE c.economic_group_id = p_group_id AND c.cnpj_root = pg_catalog.left(v_cnpj, 8) AND c.deleted_at IS NULL
  );
  IF NOT v_ours AND EXISTS (
    SELECT 1 FROM public.company c WHERE c.cnpj_root = pg_catalog.left(v_cnpj, 8) AND c.deleted_at IS NULL
  ) THEN
    IF p_own THEN
      RAISE EXCEPTION 'O CNPJ do emitente é de uma filial de outro cliente.' USING ERRCODE = 'FA742', DETAIL = v_cnpj;
    END IF;
    RETURN;
  END IF;
  IF p_own OR v_ours THEN
    INSERT INTO public.import_pending_issuer (economic_group_id, cnpj, issuer)
    VALUES (p_group_id, v_cnpj, p_party || pg_catalog.jsonb_build_object('cnpj', v_cnpj))
    RETURNING id INTO out_pending;
  END IF;
END;
$$;

-- Motivo da nota que espera, com o CNPJ formatado.
CREATE FUNCTION app.import_waiting_message(p_pending_id uuid) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT 'Aguardando o administrador da plataforma definir a empresa ou filial do CNPJ '
         || pg_catalog.regexp_replace(p.cnpj, '^(\d{2})(\d{3})(\d{3})(\d{4})(\d{2})$', '\1.\2.\3/\4-\5') || '.'
    FROM public.import_pending_issuer p WHERE p.id = p_pending_id
$$;

-- Produto que o cliente já tem, pelo código do sistema anterior ou pelo código de barras. Não cria.
CREATE FUNCTION app.import_find_product(p_group_id uuid, p_item jsonb) RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_legacy text := app.import_text(p_item ->> 'code', 60);
  v_candidate text;
  v_found uuid;
BEGIN
  IF v_legacy IS NOT NULL THEN
    SELECT p.id INTO v_found FROM public.product p
     WHERE p.economic_group_id = p_group_id AND p.legacy_code = v_legacy AND p.deleted_at IS NULL;
    IF v_found IS NOT NULL THEN
      RETURN v_found;
    END IF;
  END IF;
  FOREACH v_candidate IN ARRAY ARRAY[NULLIF(p_item ->> 'gtin', ''), NULLIF(p_item ->> 'tax_gtin', '')] LOOP
    CONTINUE WHEN v_candidate IS NULL OR NOT app.is_valid_gtin(v_candidate);
    SELECT pb.product_id INTO v_found FROM public.product_barcode pb
      JOIN public.product p ON p.id = pb.product_id AND p.deleted_at IS NULL
     WHERE pb.economic_group_id = p_group_id AND pb.code = v_candidate AND pb.deleted_at IS NULL
     LIMIT 1;
    IF v_found IS NOT NULL THEN
      RETURN v_found;
    END IF;
  END LOOP;
  RETURN NULL;
END;
$$;

-- Item que ficou de fora, como aparece no relatório.
CREATE FUNCTION app.import_skipped_item(p_item jsonb) RETURNS jsonb
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$
  SELECT pg_catalog.jsonb_build_object(
    'line', CASE WHEN p_item ->> 'line' ~ '^\d{1,4}$' THEN (p_item ->> 'line')::integer END,
    'code', app.import_text(p_item ->> 'code', 60),
    'name', app.import_text(p_item ->> 'name', 120),
    'gtin', CASE WHEN p_item ->> 'gtin' ~ '^\d{8,14}$' THEN p_item ->> 'gtin' END,
    'quantity', CASE WHEN p_item ->> 'quantity' ~ '^\d{1,12}(\.\d{1,4})?$' THEN (p_item ->> 'quantity')::numeric END
  )
$$;

-- Nenhum item com produto: a nota não entra (o chamador transforma em "ignorada").
CREATE FUNCTION app.import_require_items(p_skipped jsonb, p_items jsonb) RETURNS void
LANGUAGE plpgsql IMMUTABLE
SET search_path = ''
AS $$
BEGIN
  IF pg_catalog.jsonb_array_length(p_skipped) > 0
     AND pg_catalog.jsonb_array_length(p_skipped) >= pg_catalog.jsonb_array_length(COALESCE(p_items, '[]'::jsonb)) THEN
    RAISE EXCEPTION 'Nenhum item da nota tem produto cadastrado.' USING ERRCODE = 'FA759';
  END IF;
END;
$$;

-- Passa notas de um resultado para outro na contagem de uma importação já concluída.
CREATE FUNCTION app.import_totals_move(p_import_id uuid, p_from text, p_to text, p_count integer) RETURNS void
LANGUAGE sql SECURITY DEFINER
SET search_path = ''
AS $$
  UPDATE public.document_import d
     SET totals = d.totals
       || pg_catalog.jsonb_build_object(p_from, GREATEST(COALESCE((d.totals ->> p_from)::integer, 0) - p_count, 0))
       || pg_catalog.jsonb_build_object(p_to, COALESCE((d.totals ->> p_to)::integer, 0) + p_count)
   WHERE d.id = p_import_id AND p_count > 0
$$;

-- Resultado da nota no relatório. Nota que espera: guardada com o que foi lido do XML. Nota que
-- voltou depois da decisão: o mesmo registro do relatório muda, e a conta da importação também.
CREATE FUNCTION app.import_record_note(
  p_job public.document_import, p_entry text, p_key text, p_model text, p_outcome text, p_code text, p_reason text,
  p_pending uuid, p_note jsonb
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_waiting public.import_waiting_note;
  v_note_id uuid;
BEGIN
  IF p_key ~ '^[0-9]{44}$' THEN
    SELECT * INTO v_waiting FROM public.import_waiting_note w
     WHERE w.import_id = p_job.id AND w.access_key = p_key AND w.status = 'released' AND w.deleted_at IS NULL
     FOR UPDATE;
  END IF;
  IF v_waiting.id IS NOT NULL THEN
    IF p_outcome = 'waiting' THEN
      -- Ainda espera (a outra parte da NF-e também é um CNPJ novo).
      UPDATE public.import_waiting_note w SET status = 'waiting', pending_issuer_id = p_pending, locked_until = NULL
       WHERE w.id = v_waiting.id;
      UPDATE public.document_import_note n SET reason = p_reason WHERE n.id = v_waiting.import_note_id;
      RETURN;
    END IF;
    UPDATE public.document_import_note n SET result = p_outcome, error_code = p_code, reason = p_reason
     WHERE n.id = v_waiting.import_note_id;
    UPDATE public.import_waiting_note w SET status = 'done', processed_at = pg_catalog.now(), locked_until = NULL
     WHERE w.id = v_waiting.id;
    PERFORM app.import_totals_move(p_job.id, 'waiting', p_outcome, 1);
    RETURN;
  END IF;
  INSERT INTO public.document_import_note (economic_group_id, import_id, entry_name, access_key, model, result, error_code, reason)
  VALUES (
    p_job.economic_group_id, p_job.id, pg_catalog.left(COALESCE(p_entry, '?'), 300),
    CASE WHEN p_key ~ '^[0-9]{44}$' THEN p_key END, p_model, p_outcome, p_code, p_reason
  ) RETURNING id INTO v_note_id;
  IF p_outcome = 'waiting' THEN
    INSERT INTO public.import_waiting_note (
      economic_group_id, import_id, import_note_id, pending_issuer_id, entry_name, access_key, model, note
    ) VALUES (
      p_job.economic_group_id, p_job.id, v_note_id, p_pending, pg_catalog.left(COALESCE(p_entry, '?'), 300), p_key, p_model, p_note
    );
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION app.import_purchase_product(
  p_group_id uuid, p_supplier_id uuid, p_item jsonb, OUT out_product_id uuid, OUT out_fraction numeric
)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_code text := app.import_text(p_item ->> 'code', 60);
  v_gtin text;
  v_candidate text;
  v_link_id uuid;
  v_barcode_id uuid;
BEGIN
  IF p_supplier_id IS NOT NULL AND v_code IS NOT NULL THEN
    SELECT ps.id, ps.product_id INTO v_link_id, out_product_id FROM public.product_supplier ps
      JOIN public.product p ON p.id = ps.product_id AND p.deleted_at IS NULL
     WHERE ps.supplier_id = p_supplier_id AND ps.supplier_code = v_code AND ps.deleted_at IS NULL;
  END IF;
  IF out_product_id IS NULL THEN
    FOREACH v_candidate IN ARRAY ARRAY[NULLIF(p_item ->> 'gtin', ''), NULLIF(p_item ->> 'tax_gtin', '')] LOOP
      CONTINUE WHEN v_candidate IS NULL OR NOT app.is_valid_gtin(v_candidate);
      v_gtin := COALESCE(v_gtin, v_candidate);
      SELECT pb.id, pb.product_id INTO v_barcode_id, out_product_id FROM public.product_barcode pb
        JOIN public.product p ON p.id = pb.product_id AND p.deleted_at IS NULL
       WHERE pb.economic_group_id = p_group_id AND pb.code = v_candidate AND pb.deleted_at IS NULL
       LIMIT 1;
      EXIT WHEN out_product_id IS NOT NULL;
    END LOOP;
  END IF;
  -- Produto que o cliente não tem: o item fica de fora (os produtos nascem das NFC-e).
  IF out_product_id IS NULL THEN
    RETURN;
  END IF;
  IF p_supplier_id IS NOT NULL AND v_code IS NOT NULL AND v_link_id IS NULL THEN
    INSERT INTO public.product_supplier (economic_group_id, product_id, supplier_id, supplier_code)
    VALUES (p_group_id, out_product_id, p_supplier_id, v_code)
    ON CONFLICT DO NOTHING;
  END IF;
  out_fraction := COALESCE(app.effective_fraction(out_product_id, v_barcode_id, v_link_id), 1);
END;
$$;


CREATE OR REPLACE FUNCTION app.import_nfce(p_import_id uuid, p_entry text, p_note jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  job public.document_import;
  key text := p_note ->> 'access_key';
  emitted timestamptz;
  branch_id uuid;
  branch_row public.branch;
  regime smallint;
  customer_id uuid;
  sale_id uuid;
  item jsonb;
  product_id uuid;
  item_id uuid;
  payment jsonb;
  outcome text := 'imported';
  code text;
  message text;
  detail text;
  v_pending uuid;
  v_refused boolean;
BEGIN
  PERFORM app.require_import_worker();
  SELECT * INTO job FROM public.document_import d
   WHERE d.id = p_import_id AND (d.status = 'processing' OR EXISTS (
     SELECT 1 FROM public.import_waiting_note w
      WHERE w.import_id = d.id AND w.access_key = p_note ->> 'access_key' AND w.status = 'released'));
  IF job.id IS NULL THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.' USING ERRCODE = 'FA006', DETAIL = 'Importação fora do processamento.';
  END IF;
  BEGIN
    IF key !~ '^[0-9]{44}$' OR p_note ->> 'model' <> '65' THEN
      RAISE EXCEPTION 'A nota não pôde ser importada.' USING ERRCODE = 'FA743', DETAIL = 'Chave ou modelo fora do formato.';
    END IF;
    IF COALESCE(p_note ->> 'environment', '1') <> '1' THEN
      outcome := 'ignored';
      message := 'Nota de homologação, sem valor fiscal.';
    ELSIF COALESCE(p_note ->> 'status_code', '') NOT IN ('100', '150') THEN
      outcome := 'ignored';
      message := 'Nota sem autorização da Sefaz.';
    ELSIF EXISTS (SELECT 1 FROM public.imported_sale s WHERE s.access_key = key AND s.deleted_at IS NULL)
       OR app.import_key_waiting(key, job.id) THEN
      outcome := 'duplicate';
    ELSE
      emitted := (p_note ->> 'emitted_at')::timestamptz;
      -- Filial do cliente pelo CNPJ do emitente. Empresa ou filial que o cliente ainda não tem: a
      -- nota espera o administrador da plataforma decidir (criar ou recusar).
      SELECT r.out_branch, r.out_pending, r.out_refused INTO branch_id, v_pending, v_refused
        FROM app.import_branch_or_wait(job.economic_group_id, p_note -> 'issuer', true) r;
      IF v_pending IS NOT NULL THEN
        outcome := 'waiting';
        message := app.import_waiting_message(v_pending);
      ELSIF v_refused THEN
        outcome := 'ignored';
        message := 'O administrador da plataforma recusou a empresa deste CNPJ.';
      ELSE
      SELECT b.* INTO branch_row FROM public.branch b WHERE b.id = branch_id;
      SELECT c.tax_regime INTO regime FROM public.company c WHERE c.id = branch_row.company_id;
      customer_id := app.import_customer(job.economic_group_id, COALESCE(p_note -> 'customer', '{}'::jsonb));
      INSERT INTO public.imported_sale (
        economic_group_id, branch_id, import_id, access_key, model, series, number, emitted_at, protocol, customer_id,
        subtotal, discount_total, total, change_amount, xml
      ) VALUES (
        job.economic_group_id, branch_id, job.id, key, '65', (p_note ->> 'series')::integer, (p_note ->> 'number')::bigint,
        emitted, NULLIF(p_note ->> 'protocol', ''), customer_id, (p_note ->> 'subtotal')::numeric,
        COALESCE((p_note ->> 'discount')::numeric, 0), (p_note ->> 'total')::numeric, COALESCE((p_note ->> 'change')::numeric, 0),
        p_note ->> 'xml'
      ) RETURNING id INTO sale_id;
      FOR item IN SELECT value FROM pg_catalog.jsonb_array_elements(p_note -> 'items') LOOP
        product_id := app.import_product(job.economic_group_id, item, emitted);
        PERFORM app.import_tax_rule(job.economic_group_id, product_id, regime, branch_row.state, item, emitted);
        INSERT INTO public.imported_sale_item (economic_group_id, imported_sale_id, line, product_id, quantity, unit_price, discount, total, cfop)
        VALUES (
          job.economic_group_id, sale_id, (item ->> 'line')::integer, product_id, (item ->> 'quantity')::numeric,
          (item ->> 'unit_price')::numeric, COALESCE((item ->> 'discount')::numeric, 0), (item ->> 'total')::numeric,
          NULLIF(item ->> 'cfop', '')
        ) RETURNING id INTO item_id;
        INSERT INTO public.stock_movement (economic_group_id, branch_id, product_id, movement_type, quantity, occurred_at, reason, imported_sale_item_id)
        VALUES (
          job.economic_group_id, branch_id, product_id, 'import', -pg_catalog.round((item ->> 'quantity')::numeric, 3), emitted,
          'Venda importada ' || key, item_id
        );
      END LOOP;
      FOR payment IN SELECT value FROM pg_catalog.jsonb_array_elements(COALESCE(p_note -> 'payments', '[]'::jsonb)) LOOP
        INSERT INTO public.imported_sale_payment (economic_group_id, imported_sale_id, method, description, amount, card_brand, authorization_code)
        VALUES (
          job.economic_group_id, sale_id, payment ->> 'type', app.import_text(payment ->> 'description', 60),
          (payment ->> 'amount')::numeric, NULLIF(payment ->> 'card_brand', ''), app.import_text(payment ->> 'authorization', 128)
        );
      END LOOP;
      END IF;
    END IF;
  EXCEPTION
    WHEN SQLSTATE 'FA742' OR SQLSTATE 'FA743' THEN
      GET STACKED DIAGNOSTICS detail = PG_EXCEPTION_DETAIL;
      outcome := 'failed';
      code := SQLSTATE;
      message := pg_catalog.left(SQLERRM || COALESCE(' ' || NULLIF(detail, ''), ''), 500);
    WHEN check_violation OR not_null_violation OR unique_violation OR invalid_text_representation OR numeric_value_out_of_range
         OR invalid_datetime_format OR datetime_field_overflow OR foreign_key_violation OR null_value_not_allowed THEN
      outcome := 'failed';
      code := 'FA743';
      message := pg_catalog.left(SQLERRM, 500);
  END;
  PERFORM app.import_record_note(
    job, p_entry, key, CASE WHEN p_note ->> 'model' ~ '^[0-9]{2}$' THEN p_note ->> 'model' END, outcome, code, message, v_pending, p_note
  );
  RETURN pg_catalog.jsonb_build_object('result', outcome, 'code', code, 'reason', message);
END;
$$;


CREATE OR REPLACE FUNCTION app.import_nfe(p_import_id uuid, p_entry text, p_note jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  job public.document_import;
  v_key text := p_note ->> 'access_key';
  v_emitted timestamptz;
  v_issuer_branch uuid;
  v_dest_branch uuid;
  v_kinds text[];
  v_kind text;
  v_note_kind text;
  v_branch uuid;
  v_supplier uuid;
  v_customer uuid;
  v_party jsonb;
  v_sale uuid;
  v_note uuid;
  v_item jsonb;
  v_payment jsonb;
  v_product uuid;
  v_fraction numeric;
  v_quantity numeric;
  v_cost numeric;
  v_item_id uuid;
  v_sign integer;
  v_own_coded boolean;
  outcome text := 'imported';
  code text;
  message text;
  detail text;
  v_pending uuid;
  v_dest_pending uuid;
  v_skipped jsonb := '[]'::jsonb;
BEGIN
  PERFORM app.require_import_worker();
  SELECT * INTO job FROM public.document_import d
   WHERE d.id = p_import_id AND (d.status = 'processing' OR EXISTS (
     SELECT 1 FROM public.import_waiting_note w
      WHERE w.import_id = d.id AND w.access_key = p_note ->> 'access_key' AND w.status = 'released'));
  IF job.id IS NULL THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.' USING ERRCODE = 'FA006', DETAIL = 'Importação fora do processamento.';
  END IF;
  BEGIN
    IF v_key !~ '^[0-9]{44}$' OR p_note ->> 'model' <> '55' THEN
      RAISE EXCEPTION 'A nota não pôde ser importada.' USING ERRCODE = 'FA743', DETAIL = 'Chave ou modelo fora do formato.';
    END IF;
    IF COALESCE(p_note ->> 'environment', '1') <> '1' THEN
      outcome := 'ignored';
      message := 'Nota de homologação, sem valor fiscal.';
    ELSIF COALESCE(p_note ->> 'status_code', '') NOT IN ('100', '150') THEN
      outcome := 'ignored';
      message := 'Nota sem autorização da Sefaz.';
    ELSIF EXISTS (SELECT 1 FROM public.imported_sale s WHERE s.access_key = v_key AND s.deleted_at IS NULL)
       OR EXISTS (SELECT 1 FROM public.imported_stock_note n WHERE n.access_key = v_key AND n.deleted_at IS NULL)
       OR app.import_key_waiting(v_key, job.id) THEN
      outcome := 'duplicate';
    ELSE
      v_emitted := (p_note ->> 'emitted_at')::timestamptz;
      -- Filial do cliente em cada parte. Filial nova de uma empresa do cliente (ou CNPJ que já espera
      -- o destino): a nota espera junto.
      SELECT r.out_branch, r.out_pending INTO v_issuer_branch, v_pending
        FROM app.import_branch_or_wait(job.economic_group_id, p_note -> 'issuer', false) r;
      SELECT r.out_branch, r.out_pending INTO v_dest_branch, v_dest_pending
        FROM app.import_branch_or_wait(job.economic_group_id, COALESCE(p_note -> 'dest', '{}'::jsonb), false) r;
      v_pending := COALESCE(v_pending, v_dest_pending);
      SELECT pg_catalog.array_agg(DISTINCT app.import_cfop_kind(i ->> 'cfop')) INTO v_kinds
        FROM pg_catalog.jsonb_array_elements(p_note -> 'items') AS i;
      -- Natureza da nota: venda se algum item é venda; depois devolução; depois transferência.
      v_kind := CASE WHEN 'sale' = ANY (v_kinds) THEN 'sale' WHEN 'return' = ANY (v_kinds) THEN 'return'
                     WHEN 'transfer' = ANY (v_kinds) THEN 'transfer' ELSE 'other' END;

      IF v_issuer_branch IS NOT NULL AND v_dest_branch IS NOT NULL AND v_issuer_branch <> v_dest_branch THEN
        v_note_kind := 'transfer';
      ELSIF v_issuer_branch IS NOT NULL THEN
        v_note_kind := CASE
          WHEN p_note ->> 'operation' = '0' THEN 'own_entry'
          WHEN v_kind = 'sale' THEN 'sale'
          WHEN v_kind = 'return' THEN 'supplier_return'
          ELSE 'other_output' END;
      ELSIF v_dest_branch IS NOT NULL THEN
        v_note_kind := CASE
          WHEN p_note ->> 'operation' = '0' THEN NULL
          WHEN v_kind = 'sale' THEN 'purchase'
          WHEN v_kind = 'return' THEN 'customer_return'
          ELSE 'other_entry' END;
      END IF;

      IF v_pending IS NOT NULL THEN
        outcome := 'waiting';
        message := app.import_waiting_message(v_pending);
      ELSIF v_note_kind IS NULL THEN
        outcome := 'ignored';
        message := CASE WHEN v_dest_branch IS NOT NULL
          THEN 'Nota de entrada emitida por terceiro: o estoque segue a nota da própria filial.'
          ELSE 'Nenhuma filial do cliente na nota (emitente e destinatário de fora). Cadastre a empresa ou importe as NFC-e antes.' END;
      ELSIF v_note_kind = 'sale' THEN
        -- Venda em NF-e: como a NFC-e, com o cliente do destinatário.
        v_customer := app.import_customer(job.economic_group_id, pg_catalog.jsonb_build_object(
          'document', COALESCE(p_note -> 'dest' ->> 'cnpj', p_note -> 'dest' ->> 'cpf'), 'name', p_note -> 'dest' ->> 'name'));
        INSERT INTO public.imported_sale (
          economic_group_id, branch_id, import_id, access_key, model, series, number, emitted_at, protocol, customer_id,
          subtotal, discount_total, total, change_amount, xml
        ) VALUES (
          job.economic_group_id, v_issuer_branch, job.id, v_key, '55', (p_note ->> 'series')::integer, (p_note ->> 'number')::bigint,
          v_emitted, NULLIF(p_note ->> 'protocol', ''), v_customer, (p_note ->> 'subtotal')::numeric,
          COALESCE((p_note ->> 'discount')::numeric, 0), (p_note ->> 'total')::numeric, COALESCE((p_note ->> 'change')::numeric, 0),
          p_note ->> 'xml'
        ) RETURNING id INTO v_sale;
        FOR v_item IN SELECT value FROM pg_catalog.jsonb_array_elements(p_note -> 'items') LOOP
          v_product := app.import_find_product(job.economic_group_id, v_item);
          IF v_product IS NULL THEN
            v_skipped := v_skipped || app.import_skipped_item(v_item);
            CONTINUE;
          END IF;
          INSERT INTO public.imported_sale_item (economic_group_id, imported_sale_id, line, product_id, quantity, unit_price, discount, total, cfop)
          VALUES (
            job.economic_group_id, v_sale, (v_item ->> 'line')::integer, v_product, (v_item ->> 'quantity')::numeric,
            (v_item ->> 'unit_price')::numeric, COALESCE((v_item ->> 'discount')::numeric, 0), (v_item ->> 'total')::numeric,
            NULLIF(v_item ->> 'cfop', '')
          ) RETURNING id INTO v_item_id;
          INSERT INTO public.stock_movement (economic_group_id, branch_id, product_id, movement_type, quantity, occurred_at, reason, imported_sale_item_id)
          VALUES (job.economic_group_id, v_issuer_branch, v_product, 'import', -pg_catalog.round((v_item ->> 'quantity')::numeric, 3),
                  v_emitted, 'Venda importada ' || v_key, v_item_id);
        END LOOP;
        PERFORM app.import_require_items(v_skipped, p_note -> 'items');
        UPDATE public.imported_sale s SET skipped_items = v_skipped WHERE s.id = v_sale;
        FOR v_payment IN SELECT value FROM pg_catalog.jsonb_array_elements(COALESCE(p_note -> 'payments', '[]'::jsonb)) LOOP
          INSERT INTO public.imported_sale_payment (economic_group_id, imported_sale_id, method, description, amount, card_brand, authorization_code)
          VALUES (
            job.economic_group_id, v_sale, v_payment ->> 'type', app.import_text(v_payment ->> 'description', 60),
            (v_payment ->> 'amount')::numeric, NULLIF(v_payment ->> 'card_brand', ''), app.import_text(v_payment ->> 'authorization', 128)
          );
        END LOOP;
      ELSE
        -- Nota de estoque: a filial do cliente e a outra parte.
        IF v_note_kind IN ('purchase', 'customer_return', 'other_entry') THEN
          v_branch := v_dest_branch;
          v_party := p_note -> 'issuer';
          IF v_note_kind IN ('purchase', 'other_entry') THEN
            v_supplier := app.import_supplier(job.economic_group_id, v_party);
          END IF;
        ELSE
          v_branch := v_issuer_branch;
          v_party := COALESCE(p_note -> 'dest', '{}'::jsonb);
          IF v_note_kind = 'supplier_return' THEN
            v_supplier := app.import_supplier(job.economic_group_id, v_party);
          END IF;
        END IF;
        -- Código do cliente nas notas que ele emitiu; código do fornecedor nas de fora.
        v_own_coded := v_note_kind IN ('own_entry', 'supplier_return', 'transfer', 'other_output');
        INSERT INTO public.imported_stock_note (
          economic_group_id, branch_id, counterpart_branch_id, import_id, access_key, model, series, number, emitted_at, protocol,
          kind, own_issued, cfop, supplier_id, party_document, party_name, total, xml
        ) VALUES (
          job.economic_group_id, v_branch, CASE WHEN v_note_kind = 'transfer' THEN v_dest_branch END, job.id, v_key, '55',
          (p_note ->> 'series')::integer, (p_note ->> 'number')::bigint, v_emitted, NULLIF(p_note ->> 'protocol', ''),
          v_note_kind, v_own_coded, NULLIF(p_note -> 'items' -> 0 ->> 'cfop', ''), v_supplier,
          COALESCE(NULLIF(v_party ->> 'cnpj', ''), NULLIF(v_party ->> 'cpf', '')), app.import_text(v_party ->> 'name', 150),
          (p_note ->> 'total')::numeric, p_note ->> 'xml'
        ) RETURNING id INTO v_note;
        v_sign := CASE WHEN v_note_kind IN ('purchase', 'customer_return', 'other_entry', 'own_entry') THEN 1 ELSE -1 END;
        FOR v_item IN SELECT value FROM pg_catalog.jsonb_array_elements(p_note -> 'items') LOOP
          IF v_own_coded THEN
            v_product := app.import_find_product(job.economic_group_id, v_item);
            v_fraction := 1;
          ELSE
            SELECT r.out_product_id, r.out_fraction INTO v_product, v_fraction
              FROM app.import_purchase_product(job.economic_group_id, v_supplier, v_item) r;
          END IF;
          -- Produtos nascem só das NFC-e: o item sem produto fica de fora (anotado na nota).
          IF v_product IS NULL THEN
            v_skipped := v_skipped || app.import_skipped_item(v_item);
            CONTINUE;
          END IF;
          v_quantity := pg_catalog.round((v_item ->> 'quantity')::numeric * v_fraction, 3);
          v_cost := NULL;
          IF v_note_kind = 'purchase' AND app.import_cfop_kind(v_item ->> 'cfop') = 'sale' AND v_quantity > 0 THEN
            v_cost := GREATEST(pg_catalog.round((
              COALESCE((v_item ->> 'products_value')::numeric, 0) - COALESCE((v_item ->> 'discount')::numeric, 0)
              + COALESCE((v_item ->> 'freight')::numeric, 0) + COALESCE((v_item ->> 'insurance')::numeric, 0)
              + COALESCE((v_item ->> 'other')::numeric, 0) + COALESCE((v_item ->> 'ipi')::numeric, 0)
              + COALESCE((v_item ->> 'st')::numeric, 0) + COALESCE((v_item ->> 'fcp_st')::numeric, 0)
            ) / v_quantity, 6), 0);
          END IF;
          INSERT INTO public.imported_stock_note_item (
            economic_group_id, note_id, line, product_id, supplier_code, note_quantity, quantity, unit, total, unit_cost, cfop, batches
          ) VALUES (
            job.economic_group_id, v_note, (v_item ->> 'line')::integer, v_product,
            CASE WHEN NOT v_own_coded THEN app.import_text(v_item ->> 'code', 60) END,
            (v_item ->> 'quantity')::numeric, v_quantity, app.import_text(v_item ->> 'unit', 6), (v_item ->> 'total')::numeric,
            v_cost, NULLIF(v_item ->> 'cfop', ''), COALESCE(v_item -> 'batches', '[]'::jsonb)
          ) RETURNING id INTO v_item_id;
          IF v_cost IS NOT NULL THEN
            PERFORM app.import_product_cost(job.economic_group_id, v_branch, v_product, v_item_id, v_cost, v_quantity, v_emitted);
          END IF;
          INSERT INTO public.stock_movement (economic_group_id, branch_id, product_id, movement_type, quantity, occurred_at, reason, imported_stock_item_id)
          VALUES (job.economic_group_id, v_branch, v_product, 'import', v_sign * v_quantity, v_emitted, 'Nota importada ' || v_key, v_item_id);
          IF v_note_kind = 'transfer' THEN
            INSERT INTO public.stock_movement (economic_group_id, branch_id, product_id, movement_type, quantity, occurred_at, reason, imported_stock_item_id)
            VALUES (job.economic_group_id, v_dest_branch, v_product, 'import', v_quantity, v_emitted, 'Transferência importada ' || v_key, v_item_id);
          END IF;
        END LOOP;
        PERFORM app.import_require_items(v_skipped, p_note -> 'items');
        UPDATE public.imported_stock_note n SET skipped_items = v_skipped WHERE n.id = v_note;
      END IF;
    END IF;
  EXCEPTION
    WHEN SQLSTATE 'FA759' THEN
      outcome := 'ignored';
      message := 'Nenhum item da nota tem produto cadastrado (os produtos nascem das NFC-e importadas).';
    WHEN SQLSTATE 'FA742' OR SQLSTATE 'FA743' THEN
      GET STACKED DIAGNOSTICS detail = PG_EXCEPTION_DETAIL;
      outcome := 'failed';
      code := SQLSTATE;
      message := pg_catalog.left(SQLERRM || COALESCE(' ' || NULLIF(detail, ''), ''), 500);
    WHEN check_violation OR not_null_violation OR unique_violation OR invalid_text_representation OR numeric_value_out_of_range
         OR invalid_datetime_format OR datetime_field_overflow OR foreign_key_violation OR null_value_not_allowed
         OR division_by_zero THEN
      outcome := 'failed';
      code := 'FA743';
      message := pg_catalog.left(SQLERRM, 500);
  END;
  -- Nota que entrou sem alguns itens: o motivo diz quantos ficaram de fora.
  IF outcome = 'imported' AND pg_catalog.jsonb_array_length(v_skipped) > 0 THEN
    message := pg_catalog.jsonb_array_length(v_skipped) || ' item(ns) sem produto cadastrado ficaram de fora.';
  END IF;
  PERFORM app.import_record_note(job, p_entry, v_key, '55', outcome, code, message, v_pending, p_note);
  RETURN pg_catalog.jsonb_build_object('result', outcome, 'code', code, 'reason', message, 'kind', v_note_kind);
END;
$$;


CREATE OR REPLACE FUNCTION app.import_nfce_cancel(p_import_id uuid, p_entry text, p_key text, p_canceled_at timestamptz) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  job public.document_import;
  sale public.imported_sale;
  stock_note public.imported_stock_note;
  movement public.stock_movement;
  entry public.product_cost;
  at timestamptz := COALESCE(p_canceled_at, pg_catalog.now());
  waiting public.import_waiting_note;
BEGIN
  PERFORM app.require_import_worker();
  SELECT * INTO job FROM public.document_import d WHERE d.id = p_import_id AND d.status = 'processing';
  IF job.id IS NULL THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.' USING ERRCODE = 'FA006', DETAIL = 'Importação fora do processamento.';
  END IF;
  SELECT * INTO sale FROM public.imported_sale s
   WHERE s.access_key = p_key AND s.economic_group_id = job.economic_group_id AND s.deleted_at IS NULL FOR UPDATE;
  IF sale.id IS NOT NULL AND sale.canceled_at IS NULL THEN
    UPDATE public.imported_sale s SET canceled_at = at WHERE s.id = sale.id;
    FOR movement IN
      SELECT m.* FROM public.stock_movement m
        JOIN public.imported_sale_item i ON i.id = m.imported_sale_item_id
       WHERE i.imported_sale_id = sale.id AND m.reversal_of IS NULL AND m.deleted_at IS NULL
    LOOP
      INSERT INTO public.stock_movement (economic_group_id, branch_id, product_id, batch_id, movement_type, quantity, occurred_at, reason, reversal_of)
      VALUES (movement.economic_group_id, movement.branch_id, movement.product_id, movement.batch_id, 'import', -movement.quantity,
              at, 'Nota cancelada ' || p_key, movement.id);
    END LOOP;
  END IF;
  SELECT * INTO stock_note FROM public.imported_stock_note n
   WHERE n.access_key = p_key AND n.economic_group_id = job.economic_group_id AND n.deleted_at IS NULL FOR UPDATE;
  IF stock_note.id IS NOT NULL AND stock_note.canceled_at IS NULL THEN
    UPDATE public.imported_stock_note n SET canceled_at = at WHERE n.id = stock_note.id;
    FOR movement IN
      SELECT m.* FROM public.stock_movement m
        JOIN public.imported_stock_note_item i ON i.id = m.imported_stock_item_id
       WHERE i.note_id = stock_note.id AND m.reversal_of IS NULL AND m.deleted_at IS NULL
    LOOP
      INSERT INTO public.stock_movement (economic_group_id, branch_id, product_id, batch_id, movement_type, quantity, occurred_at, reason, reversal_of)
      VALUES (movement.economic_group_id, movement.branch_id, movement.product_id, movement.batch_id, 'import', -movement.quantity,
              at, 'Nota cancelada ' || p_key, movement.id);
    END LOOP;
    -- Custo da compra cancelada: estorno, se ele ainda é o custo em vigor (uma compra mais nova manda).
    FOR entry IN
      SELECT c.* FROM public.product_cost c
        JOIN public.imported_stock_note_item i ON i.id = c.imported_stock_item_id
       WHERE i.note_id = stock_note.id AND c.reversal_of IS NULL AND c.deleted_at IS NULL
    LOOP
      CONTINUE WHEN EXISTS (
        SELECT 1 FROM public.product_cost newer
         WHERE newer.product_id = entry.product_id AND newer.branch_id = entry.branch_id AND newer.deleted_at IS NULL
           AND (newer.created_at, newer.id) > (entry.created_at, entry.id)
      );
      INSERT INTO public.product_cost (
        economic_group_id, branch_id, product_id, average_cost, previous_cost, stock_before, entry_quantity, entry_cost,
        imported_stock_item_id, reversal_of
      ) VALUES (
        entry.economic_group_id, entry.branch_id, entry.product_id, entry.previous_cost, entry.average_cost,
        app.branch_stock_quantity(entry.product_id, entry.branch_id), -entry.entry_quantity, entry.entry_cost,
        entry.imported_stock_item_id, entry.id
      );
    END LOOP;
  END IF;
  -- Nota que ainda espera o destino do CNPJ: não entra mais (cancelada).
  IF sale.id IS NULL AND stock_note.id IS NULL THEN
    SELECT * INTO waiting FROM public.import_waiting_note w
     WHERE w.access_key = p_key AND w.economic_group_id = job.economic_group_id AND w.status IN ('waiting', 'released')
       AND w.deleted_at IS NULL
     FOR UPDATE;
    IF waiting.id IS NOT NULL THEN
      UPDATE public.import_waiting_note w SET status = 'done', processed_at = pg_catalog.now(), locked_until = NULL WHERE w.id = waiting.id;
      UPDATE public.document_import_note n SET result = 'canceled', reason = 'Nota cancelada enquanto esperava o destino do CNPJ.'
       WHERE n.id = waiting.import_note_id;
      -- Na importação em andamento, quem conta é o processamento; nas anteriores, a conta muda aqui.
      IF waiting.import_id <> job.id THEN
        PERFORM app.import_totals_move(waiting.import_id, 'waiting', 'canceled', 1);
      END IF;
    END IF;
  END IF;
  INSERT INTO public.document_import_note (economic_group_id, import_id, entry_name, access_key, model, result, reason)
  VALUES (job.economic_group_id, job.id, pg_catalog.left(COALESCE(p_entry, '?'), 300), CASE WHEN p_key ~ '^[0-9]{44}$' THEN p_key END,
          CASE WHEN pg_catalog.substr(p_key, 21, 2) ~ '^[0-9]{2}$' THEN pg_catalog.substr(p_key, 21, 2) END, 'canceled',
          CASE WHEN waiting.id IS NOT NULL THEN 'Cancelamento de nota que esperava o destino do CNPJ.'
               WHEN sale.id IS NULL AND stock_note.id IS NULL THEN 'Cancelamento de nota que não está na importação.' END);
  RETURN pg_catalog.jsonb_build_object(
    'result', 'canceled', 'found', sale.id IS NOT NULL OR stock_note.id IS NOT NULL OR waiting.id IS NOT NULL,
    'was_waiting', waiting.id IS NOT NULL AND waiting.import_id = job.id
  );
END;
$$;


CREATE OR REPLACE FUNCTION app.document_import_report(p_import_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.require_imports_manage();
  target public.document_import;
BEGIN
  SELECT * INTO target FROM public.document_import d WHERE d.id = p_import_id AND d.economic_group_id = group_id AND d.deleted_at IS NULL;
  IF target.id IS NULL THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.' USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('document_import %s.', p_import_id);
  END IF;
  RETURN pg_catalog.jsonb_build_object(
    'id', target.id, 'file_name', target.file_name, 'size_bytes', target.size_bytes, 'received_bytes', target.received_bytes,
    'status', target.status, 'totals', target.totals, 'error', target.error, 'started_at', target.started_at,
    'finished_at', target.finished_at, 'created_at', target.created_at,
    -- Ignoradas, contadas por motivo (nota de fora da rede, homologação, outro documento...).
    'ignored_reasons', COALESCE((
      SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('reason', x.reason, 'total', x.total) ORDER BY x.total DESC, x.reason)
        FROM (SELECT COALESCE(n.reason, 'Sem motivo informado.') AS reason, pg_catalog.count(*)::integer AS total
                FROM public.document_import_note n
               WHERE n.import_id = target.id AND n.result = 'ignored' AND n.deleted_at IS NULL
               GROUP BY 1) x), '[]'::jsonb),
    -- CNPJs que esperam o administrador da plataforma (e os já decididos), com as notas desta importação.
    'waiting', COALESCE((
      SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
               'cnpj', p.cnpj, 'name', p.issuer ->> 'name', 'status', p.status, 'notes', x.notes) ORDER BY p.cnpj)
        FROM (SELECT w.pending_issuer_id, pg_catalog.count(*)::integer AS notes
                FROM public.import_waiting_note w
               WHERE w.import_id = target.id AND w.deleted_at IS NULL AND w.status <> 'done'
               GROUP BY w.pending_issuer_id) x
        JOIN public.import_pending_issuer p ON p.id = x.pending_issuer_id), '[]'::jsonb),
    -- Itens de NF-e sem produto cadastrado, que ficaram de fora (até 500).
    'skipped_items', COALESCE((
      SELECT pg_catalog.jsonb_agg(y.item ORDER BY y.number, (y.item ->> 'line')::integer)
        FROM (SELECT s.number, i.value || pg_catalog.jsonb_build_object('note_number', s.number, 'access_key', s.access_key) AS item
                FROM (SELECT n.number, n.access_key, n.skipped_items FROM public.imported_stock_note n
                       WHERE n.import_id = target.id AND n.deleted_at IS NULL
                      UNION ALL
                      SELECT v.number, v.access_key, v.skipped_items FROM public.imported_sale v
                       WHERE v.import_id = target.id AND v.deleted_at IS NULL) s,
                     LATERAL pg_catalog.jsonb_array_elements(s.skipped_items) i
               ORDER BY s.number LIMIT 500) y), '[]'::jsonb),
    'skipped_total', (
      SELECT COALESCE(pg_catalog.sum(pg_catalog.jsonb_array_length(s.skipped_items)), 0)::integer
        FROM (SELECT n.skipped_items FROM public.imported_stock_note n WHERE n.import_id = target.id AND n.deleted_at IS NULL
              UNION ALL
              SELECT v.skipped_items FROM public.imported_sale v WHERE v.import_id = target.id AND v.deleted_at IS NULL) s),
    -- Problemas, para corrigir (até 500).
    'problems', COALESCE((
      SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
               'entry_name', n.entry_name, 'access_key', n.access_key, 'model', n.model, 'result', n.result,
               'error_code', n.error_code, 'reason', n.reason) ORDER BY n.created_at)
        FROM (SELECT * FROM public.document_import_note n
               WHERE n.import_id = target.id AND n.result = 'failed' AND n.deleted_at IS NULL
               ORDER BY n.created_at LIMIT 500) n), '[]'::jsonb),
    -- Última numeração por filial, modelo e série, para continuar sem repetir número.
    'last_numbers', COALESCE((
      SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
               'branch_id', x.branch_id, 'branch_name', b.name, 'model', x.model, 'series', x.series, 'last_number', x.last_number)
             ORDER BY b.name, x.model, x.series)
        FROM (SELECT u.branch_id, u.model, u.series, pg_catalog.max(u.number) AS last_number
                FROM (SELECT s.branch_id, s.model, s.series, s.number
                        FROM public.imported_sale s WHERE s.import_id = target.id AND s.deleted_at IS NULL
                      UNION ALL
                      SELECT n.branch_id, n.model, n.series, n.number
                        FROM public.imported_stock_note n
                       WHERE n.import_id = target.id AND n.deleted_at IS NULL AND n.own_issued) u
               GROUP BY u.branch_id, u.model, u.series) x
        JOIN public.branch b ON b.id = x.branch_id), '[]'::jsonb)
  );
END;
$$;


-- Notas liberadas pela decisão, para a rotina da importação: NFC-e antes (os produtos nascem
-- delas), só de importações já concluídas, reservadas por 10 minutos.
CREATE FUNCTION app.claim_released_import_notes(p_limit integer) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  picked jsonb;
BEGIN
  PERFORM app.require_import_worker();
  WITH chosen AS (
    SELECT w.id FROM public.import_waiting_note w
      JOIN public.document_import d ON d.id = w.import_id AND d.status = 'done'
     WHERE w.status = 'released' AND w.deleted_at IS NULL AND (w.locked_until IS NULL OR w.locked_until < pg_catalog.now())
     ORDER BY w.model = '55', w.created_at, w.id
     LIMIT LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200)
       FOR UPDATE OF w SKIP LOCKED
  ), locked AS (
    UPDATE public.import_waiting_note w SET locked_until = pg_catalog.now() + interval '10 minutes'
      FROM chosen WHERE w.id = chosen.id
    RETURNING w.import_id, w.entry_name, w.model, w.note, w.created_at, w.id
  )
  SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
           'import_id', l.import_id, 'entry', l.entry_name, 'model', l.model, 'note', l.note) ORDER BY l.model = '55', l.created_at, l.id)
    INTO picked FROM locked l;
  RETURN COALESCE(picked, '[]'::jsonb);
END;
$$;

-- Plataforma: CNPJs que esperam destino, de todos os clientes. O administrador da plataforma vê só
-- o nome do cliente, os dados do CNPJ da nota, a empresa de mesma raiz (se houver) e a contagem.
CREATE FUNCTION app.platform_pending_issuers()
RETURNS TABLE (
  id uuid, group_id uuid, group_name text, cnpj text, name text, trade_name text, state text, tax_regime smallint,
  kind text, company_name text, notes integer, first_emitted_at timestamptz, last_emitted_at timestamptz, created_at timestamptz
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM app.require_platform_admin();
  RETURN QUERY
  SELECT p.id, g.id, g.name, p.cnpj, p.issuer ->> 'name', p.issuer ->> 'trade_name', pg_catalog.upper(p.issuer ->> 'uf'),
         CASE WHEN p.issuer ->> 'crt' IN ('1', '2', '3', '4') THEN (p.issuer ->> 'crt')::smallint END,
         CASE WHEN c.id IS NULL THEN 'company' ELSE 'branch' END, c.legal_name,
         (SELECT pg_catalog.count(*)::integer FROM public.import_waiting_note w
           WHERE w.pending_issuer_id = p.id AND w.status = 'waiting' AND w.deleted_at IS NULL),
         (SELECT pg_catalog.min((w.note ->> 'emitted_at')::timestamptz) FROM public.import_waiting_note w
           WHERE w.pending_issuer_id = p.id AND w.status = 'waiting' AND w.deleted_at IS NULL),
         (SELECT pg_catalog.max((w.note ->> 'emitted_at')::timestamptz) FROM public.import_waiting_note w
           WHERE w.pending_issuer_id = p.id AND w.status = 'waiting' AND w.deleted_at IS NULL),
         p.created_at
    FROM public.import_pending_issuer p
    JOIN public.economic_group g ON g.id = p.economic_group_id
    LEFT JOIN public.company c
      ON c.economic_group_id = p.economic_group_id AND c.cnpj_root = pg_catalog.left(p.cnpj, 8) AND c.deleted_at IS NULL
   WHERE p.status = 'pending' AND p.deleted_at IS NULL
   ORDER BY p.created_at, p.id;
END;
$$;

-- Decisão do administrador da plataforma. create: cria a empresa e a filial (ou só a filial, na
-- empresa de mesma raiz) no cliente que importou, com nome, fantasia e regime revisados; as notas
-- que esperavam entram pela rotina da importação. refuse: as notas ficam ignoradas com o motivo.
CREATE FUNCTION app.platform_resolve_issuer(p_id uuid, p_decision text, p_data jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_pending public.import_pending_issuer;
  v_issuer jsonb;
  v_branch uuid;
  v_count integer;
  v_job record;
  v_legal text;
  v_trade text;
  v_regime text;
BEGIN
  PERFORM app.require_platform_admin();
  IF p_decision IS NULL OR p_decision NOT IN ('create', 'refuse')
     OR (p_data IS NOT NULL AND pg_catalog.jsonb_typeof(p_data) <> 'object') THEN
    RAISE EXCEPTION 'Alguns dados informados são inválidos.' USING ERRCODE = 'FA005', DETAIL = 'Decisão do CNPJ.';
  END IF;
  SELECT * INTO v_pending FROM public.import_pending_issuer p WHERE p.id = p_id AND p.deleted_at IS NULL FOR UPDATE;
  IF v_pending.id IS NULL THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.' USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('import_pending_issuer %s.', p_id);
  END IF;
  IF v_pending.status <> 'pending' THEN
    RAISE EXCEPTION 'Este CNPJ já foi decidido.' USING ERRCODE = 'FA758', DETAIL = v_pending.status;
  END IF;

  IF p_decision = 'refuse' THEN
    UPDATE public.import_pending_issuer p
       SET status = 'refused', decided_by = app.current_user_id(), decided_at = pg_catalog.now()
     WHERE p.id = v_pending.id;
    FOR v_job IN
      SELECT w.import_id, pg_catalog.count(*)::integer AS total FROM public.import_waiting_note w
       WHERE w.pending_issuer_id = v_pending.id AND w.status = 'waiting' AND w.deleted_at IS NULL
       GROUP BY w.import_id
    LOOP
      PERFORM app.import_totals_move(v_job.import_id, 'waiting', 'ignored', v_job.total);
    END LOOP;
    UPDATE public.document_import_note n
       SET result = 'ignored', reason = 'O administrador da plataforma recusou a empresa deste CNPJ.'
      FROM public.import_waiting_note w
     WHERE w.import_note_id = n.id AND w.pending_issuer_id = v_pending.id AND w.status = 'waiting' AND w.deleted_at IS NULL;
    UPDATE public.import_waiting_note w SET status = 'done', processed_at = pg_catalog.now()
     WHERE w.pending_issuer_id = v_pending.id AND w.status = 'waiting' AND w.deleted_at IS NULL;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN pg_catalog.jsonb_build_object('status', 'refused', 'notes', v_count);
  END IF;

  v_legal := app.import_text(p_data ->> 'legalName', 150);
  v_trade := app.import_text(p_data ->> 'tradeName', 150);
  v_regime := p_data ->> 'taxRegime';
  IF v_regime IS NOT NULL AND v_regime NOT IN ('1', '2', '3', '4') THEN
    RAISE EXCEPTION 'Alguns dados informados são inválidos.' USING ERRCODE = 'FA005', DETAIL = 'Regime tributário.';
  END IF;
  v_issuer := v_pending.issuer || pg_catalog.jsonb_strip_nulls(pg_catalog.jsonb_build_object(
    'name', v_legal, 'trade_name', v_trade, 'crt', v_regime));
  v_branch := app.import_branch(v_pending.economic_group_id, v_issuer);
  UPDATE public.import_pending_issuer p
     SET status = 'created', branch_id = v_branch, decided_by = app.current_user_id(), decided_at = pg_catalog.now()
   WHERE p.id = v_pending.id;
  UPDATE public.import_waiting_note w SET status = 'released', locked_until = NULL
   WHERE w.pending_issuer_id = v_pending.id AND w.status = 'waiting' AND w.deleted_at IS NULL;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN pg_catalog.jsonb_build_object('status', 'created', 'branch_id', v_branch, 'notes', v_count);
END;
$$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  app.claim_released_import_notes(integer),
  app.platform_pending_issuers(),
  app.platform_resolve_issuer(uuid, text, jsonb)
TO farmaerp_app;
