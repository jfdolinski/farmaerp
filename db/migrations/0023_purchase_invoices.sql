-- Up Migration

-- Importação e conferência da NF-e de compra. A API confere o XML (assinatura, protocolo e chave) e
-- manda os dados já lidos; aqui ficam as regras de quem pode importar, para qual filial, quando a
-- nota pode ir para o estoque e como cada item se liga a um produto. O lançamento no estoque vem
-- no próximo passo: nada aqui mexe em saldo.

-- Chave de acesso: 44 posições, com o CNPJ do emitente podendo ser alfanumérico. O dígito usa o
-- módulo 11 com pesos de 2 a 9 da direita para a esquerda, e as letras valem o código ASCII menos 48.
CREATE FUNCTION app.is_valid_access_key(p_key text) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE
SET search_path = ''
AS $$
DECLARE
  total int := 0;
  weight int := 2;
  remainder int;
  digit int;
BEGIN
  IF p_key IS NULL OR p_key !~ '^[0-9]{6}[0-9A-Z]{12}[0-9]{26}$' THEN
    RETURN false;
  END IF;
  FOR pos IN REVERSE 43..1 LOOP
    total := total + (pg_catalog.ascii(pg_catalog.substr(p_key, pos, 1)) - 48) * weight;
    weight := CASE WHEN weight = 9 THEN 2 ELSE weight + 1 END;
  END LOOP;
  remainder := total % 11;
  digit := CASE WHEN remainder < 2 THEN 0 ELSE 11 - remainder END;
  RETURN pg_catalog.substr(p_key, 44, 1)::int = digit;
END;
$$;

CREATE TABLE purchase_invoice (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  branch_id uuid NOT NULL REFERENCES branch (id),
  supplier_id uuid NOT NULL REFERENCES supplier (id),
  access_key text NOT NULL CONSTRAINT purchase_invoice_access_key_check CHECK (app.is_valid_access_key(access_key)),
  series integer NOT NULL CONSTRAINT purchase_invoice_series_check CHECK (series BETWEEN 0 AND 999),
  number bigint NOT NULL CONSTRAINT purchase_invoice_number_check CHECK (number BETWEEN 1 AND 999999999),
  issued_at timestamptz NOT NULL,
  -- tpNF: 0 entrada, 1 saída. finNFe: 1 normal, 2 complementar, 3 ajuste, 4 devolução. tpAmb: 1 produção, 2 teste.
  operation_type smallint NOT NULL CONSTRAINT purchase_invoice_operation_type_check CHECK (operation_type IN (0, 1)),
  purpose smallint NOT NULL CONSTRAINT purchase_invoice_purpose_check CHECK (purpose BETWEEN 1 AND 4),
  environment smallint NOT NULL CONSTRAINT purchase_invoice_environment_check CHECK (environment IN (1, 2)),
  protocol_number text NOT NULL CONSTRAINT purchase_invoice_protocol_number_check CHECK (protocol_number ~ '^[0-9]{15}$'),
  authorized_at timestamptz NOT NULL,
  emitter_cnpj text NOT NULL CONSTRAINT purchase_invoice_emitter_cnpj_check CHECK (app.is_valid_cnpj(emitter_cnpj)),
  emitter_name text NOT NULL CONSTRAINT purchase_invoice_emitter_name_check CHECK (btrim(emitter_name) <> '' AND length(emitter_name) <= 150),
  products_total numeric(15, 2) NOT NULL CONSTRAINT purchase_invoice_products_total_check CHECK (products_total >= 0),
  discount_total numeric(15, 2) NOT NULL DEFAULT 0 CONSTRAINT purchase_invoice_discount_total_check CHECK (discount_total >= 0),
  freight_total numeric(15, 2) NOT NULL DEFAULT 0 CONSTRAINT purchase_invoice_freight_total_check CHECK (freight_total >= 0),
  insurance_total numeric(15, 2) NOT NULL DEFAULT 0 CONSTRAINT purchase_invoice_insurance_total_check CHECK (insurance_total >= 0),
  other_total numeric(15, 2) NOT NULL DEFAULT 0 CONSTRAINT purchase_invoice_other_total_check CHECK (other_total >= 0),
  ipi_total numeric(15, 2) NOT NULL DEFAULT 0 CONSTRAINT purchase_invoice_ipi_total_check CHECK (ipi_total >= 0),
  st_total numeric(15, 2) NOT NULL DEFAULT 0 CONSTRAINT purchase_invoice_st_total_check CHECK (st_total >= 0),
  invoice_total numeric(15, 2) NOT NULL CONSTRAINT purchase_invoice_invoice_total_check CHECK (invoice_total >= 0),
  -- Em conferência ou fora do estoque. O lançamento acrescenta as próximas situações.
  status text NOT NULL CONSTRAINT purchase_invoice_status_check CHECK (status IN ('review', 'not_postable')),
  -- Por que a nota não vai para o estoque: finalidade, nota de entrada ou emitida por filial da rede.
  not_postable_reason text CONSTRAINT purchase_invoice_not_postable_reason_check CHECK (
    not_postable_reason IN ('purpose', 'entry', 'own_branch')
  ),
  discard_reason text CONSTRAINT purchase_invoice_discard_reason_check CHECK (btrim(discard_reason) <> '' AND length(discard_reason) <= 500),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid,
  CONSTRAINT purchase_invoice_status_reason_check CHECK ((status = 'not_postable') = (not_postable_reason IS NOT NULL)),
  -- Descartar é a exclusão lógica: o motivo vem junto.
  CONSTRAINT purchase_invoice_discard_check CHECK ((deleted_at IS NULL) = (discard_reason IS NULL))
);
-- Descartada libera a chave para importar de novo.
CREATE UNIQUE INDEX purchase_invoice_access_key_active_key
  ON purchase_invoice (economic_group_id, access_key) WHERE deleted_at IS NULL;
CREATE INDEX purchase_invoice_branch_recent_idx ON purchase_invoice (branch_id, issued_at DESC, id DESC);
CREATE INDEX purchase_invoice_supplier_id_idx ON purchase_invoice (supplier_id);
CALL app.apply_table_standard('public.purchase_invoice');
-- O que veio do XML não muda: só a situação e o descarte.
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON purchase_invoice
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'branch_id', 'supplier_id', 'access_key', 'series', 'number', 'issued_at', 'operation_type',
    'purpose', 'environment', 'protocol_number', 'authorized_at', 'emitter_cnpj', 'emitter_name', 'products_total',
    'discount_total', 'freight_total', 'insurance_total', 'other_total', 'ipi_total', 'st_total', 'invoice_total'
  );

-- O XML original, à parte para não pesar nas listas. Fica guardado mesmo com a nota descartada.
CREATE TABLE purchase_invoice_document (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  branch_id uuid NOT NULL REFERENCES branch (id),
  invoice_id uuid NOT NULL REFERENCES purchase_invoice (id),
  xml text NOT NULL CONSTRAINT purchase_invoice_document_xml_check CHECK (length(xml) BETWEEN 1 AND 5242880),
  sha256 text NOT NULL CONSTRAINT purchase_invoice_document_sha256_check CHECK (sha256 ~ '^[0-9a-f]{64}$'),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE UNIQUE INDEX purchase_invoice_document_invoice_key ON purchase_invoice_document (invoice_id);
CALL app.apply_table_standard('public.purchase_invoice_document');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON purchase_invoice_document
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns('economic_group_id', 'branch_id', 'invoice_id', 'xml', 'sha256');

CREATE TABLE purchase_invoice_item (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  branch_id uuid NOT NULL REFERENCES branch (id),
  invoice_id uuid NOT NULL REFERENCES purchase_invoice (id),
  item_number smallint NOT NULL CONSTRAINT purchase_invoice_item_number_check CHECK (item_number BETWEEN 1 AND 990),
  supplier_code text NOT NULL CONSTRAINT purchase_invoice_item_supplier_code_check CHECK (
    btrim(supplier_code) <> '' AND supplier_code = btrim(supplier_code) AND length(supplier_code) <= 60
  ),
  -- cEAN e cEANTrib. "SEM GTIN" chega aqui vazio.
  barcode text CONSTRAINT purchase_invoice_item_barcode_check CHECK (barcode ~ '^[0-9A-Za-z]{1,30}$'),
  tax_barcode text CONSTRAINT purchase_invoice_item_tax_barcode_check CHECK (tax_barcode ~ '^[0-9A-Za-z]{1,30}$'),
  description text NOT NULL CONSTRAINT purchase_invoice_item_description_check CHECK (btrim(description) <> '' AND length(description) <= 120),
  ncm text CONSTRAINT purchase_invoice_item_ncm_check CHECK (ncm ~ '^[0-9]{2}([0-9]{6})?$'),
  cest text CONSTRAINT purchase_invoice_item_cest_check CHECK (cest ~ '^[0-9]{7}$'),
  cfop text NOT NULL CONSTRAINT purchase_invoice_item_cfop_check CHECK (cfop ~ '^[1-7][0-9]{3}$'),
  unit text NOT NULL CONSTRAINT purchase_invoice_item_unit_check CHECK (btrim(unit) <> '' AND length(unit) <= 6),
  quantity numeric(15, 4) NOT NULL CONSTRAINT purchase_invoice_item_quantity_check CHECK (quantity > 0),
  unit_price numeric(21, 10) NOT NULL CONSTRAINT purchase_invoice_item_unit_price_check CHECK (unit_price >= 0),
  products_value numeric(15, 2) NOT NULL CONSTRAINT purchase_invoice_item_products_value_check CHECK (products_value >= 0),
  discount_value numeric(15, 2) NOT NULL DEFAULT 0 CONSTRAINT purchase_invoice_item_discount_value_check CHECK (discount_value >= 0),
  freight_value numeric(15, 2) NOT NULL DEFAULT 0 CONSTRAINT purchase_invoice_item_freight_value_check CHECK (freight_value >= 0),
  insurance_value numeric(15, 2) NOT NULL DEFAULT 0 CONSTRAINT purchase_invoice_item_insurance_value_check CHECK (insurance_value >= 0),
  other_value numeric(15, 2) NOT NULL DEFAULT 0 CONSTRAINT purchase_invoice_item_other_value_check CHECK (other_value >= 0),
  ipi_value numeric(15, 2) NOT NULL DEFAULT 0 CONSTRAINT purchase_invoice_item_ipi_value_check CHECK (ipi_value >= 0),
  st_value numeric(15, 2) NOT NULL DEFAULT 0 CONSTRAINT purchase_invoice_item_st_value_check CHECK (st_value >= 0),
  fcp_st_value numeric(15, 2) NOT NULL DEFAULT 0 CONSTRAINT purchase_invoice_item_fcp_st_value_check CHECK (fcp_st_value >= 0),
  -- Grupo med: registro na Anvisa (ou ISENTO) e PMC.
  anvisa_code text CONSTRAINT purchase_invoice_item_anvisa_code_check CHECK (anvisa_code ~ '^([0-9]{13}|ISENTO)$'),
  pmc numeric(15, 2) CONSTRAINT purchase_invoice_item_pmc_check CHECK (pmc >= 0),
  -- Ligação com o produto da loja: vazia enquanto ninguém conferiu.
  product_id uuid REFERENCES product (id),
  product_supplier_id uuid REFERENCES product_supplier (id),
  barcode_id uuid REFERENCES product_barcode (id),
  match_source text CONSTRAINT purchase_invoice_item_match_source_check CHECK (
    match_source IN ('supplier_code', 'barcode', 'manual', 'duplicate', 'catalog')
  ),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid,
  CONSTRAINT purchase_invoice_item_match_check CHECK (
    (product_id IS NULL) = (match_source IS NULL) AND (product_id IS NOT NULL OR (product_supplier_id IS NULL AND barcode_id IS NULL))
  )
);
CREATE UNIQUE INDEX purchase_invoice_item_number_key ON purchase_invoice_item (invoice_id, item_number);
CREATE INDEX purchase_invoice_item_product_id_idx ON purchase_invoice_item (product_id);
-- Itens sem produto, para ligar de uma vez os iguais de outras notas.
CREATE INDEX purchase_invoice_item_pending_idx ON purchase_invoice_item (economic_group_id, supplier_code) WHERE product_id IS NULL;
CALL app.apply_table_standard('public.purchase_invoice_item');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON purchase_invoice_item
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'branch_id', 'invoice_id', 'item_number', 'supplier_code', 'barcode', 'tax_barcode', 'description',
    'ncm', 'cest', 'cfop', 'unit', 'quantity', 'unit_price', 'products_value', 'discount_value', 'freight_value',
    'insurance_value', 'other_value', 'ipi_value', 'st_value', 'fcp_st_value', 'anvisa_code', 'pmc'
  );

-- Lotes do grupo rastro. Ficam como vieram; o lançamento cria ou confere o lote no estoque.
CREATE TABLE purchase_invoice_item_batch (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  branch_id uuid NOT NULL REFERENCES branch (id),
  item_id uuid NOT NULL REFERENCES purchase_invoice_item (id),
  batch_number text NOT NULL CONSTRAINT purchase_invoice_item_batch_number_check CHECK (btrim(batch_number) <> '' AND length(batch_number) <= 20),
  quantity numeric(14, 3) NOT NULL CONSTRAINT purchase_invoice_item_batch_quantity_check CHECK (quantity > 0),
  manufactured_on date,
  expires_on date NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid,
  CONSTRAINT purchase_invoice_item_batch_dates_check CHECK (manufactured_on IS NULL OR manufactured_on <= expires_on)
);
CREATE INDEX purchase_invoice_item_batch_item_idx ON purchase_invoice_item_batch (item_id);
CALL app.apply_table_standard('public.purchase_invoice_item_batch');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON purchase_invoice_item_batch
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'branch_id', 'item_id', 'batch_number', 'quantity', 'manufactured_on', 'expires_on'
  );

UPDATE permission SET name = 'Ver fornecedores e notas de compra' WHERE code = 'purchases.view';
UPDATE permission SET name = 'Cadastrar fornecedores, importar notas de compra e ligar os itens aos produtos' WHERE code = 'purchases.manage';

-- A nota é da filial: importar e conferir exige purchases.manage nela.
CREATE FUNCTION app.require_invoice_branch(p_branch_id uuid) RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT app.has_permission('purchases.manage', p_branch_id) THEN
    RAISE EXCEPTION 'Você não tem permissão para esta operação.'
      USING ERRCODE = 'FA002', DETAIL = pg_catalog.format('purchases.manage na filial %s.', p_branch_id);
  END IF;
END;
$$;

-- Nota da filial que o usuário confere. Descartada ou fora do estoque não se confere mais.
CREATE FUNCTION app.invoice_for_review(p_invoice_id uuid) RETURNS public.purchase_invoice
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.purchase_invoice;
BEGIN
  SELECT * INTO target FROM public.purchase_invoice i
   WHERE i.id = p_invoice_id AND i.economic_group_id = app.current_user_group() AND i.deleted_at IS NULL
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('purchase_invoice %s.', p_invoice_id);
  END IF;
  PERFORM app.require_invoice_branch(target.branch_id);
  IF target.status <> 'review' THEN
    RAISE EXCEPTION 'Esta nota não pode mais ser conferida.'
      USING ERRCODE = 'FA932', DETAIL = pg_catalog.format('purchase_invoice %s em %s.', target.id, target.status);
  END IF;
  RETURN target;
END;
$$;

-- Liga o item sozinho, na ordem do documento base: código do fornecedor e, sem ele, código de
-- barras, criando a relação com o fornecedor. Sem nenhum dos dois, o item espera a conferência.
CREATE FUNCTION app.match_purchase_item(p_item_id uuid) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  item public.purchase_invoice_item;
  invoice public.purchase_invoice;
  relation public.product_supplier;
  found_barcode public.product_barcode;
  relation_id uuid;
BEGIN
  SELECT * INTO item FROM public.purchase_invoice_item it WHERE it.id = p_item_id AND it.product_id IS NULL;
  IF NOT FOUND THEN
    RETURN false;
  END IF;
  SELECT * INTO invoice FROM public.purchase_invoice i WHERE i.id = item.invoice_id;

  SELECT ps.* INTO relation FROM public.product_supplier ps
    JOIN public.product p ON p.id = ps.product_id AND p.deleted_at IS NULL
   WHERE ps.supplier_id = invoice.supplier_id AND ps.supplier_code = item.supplier_code AND ps.deleted_at IS NULL;
  IF FOUND THEN
    UPDATE public.purchase_invoice_item
       SET product_id = relation.product_id, product_supplier_id = relation.id, match_source = 'supplier_code'
     WHERE id = item.id;
    RETURN true;
  END IF;

  -- Só o cEAN: o fracionamento do código de barras é da unidade comercial da nota.
  IF item.barcode IS NULL OR NOT app.is_valid_gtin(item.barcode) THEN
    RETURN false;
  END IF;
  SELECT b.* INTO found_barcode FROM public.product_barcode b
    JOIN public.product p ON p.id = b.product_id AND p.deleted_at IS NULL
   WHERE b.economic_group_id = item.economic_group_id AND b.code = item.barcode AND b.deleted_at IS NULL;
  IF NOT FOUND THEN
    RETURN false;
  END IF;
  -- Um código ativo do fornecedor apontando para produto encerrado bloqueia a relação nova: espera a conferência.
  IF EXISTS (
    SELECT 1 FROM public.product_supplier ps
     WHERE ps.supplier_id = invoice.supplier_id AND ps.supplier_code = item.supplier_code AND ps.deleted_at IS NULL
  ) THEN
    RETURN false;
  END IF;
  INSERT INTO public.product_supplier (economic_group_id, product_id, supplier_id, supplier_code)
  VALUES (item.economic_group_id, found_barcode.product_id, invoice.supplier_id, item.supplier_code)
  RETURNING id INTO relation_id;
  UPDATE public.purchase_invoice_item
     SET product_id = found_barcode.product_id, product_supplier_id = relation_id, barcode_id = found_barcode.id,
         match_source = 'barcode'
   WHERE id = item.id;
  RETURN true;
END;
$$;

-- Itens iguais (mesmo fornecedor e código) de outras notas em conferência passam a seguir a ligação.
CREATE FUNCTION app.match_pending_items(p_supplier_id uuid, p_supplier_code text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  pending uuid;
BEGIN
  FOR pending IN
    SELECT it.id FROM public.purchase_invoice_item it
      JOIN public.purchase_invoice i ON i.id = it.invoice_id AND i.deleted_at IS NULL AND i.status = 'review'
     WHERE i.supplier_id = p_supplier_id AND it.supplier_code = p_supplier_code AND it.product_id IS NULL
       AND it.deleted_at IS NULL
     ORDER BY it.id
  LOOP
    PERFORM app.match_purchase_item(pending);
  END LOOP;
END;
$$;

-- Fornecedor da nota: o cadastrado, ou um novo com os dados do emitente. Inscrição que não passa na
-- conferência do estado fica de fora, para não travar a importação.
CREATE FUNCTION app.supplier_for_invoice(p_group_id uuid, p_emitter jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  emitter_cnpj text := app.clean_document(p_emitter ->> 'cnpj');
  emitter_state text := pg_catalog.upper(app.clean_text(p_emitter ->> 'state'));
  registration text := app.clean_state_registration(p_emitter ->> 'stateRegistration');
  supplier_id uuid;
BEGIN
  SELECT s.id INTO supplier_id FROM public.supplier s
   WHERE s.economic_group_id = p_group_id AND s.cnpj = emitter_cnpj AND s.deleted_at IS NULL;
  IF FOUND THEN
    RETURN supplier_id;
  END IF;
  IF registration IS NOT NULL AND (emitter_state IS NULL OR NOT app.is_valid_state_registration(registration, emitter_state)) THEN
    registration := NULL;
  END IF;
  INSERT INTO public.supplier (
    economic_group_id, cnpj, legal_name, trade_name, state_registration, phone, postal_code, street, street_number,
    complement, district, city, city_code, state
  ) VALUES (
    p_group_id, COALESCE(emitter_cnpj, ''), COALESCE(pg_catalog.left(app.clean_text(p_emitter ->> 'legalName'), 150), ''),
    pg_catalog.left(app.clean_text(p_emitter ->> 'tradeName'), 150), registration,
    CASE WHEN app.clean_digits(p_emitter ->> 'phone') ~ '^[0-9]{10,11}$' THEN app.clean_digits(p_emitter ->> 'phone') END,
    CASE WHEN app.clean_digits(p_emitter ->> 'postalCode') ~ '^[0-9]{8}$' THEN app.clean_digits(p_emitter ->> 'postalCode') END,
    pg_catalog.left(app.clean_text(p_emitter ->> 'street'), 150), pg_catalog.left(app.clean_text(p_emitter ->> 'streetNumber'), 20),
    pg_catalog.left(app.clean_text(p_emitter ->> 'complement'), 100), pg_catalog.left(app.clean_text(p_emitter ->> 'district'), 100),
    pg_catalog.left(app.clean_text(p_emitter ->> 'city'), 100),
    CASE WHEN app.clean_digits(p_emitter ->> 'cityCode') ~ '^[0-9]{7}$' THEN app.clean_digits(p_emitter ->> 'cityCode') END,
    emitter_state
  ) RETURNING id INTO supplier_id;
  RETURN supplier_id;
END;
$$;

-- Recebe a nota já conferida pela API (assinatura, protocolo e chave). p_accepts_test diz se o
-- ambiente aceita nota de teste da Sefaz: só a produção recusa.
CREATE FUNCTION app.import_purchase_invoice(p_data jsonb, p_xml text, p_sha256 text, p_accepts_test boolean) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.current_user_group();
  target_branch public.branch;
  dest_cnpj text := app.clean_document(p_data ->> 'destCnpj');
  emitter_cnpj text := app.clean_document(p_data #>> '{emitter,cnpj}');
  supplier_id uuid;
  reason text;
  new_invoice_id uuid;
  item jsonb;
  item_id uuid;
  batch jsonb;
BEGIN
  SELECT b.* INTO target_branch FROM public.branch b
    JOIN public.company c ON c.id = b.company_id AND c.deleted_at IS NULL
   WHERE c.economic_group_id = group_id AND b.cnpj = dest_cnpj AND b.deleted_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Esta nota não é de uma filial da rede.'
      USING ERRCODE = 'FA927', DETAIL = 'Destinatário fora do grupo.';
  END IF;
  PERFORM app.require_invoice_branch(target_branch.id);
  IF (p_data ->> 'environment')::smallint = 2 AND NOT p_accepts_test THEN
    RAISE EXCEPTION 'Esta nota é do ambiente de teste da Sefaz.'
      USING ERRCODE = 'FA928', DETAIL = pg_catalog.format('Filial %s.', target_branch.id);
  END IF;

  reason := CASE
    WHEN EXISTS (
      SELECT 1 FROM public.branch b JOIN public.company c ON c.id = b.company_id
       WHERE c.economic_group_id = group_id AND b.cnpj = emitter_cnpj AND b.deleted_at IS NULL
    ) THEN 'own_branch'
    WHEN (p_data ->> 'operationType')::smallint = 0 THEN 'entry'
    WHEN (p_data ->> 'purpose')::smallint <> 1 THEN 'purpose'
  END;
  supplier_id := app.supplier_for_invoice(group_id, p_data -> 'emitter');

  INSERT INTO public.purchase_invoice (
    economic_group_id, branch_id, supplier_id, access_key, series, number, issued_at, operation_type, purpose,
    environment, protocol_number, authorized_at, emitter_cnpj, emitter_name, products_total, discount_total,
    freight_total, insurance_total, other_total, ipi_total, st_total, invoice_total, status, not_postable_reason
  ) VALUES (
    group_id, target_branch.id, supplier_id, COALESCE(p_data ->> 'accessKey', ''), (p_data ->> 'series')::integer,
    (p_data ->> 'number')::bigint, (p_data ->> 'issuedAt')::timestamptz, (p_data ->> 'operationType')::smallint,
    (p_data ->> 'purpose')::smallint, (p_data ->> 'environment')::smallint, COALESCE(p_data ->> 'protocolNumber', ''),
    (p_data ->> 'authorizedAt')::timestamptz, COALESCE(emitter_cnpj, ''),
    COALESCE(pg_catalog.left(app.clean_text(p_data #>> '{emitter,legalName}'), 150), ''),
    (p_data #>> '{totals,products}')::numeric, COALESCE((p_data #>> '{totals,discount}')::numeric, 0),
    COALESCE((p_data #>> '{totals,freight}')::numeric, 0), COALESCE((p_data #>> '{totals,insurance}')::numeric, 0),
    COALESCE((p_data #>> '{totals,other}')::numeric, 0), COALESCE((p_data #>> '{totals,ipi}')::numeric, 0),
    COALESCE((p_data #>> '{totals,st}')::numeric, 0), (p_data #>> '{totals,invoice}')::numeric,
    CASE WHEN reason IS NULL THEN 'review' ELSE 'not_postable' END, reason
  ) RETURNING id INTO new_invoice_id;

  INSERT INTO public.purchase_invoice_document (economic_group_id, branch_id, invoice_id, xml, sha256)
  VALUES (group_id, target_branch.id, new_invoice_id, p_xml, p_sha256);

  FOR item IN SELECT value FROM pg_catalog.jsonb_array_elements(COALESCE(p_data -> 'items', '[]')) AS value LOOP
    INSERT INTO public.purchase_invoice_item (
      economic_group_id, branch_id, invoice_id, item_number, supplier_code, barcode, tax_barcode, description, ncm, cest,
      cfop, unit, quantity, unit_price, products_value, discount_value, freight_value, insurance_value, other_value,
      ipi_value, st_value, fcp_st_value, anvisa_code, pmc
    ) VALUES (
      group_id, target_branch.id, new_invoice_id, (item ->> 'number')::smallint, COALESCE(app.clean_text(item ->> 'supplierCode'), ''),
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
        group_id, target_branch.id, item_id, pg_catalog.upper(COALESCE(app.clean_text(batch ->> 'number'), '')),
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

-- Liga o item a um produto escolhido na conferência. Serve também para trocar uma ligação errada:
-- o código do fornecedor passa a apontar o produto novo, e os iguais de outras notas seguem junto.
-- O código de barras da nota entra no produto se ainda não for de ninguém.
CREATE FUNCTION app.link_purchase_item(p_item_id uuid, p_product_id uuid, p_source text DEFAULT 'manual') RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  item public.purchase_invoice_item;
  invoice public.purchase_invoice;
  relation_id uuid;
  found_barcode_id uuid;
  barcode_owner uuid;
  barcode_added boolean := false;
BEGIN
  SELECT * INTO item FROM public.purchase_invoice_item it
   WHERE it.id = p_item_id AND it.economic_group_id = app.current_user_group() AND it.deleted_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('purchase_invoice_item %s.', p_item_id);
  END IF;
  invoice := app.invoice_for_review(item.invoice_id);
  IF NOT EXISTS (
    SELECT 1 FROM public.product p
     WHERE p.id = p_product_id AND p.economic_group_id = item.economic_group_id AND p.deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Um dos itens informados não foi encontrado.'
      USING ERRCODE = 'FA004', DETAIL = pg_catalog.format('product %s.', p_product_id);
  END IF;

  SELECT ps.id INTO relation_id FROM public.product_supplier ps
   WHERE ps.supplier_id = invoice.supplier_id AND ps.supplier_code = item.supplier_code AND ps.deleted_at IS NULL
     AND ps.product_id = p_product_id;
  IF NOT FOUND THEN
    UPDATE public.product_supplier ps SET deleted_at = pg_catalog.clock_timestamp()
     WHERE ps.supplier_id = invoice.supplier_id AND ps.supplier_code = item.supplier_code AND ps.deleted_at IS NULL;
    INSERT INTO public.product_supplier (economic_group_id, product_id, supplier_id, supplier_code)
    VALUES (item.economic_group_id, p_product_id, invoice.supplier_id, item.supplier_code)
    RETURNING id INTO relation_id;
  END IF;

  IF item.barcode IS NOT NULL AND app.is_valid_gtin(item.barcode) THEN
    SELECT b.id, b.product_id INTO found_barcode_id, barcode_owner FROM public.product_barcode b
     WHERE b.economic_group_id = item.economic_group_id AND b.code = item.barcode AND b.deleted_at IS NULL;
    IF NOT FOUND THEN
      INSERT INTO public.product_barcode (economic_group_id, product_id, code)
      VALUES (item.economic_group_id, p_product_id, item.barcode)
      RETURNING id INTO found_barcode_id;
      barcode_owner := p_product_id;
      barcode_added := true;
    END IF;
    IF barcode_owner <> p_product_id THEN
      found_barcode_id := NULL;
    END IF;
  END IF;

  UPDATE public.purchase_invoice_item
     SET product_id = p_product_id, product_supplier_id = relation_id, barcode_id = found_barcode_id, match_source = p_source
   WHERE id = item.id;
  -- Iguais já ligados por este código seguem o produto novo; os que esperavam passam a ter ligação.
  UPDATE public.purchase_invoice_item it
     SET product_id = p_product_id, product_supplier_id = relation_id, barcode_id = NULL, match_source = 'supplier_code'
    FROM public.purchase_invoice i
   WHERE i.id = it.invoice_id AND i.status = 'review' AND i.deleted_at IS NULL AND i.supplier_id = invoice.supplier_id
     AND it.supplier_code = item.supplier_code AND it.id <> item.id AND it.deleted_at IS NULL
     AND it.product_id IS DISTINCT FROM p_product_id;
  RETURN pg_catalog.jsonb_build_object(
    'barcodeAdded', barcode_added,
    'barcodeConflict', item.barcode IS NOT NULL AND app.is_valid_gtin(item.barcode) AND barcode_owner <> p_product_id
  );
END;
$$;

-- Cadastro novo a partir de um parecido: estrutura, grupos e PMC do original, nome e código do item.
CREATE FUNCTION app.duplicate_product_for_item(p_item_id uuid, p_source_product_id uuid, p_data jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  item public.purchase_invoice_item;
  source public.product;
  new_id uuid;
BEGIN
  SELECT * INTO item FROM public.purchase_invoice_item it
   WHERE it.id = p_item_id AND it.economic_group_id = app.current_user_group() AND it.deleted_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('purchase_invoice_item %s.', p_item_id);
  END IF;
  PERFORM app.invoice_for_review(item.invoice_id);
  SELECT * INTO source FROM public.product p
   WHERE p.id = p_source_product_id AND p.economic_group_id = item.economic_group_id AND p.deleted_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Um dos itens informados não foi encontrado.'
      USING ERRCODE = 'FA004', DETAIL = pg_catalog.format('product %s.', p_source_product_id);
  END IF;
  -- O vínculo com o Catálogo é único por produto: a cópia nasce sem ele.
  new_id := app.create_product(pg_catalog.jsonb_build_object(
    'displayName', COALESCE(app.clean_text(p_data ->> 'displayName'), item.description),
    'barcode', COALESCE(app.clean_text(p_data ->> 'barcode'), item.barcode),
    'barcodeIsInternal', COALESCE((p_data ->> 'barcodeIsInternal')::boolean, false),
    'categoryId', source.category_id,
    'commissionGroupId', source.commission_group_id,
    'pricingGroupId', source.pricing_group_id,
    'priceFamilyId', source.price_family_id,
    'usesPmc', source.uses_pmc,
    'onlineSaleBlocked', source.online_sale_blocked,
    'ownManufacturer', source.own_manufacturer
  ));
  PERFORM app.link_purchase_item(p_item_id, new_id, 'duplicate');
  RETURN new_id;
END;
$$;

-- Cadastro novo pelo Catálogo, com os dados confirmados na tela.
CREATE FUNCTION app.create_product_for_item(p_item_id uuid, p_data jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  item public.purchase_invoice_item;
  new_id uuid;
BEGIN
  SELECT * INTO item FROM public.purchase_invoice_item it
   WHERE it.id = p_item_id AND it.economic_group_id = app.current_user_group() AND it.deleted_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('purchase_invoice_item %s.', p_item_id);
  END IF;
  PERFORM app.invoice_for_review(item.invoice_id);
  new_id := app.create_product(p_data || pg_catalog.jsonb_build_object(
    'barcode', COALESCE(app.clean_text(p_data ->> 'barcode'), item.barcode)
  ));
  PERFORM app.link_purchase_item(p_item_id, new_id, 'catalog');
  RETURN new_id;
END;
$$;

-- Descartar é a exclusão lógica, com motivo. O XML continua guardado.
CREATE FUNCTION app.discard_purchase_invoice(p_invoice_id uuid, p_reason text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.purchase_invoice;
  clean_reason text := app.require_reason(p_reason);
BEGIN
  SELECT * INTO target FROM public.purchase_invoice i
   WHERE i.id = p_invoice_id AND i.economic_group_id = app.current_user_group() AND i.deleted_at IS NULL
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('purchase_invoice %s.', p_invoice_id);
  END IF;
  PERFORM app.require_invoice_branch(target.branch_id);
  UPDATE public.purchase_invoice SET deleted_at = pg_catalog.clock_timestamp(), discard_reason = clean_reason
   WHERE id = target.id;
END;
$$;

-- Quem vê compras na filial vê as notas dela.
CREATE POLICY purchase_invoice_select ON purchase_invoice FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group())
         AND (app.has_permission('purchases.view', branch_id) OR app.has_permission('purchases.manage', branch_id)));
CREATE POLICY purchase_invoice_document_select ON purchase_invoice_document FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group())
         AND (app.has_permission('purchases.view', branch_id) OR app.has_permission('purchases.manage', branch_id)));
CREATE POLICY purchase_invoice_item_select ON purchase_invoice_item FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group())
         AND (app.has_permission('purchases.view', branch_id) OR app.has_permission('purchases.manage', branch_id)));
CREATE POLICY purchase_invoice_item_batch_select ON purchase_invoice_item_batch FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group())
         AND (app.has_permission('purchases.view', branch_id) OR app.has_permission('purchases.manage', branch_id)));
GRANT SELECT ON purchase_invoice, purchase_invoice_document, purchase_invoice_item, purchase_invoice_item_batch TO farmaerp_app;

CREATE VIEW v_purchase_invoice WITH (security_invoker = true) AS
  SELECT * FROM purchase_invoice WHERE deleted_at IS NULL;
CREATE VIEW v_purchase_invoice_item WITH (security_invoker = true) AS
  SELECT * FROM purchase_invoice_item WHERE deleted_at IS NULL;
CREATE VIEW v_purchase_invoice_item_batch WITH (security_invoker = true) AS
  SELECT * FROM purchase_invoice_item_batch WHERE deleted_at IS NULL;
CREATE VIEW v_purchase_invoice_document WITH (security_invoker = true) AS
  SELECT * FROM purchase_invoice_document WHERE deleted_at IS NULL;
GRANT SELECT ON v_purchase_invoice, v_purchase_invoice_document, v_purchase_invoice_item, v_purchase_invoice_item_batch TO farmaerp_app;

-- Notas das filiais que o usuário vê, com quantos itens ainda esperam a conferência.
CREATE FUNCTION app.list_purchase_invoices(p_branch_id uuid DEFAULT NULL, p_status text DEFAULT NULL, p_limit integer DEFAULT 100)
RETURNS TABLE (
  id uuid, branch_id uuid, branch_name text, supplier_id uuid, supplier_name text, access_key text, series integer,
  number bigint, issued_at timestamptz, invoice_total numeric, status text, not_postable_reason text, environment smallint,
  item_count bigint, pending_count bigint, created_at timestamptz
)
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT i.id, i.branch_id, b.name, i.supplier_id, COALESCE(s.trade_name, s.legal_name, i.emitter_name), i.access_key,
         i.series, i.number, i.issued_at, i.invoice_total, i.status, i.not_postable_reason, i.environment,
         (SELECT pg_catalog.count(*) FROM public.v_purchase_invoice_item it WHERE it.invoice_id = i.id),
         (SELECT pg_catalog.count(*) FROM public.v_purchase_invoice_item it WHERE it.invoice_id = i.id AND it.product_id IS NULL),
         i.created_at
    FROM public.v_purchase_invoice i
    JOIN public.branch b ON b.id = i.branch_id
    LEFT JOIN public.supplier s ON s.id = i.supplier_id
   WHERE (p_branch_id IS NULL OR i.branch_id = p_branch_id)
     AND (p_status IS NULL OR i.status = p_status)
   ORDER BY i.created_at DESC, i.id DESC
   LIMIT LEAST(GREATEST(COALESCE(p_limit, 100), 1), 500)
$$;

-- Itens da nota para a conferência: produto ligado, quantidade no estoque pelo fracionamento e os
-- avisos que o lançamento vai tratar (MS diferente do Catálogo e PMC abaixo do preço de venda).
CREATE FUNCTION app.purchase_invoice_items(p_invoice_id uuid)
RETURNS TABLE (
  id uuid, item_number smallint, supplier_code text, barcode text, description text, ncm text, cfop text, unit text,
  quantity numeric, unit_price numeric, products_value numeric, discount_value numeric, st_value numeric, ipi_value numeric,
  anvisa_code text, pmc numeric, product_id uuid, product_code bigint, product_name text, match_source text,
  fraction numeric, stock_quantity numeric, catalog_ms text, ms_differs boolean, sale_price numeric, pmc_below_price boolean,
  batches jsonb
)
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT it.id, it.item_number, it.supplier_code, it.barcode, it.description, it.ncm, it.cfop, it.unit, it.quantity,
         it.unit_price, it.products_value, it.discount_value, it.st_value, it.ipi_value, it.anvisa_code, it.pmc,
         it.product_id, p.code, p.display_name, it.match_source, computed.fraction,
         pg_catalog.round(it.quantity * computed.fraction, 3), cp.ms_registration,
         COALESCE(it.anvisa_code ~ '^[0-9]{13}$' AND cp.ms_registration IS NOT NULL AND cp.ms_registration <> it.anvisa_code, false),
         computed.price, COALESCE(it.pmc < computed.price, false),
         COALESCE((SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
                    'number', b.batch_number, 'quantity', b.quantity, 'manufacturedOn', b.manufactured_on::text,
                    'expiresOn', b.expires_on::text) ORDER BY b.expires_on, b.batch_number)
                     FROM public.v_purchase_invoice_item_batch b WHERE b.item_id = it.id), '[]'::jsonb)
    FROM public.v_purchase_invoice_item it
    LEFT JOIN public.v_product p ON p.id = it.product_id
    LEFT JOIN public.v_catalog_product cp ON cp.id = p.catalog_product_id
    LEFT JOIN LATERAL (
      SELECT CASE WHEN it.product_id IS NULL THEN NULL
                  ELSE app.effective_fraction(it.product_id, it.barcode_id, it.product_supplier_id) END AS fraction,
             CASE WHEN it.product_id IS NULL THEN NULL ELSE app.effective_price(it.product_id, it.branch_id) END AS price
    ) AS computed ON true
   WHERE it.invoice_id = p_invoice_id
   ORDER BY it.item_number
$$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  app.is_valid_access_key(text),
  app.import_purchase_invoice(jsonb, text, text, boolean),
  app.link_purchase_item(uuid, uuid, text),
  app.duplicate_product_for_item(uuid, uuid, jsonb),
  app.create_product_for_item(uuid, jsonb),
  app.discard_purchase_invoice(uuid, text),
  app.list_purchase_invoices(uuid, text, integer),
  app.purchase_invoice_items(uuid)
TO farmaerp_app;
