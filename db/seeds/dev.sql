-- Dados de desenvolvimento. Pode rodar mais de uma vez. Nunca roda em produção.
BEGIN;

INSERT INTO economic_group (id, name) VALUES
  ('019a0000-0000-7000-8000-000000000001', 'Grupo Demonstração')
ON CONFLICT (id) DO NOTHING;

INSERT INTO company (id, economic_group_id, legal_name, trade_name, cnpj_root) VALUES
  ('019a0000-0000-7000-8000-000000000002', '019a0000-0000-7000-8000-000000000001',
   'Farmácia Demonstração Ltda', 'Farmácia Demonstração', '11222333')
ON CONFLICT (id) DO NOTHING;

INSERT INTO branch_group (id, economic_group_id, name) VALUES
  ('019a0000-0000-7000-8000-000000000003', '019a0000-0000-7000-8000-000000000001', 'Grupo Norte')
ON CONFLICT (id) DO NOTHING;

INSERT INTO region (id, branch_group_id, name) VALUES
  ('019a0000-0000-7000-8000-000000000004', '019a0000-0000-7000-8000-000000000003', 'Capital')
ON CONFLICT (id) DO NOTHING;

INSERT INTO branch (id, company_id, region_id, name, cnpj) VALUES
  ('019a0000-0000-7000-8000-000000000005', '019a0000-0000-7000-8000-000000000002',
   '019a0000-0000-7000-8000-000000000004', 'Loja Centro', '11222333000181'),
  ('019a0000-0000-7000-8000-000000000006', '019a0000-0000-7000-8000-000000000002',
   '019a0000-0000-7000-8000-000000000004', 'Loja Sul', '11222333000262')
ON CONFLICT (id) DO NOTHING;

INSERT INTO terminal (id, branch_id, name, profile, status, public_key) VALUES
  ('019a0000-0000-7000-8000-000000000007', '019a0000-0000-7000-8000-000000000005',
   'Caixa 1', 'cashier', 'active', 'chave-publica-de-desenvolvimento')
ON CONFLICT (id) DO NOTHING;

-- Confere antes de incluir: com ON CONFLICT, o trigger consumiria um código a cada execução.
INSERT INTO user_account (id, economic_group_id, name, email)
SELECT seed.id, seed.economic_group_id, seed.name, seed.email
  FROM (VALUES
    ('019a0000-0000-7000-8000-000000000008'::uuid, '019a0000-0000-7000-8000-000000000001'::uuid, 'Administrador', 'admin@farmaerp.test'),
    ('019a0000-0000-7000-8000-000000000009'::uuid, '019a0000-0000-7000-8000-000000000001'::uuid, 'Operador Centro', 'operador@farmaerp.test'),
    ('019a0000-0000-7000-8000-00000000000d'::uuid, '019a0000-0000-7000-8000-000000000001'::uuid, 'Gerente Centro', 'gerente@farmaerp.test')
  ) AS seed (id, economic_group_id, name, email)
 WHERE NOT EXISTS (SELECT 1 FROM user_account u WHERE u.id = seed.id);

INSERT INTO user_branch (id, user_id, branch_id) VALUES
  ('019a0000-0000-7000-8000-00000000000a', '019a0000-0000-7000-8000-000000000009',
   '019a0000-0000-7000-8000-000000000005')
ON CONFLICT (id) DO NOTHING;

INSERT INTO user_branch (id, user_id, branch_id) VALUES
  ('019a0000-0000-7000-8000-00000000000e', '019a0000-0000-7000-8000-00000000000d',
   '019a0000-0000-7000-8000-000000000005')
ON CONFLICT (id) DO NOTHING;

-- Administrador em todas as filiais, gerente só na Loja Centro e operador de caixa.
INSERT INTO user_role (id, user_id, role_id, branch_id)
SELECT seed.id, seed.user_id, r.id, seed.branch_id
  FROM (VALUES
    ('019a0000-0000-7000-8000-00000000000f'::uuid, '019a0000-0000-7000-8000-000000000008'::uuid, 'Administrador', NULL::uuid),
    ('019a0000-0000-7000-8000-000000000010'::uuid, '019a0000-0000-7000-8000-00000000000d'::uuid, 'Gerente', '019a0000-0000-7000-8000-000000000005'::uuid),
    ('019a0000-0000-7000-8000-000000000011'::uuid, '019a0000-0000-7000-8000-000000000009'::uuid, 'Operador de caixa', NULL::uuid)
  ) AS seed (id, user_id, role_name, branch_id)
  JOIN role r
    ON r.economic_group_id = '019a0000-0000-7000-8000-000000000001' AND r.name = seed.role_name AND r.deleted_at IS NULL
 WHERE NOT EXISTS (
   -- Confere pelo vínculo: a migração pode já ter dado este perfil ao usuário.
   SELECT 1 FROM user_role ur
    WHERE ur.user_id = seed.user_id AND ur.role_id = r.id
      AND ur.branch_id IS NOT DISTINCT FROM seed.branch_id AND ur.deleted_at IS NULL
 )
 AND NOT EXISTS (SELECT 1 FROM user_role ur WHERE ur.id = seed.id);

-- Catálogo e produtos fictícios, para demonstração. Os códigos de barras têm dígito válido, mas não são reais.
SELECT app.upsert_catalog_product(item) FROM jsonb_array_elements('[
  {"sourceKey": "demo-1", "name": "Dipirona Demonstração 500 mg 20 comprimidos", "activeIngredient": "Dipirona", "manufacturer": "Laboratório Demonstração", "msRegistration": "1000000000001", "ncm": "30049099", "barcodes": ["7890000000017", "7890000000024"]},
  {"sourceKey": "demo-2", "name": "Paracetamol Demonstração 750 mg 20 comprimidos", "activeIngredient": "Paracetamol", "manufacturer": "Laboratório Demonstração", "msRegistration": "1000000000002", "ncm": "30049099", "barcodes": ["7890000000031"]},
  {"sourceKey": "demo-3", "name": "Amoxicilina Demonstração 500 mg 21 cápsulas", "activeIngredient": "Amoxicilina", "manufacturer": "Indústria Fictícia", "msRegistration": "1000000000003", "controlledClass": "antimicrobial", "ncm": "30041019", "barcodes": ["7890000000048"]},
  {"sourceKey": "demo-4", "name": "Clonazepam Demonstração 2 mg 30 comprimidos", "activeIngredient": "Clonazepam", "manufacturer": "Indústria Fictícia", "msRegistration": "1000000000004", "controlledClass": "B1", "ncm": "30049069", "barcodes": ["7890000000055"]},
  {"sourceKey": "demo-5", "name": "Protetor Solar Demonstração FPS 50", "manufacturer": "Cosméticos Fictícios", "ncm": "33049910", "cest": "2003000", "barcodes": ["7890000000062"]}
]'::jsonb) AS item;

INSERT INTO product_category (id, economic_group_id, parent_id, level, name) VALUES
  ('019a0000-0000-7000-8000-000000000020', '019a0000-0000-7000-8000-000000000001', NULL, 1, 'Medicamentos'),
  ('019a0000-0000-7000-8000-000000000021', '019a0000-0000-7000-8000-000000000001', '019a0000-0000-7000-8000-000000000020', 2, 'Analgésicos'),
  ('019a0000-0000-7000-8000-000000000022', '019a0000-0000-7000-8000-000000000001', '019a0000-0000-7000-8000-000000000021', 3, 'Comprimidos')
ON CONFLICT (id) DO NOTHING;

INSERT INTO product_group (id, economic_group_id, kind, name) VALUES
  ('019a0000-0000-7000-8000-000000000023', '019a0000-0000-7000-8000-000000000001', 'commission', 'Comissão padrão'),
  ('019a0000-0000-7000-8000-000000000024', '019a0000-0000-7000-8000-000000000001', 'pricing', 'Genéricos'),
  ('019a0000-0000-7000-8000-000000000025', '019a0000-0000-7000-8000-000000000001', 'price_family', 'Dipironas')
ON CONFLICT (id) DO NOTHING;

INSERT INTO sales_channel (id, economic_group_id, name) VALUES
  ('019a0000-0000-7000-8000-000000000026', '019a0000-0000-7000-8000-000000000001', 'Marketplace demonstração')
ON CONFLICT (id) DO NOTHING;

-- Confere antes de incluir: com ON CONFLICT, o trigger consumiria um código a cada execução.
INSERT INTO product (id, economic_group_id, catalog_product_id, display_name, category_id, pricing_group_id, price_family_id, commission_group_id)
SELECT '019a0000-0000-7000-8000-000000000027'::uuid, '019a0000-0000-7000-8000-000000000001'::uuid, cp.id, cp.name,
       '019a0000-0000-7000-8000-000000000022'::uuid, '019a0000-0000-7000-8000-000000000024'::uuid,
       '019a0000-0000-7000-8000-000000000025'::uuid, '019a0000-0000-7000-8000-000000000023'::uuid
  FROM catalog_product cp
 WHERE cp.source_key = 'demo-1' AND cp.deleted_at IS NULL
   AND NOT EXISTS (SELECT 1 FROM product p WHERE p.id = '019a0000-0000-7000-8000-000000000027');

INSERT INTO product_barcode (id, economic_group_id, product_id, code, is_primary) VALUES
  ('019a0000-0000-7000-8000-000000000028', '019a0000-0000-7000-8000-000000000001',
   '019a0000-0000-7000-8000-000000000027', '7890000000017', true),
  ('019a0000-0000-7000-8000-000000000029', '019a0000-0000-7000-8000-000000000001',
   '019a0000-0000-7000-8000-000000000027', '7890000000024', false)
ON CONFLICT (id) DO NOTHING;

-- Não sobrescreve o estado de quem já informou.
UPDATE branch SET state = 'SP'
 WHERE id IN ('019a0000-0000-7000-8000-000000000005', '019a0000-0000-7000-8000-000000000006') AND state IS NULL;

INSERT INTO product_price (id, economic_group_id, product_id, branch_id, price, reason) VALUES
  ('019a0000-0000-7000-8000-00000000002a', '019a0000-0000-7000-8000-000000000001',
   '019a0000-0000-7000-8000-000000000027', NULL, 12.90, 'Preço de demonstração')
ON CONFLICT (id) DO NOTHING;

INSERT INTO product_pmc (id, economic_group_id, product_id, state, value) VALUES
  ('019a0000-0000-7000-8000-00000000002b', '019a0000-0000-7000-8000-000000000001',
   '019a0000-0000-7000-8000-000000000027', 'SP', 15.00)
ON CONFLICT (id) DO NOTHING;

-- Regras fictícias, para o simulador ter o que mostrar. Em produção, os valores são decisão de cada rede.
INSERT INTO product_rule (id, economic_group_id, rule_type_id, level, category_id, product_group_id, value, reason)
SELECT seed.id, '019a0000-0000-7000-8000-000000000001'::uuid, t.id, seed.level, seed.category_id, seed.product_group_id, seed.value, 'Exemplo de demonstração'
  FROM (VALUES
    ('019a0000-0000-7000-8000-00000000002c'::uuid, 'cost_tolerance', 'store_default', NULL::uuid, NULL::uuid, 5.0),
    ('019a0000-0000-7000-8000-00000000002d'::uuid, 'commission', 'subcategory', '019a0000-0000-7000-8000-000000000022'::uuid, NULL::uuid, 3.0),
    ('019a0000-0000-7000-8000-00000000002e'::uuid, 'cashback', 'price_family', NULL::uuid, '019a0000-0000-7000-8000-000000000025'::uuid, 2.0)
  ) AS seed (id, type_code, level, category_id, product_group_id, value)
  JOIN rule_type t ON t.code = seed.type_code
ON CONFLICT (id) DO NOTHING;

COMMIT;
