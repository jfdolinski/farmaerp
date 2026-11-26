-- Up Migration

-- Controlado que não é psicotrópico (antimicrobiano, RDC 471/2021): receita (data e número),
-- prescritor e paciente (idade e sexo) obrigatórios; o comprador passa a ser opcional.
-- Os psicotrópicos (listas da Portaria 344/98) continuam exigindo o comprador com documento.
-- O comprador vai inteiro ou não vai: nada de nome sem documento.

ALTER TABLE controlled_dispensing DROP CONSTRAINT controlled_dispensing_complete_check;
ALTER TABLE controlled_dispensing ADD CONSTRAINT controlled_dispensing_complete_check CHECK (
  (status = 'pending' AND pending_reason IS NOT NULL AND prescription_type IS NULL)
  OR (status = 'complete' AND pending_reason IS NULL AND batch_id IS NOT NULL
      AND prescription_type IS NOT NULL AND prescription_date IS NOT NULL
      AND prescriber_name IS NOT NULL AND prescriber_council IS NOT NULL AND prescriber_number IS NOT NULL
      AND prescriber_state IS NOT NULL
      AND num_nulls(buyer_name, buyer_document_type, buyer_document, buyer_issuer, buyer_state) IN (0, 5)
      AND (prescription_type = 'antimicrobial' OR buyer_name IS NOT NULL)
      AND (prescription_type NOT LIKE 'notification%' OR prescription_number IS NOT NULL)
      AND (prescription_type <> 'antimicrobial'
           OR (prescription_number IS NOT NULL AND patient_age IS NOT NULL AND patient_sex IS NOT NULL)))
) NOT VALID;
-- Vendas antigas já cumpriam a regra anterior (mais rígida no comprador); só o número da receita
-- do antimicrobiano é novo, por isso a conferência das linhas antigas fica de fora.

ALTER TABLE sngpc_dispensing_complement
  ALTER COLUMN buyer_name DROP NOT NULL,
  ALTER COLUMN buyer_document_type DROP NOT NULL,
  ALTER COLUMN buyer_document DROP NOT NULL,
  ALTER COLUMN buyer_issuer DROP NOT NULL,
  ALTER COLUMN buyer_state DROP NOT NULL;
ALTER TABLE sngpc_dispensing_complement DROP CONSTRAINT sngpc_complement_rules_check;
ALTER TABLE sngpc_dispensing_complement ADD CONSTRAINT sngpc_complement_rules_check CHECK (
  num_nulls(buyer_name, buyer_document_type, buyer_document, buyer_issuer, buyer_state) IN (0, 5)
  AND (prescription_type = 'antimicrobial' OR buyer_name IS NOT NULL)
  AND (prescription_type NOT LIKE 'notification%' OR prescription_number IS NOT NULL)
  AND (prescription_type <> 'antimicrobial'
       OR (prescription_number IS NOT NULL AND patient_age IS NOT NULL AND patient_sex IS NOT NULL))
) NOT VALID;

-- Completar pela retaguarda: comprador em branco vai vazio (antimicrobiano).
CREATE OR REPLACE FUNCTION app.sngpc_complete_sale(p_movement_id uuid, p_data jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  target public.sngpc_movement := app.require_sngpc_pending(p_movement_id);
  dispensing public.controlled_dispensing;
  batch uuid := NULLIF(p_data ->> 'batchId', '')::uuid;
  issued date := NULLIF(p_data ->> 'prescriptionDate', '')::date;
  rx_type text := p_data ->> 'prescriptionType';
  sold_on date;
  -- Sem nome do comprador, nenhum dado dele (o tipo de documento vem marcado na tela).
  buyer jsonb := CASE WHEN NULLIF(pg_catalog.btrim(COALESCE(p_data ->> 'buyerName', '')), '') IS NULL THEN '{}'::jsonb
    ELSE pg_catalog.jsonb_build_object('name', pg_catalog.btrim(p_data ->> 'buyerName'), 'documentType', p_data ->> 'buyerDocumentType',
      'document', p_data ->> 'buyerDocument', 'issuer', pg_catalog.btrim(p_data ->> 'buyerIssuer'),
      'state', pg_catalog.upper(p_data ->> 'buyerState')) END;
BEGIN
  SELECT d.* INTO dispensing FROM public.controlled_dispensing d WHERE d.id = target.dispensing_id;
  IF target.kind <> 'sale' OR dispensing.id IS NULL OR dispensing.status <> 'pending' THEN
    RAISE EXCEPTION 'Só a venda de controlado liberada como pendente recebe os dados da receita.'
      USING ERRCODE = 'FA867', DETAIL = pg_catalog.format('Movimentação %s.', target.kind);
  END IF;
  PERFORM app.require_sngpc_batch(batch, target.branch_id, target.product_id);
  sold_on := app.local_day(target.occurred_at);
  IF issued IS NULL OR issued > sold_on OR issued < sold_on - app.prescription_valid_days(rx_type) THEN
    RAISE EXCEPTION 'A receita está vencida ou com data no futuro.'
      USING ERRCODE = 'FA987', DETAIL = pg_catalog.format('Receita de %s, venda de %s.', issued, sold_on);
  END IF;
  UPDATE public.sngpc_dispensing_complement SET deleted_at = pg_catalog.now()
   WHERE dispensing_id = dispensing.id AND deleted_at IS NULL;
  INSERT INTO public.sngpc_dispensing_complement (
    economic_group_id, dispensing_id, batch_id, pharmacist_id, prescription_type, prescription_number, prescription_date,
    prescriber_name, prescriber_council, prescriber_number, prescriber_state, buyer_name, buyer_document_type,
    buyer_document, buyer_issuer, buyer_state, patient_name, patient_age, patient_sex
  ) VALUES (
    target.economic_group_id, dispensing.id, batch, app.current_user_id(), rx_type,
    NULLIF(pg_catalog.btrim(COALESCE(p_data ->> 'prescriptionNumber', '')), ''), issued,
    pg_catalog.btrim(p_data ->> 'prescriberName'), p_data ->> 'prescriberCouncil', p_data ->> 'prescriberNumber',
    pg_catalog.upper(p_data ->> 'prescriberState'), buyer ->> 'name', buyer ->> 'documentType',
    buyer ->> 'document', buyer ->> 'issuer', buyer ->> 'state',
    NULLIF(pg_catalog.btrim(COALESCE(p_data ->> 'patientName', '')), ''), (p_data ->> 'patientAge')::smallint,
    NULLIF(p_data ->> 'patientSex', '')
  );
  UPDATE public.sngpc_movement SET batch_id = batch WHERE id = target.id;
END;
$$;
