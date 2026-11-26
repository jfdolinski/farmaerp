-- Up Migration

-- NFC-e no caixa, parte 1 (8A-2a): o certificado A1 e o CSC descem para o caixa.
-- A central continua dona do certificado. Cada caixa tem uma chave de criptografia própria
-- (X25519), registrada com a assinatura da chave do terminal; a API abre o certificado só
-- durante a entrega e o cifra para aquele caixa. O banco guarda quando e o que foi entregue,
-- nunca o conteúdo aberto.
-- A emissão é ligada filial por filial ("Emitir NFC-e"), começando em homologação.

ALTER TABLE branch ADD COLUMN nfce_enabled boolean NOT NULL DEFAULT false;
ALTER TABLE branch ADD COLUMN nfce_environment smallint NOT NULL DEFAULT 2
  CONSTRAINT branch_nfce_environment_check CHECK (nfce_environment IN (1, 2));
-- Prazo para transmitir a nota emitida sem internet (contingência). O caixa avisa na metade.
ALTER TABLE branch ADD COLUMN nfce_contingency_hours smallint NOT NULL DEFAULT 24
  CONSTRAINT branch_nfce_contingency_hours_check CHECK (nfce_contingency_hours BETWEEN 1 AND 168);

-- Chave pública X25519 do caixa (base64url, 32 bytes). Trocá-la invalida o que já desceu.
ALTER TABLE terminal ADD COLUMN fiscal_key text
  CONSTRAINT terminal_fiscal_key_check CHECK (fiscal_key ~ '^[A-Za-z0-9_-]{43}$');
ALTER TABLE terminal ADD COLUMN fiscal_key_at timestamptz;

-- Cada entrega do certificado e do CSC a um caixa.
CREATE TABLE terminal_credential_delivery (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  terminal_id uuid NOT NULL REFERENCES terminal (id),
  branch_id uuid NOT NULL REFERENCES branch (id),
  certificate_id uuid NOT NULL REFERENCES branch_certificate (id),
  csc_id uuid NOT NULL REFERENCES branch_csc (id),
  fiscal_key text NOT NULL CONSTRAINT terminal_credential_delivery_key_check CHECK (fiscal_key ~ '^[A-Za-z0-9_-]{43}$'),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE INDEX terminal_credential_delivery_terminal_idx ON terminal_credential_delivery (terminal_id, created_at DESC);
CREATE INDEX terminal_credential_delivery_branch_idx ON terminal_credential_delivery (branch_id);
CREATE INDEX terminal_credential_delivery_economic_group_id_idx ON terminal_credential_delivery (economic_group_id);
CALL app.apply_table_standard('public.terminal_credential_delivery');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON terminal_credential_delivery
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'terminal_id', 'branch_id', 'certificate_id', 'csc_id', 'fiscal_key', 'deleted_at'
  );
CREATE POLICY terminal_credential_delivery_select ON terminal_credential_delivery FOR SELECT TO farmaerp_app
  USING (EXISTS (SELECT 1 FROM terminal t WHERE t.id = terminal_credential_delivery.terminal_id));
CREATE VIEW v_terminal_credential_delivery WITH (security_invoker = true) AS
  SELECT * FROM terminal_credential_delivery WHERE deleted_at IS NULL;
GRANT SELECT ON terminal_credential_delivery, v_terminal_credential_delivery TO farmaerp_app;

-- Estados em que a NFC-e já é montada pelo PDV (endereços conferidos por UF).
CREATE FUNCTION app.nfce_supported_state(p_state text) RETURNS boolean
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$ SELECT p_state IN ('SP', 'PR', 'RS', 'SC', 'MG') $$;

-- Versão do que o caixa deve ter: certificado e CSC em uso (as linhas não mudam, são trocadas).
CREATE FUNCTION app.nfce_credential_version(p_branch_id uuid) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT bc.id::text || ':' || cs.id::text
    FROM public.branch_certificate bc
    JOIN public.branch_csc cs ON cs.branch_id = bc.branch_id AND cs.deleted_at IS NULL
   WHERE bc.branch_id = p_branch_id AND bc.deleted_at IS NULL
$$;

-- Liga ou desliga a emissão. Para ligar, a filial precisa estar completa (FA727) e num estado
-- atendido (FA725), com certificado dentro da validade (FA943).
CREATE FUNCTION app.set_branch_nfce(p_branch_id uuid, p_enabled boolean, p_environment smallint, p_contingency_hours smallint)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.branch := app.require_branch_permission('fiscal.manage', p_branch_id);
  regime smallint;
BEGIN
  IF p_enabled IS NULL OR p_environment IS NULL OR p_environment NOT IN (1, 2)
     OR p_contingency_hours IS NULL OR p_contingency_hours NOT BETWEEN 1 AND 168 THEN
    RAISE EXCEPTION 'A configuração da NFC-e é inválida.' USING ERRCODE = 'FA728';
  END IF;
  IF p_enabled THEN
    SELECT c.tax_regime INTO regime FROM public.company c WHERE c.id = target.company_id;
    IF NOT app.nfce_supported_state(target.state) THEN
      RAISE EXCEPTION 'A NFC-e ainda não é emitida no estado desta filial.' USING ERRCODE = 'FA725';
    END IF;
    IF regime IS NULL OR target.state_registration IS NULL OR target.state_registration = 'ISENTO'
       OR NOT EXISTS (SELECT 1 FROM public.branch_csc cs WHERE cs.branch_id = target.id AND cs.deleted_at IS NULL) THEN
      RAISE EXCEPTION 'A filial ainda não pode emitir NFC-e.' USING ERRCODE = 'FA727';
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM public.branch_certificate bc
       WHERE bc.branch_id = target.id AND bc.deleted_at IS NULL AND bc.valid_to > pg_catalog.now()
    ) THEN
      RAISE EXCEPTION 'A filial não tem certificado digital válido.' USING ERRCODE = 'FA943';
    END IF;
  END IF;
  UPDATE public.branch b
     SET nfce_enabled = p_enabled, nfce_environment = p_environment, nfce_contingency_hours = p_contingency_hours
   WHERE b.id = target.id;
END;
$$;

-- Situação da NFC-e por filial, para a tela fiscal.
CREATE FUNCTION app.nfce_settings()
RETURNS TABLE (
  branch_id uuid, enabled boolean, environment smallint, contingency_hours smallint, state_supported boolean,
  has_state_registration boolean, has_regime boolean, has_certificate boolean, has_csc boolean,
  terminals integer, terminals_ready integer, can_manage boolean
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT b.id, b.nfce_enabled, b.nfce_environment, b.nfce_contingency_hours, app.nfce_supported_state(b.state),
         b.state_registration IS NOT NULL AND b.state_registration <> 'ISENTO', c.tax_regime IS NOT NULL,
         EXISTS (SELECT 1 FROM public.branch_certificate bc
                  WHERE bc.branch_id = b.id AND bc.deleted_at IS NULL AND bc.valid_to > pg_catalog.now()),
         EXISTS (SELECT 1 FROM public.branch_csc cs WHERE cs.branch_id = b.id AND cs.deleted_at IS NULL),
         (SELECT pg_catalog.count(*)::integer FROM public.terminal t
           WHERE t.branch_id = b.id AND t.deleted_at IS NULL AND t.status = 'active' AND t.profile IN ('cashier', 'self_service')),
         -- Pronto: a última entrega ao caixa é do certificado e do CSC em uso, para a chave atual dele.
         (SELECT pg_catalog.count(*)::integer FROM public.terminal t
           WHERE t.branch_id = b.id AND t.deleted_at IS NULL AND t.status = 'active' AND t.profile IN ('cashier', 'self_service')
             AND (SELECT d.certificate_id::text || ':' || d.csc_id::text FROM public.terminal_credential_delivery d
                   WHERE d.terminal_id = t.id AND d.fiscal_key = t.fiscal_key AND d.deleted_at IS NULL
                   ORDER BY d.created_at DESC LIMIT 1) = app.nfce_credential_version(b.id)),
         app.has_permission('fiscal.manage', b.id)
    FROM public.branch b
    JOIN public.company c ON c.id = b.company_id AND c.deleted_at IS NULL
   WHERE b.deleted_at IS NULL
     AND c.economic_group_id = app.current_user_group()
     AND (app.has_permission('fiscal.view', b.id) OR app.has_permission('fiscal.manage', b.id)
          OR app.has_permission('fiscal.certificate', b.id))
   ORDER BY c.trade_name, b.name
$$;

-- O caixa registra a chave de criptografia (a assinatura é conferida pela API com a chave do terminal).
CREATE FUNCTION app.set_terminal_fiscal_key(p_key text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  current_terminal public.terminal := app.require_active_terminal();
BEGIN
  IF p_key IS NULL OR p_key !~ '^[A-Za-z0-9_-]{43}$' THEN
    RAISE EXCEPTION 'Não foi possível confirmar a chave de criptografia do terminal.' USING ERRCODE = 'FA731';
  END IF;
  IF current_terminal.fiscal_key IS DISTINCT FROM p_key THEN
    UPDATE public.terminal t SET fiscal_key = p_key, fiscal_key_at = pg_catalog.now() WHERE t.id = current_terminal.id;
  END IF;
END;
$$;

-- O que a API precisa para montar a entrega ao caixa: o conteúdo ainda cifrado com a chave do
-- servidor e a chave do caixa. Cada chamada fica registrada.
CREATE FUNCTION app.terminal_nfce_credentials() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  current_terminal public.terminal := app.require_active_terminal();
  target public.branch;
  certificate public.branch_certificate;
  csc public.branch_csc;
BEGIN
  IF current_terminal.profile NOT IN ('cashier', 'self_service') THEN
    RAISE EXCEPTION 'Este terminal não emite NFC-e.' USING ERRCODE = 'FA729';
  END IF;
  SELECT b.* INTO target FROM public.branch b WHERE b.id = current_terminal.branch_id;
  IF NOT target.nfce_enabled THEN
    RAISE EXCEPTION 'A NFC-e não está ligada nesta filial.' USING ERRCODE = 'FA730';
  END IF;
  IF current_terminal.fiscal_key IS NULL THEN
    RAISE EXCEPTION 'Não foi possível confirmar a chave de criptografia do terminal.' USING ERRCODE = 'FA731';
  END IF;
  SELECT bc.* INTO certificate FROM public.branch_certificate bc WHERE bc.branch_id = target.id AND bc.deleted_at IS NULL;
  IF certificate.id IS NULL OR certificate.valid_to <= pg_catalog.now() THEN
    RAISE EXCEPTION 'A filial não tem certificado digital válido.' USING ERRCODE = 'FA943';
  END IF;
  SELECT cs.* INTO csc FROM public.branch_csc cs WHERE cs.branch_id = target.id AND cs.deleted_at IS NULL;
  IF csc.id IS NULL THEN
    RAISE EXCEPTION 'A filial ainda não pode emitir NFC-e.' USING ERRCODE = 'FA727';
  END IF;
  INSERT INTO public.terminal_credential_delivery (economic_group_id, terminal_id, branch_id, certificate_id, csc_id, fiscal_key)
  VALUES (certificate.economic_group_id, current_terminal.id, target.id, certificate.id, csc.id, current_terminal.fiscal_key);
  RETURN pg_catalog.jsonb_build_object(
    'terminal_id', current_terminal.id,
    'company_id', target.company_id,
    'branch_id', target.id,
    'credential_version', certificate.id::text || ':' || csc.id::text,
    'fiscal_key', current_terminal.fiscal_key,
    'fingerprint', certificate.fingerprint,
    'valid_to', certificate.valid_to,
    'encrypted_pfx', pg_catalog.encode(certificate.encrypted_pfx, 'base64'),
    'encrypted_password', pg_catalog.encode(certificate.encrypted_password, 'base64'),
    'csc_id', csc.csc_id,
    'encrypted_csc', pg_catalog.encode(csc.encrypted_token, 'base64')
  );
END;
$$;

-- Troca de certificado ou de CSC desce como mudança fiscal: o caixa busca a versão nova.
CREATE FUNCTION app.track_nfce_credential() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM app.mark_sync_change('fiscal', NEW.branch_id, NEW.economic_group_id, NEW.branch_id);
  RETURN NULL;
END;
$$;
CREATE TRIGGER track_nfce_credential AFTER INSERT OR UPDATE ON branch_certificate
  FOR EACH ROW EXECUTE FUNCTION app.track_nfce_credential();
CREATE TRIGGER track_nfce_credential AFTER INSERT OR UPDATE ON branch_csc
  FOR EACH ROW EXECUTE FUNCTION app.track_nfce_credential();

-- Dados fiscais do PDV: a NFC-e da filial e a versão do certificado e do CSC em uso.
CREATE OR REPLACE FUNCTION app.pdv_fiscal_data(p_branch_id uuid, p_terminal_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT pg_catalog.jsonb_build_object(
           'branch', pg_catalog.jsonb_build_object(
             'id', b.id, 'name', b.name, 'cnpj', b.cnpj, 'state_registration', b.state_registration,
             'state', b.state, 'pmc_region', b.pmc_region, 'postal_code', b.postal_code, 'street', b.street,
             'street_number', b.street_number, 'complement', b.complement, 'district', b.district,
             'city', b.city, 'city_code', b.city_code, 'phone', b.phone
           ),
           'company', pg_catalog.jsonb_build_object(
             'id', c.id, 'legal_name', c.legal_name, 'trade_name', c.trade_name, 'tax_regime', c.tax_regime
           ),
           'nfce', pg_catalog.jsonb_build_object(
             'enabled', b.nfce_enabled,
             'environment', b.nfce_environment,
             'contingency_hours', b.nfce_contingency_hours,
             'credential_version', CASE WHEN b.nfce_enabled THEN app.nfce_credential_version(b.id) END
           ),
           'offline_zero_stock_minutes', COALESCE(
             (SELECT t.offline_zero_stock_minutes FROM public.terminal t WHERE t.id = p_terminal_id),
             b.offline_zero_stock_minutes
           ),
           'terminal_profile', (SELECT t.profile FROM public.terminal t WHERE t.id = p_terminal_id),
           'fixed_seller_id', (SELECT t.fixed_seller_id FROM public.terminal t WHERE t.id = p_terminal_id),
           'quote_validity_days', b.quote_validity_days,
           'return_days', b.return_days,
           'last_return_number', (
             SELECT pg_catalog.max(r.number) FROM public.sale_return r WHERE r.terminal_id = p_terminal_id AND r.deleted_at IS NULL
           ),
           'seller_pin_required', b.seller_pin_required,
           'last_quote_number', (
             SELECT pg_catalog.max(q.number) FROM public.quote q WHERE q.terminal_id = p_terminal_id AND q.deleted_at IS NULL
           ),
           'last_sale_number', (
             SELECT pg_catalog.max(s.number) FROM public.sale s WHERE s.terminal_id = p_terminal_id AND s.deleted_at IS NULL
           ),
           'series', COALESCE((
             SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
                      'id', s.id, 'model', s.model, 'series', s.series, 'initial_number', s.initial_number,
                      'last_used_number', s.last_used_number) ORDER BY s.model)
               FROM public.terminal_fiscal_series s
              WHERE s.terminal_id = p_terminal_id AND s.deleted_at IS NULL
           ), '[]'::jsonb)
         )
    FROM public.branch b
    JOIN public.company c ON c.id = b.company_id
   WHERE b.id = p_branch_id AND b.deleted_at IS NULL
$$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  app.nfce_supported_state(text),
  app.set_branch_nfce(uuid, boolean, smallint, smallint),
  app.nfce_settings(),
  app.set_terminal_fiscal_key(text),
  app.terminal_nfce_credentials()
TO farmaerp_app;
