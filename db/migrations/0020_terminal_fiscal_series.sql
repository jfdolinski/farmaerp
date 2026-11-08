-- Up Migration

-- Séries da NFC-e (65) e da NF-e (55) amarradas a cada terminal. A numeração em si é reservada no
-- PDV, na Etapa 3: aqui ficam a série, o número inicial e o último número que o PDV informar.

CREATE TABLE terminal_fiscal_series (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  branch_id uuid NOT NULL REFERENCES branch (id),
  terminal_id uuid NOT NULL REFERENCES terminal (id),
  model text NOT NULL CONSTRAINT terminal_fiscal_series_model_check CHECK (model IN ('55', '65')),
  -- As faixas acima de 889 são reservadas: 890 a 899 para nota avulsa e 900 a 999 para contingência.
  series integer NOT NULL CONSTRAINT terminal_fiscal_series_series_check CHECK (series BETWEEN 1 AND 889),
  initial_number bigint NOT NULL DEFAULT 1 CONSTRAINT terminal_fiscal_series_initial_number_check CHECK (initial_number BETWEEN 1 AND 999999999),
  last_used_number bigint CONSTRAINT terminal_fiscal_series_last_used_check CHECK (last_used_number BETWEEN 1 AND 999999999),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
-- Conta as encerradas de propósito: a série de um terminal revogado não volta, para não repetir número.
CREATE UNIQUE INDEX terminal_fiscal_series_branch_series_key ON terminal_fiscal_series (branch_id, model, series);
CREATE UNIQUE INDEX terminal_fiscal_series_terminal_active_key ON terminal_fiscal_series (terminal_id, model) WHERE deleted_at IS NULL;
CREATE INDEX terminal_fiscal_series_terminal_idx ON terminal_fiscal_series (terminal_id);
CALL app.apply_table_standard('public.terminal_fiscal_series');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON terminal_fiscal_series
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns('economic_group_id', 'branch_id', 'terminal_id', 'model');

-- Histórico de cada ajuste de série ou de número inicial.
CREATE TABLE terminal_fiscal_series_event (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  series_id uuid NOT NULL REFERENCES terminal_fiscal_series (id),
  from_series integer NOT NULL,
  to_series integer NOT NULL,
  from_initial_number bigint NOT NULL,
  to_initial_number bigint NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE INDEX terminal_fiscal_series_event_series_idx ON terminal_fiscal_series_event (series_id);
CALL app.apply_table_standard('public.terminal_fiscal_series_event');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON terminal_fiscal_series_event
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'series_id', 'from_series', 'to_series', 'from_initial_number', 'to_initial_number'
  );

-- Depois do primeiro número usado, série e número inicial não mudam, e o último número só anda para a frente.
CREATE FUNCTION app.guard_terminal_series() RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF OLD.last_used_number IS NOT NULL AND (
    NEW.series IS DISTINCT FROM OLD.series
    OR NEW.initial_number IS DISTINCT FROM OLD.initial_number
    OR NEW.last_used_number IS NULL
    OR NEW.last_used_number < OLD.last_used_number
  ) THEN
    RAISE EXCEPTION 'Esta série já foi usada e não pode mais mudar.'
      USING ERRCODE = 'FA920', DETAIL = pg_catalog.format('Série %s.', OLD.id);
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER guard_terminal_series BEFORE UPDATE ON terminal_fiscal_series
  FOR EACH ROW EXECUTE FUNCTION app.guard_terminal_series();

CREATE FUNCTION app.record_terminal_series_change() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NEW.series <> OLD.series OR NEW.initial_number <> OLD.initial_number THEN
    INSERT INTO public.terminal_fiscal_series_event (
      economic_group_id, series_id, from_series, to_series, from_initial_number, to_initial_number
    ) VALUES (
      NEW.economic_group_id, NEW.id, OLD.series, NEW.series, OLD.initial_number, NEW.initial_number
    );
  END IF;
  RETURN NULL;
END;
$$;
CREATE TRIGGER record_terminal_series_change AFTER UPDATE ON terminal_fiscal_series
  FOR EACH ROW EXECUTE FUNCTION app.record_terminal_series_change();

-- Trava por filial, para escolher a série livre sem disputar com outra aprovação ou com um ajuste.
CREATE FUNCTION app.lock_branch_series(p_branch_id uuid) RETURNS void
LANGUAGE sql
SET search_path = ''
AS $$
  SELECT pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('terminal_series:' || p_branch_id::text, 0))
$$;

-- A série padrão é o número do terminal. Ocupada, usa a próxima livre e, por fim, a menor livre.
CREATE FUNCTION app.free_series(p_branch_id uuid, p_model text, p_preferred integer) RETURNS integer
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  chosen integer;
BEGIN
  SELECT candidate INTO chosen
    FROM pg_catalog.generate_series(1, 889) AS candidate
   WHERE NOT EXISTS (
     SELECT 1 FROM public.terminal_fiscal_series s
      WHERE s.branch_id = p_branch_id AND s.model = p_model AND s.series = candidate
   )
   ORDER BY candidate < COALESCE(p_preferred, 1), candidate
   LIMIT 1;
  IF chosen IS NULL THEN
    RAISE EXCEPTION 'Esta filial não tem mais série livre.'
      USING ERRCODE = 'FA921', DETAIL = pg_catalog.format('Filial %s, modelo %s.', p_branch_id, p_model);
  END IF;
  RETURN chosen;
END;
$$;

-- Caixa: 65 e 55. Autoatendimento: só 65. Orçamento não emite nota.
CREATE FUNCTION app.create_series_for_terminal(p_terminal public.terminal) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid;
  model_code text;
BEGIN
  IF EXISTS (SELECT 1 FROM public.terminal_fiscal_series s WHERE s.terminal_id = p_terminal.id) THEN
    RETURN;
  END IF;
  SELECT c.economic_group_id INTO group_id
    FROM public.branch b JOIN public.company c ON c.id = b.company_id
   WHERE b.id = p_terminal.branch_id;
  PERFORM app.lock_branch_series(p_terminal.branch_id);
  FOREACH model_code IN ARRAY CASE p_terminal.profile
    WHEN 'cashier' THEN ARRAY['65', '55']
    WHEN 'self_service' THEN ARRAY['65']
    ELSE ARRAY[]::text[]
  END LOOP
    INSERT INTO public.terminal_fiscal_series (economic_group_id, branch_id, terminal_id, model, series)
    VALUES (
      group_id, p_terminal.branch_id, p_terminal.id, model_code,
      app.free_series(p_terminal.branch_id, model_code, p_terminal.number)
    );
  END LOOP;
END;
$$;

-- Nasce quando o terminal é aprovado e termina quando ele é revogado.
CREATE FUNCTION app.sync_terminal_series() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NEW.status IN ('active', 'blocked') THEN
    PERFORM app.create_series_for_terminal(NEW);
  ELSIF NEW.status = 'revoked' THEN
    UPDATE public.terminal_fiscal_series s SET deleted_at = pg_catalog.clock_timestamp()
     WHERE s.terminal_id = NEW.id AND s.deleted_at IS NULL;
  END IF;
  RETURN NULL;
END;
$$;
CREATE TRIGGER sync_terminal_series AFTER INSERT OR UPDATE OF status ON terminal
  FOR EACH ROW EXECUTE FUNCTION app.sync_terminal_series();

-- Terminais já aprovados.
DO $$
DECLARE
  existing public.terminal;
BEGIN
  FOR existing IN
    SELECT * FROM public.terminal t
     WHERE t.status IN ('active', 'blocked') AND t.deleted_at IS NULL
     ORDER BY t.branch_id, t.number
  LOOP
    PERFORM app.create_series_for_terminal(existing);
  END LOOP;
END;
$$;

CREATE FUNCTION app.set_terminal_series(p_id uuid, p_series integer, p_initial_number bigint) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.terminal_fiscal_series;
BEGIN
  SELECT * INTO target FROM public.terminal_fiscal_series s
   WHERE s.id = p_id AND s.deleted_at IS NULL AND s.economic_group_id = app.current_user_group();
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('Série %s.', p_id);
  END IF;
  IF NOT app.has_permission('fiscal.manage', target.branch_id) THEN
    RAISE EXCEPTION 'Você não tem permissão para esta operação.'
      USING ERRCODE = 'FA002', DETAIL = pg_catalog.format('fiscal.manage na filial %s.', target.branch_id);
  END IF;
  IF p_series IS NULL OR p_initial_number IS NULL THEN
    RAISE EXCEPTION 'A série ou o número inicial é inválido.'
      USING ERRCODE = 'FA919', DETAIL = pg_catalog.format('Série %s.', p_id);
  END IF;
  PERFORM app.lock_branch_series(target.branch_id);
  UPDATE public.terminal_fiscal_series s
     SET series = p_series, initial_number = p_initial_number
   WHERE s.id = p_id;
END;
$$;

CREATE POLICY terminal_fiscal_series_select ON terminal_fiscal_series FOR SELECT TO farmaerp_app
  USING (
    economic_group_id = (SELECT app.current_user_group())
    AND branch_id = ANY ((SELECT app.allowed_branch_ids())::uuid[])
    AND (app.has_permission('fiscal.view', branch_id) OR app.has_permission('fiscal.manage', branch_id)
         OR app.has_permission('fiscal.certificate', branch_id) OR app.has_permission('terminals.view', branch_id))
  );
CREATE POLICY terminal_fiscal_series_event_select ON terminal_fiscal_series_event FOR SELECT TO farmaerp_app
  USING (
    economic_group_id = (SELECT app.current_user_group())
    AND EXISTS (
      SELECT 1 FROM terminal_fiscal_series s
       WHERE s.id = series_id
         AND (app.has_permission('fiscal.view', s.branch_id) OR app.has_permission('fiscal.manage', s.branch_id))
    )
  );
GRANT SELECT ON terminal_fiscal_series, terminal_fiscal_series_event TO farmaerp_app;

CREATE VIEW v_terminal_fiscal_series WITH (security_invoker = true) AS
  SELECT * FROM terminal_fiscal_series WHERE deleted_at IS NULL;
CREATE VIEW v_terminal_fiscal_series_event WITH (security_invoker = true) AS
  SELECT * FROM terminal_fiscal_series_event WHERE deleted_at IS NULL;
GRANT SELECT ON v_terminal_fiscal_series, v_terminal_fiscal_series_event TO farmaerp_app;

-- Séries em uso, com o terminal, para as telas Fiscal e Terminais.
CREATE FUNCTION app.list_terminal_series()
RETURNS TABLE (
  id uuid, branch_id uuid, terminal_id uuid, terminal_number integer, terminal_name text, model text,
  series integer, initial_number bigint, last_used_number bigint, can_manage boolean
)
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT s.id, s.branch_id, s.terminal_id, t.number::integer, t.name, s.model, s.series, s.initial_number,
         s.last_used_number, app.has_permission('fiscal.manage', s.branch_id)
    FROM public.v_terminal_fiscal_series s
    JOIN public.terminal t ON t.id = s.terminal_id
   ORDER BY t.number, s.model DESC
$$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  app.set_terminal_series(uuid, integer, bigint),
  app.list_terminal_series()
TO farmaerp_app;
