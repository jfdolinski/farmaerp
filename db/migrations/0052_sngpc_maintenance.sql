-- Up Migration

-- Etapa 8, PR 8C-1: entreposto do SNGPC (banco e retaguarda).
-- Cada filial abre o SNGPC com um inventário inicial por lote (o saldo do estoque, que o
-- farmacêutico confere). Daí em diante, toda movimentação de estoque de produto controlado vira
-- uma movimentação do SNGPC pendente, por trigger. Nada segue sozinho: o farmacêutico completa
-- os dados (lote, motivo da perda, receita da venda pendente), simula o saldo por lote e confere,
-- autenticando com a senha (na API) e definindo a data de envio. O envio à Anvisa é do 8C-2.
-- Regras da conferência: inventário da filial conferido antes; ordem cronológica por produto (uma
-- pendência anterior segura as posteriores); a saída não pode ficar antes da entrada do lote nem
-- deixar o saldo do lote negativo; cada movimentação leva o MS do seu lote.

INSERT INTO permission (code, module, name) VALUES
  ('sngpc.manage', 'Controlados', 'Conferir as movimentações do SNGPC');

INSERT INTO role_permission (role_id, permission_id)
SELECT r.id, p.id
  FROM role r
  JOIN permission p ON p.code = 'sngpc.manage'
 WHERE r.deleted_at IS NULL AND r.system_key IS NULL AND r.name = 'Farmacêutico'
   AND NOT EXISTS (
     SELECT 1 FROM role_permission rp WHERE rp.role_id = r.id AND rp.permission_id = p.id AND rp.deleted_at IS NULL
   );

UPDATE role SET description = 'Libera a venda de controlados no PDV e confere o SNGPC.'
 WHERE name = 'Farmacêutico' AND system_key IS NULL
   AND description = 'Libera a venda de controlados no PDV. O SNGPC chega na Etapa 8.';

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
     'users.release_login', 'users.biometrics', 'credit.view', 'credit.manage'
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
    JOIN public.permission p ON p.code IN ('sales.sell', 'sales.quote', 'controlled.dispense', 'controlled.view', 'sngpc.manage')
   WHERE r.economic_group_id = p_group_id AND r.name = 'Farmacêutico';
  PERFORM app.seed_manager_limits(manager_id, p_group_id);
END;
$$;

-- SNGPC aberto na filial: a partir daqui as movimentações de controlados entram no entreposto.
CREATE TABLE sngpc_branch (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  branch_id uuid NOT NULL REFERENCES branch (id),
  opened_at timestamptz NOT NULL DEFAULT now(),
  opened_by uuid NOT NULL REFERENCES user_account (id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE UNIQUE INDEX sngpc_branch_branch_key ON sngpc_branch (branch_id) WHERE deleted_at IS NULL;
CREATE INDEX sngpc_branch_economic_group_id_idx ON sngpc_branch (economic_group_id);
CREATE INDEX sngpc_branch_opened_by_idx ON sngpc_branch (opened_by);

-- Movimentação do SNGPC. A quantidade é sempre positiva; o tipo diz se entra ou sai.
CREATE TABLE sngpc_movement (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  branch_id uuid NOT NULL REFERENCES branch (id),
  product_id uuid NOT NULL REFERENCES product (id),
  batch_id uuid REFERENCES product_batch (id),
  -- Movimentação de estoque que a gerou (o inventário inicial não tem).
  stock_movement_id uuid REFERENCES stock_movement (id),
  kind text NOT NULL CONSTRAINT sngpc_movement_kind_check CHECK (kind IN (
    'inventory', 'purchase', 'transfer_in', 'return_in', 'adjustment_in',
    'sale', 'transfer_out', 'loss', 'adjustment_out'
  )),
  quantity numeric(14, 3) NOT NULL CONSTRAINT sngpc_movement_quantity_check CHECK (quantity > 0),
  occurred_at timestamptz NOT NULL,
  -- Data que vai para o SNGPC. Nasce com o dia da movimentação; o farmacêutico pode corrigir.
  reported_on date NOT NULL,
  dispensing_id uuid REFERENCES controlled_dispensing (id),
  loss_reason text CONSTRAINT sngpc_movement_loss_reason_check CHECK (loss_reason IN (
    'theft', 'damage', 'expired', 'seized', 'quality_sample', 'recall', 'other'
  )),
  status text NOT NULL DEFAULT 'pending' CONSTRAINT sngpc_movement_status_check CHECK (status IN (
    'pending', 'confirmed', 'sent', 'accepted', 'rejected', 'disregarded'
  )),
  status_reason text CONSTRAINT sngpc_movement_status_reason_check CHECK (length(btrim(status_reason)) BETWEEN 1 AND 500),
  confirmed_by uuid REFERENCES user_account (id),
  confirmed_at timestamptz,
  send_on date,
  -- MS do lote no momento da conferência (o lote pode ser editado depois).
  ms_registration text CONSTRAINT sngpc_movement_ms_check CHECK (ms_registration ~ '^[0-9]{9,13}$'),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid,
  CONSTRAINT sngpc_movement_source_check CHECK ((kind = 'inventory') = (stock_movement_id IS NULL)),
  CONSTRAINT sngpc_movement_dispensing_check CHECK (dispensing_id IS NULL OR kind = 'sale'),
  CONSTRAINT sngpc_movement_loss_kind_check CHECK (loss_reason IS NULL OR kind IN ('loss', 'adjustment_out')),
  CONSTRAINT sngpc_movement_state_check CHECK (
    (status = 'pending' AND confirmed_by IS NULL AND send_on IS NULL AND status_reason IS NULL)
    OR (status = 'disregarded' AND status_reason IS NOT NULL AND confirmed_by IS NULL)
    OR (status IN ('confirmed', 'sent', 'accepted', 'rejected') AND confirmed_by IS NOT NULL AND confirmed_at IS NOT NULL
        AND send_on IS NOT NULL AND batch_id IS NOT NULL AND ms_registration IS NOT NULL)
  )
);
CREATE UNIQUE INDEX sngpc_movement_stock_key ON sngpc_movement (stock_movement_id) WHERE deleted_at IS NULL;
CREATE INDEX sngpc_movement_branch_idx ON sngpc_movement (branch_id, status, reported_on);
CREATE INDEX sngpc_movement_product_idx ON sngpc_movement (product_id, reported_on);
CREATE INDEX sngpc_movement_batch_idx ON sngpc_movement (batch_id);
CREATE INDEX sngpc_movement_dispensing_idx ON sngpc_movement (dispensing_id);
CREATE INDEX sngpc_movement_economic_group_id_idx ON sngpc_movement (economic_group_id);
CREATE INDEX sngpc_movement_confirmed_by_idx ON sngpc_movement (confirmed_by);

-- Dados do SNGPC de uma venda liberada como pendente (sem receita), completados na manutenção.
-- A dispensação original não muda. Correção antes da conferência: o complemento antigo é
-- desativado e entra outro.
CREATE TABLE sngpc_dispensing_complement (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  dispensing_id uuid NOT NULL REFERENCES controlled_dispensing (id),
  batch_id uuid NOT NULL REFERENCES product_batch (id),
  pharmacist_id uuid NOT NULL REFERENCES user_account (id),
  prescription_type text NOT NULL CONSTRAINT sngpc_complement_prescription_type_check CHECK (prescription_type IN (
    'notification_a', 'notification_b', 'notification_b2', 'notification_retinoid', 'notification_thalidomide',
    'special_control', 'antimicrobial'
  )),
  prescription_number text CONSTRAINT sngpc_complement_prescription_number_check CHECK (prescription_number ~ '^[0-9A-Za-z./-]{1,30}$'),
  prescription_date date NOT NULL,
  prescriber_name text NOT NULL CONSTRAINT sngpc_complement_prescriber_name_check CHECK (length(btrim(prescriber_name)) BETWEEN 3 AND 150),
  prescriber_council text NOT NULL CONSTRAINT sngpc_complement_prescriber_council_check CHECK (prescriber_council IN ('CRM', 'CRO', 'CRMV', 'COREN', 'CRF', 'RMS')),
  prescriber_number text NOT NULL CONSTRAINT sngpc_complement_prescriber_number_check CHECK (prescriber_number ~ '^[0-9A-Za-z-]{1,20}$'),
  prescriber_state char(2) NOT NULL CONSTRAINT sngpc_complement_prescriber_state_check CHECK (prescriber_state ~ '^[A-Z]{2}$'),
  buyer_name text NOT NULL CONSTRAINT sngpc_complement_buyer_name_check CHECK (length(btrim(buyer_name)) BETWEEN 3 AND 150),
  buyer_document_type text NOT NULL CONSTRAINT sngpc_complement_buyer_document_type_check CHECK (buyer_document_type IN ('rg', 'cpf', 'cnh', 'passport', 'other')),
  buyer_document text NOT NULL CONSTRAINT sngpc_complement_buyer_document_check CHECK (buyer_document ~ '^[0-9A-Za-z./-]{3,30}$'),
  buyer_issuer text NOT NULL CONSTRAINT sngpc_complement_buyer_issuer_check CHECK (length(btrim(buyer_issuer)) BETWEEN 2 AND 20),
  buyer_state char(2) NOT NULL CONSTRAINT sngpc_complement_buyer_state_check CHECK (buyer_state ~ '^[A-Z]{2}$'),
  patient_name text CONSTRAINT sngpc_complement_patient_name_check CHECK (length(btrim(patient_name)) BETWEEN 3 AND 150),
  patient_age smallint CONSTRAINT sngpc_complement_patient_age_check CHECK (patient_age BETWEEN 0 AND 130),
  patient_sex char(1) CONSTRAINT sngpc_complement_patient_sex_check CHECK (patient_sex IN ('F', 'M')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid,
  CONSTRAINT sngpc_complement_rules_check CHECK (
    (prescription_type NOT LIKE 'notification%' OR prescription_number IS NOT NULL)
    AND (prescription_type <> 'antimicrobial' OR (patient_age IS NOT NULL AND patient_sex IS NOT NULL))
  )
);
CREATE UNIQUE INDEX sngpc_complement_dispensing_key ON sngpc_dispensing_complement (dispensing_id) WHERE deleted_at IS NULL;
CREATE INDEX sngpc_complement_economic_group_id_idx ON sngpc_dispensing_complement (economic_group_id);
CREATE INDEX sngpc_complement_batch_idx ON sngpc_dispensing_complement (batch_id);
CREATE INDEX sngpc_complement_pharmacist_idx ON sngpc_dispensing_complement (pharmacist_id);

CALL app.apply_table_standard('public.sngpc_branch');
CALL app.apply_table_standard('public.sngpc_movement');
CALL app.apply_table_standard('public.sngpc_dispensing_complement');

CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON sngpc_branch
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'branch_id', 'opened_at', 'opened_by', 'deleted_at'
  );
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON sngpc_movement
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'branch_id', 'product_id', 'stock_movement_id', 'kind', 'occurred_at', 'dispensing_id', 'deleted_at'
  );
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON sngpc_dispensing_complement
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'dispensing_id', 'batch_id', 'pharmacist_id', 'prescription_type', 'prescription_number',
    'prescription_date', 'prescriber_name', 'prescriber_council', 'prescriber_number', 'prescriber_state',
    'buyer_name', 'buyer_document_type', 'buyer_document', 'buyer_issuer', 'buyer_state',
    'patient_name', 'patient_age', 'patient_sex'
  );

-- Depois de conferida, a movimentação não muda: só segue o caminho do envio (8C-2).
CREATE FUNCTION app.guard_sngpc_movement() RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF OLD.status = 'pending' THEN
    IF NEW.status NOT IN ('pending', 'confirmed', 'disregarded') THEN
      RAISE EXCEPTION 'Esta movimentação do SNGPC não pode mais ser alterada.'
        USING ERRCODE = 'FA863', DETAIL = pg_catalog.format('De %s para %s.', OLD.status, NEW.status);
    END IF;
    IF NEW.quantity IS DISTINCT FROM OLD.quantity AND OLD.kind <> 'inventory' THEN
      RAISE EXCEPTION 'Esta movimentação do SNGPC não pode mais ser alterada.'
        USING ERRCODE = 'FA863', DETAIL = 'Só a quantidade do inventário muda.';
    END IF;
    RETURN NEW;
  END IF;
  IF NEW.batch_id IS DISTINCT FROM OLD.batch_id OR NEW.quantity IS DISTINCT FROM OLD.quantity
     OR NEW.reported_on IS DISTINCT FROM OLD.reported_on OR NEW.loss_reason IS DISTINCT FROM OLD.loss_reason
     OR NEW.confirmed_by IS DISTINCT FROM OLD.confirmed_by OR NEW.confirmed_at IS DISTINCT FROM OLD.confirmed_at
     OR NEW.send_on IS DISTINCT FROM OLD.send_on OR NEW.ms_registration IS DISTINCT FROM OLD.ms_registration
     OR NOT (NEW.status = OLD.status OR (OLD.status = 'confirmed' AND NEW.status = 'sent')
             OR (OLD.status = 'sent' AND NEW.status IN ('accepted', 'rejected'))) THEN
    RAISE EXCEPTION 'Esta movimentação do SNGPC não pode mais ser alterada.'
      USING ERRCODE = 'FA863', DETAIL = pg_catalog.format('Movimentação em %s.', OLD.status);
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER guard_sngpc_movement BEFORE UPDATE ON sngpc_movement
  FOR EACH ROW EXECUTE FUNCTION app.guard_sngpc_movement();

CREATE POLICY sngpc_branch_select ON sngpc_branch FOR SELECT TO farmaerp_app USING (false);
CREATE POLICY sngpc_movement_select ON sngpc_movement FOR SELECT TO farmaerp_app USING (false);
CREATE POLICY sngpc_dispensing_complement_select ON sngpc_dispensing_complement FOR SELECT TO farmaerp_app USING (false);
CREATE VIEW v_sngpc_branch WITH (security_invoker = true) AS SELECT * FROM sngpc_branch WHERE deleted_at IS NULL;
CREATE VIEW v_sngpc_movement WITH (security_invoker = true) AS SELECT * FROM sngpc_movement WHERE deleted_at IS NULL;
CREATE VIEW v_sngpc_dispensing_complement WITH (security_invoker = true) AS
  SELECT * FROM sngpc_dispensing_complement WHERE deleted_at IS NULL;

-- Entra (1) ou sai (-1).
CREATE FUNCTION app.sngpc_sign(p_kind text) RETURNS integer
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$ SELECT CASE WHEN p_kind IN ('inventory', 'purchase', 'transfer_in', 'return_in', 'adjustment_in') THEN 1 ELSE -1 END $$;

-- Ordem do SNGPC: data, inventário antes, entradas antes das saídas, hora da movimentação.
CREATE FUNCTION app.sngpc_rank(p_kind text) RETURNS integer
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$ SELECT CASE WHEN p_kind = 'inventory' THEN 0 WHEN app.sngpc_sign(p_kind) = 1 THEN 1 ELSE 2 END $$;

-- Tipo do SNGPC de uma movimentação de estoque.
CREATE FUNCTION app.sngpc_kind_for(p_type text, p_quantity numeric) RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$
  SELECT CASE
    WHEN p_type = 'invoice' AND p_quantity > 0 THEN 'purchase'
    WHEN p_type = 'sale' AND p_quantity < 0 THEN 'sale'
    WHEN p_type = 'return' AND p_quantity > 0 THEN 'return_in'
    WHEN p_type = 'transfer' THEN CASE WHEN p_quantity > 0 THEN 'transfer_in' ELSE 'transfer_out' END
    WHEN p_type = 'loss' AND p_quantity < 0 THEN 'loss'
    WHEN p_quantity > 0 THEN 'adjustment_in'
    ELSE 'adjustment_out'
  END
$$;

-- Movimentação de estoque de controlado, na filial com o SNGPC aberto, entra no entreposto.
CREATE FUNCTION app.track_sngpc_movement() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  new_kind text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.sngpc_branch sb WHERE sb.branch_id = NEW.branch_id AND sb.deleted_at IS NULL) THEN
    RETURN NULL;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.product p JOIN public.catalog_product cp ON cp.id = p.catalog_product_id
     WHERE p.id = NEW.product_id AND cp.controlled_class IS NOT NULL
  ) THEN
    RETURN NULL;
  END IF;
  new_kind := app.sngpc_kind_for(NEW.movement_type, NEW.quantity);
  INSERT INTO public.sngpc_movement (
    economic_group_id, branch_id, product_id, batch_id, stock_movement_id, kind, quantity, occurred_at, reported_on, dispensing_id
  ) VALUES (
    NEW.economic_group_id, NEW.branch_id, NEW.product_id, NEW.batch_id, NEW.id, new_kind, pg_catalog.abs(NEW.quantity),
    NEW.occurred_at, app.local_day(NEW.occurred_at),
    CASE WHEN new_kind = 'sale' AND NEW.sale_item_id IS NOT NULL THEN (
      SELECT d.id FROM public.controlled_dispensing d WHERE d.sale_item_id = NEW.sale_item_id AND d.deleted_at IS NULL
    ) END
  );
  RETURN NULL;
END;
$$;
CREATE TRIGGER track_sngpc_movement AFTER INSERT ON stock_movement
  FOR EACH ROW EXECUTE FUNCTION app.track_sngpc_movement();

-- Filial do grupo em que a pessoa confere o SNGPC (FA006 fora do grupo, FA002 sem a permissão).
CREATE FUNCTION app.require_sngpc_branch(p_branch_id uuid) RETURNS public.sngpc_branch
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  found_branch public.sngpc_branch;
BEGIN
  PERFORM app.require_branch_permission('sngpc.manage', p_branch_id);
  SELECT sb.* INTO found_branch FROM public.sngpc_branch sb WHERE sb.branch_id = p_branch_id AND sb.deleted_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O SNGPC ainda não foi aberto nesta filial.' USING ERRCODE = 'FA862', DETAIL = pg_catalog.format('Filial %s.', p_branch_id);
  END IF;
  RETURN found_branch;
END;
$$;

-- Movimentação pendente, travada, de uma filial em que a pessoa confere o SNGPC.
CREATE FUNCTION app.require_sngpc_pending(p_movement_id uuid) RETURNS public.sngpc_movement
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  found_movement public.sngpc_movement;
BEGIN
  SELECT m.* INTO found_movement FROM public.sngpc_movement m
   WHERE m.id = p_movement_id AND m.economic_group_id = app.current_user_group() AND m.deleted_at IS NULL
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.' USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('sngpc_movement %s.', p_movement_id);
  END IF;
  PERFORM app.require_branch_permission('sngpc.manage', found_movement.branch_id);
  IF found_movement.status <> 'pending' THEN
    RAISE EXCEPTION 'Esta movimentação do SNGPC não pode mais ser alterada.'
      USING ERRCODE = 'FA863', DETAIL = pg_catalog.format('Movimentação em %s.', found_movement.status);
  END IF;
  RETURN found_movement;
END;
$$;

-- Lote do produto na filial (FA865 se não for).
CREATE FUNCTION app.require_sngpc_batch(p_batch_id uuid, p_branch_id uuid, p_product_id uuid) RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF p_batch_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.product_batch pb
     WHERE pb.id = p_batch_id AND pb.branch_id = p_branch_id AND pb.product_id = p_product_id AND pb.deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Os dados da movimentação do SNGPC são inválidos.'
      USING ERRCODE = 'FA865', DETAIL = 'Lote de outro produto ou filial.';
  END IF;
END;
$$;

-- Abre o SNGPC da filial com o inventário inicial: o saldo de cada lote de controlado.
-- Saldo sem lote (ou negativo) não entra e volta na resposta, para acertar o estoque.
CREATE FUNCTION app.sngpc_open(p_branch_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.branch := app.require_branch_permission('sngpc.manage', p_branch_id);
  lines integer;
BEGIN
  PERFORM 1 FROM public.branch b WHERE b.id = target.id FOR UPDATE;
  IF EXISTS (SELECT 1 FROM public.sngpc_branch sb WHERE sb.branch_id = target.id AND sb.deleted_at IS NULL) THEN
    RAISE EXCEPTION 'O SNGPC já foi aberto nesta filial.' USING ERRCODE = 'FA861', DETAIL = pg_catalog.format('Filial %s.', target.id);
  END IF;
  INSERT INTO public.sngpc_branch (economic_group_id, branch_id, opened_by)
  VALUES (app.current_user_group(), target.id, app.current_user_id());
  INSERT INTO public.sngpc_movement (economic_group_id, branch_id, product_id, batch_id, kind, quantity, occurred_at, reported_on)
  SELECT sb.economic_group_id, sb.branch_id, sb.product_id, sb.batch_id, 'inventory', sb.quantity, pg_catalog.now(),
         app.local_day(pg_catalog.now())
    FROM public.stock_balance sb
    JOIN public.product p ON p.id = sb.product_id
    JOIN public.catalog_product cp ON cp.id = p.catalog_product_id AND cp.controlled_class IS NOT NULL
   WHERE sb.branch_id = target.id AND sb.deleted_at IS NULL AND sb.batch_id IS NOT NULL AND sb.quantity > 0;
  GET DIAGNOSTICS lines = ROW_COUNT;
  RETURN pg_catalog.jsonb_build_object(
    'inventory_lines', lines,
    'unbatched', COALESCE((
      SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
               'product_code', p.code, 'product_name', p.display_name, 'quantity', sb.quantity,
               'batch_number', pb.batch_number) ORDER BY p.display_name)
        FROM public.stock_balance sb
        JOIN public.product p ON p.id = sb.product_id
        JOIN public.catalog_product cp ON cp.id = p.catalog_product_id AND cp.controlled_class IS NOT NULL
        LEFT JOIN public.product_batch pb ON pb.id = sb.batch_id
       WHERE sb.branch_id = target.id AND sb.deleted_at IS NULL AND sb.quantity <> 0
         AND (sb.batch_id IS NULL OR sb.quantity < 0)
    ), '[]'::jsonb)
  );
END;
$$;

-- Linha do inventário inicial que o estoque não tinha (lote achado na contagem).
CREATE FUNCTION app.sngpc_add_inventory(p_branch_id uuid, p_batch_id uuid, p_quantity numeric) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  opened public.sngpc_branch := app.require_sngpc_branch(p_branch_id);
  found_batch public.product_batch;
  new_id uuid;
BEGIN
  SELECT pb.* INTO found_batch FROM public.product_batch pb
    JOIN public.product p ON p.id = pb.product_id
    JOIN public.catalog_product cp ON cp.id = p.catalog_product_id AND cp.controlled_class IS NOT NULL
   WHERE pb.id = p_batch_id AND pb.branch_id = opened.branch_id AND pb.deleted_at IS NULL;
  IF NOT FOUND OR p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'Os dados da movimentação do SNGPC são inválidos.'
      USING ERRCODE = 'FA865', DETAIL = 'Lote de controlado da filial e quantidade positiva.';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.sngpc_movement m
     WHERE m.branch_id = opened.branch_id AND m.kind = 'inventory' AND m.status NOT IN ('pending', 'disregarded')
  ) OR EXISTS (
    SELECT 1 FROM public.sngpc_movement m WHERE m.batch_id = p_batch_id AND m.kind = 'inventory' AND m.status <> 'disregarded'
  ) THEN
    RAISE EXCEPTION 'Esta movimentação do SNGPC não pode mais ser alterada.'
      USING ERRCODE = 'FA863', DETAIL = 'Inventário já conferido ou lote já no inventário.';
  END IF;
  INSERT INTO public.sngpc_movement (economic_group_id, branch_id, product_id, batch_id, kind, quantity, occurred_at, reported_on)
  VALUES (opened.economic_group_id, opened.branch_id, found_batch.product_id, found_batch.id, 'inventory', p_quantity,
          opened.opened_at, app.local_day(opened.opened_at))
  RETURNING id INTO new_id;
  RETURN new_id;
END;
$$;

-- Ajustes da pendência: data do SNGPC, motivo da perda, lote (quando a movimentação veio sem),
-- quantidade do inventário.
CREATE FUNCTION app.sngpc_update_movement(p_movement_id uuid, p_data jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.sngpc_movement := app.require_sngpc_pending(p_movement_id);
  new_day date := target.reported_on;
  new_reason text := target.loss_reason;
  new_batch uuid := target.batch_id;
  new_quantity numeric := target.quantity;
BEGIN
  IF p_data ? 'reportedOn' THEN
    new_day := NULLIF(p_data ->> 'reportedOn', '')::date;
    IF new_day IS NULL OR new_day > app.local_day(pg_catalog.now()) OR target.kind = 'inventory' THEN
      RAISE EXCEPTION 'Confira a data da movimentação do SNGPC.'
        USING ERRCODE = 'FA866', DETAIL = pg_catalog.format('Data %s.', new_day);
    END IF;
  END IF;
  IF p_data ? 'lossReason' THEN
    new_reason := NULLIF(p_data ->> 'lossReason', '');
    IF target.kind NOT IN ('loss', 'adjustment_out') THEN
      RAISE EXCEPTION 'Os dados da movimentação do SNGPC são inválidos.' USING ERRCODE = 'FA865', DETAIL = 'Motivo de perda só em saída.';
    END IF;
  END IF;
  IF p_data ? 'batchId' THEN
    new_batch := NULLIF(p_data ->> 'batchId', '')::uuid;
    IF target.kind = 'sale' OR target.kind = 'inventory'
       OR (SELECT m.batch_id FROM public.stock_movement m WHERE m.id = target.stock_movement_id) IS NOT NULL THEN
      RAISE EXCEPTION 'Os dados da movimentação do SNGPC são inválidos.'
        USING ERRCODE = 'FA865', DETAIL = 'O lote só se escolhe quando a movimentação veio sem.';
    END IF;
    PERFORM app.require_sngpc_batch(new_batch, target.branch_id, target.product_id);
  END IF;
  IF p_data ? 'quantity' THEN
    new_quantity := (p_data ->> 'quantity')::numeric;
    IF target.kind <> 'inventory' OR new_quantity IS NULL OR new_quantity <= 0 THEN
      RAISE EXCEPTION 'Os dados da movimentação do SNGPC são inválidos.'
        USING ERRCODE = 'FA865', DETAIL = 'Quantidade só no inventário, e positiva.';
    END IF;
  END IF;
  UPDATE public.sngpc_movement
     SET reported_on = new_day, loss_reason = new_reason, batch_id = new_batch, quantity = new_quantity
   WHERE id = target.id;
END;
$$;

-- Completa a venda liberada como pendente: lote e receita, como no caixa. A receita vale pela
-- data da venda.
CREATE FUNCTION app.sngpc_complete_sale(p_movement_id uuid, p_data jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.sngpc_movement := app.require_sngpc_pending(p_movement_id);
  dispensing public.controlled_dispensing;
  batch uuid := NULLIF(p_data ->> 'batchId', '')::uuid;
  issued date := NULLIF(p_data ->> 'prescriptionDate', '')::date;
  rx_type text := p_data ->> 'prescriptionType';
  sold_on date;
BEGIN
  SELECT d.* INTO dispensing FROM public.controlled_dispensing d WHERE d.id = target.dispensing_id;
  IF target.kind <> 'sale' OR dispensing.id IS NULL OR dispensing.status <> 'pending' THEN
    RAISE EXCEPTION 'Só a venda de controlado liberada como pendente recebe os dados da receita.'
      USING ERRCODE = 'FA867', DETAIL = pg_catalog.format('Movimentação %s.', target.kind);
  END IF;
  PERFORM app.require_sngpc_batch(batch, target.branch_id, target.product_id);
  sold_on := app.local_day(target.occurred_at);
  IF issued IS NULL OR issued > sold_on OR issued < sold_on - app.prescription_valid_days(rx_type) THEN
    RAISE EXCEPTION 'A receita está vencida ou com data no futuro.'
      USING ERRCODE = 'FA987', DETAIL = pg_catalog.format('Receita de %s, venda de %s.', issued, sold_on);
  END IF;
  UPDATE public.sngpc_dispensing_complement SET deleted_at = pg_catalog.now()
   WHERE dispensing_id = dispensing.id AND deleted_at IS NULL;
  INSERT INTO public.sngpc_dispensing_complement (
    economic_group_id, dispensing_id, batch_id, pharmacist_id, prescription_type, prescription_number, prescription_date,
    prescriber_name, prescriber_council, prescriber_number, prescriber_state, buyer_name, buyer_document_type,
    buyer_document, buyer_issuer, buyer_state, patient_name, patient_age, patient_sex
  ) VALUES (
    target.economic_group_id, dispensing.id, batch, app.current_user_id(), rx_type,
    NULLIF(pg_catalog.btrim(COALESCE(p_data ->> 'prescriptionNumber', '')), ''), issued,
    pg_catalog.btrim(p_data ->> 'prescriberName'), p_data ->> 'prescriberCouncil', p_data ->> 'prescriberNumber',
    pg_catalog.upper(p_data ->> 'prescriberState'), pg_catalog.btrim(p_data ->> 'buyerName'), p_data ->> 'buyerDocumentType',
    p_data ->> 'buyerDocument', pg_catalog.btrim(p_data ->> 'buyerIssuer'), pg_catalog.upper(p_data ->> 'buyerState'),
    NULLIF(pg_catalog.btrim(COALESCE(p_data ->> 'patientName', '')), ''), (p_data ->> 'patientAge')::smallint,
    NULLIF(p_data ->> 'patientSex', '')
  );
  UPDATE public.sngpc_movement SET batch_id = batch WHERE id = target.id;
END;
$$;

-- Desconsidera uma linha do inventário ou um ajuste (o SNGPC não tem ajuste), com motivo.
CREATE FUNCTION app.sngpc_disregard(p_movement_id uuid, p_reason text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.sngpc_movement := app.require_sngpc_pending(p_movement_id);
  note text := pg_catalog.btrim(COALESCE(p_reason, ''));
BEGIN
  IF target.kind NOT IN ('inventory', 'adjustment_in', 'adjustment_out') THEN
    RAISE EXCEPTION 'Só o inventário e os ajustes podem ficar fora do SNGPC.'
      USING ERRCODE = 'FA868', DETAIL = pg_catalog.format('Movimentação %s.', target.kind);
  END IF;
  IF note = '' THEN
    RAISE EXCEPTION 'Informe o motivo desta ação.' USING ERRCODE = 'FA302';
  END IF;
  UPDATE public.sngpc_movement SET status = 'disregarded', status_reason = pg_catalog.left(note, 500) WHERE id = target.id;
END;
$$;

-- Simulação da conferência: os problemas de cada movimentação escolhida (vazio = pode conferir).
-- O saldo de cada lote é o das movimentações já conferidas mais as escolhidas, na ordem do SNGPC.
CREATE FUNCTION app.sngpc_check(p_branch_id uuid, p_ids uuid[])
RETURNS TABLE (movement_id uuid, problem text, suggested_on date, balance numeric)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  opened public.sngpc_branch := app.require_sngpc_branch(p_branch_id);
  today date := app.local_day(pg_catalog.now());
BEGIN
  RETURN QUERY
  WITH chosen AS (
    SELECT m.*, COALESCE(m.batch_id, sc.batch_id) AS effective_batch, d.status AS dispensing_status,
           sc.id AS complement_id
      FROM public.sngpc_movement m
      LEFT JOIN public.controlled_dispensing d ON d.id = m.dispensing_id
      LEFT JOIN public.sngpc_dispensing_complement sc ON sc.dispensing_id = m.dispensing_id AND sc.deleted_at IS NULL
     WHERE m.branch_id = opened.branch_id AND m.id = ANY (p_ids) AND m.deleted_at IS NULL
  ),
  ledger AS (
    SELECT l.id, l.effective_batch, l.kind, l.reported_on, l.occurred_at, l.chosen,
           pg_catalog.sum(app.sngpc_sign(l.kind) * l.quantity) OVER w AS running,
           pg_catalog.count(*) FILTER (WHERE app.sngpc_sign(l.kind) = 1) OVER w AS entries_before
      FROM (
        SELECT m.id, m.batch_id AS effective_batch, m.kind, m.reported_on, m.occurred_at, m.quantity, false AS chosen
          FROM public.sngpc_movement m
         WHERE m.branch_id = opened.branch_id AND m.status IN ('confirmed', 'sent', 'accepted') AND m.deleted_at IS NULL
        UNION ALL
        SELECT c.id, c.effective_batch, c.kind, c.reported_on, c.occurred_at, c.quantity, true
          FROM chosen c WHERE c.status = 'pending' AND c.effective_batch IS NOT NULL
      ) l
    WINDOW w AS (PARTITION BY l.effective_batch ORDER BY l.reported_on, app.sngpc_rank(l.kind), l.occurred_at, l.id
                 ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
  ),
  problems AS (
    SELECT c.id, 'not_pending' AS problem, NULL::date AS suggested_on, NULL::numeric AS balance
      FROM chosen c WHERE c.status <> 'pending'
    UNION ALL
    SELECT c.id, 'inventory_pending', NULL, NULL FROM chosen c
     WHERE c.status = 'pending' AND c.kind <> 'inventory' AND EXISTS (
       SELECT 1 FROM public.sngpc_movement m
        WHERE m.branch_id = opened.branch_id AND m.kind = 'inventory' AND m.status = 'pending' AND NOT (m.id = ANY (p_ids))
     )
    UNION ALL
    SELECT c.id, 'missing_batch', NULL, NULL FROM chosen c WHERE c.status = 'pending' AND c.effective_batch IS NULL
    UNION ALL
    SELECT c.id, 'missing_ms', NULL, NULL FROM chosen c
      JOIN public.product_batch pb ON pb.id = c.effective_batch
     WHERE c.status = 'pending' AND pb.ms_registration IS NULL
    UNION ALL
    SELECT c.id, 'missing_prescription', NULL, NULL FROM chosen c
     WHERE c.status = 'pending' AND c.dispensing_status = 'pending' AND c.complement_id IS NULL
    UNION ALL
    SELECT c.id, 'missing_loss_reason', NULL, NULL FROM chosen c
     WHERE c.status = 'pending' AND c.kind IN ('loss', 'adjustment_out') AND c.loss_reason IS NULL
    UNION ALL
    SELECT c.id, 'adjustment_in', NULL, NULL FROM chosen c WHERE c.status = 'pending' AND c.kind = 'adjustment_in'
    UNION ALL
    SELECT c.id, 'date_future', NULL, NULL FROM chosen c WHERE c.status = 'pending' AND c.reported_on > today
    UNION ALL
    SELECT c.id, 'date_before_start', app.local_day(opened.opened_at), NULL FROM chosen c
     WHERE c.status = 'pending' AND c.reported_on < app.local_day(opened.opened_at)
    UNION ALL
    -- Pendência anterior do mesmo produto (fora da escolha) segura as posteriores.
    SELECT c.id, 'earlier_pending', NULL, NULL FROM chosen c
     WHERE c.status = 'pending' AND EXISTS (
       SELECT 1 FROM public.sngpc_movement m
        WHERE m.branch_id = c.branch_id AND m.product_id = c.product_id AND m.status = 'pending' AND m.deleted_at IS NULL
          AND NOT (m.id = ANY (p_ids))
          AND (m.reported_on, app.sngpc_rank(m.kind), m.occurred_at, m.id)
              < (c.reported_on, app.sngpc_rank(c.kind), c.occurred_at, c.id)
     )
    UNION ALL
    -- Saída antes de qualquer entrada do lote: sugere a data da primeira entrada.
    SELECT l.id, 'out_before_entry',
           (SELECT pg_catalog.min(e.reported_on) FROM ledger e
             WHERE e.effective_batch = l.effective_batch AND app.sngpc_sign(e.kind) = 1),
           l.running
      FROM ledger l
     WHERE l.chosen AND app.sngpc_sign(l.kind) = -1 AND l.entries_before = 0
    UNION ALL
    SELECT l.id, 'negative_balance', NULL, l.running
      FROM ledger l
     WHERE l.chosen AND app.sngpc_sign(l.kind) = -1 AND l.entries_before > 0 AND l.running < 0
    UNION ALL
    -- Saída escolhida antes de uma movimentação já conferida que ficaria negativa.
    SELECT l.id, 'negative_balance', NULL, later.running
      FROM ledger l
      JOIN LATERAL (
        SELECT pg_catalog.min(x.running) AS running FROM ledger x
         WHERE x.effective_batch = l.effective_batch AND NOT x.chosen AND x.running < 0
           AND (x.reported_on, app.sngpc_rank(x.kind), x.occurred_at, x.id) > (l.reported_on, app.sngpc_rank(l.kind), l.occurred_at, l.id)
      ) later ON later.running IS NOT NULL
     WHERE l.chosen AND app.sngpc_sign(l.kind) = -1 AND l.running >= 0
  )
  SELECT p.id, p.problem, p.suggested_on, p.balance FROM problems p ORDER BY p.id, p.problem;
END;
$$;

-- Conferência do farmacêutico (a senha é conferida na API): tudo ou nada, com a data de envio.
CREATE FUNCTION app.sngpc_confirm(p_branch_id uuid, p_ids uuid[], p_send_on date) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  opened public.sngpc_branch := app.require_sngpc_branch(p_branch_id);
  found_problems jsonb;
  done integer;
BEGIN
  -- Uma conferência por vez na filial: a simulação vale para o que vai ser gravado.
  PERFORM 1 FROM public.sngpc_branch sb WHERE sb.id = opened.id FOR UPDATE;
  IF p_ids IS NULL OR pg_catalog.cardinality(p_ids) = 0 OR pg_catalog.cardinality(p_ids) > 500
     OR (SELECT pg_catalog.count(*) FROM public.sngpc_movement m
          WHERE m.branch_id = opened.branch_id AND m.id = ANY (p_ids) AND m.deleted_at IS NULL)
        <> (SELECT pg_catalog.count(DISTINCT x) FROM pg_catalog.unnest(p_ids) x) THEN
    RAISE EXCEPTION 'Os dados da movimentação do SNGPC são inválidos.'
      USING ERRCODE = 'FA865', DETAIL = 'Escolha de 1 a 500 movimentações da filial.';
  END IF;
  IF p_send_on IS NULL OR p_send_on < app.local_day(pg_catalog.now()) THEN
    RAISE EXCEPTION 'Confira a data da movimentação do SNGPC.'
      USING ERRCODE = 'FA866', DETAIL = pg_catalog.format('Envio em %s.', p_send_on);
  END IF;
  SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('id', c.movement_id, 'problem', c.problem))
    INTO found_problems FROM app.sngpc_check(p_branch_id, p_ids) c;
  IF found_problems IS NOT NULL THEN
    RAISE EXCEPTION 'A conferência do SNGPC tem pendências.'
      USING ERRCODE = 'FA864', DETAIL = pg_catalog.left(found_problems::text, 900);
  END IF;
  UPDATE public.sngpc_movement m
     SET status = 'confirmed', confirmed_by = app.current_user_id(), confirmed_at = pg_catalog.now(), send_on = p_send_on,
         batch_id = COALESCE(m.batch_id, sc.batch_id),
         ms_registration = (SELECT pb.ms_registration FROM public.product_batch pb WHERE pb.id = COALESCE(m.batch_id, sc.batch_id))
    FROM (SELECT x.id, (SELECT c.batch_id FROM public.sngpc_dispensing_complement c
                          JOIN public.sngpc_movement mm ON mm.dispensing_id = c.dispensing_id
                         WHERE mm.id = x.id AND c.deleted_at IS NULL) AS batch_id
            FROM pg_catalog.unnest(p_ids) AS x(id)) sc
   WHERE m.id = sc.id;
  GET DIAGNOSTICS done = ROW_COUNT;
  RETURN done;
END;
$$;

-- Filiais em que a pessoa confere o SNGPC, com a situação de cada uma.
CREATE FUNCTION app.sngpc_branches()
RETURNS TABLE (
  branch_id uuid, branch_name text, opened_at timestamptz, inventory_pending integer, pending integer,
  oldest_pending date, confirmed integer, send_due integer
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT b.id, b.name, sb.opened_at,
         (SELECT pg_catalog.count(*)::integer FROM public.sngpc_movement m
           WHERE m.branch_id = b.id AND m.kind = 'inventory' AND m.status = 'pending'),
         (SELECT pg_catalog.count(*)::integer FROM public.sngpc_movement m WHERE m.branch_id = b.id AND m.status = 'pending'),
         (SELECT pg_catalog.min(m.reported_on) FROM public.sngpc_movement m WHERE m.branch_id = b.id AND m.status = 'pending'),
         (SELECT pg_catalog.count(*)::integer FROM public.sngpc_movement m WHERE m.branch_id = b.id AND m.status = 'confirmed'),
         (SELECT pg_catalog.count(*)::integer FROM public.sngpc_movement m
           WHERE m.branch_id = b.id AND m.status = 'confirmed' AND m.send_on <= app.local_day(pg_catalog.now()))
    FROM public.branch b
    JOIN public.company co ON co.id = b.company_id
    LEFT JOIN public.sngpc_branch sb ON sb.branch_id = b.id AND sb.deleted_at IS NULL
   WHERE b.deleted_at IS NULL AND co.economic_group_id = app.current_user_group()
     AND app.has_permission('sngpc.manage', b.id)
   ORDER BY b.name
$$;

-- Movimentações da filial, na ordem do SNGPC. A venda mostra a receita e o comprador mascarado.
CREATE FUNCTION app.sngpc_movements(p_branch_id uuid, p_status text DEFAULT 'pending')
RETURNS TABLE (
  id uuid, kind text, status text, status_reason text, reported_on date, occurred_at timestamptz,
  product_id uuid, product_code bigint, product_name text, controlled_class text,
  batch_id uuid, batch_number text, expires_on date, ms_registration text, quantity numeric, loss_reason text,
  origin_batch boolean, counterpart text, dispensing_status text, prescription text, buyer text,
  send_on date, confirmed_by_name text, confirmed_at timestamptz
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  opened public.sngpc_branch := app.require_sngpc_branch(p_branch_id);
BEGIN
  IF p_status NOT IN ('pending', 'confirmed', 'sent', 'accepted', 'rejected', 'disregarded') THEN
    RAISE EXCEPTION 'Os dados da movimentação do SNGPC são inválidos.' USING ERRCODE = 'FA865', DETAIL = 'Situação desconhecida.';
  END IF;
  RETURN QUERY
  SELECT m.id, m.kind, m.status, m.status_reason, m.reported_on, m.occurred_at,
         p.id, p.code, p.display_name, cp.controlled_class,
         eb.id, eb.batch_number, eb.expires_on, COALESCE(m.ms_registration, eb.ms_registration), m.quantity, m.loss_reason,
         sm.batch_id IS NOT NULL,
         CASE
           WHEN m.kind = 'purchase' THEN (SELECT pi.emitter_name || ' · NF ' || pi.number
                                            FROM public.purchase_invoice_item pii JOIN public.purchase_invoice pi ON pi.id = pii.invoice_id
                                           WHERE pii.id = sm.purchase_invoice_item_id)
           WHEN m.kind IN ('transfer_in', 'transfer_out') THEN (SELECT ob.name FROM public.stock_movement o JOIN public.branch ob ON ob.id = o.branch_id
                                                                 WHERE o.transfer_group = sm.transfer_group AND o.id <> sm.id LIMIT 1)
           WHEN m.kind = 'sale' THEN (SELECT 'Venda ' || s.code FROM public.sale s JOIN public.sale_item si ON si.sale_id = s.id
                                       WHERE si.id = sm.sale_item_id)
           ELSE sm.reason
         END,
         CASE WHEN d.id IS NULL THEN NULL WHEN d.status = 'complete' THEN 'complete'
              WHEN sc.id IS NOT NULL THEN 'complemented' ELSE 'pending' END,
         CASE WHEN COALESCE(sc.prescription_type, d.prescription_type) IS NOT NULL
              THEN COALESCE(sc.prescription_type, d.prescription_type) || ' ' || COALESCE(sc.prescription_number, d.prescription_number, '')
                   || ' de ' || pg_catalog.to_char(COALESCE(sc.prescription_date, d.prescription_date), 'DD/MM/YYYY') END,
         CASE WHEN COALESCE(sc.buyer_name, d.buyer_name) IS NOT NULL
              THEN COALESCE(sc.buyer_name, d.buyer_name) || ' · ' || pg_catalog.repeat('*', GREATEST(pg_catalog.length(COALESCE(sc.buyer_document, d.buyer_document)) - 3, 0))
                   || pg_catalog.right(COALESCE(sc.buyer_document, d.buyer_document), 3) END,
         m.send_on, u.name, m.confirmed_at
    FROM public.sngpc_movement m
    JOIN public.product p ON p.id = m.product_id
    LEFT JOIN public.catalog_product cp ON cp.id = p.catalog_product_id
    LEFT JOIN public.stock_movement sm ON sm.id = m.stock_movement_id
    LEFT JOIN public.controlled_dispensing d ON d.id = m.dispensing_id
    LEFT JOIN public.sngpc_dispensing_complement sc ON sc.dispensing_id = m.dispensing_id AND sc.deleted_at IS NULL
    LEFT JOIN public.product_batch eb ON eb.id = COALESCE(m.batch_id, sc.batch_id)
    LEFT JOIN public.user_account u ON u.id = m.confirmed_by
   WHERE m.branch_id = opened.branch_id AND m.status = p_status AND m.deleted_at IS NULL
   ORDER BY m.reported_on, app.sngpc_rank(m.kind), m.occurred_at, m.id
   LIMIT 1000;
END;
$$;

-- Lotes do produto na filial, para escolher o lote da pendência ou do inventário.
CREATE FUNCTION app.sngpc_batches(p_branch_id uuid, p_product_id uuid)
RETURNS TABLE (id uuid, batch_number text, expires_on date, ms_registration text, quantity numeric)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM app.require_sngpc_branch(p_branch_id);
  RETURN QUERY
  SELECT pb.id, pb.batch_number, pb.expires_on, pb.ms_registration,
         COALESCE((SELECT sb.quantity FROM public.stock_balance sb WHERE sb.batch_id = pb.id AND sb.deleted_at IS NULL), 0)
    FROM public.product_batch pb
   WHERE pb.branch_id = p_branch_id AND pb.product_id = p_product_id AND pb.deleted_at IS NULL
   ORDER BY pb.expires_on, pb.batch_number;
END;
$$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  app.sngpc_open(uuid),
  app.sngpc_add_inventory(uuid, uuid, numeric),
  app.sngpc_update_movement(uuid, jsonb),
  app.sngpc_complete_sale(uuid, jsonb),
  app.sngpc_disregard(uuid, text),
  app.sngpc_check(uuid, uuid[]),
  app.sngpc_confirm(uuid, uuid[], date),
  app.sngpc_branches(),
  app.sngpc_movements(uuid, text),
  app.sngpc_batches(uuid, uuid)
TO farmaerp_app;
