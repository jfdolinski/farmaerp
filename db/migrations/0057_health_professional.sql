-- Up Migration

-- Profissionais da saúde (prescritores), por grupo econômico.
-- Cadastro na retaguarda (permissão health_professionals.manage, de Gerente e Farmacêutico) e no
-- caixa, na hora de lançar a receita: o cadastro rápido sobe pela outbox. O mesmo conselho, número
-- e UF não se repete; o caixa que manda um profissional já cadastrado não gera conflito (a central
-- fica com o que já tinha). Todos descem para os caixas do grupo, para a busca na receita.
-- A receita da venda continua guardando o prescritor por extenso: o cadastro só ajuda a preencher.

CREATE TABLE health_professional (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  name text NOT NULL CONSTRAINT health_professional_name_check CHECK (length(btrim(name)) BETWEEN 3 AND 150 AND name = btrim(name)),
  council text NOT NULL CONSTRAINT health_professional_council_check CHECK (council IN ('CRM', 'CRO', 'CRMV', 'COREN', 'CRF', 'RMS')),
  registration text NOT NULL CONSTRAINT health_professional_registration_check CHECK (registration ~ '^[0-9A-Za-z-]{1,20}$'),
  state char(2) NOT NULL CONSTRAINT health_professional_state_check CHECK (state ~ '^[A-Z]{2}$'),
  specialty text CONSTRAINT health_professional_specialty_check CHECK (length(btrim(specialty)) BETWEEN 2 AND 100),
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
-- O número no conselho vale sem zeros à esquerda e sem diferença de maiúsculas.
CREATE UNIQUE INDEX health_professional_registration_key ON health_professional
  (economic_group_id, council, state, upper(ltrim(registration, '0'))) WHERE deleted_at IS NULL;
CREATE INDEX health_professional_economic_group_id_idx ON health_professional (economic_group_id);
CALL app.apply_table_standard('public.health_professional');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON health_professional
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns('economic_group_id');
CREATE POLICY health_professional_select ON health_professional FOR SELECT TO farmaerp_app
  USING (economic_group_id = app.current_user_group());
CREATE VIEW v_health_professional WITH (security_invoker = true) AS
  SELECT * FROM health_professional WHERE deleted_at IS NULL;
GRANT SELECT ON health_professional, v_health_professional TO farmaerp_app;

INSERT INTO permission (code, module, name) VALUES
  ('health_professionals.manage', 'Controlados', 'Cadastrar profissionais da saúde (prescritores)');

INSERT INTO role_permission (role_id, permission_id)
SELECT r.id, p.id
  FROM role r
  JOIN permission p ON p.code = 'health_professionals.manage'
 WHERE r.deleted_at IS NULL AND r.system_key IS NULL AND r.name IN ('Farmacêutico', 'Gerente')
   AND NOT EXISTS (
     SELECT 1 FROM role_permission rp WHERE rp.role_id = r.id AND rp.permission_id = p.id AND rp.deleted_at IS NULL
   );

-- Inclui (p_id nulo) ou altera. Repetido: FA733; dados inválidos: FA734.
CREATE FUNCTION app.save_health_professional(p_id uuid, p_data jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.current_user_group();
  saved uuid;
BEGIN
  IF NOT app.has_permission_anywhere('health_professionals.manage') THEN
    RAISE EXCEPTION 'Você não tem permissão para esta operação.'
      USING ERRCODE = 'FA002', DETAIL = 'Profissional sem health_professionals.manage.';
  END IF;
  IF pg_catalog.jsonb_typeof(p_data) IS DISTINCT FROM 'object'
     OR (p_data ? 'active' AND pg_catalog.jsonb_typeof(p_data -> 'active') IS DISTINCT FROM 'boolean') THEN
    RAISE EXCEPTION 'Os dados do profissional são inválidos.' USING ERRCODE = 'FA734';
  END IF;
  BEGIN
    IF p_id IS NULL THEN
      INSERT INTO public.health_professional (economic_group_id, name, council, registration, state, specialty, active)
      VALUES (group_id, app.clean_text(p_data ->> 'name'), p_data ->> 'council', app.clean_text(p_data ->> 'registration'),
              pg_catalog.upper(app.clean_text(p_data ->> 'state')), app.clean_text(p_data ->> 'specialty'),
              COALESCE((p_data ->> 'active')::boolean, true))
      RETURNING id INTO saved;
    ELSE
      UPDATE public.health_professional hp
         SET name = app.clean_text(p_data ->> 'name'), council = p_data ->> 'council',
             registration = app.clean_text(p_data ->> 'registration'), state = pg_catalog.upper(app.clean_text(p_data ->> 'state')),
             specialty = app.clean_text(p_data ->> 'specialty'), active = COALESCE((p_data ->> 'active')::boolean, hp.active)
       WHERE hp.id = p_id AND hp.economic_group_id = group_id AND hp.deleted_at IS NULL
      RETURNING hp.id INTO saved;
      IF saved IS NULL THEN
        RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
          USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('health_professional %s.', p_id);
      END IF;
    END IF;
  EXCEPTION
    WHEN unique_violation THEN
      RAISE EXCEPTION 'Já existe um profissional com este conselho, número e UF.' USING ERRCODE = 'FA733';
    WHEN not_null_violation OR check_violation THEN
      RAISE EXCEPTION 'Os dados do profissional são inválidos.' USING ERRCODE = 'FA734', DETAIL = SQLERRM;
  END;
  RETURN saved;
END;
$$;

-- Lista da retaguarda (e de quem vê controlados), com busca por nome ou número.
CREATE FUNCTION app.list_health_professionals(p_search text, p_include_inactive boolean)
RETURNS TABLE (
  id uuid, name text, council text, registration text, state text, specialty text, active boolean,
  updated_at timestamptz, can_manage boolean
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  term text := pg_catalog.lower(app.clean_text(p_search));
  allowed boolean := app.has_permission_anywhere('health_professionals.manage');
BEGIN
  IF NOT allowed AND NOT app.has_permission_anywhere('controlled.view') THEN
    RAISE EXCEPTION 'Você não tem permissão para esta operação.'
      USING ERRCODE = 'FA002', DETAIL = 'Lista de profissionais sem permissão.';
  END IF;
  RETURN QUERY
  SELECT hp.id, hp.name, hp.council, hp.registration, hp.state::text, hp.specialty, hp.active, hp.updated_at, allowed
    FROM public.health_professional hp
   WHERE hp.economic_group_id = app.current_user_group() AND hp.deleted_at IS NULL
     AND (hp.active OR COALESCE(p_include_inactive, false))
     AND (term IS NULL OR pg_catalog.lower(hp.name) LIKE '%' || term || '%'
          OR pg_catalog.upper(pg_catalog.ltrim(hp.registration, '0')) = pg_catalog.upper(pg_catalog.ltrim(term, '0')))
   ORDER BY hp.name, hp.council, hp.registration
   LIMIT 500;
END;
$$;

-- Cadastro rápido feito no caixa. O id é o do caixa (idempotente pela outbox). Profissional que a
-- central já tem (mesmo conselho, número e UF) não muda nada. Dado inválido vira conflito (FA734).
CREATE FUNCTION app.sync_apply_health_professional(p_group_id uuid, p_payload jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  BEGIN
    INSERT INTO public.health_professional (id, economic_group_id, name, council, registration, state, specialty)
    VALUES ((p_payload ->> 'id')::uuid, p_group_id, app.clean_text(p_payload ->> 'name'), p_payload ->> 'council',
            app.clean_text(p_payload ->> 'registration'), pg_catalog.upper(app.clean_text(p_payload ->> 'state')),
            app.clean_text(p_payload ->> 'specialty'));
  EXCEPTION
    WHEN unique_violation THEN
      IF NOT EXISTS (
        SELECT 1 FROM public.health_professional hp
         WHERE hp.economic_group_id = p_group_id AND hp.deleted_at IS NULL AND hp.council = p_payload ->> 'council'
           AND hp.state = pg_catalog.upper(app.clean_text(p_payload ->> 'state'))
           AND pg_catalog.upper(pg_catalog.ltrim(hp.registration, '0'))
               = pg_catalog.upper(pg_catalog.ltrim(app.clean_text(p_payload ->> 'registration'), '0'))
      ) THEN
        -- O id já existe em outro registro: não é o mesmo profissional.
        RAISE EXCEPTION 'Os dados do profissional são inválidos.' USING ERRCODE = 'FA734', DETAIL = 'Id já usado.';
      END IF;
    WHEN not_null_violation OR check_violation OR invalid_text_representation THEN
      RAISE EXCEPTION 'Os dados do profissional são inválidos.' USING ERRCODE = 'FA734', DETAIL = SQLERRM;
  END;
END;
$$;

ALTER TABLE sync_change DROP CONSTRAINT sync_change_entity_check;
ALTER TABLE sync_change ADD CONSTRAINT sync_change_entity_check CHECK (entity IN (
  'product', 'catalog_product', 'manufacturer', 'stock', 'user', 'role', 'branch', 'fiscal', 'customer', 'discount_rule',
  'health_professional'
));

-- Toda mudança desce para os caixas do grupo.
CREATE FUNCTION app.track_health_professional() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM app.mark_sync_change('health_professional', NEW.id, NEW.economic_group_id, NULL);
  RETURN NULL;
END;
$$;
CREATE TRIGGER track_sync_change AFTER INSERT OR UPDATE ON health_professional
  FOR EACH ROW EXECUTE FUNCTION app.track_health_professional();

-- Dados do profissional para o PDV. Inativo ou apagado desce vazio (o PDV apaga).
CREATE FUNCTION app.pdv_health_professional_data(p_group_id uuid, p_ids uuid[])
RETURNS TABLE (id uuid, data jsonb)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT ids.id,
         CASE WHEN hp.id IS NOT NULL THEN pg_catalog.jsonb_build_object(
           'name', hp.name, 'council', hp.council, 'registration', hp.registration, 'state', hp.state,
           'specialty', hp.specialty) END
    FROM pg_catalog.unnest(p_ids) AS ids(id)
    LEFT JOIN public.health_professional hp
      ON hp.id = ids.id AND hp.economic_group_id = p_group_id AND hp.deleted_at IS NULL AND hp.active
$$;

-- Perfis padrão de grupos novos: Gerente e Farmacêutico cadastram profissionais.

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
    (p_group_id, 'Farmacêutico', 'Libera a venda de controlados no PDV e confere o SNGPC.'),
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
     'users.release_login', 'users.biometrics', 'credit.view', 'credit.manage', 'health_professionals.manage'
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
    JOIN public.permission p ON p.code IN ('sales.sell', 'sales.quote', 'controlled.dispense', 'controlled.view', 'sngpc.manage',
                                           'health_professionals.manage')
   WHERE r.economic_group_id = p_group_id AND r.name = 'Farmacêutico';
  PERFORM app.seed_manager_limits(manager_id, p_group_id);
END;
$$;

-- Subida: o cadastro rápido feito no caixa.

CREATE OR REPLACE FUNCTION app.pdv_apply_item(
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
    WHEN 'credit_payment' THEN
      PERFORM app.sync_apply_credit_payment(p_terminal, p_group_id, p_payload);
    WHEN 'health_professional' THEN
      PERFORM app.sync_apply_health_professional(p_group_id, p_payload);
    ELSE
      RAISE EXCEPTION 'O terminal enviou um tipo de registro desconhecido.'
        USING ERRCODE = 'FA959', DETAIL = pg_catalog.format('Tipo %s.', p_kind);
  END CASE;
END;
$$;

-- Descida: os profissionais entram como o 7º tipo.

CREATE OR REPLACE FUNCTION app.pdv_targets(p_branch_id uuid, p_group_id uuid, p_terminal_id uuid, p_since xid8, p_until xid8)
RETURNS TABLE (rank integer, id uuid)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  WITH changed AS (
    SELECT sc.entity, sc.entity_id
      FROM public.sync_change sc
     WHERE p_since IS NOT NULL AND sc.deleted_at IS NULL
       AND sc.xid >= p_since AND sc.xid < p_until
       AND (sc.economic_group_id IS NULL OR sc.economic_group_id = p_group_id)
       AND (sc.branch_id IS NULL OR sc.branch_id = p_branch_id)
  ),
  branch_products AS (
    SELECT s.product_id AS id
      FROM public.product_branch_status s
      JOIN public.product p ON p.id = s.product_id AND p.deleted_at IS NULL
     WHERE s.branch_id = p_branch_id AND s.deleted_at IS NULL AND p.economic_group_id = p_group_id
       AND app.pdv_product_in_scope(s.product_id, p_branch_id)
  ),
  products AS (
    SELECT bp.id FROM branch_products bp
     WHERE p_since IS NULL OR EXISTS (SELECT 1 FROM changed WHERE entity = 'branch')
    UNION
    SELECT c.entity_id FROM changed c WHERE c.entity = 'product'
    UNION
    SELECT p.id FROM changed c
      JOIN public.product p ON p.catalog_product_id = c.entity_id AND p.economic_group_id = p_group_id
     WHERE c.entity = 'catalog_product'
    UNION
    SELECT p.id FROM changed c
      JOIN public.catalog_product cp ON cp.manufacturer_id = c.entity_id
      JOIN public.product p ON p.catalog_product_id = cp.id AND p.economic_group_id = p_group_id
     WHERE c.entity = 'manufacturer'
    -- Bloqueado só desce com saldo: a mudança no estoque pode incluir ou retirar o produto.
    UNION
    SELECT c.entity_id FROM changed c
      JOIN public.product_branch_status s ON s.product_id = c.entity_id AND s.branch_id = p_branch_id
       AND s.deleted_at IS NULL AND s.status = 'blocked'
     WHERE c.entity = 'stock'
  ),
  stock AS (
    SELECT bp.id FROM branch_products bp WHERE p_since IS NULL
    UNION
    SELECT c.entity_id FROM changed c WHERE c.entity IN ('stock', 'product')
  ),
  users AS (
    SELECT u.id FROM public.user_account u
     WHERE p_since IS NULL AND u.economic_group_id = p_group_id AND u.deleted_at IS NULL
       AND EXISTS (SELECT 1 FROM app.user_roles_at(u.id, p_branch_id))
    UNION
    SELECT c.entity_id FROM changed c WHERE c.entity = 'user'
    UNION
    SELECT ur.user_id FROM changed c
      JOIN public.user_role ur ON ur.role_id = c.entity_id
     WHERE c.entity = 'role'
  ),
  customers AS (
    SELECT cc.customer_id AS id FROM public.pdv_customer_cache cc
     WHERE p_since IS NULL AND cc.terminal_id = p_terminal_id AND cc.deleted_at IS NULL
    UNION
    SELECT c.entity_id FROM changed c
      JOIN public.pdv_customer_cache cc
        ON cc.customer_id = c.entity_id AND cc.terminal_id = p_terminal_id AND cc.deleted_at IS NULL
     WHERE c.entity = 'customer'
    -- Crediário: quem deve desce para toda a rede. Mudança no crediário desce (ou retira, quando o
    -- débito acaba e o terminal não guardou o cliente).
    UNION
    SELECT a.customer_id FROM public.credit_account a
     WHERE p_since IS NULL AND a.economic_group_id = p_group_id AND a.deleted_at IS NULL
       AND app.credit_has_debt(a.customer_id)
    UNION
    SELECT c.entity_id FROM changed c
      JOIN public.credit_account a ON a.customer_id = c.entity_id AND a.economic_group_id = p_group_id
     WHERE c.entity = 'customer'
  ),
  discounts AS (
    SELECT r.id FROM public.discount_rule r
     WHERE p_since IS NULL AND r.economic_group_id = p_group_id AND r.deleted_at IS NULL
       AND (r.branch_id IS NULL OR r.branch_id = p_branch_id)
       AND (r.valid_to IS NULL OR r.valid_to > pg_catalog.now())
    UNION
    SELECT c.entity_id FROM changed c WHERE c.entity = 'discount_rule'
  ),
  professionals AS (
    SELECT hp.id FROM public.health_professional hp
     WHERE p_since IS NULL AND hp.economic_group_id = p_group_id AND hp.deleted_at IS NULL AND hp.active
    UNION
    SELECT c.entity_id FROM changed c WHERE c.entity = 'health_professional'
  )
  SELECT 1, p_branch_id
   WHERE p_since IS NULL OR EXISTS (SELECT 1 FROM changed WHERE entity IN ('fiscal', 'branch'))
  UNION ALL SELECT 2, users.id FROM users
  UNION ALL SELECT 3, products.id FROM products
  UNION ALL SELECT 4, stock.id FROM stock
  UNION ALL SELECT 5, customers.id FROM customers
  UNION ALL SELECT 6, discounts.id FROM discounts
  UNION ALL SELECT 7, professionals.id FROM professionals
$$;

CREATE OR REPLACE FUNCTION app.pdv_pull(p_cursor text, p_until text, p_after text, p_limit integer)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  terminal_row public.terminal;
  group_id uuid;
  since xid8;
  until xid8;
  after_rank integer := 0;
  after_id uuid := '00000000-0000-0000-0000-000000000000';
  page_rank integer[];
  page_id uuid[];
  items jsonb := '[]'::jsonb;
  next_token text;
  total bigint;
  fiscal jsonb;
BEGIN
  SELECT t.* INTO terminal_row FROM public.terminal t
   WHERE t.id = app.current_terminal_id() AND t.deleted_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Não foi possível confirmar a identidade do terminal.'
      USING ERRCODE = 'FA306', DETAIL = 'Descida sem app.terminal_id válido.';
  ELSIF terminal_row.status = 'pending' THEN
    RAISE EXCEPTION 'Este terminal ainda não foi aprovado.' USING ERRCODE = 'FA307';
  ELSIF terminal_row.status = 'blocked' THEN
    RAISE EXCEPTION 'Este terminal está bloqueado.' USING ERRCODE = 'FA304';
  ELSIF terminal_row.status = 'revoked' THEN
    RAISE EXCEPTION 'Este terminal foi revogado.' USING ERRCODE = 'FA305';
  END IF;

  IF (p_cursor IS NOT NULL AND p_cursor !~ '^[0-9]{1,19}$')
     OR (p_until IS NOT NULL AND p_until !~ '^[0-9]{1,19}$')
     OR (p_after IS NOT NULL AND (p_until IS NULL OR p_after !~ '^[1-7]:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'))
     OR p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 5000 THEN
    RAISE EXCEPTION 'Os dados da sincronização são inválidos.'
      USING ERRCODE = 'FA956', DETAIL = 'Cursor, janela, posição ou tamanho do pacote fora do formato.';
  END IF;

  SELECT c.economic_group_id INTO group_id
    FROM public.branch b JOIN public.company c ON c.id = b.company_id
   WHERE b.id = terminal_row.branch_id;

  since := p_cursor::xid8;
  until := COALESCE(p_until::xid8, pg_catalog.pg_snapshot_xmin(pg_catalog.pg_current_snapshot()));
  -- O cursor nunca volta: sem janela nova, nada desce.
  IF since IS NOT NULL AND since > until THEN
    until := since;
  END IF;
  IF p_after IS NOT NULL THEN
    after_rank := pg_catalog.split_part(p_after, ':', 1)::integer;
    after_id := pg_catalog.split_part(p_after, ':', 2)::uuid;
  END IF;

  IF p_after IS NULL THEN
    SELECT pg_catalog.count(*) INTO total
      FROM (SELECT DISTINCT tg.rank, tg.id FROM app.pdv_targets(terminal_row.branch_id, group_id, terminal_row.id, since, until) tg) t;
  END IF;

  SELECT pg_catalog.array_agg(t.rank ORDER BY t.rank, t.id), pg_catalog.array_agg(t.id ORDER BY t.rank, t.id)
    INTO page_rank, page_id
    FROM (
      SELECT DISTINCT tg.rank, tg.id
        FROM app.pdv_targets(terminal_row.branch_id, group_id, terminal_row.id, since, until) tg
       WHERE (tg.rank, tg.id) > (after_rank, after_id)
       ORDER BY tg.rank, tg.id
       LIMIT p_limit + 1
    ) t;

  IF pg_catalog.cardinality(page_id) > p_limit THEN
    next_token := page_rank[p_limit] || ':' || page_id[p_limit];
    page_rank := page_rank[1:p_limit];
    page_id := page_id[1:p_limit];
  END IF;

  IF 1 = ANY (page_rank) THEN
    fiscal := app.pdv_fiscal_data(terminal_row.branch_id, terminal_row.id);
    items := items || pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
      'type', 'fiscal', 'id', terminal_row.branch_id, 'data', fiscal));
  END IF;

  SELECT items || COALESCE(pg_catalog.jsonb_agg(page.item ORDER BY page.rank_order, page.id), '[]'::jsonb) INTO items
    FROM (
      SELECT 2 AS rank_order, d.id, pg_catalog.jsonb_build_object('type', 'user', 'id', d.id, 'data', d.data) AS item
        FROM app.pdv_user_data(terminal_row.branch_id, ARRAY(
          SELECT page_id[i] FROM pg_catalog.generate_subscripts(page_id, 1) i WHERE page_rank[i] = 2)) d
      UNION ALL
      SELECT 3, d.id, pg_catalog.jsonb_build_object('type', 'product', 'id', d.id, 'data', d.data)
        FROM app.pdv_product_data(terminal_row.branch_id, ARRAY(
          SELECT page_id[i] FROM pg_catalog.generate_subscripts(page_id, 1) i WHERE page_rank[i] = 3)) d
      UNION ALL
      SELECT 4, d.id, pg_catalog.jsonb_build_object('type', 'stock', 'id', d.id, 'data', d.data)
        FROM app.pdv_stock_data(terminal_row.branch_id, ARRAY(
          SELECT page_id[i] FROM pg_catalog.generate_subscripts(page_id, 1) i WHERE page_rank[i] = 4)) d
      UNION ALL
      SELECT 5, d.id, pg_catalog.jsonb_build_object('type', 'customer', 'id', d.id, 'data', d.data)
        FROM app.pdv_customer_data(terminal_row.id, ARRAY(
          SELECT page_id[i] FROM pg_catalog.generate_subscripts(page_id, 1) i WHERE page_rank[i] = 5)) d
      UNION ALL
      SELECT 6, d.id, pg_catalog.jsonb_build_object('type', 'discount_rule', 'id', d.id, 'data', d.data)
        FROM app.pdv_discount_rule_data(terminal_row.branch_id, ARRAY(
          SELECT page_id[i] FROM pg_catalog.generate_subscripts(page_id, 1) i WHERE page_rank[i] = 6)) d
      UNION ALL
      SELECT 7, d.id, pg_catalog.jsonb_build_object('type', 'health_professional', 'id', d.id, 'data', d.data)
        FROM app.pdv_health_professional_data(group_id, ARRAY(
          SELECT page_id[i] FROM pg_catalog.generate_subscripts(page_id, 1) i WHERE page_rank[i] = 7)) d
    ) page;

  IF next_token IS NULL THEN
    PERFORM app.record_terminal_sync('pull', until, since IS NULL);
  END IF;

  RETURN pg_catalog.jsonb_build_object(
    'format', app.pdv_sync_format(),
    'until', until::text,
    'total', total,
    'items', items,
    'next', next_token
  );
END;
$$;

-- Formato novo: os caixas recarregam tudo uma vez e recebem os profissionais.
CREATE OR REPLACE FUNCTION app.pdv_sync_format() RETURNS integer
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$ SELECT 8 $$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  app.save_health_professional(uuid, jsonb),
  app.list_health_professionals(text, boolean)
TO farmaerp_app;

