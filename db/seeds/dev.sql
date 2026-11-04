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
INSERT INTO user_account (id, economic_group_id, name, is_group_admin, email)
SELECT seed.id, seed.economic_group_id, seed.name, seed.is_group_admin, seed.email
  FROM (VALUES
    ('019a0000-0000-7000-8000-000000000008'::uuid, '019a0000-0000-7000-8000-000000000001'::uuid, 'Administrador', true, 'admin@farmaerp.test'),
    ('019a0000-0000-7000-8000-000000000009'::uuid, '019a0000-0000-7000-8000-000000000001'::uuid, 'Operador Centro', false, 'operador@farmaerp.test')
  ) AS seed (id, economic_group_id, name, is_group_admin, email)
 WHERE NOT EXISTS (SELECT 1 FROM user_account u WHERE u.id = seed.id);

INSERT INTO user_branch (id, user_id, branch_id) VALUES
  ('019a0000-0000-7000-8000-00000000000a', '019a0000-0000-7000-8000-000000000009',
   '019a0000-0000-7000-8000-000000000005')
ON CONFLICT (id) DO NOTHING;

COMMIT;
