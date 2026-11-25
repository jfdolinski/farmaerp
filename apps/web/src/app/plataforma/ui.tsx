"use client";

import { useActionState } from "react";
import { ErrorNotice } from "../error-notice";
import { BranchFields } from "../empresas/ui";
import { createTenant, TenantState } from "./actions";
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
