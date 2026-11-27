-- Up Migration

-- Auditoria do Catálogo no cadastro do produto. Guarda cada interação do produto com o Catálogo:
-- a busca manual (o que foi digitado e quantos itens vieram), a busca automática pelo código de
-- barras (achou ou não) e cada vínculo feito, trocado ou desfeito, com a origem: à mão, pelo código
-- de barras ou pela importação de notas de outro sistema.
-- O vínculo é registrado por gatilho no próprio produto, então nenhum caminho fica de fora.

CREATE TABLE product_catalog_event (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  product_id uuid NOT NULL REFERENCES product (id),
  -- search: busca manual; lookup: busca automática pelo código de barras;
  -- linked/changed/unlinked: o vínculo do produto mudou.
  kind text NOT NULL CONSTRAINT product_catalog_event_kind_check CHECK (kind IN (
    'search', 'lookup', 'linked', 'changed', 'unlinked'
  )),
  source text CONSTRAINT product_catalog_event_source_check CHECK (source IN (
    'manual', 'barcode', 'import'
  )),
  query text CONSTRAINT product_catalog_event_query_check CHECK (length(query) <= 200),
  result_count integer CONSTRAINT product_catalog_event_result_count_check CHECK (result_count >= 0),
  catalog_product_id uuid REFERENCES catalog_product (id),
  previous_catalog_product_id uuid REFERENCES catalog_product (id),
  user_id uuid REFERENCES user_account (id),
  occurred_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid,
  -- Busca tem texto e quantidade; mudança de vínculo tem origem.
  CONSTRAINT product_catalog_event_shape_check CHECK (
    CASE WHEN kind IN ('search', 'lookup')
         THEN query IS NOT NULL AND btrim(query) <> '' AND result_count IS NOT NULL
         ELSE source IS NOT NULL END
  )
);
CREATE INDEX product_catalog_event_product_idx ON product_catalog_event (product_id, occurred_at DESC);
CREATE INDEX product_catalog_event_economic_group_id_idx ON product_catalog_event (economic_group_id);
CREATE INDEX product_catalog_event_catalog_product_id_idx ON product_catalog_event (catalog_product_id);
CREATE INDEX product_catalog_event_previous_catalog_product_id_idx ON product_catalog_event (previous_catalog_product_id);
CREATE INDEX product_catalog_event_user_id_idx ON product_catalog_event (user_id);
CALL app.apply_table_standard('public.product_catalog_event');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON product_catalog_event
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'product_id', 'kind', 'source', 'query', 'result_count', 'catalog_product_id',
    'previous_catalog_product_id', 'user_id', 'occurred_at', 'deleted_at'
  );
CREATE POLICY product_catalog_event_select ON product_catalog_event FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group())
         AND (SELECT app.has_permission_anywhere('products.view')
                  OR app.has_permission_anywhere('products.manage')));
CREATE VIEW v_product_catalog_event WITH (security_invoker = true) AS
  SELECT * FROM product_catalog_event WHERE deleted_at IS NULL;
GRANT SELECT ON product_catalog_event, v_product_catalog_event TO farmaerp_app;

-- Origem do vínculo. O serviço de importação de notas (NFC-e e NF-e de outro sistema) cria o produto já
-- vinculado pelo GTIN, sem ninguém escolher o item; nos cadastros à mão, a tela informa se o item veio
-- da busca automática pelo código de barras.
CREATE FUNCTION app.catalog_source() RETURNS text
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT CASE WHEN COALESCE(pg_catalog.current_setting('app.worker', true), '') = 'import' THEN 'import'
              WHEN pg_catalog.current_setting('app.catalog_source', true) = 'barcode' THEN 'barcode'
              ELSE 'manual' END
$$;

CREATE FUNCTION app.log_product_catalog_link() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  previous uuid := CASE WHEN TG_OP = 'UPDATE' THEN OLD.catalog_product_id END;
  lookup jsonb;
BEGIN
  IF NEW.catalog_product_id IS NOT DISTINCT FROM previous THEN
    RETURN NULL;
  END IF;
  -- Cadastro novo: a busca que levou ao item vem antes do vínculo.
  IF TG_OP = 'INSERT' THEN
    lookup := NULLIF(pg_catalog.current_setting('app.catalog_lookup', true), '')::jsonb;
    IF lookup IS NOT NULL THEN
      -- Na automática, o item achado é o próprio item vinculado.
      INSERT INTO public.product_catalog_event (
        economic_group_id, product_id, kind, query, result_count, catalog_product_id, user_id
      ) VALUES (
        NEW.economic_group_id, NEW.id,
        CASE WHEN lookup ->> 'kind' = 'lookup' THEN 'lookup' ELSE 'search' END,
        pg_catalog.left(pg_catalog.btrim(lookup ->> 'query'), 200),
        GREATEST((lookup ->> 'resultCount')::integer, 0),
        CASE WHEN lookup ->> 'kind' = 'lookup' THEN NEW.catalog_product_id END,
        app.current_user_id()
      );
    END IF;
  END IF;
  INSERT INTO public.product_catalog_event (
    economic_group_id, product_id, kind, source, catalog_product_id, previous_catalog_product_id, user_id
  ) VALUES (
    NEW.economic_group_id, NEW.id,
    CASE WHEN NEW.catalog_product_id IS NULL THEN 'unlinked'
         WHEN previous IS NULL THEN 'linked'
         ELSE 'changed' END,
    app.catalog_source(), NEW.catalog_product_id, previous, app.current_user_id()
  );
  RETURN NULL;
END;
$$;

CREATE TRIGGER log_product_catalog_link AFTER INSERT OR UPDATE OF catalog_product_id ON product
  FOR EACH ROW EXECUTE FUNCTION app.log_product_catalog_link();

/*
 * Registra a busca feita na tela do produto. A automática (pelo código de barras) roda a cada
 * abertura da tela, então só entra quando o resultado mudou desde a última igual nas últimas 24 horas.
 */
CREATE FUNCTION app.record_catalog_search(
  p_product_id uuid, p_kind text, p_query text, p_result_count integer, p_catalog_product_id uuid DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.require_products_manage();
  clean text := pg_catalog.left(pg_catalog.btrim(COALESCE(p_query, '')), 200);
BEGIN
  IF p_kind NOT IN ('search', 'lookup') OR clean = '' OR p_result_count IS NULL OR p_result_count < 0 THEN
    RAISE EXCEPTION 'Alguns dados informados são inválidos.'
      USING ERRCODE = 'FA005', DETAIL = 'record_catalog_search com dados inválidos.';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.product p
     WHERE p.id = p_product_id AND p.economic_group_id = group_id AND p.deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('product %s.', p_product_id);
  END IF;
  IF p_kind = 'lookup' AND EXISTS (
    SELECT 1 FROM public.product_catalog_event e
     WHERE e.product_id = p_product_id AND e.kind = 'lookup' AND e.query = clean
       AND e.result_count = p_result_count
       AND e.catalog_product_id IS NOT DISTINCT FROM p_catalog_product_id
       AND e.occurred_at > now() - interval '24 hours' AND e.deleted_at IS NULL
  ) THEN
    RETURN;
  END IF;
  INSERT INTO public.product_catalog_event (
    economic_group_id, product_id, kind, query, result_count, catalog_product_id, user_id
  ) VALUES (group_id, p_product_id, p_kind, clean, p_result_count, p_catalog_product_id, app.current_user_id());
END;
$$;

-- Histórico do produto com os nomes, do mais novo para o mais antigo.
CREATE FUNCTION app.product_catalog_history(p_product_id uuid)
RETURNS TABLE (
  id uuid, kind text, source text, query text, result_count integer,
  catalog_name text, previous_catalog_name text, user_name text, occurred_at timestamptz
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT e.id, e.kind, e.source, e.query, e.result_count, cp.name, prev.name, u.name, e.occurred_at
    FROM public.product_catalog_event e
    JOIN public.product p ON p.id = e.product_id
    LEFT JOIN public.catalog_product cp ON cp.id = e.catalog_product_id
    LEFT JOIN public.catalog_product prev ON prev.id = e.previous_catalog_product_id
    LEFT JOIN public.user_account u ON u.id = e.user_id
   WHERE e.product_id = p_product_id AND e.deleted_at IS NULL
     AND p.economic_group_id = app.current_user_group()
     AND (app.has_permission_anywhere('products.view') OR app.has_permission_anywhere('products.manage'))
   ORDER BY e.occurred_at DESC, e.id DESC
   LIMIT 500
$$;

-- Cadastro e alteração: iguais aos da 0077, mais a origem do vínculo (e, no cadastro, a busca que levou ao item).
CREATE OR REPLACE FUNCTION app.create_product(p_data jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.require_products_manage();
  catalog_id uuid := (p_data ->> 'catalogProductId')::uuid;
  primary_code text := pg_catalog.btrim(p_data ->> 'barcode');
  lookup jsonb := p_data -> 'catalogLookup';
  new_id uuid;
BEGIN
  PERFORM pg_catalog.set_config('app.catalog_source', COALESCE(p_data ->> 'catalogSource', ''), true);
  PERFORM pg_catalog.set_config('app.catalog_lookup',
    CASE WHEN pg_catalog.jsonb_typeof(lookup) = 'object'
              AND NULLIF(pg_catalog.btrim(lookup ->> 'query'), '') IS NOT NULL
              AND pg_catalog.jsonb_typeof(lookup -> 'resultCount') = 'number'
         THEN lookup::text ELSE '' END, true);
  INSERT INTO public.product (
    economic_group_id, catalog_product_id, display_name, own_manufacturer, category_id,
    commission_group_id, pricing_group_id, price_family_id, uses_pmc, online_sale_blocked,
    fraction_quantity, unit
  ) VALUES (
    group_id, catalog_id, pg_catalog.btrim(p_data ->> 'displayName'),
    CASE WHEN catalog_id IS NULL THEN NULLIF(pg_catalog.btrim(p_data ->> 'ownManufacturer'), '') END,
    (p_data ->> 'categoryId')::uuid, (p_data ->> 'commissionGroupId')::uuid,
    (p_data ->> 'pricingGroupId')::uuid, (p_data ->> 'priceFamilyId')::uuid,
    COALESCE((p_data ->> 'usesPmc')::boolean, false),
    COALESCE((p_data ->> 'onlineSaleBlocked')::boolean, false),
    COALESCE((p_data ->> 'fractionQuantity')::numeric, 1),
    app.product_unit_from(p_data, NULL)
  ) RETURNING id INTO new_id;
  PERFORM pg_catalog.set_config('app.catalog_source', '', true);
  PERFORM pg_catalog.set_config('app.catalog_lookup', '', true);

  IF NULLIF(primary_code, '') IS NULL THEN
    RAISE EXCEPTION 'O produto precisa ter um código de barras principal.'
      USING ERRCODE = 'FA603', DETAIL = 'create_product sem código.';
  END IF;

  PERFORM app.insert_product_barcode(
    group_id, new_id, primary_code, (p_data ->> 'barcodeIsInternal')::boolean, true,
    true, true, NULL, NULL
  );

  IF catalog_id IS NOT NULL THEN
    INSERT INTO public.product_barcode (economic_group_id, product_id, code)
    SELECT group_id, new_id, cb.code
      FROM public.catalog_product_barcode cb
     WHERE cb.catalog_product_id = catalog_id AND cb.deleted_at IS NULL
    ON CONFLICT (economic_group_id, code) WHERE deleted_at IS NULL DO NOTHING;
  END IF;
  RETURN new_id;
END;
$$;

CREATE OR REPLACE FUNCTION app.update_product(p_product_id uuid, p_data jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.require_products_manage();
  catalog_id uuid := (p_data ->> 'catalogProductId')::uuid;
BEGIN
  PERFORM pg_catalog.set_config('app.catalog_source', COALESCE(p_data ->> 'catalogSource', ''), true);
  UPDATE public.product p
     SET catalog_product_id = catalog_id,
         display_name = pg_catalog.btrim(p_data ->> 'displayName'),
         own_manufacturer = CASE WHEN catalog_id IS NULL
                                 THEN NULLIF(pg_catalog.btrim(p_data ->> 'ownManufacturer'), '') END,
         category_id = (p_data ->> 'categoryId')::uuid,
         commission_group_id = (p_data ->> 'commissionGroupId')::uuid,
         pricing_group_id = (p_data ->> 'pricingGroupId')::uuid,
         price_family_id = (p_data ->> 'priceFamilyId')::uuid,
         uses_pmc = COALESCE((p_data ->> 'usesPmc')::boolean, false),
         online_sale_blocked = COALESCE((p_data ->> 'onlineSaleBlocked')::boolean, false),
         fraction_quantity = COALESCE((p_data ->> 'fractionQuantity')::numeric, 1),
         unit = app.product_unit_from(p_data, p.unit)
   WHERE p.id = p_product_id AND p.economic_group_id = group_id AND p.deleted_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('product %s.', p_product_id);
  END IF;
  PERFORM pg_catalog.set_config('app.catalog_source', '', true);
END;
$$;

REVOKE ALL ON FUNCTION app.catalog_source(), app.log_product_catalog_link(),
  app.record_catalog_search(uuid, text, text, integer, uuid), app.product_catalog_history(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.record_catalog_search(uuid, text, text, integer, uuid),
  app.product_catalog_history(uuid) TO farmaerp_app;

