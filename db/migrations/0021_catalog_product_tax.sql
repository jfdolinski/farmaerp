-- Up Migration

-- Tributação do Catálogo, por item, regime e UF da filial, com vigência. Nesta etapa cobre a venda
-- interna. A loja só consulta: quem grava é a importação do Catálogo. Os valores retidos de ST
-- (CST 60 e CSOSN 500) vêm da nota de compra, na etapa de entrada de nota.

CREATE TABLE catalog_product_tax (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  catalog_product_id uuid NOT NULL REFERENCES catalog_product (id),
  -- Mesmos códigos de company.tax_regime.
  tax_regime smallint NOT NULL CONSTRAINT catalog_product_tax_regime_check CHECK (tax_regime IN (1, 2, 3, 4)),
  state char(2) NOT NULL CONSTRAINT catalog_product_tax_state_check CHECK (state IN (
    'AC', 'AL', 'AM', 'AP', 'BA', 'CE', 'DF', 'ES', 'GO', 'MA', 'MG', 'MS', 'MT', 'PA', 'PB', 'PE', 'PI',
    'PR', 'RJ', 'RN', 'RO', 'RR', 'RS', 'SC', 'SE', 'SP', 'TO'
  )),
  valid_from date NOT NULL,
  cfop text NOT NULL CONSTRAINT catalog_product_tax_cfop_check CHECK (cfop ~ '^5[0-9]{3}$'),
  origin smallint NOT NULL CONSTRAINT catalog_product_tax_origin_check CHECK (origin BETWEEN 0 AND 8),
  benefit_code text CONSTRAINT catalog_product_tax_benefit_code_check CHECK (benefit_code ~ '^([A-Z0-9]{8}|[A-Z0-9]{10})$'),
  icms_cst text CONSTRAINT catalog_product_tax_icms_cst_check CHECK (
    icms_cst IN ('00', '10', '20', '30', '40', '41', '50', '51', '60', '70', '90')
  ),
  icms_csosn text CONSTRAINT catalog_product_tax_icms_csosn_check CHECK (
    icms_csosn IN ('101', '102', '103', '201', '202', '203', '300', '400', '500', '900')
  ),
  icms_rate numeric(7, 4) CONSTRAINT catalog_product_tax_icms_rate_range_check CHECK (icms_rate BETWEEN 0 AND 100),
  icms_base_reduction numeric(7, 4) CONSTRAINT catalog_product_tax_icms_base_reduction_check CHECK (icms_base_reduction BETWEEN 0 AND 100),
  fcp_rate numeric(7, 4) CONSTRAINT catalog_product_tax_fcp_rate_check CHECK (fcp_rate BETWEEN 0 AND 100),
  -- modBCST da NF-e: 0 tabelado, 1 lista negativa, 2 positiva, 3 neutra, 4 MVA, 5 pauta, 6 valor da operação.
  st_base_mode smallint CONSTRAINT catalog_product_tax_st_base_mode_check CHECK (st_base_mode BETWEEN 0 AND 6),
  st_mva numeric(7, 4) CONSTRAINT catalog_product_tax_st_mva_check CHECK (st_mva >= 0),
  st_rate numeric(7, 4) CONSTRAINT catalog_product_tax_st_rate_check CHECK (st_rate BETWEEN 0 AND 100),
  st_base_reduction numeric(7, 4) CONSTRAINT catalog_product_tax_st_base_reduction_check CHECK (st_base_reduction BETWEEN 0 AND 100),
  st_fcp_rate numeric(7, 4) CONSTRAINT catalog_product_tax_st_fcp_rate_check CHECK (st_fcp_rate BETWEEN 0 AND 100),
  pis_cst text NOT NULL CONSTRAINT catalog_product_tax_pis_cst_check CHECK (
    pis_cst IN ('01', '02', '03', '04', '05', '06', '07', '08', '09', '49', '99')
  ),
  pis_rate numeric(7, 4) CONSTRAINT catalog_product_tax_pis_rate_range_check CHECK (pis_rate BETWEEN 0 AND 100),
  cofins_cst text NOT NULL CONSTRAINT catalog_product_tax_cofins_cst_check CHECK (
    cofins_cst IN ('01', '02', '03', '04', '05', '06', '07', '08', '09', '49', '99')
  ),
  cofins_rate numeric(7, 4) CONSTRAINT catalog_product_tax_cofins_rate_range_check CHECK (cofins_rate BETWEEN 0 AND 100),
  -- A tabela oficial de CST e cClassTrib muda com frequência: aqui só o formato é conferido.
  ibs_cbs_cst text CONSTRAINT catalog_product_tax_ibs_cbs_cst_check CHECK (ibs_cbs_cst ~ '^[0-9]{3}$'),
  class_trib text CONSTRAINT catalog_product_tax_class_trib_check CHECK (class_trib ~ '^[0-9]{6}$'),
  ibs_state_rate numeric(7, 4) CONSTRAINT catalog_product_tax_ibs_state_rate_check CHECK (ibs_state_rate BETWEEN 0 AND 100),
  ibs_city_rate numeric(7, 4) CONSTRAINT catalog_product_tax_ibs_city_rate_check CHECK (ibs_city_rate BETWEEN 0 AND 100),
  cbs_rate numeric(7, 4) CONSTRAINT catalog_product_tax_cbs_rate_check CHECK (cbs_rate BETWEEN 0 AND 100),
  ibs_cbs_reduction numeric(7, 4) CONSTRAINT catalog_product_tax_ibs_cbs_reduction_range_check CHECK (ibs_cbs_reduction BETWEEN 0 AND 100),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid,
  -- Simples Nacional e MEI usam CSOSN; os demais regimes usam CST.
  CONSTRAINT catalog_product_tax_icms_code_check CHECK (
    CASE WHEN tax_regime IN (1, 4)
         THEN icms_csosn IS NOT NULL AND icms_cst IS NULL
         ELSE icms_cst IS NOT NULL AND icms_csosn IS NULL
    END
  ),
  CONSTRAINT catalog_product_tax_icms_rate_check CHECK (
    icms_cst IS NULL OR icms_cst NOT IN ('00', '10', '20', '70') OR icms_rate IS NOT NULL
  ),
  -- Com ST nesta operação, a modalidade e a alíquota são obrigatórias. CST 90 e CSOSN 900 podem ou não
  -- ter ST. Nos demais códigos, a ST não se aplica.
  CONSTRAINT catalog_product_tax_st_required_check CHECK (
    (icms_cst IS NULL OR icms_cst NOT IN ('10', '30', '70'))
    AND (icms_csosn IS NULL OR icms_csosn NOT IN ('201', '202', '203'))
    OR (st_base_mode IS NOT NULL AND st_rate IS NOT NULL)
  ),
  CONSTRAINT catalog_product_tax_st_allowed_check CHECK (
    -- COALESCE: com o outro código vazio, o IN daria nulo, e um CHECK nulo deixa passar.
    COALESCE(icms_cst IN ('10', '30', '70', '90'), false) OR COALESCE(icms_csosn IN ('201', '202', '203', '900'), false)
    OR num_nonnulls(st_base_mode, st_mva, st_rate, st_base_reduction, st_fcp_rate) = 0
  ),
  CONSTRAINT catalog_product_tax_st_mva_required_check CHECK (st_base_mode IS DISTINCT FROM 4 OR st_mva IS NOT NULL),
  -- CST 01 e 02 são por alíquota; os demais podem não ter.
  CONSTRAINT catalog_product_tax_pis_rate_check CHECK (pis_cst NOT IN ('01', '02') OR pis_rate IS NOT NULL),
  CONSTRAINT catalog_product_tax_cofins_rate_check CHECK (cofins_cst NOT IN ('01', '02') OR cofins_rate IS NOT NULL),
  CONSTRAINT catalog_product_tax_ibs_cbs_group_check CHECK (
    num_nonnulls(ibs_cbs_cst, class_trib, ibs_state_rate, ibs_city_rate, cbs_rate) IN (0, 5)
  ),
  CONSTRAINT catalog_product_tax_ibs_cbs_reduction_check CHECK (ibs_cbs_reduction IS NULL OR ibs_cbs_cst IS NOT NULL)
);
CREATE UNIQUE INDEX catalog_product_tax_active_key
  ON catalog_product_tax (catalog_product_id, tax_regime, state, valid_from) WHERE deleted_at IS NULL;
CALL app.apply_table_standard('public.catalog_product_tax');
-- A regra nunca muda: uma alteração é uma linha nova, e fica o histórico do que valeu em cada data.
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON catalog_product_tax
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'catalog_product_id', 'tax_regime', 'state', 'valid_from', 'cfop', 'origin', 'benefit_code', 'icms_cst', 'icms_csosn',
    'icms_rate', 'icms_base_reduction', 'fcp_rate', 'st_base_mode', 'st_mva', 'st_rate', 'st_base_reduction', 'st_fcp_rate',
    'pis_cst', 'pis_rate', 'cofins_cst', 'cofins_rate', 'ibs_cbs_cst', 'class_trib', 'ibs_state_rate', 'ibs_city_rate',
    'cbs_rate', 'ibs_cbs_reduction'
  );

-- Texto vazio vale como não informado.
CREATE FUNCTION app.catalog_tax_text(p_entry jsonb, p_key text) RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$
  SELECT NULLIF(pg_catalog.btrim(p_entry ->> p_key), '')
$$;

-- A NF-e aceita até quatro casas. Arredondar uma alíquota sem avisar mudaria o imposto.
CREATE FUNCTION app.catalog_tax_rate(p_entry jsonb, p_key text) RETURNS numeric
LANGUAGE plpgsql IMMUTABLE
SET search_path = ''
AS $$
DECLARE
  value numeric := (app.catalog_tax_text(p_entry, p_key))::numeric;
BEGIN
  IF value <> pg_catalog.round(value, 4) THEN
    RAISE EXCEPTION 'A tributação do Catálogo tem dados inválidos.'
      USING ERRCODE = 'FA922', DETAIL = pg_catalog.format('%s com mais de quatro casas.', p_key);
  END IF;
  RETURN value;
END;
$$;

-- Cada entrada vale para vários regimes e UFs. Valor igual ao vigente não gera linha, para não descer
-- de novo aos terminais na Etapa 3. Mesma vigência com outro valor é correção: substitui a anterior.
CREATE FUNCTION app.upsert_catalog_product_taxes(p_item_id uuid, p_taxes jsonb) RETURNS void
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  allowed_keys constant text[] := ARRAY[
    'regimes', 'states', 'validFrom', 'cfop', 'origin', 'benefitCode', 'icmsCst', 'icmsCsosn', 'icmsRate', 'icmsBaseReduction',
    'fcpRate', 'stBaseMode', 'stMva', 'stRate', 'stBaseReduction', 'stFcpRate', 'pisCst', 'pisRate', 'cofinsCst', 'cofinsRate',
    'ibsCbsCst', 'classTrib', 'ibsStateRate', 'ibsCityRate', 'cbsRate', 'ibsCbsReduction'
  ];
  entry jsonb;
  unknown_key text;
  regime_value smallint;
  state_value text;
  combination text;
  seen text[] := '{}';
  candidate public.catalog_product_tax;
  current_rule public.catalog_product_tax;
BEGIN
  IF p_taxes IS NULL THEN
    RETURN;
  END IF;
  IF pg_catalog.jsonb_typeof(p_taxes) <> 'array' THEN
    RAISE EXCEPTION 'A tributação do Catálogo tem dados inválidos.'
      USING ERRCODE = 'FA922', DETAIL = 'taxes precisa ser uma lista.';
  END IF;

  FOR entry IN SELECT value FROM pg_catalog.jsonb_array_elements(p_taxes) AS value LOOP
    IF pg_catalog.jsonb_typeof(entry) <> 'object' THEN
      RAISE EXCEPTION 'A tributação do Catálogo tem dados inválidos.'
        USING ERRCODE = 'FA922', DETAIL = 'Cada entrada de taxes precisa ser um objeto.';
    END IF;
    -- Um nome digitado errado não pode virar um imposto vazio.
    SELECT key INTO unknown_key FROM pg_catalog.jsonb_object_keys(entry) AS key WHERE key <> ALL (allowed_keys) LIMIT 1;
    IF FOUND THEN
      RAISE EXCEPTION 'A tributação do Catálogo tem dados inválidos.'
        USING ERRCODE = 'FA922', DETAIL = pg_catalog.format('Campo desconhecido: %s.', unknown_key);
    END IF;
    IF COALESCE(pg_catalog.jsonb_typeof(entry -> 'regimes'), '') <> 'array' OR pg_catalog.jsonb_array_length(entry -> 'regimes') = 0
       OR COALESCE(pg_catalog.jsonb_typeof(entry -> 'states'), '') <> 'array' OR pg_catalog.jsonb_array_length(entry -> 'states') = 0
       OR app.catalog_tax_text(entry, 'validFrom') IS NULL
       OR app.catalog_tax_text(entry, 'cfop') IS NULL
       OR app.catalog_tax_text(entry, 'origin') IS NULL
       OR app.catalog_tax_text(entry, 'pisCst') IS NULL
       OR app.catalog_tax_text(entry, 'cofinsCst') IS NULL THEN
      RAISE EXCEPTION 'A tributação do Catálogo tem dados inválidos.'
        USING ERRCODE = 'FA922', DETAIL = 'Faltam regimes, states, validFrom, cfop, origin, pisCst ou cofinsCst.';
    END IF;

    candidate := NULL;
    candidate.catalog_product_id := p_item_id;
    candidate.valid_from := (entry ->> 'validFrom')::date;
    candidate.cfop := app.catalog_tax_text(entry, 'cfop');
    candidate.origin := (app.catalog_tax_text(entry, 'origin'))::smallint;
    candidate.benefit_code := app.catalog_tax_text(entry, 'benefitCode');
    candidate.icms_cst := app.catalog_tax_text(entry, 'icmsCst');
    candidate.icms_csosn := app.catalog_tax_text(entry, 'icmsCsosn');
    candidate.icms_rate := app.catalog_tax_rate(entry, 'icmsRate');
    candidate.icms_base_reduction := app.catalog_tax_rate(entry, 'icmsBaseReduction');
    candidate.fcp_rate := app.catalog_tax_rate(entry, 'fcpRate');
    candidate.st_base_mode := (app.catalog_tax_text(entry, 'stBaseMode'))::smallint;
    candidate.st_mva := app.catalog_tax_rate(entry, 'stMva');
    candidate.st_rate := app.catalog_tax_rate(entry, 'stRate');
    candidate.st_base_reduction := app.catalog_tax_rate(entry, 'stBaseReduction');
    candidate.st_fcp_rate := app.catalog_tax_rate(entry, 'stFcpRate');
    candidate.pis_cst := app.catalog_tax_text(entry, 'pisCst');
    candidate.pis_rate := app.catalog_tax_rate(entry, 'pisRate');
    candidate.cofins_cst := app.catalog_tax_text(entry, 'cofinsCst');
    candidate.cofins_rate := app.catalog_tax_rate(entry, 'cofinsRate');
    candidate.ibs_cbs_cst := app.catalog_tax_text(entry, 'ibsCbsCst');
    candidate.class_trib := app.catalog_tax_text(entry, 'classTrib');
    candidate.ibs_state_rate := app.catalog_tax_rate(entry, 'ibsStateRate');
    candidate.ibs_city_rate := app.catalog_tax_rate(entry, 'ibsCityRate');
    candidate.cbs_rate := app.catalog_tax_rate(entry, 'cbsRate');
    candidate.ibs_cbs_reduction := app.catalog_tax_rate(entry, 'ibsCbsReduction');

    FOR regime_value IN SELECT (value)::smallint FROM pg_catalog.jsonb_array_elements_text(entry -> 'regimes') AS value LOOP
      FOR state_value IN SELECT pg_catalog.upper(pg_catalog.btrim(value)) FROM pg_catalog.jsonb_array_elements_text(entry -> 'states') AS value LOOP
        combination := pg_catalog.format('%s/%s/%s', regime_value, state_value, candidate.valid_from);
        -- Duas entradas para a mesma combinação: valeria a última, sem ninguém perceber.
        IF combination = ANY (seen) THEN
          RAISE EXCEPTION 'A tributação do Catálogo tem dados inválidos.'
            USING ERRCODE = 'FA922', DETAIL = pg_catalog.format('Combinação repetida: %s.', combination);
        END IF;
        seen := seen || combination;

        SELECT * INTO current_rule FROM public.catalog_product_tax t
         WHERE t.catalog_product_id = p_item_id AND t.tax_regime = regime_value AND t.state = state_value
           AND t.valid_from <= candidate.valid_from AND t.deleted_at IS NULL
         ORDER BY t.valid_from DESC
         LIMIT 1;
        IF FOUND THEN
          CONTINUE WHEN (
            current_rule.cfop, current_rule.origin, current_rule.benefit_code, current_rule.icms_cst, current_rule.icms_csosn,
            current_rule.icms_rate, current_rule.icms_base_reduction, current_rule.fcp_rate, current_rule.st_base_mode,
            current_rule.st_mva, current_rule.st_rate, current_rule.st_base_reduction, current_rule.st_fcp_rate,
            current_rule.pis_cst, current_rule.pis_rate, current_rule.cofins_cst, current_rule.cofins_rate,
            current_rule.ibs_cbs_cst, current_rule.class_trib, current_rule.ibs_state_rate, current_rule.ibs_city_rate,
            current_rule.cbs_rate, current_rule.ibs_cbs_reduction
          ) IS NOT DISTINCT FROM (
            candidate.cfop, candidate.origin, candidate.benefit_code, candidate.icms_cst, candidate.icms_csosn,
            candidate.icms_rate, candidate.icms_base_reduction, candidate.fcp_rate, candidate.st_base_mode,
            candidate.st_mva, candidate.st_rate, candidate.st_base_reduction, candidate.st_fcp_rate,
            candidate.pis_cst, candidate.pis_rate, candidate.cofins_cst, candidate.cofins_rate,
            candidate.ibs_cbs_cst, candidate.class_trib, candidate.ibs_state_rate, candidate.ibs_city_rate,
            candidate.cbs_rate, candidate.ibs_cbs_reduction
          );
          IF current_rule.valid_from = candidate.valid_from THEN
            UPDATE public.catalog_product_tax SET deleted_at = pg_catalog.clock_timestamp() WHERE id = current_rule.id;
          END IF;
        END IF;

        INSERT INTO public.catalog_product_tax (
          catalog_product_id, tax_regime, state, valid_from, cfop, origin, benefit_code, icms_cst, icms_csosn, icms_rate,
          icms_base_reduction, fcp_rate, st_base_mode, st_mva, st_rate, st_base_reduction, st_fcp_rate, pis_cst, pis_rate,
          cofins_cst, cofins_rate, ibs_cbs_cst, class_trib, ibs_state_rate, ibs_city_rate, cbs_rate, ibs_cbs_reduction
        ) VALUES (
          p_item_id, regime_value, state_value, candidate.valid_from, candidate.cfop, candidate.origin, candidate.benefit_code,
          candidate.icms_cst, candidate.icms_csosn, candidate.icms_rate, candidate.icms_base_reduction, candidate.fcp_rate,
          candidate.st_base_mode, candidate.st_mva, candidate.st_rate, candidate.st_base_reduction, candidate.st_fcp_rate,
          candidate.pis_cst, candidate.pis_rate, candidate.cofins_cst, candidate.cofins_rate, candidate.ibs_cbs_cst,
          candidate.class_trib, candidate.ibs_state_rate, candidate.ibs_city_rate, candidate.cbs_rate, candidate.ibs_cbs_reduction
        );
      END LOOP;
    END LOOP;
  END LOOP;
END;
$$;

-- A importação do Catálogo passa a aceitar a tributação. Item sem o bloco mantém as regras que já tem.
CREATE OR REPLACE FUNCTION app.upsert_catalog_product(p_item jsonb) RETURNS uuid
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  manufacturer_name text := NULLIF(pg_catalog.btrim(p_item ->> 'manufacturer'), '');
  manufacturer uuid;
  codes text[] := ARRAY(
    SELECT DISTINCT pg_catalog.btrim(value)
      FROM pg_catalog.jsonb_array_elements_text(COALESCE(p_item -> 'barcodes', '[]')) AS value
  );
  item_id uuid;
  pmc_item jsonb;
  pmc_state text;
  pmc_region_value text;
  pmc_value numeric;
BEGIN
  IF manufacturer_name IS NOT NULL THEN
    SELECT m.id INTO manufacturer FROM public.catalog_manufacturer m
     WHERE m.name = manufacturer_name AND m.deleted_at IS NULL;
    IF NOT FOUND THEN
      INSERT INTO public.catalog_manufacturer (name) VALUES (manufacturer_name)
      RETURNING id INTO manufacturer;
    END IF;
  END IF;

  INSERT INTO public.catalog_product (
    source_key, name, active_ingredient, manufacturer_id, ms_registration, controlled_class, ncm, cest
  ) VALUES (
    p_item ->> 'sourceKey', pg_catalog.btrim(p_item ->> 'name'),
    NULLIF(pg_catalog.btrim(p_item ->> 'activeIngredient'), ''), manufacturer,
    NULLIF(p_item ->> 'msRegistration', ''), NULLIF(p_item ->> 'controlledClass', ''),
    NULLIF(p_item ->> 'ncm', ''), NULLIF(p_item ->> 'cest', '')
  )
  ON CONFLICT (source_key) WHERE deleted_at IS NULL DO UPDATE
    SET name = EXCLUDED.name,
        active_ingredient = EXCLUDED.active_ingredient,
        manufacturer_id = EXCLUDED.manufacturer_id,
        ms_registration = EXCLUDED.ms_registration,
        controlled_class = EXCLUDED.controlled_class,
        ncm = EXCLUDED.ncm,
        cest = EXCLUDED.cest
    -- Item igual não muda de versão, para não descer de novo aos terminais na Etapa 3.
    WHERE (public.catalog_product.name, public.catalog_product.active_ingredient,
           public.catalog_product.manufacturer_id, public.catalog_product.ms_registration,
           public.catalog_product.controlled_class, public.catalog_product.ncm, public.catalog_product.cest)
          IS DISTINCT FROM
          (EXCLUDED.name, EXCLUDED.active_ingredient, EXCLUDED.manufacturer_id, EXCLUDED.ms_registration,
           EXCLUDED.controlled_class, EXCLUDED.ncm, EXCLUDED.cest)
  RETURNING id INTO item_id;

  IF item_id IS NULL THEN
    SELECT cp.id INTO item_id FROM public.catalog_product cp
     WHERE cp.source_key = p_item ->> 'sourceKey' AND cp.deleted_at IS NULL;
  END IF;

  UPDATE public.catalog_product_barcode cb
     SET deleted_at = pg_catalog.clock_timestamp()
   WHERE cb.catalog_product_id = item_id AND cb.deleted_at IS NULL AND cb.code <> ALL (codes);

  INSERT INTO public.catalog_product_barcode (catalog_product_id, code)
  SELECT item_id, requested.code
    FROM pg_catalog.unnest(codes) AS requested(code)
   WHERE NOT EXISTS (
     SELECT 1 FROM public.catalog_product_barcode cb
      WHERE cb.catalog_product_id = item_id AND cb.code = requested.code AND cb.deleted_at IS NULL
   );

  FOR pmc_item IN SELECT value FROM pg_catalog.jsonb_array_elements(COALESCE(p_item -> 'pmc', '[]')) AS value LOOP
    pmc_state := pmc_item ->> 'state';
    pmc_region_value := NULLIF(pmc_item ->> 'region', '');
    pmc_value := (pmc_item ->> 'value')::numeric;
    IF pmc_value IS DISTINCT FROM (
      SELECT cm.value FROM public.catalog_product_pmc cm
       WHERE cm.catalog_product_id = item_id AND cm.state = pmc_state
         AND cm.pmc_region IS NOT DISTINCT FROM pmc_region_value AND cm.deleted_at IS NULL
       ORDER BY cm.created_at DESC, cm.id DESC LIMIT 1
    ) THEN
      INSERT INTO public.catalog_product_pmc (catalog_product_id, state, pmc_region, value)
      VALUES (item_id, pmc_state, pmc_region_value, pmc_value);
    END IF;
  END LOOP;

  PERFORM app.upsert_catalog_product_taxes(item_id, p_item -> 'taxes');
  RETURN item_id;
END;
$$;

-- Regra que vale para o produto na filial, na data. A falta de regra não é erro: a resposta diz o
-- motivo. Produto ou filial que o usuário não enxerga não devolve linha.
CREATE FUNCTION app.resolve_product_tax(p_product_id uuid, p_branch_id uuid, p_on date DEFAULT NULL)
RETURNS TABLE (
  status text, tax_regime smallint, state text, tax_id uuid, valid_from date, cfop text, origin smallint, benefit_code text,
  icms_cst text, icms_csosn text, icms_rate numeric, icms_base_reduction numeric, fcp_rate numeric, st_base_mode smallint,
  st_mva numeric, st_rate numeric, st_base_reduction numeric, st_fcp_rate numeric, pis_cst text, pis_rate numeric,
  cofins_cst text, cofins_rate numeric, ibs_cbs_cst text, class_trib text, ibs_state_rate numeric, ibs_city_rate numeric,
  cbs_rate numeric, ibs_cbs_reduction numeric
)
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT CASE WHEN p.catalog_product_id IS NULL THEN 'no_catalog'
              WHEN c.tax_regime IS NULL THEN 'no_regime'
              WHEN b.state IS NULL THEN 'no_state'
              WHEN rule.id IS NULL THEN 'no_rule'
              ELSE 'ok' END,
         c.tax_regime, b.state::text, rule.id, rule.valid_from, rule.cfop, rule.origin, rule.benefit_code,
         rule.icms_cst, rule.icms_csosn, rule.icms_rate, rule.icms_base_reduction, rule.fcp_rate, rule.st_base_mode,
         rule.st_mva, rule.st_rate, rule.st_base_reduction, rule.st_fcp_rate, rule.pis_cst, rule.pis_rate,
         rule.cofins_cst, rule.cofins_rate, rule.ibs_cbs_cst, rule.class_trib, rule.ibs_state_rate, rule.ibs_city_rate,
         rule.cbs_rate, rule.ibs_cbs_reduction
    FROM public.product p
    JOIN public.company c ON c.economic_group_id = p.economic_group_id AND c.deleted_at IS NULL
    JOIN public.branch b ON b.company_id = c.id AND b.id = p_branch_id AND b.deleted_at IS NULL
    LEFT JOIN LATERAL (
      SELECT t.* FROM public.catalog_product_tax t
       WHERE t.catalog_product_id = p.catalog_product_id AND t.tax_regime = c.tax_regime AND t.state = b.state
         AND t.valid_from <= COALESCE(p_on, app.local_today()) AND t.deleted_at IS NULL
       ORDER BY t.valid_from DESC
       LIMIT 1
    ) AS rule ON true
   WHERE p.id = p_product_id AND p.deleted_at IS NULL
$$;

-- Quantos produtos que a filial pode vender estão sem tributação hoje. Só totais, para quem vê o
-- Fiscal da filial: essa pessoa pode não ter permissão para consultar os produtos.
CREATE FUNCTION app.tax_coverage()
RETURNS TABLE (branch_id uuid, products_total bigint, products_missing bigint)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT b.id, COUNT(p.id),
         COUNT(p.id) FILTER (WHERE NOT EXISTS (
           SELECT 1 FROM public.catalog_product_tax t
            WHERE t.catalog_product_id = p.catalog_product_id AND t.tax_regime = c.tax_regime AND t.state = b.state
              AND t.valid_from <= app.local_today() AND t.deleted_at IS NULL
         ))
    FROM public.branch b
    JOIN public.company c ON c.id = b.company_id AND c.deleted_at IS NULL
    LEFT JOIN public.product_branch_status s ON s.branch_id = b.id AND s.deleted_at IS NULL AND s.status <> 'inactive'
    LEFT JOIN public.product p ON p.id = s.product_id AND p.deleted_at IS NULL
   WHERE b.deleted_at IS NULL
     AND c.economic_group_id = app.current_user_group()
     AND (app.has_permission('fiscal.view', b.id) OR app.has_permission('fiscal.manage', b.id)
          OR app.has_permission('fiscal.certificate', b.id))
   GROUP BY b.id
$$;

CREATE POLICY catalog_product_tax_select ON catalog_product_tax FOR SELECT TO farmaerp_app
  USING ((SELECT app.current_user_group()) IS NOT NULL);
GRANT SELECT ON catalog_product_tax TO farmaerp_app;

CREATE VIEW v_catalog_product_tax WITH (security_invoker = true) AS
  SELECT * FROM catalog_product_tax WHERE deleted_at IS NULL;
GRANT SELECT ON v_catalog_product_tax TO farmaerp_app;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  app.resolve_product_tax(uuid, uuid, date),
  app.tax_coverage()
TO farmaerp_app;
