-- Up Migration

-- Etapa 5, PR 5A: serviço único de autenticação no PDV.
-- Cada pessoa tem a forma de entrar no PDV (qualquer uma, só PIN, só câmera ou só digital), que
-- desce para as filiais dela. Quem não consegue usar a forma configurada (câmera ou leitor com
-- defeito, ou ainda sem cadastro) entra com a liberação de quem tem "Liberar a entrada no PDV".
-- Toda entrada, falha, bloqueio e liberação feitos no PDV sobem pela outbox e ficam registrados.
-- Entrada fora da forma configurada ou liberada por quem não tinha a permissão vale (já
-- aconteceu, talvez sem internet) e fica marcada para a retaguarda conferir.

-- any: qualquer uma das três; pin, face (câmera) ou fingerprint (digital): só ela.
ALTER TABLE user_account ADD COLUMN pdv_auth_mode text NOT NULL DEFAULT 'pin'
  CONSTRAINT user_account_pdv_auth_mode_check CHECK (pdv_auth_mode IN ('any', 'pin', 'face', 'fingerprint'));
CREATE OR REPLACE VIEW v_user_account WITH (security_invoker = true) AS
  SELECT * FROM user_account WHERE deleted_at IS NULL;

-- A forma de entrar só muda por app.set_user_auth_mode (que confere a permissão).
CREATE FUNCTION app.guard_pdv_auth_mode() RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF NEW.pdv_auth_mode IS DISTINCT FROM OLD.pdv_auth_mode AND CURRENT_USER = 'farmaerp_app' THEN
    RAISE EXCEPTION 'Você não tem permissão para esta operação.'
      USING ERRCODE = 'FA002', DETAIL = 'A forma de entrar no PDV muda só por set_user_auth_mode.';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER guard_pdv_auth_mode BEFORE UPDATE OF pdv_auth_mode ON user_account
  FOR EACH ROW EXECUTE FUNCTION app.guard_pdv_auth_mode();

ALTER TABLE auth_event DROP CONSTRAINT auth_event_event_type_check;
ALTER TABLE auth_event ADD CONSTRAINT auth_event_event_type_check CHECK (event_type IN (
  'login_success', 'login_failure', 'login_locked', 'logout', 'password_changed', 'password_reset', 'pin_set',
  'pdv_auth_mode_set'
));

INSERT INTO permission (code, module, name) VALUES
  ('users.release_login', 'Usuários', 'Liberar a entrada no PDV de quem não consegue usar a câmera ou a digital');
INSERT INTO role_permission (role_id, permission_id)
SELECT r.id, p.id
  FROM role r JOIN permission p ON p.code = 'users.release_login'
 WHERE r.deleted_at IS NULL AND r.system_key IS NULL AND r.name = 'Gerente'
   AND NOT EXISTS (
     SELECT 1 FROM role_permission rp WHERE rp.role_id = r.id AND rp.permission_id = p.id AND rp.deleted_at IS NULL
   );

-- Define a forma de entrar no PDV de outra pessoa. A regra é a mesma do PIN.
CREATE FUNCTION app.set_user_auth_mode(p_user_id uuid, p_mode text, p_ip text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.user_account;
BEGIN
  SELECT * INTO target FROM public.user_account u WHERE u.id = p_user_id AND u.deleted_at IS NULL FOR UPDATE;
  IF NOT FOUND
     OR NOT app.can_on_user('users.reset_password', p_user_id)
     OR NOT app.covers_user(p_user_id) THEN
    RAISE EXCEPTION 'Você não tem permissão para esta operação.'
      USING ERRCODE = 'FA002', DETAIL = pg_catalog.format('Forma de entrada de %s.', p_user_id);
  END IF;
  IF p_mode IS NULL OR p_mode NOT IN ('any', 'pin', 'face', 'fingerprint') THEN
    RAISE EXCEPTION 'Escolha uma forma de entrar no PDV válida.'
      USING ERRCODE = 'FA819', DETAIL = pg_catalog.format('Forma %s.', p_mode);
  END IF;
  IF NOT target.is_active THEN
    RAISE EXCEPTION 'O usuário informado não está ativo.'
      USING ERRCODE = 'FA209', DETAIL = pg_catalog.format('user_account %s inativo.', p_user_id);
  END IF;
  IF target.pdv_auth_mode = p_mode THEN
    RETURN;
  END IF;
  UPDATE public.user_account SET pdv_auth_mode = p_mode WHERE id = p_user_id;
  PERFORM app.record_auth_event(p_user_id, 'pdv_auth_mode_set', p_ip);
END;
$$;

-- Entradas e liberações feitas no PDV. Só sobem do terminal; ninguém altera.
CREATE TABLE pdv_auth_event (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  branch_id uuid NOT NULL REFERENCES branch (id),
  terminal_id uuid NOT NULL REFERENCES terminal (id),
  user_id uuid NOT NULL REFERENCES user_account (id),
  -- success: entrou ou liberou; failure: errou; locked: bloqueado por tentativas.
  event text NOT NULL CONSTRAINT pdv_auth_event_event_check CHECK (event IN ('success', 'failure', 'locked')),
  -- login: entrada no caixa; approval: liberação de outra pessoa; seller: vendedor que atende.
  purpose text NOT NULL CONSTRAINT pdv_auth_event_purpose_check CHECK (purpose IN ('login', 'approval', 'seller')),
  method text NOT NULL CONSTRAINT pdv_auth_event_method_check CHECK (method IN ('pin', 'face', 'fingerprint', 'manager_release')),
  authorized_by uuid REFERENCES user_account (id),
  occurred_at timestamptz NOT NULL,
  -- outside_mode: entrou por uma forma que não é a dela; release_permission: liberado por quem não podia.
  alert text CONSTRAINT pdv_auth_event_alert_check CHECK (alert IN ('outside_mode', 'release_permission')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid,
  CONSTRAINT pdv_auth_event_release_check CHECK ((method = 'manager_release') = (authorized_by IS NOT NULL)),
  CONSTRAINT pdv_auth_event_release_success_check CHECK (method <> 'manager_release' OR event = 'success'),
  CONSTRAINT pdv_auth_event_self_check CHECK (authorized_by IS NULL OR authorized_by <> user_id)
);
CREATE INDEX pdv_auth_event_branch_idx ON pdv_auth_event (branch_id, occurred_at DESC);
CREATE INDEX pdv_auth_event_user_idx ON pdv_auth_event (user_id, occurred_at DESC);
CALL app.apply_table_standard('public.pdv_auth_event');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON pdv_auth_event
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'branch_id', 'terminal_id', 'user_id', 'event', 'purpose', 'method', 'authorized_by',
    'occurred_at', 'alert'
  );
CREATE POLICY pdv_auth_event_select ON pdv_auth_event FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group()) AND app.has_permission('users.view', branch_id));
GRANT SELECT ON pdv_auth_event TO farmaerp_app;
CREATE VIEW v_pdv_auth_event WITH (security_invoker = true) AS
  SELECT * FROM pdv_auth_event WHERE deleted_at IS NULL;
GRANT SELECT ON v_pdv_auth_event TO farmaerp_app;

-- A forma configurada aceita este método?
CREATE FUNCTION app.auth_mode_allows(p_mode text, p_method text) RETURNS boolean
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$
  SELECT p_method = 'manager_release' OR p_mode = 'any' OR p_mode = p_method
$$;

-- Entrada, falha, bloqueio ou liberação vindos do PDV.
CREATE FUNCTION app.sync_apply_auth_event(p_terminal public.terminal, p_group_id uuid, p_payload jsonb)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  uuid_any constant text := '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
  event_id uuid;
  person public.user_account;
  authorizer uuid;
  method text := p_payload ->> 'method';
  found_alert text;
BEGIN
  IF (p_payload ->> 'id') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
     OR (p_payload ->> 'user_id') !~ uuid_any
     OR (p_payload ->> 'event') IS NULL OR (p_payload ->> 'event') NOT IN ('success', 'failure', 'locked')
     OR (p_payload ->> 'purpose') IS NULL OR (p_payload ->> 'purpose') NOT IN ('login', 'approval', 'seller')
     OR method IS NULL OR method NOT IN ('pin', 'face', 'fingerprint', 'manager_release')
     OR (p_payload ->> 'authorized_by') !~ uuid_any
     OR (method = 'manager_release') <> (p_payload ->> 'authorized_by' IS NOT NULL)
     OR (method = 'manager_release' AND (p_payload ->> 'event') <> 'success')
     OR p_payload ->> 'authorized_by' = p_payload ->> 'user_id'
     OR (p_payload ->> 'occurred_at') !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$' THEN
    RAISE EXCEPTION 'A venda enviada pelo terminal está inconsistente.'
      USING ERRCODE = 'FA962', DETAIL = 'Autenticação fora do formato.';
  END IF;
  event_id := (p_payload ->> 'id')::uuid;
  authorizer := (p_payload ->> 'authorized_by')::uuid;
  IF EXISTS (SELECT 1 FROM public.pdv_auth_event e WHERE e.id = event_id) THEN
    RAISE EXCEPTION 'Esta venda ou turno já foi recebido com outro registro.'
      USING ERRCODE = 'FA963', DETAIL = pg_catalog.format('pdv_auth_event %s.', event_id);
  END IF;
  SELECT u.* INTO person FROM public.user_account u
   WHERE u.id = (p_payload ->> 'user_id')::uuid AND u.economic_group_id = p_group_id;
  IF NOT FOUND OR (authorizer IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_account u WHERE u.id = authorizer AND u.economic_group_id = p_group_id
  )) THEN
    RAISE EXCEPTION 'Um dos itens informados não foi encontrado.'
      USING ERRCODE = 'FA004', DETAIL = 'Pessoa da autenticação fora do grupo.';
  END IF;
  found_alert := CASE
    WHEN authorizer IS NOT NULL AND NOT app.user_has_permission(authorizer, 'users.release_login', p_terminal.branch_id)
      THEN 'release_permission'
    WHEN (p_payload ->> 'event') = 'success' AND NOT app.auth_mode_allows(person.pdv_auth_mode, method)
      THEN 'outside_mode'
  END;
  BEGIN
    INSERT INTO public.pdv_auth_event (
      id, economic_group_id, branch_id, terminal_id, user_id, event, purpose, method, authorized_by, occurred_at, alert
    ) VALUES (
      event_id, p_group_id, p_terminal.branch_id, p_terminal.id, person.id, p_payload ->> 'event',
      p_payload ->> 'purpose', method, authorizer, (p_payload ->> 'occurred_at')::timestamptz, found_alert
    );
  EXCEPTION WHEN datetime_field_overflow OR invalid_datetime_format THEN
    RAISE EXCEPTION 'A venda enviada pelo terminal está inconsistente.'
      USING ERRCODE = 'FA962', DETAIL = 'Data da autenticação impossível.';
  END;
END;
$$;

-- Entradas no PDV para a retaguarda: por filial, período e só as marcadas.
CREATE FUNCTION app.list_pdv_auth_events(
  p_branch_id uuid DEFAULT NULL, p_from date DEFAULT NULL, p_to date DEFAULT NULL, p_only_alerts boolean DEFAULT false
)
RETURNS TABLE (
  id uuid, occurred_at timestamptz, branch_name text, terminal_name text, user_id uuid, user_code integer, user_name text,
  event text, purpose text, method text, authorized_by_name text, alert text
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT e.id, e.occurred_at, b.name, t.name, u.id, u.code, u.name, e.event, e.purpose, e.method, a.name, e.alert
    FROM public.pdv_auth_event e
    JOIN public.branch b ON b.id = e.branch_id
    JOIN public.terminal t ON t.id = e.terminal_id
    JOIN public.user_account u ON u.id = e.user_id
    LEFT JOIN public.user_account a ON a.id = e.authorized_by
   WHERE e.deleted_at IS NULL
     AND e.economic_group_id = app.current_user_group()
     AND app.has_permission('users.view', e.branch_id)
     AND (p_branch_id IS NULL OR e.branch_id = p_branch_id)
     AND (p_from IS NULL OR e.occurred_at >= p_from::timestamp AT TIME ZONE 'America/Sao_Paulo')
     AND (p_to IS NULL OR e.occurred_at < (p_to + 1)::timestamp AT TIME ZONE 'America/Sao_Paulo')
     AND (NOT COALESCE(p_only_alerts, false) OR e.alert IS NOT NULL)
   ORDER BY e.occurred_at DESC, e.id DESC
   LIMIT 500
$$;

-- Usuário com a forma de entrar no PDV.
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


-- Perfis padrão de um grupo novo, agora com a liberação da entrada no PDV para o Gerente.
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
     'users.release_login'
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


-- Subida do PDV, agora com as autenticações.
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
  app.set_user_auth_mode(uuid, text, text),
  app.list_pdv_auth_events(uuid, date, date, boolean)
TO farmaerp_app;
