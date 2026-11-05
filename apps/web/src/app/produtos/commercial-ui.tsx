"use client";

import { useActionState, useEffect, useRef } from "react";
import { ErrorNotice } from "../error-notice";
import {
  addPmc,
  ProductFormState,
  reactivateProduct,
  setBranchLocation,
  setPrice,
  setStatus,
} from "./actions";
import { moneyText, REGION_LABELS, STATUS_LABELS, statusLabel } from "./commercial-format";
import { keepValues } from "./ui";
import styles from "../terminais/page.module.css";

export interface BranchRow {
  branch_id: string;
  branch_name: string;
  state: string | null;
  pmc_region: string | null;
  status: string;
  exception_price: string | null;
  effective_price: string | null;
  pmc: string | null;
  above_pmc: boolean;
}

export interface PmcRow {
  state: string;
  pmc_region: string | null;
  value: string;
  source: string;
  created_at: string;
  author: string | null;
}

export interface PriceEvent {
  branch_id: string | null;
  branch_name: string | null;
  price: string | null;
  reason: string | null;
  created_at: string;
  author: string | null;
}

export interface StatusEvent {
  branch_name: string | null;
  old_status: string;
  new_status: string;
  reason: string;
  created_at: string;
  author: string | null;
}

export interface BranchLocationValues {
  id: string;
  name: string;
  state: string | null;
  pmc_region: string | null;
}

const STATUS_STYLES: Record<string, string> = {
  active: styles.active,
  on_order: styles.pending,
  blocked: styles.blocked,
  inactive: styles.offline,
};

const STATES = [
  "AC", "AL", "AM", "AP", "BA", "CE", "DF", "ES", "GO", "MA", "MG", "MS", "MT", "PA",
  "PB", "PE", "PI", "PR", "RJ", "RN", "RO", "RR", "RS", "SC", "SE", "SP", "TO",
];

function RegionSelect({ value, disabled }: { value?: string | null; disabled?: boolean }) {
  return (
    <label>
      Região especial
      <select name="region" defaultValue={value ?? ""} disabled={disabled}>
        <option value="">Nenhuma</option>
        {Object.entries(REGION_LABELS).map(([key, label]) => (
          <option key={key} value={key}>
            {label}
          </option>
        ))}
      </select>
    </label>
  );
}

function StateSelect({ value, disabled, required }: { value?: string | null; disabled?: boolean; required?: boolean }) {
  return (
    <label>
      Estado
      <select name="state" defaultValue={value ?? ""} disabled={disabled} required={required}>
        <option value="">Selecione</option>
        {STATES.map((state) => (
          <option key={state} value={state}>
            {state}
          </option>
        ))}
      </select>
    </label>
  );
}

/** Limpa o formulário só depois de dar certo: num erro, o que foi digitado continua. */
function useResetOnDone(done?: boolean, state?: unknown) {
  const form = useRef<HTMLFormElement>(null);
  useEffect(() => {
    if (done) form.current?.reset();
  }, [done, state]);
  return form;
}

export function StatusForm({ productId, grid }: { productId: string; grid: BranchRow[] }) {
  const [state, action, pending] = useActionState<ProductFormState, FormData>(setStatus, {});
  const form = useResetOnDone(state.done, state);

  return (
    <form ref={form} action={action} onSubmit={keepValues(action)} className={styles.stack}>
      <input type="hidden" name="productId" value={productId} />
      <div className={styles.tableWrap}>
        <table>
          <thead>
            <tr>
              <th>Marcar</th>
              <th>Filial</th>
              <th>Status</th>
              <th>Preço em vigor</th>
              <th>PMC</th>
            </tr>
          </thead>
          <tbody>
            {grid.map((row) => (
              <tr key={row.branch_id}>
                <td>
                  <input
                    type="checkbox"
                    name="branchIds"
                    value={row.branch_id}
                    aria-label={`Marcar ${row.branch_name}`}
                    disabled={row.status === "inactive"}
                  />
                </td>
                <td>
                  {row.branch_name}
                  <small>{row.state ?? "Estado não informado"}</small>
                </td>
                <td>
                  <span className={`${styles.badge} ${STATUS_STYLES[row.status] ?? ""}`}>
                    {statusLabel(row.status)}
                  </span>
                </td>
                <td>
                  {moneyText(row.effective_price)}
                  {row.exception_price !== null && <small>Exceção da filial</small>}
                  {row.above_pmc && <small className={styles.warning}>Acima do PMC</small>}
                </td>
                <td>{moneyText(row.pmc)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <div className={styles.inline}>
        <label>
          Novo status
          <select name="status" defaultValue="blocked">
            {Object.entries(STATUS_LABELS).map(([key, label]) => (
              <option key={key} value={key}>
                {label}
              </option>
            ))}
          </select>
        </label>
        <label>
          Motivo
          <input name="reason" required maxLength={500} size={40} />
        </label>
        <button type="submit" disabled={pending}>
          Aplicar às filiais marcadas
        </button>
      </div>
      <ErrorNotice error={state.error} />
      {state.done && (
        <p className={styles.success} role="status">
          Status atualizado.
        </p>
      )}
    </form>
  );
}

export function ReactivateForm({ productId, grid }: { productId: string; grid: BranchRow[] }) {
  const [state, action, pending] = useActionState<ProductFormState, FormData>(reactivateProduct, {});
  const form = useResetOnDone(state.done, state);

  return (
    <form ref={form} action={action} onSubmit={keepValues(action)} className={styles.device}>
      <h3>Reativar</h3>
      <input type="hidden" name="productId" value={productId} />
      <div className={styles.inline}>
        {grid
          .filter((row) => row.status === "inactive")
          .map((row) => (
            <label key={row.branch_id} className={styles.check}>
              <input type="checkbox" name="branchIds" value={row.branch_id} />
              {row.branch_name}
            </label>
          ))}
      </div>
      <div className={styles.inline}>
        <label>
          Voltar para
          <select name="status" defaultValue="active">
            {Object.entries(STATUS_LABELS)
              .filter(([key]) => key !== "inactive")
              .map(([key, label]) => (
                <option key={key} value={key}>
                  {label}
                </option>
              ))}
          </select>
        </label>
        <label>
          Motivo
          <input name="reason" required maxLength={500} />
        </label>
        <label>
          Sua senha
          <input name="password" type="password" required maxLength={200} autoComplete="current-password" />
        </label>
        <button type="submit" disabled={pending}>
          Reativar
        </button>
      </div>
      <ErrorNotice error={state.error} />
    </form>
  );
}

export function PriceForms({ productId, grid }: { productId: string; grid: BranchRow[] }) {
  const [network, networkAction, networkPending] = useActionState<ProductFormState, FormData>(setPrice, {});
  const [exception, exceptionAction, exceptionPending] = useActionState<ProductFormState, FormData>(setPrice, {});
  const networkForm = useResetOnDone(network.done, network);
  const exceptionForm = useResetOnDone(exception.done, exception);

  return (
    <div className={styles.stack}>
      <form ref={networkForm} action={networkAction} onSubmit={keepValues(networkAction)} className={styles.stack}>
        <input type="hidden" name="productId" value={productId} />
        <div className={styles.inline}>
          <label>
            Preço da rede
            <input name="price" inputMode="decimal" required size={10} placeholder="0,00" />
          </label>
          <label>
            Motivo (opcional)
            <input name="reason" maxLength={500} />
          </label>
          <button type="submit" disabled={networkPending}>
            Salvar preço da rede
          </button>
        </div>
        <ErrorNotice error={network.error} />
      </form>
      <form ref={exceptionForm} action={exceptionAction} onSubmit={keepValues(exceptionAction)} className={styles.stack}>
        <input type="hidden" name="productId" value={productId} />
        <div className={styles.inline}>
          <label>
            Exceção da filial
            <select name="branchId" required defaultValue="">
              <option value="" disabled>
                Selecione
              </option>
              {grid.map((row) => (
                <option key={row.branch_id} value={row.branch_id}>
                  {row.branch_name}
                </option>
              ))}
            </select>
          </label>
          <label>
            Preço
            <input name="price" inputMode="decimal" size={10} placeholder="0,00" />
          </label>
          <label>
            Motivo (opcional)
            <input name="reason" maxLength={500} />
          </label>
          <button type="submit" name="intent" value="save" disabled={exceptionPending}>
            Salvar exceção
          </button>
          <button type="submit" name="intent" value="remove" disabled={exceptionPending}>
            Encerrar exceção
          </button>
        </div>
        <ErrorNotice error={exception.error} />
      </form>
    </div>
  );
}

export function AddPmcForm({ productId }: { productId: string }) {
  const [state, action, pending] = useActionState<ProductFormState, FormData>(addPmc, {});
  const form = useResetOnDone(state.done, state);

  return (
    <form ref={form} action={action} onSubmit={keepValues(action)} className={styles.stack}>
      <input type="hidden" name="productId" value={productId} />
      <div className={styles.inline}>
        <StateSelect required />
        <RegionSelect />
        <label>
          PMC
          <input name="value" inputMode="decimal" required size={10} placeholder="0,00" />
        </label>
        <button type="submit" disabled={pending}>
          Adicionar PMC
        </button>
      </div>
      <ErrorNotice error={state.error} />
    </form>
  );
}

export function BranchLocationRow({
  branch,
  canManage,
}: {
  branch: BranchLocationValues;
  canManage: boolean;
}) {
  const [state, action, pending] = useActionState<ProductFormState, FormData>(setBranchLocation, {});

  return (
    <form action={action} onSubmit={keepValues(action)} className={styles.stack}>
      <input type="hidden" name="id" value={branch.id} />
      <div className={styles.inline}>
        <strong>{branch.name}</strong>
        <StateSelect value={branch.state} disabled={!canManage} />
        <RegionSelect value={branch.pmc_region} disabled={!canManage} />
        {canManage && (
          <button type="submit" disabled={pending}>
            Salvar
          </button>
        )}
      </div>
      <ErrorNotice error={state.error} />
      {state.done && (
        <p className={styles.success} role="status">
          Filial salva.
        </p>
      )}
    </form>
  );
}
