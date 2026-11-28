-- Up Migration

-- Marca e departamento do Catálogo externo. O Catálogo manda a marca (brand), o fabricante
-- (manufacturer) e o departamento como "category". Até aqui a marca entrava no lugar do fabricante
-- quando ele faltava; agora cada um fica no seu campo. A marca entra na busca, e a busca e o
-- cadastro do produto mostram os três.

ALTER TABLE catalog_product
  ADD COLUMN brand text CONSTRAINT catalog_product_brand_check CHECK (length(brand) <= 150),
  ADD COLUMN department text CONSTRAINT catalog_product_department_check CHECK (length(department) <= 150);

-- A view repete o SELECT * para passar a ter as colunas novas (as do 0086 e do 0087 também).
CREATE OR REPLACE VIEW v_catalog_product WITH (security_invoker = true) AS
  SELECT * FROM catalog_product WHERE deleted_at IS NULL;

-- Texto de busca do Catálogo: nome, princípio ativo, fabricante e marca.
CREATE OR REPLACE FUNCTION app.set_catalog_search_text() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  NEW.search_text := app.normalize_search(
    pg_catalog.concat_ws(' ', NEW.name, NEW.active_ingredient, (
      SELECT m.name FROM public.catalog_manufacturer m WHERE m.id = NEW.manufacturer_id
    ), NEW.brand)
  );
  RETURN NEW;
END;
$$;

-- O item passa a trazer a marca e o departamento (o resto como no 0087).
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
             tax_origin = CASE WHEN origin ~ '^[0-8]$' THEN origin::smallint END,
             brand = pg_catalog.left(app.clean_text(item ->> 'brand'), 150),
             department = pg_catalog.left(app.clean_text(item ->> 'department'), 150)
       WHERE cp.source_key = item_key AND cp.deleted_at IS NULL;
      changed := changed + 1;
    EXCEPTION WHEN OTHERS THEN
      failures := failures || pg_catalog.jsonb_build_object('sourceKey', item_key, 'reason', pg_catalog.left(SQLERRM, 200));
    END;
  END LOOP;
  RETURN pg_catalog.jsonb_build_object('changed', changed, 'failures', failures);
END;
$$;

-- A busca diz a marca e o departamento.
DROP FUNCTION app.search_catalog(text, integer);
CREATE FUNCTION app.search_catalog(p_query text, p_limit integer DEFAULT 20)
RETURNS TABLE (
  id uuid, name text, active_ingredient text, manufacturer text, ms_registration text,
  controlled_class text, ncm text, cest text, barcodes text[], product_id uuid, pending boolean,
  brand text, department text
)
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  WITH input AS (
    SELECT app.search_patterns(p_query) AS patterns, pg_catalog.btrim(COALESCE(p_query, '')) AS raw
  )
  SELECT cp.id, cp.name, cp.active_ingredient, m.name, cp.ms_registration, cp.controlled_class,
         cp.ncm, cp.cest,
         ARRAY(
           SELECT cb.code FROM public.catalog_product_barcode cb
            WHERE cb.catalog_product_id = cp.id AND cb.deleted_at IS NULL
            ORDER BY cb.code
         ),
         (SELECT p.id FROM public.product p
           WHERE p.catalog_product_id = cp.id AND p.deleted_at IS NULL
             AND p.economic_group_id = app.current_user_group()),
         cp.external_pending, cp.brand, cp.department
    FROM public.catalog_product cp
   CROSS JOIN input
    LEFT JOIN public.catalog_manufacturer m ON m.id = cp.manufacturer_id
   WHERE cp.deleted_at IS NULL AND cp.external_removed_at IS NULL
     AND input.raw <> ''
     AND (
       -- A primeira condição é a que o índice consegue usar.
       (cp.search_text LIKE input.patterns[1] AND cp.search_text LIKE ALL (input.patterns))
       OR EXISTS (
         SELECT 1 FROM public.catalog_product_barcode exact
          WHERE exact.catalog_product_id = cp.id AND exact.code = input.raw AND exact.deleted_at IS NULL
       )
     )
   ORDER BY cp.external_pending, cp.name, cp.id
   LIMIT LEAST(GREATEST(COALESCE(p_limit, 20), 1), 50)
$$;

REVOKE ALL ON FUNCTION app.search_catalog(text, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.search_catalog(text, integer) TO farmaerp_app;
