-- Up Migration

-- Cadastro de produtos: Catálogo global (só leitura para a API), produto da loja, estrutura
-- comercial e códigos de barras. Toda escrita da API passa pelas funções app.* deste arquivo.

-- Busca sem diferenciar acentos. As extensões ficam em schema próprio para não se misturarem
-- às funções do sistema, cujo acesso é revogado em bloco.
CREATE SCHEMA ext;
REVOKE ALL ON SCHEMA ext FROM PUBLIC;
GRANT USAGE ON SCHEMA ext TO farmaerp_app;
CREATE EXTENSION pg_trgm SCHEMA ext;
CREATE EXTENSION unaccent SCHEMA ext;

-- unaccent não é IMMUTABLE porque o dicionário pode mudar; aqui ele é fixo, e isso permite indexar.
CREATE FUNCTION app.normalize_search(p_text text) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path = ''
AS $$
  SELECT pg_catalog.lower(ext.unaccent('ext.unaccent'::regdictionary, COALESCE(p_text, '')))
$$;

-- Um padrão LIKE por palavra, com os caracteres especiais escapados.
CREATE FUNCTION app.search_patterns(p_query text) RETURNS text[]
LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path = ''
AS $$
  SELECT COALESCE(pg_catalog.array_agg(
           '%' || pg_catalog.regexp_replace(term, '([\\%_])', '\\\1', 'g') || '%'
           ORDER BY position
         ), '{}')
    FROM pg_catalog.regexp_split_to_table(
           pg_catalog.btrim(app.normalize_search(p_query)), '\s+'
         ) WITH ORDINALITY AS terms(term, position)
   WHERE term <> ''
$$;

-- GTIN-8, 12, 13 ou 14, com dígito verificador.
CREATE FUNCTION app.is_valid_gtin(p_code text) RETURNS boolean
LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path = ''
AS $$
  -- CASE garante a ordem: só converte para número depois de conferir que são dígitos.
  SELECT CASE WHEN p_code ~ '^([0-9]{8}|[0-9]{12,14})$' THEN (
    SELECT pg_catalog.sum(
             (pg_catalog.substr(p_code, digit_position, 1))::integer
             * CASE WHEN (pg_catalog.length(p_code) - digit_position) % 2 = 1 THEN 3 ELSE 1 END
           ) % 10 = 0
      FROM pg_catalog.generate_series(1, pg_catalog.length(p_code)) AS digit_position
  ) ELSE false END
$$;

CREATE TABLE catalog_manufacturer (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  name text NOT NULL CHECK (btrim(name) <> ''),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE UNIQUE INDEX catalog_manufacturer_name_active_key
  ON catalog_manufacturer (name) WHERE deleted_at IS NULL;

CREATE TABLE catalog_product (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  -- Identificador do item na origem do Catálogo: é o que torna a importação idempotente.
  source_key text NOT NULL CHECK (btrim(source_key) <> ''),
  name text NOT NULL CHECK (btrim(name) <> ''),
  active_ingredient text,
  manufacturer_id uuid REFERENCES catalog_manufacturer (id),
  ms_registration text CHECK (ms_registration ~ '^[0-9]{9,13}$'),
  -- Listas da Portaria 344/98 e antimicrobianos. Vazio significa não controlado.
  controlled_class text CHECK (controlled_class IN (
    'A1', 'A2', 'A3', 'B1', 'B2', 'C1', 'C2', 'C3', 'C4', 'C5', 'D1', 'antimicrobial'
  )),
  ncm text CHECK (ncm ~ '^[0-9]{8}$'),
  cest text CHECK (cest ~ '^[0-9]{7}$'),
  search_text text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE UNIQUE INDEX catalog_product_source_key_active_key
  ON catalog_product (source_key) WHERE deleted_at IS NULL;
CREATE INDEX catalog_product_manufacturer_id_idx ON catalog_product (manufacturer_id);
CREATE INDEX catalog_product_search_idx ON catalog_product USING gin (search_text ext.gin_trgm_ops);

CREATE TABLE catalog_product_barcode (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  catalog_product_id uuid NOT NULL REFERENCES catalog_product (id),
  code text NOT NULL CONSTRAINT catalog_product_barcode_gtin_check CHECK (app.is_valid_gtin(code)),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE UNIQUE INDEX catalog_product_barcode_code_active_key
  ON catalog_product_barcode (code) WHERE deleted_at IS NULL;
CREATE INDEX catalog_product_barcode_product_idx ON catalog_product_barcode (catalog_product_id);

-- Departamento (1) > categoria (2) > subcategoria (3).
CREATE TABLE product_category (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  parent_id uuid REFERENCES product_category (id),
  level smallint NOT NULL,
  name text NOT NULL CHECK (btrim(name) <> ''),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid,
  CONSTRAINT product_category_level_check CHECK (
    level BETWEEN 1 AND 3 AND (level = 1) = (parent_id IS NULL)
  )
);
CREATE UNIQUE INDEX product_category_name_active_key
  ON product_category (
    economic_group_id, COALESCE(parent_id, '00000000-0000-0000-0000-000000000000'::uuid), lower(name)
  ) WHERE deleted_at IS NULL;
CREATE INDEX product_category_parent_id_idx ON product_category (parent_id);

-- Grupos de comissão, de precificação e de preço (família).
CREATE TABLE product_group (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  kind text NOT NULL CHECK (kind IN ('commission', 'pricing', 'price_family')),
  name text NOT NULL CHECK (btrim(name) <> ''),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE UNIQUE INDEX product_group_name_active_key
  ON product_group (economic_group_id, kind, lower(name)) WHERE deleted_at IS NULL;

CREATE TABLE sales_channel (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  name text NOT NULL CHECK (btrim(name) <> ''),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE UNIQUE INDEX sales_channel_name_active_key
  ON sales_channel (economic_group_id, lower(name)) WHERE deleted_at IS NULL;

CREATE TABLE product (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  code bigint NOT NULL,
  -- Vazio: produto sem vínculo com o Catálogo, ainda sem tributação.
  catalog_product_id uuid REFERENCES catalog_product (id),
  display_name text NOT NULL CHECK (btrim(display_name) <> ''),
  own_manufacturer text,
  category_id uuid REFERENCES product_category (id),
  commission_group_id uuid REFERENCES product_group (id),
  pricing_group_id uuid REFERENCES product_group (id),
  price_family_id uuid REFERENCES product_group (id),
  uses_pmc boolean NOT NULL DEFAULT false,
  online_sale_blocked boolean NOT NULL DEFAULT false,
  fraction_quantity numeric(10, 3) NOT NULL DEFAULT 1 CHECK (fraction_quantity > 0),
  search_text text GENERATED ALWAYS AS (
    app.normalize_search(display_name || ' ' || COALESCE(own_manufacturer, ''))
  ) STORED,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid,
  -- Com Catálogo, o fabricante é o do Catálogo.
  CONSTRAINT product_manufacturer_source_check CHECK (
    catalog_product_id IS NULL OR own_manufacturer IS NULL
  )
);
CREATE UNIQUE INDEX product_catalog_active_key
  ON product (economic_group_id, catalog_product_id)
  WHERE deleted_at IS NULL AND catalog_product_id IS NOT NULL;
CREATE INDEX product_catalog_product_id_idx ON product (catalog_product_id);
CREATE INDEX product_category_id_idx ON product (category_id);
CREATE INDEX product_commission_group_id_idx ON product (commission_group_id);
CREATE INDEX product_pricing_group_id_idx ON product (pricing_group_id);
CREATE INDEX product_price_family_id_idx ON product (price_family_id);
CREATE INDEX product_search_idx ON product USING gin (search_text ext.gin_trgm_ops);

CREATE TABLE product_barcode (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  economic_group_id uuid NOT NULL REFERENCES economic_group (id),
  product_id uuid NOT NULL REFERENCES product (id),
  code text NOT NULL,
  -- Código criado pela loja, fora do padrão GTIN.
  is_internal boolean NOT NULL DEFAULT false,
  is_primary boolean NOT NULL DEFAULT false,
  sends_to_supplier boolean NOT NULL DEFAULT true,
  scan_enabled boolean NOT NULL DEFAULT true,
  -- Vazio: vale o fracionamento do produto.
  fraction_quantity numeric(10, 3) CHECK (fraction_quantity > 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid,
  CONSTRAINT product_barcode_code_check CHECK (code ~ '^[0-9A-Za-z]{1,30}$'),
  CONSTRAINT product_barcode_gtin_check CHECK (is_internal OR app.is_valid_gtin(code)),
  -- O principal vai para a etiqueta, então precisa ser lido no PDV.
  CONSTRAINT product_barcode_primary_scan_check CHECK (NOT is_primary OR scan_enabled)
);
CREATE UNIQUE INDEX product_barcode_code_active_key
  ON product_barcode (economic_group_id, code) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX product_barcode_primary_active_key
  ON product_barcode (product_id) WHERE deleted_at IS NULL AND is_primary;
CREATE INDEX product_barcode_product_id_idx ON product_barcode (product_id);

CREATE TABLE product_barcode_channel (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  barcode_id uuid NOT NULL REFERENCES product_barcode (id),
  channel_id uuid NOT NULL REFERENCES sales_channel (id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
CREATE UNIQUE INDEX product_barcode_channel_active_key
  ON product_barcode_channel (barcode_id, channel_id) WHERE deleted_at IS NULL;
CREATE INDEX product_barcode_channel_channel_id_idx ON product_barcode_channel (channel_id);

CALL app.apply_table_standard('public.catalog_manufacturer');
CALL app.apply_table_standard('public.catalog_product');
CALL app.apply_table_standard('public.catalog_product_barcode');
CALL app.apply_table_standard('public.product_category');
CALL app.apply_table_standard('public.product_group');
CALL app.apply_table_standard('public.sales_channel');
CALL app.apply_table_standard('public.product');
CALL app.apply_table_standard('public.product_barcode');
CALL app.apply_table_standard('public.product_barcode_channel');
CALL app.apply_human_code('public.product', 'product');

CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON catalog_product_barcode
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns('catalog_product_id', 'code');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON product_category
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns('economic_group_id', 'parent_id', 'level');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON product_group
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns('economic_group_id', 'kind');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON sales_channel
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns('economic_group_id');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON product
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns('economic_group_id');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON product_barcode
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns('economic_group_id', 'product_id', 'code', 'is_internal');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON product_barcode_channel
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns('barcode_id', 'channel_id');

-- Texto de busca do Catálogo, com o nome do fabricante.
CREATE FUNCTION app.set_catalog_search_text() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  NEW.search_text := app.normalize_search(
    pg_catalog.concat_ws(' ', NEW.name, NEW.active_ingredient, (
      SELECT m.name FROM public.catalog_manufacturer m WHERE m.id = NEW.manufacturer_id
    ))
  );
  RETURN NEW;
END;
$$;

CREATE TRIGGER set_search_text BEFORE INSERT OR UPDATE ON catalog_product
  FOR EACH ROW EXECUTE FUNCTION app.set_catalog_search_text();

-- Regras da estrutura, valendo para qualquer caminho de escrita.
CREATE FUNCTION app.validate_product_category() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  parent public.product_category;
BEGIN
  IF NEW.deleted_at IS NOT NULL THEN
    IF OLD.deleted_at IS NULL AND (
      EXISTS (SELECT 1 FROM public.product_category c WHERE c.parent_id = NEW.id AND c.deleted_at IS NULL)
      OR EXISTS (SELECT 1 FROM public.product p WHERE p.category_id = NEW.id AND p.deleted_at IS NULL)
    ) THEN
      RAISE EXCEPTION 'Este registro ainda tem itens ativos vinculados.'
        USING ERRCODE = 'FA105', DETAIL = pg_catalog.format('product_category %s.', NEW.id);
    END IF;
    RETURN NEW;
  END IF;

  IF NEW.parent_id IS NOT NULL THEN
    SELECT * INTO parent FROM public.product_category c
     WHERE c.id = NEW.parent_id AND c.deleted_at IS NULL;
    IF NOT FOUND
       OR parent.economic_group_id IS DISTINCT FROM NEW.economic_group_id
       OR parent.level <> NEW.level - 1 THEN
      RAISE EXCEPTION 'A estrutura de categorias é inválida.'
        USING ERRCODE = 'FA607', DETAIL = pg_catalog.format('product_category %s, pai %s.', NEW.id, NEW.parent_id);
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER validate_parent BEFORE INSERT OR UPDATE ON product_category
  FOR EACH ROW EXECUTE FUNCTION app.validate_product_category();

CREATE FUNCTION app.protect_product_group() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.product p
     WHERE p.deleted_at IS NULL
       AND NEW.id IN (p.commission_group_id, p.pricing_group_id, p.price_family_id)
  ) THEN
    RAISE EXCEPTION 'Este registro ainda tem itens ativos vinculados.'
      USING ERRCODE = 'FA105', DETAIL = pg_catalog.format('product_group %s.', NEW.id);
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER protect_links BEFORE UPDATE ON product_group
  FOR EACH ROW EXECUTE FUNCTION app.protect_product_group();

CREATE FUNCTION app.protect_sales_channel() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.product_barcode_channel bc
     WHERE bc.channel_id = NEW.id AND bc.deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Este registro ainda tem itens ativos vinculados.'
      USING ERRCODE = 'FA105', DETAIL = pg_catalog.format('sales_channel %s.', NEW.id);
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER protect_links BEFORE UPDATE ON sales_channel
  FOR EACH ROW EXECUTE FUNCTION app.protect_sales_channel();

-- Confere se o grupo é do tipo certo e do mesmo grupo econômico.
CREATE FUNCTION app.assert_product_group(p_group_id uuid, p_kind text, p_economic_group_id uuid) RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF p_group_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.product_group g
     WHERE g.id = p_group_id AND g.kind = p_kind
       AND g.economic_group_id = p_economic_group_id AND g.deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Um dos itens informados não foi encontrado.'
      USING ERRCODE = 'FA004', DETAIL = pg_catalog.format('product_group %s, tipo %s.', p_group_id, p_kind);
  END IF;
END;
$$;

CREATE FUNCTION app.validate_product() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NEW.deleted_at IS NOT NULL THEN
    RETURN NEW;
  END IF;

  IF NEW.category_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.product_category c
     WHERE c.id = NEW.category_id AND c.level = 3
       AND c.economic_group_id = NEW.economic_group_id AND c.deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Selecione uma subcategoria ativa.'
      USING ERRCODE = 'FA605', DETAIL = pg_catalog.format('product_category %s.', NEW.category_id);
  END IF;

  IF NEW.catalog_product_id IS NOT NULL
     AND (TG_OP = 'INSERT' OR NEW.catalog_product_id IS DISTINCT FROM OLD.catalog_product_id)
     AND NOT EXISTS (
       SELECT 1 FROM public.catalog_product cp
        WHERE cp.id = NEW.catalog_product_id AND cp.deleted_at IS NULL
     ) THEN
    RAISE EXCEPTION 'Um dos itens informados não foi encontrado.'
      USING ERRCODE = 'FA004', DETAIL = pg_catalog.format('catalog_product %s.', NEW.catalog_product_id);
  END IF;

  PERFORM app.assert_product_group(NEW.commission_group_id, 'commission', NEW.economic_group_id);
  PERFORM app.assert_product_group(NEW.pricing_group_id, 'pricing', NEW.economic_group_id);
  PERFORM app.assert_product_group(NEW.price_family_id, 'price_family', NEW.economic_group_id);
  RETURN NEW;
END;
$$;

CREATE TRIGGER validate_parent BEFORE INSERT OR UPDATE ON product
  FOR EACH ROW EXECUTE FUNCTION app.validate_product();

CREATE FUNCTION app.validate_product_barcode() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NEW.deleted_at IS NULL AND NOT EXISTS (
    SELECT 1 FROM public.product p
     WHERE p.id = NEW.product_id AND p.economic_group_id = NEW.economic_group_id AND p.deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Um dos itens informados não foi encontrado.'
      USING ERRCODE = 'FA004', DETAIL = pg_catalog.format('product %s.', NEW.product_id);
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER validate_parent BEFORE INSERT OR UPDATE ON product_barcode
  FOR EACH ROW EXECUTE FUNCTION app.validate_product_barcode();

CREATE FUNCTION app.validate_barcode_channel() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NEW.deleted_at IS NULL AND NOT EXISTS (
    SELECT 1
      FROM public.product_barcode b
      JOIN public.sales_channel c ON c.economic_group_id = b.economic_group_id
     WHERE b.id = NEW.barcode_id AND b.deleted_at IS NULL
       AND c.id = NEW.channel_id AND c.deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Um dos itens informados não foi encontrado.'
      USING ERRCODE = 'FA004', DETAIL = pg_catalog.format('sales_channel %s.', NEW.channel_id);
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER validate_parent BEFORE INSERT OR UPDATE ON product_barcode_channel
  FOR EACH ROW EXECUTE FUNCTION app.validate_barcode_channel();

-- Todo produto ativo termina a transação com um código principal. Fica para o fim da
-- transação porque o produto nasce antes do código, e a troca de principal é feita em dois passos.
CREATE FUNCTION app.assert_primary_barcode() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  -- Serve às duas tabelas: só product_barcode tem a coluna product_id.
  target_id uuid := COALESCE((pg_catalog.to_jsonb(NEW) ->> 'product_id')::uuid, NEW.id);
BEGIN
  IF EXISTS (SELECT 1 FROM public.product p WHERE p.id = target_id AND p.deleted_at IS NULL)
     AND NOT EXISTS (
       SELECT 1 FROM public.product_barcode b
        WHERE b.product_id = target_id AND b.is_primary AND b.deleted_at IS NULL
     ) THEN
    RAISE EXCEPTION 'O produto precisa ter um código de barras principal.'
      USING ERRCODE = 'FA603', DETAIL = pg_catalog.format('product %s.', target_id);
  END IF;
  RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER assert_primary_barcode AFTER INSERT OR UPDATE ON product
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION app.assert_primary_barcode();
CREATE CONSTRAINT TRIGGER assert_primary_barcode AFTER INSERT OR UPDATE ON product_barcode
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION app.assert_primary_barcode();

-- Fracionamento: o mais específico prevalece. O terceiro nível, da relação com o fornecedor,
-- chega com a entrada do XML.
CREATE FUNCTION app.effective_fraction(p_product_id uuid, p_barcode_id uuid DEFAULT NULL) RETURNS numeric
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT COALESCE(
    (SELECT b.fraction_quantity FROM public.product_barcode b
      WHERE b.id = p_barcode_id AND b.product_id = p_product_id AND b.deleted_at IS NULL),
    (SELECT p.fraction_quantity FROM public.product p WHERE p.id = p_product_id)
  )
$$;

-- Permissões novas. O Administrador recebe por ser perfil de sistema.
INSERT INTO permission (code, module, name) VALUES
  ('products.view', 'Produtos', 'Ver produtos'),
  ('products.manage', 'Produtos', 'Alterar cadastro, códigos de barras e estrutura'),
  ('products.price', 'Produtos', 'Alterar preços'),
  ('products.status', 'Produtos', 'Alterar status por filial'),
  ('products.reactivate', 'Produtos', 'Reativar produtos inativos');

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
     'products.view'
   );
END;
$$;

-- Grupos que já existem: o Gerente, identificado pelo nome, passa a ver produtos.
INSERT INTO role_permission (role_id, permission_id)
SELECT r.id, p.id
  FROM role r
 CROSS JOIN permission p
 WHERE r.name = 'Gerente' AND r.deleted_at IS NULL AND p.code = 'products.view';

-- Grupo do usuário, se ele puder alterar o cadastro em todas as filiais.
CREATE FUNCTION app.require_products_manage() RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.permission_group('products.manage');
BEGIN
  IF group_id IS NULL THEN
    RAISE EXCEPTION 'Você não tem permissão para esta operação.'
      USING ERRCODE = 'FA002', DETAIL = 'Alteração de produto sem products.manage.';
  END IF;
  RETURN group_id;
END;
$$;

-- Inclui um código e, opcionalmente, os canais. Ao ser o primeiro código, vira o principal.
CREATE FUNCTION app.insert_product_barcode(
  p_group_id uuid, p_product_id uuid, p_code text, p_is_internal boolean, p_is_primary boolean,
  p_sends_to_supplier boolean, p_scan_enabled boolean, p_fraction numeric, p_channels uuid[]
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  new_id uuid;
BEGIN
  INSERT INTO public.product_barcode (
    economic_group_id, product_id, code, is_internal, is_primary,
    sends_to_supplier, scan_enabled, fraction_quantity
  ) VALUES (
    p_group_id, p_product_id, pg_catalog.btrim(p_code), COALESCE(p_is_internal, false), p_is_primary,
    COALESCE(p_sends_to_supplier, true), COALESCE(p_scan_enabled, true), p_fraction
  ) RETURNING id INTO new_id;

  INSERT INTO public.product_barcode_channel (barcode_id, channel_id)
  SELECT new_id, channel_id
    FROM (SELECT DISTINCT pg_catalog.unnest(COALESCE(p_channels, '{}')) AS channel_id) AS requested;
  RETURN new_id;
END;
$$;

-- Cria o produto com o código principal. Vindo do Catálogo, os demais códigos do item também
-- entram, menos os que a rede já usa em outro produto.
CREATE FUNCTION app.create_product(p_data jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.require_products_manage();
  catalog_id uuid := (p_data ->> 'catalogProductId')::uuid;
  primary_code text := pg_catalog.btrim(p_data ->> 'barcode');
  new_id uuid;
BEGIN
  INSERT INTO public.product (
    economic_group_id, catalog_product_id, display_name, own_manufacturer, category_id,
    commission_group_id, pricing_group_id, price_family_id, uses_pmc, online_sale_blocked,
    fraction_quantity
  ) VALUES (
    group_id, catalog_id, pg_catalog.btrim(p_data ->> 'displayName'),
    CASE WHEN catalog_id IS NULL THEN NULLIF(pg_catalog.btrim(p_data ->> 'ownManufacturer'), '') END,
    (p_data ->> 'categoryId')::uuid, (p_data ->> 'commissionGroupId')::uuid,
    (p_data ->> 'pricingGroupId')::uuid, (p_data ->> 'priceFamilyId')::uuid,
    COALESCE((p_data ->> 'usesPmc')::boolean, false),
    COALESCE((p_data ->> 'onlineSaleBlocked')::boolean, false),
    COALESCE((p_data ->> 'fractionQuantity')::numeric, 1)
  ) RETURNING id INTO new_id;

  IF NULLIF(primary_code, '') IS NULL THEN
    RAISE EXCEPTION 'O produto precisa ter um código de barras principal.'
      USING ERRCODE = 'FA603', DETAIL = 'create_product sem código.';
  END IF;

  PERFORM app.insert_product_barcode(
    group_id, new_id, primary_code, (p_data ->> 'barcodeIsInternal')::boolean, true,
    true, true, NULL, NULL
  );

  IF catalog_id IS NOT NULL THEN
    INSERT INTO public.product_barcode (economic_group_id, product_id, code)
    SELECT group_id, new_id, cb.code
      FROM public.catalog_product_barcode cb
     WHERE cb.catalog_product_id = catalog_id AND cb.deleted_at IS NULL
    ON CONFLICT (economic_group_id, code) WHERE deleted_at IS NULL DO NOTHING;
  END IF;
  RETURN new_id;
END;
$$;

CREATE FUNCTION app.update_product(p_product_id uuid, p_data jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.require_products_manage();
  catalog_id uuid := (p_data ->> 'catalogProductId')::uuid;
BEGIN
  UPDATE public.product p
     SET catalog_product_id = catalog_id,
         display_name = pg_catalog.btrim(p_data ->> 'displayName'),
         own_manufacturer = CASE WHEN catalog_id IS NULL
                                 THEN NULLIF(pg_catalog.btrim(p_data ->> 'ownManufacturer'), '') END,
         category_id = (p_data ->> 'categoryId')::uuid,
         commission_group_id = (p_data ->> 'commissionGroupId')::uuid,
         pricing_group_id = (p_data ->> 'pricingGroupId')::uuid,
         price_family_id = (p_data ->> 'priceFamilyId')::uuid,
         uses_pmc = COALESCE((p_data ->> 'usesPmc')::boolean, false),
         online_sale_blocked = COALESCE((p_data ->> 'onlineSaleBlocked')::boolean, false),
         fraction_quantity = COALESCE((p_data ->> 'fractionQuantity')::numeric, 1)
   WHERE p.id = p_product_id AND p.economic_group_id = group_id AND p.deleted_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('product %s.', p_product_id);
  END IF;
END;
$$;

CREATE FUNCTION app.add_barcode(p_product_id uuid, p_data jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.require_products_manage();
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.product p
     WHERE p.id = p_product_id AND p.economic_group_id = group_id AND p.deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('product %s.', p_product_id);
  END IF;

  RETURN app.insert_product_barcode(
    group_id, p_product_id, p_data ->> 'code', (p_data ->> 'isInternal')::boolean, false,
    (p_data ->> 'sendsToSupplier')::boolean, (p_data ->> 'scanEnabled')::boolean,
    (p_data ->> 'fractionQuantity')::numeric,
    ARRAY(SELECT value::uuid FROM pg_catalog.jsonb_array_elements_text(COALESCE(p_data -> 'channels', '[]')) AS value)
  );
END;
$$;

CREATE FUNCTION app.lock_barcode(p_barcode_id uuid) RETURNS public.product_barcode
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.require_products_manage();
  target public.product_barcode;
BEGIN
  SELECT * INTO target FROM public.product_barcode b
   WHERE b.id = p_barcode_id AND b.economic_group_id = group_id AND b.deleted_at IS NULL
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('product_barcode %s.', p_barcode_id);
  END IF;
  RETURN target;
END;
$$;

CREATE FUNCTION app.update_barcode(p_barcode_id uuid, p_data jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.product_barcode := app.lock_barcode(p_barcode_id);
  channels uuid[] := ARRAY(
    SELECT DISTINCT value::uuid
      FROM pg_catalog.jsonb_array_elements_text(COALESCE(p_data -> 'channels', '[]')) AS value
  );
BEGIN
  UPDATE public.product_barcode b
     SET sends_to_supplier = COALESCE((p_data ->> 'sendsToSupplier')::boolean, true),
         scan_enabled = COALESCE((p_data ->> 'scanEnabled')::boolean, true),
         fraction_quantity = (p_data ->> 'fractionQuantity')::numeric
   WHERE b.id = target.id;

  UPDATE public.product_barcode_channel bc
     SET deleted_at = pg_catalog.clock_timestamp()
   WHERE bc.barcode_id = target.id AND bc.deleted_at IS NULL AND bc.channel_id <> ALL (channels);

  INSERT INTO public.product_barcode_channel (barcode_id, channel_id)
  SELECT target.id, requested.channel_id
    FROM pg_catalog.unnest(channels) AS requested(channel_id)
   WHERE NOT EXISTS (
     SELECT 1 FROM public.product_barcode_channel bc
      WHERE bc.barcode_id = target.id AND bc.channel_id = requested.channel_id AND bc.deleted_at IS NULL
   );
END;
$$;

CREATE FUNCTION app.set_primary_barcode(p_barcode_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.product_barcode := app.lock_barcode(p_barcode_id);
BEGIN
  UPDATE public.product_barcode b
     SET is_primary = false
   WHERE b.product_id = target.product_id AND b.is_primary AND b.deleted_at IS NULL AND b.id <> target.id;
  UPDATE public.product_barcode b SET is_primary = true WHERE b.id = target.id;
END;
$$;

CREATE FUNCTION app.remove_barcode(p_barcode_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.product_barcode := app.lock_barcode(p_barcode_id);
BEGIN
  UPDATE public.product_barcode_channel bc
     SET deleted_at = pg_catalog.clock_timestamp()
   WHERE bc.barcode_id = target.id AND bc.deleted_at IS NULL;
  -- Tirar o principal cai na regra do fim da transação (FA603).
  UPDATE public.product_barcode b
     SET deleted_at = pg_catalog.clock_timestamp()
   WHERE b.id = target.id;
END;
$$;

CREATE FUNCTION app.create_product_category(p_parent_id uuid, p_name text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.require_products_manage();
  parent_level smallint;
  new_id uuid;
BEGIN
  IF p_parent_id IS NOT NULL THEN
    SELECT c.level INTO parent_level FROM public.product_category c
     WHERE c.id = p_parent_id AND c.economic_group_id = group_id AND c.deleted_at IS NULL;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'A estrutura de categorias é inválida.'
        USING ERRCODE = 'FA607', DETAIL = pg_catalog.format('Pai %s não encontrado.', p_parent_id);
    END IF;
  END IF;

  INSERT INTO public.product_category (economic_group_id, parent_id, level, name)
  VALUES (group_id, p_parent_id, COALESCE(parent_level, 0) + 1, pg_catalog.btrim(p_name))
  RETURNING id INTO new_id;
  RETURN new_id;
END;
$$;

CREATE FUNCTION app.rename_product_category(p_id uuid, p_name text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.require_products_manage();
BEGIN
  UPDATE public.product_category c SET name = pg_catalog.btrim(p_name)
   WHERE c.id = p_id AND c.economic_group_id = group_id AND c.deleted_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('product_category %s.', p_id);
  END IF;
END;
$$;

CREATE FUNCTION app.delete_product_category(p_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.require_products_manage();
BEGIN
  UPDATE public.product_category c SET deleted_at = pg_catalog.clock_timestamp()
   WHERE c.id = p_id AND c.economic_group_id = group_id AND c.deleted_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('product_category %s.', p_id);
  END IF;
END;
$$;

CREATE FUNCTION app.create_product_group(p_kind text, p_name text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.require_products_manage();
  new_id uuid;
BEGIN
  INSERT INTO public.product_group (economic_group_id, kind, name)
  VALUES (group_id, p_kind, pg_catalog.btrim(p_name))
  RETURNING id INTO new_id;
  RETURN new_id;
END;
$$;

CREATE FUNCTION app.rename_product_group(p_id uuid, p_name text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.require_products_manage();
BEGIN
  UPDATE public.product_group g SET name = pg_catalog.btrim(p_name)
   WHERE g.id = p_id AND g.economic_group_id = group_id AND g.deleted_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('product_group %s.', p_id);
  END IF;
END;
$$;

CREATE FUNCTION app.delete_product_group(p_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.require_products_manage();
BEGIN
  UPDATE public.product_group g SET deleted_at = pg_catalog.clock_timestamp()
   WHERE g.id = p_id AND g.economic_group_id = group_id AND g.deleted_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('product_group %s.', p_id);
  END IF;
END;
$$;

CREATE FUNCTION app.create_sales_channel(p_name text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.require_products_manage();
  new_id uuid;
BEGIN
  INSERT INTO public.sales_channel (economic_group_id, name)
  VALUES (group_id, pg_catalog.btrim(p_name))
  RETURNING id INTO new_id;
  RETURN new_id;
END;
$$;

CREATE FUNCTION app.rename_sales_channel(p_id uuid, p_name text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.require_products_manage();
BEGIN
  UPDATE public.sales_channel c SET name = pg_catalog.btrim(p_name)
   WHERE c.id = p_id AND c.economic_group_id = group_id AND c.deleted_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('sales_channel %s.', p_id);
  END IF;
END;
$$;

CREATE FUNCTION app.delete_sales_channel(p_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid := app.require_products_manage();
BEGIN
  UPDATE public.sales_channel c SET deleted_at = pg_catalog.clock_timestamp()
   WHERE c.id = p_id AND c.economic_group_id = group_id AND c.deleted_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('sales_channel %s.', p_id);
  END IF;
END;
$$;

-- Importação do Catálogo, item a item. Só o dono das tabelas executa: a API nunca escreve aqui.
-- Códigos que saíram do arquivo são excluídos logicamente e os novos são incluídos.
CREATE FUNCTION app.upsert_catalog_product(p_item jsonb) RETURNS uuid
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  manufacturer_name text := NULLIF(pg_catalog.btrim(p_item ->> 'manufacturer'), '');
  manufacturer uuid;
  codes text[] := ARRAY(
    SELECT DISTINCT pg_catalog.btrim(value)
      FROM pg_catalog.jsonb_array_elements_text(COALESCE(p_item -> 'barcodes', '[]')) AS value
  );
  item_id uuid;
BEGIN
  IF manufacturer_name IS NOT NULL THEN
    SELECT m.id INTO manufacturer FROM public.catalog_manufacturer m
     WHERE m.name = manufacturer_name AND m.deleted_at IS NULL;
    IF NOT FOUND THEN
      INSERT INTO public.catalog_manufacturer (name) VALUES (manufacturer_name)
      RETURNING id INTO manufacturer;
    END IF;
  END IF;

  INSERT INTO public.catalog_product (
    source_key, name, active_ingredient, manufacturer_id, ms_registration, controlled_class, ncm, cest
  ) VALUES (
    p_item ->> 'sourceKey', pg_catalog.btrim(p_item ->> 'name'),
    NULLIF(pg_catalog.btrim(p_item ->> 'activeIngredient'), ''), manufacturer,
    NULLIF(p_item ->> 'msRegistration', ''), NULLIF(p_item ->> 'controlledClass', ''),
    NULLIF(p_item ->> 'ncm', ''), NULLIF(p_item ->> 'cest', '')
  )
  ON CONFLICT (source_key) WHERE deleted_at IS NULL DO UPDATE
    SET name = EXCLUDED.name,
        active_ingredient = EXCLUDED.active_ingredient,
        manufacturer_id = EXCLUDED.manufacturer_id,
        ms_registration = EXCLUDED.ms_registration,
        controlled_class = EXCLUDED.controlled_class,
        ncm = EXCLUDED.ncm,
        cest = EXCLUDED.cest
    -- Item igual não muda de versão, para não descer de novo aos terminais na Etapa 3.
    WHERE (public.catalog_product.name, public.catalog_product.active_ingredient,
           public.catalog_product.manufacturer_id, public.catalog_product.ms_registration,
           public.catalog_product.controlled_class, public.catalog_product.ncm, public.catalog_product.cest)
          IS DISTINCT FROM
          (EXCLUDED.name, EXCLUDED.active_ingredient, EXCLUDED.manufacturer_id, EXCLUDED.ms_registration,
           EXCLUDED.controlled_class, EXCLUDED.ncm, EXCLUDED.cest)
  RETURNING id INTO item_id;

  IF item_id IS NULL THEN
    SELECT cp.id INTO item_id FROM public.catalog_product cp
     WHERE cp.source_key = p_item ->> 'sourceKey' AND cp.deleted_at IS NULL;
  END IF;

  UPDATE public.catalog_product_barcode cb
     SET deleted_at = pg_catalog.clock_timestamp()
   WHERE cb.catalog_product_id = item_id AND cb.deleted_at IS NULL AND cb.code <> ALL (codes);

  INSERT INTO public.catalog_product_barcode (catalog_product_id, code)
  SELECT item_id, requested.code
    FROM pg_catalog.unnest(codes) AS requested(code)
   WHERE NOT EXISTS (
     SELECT 1 FROM public.catalog_product_barcode cb
      WHERE cb.catalog_product_id = item_id AND cb.code = requested.code AND cb.deleted_at IS NULL
   );
  RETURN item_id;
END;
$$;

-- Leitura pelo papel da API: o Catálogo não é sigiloso; o produto da loja exige products.view.
CREATE POLICY catalog_manufacturer_select ON catalog_manufacturer FOR SELECT TO farmaerp_app
  USING ((SELECT app.current_user_group()) IS NOT NULL);
CREATE POLICY catalog_product_select ON catalog_product FOR SELECT TO farmaerp_app
  USING ((SELECT app.current_user_group()) IS NOT NULL);
CREATE POLICY catalog_product_barcode_select ON catalog_product_barcode FOR SELECT TO farmaerp_app
  USING ((SELECT app.current_user_group()) IS NOT NULL);
CREATE POLICY product_category_select ON product_category FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group())
         AND (SELECT app.has_permission_anywhere('products.view')
                  OR app.has_permission_anywhere('products.manage')));
CREATE POLICY product_group_select ON product_group FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group())
         AND (SELECT app.has_permission_anywhere('products.view')
                  OR app.has_permission_anywhere('products.manage')));
CREATE POLICY sales_channel_select ON sales_channel FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group())
         AND (SELECT app.has_permission_anywhere('products.view')
                  OR app.has_permission_anywhere('products.manage')));
CREATE POLICY product_select ON product FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group())
         AND (SELECT app.has_permission_anywhere('products.view')
                  OR app.has_permission_anywhere('products.manage')));
CREATE POLICY product_barcode_select ON product_barcode FOR SELECT TO farmaerp_app
  USING (economic_group_id = (SELECT app.current_user_group())
         AND (SELECT app.has_permission_anywhere('products.view')
                  OR app.has_permission_anywhere('products.manage')));
CREATE POLICY product_barcode_channel_select ON product_barcode_channel FOR SELECT TO farmaerp_app
  USING (EXISTS (SELECT 1 FROM product_barcode b WHERE b.id = product_barcode_channel.barcode_id));

GRANT SELECT ON
  catalog_manufacturer, catalog_product, catalog_product_barcode, product_category, product_group,
  sales_channel, product, product_barcode, product_barcode_channel
TO farmaerp_app;

CREATE VIEW v_catalog_manufacturer WITH (security_invoker = true) AS
  SELECT * FROM catalog_manufacturer WHERE deleted_at IS NULL;
CREATE VIEW v_catalog_product WITH (security_invoker = true) AS
  SELECT * FROM catalog_product WHERE deleted_at IS NULL;
CREATE VIEW v_catalog_product_barcode WITH (security_invoker = true) AS
  SELECT * FROM catalog_product_barcode WHERE deleted_at IS NULL;
CREATE VIEW v_product_category WITH (security_invoker = true) AS
  SELECT * FROM product_category WHERE deleted_at IS NULL;
CREATE VIEW v_product_group WITH (security_invoker = true) AS
  SELECT * FROM product_group WHERE deleted_at IS NULL;
CREATE VIEW v_sales_channel WITH (security_invoker = true) AS
  SELECT * FROM sales_channel WHERE deleted_at IS NULL;
CREATE VIEW v_product WITH (security_invoker = true) AS
  SELECT * FROM product WHERE deleted_at IS NULL;
CREATE VIEW v_product_barcode WITH (security_invoker = true) AS
  SELECT * FROM product_barcode WHERE deleted_at IS NULL;
CREATE VIEW v_product_barcode_channel WITH (security_invoker = true) AS
  SELECT * FROM product_barcode_channel WHERE deleted_at IS NULL;
GRANT SELECT ON
  v_catalog_manufacturer, v_catalog_product, v_catalog_product_barcode, v_product_category,
  v_product_group, v_sales_channel, v_product, v_product_barcode, v_product_barcode_channel
TO farmaerp_app;

-- Busca da retaguarda: nome, fabricante, princípio ativo, código humano ou código de barras.
-- Roda como quem chama, então a RLS decide o que aparece.
CREATE FUNCTION app.search_products(p_query text, p_limit integer DEFAULT 50)
RETURNS TABLE (
  id uuid, code bigint, display_name text, catalog_product_id uuid, active_ingredient text,
  manufacturer text, primary_barcode text, online_sale_blocked boolean
)
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  WITH input AS (
    SELECT app.search_patterns(p_query) AS patterns, pg_catalog.btrim(COALESCE(p_query, '')) AS raw
  )
  SELECT p.id, p.code, p.display_name, p.catalog_product_id, cp.active_ingredient,
         COALESCE(m.name, p.own_manufacturer), b.code, p.online_sale_blocked
    FROM public.product p
   CROSS JOIN input
    LEFT JOIN public.catalog_product cp ON cp.id = p.catalog_product_id
    LEFT JOIN public.catalog_manufacturer m ON m.id = cp.manufacturer_id
    LEFT JOIN public.product_barcode b ON b.product_id = p.id AND b.is_primary AND b.deleted_at IS NULL
   WHERE p.deleted_at IS NULL
     AND (
       input.raw = ''
       OR (p.search_text || ' ' || COALESCE(cp.search_text, '')) LIKE ALL (input.patterns)
       OR p.code::text = input.raw
       OR EXISTS (
         SELECT 1 FROM public.product_barcode exact
          WHERE exact.product_id = p.id AND exact.code = input.raw AND exact.deleted_at IS NULL
       )
     )
   ORDER BY p.display_name, p.id
   LIMIT LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200)
$$;

-- Consulta ao Catálogo no cadastro. product_id avisa se o item já está na loja.
CREATE FUNCTION app.search_catalog(p_query text, p_limit integer DEFAULT 20)
RETURNS TABLE (
  id uuid, name text, active_ingredient text, manufacturer text, ms_registration text,
  controlled_class text, ncm text, cest text, barcodes text[], product_id uuid
)
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  WITH input AS (
    SELECT app.search_patterns(p_query) AS patterns, pg_catalog.btrim(COALESCE(p_query, '')) AS raw
  )
  SELECT cp.id, cp.name, cp.active_ingredient, m.name, cp.ms_registration, cp.controlled_class,
         cp.ncm, cp.cest,
         ARRAY(
           SELECT cb.code FROM public.catalog_product_barcode cb
            WHERE cb.catalog_product_id = cp.id AND cb.deleted_at IS NULL
            ORDER BY cb.code
         ),
         (SELECT p.id FROM public.product p
           WHERE p.catalog_product_id = cp.id AND p.deleted_at IS NULL
             AND p.economic_group_id = app.current_user_group())
    FROM public.catalog_product cp
   CROSS JOIN input
    LEFT JOIN public.catalog_manufacturer m ON m.id = cp.manufacturer_id
   WHERE cp.deleted_at IS NULL
     AND input.raw <> ''
     AND (
       -- A primeira condição é a que o índice consegue usar.
       (cp.search_text LIKE input.patterns[1] AND cp.search_text LIKE ALL (input.patterns))
       OR EXISTS (
         SELECT 1 FROM public.catalog_product_barcode exact
          WHERE exact.catalog_product_id = cp.id AND exact.code = input.raw AND exact.deleted_at IS NULL
       )
     )
   ORDER BY cp.name, cp.id
   LIMIT LEAST(GREATEST(COALESCE(p_limit, 20), 1), 50)
$$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  app.normalize_search(text),
  app.search_patterns(text),
  app.is_valid_gtin(text),
  app.effective_fraction(uuid, uuid),
  app.search_products(text, integer),
  app.search_catalog(text, integer),
  app.create_product(jsonb),
  app.update_product(uuid, jsonb),
  app.add_barcode(uuid, jsonb),
  app.update_barcode(uuid, jsonb),
  app.set_primary_barcode(uuid),
  app.remove_barcode(uuid),
  app.create_product_category(uuid, text),
  app.rename_product_category(uuid, text),
  app.delete_product_category(uuid),
  app.create_product_group(text, text),
  app.rename_product_group(uuid, text),
  app.delete_product_group(uuid),
  app.create_sales_channel(text),
  app.rename_sales_channel(uuid, text),
  app.delete_sales_channel(uuid)
TO farmaerp_app;
