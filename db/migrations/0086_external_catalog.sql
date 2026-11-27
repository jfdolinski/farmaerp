-- Up Migration

-- Catálogo externo (catalogo-produtos): a central copia o catálogo completo de hora em hora e
-- consulta na hora o código de barras que a cópia não tem. Cada item vem com a chave
-- "catalogo:{id}". O que vem de lá é a verdade: o item que sumiu do catálogo fica marcado como
-- fora dele (o produto da loja continua vinculado e mostra o aviso), e o item ainda pendente lá
-- (cadastro provisório) aparece na busca, mas não pode ser vinculado. As imagens só são trazidas
-- para os itens vinculados a algum produto, para o banco não guardar as fotos do catálogo inteiro.
-- Só a rotina do Catálogo (app.worker = 'catalog') grava; a Plataforma acompanha.

ALTER TABLE catalog_product
  ADD COLUMN external_pending boolean NOT NULL DEFAULT false,
  ADD COLUMN external_removed_at timestamptz,
  -- Impressão digital do item como veio do catálogo: item igual não é regravado.
  ADD COLUMN external_hash text CONSTRAINT catalog_product_external_hash_check CHECK (external_hash ~ '^[0-9a-f]{64}$'),
  -- Imagens que o item tem lá (endereços, na ordem) e as que já foram trazidas para cá.
  ADD COLUMN external_image_urls text[] CONSTRAINT catalog_product_external_image_urls_check CHECK (
    pg_catalog.cardinality(external_image_urls) <= 20
  ),
  ADD COLUMN external_images_done text[];

CREATE TABLE catalog_sync_run (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  trigger text NOT NULL CONSTRAINT catalog_sync_run_trigger_check CHECK (trigger IN ('schedule', 'manual')),
  status text NOT NULL DEFAULT 'running' CONSTRAINT catalog_sync_run_status_check CHECK (status IN ('running', 'unchanged', 'updated', 'failed')),
  started_at timestamptz NOT NULL DEFAULT now(),
  finished_at timestamptz,
  etag text CONSTRAINT catalog_sync_run_etag_check CHECK (length(etag) <= 200),
  items integer CONSTRAINT catalog_sync_run_items_check CHECK (items >= 0),
  changed integer CONSTRAINT catalog_sync_run_changed_check CHECK (changed >= 0),
  failed integer CONSTRAINT catalog_sync_run_failed_check CHECK (failed >= 0),
  removed integer CONSTRAINT catalog_sync_run_removed_check CHECK (removed >= 0),
  message text CONSTRAINT catalog_sync_run_message_check CHECK (length(message) <= 500),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid,
  CONSTRAINT catalog_sync_run_finished_check CHECK ((status = 'running') = (finished_at IS NULL))
);
CREATE INDEX catalog_sync_run_started_idx ON catalog_sync_run (started_at DESC);
CALL app.apply_table_standard('public.catalog_sync_run');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON catalog_sync_run
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns('trigger', 'deleted_at');
-- A aplicação lê e grava só pelas funções abaixo.
CREATE POLICY catalog_sync_run_select ON catalog_sync_run FOR SELECT TO farmaerp_app USING (false);
CREATE VIEW v_catalog_sync_run WITH (security_invoker = true) AS SELECT * FROM catalog_sync_run WHERE deleted_at IS NULL;
GRANT SELECT ON catalog_sync_run, v_catalog_sync_run TO farmaerp_app;

CREATE FUNCTION app.require_catalog_worker() RETURNS void
LANGUAGE plpgsql STABLE
SET search_path = ''
AS $$
BEGIN
  IF app.current_user_id() IS NOT NULL OR COALESCE(pg_catalog.current_setting('app.worker', true), '') <> 'catalog' THEN
    RAISE EXCEPTION 'Você não tem permissão para esta operação.'
      USING ERRCODE = 'FA002', DETAIL = 'Função da rotina do Catálogo chamada fora dela.';
  END IF;
END;
$$;

-- Começa uma cópia. Devolve a ETag da última cópia boa (para o catálogo responder 304 se nada
-- mudou), ou nada se já há uma cópia em andamento (de menos de 30 minutos).
CREATE FUNCTION app.catalog_sync_start(p_trigger text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  run_id uuid;
BEGIN
  PERFORM app.require_catalog_worker();
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('catalog_sync'));
  -- Cópia que ficou pela metade (a API caiu no meio) vira falha.
  UPDATE public.catalog_sync_run SET status = 'failed', finished_at = pg_catalog.now(), message = 'Interrompida.'
   WHERE status = 'running' AND started_at < pg_catalog.now() - interval '30 minutes';
  IF EXISTS (SELECT 1 FROM public.catalog_sync_run WHERE status = 'running') THEN
    RETURN NULL;
  END IF;
  INSERT INTO public.catalog_sync_run (trigger) VALUES (p_trigger) RETURNING id INTO run_id;
  RETURN pg_catalog.jsonb_build_object(
    'runId', run_id,
    'etag', (SELECT r.etag FROM public.catalog_sync_run r WHERE r.status IN ('updated', 'unchanged') AND r.etag IS NOT NULL
              ORDER BY r.started_at DESC LIMIT 1),
    -- Impressão digital de cada item já copiado: a API só manda o que mudou.
    'hashes', COALESCE((
      SELECT pg_catalog.jsonb_object_agg(cp.source_key, cp.external_hash) FROM public.catalog_product cp
       WHERE cp.source_key LIKE 'catalogo:%' AND cp.deleted_at IS NULL AND cp.external_removed_at IS NULL
    ), '{}'::jsonb)
  );
END;
$$;

-- Grava os itens que vieram do catálogo (já no formato daqui). Valor fora do formato daqui vira
-- vazio, e código de barras inválido fica de fora; o código que passou para outro item sai do item
-- antigo. Item recusado não para os outros: volta na lista de falhas, com o motivo.
CREATE FUNCTION app.catalog_sync_apply(p_items jsonb) RETURNS jsonb
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
             )
       WHERE cp.source_key = item_key AND cp.deleted_at IS NULL;
      changed := changed + 1;
    EXCEPTION WHEN OTHERS THEN
      failures := failures || pg_catalog.jsonb_build_object('sourceKey', item_key, 'reason', pg_catalog.left(SQLERRM, 200));
    END;
  END LOOP;
  RETURN pg_catalog.jsonb_build_object('changed', changed, 'failures', failures);
END;
$$;

-- Fim da cópia. Com a lista completa do catálogo (p_seen), o que não veio fica marcado como fora
-- dele. Sem a lista (catálogo igual, ou falha), nada é marcado.
CREATE FUNCTION app.catalog_sync_finish(p_run_id uuid, p_result jsonb, p_seen text[]) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  gone integer := 0;
  run public.catalog_sync_run;
BEGIN
  PERFORM app.require_catalog_worker();
  IF p_seen IS NOT NULL AND (p_result ->> 'status') = 'updated' THEN
    UPDATE public.catalog_product cp SET external_removed_at = pg_catalog.now()
     WHERE cp.source_key LIKE 'catalogo:%' AND cp.deleted_at IS NULL AND cp.external_removed_at IS NULL
       AND cp.source_key <> ALL (p_seen);
    GET DIAGNOSTICS gone = ROW_COUNT;
  END IF;
  UPDATE public.catalog_sync_run r
     SET status = p_result ->> 'status', finished_at = pg_catalog.now(), etag = pg_catalog.left(p_result ->> 'etag', 200),
         items = (p_result ->> 'items')::integer, changed = (p_result ->> 'changed')::integer,
         failed = (p_result ->> 'failed')::integer, removed = gone, message = pg_catalog.left(p_result ->> 'message', 500)
   WHERE r.id = p_run_id AND r.status = 'running'
  RETURNING * INTO run;
  IF run.id IS NULL THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.' USING ERRCODE = 'FA006', DETAIL = 'catalog_sync_run.';
  END IF;
  RETURN pg_catalog.jsonb_build_object('removed', gone);
END;
$$;

-- Itens vinculados a algum produto cujas imagens daqui não são as de lá. A rotina traz em lotes.
CREATE FUNCTION app.catalog_images_due(p_limit integer DEFAULT 50) RETURNS TABLE (source_key text, urls text[])
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM app.require_catalog_worker();
  RETURN QUERY
    SELECT cp.source_key, cp.external_image_urls
      FROM public.catalog_product cp
     WHERE cp.source_key LIKE 'catalogo:%' AND cp.deleted_at IS NULL AND cp.external_removed_at IS NULL
       AND cp.external_image_urls IS NOT NULL
       AND cp.external_images_done IS DISTINCT FROM cp.external_image_urls
       AND EXISTS (SELECT 1 FROM public.product p WHERE p.catalog_product_id = cp.id AND p.deleted_at IS NULL)
     ORDER BY cp.updated_at, cp.id
     LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 50), 200));
END;
$$;

-- Imagens trazidas de um item (já convertidas): trocam as daqui e o item fica em dia. p_urls é a
-- lista de lá que elas representam (se mudou no meio, o item volta para a fila).
CREATE FUNCTION app.catalog_sync_images(p_source_key text, p_urls text[], p_images jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM app.require_catalog_worker();
  IF p_source_key IS NULL OR p_source_key NOT LIKE 'catalogo:%' THEN
    RAISE EXCEPTION 'Alguns dados informados são inválidos.' USING ERRCODE = 'FA005', DETAIL = 'Item do Catálogo.';
  END IF;
  PERFORM app.set_catalog_product_images(p_source_key, p_images);
  UPDATE public.catalog_product cp SET external_images_done = p_urls
   WHERE cp.source_key = p_source_key AND cp.deleted_at IS NULL;
END;
$$;

-- Situação da cópia, para a Plataforma.
CREATE FUNCTION app.catalog_sync_status() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM app.require_platform_admin();
  RETURN pg_catalog.jsonb_build_object(
    'items', (SELECT pg_catalog.count(*) FROM public.catalog_product cp
               WHERE cp.source_key LIKE 'catalogo:%' AND cp.deleted_at IS NULL AND cp.external_removed_at IS NULL),
    'pending', (SELECT pg_catalog.count(*) FROM public.catalog_product cp
                 WHERE cp.source_key LIKE 'catalogo:%' AND cp.deleted_at IS NULL AND cp.external_removed_at IS NULL AND cp.external_pending),
    'removed', (SELECT pg_catalog.count(*) FROM public.catalog_product cp
                 WHERE cp.source_key LIKE 'catalogo:%' AND cp.deleted_at IS NULL AND cp.external_removed_at IS NOT NULL),
    'imagesDue', (SELECT pg_catalog.count(*) FROM public.catalog_product cp
                   WHERE cp.source_key LIKE 'catalogo:%' AND cp.deleted_at IS NULL AND cp.external_removed_at IS NULL
                     AND cp.external_image_urls IS NOT NULL AND cp.external_images_done IS DISTINCT FROM cp.external_image_urls
                     AND EXISTS (SELECT 1 FROM public.product p WHERE p.catalog_product_id = cp.id AND p.deleted_at IS NULL)),
    'runs', COALESCE((
      SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
               'id', r.id, 'trigger', r.trigger, 'status', r.status, 'startedAt', r.started_at, 'finishedAt', r.finished_at,
               'items', r.items, 'changed', r.changed, 'failed', r.failed, 'removed', r.removed, 'message', r.message)
               ORDER BY r.started_at DESC)
        FROM (SELECT * FROM public.catalog_sync_run ORDER BY started_at DESC LIMIT 10) r
    ), '[]'::jsonb)
  );
END;
$$;

-- Vincular produto a item pendente no catálogo (cadastro provisório) ou que saiu dele não pode.
CREATE FUNCTION app.guard_catalog_link() RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  target public.catalog_product;
BEGIN
  IF NEW.catalog_product_id IS NULL OR (TG_OP = 'UPDATE' AND NEW.catalog_product_id IS NOT DISTINCT FROM OLD.catalog_product_id) THEN
    RETURN NEW;
  END IF;
  SELECT * INTO target FROM public.catalog_product cp WHERE cp.id = NEW.catalog_product_id;
  IF target.external_pending OR target.external_removed_at IS NOT NULL THEN
    RAISE EXCEPTION 'Este item do Catálogo ainda não pode ser vinculado.'
      USING ERRCODE = 'FA226', DETAIL = CASE WHEN target.external_pending THEN 'Pendente no Catálogo.' ELSE 'Fora do Catálogo.' END;
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER guard_catalog_link BEFORE INSERT OR UPDATE OF catalog_product_id ON product
  FOR EACH ROW EXECUTE FUNCTION app.guard_catalog_link();

-- A busca diz se o item está pendente no catálogo; o que saiu dele não aparece mais.
DROP FUNCTION app.search_catalog(text, integer);
CREATE FUNCTION app.search_catalog(p_query text, p_limit integer DEFAULT 20)
RETURNS TABLE (
  id uuid, name text, active_ingredient text, manufacturer text, ms_registration text,
  controlled_class text, ncm text, cest text, barcodes text[], product_id uuid, pending boolean
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
         cp.external_pending
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

REVOKE ALL ON FUNCTION app.require_catalog_worker(), app.catalog_sync_start(text), app.catalog_sync_apply(jsonb),
  app.catalog_sync_finish(uuid, jsonb, text[]), app.catalog_images_due(integer), app.catalog_sync_images(text, text[], jsonb),
  app.catalog_sync_status(), app.guard_catalog_link(), app.search_catalog(text, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.catalog_sync_start(text), app.catalog_sync_apply(jsonb), app.catalog_sync_finish(uuid, jsonb, text[]),
  app.catalog_images_due(integer), app.catalog_sync_images(text, text[], jsonb), app.catalog_sync_status(),
  app.search_catalog(text, integer) TO farmaerp_app;
