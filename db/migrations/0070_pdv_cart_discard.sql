-- Up Migration

-- Parte A do lote de 26/11: no PDV, descartar a venda em andamento ("Limpar tela" no orçamento,
-- "Cancelar venda" no caixa e no autoatendimento), com uma permissão para cada tela, e permissão
-- própria para os botões de cadastro (cliente e prescritor). Sem a permissão, um supervisor que
-- tenha libera no caixa com código e PIN. Cada descarte sobe pela outbox e fica registrado para
-- auditoria; quem liberou sem ter a permissão (perfil mudou enquanto o caixa estava sem internet)
-- fica marcado, como na autenticação do PDV.

INSERT INTO permission (code, module, name) VALUES
  ('pdv.quote_clear', 'Vendas', 'Limpar a tela do orçamento no PDV'),
  ('pdv.sale_cancel', 'Vendas', 'Cancelar a venda em andamento no caixa'),
  ('pdv.self_service_cancel', 'Vendas', 'Cancelar a venda em andamento no autoatendimento'),
  ('pdv.customer_create', 'Vendas', 'Cadastrar cliente no PDV'),
  ('pdv.prescriber_create', 'Controlados', 'Cadastrar prescritor no PDV');

-- Perfis que já existem: pela capacidade que já tinham, para perfil criado ou renomeado pelo
-- cliente não perder o que fazia (antes, cadastrar cliente no caixa pedia só "Vender").
-- Cancelar no caixa e no autoatendimento: só Gerente e Farmacêutico, como nos perfis padrão.
-- O Administrador tem tudo.
INSERT INTO role_permission (role_id, permission_id)
SELECT DISTINCT r.id, p.id
  FROM role r
  JOIN permission p ON (
       (p.code = 'pdv.quote_clear' AND EXISTS (
         SELECT 1 FROM role_permission rp JOIN permission had ON had.id = rp.permission_id
          WHERE rp.role_id = r.id AND rp.deleted_at IS NULL AND had.code = 'sales.quote'))
    OR (p.code = 'pdv.customer_create' AND EXISTS (
         SELECT 1 FROM role_permission rp JOIN permission had ON had.id = rp.permission_id
          WHERE rp.role_id = r.id AND rp.deleted_at IS NULL AND had.code IN ('sales.sell', 'sales.quote')))
    OR (p.code = 'pdv.prescriber_create' AND EXISTS (
         SELECT 1 FROM role_permission rp JOIN permission had ON had.id = rp.permission_id
          WHERE rp.role_id = r.id AND rp.deleted_at IS NULL AND had.code = 'sales.sell'))
    OR (p.code IN ('pdv.sale_cancel', 'pdv.self_service_cancel') AND r.name IN ('Gerente', 'Farmacêutico'))
  )
 WHERE r.deleted_at IS NULL AND r.system_key IS NULL
   AND NOT EXISTS (
     SELECT 1 FROM role_permission rp WHERE rp.role_id = r.id AND rp.permission_id = p.id AND rp.deleted_at IS NULL
   );

-- Perfis padrão de grupos novos.
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
     'users.release_login', 'users.biometrics', 'credit.view', 'credit.manage', 'health_professionals.manage',
     'pdv.quote_clear', 'pdv.sale_cancel', 'pdv.self_service_cancel', 'pdv.customer_create', 'pdv.prescriber_create'
   );
  INSERT INTO public.role_permission (role_id, permission_id)
  SELECT r.id, p.id
    FROM public.role r
    JOIN public.permission p ON p.code IN ('sales.sell', 'sales.quote', 'pdv.quote_clear', 'pdv.customer_create', 'pdv.prescriber_create')
   WHERE r.economic_group_id = p_group_id AND r.name = 'Operador de caixa';
  INSERT INTO public.role_permission (role_id, permission_id)
  SELECT r.id, p.id
    FROM public.role r
    JOIN public.permission p ON p.code IN ('sales.quote', 'pdv.quote_clear', 'pdv.customer_create')
   WHERE r.economic_group_id = p_group_id AND r.name = 'Balconista';
  INSERT INTO public.role_permission (role_id, permission_id)
  SELECT r.id, p.id
    FROM public.role r
    JOIN public.permission p ON p.code IN ('sales.sell', 'sales.quote', 'controlled.dispense', 'controlled.view', 'sngpc.manage',
                                           'health_professionals.manage', 'pdv.quote_clear', 'pdv.sale_cancel',
                                           'pdv.self_service_cancel', 'pdv.customer_create', 'pdv.prescriber_create')
   WHERE r.economic_group_id = p_group_id AND r.name = 'Farmacêutico';
  PERFORM app.seed_manager_limits(manager_id, p_group_id);
END;
$$;

-- Vendas descartadas no PDV antes de concluir. Só sobem do terminal; ninguém altera.
CREATE TABLE pdv_cart_discard (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  branch_id uuid NOT NULL REFERENCES branch (id),
  terminal_id uuid NOT NULL REFERENCES terminal (id),
  -- Tela onde foi descartada: quote (orçamento), cashier (caixa) ou self_service (autoatendimento).
  screen text NOT NULL CONSTRAINT pdv_cart_discard_screen_check CHECK (screen IN ('quote', 'cashier', 'self_service')),
  -- Quem estava no terminal: o operador no caixa, o vendedor no orçamento.
  user_id uuid NOT NULL REFERENCES user_account (id),
  -- Supervisor que liberou (quem estava no terminal não tinha a permissão).
  authorized_by uuid REFERENCES user_account (id),
  items_count integer NOT NULL CONSTRAINT pdv_cart_discard_items_count_check CHECK (items_count BETWEEN 1 AND 10000),
  total numeric(15, 2) NOT NULL CONSTRAINT pdv_cart_discard_total_check CHECK (total >= 0),
  discarded_at timestamptz NOT NULL,
  -- release_permission: quem liberou (ou quem descartou sozinho) não tinha a permissão da tela.
  alert text CONSTRAINT pdv_cart_discard_alert_check CHECK (alert IN ('release_permission')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid,
  CONSTRAINT pdv_cart_discard_self_check CHECK (authorized_by IS NULL OR authorized_by <> user_id)
);
CREATE INDEX pdv_cart_discard_branch_idx ON pdv_cart_discard (branch_id, discarded_at DESC);
CREATE INDEX pdv_cart_discard_user_idx ON pdv_cart_discard (user_id, discarded_at DESC);
CREATE INDEX pdv_cart_discard_terminal_id_idx ON pdv_cart_discard (terminal_id);
CREATE INDEX pdv_cart_discard_authorized_by_idx ON pdv_cart_discard (authorized_by);
CALL app.apply_table_standard('public.pdv_cart_discard');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON pdv_cart_discard
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'branch_id', 'terminal_id', 'screen', 'user_id', 'authorized_by', 'items_count', 'total',
    'discarded_at', 'alert'
  );
CREATE POLICY pdv_cart_discard_select ON pdv_cart_discard FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group()) AND app.has_permission('sales.view', branch_id));
GRANT SELECT ON pdv_cart_discard TO farmaerp_app;
CREATE VIEW v_pdv_cart_discard WITH (security_invoker = true) AS
  SELECT * FROM pdv_cart_discard WHERE deleted_at IS NULL;
GRANT SELECT ON v_pdv_cart_discard TO farmaerp_app;

-- Permissão de cada tela.
CREATE FUNCTION app.cart_discard_permission(p_screen text) RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$
  SELECT CASE p_screen
    WHEN 'quote' THEN 'pdv.quote_clear'
    WHEN 'cashier' THEN 'pdv.sale_cancel'
    WHEN 'self_service' THEN 'pdv.self_service_cancel'
  END
$$;

-- Descarte vindo do PDV.
CREATE FUNCTION app.sync_apply_cart_discard(p_terminal public.terminal, p_group_id uuid, p_payload jsonb)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  uuid_any constant text := '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
  discard_id uuid;
  person uuid;
  authorizer uuid;
  responsible uuid;
BEGIN
  IF pg_catalog.jsonb_typeof(p_payload) IS DISTINCT FROM 'object'
     OR (p_payload ->> 'id') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
     OR (p_payload ->> 'user_id') !~ uuid_any
     OR (p_payload ->> 'authorized_by') !~ uuid_any
     OR p_payload ->> 'authorized_by' = p_payload ->> 'user_id'
     OR (p_payload ->> 'screen') IS NULL OR (p_payload ->> 'screen') NOT IN ('quote', 'cashier', 'self_service')
     OR pg_catalog.jsonb_typeof(p_payload -> 'items_count') IS DISTINCT FROM 'number'
     OR (p_payload ->> 'items_count') !~ '^\d{1,5}$' OR (p_payload ->> 'items_count')::integer < 1
     OR pg_catalog.jsonb_typeof(p_payload -> 'total') IS DISTINCT FROM 'number'
     OR (p_payload ->> 'total') !~ '^\d{1,13}(\.\d{1,2})?$'
     OR (p_payload ->> 'discarded_at') !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$' THEN
    RAISE EXCEPTION 'A venda enviada pelo terminal está inconsistente.'
      USING ERRCODE = 'FA962', DETAIL = 'Descarte de venda fora do formato.';
  END IF;
  discard_id := (p_payload ->> 'id')::uuid;
  person := (p_payload ->> 'user_id')::uuid;
  authorizer := (p_payload ->> 'authorized_by')::uuid;
  IF EXISTS (SELECT 1 FROM public.pdv_cart_discard d WHERE d.id = discard_id) THEN
    RAISE EXCEPTION 'Esta venda ou turno já foi recebido com outro registro.'
      USING ERRCODE = 'FA963', DETAIL = pg_catalog.format('pdv_cart_discard %s.', discard_id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.user_account u WHERE u.id = person AND u.economic_group_id = p_group_id)
     OR (authorizer IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM public.user_account u WHERE u.id = authorizer AND u.economic_group_id = p_group_id
     )) THEN
    RAISE EXCEPTION 'Um dos itens informados não foi encontrado.'
      USING ERRCODE = 'FA004', DETAIL = 'Pessoa do descarte fora do grupo.';
  END IF;
  responsible := COALESCE(authorizer, person);
  INSERT INTO public.pdv_cart_discard (
    id, economic_group_id, branch_id, terminal_id, screen, user_id, authorized_by, items_count, total, discarded_at, alert
  ) VALUES (
    discard_id, p_group_id, p_terminal.branch_id, p_terminal.id, p_payload ->> 'screen', person, authorizer,
    (p_payload ->> 'items_count')::integer, (p_payload ->> 'total')::numeric, (p_payload ->> 'discarded_at')::timestamptz,
    CASE WHEN NOT app.user_has_permission(responsible, app.cart_discard_permission(p_payload ->> 'screen'), p_terminal.branch_id)
      THEN 'release_permission' END
  );
END;
$$;

-- Prescritor cadastrado no caixa: quem cadastrou (ou o supervisor que liberou) precisa ter
-- "Cadastrar prescritor no PDV" na filial. Caixas de versões anteriores não mandam quem foi:
-- seguem aceitos como antes.
CREATE FUNCTION app.sync_apply_pdv_prescriber(p_terminal public.terminal, p_group_id uuid, p_payload jsonb)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  responsible text := p_payload ->> 'created_by';
BEGIN
  IF responsible IS NOT NULL AND (
       responsible !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    OR NOT EXISTS (
         SELECT 1 FROM public.user_account u
          WHERE u.id = responsible::uuid AND u.economic_group_id = p_group_id AND u.deleted_at IS NULL
       )
    OR NOT app.user_has_permission(responsible::uuid, 'pdv.prescriber_create', p_terminal.branch_id)
  ) THEN
    RAISE EXCEPTION 'Você não tem permissão para esta operação.'
      USING ERRCODE = 'FA002', DETAIL = 'Prescritor cadastrado no PDV sem pdv.prescriber_create.';
  END IF;
  PERFORM app.sync_apply_health_professional(p_group_id, p_payload);
END;
$$;

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
      PERFORM app.sync_apply_pdv_prescriber(p_terminal, p_group_id, p_payload);
    WHEN 'nfce' THEN
      PERFORM app.sync_apply_nfce(p_terminal, p_group_id, p_payload);
    WHEN 'cart_discard' THEN
      PERFORM app.sync_apply_cart_discard(p_terminal, p_group_id, p_payload);
    ELSE
      RAISE EXCEPTION 'O terminal enviou um tipo de registro desconhecido.'
        USING ERRCODE = 'FA959', DETAIL = pg_catalog.format('Tipo %s.', p_kind);
  END CASE;
END;
$$;

-- Cadastro de cliente no PDV: quem cadastra (o operador, o vendedor no orçamento ou o supervisor
-- que liberou) precisa de "Cadastrar cliente no PDV" na filial do terminal.
CREATE OR REPLACE FUNCTION app.pdv_create_customer(p_operator_id uuid, p_data jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  terminal_row public.terminal := app.require_active_terminal();
  group_id uuid;
  new_id uuid;
  purpose text;
  result jsonb;
BEGIN
  SELECT c.economic_group_id INTO group_id
    FROM public.branch b JOIN public.company c ON c.id = b.company_id
   WHERE b.id = terminal_row.branch_id;
  IF p_operator_id IS NULL OR NOT EXISTS (
       SELECT 1 FROM public.user_account u
        WHERE u.id = p_operator_id AND u.economic_group_id = group_id AND u.deleted_at IS NULL AND u.is_active
     ) OR NOT app.user_has_permission(p_operator_id, 'pdv.customer_create', terminal_row.branch_id) THEN
    RAISE EXCEPTION 'Você não tem permissão para esta operação.'
      USING ERRCODE = 'FA002', DETAIL = 'Cadastro de cliente no PDV sem pdv.customer_create.';
  END IF;
  IF pg_catalog.jsonb_typeof(p_data) IS DISTINCT FROM 'object'
     OR app.clean_text(p_data ->> 'name') IS NULL OR pg_catalog.length(app.clean_text(p_data ->> 'name')) < 3 THEN
    RAISE EXCEPTION 'Os dados do cliente são inválidos.' USING ERRCODE = 'FA904', DETAIL = 'Nome do cliente no PDV.';
  END IF;

  INSERT INTO public.customer (economic_group_id, person_type, document, name, birth_date, phone)
  VALUES (
    group_id, 'individual', COALESCE(app.clean_document(p_data ->> 'document'), ''), app.clean_text(p_data ->> 'name'),
    NULLIF(p_data ->> 'birthDate', '')::date, app.clean_digits(p_data ->> 'phone')
  ) RETURNING id INTO new_id;

  FOREACH purpose IN ARRAY ARRAY['cashback', 'marketing'] LOOP
    IF (p_data -> 'consents' ->> purpose) = 'true' THEN
      INSERT INTO public.customer_consent_event (economic_group_id, customer_id, purpose, granted, channel)
      VALUES (group_id, new_id, purpose, true, 'store');
    END IF;
  END LOOP;

  INSERT INTO public.pdv_customer_cache (economic_group_id, terminal_id, customer_id)
  VALUES (group_id, terminal_row.id, new_id);
  SELECT d.data INTO result FROM app.pdv_customer_data(terminal_row.id, ARRAY[new_id]) d;
  RETURN pg_catalog.jsonb_build_object('id', new_id, 'data', result);
END;
$$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.pdv_create_customer(uuid, jsonb) TO farmaerp_app;
