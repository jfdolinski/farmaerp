-- Up Migration

-- Manutenção da nota de entrada lançada: cancelar (a nota sai do estoque e fica guardada como
-- cancelada, com motivo) e alterar o fracionamento de um item (o estoque e o custo médio acompanham,
-- e o vínculo com o fornecedor passa a valer o novo). Se o que entrou já saiu, o estoque pode ficar
-- negativo, mas só para quem tem a permissão de deixar negativo.

INSERT INTO permission (code, module, name) VALUES
  ('purchases.cancel', 'Compras', 'Cancelar nota de entrada'),
  ('purchases.negative_stock', 'Compras', 'Deixar estoque negativo ao cancelar, estornar ou alterar nota de entrada');

-- O Gerente cancela a nota da loja; deixar o estoque negativo fica com o Administrador (dá para
-- estender em /perfis).
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
     'purchases.post', 'purchases.cancel', 'releases.view', 'sync.view', 'sync.resolve', 'sales.sell', 'sales.view',
     'sales.zero_stock_release', 'controlled.view', 'sales.quote', 'sales.return',
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

-- Grupos que já existem: quem lança a nota da loja (o Gerente) passa a poder cancelar.
INSERT INTO role_permission (role_id, permission_id)
SELECT r.id, p.id
  FROM role r
 CROSS JOIN permission p
 WHERE r.name = 'Gerente' AND r.deleted_at IS NULL AND r.system_key IS NULL AND p.code = 'purchases.cancel'
   AND NOT EXISTS (
     SELECT 1 FROM role_permission rp WHERE rp.role_id = r.id AND rp.permission_id = p.id AND rp.deleted_at IS NULL
   );

-- Cancelada por alguém da farmácia: quem e por quê. O cancelamento informado pela Sefaz continua só
-- no cancelled_at.
ALTER TABLE purchase_invoice
  ADD COLUMN cancelled_by uuid REFERENCES user_account (id),
  ADD COLUMN cancel_reason text CONSTRAINT purchase_invoice_cancel_reason_check CHECK (btrim(cancel_reason) <> '' AND length(cancel_reason) <= 500),
  ADD CONSTRAINT purchase_invoice_cancelled_by_check CHECK (
    (cancelled_by IS NULL) = (cancel_reason IS NULL) AND (cancelled_by IS NULL OR status = 'cancelled')
  );
CREATE INDEX purchase_invoice_cancelled_by_idx ON purchase_invoice (cancelled_by) WHERE cancelled_by IS NOT NULL;

ALTER TABLE purchase_invoice_event DROP CONSTRAINT purchase_invoice_event_kind_check;
ALTER TABLE purchase_invoice_event ADD CONSTRAINT purchase_invoice_event_kind_check CHECK (kind IN ('posted', 'reversed', 'cancelled'));
ALTER TABLE purchase_invoice_event DROP CONSTRAINT purchase_invoice_event_kind_reason_check;
ALTER TABLE purchase_invoice_event ADD CONSTRAINT purchase_invoice_event_kind_reason_check CHECK ((kind IN ('reversed', 'cancelled')) = (reason IS NOT NULL));

ALTER TABLE purchase_invoice_audit DROP CONSTRAINT purchase_invoice_audit_kind_check;
ALTER TABLE purchase_invoice_audit ADD CONSTRAINT purchase_invoice_audit_kind_check CHECK (kind IN (
  'linked', 'unlinked', 'batch_added', 'batch_removed', 'cost_released', 'discarded', 'fraction_changed'
));

-- Fracionamento com que o item entrou no estoque. Guardado no lançamento: mudar o vínculo do
-- fornecedor depois não muda o que a nota lançada mostra.
ALTER TABLE purchase_invoice_item
  ADD COLUMN posted_fraction numeric(10, 3) CONSTRAINT purchase_invoice_item_posted_fraction_check CHECK (posted_fraction > 0);
UPDATE purchase_invoice_item it
   SET posted_fraction = pg_catalog.round(c.entry_quantity / it.quantity, 3)
  FROM purchase_invoice i, product_cost c
 WHERE i.id = it.invoice_id AND i.status = 'posted' AND c.purchase_invoice_item_id = it.id
   AND c.reversal_of IS NULL AND c.deleted_at IS NULL
   AND NOT EXISTS (SELECT 1 FROM product_cost r WHERE r.reversal_of = c.id AND r.deleted_at IS NULL)
   AND pg_catalog.round(c.entry_quantity / it.quantity, 3) > 0;

CREATE FUNCTION app.keep_posted_fraction() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NEW.status = 'posted' THEN
    UPDATE public.purchase_invoice_item it
       SET posted_fraction = app.effective_fraction(it.product_id, it.barcode_id, it.product_supplier_id)
     WHERE it.invoice_id = NEW.id AND it.deleted_at IS NULL AND it.product_id IS NOT NULL;
  ELSIF NEW.status = 'review' THEN
    UPDATE public.purchase_invoice_item it SET posted_fraction = NULL
     WHERE it.invoice_id = NEW.id AND it.posted_fraction IS NOT NULL;
  END IF;
  RETURN NULL;
END;
$$;
CREATE TRIGGER keep_posted_fraction AFTER UPDATE OF status ON purchase_invoice
  FOR EACH ROW WHEN (OLD.status IS DISTINCT FROM NEW.status AND NEW.status IN ('posted', 'review'))
  EXECUTE FUNCTION app.keep_posted_fraction();

-- Saída que deixa o saldo negativo com a liberação de quem tinha a permissão.
ALTER TABLE stock_movement ADD COLUMN negative_allowed_by uuid REFERENCES user_account (id);
CREATE INDEX stock_movement_negative_allowed_by_idx ON stock_movement (negative_allowed_by) WHERE negative_allowed_by IS NOT NULL;

-- A view com SELECT * congela as colunas: recria para mostrar as novas.
CREATE OR REPLACE VIEW v_purchase_invoice WITH (security_invoker = true) AS
  SELECT * FROM purchase_invoice WHERE deleted_at IS NULL;
CREATE OR REPLACE VIEW v_purchase_invoice_item WITH (security_invoker = true) AS
  SELECT * FROM purchase_invoice_item WHERE deleted_at IS NULL;
CREATE OR REPLACE VIEW v_stock_movement WITH (security_invoker = true) AS
  SELECT * FROM stock_movement WHERE deleted_at IS NULL;


-- Venda, venda importada, inventário com corte e saída liberada podem deixar o saldo negativo.
CREATE OR REPLACE FUNCTION app.apply_stock_movement() RETURNS trigger
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

  IF NEW.quantity < 0 AND new_quantity < 0 AND NEW.movement_type NOT IN ('sale', 'import') AND NEW.stock_count_id IS NULL
     AND NEW.negative_allowed_by IS NULL THEN
    RAISE EXCEPTION 'A quantidade é maior que o saldo disponível.'
      USING ERRCODE = 'FA801',
            DETAIL = pg_catalog.format('Produto %s, filial %s, lote %s, saldo ficaria %s.', NEW.product_id, NEW.branch_id, NEW.batch_id, new_quantity);
  END IF;
  RETURN NULL;
END;
$$;

-- Movimentação de um item da nota. Saída que deixaria o saldo do lote negativo só passa para quem tem
-- a permissão; fica registrado quem liberou.
CREATE FUNCTION app.purchase_item_movement(
  p_item public.purchase_invoice_item, p_batch_id uuid, p_quantity numeric, p_reason text, p_reversal_of uuid
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  balance numeric;
  allowed_by uuid;
BEGIN
  IF p_quantity < 0 THEN
    SELECT COALESCE(pg_catalog.sum(sb.quantity), 0) INTO balance FROM public.stock_balance sb
     WHERE sb.branch_id = p_item.branch_id AND sb.product_id = p_item.product_id
       AND sb.batch_id IS NOT DISTINCT FROM p_batch_id AND sb.deleted_at IS NULL;
    IF balance + p_quantity < 0 THEN
      IF NOT app.has_permission('purchases.negative_stock', p_item.branch_id) THEN
        RAISE EXCEPTION 'Esta operação deixa o estoque negativo, e você não tem permissão para isso.'
          USING ERRCODE = 'FA763',
                DETAIL = pg_catalog.format('Item %s, produto %s, lote %s, saldo %s, saída %s.', p_item.id, p_item.product_id,
                                           p_batch_id, balance, p_quantity);
      END IF;
      allowed_by := app.current_user_id();
    END IF;
  END IF;
  INSERT INTO public.stock_movement (
    economic_group_id, branch_id, product_id, batch_id, movement_type, quantity, reason, reversal_of,
    purchase_invoice_item_id, negative_allowed_by
  ) VALUES (
    p_item.economic_group_id, p_item.branch_id, p_item.product_id, p_batch_id, 'invoice', p_quantity, p_reason,
    p_reversal_of, p_item.id, allowed_by
  );
END;
$$;

-- Tira a nota lançada do estoque: movimentações contrárias e o custo médio pela conta inversa. Usada
-- pelo estorno (volta para a conferência) e pelo cancelamento.
CREATE FUNCTION app.unpost_purchase_invoice(p_invoice public.purchase_invoice, p_reason text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  item public.purchase_invoice_item;
  movement public.stock_movement;
  entry public.product_cost;
  current_average numeric;
  stock_after numeric;
  restored numeric;
BEGIN
  FOR item IN
    SELECT * FROM public.purchase_invoice_item it
     WHERE it.invoice_id = p_invoice.id AND it.deleted_at IS NULL
     ORDER BY it.item_number DESC
  LOOP
    SELECT * INTO entry FROM public.product_cost c
     WHERE c.purchase_invoice_item_id = item.id AND c.reversal_of IS NULL AND c.deleted_at IS NULL
       AND NOT EXISTS (SELECT 1 FROM public.product_cost r WHERE r.reversal_of = c.id AND r.deleted_at IS NULL)
     ORDER BY c.id DESC
     LIMIT 1;
    CONTINUE WHEN NOT FOUND;
    PERFORM app.lock_product_cost(entry.product_id, p_invoice.branch_id);

    FOR movement IN
      SELECT * FROM public.stock_movement m
       WHERE m.purchase_invoice_item_id = item.id AND m.reversal_of IS NULL AND m.deleted_at IS NULL
         AND NOT EXISTS (SELECT 1 FROM public.stock_movement r WHERE r.reversal_of = m.id AND r.deleted_at IS NULL)
       ORDER BY m.id
    LOOP
      PERFORM app.purchase_item_movement(item, movement.batch_id, -movement.quantity, p_reason, movement.id);
    END LOOP;

    -- Conta inversa da média. Sem saldo depois, ou com a conta dando negativa, volta o custo de antes
    -- da entrada.
    current_average := app.average_cost(entry.product_id, p_invoice.branch_id);
    stock_after := app.branch_stock_quantity(entry.product_id, p_invoice.branch_id);
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
      p_invoice.economic_group_id, p_invoice.branch_id, entry.product_id, restored, current_average,
      stock_after + entry.entry_quantity, -entry.entry_quantity, entry.entry_cost, item.id, entry.id
    );
  END LOOP;

  UPDATE public.purchase_invoice_item_cost_release cr SET deleted_at = pg_catalog.clock_timestamp()
    FROM public.purchase_invoice_item it
   WHERE it.id = cr.item_id AND it.invoice_id = p_invoice.id AND cr.deleted_at IS NULL;
END;
$$;

-- Estorno: a nota sai do estoque e volta para a conferência.
CREATE OR REPLACE FUNCTION app.reverse_purchase_invoice(p_invoice_id uuid, p_reason text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.purchase_invoice := app.lock_purchase_invoice(p_invoice_id);
  clean_reason text := app.require_reason(p_reason);
BEGIN
  PERFORM app.require_purchase_permission('purchases.post', target.branch_id);
  IF target.status <> 'posted' THEN
    RAISE EXCEPTION 'Esta nota não está lançada.'
      USING ERRCODE = 'FA939', DETAIL = pg_catalog.format('purchase_invoice %s em %s.', target.id, target.status);
  END IF;
  PERFORM app.unpost_purchase_invoice(target, clean_reason);
  UPDATE public.purchase_invoice SET status = 'review' WHERE id = target.id;
  INSERT INTO public.purchase_invoice_event (economic_group_id, branch_id, invoice_id, kind, reason, user_id)
  VALUES (target.economic_group_id, target.branch_id, target.id, 'reversed', clean_reason, app.current_user_id());
END;
$$;

-- Cancelamento: lançada, sai do estoque; em conferência, só deixa de poder ser lançada. A nota fica
-- guardada como cancelada (o mesmo XML não entra de novo) e não volta para a conferência.
CREATE FUNCTION app.cancel_purchase_invoice(p_invoice_id uuid, p_reason text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.purchase_invoice := app.lock_purchase_invoice(p_invoice_id);
  clean_reason text := app.require_reason(p_reason);
BEGIN
  PERFORM app.require_purchase_permission('purchases.cancel', target.branch_id);
  IF target.status = 'cancelled' THEN
    RAISE EXCEPTION 'Esta nota já está cancelada.'
      USING ERRCODE = 'FA764', DETAIL = pg_catalog.format('purchase_invoice %s.', target.id);
  END IF;
  IF target.status = 'posted' THEN
    PERFORM app.unpost_purchase_invoice(target, pg_catalog.format('Nota %s cancelada: %s', target.number, clean_reason));
  END IF;
  UPDATE public.purchase_invoice
     SET status = 'cancelled', cancelled_by = app.current_user_id(), cancel_reason = clean_reason
   WHERE id = target.id;
  INSERT INTO public.purchase_invoice_event (economic_group_id, branch_id, invoice_id, kind, reason, user_id)
  VALUES (target.economic_group_id, target.branch_id, target.id, 'cancelled', clean_reason, app.current_user_id());
END;
$$;

-- Nota lançada não se descarta (o estoque precisa sair antes), nem a cancelada pela farmácia: ela fica
-- guardada para o mesmo XML não entrar de novo.
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
  IF target.cancelled_by IS NOT NULL THEN
    RAISE EXCEPTION 'Esta nota já está cancelada.'
      USING ERRCODE = 'FA764', DETAIL = pg_catalog.format('purchase_invoice %s cancelada pela farmácia.', target.id);
  END IF;
  UPDATE public.purchase_invoice SET deleted_at = pg_catalog.clock_timestamp(), discard_reason = clean_reason
   WHERE id = target.id;
END;
$$;

-- Novo fracionamento de um item da nota lançada. A diferença entra (ou sai) nos mesmos lotes, na
-- proporção do que cada um recebeu; o custo da entrada é refeito com a nova quantidade, e o custo
-- médio pela conta inversa da entrada antiga mais a entrada nova. O vínculo com o fornecedor passa a
-- usar o novo fracionamento (vale para as próximas notas).
CREATE FUNCTION app.change_purchase_item_fraction(p_item_id uuid, p_fraction numeric, p_reason text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  item public.purchase_invoice_item := app.find_purchase_item(p_item_id);
  target public.purchase_invoice := app.lock_purchase_invoice(item.invoice_id);
  clean_reason text := app.require_reason(p_reason);
  entry public.product_cost;
  old_fraction numeric;
  new_quantity numeric;
  new_cost numeric;
  stock_now numeric;
  average_now numeric;
  stock_without numeric;
  average_without numeric;
  new_average numeric;
  group_row record;
  groups_left integer;
  assigned numeric := 0;
  batch_target numeric;
  movement_reason text;
BEGIN
  PERFORM app.require_purchase_permission('purchases.post', target.branch_id);
  IF target.status <> 'posted' THEN
    RAISE EXCEPTION 'Esta nota não está lançada.'
      USING ERRCODE = 'FA939', DETAIL = pg_catalog.format('purchase_invoice %s em %s.', target.id, target.status);
  END IF;
  -- O item travado junto: duas alterações ao mesmo tempo não passam.
  SELECT * INTO item FROM public.purchase_invoice_item it WHERE it.id = item.id FOR UPDATE;
  IF p_fraction IS NULL OR p_fraction <= 0 OR p_fraction >= 10000000 OR p_fraction <> pg_catalog.round(p_fraction, 3) THEN
    RAISE EXCEPTION 'Os dados da nota são inválidos.'
      USING ERRCODE = 'FA931', DETAIL = pg_catalog.format('Fracionamento %s.', p_fraction);
  END IF;
  new_quantity := pg_catalog.round(item.quantity * p_fraction, 3);
  IF new_quantity <= 0 THEN
    RAISE EXCEPTION 'Os dados da nota são inválidos.'
      USING ERRCODE = 'FA931', DETAIL = pg_catalog.format('Item %s sem quantidade no estoque.', item.item_number);
  END IF;

  SELECT * INTO entry FROM public.product_cost c
   WHERE c.purchase_invoice_item_id = item.id AND c.reversal_of IS NULL AND c.deleted_at IS NULL
     AND NOT EXISTS (SELECT 1 FROM public.product_cost r WHERE r.reversal_of = c.id AND r.deleted_at IS NULL)
   ORDER BY c.id DESC
   LIMIT 1;
  IF entry.id IS NULL THEN
    RAISE EXCEPTION 'Esta nota não está lançada.'
      USING ERRCODE = 'FA939', DETAIL = pg_catalog.format('Item %s sem entrada.', item.id);
  END IF;
  old_fraction := COALESCE(item.posted_fraction, pg_catalog.round(entry.entry_quantity / item.quantity, 3));
  IF new_quantity = entry.entry_quantity THEN
    RAISE EXCEPTION 'O fracionamento informado é igual ao que já está na nota.'
      USING ERRCODE = 'FA765', DETAIL = pg_catalog.format('Item %s, fracionamento %s.', item.id, p_fraction);
  END IF;
  PERFORM app.lock_product_cost(item.product_id, target.branch_id);
  stock_now := app.branch_stock_quantity(item.product_id, target.branch_id);
  average_now := app.average_cost(item.product_id, target.branch_id);

  -- Diferença em cada lote que o item recebeu; o último fica com a sobra do arredondamento.
  movement_reason := pg_catalog.format('Nota %s série %s: fracionamento de %s para %s (%s)', target.number, target.series,
                                       old_fraction, p_fraction, clean_reason);
  SELECT pg_catalog.count(*) INTO groups_left FROM (
    SELECT m.batch_id FROM public.stock_movement m
     WHERE m.purchase_invoice_item_id = item.id AND m.deleted_at IS NULL
     GROUP BY m.batch_id HAVING pg_catalog.sum(m.quantity) <> 0
  ) g;
  FOR group_row IN
    SELECT m.batch_id, pg_catalog.sum(m.quantity) AS quantity
      FROM public.stock_movement m
      LEFT JOIN public.product_batch pb ON pb.id = m.batch_id
     WHERE m.purchase_invoice_item_id = item.id AND m.deleted_at IS NULL
     GROUP BY m.batch_id, pb.expires_on, pb.batch_number
    HAVING pg_catalog.sum(m.quantity) <> 0
     ORDER BY pb.expires_on NULLS LAST, pb.batch_number, m.batch_id
  LOOP
    groups_left := groups_left - 1;
    batch_target := CASE WHEN groups_left = 0 THEN new_quantity - assigned
                         ELSE pg_catalog.round(group_row.quantity * new_quantity / entry.entry_quantity, 3) END;
    assigned := assigned + batch_target;
    IF batch_target <> group_row.quantity THEN
      PERFORM app.purchase_item_movement(item, group_row.batch_id, batch_target - group_row.quantity, movement_reason, NULL);
    END IF;
  END LOOP;

  -- Custo da entrada com a nova quantidade (a mesma conta do lançamento).
  new_cost := GREATEST(pg_catalog.round(
    (item.products_value - item.discount_value + item.freight_value + item.insurance_value + item.other_value
     + item.ipi_value + item.st_value + item.fcp_st_value) / new_quantity, 6), 0.000000);

  -- Primeiro sai a entrada antiga (conta inversa), depois entra a nova.
  stock_without := stock_now - entry.entry_quantity;
  average_without := CASE
    WHEN stock_without <= 0 OR average_now IS NULL THEN entry.previous_cost
    ELSE pg_catalog.round((stock_now * average_now - entry.entry_quantity * entry.entry_cost) / stock_without, 6)
  END;
  IF average_without < 0 THEN
    average_without := entry.previous_cost;
  END IF;
  INSERT INTO public.product_cost (
    economic_group_id, branch_id, product_id, average_cost, previous_cost, stock_before, entry_quantity, entry_cost,
    purchase_invoice_item_id, reversal_of
  ) VALUES (
    target.economic_group_id, target.branch_id, item.product_id, average_without, average_now, stock_now,
    -entry.entry_quantity, entry.entry_cost, item.id, entry.id
  );
  new_average := CASE
    WHEN average_without IS NULL OR stock_without <= 0 THEN new_cost
    ELSE pg_catalog.round((stock_without * average_without + new_quantity * new_cost) / (stock_without + new_quantity), 6)
  END;
  INSERT INTO public.product_cost (
    economic_group_id, branch_id, product_id, average_cost, previous_cost, stock_before, entry_quantity, entry_cost,
    purchase_invoice_item_id
  ) VALUES (
    target.economic_group_id, target.branch_id, item.product_id, new_average, average_without, stock_without,
    new_quantity, new_cost, item.id
  );

  UPDATE public.purchase_invoice_item SET posted_fraction = p_fraction WHERE id = item.id;
  UPDATE public.product_supplier ps SET fraction_quantity = p_fraction
   WHERE ps.id = item.product_supplier_id AND ps.product_id = item.product_id AND ps.deleted_at IS NULL;

  PERFORM app.record_purchase_audit(target.id, 'fraction_changed', pg_catalog.jsonb_build_object(
    'item_number', item.item_number, 'description', item.description, 'from', old_fraction, 'to', p_fraction,
    'stock_from', entry.entry_quantity, 'stock_to', new_quantity, 'cost_from', entry.entry_cost, 'cost_to', new_cost,
    'reason', clean_reason
  ));
END;
$$;

-- Itens da nota: na lançada, o fracionamento é o do lançamento.
CREATE OR REPLACE FUNCTION app.purchase_invoice_items(p_invoice_id uuid)
RETURNS TABLE (
  id uuid, item_number smallint, supplier_code text, barcode text, description text, ncm text, cfop text, unit text,
  quantity numeric, unit_price numeric, products_value numeric, discount_value numeric, st_value numeric, ipi_value numeric,
  anvisa_code text, pmc numeric, product_id uuid, product_code bigint, product_name text, match_source text,
  fraction numeric, stock_quantity numeric, catalog_ms text, ms_differs boolean, sale_price numeric, pmc_below_price boolean,
  batches jsonb
)
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT it.id, it.item_number, it.supplier_code, it.barcode, it.description, it.ncm, it.cfop, it.unit, it.quantity,
         it.unit_price, it.products_value, it.discount_value, it.st_value, it.ipi_value, it.anvisa_code, it.pmc,
         it.product_id, p.code, p.display_name, it.match_source, computed.fraction,
         pg_catalog.round(it.quantity * computed.fraction, 3), cp.ms_registration,
         COALESCE(it.anvisa_code ~ '^[0-9]{13}$' AND cp.ms_registration IS NOT NULL AND cp.ms_registration <> it.anvisa_code, false),
         computed.price, COALESCE(it.pmc < computed.price, false),
         COALESCE((SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
                    'number', b.batch_number, 'quantity', b.quantity, 'manufacturedOn', b.manufactured_on::text,
                    'expiresOn', b.expires_on::text) ORDER BY b.expires_on, b.batch_number)
                     FROM public.v_purchase_invoice_item_batch b WHERE b.item_id = it.id), '[]'::jsonb)
    FROM public.v_purchase_invoice_item it
    LEFT JOIN public.v_product p ON p.id = it.product_id
    LEFT JOIN public.v_catalog_product cp ON cp.id = p.catalog_product_id
    LEFT JOIN LATERAL (
      SELECT CASE WHEN it.product_id IS NULL THEN NULL
                  ELSE COALESCE(it.posted_fraction, app.effective_fraction(it.product_id, it.barcode_id, it.product_supplier_id)) END AS fraction,
             CASE WHEN it.product_id IS NULL THEN NULL ELSE app.effective_price(it.product_id, it.branch_id) END AS price
    ) AS computed ON true
   WHERE it.invoice_id = p_invoice_id
   ORDER BY it.item_number
$$;

-- Situação de cada item. Na nota lançada, mostra o que entrou (a entrada em vigor do item).
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
       WHERE c.purchase_invoice_item_id = item.id AND c.reversal_of IS NULL AND c.deleted_at IS NULL
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
  app.cancel_purchase_invoice(uuid, text),
  app.change_purchase_item_fraction(uuid, numeric, text)
TO farmaerp_app;
