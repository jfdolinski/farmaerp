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
-- A tributação também é fictícia: serve para ver a tela, não para emitir nota.
SELECT app.upsert_catalog_product(item) FROM jsonb_array_elements('[
  {"sourceKey": "demo-1", "name": "Dipirona Demonstração 500 mg 20 comprimidos", "activeIngredient": "Dipirona", "manufacturer": "Laboratório Demonstração", "msRegistration": "1000000000001", "ncm": "30049099", "barcodes": ["7890000000017", "7890000000024"], "taxes": [
    {"regimes": [1, 4], "states": ["SP", "PR"], "validFrom": "2026-01-01", "cfop": "5405", "origin": 0, "icmsCsosn": "500", "pisCst": "49", "cofinsCst": "49"},
    {"regimes": [2, 3], "states": ["SP", "PR"], "validFrom": "2026-01-01", "cfop": "5102", "origin": 0, "icmsCst": "00", "icmsRate": 18, "pisCst": "01", "pisRate": 1.65, "cofinsCst": "01", "cofinsRate": 7.6, "ibsCbsCst": "000", "classTrib": "000001", "ibsStateRate": 0.1, "ibsCityRate": 0, "cbsRate": 0.9}
  ]},
  {"sourceKey": "demo-2", "name": "Paracetamol Demonstração 750 mg 20 comprimidos", "activeIngredient": "Paracetamol", "manufacturer": "Laboratório Demonstração", "msRegistration": "1000000000002", "ncm": "30049099", "barcodes": ["7890000000031"]},
  {"sourceKey": "demo-3", "name": "Amoxicilina Demonstração 500 mg 21 cápsulas", "activeIngredient": "Amoxicilina", "manufacturer": "Indústria Fictícia", "msRegistration": "1000000000003", "controlledClass": "antimicrobial", "ncm": "30041019", "barcodes": ["7890000000048"]},
  {"sourceKey": "demo-4", "name": "Clonazepam Demonstração 2 mg 30 comprimidos", "activeIngredient": "Clonazepam", "manufacturer": "Indústria Fictícia", "msRegistration": "1000000000004", "controlledClass": "B1", "ncm": "30049069", "barcodes": ["7890000000055"]},
  {"sourceKey": "demo-5", "name": "Protetor Solar Demonstração FPS 50", "manufacturer": "Cosméticos Fictícios", "ncm": "33049910", "cest": "2003000", "barcodes": ["7890000000062"]}
]'::jsonb) AS item;

-- Imagem de demonstração da Dipirona: um desenho simples de caixa, sem marca, já em WebP.
-- A importação reconhece a mesma imagem pelo SHA-256 e não grava de novo.
SELECT app.set_catalog_product_images('demo-1', '[{"sha256":"e7d18fd9f8b22c49280e8ecba3e5974d1e2fecbde4b973617be5e3cc338044cd","width":600,"height":600,"full":"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","thumb":"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","main":true}]'::jsonb);

-- Daqui em diante, tabelas com trigger de validação conferem antes de incluir: o trigger roda
-- antes do ON CONFLICT e, se alguém mudou os dados na tela, derrubaria o deploy.
-- Um nível por instrução: dentro de uma só, a ordem das linhas não é garantida, e o filho precisa do pai.
INSERT INTO product_category (id, economic_group_id, parent_id, level, name)
SELECT '019a0000-0000-7000-8000-000000000020'::uuid, '019a0000-0000-7000-8000-000000000001'::uuid, NULL::uuid, 1, 'Medicamentos'
 WHERE NOT EXISTS (SELECT 1 FROM product_category c WHERE c.id = '019a0000-0000-7000-8000-000000000020');
INSERT INTO product_category (id, economic_group_id, parent_id, level, name)
SELECT '019a0000-0000-7000-8000-000000000021'::uuid, '019a0000-0000-7000-8000-000000000001'::uuid, '019a0000-0000-7000-8000-000000000020'::uuid, 2, 'Analgésicos'
 WHERE NOT EXISTS (SELECT 1 FROM product_category c WHERE c.id = '019a0000-0000-7000-8000-000000000021');
INSERT INTO product_category (id, economic_group_id, parent_id, level, name)
SELECT '019a0000-0000-7000-8000-000000000022'::uuid, '019a0000-0000-7000-8000-000000000001'::uuid, '019a0000-0000-7000-8000-000000000021'::uuid, 3, 'Comprimidos'
 WHERE NOT EXISTS (SELECT 1 FROM product_category c WHERE c.id = '019a0000-0000-7000-8000-000000000022');

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
 WHERE NOT EXISTS (SELECT 1 FROM product_rule r WHERE r.id = seed.id);

-- Estoque de demonstração: a Loja Centro controla lote deste produto, e a Loja Sul não.
-- Confere pela movimentação do seed: se ela já existe, alguém pode ter mudado o parâmetro depois.
UPDATE product_branch_status SET tracks_batches = true
 WHERE product_id = '019a0000-0000-7000-8000-000000000027'
   AND branch_id = '019a0000-0000-7000-8000-000000000005'
   AND NOT EXISTS (SELECT 1 FROM stock_movement WHERE id = '019a0000-0000-7000-8000-000000000030');

INSERT INTO product_batch (id, economic_group_id, branch_id, product_id, batch_number, expires_on, ms_registration, ms_original) VALUES
  ('019a0000-0000-7000-8000-00000000002f', '019a0000-0000-7000-8000-000000000001', '019a0000-0000-7000-8000-000000000005',
   '019a0000-0000-7000-8000-000000000027', 'DEMO1', '2030-06-30', '1000000000001', '1000000000001')
ON CONFLICT (id) DO NOTHING;

INSERT INTO stock_movement (id, economic_group_id, branch_id, product_id, batch_id, movement_type, quantity, reason)
SELECT seed.id, '019a0000-0000-7000-8000-000000000001'::uuid, seed.branch_id, '019a0000-0000-7000-8000-000000000027'::uuid,
       seed.batch_id, 'adjustment', seed.quantity, 'Saldo de demonstração'
  FROM (VALUES
    ('019a0000-0000-7000-8000-000000000030'::uuid, '019a0000-0000-7000-8000-000000000005'::uuid, '019a0000-0000-7000-8000-00000000002f'::uuid, 50::numeric),
    ('019a0000-0000-7000-8000-000000000031'::uuid, '019a0000-0000-7000-8000-000000000006'::uuid, NULL::uuid, 20::numeric)
  ) AS seed (id, branch_id, batch_id, quantity)
 WHERE NOT EXISTS (SELECT 1 FROM stock_movement m WHERE m.id = seed.id);

-- Controlado de demonstração (lista B1) na Loja Centro, com lote e saldo, para testar a venda com receita.
INSERT INTO product (id, economic_group_id, catalog_product_id, display_name, category_id, commission_group_id)
SELECT '019a0000-0000-7000-8000-000000000033'::uuid, '019a0000-0000-7000-8000-000000000001'::uuid, cp.id, cp.name,
       '019a0000-0000-7000-8000-000000000022'::uuid, '019a0000-0000-7000-8000-000000000023'::uuid
  FROM catalog_product cp
 WHERE cp.source_key = 'demo-4' AND cp.deleted_at IS NULL
   AND NOT EXISTS (SELECT 1 FROM product p WHERE p.id = '019a0000-0000-7000-8000-000000000033');

INSERT INTO product_barcode (id, economic_group_id, product_id, code, is_primary) VALUES
  ('019a0000-0000-7000-8000-000000000034', '019a0000-0000-7000-8000-000000000001',
   '019a0000-0000-7000-8000-000000000033', '7890000000055', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO product_price (id, economic_group_id, product_id, branch_id, price, reason) VALUES
  ('019a0000-0000-7000-8000-000000000035', '019a0000-0000-7000-8000-000000000001',
   '019a0000-0000-7000-8000-000000000033', NULL, 24.50, 'Preço de demonstração')
ON CONFLICT (id) DO NOTHING;

UPDATE product_branch_status SET tracks_batches = true
 WHERE product_id = '019a0000-0000-7000-8000-000000000033'
   AND branch_id = '019a0000-0000-7000-8000-000000000005'
   AND NOT EXISTS (SELECT 1 FROM stock_movement WHERE id = '019a0000-0000-7000-8000-000000000037');

INSERT INTO product_batch (id, economic_group_id, branch_id, product_id, batch_number, expires_on, ms_registration, ms_original) VALUES
  ('019a0000-0000-7000-8000-000000000036', '019a0000-0000-7000-8000-000000000001', '019a0000-0000-7000-8000-000000000005',
   '019a0000-0000-7000-8000-000000000033', 'CLZ01', '2030-03-31', '1000000000004', '1000000000004')
ON CONFLICT (id) DO NOTHING;

INSERT INTO stock_movement (id, economic_group_id, branch_id, product_id, batch_id, movement_type, quantity, reason)
SELECT '019a0000-0000-7000-8000-000000000037'::uuid, '019a0000-0000-7000-8000-000000000001'::uuid,
       '019a0000-0000-7000-8000-000000000005'::uuid, '019a0000-0000-7000-8000-000000000033'::uuid,
       '019a0000-0000-7000-8000-000000000036'::uuid, 'adjustment', 30, 'Saldo de demonstração'
 WHERE NOT EXISTS (SELECT 1 FROM stock_movement m WHERE m.id = '019a0000-0000-7000-8000-000000000037');

-- Cliente fictício. O CPF é o exemplo de dígito válido usado em documentação.
INSERT INTO customer (id, economic_group_id, person_type, document, name, phone, city, state)
SELECT '019a0000-0000-7000-8000-000000000032'::uuid, '019a0000-0000-7000-8000-000000000001'::uuid,
       'individual', '11144477735', 'Cliente Demonstração', '11999990000', 'São Paulo', 'SP'
 WHERE NOT EXISTS (SELECT 1 FROM customer WHERE id = '019a0000-0000-7000-8000-000000000032');

-- PINs do PDV, só de desenvolvimento: Administrador 2580, Operador Centro 2468, Gerente Centro 1357.
INSERT INTO user_pin (user_id, pin_hash)
SELECT seed.user_id, seed.pin_hash
  FROM (VALUES
    ('019a0000-0000-7000-8000-000000000008'::uuid, 'pbkdf2-sha256$210000$CwsLCwsLCwsLCwsLCwsLCw==$Ibg1aBCVWciZ09CR/tWnqoxvfYc+vRQn4oWrfrHEPqU='),
    ('019a0000-0000-7000-8000-000000000009'::uuid, 'pbkdf2-sha256$210000$DAwMDAwMDAwMDAwMDAwMDA==$0Y+4ZaPrEpWxpjCyiyQsgVU97GA29jxTLVuoyG8WNgc='),
    ('019a0000-0000-7000-8000-00000000000d'::uuid, 'pbkdf2-sha256$210000$DQ0NDQ0NDQ0NDQ0NDQ0NDQ==$YLCplR765nYp6Saph4wxcPT+A3Piz/goI7ksOBlBV6s=')
  ) AS seed (user_id, pin_hash)
 WHERE NOT EXISTS (SELECT 1 FROM user_pin up WHERE up.user_id = seed.user_id AND up.deleted_at IS NULL);


COMMIT;
