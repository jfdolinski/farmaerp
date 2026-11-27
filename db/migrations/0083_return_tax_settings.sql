-- Up Migration

-- Padrões fiscais da NF-e de devolução ao fornecedor, por filial: CFOP (dentro e fora do estado,
-- com e sem ST), CSOSN/CST do ICMS e CST de PIS/COFINS. Já existiam (0079), criados na primeira
-- emissão com os valores padrão; agora a retaguarda lê e altera. Os valores padrão ficam num só
-- lugar, usado pela tabela e pela tela.

CREATE FUNCTION app.return_tax_defaults() RETURNS jsonb
LANGUAGE sql IMMUTABLE
SET search_path = ''
AS $$
  SELECT '{"cfop_internal": "5202", "cfop_interstate": "6202", "cfop_st_internal": "5411", "cfop_st_interstate": "6411",
           "simples_csosn": "102", "simples_csosn_st": "500", "normal_cst": "00", "normal_cst_st": "60",
           "pis_cst": "49", "cofins_cst": "49"}'::jsonb
$$;

ALTER TABLE purchase_return_tax_setting
  ALTER COLUMN cfop_internal SET DEFAULT (app.return_tax_defaults() ->> 'cfop_internal'),
  ALTER COLUMN cfop_interstate SET DEFAULT (app.return_tax_defaults() ->> 'cfop_interstate'),
  ALTER COLUMN cfop_st_internal SET DEFAULT (app.return_tax_defaults() ->> 'cfop_st_internal'),
  ALTER COLUMN cfop_st_interstate SET DEFAULT (app.return_tax_defaults() ->> 'cfop_st_interstate'),
  ALTER COLUMN simples_csosn SET DEFAULT (app.return_tax_defaults() ->> 'simples_csosn'),
  ALTER COLUMN simples_csosn_st SET DEFAULT (app.return_tax_defaults() ->> 'simples_csosn_st'),
  ALTER COLUMN normal_cst SET DEFAULT (app.return_tax_defaults() ->> 'normal_cst'),
  ALTER COLUMN normal_cst_st SET DEFAULT (app.return_tax_defaults() ->> 'normal_cst_st'),
  ALTER COLUMN pis_cst SET DEFAULT (app.return_tax_defaults() ->> 'pis_cst'),
  ALTER COLUMN cofins_cst SET DEFAULT (app.return_tax_defaults() ->> 'cofins_cst');

-- Os padrões de uma linha (ou os de fábrica, sem linha), só com os campos fiscais.
CREATE FUNCTION app.return_tax_values(p_row public.purchase_return_tax_setting) RETURNS jsonb
LANGUAGE sql STABLE
SET search_path = ''
AS $$
  SELECT CASE WHEN p_row.id IS NULL THEN app.return_tax_defaults()
              ELSE pg_catalog.jsonb_build_object(
                'cfop_internal', p_row.cfop_internal, 'cfop_interstate', p_row.cfop_interstate,
                'cfop_st_internal', p_row.cfop_st_internal, 'cfop_st_interstate', p_row.cfop_st_interstate,
                'simples_csosn', p_row.simples_csosn, 'simples_csosn_st', p_row.simples_csosn_st,
                'normal_cst', p_row.normal_cst, 'normal_cst_st', p_row.normal_cst_st,
                'pis_cst', p_row.pis_cst, 'cofins_cst', p_row.cofins_cst) END
$$;

-- Filiais que a pessoa vê no fiscal, com os padrões de cada uma.
CREATE FUNCTION app.return_tax_settings()
RETURNS TABLE (branch_id uuid, branch_name text, settings jsonb, customized boolean, can_manage boolean)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT b.id, b.name, app.return_tax_values(t), app.return_tax_values(t) <> app.return_tax_defaults(),
         app.has_permission('fiscal.manage', b.id)
    FROM public.branch b
    JOIN public.company c ON c.id = b.company_id AND c.deleted_at IS NULL
    LEFT JOIN public.purchase_return_tax_setting t ON t.branch_id = b.id AND t.deleted_at IS NULL
   WHERE c.economic_group_id = app.current_user_group() AND b.deleted_at IS NULL
     AND (app.has_permission('fiscal.view', b.id) OR app.has_permission('fiscal.manage', b.id))
   ORDER BY b.name, b.id
$$;

-- Filial do grupo em que a pessoa altera o fiscal.
CREATE FUNCTION app.require_return_tax_manage(p_branch_id uuid) RETURNS public.branch
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.branch;
BEGIN
  SELECT b.* INTO target FROM public.branch b
    JOIN public.company c ON c.id = b.company_id AND c.deleted_at IS NULL
   WHERE b.id = p_branch_id AND c.economic_group_id = app.current_user_group() AND b.deleted_at IS NULL;
  IF target.id IS NULL THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('branch %s.', p_branch_id);
  END IF;
  IF NOT app.has_permission('fiscal.manage', target.id) THEN
    RAISE EXCEPTION 'Você não tem permissão para esta operação.'
      USING ERRCODE = 'FA002', DETAIL = 'Padrões da devolução sem fiscal.manage.';
  END IF;
  RETURN target;
END;
$$;

-- Altera os padrões da filial. Campo que não vier fica como está; valor fora da lista é recusado.
CREATE FUNCTION app.set_return_tax_setting(p_branch_id uuid, p_data jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.branch := app.require_return_tax_manage(p_branch_id);
  current public.purchase_return_tax_setting;
  wanted jsonb;
BEGIN
  IF p_data IS NULL OR pg_catalog.jsonb_typeof(p_data) <> 'object' THEN
    RAISE EXCEPTION 'Este padrão fiscal da devolução não é aceito.' USING ERRCODE = 'FA775', DETAIL = 'Dados fora do formato.';
  END IF;
  SELECT * INTO current FROM public.purchase_return_tax_setting t
   WHERE t.branch_id = target.id AND t.deleted_at IS NULL FOR UPDATE;
  -- Só os campos fiscais, como texto e sem espaços.
  SELECT app.return_tax_values(current) || COALESCE(pg_catalog.jsonb_object_agg(e.key, pg_catalog.btrim(e.value #>> '{}')), '{}'::jsonb)
    INTO wanted
    FROM pg_catalog.jsonb_each(p_data) e
   WHERE e.key IN (SELECT pg_catalog.jsonb_object_keys(app.return_tax_defaults()))
     AND pg_catalog.jsonb_typeof(e.value) IN ('string', 'number');
  BEGIN
    IF current.id IS NULL THEN
      INSERT INTO public.purchase_return_tax_setting (economic_group_id, branch_id) VALUES (app.current_user_group(), target.id)
      RETURNING * INTO current;
    END IF;
    UPDATE public.purchase_return_tax_setting t
       SET cfop_internal = wanted ->> 'cfop_internal', cfop_interstate = wanted ->> 'cfop_interstate',
           cfop_st_internal = wanted ->> 'cfop_st_internal', cfop_st_interstate = wanted ->> 'cfop_st_interstate',
           simples_csosn = wanted ->> 'simples_csosn', simples_csosn_st = wanted ->> 'simples_csosn_st',
           normal_cst = wanted ->> 'normal_cst', normal_cst_st = wanted ->> 'normal_cst_st',
           pis_cst = wanted ->> 'pis_cst', cofins_cst = wanted ->> 'cofins_cst'
     WHERE t.id = current.id
    RETURNING * INTO current;
  EXCEPTION WHEN check_violation OR not_null_violation THEN
    RAISE EXCEPTION 'Este padrão fiscal da devolução não é aceito.'
      USING ERRCODE = 'FA775', DETAIL = SQLERRM;
  END;
  RETURN app.return_tax_values(current);
END;
$$;

-- Volta a filial aos padrões de fábrica.
CREATE FUNCTION app.reset_return_tax_setting(p_branch_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  RETURN app.set_return_tax_setting(p_branch_id, app.return_tax_defaults());
END;
$$;

REVOKE ALL ON FUNCTION app.return_tax_defaults(), app.return_tax_values(public.purchase_return_tax_setting),
  app.return_tax_settings(), app.require_return_tax_manage(uuid), app.set_return_tax_setting(uuid, jsonb),
  app.reset_return_tax_setting(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.return_tax_defaults(), app.return_tax_settings(), app.set_return_tax_setting(uuid, jsonb),
  app.reset_return_tax_setting(uuid) TO farmaerp_app;
