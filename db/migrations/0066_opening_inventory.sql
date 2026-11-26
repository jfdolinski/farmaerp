-- Up Migration

-- Inventário de abertura (E1): a contagem de uma filial inteira, com data e hora de corte.
-- * A contagem entra por planilha (cada arquivo soma, para contar por seção) e por digitação
--   (que define a quantidade). Produto pelo código de barras, código interno ou código anterior.
-- * Produto que exige lote é contado por lote, com validade; nos outros, o lote é ignorado.
-- * A diferença é contra o saldo no corte (só os movimentos até ele): o caixa continua vendendo.
-- * Ao aplicar, o que foi contado vira o saldo; o que tinha saldo e não foi contado vai a zero.
--   Cada diferença é um movimento "inventory" na hora do corte, ligado ao inventário.
-- * Sem custo e fora do SNGPC (o inventário dos controlados tem a tela própria).

INSERT INTO permission (code, module, name) VALUES
  ('stock.opening', 'Estoque', 'Fazer o inventário de abertura da filial');

CREATE TABLE stock_count (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  branch_id uuid NOT NULL REFERENCES branch (id),
  kind text NOT NULL DEFAULT 'opening' CONSTRAINT stock_count_kind_check CHECK (kind IN ('opening')),
  status text NOT NULL DEFAULT 'counting' CONSTRAINT stock_count_status_check CHECK (status IN ('counting', 'applied', 'canceled')),
  -- Momento a que a contagem se refere.
  cutoff_at timestamptz NOT NULL,
  note text CONSTRAINT stock_count_note_check CHECK (length(note) <= 200),
  created_by uuid REFERENCES user_account (id),
  applied_at timestamptz,
  applied_by uuid REFERENCES user_account (id),
  -- Resumo do que foi aplicado.
  totals jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid,
  CONSTRAINT stock_count_applied_check CHECK ((status = 'applied') = (applied_at IS NOT NULL))
);
-- Um inventário em contagem por filial.
CREATE UNIQUE INDEX stock_count_open_key ON stock_count (branch_id) WHERE status = 'counting' AND deleted_at IS NULL;
CREATE INDEX stock_count_branch_idx ON stock_count (branch_id, created_at DESC);
CREATE INDEX stock_count_economic_group_id_idx ON stock_count (economic_group_id);
CALL app.apply_table_standard('public.stock_count');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON stock_count
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns('economic_group_id', 'branch_id', 'kind', 'cutoff_at', 'created_by');
CREATE POLICY stock_count_select ON stock_count FOR SELECT TO farmaerp_app
  USING (branch_id = ANY (app.allowed_branch_ids()));
CREATE VIEW v_stock_count WITH (security_invoker = true) AS SELECT * FROM stock_count WHERE deleted_at IS NULL;
GRANT SELECT ON stock_count, v_stock_count TO farmaerp_app;

CREATE TABLE stock_count_item (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  count_id uuid NOT NULL REFERENCES stock_count (id),
  product_id uuid NOT NULL REFERENCES product (id),
  -- Só nos produtos que exigem lote (em maiúsculas, sem espaços nas pontas).
  batch_number text CONSTRAINT stock_count_item_batch_check CHECK (batch_number = pg_catalog.upper(pg_catalog.btrim(batch_number)) AND length(batch_number) BETWEEN 1 AND 30),
  expires_on date,
  quantity numeric(14, 3) NOT NULL CONSTRAINT stock_count_item_quantity_check CHECK (quantity >= 0),
  source text NOT NULL CONSTRAINT stock_count_item_source_check CHECK (source IN ('file', 'typed')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid,
  CONSTRAINT stock_count_item_expiry_check CHECK ((batch_number IS NULL) = (expires_on IS NULL))
);
CREATE UNIQUE INDEX stock_count_item_key ON stock_count_item (count_id, product_id, COALESCE(batch_number, '')) WHERE deleted_at IS NULL;
CREATE INDEX stock_count_item_product_idx ON stock_count_item (product_id);
CREATE INDEX stock_count_item_economic_group_id_idx ON stock_count_item (economic_group_id);
CALL app.apply_table_standard('public.stock_count_item');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON stock_count_item
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns('economic_group_id', 'count_id', 'product_id', 'batch_number');
CREATE POLICY stock_count_item_select ON stock_count_item FOR SELECT TO farmaerp_app
  USING (EXISTS (SELECT 1 FROM stock_count c WHERE c.id = stock_count_item.count_id));
CREATE VIEW v_stock_count_item WITH (security_invoker = true) AS SELECT * FROM stock_count_item WHERE deleted_at IS NULL;
GRANT SELECT ON stock_count_item, v_stock_count_item TO farmaerp_app;

ALTER TABLE stock_movement ADD COLUMN stock_count_id uuid REFERENCES stock_count (id);
ALTER TABLE stock_movement ADD CONSTRAINT stock_movement_stock_count_check
  CHECK (stock_count_id IS NULL OR movement_type = 'inventory');
CREATE INDEX stock_movement_stock_count_idx ON stock_movement (stock_count_id) WHERE stock_count_id IS NOT NULL;

-- O inventário de abertura não entra no SNGPC.
DROP TRIGGER track_sngpc_movement ON stock_movement;
CREATE TRIGGER track_sngpc_movement AFTER INSERT ON stock_movement
  FOR EACH ROW WHEN (NEW.movement_type <> 'import' AND NEW.stock_count_id IS NULL) EXECUTE FUNCTION app.track_sngpc_movement();

CREATE OR REPLACE FUNCTION app.validate_stock_movement() RETURNS trigger
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

  -- Devolução de venda: volta para os lotes que saíram (ou sem lote, se a venda saiu sem).
  IF NEW.movement_type = 'return' AND NEW.sale_return_item_id IS NOT NULL THEN
    RETURN NEW;
  END IF;

  -- Nota importada do sistema anterior (venda, compra, transferência...): já aconteceu, sem lote.
  IF NEW.movement_type = 'import' AND (NEW.imported_sale_item_id IS NOT NULL OR NEW.imported_stock_item_id IS NOT NULL) THEN
    RETURN NEW;
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
    -- Inventário de abertura: a contagem é por lote; o saldo antigo sem lote (das notas importadas)
    -- vai a zero sem lote.
    IF NEW.batch_id IS NULL AND NEW.stock_count_id IS NOT NULL THEN
      RETURN NEW;
    END IF;
    -- Só uma saída sem lote é aceita, para zerar o saldo antigo de um produto que passou a
    -- exigir lote. Sem isso, esse saldo não teria como ser regularizado.
    -- A venda também sai sem lote quando o produto ainda não tem nenhum lote na filial: a venda já
    -- aconteceu, e a regularização fica para a retaguarda.
    IF NEW.batch_id IS NULL AND NOT (
      NEW.movement_type = 'sale' AND NEW.quantity < 0 AND NOT EXISTS (
        SELECT 1 FROM public.product_batch pb
         WHERE pb.branch_id = NEW.branch_id AND pb.product_id = NEW.product_id AND pb.deleted_at IS NULL
      )
    ) AND NOT (
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


-- Venda, venda importada e inventário com corte podem deixar o saldo negativo: já aconteceram.
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

  IF NEW.quantity < 0 AND new_quantity < 0 AND NEW.movement_type NOT IN ('sale', 'import') AND NEW.stock_count_id IS NULL THEN
    RAISE EXCEPTION 'A quantidade é maior que o saldo disponível.'
      USING ERRCODE = 'FA801',
            DETAIL = pg_catalog.format('Produto %s, filial %s, lote %s, saldo ficaria %s.', NEW.product_id, NEW.branch_id, NEW.batch_id, new_quantity);
  END IF;
  RETURN NULL;
END;
$$;


-- Inventário da filial em contagem, travado para a operação, com a permissão conferida.
CREATE FUNCTION app.stock_count_for_change(p_count_id uuid) RETURNS public.stock_count
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.stock_count;
BEGIN
  SELECT * INTO target FROM public.stock_count c
   WHERE c.id = p_count_id AND c.economic_group_id = app.current_user_group() AND c.deleted_at IS NULL
   FOR UPDATE;
  IF target.id IS NULL OR NOT app.has_permission('stock.opening', target.branch_id) THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('stock_count %s.', p_count_id);
  END IF;
  IF target.status <> 'counting' THEN
    RAISE EXCEPTION 'Este inventário não pode mais ser alterado.'
      USING ERRCODE = 'FA745', DETAIL = pg_catalog.format('stock_count %s em %s.', target.id, target.status);
  END IF;
  RETURN target;
END;
$$;

-- Produto pelo código de barras, código interno ou código do sistema anterior.
CREATE FUNCTION app.stock_count_product(p_lookup text) RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE(
    app.find_product_id(p_lookup),
    (SELECT p.id FROM public.product p
      WHERE p.economic_group_id = app.current_user_group() AND p.legacy_code = pg_catalog.btrim(p_lookup) AND p.deleted_at IS NULL
      LIMIT 1)
  )
$$;

-- Abre o inventário da filial. O corte não pode estar no futuro nem antes de outro já aplicado.
CREATE FUNCTION app.create_stock_count(p_branch_id uuid, p_cutoff_at timestamptz, p_note text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.current_user_group();
  new_id uuid;
BEGIN
  IF NOT app.has_permission('stock.opening', p_branch_id) OR NOT EXISTS (
    SELECT 1 FROM public.branch b JOIN public.company c ON c.id = b.company_id
     WHERE b.id = p_branch_id AND b.deleted_at IS NULL AND c.economic_group_id = group_id
  ) THEN
    RAISE EXCEPTION 'Você não tem permissão para esta operação.'
      USING ERRCODE = 'FA002', DETAIL = 'Inventário sem stock.opening na filial.';
  END IF;
  IF p_cutoff_at IS NULL OR p_cutoff_at > pg_catalog.now() + interval '5 minutes' OR EXISTS (
    SELECT 1 FROM public.stock_count c
     WHERE c.branch_id = p_branch_id AND c.status = 'applied' AND c.deleted_at IS NULL AND c.cutoff_at >= p_cutoff_at
  ) THEN
    RAISE EXCEPTION 'A data e hora de corte do inventário são inválidas.'
      USING ERRCODE = 'FA747', DETAIL = 'Corte no futuro ou antes de um inventário já aplicado.';
  END IF;
  IF EXISTS (SELECT 1 FROM public.stock_count c WHERE c.branch_id = p_branch_id AND c.status = 'counting' AND c.deleted_at IS NULL) THEN
    RAISE EXCEPTION 'Já existe um inventário em contagem nesta filial.'
      USING ERRCODE = 'FA744', DETAIL = pg_catalog.format('Filial %s.', p_branch_id);
  END IF;
  INSERT INTO public.stock_count (economic_group_id, branch_id, cutoff_at, note, created_by)
  VALUES (group_id, p_branch_id, p_cutoff_at, NULLIF(pg_catalog.left(pg_catalog.btrim(COALESCE(p_note, '')), 200), ''), app.current_user_id())
  RETURNING id INTO new_id;
  RETURN new_id;
END;
$$;

-- Grava uma linha da contagem. p_add soma (planilha) ou define (digitação). Devolve o motivo da
-- recusa, ou NULL se gravou.
CREATE FUNCTION app.stock_count_put(
  p_count public.stock_count, p_lookup text, p_batch text, p_expires_on date, p_quantity numeric, p_add boolean
) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_product uuid := app.stock_count_product(p_lookup);
  v_batch text := NULLIF(pg_catalog.upper(pg_catalog.btrim(COALESCE(p_batch, ''))), '');
  v_expires date := p_expires_on;
  v_existing public.stock_count_item;
BEGIN
  IF v_product IS NULL THEN
    RETURN 'Produto não encontrado pelo código.';
  END IF;
  IF p_quantity IS NULL OR p_quantity < 0 OR p_quantity <> pg_catalog.round(p_quantity, 3) OR p_quantity > 99999999 THEN
    RETURN 'Quantidade inválida.';
  END IF;
  IF app.batch_required(v_product, p_count.branch_id) THEN
    IF v_batch IS NULL OR v_expires IS NULL OR pg_catalog.length(v_batch) > 30 THEN
      RETURN 'Produto que exige lote: informe o lote e a validade.';
    END IF;
  ELSE
    -- Produto sem controle de lote: o lote é ignorado.
    v_batch := NULL;
    v_expires := NULL;
  END IF;
  SELECT * INTO v_existing FROM public.stock_count_item i
   WHERE i.count_id = p_count.id AND i.product_id = v_product AND i.batch_number IS NOT DISTINCT FROM v_batch AND i.deleted_at IS NULL
   FOR UPDATE;
  IF v_existing.id IS NOT NULL THEN
    UPDATE public.stock_count_item i
       SET quantity = CASE WHEN p_add THEN i.quantity + p_quantity ELSE p_quantity END,
           expires_on = v_expires, source = CASE WHEN p_add THEN i.source ELSE 'typed' END
     WHERE i.id = v_existing.id;
  ELSE
    INSERT INTO public.stock_count_item (economic_group_id, count_id, product_id, batch_number, expires_on, quantity, source)
    VALUES (p_count.economic_group_id, p_count.id, v_product, v_batch, v_expires, p_quantity, CASE WHEN p_add THEN 'file' ELSE 'typed' END);
  END IF;
  RETURN NULL;
END;
$$;

-- Planilha já lida pela API: [{line, lookup, quantity, batch, expires_on}]. Cada arquivo soma ao
-- que já foi contado (dá para contar por seção). Linha com problema não para as outras.
CREATE FUNCTION app.stock_count_load(p_count_id uuid, p_rows jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.stock_count := app.stock_count_for_change(p_count_id);
  v_row jsonb;
  v_reason text;
  v_quantity numeric;
  v_expires date;
  accepted integer := 0;
  rejected jsonb := '[]'::jsonb;
BEGIN
  IF pg_catalog.jsonb_typeof(p_rows) <> 'array' OR pg_catalog.jsonb_array_length(p_rows) > 50000 THEN
    RAISE EXCEPTION 'Alguns dados informados são inválidos.' USING ERRCODE = 'FA005', DETAIL = 'Planilha fora do formato.';
  END IF;
  FOR v_row IN SELECT value FROM pg_catalog.jsonb_array_elements(p_rows) LOOP
    BEGIN
      v_quantity := (v_row ->> 'quantity')::numeric;
      v_expires := NULLIF(v_row ->> 'expires_on', '')::date;
      v_reason := app.stock_count_put(target, v_row ->> 'lookup', v_row ->> 'batch', v_expires, v_quantity, true);
    EXCEPTION WHEN invalid_text_representation OR invalid_datetime_format OR datetime_field_overflow OR numeric_value_out_of_range THEN
      v_reason := 'Quantidade ou validade fora do formato.';
    END;
    IF v_reason IS NULL THEN
      accepted := accepted + 1;
    ELSIF pg_catalog.jsonb_array_length(rejected) < 1000 THEN
      rejected := rejected || pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
        'line', v_row -> 'line', 'lookup', pg_catalog.left(v_row ->> 'lookup', 60), 'reason', v_reason));
    END IF;
  END LOOP;
  RETURN pg_catalog.jsonb_build_object(
    'accepted', accepted, 'rejected', rejected,
    'rejected_total', pg_catalog.jsonb_array_length(p_rows) - accepted);
END;
$$;

-- Digitação: define a quantidade da linha (produto e lote).
CREATE FUNCTION app.stock_count_set_item(p_count_id uuid, p_lookup text, p_batch text, p_expires_on date, p_quantity numeric)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.stock_count := app.stock_count_for_change(p_count_id);
  v_reason text := app.stock_count_put(target, p_lookup, p_batch, p_expires_on, p_quantity, false);
BEGIN
  IF v_reason = 'Produto não encontrado pelo código.' THEN
    RAISE EXCEPTION 'Um dos itens informados não foi encontrado.' USING ERRCODE = 'FA004', DETAIL = 'Produto não localizado.';
  ELSIF v_reason LIKE 'Produto que exige lote%' THEN
    RAISE EXCEPTION 'Produto que exige lote precisa de lote e validade na contagem.' USING ERRCODE = 'FA746', DETAIL = v_reason;
  ELSIF v_reason IS NOT NULL THEN
    RAISE EXCEPTION 'Os dados da movimentação são inválidos.' USING ERRCODE = 'FA810', DETAIL = v_reason;
  END IF;
END;
$$;

-- Tira uma linha da contagem.
CREATE FUNCTION app.stock_count_remove_item(p_item_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_item public.stock_count_item;
BEGIN
  SELECT * INTO v_item FROM public.stock_count_item i WHERE i.id = p_item_id AND i.deleted_at IS NULL;
  IF v_item.id IS NULL THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.' USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('stock_count_item %s.', p_item_id);
  END IF;
  PERFORM app.stock_count_for_change(v_item.count_id);
  UPDATE public.stock_count_item i SET deleted_at = pg_catalog.now() WHERE i.id = v_item.id;
END;
$$;

-- Conferência: cada produto e lote com o saldo no corte, o contado e a diferença. Entra o que
-- foi contado e o que tinha saldo no corte (esse, sem contagem, vai a zero). problem diz o que
-- impede aplicar.
CREATE FUNCTION app.stock_count_review(p_count_id uuid)
RETURNS TABLE (
  product_id uuid, product_code bigint, product_name text, batch_number text, expires_on date, expected numeric,
  counted numeric, difference numeric, was_counted boolean, problem text
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.stock_count;
BEGIN
  SELECT * INTO target FROM public.stock_count c
   WHERE c.id = p_count_id AND c.economic_group_id = app.current_user_group() AND c.deleted_at IS NULL;
  IF target.id IS NULL OR NOT (app.has_permission('stock.opening', target.branch_id) OR app.has_permission('stock.view', target.branch_id)) THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('stock_count %s.', p_count_id);
  END IF;
  RETURN QUERY
  WITH expected_rows AS (
    SELECT m.product_id, pb.batch_number AS batch_key, pg_catalog.sum(m.quantity) AS quantity
      FROM public.stock_movement m
      LEFT JOIN public.product_batch pb ON pb.id = m.batch_id
     WHERE m.branch_id = target.branch_id AND m.deleted_at IS NULL AND m.occurred_at <= target.cutoff_at
       AND (m.stock_count_id IS NULL OR m.stock_count_id <> target.id)
     GROUP BY m.product_id, pb.batch_number
    HAVING pg_catalog.sum(m.quantity) <> 0
  ),
  counted_rows AS (
    SELECT i.product_id, i.batch_number AS batch_key, i.expires_on, i.quantity
      FROM public.stock_count_item i
     WHERE i.count_id = target.id AND i.deleted_at IS NULL
  ),
  joined AS (
    SELECT COALESCE(c.product_id, e.product_id) AS product_id,
           COALESCE(c.batch_key, e.batch_key) AS batch_key,
           c.expires_on, COALESCE(e.quantity, 0) AS expected, COALESCE(c.quantity, 0) AS counted, c.product_id IS NOT NULL AS was_counted
      FROM counted_rows c
      FULL JOIN expected_rows e
        ON e.product_id = c.product_id AND pg_catalog.upper(COALESCE(e.batch_key, '')) = COALESCE(c.batch_key, '')
  )
  SELECT j.product_id, p.code, p.display_name, j.batch_key,
         COALESCE(j.expires_on, pb.expires_on), j.expected, j.counted, j.counted - j.expected, j.was_counted,
         CASE
           WHEN j.was_counted AND j.batch_key IS NOT NULL AND pb.id IS NOT NULL AND pb.expires_on <> j.expires_on
             THEN 'O lote já existe com a validade ' || pg_catalog.to_char(pb.expires_on, 'DD/MM/YYYY') || '.'
           WHEN j.was_counted AND j.batch_key IS NULL AND app.batch_required(j.product_id, target.branch_id)
             THEN 'Produto que exige lote: conte por lote.'
         END
    FROM joined j
    JOIN public.product p ON p.id = j.product_id
    LEFT JOIN public.product_batch pb
      ON pb.branch_id = target.branch_id AND pb.product_id = j.product_id AND pg_catalog.upper(pb.batch_number) = j.batch_key AND pb.deleted_at IS NULL
   ORDER BY p.display_name, p.code, j.batch_key NULLS FIRST;
END;
$$;

-- Aplica: cada diferença vira um movimento de inventário na hora do corte. Com problema, não aplica.
CREATE FUNCTION app.apply_stock_count(p_count_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.stock_count := app.stock_count_for_change(p_count_id);
  v_line record;
  v_batch uuid;
  v_problems integer;
  v_totals jsonb;
  v_up integer := 0;
  v_down integer := 0;
  v_zeroed integer := 0;
  v_counted integer;
BEGIN
  SELECT pg_catalog.count(*) INTO v_problems FROM app.stock_count_review(target.id) r WHERE r.problem IS NOT NULL;
  IF v_problems > 0 THEN
    RAISE EXCEPTION 'Produto que exige lote precisa de lote e validade na contagem.'
      USING ERRCODE = 'FA746', DETAIL = pg_catalog.format('%s linha(s) com problema na conferência.', v_problems);
  END IF;
  SELECT pg_catalog.count(*) INTO v_counted FROM public.stock_count_item i WHERE i.count_id = target.id AND i.deleted_at IS NULL;
  FOR v_line IN SELECT * FROM app.stock_count_review(target.id) r WHERE r.difference <> 0 LOOP
    v_batch := NULL;
    IF v_line.batch_number IS NOT NULL THEN
      SELECT pb.id INTO v_batch FROM public.product_batch pb
       WHERE pb.branch_id = target.branch_id AND pb.product_id = v_line.product_id
         AND pg_catalog.upper(pb.batch_number) = v_line.batch_number AND pb.deleted_at IS NULL;
      IF v_batch IS NULL THEN
        v_batch := app.batch_for_entry(target.economic_group_id, target.branch_id, v_line.product_id, v_line.batch_number, v_line.expires_on, NULL);
      END IF;
    END IF;
    INSERT INTO public.stock_movement (economic_group_id, branch_id, product_id, batch_id, movement_type, quantity, occurred_at, reason, stock_count_id)
    VALUES (target.economic_group_id, target.branch_id, v_line.product_id, v_batch, 'inventory', v_line.difference, target.cutoff_at,
            'Inventário de abertura', target.id);
    IF NOT v_line.was_counted THEN
      v_zeroed := v_zeroed + 1;
    ELSIF v_line.difference > 0 THEN
      v_up := v_up + 1;
    ELSE
      v_down := v_down + 1;
    END IF;
  END LOOP;
  v_totals := pg_catalog.jsonb_build_object('counted_lines', v_counted, 'raised', v_up, 'lowered', v_down, 'zeroed', v_zeroed);
  UPDATE public.stock_count c
     SET status = 'applied', applied_at = pg_catalog.now(), applied_by = app.current_user_id(), totals = v_totals
   WHERE c.id = target.id;
  RETURN v_totals;
END;
$$;

-- Desiste do inventário em contagem (nada muda no estoque).
CREATE FUNCTION app.cancel_stock_count(p_count_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.stock_count := app.stock_count_for_change(p_count_id);
BEGIN
  UPDATE public.stock_count c SET status = 'canceled' WHERE c.id = target.id;
END;
$$;

-- Inventários das filiais que o usuário vê.
CREATE FUNCTION app.list_stock_counts(p_branch_id uuid DEFAULT NULL)
RETURNS TABLE (
  id uuid, branch_id uuid, branch_name text, kind text, status text, cutoff_at timestamptz, note text, item_count integer,
  totals jsonb, created_at timestamptz, created_by_name text, applied_at timestamptz, applied_by_name text, can_change boolean
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT c.id, c.branch_id, b.name, c.kind, c.status, c.cutoff_at, c.note,
         (SELECT pg_catalog.count(*)::integer FROM public.stock_count_item i WHERE i.count_id = c.id AND i.deleted_at IS NULL),
         c.totals, c.created_at, cu.name, c.applied_at, au.name,
         c.status = 'counting' AND app.has_permission('stock.opening', c.branch_id)
    FROM public.stock_count c
    JOIN public.branch b ON b.id = c.branch_id
    LEFT JOIN public.user_account cu ON cu.id = c.created_by
    LEFT JOIN public.user_account au ON au.id = c.applied_by
   WHERE c.deleted_at IS NULL AND c.economic_group_id = app.current_user_group()
     AND (app.has_permission('stock.opening', c.branch_id) OR app.has_permission('stock.view', c.branch_id))
     AND (p_branch_id IS NULL OR c.branch_id = p_branch_id)
   ORDER BY c.created_at DESC
   LIMIT 100
$$;

-- Linhas contadas (para editar na tela).
CREATE FUNCTION app.stock_count_items(p_count_id uuid)
RETURNS TABLE (
  id uuid, product_id uuid, product_code bigint, product_name text, batch_number text, expires_on date, quantity numeric,
  source text, updated_at timestamptz
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT i.id, i.product_id, p.code, p.display_name, i.batch_number, i.expires_on, i.quantity, i.source, i.updated_at
    FROM public.stock_count_item i
    JOIN public.stock_count c ON c.id = i.count_id
    JOIN public.product p ON p.id = i.product_id
   WHERE i.count_id = p_count_id AND i.deleted_at IS NULL AND c.deleted_at IS NULL
     AND c.economic_group_id = app.current_user_group()
     AND (app.has_permission('stock.opening', c.branch_id) OR app.has_permission('stock.view', c.branch_id))
   ORDER BY p.display_name, p.code, i.batch_number NULLS FIRST
$$;

REVOKE ALL ON FUNCTION
  app.stock_count_for_change(uuid),
  app.stock_count_product(text),
  app.create_stock_count(uuid, timestamptz, text),
  app.stock_count_put(public.stock_count, text, text, date, numeric, boolean),
  app.stock_count_load(uuid, jsonb),
  app.stock_count_set_item(uuid, text, text, date, numeric),
  app.stock_count_remove_item(uuid),
  app.stock_count_review(uuid),
  app.apply_stock_count(uuid),
  app.cancel_stock_count(uuid),
  app.list_stock_counts(uuid),
  app.stock_count_items(uuid)
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  app.create_stock_count(uuid, timestamptz, text),
  app.stock_count_load(uuid, jsonb),
  app.stock_count_set_item(uuid, text, text, date, numeric),
  app.stock_count_remove_item(uuid),
  app.stock_count_review(uuid),
  app.apply_stock_count(uuid),
  app.cancel_stock_count(uuid),
  app.list_stock_counts(uuid),
  app.stock_count_items(uuid)
TO farmaerp_app;
