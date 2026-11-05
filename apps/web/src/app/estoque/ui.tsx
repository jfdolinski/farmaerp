"use client";

import { useActionState, useEffect, useRef, useState } from "react";
import { ErrorNotice } from "../error-notice";
import { keepValues } from "../produtos/ui";
import {
  registerMovement,
  reverseMovement,
  setBatchTracking,
  StockFormState,
  updateBatch,
} from "./actions";
import { BalanceRow } from "./format";
import styles from "../terminais/page.module.css";

export interface BranchOption {
  id: string;
  name: string;
}

export interface TrackingRow {
  branch_id: string;
  branch_name: string;
  tracks_batches: boolean;
  is_controlled: boolean;
}

export function MovementForm({
  branches,
  canAdjust,
  canLoss,
}: {
  branches: BranchOption[];
  canAdjust: boolean;
  canLoss: boolean;
}) {
  const initialKind = canAdjust ? "in" : "loss";
  const [state, action, pending] = useActionState<StockFormState, FormData>(registerMovement, {});
  const [kind, setKind] = useState(initialKind);
  const form = useRef<HTMLFormElement>(null);
  useEffect(() => {
    if (state.done) form.current?.reset();
  }, [state]);

  return (
    <form
      ref={form}
      action={action}
      onSubmit={keepValues(action)}
      onReset={() => setKind(initialKind)}
      className={styles.stack}
    >
      <div className={styles.inline}>
        <label>
          Operação
          <select name="kind" value={kind} onChange={(event) => setKind(event.target.value)}>
            {canAdjust && <option value="in">Ajuste de entrada</option>}
            {canAdjust && <option value="out">Ajuste de saída</option>}
            {canLoss && <option value="loss">Perda</option>}
          </select>
        </label>
        <label>
          Código ou código de barras
          <input name="productLookup" required maxLength={30} />
        </label>
        <label>
          Filial
          <select name="branchId" required defaultValue="">
            <option value="" disabled>
              Selecione
            </option>
            {branches.map((branch) => (
              <option key={branch.id} value={branch.id}>
                {branch.name}
              </option>
            ))}
          </select>
        </label>
        <label>
          Quantidade
          <input name="quantity" inputMode="decimal" required size={8} />
        </label>
      </div>
      <div className={styles.inline}>
        <label>
          Lote
          <input name="batchNumber" maxLength={40} placeholder="Se o produto controla" />
        </label>
        {kind === "in" && (
          <>
            <label>
              Validade do lote
              <input type="date" name="expiresOn" />
            </label>
            <label>
              MS do lote
              <input name="msRegistration" inputMode="numeric" maxLength={13} placeholder="Herda do Catálogo" />
            </label>
          </>
        )}
        <label>
          Motivo
          <input name="reason" required maxLength={500} size={30} />
        </label>
        <button type="submit" disabled={pending}>
          Registrar
        </button>
      </div>
      <ErrorNotice error={state.error} />
      {state.done && (
        <p className={styles.success} role="status">
          Movimentação registrada.
        </p>
      )}
    </form>
  );
}

export function EditBatchForm({ row }: { row: BalanceRow }) {
  const [state, action, pending] = useActionState<StockFormState, FormData>(updateBatch, {});

  return (
    <details className={styles.reason}>
      <summary>Editar lote</summary>
      <form action={action} onSubmit={keepValues(action)} className={styles.rowForm}>
        <input type="hidden" name="id" value={row.batch_id ?? ""} />
        <label>
          Lote
          <input name="batchNumber" required maxLength={40} defaultValue={row.batch_number ?? ""} />
        </label>
        <label>
          Validade
          <input type="date" name="expiresOn" required defaultValue={row.expires_on ?? ""} />
        </label>
        <label>
          MS
          <input name="msRegistration" inputMode="numeric" maxLength={13} defaultValue={row.ms_registration ?? ""} />
        </label>
        <label>
          Motivo
          <input name="reason" required maxLength={500} />
        </label>
        <button type="submit" disabled={pending}>
          Salvar lote
        </button>
        <ErrorNotice error={state.error} />
      </form>
    </details>
  );
}

export function ReverseForm({ id }: { id: string }) {
  const [state, action, pending] = useActionState<StockFormState, FormData>(reverseMovement, {});

  return (
    <details className={styles.reason}>
      <summary>Estornar</summary>
      <form action={action} onSubmit={keepValues(action)} className={styles.rowForm}>
        <input type="hidden" name="id" value={id} />
        <label>
          Motivo
          <input name="reason" required maxLength={500} />
        </label>
        <button type="submit" className={styles.danger} disabled={pending}>
          Confirmar estorno
        </button>
        <ErrorNotice error={state.error} />
      </form>
    </details>
  );
}

export function BatchTrackingRow({
  productId,
  row,
  canManage,
}: {
  productId: string;
  row: TrackingRow;
  canManage: boolean;
}) {
  const [state, action, pending] = useActionState<StockFormState, FormData>(setBatchTracking, {});
  const on = row.is_controlled || row.tracks_batches;

  return (
    <form action={action} onSubmit={keepValues(action)} className={styles.stack}>
      <input type="hidden" name="productId" value={productId} />
      <input type="hidden" name="branchId" value={row.branch_id} />
      <input type="hidden" name="tracks" value={row.tracks_batches ? "0" : "1"} />
      <div className={styles.inline}>
        <strong>{row.branch_name}</strong>
        <span className={`${styles.badge} ${on ? styles.active : styles.offline}`}>
          {on ? "Controla lote" : "Sem controle de lote"}
        </span>
        {row.is_controlled && <span className={styles.hint}>Obrigatório em produto controlado.</span>}
        {canManage && !row.is_controlled && (
          <button type="submit" disabled={pending}>
            {row.tracks_batches ? "Desligar" : "Ligar"}
          </button>
        )}
      </div>
      <ErrorNotice error={state.error} />
    </form>
  );
}
