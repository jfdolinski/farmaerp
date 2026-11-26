-- Up Migration

-- Cadastro de cliente na tela de vendas do PDV (só com internet: a central confere o CPF repetido
-- na hora). Pessoa física, com nome e CPF; telefone e nascimento opcionais. Quem cadastra é o
-- operador do caixa, conferido pela permissão de vender na filial do terminal. Os consentimentos
-- (cashback e ofertas) são opcionais e ficam registrados como dados na loja. O cliente novo já
-- fica guardado neste terminal, como o escolhido na busca.

CREATE FUNCTION app.pdv_create_customer(p_operator_id uuid, p_data jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  terminal_row public.terminal := app.require_active_terminal();
  group_id uuid;
  new_id uuid;
  purpose text;
  result jsonb;
BEGIN
  SELECT c.economic_group_id INTO group_id
    FROM public.branch b JOIN public.company c ON c.id = b.company_id
   WHERE b.id = terminal_row.branch_id;
  IF p_operator_id IS NULL OR NOT EXISTS (
       SELECT 1 FROM public.user_account u
        WHERE u.id = p_operator_id AND u.economic_group_id = group_id AND u.deleted_at IS NULL AND u.is_active
     ) OR NOT app.user_has_permission(p_operator_id, 'sales.sell', terminal_row.branch_id) THEN
    RAISE EXCEPTION 'Você não tem permissão para esta operação.'
      USING ERRCODE = 'FA002', DETAIL = 'Cadastro de cliente no PDV sem operador com sales.sell.';
  END IF;
  IF pg_catalog.jsonb_typeof(p_data) IS DISTINCT FROM 'object'
     OR app.clean_text(p_data ->> 'name') IS NULL OR pg_catalog.length(app.clean_text(p_data ->> 'name')) < 3 THEN
    RAISE EXCEPTION 'Os dados do cliente são inválidos.' USING ERRCODE = 'FA904', DETAIL = 'Nome do cliente no PDV.';
  END IF;

  INSERT INTO public.customer (economic_group_id, person_type, document, name, birth_date, phone)
  VALUES (
    group_id, 'individual', COALESCE(app.clean_document(p_data ->> 'document'), ''), app.clean_text(p_data ->> 'name'),
    NULLIF(p_data ->> 'birthDate', '')::date, app.clean_digits(p_data ->> 'phone')
  ) RETURNING id INTO new_id;

  FOREACH purpose IN ARRAY ARRAY['cashback', 'marketing'] LOOP
    IF (p_data -> 'consents' ->> purpose) = 'true' THEN
      INSERT INTO public.customer_consent_event (economic_group_id, customer_id, purpose, granted, channel)
      VALUES (group_id, new_id, purpose, true, 'store');
    END IF;
  END LOOP;

  INSERT INTO public.pdv_customer_cache (economic_group_id, terminal_id, customer_id)
  VALUES (group_id, terminal_row.id, new_id);
  SELECT d.data INTO result FROM app.pdv_customer_data(terminal_row.id, ARRAY[new_id]) d;
  RETURN pg_catalog.jsonb_build_object('id', new_id, 'data', result);
END;
$$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.pdv_create_customer(uuid, jsonb) TO farmaerp_app;
