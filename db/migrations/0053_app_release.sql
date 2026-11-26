-- Up Migration

-- Distribuição e atualização automática do PDV (parte central).
-- Cada versão publicada é da plataforma (igual para todos os clientes): o CI envia o pacote e a
-- assinatura feita com a chave que só ele tem; o PDV confere a assinatura antes de instalar.
-- A liberação é gradual: a versão nasce só para os terminais de teste; o administrador da
-- plataforma libera para a rede ou retira. Cada cliente marca quais terminais dele são de teste.
-- O terminal informa o que fez (baixou, aplicou, voltou à versão anterior) e não recebe de novo
-- uma versão que precisou desfazer.

CREATE TABLE app_release (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  app text NOT NULL CONSTRAINT app_release_app_check CHECK (app IN ('pdv')),
  platform text NOT NULL CONSTRAINT app_release_platform_check CHECK (platform IN ('windows', 'linux')),
  app_version text NOT NULL CONSTRAINT app_release_version_check CHECK (app_version ~ '^[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}$'),
  file_name text NOT NULL CONSTRAINT app_release_file_name_check CHECK (file_name ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,119}$' AND file_name NOT LIKE '%..%'),
  size_bytes bigint NOT NULL CONSTRAINT app_release_size_check CHECK (size_bytes > 0),
  sha256 text NOT NULL CONSTRAINT app_release_sha256_check CHECK (sha256 ~ '^[0-9a-f]{64}$'),
  signature text NOT NULL CONSTRAINT app_release_signature_check CHECK (signature ~ '^[A-Za-z0-9+/]{86}==$'),
  notes text CONSTRAINT app_release_notes_check CHECK (length(notes) <= 2000),
  status text NOT NULL DEFAULT 'test' CONSTRAINT app_release_status_check CHECK (status IN ('test', 'general', 'withdrawn')),
  released_at timestamptz,
  withdrawn_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid,
  CONSTRAINT app_release_state_check CHECK (
    (status = 'test' AND released_at IS NULL AND withdrawn_at IS NULL)
    OR (status = 'general' AND released_at IS NOT NULL AND withdrawn_at IS NULL)
    OR (status = 'withdrawn' AND withdrawn_at IS NOT NULL)
  )
);
CREATE UNIQUE INDEX app_release_version_key ON app_release (app, platform, app_version) WHERE deleted_at IS NULL;
CALL app.apply_table_standard('public.app_release');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON app_release
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'app', 'platform', 'app_version', 'file_name', 'size_bytes', 'sha256', 'signature', 'notes', 'deleted_at'
  );
CREATE POLICY app_release_select ON app_release FOR SELECT TO farmaerp_app USING (false);
CREATE VIEW v_app_release WITH (security_invoker = true) AS SELECT * FROM app_release WHERE deleted_at IS NULL;

-- Anel de atualização do terminal: os de teste recebem a versão antes da rede.
ALTER TABLE terminal ADD COLUMN update_ring text NOT NULL DEFAULT 'general'
  CONSTRAINT terminal_update_ring_check CHECK (update_ring IN ('test', 'general'));

CREATE TABLE terminal_update_event (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  terminal_id uuid NOT NULL REFERENCES terminal (id),
  release_id uuid NOT NULL REFERENCES app_release (id),
  status text NOT NULL CONSTRAINT terminal_update_event_status_check CHECK (status IN ('downloaded', 'applied', 'rolled_back', 'failed')),
  detail text CONSTRAINT terminal_update_event_detail_check CHECK (length(detail) <= 500),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE INDEX terminal_update_event_terminal_idx ON terminal_update_event (terminal_id, created_at DESC);
CREATE INDEX terminal_update_event_release_idx ON terminal_update_event (release_id, status);
CREATE INDEX terminal_update_event_economic_group_id_idx ON terminal_update_event (economic_group_id);
CALL app.apply_table_standard('public.terminal_update_event');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON terminal_update_event
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'terminal_id', 'release_id', 'status', 'detail', 'deleted_at'
  );
CREATE POLICY terminal_update_event_select ON terminal_update_event FOR SELECT TO farmaerp_app
  USING (EXISTS (SELECT 1 FROM terminal t WHERE t.id = terminal_update_event.terminal_id));
CREATE VIEW v_terminal_update_event WITH (security_invoker = true) AS
  SELECT * FROM terminal_update_event WHERE deleted_at IS NULL;
GRANT SELECT ON terminal_update_event, v_terminal_update_event TO farmaerp_app;

-- Versão em número, para comparar (1.2.10 depois de 1.2.9). Fora do formato vale zero.
CREATE FUNCTION app.version_rank(p_version text) RETURNS bigint
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$
  SELECT CASE WHEN p_version ~ '^[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}$'
              THEN pg_catalog.split_part(p_version, '.', 1)::bigint * 100000000
                   + pg_catalog.split_part(p_version, '.', 2)::bigint * 10000
                   + pg_catalog.split_part(p_version, '.', 3)::bigint
              ELSE 0 END
$$;

-- Só o envio de versões da API (com o token do CI): sem usuário e com o contexto dele.
CREATE FUNCTION app.require_release_worker() RETURNS void
LANGUAGE plpgsql STABLE
SET search_path = ''
AS $$
BEGIN
  IF app.current_user_id() IS NOT NULL OR COALESCE(pg_catalog.current_setting('app.worker', true), '') <> 'release' THEN
    RAISE EXCEPTION 'Você não tem permissão para esta operação.'
      USING ERRCODE = 'FA002', DETAIL = 'Envio de versão fora do envio do CI.';
  END IF;
END;
$$;

-- Registra a versão enviada pelo CI (o arquivo já está gravado e conferido pela API).
CREATE FUNCTION app.register_release(p_data jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  new_id uuid;
BEGIN
  PERFORM app.require_release_worker();
  IF EXISTS (
    SELECT 1 FROM public.app_release r
     WHERE r.app = p_data ->> 'app' AND r.platform = p_data ->> 'platform' AND r.app_version = p_data ->> 'version'
       AND r.deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Esta versão já foi publicada.'
      USING ERRCODE = 'FA874', DETAIL = pg_catalog.format('%s %s %s.', p_data ->> 'app', p_data ->> 'platform', p_data ->> 'version');
  END IF;
  INSERT INTO public.app_release (app, platform, app_version, file_name, size_bytes, sha256, signature, notes)
  VALUES (
    p_data ->> 'app', p_data ->> 'platform', p_data ->> 'version', p_data ->> 'fileName', (p_data ->> 'size')::bigint,
    p_data ->> 'sha256', p_data ->> 'signature', NULLIF(pg_catalog.btrim(COALESCE(p_data ->> 'notes', '')), '')
  ) RETURNING id INTO new_id;
  RETURN new_id;
END;
$$;

-- Versões para o administrador da plataforma, com quantos terminais estão em cada uma.
CREATE FUNCTION app.list_releases()
RETURNS TABLE (
  id uuid, app text, platform text, app_version text, size_bytes bigint, sha256 text, notes text, status text,
  created_at timestamptz, released_at timestamptz, withdrawn_at timestamptz,
  terminals_on integer, applied integer, rolled_back integer
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM app.require_platform_admin();
  RETURN QUERY
  SELECT r.id, r.app, r.platform, r.app_version, r.size_bytes, r.sha256, r.notes, r.status,
         r.created_at, r.released_at, r.withdrawn_at,
         (SELECT pg_catalog.count(*)::integer FROM public.terminal_status s
            JOIN public.terminal t ON t.id = s.terminal_id AND t.deleted_at IS NULL AND t.status = 'active'
           WHERE s.app_version = r.app_version AND s.deleted_at IS NULL),
         (SELECT pg_catalog.count(DISTINCT e.terminal_id)::integer FROM public.terminal_update_event e
           WHERE e.release_id = r.id AND e.status = 'applied'),
         (SELECT pg_catalog.count(DISTINCT e.terminal_id)::integer FROM public.terminal_update_event e
           WHERE e.release_id = r.id AND e.status = 'rolled_back')
    FROM public.app_release r
   WHERE r.deleted_at IS NULL
   ORDER BY r.app, r.platform, app.version_rank(r.app_version) DESC;
END;
$$;

-- Liberação gradual: teste → rede; qualquer uma pode ser retirada (retirada não volta).
CREATE FUNCTION app.set_release_status(p_release_id uuid, p_status text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.app_release;
BEGIN
  PERFORM app.require_platform_admin();
  SELECT r.* INTO target FROM public.app_release r WHERE r.id = p_release_id AND r.deleted_at IS NULL FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.' USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('app_release %s.', p_release_id);
  END IF;
  IF NOT ((target.status = 'test' AND p_status IN ('general', 'withdrawn')) OR (target.status = 'general' AND p_status = 'withdrawn')) THEN
    RAISE EXCEPTION 'Esta versão não pode mudar para essa situação.'
      USING ERRCODE = 'FA877', DETAIL = pg_catalog.format('De %s para %s.', target.status, p_status);
  END IF;
  UPDATE public.app_release
     SET status = p_status,
         released_at = CASE WHEN p_status = 'general' THEN pg_catalog.now() ELSE released_at END,
         withdrawn_at = CASE WHEN p_status = 'withdrawn' THEN pg_catalog.now() END
   WHERE id = target.id;
END;
$$;

-- Anel do terminal, pelo administrador do cliente (mesma permissão do perfil do terminal).
CREATE FUNCTION app.set_terminal_update_ring(p_terminal_id uuid, p_ring text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.terminal := app.lock_terminal(p_terminal_id, 'terminals.approve');
BEGIN
  IF p_ring IS NULL OR p_ring NOT IN ('test', 'general') THEN
    RAISE EXCEPTION 'O anel de atualização do terminal é inválido.'
      USING ERRCODE = 'FA878', DETAIL = pg_catalog.format('Anel %s.', p_ring);
  END IF;
  UPDATE public.terminal SET update_ring = p_ring WHERE id = target.id;
END;
$$;

-- Versão liberada para o terminal autenticado: a mais nova do anel dele, acima da que ele tem,
-- que ele não tenha precisado desfazer. Sem nada novo, null.
CREATE FUNCTION app.terminal_update_check(p_platform text, p_current text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  current_terminal public.terminal := app.require_active_terminal();
  found public.app_release;
BEGIN
  SELECT r.* INTO found FROM public.app_release r
   WHERE r.app = 'pdv' AND r.platform = p_platform AND r.deleted_at IS NULL
     AND (r.status = 'general' OR (r.status = 'test' AND current_terminal.update_ring = 'test'))
     AND app.version_rank(r.app_version) > app.version_rank(p_current)
     AND NOT EXISTS (
       SELECT 1 FROM public.terminal_update_event e
        WHERE e.terminal_id = current_terminal.id AND e.release_id = r.id AND e.status = 'rolled_back'
     )
   ORDER BY app.version_rank(r.app_version) DESC
   LIMIT 1;
  IF found.id IS NULL THEN
    RETURN NULL;
  END IF;
  RETURN pg_catalog.jsonb_build_object(
    'id', found.id, 'app', found.app, 'platform', found.platform, 'version', found.app_version,
    'fileName', found.file_name, 'size', found.size_bytes, 'sha256', found.sha256, 'signature', found.signature,
    'notes', found.notes
  );
END;
$$;

-- Arquivo que o terminal pode baixar: versão do anel dele, não retirada (FA875 se não puder).
CREATE FUNCTION app.terminal_release_file(p_release_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  current_terminal public.terminal := app.require_active_terminal();
  found public.app_release;
BEGIN
  SELECT r.* INTO found FROM public.app_release r
   WHERE r.id = p_release_id AND r.deleted_at IS NULL
     AND (r.status = 'general' OR (r.status = 'test' AND current_terminal.update_ring = 'test'));
  IF found.id IS NULL THEN
    RAISE EXCEPTION 'O arquivo desta versão não está disponível.'
      USING ERRCODE = 'FA875', DETAIL = pg_catalog.format('Versão %s para o terminal %s.', p_release_id, current_terminal.id);
  END IF;
  RETURN pg_catalog.jsonb_build_object(
    'app', found.app, 'platform', found.platform, 'version', found.app_version, 'fileName', found.file_name,
    'size', found.size_bytes, 'sha256', found.sha256
  );
END;
$$;

-- O terminal informa o que fez com a versão (o motivo técnico vai curto e sem dados pessoais).
CREATE FUNCTION app.record_terminal_update(p_release_id uuid, p_status text, p_detail text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  current_terminal public.terminal := app.require_active_terminal();
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.app_release r WHERE r.id = p_release_id AND r.deleted_at IS NULL) THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.' USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('app_release %s.', p_release_id);
  END IF;
  INSERT INTO public.terminal_update_event (economic_group_id, terminal_id, release_id, status, detail)
  SELECT b.economic_group_id, current_terminal.id, p_release_id, p_status,
         NULLIF(pg_catalog.left(pg_catalog.btrim(COALESCE(p_detail, '')), 500), '')
    FROM public.branch br JOIN public.company b ON b.id = br.company_id
   WHERE br.id = current_terminal.branch_id;
END;
$$;

-- Versão de uma publicação, para o monitor dos terminais (a tabela não é lida direto).
CREATE FUNCTION app.release_version(p_release_id uuid) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$ SELECT r.app_version FROM public.app_release r WHERE r.id = p_release_id $$;

-- Monitor dos terminais: anel e a última atualização.
CREATE OR REPLACE VIEW v_terminal_monitor WITH (security_invoker = true) AS
  SELECT
    t.id,
    t.branch_id,
    b.name AS branch_name,
    t.name,
    t.profile,
    t.status,
    t.created_at,
    r.platform,
    r.device_name,
    r.key_storage,
    COALESCE(s.app_version, r.app_version) AS app_version,
    s.last_seen_at,
    CASE
      WHEN s.last_seen_at >= now() - interval '3 minutes' THEN 'online'
      ELSE 'offline'
    END AS connectivity,
    s.last_sync_at,
    s.outbox_pending,
    t.number,
    s.initial_load_at,
    s.last_pull_at,
    s.last_push_at,
    app.terminal_sync_lag(t.id) AS pending_changes,
    -- Só conta para quem pode ver os conflitos (a política da tabela decide).
    (SELECT pg_catalog.count(*)::integer FROM sync_conflict sc
      WHERE sc.terminal_id = t.id AND sc.status = 'open' AND sc.deleted_at IS NULL) AS open_conflicts,
    t.offline_zero_stock_minutes AS offline_minutes,
    b.offline_zero_stock_minutes AS branch_offline_minutes,
    t.update_ring,
    u.status AS last_update_status,
    u.version AS last_update_version,
    u.created_at AS last_update_at,
    u.detail AS last_update_detail
  FROM terminal t
  JOIN branch b ON b.id = t.branch_id
  LEFT JOIN terminal_status s ON s.terminal_id = t.id AND s.deleted_at IS NULL
  LEFT JOIN terminal_pairing_request r ON r.terminal_id = t.id AND r.deleted_at IS NULL
  LEFT JOIN LATERAL (
    SELECT e.status, app.release_version(e.release_id) AS version, e.created_at, e.detail
      FROM terminal_update_event e
     WHERE e.terminal_id = t.id AND e.deleted_at IS NULL
     ORDER BY e.created_at DESC, e.id DESC
     LIMIT 1
  ) u ON true
  WHERE t.deleted_at IS NULL;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  app.version_rank(text),
  app.release_version(uuid),
  app.register_release(jsonb),
  app.list_releases(),
  app.set_release_status(uuid, text),
  app.set_terminal_update_ring(uuid, text),
  app.terminal_update_check(text, text),
  app.terminal_release_file(uuid),
  app.record_terminal_update(uuid, text, text)
TO farmaerp_app;
