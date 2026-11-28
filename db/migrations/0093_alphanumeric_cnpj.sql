-- Up Migration

-- CNPJ alfanumérico (IN RFB 2.229/2024; NT Conjunta DFe 2025.001 v1.00: homologação 06/04/2026,
-- produção 06/07/2026; NT 2026.004 v1.01 para os schemas da NF-e e da NFC-e). O CNPJ passa a ter
-- letras nas 12 primeiras posições, e a chave de acesso também (posições 7 a 18). As validações com o
-- dígito (app.is_valid_cnpj e app.is_valid_access_key) já aceitavam letras; aqui saem as conferências
-- de formato que ainda exigiam só números. Os nomes das restrições continuam os mesmos.

ALTER TABLE fiscal_document DROP CONSTRAINT fiscal_document_access_key_check;
ALTER TABLE fiscal_document ADD CONSTRAINT fiscal_document_access_key_check CHECK (access_key ~ '^[0-9]{6}[0-9A-Z]{12}[0-9]{26}$');
ALTER TABLE document_import_note DROP CONSTRAINT document_import_note_key_check;
ALTER TABLE document_import_note ADD CONSTRAINT document_import_note_key_check CHECK (access_key ~ '^[0-9]{6}[0-9A-Z]{12}[0-9]{26}$');
ALTER TABLE imported_sale DROP CONSTRAINT imported_sale_key_check;
ALTER TABLE imported_sale ADD CONSTRAINT imported_sale_key_check CHECK (access_key ~ '^[0-9]{6}[0-9A-Z]{12}[0-9]{26}$');
ALTER TABLE imported_stock_note DROP CONSTRAINT imported_stock_note_key_check;
ALTER TABLE imported_stock_note ADD CONSTRAINT imported_stock_note_key_check CHECK (access_key ~ '^[0-9]{6}[0-9A-Z]{12}[0-9]{26}$');
ALTER TABLE import_waiting_note DROP CONSTRAINT import_waiting_note_key_check;
ALTER TABLE import_waiting_note ADD CONSTRAINT import_waiting_note_key_check CHECK (access_key ~ '^[0-9]{6}[0-9A-Z]{12}[0-9]{26}$');
ALTER TABLE central_nfe DROP CONSTRAINT central_nfe_access_key_check;
ALTER TABLE central_nfe ADD CONSTRAINT central_nfe_access_key_check CHECK (access_key ~ '^[0-9]{6}[0-9A-Z]{12}[0-9]{26}$');
-- Documento da contraparte na nota importada: CPF (11 números) ou CNPJ, com ou sem letras.
ALTER TABLE imported_stock_note DROP CONSTRAINT imported_stock_note_party_document_check;
ALTER TABLE imported_stock_note ADD CONSTRAINT imported_stock_note_party_document_check
  CHECK (party_document ~ '^[0-9]{11}$|^[0-9A-Z]{12}[0-9]{2}$');

-- A importação das notas emitidas reconhece a chave com letras (o resto das funções não muda).
CREATE OR REPLACE FUNCTION app.import_record_note(
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
  IF p_key ~ '^[0-9]{6}[0-9A-Z]{12}[0-9]{26}$' THEN
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
    -- A cópia da nota não fica guardada duas vezes: o XML já está na venda ou na nota importada.
    UPDATE public.import_waiting_note w SET status = 'done', processed_at = pg_catalog.now(), locked_until = NULL, note = '{}'::jsonb
     WHERE w.id = v_waiting.id;
    PERFORM app.import_totals_move(p_job.id, 'waiting', p_outcome, 1);
    -- Cancelada enquanto esperava: entra e já sai cancelada, como as outras.
    IF p_outcome = 'imported' AND v_waiting.canceled_at IS NOT NULL THEN
      PERFORM app.import_cancel_apply(p_job.economic_group_id, p_key, v_waiting.canceled_at);
    END IF;
    RETURN;
  END IF;
  INSERT INTO public.document_import_note (economic_group_id, import_id, entry_name, access_key, model, result, error_code, reason)
  VALUES (
    p_job.economic_group_id, p_job.id, pg_catalog.left(COALESCE(p_entry, '?'), 300),
    CASE WHEN p_key ~ '^[0-9]{6}[0-9A-Z]{12}[0-9]{26}$' THEN p_key END, p_model, p_outcome, p_code, p_reason
  ) RETURNING id INTO v_note_id;
  IF p_outcome = 'waiting' THEN
    INSERT INTO public.import_waiting_note (
      economic_group_id, import_id, import_note_id, pending_issuer_id, entry_name, access_key, model, note, emitted_at
    ) VALUES (
      p_job.economic_group_id, p_job.id, v_note_id, p_pending, pg_catalog.left(COALESCE(p_entry, '?'), 300), p_key, p_model, p_note,
      (p_note ->> 'emitted_at')::timestamptz
    );
  END IF;
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
      WHERE w.access_key = p_note ->> 'access_key' AND w.import_id = d.id AND w.status = 'released' AND w.deleted_at IS NULL));
  IF job.id IS NULL THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.' USING ERRCODE = 'FA006', DETAIL = 'Importação fora do processamento.';
  END IF;
  BEGIN
    IF key !~ '^[0-9]{6}[0-9A-Z]{12}[0-9]{26}$' OR p_note ->> 'model' <> '65' THEN
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

CREATE OR REPLACE FUNCTION app.import_nfce_cancel(p_import_id uuid, p_entry text, p_key text, p_canceled_at timestamptz) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  job public.document_import;
  at timestamptz := COALESCE(p_canceled_at, pg_catalog.now());
  found boolean;
  waiting uuid;
BEGIN
  PERFORM app.require_import_worker();
  SELECT * INTO job FROM public.document_import d WHERE d.id = p_import_id AND d.status = 'processing';
  IF job.id IS NULL THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.' USING ERRCODE = 'FA006', DETAIL = 'Importação fora do processamento.';
  END IF;
  found := app.import_cancel_apply(job.economic_group_id, p_key, at);
  IF NOT found THEN
    UPDATE public.import_waiting_note w SET canceled_at = COALESCE(w.canceled_at, at)
     WHERE w.access_key = p_key AND w.economic_group_id = job.economic_group_id AND w.status IN ('waiting', 'released')
       AND w.deleted_at IS NULL
    RETURNING w.id INTO waiting;
  END IF;
  INSERT INTO public.document_import_note (economic_group_id, import_id, entry_name, access_key, model, result, reason)
  VALUES (job.economic_group_id, job.id, pg_catalog.left(COALESCE(p_entry, '?'), 300), CASE WHEN p_key ~ '^[0-9]{6}[0-9A-Z]{12}[0-9]{26}$' THEN p_key END,
          CASE WHEN pg_catalog.substr(p_key, 21, 2) ~ '^[0-9]{2}$' THEN pg_catalog.substr(p_key, 21, 2) END, 'canceled',
          CASE WHEN waiting IS NOT NULL THEN 'Cancelamento guardado: a nota espera o destino do CNPJ e entra já cancelada.'
               WHEN NOT found THEN 'Cancelamento de nota que não está na importação.' END);
  RETURN pg_catalog.jsonb_build_object('result', 'canceled', 'found', found OR waiting IS NOT NULL);
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
      WHERE w.access_key = p_note ->> 'access_key' AND w.import_id = d.id AND w.status = 'released' AND w.deleted_at IS NULL));
  IF job.id IS NULL THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.' USING ERRCODE = 'FA006', DETAIL = 'Importação fora do processamento.';
  END IF;
  BEGIN
    IF v_key !~ '^[0-9]{6}[0-9A-Z]{12}[0-9]{26}$' OR p_note ->> 'model' <> '55' THEN
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
