-- Up Migration

-- Lançamento da nota de compra: estoque, lotes, custo médio, PMC e a trava de custo. Tudo acontece
-- numa transação só: a nota entra inteira ou não entra. O estorno faz o caminho inverso e devolve a
-- nota para a conferência.

INSERT INTO permission (code, module, name) VALUES
  ('purchases.post', 'Compras', 'Lançar e estornar notas de compra no estoque'),
  ('purchases.cost_override', 'Compras', 'Liberar custo acima da tolerância na nota de compra');

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

  -- A liberação do custo fica só com o Administrador; dá para estender em /perfis.
  INSERT INTO public.role_permission (role_id, permission_id)
  SELECT manager_id, p.id
    FROM public.permission p
   WHERE p.code IN (
     'users.view', 'users.reset_password', 'terminals.view', 'terminals.request', 'terminals.block',
     'products.view', 'stock.view', 'stock.loss', 'stock.transfer', 'stock.batch_override',
     'customers.view', 'customers.manage', 'fiscal.certificate', 'purchases.view', 'purchases.manage',
     'purchases.post'
   );
END;
$$;

-- Grupos que já existem: o Gerente, identificado pelo nome, passa a lançar a nota da loja.
INSERT INTO role_permission (role_id, permission_id)
SELECT r.id, p.id
  FROM role r
 CROSS JOIN permission p
 WHERE r.name = 'Gerente' AND r.deleted_at IS NULL AND p.code = 'purchases.post'
   AND NOT EXISTS (
     SELECT 1 FROM role_permission rp WHERE rp.role_id = r.id AND rp.permission_id = p.id AND rp.deleted_at IS NULL
   );

-- Lançada é a nota que está no estoque. O estorno devolve para a conferência.
ALTER TABLE purchase_invoice DROP CONSTRAINT purchase_invoice_status_check;
ALTER TABLE purchase_invoice ADD CONSTRAINT purchase_invoice_status_check CHECK (status IN ('review', 'not_postable', 'posted'));

-- Lote digitado na conferência: o do XML continua guardado, só sai de uso.
ALTER TABLE purchase_invoice_item_batch
  ADD COLUMN source text NOT NULL DEFAULT 'xml' CONSTRAINT purchase_invoice_item_batch_source_check CHECK (source IN ('xml', 'manual'));
DROP TRIGGER block_immutable_columns ON purchase_invoice_item_batch;
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON purchase_invoice_item_batch
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'branch_id', 'item_id', 'batch_number', 'quantity', 'manufactured_on', 'expires_on', 'source'
  );

-- Cada entrada da nota aponta o item que a gerou; o estorno também.
ALTER TABLE stock_movement
  ADD COLUMN purchase_invoice_item_id uuid REFERENCES purchase_invoice_item (id),
  ADD CONSTRAINT stock_movement_invoice_item_check CHECK (purchase_invoice_item_id IS NULL OR movement_type = 'invoice');
CREATE INDEX stock_movement_invoice_item_idx ON stock_movement (purchase_invoice_item_id) WHERE purchase_invoice_item_id IS NOT NULL;

-- Histórico do custo médio por produto e filial: só inclusão, a última linha vale. Guarda a conta
-- inteira (saldo antes, entrada e custo dela) para o estorno refazer pela conta inversa.
CREATE TABLE product_cost (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  branch_id uuid NOT NULL REFERENCES branch (id),
  product_id uuid NOT NULL REFERENCES product (id),
  -- Vazio só no estorno da primeira entrada: o produto volta a não ter custo.
  average_cost numeric(19, 6) CONSTRAINT product_cost_average_cost_check CHECK (average_cost >= 0),
  previous_cost numeric(19, 6) CONSTRAINT product_cost_previous_cost_check CHECK (previous_cost >= 0),
  stock_before numeric(14, 3) NOT NULL,
  -- Negativa no estorno.
  entry_quantity numeric(14, 3) NOT NULL CONSTRAINT product_cost_entry_quantity_check CHECK (entry_quantity <> 0),
  entry_cost numeric(19, 6) NOT NULL CONSTRAINT product_cost_entry_cost_check CHECK (entry_cost >= 0),
  purchase_invoice_item_id uuid NOT NULL REFERENCES purchase_invoice_item (id),
  reversal_of uuid REFERENCES product_cost (id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid,
  CONSTRAINT product_cost_reversal_check CHECK (
    (reversal_of IS NULL) = (entry_quantity > 0) AND (average_cost IS NOT NULL OR reversal_of IS NOT NULL)
  )
);
CREATE INDEX product_cost_lookup_idx ON product_cost (product_id, branch_id, created_at DESC, id DESC);
CREATE INDEX product_cost_branch_id_idx ON product_cost (branch_id);
CREATE INDEX product_cost_item_idx ON product_cost (purchase_invoice_item_id);
CREATE UNIQUE INDEX product_cost_reversal_active_key ON product_cost (reversal_of) WHERE reversal_of IS NOT NULL AND deleted_at IS NULL;
CALL app.apply_table_standard('public.product_cost');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON product_cost
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'branch_id', 'product_id', 'average_cost', 'previous_cost', 'stock_before', 'entry_quantity',
    'entry_cost', 'purchase_invoice_item_id', 'reversal_of', 'deleted_at'
  );

-- Liberação do custo acima da tolerância: vale só para o produto e o custo daquela hora.
CREATE TABLE purchase_invoice_item_cost_release (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  branch_id uuid NOT NULL REFERENCES branch (id),
  item_id uuid NOT NULL REFERENCES purchase_invoice_item (id),
  product_id uuid NOT NULL REFERENCES product (id),
  entry_cost numeric(19, 6) NOT NULL,
  average_cost numeric(19, 6) NOT NULL,
  tolerance numeric(12, 4) NOT NULL,
  reason text NOT NULL CONSTRAINT purchase_invoice_item_cost_release_reason_check CHECK (btrim(reason) <> '' AND length(reason) <= 500),
  released_by uuid NOT NULL REFERENCES user_account (id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE UNIQUE INDEX purchase_invoice_item_cost_release_active_key
  ON purchase_invoice_item_cost_release (item_id) WHERE deleted_at IS NULL;
CREATE INDEX purchase_invoice_item_cost_release_branch_id_idx ON purchase_invoice_item_cost_release (branch_id);
CALL app.apply_table_standard('public.purchase_invoice_item_cost_release');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON purchase_invoice_item_cost_release
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'branch_id', 'item_id', 'product_id', 'entry_cost', 'average_cost', 'tolerance', 'reason', 'released_by'
  );

-- Quem lançou e quem estornou, quando e por quê.
CREATE TABLE purchase_invoice_event (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  branch_id uuid NOT NULL REFERENCES branch (id),
  invoice_id uuid NOT NULL REFERENCES purchase_invoice (id),
  kind text NOT NULL CONSTRAINT purchase_invoice_event_kind_check CHECK (kind IN ('posted', 'reversed')),
  reason text CONSTRAINT purchase_invoice_event_reason_check CHECK (btrim(reason) <> '' AND length(reason) <= 500),
  user_id uuid NOT NULL REFERENCES user_account (id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid,
  CONSTRAINT purchase_invoice_event_kind_reason_check CHECK ((kind = 'reversed') = (reason IS NOT NULL))
);
CREATE INDEX purchase_invoice_event_invoice_idx ON purchase_invoice_event (invoice_id, created_at DESC, id DESC);
CREATE INDEX purchase_invoice_event_branch_id_idx ON purchase_invoice_event (branch_id);
CALL app.apply_table_standard('public.purchase_invoice_event');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON purchase_invoice_event
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'branch_id', 'invoice_id', 'kind', 'reason', 'user_id', 'deleted_at'
  );

-- Custo médio em vigor. Vazio quando o produto ainda não teve entrada na filial.
CREATE FUNCTION app.average_cost(p_product_id uuid, p_branch_id uuid) RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT c.average_cost FROM public.product_cost c
   WHERE c.product_id = p_product_id AND c.branch_id = p_branch_id AND c.deleted_at IS NULL
   ORDER BY c.created_at DESC, c.id DESC
   LIMIT 1
$$;

-- Saldo da filial somando todos os lotes.
CREATE FUNCTION app.branch_stock_quantity(p_product_id uuid, p_branch_id uuid) RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE(pg_catalog.sum(sb.quantity), 0) FROM public.stock_balance sb
   WHERE sb.product_id = p_product_id AND sb.branch_id = p_branch_id AND sb.deleted_at IS NULL
$$;

-- A situação de um item para o lançamento. A tela e o lançamento usam esta mesma conta.
-- Custo: (produtos − desconto + frete + seguro + outras + IPI + ST + FCP-ST) ÷ quantidade no estoque.
-- Situação do custo: first_entry (sem custo anterior), no_rule (sem tolerância cadastrada), ok,
-- locked (acima da tolerância) ou released. Lotes: not_required, missing, mismatch, expired ou ok.
CREATE FUNCTION app.purchase_item_check(
  p_item_id uuid,
  OUT out_fraction numeric, OUT out_stock_quantity numeric, OUT out_unit_cost numeric, OUT out_average_cost numeric,
  OUT out_tolerance numeric, OUT out_cost_status text, OUT out_batch_status text, OUT out_batch_required boolean
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  item public.purchase_invoice_item;
  batch_count integer;
  batch_total numeric;
BEGIN
  SELECT * INTO item FROM public.purchase_invoice_item it WHERE it.id = p_item_id;
  IF item.product_id IS NULL THEN
    out_cost_status := 'no_product';
    out_batch_status := 'no_product';
    RETURN;
  END IF;
  out_fraction := app.effective_fraction(item.product_id, item.barcode_id, item.product_supplier_id);
  out_stock_quantity := pg_catalog.round(item.quantity * out_fraction, 3);
  IF out_stock_quantity > 0 THEN
    out_unit_cost := pg_catalog.round(
      (item.products_value - item.discount_value + item.freight_value + item.insurance_value + item.other_value
       + item.ipi_value + item.st_value + item.fcp_st_value) / out_stock_quantity, 6);
    -- Desconto maior que os valores não vira custo negativo.
    out_unit_cost := GREATEST(out_unit_cost, 0.000000);
  END IF;
  out_average_cost := app.average_cost(item.product_id, item.branch_id);
  SELECT r.value INTO out_tolerance FROM app.resolve_product_rule('cost_tolerance', item.product_id, item.branch_id) AS r;

  out_cost_status := CASE
    WHEN out_unit_cost IS NULL THEN 'invalid'
    WHEN out_average_cost IS NULL THEN 'first_entry'
    WHEN out_tolerance IS NULL THEN 'no_rule'
    WHEN out_unit_cost <= out_average_cost * (1 + out_tolerance / 100) THEN 'ok'
    WHEN EXISTS (
      SELECT 1 FROM public.purchase_invoice_item_cost_release cr
       WHERE cr.item_id = item.id AND cr.product_id = item.product_id AND cr.entry_cost = out_unit_cost
         AND cr.deleted_at IS NULL
    ) THEN 'released'
    ELSE 'locked'
  END;

  out_batch_required := app.batch_required(item.product_id, item.branch_id);
  IF NOT out_batch_required THEN
    out_batch_status := 'not_required';
    RETURN;
  END IF;
  SELECT pg_catalog.count(*), pg_catalog.sum(b.quantity) INTO batch_count, batch_total
    FROM public.purchase_invoice_item_batch b
   WHERE b.item_id = item.id AND b.deleted_at IS NULL;
  out_batch_status := CASE
    WHEN batch_count = 0 THEN 'missing'
    WHEN batch_total <> item.quantity THEN 'mismatch'
    WHEN EXISTS (
      SELECT 1 FROM public.purchase_invoice_item_batch b
       WHERE b.item_id = item.id AND b.deleted_at IS NULL AND b.expires_on < app.local_today()
    ) THEN 'expired'
    ELSE 'ok'
  END;
END;
$$;

-- Nota do grupo do usuário, travada para a operação.
CREATE FUNCTION app.lock_purchase_invoice(p_invoice_id uuid) RETURNS public.purchase_invoice
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.purchase_invoice;
BEGIN
  SELECT * INTO target FROM public.purchase_invoice i
   WHERE i.id = p_invoice_id AND i.economic_group_id = app.current_user_group() AND i.deleted_at IS NULL
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('purchase_invoice %s.', p_invoice_id);
  END IF;
  RETURN target;
END;
$$;

CREATE FUNCTION app.require_purchase_permission(p_code text, p_branch_id uuid) RETURNS void
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

-- Item do grupo do usuário.
CREATE FUNCTION app.find_purchase_item(p_item_id uuid) RETURNS public.purchase_invoice_item
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  item public.purchase_invoice_item;
BEGIN
  SELECT * INTO item FROM public.purchase_invoice_item it
   WHERE it.id = p_item_id AND it.economic_group_id = app.current_user_group() AND it.deleted_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('purchase_invoice_item %s.', p_item_id);
  END IF;
  RETURN item;
END;
$$;

-- Lotes digitados na conferência, na unidade da nota. Trocam todos os lotes em uso do item; os do
-- XML ficam guardados. A soma é conferida no lançamento, para dar para salvar aos poucos.
CREATE FUNCTION app.set_purchase_item_batches(p_item_id uuid, p_batches jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  item public.purchase_invoice_item := app.find_purchase_item(p_item_id);
  entry jsonb;
  clean_number text;
  seen text[] := '{}';
  batch_quantity numeric;
  expires date;
  manufactured date;
BEGIN
  PERFORM app.invoice_for_review(item.invoice_id);
  IF p_batches IS NULL OR pg_catalog.jsonb_typeof(p_batches) <> 'array' OR pg_catalog.jsonb_array_length(p_batches) > 50 THEN
    RAISE EXCEPTION 'Os lotes do item estão incompletos ou inválidos.'
      USING ERRCODE = 'FA936', DETAIL = 'Lista de lotes ausente ou com mais de 50 linhas.';
  END IF;

  UPDATE public.purchase_invoice_item_batch SET deleted_at = pg_catalog.clock_timestamp()
   WHERE item_id = item.id AND deleted_at IS NULL;

  FOR entry IN SELECT value FROM pg_catalog.jsonb_array_elements(p_batches) AS value LOOP
    clean_number := pg_catalog.upper(COALESCE(app.clean_text(entry ->> 'number'), ''));
    BEGIN
      batch_quantity := (entry ->> 'quantity')::numeric;
      expires := (entry ->> 'expiresOn')::date;
      manufactured := (entry ->> 'manufacturedOn')::date;
    EXCEPTION WHEN invalid_text_representation OR invalid_datetime_format OR datetime_field_overflow THEN
      RAISE EXCEPTION 'Os lotes do item estão incompletos ou inválidos.'
        USING ERRCODE = 'FA936', DETAIL = 'Quantidade ou data em formato inválido.';
    END;
    IF clean_number = '' OR pg_catalog.length(clean_number) > 20 OR clean_number = ANY (seen)
       OR batch_quantity IS NULL OR batch_quantity <= 0 OR batch_quantity >= 100000000000
       OR expires IS NULL OR (manufactured IS NOT NULL AND manufactured > expires) THEN
      RAISE EXCEPTION 'Os lotes do item estão incompletos ou inválidos.'
        USING ERRCODE = 'FA936', DETAIL = pg_catalog.format('Item %s, lote %s.', item.id, clean_number);
    END IF;
    seen := seen || clean_number;
    INSERT INTO public.purchase_invoice_item_batch (
      economic_group_id, branch_id, item_id, batch_number, quantity, manufactured_on, expires_on, source
    ) VALUES (item.economic_group_id, item.branch_id, item.id, clean_number, batch_quantity, manufactured, expires, 'manual');
  END LOOP;
END;
$$;

-- Libera o custo acima da tolerância. A API confere a senha antes de chamar.
CREATE FUNCTION app.release_purchase_item_cost(p_item_id uuid, p_reason text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  item public.purchase_invoice_item := app.find_purchase_item(p_item_id);
  invoice public.purchase_invoice;
  clean_reason text := app.require_reason(p_reason);
  checked record;
BEGIN
  invoice := app.lock_purchase_invoice(item.invoice_id);
  PERFORM app.require_purchase_permission('purchases.cost_override', invoice.branch_id);
  IF invoice.status <> 'review' THEN
    RAISE EXCEPTION 'Esta nota não pode mais ser conferida.'
      USING ERRCODE = 'FA932', DETAIL = pg_catalog.format('purchase_invoice %s em %s.', invoice.id, invoice.status);
  END IF;
  SELECT * INTO checked FROM app.purchase_item_check(item.id);
  IF checked.out_cost_status <> 'locked' THEN
    RAISE EXCEPTION 'O custo deste item não precisa de liberação.'
      USING ERRCODE = 'FA941', DETAIL = pg_catalog.format('Item %s em %s.', item.id, checked.out_cost_status);
  END IF;
  -- Uma liberação antiga, de outro produto ou custo, sai de uso.
  UPDATE public.purchase_invoice_item_cost_release SET deleted_at = pg_catalog.clock_timestamp()
   WHERE item_id = item.id AND deleted_at IS NULL;
  INSERT INTO public.purchase_invoice_item_cost_release (
    economic_group_id, branch_id, item_id, product_id, entry_cost, average_cost, tolerance, reason, released_by
  ) VALUES (
    item.economic_group_id, item.branch_id, item.id, item.product_id, checked.out_unit_cost, checked.out_average_cost,
    checked.out_tolerance, clean_reason, app.current_user_id()
  );
END;
$$;

-- Duas notas do mesmo produto e filial ao mesmo tempo esperam uma pela outra: o custo médio
-- depende do saldo e do custo anterior.
CREATE FUNCTION app.lock_product_cost(p_product_id uuid, p_branch_id uuid) RETURNS void
LANGUAGE sql
SET search_path = ''
AS $$
  SELECT pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('product_cost:' || p_product_id || ':' || p_branch_id, 0))
$$;

-- Lança a nota inteira: estoque por lote, custo médio e PMC.
CREATE FUNCTION app.post_purchase_invoice(p_invoice_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.purchase_invoice := app.lock_purchase_invoice(p_invoice_id);
  branch_row public.branch;
  item public.purchase_invoice_item;
  checked record;
  batch public.purchase_invoice_item_batch;
  stock_before numeric;
  new_average numeric;
  movement_reason text;
  remaining numeric;
  batches_left integer;
  batch_quantity numeric;
  stock_batch_id uuid;
  batch_ms text;
BEGIN
  PERFORM app.require_purchase_permission('purchases.post', target.branch_id);
  IF target.status <> 'review' THEN
    RAISE EXCEPTION 'Esta nota não pode ser lançada.'
      USING ERRCODE = 'FA938', DETAIL = pg_catalog.format('purchase_invoice %s em %s.', target.id, target.status);
  END IF;
  SELECT * INTO branch_row FROM public.branch b WHERE b.id = target.branch_id;
  movement_reason := pg_catalog.format('Nota %s série %s de %s', target.number, target.series, target.emitter_name);

  FOR item IN
    SELECT * FROM public.purchase_invoice_item it
     WHERE it.invoice_id = target.id AND it.deleted_at IS NULL
     ORDER BY it.item_number
  LOOP
    IF item.product_id IS NULL THEN
      RAISE EXCEPTION 'Há itens da nota sem produto ligado.'
        USING ERRCODE = 'FA934', DETAIL = pg_catalog.format('Item %s da nota %s.', item.item_number, target.id);
    END IF;
    PERFORM app.lock_product_cost(item.product_id, target.branch_id);
    SELECT * INTO checked FROM app.purchase_item_check(item.id);
    IF checked.out_cost_status = 'invalid' THEN
      RAISE EXCEPTION 'Os dados da nota são inválidos.'
        USING ERRCODE = 'FA931', DETAIL = pg_catalog.format('Item %s sem quantidade no estoque.', item.item_number);
    ELSIF checked.out_cost_status = 'locked' THEN
      RAISE EXCEPTION 'O custo de um item passou da tolerância e precisa ser liberado.'
        USING ERRCODE = 'FA935', DETAIL = pg_catalog.format('Item %s da nota %s.', item.item_number, target.id);
    ELSIF checked.out_batch_status IN ('missing', 'mismatch') THEN
      RAISE EXCEPTION 'Os lotes do item estão incompletos ou inválidos.'
        USING ERRCODE = 'FA936', DETAIL = pg_catalog.format('Item %s em %s.', item.item_number, checked.out_batch_status);
    ELSIF checked.out_batch_status = 'expired' THEN
      RAISE EXCEPTION 'Um lote da nota já está vencido.'
        USING ERRCODE = 'FA937', DETAIL = pg_catalog.format('Item %s da nota %s.', item.item_number, target.id);
    END IF;

    -- Custo médio: média móvel sobre o saldo da filial. Sem custo ou sem saldo, vale o da entrada.
    stock_before := app.branch_stock_quantity(item.product_id, target.branch_id);
    new_average := CASE
      WHEN checked.out_average_cost IS NULL OR stock_before <= 0 THEN checked.out_unit_cost
      ELSE pg_catalog.round(
        (stock_before * checked.out_average_cost + checked.out_stock_quantity * checked.out_unit_cost)
        / (stock_before + checked.out_stock_quantity), 6)
    END;
    INSERT INTO public.product_cost (
      economic_group_id, branch_id, product_id, average_cost, previous_cost, stock_before, entry_quantity, entry_cost,
      purchase_invoice_item_id
    ) VALUES (
      target.economic_group_id, target.branch_id, item.product_id, new_average, checked.out_average_cost, stock_before,
      checked.out_stock_quantity, checked.out_unit_cost, item.id
    );

    IF checked.out_batch_required THEN
      -- Cada lote na unidade do estoque; o último fica com a sobra do arredondamento.
      remaining := checked.out_stock_quantity;
      SELECT pg_catalog.count(*) INTO batches_left FROM public.purchase_invoice_item_batch b
       WHERE b.item_id = item.id AND b.deleted_at IS NULL;
      FOR batch IN
        SELECT * FROM public.purchase_invoice_item_batch b
         WHERE b.item_id = item.id AND b.deleted_at IS NULL
         ORDER BY b.expires_on, b.batch_number, b.id
      LOOP
        batches_left := batches_left - 1;
        batch_quantity := CASE WHEN batches_left = 0 THEN remaining
                               ELSE pg_catalog.round(batch.quantity * checked.out_fraction, 3) END;
        remaining := remaining - batch_quantity;
        -- O MS da nota só vale para lote novo: um lote que já existe fica com o MS que tem.
        batch_ms := CASE WHEN item.anvisa_code ~ '^[0-9]{13}$' THEN item.anvisa_code END;
        IF EXISTS (
          SELECT 1 FROM public.product_batch pb
           WHERE pb.branch_id = target.branch_id AND pb.product_id = item.product_id
             AND pg_catalog.upper(pb.batch_number) = batch.batch_number AND pb.deleted_at IS NULL
        ) THEN
          batch_ms := NULL;
        END IF;
        stock_batch_id := app.batch_for_entry(
          target.economic_group_id, target.branch_id, item.product_id, batch.batch_number, batch.expires_on, batch_ms
        );
        INSERT INTO public.stock_movement (
          economic_group_id, branch_id, product_id, batch_id, movement_type, quantity, reason, purchase_invoice_item_id
        ) VALUES (
          target.economic_group_id, target.branch_id, item.product_id, stock_batch_id, 'invoice', batch_quantity,
          movement_reason, item.id
        );
      END LOOP;
    ELSE
      INSERT INTO public.stock_movement (
        economic_group_id, branch_id, product_id, movement_type, quantity, reason, purchase_invoice_item_id
      ) VALUES (
        target.economic_group_id, target.branch_id, item.product_id, 'invoice', checked.out_stock_quantity,
        movement_reason, item.id
      );
    END IF;

    -- PMC da nota para o estado e a região da filial. Igual ao vigente não gera linha.
    IF item.pmc > 0 AND branch_row.state IS NOT NULL
       AND item.pmc IS DISTINCT FROM app.effective_pmc(item.product_id, branch_row.state, branch_row.pmc_region) THEN
      INSERT INTO public.product_pmc (economic_group_id, product_id, state, pmc_region, value, source)
      VALUES (target.economic_group_id, item.product_id, branch_row.state, branch_row.pmc_region, item.pmc, 'invoice');
    END IF;
  END LOOP;

  UPDATE public.purchase_invoice SET status = 'posted' WHERE id = target.id;
  INSERT INTO public.purchase_invoice_event (economic_group_id, branch_id, invoice_id, kind, user_id)
  VALUES (target.economic_group_id, target.branch_id, target.id, 'posted', app.current_user_id());
END;
$$;

-- Estorno: movimentações contrárias e o custo médio pela conta inversa. Se parte do que entrou já
-- saiu, o saldo não cobre e o banco recusa. A nota volta para a conferência e as liberações de
-- custo precisam ser feitas de novo. O PMC gravado fica: é o valor que o fornecedor informou.
CREATE FUNCTION app.reverse_purchase_invoice(p_invoice_id uuid, p_reason text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.purchase_invoice := app.lock_purchase_invoice(p_invoice_id);
  clean_reason text := app.require_reason(p_reason);
  item public.purchase_invoice_item;
  movement public.stock_movement;
  entry public.product_cost;
  current_average numeric;
  stock_after numeric;
  restored numeric;
BEGIN
  PERFORM app.require_purchase_permission('purchases.post', target.branch_id);
  IF target.status <> 'posted' THEN
    RAISE EXCEPTION 'Esta nota não está lançada.'
      USING ERRCODE = 'FA939', DETAIL = pg_catalog.format('purchase_invoice %s em %s.', target.id, target.status);
  END IF;

  FOR item IN
    SELECT * FROM public.purchase_invoice_item it
     WHERE it.invoice_id = target.id AND it.deleted_at IS NULL
     ORDER BY it.item_number DESC
  LOOP
    SELECT * INTO entry FROM public.product_cost c
     WHERE c.purchase_invoice_item_id = item.id AND c.reversal_of IS NULL AND c.deleted_at IS NULL
       AND NOT EXISTS (SELECT 1 FROM public.product_cost r WHERE r.reversal_of = c.id AND r.deleted_at IS NULL)
     ORDER BY c.id DESC
     LIMIT 1;
    CONTINUE WHEN NOT FOUND;
    PERFORM app.lock_product_cost(entry.product_id, target.branch_id);

    FOR movement IN
      SELECT * FROM public.stock_movement m
       WHERE m.purchase_invoice_item_id = item.id AND m.reversal_of IS NULL AND m.deleted_at IS NULL
         AND NOT EXISTS (SELECT 1 FROM public.stock_movement r WHERE r.reversal_of = m.id AND r.deleted_at IS NULL)
       ORDER BY m.id
    LOOP
      INSERT INTO public.stock_movement (
        economic_group_id, branch_id, product_id, batch_id, movement_type, quantity, reason, reversal_of,
        purchase_invoice_item_id
      ) VALUES (
        movement.economic_group_id, movement.branch_id, movement.product_id, movement.batch_id, 'invoice',
        -movement.quantity, clean_reason, movement.id, item.id
      );
    END LOOP;

    -- Conta inversa da média. Sem saldo depois do estorno, ou com a conta dando negativa, volta o
    -- custo de antes da entrada.
    current_average := app.average_cost(entry.product_id, target.branch_id);
    stock_after := app.branch_stock_quantity(entry.product_id, target.branch_id);
    restored := CASE
      WHEN stock_after <= 0 OR current_average IS NULL THEN entry.previous_cost
      ELSE pg_catalog.round(
        ((stock_after + entry.entry_quantity) * current_average - entry.entry_quantity * entry.entry_cost) / stock_after, 6)
    END;
    IF restored < 0 THEN
      restored := entry.previous_cost;
    END IF;
    INSERT INTO public.product_cost (
      economic_group_id, branch_id, product_id, average_cost, previous_cost, stock_before, entry_quantity, entry_cost,
      purchase_invoice_item_id, reversal_of
    ) VALUES (
      target.economic_group_id, target.branch_id, entry.product_id, restored, current_average,
      stock_after + entry.entry_quantity, -entry.entry_quantity, entry.entry_cost, item.id, entry.id
    );
  END LOOP;

  UPDATE public.purchase_invoice_item_cost_release cr SET deleted_at = pg_catalog.clock_timestamp()
    FROM public.purchase_invoice_item it
   WHERE it.id = cr.item_id AND it.invoice_id = target.id AND cr.deleted_at IS NULL;
  UPDATE public.purchase_invoice SET status = 'review' WHERE id = target.id;
  INSERT INTO public.purchase_invoice_event (economic_group_id, branch_id, invoice_id, kind, reason, user_id)
  VALUES (target.economic_group_id, target.branch_id, target.id, 'reversed', clean_reason, app.current_user_id());
END;
$$;

-- Nota lançada não se descarta: o estoque dela precisa sair antes, pelo estorno.
CREATE OR REPLACE FUNCTION app.discard_purchase_invoice(p_invoice_id uuid, p_reason text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.purchase_invoice;
  clean_reason text := app.require_reason(p_reason);
BEGIN
  target := app.lock_purchase_invoice(p_invoice_id);
  PERFORM app.require_invoice_branch(target.branch_id);
  IF target.status = 'posted' THEN
    RAISE EXCEPTION 'Nota lançada não pode ser descartada.'
      USING ERRCODE = 'FA940', DETAIL = pg_catalog.format('purchase_invoice %s.', target.id);
  END IF;
  UPDATE public.purchase_invoice SET deleted_at = pg_catalog.clock_timestamp(), discard_reason = clean_reason
   WHERE id = target.id;
END;
$$;

-- Situação de cada item para o lançamento. Na nota lançada, mostra o que entrou: custo da entrada,
-- médio de antes e médio de depois.
CREATE FUNCTION app.purchase_invoice_posting(p_invoice_id uuid)
RETURNS TABLE (
  item_id uuid, fraction numeric, stock_quantity numeric, unit_cost numeric, average_cost numeric, new_average_cost numeric,
  tolerance numeric, difference_percent numeric, cost_status text, batch_status text, batch_required boolean,
  release jsonb
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.purchase_invoice;
  item public.purchase_invoice_item;
  checked record;
  entry public.product_cost;
BEGIN
  SELECT * INTO target FROM public.purchase_invoice i
   WHERE i.id = p_invoice_id AND i.economic_group_id = app.current_user_group() AND i.deleted_at IS NULL;
  IF NOT FOUND OR NOT (app.has_permission('purchases.view', target.branch_id) OR app.has_permission('purchases.manage', target.branch_id)) THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('purchase_invoice %s.', p_invoice_id);
  END IF;

  FOR item IN
    SELECT * FROM public.purchase_invoice_item it
     WHERE it.invoice_id = target.id AND it.deleted_at IS NULL
     ORDER BY it.item_number
  LOOP
    SELECT * INTO checked FROM app.purchase_item_check(item.id);
    item_id := item.id;
    fraction := checked.out_fraction;
    stock_quantity := checked.out_stock_quantity;
    tolerance := checked.out_tolerance;
    batch_status := checked.out_batch_status;
    batch_required := checked.out_batch_required;
    release := NULL;
    IF target.status = 'posted' THEN
      SELECT * INTO entry FROM public.product_cost c
       WHERE c.purchase_invoice_item_id = item.id AND c.reversal_of IS NULL AND c.deleted_at IS NULL
       ORDER BY c.id DESC LIMIT 1;
      unit_cost := entry.entry_cost;
      average_cost := entry.previous_cost;
      new_average_cost := entry.average_cost;
      stock_quantity := entry.entry_quantity;
      cost_status := 'posted';
    ELSE
      unit_cost := checked.out_unit_cost;
      average_cost := checked.out_average_cost;
      new_average_cost := NULL;
      cost_status := checked.out_cost_status;
    END IF;
    difference_percent := CASE WHEN average_cost > 0 AND unit_cost IS NOT NULL
                               THEN pg_catalog.round((unit_cost / average_cost - 1) * 100, 2) END;
    SELECT pg_catalog.jsonb_build_object(
             'reason', cr.reason, 'releasedBy', u.name, 'releasedAt', cr.created_at, 'entryCost', cr.entry_cost,
             'averageCost', cr.average_cost, 'tolerance', cr.tolerance)
      INTO release
      FROM public.purchase_invoice_item_cost_release cr
      JOIN public.user_account u ON u.id = cr.released_by
     WHERE cr.item_id = item.id AND cr.deleted_at IS NULL;
    RETURN NEXT;
  END LOOP;
END;
$$;

-- Custo médio do produto nas filiais em que o usuário vê compras.
CREATE FUNCTION app.product_average_costs(p_product_id uuid)
RETURNS TABLE (branch_id uuid, branch_name text, average_cost numeric, stock_quantity numeric, updated_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT b.id, b.name, latest.average_cost, app.branch_stock_quantity(p_product_id, b.id), latest.created_at
    FROM public.branch b
    JOIN public.company c ON c.id = b.company_id AND c.economic_group_id = app.current_user_group()
    JOIN LATERAL (
      SELECT pc.average_cost, pc.created_at FROM public.product_cost pc
       WHERE pc.product_id = p_product_id AND pc.branch_id = b.id AND pc.deleted_at IS NULL
       ORDER BY pc.created_at DESC, pc.id DESC
       LIMIT 1
    ) AS latest ON true
   WHERE b.deleted_at IS NULL
     AND (app.has_permission('purchases.view', b.id) OR app.has_permission('purchases.manage', b.id))
   ORDER BY b.name
$$;

-- Quem vê compras na filial vê o custo e o histórico da nota.
CREATE POLICY product_cost_select ON product_cost FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group())
         AND (app.has_permission('purchases.view', branch_id) OR app.has_permission('purchases.manage', branch_id)));
CREATE POLICY purchase_invoice_item_cost_release_select ON purchase_invoice_item_cost_release FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group())
         AND (app.has_permission('purchases.view', branch_id) OR app.has_permission('purchases.manage', branch_id)));
CREATE POLICY purchase_invoice_event_select ON purchase_invoice_event FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group())
         AND (app.has_permission('purchases.view', branch_id) OR app.has_permission('purchases.manage', branch_id)));
GRANT SELECT ON product_cost, purchase_invoice_item_cost_release, purchase_invoice_event TO farmaerp_app;

CREATE VIEW v_product_cost WITH (security_invoker = true) AS
  SELECT * FROM product_cost WHERE deleted_at IS NULL;
CREATE VIEW v_purchase_invoice_item_cost_release WITH (security_invoker = true) AS
  SELECT * FROM purchase_invoice_item_cost_release WHERE deleted_at IS NULL;
CREATE VIEW v_purchase_invoice_event WITH (security_invoker = true) AS
  SELECT * FROM purchase_invoice_event WHERE deleted_at IS NULL;
GRANT SELECT ON v_product_cost, v_purchase_invoice_item_cost_release, v_purchase_invoice_event TO farmaerp_app;

-- As views com SELECT * congelam as colunas: recria para mostrar as novas.
CREATE OR REPLACE VIEW v_stock_movement WITH (security_invoker = true) AS
  SELECT * FROM stock_movement WHERE deleted_at IS NULL;
CREATE OR REPLACE VIEW v_purchase_invoice_item_batch WITH (security_invoker = true) AS
  SELECT * FROM purchase_invoice_item_batch WHERE deleted_at IS NULL;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  app.set_purchase_item_batches(uuid, jsonb),
  app.release_purchase_item_cost(uuid, text),
  app.post_purchase_invoice(uuid),
  app.reverse_purchase_invoice(uuid, text),
  app.purchase_invoice_posting(uuid),
  app.product_average_costs(uuid)
TO farmaerp_app;
