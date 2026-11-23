-- Up Migration

-- Notas de serviço (NFS-e) pelo Ambiente de Dados Nacional (ADN). A mesma rotina e a mesma chave
-- "Download automático" da NF-e buscam, por NSU, as NFS-e em que a filial aparece. A nota de serviço
-- é só registro: não mexe em estoque nem em custo, e fica pronta para o contas a pagar.

-- A NFS-e tem a própria sequência de NSU, guardada ao lado da NF-e.
ALTER TABLE branch_dfe_sync
  ADD COLUMN nfse_last_nsu text NOT NULL DEFAULT '000000000000000' CONSTRAINT branch_dfe_sync_nfse_last_nsu_check CHECK (nfse_last_nsu ~ '^[0-9]{15}$'),
  ADD COLUMN nfse_next_run_at timestamptz NOT NULL DEFAULT now(),
  ADD COLUMN nfse_locked_until timestamptz,
  ADD COLUMN nfse_last_run_at timestamptz,
  ADD COLUMN nfse_last_status text CONSTRAINT branch_dfe_sync_nfse_last_status_check CHECK (nfse_last_status ~ '^[A-Z_]{1,40}$'),
  ADD COLUMN nfse_last_message text CONSTRAINT branch_dfe_sync_nfse_last_message_check CHECK (length(nfse_last_message) <= 500),
  ADD COLUMN nfse_last_error text CONSTRAINT branch_dfe_sync_nfse_last_error_check CHECK (nfse_last_error ~ '^FA[0-9]{3}$');
-- A view com SELECT * congela as colunas: recria para mostrar as novas.
CREATE OR REPLACE VIEW v_branch_dfe_sync WITH (security_invoker = true) AS
  SELECT * FROM branch_dfe_sync WHERE deleted_at IS NULL;

-- Os documentos guardados dizem de onde vieram: cada origem tem a própria sequência de NSU.
ALTER TABLE dfe_document
  ADD COLUMN kind text NOT NULL DEFAULT 'nfe' CONSTRAINT dfe_document_kind_check CHECK (kind IN ('nfe', 'nfse'));
ALTER TABLE dfe_document DROP CONSTRAINT dfe_document_schema_check;
ALTER TABLE dfe_document ADD CONSTRAINT dfe_document_schema_check CHECK (
  (kind = 'nfe' AND schema ~ '^[A-Za-z]{1,30}_v[0-9]{1,2}\.[0-9]{2}$') OR (kind = 'nfse' AND schema IN ('NFSE', 'EVENTO', 'DPS'))
);
ALTER TABLE dfe_document DROP CONSTRAINT dfe_document_access_key_check;
-- Chave da NF-e: 44 posições com dígito. Chave da NFS-e: 50 dígitos.
ALTER TABLE dfe_document ADD CONSTRAINT dfe_document_access_key_check CHECK (
  access_key IS NULL
  OR (kind = 'nfe' AND app.is_valid_access_key(access_key))
  OR (kind = 'nfse' AND access_key ~ '^[0-9]{50}$')
);
DROP INDEX dfe_document_nsu_key;
CREATE UNIQUE INDEX dfe_document_nsu_key ON dfe_document (branch_id, kind, nsu) WHERE deleted_at IS NULL;
DROP TRIGGER block_immutable_columns ON dfe_document;
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON dfe_document
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'branch_id', 'nsu', 'schema', 'access_key', 'xml', 'deleted_at', 'kind'
  );
CREATE OR REPLACE VIEW v_dfe_document WITH (security_invoker = true) AS
  SELECT * FROM dfe_document WHERE deleted_at IS NULL;

-- O NSU da NF-e passa a conferir a origem.
CREATE OR REPLACE FUNCTION app.dfe_store_document(p_branch_id uuid, p_nsu text, p_schema text, p_access_key text, p_xml text) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  inserted uuid;
BEGIN
  PERFORM app.require_dfe_worker();
  INSERT INTO public.dfe_document (economic_group_id, branch_id, nsu, schema, access_key, xml, kind)
  SELECT c.economic_group_id, b.id, p_nsu, p_schema, p_access_key, p_xml, 'nfe'
    FROM public.branch b JOIN public.company c ON c.id = b.company_id
   WHERE b.id = p_branch_id
  ON CONFLICT (branch_id, kind, nsu) WHERE deleted_at IS NULL DO NOTHING
  RETURNING id INTO inserted;
  RETURN inserted IS NOT NULL;
END;
$$;

-- Nota de serviço em que a filial aparece. A recebida (filial tomadora) é a que vai para a tela.
CREATE TABLE service_invoice (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  branch_id uuid NOT NULL REFERENCES branch (id),
  document_id uuid NOT NULL REFERENCES dfe_document (id),
  -- received: a filial é tomadora. issued: a filial prestou o serviço. intermediary: só intermediou.
  role text NOT NULL CONSTRAINT service_invoice_role_check CHECK (role IN ('received', 'issued', 'intermediary')),
  access_key text NOT NULL CONSTRAINT service_invoice_access_key_check CHECK (access_key ~ '^[0-9]{50}$'),
  number text NOT NULL CONSTRAINT service_invoice_number_check CHECK (number ~ '^[0-9]{1,15}$'),
  environment smallint NOT NULL CONSTRAINT service_invoice_environment_check CHECK (environment IN (1, 2)),
  issued_at timestamptz NOT NULL,
  competence date NOT NULL,
  processed_at timestamptz,
  provider_document text CONSTRAINT service_invoice_provider_document_check CHECK (provider_document ~ '^([0-9]{11}|[0-9A-Z]{12}[0-9]{2})$'),
  provider_name text NOT NULL CONSTRAINT service_invoice_provider_name_check CHECK (btrim(provider_name) <> '' AND length(provider_name) <= 300),
  provider_location text CONSTRAINT service_invoice_provider_location_check CHECK (length(provider_location) <= 150),
  taker_document text CONSTRAINT service_invoice_taker_document_check CHECK (taker_document ~ '^([0-9]{11}|[0-9A-Z]{12}[0-9]{2})$'),
  service_code text CONSTRAINT service_invoice_service_code_check CHECK (service_code ~ '^[0-9]{6}$'),
  municipal_code text CONSTRAINT service_invoice_municipal_code_check CHECK (length(municipal_code) <= 20),
  nbs_code text CONSTRAINT service_invoice_nbs_code_check CHECK (nbs_code ~ '^[0-9]{9}$'),
  description text NOT NULL CONSTRAINT service_invoice_description_check CHECK (btrim(description) <> '' AND length(description) <= 2000),
  incidence_location text CONSTRAINT service_invoice_incidence_location_check CHECK (length(incidence_location) <= 150),
  service_value numeric(15, 2) NOT NULL CONSTRAINT service_invoice_service_value_check CHECK (service_value >= 0),
  unconditional_discount numeric(15, 2) NOT NULL DEFAULT 0 CONSTRAINT service_invoice_discount_check CHECK (unconditional_discount >= 0),
  deductions numeric(15, 2) NOT NULL DEFAULT 0 CONSTRAINT service_invoice_deductions_check CHECK (deductions >= 0),
  iss_base numeric(15, 2) CONSTRAINT service_invoice_iss_base_check CHECK (iss_base >= 0),
  iss_rate numeric(7, 4) CONSTRAINT service_invoice_iss_rate_check CHECK (iss_rate >= 0),
  iss_value numeric(15, 2) NOT NULL DEFAULT 0 CONSTRAINT service_invoice_iss_value_check CHECK (iss_value >= 0),
  -- tpRetISSQN: 1 não retido, 2 retido pelo tomador, 3 retido pelo intermediário.
  iss_withholding smallint CONSTRAINT service_invoice_iss_withholding_check CHECK (iss_withholding IN (1, 2, 3)),
  irrf_withheld numeric(15, 2) NOT NULL DEFAULT 0 CONSTRAINT service_invoice_irrf_check CHECK (irrf_withheld >= 0),
  csll_withheld numeric(15, 2) NOT NULL DEFAULT 0 CONSTRAINT service_invoice_csll_check CHECK (csll_withheld >= 0),
  social_security_withheld numeric(15, 2) NOT NULL DEFAULT 0 CONSTRAINT service_invoice_social_security_check CHECK (social_security_withheld >= 0),
  pis_value numeric(15, 2) NOT NULL DEFAULT 0 CONSTRAINT service_invoice_pis_check CHECK (pis_value >= 0),
  cofins_value numeric(15, 2) NOT NULL DEFAULT 0 CONSTRAINT service_invoice_cofins_check CHECK (cofins_value >= 0),
  -- tpRetPisCofins: de 0 a 9, como no leiaute; a tela traduz.
  pis_cofins_withholding smallint CONSTRAINT service_invoice_pis_cofins_withholding_check CHECK (pis_cofins_withholding BETWEEN 0 AND 9),
  total_withheld numeric(15, 2) NOT NULL DEFAULT 0 CONSTRAINT service_invoice_total_withheld_check CHECK (total_withheld >= 0),
  net_value numeric(15, 2) NOT NULL CONSTRAINT service_invoice_net_value_check CHECK (net_value >= 0),
  -- Chave da nota que esta substitui (chSubstda).
  replaces_key text CONSTRAINT service_invoice_replaces_key_check CHECK (replaces_key ~ '^[0-9]{50}$'),
  status text NOT NULL DEFAULT 'active' CONSTRAINT service_invoice_status_check CHECK (status IN ('active', 'cancelled', 'replaced')),
  status_changed_at timestamptz,
  replaced_by uuid REFERENCES service_invoice (id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid,
  CONSTRAINT service_invoice_status_date_check CHECK ((status = 'active') = (status_changed_at IS NULL))
);
CREATE UNIQUE INDEX service_invoice_access_key ON service_invoice (economic_group_id, access_key) WHERE deleted_at IS NULL;
CREATE INDEX service_invoice_branch_recent_idx ON service_invoice (branch_id, issued_at DESC, id DESC);
CREATE INDEX service_invoice_document_id_idx ON service_invoice (document_id);
CREATE INDEX service_invoice_replaced_by_idx ON service_invoice (replaced_by) WHERE replaced_by IS NOT NULL;
CALL app.apply_table_standard('public.service_invoice');
-- O que veio do XML não muda: só a situação.
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON service_invoice
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'branch_id', 'document_id', 'role', 'access_key', 'number', 'environment', 'issued_at',
    'competence', 'processed_at', 'provider_document', 'provider_name', 'provider_location', 'taker_document',
    'service_code', 'municipal_code', 'nbs_code', 'description', 'incidence_location', 'service_value',
    'unconditional_discount', 'deductions', 'iss_base', 'iss_rate', 'iss_value', 'iss_withholding', 'irrf_withheld',
    'csll_withheld', 'social_security_withheld', 'pis_value', 'cofins_value', 'pis_cofins_withholding',
    'total_withheld', 'net_value', 'replaces_key', 'deleted_at'
  );

CREATE VIEW v_service_invoice WITH (security_invoker = true) AS
  SELECT * FROM service_invoice WHERE deleted_at IS NULL;
GRANT SELECT ON v_service_invoice TO farmaerp_app;

-- Filiais com o download ligado, certificado válido e hora de buscar NFS-e.
CREATE FUNCTION app.dfe_claim_nfse_branches(p_limit integer DEFAULT 10)
RETURNS TABLE (
  branch_id uuid, company_id uuid, cnpj text, last_nsu text, encrypted_pfx bytea, encrypted_password bytea
)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM app.require_dfe_worker();
  RETURN QUERY
  WITH due AS (
    SELECT s.id
      FROM public.branch_dfe_sync s
      JOIN public.branch b ON b.id = s.branch_id AND b.deleted_at IS NULL
      JOIN public.branch_certificate bc ON bc.branch_id = s.branch_id AND bc.deleted_at IS NULL
           AND bc.valid_to > pg_catalog.now()
     WHERE s.enabled AND s.deleted_at IS NULL AND s.nfse_next_run_at <= pg_catalog.now()
       AND (s.nfse_locked_until IS NULL OR s.nfse_locked_until < pg_catalog.now())
     ORDER BY s.nfse_next_run_at
     LIMIT LEAST(GREATEST(COALESCE(p_limit, 10), 1), 50)
     FOR UPDATE OF s SKIP LOCKED
  ), claimed AS (
    UPDATE public.branch_dfe_sync s SET nfse_locked_until = pg_catalog.now() + interval '10 minutes'
      FROM due WHERE s.id = due.id
    RETURNING s.branch_id, s.nfse_last_nsu
  )
  SELECT c.branch_id, b.company_id, b.cnpj::text, c.nfse_last_nsu, bc.encrypted_pfx, bc.encrypted_password
    FROM claimed c
    JOIN public.branch b ON b.id = c.branch_id
    JOIN public.branch_certificate bc ON bc.branch_id = c.branch_id AND bc.deleted_at IS NULL;
END;
$$;

CREATE FUNCTION app.dfe_finish_nfse_branch(p_branch_id uuid, p_result jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  wait_minutes integer := LEAST(GREATEST(COALESCE((p_result ->> 'waitMinutes')::integer, 60), 1), 1440);
BEGIN
  PERFORM app.require_dfe_worker();
  UPDATE public.branch_dfe_sync
     SET nfse_last_nsu = COALESCE(NULLIF(p_result ->> 'lastNsu', ''), nfse_last_nsu),
         nfse_last_status = NULLIF(p_result ->> 'status', ''),
         nfse_last_message = pg_catalog.left(NULLIF(p_result ->> 'message', ''), 500),
         nfse_last_error = NULLIF(p_result ->> 'error', ''),
         nfse_last_run_at = pg_catalog.clock_timestamp(),
         nfse_next_run_at = pg_catalog.clock_timestamp() + pg_catalog.make_interval(mins => wait_minutes),
         nfse_locked_until = NULL
   WHERE branch_id = p_branch_id AND deleted_at IS NULL;
END;
$$;

-- Guarda o documento do ADN e devolve o id dele, novo ou o que já existia com o mesmo NSU.
CREATE FUNCTION app.dfe_store_nfse_document(p_branch_id uuid, p_nsu text, p_type text, p_access_key text, p_xml text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  document_id uuid;
BEGIN
  PERFORM app.require_dfe_worker();
  INSERT INTO public.dfe_document (economic_group_id, branch_id, nsu, schema, access_key, xml, kind)
  SELECT c.economic_group_id, b.id, p_nsu, p_type, p_access_key, p_xml, 'nfse'
    FROM public.branch b JOIN public.company c ON c.id = b.company_id
   WHERE b.id = p_branch_id
  ON CONFLICT (branch_id, kind, nsu) WHERE deleted_at IS NULL DO NOTHING
  RETURNING id INTO document_id;
  IF document_id IS NULL THEN
    SELECT d.id INTO document_id FROM public.dfe_document d
     WHERE d.branch_id = p_branch_id AND d.kind = 'nfse' AND d.nsu = p_nsu AND d.deleted_at IS NULL;
  END IF;
  RETURN document_id;
END;
$$;

-- Troca a situação da nota e de quem ela substitui. Cancelada ou substituída não volta a valer.
CREATE FUNCTION app.mark_service_invoice(p_id uuid, p_status text, p_replaced_by uuid DEFAULT NULL) RETURNS void
LANGUAGE sql SECURITY DEFINER
SET search_path = ''
AS $$
  UPDATE public.service_invoice
     SET status = p_status, status_changed_at = pg_catalog.clock_timestamp(),
         replaced_by = COALESCE(p_replaced_by, replaced_by)
   WHERE id = p_id AND status = 'active' AND deleted_at IS NULL
$$;

-- Nota de serviço lida pela API. A filial é tomadora, prestadora ou intermediária conforme o CNPJ.
-- Chegar de novo não duplica. Se ela substitui outra, a outra passa a substituída.
CREATE FUNCTION app.nfse_record_invoice(p_branch_id uuid, p_document_id uuid, p_data jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.branch;
  group_id uuid;
  role_value text;
  invoice_id uuid;
  replaced public.service_invoice;
BEGIN
  PERFORM app.require_dfe_worker();
  SELECT b.* INTO target FROM public.branch b WHERE b.id = p_branch_id;
  SELECT c.economic_group_id INTO group_id FROM public.company c WHERE c.id = target.company_id;
  role_value := CASE
    WHEN p_data ->> 'takerDocument' = target.cnpj THEN 'received'
    WHEN p_data ->> 'providerDocument' = target.cnpj THEN 'issued'
    ELSE 'intermediary'
  END;
  SELECT s.id INTO invoice_id FROM public.service_invoice s
   WHERE s.economic_group_id = group_id AND s.access_key = p_data ->> 'accessKey' AND s.deleted_at IS NULL;
  IF FOUND THEN
    RETURN invoice_id;
  END IF;
  INSERT INTO public.service_invoice (
    economic_group_id, branch_id, document_id, role, access_key, number, environment, issued_at, competence, processed_at,
    provider_document, provider_name, provider_location, taker_document, service_code, municipal_code, nbs_code,
    description, incidence_location, service_value, unconditional_discount, deductions, iss_base, iss_rate, iss_value,
    iss_withholding, irrf_withheld, csll_withheld, social_security_withheld, pis_value, cofins_value,
    pis_cofins_withholding, total_withheld, net_value, replaces_key
  ) VALUES (
    group_id, p_branch_id, p_document_id, role_value, COALESCE(p_data ->> 'accessKey', ''), COALESCE(p_data ->> 'number', ''),
    (p_data ->> 'environment')::smallint, (p_data ->> 'issuedAt')::timestamptz, (p_data ->> 'competence')::date,
    (p_data ->> 'processedAt')::timestamptz, NULLIF(p_data ->> 'providerDocument', ''),
    COALESCE(pg_catalog.left(app.clean_text(p_data ->> 'providerName'), 300), ''),
    pg_catalog.left(app.clean_text(p_data ->> 'providerLocation'), 150), NULLIF(p_data ->> 'takerDocument', ''),
    NULLIF(p_data ->> 'serviceCode', ''), pg_catalog.left(app.clean_text(p_data ->> 'municipalCode'), 20),
    NULLIF(p_data ->> 'nbsCode', ''), COALESCE(pg_catalog.left(app.clean_text(p_data ->> 'description'), 2000), ''),
    pg_catalog.left(app.clean_text(p_data ->> 'incidenceLocation'), 150), (p_data ->> 'serviceValue')::numeric,
    COALESCE((p_data ->> 'unconditionalDiscount')::numeric, 0), COALESCE((p_data ->> 'deductions')::numeric, 0),
    (p_data ->> 'issBase')::numeric, (p_data ->> 'issRate')::numeric, COALESCE((p_data ->> 'issValue')::numeric, 0),
    (p_data ->> 'issWithholding')::smallint, COALESCE((p_data ->> 'irrf')::numeric, 0),
    COALESCE((p_data ->> 'csll')::numeric, 0), COALESCE((p_data ->> 'socialSecurity')::numeric, 0),
    COALESCE((p_data ->> 'pis')::numeric, 0), COALESCE((p_data ->> 'cofins')::numeric, 0),
    (p_data ->> 'pisCofinsWithholding')::smallint, COALESCE((p_data ->> 'totalWithheld')::numeric, 0),
    (p_data ->> 'netValue')::numeric, NULLIF(p_data ->> 'replacesKey', '')
  ) RETURNING id INTO invoice_id;

  IF p_data ->> 'replacesKey' IS NOT NULL THEN
    SELECT * INTO replaced FROM public.service_invoice s
     WHERE s.economic_group_id = group_id AND s.access_key = p_data ->> 'replacesKey' AND s.deleted_at IS NULL;
    IF FOUND THEN
      PERFORM app.mark_service_invoice(replaced.id, 'replaced', invoice_id);
    END IF;
  END IF;
  -- A substituta pode chegar antes da substituída: quem chega depois já vê a nova.
  UPDATE public.service_invoice SET status = 'replaced', status_changed_at = pg_catalog.clock_timestamp(),
         replaced_by = (SELECT s.id FROM public.service_invoice s
                         WHERE s.economic_group_id = group_id AND s.replaces_key = p_data ->> 'accessKey' AND s.deleted_at IS NULL
                         LIMIT 1)
   WHERE id = invoice_id AND EXISTS (
     SELECT 1 FROM public.service_invoice s
      WHERE s.economic_group_id = group_id AND s.replaces_key = p_data ->> 'accessKey' AND s.deleted_at IS NULL
   );
  RETURN invoice_id;
END;
$$;

-- Evento da NFS-e: cancelamento (101101) ou cancelamento por substituição (105102).
CREATE FUNCTION app.nfse_record_event(p_branch_id uuid, p_access_key text, p_kind text, p_substitute_key text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid;
  target public.service_invoice;
  substitute uuid;
BEGIN
  PERFORM app.require_dfe_worker();
  SELECT c.economic_group_id INTO group_id FROM public.branch b JOIN public.company c ON c.id = b.company_id WHERE b.id = p_branch_id;
  SELECT * INTO target FROM public.service_invoice s
   WHERE s.economic_group_id = group_id AND s.access_key = p_access_key AND s.deleted_at IS NULL;
  IF NOT FOUND THEN
    RETURN;
  END IF;
  IF p_kind = 'cancel' THEN
    PERFORM app.mark_service_invoice(target.id, 'cancelled');
  ELSIF p_kind = 'replace' THEN
    SELECT s.id INTO substitute FROM public.service_invoice s
     WHERE s.economic_group_id = group_id AND s.access_key = p_substitute_key AND s.deleted_at IS NULL;
    PERFORM app.mark_service_invoice(target.id, 'replaced', substitute);
  END IF;
END;
$$;

-- Liga e desliga NF-e e NFS-e juntas. Ligar põe as duas na fila na hora.
CREATE OR REPLACE FUNCTION app.set_dfe_sync(p_branch_id uuid, p_enabled boolean) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.branch := app.require_branch_permission('fiscal.certificate', p_branch_id);
BEGIN
  INSERT INTO public.branch_dfe_sync (economic_group_id, branch_id, enabled)
  SELECT c.economic_group_id, target.id, COALESCE(p_enabled, false)
    FROM public.company c WHERE c.id = target.company_id
  ON CONFLICT (branch_id) WHERE deleted_at IS NULL
  DO UPDATE SET enabled = EXCLUDED.enabled,
                next_run_at = CASE WHEN EXCLUDED.enabled AND NOT public.branch_dfe_sync.enabled
                                   THEN LEAST(public.branch_dfe_sync.next_run_at, pg_catalog.now())
                                   ELSE public.branch_dfe_sync.next_run_at END,
                nfse_next_run_at = CASE WHEN EXCLUDED.enabled AND NOT public.branch_dfe_sync.enabled
                                        THEN LEAST(public.branch_dfe_sync.nfse_next_run_at, pg_catalog.now())
                                        ELSE public.branch_dfe_sync.nfse_next_run_at END;
END;
$$;

-- A situação do download na tela fiscal passa a mostrar também a NFS-e.
DROP FUNCTION app.dfe_sync_status();
CREATE FUNCTION app.dfe_sync_status()
RETURNS TABLE (
  branch_id uuid, branch_name text, enabled boolean, has_certificate boolean, certificate_valid_to timestamptz,
  last_run_at timestamptz, next_run_at timestamptz, last_status text, last_message text, last_error text,
  waiting_awareness bigint, can_manage boolean,
  nfse_last_run_at timestamptz, nfse_next_run_at timestamptz, nfse_last_status text, nfse_last_message text,
  nfse_last_error text
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT b.id, b.name, COALESCE(s.enabled, false), bc.id IS NOT NULL AND bc.valid_to > pg_catalog.now(), bc.valid_to,
         s.last_run_at, s.next_run_at, s.last_status, s.last_message, s.last_error,
         (SELECT pg_catalog.count(*) FROM public.purchase_invoice_summary ps
           WHERE ps.branch_id = b.id AND ps.deleted_at IS NULL AND ps.invoice_id IS NULL AND ps.awareness_at IS NULL
             AND ps.situation = 1),
         app.has_permission('fiscal.certificate', b.id),
         s.nfse_last_run_at, s.nfse_next_run_at, s.nfse_last_status, s.nfse_last_message, s.nfse_last_error
    FROM public.branch b
    JOIN public.company c ON c.id = b.company_id AND c.economic_group_id = app.current_user_group()
    LEFT JOIN public.branch_dfe_sync s ON s.branch_id = b.id AND s.deleted_at IS NULL
    LEFT JOIN public.branch_certificate bc ON bc.branch_id = b.id AND bc.deleted_at IS NULL
   WHERE b.deleted_at IS NULL
     AND (app.has_permission('fiscal.view', b.id) OR app.has_permission('fiscal.certificate', b.id))
   ORDER BY b.name
$$;

-- Notas de serviço recebidas nas filiais que a pessoa vê, com filtro de período e situação.
CREATE FUNCTION app.list_service_invoices(
  p_branch_id uuid DEFAULT NULL, p_from date DEFAULT NULL, p_to date DEFAULT NULL, p_status text DEFAULT NULL,
  p_limit integer DEFAULT 200
)
RETURNS TABLE (
  id uuid, branch_id uuid, branch_name text, number text, issued_at timestamptz, competence text,
  provider_document text, provider_name text, provider_location text, description text, service_value numeric,
  iss_value numeric, iss_withholding smallint, total_withheld numeric, net_value numeric, status text
)
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  -- A competência sai como texto (AAAA-MM-DD): convertida em data, mudaria de dia com o fuso do servidor.
  SELECT s.id, s.branch_id, b.name, s.number, s.issued_at, s.competence::text, s.provider_document, s.provider_name,
         s.provider_location, s.description, s.service_value, s.iss_value, s.iss_withholding, s.total_withheld,
         s.net_value, s.status
    FROM public.v_service_invoice s
    JOIN public.branch b ON b.id = s.branch_id
   WHERE s.role = 'received'
     AND (p_branch_id IS NULL OR s.branch_id = p_branch_id)
     AND (p_from IS NULL OR s.competence >= p_from)
     AND (p_to IS NULL OR s.competence <= p_to)
     AND (p_status IS NULL OR s.status = p_status)
   ORDER BY s.issued_at DESC, s.id DESC
   LIMIT LEAST(GREATEST(COALESCE(p_limit, 200), 1), 1000)
$$;

CREATE POLICY service_invoice_select ON service_invoice FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group())
         AND (app.has_permission('purchases.view', branch_id) OR app.has_permission('purchases.manage', branch_id)));
GRANT SELECT ON service_invoice TO farmaerp_app;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  app.dfe_store_document(uuid, text, text, text, text),
  app.dfe_claim_nfse_branches(integer),
  app.dfe_finish_nfse_branch(uuid, jsonb),
  app.dfe_store_nfse_document(uuid, text, text, text, text),
  app.nfse_record_invoice(uuid, uuid, jsonb),
  app.nfse_record_event(uuid, text, text, text),
  app.set_dfe_sync(uuid, boolean),
  app.dfe_sync_status(),
  app.list_service_invoices(uuid, date, date, text, integer)
TO farmaerp_app;
