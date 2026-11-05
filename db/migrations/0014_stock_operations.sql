-- Up Migration

-- Transferência, inventário simples, baixa pelo vencimento mais próximo e o que cada status
-- permite conforme o saldo. Toda escrita da API passa pelas funções app.*.

-- Liga a saída e a entrada de uma mesma transferência.
ALTER TABLE stock_movement ADD COLUMN transfer_group uuid;
CREATE INDEX stock_movement_transfer_group_idx ON stock_movement (transfer_group) WHERE transfer_group IS NOT NULL;

-- security_invoker precisa ser repetido: CREATE OR REPLACE substitui as opções da view.
CREATE OR REPLACE VIEW v_stock_movement WITH (security_invoker = true) AS
  SELECT * FROM stock_movement WHERE deleted_at IS NULL;

-- Lotes que podem sair, na ordem: vence antes, depois entrou antes. Vencido e zerado não entram.
CREATE FUNCTION app.batches_in_fefo_order(p_product_id uuid, p_branch_id uuid)
RETURNS TABLE (batch_id uuid, available numeric, expires_on date, fefo_position bigint)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT pb.id, sb.quantity, pb.expires_on,
         pg_catalog.row_number() OVER (ORDER BY pb.expires_on, pb.created_at, pb.id)
    FROM public.stock_balance sb
    JOIN public.product_batch pb ON pb.id = sb.batch_id AND pb.deleted_at IS NULL
   WHERE sb.product_id = p_product_id AND sb.branch_id = p_branch_id
     AND sb.deleted_at IS NULL AND sb.quantity > 0
     AND pb.expires_on >= app.local_today()
$$;

-- Distribui a quantidade entre os lotes, pela ordem. Falta saldo: recusa.
CREATE FUNCTION app.allocate_batches(p_product_id uuid, p_branch_id uuid, p_quantity numeric)
RETURNS TABLE (batch_id uuid, quantity numeric)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  remaining numeric := p_quantity;
  candidate record;
BEGIN
  FOR candidate IN
    SELECT * FROM app.batches_in_fefo_order(p_product_id, p_branch_id) ORDER BY fefo_position
  LOOP
    EXIT WHEN remaining <= 0;
    batch_id := candidate.batch_id;
    quantity := LEAST(candidate.available, remaining);
    remaining := remaining - quantity;
    RETURN NEXT;
  END LOOP;
  IF remaining > 0 THEN
    RAISE EXCEPTION 'A quantidade é maior que o saldo disponível.'
      USING ERRCODE = 'FA801',
            DETAIL = pg_catalog.format('Produto %s, filial %s: faltam %s fora de lotes vencidos.', p_product_id, p_branch_id, remaining);
  END IF;
END;
$$;

-- Lote escolhido à mão: vencido nunca; fora da ordem, só com permissão, e fica registrado.
-- Devolve true quando furou a ordem.
CREATE FUNCTION app.check_chosen_batch(p_product_id uuid, p_branch_id uuid, p_batch_id uuid) RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  chosen_position bigint;
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.product_batch pb WHERE pb.id = p_batch_id AND pb.expires_on < app.local_today()
  ) THEN
    RAISE EXCEPTION 'Lote vencido só sai como perda.'
      USING ERRCODE = 'FA813', DETAIL = pg_catalog.format('product_batch %s.', p_batch_id);
  END IF;

  SELECT f.fefo_position INTO chosen_position
    FROM app.batches_in_fefo_order(p_product_id, p_branch_id) f WHERE f.batch_id = p_batch_id;
  IF chosen_position IS NULL OR chosen_position = 1 THEN
    -- Sem saldo, quem recusa é o trigger do saldo.
    RETURN false;
  END IF;

  IF NOT app.has_permission('stock.batch_override', p_branch_id) THEN
    RAISE EXCEPTION 'Este lote fura a ordem de vencimento.'
      USING ERRCODE = 'FA814', DETAIL = pg_catalog.format('Lote na posição %s.', chosen_position);
  END IF;
  RETURN true;
END;
$$;

-- Transferência imediata: saída na origem e entrada no destino, na mesma transação.
-- No destino, o lote de mesmo número é usado ou criado com a validade e o MS da origem.
CREATE FUNCTION app.transfer_stock(p_data jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  origin uuid := (p_data ->> 'fromBranchId')::uuid;
  destination uuid := (p_data ->> 'toBranchId')::uuid;
  amount numeric := (p_data ->> 'quantity')::numeric;
  batch_number text := NULLIF(pg_catalog.btrim(COALESCE(p_data ->> 'batchNumber', '')), '');
  clean_reason text := app.require_reason(p_data ->> 'reason');
  group_id uuid := app.current_user_group();
  transfer uuid := pg_catalog.uuidv7();
  product uuid;
  chosen uuid;
  overridden boolean := false;
  part record;
  source public.product_batch;
  target_batch uuid;
BEGIN
  PERFORM app.require_stock_permission('stock.transfer', origin);
  product := app.require_product_lookup(p_data ->> 'productLookup');
  PERFORM app.require_positive_quantity(amount);

  IF origin = destination THEN
    RAISE EXCEPTION 'A filial de destino precisa ser diferente da origem.'
      USING ERRCODE = 'FA815', DETAIL = pg_catalog.format('Filial %s.', origin);
  END IF;
  IF destination IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.branch b JOIN public.company c ON c.id = b.company_id
     WHERE b.id = destination AND b.deleted_at IS NULL AND c.economic_group_id = group_id
  ) THEN
    RAISE EXCEPTION 'Um dos itens informados não foi encontrado.'
      USING ERRCODE = 'FA004', DETAIL = pg_catalog.format('Destino %s.', destination);
  END IF;

  IF NOT app.batch_required(product, origin) THEN
    IF batch_number IS NOT NULL THEN
      RAISE EXCEPTION 'Este produto não controla lote nesta filial.'
        USING ERRCODE = 'FA803', DETAIL = pg_catalog.format('Origem %s.', origin);
    END IF;
    -- Sem lote na origem não há validade nem MS para levar ao destino.
    IF app.batch_required(product, destination) THEN
      RAISE EXCEPTION 'Sem lote na origem, o produto não entra onde o lote é obrigatório.'
        USING ERRCODE = 'FA817', DETAIL = pg_catalog.format('Origem %s, destino %s.', origin, destination);
    END IF;
    INSERT INTO public.stock_movement (economic_group_id, branch_id, product_id, movement_type, quantity, reason, transfer_group)
    VALUES (group_id, origin, product, 'transfer', -amount, clean_reason, transfer),
           (group_id, destination, product, 'transfer', amount, clean_reason, transfer);
    RETURN transfer;
  END IF;

  IF batch_number IS NOT NULL THEN
    chosen := app.find_batch(origin, product, batch_number);
    overridden := app.check_chosen_batch(product, origin, chosen);
  END IF;

  FOR part IN
    SELECT chosen AS batch_id, amount AS quantity WHERE chosen IS NOT NULL
    UNION ALL
    SELECT a.batch_id, a.quantity FROM app.allocate_batches(product, origin, amount) a WHERE chosen IS NULL
  LOOP
    SELECT * INTO source FROM public.product_batch pb WHERE pb.id = part.batch_id;
    target_batch := NULL;
    IF app.batch_required(product, destination) THEN
      target_batch := app.batch_for_entry(
        group_id, destination, product, source.batch_number, source.expires_on, source.ms_registration
      );
    END IF;
    INSERT INTO public.stock_movement (
      economic_group_id, branch_id, product_id, batch_id, movement_type, quantity, reason, transfer_group, fefo_override
    ) VALUES
      (group_id, origin, product, part.batch_id, 'transfer', -part.quantity, clean_reason, transfer, overridden),
      (group_id, destination, product, target_batch, 'transfer', part.quantity, clean_reason, transfer, false);
  END LOOP;
  RETURN transfer;
END;
$$;

-- Inventário simples: informa o que foi contado, e a diferença vira movimentação.
-- Contagem igual ao saldo não gera nada e devolve vazio.
CREATE FUNCTION app.count_stock(p_data jsonb) RETURNS uuid
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
    -- Achou na prateleira um lote que o sistema não conhecia: nasce aqui, com validade.
    batch := CASE WHEN counted > 0
      THEN app.batch_for_entry(group_id, branch, product, batch_number, (p_data ->> 'expiresOn')::date, p_data ->> 'msRegistration')
      ELSE app.find_batch(branch, product, batch_number)
    END;
  END IF;

  -- Trava a linha do saldo antes de ler, para a diferença não ficar velha.
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
  RETURN new_id;
END;
$$;

-- O que o status permite nesta filial, conforme o saldo. A venda e a compra vão consultar aqui.
-- Lote vencido não conta como saldo vendável.
CREATE FUNCTION app.product_availability(p_product_id uuid, p_branch_id uuid)
RETURNS TABLE (status text, sellable_quantity numeric, sellable boolean, auto_purchase boolean, notice text)
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  WITH base AS (
    SELECT s.status,
           COALESCE((
             SELECT pg_catalog.sum(sb.quantity)
               FROM public.stock_balance sb
               LEFT JOIN public.product_batch pb ON pb.id = sb.batch_id
              WHERE sb.product_id = s.product_id AND sb.branch_id = s.branch_id AND sb.deleted_at IS NULL
                AND (pb.id IS NULL OR pb.expires_on >= app.local_today())
           ), 0) AS quantity
      FROM public.product_branch_status s
     WHERE s.product_id = p_product_id AND s.branch_id = p_branch_id AND s.deleted_at IS NULL
  )
  SELECT base.status, base.quantity,
         CASE base.status
           WHEN 'active' THEN true
           WHEN 'on_order' THEN true
           ELSE base.quantity > 0
         END,
         base.status = 'active',
         CASE
           WHEN base.status = 'on_order' AND base.quantity <= 0 THEN 'on_order_without_stock'
           WHEN base.status IN ('blocked', 'inactive') AND base.quantity <= 0 THEN 'unavailable'
           WHEN base.status IN ('blocked', 'inactive') THEN 'remaining_stock_only'
         END
    FROM base
$$;

-- Destinos possíveis: quem transfere da própria loja precisa enxergar as outras filiais do
-- grupo, mesmo sem ver o estoque delas. Só o nome sai daqui.
CREATE FUNCTION app.transfer_destinations()
RETURNS TABLE (id uuid, name text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT b.id, b.name
    FROM public.branch b
    JOIN public.company c ON c.id = b.company_id
   WHERE b.deleted_at IS NULL
     AND c.economic_group_id = app.current_user_group()
     AND app.has_permission_anywhere('stock.transfer')
   ORDER BY b.name
$$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  app.transfer_destinations(),
  app.transfer_stock(jsonb),
  app.count_stock(jsonb),
  app.product_availability(uuid, uuid)
TO farmaerp_app;
