-- Up Migration

-- Login da retaguarda: credenciais, sessões e histórico de autenticação.
-- O hash da senha é calculado na API, para a senha pura nunca passar pelo banco.

ALTER TABLE user_account
  ADD COLUMN email text CHECK (email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' AND char_length(email) <= 254),
  ADD COLUMN code bigint,
  ADD COLUMN is_active boolean NOT NULL DEFAULT true;

CREATE UNIQUE INDEX user_account_email_active_key ON user_account (email)
  WHERE deleted_at IS NULL AND email IS NOT NULL;

-- Usuários existentes recebem código pela ordem de criação, e o contador continua dali.
UPDATE user_account u
   SET code = numbered.value
  FROM (
    SELECT id, row_number() OVER (PARTITION BY economic_group_id ORDER BY created_at, id) AS value
      FROM user_account
  ) numbered
 WHERE numbered.id = u.id;

INSERT INTO code_counter (economic_group_id, entity, last_value)
SELECT economic_group_id, 'user', MAX(code)
  FROM user_account
 GROUP BY economic_group_id;

ALTER TABLE user_account ALTER COLUMN code SET NOT NULL;
CALL app.apply_human_code('public.user_account', 'user');

CREATE TABLE user_credential (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  user_id uuid NOT NULL REFERENCES user_account (id),
  password_hash text NOT NULL CHECK (btrim(password_hash) <> ''),
  must_change_password boolean NOT NULL DEFAULT true,
  failed_attempts integer NOT NULL DEFAULT 0 CHECK (failed_attempts >= 0),
  locked_until timestamptz,
  password_changed_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE UNIQUE INDEX user_credential_user_active_key ON user_credential (user_id) WHERE deleted_at IS NULL;

-- Guarda só o hash do token: quem lê o banco não consegue usar uma sessão.
CREATE TABLE user_session (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  user_id uuid NOT NULL REFERENCES user_account (id),
  token_hash text NOT NULL CHECK (token_hash ~ '^[0-9a-f]{64}$'),
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  revoked_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE UNIQUE INDEX user_session_token_hash_active_key ON user_session (token_hash) WHERE deleted_at IS NULL;
CREATE INDEX user_session_user_id_idx ON user_session (user_id) WHERE revoked_at IS NULL;

-- Histórico imutável. Só o IP é apagado depois de 90 dias (LGPD).
-- Tentativa com e-mail desconhecido fica sem usuário, e o e-mail digitado não é guardado.
CREATE TABLE auth_event (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  user_id uuid REFERENCES user_account (id),
  event_type text NOT NULL CHECK (event_type IN (
    'login_success', 'login_failure', 'login_locked', 'logout', 'password_changed', 'password_reset'
  )),
  ip_address inet,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE INDEX auth_event_user_id_idx ON auth_event (user_id, created_at);
CREATE INDEX auth_event_ip_retention_idx ON auth_event (created_at) WHERE ip_address IS NOT NULL;

CALL app.apply_table_standard('public.user_credential');
CALL app.apply_table_standard('public.user_session');
CALL app.apply_table_standard('public.auth_event');

CREATE FUNCTION app.block_auth_event_update() RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF NEW.ip_address IS NOT NULL
     OR (pg_catalog.to_jsonb(NEW) - ARRAY['ip_address', 'updated_at', 'updated_by', 'version', 'trace_id'])
        IS DISTINCT FROM
        (pg_catalog.to_jsonb(OLD) - ARRAY['ip_address', 'updated_at', 'updated_by', 'version', 'trace_id'])
  THEN
    RAISE EXCEPTION 'Este histórico não pode ser alterado.'
      USING ERRCODE = 'FA107', DETAIL = pg_catalog.format('auth_event %s.', OLD.id);
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER block_auth_event_update BEFORE UPDATE ON auth_event
  FOR EACH ROW EXECUTE FUNCTION app.block_auth_event_update();

CREATE FUNCTION app.normalize_user_email() RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  NEW.email := NULLIF(pg_catalog.lower(pg_catalog.btrim(NEW.email)), '');
  RETURN NEW;
END;
$$;

CREATE TRIGGER normalize_user_email BEFORE INSERT OR UPDATE OF email ON user_account
  FOR EACH ROW EXECUTE FUNCTION app.normalize_user_email();

-- O grupo econômico nunca fica sem administrador ativo.
CREATE FUNCTION app.protect_last_admin() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF OLD.is_group_admin AND OLD.is_active AND OLD.deleted_at IS NULL
     AND NOT (NEW.is_group_admin AND NEW.is_active AND NEW.deleted_at IS NULL)
  THEN
    PERFORM pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended('group_admin:' || OLD.economic_group_id::text, 0));

    IF NOT EXISTS (
      SELECT 1 FROM public.user_account u
       WHERE u.economic_group_id = OLD.economic_group_id
         AND u.id <> OLD.id
         AND u.is_group_admin
         AND u.is_active
         AND u.deleted_at IS NULL
    ) THEN
      RAISE EXCEPTION 'O grupo precisa ter ao menos um administrador ativo.'
        USING ERRCODE = 'FA405', DETAIL = pg_catalog.format('user_account %s.', OLD.id);
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER protect_last_admin BEFORE UPDATE ON user_account
  FOR EACH ROW EXECUTE FUNCTION app.protect_last_admin();

-- Encerrar as sessões em trigger garante que nenhuma exceção fique de fora.
CREATE FUNCTION app.revoke_sessions_of(p_user_id uuid, p_except_token_hash text DEFAULT NULL) RETURNS void
LANGUAGE sql SECURITY DEFINER
SET search_path = ''
AS $$
  UPDATE public.user_session s
     SET revoked_at = pg_catalog.clock_timestamp()
   WHERE s.user_id = p_user_id
     AND s.revoked_at IS NULL
     AND s.token_hash IS DISTINCT FROM p_except_token_hash
$$;

CREATE FUNCTION app.revoke_sessions_on_user_change() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT NEW.is_active OR NEW.deleted_at IS NOT NULL OR NEW.email IS DISTINCT FROM OLD.email THEN
    PERFORM app.revoke_sessions_of(NEW.id);
  END IF;
  RETURN NULL;
END;
$$;

CREATE TRIGGER revoke_sessions_on_user_change AFTER UPDATE ON user_account
  FOR EACH ROW EXECUTE FUNCTION app.revoke_sessions_on_user_change();

-- Usuário desativado não é administrador nem enxerga filiais.
CREATE OR REPLACE FUNCTION app.admin_economic_group_id() RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT u.economic_group_id
    FROM public.user_account u
   WHERE u.id = app.current_user_id()
     AND u.deleted_at IS NULL
     AND u.is_active
     AND u.is_group_admin
$$;

CREATE OR REPLACE FUNCTION app.allowed_branch_ids() RETURNS uuid[]
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE(pg_catalog.array_agg(b.id), '{}')
    FROM public.user_account u
    JOIN public.company c ON c.economic_group_id = u.economic_group_id
    JOIN public.branch b ON b.company_id = c.id
   WHERE u.id = app.current_user_id()
     AND u.deleted_at IS NULL
     AND u.is_active
     AND (
       u.is_group_admin
       OR (
         b.deleted_at IS NULL
         AND c.deleted_at IS NULL
         AND EXISTS (
           SELECT 1
             FROM public.user_branch ub
            WHERE ub.user_id = u.id
              AND ub.branch_id = b.id
              AND ub.deleted_at IS NULL
         )
       )
     )
$$;

CREATE FUNCTION app.record_auth_event(p_user_id uuid, p_event_type text, p_ip text) RETURNS void
LANGUAGE sql SECURITY DEFINER
SET search_path = ''
AS $$
  INSERT INTO public.auth_event (user_id, event_type, ip_address)
  VALUES (p_user_id, p_event_type, NULLIF(p_ip, '')::inet)
$$;

-- Dados para conferir a senha na API. Sem usuário logado, porque ainda é o login.
CREATE FUNCTION app.auth_lookup(p_email text) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT pg_catalog.jsonb_build_object(
    'userId', u.id,
    'passwordHash', c.password_hash,
    'locked', COALESCE(c.locked_until > pg_catalog.now(), false)
  )
    FROM public.user_account u
    JOIN public.user_credential c ON c.user_id = u.id AND c.deleted_at IS NULL
   WHERE u.email = pg_catalog.lower(pg_catalog.btrim(p_email))
     AND u.deleted_at IS NULL
     AND u.is_active
$$;

-- Depois de 5 falhas seguidas, a conta fica bloqueada por 15 minutos.
CREATE FUNCTION app.auth_login_failed(p_user_id uuid, p_ip text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  credential public.user_credential;
BEGIN
  IF p_user_id IS NOT NULL THEN
    SELECT * INTO credential
      FROM public.user_credential c
     WHERE c.user_id = p_user_id AND c.deleted_at IS NULL
       FOR UPDATE;

    IF credential.locked_until > pg_catalog.now() THEN
      PERFORM app.record_auth_event(p_user_id, 'login_locked', p_ip);
      RETURN;
    END IF;

    UPDATE public.user_credential c
       SET failed_attempts = CASE WHEN c.failed_attempts >= 4 THEN 0 ELSE c.failed_attempts + 1 END,
           locked_until = CASE
             WHEN c.failed_attempts >= 4 THEN pg_catalog.now() + interval '15 minutes'
             ELSE c.locked_until
           END
     WHERE c.id = credential.id;
  END IF;

  PERFORM app.record_auth_event(p_user_id, 'login_failure', p_ip);
END;
$$;

CREATE FUNCTION app.auth_login_succeeded(p_user_id uuid, p_token_hash text, p_ip text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  must_change boolean;
BEGIN
  UPDATE public.user_credential c
     SET failed_attempts = 0, locked_until = NULL
   WHERE c.user_id = p_user_id AND c.deleted_at IS NULL
  RETURNING c.must_change_password INTO must_change;

  INSERT INTO public.user_session (user_id, token_hash) VALUES (p_user_id, p_token_hash);
  PERFORM app.record_auth_event(p_user_id, 'login_success', p_ip);

  -- Retenção do IP: roda aqui para não depender de um agendador.
  UPDATE public.auth_event e
     SET ip_address = NULL
   WHERE e.ip_address IS NOT NULL
     AND e.created_at < pg_catalog.now() - interval '90 days';

  RETURN pg_catalog.jsonb_build_object('mustChangePassword', must_change);
END;
$$;

-- Sessão vale até 8 horas sem uso, e no máximo 12 horas no total.
CREATE FUNCTION app.validate_session(p_token_hash text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  session_id uuid;
  session_last_seen timestamptz;
  result jsonb;
BEGIN
  SELECT s.id, s.last_seen_at,
         pg_catalog.jsonb_build_object(
           'userId', u.id,
           'name', u.name,
           'email', u.email,
           'code', u.code,
           'isAdmin', u.is_group_admin,
           'mustChangePassword', COALESCE(c.must_change_password, false)
         )
    INTO session_id, session_last_seen, result
    FROM public.user_session s
    JOIN public.user_account u ON u.id = s.user_id
    LEFT JOIN public.user_credential c ON c.user_id = u.id AND c.deleted_at IS NULL
   WHERE s.token_hash = p_token_hash
     AND s.revoked_at IS NULL
     AND s.deleted_at IS NULL
     AND s.last_seen_at > pg_catalog.now() - interval '8 hours'
     AND s.created_at > pg_catalog.now() - interval '12 hours'
     AND u.deleted_at IS NULL
     AND u.is_active;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  -- Atualiza no máximo uma vez por minuto, para não gravar a cada requisição.
  IF session_last_seen < pg_catalog.now() - interval '1 minute' THEN
    UPDATE public.user_session s SET last_seen_at = pg_catalog.now() WHERE s.id = session_id;
  END IF;

  RETURN result;
END;
$$;

CREATE FUNCTION app.end_session(p_token_hash text, p_ip text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  ended_user_id uuid;
BEGIN
  UPDATE public.user_session s
     SET revoked_at = pg_catalog.clock_timestamp()
   WHERE s.token_hash = p_token_hash AND s.revoked_at IS NULL
  RETURNING s.user_id INTO ended_user_id;

  IF ended_user_id IS NOT NULL THEN
    PERFORM app.record_auth_event(ended_user_id, 'logout', p_ip);
  END IF;
END;
$$;

-- Hash do próprio usuário, para conferir a senha atual antes de trocar.
CREATE FUNCTION app.current_password_hash() RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT c.password_hash
    FROM public.user_credential c
   WHERE c.user_id = app.current_user_id() AND c.deleted_at IS NULL
$$;

-- Trocar a senha encerra as outras sessões do usuário e mantém a atual.
CREATE FUNCTION app.change_own_password(p_new_hash text, p_token_hash text, p_ip text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target_user_id uuid := app.current_user_id();
BEGIN
  UPDATE public.user_credential c
     SET password_hash = p_new_hash,
         must_change_password = false,
         failed_attempts = 0,
         locked_until = NULL,
         password_changed_at = pg_catalog.now()
   WHERE c.user_id = target_user_id AND c.deleted_at IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Sua sessão expirou.'
      USING ERRCODE = 'FA402', DETAIL = 'Troca de senha sem credencial.';
  END IF;

  PERFORM app.revoke_sessions_of(target_user_id, p_token_hash);
  PERFORM app.record_auth_event(target_user_id, 'password_changed', p_ip);
END;
$$;

-- Senha temporária definida pelo admin. Também é assim que um usuário ganha acesso.
CREATE FUNCTION app.set_temporary_password(p_user_id uuid, p_new_hash text, p_ip text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.user_account;
BEGIN
  SELECT * INTO target
    FROM public.user_account u
   WHERE u.id = p_user_id AND u.deleted_at IS NULL
     FOR UPDATE;

  IF NOT FOUND OR target.economic_group_id IS DISTINCT FROM app.admin_economic_group_id() THEN
    RAISE EXCEPTION 'Você não tem permissão para esta operação.'
      USING ERRCODE = 'FA002', DETAIL = pg_catalog.format('Senha temporária de %s.', p_user_id);
  END IF;

  IF NOT target.is_active THEN
    RAISE EXCEPTION 'O usuário informado não está ativo.'
      USING ERRCODE = 'FA209', DETAIL = pg_catalog.format('user_account %s inativo.', p_user_id);
  END IF;

  IF target.email IS NULL THEN
    RAISE EXCEPTION 'Informe o e-mail do usuário para liberar o acesso à retaguarda.'
      USING ERRCODE = 'FA408', DETAIL = pg_catalog.format('user_account %s sem e-mail.', p_user_id);
  END IF;

  INSERT INTO public.user_credential (user_id, password_hash, must_change_password)
  VALUES (p_user_id, p_new_hash, true)
  ON CONFLICT (user_id) WHERE deleted_at IS NULL DO UPDATE
    SET password_hash = EXCLUDED.password_hash,
        must_change_password = true,
        failed_attempts = 0,
        locked_until = NULL,
        password_changed_at = pg_catalog.now();

  PERFORM app.revoke_sessions_of(p_user_id);
  PERFORM app.record_auth_event(p_user_id, 'password_reset', p_ip);
END;
$$;

-- Quais usuários do grupo têm acesso à retaguarda. Não revela nada da senha.
CREATE FUNCTION app.user_ids_with_access() RETURNS uuid[]
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE(pg_catalog.array_agg(c.user_id), '{}')
    FROM public.user_credential c
    JOIN public.user_account u ON u.id = c.user_id
   WHERE c.deleted_at IS NULL
     AND u.economic_group_id = app.admin_economic_group_id()
$$;

-- Credenciais e sessões só pelas funções: a API não lê nem grava as tabelas.
CREATE POLICY user_credential_select ON user_credential FOR SELECT TO farmaerp_app USING (false);
CREATE POLICY user_session_select ON user_session FOR SELECT TO farmaerp_app USING (false);
CREATE POLICY auth_event_select ON auth_event FOR SELECT TO farmaerp_app
  USING (EXISTS (
    SELECT 1 FROM user_account u
     WHERE u.id = auth_event.user_id
       AND u.economic_group_id = (SELECT app.admin_economic_group_id())
  ));
GRANT SELECT ON auth_event TO farmaerp_app;

CREATE VIEW v_user_credential WITH (security_invoker = true) AS
  SELECT * FROM user_credential WHERE deleted_at IS NULL;
CREATE VIEW v_user_session WITH (security_invoker = true) AS
  SELECT * FROM user_session WHERE deleted_at IS NULL;
CREATE VIEW v_auth_event WITH (security_invoker = true) AS
  SELECT * FROM auth_event WHERE deleted_at IS NULL;
GRANT SELECT ON v_auth_event TO farmaerp_app;

-- security_invoker precisa ser repetido: CREATE OR REPLACE substitui as opções da view.
CREATE OR REPLACE VIEW v_user_account WITH (security_invoker = true) AS
  SELECT * FROM user_account WHERE deleted_at IS NULL;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  app.auth_lookup(text),
  app.auth_login_failed(uuid, text),
  app.auth_login_succeeded(uuid, text, text),
  app.validate_session(text),
  app.end_session(text, text),
  app.current_password_hash(),
  app.change_own_password(text, text, text),
  app.set_temporary_password(uuid, text, text),
  app.user_ids_with_access()
TO farmaerp_app;
