-- Up Migration

-- Parte E1 do lote de 26/11: manutenção das notas de entrada.
-- 1. Tudo o que o XML traz fica guardado na nota (content: o trecho assinado infNFe, lido pela API)
--    e as duplicatas da cobrança viram o financeiro da nota (purchase_invoice_installment). As notas
--    já recebidas são lidas por uma rotina da API, do XML que já está guardado.
-- 2. Auditoria das alterações: além de lançada e estornada (purchase_invoice_event), ficam
--    registrados o item ligado ou desligado de um produto, lote incluído ou tirado na conferência,
--    custo liberado e nota descartada, com quem, quando e o que mudou.

ALTER TABLE purchase_invoice ADD COLUMN content jsonb
  CONSTRAINT purchase_invoice_content_check CHECK (content IS NULL OR jsonb_typeof(content) = 'object');
ALTER TABLE purchase_invoice ADD COLUMN content_read_at timestamptz;
ALTER TABLE purchase_invoice ADD COLUMN content_error text
  CONSTRAINT purchase_invoice_content_error_check CHECK (length(content_error) BETWEEN 1 AND 500);
ALTER TABLE purchase_invoice ADD CONSTRAINT purchase_invoice_content_read_check
  CHECK ((content IS NULL) = (content_read_at IS NULL));
CREATE INDEX purchase_invoice_content_pending_idx ON purchase_invoice (created_at)
  WHERE content IS NULL AND content_error IS NULL;

-- O conteúdo lido é o do XML autorizado: entra uma vez e não muda mais.
CREATE FUNCTION app.block_purchase_content_change() RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF OLD.content IS NOT NULL AND (NEW.content IS DISTINCT FROM OLD.content OR NEW.content_read_at IS DISTINCT FROM OLD.content_read_at) THEN
    RAISE EXCEPTION 'Este dado não pode ser alterado depois do cadastro.' USING ERRCODE = 'FA104', DETAIL = 'Conteúdo da nota já lido.';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER block_content_change BEFORE UPDATE OF content, content_read_at ON purchase_invoice
  FOR EACH ROW EXECUTE FUNCTION app.block_purchase_content_change();

-- Duplicatas da cobrança (tag cobr/dup): o financeiro da nota.
CREATE TABLE purchase_invoice_installment (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  branch_id uuid NOT NULL REFERENCES branch (id),
  invoice_id uuid NOT NULL REFERENCES purchase_invoice (id),
  line smallint NOT NULL CONSTRAINT purchase_invoice_installment_line_check CHECK (line BETWEEN 1 AND 120),
  number text CONSTRAINT purchase_invoice_installment_number_check CHECK (length(btrim(number)) BETWEEN 1 AND 60),
  due_date date,
  amount numeric(15, 2) NOT NULL CONSTRAINT purchase_invoice_installment_amount_check CHECK (amount >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE UNIQUE INDEX purchase_invoice_installment_line_key ON purchase_invoice_installment (invoice_id, line) WHERE deleted_at IS NULL;
CREATE INDEX purchase_invoice_installment_branch_due_idx ON purchase_invoice_installment (branch_id, due_date) WHERE deleted_at IS NULL;
CREATE INDEX purchase_invoice_installment_economic_group_id_idx ON purchase_invoice_installment (economic_group_id);
CALL app.apply_table_standard('public.purchase_invoice_installment');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON purchase_invoice_installment
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'branch_id', 'invoice_id', 'line', 'number', 'due_date', 'amount'
  );
CREATE POLICY purchase_invoice_installment_select ON purchase_invoice_installment FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group()) AND app.has_permission('purchases.view', branch_id));
CREATE VIEW v_purchase_invoice_installment WITH (security_invoker = true) AS
  SELECT * FROM purchase_invoice_installment WHERE deleted_at IS NULL;
GRANT SELECT ON purchase_invoice_installment, v_purchase_invoice_installment TO farmaerp_app;

-- Alterações da nota além de lançar e estornar. Ninguém altera.
CREATE TABLE purchase_invoice_audit (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  branch_id uuid NOT NULL REFERENCES branch (id),
  invoice_id uuid NOT NULL REFERENCES purchase_invoice (id),
  kind text NOT NULL CONSTRAINT purchase_invoice_audit_kind_check CHECK (kind IN (
    'linked', 'unlinked', 'batch_added', 'batch_removed', 'cost_released', 'discarded'
  )),
  detail jsonb NOT NULL CONSTRAINT purchase_invoice_audit_detail_check CHECK (jsonb_typeof(detail) = 'object'),
  user_id uuid REFERENCES user_account (id),
  occurred_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE INDEX purchase_invoice_audit_invoice_idx ON purchase_invoice_audit (invoice_id, occurred_at DESC);
CREATE INDEX purchase_invoice_audit_branch_id_idx ON purchase_invoice_audit (branch_id);
CREATE INDEX purchase_invoice_audit_user_id_idx ON purchase_invoice_audit (user_id);
CREATE INDEX purchase_invoice_audit_economic_group_id_idx ON purchase_invoice_audit (economic_group_id);
CALL app.apply_table_standard('public.purchase_invoice_audit');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON purchase_invoice_audit
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'branch_id', 'invoice_id', 'kind', 'detail', 'user_id', 'occurred_at', 'deleted_at'
  );
CREATE POLICY purchase_invoice_audit_select ON purchase_invoice_audit FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group()) AND app.has_permission('purchases.view', branch_id));
CREATE VIEW v_purchase_invoice_audit WITH (security_invoker = true) AS SELECT * FROM purchase_invoice_audit WHERE deleted_at IS NULL;
GRANT SELECT ON purchase_invoice_audit, v_purchase_invoice_audit TO farmaerp_app;

CREATE FUNCTION app.record_purchase_audit(p_invoice_id uuid, p_kind text, p_detail jsonb) RETURNS void
LANGUAGE sql SECURITY DEFINER
SET search_path = ''
AS $$
  INSERT INTO public.purchase_invoice_audit (economic_group_id, branch_id, invoice_id, kind, detail, user_id)
  SELECT i.economic_group_id, i.branch_id, i.id, p_kind, p_detail, app.current_user_id()
    FROM public.purchase_invoice i WHERE i.id = p_invoice_id
$$;

-- Item ligado (ou desligado) de um produto. A ligação automática feita na própria importação (pelo
-- código do fornecedor ou de barras, na mesma transação que criou o item) faz parte da nota e não
-- entra; a manual sempre entra, e a automática depois (produto cadastrado mais tarde) também.
CREATE FUNCTION app.audit_purchase_item_link() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF OLD.product_id IS NULL AND NEW.match_source IN ('supplier_code', 'barcode') AND OLD.created_at = pg_catalog.now() THEN
    RETURN NULL;
  END IF;
  PERFORM app.record_purchase_audit(NEW.invoice_id, CASE WHEN NEW.product_id IS NULL THEN 'unlinked' ELSE 'linked' END,
    pg_catalog.jsonb_build_object(
      'item_number', NEW.item_number, 'description', NEW.description, 'source', NEW.match_source,
      'product_id', NEW.product_id,
      'product', (SELECT p.code::text || ' · ' || p.display_name FROM public.product p WHERE p.id = NEW.product_id),
      'previous_product', (SELECT p.code::text || ' · ' || p.display_name FROM public.product p WHERE p.id = OLD.product_id)
    ));
  RETURN NULL;
END;
$$;
CREATE TRIGGER audit_link AFTER UPDATE OF product_id ON purchase_invoice_item
  FOR EACH ROW WHEN (OLD.product_id IS DISTINCT FROM NEW.product_id) EXECUTE FUNCTION app.audit_purchase_item_link();

-- Lote digitado na conferência (o do XML faz parte da nota) e lote que sai de uso.
CREATE FUNCTION app.audit_purchase_item_batch() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  item public.purchase_invoice_item;
BEGIN
  SELECT * INTO item FROM public.purchase_invoice_item i WHERE i.id = NEW.item_id;
  PERFORM app.record_purchase_audit(item.invoice_id, CASE WHEN TG_OP = 'INSERT' THEN 'batch_added' ELSE 'batch_removed' END,
    pg_catalog.jsonb_build_object(
      'item_number', item.item_number, 'description', item.description, 'batch_number', NEW.batch_number,
      'quantity', NEW.quantity, 'expires_on', NEW.expires_on, 'source', NEW.source
    ));
  RETURN NULL;
END;
$$;
CREATE TRIGGER audit_batch_added AFTER INSERT ON purchase_invoice_item_batch
  FOR EACH ROW WHEN (NEW.source = 'manual') EXECUTE FUNCTION app.audit_purchase_item_batch();
CREATE TRIGGER audit_batch_removed AFTER UPDATE OF deleted_at ON purchase_invoice_item_batch
  FOR EACH ROW WHEN (OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL) EXECUTE FUNCTION app.audit_purchase_item_batch();

-- Custo acima da tolerância liberado.
CREATE FUNCTION app.audit_purchase_cost_release() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  item public.purchase_invoice_item;
BEGIN
  SELECT * INTO item FROM public.purchase_invoice_item i WHERE i.id = NEW.item_id;
  PERFORM app.record_purchase_audit(item.invoice_id, 'cost_released', pg_catalog.jsonb_build_object(
    'item_number', item.item_number, 'description', item.description, 'entry_cost', NEW.entry_cost,
    'average_cost', NEW.average_cost, 'tolerance', NEW.tolerance, 'reason', NEW.reason
  ));
  RETURN NULL;
END;
$$;
CREATE TRIGGER audit_cost_release AFTER INSERT ON purchase_invoice_item_cost_release
  FOR EACH ROW EXECUTE FUNCTION app.audit_purchase_cost_release();

-- Nota descartada.
CREATE FUNCTION app.audit_purchase_discard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM app.record_purchase_audit(NEW.id, 'discarded', pg_catalog.jsonb_build_object('reason', NEW.discard_reason));
  RETURN NULL;
END;
$$;
CREATE TRIGGER audit_discard AFTER UPDATE OF deleted_at ON purchase_invoice
  FOR EACH ROW WHEN (OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL) EXECUTE FUNCTION app.audit_purchase_discard();

-- Rotina da API que lê as notas guardadas.
CREATE FUNCTION app.require_purchase_content_worker() RETURNS void
LANGUAGE plpgsql STABLE
SET search_path = ''
AS $$
BEGIN
  IF app.current_user_id() IS NOT NULL OR COALESCE(pg_catalog.current_setting('app.worker', true), '') <> 'purchase_content' THEN
    RAISE EXCEPTION 'Você não tem permissão para esta operação.'
      USING ERRCODE = 'FA002', DETAIL = 'Leitura da nota fora da rotina.';
  END IF;
END;
$$;

-- Notas ainda sem o conteúdo lido (as mais antigas primeiro), com o XML guardado.
CREATE FUNCTION app.purchase_content_pending(p_limit integer) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM app.require_purchase_content_worker();
  RETURN COALESCE((
    SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('id', x.id, 'xml', x.xml) ORDER BY x.created_at, x.id)
      FROM (
        SELECT i.id, i.created_at, d.xml FROM public.purchase_invoice i
          JOIN public.purchase_invoice_document d ON d.invoice_id = i.id AND d.deleted_at IS NULL
         WHERE i.content IS NULL AND i.content_error IS NULL
         ORDER BY i.created_at, i.id
         LIMIT LEAST(GREATEST(COALESCE(p_limit, 20), 1), 100)
      ) x
  ), '[]'::jsonb);
END;
$$;

-- Guarda o conteúdo lido e as duplicatas. Pela rotina ou por quem acabou de importar a nota. Já lido:
-- não faz nada.
CREATE FUNCTION app.store_purchase_content(p_invoice_id uuid, p_content jsonb, p_installments jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  invoice public.purchase_invoice;
  entry jsonb;
  line integer := 0;
  due date;
BEGIN
  SELECT * INTO invoice FROM public.purchase_invoice i WHERE i.id = p_invoice_id FOR UPDATE;
  IF invoice.id IS NULL THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.' USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('purchase_invoice %s.', p_invoice_id);
  END IF;
  IF app.current_user_id() IS NULL THEN
    PERFORM app.require_purchase_content_worker();
  ELSIF invoice.economic_group_id IS DISTINCT FROM app.current_user_group() OR NOT app.has_permission('purchases.manage', invoice.branch_id) THEN
    RAISE EXCEPTION 'Você não tem permissão para esta operação.' USING ERRCODE = 'FA002', DETAIL = 'Conteúdo da nota sem purchases.manage.';
  END IF;
  IF invoice.content IS NOT NULL THEN
    RETURN;
  END IF;
  IF pg_catalog.jsonb_typeof(p_content) IS DISTINCT FROM 'object' OR pg_catalog.jsonb_typeof(p_installments) IS DISTINCT FROM 'array'
     OR pg_catalog.jsonb_array_length(p_installments) > 120 THEN
    RAISE EXCEPTION 'Alguns dados informados são inválidos.' USING ERRCODE = 'FA005', DETAIL = 'Conteúdo da nota.';
  END IF;
  FOR entry IN SELECT value FROM pg_catalog.jsonb_array_elements(p_installments) LOOP
    line := line + 1;
    -- O vencimento (dVenc) e o número (nDup) são opcionais no leiaute; o valor (vDup), não.
    due := NULL;
    IF pg_catalog.jsonb_typeof(entry) IS DISTINCT FROM 'object'
       OR COALESCE(entry ->> 'amount', '') !~ '^\d{1,13}(\.\d{1,2})?$'
       OR COALESCE(entry ->> 'dueDate', '0000-00-00') !~ '^\d{4}-\d{2}-\d{2}$' THEN
      RAISE EXCEPTION 'Alguns dados informados são inválidos.' USING ERRCODE = 'FA005', DETAIL = pg_catalog.format('Duplicata %s.', line);
    END IF;
    IF entry ->> 'dueDate' IS NOT NULL THEN
      BEGIN
        due := (entry ->> 'dueDate')::date;
      EXCEPTION WHEN datetime_field_overflow OR invalid_datetime_format THEN
        RAISE EXCEPTION 'Alguns dados informados são inválidos.' USING ERRCODE = 'FA005', DETAIL = pg_catalog.format('Vencimento da duplicata %s.', line);
      END;
    END IF;
    INSERT INTO public.purchase_invoice_installment (economic_group_id, branch_id, invoice_id, line, number, due_date, amount)
    VALUES (invoice.economic_group_id, invoice.branch_id, invoice.id, line, NULLIF(pg_catalog.btrim(entry ->> 'number'), ''),
            due, (entry ->> 'amount')::numeric);
  END LOOP;
  UPDATE public.purchase_invoice i SET content = p_content, content_read_at = pg_catalog.now() WHERE i.id = invoice.id;
END;
$$;

-- XML que a rotina não conseguiu ler: fica marcado (e não volta para a fila).
CREATE FUNCTION app.purchase_content_failed(p_invoice_id uuid, p_reason text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM app.require_purchase_content_worker();
  UPDATE public.purchase_invoice i
     SET content_error = pg_catalog.left(COALESCE(NULLIF(pg_catalog.btrim(p_reason), ''), 'Falha na leitura do XML.'), 500)
   WHERE i.id = p_invoice_id AND i.content IS NULL;
END;
$$;

-- Detalhe extra da nota para a tela: o conteúdo do XML, as duplicatas e a auditoria completa
-- (lançada, estornada e as alterações), do mais novo para o mais antigo.
CREATE FUNCTION app.purchase_invoice_extra(p_invoice_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT pg_catalog.jsonb_build_object(
    'content', i.content, 'content_read_at', i.content_read_at, 'content_error', i.content_error,
    'installments', COALESCE((
      SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
               'line', x.line, 'number', x.number, 'due_date', x.due_date, 'amount', x.amount) ORDER BY x.line)
        FROM public.purchase_invoice_installment x WHERE x.invoice_id = i.id AND x.deleted_at IS NULL
    ), '[]'::jsonb),
    'audit', COALESCE((
      SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
               'kind', a.kind, 'detail', a.detail, 'user_name', u.name, 'occurred_at', a.occurred_at)
             ORDER BY a.occurred_at DESC)
        FROM (
          SELECT e.kind, CASE WHEN e.reason IS NULL THEN '{}'::jsonb ELSE pg_catalog.jsonb_build_object('reason', e.reason) END AS detail,
                 e.user_id, e.created_at AS occurred_at
            FROM public.purchase_invoice_event e WHERE e.invoice_id = i.id AND e.deleted_at IS NULL
          UNION ALL
          SELECT a.kind, a.detail, a.user_id, a.occurred_at
            FROM public.purchase_invoice_audit a WHERE a.invoice_id = i.id AND a.deleted_at IS NULL
        ) a
        LEFT JOIN public.user_account u ON u.id = a.user_id
    ), '[]'::jsonb)
  )
    FROM public.purchase_invoice i
   WHERE i.id = p_invoice_id AND i.economic_group_id = app.current_user_group() AND app.has_permission('purchases.view', i.branch_id)
$$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  app.purchase_content_pending(integer),
  app.store_purchase_content(uuid, jsonb, jsonb),
  app.purchase_content_failed(uuid, text),
  app.purchase_invoice_extra(uuid)
TO farmaerp_app;
