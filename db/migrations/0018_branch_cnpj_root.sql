-- A filial deixa de precisar da mesma raiz de CNPJ da empresa. O certificado passa a ser conferido
-- com o CNPJ da própria filial, porque é ele que vai na nota.

CREATE OR REPLACE FUNCTION app.validate_branch() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  company_group_id uuid;
  company_deleted_at timestamptz;
  region_group_id uuid;
BEGIN
  SELECT c.economic_group_id, c.deleted_at
    INTO company_group_id, company_deleted_at
    FROM public.company c
   WHERE c.id = NEW.company_id
     FOR SHARE;

  IF NEW.deleted_at IS NULL THEN
    IF company_deleted_at IS NOT NULL THEN
      RAISE EXCEPTION 'A empresa informada não está ativa.'
        USING ERRCODE = 'FA204',
              DETAIL = pg_catalog.format('company %s inativa.', NEW.company_id);
    END IF;

    IF NEW.region_id IS NOT NULL THEN
      SELECT bg.economic_group_id INTO region_group_id
        FROM public.region r
        JOIN public.branch_group bg ON bg.id = r.branch_group_id
       WHERE r.id = NEW.region_id AND r.deleted_at IS NULL
         FOR SHARE OF r;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'A região informada não está ativa.'
          USING ERRCODE = 'FA205',
                DETAIL = pg_catalog.format('region %s inativa.', NEW.region_id);
      END IF;

      IF region_group_id IS DISTINCT FROM company_group_id THEN
        RAISE EXCEPTION 'A região precisa ser do mesmo grupo econômico da empresa.'
          USING ERRCODE = 'FA206',
                DETAIL = pg_catalog.format('region %s, company %s.', NEW.region_id, NEW.company_id);
      END IF;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

-- Raiz de CNPJ que vale para a filial: a dela e, se ainda não tiver CNPJ, a da empresa.
CREATE FUNCTION app.branch_cnpj_root(p_branch public.branch) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE(
    pg_catalog.left(p_branch.cnpj, 8),
    (SELECT c.cnpj_root::text FROM public.company c WHERE c.id = p_branch.company_id)
  )
$$;

CREATE OR REPLACE FUNCTION app.set_branch_certificate(
  p_branch_id uuid, p_meta jsonb, p_encrypted_pfx bytea, p_encrypted_password bytea
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.branch := app.require_branch_permission('fiscal.certificate', p_branch_id);
  new_id uuid;
BEGIN
  IF pg_catalog.left(p_meta ->> 'cnpj', 8) IS DISTINCT FROM app.branch_cnpj_root(target) THEN
    RAISE EXCEPTION 'O certificado é de outra empresa.'
      USING ERRCODE = 'FA913', DETAIL = pg_catalog.format('Filial %s.', p_branch_id);
  END IF;
  IF (p_meta ->> 'validTo')::timestamptz <= pg_catalog.now() THEN
    RAISE EXCEPTION 'O certificado está vencido.'
      USING ERRCODE = 'FA914', DETAIL = pg_catalog.format('Filial %s.', p_branch_id);
  END IF;

  UPDATE public.branch_certificate bc SET deleted_at = pg_catalog.clock_timestamp()
   WHERE bc.branch_id = target.id AND bc.deleted_at IS NULL;
  INSERT INTO public.branch_certificate (
    economic_group_id, branch_id, subject_name, cnpj, valid_from, valid_to, fingerprint,
    encrypted_pfx, encrypted_password
  ) VALUES (
    app.current_user_group(), target.id, p_meta ->> 'subjectName', p_meta ->> 'cnpj',
    (p_meta ->> 'validFrom')::timestamptz, (p_meta ->> 'validTo')::timestamptz, p_meta ->> 'fingerprint',
    p_encrypted_pfx, p_encrypted_password
  ) RETURNING id INTO new_id;
  RETURN new_id;
END;
$$;

-- A cópia continua dentro da empresa, porque a criptografia é por empresa, e agora também exige
-- a mesma raiz: uma filial de outra raiz não pode assinar com este certificado.
CREATE OR REPLACE FUNCTION app.copy_branch_certificate(p_source_branch_id uuid, p_target_branch_ids uuid[]) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  source_branch public.branch := app.require_branch_permission('fiscal.certificate', p_source_branch_id);
  source public.branch_certificate;
  target_id uuid;
  target public.branch;
  copied integer := 0;
BEGIN
  SELECT * INTO source FROM public.branch_certificate bc
   WHERE bc.branch_id = source_branch.id AND bc.deleted_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'O recurso solicitado não foi encontrado.'
      USING ERRCODE = 'FA006', DETAIL = pg_catalog.format('Filial %s sem certificado.', p_source_branch_id);
  END IF;

  FOR target_id IN SELECT DISTINCT value FROM pg_catalog.unnest(p_target_branch_ids) AS value WHERE value <> source_branch.id LOOP
    target := app.require_branch_permission('fiscal.certificate', target_id);
    IF target.company_id <> source_branch.company_id
       OR app.branch_cnpj_root(target) IS DISTINCT FROM pg_catalog.left(source.cnpj, 8) THEN
      RAISE EXCEPTION 'O certificado é de outra empresa.'
        USING ERRCODE = 'FA913', DETAIL = pg_catalog.format('Filial %s.', target_id);
    END IF;
    UPDATE public.branch_certificate bc SET deleted_at = pg_catalog.clock_timestamp()
     WHERE bc.branch_id = target.id AND bc.deleted_at IS NULL;
    INSERT INTO public.branch_certificate (
      economic_group_id, branch_id, subject_name, cnpj, valid_from, valid_to, fingerprint,
      encrypted_pfx, encrypted_password
    ) VALUES (
      source.economic_group_id, target.id, source.subject_name, source.cnpj, source.valid_from,
      source.valid_to, source.fingerprint, source.encrypted_pfx, source.encrypted_password
    );
    copied := copied + 1;
  END LOOP;
  RETURN copied;
END;
$$;

REVOKE ALL ON FUNCTION app.branch_cnpj_root(public.branch) FROM PUBLIC;
