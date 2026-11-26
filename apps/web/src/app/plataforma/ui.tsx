"use client";

import { useActionState } from "react";
import { ErrorNotice } from "../error-notice";
import { BranchFields } from "../empresas/ui";
import { createTenant, decideIssuer, IssuerDecisionState, TenantState } from "./actions";
import styles from "../terminais/page.module.css";

/** Empresa nova como cliente separado: nome do cliente, empresa, primeira filial e administrador. */
export function CreateTenantForm() {
  const [state, action, pending] = useActionState<TenantState, FormData>(createTenant, {});
  if (state.created) {
    return (
      <div className={styles.success} role="status">
        <p>
          <strong>{state.created.name}</strong> cadastrado como cliente separado.
        </p>
        <p>
          Entregue ao administrador ({state.created.email}) a senha temporária abaixo. Ela aparece só agora e precisa
          ser trocada na primeira entrada.
        </p>
        <p>
          <code data-testid="temporary-password">{state.created.temporaryPassword}</code>
        </p>
        <button type="button" onClick={() => window.location.reload()}>
          Cadastrar outra
        </button>
      </div>
    );
  }
  return (
    <form action={action} className={styles.stack}>
      <div className={styles.inline}>
        <label>
          Nome do cliente (rede ou farmácia)
          <input name="groupName" required maxLength={150} size={30} />
        </label>
      </div>
      <h3>Empresa</h3>
      <div className={styles.inline}>
        <label>
          CNPJ
          <input name="cnpj" required maxLength={20} />
        </label>
        <label>
          Razão social
          <input name="legalName" required maxLength={150} size={30} />
        </label>
        <label>
          Nome fantasia
          <input name="tradeName" required maxLength={150} size={30} />
        </label>
      </div>
      <h3>Primeira filial (mesmo CNPJ)</h3>
      <BranchFields values={{}} />
      <h3>Administrador da empresa</h3>
      <div className={styles.inline}>
        <label>
          Nome
          <input name="adminName" required maxLength={200} size={30} />
        </label>
        <label>
          E-mail
          <input name="adminEmail" type="email" required maxLength={254} size={30} />
        </label>
      </div>
      <button type="submit" disabled={pending}>
        {pending ? "Cadastrando..." : "Cadastrar empresa"}
      </button>
      <ErrorNotice error={state.error} />
    </form>
  );
}

export interface PendingIssuer {
  id: string;
  group_name: string;
  cnpj: string;
  name: string | null;
  trade_name: string | null;
  state: string | null;
  tax_regime: number | null;
  kind: "company" | "branch";
  company_name: string | null;
  notes: number;
  first_emitted_at: string | null;
  last_emitted_at: string | null;
}

const REGIMES: [string, string][] = [
  ["1", "Simples Nacional"],
  ["2", "Simples Nacional (excesso de sublimite)"],
  ["3", "Regime normal"],
  ["4", "MEI"],
];

/**
 * Destino de um CNPJ das notas importadas: criar a empresa e a filial (ou só a filial, na empresa de
 * mesma raiz) no cliente que importou, revisando os dados que vieram da nota, ou recusar.
 */
export function IssuerDecision({ issuer }: { issuer: PendingIssuer }) {
  const [state, action, pending] = useActionState<IssuerDecisionState, FormData>(decideIssuer, {});
  if (state.done) {
    return (
      <p className={styles.success} role="status">
        {state.done.decision === "create"
          ? `Criada. ${state.done.notes} nota(s) vão entrar pela importação nos próximos minutos.`
          : `Recusada. ${state.done.notes} nota(s) ficaram como ignoradas.`}
      </p>
    );
  }
  const company = issuer.kind === "company";
  return (
    <form action={action} className={styles.stack}>
      <input type="hidden" name="id" value={issuer.id} />
      <div className={styles.inline}>
        {company && (
          <label>
            Razão social
            <input name="legalName" defaultValue={issuer.name ?? ""} maxLength={150} size={30} />
          </label>
        )}
        <label>
          Nome fantasia
          <input name="tradeName" defaultValue={issuer.trade_name ?? ""} maxLength={150} size={24} />
        </label>
        {company && (
          <label>
            Regime tributário
            <select name="taxRegime" defaultValue={issuer.tax_regime ? String(issuer.tax_regime) : ""}>
              <option value="">Como veio na nota</option>
              {REGIMES.map(([value, label]) => (
                <option key={value} value={value}>
                  {label}
                </option>
              ))}
            </select>
          </label>
        )}
      </div>
      <div className={styles.inline}>
        <button type="submit" name="decision" value="create" disabled={pending}>
          {company ? "Criar empresa e filial" : "Criar filial"}
        </button>
        <button
          type="submit"
          name="decision"
          value="refuse"
          disabled={pending}
          onClick={(event) => {
            if (!window.confirm(`Recusar o CNPJ ${issuer.cnpj}? As ${issuer.notes} nota(s) dele ficam como ignoradas.`)) {
              event.preventDefault();
            }
          }}
        >
          Recusar
        </button>
      </div>
      <ErrorNotice error={state.error} />
    </form>
  );
}
