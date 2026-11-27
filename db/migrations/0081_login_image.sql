-- Up Migration

-- Imagem da tela de entrada (retaguarda e PDV). Uma só para a plataforma, enviada pelo administrador
-- da plataforma em /plataforma. Não é dado de cliente: a tela de entrada mostra antes de alguém entrar,
-- e o PDV baixa e guarda para mostrar sem internet. Trocar é outra linha; voltar ao padrão (cor da
-- marca) é a exclusão lógica da atual.

CREATE TABLE login_image (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  mime text NOT NULL CONSTRAINT login_image_mime_check CHECK (mime IN ('image/jpeg', 'image/png', 'image/webp')),
  sha256 text NOT NULL CONSTRAINT login_image_sha256_check CHECK (sha256 ~ '^[0-9a-f]{64}$'),
  -- Até 3 MB, e o conteúdo precisa ser mesmo do tipo informado (assinatura do arquivo).
  content bytea NOT NULL CONSTRAINT login_image_content_check CHECK (
    octet_length(content) BETWEEN 64 AND 3145728 AND CASE mime
      WHEN 'image/jpeg' THEN substring(content FROM 1 FOR 3) = '\xffd8ff'::bytea
      WHEN 'image/png' THEN substring(content FROM 1 FOR 8) = '\x89504e470d0a1a0a'::bytea
      WHEN 'image/webp' THEN substring(content FROM 1 FOR 4) = '\x52494646'::bytea
                         AND substring(content FROM 9 FOR 4) = '\x57454250'::bytea
    END
  ),
  user_id uuid REFERENCES user_account (id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid,
  trace_id uuid
);
-- Uma imagem em uso por vez.
CREATE UNIQUE INDEX login_image_current_key ON login_image ((true)) WHERE deleted_at IS NULL;
CREATE INDEX login_image_user_id_idx ON login_image (user_id);
CALL app.apply_table_standard('public.login_image');
CREATE TRIGGER block_immutable_columns BEFORE UPDATE ON login_image
  FOR EACH ROW EXECUTE FUNCTION app.block_immutable_columns('mime', 'sha256', 'content', 'user_id', 'created_at');
-- A aplicação lê e grava só pelas funções abaixo.
CREATE POLICY login_image_select ON login_image FOR SELECT TO farmaerp_app USING (false);
CREATE VIEW v_login_image WITH (security_invoker = true) AS SELECT * FROM login_image WHERE deleted_at IS NULL;
GRANT SELECT ON login_image, v_login_image TO farmaerp_app;

-- Troca a imagem. O resumo (sha256) é calculado aqui: é ele que o navegador e o PDV usam para saber
-- se a imagem mudou.
CREATE FUNCTION app.set_login_image(p_mime text, p_content bytea) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  digest text;
BEGIN
  PERFORM app.require_platform_admin();
  IF p_mime IS NULL OR p_content IS NULL THEN
    RAISE EXCEPTION 'A imagem da tela de entrada é inválida.'
      USING ERRCODE = 'FA225', DETAIL = 'set_login_image sem conteúdo.';
  END IF;
  digest := pg_catalog.encode(pg_catalog.sha256(p_content), 'hex');
  UPDATE public.login_image SET deleted_at = now() WHERE deleted_at IS NULL;
  INSERT INTO public.login_image (mime, sha256, content, user_id)
  VALUES (p_mime, digest, p_content, app.current_user_id());
  RETURN digest;
END;
$$;

-- Volta ao padrão: sem imagem, a tela de entrada fica na cor da marca.
CREATE FUNCTION app.clear_login_image() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM app.require_platform_admin();
  UPDATE public.login_image SET deleted_at = now() WHERE deleted_at IS NULL;
END;
$$;

-- A imagem em uso, sem sessão (a tela de entrada aparece antes de alguém entrar). Sem o conteúdo,
-- só o resumo, para conferir se mudou.
CREATE FUNCTION app.current_login_image(p_with_content boolean DEFAULT true)
RETURNS TABLE (sha256 text, mime text, content bytea, size integer, updated_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT i.sha256, i.mime, CASE WHEN p_with_content THEN i.content END, octet_length(i.content), i.created_at
    FROM public.login_image i
   WHERE i.deleted_at IS NULL
$$;

REVOKE ALL ON FUNCTION app.set_login_image(text, bytea), app.clear_login_image(), app.current_login_image(boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.set_login_image(text, bytea), app.clear_login_image(), app.current_login_image(boolean),
  app.require_platform_admin()
  TO farmaerp_app;
