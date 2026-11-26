-- Up Migration

-- Importação das notas já emitidas pelo cliente (.zip), começando pela NFC-e (modelo 65).
-- A retaguarda envia o arquivo em partes; a API guarda e processa em segundo plano, lendo cada
-- XML e chamando app.import_nfce com os dados da nota. As regras ficam aqui:
--   * só nota autorizada (protocolo 100/150) de produção; repetida (mesma chave) é ignorada;
--   * filial do emitente: a do grupo com o CNPJ, ou criada (e a empresa, se a raiz for nova);
--   * produto pelo código do sistema anterior (cProd), criado se não existir, com GTIN, NCM e
--     CEST próprios e o preço da nota; tributação própria do produto (regime e UF) pela nota
--     mais recente, usada quando o Catálogo não tem a do produto;
--   * cliente pelo CPF/CNPJ do destinatário, criado se não existir;
--   * a venda fica como venda importada (sem caixa nem turno) e baixa o estoque na data da nota,
--     com o tipo "import", que não entra no SNGPC;
--   * cancelamento (evento 110111) desfaz a venda importada e devolve o estoque.

INSERT INTO permission (code, module, name) VALUES
  ('imports.manage', 'Administração', 'Importar notas emitidas no sistema anterior');

-- Código do produto no sistema anterior (cProd da nota): a chave da importação.
ALTER TABLE product
  ADD COLUMN legacy_code text CONSTRAINT product_legacy_code_check CHECK (length(btrim(legacy_code)) BETWEEN 1 AND 60),
  -- NCM e CEST próprios, para o produto sem Catálogo (vindos da nota).
  ADD COLUMN own_ncm text CONSTRAINT product_own_ncm_check CHECK (own_ncm ~ '^[0-9]{8}$'),
  ADD COLUMN own_cest text CONSTRAINT product_own_cest_check CHECK (own_cest ~ '^[0-9]{7}$');
CREATE UNIQUE INDEX product_legacy_code_key ON product (economic_group_id, legacy_code) WHERE deleted_at IS NULL;
CREATE OR REPLACE VIEW v_product WITH (security_invoker = true) AS SELECT * FROM product WHERE deleted_at IS NULL;

-- Tributação própria do produto (por regime e UF), da nota mais recente importada.
CREATE TABLE product_tax_rule (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  product_id uuid NOT NULL REFERENCES product (id),
  tax_regime smallint NOT NULL CONSTRAINT product_tax_rule_regime_check CHECK (tax_regime IN (1, 2, 3, 4)),
  state char(2) NOT NULL CONSTRAINT product_tax_rule_state_check CHECK (state ~ '^[A-Z]{2}$'),
  cfop text NOT NULL CONSTRAINT product_tax_rule_cfop_check CHECK (cfop ~ '^[1-7][0-9]{3}$'),
  origin smallint NOT NULL CONSTRAINT product_tax_rule_origin_check CHECK (origin BETWEEN 0 AND 8),
  icms_cst text CONSTRAINT product_tax_rule_icms_cst_check CHECK (icms_cst ~ '^[0-9]{2}$'),
  icms_csosn text CONSTRAINT product_tax_rule_icms_csosn_check CHECK (icms_csosn ~ '^[0-9]{3}$'),
  icms_rate numeric(7, 4) CONSTRAINT product_tax_rule_icms_rate_check CHECK (icms_rate BETWEEN 0 AND 100),
  pis_cst text CONSTRAINT product_tax_rule_pis_cst_check CHECK (pis_cst ~ '^[0-9]{2}$'),
  pis_rate numeric(7, 4) CONSTRAINT product_tax_rule_pis_rate_check CHECK (pis_rate BETWEEN 0 AND 100),
  cofins_cst text CONSTRAINT product_tax_rule_cofins_cst_check CHECK (cofins_cst ~ '^[0-9]{2}$'),
  cofins_rate numeric(7, 4) CONSTRAINT product_tax_rule_cofins_rate_check CHECK (cofins_rate BETWEEN 0 AND 100),
  benefit_code text CONSTRAINT product_tax_rule_benefit_code_check CHECK (length(benefit_code) BETWEEN 1 AND 10),
  -- Data da nota que deu origem: só uma nota mais nova troca a regra.
  source_emitted_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid,
  CONSTRAINT product_tax_rule_icms_check CHECK ((icms_cst IS NULL) <> (icms_csosn IS NULL))
);
CREATE UNIQUE INDEX product_tax_rule_key ON product_tax_rule (product_id, tax_regime, state) WHERE deleted_at IS NULL;
CREATE INDEX product_tax_rule_economic_group_id_idx ON product_tax_rule (economic_group_id);
CALL app.apply_table_standard('public.product_tax_rule');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON product_tax_rule
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns('economic_group_id', 'product_id', 'tax_regime', 'state');
CREATE POLICY product_tax_rule_select ON product_tax_rule FOR SELECT TO farmaerp_app
  USING (economic_group_id = app.current_user_group());
CREATE VIEW v_product_tax_rule WITH (security_invoker = true) AS SELECT * FROM product_tax_rule WHERE deleted_at IS NULL;
GRANT SELECT ON product_tax_rule, v_product_tax_rule TO farmaerp_app;

-- Um arquivo de importação: envio em partes, depois processamento em segundo plano.
CREATE TABLE document_import (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  file_name text NOT NULL CONSTRAINT document_import_file_name_check CHECK (length(btrim(file_name)) BETWEEN 1 AND 200),
  size_bytes bigint NOT NULL CONSTRAINT document_import_size_check CHECK (size_bytes BETWEEN 1 AND 1073741824),
  received_bytes bigint NOT NULL DEFAULT 0 CONSTRAINT document_import_received_check CHECK (received_bytes BETWEEN 0 AND size_bytes),
  parts integer NOT NULL DEFAULT 0 CONSTRAINT document_import_parts_check CHECK (parts >= 0),
  status text NOT NULL DEFAULT 'uploading' CONSTRAINT document_import_status_check
    CHECK (status IN ('uploading', 'queued', 'processing', 'done', 'failed')),
  -- Contagem do processamento: por modelo e por resultado, e os cadastros criados.
  totals jsonb NOT NULL DEFAULT '{}'::jsonb,
  error text CONSTRAINT document_import_error_check CHECK (length(error) <= 500),
  locked_until timestamptz,
  started_at timestamptz,
  finished_at timestamptz,
  created_by uuid NOT NULL REFERENCES user_account (id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE INDEX document_import_economic_group_id_idx ON document_import (economic_group_id, created_at DESC);
CREATE INDEX document_import_queue_idx ON document_import (created_at) WHERE status IN ('queued', 'processing') AND deleted_at IS NULL;
CREATE INDEX document_import_created_by_idx ON document_import (created_by);
CALL app.apply_table_standard('public.document_import');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON document_import
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns('economic_group_id', 'file_name', 'size_bytes', 'created_by');
CREATE POLICY document_import_select ON document_import FOR SELECT TO farmaerp_app
  USING (economic_group_id = app.current_user_group());
CREATE VIEW v_document_import WITH (security_invoker = true) AS SELECT * FROM document_import WHERE deleted_at IS NULL;
GRANT SELECT ON document_import, v_document_import TO farmaerp_app;

-- O que aconteceu com cada nota do arquivo (para o relatório).
CREATE TABLE document_import_note (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  import_id uuid NOT NULL REFERENCES document_import (id),
  entry_name text NOT NULL CONSTRAINT document_import_note_entry_check CHECK (length(entry_name) BETWEEN 1 AND 300),
  access_key text CONSTRAINT document_import_note_key_check CHECK (access_key ~ '^[0-9]{44}$'),
  model text CONSTRAINT document_import_note_model_check CHECK (model ~ '^[0-9]{2}$'),
  result text NOT NULL CONSTRAINT document_import_note_result_check
    CHECK (result IN ('imported', 'duplicate', 'canceled', 'ignored', 'failed')),
  error_code text CONSTRAINT document_import_note_error_code_check CHECK (error_code ~ '^FA[0-9]{3}$'),
  reason text CONSTRAINT document_import_note_reason_check CHECK (length(reason) <= 500),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE INDEX document_import_note_import_idx ON document_import_note (import_id, result);
CREATE INDEX document_import_note_economic_group_id_idx ON document_import_note (economic_group_id);
CALL app.apply_table_standard('public.document_import_note');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON document_import_note
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns('economic_group_id', 'import_id', 'entry_name');
CREATE POLICY document_import_note_select ON document_import_note FOR SELECT TO farmaerp_app
  USING (economic_group_id = app.current_user_group());
CREATE VIEW v_document_import_note WITH (security_invoker = true) AS SELECT * FROM document_import_note WHERE deleted_at IS NULL;
GRANT SELECT ON document_import_note, v_document_import_note TO farmaerp_app;

-- Venda importada (do sistema anterior): sem caixa, sem turno, com o XML original.
CREATE TABLE imported_sale (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  branch_id uuid NOT NULL REFERENCES branch (id),
  import_id uuid NOT NULL REFERENCES document_import (id),
  access_key text NOT NULL CONSTRAINT imported_sale_key_check CHECK (access_key ~ '^[0-9]{44}$'),
  model text NOT NULL CONSTRAINT imported_sale_model_check CHECK (model IN ('65', '55')),
  series integer NOT NULL CONSTRAINT imported_sale_series_check CHECK (series BETWEEN 0 AND 999),
  number bigint NOT NULL CONSTRAINT imported_sale_number_check CHECK (number BETWEEN 1 AND 999999999),
  emitted_at timestamptz NOT NULL,
  protocol text CONSTRAINT imported_sale_protocol_check CHECK (protocol ~ '^[0-9]{15}$'),
  customer_id uuid REFERENCES customer (id),
  subtotal numeric(12, 2) NOT NULL CONSTRAINT imported_sale_subtotal_check CHECK (subtotal >= 0),
  discount_total numeric(12, 2) NOT NULL CONSTRAINT imported_sale_discount_check CHECK (discount_total >= 0),
  total numeric(12, 2) NOT NULL CONSTRAINT imported_sale_total_check CHECK (total >= 0),
  change_amount numeric(12, 2) NOT NULL DEFAULT 0 CONSTRAINT imported_sale_change_check CHECK (change_amount >= 0),
  xml text NOT NULL CONSTRAINT imported_sale_xml_check CHECK (length(xml) BETWEEN 100 AND 2000000),
  canceled_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE UNIQUE INDEX imported_sale_key_key ON imported_sale (access_key) WHERE deleted_at IS NULL;
CREATE INDEX imported_sale_branch_idx ON imported_sale (branch_id, emitted_at DESC);
CREATE INDEX imported_sale_customer_idx ON imported_sale (customer_id, emitted_at DESC);
CREATE INDEX imported_sale_import_idx ON imported_sale (import_id);
CREATE INDEX imported_sale_economic_group_id_idx ON imported_sale (economic_group_id);
CALL app.apply_table_standard('public.imported_sale');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON imported_sale
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'branch_id', 'import_id', 'access_key', 'model', 'series', 'number', 'emitted_at', 'protocol',
    'customer_id', 'subtotal', 'discount_total', 'total', 'change_amount', 'xml'
  );
CREATE POLICY imported_sale_select ON imported_sale FOR SELECT TO farmaerp_app
  USING (branch_id = ANY (app.allowed_branch_ids()));
CREATE VIEW v_imported_sale WITH (security_invoker = true) AS
  SELECT id, economic_group_id, branch_id, import_id, access_key, model, series, number, emitted_at, protocol, customer_id,
         subtotal, discount_total, total, change_amount, canceled_at, created_at, updated_at, deleted_at, version, updated_by, trace_id
    FROM imported_sale WHERE deleted_at IS NULL;
GRANT SELECT ON imported_sale, v_imported_sale TO farmaerp_app;

CREATE TABLE imported_sale_item (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  imported_sale_id uuid NOT NULL REFERENCES imported_sale (id),
  line integer NOT NULL CONSTRAINT imported_sale_item_line_check CHECK (line BETWEEN 1 AND 990),
  product_id uuid NOT NULL REFERENCES product (id),
  quantity numeric(15, 4) NOT NULL CONSTRAINT imported_sale_item_quantity_check CHECK (quantity > 0),
  unit_price numeric(21, 10) NOT NULL CONSTRAINT imported_sale_item_price_check CHECK (unit_price >= 0),
  discount numeric(12, 2) NOT NULL CONSTRAINT imported_sale_item_discount_check CHECK (discount >= 0),
  total numeric(12, 2) NOT NULL CONSTRAINT imported_sale_item_total_check CHECK (total >= 0),
  cfop text CONSTRAINT imported_sale_item_cfop_check CHECK (cfop ~ '^[1-7][0-9]{3}$'),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE UNIQUE INDEX imported_sale_item_line_key ON imported_sale_item (imported_sale_id, line) WHERE deleted_at IS NULL;
CREATE INDEX imported_sale_item_product_idx ON imported_sale_item (product_id);
CREATE INDEX imported_sale_item_economic_group_id_idx ON imported_sale_item (economic_group_id);
CALL app.apply_table_standard('public.imported_sale_item');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON imported_sale_item
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'imported_sale_id', 'line', 'product_id', 'quantity', 'unit_price', 'discount', 'total', 'cfop'
  );
CREATE POLICY imported_sale_item_select ON imported_sale_item FOR SELECT TO farmaerp_app
  USING (EXISTS (SELECT 1 FROM imported_sale s WHERE s.id = imported_sale_item.imported_sale_id));
CREATE VIEW v_imported_sale_item WITH (security_invoker = true) AS SELECT * FROM imported_sale_item WHERE deleted_at IS NULL;
GRANT SELECT ON imported_sale_item, v_imported_sale_item TO farmaerp_app;

CREATE TABLE imported_sale_payment (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  imported_sale_id uuid NOT NULL REFERENCES imported_sale (id),
  -- tPag da nota (01 dinheiro, 03 crédito, 04 débito, 17 PIX...).
  method text NOT NULL CONSTRAINT imported_sale_payment_method_check CHECK (method ~ '^[0-9]{2}$'),
  description text CONSTRAINT imported_sale_payment_description_check CHECK (length(description) <= 60),
  amount numeric(12, 2) NOT NULL CONSTRAINT imported_sale_payment_amount_check CHECK (amount >= 0),
  card_brand text CONSTRAINT imported_sale_payment_brand_check CHECK (card_brand ~ '^[0-9]{2}$'),
  authorization_code text CONSTRAINT imported_sale_payment_authorization_check CHECK (length(authorization_code) <= 128),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE INDEX imported_sale_payment_sale_idx ON imported_sale_payment (imported_sale_id);
CREATE INDEX imported_sale_payment_economic_group_id_idx ON imported_sale_payment (economic_group_id);
CALL app.apply_table_standard('public.imported_sale_payment');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON imported_sale_payment
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'imported_sale_id', 'method', 'description', 'amount', 'card_brand', 'authorization_code'
  );
CREATE POLICY imported_sale_payment_select ON imported_sale_payment FOR SELECT TO farmaerp_app
  USING (EXISTS (SELECT 1 FROM imported_sale s WHERE s.id = imported_sale_payment.imported_sale_id));
CREATE VIEW v_imported_sale_payment WITH (security_invoker = true) AS SELECT * FROM imported_sale_payment WHERE deleted_at IS NULL;
GRANT SELECT ON imported_sale_payment, v_imported_sale_payment TO farmaerp_app;

-- Saída de estoque da venda importada: tipo próprio, ligado ao item.
ALTER TABLE stock_movement DROP CONSTRAINT stock_movement_type_check;
ALTER TABLE stock_movement ADD CONSTRAINT stock_movement_type_check CHECK (movement_type IN (
  'invoice', 'sale', 'return', 'transfer', 'adjustment', 'loss', 'inventory', 'import'
));
ALTER TABLE stock_movement ADD COLUMN imported_sale_item_id uuid REFERENCES imported_sale_item (id);
ALTER TABLE stock_movement ADD CONSTRAINT stock_movement_imported_item_check
  CHECK (imported_sale_item_id IS NULL OR movement_type = 'import');
CREATE INDEX stock_movement_imported_item_idx ON stock_movement (imported_sale_item_id) WHERE imported_sale_item_id IS NOT NULL;

-- A venda importada não entra no SNGPC (o entreposto começa na abertura).
DROP TRIGGER track_sngpc_movement ON stock_movement;
CREATE TRIGGER track_sngpc_movement AFTER INSERT ON stock_movement
  FOR EACH ROW WHEN (NEW.movement_type <> 'import') EXECUTE FUNCTION app.track_sngpc_movement();

CREATE FUNCTION app.require_import_worker() RETURNS void
LANGUAGE plpgsql STABLE
SET search_path = ''
AS $$
BEGIN
  IF app.current_user_id() IS NOT NULL OR COALESCE(pg_catalog.current_setting('app.worker', true), '') <> 'import' THEN
    RAISE EXCEPTION 'Você não tem permissão para esta operação.'
      USING ERRCODE = 'FA002', DETAIL = 'Importação fora do processamento.';
  END IF;
END;
$$;

CREATE FUNCTION app.require_imports_manage() RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT app.has_permission('imports.manage') THEN
    RAISE EXCEPTION 'Você não tem permissão para esta operação.'
      USING ERRCODE = 'FA002', DETAIL = 'Importação sem imports.manage.';
  END IF;
  RETURN app.current_user_group();
END;
$$;

-- Começa o envio de um arquivo.
CREATE FUNCTION app.create_document_import(p_file_name text, p_size bigint) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.require_imports_manage();
  new_id uuid;
BEGIN
  IF p_file_name IS NULL OR p_file_name !~* '\.zip$' OR p_size IS NULL OR p_size NOT BETWEEN 1 AND 1073741824 THEN
    RAISE EXCEPTION 'O arquivo de importação é inválido.' USING ERRCODE = 'FA740';
  END IF;
  INSERT INTO public.document_import (economic_group_id, file_name, size_bytes, created_by)
  VALUES (group_id, pg_catalog.btrim(p_file_name), p_size, app.current_user_id())
  RETURNING id INTO new_id;
  RETURN new_id;
END;
$$;

-- Parte recebida (a API já gravou no arquivo). As partes vêm em ordem, sem passar do tamanho.
CREATE FUNCTION app.document_import_part(p_import_id uuid, p_part integer, p_bytes bigint) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.require_imports_manage();
  target public.document_import;
BEGIN
  SELECT * INTO target FROM public.document_import d
   WHERE d.id = p_import_id AND d.economic_group_id = group_id AND d.deleted_at IS NULL FOR UPDATE;
  IF target.id IS NULL THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.' USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('document_import %s.', p_import_id);
  END IF;
  IF target.status <> 'uploading' OR p_part <> target.parts + 1 OR p_bytes IS NULL OR p_bytes < 1
     OR target.received_bytes + p_bytes > target.size_bytes THEN
    RAISE EXCEPTION 'O envio do arquivo saiu de ordem.' USING ERRCODE = 'FA741',
      DETAIL = pg_catalog.format('Parte %s, esperada %s.', p_part, target.parts + 1);
  END IF;
  UPDATE public.document_import d SET parts = d.parts + 1, received_bytes = d.received_bytes + p_bytes WHERE d.id = target.id;
  RETURN target.received_bytes + p_bytes;
END;
$$;

-- Envio completo: entra na fila.
CREATE FUNCTION app.complete_document_import(p_import_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.require_imports_manage();
  target public.document_import;
BEGIN
  SELECT * INTO target FROM public.document_import d
   WHERE d.id = p_import_id AND d.economic_group_id = group_id AND d.deleted_at IS NULL FOR UPDATE;
  IF target.id IS NULL THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.' USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('document_import %s.', p_import_id);
  END IF;
  IF target.status <> 'uploading' OR target.received_bytes <> target.size_bytes THEN
    RAISE EXCEPTION 'O envio do arquivo saiu de ordem.' USING ERRCODE = 'FA741', DETAIL = 'Arquivo incompleto.';
  END IF;
  UPDATE public.document_import d SET status = 'queued' WHERE d.id = target.id;
END;
$$;

-- Lista e relatório (para a retaguarda).
CREATE FUNCTION app.list_document_imports() RETURNS SETOF public.v_document_import
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.require_imports_manage();
BEGIN
  RETURN QUERY SELECT * FROM public.v_document_import d WHERE d.economic_group_id = group_id ORDER BY d.created_at DESC LIMIT 100;
END;
$$;

CREATE FUNCTION app.document_import_report(p_import_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.require_imports_manage();
  target public.document_import;
BEGIN
  SELECT * INTO target FROM public.document_import d WHERE d.id = p_import_id AND d.economic_group_id = group_id AND d.deleted_at IS NULL;
  IF target.id IS NULL THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.' USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('document_import %s.', p_import_id);
  END IF;
  RETURN pg_catalog.jsonb_build_object(
    'id', target.id, 'file_name', target.file_name, 'size_bytes', target.size_bytes, 'received_bytes', target.received_bytes,
    'status', target.status, 'totals', target.totals, 'error', target.error, 'started_at', target.started_at,
    'finished_at', target.finished_at, 'created_at', target.created_at,
    -- Problemas, para corrigir (até 500).
    'problems', COALESCE((
      SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
               'entry_name', n.entry_name, 'access_key', n.access_key, 'model', n.model, 'result', n.result,
               'error_code', n.error_code, 'reason', n.reason) ORDER BY n.created_at)
        FROM (SELECT * FROM public.document_import_note n
               WHERE n.import_id = target.id AND n.result = 'failed' AND n.deleted_at IS NULL
               ORDER BY n.created_at LIMIT 500) n), '[]'::jsonb),
    -- Última numeração por filial, modelo e série, para continuar sem repetir número.
    'last_numbers', COALESCE((
      SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
               'branch_id', x.branch_id, 'branch_name', b.name, 'model', x.model, 'series', x.series, 'last_number', x.last_number)
             ORDER BY b.name, x.model, x.series)
        FROM (SELECT s.branch_id, s.model, s.series, pg_catalog.max(s.number) AS last_number
                FROM public.imported_sale s WHERE s.import_id = target.id AND s.deleted_at IS NULL
               GROUP BY s.branch_id, s.model, s.series) x
        JOIN public.branch b ON b.id = x.branch_id), '[]'::jsonb)
  );
END;
$$;

-- Próximo arquivo da fila para o processamento (reserva por 30 minutos; renovada no progresso).
CREATE FUNCTION app.claim_document_import() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.document_import;
BEGIN
  PERFORM app.require_import_worker();
  SELECT * INTO target FROM public.document_import d
   WHERE d.deleted_at IS NULL
     AND (d.status = 'queued' OR (d.status = 'processing' AND d.locked_until < pg_catalog.now()))
   ORDER BY d.created_at LIMIT 1 FOR UPDATE SKIP LOCKED;
  IF target.id IS NULL THEN
    RETURN NULL;
  END IF;
  UPDATE public.document_import d
     SET status = 'processing', started_at = COALESCE(d.started_at, pg_catalog.now()),
         locked_until = pg_catalog.now() + interval '30 minutes'
   WHERE d.id = target.id;
  RETURN pg_catalog.jsonb_build_object('id', target.id, 'economic_group_id', target.economic_group_id, 'size_bytes', target.size_bytes);
END;
$$;

-- Progresso: soma as contagens e renova a reserva. Com p_status, encerra.
CREATE FUNCTION app.document_import_progress(p_import_id uuid, p_totals jsonb, p_status text, p_error text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM app.require_import_worker();
  IF p_status IS NOT NULL AND p_status NOT IN ('done', 'failed') THEN
    RAISE EXCEPTION 'Alguns dados informados são inválidos.' USING ERRCODE = 'FA005';
  END IF;
  UPDATE public.document_import d
     SET totals = COALESCE(p_totals, d.totals),
         locked_until = CASE WHEN p_status IS NULL THEN pg_catalog.now() + interval '30 minutes' END,
         status = COALESCE(p_status, d.status),
         finished_at = CASE WHEN p_status IS NOT NULL THEN pg_catalog.now() END,
         error = NULLIF(pg_catalog.left(p_error, 500), '')
   WHERE d.id = p_import_id AND d.status = 'processing';
END;
$$;

-- Registra o resultado de uma entrada do arquivo que nem chegou a ser nota (XML ruim, outro
-- modelo, homologação): só para o relatório.
CREATE FUNCTION app.import_note_result(p_import_id uuid, p_entry text, p_key text, p_model text, p_result text, p_code text, p_reason text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM app.require_import_worker();
  INSERT INTO public.document_import_note (economic_group_id, import_id, entry_name, access_key, model, result, error_code, reason)
  SELECT d.economic_group_id, d.id, pg_catalog.left(p_entry, 300), NULLIF(p_key, ''), NULLIF(p_model, ''), p_result,
         NULLIF(p_code, ''), NULLIF(pg_catalog.left(p_reason, 500), '')
    FROM public.document_import d WHERE d.id = p_import_id;
END;
$$;

-- Texto sem espaços sobrando, cortado no tamanho; vazio vira nulo.
CREATE FUNCTION app.import_text(p_value text, p_max integer) RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$ SELECT NULLIF(pg_catalog.left(pg_catalog.regexp_replace(pg_catalog.btrim(COALESCE(p_value, '')), '\s+', ' ', 'g'), p_max), '') $$;

-- Filial do emitente no grupo: a que já existe pelo CNPJ ou uma nova (com a empresa, se a raiz
-- for nova). CNPJ de filial de outro grupo: FA742.
CREATE FUNCTION app.import_branch(p_group_id uuid, p_issuer jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  issuer_cnpj text := p_issuer ->> 'cnpj';
  found_branch public.branch;
  company_id uuid;
  new_branch uuid;
  uf text := pg_catalog.upper(p_issuer ->> 'uf');
  registration text := app.clean_state_registration(p_issuer ->> 'state_registration');
BEGIN
  IF issuer_cnpj IS NULL OR NOT app.is_valid_cnpj(issuer_cnpj) THEN
    RAISE EXCEPTION 'A nota não pôde ser importada.' USING ERRCODE = 'FA743', DETAIL = 'CNPJ do emitente inválido.';
  END IF;
  SELECT b.* INTO found_branch FROM public.branch b WHERE b.cnpj = issuer_cnpj AND b.deleted_at IS NULL;
  IF found_branch.id IS NOT NULL THEN
    IF NOT EXISTS (SELECT 1 FROM public.company c WHERE c.id = found_branch.company_id AND c.economic_group_id = p_group_id) THEN
      RAISE EXCEPTION 'O CNPJ do emitente é de uma filial de outro cliente.' USING ERRCODE = 'FA742', DETAIL = issuer_cnpj;
    END IF;
    RETURN found_branch.id;
  END IF;
  SELECT c.id INTO company_id FROM public.company c
   WHERE c.economic_group_id = p_group_id AND c.cnpj_root = pg_catalog.left(issuer_cnpj, 8) AND c.deleted_at IS NULL LIMIT 1;
  IF company_id IS NULL THEN
    IF EXISTS (SELECT 1 FROM public.company c WHERE c.cnpj_root = pg_catalog.left(issuer_cnpj, 8) AND c.deleted_at IS NULL) THEN
      RAISE EXCEPTION 'O CNPJ do emitente é de uma filial de outro cliente.' USING ERRCODE = 'FA742', DETAIL = issuer_cnpj;
    END IF;
    INSERT INTO public.company (economic_group_id, legal_name, trade_name, cnpj_root, tax_regime)
    VALUES (
      p_group_id, COALESCE(app.import_text(p_issuer ->> 'name', 150), 'Empresa ' || issuer_cnpj),
      COALESCE(app.import_text(p_issuer ->> 'trade_name', 150), app.import_text(p_issuer ->> 'name', 150), 'Empresa ' || issuer_cnpj),
      pg_catalog.left(issuer_cnpj, 8), CASE WHEN p_issuer ->> 'crt' IN ('1', '2', '3', '4') THEN (p_issuer ->> 'crt')::smallint END
    ) RETURNING id INTO company_id;
  END IF;
  INSERT INTO public.branch (
    company_id, name, cnpj, state, state_registration, postal_code, street, street_number, complement, district, city,
    city_code, phone
  ) VALUES (
    company_id,
    COALESCE(app.import_text(p_issuer ->> 'trade_name', 100), app.import_text(p_issuer ->> 'name', 100), 'Filial ' || issuer_cnpj)
      || ' ' || pg_catalog.right(issuer_cnpj, 6),
    issuer_cnpj,
    CASE WHEN uf ~ '^[A-Z]{2}$' THEN uf END,
    CASE WHEN uf ~ '^[A-Z]{2}$' AND registration IS NOT NULL AND app.is_valid_state_registration(registration, uf) THEN registration END,
    CASE WHEN p_issuer ->> 'postal_code' ~ '^[0-9]{8}$' THEN p_issuer ->> 'postal_code' END,
    app.import_text(p_issuer ->> 'street', 150), app.import_text(p_issuer ->> 'number', 20),
    app.import_text(p_issuer ->> 'complement', 100), app.import_text(p_issuer ->> 'district', 100),
    app.import_text(p_issuer ->> 'city', 100),
    CASE WHEN p_issuer ->> 'city_code' ~ '^[0-9]{7}$' THEN p_issuer ->> 'city_code' END,
    CASE WHEN app.clean_digits(p_issuer ->> 'phone') ~ '^[0-9]{10,11}$' THEN app.clean_digits(p_issuer ->> 'phone') END
  ) RETURNING id INTO new_branch;
  RETURN new_branch;
END;
$$;

-- Cliente pelo CPF/CNPJ do destinatário: o que existe no grupo ou um novo. Documento inválido:
-- a venda entra sem cliente.
CREATE FUNCTION app.import_customer(p_group_id uuid, p_customer jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  doc text := app.clean_document(p_customer ->> 'document');
  person text;
  found_id uuid;
  customer_name text;
BEGIN
  IF doc IS NULL THEN
    RETURN NULL;
  END IF;
  person := CASE pg_catalog.length(doc) WHEN 11 THEN 'individual' WHEN 14 THEN 'company' END;
  IF person IS NULL OR (person = 'individual' AND NOT app.is_valid_cpf(doc))
     OR (person = 'company' AND NOT app.is_valid_cnpj(doc)) THEN
    RETURN NULL;
  END IF;
  SELECT c.id INTO found_id FROM public.customer c
   WHERE c.economic_group_id = p_group_id AND c.document = doc AND c.deleted_at IS NULL;
  IF found_id IS NOT NULL THEN
    RETURN found_id;
  END IF;
  customer_name := COALESCE(
    app.import_text(p_customer ->> 'name', 150),
    CASE person WHEN 'individual'
      THEN 'Cliente CPF ***.***.***-' || pg_catalog.right(doc, 2)
      ELSE 'Cliente CNPJ ' || pg_catalog.left(doc, 8) || '/****-' || pg_catalog.right(doc, 2) END
  );
  INSERT INTO public.customer (economic_group_id, person_type, document, name)
  VALUES (p_group_id, person, doc, customer_name)
  RETURNING id INTO found_id;
  RETURN found_id;
END;
$$;

-- Produto pelo código do sistema anterior: o que existe no grupo ou um novo, com o código de
-- barras (GTIN válido e livre, ou o próprio código como interno), NCM, CEST e o preço da nota.
CREATE FUNCTION app.import_product(p_group_id uuid, p_item jsonb, p_emitted_at timestamptz) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  legacy text := app.import_text(p_item ->> 'code', 60);
  gtin text := NULLIF(p_item ->> 'gtin', '');
  found_id uuid;
  catalog_id uuid;
  barcode text;
  internal boolean := false;
  price numeric := pg_catalog.round(COALESCE((p_item ->> 'unit_price')::numeric, 0), 2);
BEGIN
  IF legacy IS NULL THEN
    RAISE EXCEPTION 'A nota não pôde ser importada.' USING ERRCODE = 'FA743', DETAIL = 'Item sem código do produto.';
  END IF;
  SELECT p.id INTO found_id FROM public.product p
   WHERE p.economic_group_id = p_group_id AND p.legacy_code = legacy AND p.deleted_at IS NULL;
  IF found_id IS NOT NULL THEN
    RETURN found_id;
  END IF;
  IF gtin IS NOT NULL AND NOT app.is_valid_gtin(gtin) THEN
    gtin := NULL;
  END IF;
  IF gtin IS NOT NULL THEN
    SELECT cb.catalog_product_id INTO catalog_id FROM public.catalog_product_barcode cb
     WHERE cb.code = gtin AND cb.deleted_at IS NULL LIMIT 1;
    -- O Catálogo já ligado a outro produto do grupo não liga de novo.
    IF EXISTS (SELECT 1 FROM public.product p WHERE p.economic_group_id = p_group_id AND p.catalog_product_id = catalog_id AND p.deleted_at IS NULL) THEN
      catalog_id := NULL;
    END IF;
  END IF;
  INSERT INTO public.product (economic_group_id, catalog_product_id, display_name, legacy_code, own_ncm, own_cest)
  VALUES (
    p_group_id, catalog_id, COALESCE(app.import_text(p_item ->> 'name', 120), 'Produto ' || legacy), legacy,
    CASE WHEN p_item ->> 'ncm' ~ '^[0-9]{8}$' THEN p_item ->> 'ncm' END,
    CASE WHEN p_item ->> 'cest' ~ '^[0-9]{7}$' THEN p_item ->> 'cest' END
  ) RETURNING id INTO found_id;

  -- Código de barras principal: o GTIN, se livre no grupo; senão o código anterior, como interno.
  IF gtin IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.product_barcode pb WHERE pb.economic_group_id = p_group_id AND pb.code = gtin AND pb.deleted_at IS NULL
  ) THEN
    barcode := gtin;
  ELSE
    barcode := pg_catalog.left(pg_catalog.regexp_replace(legacy, '[^0-9A-Za-z]', '', 'g'), 28);
    internal := true;
    IF barcode = '' OR EXISTS (
      SELECT 1 FROM public.product_barcode pb WHERE pb.economic_group_id = p_group_id AND pb.code = barcode AND pb.deleted_at IS NULL
    ) THEN
      barcode := 'IM' || pg_catalog.left(pg_catalog.replace(found_id::text, '-', ''), 26);
    END IF;
  END IF;
  PERFORM app.insert_product_barcode(p_group_id, found_id, barcode, internal, true, true, true, NULL, NULL);
  IF price > 0 THEN
    INSERT INTO public.product_price (economic_group_id, product_id, branch_id, price, reason)
    VALUES (p_group_id, found_id, NULL, price, 'Importado da nota');
  END IF;
  RETURN found_id;
END;
$$;

-- Tributação própria do produto pela nota (só troca se a nota for mais nova).
CREATE FUNCTION app.import_tax_rule(p_group_id uuid, p_product_id uuid, p_regime smallint, p_state text, p_item jsonb, p_emitted_at timestamptz)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  tax jsonb := p_item -> 'tax';
  current_rule public.product_tax_rule;
BEGIN
  IF p_regime IS NULL OR p_state IS NULL OR tax IS NULL OR NOT (p_item ->> 'cfop' ~ '^[1-7][0-9]{3}$')
     OR ((tax ->> 'icms_cst') IS NULL) = ((tax ->> 'icms_csosn') IS NULL) THEN
    RETURN;
  END IF;
  SELECT * INTO current_rule FROM public.product_tax_rule r
   WHERE r.product_id = p_product_id AND r.tax_regime = p_regime AND r.state = p_state AND r.deleted_at IS NULL;
  IF current_rule.id IS NOT NULL AND current_rule.source_emitted_at >= p_emitted_at THEN
    RETURN;
  END IF;
  BEGIN
    IF current_rule.id IS NOT NULL THEN
      UPDATE public.product_tax_rule r
         SET cfop = p_item ->> 'cfop', origin = COALESCE((tax ->> 'origin')::smallint, 0), icms_cst = tax ->> 'icms_cst',
             icms_csosn = tax ->> 'icms_csosn', icms_rate = (tax ->> 'icms_rate')::numeric, pis_cst = tax ->> 'pis_cst',
             pis_rate = (tax ->> 'pis_rate')::numeric, cofins_cst = tax ->> 'cofins_cst',
             cofins_rate = (tax ->> 'cofins_rate')::numeric, benefit_code = NULLIF(tax ->> 'benefit_code', ''),
             source_emitted_at = p_emitted_at
       WHERE r.id = current_rule.id;
    ELSE
      INSERT INTO public.product_tax_rule (
        economic_group_id, product_id, tax_regime, state, cfop, origin, icms_cst, icms_csosn, icms_rate, pis_cst, pis_rate,
        cofins_cst, cofins_rate, benefit_code, source_emitted_at
      ) VALUES (
        p_group_id, p_product_id, p_regime, p_state, p_item ->> 'cfop', COALESCE((tax ->> 'origin')::smallint, 0),
        tax ->> 'icms_cst', tax ->> 'icms_csosn', (tax ->> 'icms_rate')::numeric, tax ->> 'pis_cst',
        (tax ->> 'pis_rate')::numeric, tax ->> 'cofins_cst', (tax ->> 'cofins_rate')::numeric,
        NULLIF(tax ->> 'benefit_code', ''), p_emitted_at
      );
    END IF;
  EXCEPTION WHEN check_violation OR invalid_text_representation OR numeric_value_out_of_range THEN
    -- Tributação fora do formato não impede a venda: o produto fica sem a regra.
    RETURN;
  END;
END;
$$;

-- Uma NFC-e autorizada do arquivo. Devolve o resultado: imported, duplicate, ignored ou failed
-- (com o código). Cada nota é uma transação na API: a falha de uma não para as outras.
CREATE FUNCTION app.import_nfce(p_import_id uuid, p_entry text, p_note jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  job public.document_import;
  key text := p_note ->> 'access_key';
  emitted timestamptz;
  branch_id uuid;
  branch_row public.branch;
  regime smallint;
  customer_id uuid;
  sale_id uuid;
  item jsonb;
  product_id uuid;
  item_id uuid;
  payment jsonb;
  outcome text := 'imported';
  code text;
  message text;
  detail text;
BEGIN
  PERFORM app.require_import_worker();
  SELECT * INTO job FROM public.document_import d WHERE d.id = p_import_id AND d.status = 'processing';
  IF job.id IS NULL THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.' USING ERRCODE = 'FA006', DETAIL = 'Importação fora do processamento.';
  END IF;
  BEGIN
    IF key !~ '^[0-9]{44}$' OR p_note ->> 'model' <> '65' THEN
      RAISE EXCEPTION 'A nota não pôde ser importada.' USING ERRCODE = 'FA743', DETAIL = 'Chave ou modelo fora do formato.';
    END IF;
    IF COALESCE(p_note ->> 'environment', '1') <> '1' THEN
      outcome := 'ignored';
      message := 'Nota de homologação, sem valor fiscal.';
    ELSIF COALESCE(p_note ->> 'status_code', '') NOT IN ('100', '150') THEN
      outcome := 'ignored';
      message := 'Nota sem autorização da Sefaz.';
    ELSIF EXISTS (SELECT 1 FROM public.imported_sale s WHERE s.access_key = key AND s.deleted_at IS NULL) THEN
      outcome := 'duplicate';
    ELSE
      emitted := (p_note ->> 'emitted_at')::timestamptz;
      branch_id := app.import_branch(job.economic_group_id, p_note -> 'issuer');
      SELECT b.* INTO branch_row FROM public.branch b WHERE b.id = branch_id;
      SELECT c.tax_regime INTO regime FROM public.company c WHERE c.id = branch_row.company_id;
      customer_id := app.import_customer(job.economic_group_id, COALESCE(p_note -> 'customer', '{}'::jsonb));
      INSERT INTO public.imported_sale (
        economic_group_id, branch_id, import_id, access_key, model, series, number, emitted_at, protocol, customer_id,
        subtotal, discount_total, total, change_amount, xml
      ) VALUES (
        job.economic_group_id, branch_id, job.id, key, '65', (p_note ->> 'series')::integer, (p_note ->> 'number')::bigint,
        emitted, NULLIF(p_note ->> 'protocol', ''), customer_id, (p_note ->> 'subtotal')::numeric,
        COALESCE((p_note ->> 'discount')::numeric, 0), (p_note ->> 'total')::numeric, COALESCE((p_note ->> 'change')::numeric, 0),
        p_note ->> 'xml'
      ) RETURNING id INTO sale_id;
      FOR item IN SELECT value FROM pg_catalog.jsonb_array_elements(p_note -> 'items') LOOP
        product_id := app.import_product(job.economic_group_id, item, emitted);
        PERFORM app.import_tax_rule(job.economic_group_id, product_id, regime, branch_row.state, item, emitted);
        INSERT INTO public.imported_sale_item (economic_group_id, imported_sale_id, line, product_id, quantity, unit_price, discount, total, cfop)
        VALUES (
          job.economic_group_id, sale_id, (item ->> 'line')::integer, product_id, (item ->> 'quantity')::numeric,
          (item ->> 'unit_price')::numeric, COALESCE((item ->> 'discount')::numeric, 0), (item ->> 'total')::numeric,
          NULLIF(item ->> 'cfop', '')
        ) RETURNING id INTO item_id;
        INSERT INTO public.stock_movement (economic_group_id, branch_id, product_id, movement_type, quantity, occurred_at, reason, imported_sale_item_id)
        VALUES (
          job.economic_group_id, branch_id, product_id, 'import', -pg_catalog.round((item ->> 'quantity')::numeric, 3), emitted,
          'Venda importada ' || key, item_id
        );
      END LOOP;
      FOR payment IN SELECT value FROM pg_catalog.jsonb_array_elements(COALESCE(p_note -> 'payments', '[]'::jsonb)) LOOP
        INSERT INTO public.imported_sale_payment (economic_group_id, imported_sale_id, method, description, amount, card_brand, authorization_code)
        VALUES (
          job.economic_group_id, sale_id, payment ->> 'type', app.import_text(payment ->> 'description', 60),
          (payment ->> 'amount')::numeric, NULLIF(payment ->> 'card_brand', ''), app.import_text(payment ->> 'authorization', 128)
        );
      END LOOP;
    END IF;
  EXCEPTION
    WHEN SQLSTATE 'FA742' OR SQLSTATE 'FA743' THEN
      GET STACKED DIAGNOSTICS detail = PG_EXCEPTION_DETAIL;
      outcome := 'failed';
      code := SQLSTATE;
      message := pg_catalog.left(SQLERRM || COALESCE(' ' || NULLIF(detail, ''), ''), 500);
    WHEN check_violation OR not_null_violation OR unique_violation OR invalid_text_representation OR numeric_value_out_of_range
         OR invalid_datetime_format OR datetime_field_overflow OR foreign_key_violation OR null_value_not_allowed THEN
      outcome := 'failed';
      code := 'FA743';
      message := pg_catalog.left(SQLERRM, 500);
  END;
  INSERT INTO public.document_import_note (economic_group_id, import_id, entry_name, access_key, model, result, error_code, reason)
  VALUES (
    job.economic_group_id, job.id, pg_catalog.left(COALESCE(p_entry, '?'), 300),
    CASE WHEN key ~ '^[0-9]{44}$' THEN key END, CASE WHEN p_note ->> 'model' ~ '^[0-9]{2}$' THEN p_note ->> 'model' END,
    outcome, code, message
  );
  RETURN pg_catalog.jsonb_build_object('result', outcome, 'code', code, 'reason', message);
END;
$$;

-- Cancelamento da nota (evento 110111): desfaz a venda importada e devolve o estoque.
CREATE FUNCTION app.import_nfce_cancel(p_import_id uuid, p_entry text, p_key text, p_canceled_at timestamptz) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  job public.document_import;
  sale public.imported_sale;
  movement public.stock_movement;
BEGIN
  PERFORM app.require_import_worker();
  SELECT * INTO job FROM public.document_import d WHERE d.id = p_import_id AND d.status = 'processing';
  IF job.id IS NULL THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.' USING ERRCODE = 'FA006', DETAIL = 'Importação fora do processamento.';
  END IF;
  SELECT * INTO sale FROM public.imported_sale s
   WHERE s.access_key = p_key AND s.economic_group_id = job.economic_group_id AND s.deleted_at IS NULL FOR UPDATE;
  IF sale.id IS NOT NULL AND sale.canceled_at IS NULL THEN
    UPDATE public.imported_sale s SET canceled_at = COALESCE(p_canceled_at, pg_catalog.now()) WHERE s.id = sale.id;
    FOR movement IN
      SELECT m.* FROM public.stock_movement m
        JOIN public.imported_sale_item i ON i.id = m.imported_sale_item_id
       WHERE i.imported_sale_id = sale.id AND m.reversal_of IS NULL AND m.deleted_at IS NULL
    LOOP
      INSERT INTO public.stock_movement (economic_group_id, branch_id, product_id, batch_id, movement_type, quantity, occurred_at, reason, reversal_of)
      VALUES (movement.economic_group_id, movement.branch_id, movement.product_id, movement.batch_id, 'import', -movement.quantity,
              COALESCE(p_canceled_at, pg_catalog.now()), 'Nota cancelada ' || p_key, movement.id);
    END LOOP;
  END IF;
  INSERT INTO public.document_import_note (economic_group_id, import_id, entry_name, access_key, model, result, reason)
  VALUES (job.economic_group_id, job.id, pg_catalog.left(COALESCE(p_entry, '?'), 300), CASE WHEN p_key ~ '^[0-9]{44}$' THEN p_key END,
          '65', 'canceled', CASE WHEN sale.id IS NULL THEN 'Cancelamento de nota que não está na importação.' END);
  RETURN pg_catalog.jsonb_build_object('result', 'canceled', 'found', sale.id IS NOT NULL);
END;
$$;

-- O estoque aceita a saída da venda importada sem lote.
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

  -- Venda importada do sistema anterior: já aconteceu, sai sem lote (como a venda sem lote).
  IF NEW.movement_type = 'import' AND NEW.imported_sale_item_id IS NOT NULL THEN
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

-- A venda importada, como a venda, pode deixar o saldo negativo: ela já aconteceu.
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

  IF NEW.quantity < 0 AND new_quantity < 0 AND NEW.movement_type NOT IN ('sale', 'import') THEN
    RAISE EXCEPTION 'A quantidade é maior que o saldo disponível.'
      USING ERRCODE = 'FA801',
            DETAIL = pg_catalog.format('Produto %s, filial %s, lote %s, saldo ficaria %s.', NEW.product_id, NEW.branch_id, NEW.batch_id, new_quantity);
  END IF;
  RETURN NULL;
END;
$$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  app.create_document_import(text, bigint),
  app.document_import_part(uuid, integer, bigint),
  app.complete_document_import(uuid),
  app.list_document_imports(),
  app.document_import_report(uuid),
  app.claim_document_import(),
  app.document_import_progress(uuid, jsonb, text, text),
  app.import_note_result(uuid, text, text, text, text, text, text),
  app.import_nfce(uuid, text, jsonb),
  app.import_nfce_cancel(uuid, text, text, timestamptz)
TO farmaerp_app;
