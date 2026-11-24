-- Up Migration

-- Etapa 5, PR 5B: rosto do funcionário.
-- O rosto é cadastrado no PDV, com a pessoa presente, o consentimento dela (LGPD) e alguém com
-- "Cadastrar o rosto no PDV" autorizando. Só o código numérico do rosto (128 números, 512 bytes) é
-- guardado, nunca a imagem. Ele desce para os PDVs das filiais da pessoa, onde a comparação é feita
-- sem internet. Revogar o consentimento apaga o código (exclusão lógica) e tira o rosto dos PDVs.

INSERT INTO permission (code, module, name) VALUES
  ('users.biometrics', 'Usuários', 'Cadastrar o rosto e a digital no PDV');
INSERT INTO role_permission (role_id, permission_id)
SELECT r.id, p.id
  FROM role r JOIN permission p ON p.code = 'users.biometrics'
 WHERE r.deleted_at IS NULL AND r.system_key IS NULL AND r.name = 'Gerente'
   AND NOT EXISTS (
     SELECT 1 FROM role_permission rp WHERE rp.role_id = r.id AND rp.permission_id = p.id AND rp.deleted_at IS NULL
   );

ALTER TABLE auth_event DROP CONSTRAINT auth_event_event_type_check;
ALTER TABLE auth_event ADD CONSTRAINT auth_event_event_type_check CHECK (event_type IN (
  'login_success', 'login_failure', 'login_locked', 'logout', 'password_changed', 'password_reset', 'pin_set',
  'pdv_auth_mode_set', 'face_enrolled', 'face_revoked'
));

-- Consentimento para o uso da biometria: versão do termo, quando, quem colheu e onde. Revogado,
-- guarda quando e por quem.
CREATE TABLE biometric_consent (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  user_id uuid NOT NULL REFERENCES user_account (id),
  kind text NOT NULL CONSTRAINT biometric_consent_kind_check CHECK (kind IN ('face', 'fingerprint')),
  term_version text NOT NULL CONSTRAINT biometric_consent_term_check CHECK (term_version ~ '^[a-z0-9-]{1,40}$'),
  consented_at timestamptz NOT NULL,
  collected_by uuid NOT NULL REFERENCES user_account (id),
  terminal_id uuid REFERENCES terminal (id),
  revoked_at timestamptz,
  revoked_by uuid REFERENCES user_account (id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid,
  CONSTRAINT biometric_consent_revoked_check CHECK ((revoked_at IS NULL) = (revoked_by IS NULL))
);
CREATE INDEX biometric_consent_user_idx ON biometric_consent (user_id, consented_at DESC);
CALL app.apply_table_standard('public.biometric_consent');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON biometric_consent
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'user_id', 'kind', 'term_version', 'consented_at', 'collected_by', 'terminal_id'
  );
CREATE POLICY biometric_consent_select ON biometric_consent FOR SELECT TO farmaerp_app USING (false);
CREATE VIEW v_biometric_consent WITH (security_invoker = true) AS
  SELECT * FROM biometric_consent WHERE deleted_at IS NULL;

-- Código numérico do rosto (vetor de 128 float32, 512 bytes). Um ativo por pessoa.
CREATE TABLE face_template (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  user_id uuid NOT NULL REFERENCES user_account (id),
  consent_id uuid NOT NULL REFERENCES biometric_consent (id),
  model text NOT NULL CONSTRAINT face_template_model_check CHECK (model IN ('sface-2021dec-int8')),
  template bytea NOT NULL CONSTRAINT face_template_template_check CHECK (octet_length(template) = 512),
  enrolled_by uuid NOT NULL REFERENCES user_account (id),
  enrolled_at timestamptz NOT NULL,
  terminal_id uuid NOT NULL REFERENCES terminal (id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE UNIQUE INDEX face_template_user_key ON face_template (user_id) WHERE deleted_at IS NULL;
CALL app.apply_table_standard('public.face_template');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON face_template
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'user_id', 'consent_id', 'model', 'template', 'enrolled_by', 'enrolled_at', 'terminal_id'
  );
CREATE POLICY face_template_select ON face_template FOR SELECT TO farmaerp_app USING (false);
CREATE VIEW v_face_template WITH (security_invoker = true) AS
  SELECT * FROM face_template WHERE deleted_at IS NULL;

-- Rosto novo ou apagado desce para os PDVs da pessoa.
CREATE FUNCTION app.track_face_template_change() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM app.mark_sync_change('user', NEW.user_id, NEW.economic_group_id, NULL);
  RETURN NULL;
END;
$$;
CREATE TRIGGER track_sync_change AFTER INSERT OR UPDATE ON face_template
  FOR EACH ROW EXECUTE FUNCTION app.track_face_template_change();

-- Cadastro do rosto vindo do PDV: consentimento e código, com quem autorizou.
CREATE FUNCTION app.sync_apply_face_enrollment(p_terminal public.terminal, p_group_id uuid, p_payload jsonb)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  uuid_any constant text := '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
  uuid_v7 constant text := '^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$';
  stamp constant text := '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$';
  person public.user_account;
  enroller uuid;
  consent jsonb := p_payload -> 'consent';
  template bytea;
  consent_row_id uuid;
BEGIN
  IF (p_payload ->> 'id') !~ uuid_v7
     OR (p_payload ->> 'user_id') !~ uuid_any
     OR (p_payload ->> 'enrolled_by') !~ uuid_any
     OR (p_payload ->> 'enrolled_at') !~ stamp
     OR (p_payload ->> 'model') IS DISTINCT FROM 'sface-2021dec-int8'
     OR pg_catalog.jsonb_typeof(p_payload -> 'template') IS DISTINCT FROM 'string'
     OR (p_payload ->> 'template') !~ '^[A-Za-z0-9+/]+=$'
     OR pg_catalog.length(p_payload ->> 'template') <> 684
     OR pg_catalog.jsonb_typeof(consent) IS DISTINCT FROM 'object'
     OR (consent ->> 'id') !~ uuid_v7
     OR (consent ->> 'term_version') !~ '^[a-z0-9-]{1,40}$'
     OR (consent ->> 'consented_at') !~ stamp THEN
    RAISE EXCEPTION 'A venda enviada pelo terminal está inconsistente.'
      USING ERRCODE = 'FA962', DETAIL = 'Cadastro do rosto fora do formato.';
  END IF;
  template := pg_catalog.decode(p_payload ->> 'template', 'base64');
  enroller := (p_payload ->> 'enrolled_by')::uuid;
  IF EXISTS (SELECT 1 FROM public.face_template f WHERE f.id = (p_payload ->> 'id')::uuid)
     OR EXISTS (SELECT 1 FROM public.biometric_consent c WHERE c.id = (consent ->> 'id')::uuid) THEN
    RAISE EXCEPTION 'Esta venda ou turno já foi recebido com outro registro.'
      USING ERRCODE = 'FA963', DETAIL = 'Cadastro do rosto repetido.';
  END IF;
  SELECT u.* INTO person FROM public.user_account u
   WHERE u.id = (p_payload ->> 'user_id')::uuid AND u.economic_group_id = p_group_id AND u.deleted_at IS NULL;
  IF NOT FOUND OR NOT EXISTS (
    SELECT 1 FROM public.user_account u WHERE u.id = enroller AND u.economic_group_id = p_group_id AND u.deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Um dos itens informados não foi encontrado.'
      USING ERRCODE = 'FA004', DETAIL = 'Pessoa do cadastro do rosto fora do grupo.';
  END IF;
  -- Biometria só com autorização: sem a permissão, o cadastro não vale (vira conflito).
  IF NOT app.user_has_permission(enroller, 'users.biometrics', p_terminal.branch_id) THEN
    RAISE EXCEPTION 'Quem cadastra o rosto precisa da permissão.'
      USING ERRCODE = 'FA822', DETAIL = pg_catalog.format('Cadastro autorizado por %s.', enroller);
  END IF;
  IF NOT person.is_active THEN
    RAISE EXCEPTION 'O usuário informado não está ativo.'
      USING ERRCODE = 'FA209', DETAIL = pg_catalog.format('user_account %s inativo.', person.id);
  END IF;
  BEGIN
    INSERT INTO public.biometric_consent (
      id, economic_group_id, user_id, kind, term_version, consented_at, collected_by, terminal_id
    ) VALUES (
      (consent ->> 'id')::uuid, p_group_id, person.id, 'face', consent ->> 'term_version',
      (consent ->> 'consented_at')::timestamptz, enroller, p_terminal.id
    ) RETURNING id INTO consent_row_id;
    -- O rosto anterior (e o consentimento dele) dá lugar ao novo.
    UPDATE public.face_template SET deleted_at = pg_catalog.now()
     WHERE user_id = person.id AND deleted_at IS NULL;
    INSERT INTO public.face_template (
      id, economic_group_id, user_id, consent_id, model, template, enrolled_by, enrolled_at, terminal_id
    ) VALUES (
      (p_payload ->> 'id')::uuid, p_group_id, person.id, consent_row_id, p_payload ->> 'model', template, enroller,
      (p_payload ->> 'enrolled_at')::timestamptz, p_terminal.id
    );
  EXCEPTION WHEN datetime_field_overflow OR invalid_datetime_format THEN
    RAISE EXCEPTION 'A venda enviada pelo terminal está inconsistente.'
      USING ERRCODE = 'FA962', DETAIL = 'Data do cadastro do rosto impossível.';
  END;
  PERFORM app.record_auth_event(person.id, 'face_enrolled', NULL);
END;
$$;

-- Revoga o consentimento e apaga o rosto. Pode a própria pessoa ou quem pode definir o PIN dela.
CREATE FUNCTION app.revoke_face(p_user_id uuid, p_ip text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  actor uuid := app.current_user_id();
  target public.user_account;
  removed public.face_template;
BEGIN
  SELECT * INTO target FROM public.user_account u
   WHERE u.id = p_user_id AND u.deleted_at IS NULL AND u.economic_group_id = app.current_user_group();
  IF NOT FOUND OR (
    p_user_id IS DISTINCT FROM actor
    AND (NOT app.can_on_user('users.reset_password', p_user_id) OR NOT app.covers_user(p_user_id))
  ) THEN
    RAISE EXCEPTION 'Você não tem permissão para esta operação.'
      USING ERRCODE = 'FA002', DETAIL = pg_catalog.format('Rosto de %s.', p_user_id);
  END IF;
  UPDATE public.face_template SET deleted_at = pg_catalog.now()
   WHERE user_id = p_user_id AND deleted_at IS NULL
  RETURNING * INTO removed;
  IF removed.id IS NULL THEN
    RAISE EXCEPTION 'Esta pessoa não tem rosto cadastrado.'
      USING ERRCODE = 'FA823', DETAIL = pg_catalog.format('user_account %s.', p_user_id);
  END IF;
  UPDATE public.biometric_consent SET revoked_at = pg_catalog.now(), revoked_by = actor
   WHERE user_id = p_user_id AND kind = 'face' AND revoked_at IS NULL;
  PERFORM app.record_auth_event(p_user_id, 'face_revoked', p_ip);
END;
$$;

-- Situação do rosto das pessoas que quem pergunta pode ver (sem o código do rosto).
CREATE FUNCTION app.face_enrollments()
RETURNS TABLE (user_id uuid, enrolled_at timestamptz, enrolled_by_name text, term_version text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT f.user_id, f.enrolled_at, e.name, c.term_version
    FROM public.face_template f
    JOIN public.biometric_consent c ON c.id = f.consent_id
    JOIN public.user_account e ON e.id = f.enrolled_by
   WHERE f.deleted_at IS NULL
     AND f.economic_group_id = app.current_user_group()
     AND (f.user_id = app.current_user_id() OR app.can_on_user('users.view', f.user_id))
$$;

-- Usuário com o código do rosto (só quando há rosto cadastrado e consentimento).
CREATE OR REPLACE FUNCTION app.pdv_user_data(p_branch_id uuid, p_ids uuid[])
RETURNS TABLE (id uuid, data jsonb)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT ids.id,
         CASE WHEN EXISTS (SELECT 1 FROM app.user_roles_at(ids.id, p_branch_id)) THEN pg_catalog.jsonb_build_object(
           'code', u.code,
           'name', u.name,
           'auth_mode', u.pdv_auth_mode,
           'face', (
             SELECT pg_catalog.jsonb_build_object('model', f.model, 'template', pg_catalog.translate(pg_catalog.encode(f.template, 'base64'), E'\n', ''))
               FROM public.face_template f
              WHERE f.user_id = ids.id AND f.deleted_at IS NULL
           ),
           'pin_hash', (SELECT up.pin_hash FROM public.user_pin up WHERE up.user_id = ids.id AND up.deleted_at IS NULL),
           'is_admin', EXISTS (
             SELECT 1 FROM app.user_roles_at(ids.id, p_branch_id) r WHERE r.system_key = 'administrator'
           ),
           'roles', (
             SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('id', r.id, 'name', r.name) ORDER BY r.name, r.id)
               FROM app.user_roles_at(ids.id, p_branch_id) r
           ),
           'permissions', COALESCE((
             SELECT pg_catalog.jsonb_agg(p.code ORDER BY p.code)
               FROM public.permission p
              WHERE p.deleted_at IS NULL AND app.user_has_permission(ids.id, p.code, p_branch_id)
           ), '[]'::jsonb),
           'limits', COALESCE((
             SELECT pg_catalog.jsonb_object_agg(t.code, app.user_limit(ids.id, p_branch_id, t.code))
               FROM public.limit_type t
              WHERE t.deleted_at IS NULL
           ), '{}'::jsonb)
         ) END
    FROM pg_catalog.unnest(p_ids) AS ids(id)
    LEFT JOIN public.user_account u ON u.id = ids.id
$$;


-- Perfis padrão de um grupo novo, agora com o cadastro da biometria para o Gerente.
CREATE OR REPLACE FUNCTION app.create_default_roles(p_group_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  manager_id uuid;
BEGIN
  INSERT INTO public.role (economic_group_id, name, description, system_key)
  VALUES (p_group_id, 'Administrador', 'Acesso total. Não pode ser alterado.', 'administrator');

  INSERT INTO public.role (economic_group_id, name, description)
  VALUES (p_group_id, 'Gerente', 'Urgências da loja: terminais e senhas temporárias.')
  RETURNING id INTO manager_id;

  INSERT INTO public.role (economic_group_id, name, description) VALUES
    (p_group_id, 'Farmacêutico', 'Libera a venda de controlados no PDV. O SNGPC chega na Etapa 8.'),
    (p_group_id, 'Operador de caixa', 'Abre o caixa, vende e orça no PDV.'),
    (p_group_id, 'Balconista', 'Monta orçamentos no PDV para o caixa fechar a venda.');

  -- A liberação do custo e o desconto acima do produto ficam só com o Administrador.
  INSERT INTO public.role_permission (role_id, permission_id)
  SELECT manager_id, p.id
    FROM public.permission p
   WHERE p.code IN (
     'users.view', 'users.reset_password', 'terminals.view', 'terminals.request', 'terminals.block',
     'products.view', 'stock.view', 'stock.loss', 'stock.transfer', 'stock.batch_override',
     'customers.view', 'customers.manage', 'fiscal.certificate', 'purchases.view', 'purchases.manage',
     'purchases.post', 'releases.view', 'sync.view', 'sync.resolve', 'sales.sell', 'sales.view', 'sales.zero_stock_release', 'controlled.view', 'sales.quote', 'sales.return',
     'users.release_login', 'users.biometrics'
   );
  INSERT INTO public.role_permission (role_id, permission_id)
  SELECT r.id, p.id
    FROM public.role r
    JOIN public.permission p ON p.code IN ('sales.sell', 'sales.quote')
   WHERE r.economic_group_id = p_group_id AND r.name = 'Operador de caixa';
  INSERT INTO public.role_permission (role_id, permission_id)
  SELECT r.id, p.id
    FROM public.role r
    JOIN public.permission p ON p.code = 'sales.quote'
   WHERE r.economic_group_id = p_group_id AND r.name = 'Balconista';
  INSERT INTO public.role_permission (role_id, permission_id)
  SELECT r.id, p.id
    FROM public.role r
    JOIN public.permission p ON p.code IN ('sales.sell', 'sales.quote', 'controlled.dispense', 'controlled.view')
   WHERE r.economic_group_id = p_group_id AND r.name = 'Farmacêutico';
  PERFORM app.seed_manager_limits(manager_id, p_group_id);
END;
$$;


-- Subida do PDV, agora com o cadastro do rosto.
CREATE OR REPLACE FUNCTION app.pdv_push(p_items jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  terminal_row public.terminal := app.require_active_terminal();
  group_id uuid;
  item jsonb;
  item_id uuid;
  item_sequence bigint;
  last_sequence bigint := 0;
  existing public.sync_receipt;
  outcome text;
  failure_code text;
  failure_message text;
  results jsonb := '[]'::jsonb;
BEGIN
  IF pg_catalog.jsonb_typeof(p_items) IS DISTINCT FROM 'array'
     OR pg_catalog.jsonb_array_length(p_items) NOT BETWEEN 1 AND 500 THEN
    RAISE EXCEPTION 'Os dados da sincronização são inválidos.'
      USING ERRCODE = 'FA956', DETAIL = 'Lista de itens vazia, grande demais ou fora do formato.';
  END IF;

  SELECT c.economic_group_id INTO group_id
    FROM public.branch b JOIN public.company c ON c.id = b.company_id
   WHERE b.id = terminal_row.branch_id;

  FOR item IN SELECT value FROM pg_catalog.jsonb_array_elements(p_items) LOOP
    -- Item fora do formato recusa o pacote inteiro: é defeito do PDV, não conflito de dados.
    IF pg_catalog.jsonb_typeof(item) IS DISTINCT FROM 'object'
       OR (item ->> 'id') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
       OR (item ->> 'sequence') !~ '^[1-9][0-9]{0,17}$'
       OR (item ->> 'kind') !~ '^[a-z_]{1,40}$'
       OR pg_catalog.jsonb_typeof(item -> 'payload') IS DISTINCT FROM 'object' THEN
      RAISE EXCEPTION 'Os dados da sincronização são inválidos.'
        USING ERRCODE = 'FA956', DETAIL = 'Item da subida fora do formato.';
    END IF;
    item_id := (item ->> 'id')::uuid;
    item_sequence := (item ->> 'sequence')::bigint;
    IF item_sequence <= last_sequence THEN
      RAISE EXCEPTION 'Os dados da sincronização são inválidos.'
        USING ERRCODE = 'FA956', DETAIL = 'Itens da subida fora de ordem.';
    END IF;
    last_sequence := item_sequence;

    SELECT r.* INTO existing FROM public.sync_receipt r WHERE r.id = item_id;
    IF FOUND THEN
      IF existing.terminal_id <> terminal_row.id THEN
        RAISE EXCEPTION 'Os dados da sincronização são inválidos.'
          USING ERRCODE = 'FA956', DETAIL = 'Item já recebido de outro terminal.';
      END IF;
      results := results || pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
        'id', item_id, 'status', 'duplicate', 'result', existing.status,
        'code', (SELECT c.error_code FROM public.sync_conflict c WHERE c.receipt_id = item_id AND c.deleted_at IS NULL)
      ));
      CONTINUE;
    END IF;

    outcome := 'applied';
    failure_code := NULL;
    failure_message := NULL;
    BEGIN
      CASE item ->> 'kind'
        WHEN 'log' THEN
          PERFORM app.sync_apply_log(terminal_row, group_id, item_id, item -> 'payload');
        WHEN 'cash_session_open' THEN
          PERFORM app.sync_apply_cash_open(terminal_row, group_id, item -> 'payload');
        WHEN 'sale' THEN
          PERFORM app.sync_apply_sale(terminal_row, group_id, item -> 'payload');
        WHEN 'sale_return' THEN
          PERFORM app.sync_apply_return(terminal_row, group_id, item -> 'payload');
        WHEN 'quote' THEN
          PERFORM app.sync_apply_quote(terminal_row, group_id, item -> 'payload');
        WHEN 'cash_movement' THEN
          PERFORM app.sync_apply_cash_movement(terminal_row, group_id, item -> 'payload');
        WHEN 'cash_session_close' THEN
          PERFORM app.sync_apply_cash_close(terminal_row, group_id, item -> 'payload');
        WHEN 'auth_event' THEN
          PERFORM app.sync_apply_auth_event(terminal_row, group_id, item -> 'payload');
        WHEN 'face_enrollment' THEN
          PERFORM app.sync_apply_face_enrollment(terminal_row, group_id, item -> 'payload');
        ELSE
          RAISE EXCEPTION 'O terminal enviou um tipo de registro desconhecido.'
            USING ERRCODE = 'FA959', DETAIL = pg_catalog.format('Tipo %s.', item ->> 'kind');
      END CASE;
    EXCEPTION WHEN OTHERS THEN
      -- Erro do catálogo é decisão do banco: vira conflito. Outro erro é falha e recusa o pacote.
      IF SQLSTATE !~ '^FA[0-9]{3}$' THEN
        RAISE;
      END IF;
      outcome := 'conflict';
      failure_code := SQLSTATE;
      failure_message := SQLERRM;
    END;

    INSERT INTO public.sync_receipt (id, economic_group_id, branch_id, terminal_id, kind, sequence, status)
    VALUES (item_id, group_id, terminal_row.branch_id, terminal_row.id, item ->> 'kind', item_sequence, outcome);
    IF outcome = 'conflict' THEN
      INSERT INTO public.sync_conflict (
        economic_group_id, branch_id, terminal_id, receipt_id, kind, error_code, detail, payload
      ) VALUES (
        group_id, terminal_row.branch_id, terminal_row.id, item_id, item ->> 'kind', failure_code, failure_message,
        item -> 'payload'
      );
    END IF;
    results := results || pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
      'id', item_id, 'status', outcome, 'code', failure_code
    ));
  END LOOP;

  PERFORM app.record_terminal_sync('push', NULL, false);
  RETURN pg_catalog.jsonb_build_object('results', results);
END;
$$;


REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  app.revoke_face(uuid, text),
  app.face_enrollments()
TO farmaerp_app;
