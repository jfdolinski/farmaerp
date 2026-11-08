-- Up Migration

-- Configuração fiscal: regime da empresa e, por filial, inscrição estadual, CSC da NFC-e e
-- certificado A1. CSC e certificado chegam já criptografados pela API (AES-256-GCM, com a chave
-- que só o servidor conhece): o banco nunca vê o conteúdo aberto, e a API nem consegue ler de volta.

-- Soma ponderada de dígitos, usada pelos cálculos de cada estado.
CREATE FUNCTION app.weighted_sum(p_digits text, p_weights int[]) RETURNS int
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$
  SELECT COALESCE(pg_catalog.sum((pg_catalog.substr(p_digits, i, 1))::int * p_weights[i]), 0)::int
    FROM pg_catalog.generate_series(1, pg_catalog.array_length(p_weights, 1)) AS i
$$;

-- Módulo 11 mais comum: resto 0 ou 1 vira 0, senão 11 menos o resto.
CREATE FUNCTION app.mod11_digit(p_sum int) RETURNS int
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$
  SELECT CASE WHEN p_sum % 11 < 2 THEN 0 ELSE 11 - p_sum % 11 END
$$;

-- Dígito verificador da inscrição estadual, pelo roteiro de cada estado no SINTEGRA.
-- Recebe só dígitos (e o P do produtor rural de SP) e o estado.
CREATE FUNCTION app.state_registration_digits_ok(p_ie text, p_state text) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE
SET search_path = ''
AS $$
DECLARE
  len int := pg_catalog.length(p_ie);
  base text;
  sum1 int;
  sum2 int;
  d1 int;
  d2 int;
  p int;
  d int;
  number bigint;
  mg text;
  mod_ten boolean;
BEGIN
  IF p_ie IS NULL OR p_state IS NULL THEN
    RETURN false;
  END IF;
  -- Só o produtor rural de SP tem letra.
  IF p_ie !~ '^[0-9]+$' AND NOT (p_state = 'SP' AND p_ie ~ '^P[0-9]{12}$') THEN
    RETURN false;
  END IF;

  CASE p_state
  WHEN 'AC', 'DF' THEN
    -- O prefixo vem antes: dentro de um IF, o PL/pgSQL corta a condição no primeiro THEN, até o de um CASE.
    base := CASE p_state WHEN 'AC' THEN '01' ELSE '07' END;
    IF len <> 13 OR pg_catalog.substr(p_ie, 1, 2) <> base THEN
      RETURN false;
    END IF;
    d1 := 11 - app.weighted_sum(p_ie, ARRAY[4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2]) % 11;
    IF d1 >= 10 THEN d1 := 0; END IF;
    d2 := 11 - (app.weighted_sum(p_ie, ARRAY[5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3]) + d1 * 2) % 11;
    IF d2 >= 10 THEN d2 := 0; END IF;
    RETURN pg_catalog.substr(p_ie, 12, 2) = d1::text || d2::text;

  WHEN 'AL' THEN
    IF len <> 9 OR pg_catalog.substr(p_ie, 1, 2) <> '24' OR pg_catalog.substr(p_ie, 3, 1) NOT IN ('0', '3', '5', '7', '8') THEN
      RETURN false;
    END IF;
    d := (app.weighted_sum(p_ie, ARRAY[9, 8, 7, 6, 5, 4, 3, 2]) * 10) % 11;
    IF d = 10 THEN d := 0; END IF;
    RETURN pg_catalog.substr(p_ie, 9, 1)::int = d;

  WHEN 'AM' THEN
    IF len <> 9 THEN RETURN false; END IF;
    sum1 := app.weighted_sum(p_ie, ARRAY[9, 8, 7, 6, 5, 4, 3, 2]);
    d := CASE WHEN sum1 < 11 THEN 11 - sum1 ELSE app.mod11_digit(sum1) END;
    RETURN d < 10 AND pg_catalog.substr(p_ie, 9, 1)::int = d;

  WHEN 'AP' THEN
    IF len <> 9 OR pg_catalog.substr(p_ie, 1, 2) <> '03' THEN RETURN false; END IF;
    number := pg_catalog.substr(p_ie, 1, 8)::bigint;
    IF number BETWEEN 3000001 AND 3017000 THEN p := 5; d := 0;
    ELSIF number BETWEEN 3017001 AND 3019022 THEN p := 9; d := 1;
    ELSE p := 0; d := 0;
    END IF;
    d1 := 11 - (p + app.weighted_sum(p_ie, ARRAY[9, 8, 7, 6, 5, 4, 3, 2])) % 11;
    IF d1 = 10 THEN d1 := 0; ELSIF d1 = 11 THEN d1 := d; END IF;
    RETURN pg_catalog.substr(p_ie, 9, 1)::int = d1;

  WHEN 'BA' THEN
    IF len NOT IN (8, 9) THEN RETURN false; END IF;
    -- Com 8 dígitos decide o primeiro algarismo; com 9, o segundo.
    mod_ten := pg_catalog.substr(p_ie, CASE len WHEN 8 THEN 1 ELSE 2 END, 1) IN ('0', '1', '2', '3', '4', '5', '8');
    base := pg_catalog.substr(p_ie, 1, len - 2);
    -- O último dígito é calculado primeiro, sobre a base.
    sum2 := app.weighted_sum(base, CASE len WHEN 8 THEN ARRAY[7, 6, 5, 4, 3, 2] ELSE ARRAY[8, 7, 6, 5, 4, 3, 2] END);
    d2 := CASE WHEN mod_ten THEN (10 - sum2 % 10) % 10 ELSE app.mod11_digit(sum2) END;
    sum1 := app.weighted_sum(base || d2::text, CASE len WHEN 8 THEN ARRAY[8, 7, 6, 5, 4, 3, 2] ELSE ARRAY[9, 8, 7, 6, 5, 4, 3, 2] END);
    d1 := CASE WHEN mod_ten THEN (10 - sum1 % 10) % 10 ELSE app.mod11_digit(sum1) END;
    RETURN pg_catalog.substr(p_ie, len - 1, 2) = d1::text || d2::text;

  WHEN 'CE', 'PB', 'PI', 'SE' THEN
    IF len <> 9 THEN RETURN false; END IF;
    d := 11 - app.weighted_sum(p_ie, ARRAY[9, 8, 7, 6, 5, 4, 3, 2]) % 11;
    IF d >= 10 THEN d := 0; END IF;
    RETURN pg_catalog.substr(p_ie, 9, 1)::int = d;

  WHEN 'ES', 'SC' THEN
    IF len <> 9 THEN RETURN false; END IF;
    RETURN pg_catalog.substr(p_ie, 9, 1)::int = app.mod11_digit(app.weighted_sum(p_ie, ARRAY[9, 8, 7, 6, 5, 4, 3, 2]));

  WHEN 'GO' THEN
    IF len <> 9 OR NOT (pg_catalog.substr(p_ie, 1, 2) IN ('10', '11') OR pg_catalog.substr(p_ie, 1, 2) BETWEEN '20' AND '29') THEN
      RETURN false;
    END IF;
    RETURN pg_catalog.substr(p_ie, 9, 1)::int = app.mod11_digit(app.weighted_sum(p_ie, ARRAY[9, 8, 7, 6, 5, 4, 3, 2]));

  WHEN 'MA' THEN
    IF len <> 9 OR pg_catalog.substr(p_ie, 1, 2) <> '12' THEN RETURN false; END IF;
    RETURN pg_catalog.substr(p_ie, 9, 1)::int = app.mod11_digit(app.weighted_sum(p_ie, ARRAY[9, 8, 7, 6, 5, 4, 3, 2]));

  WHEN 'MG' THEN
    IF len <> 13 THEN RETURN false; END IF;
    -- Primeiro dígito: um zero depois do município, pesos 1 e 2 alternados e soma dos algarismos.
    mg := pg_catalog.substr(p_ie, 1, 3) || '0' || pg_catalog.substr(p_ie, 4, 8);
    sum1 := 0;
    FOR i IN 1..12 LOOP
      p := pg_catalog.substr(mg, i, 1)::int * CASE WHEN i % 2 = 1 THEN 1 ELSE 2 END;
      sum1 := sum1 + p / 10 + p % 10;
    END LOOP;
    d1 := (10 - sum1 % 10) % 10;
    -- Segundo dígito: pesos de 2 a 11 da direita para a esquerda, recomeçando em 2.
    sum2 := app.weighted_sum(pg_catalog.substr(p_ie, 1, 11) || d1::text, ARRAY[3, 2, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2]);
    d2 := app.mod11_digit(sum2);
    RETURN pg_catalog.substr(p_ie, 12, 2) = d1::text || d2::text;

  WHEN 'MS' THEN
    IF len <> 9 OR pg_catalog.substr(p_ie, 1, 2) NOT IN ('28', '50') THEN RETURN false; END IF;
    sum1 := app.weighted_sum(p_ie, ARRAY[9, 8, 7, 6, 5, 4, 3, 2]);
    d := CASE WHEN sum1 % 11 = 0 THEN 0 WHEN 11 - sum1 % 11 > 9 THEN 0 ELSE 11 - sum1 % 11 END;
    RETURN pg_catalog.substr(p_ie, 9, 1)::int = d;

  WHEN 'MT' THEN
    IF len <> 11 THEN RETURN false; END IF;
    RETURN pg_catalog.substr(p_ie, 11, 1)::int = app.mod11_digit(app.weighted_sum(p_ie, ARRAY[3, 2, 9, 8, 7, 6, 5, 4, 3, 2]));

  WHEN 'PA' THEN
    IF len <> 9 OR pg_catalog.substr(p_ie, 1, 2) NOT IN ('15', '75', '76', '77', '78', '79') THEN RETURN false; END IF;
    RETURN pg_catalog.substr(p_ie, 9, 1)::int = app.mod11_digit(app.weighted_sum(p_ie, ARRAY[9, 8, 7, 6, 5, 4, 3, 2]));

  WHEN 'PE' THEN
    IF len = 9 THEN
      d1 := app.mod11_digit(app.weighted_sum(p_ie, ARRAY[8, 7, 6, 5, 4, 3, 2]));
      d2 := app.mod11_digit(app.weighted_sum(pg_catalog.substr(p_ie, 1, 7) || d1::text, ARRAY[9, 8, 7, 6, 5, 4, 3, 2]));
      RETURN pg_catalog.substr(p_ie, 8, 2) = d1::text || d2::text;
    ELSIF len = 14 THEN
      -- Formato antigo do CACEPE.
      d := 11 - app.weighted_sum(p_ie, ARRAY[5, 4, 3, 2, 1, 9, 8, 7, 6, 5, 4, 3, 2]) % 11;
      IF d > 9 THEN d := d - 10; END IF;
      RETURN pg_catalog.substr(p_ie, 14, 1)::int = d;
    END IF;
    RETURN false;

  WHEN 'PR' THEN
    IF len <> 10 THEN RETURN false; END IF;
    d1 := 11 - app.weighted_sum(p_ie, ARRAY[3, 2, 7, 6, 5, 4, 3, 2]) % 11;
    IF d1 >= 10 THEN d1 := 0; END IF;
    d2 := 11 - app.weighted_sum(pg_catalog.substr(p_ie, 1, 8) || d1::text, ARRAY[4, 3, 2, 7, 6, 5, 4, 3, 2]) % 11;
    IF d2 >= 10 THEN d2 := 0; END IF;
    RETURN pg_catalog.substr(p_ie, 9, 2) = d1::text || d2::text;

  WHEN 'RJ' THEN
    IF len <> 8 THEN RETURN false; END IF;
    RETURN pg_catalog.substr(p_ie, 8, 1)::int = app.mod11_digit(app.weighted_sum(p_ie, ARRAY[2, 7, 6, 5, 4, 3, 2]));

  WHEN 'RN' THEN
    IF len NOT IN (9, 10) OR pg_catalog.substr(p_ie, 1, 2) <> '20' THEN RETURN false; END IF;
    d := (app.weighted_sum(p_ie, CASE len WHEN 9 THEN ARRAY[9, 8, 7, 6, 5, 4, 3, 2] ELSE ARRAY[10, 9, 8, 7, 6, 5, 4, 3, 2] END) * 10) % 11;
    IF d = 10 THEN d := 0; END IF;
    RETURN pg_catalog.substr(p_ie, len, 1)::int = d;

  WHEN 'RO' THEN
    IF len = 9 THEN
      -- Formato anterior a 2000: só os 5 dígitos da empresa entram no cálculo.
      d := 11 - app.weighted_sum(pg_catalog.substr(p_ie, 4, 5), ARRAY[6, 5, 4, 3, 2]) % 11;
    ELSIF len = 14 THEN
      d := 11 - app.weighted_sum(p_ie, ARRAY[6, 5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2]) % 11;
    ELSE
      RETURN false;
    END IF;
    IF d >= 10 THEN d := d - 10; END IF;
    RETURN pg_catalog.substr(p_ie, len, 1)::int = d;

  WHEN 'RR' THEN
    IF len <> 9 OR pg_catalog.substr(p_ie, 1, 2) <> '24' THEN RETURN false; END IF;
    RETURN pg_catalog.substr(p_ie, 9, 1)::int = app.weighted_sum(p_ie, ARRAY[1, 2, 3, 4, 5, 6, 7, 8]) % 9;

  WHEN 'RS' THEN
    IF len <> 10 THEN RETURN false; END IF;
    d := 11 - app.weighted_sum(p_ie, ARRAY[2, 9, 8, 7, 6, 5, 4, 3, 2]) % 11;
    IF d >= 10 THEN d := 0; END IF;
    RETURN pg_catalog.substr(p_ie, 10, 1)::int = d;

  WHEN 'SP' THEN
    IF len = 13 AND pg_catalog.left(p_ie, 1) = 'P' THEN
      -- Produtor rural: P, 8 dígitos, o verificador e mais 3 dígitos que não entram no cálculo.
      d := app.weighted_sum(pg_catalog.substr(p_ie, 2, 8), ARRAY[1, 3, 4, 5, 6, 7, 8, 10]) % 11 % 10;
      RETURN pg_catalog.substr(p_ie, 10, 1)::int = d;
    ELSIF len = 12 THEN
      d1 := app.weighted_sum(p_ie, ARRAY[1, 3, 4, 5, 6, 7, 8, 10]) % 11 % 10;
      d2 := app.weighted_sum(p_ie, ARRAY[3, 2, 10, 9, 8, 7, 6, 5, 4, 3, 2]) % 11 % 10;
      RETURN pg_catalog.substr(p_ie, 9, 1)::int = d1 AND pg_catalog.substr(p_ie, 12, 1)::int = d2;
    END IF;
    RETURN false;

  WHEN 'TO' THEN
    IF len = 11 THEN
      -- Os dígitos 3 e 4 são o tipo de empresa e não entram no cálculo.
      IF pg_catalog.substr(p_ie, 3, 2) NOT IN ('01', '02', '03', '99') THEN RETURN false; END IF;
      base := pg_catalog.substr(p_ie, 1, 2) || pg_catalog.substr(p_ie, 5, 6);
      RETURN pg_catalog.substr(p_ie, 11, 1)::int = app.mod11_digit(app.weighted_sum(base, ARRAY[9, 8, 7, 6, 5, 4, 3, 2]));
    ELSIF len = 9 THEN
      -- O formato de 9 dígitos não está no roteiro do SINTEGRA: usa o módulo 11 padrão.
      RETURN pg_catalog.substr(p_ie, 9, 1)::int = app.mod11_digit(app.weighted_sum(p_ie, ARRAY[9, 8, 7, 6, 5, 4, 3, 2]));
    END IF;
    RETURN false;

  ELSE
    RETURN false;
  END CASE;
END;
$$;

-- Agora a conferência inclui o dígito. ISENTO continua aceito.
CREATE OR REPLACE FUNCTION app.is_valid_state_registration(p_registration text, p_state text) RETURNS boolean
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$
  SELECT p_registration = 'ISENTO' OR app.state_registration_digits_ok(p_registration, p_state)
$$;

-- O P do produtor rural de SP passa a ser mantido.
CREATE OR REPLACE FUNCTION app.clean_state_registration(p_value text) RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$
  SELECT CASE
    WHEN pg_catalog.upper(pg_catalog.btrim(COALESCE(p_value, ''))) = 'ISENTO' THEN 'ISENTO'
    ELSE NULLIF(pg_catalog.regexp_replace(pg_catalog.upper(COALESCE(p_value, '')), '[^0-9P]', '', 'g'), '')
  END
$$;

-- A regra ficou mais exigente. Um cadastro antigo que não passe nela não pode travar o deploy:
-- nesse caso a constraint fica valendo só para o que for gravado daqui em diante, e o aviso
-- aparece no log da migration.
ALTER TABLE customer DROP CONSTRAINT customer_state_registration_check;
ALTER TABLE customer ADD CONSTRAINT customer_state_registration_check CHECK (
  state_registration IS NULL OR app.is_valid_state_registration(state_registration, state)
) NOT VALID;
DO $$
DECLARE
  invalid_count int;
BEGIN
  SELECT count(*) INTO invalid_count FROM customer
   WHERE state_registration IS NOT NULL AND NOT app.is_valid_state_registration(state_registration, state);
  IF invalid_count = 0 THEN
    ALTER TABLE customer VALIDATE CONSTRAINT customer_state_registration_check;
  ELSE
    RAISE WARNING 'Há % cliente(s) com inscrição estadual que não confere com o dígito. Corrija pela tela.', invalid_count;
  END IF;
END;
$$;

-- Regime tributário da empresa, pelo código CRT da nota: 1 Simples Nacional, 2 Simples com
-- excesso de sublimite, 3 Regime Normal, 4 MEI. Vale para todas as filiais da empresa.
ALTER TABLE company ADD COLUMN tax_regime smallint CONSTRAINT company_tax_regime_check CHECK (tax_regime IN (1, 2, 3, 4));
CREATE OR REPLACE VIEW v_company WITH (security_invoker = true) AS
  SELECT * FROM company WHERE deleted_at IS NULL;

-- A inscrição estadual é de cada estabelecimento, então fica na filial.
ALTER TABLE branch
  ADD COLUMN state_registration text,
  ADD CONSTRAINT branch_state_registration_check CHECK (
    state_registration IS NULL OR app.is_valid_state_registration(state_registration, state)
  );
CREATE OR REPLACE VIEW v_branch WITH (security_invoker = true) AS
  SELECT * FROM branch WHERE deleted_at IS NULL;

-- Certificado A1 da filial. O arquivo e a senha chegam criptografados; os dados de exibição
-- (titular, CNPJ e validade) chegam abertos, lidos pela API do próprio arquivo.
CREATE TABLE branch_certificate (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  branch_id uuid NOT NULL REFERENCES branch (id),
  subject_name text NOT NULL CONSTRAINT branch_certificate_subject_check CHECK (btrim(subject_name) <> '' AND length(subject_name) <= 300),
  cnpj text NOT NULL CONSTRAINT branch_certificate_cnpj_check CHECK (app.is_valid_cnpj(cnpj)),
  valid_from timestamptz NOT NULL,
  valid_to timestamptz NOT NULL,
  fingerprint text NOT NULL CONSTRAINT branch_certificate_fingerprint_check CHECK (fingerprint ~ '^[0-9a-f]{64}$'),
  encrypted_pfx bytea NOT NULL,
  encrypted_password bytea NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid,
  CONSTRAINT branch_certificate_validity_check CHECK (valid_to > valid_from)
);
-- Um certificado em uso por filial; os anteriores ficam como histórico.
CREATE UNIQUE INDEX branch_certificate_active_key ON branch_certificate (branch_id) WHERE deleted_at IS NULL;

-- CSC da NFC-e: o identificador é aberto, o código vai criptografado.
CREATE TABLE branch_csc (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  branch_id uuid NOT NULL REFERENCES branch (id),
  csc_id text NOT NULL CONSTRAINT branch_csc_id_check CHECK (csc_id ~ '^[0-9]{1,6}$'),
  encrypted_token bytea NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE UNIQUE INDEX branch_csc_active_key ON branch_csc (branch_id) WHERE deleted_at IS NULL;

CALL app.apply_table_standard('public.branch_certificate');
CALL app.apply_table_standard('public.branch_csc');

-- Trocar é encerrar e incluir: o conteúdo de uma linha nunca muda.
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON branch_certificate
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns(
    'economic_group_id', 'branch_id', 'subject_name', 'cnpj', 'valid_from', 'valid_to', 'fingerprint',
    'encrypted_pfx', 'encrypted_password'
  );
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON branch_csc
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns('economic_group_id', 'branch_id', 'csc_id', 'encrypted_token');

INSERT INTO permission (code, module, name) VALUES
  ('fiscal.view', 'Fiscal', 'Ver a configuração fiscal'),
  ('fiscal.manage', 'Fiscal', 'Alterar regime, inscrição estadual e séries'),
  ('fiscal.certificate', 'Fiscal', 'Atualizar certificado A1 e CSC da filial');

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
     'products.view', 'stock.view', 'stock.loss', 'stock.transfer', 'stock.batch_override',
     'customers.view', 'customers.manage', 'fiscal.certificate'
   );
END;
$$;

-- Grupos que já existem: o Gerente, identificado pelo nome, cuida do certificado da loja dele.
INSERT INTO role_permission (role_id, permission_id)
SELECT r.id, p.id
  FROM role r
 CROSS JOIN permission p
 WHERE r.name = 'Gerente' AND r.deleted_at IS NULL AND p.code = 'fiscal.certificate';

CREATE FUNCTION app.require_branch_permission(p_code text, p_branch_id uuid) RETURNS public.branch
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.branch;
BEGIN
  SELECT b.* INTO target FROM public.branch b
    JOIN public.company c ON c.id = b.company_id
   WHERE b.id = p_branch_id AND b.deleted_at IS NULL AND c.economic_group_id = app.current_user_group();
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('branch %s.', p_branch_id);
  END IF;
  IF NOT app.has_permission(p_code, p_branch_id) THEN
    RAISE EXCEPTION 'Você não tem permissão para esta operação.'
      USING ERRCODE = 'FA002', DETAIL = pg_catalog.format('%s na filial %s.', p_code, p_branch_id);
  END IF;
  RETURN target;
END;
$$;

CREATE FUNCTION app.set_company_tax_regime(p_company_id uuid, p_regime smallint) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT app.company_has_permission(p_company_id, 'fiscal.manage') THEN
    RAISE EXCEPTION 'Você não tem permissão para esta operação.'
      USING ERRCODE = 'FA002', DETAIL = pg_catalog.format('fiscal.manage na empresa %s.', p_company_id);
  END IF;
  IF p_regime IS NULL THEN
    RAISE EXCEPTION 'O regime tributário informado é inválido.'
      USING ERRCODE = 'FA917', DETAIL = pg_catalog.format('Empresa %s.', p_company_id);
  END IF;
  UPDATE public.company c SET tax_regime = p_regime WHERE c.id = p_company_id AND c.deleted_at IS NULL;
END;
$$;

CREATE FUNCTION app.set_branch_state_registration(p_branch_id uuid, p_registration text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.branch := app.require_branch_permission('fiscal.manage', p_branch_id);
BEGIN
  UPDATE public.branch b SET state_registration = app.clean_state_registration(p_registration) WHERE b.id = target.id;
END;
$$;

-- A API já conferiu a senha e leu os dados do arquivo; aqui ficam as regras que o banco consegue
-- garantir sozinho: mesma raiz de CNPJ da empresa e certificado ainda válido.
CREATE FUNCTION app.set_branch_certificate(
  p_branch_id uuid, p_meta jsonb, p_encrypted_pfx bytea, p_encrypted_password bytea
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.branch := app.require_branch_permission('fiscal.certificate', p_branch_id);
  root text;
  new_id uuid;
BEGIN
  SELECT c.cnpj_root INTO root FROM public.company c WHERE c.id = target.company_id;
  IF pg_catalog.left(p_meta ->> 'cnpj', 8) IS DISTINCT FROM root THEN
    RAISE EXCEPTION 'O certificado é de outra empresa.'
      USING ERRCODE = 'FA913', DETAIL = pg_catalog.format('Filial %s.', p_branch_id);
  END IF;
  IF (p_meta ->> 'validTo')::timestamptz <= pg_catalog.now() THEN
    RAISE EXCEPTION 'O certificado está vencido.'
      USING ERRCODE = 'FA914', DETAIL = pg_catalog.format('Filial %s.', p_branch_id);
  END IF;

  UPDATE public.branch_certificate bc SET deleted_at = pg_catalog.clock_timestamp()
   WHERE bc.branch_id = target.id AND bc.deleted_at IS NULL;
  INSERT INTO public.branch_certificate (
    economic_group_id, branch_id, subject_name, cnpj, valid_from, valid_to, fingerprint,
    encrypted_pfx, encrypted_password
  ) VALUES (
    app.current_user_group(), target.id, p_meta ->> 'subjectName', p_meta ->> 'cnpj',
    (p_meta ->> 'validFrom')::timestamptz, (p_meta ->> 'validTo')::timestamptz, p_meta ->> 'fingerprint',
    p_encrypted_pfx, p_encrypted_password
  ) RETURNING id INTO new_id;
  RETURN new_id;
END;
$$;

-- Mesmo certificado em outras filiais da mesma empresa, sem mandar o arquivo de novo.
CREATE FUNCTION app.copy_branch_certificate(p_source_branch_id uuid, p_target_branch_ids uuid[]) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  source_branch public.branch := app.require_branch_permission('fiscal.certificate', p_source_branch_id);
  source public.branch_certificate;
  target_id uuid;
  target public.branch;
  copied integer := 0;
BEGIN
  SELECT * INTO source FROM public.branch_certificate bc
   WHERE bc.branch_id = source_branch.id AND bc.deleted_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('Filial %s sem certificado.', p_source_branch_id);
  END IF;

  FOR target_id IN SELECT DISTINCT value FROM pg_catalog.unnest(p_target_branch_ids) AS value WHERE value <> source_branch.id LOOP
    target := app.require_branch_permission('fiscal.certificate', target_id);
    IF target.company_id <> source_branch.company_id THEN
      RAISE EXCEPTION 'O certificado é de outra empresa.'
        USING ERRCODE = 'FA913', DETAIL = pg_catalog.format('Filial %s.', target_id);
    END IF;
    UPDATE public.branch_certificate bc SET deleted_at = pg_catalog.clock_timestamp()
     WHERE bc.branch_id = target.id AND bc.deleted_at IS NULL;
    INSERT INTO public.branch_certificate (
      economic_group_id, branch_id, subject_name, cnpj, valid_from, valid_to, fingerprint,
      encrypted_pfx, encrypted_password
    ) VALUES (
      source.economic_group_id, target.id, source.subject_name, source.cnpj, source.valid_from,
      source.valid_to, source.fingerprint, source.encrypted_pfx, source.encrypted_password
    );
    copied := copied + 1;
  END LOOP;
  RETURN copied;
END;
$$;

CREATE FUNCTION app.set_branch_csc(p_branch_id uuid, p_csc_id text, p_encrypted_token bytea) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.branch := app.require_branch_permission('fiscal.certificate', p_branch_id);
  new_id uuid;
BEGIN
  UPDATE public.branch_csc bc SET deleted_at = pg_catalog.clock_timestamp()
   WHERE bc.branch_id = target.id AND bc.deleted_at IS NULL;
  INSERT INTO public.branch_csc (economic_group_id, branch_id, csc_id, encrypted_token)
  VALUES (app.current_user_group(), target.id, pg_catalog.btrim(COALESCE(p_csc_id, '')), p_encrypted_token)
  RETURNING id INTO new_id;
  RETURN new_id;
END;
$$;

CREATE POLICY branch_certificate_select ON branch_certificate FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group())
         AND branch_id = ANY ((SELECT app.allowed_branch_ids())::uuid[])
         AND (app.has_permission('fiscal.view', branch_id) OR app.has_permission('fiscal.manage', branch_id)
              OR app.has_permission('fiscal.certificate', branch_id)));
CREATE POLICY branch_csc_select ON branch_csc FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group())
         AND branch_id = ANY ((SELECT app.allowed_branch_ids())::uuid[])
         AND (app.has_permission('fiscal.view', branch_id) OR app.has_permission('fiscal.manage', branch_id)
              OR app.has_permission('fiscal.certificate', branch_id)));

-- A API lê só os dados de exibição: o conteúdo criptografado não sai do banco por ela.
GRANT SELECT (id, economic_group_id, branch_id, subject_name, cnpj, valid_from, valid_to, fingerprint,
              created_at, updated_at, deleted_at, version, updated_by, trace_id)
  ON branch_certificate TO farmaerp_app;
GRANT SELECT (id, economic_group_id, branch_id, csc_id, created_at, updated_at, deleted_at, version,
              updated_by, trace_id)
  ON branch_csc TO farmaerp_app;

CREATE VIEW v_branch_certificate WITH (security_invoker = true) AS
  SELECT id, economic_group_id, branch_id, subject_name, cnpj, valid_from, valid_to, fingerprint,
         created_at, updated_at, deleted_at, version, updated_by, trace_id
    FROM branch_certificate WHERE deleted_at IS NULL;
CREATE VIEW v_branch_csc WITH (security_invoker = true) AS
  SELECT id, economic_group_id, branch_id, csc_id, created_at, updated_at, deleted_at, version, updated_by, trace_id
    FROM branch_csc WHERE deleted_at IS NULL;
GRANT SELECT ON v_branch_certificate, v_branch_csc TO farmaerp_app;

-- Situação fiscal de cada filial que o usuário pode ver no fiscal.
CREATE FUNCTION app.fiscal_overview()
RETURNS TABLE (
  company_id uuid, company_name text, cnpj_root text, tax_regime smallint, branch_id uuid, branch_name text,
  branch_cnpj text, state text, state_registration text, certificate_subject text, certificate_cnpj text,
  certificate_valid_to timestamptz, certificate_days_left integer, certificate_updated_at timestamptz,
  certificate_author text, csc_id text, csc_updated_at timestamptz, can_regime boolean, can_manage boolean, can_certificate boolean
)
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT c.id, c.trade_name, c.cnpj_root::text, c.tax_regime, b.id, b.name, b.cnpj::text, b.state::text,
         b.state_registration, bc.subject_name, bc.cnpj, bc.valid_to,
         CASE WHEN bc.valid_to IS NULL THEN NULL
              ELSE (bc.valid_to::date - app.local_today())::integer END,
         bc.created_at, u.name, cs.csc_id, cs.created_at,
         app.company_has_permission(c.id, 'fiscal.manage'), app.has_permission('fiscal.manage', b.id), app.has_permission('fiscal.certificate', b.id)
    FROM public.branch b
    JOIN public.company c ON c.id = b.company_id AND c.deleted_at IS NULL
    LEFT JOIN public.v_branch_certificate bc ON bc.branch_id = b.id
    LEFT JOIN public.user_account u ON u.id = bc.updated_by
    LEFT JOIN public.v_branch_csc cs ON cs.branch_id = b.id
   WHERE b.deleted_at IS NULL
     AND (app.has_permission('fiscal.view', b.id) OR app.has_permission('fiscal.manage', b.id)
          OR app.has_permission('fiscal.certificate', b.id))
   ORDER BY c.trade_name, b.name
$$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  app.is_valid_state_registration(text, text),
  app.clean_state_registration(text),
  app.require_branch_permission(text, uuid),
  app.set_company_tax_regime(uuid, smallint),
  app.set_branch_state_registration(uuid, text),
  app.set_branch_certificate(uuid, jsonb, bytea, bytea),
  app.copy_branch_certificate(uuid, uuid[]),
  app.set_branch_csc(uuid, text, bytea),
  app.fiscal_overview()
TO farmaerp_app;
