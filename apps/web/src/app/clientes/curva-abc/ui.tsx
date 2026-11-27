"use client";

import { useActionState } from "react";
import { ErrorNotice } from "../../error-notice";
import { AbcState, recalculateAbc, saveAbcSettings } from "./actions";
import styles from "../../terminais/page.module.css";

export interface AbcSettingRow {
  branch_id: string;
  branch_name: string;
  period_days: number;
  a_min_sales: number;
  b_min_sales: number;
  a_interval_days: number;
  b_interval_days: number;
  c_interval_days: number;
  a_ran_at: string | null;
  b_ran_at: string | null;
  c_ran_at: string | null;
  a_count: number;
  b_count: number;
  c_count: number;
  can_manage: boolean;
}

/** Parâmetros da curva ABC da filial (quem cadastra clientes nela). */
export function AbcSettingsForm({ row }: { row: AbcSettingRow }) {
  const [state, action, pending] = useActionState<AbcState, FormData>(saveAbcSettings, {});
  const field = (name: string, label: string, value: number, min: number, max: number) => (
    <label>
      {label}
      <input name={name} type="number" min={min} max={max} defaultValue={value} required style={{ width: "7em" }} />
    </label>
  );
  return (
    <form action={action} className={styles.stack}>
      <input type="hidden" name="branchId" value={row.branch_id} />
      <div className={styles.inline}>
        {field("periodDays", "Período (dias)", row.period_days, 7, 730)}
        {field("aMinSales", "Curva A: vendas a partir de", row.a_min_sales, 2, 100000)}
        {field("bMinSales", "Curva B: vendas a partir de", row.b_min_sales, 1, 100000)}
      </div>
      <div className={styles.inline}>
        {field("aIntervalDays", "Recalcular a A a cada (dias)", row.a_interval_days, 1, 365)}
        {field("bIntervalDays", "a B a cada (dias)", row.b_interval_days, 1, 365)}
        {field("cIntervalDays", "a C a cada (dias)", row.c_interval_days, 1, 365)}
      </div>
      <div className={styles.inline}>
        <button type="submit" disabled={pending}>
          {pending ? "Salvando..." : "Salvar parâmetros"}
        </button>
        {state.saved && <span role="status">Parâmetros salvos. Valem nos próximos recálculos.</span>}
      </div>
      <ErrorNotice error={state.error} />
    </form>
  );
}

/** Recalcula as três curvas da filial agora. */
export function RecalculateButton({ branchId }: { branchId: string }) {
  const [state, action, pending] = useActionState<AbcState, FormData>(recalculateAbc, {});
  return (
    <form action={action} className={styles.inline}>
      <input type="hidden" name="branchId" value={branchId} />
      <button type="submit" disabled={pending}>
        {pending ? "Recalculando..." : "Recalcular agora"}
      </button>
      {state.changed !== undefined && (
        <span role="status">
          Pronto: {state.changed} {state.changed === 1 ? "cliente mudou" : "clientes mudaram"} de curva.
        </span>
      )}
      <ErrorNotice error={state.error} />
    </form>
  );
}
