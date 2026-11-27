-- Up Migration

-- Vendedor padrão do terminal (pedido de 27/11): a coluna terminal.fixed_seller_id já descia ao PDV
-- (a venda começa com esse vendedor e a tela não bloqueia pedindo o vendedor), mas não havia como
-- configurar. Quem aprova terminais escolhe, na retaguarda, alguém que vende ou orça na filial do
-- terminal, ou tira o padrão. A mudança desce ao PDV pelo gatilho que já existe na tabela.

-- Pode ser o padrão: usuário ativo do grupo, com acesso à filial e que vende ou orça nela.
CREATE FUNCTION app.can_be_terminal_seller(p_user_id uuid, p_branch_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT app.user_has_permission(p_user_id, 'sales.sell', p_branch_id)
      OR app.user_has_permission(p_user_id, 'sales.quote', p_branch_id)
$$;

CREATE FUNCTION app.set_terminal_fixed_seller(p_terminal_id uuid, p_user_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.terminal := app.lock_terminal(p_terminal_id, 'terminals.approve');
BEGIN
  IF target.status NOT IN ('active', 'blocked') THEN
    RAISE EXCEPTION 'Esta mudança de situação não é permitida para o terminal.'
      USING ERRCODE = 'FA303', DETAIL = pg_catalog.format('Vendedor padrão com situação %s.', target.status);
  END IF;
  IF p_user_id IS NOT NULL AND NOT app.can_be_terminal_seller(p_user_id, target.branch_id) THEN
    RAISE EXCEPTION 'Esta pessoa não pode ser o vendedor padrão deste terminal.'
      USING ERRCODE = 'FA762', DETAIL = pg_catalog.format('Usuário %s sem venda ou orçamento na filial.', p_user_id);
  END IF;
  UPDATE public.terminal t SET fixed_seller_id = p_user_id WHERE t.id = target.id;
END;
$$;

-- Quem pode ser o padrão, por filial, nas filiais em que o usuário aprova terminais.
CREATE FUNCTION app.terminal_seller_options() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
           'branch_id', b.id, 'user_id', u.id, 'code', u.code, 'name', u.name) ORDER BY b.id, u.code), '[]'::jsonb)
    FROM public.branch b
    JOIN public.company c ON c.id = b.company_id
    JOIN public.user_account u ON u.economic_group_id = c.economic_group_id AND u.deleted_at IS NULL AND u.is_active
   WHERE b.deleted_at IS NULL
     AND c.economic_group_id = app.current_user_group()
     AND app.has_permission('terminals.approve', b.id)
     AND app.can_be_terminal_seller(u.id, b.id)
$$;

CREATE OR REPLACE VIEW v_terminal_monitor WITH (security_invoker = true) AS
  SELECT
    t.id,
    t.branch_id,
    b.name AS branch_name,
    t.name,
    t.profile,
    t.status,
    t.created_at,
    r.platform,
    r.device_name,
    r.key_storage,
    COALESCE(s.app_version, r.app_version) AS app_version,
    s.last_seen_at,
    CASE
      WHEN s.last_seen_at >= now() - interval '3 minutes' THEN 'online'
      ELSE 'offline'
    END AS connectivity,
    s.last_sync_at,
    s.outbox_pending,
    t.number,
    s.initial_load_at,
    s.last_pull_at,
    s.last_push_at,
    app.terminal_sync_lag(t.id) AS pending_changes,
    -- Só conta para quem pode ver os conflitos (a política da tabela decide).
    (SELECT pg_catalog.count(*)::integer FROM sync_conflict sc
      WHERE sc.terminal_id = t.id AND sc.status = 'open' AND sc.deleted_at IS NULL) AS open_conflicts,
    t.offline_zero_stock_minutes AS offline_minutes,
    b.offline_zero_stock_minutes AS branch_offline_minutes,
    t.update_ring,
    u.status AS last_update_status,
    u.version AS last_update_version,
    u.created_at AS last_update_at,
    u.detail AS last_update_detail,
    t.fixed_seller_id,
    (SELECT fs.code::text || ' · ' || fs.name FROM user_account fs WHERE fs.id = t.fixed_seller_id) AS fixed_seller_name
  FROM terminal t
  JOIN branch b ON b.id = t.branch_id
  LEFT JOIN terminal_status s ON s.terminal_id = t.id AND s.deleted_at IS NULL
  LEFT JOIN terminal_pairing_request r ON r.terminal_id = t.id AND r.deleted_at IS NULL
  LEFT JOIN LATERAL (
    SELECT e.status, app.release_version(e.release_id) AS version, e.created_at, e.detail
      FROM terminal_update_event e
     WHERE e.terminal_id = t.id AND e.deleted_at IS NULL
     ORDER BY e.created_at DESC, e.id DESC
     LIMIT 1
  ) u ON true
  WHERE t.deleted_at IS NULL;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  app.set_terminal_fixed_seller(uuid, uuid),
  app.terminal_seller_options()
TO farmaerp_app;
