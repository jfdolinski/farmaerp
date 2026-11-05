-- Up Migration

-- Perfis e permissões no lugar de is_group_admin.
-- Um usuário pode ter vários perfis, em todas as suas filiais ou em uma só, e as permissões se somam.

CREATE TABLE permission (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  code text NOT NULL CHECK (code ~ '^[a-z_]+\.[a-z_]+$'),
  module text NOT NULL CHECK (btrim(module) <> ''),
  name text NOT NULL CHECK (btrim(name) <> ''),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE UNIQUE INDEX permission_code_active_key ON permission (code) WHERE deleted_at IS NULL;

CREATE TABLE role (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  name text NOT NULL CHECK (btrim(name) <> ''),
  description text,
  -- Só o perfil Administrador é de sistema: tem tudo e não pode ser editado.
  system_key text CHECK (system_key = 'administrator'),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE INDEX role_economic_group_id_idx ON role (economic_group_id);
CREATE UNIQUE INDEX role_name_active_key ON role (economic_group_id, name) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX role_system_key_active_key ON role (economic_group_id, system_key)
  WHERE deleted_at IS NULL AND system_key IS NOT NULL;

CREATE TABLE role_permission (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  role_id uuid NOT NULL REFERENCES role (id),
  permission_id uuid NOT NULL REFERENCES permission (id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE UNIQUE INDEX role_permission_active_key ON role_permission (role_id, permission_id) WHERE deleted_at IS NULL;
CREATE INDEX role_permission_permission_id_idx ON role_permission (permission_id);

-- branch_id vazio significa todas as filiais do usuário.
CREATE TABLE user_role (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  user_id uuid NOT NULL REFERENCES user_account (id),
  role_id uuid NOT NULL REFERENCES role (id),
  branch_id uuid REFERENCES branch (id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE UNIQUE INDEX user_role_active_key
  ON user_role (user_id, role_id, COALESCE(branch_id, '00000000-0000-0000-0000-000000000000'::uuid))
  WHERE deleted_at IS NULL;
CREATE INDEX user_role_role_id_idx ON user_role (role_id);

CALL app.apply_table_standard('public.permission');
CALL app.apply_table_standard('public.role');
CALL app.apply_table_standard('public.role_permission');
CALL app.apply_table_standard('public.user_role');

INSERT INTO permission (code, module, name) VALUES
  ('branches.view_all', 'Estrutura', 'Ver todas as filiais do grupo'),
  ('structure.manage', 'Estrutura', 'Alterar empresas, filiais e regiões'),
  ('users.view', 'Usuários', 'Ver usuários'),
  ('users.manage', 'Usuários', 'Criar e editar usuários e filiais'),
  ('users.reset_password', 'Usuários', 'Gerar senha temporária'),
  ('roles.manage', 'Perfis', 'Criar e editar perfis'),
  ('roles.assign', 'Perfis', 'Atribuir perfis'),
  ('terminals.view', 'Terminais', 'Ver terminais'),
  ('terminals.request', 'Terminais', 'Solicitar terminal (aceitar código)'),
  ('terminals.approve', 'Terminais', 'Aprovar terminal'),
  ('terminals.block', 'Terminais', 'Bloquear e desbloquear terminal'),
  ('terminals.revoke', 'Terminais', 'Revogar terminal'),
  ('audit.view', 'Auditoria', 'Ver histórico de acesso');

-- Perfis iniciais de cada grupo econômico.
CREATE FUNCTION app.create_default_roles(p_group_id uuid) RETURNS void
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

  INSERT INTO public.role_permission (role_id, permission_id)
  SELECT manager_id, p.id
    FROM public.permission p
   WHERE p.code IN ('users.view', 'users.reset_password', 'terminals.view', 'terminals.request', 'terminals.block');
END;
$$;

CREATE FUNCTION app.create_default_roles_on_group() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM app.create_default_roles(NEW.id);
  RETURN NULL;
END;
$$;

CREATE TRIGGER create_default_roles AFTER INSERT ON economic_group
  FOR EACH ROW EXECUTE FUNCTION app.create_default_roles_on_group();

SELECT app.create_default_roles(id) FROM economic_group;

-- Quem era administrador continua sendo.
INSERT INTO user_role (user_id, role_id)
SELECT u.id, r.id
  FROM user_account u
  JOIN role r ON r.economic_group_id = u.economic_group_id AND r.system_key = 'administrator'
 WHERE u.is_group_admin;

-- Núcleo: o Administrador tem tudo; os demais, o que os perfis dão, onde valem.
CREATE FUNCTION app.current_user_group() RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT u.economic_group_id
    FROM public.user_account u
   WHERE u.id = app.current_user_id() AND u.deleted_at IS NULL AND u.is_active
$$;

-- Sem filial, só contam perfis válidos em todas as filiais do usuário.
CREATE FUNCTION app.has_permission(p_code text, p_branch_id uuid DEFAULT NULL) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
      FROM public.user_account u
      JOIN public.user_role ur ON ur.user_id = u.id AND ur.deleted_at IS NULL
      JOIN public.role r ON r.id = ur.role_id AND r.deleted_at IS NULL
     WHERE u.id = app.current_user_id()
       AND u.deleted_at IS NULL
       AND u.is_active
       AND (ur.branch_id IS NULL OR ur.branch_id = p_branch_id)
       AND (
         r.system_key = 'administrator'
         OR EXISTS (
           SELECT 1
             FROM public.role_permission rp
             JOIN public.permission p ON p.id = rp.permission_id AND p.deleted_at IS NULL
            WHERE rp.role_id = r.id AND rp.deleted_at IS NULL AND p.code = p_code
         )
       )
  )
  AND (p_branch_id IS NULL OR p_branch_id = ANY (app.allowed_branch_ids()))
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
       app.has_permission('branches.view_all')
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

-- Tem a permissão em ao menos uma filial, para ações que ainda não têm filial definida.
CREATE FUNCTION app.has_permission_anywhere(p_code text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT app.has_permission(p_code)
      OR EXISTS (
        SELECT 1 FROM pg_catalog.unnest(app.allowed_branch_ids()) AS allowed(branch_id)
         WHERE app.has_permission(p_code, allowed.branch_id)
      )
$$;

-- Grupo do usuário, se ele tiver a permissão em todas as suas filiais.
CREATE FUNCTION app.permission_group(p_code text) RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT CASE WHEN app.has_permission(p_code) THEN app.current_user_group() END
$$;

CREATE FUNCTION app.company_has_permission(p_company_id uuid, p_code text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.company c
     WHERE c.id = p_company_id AND c.economic_group_id = app.permission_group(p_code)
  )
$$;

CREATE FUNCTION app.branch_group_has_permission(p_branch_group_id uuid, p_code text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.branch_group bg
     WHERE bg.id = p_branch_group_id AND bg.economic_group_id = app.permission_group(p_code)
  )
$$;

-- Permissão sobre um usuário: em todas as filiais, ou em uma filial à qual ele esteja vinculado.
CREATE FUNCTION app.can_on_user(p_code text, p_user_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.user_account t
     WHERE t.id = p_user_id
       AND t.economic_group_id = app.current_user_group()
       AND (
         app.has_permission(p_code)
         OR EXISTS (
           SELECT 1 FROM public.user_branch ub
            WHERE ub.user_id = t.id
              AND ub.deleted_at IS NULL
              AND app.has_permission(p_code, ub.branch_id)
         )
       )
  )
$$;

-- Evita escalada: quem age precisa ter tudo o que o perfil dá, ali onde ele vale.
CREATE FUNCTION app.covers_role(p_role_id uuid, p_branch_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT CASE
    WHEN (SELECT r.system_key FROM public.role r WHERE r.id = p_role_id) = 'administrator' THEN
      EXISTS (
        SELECT 1
          FROM public.user_role ur
          JOIN public.role r ON r.id = ur.role_id AND r.deleted_at IS NULL
         WHERE ur.user_id = app.current_user_id()
           AND ur.deleted_at IS NULL
           AND r.system_key = 'administrator'
      )
    ELSE NOT EXISTS (
      SELECT 1
        FROM public.role_permission rp
        JOIN public.permission p ON p.id = rp.permission_id AND p.deleted_at IS NULL
       WHERE rp.role_id = p_role_id
         AND rp.deleted_at IS NULL
         AND NOT app.has_permission(p.code, p_branch_id)
    )
  END
$$;

-- Ninguém age sobre alguém com mais poder: seria um caminho para tomar a conta dele.
CREATE FUNCTION app.covers_user(p_user_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT NOT EXISTS (
    SELECT 1 FROM public.user_role ur
     WHERE ur.user_id = p_user_id
       AND ur.deleted_at IS NULL
       AND NOT app.covers_role(ur.role_id, ur.branch_id)
  )
$$;

CREATE FUNCTION app.can_manage_user(p_user_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT app.can_on_user('users.manage', p_user_id) AND app.covers_user(p_user_id)
$$;

-- Permissões do usuário em qualquer filial, para a retaguarda montar menus e botões.
CREATE FUNCTION app.user_permission_codes(p_user_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE(pg_catalog.jsonb_agg(DISTINCT p.code), '[]'::jsonb)
    FROM public.user_role ur
    JOIN public.role r ON r.id = ur.role_id AND r.deleted_at IS NULL
    JOIN public.permission p ON p.deleted_at IS NULL
   WHERE ur.user_id = p_user_id
     AND ur.deleted_at IS NULL
     AND (
       r.system_key = 'administrator'
       OR EXISTS (
         SELECT 1 FROM public.role_permission rp
          WHERE rp.role_id = r.id AND rp.permission_id = p.id AND rp.deleted_at IS NULL
       )
     )
$$;

-- Regras dos vínculos, valendo para qualquer caminho de escrita.
CREATE FUNCTION app.validate_user_role() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  user_group_id uuid;
  role_group_id uuid;
  role_system_key text;
BEGIN
  IF NEW.deleted_at IS NOT NULL THEN
    RETURN NEW;
  END IF;

  SELECT u.economic_group_id INTO user_group_id
    FROM public.user_account u
   WHERE u.id = NEW.user_id AND u.deleted_at IS NULL AND u.is_active;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O usuário informado não está ativo.'
      USING ERRCODE = 'FA209', DETAIL = pg_catalog.format('user_account %s.', NEW.user_id);
  END IF;

  SELECT r.economic_group_id, r.system_key INTO role_group_id, role_system_key
    FROM public.role r
   WHERE r.id = NEW.role_id AND r.deleted_at IS NULL;
  IF NOT FOUND OR role_group_id IS DISTINCT FROM user_group_id THEN
    RAISE EXCEPTION 'Este perfil não pertence ao grupo do usuário.'
      USING ERRCODE = 'FA509', DETAIL = pg_catalog.format('role %s, user_account %s.', NEW.role_id, NEW.user_id);
  END IF;

  IF NEW.branch_id IS NOT NULL THEN
    IF role_system_key = 'administrator' THEN
      RAISE EXCEPTION 'O perfil Administrador vale para todas as filiais.'
        USING ERRCODE = 'FA506', DETAIL = pg_catalog.format('role %s.', NEW.role_id);
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM public.user_branch ub
       WHERE ub.user_id = NEW.user_id AND ub.branch_id = NEW.branch_id AND ub.deleted_at IS NULL
    ) THEN
      RAISE EXCEPTION 'Vincule o usuário a esta filial antes de atribuir o perfil.'
        USING ERRCODE = 'FA505', DETAIL = pg_catalog.format('user_account %s, branch %s.', NEW.user_id, NEW.branch_id);
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER validate_parent BEFORE INSERT OR UPDATE ON user_role
  FOR EACH ROW EXECUTE FUNCTION app.validate_user_role();

-- O histórico dos vínculos é a própria tabela: inclusão e exclusão lógica, nunca edição.
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON user_role
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns('user_id', 'role_id', 'branch_id');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON role_permission
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns('role_id', 'permission_id');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON role
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns('economic_group_id', 'system_key');

CREATE FUNCTION app.block_system_role_change() RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF OLD.system_key IS NOT NULL THEN
    RAISE EXCEPTION 'O perfil Administrador não pode ser alterado.'
      USING ERRCODE = 'FA502', DETAIL = pg_catalog.format('role %s.', OLD.id);
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER block_system_role_change BEFORE UPDATE ON role
  FOR EACH ROW EXECUTE FUNCTION app.block_system_role_change();

-- O grupo nunca fica sem um Administrador ativo. A trava cobre saídas simultâneas.
CREATE FUNCTION app.assert_other_admin(p_group_id uuid, p_user_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('group_admin:' || p_group_id::text, 0));

  IF NOT EXISTS (
    SELECT 1
      FROM public.user_role ur
      JOIN public.role r ON r.id = ur.role_id AND r.deleted_at IS NULL
      JOIN public.user_account u ON u.id = ur.user_id
     WHERE r.economic_group_id = p_group_id
       AND r.system_key = 'administrator'
       AND ur.deleted_at IS NULL
       AND ur.user_id <> p_user_id
       AND u.is_active
       AND u.deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'O grupo precisa ter ao menos um administrador ativo.'
      USING ERRCODE = 'FA405', DETAIL = pg_catalog.format('user_account %s.', p_user_id);
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION app.protect_last_admin() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF OLD.is_active AND OLD.deleted_at IS NULL
     AND NOT (NEW.is_active AND NEW.deleted_at IS NULL)
     AND EXISTS (
       SELECT 1
         FROM public.user_role ur
         JOIN public.role r ON r.id = ur.role_id AND r.deleted_at IS NULL
        WHERE ur.user_id = OLD.id AND ur.deleted_at IS NULL AND r.system_key = 'administrator'
     )
  THEN
    PERFORM app.assert_other_admin(OLD.economic_group_id, OLD.id);
  END IF;
  RETURN NEW;
END;
$$;

CREATE FUNCTION app.protect_last_admin_role() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  admin_group_id uuid;
BEGIN
  IF OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL THEN
    SELECT r.economic_group_id INTO admin_group_id
      FROM public.role r
     WHERE r.id = OLD.role_id AND r.system_key = 'administrator' AND r.deleted_at IS NULL;
    IF FOUND THEN
      PERFORM app.assert_other_admin(admin_group_id, OLD.user_id);
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER protect_last_admin BEFORE UPDATE ON user_role
  FOR EACH ROW EXECUTE FUNCTION app.protect_last_admin_role();

-- Gestão de perfis: só por estas funções, que conferem a escalada.
CREATE FUNCTION app.set_role_permissions(p_role_id uuid, p_codes text[]) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  wanted text[] := COALESCE(p_codes, '{}');
  unknown text;
  denied text;
BEGIN
  SELECT w.code INTO unknown
    FROM pg_catalog.unnest(wanted) AS w(code)
   WHERE NOT EXISTS (SELECT 1 FROM public.permission p WHERE p.code = w.code AND p.deleted_at IS NULL)
   LIMIT 1;
  IF unknown IS NOT NULL THEN
    RAISE EXCEPTION 'Os dados do perfil são inválidos.'
      USING ERRCODE = 'FA508', DETAIL = pg_catalog.format('Permissão %s.', unknown);
  END IF;

  -- Só as permissões novas são conferidas: tirar o que não se tem é permitido.
  SELECT p.code INTO denied
    FROM public.permission p
   WHERE p.code = ANY (wanted)
     AND p.deleted_at IS NULL
     AND NOT EXISTS (
       SELECT 1 FROM public.role_permission rp
        WHERE rp.role_id = p_role_id AND rp.permission_id = p.id AND rp.deleted_at IS NULL
     )
     AND NOT app.has_permission(p.code)
   LIMIT 1;
  IF denied IS NOT NULL THEN
    RAISE EXCEPTION 'Você não pode conceder uma permissão que não tem.'
      USING ERRCODE = 'FA504', DETAIL = pg_catalog.format('Permissão %s.', denied);
  END IF;

  UPDATE public.role_permission rp
     SET deleted_at = pg_catalog.clock_timestamp()
    FROM public.permission p
   WHERE p.id = rp.permission_id
     AND rp.role_id = p_role_id
     AND rp.deleted_at IS NULL
     AND NOT (p.code = ANY (wanted));

  INSERT INTO public.role_permission (role_id, permission_id)
  SELECT p_role_id, p.id
    FROM public.permission p
   WHERE p.code = ANY (wanted)
     AND p.deleted_at IS NULL
     AND NOT EXISTS (
       SELECT 1 FROM public.role_permission rp
        WHERE rp.role_id = p_role_id AND rp.permission_id = p.id AND rp.deleted_at IS NULL
     );
END;
$$;

CREATE FUNCTION app.lock_role_for_manager(p_role_id uuid) RETURNS public.role
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.role;
BEGIN
  SELECT * INTO target FROM public.role r
   WHERE r.id = p_role_id AND r.deleted_at IS NULL
     FOR UPDATE;
  IF NOT FOUND OR target.economic_group_id IS DISTINCT FROM app.permission_group('roles.manage') THEN
    RAISE EXCEPTION 'Você não tem permissão para esta operação.'
      USING ERRCODE = 'FA002', DETAIL = pg_catalog.format('role %s.', p_role_id);
  END IF;
  IF target.system_key IS NOT NULL THEN
    RAISE EXCEPTION 'O perfil Administrador não pode ser alterado.'
      USING ERRCODE = 'FA502', DETAIL = pg_catalog.format('role %s.', p_role_id);
  END IF;
  RETURN target;
END;
$$;

CREATE FUNCTION app.create_role(p_name text, p_description text, p_codes text[]) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.permission_group('roles.manage');
  new_id uuid;
BEGIN
  IF group_id IS NULL THEN
    RAISE EXCEPTION 'Você não tem permissão para esta operação.'
      USING ERRCODE = 'FA002', DETAIL = 'create_role sem roles.manage.';
  END IF;
  INSERT INTO public.role (economic_group_id, name, description)
  VALUES (group_id, pg_catalog.btrim(p_name), NULLIF(pg_catalog.btrim(p_description), ''))
  RETURNING id INTO new_id;
  PERFORM app.set_role_permissions(new_id, p_codes);
  RETURN new_id;
END;
$$;

CREATE FUNCTION app.update_role(p_role_id uuid, p_name text, p_description text, p_codes text[]) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.role := app.lock_role_for_manager(p_role_id);
BEGIN
  UPDATE public.role r
     SET name = pg_catalog.btrim(p_name), description = NULLIF(pg_catalog.btrim(p_description), '')
   WHERE r.id = target.id;
  PERFORM app.set_role_permissions(target.id, p_codes);
END;
$$;

CREATE FUNCTION app.delete_role(p_role_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.role := app.lock_role_for_manager(p_role_id);
BEGIN
  IF EXISTS (SELECT 1 FROM public.user_role ur WHERE ur.role_id = target.id AND ur.deleted_at IS NULL) THEN
    RAISE EXCEPTION 'Este perfil ainda está atribuído a usuários.'
      USING ERRCODE = 'FA503', DETAIL = pg_catalog.format('role %s.', target.id);
  END IF;
  UPDATE public.role_permission rp
     SET deleted_at = pg_catalog.clock_timestamp()
   WHERE rp.role_id = target.id AND rp.deleted_at IS NULL;
  UPDATE public.role r SET deleted_at = pg_catalog.clock_timestamp() WHERE r.id = target.id;
END;
$$;

CREATE FUNCTION app.assign_role(p_user_id uuid, p_role_id uuid, p_branch_id uuid) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  new_id uuid;
BEGIN
  IF NOT app.has_permission('roles.assign', p_branch_id)
     OR NOT app.can_on_user('roles.assign', p_user_id) THEN
    RAISE EXCEPTION 'Você não tem permissão para esta operação.'
      USING ERRCODE = 'FA002', DETAIL = pg_catalog.format('assign_role em %s.', p_user_id);
  END IF;
  IF NOT app.covers_role(p_role_id, p_branch_id) THEN
    RAISE EXCEPTION 'Você não pode conceder uma permissão que não tem.'
      USING ERRCODE = 'FA504', DETAIL = pg_catalog.format('role %s.', p_role_id);
  END IF;
  INSERT INTO public.user_role (user_id, role_id, branch_id)
  VALUES (p_user_id, p_role_id, p_branch_id)
  RETURNING id INTO new_id;
  RETURN new_id;
END;
$$;

CREATE FUNCTION app.unassign_role(p_user_role_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.user_role;
BEGIN
  SELECT * INTO target FROM public.user_role ur
   WHERE ur.id = p_user_role_id AND ur.deleted_at IS NULL
     FOR UPDATE;
  IF NOT FOUND
     OR NOT app.has_permission('roles.assign', target.branch_id)
     OR NOT app.can_on_user('roles.assign', target.user_id) THEN
    RAISE EXCEPTION 'Você não tem permissão para esta operação.'
      USING ERRCODE = 'FA002', DETAIL = pg_catalog.format('unassign_role %s.', p_user_role_id);
  END IF;
  IF NOT app.covers_role(target.role_id, target.branch_id) THEN
    RAISE EXCEPTION 'Você não pode conceder uma permissão que não tem.'
      USING ERRCODE = 'FA504', DETAIL = pg_catalog.format('role %s.', target.role_id);
  END IF;
  UPDATE public.user_role ur SET deleted_at = pg_catalog.clock_timestamp() WHERE ur.id = target.id;
END;
$$;

-- Fluxo de terminais: a permissão certa para cada passo.
CREATE OR REPLACE FUNCTION app.find_pairing_request(p_code text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  request public.terminal_pairing_request;
BEGIN
  IF NOT app.has_permission_anywhere('terminals.request') THEN
    RAISE EXCEPTION 'Você não tem permissão para esta operação.'
      USING ERRCODE = 'FA002', DETAIL = 'find_pairing_request sem terminals.request.';
  END IF;

  SELECT * INTO request
    FROM public.terminal_pairing_request r
   WHERE r.code = app.normalize_pairing_code(p_code)
     AND r.status = 'waiting'
     AND r.deleted_at IS NULL
     AND r.expires_at > pg_catalog.now();
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Código não encontrado ou expirado.'
      USING ERRCODE = 'FA301', DETAIL = 'Consulta de código sem resultado.';
  END IF;

  RETURN pg_catalog.jsonb_build_object(
    'platform', request.platform,
    'deviceName', request.device_name,
    'appVersion', request.app_version,
    'keyStorage', request.key_storage,
    'expiresAt', request.expires_at
  );
END;
$$;

CREATE OR REPLACE FUNCTION app.claim_pairing_request(p_code text, p_branch_id uuid) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  request public.terminal_pairing_request;
  new_terminal_id uuid;
BEGIN
  IF NOT app.has_permission('terminals.request', p_branch_id) THEN
    RAISE EXCEPTION 'Você não tem permissão para esta operação.'
      USING ERRCODE = 'FA002', DETAIL = pg_catalog.format('Filial %s sem terminals.request.', p_branch_id);
  END IF;

  SELECT * INTO request
    FROM public.terminal_pairing_request r
   WHERE r.code = app.normalize_pairing_code(p_code)
     AND r.status = 'waiting'
     AND r.deleted_at IS NULL
     AND r.expires_at > pg_catalog.now()
     FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Código não encontrado ou expirado.'
      USING ERRCODE = 'FA301', DETAIL = 'Código sem solicitação válida.';
  END IF;

  INSERT INTO public.terminal (branch_id, public_key)
  VALUES (p_branch_id, request.public_key)
  RETURNING id INTO new_terminal_id;

  UPDATE public.terminal_pairing_request r
     SET status = 'claimed', terminal_id = new_terminal_id
   WHERE r.id = request.id;

  RETURN new_terminal_id;
END;
$$;

CREATE FUNCTION app.lock_terminal(p_terminal_id uuid, p_code text) RETURNS public.terminal
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.terminal;
BEGIN
  SELECT * INTO target
    FROM public.terminal t
   WHERE t.id = p_terminal_id AND t.deleted_at IS NULL
     FOR UPDATE;
  IF NOT FOUND OR NOT app.has_permission(p_code, target.branch_id) THEN
    RAISE EXCEPTION 'Você não tem permissão para esta operação.'
      USING ERRCODE = 'FA002', DETAIL = pg_catalog.format('Terminal %s sem %s.', p_terminal_id, p_code);
  END IF;
  RETURN target;
END;
$$;

CREATE OR REPLACE FUNCTION app.approve_terminal(p_terminal_id uuid, p_name text, p_profile text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.terminal := app.lock_terminal(p_terminal_id, 'terminals.approve');
BEGIN
  IF target.status <> 'pending' THEN
    RAISE EXCEPTION 'Esta mudança de situação não é permitida para o terminal.'
      USING ERRCODE = 'FA303', DETAIL = pg_catalog.format('Aprovação com situação %s.', target.status);
  END IF;

  UPDATE public.terminal t
     SET name = pg_catalog.btrim(p_name), profile = p_profile, status = 'active'
   WHERE t.id = p_terminal_id;
END;
$$;

-- Recusar um terminal pendente faz parte da aprovação; revogar um aprovado é outra permissão.
CREATE OR REPLACE FUNCTION app.set_terminal_status(p_terminal_id uuid, p_status text, p_reason text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  current_status text := (SELECT t.status FROM public.terminal t WHERE t.id = p_terminal_id);
  target public.terminal := app.lock_terminal(
    p_terminal_id,
    CASE
      WHEN p_status <> 'revoked' THEN 'terminals.block'
      WHEN current_status = 'pending' THEN 'terminals.approve'
      ELSE 'terminals.revoke'
    END
  );
  reason text := NULLIF(pg_catalog.btrim(COALESCE(p_reason, '')), '');
BEGIN
  IF p_status IN ('blocked', 'revoked') AND reason IS NULL THEN
    RAISE EXCEPTION 'Informe o motivo desta ação.'
      USING ERRCODE = 'FA302', DETAIL = pg_catalog.format('Mudança para %s sem motivo.', p_status);
  END IF;

  -- Aprovar tem função própria, que exige nome e perfil.
  IF p_status = target.status OR (p_status = 'active' AND target.status <> 'blocked') THEN
    RAISE EXCEPTION 'Esta mudança de situação não é permitida para o terminal.'
      USING ERRCODE = 'FA303', DETAIL = pg_catalog.format('%s para %s.', target.status, p_status);
  END IF;

  PERFORM pg_catalog.set_config('app.status_reason', COALESCE(reason, ''), true);
  UPDATE public.terminal t SET status = p_status WHERE t.id = p_terminal_id;
  PERFORM pg_catalog.set_config('app.status_reason', '', true);
END;
$$;

-- Senha temporária de alguém com mais poder seria uma forma de tomar a conta dele.
CREATE OR REPLACE FUNCTION app.set_temporary_password(p_user_id uuid, p_new_hash text, p_ip text) RETURNS void
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

  IF NOT FOUND
     OR NOT app.can_on_user('users.reset_password', p_user_id)
     OR NOT app.covers_user(p_user_id) THEN
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

CREATE OR REPLACE FUNCTION app.user_ids_with_access() RETURNS uuid[]
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE(pg_catalog.array_agg(c.user_id), '{}')
    FROM public.user_credential c
   WHERE c.deleted_at IS NULL
     AND app.can_on_user('users.view', c.user_id)
$$;

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

-- Políticas: as mesmas tabelas, agora decididas por permissão.
DROP POLICY branch_select ON branch;
DROP POLICY branch_insert ON branch;
DROP POLICY branch_update ON branch;
DROP POLICY economic_group_select ON economic_group;
DROP POLICY economic_group_update ON economic_group;
DROP POLICY company_select ON company;
DROP POLICY company_insert ON company;
DROP POLICY company_update ON company;
DROP POLICY region_select ON region;
DROP POLICY region_insert ON region;
DROP POLICY region_update ON region;
DROP POLICY branch_group_select ON branch_group;
DROP POLICY branch_group_insert ON branch_group;
DROP POLICY branch_group_update ON branch_group;
DROP POLICY terminal_select ON terminal;
DROP POLICY terminal_insert ON terminal;
DROP POLICY terminal_update ON terminal;
DROP POLICY user_account_select ON user_account;
DROP POLICY user_account_insert ON user_account;
DROP POLICY user_account_update ON user_account;
DROP POLICY user_branch_select ON user_branch;
DROP POLICY user_branch_insert ON user_branch;
DROP POLICY user_branch_update ON user_branch;
DROP POLICY auth_event_select ON auth_event;

CREATE POLICY branch_select ON branch FOR SELECT TO farmaerp_app
  USING (
    id = ANY ((SELECT app.allowed_branch_ids())::uuid[])
    OR app.company_has_permission(company_id, 'structure.manage')
  );
CREATE POLICY branch_insert ON branch FOR INSERT TO farmaerp_app
  WITH CHECK (app.company_has_permission(company_id, 'structure.manage'));
CREATE POLICY branch_update ON branch FOR UPDATE TO farmaerp_app
  USING (app.company_has_permission(company_id, 'structure.manage'))
  WITH CHECK (app.company_has_permission(company_id, 'structure.manage'));

CREATE POLICY economic_group_select ON economic_group FOR SELECT TO farmaerp_app
  USING (
    id = (SELECT app.permission_group('branches.view_all'))
    OR EXISTS (SELECT 1 FROM company c WHERE c.economic_group_id = economic_group.id)
  );
CREATE POLICY economic_group_update ON economic_group FOR UPDATE TO farmaerp_app
  USING (id = (SELECT app.permission_group('structure.manage')))
  WITH CHECK (id = (SELECT app.permission_group('structure.manage')));

CREATE POLICY company_select ON company FOR SELECT TO farmaerp_app
  USING (
    economic_group_id = (SELECT app.permission_group('branches.view_all'))
    OR economic_group_id = (SELECT app.permission_group('structure.manage'))
    OR EXISTS (SELECT 1 FROM branch b WHERE b.company_id = company.id)
  );
CREATE POLICY company_insert ON company FOR INSERT TO farmaerp_app
  WITH CHECK (economic_group_id = (SELECT app.permission_group('structure.manage')));
CREATE POLICY company_update ON company FOR UPDATE TO farmaerp_app
  USING (economic_group_id = (SELECT app.permission_group('structure.manage')))
  WITH CHECK (economic_group_id = (SELECT app.permission_group('structure.manage')));

CREATE POLICY region_select ON region FOR SELECT TO farmaerp_app
  USING (
    app.branch_group_has_permission(branch_group_id, 'branches.view_all')
    OR app.branch_group_has_permission(branch_group_id, 'structure.manage')
    OR EXISTS (SELECT 1 FROM branch b WHERE b.region_id = region.id)
  );
CREATE POLICY region_insert ON region FOR INSERT TO farmaerp_app
  WITH CHECK (app.branch_group_has_permission(branch_group_id, 'structure.manage'));
CREATE POLICY region_update ON region FOR UPDATE TO farmaerp_app
  USING (app.branch_group_has_permission(branch_group_id, 'structure.manage'))
  WITH CHECK (app.branch_group_has_permission(branch_group_id, 'structure.manage'));

CREATE POLICY branch_group_select ON branch_group FOR SELECT TO farmaerp_app
  USING (
    economic_group_id = (SELECT app.permission_group('branches.view_all'))
    OR economic_group_id = (SELECT app.permission_group('structure.manage'))
    OR EXISTS (SELECT 1 FROM region r WHERE r.branch_group_id = branch_group.id)
  );
CREATE POLICY branch_group_insert ON branch_group FOR INSERT TO farmaerp_app
  WITH CHECK (economic_group_id = (SELECT app.permission_group('structure.manage')));
CREATE POLICY branch_group_update ON branch_group FOR UPDATE TO farmaerp_app
  USING (economic_group_id = (SELECT app.permission_group('structure.manage')))
  WITH CHECK (economic_group_id = (SELECT app.permission_group('structure.manage')));

CREATE POLICY terminal_select ON terminal FOR SELECT TO farmaerp_app
  USING (app.has_permission('terminals.view', branch_id));
CREATE POLICY terminal_insert ON terminal FOR INSERT TO farmaerp_app
  WITH CHECK (app.has_permission('terminals.request', branch_id));
CREATE POLICY terminal_update ON terminal FOR UPDATE TO farmaerp_app
  USING (app.has_permission('terminals.approve', branch_id))
  WITH CHECK (app.has_permission('terminals.approve', branch_id));

CREATE POLICY user_account_select ON user_account FOR SELECT TO farmaerp_app
  USING (
    id = (SELECT app.current_user_id())
    OR economic_group_id = (SELECT app.permission_group('users.manage'))
    OR app.can_on_user('users.view', id)
  );
CREATE POLICY user_account_insert ON user_account FOR INSERT TO farmaerp_app
  WITH CHECK (economic_group_id = (SELECT app.permission_group('users.manage')));
CREATE POLICY user_account_update ON user_account FOR UPDATE TO farmaerp_app
  USING (app.can_manage_user(id))
  WITH CHECK (app.can_manage_user(id));

-- Quem gerencia só vincula a filiais que alcança: senão ampliaria a própria visão.
CREATE POLICY user_branch_select ON user_branch FOR SELECT TO farmaerp_app
  USING (
    user_id = (SELECT app.current_user_id())
    OR app.can_on_user('users.view', user_id)
    OR app.can_on_user('users.manage', user_id)
  );
CREATE POLICY user_branch_insert ON user_branch FOR INSERT TO farmaerp_app
  WITH CHECK (
    app.can_manage_user(user_id)
    AND branch_id = ANY ((SELECT app.allowed_branch_ids())::uuid[])
  );
CREATE POLICY user_branch_update ON user_branch FOR UPDATE TO farmaerp_app
  USING (app.can_manage_user(user_id))
  WITH CHECK (app.can_manage_user(user_id));

CREATE POLICY auth_event_select ON auth_event FOR SELECT TO farmaerp_app
  USING (app.can_on_user('audit.view', user_id));

-- O catálogo e os perfis do grupo não são sigilosos. Quem escreve são as funções acima.
CREATE POLICY permission_select ON permission FOR SELECT TO farmaerp_app
  USING ((SELECT app.current_user_group()) IS NOT NULL);
CREATE POLICY role_select ON role FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group()));
CREATE POLICY role_permission_select ON role_permission FOR SELECT TO farmaerp_app
  USING (EXISTS (SELECT 1 FROM role r WHERE r.id = role_permission.role_id));
CREATE POLICY user_role_select ON user_role FOR SELECT TO farmaerp_app
  USING (
    user_id = (SELECT app.current_user_id())
    OR app.can_on_user('users.view', user_id)
    OR app.can_on_user('roles.assign', user_id)
  );

GRANT SELECT ON permission, role, role_permission, user_role TO farmaerp_app;

CREATE VIEW v_permission WITH (security_invoker = true) AS
  SELECT * FROM permission WHERE deleted_at IS NULL;
CREATE VIEW v_role WITH (security_invoker = true) AS
  SELECT * FROM role WHERE deleted_at IS NULL;
CREATE VIEW v_role_permission WITH (security_invoker = true) AS
  SELECT * FROM role_permission WHERE deleted_at IS NULL;
CREATE VIEW v_user_role WITH (security_invoker = true) AS
  SELECT * FROM user_role WHERE deleted_at IS NULL;
GRANT SELECT ON v_permission, v_role, v_role_permission, v_user_role TO farmaerp_app;

-- is_group_admin sai de vez: manter os dois modelos abriria espaço para regras divergentes.
DROP FUNCTION app.lock_terminal_for_admin(uuid);
DROP FUNCTION app.is_admin_of_branch(uuid);
DROP FUNCTION app.is_admin_of_company(uuid);
DROP FUNCTION app.is_admin_of_branch_group(uuid);
DROP FUNCTION app.admin_economic_group_id();

DROP VIEW v_user_account;
ALTER TABLE user_account DROP COLUMN is_group_admin;
CREATE VIEW v_user_account WITH (security_invoker = true) AS
  SELECT * FROM user_account WHERE deleted_at IS NULL;
GRANT SELECT ON v_user_account TO farmaerp_app;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  app.current_user_group(),
  app.has_permission(text, uuid),
  app.has_permission_anywhere(text),
  app.permission_group(text),
  app.company_has_permission(uuid, text),
  app.branch_group_has_permission(uuid, text),
  app.can_on_user(text, uuid),
  app.covers_role(uuid, uuid),
  app.covers_user(uuid),
  app.can_manage_user(uuid),
  app.create_role(text, text, text[]),
  app.update_role(uuid, text, text, text[]),
  app.delete_role(uuid),
  app.assign_role(uuid, uuid, uuid),
  app.unassign_role(uuid)
TO farmaerp_app;
