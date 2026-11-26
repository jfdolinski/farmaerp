-- Up Migration

-- Importação do NF-e 55 (I3a). A direção sai do CNPJ: filial do cliente no emitente, no
-- destinatário ou nos dois (transferência). As regras:
-- * Emitida pelo cliente (saída, tpNF 1), pelo CFOP: venda vira venda importada (imported_sale,
--   modelo 55, cliente pelo destinatário); devolução ao fornecedor e outras saídas baixam o
--   estoque; transferência entre filiais tira de uma e põe na outra. Entrada emitida pelo cliente
--   (tpNF 0, ex.: devolução de consumidor) soma no estoque. Produto pelo código do cliente.
-- * Recebida (destinatário filial do cliente): compra, devolução de cliente ou outra entrada, que
--   somam no estoque. Fornecedor pelo CNPJ do emitente; produto pelo vínculo código do fornecedor,
--   depois pelo GTIN, senão criado; o vínculo fica gravado para as próximas notas.
-- * Custo: o da compra mais recente importada (a média fora da ordem das datas sairia errada). O
--   custo de uma compra lançada no próprio sistema não é trocado.
-- * Lote e validade ficam no item (sem saldo por lote) e nada disso entra no SNGPC.
-- * Nota de fora (nenhuma filial do cliente), de homologação ou sem autorização: ignorada.

CREATE TABLE imported_stock_note (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  -- Filial do cliente: a que emitiu (saídas, entrada própria, transferência) ou a que recebeu.
  branch_id uuid NOT NULL REFERENCES branch (id),
  -- Transferência: a filial que recebeu.
  counterpart_branch_id uuid REFERENCES branch (id),
  import_id uuid NOT NULL REFERENCES document_import (id),
  access_key text NOT NULL CONSTRAINT imported_stock_note_key_check CHECK (access_key ~ '^[0-9]{44}$'),
  model text NOT NULL CONSTRAINT imported_stock_note_model_check CHECK (model = '55'),
  series integer NOT NULL CONSTRAINT imported_stock_note_series_check CHECK (series BETWEEN 0 AND 999),
  number bigint NOT NULL CONSTRAINT imported_stock_note_number_check CHECK (number BETWEEN 1 AND 999999999),
  emitted_at timestamptz NOT NULL,
  protocol text CONSTRAINT imported_stock_note_protocol_check CHECK (protocol ~ '^[0-9]{15}$'),
  kind text NOT NULL CONSTRAINT imported_stock_note_kind_check CHECK (kind IN (
    'purchase', 'customer_return', 'other_entry', 'own_entry', 'supplier_return', 'transfer', 'other_output'
  )),
  -- Emitida pelo cliente: conta na última numeração.
  own_issued boolean NOT NULL,
  cfop text CONSTRAINT imported_stock_note_cfop_check CHECK (cfop ~ '^[1-7][0-9]{3}$'),
  supplier_id uuid REFERENCES supplier (id),
  -- Outra parte da nota (fornecedor, cliente ou filial), como veio.
  party_document text CONSTRAINT imported_stock_note_party_document_check CHECK (party_document ~ '^[0-9]{11}$|^[0-9]{14}$'),
  party_name text CONSTRAINT imported_stock_note_party_name_check CHECK (length(party_name) <= 150),
  total numeric(14, 2) NOT NULL CONSTRAINT imported_stock_note_total_check CHECK (total >= 0),
  xml text NOT NULL CONSTRAINT imported_stock_note_xml_check CHECK (length(xml) BETWEEN 100 AND 5000000),
  canceled_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid,
  CONSTRAINT imported_stock_note_transfer_check CHECK ((kind = 'transfer') = (counterpart_branch_id IS NOT NULL))
);
CREATE UNIQUE INDEX imported_stock_note_key_key ON imported_stock_note (access_key) WHERE deleted_at IS NULL;
CREATE INDEX imported_stock_note_branch_idx ON imported_stock_note (branch_id, emitted_at DESC);
CREATE INDEX imported_stock_note_counterpart_idx ON imported_stock_note (counterpart_branch_id) WHERE counterpart_branch_id IS NOT NULL;
CREATE INDEX imported_stock_note_import_idx ON imported_stock_note (import_id);
CREATE INDEX imported_stock_note_supplier_idx ON imported_stock_note (supplier_id) WHERE supplier_id IS NOT NULL;
CREATE INDEX imported_stock_note_economic_group_id_idx ON imported_stock_note (economic_group_id);
CALL app.apply_table_standard('public.imported_stock_note');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON imported_stock_note
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'branch_id', 'counterpart_branch_id', 'import_id', 'access_key', 'model', 'series', 'number',
    'emitted_at', 'protocol', 'kind', 'own_issued', 'cfop', 'supplier_id', 'party_document', 'party_name', 'total', 'xml'
  );
CREATE POLICY imported_stock_note_select ON imported_stock_note FOR SELECT TO farmaerp_app
  USING (branch_id = ANY (app.allowed_branch_ids()) OR counterpart_branch_id = ANY (app.allowed_branch_ids()));
CREATE VIEW v_imported_stock_note WITH (security_invoker = true) AS
  SELECT id, economic_group_id, branch_id, counterpart_branch_id, import_id, access_key, model, series, number, emitted_at,
         protocol, kind, own_issued, cfop, supplier_id, party_document, party_name, total, canceled_at, created_at, updated_at,
         deleted_at, version, updated_by, trace_id
    FROM imported_stock_note WHERE deleted_at IS NULL;
GRANT SELECT ON imported_stock_note, v_imported_stock_note TO farmaerp_app;

CREATE TABLE imported_stock_note_item (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  note_id uuid NOT NULL REFERENCES imported_stock_note (id),
  line integer NOT NULL CONSTRAINT imported_stock_note_item_line_check CHECK (line BETWEEN 1 AND 990),
  product_id uuid NOT NULL REFERENCES product (id),
  -- Código do fornecedor (cProd), quando a nota é de fora.
  supplier_code text CONSTRAINT imported_stock_note_item_supplier_code_check CHECK (length(supplier_code) BETWEEN 1 AND 60),
  -- Quantidade da nota e a que entrou ou saiu do estoque (com o fracionamento).
  note_quantity numeric(15, 4) NOT NULL CONSTRAINT imported_stock_note_item_note_quantity_check CHECK (note_quantity > 0),
  quantity numeric(14, 3) NOT NULL CONSTRAINT imported_stock_note_item_quantity_check CHECK (quantity > 0),
  unit text CONSTRAINT imported_stock_note_item_unit_check CHECK (length(unit) <= 6),
  total numeric(14, 2) NOT NULL CONSTRAINT imported_stock_note_item_total_check CHECK (total >= 0),
  -- Custo por unidade de estoque (só na compra).
  unit_cost numeric(19, 6) CONSTRAINT imported_stock_note_item_unit_cost_check CHECK (unit_cost >= 0),
  cfop text CONSTRAINT imported_stock_note_item_cfop_check CHECK (cfop ~ '^[1-7][0-9]{3}$'),
  -- Lotes da nota (rastro): número, quantidade, fabricação e validade. Só registro.
  batches jsonb NOT NULL DEFAULT '[]'::jsonb CONSTRAINT imported_stock_note_item_batches_check CHECK (pg_catalog.jsonb_typeof(batches) = 'array'),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE UNIQUE INDEX imported_stock_note_item_line_key ON imported_stock_note_item (note_id, line) WHERE deleted_at IS NULL;
CREATE INDEX imported_stock_note_item_product_idx ON imported_stock_note_item (product_id);
CREATE INDEX imported_stock_note_item_economic_group_id_idx ON imported_stock_note_item (economic_group_id);
CALL app.apply_table_standard('public.imported_stock_note_item');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON imported_stock_note_item
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'note_id', 'line', 'product_id', 'supplier_code', 'note_quantity', 'quantity', 'unit', 'total',
    'unit_cost', 'cfop', 'batches'
  );
CREATE POLICY imported_stock_note_item_select ON imported_stock_note_item FOR SELECT TO farmaerp_app
  USING (EXISTS (SELECT 1 FROM imported_stock_note n WHERE n.id = imported_stock_note_item.note_id));
CREATE VIEW v_imported_stock_note_item WITH (security_invoker = true) AS
  SELECT * FROM imported_stock_note_item WHERE deleted_at IS NULL;
GRANT SELECT ON imported_stock_note_item, v_imported_stock_note_item TO farmaerp_app;

-- Movimento de estoque da nota importada.
ALTER TABLE stock_movement ADD COLUMN imported_stock_item_id uuid REFERENCES imported_stock_note_item (id);
ALTER TABLE stock_movement ADD CONSTRAINT stock_movement_imported_stock_item_check
  CHECK (imported_stock_item_id IS NULL OR movement_type = 'import');
CREATE INDEX stock_movement_imported_stock_item_idx ON stock_movement (imported_stock_item_id) WHERE imported_stock_item_id IS NOT NULL;

-- Custo vindo da compra importada: a origem é o item da nota de compra ou o da nota importada.
ALTER TABLE product_cost ALTER COLUMN purchase_invoice_item_id DROP NOT NULL;
ALTER TABLE product_cost ADD COLUMN imported_stock_item_id uuid REFERENCES imported_stock_note_item (id);
ALTER TABLE product_cost ADD CONSTRAINT product_cost_source_check
  CHECK (pg_catalog.num_nonnulls(purchase_invoice_item_id, imported_stock_item_id) = 1);
CREATE INDEX product_cost_imported_stock_item_idx ON product_cost (imported_stock_item_id) WHERE imported_stock_item_id IS NOT NULL;

CREATE OR REPLACE FUNCTION app.validate_stock_movement() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  original public.stock_movement;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.product p
     WHERE p.id = NEW.product_id AND p.economic_group_id = NEW.economic_group_id AND p.deleted_at IS NULL
  ) OR NOT EXISTS (
    SELECT 1 FROM public.branch b
      JOIN public.company c ON c.id = b.company_id
     WHERE b.id = NEW.branch_id AND b.deleted_at IS NULL AND c.economic_group_id = NEW.economic_group_id
  ) THEN
    RAISE EXCEPTION 'Um dos itens informados não foi encontrado.'
      USING ERRCODE = 'FA004', DETAIL = pg_catalog.format('Produto %s, filial %s.', NEW.product_id, NEW.branch_id);
  END IF;

  IF NEW.batch_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.product_batch b
     WHERE b.id = NEW.batch_id AND b.branch_id = NEW.branch_id
       AND b.product_id = NEW.product_id AND b.deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Lote não encontrado neste produto e filial.'
      USING ERRCODE = 'FA808', DETAIL = pg_catalog.format('product_batch %s.', NEW.batch_id);
  END IF;

  -- Devolução de venda: volta para os lotes que saíram (ou sem lote, se a venda saiu sem).
  IF NEW.movement_type = 'return' AND NEW.sale_return_item_id IS NOT NULL THEN
    RETURN NEW;
  END IF;

  -- Nota importada do sistema anterior (venda, compra, transferência...): já aconteceu, sem lote.
  IF NEW.movement_type = 'import' AND (NEW.imported_sale_item_id IS NOT NULL OR NEW.imported_stock_item_id IS NOT NULL) THEN
    RETURN NEW;
  END IF;

  IF NEW.reversal_of IS NOT NULL THEN
    SELECT * INTO original FROM public.stock_movement m WHERE m.id = NEW.reversal_of;
    IF NOT FOUND
       OR original.reversal_of IS NOT NULL
       OR original.branch_id <> NEW.branch_id
       OR original.product_id <> NEW.product_id
       OR original.batch_id IS DISTINCT FROM NEW.batch_id
       OR original.quantity <> -NEW.quantity THEN
      RAISE EXCEPTION 'Esta movimentação não pode ser estornada.'
        USING ERRCODE = 'FA811', DETAIL = pg_catalog.format('Estorno de %s.', NEW.reversal_of);
    END IF;
    -- O estorno devolve exatamente o que a original fez, então não passa pelas regras de lote.
    RETURN NEW;
  END IF;

  IF app.batch_required(NEW.product_id, NEW.branch_id) THEN
    -- Só uma saída sem lote é aceita, para zerar o saldo antigo de um produto que passou a
    -- exigir lote. Sem isso, esse saldo não teria como ser regularizado.
    -- A venda também sai sem lote quando o produto ainda não tem nenhum lote na filial: a venda já
    -- aconteceu, e a regularização fica para a retaguarda.
    IF NEW.batch_id IS NULL AND NOT (
      NEW.movement_type = 'sale' AND NEW.quantity < 0 AND NOT EXISTS (
        SELECT 1 FROM public.product_batch pb
         WHERE pb.branch_id = NEW.branch_id AND pb.product_id = NEW.product_id AND pb.deleted_at IS NULL
      )
    ) AND NOT (
      NEW.quantity < 0 AND EXISTS (
        SELECT 1 FROM public.stock_balance sb
         WHERE sb.branch_id = NEW.branch_id AND sb.product_id = NEW.product_id
           AND sb.batch_id IS NULL AND sb.quantity > 0 AND sb.deleted_at IS NULL
      )
    ) THEN
      RAISE EXCEPTION 'Este produto exige lote nesta filial.'
        USING ERRCODE = 'FA802', DETAIL = pg_catalog.format('Produto %s, filial %s.', NEW.product_id, NEW.branch_id);
    END IF;
  ELSIF NEW.batch_id IS NOT NULL THEN
    RAISE EXCEPTION 'Este produto não controla lote nesta filial.'
      USING ERRCODE = 'FA803', DETAIL = pg_catalog.format('Produto %s, filial %s.', NEW.product_id, NEW.branch_id);
  END IF;
  RETURN NEW;
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


-- Filial do cliente pela parte da nota (emitente ou destinatário): a filial do grupo com o CNPJ,
-- ou uma nova se a raiz é de uma empresa do grupo. Sem isso, a parte é de fora (NULL).
CREATE FUNCTION app.import_own_branch(p_group_id uuid, p_party jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  party_cnpj text := app.clean_document(p_party ->> 'cnpj');
  found_id uuid;
BEGIN
  IF party_cnpj IS NULL OR pg_catalog.length(party_cnpj) <> 14 OR NOT app.is_valid_cnpj(party_cnpj) THEN
    RETURN NULL;
  END IF;
  SELECT b.id INTO found_id FROM public.branch b
    JOIN public.company c ON c.id = b.company_id
   WHERE b.cnpj = party_cnpj AND b.deleted_at IS NULL AND c.economic_group_id = p_group_id;
  IF found_id IS NOT NULL THEN
    RETURN found_id;
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.company c
     WHERE c.economic_group_id = p_group_id AND c.cnpj_root = pg_catalog.left(party_cnpj, 8) AND c.deleted_at IS NULL
  ) AND NOT EXISTS (SELECT 1 FROM public.branch b WHERE b.cnpj = party_cnpj AND b.deleted_at IS NULL) THEN
    RETURN app.import_branch(p_group_id, p_party);
  END IF;
  RETURN NULL;
END;
$$;

-- Natureza da operação pelo CFOP: sale, return, transfer ou other.
CREATE FUNCTION app.import_cfop_kind(p_cfop text) RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$
  SELECT CASE
    WHEN p_cfop IS NULL OR p_cfop !~ '^[1-7][0-9]{3}$' THEN 'other'
    WHEN pg_catalog.substr(p_cfop, 2, 3)::integer BETWEEN 151 AND 159 OR pg_catalog.substr(p_cfop, 2, 3) IN ('408', '409') THEN 'transfer'
    WHEN pg_catalog.substr(p_cfop, 2, 3)::integer BETWEEN 201 AND 211
      OR pg_catalog.substr(p_cfop, 2, 3) IN ('410', '411', '412', '413', '503', '553', '555', '556', '660', '661', '662', '918', '919') THEN 'return'
    WHEN pg_catalog.substr(p_cfop, 2, 3)::integer BETWEEN 101 AND 125 OR pg_catalog.substr(p_cfop, 2, 3)::integer BETWEEN 401 AND 405
      OR pg_catalog.substr(p_cfop, 2, 3) IN ('651', '652', '653', '654', '655', '656', '667') THEN 'sale'
    ELSE 'other'
  END
$$;

-- Produto do item de uma nota de fora: pelo vínculo código do fornecedor, pelo GTIN (do item ou
-- da unidade tributável), senão um novo. O vínculo fica gravado. Devolve o produto e o
-- fracionamento (quantas unidades de estoque há em uma da nota).
CREATE FUNCTION app.import_purchase_product(
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
  v_catalog_id uuid;
  v_barcode text;
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
  IF out_product_id IS NULL THEN
    IF v_gtin IS NOT NULL THEN
      SELECT cb.catalog_product_id INTO v_catalog_id FROM public.catalog_product_barcode cb
       WHERE cb.code = v_gtin AND cb.deleted_at IS NULL LIMIT 1;
      IF EXISTS (SELECT 1 FROM public.product p WHERE p.economic_group_id = p_group_id AND p.catalog_product_id = v_catalog_id AND p.deleted_at IS NULL) THEN
        v_catalog_id := NULL;
      END IF;
    END IF;
    INSERT INTO public.product (economic_group_id, catalog_product_id, display_name, own_ncm, own_cest)
    VALUES (
      p_group_id, v_catalog_id, COALESCE(app.import_text(p_item ->> 'name', 120), 'Produto ' || COALESCE(v_code, 'sem código')),
      CASE WHEN p_item ->> 'ncm' ~ '^[0-9]{8}$' THEN p_item ->> 'ncm' END,
      CASE WHEN p_item ->> 'cest' ~ '^[0-9]{7}$' THEN p_item ->> 'cest' END
    ) RETURNING id INTO out_product_id;
    v_barcode := CASE WHEN v_gtin IS NOT NULL THEN v_gtin
                      ELSE 'IM' || pg_catalog.left(pg_catalog.replace(out_product_id::text, '-', ''), 26) END;
    v_barcode_id := app.insert_product_barcode(p_group_id, out_product_id, v_barcode, v_gtin IS NULL, true, true, true, NULL, NULL);
  END IF;
  IF p_supplier_id IS NOT NULL AND v_code IS NOT NULL AND v_link_id IS NULL THEN
    INSERT INTO public.product_supplier (economic_group_id, product_id, supplier_id, supplier_code)
    VALUES (p_group_id, out_product_id, p_supplier_id, v_code)
    ON CONFLICT DO NOTHING;
  END IF;
  out_fraction := COALESCE(app.effective_fraction(out_product_id, v_barcode_id, v_link_id), 1);
END;
$$;

-- Fornecedor pela parte da nota (formato do arquivo importado).
CREATE FUNCTION app.import_supplier(p_group_id uuid, p_party jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT COALESCE(app.is_valid_cnpj(app.clean_document(p_party ->> 'cnpj')), false) THEN
    RETURN NULL;
  END IF;
  RETURN app.supplier_for_invoice(p_group_id, pg_catalog.jsonb_build_object(
    'cnpj', p_party ->> 'cnpj', 'legalName', COALESCE(p_party ->> 'name', 'Fornecedor ' || (p_party ->> 'cnpj')),
    'tradeName', p_party ->> 'trade_name', 'stateRegistration', p_party ->> 'state_registration', 'phone', p_party ->> 'phone',
    'postalCode', p_party ->> 'postal_code', 'street', p_party ->> 'street', 'streetNumber', p_party ->> 'number',
    'complement', p_party ->> 'complement', 'district', p_party ->> 'district', 'city', p_party ->> 'city',
    'cityCode', p_party ->> 'city_code', 'state', p_party ->> 'uf'
  ));
END;
$$;

-- Custo da compra importada: vale a mais recente. Compra lançada no próprio sistema manda.
CREATE FUNCTION app.import_product_cost(
  p_group_id uuid, p_branch_id uuid, p_product_id uuid, p_item_id uuid, p_unit_cost numeric, p_quantity numeric, p_emitted_at timestamptz
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF p_unit_cost IS NULL OR p_quantity <= 0 THEN
    RETURN;
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.product_cost c
     WHERE c.product_id = p_product_id AND c.branch_id = p_branch_id AND c.deleted_at IS NULL AND c.purchase_invoice_item_id IS NOT NULL
  ) OR EXISTS (
    SELECT 1 FROM public.product_cost c
      JOIN public.imported_stock_note_item i ON i.id = c.imported_stock_item_id
      JOIN public.imported_stock_note n ON n.id = i.note_id
     WHERE c.product_id = p_product_id AND c.branch_id = p_branch_id AND c.deleted_at IS NULL AND n.emitted_at > p_emitted_at
       AND c.reversal_of IS NULL
       AND NOT EXISTS (SELECT 1 FROM public.product_cost r WHERE r.reversal_of = c.id AND r.deleted_at IS NULL)
  ) THEN
    RETURN;
  END IF;
  INSERT INTO public.product_cost (
    economic_group_id, branch_id, product_id, average_cost, previous_cost, stock_before, entry_quantity, entry_cost, imported_stock_item_id
  ) VALUES (
    p_group_id, p_branch_id, p_product_id, p_unit_cost, app.average_cost(p_product_id, p_branch_id),
    app.branch_stock_quantity(p_product_id, p_branch_id), p_quantity, p_unit_cost, p_item_id
  );
END;
$$;

-- Uma NF-e (modelo 55) do arquivo. Resultado como o da NFC-e: imported, duplicate, ignored ou failed.
CREATE FUNCTION app.import_nfe(p_import_id uuid, p_entry text, p_note jsonb) RETURNS jsonb
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
BEGIN
  PERFORM app.require_import_worker();
  SELECT * INTO job FROM public.document_import d WHERE d.id = p_import_id AND d.status = 'processing';
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
       OR EXISTS (SELECT 1 FROM public.imported_stock_note n WHERE n.access_key = v_key AND n.deleted_at IS NULL) THEN
      outcome := 'duplicate';
    ELSE
      v_emitted := (p_note ->> 'emitted_at')::timestamptz;
      v_issuer_branch := app.import_own_branch(job.economic_group_id, p_note -> 'issuer');
      v_dest_branch := app.import_own_branch(job.economic_group_id, COALESCE(p_note -> 'dest', '{}'::jsonb));
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

      IF v_note_kind IS NULL THEN
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
          v_product := app.import_product(job.economic_group_id, v_item, v_emitted);
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
            v_product := app.import_product(job.economic_group_id, v_item, v_emitted);
            v_fraction := 1;
          ELSE
            SELECT r.out_product_id, r.out_fraction INTO v_product, v_fraction
              FROM app.import_purchase_product(job.economic_group_id, v_supplier, v_item) r;
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
      END IF;
    END IF;
  EXCEPTION
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
  INSERT INTO public.document_import_note (economic_group_id, import_id, entry_name, access_key, model, result, error_code, reason)
  VALUES (
    job.economic_group_id, job.id, pg_catalog.left(COALESCE(p_entry, '?'), 300),
    CASE WHEN v_key ~ '^[0-9]{44}$' THEN v_key END, '55', outcome, code, message
  );
  RETURN pg_catalog.jsonb_build_object('result', outcome, 'code', code, 'reason', message, 'kind', v_note_kind);
END;
$$;

-- Cancelamento (evento 110111) de NFC-e ou NF-e importada: desfaz a venda ou a nota de estoque,
-- devolve o estoque e tira o custo que a compra cancelada tinha posto.
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
  INSERT INTO public.document_import_note (economic_group_id, import_id, entry_name, access_key, model, result, reason)
  VALUES (job.economic_group_id, job.id, pg_catalog.left(COALESCE(p_entry, '?'), 300), CASE WHEN p_key ~ '^[0-9]{44}$' THEN p_key END,
          CASE WHEN pg_catalog.substr(p_key, 21, 2) ~ '^[0-9]{2}$' THEN pg_catalog.substr(p_key, 21, 2) END, 'canceled',
          CASE WHEN sale.id IS NULL AND stock_note.id IS NULL THEN 'Cancelamento de nota que não está na importação.' END);
  RETURN pg_catalog.jsonb_build_object('result', 'canceled', 'found', sale.id IS NOT NULL OR stock_note.id IS NOT NULL);
END;
$$;

REVOKE ALL ON FUNCTION
  app.import_own_branch(uuid, jsonb),
  app.import_cfop_kind(text),
  app.import_purchase_product(uuid, uuid, jsonb),
  app.import_supplier(uuid, jsonb),
  app.import_product_cost(uuid, uuid, uuid, uuid, numeric, numeric, timestamptz),
  app.import_nfe(uuid, text, jsonb)
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.import_nfe(uuid, text, jsonb) TO farmaerp_app;
