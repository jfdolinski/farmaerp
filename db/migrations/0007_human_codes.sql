-- Up Migration

-- Código humano para tela e cupom. A identidade continua sendo o UUID.
-- Produto e cliente: sequência única por grupo econômico, gerada na central.
-- Venda: número do terminal + contador local, gerado no PDV mesmo offline (ex.: 2-000123).

CREATE TABLE code_counter (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  entity text NOT NULL CHECK (entity ~ '^[a-z][a-z_]{0,39}$'),
  last_value bigint NOT NULL CHECK (last_value >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE UNIQUE INDEX code_counter_economic_group_entity_active_key
  ON code_counter (economic_group_id, entity) WHERE deleted_at IS NULL;

CALL app.apply_table_standard('public.code_counter');

-- Os contadores só mudam pelos triggers: a API não recebe nenhuma permissão direta.
CREATE POLICY code_counter_select ON code_counter FOR SELECT TO farmaerp_app USING (false);
CREATE VIEW v_code_counter WITH (security_invoker = true) AS
  SELECT * FROM code_counter WHERE deleted_at IS NULL;

-- Próximo código. A linha do contador fica travada até o fim da transação: um cancelamento
-- desfaz o incremento e não deixa buraco. Concorrentes do mesmo contador esperam.
CREATE FUNCTION app.next_human_code(p_economic_group_id uuid, p_entity text) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  next_value bigint;
BEGIN
  IF p_economic_group_id IS NULL THEN
    RAISE EXCEPTION 'Não foi possível gerar o código do cadastro.'
      USING ERRCODE = 'FA108', DETAIL = pg_catalog.format('Contador %s sem grupo econômico.', p_entity);
  END IF;

  INSERT INTO public.code_counter (economic_group_id, entity, last_value)
  VALUES (p_economic_group_id, p_entity, 1)
  ON CONFLICT (economic_group_id, entity) WHERE deleted_at IS NULL DO UPDATE
    SET last_value = public.code_counter.last_value + 1
  RETURNING last_value INTO next_value;

  RETURN next_value;
END;
$$;

-- Trigger de inclusão. O valor enviado pela API é ignorado, como em updated_by.
-- Só a migração de dados (farmaerp_migrator) grava um código antigo, e o contador
-- avança para nunca gerar esse número de novo.
--
-- Atenção: trigger BEFORE roda antes da checagem de ON CONFLICT. Inclusões com
-- ON CONFLICT DO NOTHING consomem um número e deixam buraco, embora nunca repitam código.
-- Na sincronização da Etapa 3, confira se o UUID já existe antes de incluir.
CREATE FUNCTION app.assign_human_code() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  row_data jsonb := pg_catalog.to_jsonb(NEW);
  group_id uuid := (row_data ->> 'economic_group_id')::uuid;
  provided_code bigint := (row_data ->> 'code')::bigint;
BEGIN
  IF provided_code IS NOT NULL AND session_user = 'farmaerp_migrator' THEN
    INSERT INTO public.code_counter (economic_group_id, entity, last_value)
    VALUES (group_id, TG_ARGV[0], provided_code)
    ON CONFLICT (economic_group_id, entity) WHERE deleted_at IS NULL DO UPDATE
      SET last_value = GREATEST(public.code_counter.last_value, EXCLUDED.last_value);
    RETURN NEW;
  END IF;

  NEW := pg_catalog.jsonb_populate_record(
    NEW,
    pg_catalog.jsonb_build_object('code', app.next_human_code(group_id, TG_ARGV[0]))
  );
  RETURN NEW;
END;
$$;

-- Aplica o código humano a uma tabela. Usar nas tabelas de produto e cliente da Etapa 2.
-- O índice não é parcial: um código nunca é reaproveitado, mesmo após a exclusão lógica.
CREATE PROCEDURE app.apply_human_code(target regclass, entity text)
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  table_name text := (SELECT c.relname FROM pg_catalog.pg_class c WHERE c.oid = target);
  missing_columns text;
BEGIN
  SELECT pg_catalog.string_agg(required.column_name, ', ' ORDER BY required.position)
    INTO missing_columns
    FROM pg_catalog.unnest(ARRAY['code', 'economic_group_id'])
      WITH ORDINALITY AS required(column_name, position)
   WHERE NOT EXISTS (
     SELECT 1
       FROM pg_catalog.pg_attribute a
      WHERE a.attrelid = target
        AND a.attname = required.column_name
        AND NOT a.attisdropped
   );

  IF missing_columns IS NOT NULL THEN
    RAISE EXCEPTION 'Tabela % sem as colunas obrigatórias: %', target, missing_columns;
  END IF;

  EXECUTE pg_catalog.format(
    'CREATE UNIQUE INDEX %I ON %s (economic_group_id, code)', table_name || '_code_key', target);
  EXECUTE pg_catalog.format(
    'CREATE TRIGGER assign_human_code BEFORE INSERT ON %s
       FOR EACH ROW EXECUTE FUNCTION app.assign_human_code(%L)', target, entity);
  EXECUTE pg_catalog.format(
    'CREATE TRIGGER block_human_code_change BEFORE UPDATE ON %s
       FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(''code'')', target);
END;
$$;

-- Número curto do terminal, único na filial e nunca reaproveitado.
ALTER TABLE terminal ADD COLUMN number smallint CHECK (number BETWEEN 1 AND 999);

-- Terminais já aprovados recebem número pela ordem de criação. Revogado sem nome nunca foi aprovado.
UPDATE terminal t
   SET number = numbered.value
  FROM (
    SELECT id, row_number() OVER (PARTITION BY branch_id ORDER BY created_at, id) AS value
      FROM terminal
     WHERE name IS NOT NULL
  ) numbered
 WHERE numbered.id = t.id;

CREATE UNIQUE INDEX terminal_branch_number_key ON terminal (branch_id, number);

ALTER TABLE terminal ADD CONSTRAINT terminal_active_has_number CHECK (
  status IN ('pending', 'revoked') OR number IS NOT NULL
);

-- Atribui o número na aprovação. Terminais excluídos entram na conta, por isso nada se repete.
-- A trava consultiva não conflita com o FOR SHARE das validações na filial.
CREATE FUNCTION app.assign_terminal_number() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.number IS DISTINCT FROM OLD.number AND OLD.number IS NOT NULL THEN
    RAISE EXCEPTION 'Este dado não pode ser alterado depois do cadastro.'
      USING ERRCODE = 'FA104', DETAIL = pg_catalog.format('Alteração de number no terminal %s.', NEW.id);
  END IF;

  IF NEW.number IS NULL AND NEW.status IN ('active', 'blocked') THEN
    PERFORM pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended('terminal_number:' || NEW.branch_id::text, 0));

    SELECT COALESCE(MAX(t.number), 0) + 1 INTO NEW.number
      FROM public.terminal t
     WHERE t.branch_id = NEW.branch_id;

    IF NEW.number > 999 THEN
      RAISE EXCEPTION 'Esta filial atingiu o limite de terminais.'
        USING ERRCODE = 'FA311', DETAIL = pg_catalog.format('Filial %s com 999 terminais.', NEW.branch_id);
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER assign_terminal_number BEFORE INSERT OR UPDATE ON terminal
  FOR EACH ROW EXECUTE FUNCTION app.assign_terminal_number();

-- security_invoker precisa ser repetido: CREATE OR REPLACE substitui as opções da view.
CREATE OR REPLACE VIEW v_terminal WITH (security_invoker = true) AS
  SELECT * FROM terminal WHERE deleted_at IS NULL;

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
    t.number
  FROM terminal t
  JOIN branch b ON b.id = t.branch_id
  LEFT JOIN terminal_status s ON s.terminal_id = t.id AND s.deleted_at IS NULL
  LEFT JOIN terminal_pairing_request r ON r.terminal_id = t.id AND r.deleted_at IS NULL
  WHERE t.deleted_at IS NULL;

-- O aparelho precisa conhecer o próprio número para montar o código das vendas.
CREATE OR REPLACE FUNCTION app.get_pairing_status(p_request_id uuid, p_public_key text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  request public.terminal_pairing_request;
  current_status text;
  current_number smallint;
BEGIN
  SELECT * INTO request
    FROM public.terminal_pairing_request r
   WHERE r.id = p_request_id AND r.public_key = p_public_key AND r.deleted_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Código não encontrado ou expirado.'
      USING ERRCODE = 'FA301', DETAIL = pg_catalog.format('Solicitação %s.', p_request_id);
  END IF;

  SELECT t.status, t.number INTO current_status, current_number
    FROM public.terminal t WHERE t.id = request.terminal_id;

  RETURN pg_catalog.jsonb_build_object(
    'status', CASE
      WHEN request.status = 'waiting' AND request.expires_at <= pg_catalog.now() THEN 'expired'
      ELSE request.status
    END,
    'terminalId', request.terminal_id,
    'terminalStatus', current_status,
    'terminalNumber', current_number
  );
END;
$$;

CREATE OR REPLACE FUNCTION app.terminal_auth_info(p_terminal_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT pg_catalog.jsonb_build_object('publicKey', t.public_key, 'status', t.status, 'number', t.number)
    FROM public.terminal t
   WHERE t.id = p_terminal_id AND t.deleted_at IS NULL
$$;

REVOKE ALL ON FUNCTION app.next_human_code(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.assign_human_code() FROM PUBLIC;
REVOKE ALL ON FUNCTION app.assign_terminal_number() FROM PUBLIC;
REVOKE ALL ON PROCEDURE app.apply_human_code(regclass, text) FROM PUBLIC;
