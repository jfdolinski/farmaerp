-- Up Migration

-- Reaplicar conflitos de sincronização. Um item que a central recusou (por exemplo, um tipo que a
-- API ainda não conhecia porque o PDV foi atualizado antes) pode ser aplicado de novo pela
-- retaguarda, com o mesmo conteúdo que chegou e em nome do terminal de origem. Se passar, o recibo
-- vira "applied" e o conflito fica resolvido; se o banco recusar de novo, o conflito continua aberto
-- com o motivo da última tentativa. A aplicação de cada tipo sai do pdv_push para app.pdv_apply_item,
-- usada pelos dois caminhos.
-- O cadastro do rosto que chega atrasado não passa por cima de um rosto mais novo nem volta depois
-- de a pessoa revogar o consentimento (FA833). A lista de conflitos não mostra mais o modelo do rosto.

ALTER TABLE sync_conflict ADD COLUMN last_retry_at timestamptz;
ALTER TABLE sync_conflict ADD COLUMN last_retry_by uuid REFERENCES user_account (id);
ALTER TABLE sync_conflict ADD COLUMN last_retry_code text
  CONSTRAINT sync_conflict_last_retry_code_check CHECK (last_retry_code ~ '^FA[0-9]{3}$');
ALTER TABLE sync_conflict ADD CONSTRAINT sync_conflict_last_retry_check CHECK (
  (last_retry_at IS NULL) = (last_retry_by IS NULL) AND (last_retry_code IS NULL OR last_retry_at IS NOT NULL)
);
CREATE INDEX sync_conflict_last_retry_by_idx ON sync_conflict (last_retry_by);
CREATE OR REPLACE VIEW v_sync_conflict WITH (security_invoker = true) AS
  SELECT * FROM sync_conflict WHERE deleted_at IS NULL;

-- O recibo continua imutável; a situação só pode ir de conflito para aplicado (reaplicação).
DROP TRIGGER block_immutable_columns ON sync_receipt;
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON sync_receipt
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'branch_id', 'terminal_id', 'kind', 'sequence'
  );

CREATE FUNCTION app.guard_sync_receipt_status() RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF NEW.status IS DISTINCT FROM OLD.status AND NOT (OLD.status = 'conflict' AND NEW.status = 'applied') THEN
    RAISE EXCEPTION 'Este dado não pode ser alterado depois do cadastro.'
      USING ERRCODE = 'FA104',
            DETAIL = pg_catalog.format('Recibo %s de %s para %s.', OLD.id, OLD.status, NEW.status);
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER guard_sync_receipt_status BEFORE UPDATE ON sync_receipt
  FOR EACH ROW EXECUTE FUNCTION app.guard_sync_receipt_status();

-- Aplica um item da subida conforme o tipo. Erro do catálogo (FA) é decisão do banco e vira conflito
-- em quem chama; o terminal é sempre o de origem do item.
CREATE FUNCTION app.pdv_apply_item(
  p_terminal public.terminal, p_group_id uuid, p_kind text, p_item_id uuid, p_payload jsonb
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  CASE p_kind
    WHEN 'log' THEN
      PERFORM app.sync_apply_log(p_terminal, p_group_id, p_item_id, p_payload);
    WHEN 'cash_session_open' THEN
      PERFORM app.sync_apply_cash_open(p_terminal, p_group_id, p_payload);
    WHEN 'sale' THEN
      PERFORM app.sync_apply_sale(p_terminal, p_group_id, p_payload);
    WHEN 'sale_return' THEN
      PERFORM app.sync_apply_return(p_terminal, p_group_id, p_payload);
    WHEN 'quote' THEN
      PERFORM app.sync_apply_quote(p_terminal, p_group_id, p_payload);
    WHEN 'cash_movement' THEN
      PERFORM app.sync_apply_cash_movement(p_terminal, p_group_id, p_payload);
    WHEN 'cash_session_close' THEN
      PERFORM app.sync_apply_cash_close(p_terminal, p_group_id, p_payload);
    WHEN 'auth_event' THEN
      PERFORM app.sync_apply_auth_event(p_terminal, p_group_id, p_payload);
    WHEN 'face_enrollment' THEN
      PERFORM app.sync_apply_face_enrollment(p_terminal, p_group_id, p_payload);
    ELSE
      RAISE EXCEPTION 'O terminal enviou um tipo de registro desconhecido.'
        USING ERRCODE = 'FA959', DETAIL = pg_catalog.format('Tipo %s.', p_kind);
  END CASE;
END;
$$;

-- Subida do PDV, aplicando cada item por app.pdv_apply_item.
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
        'code', (SELECT c.error_code FROM public.sync_conflict c
                  WHERE c.receipt_id = item_id AND c.deleted_at IS NULL AND existing.status = 'conflict')
      ));
      CONTINUE;
    END IF;

    outcome := 'applied';
    failure_code := NULL;
    failure_message := NULL;
    BEGIN
      PERFORM app.pdv_apply_item(terminal_row, group_id, item ->> 'kind', item_id, item -> 'payload');
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

CREATE OR REPLACE FUNCTION app.sync_apply_face_enrollment(p_terminal public.terminal, p_group_id uuid, p_payload jsonb)
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
    -- Cadastro que chega atrasado (de outro terminal ou reaplicado pela retaguarda) não substitui um
    -- rosto mais novo e não volta depois de a pessoa revogar o consentimento.
    IF EXISTS (
         SELECT 1 FROM public.face_template f
          WHERE f.user_id = person.id AND f.enrolled_at > (p_payload ->> 'enrolled_at')::timestamptz
       ) OR EXISTS (
         SELECT 1 FROM public.biometric_consent c
          WHERE c.user_id = person.id AND c.kind = 'face' AND c.revoked_at > (p_payload ->> 'enrolled_at')::timestamptz
       ) THEN
      RAISE EXCEPTION 'Este cadastro do rosto ficou para trás.'
        USING ERRCODE = 'FA833', DETAIL = pg_catalog.format('Rosto %s de %s.', p_payload ->> 'id', person.id);
    END IF;
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

-- Conflitos das filiais que a pessoa pode ver, com a última reaplicação.
DROP FUNCTION app.list_sync_conflicts(text, uuid);
CREATE FUNCTION app.list_sync_conflicts(p_status text DEFAULT 'open', p_branch_id uuid DEFAULT NULL)
RETURNS TABLE (
  id uuid, branch_id uuid, branch_name text, terminal_id uuid, terminal_name text, kind text, error_code text,
  detail text, payload jsonb, status text, created_at timestamptz, resolved_at timestamptz, resolved_by_name text,
  resolution_note text, can_resolve boolean, last_retry_at timestamptz, last_retry_by_name text, last_retry_code text
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT c.id, c.branch_id, b.name, c.terminal_id, t.name, c.kind, c.error_code, c.detail,
         -- O modelo do rosto é dado biométrico: não sai na lista.
         CASE WHEN c.payload ? 'template' THEN c.payload || '{"template": "(oculto)"}'::jsonb ELSE c.payload END,
         c.status, c.created_at, c.resolved_at, u.name, c.resolution_note, app.has_permission('sync.resolve', c.branch_id),
         c.last_retry_at, rb.name, c.last_retry_code
    FROM public.sync_conflict c
    JOIN public.branch b ON b.id = c.branch_id
    JOIN public.terminal t ON t.id = c.terminal_id
    LEFT JOIN public.user_account u ON u.id = c.resolved_by
    LEFT JOIN public.user_account rb ON rb.id = c.last_retry_by
   WHERE c.deleted_at IS NULL
     AND c.economic_group_id = app.current_user_group()
     AND app.has_permission('sync.view', c.branch_id)
     AND (p_status IS NULL OR c.status = p_status)
     AND (p_branch_id IS NULL OR c.branch_id = p_branch_id)
   ORDER BY c.created_at DESC, c.id DESC
   LIMIT 200
$$;

-- Aplica de novo o item do conflito, com o conteúdo que chegou e em nome do terminal de origem.
-- Devolve {"status": "applied"} ou {"status": "conflict", "code": "FA..."}; nos dois casos a
-- tentativa fica registrada. Erro fora do catálogo é falha e desfaz tudo.
CREATE FUNCTION app.retry_sync_conflict(p_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.sync_conflict;
  terminal_row public.terminal;
  failure_code text;
  actor uuid := app.current_user_id();
  moment timestamptz := pg_catalog.clock_timestamp();
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
  IF target.status <> 'open' THEN
    RAISE EXCEPTION 'Não foi possível registrar a solução do conflito.'
      USING ERRCODE = 'FA960', DETAIL = pg_catalog.format('sync_conflict %s em %s.', p_id, target.status);
  END IF;
  PERFORM 1 FROM public.sync_receipt r WHERE r.id = target.receipt_id FOR UPDATE;
  SELECT t.* INTO terminal_row FROM public.terminal t WHERE t.id = target.terminal_id;

  BEGIN
    PERFORM app.pdv_apply_item(terminal_row, target.economic_group_id, target.kind, target.receipt_id, target.payload);
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE !~ '^FA[0-9]{3}$' THEN
      RAISE;
    END IF;
    failure_code := SQLSTATE;
  END;

  IF failure_code IS NOT NULL THEN
    UPDATE public.sync_conflict
       SET last_retry_at = moment, last_retry_by = actor, last_retry_code = failure_code
     WHERE id = p_id;
    RETURN pg_catalog.jsonb_build_object('status', 'conflict', 'code', failure_code);
  END IF;
  UPDATE public.sync_receipt SET status = 'applied' WHERE id = target.receipt_id;
  UPDATE public.sync_conflict
     SET status = 'resolved', resolved_at = moment, resolved_by = actor,
         resolution_note = 'Reaplicado com sucesso pela retaguarda.',
         last_retry_at = moment, last_retry_by = actor, last_retry_code = NULL
   WHERE id = p_id;
  RETURN pg_catalog.jsonb_build_object('status', 'applied');
END;
$$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  app.list_sync_conflicts(text, uuid),
  app.retry_sync_conflict(uuid)
TO farmaerp_app;
