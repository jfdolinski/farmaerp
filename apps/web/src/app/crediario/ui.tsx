"use client";

import { useActionState, useState } from "react";
import { ErrorNotice } from "../error-notice";
import {
  changeDependent,
  changeLimit,
  changeStatus,
  changeTerms,
  CreditState,
  openCredit,
  savePolicy,
} from "./actions";
import styles from "../terminais/page.module.css";

const moneyText = (value: number) => value.toLocaleString("pt-BR", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const numberText = (value: number) => value.toLocaleString("pt-BR", { maximumFractionDigits: 2 });

function Saved({ state }: { state: CreditState }) {
  return (
    <>
      {state.done && <p className={styles.success}>Salvo.</p>}
      <ErrorNotice error={state.error} />
    </>
  );
}

/** Abre o crediário: filial da conta (os parâmetros dela valem), limite e, se quiser, o motivo. */
export function OpenCreditForm({
  customerId,
  branches,
}: {
  customerId: string;
  branches: { branch_id: string; branch_name: string; suggested_limit: number }[];
}) {
  const [state, action, pending] = useActionState<CreditState, FormData>(openCredit, {});
  const [branchId, setBranchId] = useState(branches[0]?.branch_id ?? "");
  const suggested = branches.find((b) => b.branch_id === branchId)?.suggested_limit ?? 0;
  return (
    <form action={action} className={styles.stack}>
      <input type="hidden" name="customerId" value={customerId} />
      <input type="hidden" name="back" value={`/clientes/${customerId}`} />
      <div className={styles.inline}>
        <label>
          Filial da conta
          <select name="homeBranchId" value={branchId} onChange={(event) => setBranchId(event.target.value)} required>
            {branches.map((branch) => (
              <option key={branch.branch_id} value={branch.branch_id}>
                {branch.branch_name}
              </option>
            ))}
          </select>
        </label>
        <label>
          Limite (R$)
          <input name="creditLimit" inputMode="decimal" required defaultValue={moneyText(suggested)} key={branchId} />
        </label>
        <label>
          Observação
          <input name="reason" maxLength={500} placeholder="Opcional" />
        </label>
        <button type="submit" disabled={pending}>
          Abrir crediário
        </button>
      </div>
      <p className={styles.hint}>
        Limite sugerido pela filial: R$ {moneyText(suggested)} (média mensal das compras dos últimos 6 meses vezes o fator
        da filial).
      </p>
      <Saved state={state} />
    </form>
  );
}

export function LimitForm({ accountId, customerId, current, suggested }: { accountId: string; customerId: string; current: number; suggested: number }) {
  const [state, action, pending] = useActionState<CreditState, FormData>(changeLimit, {});
  return (
    <details className={styles.reason}>
      <summary>Mudar o limite</summary>
      <form action={action} className={styles.rowForm}>
        <input type="hidden" name="accountId" value={accountId} />
        <input type="hidden" name="back" value={`/clientes/${customerId}`} />
        <label>
          Novo limite (R$)
          <input name="creditLimit" inputMode="decimal" required defaultValue={moneyText(current)} />
        </label>
        <label>
          Motivo
          <input name="reason" required maxLength={500} placeholder={`Sugerido hoje: R$ ${moneyText(suggested)}`} />
        </label>
        <button type="submit" disabled={pending}>
          Salvar limite
        </button>
        <Saved state={state} />
      </form>
    </details>
  );
}

export function StatusForm({ accountId, customerId, status }: { accountId: string; customerId: string; status: string }) {
  const [state, action, pending] = useActionState<CreditState, FormData>(changeStatus, {});
  const next = status === "blocked" ? "active" : "blocked";
  return (
    <details className={styles.reason}>
      <summary>{next === "blocked" ? "Bloquear novas compras" : "Liberar novas compras"}</summary>
      <form action={action} className={styles.rowForm}>
        <input type="hidden" name="accountId" value={accountId} />
        <input type="hidden" name="status" value={next} />
        <input type="hidden" name="back" value={`/clientes/${customerId}`} />
        <label>
          Motivo
          <input name="reason" required maxLength={500} />
        </label>
        <button type="submit" disabled={pending}>
          {next === "blocked" ? "Bloquear" : "Liberar"}
        </button>
        <Saved state={state} />
      </form>
    </details>
  );
}

export interface Terms {
  due_mode: string;
  closing_day: number;
  due_day: number;
  interval_days: number;
  own: boolean;
}

export function TermsForm({ accountId, customerId, terms }: { accountId: string; customerId: string; terms: Terms }) {
  const [state, action, pending] = useActionState<CreditState, FormData>(changeTerms, {});
  const [mode, setMode] = useState(terms.own ? terms.due_mode : "");
  return (
    <details className={styles.reason}>
      <summary>Vencimentos desta conta</summary>
      <form action={action} className={styles.rowForm}>
        <input type="hidden" name="accountId" value={accountId} />
        <input type="hidden" name="back" value={`/clientes/${customerId}`} />
        <label>
          Forma
          <select name="dueMode" value={mode} onChange={(event) => setMode(event.target.value)}>
            <option value="">Padrão da filial</option>
            <option value="closing">Fatura mensal (fechamento)</option>
            <option value="days">Dias corridos</option>
          </select>
        </label>
        {mode === "closing" && (
          <>
            <label>
              Fecha no dia
              <input name="closingDay" type="number" min={1} max={28} required defaultValue={terms.closing_day} />
            </label>
            <label>
              Vence no dia
              <input name="dueDay" type="number" min={1} max={28} required defaultValue={terms.due_day} />
            </label>
          </>
        )}
        {mode === "days" && (
          <label>
            A cada (dias)
            <input name="intervalDays" type="number" min={7} max={90} required defaultValue={terms.interval_days} />
          </label>
        )}
        <button type="submit" disabled={pending}>
          Salvar vencimentos
        </button>
        <p className={styles.hint}>Vale para as compras novas; as parcelas já lançadas mantêm os vencimentos.</p>
        <Saved state={state} />
      </form>
    </details>
  );
}

export function DependentToggle({
  customerId,
  dependent,
  canManage,
}: {
  customerId: string;
  dependent: { id: string; name: string; credit_allowed: boolean };
  canManage: boolean;
}) {
  const [state, action, pending] = useActionState<CreditState, FormData>(changeDependent, {});
  return (
    <form action={action} className={styles.inline}>
      <input type="hidden" name="dependentId" value={dependent.id} />
      <input type="hidden" name="allowed" value={String(!dependent.credit_allowed)} />
      <input type="hidden" name="back" value={`/clientes/${customerId}`} />
      <span>
        {dependent.name}: {dependent.credit_allowed ? "pode comprar no crediário" : "não compra no crediário"}
      </span>
      {canManage && (
        <button type="submit" disabled={pending}>
          {dependent.credit_allowed ? "Tirar autorização" : "Autorizar"}
        </button>
      )}
      <ErrorNotice error={state.error} />
    </form>
  );
}

export interface Policy {
  late_fee_percent: number;
  monthly_interest_percent: number;
  max_installments: number;
  limit_factor: number;
  block_after_days: number;
  due_mode: string;
  closing_day: number;
  due_day: number;
  interval_days: number;
}

export function PolicyForm({ branchId, policy, canEdit }: { branchId: string; policy: Policy; canEdit: boolean }) {
  const [state, action, pending] = useActionState<CreditState, FormData>(savePolicy, {});
  const [mode, setMode] = useState(policy.due_mode);
  return (
    <form action={action} className={styles.stack}>
      <input type="hidden" name="branchId" value={branchId} />
      <fieldset disabled={!canEdit} className={styles.inline}>
        <label>
          Multa (%)
          <input name="lateFeePercent" inputMode="decimal" defaultValue={numberText(policy.late_fee_percent)} />
        </label>
        <label>
          Juros ao mês (%)
          <input name="monthlyInterestPercent" inputMode="decimal" defaultValue={numberText(policy.monthly_interest_percent)} />
        </label>
        <label>
          Máximo de parcelas
          <input name="maxInstallments" type="number" min={1} max={24} defaultValue={policy.max_installments} />
        </label>
        <label>
          Bloqueia após (dias de atraso)
          <input name="blockAfterDays" type="number" min={1} max={365} defaultValue={policy.block_after_days} />
        </label>
        <label>
          Fator do limite sugerido
          <input name="limitFactor" inputMode="decimal" defaultValue={numberText(policy.limit_factor)} />
        </label>
        <label>
          Vencimentos
          <select name="dueMode" value={mode} onChange={(event) => setMode(event.target.value)}>
            <option value="closing">Fatura mensal (fechamento)</option>
            <option value="days">Dias corridos</option>
          </select>
        </label>
        <label>
          Fecha no dia
          <input name="closingDay" type="number" min={1} max={28} defaultValue={policy.closing_day} disabled={mode !== "closing"} />
        </label>
        <label>
          Vence no dia
          <input name="dueDay" type="number" min={1} max={28} defaultValue={policy.due_day} disabled={mode !== "closing"} />
        </label>
        <label>
          A cada (dias)
          <input name="intervalDays" type="number" min={7} max={90} defaultValue={policy.interval_days} disabled={mode !== "days"} />
        </label>
        {canEdit && (
          <button type="submit" disabled={pending}>
            Salvar parâmetros
          </button>
        )}
      </fieldset>
      <Saved state={state} />
    </form>
  );
}
