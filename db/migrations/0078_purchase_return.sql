-- Up Migration

-- Devolução ao fornecedor: por item e quantidade (na unidade do produto), parcial e quantas vezes
-- precisar, até o que entrou. Espelho da nota: cada item volta com o mesmo preço e com desconto,
-- frete, seguro, outras despesas, IPI, ST e FCP-ST na proporção da quantidade. O estoque sai do lote
-- escolhido, pelo custo da própria entrada, e o custo médio é refeito pela conta inversa. Saída que
-- deixa o estoque negativo só para quem tem a permissão. Nota com devolução não se cancela, não se
-- estorna e não tem o fracionamento alterado (o que já saiu sairia de novo).

INSERT INTO permission (code, module, name) VALUES ('purchases.return', 'Compras', 'Devolver ao fornecedor');

CREATE TABLE purchase_return (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  branch_id uuid NOT NULL REFERENCES branch (id),
  invoice_id uuid NOT NULL REFERENCES purchase_invoice (id),
  -- Sequência da nota: 1ª, 2ª devolução...
  number smallint NOT NULL CONSTRAINT purchase_return_number_check CHECK (number BETWEEN 1 AND 999),
  reason text NOT NULL CONSTRAINT purchase_return_reason_check CHECK (btrim(reason) <> '' AND length(reason) <= 500),
  products_value numeric(15, 2) NOT NULL CONSTRAINT purchase_return_products_value_check CHECK (products_value >= 0),
  discount_value numeric(15, 2) NOT NULL CONSTRAINT purchase_return_discount_value_check CHECK (discount_value >= 0),
  freight_value numeric(15, 2) NOT NULL CONSTRAINT purchase_return_freight_value_check CHECK (freight_value >= 0),
  insurance_value numeric(15, 2) NOT NULL CONSTRAINT purchase_return_insurance_value_check CHECK (insurance_value >= 0),
  other_value numeric(15, 2) NOT NULL CONSTRAINT purchase_return_other_value_check CHECK (other_value >= 0),
  ipi_value numeric(15, 2) NOT NULL CONSTRAINT purchase_return_ipi_value_check CHECK (ipi_value >= 0),
  st_value numeric(15, 2) NOT NULL CONSTRAINT purchase_return_st_value_check CHECK (st_value >= 0),
  fcp_st_value numeric(15, 2) NOT NULL CONSTRAINT purchase_return_fcp_st_value_check CHECK (fcp_st_value >= 0),
  total_value numeric(15, 2) NOT NULL CONSTRAINT purchase_return_total_value_check CHECK (total_value >= 0),
  user_id uuid NOT NULL REFERENCES user_account (id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE UNIQUE INDEX purchase_return_number_key ON purchase_return (invoice_id, number) WHERE deleted_at IS NULL;
CREATE INDEX purchase_return_branch_id_idx ON purchase_return (branch_id);
CREATE INDEX purchase_return_economic_group_id_idx ON purchase_return (economic_group_id);
CREATE INDEX purchase_return_user_id_idx ON purchase_return (user_id);
CALL app.apply_table_standard('public.purchase_return');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON purchase_return
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'branch_id', 'invoice_id', 'number', 'reason', 'user_id', 'deleted_at'
  );
-- Os totais são a soma dos itens: gravados na mesma transação que cria a devolução e nunca mais.
CREATE FUNCTION app.block_return_totals() RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF OLD.created_at <> pg_catalog.now() AND (
       NEW.products_value, NEW.discount_value, NEW.freight_value, NEW.insurance_value, NEW.other_value,
       NEW.ipi_value, NEW.st_value, NEW.fcp_st_value, NEW.total_value
     ) IS DISTINCT FROM (
       OLD.products_value, OLD.discount_value, OLD.freight_value, OLD.insurance_value, OLD.other_value,
       OLD.ipi_value, OLD.st_value, OLD.fcp_st_value, OLD.total_value
     ) THEN
    RAISE EXCEPTION 'Este dado não pode ser alterado depois do cadastro.'
      USING ERRCODE = 'FA104', DETAIL = pg_catalog.format('Totais da devolução %s.', OLD.id);
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER block_return_totals BEFORE UPDATE ON purchase_return
  FOR EACH ROW EXECUTE FUNCTION app.block_return_totals();
CREATE POLICY purchase_return_select ON purchase_return FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group()) AND app.has_permission('purchases.view', branch_id));
CREATE VIEW v_purchase_return WITH (security_invoker = true) AS SELECT * FROM purchase_return WHERE deleted_at IS NULL;
GRANT SELECT ON purchase_return, v_purchase_return TO farmaerp_app;

CREATE TABLE purchase_return_item (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  branch_id uuid NOT NULL REFERENCES branch (id),
  return_id uuid NOT NULL REFERENCES purchase_return (id),
  invoice_item_id uuid NOT NULL REFERENCES purchase_invoice_item (id),
  product_id uuid NOT NULL REFERENCES product (id),
  -- Lote de onde saiu (vazio: produto sem controle de lote).
  batch_id uuid REFERENCES product_batch (id),
  -- Na unidade do produto (a do estoque).
  quantity numeric(14, 3) NOT NULL CONSTRAINT purchase_return_item_quantity_check CHECK (quantity > 0),
  -- A mesma quantidade na unidade da nota (espelho do item da nota).
  invoice_quantity numeric(15, 4) NOT NULL CONSTRAINT purchase_return_item_invoice_quantity_check CHECK (invoice_quantity >= 0),
  unit_price numeric(21, 10) NOT NULL CONSTRAINT purchase_return_item_unit_price_check CHECK (unit_price >= 0),
  products_value numeric(15, 2) NOT NULL CONSTRAINT purchase_return_item_products_value_check CHECK (products_value >= 0),
  discount_value numeric(15, 2) NOT NULL CONSTRAINT purchase_return_item_discount_value_check CHECK (discount_value >= 0),
  freight_value numeric(15, 2) NOT NULL CONSTRAINT purchase_return_item_freight_value_check CHECK (freight_value >= 0),
  insurance_value numeric(15, 2) NOT NULL CONSTRAINT purchase_return_item_insurance_value_check CHECK (insurance_value >= 0),
  other_value numeric(15, 2) NOT NULL CONSTRAINT purchase_return_item_other_value_check CHECK (other_value >= 0),
  ipi_value numeric(15, 2) NOT NULL CONSTRAINT purchase_return_item_ipi_value_check CHECK (ipi_value >= 0),
  st_value numeric(15, 2) NOT NULL CONSTRAINT purchase_return_item_st_value_check CHECK (st_value >= 0),
  fcp_st_value numeric(15, 2) NOT NULL CONSTRAINT purchase_return_item_fcp_st_value_check CHECK (fcp_st_value >= 0),
  total_value numeric(15, 2) NOT NULL CONSTRAINT purchase_return_item_total_value_check CHECK (total_value >= 0),
  -- Custo por unidade da entrada (é por ele que sai).
  unit_cost numeric(19, 6) NOT NULL CONSTRAINT purchase_return_item_unit_cost_check CHECK (unit_cost >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE INDEX purchase_return_item_return_idx ON purchase_return_item (return_id);
CREATE INDEX purchase_return_item_invoice_item_idx ON purchase_return_item (invoice_item_id);
CREATE INDEX purchase_return_item_product_id_idx ON purchase_return_item (product_id);
CREATE INDEX purchase_return_item_batch_id_idx ON purchase_return_item (batch_id);
CREATE INDEX purchase_return_item_branch_id_idx ON purchase_return_item (branch_id);
CREATE INDEX purchase_return_item_economic_group_id_idx ON purchase_return_item (economic_group_id);
CALL app.apply_table_standard('public.purchase_return_item');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON purchase_return_item
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'branch_id', 'return_id', 'invoice_item_id', 'product_id', 'batch_id', 'quantity',
    'invoice_quantity', 'unit_price', 'products_value', 'discount_value', 'freight_value', 'insurance_value',
    'other_value', 'ipi_value', 'st_value', 'fcp_st_value', 'total_value', 'unit_cost', 'deleted_at'
  );
CREATE POLICY purchase_return_item_select ON purchase_return_item FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group()) AND app.has_permission('purchases.view', branch_id));
CREATE VIEW v_purchase_return_item WITH (security_invoker = true) AS SELECT * FROM purchase_return_item WHERE deleted_at IS NULL;
GRANT SELECT ON purchase_return_item, v_purchase_return_item TO farmaerp_app;

-- Saída de estoque da devolução, ligada ao item devolvido.
ALTER TABLE stock_movement DROP CONSTRAINT stock_movement_type_check;
ALTER TABLE stock_movement ADD CONSTRAINT stock_movement_type_check CHECK (movement_type IN (
  'invoice', 'sale', 'return', 'transfer', 'adjustment', 'loss', 'inventory', 'import', 'supplier_return'
));
ALTER TABLE stock_movement
  ADD COLUMN purchase_return_item_id uuid REFERENCES purchase_return_item (id),
  ADD CONSTRAINT stock_movement_purchase_return_check CHECK ((purchase_return_item_id IS NOT NULL) = (movement_type = 'supplier_return'));
CREATE INDEX stock_movement_purchase_return_item_idx ON stock_movement (purchase_return_item_id) WHERE purchase_return_item_id IS NOT NULL;
CREATE OR REPLACE VIEW v_stock_movement WITH (security_invoker = true) AS
  SELECT * FROM stock_movement WHERE deleted_at IS NULL;

-- O custo médio também anda na devolução (saída pelo custo da entrada).
ALTER TABLE product_cost ADD COLUMN purchase_return_item_id uuid REFERENCES purchase_return_item (id);
CREATE INDEX product_cost_purchase_return_item_idx ON product_cost (purchase_return_item_id) WHERE purchase_return_item_id IS NOT NULL;
ALTER TABLE product_cost DROP CONSTRAINT product_cost_reversal_check;
ALTER TABLE product_cost ADD CONSTRAINT product_cost_reversal_check CHECK (
  ((reversal_of IS NULL AND purchase_return_item_id IS NULL) = (entry_quantity > 0))
  AND (average_cost IS NOT NULL OR reversal_of IS NOT NULL)
  AND (reversal_of IS NULL OR purchase_return_item_id IS NULL)
);
DROP TRIGGER block_immutable_columns ON product_cost;
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON product_cost
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'branch_id', 'product_id', 'average_cost', 'previous_cost', 'stock_before', 'entry_quantity',
    'entry_cost', 'purchase_invoice_item_id', 'reversal_of', 'deleted_at', 'imported_stock_item_id', 'purchase_return_item_id'
  );
CREATE OR REPLACE VIEW v_product_cost WITH (security_invoker = true) AS
  SELECT * FROM product_cost WHERE deleted_at IS NULL;

ALTER TABLE purchase_invoice_audit DROP CONSTRAINT purchase_invoice_audit_kind_check;
ALTER TABLE purchase_invoice_audit ADD CONSTRAINT purchase_invoice_audit_kind_check CHECK (kind IN (
  'linked', 'unlinked', 'batch_added', 'batch_removed', 'cost_released', 'discarded', 'fraction_changed', 'returned'
));

-- Controlado devolvido vai ao SNGPC como perda; o motivo o farmacêutico escolhe na conferência
-- (o código oficial da devolução no XML ainda vai ser confirmado).
CREATE OR REPLACE FUNCTION app.sngpc_kind_for(p_type text, p_quantity numeric) RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$
  SELECT CASE
    WHEN p_type = 'invoice' AND p_quantity > 0 THEN 'purchase'
    WHEN p_type = 'sale' AND p_quantity < 0 THEN 'sale'
    WHEN p_type = 'return' AND p_quantity > 0 THEN 'return_in'
    WHEN p_type = 'transfer' THEN CASE WHEN p_quantity > 0 THEN 'transfer_in' ELSE 'transfer_out' END
    WHEN p_type IN ('loss', 'supplier_return') AND p_quantity < 0 THEN 'loss'
    WHEN p_quantity > 0 THEN 'adjustment_in'
    ELSE 'adjustment_out'
  END
$$;

-- Nota com devolução: o que já saiu sairia de novo no estorno, no cancelamento ou no novo
-- fracionamento. O banco barra qualquer movimentação nova da nota depois da primeira devolução.
CREATE FUNCTION app.block_returned_invoice_movement() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.purchase_invoice_item it
      JOIN public.purchase_return r ON r.invoice_id = it.invoice_id AND r.deleted_at IS NULL
     WHERE it.id = NEW.purchase_invoice_item_id
  ) THEN
    RAISE EXCEPTION 'Esta nota tem devolução ao fornecedor e não pode mais ser estornada, cancelada nem ter o fracionamento alterado.'
      USING ERRCODE = 'FA767', DETAIL = pg_catalog.format('Item %s.', NEW.purchase_invoice_item_id);
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER block_returned_invoice_movement BEFORE INSERT ON stock_movement
  FOR EACH ROW WHEN (NEW.movement_type = 'invoice' AND NEW.purchase_invoice_item_id IS NOT NULL)
  EXECUTE FUNCTION app.block_returned_invoice_movement();

-- O que entrou de um item da nota (líquido de estornos e de fracionamento), por lote, e quanto já
-- foi devolvido de cada lote.
CREATE FUNCTION app.purchase_item_return_balance(p_item_id uuid)
RETURNS TABLE (batch_id uuid, entered numeric, returned numeric)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT e.batch_id, e.entered,
         COALESCE((SELECT pg_catalog.sum(ri.quantity) FROM public.purchase_return_item ri
                    WHERE ri.invoice_item_id = p_item_id AND ri.batch_id IS NOT DISTINCT FROM e.batch_id
                      AND ri.deleted_at IS NULL), 0)
    FROM (
      SELECT m.batch_id, pg_catalog.sum(m.quantity) AS entered
        FROM public.stock_movement m
       WHERE m.purchase_invoice_item_id = p_item_id AND m.movement_type = 'invoice' AND m.deleted_at IS NULL
       GROUP BY m.batch_id
      HAVING pg_catalog.sum(m.quantity) > 0
    ) e
$$;

-- Devolve itens da nota lançada. p_items: [{"itemId", "quantity" (na unidade do produto), "batchId"}].
-- Devolve o id da devolução.
CREATE FUNCTION app.return_purchase_items(p_invoice_id uuid, p_items jsonb, p_reason text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.purchase_invoice := app.lock_purchase_invoice(p_invoice_id);
  clean_reason text := app.require_reason(p_reason);
  line jsonb;
  item public.purchase_invoice_item;
  item_unit text;
  fractional boolean;
  qty numeric;
  wanted_batch uuid;
  balance record;
  item_entered numeric;
  item_returned numeric;
  entry public.product_cost;
  ratio numeric;
  closes boolean;
  v_products numeric; v_discount numeric; v_freight numeric; v_insurance numeric; v_other numeric;
  v_ipi numeric; v_st numeric; v_fcp numeric; v_total numeric;
  new_return_id uuid;
  new_item_id uuid;
  stock_now numeric;
  average_now numeric;
  new_average numeric;
  stock_balance numeric;
  allowed_by uuid;
  return_number integer;
  count_lines integer := 0;
BEGIN
  PERFORM app.require_purchase_permission('purchases.return', target.branch_id);
  IF target.status <> 'posted' THEN
    RAISE EXCEPTION 'Esta nota não está lançada.'
      USING ERRCODE = 'FA939', DETAIL = pg_catalog.format('purchase_invoice %s em %s.', target.id, target.status);
  END IF;
  IF pg_catalog.jsonb_typeof(p_items) IS DISTINCT FROM 'array' OR pg_catalog.jsonb_array_length(p_items) = 0
     OR pg_catalog.jsonb_array_length(p_items) > 500 THEN
    RAISE EXCEPTION 'Os dados da nota são inválidos.' USING ERRCODE = 'FA931', DETAIL = 'Devolução sem itens.';
  END IF;

  SELECT COALESCE(pg_catalog.max(r.number), 0) + 1 INTO return_number
    FROM public.purchase_return r WHERE r.invoice_id = target.id;
  INSERT INTO public.purchase_return (
    economic_group_id, branch_id, invoice_id, number, reason, products_value, discount_value, freight_value,
    insurance_value, other_value, ipi_value, st_value, fcp_st_value, total_value, user_id
  ) VALUES (
    target.economic_group_id, target.branch_id, target.id, return_number, clean_reason, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    app.current_user_id()
  ) RETURNING id INTO new_return_id;

  FOR line IN SELECT value FROM pg_catalog.jsonb_array_elements(p_items) AS value LOOP
    BEGIN
      qty := (line ->> 'quantity')::numeric;
      wanted_batch := NULLIF(line ->> 'batchId', '')::uuid;
      SELECT * INTO item FROM public.purchase_invoice_item it
       WHERE it.id = (line ->> 'itemId')::uuid AND it.invoice_id = target.id AND it.deleted_at IS NULL
       FOR UPDATE;
    EXCEPTION WHEN invalid_text_representation OR data_exception THEN
      RAISE EXCEPTION 'Os dados da nota são inválidos.' USING ERRCODE = 'FA931', DETAIL = 'Item da devolução fora do formato.';
    END;
    IF item.id IS NULL OR item.product_id IS NULL THEN
      RAISE EXCEPTION 'Um dos itens informados não foi encontrado.'
        USING ERRCODE = 'FA004', DETAIL = pg_catalog.format('Item %s fora da nota %s.', line ->> 'itemId', target.id);
    END IF;
    IF qty IS NULL OR qty <= 0 OR qty <> pg_catalog.round(qty, 3) THEN
      RAISE EXCEPTION 'Os dados da nota são inválidos.'
        USING ERRCODE = 'FA931', DETAIL = pg_catalog.format('Quantidade %s.', qty);
    END IF;

    SELECT pg_catalog.sum(b.entered), pg_catalog.sum(b.returned) INTO item_entered, item_returned
      FROM app.purchase_item_return_balance(item.id) b;
    SELECT * INTO balance FROM app.purchase_item_return_balance(item.id) b
     WHERE b.batch_id IS NOT DISTINCT FROM wanted_batch;
    IF balance.entered IS NULL THEN
      RAISE EXCEPTION 'Escolha um lote que entrou por este item da nota.'
        USING ERRCODE = 'FA770', DETAIL = pg_catalog.format('Item %s, lote %s.', item.id, wanted_batch);
    END IF;
    IF qty > balance.entered - balance.returned THEN
      RAISE EXCEPTION 'A quantidade passa do que ainda pode ser devolvido deste item.'
        USING ERRCODE = 'FA768',
              DETAIL = pg_catalog.format('Item %s, lote %s: pedido %s, disponível %s.', item.id, wanted_batch, qty,
                                         balance.entered - balance.returned);
    END IF;
    -- Unidade inteira (UN, CX...): só quantidade inteira, menos para fechar o que sobrou do lote.
    SELECT p.unit INTO item_unit FROM public.product p WHERE p.id = item.product_id;
    SELECT u.fractional INTO fractional FROM app.measure_units() u WHERE u.code = item_unit;
    IF NOT COALESCE(fractional, false) AND qty <> pg_catalog.trunc(qty) AND qty <> balance.entered - balance.returned THEN
      RAISE EXCEPTION 'Esta unidade só aceita quantidade inteira.'
        USING ERRCODE = 'FA769', DETAIL = pg_catalog.format('Item %s, unidade %s, quantidade %s.', item.id, item_unit, qty);
    END IF;

    -- Espelho da nota: valores na proporção do que entrou. A devolução que fecha o item leva o que
    -- sobrou, para os centavos baterem com a nota.
    ratio := qty / item_entered;
    closes := item_returned + qty = item_entered;
    IF closes THEN
      SELECT item.products_value - COALESCE(pg_catalog.sum(ri.products_value), 0),
             item.discount_value - COALESCE(pg_catalog.sum(ri.discount_value), 0),
             item.freight_value - COALESCE(pg_catalog.sum(ri.freight_value), 0),
             item.insurance_value - COALESCE(pg_catalog.sum(ri.insurance_value), 0),
             item.other_value - COALESCE(pg_catalog.sum(ri.other_value), 0),
             item.ipi_value - COALESCE(pg_catalog.sum(ri.ipi_value), 0),
             item.st_value - COALESCE(pg_catalog.sum(ri.st_value), 0),
             item.fcp_st_value - COALESCE(pg_catalog.sum(ri.fcp_st_value), 0)
        INTO v_products, v_discount, v_freight, v_insurance, v_other, v_ipi, v_st, v_fcp
        FROM public.purchase_return_item ri WHERE ri.invoice_item_id = item.id AND ri.deleted_at IS NULL;
    ELSE
      v_products := pg_catalog.round(item.products_value * ratio, 2);
      v_discount := pg_catalog.round(item.discount_value * ratio, 2);
      v_freight := pg_catalog.round(item.freight_value * ratio, 2);
      v_insurance := pg_catalog.round(item.insurance_value * ratio, 2);
      v_other := pg_catalog.round(item.other_value * ratio, 2);
      v_ipi := pg_catalog.round(item.ipi_value * ratio, 2);
      v_st := pg_catalog.round(item.st_value * ratio, 2);
      v_fcp := pg_catalog.round(item.fcp_st_value * ratio, 2);
    END IF;
    v_total := v_products - v_discount + v_freight + v_insurance + v_other + v_ipi + v_st + v_fcp;

    SELECT * INTO entry FROM public.product_cost c
     WHERE c.purchase_invoice_item_id = item.id AND c.reversal_of IS NULL AND c.purchase_return_item_id IS NULL
       AND c.deleted_at IS NULL
       AND NOT EXISTS (SELECT 1 FROM public.product_cost r WHERE r.reversal_of = c.id AND r.deleted_at IS NULL)
     ORDER BY c.id DESC LIMIT 1;

    INSERT INTO public.purchase_return_item (
      economic_group_id, branch_id, return_id, invoice_item_id, product_id, batch_id, quantity, invoice_quantity,
      unit_price, products_value, discount_value, freight_value, insurance_value, other_value, ipi_value, st_value,
      fcp_st_value, total_value, unit_cost
    ) VALUES (
      target.economic_group_id, target.branch_id, new_return_id, item.id, item.product_id, wanted_batch, qty,
      pg_catalog.round(item.quantity * ratio, 4), item.unit_price, v_products, v_discount, v_freight, v_insurance,
      v_other, v_ipi, v_st, v_fcp, v_total, COALESCE(entry.entry_cost, 0)
    ) RETURNING id INTO new_item_id;

    -- Custo médio: tira a quantidade pelo custo da entrada. Sem saldo depois, fica o que estava.
    PERFORM app.lock_product_cost(item.product_id, target.branch_id);
    stock_now := app.branch_stock_quantity(item.product_id, target.branch_id);
    average_now := app.average_cost(item.product_id, target.branch_id);
    IF average_now IS NOT NULL THEN
      new_average := CASE
        WHEN stock_now - qty <= 0 THEN average_now
        ELSE pg_catalog.round((stock_now * average_now - qty * COALESCE(entry.entry_cost, 0)) / (stock_now - qty), 6)
      END;
      IF new_average < 0 THEN
        new_average := average_now;
      END IF;
      INSERT INTO public.product_cost (
        economic_group_id, branch_id, product_id, average_cost, previous_cost, stock_before, entry_quantity, entry_cost,
        purchase_invoice_item_id, purchase_return_item_id
      ) VALUES (
        target.economic_group_id, target.branch_id, item.product_id, new_average, average_now, stock_now, -qty,
        COALESCE(entry.entry_cost, 0), item.id, new_item_id
      );
    END IF;

    -- Saída do lote. Deixar negativo só com a permissão; fica registrado quem liberou.
    SELECT COALESCE(pg_catalog.sum(sb.quantity), 0) INTO stock_balance FROM public.stock_balance sb
     WHERE sb.branch_id = target.branch_id AND sb.product_id = item.product_id
       AND sb.batch_id IS NOT DISTINCT FROM wanted_batch AND sb.deleted_at IS NULL;
    allowed_by := NULL;
    IF stock_balance - qty < 0 THEN
      IF NOT app.has_permission('purchases.negative_stock', target.branch_id) THEN
        RAISE EXCEPTION 'Esta operação deixa o estoque negativo, e você não tem permissão para isso.'
          USING ERRCODE = 'FA763',
                DETAIL = pg_catalog.format('Item %s, lote %s, saldo %s, saída %s.', item.id, wanted_batch, stock_balance, qty);
      END IF;
      allowed_by := app.current_user_id();
    END IF;
    INSERT INTO public.stock_movement (
      economic_group_id, branch_id, product_id, batch_id, movement_type, quantity, reason, purchase_return_item_id,
      negative_allowed_by
    ) VALUES (
      target.economic_group_id, target.branch_id, item.product_id, wanted_batch, 'supplier_return', -qty,
      pg_catalog.format('Devolução %s ao fornecedor da nota %s: %s', return_number, target.number, clean_reason),
      new_item_id, allowed_by
    );
    count_lines := count_lines + 1;
  END LOOP;

  UPDATE public.purchase_return r
     SET products_value = s.products_value, discount_value = s.discount_value, freight_value = s.freight_value,
         insurance_value = s.insurance_value, other_value = s.other_value, ipi_value = s.ipi_value,
         st_value = s.st_value, fcp_st_value = s.fcp_st_value, total_value = s.total_value
    FROM (
      SELECT pg_catalog.sum(ri.products_value) AS products_value, pg_catalog.sum(ri.discount_value) AS discount_value,
             pg_catalog.sum(ri.freight_value) AS freight_value, pg_catalog.sum(ri.insurance_value) AS insurance_value,
             pg_catalog.sum(ri.other_value) AS other_value, pg_catalog.sum(ri.ipi_value) AS ipi_value,
             pg_catalog.sum(ri.st_value) AS st_value, pg_catalog.sum(ri.fcp_st_value) AS fcp_st_value,
             pg_catalog.sum(ri.total_value) AS total_value
        FROM public.purchase_return_item ri WHERE ri.return_id = new_return_id
    ) s
   WHERE r.id = new_return_id;

  PERFORM app.record_purchase_audit(target.id, 'returned', (
    SELECT pg_catalog.jsonb_build_object('number', r.number, 'items', count_lines, 'total', r.total_value, 'reason', r.reason)
      FROM public.purchase_return r WHERE r.id = new_return_id
  ));
  RETURN new_return_id;
END;
$$;

-- Itens que podem ser devolvidos (o que entrou, o que já voltou e o saldo, por lote) e as
-- devoluções feitas, para a tela da nota.
CREATE FUNCTION app.purchase_invoice_returns(p_invoice_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT pg_catalog.jsonb_build_object(
    'can_return', app.has_permission('purchases.return', i.branch_id) AND i.status = 'posted',
    'items', COALESCE((
      SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
               'item_id', it.id, 'item_number', it.item_number, 'description', it.description,
               'unit', p.unit, 'fractional', u.fractional, 'invoice_unit', it.unit,
               'entered', b.entered, 'returned', b.returned, 'available', b.entered - b.returned,
               'batches', b.batches) ORDER BY it.item_number)
        FROM public.purchase_invoice_item it
        JOIN public.product p ON p.id = it.product_id
        LEFT JOIN LATERAL (SELECT mu.fractional FROM app.measure_units() mu WHERE mu.code = p.unit) u ON true
        JOIN LATERAL (
          SELECT pg_catalog.sum(x.entered) AS entered, pg_catalog.sum(x.returned) AS returned,
                 pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
                   'batch_id', x.batch_id, 'batch_number', pb.batch_number, 'expires_on', pb.expires_on,
                   'entered', x.entered, 'returned', x.returned, 'available', x.entered - x.returned)
                   ORDER BY pb.expires_on NULLS FIRST, pb.batch_number) AS batches
            FROM app.purchase_item_return_balance(it.id) x
            LEFT JOIN public.product_batch pb ON pb.id = x.batch_id
        ) b ON b.entered IS NOT NULL
       WHERE it.invoice_id = i.id AND it.deleted_at IS NULL
    ), '[]'::jsonb),
    'returns', COALESCE((
      SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
               'id', r.id, 'number', r.number, 'reason', r.reason, 'created_at', r.created_at, 'user_name', ua.name,
               'products_value', r.products_value, 'discount_value', r.discount_value, 'freight_value', r.freight_value,
               'insurance_value', r.insurance_value, 'other_value', r.other_value, 'ipi_value', r.ipi_value,
               'st_value', r.st_value, 'fcp_st_value', r.fcp_st_value, 'total_value', r.total_value,
               'items', (
                 SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
                          'item_number', it.item_number, 'description', it.description, 'quantity', ri.quantity,
                          'unit', p.unit, 'invoice_quantity', ri.invoice_quantity, 'invoice_unit', it.unit,
                          'batch_number', pb.batch_number, 'unit_price', ri.unit_price, 'total_value', ri.total_value)
                          ORDER BY it.item_number, pb.batch_number)
                   FROM public.purchase_return_item ri
                   JOIN public.purchase_invoice_item it ON it.id = ri.invoice_item_id
                   JOIN public.product p ON p.id = ri.product_id
                   LEFT JOIN public.product_batch pb ON pb.id = ri.batch_id
                  WHERE ri.return_id = r.id AND ri.deleted_at IS NULL
               )) ORDER BY r.number)
        FROM public.purchase_return r
        JOIN public.user_account ua ON ua.id = r.user_id
       WHERE r.invoice_id = i.id AND r.deleted_at IS NULL
    ), '[]'::jsonb)
  )
    FROM public.purchase_invoice i
   WHERE i.id = p_invoice_id AND i.economic_group_id = app.current_user_group() AND i.deleted_at IS NULL
     AND app.has_permission('purchases.view', i.branch_id)
$$;

-- Situação de cada item: a entrada em vigor é a positiva (a linha de custo da devolução não conta).
CREATE OR REPLACE FUNCTION app.purchase_invoice_posting(p_invoice_id uuid)
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
       WHERE c.purchase_invoice_item_id = item.id AND c.reversal_of IS NULL AND c.purchase_return_item_id IS NULL
         AND c.deleted_at IS NULL
         AND NOT EXISTS (SELECT 1 FROM public.product_cost r WHERE r.reversal_of = c.id AND r.deleted_at IS NULL)
       ORDER BY c.id DESC LIMIT 1;
      fraction := COALESCE(item.posted_fraction, fraction);
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

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  app.return_purchase_items(uuid, jsonb, text),
  app.purchase_invoice_returns(uuid)
TO farmaerp_app;
