-- Up Migration

-- Tributação vinda do Catálogo externo (C2). Para cada item do Catálogo vinculado a algum produto e
-- cada estado onde o grupo do produto tem filial com chave do Catálogo, a rotina busca a tributação
-- daquele estado (com a chave de uma filial dali) e grava na tributação do Catálogo daqui, que já é
-- a fonte do caixa, da NFC-e e da NF-e. Renova todo dia e na hora em que o item muda lá.
-- O Catálogo guarda um só código de ICMS por regra: CSOSN (3 dígitos, Simples e MEI) ou CST (2
-- dígitos, regime normal). O outro regime recebe o código convertido por uma tabela fixa (a
-- conferir com o contador). A origem do produto vem do item do Catálogo.

ALTER TABLE catalog_product
  ADD COLUMN tax_origin smallint CONSTRAINT catalog_product_origin_check CHECK (tax_origin BETWEEN 0 AND 8);

-- O item passa a trazer a origem (o resto como no 0086).
CREATE OR REPLACE FUNCTION app.catalog_sync_apply(p_items jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  item jsonb;
  item_key text;
  codes text[];
  ms text;
  ncm text;
  cest text;
  controlled text;
  origin text;
  changed integer := 0;
  failures jsonb := '[]'::jsonb;
BEGIN
  PERFORM app.require_catalog_worker();
  IF pg_catalog.jsonb_typeof(p_items) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'Alguns dados informados são inválidos.' USING ERRCODE = 'FA005', DETAIL = 'Itens do Catálogo.';
  END IF;
  FOR item IN SELECT value FROM pg_catalog.jsonb_array_elements(p_items) AS value LOOP
    item_key := item ->> 'sourceKey';
    BEGIN
      -- Item sem nome é recusado pela própria tabela do Catálogo.
      IF item_key IS NULL OR item_key !~ '^catalogo:[0-9]{1,12}$' THEN
        RAISE EXCEPTION 'Alguns dados informados são inválidos.' USING ERRCODE = 'FA005', DETAIL = 'Item sem a chave do catálogo externo.';
      END IF;
      codes := ARRAY(
        SELECT DISTINCT pg_catalog.btrim(value) FROM pg_catalog.jsonb_array_elements_text(COALESCE(item -> 'barcodes', '[]')) AS value
         WHERE app.is_valid_gtin(pg_catalog.btrim(value))
      );
      ms := app.clean_digits(item ->> 'msRegistration');
      ncm := app.clean_digits(item ->> 'ncm');
      cest := app.clean_digits(item ->> 'cest');
      origin := pg_catalog.btrim(item ->> 'origin');
      controlled := CASE WHEN pg_catalog.lower(pg_catalog.btrim(item ->> 'controlledClass')) = 'antimicrobiano' THEN 'antimicrobial'
                         ELSE pg_catalog.upper(pg_catalog.btrim(item ->> 'controlledClass')) END;
      -- O código que agora é de outro item sai do antigo (o catálogo juntou ou corrigiu cadastros).
      UPDATE public.catalog_product_barcode cb SET deleted_at = pg_catalog.clock_timestamp()
        FROM public.catalog_product other
       WHERE other.id = cb.catalog_product_id AND other.source_key <> item_key
         AND cb.code = ANY (codes) AND cb.deleted_at IS NULL;
      PERFORM app.upsert_catalog_product(pg_catalog.jsonb_build_object(
        'sourceKey', item_key,
        'name', pg_catalog.left(app.clean_text(item ->> 'name'), 300),
        'manufacturer', pg_catalog.left(app.clean_text(item ->> 'manufacturer'), 150),
        'activeIngredient', pg_catalog.left(app.clean_text(item ->> 'activeIngredient'), 500),
        'msRegistration', CASE WHEN ms ~ '^[0-9]{9,13}$' THEN ms END,
        'controlledClass', CASE WHEN controlled IN ('A1', 'A2', 'A3', 'B1', 'B2', 'C1', 'C2', 'C3', 'C4', 'C5', 'D1', 'antimicrobial')
                                THEN controlled END,
        'ncm', CASE WHEN ncm ~ '^[0-9]{8}$' THEN ncm END,
        'cest', CASE WHEN cest ~ '^[0-9]{7}$' THEN cest END,
        'barcodes', pg_catalog.to_jsonb(codes)
      ));
      UPDATE public.catalog_product cp
         SET external_pending = COALESCE((item ->> 'pending')::boolean, false),
             external_removed_at = NULL,
             external_hash = item ->> 'hash',
             external_image_urls = ARRAY(
               SELECT value FROM pg_catalog.jsonb_array_elements_text(COALESCE(item -> 'images', '[]')) WITH ORDINALITY AS i(value, n)
                ORDER BY n LIMIT 20
             ),
             tax_origin = CASE WHEN origin ~ '^[0-8]$' THEN origin::smallint END
       WHERE cp.source_key = item_key AND cp.deleted_at IS NULL;
      changed := changed + 1;
    EXCEPTION WHEN OTHERS THEN
      failures := failures || pg_catalog.jsonb_build_object('sourceKey', item_key, 'reason', pg_catalog.left(SQLERRM, 200));
    END;
  END LOOP;
  RETURN pg_catalog.jsonb_build_object('changed', changed, 'failures', failures);
END;
$$;

-- Última busca da tributação de cada item em cada estado: quando foi, com a impressão digital do
-- item naquela hora, o resultado e a filial cuja chave foi usada.
CREATE TABLE catalog_tax_fetch (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  catalog_product_id uuid NOT NULL REFERENCES catalog_product (id),
  state char(2) NOT NULL CONSTRAINT catalog_tax_fetch_state_check CHECK (state IN (
    'AC', 'AL', 'AM', 'AP', 'BA', 'CE', 'DF', 'ES', 'GO', 'MA', 'MG', 'MS', 'MT', 'PA', 'PB', 'PE', 'PI',
    'PR', 'RJ', 'RN', 'RO', 'RR', 'RS', 'SC', 'SE', 'SP', 'TO'
  )),
  branch_id uuid NOT NULL REFERENCES branch (id),
  fetched_at timestamptz NOT NULL DEFAULT now(),
  item_hash text CONSTRAINT catalog_tax_fetch_item_hash_check CHECK (item_hash ~ '^[0-9a-f]{64}$'),
  -- ok: gravada; no_rule: o Catálogo não tem regra para o NCM no estado; incomplete: faltou dado
  -- (CFOP de venda, PIS/COFINS, origem); not_found: o item não está mais lá; failed: sem resposta.
  status text NOT NULL CONSTRAINT catalog_tax_fetch_status_check CHECK (status IN ('ok', 'no_rule', 'incomplete', 'not_found', 'failed')),
  -- Código de ICMS que veio do Catálogo (o outro regime recebe o convertido).
  source_icms_code text CONSTRAINT catalog_tax_fetch_source_icms_check CHECK (source_icms_code ~ '^[0-9]{2,3}$'),
  message text CONSTRAINT catalog_tax_fetch_message_check CHECK (length(message) <= 500),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE UNIQUE INDEX catalog_tax_fetch_item_state_key ON catalog_tax_fetch (catalog_product_id, state) WHERE deleted_at IS NULL;
CREATE INDEX catalog_tax_fetch_branch_idx ON catalog_tax_fetch (branch_id);
CREATE INDEX catalog_tax_fetch_fetched_idx ON catalog_tax_fetch (fetched_at);
CALL app.apply_table_standard('public.catalog_tax_fetch');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON catalog_tax_fetch
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns('catalog_product_id', 'state', 'deleted_at');
-- A aplicação lê e grava só pelas funções abaixo.
CREATE POLICY catalog_tax_fetch_select ON catalog_tax_fetch FOR SELECT TO farmaerp_app USING (false);
CREATE VIEW v_catalog_tax_fetch WITH (security_invoker = true) AS SELECT * FROM catalog_tax_fetch WHERE deleted_at IS NULL;
GRANT SELECT ON catalog_tax_fetch, v_catalog_tax_fetch TO farmaerp_app;

-- Código de ICMS do outro regime: CST (regime normal) vira CSOSN (Simples) e vice-versa. Tabela
-- fixa, a conferir com o contador. Código fora da tabela não tem correspondente (nulo).
CREATE FUNCTION app.convert_icms_code(p_code text) RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$
  SELECT CASE p_code
    -- CST -> CSOSN
    WHEN '00' THEN '102' WHEN '10' THEN '202' WHEN '20' THEN '102' WHEN '30' THEN '203' WHEN '40' THEN '300'
    WHEN '41' THEN '400' WHEN '50' THEN '400' WHEN '51' THEN '900' WHEN '60' THEN '500' WHEN '70' THEN '202'
    WHEN '90' THEN '900'
    -- CSOSN -> CST
    WHEN '101' THEN '00' WHEN '102' THEN '00' WHEN '103' THEN '40' WHEN '201' THEN '10' WHEN '202' THEN '10'
    WHEN '203' THEN '30' WHEN '300' THEN '41' WHEN '400' THEN '41' WHEN '500' THEN '60' WHEN '900' THEN '90'
  END
$$;

-- Itens e estados cuja tributação precisa ser buscada: vinculados a algum produto de um grupo que
-- tem filial com chave naquele estado, nunca buscados, buscados antes da última mudança do item, ou
-- há mais de um dia. A chave usada é a da filial mais antiga do grupo naquele estado.
CREATE FUNCTION app.catalog_tax_due(p_limit integer DEFAULT 200) RETURNS TABLE (
  catalog_product_id uuid, external_id text, state text, branch_id uuid, encrypted_key bytea, item_hash text
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM app.require_catalog_worker();
  RETURN QUERY
    WITH pairs AS (
      SELECT DISTINCT ON (cp.id, b.state)
             cp.id AS item_id, pg_catalog.substr(cp.source_key, 10) AS external, b.state::text AS uf, b.id AS key_branch,
             k.encrypted_key AS key_value, cp.external_hash AS hash
        FROM public.catalog_product cp
        JOIN public.product p ON p.catalog_product_id = cp.id AND p.deleted_at IS NULL
        JOIN public.company c ON c.economic_group_id = p.economic_group_id AND c.deleted_at IS NULL
        JOIN public.branch b ON b.company_id = c.id AND b.deleted_at IS NULL AND b.state IS NOT NULL
        JOIN public.branch_catalog_key k ON k.branch_id = b.id AND k.deleted_at IS NULL
       WHERE cp.source_key LIKE 'catalogo:%' AND cp.deleted_at IS NULL AND cp.external_removed_at IS NULL
         AND NOT cp.external_pending
       ORDER BY cp.id, b.state, b.created_at, b.id
    )
    SELECT pairs.item_id, pairs.external, pairs.uf, pairs.key_branch, pairs.key_value, pairs.hash
      FROM pairs
      LEFT JOIN public.catalog_tax_fetch f ON f.catalog_product_id = pairs.item_id AND f.state = pairs.uf AND f.deleted_at IS NULL
     WHERE f.id IS NULL OR f.item_hash IS DISTINCT FROM pairs.hash
        OR f.fetched_at < pg_catalog.now() - interval '23 hours'
     ORDER BY f.fetched_at NULLS FIRST, pairs.item_id, pairs.uf
     LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 200), 1000));
END;
$$;

-- Resultado da busca de um item num estado. p_result: {status: ok|not_found|failed, message,
-- values: {cfop, cst_icms, icms_rate, ...} como o Catálogo devolve}. Com valores, monta a regra dos
-- dois grupos de regime (o código do Catálogo e o convertido) e grava; o que não fecha vira
-- "incomplete" com o motivo, e a regra anterior continua valendo.
CREATE FUNCTION app.catalog_tax_apply(p_item_id uuid, p_state text, p_branch_id uuid, p_hash text, p_result jsonb) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  item public.catalog_product;
  v jsonb := COALESCE(p_result -> 'values', '{}'::jsonb);
  status text := p_result ->> 'status';
  message text := pg_catalog.left(p_result ->> 'message', 500);
  code text := app.clean_digits(v ->> 'cst_icms');
  other text;
  cst text;
  csosn text;
  base jsonb;
  reform jsonb;
  reduction text;
BEGIN
  PERFORM app.require_catalog_worker();
  SELECT * INTO item FROM public.catalog_product cp WHERE cp.id = p_item_id AND cp.deleted_at IS NULL;
  IF item.id IS NULL OR status NOT IN ('ok', 'not_found', 'failed') THEN
    RAISE EXCEPTION 'Alguns dados informados são inválidos.' USING ERRCODE = 'FA005', DETAIL = 'Tributação do Catálogo.';
  END IF;
  IF status = 'ok' THEN
    IF code IS NULL AND app.clean_digits(v ->> 'cfop') IS NULL THEN
      status := 'no_rule';
      message := 'O Catálogo não tem regra de ICMS para o NCM deste item neste estado.';
    ELSIF code IS NULL OR code !~ '^[0-9]{2,3}$' OR app.convert_icms_code(code) IS NULL THEN
      status := 'incomplete';
      message := pg_catalog.format('Código de ICMS do Catálogo fora da tabela: %s.', COALESCE(code, 'vazio'));
    ELSIF COALESCE(app.clean_digits(v ->> 'cfop'), '') !~ '^5[0-9]{3}$' THEN
      status := 'incomplete';
      message := pg_catalog.format('O Catálogo não tem CFOP de venda dentro do estado (veio %s).', COALESCE(v ->> 'cfop', 'vazio'));
    ELSIF app.clean_digits(v ->> 'cst_pis') IS NULL OR app.clean_digits(v ->> 'cst_cofins') IS NULL THEN
      status := 'incomplete';
      message := 'O Catálogo não tem o CST do PIS e do COFINS deste item.';
    ELSIF item.tax_origin IS NULL THEN
      status := 'incomplete';
      message := 'O item não tem a origem (0 a 8) no Catálogo.';
    ELSE
      other := app.convert_icms_code(code);
      cst := CASE WHEN pg_catalog.length(code) = 2 THEN code ELSE other END;
      csosn := CASE WHEN pg_catalog.length(code) = 3 THEN code ELSE other END;
      -- As reduções do IBS e da CBS são uma só aqui: vale quando as do Catálogo são iguais.
      SELECT CASE WHEN pg_catalog.count(DISTINCT r) = 1 THEN pg_catalog.min(r) END INTO reduction
        FROM pg_catalog.unnest(ARRAY[NULLIF(v ->> 'ibs_uf_reduction', ''), NULLIF(v ->> 'ibs_mun_reduction', ''),
                                     NULLIF(v ->> 'cbs_reduction', '')]) AS r WHERE r IS NOT NULL;
      -- IBS/CBS só entra com o grupo completo (CST, classificação e as três alíquotas); faltando parte,
      -- a regra segue sem ele (a reforma fica desligada por empresa até o contador confirmar).
      reform := pg_catalog.jsonb_strip_nulls(pg_catalog.jsonb_build_object(
        'ibsCbsCst', app.clean_digits(v ->> 'cst_ibs_cbs'), 'classTrib', app.clean_digits(v ->> 'c_class_trib'),
        'ibsStateRate', NULLIF(v ->> 'ibs_uf_rate', ''), 'ibsCityRate', NULLIF(v ->> 'ibs_mun_rate', ''),
        'cbsRate', NULLIF(v ->> 'cbs_rate', ''), 'ibsCbsReduction', reduction
      ));
      IF NOT (reform ?& ARRAY['ibsCbsCst', 'classTrib', 'ibsStateRate', 'ibsCityRate', 'cbsRate']) THEN
        reform := '{}'::jsonb;
      END IF;
      base := pg_catalog.jsonb_strip_nulls(pg_catalog.jsonb_build_object(
        'states', pg_catalog.jsonb_build_array(p_state), 'validFrom', app.local_today(),
        'cfop', app.clean_digits(v ->> 'cfop'), 'origin', item.tax_origin,
        'icmsRate', NULLIF(v ->> 'icms_rate', ''), 'icmsBaseReduction', NULLIF(v ->> 'icms_reduction', ''),
        'fcpRate', NULLIF(v ->> 'fcp_rate', ''),
        'stBaseMode', CASE WHEN NULLIF(v ->> 'mva', '') IS NOT NULL THEN 4 END,
        'stMva', NULLIF(v ->> 'mva', ''), 'stRate', NULLIF(v ->> 'icms_st_rate', ''),
        'pisCst', app.clean_digits(v ->> 'cst_pis'), 'pisRate', NULLIF(v ->> 'pis_rate', ''),
        'cofinsCst', app.clean_digits(v ->> 'cst_cofins'), 'cofinsRate', NULLIF(v ->> 'cofins_rate', '')
      )) || reform;
      BEGIN
        PERFORM app.upsert_catalog_product_taxes(item.id, pg_catalog.jsonb_build_array(
          base || pg_catalog.jsonb_build_object('regimes', pg_catalog.jsonb_build_array(2, 3), 'icmsCst', cst),
          base || pg_catalog.jsonb_build_object('regimes', pg_catalog.jsonb_build_array(1, 4), 'icmsCsosn', csosn)
        ));
        message := NULL;
      EXCEPTION WHEN OTHERS THEN
        status := 'incomplete';
        message := pg_catalog.left('A tributação do Catálogo não fecha com as regras daqui: ' || SQLERRM, 500);
      END;
    END IF;
  END IF;
  INSERT INTO public.catalog_tax_fetch AS f (catalog_product_id, state, branch_id, fetched_at, item_hash, status, source_icms_code, message)
  VALUES (item.id, p_state, p_branch_id, pg_catalog.now(), p_hash, status, CASE WHEN code ~ '^[0-9]{2,3}$' THEN code END, message)
  ON CONFLICT (catalog_product_id, state) WHERE deleted_at IS NULL DO UPDATE
     SET branch_id = EXCLUDED.branch_id, fetched_at = EXCLUDED.fetched_at, item_hash = EXCLUDED.item_hash, status = EXCLUDED.status,
         source_icms_code = EXCLUDED.source_icms_code, message = EXCLUDED.message;
  RETURN status;
END;
$$;

-- Itens do grupo com problema na tributação do Catálogo, por filial (para a aba Tributação).
CREATE FUNCTION app.catalog_tax_problems(p_branch_id uuid) RETURNS TABLE (
  product_id uuid, product_code bigint, product_name text, status text, message text, fetched_at timestamptz
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT p.id, p.code, p.display_name, f.status, f.message, f.fetched_at
    FROM public.branch b
    JOIN public.company c ON c.id = b.company_id
    JOIN public.product p ON p.economic_group_id = c.economic_group_id AND p.deleted_at IS NULL
    JOIN public.catalog_tax_fetch f ON f.catalog_product_id = p.catalog_product_id AND f.state = b.state AND f.deleted_at IS NULL
   -- A permissão já é só da filial do grupo do usuário.
   WHERE b.id = p_branch_id AND b.deleted_at IS NULL
     AND app.has_permission('fiscal.view', b.id) AND f.status <> 'ok'
   ORDER BY p.display_name, p.id
   LIMIT 200
$$;

-- A cobertura por filial ganha a situação da busca no Catálogo.
DROP FUNCTION app.tax_coverage();
CREATE FUNCTION app.tax_coverage()
RETURNS TABLE (branch_id uuid, products_total bigint, products_missing bigint, catalog_waiting bigint, catalog_problems bigint, has_catalog_key boolean)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT b.id, COUNT(p.id),
         COUNT(p.id) FILTER (WHERE NOT EXISTS (
           SELECT 1 FROM public.catalog_product_tax t
            WHERE t.catalog_product_id = p.catalog_product_id AND t.tax_regime = c.tax_regime AND t.state = b.state
              AND t.valid_from <= app.local_today() AND t.deleted_at IS NULL
         )),
         -- Vinculados ao Catálogo e ainda sem a primeira busca neste estado.
         COUNT(p.id) FILTER (WHERE p.catalog_product_id IS NOT NULL AND NOT EXISTS (
           SELECT 1 FROM public.catalog_tax_fetch f
            WHERE f.catalog_product_id = p.catalog_product_id AND f.state = b.state AND f.deleted_at IS NULL
         )),
         COUNT(p.id) FILTER (WHERE EXISTS (
           SELECT 1 FROM public.catalog_tax_fetch f
            WHERE f.catalog_product_id = p.catalog_product_id AND f.state = b.state AND f.deleted_at IS NULL AND f.status <> 'ok'
         )),
         EXISTS (SELECT 1 FROM public.branch_catalog_key k WHERE k.branch_id = b.id AND k.deleted_at IS NULL)
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

REVOKE ALL ON FUNCTION app.convert_icms_code(text), app.catalog_tax_due(integer), app.catalog_tax_apply(uuid, text, uuid, text, jsonb),
  app.catalog_tax_problems(uuid), app.tax_coverage() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.catalog_tax_due(integer), app.catalog_tax_apply(uuid, text, uuid, text, jsonb),
  app.catalog_tax_problems(uuid), app.tax_coverage() TO farmaerp_app;
