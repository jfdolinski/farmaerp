-- Up Migration

-- Plataforma: cada empresa nova é um cliente separado do sistema (grupo econômico próprio), com
-- usuários, produtos, clientes, estoque, vendas, crediário e descontos só dela. A separação é a que
-- já existe por grupo (RLS e funções filtram pelo grupo de quem está logado). Quem cadastra é o
-- administrador da plataforma, que não pertence a nenhuma empresa cadastrada por ele e não vê os
-- dados delas: só nome, CNPJ, quantidade de filiais e de usuários. A página Empresas continua para
-- os outros CNPJs do mesmo dono, dentro do mesmo cliente.

CREATE TABLE platform_admin (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  user_id uuid NOT NULL REFERENCES user_account (id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE UNIQUE INDEX platform_admin_user_key ON platform_admin (user_id) WHERE deleted_at IS NULL;
CALL app.apply_table_standard('public.platform_admin');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON platform_admin
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns('user_id');
CREATE POLICY platform_admin_select ON platform_admin FOR SELECT TO farmaerp_app USING (false);
CREATE VIEW v_platform_admin WITH (security_invoker = true) AS SELECT * FROM platform_admin WHERE deleted_at IS NULL;

CREATE FUNCTION app.is_platform_admin() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.platform_admin p
      JOIN public.user_account u ON u.id = p.user_id AND u.deleted_at IS NULL AND u.is_active
     WHERE p.user_id = app.current_user_id() AND p.deleted_at IS NULL
  )
$$;

CREATE FUNCTION app.require_platform_admin() RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT app.is_platform_admin() THEN
    RAISE EXCEPTION 'Você não tem permissão para esta operação.'
      USING ERRCODE = 'FA002', DETAIL = 'Administrador da plataforma.';
  END IF;
END;
$$;

-- Empresa nova como cliente separado: grupo (com os perfis padrão), empresa, primeira filial e o
-- administrador dela, que troca a senha temporária na primeira entrada. Tudo entra junto ou nada entra.
CREATE FUNCTION app.create_tenant(p_data jsonb, p_password_hash text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  clean text;
  group_id uuid;
  company_id uuid;
  branch_id uuid;
  admin_id uuid;
  admin_email text := pg_catalog.lower(pg_catalog.btrim(COALESCE(p_data -> 'admin' ->> 'email', '')));
  branch jsonb := COALESCE(p_data -> 'branch', '{}'::jsonb);
BEGIN
  PERFORM app.require_platform_admin();
  IF pg_catalog.btrim(COALESCE(p_data ->> 'groupName', '')) = '' OR pg_catalog.length(p_data ->> 'groupName') > 150 THEN
    RAISE EXCEPTION 'Dê um nome ao cliente, com até 150 letras.' USING ERRCODE = 'FA847';
  END IF;
  IF admin_email = '' OR pg_catalog.btrim(COALESCE(p_data -> 'admin' ->> 'name', '')) = '' THEN
    RAISE EXCEPTION 'Informe o nome e o e-mail do administrador da empresa.' USING ERRCODE = 'FA848';
  END IF;
  IF pg_catalog.btrim(COALESCE(p_password_hash, '')) = '' THEN
    RAISE EXCEPTION 'Alguns dados informados são inválidos.' USING ERRCODE = 'FA005', DETAIL = 'Senha temporária vazia.';
  END IF;
  clean := app.require_valid_cnpj(p_data ->> 'cnpj');

  INSERT INTO public.economic_group (name) VALUES (pg_catalog.btrim(p_data ->> 'groupName')) RETURNING id INTO group_id;
  INSERT INTO public.company (economic_group_id, legal_name, trade_name, cnpj_root)
  VALUES (
    group_id, COALESCE(pg_catalog.btrim(p_data ->> 'legalName'), ''), COALESCE(pg_catalog.btrim(p_data ->> 'tradeName'), ''),
    pg_catalog.left(clean, 8)
  ) RETURNING id INTO company_id;
  INSERT INTO public.branch (
    company_id, name, cnpj, state, pmc_region, postal_code, street, street_number, complement,
    district, city, city_code, phone
  ) VALUES (
    company_id,
    COALESCE(pg_catalog.btrim(branch ->> 'name'), ''),
    clean,
    app.blank_to_null(branch ->> 'state'),
    app.blank_to_null(branch ->> 'pmcRegion'),
    app.only_digits(branch ->> 'postalCode'),
    app.blank_to_null(branch ->> 'street'),
    app.blank_to_null(branch ->> 'streetNumber'),
    app.blank_to_null(branch ->> 'complement'),
    app.blank_to_null(branch ->> 'district'),
    app.blank_to_null(branch ->> 'city'),
    app.only_digits(branch ->> 'cityCode'),
    app.only_digits(branch ->> 'phone')
  ) RETURNING id INTO branch_id;

  INSERT INTO public.user_account (economic_group_id, name, email)
  VALUES (group_id, pg_catalog.btrim(p_data -> 'admin' ->> 'name'), admin_email)
  RETURNING id INTO admin_id;
  INSERT INTO public.user_role (user_id, role_id)
  SELECT admin_id, r.id FROM public.role r
   WHERE r.economic_group_id = group_id AND r.system_key = 'administrator' AND r.deleted_at IS NULL;
  INSERT INTO public.user_credential (user_id, password_hash, must_change_password) VALUES (admin_id, p_password_hash, true);

  RETURN pg_catalog.jsonb_build_object('groupId', group_id, 'companyId', company_id, 'branchId', branch_id, 'adminId', admin_id);
END;
$$;

-- Clientes da plataforma: só o que identifica cada um, nunca os dados do negócio.
CREATE FUNCTION app.list_tenants()
RETURNS TABLE (
  group_id uuid, name text, created_at timestamptz, companies jsonb, branch_count integer, user_count integer,
  admin_email text
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM app.require_platform_admin();
  RETURN QUERY
  SELECT g.id, g.name, g.created_at,
         COALESCE((
           SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
                    'legal_name', c.legal_name, 'trade_name', c.trade_name, 'cnpj_root', c.cnpj_root) ORDER BY c.created_at)
             FROM public.company c WHERE c.economic_group_id = g.id AND c.deleted_at IS NULL
         ), '[]'::jsonb),
         (SELECT pg_catalog.count(*)::integer FROM public.branch b JOIN public.company c ON c.id = b.company_id
           WHERE c.economic_group_id = g.id AND b.deleted_at IS NULL),
         (SELECT pg_catalog.count(*)::integer FROM public.user_account u WHERE u.economic_group_id = g.id AND u.deleted_at IS NULL),
         (SELECT u.email FROM public.user_account u
            JOIN public.user_role ur ON ur.user_id = u.id AND ur.deleted_at IS NULL
            JOIN public.role r ON r.id = ur.role_id AND r.system_key = 'administrator'
           WHERE u.economic_group_id = g.id AND u.deleted_at IS NULL
           ORDER BY u.created_at LIMIT 1)
    FROM public.economic_group g
   WHERE g.deleted_at IS NULL
   ORDER BY g.created_at DESC, g.id DESC;
END;
$$;

-- Sessão: diz se a pessoa administra a plataforma (só para a tela; o banco confere de novo).
CREATE OR REPLACE FUNCTION app.validate_session(p_token_hash text) RETURNS jsonb
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
           'permissions', app.user_permission_codes(u.id),
           'mustChangePassword', COALESCE(c.must_change_password, false),
           'platformAdmin', EXISTS (
             SELECT 1 FROM public.platform_admin p WHERE p.user_id = u.id AND p.deleted_at IS NULL)
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

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  app.is_platform_admin(),
  app.create_tenant(jsonb, text),
  app.list_tenants()
TO farmaerp_app;
