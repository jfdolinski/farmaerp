-- Up Migration

-- NF-e de transferência entre filiais, emitida pela central na filial de origem, com a de destino
-- como destinatária. A transferência de estoque continua imediata (como antes): a nota só acompanha
-- a mercadoria. Mesmo caminho da devolução ao fornecedor (0079): série da central, número reservado,
-- nota pendente até a resposta da Sefaz. Os CFOP de transferência entram nos padrões da filial.

-- Nota da central: devolução ou transferência.
ALTER TABLE central_nfe ADD COLUMN transfer_group uuid;
ALTER TABLE central_nfe DROP CONSTRAINT central_nfe_kind_check;
ALTER TABLE central_nfe ADD CONSTRAINT central_nfe_kind_check CHECK (kind IN ('supplier_return', 'transfer'));
ALTER TABLE central_nfe DROP CONSTRAINT central_nfe_source_check;
ALTER TABLE central_nfe ADD CONSTRAINT central_nfe_source_check CHECK (
  (kind = 'supplier_return') = (purchase_return_id IS NOT NULL) AND (kind = 'transfer') = (transfer_group IS NOT NULL)
);
-- Uma transferência tem no máximo uma nota viva (pendente ou autorizada).
CREATE UNIQUE INDEX central_nfe_transfer_live_key ON central_nfe (transfer_group) WHERE deleted_at IS NULL AND status <> 'rejected';
CREATE INDEX central_nfe_transfer_group_idx ON central_nfe (transfer_group);
DROP TRIGGER block_immutable_columns ON central_nfe;
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON central_nfe
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'branch_id', 'kind', 'purchase_return_id', 'transfer_group', 'series', 'number', 'access_key',
    'environment', 'total_value', 'emitted_at', 'user_id', 'deleted_at'
  );
CREATE OR REPLACE VIEW v_central_nfe WITH (security_invoker = true) AS
  SELECT id, economic_group_id, branch_id, kind, purchase_return_id, series, number, access_key, environment, status, protocol,
         status_code, reason, total_value, emitted_at, authorized_at, user_id, created_at, updated_at, deleted_at, version,
         updated_by, trace_id, transfer_group
    FROM central_nfe WHERE deleted_at IS NULL;

-- CFOP da transferência nos padrões da filial (mesma tabela dos padrões da devolução).
CREATE OR REPLACE FUNCTION app.return_tax_defaults() RETURNS jsonb
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$
  SELECT '{"cfop_internal": "5202", "cfop_interstate": "6202", "cfop_st_internal": "5411", "cfop_st_interstate": "6411",
           "simples_csosn": "102", "simples_csosn_st": "500", "normal_cst": "00", "normal_cst_st": "60",
           "pis_cst": "49", "cofins_cst": "49",
           "transfer_cfop_internal": "5152", "transfer_cfop_interstate": "6152",
           "transfer_cfop_st_internal": "5409", "transfer_cfop_st_interstate": "6409"}'::jsonb
$$;

ALTER TABLE purchase_return_tax_setting
  ADD COLUMN transfer_cfop_internal text NOT NULL DEFAULT (app.return_tax_defaults() ->> 'transfer_cfop_internal')
    CONSTRAINT purchase_return_tax_transfer_cfop_internal_check CHECK (transfer_cfop_internal ~ '^5[0-9]{3}$'),
  ADD COLUMN transfer_cfop_interstate text NOT NULL DEFAULT (app.return_tax_defaults() ->> 'transfer_cfop_interstate')
    CONSTRAINT purchase_return_tax_transfer_cfop_interstate_check CHECK (transfer_cfop_interstate ~ '^6[0-9]{3}$'),
  ADD COLUMN transfer_cfop_st_internal text NOT NULL DEFAULT (app.return_tax_defaults() ->> 'transfer_cfop_st_internal')
    CONSTRAINT purchase_return_tax_transfer_cfop_st_internal_check CHECK (transfer_cfop_st_internal ~ '^5[0-9]{3}$'),
  ADD COLUMN transfer_cfop_st_interstate text NOT NULL DEFAULT (app.return_tax_defaults() ->> 'transfer_cfop_st_interstate')
    CONSTRAINT purchase_return_tax_transfer_cfop_st_interstate_check CHECK (transfer_cfop_st_interstate ~ '^6[0-9]{3}$');

CREATE OR REPLACE FUNCTION app.return_tax_values(p_row public.purchase_return_tax_setting) RETURNS jsonb
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT CASE WHEN p_row.id IS NULL THEN app.return_tax_defaults()
              ELSE pg_catalog.jsonb_build_object(
                'cfop_internal', p_row.cfop_internal, 'cfop_interstate', p_row.cfop_interstate,
                'cfop_st_internal', p_row.cfop_st_internal, 'cfop_st_interstate', p_row.cfop_st_interstate,
                'simples_csosn', p_row.simples_csosn, 'simples_csosn_st', p_row.simples_csosn_st,
                'normal_cst', p_row.normal_cst, 'normal_cst_st', p_row.normal_cst_st,
                'pis_cst', p_row.pis_cst, 'cofins_cst', p_row.cofins_cst,
                'transfer_cfop_internal', p_row.transfer_cfop_internal,
                'transfer_cfop_interstate', p_row.transfer_cfop_interstate,
                'transfer_cfop_st_internal', p_row.transfer_cfop_st_internal,
                'transfer_cfop_st_interstate', p_row.transfer_cfop_st_interstate) END
$$;

CREATE OR REPLACE FUNCTION app.set_return_tax_setting(p_branch_id uuid, p_data jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.branch := app.require_return_tax_manage(p_branch_id);
  current public.purchase_return_tax_setting;
  wanted jsonb;
BEGIN
  IF p_data IS NULL OR pg_catalog.jsonb_typeof(p_data) <> 'object' THEN
    RAISE EXCEPTION 'Este padrão fiscal da devolução não é aceito.' USING ERRCODE = 'FA775', DETAIL = 'Dados fora do formato.';
  END IF;
  SELECT * INTO current FROM public.purchase_return_tax_setting t
   WHERE t.branch_id = target.id AND t.deleted_at IS NULL FOR UPDATE;
  SELECT app.return_tax_values(current) || COALESCE(pg_catalog.jsonb_object_agg(e.key, pg_catalog.btrim(e.value #>> '{}')), '{}'::jsonb)
    INTO wanted
    FROM pg_catalog.jsonb_each(p_data) e
   WHERE e.key IN (SELECT pg_catalog.jsonb_object_keys(app.return_tax_defaults()))
     AND pg_catalog.jsonb_typeof(e.value) IN ('string', 'number');
  BEGIN
    IF current.id IS NULL THEN
      INSERT INTO public.purchase_return_tax_setting (economic_group_id, branch_id) VALUES (app.current_user_group(), target.id)
      RETURNING * INTO current;
    END IF;
    UPDATE public.purchase_return_tax_setting t
       SET cfop_internal = wanted ->> 'cfop_internal', cfop_interstate = wanted ->> 'cfop_interstate',
           cfop_st_internal = wanted ->> 'cfop_st_internal', cfop_st_interstate = wanted ->> 'cfop_st_interstate',
           simples_csosn = wanted ->> 'simples_csosn', simples_csosn_st = wanted ->> 'simples_csosn_st',
           normal_cst = wanted ->> 'normal_cst', normal_cst_st = wanted ->> 'normal_cst_st',
           pis_cst = wanted ->> 'pis_cst', cofins_cst = wanted ->> 'cofins_cst',
           transfer_cfop_internal = wanted ->> 'transfer_cfop_internal',
           transfer_cfop_interstate = wanted ->> 'transfer_cfop_interstate',
           transfer_cfop_st_internal = wanted ->> 'transfer_cfop_st_internal',
           transfer_cfop_st_interstate = wanted ->> 'transfer_cfop_st_interstate'
     WHERE t.id = current.id
    RETURNING * INTO current;
  EXCEPTION WHEN check_violation OR not_null_violation THEN
    RAISE EXCEPTION 'Este padrão fiscal da devolução não é aceito.'
      USING ERRCODE = 'FA775', DETAIL = SQLERRM;
  END;
  RETURN app.return_tax_values(current);
END;
$$;

-- Tributação de venda em vigor do produto na filial (Catálogo ou a própria, como no caixa).
CREATE FUNCTION app.product_sale_tax(p_product_id uuid, p_branch_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE((
    SELECT pg_catalog.jsonb_build_object('origin', t.origin, 'icms_cst', t.icms_cst, 'icms_csosn', t.icms_csosn, 'icms_rate', t.icms_rate)
      FROM public.product p
      JOIN public.branch b ON b.id = p_branch_id
      JOIN public.company c ON c.id = b.company_id
      JOIN public.catalog_product_tax t ON t.catalog_product_id = p.catalog_product_id AND t.tax_regime = c.tax_regime
           AND t.state = b.state AND t.deleted_at IS NULL AND t.valid_from <= app.local_today()
     WHERE p.id = p_product_id
     ORDER BY t.valid_from DESC
     LIMIT 1
  ), (
    SELECT pg_catalog.jsonb_build_object('origin', r.origin, 'icms_cst', r.icms_cst, 'icms_csosn', r.icms_csosn, 'icms_rate', r.icms_rate)
      FROM public.product_tax_rule r
      JOIN public.branch b ON b.id = p_branch_id
      JOIN public.company c ON c.id = b.company_id
     WHERE r.product_id = p_product_id AND r.tax_regime = c.tax_regime AND r.state = b.state AND r.deleted_at IS NULL
     LIMIT 1
  ))
$$;

-- Transferência do grupo: as saídas e entradas da mesma operação (sem as que vieram de nota importada,
-- que já têm a nota do sistema anterior).
CREATE FUNCTION app.find_transfer(p_transfer uuid)
RETURNS TABLE (origin uuid, destination uuid, product_id uuid, quantity numeric, reason text, occurred_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT pg_catalog.min(m.branch_id::text) FILTER (WHERE m.quantity < 0)::uuid,
         pg_catalog.min(m.branch_id::text) FILTER (WHERE m.quantity > 0)::uuid,
         pg_catalog.min(m.product_id::text)::uuid,
         pg_catalog.sum(m.quantity) FILTER (WHERE m.quantity > 0),
         pg_catalog.min(m.reason),
         pg_catalog.min(m.occurred_at)
    FROM public.stock_movement m
   WHERE m.transfer_group = p_transfer AND m.movement_type = 'transfer' AND m.deleted_at IS NULL
     AND m.economic_group_id = app.current_user_group() AND m.imported_stock_item_id IS NULL AND m.reversal_of IS NULL
  HAVING pg_catalog.count(*) > 0
$$;

-- Transferência para a NF-e: existe, é do grupo e a pessoa emite NF-e na origem.
CREATE FUNCTION app.require_transfer_nfe(p_transfer uuid)
RETURNS TABLE (origin uuid, destination uuid, product_id uuid, quantity numeric, reason text, occurred_at timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  found record;
BEGIN
  SELECT * INTO found FROM app.find_transfer(p_transfer);
  IF found.origin IS NULL OR found.destination IS NULL THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.' USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('transfer %s.', p_transfer);
  END IF;
  PERFORM app.require_stock_permission('fiscal.nfe_issue', found.origin);
  RETURN QUERY SELECT found.origin, found.destination, found.product_id, found.quantity, found.reason, found.occurred_at;
END;
$$;

-- Prepara a NF-e da transferência: confere, reserva o número e devolve o que o motor precisa. O valor
-- é o custo médio da origem.
CREATE FUNCTION app.transfer_nfe_prepare(p_transfer uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  moved record;
  origin_row public.branch;
  destination_row public.branch;
  company_row public.company;
  destination_company public.company;
  item public.product;
  catalog public.catalog_product;
  rules public.purchase_return_tax_setting;
  numbering public.central_nfe_series;
  sale_tax jsonb;
  st boolean;
  interstate boolean;
  simples boolean;
  cost numeric;
  gtin text;
  tax jsonb;
  gross bigint;
  group_id uuid := app.current_user_group();
BEGIN
  SELECT * INTO moved FROM app.require_transfer_nfe(p_transfer);
  -- Uma emissão de cada vez para a mesma transferência.
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_transfer::text, 84));
  IF EXISTS (SELECT 1 FROM public.central_nfe n WHERE n.transfer_group = p_transfer AND n.status <> 'rejected' AND n.deleted_at IS NULL) THEN
    RAISE EXCEPTION 'Esta transferência já tem NF-e emitida ou em transmissão.'
      USING ERRCODE = 'FA776', DETAIL = pg_catalog.format('transfer %s.', p_transfer);
  END IF;
  SELECT * INTO origin_row FROM public.branch b WHERE b.id = moved.origin;
  SELECT * INTO destination_row FROM public.branch b WHERE b.id = moved.destination;
  SELECT * INTO company_row FROM public.company c WHERE c.id = origin_row.company_id;
  SELECT * INTO destination_company FROM public.company c WHERE c.id = destination_row.company_id;
  -- Transferência fiscal é entre estabelecimentos da mesma empresa (mesma raiz do CNPJ).
  IF pg_catalog.left(origin_row.cnpj, 8) <> pg_catalog.left(destination_row.cnpj, 8) THEN
    RAISE EXCEPTION 'A transferência entre empresas diferentes não tem NF-e de transferência.'
      USING ERRCODE = 'FA777', DETAIL = pg_catalog.format('Origem %s, destino %s.', origin_row.id, destination_row.id);
  END IF;
  IF origin_row.state_registration IS NULL OR origin_row.street IS NULL OR origin_row.street_number IS NULL
     OR origin_row.district IS NULL OR origin_row.city IS NULL OR origin_row.city_code IS NULL OR origin_row.state IS NULL
     OR origin_row.postal_code IS NULL OR company_row.tax_regime IS NULL THEN
    RAISE EXCEPTION 'A filial está sem os dados fiscais completos.'
      USING ERRCODE = 'FA724', DETAIL = pg_catalog.format('branch %s (origem).', origin_row.id);
  END IF;
  IF destination_row.state_registration IS NULL OR destination_row.street IS NULL OR destination_row.street_number IS NULL
     OR destination_row.district IS NULL OR destination_row.city IS NULL OR destination_row.city_code IS NULL
     OR destination_row.state IS NULL OR destination_row.postal_code IS NULL THEN
    RAISE EXCEPTION 'A filial está sem os dados fiscais completos.'
      USING ERRCODE = 'FA724', DETAIL = pg_catalog.format('branch %s (destino).', destination_row.id);
  END IF;

  SELECT * INTO item FROM public.product p WHERE p.id = moved.product_id;
  SELECT * INTO catalog FROM public.catalog_product cp WHERE cp.id = item.catalog_product_id;
  IF COALESCE(catalog.ncm, item.own_ncm) IS NULL THEN
    RAISE EXCEPTION 'O produto da transferência está sem NCM.'
      USING ERRCODE = 'FA779', DETAIL = pg_catalog.format('product %s.', item.id);
  END IF;
  cost := app.average_cost(item.id, origin_row.id);
  IF cost IS NULL OR cost <= 0 THEN
    RAISE EXCEPTION 'O produto não tem custo médio na filial de origem.'
      USING ERRCODE = 'FA778', DETAIL = pg_catalog.format('product %s, branch %s.', item.id, origin_row.id);
  END IF;
  gross := pg_catalog.round(moved.quantity * cost * 100)::bigint;

  SELECT * INTO rules FROM public.purchase_return_tax_setting t WHERE t.branch_id = origin_row.id AND t.deleted_at IS NULL;
  IF rules.id IS NULL THEN
    INSERT INTO public.purchase_return_tax_setting (economic_group_id, branch_id) VALUES (group_id, origin_row.id)
    RETURNING * INTO rules;
  END IF;
  sale_tax := COALESCE(app.product_sale_tax(item.id, origin_row.id), '{}'::jsonb);
  -- ICMS já recolhido por substituição tributária na venda (CSOSN 500 ou CST 10, 30, 60, 70).
  st := sale_tax ->> 'icms_csosn' = '500' OR sale_tax ->> 'icms_cst' IN ('10', '30', '60', '70');
  interstate := origin_row.state::text <> destination_row.state::text;
  simples := company_row.tax_regime IN (1, 4);
  tax := pg_catalog.jsonb_build_object(
    'cfop', CASE WHEN interstate THEN CASE WHEN st THEN rules.transfer_cfop_st_interstate ELSE rules.transfer_cfop_interstate END
                 ELSE CASE WHEN st THEN rules.transfer_cfop_st_internal ELSE rules.transfer_cfop_internal END END,
    'origin', COALESCE((sale_tax ->> 'origin')::integer, 0),
    'pis_cst', rules.pis_cst, 'pis_rate', 0,
    'cofins_cst', rules.cofins_cst, 'cofins_rate', 0
  );
  IF simples THEN
    tax := tax || pg_catalog.jsonb_build_object('icms_csosn', CASE WHEN st THEN rules.simples_csosn_st ELSE rules.simples_csosn END);
  ELSE
    tax := tax || pg_catalog.jsonb_build_object('icms_cst', CASE WHEN st THEN rules.normal_cst_st ELSE rules.normal_cst END);
    IF sale_tax ? 'icms_rate' AND sale_tax ->> 'icms_rate' IS NOT NULL THEN
      tax := tax || pg_catalog.jsonb_build_object('icms_rate', (sale_tax ->> 'icms_rate')::numeric);
    END IF;
  END IF;
  SELECT pb.code INTO gtin FROM public.product_barcode pb
   WHERE pb.product_id = item.id AND pb.deleted_at IS NULL AND NOT pb.is_internal AND app.is_valid_gtin(pb.code)
   ORDER BY pb.is_primary DESC, pb.code LIMIT 1;

  numbering := app.lock_central_nfe_series(group_id, origin_row.id);
  UPDATE public.central_nfe_series SET last_used_number = last_used_number + 1 WHERE id = numbering.id
  RETURNING * INTO numbering;

  RETURN pg_catalog.jsonb_build_object(
    'transferId', p_transfer,
    'branchId', origin_row.id,
    'companyId', origin_row.company_id,
    'state', origin_row.state,
    'series', numbering.series,
    'number', numbering.last_used_number,
    'totalValue', gross / 100.0,
    'input', pg_catalog.jsonb_build_object(
      'issuer', pg_catalog.jsonb_build_object(
        'cnpj', origin_row.cnpj, 'stateRegistration', origin_row.state_registration, 'legalName', company_row.legal_name,
        'tradeName', company_row.trade_name, 'street', origin_row.street, 'number', origin_row.street_number,
        'complement', origin_row.complement, 'district', origin_row.district, 'cityCode', origin_row.city_code,
        'city', origin_row.city, 'uf', origin_row.state, 'postalCode', origin_row.postal_code, 'phone', origin_row.phone,
        'taxRegime', company_row.tax_regime
      ),
      'recipient', pg_catalog.jsonb_build_object(
        'cnpj', destination_row.cnpj, 'name', destination_company.legal_name, 'ieIndicator', 1,
        'stateRegistration', destination_row.state_registration, 'street', destination_row.street,
        'number', destination_row.street_number, 'complement', destination_row.complement, 'district', destination_row.district,
        'cityCode', destination_row.city_code, 'city', destination_row.city, 'uf', destination_row.state,
        'postalCode', destination_row.postal_code, 'phone', destination_row.phone
      ),
      'items', pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
        'code', item.code::text,
        'gtin', gtin,
        'description', COALESCE(catalog.name, item.display_name),
        'ncm', COALESCE(catalog.ncm, item.own_ncm),
        'cest', COALESCE(catalog.cest, item.own_cest),
        'unit', item.unit,
        'quantityMilli', pg_catalog.round(moved.quantity * 1000)::bigint,
        'unitPriceCents', pg_catalog.round(cost * 100)::bigint,
        'grossCents', gross,
        'discountCents', 0,
        'tax', tax
      )),
      'series', numbering.series,
      'number', numbering.last_used_number,
      'operation', 'TRANSFERENCIA DE MERCADORIA',
      'purpose', 1,
      'presence', 0,
      'finalConsumer', false,
      'references', '[]'::jsonb,
      'additionalInfo', pg_catalog.format(
        'Transferência entre filiais: de %s para %s, pelo custo médio da origem. Motivo: %s.',
        origin_row.name, destination_row.name, moved.reason)
    )
  );
END;
$$;

-- Certificado da filial de origem, cifrado (a API abre com a chave dela).
CREATE FUNCTION app.transfer_nfe_certificate(p_transfer uuid) RETURNS TABLE (company_id uuid, encrypted_pfx bytea, encrypted_password bytea)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  moved record;
BEGIN
  SELECT * INTO moved FROM app.require_transfer_nfe(p_transfer);
  RETURN QUERY
    SELECT b.company_id, bc.encrypted_pfx, bc.encrypted_password
      FROM public.branch b
      LEFT JOIN public.branch_certificate bc ON bc.branch_id = b.id AND bc.deleted_at IS NULL
     WHERE b.id = moved.origin;
END;
$$;

-- Guarda a nota assinada (pendente) com o número reservado. Mesma transação do preparo.
CREATE FUNCTION app.transfer_nfe_store(
  p_transfer uuid, p_series integer, p_number bigint, p_access_key text, p_environment smallint, p_xml text,
  p_emitted_at timestamptz, p_total numeric
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  moved record;
  new_id uuid;
BEGIN
  SELECT * INTO moved FROM app.require_transfer_nfe(p_transfer);
  IF NOT EXISTS (
    SELECT 1 FROM public.central_nfe_series s
     WHERE s.branch_id = moved.origin AND s.series = p_series AND s.last_used_number = p_number AND s.deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Os dados da nota são inválidos.' USING ERRCODE = 'FA931', DETAIL = 'Número fora da reserva.';
  END IF;
  INSERT INTO public.central_nfe (
    economic_group_id, branch_id, kind, transfer_group, series, number, access_key, environment, status, xml,
    total_value, emitted_at, user_id
  ) VALUES (
    app.current_user_group(), moved.origin, 'transfer', p_transfer, p_series, p_number, p_access_key, p_environment, 'pending',
    p_xml, p_total, p_emitted_at, app.current_user_id()
  ) RETURNING id INTO new_id;
  RETURN new_id;
END;
$$;

-- Nota pendente da transferência, para transmitir (de novo) o mesmo XML.
CREATE FUNCTION app.transfer_nfe_pending(p_transfer uuid) RETURNS TABLE (id uuid, access_key text, environment smallint, xml text, state text)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  moved record;
BEGIN
  SELECT * INTO moved FROM app.require_transfer_nfe(p_transfer);
  RETURN QUERY
    SELECT n.id, n.access_key, n.environment, n.xml, b.state::text
      FROM public.central_nfe n JOIN public.branch b ON b.id = n.branch_id
     WHERE n.transfer_group = p_transfer AND n.status = 'pending' AND n.deleted_at IS NULL;
END;
$$;

-- NF-e das transferências, para a tela do estoque (a mais recente de cada transferência).
CREATE FUNCTION app.transfer_nfes(p_transfers uuid[]) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE(pg_catalog.jsonb_object_agg(x.transfer_group, x.doc), '{}'::jsonb)
    FROM (
      SELECT DISTINCT ON (n.transfer_group) n.transfer_group, pg_catalog.jsonb_build_object(
               'id', n.id, 'series', n.series, 'number', n.number, 'access_key', n.access_key, 'status', n.status,
               'status_code', n.status_code, 'reason', n.reason, 'total_value', n.total_value,
               'authorized_at', n.authorized_at, 'can_issue', app.has_permission('fiscal.nfe_issue', n.branch_id)) AS doc
        FROM public.central_nfe n
       WHERE n.transfer_group = ANY (p_transfers) AND n.deleted_at IS NULL
         AND n.economic_group_id = app.current_user_group() AND app.has_permission('stock.view', n.branch_id)
       ORDER BY n.transfer_group, n.created_at DESC, n.id DESC
    ) x
$$;

-- XML da NF-e para baixar: quem vê as compras (devolução) ou o estoque (transferência) da filial.
CREATE OR REPLACE FUNCTION app.central_nfe_xml(p_id uuid) RETURNS TABLE (access_key text, status text, xml text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT n.access_key, n.status, n.xml FROM public.central_nfe n
   WHERE n.id = p_id AND n.deleted_at IS NULL AND n.economic_group_id = app.current_user_group()
     AND app.has_permission(CASE n.kind WHEN 'transfer' THEN 'stock.view' ELSE 'purchases.view' END, n.branch_id)
$$;

REVOKE ALL ON FUNCTION app.product_sale_tax(uuid, uuid), app.find_transfer(uuid), app.require_transfer_nfe(uuid),
  app.transfer_nfe_prepare(uuid), app.transfer_nfe_certificate(uuid),
  app.transfer_nfe_store(uuid, integer, bigint, text, smallint, text, timestamptz, numeric),
  app.transfer_nfe_pending(uuid), app.transfer_nfes(uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.transfer_nfe_prepare(uuid), app.transfer_nfe_certificate(uuid),
  app.transfer_nfe_store(uuid, integer, bigint, text, smallint, text, timestamptz, numeric),
  app.transfer_nfe_pending(uuid), app.transfer_nfes(uuid[]) TO farmaerp_app;
