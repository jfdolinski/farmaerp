-- Up Migration

-- Controle de acesso por filial. Sem usuário na transação, nenhuma linha é liberada.
-- O papel farmaerp_app não é dono das tabelas, por isso está sempre sujeito às políticas.
-- As políticas não filtram deleted_at: isso faria a exclusão lógica falhar no UPDATE.
-- O filtro de registros ativos fica nas views v_*.

-- Grupo econômico do usuário atual, somente se ele for admin ativo.
CREATE FUNCTION app.admin_economic_group_id() RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT u.economic_group_id
    FROM public.user_account u
   WHERE u.id = app.current_user_id()
     AND u.deleted_at IS NULL
     AND u.is_group_admin
$$;

-- Filiais permitidas. O admin vê todas as do grupo, inclusive excluídas, para poder
-- reativá-las. Os demais veem só as filiais ativas com vínculo ativo.
CREATE FUNCTION app.allowed_branch_ids() RETURNS uuid[]
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE(pg_catalog.array_agg(b.id), '{}')
    FROM public.user_account u
    JOIN public.company c ON c.economic_group_id = u.economic_group_id
    JOIN public.branch b ON b.company_id = c.id
   WHERE u.id = app.current_user_id()
     AND u.deleted_at IS NULL
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

-- Funções de apoio: evitam recursão entre as políticas de tabelas relacionadas.
CREATE FUNCTION app.is_admin_of_branch_group(target_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.branch_group bg
     WHERE bg.id = target_id
       AND bg.economic_group_id = app.admin_economic_group_id()
  )
$$;

CREATE FUNCTION app.is_admin_of_company(target_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.company c
     WHERE c.id = target_id
       AND c.economic_group_id = app.admin_economic_group_id()
  )
$$;

CREATE FUNCTION app.is_admin_of_branch(target_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
      FROM public.branch b
      JOIN public.company c ON c.id = b.company_id
     WHERE b.id = target_id
       AND c.economic_group_id = app.admin_economic_group_id()
  )
$$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  app.current_user_id(),
  app.is_valid_cnpj(text),
  app.admin_economic_group_id(),
  app.allowed_branch_ids(),
  app.is_admin_of_branch_group(uuid),
  app.is_admin_of_company(uuid),
  app.is_admin_of_branch(uuid)
TO farmaerp_app;

-- A API não cria grupo econômico e nunca executa DELETE ou TRUNCATE.
GRANT SELECT, UPDATE ON economic_group TO farmaerp_app;
GRANT SELECT, INSERT, UPDATE ON company, branch_group, region, branch, terminal, user_account, user_branch TO farmaerp_app;

-- A filial é a base: suas políticas não consultam outras tabelas com RLS.
CREATE POLICY branch_select ON branch FOR SELECT TO farmaerp_app
  USING (id = ANY ((SELECT app.allowed_branch_ids())::uuid[]) OR app.is_admin_of_company(company_id));
CREATE POLICY branch_insert ON branch FOR INSERT TO farmaerp_app
  WITH CHECK (app.is_admin_of_company(company_id));
CREATE POLICY branch_update ON branch FOR UPDATE TO farmaerp_app
  USING (app.is_admin_of_company(company_id))
  WITH CHECK (app.is_admin_of_company(company_id));

CREATE POLICY economic_group_select ON economic_group FOR SELECT TO farmaerp_app
  USING (
    id = (SELECT app.admin_economic_group_id())
    OR EXISTS (SELECT 1 FROM company c WHERE c.economic_group_id = economic_group.id)
  );
CREATE POLICY economic_group_update ON economic_group FOR UPDATE TO farmaerp_app
  USING (id = (SELECT app.admin_economic_group_id()))
  WITH CHECK (id = (SELECT app.admin_economic_group_id()));

CREATE POLICY company_select ON company FOR SELECT TO farmaerp_app
  USING (
    economic_group_id = (SELECT app.admin_economic_group_id())
    OR EXISTS (SELECT 1 FROM branch b WHERE b.company_id = company.id)
  );
CREATE POLICY company_insert ON company FOR INSERT TO farmaerp_app
  WITH CHECK (economic_group_id = (SELECT app.admin_economic_group_id()));
CREATE POLICY company_update ON company FOR UPDATE TO farmaerp_app
  USING (economic_group_id = (SELECT app.admin_economic_group_id()))
  WITH CHECK (economic_group_id = (SELECT app.admin_economic_group_id()));

CREATE POLICY region_select ON region FOR SELECT TO farmaerp_app
  USING (
    app.is_admin_of_branch_group(branch_group_id)
    OR EXISTS (SELECT 1 FROM branch b WHERE b.region_id = region.id)
  );
CREATE POLICY region_insert ON region FOR INSERT TO farmaerp_app
  WITH CHECK (app.is_admin_of_branch_group(branch_group_id));
CREATE POLICY region_update ON region FOR UPDATE TO farmaerp_app
  USING (app.is_admin_of_branch_group(branch_group_id))
  WITH CHECK (app.is_admin_of_branch_group(branch_group_id));

CREATE POLICY branch_group_select ON branch_group FOR SELECT TO farmaerp_app
  USING (
    economic_group_id = (SELECT app.admin_economic_group_id())
    OR EXISTS (SELECT 1 FROM region r WHERE r.branch_group_id = branch_group.id)
  );
CREATE POLICY branch_group_insert ON branch_group FOR INSERT TO farmaerp_app
  WITH CHECK (economic_group_id = (SELECT app.admin_economic_group_id()));
CREATE POLICY branch_group_update ON branch_group FOR UPDATE TO farmaerp_app
  USING (economic_group_id = (SELECT app.admin_economic_group_id()))
  WITH CHECK (economic_group_id = (SELECT app.admin_economic_group_id()));

CREATE POLICY terminal_select ON terminal FOR SELECT TO farmaerp_app
  USING (branch_id = ANY ((SELECT app.allowed_branch_ids())::uuid[]));
CREATE POLICY terminal_insert ON terminal FOR INSERT TO farmaerp_app
  WITH CHECK (app.is_admin_of_branch(branch_id));
CREATE POLICY terminal_update ON terminal FOR UPDATE TO farmaerp_app
  USING (app.is_admin_of_branch(branch_id))
  WITH CHECK (app.is_admin_of_branch(branch_id));

CREATE POLICY user_account_select ON user_account FOR SELECT TO farmaerp_app
  USING (
    id = (SELECT app.current_user_id())
    OR economic_group_id = (SELECT app.admin_economic_group_id())
  );
CREATE POLICY user_account_insert ON user_account FOR INSERT TO farmaerp_app
  WITH CHECK (economic_group_id = (SELECT app.admin_economic_group_id()));
CREATE POLICY user_account_update ON user_account FOR UPDATE TO farmaerp_app
  USING (economic_group_id = (SELECT app.admin_economic_group_id()))
  WITH CHECK (economic_group_id = (SELECT app.admin_economic_group_id()));

CREATE POLICY user_branch_select ON user_branch FOR SELECT TO farmaerp_app
  USING (
    user_id = (SELECT app.current_user_id())
    OR app.is_admin_of_branch(branch_id)
  );
CREATE POLICY user_branch_insert ON user_branch FOR INSERT TO farmaerp_app
  WITH CHECK (app.is_admin_of_branch(branch_id));
CREATE POLICY user_branch_update ON user_branch FOR UPDATE TO farmaerp_app
  USING (app.is_admin_of_branch(branch_id))
  WITH CHECK (app.is_admin_of_branch(branch_id));
