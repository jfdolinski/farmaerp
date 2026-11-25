"use client";

import { useActionState } from "react";
import { ErrorNotice } from "../error-notice";
import { CashbackPolicyState, saveCashbackPolicy } from "./actions";
import styles from "../terminais/page.module.css";

export interface CashbackPolicy {
  waiting_days: number;
  validity_days: number;
  max_use_percent: number;
  can_edit: boolean;
}

export function CashbackPolicyForm({ policy }: { policy: CashbackPolicy }) {
  const [state, action, pending] = useActionState<CashbackPolicyState, FormData>(saveCashbackPolicy, {});
  return (
    <form action={action} className={styles.stack}>
      <fieldset disabled={!policy.can_edit} className={styles.inline}>
        <label>
          Carência (dias)
          <input name="waitingDays" type="number" min={0} max={365} defaultValue={policy.waiting_days} />
        </label>
        <label>
          Validade (dias)
          <input name="validityDays" type="number" min={1} max={3650} defaultValue={policy.validity_days} />
        </label>
        <label>
          Paga até (% da compra)
          <input name="maxUsePercent" inputMode="decimal" defaultValue={String(policy.max_use_percent).replace(".", ",")} />
        </label>
        {policy.can_edit && (
          <button type="submit" disabled={pending}>
            Salvar cashback
          </button>
        )}
      </fieldset>
      {state.done && <p className={styles.success}>Salvo.</p>}
      <ErrorNotice error={state.error} />
    </form>
  );
}
