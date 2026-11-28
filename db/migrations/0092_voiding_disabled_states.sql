-- Up Migration

-- NT 2023.002 v1.02 (Portal da NF-e, 27/10/2026), com os Ajustes SINIEF 38/2026 e 40/2026: a
-- inutilização de numeração deixou de existir em AC, BA e SP desde 11/11/2026 (a Sefaz responde 998
-- "Serviço Desativado" ou HTTP 404). Nessas UFs o buraco de numeração continua listado, mas não se
-- inutiliza: o pedido é recusado antes de ir à Sefaz (FA788).

-- UFs em que a Sefaz não inutiliza mais. Outra UF que aderir entra numa migração nova.
CREATE FUNCTION app.state_voiding_disabled(p_state text) RETURNS boolean
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$
  SELECT pg_catalog.upper(pg_catalog.btrim(p_state)) IN ('AC', 'BA', 'SP')
$$;

-- Os buracos dizem se a UF da filial ainda inutiliza.
DROP FUNCTION app.fiscal_number_gaps(uuid);
CREATE FUNCTION app.fiscal_number_gaps(p_branch_id uuid DEFAULT NULL)
RETURNS TABLE (
  branch_id uuid, branch_name text, terminal_id uuid, terminal_name text, series integer, first_number bigint, last_number bigint,
  quantity bigint, rejected integer, safe boolean, voiding_available boolean
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  WITH series_range AS (
    SELECT fs.terminal_id, t.branch_id, t.name AS terminal_name, fs.series, fs.last_used_number,
           (SELECT pg_catalog.min(d.number) FROM public.fiscal_document d
             WHERE d.branch_id = t.branch_id AND d.model = '65' AND d.series = fs.series AND d.deleted_at IS NULL) AS first_seen
      FROM public.terminal_fiscal_series fs
      JOIN public.terminal t ON t.id = fs.terminal_id
     WHERE fs.model = '65' AND fs.deleted_at IS NULL AND fs.last_used_number IS NOT NULL
       AND fs.economic_group_id = app.current_user_group()
       AND (app.has_permission('fiscal.void', t.branch_id) OR app.has_permission('sales.view', t.branch_id))
       AND (p_branch_id IS NULL OR t.branch_id = p_branch_id)
  ),
  missing AS (
    SELECT r.*, n.n
      FROM series_range r
      CROSS JOIN LATERAL pg_catalog.generate_series(r.first_seen, r.last_used_number) AS n(n)
     WHERE r.first_seen IS NOT NULL AND r.last_used_number - r.first_seen < 200000
       AND NOT EXISTS (
         SELECT 1 FROM public.fiscal_document d
          WHERE d.branch_id = r.branch_id AND d.model = '65' AND d.series = r.series AND d.number = n.n
            AND d.status <> 'rejected' AND d.deleted_at IS NULL)
       AND NOT EXISTS (
         SELECT 1 FROM public.fiscal_number_void v
          WHERE v.branch_id = r.branch_id AND v.model = '65' AND v.series = r.series AND n.n BETWEEN v.first_number AND v.last_number
            AND v.deleted_at IS NULL)
  ),
  islands AS (
    SELECT m.*, m.n - pg_catalog.row_number() OVER (PARTITION BY m.terminal_id, m.series ORDER BY m.n) AS island FROM missing m
  )
  SELECT i.branch_id, b.name, i.terminal_id, i.terminal_name, i.series, pg_catalog.min(i.n), pg_catalog.max(i.n), pg_catalog.count(*),
         (SELECT pg_catalog.count(*)::integer FROM public.fiscal_document d
           WHERE d.branch_id = i.branch_id AND d.model = '65' AND d.series = i.series AND d.status = 'rejected' AND d.deleted_at IS NULL
             AND d.number BETWEEN pg_catalog.min(i.n) AND pg_catalog.max(i.n)),
         COALESCE((SELECT ts.outbox_pending = 0 FROM public.terminal_status ts WHERE ts.terminal_id = i.terminal_id), false),
         NOT app.state_voiding_disabled(b.state::text)
    FROM islands i JOIN public.branch b ON b.id = i.branch_id
   GROUP BY i.branch_id, b.name, b.state, i.terminal_id, i.terminal_name, i.series, i.island
   ORDER BY b.name, i.terminal_name, i.series, pg_catalog.min(i.n)
$$;

-- Contexto da inutilização: a UF da filial precisa ainda ter o serviço; a faixa tem de ser buraco.
CREATE OR REPLACE FUNCTION app.fiscal_void_context(p_branch_id uuid, p_series integer, p_first bigint, p_last bigint) RETURNS TABLE (
  branch_id uuid, company_id uuid, cnpj text, state text, environment smallint, encrypted_pfx bytea, encrypted_password bytea
)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_state text;
BEGIN
  IF NOT app.has_permission('fiscal.void', p_branch_id) OR NOT EXISTS (
    SELECT 1 FROM public.branch b JOIN public.company c ON c.id = b.company_id
     WHERE b.id = p_branch_id AND c.economic_group_id = app.current_user_group() AND b.deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Você não tem permissão para esta operação.' USING ERRCODE = 'FA002', DETAIL = 'Inutilização sem fiscal.void.';
  END IF;
  SELECT b.state::text INTO v_state FROM public.branch b WHERE b.id = p_branch_id;
  IF app.state_voiding_disabled(v_state) THEN
    RAISE EXCEPTION 'A Sefaz desta UF não faz mais inutilização de numeração.' USING ERRCODE = 'FA788',
      DETAIL = pg_catalog.format('UF %s.', v_state);
  END IF;
  IF p_series IS NULL OR p_first IS NULL OR p_last IS NULL OR p_first < 1 OR p_last < p_first OR p_last - p_first >= 10000
     OR EXISTS (
       SELECT 1 FROM public.fiscal_document d
        WHERE d.branch_id = p_branch_id AND d.model = '65' AND d.series = p_series AND d.number BETWEEN p_first AND p_last
          AND d.status <> 'rejected' AND d.deleted_at IS NULL)
     OR EXISTS (
       SELECT 1 FROM public.fiscal_number_void v
        WHERE v.branch_id = p_branch_id AND v.model = '65' AND v.series = p_series AND v.deleted_at IS NULL
          AND v.first_number <= p_last AND v.last_number >= p_first) THEN
    RAISE EXCEPTION 'A faixa para inutilizar é inválida.' USING ERRCODE = 'FA755',
      DETAIL = pg_catalog.format('Série %s, %s a %s.', p_series, p_first, p_last);
  END IF;
  RETURN QUERY
    SELECT b.id, b.company_id, b.cnpj::text, b.state::text, b.nfce_environment, bc.encrypted_pfx, bc.encrypted_password
      FROM public.branch b
      LEFT JOIN public.branch_certificate bc ON bc.branch_id = b.id AND bc.deleted_at IS NULL
     WHERE b.id = p_branch_id;
END;
$$;

REVOKE ALL ON FUNCTION app.state_voiding_disabled(text), app.fiscal_number_gaps(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.state_voiding_disabled(text), app.fiscal_number_gaps(uuid) TO farmaerp_app;
