-- Up Migration

-- Pareamento, situação e monitoramento de terminais.
-- A API só altera a situação de um terminal pelas funções deste arquivo.

-- Terminal autenticado na transação, definido pela API com set_config('app.terminal_id', ..., true).
CREATE FUNCTION app.current_terminal_id() RETURNS uuid
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT NULLIF(pg_catalog.current_setting('app.terminal_id', true), '')::uuid
$$;

-- Criada antes de o aparelho ter filial: por isso não fica na tabela terminal.
CREATE TABLE terminal_pairing_request (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  code char(8) NOT NULL CHECK (code ~ '^[A-HJ-NP-Z2-9]{8}$'),
  public_key text NOT NULL CHECK (public_key ~ '^[A-Za-z0-9_-]{43}$'),
  platform text NOT NULL CHECK (platform IN ('windows', 'linux', 'android')),
  device_name text NOT NULL CHECK (btrim(device_name) <> '' AND char_length(device_name) <= 100),
  app_version text NOT NULL CHECK (btrim(app_version) <> '' AND char_length(app_version) <= 50),
  -- 'file' indica proteção mais fraca: Linux sem chaveiro do sistema.
  key_storage text NOT NULL CHECK (key_storage IN ('system', 'file')),
  status text NOT NULL DEFAULT 'waiting' CHECK (status IN ('waiting', 'claimed', 'expired')),
  expires_at timestamptz NOT NULL,
  terminal_id uuid REFERENCES terminal (id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid,
  CONSTRAINT terminal_pairing_request_claimed_has_terminal CHECK (
    (status = 'claimed') = (terminal_id IS NOT NULL)
  )
);
CREATE UNIQUE INDEX terminal_pairing_request_code_active_key
  ON terminal_pairing_request (code) WHERE status = 'waiting' AND deleted_at IS NULL;
CREATE UNIQUE INDEX terminal_pairing_request_public_key_active_key
  ON terminal_pairing_request (public_key) WHERE status = 'waiting' AND deleted_at IS NULL;
CREATE INDEX terminal_pairing_request_terminal_id_idx ON terminal_pairing_request (terminal_id);

-- Sinal de vida em tabela própria, para não alterar version e updated_at de terminal a cada minuto.
CREATE TABLE terminal_status (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  terminal_id uuid NOT NULL REFERENCES terminal (id),
  last_seen_at timestamptz NOT NULL,
  app_version text,
  last_sync_at timestamptz,
  outbox_pending integer CHECK (outbox_pending >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE UNIQUE INDEX terminal_status_terminal_active_key
  ON terminal_status (terminal_id) WHERE deleted_at IS NULL;

-- Histórico imutável de quem mudou a situação do terminal, quando e por quê.
CREATE TABLE terminal_event (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  terminal_id uuid NOT NULL REFERENCES terminal (id),
  event_type text NOT NULL CHECK (event_type IN ('created', 'requested', 'approved', 'blocked', 'unblocked', 'revoked')),
  from_status text,
  to_status text NOT NULL,
  reason text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE INDEX terminal_event_terminal_id_idx ON terminal_event (terminal_id, created_at);

-- Um terminal pendente pode ser recusado (revogado) sem nunca ter recebido nome e perfil.
ALTER TABLE terminal DROP CONSTRAINT terminal_approved_has_name_and_profile;
ALTER TABLE terminal ADD CONSTRAINT terminal_approved_has_name_and_profile CHECK (
  status IN ('pending', 'revoked') OR (name IS NOT NULL AND profile IS NOT NULL)
);

CALL app.apply_table_standard('public.terminal_pairing_request');
CALL app.apply_table_standard('public.terminal_status');
CALL app.apply_table_standard('public.terminal_event');

CREATE FUNCTION app.block_history_update() RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  RAISE EXCEPTION 'Este histórico não pode ser alterado.'
    USING ERRCODE = 'FA107',
          DETAIL = pg_catalog.format('UPDATE em %I.%I.', TG_TABLE_SCHEMA, TG_TABLE_NAME);
END;
$$;

CREATE TRIGGER block_history_update BEFORE UPDATE ON terminal_event
  FOR EACH ROW EXECUTE FUNCTION app.block_history_update();

-- A chave identifica o aparelho, e a filial amarra as séries fiscais do terminal.
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON terminal
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns('public_key', 'branch_id');

-- Revogado é definitivo: o aparelho precisa de um novo pareamento, com chave nova.
CREATE FUNCTION app.validate_terminal_transition() RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF NEW.status IS DISTINCT FROM OLD.status AND NOT (
    (OLD.status = 'pending' AND NEW.status IN ('active', 'revoked'))
    OR (OLD.status = 'active' AND NEW.status IN ('blocked', 'revoked'))
    OR (OLD.status = 'blocked' AND NEW.status IN ('active', 'revoked'))
  ) THEN
    RAISE EXCEPTION 'Esta mudança de situação não é permitida para o terminal.'
      USING ERRCODE = 'FA303',
            DETAIL = pg_catalog.format('terminal %s: %s para %s.', NEW.id, OLD.status, NEW.status);
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER validate_terminal_transition BEFORE UPDATE ON terminal
  FOR EACH ROW EXECUTE FUNCTION app.validate_terminal_transition();

-- Em trigger, para nenhuma mudança de situação escapar do histórico.
CREATE FUNCTION app.record_terminal_event() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  new_event_type text;
  previous_status text;
BEGIN
  IF TG_OP = 'INSERT' THEN
    new_event_type := CASE WHEN NEW.status = 'pending' THEN 'requested' ELSE 'created' END;
  ELSE
    IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
      RETURN NULL;
    END IF;
    previous_status := OLD.status;
    new_event_type := CASE
      WHEN NEW.status = 'blocked' THEN 'blocked'
      WHEN NEW.status = 'revoked' THEN 'revoked'
      WHEN OLD.status = 'blocked' THEN 'unblocked'
      ELSE 'approved'
    END;
  END IF;

  INSERT INTO public.terminal_event (terminal_id, event_type, from_status, to_status, reason)
  VALUES (
    NEW.id, new_event_type, previous_status, NEW.status,
    NULLIF(pg_catalog.current_setting('app.status_reason', true), '')
  );
  RETURN NULL;
END;
$$;

CREATE TRIGGER record_terminal_event AFTER INSERT OR UPDATE OF status ON terminal
  FOR EACH ROW EXECUTE FUNCTION app.record_terminal_event();

-- Código de 8 caracteres sem símbolos parecidos. Usa o sorteio forte de gen_random_uuid,
-- nos bytes sem bits fixos.
CREATE FUNCTION app.generate_pairing_code() RETURNS text
LANGUAGE plpgsql VOLATILE
SET search_path = ''
AS $$
DECLARE
  alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  random_bytes bytea := pg_catalog.uuid_send(pg_catalog.gen_random_uuid());
  byte_positions constant int[] := ARRAY[0, 1, 2, 3, 4, 5, 10, 11];
  result text := '';
  position_index int;
BEGIN
  FOREACH position_index IN ARRAY byte_positions LOOP
    result := result || pg_catalog.substr(
      alphabet, pg_catalog.get_byte(random_bytes, position_index) % 32 + 1, 1);
  END LOOP;
  RETURN result;
END;
$$;

CREATE FUNCTION app.normalize_pairing_code(code text) RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$
  SELECT pg_catalog.upper(pg_catalog.regexp_replace(code, '[^0-9A-Za-z]', '', 'g'))
$$;

-- Chamada sem usuário logado: a API limita as tentativas e confere a posse da chave.
CREATE FUNCTION app.create_pairing_request(
  p_public_key text, p_platform text, p_device_name text, p_app_version text, p_key_storage text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  request public.terminal_pairing_request;
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.terminal t
     WHERE t.public_key = p_public_key AND t.deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Este aparelho já está cadastrado como terminal.'
      USING ERRCODE = 'FA220', DETAIL = 'Chave pública já usada em um terminal.';
  END IF;

  UPDATE public.terminal_pairing_request r
     SET status = 'expired'
   WHERE r.status = 'waiting' AND r.deleted_at IS NULL AND r.expires_at <= pg_catalog.now();

  SELECT * INTO request
    FROM public.terminal_pairing_request r
   WHERE r.public_key = p_public_key AND r.status = 'waiting' AND r.deleted_at IS NULL;

  IF NOT FOUND THEN
    FOR attempt IN 1..5 LOOP
      BEGIN
        INSERT INTO public.terminal_pairing_request
          (code, public_key, platform, device_name, app_version, key_storage, expires_at)
        VALUES (
          app.generate_pairing_code(), p_public_key, p_platform, p_device_name, p_app_version,
          p_key_storage, pg_catalog.now() + interval '15 minutes'
        )
        RETURNING * INTO request;
        EXIT;
      EXCEPTION WHEN unique_violation THEN
        -- Código sorteado repetido: tenta de novo.
        IF attempt = 5 THEN
          RAISE EXCEPTION 'Outra operação está usando estes dados.'
            USING ERRCODE = 'FA008', DETAIL = 'Código de pareamento repetido em 5 tentativas.';
        END IF;
      END;
    END LOOP;
  END IF;

  RETURN pg_catalog.jsonb_build_object(
    'requestId', request.id, 'code', request.code, 'expiresAt', request.expires_at);
END;
$$;

-- Consultada pelo aparelho enquanto aguarda. Exige o identificador e a chave da solicitação.
CREATE FUNCTION app.get_pairing_status(p_request_id uuid, p_public_key text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  request public.terminal_pairing_request;
  current_status text;
BEGIN
  SELECT * INTO request
    FROM public.terminal_pairing_request r
   WHERE r.id = p_request_id AND r.public_key = p_public_key AND r.deleted_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Código não encontrado ou expirado.'
      USING ERRCODE = 'FA301', DETAIL = pg_catalog.format('Solicitação %s.', p_request_id);
  END IF;

  SELECT t.status INTO current_status FROM public.terminal t WHERE t.id = request.terminal_id;

  RETURN pg_catalog.jsonb_build_object(
    'status', CASE
      WHEN request.status = 'waiting' AND request.expires_at <= pg_catalog.now() THEN 'expired'
      ELSE request.status
    END,
    'terminalId', request.terminal_id,
    'terminalStatus', current_status
  );
END;
$$;

-- Para o admin conferir o aparelho antes de aceitar o código.
CREATE FUNCTION app.find_pairing_request(p_code text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  request public.terminal_pairing_request;
BEGIN
  IF app.admin_economic_group_id() IS NULL THEN
    RAISE EXCEPTION 'Você não tem permissão para esta operação.'
      USING ERRCODE = 'FA002', DETAIL = 'find_pairing_request exige admin do grupo.';
  END IF;

  SELECT * INTO request
    FROM public.terminal_pairing_request r
   WHERE r.code = app.normalize_pairing_code(p_code)
     AND r.status = 'waiting'
     AND r.deleted_at IS NULL
     AND r.expires_at > pg_catalog.now();
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Código não encontrado ou expirado.'
      USING ERRCODE = 'FA301', DETAIL = 'Consulta de código sem resultado.';
  END IF;

  RETURN pg_catalog.jsonb_build_object(
    'platform', request.platform,
    'deviceName', request.device_name,
    'appVersion', request.app_version,
    'keyStorage', request.key_storage,
    'expiresAt', request.expires_at
  );
END;
$$;

-- Aceita o código e cria o terminal pendente na filial escolhida.
CREATE FUNCTION app.claim_pairing_request(p_code text, p_branch_id uuid) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  request public.terminal_pairing_request;
  new_terminal_id uuid;
BEGIN
  IF NOT app.is_admin_of_branch(p_branch_id) THEN
    RAISE EXCEPTION 'Você não tem permissão para esta operação.'
      USING ERRCODE = 'FA002', DETAIL = pg_catalog.format('Filial %s fora do grupo do admin.', p_branch_id);
  END IF;

  SELECT * INTO request
    FROM public.terminal_pairing_request r
   WHERE r.code = app.normalize_pairing_code(p_code)
     AND r.status = 'waiting'
     AND r.deleted_at IS NULL
     AND r.expires_at > pg_catalog.now()
     FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Código não encontrado ou expirado.'
      USING ERRCODE = 'FA301', DETAIL = 'Código sem solicitação válida.';
  END IF;

  INSERT INTO public.terminal (branch_id, public_key)
  VALUES (p_branch_id, request.public_key)
  RETURNING id INTO new_terminal_id;

  UPDATE public.terminal_pairing_request r
     SET status = 'claimed', terminal_id = new_terminal_id
   WHERE r.id = request.id;

  RETURN new_terminal_id;
END;
$$;

CREATE FUNCTION app.lock_terminal_for_admin(p_terminal_id uuid) RETURNS public.terminal
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.terminal;
BEGIN
  SELECT * INTO target
    FROM public.terminal t
   WHERE t.id = p_terminal_id AND t.deleted_at IS NULL
     FOR UPDATE;
  IF NOT FOUND OR NOT app.is_admin_of_branch(target.branch_id) THEN
    RAISE EXCEPTION 'Você não tem permissão para esta operação.'
      USING ERRCODE = 'FA002', DETAIL = pg_catalog.format('Terminal %s fora do grupo do admin.', p_terminal_id);
  END IF;
  RETURN target;
END;
$$;

CREATE FUNCTION app.approve_terminal(p_terminal_id uuid, p_name text, p_profile text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.terminal := app.lock_terminal_for_admin(p_terminal_id);
BEGIN
  IF target.status <> 'pending' THEN
    RAISE EXCEPTION 'Esta mudança de situação não é permitida para o terminal.'
      USING ERRCODE = 'FA303', DETAIL = pg_catalog.format('Aprovação com situação %s.', target.status);
  END IF;

  UPDATE public.terminal t
     SET name = pg_catalog.btrim(p_name), profile = p_profile, status = 'active'
   WHERE t.id = p_terminal_id;
END;
$$;

-- Bloqueio, desbloqueio e revogação. Bloquear e revogar exigem motivo.
CREATE FUNCTION app.set_terminal_status(p_terminal_id uuid, p_status text, p_reason text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.terminal := app.lock_terminal_for_admin(p_terminal_id);
  reason text := NULLIF(pg_catalog.btrim(COALESCE(p_reason, '')), '');
BEGIN
  IF p_status IN ('blocked', 'revoked') AND reason IS NULL THEN
    RAISE EXCEPTION 'Informe o motivo desta ação.'
      USING ERRCODE = 'FA302', DETAIL = pg_catalog.format('Mudança para %s sem motivo.', p_status);
  END IF;

  -- Aprovar tem função própria, que exige nome e perfil.
  IF p_status = target.status OR (p_status = 'active' AND target.status <> 'blocked') THEN
    RAISE EXCEPTION 'Esta mudança de situação não é permitida para o terminal.'
      USING ERRCODE = 'FA303', DETAIL = pg_catalog.format('%s para %s.', target.status, p_status);
  END IF;

  PERFORM pg_catalog.set_config('app.status_reason', COALESCE(reason, ''), true);
  UPDATE public.terminal t SET status = p_status WHERE t.id = p_terminal_id;
  PERFORM pg_catalog.set_config('app.status_reason', '', true);
END;
$$;

-- Dados para autenticar o terminal. A chave é pública; retorna NULL se o terminal não existir.
CREATE FUNCTION app.terminal_auth_info(p_terminal_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT pg_catalog.jsonb_build_object('publicKey', t.public_key, 'status', t.status)
    FROM public.terminal t
   WHERE t.id = p_terminal_id AND t.deleted_at IS NULL
$$;

-- Sinal de vida do terminal autenticado na transação.
CREATE FUNCTION app.record_terminal_heartbeat(
  p_app_version text, p_last_sync_at timestamptz, p_outbox_pending integer
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  authenticated_id uuid := app.current_terminal_id();
BEGIN
  IF authenticated_id IS NULL THEN
    RAISE EXCEPTION 'Não foi possível confirmar a identidade do terminal.'
      USING ERRCODE = 'FA306', DETAIL = 'Sinal de vida sem app.terminal_id.';
  END IF;

  INSERT INTO public.terminal_status (terminal_id, last_seen_at, app_version, last_sync_at, outbox_pending)
  VALUES (authenticated_id, pg_catalog.clock_timestamp(), p_app_version, p_last_sync_at, p_outbox_pending)
  ON CONFLICT (terminal_id) WHERE deleted_at IS NULL DO UPDATE
    SET last_seen_at = EXCLUDED.last_seen_at,
        app_version = EXCLUDED.app_version,
        last_sync_at = EXCLUDED.last_sync_at,
        outbox_pending = EXCLUDED.outbox_pending;
END;
$$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  app.current_user_id(),
  app.current_trace_id(),
  app.current_terminal_id(),
  app.is_valid_cnpj(text),
  app.admin_economic_group_id(),
  app.allowed_branch_ids(),
  app.is_admin_of_branch_group(uuid),
  app.is_admin_of_company(uuid),
  app.is_admin_of_branch(uuid),
  app.create_pairing_request(text, text, text, text, text),
  app.get_pairing_status(uuid, text),
  app.find_pairing_request(text),
  app.claim_pairing_request(text, uuid),
  app.approve_terminal(uuid, text, text),
  app.set_terminal_status(uuid, text, text),
  app.terminal_auth_info(uuid),
  app.record_terminal_heartbeat(text, timestamptz, integer)
TO farmaerp_app;

-- A situação só muda pelas funções, que registram o motivo.
REVOKE INSERT, UPDATE ON terminal FROM farmaerp_app;
GRANT INSERT (id, branch_id, name, profile, public_key) ON terminal TO farmaerp_app;
GRANT UPDATE (name, profile, deleted_at) ON terminal TO farmaerp_app;

-- Leitura para quem enxerga o terminal; nenhuma escrita direta.
GRANT SELECT ON terminal_pairing_request, terminal_status, terminal_event TO farmaerp_app;

CREATE POLICY terminal_pairing_request_select ON terminal_pairing_request FOR SELECT TO farmaerp_app
  USING (EXISTS (SELECT 1 FROM terminal t WHERE t.id = terminal_pairing_request.terminal_id));
CREATE POLICY terminal_status_select ON terminal_status FOR SELECT TO farmaerp_app
  USING (EXISTS (SELECT 1 FROM terminal t WHERE t.id = terminal_status.terminal_id));
CREATE POLICY terminal_event_select ON terminal_event FOR SELECT TO farmaerp_app
  USING (EXISTS (SELECT 1 FROM terminal t WHERE t.id = terminal_event.terminal_id));

CREATE VIEW v_terminal_pairing_request WITH (security_invoker = true) AS
  SELECT * FROM terminal_pairing_request WHERE deleted_at IS NULL;
CREATE VIEW v_terminal_status WITH (security_invoker = true) AS
  SELECT * FROM terminal_status WHERE deleted_at IS NULL;
CREATE VIEW v_terminal_event WITH (security_invoker = true) AS
  SELECT * FROM terminal_event WHERE deleted_at IS NULL;

-- Painel de monitoramento. Sem sinal de vida há 3 minutos, o terminal aparece como offline.
CREATE VIEW v_terminal_monitor WITH (security_invoker = true) AS
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
    s.outbox_pending
  FROM terminal t
  JOIN branch b ON b.id = t.branch_id
  LEFT JOIN terminal_status s ON s.terminal_id = t.id AND s.deleted_at IS NULL
  LEFT JOIN terminal_pairing_request r ON r.terminal_id = t.id AND r.deleted_at IS NULL
  WHERE t.deleted_at IS NULL;

GRANT SELECT ON v_terminal_pairing_request, v_terminal_status, v_terminal_event, v_terminal_monitor
TO farmaerp_app;
