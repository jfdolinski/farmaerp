-- Up Migration

-- PBM (programas de benefício em medicamentos), parte 1: programas, ativação e dados de acesso por
-- filial, regras do programa de teste e as autorizações feitas no caixa.
-- O caixa fala com o programa pela central (a API guarda os dados de acesso cifrados e chama o
-- conector). O fluxo tem duas fases: a autorização (ao aplicar o PBM) e a confirmação (depois do
-- pagamento); a autorização não confirmada se desfaz ou expira. O desconto do PBM é exclusivo no item
-- e fica fora da margem mínima (o caixa aplica na parte 2).

INSERT INTO permission (code, module, name) VALUES ('pbm.manage', 'Vendas', 'Configurar os programas de benefício em medicamentos (PBM)');

-- ===== Programas =====
CREATE TABLE pbm_program (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  name text NOT NULL CONSTRAINT pbm_program_name_check CHECK (length(btrim(name)) BETWEEN 2 AND 80),
  -- Conector que fala com o programa. Por enquanto só o de teste; os reais entram com o contrato.
  connector text NOT NULL CONSTRAINT pbm_program_connector_check CHECK (connector IN ('test')),
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE UNIQUE INDEX pbm_program_name_key ON pbm_program (economic_group_id, lower(btrim(name))) WHERE deleted_at IS NULL;
CALL app.apply_table_standard('public.pbm_program');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON pbm_program
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns('economic_group_id', 'connector');
CREATE POLICY pbm_program_select ON pbm_program FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group()));
CREATE VIEW v_pbm_program WITH (security_invoker = true) AS SELECT * FROM pbm_program WHERE deleted_at IS NULL;
GRANT SELECT ON pbm_program, v_pbm_program TO farmaerp_app;

-- Programa por filial: ativo ou não e os dados de acesso (cifrados pela API, nunca em texto).
CREATE TABLE pbm_program_branch (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  program_id uuid NOT NULL REFERENCES pbm_program (id),
  branch_id uuid NOT NULL REFERENCES branch (id),
  active boolean NOT NULL DEFAULT true,
  encrypted_credentials bytea CONSTRAINT pbm_program_branch_credentials_check CHECK (length(encrypted_credentials) BETWEEN 30 AND 20000),
  credentials_set_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid,
  CONSTRAINT pbm_program_branch_credentials_at_check CHECK ((encrypted_credentials IS NULL) = (credentials_set_at IS NULL))
);
CREATE UNIQUE INDEX pbm_program_branch_key ON pbm_program_branch (program_id, branch_id) WHERE deleted_at IS NULL;
CREATE INDEX pbm_program_branch_economic_group_id_idx ON pbm_program_branch (economic_group_id);
CREATE INDEX pbm_program_branch_branch_id_idx ON pbm_program_branch (branch_id);
CALL app.apply_table_standard('public.pbm_program_branch');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON pbm_program_branch
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns('economic_group_id', 'program_id', 'branch_id');
CREATE POLICY pbm_program_branch_select ON pbm_program_branch FOR SELECT TO farmaerp_app
  USING (branch_id = ANY (app.allowed_branch_ids()) AND app.has_permission('pbm.manage', branch_id));
-- A view não mostra os dados de acesso, só se estão informados.
CREATE VIEW v_pbm_program_branch WITH (security_invoker = true) AS
  SELECT id, economic_group_id, program_id, branch_id, active, credentials_set_at, created_at, updated_at, deleted_at, version,
         updated_by, trace_id
    FROM pbm_program_branch WHERE deleted_at IS NULL;
GRANT SELECT (id, economic_group_id, program_id, branch_id, active, credentials_set_at, created_at, updated_at, deleted_at, version,
                updated_by, trace_id) ON pbm_program_branch TO farmaerp_app;
GRANT SELECT ON v_pbm_program_branch TO farmaerp_app;

-- Regras do programa de teste: o produto que entra e o percentual de desconto. Simula o que um
-- programa real responderia na consulta.
CREATE TABLE pbm_test_rule (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  program_id uuid NOT NULL REFERENCES pbm_program (id),
  product_id uuid NOT NULL REFERENCES product (id),
  discount_percent numeric(5,2) NOT NULL CONSTRAINT pbm_test_rule_percent_check CHECK (discount_percent > 0 AND discount_percent <= 100),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE UNIQUE INDEX pbm_test_rule_key ON pbm_test_rule (program_id, product_id) WHERE deleted_at IS NULL;
CREATE INDEX pbm_test_rule_economic_group_id_idx ON pbm_test_rule (economic_group_id);
CREATE INDEX pbm_test_rule_product_id_idx ON pbm_test_rule (product_id);
CALL app.apply_table_standard('public.pbm_test_rule');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON pbm_test_rule
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns('economic_group_id', 'program_id', 'product_id');
CREATE POLICY pbm_test_rule_select ON pbm_test_rule FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group()));
CREATE VIEW v_pbm_test_rule WITH (security_invoker = true) AS SELECT * FROM pbm_test_rule WHERE deleted_at IS NULL;
GRANT SELECT ON pbm_test_rule, v_pbm_test_rule TO farmaerp_app;

-- ===== Autorizações =====
CREATE TABLE pbm_authorization (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  branch_id uuid NOT NULL REFERENCES branch (id),
  terminal_id uuid NOT NULL REFERENCES terminal (id),
  program_id uuid NOT NULL REFERENCES pbm_program (id),
  -- CPF ou número do cartão do beneficiário (fica no banco; nunca vai para o log).
  beneficiary_document text NOT NULL CONSTRAINT pbm_authorization_beneficiary_check CHECK (beneficiary_document ~ '^[0-9A-Z]{4,30}$'),
  -- Código da autorização no programa.
  external_id text NOT NULL CONSTRAINT pbm_authorization_external_id_check CHECK (external_id ~ '^[0-9A-Za-z._-]{1,60}$'),
  status text NOT NULL DEFAULT 'authorized'
    CONSTRAINT pbm_authorization_status_check CHECK (status IN ('authorized', 'confirmed', 'undone', 'expired')),
  list_total numeric(12,2) NOT NULL CONSTRAINT pbm_authorization_list_total_check CHECK (list_total > 0),
  -- O que o cliente paga pelos itens do programa; a diferença é o benefício.
  pbm_total numeric(12,2) NOT NULL CONSTRAINT pbm_authorization_pbm_total_check CHECK (pbm_total >= 0),
  authorized_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  -- Venda do caixa (chega à central pela fila; sem referência para não depender da ordem).
  sale_id uuid,
  confirmed_at timestamptz,
  undone_at timestamptz,
  undo_reason text CONSTRAINT pbm_authorization_undo_reason_check CHECK (length(btrim(undo_reason)) BETWEEN 3 AND 255),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid,
  CONSTRAINT pbm_authorization_totals_check CHECK (pbm_total <= list_total),
  CONSTRAINT pbm_authorization_expires_check CHECK (expires_at > authorized_at),
  CONSTRAINT pbm_authorization_confirmed_check CHECK ((status = 'confirmed' OR (status = 'undone' AND sale_id IS NOT NULL))
                                                      = (sale_id IS NOT NULL AND confirmed_at IS NOT NULL)),
  CONSTRAINT pbm_authorization_undone_check CHECK ((status = 'undone') = (undone_at IS NOT NULL AND undo_reason IS NOT NULL))
);
CREATE UNIQUE INDEX pbm_authorization_external_key ON pbm_authorization (program_id, external_id) WHERE deleted_at IS NULL;
CREATE INDEX pbm_authorization_economic_group_id_idx ON pbm_authorization (economic_group_id);
CREATE INDEX pbm_authorization_branch_id_idx ON pbm_authorization (branch_id, authorized_at);
CREATE INDEX pbm_authorization_terminal_id_idx ON pbm_authorization (terminal_id);
CREATE INDEX pbm_authorization_sale_id_idx ON pbm_authorization (sale_id);
CREATE INDEX pbm_authorization_open_idx ON pbm_authorization (expires_at) WHERE status = 'authorized';
CALL app.apply_table_standard('public.pbm_authorization');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON pbm_authorization
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'branch_id', 'terminal_id', 'program_id', 'beneficiary_document', 'external_id', 'list_total', 'pbm_total',
    'authorized_at', 'expires_at'
  );

-- A situação só anda para a frente: autorizada vira confirmada, desfeita ou expirada; confirmada só
-- vira desfeita (estorno, na parte 3). Venda e datas só se gravam na passagem.
CREATE FUNCTION app.guard_pbm_authorization() RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF NEW.status IS DISTINCT FROM OLD.status
     AND NOT ((OLD.status = 'authorized' AND NEW.status IN ('confirmed', 'undone', 'expired'))
              OR (OLD.status = 'confirmed' AND NEW.status = 'undone')) THEN
    RAISE EXCEPTION 'Esta autorização do PBM não está mais válida.'
      USING ERRCODE = 'FA795', DETAIL = pg_catalog.format('pbm_authorization %s de %s para %s.', OLD.id, OLD.status, NEW.status);
  END IF;
  IF (NEW.sale_id, NEW.confirmed_at) IS DISTINCT FROM (OLD.sale_id, OLD.confirmed_at)
     AND NOT (OLD.status = 'authorized' AND NEW.status = 'confirmed') THEN
    RAISE EXCEPTION 'Esta autorização do PBM não está mais válida.'
      USING ERRCODE = 'FA795', DETAIL = pg_catalog.format('pbm_authorization %s: venda.', OLD.id);
  END IF;
  IF (NEW.undone_at, NEW.undo_reason) IS DISTINCT FROM (OLD.undone_at, OLD.undo_reason) AND NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RAISE EXCEPTION 'Esta autorização do PBM não está mais válida.'
      USING ERRCODE = 'FA795', DETAIL = pg_catalog.format('pbm_authorization %s: desfazer.', OLD.id);
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER guard_pbm_authorization BEFORE UPDATE ON pbm_authorization
  FOR EACH ROW EXECUTE FUNCTION app.guard_pbm_authorization();

CREATE POLICY pbm_authorization_select ON pbm_authorization FOR SELECT TO farmaerp_app
  USING (branch_id = ANY (app.allowed_branch_ids()) AND app.has_permission('sales.view', branch_id));
CREATE VIEW v_pbm_authorization WITH (security_invoker = true) AS SELECT * FROM pbm_authorization WHERE deleted_at IS NULL;
GRANT SELECT ON pbm_authorization, v_pbm_authorization TO farmaerp_app;

CREATE TABLE pbm_authorization_item (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  authorization_id uuid NOT NULL REFERENCES pbm_authorization (id),
  product_id uuid NOT NULL REFERENCES product (id),
  quantity numeric(12,3) NOT NULL CONSTRAINT pbm_authorization_item_quantity_check CHECK (quantity > 0),
  -- Preço unitário do caixa e o do programa (o que o cliente paga por unidade).
  list_price numeric(12,2) NOT NULL CONSTRAINT pbm_authorization_item_list_price_check CHECK (list_price > 0),
  pbm_price numeric(12,2) NOT NULL CONSTRAINT pbm_authorization_item_pbm_price_check CHECK (pbm_price >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid,
  CONSTRAINT pbm_authorization_item_price_check CHECK (pbm_price <= list_price)
);
CREATE UNIQUE INDEX pbm_authorization_item_key ON pbm_authorization_item (authorization_id, product_id) WHERE deleted_at IS NULL;
CREATE INDEX pbm_authorization_item_economic_group_id_idx ON pbm_authorization_item (economic_group_id);
CREATE INDEX pbm_authorization_item_product_id_idx ON pbm_authorization_item (product_id);
CALL app.apply_table_standard('public.pbm_authorization_item');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON pbm_authorization_item
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'authorization_id', 'product_id', 'quantity', 'list_price', 'pbm_price'
  );
CREATE POLICY pbm_authorization_item_select ON pbm_authorization_item FOR SELECT TO farmaerp_app
  USING (EXISTS (SELECT 1 FROM pbm_authorization a WHERE a.id = pbm_authorization_item.authorization_id));
CREATE VIEW v_pbm_authorization_item WITH (security_invoker = true) AS SELECT * FROM pbm_authorization_item WHERE deleted_at IS NULL;
GRANT SELECT ON pbm_authorization_item, v_pbm_authorization_item TO farmaerp_app;

-- ===== Retaguarda =====

-- Programas do grupo com as filiais e as regras de teste: quem configura PBM em alguma filial.
CREATE FUNCTION app.pbm_programs() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT app.has_permission_anywhere('pbm.manage') THEN
    RAISE EXCEPTION 'Você não tem permissão para esta operação.' USING ERRCODE = 'FA002', DETAIL = 'pbm.manage.';
  END IF;
  RETURN COALESCE((
    SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
             'id', p.id, 'name', p.name, 'connector', p.connector, 'active', p.active,
             'can_edit', app.has_permission('pbm.manage'),
             'branches', COALESCE((
               SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
                        'branch_id', b.id, 'branch_name', b.name,
                        'active', COALESCE(pb.active, false), 'credentials_set_at', pb.credentials_set_at)
                        ORDER BY b.name, b.id)
                 FROM pg_catalog.unnest(app.allowed_branch_ids()) AS allowed(branch_id)
                 JOIN public.branch b ON b.id = allowed.branch_id
                 LEFT JOIN public.pbm_program_branch pb ON pb.program_id = p.id AND pb.branch_id = b.id AND pb.deleted_at IS NULL
                WHERE app.has_permission('pbm.manage', b.id)
             ), '[]'::jsonb),
             'rules', COALESCE((
               SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
                        'product_id', r.product_id, 'product_code', pr.code, 'product_name', pr.display_name,
                        'discount_percent', r.discount_percent) ORDER BY pr.display_name, pr.id)
                 FROM public.pbm_test_rule r JOIN public.product pr ON pr.id = r.product_id
                WHERE r.program_id = p.id AND r.deleted_at IS NULL
             ), '[]'::jsonb))
             ORDER BY p.name, p.id)
      FROM public.pbm_program p
     WHERE p.economic_group_id = app.current_user_group() AND p.deleted_at IS NULL
  ), '[]'::jsonb);
END;
$$;

-- Cria ou altera o programa (nome e ativo): quem configura PBM em todas as filiais.
CREATE FUNCTION app.save_pbm_program(p_data jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_group uuid := app.permission_group('pbm.manage');
  v_id uuid := (p_data ->> 'id')::uuid;
BEGIN
  IF v_group IS NULL THEN
    RAISE EXCEPTION 'Você não tem permissão para esta operação.' USING ERRCODE = 'FA002', DETAIL = 'pbm.manage em todas as filiais.';
  END IF;
  IF v_id IS NULL THEN
    INSERT INTO public.pbm_program (economic_group_id, name, connector, active)
    VALUES (v_group, pg_catalog.btrim(p_data ->> 'name'), COALESCE(p_data ->> 'connector', 'test'), COALESCE((p_data ->> 'active')::boolean, true))
    RETURNING id INTO v_id;
    RETURN v_id;
  END IF;
  UPDATE public.pbm_program p
     SET name = COALESCE(pg_catalog.btrim(p_data ->> 'name'), p.name), active = COALESCE((p_data ->> 'active')::boolean, p.active)
   WHERE p.id = v_id AND p.economic_group_id = v_group AND p.deleted_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.' USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('pbm_program %s.', v_id);
  END IF;
  RETURN v_id;
END;
$$;

-- Programa do grupo de quem pede (FA006 se não for).
CREATE FUNCTION app.pbm_program_of_group(p_program_id uuid) RETURNS public.pbm_program
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_program public.pbm_program;
BEGIN
  SELECT * INTO v_program FROM public.pbm_program p
   WHERE p.id = p_program_id AND p.deleted_at IS NULL AND p.economic_group_id = app.current_user_group();
  IF v_program.id IS NULL THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.' USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('pbm_program %s.', p_program_id);
  END IF;
  RETURN v_program;
END;
$$;
REVOKE ALL ON FUNCTION app.pbm_program_of_group(uuid) FROM PUBLIC;

-- Liga ou desliga o programa numa filial: quem configura PBM nela.
CREATE FUNCTION app.set_pbm_program_branch(p_program_id uuid, p_branch_id uuid, p_active boolean) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_program public.pbm_program := app.pbm_program_of_group(p_program_id);
  v_branch public.branch := app.require_branch_permission('pbm.manage', p_branch_id);
BEGIN
  INSERT INTO public.pbm_program_branch (economic_group_id, program_id, branch_id, active)
  VALUES (v_program.economic_group_id, v_program.id, v_branch.id, COALESCE(p_active, false))
  ON CONFLICT (program_id, branch_id) WHERE deleted_at IS NULL DO UPDATE SET active = EXCLUDED.active;
END;
$$;

-- Grava os dados de acesso da filial (já cifrados pela API com o contexto do programa e da filial).
CREATE FUNCTION app.set_pbm_branch_credentials(p_program_id uuid, p_branch_id uuid, p_encrypted bytea) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_program public.pbm_program := app.pbm_program_of_group(p_program_id);
  v_branch public.branch := app.require_branch_permission('pbm.manage', p_branch_id);
BEGIN
  INSERT INTO public.pbm_program_branch (economic_group_id, program_id, branch_id, active, encrypted_credentials, credentials_set_at)
  VALUES (v_program.economic_group_id, v_program.id, v_branch.id, false, p_encrypted, pg_catalog.now())
  ON CONFLICT (program_id, branch_id) WHERE deleted_at IS NULL
  DO UPDATE SET encrypted_credentials = EXCLUDED.encrypted_credentials, credentials_set_at = EXCLUDED.credentials_set_at;
END;
$$;

-- Regra do programa de teste: percentual do produto; sem percentual, o produto sai do programa.
CREATE FUNCTION app.set_pbm_test_rule(p_program_id uuid, p_product_id uuid, p_percent numeric) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_group uuid := app.permission_group('pbm.manage');
  v_program public.pbm_program := app.pbm_program_of_group(p_program_id);
BEGIN
  IF v_group IS NULL THEN
    RAISE EXCEPTION 'Você não tem permissão para esta operação.' USING ERRCODE = 'FA002', DETAIL = 'pbm.manage em todas as filiais.';
  END IF;
  IF v_program.connector <> 'test' THEN
    RAISE EXCEPTION 'Alguns dados informados são inválidos.' USING ERRCODE = 'FA005', DETAIL = 'Regra só no programa de teste.';
  END IF;
  PERFORM 1 FROM public.product pr WHERE pr.id = p_product_id AND pr.economic_group_id = v_group AND pr.deleted_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.' USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('product %s.', p_product_id);
  END IF;
  IF p_percent IS NULL THEN
    UPDATE public.pbm_test_rule r SET deleted_at = pg_catalog.clock_timestamp()
     WHERE r.program_id = v_program.id AND r.product_id = p_product_id AND r.deleted_at IS NULL;
    RETURN;
  END IF;
  INSERT INTO public.pbm_test_rule (economic_group_id, program_id, product_id, discount_percent)
  VALUES (v_group, v_program.id, p_product_id, p_percent)
  ON CONFLICT (program_id, product_id) WHERE deleted_at IS NULL DO UPDATE SET discount_percent = EXCLUDED.discount_percent;
END;
$$;

-- A mesma regra pela tela: o produto pelo código ou código de barras.
CREATE FUNCTION app.set_pbm_test_rule_by_lookup(p_program_id uuid, p_lookup text, p_percent numeric) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM app.set_pbm_test_rule(p_program_id, app.require_product_lookup(p_lookup), p_percent);
END;
$$;

-- Documento do beneficiário mascarado para as telas (os 3 últimos ficam à mostra).
CREATE FUNCTION app.pbm_masked_document(p_document text) RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$
  SELECT pg_catalog.repeat('*', GREATEST(pg_catalog.length(p_document) - 3, 0)) || pg_catalog.right(p_document, 3)
$$;

-- Conferência das autorizações por período (datas do horário de Brasília) e filial: quem vê vendas.
CREATE FUNCTION app.pbm_authorizations(p_from date, p_to date, p_branch_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
           'id', a.id, 'branch_name', b.name, 'terminal_name', t.name, 'program_name', p.name,
           'beneficiary', app.pbm_masked_document(a.beneficiary_document), 'external_id', a.external_id, 'status', a.status,
           'list_total', a.list_total, 'pbm_total', a.pbm_total, 'benefit', a.list_total - a.pbm_total,
           'authorized_at', a.authorized_at, 'expires_at', a.expires_at, 'confirmed_at', a.confirmed_at,
           'sale_id', a.sale_id, 'sale_number', s.number, 'undone_at', a.undone_at, 'undo_reason', a.undo_reason,
           -- Confirmada no programa, mas a venda ainda não chegou à central.
           'missing_sale', a.status = 'confirmed' AND s.id IS NULL,
           'items', (SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
                              'product_name', pr.display_name, 'quantity', i.quantity, 'list_price', i.list_price, 'pbm_price', i.pbm_price)
                              ORDER BY pr.display_name, i.id)
                       FROM public.pbm_authorization_item i JOIN public.product pr ON pr.id = i.product_id
                      WHERE i.authorization_id = a.id AND i.deleted_at IS NULL))
           ORDER BY a.authorized_at DESC, a.id), '[]'::jsonb)
    FROM public.pbm_authorization a
    JOIN public.branch b ON b.id = a.branch_id
    JOIN public.terminal t ON t.id = a.terminal_id
    JOIN public.pbm_program p ON p.id = a.program_id
    LEFT JOIN public.sale s ON s.id = a.sale_id AND s.deleted_at IS NULL
   WHERE a.deleted_at IS NULL AND a.economic_group_id = app.current_user_group()
     AND a.branch_id = ANY (app.allowed_branch_ids()) AND app.has_permission('sales.view', a.branch_id)
     AND (p_branch_id IS NULL OR a.branch_id = p_branch_id)
     AND (p_from IS NULL OR a.authorized_at >= (p_from::timestamp AT TIME ZONE 'America/Sao_Paulo'))
     AND (p_to IS NULL OR a.authorized_at < ((p_to + 1)::timestamp AT TIME ZONE 'America/Sao_Paulo'))
$$;

-- ===== Caixa (pela API, com a internet) =====

-- Programas ativos na filial do terminal.
CREATE FUNCTION app.terminal_pbm_programs() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_terminal public.terminal := app.require_active_terminal();
BEGIN
  RETURN COALESCE((
    SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('id', p.id, 'name', p.name) ORDER BY p.name, p.id)
      FROM public.pbm_program p
      JOIN public.pbm_program_branch pb ON pb.program_id = p.id AND pb.branch_id = v_terminal.branch_id AND pb.deleted_at IS NULL
     WHERE p.deleted_at IS NULL AND p.active AND pb.active
  ), '[]'::jsonb);
END;
$$;

-- O que a API precisa para chamar o programa: o conector e os dados de acesso da filial. Programa
-- desligado ou fora da filial do terminal: FA793.
CREATE FUNCTION app.terminal_pbm_context(p_program_id uuid) RETURNS TABLE (
  program_id uuid, economic_group_id uuid, branch_id uuid, terminal_id uuid, connector text, encrypted_credentials bytea
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_terminal public.terminal := app.require_active_terminal();
BEGIN
  RETURN QUERY
    SELECT p.id, p.economic_group_id, v_terminal.branch_id, v_terminal.id, p.connector, pb.encrypted_credentials
      FROM public.pbm_program p
      JOIN public.pbm_program_branch pb ON pb.program_id = p.id AND pb.branch_id = v_terminal.branch_id AND pb.deleted_at IS NULL
     WHERE p.id = p_program_id AND p.deleted_at IS NULL AND p.active AND pb.active;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Este programa de benefício não está ativo nesta loja.'
      USING ERRCODE = 'FA793', DETAIL = pg_catalog.format('pbm_program %s na filial %s.', p_program_id, v_terminal.branch_id);
  END IF;
END;
$$;

-- Regras do programa de teste para os produtos do carrinho (o conector de teste da API consulta).
CREATE FUNCTION app.terminal_pbm_test_rules(p_program_id uuid, p_product_ids uuid[]) RETURNS TABLE (product_id uuid, discount_percent numeric)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM 1 FROM app.terminal_pbm_context(p_program_id);
  RETURN QUERY
    SELECT r.product_id, r.discount_percent FROM public.pbm_test_rule r
     WHERE r.program_id = p_program_id AND r.deleted_at IS NULL AND r.product_id = ANY (p_product_ids);
END;
$$;

-- Registra a autorização que o programa deu: itens com o preço do caixa e o do programa. Os totais
-- saem dos itens. Vale 30 minutos para a venda confirmar.
CREATE FUNCTION app.terminal_pbm_register(p_program_id uuid, p_data jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_context record;
  v_id uuid;
  v_list numeric;
  v_pbm numeric;
  v_expires timestamptz;
BEGIN
  SELECT * INTO v_context FROM app.terminal_pbm_context(p_program_id);
  IF pg_catalog.jsonb_typeof(p_data -> 'items') IS DISTINCT FROM 'array' OR pg_catalog.jsonb_array_length(p_data -> 'items') = 0 THEN
    RAISE EXCEPTION 'Nenhum item desta venda faz parte do programa.' USING ERRCODE = 'FA796';
  END IF;
  -- Produto de outro grupo não entra.
  IF EXISTS (
    SELECT 1 FROM pg_catalog.jsonb_array_elements(p_data -> 'items') AS item
     WHERE NOT EXISTS (SELECT 1 FROM public.product pr
                        WHERE pr.id = (item ->> 'product_id')::uuid AND pr.economic_group_id = v_context.economic_group_id AND pr.deleted_at IS NULL)
  ) THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.' USING ERRCODE = 'FA006', DETAIL = 'Produto do PBM.';
  END IF;
  SELECT pg_catalog.sum(pg_catalog.round((item ->> 'quantity')::numeric * (item ->> 'list_price')::numeric, 2)),
         pg_catalog.sum(pg_catalog.round((item ->> 'quantity')::numeric * (item ->> 'pbm_price')::numeric, 2))
    INTO v_list, v_pbm
    FROM pg_catalog.jsonb_array_elements(p_data -> 'items') AS item;
  INSERT INTO public.pbm_authorization (economic_group_id, branch_id, terminal_id, program_id, beneficiary_document, external_id,
                                        list_total, pbm_total, expires_at)
  VALUES (v_context.economic_group_id, v_context.branch_id, v_context.terminal_id, v_context.program_id,
          pg_catalog.upper(p_data ->> 'beneficiary'), p_data ->> 'external_id', v_list, v_pbm, pg_catalog.now() + interval '30 minutes')
  RETURNING pbm_authorization.id, pbm_authorization.expires_at INTO v_id, v_expires;
  INSERT INTO public.pbm_authorization_item (economic_group_id, authorization_id, product_id, quantity, list_price, pbm_price)
  SELECT v_context.economic_group_id, v_id, (item ->> 'product_id')::uuid, (item ->> 'quantity')::numeric,
         (item ->> 'list_price')::numeric, (item ->> 'pbm_price')::numeric
    FROM pg_catalog.jsonb_array_elements(p_data -> 'items') AS item;
  RETURN pg_catalog.jsonb_build_object('id', v_id, 'list_total', v_list, 'pbm_total', v_pbm, 'benefit', v_list - v_pbm,
                                       'expires_at', v_expires);
END;
$$;

-- A autorização do terminal (FA006 se for de outro terminal ou não existir).
CREATE FUNCTION app.terminal_pbm_authorization(p_id uuid) RETURNS public.pbm_authorization
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_terminal public.terminal := app.require_active_terminal();
  v_row public.pbm_authorization;
BEGIN
  SELECT * INTO v_row FROM public.pbm_authorization a WHERE a.id = p_id AND a.terminal_id = v_terminal.id AND a.deleted_at IS NULL;
  IF v_row.id IS NULL THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.' USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('pbm_authorization %s.', p_id);
  END IF;
  RETURN v_row;
END;
$$;
REVOKE ALL ON FUNCTION app.terminal_pbm_authorization(uuid) FROM PUBLIC;

-- O que a API precisa para confirmar ou desfazer no programa (a autorização, o conector e os dados de
-- acesso), sem mudar nada.
CREATE FUNCTION app.terminal_pbm_action_context(p_id uuid) RETURNS TABLE (
  id uuid, program_id uuid, branch_id uuid, status text, external_id text, expires_at timestamptz, sale_id uuid,
  connector text, encrypted_credentials bytea
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_row public.pbm_authorization := app.terminal_pbm_authorization(p_id);
BEGIN
  RETURN QUERY
    SELECT v_row.id, v_row.program_id, v_row.branch_id, v_row.status, v_row.external_id, v_row.expires_at, v_row.sale_id,
           p.connector, pb.encrypted_credentials
      FROM public.pbm_program p
      LEFT JOIN public.pbm_program_branch pb ON pb.program_id = p.id AND pb.branch_id = v_row.branch_id AND pb.deleted_at IS NULL
     WHERE p.id = v_row.program_id;
END;
$$;

-- Confirma depois do pagamento. Repetido com a mesma venda: já está feito. Vencida, desfeita ou
-- confirmada com outra venda: FA795.
CREATE FUNCTION app.terminal_pbm_confirm(p_id uuid, p_sale_id uuid) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_row public.pbm_authorization := app.terminal_pbm_authorization(p_id);
BEGIN
  IF v_row.status = 'confirmed' AND v_row.sale_id = p_sale_id THEN
    RETURN 'confirmed';
  END IF;
  IF v_row.status <> 'authorized' OR v_row.expires_at < pg_catalog.now() OR p_sale_id IS NULL THEN
    RAISE EXCEPTION 'Esta autorização do PBM não está mais válida.'
      USING ERRCODE = 'FA795', DETAIL = pg_catalog.format('pbm_authorization %s em %s.', v_row.id, v_row.status);
  END IF;
  UPDATE public.pbm_authorization a SET status = 'confirmed', sale_id = p_sale_id, confirmed_at = pg_catalog.now() WHERE a.id = v_row.id;
  RETURN 'confirmed';
END;
$$;

-- Desfaz a autorização da venda que não aconteceu (a confirmada fica para o estorno, na parte 3).
-- Repetido: já está feito.
CREATE FUNCTION app.terminal_pbm_undo(p_id uuid, p_reason text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_row public.pbm_authorization := app.terminal_pbm_authorization(p_id);
BEGIN
  IF v_row.status IN ('undone', 'expired') THEN
    RETURN v_row.status;
  END IF;
  IF v_row.status <> 'authorized' THEN
    RAISE EXCEPTION 'Esta autorização do PBM não está mais válida.'
      USING ERRCODE = 'FA795', DETAIL = pg_catalog.format('pbm_authorization %s em %s.', v_row.id, v_row.status);
  END IF;
  UPDATE public.pbm_authorization a
     SET status = 'undone', undone_at = pg_catalog.now(), undo_reason = COALESCE(NULLIF(pg_catalog.btrim(p_reason), ''), 'Venda não concluída')
   WHERE a.id = v_row.id;
  RETURN 'undone';
END;
$$;

REVOKE ALL ON FUNCTION
  app.pbm_programs(), app.save_pbm_program(jsonb), app.set_pbm_program_branch(uuid, uuid, boolean),
  app.set_pbm_branch_credentials(uuid, uuid, bytea), app.set_pbm_test_rule(uuid, uuid, numeric), app.set_pbm_test_rule_by_lookup(uuid, text, numeric),
  app.pbm_authorizations(date, date, uuid), app.terminal_pbm_programs(), app.terminal_pbm_context(uuid),
  app.terminal_pbm_test_rules(uuid, uuid[]), app.terminal_pbm_register(uuid, jsonb), app.terminal_pbm_action_context(uuid),
  app.terminal_pbm_confirm(uuid, uuid), app.terminal_pbm_undo(uuid, text)
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  app.pbm_programs(), app.save_pbm_program(jsonb), app.set_pbm_program_branch(uuid, uuid, boolean),
  app.set_pbm_branch_credentials(uuid, uuid, bytea), app.set_pbm_test_rule(uuid, uuid, numeric), app.set_pbm_test_rule_by_lookup(uuid, text, numeric),
  app.pbm_authorizations(date, date, uuid), app.terminal_pbm_programs(), app.terminal_pbm_context(uuid),
  app.terminal_pbm_test_rules(uuid, uuid[]), app.terminal_pbm_register(uuid, jsonb), app.terminal_pbm_action_context(uuid),
  app.terminal_pbm_confirm(uuid, uuid), app.terminal_pbm_undo(uuid, text)
TO farmaerp_app;
