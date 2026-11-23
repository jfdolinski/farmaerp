-- Up Migration

-- Subida do PDV para a central. O PDV grava cada item na outbox local, na mesma transação da
-- operação, e envia em ordem. O UUID do item é o recibo: reenvio não aplica de novo. Quem decide
-- é o banco: item que não pode ser aplicado vira conflito, visível na retaguarda, e a fila segue.
-- O primeiro tipo são os logs do PDV (avisos e erros, sem dados pessoais).

CREATE TABLE sync_receipt (
  -- O id da outbox do PDV.
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  branch_id uuid NOT NULL REFERENCES branch (id),
  terminal_id uuid NOT NULL REFERENCES terminal (id),
  kind text NOT NULL CONSTRAINT sync_receipt_kind_check CHECK (kind ~ '^[a-z_]{1,40}$'),
  -- Ordem do item no terminal.
  sequence bigint NOT NULL CONSTRAINT sync_receipt_sequence_check CHECK (sequence > 0),
  status text NOT NULL CONSTRAINT sync_receipt_status_check CHECK (status IN ('applied', 'conflict')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE INDEX sync_receipt_terminal_idx ON sync_receipt (terminal_id, sequence);
CREATE INDEX sync_receipt_economic_group_id_idx ON sync_receipt (economic_group_id);
CREATE INDEX sync_receipt_branch_id_idx ON sync_receipt (branch_id);

CREATE TABLE sync_conflict (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  branch_id uuid NOT NULL REFERENCES branch (id),
  terminal_id uuid NOT NULL REFERENCES terminal (id),
  receipt_id uuid NOT NULL REFERENCES sync_receipt (id),
  kind text NOT NULL,
  error_code text NOT NULL CONSTRAINT sync_conflict_error_code_check CHECK (error_code ~ '^FA[0-9]{3}$'),
  detail text,
  payload jsonb NOT NULL,
  status text NOT NULL DEFAULT 'open' CONSTRAINT sync_conflict_status_check CHECK (status IN ('open', 'resolved')),
  resolved_at timestamptz,
  resolved_by uuid REFERENCES user_account (id),
  resolution_note text CONSTRAINT sync_conflict_note_check CHECK (length(resolution_note) BETWEEN 1 AND 500),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid,
  CONSTRAINT sync_conflict_resolution_check CHECK (
    (status = 'open' AND resolved_at IS NULL AND resolved_by IS NULL AND resolution_note IS NULL)
    OR (status = 'resolved' AND resolved_at IS NOT NULL AND resolved_by IS NOT NULL AND resolution_note IS NOT NULL)
  )
);
CREATE UNIQUE INDEX sync_conflict_receipt_key ON sync_conflict (receipt_id) WHERE deleted_at IS NULL;
CREATE INDEX sync_conflict_open_idx ON sync_conflict (branch_id, created_at) WHERE status = 'open' AND deleted_at IS NULL;
CREATE INDEX sync_conflict_economic_group_id_idx ON sync_conflict (economic_group_id);
CREATE INDEX sync_conflict_terminal_id_idx ON sync_conflict (terminal_id);
CREATE INDEX sync_conflict_resolved_by_idx ON sync_conflict (resolved_by);

-- Avisos e erros do PDV. O id é o da outbox.
CREATE TABLE terminal_log (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  branch_id uuid NOT NULL REFERENCES branch (id),
  terminal_id uuid NOT NULL REFERENCES terminal (id),
  level text NOT NULL CONSTRAINT terminal_log_level_check CHECK (level IN ('warn', 'error')),
  logged_at timestamptz NOT NULL,
  message text NOT NULL CONSTRAINT terminal_log_message_check CHECK (length(message) BETWEEN 1 AND 500),
  error_code text CONSTRAINT terminal_log_error_code_check CHECK (error_code ~ '^FA[0-9]{3}$'),
  -- O rastreio da operação no PDV; trace_id (padrão) é o da requisição que trouxe o log.
  entry_trace_id uuid,
  app_version text CONSTRAINT terminal_log_app_version_check CHECK (length(app_version) <= 50),
  fields jsonb NOT NULL DEFAULT '{}'::jsonb CONSTRAINT terminal_log_fields_check CHECK (
    pg_catalog.jsonb_typeof(fields) = 'object' AND octet_length(fields::text) <= 8192
  ),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE INDEX terminal_log_terminal_idx ON terminal_log (terminal_id, logged_at);
CREATE INDEX terminal_log_entry_trace_idx ON terminal_log (entry_trace_id);
CREATE INDEX terminal_log_economic_group_id_idx ON terminal_log (economic_group_id);
CREATE INDEX terminal_log_branch_id_idx ON terminal_log (branch_id);

CALL app.apply_table_standard('public.sync_receipt');
CALL app.apply_table_standard('public.sync_conflict');
CALL app.apply_table_standard('public.terminal_log');

-- Recibo e log não mudam depois de gravados; o conflito só muda pela solução.
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON sync_receipt
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'branch_id', 'terminal_id', 'kind', 'sequence', 'status'
  );
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON terminal_log
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'branch_id', 'terminal_id', 'level', 'logged_at', 'message', 'error_code',
    'entry_trace_id', 'app_version', 'fields'
  );
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON sync_conflict
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'branch_id', 'terminal_id', 'receipt_id', 'kind', 'error_code', 'detail', 'payload'
  );

INSERT INTO permission (code, module, name) VALUES
  ('sync.view', 'Terminais', 'Ver os conflitos de sincronização'),
  ('sync.resolve', 'Terminais', 'Resolver os conflitos de sincronização');

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
    (p_group_id, 'Farmacêutico', 'As permissões chegam com o SNGPC.'),
    (p_group_id, 'Operador de caixa', 'As permissões chegam com o PDV.');

  -- A liberação do custo e o desconto acima do produto ficam só com o Administrador.
  INSERT INTO public.role_permission (role_id, permission_id)
  SELECT manager_id, p.id
    FROM public.permission p
   WHERE p.code IN (
     'users.view', 'users.reset_password', 'terminals.view', 'terminals.request', 'terminals.block',
     'products.view', 'stock.view', 'stock.loss', 'stock.transfer', 'stock.batch_override',
     'customers.view', 'customers.manage', 'fiscal.certificate', 'purchases.view', 'purchases.manage',
     'purchases.post', 'releases.view', 'sync.view', 'sync.resolve'
   );
  PERFORM app.seed_manager_limits(manager_id, p_group_id);
END;
$$;

-- Grupos que já existem: o Gerente, identificado pelo nome, vê e resolve os conflitos.
INSERT INTO role_permission (role_id, permission_id)
SELECT r.id, p.id
  FROM role r
 CROSS JOIN permission p
 WHERE r.name = 'Gerente' AND r.deleted_at IS NULL AND r.system_key IS NULL AND p.code IN ('sync.view', 'sync.resolve')
   AND NOT EXISTS (
     SELECT 1 FROM role_permission rp WHERE rp.role_id = r.id AND rp.permission_id = p.id AND rp.deleted_at IS NULL
   );

-- O terminal autenticado na transação, se puder operar.
CREATE FUNCTION app.require_active_terminal() RETURNS public.terminal
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  terminal_row public.terminal;
BEGIN
  SELECT t.* INTO terminal_row FROM public.terminal t
   WHERE t.id = app.current_terminal_id() AND t.deleted_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Não foi possível confirmar a identidade do terminal.'
      USING ERRCODE = 'FA306', DETAIL = 'Sincronização sem app.terminal_id válido.';
  ELSIF terminal_row.status = 'pending' THEN
    RAISE EXCEPTION 'Este terminal ainda não foi aprovado.' USING ERRCODE = 'FA307';
  ELSIF terminal_row.status = 'blocked' THEN
    RAISE EXCEPTION 'Este terminal está bloqueado.' USING ERRCODE = 'FA304';
  ELSIF terminal_row.status = 'revoked' THEN
    RAISE EXCEPTION 'Este terminal foi revogado.' USING ERRCODE = 'FA305';
  END IF;
  RETURN terminal_row;
END;
$$;

-- Log do PDV: só aviso e erro, com tamanho limitado. Fora disso vira conflito (FA958).
CREATE FUNCTION app.sync_apply_log(p_terminal public.terminal, p_group_id uuid, p_id uuid, p_payload jsonb)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  logged_at timestamptz;
BEGIN
  IF p_payload ->> 'level' IS NULL OR p_payload ->> 'level' NOT IN ('warn', 'error')
     OR pg_catalog.length(COALESCE(p_payload ->> 'msg', '')) NOT BETWEEN 1 AND 500
     OR (p_payload ->> 'error_code') !~ '^FA[0-9]{3}$'
     OR (p_payload ->> 'trace_id') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
     OR pg_catalog.length(p_payload ->> 'version') > 50
     OR pg_catalog.jsonb_typeof(COALESCE(p_payload -> 'fields', '{}'::jsonb)) <> 'object'
     OR octet_length(COALESCE(p_payload -> 'fields', '{}'::jsonb)::text) > 8192
     OR p_payload ->> 'time' IS NULL
     OR (p_payload ->> 'time') !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$' THEN
    RAISE EXCEPTION 'O registro enviado pelo terminal é inválido.'
      USING ERRCODE = 'FA958', DETAIL = 'Log do terminal fora do formato.';
  END IF;
  -- Formato certo com data impossível (mês 13, por exemplo) também é conflito, e não falha do pacote:
  -- senão o item travaria a fila do PDV para sempre.
  BEGIN
    logged_at := (p_payload ->> 'time')::timestamptz;
  EXCEPTION WHEN datetime_field_overflow OR invalid_datetime_format THEN
    RAISE EXCEPTION 'O registro enviado pelo terminal é inválido.'
      USING ERRCODE = 'FA958', DETAIL = 'Data do log impossível.';
  END;
  -- Relógio do aparelho muito fora: o log não é confiável para a investigação.
  IF logged_at < pg_catalog.now() - interval '400 days' OR logged_at > pg_catalog.now() + interval '1 day' THEN
    RAISE EXCEPTION 'O registro enviado pelo terminal é inválido.'
      USING ERRCODE = 'FA958', DETAIL = 'Data do log fora do intervalo aceito.';
  END IF;
  INSERT INTO public.terminal_log (
    id, economic_group_id, branch_id, terminal_id, level, logged_at, message, error_code, entry_trace_id,
    app_version, fields
  ) VALUES (
    p_id, p_group_id, p_terminal.branch_id, p_terminal.id, p_payload ->> 'level', logged_at, p_payload ->> 'msg',
    p_payload ->> 'error_code', (p_payload ->> 'trace_id')::uuid, p_payload ->> 'version',
    COALESCE(p_payload -> 'fields', '{}'::jsonb)
  );
END;
$$;

-- Subida para o terminal autenticado. p_items: [{ id, sequence, kind, payload }], em ordem.
-- Devolve { results: [{ id, status, code }] }: applied, conflict (com o código) ou duplicate
-- (já recebido antes; result traz como ficou).
CREATE FUNCTION app.pdv_push(p_items jsonb) RETURNS jsonb
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

  RETURN pg_catalog.jsonb_build_object('results', results);
END;
$$;

-- Conflitos das filiais que a pessoa pode ver, mais recentes primeiro.
CREATE FUNCTION app.list_sync_conflicts(p_status text DEFAULT 'open', p_branch_id uuid DEFAULT NULL)
RETURNS TABLE (
  id uuid, branch_id uuid, branch_name text, terminal_id uuid, terminal_name text, kind text, error_code text,
  detail text, payload jsonb, status text, created_at timestamptz, resolved_at timestamptz, resolved_by_name text,
  resolution_note text, can_resolve boolean
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT c.id, c.branch_id, b.name, c.terminal_id, t.name, c.kind, c.error_code, c.detail, c.payload, c.status,
         c.created_at, c.resolved_at, u.name, c.resolution_note, app.has_permission('sync.resolve', c.branch_id)
    FROM public.sync_conflict c
    JOIN public.branch b ON b.id = c.branch_id
    JOIN public.terminal t ON t.id = c.terminal_id
    LEFT JOIN public.user_account u ON u.id = c.resolved_by
   WHERE c.deleted_at IS NULL
     AND c.economic_group_id = app.current_user_group()
     AND app.has_permission('sync.view', c.branch_id)
     AND (p_status IS NULL OR c.status = p_status)
     AND (p_branch_id IS NULL OR c.branch_id = p_branch_id)
   ORDER BY c.created_at DESC, c.id DESC
   LIMIT 200
$$;

-- Marca o conflito como resolvido, com a explicação de quem resolveu.
CREATE FUNCTION app.resolve_sync_conflict(p_id uuid, p_note text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.sync_conflict;
  note text := pg_catalog.btrim(COALESCE(p_note, ''));
BEGIN
  SELECT c.* INTO target FROM public.sync_conflict c
   WHERE c.id = p_id AND c.deleted_at IS NULL AND c.economic_group_id = app.current_user_group()
     AND app.has_permission('sync.view', c.branch_id)
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('sync_conflict %s.', p_id);
  END IF;
  PERFORM app.require_branch_permission('sync.resolve', target.branch_id);
  IF note = '' THEN
    RAISE EXCEPTION 'Informe o motivo desta ação.' USING ERRCODE = 'FA302';
  END IF;
  IF pg_catalog.length(note) > 500 OR target.status <> 'open' THEN
    RAISE EXCEPTION 'Não foi possível registrar a solução do conflito.'
      USING ERRCODE = 'FA960', DETAIL = pg_catalog.format('sync_conflict %s em %s.', p_id, target.status);
  END IF;
  UPDATE public.sync_conflict
     SET status = 'resolved', resolved_at = pg_catalog.clock_timestamp(), resolved_by = app.current_user_id(),
         resolution_note = note
   WHERE id = p_id;
END;
$$;

-- Recibos e logs só pelas funções. Conflitos: quem vê a sincronização da filial.
CREATE POLICY sync_receipt_select ON sync_receipt FOR SELECT TO farmaerp_app USING (false);
CREATE POLICY terminal_log_select ON terminal_log FOR SELECT TO farmaerp_app USING (false);
CREATE POLICY sync_conflict_select ON sync_conflict FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group()) AND app.has_permission('sync.view', branch_id));
GRANT SELECT ON sync_conflict TO farmaerp_app;

CREATE VIEW v_sync_receipt WITH (security_invoker = true) AS
  SELECT * FROM sync_receipt WHERE deleted_at IS NULL;
CREATE VIEW v_terminal_log WITH (security_invoker = true) AS
  SELECT * FROM terminal_log WHERE deleted_at IS NULL;
CREATE VIEW v_sync_conflict WITH (security_invoker = true) AS
  SELECT * FROM sync_conflict WHERE deleted_at IS NULL;
GRANT SELECT ON v_sync_conflict TO farmaerp_app;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  app.pdv_push(jsonb),
  app.list_sync_conflicts(text, uuid),
  app.resolve_sync_conflict(uuid, text)
TO farmaerp_app;
