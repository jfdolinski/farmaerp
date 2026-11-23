-- Up Migration

-- Limites de valor por perfil e liberação de supervisor. Cada perfil tem um teto por tipo de
-- limite; quem tem vários perfis na filial fica com o maior. O Administrador não tem teto. Acima
-- do próprio limite, a operação só passa com a liberação de um supervisor presente, cujo limite
-- cubra o valor. A senha do supervisor é conferida na API; aqui fica quem pode liberar o quê.

-- Catálogo fixo dos tipos de limite, como o dos tipos de regra.
CREATE TABLE limit_type (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  code text NOT NULL CONSTRAINT limit_type_code_check CHECK (code ~ '^[a-z_]+$'),
  name text NOT NULL CONSTRAINT limit_type_name_check CHECK (btrim(name) <> ''),
  unit text NOT NULL CONSTRAINT limit_type_unit_check CHECK (unit IN ('percent', 'money')),
  max_value numeric(14, 2) NOT NULL CONSTRAINT limit_type_max_value_check CHECK (max_value > 0),
  description text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE UNIQUE INDEX limit_type_code_key ON limit_type (code) WHERE deleted_at IS NULL;
CALL app.apply_table_standard('public.limit_type');

INSERT INTO limit_type (code, name, unit, max_value, description) VALUES
  ('sale_discount', 'Desconto na venda', 'percent', 100, 'Desconto que a pessoa dá sozinha no PDV. O desconto máximo do produto, no motor de regras, continua valendo.'),
  ('cash_withdrawal', 'Sangria', 'money', 1000000, 'Valor de cada sangria do caixa.'),
  ('credit_sale', 'Venda no crediário', 'money', 1000000, 'Valor de cada venda no crediário.'),
  ('stock_loss', 'Perda ou ajuste de estoque', 'money', 1000000, 'Valor de cada perda, ajuste ou diferença de inventário, pelo custo médio da filial.');

-- Teto de cada perfil. Sem linha, o teto é zero: tudo acima precisa de liberação.
CREATE TABLE role_limit (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  role_id uuid NOT NULL REFERENCES role (id),
  limit_type_id uuid NOT NULL REFERENCES limit_type (id),
  value numeric(14, 2) NOT NULL CONSTRAINT role_limit_value_check CHECK (value >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE UNIQUE INDEX role_limit_active_key ON role_limit (role_id, limit_type_id) WHERE deleted_at IS NULL;
CREATE INDEX role_limit_limit_type_id_idx ON role_limit (limit_type_id);
CALL app.apply_table_standard('public.role_limit');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON role_limit
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns('economic_group_id', 'role_id', 'limit_type_id');

-- O valor respeita o teto do tipo, e o perfil é do grupo e não é o Administrador.
CREATE FUNCTION app.validate_role_limit() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NEW.value > (SELECT t.max_value FROM public.limit_type t WHERE t.id = NEW.limit_type_id) THEN
    RAISE EXCEPTION 'Os dados do limite são inválidos.'
      USING ERRCODE = 'FA954', DETAIL = 'Limite acima do teto do tipo.';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.role r
     WHERE r.id = NEW.role_id AND r.economic_group_id = NEW.economic_group_id AND r.system_key IS NULL
  ) THEN
    RAISE EXCEPTION 'Um dos itens informados não foi encontrado.'
      USING ERRCODE = 'FA004', DETAIL = pg_catalog.format('role %s.', NEW.role_id);
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER validate_parent BEFORE INSERT OR UPDATE ON role_limit
  FOR EACH ROW EXECUTE FUNCTION app.validate_role_limit();

-- Quem pediu, quem liberou, quanto, o limite de cada um e o motivo. Não muda depois.
CREATE TABLE supervisor_release (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  branch_id uuid NOT NULL REFERENCES branch (id),
  action text NOT NULL CONSTRAINT supervisor_release_action_check CHECK (action ~ '^[a-z_]+\.[a-z_]+$'),
  limit_type_id uuid NOT NULL REFERENCES limit_type (id),
  requested_by uuid NOT NULL REFERENCES user_account (id),
  released_by uuid NOT NULL REFERENCES user_account (id),
  value numeric(14, 2) NOT NULL CONSTRAINT supervisor_release_value_check CHECK (value >= 0),
  requester_limit numeric(14, 2) NOT NULL CONSTRAINT supervisor_release_requester_limit_check CHECK (requester_limit >= 0),
  -- Vazio: o supervisor não tem teto (Administrador).
  releaser_limit numeric(14, 2) CONSTRAINT supervisor_release_releaser_limit_check CHECK (releaser_limit >= 0),
  reason text NOT NULL CONSTRAINT supervisor_release_reason_check CHECK (btrim(reason) <> '' AND length(reason) <= 500),
  reference_id uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid,
  CONSTRAINT supervisor_release_people_check CHECK (requested_by <> released_by)
);
CREATE INDEX supervisor_release_branch_recent_idx ON supervisor_release (branch_id, created_at DESC, id DESC);
CREATE INDEX supervisor_release_requested_by_idx ON supervisor_release (requested_by);
CREATE INDEX supervisor_release_released_by_idx ON supervisor_release (released_by);
CREATE INDEX supervisor_release_limit_type_id_idx ON supervisor_release (limit_type_id);
CALL app.apply_table_standard('public.supervisor_release');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON supervisor_release
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'branch_id', 'action', 'limit_type_id', 'requested_by', 'released_by', 'value',
    'requester_limit', 'releaser_limit', 'reason', 'reference_id', 'deleted_at'
  );

INSERT INTO permission (code, module, name) VALUES
  ('releases.view', 'Usuários', 'Ver as liberações de supervisor'),
  ('sales.discount_override', 'Vendas', 'Dar desconto acima do máximo do produto');

-- Valores iniciais do Gerente: exemplos para não travar o que já funciona; ajuste em /perfis.
CREATE FUNCTION app.seed_manager_limits(p_role_id uuid, p_group_id uuid) RETURNS void
LANGUAGE sql SECURITY DEFINER
SET search_path = ''
AS $$
  INSERT INTO public.role_limit (economic_group_id, role_id, limit_type_id, value)
  SELECT p_group_id, p_role_id, t.id, defaults.value
    FROM (VALUES ('sale_discount', 10::numeric), ('cash_withdrawal', 1000), ('credit_sale', 500), ('stock_loss', 500))
         AS defaults (code, value)
    JOIN public.limit_type t ON t.code = defaults.code AND t.deleted_at IS NULL
   WHERE NOT EXISTS (
     SELECT 1 FROM public.role_limit rl WHERE rl.role_id = p_role_id AND rl.limit_type_id = t.id AND rl.deleted_at IS NULL
   )
$$;

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
     'purchases.post', 'releases.view'
   );
  PERFORM app.seed_manager_limits(manager_id, p_group_id);
END;
$$;

-- Grupos que já existem: o Gerente, identificado pelo nome, vê as liberações e recebe os limites iniciais.
INSERT INTO role_permission (role_id, permission_id)
SELECT r.id, p.id
  FROM role r
 CROSS JOIN permission p
 WHERE r.name = 'Gerente' AND r.deleted_at IS NULL AND p.code = 'releases.view'
   AND NOT EXISTS (
     SELECT 1 FROM role_permission rp WHERE rp.role_id = r.id AND rp.permission_id = p.id AND rp.deleted_at IS NULL
   );
SELECT app.seed_manager_limits(r.id, r.economic_group_id)
  FROM role r
 WHERE r.name = 'Gerente' AND r.deleted_at IS NULL AND r.system_key IS NULL;

-- Perfis da pessoa que valem na filial: os sem filial e os da filial, com a pessoa ativa e
-- vinculada a ela, ou com acesso a todas as filiais (Administrador ou branches.view_all, como em
-- app.allowed_branch_ids).
CREATE FUNCTION app.user_roles_at(p_user_id uuid, p_branch_id uuid) RETURNS SETOF public.role
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT r.*
    FROM public.user_account u
    JOIN public.user_role ur ON ur.user_id = u.id AND ur.deleted_at IS NULL
    JOIN public.role r ON r.id = ur.role_id AND r.deleted_at IS NULL
    JOIN public.branch b ON b.id = p_branch_id AND b.deleted_at IS NULL
    JOIN public.company c ON c.id = b.company_id AND c.economic_group_id = u.economic_group_id
   WHERE u.id = p_user_id AND u.deleted_at IS NULL AND u.is_active
     AND (ur.branch_id IS NULL OR ur.branch_id = p_branch_id)
     AND (
       EXISTS (
         SELECT 1 FROM public.user_branch ub WHERE ub.user_id = u.id AND ub.branch_id = p_branch_id AND ub.deleted_at IS NULL
       )
       OR EXISTS (
         SELECT 1 FROM public.user_role all_ur
           JOIN public.role all_r ON all_r.id = all_ur.role_id AND all_r.deleted_at IS NULL
          WHERE all_ur.user_id = u.id AND all_ur.deleted_at IS NULL AND all_ur.branch_id IS NULL
            AND (all_r.system_key = 'administrator' OR EXISTS (
              SELECT 1 FROM public.role_permission rp
                JOIN public.permission p ON p.id = rp.permission_id AND p.deleted_at IS NULL
               WHERE rp.role_id = all_r.id AND rp.deleted_at IS NULL AND p.code = 'branches.view_all'
            ))
       )
     )
$$;

-- Limite da pessoa na filial: o maior entre os perfis dela. Vazio quando não há teto (Administrador).
-- Sem perfil com limite, zero.
CREATE FUNCTION app.user_limit(p_user_id uuid, p_branch_id uuid, p_type text) RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT CASE
    WHEN EXISTS (SELECT 1 FROM app.user_roles_at(p_user_id, p_branch_id) r WHERE r.system_key = 'administrator') THEN NULL
    ELSE COALESCE((
      SELECT pg_catalog.max(rl.value)
        FROM app.user_roles_at(p_user_id, p_branch_id) r
        JOIN public.role_limit rl ON rl.role_id = r.id AND rl.deleted_at IS NULL
        JOIN public.limit_type t ON t.id = rl.limit_type_id AND t.code = p_type AND t.deleted_at IS NULL
    ), 0)
  END
$$;

-- Permissão de outra pessoa na filial (a do supervisor, por exemplo).
CREATE FUNCTION app.user_has_permission(p_user_id uuid, p_code text, p_branch_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM app.user_roles_at(p_user_id, p_branch_id) r
     WHERE r.system_key = 'administrator'
        OR EXISTS (
          SELECT 1 FROM public.role_permission rp
            JOIN public.permission p ON p.id = rp.permission_id AND p.deleted_at IS NULL
           WHERE rp.role_id = r.id AND rp.deleted_at IS NULL AND p.code = p_code
        )
  )
$$;

-- Confere o limite de quem opera e, acima dele, a liberação do supervisor. p_release traz o
-- supervisor (já com a senha conferida pela API) e o motivo. Devolve o id da liberação, se houve.
CREATE FUNCTION app.require_value_release(
  p_type text, p_action text, p_permission text, p_branch_id uuid, p_value numeric, p_release jsonb, p_reference uuid
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  requester uuid := app.current_user_id();
  requester_limit numeric := app.user_limit(app.current_user_id(), p_branch_id, p_type);
  supervisor uuid;
  supervisor_limit numeric;
  release_id uuid;
BEGIN
  IF requester_limit IS NULL OR p_value <= requester_limit THEN
    RETURN NULL;
  END IF;
  supervisor := NULLIF(p_release ->> 'supervisorId', '')::uuid;
  IF supervisor IS NULL THEN
    RAISE EXCEPTION 'Este valor passa do seu limite e precisa da liberação de um supervisor.'
      USING ERRCODE = 'FA949',
            DETAIL = pg_catalog.format('%s: valor %s, limite %s.', p_type, p_value, requester_limit);
  END IF;
  IF supervisor = requester THEN
    RAISE EXCEPTION 'Quem pede não pode liberar para si mesmo.'
      USING ERRCODE = 'FA950', DETAIL = pg_catalog.format('Usuário %s.', requester);
  END IF;
  -- O supervisor precisa atuar na filial e poder fazer a mesma operação.
  IF NOT app.user_has_permission(supervisor, p_permission, p_branch_id) THEN
    RAISE EXCEPTION 'Este supervisor não pode liberar esta operação nesta filial.'
      USING ERRCODE = 'FA951', DETAIL = pg_catalog.format('Supervisor %s sem %s na filial %s.', supervisor, p_permission, p_branch_id);
  END IF;
  supervisor_limit := app.user_limit(supervisor, p_branch_id, p_type);
  IF supervisor_limit IS NOT NULL AND p_value > supervisor_limit THEN
    RAISE EXCEPTION 'O limite do supervisor também não cobre este valor.'
      USING ERRCODE = 'FA952',
            DETAIL = pg_catalog.format('%s: valor %s, limite do supervisor %s.', p_type, p_value, supervisor_limit);
  END IF;
  INSERT INTO public.supervisor_release (
    economic_group_id, branch_id, action, limit_type_id, requested_by, released_by, value, requester_limit,
    releaser_limit, reason, reference_id
  ) VALUES (
    app.current_user_group(), p_branch_id, p_action,
    (SELECT t.id FROM public.limit_type t WHERE t.code = p_type AND t.deleted_at IS NULL),
    requester, supervisor, p_value, requester_limit, supervisor_limit, app.require_reason(p_release ->> 'reason'), p_reference
  ) RETURNING id INTO release_id;
  RETURN release_id;
END;
$$;

-- Valor de uma movimentação de estoque pelo custo médio da filial. Sem custo, zero.
CREATE FUNCTION app.stock_movement_value(p_product_id uuid, p_branch_id uuid, p_quantity numeric) RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT pg_catalog.round(pg_catalog.abs(p_quantity) * COALESCE(app.average_cost(p_product_id, p_branch_id), 0), 2)
$$;

-- Ajuste, perda e inventário passam pelo limite de quem opera.
CREATE OR REPLACE FUNCTION app.adjust_stock(p_data jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  branch uuid := (p_data ->> 'branchId')::uuid;
  direction text := p_data ->> 'direction';
  amount numeric := (p_data ->> 'quantity')::numeric;
  batch_number text := NULLIF(pg_catalog.btrim(COALESCE(p_data ->> 'batchNumber', '')), '');
  clean_reason text := app.require_reason(p_data ->> 'reason');
  product uuid;
  batch uuid;
  new_id uuid;
BEGIN
  PERFORM app.require_stock_permission('stock.adjust', branch);
  product := app.require_product_lookup(p_data ->> 'productLookup');
  PERFORM app.require_positive_quantity(amount);
  IF direction NOT IN ('in', 'out') OR direction IS NULL THEN
    RAISE EXCEPTION 'Os dados da movimentação são inválidos.'
      USING ERRCODE = 'FA810', DETAIL = 'Direção desconhecida.';
  END IF;

  IF batch_number IS NOT NULL THEN
    batch := CASE direction
      WHEN 'in' THEN app.batch_for_entry(
        app.current_user_group(), branch, product, batch_number,
        (p_data ->> 'expiresOn')::date, p_data ->> 'msRegistration'
      )
      ELSE app.find_batch(branch, product, batch_number)
    END;
  END IF;

  INSERT INTO public.stock_movement (economic_group_id, branch_id, product_id, batch_id, movement_type, quantity, reason)
  VALUES (
    app.current_user_group(), branch, product, batch, 'adjustment',
    CASE direction WHEN 'in' THEN amount ELSE -amount END, clean_reason
  ) RETURNING id INTO new_id;
  PERFORM app.require_value_release(
    'stock_loss', 'stock.adjust', 'stock.adjust', branch, app.stock_movement_value(product, branch, amount), p_data -> 'release', new_id
  );
  RETURN new_id;
END;
$$;

CREATE OR REPLACE FUNCTION app.register_stock_loss(p_data jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  branch uuid := (p_data ->> 'branchId')::uuid;
  amount numeric := (p_data ->> 'quantity')::numeric;
  batch_number text := NULLIF(pg_catalog.btrim(COALESCE(p_data ->> 'batchNumber', '')), '');
  clean_reason text := app.require_reason(p_data ->> 'reason');
  product uuid;
  batch uuid;
  new_id uuid;
BEGIN
  PERFORM app.require_stock_permission('stock.loss', branch);
  product := app.require_product_lookup(p_data ->> 'productLookup');
  PERFORM app.require_positive_quantity(amount);
  IF batch_number IS NOT NULL THEN
    batch := app.find_batch(branch, product, batch_number);
  END IF;

  INSERT INTO public.stock_movement (economic_group_id, branch_id, product_id, batch_id, movement_type, quantity, reason)
  VALUES (app.current_user_group(), branch, product, batch, 'loss', -amount, clean_reason)
  RETURNING id INTO new_id;
  PERFORM app.require_value_release(
    'stock_loss', 'stock.loss', 'stock.loss', branch, app.stock_movement_value(product, branch, amount), p_data -> 'release', new_id
  );
  RETURN new_id;
END;
$$;

CREATE OR REPLACE FUNCTION app.count_stock(p_data jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  branch uuid := (p_data ->> 'branchId')::uuid;
  counted numeric := (p_data ->> 'countedQuantity')::numeric;
  batch_number text := NULLIF(pg_catalog.btrim(COALESCE(p_data ->> 'batchNumber', '')), '');
  clean_reason text := app.require_reason(p_data ->> 'reason');
  group_id uuid := app.current_user_group();
  product uuid;
  batch uuid;
  current_quantity numeric;
  new_id uuid;
BEGIN
  PERFORM app.require_stock_permission('stock.adjust', branch);
  product := app.require_product_lookup(p_data ->> 'productLookup');
  IF counted IS NULL OR counted < 0 THEN
    RAISE EXCEPTION 'Os dados da movimentação são inválidos.'
      USING ERRCODE = 'FA810', DETAIL = 'Contagem vazia ou negativa.';
  END IF;

  IF batch_number IS NOT NULL THEN
    batch := CASE WHEN counted > 0
      THEN app.batch_for_entry(group_id, branch, product, batch_number, (p_data ->> 'expiresOn')::date, p_data ->> 'msRegistration')
      ELSE app.find_batch(branch, product, batch_number)
    END;
  END IF;

  SELECT sb.quantity INTO current_quantity
    FROM public.stock_balance sb
   WHERE sb.branch_id = branch AND sb.product_id = product
     AND sb.batch_id IS NOT DISTINCT FROM batch AND sb.deleted_at IS NULL
   FOR UPDATE;

  IF counted = COALESCE(current_quantity, 0) THEN
    RETURN NULL;
  END IF;

  INSERT INTO public.stock_movement (economic_group_id, branch_id, product_id, batch_id, movement_type, quantity, reason)
  VALUES (group_id, branch, product, batch, 'inventory', counted - COALESCE(current_quantity, 0), clean_reason)
  RETURNING id INTO new_id;
  PERFORM app.require_value_release(
    'stock_loss', 'stock.count', 'stock.adjust', branch,
    app.stock_movement_value(product, branch, counted - COALESCE(current_quantity, 0)), p_data -> 'release', new_id
  );
  RETURN new_id;
END;
$$;

-- Desconto: o que a pessoa dá sozinha é o menor entre o limite dela e o máximo do produto. Acima
-- do máximo do produto, só quem tem sales.discount_override. Usado pelo PDV a partir da Etapa 4.
CREATE FUNCTION app.discount_check(p_product_id uuid, p_branch_id uuid, p_percent numeric)
RETURNS TABLE (status text, user_limit numeric, product_limit numeric)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  person numeric := app.user_limit(app.current_user_id(), p_branch_id, 'sale_discount');
  product numeric;
BEGIN
  SELECT r.value INTO product FROM app.resolve_product_rule('max_discount', p_product_id, p_branch_id) AS r;
  user_limit := person;
  product_limit := product;
  status := CASE
    WHEN product IS NOT NULL AND p_percent > product AND NOT app.has_permission('sales.discount_override', p_branch_id)
      THEN 'needs_override'
    WHEN person IS NULL OR p_percent <= person THEN 'allowed'
    ELSE 'needs_release'
  END;
  RETURN NEXT;
END;
$$;

-- Dados para a API conferir a senha do supervisor: só gente do mesmo grupo, ativa, pelo e-mail ou
-- pelo código. Erros de senha bloqueiam a conta como no login.
CREATE FUNCTION app.supervisor_lookup(p_identifier text) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT pg_catalog.jsonb_build_object(
    'userId', u.id,
    'passwordHash', c.password_hash,
    'locked', COALESCE(c.locked_until > pg_catalog.now(), false)
  )
    FROM public.user_account u
    JOIN public.user_credential c ON c.user_id = u.id AND c.deleted_at IS NULL
   WHERE u.economic_group_id = app.current_user_group()
     AND u.deleted_at IS NULL
     AND u.is_active
     AND (
       u.email = pg_catalog.lower(pg_catalog.btrim(p_identifier))
       OR (pg_catalog.btrim(p_identifier) ~ '^[0-9]{1,9}$' AND u.code = pg_catalog.btrim(p_identifier)::bigint)
     )
   LIMIT 1
$$;

-- Limites dos perfis, para a tela /perfis.
CREATE FUNCTION app.role_limits()
RETURNS TABLE (role_id uuid, limit_type_id uuid, code text, name text, unit text, max_value numeric, value numeric)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT r.id, t.id, t.code, t.name, t.unit, t.max_value, rl.value
    FROM public.role r
   CROSS JOIN public.limit_type t
    LEFT JOIN public.role_limit rl ON rl.role_id = r.id AND rl.limit_type_id = t.id AND rl.deleted_at IS NULL
   WHERE r.economic_group_id = app.current_user_group() AND r.deleted_at IS NULL AND r.system_key IS NULL
     AND t.deleted_at IS NULL
     AND (app.has_permission_anywhere('roles.assign') OR app.has_permission_anywhere('roles.manage'))
   ORDER BY r.name, t.name
$$;

-- Troca os limites de um perfil. Valor vazio tira o limite (vira zero).
CREATE FUNCTION app.set_role_limits(p_role_id uuid, p_limits jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.role := app.lock_role_for_manager(p_role_id);
  entry record;
  type_id uuid;
BEGIN
  IF p_limits IS NULL OR pg_catalog.jsonb_typeof(p_limits) <> 'object' THEN
    RAISE EXCEPTION 'Alguns dados informados são inválidos.'
      USING ERRCODE = 'FA005', DETAIL = 'Limites fora do formato.';
  END IF;
  FOR entry IN SELECT key, value FROM pg_catalog.jsonb_each(p_limits) LOOP
    SELECT t.id INTO type_id FROM public.limit_type t WHERE t.code = entry.key AND t.deleted_at IS NULL;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Um dos itens informados não foi encontrado.'
        USING ERRCODE = 'FA004', DETAIL = pg_catalog.format('limit_type %s.', entry.key);
    END IF;
    UPDATE public.role_limit SET deleted_at = pg_catalog.clock_timestamp()
     WHERE role_id = target.id AND limit_type_id = type_id AND deleted_at IS NULL;
    IF pg_catalog.jsonb_typeof(entry.value) = 'number' OR (pg_catalog.jsonb_typeof(entry.value) = 'string' AND entry.value #>> '{}' <> '') THEN
      INSERT INTO public.role_limit (economic_group_id, role_id, limit_type_id, value)
      VALUES (target.economic_group_id, target.id, type_id, (entry.value #>> '{}')::numeric);
    END IF;
  END LOOP;
END;
$$;

-- Liberações das filiais em que a pessoa vê liberações, com as de custo da nota de compra junto.
CREATE FUNCTION app.list_supervisor_releases(
  p_branch_id uuid DEFAULT NULL, p_from date DEFAULT NULL, p_to date DEFAULT NULL, p_action text DEFAULT NULL
)
RETURNS TABLE (
  id uuid, created_at timestamptz, branch_id uuid, branch_name text, action text, limit_name text, unit text,
  value numeric, requester_limit numeric, releaser_limit numeric, requested_by_name text, released_by_name text,
  reason text, reference_id uuid
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT * FROM (
    SELECT sr.id, sr.created_at, sr.branch_id, b.name, sr.action, t.name, t.unit, sr.value, sr.requester_limit,
           sr.releaser_limit, req.name, rel.name, sr.reason, sr.reference_id
      FROM public.supervisor_release sr
      JOIN public.branch b ON b.id = sr.branch_id
      JOIN public.limit_type t ON t.id = sr.limit_type_id
      JOIN public.user_account req ON req.id = sr.requested_by
      JOIN public.user_account rel ON rel.id = sr.released_by
     WHERE sr.economic_group_id = app.current_user_group() AND sr.deleted_at IS NULL
    UNION ALL
    SELECT cr.id, cr.created_at, cr.branch_id, b.name, 'purchases.cost', 'Custo da nota de compra', 'money',
           cr.entry_cost, cr.average_cost, NULL, NULL, rel.name, cr.reason, it.invoice_id
      FROM public.purchase_invoice_item_cost_release cr
      JOIN public.purchase_invoice_item it ON it.id = cr.item_id
      JOIN public.branch b ON b.id = cr.branch_id
      JOIN public.user_account rel ON rel.id = cr.released_by
     WHERE cr.economic_group_id = app.current_user_group()
  ) AS releases (id, created_at, branch_id, branch_name, action, limit_name, unit, value, requester_limit,
                 releaser_limit, requested_by_name, released_by_name, reason, reference_id)
   WHERE app.has_permission('releases.view', releases.branch_id)
     AND (p_branch_id IS NULL OR releases.branch_id = p_branch_id)
     AND (p_from IS NULL OR releases.created_at >= p_from::timestamp AT TIME ZONE 'America/Sao_Paulo')
     AND (p_to IS NULL OR releases.created_at < (p_to + 1)::timestamp AT TIME ZONE 'America/Sao_Paulo')
     AND (p_action IS NULL OR releases.action = p_action)
   ORDER BY releases.created_at DESC, releases.id DESC
   LIMIT 500
$$;

-- Os limites da própria pessoa na filial, para a tela avisar antes de pedir a liberação.
CREATE FUNCTION app.my_limits(p_branch_id uuid)
RETURNS TABLE (code text, name text, unit text, value numeric)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT t.code, t.name, t.unit, app.user_limit(app.current_user_id(), p_branch_id, t.code)
    FROM public.limit_type t
   WHERE t.deleted_at IS NULL AND p_branch_id = ANY (app.allowed_branch_ids())
   ORDER BY t.name
$$;

CREATE POLICY limit_type_select ON limit_type FOR SELECT TO farmaerp_app USING (true);
CREATE POLICY role_limit_select ON role_limit FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group())
         AND (app.has_permission_anywhere('roles.assign') OR app.has_permission_anywhere('roles.manage')));
CREATE POLICY supervisor_release_select ON supervisor_release FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group()) AND app.has_permission('releases.view', branch_id));
GRANT SELECT ON limit_type, role_limit, supervisor_release TO farmaerp_app;

CREATE VIEW v_limit_type WITH (security_invoker = true) AS
  SELECT * FROM limit_type WHERE deleted_at IS NULL;
CREATE VIEW v_role_limit WITH (security_invoker = true) AS
  SELECT * FROM role_limit WHERE deleted_at IS NULL;
CREATE VIEW v_supervisor_release WITH (security_invoker = true) AS
  SELECT * FROM supervisor_release WHERE deleted_at IS NULL;
GRANT SELECT ON v_limit_type, v_role_limit, v_supervisor_release TO farmaerp_app;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  app.adjust_stock(jsonb),
  app.register_stock_loss(jsonb),
  app.count_stock(jsonb),
  app.discount_check(uuid, uuid, numeric),
  app.supervisor_lookup(text),
  app.role_limits(),
  app.set_role_limits(uuid, jsonb),
  app.list_supervisor_releases(uuid, date, date, text),
  app.my_limits(uuid)
TO farmaerp_app;
