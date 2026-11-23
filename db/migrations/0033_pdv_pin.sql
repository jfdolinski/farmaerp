-- Up Migration

-- PIN do operador para o PDV (primeira parte da Etapa 5, antecipada). Quem pode gerar senha
-- temporária para a pessoa define o PIN dela na retaguarda. O PIN chega aqui já com hash forte
-- (PBKDF2-SHA256, sal próprio), e o hash desce para as filiais da pessoa, para o PDV conferir
-- mesmo sem internet. O banco local do PDV é criptografado; o PIN em texto nunca é guardado.

CREATE TABLE user_pin (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  user_id uuid NOT NULL REFERENCES user_account (id),
  pin_hash text NOT NULL CONSTRAINT user_pin_hash_check CHECK (
    pin_hash ~ '^pbkdf2-sha256\$[0-9]{6,7}\$[A-Za-z0-9+/]{22}==\$[A-Za-z0-9+/]{43}=$'
  ),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE UNIQUE INDEX user_pin_user_key ON user_pin (user_id) WHERE deleted_at IS NULL;

CALL app.apply_table_standard('public.user_pin');

CREATE POLICY user_pin_select ON user_pin FOR SELECT TO farmaerp_app USING (false);
CREATE VIEW v_user_pin WITH (security_invoker = true) AS
  SELECT * FROM user_pin WHERE deleted_at IS NULL;

ALTER TABLE auth_event DROP CONSTRAINT auth_event_event_type_check;
ALTER TABLE auth_event ADD CONSTRAINT auth_event_event_type_check CHECK (event_type IN (
  'login_success', 'login_failure', 'login_locked', 'logout', 'password_changed', 'password_reset', 'pin_set'
));

-- Define (ou troca) o PIN de outra pessoa. A regra é a mesma da senha temporária.
CREATE FUNCTION app.set_user_pin(p_user_id uuid, p_pin_hash text, p_ip text) RETURNS void
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
      USING ERRCODE = 'FA002', DETAIL = pg_catalog.format('PIN de %s.', p_user_id);
  END IF;
  IF NOT target.is_active THEN
    RAISE EXCEPTION 'O usuário informado não está ativo.'
      USING ERRCODE = 'FA209', DETAIL = pg_catalog.format('user_account %s inativo.', p_user_id);
  END IF;

  INSERT INTO public.user_pin (user_id, pin_hash) VALUES (p_user_id, p_pin_hash)
  ON CONFLICT (user_id) WHERE deleted_at IS NULL DO UPDATE SET pin_hash = EXCLUDED.pin_hash;
  PERFORM app.record_auth_event(p_user_id, 'pin_set', p_ip);
END;
$$;

-- PIN novo desce para os PDVs da pessoa.
CREATE FUNCTION app.track_user_pin_change() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM app.mark_sync_change('user', NEW.user_id, u.economic_group_id, NULL)
     FROM public.user_account u WHERE u.id = NEW.user_id;
  RETURN NULL;
END;
$$;
CREATE TRIGGER track_sync_change AFTER INSERT OR UPDATE ON user_pin
  FOR EACH ROW EXECUTE FUNCTION app.track_user_pin_change();

-- Formato 2: usuários trazem o hash do PIN e os dados fiscais, o último número de venda do
-- terminal. Os PDVs refazem a carga inteira ao ver o formato novo.
CREATE OR REPLACE FUNCTION app.pdv_sync_format() RETURNS integer
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$ SELECT 2 $$;

-- Usuário com algum perfil na filial, com permissões e limites prontos. Da credencial, só o hash
-- do PIN desce (para o PDV conferir sem internet); a senha da retaguarda nunca desce.
CREATE OR REPLACE FUNCTION app.pdv_user_data(p_branch_id uuid, p_ids uuid[])
RETURNS TABLE (id uuid, data jsonb)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT ids.id,
         CASE WHEN EXISTS (SELECT 1 FROM app.user_roles_at(ids.id, p_branch_id)) THEN pg_catalog.jsonb_build_object(
           'code', u.code,
           'name', u.name,
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

-- Dados fiscais da filial e as séries deste terminal. Certificado e CSC não descem. Traz também o
-- último número de venda que a central recebeu deste terminal: se o banco local se perder, o PDV
-- continua a contagem dali e não repete número.
CREATE OR REPLACE FUNCTION app.pdv_fiscal_data(p_branch_id uuid, p_terminal_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT pg_catalog.jsonb_build_object(
           'branch', pg_catalog.jsonb_build_object(
             'id', b.id, 'name', b.name, 'cnpj', b.cnpj, 'state_registration', b.state_registration,
             'state', b.state, 'pmc_region', b.pmc_region, 'postal_code', b.postal_code, 'street', b.street,
             'street_number', b.street_number, 'complement', b.complement, 'district', b.district,
             'city', b.city, 'city_code', b.city_code, 'phone', b.phone
           ),
           'company', pg_catalog.jsonb_build_object(
             'id', c.id, 'legal_name', c.legal_name, 'trade_name', c.trade_name, 'tax_regime', c.tax_regime
           ),
           'last_sale_number', (
             SELECT pg_catalog.max(s.number) FROM public.sale s WHERE s.terminal_id = p_terminal_id AND s.deleted_at IS NULL
           ),
           'series', COALESCE((
             SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
                      'id', s.id, 'model', s.model, 'series', s.series, 'initial_number', s.initial_number,
                      'last_used_number', s.last_used_number) ORDER BY s.model)
               FROM public.terminal_fiscal_series s
              WHERE s.terminal_id = p_terminal_id AND s.deleted_at IS NULL
           ), '[]'::jsonb)
         )
    FROM public.branch b
    JOIN public.company c ON c.id = b.company_id
   WHERE b.id = p_branch_id AND b.deleted_at IS NULL
$$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.set_user_pin(uuid, text, text) TO farmaerp_app;
