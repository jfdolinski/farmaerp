-- Up Migration

-- Imagens do Catálogo. Como o resto do Catálogo, são globais e só mudam pela importação. Chegam
-- já convertidas para WebP em duas versões (até 800 px e até 200 px); o original não fica guardado.

CREATE TABLE catalog_product_image (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  catalog_product_id uuid NOT NULL REFERENCES catalog_product (id),
  sort_order smallint NOT NULL CONSTRAINT catalog_product_image_sort_order_check CHECK (sort_order BETWEEN 1 AND 20),
  is_main boolean NOT NULL DEFAULT false,
  sha256 text NOT NULL CONSTRAINT catalog_product_image_sha256_check CHECK (sha256 ~ '^[0-9a-f]{64}$'),
  width smallint NOT NULL CONSTRAINT catalog_product_image_width_check CHECK (width BETWEEN 1 AND 800),
  height smallint NOT NULL CONSTRAINT catalog_product_image_height_check CHECK (height BETWEEN 1 AND 800),
  full_webp bytea NOT NULL CONSTRAINT catalog_product_image_full_check CHECK (
    octet_length(full_webp) BETWEEN 12 AND 1048576 AND substring(full_webp FROM 1 FOR 4) = '\x52494646'::bytea
    AND substring(full_webp FROM 9 FOR 4) = '\x57454250'::bytea
  ),
  thumb_webp bytea NOT NULL CONSTRAINT catalog_product_image_thumb_check CHECK (
    octet_length(thumb_webp) BETWEEN 12 AND 262144 AND substring(thumb_webp FROM 1 FOR 4) = '\x52494646'::bytea
    AND substring(thumb_webp FROM 9 FOR 4) = '\x57454250'::bytea
  ),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
-- A mesma imagem não entra duas vezes no produto, e só uma é a principal.
CREATE UNIQUE INDEX catalog_product_image_sha256_key
  ON catalog_product_image (catalog_product_id, sha256) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX catalog_product_image_main_key
  ON catalog_product_image (catalog_product_id) WHERE is_main AND deleted_at IS NULL;
CREATE INDEX catalog_product_image_product_idx ON catalog_product_image (catalog_product_id, sort_order) WHERE deleted_at IS NULL;
CALL app.apply_table_standard('public.catalog_product_image');
-- A imagem não muda: outra imagem é outra linha. Só a ordem e a principal mudam.
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON catalog_product_image
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'catalog_product_id', 'sha256', 'width', 'height', 'full_webp', 'thumb_webp'
  );

-- Troca as imagens de um produto do Catálogo pela lista da importação. A lista vem em ordem; a
-- principal é a marcada, ou a primeira. Imagem que saiu da lista sai por exclusão lógica; a que
-- continua só tem a ordem e a principal atualizadas. Roda como dono, pela importação.
CREATE FUNCTION app.set_catalog_product_images(p_source_key text, p_images jsonb) RETURNS void
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  product_id uuid;
  image jsonb;
  ordinal integer := 0;
  main_index integer;
  kept text[] := '{}';
BEGIN
  SELECT cp.id INTO product_id FROM public.catalog_product cp WHERE cp.source_key = p_source_key AND cp.deleted_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Um dos itens informados não foi encontrado.'
      USING ERRCODE = 'FA004', DETAIL = pg_catalog.format('catalog_product %s.', p_source_key);
  END IF;
  IF p_images IS NULL OR pg_catalog.jsonb_typeof(p_images) <> 'array' OR pg_catalog.jsonb_array_length(p_images) > 20 THEN
    RAISE EXCEPTION 'As imagens do Catálogo são inválidas.'
      USING ERRCODE = 'FA955', DETAIL = 'Lista de imagens ausente ou com mais de 20.';
  END IF;
  SELECT COALESCE(pg_catalog.min(entry.ordinality) FILTER (WHERE (entry.value ->> 'main')::boolean), 1)
    INTO main_index
    FROM pg_catalog.jsonb_array_elements(p_images) WITH ORDINALITY AS entry;

  -- A principal anterior deixa de ser, para o índice de uma principal não barrar a troca.
  UPDATE public.catalog_product_image SET is_main = false
   WHERE catalog_product_id = product_id AND deleted_at IS NULL AND is_main;

  FOR image IN SELECT value FROM pg_catalog.jsonb_array_elements(p_images) AS value LOOP
    ordinal := ordinal + 1;
    IF (image ->> 'sha256') = ANY (kept) THEN
      RAISE EXCEPTION 'As imagens do Catálogo são inválidas.'
        USING ERRCODE = 'FA955', DETAIL = pg_catalog.format('Imagem repetida em %s.', p_source_key);
    END IF;
    kept := kept || (image ->> 'sha256');
    UPDATE public.catalog_product_image
       SET sort_order = ordinal, is_main = (ordinal = main_index)
     WHERE catalog_product_id = product_id AND sha256 = image ->> 'sha256' AND deleted_at IS NULL;
    IF NOT FOUND THEN
      INSERT INTO public.catalog_product_image (
        catalog_product_id, sort_order, is_main, sha256, width, height, full_webp, thumb_webp
      ) VALUES (
        product_id, ordinal, ordinal = main_index, image ->> 'sha256', (image ->> 'width')::smallint,
        (image ->> 'height')::smallint, pg_catalog.decode(image ->> 'full', 'base64'),
        pg_catalog.decode(image ->> 'thumb', 'base64')
      );
    END IF;
  END LOOP;

  UPDATE public.catalog_product_image SET deleted_at = pg_catalog.clock_timestamp()
   WHERE catalog_product_id = product_id AND deleted_at IS NULL AND NOT (sha256 = ANY (kept));
END;
$$;

-- Imagens dos produtos do Catálogo informados, sem o conteúdo: para as telas montarem as listas.
CREATE FUNCTION app.catalog_images(p_catalog_product_ids uuid[])
RETURNS TABLE (id uuid, catalog_product_id uuid, sort_order smallint, is_main boolean, width smallint, height smallint, sha256 text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT i.id, i.catalog_product_id, i.sort_order, i.is_main, i.width, i.height, i.sha256
    FROM public.catalog_product_image i
   WHERE i.catalog_product_id = ANY (p_catalog_product_ids) AND i.deleted_at IS NULL
     AND app.current_user_group() IS NOT NULL
   ORDER BY i.catalog_product_id, i.sort_order
$$;

-- O conteúdo de uma imagem, na versão pedida.
CREATE FUNCTION app.catalog_image_content(p_id uuid, p_size text)
RETURNS TABLE (content bytea, sha256 text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT CASE WHEN p_size = 'thumb' THEN i.thumb_webp ELSE i.full_webp END, i.sha256
    FROM public.catalog_product_image i
   WHERE i.id = p_id AND i.deleted_at IS NULL AND p_size IN ('full', 'thumb')
     AND app.current_user_group() IS NOT NULL
$$;

-- Como o resto do Catálogo: qualquer usuário logado lê.
CREATE POLICY catalog_product_image_select ON catalog_product_image FOR SELECT TO farmaerp_app
  USING ((SELECT app.current_user_group()) IS NOT NULL);
GRANT SELECT ON catalog_product_image TO farmaerp_app;
CREATE VIEW v_catalog_product_image WITH (security_invoker = true) AS
  SELECT * FROM catalog_product_image WHERE deleted_at IS NULL;
GRANT SELECT ON v_catalog_product_image TO farmaerp_app;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  app.catalog_images(uuid[]),
  app.catalog_image_content(uuid, text)
TO farmaerp_app;
