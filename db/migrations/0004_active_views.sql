-- Up Migration

-- Views de consulta do dia a dia: só registros ativos.
-- security_invoker é obrigatório: sem ele, a view usaria as permissões do dono e ignoraria a RLS.

CREATE VIEW v_economic_group WITH (security_invoker = true) AS
  SELECT * FROM economic_group WHERE deleted_at IS NULL;
CREATE VIEW v_company WITH (security_invoker = true) AS
  SELECT * FROM company WHERE deleted_at IS NULL;
CREATE VIEW v_branch_group WITH (security_invoker = true) AS
  SELECT * FROM branch_group WHERE deleted_at IS NULL;
CREATE VIEW v_region WITH (security_invoker = true) AS
  SELECT * FROM region WHERE deleted_at IS NULL;
CREATE VIEW v_branch WITH (security_invoker = true) AS
  SELECT * FROM branch WHERE deleted_at IS NULL;
CREATE VIEW v_terminal WITH (security_invoker = true) AS
  SELECT * FROM terminal WHERE deleted_at IS NULL;
CREATE VIEW v_user_account WITH (security_invoker = true) AS
  SELECT * FROM user_account WHERE deleted_at IS NULL;
CREATE VIEW v_user_branch WITH (security_invoker = true) AS
  SELECT * FROM user_branch WHERE deleted_at IS NULL;

GRANT SELECT ON
  v_economic_group, v_company, v_branch_group, v_region,
  v_branch, v_terminal, v_user_account, v_user_branch
TO farmaerp_app;
