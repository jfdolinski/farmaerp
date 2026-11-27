-- Up Migration

-- Importação de notas pela Plataforma: o administrador da plataforma escolhe o cliente e envia o
-- arquivo para ele. O envio, a fila, o processamento e o relatório são os mesmos da importação feita
-- pelo próprio cliente; muda só de quem é o grupo. A escolha vale para a transação (app.import_group)
-- e só é aceita do administrador da plataforma.

-- Grupo da importação: o escolhido pelo administrador da plataforma, ou o de quem tem imports.manage.
CREATE OR REPLACE FUNCTION app.require_imports_manage() RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  chosen uuid := NULLIF(pg_catalog.current_setting('app.import_group', true), '')::uuid;
BEGIN
  IF chosen IS NOT NULL THEN
    PERFORM app.require_platform_admin();
    RETURN chosen;
  END IF;
  IF NOT app.has_permission('imports.manage') THEN
    RAISE EXCEPTION 'Você não tem permissão para esta operação.'
      USING ERRCODE = 'FA002', DETAIL = 'Importação sem imports.manage.';
  END IF;
  RETURN app.current_user_group();
END;
$$;

-- Escolhe o cliente para as próximas chamadas da importação nesta transação.
CREATE FUNCTION app.use_import_group(p_group_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM app.require_platform_admin();
  IF NOT EXISTS (SELECT 1 FROM public.economic_group g WHERE g.id = p_group_id AND g.deleted_at IS NULL) THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('economic_group %s.', p_group_id);
  END IF;
  PERFORM pg_catalog.set_config('app.import_group', p_group_id::text, true);
END;
$$;

-- O mesmo, a partir de uma importação já começada (partes, conclusão e relatório).
CREATE FUNCTION app.use_import_of(p_import_id uuid) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  group_id uuid;
BEGIN
  PERFORM app.require_platform_admin();
  SELECT d.economic_group_id INTO group_id FROM public.document_import d
   WHERE d.id = p_import_id AND d.deleted_at IS NULL;
  IF group_id IS NULL THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('document_import %s.', p_import_id);
  END IF;
  PERFORM pg_catalog.set_config('app.import_group', group_id::text, true);
  RETURN group_id;
END;
$$;

REVOKE ALL ON FUNCTION app.use_import_group(uuid), app.use_import_of(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.use_import_group(uuid), app.use_import_of(uuid) TO farmaerp_app;
