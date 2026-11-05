-- Up Migration

-- Estoque: movimentações imutáveis são a fonte da verdade, e o saldo é mantido por trigger.
-- O lote é cadastrado por filial e produto. Toda escrita da API passa pelas funções app.*.

-- Dia no fuso da operação: a validade é uma data, não um instante.
CREATE FUNCTION app.local_today() RETURNS date
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT (pg_catalog.now() AT TIME ZONE 'America/Sao_Paulo')::date
$$;

-- Parâmetro por filial e produto. Em controlado, o lote é obrigatório de qualquer forma.
ALTER TABLE product_branch_status ADD COLUMN tracks_batches boolean NOT NULL DEFAULT false;

-- security_invoker precisa ser repetido: CREATE OR REPLACE substitui as opções da view.
CREATE OR REPLACE VIEW v_product_branch_status WITH (security_invoker = true) AS
  SELECT * FROM product_branch_status WHERE deleted_at IS NULL;

CREATE TABLE product_batch (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  branch_id uuid NOT NULL REFERENCES branch (id),
  product_id uuid NOT NULL REFERENCES product (id),
  batch_number text NOT NULL CONSTRAINT product_batch_number_check CHECK (btrim(batch_number) <> '' AND length(batch_number) <= 40),
  expires_on date NOT NULL,
  ms_registration text CONSTRAINT product_batch_ms_check CHECK (ms_registration ~ '^[0-9]{9,13}$'),
  -- O MS com que o lote nasceu: a edição é permitida, mas o valor original não se perde.
  ms_original text CONSTRAINT product_batch_ms_original_check CHECK (ms_original ~ '^[0-9]{9,13}$'),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE UNIQUE INDEX product_batch_number_active_key
  ON product_batch (branch_id, product_id, upper(batch_number)) WHERE deleted_at IS NULL;
CREATE INDEX product_batch_product_id_idx ON product_batch (product_id);

-- Quem, quando (colunas padrão), o que era e por quê.
CREATE TABLE product_batch_event (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  batch_id uuid NOT NULL REFERENCES product_batch (id),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  branch_id uuid NOT NULL REFERENCES branch (id),
  old_number text NOT NULL,
  new_number text NOT NULL,
  old_expires_on date NOT NULL,
  new_expires_on date NOT NULL,
  old_ms text,
  new_ms text,
  reason text NOT NULL CONSTRAINT product_batch_event_reason_check CHECK (btrim(reason) <> ''),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE INDEX product_batch_event_batch_id_idx ON product_batch_event (batch_id, created_at DESC);
CREATE INDEX product_batch_event_branch_id_idx ON product_batch_event (branch_id);

CREATE TABLE stock_movement (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  branch_id uuid NOT NULL REFERENCES branch (id),
  product_id uuid NOT NULL REFERENCES product (id),
  batch_id uuid REFERENCES product_batch (id),
  movement_type text NOT NULL CONSTRAINT stock_movement_type_check CHECK (movement_type IN (
    'invoice', 'sale', 'return', 'transfer', 'adjustment', 'loss', 'inventory'
  )),
  -- Positivo entra, negativo sai. Três casas por causa do fracionamento.
  quantity numeric(14, 3) NOT NULL CONSTRAINT stock_movement_quantity_check CHECK (quantity <> 0),
  reason text,
  -- Correção é uma movimentação contrária, ligada à original.
  reversal_of uuid REFERENCES stock_movement (id),
  -- Baixa fora da ordem de vencimento, liberada por permissão.
  fefo_override boolean NOT NULL DEFAULT false,
  occurred_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
-- Esta tabela só cresce: as listas das últimas movimentações precisam vir direto do índice.
CREATE INDEX stock_movement_recent_idx ON stock_movement (occurred_at DESC, id DESC);
CREATE INDEX stock_movement_branch_recent_idx ON stock_movement (branch_id, occurred_at DESC, id DESC);
CREATE INDEX stock_movement_product_recent_idx ON stock_movement (product_id, occurred_at DESC, id DESC);
CREATE INDEX stock_movement_batch_id_idx ON stock_movement (batch_id);
CREATE UNIQUE INDEX stock_movement_reversal_active_key
  ON stock_movement (reversal_of) WHERE reversal_of IS NOT NULL AND deleted_at IS NULL;

CREATE TABLE stock_balance (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  branch_id uuid NOT NULL REFERENCES branch (id),
  product_id uuid NOT NULL REFERENCES product (id),
  batch_id uuid REFERENCES product_batch (id),
  quantity numeric(14, 3) NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE UNIQUE INDEX stock_balance_active_key
  ON stock_balance (branch_id, product_id, COALESCE(batch_id, '00000000-0000-0000-0000-000000000000'::uuid))
  WHERE deleted_at IS NULL;
CREATE INDEX stock_balance_product_id_idx ON stock_balance (product_id);
CREATE INDEX stock_balance_batch_id_idx ON stock_balance (batch_id);

CALL app.apply_table_standard('public.product_batch');
CALL app.apply_table_standard('public.product_batch_event');
CALL app.apply_table_standard('public.stock_movement');
CALL app.apply_table_standard('public.stock_balance');

CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON product_batch
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns('economic_group_id', 'branch_id', 'product_id', 'ms_original');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON product_batch_event
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'batch_id', 'economic_group_id', 'branch_id', 'old_number', 'new_number', 'old_expires_on',
    'new_expires_on', 'old_ms', 'new_ms', 'reason'
  );
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON stock_balance
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns('economic_group_id', 'branch_id', 'product_id', 'batch_id');

-- Movimentação não muda de jeito nenhum, nem a exclusão lógica: correção é outra movimentação.
CREATE FUNCTION app.block_movement_change() RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  RAISE EXCEPTION 'Este dado não pode ser alterado depois do cadastro.'
    USING ERRCODE = 'FA104', DETAIL = pg_catalog.format('stock_movement %s é imutável.', OLD.id);
END;
$$;

CREATE TRIGGER block_movement_change BEFORE UPDATE ON stock_movement
  FOR EACH ROW EXECUTE FUNCTION app.block_movement_change();

-- Produto exige lote nesta filial? Controlado sempre; os demais, conforme o parâmetro.
CREATE FUNCTION app.batch_required(p_product_id uuid, p_branch_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE((
    SELECT cp.controlled_class IS NOT NULL
      FROM public.product p
      JOIN public.catalog_product cp ON cp.id = p.catalog_product_id
     WHERE p.id = p_product_id
  ), false)
  OR COALESCE((
    SELECT s.tracks_batches
      FROM public.product_branch_status s
     WHERE s.product_id = p_product_id AND s.branch_id = p_branch_id AND s.deleted_at IS NULL
  ), false)
$$;

-- Regras da movimentação, valendo para qualquer caminho de escrita.
CREATE FUNCTION app.validate_stock_movement() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  original public.stock_movement;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.product p
     WHERE p.id = NEW.product_id AND p.economic_group_id = NEW.economic_group_id AND p.deleted_at IS NULL
  ) OR NOT EXISTS (
    SELECT 1 FROM public.branch b
      JOIN public.company c ON c.id = b.company_id
     WHERE b.id = NEW.branch_id AND b.deleted_at IS NULL AND c.economic_group_id = NEW.economic_group_id
  ) THEN
    RAISE EXCEPTION 'Um dos itens informados não foi encontrado.'
      USING ERRCODE = 'FA004', DETAIL = pg_catalog.format('Produto %s, filial %s.', NEW.product_id, NEW.branch_id);
  END IF;

  IF NEW.batch_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.product_batch b
     WHERE b.id = NEW.batch_id AND b.branch_id = NEW.branch_id
       AND b.product_id = NEW.product_id AND b.deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Lote não encontrado neste produto e filial.'
      USING ERRCODE = 'FA808', DETAIL = pg_catalog.format('product_batch %s.', NEW.batch_id);
  END IF;

  IF NEW.reversal_of IS NOT NULL THEN
    SELECT * INTO original FROM public.stock_movement m WHERE m.id = NEW.reversal_of;
    IF NOT FOUND
       OR original.reversal_of IS NOT NULL
       OR original.branch_id <> NEW.branch_id
       OR original.product_id <> NEW.product_id
       OR original.batch_id IS DISTINCT FROM NEW.batch_id
       OR original.quantity <> -NEW.quantity THEN
      RAISE EXCEPTION 'Esta movimentação não pode ser estornada.'
        USING ERRCODE = 'FA811', DETAIL = pg_catalog.format('Estorno de %s.', NEW.reversal_of);
    END IF;
    -- O estorno devolve exatamente o que a original fez, então não passa pelas regras de lote.
    RETURN NEW;
  END IF;

  IF app.batch_required(NEW.product_id, NEW.branch_id) THEN
    -- Só uma saída sem lote é aceita, para zerar o saldo antigo de um produto que passou a
    -- exigir lote. Sem isso, esse saldo não teria como ser regularizado.
    IF NEW.batch_id IS NULL AND NOT (
      NEW.quantity < 0 AND EXISTS (
        SELECT 1 FROM public.stock_balance sb
         WHERE sb.branch_id = NEW.branch_id AND sb.product_id = NEW.product_id
           AND sb.batch_id IS NULL AND sb.quantity > 0 AND sb.deleted_at IS NULL
      )
    ) THEN
      RAISE EXCEPTION 'Este produto exige lote nesta filial.'
        USING ERRCODE = 'FA802', DETAIL = pg_catalog.format('Produto %s, filial %s.', NEW.product_id, NEW.branch_id);
    END IF;
  ELSIF NEW.batch_id IS NOT NULL THEN
    RAISE EXCEPTION 'Este produto não controla lote nesta filial.'
      USING ERRCODE = 'FA803', DETAIL = pg_catalog.format('Produto %s, filial %s.', NEW.product_id, NEW.branch_id);
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER validate_parent BEFORE INSERT ON stock_movement
  FOR EACH ROW EXECUTE FUNCTION app.validate_stock_movement();

-- O saldo só muda aqui. A linha fica travada até o fim da transação, então duas saídas ao mesmo
-- tempo não passam juntas. Só a venda pode deixar negativo: o PDV pode vender offline, e essa
-- venda já aconteceu na loja.
CREATE FUNCTION app.apply_stock_movement() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  new_quantity numeric;
BEGIN
  INSERT INTO public.stock_balance (economic_group_id, branch_id, product_id, batch_id, quantity)
  VALUES (NEW.economic_group_id, NEW.branch_id, NEW.product_id, NEW.batch_id, NEW.quantity)
  ON CONFLICT (branch_id, product_id, COALESCE(batch_id, '00000000-0000-0000-0000-000000000000'::uuid))
    WHERE deleted_at IS NULL
  DO UPDATE SET quantity = public.stock_balance.quantity + EXCLUDED.quantity
  RETURNING quantity INTO new_quantity;

  IF NEW.quantity < 0 AND new_quantity < 0 AND NEW.movement_type <> 'sale' THEN
    RAISE EXCEPTION 'A quantidade é maior que o saldo disponível.'
      USING ERRCODE = 'FA801',
            DETAIL = pg_catalog.format('Produto %s, filial %s, lote %s, saldo ficaria %s.', NEW.product_id, NEW.branch_id, NEW.batch_id, new_quantity);
  END IF;
  RETURN NULL;
END;
$$;

CREATE TRIGGER apply_stock_movement AFTER INSERT ON stock_movement
  FOR EACH ROW EXECUTE FUNCTION app.apply_stock_movement();

INSERT INTO permission (code, module, name) VALUES
  ('stock.view', 'Estoque', 'Ver saldo, lotes e movimentações'),
  ('stock.loss', 'Estoque', 'Registrar perda'),
  ('stock.transfer', 'Estoque', 'Transferir entre filiais'),
  ('stock.adjust', 'Estoque', 'Ajustar estoque e fazer inventário'),
  ('stock.batch', 'Estoque', 'Editar lote, validade e MS, e ligar o controle de lote'),
  ('stock.batch_override', 'Estoque', 'Baixar fora da ordem de vencimento');

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

  INSERT INTO public.role_permission (role_id, permission_id)
  SELECT manager_id, p.id
    FROM public.permission p
   WHERE p.code IN (
     'users.view', 'users.reset_password', 'terminals.view', 'terminals.request', 'terminals.block',
     'products.view', 'stock.view', 'stock.loss', 'stock.transfer', 'stock.batch_override'
   );
END;
$$;

-- Grupos que já existem: o Gerente, identificado pelo nome, recebe as permissões da loja.
INSERT INTO role_permission (role_id, permission_id)
SELECT r.id, p.id
  FROM role r
 CROSS JOIN permission p
 WHERE r.name = 'Gerente' AND r.deleted_at IS NULL
   AND p.code IN ('stock.view', 'stock.loss', 'stock.transfer', 'stock.batch_override');

CREATE FUNCTION app.require_stock_permission(p_code text, p_branch_id uuid) RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT app.has_permission(p_code, p_branch_id) THEN
    RAISE EXCEPTION 'Você não tem permissão para esta operação.'
      USING ERRCODE = 'FA002', DETAIL = pg_catalog.format('%s na filial %s.', p_code, p_branch_id);
  END IF;
END;
$$;

-- Produto localizado pelo código ou pelo código de barras. Não achou, é erro.
CREATE FUNCTION app.require_product_lookup(p_lookup text) RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  found_id uuid := app.find_product_id(p_lookup);
BEGIN
  IF found_id IS NULL THEN
    RAISE EXCEPTION 'Um dos itens informados não foi encontrado.'
      USING ERRCODE = 'FA004', DETAIL = 'Produto não localizado.';
  END IF;
  RETURN found_id;
END;
$$;

-- Entrada: usa o lote de mesmo número ou cria. O MS vazio herda o do Catálogo. Lote que já existe
-- com outra validade ou MS é recusado, para não misturar dados sem querer.
CREATE FUNCTION app.batch_for_entry(
  p_group_id uuid, p_branch_id uuid, p_product_id uuid, p_number text, p_expires_on date, p_ms text
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  clean_number text := pg_catalog.upper(pg_catalog.btrim(COALESCE(p_number, '')));
  clean_ms text := NULLIF(pg_catalog.btrim(COALESCE(p_ms, '')), '');
  existing public.product_batch;
  base_ms text;
  new_id uuid;
BEGIN
  IF clean_number = '' THEN
    RAISE EXCEPTION 'Este produto exige lote nesta filial.'
      USING ERRCODE = 'FA802', DETAIL = 'Entrada sem número de lote.';
  END IF;

  SELECT * INTO existing FROM public.product_batch b
   WHERE b.branch_id = p_branch_id AND b.product_id = p_product_id
     AND pg_catalog.upper(b.batch_number) = clean_number AND b.deleted_at IS NULL;
  IF FOUND THEN
    IF (p_expires_on IS NOT NULL AND p_expires_on <> existing.expires_on)
       OR (clean_ms IS NOT NULL AND clean_ms IS DISTINCT FROM existing.ms_registration) THEN
      RAISE EXCEPTION 'Este lote já existe com outra validade ou outro MS.'
        USING ERRCODE = 'FA804', DETAIL = pg_catalog.format('product_batch %s.', existing.id);
    END IF;
    RETURN existing.id;
  END IF;

  IF p_expires_on IS NULL THEN
    RAISE EXCEPTION 'Os dados do lote são inválidos.'
      USING ERRCODE = 'FA806', DETAIL = 'Lote novo sem validade.';
  END IF;

  SELECT cp.ms_registration INTO base_ms
    FROM public.product p
    JOIN public.catalog_product cp ON cp.id = p.catalog_product_id
   WHERE p.id = p_product_id;

  INSERT INTO public.product_batch (
    economic_group_id, branch_id, product_id, batch_number, expires_on, ms_registration, ms_original
  ) VALUES (
    p_group_id, p_branch_id, p_product_id, clean_number, p_expires_on,
    COALESCE(clean_ms, base_ms), COALESCE(clean_ms, base_ms)
  ) RETURNING id INTO new_id;
  RETURN new_id;
END;
$$;

CREATE FUNCTION app.find_batch(p_branch_id uuid, p_product_id uuid, p_number text) RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  found_id uuid;
BEGIN
  SELECT b.id INTO found_id FROM public.product_batch b
   WHERE b.branch_id = p_branch_id AND b.product_id = p_product_id
     AND pg_catalog.upper(b.batch_number) = pg_catalog.upper(pg_catalog.btrim(p_number))
     AND b.deleted_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Lote não encontrado neste produto e filial.'
      USING ERRCODE = 'FA808', DETAIL = 'Número de lote não localizado.';
  END IF;
  RETURN found_id;
END;
$$;

CREATE FUNCTION app.require_positive_quantity(p_quantity numeric) RETURNS void
LANGUAGE plpgsql IMMUTABLE
SET search_path = ''
AS $$
BEGIN
  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'Os dados da movimentação são inválidos.'
      USING ERRCODE = 'FA810', DETAIL = 'A quantidade precisa ser maior que zero.';
  END IF;
END;
$$;

CREATE FUNCTION app.require_reason(p_reason text) RETURNS text
LANGUAGE plpgsql IMMUTABLE
SET search_path = ''
AS $$
BEGIN
  IF pg_catalog.btrim(COALESCE(p_reason, '')) = '' THEN
    RAISE EXCEPTION 'Informe o motivo desta ação.'
      USING ERRCODE = 'FA302', DETAIL = 'Operação de estoque sem motivo.';
  END IF;
  RETURN pg_catalog.btrim(p_reason);
END;
$$;

-- Ajuste de entrada ou de saída.
CREATE FUNCTION app.adjust_stock(p_data jsonb) RETURNS uuid
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
    -- Só cria lote se o produto controla. Sem controle, quem recusa é o trigger, mas o lote
    -- nem chegaria a existir por causa do rollback da transação.
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
  RETURN new_id;
END;
$$;

CREATE FUNCTION app.register_stock_loss(p_data jsonb) RETURNS uuid
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
  RETURN new_id;
END;
$$;

-- Correção por movimentação contrária. Nota, venda e devolução têm fluxo próprio.
CREATE FUNCTION app.reverse_stock_movement(p_id uuid, p_reason text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  clean_reason text := app.require_reason(p_reason);
  original public.stock_movement;
  new_id uuid;
BEGIN
  SELECT * INTO original FROM public.stock_movement m
   WHERE m.id = p_id AND m.economic_group_id = app.current_user_group();
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('stock_movement %s.', p_id);
  END IF;
  PERFORM app.require_stock_permission('stock.adjust', original.branch_id);
  IF original.movement_type NOT IN ('adjustment', 'loss', 'inventory') OR original.reversal_of IS NOT NULL THEN
    RAISE EXCEPTION 'Esta movimentação não pode ser estornada.'
      USING ERRCODE = 'FA811', DETAIL = pg_catalog.format('Tipo %s.', original.movement_type);
  END IF;

  INSERT INTO public.stock_movement (
    economic_group_id, branch_id, product_id, batch_id, movement_type, quantity, reason, reversal_of
  ) VALUES (
    original.economic_group_id, original.branch_id, original.product_id, original.batch_id,
    original.movement_type, -original.quantity, clean_reason, original.id
  ) RETURNING id INTO new_id;
  RETURN new_id;
END;
$$;

-- Corrige lote, validade ou MS. O valor anterior fica no histórico, e o MS original, no próprio lote.
CREATE FUNCTION app.update_product_batch(p_id uuid, p_data jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  clean_reason text := app.require_reason(p_data ->> 'reason');
  target public.product_batch;
  new_number text;
  new_expires date;
  new_ms text;
BEGIN
  SELECT * INTO target FROM public.product_batch b
   WHERE b.id = p_id AND b.economic_group_id = app.current_user_group() AND b.deleted_at IS NULL
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('product_batch %s.', p_id);
  END IF;
  PERFORM app.require_stock_permission('stock.batch', target.branch_id);

  new_number := pg_catalog.upper(pg_catalog.btrim(COALESCE(p_data ->> 'batchNumber', target.batch_number)));
  new_expires := COALESCE((p_data ->> 'expiresOn')::date, target.expires_on);
  new_ms := NULLIF(pg_catalog.btrim(COALESCE(p_data ->> 'msRegistration', '')), '');

  UPDATE public.product_batch b
     SET batch_number = new_number, expires_on = new_expires, ms_registration = new_ms
   WHERE b.id = target.id;

  INSERT INTO public.product_batch_event (
    batch_id, economic_group_id, branch_id, old_number, new_number, old_expires_on, new_expires_on,
    old_ms, new_ms, reason
  ) VALUES (
    target.id, target.economic_group_id, target.branch_id, target.batch_number, new_number,
    target.expires_on, new_expires, target.ms_registration, new_ms, clean_reason
  );
END;
$$;

-- Ligar exige saldo sem lote zerado, e desligar, saldo em lotes zerado: sem isso, a mesma caixa
-- ficaria contada de duas formas.
CREATE FUNCTION app.set_batch_tracking(p_product_id uuid, p_branch_id uuid, p_tracks boolean) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  row_id uuid;
BEGIN
  PERFORM app.require_stock_permission('stock.batch', p_branch_id);

  SELECT s.id INTO row_id FROM public.product_branch_status s
   WHERE s.product_id = p_product_id AND s.branch_id = p_branch_id
     AND s.economic_group_id = app.current_user_group() AND s.deleted_at IS NULL
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('Produto %s, filial %s.', p_product_id, p_branch_id);
  END IF;

  IF NOT p_tracks AND EXISTS (
    SELECT 1 FROM public.product p
      JOIN public.catalog_product cp ON cp.id = p.catalog_product_id
     WHERE p.id = p_product_id AND cp.controlled_class IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'Produto controlado sempre exige lote.'
      USING ERRCODE = 'FA807', DETAIL = pg_catalog.format('Produto %s.', p_product_id);
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.stock_balance sb
     WHERE sb.product_id = p_product_id AND sb.branch_id = p_branch_id AND sb.deleted_at IS NULL
       AND sb.quantity <> 0
       AND (CASE WHEN p_tracks THEN sb.batch_id IS NULL ELSE sb.batch_id IS NOT NULL END)
  ) THEN
    RAISE EXCEPTION 'O controle de lote só muda com o saldo zerado.'
      USING ERRCODE = 'FA809', DETAIL = pg_catalog.format('Produto %s, filial %s.', p_product_id, p_branch_id);
  END IF;

  UPDATE public.product_branch_status s SET tracks_batches = p_tracks WHERE s.id = row_id;
END;
$$;

CREATE POLICY product_batch_select ON product_batch FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group())
         AND (SELECT app.has_permission_anywhere('stock.view'))
         AND branch_id = ANY ((SELECT app.allowed_branch_ids())::uuid[]));
CREATE POLICY product_batch_event_select ON product_batch_event FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group())
         AND (SELECT app.has_permission_anywhere('stock.view'))
         AND branch_id = ANY ((SELECT app.allowed_branch_ids())::uuid[]));
CREATE POLICY stock_movement_select ON stock_movement FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group())
         AND (SELECT app.has_permission_anywhere('stock.view'))
         AND branch_id = ANY ((SELECT app.allowed_branch_ids())::uuid[]));
CREATE POLICY stock_balance_select ON stock_balance FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group())
         AND (SELECT app.has_permission_anywhere('stock.view'))
         AND branch_id = ANY ((SELECT app.allowed_branch_ids())::uuid[]));

GRANT SELECT ON product_batch, product_batch_event, stock_movement, stock_balance TO farmaerp_app;

CREATE VIEW v_product_batch WITH (security_invoker = true) AS
  SELECT * FROM product_batch WHERE deleted_at IS NULL;
CREATE VIEW v_product_batch_event WITH (security_invoker = true) AS
  SELECT * FROM product_batch_event WHERE deleted_at IS NULL;
CREATE VIEW v_stock_movement WITH (security_invoker = true) AS
  SELECT * FROM stock_movement WHERE deleted_at IS NULL;
CREATE VIEW v_stock_balance WITH (security_invoker = true) AS
  SELECT * FROM stock_balance WHERE deleted_at IS NULL;

-- Total por produto, somando o que o usuário enxerga.
CREATE VIEW v_stock_network_total WITH (security_invoker = true) AS
  SELECT economic_group_id, product_id, sum(quantity) AS quantity
    FROM stock_balance
   WHERE deleted_at IS NULL
   GROUP BY economic_group_id, product_id;

GRANT SELECT ON v_product_batch, v_product_batch_event, v_stock_movement, v_stock_balance, v_stock_network_total TO farmaerp_app;

-- Saldo por filial e lote, com avisos de validade e de saldo sem lote em produto que exige lote.
-- Roda como quem chama, então a RLS decide o que aparece.
CREATE FUNCTION app.stock_overview(
  p_query text DEFAULT NULL, p_branch_id uuid DEFAULT NULL, p_product_id uuid DEFAULT NULL,
  p_include_zero boolean DEFAULT false, p_limit integer DEFAULT 200
) RETURNS TABLE (
  balance_id uuid, branch_id uuid, branch_name text, product_id uuid, product_code bigint, product_name text,
  batch_id uuid, batch_number text, expires_on date, ms_registration text, ms_original text,
  base_ms text, quantity numeric, is_expired boolean, days_to_expire integer,
  ms_diverges boolean, needs_batch boolean
)
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  WITH input AS (
    SELECT app.search_patterns(p_query) AS patterns, pg_catalog.btrim(COALESCE(p_query, '')) AS raw,
           app.local_today() AS today
  )
  SELECT sb.id, sb.branch_id, b.name, sb.product_id, p.code, p.display_name,
         sb.batch_id, pb.batch_number, pb.expires_on, pb.ms_registration, pb.ms_original,
         cp.ms_registration, sb.quantity,
         COALESCE(pb.expires_on < input.today, false),
         (pb.expires_on - input.today)::integer,
         pb.ms_registration IS DISTINCT FROM cp.ms_registration AND pb.id IS NOT NULL AND cp.ms_registration IS NOT NULL,
         sb.batch_id IS NULL AND sb.quantity <> 0 AND app.batch_required(sb.product_id, sb.branch_id)
    FROM public.stock_balance sb
   CROSS JOIN input
    JOIN public.branch b ON b.id = sb.branch_id
    JOIN public.product p ON p.id = sb.product_id AND p.deleted_at IS NULL
    LEFT JOIN public.catalog_product cp ON cp.id = p.catalog_product_id
    LEFT JOIN public.product_batch pb ON pb.id = sb.batch_id
   WHERE sb.deleted_at IS NULL
     AND (COALESCE(p_include_zero, false) OR sb.quantity <> 0)
     AND (p_branch_id IS NULL OR sb.branch_id = p_branch_id)
     AND (p_product_id IS NULL OR sb.product_id = p_product_id)
     AND (
       input.raw = ''
       OR (p.search_text || ' ' || COALESCE(cp.search_text, '')) LIKE ALL (input.patterns)
       OR p.code::text = input.raw
       OR pg_catalog.upper(COALESCE(pb.batch_number, '')) = pg_catalog.upper(input.raw)
       OR EXISTS (
         SELECT 1 FROM public.product_barcode exact
          WHERE exact.product_id = p.id AND exact.code = input.raw AND exact.deleted_at IS NULL
       )
     )
   ORDER BY p.display_name, b.name, pb.expires_on NULLS FIRST, sb.id
   LIMIT LEAST(GREATEST(COALESCE(p_limit, 200), 1), 500)
$$;

CREATE FUNCTION app.list_stock_movements(
  p_product_id uuid DEFAULT NULL, p_branch_id uuid DEFAULT NULL, p_limit integer DEFAULT 100
) RETURNS TABLE (
  id uuid, branch_name text, product_code bigint, product_name text, batch_number text,
  movement_type text, quantity numeric, reason text, reversal_of uuid, reversed boolean,
  fefo_override boolean, occurred_at timestamptz, author text
)
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT m.id, b.name, p.code, p.display_name, pb.batch_number, m.movement_type, m.quantity, m.reason,
         m.reversal_of,
         -- A exclusão lógica na condição permite usar o índice parcial de reversal_of.
         EXISTS (SELECT 1 FROM public.stock_movement r WHERE r.reversal_of = m.id AND r.deleted_at IS NULL),
         m.fefo_override, m.occurred_at, u.name
    FROM public.stock_movement m
    JOIN public.branch b ON b.id = m.branch_id
    JOIN public.product p ON p.id = m.product_id
    LEFT JOIN public.product_batch pb ON pb.id = m.batch_id
    LEFT JOIN public.user_account u ON u.id = m.updated_by
   WHERE (p_product_id IS NULL OR m.product_id = p_product_id)
     AND (p_branch_id IS NULL OR m.branch_id = p_branch_id)
   ORDER BY m.occurred_at DESC, m.id DESC
   LIMIT LEAST(GREATEST(COALESCE(p_limit, 100), 1), 500)
$$;

-- Controle de lote em cada filial que o usuário enxerga.
CREATE FUNCTION app.batch_tracking_grid(p_product_id uuid)
RETURNS TABLE (branch_id uuid, branch_name text, tracks_batches boolean, is_controlled boolean)
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT s.branch_id, b.name, s.tracks_batches, COALESCE(cp.controlled_class IS NOT NULL, false)
    FROM public.product_branch_status s
    JOIN public.branch b ON b.id = s.branch_id AND b.deleted_at IS NULL
    JOIN public.product p ON p.id = s.product_id
    LEFT JOIN public.catalog_product cp ON cp.id = p.catalog_product_id
   WHERE s.product_id = p_product_id AND s.deleted_at IS NULL
   ORDER BY b.name
$$;

-- Conferência: o saldo precisa ser igual à soma das movimentações. Qualquer linha aqui é defeito.
CREATE FUNCTION app.stock_balance_divergences()
RETURNS TABLE (branch_id uuid, product_id uuid, batch_id uuid, balance numeric, movements numeric)
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT COALESCE(sb.branch_id, totals.branch_id), COALESCE(sb.product_id, totals.product_id),
         COALESCE(sb.batch_id, totals.batch_id), COALESCE(sb.quantity, 0), COALESCE(totals.quantity, 0)
    FROM public.stock_balance sb
    FULL JOIN (
      SELECT m.branch_id, m.product_id, m.batch_id, pg_catalog.sum(m.quantity) AS quantity
        FROM public.stock_movement m
       GROUP BY m.branch_id, m.product_id, m.batch_id
    ) AS totals
      ON totals.branch_id = sb.branch_id AND totals.product_id = sb.product_id
     AND totals.batch_id IS NOT DISTINCT FROM sb.batch_id
   WHERE COALESCE(sb.quantity, 0) <> COALESCE(totals.quantity, 0)
$$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  app.local_today(),
  app.batch_required(uuid, uuid),
  app.adjust_stock(jsonb),
  app.register_stock_loss(jsonb),
  app.reverse_stock_movement(uuid, text),
  app.update_product_batch(uuid, jsonb),
  app.set_batch_tracking(uuid, uuid, boolean),
  app.stock_overview(text, uuid, uuid, boolean, integer),
  app.list_stock_movements(uuid, uuid, integer),
  app.batch_tracking_grid(uuid),
  app.stock_balance_divergences()
TO farmaerp_app;
